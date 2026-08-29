#include <verilated.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

#include "Vvsp_ordered_ifetch_model.h"

namespace {

constexpr uint8_t kLocal = 0;
constexpr uint8_t kPhysical = 1;
constexpr uint8_t kTranslated = 2;
constexpr uint8_t kUndefinedSpace = 3;
constexpr uint8_t kFaultNone = 0;
constexpr uint8_t kFaultTranslation = 1;
constexpr uint8_t kFaultAccess = 3;
constexpr uint8_t kFaultProtocol = 6;

unsigned checks = 0;

template <typename Expected, typename Actual>
void expect_eq(const std::string& label, Expected expected, Actual actual) {
  ++checks;
  if (static_cast<uint64_t>(expected) != static_cast<uint64_t>(actual)) {
    std::cerr << label << ": expected 0x" << std::hex
              << static_cast<uint64_t>(expected) << ", got 0x"
              << static_cast<uint64_t>(actual) << std::dec << '\n';
    std::exit(1);
  }
}

void eval_low(Vvsp_ordered_ifetch_model& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_ordered_ifetch_model& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_ordered_ifetch_model& dut) {
  dut.req_valid_i = 0;
  dut.req_pc_i = 0;
  dut.req_word_count_i = 0;
  dut.req_addr_space_i = kLocal;
  dut.req_addr_context_i = 0;
  dut.rsp_ready_i = 0;
  dut.init_valid_i = 0;
  dut.init_pc_i = 0;
  dut.init_word_i = 0;
  dut.peek_pc_i = 0;
}

void reset(Vvsp_ordered_ifetch_model& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
}

void initialize_word(Vvsp_ordered_ifetch_model& dut, uint32_t pc,
                     uint32_t word) {
  dut.init_valid_i = 1;
  dut.init_pc_i = pc;
  dut.init_word_i = word;
  eval_low(dut);
  expect_eq("initializer ready", 1, dut.init_ready_o);
  expect_eq("initializer address accepted", 0, dut.init_error_o);
  tick(dut);
  dut.init_valid_i = 0;
}

void expect_peek(Vvsp_ordered_ifetch_model& dut, uint32_t pc,
                 uint32_t word) {
  dut.peek_pc_i = pc;
  eval_low(dut);
  expect_eq("peek address valid", 0, dut.peek_error_o);
  expect_eq("peek word", word, dut.peek_word_o);
}

struct Request {
  uint32_t pc;
  uint8_t count;
  uint8_t address_space = kLocal;
  uint8_t address_context = 0;
};

void drive_request(Vvsp_ordered_ifetch_model& dut, const Request& request) {
  dut.req_valid_i = 1;
  dut.req_pc_i = request.pc;
  dut.req_word_count_i = request.count;
  dut.req_addr_space_i = request.address_space;
  dut.req_addr_context_i = request.address_context;
}

void enqueue(Vvsp_ordered_ifetch_model& dut, const Request& request,
             unsigned expected_count) {
  drive_request(dut, request);
  eval_low(dut);
  expect_eq("fetch queue has credit", 1, dut.req_ready_o);
  tick(dut);
  dut.req_valid_i = 0;
  expect_eq("fetch outstanding count", expected_count,
            dut.outstanding_count_o);
}

struct Response {
  std::array<uint32_t, 4> words{};
  uint8_t count = 0;
  uint8_t fault = 0;
};

Response observe_response(const Vvsp_ordered_ifetch_model& dut) {
  Response response;
  for (unsigned index = 0; index < response.words.size(); ++index)
    response.words[index] = dut.rsp_words_o[index];
  response.count = dut.rsp_word_count_o;
  response.fault = dut.rsp_fault_cause_o;
  return response;
}

Response consume_response(Vvsp_ordered_ifetch_model& dut) {
  for (unsigned timeout = 0; timeout < 100; ++timeout) {
    dut.rsp_ready_i = 0;
    eval_low(dut);
    if (!dut.rsp_valid_o) {
      tick(dut);
      continue;
    }

    const Response response = observe_response(dut);
    tick(dut);
    expect_eq("stalled fetch response remains valid", 1, dut.rsp_valid_o);
    expect_eq("stalled fetch count", response.count,
              dut.rsp_word_count_o);
    expect_eq("stalled fetch fault", response.fault,
              dut.rsp_fault_cause_o);
    for (unsigned index = 0; index < response.words.size(); ++index)
      expect_eq("stalled fetch word", response.words[index],
                dut.rsp_words_o[index]);

    dut.rsp_ready_i = 1;
    tick(dut);
    dut.rsp_ready_i = 0;
    return response;
  }

  std::cerr << "timeout waiting for fetch response\n";
  std::exit(1);
}

void expect_response(Vvsp_ordered_ifetch_model& dut,
                     const Response& expected, const std::string& label) {
  const Response observed = consume_response(dut);
  expect_eq(label + " count", expected.count, observed.count);
  expect_eq(label + " fault", expected.fault, observed.fault);
  for (unsigned index = 0; index < expected.words.size(); ++index)
    expect_eq(label + " word", expected.words[index], observed.words[index]);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_ordered_ifetch_model dut;
  reset(dut);

  expect_eq("fetch model idle after reset", 1, dut.idle_o);
  expect_eq("fetch model empty after reset", 0, dut.outstanding_count_o);

  const std::array<uint32_t, 8> program = {
      0x10000000u, 0x20000001u, 0x30000002u, 0x40000003u,
      0x50000004u, 0x60000005u, 0x70000006u, 0x80000007u};
  for (unsigned index = 0; index < program.size(); ++index)
    initialize_word(dut, 0x20 + 4 * index, program[index]);
  expect_peek(dut, 0x20, program[0]);
  expect_peek(dut, 0x3c, program[7]);

  enqueue(dut, Request{0x20, 4, kLocal, 0x11}, 1);
  enqueue(dut, Request{0x30, 2, kLocal, 0x22}, 2);
  enqueue(dut, Request{0x20, 1, kTranslated, 0x33}, 3);

  drive_request(dut, Request{0x24, 1, kLocal, 0x44});
  eval_low(dut);
  expect_eq("full fetch queue backpressures request", 0, dut.req_ready_o);
  dut.init_valid_i = 1;
  dut.init_pc_i = 0x20;
  dut.init_word_i = 0;
  eval_low(dut);
  expect_eq("held fetch request blocks initializer", 0, dut.init_ready_o);
  dut.init_valid_i = 0;

  for (unsigned timeout = 0; timeout < 20 && !dut.rsp_valid_o; ++timeout)
    tick(dut);
  expect_eq("fetch head became eligible", 1, dut.rsp_valid_o);
  const Response wide_head = observe_response(dut);
  expect_eq("wide fetch count", 4, wide_head.count);
  expect_eq("wide fetch fault", kFaultNone, wide_head.fault);
  for (unsigned index = 0; index < 4; ++index)
    expect_eq("wide fetch word", program[index], wide_head.words[index]);
  dut.rsp_ready_i = 1;
  eval_low(dut);
  expect_eq("full queue exposes same-cycle replacement", 1,
            dut.req_ready_o);
  tick(dut);
  dut.req_valid_i = 0;
  dut.rsp_ready_i = 0;
  expect_eq("fetch pop plus push preserves count", 3,
            dut.outstanding_count_o);

  expect_response(dut,
                  Response{{program[4], program[5], 0, 0}, 2, kFaultNone},
                  "short fetch");
  expect_response(dut, Response{{0, 0, 0, 0}, 1, kFaultTranslation},
                  "translated fetch without translator");
  expect_response(dut, Response{{program[1], 0, 0, 0}, 1, kFaultNone},
                  "same-cycle replacement fetch");
  expect_eq("fetch queue drained", 1, dut.idle_o);

  // A fetch bundle may cross a future cache-line boundary.  This memory
  // endpoint models the logical request and does not invent a line limit.
  enqueue(dut, Request{0x2c, 4, kLocal, 0}, 1);
  expect_response(dut,
                  Response{{program[3], program[4], program[5], program[6]},
                           4, kFaultNone},
                  "line-agnostic logical fetch");

  enqueue(dut, Request{0x20, 1, kPhysical, 0}, 1);
  expect_response(dut, Response{{0, 0, 0, 0}, 1, kFaultAccess},
                  "unsupported physical fetch");
  enqueue(dut, Request{0x21, 1, kLocal, 0}, 1);
  expect_response(dut, Response{{0, 0, 0, 0}, 1, kFaultAccess},
                  "unaligned fetch");
  enqueue(dut, Request{0x1000, 1, kLocal, 0}, 1);
  expect_response(dut, Response{{0, 0, 0, 0}, 1, kFaultAccess},
                  "out-of-range fetch");
  enqueue(dut, Request{0x20, 0, kLocal, 0}, 1);
  expect_response(dut, Response{{0, 0, 0, 0}, 0, kFaultProtocol},
                  "zero-word fetch");
  enqueue(dut, Request{0x20, 5, kLocal, 0}, 1);
  expect_response(dut, Response{{0, 0, 0, 0}, 5, kFaultProtocol},
                  "oversized fetch");
  enqueue(dut, Request{0x20, 1, kUndefinedSpace, 0}, 1);
  expect_response(dut, Response{{0, 0, 0, 0}, 1, kFaultProtocol},
                  "undefined address space");

  dut.init_valid_i = 1;
  dut.init_pc_i = 0x21;
  dut.init_word_i = 0;
  eval_low(dut);
  expect_eq("unaligned initializer reports error", 1, dut.init_error_o);
  tick(dut);
  dut.init_valid_i = 0;

  // Fetch reset has transaction semantics and must not erase program memory.
  enqueue(dut, Request{0x20, 1, kLocal, 0}, 1);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
  expect_eq("reset drops queued fetch", 0, dut.outstanding_count_o);
  expect_peek(dut, 0x20, program[0]);

  std::cout << "vsp_ordered_ifetch_model_tb: " << checks
            << " checks passed\n";
  return 0;
}
