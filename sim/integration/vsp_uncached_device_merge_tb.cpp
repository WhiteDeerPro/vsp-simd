// SPDX-License-Identifier: MIT

#include "Vvsp_uncached_device_merge_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using Dut = Vvsp_uncached_device_merge_tb_top;

constexpr std::uint8_t kLoad = 0;
constexpr std::uint8_t kStore = 1;
constexpr std::uint8_t kFaultNone = 0;
constexpr std::uint8_t kFaultBus = 4;

std::uint64_t checks = 0;
std::uint64_t cycles = 0;

[[noreturn]] void fail(const std::string& label, std::uint64_t expected,
                       std::uint64_t actual) {
  std::cerr << "FAIL " << label << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << std::dec << '\n';
  std::exit(EXIT_FAILURE);
}

void expect_eq(const std::string& label, std::uint64_t expected,
               std::uint64_t actual) {
  ++checks;
  if (expected != actual) fail(label, expected, actual);
}

void eval_low(Dut& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Dut& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  ++cycles;
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Dut& dut) {
  dut.uncached_req_valid_i = 0;
  dut.uncached_req_op_i = kLoad;
  dut.uncached_req_addr_i = 0;
  dut.uncached_req_wdata_i = 0;
  dut.uncached_req_wstrb_i = 0;
  dut.uncached_rsp_ready_i = 0;

  dut.device_req_valid_i = 0;
  dut.device_req_op_i = kLoad;
  dut.device_req_addr_i = 0;
  dut.device_req_wdata_i = 0;
  dut.device_req_wstrb_i = 0;
  dut.device_rsp_ready_i = 0;

  dut.shared_req_ready_i = 0;
  dut.shared_rsp_valid_i = 0;
  dut.shared_rsp_rdata_i = 0;
  dut.shared_rsp_fault_cause_i = kFaultNone;
  dut.protocol_error_clear_i = 0;
}

void reset(Dut& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  expect_eq("reset request valid", 0, dut.shared_req_valid_o);
  expect_eq("reset uncached response valid", 0, dut.uncached_rsp_valid_o);
  expect_eq("reset device response valid", 0, dut.device_rsp_valid_o);
  expect_eq("reset protocol diagnostic", 0, dut.protocol_error_o);
  dut.rst_ni = 1;
  eval_low(dut);
  expect_eq("empty merge idle", 1, dut.idle_o);
}

void expect_device_payload(const Dut& dut, const std::string& prefix) {
  expect_eq(prefix + " valid", 1, dut.shared_req_valid_o);
  expect_eq(prefix + " op", kStore, dut.shared_req_op_o);
  expect_eq(prefix + " address", 0x0220, dut.shared_req_addr_o);
  expect_eq(prefix + " data", 0xdeadbeefU, dut.shared_req_wdata_o);
  expect_eq(prefix + " strobe", 0xf, dut.shared_req_wstrb_o);
}

void complete_pending_uncached(Dut& dut) {
  dut.shared_req_ready_i = 1;
  eval_low(dut);
  expect_eq("pending uncached selected", 1, dut.shared_req_valid_o);
  expect_eq("pending uncached ready", 1, dut.uncached_req_ready_o);
  expect_eq("pending device not ready", 0, dut.device_req_ready_o);
  expect_eq("pending uncached address", 0x0111, dut.shared_req_addr_o);
  tick(dut);

  dut.uncached_req_valid_i = 0;
  dut.shared_req_ready_i = 0;
  dut.uncached_rsp_ready_i = 1;
  dut.shared_rsp_valid_i = 1;
  dut.shared_rsp_rdata_i = 0x12345678U;
  dut.shared_rsp_fault_cause_i = kFaultNone;
  eval_low(dut);
  expect_eq("uncached response demux valid", 1, dut.uncached_rsp_valid_o);
  expect_eq("uncached response excludes device", 0, dut.device_rsp_valid_o);
  expect_eq("uncached response data", 0x12345678U,
            dut.uncached_rsp_rdata_o);
  tick(dut);
  dut.shared_rsp_valid_i = 0;
  dut.uncached_rsp_ready_i = 0;
  eval_low(dut);
  expect_eq("merge idle after uncached completion", 1, dut.idle_o);
}

