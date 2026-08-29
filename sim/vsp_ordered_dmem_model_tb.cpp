#include "Vvsp_ordered_dmem_model.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr uint8_t kLoad = 0;
constexpr uint8_t kStore = 1;
constexpr uint8_t kLocal = 0;
constexpr uint8_t kPhysical = 1;
constexpr uint8_t kTranslated = 2;

constexpr uint8_t kFaultNone = 0;
constexpr uint8_t kFaultTranslation = 1;
constexpr uint8_t kFaultAccess = 3;
constexpr uint8_t kFaultProtocol = 6;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& what, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << what << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& what, uint64_t expected,
               uint64_t actual) {
  ++checks;
  if (expected != actual) fail(what, expected, actual);
}

void eval_low(Vvsp_ordered_dmem_model& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_ordered_dmem_model& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_ordered_dmem_model& dut) {
  dut.req_valid_i = 0;
  dut.req_op_i = kLoad;
  dut.req_eaddr_i = 0;
  dut.req_addr_space_i = kLocal;
  dut.req_addr_context_i = 0;
  dut.req_wdata_i = 0;
  dut.req_wstrb_i = 0;
  dut.rsp_ready_i = 0;
  dut.init_valid_i = 0;
  dut.init_eaddr_i = 0;
  dut.init_wdata_i = 0;
  dut.init_wstrb_i = 0;
  dut.peek_eaddr_i = 0;
}

void reset(Vvsp_ordered_dmem_model& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
}

void initialize_word(Vvsp_ordered_dmem_model& dut, uint32_t address,
                     uint32_t data, uint8_t strobe = 0xf) {
  dut.init_valid_i = 1;
  dut.init_eaddr_i = address;
  dut.init_wdata_i = data;
  dut.init_wstrb_i = strobe;
  eval_low(dut);
  expect_eq("initializer ready", 1, dut.init_ready_o);
  expect_eq("initializer address accepted", 0, dut.init_error_o);
  tick(dut);
  dut.init_valid_i = 0;
}

void expect_peek(Vvsp_ordered_dmem_model& dut, uint32_t address,
                 uint32_t data) {
  dut.peek_eaddr_i = address;
  eval_low(dut);
  expect_eq("peek address valid", 0, dut.peek_error_o);
  expect_eq("peek data", data, dut.peek_rdata_o);
}

struct Request {
  uint8_t op = kLoad;
  uint32_t address = 0;
  uint8_t address_space = kLocal;
  uint32_t data = 0;
  uint8_t strobe = 0;
  uint8_t address_context = 0;
};

struct ExpectedResponse {
  uint32_t data = 0;
  uint8_t fault = kFaultNone;
};

void drive_request(Vvsp_ordered_dmem_model& dut, const Request& request) {
  dut.req_valid_i = 1;
  dut.req_op_i = request.op;
  dut.req_eaddr_i = request.address;
  dut.req_addr_space_i = request.address_space;
  dut.req_addr_context_i = request.address_context;
  dut.req_wdata_i = request.data;
  dut.req_wstrb_i = request.strobe;
}

void enqueue(Vvsp_ordered_dmem_model& dut, const Request& request,
             unsigned expected_count) {
  drive_request(dut, request);
  eval_low(dut);
  expect_eq("request queue has credit", 1, dut.req_ready_o);
  tick(dut);
  dut.req_valid_i = 0;
  expect_eq("outstanding count after request", expected_count,
            dut.outstanding_count_o);
}

ExpectedResponse consume_response(Vvsp_ordered_dmem_model& dut) {
  for (unsigned timeout = 0; timeout < 100; ++timeout) {
    dut.rsp_ready_i = 0;
    eval_low(dut);
    if (!dut.rsp_valid_o) {
      tick(dut);
      continue;
    }

    const ExpectedResponse observed{dut.rsp_rdata_o,
                                    uint8_t(dut.rsp_fault_cause_o)};
    // A response must remain stable for an arbitrary backpressure cycle.
    tick(dut);
    expect_eq("stalled response remains valid", 1, dut.rsp_valid_o);
    expect_eq("stalled response data", observed.data, dut.rsp_rdata_o);
    expect_eq("stalled response fault", observed.fault,
              dut.rsp_fault_cause_o);

    dut.rsp_ready_i = 1;
    tick(dut);
    dut.rsp_ready_i = 0;
    return observed;
  }

  std::cerr << "timeout waiting for memory response\n";
  std::exit(1);
}

