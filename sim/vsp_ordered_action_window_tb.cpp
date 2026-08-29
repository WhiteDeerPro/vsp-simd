#include "Vvsp_ordered_action_window.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr uint8_t kClassExec = 0;
constexpr uint8_t kClassMemory = 1;
constexpr uint8_t kClassControl = 2;
constexpr uint8_t kClassReserved = 3;

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

uint64_t replace_field(uint64_t packed, unsigned lane, unsigned width,
                       uint64_t value) {
  const uint64_t mask = ((uint64_t{1} << width) - 1) << (lane * width);
  return (packed & ~mask) | ((value << (lane * width)) & mask);
}

uint64_t field(uint64_t packed, unsigned lane, unsigned width) {
  return (packed >> (lane * width)) & ((uint64_t{1} << width) - 1);
}

void eval_low(Vvsp_ordered_action_window& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_ordered_action_window& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_admission(Vvsp_ordered_action_window& dut) {
  dut.admit_valid_i = 0;
  dut.admit_pc_i = 0;
  dut.admit_class_i = 0;
  dut.admit_group_mask_i = 0;
  dut.admit_raw_record_i = 0;
  dut.admit_record_word_count_i = 0;
  dut.admit_dep_read_i = 0;
  dut.admit_dep_write_i = 0;
  dut.admit_split_ok_i = 0;
  dut.admit_serializing_i = 0;
  dut.admit_end_i = 0;
}

void clear_completions(Vvsp_ordered_action_window& dut) {
  dut.complete_valid_i = 0;
  dut.complete_seq_i = 0;
  dut.complete_group_mask_i = 0;
  dut.complete_action_i = 0;
}

void clear_inputs(Vvsp_ordered_action_window& dut) {
  dut.clear_i = 0;
  dut.protocol_error_clear_i = 0;
  clear_admission(dut);
  clear_completions(dut);
  dut.exec_issue_ready_i = 0;
  dut.exec_issue_group_ready_i = 0xff;
  dut.side_issue_ready_i = 0;
  dut.side_issue_group_ready_i = 0xf;
  dut.retire_ready_i = 0;
}

void set_admission(Vvsp_ordered_action_window& dut, unsigned lane,
                   uint16_t pc, uint8_t action_class, uint8_t group_mask,
                   uint16_t raw_record, uint8_t dep_read,
                   uint8_t dep_write, bool split_ok, bool serializing = false,
                   bool end = false) {
  dut.admit_valid_i |= uint8_t{1} << lane;
  dut.admit_pc_i = replace_field(dut.admit_pc_i, lane, 16, pc);
  dut.admit_class_i =
      replace_field(dut.admit_class_i, lane, 2, action_class);
  dut.admit_group_mask_i =
      replace_field(dut.admit_group_mask_i, lane, 4, group_mask);
  dut.admit_raw_record_i =
      replace_field(dut.admit_raw_record_i, lane, 16, raw_record);
  dut.admit_record_word_count_i =
      replace_field(dut.admit_record_word_count_i, lane, 3, 1);
  dut.admit_dep_read_i =
      replace_field(dut.admit_dep_read_i, lane, 4, dep_read);
  dut.admit_dep_write_i =
      replace_field(dut.admit_dep_write_i, lane, 4, dep_write);
  dut.admit_split_ok_i |= uint8_t(split_ok) << lane;
  dut.admit_serializing_i |= uint8_t(serializing) << lane;
  dut.admit_end_i |= uint8_t(end) << lane;
}

void set_completion(Vvsp_ordered_action_window& dut, unsigned lane,
                    uint8_t seq, uint8_t groups, bool action = false) {
  dut.complete_valid_i |= uint8_t{1} << lane;
  dut.complete_seq_i = replace_field(dut.complete_seq_i, lane, 8, seq);
  dut.complete_group_mask_i =
      replace_field(dut.complete_group_mask_i, lane, 4, groups);
  dut.complete_action_i |= uint8_t(action) << lane;
}

void retire_one(Vvsp_ordered_action_window& dut, uint8_t expected_seq,
                bool expected_end = false) {
  eval_low(dut);
  expect_eq("retire valid", 1, dut.retire_valid_o & 1U);
  expect_eq("retire sequence", expected_seq,
            field(dut.retire_seq_o, 0, 8));
  expect_eq("retire END", expected_end, dut.retire_end_o & 1U);
  dut.retire_ready_i = 1;
  tick(dut);
  dut.retire_ready_i = 0;
}

void complete_groups(Vvsp_ordered_action_window& dut, uint8_t seq,
                     uint8_t groups) {
  clear_completions(dut);
  set_completion(dut, 0, seq, groups);
  eval_low(dut);
  expect_eq("group completion accepted", 1,
            dut.complete_ready_o & 1U);
  tick(dut);
  clear_completions(dut);
}

void clear_window(Vvsp_ordered_action_window& dut) {
  dut.clear_i = 1;
  tick(dut);
  dut.clear_i = 0;
  eval_low(dut);
  expect_eq("window clear occupancy", 0, dut.occupancy_o);
  expect_eq("window clear halt", 0, dut.halt_fetch_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_ordered_action_window dut;

  clear_inputs(dut);
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 3; ++cycle) tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  expect_eq("reset empty", 1, dut.empty_o);

  // Structurally undefined records use the side lane as an ordered reject
  // path instead of becoming immortal entries in the window.
  set_admission(dut, 0, 0x080, kClassReserved, 0, 0xdead, 0, 0, false);
  tick(dut);
  clear_admission(dut);
  eval_low(dut);
  expect_eq("reserved class reaches side lane", 1, dut.side_issue_valid_o);
  expect_eq("reserved class preserved", kClassReserved,
            dut.side_issue_class_o);
  dut.side_issue_ready_i = 1;
  tick(dut);
  dut.side_issue_ready_i = 0;
  clear_completions(dut);
  set_completion(dut, 0, 0, 0, true);
  eval_low(dut);
  expect_eq("ordered reject completion accepted", 1,
            dut.complete_ready_o & 1U);
  tick(dut);
  clear_completions(dut);
  retire_one(dut, 0);
  clear_window(dut);

  // The present machine can consume two vector commands and one mixed
  // MEMORY/CONTROL side command in the same cycle.
  set_admission(dut, 0, 0x100, kClassExec, 0x1, 0x1011, 0, 0, true);
  set_admission(dut, 1, 0x104, kClassExec, 0x2, 0x2022, 0, 0, true);
  set_admission(dut, 2, 0x108, kClassMemory, 0x4, 0x3033, 0, 0, true);
  eval_low(dut);
  expect_eq("three admission lanes ready", 0x7, dut.admit_ready_o);
  expect_eq("admission seq lane zero", 0, field(dut.admit_seq_o, 0, 8));
  expect_eq("admission seq lane one", 1, field(dut.admit_seq_o, 1, 8));
  expect_eq("admission seq lane two", 2, field(dut.admit_seq_o, 2, 8));
  tick(dut);
  clear_admission(dut);

  eval_low(dut);
  expect_eq("three entries admitted", 3, dut.occupancy_o);
  expect_eq("two EXEC views", 0x3, dut.exec_issue_valid_o);
  expect_eq("EXEC slot zero seq", 0, field(dut.exec_issue_seq_o, 0, 8));
  expect_eq("EXEC slot one seq", 1, field(dut.exec_issue_seq_o, 1, 8));
  expect_eq("EXEC slot zero mask", 0x1,
            field(dut.exec_issue_group_mask_o, 0, 4));
  expect_eq("EXEC slot one mask", 0x2,
            field(dut.exec_issue_group_mask_o, 1, 4));
  expect_eq("one side view", 1, dut.side_issue_valid_o);
  expect_eq("side picks MEMORY", kClassMemory, dut.side_issue_class_o);
  expect_eq("side sequence", 2, dut.side_issue_seq_o);
  expect_eq("side mask", 0x4, dut.side_issue_group_mask_o);
  dut.exec_issue_ready_i = 0x3;
  dut.side_issue_ready_i = 0x1;
  tick(dut);
  dut.exec_issue_ready_i = 0;
  dut.side_issue_ready_i = 0;

  set_completion(dut, 0, 0, 0x1);
  set_completion(dut, 1, 0, 0x1);  // same child duplicated in one cycle
  set_completion(dut, 2, 1, 0x2);
  eval_low(dut);
  expect_eq("all duplicate completion lanes consumed", 0x7,
            dut.complete_ready_o);
  tick(dut);
  clear_completions(dut);
  expect_eq("duplicate completion sets protocol error", 1,
            dut.protocol_error_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("protocol error explicit clear", 0, dut.protocol_error_o);

  set_completion(dut, 0, 0xfe, 0x1);
  eval_low(dut);
  expect_eq("unknown completion still consumed", 0x7,
            dut.complete_ready_o);
  tick(dut);
  clear_completions(dut);
  expect_eq("unknown completion sets protocol error", 1,
            dut.protocol_error_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("unknown completion error cleared", 0,
            dut.protocol_error_o);
  complete_groups(dut, 2, 0x4);

  // Three consecutive completed heads retire together, and their slots are
  // immediately reusable by the next admission group in the same cycle.
  clear_admission(dut);
  set_admission(dut, 0, 0x120, kClassExec, 0x3, 0x4033, 0, 0, true);
  set_admission(dut, 1, 0x124, kClassExec, 0x6, 0x5066, 0, 0, true);
  eval_low(dut);
  expect_eq("three retire views", 0x7, dut.retire_valid_o);
  expect_eq("retire slot zero sequence", 0,
            field(dut.retire_seq_o, 0, 8));
  expect_eq("retire slot one sequence", 1,
            field(dut.retire_seq_o, 1, 8));
  expect_eq("retire slot two sequence", 2,
            field(dut.retire_seq_o, 2, 8));
  dut.retire_ready_i = 0x7;
  eval_low(dut);
  expect_eq("three retire accepts", 0x7, dut.retire_accept_o);
  expect_eq("retirement restores three admission lanes", 0x7,
            dut.admit_ready_o);
  tick(dut);
  dut.retire_ready_i = 0;
  clear_admission(dut);
  eval_low(dut);
  expect_eq("retire/admit replacement occupancy", 2, dut.occupancy_o);

  // A split younger action may issue only groups not held by an older live
  // action. Completing one older child releases that group even while another
  // child keeps the older parent live.
  eval_low(dut);
  expect_eq("split pair visible", 0x3, dut.exec_issue_valid_o);
  expect_eq("older split full mask", 0x3,
            field(dut.exec_issue_group_mask_o, 0, 4));
  expect_eq("younger split disjoint child", 0x4,
            field(dut.exec_issue_group_mask_o, 1, 4));
  expect_eq("older split sequence", 3,
            field(dut.exec_issue_seq_o, 0, 8));
  expect_eq("younger split sequence", 4,
            field(dut.exec_issue_seq_o, 1, 8));
  dut.exec_issue_ready_i = 0x3;
  dut.exec_issue_group_ready_i = 0x41;  // slot0 accepts G0, slot1 G2
  eval_low(dut);
  expect_eq("split partial accept slot zero", 0x1,
            field(dut.exec_issue_accept_mask_o, 0, 4));
  expect_eq("split partial accept slot one", 0x4,
            field(dut.exec_issue_accept_mask_o, 1, 4));
  tick(dut);
  dut.exec_issue_ready_i = 0;
  dut.exec_issue_group_ready_i = 0xff;

  eval_low(dut);
  expect_eq("older split retains unissued child", 0x1,
            dut.exec_issue_valid_o);
  expect_eq("older remaining child sequence", 3,
            field(dut.exec_issue_seq_o, 0, 8));
  expect_eq("older remaining child mask", 0x2,
            field(dut.exec_issue_group_mask_o, 0, 4));
  dut.exec_issue_ready_i = 0x1;
  tick(dut);
  dut.exec_issue_ready_i = 0;

  clear_completions(dut);
  set_completion(dut, 0, 3, 0x2);  // older group one, group zero remains
  set_completion(dut, 1, 4, 0x4);  // younger disjoint group
  eval_low(dut);
  expect_eq("partial completions accepted", 0x3,
            dut.complete_ready_o & 0x3U);
  tick(dut);
  clear_completions(dut);
  eval_low(dut);
  expect_eq("released child has one EXEC view", 0x1,
            dut.exec_issue_valid_o);
  expect_eq("released child belongs to younger", 4,
            field(dut.exec_issue_seq_o, 0, 8));
  expect_eq("released overlap mask", 0x2,
            field(dut.exec_issue_group_mask_o, 0, 4));
  dut.exec_issue_ready_i = 0x1;
  tick(dut);
  dut.exec_issue_ready_i = 0;

  clear_completions(dut);
  set_completion(dut, 0, 3, 0x1);
  set_completion(dut, 1, 4, 0x2);
  tick(dut);
  clear_completions(dut);
  retire_one(dut, 3);
  retire_one(dut, 4);

  // A non-split multicast waits for every target group rather than issuing
  // only its currently unblocked subset.
  clear_admission(dut);
  set_admission(dut, 0, 0x140, kClassExec, 0x2, 0x6022, 0, 0, true);
  set_admission(dut, 1, 0x144, kClassMemory, 0x6, 0x7066, 0, 0, false);
  tick(dut);
  clear_admission(dut);
  eval_low(dut);
  expect_eq("older EXEC visible", 1, dut.exec_issue_valid_o & 1U);
  expect_eq("non-split side waits", 0, dut.side_issue_valid_o);
  dut.exec_issue_ready_i = 1;
  tick(dut);
  dut.exec_issue_ready_i = 0;
  complete_groups(dut, 5, 0x2);
  eval_low(dut);
  expect_eq("non-split side released", 1, dut.side_issue_valid_o);
  expect_eq("non-split keeps full mask", 0x6,
            dut.side_issue_group_mask_o);
  dut.side_issue_ready_i = 1;
  dut.side_issue_group_ready_i = 0x2;
  eval_low(dut);
  expect_eq("non-split rejects partial downstream readiness", 0,
            dut.side_issue_accept_mask_o);
  tick(dut);
  eval_low(dut);
  expect_eq("non-split remains visible after no accept", 1,
            dut.side_issue_valid_o);
  dut.side_issue_group_ready_i = 0xf;
  eval_low(dut);
  expect_eq("non-split accepts complete downstream mask", 0x6,
            dut.side_issue_accept_mask_o);
  tick(dut);
  dut.side_issue_ready_i = 0;
  dut.side_issue_group_ready_i = 0xf;
  complete_groups(dut, 6, 0x6);
  retire_one(dut, 5);
  retire_one(dut, 6);

  // Dependency metadata covers window-global state. It can serialize
  // disjoint group masks without forcing every scalar/vector pair to wait.
  clear_admission(dut);
  set_admission(dut, 0, 0x160, kClassExec, 0x1, 0x8011, 0, 0x1, true);
  set_admission(dut, 1, 0x164, kClassMemory, 0x2, 0x9022, 0x1, 0, true);
  tick(dut);
  clear_admission(dut);
  eval_low(dut);
  expect_eq("dependency producer visible", 1, dut.exec_issue_valid_o & 1U);
  expect_eq("disjoint dependent side blocked", 0, dut.side_issue_valid_o);
  dut.exec_issue_ready_i = 1;
  tick(dut);
  dut.exec_issue_ready_i = 0;
  complete_groups(dut, 7, 0x1);
  eval_low(dut);
  expect_eq("completed producer may await retirement", 1,
            dut.retire_valid_o & 1U);
  expect_eq("dependent side released on completion", 1,
            dut.side_issue_valid_o);
  expect_eq("dependent side sequence", 8, dut.side_issue_seq_o);
  dut.side_issue_ready_i = 1;
  tick(dut);
  dut.side_issue_ready_i = 0;
  complete_groups(dut, 8, 0x2);
  retire_one(dut, 7);
  retire_one(dut, 8);

  // END cuts off younger records in the same admission group, stops fetch,
  // waits until it reaches the retirement head, and remains sticky until a
  // program restart clears the independent window.
  clear_admission(dut);
  set_admission(dut, 0, 0x180, kClassExec, 0x1, 0xa011, 0, 0, true);
  set_admission(dut, 1, 0x184, kClassControl, 0x0, 0xb000, 0, 0, false,
                false, true);
  set_admission(dut, 2, 0x188, kClassExec, 0x2, 0xc022, 0, 0, true);
  eval_low(dut);
  expect_eq("END rejects younger lane", 0x3, dut.admit_ready_o);
  expect_eq("END sequences accepted prefix", 9,
            field(dut.admit_seq_o, 0, 8));
  expect_eq("END sequence", 10, field(dut.admit_seq_o, 1, 8));
  tick(dut);
  clear_admission(dut);
  eval_low(dut);
  expect_eq("END admitted only two", 2, dut.occupancy_o);
  expect_eq("END halts fetch", 1, dut.halt_fetch_o);
  expect_eq("older EXEC before END", 1, dut.exec_issue_valid_o & 1U);
  expect_eq("serializing END waits", 0, dut.side_issue_valid_o);
  dut.exec_issue_ready_i = 1;
  tick(dut);
  dut.exec_issue_ready_i = 0;
  complete_groups(dut, 9, 0x1);
  eval_low(dut);
  expect_eq("END still waits for older retirement", 0,
            dut.side_issue_valid_o);
  retire_one(dut, 9);
  eval_low(dut);
  expect_eq("END reaches side lane", 1, dut.side_issue_valid_o);
  expect_eq("END class", kClassControl, dut.side_issue_class_o);
  expect_eq("END marker", 1, dut.side_issue_end_o);
  expect_eq("END group mask is empty", 0, dut.side_issue_group_mask_o);
  dut.side_issue_ready_i = 1;
  tick(dut);
  dut.side_issue_ready_i = 0;
  clear_completions(dut);
  set_completion(dut, 0, 10, 0, true);
  eval_low(dut);
  expect_eq("END completion accepted", 1, dut.complete_ready_o & 1U);
  tick(dut);
  clear_completions(dut);
  eval_low(dut);
  expect_eq("END retire valid", 1, dut.retire_valid_o & 1U);
  dut.retire_ready_i = 1;
  tick(dut);
  dut.retire_ready_i = 0;
  expect_eq("END retirement pulse", 1, dut.program_end_retired_o);
  expect_eq("END leaves empty window", 1, dut.empty_o);
  expect_eq("END halt remains sticky", 1, dut.halt_fetch_o);
  clear_admission(dut);
  set_admission(dut, 0, 0x200, kClassExec, 1, 0xd011, 0, 0, true);
  eval_low(dut);
  expect_eq("sticky END blocks new program", 0, dut.admit_ready_o & 1U);
  clear_admission(dut);
  clear_window(dut);

  // A stalled view is locked. When an older EXEC becomes ready later, it may
  // use the other slot but cannot replace the payload already being offered.
  set_admission(dut, 0, 0x220, kClassMemory, 0x1, 0xe011, 0, 0, true);
  set_admission(dut, 1, 0x224, kClassExec, 0x1, 0xe111, 0, 0, true);
  set_admission(dut, 2, 0x228, kClassExec, 0x2, 0xe222, 0, 0, true);
  tick(dut);
  clear_admission(dut);
  eval_low(dut);
  expect_eq("younger disjoint EXEC initially visible", 1,
            dut.exec_issue_valid_o & 1U);
  expect_eq("stalled candidate sequence", 2,
            field(dut.exec_issue_seq_o, 0, 8));
  dut.side_issue_ready_i = 1;
  tick(dut);  // issue MEMORY while EXEC remains stalled and becomes locked
  dut.side_issue_ready_i = 0;
  complete_groups(dut, 0, 0x1);
  eval_low(dut);
  expect_eq("locked payload stays in slot zero", 2,
            field(dut.exec_issue_seq_o, 0, 8));
  expect_eq("newly ready older payload uses slot one", 1,
            field(dut.exec_issue_seq_o, 1, 8));
  expect_eq("both EXEC slots now visible", 0x3, dut.exec_issue_valid_o);
  clear_window(dut);

  dut.final();
  std::cout << "PASS: " << checks
            << " ordered action-window scheduling checks\n";
  return 0;
}
