#include "Vvsp_uword_program_source.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr int kBundleWords = 4;
uint64_t checks = 0;

[[noreturn]] void fail(const std::string& name, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << name << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& name, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(name, expected, actual);
}

void eval_low(Vvsp_uword_program_source& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_uword_program_source& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_uword_program_source& dut) {
  dut.start_valid_i = 0;
  dut.start_pc_i = 0;
  dut.end_pc_i = 0;
  dut.redirect_valid_i = 0;
  dut.redirect_pc_i = 0;
  dut.store_req_ready_i = 0;
  dut.store_rsp_valid_i = 0;
  dut.store_rsp_fault_i = 0;
  for (int word = 0; word < kBundleWords; ++word)
    dut.store_rsp_words_i[word] = 0;
  dut.bundle_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_uword_program_source& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  expect_eq("reset start ready", 1, dut.start_ready_o);
  expect_eq("reset redirect ready", 1, dut.redirect_ready_o);
  expect_eq("reset not running", 0, dut.running_o);
  expect_eq("reset no bundle", 0, dut.bundle_valid_o);
  expect_eq("reset no error", 0, dut.protocol_error_o);
}

void launch(Vvsp_uword_program_source& dut, uint32_t start_pc,
            uint32_t end_pc) {
  dut.start_valid_i = 1;
  dut.start_pc_i = start_pc;
  dut.end_pc_i = end_pc;
  eval_low(dut);
  expect_eq("launch ready", 1, dut.start_ready_o);
  tick(dut);
  dut.start_valid_i = 0;
  eval_low(dut);
  expect_eq("launch PC", start_pc, dut.current_pc_o);
}

void accept_request(Vvsp_uword_program_source& dut, uint32_t pc,
                    uint8_t words) {
  eval_low(dut);
  expect_eq("request valid", 1, dut.store_req_valid_o);
  expect_eq("request PC", pc, dut.store_req_pc_o);
  expect_eq("request word count", words, dut.store_req_word_count_o);
  dut.store_req_ready_i = 1;
  tick(dut);
  dut.store_req_ready_i = 0;
  eval_low(dut);
  expect_eq("response ready after request", 1, dut.store_rsp_ready_o);
}

void return_response(Vvsp_uword_program_source& dut, bool fault,
                     uint32_t seed) {
  dut.store_rsp_valid_i = 1;
  dut.store_rsp_fault_i = fault;
  for (int word = 0; word < kBundleWords; ++word)
    dut.store_rsp_words_i[word] = seed + static_cast<uint32_t>(word);
  eval_low(dut);
  expect_eq("response accepted", 1, dut.store_rsp_ready_o);
  tick(dut);
  dut.store_rsp_valid_i = 0;
  dut.store_rsp_fault_i = 0;
}

