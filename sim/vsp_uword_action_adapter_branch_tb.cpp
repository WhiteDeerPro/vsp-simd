#include "Vvsp_uword_action_adapter.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

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

void eval_low(Vvsp_uword_action_adapter& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_uword_action_adapter& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

uint32_t branch_header(uint8_t condition, uint8_t rs1 = 0,
                       uint8_t rs2 = 0) {
  return 0xc7000000U | (static_cast<uint32_t>(condition) << 22) |
         (static_cast<uint32_t>(rs1) << 17) |
         (static_cast<uint32_t>(rs2) << 12);
}

void clear_inputs(Vvsp_uword_action_adapter& dut) {
  dut.rst_ni = 1;
  dut.launch_fire_i = 0;
  dut.launch_context_i = 0;
  dut.launch_group_mask_i = 0;
  dut.launch_tag_seed_i = 0;
  dut.record_valid_i = 0;
  dut.record_class_i = 0;
  dut.record_major_defined_i = 1;
  dut.record_start_pc_i = 0;
  dut.record_word_count_i = 0;
  dut.record_present_word_count_i = 0;
  dut.record_truncated_i = 0;
  dut.record_control_end_allowed_i = 0;
  dut.action_ready_i = 0;
  dut.memory_base_read_data_i = 0;
  dut.memory_base_read_legal_i = 1;
  for (int word = 0; word < 4; ++word) dut.record_words_i[word] = 0;
}

void reset(Vvsp_uword_action_adapter& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
}

void launch(Vvsp_uword_action_adapter& dut) {
  dut.launch_fire_i = 1;
  dut.launch_context_i = 1;
  dut.launch_group_mask_i = 0xb;
  dut.launch_tag_seed_i = 0x24;
  tick(dut);
  dut.launch_fire_i = 0;
}

void drive_branch(Vvsp_uword_action_adapter& dut, uint32_t header,
                  uint32_t offset) {
  dut.record_valid_i = 1;
  dut.record_class_i = 2;  // CONTROL
  dut.record_major_defined_i = 1;
  dut.record_start_pc_i = 0x80;
  dut.record_word_count_i = 2;
  dut.record_present_word_count_i = 2;
  dut.record_truncated_i = 0;
  dut.record_words_i[0] = header;
  dut.record_words_i[1] = offset;
  dut.action_ready_i = 0;
  eval_low(dut);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_uword_action_adapter dut;
  reset(dut);
  launch(dut);

  drive_branch(dut, branch_header(1, 3, 4), 0xfffffff0U);
  expect_eq("branch action valid", 1, dut.action_valid_o);
  expect_eq("backpressure reaches record boundary", 0, dut.record_ready_o);
  expect_eq("branch identity", 1, dut.action_is_branch_o);
  expect_eq("branch is not state", 0, dut.action_is_state_o);
  expect_eq("branch legal", 1, dut.action_legal_o);
  expect_eq("branch decode diagnostic clear", 0,
            dut.action_decode_error_o);
  expect_eq("branch condition", 1, dut.action_branch_cond_o);
  expect_eq("branch rs1", 3, dut.action_branch_rs1_o);
  expect_eq("branch rs2", 4, dut.action_branch_rs2_o);
  expect_eq("branch signed offset", 0xfffffff0U,
            static_cast<uint32_t>(dut.action_branch_offset_o));
  expect_eq("branch group mask clear", 0, dut.action_group_mask_o);
  expect_eq("branch context", 1, dut.action_context_o);
  expect_eq("branch seed tag", 0x24, dut.action_tag_o);
  expect_eq("branch source PC", 0x80, dut.action_start_pc_o);
  expect_eq("branch uses non-controller sentinel", 2,
            dut.action_control_op_o);

  // A recognized malformed branch keeps its local identity and ordered tag,
  // while canonical control fields remain suppressed by the decoder.
  drive_branch(dut, branch_header(3), 0U);
  expect_eq("malformed branch identity", 1, dut.action_is_branch_o);
  expect_eq("malformed branch rejected", 0, dut.action_legal_o);
  expect_eq("malformed branch diagnostic", 2,
            dut.action_decode_error_o);
  expect_eq("malformed branch condition suppressed", 0,
            dut.action_branch_cond_o);
  expect_eq("malformed branch tag remains ordered", 0x24,
            dut.action_tag_o);

  // Acceptance advances exactly one tag; holding a branch under backpressure
  // did not mutate the launch envelope.
  drive_branch(dut, branch_header(2, 1, 2), 8U);
  dut.action_ready_i = 1;
  eval_low(dut);
  expect_eq("ready branch accepted", 1, dut.record_ready_o);
  tick(dut);
  dut.record_valid_i = 0;
  eval_low(dut);

  drive_branch(dut, branch_header(0), 4U);
  expect_eq("accepted branch advances tag", 0x25, dut.action_tag_o);

  dut.final();
  std::cout << "vsp_uword_action_adapter_branch_tb: " << checks
            << " branch propagation, error identity and tag checks passed\n";
  return 0;
}
