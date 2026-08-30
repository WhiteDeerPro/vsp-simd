// CLASS: dependent route-wave admission and completion pipeline
// CLAIM: complementary route fragments rendezvous in either order, wait for
//        both retirement frontiers, form one stable parent transaction, and
//        fan one parent completion out to two independently backpressured
//        participant completions without permitting active-key ABA reuse.
// NON_CLAIMS: instruction encoding, participant-aware fetch/window wiring,
//             route datapath contents, VRF timing, or multiple concurrent RUNs.

#include "Vvsp_route_wave_controller.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr uint8_t kRoleIn = 1;
constexpr uint8_t kRoleOut = 2;
constexpr uint8_t kTermWave = 0;
constexpr uint8_t kTermReject = 1;
constexpr uint8_t kTermCancel = 2;
constexpr uint8_t kCauseBadProfile = 4;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& label, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << label << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& label, uint64_t expected,
               uint64_t actual) {
  ++checks;
  if (expected != actual) fail(label, expected, actual);
}

uint64_t slot_field(uint64_t packed, unsigned slot, unsigned width) {
  const uint64_t mask = (uint64_t{1} << width) - 1;
  return (packed >> (slot * width)) & mask;
}

void eval_low(Vvsp_route_wave_controller& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_route_wave_controller& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_fragment(Vvsp_route_wave_controller& dut) {
  dut.fragment_valid_i = 0;
  dut.fragment_legal_i = 1;
  dut.fragment_cause_i = 0;
  dut.fragment_context_i = 0;
  dut.fragment_epoch_i = 0;
  dut.fragment_route_id_i = 0;
  dut.fragment_role_i = kRoleIn;
  dut.fragment_participant_i = 0;
  dut.fragment_retire_token_i = 0;
  dut.fragment_tag_i = 0;
  dut.fragment_group_mask_i = 0;
  dut.fragment_source_row_i = 0;
  dut.fragment_index_row_i = 0;
  dut.fragment_destination_row_i = 0;
}

void clear_parent_completion(Vvsp_route_wave_controller& dut) {
  dut.parent_cpl_valid_i = 0;
  dut.parent_cpl_context_i = 0;
  dut.parent_cpl_tag_i = 0;
  dut.parent_cpl_group_mask_i = 0;
  dut.parent_cpl_illegal_i = 0;
  dut.parent_cpl_illegal_group_mask_i = 0;
  dut.parent_cpl_rejected_i = 0;
  dut.parent_cpl_empty_mask_i = 0;
  dut.parent_cpl_owner_mismatch_i = 0;
  dut.parent_cpl_invalid_element_mask_i = 0;
}

void clear_inputs(Vvsp_route_wave_controller& dut) {
  clear_fragment(dut);
  clear_parent_completion(dut);
  dut.participant_frontier_i = 0;
  dut.flush_valid_i = 0;
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 0;
  dut.epoch_advance_valid_i = 0;
  dut.epoch_advance_context_i = 0;
  dut.epoch_advance_new_epoch_i = 0;
  dut.parent_ready_i = 0;
  dut.cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_route_wave_controller& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  eval_low(dut);
  expect_eq("reset collection empty", 0, dut.collect_occupancy_o);
  expect_eq("reset parent invalid", 0, dut.parent_valid_o);
  expect_eq("reset completions invalid", 0, dut.cpl_valid_o);
  expect_eq("reset protocol clean", 0, dut.protocol_error_o);
}

void set_frontiers(Vvsp_route_wave_controller& dut, uint8_t participant0,
                   uint8_t participant1) {
  dut.participant_frontier_i =
      uint16_t{participant0} | (uint16_t{participant1} << 8);
  eval_low(dut);
}

struct Fragment {
  uint8_t context = 0;
  uint8_t epoch = 0;
  uint8_t route_id = 0;
  uint8_t role = kRoleIn;
  uint8_t participant = 0;
  uint8_t token = 0;
  uint8_t tag = 0;
  uint8_t group_mask = 0;
  uint8_t source_row = 0;
  uint8_t index_row = 0;
  uint8_t destination_row = 0;
  bool legal = true;
  uint8_t cause = 0;
};

void drive_fragment(Vvsp_route_wave_controller& dut,
                    const Fragment& fragment) {
  dut.fragment_valid_i = 1;
  dut.fragment_legal_i = fragment.legal;
  dut.fragment_cause_i = fragment.cause;
  dut.fragment_context_i = fragment.context;
  dut.fragment_epoch_i = fragment.epoch;
  dut.fragment_route_id_i = fragment.route_id;
  dut.fragment_role_i = fragment.role;
  dut.fragment_participant_i = fragment.participant;
  dut.fragment_retire_token_i = fragment.token;
  dut.fragment_tag_i = fragment.tag;
  dut.fragment_group_mask_i = fragment.group_mask;
  dut.fragment_source_row_i = fragment.source_row;
  dut.fragment_index_row_i = fragment.index_row;
  dut.fragment_destination_row_i = fragment.destination_row;
  eval_low(dut);
}

void send_fragment(Vvsp_route_wave_controller& dut,
                   const Fragment& fragment,
                   const std::string& label) {
  drive_fragment(dut, fragment);
  expect_eq(label + " ready", 1, dut.fragment_ready_o);
  tick(dut);
  clear_fragment(dut);
  eval_low(dut);
}

void expect_active_key_blocked(Vvsp_route_wave_controller& dut,
                               const Fragment& fragment,
                               const std::string& label) {
  drive_fragment(dut, fragment);
  expect_eq(label + " active key blocked", 0, dut.fragment_ready_o);
  tick(dut);
  clear_fragment(dut);
  eval_low(dut);
}

void wait_for_parent(Vvsp_route_wave_controller& dut,
                     const std::string& label) {
  for (unsigned cycle = 0; cycle < 20; ++cycle) {
    eval_low(dut);
    if (dut.parent_valid_o) return;
    expect_eq(label + " no premature completion", 0, dut.cpl_valid_o);
    tick(dut);
  }
  fail(label + " parent timeout", 1, 0);
}

void wait_for_fanout_without_parent(Vvsp_route_wave_controller& dut,
                                    const std::string& label) {
  for (unsigned cycle = 0; cycle < 20; ++cycle) {
    eval_low(dut);
    expect_eq(label + " no parent", 0, dut.parent_valid_o);
    if (dut.fanout_pending_o && dut.cpl_valid_o != 0) return;
    tick(dut);
  }
  fail(label + " fanout timeout", 1, 0);
}

void accept_parent_once(Vvsp_route_wave_controller& dut,
                        const std::string& label) {
  expect_eq(label + " parent valid", 1, dut.parent_valid_o);
  dut.parent_ready_i = 1;
  eval_low(dut);
  expect_eq(label + " launch pending", 1, dut.launch_pending_o);
  tick(dut);
  expect_eq(label + " entered RUN", 1, dut.run_active_o);
  expect_eq(label + " parent valid drops", 0, dut.parent_valid_o);

  // Keeping ready asserted cannot duplicate the parent handshake.
  for (unsigned cycle = 0; cycle < 3; ++cycle) {
    tick(dut);
    expect_eq(label + " no duplicate parent", 0, dut.parent_valid_o);
    expect_eq(label + " remains RUN", 1, dut.run_active_o);
  }
  dut.parent_ready_i = 0;
}

void drive_parent_completion(Vvsp_route_wave_controller& dut,
                             uint8_t context, uint8_t tag,
                             bool illegal = false,
                             uint8_t illegal_group_mask = 0,
                             bool rejected = false,
                             bool empty_mask = false,
                             bool owner_mismatch = false,
                             uint16_t invalid_element_mask = 0) {
  dut.parent_cpl_valid_i = 1;
  dut.parent_cpl_context_i = context;
  dut.parent_cpl_tag_i = tag;
  dut.parent_cpl_group_mask_i = 0xf;
  dut.parent_cpl_illegal_i = illegal;
  dut.parent_cpl_illegal_group_mask_i = illegal_group_mask;
  dut.parent_cpl_rejected_i = rejected;
  dut.parent_cpl_empty_mask_i = empty_mask;
  dut.parent_cpl_owner_mismatch_i = owner_mismatch;
  dut.parent_cpl_invalid_element_mask_i = invalid_element_mask;
  eval_low(dut);
}

void accept_parent_completion(Vvsp_route_wave_controller& dut,
                              const std::string& label) {
  expect_eq(label + " completion ready", 1, dut.parent_cpl_ready_o);
  tick(dut);
  clear_parent_completion(dut);
  eval_low(dut);
  expect_eq(label + " entered FANOUT", 1, dut.fanout_pending_o);
}

void expect_completion_identity(const Vvsp_route_wave_controller& dut,
                                unsigned slot, uint8_t kind,
                                uint8_t cause, uint8_t context,
                                uint8_t epoch, uint8_t route_id,
                                uint8_t role, uint8_t participant,
                                uint8_t token, uint8_t tag,
                                uint8_t group_mask,
                                const std::string& label) {
  expect_eq(label + " valid", 1, (dut.cpl_valid_o >> slot) & 1U);
  expect_eq(label + " kind", kind,
            slot_field(dut.cpl_kind_o, slot, 2));
  expect_eq(label + " cause", cause,
            slot_field(dut.cpl_cause_o, slot, 4));
  expect_eq(label + " context", context,
            slot_field(dut.cpl_context_o, slot, 1));
  expect_eq(label + " epoch", epoch,
            slot_field(dut.cpl_epoch_o, slot, 4));
  expect_eq(label + " route ID", route_id,
            slot_field(dut.cpl_route_id_o, slot, 8));
  expect_eq(label + " role", role,
            slot_field(dut.cpl_role_o, slot, 2));
  expect_eq(label + " participant", participant,
            slot_field(dut.cpl_participant_o, slot, 1));
  expect_eq(label + " token", token,
            slot_field(dut.cpl_retire_token_o, slot, 8));
  expect_eq(label + " tag", tag,
            slot_field(dut.cpl_tag_o, slot, 8));
  expect_eq(label + " group mask", group_mask,
            slot_field(dut.cpl_group_mask_o, slot, 4));
}

void consume_all_completions(Vvsp_route_wave_controller& dut,
                             const std::string& label) {
  dut.cpl_ready_i = 0x7;
  tick(dut);
  dut.cpl_ready_i = 0;
  eval_low(dut);
  expect_eq(label + " fanout drained", 0, dut.fanout_pending_o);
  expect_eq(label + " completions drained", 0, dut.cpl_valid_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_route_wave_controller dut;

  reset(dut);

  // OUT then IN: the complete pair must wait for both participant retirement
  // frontiers.  The two payloads have deliberately disjoint masks and rows so
  // an accidental whole-descriptor selection is observable.
  const Fragment out_first{0, 1, 0x31, kRoleOut, 0, 5, 0xa0,
                           0x5, 7, 0, 0};
  const Fragment in_second{0, 1, 0x31, kRoleIn, 1, 7, 0xb1,
                           0xa, 0, 8, 9};
  send_fragment(dut, out_first, "OUT-first");
  expect_eq("OUT-first collects one key", 1, dut.collect_occupancy_o);
  expect_eq("OUT-first allocates no parent", 0, dut.parent_valid_o);
  send_fragment(dut, in_second, "IN-second");
  expect_eq("complete pair still has no parent", 0, dut.parent_valid_o);

  set_frontiers(dut, 5, 6);
  for (unsigned cycle = 0; cycle < 3; ++cycle) {
    tick(dut);
    expect_eq("one frontier blocks parent", 0, dut.parent_valid_o);
  }
  set_frontiers(dut, 5, 7);
  wait_for_parent(dut, "OUT-IN wave");

  expect_eq("merged parent context", 0, dut.parent_context_o);
  expect_eq("merged parent tag follows IN", 0xb1, dut.parent_tag_o);
  expect_eq("merged parent epoch", 1, dut.parent_epoch_o);
  expect_eq("merged parent route ID", 0x31, dut.parent_route_id_o);
  expect_eq("merged source mask follows OUT", 0x5,
            dut.parent_source_group_mask_o);
  expect_eq("merged destination mask follows IN", 0xa,
            dut.parent_destination_group_mask_o);
  expect_eq("merged resource mask is union", 0xf,
            dut.parent_resource_group_mask_o);
  expect_eq("merged source row follows OUT", 7,
            dut.parent_source_row_o);
  expect_eq("merged index row follows IN", 8,
            dut.parent_index_row_o);
  expect_eq("merged destination row follows IN", 9,
            dut.parent_destination_row_o);

  // Parent backpressure must freeze every merged field.  Presenting the same
  // key cannot re-enter the now-free rendezvous entry while LAUNCH owns it.
  for (unsigned stall = 0; stall < 3; ++stall) {
    expect_active_key_blocked(dut, out_first, "LAUNCH ABA");
    expect_eq("stalled parent remains valid", 1, dut.parent_valid_o);
    expect_eq("stalled parent route ID stable", 0x31,
              dut.parent_route_id_o);
    expect_eq("stalled parent source mask stable", 0x5,
              dut.parent_source_group_mask_o);
    expect_eq("stalled parent destination mask stable", 0xa,
              dut.parent_destination_group_mask_o);
  }

  accept_parent_once(dut, "OUT-IN wave");
  expect_active_key_blocked(dut, in_second, "RUN ABA");

  drive_parent_completion(dut, 0, 0xb1, false, 0, false, false, false,
                          0x00f3);
  accept_parent_completion(dut, "OUT-IN wave");
  expect_eq("successful fanout has IN and OUT", 0x3, dut.cpl_valid_o);
  expect_completion_identity(dut, 0, kTermWave, 0, 0, 1, 0x31,
                             kRoleIn, 1, 7, 0xb1, 0xa, "IN completion");
  expect_completion_identity(dut, 1, kTermWave, 0, 0, 1, 0x31,
                             kRoleOut, 0, 5, 0xa0, 0x5,
                             "OUT completion");
  expect_eq("IN receives destination-filtered invalid detail", 0x00f0,
            slot_field(dut.cpl_invalid_element_mask_o, 0, 16));
  expect_eq("OUT receives no invalid-element detail", 0,
            slot_field(dut.cpl_invalid_element_mask_o, 1, 16));

  // Consume IN while OUT is stalled.  OUT must remain completely stable and
  // the route key remains active until the last obligation is accepted.
  dut.cpl_ready_i = 0x1;
  tick(dut);
  dut.cpl_ready_i = 0;
  eval_low(dut);
  expect_eq("only OUT remains", 0x2, dut.cpl_valid_o);
  for (unsigned stall = 0; stall < 3; ++stall) {
    expect_active_key_blocked(dut, out_first, "FANOUT ABA");
    expect_completion_identity(dut, 1, kTermWave, 0, 0, 1, 0x31,
                               kRoleOut, 0, 5, 0xa0, 0x5,
                               "stalled OUT completion");
  }
  dut.cpl_ready_i = 0x2;
  tick(dut);
  dut.cpl_ready_i = 0;
  eval_low(dut);
  expect_eq("independent fanout drained", 0, dut.fanout_pending_o);
  expect_eq("independent completions drained", 0, dut.cpl_valid_o);

  // The exact key becomes reusable only after FANOUT is completely drained.
  drive_fragment(dut, out_first);
  expect_eq("key reopens after FANOUT", 1, dut.fragment_ready_o);
  clear_fragment(dut);
  eval_low(dut);

  // IN then OUT with already-satisfied frontiers proves arrival-order
  // independence.  This completion also checks common parent error fanout and
  // destination-only invalid-element detail.
  reset(dut);
  set_frontiers(dut, 11, 13);
  const Fragment in_first{0, 2, 0x42, kRoleIn, 1, 13, 0xd2,
                          0x3, 0, 4, 5};
  const Fragment out_second{0, 2, 0x42, kRoleOut, 0, 11, 0xc1,
                            0xc, 6, 0, 0};
  send_fragment(dut, in_first, "IN-first");
  send_fragment(dut, out_second, "OUT-second");
  wait_for_parent(dut, "IN-OUT wave");
  expect_eq("reverse-order source mask", 0xc,
            dut.parent_source_group_mask_o);
  expect_eq("reverse-order destination mask", 0x3,
            dut.parent_destination_group_mask_o);
  expect_eq("reverse-order resource union", 0xf,
            dut.parent_resource_group_mask_o);
  expect_eq("reverse-order source row", 6, dut.parent_source_row_o);
  expect_eq("reverse-order index row", 4, dut.parent_index_row_o);
  expect_eq("reverse-order destination row", 5,
            dut.parent_destination_row_o);
  accept_parent_once(dut, "IN-OUT wave");
  drive_parent_completion(dut, 0, 0xd2, true, 0x9, true, false, true,
                          0x1234);
  accept_parent_completion(dut, "IN-OUT wave");
  expect_completion_identity(dut, 0, kTermWave, 0, 0, 2, 0x42,
                             kRoleIn, 1, 13, 0xd2, 0x3,
                             "reverse IN completion");
  expect_completion_identity(dut, 1, kTermWave, 0, 0, 2, 0x42,
                             kRoleOut, 0, 11, 0xc1, 0xc,
                             "reverse OUT completion");
  expect_eq("IN common illegal", 1, dut.cpl_illegal_o & 1U);
  expect_eq("OUT common illegal", 1, (dut.cpl_illegal_o >> 1) & 1U);
  expect_eq("IN illegal groups intersect destination", 0x1,
            slot_field(dut.cpl_illegal_group_mask_o, 0, 4));
  expect_eq("OUT illegal groups intersect source", 0x8,
            slot_field(dut.cpl_illegal_group_mask_o, 1, 4));
  expect_eq("common rejection reaches both", 0x3,
            dut.cpl_rejected_o & 0x3U);
  expect_eq("common owner mismatch reaches both", 0x3,
            dut.cpl_owner_mismatch_o & 0x3U);
  expect_eq("reverse IN invalid detail filtered by destination", 0x0034,
            slot_field(dut.cpl_invalid_element_mask_o, 0, 16));
  expect_eq("reverse OUT invalid detail absent", 0,
            slot_field(dut.cpl_invalid_element_mask_o, 1, 16));
  consume_all_completions(dut, "reverse-order wave");

  // A profile-invalid matching IN terminates both accepted identities as
  // REJECT and must never expose a route parent.
  reset(dut);
  set_frontiers(dut, 20, 21);
  const Fragment reject_out{0, 3, 0x53, kRoleOut, 0, 20, 0xe0,
                            0x5, 3, 0, 0};
  Fragment reject_in{0, 3, 0x53, kRoleIn, 1, 21, 0xe1,
                     0xa, 1, 4, 5};
  send_fragment(dut, reject_out, "reject OUT");
  // DEP_IN reserves source_row=0; source_row=1 is a controller profile fault.
  send_fragment(dut, reject_in, "bad-profile IN");
  wait_for_fanout_without_parent(dut, "profile reject");
  expect_eq("profile reject has two identities", 0x3, dut.cpl_valid_o);
  expect_completion_identity(dut, 0, kTermReject, kCauseBadProfile,
                             0, 3, 0x53, kRoleIn, 1, 21, 0xe1, 0xa,
                             "rejected IN");
  expect_completion_identity(dut, 1, kTermReject, kCauseBadProfile,
                             0, 3, 0x53, kRoleOut, 0, 20, 0xe0, 0x5,
                             "rejected OUT");
  expect_eq("reject marks both illegal", 0x3, dut.cpl_illegal_o & 0x3U);
  expect_eq("reject marks both rejected", 0x3,
            dut.cpl_rejected_o & 0x3U);
  expect_eq("rejected IN illegal groups follow its mask", 0xa,
            slot_field(dut.cpl_illegal_group_mask_o, 0, 4));
  expect_eq("rejected OUT illegal groups follow its mask", 0x5,
            slot_field(dut.cpl_illegal_group_mask_o, 1, 4));
  consume_all_completions(dut, "profile reject");

  // An orphaned OUT released by an exact flush becomes one CANCEL completion
  // and creates no parent transaction.
  reset(dut);
  const Fragment cancel_out{0, 4, 0x64, kRoleOut, 0, 30, 0xf0,
                            0x6, 2, 0, 0};
  send_fragment(dut, cancel_out, "cancel OUT");
  dut.flush_valid_i = 1;
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 4;
  tick(dut);
  dut.flush_valid_i = 0;
  eval_low(dut);
  wait_for_fanout_without_parent(dut, "flush cancel");
  expect_eq("cancel has only OUT identity", 0x2, dut.cpl_valid_o);
  expect_completion_identity(dut, 1, kTermCancel, 0, 0, 4, 0x64,
                             kRoleOut, 0, 30, 0xf0, 0x6,
                             "cancelled OUT");
  expect_eq("cancel is not illegal", 0, (dut.cpl_illegal_o >> 1) & 1U);
  expect_eq("cancel is an explicit rejected obligation", 1,
            (dut.cpl_rejected_o >> 1) & 1U);
  expect_eq("cancel has no illegal group detail", 0,
            slot_field(dut.cpl_illegal_group_mask_o, 1, 4));
  consume_all_completions(dut, "flush cancel");

  // A complete WAVE can already occupy the rendezvous terminal register while
  // the controller is still in COLLECT.  If flush arrives on the exact edge
  // that transfers that terminal, the transfer must become CANCEL rather than
  // briefly exposing a parent in the following cycle.
  reset(dut);
  set_frontiers(dut, 32, 33);
  const Fragment terminal_race_out{0, 5, 0x65, kRoleOut, 0, 32, 0xf2,
                                   0x3, 4, 0, 0};
  const Fragment terminal_race_in{0, 5, 0x65, kRoleIn, 1, 33, 0xf3,
                                  0xc, 0, 5, 6};
  send_fragment(dut, terminal_race_out, "terminal-race OUT");
  send_fragment(dut, terminal_race_in, "terminal-race IN");
  tick(dut);  // Move the ready table entry into its stall-stable terminal.
  expect_eq("terminal-race has not launched", 0, dut.parent_valid_o);
  dut.flush_valid_i = 1;
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 5;
  eval_low(dut);
  expect_eq("terminal-race flush suppresses parent", 0,
            dut.parent_valid_o);
  tick(dut);
  dut.flush_valid_i = 0;
  eval_low(dut);
  wait_for_fanout_without_parent(dut, "terminal-race cancel");
  expect_eq("terminal-race returns both identities", 0x3,
            dut.cpl_valid_o);
  expect_eq("terminal-race IN kind", kTermCancel,
            slot_field(dut.cpl_kind_o, 0, 2));
  expect_eq("terminal-race OUT kind", kTermCancel,
            slot_field(dut.cpl_kind_o, 1, 2));
  consume_all_completions(dut, "terminal-race cancel");

  // Cancellation wins over a stalled parent launch, including the cycle in
  // which the parent endpoint asserts ready.  Exercise both exact flush and
  // epoch-advance invalidation; neither may create a parent RUN transaction.
  for (uint8_t cancel_mode : {uint8_t{0}, uint8_t{1}}) {
    reset(dut);
    const uint8_t epoch = static_cast<uint8_t>(6 + cancel_mode);
    const uint8_t route_id = static_cast<uint8_t>(0x76 + cancel_mode);
    const Fragment launch_out{0, epoch, route_id, kRoleOut, 0, 50,
                              static_cast<uint8_t>(0xc0 + cancel_mode),
                              0x3, 13, 0, 0};
    const Fragment launch_in{0, epoch, route_id, kRoleIn, 1, 51,
                             static_cast<uint8_t>(0xd0 + cancel_mode),
                             0xc, 0, 14, 15};
    set_frontiers(dut, 50, 51);
    send_fragment(dut, launch_out, "cancel LAUNCH OUT");
    send_fragment(dut, launch_in, "cancel LAUNCH IN");
    wait_for_parent(dut, "cancelled LAUNCH wave");

    dut.parent_ready_i = 1;
    if (cancel_mode == 0) {
      dut.flush_valid_i = 1;
      dut.flush_context_i = 0;
      dut.flush_epoch_i = epoch;
    } else {
      dut.epoch_advance_valid_i = 1;
      dut.epoch_advance_context_i = 0;
      dut.epoch_advance_new_epoch_i = static_cast<uint8_t>(epoch + 1);
    }
    eval_low(dut);
    expect_eq("cancellation suppresses same-cycle parent valid", 0,
              dut.parent_valid_o);
    tick(dut);
    dut.parent_ready_i = 0;
    dut.flush_valid_i = 0;
    dut.epoch_advance_valid_i = 0;
    eval_low(dut);
    expect_eq("cancelled LAUNCH never enters RUN", 0, dut.run_active_o);
    wait_for_fanout_without_parent(dut, "cancelled LAUNCH wave");
    expect_eq("cancelled LAUNCH returns both identities", 0x3,
              dut.cpl_valid_o);
    expect_eq("cancelled LAUNCH kind IN", kTermCancel,
              slot_field(dut.cpl_kind_o, 0, 2));
    expect_eq("cancelled LAUNCH kind OUT", kTermCancel,
              slot_field(dut.cpl_kind_o, 1, 2));
    expect_eq("cancelled LAUNCH IN illegal groups zero", 0,
              slot_field(dut.cpl_illegal_group_mask_o, 0, 4));
    expect_eq("cancelled LAUNCH OUT illegal groups zero", 0,
              slot_field(dut.cpl_illegal_group_mask_o, 1, 4));
    consume_all_completions(dut, "cancelled LAUNCH wave");
  }

  // A completion belongs to exactly the launched parent transaction.  A bad
  // identity still terminates both child obligations, but marks them illegal
  // and raises a sticky protocol error until software explicitly clears it.
  reset(dut);
  set_frontiers(dut, 40, 41);
  const Fragment mismatch_out{0, 5, 0x75, kRoleOut, 0, 40, 0xa5,
                              0x3, 10, 0, 0};
  const Fragment mismatch_in{0, 5, 0x75, kRoleIn, 1, 41, 0xb5,
                             0xc, 0, 11, 12};
  send_fragment(dut, mismatch_out, "identity mismatch OUT");
  send_fragment(dut, mismatch_in, "identity mismatch IN");
  wait_for_parent(dut, "identity mismatch wave");
  accept_parent_once(dut, "identity mismatch wave");
  drive_parent_completion(dut, 0, 0xb6);
  accept_parent_completion(dut, "identity mismatch wave");
  expect_eq("identity mismatch sets sticky protocol error", 1,
            dut.protocol_error_o);
  expect_eq("identity mismatch marks both completions illegal", 0x3,
            dut.cpl_illegal_o & 0x3U);
  expect_eq("identity mismatch IN reports full participant mask", 0xc,
            slot_field(dut.cpl_illegal_group_mask_o, 0, 4));
  expect_eq("identity mismatch OUT reports full participant mask", 0x3,
            slot_field(dut.cpl_illegal_group_mask_o, 1, 4));
  expect_eq("identity mismatch does not reject completions", 0,
            dut.cpl_rejected_o & 0x3U);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  eval_low(dut);
  expect_eq("protocol error clear while fanout stalled", 0,
            dut.protocol_error_o);
  expect_eq("clear preserves pending completions", 0x3,
            dut.cpl_valid_o);
  consume_all_completions(dut, "identity mismatch wave");

  expect_eq("final controller idle", 0, dut.busy_o);
  expect_eq("final protocol clean", 0, dut.protocol_error_o);
  dut.final();
  std::cout << "PASS vsp_route_wave_controller " << checks
            << " checks\n";
  return 0;
}
