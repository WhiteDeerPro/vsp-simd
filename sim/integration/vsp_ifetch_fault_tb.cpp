// SPDX-License-Identifier: MIT

#include "Vvsp_ifetch_fault_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using Dut = Vvsp_ifetch_fault_tb_top;
constexpr unsigned kFaultNone = 0;
constexpr unsigned kFaultPermission = 2;
constexpr unsigned kFaultAccess = 3;
constexpr unsigned kAccessFetch = 2;
constexpr unsigned kTimeout = 128;

std::string phase = "reset";
std::uint64_t cycles = 0;
std::uint64_t checks = 0;
unsigned source_requests = 0;
unsigned source_responses = 0;
unsigned mmu_requests = 0;
unsigned mmu_responses = 0;

void expect_eq(const std::string& label, std::uint64_t expected,
               std::uint64_t actual) {
  ++checks;
  if (expected == actual) return;
  std::cerr << "FAIL " << phase << ": " << label << " cycle=" << cycles
            << " expected=0x" << std::hex << expected << " actual=0x" << actual
            << std::dec << '\n';
  std::exit(EXIT_FAILURE);
}

void expect_clean_metadata(const Dut& dut) {
  expect_eq("clean fault cause", kFaultNone, dut.source_rsp_fault_cause_o);
  expect_eq("clean fault eaddr", 0, dut.source_rsp_fault_eaddr_o);
  expect_eq("clean fault paddr", 0, dut.source_rsp_fault_paddr_o);
}

void eval_low(Dut& dut) {
  dut.clk_i = 0;
  dut.eval();
  expect_eq("no lower request for pre-cache faults", 0, dut.lower_request_o);
  expect_eq("no protocol error", 0, dut.protocol_error_o);
  if (!dut.source_rsp_valid_o || !dut.source_rsp_fault_o)
    expect_clean_metadata(dut);
}

void tick(Dut& dut) {
  eval_low(dut);
  if (dut.rst_ni) {
    source_requests += dut.source_req_valid_i && dut.source_req_ready_o;
    source_responses += dut.source_rsp_valid_o && dut.source_rsp_ready_i;
    mmu_requests += dut.i_tr_req_valid_o && dut.i_tr_req_ready_i;
    mmu_responses += dut.i_tr_rsp_valid_i && dut.i_tr_rsp_ready_o;
  }
  dut.clk_i = 1;
  dut.eval();
  ++cycles;
  eval_low(dut);
}

template <typename Predicate>
void wait_for(Dut& dut, Predicate predicate, const std::string& label) {
  for (unsigned waited = 0; waited < kTimeout; ++waited) {
    eval_low(dut);
    if (predicate()) return;
    tick(dut);
  }
  std::cerr << "FAIL " << phase << ": timeout waiting for " << label << '\n';
  std::exit(EXIT_FAILURE);
}

void reset(Dut& dut) {
  dut.rst_ni = 0;
  dut.source_admit_enable_i = 0;
  dut.redirect_commit_i = 0;
  dut.source_addr_context_i = 0;
  dut.source_req_valid_i = 0;
  dut.source_req_pc_i = 0;
  dut.source_req_word_count_i = 0;
  dut.source_rsp_ready_i = 0;
  dut.i_tr_req_ready_i = 0;
  dut.i_tr_rsp_valid_i = 0;
  dut.i_tr_rsp_paddr_i = 0;
  dut.i_tr_rsp_fault_i = kFaultNone;
  dut.i_tr_rsp_fault_vaddr_i = 0;
  for (unsigned cycle = 0; cycle < 3; ++cycle) tick(dut);
  expect_eq("source blocked during reset", 0, dut.source_req_ready_o);
  expect_eq("no source response during reset", 0, dut.source_rsp_valid_o);
  dut.rst_ni = 1;
  dut.source_admit_enable_i = 1;
  wait_for(dut, [&]() { return dut.ready_o && dut.quiescent_o; },
           "real cache initialization");
  expect_eq("cache initialized", 1, dut.icache_init_done_o);
}

