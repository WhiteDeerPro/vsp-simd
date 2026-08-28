#include "Vsimd_issue_decode_stage.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <random>

namespace {

struct Entry {
  uint16_t raw;
  uint8_t resolved;
  uint8_t cached;
  uint8_t context;
  uint8_t tag;
  uint8_t dispatch_class;
  uint8_t response_kind;
  uint8_t group_mask;
  uint8_t resource;
  uint16_t payload;
  uint8_t decode_meta;
  uint8_t legal;
  uint8_t error_cause;
};

uint64_t checks = 0;

[[noreturn]] void fail(const char* field, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << field << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const char* field, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(field, expected, actual);
}

void eval_low(Vsimd_issue_decode_stage& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vsimd_issue_decode_stage& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vsimd_issue_decode_stage& dut) {
  dut.in_valid_i = 0;
  dut.in_raw_word_i = 0;
  dut.in_resolved_i = 0;
  dut.in_cached_meta_i = 0;
  dut.in_context_i = 0;
  dut.in_tag_i = 0;
  dut.hook_dispatch_class_i = 0;
  dut.hook_response_kind_i = 0;
  dut.hook_group_mask_i = 0;
  dut.hook_exact_resource_i = 0;
  dut.hook_canonical_payload_i = 0;
  dut.hook_decode_meta_i = 0;
  dut.hook_legal_i = 0;
  dut.hook_error_cause_i = 0;
  dut.out_ready_i = 0;
}

void drive(Vsimd_issue_decode_stage& dut, const Entry& entry) {
  dut.in_valid_i = 1;
  dut.in_raw_word_i = entry.raw;
  dut.in_resolved_i = entry.resolved;
  dut.in_cached_meta_i = entry.cached;
  dut.in_context_i = entry.context;
  dut.in_tag_i = entry.tag;
  dut.hook_dispatch_class_i = entry.dispatch_class;
  dut.hook_response_kind_i = entry.response_kind;
  dut.hook_group_mask_i = entry.group_mask;
  dut.hook_exact_resource_i = entry.resource;
  dut.hook_canonical_payload_i = entry.payload;
  dut.hook_decode_meta_i = entry.decode_meta;
  dut.hook_legal_i = entry.legal;
  dut.hook_error_cause_i = entry.error_cause;
}

void expect_entry(Vsimd_issue_decode_stage& dut, const Entry& entry) {
  expect_eq("out valid", 1, dut.out_valid_o);
  expect_eq("raw provenance", entry.raw, dut.out_raw_word_o);
  expect_eq("resolved", entry.resolved, dut.out_resolved_o);
  expect_eq("cached metadata", entry.cached, dut.out_cached_meta_o);
  expect_eq("context", entry.context, dut.out_context_o);
  expect_eq("tag", entry.tag, dut.out_tag_o);
  expect_eq("dispatch class", entry.dispatch_class,
            dut.out_dispatch_class_o);
  expect_eq("response kind", entry.response_kind,
            dut.out_response_kind_o);
  expect_eq("group mask", entry.group_mask, dut.out_group_mask_o);
  expect_eq("exact resource", entry.resource, dut.out_exact_resource_o);
  expect_eq("canonical payload", entry.payload,
            dut.out_canonical_payload_o);
  expect_eq("decode metadata", entry.decode_meta, dut.out_decode_meta_o);
  expect_eq("legal", entry.legal, dut.out_legal_o);
  expect_eq("error cause", entry.error_cause, dut.out_error_cause_o);
}

Entry random_entry(std::mt19937& rng) {
  Entry entry{};
  entry.raw = rng() & 0xfff;
  entry.resolved = rng() & 0x7f;
  entry.cached = rng() & 0x3f;
  entry.context = rng() & 0x3;
  entry.tag = rng() & 0xff;
  entry.dispatch_class = rng() & 0x3;
  entry.response_kind = rng() & 0x3;
  entry.group_mask = rng() & 0xf;
  entry.resource = rng() & 0x1f;
  entry.payload = rng() & 0xffff;
  entry.decode_meta = rng() & 0x7f;
  entry.legal = rng() & 0x1;
  entry.error_cause = rng() & 0x7;
  return entry;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_issue_decode_stage dut;
  clear_inputs(dut);

  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
  expect_eq("empty after reset", 0, dut.out_valid_o);
  expect_eq("ready after reset", 1, dut.in_ready_o);

  const Entry first{0xa35, 0x52, 0x21, 2, 0x91, 0, 2, 0xb,
                    0x15, 0xcafe, 0x6a, 1, 0};
  drive(dut, first);
  eval_low(dut);
  expect_eq("no combinational fallthrough", 0, dut.out_valid_o);
  expect_eq("empty accepts", 1, dut.in_ready_o);
  tick(dut);
  expect_entry(dut, first);

  // Backpressure freezes every decoded field even if both raw and hook inputs
  // change.  An illegal reference record is deliberately included here: the
  // The stage transports decoder decisions but does not reinterpret them.
  const Entry blocked{0x17c, 0x03, 0x3e, 1, 0x22, 3, 1, 0,
                      0x03, 0x1234, 0x11, 0, 5};
  drive(dut, blocked);
  dut.out_ready_i = 0;
  for (int cycle = 0; cycle < 5; ++cycle) {
    eval_low(dut);
    expect_eq("blocked input ready", 0, dut.in_ready_o);
    expect_entry(dut, first);
    tick(dut);
  }

  // Consume and replace in one cycle.  The old record is the transaction
  // visible before the edge and the new record owns the stage afterward.
  dut.out_ready_i = 1;
  eval_low(dut);
  expect_eq("replacement ready", 1, dut.in_ready_o);
  expect_entry(dut, first);
  tick(dut);
  dut.out_ready_i = 0;
  expect_entry(dut, blocked);

  clear_inputs(dut);
  dut.out_ready_i = 1;
  tick(dut);
  eval_low(dut);
  expect_eq("bubble clears valid", 0, dut.out_valid_o);
  expect_eq("bubble leaves stage ready", 1, dut.in_ready_o);

  // Random valid/ready traffic checks ordering, losslessness and one-entry
  // elastic replacement over long stalls and back-to-back transfers.
  std::mt19937 rng(0x5eeda11u);
  std::deque<Entry> expected;
  for (int cycle = 0; cycle < 20000; ++cycle) {
    const bool drive_valid = (rng() % 5) != 0;
    const bool sink_ready = (rng() % 4) != 0;
    const Entry candidate = random_entry(rng);

    if (drive_valid) drive(dut, candidate);
    else {
      dut.in_valid_i = 0;
      // Toggle unused candidate fields to make accidental capture observable.
      const Entry noise = random_entry(rng);
      drive(dut, noise);
      dut.in_valid_i = 0;
    }
    dut.out_ready_i = sink_ready;
    eval_low(dut);

    expect_eq("model valid", !expected.empty(), dut.out_valid_o);
    if (!expected.empty()) expect_entry(dut, expected.front());

    const bool pop = dut.out_valid_o && dut.out_ready_i;
    const bool push = dut.in_valid_i && dut.in_ready_o;
    if (pop) expected.pop_front();
    if (push) expected.push_back(candidate);
    expect_eq("single-entry bound", expected.size() <= 1, 1);
    tick(dut);
  }

  clear_inputs(dut);
  dut.out_ready_i = 1;
  while (!expected.empty()) {
    eval_low(dut);
    expect_entry(dut, expected.front());
    expected.pop_front();
    tick(dut);
  }
  eval_low(dut);
  expect_eq("drained", 0, dut.out_valid_o);

  // Asynchronous reset revokes ownership immediately, including while the
  // canonical record is stalled.
  drive(dut, first);
  dut.out_ready_i = 0;
  tick(dut);
  expect_entry(dut, first);
  dut.rst_ni = 0;
  eval_low(dut);
  expect_eq("async reset valid", 0, dut.out_valid_o);
  expect_eq("reset blocks input ready", 0, dut.in_ready_o);
  tick(dut);

  dut.final();
  std::cout << "PASS: " << checks
            << " issue-decode stage checks across reference adaptation, "
               "canonical hold stability, elastic replacement, randomized "
               "backpressure, illegal metadata transport and reset\n";
  return 0;
}
