module vsp_uword_cluster_program_wrapper #(
  parameter int PC_W              = 32,
  parameter int STORE_WORDS       = 64,
  parameter logic [PC_W-1:0] STORE_BASE_PC = '0,
  parameter int FETCH_WORDS       = 4,
  // Selects the provider connected to vsp_uword_program_source.  The default
  // keeps the behavioral control store for focused control-path verification;
  // product memory-system wrappers select the external provider boundary.
  parameter bit EXTERNAL_FETCH_PROVIDER = 1'b0,
  parameter int ADMIT_SLOTS       = 3,
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
  parameter int STATE_REGS        = 32,
  parameter int DECODE_ERROR_W    =
      vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W,
  parameter int VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 :
                             $clog2(GROUP_COUNT),
  parameter int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1),
  parameter int SPAN_BYTES_W = ((GROUP_COUNT*LANES) <= 1) ? 1 :
                               $clog2((GROUP_COUNT*LANES) + 1),
  parameter int STATE_REG_INDEX_W = (STATE_REGS <= 2) ? 1 :
                                    $clog2(STATE_REGS),
  parameter int FETCH_COUNT_W = (FETCH_WORDS < 2) ? 1 :
                                $clog2(FETCH_WORDS + 1)
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  // Behavioral control-store programming port.  Program words use byte PCs
  // and may be changed only while no program is active.
  input  logic                                      store_write_valid_i,
  output logic                                      store_write_ready_o,
  input  logic [PC_W-1:0]                           store_write_pc_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_W-1:0]    store_write_data_i,

  // External instruction-provider boundary.  Its request/response shape is
  // intentionally identical to the current control store.  Redirect commit
  // is exported so an accepted external transaction can be poisoned and
  // drained without exposing stale words to the framer.
  output logic                                      ifetch_provider_req_valid_o,
  input  logic                                      ifetch_provider_req_ready_i,
  output logic [PC_W-1:0]                           ifetch_provider_req_pc_o,
  output logic [FETCH_COUNT_W-1:0]
                                                     ifetch_provider_req_word_count_o,
  input  logic                                      ifetch_provider_rsp_valid_i,
  output logic                                      ifetch_provider_rsp_ready_o,
  input  logic [(FETCH_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
                                                     ifetch_provider_rsp_words_i,
  input  logic                                      ifetch_provider_rsp_fault_i,
  output logic                                      ifetch_redirect_commit_o,

  // Launch captures all execution-envelope fields.  Later changes on these
  // inputs cannot alter a running stream.
  input  logic                                      start_valid_i,
  output logic                                      start_ready_o,
  input  logic [PC_W-1:0]                           start_pc_i,
  input  logic [PC_W-1:0]                           end_pc_i,
  input  logic [CONTEXT_W-1:0]                      start_context_i,
  input  logic [GROUP_COUNT-1:0]                    start_group_mask_i,
  input  logic [TAG_W-1:0]                          start_tag_seed_i,

  output logic [PC_W-1:0]                           fetch_pc_o,
  output logic                                      fetch_running_o,
  output logic                                      fetch_stop_o,
  output logic                                      program_active_o,
  // done denotes retirement of a legal, range-final END.  failed denotes a
  // drained stream which did not reach such an END.  Both are one-cycle
  // pulses; program_error is sticky through the completed launch.
  output logic                                      program_done_o,
  output logic                                      program_failed_o,
  output logic                                      program_error_o,
  output logic                                      program_halted_o,
  output logic [PC_W-1:0]                           program_terminal_pc_o,

  // Ordered action completions remain externally visible.  Backpressure here
  // also backpressures the strict program stream.
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
  // MEMORY-class detail is valid with an ordered MEMORY completion.  Other
  // completion classes drive canonical zero so software-facing integration
  // does not have to inspect stale child-engine payload.
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]         action_cpl_memory_op_o,
  output logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
                                                     action_cpl_memory_status_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     action_cpl_memory_fault_cause_o,
  output logic [MEM_EADDR_W-1:0]
                                                     action_cpl_memory_fault_eaddr_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_requested_group_mask_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_completed_group_mask_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_failed_group_mask_o,
  output logic [SPAN_BYTES_W-1:0]
                                                     action_cpl_memory_bytes_committed_o,
  output logic                                      action_cpl_memory_partial_o,

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

  input  logic                                      protocol_error_clear_i,
  output logic                                      fetch_protocol_error_o,
  output logic                                      cluster_protocol_error_o,
  output logic                                      protocol_error_o
);
  import vsp_action_pkg::*;
  import vsp_exec_uword_pkg::*;
  import vsp_sequencer_state_pkg::*;
  import vsp_uword_pkg::*;

  logic control_store_write_valid;
  logic control_store_write_ready;
  logic control_store_req_valid;
  logic control_store_req_ready;
  logic control_store_rsp_valid;
  logic control_store_rsp_ready;
  logic [(FETCH_WORDS*VSP_UWORD_W)-1:0] control_store_rsp_words;
  logic control_store_rsp_fault;
  logic store_req_valid;
  logic store_req_ready;
  logic [PC_W-1:0] store_req_pc;
  logic [FETCH_COUNT_W-1:0] store_req_word_count;
  logic store_rsp_valid;
  logic store_rsp_ready;
  logic [(FETCH_WORDS*VSP_UWORD_W)-1:0] store_rsp_words;
  logic store_rsp_fault;
  logic control_store_protocol_error;

  logic source_start_valid;
  logic source_start_ready;
  logic source_redirect_valid;
  logic source_redirect_ready;
  logic [PC_W-1:0] source_redirect_pc;
  logic source_bundle_valid;
  logic source_bundle_ready;
  logic [(FETCH_WORDS*VSP_UWORD_W)-1:0] source_bundle_words;
  logic [FETCH_COUNT_W-1:0] source_bundle_word_count;
  logic [PC_W-1:0] source_bundle_base_pc;
  logic source_bundle_last;
  logic [PC_W-1:0] source_current_pc;
  logic source_running;
  logic source_delivery_done;
  logic source_store_fault;
  logic source_protocol_error;
  logic source_terminal_drain_q;

  logic framer_bundle_valid;
  logic framer_bundle_ready;
  logic [ADMIT_SLOTS-1:0] record_valid;
  logic [ADMIT_SLOTS-1:0] record_ready;
  logic [ADMIT_SLOTS-1:0] record_accept;
  logic [(ADMIT_SLOTS*VSP_ACTION_CLASS_W)-1:0] record_class;
  logic [ADMIT_SLOTS-1:0] record_major_defined;
  logic [(ADMIT_SLOTS*PC_W)-1:0] record_start_pc;
  logic [(ADMIT_SLOTS*VSP_UWORD_WORD_COUNT_W)-1:0]
      record_word_count;
  logic [(ADMIT_SLOTS*VSP_UWORD_WORD_COUNT_W)-1:0]
      record_present_word_count;
  logic [(ADMIT_SLOTS*VSP_UWORD_MAX_RECORD_WORDS*VSP_UWORD_W)-1:0]
      record_words;
  logic [ADMIT_SLOTS-1:0] record_truncated;
  logic [ADMIT_SLOTS-1:0] record_terminal;
  logic framer_stop_fetch;
  logic [PC_W-1:0] framer_terminal_pc;
  logic framer_terminal_accept;
  logic framer_halted;
  logic framer_terminal_clear;
  logic framer_clear_q;
  logic framer_stream_abort_q;
  logic framer_redirect_flush;
  logic framer_delivery_done;
  logic framer_idle;
  logic framer_protocol_error;

  logic adapter_record_ready;
  logic decode_action_valid;
  logic decode_action_ready;
  logic [VSP_ACTION_CLASS_W-1:0] decode_action_class;
  logic decode_action_legal;
  logic [DECODE_ERROR_W-1:0] decode_action_decode_error;
  logic [VSP_CONTROL_OP_W-1:0] decode_action_control_op;
  logic [CONTEXT_W-1:0] decode_action_context;
  logic [TAG_W-1:0] decode_action_tag;
  logic [GROUP_COUNT-1:0] decode_action_group_mask;
  logic [VSP_EXEC_UWORD_W-1:0] decode_exec_base_word;
  logic decode_exec_extension_valid;
  logic [VSP_EXEC_UWORD_W-1:0] decode_exec_extension_word;
  logic decode_action_is_state;
  logic [VSP_STATE_OP_W-1:0] decode_state_op;
  logic [STATE_REG_INDEX_W-1:0] decode_state_rd;
  logic [STATE_REG_INDEX_W-1:0] decode_state_rs1;
  logic [STATE_REG_INDEX_W-1:0] decode_state_rs2;
  logic [31:0] decode_state_imm;
  logic decode_action_is_branch;
  logic [VSP_BRANCH_COND_W-1:0] decode_branch_cond;
  logic [STATE_REG_INDEX_W-1:0] decode_branch_rs1;
  logic [STATE_REG_INDEX_W-1:0] decode_branch_rs2;
  logic signed [31:0] decode_branch_offset;
  logic [vsp_pkg::VSP_MEM_OP_W-1:0] decode_memory_op;
  logic [vsp_pkg::VSP_MEM_ADDR_MODE_W-1:0] decode_memory_addr_mode;
  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] decode_memory_addr_space;
  logic [VSP_MEMORY_UWORD_ADDR_CONTEXT_W-1:0]
      decode_memory_addr_context;
  logic [MEM_EADDR_W-1:0] decode_memory_base_eaddr;
  logic signed [VSP_MEMORY_UWORD_OFFSET_W-1:0]
      decode_memory_eaddr_offset;
  logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0] decode_memory_vrf_row;
  logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0]
      decode_memory_index_vrf_row;
  logic [VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0]
      decode_memory_span_bytes;
  logic [PC_W-1:0] decode_action_start_pc;
  logic decode_action_is_end;

  // Semantic decode is captured before class routing.  This stage snapshots
  // resolved MEMORY addresses as well as CONTROL/EXEC fields, so downstream
  // engines never depend on a live instruction word and MEMORY never depends
  // on a later scalar-state value.  Branch operands are intentionally read at
  // ordered dispatch below.  The current strict program profile deliberately
  // does not replace this entry in the cycle it is dispatched.
  typedef struct packed {
    logic [VSP_ACTION_CLASS_W-1:0] action_class;
    logic action_legal;
    logic [DECODE_ERROR_W-1:0] decode_error;
    logic [VSP_CONTROL_OP_W-1:0] control_op;
    logic [CONTEXT_W-1:0] action_context;
    logic [TAG_W-1:0] tag;
    logic [GROUP_COUNT-1:0] group_mask;
    logic [VSP_EXEC_UWORD_W-1:0] exec_base_word;
    logic exec_extension_valid;
    logic [VSP_EXEC_UWORD_W-1:0] exec_extension_word;
    logic is_state;
    logic [VSP_STATE_OP_W-1:0] state_op;
    logic [STATE_REG_INDEX_W-1:0] state_rd;
    logic [STATE_REG_INDEX_W-1:0] state_rs1;
    logic [STATE_REG_INDEX_W-1:0] state_rs2;
    logic [31:0] state_imm;
    logic is_branch;
    logic [VSP_BRANCH_COND_W-1:0] branch_cond;
    logic [STATE_REG_INDEX_W-1:0] branch_rs1;
    logic [STATE_REG_INDEX_W-1:0] branch_rs2;
    logic signed [31:0] branch_offset;
    logic [vsp_pkg::VSP_MEM_OP_W-1:0] memory_op;
    logic [vsp_pkg::VSP_MEM_ADDR_MODE_W-1:0] memory_addr_mode;
    logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] memory_addr_space;
    logic [VSP_MEMORY_UWORD_ADDR_CONTEXT_W-1:0] memory_addr_context;
    logic [MEM_EADDR_W-1:0] memory_base_eaddr;
    logic signed [VSP_MEMORY_UWORD_OFFSET_W-1:0] memory_eaddr_offset;
    logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0] memory_vrf_row;
    logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0] memory_index_vrf_row;
    logic [VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0] memory_span_bytes;
    logic [PC_W-1:0] start_pc;
    logic is_end;
  } decoded_action_t;

  logic decoded_action_valid_q;
  decoded_action_t decoded_action_q;
  logic decode_action_fire;
  logic decoded_action_fire;

  logic adapter_action_valid;
  logic adapter_action_ready;
  logic [VSP_ACTION_CLASS_W-1:0] adapter_action_class;
  logic adapter_action_legal;
  logic [DECODE_ERROR_W-1:0] adapter_action_decode_error;
  logic [VSP_CONTROL_OP_W-1:0] adapter_action_control_op;
  logic [CONTEXT_W-1:0] adapter_action_context;
  logic [TAG_W-1:0] adapter_action_tag;
  logic [GROUP_COUNT-1:0] adapter_action_group_mask;
  logic [VSP_EXEC_UWORD_W-1:0] adapter_exec_base_word;
  logic adapter_exec_extension_valid;
  logic [VSP_EXEC_UWORD_W-1:0] adapter_exec_extension_word;
  logic adapter_action_is_state;
  logic [VSP_STATE_OP_W-1:0] adapter_state_op;
  logic [STATE_REG_INDEX_W-1:0] adapter_state_rd;
  logic [STATE_REG_INDEX_W-1:0] adapter_state_rs1;
  logic [STATE_REG_INDEX_W-1:0] adapter_state_rs2;
  logic [31:0] adapter_state_imm;
  logic adapter_action_is_branch;
  logic [VSP_BRANCH_COND_W-1:0] adapter_branch_cond;
  logic [STATE_REG_INDEX_W-1:0] adapter_branch_rs1;
  logic [STATE_REG_INDEX_W-1:0] adapter_branch_rs2;
  logic signed [31:0] adapter_branch_offset;
  logic adapter_memory_base_read_valid;
  logic [VSP_MEMORY_UWORD_STATE_REG_W-1:0]
      adapter_memory_base_read_reg;
  logic [MEM_EADDR_W-1:0] adapter_memory_base_read_data;
  logic adapter_memory_base_read_legal;
  logic [vsp_pkg::VSP_MEM_OP_W-1:0] adapter_memory_op;
  logic [vsp_pkg::VSP_MEM_ADDR_MODE_W-1:0] adapter_memory_addr_mode;
  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
      adapter_memory_addr_space;
  logic [VSP_MEMORY_UWORD_ADDR_CONTEXT_W-1:0]
      adapter_memory_addr_context;
  logic [MEM_EADDR_W-1:0] adapter_memory_base_eaddr;
  logic signed [VSP_MEMORY_UWORD_OFFSET_W-1:0]
      adapter_memory_eaddr_offset;
  logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0] adapter_memory_vrf_row;
  logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0]
      adapter_memory_index_vrf_row;
  // Narrow profiles intentionally consume only the resolved bits their
  // physical group count can represent; all seven bits are live at 16 groups.
  /* verilator lint_off UNUSED */
  logic [VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0]
      adapter_memory_span_bytes;
  /* verilator lint_on UNUSED */
  logic [PC_W-1:0] adapter_action_start_pc;
  logic adapter_action_is_end;
  logic adapter_end_allowed;

  logic cluster_action_valid;
  logic cluster_action_ready;
  logic cluster_action_cpl_valid;
  logic cluster_action_cpl_ready;
  logic [VSP_ACTION_CLASS_W-1:0] cluster_action_cpl_class;
  logic [CONTEXT_W-1:0] cluster_action_cpl_context;
  logic [TAG_W-1:0] cluster_action_cpl_tag;
  logic [GROUP_COUNT-1:0] cluster_action_cpl_group_mask;
  logic [VSP_ACTION_CPL_STATUS_W-1:0] cluster_action_cpl_status;
  logic [DECODE_ERROR_W-1:0] cluster_action_cpl_decode_error;
  logic cluster_action_cpl_end;
  logic [vsp_pkg::VSP_MEM_OP_W-1:0] cluster_action_cpl_memory_op;
  logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
      cluster_action_cpl_memory_status;
  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
      cluster_action_cpl_memory_fault_cause;
  logic [MEM_EADDR_W-1:0] cluster_action_cpl_memory_fault_eaddr;
  logic [GROUP_COUNT-1:0]
      cluster_action_cpl_memory_requested_group_mask;
  logic [GROUP_COUNT-1:0]
      cluster_action_cpl_memory_completed_group_mask;
  logic [GROUP_COUNT-1:0]
      cluster_action_cpl_memory_failed_group_mask;
  logic [SPAN_BYTES_W-1:0] cluster_action_cpl_memory_bytes_committed;
  logic cluster_action_cpl_memory_partial;

  logic state_action_selected;
  logic state_cmd_valid;
  logic state_cmd_ready;
  logic state_cpl_valid;
  logic state_cpl_ready;
  logic [CONTEXT_W-1:0] state_cpl_context;
  logic [TAG_W-1:0] state_cpl_tag;
  logic [VSP_STATE_CPL_STATUS_W-1:0] state_cpl_status;
  logic state_busy;
  logic state_router_protocol_error_q;

  logic branch_action_selected;
  logic branch_issue_valid;
  logic branch_issue_ready;
  logic branch_fire;
  logic branch_redirect_fire;
  logic branch_condition_legal;
  logic branch_taken;
  logic branch_next_pc_valid;
  logic [PC_W-1:0] branch_next_pc;
  logic control_read_valid;
  logic [MEM_EADDR_W-1:0] control_read_rs1_data;
  logic [MEM_EADDR_W-1:0] control_read_rs2_data;
  logic control_read_legal;
  logic branch_cpl_valid_q;
  logic branch_cpl_ready;
  logic [CONTEXT_W-1:0] branch_cpl_context_q;
  logic [TAG_W-1:0] branch_cpl_tag_q;
  logic [VSP_ACTION_CPL_STATUS_W-1:0] branch_cpl_status_q;
  logic [DECODE_ERROR_W-1:0] branch_cpl_decode_error_q;

  logic [ADDR_CONTEXT_W-1:0] action_memory_addr_context;
  logic signed [MEM_OFFSET_W-1:0] action_memory_eaddr_offset;
  logic [VRF_ADDR_W-1:0] action_memory_vrf_row;
  logic [VRF_ADDR_W-1:0] action_memory_index_vrf_row;
  logic [SPAN_BYTES_W-1:0] action_memory_span_bytes;

  logic action_record_valid_q;
  logic [VSP_ACTION_CLASS_W-1:0] action_record_class_q;
  logic action_record_major_defined_q;
  logic [PC_W-1:0] action_record_start_pc_q;
  logic [VSP_UWORD_WORD_COUNT_W-1:0] action_record_word_count_q;
  logic [VSP_UWORD_WORD_COUNT_W-1:0]
      action_record_present_word_count_q;
  logic [(VSP_UWORD_MAX_RECORD_WORDS*VSP_UWORD_W)-1:0]
      action_record_words_q;
  logic action_record_truncated_q;

  logic [CONTEXT_W-1:0] program_context_q;
  logic [GROUP_COUNT-1:0] program_group_mask_q;
  logic [PC_W-1:0] program_start_pc_q;
  logic [PC_W-1:0] program_end_pc_q;
  logic program_active_q;
  logic program_done_q;
  logic program_failed_q;
  logic program_error_q;
  logic eof_records_done_q;
  logic end_retired_q;
  logic terminal_boundary_error_q;
  logic transport_failure_q;

  logic [GROUP_COUNT-1:0] group_owner_valid;
  logic [(GROUP_COUNT*CONTEXT_W)-1:0] group_owner;
  logic cluster_raw_program_done;
  logic cluster_controller_busy;
  logic cluster_mem_busy;
  logic cluster_vrf_arbiter_busy;
  logic cluster_exec_queue_empty;
  logic cluster_exec_tracker_empty;
  logic cluster_exec_quiescent;
  logic [CONTEXT_COUNT-1:0] cluster_context_quiescent;
  logic cluster_controller_protocol_error;
  logic cluster_exec_protocol_error;
  logic cluster_mem_protocol_error;
  logic action_exec_extension_required_unused;
  logic cluster_raw_protocol_error_unused;
  logic action_cpl_fire;
  logic start_fire;
  logic terminal_boundary_error_now;
  logic program_finish_success;
  logic program_finish_failure;
  logic transport_failure_now;
  logic completion_parent_overlap;
  logic active_engine_overlap;

  localparam int BRANCH_CALC_W = ((PC_W + 1) > 33) ? (PC_W + 1) : 33;
  logic signed [BRANCH_CALC_W-1:0] branch_pc_ext;
  logic signed [BRANCH_CALC_W-1:0] branch_offset_ext;
  logic signed [BRANCH_CALC_W-1:0] branch_target_ext;
  logic signed [BRANCH_CALC_W-1:0] branch_fallthrough_ext;
  logic signed [BRANCH_CALC_W-1:0] branch_selected_pc_ext;
  logic signed [BRANCH_CALC_W-1:0] program_start_pc_ext;
  logic signed [BRANCH_CALC_W-1:0] program_end_pc_ext;

  // Registered semantic-decode output.  Keeping these aliases separate from
  // the decoder's combinational decode_* signals makes the class router and
  // all engines consume only stall-stable state.
  assign adapter_action_valid = decoded_action_valid_q && program_active_q;
  assign adapter_action_class = decoded_action_q.action_class;
  assign adapter_action_legal = decoded_action_q.action_legal;
  assign adapter_action_decode_error = decoded_action_q.decode_error;
  assign adapter_action_control_op = decoded_action_q.control_op;
  assign adapter_action_context = decoded_action_q.action_context;
  assign adapter_action_tag = decoded_action_q.tag;
  assign adapter_action_group_mask = decoded_action_q.group_mask;
  assign adapter_exec_base_word = decoded_action_q.exec_base_word;
  assign adapter_exec_extension_valid =
      decoded_action_q.exec_extension_valid;
  assign adapter_exec_extension_word = decoded_action_q.exec_extension_word;
  assign adapter_action_is_state = decoded_action_q.is_state;
  assign adapter_state_op = decoded_action_q.state_op;
  assign adapter_state_rd = decoded_action_q.state_rd;
  assign adapter_state_rs1 = decoded_action_q.state_rs1;
  assign adapter_state_rs2 = decoded_action_q.state_rs2;
  assign adapter_state_imm = decoded_action_q.state_imm;
  assign adapter_action_is_branch = decoded_action_q.is_branch;
  assign adapter_branch_cond = decoded_action_q.branch_cond;
  assign adapter_branch_rs1 = decoded_action_q.branch_rs1;
  assign adapter_branch_rs2 = decoded_action_q.branch_rs2;
  assign adapter_branch_offset = decoded_action_q.branch_offset;
  assign adapter_memory_op = decoded_action_q.memory_op;
  assign adapter_memory_addr_mode = decoded_action_q.memory_addr_mode;
  assign adapter_memory_addr_space = decoded_action_q.memory_addr_space;
  assign adapter_memory_addr_context = decoded_action_q.memory_addr_context;
  assign adapter_memory_base_eaddr = decoded_action_q.memory_base_eaddr;
  assign adapter_memory_eaddr_offset = decoded_action_q.memory_eaddr_offset;
  assign adapter_memory_vrf_row = decoded_action_q.memory_vrf_row;
  assign adapter_memory_index_vrf_row =
      decoded_action_q.memory_index_vrf_row;
  assign adapter_memory_span_bytes = decoded_action_q.memory_span_bytes;
  assign adapter_action_start_pc = decoded_action_q.start_pc;
  assign adapter_action_is_end = decoded_action_q.is_end;

  // A decode entry is admitted only after every older sequencer/cluster parent
  // action has completed.  This is intentionally conservative: in particular
  // a MEMORY base is sampled only after an older state command has committed.
  // The stage adds a clean timing boundary without creating speculative state
  // or requiring a scoreboard.
  assign decode_action_ready = rst_ni && program_active_q &&
      !decoded_action_valid_q && !state_busy && !branch_cpl_valid_q &&
      !cluster_controller_busy && !branch_redirect_fire;
  assign decode_action_fire = decode_action_valid && adapter_record_ready;
  assign decoded_action_fire = adapter_action_valid && adapter_action_ready;

  assign start_ready_o = rst_ni && !program_active_q && !state_busy &&
      !branch_cpl_valid_q &&
      !cluster_controller_busy && source_start_ready && framer_idle &&
      !framer_clear_q && !action_record_valid_q && !decoded_action_valid_q;
  assign start_fire = start_valid_i && start_ready_o;
  assign source_start_valid = start_valid_i && start_ready_o;
  assign framer_terminal_clear = framer_clear_q;

  assign control_store_write_valid = store_write_valid_i &&
      !EXTERNAL_FETCH_PROVIDER && !program_active_q && !source_running;
  assign store_write_ready_o = control_store_write_ready &&
      !EXTERNAL_FETCH_PROVIDER && !program_active_q && !source_running;

  // The provider choice is an elaboration-time profile, not a live mux.  The
  // inactive boundary is driven to canonical idle values so it cannot create
  // a second request owner or leak X/Z into transport-failure handling.
  assign control_store_req_valid = EXTERNAL_FETCH_PROVIDER ? 1'b0 :
                                     store_req_valid;
  assign control_store_rsp_ready = EXTERNAL_FETCH_PROVIDER ? 1'b1 :
                                     store_rsp_ready;
  assign store_req_ready = EXTERNAL_FETCH_PROVIDER ?
      ifetch_provider_req_ready_i : control_store_req_ready;
  assign store_rsp_valid = EXTERNAL_FETCH_PROVIDER ?
      ifetch_provider_rsp_valid_i : control_store_rsp_valid;
  assign store_rsp_words = EXTERNAL_FETCH_PROVIDER ?
      ifetch_provider_rsp_words_i : control_store_rsp_words;
  assign store_rsp_fault = EXTERNAL_FETCH_PROVIDER ?
      ifetch_provider_rsp_fault_i : control_store_rsp_fault;

  assign ifetch_provider_req_valid_o = EXTERNAL_FETCH_PROVIDER ?
      store_req_valid : 1'b0;
  assign ifetch_provider_req_pc_o = EXTERNAL_FETCH_PROVIDER ?
      store_req_pc : '0;
  assign ifetch_provider_req_word_count_o = EXTERNAL_FETCH_PROVIDER ?
      store_req_word_count : '0;
  assign ifetch_provider_rsp_ready_o = EXTERNAL_FETCH_PROVIDER ?
      store_rsp_ready : 1'b0;
  assign ifetch_redirect_commit_o = branch_redirect_fire;

  // Once END is structurally visible, no younger bundle reaches the framer.
  // A launch whose end_pc extends beyond END is invalid, but the source is
  // allowed to drain its declared range so it reaches its real idle state.
  // Register the transition into source-only draining.  On the detection
  // cycle the source still follows the framer's ready, so a back-to-back
  // response remains stable.  From the next cycle onward it is consumed
  // without being presented to the stopped framer.
  assign framer_bundle_valid = source_bundle_valid &&
                               !source_terminal_drain_q;
  assign source_bundle_ready = source_terminal_drain_q ? 1'b1 :
                                                           framer_bundle_ready;

  always_comb begin
    record_ready = '0;
    // A one-entry registered boundary deliberately breaks ready/payload
    // combinational paths between the framer and the decoded controller.
    // While a state completion is pending, holding slot zero closed preserves
    // global record order and prevents a younger cluster action from passing
    // the sequencer-local engine.
    record_ready[0] = !action_record_valid_q && program_active_q &&
                      !state_busy && !branch_cpl_valid_q &&
                      !branch_redirect_fire;
  end

  assign adapter_end_allowed =
      (action_record_start_pc_q + PC_W'(4)) == program_end_pc_q;
  assign terminal_boundary_error_now = program_active_q &&
      framer_stop_fetch &&
      ((framer_terminal_pc + PC_W'(4)) != program_end_pc_q);
  assign transport_failure_now = source_store_fault ||
      source_protocol_error || framer_protocol_error ||
      control_store_protocol_error;
  // A fetch fault can arrive after complete older records and an incomplete
  // cross-bundle tail are resident.  Preserve and issue every complete record;
  // once none remains visible, abort only the unframeable tail.  An observed
  // END owns the terminal path and is never undone by transport recovery.

  always_comb begin
    group_owner_valid = program_active_q ? program_group_mask_q : '0;
    group_owner = '0;
    for (int group = 0; group < GROUP_COUNT; group++)
      group_owner[(group*CONTEXT_W) +: CONTEXT_W] = program_context_q;
  end

  assign action_cpl_fire = action_cpl_valid_o && action_cpl_ready_i;
  assign program_finish_success = program_active_q && end_retired_q &&
      !terminal_boundary_error_q && !source_running && framer_halted &&
      !cluster_controller_busy && !state_busy && !branch_cpl_valid_q &&
      !action_record_valid_q && !decoded_action_valid_q &&
      !branch_redirect_fire;
  assign program_finish_failure = program_active_q &&
      !cluster_controller_busy && !state_busy && !branch_cpl_valid_q &&
      !source_running &&
      !action_record_valid_q && !decoded_action_valid_q && !record_valid[0] &&
      !branch_redirect_fire &&
      ((terminal_boundary_error_q && framer_halted) ||
       (eof_records_done_q && !end_retired_q) ||
       (transport_failure_q && (framer_idle || framer_halted)));

  assign fetch_pc_o = source_current_pc;
  assign fetch_running_o = source_running;
  assign fetch_stop_o = framer_stop_fetch;
  assign program_active_o = program_active_q;
  assign program_done_o = program_done_q;
  assign program_failed_o = program_failed_q;
  assign program_error_o = program_error_q || terminal_boundary_error_q ||
                           transport_failure_q;
  assign program_halted_o = framer_halted;
  assign program_terminal_pc_o = framer_terminal_pc;
  assign fetch_protocol_error_o = control_store_protocol_error ||
      source_protocol_error || framer_protocol_error || source_store_fault;
  assign cluster_protocol_error_o = cluster_controller_protocol_error ||
      cluster_exec_protocol_error || cluster_mem_protocol_error;
  assign protocol_error_o = fetch_protocol_error_o ||
      cluster_protocol_error_o || state_router_protocol_error_q ||
      terminal_boundary_error_q;
  assign completion_parent_overlap =
      (branch_cpl_valid_q && state_cpl_valid) ||
      (branch_cpl_valid_q && cluster_action_cpl_valid) ||
      (state_cpl_valid && cluster_action_cpl_valid);
  assign active_engine_overlap =
      (branch_cpl_valid_q && state_busy) ||
      (branch_cpl_valid_q && cluster_controller_busy) ||
      (state_busy && cluster_controller_busy);

  // Legal CONTROL-state records and every recognized branch record are
  // intercepted locally.  Malformed state records still use the generic
  // ordered reject path; malformed branches use the local completion so no
  // branch-family record can leak into the cluster controller.  A branch
  // resolves only after every older engine is idle, and its registered
  // completion blocks younger admission until the external handshake.
  assign state_action_selected = adapter_action_valid &&
      adapter_action_is_state && adapter_action_legal;
  assign branch_action_selected = adapter_action_valid &&
      adapter_action_is_branch;
  assign state_cmd_valid = state_action_selected &&
                           !cluster_controller_busy && !branch_cpl_valid_q;
  assign branch_issue_valid = branch_action_selected && !state_busy &&
      !cluster_controller_busy && !branch_cpl_valid_q;
  assign branch_issue_ready = !branch_next_pc_valid || source_redirect_ready;
  assign branch_fire = branch_issue_valid && branch_issue_ready;
  assign branch_redirect_fire = branch_fire && branch_next_pc_valid;
  assign source_redirect_valid = branch_issue_valid && branch_next_pc_valid;
  assign source_redirect_pc = branch_next_pc;
  assign framer_redirect_flush = branch_redirect_fire;
  assign cluster_action_valid = adapter_action_valid &&
      !state_action_selected && !branch_action_selected && !state_busy &&
      !branch_cpl_valid_q;
  always_comb begin
    if (state_action_selected) begin
      adapter_action_ready = !cluster_controller_busy &&
                             !branch_cpl_valid_q && state_cmd_ready;
    end else if (branch_action_selected) begin
      adapter_action_ready = branch_issue_valid && branch_issue_ready;
    end else begin
      adapter_action_ready = !state_busy && !branch_cpl_valid_q &&
                             cluster_action_ready;
    end
  end

  // Branch targets are signed byte displacements relative to the header PC.
  // The widened arithmetic distinguishes a real in-range target from modulo
  // wraparound.  Taken targets must name a word inside the launch range;
  // fall-through may equal end_pc so a missing final END drains normally.
  always_comb begin
    branch_pc_ext = $signed({{(BRANCH_CALC_W-PC_W){1'b0}},
                             adapter_action_start_pc});
    branch_offset_ext =
        $signed({{(BRANCH_CALC_W-32){adapter_branch_offset[31]}},
                 adapter_branch_offset});
    branch_target_ext = branch_pc_ext + branch_offset_ext;
    branch_fallthrough_ext = branch_pc_ext + BRANCH_CALC_W'(8);
    program_start_pc_ext =
        $signed({{(BRANCH_CALC_W-PC_W){1'b0}}, program_start_pc_q});
    program_end_pc_ext =
        $signed({{(BRANCH_CALC_W-PC_W){1'b0}}, program_end_pc_q});

    branch_condition_legal = adapter_action_legal &&
        ((adapter_branch_cond == VSP_BRANCH_COND_J) || control_read_legal);
    branch_taken = 1'b0;
    unique case (adapter_branch_cond)
      VSP_BRANCH_COND_J: branch_taken = 1'b1;
      VSP_BRANCH_COND_BEQ:
        branch_taken = control_read_rs1_data == control_read_rs2_data;
      VSP_BRANCH_COND_BNE:
        branch_taken = control_read_rs1_data != control_read_rs2_data;
      VSP_BRANCH_COND_BLT:
        branch_taken = $signed(control_read_rs1_data) <
                       $signed(control_read_rs2_data);
      VSP_BRANCH_COND_BGE:
        branch_taken = $signed(control_read_rs1_data) >=
                       $signed(control_read_rs2_data);
      VSP_BRANCH_COND_BLTU:
        branch_taken = control_read_rs1_data < control_read_rs2_data;
      VSP_BRANCH_COND_BGEU:
        branch_taken = control_read_rs1_data >= control_read_rs2_data;
      default: branch_taken = 1'b0;
    endcase

    branch_selected_pc_ext = branch_taken ? branch_target_ext :
                                            branch_fallthrough_ext;
    branch_next_pc = branch_selected_pc_ext[PC_W-1:0];
    branch_next_pc_valid = branch_condition_legal &&
        (branch_selected_pc_ext >= program_start_pc_ext) &&
        (branch_selected_pc_ext <= program_end_pc_ext) &&
        (branch_selected_pc_ext[1:0] == 2'b00);
    if (branch_taken)
      branch_next_pc_valid = branch_next_pc_valid &&
                             (branch_selected_pc_ext < program_end_pc_ext);
  end

  assign control_read_valid = branch_action_selected &&
      adapter_action_legal &&
      (adapter_branch_cond != VSP_BRANCH_COND_J);

  // The adapter has already expanded UNIT_STRIDE span code zero into the
  // ordinary byte count selected by the launch mask.  Explicit casts keep
  // the decoded seven-bit profile visibly separate from narrower physical
  // integrations; the 16-group reference profile naturally keeps all seven
  // bits and can carry 64 bytes.
  assign action_memory_addr_context =
      ADDR_CONTEXT_W'(adapter_memory_addr_context);
  assign action_memory_eaddr_offset =
      MEM_OFFSET_W'($signed(adapter_memory_eaddr_offset));
  assign action_memory_vrf_row = VRF_ADDR_W'(adapter_memory_vrf_row);
  assign action_memory_index_vrf_row =
      VRF_ADDR_W'(adapter_memory_index_vrf_row);
  assign action_memory_span_bytes =
      SPAN_BYTES_W'(adapter_memory_span_bytes);

  // Branch, state and cluster completions cannot overlap in the strict path.
  // Deterministic priority keeps payload stable while the assertion below
  // records an integration violation rather than combining parents.
  assign action_cpl_valid_o = branch_cpl_valid_q || state_cpl_valid ||
                              cluster_action_cpl_valid;
  assign branch_cpl_ready = action_cpl_ready_i && branch_cpl_valid_q;
  assign state_cpl_ready = action_cpl_ready_i && !branch_cpl_valid_q &&
                           state_cpl_valid;
  assign cluster_action_cpl_ready = action_cpl_ready_i &&
      !branch_cpl_valid_q && !state_cpl_valid;
  assign action_cpl_class_o = (branch_cpl_valid_q || state_cpl_valid) ?
      VSP_ACTION_CLASS_CONTROL : cluster_action_cpl_class;
  assign action_cpl_context_o = branch_cpl_valid_q ?
      branch_cpl_context_q : (state_cpl_valid ?
      state_cpl_context : cluster_action_cpl_context);
  assign action_cpl_tag_o = branch_cpl_valid_q ? branch_cpl_tag_q :
      (state_cpl_valid ? state_cpl_tag : cluster_action_cpl_tag);
  assign action_cpl_group_mask_o = (branch_cpl_valid_q || state_cpl_valid) ?
      '0 : cluster_action_cpl_group_mask;
  assign action_cpl_status_o = branch_cpl_valid_q ? branch_cpl_status_q :
      (state_cpl_valid ?
       (state_cpl_status == VSP_STATE_CPL_OK ? VSP_ACTION_CPL_OK :
                                              VSP_ACTION_CPL_CONTROL_ERROR) :
       cluster_action_cpl_status);
  assign action_cpl_decode_error_o = branch_cpl_valid_q ?
      branch_cpl_decode_error_q : (state_cpl_valid ?
      '0 : cluster_action_cpl_decode_error);
  assign action_cpl_end_o = (branch_cpl_valid_q || state_cpl_valid) ? 1'b0 :
      cluster_action_cpl_end;
  always_comb begin : p_memory_completion_detail
    action_cpl_memory_op_o = '0;
    action_cpl_memory_status_o = '0;
    action_cpl_memory_fault_cause_o = '0;
    action_cpl_memory_fault_eaddr_o = '0;
    action_cpl_memory_requested_group_mask_o = '0;
    action_cpl_memory_completed_group_mask_o = '0;
    action_cpl_memory_failed_group_mask_o = '0;
    action_cpl_memory_bytes_committed_o = '0;
    action_cpl_memory_partial_o = 1'b0;

    if (action_cpl_valid_o &&
        (action_cpl_class_o == VSP_ACTION_CLASS_MEMORY)) begin
      action_cpl_memory_op_o = cluster_action_cpl_memory_op;
      action_cpl_memory_status_o = cluster_action_cpl_memory_status;
      action_cpl_memory_fault_cause_o =
          cluster_action_cpl_memory_fault_cause;
      action_cpl_memory_fault_eaddr_o =
          cluster_action_cpl_memory_fault_eaddr;
      action_cpl_memory_requested_group_mask_o =
          cluster_action_cpl_memory_requested_group_mask;
      action_cpl_memory_completed_group_mask_o =
          cluster_action_cpl_memory_completed_group_mask;
      action_cpl_memory_failed_group_mask_o =
          cluster_action_cpl_memory_failed_group_mask;
      action_cpl_memory_bytes_committed_o =
          cluster_action_cpl_memory_bytes_committed;
      action_cpl_memory_partial_o = cluster_action_cpl_memory_partial;
    end
  end

  generate
    if (!EXTERNAL_FETCH_PROVIDER) begin : g_internal_control_store
      vsp_uword_control_store #(
        .PC_W(PC_W),
        .STORE_WORDS(STORE_WORDS),
        .STORE_BASE_PC(STORE_BASE_PC),
        .BUNDLE_WORDS(FETCH_WORDS),
        .BUNDLE_COUNT_W(FETCH_COUNT_W)
      ) u_control_store (
        .clk_i,
        .rst_ni,
        .write_valid_i(control_store_write_valid),
        .write_ready_o(control_store_write_ready),
        .write_pc_i(store_write_pc_i),
        .write_data_i(store_write_data_i),
        .req_valid_i(control_store_req_valid),
        .req_ready_o(control_store_req_ready),
        .req_pc_i(store_req_pc),
        .req_word_count_i(store_req_word_count),
        .rsp_valid_o(control_store_rsp_valid),
        .rsp_ready_i(control_store_rsp_ready),
        .rsp_words_o(control_store_rsp_words),
        .rsp_fault_o(control_store_rsp_fault),
        .protocol_error_clear_i,
        .protocol_error_o(control_store_protocol_error)
      );
    end else begin : g_external_control_store_idle
      assign control_store_write_ready = 1'b0;
      assign control_store_req_ready = 1'b0;
      assign control_store_rsp_valid = 1'b0;
      assign control_store_rsp_words = '0;
      assign control_store_rsp_fault = 1'b0;
      assign control_store_protocol_error = 1'b0;

      // Programming pins remain part of the backward-compatible wrapper ABI,
      // but have no architectural effect in the product provider profile.
      /* verilator lint_off UNUSED */
      wire unused_internal_store_boundary = &{1'b0, store_write_pc_i,
          store_write_data_i, control_store_write_valid,
          control_store_req_valid, control_store_rsp_ready};
      /* verilator lint_on UNUSED */
    end
  endgenerate

  vsp_uword_program_source #(
    .PC_W(PC_W),
    .BUNDLE_WORDS(FETCH_WORDS),
    .BUNDLE_COUNT_W(FETCH_COUNT_W)
  ) u_program_source (
    .clk_i,
    .rst_ni,
    .start_valid_i(source_start_valid),
    .start_ready_o(source_start_ready),
    .start_pc_i,
    .end_pc_i,
    .redirect_valid_i(source_redirect_valid),
    .redirect_ready_o(source_redirect_ready),
    .redirect_pc_i(source_redirect_pc),
    .store_req_valid_o(store_req_valid),
    .store_req_ready_i(store_req_ready),
    .store_req_pc_o(store_req_pc),
    .store_req_word_count_o(store_req_word_count),
    .store_rsp_valid_i(store_rsp_valid),
    .store_rsp_ready_o(store_rsp_ready),
    .store_rsp_words_i(store_rsp_words),
    .store_rsp_fault_i(store_rsp_fault),
    .bundle_valid_o(source_bundle_valid),
    .bundle_ready_i(source_bundle_ready),
    .bundle_words_o(source_bundle_words),
    .bundle_word_count_o(source_bundle_word_count),
    .bundle_base_pc_o(source_bundle_base_pc),
    .bundle_last_o(source_bundle_last),
    .current_pc_o(source_current_pc),
    .running_o(source_running),
    .delivery_done_o(source_delivery_done),
    .store_fault_o(source_store_fault),
    .protocol_error_clear_i,
    .protocol_error_o(source_protocol_error)
  );

  vsp_uword_multi_framer #(
    .PC_W(PC_W),
    .BUNDLE_WORDS(FETCH_WORDS),
    .ADMIT_SLOTS(ADMIT_SLOTS),
    .BUNDLE_COUNT_W(FETCH_COUNT_W)
  ) u_multi_framer (
    .clk_i,
    .rst_ni,
    .bundle_valid_i(framer_bundle_valid),
    .bundle_ready_o(framer_bundle_ready),
    .bundle_words_i(source_bundle_words),
    .bundle_word_count_i(source_bundle_word_count),
    .bundle_base_pc_i(source_bundle_base_pc),
    .bundle_last_i(source_bundle_last),
    .record_valid_o(record_valid),
    .record_ready_i(record_ready),
    .record_accept_o(record_accept),
    .record_class_o(record_class),
    .record_major_defined_o(record_major_defined),
    .record_start_pc_o(record_start_pc),
    .record_word_count_o(record_word_count),
    .record_present_word_count_o(record_present_word_count),
    .record_words_o(record_words),
    .record_truncated_o(record_truncated),
    .record_terminal_o(record_terminal),
    .stop_fetch_o(framer_stop_fetch),
    .terminal_pc_o(framer_terminal_pc),
    .terminal_accept_o(framer_terminal_accept),
    .halted_o(framer_halted),
    .terminal_clear_i(framer_terminal_clear),
    .stream_abort_i(framer_stream_abort_q),
    .redirect_flush_i(framer_redirect_flush),
    .record_delivery_done_o(framer_delivery_done),
    .idle_o(framer_idle),
    .protocol_error_clear_i,
    .protocol_error_o(framer_protocol_error)
  );

  vsp_uword_action_adapter #(
    .PC_W(PC_W),
    .GROUP_COUNT(GROUP_COUNT),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .MEM_EADDR_W(MEM_EADDR_W),
    .STATE_REGS(STATE_REGS),
    .VREGS(VREGS),
    .MAX_SPAN_BYTES(
        ((GROUP_COUNT*LANES) < VSP_MEMORY_UWORD_MAX_SPAN_BYTES) ?
            (GROUP_COUNT*LANES) : VSP_MEMORY_UWORD_MAX_SPAN_BYTES),
    .DECODE_ERROR_W(DECODE_ERROR_W),
    .STATE_REG_INDEX_W(STATE_REG_INDEX_W),
    .CONTEXT_W(CONTEXT_W)
  ) u_action_adapter (
    .clk_i,
    .rst_ni,
    .launch_fire_i(start_fire),
    .launch_context_i(start_context_i),
    .launch_group_mask_i(start_group_mask_i),
    .launch_tag_seed_i(start_tag_seed_i),
    .record_valid_i(action_record_valid_q && program_active_q),
    .record_ready_o(adapter_record_ready),
    .record_class_i(action_record_class_q),
    .record_major_defined_i(action_record_major_defined_q),
    .record_start_pc_i(action_record_start_pc_q),
    .record_word_count_i(action_record_word_count_q),
    .record_present_word_count_i(action_record_present_word_count_q),
    .record_words_i(action_record_words_q),
    .record_truncated_i(action_record_truncated_q),
    .record_control_end_allowed_i(adapter_end_allowed),
    .action_valid_o(decode_action_valid),
    .action_ready_i(decode_action_ready),
    .action_class_o(decode_action_class),
    .action_legal_o(decode_action_legal),
    .action_decode_error_o(decode_action_decode_error),
    .action_control_op_o(decode_action_control_op),
    .action_context_o(decode_action_context),
    .action_tag_o(decode_action_tag),
    .action_group_mask_o(decode_action_group_mask),
    .action_exec_base_word_o(decode_exec_base_word),
    .action_exec_extension_valid_o(decode_exec_extension_valid),
    .action_exec_extension_word_o(decode_exec_extension_word),
    .action_is_state_o(decode_action_is_state),
    .action_state_op_o(decode_state_op),
    .action_state_rd_o(decode_state_rd),
    .action_state_rs1_o(decode_state_rs1),
    .action_state_rs2_o(decode_state_rs2),
    .action_state_imm_o(decode_state_imm),
    .action_is_branch_o(decode_action_is_branch),
    .action_branch_cond_o(decode_branch_cond),
    .action_branch_rs1_o(decode_branch_rs1),
    .action_branch_rs2_o(decode_branch_rs2),
    .action_branch_offset_o(decode_branch_offset),
    .memory_base_read_valid_o(adapter_memory_base_read_valid),
    .memory_base_read_reg_o(adapter_memory_base_read_reg),
    .memory_base_read_data_i(adapter_memory_base_read_data),
    .memory_base_read_legal_i(adapter_memory_base_read_legal),
    .action_memory_op_o(decode_memory_op),
    .action_memory_addr_mode_o(decode_memory_addr_mode),
    .action_memory_addr_space_o(decode_memory_addr_space),
    .action_memory_addr_context_o(decode_memory_addr_context),
    .action_memory_base_eaddr_o(decode_memory_base_eaddr),
    .action_memory_eaddr_offset_o(decode_memory_eaddr_offset),
    .action_memory_vrf_row_o(decode_memory_vrf_row),
    .action_memory_index_vrf_row_o(decode_memory_index_vrf_row),
    .action_memory_span_bytes_o(decode_memory_span_bytes),
    .action_start_pc_o(decode_action_start_pc),
    .action_is_control_end_o(decode_action_is_end)
  );

  vsp_sequencer_state_engine #(
    .STATE_W(MEM_EADDR_W),
    .STATE_REGS(STATE_REGS),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .STATE_REG_INDEX_W(STATE_REG_INDEX_W),
    .CONTEXT_ID_W(CONTEXT_W)
  ) u_state_engine (
    .clk_i,
    .rst_ni,
    .cmd_valid_i(state_cmd_valid),
    .cmd_ready_o(state_cmd_ready),
    .cmd_op_i(adapter_state_op),
    .cmd_context_i(adapter_action_context),
    .cmd_tag_i(adapter_action_tag),
    .cmd_rd_i(adapter_state_rd),
    .cmd_rs1_i(adapter_state_rs1),
    .cmd_rs2_i(adapter_state_rs2),
    .cmd_imm_i(MEM_EADDR_W'(adapter_state_imm)),
    .base_read_valid_i(adapter_memory_base_read_valid),
    .base_read_context_i(decode_action_context),
    .base_read_reg_i(STATE_REG_INDEX_W'(adapter_memory_base_read_reg)),
    .base_read_data_o(adapter_memory_base_read_data),
    .base_read_legal_o(adapter_memory_base_read_legal),
    .control_read_valid_i(control_read_valid),
    .control_read_context_i(adapter_action_context),
    .control_read_rs1_i(adapter_branch_rs1),
    .control_read_rs2_i(adapter_branch_rs2),
    .control_read_rs1_data_o(control_read_rs1_data),
    .control_read_rs2_data_o(control_read_rs2_data),
    .control_read_legal_o(control_read_legal),
    .cpl_valid_o(state_cpl_valid),
    .cpl_ready_i(state_cpl_ready),
    .cpl_context_o(state_cpl_context),
    .cpl_tag_o(state_cpl_tag),
    .cpl_status_o(state_cpl_status),
    .busy_o(state_busy)
  );

  /* verilator lint_off PINCONNECTEMPTY */
  vsp_cluster_controller_wrapper #(
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
    .DECODE_ERROR_W(DECODE_ERROR_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W),
    .SPAN_BYTES_W(SPAN_BYTES_W)
  ) u_cluster_controller (
    .clk_i,
    .rst_ni,
    .action_valid_i(cluster_action_valid),
    .action_ready_o(cluster_action_ready),
    .action_class_i(adapter_action_class),
    .action_legal_i(adapter_action_legal),
    .action_decode_error_i(adapter_action_decode_error),
    .action_control_op_i(adapter_action_control_op),
    .action_context_i(adapter_action_context),
    .action_tag_i(adapter_action_tag),
    .action_group_mask_i(adapter_action_group_mask),
    .action_exec_base_word_i(adapter_exec_base_word),
    .action_exec_extension_valid_i(adapter_exec_extension_valid),
    .action_exec_extension_word_i(adapter_exec_extension_word),
    .action_exec_extension_required_diag_o(
        action_exec_extension_required_unused),
    .action_memory_op_i(adapter_memory_op),
    .action_memory_addr_mode_i(adapter_memory_addr_mode),
    .action_memory_addr_space_i(adapter_memory_addr_space),
    .action_memory_addr_context_i(action_memory_addr_context),
    .action_memory_base_eaddr_i(adapter_memory_base_eaddr),
    .action_memory_eaddr_offset_i(action_memory_eaddr_offset),
    .action_memory_vrf_row_i(action_memory_vrf_row),
    .action_memory_index_vrf_row_i(action_memory_index_vrf_row),
    .action_memory_span_bytes_i(action_memory_span_bytes),
    .group_owner_valid_i(group_owner_valid),
    .group_owner_i(group_owner),
    .action_cpl_valid_o(cluster_action_cpl_valid),
    .action_cpl_ready_i(cluster_action_cpl_ready),
    .action_cpl_class_o(cluster_action_cpl_class),
    .action_cpl_context_o(cluster_action_cpl_context),
    .action_cpl_tag_o(cluster_action_cpl_tag),
    .action_cpl_group_mask_o(cluster_action_cpl_group_mask),
    .action_cpl_status_o(cluster_action_cpl_status),
    .action_cpl_decode_error_o(cluster_action_cpl_decode_error),
    .action_cpl_end_o(cluster_action_cpl_end),
    .program_done_o(cluster_raw_program_done),
    .action_cpl_exec_group_mask_o(),
    .action_cpl_exec_result_mask_o(),
    .action_cpl_exec_illegal_o(),
    .action_cpl_exec_illegal_group_mask_o(),
    .action_cpl_exec_rejected_o(),
    .action_cpl_exec_empty_mask_o(),
    .action_cpl_exec_owner_mismatch_o(),
    .action_cpl_memory_op_o(cluster_action_cpl_memory_op),
    .action_cpl_memory_status_o(cluster_action_cpl_memory_status),
    .action_cpl_memory_fault_cause_o(
        cluster_action_cpl_memory_fault_cause),
    .action_cpl_memory_fault_eaddr_o(
        cluster_action_cpl_memory_fault_eaddr),
    .action_cpl_memory_requested_group_mask_o(
        cluster_action_cpl_memory_requested_group_mask),
    .action_cpl_memory_completed_group_mask_o(
        cluster_action_cpl_memory_completed_group_mask),
    .action_cpl_memory_failed_group_mask_o(
        cluster_action_cpl_memory_failed_group_mask),
    .action_cpl_memory_bytes_committed_o(
        cluster_action_cpl_memory_bytes_committed),
    .action_cpl_memory_partial_o(cluster_action_cpl_memory_partial),
    .exec_result_valid_o,
    .exec_result_ready_i,
    .exec_result_group_o,
    .exec_result_context_o,
    .exec_result_tag_o,
    .exec_result_illegal_o,
    .exec_result_has_narrow_o,
    .exec_result_narrow_o,
    .exec_result_narrow_mask_o,
    .exec_result_has_reduce_o,
    .exec_result_reduce_value_o,
    .exec_result_reduce_index_o,
    .exec_result_has_count_o,
    .exec_result_count_o,
    .dmem_req_valid_o,
    .dmem_req_ready_i,
    .dmem_req_op_o,
    .dmem_req_eaddr_o,
    .dmem_req_addr_space_o,
    .dmem_req_addr_context_o,
    .dmem_req_wdata_o,
    .dmem_req_wstrb_o,
    .dmem_rsp_valid_i,
    .dmem_rsp_ready_o,
    .dmem_rsp_rdata_i,
    .dmem_rsp_fault_cause_i,
    .controller_busy_o(cluster_controller_busy),
    .mem_busy_o(cluster_mem_busy),
    .vrf_arbiter_busy_o(cluster_vrf_arbiter_busy),
    .exec_queue_empty_o(cluster_exec_queue_empty),
    .exec_tracker_empty_o(cluster_exec_tracker_empty),
    .exec_quiescent_o(cluster_exec_quiescent),
    .exec_context_children_quiescent_o(cluster_context_quiescent),
    .protocol_error_clear_i,
    .controller_protocol_error_o(cluster_controller_protocol_error),
    .exec_protocol_error_o(cluster_exec_protocol_error),
    .mem_protocol_error_o(cluster_mem_protocol_error),
    .protocol_error_o(cluster_raw_protocol_error_unused)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // Semantic-decode pipeline stage.  MEMORY base_eaddr is captured here from
  // the state-engine query response; branch register values are intentionally
  // not captured, because the branch must compare the latest committed scalar
  // state when it reaches the ordered dispatch point.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      decoded_action_valid_q <= 1'b0;
      decoded_action_q <= '0;
    end else begin
      if (decoded_action_fire)
        decoded_action_valid_q <= 1'b0;

      if (decode_action_fire) begin
        decoded_action_valid_q <= 1'b1;
        decoded_action_q.action_class <= decode_action_class;
        decoded_action_q.action_legal <= decode_action_legal;
        decoded_action_q.decode_error <= decode_action_decode_error;
        decoded_action_q.control_op <= decode_action_control_op;
        decoded_action_q.action_context <= decode_action_context;
        decoded_action_q.tag <= decode_action_tag;
        decoded_action_q.group_mask <= decode_action_group_mask;
        decoded_action_q.exec_base_word <= decode_exec_base_word;
        decoded_action_q.exec_extension_valid <=
            decode_exec_extension_valid;
        decoded_action_q.exec_extension_word <= decode_exec_extension_word;
        decoded_action_q.is_state <= decode_action_is_state;
        decoded_action_q.state_op <= decode_state_op;
        decoded_action_q.state_rd <= decode_state_rd;
        decoded_action_q.state_rs1 <= decode_state_rs1;
        decoded_action_q.state_rs2 <= decode_state_rs2;
        decoded_action_q.state_imm <= decode_state_imm;
        decoded_action_q.is_branch <= decode_action_is_branch;
        decoded_action_q.branch_cond <= decode_branch_cond;
        decoded_action_q.branch_rs1 <= decode_branch_rs1;
        decoded_action_q.branch_rs2 <= decode_branch_rs2;
        decoded_action_q.branch_offset <= decode_branch_offset;
        decoded_action_q.memory_op <= decode_memory_op;
        decoded_action_q.memory_addr_mode <= decode_memory_addr_mode;
        decoded_action_q.memory_addr_space <= decode_memory_addr_space;
        decoded_action_q.memory_addr_context <= decode_memory_addr_context;
        decoded_action_q.memory_base_eaddr <= decode_memory_base_eaddr;
        decoded_action_q.memory_eaddr_offset <= decode_memory_eaddr_offset;
        decoded_action_q.memory_vrf_row <= decode_memory_vrf_row;
        decoded_action_q.memory_index_vrf_row <=
            decode_memory_index_vrf_row;
        decoded_action_q.memory_span_bytes <= decode_memory_span_bytes;
        decoded_action_q.start_pc <= decode_action_start_pc;
        decoded_action_q.is_end <= decode_action_is_end;
      end
    end
  end

  // A branch completion is deliberately registered even though comparison
  // and target selection are combinational.  This makes CONTROL completion
  // obey the same valid/ready stability contract as EXEC, MEMORY and state
  // actions, and prevents a younger record from entering while it is stalled.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      branch_cpl_valid_q <= 1'b0;
      branch_cpl_context_q <= '0;
      branch_cpl_tag_q <= '0;
      branch_cpl_status_q <= VSP_ACTION_CPL_OK;
      branch_cpl_decode_error_q <= '0;
    end else begin
      if (branch_cpl_valid_q && branch_cpl_ready)
        branch_cpl_valid_q <= 1'b0;
      if (branch_fire) begin
        branch_cpl_valid_q <= 1'b1;
        branch_cpl_context_q <= adapter_action_context;
        branch_cpl_tag_q <= adapter_action_tag;
        branch_cpl_status_q <= !adapter_action_legal ?
            VSP_ACTION_CPL_DECODE_ERROR :
            (branch_next_pc_valid ? VSP_ACTION_CPL_OK :
                                    VSP_ACTION_CPL_CONTROL_ERROR);
        branch_cpl_decode_error_q <= adapter_action_legal ?
            '0 : adapter_action_decode_error;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      source_terminal_drain_q <= 1'b0;
      program_context_q <= '0;
      program_group_mask_q <= '0;
      program_start_pc_q <= '0;
      program_end_pc_q <= '0;
      program_active_q <= 1'b0;
      program_done_q <= 1'b0;
      program_failed_q <= 1'b0;
      program_error_q <= 1'b0;
      eof_records_done_q <= 1'b0;
      end_retired_q <= 1'b0;
      terminal_boundary_error_q <= 1'b0;
      transport_failure_q <= 1'b0;
      framer_clear_q <= 1'b0;
      framer_stream_abort_q <= 1'b0;
      action_record_valid_q <= 1'b0;
      action_record_class_q <= '0;
      action_record_major_defined_q <= 1'b0;
      action_record_start_pc_q <= '0;
      action_record_word_count_q <= '0;
      action_record_present_word_count_q <= '0;
      action_record_words_q <= '0;
      action_record_truncated_q <= 1'b0;
      state_router_protocol_error_q <= 1'b0;
    end else begin
      if (protocol_error_clear_i)
        state_router_protocol_error_q <= 1'b0;
      if (completion_parent_overlap || active_engine_overlap)
        state_router_protocol_error_q <= 1'b1;

      if (start_fire || branch_redirect_fire)
        source_terminal_drain_q <= 1'b0;
      else if (framer_stop_fetch)
        source_terminal_drain_q <= 1'b1;
      else if (!program_active_q && framer_idle)
        source_terminal_drain_q <= 1'b0;

      program_done_q <= 1'b0;
      program_failed_q <= 1'b0;
      framer_clear_q <= !program_active_q && framer_halted &&
                        !framer_clear_q;
      framer_stream_abort_q <= 1'b0;
      if (program_active_q &&
          (transport_failure_q || transport_failure_now) &&
          !framer_stop_fetch && !record_valid[0] &&
          !framer_idle && !framer_halted && !framer_stream_abort_q &&
          !branch_redirect_fire)
        framer_stream_abort_q <= 1'b1;

      // A committed redirect invalidates the younger raw record that may have
      // filled behind the decoded branch.  Source and framer flushes cannot
      // reach this explicit boundary, so clear it here with highest priority.
      if (branch_redirect_fire) begin
        action_record_valid_q <= 1'b0;
        action_record_class_q <= '0;
        action_record_major_defined_q <= 1'b0;
        action_record_start_pc_q <= '0;
        action_record_word_count_q <= '0;
        action_record_present_word_count_q <= '0;
        action_record_words_q <= '0;
        action_record_truncated_q <= 1'b0;
      end else if (record_accept[0]) begin
        action_record_valid_q <= 1'b1;
        action_record_class_q <= record_class[0 +: VSP_ACTION_CLASS_W];
        action_record_major_defined_q <= record_major_defined[0];
        action_record_start_pc_q <= record_start_pc[0 +: PC_W];
        action_record_word_count_q <=
            record_word_count[0 +: VSP_UWORD_WORD_COUNT_W];
        action_record_present_word_count_q <=
            record_present_word_count[0 +: VSP_UWORD_WORD_COUNT_W];
        action_record_words_q <=
            record_words[0 +: VSP_UWORD_MAX_RECORD_WORDS*VSP_UWORD_W];
        action_record_truncated_q <= record_truncated[0];
      end else if (decode_action_fire) begin
        action_record_valid_q <= 1'b0;
        action_record_class_q <= '0;
        action_record_major_defined_q <= 1'b0;
        action_record_start_pc_q <= '0;
        action_record_word_count_q <= '0;
        action_record_present_word_count_q <= '0;
        action_record_words_q <= '0;
        action_record_truncated_q <= 1'b0;
      end

      if (protocol_error_clear_i && !program_active_q)
        program_error_q <= 1'b0;

      if (start_fire) begin
        program_context_q <= start_context_i;
        program_group_mask_q <= start_group_mask_i;
        program_start_pc_q <= start_pc_i;
        program_end_pc_q <= end_pc_i;
        program_active_q <= 1'b1;
        program_error_q <= 1'b0;
        eof_records_done_q <= 1'b0;
        end_retired_q <= 1'b0;
        terminal_boundary_error_q <= 1'b0;
        transport_failure_q <= 1'b0;
      end else if (program_active_q) begin
        // An empty [start_pc,end_pc) range produces no bundle for the framer;
        // source delivery is therefore also an EOF event when the framer is
        // already idle.  It closes as a missing-END failure, not a hang.
        if (!branch_redirect_fire &&
            (framer_delivery_done ||
             (source_delivery_done && framer_idle)))
          eof_records_done_q <= 1'b1;
        if (terminal_boundary_error_now && !branch_redirect_fire) begin
          terminal_boundary_error_q <= 1'b1;
        end
        if (transport_failure_now && !branch_redirect_fire) begin
          transport_failure_q <= 1'b1;
        end
        if (branch_redirect_fire) begin
          // EOF, an early END and a fetch fault may all belong to the
          // prefetched sequential path younger than this branch.
          eof_records_done_q <= 1'b0;
          terminal_boundary_error_q <= 1'b0;
          transport_failure_q <= 1'b0;
        end
        if (cluster_protocol_error_o || state_router_protocol_error_q ||
            completion_parent_overlap || active_engine_overlap)
          program_error_q <= 1'b1;
        if (action_cpl_fire &&
            action_cpl_status_o != VSP_ACTION_CPL_OK)
          program_error_q <= 1'b1;
        if (cluster_raw_program_done)
          end_retired_q <= 1'b1;

        if (program_finish_success) begin
          program_active_q <= 1'b0;
          program_done_q <= 1'b1;
        end else if (program_finish_failure) begin
          program_active_q <= 1'b0;
          program_failed_q <= 1'b1;
          program_error_q <= 1'b1;
        end
      end
    end
  end

  initial begin
    if (FETCH_WORDS <= 0)
      $error("FETCH_WORDS must be positive");
    if (ADMIT_SLOTS < 1)
      $error("ADMIT_SLOTS must expose at least the strict slot zero");
    if (PC_W < 3) $error("PC_W must hold byte PCs");
    if (MEM_EADDR_W != 32)
      $error("encoded state/MEMORY profile v0 requires 32-bit eaddr state");
    if (MEM_OFFSET_W != VSP_MEMORY_UWORD_OFFSET_W)
      $error("encoded MEMORY profile v0 requires a signed 16-bit offset");
    if (ADDR_CONTEXT_W != VSP_MEMORY_UWORD_ADDR_CONTEXT_W)
      $error("encoded MEMORY profile v0 requires 8-bit address context");
  end

  /* verilator lint_off UNUSED */
  logic implementation_observability_used;
  assign implementation_observability_used = source_delivery_done ^
      (^record_valid) ^ (^record_accept) ^ (^record_class) ^
      (^record_major_defined) ^ (^record_start_pc) ^
      (^record_word_count) ^ (^record_present_word_count) ^
      (^record_words) ^ (^record_truncated) ^ (^record_terminal) ^
      framer_terminal_accept ^ (^adapter_action_start_pc) ^
      adapter_action_is_end ^ adapter_record_ready ^
      (^program_group_mask_q) ^ cluster_mem_busy ^
      cluster_vrf_arbiter_busy ^ cluster_exec_queue_empty ^
      cluster_exec_tracker_empty ^ cluster_exec_quiescent ^
      (^cluster_context_quiescent) ^
      state_cmd_valid ^ state_cmd_ready ^ state_busy ^
      adapter_memory_base_read_valid ^
      (^adapter_memory_base_read_reg) ^
      action_exec_extension_required_unused ^
      cluster_raw_protocol_error_unused ^ framer_stream_abort_q;
  /* verilator lint_on UNUSED */
endmodule
