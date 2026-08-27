module simd_issue_dispatch #(
  parameter int GROUP_COUNT   = 4,
  parameter int ISSUE_SLOTS   = 2,
  parameter int CONTEXT_COUNT = 2,
  parameter int SLOT_W = (ISSUE_SLOTS <= 2) ? 1 : $clog2(ISSUE_SLOTS),
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 : $clog2(CONTEXT_COUNT)
) (
  // Every slot has already been classified and validated as GROUP_EXEC by its
  // upstream contract. This module routes only identity and target groups; the
  // wider operation bundle remains outside so dispatch does not freeze a
  // microinstruction format or claim that a decoder exists here.
  input  logic [ISSUE_SLOTS-1:0]                 issue_valid_i,
  output logic [ISSUE_SLOTS-1:0]                 issue_ready_o,
  input  logic [(ISSUE_SLOTS*CONTEXT_W)-1:0]     issue_context_i,
  input  logic [(ISSUE_SLOTS*GROUP_COUNT)-1:0]   issue_group_mask_i,
  // Slot-specific shared resources cannot be represented by the one
  // group_ready vector. The enclosing shell uses this gate for completion
  // tracker allocation, result credits and other resources that must be
  // granted atomically with every requested group. Driving all ones preserves
  // the original group-only dispatch behavior.
  input  logic [ISSUE_SLOTS-1:0]                 issue_resource_ready_i,
  // A malformed request may retire only when its ordered error record has a
  // real destination. This is deliberately separate from group readiness.
  input  logic [ISSUE_SLOTS-1:0]                 issue_reject_ready_i,

  // A group accepts work only from its current owner context. Ownership is
  // configured at a barrier by an outer controller and is deliberately not
  // modified by this combinational dispatcher.
  input  logic [GROUP_COUNT-1:0]                  group_owner_valid_i,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]      group_owner_i,
  input  logic [GROUP_COUNT-1:0]                  group_ready_i,

  output logic [ISSUE_SLOTS-1:0]                 issue_accept_o,
  // A rejected command is consumed by the upstream queue and must generate an
  // error completion, but it never asserts a group issue valid.
  output logic [ISSUE_SLOTS-1:0]                 issue_reject_o,
  output logic [GROUP_COUNT-1:0]                  group_issue_valid_o,
  output logic [(GROUP_COUNT*SLOT_W)-1:0]         group_issue_slot_o,

  // Diagnostic reasons are valid only while the corresponding input slot is
  // valid. They let a future sequencer distinguish a wait from a bad request.
  output logic [ISSUE_SLOTS-1:0]                 empty_mask_o,
  output logic [ISSUE_SLOTS-1:0]                 owner_mismatch_o,
  output logic [ISSUE_SLOTS-1:0]                 backpressured_o,
  output logic [ISSUE_SLOTS-1:0]                 conflict_o
);
  logic [GROUP_COUNT-1:0] reserved_groups;

  always_comb begin
    issue_ready_o = '0;
    issue_accept_o = '0;
    issue_reject_o = '0;
    group_issue_valid_o = '0;
    group_issue_slot_o = '0;
    empty_mask_o = '0;
    owner_mismatch_o = '0;
    backpressured_o = '0;
    conflict_o = '0;
    reserved_groups = '0;

    // Lower-numbered slots have deterministic priority. A multicast request
    // is atomic: either every requested group accepts it in this cycle, or no
    // group observes it. Only accepted requests reserve groups, so a malformed
    // higher-priority slot cannot block a valid lower-priority one.
    for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
      logic [GROUP_COUNT-1:0] requested_groups;
      logic [CONTEXT_W-1:0] requested_context;
      logic context_valid;
      logic owners_match;
      logic all_groups_ready;
      logic overlaps_reserved;
      logic request_error;
      logic can_execute;

      requested_groups =
          issue_group_mask_i[(slot*GROUP_COUNT) +: GROUP_COUNT];
      requested_context =
          issue_context_i[(slot*CONTEXT_W) +: CONTEXT_W];
      context_valid = int'(requested_context) < CONTEXT_COUNT;
      owners_match = context_valid;
      all_groups_ready = 1'b1;

      for (int group = 0; group < GROUP_COUNT; group++) begin
        logic [CONTEXT_W-1:0] owner;
        owner = group_owner_i[(group*CONTEXT_W) +: CONTEXT_W];
        if (requested_groups[group]) begin
          owners_match &= group_owner_valid_i[group] &&
                          (int'(owner) < CONTEXT_COUNT) &&
                          (owner == requested_context);
          all_groups_ready &= group_ready_i[group];
        end
      end

      overlaps_reserved = |(requested_groups & reserved_groups);
      request_error = !(|requested_groups) || !owners_match;
      can_execute = !request_error && all_groups_ready &&
                    issue_resource_ready_i[slot] && !overlaps_reserved;
      // ready means the upstream queue may advance. A malformed request is
      // consumed only when its error sink has credit.
      issue_ready_o[slot] = request_error
          ? issue_reject_ready_i[slot] : can_execute;
      issue_accept_o[slot] = issue_valid_i[slot] && can_execute;
      issue_reject_o[slot] = issue_valid_i[slot] && request_error &&
                             issue_reject_ready_i[slot];

      empty_mask_o[slot] = issue_valid_i[slot] && !(|requested_groups);
      owner_mismatch_o[slot] = issue_valid_i[slot] &&
                               (|requested_groups) && !owners_match;
      backpressured_o[slot] = issue_valid_i[slot] &&
                              (|requested_groups) && owners_match &&
                              (!all_groups_ready ||
                               !issue_resource_ready_i[slot]);
      conflict_o[slot] = issue_valid_i[slot] &&
                         (|requested_groups) && owners_match &&
                         all_groups_ready &&
                         issue_resource_ready_i[slot] &&
                         overlaps_reserved;

      if (issue_accept_o[slot]) begin
        reserved_groups |= requested_groups;
        for (int group = 0; group < GROUP_COUNT; group++) begin
          if (requested_groups[group]) begin
            group_issue_valid_o[group] = 1'b1;
            group_issue_slot_o[(group*SLOT_W) +: SLOT_W] = SLOT_W'(slot);
          end
        end
      end
    end
  end

  initial begin
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (ISSUE_SLOTS < 1) $error("ISSUE_SLOTS must be positive");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (SLOT_W != ((ISSUE_SLOTS <= 2) ? 1 : $clog2(ISSUE_SLOTS))) begin
      $error("SLOT_W must match ISSUE_SLOTS");
    end
    if (CONTEXT_W != ((CONTEXT_COUNT <= 2) ? 1 :
                      $clog2(CONTEXT_COUNT))) begin
      $error("CONTEXT_W must match CONTEXT_COUNT");
    end
  end
endmodule