// Accept one source request, stall its public MMU request, then accept that
// request.  Input valid and payload are held until their own handshake.
void begin_request(Dut& dut, std::uint32_t pc, unsigned context) {
  dut.source_req_pc_i = pc;
  dut.source_req_word_count_i = 4;
  dut.source_addr_context_i = context;
  dut.source_req_valid_i = 1;
  wait_for(dut, [&]() { return dut.source_req_ready_o; }, "source acceptance");
  tick(dut);
  dut.source_req_valid_i = 0;
  // Accepted work must use its captured address and context.
  dut.source_req_pc_i = 0xdeadbeec;
  dut.source_req_word_count_i = 1;
  dut.source_addr_context_i = context ^ 0xff;
  wait_for(dut, [&]() { return dut.i_tr_req_valid_o; }, "MMU request");
  for (unsigned stalled = 0; stalled < 3; ++stalled) {
    expect_eq("MMU request remains valid", 1, dut.i_tr_req_valid_o);
    expect_eq("captured request PC", pc, dut.i_tr_req_vaddr_o);
    expect_eq("captured request context", context, dut.i_tr_req_addr_context_o);
    expect_eq("instruction access kind", kAccessFetch, dut.i_tr_req_access_o);
    expect_eq("no premature source response", 0, dut.source_rsp_valid_o);
    tick(dut);
  }
  dut.i_tr_req_ready_i = 1;
  tick(dut);
  dut.i_tr_req_ready_i = 0;
  eval_low(dut);
  expect_eq("MMU request consumed once", 0, dut.i_tr_req_valid_o);
}

void send_mmu_response(Dut& dut, std::uint32_t pc, unsigned fault,
                       std::uint64_t paddr) {
  dut.i_tr_rsp_fault_vaddr_i = pc;
  dut.i_tr_rsp_fault_i = fault;
  dut.i_tr_rsp_paddr_i = paddr;
  dut.i_tr_rsp_valid_i = 1;
  wait_for(dut, [&]() { return dut.i_tr_rsp_ready_o; }, "MMU response acceptance");
  tick(dut);
  dut.i_tr_rsp_valid_i = 0;
  // Invalid bus values may change immediately after response acceptance.
  dut.i_tr_rsp_fault_vaddr_i = 0xbad0bad0;
  dut.i_tr_rsp_fault_i = kFaultAccess;
  dut.i_tr_rsp_paddr_i = 0xee87654000ULL;
  eval_low(dut);
}

void expect_response(const Dut& dut, bool fault, unsigned cause,
                     std::uint32_t pc, std::uint64_t paddr) {
  expect_eq("source completion stays valid", 1, dut.source_rsp_valid_o);
  expect_eq("source fault bit", fault, dut.source_rsp_fault_o);
  expect_eq("source fault cause", cause, dut.source_rsp_fault_cause_o);
  expect_eq("source fault eaddr", pc, dut.source_rsp_fault_eaddr_o);
  expect_eq("source fault paddr", paddr, dut.source_rsp_fault_paddr_o);
  for (unsigned word = 0; word < 4; ++word)
    expect_eq("fault/stale response words are zero", 0, dut.source_rsp_words_o[word]);
}

void hold_response(Dut& dut, bool fault, unsigned cause, std::uint32_t pc,
                   std::uint64_t paddr, unsigned hold_cycles = 5) {
  expect_eq("source response backpressured", 0, dut.source_rsp_ready_i);
  wait_for(dut, [&]() { return dut.source_rsp_valid_o; }, "source response");
  for (unsigned held = 0; held < hold_cycles; ++held) {
    expect_response(dut, fault, cause, pc, paddr);
    tick(dut);
  }
  expect_response(dut, fault, cause, pc, paddr);
}

void consume_response(Dut& dut) {
  dut.source_rsp_ready_i = 1;
  tick(dut);
  dut.source_rsp_ready_i = 0;
  wait_for(dut, [&]() { return dut.quiescent_o; }, "complete downstream drain");
  expect_eq("bridge released source obligation", 1, dut.bridge_idle_o);
  expect_eq("completion consumed once", 0, dut.source_rsp_valid_o);
  expect_eq("source request/response balance", source_requests, source_responses);
  expect_eq("MMU request/response balance", mmu_requests, mmu_responses);
  expect_clean_metadata(dut);
  for (unsigned idle = 0; idle < 2; ++idle) {
    tick(dut);
    expect_eq("no duplicate source completion", 0, dut.source_rsp_valid_o);
  }
}

void live_mmu_fault(Dut& dut, const std::string& label, std::uint32_t pc,
                    unsigned context, unsigned cause) {
  phase = label;
  begin_request(dut, pc, context);
  send_mmu_response(dut, pc, cause, 0xa512340000ULL | (pc & 0xfff));
  // MMU faults have no translated physical address in the canonical ABI.
  hold_response(dut, true, cause, pc, 0);
  consume_response(dut);
}

