// SPDX-License-Identifier: MIT

`default_nettype none

// Product memory-system integration harness.  Both instruction and data
// traffic leave the DUT through its one ordered lower port and terminate in
// the real physical-fabric SRAM model.  The SRAM sideband ports are only used
// to install the test image and inspect architectural memory after execution.
module vsp_uword_memory_system_wrapper_tb_top #(
  parameter integer PADDR_W = 40,
  parameter integer LOWER_DATA_W = 32
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                                      start_valid_i,
  output logic                                      start_ready_o,
  input  logic [31:0]                               start_pc_i,
  input  logic [31:0]                               end_pc_i,
  input  logic                                      start_context_i,
  input  logic [3:0]                                start_group_mask_i,
  input  logic [7:0]                                start_tag_seed_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                                     start_ifetch_addr_space_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
                                                     start_ifetch_addr_context_i,

  output logic [31:0]                               fetch_pc_o,
  output logic                                      fetch_running_o,
  output logic                                      program_active_o,
  output logic                                      program_done_o,
  output logic                                      program_failed_o,
  output logic                                      program_error_o,
  output logic                                      program_halted_o,
  output logic [31:0]                               program_terminal_pc_o,

  output logic                                      action_cpl_valid_o,
  input  logic                                      action_cpl_ready_i,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     action_cpl_class_o,
  output logic [7:0]                                action_cpl_tag_o,
  output logic [3:0]                                action_cpl_group_mask_o,
  output logic [vsp_action_pkg::VSP_ACTION_CPL_STATUS_W-1:0]
                                                     action_cpl_status_o,
  output logic                                      action_cpl_end_o,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]
                                                     action_cpl_memory_op_o,
  output logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
                                                     action_cpl_memory_status_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     action_cpl_memory_fault_cause_o,
  output logic [31:0]                               action_cpl_memory_fault_eaddr_o,
  output logic [3:0]
                                                     action_cpl_memory_requested_group_mask_o,
  output logic [3:0]
                                                     action_cpl_memory_completed_group_mask_o,
  output logic [3:0]
                                                     action_cpl_memory_failed_group_mask_o,
  output logic [4:0]                                action_cpl_memory_bytes_committed_o,
  output logic                                      action_cpl_memory_partial_o,

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

  input  logic                                      maint_cmd_valid_i,
  output logic                                      maint_cmd_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_MAINT_OP_W-1:0]
                                                     maint_cmd_op_i,
  input  logic [31:0]                               maint_cmd_eaddr_i,
  input  logic [PADDR_W-1:0]                        maint_cmd_paddr_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
                                                     maint_cmd_addr_context_i,
  input  logic [8:0]                                maint_cmd_asid_i,
  output logic                                      maint_cpl_valid_o,
  input  logic                                      maint_cpl_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_MAINT_CPL_STATUS_W-1:0]
                                                     maint_cpl_status_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     maint_cpl_fault_o,
  output logic                                      maint_busy_o,
  output logic                                      maint_quiescent_o,
  output logic [vsp_memory_maintenance_pkg::VSP_MAINT_STEP_W-1:0]
                                                     maint_current_step_o,

  input  logic                                      backing_init_valid_i,
  output logic                                      backing_init_ready_o,
  input  logic [PADDR_W-1:0]                        backing_init_paddr_i,
  input  logic [LOWER_DATA_W-1:0]                   backing_init_wdata_i,
  input  logic [(LOWER_DATA_W/8)-1:0]               backing_init_wstrb_i,
  output logic                                      backing_init_error_o,
  input  logic [PADDR_W-1:0]                        backing_peek_paddr_i,
  output logic [LOWER_DATA_W-1:0]                   backing_peek_rdata_o,
  output logic                                      backing_peek_error_o,

  output logic                                      system_ready_o,
  output logic                                      system_quiescent_o,
  output logic                                      system_busy_o,
  output logic                                      dmem_path_ready_o,
  output logic                                      ifetch_path_ready_o,
  output logic                                      mmu_init_done_o,
  output logic                                      dcache_init_done_o,
  output logic                                      icache_init_done_o,
  output logic                                      fabric_quarantine_o,
  output logic                                      i_region_config_overlap_o,
  output logic                                      d_region_config_overlap_o,
  output logic                                      perf_icache_read_hit_o,
  output logic                                      perf_icache_read_miss_o,
  output logic                                      perf_dcache_read_hit_o,
  output logic                                      perf_dcache_read_miss_o,
  output logic                                      perf_dcache_write_hit_o,
  output logic                                      perf_dcache_write_miss_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      fetch_protocol_error_o,
  output logic                                      cluster_protocol_error_o,
  output logic                                      ifetch_path_protocol_error_o,
  output logic                                      dmem_path_protocol_error_o,
  output logic                                      maint_protocol_error_o,
  output logic                                      protocol_error_o,
  output logic [31:0]                               lower_req_count_o,
  output logic [31:0]                               lower_read_req_count_o,
  output logic [31:0]                               lower_write_req_count_o,
  output logic [31:0]                               lower_rsp_count_o
);
  import vsp_mem_common_pkg::*;

  localparam integer REGION_COUNT = 4;
  localparam logic [PADDR_W-1:0] REGION_PAGE_MASK =
      {PADDR_W{1'b1}} & ~PADDR_W'(12'hfff);
  localparam logic [REGION_COUNT*PADDR_W-1:0] STATIC_REGION_BASE = {
    PADDR_W'(0), PADDR_W'(0), PADDR_W'(32'h0000_1000), PADDR_W'(0)
  };
  localparam logic [REGION_COUNT*PADDR_W-1:0] STATIC_REGION_MASK = {
    PADDR_W'(0), PADDR_W'(0), REGION_PAGE_MASK, REGION_PAGE_MASK
  };
  localparam logic [REGION_COUNT*VSP_MEM_ENDPOINT_W-1:0]
      STATIC_REGION_ENDPOINT = {
        VSP_MEM_ENDPOINT_CACHEABLE,
        VSP_MEM_ENDPOINT_CACHEABLE,
        VSP_MEM_ENDPOINT_CACHEABLE,
        VSP_MEM_ENDPOINT_CACHEABLE
      };

  logic lower_req_valid;
  logic lower_req_ready;
  logic lower_req_write;
  logic [PADDR_W-1:0] lower_req_paddr;
  logic [LOWER_DATA_W-1:0] lower_req_wdata;
  logic [(LOWER_DATA_W/8)-1:0] lower_req_wstrb;
  logic lower_rsp_valid;
  logic lower_rsp_ready;
  logic [LOWER_DATA_W-1:0] lower_rsp_rdata;
  logic [vsp_memory_endpoints_pkg::VSP_LOWER_STATUS_W-1:0]
      lower_rsp_status;
  logic backing_idle;
  logic backing_quiescent;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_lower_counters
    if (!rst_ni) begin
      lower_req_count_o <= '0;
      lower_read_req_count_o <= '0;
      lower_write_req_count_o <= '0;
      lower_rsp_count_o <= '0;
    end else begin
      if (lower_req_valid && lower_req_ready) begin
        lower_req_count_o <= lower_req_count_o + 32'd1;
        if (lower_req_write)
          lower_write_req_count_o <= lower_write_req_count_o + 32'd1;
        else
          lower_read_req_count_o <= lower_read_req_count_o + 32'd1;
      end
      if (lower_rsp_valid && lower_rsp_ready)
        lower_rsp_count_o <= lower_rsp_count_o + 32'd1;
    end
  end

  /* verilator lint_off PINCONNECTEMPTY */
  vsp_uword_memory_system_wrapper #(
    .PC_W(32),
    .STORE_WORDS(16),
    .STORE_BASE_PC(32'h0000_0020),
    .FETCH_WORDS(4),
    .ADMIT_SLOTS(3),
    .GROUP_COUNT(4),
    .ISSUE_SLOTS(1),
    .QUEUE_DEPTH(4),
    .TRACKER_ENTRIES(4),
    .LANES(4),
    .ELEM_W(8),
    .ACC_W(32),
    .VREGS(16),
    .AREGS(8),
    .MREGS(4),
    .CONTEXT_COUNT(1),
    .TAG_W(8),
    .PADDR_W(PADDR_W),
    .TRANSLATION_ENABLE(1'b1),
    .MMU_CONTEXT_COUNT(2),
    .ASID_W(9),
    .I_TLB_ENTRY_COUNT(2),
    .D_TLB_ENTRY_COUNT(4),
    .TLB_EPOCH_W(8),
    .REGION_COUNT(REGION_COUNT),
    .REGION_INDEX_W(2),
    .REGION_ENABLE(4'b0011),
    .REGION_BASE(STATIC_REGION_BASE),
    .REGION_MASK(STATIC_REGION_MASK),
    .REGION_ENDPOINT(STATIC_REGION_ENDPOINT),
    .REGION_READ_OK(4'b0010),
    .REGION_WRITE_OK(4'b0010),
    .REGION_EXECUTE_OK(4'b0001),
    .REGION_IDEMPOTENT(4'b0011),
    .LOWER_DATA_W(LOWER_DATA_W),
    .DCACHE_LINE_BYTES(32),
    .DCACHE_SET_COUNT(4),
    .DCACHE_WAY_COUNT(2),
    .DCACHE_RAM_RD_LATENCY(1),
    .ICACHE_FRONT_DATA_W(128),
    .ICACHE_LINE_BYTES(32),
    .ICACHE_SET_COUNT(4),
    .ICACHE_WAY_COUNT(2),
    .ICACHE_RAM_RD_LATENCY(1),
    .CACHE_REQ_ID_W(1),
    .CACHE_USER_W(1),
    .LOCAL_BASE_ADDR(PADDR_W'(0)),
    .LOCAL_DEPTH_WORDS(256)
  ) u_dut (
    .clk_i,
    .rst_ni,
    .start_valid_i,
    .start_ready_o,
    .start_pc_i,
    .end_pc_i,
    .start_context_i,
    .start_group_mask_i,
    .start_tag_seed_i,
    .start_ifetch_addr_space_i,
    .start_ifetch_addr_context_i,
    .fetch_pc_o,
    .fetch_running_o,
    .fetch_stop_o(),
    .program_active_o,
    .program_done_o,
    .program_failed_o,
    .program_error_o,
    .program_halted_o,
    .program_terminal_pc_o,
    .action_cpl_valid_o,
    .action_cpl_ready_i,
    .action_cpl_class_o,
    .action_cpl_context_o(),
    .action_cpl_tag_o,
    .action_cpl_group_mask_o,
    .action_cpl_status_o,
    .action_cpl_decode_error_o(),
    .action_cpl_end_o,
    .action_cpl_memory_op_o,
    .action_cpl_memory_status_o,
    .action_cpl_memory_fault_cause_o,
    .action_cpl_memory_fault_eaddr_o,
    .action_cpl_memory_requested_group_mask_o,
    .action_cpl_memory_completed_group_mask_o,
    .action_cpl_memory_failed_group_mask_o,
    .action_cpl_memory_bytes_committed_o,
    .action_cpl_memory_partial_o,
    .exec_result_valid_o(),
    .exec_result_ready_i(1'b1),
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
    .mmu_cfg_valid_i,
    .mmu_cfg_ready_o,
    .mmu_cfg_write_i,
    .mmu_cfg_context_i,
    .mmu_cfg_field_i,
    .mmu_cfg_wdata_i,
    .mmu_cfg_rsp_valid_o,
    .mmu_cfg_rsp_ready_i,
    .mmu_cfg_rsp_rdata_o,
    .mmu_cfg_rsp_status_o,
    .maint_cmd_valid_i,
    .maint_cmd_ready_o,
    .maint_cmd_op_i,
    .maint_cmd_eaddr_i,
    .maint_cmd_paddr_i,
    .maint_cmd_addr_context_i,
    .maint_cmd_asid_i,
    .maint_cpl_valid_o,
    .maint_cpl_ready_i,
    .maint_cpl_status_o,
    .maint_cpl_fault_o,
    .maint_busy_o,
    .maint_quiescent_o,
    .maint_current_step_o,
    .lower_req_valid_o(lower_req_valid),
    .lower_req_ready_i(lower_req_ready),
    .lower_req_write_o(lower_req_write),
    .lower_req_paddr_o(lower_req_paddr),
    .lower_req_wdata_o(lower_req_wdata),
    .lower_req_wstrb_o(lower_req_wstrb),
    .lower_rsp_valid_i(lower_rsp_valid),
    .lower_rsp_ready_o(lower_rsp_ready),
    .lower_rsp_rdata_i(lower_rsp_rdata),
    .lower_rsp_status_i(lower_rsp_status),
    .lower_quiescent_i(backing_quiescent),
    .system_ready_o,
    .system_quiescent_o,
    .system_busy_o,
    .dmem_path_ready_o,
    .ifetch_path_ready_o,
    .mmu_init_done_o,
    .dcache_init_done_o,
    .icache_init_done_o,
    .fabric_quarantine_o,
    .i_region_config_overlap_o,
    .d_region_config_overlap_o,
    .perf_icache_read_hit_o,
    .perf_icache_read_miss_o,
    .perf_dcache_read_hit_o,
    .perf_dcache_read_miss_o,
    .perf_dcache_write_hit_o,
    .perf_dcache_write_miss_o,
    .protocol_error_clear_i,
    .fetch_protocol_error_o,
    .cluster_protocol_error_o,
    .ifetch_path_protocol_error_o,
    .dmem_path_protocol_error_o,
    .maint_protocol_error_o,
    .protocol_error_o
  );
  /* verilator lint_on PINCONNECTEMPTY */

  vsp_fabric_ordered_sram #(
    .PADDR_W(PADDR_W),
    .DATA_W(LOWER_DATA_W),
    .BASE_ADDR(PADDR_W'(0)),
    .DEPTH_BEATS(8192/(LOWER_DATA_W/8)),
    .INIT_FILE("")
  ) u_backing_sram (
    .clk_i,
    .rst_ni,
    .req_valid_i(lower_req_valid),
    .req_ready_o(lower_req_ready),
    .req_write_i(lower_req_write),
    .req_paddr_i(lower_req_paddr),
    .req_wdata_i(lower_req_wdata),
    .req_wstrb_i(lower_req_wstrb),
    .rsp_valid_o(lower_rsp_valid),
    .rsp_ready_i(lower_rsp_ready),
    .rsp_rdata_o(lower_rsp_rdata),
    .rsp_status_o(lower_rsp_status),
    .idle_o(backing_idle),
    .quiescent_o(backing_quiescent),
    .init_valid_i(backing_init_valid_i),
    .init_ready_o(backing_init_ready_o),
    .init_paddr_i(backing_init_paddr_i),
    .init_wdata_i(backing_init_wdata_i),
    .init_wstrb_i(backing_init_wstrb_i),
    .init_error_o(backing_init_error_o),
    .peek_paddr_i(backing_peek_paddr_i),
    .peek_rdata_o(backing_peek_rdata_o),
    .peek_error_o(backing_peek_error_o)
  );

  /* verilator lint_off UNUSED */
  logic unused_backing_idle;
  assign unused_backing_idle = backing_idle;
  /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