void test_stalled_device_lock_and_response_hold(Dut& dut) {
  dut.device_req_valid_i = 1;
  dut.device_req_op_i = kStore;
  dut.device_req_addr_i = 0x0220;
  dut.device_req_wdata_i = 0xdeadbeefU;
  dut.device_req_wstrb_i = 0xf;
  dut.shared_req_ready_i = 0;
  eval_low(dut);
  expect_device_payload(dut, "initial stalled device");
  expect_eq("stalled device not accepted", 0, dut.device_req_ready_o);
  tick(dut);  // Locks the DEVICE grant.

  // A later, normally higher-priority UNCACHED request must not switch the
  // selected shared payload while DEVICE remains stalled.
  dut.uncached_req_valid_i = 1;
  dut.uncached_req_op_i = kLoad;
  dut.uncached_req_addr_i = 0x0111;
  dut.uncached_req_wdata_i = 0xa5a5a5a5U;
  dut.uncached_req_wstrb_i = 0;
  eval_low(dut);
  expect_device_payload(dut, "locked device with late uncached");
  expect_eq("late uncached remains stalled", 0, dut.uncached_req_ready_o);
  tick(dut);
  expect_eq("overlapping live sources diagnosed", 1,
            dut.protocol_error_o);
  expect_device_payload(dut, "locked device after overlap cycle");

  dut.shared_req_ready_i = 1;
  eval_low(dut);
  expect_device_payload(dut, "device grant handshake");
  expect_eq("device alone receives ready", 1, dut.device_req_ready_o);
  expect_eq("uncached cannot steal ready", 0, dut.uncached_req_ready_o);
  tick(dut);
  dut.device_req_valid_i = 0;
  dut.shared_req_ready_i = 0;

  // The accepted owner, not live request arbitration, controls the response.
  dut.shared_rsp_valid_i = 1;
  dut.shared_rsp_rdata_i = 0xcafe1234U;
  dut.shared_rsp_fault_cause_i = kFaultBus;
  dut.device_rsp_ready_i = 0;
  dut.uncached_rsp_ready_i = 1;
  eval_low(dut);
  expect_eq("device response valid while stalled", 1,
            dut.device_rsp_valid_o);
  expect_eq("device response excludes uncached", 0,
            dut.uncached_rsp_valid_o);
  expect_eq("owner backpressure reaches shared response", 0,
            dut.shared_rsp_ready_o);
  expect_eq("device response data", 0xcafe1234U, dut.device_rsp_rdata_o);
  expect_eq("device response fault", kFaultBus,
            dut.device_rsp_fault_cause_o);
  tick(dut);
  expect_eq("stalled response remains exposed", 1, dut.device_rsp_valid_o);
  expect_eq("stalled response remains blocked", 0, dut.shared_rsp_ready_o);

  dut.device_rsp_ready_i = 1;
  eval_low(dut);
  expect_eq("device ready releases shared response", 1,
            dut.shared_rsp_ready_o);
  tick(dut);
  dut.shared_rsp_valid_i = 0;
  dut.device_rsp_ready_i = 0;

  // The previously blocked UNCACHED request is still a normal ready/valid
  // producer and proceeds once the DEVICE response retires.
  complete_pending_uncached(dut);

  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("explicit clear removes overlap diagnostic", 0,
            dut.protocol_error_o);
}

