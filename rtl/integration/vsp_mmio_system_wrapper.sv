// SPDX-License-Identifier: MIT

`default_nettype none

// MMIO-controlled executable VSP with one shared ordered lower-memory port.
// All launch, MMU programming and maintenance requests originate from the
// register target. Vector results intended for software use program STOREs.
// The inherited memory-system and host-control guards define the supported
// single-context PC32/SIMD4x8 profile; parameters retain their original bounds.
module vsp_mmio_system_wrapper #(
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
  parameter integer ICACHE_FRONT_DATA_W = 128,
  parameter integer ICACHE_LINE_BYTES = 32,
  parameter integer ICACHE_SET_COUNT = 64,
  parameter integer ICACHE_WAY_COUNT = 2,
  parameter integer ICACHE_RAM_RD_LATENCY = 1,
  parameter integer CACHE_REQ_ID_W = 1,
  parameter integer CACHE_USER_W = 1,
  parameter integer CACHE_MEM_BEATS_W =
      ((((DCACHE_LINE_BYTES > ICACHE_LINE_BYTES) ? DCACHE_LINE_BYTES :
          ICACHE_LINE_BYTES) / (LOWER_DATA_W / 8)) <= 1) ? 1 :
      $clog2((((DCACHE_LINE_BYTES > ICACHE_LINE_BYTES) ?
               DCACHE_LINE_BYTES : ICACHE_LINE_BYTES) /
              (LOWER_DATA_W / 8)) + 1),
  parameter logic [PADDR_W-1:0] LOCAL_BASE_ADDR = '0,
  parameter integer LOCAL_DEPTH_WORDS = 1024
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Passive device-register target; addresses are 4 KiB aperture offsets.
  input  logic mmio_req_valid_i,
  output logic mmio_req_ready_o,
  input  logic mmio_req_write_i,
  input  logic [11:0] mmio_req_addr_i,
  input  logic [31:0] mmio_req_wdata_i,
  input  logic [3:0] mmio_req_wstrb_i,
  output logic mmio_rsp_valid_o,
  input  logic mmio_rsp_ready_i,
  output logic [31:0] mmio_rsp_rdata_o,
  output logic mmio_rsp_error_o,
  output logic irq_o,

  // Active ordered lower-memory port shared by instruction, data and PTW.
  output logic lower_req_valid_o,
  input  logic lower_req_ready_i,
  output logic lower_req_write_o,
  output logic [PADDR_W-1:0] lower_req_paddr_o,
  output logic [LOWER_DATA_W-1:0] lower_req_wdata_o,
  output logic [(LOWER_DATA_W/8)-1:0] lower_req_wstrb_o,
  input  logic lower_rsp_valid_i,
  output logic lower_rsp_ready_o,
  input  logic [LOWER_DATA_W-1:0] lower_rsp_rdata_i,
  input  logic [vsp_memory_endpoints_pkg::VSP_LOWER_STATUS_W-1:0] lower_rsp_status_i,
  input  logic lower_quiescent_i,

  // Raw memory-system diagnostics; host ownership is reported by MMIO STATUS.
  output logic system_ready_o,
  output logic system_quiescent_o,
  output logic system_busy_o
);
  // The host controller is the sole launch and management owner.
  logic start_valid;
  logic start_ready;
  logic [PC_W-1:0] start_pc;
  logic [PC_W-1:0] end_pc;
  logic [GROUP_COUNT-1:0] start_group_mask;
  logic [TAG_W-1:0] start_tag_seed;
  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0] start_ifetch_addr_space;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0] start_ifetch_addr_context;
  logic [PC_W-1:0] fetch_pc;
  logic program_active;
  logic program_done;
  logic program_failed;
  logic program_error;
  logic [PC_W-1:0] program_terminal_pc;

  // Preserve raw redirect-aware IFetch diagnostics until the host publishes.
  logic ifetch_fault_valid;
  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0] ifetch_fault_cause;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_EADDR_W-1:0] ifetch_fault_eaddr;
  logic [PADDR_W-1:0] ifetch_fault_paddr;
  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0] ifetch_fault_addr_space;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0] ifetch_fault_addr_context;

  // Software-visible completion metadata and automatic drain handshakes.
  logic action_cpl_valid;
  logic action_cpl_ready;
  logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0] action_cpl_class;
  logic [TAG_W-1:0] action_cpl_tag;
  logic [vsp_action_pkg::VSP_ACTION_CPL_STATUS_W-1:0] action_cpl_status;
  logic [DECODE_ERROR_W-1:0] action_cpl_decode_error;
  logic [vsp_pkg::VSP_MEM_OP_W-1:0] action_cpl_memory_op;
  logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0] action_cpl_memory_status;
  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0] action_cpl_memory_fault_cause;
  logic [31:0] action_cpl_memory_fault_eaddr;
  logic [GROUP_COUNT-1:0] action_cpl_memory_requested_group_mask;
  logic [GROUP_COUNT-1:0] action_cpl_memory_completed_group_mask;
  logic [GROUP_COUNT-1:0] action_cpl_memory_failed_group_mask;
  logic [SPAN_BYTES_W-1:0] action_cpl_memory_bytes_committed;
  logic action_cpl_memory_partial;
  logic exec_result_ready;

  logic mmu_cfg_valid;
  logic mmu_cfg_ready;
  logic mmu_cfg_write;
  logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0] mmu_cfg_context;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_FIELD_W-1:0] mmu_cfg_field;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0] mmu_cfg_wdata;
  logic mmu_cfg_rsp_valid;
  logic mmu_cfg_rsp_ready;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0] mmu_cfg_rsp_rdata;
  logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0] mmu_cfg_rsp_status;

  logic maint_cmd_valid;
  logic maint_cmd_ready;
  logic [vsp_mem_common_pkg::VSP_MEM_MAINT_OP_W-1:0] maint_cmd_op;
  logic [31:0] maint_cmd_eaddr;
  logic [PADDR_W-1:0] maint_cmd_paddr;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0] maint_cmd_addr_context;
  logic [ASID_W-1:0] maint_cmd_asid;
  logic maint_cpl_valid;
  logic maint_cpl_ready;
  logic [vsp_mem_common_pkg::VSP_MEM_MAINT_CPL_STATUS_W-1:0] maint_cpl_status;
  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0] maint_cpl_fault;
  logic protocol_error_clear;

  vsp_host_control #(
    .GROUP_COUNT(GROUP_COUNT),
    .PADDR_W(PADDR_W),
    .TAG_W(TAG_W),
    .ASID_W(ASID_W),
    .DECODE_ERROR_W(DECODE_ERROR_W),
    .SPAN_BYTES_W(SPAN_BYTES_W)
  ) u_host_control (
    .clk_i,
    .rst_ni,
    .mmio_req_valid_i,
    .mmio_req_ready_o,
    .mmio_req_write_i,
    .mmio_req_addr_i,
    .mmio_req_wdata_i,
    .mmio_req_wstrb_i,
    .mmio_rsp_valid_o,
    .mmio_rsp_ready_i,
    .mmio_rsp_rdata_o,
    .mmio_rsp_error_o,
    .irq_o,
    .start_valid_o(start_valid),
    .start_ready_i(start_ready),
    .start_pc_o(start_pc),
    .end_pc_o(end_pc),
    .start_group_mask_o(start_group_mask),
    .start_tag_seed_o(start_tag_seed),
    .start_ifetch_addr_space_o(start_ifetch_addr_space),
    .start_ifetch_addr_context_o(start_ifetch_addr_context),
    .fetch_pc_i(fetch_pc),
    .program_active_i(program_active),
    .program_done_i(program_done),
    .program_failed_i(program_failed),
    .program_error_i(program_error),
    .program_terminal_pc_i(program_terminal_pc),
    .system_ready_i(system_ready_o),
    .system_quiescent_i(system_quiescent_o),
    .system_busy_i(system_busy_o),
    .ifetch_fault_valid_i(ifetch_fault_valid),
    .ifetch_fault_cause_i(ifetch_fault_cause),
    .ifetch_fault_eaddr_i(ifetch_fault_eaddr),
    .ifetch_fault_paddr_i(ifetch_fault_paddr),
    .ifetch_fault_addr_space_i(ifetch_fault_addr_space),
    .ifetch_fault_addr_context_i(ifetch_fault_addr_context),
    .action_cpl_valid_i(action_cpl_valid),
    .action_cpl_ready_o(action_cpl_ready),
    .action_cpl_class_i(action_cpl_class),
    .action_cpl_tag_i(action_cpl_tag),
    .action_cpl_status_i(action_cpl_status),
    .action_cpl_decode_error_i(action_cpl_decode_error),
    .action_cpl_memory_op_i(action_cpl_memory_op),
    .action_cpl_memory_status_i(action_cpl_memory_status),
    .action_cpl_memory_fault_cause_i(action_cpl_memory_fault_cause),
    .action_cpl_memory_fault_eaddr_i(action_cpl_memory_fault_eaddr),
    .action_cpl_memory_requested_group_mask_i(action_cpl_memory_requested_group_mask),
    .action_cpl_memory_completed_group_mask_i(action_cpl_memory_completed_group_mask),
    .action_cpl_memory_failed_group_mask_i(action_cpl_memory_failed_group_mask),
    .action_cpl_memory_bytes_committed_i(action_cpl_memory_bytes_committed),
    .action_cpl_memory_partial_i(action_cpl_memory_partial),
    .exec_result_ready_o(exec_result_ready),
    .mmu_cfg_valid_o(mmu_cfg_valid),
    .mmu_cfg_ready_i(mmu_cfg_ready),
    .mmu_cfg_write_o(mmu_cfg_write),
    .mmu_cfg_context_o(mmu_cfg_context),
    .mmu_cfg_field_o(mmu_cfg_field),
    .mmu_cfg_wdata_o(mmu_cfg_wdata),
    .mmu_cfg_rsp_valid_i(mmu_cfg_rsp_valid),
    .mmu_cfg_rsp_ready_o(mmu_cfg_rsp_ready),
    .mmu_cfg_rsp_rdata_i(mmu_cfg_rsp_rdata),
    .mmu_cfg_rsp_status_i(mmu_cfg_rsp_status),
    .maint_cmd_valid_o(maint_cmd_valid),
    .maint_cmd_ready_i(maint_cmd_ready),
    .maint_cmd_op_o(maint_cmd_op),
    .maint_cmd_eaddr_o(maint_cmd_eaddr),
    .maint_cmd_paddr_o(maint_cmd_paddr),
    .maint_cmd_addr_context_o(maint_cmd_addr_context),
    .maint_cmd_asid_o(maint_cmd_asid),
    .maint_cpl_valid_i(maint_cpl_valid),
    .maint_cpl_ready_o(maint_cpl_ready),
    .maint_cpl_status_i(maint_cpl_status),
    .maint_cpl_fault_i(maint_cpl_fault),
    .protocol_error_clear_o(protocol_error_clear)
  );

  // The controller drains every action and EXEC result. EXEC observations,
  // action context/group/end fields and detailed performance diagnostics have
  // no additional consumer in this product profile.
  /* verilator lint_off PINCONNECTEMPTY */
  vsp_uword_memory_system_wrapper #(
    .PC_W(PC_W),
    .STORE_WORDS(STORE_WORDS),
    .STORE_BASE_PC(STORE_BASE_PC),
    .FETCH_WORDS(FETCH_WORDS),
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
    .MEM_OFFSET_W(MEM_OFFSET_W),
    .STATE_REGS(STATE_REGS),
    .DECODE_ERROR_W(DECODE_ERROR_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W),
    .SPAN_BYTES_W(SPAN_BYTES_W),
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
    .ICACHE_FRONT_DATA_W(ICACHE_FRONT_DATA_W),
    .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES),
    .ICACHE_SET_COUNT(ICACHE_SET_COUNT),
    .ICACHE_WAY_COUNT(ICACHE_WAY_COUNT),
    .ICACHE_RAM_RD_LATENCY(ICACHE_RAM_RD_LATENCY),
    .CACHE_REQ_ID_W(CACHE_REQ_ID_W),
    .CACHE_USER_W(CACHE_USER_W),
    .CACHE_MEM_BEATS_W(CACHE_MEM_BEATS_W),
    .LOCAL_BASE_ADDR(LOCAL_BASE_ADDR),
    .LOCAL_DEPTH_WORDS(LOCAL_DEPTH_WORDS)
  ) u_memory_system (
    .clk_i,
    .rst_ni,
    .start_valid_i(start_valid),
    .start_ready_o(start_ready),
    .start_pc_i(start_pc),
    .end_pc_i(end_pc),
    .start_context_i('0),
    .start_group_mask_i(start_group_mask),
    .start_tag_seed_i(start_tag_seed),
    .start_ifetch_addr_space_i(start_ifetch_addr_space),
    .start_ifetch_addr_context_i(start_ifetch_addr_context),
    .fetch_pc_o(fetch_pc),
    .fetch_running_o(),
    .fetch_stop_o(),
    .program_active_o(program_active),
    .program_done_o(program_done),
    .program_failed_o(program_failed),
    .program_error_o(program_error),
    .program_halted_o(),
    .program_terminal_pc_o(program_terminal_pc),
    .ifetch_fault_valid_o(ifetch_fault_valid),
    .ifetch_fault_cause_o(ifetch_fault_cause),
    .ifetch_fault_eaddr_o(ifetch_fault_eaddr),
    .ifetch_fault_paddr_o(ifetch_fault_paddr),
    .ifetch_fault_addr_space_o(ifetch_fault_addr_space),
    .ifetch_fault_addr_context_o(ifetch_fault_addr_context),
    .action_cpl_valid_o(action_cpl_valid),
    .action_cpl_ready_i(action_cpl_ready),
    .action_cpl_class_o(action_cpl_class),
    .action_cpl_context_o(),
    .action_cpl_tag_o(action_cpl_tag),
    .action_cpl_group_mask_o(),
    .action_cpl_status_o(action_cpl_status),
    .action_cpl_decode_error_o(action_cpl_decode_error),
    .action_cpl_end_o(),
    .action_cpl_memory_op_o(action_cpl_memory_op),
    .action_cpl_memory_status_o(action_cpl_memory_status),
    .action_cpl_memory_fault_cause_o(action_cpl_memory_fault_cause),
    .action_cpl_memory_fault_eaddr_o(action_cpl_memory_fault_eaddr),
    .action_cpl_memory_requested_group_mask_o(action_cpl_memory_requested_group_mask),
    .action_cpl_memory_completed_group_mask_o(action_cpl_memory_completed_group_mask),
    .action_cpl_memory_failed_group_mask_o(action_cpl_memory_failed_group_mask),
    .action_cpl_memory_bytes_committed_o(action_cpl_memory_bytes_committed),
    .action_cpl_memory_partial_o(action_cpl_memory_partial),
    .exec_result_valid_o(),
    .exec_result_ready_i(exec_result_ready),
    .exec_result_group_o(),
    .exec_result_context_o(),
    .exec_result_tag_o(),
    .exec_result_illegal_o(),
    .exec_result_has_narrow_o(),
    .exec_result_narrow_o(),
    .exec_result_narrow_mask_o(),
    .exec_result_has_reduce_o(),
    .exec_result_reduce_value_o(),
    .exec_result_reduce_index_o(),
    .exec_result_has_count_o(),
    .exec_result_count_o(),
    .mmu_cfg_valid_i(mmu_cfg_valid),
    .mmu_cfg_ready_o(mmu_cfg_ready),
    .mmu_cfg_write_i(mmu_cfg_write),
    .mmu_cfg_context_i(mmu_cfg_context),
    .mmu_cfg_field_i(mmu_cfg_field),
    .mmu_cfg_wdata_i(mmu_cfg_wdata),
    .mmu_cfg_rsp_valid_o(mmu_cfg_rsp_valid),
    .mmu_cfg_rsp_ready_i(mmu_cfg_rsp_ready),
    .mmu_cfg_rsp_rdata_o(mmu_cfg_rsp_rdata),
    .mmu_cfg_rsp_status_o(mmu_cfg_rsp_status),
    .maint_cmd_valid_i(maint_cmd_valid),
    .maint_cmd_ready_o(maint_cmd_ready),
    .maint_cmd_op_i(maint_cmd_op),
    .maint_cmd_eaddr_i(maint_cmd_eaddr),
    .maint_cmd_paddr_i(maint_cmd_paddr),
    .maint_cmd_addr_context_i(maint_cmd_addr_context),
    .maint_cmd_asid_i(maint_cmd_asid),
    .maint_cpl_valid_o(maint_cpl_valid),
    .maint_cpl_ready_i(maint_cpl_ready),
    .maint_cpl_status_o(maint_cpl_status),
    .maint_cpl_fault_o(maint_cpl_fault),
    .maint_busy_o(),
    .maint_quiescent_o(),
    .maint_current_step_o(),
    .lower_req_valid_o,
    .lower_req_ready_i,
    .lower_req_write_o,
    .lower_req_paddr_o,
    .lower_req_wdata_o,
    .lower_req_wstrb_o,
    .lower_rsp_valid_i,
    .lower_rsp_ready_o,
    .lower_rsp_rdata_i,
    .lower_rsp_status_i,
    .lower_quiescent_i,
    .system_ready_o,
    .system_quiescent_o,
    .system_busy_o,
    .dmem_path_ready_o(),
    .ifetch_path_ready_o(),
    .mmu_init_done_o(),
    .dcache_init_done_o(),
    .icache_init_done_o(),
    .fabric_quarantine_o(),
    .i_region_config_overlap_o(),
    .d_region_config_overlap_o(),
    .perf_icache_read_hit_o(),
    .perf_icache_read_miss_o(),
    .perf_dcache_read_hit_o(),
    .perf_dcache_read_miss_o(),
    .perf_dcache_write_hit_o(),
    .perf_dcache_write_miss_o(),
    .protocol_error_clear_i(protocol_error_clear),
    .fetch_protocol_error_o(),
    .cluster_protocol_error_o(),
    .ifetch_path_protocol_error_o(),
    .dmem_path_protocol_error_o(),
    .maint_protocol_error_o(),
    .protocol_error_o()
  );
  /* verilator lint_on PINCONNECTEMPTY */

endmodule

`default_nettype wire
