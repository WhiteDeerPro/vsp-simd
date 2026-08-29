#include <verilated.h>

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

#include "Vvsp_sequencer_state_engine.h"

namespace {

constexpr uint8_t kSmovi = 0;
constexpr uint8_t kSadd = 1;
constexpr uint8_t kSaddi = 2;
constexpr uint8_t kBadOp = 3;

constexpr uint8_t kOk = 0;
constexpr uint8_t kStatusBadOp = 1;
constexpr uint8_t kStatusBadContext = 2;
constexpr uint8_t kStatusBadRegister = 3;

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

void eval_low(Vvsp_sequencer_state_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_sequencer_state_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_sequencer_state_engine& dut) {
  dut.cmd_valid_i = 0;
  dut.cmd_op_i = kSmovi;
  dut.cmd_context_i = 0;
  dut.cmd_tag_i = 0;
  dut.cmd_rd_i = 0;
  dut.cmd_rs1_i = 0;
  dut.cmd_rs2_i = 0;
  dut.cmd_imm_i = 0;
  dut.base_read_valid_i = 0;
  dut.base_read_context_i = 0;
  dut.base_read_reg_i = 0;
  dut.cpl_ready_i = 0;
}

void reset(Vvsp_sequencer_state_engine& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
}

uint32_t read_state(Vvsp_sequencer_state_engine& dut, uint8_t context,
                    uint8_t state_register, bool legal = true) {
  dut.base_read_valid_i = 1;
  dut.base_read_context_i = context;
  dut.base_read_reg_i = state_register;
  eval_low(dut);
  expect_eq("base query legality", legal, dut.base_read_legal_o);
  const uint32_t value = dut.base_read_data_o;
  dut.base_read_valid_i = 0;
  return value;
}

struct Command {
  uint8_t op;
  uint8_t context;
  uint8_t tag;
  uint8_t rd;
  uint8_t rs1;
  uint8_t rs2;
  uint32_t immediate;
};

void drive_command(Vvsp_sequencer_state_engine& dut, const Command& command) {
  dut.cmd_valid_i = 1;
  dut.cmd_op_i = command.op;
  dut.cmd_context_i = command.context;
  dut.cmd_tag_i = command.tag;
  dut.cmd_rd_i = command.rd;
  dut.cmd_rs1_i = command.rs1;
  dut.cmd_rs2_i = command.rs2;
  dut.cmd_imm_i = command.immediate;
}

void accept_command(Vvsp_sequencer_state_engine& dut,
                    const Command& command) {
  drive_command(dut, command);
  eval_low(dut);
  expect_eq("command accepted", 1, dut.cmd_ready_o);
  tick(dut);
  dut.cmd_valid_i = 0;
}

void expect_completion(Vvsp_sequencer_state_engine& dut,
                       const Command& command, uint8_t status,
                       unsigned stall_cycles = 0) {
  for (unsigned timeout = 0; timeout < 20 && !dut.cpl_valid_o; ++timeout)
    tick(dut);
  expect_eq("completion valid", 1, dut.cpl_valid_o);
  expect_eq("completion context", command.context, dut.cpl_context_o);
  expect_eq("completion tag", command.tag, dut.cpl_tag_o);
  expect_eq("completion status", status, dut.cpl_status_o);

  for (unsigned cycle = 0; cycle < stall_cycles; ++cycle) {
    tick(dut);
    expect_eq("stalled completion remains valid", 1, dut.cpl_valid_o);
    expect_eq("stalled completion context", command.context,
              dut.cpl_context_o);
    expect_eq("stalled completion tag", command.tag, dut.cpl_tag_o);
    expect_eq("stalled completion status", status, dut.cpl_status_o);
    expect_eq("completion backpressures command", 0, dut.cmd_ready_o);
  }

  dut.cpl_ready_i = 1;
  tick(dut);
  dut.cpl_ready_i = 0;
  expect_eq("completion consumed", 0, dut.cpl_valid_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_sequencer_state_engine dut;
  reset(dut);

  expect_eq("idle after reset", 0, dut.busy_o);
  expect_eq("register zero after reset", 0u, read_state(dut, 0, 0));
  expect_eq("ordinary register after reset", 0u, read_state(dut, 0, 1));

  const Command base{kSmovi, 0, 0x11, 1, 7, 7, 0x10203040u};
  accept_command(dut, base);
  expect_eq("SMOVI commits on acceptance", 0x10203040u,
            read_state(dut, 0, 1));
  expect_eq("context remains isolated", 0u, read_state(dut, 1, 1));
  expect_completion(dut, base, kOk, 3);

  const Command negative{kSmovi, 0, 0x12, 2, 0, 0, 0xfffffff0u};
  accept_command(dut, negative);
  expect_completion(dut, negative, kOk);

  const Command add{kSadd, 0, 0x13, 3, 1, 2, 0};
  accept_command(dut, add);
  expect_completion(dut, add, kOk);
  expect_eq("SADD full-width result", 0x10203030u, read_state(dut, 0, 3));

  const Command addi{kSaddi, 0, 0x14, 1, 1, 7, 0xfffffffcu};
  accept_command(dut, addi);
  expect_completion(dut, addi, kOk);
  expect_eq("SADDI source equals destination", 0x1020303cu,
            read_state(dut, 0, 1));

  // Back-to-back RAW is possible when the previous completion is consumed on
  // the same edge that accepts the next state command.
  const Command producer{kSmovi, 1, 0x20, 1, 0, 0, 0xffffffffu};
  accept_command(dut, producer);
  dut.cpl_ready_i = 1;
  const Command consumer{kSaddi, 1, 0x21, 2, 1, 0, 1};
  drive_command(dut, consumer);
  eval_low(dut);
  expect_eq("pop plus push keeps command ready", 1, dut.cmd_ready_o);
  tick(dut);
  dut.cmd_valid_i = 0;
  dut.cpl_ready_i = 0;
  expect_eq("replacement completion valid", 1, dut.cpl_valid_o);
  expect_eq("replacement completion tag", consumer.tag, dut.cpl_tag_o);
  expect_eq("modulo addition wraps", 0u, read_state(dut, 1, 2));
  expect_completion(dut, consumer, kOk);

  const Command zero_write{kSmovi, 0, 0x30, 0, 0, 0, 0xdeadbeefu};
  accept_command(dut, zero_write);
  expect_completion(dut, zero_write, kOk);
  expect_eq("zero-register write is discarded", 0u, read_state(dut, 0, 0));

  const uint32_t before_error = read_state(dut, 0, 3);
  const Command bad_op{kBadOp, 0, 0x31, 3, 1, 2, 0};
  accept_command(dut, bad_op);
  expect_completion(dut, bad_op, kStatusBadOp);
  expect_eq("bad op has no side effect", before_error,
            read_state(dut, 0, 3));

  const Command bad_context{kSmovi, 3, 0x32, 1, 0, 0, 0x55};
  accept_command(dut, bad_context);
  expect_completion(dut, bad_context, kStatusBadContext);
  expect_eq("bad context query returns zero", 0u, read_state(dut, 3, 1,
                                                              false));

  const Command bad_register{kSadd, 0, 0x33, 4, 1, 7, 0};
  accept_command(dut, bad_register);
  expect_completion(dut, bad_register, kStatusBadRegister);
  expect_eq("bad-register command preserves destination", 0u,
            read_state(dut, 0, 4));
  expect_eq("bad-register command preserves other state", before_error,
            read_state(dut, 0, 3));
  expect_eq("bad register query returns zero", 0u, read_state(dut, 0, 7,
                                                               false));

  // Reset clears state and an unconsumed completion, but no program PC or
  // backing memory is owned by this engine.
  const Command pending{kSmovi, 2, 0x40, 1, 0, 0, 0xabcdef01u};
  accept_command(dut, pending);
  expect_eq("pending completion marks engine busy", 1, dut.busy_o);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
  expect_eq("reset clears completion", 0, dut.cpl_valid_o);
  expect_eq("reset clears address state", 0u, read_state(dut, 2, 1));

  std::cout << "vsp_sequencer_state_engine_tb: " << checks
            << " checks passed\n";
  return 0;
}
