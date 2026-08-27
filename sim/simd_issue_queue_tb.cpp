#include "Vsimd_issue_queue.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>

namespace {

constexpr unsigned kContexts = 3;
constexpr unsigned kDepth = 3;
constexpr unsigned kFieldWidth = 8;
constexpr unsigned kCountWidth = 2;

struct Entry {
  uint8_t tag;
  uint8_t uword;
  uint8_t resolved;
  uint8_t sched_meta;
};

using Model = std::array<std::deque<Entry>, kContexts>;

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

uint32_t field(uint32_t packed, unsigned index, unsigned width) {
  return (packed >> (index * width)) & ((1u << width) - 1u);
}

void tick(Vsimd_issue_queue& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vsimd_issue_queue& dut) {
  dut.enq_valid_i = 0;
  dut.enq_context_i = 0;
  dut.enq_tag_i = 0;
  dut.enq_uword_i = 0;
  dut.enq_resolved_i = 0;
  dut.enq_sched_meta_i = 0;
  dut.head_ready_i = 0;
}

void drive_enqueue(Vsimd_issue_queue& dut, unsigned context,
                   const Entry& entry) {
  dut.enq_valid_i = 1;
  dut.enq_context_i = context;
  dut.enq_tag_i = entry.tag;
  dut.enq_uword_i = entry.uword;
  dut.enq_resolved_i = entry.resolved;
  dut.enq_sched_meta_i = entry.sched_meta;
}

void check_state(Vsimd_issue_queue& dut, const Model& model) {
  dut.eval();
  uint32_t expected_valid = 0;
  uint32_t expected_full = 0;
  uint32_t expected_occupancy = 0;

  for (unsigned context = 0; context < kContexts; ++context) {
    const bool valid = !model[context].empty();
    expected_valid |= uint32_t(valid) << context;
    expected_full |= uint32_t(model[context].size() == kDepth) << context;
    expected_occupancy |= uint32_t(model[context].size())
                          << (context * kCountWidth);

    if (valid) {
      const Entry& expected = model[context].front();
      expect_eq("head tag", expected.tag,
                field(dut.head_tag_o, context, kFieldWidth));
      expect_eq("head uword", expected.uword,
                field(dut.head_uword_o, context, kFieldWidth));
      expect_eq("head resolved", expected.resolved,
                field(dut.head_resolved_o, context, kFieldWidth));
      expect_eq("head sched meta", expected.sched_meta,
                field(dut.head_sched_meta_o, context, kFieldWidth));
    } else {
      expect_eq("empty head tag", 0,
                field(dut.head_tag_o, context, kFieldWidth));
      expect_eq("empty head uword", 0,
                field(dut.head_uword_o, context, kFieldWidth));
      expect_eq("empty head resolved", 0,
                field(dut.head_resolved_o, context, kFieldWidth));
      expect_eq("empty head sched meta", 0,
                field(dut.head_sched_meta_o, context, kFieldWidth));
    }
  }

  expect_eq("head valid", expected_valid, dut.head_valid_o);
  expect_eq("full", expected_full, dut.full_o);
  expect_eq("occupancy", expected_occupancy, dut.occupancy_o);

  const unsigned context = dut.enq_context_i;
  const bool context_valid = context < kContexts;
  const bool selected_pop = context_valid && !model[context].empty() &&
                            ((dut.head_ready_i >> context) & 1u);
  const bool expected_ready = dut.rst_ni && context_valid &&
                              (model[context].size() < kDepth ||
                               selected_pop);
  expect_eq("enqueue ready", expected_ready, dut.enq_ready_o);
  expect_eq("context error",
            dut.rst_ni && dut.enq_valid_i && !context_valid,
            dut.enq_context_error_o);
}

struct Fires {
  bool push;
  uint8_t pop_mask;
};

Fires update_model_from_inputs(Vsimd_issue_queue& dut, Model& model) {
  const unsigned context = dut.enq_context_i;
  const bool push = dut.enq_valid_i && dut.enq_ready_o;
  uint8_t pop_mask = 0;

  for (unsigned ctx = 0; ctx < kContexts; ++ctx) {
    if (!model[ctx].empty() && ((dut.head_ready_i >> ctx) & 1u)) {
      pop_mask |= 1u << ctx;
      model[ctx].pop_front();
    }
  }

  if (push) {
    model[context].push_back({static_cast<uint8_t>(dut.enq_tag_i),
                              static_cast<uint8_t>(dut.enq_uword_i),
                              static_cast<uint8_t>(dut.enq_resolved_i),
                              static_cast<uint8_t>(dut.enq_sched_meta_i)});
  }
  return {push, pop_mask};
}

Fires step(Vsimd_issue_queue& dut, Model& model) {
  check_state(dut, model);
  const Fires fires = update_model_from_inputs(dut, model);
  tick(dut);
  check_state(dut, model);
  return fires;
}

uint32_t next_random(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

unsigned popcount(uint8_t value) {
  unsigned count = 0;
  for (; value != 0; value >>= 1) count += value & 1u;
  return count;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_issue_queue dut;
  Model model;
  clear_inputs(dut);

  // Reset blocks transfers, clears ownership state, and does not require the
  // payload memories themselves to be reset.
  dut.rst_ni = 0;
  drive_enqueue(dut, 0, {1, 2, 3, 4});
  dut.head_ready_i = 0x7;
  dut.eval();
  expect_eq("enqueue blocked in reset", 0, dut.enq_ready_o);
  expect_eq("heads invalid in reset", 0, dut.head_valid_o);
  tick(dut);
  dut.rst_ni = 1;
  clear_inputs(dut);
  check_state(dut, model);

  // Empty queues do not bypass a simultaneous ready request. The pushed entry
  // becomes visible only after the edge.
  drive_enqueue(dut, 0, {0x10, 0x20, 0x30, 0x40});
  dut.head_ready_i = 0x1;
  dut.eval();
  expect_eq("no empty fallthrough", 0, dut.head_valid_o & 0x1u);
  step(dut, model);
  clear_inputs(dut);
  check_state(dut, model);

  // Hold the head and prove all entry fields remain stable.
  for (unsigned stall = 0; stall < 4; ++stall) {
    tick(dut);
    check_state(dut, model);
  }

  // Fill context 0, then replace its oldest entry without a bubble while the
  // queue is full. The old head transfers; the new entry joins the tail.
  drive_enqueue(dut, 0, {0x11, 0x21, 0x31, 0x41});
  step(dut, model);
  drive_enqueue(dut, 0, {0x12, 0x22, 0x32, 0x42});
  step(dut, model);
  drive_enqueue(dut, 0, {0x13, 0x23, 0x33, 0x43});
  dut.eval();
  expect_eq("full queue blocks push", 0, dut.enq_ready_o);
  check_state(dut, model);
  dut.head_ready_i = 0x1;
  dut.eval();
  expect_eq("full queue accepts replacement", 1, dut.enq_ready_o);
  step(dut, model);
  clear_inputs(dut);
  check_state(dut, model);

  // Independent contexts may retire their heads together while context 0 is
  // left untouched.
  drive_enqueue(dut, 1, {0x50, 0x60, 0x70, 0x80});
  step(dut, model);
  drive_enqueue(dut, 2, {0x51, 0x61, 0x71, 0x81});
  step(dut, model);
  clear_inputs(dut);
  dut.head_ready_i = 0x6;
  const Fires multi_pop = step(dut, model);
  expect_eq("two contexts popped together", 0x6, multi_pop.pop_mask);
  clear_inputs(dut);

  // Context encoding 3 is a hole for CONTEXT_COUNT=3. This deliberate one-cycle
  // diagnostic probe is not a retryable ready/valid producer transaction: the
  // raw FIFO refuses it, and an upstream admission stage owns error retire.
  drive_enqueue(dut, 3, {0xaa, 0xbb, 0xcc, 0xdd});
  dut.eval();
  expect_eq("invalid context refused", 0, dut.enq_ready_o);
  expect_eq("invalid context diagnostic", 1, dut.enq_context_error_o);
  tick(dut);
  clear_inputs(dut);
  check_state(dut, model);

  // Exercise pointer wrap repeatedly by draining and refilling every context.
  for (unsigned round = 0; round < 8; ++round) {
    for (unsigned context = 0; context < kContexts; ++context) {
      while (model[context].size() < kDepth) {
        const uint8_t base = static_cast<uint8_t>(0x20u * round +
                                                  4u * context +
                                                  model[context].size());
        drive_enqueue(dut, context,
                      {base, uint8_t(base + 1), uint8_t(base + 2),
                       uint8_t(base + 3)});
        step(dut, model);
      }
    }
    clear_inputs(dut);
    dut.head_ready_i = 0x7;
    for (unsigned item = 0; item < kDepth; ++item) step(dut, model);
    clear_inputs(dut);
  }

  // A reset with live entries clears only queue ownership/occupancy.
  drive_enqueue(dut, 2, {0xe1, 0xe2, 0xe3, 0xe4});
  step(dut, model);
  dut.rst_ni = 0;
  dut.eval();
  for (auto& queue : model) queue.clear();
  check_state(dut, model);
  tick(dut);
  dut.rst_ni = 1;
  clear_inputs(dut);
  check_state(dut, model);

  // Randomized ready/valid with a behavioral deque oracle. A valid request is
  // held stable while backpressured, as required by the producer contract.
  uint32_t rng = 0x93d7a41bu;
  uint32_t sequence = 0;
  bool pending = false;
  unsigned pending_context = 0;
  Entry pending_entry{};
  unsigned pushes = 0;
  unsigned pops = 0;
  unsigned backpressured = 0;
  unsigned full_replacements = 0;
  unsigned multi_context_pops = 0;
  unsigned invalid_contexts = 0;

  constexpr unsigned kRandomCycles = 100000;
  for (unsigned cycle = 0; cycle < kRandomCycles; ++cycle) {
    clear_inputs(dut);
    dut.head_ready_i = next_random(rng) & 0x7u;

    bool one_cycle_invalid = false;
    if (!pending && (next_random(rng) & 0x1fu) == 0) {
      one_cycle_invalid = true;
      drive_enqueue(dut, 3, {uint8_t(sequence), uint8_t(sequence + 1),
                             uint8_t(sequence + 2),
                             uint8_t(sequence + 3)});
      ++invalid_contexts;
    } else {
      if (!pending && (next_random(rng) & 3u) != 0) {
        pending = true;
        pending_context = next_random(rng) % kContexts;
        pending_entry = {uint8_t(sequence), uint8_t(sequence * 3u + 1u),
                         uint8_t(sequence * 5u + 2u),
                         uint8_t(sequence * 7u + 3u)};
        ++sequence;
      }
      if (pending) drive_enqueue(dut, pending_context, pending_entry);
    }

    check_state(dut, model);
    const bool was_full = !one_cycle_invalid && pending &&
                          model[pending_context].size() == kDepth;
    const bool selected_pop = !one_cycle_invalid && pending &&
        !model[pending_context].empty() &&
        ((dut.head_ready_i >> pending_context) & 1u);
    const bool stalled = dut.enq_valid_i && !dut.enq_ready_o;
    const Fires fires = update_model_from_inputs(dut, model);
    if (fires.push) {
      ++pushes;
      pending = false;
      if (was_full && selected_pop) ++full_replacements;
    } else if (stalled && !one_cycle_invalid) {
      ++backpressured;
    }
    pops += popcount(fires.pop_mask);
    if (popcount(fires.pop_mask) >= 2) ++multi_context_pops;

    tick(dut);
    check_state(dut, model);
  }

  // Stop admitting, then retire every remaining entry.
  pending = false;
  clear_inputs(dut);
  dut.head_ready_i = 0x7;
  while (!model[0].empty() || !model[1].empty() || !model[2].empty()) {
    const Fires fires = step(dut, model);
    pops += popcount(fires.pop_mask);
  }
  clear_inputs(dut);
  check_state(dut, model);

  expect_eq("random covered pushes", 1, pushes != 0);
  expect_eq("random covered pops", 1, pops != 0);
  expect_eq("random covered backpressure", 1, backpressured != 0);
  expect_eq("random covered full replacement", 1, full_replacements != 0);
  expect_eq("random covered multi-context pop", 1,
            multi_context_pops != 0);
  expect_eq("random covered invalid context", 1, invalid_contexts != 0);

  dut.final();
  std::cout << "PASS: " << checks
            << " hybrid issue queue checks across ordered per-context heads, "
               "elastic replacement, wraparound, reset, and randomized "
               "backpressure\n";
  return 0;
}
