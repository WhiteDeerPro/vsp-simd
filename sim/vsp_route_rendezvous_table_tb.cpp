#include "Vvsp_route_rendezvous_table.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& field, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << field << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect(const std::string& field, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(field, expected, actual);
}

void eval_low(Vvsp_route_rendezvous_table& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_route_rendezvous_table& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_route_rendezvous_table& dut) {
  dut.fragment_valid_i = 0;
  dut.fragment_legal_i = 1;
  dut.fragment_cause_i = 0;
  dut.fragment_context_i = 0;
  dut.fragment_epoch_i = 0;
  dut.fragment_route_id_i = 0;
  dut.fragment_role_i = 0;
  dut.fragment_participant_i = 0;
  dut.fragment_retire_token_i = 0;
  dut.fragment_payload_i = 0;
  dut.participant_frontier_i = 0;
  dut.flush_valid_i = 0;
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 0;
  dut.epoch_advance_valid_i = 0;
  dut.epoch_advance_context_i = 0;
  dut.epoch_advance_new_epoch_i = 0;
  dut.terminal_ready_i = 0;
}

void send(Vvsp_route_rendezvous_table& dut, uint8_t context, uint8_t epoch,
          uint8_t route_id, uint8_t role, uint8_t participant,
          uint8_t token, uint32_t payload, bool legal = true,
          uint8_t cause = 0) {
  dut.fragment_context_i = context;
  dut.fragment_epoch_i = epoch;
  dut.fragment_route_id_i = route_id;
  dut.fragment_role_i = role;
  dut.fragment_participant_i = participant;
  dut.fragment_retire_token_i = token;
  dut.fragment_payload_i = payload;
  dut.fragment_legal_i = legal;
  dut.fragment_cause_i = cause;
  dut.fragment_valid_i = 1;
  eval_low(dut);
  expect("fragment ready", 1, dut.fragment_ready_o);
  tick(dut);
  dut.fragment_valid_i = 0;
}

void wait_terminal(Vvsp_route_rendezvous_table& dut) {
  for (int timeout = 0; timeout < 30; ++timeout) {
    eval_low(dut);
    if (dut.terminal_valid_o) return;
    tick(dut);
  }
  fail("terminal timeout", 1, 0);
}

void consume(Vvsp_route_rendezvous_table& dut) {
  dut.terminal_ready_i = 1;
  tick(dut);
  dut.terminal_ready_i = 0;
}