void live_region_fault(Dut& dut) {
  phase = "live ACCESS with 40-bit paddr";
  constexpr std::uint32_t pc = 0x2028;
  constexpr std::uint64_t paddr = 0xa712342028ULL;
  begin_request(dut, pc, 0x42);
  send_mmu_response(dut, pc, kFaultNone, paddr);
  hold_response(dut, true, kFaultAccess, pc, paddr);
  consume_response(dut);
}

void redirect_while_waiting(Dut& dut) {
  phase = "redirect during MMU wait";
  constexpr std::uint32_t pc = 0x303c;
  begin_request(dut, pc, 0x53);
  dut.source_admit_enable_i = 0;
  dut.redirect_commit_i = 1;
  tick(dut);
  dut.redirect_commit_i = 0;
  for (unsigned waiting = 0; waiting < 3; ++waiting) {
    tick(dut);
    expect_eq("redirect preserves pending source obligation", 0, dut.bridge_idle_o);
    expect_eq("no completion before MMU response", 0, dut.source_rsp_valid_o);
  }
  send_mmu_response(dut, pc, kFaultPermission, 0xb81234303cULL);
  hold_response(dut, false, kFaultNone, 0, 0);
  consume_response(dut);
  dut.source_admit_enable_i = 1;
}

void redirect_held_response(Dut& dut) {
  phase = "redirect while ACCESS response is held";
  constexpr std::uint32_t pc = 0x500c;
  constexpr std::uint64_t paddr = 0xc91234500cULL;
  begin_request(dut, pc, 0x75);
  send_mmu_response(dut, pc, kFaultNone, paddr);
  hold_response(dut, true, kFaultAccess, pc, paddr, 2);
  dut.redirect_commit_i = 1;
  eval_low(dut);
  // Same-cycle combinational sanitization precedes the next clock edge.
  expect_response(dut, false, kFaultNone, 0, 0);
  tick(dut);
  dut.redirect_commit_i = 0;
  eval_low(dut);
  hold_response(dut, false, kFaultNone, 0, 0);
  consume_response(dut);
}

void redirect_response_capture(Dut& dut) {
  phase = "redirect on response capture edge";
  constexpr std::uint32_t pc = 0x7024;
  begin_request(dut, pc, 0x97);
  send_mmu_response(dut, pc, kFaultAccess, 0xda12347024ULL);
  // A fault accepted from the MMU produces the canonical response; the bridge
  // captures it on the following edge.  Only public MMU/source pins arrange
  // and check this timing; there is no hierarchy access or forced signal.
  expect_eq("capture edge has not occurred", 0, dut.source_rsp_valid_o);
  dut.redirect_commit_i = 1;
  eval_low(dut);
  expect_eq("no response before capture", 0, dut.source_rsp_valid_o);
  tick(dut);
  expect_response(dut, false, kFaultNone, 0, 0);
  dut.redirect_commit_i = 0;
  eval_low(dut);
  hold_response(dut, false, kFaultNone, 0, 0);
  consume_response(dut);
}

}  // namespace

double sc_time_stamp() { return static_cast<double>(cycles); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Dut dut;
  reset(dut);
  live_mmu_fault(dut, "live PERMISSION under backpressure", 0x1004, 0x31,
                 kFaultPermission);
  live_region_fault(dut);
  redirect_while_waiting(dut);
  live_mmu_fault(dut, "live ACCESS after wait redirect", 0x4000, 0x64,
                 kFaultAccess);
  redirect_held_response(dut);
  live_mmu_fault(dut, "live PERMISSION after held redirect", 0x6040, 0x86,
                 kFaultPermission);
  redirect_response_capture(dut);
  live_mmu_fault(dut, "live PERMISSION after capture redirect", 0x8038, 0xa8,
                 kFaultPermission);
  expect_eq("eight source requests completed", 8, source_responses);
  expect_eq("one MMU transaction per source request", source_requests, mmu_requests);
  dut.final();
  std::cout << "PASS I-side fault metadata: live backpressure, 40-bit paddr, "
               "three redirect timings, and fresh requests ("
            << checks << " checks, " << cycles << " cycles)\n";
  return EXIT_SUCCESS;
}
