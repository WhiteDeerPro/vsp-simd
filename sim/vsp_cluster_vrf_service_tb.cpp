#include "Vvsp_cluster_vrf_service.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

unsigned checks = 0;

void fail(const std::string& label, uint64_t expected, uint64_t actual) {
  std::cerr << "FAIL " << label << ": expected 0x" << std::hex << expected
            << ", got 0x" << actual << std::dec << '\n';
  std::exit(1);
}

void expect_eq(const std::string& label, uint64_t expected,
               uint64_t actual) {
  ++checks;
  if (expected != actual) fail(label, expected, actual);
}

void clear_inputs(Vvsp_cluster_vrf_service& dut) {
  dut.client_read_valid_i = 0;
  dut.client_read_context_i = 0;
  dut.client_read_tag_i = 0;
  dut.client_read_group_i = 0;
  dut.client_read_row_i = 0;
  dut.client_read_mask_i = 0;
  dut.client_read_cpl_ready_i = 0;
  dut.client_read_rsp_ready_i = 0;

  dut.client_write_valid_i = 0;
  dut.client_write_context_i = 0;
  dut.client_write_tag_i = 0;
  dut.client_write_group_i = 0;
  dut.client_write_row_i = 0;
  dut.client_write_mask_i = 0;
  dut.client_write_data_i = 0;
  dut.client_write_cpl_ready_i = 0;

  dut.cluster_read_ready_i = 0;
  dut.cluster_read_cpl_valid_i = 0;
  dut.cluster_read_cpl_context_i = 0;
  dut.cluster_read_cpl_tag_i = 0;
  dut.cluster_read_cpl_group_i = 0;
  dut.cluster_read_cpl_error_i = 0;
  dut.cluster_read_rsp_valid_i = 0;
  dut.cluster_read_rsp_context_i = 0;
  dut.cluster_read_rsp_tag_i = 0;
  dut.cluster_read_rsp_group_i = 0;
  dut.cluster_read_rsp_data_i = 0;
  dut.cluster_read_rsp_mask_i = 0;
  dut.cluster_read_rsp_error_i = 0;

  dut.cluster_write_ready_i = 0;
  dut.cluster_write_cpl_valid_i = 0;
  dut.cluster_write_cpl_context_i = 0;
  dut.cluster_write_cpl_tag_i = 0;
  dut.cluster_write_cpl_group_i = 0;
  dut.cluster_write_cpl_error_i = 0;
}