void advance_epoch(Vvsp_route_rendezvous_table& dut, uint8_t context,
                   uint8_t epoch) {
  dut.epoch_advance_valid_i = 1;
  dut.epoch_advance_context_i = context;
  dut.epoch_advance_new_epoch_i = epoch;
  tick(dut);
  dut.epoch_advance_valid_i = 0;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_route_rendezvous_table dut;
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  eval_low(dut);
  expect("reset occupancy", 0, dut.occupancy_o);
  expect("reset terminal", 0, dut.terminal_valid_o);

  // An illegal fragment never becomes COLLECT state; it terminates as reject.
  send(dut, 0, 1, 0x10, 1, 0, 1, 0x11111111, false, 9);
  wait_terminal(dut);
  expect("illegal kind", 1, dut.terminal_kind_o);
  expect("illegal cause preserved", 9, dut.terminal_cause_o);
  expect("illegal key", 0x10, dut.terminal_route_id_o);
  expect("illegal IN identity valid", 1, dut.terminal_in_valid_o);
  expect("illegal IN payload preserved", 0x11111111,
         dut.terminal_in_payload_o);
  expect("illegal OUT identity absent", 0, dut.terminal_out_valid_o);
  expect("illegal recognizable role needs no fault slot", 0,
         dut.terminal_fault_valid_o);
  consume(dut);

  // Even a structurally bad role retains the accepted raw identity in the
  // fault slot; it is never mistaken for an indefinitely missing peer.
  send(dut, 0, 1, 0x11, 0, 1, 2, 0x12121212);
  wait_terminal(dut);
  expect("bad role rejects", 1, dut.terminal_kind_o);
  expect("bad role uses fault slot", 1, dut.terminal_fault_valid_o);
  expect("bad role identity", 0x12121212,
         dut.terminal_fault_payload_o);
  consume(dut);

  // Exact duplicate is idempotent; conflicting duplicate cancels collection.
  advance_epoch(dut, 0, 2);
  send(dut, 0, 2, 0x20, 1, 0, 5, 0x11223344);
  expect("one collecting entry", 1, dut.occupancy_o);
  send(dut, 0, 2, 0x20, 1, 0, 5, 0x11223344);
  expect("duplicate does not allocate", 1, dut.occupancy_o);
  send(dut, 0, 2, 0x20, 1, 0, 5, 0x55667788);
  wait_terminal(dut);
  expect("conflict kind", 1, dut.terminal_kind_o);
  expect("conflict cause", 2, dut.terminal_cause_o);
  expect("conflict retains original payload", 0x11223344,
         dut.terminal_in_payload_o);
  expect("conflict retains offending identity", 1,
         dut.terminal_fault_valid_o);
  expect("conflict offending role", 1, dut.terminal_fault_role_o);
  expect("conflict offending payload", 0x55667788,
         dut.terminal_fault_payload_o);
  consume(dut);

  // An illegal second half must reject the existing rendezvous rather than
  // being accepted and silently ignored.
  send(dut, 0, 2, 0x21, 2, 0, 5, 0x21212121);
  send(dut, 0, 2, 0x21, 1, 1, 7, 0x22222222, false, 10);
  wait_terminal(dut);
  expect("illegal matching fragment kind", 1, dut.terminal_kind_o);
  expect("illegal matching fragment cause", 10, dut.terminal_cause_o);
  expect("illegal matching fragment retains IN validity", 1,
         dut.terminal_in_valid_o);
  expect("illegal matching fragment retains IN", 0x22222222,
         dut.terminal_in_payload_o);
  expect("illegal matching fragment retains OUT validity", 1,
         dut.terminal_out_valid_o);
  expect("illegal matching fragment retains OUT", 0x21212121,
         dut.terminal_out_payload_o);
  expect("illegal complementary role needs no fault slot", 0,
         dut.terminal_fault_valid_o);
  consume(dut);

  // Out-of-range context/participant encodings are rejected, but the raw
  // role/token/payload identity remains observable for an abort path.
  send(dut, 3, 2, 0x23, 1, 1, 6, 0x25252525);
  wait_terminal(dut);
  expect("invalid context rejects", 1, dut.terminal_kind_o);
  expect("invalid context retains role", 1, dut.terminal_in_valid_o);
  expect("invalid context retains payload", 0x25252525,
         dut.terminal_in_payload_o);
  consume(dut);

  send(dut, 0, 2, 0x24, 2, 3, 6, 0x26262626);
  wait_terminal(dut);
  expect("invalid participant rejects", 1, dut.terminal_kind_o);
  expect("invalid participant retains role", 1,
         dut.terminal_out_valid_o);
  expect("invalid participant identity", 3,
         dut.terminal_out_participant_o);
  expect("invalid participant retains payload", 0x26262626,
         dut.terminal_out_payload_o);
  consume(dut);

  // Two complementary roles must come from distinct participant streams.
  send(dut, 0, 2, 0x22, 2, 0, 5, 0x23232323);
  send(dut, 0, 2, 0x22, 1, 0, 6, 0x24242424);
  wait_terminal(dut);
  expect("same-participant pair rejects", 1, dut.terminal_kind_o);
  expect("same-participant cause", 3, dut.terminal_cause_o);
  expect("same-participant IN retained", 1, dut.terminal_in_valid_o);
  expect("same-participant OUT retained", 1, dut.terminal_out_valid_o);
  expect("same-participant pair has no third fragment", 0,
         dut.terminal_fault_valid_o);
  consume(dut);

  // A complete pair waits for both participant retirement frontiers. Tokens
  // are monotonic within this epoch; this test intentionally does not wrap.
  send(dut, 1, 3, 0x30, 2, 0, 5, 0xa0a0a0a0);
  send(dut, 1, 3, 0x30, 1, 1, 7, 0xb1b1b1b1);
  dut.participant_frontier_i = (uint16_t{7} << 8) | 4;
  dut.fragment_context_i = 1;
  dut.fragment_epoch_i = 3;
  dut.fragment_route_id_i = 0x30;
  dut.fragment_role_i = 1;
  dut.fragment_participant_i = 1;
  dut.fragment_retire_token_i = 7;
  dut.fragment_payload_i = 0xb1b1b1b1;
  dut.fragment_valid_i = 1;
  eval_low(dut);
  expect("complete pair closes collection", 0, dut.fragment_ready_o);
  dut.fragment_valid_i = 0;
  for (int cycle = 0; cycle < 3; ++cycle) {
    tick(dut);
    expect("frontier blocks wave", 0, dut.terminal_valid_o);
  }
  dut.participant_frontier_i = (uint16_t{7} << 8) | 5;
  wait_terminal(dut);
  expect("wave kind", 0, dut.terminal_kind_o);
  expect("wave has no reject cause", 0, dut.terminal_cause_o);
  expect("wave context", 1, dut.terminal_context_o);
  expect("wave epoch", 3, dut.terminal_epoch_o);
  expect("wave route id", 0x30, dut.terminal_route_id_o);
  expect("wave has IN role", 1, dut.terminal_in_valid_o);
  expect("wave IN participant", 1, dut.terminal_in_participant_o);
  expect("wave IN token", 7, dut.terminal_in_token_o);
  expect("wave IN payload", 0xb1b1b1b1, dut.terminal_in_payload_o);
  expect("wave has OUT role", 1, dut.terminal_out_valid_o);
  expect("wave OUT participant", 0, dut.terminal_out_participant_o);
  expect("wave OUT token", 5, dut.terminal_out_token_o);
  expect("wave OUT payload", 0xa0a0a0a0, dut.terminal_out_payload_o);
  expect("wave has no fault fragment", 0, dut.terminal_fault_valid_o);

  const uint32_t held_payload = dut.terminal_out_payload_o;
  for (int stall = 0; stall < 4; ++stall) {
    tick(dut);
    expect("terminal stable valid", 1, dut.terminal_valid_o);
    expect("terminal stable payload", held_payload,
           dut.terminal_out_payload_o);
  }
  dut.flush_context_i = 1;
  dut.flush_epoch_i = 3;
  dut.flush_valid_i = 1;
  tick(dut);
  dut.flush_valid_i = 0;
  expect("staged terminal is stable under later flush", 0,
         dut.terminal_kind_o);
  expect("staged terminal payload survives later flush", held_payload,
         dut.terminal_out_payload_o);

  // The key remains reserved while a terminal is stalled, but an unrelated
  // key may still enter another table entry.
  dut.fragment_context_i = 1;
  dut.fragment_epoch_i = 3;
  dut.fragment_route_id_i = 0x30;
  dut.fragment_role_i = 2;
  dut.fragment_participant_i = 0;
  dut.fragment_retire_token_i = 8;
  dut.fragment_payload_i = 0xc0c0c0c0;
  dut.fragment_valid_i = 1;
  eval_low(dut);
  expect("stalled terminal reserves route key", 0, dut.fragment_ready_o);
  dut.fragment_route_id_i = 0x31;
  eval_low(dut);
  expect("stalled terminal permits unrelated key", 1,
         dut.fragment_ready_o);
  tick(dut);
  dut.fragment_valid_i = 0;
  consume(dut);
  expect("unrelated orphan remains", 1, dut.occupancy_o);
  dut.flush_context_i = 1;
  dut.flush_epoch_i = 3;
  dut.flush_valid_i = 1;
  tick(dut);
  dut.flush_valid_i = 0;
  wait_terminal(dut);
  expect("unrelated orphan cancel", 2, dut.terminal_kind_o);
  expect("unrelated orphan key", 0x31, dut.terminal_route_id_o);
  consume(dut);
  expect("pair and orphan released", 0, dut.occupancy_o);

  // Exact flush releases an orphan through CANCEL.
  advance_epoch(dut, 0, 4);
  send(dut, 0, 4, 0x40, 2, 0, 9, 0x40404040);
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 4;
  dut.flush_valid_i = 1;
  tick(dut);
  dut.flush_valid_i = 0;
  wait_terminal(dut);
  expect("flush cancel kind", 2, dut.terminal_kind_o);
  expect("flush cancel key", 0x40, dut.terminal_route_id_o);
  consume(dut);

  // Advancing an epoch cancels older orphaned work for that context.
  advance_epoch(dut, 1, 5);
  send(dut, 1, 5, 0x50, 1, 1, 10, 0x50505050);
  dut.epoch_advance_context_i = 1;
  dut.epoch_advance_new_epoch_i = 6;
  dut.epoch_advance_valid_i = 1;
  tick(dut);
  dut.epoch_advance_valid_i = 0;
  wait_terminal(dut);
  expect("epoch cancel kind", 2, dut.terminal_kind_o);
  expect("epoch cancel old epoch", 5, dut.terminal_epoch_o);
  consume(dut);

  // Epoch advance is also an admission fence: a tardy fragment from the old
  // epoch becomes an explicit CANCEL obligation, while the new epoch remains
  // available for an ordinary rendezvous on the same route ID.
  send(dut, 1, 5, 0x51, 2, 0, 11, 0x51515151);
  wait_terminal(dut);
  expect("late old epoch cancels", 2, dut.terminal_kind_o);
  expect("late old epoch retained", 5, dut.terminal_epoch_o);
  expect("late old epoch identity retained", 1,
         dut.terminal_out_valid_o);
  consume(dut);

  send(dut, 1, 6, 0x51, 2, 0, 12, 0x52525252);
  send(dut, 1, 6, 0x51, 1, 1, 13, 0x53535353);
  dut.participant_frontier_i = (uint16_t{13} << 8) | 12;
  wait_terminal(dut);
  expect("new epoch pairs normally", 0, dut.terminal_kind_o);
  expect("new epoch preserved", 6, dut.terminal_epoch_o);
  expect("new epoch has OUT", 1, dut.terminal_out_valid_o);
  expect("new epoch has IN", 1, dut.terminal_in_valid_o);
  consume(dut);

  // A fragment racing an exact flush is accepted as a CANCEL obligation; it
  // cannot survive merely because the entry did not exist before the edge.
  advance_epoch(dut, 0, 7);
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 7;
  dut.flush_valid_i = 1;
  send(dut, 0, 7, 0x70, 1, 0, 11, 0x70707070);
  dut.flush_valid_i = 0;
  wait_terminal(dut);
  expect("same-cycle flush kind", 2, dut.terminal_kind_o);
  expect("same-cycle flush retains IN", 1, dut.terminal_in_valid_o);
  expect("same-cycle flush payload", 0x70707070,
         dut.terminal_in_payload_o);
  consume(dut);

  // A decode fault racing cancellation is reported as REJECT; the accepted
  // identity remains visible, and cancellation never hides the root cause.
  advance_epoch(dut, 0, 8);
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 8;
  dut.flush_valid_i = 1;
  send(dut, 0, 8, 0x71, 2, 0, 12, 0x71717171, false, 11);
  dut.flush_valid_i = 0;
  wait_terminal(dut);
  expect("fault beats cancel", 1, dut.terminal_kind_o);
  expect("fault beats cancel cause", 11, dut.terminal_cause_o);
  expect("fault beats cancel retains OUT", 1,
         dut.terminal_out_valid_o);
  expect("fault beats cancel payload", 0x71717171,
         dut.terminal_out_payload_o);
  consume(dut);

  // Exercise a full non-power-of-two table and the round-robin wrap.  This
  // also proves that an output handshake can be replaced immediately by the
  // next terminal without an avoidable bubble.
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  send(dut, 2, 9, 0xa0, 1, 0, 20, 0xa0a0a0a0);
  send(dut, 2, 9, 0xa1, 1, 0, 21, 0xa1a1a1a1);
  send(dut, 2, 9, 0xa2, 1, 0, 22, 0xa2a2a2a2);
  expect("three-entry table full", 3, dut.occupancy_o);
  dut.fragment_context_i = 2;
  dut.fragment_epoch_i = 9;
  dut.fragment_route_id_i = 0xa3;
  dut.fragment_role_i = 1;
  dut.fragment_participant_i = 0;
  dut.fragment_retire_token_i = 23;
  dut.fragment_payload_i = 0xa3a3a3a3;
  dut.fragment_valid_i = 1;
  eval_low(dut);
  expect("full table backpressures new key", 0, dut.fragment_ready_o);
  dut.fragment_valid_i = 0;

  dut.flush_context_i = 2;
  dut.flush_epoch_i = 9;
  dut.flush_valid_i = 1;
  tick(dut);
  dut.flush_valid_i = 0;
  expect("rr first valid", 1, dut.terminal_valid_o);
  expect("rr first key", 0xa0, dut.terminal_route_id_o);
  expect("rr first leaves two entries", 2, dut.occupancy_o);
  dut.terminal_ready_i = 1;
  tick(dut);
  expect("rr replacement remains valid", 1, dut.terminal_valid_o);
  expect("rr second key", 0xa1, dut.terminal_route_id_o);
  expect("rr second leaves one entry", 1, dut.occupancy_o);
  tick(dut);
  expect("rr third remains valid", 1, dut.terminal_valid_o);
  expect("rr third key", 0xa2, dut.terminal_route_id_o);
  expect("rr third drains table", 0, dut.occupancy_o);
  tick(dut);
  dut.terminal_ready_i = 0;
  expect("rr stream consumed", 0, dut.terminal_valid_o);

  // terminal_rr_q wrapped from physical entry two back to zero.
  advance_epoch(dut, 2, 10);
  send(dut, 2, 10, 0xa4, 2, 1, 24, 0xa4a4a4a4);
  dut.flush_context_i = 2;
  dut.flush_epoch_i = 10;
  dut.flush_valid_i = 1;
  tick(dut);
  dut.flush_valid_i = 0;
  expect("rr wrap terminal valid", 1, dut.terminal_valid_o);
  expect("rr wrap key", 0xa4, dut.terminal_route_id_o);
  consume(dut);

  eval_low(dut);
  expect("final occupancy", 0, dut.occupancy_o);
  expect("final terminal", 0, dut.terminal_valid_o);
  dut.final();
  std::cout << "PASS vsp_route_rendezvous_table " << checks
            << " checks\n";
  return 0;
}
