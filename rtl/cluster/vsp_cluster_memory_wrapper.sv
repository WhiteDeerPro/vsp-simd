module vsp_cluster_memory_wrapper #(
  // This is a deliberately small integration profile: decoded EXEC traffic,
  // one blocking vector memory engine, and one blocking register-route engine
  // share the group VRF boundary.
  // Instruction decode, program ordering, ownership changes, translation and
  // a physical memory implementation remain outside this wrapper.
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
  parameter int SIMD4_ID_W        = 8,
  parameter logic [SIMD4_ID_W-1:0] SIMD4_BASE_ID = '0,
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
                               $clog2((GROUP_COUNT*LANES) + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Decoded EXEC boundary. The wrapper intentionally does not define a
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
  input  logic [1:0]                        exec_cmd_route_io_mode_i,
  input  logic [simd_pkg::ROUTE_OP_W-1:0]  exec_cmd_route_op_i,
  input  logic [(LANES*INDEX_W)-1:0]        exec_cmd_route_index_i,
  input  logic [INDEX_W-1:0]                exec_cmd_route_broadcast_index_i,
  input  logic [OFFSET_W-1:0]               exec_cmd_route_slide_amount_i,
  input  logic [(LANES*ELEM_W)-1:0]         exec_cmd_route_lower_i,
  input  logic [(LANES*ELEM_W)-1:0]         exec_cmd_route_upper_i,
  output logic                              exec_cmd_context_error_o,

  // Ownership is supplied as a stable snapshot. This wrapper does not assign
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

  // Blocking MEMORY command. Selected groups are visited in ascending
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
  output logic                              vrf_arbiter_busy_o,
  // EXEC observability for a controller-level END.  Child quiescence only
  // reports group execution completions; tracker_empty additionally proves
  // that every result obligation has reached the result collector.  Queue and
  // tracker emptiness therefore form the stronger global drain predicate.
  output logic [CONTEXT_COUNT-1:0]
                                               exec_context_children_quiescent_o,
  output logic                              exec_queue_empty_o,
  output logic                              exec_tracker_empty_o,
  // Stronger than queue/tracker emptiness: includes accepted work between
  // those structures and ordered command-completion retirement.
  output logic                              exec_quiescent_o,
  input  logic                              protocol_error_clear_i,
  output logic                              exec_protocol_error_o,
  output logic                              mem_protocol_error_o,
  output logic                              protocol_error_o
);
  import simd_pkg::*;

  localparam int VRF_ROW_W = LANES * ELEM_W;
  localparam int VRF_CLIENT_COUNT = 2;
  localparam int MEMORY_VRF_CLIENT = 0;
  localparam int ROUTE_VRF_CLIENT = 1;

  logic [ISSUE_SLOTS-1:0] issue_slot_grant;

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
  // Span-selected group IDs are constructed from an in-range group mask. The
  // wrapper diagnostics remain wired so a later multi-client top may expose or
  // latch them without changing the child endpoint.
  logic state_write_group_error;
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
  logic state_read_group_error;
  /* verilator lint_on UNUSED */
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

  // MEMORY and register-route are independent clients of the same blocking
  // VRF transaction boundary.  Client 1 may later be replaced by a parallel
  // capture/commit port without changing vector-route semantics.
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_valid;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_ready;
  logic [(VRF_CLIENT_COUNT*CONTEXT_W)-1:0] vrf_client_read_context;
  logic [(VRF_CLIENT_COUNT*TAG_W)-1:0] vrf_client_read_tag;
  logic [(VRF_CLIENT_COUNT*GROUP_ID_W)-1:0] vrf_client_read_group;
  logic [(VRF_CLIENT_COUNT*VRF_ADDR_W)-1:0] vrf_client_read_row;
  logic [(VRF_CLIENT_COUNT*LANES)-1:0] vrf_client_read_mask;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_cpl_valid;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_cpl_ready;
  logic [(VRF_CLIENT_COUNT*CONTEXT_W)-1:0] vrf_client_read_cpl_context;
  logic [(VRF_CLIENT_COUNT*TAG_W)-1:0] vrf_client_read_cpl_tag;
  logic [(VRF_CLIENT_COUNT*GROUP_ID_W)-1:0] vrf_client_read_cpl_group;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_cpl_error;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_rsp_valid;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_rsp_ready;
  logic [(VRF_CLIENT_COUNT*CONTEXT_W)-1:0] vrf_client_read_rsp_context;
  logic [(VRF_CLIENT_COUNT*TAG_W)-1:0] vrf_client_read_rsp_tag;
  logic [(VRF_CLIENT_COUNT*GROUP_ID_W)-1:0] vrf_client_read_rsp_group;
  logic [(VRF_CLIENT_COUNT*VRF_ROW_W)-1:0] vrf_client_read_rsp_data;
  logic [(VRF_CLIENT_COUNT*LANES)-1:0] vrf_client_read_rsp_mask;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_read_rsp_error;

  logic [VRF_CLIENT_COUNT-1:0] vrf_client_write_valid;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_write_ready;
  logic [(VRF_CLIENT_COUNT*CONTEXT_W)-1:0] vrf_client_write_context;
  logic [(VRF_CLIENT_COUNT*TAG_W)-1:0] vrf_client_write_tag;
  logic [(VRF_CLIENT_COUNT*GROUP_ID_W)-1:0] vrf_client_write_group;
  logic [(VRF_CLIENT_COUNT*VRF_ADDR_W)-1:0] vrf_client_write_row;
  logic [(VRF_CLIENT_COUNT*LANES)-1:0] vrf_client_write_mask;
  logic [(VRF_CLIENT_COUNT*VRF_ROW_W)-1:0] vrf_client_write_data;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_write_cpl_valid;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_write_cpl_ready;
  logic [(VRF_CLIENT_COUNT*CONTEXT_W)-1:0] vrf_client_write_cpl_context;
  logic [(VRF_CLIENT_COUNT*TAG_W)-1:0] vrf_client_write_cpl_tag;
  logic [(VRF_CLIENT_COUNT*GROUP_ID_W)-1:0] vrf_client_write_cpl_group;
  logic [VRF_CLIENT_COUNT-1:0] vrf_client_write_cpl_error;

  logic cluster_exec_cmd_ready;
  logic cluster_exec_cmd_context_error;
  logic cluster_exec_cpl_valid;
  logic cluster_exec_cpl_ready;
  logic [CONTEXT_W-1:0] cluster_exec_cpl_context;
  logic [TAG_W-1:0] cluster_exec_cpl_tag;
  logic [GROUP_COUNT-1:0] cluster_exec_cpl_group_mask;
  logic [GROUP_COUNT-1:0] cluster_exec_cpl_result_mask;
  logic cluster_exec_cpl_illegal;
  logic [GROUP_COUNT-1:0] cluster_exec_cpl_illegal_group_mask;
  logic cluster_exec_cpl_rejected;
  logic cluster_exec_cpl_empty_mask;
  logic cluster_exec_cpl_owner_mismatch;
  logic cluster_exec_protocol_error;

  logic route_cmd_legal;
  logic route_owner_match;
  logic route_owner_mismatch_q;
  logic route_cmd_ready;
  logic route_request;
  logic route_launch_valid;
  logic route_launch_fire;
  logic route_admission_quiescent;
  logic route_cpl_valid;
  logic route_cpl_ready;
  logic [CONTEXT_W-1:0] route_cpl_context;
  logic [TAG_W-1:0] route_cpl_tag;
  logic [GROUP_COUNT-1:0] route_cpl_group_mask;
  logic route_cpl_illegal;
  logic [GROUP_COUNT-1:0] route_cpl_illegal_group_mask;
  logic route_cpl_rejected;
  logic route_cpl_empty_mask;
  /* verilator lint_off UNUSED */
  // Kept at the engine boundary for diagnostics; the current EXEC completion
  // envelope has no per-element status field.
  logic [(GROUP_COUNT*LANES)-1:0] route_cpl_invalid_element_mask;
  /* verilator lint_on UNUSED */
  logic route_busy;
  logic route_protocol_error;
  logic cluster_exec_quiescent;
  logic mem_engine_cmd_valid;
  logic mem_engine_cmd_ready;
  /* verilator lint_off UNUSED */
  logic [(GROUP_COUNT*SIMD4_ID_W)-1:0] simd4_id_unused;
  /* verilator lint_on UNUSED */

  /* verilator lint_off UNUSED */
  logic [ISSUE_SLOTS-1:0] exec_issue_slot_valid_unused;
  logic [(ISSUE_SLOTS*RESOURCE_W)-1:0] exec_issue_slot_resource_unused;
  logic [(ISSUE_SLOTS*GROUP_COUNT)-1:0] exec_issue_slot_mask_unused;
  logic [ISSUE_SLOTS-1:0] exec_issue_accept_unused;
  logic [ISSUE_SLOTS-1:0] exec_issue_reject_unused;
  logic [GROUP_COUNT-1:0] exec_group_ingress_valid_unused;
  logic [GROUP_COUNT-1:0] exec_group_fire_unused;
  logic vrf_arbiter_active_client_unused;
  logic vrf_arbiter_active_read_unused;
  /* verilator lint_on UNUSED */

  logic [(CONTEXT_COUNT*((QUEUE_DEPTH <= 1) ? 1 :
                         $clog2(QUEUE_DEPTH + 1)))-1:0]
      exec_queue_occupancy;
  logic [((TRACKER_ENTRIES <= 1) ? 1 :
          $clog2(TRACKER_ENTRIES + 1))-1:0] exec_tracker_occupancy;

  assign exec_queue_empty_o = !(|exec_queue_occupancy) && !route_busy;
  assign exec_tracker_empty_o = !(|exec_tracker_occupancy) && !route_busy;
  assign exec_quiescent_o = cluster_exec_quiescent && !route_busy;

  assign issue_slot_grant = {ISSUE_SLOTS{1'b1}};
  assign exec_protocol_error_o = cluster_exec_protocol_error ||
                                 route_protocol_error;
  assign protocol_error_o = exec_protocol_error_o || mem_protocol_error_o;

  // Register route takes a multi-transaction snapshot of distributed VRF
  // state.  Keep it mutually exclusive with ordinary EXEC and MEMORY work so
  // neither source/index capture nor destination commit can interleave with a
  // same-row update.  A pending route has deterministic priority over a new
  // MEMORY command; an already-active MEMORY/EXEC command drains first.
  assign route_request = exec_cmd_valid_i && exec_cmd_route_enable_i;
  assign route_admission_quiescent = cluster_exec_quiescent &&
      !mem_busy_o && !mem_cpl_valid_o && !vrf_arbiter_busy_o;
  assign route_launch_valid = route_request && route_admission_quiescent;
  assign route_launch_fire = route_launch_valid && route_cmd_ready;
  assign mem_engine_cmd_valid = mem_cmd_valid_i && !route_busy &&
                                !route_request;
  assign mem_cmd_ready_o = mem_engine_cmd_ready && !route_busy &&
                           !route_request;

  // A vector route is a distinct cluster engine operation.  Legacy local
  // route controls must be canonical zero; broadcast and slide are expressed
  // by values in the index VRF row instead of instruction bits.
  assign route_cmd_legal =
      exec_cmd_op_i == SIMD_OP_PASS_A &&
      exec_cmd_elem_mode_i == ELEM_MODE_BYTE &&
      exec_cmd_write_vrf_i && !exec_cmd_write_arf_i &&
      !exec_cmd_write_mrf_i && !exec_cmd_export_narrow_i &&
      !exec_cmd_use_imm_i && !exec_cmd_mask_enable_i &&
      !exec_cmd_reduce_enable_i &&
      (exec_cmd_route_io_mode_i == 2'b00 ||
       exec_cmd_route_io_mode_i == 2'b11) &&
      exec_cmd_route_op_i == ROUTE_OP_GATHER &&
      !(|exec_cmd_route_index_i) &&
      !(|exec_cmd_route_broadcast_index_i) &&
      !(|exec_cmd_route_slide_amount_i) &&
      !(|exec_cmd_route_lower_i) && !(|exec_cmd_route_upper_i);

  always_comb begin
    route_owner_match = int'(exec_cmd_context_i) < CONTEXT_COUNT;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (exec_cmd_group_mask_i[group] &&
          (!group_owner_valid_i[group] ||
           group_owner_i[(group*CONTEXT_W) +: CONTEXT_W] !=
               exec_cmd_context_i)) begin
        route_owner_match = 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      route_owner_mismatch_q <= 1'b0;
    end else begin
      if (route_cpl_valid && route_cpl_ready)
        route_owner_mismatch_q <= 1'b0;
      if (route_launch_fire)
        route_owner_mismatch_q <=
            (|exec_cmd_group_mask_i) && !route_owner_match;
    end
  end

  assign exec_cmd_ready_o = exec_cmd_route_enable_i ?
      (route_admission_quiescent && route_cmd_ready) :
      (!route_busy && cluster_exec_cmd_ready);
  assign exec_cmd_context_error_o = exec_cmd_route_enable_i ?
      (int'(exec_cmd_context_i) >= CONTEXT_COUNT) :
      cluster_exec_cmd_context_error;

  assign cluster_exec_cpl_ready = exec_cpl_ready_i && !route_cpl_valid;
  assign route_cpl_ready = exec_cpl_ready_i;
  assign exec_cpl_valid_o = route_cpl_valid || cluster_exec_cpl_valid;
  assign exec_cpl_context_o = route_cpl_valid ? route_cpl_context :
                                                 cluster_exec_cpl_context;
  assign exec_cpl_tag_o = route_cpl_valid ? route_cpl_tag :
                                             cluster_exec_cpl_tag;
  assign exec_cpl_group_mask_o = route_cpl_valid ? route_cpl_group_mask :
                                                    cluster_exec_cpl_group_mask;
  assign exec_cpl_result_mask_o = route_cpl_valid ? '0 :
                                                     cluster_exec_cpl_result_mask;
  assign exec_cpl_illegal_o = route_cpl_valid ? route_cpl_illegal :
                                                cluster_exec_cpl_illegal;
  assign exec_cpl_illegal_group_mask_o = route_cpl_valid ?
      route_cpl_illegal_group_mask : cluster_exec_cpl_illegal_group_mask;
  assign exec_cpl_rejected_o = route_cpl_valid ? route_cpl_rejected :
                                                 cluster_exec_cpl_rejected;
  assign exec_cpl_empty_mask_o = route_cpl_valid ? route_cpl_empty_mask :
                                                   cluster_exec_cpl_empty_mask;
  assign exec_cpl_owner_mismatch_o = route_cpl_valid ?
      route_owner_mismatch_q :
      cluster_exec_cpl_owner_mismatch;

  always_comb begin
    state_write_data_wide = '0;
    state_write_data_wide[0 +: VRF_ROW_W] = state_write_data;
  end

  simd_cluster_exec #(
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
    .SIMD4_ID_W(SIMD4_ID_W),
    .SIMD4_BASE_ID(SIMD4_BASE_ID),
    .VRF_ADDR_W(VRF_ADDR_W),
    .ARF_ADDR_W(ARF_ADDR_W),
    .MRF_ADDR_W(MRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W),
    .RF_ADDR_W(RF_ADDR_W)
  ) u_cluster_exec (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .cmd_valid_i(exec_cmd_valid_i && !exec_cmd_route_enable_i && !route_busy),
    .cmd_ready_o(cluster_exec_cmd_ready),
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
    .cmd_context_error_o(cluster_exec_cmd_context_error),
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
    .cpl_valid_o(cluster_exec_cpl_valid),
    .cpl_ready_i(cluster_exec_cpl_ready),
    .cpl_context_o(cluster_exec_cpl_context),
    .cpl_tag_o(cluster_exec_cpl_tag),
    .cpl_group_mask_o(cluster_exec_cpl_group_mask),
    .cpl_result_mask_o(cluster_exec_cpl_result_mask),
    .cpl_illegal_o(cluster_exec_cpl_illegal),
    .cpl_illegal_group_mask_o(cluster_exec_cpl_illegal_group_mask),
    .cpl_rejected_o(cluster_exec_cpl_rejected),
    .cpl_empty_mask_o(cluster_exec_cpl_empty_mask),
    .cpl_owner_mismatch_o(cluster_exec_cpl_owner_mismatch),
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
    .simd4_id_o(simd4_id_unused),
    .queue_occupancy_o(exec_queue_occupancy),
    .tracker_occupancy_o(exec_tracker_occupancy),
    .context_exec_quiescent_o(exec_context_children_quiescent_o),
    .quiescent_o(cluster_exec_quiescent),
    .protocol_error_clear_i(protocol_error_clear_i),
    .protocol_error_o(cluster_exec_protocol_error)
  );

  vsp_cluster_register_route_engine #(
    .GROUP_COUNT(GROUP_COUNT),
    .LANES_PER_GROUP(LANES),
    .ELEM_W(ELEM_W),
    .INDEX_ELEM_W(8),
    .VRF_ROWS(VREGS),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .GROUP_ID_W(GROUP_ID_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W)
  ) u_register_route_engine (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .cmd_valid_i(route_launch_valid),
    .cmd_ready_o(route_cmd_ready),
    .cmd_legal_i(route_cmd_legal && route_owner_match),
    .cmd_context_i(exec_cmd_context_i),
    .cmd_tag_i(exec_cmd_tag_i),
    .cmd_group_mask_i(exec_cmd_group_mask_i),
    .cmd_source_row_i(exec_cmd_src_a_addr_i),
    .cmd_index_row_i(exec_cmd_src_b_addr_i),
    .cmd_destination_row_i(exec_cmd_dst_vrf_addr_i),
    .cmd_io_mode_i(exec_cmd_route_io_mode_i),
    .cpl_valid_o(route_cpl_valid),
    .cpl_ready_i(route_cpl_ready),
    .cpl_context_o(route_cpl_context),
    .cpl_tag_o(route_cpl_tag),
    .cpl_group_mask_o(route_cpl_group_mask),
    .cpl_illegal_o(route_cpl_illegal),
    .cpl_illegal_group_mask_o(route_cpl_illegal_group_mask),
    .cpl_rejected_o(route_cpl_rejected),
    .cpl_empty_mask_o(route_cpl_empty_mask),
    .cpl_invalid_element_mask_o(route_cpl_invalid_element_mask),
    .vrf_read_valid_o(vrf_client_read_valid[ROUTE_VRF_CLIENT]),
    .vrf_read_ready_i(vrf_client_read_ready[ROUTE_VRF_CLIENT]),
    .vrf_read_context_o(vrf_client_read_context[
        (ROUTE_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_read_tag_o(vrf_client_read_tag[
        (ROUTE_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_read_group_o(vrf_client_read_group[
        (ROUTE_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_read_row_o(vrf_client_read_row[
        (ROUTE_VRF_CLIENT*VRF_ADDR_W) +: VRF_ADDR_W]),
    .vrf_read_mask_o(vrf_client_read_mask[
        (ROUTE_VRF_CLIENT*LANES) +: LANES]),
    .vrf_read_cpl_valid_i(vrf_client_read_cpl_valid[ROUTE_VRF_CLIENT]),
    .vrf_read_cpl_ready_o(vrf_client_read_cpl_ready[ROUTE_VRF_CLIENT]),
    .vrf_read_cpl_context_i(vrf_client_read_cpl_context[
        (ROUTE_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_read_cpl_tag_i(vrf_client_read_cpl_tag[
        (ROUTE_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_read_cpl_group_i(vrf_client_read_cpl_group[
        (ROUTE_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_read_cpl_error_i(vrf_client_read_cpl_error[ROUTE_VRF_CLIENT]),
    .vrf_read_rsp_valid_i(vrf_client_read_rsp_valid[ROUTE_VRF_CLIENT]),
    .vrf_read_rsp_ready_o(vrf_client_read_rsp_ready[ROUTE_VRF_CLIENT]),
    .vrf_read_rsp_context_i(vrf_client_read_rsp_context[
        (ROUTE_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_read_rsp_tag_i(vrf_client_read_rsp_tag[
        (ROUTE_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_read_rsp_group_i(vrf_client_read_rsp_group[
        (ROUTE_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_read_rsp_data_i(vrf_client_read_rsp_data[
        (ROUTE_VRF_CLIENT*VRF_ROW_W) +: VRF_ROW_W]),
    .vrf_read_rsp_mask_i(vrf_client_read_rsp_mask[
        (ROUTE_VRF_CLIENT*LANES) +: LANES]),
    .vrf_read_rsp_error_i(vrf_client_read_rsp_error[ROUTE_VRF_CLIENT]),
    .vrf_write_valid_o(vrf_client_write_valid[ROUTE_VRF_CLIENT]),
    .vrf_write_ready_i(vrf_client_write_ready[ROUTE_VRF_CLIENT]),
    .vrf_write_context_o(vrf_client_write_context[
        (ROUTE_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_write_tag_o(vrf_client_write_tag[
        (ROUTE_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_write_group_o(vrf_client_write_group[
        (ROUTE_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_write_row_o(vrf_client_write_row[
        (ROUTE_VRF_CLIENT*VRF_ADDR_W) +: VRF_ADDR_W]),
    .vrf_write_mask_o(vrf_client_write_mask[
        (ROUTE_VRF_CLIENT*LANES) +: LANES]),
    .vrf_write_data_o(vrf_client_write_data[
        (ROUTE_VRF_CLIENT*VRF_ROW_W) +: VRF_ROW_W]),
    .vrf_write_cpl_valid_i(vrf_client_write_cpl_valid[ROUTE_VRF_CLIENT]),
    .vrf_write_cpl_ready_o(vrf_client_write_cpl_ready[ROUTE_VRF_CLIENT]),
    .vrf_write_cpl_context_i(vrf_client_write_cpl_context[
        (ROUTE_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_write_cpl_tag_i(vrf_client_write_cpl_tag[
        (ROUTE_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_write_cpl_group_i(vrf_client_write_cpl_group[
        (ROUTE_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_write_cpl_error_i(vrf_client_write_cpl_error[ROUTE_VRF_CLIENT]),
    .busy_o(route_busy),
    .protocol_error_clear_i(protocol_error_clear_i),
    .protocol_error_o(route_protocol_error)
  );

  vsp_vector_memory_engine #(
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
  ) u_vector_memory_engine (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .cmd_valid_i(mem_engine_cmd_valid),
    .cmd_ready_o(mem_engine_cmd_ready),
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
    .vrf_write_valid_o(vrf_client_write_valid[MEMORY_VRF_CLIENT]),
    .vrf_write_ready_i(vrf_client_write_ready[MEMORY_VRF_CLIENT]),
    .vrf_write_exec_context_o(vrf_client_write_context[
        (MEMORY_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_write_tag_o(vrf_client_write_tag[
        (MEMORY_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_write_group_o(vrf_client_write_group[
        (MEMORY_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_write_row_o(vrf_client_write_row[
        (MEMORY_VRF_CLIENT*VRF_ADDR_W) +: VRF_ADDR_W]),
    .vrf_write_mask_o(vrf_client_write_mask[
        (MEMORY_VRF_CLIENT*LANES) +: LANES]),
    .vrf_write_data_o(vrf_client_write_data[
        (MEMORY_VRF_CLIENT*VRF_ROW_W) +: VRF_ROW_W]),
    .vrf_write_cpl_valid_i(vrf_client_write_cpl_valid[MEMORY_VRF_CLIENT]),
    .vrf_write_cpl_ready_o(vrf_client_write_cpl_ready[MEMORY_VRF_CLIENT]),
    .vrf_write_cpl_exec_context_i(vrf_client_write_cpl_context[
        (MEMORY_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_write_cpl_tag_i(vrf_client_write_cpl_tag[
        (MEMORY_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_write_cpl_group_i(vrf_client_write_cpl_group[
        (MEMORY_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_write_cpl_error_i(vrf_client_write_cpl_error[MEMORY_VRF_CLIENT]),
    .vrf_read_valid_o(vrf_client_read_valid[MEMORY_VRF_CLIENT]),
    .vrf_read_ready_i(vrf_client_read_ready[MEMORY_VRF_CLIENT]),
    .vrf_read_exec_context_o(vrf_client_read_context[
        (MEMORY_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_read_tag_o(vrf_client_read_tag[
        (MEMORY_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_read_group_o(vrf_client_read_group[
        (MEMORY_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_read_row_o(vrf_client_read_row[
        (MEMORY_VRF_CLIENT*VRF_ADDR_W) +: VRF_ADDR_W]),
    .vrf_read_mask_o(vrf_client_read_mask[
        (MEMORY_VRF_CLIENT*LANES) +: LANES]),
    .vrf_read_cpl_valid_i(vrf_client_read_cpl_valid[MEMORY_VRF_CLIENT]),
    .vrf_read_cpl_ready_o(vrf_client_read_cpl_ready[MEMORY_VRF_CLIENT]),
    .vrf_read_cpl_exec_context_i(vrf_client_read_cpl_context[
        (MEMORY_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_read_cpl_tag_i(vrf_client_read_cpl_tag[
        (MEMORY_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_read_cpl_group_i(vrf_client_read_cpl_group[
        (MEMORY_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_read_cpl_error_i(vrf_client_read_cpl_error[MEMORY_VRF_CLIENT]),
    .vrf_read_rsp_valid_i(vrf_client_read_rsp_valid[MEMORY_VRF_CLIENT]),
    .vrf_read_rsp_ready_o(vrf_client_read_rsp_ready[MEMORY_VRF_CLIENT]),
    .vrf_read_rsp_exec_context_i(vrf_client_read_rsp_context[
        (MEMORY_VRF_CLIENT*CONTEXT_W) +: CONTEXT_W]),
    .vrf_read_rsp_tag_i(vrf_client_read_rsp_tag[
        (MEMORY_VRF_CLIENT*TAG_W) +: TAG_W]),
    .vrf_read_rsp_group_i(vrf_client_read_rsp_group[
        (MEMORY_VRF_CLIENT*GROUP_ID_W) +: GROUP_ID_W]),
    .vrf_read_rsp_data_i(vrf_client_read_rsp_data[
        (MEMORY_VRF_CLIENT*VRF_ROW_W) +: VRF_ROW_W]),
    .vrf_read_rsp_mask_i(vrf_client_read_rsp_mask[
        (MEMORY_VRF_CLIENT*LANES) +: LANES]),
    .vrf_read_rsp_error_i(vrf_client_read_rsp_error[MEMORY_VRF_CLIENT]),
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

  vsp_cluster_vrf_arbiter #(
    .CLIENT_COUNT(VRF_CLIENT_COUNT),
    .GROUP_COUNT(GROUP_COUNT),
    .VRF_ROW_BYTES(LANES),
    .VRF_ROWS(VREGS),
    .EXEC_CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .CLIENT_W(1),
    .GROUP_ID_W(GROUP_ID_W),
    .VRF_ROW_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W)
  ) u_vrf_arbiter (
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
    .busy_o(vrf_arbiter_busy_o),
    .active_client_o(vrf_arbiter_active_client_unused),
    .active_read_o(vrf_arbiter_active_read_unused)
  );

  initial begin
    if (ELEM_W != 8)
      $error("memory-wrapper VRF row transport requires 8-bit base lanes");
    if (LANES < 1 || GROUP_COUNT < 1 || ISSUE_SLOTS < 1)
      $error("memory-wrapper capacities must be positive");
    if (ACC_W < ELEM_W)
      $error("ACC_W must be at least ELEM_W");
  end
endmodule
