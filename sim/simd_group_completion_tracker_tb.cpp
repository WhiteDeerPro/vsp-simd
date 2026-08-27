#include "Vsimd_group_completion_tracker.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kSlots = 2;
constexpr unsigned kContexts = 2;

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

unsigned field(uint32_t packed, unsigned index, unsigned width) {
  return (packed >> (index * width)) & ((1u << width) - 1u);
}

void tick(Vsimd_group_completion_tracker& dut) {
  dut.clk_i = 0;
  dut.eval();
  // The standalone tracker test treats every capacity-granted candidate as a
  // command that also fired in the external group dispatcher this cycle.
  dut.alloc_commit_i = dut.alloc_valid_i & dut.alloc_ready_o;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
  dut.alloc_commit_i = 0;
  dut.eval();
}

void tick_without_alloc_commit(Vsimd_group_completion_tracker& dut) {
  dut.alloc_commit_i = 0;
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_alloc(Vsimd_group_completion_tracker& dut) {
  dut.alloc_valid_i = 0;
  dut.alloc_commit_i = 0;
  dut.alloc_context_i = 0;
  dut.alloc_tag_i = 0;
  dut.alloc_group_mask_i = 0;
  dut.alloc_result_mask_i = 0;
}

void clear_children(Vsimd_group_completion_tracker& dut) {
  dut.child_cpl_valid_i = 0;
  dut.child_cpl_context_i = 0;
  dut.child_cpl_tag_i = 0;
  dut.child_cpl_illegal_i = 0;
  dut.child_cpl_has_result_i = 0;
  dut.child_rsp_retire_i = 0;
  dut.child_rsp_context_i = 0;
  dut.child_rsp_tag_i = 0;
}

void clear_inputs(Vsimd_group_completion_tracker& dut) {
  clear_alloc(dut);
  clear_children(dut);
  dut.cmd_cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void drive_alloc_slot(Vsimd_group_completion_tracker& dut, unsigned slot,
                      unsigned context, unsigned tag, unsigned group_mask,
                      unsigned result_mask) {
  dut.alloc_valid_i |= 1u << slot;
  dut.alloc_context_i |= context << slot;
  dut.alloc_tag_i |= tag << (slot * 8);
  dut.alloc_group_mask_i |= group_mask << (slot * kGroups);
  dut.alloc_result_mask_i |= result_mask << (slot * kGroups);
}

void allocate_one(Vsimd_group_completion_tracker& dut, unsigned context,
                  unsigned tag, unsigned group_mask, unsigned result_mask) {
  clear_alloc(dut);
  drive_alloc_slot(dut, 0, context, tag, group_mask, result_mask);
  dut.eval();
  expect_eq("single allocation ready", 1, dut.alloc_ready_o & 1u);
  expect_eq("single allocation error", 0, dut.alloc_error_o & 1u);
  tick(dut);
  clear_alloc(dut);
  dut.eval();
}

void drive_cpl(Vsimd_group_completion_tracker& dut, unsigned group,
               unsigned context, unsigned tag, bool illegal = false,
               bool has_result = false) {
  dut.child_cpl_valid_i |= 1u << group;
  dut.child_cpl_context_i |= context << group;
  dut.child_cpl_tag_i |= tag << (group * 8);
  dut.child_cpl_illegal_i |= unsigned(illegal) << group;
  dut.child_cpl_has_result_i |= unsigned(has_result) << group;
}

void drive_rsp(Vsimd_group_completion_tracker& dut, unsigned group,
               unsigned context, unsigned tag) {
  dut.child_rsp_retire_i |= 1u << group;
  dut.child_rsp_context_i |= context << group;
  dut.child_rsp_tag_i |= tag << (group * 8);
}

void send_cpl_mask(Vsimd_group_completion_tracker& dut, unsigned context,
                   unsigned tag, unsigned mask, unsigned illegal_mask = 0,
                   unsigned result_mask = 0) {
  clear_children(dut);
  for (unsigned group = 0; group < kGroups; ++group) {
    if ((mask >> group) & 1u) {
      drive_cpl(dut, group, context, tag,
                ((illegal_mask >> group) & 1u) != 0,
                ((result_mask >> group) & 1u) != 0);
    }
  }
  dut.eval();
  expect_eq("completion lanes always ready", 0xf, dut.child_cpl_ready_o);
  tick(dut);
  clear_children(dut);
  dut.eval();
}

void send_rsp_mask(Vsimd_group_completion_tracker& dut, unsigned context,
                   unsigned tag, unsigned mask) {
  clear_children(dut);
  for (unsigned group = 0; group < kGroups; ++group) {
    if ((mask >> group) & 1u) drive_rsp(dut, group, context, tag);
  }
  tick(dut);
  clear_children(dut);
  dut.eval();
}

struct Command {
  unsigned context;
  unsigned tag;
  unsigned group_mask;
  unsigned result_mask;
  unsigned illegal;
  unsigned illegal_group_mask;
};

Command visible_command(Vsimd_group_completion_tracker& dut) {
  dut.eval();
  expect_eq("command completion valid", 1, dut.cmd_cpl_valid_o);
  return {unsigned(dut.cmd_cpl_context_o), unsigned(dut.cmd_cpl_tag_o),
          unsigned(dut.cmd_cpl_group_mask_o),
          unsigned(dut.cmd_cpl_result_mask_o),
          unsigned(dut.cmd_cpl_illegal_o),
          unsigned(dut.cmd_cpl_illegal_group_mask_o)};
}

void expect_command(const Command& actual, const Command& expected) {
  expect_eq("command context", expected.context, actual.context);
  expect_eq("command tag", expected.tag, actual.tag);
  expect_eq("command group mask", expected.group_mask, actual.group_mask);
  expect_eq("command result mask", expected.result_mask, actual.result_mask);
  expect_eq("command illegal", expected.illegal, actual.illegal);
  expect_eq("command illegal groups", expected.illegal_group_mask,
            actual.illegal_group_mask);
}

void consume_command(Vsimd_group_completion_tracker& dut) {
  dut.cmd_cpl_ready_i = 1;
  tick(dut);
  dut.cmd_cpl_ready_i = 0;
  dut.eval();
}

void clear_protocol_error(Vsimd_group_completion_tracker& dut) {
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  dut.eval();
  expect_eq("protocol error cleared", 0, dut.protocol_error_o);
}

uint32_t next_random(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

unsigned popcount4(unsigned value) {
  unsigned count = 0;
  for (value &= 0xf; value != 0; value >>= 1) count += value & 1u;
  return count;
}

struct ModelEntry {
  unsigned context = 0;
  unsigned tag = 0;
  unsigned group_mask = 0;
  unsigned result_mask = 0;
  unsigned pending_cpl = 0;
  unsigned pending_rsp = 0;
  unsigned illegal_mask = 0;
  bool reported = false;
};

struct PendingAlloc {
  bool valid = false;
  unsigned context = 0;
  unsigned tag = 0;
  unsigned group_mask = 0;
  unsigned result_mask = 0;
};

int find_model_entry(const std::vector<ModelEntry>& entries, unsigned context,
                     unsigned tag) {
  for (unsigned index = 0; index < entries.size(); ++index) {
    if (entries[index].context == context && entries[index].tag == tag) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

void check_random_state(Vsimd_group_completion_tracker& dut,
                        const std::vector<ModelEntry>& entries) {
  unsigned exec_inflight = 0;
  unsigned tag_busy = 0;
  for (const ModelEntry& entry : entries) {
    tag_busy |= 1u << entry.context;
    if (entry.pending_cpl != 0) exec_inflight |= 1u << entry.context;
  }
  expect_eq("random occupancy", entries.size(), dut.occupancy_o);
  expect_eq("random full", entries.size() == 4, dut.full_o);
  expect_eq("random active entry count", entries.size(),
            popcount4(dut.entries_active_o));
  expect_eq("random context inflight", exec_inflight,
            dut.context_exec_inflight_o);
  expect_eq("random context tag busy", tag_busy, dut.context_tag_busy_o);
  expect_eq("random context quiescent", (~exec_inflight) & 0x3u,
            dut.context_quiescent_o);
}

Command read_command_without_valid_check(
    Vsimd_group_completion_tracker& dut) {
  return {unsigned(dut.cmd_cpl_context_o), unsigned(dut.cmd_cpl_tag_o),
          unsigned(dut.cmd_cpl_group_mask_o),
          unsigned(dut.cmd_cpl_result_mask_o),
          unsigned(dut.cmd_cpl_illegal_o),
          unsigned(dut.cmd_cpl_illegal_group_mask_o)};
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_group_completion_tracker dut;
  clear_inputs(dut);

  dut.rst_ni = 0;
  dut.eval();
  expect_eq("allocation blocked in reset", 0, dut.alloc_ready_o);
  expect_eq("children blocked in reset", 0, dut.child_cpl_ready_o);
  tick(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("empty after reset", 0, dut.occupancy_o);
  expect_eq("no active entries after reset", 0, dut.entries_active_o);
  expect_eq("all contexts quiescent", 0x3, dut.context_quiescent_o);
  expect_eq("children ready after reset", 0xf, dut.child_cpl_ready_o);

  // Candidate validity and capacity grant do not allocate by themselves.
  // Only the explicit commit pulse represents the matching group issue fire.
  clear_alloc(dut);
  drive_alloc_slot(dut, 0, 0, 0x0f, 0x1, 0x0);
  dut.eval();
  expect_eq("uncommitted candidate has capacity", 1,
            dut.alloc_ready_o & 1u);
  tick_without_alloc_commit(dut);
  expect_eq("uncommitted candidate does not allocate", 0,
            dut.occupancy_o);
  tick(dut);
  clear_alloc(dut);
  send_cpl_mask(dut, 0, 0x0f, 0x1);
  expect_command(visible_command(dut), {0, 0x0f, 0x1, 0x0, 0, 0});
  consume_command(dut);

  // Four-group completion may arrive in arbitrary order.  The last child makes
  // one command visible, and command backpressure must hold every output field.
  allocate_one(dut, 0, 0x10, 0xf, 0x0);
  expect_eq("one active entry", 1, dut.occupancy_o);
  expect_eq("context 0 executing", 1, dut.context_exec_inflight_o & 1u);
  send_cpl_mask(dut, 0, 0x10, 0x4);
  send_cpl_mask(dut, 0, 0x10, 0x1);
  send_cpl_mask(dut, 0, 0x10, 0x8, 0x8);
  expect_eq("not complete before last group", 0, dut.cmd_cpl_valid_o);
  send_cpl_mask(dut, 0, 0x10, 0x2);
  const Command held = visible_command(dut);
  expect_command(held, {0, 0x10, 0xf, 0x0, 1, 0x8});
  for (unsigned stall = 0; stall < 3; ++stall) {
    tick(dut);
    expect_command(visible_command(dut), held);
  }
  consume_command(dut);
  expect_eq("no-result command releases entry", 0, dut.occupancy_o);
  expect_eq("context 0 tag released", 0, dut.context_tag_busy_o & 1u);

  // All four child lanes may clear one command in the same cycle.
  allocate_one(dut, 1, 0x11, 0xf, 0x0);
  send_cpl_mask(dut, 1, 0x11, 0xf);
  expect_command(visible_command(dut), {1, 0x11, 0xf, 0x0, 0, 0});
  consume_command(dut);

  // Two allocations and their child completions may be interleaved.  Output
  // order is deliberately not assumed; both records must appear exactly once.
  clear_alloc(dut);
  drive_alloc_slot(dut, 0, 0, 0x20, 0x3, 0x0);
  drive_alloc_slot(dut, 1, 1, 0x21, 0xc, 0x0);
  dut.eval();
  expect_eq("dual allocation ready", 0x3, dut.alloc_ready_o);
  tick(dut);
  clear_alloc(dut);
  send_cpl_mask(dut, 0, 0x20, 0x1);
  send_cpl_mask(dut, 1, 0x21, 0x4);
  clear_children(dut);
  drive_cpl(dut, 1, 0, 0x20);
  drive_cpl(dut, 3, 1, 0x21);
  tick(dut);
  clear_children(dut);
  std::array<bool, 2> seen{false, false};
  for (unsigned item = 0; item < 2; ++item) {
    const Command command = visible_command(dut);
    if (command.context == 0 && command.tag == 0x20) {
      expect_eq("command 20 unique", 0, seen[0]);
      seen[0] = true;
      expect_command(command, {0, 0x20, 0x3, 0x0, 0, 0});
    } else if (command.context == 1 && command.tag == 0x21) {
      expect_eq("command 21 unique", 0, seen[1]);
      seen[1] = true;
      expect_command(command, {1, 0x21, 0xc, 0x0, 0, 0});
    } else {
      fail("unexpected interleaved command", 0, command.tag);
    }
    consume_command(dut);
  }
  expect_eq("both interleaved commands seen", 1, seen[0] && seen[1]);

  // Command completion may be reported before its result records retire.  The
  // entry and tag remain busy until the final expected result is consumed.
  allocate_one(dut, 0, 0x30, 0x3, 0x3);
  send_cpl_mask(dut, 0, 0x30, 0x3, 0x0, 0x3);
  expect_command(visible_command(dut), {0, 0x30, 0x3, 0x3, 0, 0});
  consume_command(dut);
  expect_eq("late-result entry retained", 1, dut.occupancy_o);
  expect_eq("execution done before result retire", 0,
            dut.context_exec_inflight_o & 1u);
  expect_eq("tag busy while results pending", 1,
            dut.context_tag_busy_o & 1u);
  expect_eq("execution context is quiescent", 1,
            dut.context_quiescent_o & 1u);

  clear_alloc(dut);
  drive_alloc_slot(dut, 0, 0, 0x30, 0x1, 0x0);
  dut.eval();
  expect_eq("busy tag allocation refused", 0, dut.alloc_ready_o & 1u);
  expect_eq("busy tag diagnostic", 1, dut.alloc_tag_busy_o & 1u);
  expect_eq("busy tag is not a format error", 0,
            dut.alloc_error_o & 1u);
  tick(dut);
  expect_eq("busy tag is ordinary backpressure", 0,
            dut.protocol_error_o);
  clear_alloc(dut);
  send_rsp_mask(dut, 0, 0x30, 0x2);
  expect_eq("one pending result retains entry", 1, dut.occupancy_o);
  send_rsp_mask(dut, 0, 0x30, 0x1);
  expect_eq("last result releases reported command", 0, dut.occupancy_o);

  // Results may also retire before child completions.  The command still waits
  // for every execution completion, then releases after its output handshake.
  allocate_one(dut, 1, 0x31, 0xc, 0xc);
  send_rsp_mask(dut, 1, 0x31, 0xc);
  expect_eq("early results do not finish execution", 1,
            (dut.context_exec_inflight_o >> 1) & 1u);
  send_cpl_mask(dut, 1, 0x31, 0xc, 0x0, 0xc);
  expect_command(visible_command(dut), {1, 0x31, 0xc, 0xc, 0, 0});
  consume_command(dut);
  expect_eq("early-result command releases on report", 0, dut.occupancy_o);

  // Protocol diagnostics are non-blocking: malformed child records are
  // consumed, do not mutate the live command, and set the sticky summary.
  allocate_one(dut, 0, 0x40, 0x1, 0x1);
  clear_children(dut);
  drive_cpl(dut, 1, 0, 0x40);  // Known key, group outside accepted mask.
  dut.eval();
  expect_eq("wrong completion group", 0x2, dut.child_cpl_wrong_group_o);
  tick(dut);
  clear_children(dut);
  expect_eq("wrong group sets sticky error", 1, dut.protocol_error_o);

  drive_cpl(dut, 0, 0, 0x40, false, false);  // Expected a result.
  dut.eval();
  expect_eq("result mismatch diagnostic", 0x1,
            dut.child_cpl_result_mismatch_o);
  tick(dut);
  clear_children(dut);
  expect_eq("mismatched legal completion still completes command", 1,
            dut.cmd_cpl_valid_o);

  drive_cpl(dut, 0, 0, 0x40);  // Same group completed twice.
  dut.eval();
  expect_eq("duplicate completion diagnostic", 0x1,
            dut.child_cpl_duplicate_o);
  tick(dut);
  clear_children(dut);

  drive_cpl(dut, 2, 1, 0xee);  // No matching context/tag.
  dut.eval();
  expect_eq("unknown completion diagnostic", 0x4,
            dut.child_cpl_unknown_o);
  tick(dut);
  clear_children(dut);

  drive_rsp(dut, 1, 0, 0x40);  // Known key, unexpected group.
  dut.eval();
  expect_eq("wrong response group", 0x2, dut.child_rsp_wrong_group_o);
  tick(dut);
  clear_children(dut);
  drive_rsp(dut, 2, 1, 0xef);
  dut.eval();
  expect_eq("unknown response diagnostic", 0x4,
            dut.child_rsp_unknown_o);
  tick(dut);
  clear_children(dut);
  send_rsp_mask(dut, 0, 0x40, 0x1);
  drive_rsp(dut, 0, 0, 0x40);
  dut.eval();
  expect_eq("duplicate response diagnostic", 0x1,
            dut.child_rsp_duplicate_o);
  tick(dut);
  clear_children(dut);
  expect_eq("protocol error remains sticky", 1, dut.protocol_error_o);
  consume_command(dut);
  expect_eq("diagnostic command eventually releases", 0, dut.occupancy_o);
  clear_protocol_error(dut);

  // A result-contract mismatch is recoverable. If the child says that an
  // expected result will not exist, the command is marked illegal and the tag
  // is released without waiting forever for that result.
  allocate_one(dut, 0, 0x41, 0x4, 0x4);
  send_cpl_mask(dut, 0, 0x41, 0x4, 0x0, 0x0);
  expect_command(visible_command(dut), {0, 0x41, 0x4, 0x0, 1, 0x4});
  consume_command(dut);
  expect_eq("missing declared result does not leak tag", 0,
            dut.occupancy_o);
  clear_protocol_error(dut);

  // Conversely, an undeclared result reported by the child extends the tag
  // lifetime until that actual result record retires.
  allocate_one(dut, 1, 0x42, 0x8, 0x0);
  send_cpl_mask(dut, 1, 0x42, 0x8, 0x0, 0x8);
  expect_command(visible_command(dut), {1, 0x42, 0x8, 0x8, 1, 0x8});
  consume_command(dut);
  expect_eq("unexpected actual result keeps tag busy", 1,
            dut.occupancy_o);
  send_rsp_mask(dut, 1, 0x42, 0x8);
  expect_eq("actual result retire releases recovered tag", 0,
            dut.occupancy_o);
  clear_protocol_error(dut);

  // Four live commands reserve every entry.  A fifth valid request observes
  // no-space and cannot handshake; same-cycle free+allocate is not required.
  clear_alloc(dut);
  drive_alloc_slot(dut, 0, 0, 0x50, 0x1, 0x0);
  drive_alloc_slot(dut, 1, 1, 0x51, 0x2, 0x0);
  dut.eval();
  expect_eq("first full-table dual allocation", 0x3, dut.alloc_ready_o);
  tick(dut);
  clear_alloc(dut);
  drive_alloc_slot(dut, 0, 0, 0x52, 0x4, 0x0);
  drive_alloc_slot(dut, 1, 1, 0x53, 0x8, 0x0);
  dut.eval();
  expect_eq("second full-table dual allocation", 0x3, dut.alloc_ready_o);
  tick(dut);
  clear_alloc(dut);
  dut.eval();
  expect_eq("tracker full", 1, dut.full_o);
  expect_eq("four active entries", 4, dut.occupancy_o);
  expect_eq("all entries active", 0xf, dut.entries_active_o);

  drive_alloc_slot(dut, 0, 0, 0x54, 0x1, 0x0);
  dut.eval();
  expect_eq("full table refuses allocation", 0, dut.alloc_ready_o & 1u);
  expect_eq("no-space diagnostic", 1, dut.alloc_no_space_o & 1u);
  expect_eq("no-space is ordinary backpressure", 0,
            dut.alloc_error_o & 1u);

  // Even when a completed entry will be released at this edge, the baseline
  // deliberately does not promise combinational free+allocate replacement.
  clear_alloc(dut);
  send_cpl_mask(dut, 0, 0x50, 0x1);
  expect_eq("full table may expose a completed command", 1,
            dut.cmd_cpl_valid_o);
  drive_alloc_slot(dut, 0, 0, 0x54, 0x1, 0x0);
  dut.cmd_cpl_ready_i = 1;
  dut.eval();
  expect_eq("no same-cycle free allocation", 0, dut.alloc_ready_o & 1u);
  tick(dut);
  dut.cmd_cpl_ready_i = 0;
  clear_alloc(dut);
  dut.eval();
  expect_eq("space visible after releasing edge", 0, dut.full_o);

  clear_children(dut);
  drive_cpl(dut, 0, 0, 0xfe);
  tick(dut);
  clear_children(dut);
  expect_eq("pre-reset protocol error set", 1, dut.protocol_error_o);

  // Reset with live commands clears ownership, sticky state, outputs, and tag
  // protection without manufacturing command completions.
  dut.rst_ni = 0;
  dut.eval();
  expect_eq("reset clears command output", 0, dut.cmd_cpl_valid_o);
  expect_eq("reset clears active entries", 0, dut.entries_active_o);
  expect_eq("reset clears occupancy", 0, dut.occupancy_o);
  expect_eq("reset clears tag busy", 0, dut.context_tag_busy_o);
  expect_eq("reset blocks child ready", 0, dut.child_cpl_ready_o);
  tick(dut);
  clear_inputs(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("post-reset tracker empty", 0, dut.occupancy_o);
  expect_eq("post-reset protocol clean", 0, dut.protocol_error_o);

  // Long randomized run with an independent transaction model.  Allocation
  // producers retain their request until ready; child traffic is selected only
  // from model bits that are still pending, so protocol diagnostics remain a
  // separate concern of the directed tests above.
  std::vector<ModelEntry> random_entries;
  std::array<PendingAlloc, kSlots> pending_alloc{};
  uint32_t rng = 0xb6712e4du;
  unsigned next_tag = 0x70;
  bool held_command_valid = false;
  Command held_command{};
  unsigned random_allocations = 0;
  unsigned random_completions = 0;
  unsigned random_responses = 0;
  unsigned random_reports = 0;
  unsigned random_dual_allocations = 0;
  unsigned random_multi_completions = 0;
  unsigned random_output_stalls = 0;
  constexpr unsigned kRandomCycles = 30000;

  for (unsigned cycle = 0; cycle < kRandomCycles; ++cycle) {
    clear_inputs(dut);

    // Create independent producer requests.  Tags are selected to be distinct
    // from both live model entries and the other producer's held request.
    for (unsigned slot = 0; slot < kSlots; ++slot) {
      if (!pending_alloc[slot].valid && (next_random(rng) & 3u) != 0) {
        unsigned context = next_random(rng) & 1u;
        unsigned tag = next_tag++ & 0xffu;
        bool key_free = false;
        for (unsigned attempt = 0; attempt < 512 && !key_free; ++attempt) {
          key_free = find_model_entry(random_entries, context, tag) < 0;
          for (unsigned other = 0; other < kSlots; ++other) {
            if (other != slot && pending_alloc[other].valid &&
                pending_alloc[other].context == context &&
                pending_alloc[other].tag == tag) {
              key_free = false;
            }
          }
          if (!key_free) tag = next_tag++ & 0xffu;
        }
        expect_eq("random producer found free tag", 1, key_free);
        const unsigned group_mask = (next_random(rng) & 0xfu) | 1u;
        pending_alloc[slot] = {
            true, context, tag, group_mask,
            next_random(rng) & group_mask};
      }
      if (pending_alloc[slot].valid) {
        const PendingAlloc& request = pending_alloc[slot];
        drive_alloc_slot(dut, slot, request.context, request.tag,
                         request.group_mask, request.result_mask);
      }
    }

    // At most one completion and response per physical group.  Selecting from
    // pending bits makes each generated child transaction legal by construction.
    for (unsigned group = 0; group < kGroups; ++group) {
      std::array<unsigned, 4> cpl_candidates{};
      std::array<unsigned, 4> rsp_candidates{};
      unsigned cpl_count = 0;
      unsigned rsp_count = 0;
      for (unsigned index = 0; index < random_entries.size(); ++index) {
        if ((random_entries[index].pending_cpl >> group) & 1u) {
          cpl_candidates[cpl_count++] = index;
        }
        if ((random_entries[index].pending_rsp >> group) & 1u) {
          rsp_candidates[rsp_count++] = index;
        }
      }
      if (cpl_count != 0 && (next_random(rng) & 3u) == 0) {
        const ModelEntry& entry =
            random_entries[cpl_candidates[next_random(rng) % cpl_count]];
        const bool illegal = (next_random(rng) & 0x1fu) == 0;
        drive_cpl(dut, group, entry.context, entry.tag, illegal,
                  ((entry.result_mask >> group) & 1u) != 0);
      }
      if (rsp_count != 0 && (next_random(rng) & 3u) == 0) {
        const ModelEntry& entry =
            random_entries[rsp_candidates[next_random(rng) % rsp_count]];
        drive_rsp(dut, group, entry.context, entry.tag);
      }
    }
    dut.cmd_cpl_ready_i = next_random(rng) & 1u;
    dut.eval();

    check_random_state(dut, random_entries);
    expect_eq("random child lanes ready", 0xf, dut.child_cpl_ready_o);
    expect_eq("random allocations are well formed", 0, dut.alloc_error_o);
    expect_eq("random allocations avoid busy tags", 0,
              dut.alloc_tag_busy_o);
    expect_eq("random allocation commits are atomic", 0,
              dut.alloc_commit_error_o);
    expect_eq("random legal children have no cpl diagnostics", 0,
              dut.child_cpl_unknown_o | dut.child_cpl_wrong_group_o |
                  dut.child_cpl_duplicate_o |
                  dut.child_cpl_result_mismatch_o);
    expect_eq("random legal responses have no diagnostics", 0,
              dut.child_rsp_unknown_o | dut.child_rsp_wrong_group_o |
                  dut.child_rsp_duplicate_o);
    expect_eq("random run keeps sticky protocol clean", 0,
              dut.protocol_error_o);

    // Derive allocation readiness independently from the pre-edge model.  The
    // baseline reserves only entries already free before this edge.
    unsigned free_entries = 4u - random_entries.size();
    unsigned expected_alloc_ready = 0;
    for (unsigned slot = 0; slot < kSlots; ++slot) {
      if (pending_alloc[slot].valid && free_entries != 0) {
        expected_alloc_ready |= 1u << slot;
        --free_entries;
      }
    }
    expect_eq("random allocation ready", expected_alloc_ready,
              dut.alloc_ready_o);
    unsigned expected_no_space = 0;
    for (unsigned slot = 0; slot < kSlots; ++slot) {
      if (pending_alloc[slot].valid &&
          !((expected_alloc_ready >> slot) & 1u)) {
        expected_no_space |= 1u << slot;
      }
    }
    expect_eq("random no-space", expected_no_space, dut.alloc_no_space_o);

    // A held command must be bit-stable.  Otherwise any currently visible
    // record may be selected, but it must correspond to one done model entry.
    int output_entry = -1;
    Command output{};
    if (dut.cmd_cpl_valid_o) {
      output = read_command_without_valid_check(dut);
      output_entry = find_model_entry(random_entries, output.context,
                                      output.tag);
      expect_eq("random output has live entry", 1, output_entry >= 0);
      if (output_entry >= 0) {
        const ModelEntry& entry = random_entries[output_entry];
        expect_eq("random output entry is done", 0, entry.pending_cpl);
        expect_eq("random output not already reported", 0, entry.reported);
        expect_command(output,
                       {entry.context, entry.tag, entry.group_mask,
                        entry.result_mask, entry.illegal_mask != 0,
                        entry.illegal_mask});
      }
      if (held_command_valid) expect_command(output, held_command);
    } else {
      expect_eq("held command remains valid", 0, held_command_valid);
      bool any_done = false;
      for (const ModelEntry& entry : random_entries) {
        any_done |= entry.pending_cpl == 0 && !entry.reported;
      }
      expect_eq("done entry drives command valid", 0, any_done);
    }

    const unsigned accepted_alloc = dut.alloc_valid_i & dut.alloc_ready_o;
    const unsigned accepted_cpl = dut.child_cpl_valid_i;
    const unsigned accepted_rsp = dut.child_rsp_retire_i;
    const bool command_fire = dut.cmd_cpl_valid_o && dut.cmd_cpl_ready_i;

    // Apply legal child records to the independent model.
    for (unsigned group = 0; group < kGroups; ++group) {
      if ((accepted_cpl >> group) & 1u) {
        const unsigned context = field(dut.child_cpl_context_i, group, 1);
        const unsigned tag = field(dut.child_cpl_tag_i, group, 8);
        const int index = find_model_entry(random_entries, context, tag);
        expect_eq("random completion model match", 1, index >= 0);
        if (index >= 0) {
          expect_eq("random completion bit pending", 1,
                    (random_entries[index].pending_cpl >> group) & 1u);
          random_entries[index].pending_cpl &= ~(1u << group);
          if ((dut.child_cpl_illegal_i >> group) & 1u) {
            random_entries[index].illegal_mask |= 1u << group;
          }
        }
      }
      if ((accepted_rsp >> group) & 1u) {
        const unsigned context = field(dut.child_rsp_context_i, group, 1);
        const unsigned tag = field(dut.child_rsp_tag_i, group, 8);
        const int index = find_model_entry(random_entries, context, tag);
        expect_eq("random response model match", 1, index >= 0);
        if (index >= 0) {
          expect_eq("random response bit pending", 1,
                    (random_entries[index].pending_rsp >> group) & 1u);
          random_entries[index].pending_rsp &= ~(1u << group);
        }
      }
    }

    if (command_fire) {
      expect_eq("random command fire model match", 1, output_entry >= 0);
      if (output_entry >= 0) random_entries[output_entry].reported = true;
      ++random_reports;
    }

    // A reported entry is released as soon as its final result retires,
    // including a result retirement coincident with command output handshake.
    for (unsigned index = 0; index < random_entries.size();) {
      if (random_entries[index].reported &&
          random_entries[index].pending_rsp == 0) {
        random_entries.erase(random_entries.begin() + index);
      } else {
        ++index;
      }
    }

    unsigned accepted_this_cycle = 0;
    for (unsigned slot = 0; slot < kSlots; ++slot) {
      if ((accepted_alloc >> slot) & 1u) {
        const PendingAlloc request = pending_alloc[slot];
        random_entries.push_back(
            {request.context, request.tag, request.group_mask,
             request.result_mask, request.group_mask, request.result_mask, 0,
             false});
        pending_alloc[slot] = {};
        ++random_allocations;
        ++accepted_this_cycle;
      }
    }
    if (accepted_this_cycle == 2) ++random_dual_allocations;
    random_completions += popcount4(accepted_cpl);
    random_responses += popcount4(accepted_rsp);
    if (popcount4(accepted_cpl) >= 2) ++random_multi_completions;
    if (dut.cmd_cpl_valid_o && !dut.cmd_cpl_ready_i) {
      ++random_output_stalls;
      held_command_valid = true;
      held_command = output;
    } else {
      held_command_valid = false;
    }

    tick(dut);
    check_random_state(dut, random_entries);
  }

  expect_eq("random covered allocations", 1, random_allocations != 0);
  expect_eq("random covered completions", 1, random_completions != 0);
  expect_eq("random covered responses", 1, random_responses != 0);
  expect_eq("random covered reports", 1, random_reports != 0);
  expect_eq("random covered dual allocation", 1,
            random_dual_allocations != 0);
  expect_eq("random covered simultaneous completions", 1,
            random_multi_completions != 0);
  expect_eq("random covered output stalls", 1,
            random_output_stalls != 0);

  dut.final();
  std::cout << "PASS: " << checks
            << " completion tracker checks across multicast aggregation, "
               "result lifetime, diagnostics, capacity, and reset\n";
  return 0;
}