void expect_response(Vvsp_ordered_dmem_model& dut,
                     const ExpectedResponse& expected,
                     const std::string& label) {
  const ExpectedResponse observed = consume_response(dut);
  expect_eq(label + " data", expected.data, observed.data);
  expect_eq(label + " fault", expected.fault, observed.fault);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_ordered_dmem_model dut;
  reset(dut);

  expect_eq("empty after reset", 1, dut.idle_o);
  expect_eq("zero outstanding after reset", 0, dut.outstanding_count_o);

  initialize_word(dut, 0x40, 0xaabbccddu);
  initialize_word(dut, 0x44, 0x11223344u);
  expect_peek(dut, 0x40, 0xaabbccddu);
  expect_peek(dut, 0x44, 0x11223344u);

  // Fill the four-entry ordered queue while responses are backpressured.
  enqueue(dut, Request{kLoad, 0x40, kLocal, 0, 0, 0x11}, 1);
  enqueue(dut, Request{kStore, 0x44, kLocal, 0xdeadbeefu, 0x5, 0x22}, 2);
  enqueue(dut, Request{kLoad, 0x44, kLocal, 0, 0, 0x33}, 3);
  enqueue(dut, Request{kLoad, 0x40, kTranslated, 0, 0, 0x44}, 4);

  // Stores commit once, at request acceptance, and obey byte strobes.
  expect_peek(dut, 0x44, 0x11ad33efu);
  drive_request(dut, Request{kLoad, 0x42, kLocal, 0, 0, 0x55});
  eval_low(dut);
  expect_eq("full queue backpressures request", 0, dut.req_ready_o);
  dut.init_valid_i = 1;
  dut.init_eaddr_i = 0x48;
  dut.init_wdata_i = 0x12345678u;
  dut.init_wstrb_i = 0xf;
  eval_low(dut);
  expect_eq("held dmem request blocks initializer", 0, dut.init_ready_o);
  dut.init_valid_i = 0;

  // Pop the ready head and accept a replacement on the same edge.  Count
  // remains full; responses still retire in request order without IDs.
  for (unsigned timeout = 0; timeout < 20 && !dut.rsp_valid_o; ++timeout)
    tick(dut);
  eval_low(dut);
  expect_eq("head response became eligible", 1, dut.rsp_valid_o);
  expect_eq("first response data before replacement", 0xaabbccddu,
            dut.rsp_rdata_o);
  expect_eq("first response fault before replacement", kFaultNone,
            dut.rsp_fault_cause_o);
  dut.rsp_ready_i = 1;
  eval_low(dut);
  expect_eq("full queue exposes replacement credit on pop", 1,
            dut.req_ready_o);
  tick(dut);
  dut.req_valid_i = 0;
  dut.rsp_ready_i = 0;
  expect_eq("simultaneous pop/push preserves count", 4,
            dut.outstanding_count_o);

  const std::vector<ExpectedResponse> ordered = {
      {0, kFaultNone},
      {0x11ad33efu, kFaultNone},
      {0, kFaultTranslation},
      {0, kFaultAccess},
  };
  const std::vector<std::string> labels = {
      "store ack", "load after partial store", "translated request",
      "unaligned replacement"};
  for (std::size_t index = 0; index < ordered.size(); ++index)
    expect_response(dut, ordered[index], labels[index]);

  expect_eq("queue empty after ordered drain", 1, dut.idle_o);
  expect_eq("count empty after ordered drain", 0, dut.outstanding_count_o);

  // The model distinguishes endpoint access failures from malformed beat
  // shapes.  PHYSICAL is unsupported by the default LOCAL-only instance.
  enqueue(dut, Request{kLoad, 0x40, kPhysical, 0, 0, 0}, 1);
  expect_response(dut, {0, kFaultAccess}, "unsupported physical request");
  enqueue(dut, Request{kLoad, 0x1000, kLocal, 0, 0, 0}, 1);
  expect_response(dut, {0, kFaultAccess}, "out-of-range request");
  enqueue(dut, Request{kLoad, 0x40, kLocal, 0, 0x1, 0}, 1);
  expect_response(dut, {0, kFaultProtocol}, "load with write strobe");
  enqueue(dut, Request{kStore, 0x40, kLocal, 0x12345678u, 0, 0}, 1);
  expect_response(dut, {0, kFaultProtocol}, "store without write strobe");
  expect_peek(dut, 0x40, 0xaabbccddu);

  // Initialization reports bad addresses without touching the array.
  dut.init_valid_i = 1;
  dut.init_eaddr_i = 0x41;
  dut.init_wdata_i = 0;
  dut.init_wstrb_i = 0xf;
  eval_low(dut);
  expect_eq("unaligned initializer reports error", 1, dut.init_error_o);
  tick(dut);
  dut.init_valid_i = 0;
  dut.peek_eaddr_i = 0x41;
  eval_low(dut);
  expect_eq("unaligned peek reports error", 1, dut.peek_error_o);

  // Transaction-domain reset discards pending responses while preserving
  // SRAM-like contents.
  enqueue(dut, Request{kLoad, 0x40, kLocal, 0, 0, 0}, 1);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
  expect_eq("reset discards outstanding response", 0,
            dut.outstanding_count_o);
  expect_eq("reset returns model to idle", 1, dut.idle_o);
  expect_peek(dut, 0x40, 0xaabbccddu);

  std::cout << "PASS vsp_ordered_dmem_model checks=" << checks << '\n';
  return 0;
}