void tick(Vvsp_cluster_vrf_service& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void reset(Vvsp_cluster_vrf_service& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("reset idle", 0, dut.busy_o);
  expect_eq("reset no read", 0, dut.cluster_read_valid_o);
  expect_eq("reset no write", 0, dut.cluster_write_valid_o);
}

void client0_read_with_response_first(Vvsp_cluster_vrf_service& dut) {
  // Client 0 read is request lane 0 and therefore wins from reset. A client 1
  // write waits without observing ready.
  dut.client_read_valid_i = 0x1;
  dut.client_read_tag_i = 0x11;
  dut.client_read_group_i = 0x2;
  dut.client_read_row_i = 0x3;
  dut.client_read_mask_i = 0x5;
  dut.client_write_valid_i = 0x2;
  dut.client_write_tag_i = uint32_t{0x22} << 8;
  dut.client_write_group_i = uint32_t{0x1} << 2;
  dut.client_write_row_i = uint32_t{0x4} << 4;
  dut.client_write_mask_i = uint32_t{0xf} << 4;
  dut.client_write_data_i = uint64_t{0xdeadbeef} << 32;
  dut.eval();

  expect_eq("client0 read selected", 1, dut.cluster_read_valid_o);
  expect_eq("client1 write not selected", 0, dut.cluster_write_valid_o);
  expect_eq("read tag forwarded", 0x11, dut.cluster_read_tag_o);
  expect_eq("read group forwarded", 2, dut.cluster_read_group_o);
  expect_eq("read row forwarded", 3, dut.cluster_read_row_o);
  expect_eq("read mask forwarded", 5, dut.cluster_read_mask_o);
  expect_eq("no ready while cluster blocked", 0, dut.client_read_ready_o);

  dut.cluster_read_ready_i = 1;
  dut.eval();
  expect_eq("selected client ready", 1, dut.client_read_ready_o);
  tick(dut);
  dut.client_read_valid_i = 0;
  dut.cluster_read_ready_i = 0;
  dut.eval();
  expect_eq("read becomes active", 1, dut.busy_o);
  expect_eq("active client0", 0, dut.active_client_o);
  expect_eq("active direction read", 1, dut.active_read_o);
  expect_eq("waiting client remains blocked", 0, dut.client_write_ready_o);

  // The data response arrives first and is held by client backpressure.
  dut.cluster_read_rsp_valid_i = 1;
  dut.cluster_read_rsp_context_i = 0;
  dut.cluster_read_rsp_tag_i = 0x11;
  dut.cluster_read_rsp_group_i = 2;
  dut.cluster_read_rsp_data_i = 0xa1b2c3d4;
  dut.cluster_read_rsp_mask_i = 5;
  dut.eval();
  expect_eq("rsp only client0", 1, dut.client_read_rsp_valid_o);
  expect_eq("rsp cluster stalled", 0, dut.cluster_read_rsp_ready_o);
  expect_eq("rsp data client0", 0xa1b2c3d4,
            dut.client_read_rsp_data_o & 0xffffffffu);
  expect_eq("rsp client1 quiet", 0,
            (dut.client_read_rsp_valid_o >> 1) & 1u);

  dut.client_read_rsp_ready_i = 0x1;
  tick(dut);
  dut.cluster_read_rsp_valid_i = 0;
  dut.client_read_rsp_ready_i = 0;

  // Completion remains independently routable after the response retired.
  dut.cluster_read_cpl_valid_i = 1;
  dut.cluster_read_cpl_tag_i = 0x11;
  dut.cluster_read_cpl_group_i = 2;
  dut.client_read_cpl_ready_i = 0x1;
  dut.eval();
  expect_eq("cpl only client0", 1, dut.client_read_cpl_valid_o);
  expect_eq("cpl cluster ready", 1, dut.cluster_read_cpl_ready_o);
  tick(dut);
  dut.cluster_read_cpl_valid_i = 0;
  dut.client_read_cpl_ready_i = 0;
  dut.eval();
  expect_eq("read retires after both returns", 0, dut.busy_o);
}

void client0_write_then_client1_read(Vvsp_cluster_vrf_service& dut) {
  // RR advanced to lane 1, so client 0 write wins over client 1 read.
  dut.client_write_valid_i = 0x1;
  dut.client_write_context_i = 0;
  dut.client_write_tag_i = 0x33;
  dut.client_write_group_i = 3;
  dut.client_write_row_i = 7;
  dut.client_write_mask_i = 0xa;
  dut.client_write_data_i = 0x11223344;
  dut.client_read_valid_i = 0x2;
  dut.client_read_context_i = uint32_t{1} << 1;
  dut.client_read_tag_i = uint32_t{0x44} << 8;
  dut.client_read_group_i = uint32_t{1} << 2;
  dut.client_read_row_i = uint32_t{8} << 4;
  dut.client_read_mask_i = uint32_t{0xf} << 4;
  dut.cluster_write_ready_i = 1;
  dut.eval();
  expect_eq("rr selects client0 write", 1, dut.cluster_write_valid_o);
  expect_eq("write data", 0x11223344, dut.cluster_write_data_o);
  expect_eq("write client0 ready", 1, dut.client_write_ready_o);
  expect_eq("client1 read waits", 0, dut.client_read_ready_o);
  tick(dut);
  dut.client_write_valid_i = 0;
  dut.cluster_write_ready_i = 0;

  dut.cluster_write_cpl_valid_i = 1;
  dut.cluster_write_cpl_tag_i = 0x33;
  dut.cluster_write_cpl_group_i = 3;
  dut.cluster_write_cpl_error_i = 1;
  dut.client_write_cpl_ready_i = 0x1;
  dut.eval();
  expect_eq("write cpl client0", 1, dut.client_write_cpl_valid_o);
  expect_eq("write error forwarded", 1, dut.client_write_cpl_error_o);
  tick(dut);
  dut.cluster_write_cpl_valid_i = 0;
  dut.client_write_cpl_ready_i = 0;
  dut.eval();
  expect_eq("write retires", 0, dut.busy_o);

  // The waiting client 1 read is now next in RR order and is accepted.
  dut.cluster_read_ready_i = 1;
  dut.eval();
  expect_eq("client1 read selected", 1, dut.cluster_read_valid_o);
  expect_eq("client1 read ready", 0x2, dut.client_read_ready_o);
  expect_eq("client1 tag", 0x44, dut.cluster_read_tag_o);
  expect_eq("client1 context", 1, dut.cluster_read_context_o);
  tick(dut);
  dut.client_read_valid_i = 0;
  dut.cluster_read_ready_i = 0;

  // Completion and response may retire together and are routed only to owner 1.
  dut.cluster_read_cpl_valid_i = 1;
  dut.cluster_read_cpl_context_i = 1;
  dut.cluster_read_cpl_tag_i = 0x44;
  dut.cluster_read_cpl_group_i = 1;
  dut.cluster_read_rsp_valid_i = 1;
  dut.cluster_read_rsp_context_i = 1;
  dut.cluster_read_rsp_tag_i = 0x44;
  dut.cluster_read_rsp_group_i = 1;
  dut.cluster_read_rsp_data_i = 0x55667788;
  dut.cluster_read_rsp_mask_i = 0xf;
  dut.client_read_cpl_ready_i = 0x2;
  dut.client_read_rsp_ready_i = 0x2;
  dut.eval();
  expect_eq("client1 cpl only", 0x2, dut.client_read_cpl_valid_o);
  expect_eq("client1 rsp only", 0x2, dut.client_read_rsp_valid_o);
  expect_eq("client1 rsp upper data", 0x55667788,
            (dut.client_read_rsp_data_o >> 32) & 0xffffffffu);
  tick(dut);
  clear_inputs(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("client1 read retires", 0, dut.busy_o);
}

void reset_discards_outstanding(Vvsp_cluster_vrf_service& dut) {
  dut.client_write_valid_i = 1;
  dut.cluster_write_ready_i = 1;
  dut.eval();
  tick(dut);
  expect_eq("write active before reset", 1, dut.busy_o);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  clear_inputs(dut);
  dut.rst_ni = 1;
  dut.cluster_write_cpl_valid_i = 1;
  dut.eval();
  expect_eq("reset clears owner", 0, dut.busy_o);
  expect_eq("stale write completion not consumed", 0,
            dut.cluster_write_cpl_ready_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_cluster_vrf_service dut;
  reset(dut);
  client0_read_with_response_first(dut);
  client0_write_then_client1_read(dut);
  reset_discards_outstanding(dut);
  std::cout << "PASS: VSP cluster VRF service " << checks
            << " checks across arbitration, ownership, independent read "
               "returns, write errors, backpressure, and reset\n";
  return 0;
}
