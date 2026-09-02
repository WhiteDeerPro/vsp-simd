// SPDX-License-Identifier: MIT

`default_nettype none

// Executable VSP uword core with the production D-side memory composition.
//
// Instruction delivery intentionally remains the current programmable control
// store.  This wrapper closes program MEMORY actions through LSU/MMU, endpoint
// policy, D-cache/local/uncached-device endpoints and the physical fabric.  A
// later I-cache product replaces the control-store provider boundary; it does
// not change this D-side request/response connection.
module vsp_uword_cached_program_wrapper #(
  parameter integer PC_W = 32,
  parameter integer STORE_WORDS = 64,
  parameter logic [PC_W-1:0] STORE_BASE_PC = '0,
  parameter integer FETCH_WORDS = 4,
  parameter integer ADMIT_SLOTS = 3,
  parameter integer GROUP_COUNT = 4,
  parameter integer ISSUE_SLOTS = 1,
  parameter integer QUEUE_DEPTH = 4,
  parameter integer TRACKER_ENTRIES = 4,
  parameter integer LANES = 4,
  parameter integer ELEM_W = 8,
  parameter integer ACC_W = 32,
  parameter integer VREGS = 16,
  parameter integer AREGS = 8,
  parameter integer MREGS = 4,
  parameter integer CONTEXT_COUNT = 1,
  parameter integer TAG_W = 8,
  parameter integer RESOURCE_W = 8,
  parameter integer SIMD4_ID_W = 8,
  parameter logic [SIMD4_ID_W-1:0] SIMD4_BASE_ID = '0,
  parameter integer MEM_OFFSET_W = 16,
  parameter integer STATE_REGS = 32,
  parameter integer DECODE_ERROR_W =
      vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W,
  parameter integer VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter integer CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                                $clog2(CONTEXT_COUNT),
  parameter integer GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 :
                                 $clog2(GROUP_COUNT),
  parameter integer INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter integer OFFSET_W = $clog2(LANES + 1),
  parameter integer SPAN_BYTES_W = ((GROUP_COUNT*LANES) <= 1) ? 1 :
                                   $clog2((GROUP_COUNT*LANES) + 1),

  parameter integer PADDR_W = 40,
  parameter logic TRANSLATION_ENABLE = 1'b1,
  parameter integer MMU_CONTEXT_COUNT = 8,
  parameter integer ASID_W = 9,
  parameter integer I_TLB_ENTRY_COUNT = 8,
  parameter integer D_TLB_ENTRY_COUNT = 16,
  parameter integer TLB_EPOCH_W = 16,
  parameter integer REGION_COUNT = 4,
  parameter integer REGION_INDEX_W =
      (REGION_COUNT <= 1) ? 1 : $clog2(REGION_COUNT),
  parameter logic [REGION_COUNT-1:0] REGION_ENABLE = '0,
  parameter logic [REGION_COUNT*PADDR_W-1:0] REGION_BASE = '0,
  parameter logic [REGION_COUNT*PADDR_W-1:0] REGION_MASK = '0,
  parameter logic [
      REGION_COUNT*vsp_mem_common_pkg::VSP_MEM_ENDPOINT_W-1:0
  ] REGION_ENDPOINT = '0,
  parameter logic [REGION_COUNT-1:0] REGION_READ_OK = '0,
  parameter logic [REGION_COUNT-1:0] REGION_WRITE_OK = '0,
  parameter logic [REGION_COUNT-1:0] REGION_EXECUTE_OK = '0,
  parameter logic [REGION_COUNT-1:0] REGION_IDEMPOTENT = '0,
  parameter integer LOWER_DATA_W = 32,
  parameter integer DCACHE_LINE_BYTES = 32,
  parameter integer DCACHE_SET_COUNT = 64,
  parameter integer DCACHE_WAY_COUNT = 2,
  parameter integer DCACHE_RAM_RD_LATENCY = 1,
  parameter integer CACHE_REQ_ID_W = 1,
  parameter integer CACHE_USER_W = 1,
  parameter integer CACHE_MEM_BEATS_W =
      ((DCACHE_LINE_BYTES / (LOWER_DATA_W / 8)) <= 1) ? 1 :
      $clog2((DCACHE_LINE_BYTES / (LOWER_DATA_W / 8)) + 1),
  parameter logic [PADDR_W-1:0] LOCAL_BASE_ADDR = '0,
  parameter integer LOCAL_DEPTH_WORDS = 1024
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                                      store_write_valid_i,
  output logic                                      store_write_ready_o,
  input  logic [PC_W-1:0]                           store_write_pc_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_W-1:0]    store_write_data_i,

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
  output logic                                      program_done_o,
  output logic                                      program_failed_o,
  output logic                                      program_error_o,
  output logic                                      program_halted_o,
  output logic [PC_W-1:0]                           program_terminal_pc_o,

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
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]         action_cpl_memory_op_o,
  output logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
                                                     action_cpl_memory_status_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     action_cpl_memory_fault_cause_o,
  output logic [31:0]                               action_cpl_memory_fault_eaddr_o,
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

  // Host management ports.  Requests are admitted only while the program is
  // inactive and the complete D-side path is quiescent.  Fixed priority is
  // MMU configuration, TLB invalidate, D-cache maintenance, then fabric drain.
  input  logic                                      mmu_cfg_valid_i,
  output logic                                      mmu_cfg_ready_o,
  input  logic                                      mmu_cfg_write_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0]
                                                     mmu_cfg_context_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_CFG_FIELD_W-1:0]
                                                     mmu_cfg_field_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0]
                                                     mmu_cfg_wdata_i,
  output logic                                      mmu_cfg_rsp_valid_o,
  input  logic                                      mmu_cfg_rsp_ready_i,
  output logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0]
                                                     mmu_cfg_rsp_rdata_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
                                                     mmu_cfg_rsp_status_o,
  input  logic                                      tlb_inv_req_valid_i,
  output logic                                      tlb_inv_req_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_TLB_INV_SCOPE_W-1:0]
                                                     tlb_inv_req_scope_i,
  input  logic [ASID_W-1:0]                         tlb_inv_req_asid_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_VADDR_W-1:0]
                                                     tlb_inv_req_vaddr_i,
  output logic                                      tlb_inv_rsp_valid_o,
  input  logic                                      tlb_inv_rsp_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
                                                     tlb_inv_rsp_status_o,
  input  logic                                      dcache_maint_req_valid_i,
  output logic                                      dcache_maint_req_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_CACHE_MAINT_OP_W-1:0]
                                                     dcache_maint_req_op_i,
  input  logic [PADDR_W-1:0]                        dcache_maint_req_paddr_i,
  output logic                                      dcache_maint_rsp_valid_o,
  input  logic                                      dcache_maint_rsp_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
                                                     dcache_maint_rsp_status_o,
  input  logic                                      fabric_drain_req_i,
  output logic                                      fabric_drain_done_o,
  output logic                                      management_allowed_o,
  output logic                                      management_active_o,

  output logic                                      lower_req_valid_o,
  input  logic                                      lower_req_ready_i,
  output logic                                      lower_req_write_o,
  output logic [PADDR_W-1:0]                        lower_req_paddr_o,
  output logic [LOWER_DATA_W-1:0]                   lower_req_wdata_o,
  output logic [(LOWER_DATA_W/8)-1:0]               lower_req_wstrb_o,
  input  logic                                      lower_rsp_valid_i,
  output logic                                      lower_rsp_ready_o,
  input  logic [LOWER_DATA_W-1:0]                   lower_rsp_rdata_i,
  input  logic [vsp_memory_endpoints_pkg::VSP_LOWER_STATUS_W-1:0]
                                                     lower_rsp_status_i,
  input  logic                                      lower_quiescent_i,

  output logic                                      memory_ready_o,
  output logic                                      memory_quiescent_o,
  output logic                                      memory_busy_o,
  output logic                                      mmu_init_done_o,
  output logic                                      dcache_init_done_o,
  output logic                                      fabric_quarantine_o,
  output logic                                      perf_dcache_read_hit_o,
  output logic                                      perf_dcache_read_miss_o,
  output logic                                      perf_dcache_write_hit_o,
  output logic                                      perf_dcache_write_miss_o,
  // Clears VSP-owned clearable diagnostics.  The imported D-cache adapter's
  // protocol-error flag is reset-only and can keep the aggregate asserted.
  input  logic                                      protocol_error_clear_i,
  output logic                                      fetch_protocol_error_o,
  output logic                                      cluster_protocol_error_o,
  output logic                                      memory_protocol_error_o,
  output logic                                      protocol_error_o
);
  import vsp_mem_common_pkg::*;

  logic program_start_valid;
  logic program_start_ready;
  logic program_protocol_error;
  logic management_request_present;
  logic management_base_allowed;
  logic select_mmu_cfg;
  logic select_tlb_inv;
  logic select_dcache_maint;
  logic select_fabric_drain;

  typedef enum logic [1:0] {
    MGMT_MMU_CFG,
    MGMT_TLB_INV,
    MGMT_DCACHE_MAINT,
    MGMT_FABRIC_DRAIN
  } management_kind_e;

  management_kind_e management_kind_q;
  logic management_active_q;
  logic management_cmd_pending_q;
  logic management_cmd_fire;
  logic management_rsp_fire;
  logic mmu_cfg_write_q;
  logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0] mmu_cfg_context_q;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_FIELD_W-1:0] mmu_cfg_field_q;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0] mmu_cfg_wdata_q;
  logic [VSP_MEM_TLB_INV_SCOPE_W-1:0] tlb_inv_scope_q;
  logic [ASID_W-1:0] tlb_inv_asid_q;
  logic [vsp_mmu_pkg::VSP_MMU_VADDR_W-1:0] tlb_inv_vaddr_q;
  logic [VSP_MEM_CACHE_MAINT_OP_W-1:0] dcache_maint_op_q;
  logic [PADDR_W-1:0] dcache_maint_paddr_q;
  logic raw_mmu_cfg_valid;
  logic raw_tlb_inv_valid;
  logic raw_dcache_maint_valid;
  logic raw_fabric_drain_req;

  logic dmem_req_valid;
  logic dmem_req_ready;
  logic [vsp_pkg::VSP_MEM_OP_W-1:0] dmem_req_op;
  logic [31:0] dmem_req_eaddr;
  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] dmem_req_addr_space;
  logic [7:0] dmem_req_addr_context;
  logic [31:0] dmem_req_wdata;
  logic [3:0] dmem_req_wstrb;
  logic dmem_rsp_valid;
  logic dmem_rsp_ready;
  logic [31:0] dmem_rsp_rdata;
  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0] dmem_rsp_fault;

  logic raw_mmu_cfg_ready;
  logic raw_tlb_inv_ready;
  logic raw_dcache_maint_ready;
  logic raw_fabric_drain_done;

  initial begin : p_profile_guards
    if ((LANES != 4) || (ELEM_W != 8))
      $fatal(1, "vsp_uword_cached_program_wrapper: D-side beat requires 4x8-bit SIMD rows");
    if (CONTEXT_COUNT != 1)
      $fatal(1, "vsp_uword_cached_program_wrapper: executable profile requires one context");
  end

  assign management_request_present = mmu_cfg_valid_i ||
      tlb_inv_req_valid_i || dcache_maint_req_valid_i || fabric_drain_req_i;
  assign management_base_allowed = !management_active_q &&
      !program_active_o && memory_ready_o && memory_quiescent_o;
  assign management_allowed_o = management_base_allowed;
  assign management_active_o = management_active_q;

  assign select_mmu_cfg = management_base_allowed && mmu_cfg_valid_i;
  assign select_tlb_inv = management_base_allowed && !mmu_cfg_valid_i &&
                          tlb_inv_req_valid_i;
  assign select_dcache_maint = management_base_allowed && !mmu_cfg_valid_i &&
      !tlb_inv_req_valid_i && dcache_maint_req_valid_i;
  assign select_fabric_drain = management_base_allowed && !mmu_cfg_valid_i &&
      !tlb_inv_req_valid_i && !dcache_maint_req_valid_i &&
      fabric_drain_req_i;

  // Requests first enter this registered one-entry management lane.  That
  // register breaks ready/quiescent combinational feedback through the MMU
  // and cache adapters and also prevents two management classes from being
  // accepted in the same cycle.
  assign mmu_cfg_ready_o = management_base_allowed;
  assign tlb_inv_req_ready_o = management_base_allowed && !mmu_cfg_valid_i;
  assign dcache_maint_req_ready_o = management_base_allowed &&
      !mmu_cfg_valid_i && !tlb_inv_req_valid_i;
  assign fabric_drain_done_o = management_active_q &&
      (management_kind_q == MGMT_FABRIC_DRAIN) && raw_fabric_drain_done;

  assign raw_mmu_cfg_valid = management_active_q &&
      management_cmd_pending_q && (management_kind_q == MGMT_MMU_CFG);
  assign raw_tlb_inv_valid = management_active_q &&
      management_cmd_pending_q && (management_kind_q == MGMT_TLB_INV);
  assign raw_dcache_maint_valid = management_active_q &&
      management_cmd_pending_q && (management_kind_q == MGMT_DCACHE_MAINT);
  assign raw_fabric_drain_req = management_active_q &&
      (management_kind_q == MGMT_FABRIC_DRAIN);

  always_comb begin : p_management_events
    management_cmd_fire = 1'b0;
    management_rsp_fire = 1'b0;
    case (management_kind_q)
      MGMT_MMU_CFG: begin
        management_cmd_fire = raw_mmu_cfg_valid && raw_mmu_cfg_ready;
        management_rsp_fire = mmu_cfg_rsp_valid_o && mmu_cfg_rsp_ready_i;
      end
      MGMT_TLB_INV: begin
        management_cmd_fire = raw_tlb_inv_valid && raw_tlb_inv_ready;
        management_rsp_fire = tlb_inv_rsp_valid_o && tlb_inv_rsp_ready_i;
      end
      MGMT_DCACHE_MAINT: begin
        management_cmd_fire = raw_dcache_maint_valid &&
                              raw_dcache_maint_ready;
        management_rsp_fire = dcache_maint_rsp_valid_o &&
                              dcache_maint_rsp_ready_i;
      end
      default: begin
        management_cmd_fire = 1'b0;
        management_rsp_fire = raw_fabric_drain_done;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_management_lane
    if (!rst_ni) begin
      management_kind_q <= MGMT_MMU_CFG;
      management_active_q <= 1'b0;
      management_cmd_pending_q <= 1'b0;
      mmu_cfg_write_q <= 1'b0;
      mmu_cfg_context_q <= '0;
      mmu_cfg_field_q <= '0;
      mmu_cfg_wdata_q <= '0;
      tlb_inv_scope_q <= '0;
      tlb_inv_asid_q <= '0;
      tlb_inv_vaddr_q <= '0;
      dcache_maint_op_q <= '0;
      dcache_maint_paddr_q <= '0;
    end else begin
      if (!management_active_q) begin
        if (select_mmu_cfg) begin
          management_kind_q <= MGMT_MMU_CFG;
          management_active_q <= 1'b1;
          management_cmd_pending_q <= 1'b1;
          mmu_cfg_write_q <= mmu_cfg_write_i;
          mmu_cfg_context_q <= mmu_cfg_context_i;
          mmu_cfg_field_q <= mmu_cfg_field_i;
          mmu_cfg_wdata_q <= mmu_cfg_wdata_i;
        end else if (select_tlb_inv) begin
          management_kind_q <= MGMT_TLB_INV;
          management_active_q <= 1'b1;
          management_cmd_pending_q <= 1'b1;
          tlb_inv_scope_q <= tlb_inv_req_scope_i;
          tlb_inv_asid_q <= tlb_inv_req_asid_i;
          tlb_inv_vaddr_q <= tlb_inv_req_vaddr_i;
        end else if (select_dcache_maint) begin
          management_kind_q <= MGMT_DCACHE_MAINT;
          management_active_q <= 1'b1;
          management_cmd_pending_q <= 1'b1;
          dcache_maint_op_q <= dcache_maint_req_op_i;
          dcache_maint_paddr_q <= dcache_maint_req_paddr_i;
        end else if (select_fabric_drain) begin
          management_kind_q <= MGMT_FABRIC_DRAIN;
          management_active_q <= 1'b1;
          management_cmd_pending_q <= 1'b0;
        end
      end else begin
        if (management_cmd_fire)
          management_cmd_pending_q <= 1'b0;
        if (management_rsp_fire) begin
          management_active_q <= 1'b0;
          management_cmd_pending_q <= 1'b0;
        end
      end
    end
  end

  assign start_ready_o = program_start_ready && memory_ready_o &&
                         memory_quiescent_o && !management_active_q &&
                         !management_request_present;
  assign program_start_valid = start_valid_i && memory_ready_o &&
                               memory_quiescent_o && !management_active_q &&
                               !management_request_present;
  assign protocol_error_o = program_protocol_error ||
                            memory_protocol_error_o;

  /* verilator lint_off PINCONNECTEMPTY */
  vsp_uword_cluster_program_wrapper #(
    .PC_W(PC_W),
    .STORE_WORDS(STORE_WORDS),
    .STORE_BASE_PC(STORE_BASE_PC),
    .FETCH_WORDS(FETCH_WORDS),
    .EXTERNAL_FETCH_PROVIDER(1'b0),
    .ADMIT_SLOTS(ADMIT_SLOTS),
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
    .MEM_EADDR_W(32),
    .MEM_OFFSET_W(MEM_OFFSET_W),
    .ADDR_CONTEXT_W(8),
    .STATE_REGS(STATE_REGS),
    .DECODE_ERROR_W(DECODE_ERROR_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W),
    .SPAN_BYTES_W(SPAN_BYTES_W)
  ) u_program (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .store_write_valid_i(store_write_valid_i),
    .store_write_ready_o(store_write_ready_o),
    .store_write_pc_i(store_write_pc_i),
    .store_write_data_i(store_write_data_i),
    .ifetch_provider_req_valid_o(),
    .ifetch_provider_req_ready_i(1'b0),
    .ifetch_provider_req_pc_o(),
    .ifetch_provider_req_word_count_o(),
    .ifetch_provider_rsp_valid_i(1'b0),
    .ifetch_provider_rsp_ready_o(),
    .ifetch_provider_rsp_words_i('0),
    .ifetch_provider_rsp_fault_i(1'b0),
    .ifetch_redirect_commit_o(),
    .start_valid_i(program_start_valid),
    .start_ready_o(program_start_ready),
    .start_pc_i(start_pc_i),
    .end_pc_i(end_pc_i),
    .start_context_i(start_context_i),
    .start_group_mask_i(start_group_mask_i),
    .start_tag_seed_i(start_tag_seed_i),
    .fetch_pc_o(fetch_pc_o),
    .fetch_running_o(fetch_running_o),
    .fetch_stop_o(fetch_stop_o),
    .program_active_o(program_active_o),
    .program_done_o(program_done_o),
    .program_failed_o(program_failed_o),
    .program_error_o(program_error_o),
    .program_halted_o(program_halted_o),
    .program_terminal_pc_o(program_terminal_pc_o),
    .action_cpl_valid_o(action_cpl_valid_o),
    .action_cpl_ready_i(action_cpl_ready_i),
    .action_cpl_class_o(action_cpl_class_o),
    .action_cpl_context_o(action_cpl_context_o),
    .action_cpl_tag_o(action_cpl_tag_o),
    .action_cpl_group_mask_o(action_cpl_group_mask_o),
    .action_cpl_status_o(action_cpl_status_o),
    .action_cpl_decode_error_o(action_cpl_decode_error_o),
    .action_cpl_end_o(action_cpl_end_o),
    .action_cpl_memory_op_o(action_cpl_memory_op_o),
    .action_cpl_memory_status_o(action_cpl_memory_status_o),
    .action_cpl_memory_fault_cause_o(action_cpl_memory_fault_cause_o),
    .action_cpl_memory_fault_eaddr_o(action_cpl_memory_fault_eaddr_o),
    .action_cpl_memory_requested_group_mask_o(
        action_cpl_memory_requested_group_mask_o),
    .action_cpl_memory_completed_group_mask_o(
        action_cpl_memory_completed_group_mask_o),
    .action_cpl_memory_failed_group_mask_o(
        action_cpl_memory_failed_group_mask_o),
    .action_cpl_memory_bytes_committed_o(
        action_cpl_memory_bytes_committed_o),
    .action_cpl_memory_partial_o(action_cpl_memory_partial_o),
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
    .dmem_req_valid_o(dmem_req_valid),
    .dmem_req_ready_i(dmem_req_ready),
    .dmem_req_op_o(dmem_req_op),
    .dmem_req_eaddr_o(dmem_req_eaddr),
    .dmem_req_addr_space_o(dmem_req_addr_space),
    .dmem_req_addr_context_o(dmem_req_addr_context),
    .dmem_req_wdata_o(dmem_req_wdata),
    .dmem_req_wstrb_o(dmem_req_wstrb),
    .dmem_rsp_valid_i(dmem_rsp_valid),
    .dmem_rsp_ready_o(dmem_rsp_ready),
    .dmem_rsp_rdata_i(dmem_rsp_rdata),
    .dmem_rsp_fault_cause_i(dmem_rsp_fault),
    .protocol_error_clear_i(protocol_error_clear_i),
    .fetch_protocol_error_o(fetch_protocol_error_o),
    .cluster_protocol_error_o(cluster_protocol_error_o),
    .protocol_error_o(program_protocol_error)
  );

  vsp_dmem_cached_fabric_wrapper #(
    .PADDR_W(PADDR_W),
    .TRANSLATION_ENABLE(TRANSLATION_ENABLE),
    .MMU_CONTEXT_COUNT(MMU_CONTEXT_COUNT),
    .ASID_W(ASID_W),
    .I_TLB_ENTRY_COUNT(I_TLB_ENTRY_COUNT),
    .D_TLB_ENTRY_COUNT(D_TLB_ENTRY_COUNT),
    .TLB_EPOCH_W(TLB_EPOCH_W),
    .REGION_COUNT(REGION_COUNT),
    .REGION_INDEX_W(REGION_INDEX_W),
    .REGION_ENABLE(REGION_ENABLE),
    .REGION_BASE(REGION_BASE),
    .REGION_MASK(REGION_MASK),
    .REGION_ENDPOINT(REGION_ENDPOINT),
    .REGION_READ_OK(REGION_READ_OK),
    .REGION_WRITE_OK(REGION_WRITE_OK),
    .REGION_EXECUTE_OK(REGION_EXECUTE_OK),
    .REGION_IDEMPOTENT(REGION_IDEMPOTENT),
    .LOWER_DATA_W(LOWER_DATA_W),
    .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),
    .DCACHE_SET_COUNT(DCACHE_SET_COUNT),
    .DCACHE_WAY_COUNT(DCACHE_WAY_COUNT),
    .DCACHE_RAM_RD_LATENCY(DCACHE_RAM_RD_LATENCY),
    .CACHE_REQ_ID_W(CACHE_REQ_ID_W),
    .CACHE_USER_W(CACHE_USER_W),
    .CACHE_MEM_BEATS_W(CACHE_MEM_BEATS_W),
    .LOCAL_BASE_ADDR(LOCAL_BASE_ADDR),
    .LOCAL_DEPTH_WORDS(LOCAL_DEPTH_WORDS)
  ) u_memory (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .dmem_req_valid_i(dmem_req_valid),
    .dmem_req_ready_o(dmem_req_ready),
    .dmem_req_op_i(dmem_req_op),
    .dmem_req_eaddr_i(dmem_req_eaddr),
    .dmem_req_addr_space_i(dmem_req_addr_space),
    .dmem_req_addr_context_i(dmem_req_addr_context),
    .dmem_req_wdata_i(dmem_req_wdata),
    .dmem_req_wstrb_i(dmem_req_wstrb),
    .dmem_rsp_valid_o(dmem_rsp_valid),
    .dmem_rsp_ready_i(dmem_rsp_ready),
    .dmem_rsp_rdata_o(dmem_rsp_rdata),
    .dmem_rsp_fault_cause_o(dmem_rsp_fault),
    .i_tr_req_valid_i(1'b0),
    .i_tr_req_ready_o(),
    .i_tr_req_vaddr_i('0),
    .i_tr_req_addr_context_i('0),
    .i_tr_req_access_i(VSP_MEM_ACCESS_FETCH),
    .i_tr_rsp_valid_o(),
    .i_tr_rsp_ready_i(1'b1),
    .i_tr_rsp_paddr_o(),
    .i_tr_rsp_fault_o(),
    .i_tr_rsp_fault_vaddr_o(),
    .mmu_cfg_valid_i(raw_mmu_cfg_valid),
    .mmu_cfg_ready_o(raw_mmu_cfg_ready),
    .mmu_cfg_write_i(mmu_cfg_write_q),
    .mmu_cfg_context_i(mmu_cfg_context_q),
    .mmu_cfg_field_i(mmu_cfg_field_q),
    .mmu_cfg_wdata_i(mmu_cfg_wdata_q),
    .mmu_cfg_rsp_valid_o(mmu_cfg_rsp_valid_o),
    .mmu_cfg_rsp_ready_i(mmu_cfg_rsp_ready_i),
    .mmu_cfg_rsp_rdata_o(mmu_cfg_rsp_rdata_o),
    .mmu_cfg_rsp_status_o(mmu_cfg_rsp_status_o),
    .tlb_inv_req_valid_i(raw_tlb_inv_valid),
    .tlb_inv_req_ready_o(raw_tlb_inv_ready),
    .tlb_inv_req_scope_i(tlb_inv_scope_q),
    .tlb_inv_req_asid_i(tlb_inv_asid_q),
    .tlb_inv_req_vaddr_i(tlb_inv_vaddr_q),
    .tlb_inv_rsp_valid_o(tlb_inv_rsp_valid_o),
    .tlb_inv_rsp_ready_i(tlb_inv_rsp_ready_i),
    .tlb_inv_rsp_status_o(tlb_inv_rsp_status_o),
    .dcache_maint_req_valid_i(raw_dcache_maint_valid),
    .dcache_maint_req_ready_o(raw_dcache_maint_ready),
    .dcache_maint_req_op_i(dcache_maint_op_q),
    .dcache_maint_req_paddr_i(dcache_maint_paddr_q),
    .dcache_maint_rsp_valid_o(dcache_maint_rsp_valid_o),
    .dcache_maint_rsp_ready_i(dcache_maint_rsp_ready_i),
    .dcache_maint_rsp_status_o(dcache_maint_rsp_status_o),
    .barrier_valid_i(1'b0),
    .barrier_ready_o(),
    .barrier_op_i('0),
    .barrier_eaddr_i('0),
    .barrier_context_i('0),
    .barrier_rsp_valid_o(),
    .barrier_rsp_ready_i(1'b1),
    .barrier_rsp_status_o(),
    .policy_maint_req_valid_o(),
    .policy_maint_req_ready_i(1'b0),
    .policy_maint_req_op_o(),
    .policy_maint_req_eaddr_o(),
    .policy_maint_req_context_o(),
    .policy_maint_rsp_valid_i(1'b0),
    .policy_maint_rsp_ready_o(),
    .policy_maint_rsp_fault_i(VSP_MEM_FAULT_NONE),
    .ic_mem_cmd_valid_i(1'b0),
    .ic_mem_cmd_ready_o(),
    .ic_mem_cmd_id_i('0),
    .ic_mem_cmd_op_i(cache_pkg::CACHE_MEM_REFILL),
    .ic_mem_cmd_paddr_i('0),
    .ic_mem_cmd_beats_i('0),
    .ic_mem_w_valid_i(1'b0),
    .ic_mem_w_ready_o(),
    .ic_mem_w_id_i('0),
    .ic_mem_w_data_i('0),
    .ic_mem_wstrb_i('0),
    .ic_mem_w_last_i(1'b0),
    .ic_mem_r_valid_o(),
    .ic_mem_r_ready_i(1'b1),
    .ic_mem_r_id_o(),
    .ic_mem_r_data_o(),
    .ic_mem_r_last_o(),
    .ic_mem_r_status_o(),
    .ic_mem_r_fault_paddr_o(),
    .ic_mem_b_valid_o(),
    .ic_mem_b_ready_i(1'b1),
    .ic_mem_b_id_o(),
    .ic_mem_b_status_o(),
    .ic_mem_b_fault_paddr_o(),
    .fabric_drain_req_i(raw_fabric_drain_req),
    .fabric_drain_done_o(raw_fabric_drain_done),
    .lower_req_valid_o(lower_req_valid_o),
    .lower_req_ready_i(lower_req_ready_i),
    .lower_req_write_o(lower_req_write_o),
    .lower_req_paddr_o(lower_req_paddr_o),
    .lower_req_wdata_o(lower_req_wdata_o),
    .lower_req_wstrb_o(lower_req_wstrb_o),
    .lower_rsp_valid_i(lower_rsp_valid_i),
    .lower_rsp_ready_o(lower_rsp_ready_o),
    .lower_rsp_rdata_i(lower_rsp_rdata_i),
    .lower_rsp_status_i(lower_rsp_status_i),
    .lower_quiescent_i(lower_quiescent_i),
    .lsu_idle_o(),
    .lsu_busy_o(),
    .space_router_idle_o(),
    .region_router_idle_o(),
    .region_config_overlap_o(),
    .region_diag_rsp_valid_o(),
    .region_diag_match_valid_o(),
    .region_diag_match_index_o(),
    .region_diag_overlap_o(),
    .region_diag_endpoint_valid_o(),
    .region_diag_endpoint_o(),
    .region_diag_fault_o(),
    .mmu_init_done_o(mmu_init_done_o),
    .mmu_quiescent_o(),
    .mmu_busy_o(),
    .i_tlb_epoch_o(),
    .d_tlb_epoch_o(),
    .i_tlb_epoch_exhausted_o(),
    .d_tlb_epoch_exhausted_o(),
    .ptw_pte_fault_paddr_valid_o(),
    .ptw_pte_fault_paddr_o(),
    .dcache_init_busy_o(),
    .dcache_init_done_o(dcache_init_done_o),
    .dcache_idle_o(),
    .local_idle_o(),
    .uncached_device_idle_o(),
    .fabric_idle_o(),
    .fabric_busy_o(),
    .fabric_quarantine_o(fabric_quarantine_o),
    .fabric_owner_valid_o(),
    .fabric_owner_o(),
    .dmem_path_ready_o(memory_ready_o),
    .dmem_path_quiescent_o(memory_quiescent_o),
    .dmem_path_busy_o(memory_busy_o),
    .perf_dcache_read_hit_o(perf_dcache_read_hit_o),
    .perf_dcache_read_miss_o(perf_dcache_read_miss_o),
    .perf_dcache_write_hit_o(perf_dcache_write_hit_o),
    .perf_dcache_write_miss_o(perf_dcache_write_miss_o),
    .protocol_error_clear_i(protocol_error_clear_i),
    .lsu_protocol_error_o(),
    .mmu_protocol_error_o(),
    .dcache_protocol_error_o(),
    .endpoint_merge_protocol_error_o(),
    .fabric_protocol_error_o(),
    .protocol_error_o(memory_protocol_error_o)
  );
  /* verilator lint_on PINCONNECTEMPTY */

endmodule

`default_nettype wire
