module vsp_cluster_actor_shell #(
  // Integration profile in which both non-EXEC actors are online at once:
  // one blocking MEMORY span parent and one row-level EXCHANGE parent share
  // the single group VRF state-read/write boundary through the reusable VRF
  // service. This is deliberately a different profile from
  // vsp_cluster_memory_shell, which keeps a MEMORY-only client and therefore
  // still covers non-power-of-two GROUP_COUNT and wider lanes. The row
  // exchange engine requires a power-of-two group count and a 4-byte VRF row,
  // so those robustness profiles cannot be expressed here.
  //
  // Still outside this shell: instruction decode, a common class router,
  // program-order enforcement across classes, the route table that would
  // resolve cmd_route_ctrl, owner/resource control, barriers, and any
  // physical memory implementation.
  parameter int GROUP_COUNT       = 4,
  parameter int ISSUE_SLOTS       = 2,
  parameter int QUEUE_DEPTH       = 4,
  parameter int TRACKER_ENTRIES   = 4,
  parameter int LANES             = 4,
  parameter int ELEM_W            = 8,
  parameter int ACC_W             = 32,
  parameter int VREGS             = 16,
  parameter int AREGS             = 8,
  parameter int MREGS             = 4,
  parameter int CONTEXT_COUNT     = 2,
  parameter int TAG_W             = 8,
  parameter int RESOURCE_W        = 8,
  parameter int MEM_EADDR_W       = 32,
  parameter int MEM_OFFSET_W      = 16,
  parameter int ADDR_CONTEXT_W    = 8,
  parameter int VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter int ARF_ADDR_W = (AREGS <= 2) ? 1 : $clog2(AREGS),
  parameter int MRF_ADDR_W = (MREGS <= 2) ? 1 : $clog2(MREGS),
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1),
  parameter int RF_ADDR_W =
      (VRF_ADDR_W >= ARF_ADDR_W) ?
          ((VRF_ADDR_W >= MRF_ADDR_W) ? VRF_ADDR_W : MRF_ADDR_W) :
          ((ARF_ADDR_W >= MRF_ADDR_W) ? ARF_ADDR_W : MRF_ADDR_W),
  parameter int SPAN_BYTES_W = ((GROUP_COUNT*LANES) <= 1) ? 1 :
                               $clog2((GROUP_COUNT*LANES) + 1),
  parameter int BENES_CTRL_W =
      (((2*$clog2(GROUP_COUNT))-1)*(GROUP_COUNT/2))
) (
  input  logic clk_i,
  input  logic rst_ni,
  // Decoded GROUP_EXEC boundary. The shell intentionally does not define a
  // compact instruction layout; a later sequencer/decoder terminates here.
  input  logic                              exec_cmd_valid_i,
  output logic                              exec_cmd_ready_o,
  input  logic [CONTEXT_W-1:0]              exec_cmd_context_i,
  input  logic [TAG_W-1:0]                  exec_cmd_tag_i,
  input  logic [GROUP_COUNT-1:0]            exec_cmd_group_mask_i,
  input  logic [RESOURCE_W-1:0]             exec_cmd_exact_resource_i,
  input  logic                              exec_cmd_export_narrow_i,
  input  logic [simd_pkg::SIMD_OP_W-1:0]   exec_cmd_op_i,
  input  logic [simd_pkg::ELEM_MODE_W-1:0] exec_cmd_elem_mode_i,
  input  logic [VRF_ADDR_W-1:0]             exec_cmd_src_a_addr_i,
  input  logic [VRF_ADDR_W-1:0]             exec_cmd_src_b_addr_i,
  input  logic                              exec_cmd_use_imm_i,
  input  logic [(4*ELEM_W)-1:0]             exec_cmd_imm_i,
  input  logic [VRF_ADDR_W-1:0]             exec_cmd_dst_vrf_addr_i,
  input  logic [ARF_ADDR_W-1:0]             exec_cmd_src_arf_addr_i,
  input  logic [ARF_ADDR_W-1:0]             exec_cmd_dst_arf_addr_i,
  input  logic                              exec_cmd_mask_enable_i,
  input  logic [MRF_ADDR_W-1:0]             exec_cmd_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]             exec_cmd_select_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]             exec_cmd_dst_mrf_addr_i,
  input  logic                              exec_cmd_write_vrf_i,
  input  logic                              exec_cmd_write_arf_i,
  input  logic                              exec_cmd_write_mrf_i,
  input  logic                              exec_cmd_reduce_enable_i,
  input  logic [simd_pkg::REDUCE_OP_W-1:0] exec_cmd_reduce_op_i,
  input  logic                              exec_cmd_route_enable_i,
  input  logic [simd_pkg::ROUTE_OP_W-1:0]  exec_cmd_route_op_i,
  input  logic [(LANES*INDEX_W)-1:0]        exec_cmd_route_index_i,
  input  logic [INDEX_W-1:0]                exec_cmd_route_broadcast_index_i,
  input  logic [OFFSET_W-1:0]               exec_cmd_route_slide_amount_i,
  input  logic [(LANES*ELEM_W)-1:0]         exec_cmd_route_lower_i,
  input  logic [(LANES*ELEM_W)-1:0]         exec_cmd_route_upper_i,
  output logic                              exec_cmd_context_error_o,

  // Ownership is supplied as a stable snapshot. This shell does not assign
  // or revoke groups and therefore does not act as the owner controller.
  input  logic [GROUP_COUNT-1:0]              group_owner_valid_i,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]  group_owner_i,

  output logic                              exec_cpl_valid_o,
  input  logic                              exec_cpl_ready_i,
  output logic [CONTEXT_W-1:0]              exec_cpl_context_o,
  output logic [TAG_W-1:0]                  exec_cpl_tag_o,
  output logic [GROUP_COUNT-1:0]            exec_cpl_group_mask_o,
  output logic [GROUP_COUNT-1:0]            exec_cpl_result_mask_o,
  output logic                              exec_cpl_illegal_o,
  output logic [GROUP_COUNT-1:0]            exec_cpl_illegal_group_mask_o,
  output logic                              exec_cpl_rejected_o,
  output logic                              exec_cpl_empty_mask_o,
  output logic                              exec_cpl_owner_mismatch_o,

  output logic                              exec_result_valid_o,
  input  logic                              exec_result_ready_i,
  output logic [GROUP_ID_W-1:0]             exec_result_group_o,
  output logic [CONTEXT_W-1:0]              exec_result_context_o,
  output logic [TAG_W-1:0]                  exec_result_tag_o,
  output logic                              exec_result_illegal_o,
  output logic                              exec_result_has_narrow_o,
  output logic [(LANES*ELEM_W)-1:0]         exec_result_narrow_o,
  output logic [LANES-1:0]                  exec_result_narrow_mask_o,
  output logic                              exec_result_has_reduce_o,
  output logic [ACC_W-1:0]                  exec_result_reduce_value_o,
  output logic [INDEX_W-1:0]                exec_result_reduce_index_o,
  output logic                              exec_result_has_count_o,
  output logic [OFFSET_W-1:0]               exec_result_count_o,

  // Blocking MEMORY span command. Selected groups are visited in ascending
  // group order, one memory beat and one VRF child transaction at a time.
  input  logic                              mem_cmd_valid_i,
  output logic                              mem_cmd_ready_o,
  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0] mem_cmd_op_i,
  input  logic [CONTEXT_W-1:0]              mem_cmd_exec_context_i,
  input  logic [TAG_W-1:0]                  mem_cmd_tag_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                               mem_cmd_addr_space_i,
  input  logic [ADDR_CONTEXT_W-1:0]         mem_cmd_addr_context_i,
  input  logic [MEM_EADDR_W-1:0]            mem_cmd_base_eaddr_i,
  input  logic signed [MEM_OFFSET_W-1:0]    mem_cmd_eaddr_offset_i,
  input  logic [GROUP_COUNT-1:0]            mem_cmd_group_mask_i,
  input  logic [VRF_ADDR_W-1:0]             mem_cmd_vrf_row_i,
  input  logic [SPAN_BYTES_W-1:0]           mem_cmd_span_bytes_i,

  output logic                              mem_cpl_valid_o,
  input  logic                              mem_cpl_ready_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0] mem_cpl_op_o,
  output logic [CONTEXT_W-1:0]              mem_cpl_exec_context_o,
  output logic [TAG_W-1:0]                  mem_cpl_tag_o,
  output logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
                                               mem_cpl_status_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                               mem_cpl_fault_cause_o,
  output logic [MEM_EADDR_W-1:0]            mem_cpl_fault_eaddr_o,
  output logic [GROUP_COUNT-1:0]            mem_cpl_requested_group_mask_o,
  output logic [GROUP_COUNT-1:0]            mem_cpl_completed_group_mask_o,
  output logic [GROUP_COUNT-1:0]            mem_cpl_failed_group_mask_o,
  output logic [SPAN_BYTES_W-1:0]           mem_cpl_bytes_committed_o,
  output logic                              mem_cpl_partial_o,

  // One EXCHANGE row pass. cmd_route_ctrl is the resolved, immutable snapshot
  // of an external route-register entry: this shell contains no route table
  // and does not decode a compact route field.
  input  logic                              xchg_cmd_valid_i,
  output logic                              xchg_cmd_ready_o,
  input  logic [CONTEXT_W-1:0]              xchg_cmd_exec_context_i,
  input  logic [TAG_W-1:0]                  xchg_cmd_tag_i,
  input  logic [VRF_ADDR_W-1:0]             xchg_cmd_src_vrf_row_i,
  input  logic [VRF_ADDR_W-1:0]             xchg_cmd_dst_vrf_row_i,
  input  logic                              xchg_cmd_route_entry_valid_i,
  input  logic [BENES_CTRL_W-1:0]           xchg_cmd_route_ctrl_i,
  input  logic [GROUP_COUNT-1:0]            xchg_cmd_src_group_mask_i,
  input  logic [(GROUP_COUNT*LANES)-1:0]    xchg_cmd_src_byte_mask_i,
  input  logic [GROUP_COUNT-1:0]            xchg_cmd_expected_dst_group_mask_i,

  output logic                              xchg_cpl_valid_o,
  input  logic                              xchg_cpl_ready_i,
  output logic [CONTEXT_W-1:0]              xchg_cpl_exec_context_o,
  output logic [TAG_W-1:0]                  xchg_cpl_tag_o,
  output logic [vsp_pkg::VSP_EXCHANGE_CPL_STATUS_W-1:0]
                                               xchg_cpl_status_o,
  output logic [GROUP_COUNT-1:0]            xchg_cpl_requested_src_group_mask_o,
  output logic [GROUP_COUNT-1:0]            xchg_cpl_requested_dst_group_mask_o,
  output logic [GROUP_COUNT-1:0]            xchg_cpl_completed_group_mask_o,
  output logic [GROUP_COUNT-1:0]            xchg_cpl_failed_group_mask_o,
  output logic                              xchg_cpl_partial_o,

  // Effective-address memory boundary. A local SRAM adapter, cache, or a
  // future translated-memory adapter may implement this contract.
  output logic                              dmem_req_valid_o,
  input  logic                              dmem_req_ready_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0] dmem_req_op_o,
  output logic [MEM_EADDR_W-1:0]            dmem_req_eaddr_o,
  output logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                               dmem_req_addr_space_o,
  output logic [ADDR_CONTEXT_W-1:0]         dmem_req_addr_context_o,
  output logic [(LANES*ELEM_W)-1:0]         dmem_req_wdata_o,
  output logic [LANES-1:0]                  dmem_req_wstrb_o,
  input  logic                              dmem_rsp_valid_i,
  output logic                              dmem_rsp_ready_o,
  input  logic [(LANES*ELEM_W)-1:0]         dmem_rsp_rdata_i,
  input  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                               dmem_rsp_fault_cause_i,

  output logic                              mem_busy_o,
  output logic                              xchg_busy_o,
  output logic                              vrf_service_busy_o,
  input  logic                              protocol_error_clear_i,
  output logic                              exec_protocol_error_o,
  output logic                              mem_protocol_error_o,
  output logic                              xchg_protocol_error_o,
  output logic                              protocol_error_o
);
  import simd_pkg::*;

  localparam int VRF_ROW_W = LANES * ELEM_W;
  localparam int CLIENT_MEMORY = 0;
  localparam int CLIENT_EXCHANGE = 1;

  logic [ISSUE_SLOTS-1:0] issue_slot_grant;

  // Shared group state endpoints, driven by the VRF service on behalf of
  // whichever actor currently owns a child transaction.
  logic state_write_valid;
  logic state_write_ready;
  logic [GROUP_ID_W-1:0] state_write_group;
  logic [CONTEXT_W-1:0] state_write_context;
  logic [TAG_W-1:0] state_write_tag;
  logic [VRF_ADDR_W-1:0] state_write_row;
  logic [LANES-1:0] state_write_mask;
  logic [VRF_ROW_W-1:0] state_write_data;
  logic [(LANES*ACC_W)-1:0] state_write_data_wide;
  /* verilator lint_off UNUSED */
  // Actor-selected group IDs are constructed from in-range group masks. The
  // diagnostics stay wired so a later controller may latch them without
  // changing the child endpoint.
  logic state_write_group_error;
  logic state_read_group_error;
  /* verilator lint_on UNUSED */
  logic state_write_cpl_valid;
  logic state_write_cpl_ready;
  logic [GROUP_ID_W-1:0] state_write_cpl_group;
  logic [CONTEXT_W-1:0] state_write_cpl_context;
  logic [TAG_W-1:0] state_write_cpl_tag;
  logic state_write_cpl_illegal;

  logic state_read_valid;
  logic state_read_ready;
  logic [GROUP_ID_W-1:0] state_read_group;
  logic [CONTEXT_W-1:0] state_read_context;
  logic [TAG_W-1:0] state_read_tag;
  logic [VRF_ADDR_W-1:0] state_read_row;
  logic [LANES-1:0] state_read_mask;
  logic state_read_cpl_valid;
  logic state_read_cpl_ready;
  logic [GROUP_ID_W-1:0] state_read_cpl_group;
  logic [CONTEXT_W-1:0] state_read_cpl_context;
  logic [TAG_W-1:0] state_read_cpl_tag;
  logic state_read_cpl_illegal;
  logic state_read_rsp_valid;
  logic state_read_rsp_ready;
  logic [GROUP_ID_W-1:0] state_read_rsp_group;
  logic [CONTEXT_W-1:0] state_read_rsp_context;
  logic [TAG_W-1:0] state_read_rsp_tag;
  logic state_read_rsp_illegal;
  logic [VRF_ROW_W-1:0] state_read_rsp_data;
  logic [LANES-1:0] state_read_rsp_mask;

  // Per-actor VRF child wires. Each actor uses the same VRF-only child
  // contract; the service serializes them onto the single group endpoint.
  logic span_read_valid;
  logic span_read_ready;
  logic [CONTEXT_W-1:0] span_read_context;
  logic [TAG_W-1:0] span_read_tag;
  logic [GROUP_ID_W-1:0] span_read_group;
  logic [VRF_ADDR_W-1:0] span_read_row;
  logic [LANES-1:0] span_read_mask;
  logic span_read_cpl_valid;
  logic span_read_cpl_ready;
  logic [CONTEXT_W-1:0] span_read_cpl_context;
  logic [TAG_W-1:0] span_read_cpl_tag;
  logic [GROUP_ID_W-1:0] span_read_cpl_group;
  logic span_read_cpl_error;
  logic span_read_rsp_valid;
  logic span_read_rsp_ready;
  logic [CONTEXT_W-1:0] span_read_rsp_context;
  logic [TAG_W-1:0] span_read_rsp_tag;
  logic [GROUP_ID_W-1:0] span_read_rsp_group;
  logic [VRF_ROW_W-1:0] span_read_rsp_data;
  logic [LANES-1:0] span_read_rsp_mask;
  logic span_read_rsp_error;
  logic span_write_valid;
  logic span_write_ready;
  logic [CONTEXT_W-1:0] span_write_context;
  logic [TAG_W-1:0] span_write_tag;
  logic [GROUP_ID_W-1:0] span_write_group;
  logic [VRF_ADDR_W-1:0] span_write_row;
  logic [LANES-1:0] span_write_mask;
  logic [VRF_ROW_W-1:0] span_write_data;
  logic span_write_cpl_valid;
  logic span_write_cpl_ready;
  logic [CONTEXT_W-1:0] span_write_cpl_context;
  logic [TAG_W-1:0] span_write_cpl_tag;
  logic [GROUP_ID_W-1:0] span_write_cpl_group;
  logic span_write_cpl_error;

  logic xchg_read_valid;
  logic xchg_read_ready;
  logic [CONTEXT_W-1:0] xchg_read_context;
  logic [TAG_W-1:0] xchg_read_tag;
  logic [GROUP_ID_W-1:0] xchg_read_group;
  logic [VRF_ADDR_W-1:0] xchg_read_row;
  logic [LANES-1:0] xchg_read_mask;
  logic xchg_read_cpl_valid;
  logic xchg_read_cpl_ready;
  logic [CONTEXT_W-1:0] xchg_read_cpl_context;
  logic [TAG_W-1:0] xchg_read_cpl_tag;
  logic [GROUP_ID_W-1:0] xchg_read_cpl_group;
  logic xchg_read_cpl_error;
  logic xchg_read_rsp_valid;
  logic xchg_read_rsp_ready;
  logic [CONTEXT_W-1:0] xchg_read_rsp_context;
  logic [TAG_W-1:0] xchg_read_rsp_tag;
  logic [GROUP_ID_W-1:0] xchg_read_rsp_group;
  logic [VRF_ROW_W-1:0] xchg_read_rsp_data;
  logic [LANES-1:0] xchg_read_rsp_mask;
  logic xchg_read_rsp_error;
  logic xchg_write_valid;
  logic xchg_write_ready;
  logic [CONTEXT_W-1:0] xchg_write_context;
  logic [TAG_W-1:0] xchg_write_tag;
  logic [GROUP_ID_W-1:0] xchg_write_group;
  logic [VRF_ADDR_W-1:0] xchg_write_row;
  logic [LANES-1:0] xchg_write_mask;
  logic [VRF_ROW_W-1:0] xchg_write_data;
  logic xchg_write_cpl_valid;
  logic xchg_write_cpl_ready;
  logic [CONTEXT_W-1:0] xchg_write_cpl_context;
  logic [TAG_W-1:0] xchg_write_cpl_tag;
  logic [GROUP_ID_W-1:0] xchg_write_cpl_group;
  logic xchg_write_cpl_error;

  // Packed two-client service buses. Client 0 is the MEMORY span actor and
  // client 1 is the EXCHANGE actor, so the exchange field always occupies the
  // high half of each packed vector.
  logic [1:0] vrf_client_read_valid;
  logic [1:0] vrf_client_read_ready;
  logic [(2*CONTEXT_W)-1:0] vrf_client_read_context;
  logic [(2*TAG_W)-1:0] vrf_client_read_tag;
  logic [(2*GROUP_ID_W)-1:0] vrf_client_read_group;
  logic [(2*VRF_ADDR_W)-1:0] vrf_client_read_row;
  logic [(2*LANES)-1:0] vrf_client_read_mask;
  logic [1:0] vrf_client_read_cpl_valid;
  logic [1:0] vrf_client_read_cpl_ready;
  logic [(2*CONTEXT_W)-1:0] vrf_client_read_cpl_context;
  logic [(2*TAG_W)-1:0] vrf_client_read_cpl_tag;
  logic [(2*GROUP_ID_W)-1:0] vrf_client_read_cpl_group;
  logic [1:0] vrf_client_read_cpl_error;
  logic [1:0] vrf_client_read_rsp_valid;
  logic [1:0] vrf_client_read_rsp_ready;
  logic [(2*CONTEXT_W)-1:0] vrf_client_read_rsp_context;
  logic [(2*TAG_W)-1:0] vrf_client_read_rsp_tag;
  logic [(2*GROUP_ID_W)-1:0] vrf_client_read_rsp_group;
  logic [(2*VRF_ROW_W)-1:0] vrf_client_read_rsp_data;
  logic [(2*LANES)-1:0] vrf_client_read_rsp_mask;
  logic [1:0] vrf_client_read_rsp_error;

  logic [1:0] vrf_client_write_valid;
  logic [1:0] vrf_client_write_ready;
  logic [(2*CONTEXT_W)-1:0] vrf_client_write_context;
  logic [(2*TAG_W)-1:0] vrf_client_write_tag;
  logic [(2*GROUP_ID_W)-1:0] vrf_client_write_group;
  logic [(2*VRF_ADDR_W)-1:0] vrf_client_write_row;
  logic [(2*LANES)-1:0] vrf_client_write_mask;
  logic [(2*VRF_ROW_W)-1:0] vrf_client_write_data;
  logic [1:0] vrf_client_write_cpl_valid;
  logic [1:0] vrf_client_write_cpl_ready;
  logic [(2*CONTEXT_W)-1:0] vrf_client_write_cpl_context;
  logic [(2*TAG_W)-1:0] vrf_client_write_cpl_tag;
  logic [(2*GROUP_ID_W)-1:0] vrf_client_write_cpl_group;
  logic [1:0] vrf_client_write_cpl_error;

  /* verilator lint_off UNUSED */
  logic [ISSUE_SLOTS-1:0] exec_issue_slot_valid_unused;
  logic [(ISSUE_SLOTS*RESOURCE_W)-1:0] exec_issue_slot_resource_unused;
  logic [(ISSUE_SLOTS*GROUP_COUNT)-1:0] exec_issue_slot_mask_unused;
  logic [ISSUE_SLOTS-1:0] exec_issue_accept_unused;
  logic [ISSUE_SLOTS-1:0] exec_issue_reject_unused;
  logic [GROUP_COUNT-1:0] exec_group_ingress_valid_unused;
  logic [GROUP_COUNT-1:0] exec_group_fire_unused;
  logic [(CONTEXT_COUNT*((QUEUE_DEPTH <= 1) ? 1 :
                         $clog2(QUEUE_DEPTH + 1)))-1:0]
      exec_queue_occupancy_unused;
  logic [((TRACKER_ENTRIES <= 1) ? 1 :
          $clog2(TRACKER_ENTRIES + 1))-1:0] exec_tracker_occupancy_unused;
  logic [CONTEXT_COUNT-1:0] exec_context_quiescent_unused;
  logic vrf_service_active_client_unused;
  logic vrf_service_active_read_unused;
  /* verilator lint_on UNUSED */

  assign issue_slot_grant = {ISSUE_SLOTS{1'b1}};
  assign protocol_error_o = exec_protocol_error_o || mem_protocol_error_o ||
                            xchg_protocol_error_o;

  always_comb begin
    state_write_data_wide = '0;
    state_write_data_wide[0 +: VRF_ROW_W] = state_write_data;
  end

  // Pack both actors onto the service client buses.
  always_comb begin
    vrf_client_read_valid[CLIENT_MEMORY] = span_read_valid;
    vrf_client_read_valid[CLIENT_EXCHANGE] = xchg_read_valid;
    vrf_client_read_context = {xchg_read_context, span_read_context};
    vrf_client_read_tag = {xchg_read_tag, span_read_tag};
    vrf_client_read_group = {xchg_read_group, span_read_group};
    vrf_client_read_row = {xchg_read_row, span_read_row};
    vrf_client_read_mask = {xchg_read_mask, span_read_mask};
    vrf_client_read_cpl_ready[CLIENT_MEMORY] = span_read_cpl_ready;
    vrf_client_read_cpl_ready[CLIENT_EXCHANGE] = xchg_read_cpl_ready;
    vrf_client_read_rsp_ready[CLIENT_MEMORY] = span_read_rsp_ready;
    vrf_client_read_rsp_ready[CLIENT_EXCHANGE] = xchg_read_rsp_ready;

    vrf_client_write_valid[CLIENT_MEMORY] = span_write_valid;
    vrf_client_write_valid[CLIENT_EXCHANGE] = xchg_write_valid;
    vrf_client_write_context = {xchg_write_context, span_write_context};
    vrf_client_write_tag = {xchg_write_tag, span_write_tag};
    vrf_client_write_group = {xchg_write_group, span_write_group};
    vrf_client_write_row = {xchg_write_row, span_write_row};
    vrf_client_write_mask = {xchg_write_mask, span_write_mask};
    vrf_client_write_data = {xchg_write_data, span_write_data};
    vrf_client_write_cpl_ready[CLIENT_MEMORY] = span_write_cpl_ready;
    vrf_client_write_cpl_ready[CLIENT_EXCHANGE] = xchg_write_cpl_ready;
  end

  // Unpack the service return lanes back to the owning actor.
  always_comb begin
    span_read_ready = vrf_client_read_ready[CLIENT_MEMORY];
    span_read_cpl_valid = vrf_client_read_cpl_valid[CLIENT_MEMORY];
    span_read_cpl_context = vrf_client_read_cpl_context[
        (CLIENT_MEMORY*CONTEXT_W) +: CONTEXT_W];
    span_read_cpl_tag = vrf_client_read_cpl_tag[
        (CLIENT_MEMORY*TAG_W) +: TAG_W];
    span_read_cpl_group = vrf_client_read_cpl_group[
        (CLIENT_MEMORY*GROUP_ID_W) +: GROUP_ID_W];
    span_read_cpl_error = vrf_client_read_cpl_error[CLIENT_MEMORY];
    span_read_rsp_valid = vrf_client_read_rsp_valid[CLIENT_MEMORY];
    span_read_rsp_context = vrf_client_read_rsp_context[
        (CLIENT_MEMORY*CONTEXT_W) +: CONTEXT_W];
    span_read_rsp_tag = vrf_client_read_rsp_tag[
        (CLIENT_MEMORY*TAG_W) +: TAG_W];
    span_read_rsp_group = vrf_client_read_rsp_group[
        (CLIENT_MEMORY*GROUP_ID_W) +: GROUP_ID_W];
    span_read_rsp_data = vrf_client_read_rsp_data[
        (CLIENT_MEMORY*VRF_ROW_W) +: VRF_ROW_W];
    span_read_rsp_mask = vrf_client_read_rsp_mask[
        (CLIENT_MEMORY*LANES) +: LANES];
    span_read_rsp_error = vrf_client_read_rsp_error[CLIENT_MEMORY];
    span_write_ready = vrf_client_write_ready[CLIENT_MEMORY];
    span_write_cpl_valid = vrf_client_write_cpl_valid[CLIENT_MEMORY];
    span_write_cpl_context = vrf_client_write_cpl_context[
        (CLIENT_MEMORY*CONTEXT_W) +: CONTEXT_W];
    span_write_cpl_tag = vrf_client_write_cpl_tag[
        (CLIENT_MEMORY*TAG_W) +: TAG_W];
    span_write_cpl_group = vrf_client_write_cpl_group[
        (CLIENT_MEMORY*GROUP_ID_W) +: GROUP_ID_W];
    span_write_cpl_error = vrf_client_write_cpl_error[CLIENT_MEMORY];

    xchg_read_ready = vrf_client_read_ready[CLIENT_EXCHANGE];
    xchg_read_cpl_valid = vrf_client_read_cpl_valid[CLIENT_EXCHANGE];
    xchg_read_cpl_context = vrf_client_read_cpl_context[
        (CLIENT_EXCHANGE*CONTEXT_W) +: CONTEXT_W];
    xchg_read_cpl_tag = vrf_client_read_cpl_tag[
        (CLIENT_EXCHANGE*TAG_W) +: TAG_W];
    xchg_read_cpl_group = vrf_client_read_cpl_group[
        (CLIENT_EXCHANGE*GROUP_ID_W) +: GROUP_ID_W];
    xchg_read_cpl_error = vrf_client_read_cpl_error[CLIENT_EXCHANGE];
    xchg_read_rsp_valid = vrf_client_read_rsp_valid[CLIENT_EXCHANGE];
    xchg_read_rsp_context = vrf_client_read_rsp_context[
        (CLIENT_EXCHANGE*CONTEXT_W) +: CONTEXT_W];
    xchg_read_rsp_tag = vrf_client_read_rsp_tag[
        (CLIENT_EXCHANGE*TAG_W) +: TAG_W];
    xchg_read_rsp_group = vrf_client_read_rsp_group[
        (CLIENT_EXCHANGE*GROUP_ID_W) +: GROUP_ID_W];
    xchg_read_rsp_data = vrf_client_read_rsp_data[
        (CLIENT_EXCHANGE*VRF_ROW_W) +: VRF_ROW_W];
    xchg_read_rsp_mask = vrf_client_read_rsp_mask[
        (CLIENT_EXCHANGE*LANES) +: LANES];
    xchg_read_rsp_error = vrf_client_read_rsp_error[CLIENT_EXCHANGE];
    xchg_write_ready = vrf_client_write_ready[CLIENT_EXCHANGE];
    xchg_write_cpl_valid = vrf_client_write_cpl_valid[CLIENT_EXCHANGE];
    xchg_write_cpl_context = vrf_client_write_cpl_context[
        (CLIENT_EXCHANGE*CONTEXT_W) +: CONTEXT_W];
    xchg_write_cpl_tag = vrf_client_write_cpl_tag[
        (CLIENT_EXCHANGE*TAG_W) +: TAG_W];
    xchg_write_cpl_group = vrf_client_write_cpl_group[
        (CLIENT_EXCHANGE*GROUP_ID_W) +: GROUP_ID_W];
    xchg_write_cpl_error = vrf_client_write_cpl_error[CLIENT_EXCHANGE];
  end

  simd_cluster_exec_shell #(
    .GROUP_COUNT(GROUP_COUNT),
    .ISSUE_SLOTS(ISSUE_SLOTS),
    .QUEUE_DEPTH(QUEUE_DEPTH),
    .TRACKER_ENTRIES(TRACKER_ENTRIES),
    .LANES(LANES),
    .ELEM_W(ELEM_W),
    .ACC_W(ACC_W),
    .VREGS(VREGS),
    .AREGS(AREGS),
    .MREGS(MREGS),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .RESOURCE_W(RESOURCE_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .ARF_ADDR_W(ARF_ADDR_W),
    .MRF_ADDR_W(MRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W),
    .RF_ADDR_W(RF_ADDR_W)
  ) u_exec_shell (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .cmd_valid_i(exec_cmd_valid_i),
    .cmd_ready_o(exec_cmd_ready_o),
    .cmd_context_i(exec_cmd_context_i),
    .cmd_tag_i(exec_cmd_tag_i),
    .cmd_group_mask_i(exec_cmd_group_mask_i),
    .cmd_exact_resource_i(exec_cmd_exact_resource_i),
    .cmd_export_narrow_i(exec_cmd_export_narrow_i),
    .cmd_op_i(exec_cmd_op_i),
    .cmd_elem_mode_i(exec_cmd_elem_mode_i),
    .cmd_src_a_addr_i(exec_cmd_src_a_addr_i),
    .cmd_src_b_addr_i(exec_cmd_src_b_addr_i),
    .cmd_use_imm_i(exec_cmd_use_imm_i),
    .cmd_imm_i(exec_cmd_imm_i),
    .cmd_dst_vrf_addr_i(exec_cmd_dst_vrf_addr_i),
    .cmd_src_arf_addr_i(exec_cmd_src_arf_addr_i),
    .cmd_dst_arf_addr_i(exec_cmd_dst_arf_addr_i),
    .cmd_mask_enable_i(exec_cmd_mask_enable_i),
    .cmd_mask_addr_i(exec_cmd_mask_addr_i),
    .cmd_select_mask_addr_i(exec_cmd_select_mask_addr_i),
    .cmd_dst_mrf_addr_i(exec_cmd_dst_mrf_addr_i),
    .cmd_write_vrf_i(exec_cmd_write_vrf_i),
    .cmd_write_arf_i(exec_cmd_write_arf_i),
    .cmd_write_mrf_i(exec_cmd_write_mrf_i),
    .cmd_reduce_enable_i(exec_cmd_reduce_enable_i),
    .cmd_reduce_op_i(exec_cmd_reduce_op_i),
    .cmd_route_enable_i(exec_cmd_route_enable_i),
    .cmd_route_op_i(exec_cmd_route_op_i),
    .cmd_route_index_i(exec_cmd_route_index_i),
    .cmd_route_broadcast_index_i(exec_cmd_route_broadcast_index_i),
    .cmd_route_slide_amount_i(exec_cmd_route_slide_amount_i),
    .cmd_route_lower_i(exec_cmd_route_lower_i),
    .cmd_route_upper_i(exec_cmd_route_upper_i),
    .cmd_context_error_o(exec_cmd_context_error_o),
    .group_owner_valid_i(group_owner_valid_i),
    .group_owner_i(group_owner_i),
    .issue_slot_grant_i(issue_slot_grant),
    .issue_slot_valid_o(exec_issue_slot_valid_unused),
    .issue_slot_resource_o(exec_issue_slot_resource_unused),
    .issue_slot_group_mask_o(exec_issue_slot_mask_unused),
    .state_write_valid_i(state_write_valid),
    .state_write_ready_o(state_write_ready),
    .state_write_group_i(state_write_group),
    .state_write_context_i(state_write_context),
    .state_write_tag_i(state_write_tag),
    .state_write_file_i(SIMD_RF_VRF),
    .state_write_addr_i(RF_ADDR_W'(state_write_row)),
    .state_write_mask_i(state_write_mask),
    .state_write_data_i(state_write_data_wide),
    .state_write_group_error_o(state_write_group_error),
    .state_cpl_valid_o(state_write_cpl_valid),
    .state_cpl_ready_i(state_write_cpl_ready),
    .state_cpl_group_o(state_write_cpl_group),
    .state_cpl_context_o(state_write_cpl_context),
    .state_cpl_tag_o(state_write_cpl_tag),
    .state_cpl_illegal_o(state_write_cpl_illegal),
    .state_read_valid_i(state_read_valid),
    .state_read_ready_o(state_read_ready),
    .state_read_group_i(state_read_group),
    .state_read_context_i(state_read_context),
    .state_read_tag_i(state_read_tag),
    .state_read_addr_i(state_read_row),
    .state_read_mask_i(state_read_mask),
    .state_read_group_error_o(state_read_group_error),
    .state_read_cpl_valid_o(state_read_cpl_valid),
    .state_read_cpl_ready_i(state_read_cpl_ready),
    .state_read_cpl_group_o(state_read_cpl_group),
    .state_read_cpl_context_o(state_read_cpl_context),
    .state_read_cpl_tag_o(state_read_cpl_tag),
    .state_read_cpl_illegal_o(state_read_cpl_illegal),
    .state_read_rsp_valid_o(state_read_rsp_valid),
    .state_read_rsp_ready_i(state_read_rsp_ready),
    .state_read_rsp_group_o(state_read_rsp_group),
    .state_read_rsp_context_o(state_read_rsp_context),
    .state_read_rsp_tag_o(state_read_rsp_tag),
    .state_read_rsp_illegal_o(state_read_rsp_illegal),
    .state_read_rsp_data_o(state_read_rsp_data),
    .state_read_rsp_mask_o(state_read_rsp_mask),
    .cpl_valid_o(exec_cpl_valid_o),
    .cpl_ready_i(exec_cpl_ready_i),
    .cpl_context_o(exec_cpl_context_o),
    .cpl_tag_o(exec_cpl_tag_o),
    .cpl_group_mask_o(exec_cpl_group_mask_o),
    .cpl_result_mask_o(exec_cpl_result_mask_o),
    .cpl_illegal_o(exec_cpl_illegal_o),
    .cpl_illegal_group_mask_o(exec_cpl_illegal_group_mask_o),
    .cpl_rejected_o(exec_cpl_rejected_o),
    .cpl_empty_mask_o(exec_cpl_empty_mask_o),
    .cpl_owner_mismatch_o(exec_cpl_owner_mismatch_o),
    .result_valid_o(exec_result_valid_o),
    .result_ready_i(exec_result_ready_i),
    .result_group_o(exec_result_group_o),
    .result_context_o(exec_result_context_o),
    .result_tag_o(exec_result_tag_o),
    .result_illegal_o(exec_result_illegal_o),
    .result_has_narrow_o(exec_result_has_narrow_o),
    .result_narrow_o(exec_result_narrow_o),
    .result_narrow_mask_o(exec_result_narrow_mask_o),
    .result_has_reduce_o(exec_result_has_reduce_o),
    .result_reduce_value_o(exec_result_reduce_value_o),
    .result_reduce_index_o(exec_result_reduce_index_o),
    .result_has_count_o(exec_result_has_count_o),
    .result_count_o(exec_result_count_o),
    .issue_accept_o(exec_issue_accept_unused),
    .issue_reject_o(exec_issue_reject_unused),
    .group_ingress_valid_o(exec_group_ingress_valid_unused),
    .group_exec_fire_o(exec_group_fire_unused),
    .queue_occupancy_o(exec_queue_occupancy_unused),
    .tracker_occupancy_o(exec_tracker_occupancy_unused),
    .context_exec_quiescent_o(exec_context_quiescent_unused),
    .protocol_error_clear_i(protocol_error_clear_i),
    .protocol_error_o(exec_protocol_error_o)
  );

  vsp_vrf_span_engine #(
    .GROUP_COUNT(GROUP_COUNT),
    .VRF_ROW_BYTES(LANES),
    .VRF_ROWS(VREGS),
    .EXEC_CONTEXT_COUNT(CONTEXT_COUNT),
    .CMD_TAG_W(TAG_W),
    .MEM_EADDR_W(MEM_EADDR_W),
    .MEM_OFFSET_W(MEM_OFFSET_W),
    .ADDR_CONTEXT_W(ADDR_CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .VRF_ROW_ADDR_W(VRF_ADDR_W),
    .EXEC_CONTEXT_ID_W(CONTEXT_W),
    .SPAN_BYTES_W(SPAN_BYTES_W)
  ) u_span_engine (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .cmd_valid_i(mem_cmd_valid_i),
    .cmd_ready_o(mem_cmd_ready_o),
    .cmd_op_i(mem_cmd_op_i),
    .cmd_exec_context_i(mem_cmd_exec_context_i),
    .cmd_tag_i(mem_cmd_tag_i),
    .cmd_addr_space_i(mem_cmd_addr_space_i),
    .cmd_addr_context_i(mem_cmd_addr_context_i),
    .cmd_base_eaddr_i(mem_cmd_base_eaddr_i),
    .cmd_eaddr_offset_i(mem_cmd_eaddr_offset_i),
    .cmd_group_mask_i(mem_cmd_group_mask_i),
    .cmd_vrf_row_i(mem_cmd_vrf_row_i),
    .cmd_span_bytes_i(mem_cmd_span_bytes_i),
    .dmem_req_valid_o(dmem_req_valid_o),
    .dmem_req_ready_i(dmem_req_ready_i),
    .dmem_req_op_o(dmem_req_op_o),
    .dmem_req_eaddr_o(dmem_req_eaddr_o),
    .dmem_req_addr_space_o(dmem_req_addr_space_o),
    .dmem_req_addr_context_o(dmem_req_addr_context_o),
    .dmem_req_wdata_o(dmem_req_wdata_o),
    .dmem_req_wstrb_o(dmem_req_wstrb_o),
    .dmem_rsp_valid_i(dmem_rsp_valid_i),
    .dmem_rsp_ready_o(dmem_rsp_ready_o),
    .dmem_rsp_rdata_i(dmem_rsp_rdata_i),
    .dmem_rsp_fault_cause_i(dmem_rsp_fault_cause_i),
    .vrf_write_valid_o(span_write_valid),
    .vrf_write_ready_i(span_write_ready),
    .vrf_write_exec_context_o(span_write_context),
    .vrf_write_tag_o(span_write_tag),
    .vrf_write_group_o(span_write_group),
    .vrf_write_row_o(span_write_row),
    .vrf_write_mask_o(span_write_mask),
    .vrf_write_data_o(span_write_data),
    .vrf_write_cpl_valid_i(span_write_cpl_valid),
    .vrf_write_cpl_ready_o(span_write_cpl_ready),
    .vrf_write_cpl_exec_context_i(span_write_cpl_context),
    .vrf_write_cpl_tag_i(span_write_cpl_tag),
    .vrf_write_cpl_group_i(span_write_cpl_group),
    .vrf_write_cpl_error_i(span_write_cpl_error),
    .vrf_read_valid_o(span_read_valid),
    .vrf_read_ready_i(span_read_ready),
    .vrf_read_exec_context_o(span_read_context),
    .vrf_read_tag_o(span_read_tag),
    .vrf_read_group_o(span_read_group),
    .vrf_read_row_o(span_read_row),
    .vrf_read_mask_o(span_read_mask),
    .vrf_read_cpl_valid_i(span_read_cpl_valid),
    .vrf_read_cpl_ready_o(span_read_cpl_ready),
    .vrf_read_cpl_exec_context_i(span_read_cpl_context),
    .vrf_read_cpl_tag_i(span_read_cpl_tag),
    .vrf_read_cpl_group_i(span_read_cpl_group),
    .vrf_read_cpl_error_i(span_read_cpl_error),
    .vrf_read_rsp_valid_i(span_read_rsp_valid),
    .vrf_read_rsp_ready_o(span_read_rsp_ready),
    .vrf_read_rsp_exec_context_i(span_read_rsp_context),
    .vrf_read_rsp_tag_i(span_read_rsp_tag),
    .vrf_read_rsp_group_i(span_read_rsp_group),
    .vrf_read_rsp_data_i(span_read_rsp_data),
    .vrf_read_rsp_mask_i(span_read_rsp_mask),
    .vrf_read_rsp_error_i(span_read_rsp_error),
    .cpl_valid_o(mem_cpl_valid_o),
    .cpl_ready_i(mem_cpl_ready_i),
    .cpl_op_o(mem_cpl_op_o),
    .cpl_exec_context_o(mem_cpl_exec_context_o),
    .cpl_tag_o(mem_cpl_tag_o),
    .cpl_status_o(mem_cpl_status_o),
    .cpl_fault_cause_o(mem_cpl_fault_cause_o),
    .cpl_fault_eaddr_o(mem_cpl_fault_eaddr_o),
    .cpl_requested_group_mask_o(mem_cpl_requested_group_mask_o),
    .cpl_completed_group_mask_o(mem_cpl_completed_group_mask_o),
    .cpl_failed_group_mask_o(mem_cpl_failed_group_mask_o),
    .cpl_bytes_committed_o(mem_cpl_bytes_committed_o),
    .cpl_partial_o(mem_cpl_partial_o),
    .busy_o(mem_busy_o),
    .protocol_error_clear_i(protocol_error_clear_i),
    .protocol_error_o(mem_protocol_error_o)
  );

  vsp_benes_exchange_engine #(
    .GROUP_COUNT(GROUP_COUNT),
    .VRF_ROW_BYTES(LANES),
    .VRF_ROWS(VREGS),
    .EXEC_CONTEXT_COUNT(CONTEXT_COUNT),
    .CMD_TAG_W(TAG_W),
    .GROUP_ID_W(GROUP_ID_W),
    .VRF_ROW_ADDR_W(VRF_ADDR_W),
    .EXEC_CONTEXT_ID_W(CONTEXT_W),
    .BENES_CTRL_W(BENES_CTRL_W)
  ) u_exchange_engine (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .cmd_valid_i(xchg_cmd_valid_i),
    .cmd_ready_o(xchg_cmd_ready_o),
    .cmd_exec_context_i(xchg_cmd_exec_context_i),
    .cmd_tag_i(xchg_cmd_tag_i),
    .cmd_src_vrf_row_i(xchg_cmd_src_vrf_row_i),
    .cmd_dst_vrf_row_i(xchg_cmd_dst_vrf_row_i),
    .cmd_route_entry_valid_i(xchg_cmd_route_entry_valid_i),
    .cmd_route_ctrl_i(xchg_cmd_route_ctrl_i),
    .cmd_src_group_mask_i(xchg_cmd_src_group_mask_i),
    .cmd_src_byte_mask_i(xchg_cmd_src_byte_mask_i),
    .cmd_expected_dst_group_mask_i(xchg_cmd_expected_dst_group_mask_i),
    .vrf_read_valid_o(xchg_read_valid),
    .vrf_read_ready_i(xchg_read_ready),
    .vrf_read_exec_context_o(xchg_read_context),
    .vrf_read_tag_o(xchg_read_tag),
    .vrf_read_group_o(xchg_read_group),
    .vrf_read_row_o(xchg_read_row),
    .vrf_read_mask_o(xchg_read_mask),
    .vrf_read_cpl_valid_i(xchg_read_cpl_valid),
    .vrf_read_cpl_ready_o(xchg_read_cpl_ready),
    .vrf_read_cpl_exec_context_i(xchg_read_cpl_context),
    .vrf_read_cpl_tag_i(xchg_read_cpl_tag),
    .vrf_read_cpl_group_i(xchg_read_cpl_group),
    .vrf_read_cpl_error_i(xchg_read_cpl_error),
    .vrf_read_rsp_valid_i(xchg_read_rsp_valid),
    .vrf_read_rsp_ready_o(xchg_read_rsp_ready),
    .vrf_read_rsp_exec_context_i(xchg_read_rsp_context),
    .vrf_read_rsp_tag_i(xchg_read_rsp_tag),
    .vrf_read_rsp_group_i(xchg_read_rsp_group),
    .vrf_read_rsp_data_i(xchg_read_rsp_data),
    .vrf_read_rsp_mask_i(xchg_read_rsp_mask),
    .vrf_read_rsp_error_i(xchg_read_rsp_error),
    .vrf_write_valid_o(xchg_write_valid),
    .vrf_write_ready_i(xchg_write_ready),
    .vrf_write_exec_context_o(xchg_write_context),
    .vrf_write_tag_o(xchg_write_tag),
    .vrf_write_group_o(xchg_write_group),
    .vrf_write_row_o(xchg_write_row),
    .vrf_write_mask_o(xchg_write_mask),
    .vrf_write_data_o(xchg_write_data),
    .vrf_write_cpl_valid_i(xchg_write_cpl_valid),
    .vrf_write_cpl_ready_o(xchg_write_cpl_ready),
    .vrf_write_cpl_exec_context_i(xchg_write_cpl_context),
    .vrf_write_cpl_tag_i(xchg_write_cpl_tag),
    .vrf_write_cpl_group_i(xchg_write_cpl_group),
    .vrf_write_cpl_error_i(xchg_write_cpl_error),
    .cpl_valid_o(xchg_cpl_valid_o),
    .cpl_ready_i(xchg_cpl_ready_i),
    .cpl_exec_context_o(xchg_cpl_exec_context_o),
    .cpl_tag_o(xchg_cpl_tag_o),
    .cpl_status_o(xchg_cpl_status_o),
    .cpl_requested_src_group_mask_o(xchg_cpl_requested_src_group_mask_o),
    .cpl_requested_dst_group_mask_o(xchg_cpl_requested_dst_group_mask_o),
    .cpl_completed_group_mask_o(xchg_cpl_completed_group_mask_o),
    .cpl_failed_group_mask_o(xchg_cpl_failed_group_mask_o),
    .cpl_partial_o(xchg_cpl_partial_o),
    .busy_o(xchg_busy_o),
    .protocol_error_clear_i(protocol_error_clear_i),
    .protocol_error_o(xchg_protocol_error_o)
  );

  vsp_cluster_vrf_service #(
    .CLIENT_COUNT(2),
    .GROUP_COUNT(GROUP_COUNT),
    .VRF_ROW_BYTES(LANES),
    .VRF_ROWS(VREGS),
    .EXEC_CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .CLIENT_W(1),
    .GROUP_ID_W(GROUP_ID_W),
    .VRF_ROW_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W)
  ) u_vrf_service (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .client_read_valid_i(vrf_client_read_valid),
    .client_read_ready_o(vrf_client_read_ready),
    .client_read_context_i(vrf_client_read_context),
    .client_read_tag_i(vrf_client_read_tag),
    .client_read_group_i(vrf_client_read_group),
    .client_read_row_i(vrf_client_read_row),
    .client_read_mask_i(vrf_client_read_mask),
    .client_read_cpl_valid_o(vrf_client_read_cpl_valid),
    .client_read_cpl_ready_i(vrf_client_read_cpl_ready),
    .client_read_cpl_context_o(vrf_client_read_cpl_context),
    .client_read_cpl_tag_o(vrf_client_read_cpl_tag),
    .client_read_cpl_group_o(vrf_client_read_cpl_group),
    .client_read_cpl_error_o(vrf_client_read_cpl_error),
    .client_read_rsp_valid_o(vrf_client_read_rsp_valid),
    .client_read_rsp_ready_i(vrf_client_read_rsp_ready),
    .client_read_rsp_context_o(vrf_client_read_rsp_context),
    .client_read_rsp_tag_o(vrf_client_read_rsp_tag),
    .client_read_rsp_group_o(vrf_client_read_rsp_group),
    .client_read_rsp_data_o(vrf_client_read_rsp_data),
    .client_read_rsp_mask_o(vrf_client_read_rsp_mask),
    .client_read_rsp_error_o(vrf_client_read_rsp_error),
    .client_write_valid_i(vrf_client_write_valid),
    .client_write_ready_o(vrf_client_write_ready),
    .client_write_context_i(vrf_client_write_context),
    .client_write_tag_i(vrf_client_write_tag),
    .client_write_group_i(vrf_client_write_group),
    .client_write_row_i(vrf_client_write_row),
    .client_write_mask_i(vrf_client_write_mask),
    .client_write_data_i(vrf_client_write_data),
    .client_write_cpl_valid_o(vrf_client_write_cpl_valid),
    .client_write_cpl_ready_i(vrf_client_write_cpl_ready),
    .client_write_cpl_context_o(vrf_client_write_cpl_context),
    .client_write_cpl_tag_o(vrf_client_write_cpl_tag),
    .client_write_cpl_group_o(vrf_client_write_cpl_group),
    .client_write_cpl_error_o(vrf_client_write_cpl_error),
    .cluster_read_valid_o(state_read_valid),
    .cluster_read_ready_i(state_read_ready),
    .cluster_read_context_o(state_read_context),
    .cluster_read_tag_o(state_read_tag),
    .cluster_read_group_o(state_read_group),
    .cluster_read_row_o(state_read_row),
    .cluster_read_mask_o(state_read_mask),
    .cluster_read_cpl_valid_i(state_read_cpl_valid),
    .cluster_read_cpl_ready_o(state_read_cpl_ready),
    .cluster_read_cpl_context_i(state_read_cpl_context),
    .cluster_read_cpl_tag_i(state_read_cpl_tag),
    .cluster_read_cpl_group_i(state_read_cpl_group),
    .cluster_read_cpl_error_i(state_read_cpl_illegal),
    .cluster_read_rsp_valid_i(state_read_rsp_valid),
    .cluster_read_rsp_ready_o(state_read_rsp_ready),
    .cluster_read_rsp_context_i(state_read_rsp_context),
    .cluster_read_rsp_tag_i(state_read_rsp_tag),
    .cluster_read_rsp_group_i(state_read_rsp_group),
    .cluster_read_rsp_data_i(state_read_rsp_data),
    .cluster_read_rsp_mask_i(state_read_rsp_mask),
    .cluster_read_rsp_error_i(state_read_rsp_illegal),
    .cluster_write_valid_o(state_write_valid),
    .cluster_write_ready_i(state_write_ready),
    .cluster_write_context_o(state_write_context),
    .cluster_write_tag_o(state_write_tag),
    .cluster_write_group_o(state_write_group),
    .cluster_write_row_o(state_write_row),
    .cluster_write_mask_o(state_write_mask),
    .cluster_write_data_o(state_write_data),
    .cluster_write_cpl_valid_i(state_write_cpl_valid),
    .cluster_write_cpl_ready_o(state_write_cpl_ready),
    .cluster_write_cpl_context_i(state_write_cpl_context),
    .cluster_write_cpl_tag_i(state_write_cpl_tag),
    .cluster_write_cpl_group_i(state_write_cpl_group),
    .cluster_write_cpl_error_i(state_write_cpl_illegal),
    .busy_o(vrf_service_busy_o),
    .active_client_o(vrf_service_active_client_unused),
    .active_read_o(vrf_service_active_read_unused)
  );

  initial begin
    if (ELEM_W != 8)
      $error("actor-shell VRF row transport requires 8-bit base lanes");
    if (LANES != 4)
      $error("the row exchange profile requires a 4-byte VRF row");
    if (GROUP_COUNT < 2 || (GROUP_COUNT & (GROUP_COUNT - 1)) != 0)
      $error("row exchange requires a power-of-two GROUP_COUNT of at least 2");
    if (ISSUE_SLOTS < 1)
      $error("actor-shell capacities must be positive");
    if (ACC_W < ELEM_W)
      $error("ACC_W must be at least ELEM_W");
  end
endmodule
