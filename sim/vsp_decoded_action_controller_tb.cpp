#include "Vvsp_decoded_action_controller.h"
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
constexpr uint8_t kControlEnd = 0;
constexpr uint8_t kStatusOk = 0;
constexpr uint8_t kStatusDecode = 1;
constexpr uint8_t kStatusOwner = 2;
constexpr uint8_t kStatusExec = 3;
constexpr uint8_t kStatusMemory = 4;
constexpr uint8_t kStatusControl = 5;
constexpr uint8_t kStatusProtocol = 6;

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

void eval_low(Vvsp_decoded_action_controller& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_decoded_action_controller& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_action(Vvsp_decoded_action_controller& dut) {
  dut.action_valid_i = 0;
  dut.action_class_i = kClassExec;
  dut.action_legal_i = 1;
  dut.action_decode_error_i = 0;
  dut.action_control_op_i = kControlEnd;
  dut.action_context_i = 0;
  dut.action_tag_i = 0;
  dut.action_group_mask_i = 0;
  dut.action_exec_payload_i = 0;
  dut.action_memory_payload_i = 0;
}

void clear_completions(Vvsp_decoded_action_controller& dut) {
  dut.exec_cpl_valid_i = 0;
  dut.exec_cpl_context_i = 0;
  dut.exec_cpl_tag_i = 0;
  dut.exec_cpl_error_i = 0;
  dut.exec_cpl_payload_i = 0;
  dut.memory_cpl_valid_i = 0;
  dut.memory_cpl_context_i = 0;
  dut.memory_cpl_tag_i = 0;
  dut.memory_cpl_error_i = 0;
  dut.memory_cpl_payload_i = 0;
}

void clear_inputs(Vvsp_decoded_action_controller& dut) {
  clear_action(dut);
  clear_completions(dut);
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0;
  dut.end_quiescent_i = 1;
  dut.exec_cmd_ready_i = 0;
  dut.memory_cmd_ready_i = 0;
  dut.action_cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void accept_action(Vvsp_decoded_action_controller& dut, uint8_t action_class,
                   uint8_t context, uint8_t tag, uint8_t group_mask,
                   uint8_t payload) {
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = action_class;
  dut.action_context_i = context;
  dut.action_tag_i = tag;
  dut.action_group_mask_i = group_mask;
  dut.action_exec_payload_i = payload & 1U;
  dut.action_memory_payload_i = payload & 1U;
  eval_low(dut);
  expect_eq("action accepted", 1, dut.action_ready_o);
  tick(dut);
  clear_action(dut);
}

void expect_completion(Vvsp_decoded_action_controller& dut,
                       uint8_t action_class, uint8_t tag, uint8_t status,
                       uint8_t exec_payload, uint8_t memory_payload,
                       bool end) {
  eval_low(dut);
  expect_eq("completion valid", 1, dut.action_cpl_valid_o);
  expect_eq("completion class", action_class, dut.action_cpl_class_o);
  expect_eq("completion context", 0, dut.action_cpl_context_o);
  expect_eq("completion tag", tag, dut.action_cpl_tag_o);
  expect_eq("completion status", status, dut.action_cpl_status_o);
  expect_eq("completion EXEC payload", exec_payload,
            dut.action_cpl_exec_payload_o);
  expect_eq("completion MEMORY payload", memory_payload,
            dut.action_cpl_memory_payload_o);
  expect_eq("completion END", end, dut.action_cpl_end_o);
}

void consume_completion(Vvsp_decoded_action_controller& dut,
                        bool expect_done) {
  dut.action_cpl_ready_i = 1;
  eval_low(dut);
  expect_eq("program-done handshake", expect_done, dut.program_done_o);
  tick(dut);
  dut.action_cpl_ready_i = 0;
  eval_low(dut);
  expect_eq("completion consumed", 0, dut.action_cpl_valid_o);
  expect_eq("program-done pulse ended", 0, dut.program_done_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_decoded_action_controller dut;

  clear_inputs(dut);
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 3; ++cycle) tick(dut);
  dut.rst_ni = 1;
  tick(dut);

  // EXEC request remains stable while the child endpoint is stalled.
  dut.action_valid_i = 1;
  dut.action_class_i = kClassExec;
  dut.action_context_i = 0;
  dut.action_tag_i = 0x11;
  dut.action_group_mask_i = 0x3;
  dut.action_exec_payload_i = 1;
  for (int held = 0; held < 3; ++held) {
    eval_low(dut);
    expect_eq("stalled EXEC action ready", 0, dut.action_ready_o);
    expect_eq("stalled EXEC child valid", 1, dut.exec_cmd_valid_o);
    expect_eq("stalled EXEC child tag", 0x11, dut.exec_cmd_tag_o);
    expect_eq("stalled EXEC child mask", 0x3, dut.exec_cmd_group_mask_o);
    expect_eq("stalled EXEC child payload", 1, dut.exec_cmd_payload_o);
    tick(dut);
  }
  dut.exec_cmd_ready_i = 1;
  eval_low(dut);
  expect_eq("EXEC action becomes ready", 1, dut.action_ready_o);
  tick(dut);
  clear_action(dut);
  dut.exec_cmd_ready_i = 0;

  // A younger action is visible immediately but cannot cross the active EXEC.
  dut.action_valid_i = 1;
  dut.action_class_i = kClassMemory;
  dut.action_tag_i = 0x12;
  dut.action_group_mask_i = 0x3;
  dut.memory_cmd_ready_i = 1;
  eval_low(dut);
  expect_eq("younger MEMORY blocked", 0, dut.action_ready_o);
  expect_eq("no early MEMORY child", 0, dut.memory_cmd_valid_o);

  dut.exec_cpl_valid_i = 1;
  dut.exec_cpl_context_i = 0;
  dut.exec_cpl_tag_i = 0x11;
  dut.exec_cpl_payload_i = 1;
  eval_low(dut);
  expect_eq("EXEC completion drainable", 1, dut.exec_cpl_ready_o);
  tick(dut);
  clear_completions(dut);
  expect_completion(dut, kClassExec, 0x11, kStatusOk, 1, 0, false);
  for (int held = 0; held < 4; ++held) {
    expect_completion(dut, kClassExec, 0x11, kStatusOk, 1, 0, false);
    expect_eq("next action blocked by unified completion", 0,
              dut.action_ready_o);
    tick(dut);
  }
  consume_completion(dut, false);

  // A child-reported EXEC failure keeps its detail payload and is distinct
  // from a decoder-local error.
  dut.exec_cmd_ready_i = 1;
  accept_action(dut, kClassExec, 0, 0x22, 0x3, 0);
  dut.exec_cmd_ready_i = 0;
  dut.exec_cpl_valid_i = 1;
  dut.exec_cpl_context_i = 0;
  dut.exec_cpl_tag_i = 0x22;
  dut.exec_cpl_error_i = 1;
  dut.exec_cpl_payload_i = 1;
  tick(dut);
  clear_completions(dut);
  expect_completion(dut, kClassExec, 0x22, kStatusExec, 1, 0, false);
  consume_completion(dut, false);
  clear_action(dut);
  dut.memory_cmd_ready_i = 0;

  // MEMORY error is captured in the unified ordered completion.
  dut.memory_cmd_ready_i = 1;
  accept_action(dut, kClassMemory, 0, 0x21, 0x5, 1);
  dut.memory_cmd_ready_i = 0;
  dut.memory_cpl_valid_i = 1;
  dut.memory_cpl_context_i = 0;
  dut.memory_cpl_tag_i = 0x21;
  dut.memory_cpl_error_i = 1;
  dut.memory_cpl_payload_i = 1;
  tick(dut);
  clear_completions(dut);
  expect_completion(dut, kClassMemory, 0x21, kStatusMemory, 0, 1,
                    false);
  consume_completion(dut, false);

  // Decoder-local error never reaches either child endpoint.
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassExec;
  dut.action_legal_i = 0;
  dut.action_decode_error_i = 0xa;
  dut.action_tag_i = 0x31;
  dut.action_group_mask_i = 0xf;
  dut.exec_cmd_ready_i = 1;
  eval_low(dut);
  expect_eq("illegal action accepted locally", 1, dut.action_ready_o);
  expect_eq("illegal action does not issue EXEC", 0, dut.exec_cmd_valid_o);
  expect_eq("illegal action does not issue MEMORY", 0,
            dut.memory_cmd_valid_o);
  tick(dut);
  clear_action(dut);
  expect_completion(dut, kClassExec, 0x31, kStatusDecode, 0, 0, false);
  expect_eq("decode cause preserved", 0xa, dut.action_cpl_decode_error_o);
  consume_completion(dut, false);
  dut.exec_cmd_ready_i = 0;

  // A reserved class is also a deterministic local decode error.
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassReserved;
  dut.action_tag_i = 0x32;
  eval_low(dut);
  expect_eq("reserved class accepted locally", 1, dut.action_ready_o);
  tick(dut);
  clear_action(dut);
  expect_completion(dut, kClassReserved, 0x32, kStatusDecode, 0, 0,
                    false);
  consume_completion(dut, false);

  // MEMORY ownership is checked before any engine side effect.
  // Group zero belongs to context zero, but the command names context one.
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassMemory;
  dut.action_context_i = 1;
  dut.action_tag_i = 0x41;
  dut.action_group_mask_i = 0x1;
  dut.action_decode_error_i = 0xb;
  dut.memory_cmd_ready_i = 1;
  eval_low(dut);
  expect_eq("owner mismatch accepted locally", 1, dut.action_ready_o);
  expect_eq("owner mismatch has no MEMORY child", 0,
            dut.memory_cmd_valid_o);
  tick(dut);
  clear_action(dut);
  eval_low(dut);
  expect_eq("owner completion context", 1, dut.action_cpl_context_o);
  expect_eq("owner completion status", kStatusOwner,
            dut.action_cpl_status_o);
  expect_eq("owner completion clears stale decode cause", 0,
            dut.action_cpl_decode_error_o);
  consume_completion(dut, false);
  dut.memory_cmd_ready_i = 0;

  // Controller-local malformed CONTROL operations have no child side effect,
  // no END marker and no stale decoder cause.
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassControl;
  dut.action_control_op_i = 3;
  dut.action_tag_i = 0x48;
  dut.action_decode_error_i = 0xc;
  eval_low(dut);
  expect_eq("bad CONTROL accepted locally", 1, dut.action_ready_o);
  expect_eq("bad CONTROL has no EXEC child", 0, dut.exec_cmd_valid_o);
  expect_eq("bad CONTROL has no MEMORY child", 0,
            dut.memory_cmd_valid_o);
  tick(dut);
  clear_action(dut);
  expect_completion(dut, kClassControl, 0x48, kStatusControl, 0, 0,
                    false);
  expect_eq("bad CONTROL clears stale decode cause", 0,
            dut.action_cpl_decode_error_o);
  consume_completion(dut, false);

  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassControl;
  dut.action_control_op_i = kControlEnd;
  dut.action_tag_i = 0x49;
  dut.action_group_mask_i = 0x1;
  tick(dut);
  clear_action(dut);
  expect_completion(dut, kClassControl, 0x49, kStatusControl, 0, 0,
                    false);
  consume_completion(dut, false);

  // END is an ordered action and cannot complete before internal quiescence.
  dut.end_quiescent_i = 0;
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassControl;
  dut.action_control_op_i = kControlEnd;
  dut.action_tag_i = 0x51;
  eval_low(dut);
  expect_eq("END accepted", 1, dut.action_ready_o);
  tick(dut);
  clear_action(dut);
  for (int held = 0; held < 4; ++held) {
    eval_low(dut);
    expect_eq("END waits for quiescence", 0, dut.action_cpl_valid_o);
    expect_eq("END keeps controller busy", 1, dut.busy_o);
    tick(dut);
  }
  dut.end_quiescent_i = 1;
  tick(dut);
  expect_completion(dut, kClassControl, 0x51, kStatusOk, 0, 0, true);
  for (int held = 0; held < 3; ++held) {
    eval_low(dut);
    expect_eq("stalled END does not pulse done", 0, dut.program_done_o);
    tick(dut);
  }
  consume_completion(dut, true);

  // A zero-latency child may return in the command-accept cycle.  It must be
  // correlated with the action being accepted rather than diagnosed as an
  // unexpected record or lost before the WAIT state is entered.
  clear_action(dut);
  clear_completions(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassExec;
  dut.action_tag_i = 0x58;
  dut.action_group_mask_i = 0x3;
  dut.exec_cmd_ready_i = 1;
  dut.exec_cpl_valid_i = 1;
  dut.exec_cpl_context_i = 0;
  dut.exec_cpl_tag_i = 0x58;
  dut.exec_cpl_payload_i = 1;
  eval_low(dut);
  expect_eq("same-cycle EXEC action ready", 1, dut.action_ready_o);
  expect_eq("same-cycle EXEC command valid", 1, dut.exec_cmd_valid_o);
  expect_eq("same-cycle EXEC completion ready", 1, dut.exec_cpl_ready_o);
  tick(dut);
  clear_action(dut);
  clear_completions(dut);
  dut.exec_cmd_ready_i = 0;
  expect_completion(dut, kClassExec, 0x58, kStatusOk, 1, 0, false);
  expect_eq("same-cycle EXEC is not protocol error", 0,
            dut.protocol_error_o);
  consume_completion(dut, false);

  clear_action(dut);
  clear_completions(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassMemory;
  dut.action_tag_i = 0x59;
  dut.action_group_mask_i = 0x1;
  dut.memory_cmd_ready_i = 1;
  dut.memory_cpl_valid_i = 1;
  dut.memory_cpl_context_i = 0;
  dut.memory_cpl_tag_i = 0x59;
  dut.memory_cpl_error_i = 1;
  dut.memory_cpl_payload_i = 1;
  tick(dut);
  clear_action(dut);
  clear_completions(dut);
  dut.memory_cmd_ready_i = 0;
  expect_completion(dut, kClassMemory, 0x59, kStatusMemory, 0, 1,
                    false);
  consume_completion(dut, false);

  // Unexpected and mismatched child completions are consumed and diagnosed.
  dut.exec_cpl_valid_i = 1;
  dut.exec_cpl_context_i = 0;
  dut.exec_cpl_tag_i = 0xee;
  eval_low(dut);
  expect_eq("unexpected completion drainable", 1, dut.exec_cpl_ready_o);
  tick(dut);
  clear_completions(dut);
  eval_low(dut);
  expect_eq("unexpected completion sets protocol sticky", 1,
            dut.protocol_error_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  eval_low(dut);
  expect_eq("protocol sticky clears", 0, dut.protocol_error_o);

  dut.exec_cmd_ready_i = 1;
  accept_action(dut, kClassExec, 0, 0x61, 0x1, 0);
  dut.exec_cmd_ready_i = 0;
  dut.exec_cpl_valid_i = 1;
  dut.exec_cpl_context_i = 0;
  dut.exec_cpl_tag_i = 0x62;
  tick(dut);
  clear_completions(dut);
  expect_completion(dut, kClassExec, 0x61, kStatusProtocol, 0, 0,
                    false);
  eval_low(dut);
  expect_eq("identity mismatch sets protocol sticky", 1,
            dut.protocol_error_o);
  consume_completion(dut, false);

  // Reset is live recovery: no active action, held unified completion, END,
  // done pulse or sticky diagnostic may survive it.
  dut.exec_cmd_ready_i = 1;
  accept_action(dut, kClassExec, 0, 0x71, 0x1, 0);
  dut.exec_cmd_ready_i = 0;
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassControl;
  clear_completions(dut);
  dut.rst_ni = 0;
  tick(dut);
  eval_low(dut);
  expect_eq("reset clears WAIT_EXEC busy", 0, dut.busy_o);
  expect_eq("reset clears protocol sticky", 0, dut.protocol_error_o);
  expect_eq("reset suppresses action ready", 0, dut.action_ready_o);
  clear_action(dut);
  dut.rst_ni = 1;
  tick(dut);

  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_legal_i = 0;
  dut.action_decode_error_i = 0x3;
  dut.action_tag_i = 0x72;
  tick(dut);
  clear_action(dut);
  eval_low(dut);
  expect_eq("pre-reset local completion present", 1,
            dut.action_cpl_valid_o);
  dut.rst_ni = 0;
  tick(dut);
  eval_low(dut);
  expect_eq("reset clears held unified completion", 0,
            dut.action_cpl_valid_o);
  expect_eq("reset never pulses done", 0, dut.program_done_o);
  dut.rst_ni = 1;
  tick(dut);

  dut.end_quiescent_i = 0;
  clear_action(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = kClassControl;
  dut.action_tag_i = 0x73;
  tick(dut);
  clear_action(dut);
  eval_low(dut);
  expect_eq("pre-reset END is busy", 1, dut.busy_o);
  dut.rst_ni = 0;
  tick(dut);
  eval_low(dut);
  expect_eq("reset clears WAIT_END busy", 0, dut.busy_o);
  expect_eq("reset clears END completion", 0, dut.action_cpl_valid_o);
  dut.rst_ni = 1;
  dut.end_quiescent_i = 1;
  tick(dut);
  eval_low(dut);
  expect_eq("post-reset END remains cleared", 0, dut.action_cpl_valid_o);
  expect_eq("post-reset controller remains idle", 0, dut.busy_o);
  expect_eq("post-reset END has no ghost done", 0, dut.program_done_o);

  dut.final();
  std::cout << "PASS: decoded action controller " << checks
            << " checks across ordering, END, owner/error paths and "
               "backpressure\n";
  return 0;
}
