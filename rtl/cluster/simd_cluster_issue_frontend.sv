module simd_cluster_issue_frontend #(
  // The first verified profile is 4 groups, 2 ordered queues and 2 issue
  // slots. Parameters remain exposed for elaboration checks and later scans.
  parameter int GROUP_COUNT     = 4,
  parameter int QUEUE_COUNT     = 2,
  parameter int ISSUE_SLOTS     = 2,
  parameter int QUEUE_DEPTH     = 4,
  parameter int TAG_W           = 8,
  parameter int PAYLOAD_W       = 32,
  parameter int RESOLVED_W      = 16,
  parameter int SCHED_META_W    = 16,
  parameter int QUEUE_W = (QUEUE_COUNT <= 2) ? 1 : $clog2(QUEUE_COUNT),
  parameter int SLOT_W = (ISSUE_SLOTS <= 2) ? 1 : $clog2(ISSUE_SLOTS),
  parameter int COUNT_W = (QUEUE_DEPTH <= 1) ? 1 :
                          $clog2(QUEUE_DEPTH + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One admission lane selects either ordered queue. payload_i is deliberately
  // opaque, but the entry must already be classified as EXEC and its
  // group mask/ownership metadata must be trustworthy. Opaque storage alone
  // does not implement raw, hybrid or full-decoded instruction adapters.
  input  logic                         enq_valid_i,
  output logic                         enq_ready_o,
  input  logic [QUEUE_W-1:0]           enq_queue_i,
  input  logic [TAG_W-1:0]             enq_tag_i,
  input  logic [PAYLOAD_W-1:0]         enq_payload_i,
  input  logic [RESOLVED_W-1:0]        enq_resolved_i,
  input  logic [SCHED_META_W-1:0]      enq_sched_meta_i,
  input  logic [GROUP_COUNT-1:0]       enq_group_mask_i,
  output logic                         enq_queue_error_o,

  // In this reference profile one queue identity is also one ownership
  // context. A future multi-stream context layer must add a distinct queue_id
  // rather than silently changing this contract.
  input  logic [GROUP_COUNT-1:0]                    group_owner_valid_i,
  input  logic [(GROUP_COUNT*QUEUE_W)-1:0]          group_owner_i,
  input  logic [GROUP_COUNT-1:0]                    group_ready_i,

  // Per-slot credits for resources shared above the groups. A cluster integration
  // may connect completion-tracker alloc_ready here so allocation, queue pop
  // and atomic multicast all commit in the same cycle. Tie high when no such
  // resource gate is required.
  input  logic [ISSUE_SLOTS-1:0]                    slot_resource_ready_i,

  // One error credit per presented slot. A reject is terminal only when the
  // corresponding bit is high in the same cycle.
  input  logic [ISSUE_SLOTS-1:0]                    reject_ready_i,

  // Stable slot views. An unlocked live head may fire immediately; if it does
  // not, the entry is captured into that slot's shadow register at the edge.
  output logic [ISSUE_SLOTS-1:0]                    slot_valid_o,
  output logic [ISSUE_SLOTS-1:0]                    slot_ready_o,
  output logic [ISSUE_SLOTS-1:0]                    slot_locked_o,
  output logic [(ISSUE_SLOTS*QUEUE_W)-1:0]          slot_queue_o,
  output logic [(ISSUE_SLOTS*TAG_W)-1:0]            slot_tag_o,
  output logic [(ISSUE_SLOTS*PAYLOAD_W)-1:0]        slot_payload_o,
  output logic [(ISSUE_SLOTS*RESOLVED_W)-1:0]       slot_resolved_o,
  output logic [(ISSUE_SLOTS*SCHED_META_W)-1:0]     slot_sched_meta_o,
  output logic [(ISSUE_SLOTS*GROUP_COUNT)-1:0]      slot_group_mask_o,

  output logic [ISSUE_SLOTS-1:0]                    slot_accept_o,
  output logic [ISSUE_SLOTS-1:0]                    slot_reject_o,
  output logic [ISSUE_SLOTS-1:0]                    empty_mask_o,
  output logic [ISSUE_SLOTS-1:0]                    owner_mismatch_o,
  output logic [ISSUE_SLOTS-1:0]                    backpressured_o,
  output logic [ISSUE_SLOTS-1:0]                    conflict_o,

  // A cluster integration may use group_issue_slot_o to select the corresponding
  // stable payload. This module neither expands nor validates that payload.
  output logic [GROUP_COUNT-1:0]                    group_issue_valid_o,
  output logic [(GROUP_COUNT*SLOT_W)-1:0]           group_issue_slot_o,

  output logic [QUEUE_COUNT-1:0]                    queue_head_valid_o,
  output logic [QUEUE_COUNT-1:0]                    queue_claimed_o,
  output logic [QUEUE_COUNT-1:0]                    queue_pop_o,
  output logic [QUEUE_COUNT-1:0]                    queue_full_o,
  output logic [(QUEUE_COUNT*COUNT_W)-1:0]          queue_occupancy_o
);
  localparam int STORED_RESOLVED_W = GROUP_COUNT + RESOLVED_W;

  logic [QUEUE_COUNT-1:0] queue_head_ready;
  logic [(QUEUE_COUNT*TAG_W)-1:0] queue_head_tag;
  logic [(QUEUE_COUNT*PAYLOAD_W)-1:0] queue_head_payload;
  logic [(QUEUE_COUNT*STORED_RESOLVED_W)-1:0]
      queue_head_stored_resolved;
  logic [(QUEUE_COUNT*SCHED_META_W)-1:0] queue_head_sched_meta;

  logic [TAG_W-1:0] head_tag [0:QUEUE_COUNT-1];
  logic [PAYLOAD_W-1:0] head_payload [0:QUEUE_COUNT-1];
  logic [RESOLVED_W-1:0] head_resolved [0:QUEUE_COUNT-1];
  logic [SCHED_META_W-1:0] head_sched_meta [0:QUEUE_COUNT-1];
  logic [GROUP_COUNT-1:0] head_group_mask [0:QUEUE_COUNT-1];

  logic [ISSUE_SLOTS-1:0] slot_locked_q;
  logic [QUEUE_W-1:0] shadow_queue_q [0:ISSUE_SLOTS-1];
  logic [TAG_W-1:0] shadow_tag_q [0:ISSUE_SLOTS-1];
  logic [PAYLOAD_W-1:0] shadow_payload_q [0:ISSUE_SLOTS-1];
  logic [RESOLVED_W-1:0] shadow_resolved_q [0:ISSUE_SLOTS-1];
  logic [SCHED_META_W-1:0]
      shadow_sched_meta_q [0:ISSUE_SLOTS-1];
  logic [GROUP_COUNT-1:0] shadow_group_mask_q [0:ISSUE_SLOTS-1];

  logic [QUEUE_W-1:0] rr_base_q;
  logic [ISSUE_SLOTS-1:0] live_select_valid;
  logic [QUEUE_W-1:0] live_select_queue [0:ISSUE_SLOTS-1];
  logic live_select_any;
  logic [QUEUE_W-1:0] live_select_last;

  logic [QUEUE_W-1:0] present_queue [0:ISSUE_SLOTS-1];
  logic [TAG_W-1:0] present_tag [0:ISSUE_SLOTS-1];
  logic [PAYLOAD_W-1:0] present_payload [0:ISSUE_SLOTS-1];
  logic [RESOLVED_W-1:0] present_resolved [0:ISSUE_SLOTS-1];
  logic [SCHED_META_W-1:0]
      present_sched_meta [0:ISSUE_SLOTS-1];
  logic [GROUP_COUNT-1:0] present_group_mask [0:ISSUE_SLOTS-1];

  logic [ISSUE_SLOTS-1:0] slot_terminal;

  function automatic logic [QUEUE_W-1:0] increment_queue(
      input logic [QUEUE_W-1:0] queue_id);
    if (int'(queue_id) == (QUEUE_COUNT - 1)) increment_queue = '0;
    else increment_queue = queue_id + 1'b1;
  endfunction

  simd_issue_queue #(
    .CONTEXT_COUNT(QUEUE_COUNT),
    .DEPTH(QUEUE_DEPTH),
    .TAG_W(TAG_W),
    .UWORD_W(PAYLOAD_W),
    .RESOLVED_W(STORED_RESOLVED_W),
    .SCHED_META_W(SCHED_META_W),
    .CONTEXT_W(QUEUE_W),
    .COUNT_W(COUNT_W)
  ) u_queue_bank (
    .clk_i,
    .rst_ni,
    .enq_valid_i,
    .enq_ready_o,
    .enq_context_i(enq_queue_i),
    .enq_tag_i,
    .enq_uword_i(enq_payload_i),
    .enq_resolved_i({enq_resolved_i, enq_group_mask_i}),
    .enq_sched_meta_i,
    .enq_context_error_o(enq_queue_error_o),
    .head_valid_o(queue_head_valid_o),
    .head_ready_i(queue_head_ready),
    .head_tag_o(queue_head_tag),
    .head_uword_o(queue_head_payload),
    .head_resolved_o(queue_head_stored_resolved),
    .head_sched_meta_o(queue_head_sched_meta),
    .full_o(queue_full_o),
    .occupancy_o(queue_occupancy_o)
  );

  always_comb begin
    for (int queue = 0; queue < QUEUE_COUNT; queue++) begin
      head_tag[queue] = queue_head_tag[(queue*TAG_W) +: TAG_W];
      head_payload[queue] =
          queue_head_payload[(queue*PAYLOAD_W) +: PAYLOAD_W];
      head_group_mask[queue] = queue_head_stored_resolved[
          (queue*STORED_RESOLVED_W) +: GROUP_COUNT];
      head_resolved[queue] = queue_head_stored_resolved[
          (queue*STORED_RESOLVED_W + GROUP_COUNT) +: RESOLVED_W];
      head_sched_meta[queue] = queue_head_sched_meta[
          (queue*SCHED_META_W) +: SCHED_META_W];
    end
  end

  // New live candidates never overlap an already locked request. This gives a
  // stalled shadow priority over younger work even though the dispatcher uses
  // fixed lower-slot priority.
  always_comb begin
    logic [QUEUE_COUNT-1:0] claimed;
    logic [GROUP_COUNT-1:0] locked_groups;

    claimed = '0;
    locked_groups = '0;
    live_select_valid = '0;
    live_select_any = 1'b0;
    live_select_last = rr_base_q;

    for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
      live_select_queue[slot] = '0;
      if (slot_locked_q[slot]) begin
        logic owner_match;

        claimed[int'(shadow_queue_q[slot])] = 1'b1;
        owner_match = |shadow_group_mask_q[slot];
        for (int group = 0; group < GROUP_COUNT; group++) begin
          if (shadow_group_mask_q[slot][group] &&
              (!group_owner_valid_i[group] ||
               group_owner_i[(group*QUEUE_W) +: QUEUE_W] !=
                   shadow_queue_q[slot])) begin
            owner_match = 1'b0;
          end
        end

        // A malformed request waiting for reject credit owns its queue entry,
        // not the requested execution groups. Reserving those groups here can
        // deadlock the rightful owner behind an unavailable error sink.
        if (owner_match) locked_groups |= shadow_group_mask_q[slot];
      end
    end

    for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
      if (!slot_locked_q[slot]) begin
        logic found;
        found = 1'b0;
        for (int offset = 0; offset < QUEUE_COUNT; offset++) begin
          int candidate;
          candidate = int'(rr_base_q) + offset;
          if (candidate >= QUEUE_COUNT) candidate -= QUEUE_COUNT;

          if (!found && queue_head_valid_o[candidate] &&
              !claimed[candidate] &&
              !(|(head_group_mask[candidate] & locked_groups))) begin
            found = 1'b1;
            live_select_valid[slot] = 1'b1;
            live_select_queue[slot] = QUEUE_W'(candidate);
            claimed[candidate] = 1'b1;
            live_select_any = 1'b1;
            live_select_last = QUEUE_W'(candidate);
          end
        end
      end
    end

    queue_claimed_o = claimed;
  end

  always_comb begin
    slot_valid_o = '0;
    slot_locked_o = slot_locked_q;
    slot_queue_o = '0;
    slot_tag_o = '0;
    slot_payload_o = '0;
    slot_resolved_o = '0;
    slot_sched_meta_o = '0;
    slot_group_mask_o = '0;

    for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
      present_queue[slot] = '0;
      present_tag[slot] = '0;
      present_payload[slot] = '0;
      present_resolved[slot] = '0;
      present_sched_meta[slot] = '0;
      present_group_mask[slot] = '0;

      if (slot_locked_q[slot]) begin
        slot_valid_o[slot] = 1'b1;
        present_queue[slot] = shadow_queue_q[slot];
        present_tag[slot] = shadow_tag_q[slot];
        present_payload[slot] = shadow_payload_q[slot];
        present_resolved[slot] = shadow_resolved_q[slot];
        present_sched_meta[slot] = shadow_sched_meta_q[slot];
        present_group_mask[slot] = shadow_group_mask_q[slot];
      end else if (live_select_valid[slot]) begin
        slot_valid_o[slot] = 1'b1;
        present_queue[slot] = live_select_queue[slot];
        present_tag[slot] = head_tag[int'(live_select_queue[slot])];
        present_payload[slot] =
            head_payload[int'(live_select_queue[slot])];
        present_resolved[slot] =
            head_resolved[int'(live_select_queue[slot])];
        present_sched_meta[slot] =
            head_sched_meta[int'(live_select_queue[slot])];
        present_group_mask[slot] =
            head_group_mask[int'(live_select_queue[slot])];
      end

      slot_queue_o[(slot*QUEUE_W) +: QUEUE_W] = present_queue[slot];
      slot_tag_o[(slot*TAG_W) +: TAG_W] = present_tag[slot];
      slot_payload_o[(slot*PAYLOAD_W) +: PAYLOAD_W] =
          present_payload[slot];
      slot_resolved_o[(slot*RESOLVED_W) +: RESOLVED_W] =
          present_resolved[slot];
      slot_sched_meta_o[(slot*SCHED_META_W) +: SCHED_META_W] =
          present_sched_meta[slot];
      slot_group_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT] =
          present_group_mask[slot];
    end
  end

  simd_issue_dispatch #(
    .GROUP_COUNT(GROUP_COUNT),
    .ISSUE_SLOTS(ISSUE_SLOTS),
    .CONTEXT_COUNT(QUEUE_COUNT),
    .SLOT_W(SLOT_W),
    .CONTEXT_W(QUEUE_W)
  ) u_dispatch (
    .issue_valid_i(slot_valid_o),
    .issue_ready_o(slot_ready_o),
    .issue_context_i(slot_queue_o),
    .issue_group_mask_i(slot_group_mask_o),
    .issue_resource_ready_i(slot_resource_ready_i),
    .issue_reject_ready_i(reject_ready_i),
    .group_owner_valid_i,
    .group_owner_i,
    .group_ready_i,
    .issue_accept_o(slot_accept_o),
    .issue_reject_o(slot_reject_o),
    .group_issue_valid_o,
    .group_issue_slot_o,
    .empty_mask_o,
    .owner_mismatch_o,
    .backpressured_o,
    .conflict_o
  );

  assign slot_terminal = slot_accept_o | slot_reject_o;

  always_comb begin
    queue_pop_o = '0;
    for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
      if (slot_terminal[slot]) begin
        queue_pop_o[int'(present_queue[slot])] = 1'b1;
      end
    end
    queue_head_ready = queue_pop_o;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      slot_locked_q <= '0;
      rr_base_q <= '0;
      for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
        shadow_queue_q[slot] <= '0;
        shadow_tag_q[slot] <= '0;
        shadow_payload_q[slot] <= '0;
        shadow_resolved_q[slot] <= '0;
        shadow_sched_meta_q[slot] <= '0;
        shadow_group_mask_q[slot] <= '0;
      end
    end else begin
      if (live_select_any) begin
        rr_base_q <= increment_queue(live_select_last);
      end

      for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
        if (slot_locked_q[slot]) begin
          if (slot_terminal[slot]) slot_locked_q[slot] <= 1'b0;
        end else if (live_select_valid[slot] && !slot_terminal[slot]) begin
          slot_locked_q[slot] <= 1'b1;
          shadow_queue_q[slot] <= present_queue[slot];
          shadow_tag_q[slot] <= present_tag[slot];
          shadow_payload_q[slot] <= present_payload[slot];
          shadow_resolved_q[slot] <= present_resolved[slot];
          shadow_sched_meta_q[slot] <= present_sched_meta[slot];
          shadow_group_mask_q[slot] <= present_group_mask[slot];
        end
      end
    end
  end

  initial begin
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (QUEUE_COUNT < 1) $error("QUEUE_COUNT must be positive");
    if (ISSUE_SLOTS < 1) $error("ISSUE_SLOTS must be positive");
    if (QUEUE_DEPTH < 1) $error("QUEUE_DEPTH must be positive");
    if (TAG_W < 1 || PAYLOAD_W < 1 || RESOLVED_W < 1 ||
        SCHED_META_W < 1) begin
      $error("frontend entry field widths must be positive");
    end
    if (QUEUE_W != ((QUEUE_COUNT <= 2) ? 1 : $clog2(QUEUE_COUNT))) begin
      $error("QUEUE_W must match QUEUE_COUNT");
    end
    if (SLOT_W != ((ISSUE_SLOTS <= 2) ? 1 : $clog2(ISSUE_SLOTS))) begin
      $error("SLOT_W must match ISSUE_SLOTS");
    end
    if (COUNT_W != ((QUEUE_DEPTH <= 1) ? 1 :
                    $clog2(QUEUE_DEPTH + 1))) begin
      $error("COUNT_W must represent zero through QUEUE_DEPTH");
    end
  end
endmodule
