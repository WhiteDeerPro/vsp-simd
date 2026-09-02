// SPDX-License-Identifier: MIT

`default_nettype none

// Integration harness for the product-oriented D-side composition.  It adds
// only a portable ordered SRAM below the production wrapper; every component
// above that SRAM is production RTL from its owning repository.
module vsp_dmem_cached_fabric_wrapper_tb_top #(
  parameter integer PADDR_W = 40,
  parameter integer LOWER_DATA_W = 32
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                                      dmem_req_valid_i,
  output logic                                      dmem_req_ready_o,
  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0]         dmem_req_op_i,
  input  logic [31:0]                               dmem_req_eaddr_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] dmem_req_addr_space_i,
  input  logic [7:0]                                dmem_req_addr_context_i,
  input  logic [31:0]                               dmem_req_wdata_i,
  input  logic [3:0]                                dmem_req_wstrb_i,
  output logic                                      dmem_rsp_valid_o,
  input  logic                                      dmem_rsp_ready_i,
  output logic [31:0]                               dmem_rsp_rdata_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     dmem_rsp_fault_cause_o,

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

  input  logic                                      backing_init_valid_i,
  output logic                                      backing_init_ready_o,
  input  logic [PADDR_W-1:0]                        backing_init_paddr_i,
  input  logic [LOWER_DATA_W-1:0]                   backing_init_wdata_i,
  input  logic [(LOWER_DATA_W/8)-1:0]               backing_init_wstrb_i,
  output logic                                      backing_init_error_o,
  input  logic [PADDR_W-1:0]                        backing_peek_paddr_i,
  output logic [LOWER_DATA_W-1:0]                   backing_peek_rdata_o,
  output logic                                      backing_peek_error_o,

  input  logic                                      protocol_error_clear_i,
  output logic                                      dmem_path_ready_o,
  output logic                                      dmem_path_quiescent_o,
  output logic                                      dmem_path_busy_o,
  output logic                                      mmu_init_done_o,
  output logic                                      dcache_init_done_o,
  output logic                                      fabric_quarantine_o,
  output logic                                      fabric_idle_o,
  output logic                                      local_idle_o,
  output logic                                      uncached_device_idle_o,
  output logic                                      perf_dcache_read_hit_o,
  output logic                                      perf_dcache_read_miss_o,
  output logic                                      perf_dcache_write_hit_o,
  output logic                                      perf_dcache_write_miss_o,
  output logic                                      protocol_error_o,
  output logic [31:0]                               lower_req_count_o,
  output logic [31:0]                               lower_rsp_count_o
);
  import cache_pkg::*;
  import vsp_mem_common_pkg::*;

  localparam integer REGION_COUNT = 4;
  localparam integer REGION_INDEX_W = 2;
  localparam integer CACHE_MEM_BEATS_W =
      ((32 / (LOWER_DATA_W / 8)) <= 1) ? 1 :
      $clog2((32 / (LOWER_DATA_W / 8)) + 1);
  localparam logic [PADDR_W-1:0] REGION_PAGE_MASK =
      {PADDR_W{1'b1}} & ~PADDR_W'(12'hfff);
  localparam logic [REGION_COUNT*PADDR_W-1:0] STATIC_REGION_BASE = {
    PADDR_W'(0),
    PADDR_W'(32'h0000_3000),
    PADDR_W'(32'h0000_2000),
    PADDR_W'(32'h0000_1000)
  };
  localparam logic [REGION_COUNT*PADDR_W-1:0] STATIC_REGION_MASK = {
    PADDR_W'(0),
    REGION_PAGE_MASK, REGION_PAGE_MASK, REGION_PAGE_MASK
  };
  localparam logic [REGION_COUNT*VSP_MEM_ENDPOINT_W-1:0]
      STATIC_REGION_ENDPOINT = {
        VSP_MEM_ENDPOINT_CACHEABLE,
        VSP_MEM_ENDPOINT_DEVICE,
        VSP_MEM_ENDPOINT_UNCACHED,
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

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_counters
    if (!rst_ni) begin
      lower_req_count_o <= '0;
      lower_rsp_count_o <= '0;
    end else begin
      if (lower_req_valid && lower_req_ready)
        lower_req_count_o <= lower_req_count_o + 32'd1;
      if (lower_rsp_valid && lower_rsp_ready)
        lower_rsp_count_o <= lower_rsp_count_o + 32'd1;
    end
  end

  /* verilator lint_off PINCONNECTEMPTY */
  vsp_dmem_cached_fabric_wrapper #(
    .PADDR_W(PADDR_W),
    .TRANSLATION_ENABLE(1'b1),
    .MMU_CONTEXT_COUNT(2),
    .ASID_W(9),
    .I_TLB_ENTRY_COUNT(2),
    .D_TLB_ENTRY_COUNT(4),
    .TLB_EPOCH_W(8),
    .REGION_COUNT(REGION_COUNT),
    .REGION_INDEX_W(REGION_INDEX_W),
    .REGION_ENABLE(4'b0111),
    .REGION_BASE(STATIC_REGION_BASE),
    .REGION_MASK(STATIC_REGION_MASK),
    .REGION_ENDPOINT(STATIC_REGION_ENDPOINT),
    .REGION_READ_OK(4'b0111),
    .REGION_WRITE_OK(4'b0111),
    .REGION_EXECUTE_OK(4'b0000),
    .REGION_IDEMPOTENT(4'b0011),
    .LOWER_DATA_W(LOWER_DATA_W),
    .DCACHE_LINE_BYTES(32),
    .DCACHE_SET_COUNT(4),
    .DCACHE_WAY_COUNT(2),
    .DCACHE_RAM_RD_LATENCY(1),
    .CACHE_REQ_ID_W(1),
    .CACHE_USER_W(1),
    .CACHE_MEM_BEATS_W(CACHE_MEM_BEATS_W),
    .LOCAL_BASE_ADDR(PADDR_W'(0)),
    .LOCAL_DEPTH_WORDS(256)
  ) u_dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .dmem_req_valid_i(dmem_req_valid_i),
    .dmem_req_ready_o(dmem_req_ready_o),
    .dmem_req_op_i(dmem_req_op_i),
    .dmem_req_eaddr_i(dmem_req_eaddr_i),
    .dmem_req_addr_space_i(dmem_req_addr_space_i),
    .dmem_req_addr_context_i(dmem_req_addr_context_i),
    .dmem_req_wdata_i(dmem_req_wdata_i),
    .dmem_req_wstrb_i(dmem_req_wstrb_i),
    .dmem_rsp_valid_o(dmem_rsp_valid_o),
    .dmem_rsp_ready_i(dmem_rsp_ready_i),
    .dmem_rsp_rdata_o(dmem_rsp_rdata_o),
    .dmem_rsp_fault_cause_o(dmem_rsp_fault_cause_o),
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
    .mmu_cfg_valid_i(mmu_cfg_valid_i),
    .mmu_cfg_ready_o(mmu_cfg_ready_o),
    .mmu_cfg_write_i(mmu_cfg_write_i),
    .mmu_cfg_context_i(mmu_cfg_context_i),
    .mmu_cfg_field_i(mmu_cfg_field_i),
    .mmu_cfg_wdata_i(mmu_cfg_wdata_i),
    .mmu_cfg_rsp_valid_o(mmu_cfg_rsp_valid_o),
    .mmu_cfg_rsp_ready_i(mmu_cfg_rsp_ready_i),
    .mmu_cfg_rsp_rdata_o(mmu_cfg_rsp_rdata_o),
    .mmu_cfg_rsp_status_o(mmu_cfg_rsp_status_o),
    .tlb_inv_req_valid_i(1'b0),
    .tlb_inv_req_ready_o(),
    .tlb_inv_req_scope_i('0),
    .tlb_inv_req_asid_i('0),
    .tlb_inv_req_vaddr_i('0),
    .tlb_inv_rsp_valid_o(),
    .tlb_inv_rsp_ready_i(1'b1),
    .tlb_inv_rsp_status_o(),
    .dcache_maint_req_valid_i(dcache_maint_req_valid_i),
    .dcache_maint_req_ready_o(dcache_maint_req_ready_o),
    .dcache_maint_req_op_i(dcache_maint_req_op_i),
    .dcache_maint_req_paddr_i(dcache_maint_req_paddr_i),
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
    .ic_mem_cmd_op_i(CACHE_MEM_REFILL),
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
    .fabric_drain_req_i(fabric_drain_req_i),
    .fabric_drain_done_o(fabric_drain_done_o),
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
    .local_idle_o(local_idle_o),
    .uncached_device_idle_o(uncached_device_idle_o),
    .fabric_idle_o(fabric_idle_o),
    .fabric_busy_o(),
    .fabric_quarantine_o(fabric_quarantine_o),
    .fabric_owner_valid_o(),
    .fabric_owner_o(),
    .dmem_path_ready_o(dmem_path_ready_o),
    .dmem_path_quiescent_o(dmem_path_quiescent_o),
    .dmem_path_busy_o(dmem_path_busy_o),
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
    .protocol_error_o(protocol_error_o)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  vsp_fabric_ordered_sram #(
    .PADDR_W(PADDR_W),
    .DATA_W(LOWER_DATA_W),
    .BASE_ADDR(PADDR_W'(32'h0000_1000)),
    .DEPTH_BEATS(12*1024/(LOWER_DATA_W/8)),
    .INIT_FILE("")
  ) u_backing_sram (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
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