void test_simultaneous_priority(Dut& dut) {
  dut.uncached_req_valid_i = 1;
  dut.uncached_req_op_i = kLoad;
  dut.uncached_req_addr_i = 0x0333;
  dut.uncached_req_wdata_i = 0;
  dut.uncached_req_wstrb_i = 0;
  dut.device_req_valid_i = 1;
  dut.device_req_op_i = kStore;
  dut.device_req_addr_i = 0x0444;
  dut.device_req_wdata_i = 0x0badf00dU;
  dut.device_req_wstrb_i = 0x5;
  dut.shared_req_ready_i = 1;
  eval_low(dut);
  expect_eq("simultaneous priority selects uncached address", 0x0333,
            dut.shared_req_addr_o);
  expect_eq("simultaneous priority accepts uncached", 1,
            dut.uncached_req_ready_o);
  expect_eq("simultaneous priority stalls device", 0,
            dut.device_req_ready_o);
  tick(dut);
  expect_eq("simultaneous request diagnosed", 1, dut.protocol_error_o);
  dut.uncached_req_valid_i = 0;
  dut.shared_req_ready_i = 0;

  dut.uncached_rsp_ready_i = 1;
  dut.shared_rsp_valid_i = 1;
  dut.shared_rsp_rdata_i = 0x77778888U;
  dut.shared_rsp_fault_cause_i = kFaultNone;
  eval_low(dut);
  expect_eq("priority winner owns response", 1, dut.uncached_rsp_valid_o);
  tick(dut);
  dut.shared_rsp_valid_i = 0;
  dut.uncached_rsp_ready_i = 0;

  // DEVICE was not accepted and therefore remains pending at its source.
  dut.shared_req_ready_i = 1;
  eval_low(dut);
  expect_eq("losing device presented after winner retires", 1,
            dut.shared_req_valid_o);
  expect_eq("losing device receives eventual ready", 1,
            dut.device_req_ready_o);
  expect_eq("losing device address preserved", 0x0444,
            dut.shared_req_addr_o);
  tick(dut);
  dut.device_req_valid_i = 0;
  dut.shared_req_ready_i = 0;
  dut.device_rsp_ready_i = 1;
  dut.shared_rsp_valid_i = 1;
  dut.shared_rsp_rdata_i = 0x01020304U;
  tick(dut);
  dut.shared_rsp_valid_i = 0;
  dut.device_rsp_ready_i = 0;

  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("simultaneous diagnostic clears", 0, dut.protocol_error_o);
}

void test_orphan_and_clear_precedence(Dut& dut) {
  eval_low(dut);
  expect_eq("orphan test begins idle", 1, dut.idle_o);
  dut.shared_rsp_valid_i = 1;
  dut.shared_rsp_rdata_i = 0xfeedfaceU;
  dut.shared_rsp_fault_cause_i = kFaultBus;
  eval_low(dut);
  expect_eq("orphan is consumed", 1, dut.shared_rsp_ready_o);
  expect_eq("orphan hidden from uncached", 0, dut.uncached_rsp_valid_o);
  expect_eq("orphan hidden from device", 0, dut.device_rsp_valid_o);
  tick(dut);
  expect_eq("orphan diagnosed", 1, dut.protocol_error_o);
  dut.shared_rsp_valid_i = 0;

  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("orphan diagnostic clears", 0, dut.protocol_error_o);

  // A newly observed violation wins over clear in the same cycle, preserving
  // evidence rather than losing it to software's clear pulse.
  dut.protocol_error_clear_i = 1;
  dut.shared_rsp_valid_i = 1;
  tick(dut);
  expect_eq("new orphan dominates simultaneous clear", 1,
            dut.protocol_error_o);
  dut.shared_rsp_valid_i = 0;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("following clear removes final diagnostic", 0,
            dut.protocol_error_o);
  eval_low(dut);
  expect_eq("merge returns idle", 1, dut.idle_o);
}

}  // namespace

double sc_time_stamp() { return static_cast<double>(cycles); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Dut dut;
  reset(dut);
  test_stalled_device_lock_and_response_hold(dut);
  test_simultaneous_priority(dut);
  test_orphan_and_clear_precedence(dut);
  std::cout << "vsp_uncached_device_merge_tb: " << checks
            << " checks passed in " << cycles << " cycles\n";
  return EXIT_SUCCESS;
}
