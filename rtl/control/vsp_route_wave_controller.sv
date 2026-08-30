// Dependent route-wave admission and completion pipeline.
//
// DEP_OUT and DEP_IN fragments are captured before ordinary issue ownership.
// They hold no group/engine resource while collecting or draining.  Once both
// participant retirement frontiers reach their tokens, one stable parent
// command is offered to the route engine.  The fixed completion registers are
// reserved by construction before that parent can enter RUN, then preserve
// every participant identity independently through FANOUT backpressure.
module vsp_route_wave_controller #(
  parameter int GROUP_COUNT       = 4,
  parameter int VRF_ROWS          = 16,
  parameter int CONTEXT_COUNT     = 2,
  parameter int TAG_W             = 8,
  parameter int EPOCH_W           = 4,
  parameter int ROUTE_ID_W        = 8,
  parameter int PARTICIPANT_COUNT = 2,
  parameter int TOKEN_W           = 8,
  parameter int ENTRY_COUNT       = 4,
  parameter int CAUSE_W           = 4,
  parameter int LANES_PER_GROUP   = 4,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int PARTICIPANT_W = (PARTICIPANT_COUNT <= 2) ? 1 :
                                $clog2(PARTICIPANT_COUNT),
  parameter int VRF_ADDR_W = (VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS),
  parameter int OCCUPANCY_W = (ENTRY_COUNT <= 1) ? 1 :
                              $clog2(ENTRY_COUNT + 1),
  parameter int CPL_SLOTS = 3
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                              fragment_valid_i,
  output logic                              fragment_ready_o,
  input  logic                              fragment_legal_i,
  input  logic [CAUSE_W-1:0]                fragment_cause_i,
  input  logic [CONTEXT_W-1:0]              fragment_context_i,
  input  logic [EPOCH_W-1:0]                fragment_epoch_i,
  input  logic [ROUTE_ID_W-1:0]             fragment_route_id_i,
  input  logic [vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W-1:0]
                                                  fragment_role_i,
  input  logic [PARTICIPANT_W-1:0]          fragment_participant_i,
  input  logic [TOKEN_W-1:0]                fragment_retire_token_i,
  input  logic [TAG_W-1:0]                  fragment_tag_i,
  input  logic [GROUP_COUNT-1:0]            fragment_group_mask_i,
  input  logic [VRF_ADDR_W-1:0]             fragment_source_row_i,
  input  logic [VRF_ADDR_W-1:0]             fragment_index_row_i,
  input  logic [VRF_ADDR_W-1:0]             fragment_destination_row_i,

  input  logic [(PARTICIPANT_COUNT*TOKEN_W)-1:0]
                                                  participant_frontier_i,
  input  logic                              flush_valid_i,
  input  logic [CONTEXT_W-1:0]              flush_context_i,
  input  logic [EPOCH_W-1:0]                flush_epoch_i,
  input  logic                              epoch_advance_valid_i,
  input  logic [CONTEXT_W-1:0]              epoch_advance_context_i,
  input  logic [EPOCH_W-1:0]                epoch_advance_new_epoch_i,

  // Atomic READY -> RUN handoff.  Downstream asserts ready only when the
  // route engine and the union resource mask are acquired together.
  output logic                              parent_valid_o,
  input  logic                              parent_ready_i,
  output logic [CONTEXT_W-1:0]              parent_context_o,
  output logic [TAG_W-1:0]                  parent_tag_o,
  output logic [EPOCH_W-1:0]                parent_epoch_o,
  output logic [ROUTE_ID_W-1:0]             parent_route_id_o,
  output logic [GROUP_COUNT-1:0]            parent_source_group_mask_o,
  output logic [GROUP_COUNT-1:0]            parent_destination_group_mask_o,
  output logic [GROUP_COUNT-1:0]            parent_resource_group_mask_o,
  output logic [VRF_ADDR_W-1:0]             parent_source_row_o,
  output logic [VRF_ADDR_W-1:0]             parent_index_row_o,
  output logic [VRF_ADDR_W-1:0]             parent_destination_row_o,

  input  logic                              parent_cpl_valid_i,
  output logic                              parent_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]              parent_cpl_context_i,
  input  logic [TAG_W-1:0]                  parent_cpl_tag_i,
  input  logic [GROUP_COUNT-1:0]            parent_cpl_group_mask_i,
  input  logic                              parent_cpl_illegal_i,
  input  logic [GROUP_COUNT-1:0]            parent_cpl_illegal_group_mask_i,
  input  logic                              parent_cpl_rejected_i,
  input  logic                              parent_cpl_empty_mask_i,
  input  logic                              parent_cpl_owner_mismatch_i,
  input  logic [(GROUP_COUNT*LANES_PER_GROUP)-1:0]
                                                  parent_cpl_invalid_element_mask_i,

  output logic [CPL_SLOTS-1:0]              cpl_valid_o,
  input  logic [CPL_SLOTS-1:0]              cpl_ready_i,
  output logic [(CPL_SLOTS*
                 vsp_exec_uword_pkg::VSP_ROUTE_TERMINAL_KIND_W)-1:0]
                                                  cpl_kind_o,
  output logic [(CPL_SLOTS*CAUSE_W)-1:0]     cpl_cause_o,
  output logic [(CPL_SLOTS*CONTEXT_W)-1:0]   cpl_context_o,
  output logic [(CPL_SLOTS*EPOCH_W)-1:0]     cpl_epoch_o,
  output logic [(CPL_SLOTS*ROUTE_ID_W)-1:0]  cpl_route_id_o,
  output logic [(CPL_SLOTS*
                 vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W)-1:0]
                                                  cpl_role_o,
  output logic [(CPL_SLOTS*PARTICIPANT_W)-1:0]
                                                  cpl_participant_o,
  output logic [(CPL_SLOTS*TOKEN_W)-1:0]     cpl_retire_token_o,
  output logic [(CPL_SLOTS*TAG_W)-1:0]       cpl_tag_o,
  output logic [(CPL_SLOTS*GROUP_COUNT)-1:0] cpl_group_mask_o,
  output logic [CPL_SLOTS-1:0]               cpl_illegal_o,
  output logic [(CPL_SLOTS*GROUP_COUNT)-1:0]
                                                  cpl_illegal_group_mask_o,
  output logic [CPL_SLOTS-1:0]               cpl_rejected_o,
  output logic [CPL_SLOTS-1:0]               cpl_empty_mask_o,
  output logic [CPL_SLOTS-1:0]               cpl_owner_mismatch_o,
  output logic [(CPL_SLOTS*GROUP_COUNT*LANES_PER_GROUP)-1:0]
                                                  cpl_invalid_element_mask_o,

  output logic [OCCUPANCY_W-1:0]             collect_occupancy_o,
  output logic                              launch_pending_o,
  output logic                              run_active_o,
  output logic                              fanout_pending_o,
  output logic                              busy_o,
  input  logic                              protocol_error_clear_i,
  output logic                              protocol_error_o
);
  import vsp_exec_uword_pkg::*;

  localparam int PAYLOAD_W = TAG_W + GROUP_COUNT + (3 * VRF_ADDR_W);
  localparam int SOURCE_ROW_LSB = 0;
  localparam int INDEX_ROW_LSB = SOURCE_ROW_LSB + VRF_ADDR_W;
  localparam int DESTINATION_ROW_LSB = INDEX_ROW_LSB + VRF_ADDR_W;
  localparam int GROUP_MASK_LSB = DESTINATION_ROW_LSB + VRF_ADDR_W;
  localparam int TAG_LSB = GROUP_MASK_LSB + GROUP_COUNT;
  localparam logic [CAUSE_W-1:0] CAUSE_BAD_PROFILE = CAUSE_W'(4);

  typedef enum logic [1:0] {
    PIPE_COLLECT,
    PIPE_LAUNCH,
    PIPE_RUN,
    PIPE_FANOUT
  } pipe_state_e;

  pipe_state_e state_q;
  logic protocol_error_q;

  logic table_fragment_valid;
  logic table_fragment_ready;
  logic table_fragment_legal;
  logic [CAUSE_W-1:0] table_fragment_cause;
  logic [PAYLOAD_W-1:0] table_fragment_payload;
  logic fragment_role_profile_ok;
  logic active_key_match;

  logic terminal_valid;
  logic terminal_ready;
  logic [VSP_ROUTE_TERMINAL_KIND_W-1:0] terminal_kind;
  logic [CAUSE_W-1:0] terminal_cause;
  logic [CONTEXT_W-1:0] terminal_context;
  logic [EPOCH_W-1:0] terminal_epoch;
  logic [ROUTE_ID_W-1:0] terminal_route_id;
  logic terminal_in_valid;
  logic [PARTICIPANT_W-1:0] terminal_in_participant;
  logic [TOKEN_W-1:0] terminal_in_token;
  logic [PAYLOAD_W-1:0] terminal_in_payload;
  logic terminal_out_valid;
  logic [PARTICIPANT_W-1:0] terminal_out_participant;
  logic [TOKEN_W-1:0] terminal_out_token;
  logic [PAYLOAD_W-1:0] terminal_out_payload;
  logic terminal_fault_valid;
  logic [VSP_EXEC_ROUTE_IO_W-1:0] terminal_fault_role;
  logic [PARTICIPANT_W-1:0] terminal_fault_participant;
  logic [TOKEN_W-1:0] terminal_fault_token;
  logic [PAYLOAD_W-1:0] terminal_fault_payload;
  logic [OCCUPANCY_W-1:0] table_occupancy;

  logic [CONTEXT_W-1:0] parent_context_q;
  logic [TAG_W-1:0] parent_tag_q;
  logic [EPOCH_W-1:0] parent_epoch_q;
  logic [ROUTE_ID_W-1:0] parent_route_id_q;
  logic [GROUP_COUNT-1:0] parent_source_mask_q;
  logic [GROUP_COUNT-1:0] parent_destination_mask_q;
  logic [VRF_ADDR_W-1:0] parent_source_row_q;
  logic [VRF_ADDR_W-1:0] parent_index_row_q;
  logic [VRF_ADDR_W-1:0] parent_destination_row_q;
  logic [PARTICIPANT_W-1:0] parent_in_participant_q;
  logic [TOKEN_W-1:0] parent_in_token_q;
  logic [TAG_W-1:0] parent_in_tag_q;
  logic [GROUP_COUNT-1:0] parent_in_mask_q;
  logic [PARTICIPANT_W-1:0] parent_out_participant_q;
  logic [TOKEN_W-1:0] parent_out_token_q;
  logic [TAG_W-1:0] parent_out_tag_q;
  logic [GROUP_COUNT-1:0] parent_out_mask_q;

  logic [CPL_SLOTS-1:0] cpl_valid_q;
  logic [(CPL_SLOTS*VSP_ROUTE_TERMINAL_KIND_W)-1:0] cpl_kind_q;
  logic [(CPL_SLOTS*CAUSE_W)-1:0] cpl_cause_q;
  logic [(CPL_SLOTS*CONTEXT_W)-1:0] cpl_context_q;
  logic [(CPL_SLOTS*EPOCH_W)-1:0] cpl_epoch_q;
  logic [(CPL_SLOTS*ROUTE_ID_W)-1:0] cpl_route_id_q;
  logic [(CPL_SLOTS*VSP_EXEC_ROUTE_IO_W)-1:0] cpl_role_q;
  logic [(CPL_SLOTS*PARTICIPANT_W)-1:0] cpl_participant_q;
  logic [(CPL_SLOTS*TOKEN_W)-1:0] cpl_retire_token_q;
  logic [(CPL_SLOTS*TAG_W)-1:0] cpl_tag_q;
  logic [(CPL_SLOTS*GROUP_COUNT)-1:0] cpl_group_mask_q;
  logic [CPL_SLOTS-1:0] cpl_illegal_q;
  logic [(CPL_SLOTS*GROUP_COUNT)-1:0] cpl_illegal_group_mask_q;
  logic [CPL_SLOTS-1:0] cpl_rejected_q;
  logic [CPL_SLOTS-1:0] cpl_empty_mask_q;
  logic [CPL_SLOTS-1:0] cpl_owner_mismatch_q;
  logic [(CPL_SLOTS*GROUP_COUNT*LANES_PER_GROUP)-1:0]
      cpl_invalid_element_mask_q;

  logic terminal_fire;
  logic terminal_cancel_now;
  logic terminal_cancel_pending_q;
  logic [VSP_ROUTE_TERMINAL_KIND_W-1:0] terminal_kind_effective;
  logic parent_fire;
  logic parent_cancel_now;
  logic parent_cpl_fire;
  logic parent_cpl_identity_error;
  logic fanout_consumed;
  logic [(GROUP_COUNT*LANES_PER_GROUP)-1:0]
      parent_destination_lane_mask;

  assign fragment_role_profile_ok =
      (fragment_role_i == VSP_EXEC_ROUTE_IO_DEP_OUT) ?
          ((|fragment_group_mask_i) &&
           int'(fragment_source_row_i) < VRF_ROWS &&
           fragment_index_row_i == '0 &&
           fragment_destination_row_i == '0) :
      (fragment_role_i == VSP_EXEC_ROUTE_IO_DEP_IN) ?
          ((|fragment_group_mask_i) &&
           fragment_source_row_i == '0 &&
           int'(fragment_index_row_i) < VRF_ROWS &&
           int'(fragment_destination_row_i) < VRF_ROWS) : 1'b1;
  assign table_fragment_legal = fragment_legal_i &&
                                fragment_role_profile_ok;
  assign table_fragment_cause = fragment_legal_i &&
                                !fragment_role_profile_ok ?
                                    CAUSE_BAD_PROFILE : fragment_cause_i;
  assign table_fragment_payload = {
      fragment_tag_i,
      fragment_group_mask_i,
      fragment_destination_row_i,
      fragment_index_row_i,
      fragment_source_row_i
  };

  assign active_key_match = state_q != PIPE_COLLECT &&
      fragment_context_i == parent_context_q &&
      fragment_epoch_i == parent_epoch_q &&
      fragment_route_id_i == parent_route_id_q;
  assign table_fragment_valid = fragment_valid_i && !active_key_match;
  assign fragment_ready_o = table_fragment_ready && !active_key_match;

  assign terminal_ready = state_q == PIPE_COLLECT;
  assign terminal_fire = terminal_valid && terminal_ready;
  // A table terminal may already be exposed while this controller is busy.
  // Preserve the table's stall-stability contract and remember a later kill
  // here.  At handoff it becomes a CANCEL without rewriting terminal payload.
  assign terminal_cancel_now = terminal_valid &&
      terminal_kind == VSP_ROUTE_TERMINAL_WAVE &&
      ((flush_valid_i && terminal_context == flush_context_i &&
        terminal_epoch == flush_epoch_i) ||
       (epoch_advance_valid_i &&
        terminal_context == epoch_advance_context_i &&
        terminal_epoch != epoch_advance_new_epoch_i));
  assign terminal_kind_effective =
      terminal_kind == VSP_ROUTE_TERMINAL_WAVE &&
      (terminal_cancel_pending_q || terminal_cancel_now) ?
          VSP_ROUTE_TERMINAL_CANCEL : terminal_kind;

  // parent_fire is the point of no return.  A matching kill in LAUNCH removes
  // valid combinationally, so the integrated wrapper cannot expose an engine
  // command or resource handshake on the cancellation edge.  RUN deliberately
  // drains an already accepted operation.
  assign parent_cancel_now = state_q == PIPE_LAUNCH &&
      ((flush_valid_i && parent_context_q == flush_context_i &&
        parent_epoch_q == flush_epoch_i) ||
       (epoch_advance_valid_i &&
        parent_context_q == epoch_advance_context_i &&
        parent_epoch_q != epoch_advance_new_epoch_i));
  assign parent_valid_o = state_q == PIPE_LAUNCH && !parent_cancel_now;
  assign parent_fire = parent_valid_o && parent_ready_i;
  assign parent_cpl_ready_o = state_q == PIPE_RUN;
  assign parent_cpl_fire = parent_cpl_valid_i && parent_cpl_ready_o;
  assign parent_cpl_identity_error = parent_cpl_fire &&
      (parent_cpl_context_i != parent_context_q ||
       parent_cpl_tag_i != parent_tag_q ||
       parent_cpl_group_mask_i !=
           (parent_source_mask_q | parent_destination_mask_q));
  assign fanout_consumed = state_q == PIPE_FANOUT &&
      ((cpl_valid_q & ~cpl_ready_i) == '0);

  always_comb begin
    parent_destination_lane_mask = '0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      parent_destination_lane_mask[(group*LANES_PER_GROUP) +:
                                   LANES_PER_GROUP] =
          {LANES_PER_GROUP{parent_in_mask_q[group]}};
    end
  end

  assign parent_context_o = parent_context_q;
  assign parent_tag_o = parent_tag_q;
  assign parent_epoch_o = parent_epoch_q;
  assign parent_route_id_o = parent_route_id_q;
  assign parent_source_group_mask_o = parent_source_mask_q;
  assign parent_destination_group_mask_o = parent_destination_mask_q;
  assign parent_resource_group_mask_o = parent_source_mask_q |
                                        parent_destination_mask_q;
  assign parent_source_row_o = parent_source_row_q;
  assign parent_index_row_o = parent_index_row_q;
  assign parent_destination_row_o = parent_destination_row_q;

  assign cpl_valid_o = cpl_valid_q;
  assign cpl_kind_o = cpl_kind_q;
  assign cpl_cause_o = cpl_cause_q;
  assign cpl_context_o = cpl_context_q;
  assign cpl_epoch_o = cpl_epoch_q;
  assign cpl_route_id_o = cpl_route_id_q;
  assign cpl_role_o = cpl_role_q;
  assign cpl_participant_o = cpl_participant_q;
  assign cpl_retire_token_o = cpl_retire_token_q;
  assign cpl_tag_o = cpl_tag_q;
  assign cpl_group_mask_o = cpl_group_mask_q;
  assign cpl_illegal_o = cpl_illegal_q;
  assign cpl_illegal_group_mask_o = cpl_illegal_group_mask_q;
  assign cpl_rejected_o = cpl_rejected_q;
  assign cpl_empty_mask_o = cpl_empty_mask_q;
  assign cpl_owner_mismatch_o = cpl_owner_mismatch_q;
  assign cpl_invalid_element_mask_o = cpl_invalid_element_mask_q;

  assign collect_occupancy_o = table_occupancy;
  assign launch_pending_o = state_q == PIPE_LAUNCH;
  assign run_active_o = state_q == PIPE_RUN;
  assign fanout_pending_o = state_q == PIPE_FANOUT;
  assign busy_o = state_q != PIPE_COLLECT || terminal_valid ||
                  (|table_occupancy);
  assign protocol_error_o = protocol_error_q;

  vsp_route_rendezvous_table #(
    .ENTRY_COUNT(ENTRY_COUNT),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .EPOCH_W(EPOCH_W),
    .ROUTE_ID_W(ROUTE_ID_W),
    .PARTICIPANT_COUNT(PARTICIPANT_COUNT),
    .TOKEN_W(TOKEN_W),
    .PAYLOAD_W(PAYLOAD_W),
    .CAUSE_W(CAUSE_W),
    .CONTEXT_W(CONTEXT_W),
    .PARTICIPANT_W(PARTICIPANT_W),
    .COUNT_W(OCCUPANCY_W)
  ) u_rendezvous (
    .clk_i,
    .rst_ni,
    .fragment_valid_i(table_fragment_valid),
    .fragment_ready_o(table_fragment_ready),
    .fragment_legal_i(table_fragment_legal),
    .fragment_cause_i(table_fragment_cause),
    .fragment_context_i,
    .fragment_epoch_i,
    .fragment_route_id_i,
    .fragment_role_i,
    .fragment_participant_i,
    .fragment_retire_token_i,
    .fragment_payload_i(table_fragment_payload),
    .participant_frontier_i,
    .flush_valid_i,
    .flush_context_i,
    .flush_epoch_i,
    .epoch_advance_valid_i,
    .epoch_advance_context_i,
    .epoch_advance_new_epoch_i,
    .terminal_valid_o(terminal_valid),
    .terminal_ready_i(terminal_ready),
    .terminal_kind_o(terminal_kind),
    .terminal_cause_o(terminal_cause),
    .terminal_context_o(terminal_context),
    .terminal_epoch_o(terminal_epoch),
    .terminal_route_id_o(terminal_route_id),
    .terminal_in_valid_o(terminal_in_valid),
    .terminal_in_participant_o(terminal_in_participant),
    .terminal_in_token_o(terminal_in_token),
    .terminal_in_payload_o(terminal_in_payload),
    .terminal_out_valid_o(terminal_out_valid),
    .terminal_out_participant_o(terminal_out_participant),
    .terminal_out_token_o(terminal_out_token),
    .terminal_out_payload_o(terminal_out_payload),
    .terminal_fault_valid_o(terminal_fault_valid),
    .terminal_fault_role_o(terminal_fault_role),
    .terminal_fault_participant_o(terminal_fault_participant),
    .terminal_fault_token_o(terminal_fault_token),
    .terminal_fault_payload_o(terminal_fault_payload),
    .occupancy_o(table_occupancy)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= PIPE_COLLECT;
      protocol_error_q <= 1'b0;
      parent_context_q <= '0;
      parent_tag_q <= '0;
      parent_epoch_q <= '0;
      parent_route_id_q <= '0;
      parent_source_mask_q <= '0;
      parent_destination_mask_q <= '0;
      parent_source_row_q <= '0;
      parent_index_row_q <= '0;
      parent_destination_row_q <= '0;
      parent_in_participant_q <= '0;
      parent_in_token_q <= '0;
      parent_in_tag_q <= '0;
      parent_in_mask_q <= '0;
      parent_out_participant_q <= '0;
      parent_out_token_q <= '0;
      parent_out_tag_q <= '0;
      parent_out_mask_q <= '0;
      cpl_valid_q <= '0;
      cpl_kind_q <= '0;
      cpl_cause_q <= '0;
      cpl_context_q <= '0;
      cpl_epoch_q <= '0;
      cpl_route_id_q <= '0;
      cpl_role_q <= '0;
      cpl_participant_q <= '0;
      cpl_retire_token_q <= '0;
      cpl_tag_q <= '0;
      cpl_group_mask_q <= '0;
      cpl_illegal_q <= '0;
      cpl_illegal_group_mask_q <= '0;
      cpl_rejected_q <= '0;
      cpl_empty_mask_q <= '0;
      cpl_owner_mismatch_q <= '0;
      cpl_invalid_element_mask_q <= '0;
      terminal_cancel_pending_q <= 1'b0;
    end else begin
      if (protocol_error_clear_i) protocol_error_q <= 1'b0;
      if (parent_cpl_identity_error) protocol_error_q <= 1'b1;

      if (terminal_cancel_now) terminal_cancel_pending_q <= 1'b1;
      if (terminal_fire) terminal_cancel_pending_q <= 1'b0;

      for (int slot = 0; slot < CPL_SLOTS; slot++) begin
        if (cpl_valid_q[slot] && cpl_ready_i[slot])
          cpl_valid_q[slot] <= 1'b0;
      end

      if (terminal_fire) begin
        parent_context_q <= terminal_context;
        parent_epoch_q <= terminal_epoch;
        parent_route_id_q <= terminal_route_id;
        parent_tag_q <= terminal_in_payload[TAG_LSB +: TAG_W];
        parent_source_mask_q <=
            terminal_out_payload[GROUP_MASK_LSB +: GROUP_COUNT];
        parent_destination_mask_q <=
            terminal_in_payload[GROUP_MASK_LSB +: GROUP_COUNT];
        parent_source_row_q <=
            terminal_out_payload[SOURCE_ROW_LSB +: VRF_ADDR_W];
        parent_index_row_q <=
            terminal_in_payload[INDEX_ROW_LSB +: VRF_ADDR_W];
        parent_destination_row_q <=
            terminal_in_payload[DESTINATION_ROW_LSB +: VRF_ADDR_W];
        parent_in_participant_q <= terminal_in_participant;
        parent_in_token_q <= terminal_in_token;
        parent_in_tag_q <= terminal_in_payload[TAG_LSB +: TAG_W];
        parent_in_mask_q <=
            terminal_in_payload[GROUP_MASK_LSB +: GROUP_COUNT];
        parent_out_participant_q <= terminal_out_participant;
        parent_out_token_q <= terminal_out_token;
        parent_out_tag_q <= terminal_out_payload[TAG_LSB +: TAG_W];
        parent_out_mask_q <=
            terminal_out_payload[GROUP_MASK_LSB +: GROUP_COUNT];
        cpl_valid_q <= '0;
        cpl_kind_q <= '0;
        cpl_cause_q <= '0;
        cpl_context_q <= '0;
        cpl_epoch_q <= '0;
        cpl_route_id_q <= '0;
        cpl_role_q <= '0;
        cpl_participant_q <= '0;
        cpl_retire_token_q <= '0;
        cpl_tag_q <= '0;
        cpl_group_mask_q <= '0;
        cpl_illegal_q <= '0;
        cpl_illegal_group_mask_q <= '0;
        cpl_rejected_q <= '0;
        cpl_empty_mask_q <= '0;
        cpl_owner_mismatch_q <= '0;
        cpl_invalid_element_mask_q <= '0;

        if (terminal_kind_effective == VSP_ROUTE_TERMINAL_WAVE) begin
          state_q <= PIPE_LAUNCH;
        end else begin
          cpl_valid_q[0] <= terminal_in_valid;
          cpl_kind_q[0 +: VSP_ROUTE_TERMINAL_KIND_W] <=
              terminal_kind_effective;
          cpl_cause_q[0 +: CAUSE_W] <= terminal_cause;
          cpl_context_q[0 +: CONTEXT_W] <= terminal_context;
          cpl_epoch_q[0 +: EPOCH_W] <= terminal_epoch;
          cpl_route_id_q[0 +: ROUTE_ID_W] <= terminal_route_id;
          cpl_role_q[0 +: VSP_EXEC_ROUTE_IO_W] <=
              VSP_EXEC_ROUTE_IO_DEP_IN;
          cpl_participant_q[0 +: PARTICIPANT_W] <=
              terminal_in_participant;
          cpl_retire_token_q[0 +: TOKEN_W] <= terminal_in_token;
          cpl_tag_q[0 +: TAG_W] <=
              terminal_in_payload[TAG_LSB +: TAG_W];
          cpl_group_mask_q[0 +: GROUP_COUNT] <=
              terminal_in_payload[GROUP_MASK_LSB +: GROUP_COUNT];
          cpl_illegal_q[0] <=
              terminal_kind_effective == VSP_ROUTE_TERMINAL_REJECT;
          cpl_illegal_group_mask_q[0 +: GROUP_COUNT] <=
              terminal_kind_effective == VSP_ROUTE_TERMINAL_REJECT ?
                  terminal_in_payload[GROUP_MASK_LSB +: GROUP_COUNT] : '0;
          cpl_rejected_q[0] <= 1'b1;

          cpl_valid_q[1] <= terminal_out_valid;
          cpl_kind_q[VSP_ROUTE_TERMINAL_KIND_W +:
                     VSP_ROUTE_TERMINAL_KIND_W] <=
              terminal_kind_effective;
          cpl_cause_q[CAUSE_W +: CAUSE_W] <= terminal_cause;
          cpl_context_q[CONTEXT_W +: CONTEXT_W] <= terminal_context;
          cpl_epoch_q[EPOCH_W +: EPOCH_W] <= terminal_epoch;
          cpl_route_id_q[ROUTE_ID_W +: ROUTE_ID_W] <= terminal_route_id;
          cpl_role_q[VSP_EXEC_ROUTE_IO_W +: VSP_EXEC_ROUTE_IO_W] <=
              VSP_EXEC_ROUTE_IO_DEP_OUT;
          cpl_participant_q[PARTICIPANT_W +: PARTICIPANT_W] <=
              terminal_out_participant;
          cpl_retire_token_q[TOKEN_W +: TOKEN_W] <= terminal_out_token;
          cpl_tag_q[TAG_W +: TAG_W] <=
              terminal_out_payload[TAG_LSB +: TAG_W];
          cpl_group_mask_q[GROUP_COUNT +: GROUP_COUNT] <=
              terminal_out_payload[GROUP_MASK_LSB +: GROUP_COUNT];
          cpl_illegal_q[1] <=
              terminal_kind_effective == VSP_ROUTE_TERMINAL_REJECT;
          cpl_illegal_group_mask_q[GROUP_COUNT +: GROUP_COUNT] <=
              terminal_kind_effective == VSP_ROUTE_TERMINAL_REJECT ?
                  terminal_out_payload[GROUP_MASK_LSB +: GROUP_COUNT] : '0;
          cpl_rejected_q[1] <= 1'b1;

          cpl_valid_q[2] <= terminal_fault_valid;
          cpl_kind_q[(2*VSP_ROUTE_TERMINAL_KIND_W) +:
                     VSP_ROUTE_TERMINAL_KIND_W] <=
              terminal_kind_effective;
          cpl_cause_q[(2*CAUSE_W) +: CAUSE_W] <= terminal_cause;
          cpl_context_q[(2*CONTEXT_W) +: CONTEXT_W] <= terminal_context;
          cpl_epoch_q[(2*EPOCH_W) +: EPOCH_W] <= terminal_epoch;
          cpl_route_id_q[(2*ROUTE_ID_W) +: ROUTE_ID_W] <=
              terminal_route_id;
          cpl_role_q[(2*VSP_EXEC_ROUTE_IO_W) +:
                     VSP_EXEC_ROUTE_IO_W] <= terminal_fault_role;
          cpl_participant_q[(2*PARTICIPANT_W) +: PARTICIPANT_W] <=
              terminal_fault_participant;
          cpl_retire_token_q[(2*TOKEN_W) +: TOKEN_W] <=
              terminal_fault_token;
          cpl_tag_q[(2*TAG_W) +: TAG_W] <=
              terminal_fault_payload[TAG_LSB +: TAG_W];
          cpl_group_mask_q[(2*GROUP_COUNT) +: GROUP_COUNT] <=
              terminal_fault_payload[GROUP_MASK_LSB +: GROUP_COUNT];
          cpl_illegal_q[2] <=
              terminal_kind_effective == VSP_ROUTE_TERMINAL_REJECT;
          cpl_illegal_group_mask_q[(2*GROUP_COUNT) +: GROUP_COUNT] <=
              terminal_kind_effective == VSP_ROUTE_TERMINAL_REJECT ?
                  terminal_fault_payload[GROUP_MASK_LSB +: GROUP_COUNT] : '0;
          cpl_rejected_q[2] <= 1'b1;
          state_q <= PIPE_FANOUT;
        end
      end

      if (parent_cancel_now) begin
        cpl_valid_q <= '0;
        cpl_valid_q[0] <= 1'b1;
        cpl_valid_q[1] <= 1'b1;
        cpl_kind_q <= '0;
        cpl_kind_q[0 +: VSP_ROUTE_TERMINAL_KIND_W] <=
            VSP_ROUTE_TERMINAL_CANCEL;
        cpl_kind_q[VSP_ROUTE_TERMINAL_KIND_W +:
                   VSP_ROUTE_TERMINAL_KIND_W] <=
            VSP_ROUTE_TERMINAL_CANCEL;
        cpl_cause_q <= '0;
        cpl_context_q <= '0;
        cpl_context_q[0 +: CONTEXT_W] <= parent_context_q;
        cpl_context_q[CONTEXT_W +: CONTEXT_W] <= parent_context_q;
        cpl_epoch_q <= '0;
        cpl_epoch_q[0 +: EPOCH_W] <= parent_epoch_q;
        cpl_epoch_q[EPOCH_W +: EPOCH_W] <= parent_epoch_q;
        cpl_route_id_q <= '0;
        cpl_route_id_q[0 +: ROUTE_ID_W] <= parent_route_id_q;
        cpl_route_id_q[ROUTE_ID_W +: ROUTE_ID_W] <= parent_route_id_q;
        cpl_role_q <= '0;
        cpl_role_q[0 +: VSP_EXEC_ROUTE_IO_W] <=
            VSP_EXEC_ROUTE_IO_DEP_IN;
        cpl_role_q[VSP_EXEC_ROUTE_IO_W +: VSP_EXEC_ROUTE_IO_W] <=
            VSP_EXEC_ROUTE_IO_DEP_OUT;
        cpl_participant_q <= '0;
        cpl_participant_q[0 +: PARTICIPANT_W] <= parent_in_participant_q;
        cpl_participant_q[PARTICIPANT_W +: PARTICIPANT_W] <=
            parent_out_participant_q;
        cpl_retire_token_q <= '0;
        cpl_retire_token_q[0 +: TOKEN_W] <= parent_in_token_q;
        cpl_retire_token_q[TOKEN_W +: TOKEN_W] <= parent_out_token_q;
        cpl_tag_q <= '0;
        cpl_tag_q[0 +: TAG_W] <= parent_in_tag_q;
        cpl_tag_q[TAG_W +: TAG_W] <= parent_out_tag_q;
        cpl_group_mask_q <= '0;
        cpl_group_mask_q[0 +: GROUP_COUNT] <= parent_in_mask_q;
        cpl_group_mask_q[GROUP_COUNT +: GROUP_COUNT] <= parent_out_mask_q;
        cpl_illegal_q <= '0;
        cpl_illegal_group_mask_q <= '0;
        cpl_rejected_q <= '0;
        cpl_rejected_q[0] <= 1'b1;
        cpl_rejected_q[1] <= 1'b1;
        cpl_empty_mask_q <= '0;
        cpl_owner_mismatch_q <= '0;
        cpl_invalid_element_mask_q <= '0;
        state_q <= PIPE_FANOUT;
      end

      if (parent_fire) state_q <= PIPE_RUN;

      if (parent_cpl_fire) begin
        cpl_valid_q <= '0;
        cpl_valid_q[0] <= 1'b1;
        cpl_valid_q[1] <= 1'b1;
        cpl_kind_q <= '0;
        cpl_cause_q <= '0;
        cpl_context_q <= '0;
        cpl_context_q[0 +: CONTEXT_W] <= parent_context_q;
        cpl_context_q[CONTEXT_W +: CONTEXT_W] <= parent_context_q;
        cpl_epoch_q <= '0;
        cpl_epoch_q[0 +: EPOCH_W] <= parent_epoch_q;
        cpl_epoch_q[EPOCH_W +: EPOCH_W] <= parent_epoch_q;
        cpl_route_id_q <= '0;
        cpl_route_id_q[0 +: ROUTE_ID_W] <= parent_route_id_q;
        cpl_route_id_q[ROUTE_ID_W +: ROUTE_ID_W] <= parent_route_id_q;
        cpl_role_q <= '0;
        cpl_role_q[0 +: VSP_EXEC_ROUTE_IO_W] <=
            VSP_EXEC_ROUTE_IO_DEP_IN;
        cpl_role_q[VSP_EXEC_ROUTE_IO_W +: VSP_EXEC_ROUTE_IO_W] <=
            VSP_EXEC_ROUTE_IO_DEP_OUT;
        cpl_participant_q <= '0;
        cpl_participant_q[0 +: PARTICIPANT_W] <= parent_in_participant_q;
        cpl_participant_q[PARTICIPANT_W +: PARTICIPANT_W] <=
            parent_out_participant_q;
        cpl_retire_token_q <= '0;
        cpl_retire_token_q[0 +: TOKEN_W] <= parent_in_token_q;
        cpl_retire_token_q[TOKEN_W +: TOKEN_W] <= parent_out_token_q;
        cpl_tag_q <= '0;
        cpl_tag_q[0 +: TAG_W] <= parent_in_tag_q;
        cpl_tag_q[TAG_W +: TAG_W] <= parent_out_tag_q;
        cpl_group_mask_q <= '0;
        cpl_group_mask_q[0 +: GROUP_COUNT] <= parent_in_mask_q;
        cpl_group_mask_q[GROUP_COUNT +: GROUP_COUNT] <= parent_out_mask_q;
        cpl_illegal_q <= '0;
        cpl_illegal_q[0] <= parent_cpl_illegal_i ||
                            parent_cpl_identity_error;
        cpl_illegal_q[1] <= parent_cpl_illegal_i ||
                            parent_cpl_identity_error;
        cpl_illegal_group_mask_q <= '0;
        cpl_illegal_group_mask_q[0 +: GROUP_COUNT] <=
            (parent_cpl_illegal_group_mask_i & parent_in_mask_q) |
            ({GROUP_COUNT{parent_cpl_identity_error}} & parent_in_mask_q);
        cpl_illegal_group_mask_q[GROUP_COUNT +: GROUP_COUNT] <=
            (parent_cpl_illegal_group_mask_i & parent_out_mask_q) |
            ({GROUP_COUNT{parent_cpl_identity_error}} & parent_out_mask_q);
        cpl_rejected_q <= '0;
        cpl_rejected_q[0] <= parent_cpl_rejected_i;
        cpl_rejected_q[1] <= parent_cpl_rejected_i;
        cpl_empty_mask_q <= '0;
        cpl_empty_mask_q[0] <= parent_cpl_empty_mask_i;
        cpl_empty_mask_q[1] <= parent_cpl_empty_mask_i;
        cpl_owner_mismatch_q <= '0;
        cpl_owner_mismatch_q[0] <= parent_cpl_owner_mismatch_i;
        cpl_owner_mismatch_q[1] <= parent_cpl_owner_mismatch_i;
        cpl_invalid_element_mask_q <= '0;
        cpl_invalid_element_mask_q[0 +:
            (GROUP_COUNT*LANES_PER_GROUP)] <=
                parent_cpl_invalid_element_mask_i &
                parent_destination_lane_mask;
        state_q <= PIPE_FANOUT;
      end

      if (fanout_consumed) state_q <= PIPE_COLLECT;
    end
  end

  initial begin
    if (GROUP_COUNT < 1 || LANES_PER_GROUP < 1 || VRF_ROWS < 2)
      $error("route-wave geometry must be positive");
    if (CONTEXT_COUNT < 1 || PARTICIPANT_COUNT < 2 || ENTRY_COUNT < 1)
      $error("route-wave table capacities must be valid");
    if (TAG_W < 1 || EPOCH_W < 1 || ROUTE_ID_W < 1 || TOKEN_W < 1 ||
        CAUSE_W < 1)
      $error("route-wave identity widths must be positive");
    if (CPL_SLOTS != 3)
      $error("route-wave controller currently requires three completion slots");
  end
endmodule
