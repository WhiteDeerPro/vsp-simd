// Executable dependent-route reference path.
//
// This wrapper joins the pre-execution rendezvous/controller to the real
// VRF-backed route engine.  It deliberately exposes the union-resource grant
// as a handshake so a future multi-queue scheduler can place the fragment
// capture before candidate locking while keeping group ownership outside this
// leaf.  Collection may overlap one active route; launch, engine RUN and
// completion FANOUT are each single-entry elastic stages.
module vsp_cluster_route_wave_pipeline #(
  parameter int GROUP_COUNT       = 4,
  parameter int LANES_PER_GROUP   = 4,
  parameter int ELEM_W            = 8,
  parameter int VRF_ROWS          = 16,
  parameter int CONTEXT_COUNT     = 2,
  parameter int TAG_W             = 8,
  parameter int EPOCH_W           = 4,
  parameter int ROUTE_ID_W        = 8,
  parameter int PARTICIPANT_COUNT = 2,
  parameter int TOKEN_W           = 8,
  parameter int ENTRY_COUNT       = 4,
  parameter int CAUSE_W           = 4,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int PARTICIPANT_W = (PARTICIPANT_COUNT <= 2) ? 1 :
                                $clog2(PARTICIPANT_COUNT),
  parameter int VRF_ADDR_W = (VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS),
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
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

  // The request is stable until resource_ready_i.  A scheduler should assert
  // ready only when source|destination groups and route-engine ownership are
  // granted atomically.
  output logic                              resource_valid_o,
  input  logic                              resource_ready_i,
  output logic [CONTEXT_W-1:0]              resource_context_o,
  output logic [GROUP_COUNT-1:0]            resource_group_mask_o,
  output logic [EPOCH_W-1:0]                resource_epoch_o,
  output logic [ROUTE_ID_W-1:0]             resource_route_id_o,

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

  output logic                              vrf_read_valid_o,
  input  logic                              vrf_read_ready_i,
  output logic [CONTEXT_W-1:0]              vrf_read_context_o,
  output logic [TAG_W-1:0]                  vrf_read_tag_o,
  output logic [GROUP_ID_W-1:0]             vrf_read_group_o,
  output logic [VRF_ADDR_W-1:0]             vrf_read_row_o,
  output logic [LANES_PER_GROUP-1:0]        vrf_read_mask_o,
  input  logic                              vrf_read_cpl_valid_i,
  output logic                              vrf_read_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]              vrf_read_cpl_context_i,
  input  logic [TAG_W-1:0]                  vrf_read_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_read_cpl_group_i,
  input  logic                              vrf_read_cpl_error_i,
  input  logic                              vrf_read_rsp_valid_i,
  output logic                              vrf_read_rsp_ready_o,
  input  logic [CONTEXT_W-1:0]              vrf_read_rsp_context_i,
  input  logic [TAG_W-1:0]                  vrf_read_rsp_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_read_rsp_group_i,
  input  logic [(LANES_PER_GROUP*ELEM_W)-1:0]
                                                  vrf_read_rsp_data_i,
  input  logic [LANES_PER_GROUP-1:0]        vrf_read_rsp_mask_i,
  input  logic                              vrf_read_rsp_error_i,
  output logic                              vrf_write_valid_o,
  input  logic                              vrf_write_ready_i,
  output logic [CONTEXT_W-1:0]              vrf_write_context_o,
  output logic [TAG_W-1:0]                  vrf_write_tag_o,
  output logic [GROUP_ID_W-1:0]             vrf_write_group_o,
  output logic [VRF_ADDR_W-1:0]             vrf_write_row_o,
  output logic [LANES_PER_GROUP-1:0]        vrf_write_mask_o,
  output logic [(LANES_PER_GROUP*ELEM_W)-1:0]
                                                  vrf_write_data_o,
  input  logic                              vrf_write_cpl_valid_i,
  output logic                              vrf_write_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]              vrf_write_cpl_context_i,
  input  logic [TAG_W-1:0]                  vrf_write_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_write_cpl_group_i,
  input  logic                              vrf_write_cpl_error_i,

  output logic [OCCUPANCY_W-1:0]           collect_occupancy_o,
  output logic                              launch_pending_o,
  output logic                              run_active_o,
  output logic                              fanout_pending_o,
  output logic                              busy_o,
  input  logic                              protocol_error_clear_i,
  output logic                              protocol_error_o
);
  import vsp_exec_uword_pkg::*;

  logic parent_valid;
  logic parent_ready;
  logic [CONTEXT_W-1:0] parent_context;
  logic [TAG_W-1:0] parent_tag;
  logic [EPOCH_W-1:0] parent_epoch;
  logic [ROUTE_ID_W-1:0] parent_route_id;
  logic [GROUP_COUNT-1:0] parent_source_group_mask;
  logic [GROUP_COUNT-1:0] parent_destination_group_mask;
  logic [GROUP_COUNT-1:0] parent_resource_group_mask;
  logic [VRF_ADDR_W-1:0] parent_source_row;
  logic [VRF_ADDR_W-1:0] parent_index_row;
  logic [VRF_ADDR_W-1:0] parent_destination_row;

  logic engine_cmd_valid;
  logic engine_cmd_ready;
  logic engine_cpl_valid;
  logic engine_cpl_ready;
  logic [CONTEXT_W-1:0] engine_cpl_context;
  logic [TAG_W-1:0] engine_cpl_tag;
  logic [GROUP_COUNT-1:0] engine_cpl_group_mask;
  logic engine_cpl_illegal;
  logic [GROUP_COUNT-1:0] engine_cpl_illegal_group_mask;
  logic engine_cpl_rejected;
  logic engine_cpl_empty_mask;
  logic [(GROUP_COUNT*LANES_PER_GROUP)-1:0]
      engine_cpl_invalid_element_mask;
  logic engine_busy;
  logic controller_busy;
  logic controller_protocol_error;
  logic engine_protocol_error;

  // Join the external resource grant and the engine command atomically.  Each
  // sink sees valid only while the other sink is ready, so neither handshake
  // can retire alone if a future route engine deasserts cmd_ready_o in LAUNCH.
  assign resource_valid_o = parent_valid && engine_cmd_ready;
  assign resource_context_o = parent_context;
  assign resource_group_mask_o = parent_resource_group_mask;
  assign resource_epoch_o = parent_epoch;
  assign resource_route_id_o = parent_route_id;
  assign engine_cmd_valid = parent_valid && resource_ready_i;
  assign parent_ready = resource_ready_i && engine_cmd_ready;
  assign busy_o = controller_busy || engine_busy;
  assign protocol_error_o = controller_protocol_error ||
                            engine_protocol_error;

  vsp_route_wave_controller #(
    .GROUP_COUNT(GROUP_COUNT),
    .VRF_ROWS(VRF_ROWS),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .EPOCH_W(EPOCH_W),
    .ROUTE_ID_W(ROUTE_ID_W),
    .PARTICIPANT_COUNT(PARTICIPANT_COUNT),
    .TOKEN_W(TOKEN_W),
    .ENTRY_COUNT(ENTRY_COUNT),
    .CAUSE_W(CAUSE_W),
    .LANES_PER_GROUP(LANES_PER_GROUP),
    .CONTEXT_W(CONTEXT_W),
    .PARTICIPANT_W(PARTICIPANT_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .OCCUPANCY_W(OCCUPANCY_W),
    .CPL_SLOTS(CPL_SLOTS)
  ) u_wave_controller (
    .clk_i,
    .rst_ni,
    .fragment_valid_i,
    .fragment_ready_o,
    .fragment_legal_i,
    .fragment_cause_i,
    .fragment_context_i,
    .fragment_epoch_i,
    .fragment_route_id_i,
    .fragment_role_i,
    .fragment_participant_i,
    .fragment_retire_token_i,
    .fragment_tag_i,
    .fragment_group_mask_i,
    .fragment_source_row_i,
    .fragment_index_row_i,
    .fragment_destination_row_i,
    .participant_frontier_i,
    .flush_valid_i,
    .flush_context_i,
    .flush_epoch_i,
    .epoch_advance_valid_i,
    .epoch_advance_context_i,
    .epoch_advance_new_epoch_i,
    .parent_valid_o(parent_valid),
    .parent_ready_i(parent_ready),
    .parent_context_o(parent_context),
    .parent_tag_o(parent_tag),
    .parent_epoch_o(parent_epoch),
    .parent_route_id_o(parent_route_id),
    .parent_source_group_mask_o(parent_source_group_mask),
    .parent_destination_group_mask_o(parent_destination_group_mask),
    .parent_resource_group_mask_o(parent_resource_group_mask),
    .parent_source_row_o(parent_source_row),
    .parent_index_row_o(parent_index_row),
    .parent_destination_row_o(parent_destination_row),
    .parent_cpl_valid_i(engine_cpl_valid),
    .parent_cpl_ready_o(engine_cpl_ready),
    .parent_cpl_context_i(engine_cpl_context),
    .parent_cpl_tag_i(engine_cpl_tag),
    .parent_cpl_group_mask_i(engine_cpl_group_mask),
    .parent_cpl_illegal_i(engine_cpl_illegal),
    .parent_cpl_illegal_group_mask_i(engine_cpl_illegal_group_mask),
    .parent_cpl_rejected_i(engine_cpl_rejected),
    .parent_cpl_empty_mask_i(engine_cpl_empty_mask),
    .parent_cpl_owner_mismatch_i(1'b0),
    .parent_cpl_invalid_element_mask_i(
        engine_cpl_invalid_element_mask),
    .cpl_valid_o,
    .cpl_ready_i,
    .cpl_kind_o,
    .cpl_cause_o,
    .cpl_context_o,
    .cpl_epoch_o,
    .cpl_route_id_o,
    .cpl_role_o,
    .cpl_participant_o,
    .cpl_retire_token_o,
    .cpl_tag_o,
    .cpl_group_mask_o,
    .cpl_illegal_o,
    .cpl_illegal_group_mask_o,
    .cpl_rejected_o,
    .cpl_empty_mask_o,
    .cpl_owner_mismatch_o,
    .cpl_invalid_element_mask_o,
    .collect_occupancy_o,
    .launch_pending_o,
    .run_active_o,
    .fanout_pending_o,
    .busy_o(controller_busy),
    .protocol_error_clear_i,
    .protocol_error_o(controller_protocol_error)
  );

  vsp_cluster_register_route_engine #(
    .GROUP_COUNT(GROUP_COUNT),
    .LANES_PER_GROUP(LANES_PER_GROUP),
    .ELEM_W(ELEM_W),
    .INDEX_ELEM_W(8),
    .VRF_ROWS(VRF_ROWS),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .GROUP_ID_W(GROUP_ID_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W)
  ) u_route_engine (
    .clk_i,
    .rst_ni,
    .cmd_valid_i(engine_cmd_valid),
    .cmd_ready_o(engine_cmd_ready),
    .cmd_legal_i(1'b1),
    .cmd_context_i(parent_context),
    .cmd_tag_i(parent_tag),
    .cmd_source_group_mask_i(parent_source_group_mask),
    .cmd_destination_group_mask_i(parent_destination_group_mask),
    .cmd_source_row_i(parent_source_row),
    .cmd_index_row_i(parent_index_row),
    .cmd_destination_row_i(parent_destination_row),
    .cmd_io_mode_i(VSP_EXEC_ROUTE_IO_DEP_INOUT),
    .cpl_valid_o(engine_cpl_valid),
    .cpl_ready_i(engine_cpl_ready),
    .cpl_context_o(engine_cpl_context),
    .cpl_tag_o(engine_cpl_tag),
    .cpl_group_mask_o(engine_cpl_group_mask),
    .cpl_illegal_o(engine_cpl_illegal),
    .cpl_illegal_group_mask_o(engine_cpl_illegal_group_mask),
    .cpl_rejected_o(engine_cpl_rejected),
    .cpl_empty_mask_o(engine_cpl_empty_mask),
    .cpl_invalid_element_mask_o(engine_cpl_invalid_element_mask),
    .vrf_read_valid_o,
    .vrf_read_ready_i,
    .vrf_read_context_o,
    .vrf_read_tag_o,
    .vrf_read_group_o,
    .vrf_read_row_o,
    .vrf_read_mask_o,
    .vrf_read_cpl_valid_i,
    .vrf_read_cpl_ready_o,
    .vrf_read_cpl_context_i,
    .vrf_read_cpl_tag_i,
    .vrf_read_cpl_group_i,
    .vrf_read_cpl_error_i,
    .vrf_read_rsp_valid_i,
    .vrf_read_rsp_ready_o,
    .vrf_read_rsp_context_i,
    .vrf_read_rsp_tag_i,
    .vrf_read_rsp_group_i,
    .vrf_read_rsp_data_i,
    .vrf_read_rsp_mask_i,
    .vrf_read_rsp_error_i,
    .vrf_write_valid_o,
    .vrf_write_ready_i,
    .vrf_write_context_o,
    .vrf_write_tag_o,
    .vrf_write_group_o,
    .vrf_write_row_o,
    .vrf_write_mask_o,
    .vrf_write_data_o,
    .vrf_write_cpl_valid_i,
    .vrf_write_cpl_ready_o,
    .vrf_write_cpl_context_i,
    .vrf_write_cpl_tag_i,
    .vrf_write_cpl_group_i,
    .vrf_write_cpl_error_i,
    .busy_o(engine_busy),
    .protocol_error_clear_i,
    .protocol_error_o(engine_protocol_error)
  );

  initial begin
    if (ELEM_W != 8)
      $error("route-wave pipeline currently requires 8-bit lanes");
  end
endmodule
