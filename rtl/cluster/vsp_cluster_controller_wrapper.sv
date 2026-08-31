module vsp_cluster_controller_wrapper #(
  // The integration uses EXEC-uword profile v0, whose physical SIMD4 and RF
  // capacities are checked below.  Group/context identity widths remain
  // scalable, but the outer action lane is still globally single-active; this
  // parameterization does not imply matching controller concurrency.
  parameter int GROUP_COUNT       = 4,
  parameter int ISSUE_SLOTS       = 1,
  parameter int QUEUE_DEPTH       = 4,
  parameter int TRACKER_ENTRIES   = 4,
  parameter int LANES             = 4,
  parameter int ELEM_W            = 8,
  parameter int ACC_W             = 32,
  parameter int VREGS             = 16,
  parameter int AREGS             = 8,
  parameter int MREGS             = 4,
  parameter int CONTEXT_COUNT     = 1,
  parameter int TAG_W             = 8,
  parameter int RESOURCE_W        = 8,
  parameter int SIMD4_ID_W        = 8,
  parameter logic [SIMD4_ID_W-1:0] SIMD4_BASE_ID = '0,
  parameter int MEM_EADDR_W       = 32,
  parameter int MEM_OFFSET_W      = 16,
  parameter int ADDR_CONTEXT_W    = 8,
  parameter int DECODE_ERROR_W    =
      vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W,
  parameter int VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter int ARF_ADDR_W = (AREGS <= 2) ? 1 : $clog2(AREGS),
  parameter int MRF_ADDR_W = (MREGS <= 2) ? 1 : $clog2(MREGS),
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1),
  parameter int SPAN_BYTES_W = ((GROUP_COUNT*LANES) <= 1) ? 1 :
                               $clog2((GROUP_COUNT*LANES) + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One ordered action.  EXEC carries an already-collected base/extension
  // packet; MEMORY remains a decoded descriptor in this reference profile.
  input  logic                                      action_valid_i,
  output logic                                      action_ready_o,
  input  logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     action_class_i,
  // Envelope/upstream legality.  A true value does not bypass the EXEC
  // profile expander's final word legality checks.
  input  logic                                      action_legal_i,
  input  logic [DECODE_ERROR_W-1:0]                 action_decode_error_i,
  input  logic [vsp_action_pkg::VSP_CONTROL_OP_W-1:0]
                                                     action_control_op_i,
  input  logic [CONTEXT_W-1:0]                      action_context_i,
  input  logic [TAG_W-1:0]                          action_tag_i,
  input  logic [GROUP_COUNT-1:0]                    action_group_mask_i,

  input  logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_W-1:0]
                                                     action_exec_base_word_i,
  input  logic                                      action_exec_extension_valid_i,
  input  logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_W-1:0]
                                                     action_exec_extension_word_i,
  // Packet diagnostic only: the action producer must present the associated
  // extension before asserting action_valid_i.  This is not a refill request.
  output logic                                      action_exec_extension_required_diag_o,

  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0]         action_memory_op_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_MODE_W-1:0]
                                                     action_memory_addr_mode_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] action_memory_addr_space_i,
  input  logic [ADDR_CONTEXT_W-1:0]                 action_memory_addr_context_i,
  input  logic [MEM_EADDR_W-1:0]                    action_memory_base_eaddr_i,
  input  logic signed [MEM_OFFSET_W-1:0]            action_memory_eaddr_offset_i,
  input  logic [VRF_ADDR_W-1:0]                     action_memory_vrf_row_i,
  input  logic [VRF_ADDR_W-1:0]
                                                     action_memory_index_vrf_row_i,
  input  logic [SPAN_BYTES_W-1:0]                   action_memory_span_bytes_i,

  input  logic [GROUP_COUNT-1:0]                    group_owner_valid_i,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]        group_owner_i,

  output logic                                      action_cpl_valid_o,
  input  logic                                      action_cpl_ready_i,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     action_cpl_class_o,
  output logic [CONTEXT_W-1:0]                      action_cpl_context_o,
  output logic [TAG_W-1:0]                          action_cpl_tag_o,
  output logic [GROUP_COUNT-1:0]                    action_cpl_group_mask_o,
  output logic [vsp_action_pkg::VSP_ACTION_CPL_STATUS_W-1:0]
                                                     action_cpl_status_o,
  output logic [DECODE_ERROR_W-1:0]                 action_cpl_decode_error_o,
  output logic                                      action_cpl_end_o,
  // Successful END-retire pulse, not an accumulation of earlier action status.
  output logic                                      program_done_o,

  // Reference child-engine detail.  For controller-local errors the common
  // action_cpl_group_mask_o remains valid while these class detail fields are
  // canonical zero; action_cpl_status_o is authoritative.
  output logic [GROUP_COUNT-1:0]                    action_cpl_exec_group_mask_o,
  output logic [GROUP_COUNT-1:0]                    action_cpl_exec_result_mask_o,
  output logic                                      action_cpl_exec_illegal_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_exec_illegal_group_mask_o,
  output logic                                      action_cpl_exec_rejected_o,
  output logic                                      action_cpl_exec_empty_mask_o,
  output logic                                      action_cpl_exec_owner_mismatch_o,

  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]         action_cpl_memory_op_o,
  output logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0] action_cpl_memory_status_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     action_cpl_memory_fault_cause_o,
  output logic [MEM_EADDR_W-1:0]                    action_cpl_memory_fault_eaddr_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_requested_group_mask_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_completed_group_mask_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_failed_group_mask_o,
  output logic [SPAN_BYTES_W-1:0]
                                                     action_cpl_memory_bytes_committed_o,
  output logic                                      action_cpl_memory_partial_o,

  // EXEC data results remain independent of ordered command completion.
  output logic                                      exec_result_valid_o,
  input  logic                                      exec_result_ready_i,
  output logic [GROUP_ID_W-1:0]                     exec_result_group_o,
  output logic [CONTEXT_W-1:0]                      exec_result_context_o,
  output logic [TAG_W-1:0]                          exec_result_tag_o,
  output logic                                      exec_result_illegal_o,
  output logic                                      exec_result_has_narrow_o,
  output logic [(LANES*ELEM_W)-1:0]                 exec_result_narrow_o,
  output logic [LANES-1:0]                          exec_result_narrow_mask_o,
  output logic                                      exec_result_has_reduce_o,
  output logic [ACC_W-1:0]                          exec_result_reduce_value_o,
  output logic [INDEX_W-1:0]                        exec_result_reduce_index_o,
  output logic                                      exec_result_has_count_o,
  output logic [OFFSET_W-1:0]                       exec_result_count_o,

  output logic                                      dmem_req_valid_o,
  input  logic                                      dmem_req_ready_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]         dmem_req_op_o,
  output logic [MEM_EADDR_W-1:0]                    dmem_req_eaddr_o,
  output logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] dmem_req_addr_space_o,
  output logic [ADDR_CONTEXT_W-1:0]                 dmem_req_addr_context_o,
  output logic [(LANES*ELEM_W)-1:0]                 dmem_req_wdata_o,
  output logic [LANES-1:0]                          dmem_req_wstrb_o,
  input  logic                                      dmem_rsp_valid_i,
  output logic                                      dmem_rsp_ready_o,
  input  logic [(LANES*ELEM_W)-1:0]                 dmem_rsp_rdata_i,
  input  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     dmem_rsp_fault_cause_i,

  // Integration/verification observability used to construct and check END;
  // these are not sequencer-program-visible architectural state.
  output logic                                      controller_busy_o,
  output logic                                      mem_busy_o,
  output logic                                      vrf_arbiter_busy_o,
  output logic                                      exec_queue_empty_o,
  output logic                                      exec_tracker_empty_o,
  output logic                                      exec_quiescent_o,
  output logic [CONTEXT_COUNT-1:0]
                                                     exec_context_children_quiescent_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      controller_protocol_error_o,
  output logic                                      exec_protocol_error_o,
  output logic                                      mem_protocol_error_o,
  output logic                                      protocol_error_o
);
  import simd_pkg::*;
  import vsp_action_pkg::*;
  import vsp_pkg::*;
  import vsp_exec_uword_pkg::*;

  localparam int IMM_W = 4 * ELEM_W;
  localparam int EXEC_PAYLOAD_W = RESOURCE_W + 1 + SIMD_OP_W + ELEM_MODE_W +
      (3*VRF_ADDR_W) + 1 + IMM_W + (2*ARF_ADDR_W) + 1 +
      (3*MRF_ADDR_W) + 4 + REDUCE_OP_W;
  localparam int MEMORY_PAYLOAD_W = VSP_MEM_OP_W + VSP_MEM_ADDR_MODE_W +
      VSP_MEM_ADDR_SPACE_W + ADDR_CONTEXT_W + MEM_EADDR_W + MEM_OFFSET_W +
      (2*VRF_ADDR_W) + SPAN_BYTES_W;
  localparam int EXEC_CPL_PAYLOAD_W = (3*GROUP_COUNT) + 4;
  localparam int MEMORY_CPL_PAYLOAD_W = VSP_MEM_OP_W +
      VSP_MEM_CPL_STATUS_W + VSP_MEM_FAULT_CAUSE_W + MEM_EADDR_W +
      (3*GROUP_COUNT) + SPAN_BYTES_W + 1;

  logic expand_valid;
  logic expand_legal;
  logic [DECODE_ERROR_W-1:0] expand_error;
  logic [SIMD_OP_W-1:0] expand_op;
  logic [ELEM_MODE_W-1:0] expand_elem_mode;
  logic [3:0] expand_src_a;
  logic [3:0] expand_src_b;
  logic expand_use_imm;
  logic [31:0] expand_imm;
  logic [3:0] expand_dst_vrf;
  logic [2:0] expand_src_arf;
  logic [2:0] expand_dst_arf;
  logic expand_mask_enable;
  logic [1:0] expand_mask_addr;
  logic [1:0] expand_select_mask_addr;
  logic [1:0] expand_dst_mrf;
  logic expand_write_vrf;
  logic expand_write_arf;
  logic expand_write_mrf;
  logic expand_reduce_enable;
  logic [REDUCE_OP_W-1:0] expand_reduce_op;
  logic expand_export_narrow;

  logic selected_action_legal;
  logic [DECODE_ERROR_W-1:0] selected_decode_error;
  logic [EXEC_PAYLOAD_W-1:0] action_exec_payload;
  logic [MEMORY_PAYLOAD_W-1:0] action_memory_payload;
  // One non-flow-through canonical-action holding entry separates encoded
  // EXEC expansion from class routing and child-engine admission.  All action
  // classes cross the same boundary so program order and common identity do
  // not depend on the selected class.  The entry cannot be replaced in its
  // consume cycle; the strict wrapper therefore never hides a second active
  // parent behind the decoded-action controller.
  typedef struct packed {
    logic [VSP_ACTION_CLASS_W-1:0] action_class;
    logic                         legal;
    logic [DECODE_ERROR_W-1:0]    decode_error;
    logic [VSP_CONTROL_OP_W-1:0]  control_op;
    logic [CONTEXT_W-1:0]         context_id;
    logic [TAG_W-1:0]             tag;
    logic [GROUP_COUNT-1:0]       group_mask;
    logic [EXEC_PAYLOAD_W-1:0]    exec_payload;
    logic [MEMORY_PAYLOAD_W-1:0]  memory_payload;
  } canonical_action_t;

  logic canonical_action_valid_q;
  canonical_action_t canonical_action_q;
  logic canonical_action_capture;
  logic canonical_action_fire;
  logic action_controller_ready;
  logic action_controller_busy;
  logic [EXEC_PAYLOAD_W-1:0] controller_exec_payload;
  logic [MEMORY_PAYLOAD_W-1:0] controller_memory_payload;

  logic controller_exec_valid;
  logic controller_exec_ready;
  logic [CONTEXT_W-1:0] controller_exec_context;
  logic [TAG_W-1:0] controller_exec_tag;
  logic [GROUP_COUNT-1:0] controller_exec_group_mask;
  logic controller_memory_valid;
  logic controller_memory_ready;
  logic [CONTEXT_W-1:0] controller_memory_context;
  logic [TAG_W-1:0] controller_memory_tag;
  logic [GROUP_COUNT-1:0] controller_memory_group_mask;

  logic [RESOURCE_W-1:0] exec_exact_resource;
  logic exec_export_narrow;
  logic [SIMD_OP_W-1:0] exec_op;
  logic [ELEM_MODE_W-1:0] exec_elem_mode;
  logic [VRF_ADDR_W-1:0] exec_src_a;
  logic [VRF_ADDR_W-1:0] exec_src_b;
  logic exec_use_imm;
  logic [IMM_W-1:0] exec_imm;
  logic [VRF_ADDR_W-1:0] exec_dst_vrf;
  logic [ARF_ADDR_W-1:0] exec_src_arf;
  logic [ARF_ADDR_W-1:0] exec_dst_arf;
  logic exec_mask_enable;
  logic [MRF_ADDR_W-1:0] exec_mask_addr;
  logic [MRF_ADDR_W-1:0] exec_select_mask_addr;
  logic [MRF_ADDR_W-1:0] exec_dst_mrf;
  logic exec_write_vrf;
  logic exec_write_arf;
  logic exec_write_mrf;
  logic exec_reduce_enable;
  logic [REDUCE_OP_W-1:0] exec_reduce_op;

  logic [VSP_MEM_OP_W-1:0] memory_op;
  logic [VSP_MEM_ADDR_MODE_W-1:0] memory_addr_mode;
  logic [VSP_MEM_ADDR_SPACE_W-1:0] memory_addr_space;
  logic [ADDR_CONTEXT_W-1:0] memory_addr_context;
  logic [MEM_EADDR_W-1:0] memory_base_eaddr;
  logic [MEM_OFFSET_W-1:0] memory_eaddr_offset;
  logic [VRF_ADDR_W-1:0] memory_vrf_row;
  logic [VRF_ADDR_W-1:0] memory_index_vrf_row;
  logic [SPAN_BYTES_W-1:0] memory_span_bytes;

  logic raw_exec_cpl_valid;
  logic raw_exec_cpl_ready;
  logic [CONTEXT_W-1:0] raw_exec_cpl_context;
  logic [TAG_W-1:0] raw_exec_cpl_tag;
  logic [GROUP_COUNT-1:0] raw_exec_cpl_group_mask;
  logic [GROUP_COUNT-1:0] raw_exec_cpl_result_mask;
  logic raw_exec_cpl_illegal;
  logic [GROUP_COUNT-1:0] raw_exec_cpl_illegal_group_mask;
  logic raw_exec_cpl_rejected;
  logic raw_exec_cpl_empty_mask;
  logic raw_exec_cpl_owner_mismatch;
  logic [EXEC_CPL_PAYLOAD_W-1:0] raw_exec_cpl_payload;
  logic controller_exec_cpl_error;

  logic raw_memory_cpl_valid;
  logic raw_memory_cpl_ready;
  logic [CONTEXT_W-1:0] raw_memory_cpl_context;
  logic [TAG_W-1:0] raw_memory_cpl_tag;
  logic [VSP_MEM_OP_W-1:0] raw_memory_cpl_op;
  logic [VSP_MEM_CPL_STATUS_W-1:0] raw_memory_cpl_status;
  logic [VSP_MEM_FAULT_CAUSE_W-1:0] raw_memory_cpl_fault_cause;
  logic [MEM_EADDR_W-1:0] raw_memory_cpl_fault_eaddr;
  logic [GROUP_COUNT-1:0] raw_memory_cpl_requested_mask;
  logic [GROUP_COUNT-1:0] raw_memory_cpl_completed_mask;
  logic [GROUP_COUNT-1:0] raw_memory_cpl_failed_mask;
  logic [SPAN_BYTES_W-1:0] raw_memory_cpl_bytes;
  logic raw_memory_cpl_partial;
  logic [MEMORY_CPL_PAYLOAD_W-1:0] raw_memory_cpl_payload;
  logic controller_memory_cpl_error;

  logic [EXEC_CPL_PAYLOAD_W-1:0] action_cpl_exec_payload;
  logic [MEMORY_CPL_PAYLOAD_W-1:0] action_cpl_memory_payload;
  logic end_quiescent;
  logic exec_cmd_context_error_unused;
  /* verilator lint_off UNUSED */
  logic expand_requires_result_unused;
  logic expand_result_has_narrow_unused;
  logic expand_result_has_reduce_unused;
  logic expand_result_has_count_unused;
  logic raw_wrapper_protocol_error_unused;
  /* verilator lint_on UNUSED */

  vsp_exec_uword_expander #(
    .VREGS(VREGS),
    .AREGS(AREGS),
    .MREGS(MREGS)
  ) u_exec_uword_expander (
    .base_valid_i(action_valid_i &&
                  action_class_i == VSP_ACTION_CLASS_EXEC),
    .base_word_i(action_exec_base_word_i),
    .extension_valid_i(action_exec_extension_valid_i),
    .extension_word_i(action_exec_extension_word_i),
    .extension_required_o(action_exec_extension_required_diag_o),
    .out_valid_o(expand_valid),
    .legal_o(expand_legal),
    .error_cause_o(expand_error),
    .op_o(expand_op),
    .elem_mode_o(expand_elem_mode),
    .src_a_addr_o(expand_src_a),
    .src_b_addr_o(expand_src_b),
    .use_imm_o(expand_use_imm),
    .imm_o(expand_imm),
    .dst_vrf_addr_o(expand_dst_vrf),
    .src_arf_addr_o(expand_src_arf),
    .dst_arf_addr_o(expand_dst_arf),
    .mask_enable_o(expand_mask_enable),
    .mask_addr_o(expand_mask_addr),
    .select_mask_addr_o(expand_select_mask_addr),
    .dst_mrf_addr_o(expand_dst_mrf),
    .write_vrf_o(expand_write_vrf),
    .write_arf_o(expand_write_arf),
    .write_mrf_o(expand_write_mrf),
    .reduce_enable_o(expand_reduce_enable),
    .reduce_op_o(expand_reduce_op),
    .export_narrow_o(expand_export_narrow),
    .requires_result_o(expand_requires_result_unused),
    .result_has_narrow_o(expand_result_has_narrow_unused),
    .result_has_reduce_o(expand_result_has_reduce_unused),
    .result_has_count_o(expand_result_has_count_unused)
  );

  always_comb begin
    selected_action_legal = action_legal_i;
    selected_decode_error = action_decode_error_i;
    if (action_class_i == VSP_ACTION_CLASS_EXEC && action_legal_i) begin
      selected_action_legal = expand_valid && expand_legal;
      selected_decode_error = expand_error;
    end
  end

  // Exact shared-resource metadata remains zero in this strict, nonoverlapped
  // reference controller.  It must later be derived by the admission
  // predecoder before resource-aware concurrent issue is enabled.
  assign action_exec_payload = {
      {RESOURCE_W{1'b0}}, expand_export_narrow, expand_op, expand_elem_mode,
      expand_src_a, expand_src_b, expand_use_imm, expand_imm, expand_dst_vrf,
      expand_src_arf, expand_dst_arf, expand_mask_enable, expand_mask_addr,
      expand_select_mask_addr, expand_dst_mrf, expand_write_vrf,
      expand_write_arf, expand_write_mrf, expand_reduce_enable,
      expand_reduce_op};

  assign action_memory_payload = {
      action_memory_op_i, action_memory_addr_mode_i,
      action_memory_addr_space_i,
      action_memory_addr_context_i, action_memory_base_eaddr_i,
      action_memory_eaddr_offset_i, action_memory_vrf_row_i,
      action_memory_index_vrf_row_i,
      action_memory_span_bytes_i};

  // Admission is deliberately non-elastic at this boundary: an empty entry
  // may capture only while the downstream controller is idle, and consuming a
  // valid entry does not make the input ready in the same cycle.  This keeps
  // the existing global-single-active contract while breaking the late EXEC
  // decode/payload path before class routing.
  assign action_ready_o = rst_ni && !canonical_action_valid_q &&
                          !action_controller_busy;
  assign canonical_action_capture = action_valid_i && action_ready_o;
  assign canonical_action_fire = canonical_action_valid_q &&
                                 action_controller_ready;
  assign controller_busy_o = canonical_action_valid_q ||
                             action_controller_busy;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      canonical_action_valid_q <= 1'b0;
      canonical_action_q <= '0;
    end else if (canonical_action_fire) begin
      canonical_action_valid_q <= 1'b0;
      canonical_action_q <= '0;
    end else if (canonical_action_capture) begin
      canonical_action_valid_q <= 1'b1;
      canonical_action_q.action_class <= action_class_i;
      canonical_action_q.legal <= selected_action_legal;
      canonical_action_q.decode_error <= selected_decode_error;
      canonical_action_q.control_op <= action_control_op_i;
      canonical_action_q.context_id <= action_context_i;
      canonical_action_q.tag <= action_tag_i;
      canonical_action_q.group_mask <= action_group_mask_i;
      canonical_action_q.exec_payload <= action_exec_payload;
      canonical_action_q.memory_payload <= action_memory_payload;
    end
  end

  assign {exec_exact_resource, exec_export_narrow, exec_op, exec_elem_mode,
          exec_src_a, exec_src_b, exec_use_imm, exec_imm, exec_dst_vrf,
          exec_src_arf, exec_dst_arf, exec_mask_enable, exec_mask_addr,
          exec_select_mask_addr, exec_dst_mrf, exec_write_vrf,
          exec_write_arf, exec_write_mrf, exec_reduce_enable,
          exec_reduce_op} = controller_exec_payload;

  assign {memory_op, memory_addr_mode, memory_addr_space, memory_addr_context,
          memory_base_eaddr, memory_eaddr_offset, memory_vrf_row,
          memory_index_vrf_row, memory_span_bytes} = controller_memory_payload;

  assign raw_exec_cpl_payload = {
      raw_exec_cpl_group_mask, raw_exec_cpl_result_mask,
      raw_exec_cpl_illegal, raw_exec_cpl_illegal_group_mask,
      raw_exec_cpl_rejected, raw_exec_cpl_empty_mask,
      raw_exec_cpl_owner_mismatch};
  assign controller_exec_cpl_error = raw_exec_cpl_illegal ||
      raw_exec_cpl_rejected || raw_exec_cpl_empty_mask ||
      raw_exec_cpl_owner_mismatch;

  assign raw_memory_cpl_payload = {
      raw_memory_cpl_op, raw_memory_cpl_status,
      raw_memory_cpl_fault_cause, raw_memory_cpl_fault_eaddr,
      raw_memory_cpl_requested_mask, raw_memory_cpl_completed_mask,
      raw_memory_cpl_failed_mask, raw_memory_cpl_bytes,
      raw_memory_cpl_partial};
  assign controller_memory_cpl_error =
      raw_memory_cpl_status != VSP_MEM_CPL_OK;

  assign {action_cpl_exec_group_mask_o, action_cpl_exec_result_mask_o,
          action_cpl_exec_illegal_o,
          action_cpl_exec_illegal_group_mask_o,
          action_cpl_exec_rejected_o, action_cpl_exec_empty_mask_o,
          action_cpl_exec_owner_mismatch_o} = action_cpl_exec_payload;
  assign {action_cpl_memory_op_o, action_cpl_memory_status_o,
          action_cpl_memory_fault_cause_o, action_cpl_memory_fault_eaddr_o,
          action_cpl_memory_requested_group_mask_o,
          action_cpl_memory_completed_group_mask_o,
          action_cpl_memory_failed_group_mask_o,
          action_cpl_memory_bytes_committed_o,
          action_cpl_memory_partial_o} = action_cpl_memory_payload;

  // A pending canonical parent is part of controller quiescence.  END first
  // transfers out of the holding entry and then observes downstream drain in
  // STATE_WAIT_END, avoiding both an early END completion and self-deadlock.
  assign end_quiescent = !canonical_action_valid_q && exec_quiescent_o &&
                         !mem_busy_o && !vrf_arbiter_busy_o;
  assign protocol_error_o = controller_protocol_error_o ||
                            exec_protocol_error_o || mem_protocol_error_o;

  vsp_decoded_action_controller #(
    .GROUP_COUNT(GROUP_COUNT),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .DECODE_ERROR_W(DECODE_ERROR_W),
    .EXEC_PAYLOAD_W(EXEC_PAYLOAD_W),
    .MEMORY_PAYLOAD_W(MEMORY_PAYLOAD_W),
    .EXEC_CPL_PAYLOAD_W(EXEC_CPL_PAYLOAD_W),
    .MEMORY_CPL_PAYLOAD_W(MEMORY_CPL_PAYLOAD_W),
    .CONTEXT_W(CONTEXT_W)
  ) u_action_controller (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .action_valid_i(canonical_action_valid_q),
    .action_ready_o(action_controller_ready),
    .action_class_i(canonical_action_q.action_class),
    .action_legal_i(canonical_action_q.legal),
    .action_decode_error_i(canonical_action_q.decode_error),
    .action_control_op_i(canonical_action_q.control_op),
    .action_context_i(canonical_action_q.context_id),
    .action_tag_i(canonical_action_q.tag),
    .action_group_mask_i(canonical_action_q.group_mask),
    .action_exec_payload_i(canonical_action_q.exec_payload),
    .action_memory_payload_i(canonical_action_q.memory_payload),
    .group_owner_valid_i(group_owner_valid_i),
    .group_owner_i(group_owner_i),
    .end_quiescent_i(end_quiescent),
    .exec_cmd_valid_o(controller_exec_valid),
    .exec_cmd_ready_i(controller_exec_ready),
    .exec_cmd_context_o(controller_exec_context),
    .exec_cmd_tag_o(controller_exec_tag),
    .exec_cmd_group_mask_o(controller_exec_group_mask),
    .exec_cmd_payload_o(controller_exec_payload),
    .exec_cpl_valid_i(raw_exec_cpl_valid),
    .exec_cpl_ready_o(raw_exec_cpl_ready),
    .exec_cpl_context_i(raw_exec_cpl_context),
    .exec_cpl_tag_i(raw_exec_cpl_tag),
    .exec_cpl_error_i(controller_exec_cpl_error),
    .exec_cpl_payload_i(raw_exec_cpl_payload),
    .memory_cmd_valid_o(controller_memory_valid),
    .memory_cmd_ready_i(controller_memory_ready),
    .memory_cmd_context_o(controller_memory_context),
    .memory_cmd_tag_o(controller_memory_tag),
    .memory_cmd_group_mask_o(controller_memory_group_mask),
    .memory_cmd_payload_o(controller_memory_payload),
    .memory_cpl_valid_i(raw_memory_cpl_valid),
    .memory_cpl_ready_o(raw_memory_cpl_ready),
    .memory_cpl_context_i(raw_memory_cpl_context),
    .memory_cpl_tag_i(raw_memory_cpl_tag),
    .memory_cpl_error_i(controller_memory_cpl_error),
    .memory_cpl_payload_i(raw_memory_cpl_payload),
    .action_cpl_valid_o(action_cpl_valid_o),
    .action_cpl_ready_i(action_cpl_ready_i),
    .action_cpl_class_o(action_cpl_class_o),
    .action_cpl_context_o(action_cpl_context_o),
    .action_cpl_tag_o(action_cpl_tag_o),
    .action_cpl_group_mask_o(action_cpl_group_mask_o),
    .action_cpl_status_o(action_cpl_status_o),
    .action_cpl_decode_error_o(action_cpl_decode_error_o),
    .action_cpl_exec_payload_o(action_cpl_exec_payload),
    .action_cpl_memory_payload_o(action_cpl_memory_payload),
    .action_cpl_end_o(action_cpl_end_o),
    .program_done_o(program_done_o),
    .busy_o(action_controller_busy),
    .protocol_error_clear_i(protocol_error_clear_i),
    .protocol_error_o(controller_protocol_error_o)
  );

  vsp_cluster_memory_wrapper #(
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
    .MEM_EADDR_W(MEM_EADDR_W),
    .MEM_OFFSET_W(MEM_OFFSET_W),
    .ADDR_CONTEXT_W(ADDR_CONTEXT_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .ARF_ADDR_W(ARF_ADDR_W),
    .MRF_ADDR_W(MRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W),
    .SPAN_BYTES_W(SPAN_BYTES_W)
  ) u_cluster_memory (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .exec_cmd_valid_i(controller_exec_valid),
    .exec_cmd_ready_o(controller_exec_ready),
    .exec_cmd_context_i(controller_exec_context),
    .exec_cmd_tag_i(controller_exec_tag),
    .exec_cmd_group_mask_i(controller_exec_group_mask),
    .exec_cmd_exact_resource_i(exec_exact_resource),
    .exec_cmd_export_narrow_i(exec_export_narrow),
    .exec_cmd_op_i(exec_op),
    .exec_cmd_elem_mode_i(exec_elem_mode),
    .exec_cmd_src_a_addr_i(exec_src_a),
    .exec_cmd_src_b_addr_i(exec_src_b),
    .exec_cmd_use_imm_i(exec_use_imm),
    .exec_cmd_imm_i(exec_imm),
    .exec_cmd_dst_vrf_addr_i(exec_dst_vrf),
    .exec_cmd_src_arf_addr_i(exec_src_arf),
    .exec_cmd_dst_arf_addr_i(exec_dst_arf),
    .exec_cmd_mask_enable_i(exec_mask_enable),
    .exec_cmd_mask_addr_i(exec_mask_addr),
    .exec_cmd_select_mask_addr_i(exec_select_mask_addr),
    .exec_cmd_dst_mrf_addr_i(exec_dst_mrf),
    .exec_cmd_write_vrf_i(exec_write_vrf),
    .exec_cmd_write_arf_i(exec_write_arf),
    .exec_cmd_write_mrf_i(exec_write_mrf),
    .exec_cmd_reduce_enable_i(exec_reduce_enable),
    .exec_cmd_reduce_op_i(exec_reduce_op),
    .exec_cmd_context_error_o(exec_cmd_context_error_unused),
    .group_owner_valid_i(group_owner_valid_i),
    .group_owner_i(group_owner_i),
    .exec_cpl_valid_o(raw_exec_cpl_valid),
    .exec_cpl_ready_i(raw_exec_cpl_ready),
    .exec_cpl_context_o(raw_exec_cpl_context),
    .exec_cpl_tag_o(raw_exec_cpl_tag),
    .exec_cpl_group_mask_o(raw_exec_cpl_group_mask),
    .exec_cpl_result_mask_o(raw_exec_cpl_result_mask),
    .exec_cpl_illegal_o(raw_exec_cpl_illegal),
    .exec_cpl_illegal_group_mask_o(raw_exec_cpl_illegal_group_mask),
    .exec_cpl_rejected_o(raw_exec_cpl_rejected),
    .exec_cpl_empty_mask_o(raw_exec_cpl_empty_mask),
    .exec_cpl_owner_mismatch_o(raw_exec_cpl_owner_mismatch),
    .exec_result_valid_o(exec_result_valid_o),
    .exec_result_ready_i(exec_result_ready_i),
    .exec_result_group_o(exec_result_group_o),
    .exec_result_context_o(exec_result_context_o),
    .exec_result_tag_o(exec_result_tag_o),
    .exec_result_illegal_o(exec_result_illegal_o),
    .exec_result_has_narrow_o(exec_result_has_narrow_o),
    .exec_result_narrow_o(exec_result_narrow_o),
    .exec_result_narrow_mask_o(exec_result_narrow_mask_o),
    .exec_result_has_reduce_o(exec_result_has_reduce_o),
    .exec_result_reduce_value_o(exec_result_reduce_value_o),
    .exec_result_reduce_index_o(exec_result_reduce_index_o),
    .exec_result_has_count_o(exec_result_has_count_o),
    .exec_result_count_o(exec_result_count_o),
    .mem_cmd_valid_i(controller_memory_valid),
    .mem_cmd_ready_o(controller_memory_ready),
    .mem_cmd_op_i(memory_op),
    .mem_cmd_addr_mode_i(memory_addr_mode),
    .mem_cmd_exec_context_i(controller_memory_context),
    .mem_cmd_tag_i(controller_memory_tag),
    .mem_cmd_addr_space_i(memory_addr_space),
    .mem_cmd_addr_context_i(memory_addr_context),
    .mem_cmd_base_eaddr_i(memory_base_eaddr),
    .mem_cmd_eaddr_offset_i(memory_eaddr_offset),
    .mem_cmd_group_mask_i(controller_memory_group_mask),
    .mem_cmd_vrf_row_i(memory_vrf_row),
    .mem_cmd_index_vrf_row_i(memory_index_vrf_row),
    .mem_cmd_span_bytes_i(memory_span_bytes),
    .mem_cpl_valid_o(raw_memory_cpl_valid),
    .mem_cpl_ready_i(raw_memory_cpl_ready),
    .mem_cpl_op_o(raw_memory_cpl_op),
    .mem_cpl_exec_context_o(raw_memory_cpl_context),
    .mem_cpl_tag_o(raw_memory_cpl_tag),
    .mem_cpl_status_o(raw_memory_cpl_status),
    .mem_cpl_fault_cause_o(raw_memory_cpl_fault_cause),
    .mem_cpl_fault_eaddr_o(raw_memory_cpl_fault_eaddr),
    .mem_cpl_requested_group_mask_o(raw_memory_cpl_requested_mask),
    .mem_cpl_completed_group_mask_o(raw_memory_cpl_completed_mask),
    .mem_cpl_failed_group_mask_o(raw_memory_cpl_failed_mask),
    .mem_cpl_bytes_committed_o(raw_memory_cpl_bytes),
    .mem_cpl_partial_o(raw_memory_cpl_partial),
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
    .mem_busy_o(mem_busy_o),
    .vrf_arbiter_busy_o(vrf_arbiter_busy_o),
    .exec_context_children_quiescent_o(
        exec_context_children_quiescent_o),
    .exec_queue_empty_o(exec_queue_empty_o),
    .exec_tracker_empty_o(exec_tracker_empty_o),
    .exec_quiescent_o(exec_quiescent_o),
    .protocol_error_clear_i(protocol_error_clear_i),
    .exec_protocol_error_o(exec_protocol_error_o),
    .mem_protocol_error_o(mem_protocol_error_o),
    .protocol_error_o(raw_wrapper_protocol_error_unused)
  );

  initial begin
    if (LANES != 4 || ELEM_W != 8 || ACC_W != 32 || VREGS != 16 ||
        AREGS != 8 || MREGS != 4) begin
      $error("controller wrapper requires EXEC-uword profile v0 shape");
    end
    if (DECODE_ERROR_W != VSP_EXEC_UWORD_ERROR_W) begin
      $error("DECODE_ERROR_W must match EXEC-uword profile v0");
    end
  end

  /* verilator lint_off UNUSED */
  logic diagnostics_used;
  assign diagnostics_used = exec_cmd_context_error_unused;
  /* verilator lint_on UNUSED */
endmodule
