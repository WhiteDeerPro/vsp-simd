module simd_cluster_exec #(
  // The first integration profile is four SIMD4 groups, two ordered
  // contexts and two issue slots.  These are implementation parameters, not
  // encoded instruction fields.
  parameter int GROUP_COUNT     = 4,
  parameter int ISSUE_SLOTS     = 2,
  parameter int QUEUE_DEPTH     = 4,
  parameter int TRACKER_ENTRIES = 4,
  parameter int LANES           = 4,
  parameter int ELEM_W          = 8,
  parameter int ACC_W           = 32,
  parameter int VREGS           = 16,
  parameter int AREGS           = 8,
  parameter int MREGS           = 4,
  parameter int CONTEXT_COUNT   = 2,
  parameter int TAG_W           = 8,
  parameter int RESOURCE_W      = 8,
  parameter int SIMD4_ID_W      = 8,
  parameter logic [SIMD4_ID_W-1:0] SIMD4_BASE_ID = '0,
  parameter int VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter int ARF_ADDR_W = (AREGS <= 2) ? 1 : $clog2(AREGS),
  parameter int MRF_ADDR_W = (MREGS <= 2) ? 1 : $clog2(MREGS),
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int SLOT_W = (ISSUE_SLOTS <= 2) ? 1 : $clog2(ISSUE_SLOTS),
  parameter int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1),
  parameter int RF_ADDR_W =
      (VRF_ADDR_W >= ARF_ADDR_W) ?
          ((VRF_ADDR_W >= MRF_ADDR_W) ? VRF_ADDR_W : MRF_ADDR_W) :
          ((ARF_ADDR_W >= MRF_ADDR_W) ? ARF_ADDR_W : MRF_ADDR_W),
  parameter int QUEUE_COUNT_W = (QUEUE_DEPTH <= 1) ? 1 :
                                $clog2(QUEUE_DEPTH + 1),
  parameter int TRACKER_COUNT_W = (TRACKER_ENTRIES <= 1) ? 1 :
                                  $clog2(TRACKER_ENTRIES + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Fully expanded reference admission.  A future compact decoder terminates
  // at this canonical boundary; none of these fields defines the external
  // instruction layout.  Context identity selects the ordered queue and is
  // also the ownership identity in this first profile.
  input  logic                              cmd_valid_i,
  output logic                              cmd_ready_o,
  input  logic [CONTEXT_W-1:0]              cmd_context_i,
  input  logic [TAG_W-1:0]                  cmd_tag_i,
  input  logic [GROUP_COUNT-1:0]            cmd_group_mask_i,
  input  logic [RESOURCE_W-1:0]             cmd_exact_resource_i,
  input  logic                              cmd_export_narrow_i,
  input  logic [simd_pkg::SIMD_OP_W-1:0]   cmd_op_i,
  input  logic [simd_pkg::ELEM_MODE_W-1:0] cmd_elem_mode_i,
  input  logic [VRF_ADDR_W-1:0]             cmd_src_a_addr_i,
  input  logic [VRF_ADDR_W-1:0]             cmd_src_b_addr_i,
  input  logic                              cmd_use_imm_i,
  input  logic [(4*ELEM_W)-1:0]             cmd_imm_i,
  input  logic [VRF_ADDR_W-1:0]             cmd_dst_vrf_addr_i,
  input  logic [ARF_ADDR_W-1:0]             cmd_src_arf_addr_i,
  input  logic [ARF_ADDR_W-1:0]             cmd_dst_arf_addr_i,
  input  logic                              cmd_mask_enable_i,
  input  logic [MRF_ADDR_W-1:0]             cmd_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]             cmd_select_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]             cmd_dst_mrf_addr_i,
  input  logic                              cmd_write_vrf_i,
  input  logic                              cmd_write_arf_i,
  input  logic                              cmd_write_mrf_i,
  input  logic                              cmd_reduce_enable_i,
  input  logic [simd_pkg::REDUCE_OP_W-1:0] cmd_reduce_op_i,
  input  logic                              cmd_route_enable_i,
  input  logic [simd_pkg::ROUTE_OP_W-1:0]  cmd_route_op_i,
  input  logic [(LANES*INDEX_W)-1:0]        cmd_route_index_i,
  input  logic [INDEX_W-1:0]                cmd_route_broadcast_index_i,
  input  logic [OFFSET_W-1:0]               cmd_route_slide_amount_i,
  input  logic [(LANES*ELEM_W)-1:0]         cmd_route_lower_i,
  input  logic [(LANES*ELEM_W)-1:0]         cmd_route_upper_i,
  output logic                              cmd_context_error_o,

  // Ownership is maintained by the future controller. This integration consumes a
  // stable snapshot and never changes ownership itself.
  input  logic [GROUP_COUNT-1:0]                   group_owner_valid_i,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]       group_owner_i,
  // Exact shared-resource grants are slot-specific.  Drive all ones when no
  // outer resource arbiter is present; tracker credit is still enforced
  // internally and cannot be bypassed by this input.
  input  logic [ISSUE_SLOTS-1:0]                   issue_slot_grant_i,
  output logic [ISSUE_SLOTS-1:0]                   issue_slot_valid_o,
  output logic [(ISSUE_SLOTS*RESOURCE_W)-1:0]      issue_slot_resource_o,
  output logic [(ISSUE_SLOTS*GROUP_COUNT)-1:0]     issue_slot_group_mask_o,

  // One trusted state-write subrequest lane. It gives a vector memory engine or a
  // reference test driver a real way to initialize group RF state without
  // turning data movement into an arithmetic opcode.  The group ID must be in
  // range while valid is asserted.
  input  logic                              state_write_valid_i,
  output logic                              state_write_ready_o,
  input  logic [GROUP_ID_W-1:0]             state_write_group_i,
  input  logic [CONTEXT_W-1:0]              state_write_context_i,
  input  logic [TAG_W-1:0]                  state_write_tag_i,
  input  logic [simd_pkg::SIMD_RF_FILE_W-1:0] state_write_file_i,
  input  logic [RF_ADDR_W-1:0]              state_write_addr_i,
  input  logic [LANES-1:0]                  state_write_mask_i,
  input  logic [(LANES*ACC_W)-1:0]          state_write_data_i,
  output logic                              state_write_group_error_o,

  output logic                              state_cpl_valid_o,
  input  logic                              state_cpl_ready_i,
  output logic [GROUP_ID_W-1:0]             state_cpl_group_o,
  output logic [CONTEXT_W-1:0]              state_cpl_context_o,
  output logic [TAG_W-1:0]                  state_cpl_tag_o,
  output logic                              state_cpl_illegal_o,

  // One trusted VRF row-read child lane. Completion and data response are
  // independent tagged channels because a vector memory engine may consume them in
  // either order. Both remain outside the EXEC tracker and result
  // collector. The group ID must be in range while valid is asserted.
  input  logic                              state_read_valid_i,
  output logic                              state_read_ready_o,
  input  logic [GROUP_ID_W-1:0]             state_read_group_i,
  input  logic [CONTEXT_W-1:0]              state_read_context_i,
  input  logic [TAG_W-1:0]                  state_read_tag_i,
  input  logic [VRF_ADDR_W-1:0]             state_read_addr_i,
  input  logic [LANES-1:0]                  state_read_mask_i,
  output logic                              state_read_group_error_o,

  output logic                              state_read_cpl_valid_o,
  input  logic                              state_read_cpl_ready_i,
  output logic [GROUP_ID_W-1:0]             state_read_cpl_group_o,
  output logic [CONTEXT_W-1:0]              state_read_cpl_context_o,
  output logic [TAG_W-1:0]                  state_read_cpl_tag_o,
  output logic                              state_read_cpl_illegal_o,

  output logic                              state_read_rsp_valid_o,
  input  logic                              state_read_rsp_ready_i,
  output logic [GROUP_ID_W-1:0]             state_read_rsp_group_o,
  output logic [CONTEXT_W-1:0]              state_read_rsp_context_o,
  output logic [TAG_W-1:0]                  state_read_rsp_tag_o,
  output logic                              state_read_rsp_illegal_o,
  output logic [(LANES*ELEM_W)-1:0]         state_read_rsp_data_o,
  output logic [LANES-1:0]                  state_read_rsp_mask_o,

  // One command-level completion.  Pre-dispatch owner/empty-mask rejects use
  // this same lossless output but are marked separately from child-execution
  // illegality.
  output logic                              cpl_valid_o,
  input  logic                              cpl_ready_i,
  output logic [CONTEXT_W-1:0]              cpl_context_o,
  output logic [TAG_W-1:0]                  cpl_tag_o,
  output logic [GROUP_COUNT-1:0]            cpl_group_mask_o,
  output logic [GROUP_COUNT-1:0]            cpl_result_mask_o,
  output logic                              cpl_illegal_o,
  output logic [GROUP_COUNT-1:0]            cpl_illegal_group_mask_o,
  output logic                              cpl_rejected_o,
  output logic                              cpl_empty_mask_o,
  output logic                              cpl_owner_mismatch_o,

  // Result records are independent of command completions.  The collector
  // owns a record once it accepts a wrapper response and then sustains normal
  // output backpressure.
  output logic                              result_valid_o,
  input  logic                              result_ready_i,
  output logic [GROUP_ID_W-1:0]             result_group_o,
  output logic [CONTEXT_W-1:0]              result_context_o,
  output logic [TAG_W-1:0]                  result_tag_o,
  output logic                              result_illegal_o,
  output logic                              result_has_narrow_o,
  output logic [(LANES*ELEM_W)-1:0]         result_narrow_o,
  output logic [LANES-1:0]                  result_narrow_mask_o,
  output logic                              result_has_reduce_o,
  output logic [ACC_W-1:0]                  result_reduce_value_o,
  output logic [INDEX_W-1:0]                result_reduce_index_o,
  output logic                              result_has_count_o,
  output logic [OFFSET_W-1:0]               result_count_o,

  // Integration observability.  These are transaction-domain state, not
  // architected CSRs.
  output logic [ISSUE_SLOTS-1:0]            issue_accept_o,
  output logic [ISSUE_SLOTS-1:0]            issue_reject_o,
  output logic [GROUP_COUNT-1:0]            group_ingress_valid_o,
  output logic [GROUP_COUNT-1:0]            group_exec_fire_o,
  // Stable topology IDs, group-major. GROUP_ID_W elsewhere in this module is
  // only the local array slot used by child transactions.
  output logic [(GROUP_COUNT*SIMD4_ID_W)-1:0] simd4_id_o,
  output logic [(CONTEXT_COUNT*QUEUE_COUNT_W)-1:0]
                                                queue_occupancy_o,
  output logic [TRACKER_COUNT_W-1:0]        tracker_occupancy_o,
  output logic [CONTEXT_COUNT-1:0]          context_exec_quiescent_o,
  input  logic                              protocol_error_clear_i,
  output logic                              protocol_error_o
);
  import simd_pkg::*;

  localparam int IMM_W = 4 * ELEM_W;
  localparam int NARROW_W = LANES * ELEM_W;

  // Private canonical bundle layout used only between the decoded admission
  // boundary, issue queue and group ingress buffers.  It is deliberately not
  // the encoded uword layout.
  localparam int P_EXPORT_NARROW = 0;
  localparam int P_OP = P_EXPORT_NARROW + 1;
  localparam int P_ELEM_MODE = P_OP + SIMD_OP_W;
  localparam int P_SRC_A = P_ELEM_MODE + ELEM_MODE_W;
  localparam int P_SRC_B = P_SRC_A + VRF_ADDR_W;
  localparam int P_USE_IMM = P_SRC_B + VRF_ADDR_W;
  localparam int P_IMM = P_USE_IMM + 1;
  localparam int P_DST_VRF = P_IMM + IMM_W;
  localparam int P_SRC_ARF = P_DST_VRF + VRF_ADDR_W;
  localparam int P_DST_ARF = P_SRC_ARF + ARF_ADDR_W;
  localparam int P_MASK_ENABLE = P_DST_ARF + ARF_ADDR_W;
  localparam int P_MASK_ADDR = P_MASK_ENABLE + 1;
  localparam int P_SELECT_MASK_ADDR = P_MASK_ADDR + MRF_ADDR_W;
  localparam int P_DST_MRF = P_SELECT_MASK_ADDR + MRF_ADDR_W;
  localparam int P_WRITE_VRF = P_DST_MRF + MRF_ADDR_W;
  localparam int P_WRITE_ARF = P_WRITE_VRF + 1;
  localparam int P_WRITE_MRF = P_WRITE_ARF + 1;
  localparam int P_REDUCE_ENABLE = P_WRITE_MRF + 1;
  localparam int P_REDUCE_OP = P_REDUCE_ENABLE + 1;
  localparam int P_ROUTE_ENABLE = P_REDUCE_OP + REDUCE_OP_W;
  localparam int P_ROUTE_OP = P_ROUTE_ENABLE + 1;
  localparam int P_ROUTE_INDEX = P_ROUTE_OP + ROUTE_OP_W;
  localparam int P_ROUTE_BROADCAST = P_ROUTE_INDEX + LANES*INDEX_W;
  localparam int P_ROUTE_SLIDE = P_ROUTE_BROADCAST + INDEX_W;
  localparam int P_ROUTE_LOWER = P_ROUTE_SLIDE + OFFSET_W;
  localparam int P_ROUTE_UPPER = P_ROUTE_LOWER + NARROW_W;
  localparam int EXEC_PAYLOAD_W = P_ROUTE_UPPER + NARROW_W;

  logic [EXEC_PAYLOAD_W-1:0] command_payload;

  logic [ISSUE_SLOTS-1:0] slot_valid;
  /* verilator lint_off UNUSED */
  logic [ISSUE_SLOTS-1:0] slot_ready_unused;
  logic [ISSUE_SLOTS-1:0] slot_locked_unused;
  logic [ISSUE_SLOTS-1:0] slot_backpressured_unused;
  logic [ISSUE_SLOTS-1:0] slot_conflict_unused;
  /* verilator lint_on UNUSED */
  logic [(ISSUE_SLOTS*CONTEXT_W)-1:0] slot_context_flat;
  logic [(ISSUE_SLOTS*TAG_W)-1:0] slot_tag_flat;
  logic [(ISSUE_SLOTS*EXEC_PAYLOAD_W)-1:0] slot_payload_flat;
  logic [(ISSUE_SLOTS*GROUP_COUNT)-1:0] slot_group_mask_flat;
  logic [ISSUE_SLOTS-1:0] slot_empty_mask;
  logic [ISSUE_SLOTS-1:0] slot_owner_mismatch;
  logic [ISSUE_SLOTS-1:0] reject_ready;
  logic [GROUP_COUNT-1:0] group_issue_valid;
  logic [(GROUP_COUNT*SLOT_W)-1:0] group_issue_slot_flat;
  logic [CONTEXT_COUNT-1:0] queue_head_valid_unused;
  logic [CONTEXT_COUNT-1:0] queue_claimed_unused;
  logic [CONTEXT_COUNT-1:0] queue_pop_unused;
  logic [CONTEXT_COUNT-1:0] queue_full_unused;
  logic [(ISSUE_SLOTS*1)-1:0] slot_resolved_unused;

  logic [EXEC_PAYLOAD_W-1:0] slot_payload [0:ISSUE_SLOTS-1];
  logic [CONTEXT_W-1:0] slot_context [0:ISSUE_SLOTS-1];
  logic [TAG_W-1:0] slot_tag [0:ISSUE_SLOTS-1];
  logic [GROUP_COUNT-1:0] slot_group_mask [0:ISSUE_SLOTS-1];
  logic [ISSUE_SLOTS-1:0] slot_requires_result;
  logic [ISSUE_SLOTS-1:0] slot_precheck_ok;
  logic [ISSUE_SLOTS-1:0] slot_nontracker_ready;

  logic [ISSUE_SLOTS-1:0] tracker_alloc_valid;
  logic [ISSUE_SLOTS-1:0] tracker_alloc_ready;
  logic [ISSUE_SLOTS-1:0] slot_resource_ready;
  logic [(ISSUE_SLOTS*GROUP_COUNT)-1:0] tracker_alloc_result_mask;
  logic [ISSUE_SLOTS-1:0] tracker_alloc_error_unused;
  logic [ISSUE_SLOTS-1:0] tracker_alloc_tag_busy_unused;
  logic [ISSUE_SLOTS-1:0] tracker_alloc_no_space_unused;
  logic [ISSUE_SLOTS-1:0] tracker_alloc_commit_error_unused;

  logic [GROUP_COUNT-1:0] ingress_valid_q;
  logic [EXEC_PAYLOAD_W-1:0] ingress_payload_q [0:GROUP_COUNT-1];
  logic [CONTEXT_W-1:0] ingress_context_q [0:GROUP_COUNT-1];
  logic [TAG_W-1:0] ingress_tag_q [0:GROUP_COUNT-1];
  logic [GROUP_COUNT-1:0] ingress_ready;
  logic [GROUP_COUNT-1:0] ingress_pop;

  logic [GROUP_COUNT-1:0] wrapper_exec_ready;
  logic [GROUP_COUNT-1:0] wrapper_state_write_valid;
  logic [GROUP_COUNT-1:0] wrapper_state_write_ready;
  logic [GROUP_COUNT-1:0] wrapper_state_read_valid;
  logic [GROUP_COUNT-1:0] wrapper_state_read_ready;
  logic [GROUP_COUNT-1:0] wrapper_state_read_cpl_valid;
  logic [GROUP_COUNT-1:0] wrapper_state_read_cpl_ready;
  logic [(GROUP_COUNT*CONTEXT_W)-1:0] wrapper_state_read_cpl_context;
  logic [(GROUP_COUNT*TAG_W)-1:0] wrapper_state_read_cpl_tag;
  logic [GROUP_COUNT-1:0] wrapper_state_read_cpl_illegal;
  logic [GROUP_COUNT-1:0] wrapper_state_read_rsp_valid;
  logic [GROUP_COUNT-1:0] wrapper_state_read_rsp_ready;
  logic [(GROUP_COUNT*CONTEXT_W)-1:0] wrapper_state_read_rsp_context;
  logic [(GROUP_COUNT*TAG_W)-1:0] wrapper_state_read_rsp_tag;
  logic [GROUP_COUNT-1:0] wrapper_state_read_rsp_illegal;
  logic [(GROUP_COUNT*NARROW_W)-1:0] wrapper_state_read_rsp_data;
  logic [(GROUP_COUNT*LANES)-1:0] wrapper_state_read_rsp_mask;
  logic [GROUP_COUNT-1:0] wrapper_cpl_valid;
  logic [GROUP_COUNT-1:0] wrapper_cpl_ready;
  logic [(GROUP_COUNT*CONTEXT_W)-1:0] wrapper_cpl_context;
  logic [(GROUP_COUNT*TAG_W)-1:0] wrapper_cpl_tag;
  logic [(GROUP_COUNT*SIMD_GROUP_REQ_KIND_W)-1:0] wrapper_cpl_kind;
  logic [GROUP_COUNT-1:0] wrapper_cpl_illegal;
  logic [GROUP_COUNT-1:0] wrapper_cpl_has_result;

  logic [GROUP_COUNT-1:0] wrapper_rsp_valid;
  logic [GROUP_COUNT-1:0] wrapper_rsp_ready;
  logic [(GROUP_COUNT*CONTEXT_W)-1:0] wrapper_rsp_context;
  logic [(GROUP_COUNT*TAG_W)-1:0] wrapper_rsp_tag;
  logic [GROUP_COUNT-1:0] wrapper_rsp_illegal;
  logic [GROUP_COUNT-1:0] wrapper_rsp_has_narrow;
  logic [(GROUP_COUNT*NARROW_W)-1:0] wrapper_rsp_narrow;
  logic [(GROUP_COUNT*LANES)-1:0] wrapper_rsp_narrow_mask;
  logic [GROUP_COUNT-1:0] wrapper_rsp_has_reduce;
  logic [(GROUP_COUNT*ACC_W)-1:0] wrapper_rsp_reduce_value;
  logic [(GROUP_COUNT*INDEX_W)-1:0] wrapper_rsp_reduce_index;
  logic [GROUP_COUNT-1:0] wrapper_rsp_has_count;
  logic [(GROUP_COUNT*OFFSET_W)-1:0] wrapper_rsp_count;

  logic [GROUP_COUNT-1:0] tracker_child_cpl_valid;
  logic [GROUP_COUNT-1:0] tracker_child_cpl_ready;
  logic [GROUP_COUNT-1:0] tracker_child_cpl_unknown_unused;
  logic [GROUP_COUNT-1:0] tracker_child_cpl_wrong_group_unused;
  logic [GROUP_COUNT-1:0] tracker_child_cpl_duplicate_unused;
  logic [GROUP_COUNT-1:0] tracker_child_cpl_result_mismatch_unused;
  logic [GROUP_COUNT-1:0] collector_rsp_retire;
  logic [(GROUP_COUNT*CONTEXT_W)-1:0] collector_rsp_context;
  logic [(GROUP_COUNT*TAG_W)-1:0] collector_rsp_tag;
  logic [GROUP_COUNT-1:0] tracker_child_rsp_unknown_unused;
  logic [GROUP_COUNT-1:0] tracker_child_rsp_wrong_group_unused;
  logic [GROUP_COUNT-1:0] tracker_child_rsp_duplicate_unused;

  logic tracker_cpl_valid;
  logic tracker_cpl_ready;
  logic [CONTEXT_W-1:0] tracker_cpl_context;
  logic [TAG_W-1:0] tracker_cpl_tag;
  logic [GROUP_COUNT-1:0] tracker_cpl_group_mask;
  logic [GROUP_COUNT-1:0] tracker_cpl_result_mask;
  logic tracker_cpl_illegal;
  logic [GROUP_COUNT-1:0] tracker_cpl_illegal_group_mask;
  logic [CONTEXT_COUNT-1:0] tracker_context_exec_inflight_unused;
  logic [CONTEXT_COUNT-1:0] tracker_context_tag_busy_unused;
  logic [TRACKER_ENTRIES-1:0] tracker_entries_active_unused;
  logic tracker_full_unused;

  logic reject_valid_q;
  logic [CONTEXT_W-1:0] reject_context_q;
  logic [TAG_W-1:0] reject_tag_q;
  logic [GROUP_COUNT-1:0] reject_group_mask_q;
  logic reject_empty_mask_q;
  logic reject_owner_mismatch_q;
  logic reject_pop;
  logic reject_can_push;

  logic completion_valid_q;
  logic [CONTEXT_W-1:0] completion_context_q;
  logic [TAG_W-1:0] completion_tag_q;
  logic [GROUP_COUNT-1:0] completion_group_mask_q;
  logic [GROUP_COUNT-1:0] completion_result_mask_q;
  logic completion_illegal_q;
  logic [GROUP_COUNT-1:0] completion_illegal_group_mask_q;
  logic completion_rejected_q;
  logic completion_empty_mask_q;
  logic completion_owner_mismatch_q;
  logic prefer_reject_q;
  logic completion_can_push;
  logic take_tracker_completion;
  logic take_reject_completion;

  logic [GROUP_ID_W-1:0] state_rr_q;
  logic state_cpl_hold_valid_q;
  logic [GROUP_ID_W-1:0] state_cpl_hold_group_q;
  logic state_cpl_select_valid;
  logic [GROUP_ID_W-1:0] state_cpl_select_group;
  logic state_cpl_fire;

  logic [GROUP_ID_W-1:0] state_read_cpl_rr_q;
  logic state_read_cpl_hold_valid_q;
  logic [GROUP_ID_W-1:0] state_read_cpl_hold_group_q;
  logic state_read_cpl_select_valid;
  logic [GROUP_ID_W-1:0] state_read_cpl_select_group;
  logic state_read_cpl_fire;

  logic [GROUP_ID_W-1:0] state_read_rsp_rr_q;
  logic state_read_rsp_hold_valid_q;
  logic [GROUP_ID_W-1:0] state_read_rsp_hold_group_q;
  logic state_read_rsp_select_valid;
  logic [GROUP_ID_W-1:0] state_read_rsp_select_group;
  logic state_read_rsp_fire;

  always_comb begin
    command_payload = '0;
    command_payload[P_EXPORT_NARROW] = cmd_export_narrow_i;
    command_payload[P_OP +: SIMD_OP_W] = cmd_op_i;
    command_payload[P_ELEM_MODE +: ELEM_MODE_W] = cmd_elem_mode_i;
    command_payload[P_SRC_A +: VRF_ADDR_W] = cmd_src_a_addr_i;
    command_payload[P_SRC_B +: VRF_ADDR_W] = cmd_src_b_addr_i;
    command_payload[P_USE_IMM] = cmd_use_imm_i;
    command_payload[P_IMM +: IMM_W] = cmd_imm_i;
    command_payload[P_DST_VRF +: VRF_ADDR_W] = cmd_dst_vrf_addr_i;
    command_payload[P_SRC_ARF +: ARF_ADDR_W] = cmd_src_arf_addr_i;
    command_payload[P_DST_ARF +: ARF_ADDR_W] = cmd_dst_arf_addr_i;
    command_payload[P_MASK_ENABLE] = cmd_mask_enable_i;
    command_payload[P_MASK_ADDR +: MRF_ADDR_W] = cmd_mask_addr_i;
    command_payload[P_SELECT_MASK_ADDR +: MRF_ADDR_W] =
        cmd_select_mask_addr_i;
    command_payload[P_DST_MRF +: MRF_ADDR_W] = cmd_dst_mrf_addr_i;
    command_payload[P_WRITE_VRF] = cmd_write_vrf_i;
    command_payload[P_WRITE_ARF] = cmd_write_arf_i;
    command_payload[P_WRITE_MRF] = cmd_write_mrf_i;
    command_payload[P_REDUCE_ENABLE] = cmd_reduce_enable_i;
    command_payload[P_REDUCE_OP +: REDUCE_OP_W] = cmd_reduce_op_i;
    command_payload[P_ROUTE_ENABLE] = cmd_route_enable_i;
    command_payload[P_ROUTE_OP +: ROUTE_OP_W] = cmd_route_op_i;
    command_payload[P_ROUTE_INDEX +: LANES*INDEX_W] = cmd_route_index_i;
    command_payload[P_ROUTE_BROADCAST +: INDEX_W] =
        cmd_route_broadcast_index_i;
    command_payload[P_ROUTE_SLIDE +: OFFSET_W] =
        cmd_route_slide_amount_i;
    command_payload[P_ROUTE_LOWER +: NARROW_W] = cmd_route_lower_i;
    command_payload[P_ROUTE_UPPER +: NARROW_W] = cmd_route_upper_i;
  end

  simd_cluster_issue_frontend #(
    .GROUP_COUNT(GROUP_COUNT),
    .QUEUE_COUNT(CONTEXT_COUNT),
    .ISSUE_SLOTS(ISSUE_SLOTS),
    .QUEUE_DEPTH(QUEUE_DEPTH),
    .TAG_W(TAG_W),
    .PAYLOAD_W(EXEC_PAYLOAD_W),
    .RESOLVED_W(1),
    .SCHED_META_W(RESOURCE_W),
    .QUEUE_W(CONTEXT_W),
    .SLOT_W(SLOT_W),
    .COUNT_W(QUEUE_COUNT_W)
  ) u_issue_frontend (
    .clk_i,
    .rst_ni,
    .enq_valid_i(cmd_valid_i),
    .enq_ready_o(cmd_ready_o),
    .enq_queue_i(cmd_context_i),
    .enq_tag_i(cmd_tag_i),
    .enq_payload_i(command_payload),
    .enq_resolved_i(1'b0),
    .enq_sched_meta_i(cmd_exact_resource_i),
    .enq_group_mask_i(cmd_group_mask_i),
    .enq_queue_error_o(cmd_context_error_o),
    .group_owner_valid_i,
    .group_owner_i,
    .group_ready_i(ingress_ready),
    .slot_resource_ready_i(slot_resource_ready),
    .reject_ready_i(reject_ready),
    .slot_valid_o(slot_valid),
    .slot_ready_o(slot_ready_unused),
    .slot_locked_o(slot_locked_unused),
    .slot_queue_o(slot_context_flat),
    .slot_tag_o(slot_tag_flat),
    .slot_payload_o(slot_payload_flat),
    .slot_resolved_o(slot_resolved_unused),
    .slot_sched_meta_o(issue_slot_resource_o),
    .slot_group_mask_o(slot_group_mask_flat),
    .slot_accept_o(issue_accept_o),
    .slot_reject_o(issue_reject_o),
    .empty_mask_o(slot_empty_mask),
    .owner_mismatch_o(slot_owner_mismatch),
    .backpressured_o(slot_backpressured_unused),
    .conflict_o(slot_conflict_unused),
    .group_issue_valid_o(group_issue_valid),
    .group_issue_slot_o(group_issue_slot_flat),
    .queue_head_valid_o(queue_head_valid_unused),
    .queue_claimed_o(queue_claimed_unused),
    .queue_pop_o(queue_pop_unused),
    .queue_full_o(queue_full_unused),
    .queue_occupancy_o(queue_occupancy_o)
  );

  assign issue_slot_valid_o = slot_valid;
  assign issue_slot_group_mask_o = slot_group_mask_flat;

  for (genvar slot = 0; slot < ISSUE_SLOTS; slot++) begin : g_slot_view
    assign slot_context[slot] =
        slot_context_flat[(slot*CONTEXT_W) +: CONTEXT_W];
    assign slot_tag[slot] = slot_tag_flat[(slot*TAG_W) +: TAG_W];
    assign slot_payload[slot] =
        slot_payload_flat[(slot*EXEC_PAYLOAD_W) +: EXEC_PAYLOAD_W];
    assign slot_group_mask[slot] =
        slot_group_mask_flat[(slot*GROUP_COUNT) +: GROUP_COUNT];
    assign slot_requires_result[slot] = simd_exec_requires_result(
        slot_payload[slot][P_OP +: SIMD_OP_W],
        slot_payload[slot][P_EXPORT_NARROW],
        slot_payload[slot][P_REDUCE_ENABLE]);

    // Malformed requests go to the reject sink and must not reserve a tracker
    // entry merely because their context/tag fields happen to be well formed.
    assign tracker_alloc_valid[slot] = slot_nontracker_ready[slot];
    assign tracker_alloc_result_mask[
        (slot*GROUP_COUNT) +: GROUP_COUNT] = slot_requires_result[slot]
            ? slot_group_mask[slot] : '0;
  end


  assign slot_resource_ready = tracker_alloc_ready & issue_slot_grant_i;


  // Recompute only the dispatcher's static request precheck here rather than
  // feeding its diagnostic outputs back into reject/tracker readiness.  This
  // preserves the same rule while keeping the valid/ready graph acyclic.
  always_comb begin
    slot_precheck_ok = '0;
    slot_nontracker_ready = '0;
    for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
      logic owners_match;
      logic all_groups_ready;
      owners_match = (int'(slot_context[slot]) < CONTEXT_COUNT) &&
                     (|slot_group_mask[slot]);
      all_groups_ready = 1'b1;
      for (int group = 0; group < GROUP_COUNT; group++) begin
        if (slot_group_mask[slot][group]) begin
          owners_match &= group_owner_valid_i[group] &&
              (int'(group_owner_i[(group*CONTEXT_W) +: CONTEXT_W]) <
                   CONTEXT_COUNT) &&
              (group_owner_i[(group*CONTEXT_W) +: CONTEXT_W] ==
                   slot_context[slot]);
          all_groups_ready &= ingress_ready[group];
        end
      end
      slot_precheck_ok[slot] = slot_valid[slot] && owners_match;
      // Only candidates that can fire apart from tracker credit participate
      // in entry reservation.  Otherwise a grant-disabled or locally blocked
      // low slot could consume the sole preview entry and starve an unrelated
      // ready slot without ever committing that reservation.
      slot_nontracker_ready[slot] = slot_valid[slot] && owners_match &&
          all_groups_ready && issue_slot_grant_i[slot];
    end
  end

  simd_group_completion_tracker #(
    .GROUP_COUNT(GROUP_COUNT),
    .ALLOC_SLOTS(ISSUE_SLOTS),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .ENTRY_COUNT(TRACKER_ENTRIES),
    .CONTEXT_W(CONTEXT_W),
    .COUNT_W(TRACKER_COUNT_W)
  ) u_completion_tracker (
    .clk_i,
    .rst_ni,
    .alloc_valid_i(tracker_alloc_valid),
    .alloc_ready_o(tracker_alloc_ready),
    .alloc_commit_i(issue_accept_o),
    .alloc_context_i(slot_context_flat),
    .alloc_tag_i(slot_tag_flat),
    .alloc_group_mask_i(slot_group_mask_flat),
    .alloc_result_mask_i(tracker_alloc_result_mask),
    .alloc_error_o(tracker_alloc_error_unused),
    .alloc_tag_busy_o(tracker_alloc_tag_busy_unused),
    .alloc_no_space_o(tracker_alloc_no_space_unused),
    .alloc_commit_error_o(tracker_alloc_commit_error_unused),
    .child_cpl_valid_i(tracker_child_cpl_valid),
    .child_cpl_ready_o(tracker_child_cpl_ready),
    .child_cpl_context_i(wrapper_cpl_context),
    .child_cpl_tag_i(wrapper_cpl_tag),
    .child_cpl_illegal_i(wrapper_cpl_illegal),
    .child_cpl_has_result_i(wrapper_cpl_has_result),
    .child_cpl_unknown_o(tracker_child_cpl_unknown_unused),
    .child_cpl_wrong_group_o(tracker_child_cpl_wrong_group_unused),
    .child_cpl_duplicate_o(tracker_child_cpl_duplicate_unused),
    .child_cpl_result_mismatch_o(
        tracker_child_cpl_result_mismatch_unused),
    .child_rsp_retire_i(collector_rsp_retire),
    .child_rsp_context_i(collector_rsp_context),
    .child_rsp_tag_i(collector_rsp_tag),
    .child_rsp_unknown_o(tracker_child_rsp_unknown_unused),
    .child_rsp_wrong_group_o(tracker_child_rsp_wrong_group_unused),
    .child_rsp_duplicate_o(tracker_child_rsp_duplicate_unused),
    .cmd_cpl_valid_o(tracker_cpl_valid),
    .cmd_cpl_ready_i(tracker_cpl_ready),
    .cmd_cpl_context_o(tracker_cpl_context),
    .cmd_cpl_tag_o(tracker_cpl_tag),
    .cmd_cpl_group_mask_o(tracker_cpl_group_mask),
    .cmd_cpl_result_mask_o(tracker_cpl_result_mask),
    .cmd_cpl_illegal_o(tracker_cpl_illegal),
    .cmd_cpl_illegal_group_mask_o(tracker_cpl_illegal_group_mask),
    .context_exec_inflight_o(tracker_context_exec_inflight_unused),
    .context_tag_busy_o(tracker_context_tag_busy_unused),
    .context_quiescent_o(context_exec_quiescent_o),
    .entries_active_o(tracker_entries_active_unused),
    .full_o(tracker_full_unused),
    .occupancy_o(tracker_occupancy_o),
    .protocol_error_clear_i,
    .protocol_error_o
  );

  // An accepted multicast is transferred atomically into all of its target
  // ingress buffers.  Each group may then drain independently without making
  // the queue/tracker transaction partially visible.
  always_comb begin
    for (int group = 0; group < GROUP_COUNT; group++) begin
      ingress_pop[group] = ingress_valid_q[group] &&
                           wrapper_exec_ready[group];
      ingress_ready[group] = !ingress_valid_q[group] ||
                             ingress_pop[group];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ingress_valid_q <= '0;
      for (int group = 0; group < GROUP_COUNT; group++) begin
        ingress_payload_q[group] <= '0;
        ingress_context_q[group] <= '0;
        ingress_tag_q[group] <= '0;
      end
    end else begin
      for (int group = 0; group < GROUP_COUNT; group++) begin
        if (ingress_pop[group]) ingress_valid_q[group] <= 1'b0;
        if (group_issue_valid[group]) begin
          ingress_valid_q[group] <= 1'b1;
          ingress_payload_q[group] <= slot_payload[
              group_issue_slot_flat[(group*SLOT_W) +: SLOT_W]];
          ingress_context_q[group] <= slot_context[
              group_issue_slot_flat[(group*SLOT_W) +: SLOT_W]];
          ingress_tag_q[group] <= slot_tag[
              group_issue_slot_flat[(group*SLOT_W) +: SLOT_W]];
        end
      end
    end
  end

  assign group_ingress_valid_o = ingress_valid_q;
  assign group_exec_fire_o = ingress_pop;

  always_comb begin
    wrapper_state_write_valid = '0;
    state_write_ready_o = 1'b0;
    state_write_group_error_o = state_write_valid_i &&
                                (int'(state_write_group_i) >= GROUP_COUNT);
    if (int'(state_write_group_i) < GROUP_COUNT) begin
      wrapper_state_write_valid[state_write_group_i] = state_write_valid_i;
      state_write_ready_o = wrapper_state_write_ready[state_write_group_i];
    end
  end

  always_comb begin
    wrapper_state_read_valid = '0;
    state_read_ready_o = 1'b0;
    state_read_group_error_o = state_read_valid_i &&
                               (int'(state_read_group_i) >= GROUP_COUNT);
    if (int'(state_read_group_i) < GROUP_COUNT) begin
      wrapper_state_read_valid[state_read_group_i] = state_read_valid_i;
      state_read_ready_o = wrapper_state_read_ready[state_read_group_i];
    end
  end

  for (genvar group = 0; group < GROUP_COUNT; group++) begin : g_group
    localparam logic [SIMD4_ID_W-1:0] GROUP_SIMD4_ID =
        SIMD4_BASE_ID + SIMD4_ID_W'(group);

    assign tracker_child_cpl_valid[group] = wrapper_cpl_valid[group] &&
        (wrapper_cpl_kind[(group*SIMD_GROUP_REQ_KIND_W) +:
                          SIMD_GROUP_REQ_KIND_W] == SIMD_GROUP_REQ_EXEC);

    simd_group_wrapper #(
      .LANES(LANES),
      .ELEM_W(ELEM_W),
      .ACC_W(ACC_W),
      .VREGS(VREGS),
      .AREGS(AREGS),
      .MREGS(MREGS),
      .CONTEXT_COUNT(CONTEXT_COUNT),
      .TAG_W(TAG_W),
      .SIMD4_ID_W(SIMD4_ID_W),
      .SIMD4_ID(GROUP_SIMD4_ID),
      .VRF_ADDR_W(VRF_ADDR_W),
      .ARF_ADDR_W(ARF_ADDR_W),
      .MRF_ADDR_W(MRF_ADDR_W),
      .CONTEXT_W(CONTEXT_W),
      .INDEX_W(INDEX_W),
      .OFFSET_W(OFFSET_W),
      .RF_ADDR_W(RF_ADDR_W)
    ) u_group_wrapper (
      .clk_i,
      .rst_ni,
      .simd4_id_o(simd4_id_o[(group*SIMD4_ID_W) +: SIMD4_ID_W]),
      .exec_valid_i(ingress_valid_q[group]),
      .exec_ready_o(wrapper_exec_ready[group]),
      .exec_context_i(ingress_context_q[group]),
      .exec_tag_i(ingress_tag_q[group]),
      .exec_export_narrow_i(
          ingress_payload_q[group][P_EXPORT_NARROW]),
      .exec_op_i(ingress_payload_q[group][P_OP +: SIMD_OP_W]),
      .exec_elem_mode_i(
          ingress_payload_q[group][P_ELEM_MODE +: ELEM_MODE_W]),
      .exec_src_a_addr_i(
          ingress_payload_q[group][P_SRC_A +: VRF_ADDR_W]),
      .exec_src_b_addr_i(
          ingress_payload_q[group][P_SRC_B +: VRF_ADDR_W]),
      .exec_use_imm_i(ingress_payload_q[group][P_USE_IMM]),
      .exec_imm_i(ingress_payload_q[group][P_IMM +: IMM_W]),
      .exec_dst_vrf_addr_i(
          ingress_payload_q[group][P_DST_VRF +: VRF_ADDR_W]),
      .exec_src_arf_addr_i(
          ingress_payload_q[group][P_SRC_ARF +: ARF_ADDR_W]),
      .exec_dst_arf_addr_i(
          ingress_payload_q[group][P_DST_ARF +: ARF_ADDR_W]),
      .exec_mask_enable_i(
          ingress_payload_q[group][P_MASK_ENABLE]),
      .exec_mask_addr_i(
          ingress_payload_q[group][P_MASK_ADDR +: MRF_ADDR_W]),
      .exec_select_mask_addr_i(
          ingress_payload_q[group][P_SELECT_MASK_ADDR +: MRF_ADDR_W]),
      .exec_dst_mrf_addr_i(
          ingress_payload_q[group][P_DST_MRF +: MRF_ADDR_W]),
      .exec_write_vrf_i(ingress_payload_q[group][P_WRITE_VRF]),
      .exec_write_arf_i(ingress_payload_q[group][P_WRITE_ARF]),
      .exec_write_mrf_i(ingress_payload_q[group][P_WRITE_MRF]),
      .exec_reduce_enable_i(
          ingress_payload_q[group][P_REDUCE_ENABLE]),
      .exec_reduce_op_i(
          ingress_payload_q[group][P_REDUCE_OP +: REDUCE_OP_W]),
      .exec_route_enable_i(
          ingress_payload_q[group][P_ROUTE_ENABLE]),
      .exec_route_op_i(
          ingress_payload_q[group][P_ROUTE_OP +: ROUTE_OP_W]),
      .exec_route_index_i(
          ingress_payload_q[group][P_ROUTE_INDEX +: LANES*INDEX_W]),
      .exec_route_broadcast_index_i(
          ingress_payload_q[group][P_ROUTE_BROADCAST +: INDEX_W]),
      .exec_route_slide_amount_i(
          ingress_payload_q[group][P_ROUTE_SLIDE +: OFFSET_W]),
      .exec_route_lower_i(
          ingress_payload_q[group][P_ROUTE_LOWER +: NARROW_W]),
      .exec_route_upper_i(
          ingress_payload_q[group][P_ROUTE_UPPER +: NARROW_W]),
      .state_write_valid_i(wrapper_state_write_valid[group]),
      .state_write_ready_o(wrapper_state_write_ready[group]),
      .state_write_context_i(state_write_context_i),
      .state_write_tag_i(state_write_tag_i),
      .state_write_file_i(state_write_file_i),
      .state_write_addr_i(state_write_addr_i),
      .state_write_mask_i(state_write_mask_i),
      .state_write_data_i(state_write_data_i),
      .state_read_valid_i(wrapper_state_read_valid[group]),
      .state_read_ready_o(wrapper_state_read_ready[group]),
      .state_read_context_i(state_read_context_i),
      .state_read_tag_i(state_read_tag_i),
      .state_read_addr_i(state_read_addr_i),
      .state_read_mask_i(state_read_mask_i),
      .state_read_cpl_valid_o(wrapper_state_read_cpl_valid[group]),
      .state_read_cpl_ready_i(wrapper_state_read_cpl_ready[group]),
      .state_read_cpl_context_o(wrapper_state_read_cpl_context[
          (group*CONTEXT_W) +: CONTEXT_W]),
      .state_read_cpl_tag_o(wrapper_state_read_cpl_tag[
          (group*TAG_W) +: TAG_W]),
      .state_read_cpl_illegal_o(wrapper_state_read_cpl_illegal[group]),
      .state_read_rsp_valid_o(wrapper_state_read_rsp_valid[group]),
      .state_read_rsp_ready_i(wrapper_state_read_rsp_ready[group]),
      .state_read_rsp_context_o(wrapper_state_read_rsp_context[
          (group*CONTEXT_W) +: CONTEXT_W]),
      .state_read_rsp_tag_o(wrapper_state_read_rsp_tag[
          (group*TAG_W) +: TAG_W]),
      .state_read_rsp_illegal_o(wrapper_state_read_rsp_illegal[group]),
      .state_read_rsp_data_o(wrapper_state_read_rsp_data[
          (group*NARROW_W) +: NARROW_W]),
      .state_read_rsp_mask_o(wrapper_state_read_rsp_mask[
          (group*LANES) +: LANES]),
      .cpl_valid_o(wrapper_cpl_valid[group]),
      .cpl_ready_i(wrapper_cpl_ready[group]),
      .cpl_context_o(wrapper_cpl_context[
          (group*CONTEXT_W) +: CONTEXT_W]),
      .cpl_tag_o(wrapper_cpl_tag[(group*TAG_W) +: TAG_W]),
      .cpl_kind_o(wrapper_cpl_kind[
          (group*SIMD_GROUP_REQ_KIND_W) +: SIMD_GROUP_REQ_KIND_W]),
      .cpl_illegal_o(wrapper_cpl_illegal[group]),
      .cpl_has_result_o(wrapper_cpl_has_result[group]),
      .rsp_valid_o(wrapper_rsp_valid[group]),
      .rsp_ready_i(wrapper_rsp_ready[group]),
      .rsp_context_o(wrapper_rsp_context[
          (group*CONTEXT_W) +: CONTEXT_W]),
      .rsp_tag_o(wrapper_rsp_tag[(group*TAG_W) +: TAG_W]),
      .rsp_illegal_o(wrapper_rsp_illegal[group]),
      .rsp_has_narrow_o(wrapper_rsp_has_narrow[group]),
      .rsp_narrow_o(wrapper_rsp_narrow[
          (group*NARROW_W) +: NARROW_W]),
      .rsp_narrow_mask_o(wrapper_rsp_narrow_mask[
          (group*LANES) +: LANES]),
      .rsp_has_reduce_o(wrapper_rsp_has_reduce[group]),
      .rsp_reduce_value_o(wrapper_rsp_reduce_value[
          (group*ACC_W) +: ACC_W]),
      .rsp_reduce_index_o(wrapper_rsp_reduce_index[
          (group*INDEX_W) +: INDEX_W]),
      .rsp_has_count_o(wrapper_rsp_has_count[group]),
      .rsp_count_o(wrapper_rsp_count[
          (group*OFFSET_W) +: OFFSET_W])
    );
  end

  // Completion-kind demultiplexing keeps MEMORY/state-write children out of
  // the EXEC tracker.  The state path has a stable RR-selected output.
  always_comb begin
    if (state_cpl_hold_valid_q) begin
      state_cpl_select_valid = 1'b1;
      state_cpl_select_group = state_cpl_hold_group_q;
    end else begin
      state_cpl_select_valid = 1'b0;
      state_cpl_select_group = '0;
      for (int offset = 0; offset < GROUP_COUNT; offset++) begin
        int candidate;
        candidate = int'(state_rr_q) + offset;
        if (candidate >= GROUP_COUNT) candidate -= GROUP_COUNT;
        if (!state_cpl_select_valid && wrapper_cpl_valid[candidate] &&
            wrapper_cpl_kind[(candidate*SIMD_GROUP_REQ_KIND_W) +:
                             SIMD_GROUP_REQ_KIND_W] ==
                SIMD_GROUP_REQ_STATE_WRITE) begin
          state_cpl_select_valid = 1'b1;
          state_cpl_select_group = GROUP_ID_W'(candidate);
        end
      end
    end
  end

  always_comb begin
    wrapper_cpl_ready = '0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (wrapper_cpl_valid[group]) begin
        if (wrapper_cpl_kind[(group*SIMD_GROUP_REQ_KIND_W) +:
                             SIMD_GROUP_REQ_KIND_W] ==
            SIMD_GROUP_REQ_EXEC) begin
          wrapper_cpl_ready[group] = tracker_child_cpl_ready[group];
        end else if (state_cpl_select_valid &&
                     int'(state_cpl_select_group) == group) begin
          wrapper_cpl_ready[group] = state_cpl_ready_i;
        end
      end
    end
  end

  assign state_cpl_valid_o = state_cpl_select_valid;
  assign state_cpl_group_o = state_cpl_select_group;
  assign state_cpl_context_o = state_cpl_select_valid
      ? wrapper_cpl_context[(state_cpl_select_group*CONTEXT_W) +:
                            CONTEXT_W] : '0;
  assign state_cpl_tag_o = state_cpl_select_valid
      ? wrapper_cpl_tag[(state_cpl_select_group*TAG_W) +: TAG_W] : '0;
  assign state_cpl_illegal_o = state_cpl_select_valid
      ? wrapper_cpl_illegal[state_cpl_select_group] : 1'b0;
  assign state_cpl_fire = state_cpl_valid_o && state_cpl_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_rr_q <= '0;
      state_cpl_hold_valid_q <= 1'b0;
      state_cpl_hold_group_q <= '0;
    end else begin
      if (state_cpl_hold_valid_q) begin
        if (state_cpl_fire) state_cpl_hold_valid_q <= 1'b0;
      end else if (state_cpl_select_valid && !state_cpl_ready_i) begin
        state_cpl_hold_valid_q <= 1'b1;
        state_cpl_hold_group_q <= state_cpl_select_group;
      end

      if (state_cpl_fire) begin
        if (int'(state_cpl_select_group) == GROUP_COUNT - 1)
          state_rr_q <= '0;
        else state_rr_q <= state_cpl_select_group + 1'b1;
      end
    end
  end

  // State-read completion and data are independently arbitrated. Holding the
  // chosen group while its sink is blocked prevents a newly arriving lower
  // group from changing visible metadata or payload. Neither channel feeds
  // the EXEC tracker/result collector below.
  always_comb begin
    if (state_read_cpl_hold_valid_q) begin
      state_read_cpl_select_valid = 1'b1;
      state_read_cpl_select_group = state_read_cpl_hold_group_q;
    end else begin
      state_read_cpl_select_valid = 1'b0;
      state_read_cpl_select_group = '0;
      for (int offset = 0; offset < GROUP_COUNT; offset++) begin
        int candidate;
        candidate = int'(state_read_cpl_rr_q) + offset;
        if (candidate >= GROUP_COUNT) candidate -= GROUP_COUNT;
        if (!state_read_cpl_select_valid &&
            wrapper_state_read_cpl_valid[candidate]) begin
          state_read_cpl_select_valid = 1'b1;
          state_read_cpl_select_group = GROUP_ID_W'(candidate);
        end
      end
    end
  end

  always_comb begin
    wrapper_state_read_cpl_ready = '0;
    if (state_read_cpl_select_valid) begin
      wrapper_state_read_cpl_ready[state_read_cpl_select_group] =
          state_read_cpl_ready_i;
    end
  end

  assign state_read_cpl_valid_o = state_read_cpl_select_valid;
  assign state_read_cpl_group_o = state_read_cpl_select_group;
  assign state_read_cpl_context_o = state_read_cpl_select_valid
      ? wrapper_state_read_cpl_context[
            (state_read_cpl_select_group*CONTEXT_W) +: CONTEXT_W] : '0;
  assign state_read_cpl_tag_o = state_read_cpl_select_valid
      ? wrapper_state_read_cpl_tag[
            (state_read_cpl_select_group*TAG_W) +: TAG_W] : '0;
  assign state_read_cpl_illegal_o = state_read_cpl_select_valid
      ? wrapper_state_read_cpl_illegal[state_read_cpl_select_group] : 1'b0;
  assign state_read_cpl_fire = state_read_cpl_valid_o &&
                               state_read_cpl_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_read_cpl_rr_q <= '0;
      state_read_cpl_hold_valid_q <= 1'b0;
      state_read_cpl_hold_group_q <= '0;
    end else begin
      if (state_read_cpl_hold_valid_q) begin
        if (state_read_cpl_fire) state_read_cpl_hold_valid_q <= 1'b0;
      end else if (state_read_cpl_select_valid &&
                   !state_read_cpl_ready_i) begin
        state_read_cpl_hold_valid_q <= 1'b1;
        state_read_cpl_hold_group_q <= state_read_cpl_select_group;
      end

      if (state_read_cpl_fire) begin
        if (int'(state_read_cpl_select_group) == GROUP_COUNT - 1)
          state_read_cpl_rr_q <= '0;
        else state_read_cpl_rr_q <= state_read_cpl_select_group + 1'b1;
      end
    end
  end

  always_comb begin
    if (state_read_rsp_hold_valid_q) begin
      state_read_rsp_select_valid = 1'b1;
      state_read_rsp_select_group = state_read_rsp_hold_group_q;
    end else begin
      state_read_rsp_select_valid = 1'b0;
      state_read_rsp_select_group = '0;
      for (int offset = 0; offset < GROUP_COUNT; offset++) begin
        int candidate;
        candidate = int'(state_read_rsp_rr_q) + offset;
        if (candidate >= GROUP_COUNT) candidate -= GROUP_COUNT;
        if (!state_read_rsp_select_valid &&
            wrapper_state_read_rsp_valid[candidate]) begin
          state_read_rsp_select_valid = 1'b1;
          state_read_rsp_select_group = GROUP_ID_W'(candidate);
        end
      end
    end
  end

  always_comb begin
    wrapper_state_read_rsp_ready = '0;
    if (state_read_rsp_select_valid) begin
      wrapper_state_read_rsp_ready[state_read_rsp_select_group] =
          state_read_rsp_ready_i;
    end
  end

  assign state_read_rsp_valid_o = state_read_rsp_select_valid;
  assign state_read_rsp_group_o = state_read_rsp_select_group;
  assign state_read_rsp_context_o = state_read_rsp_select_valid
      ? wrapper_state_read_rsp_context[
            (state_read_rsp_select_group*CONTEXT_W) +: CONTEXT_W] : '0;
  assign state_read_rsp_tag_o = state_read_rsp_select_valid
      ? wrapper_state_read_rsp_tag[
            (state_read_rsp_select_group*TAG_W) +: TAG_W] : '0;
  assign state_read_rsp_illegal_o = state_read_rsp_select_valid
      ? wrapper_state_read_rsp_illegal[state_read_rsp_select_group] : 1'b0;
  assign state_read_rsp_data_o = state_read_rsp_select_valid
      ? wrapper_state_read_rsp_data[
            (state_read_rsp_select_group*NARROW_W) +: NARROW_W] : '0;
  assign state_read_rsp_mask_o = state_read_rsp_select_valid
      ? wrapper_state_read_rsp_mask[
            (state_read_rsp_select_group*LANES) +: LANES] : '0;
  assign state_read_rsp_fire = state_read_rsp_valid_o &&
                               state_read_rsp_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_read_rsp_rr_q <= '0;
      state_read_rsp_hold_valid_q <= 1'b0;
      state_read_rsp_hold_group_q <= '0;
    end else begin
      if (state_read_rsp_hold_valid_q) begin
        if (state_read_rsp_fire) state_read_rsp_hold_valid_q <= 1'b0;
      end else if (state_read_rsp_select_valid &&
                   !state_read_rsp_ready_i) begin
        state_read_rsp_hold_valid_q <= 1'b1;
        state_read_rsp_hold_group_q <= state_read_rsp_select_group;
      end

      if (state_read_rsp_fire) begin
        if (int'(state_read_rsp_select_group) == GROUP_COUNT - 1)
          state_read_rsp_rr_q <= '0;
        else state_read_rsp_rr_q <= state_read_rsp_select_group + 1'b1;
      end
    end
  end

  simd_cluster_result_collector #(
    .GROUP_COUNT(GROUP_COUNT),
    .LANES(LANES),
    .ELEM_W(ELEM_W),
    .ACC_W(ACC_W),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W)
  ) u_result_collector (
    .clk_i,
    .rst_ni,
    .group_rsp_valid_i(wrapper_rsp_valid),
    .group_rsp_ready_o(wrapper_rsp_ready),
    .group_rsp_context_i(wrapper_rsp_context),
    .group_rsp_tag_i(wrapper_rsp_tag),
    .group_rsp_illegal_i(wrapper_rsp_illegal),
    .group_rsp_has_narrow_i(wrapper_rsp_has_narrow),
    .group_rsp_narrow_i(wrapper_rsp_narrow),
    .group_rsp_narrow_mask_i(wrapper_rsp_narrow_mask),
    .group_rsp_has_reduce_i(wrapper_rsp_has_reduce),
    .group_rsp_reduce_value_i(wrapper_rsp_reduce_value),
    .group_rsp_reduce_index_i(wrapper_rsp_reduce_index),
    .group_rsp_has_count_i(wrapper_rsp_has_count),
    .group_rsp_count_i(wrapper_rsp_count),
    .result_valid_o,
    .result_ready_i,
    .result_group_id_o(result_group_o),
    .result_context_o,
    .result_tag_o,
    .result_illegal_o,
    .result_has_narrow_o,
    .result_narrow_o,
    .result_narrow_mask_o,
    .result_has_reduce_o,
    .result_reduce_value_o,
    .result_reduce_index_o,
    .result_has_count_o,
    .result_count_o,
    .child_rsp_retire_o(collector_rsp_retire),
    .child_rsp_context_o(collector_rsp_context),
    .child_rsp_tag_o(collector_rsp_tag)
  );

  // At most one malformed slot is accepted into the one-entry reject buffer
  // per cycle.  Other malformed heads remain stable until credit returns.
  assign reject_can_push = !reject_valid_q || reject_pop;
  always_comb begin
    logic selected;
    selected = 1'b0;
    reject_ready = '0;
    if (reject_can_push) begin
      for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
        if (!selected && slot_valid[slot] && !slot_precheck_ok[slot]) begin
          reject_ready[slot] = 1'b1;
          selected = 1'b1;
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reject_valid_q <= 1'b0;
      reject_context_q <= '0;
      reject_tag_q <= '0;
      reject_group_mask_q <= '0;
      reject_empty_mask_q <= 1'b0;
      reject_owner_mismatch_q <= 1'b0;
    end else begin
      if (reject_pop) reject_valid_q <= 1'b0;
      for (int slot = 0; slot < ISSUE_SLOTS; slot++) begin
        if (issue_reject_o[slot]) begin
          reject_valid_q <= 1'b1;
          reject_context_q <= slot_context[slot];
          reject_tag_q <= slot_tag[slot];
          reject_group_mask_q <= slot_group_mask[slot];
          reject_empty_mask_q <= slot_empty_mask[slot];
          reject_owner_mismatch_q <= slot_owner_mismatch[slot];
        end
      end
    end
  end

  // Merge child-aggregated completions and pre-dispatch rejects into one
  // buffered output.  The preference toggles only when both sources compete.
  assign completion_can_push = !completion_valid_q || cpl_ready_i;
  always_comb begin
    take_tracker_completion = 1'b0;
    take_reject_completion = 1'b0;
    tracker_cpl_ready = 1'b0;
    reject_pop = 1'b0;

    if (completion_can_push) begin
      if (tracker_cpl_valid && reject_valid_q) begin
        if (prefer_reject_q) take_reject_completion = 1'b1;
        else take_tracker_completion = 1'b1;
      end else if (tracker_cpl_valid) begin
        take_tracker_completion = 1'b1;
      end else if (reject_valid_q) begin
        take_reject_completion = 1'b1;
      end
    end
    tracker_cpl_ready = take_tracker_completion;
    reject_pop = take_reject_completion;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      completion_valid_q <= 1'b0;
      completion_context_q <= '0;
      completion_tag_q <= '0;
      completion_group_mask_q <= '0;
      completion_result_mask_q <= '0;
      completion_illegal_q <= 1'b0;
      completion_illegal_group_mask_q <= '0;
      completion_rejected_q <= 1'b0;
      completion_empty_mask_q <= 1'b0;
      completion_owner_mismatch_q <= 1'b0;
      prefer_reject_q <= 1'b0;
    end else begin
      if (completion_valid_q && cpl_ready_i) completion_valid_q <= 1'b0;

      if (take_tracker_completion) begin
        completion_valid_q <= 1'b1;
        completion_context_q <= tracker_cpl_context;
        completion_tag_q <= tracker_cpl_tag;
        completion_group_mask_q <= tracker_cpl_group_mask;
        completion_result_mask_q <= tracker_cpl_result_mask;
        completion_illegal_q <= tracker_cpl_illegal;
        completion_illegal_group_mask_q <=
            tracker_cpl_illegal_group_mask;
        completion_rejected_q <= 1'b0;
        completion_empty_mask_q <= 1'b0;
        completion_owner_mismatch_q <= 1'b0;
        if (reject_valid_q) prefer_reject_q <= 1'b1;
      end else if (take_reject_completion) begin
        completion_valid_q <= 1'b1;
        completion_context_q <= reject_context_q;
        completion_tag_q <= reject_tag_q;
        completion_group_mask_q <= reject_group_mask_q;
        completion_result_mask_q <= '0;
        completion_illegal_q <= 1'b1;
        completion_illegal_group_mask_q <= reject_group_mask_q;
        completion_rejected_q <= 1'b1;
        completion_empty_mask_q <= reject_empty_mask_q;
        completion_owner_mismatch_q <= reject_owner_mismatch_q;
        if (tracker_cpl_valid) prefer_reject_q <= 1'b0;
      end
    end
  end

  assign cpl_valid_o = completion_valid_q;
  assign cpl_context_o = completion_context_q;
  assign cpl_tag_o = completion_tag_q;
  assign cpl_group_mask_o = completion_group_mask_q;
  assign cpl_result_mask_o = completion_result_mask_q;
  assign cpl_illegal_o = completion_illegal_q;
  assign cpl_illegal_group_mask_o = completion_illegal_group_mask_q;
  assign cpl_rejected_o = completion_rejected_q;
  assign cpl_empty_mask_o = completion_empty_mask_q;
  assign cpl_owner_mismatch_o = completion_owner_mismatch_q;

  initial begin
    if (SIMD4_ID_W != 8) $error("SIMD4 identity is defined as 8 bits");
    if ((int'(SIMD4_BASE_ID) + GROUP_COUNT) > (1 << SIMD4_ID_W))
      $error("SIMD4 ID range exceeds 0..255");
    if (GROUP_COUNT < 1 || ISSUE_SLOTS < 1 || QUEUE_DEPTH < 1 ||
        TRACKER_ENTRIES < 1 || CONTEXT_COUNT < 1) begin
      $error("cluster capacities must be positive");
    end
    if (ISSUE_SLOTS > CONTEXT_COUNT) begin
      $error("ISSUE_SLOTS cannot exceed ordered context count");
    end
    if (LANES < 1 || ELEM_W < 1 || ACC_W < ELEM_W) begin
      $error("invalid SIMD group shape");
    end
    if (RESOURCE_W < 1) $error("RESOURCE_W must be positive");
    if (RF_ADDR_W < VRF_ADDR_W || RF_ADDR_W < ARF_ADDR_W ||
        RF_ADDR_W < MRF_ADDR_W) begin
      $error("RF_ADDR_W must cover every register-file address");
    end
  end
endmodule