void redirect(Vvsp_uword_program_source& dut, uint32_t pc) {
  dut.redirect_valid_i = 1;
  dut.redirect_pc_i = pc;
  eval_low(dut);
  expect_eq("redirect ready", 1, dut.redirect_ready_o);
  tick(dut);
  dut.redirect_valid_i = 0;
  eval_low(dut);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_uword_program_source dut;

  // A held response bundle is never transferred in the redirect cycle.  The
  // new PC immediately becomes the next request address.
  reset(dut);
  launch(dut, 0x100, 0x120);
  accept_request(dut, 0x100, 4);
  return_response(dut, false, 0x11110000U);
  expect_eq("old bundle held", 1, dut.bundle_valid_o);
  expect_eq("old bundle base", 0x100, dut.bundle_base_pc_o);
  dut.bundle_ready_i = 1;
  dut.redirect_valid_i = 1;
  dut.redirect_pc_i = 0x110;
  eval_low(dut);
  expect_eq("held bundle suppressed by redirect", 0, dut.bundle_valid_o);
  tick(dut);
  dut.redirect_valid_i = 0;
  dut.bundle_ready_i = 0;
  eval_low(dut);
  expect_eq("held bundle discarded", 0, dut.bundle_valid_o);
  expect_eq("redirected PC", 0x110, dut.current_pc_o);
  expect_eq("redirect resumes source", 1, dut.running_o);
  expect_eq("redirect target request valid", 1, dut.store_req_valid_o);
  expect_eq("redirect target request PC", 0x110, dut.store_req_pc_o);
  expect_eq("redirect target request words", 4,
            dut.store_req_word_count_o);

  // An accepted old request cannot be cancelled.  Redirect poisons exactly
  // that response, including its fault, then issues from the target.
  reset(dut);
  launch(dut, 0x100, 0x140);
  accept_request(dut, 0x100, 4);
  redirect(dut, 0x120);
  expect_eq("poison blocks target request", 0, dut.store_req_valid_o);
  expect_eq("poison keeps response drainable", 1, dut.store_rsp_ready_o);
  return_response(dut, true, 0xdead0000U);
  eval_low(dut);
  expect_eq("poisoned fault is discarded", 0, dut.store_fault_o);
  expect_eq("poisoned data is discarded", 0, dut.bundle_valid_o);
  expect_eq("target request follows poison", 1, dut.store_req_valid_o);
  expect_eq("target request follows poison PC", 0x120,
            dut.store_req_pc_o);

  // A later-path fetch fault may become visible while an older branch waits
  // to resolve.  Committing that branch makes the fault speculative and
  // restarts fetch from the selected target.
  reset(dut);
  launch(dut, 0x100, 0x140);
  accept_request(dut, 0x100, 4);
  return_response(dut, true, 0);
  eval_low(dut);
  expect_eq("visible fetch fault stops source", 1, dut.store_fault_o);
  expect_eq("visible fetch fault has no request", 0, dut.store_req_valid_o);
  redirect(dut, 0x110);
  expect_eq("redirect clears speculative fetch fault", 0,
            dut.store_fault_o);
  expect_eq("redirect after fault restarts request", 1,
            dut.store_req_valid_o);
  expect_eq("redirect after fault request PC", 0x110,
            dut.store_req_pc_o);

  // A response racing the redirect is stale in the same way and must not set
  // store_fault or become visible for one cycle.
  reset(dut);
  launch(dut, 0x100, 0x140);
  accept_request(dut, 0x100, 4);
  dut.store_rsp_valid_i = 1;
  dut.store_rsp_fault_i = 1;
  dut.redirect_valid_i = 1;
  dut.redirect_pc_i = 0x130;
  eval_low(dut);
  expect_eq("racing response ready", 1, dut.store_rsp_ready_o);
  expect_eq("racing redirect ready", 1, dut.redirect_ready_o);
  tick(dut);
  dut.store_rsp_valid_i = 0;
  dut.store_rsp_fault_i = 0;
  dut.redirect_valid_i = 0;
  eval_low(dut);
  expect_eq("racing stale response no fault", 0, dut.store_fault_o);
  expect_eq("racing stale response no bundle", 0, dut.bundle_valid_o);
  expect_eq("racing redirect target request", 1, dut.store_req_valid_o);
  expect_eq("racing redirect target PC", 0x130, dut.store_req_pc_o);

  // The launch range remains available after physical EOF, allowing a later
  // redirect to restart an earlier word without a new launch transaction.
  reset(dut);
  launch(dut, 0x100, 0x110);
  accept_request(dut, 0x100, 4);
  return_response(dut, false, 0x22220000U);
  dut.bundle_ready_i = 1;
  tick(dut);
  dut.bundle_ready_i = 0;
  eval_low(dut);
  expect_eq("EOF stops source", 0, dut.running_o);
  expect_eq("EOF delivery pulse", 1, dut.delivery_done_o);
  tick(dut);
  expect_eq("EOF delivery pulse clears", 0, dut.delivery_done_o);
  redirect(dut, 0x108);
  expect_eq("post-EOF redirect PC", 0x108, dut.current_pc_o);
  expect_eq("post-EOF redirect restarts", 1, dut.running_o);
  expect_eq("post-EOF target request", 1, dut.store_req_valid_o);
  expect_eq("post-EOF remaining words", 2, dut.store_req_word_count_o);

  // end_pc itself is a legal empty tail.  It reports delivery exactly once,
  // while any old request is still safely drained in the background.
  reset(dut);
  launch(dut, 0x100, 0x120);
  accept_request(dut, 0x100, 4);
  redirect(dut, 0x120);
  expect_eq("redirect-to-end PC", 0x120, dut.current_pc_o);
  expect_eq("redirect-to-end delivery", 1, dut.delivery_done_o);
  expect_eq("redirect-to-end no request", 0, dut.store_req_valid_o);
  expect_eq("redirect-to-end drains stale request", 1,
            dut.store_rsp_ready_o);
  return_response(dut, true, 0xbeef0000U);
  eval_low(dut);
  expect_eq("redirect-to-end stale fault discarded", 0, dut.store_fault_o);
  expect_eq("redirect-to-end fully stops after drain", 0, dut.running_o);
  expect_eq("redirect-to-end delivery is one pulse", 0,
            dut.delivery_done_o);

  // Range and alignment errors are diagnosed but do not replace the current
  // source PC or destroy its sequential request state.
  reset(dut);
  launch(dut, 0x100, 0x120);
  redirect(dut, 0x124);
  expect_eq("out-of-range redirect error", 1, dut.protocol_error_o);
  expect_eq("out-of-range redirect keeps PC", 0x100, dut.current_pc_o);
  expect_eq("out-of-range redirect keeps request", 1,
            dut.store_req_valid_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("redirect error explicit clear", 0, dut.protocol_error_o);

  dut.final();
  std::cout << "vsp_uword_program_source_tb: " << std::dec << checks
            << " redirect, poison, held-bundle and EOF checks passed\n";
  return 0;
}
