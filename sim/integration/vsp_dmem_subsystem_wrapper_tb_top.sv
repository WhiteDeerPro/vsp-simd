// SPDX-License-Identifier: MIT

`default_nettype none

/* verilator lint_off DECLFILENAME */
// Small registered endpoint used only by the dmem subsystem integration
// testbench.  A request is captured into a pending slot, so even with
// response_enable_i continuously asserted the response cannot appear until
// the cycle after request acceptance.  The response is then held until the
// wrapper accepts it.
module vsp_dmem_tb_registered_responder #(
  parameter integer ADDR_W = 40,
  parameter logic [31:0] READ_DATA_XOR = 32'h0000_0000
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              accept_enable_i,
  input  logic              response_enable_i,

  input  logic              req_valid_i,
  output logic              req_ready_o,
  input  logic              req_store_i,
  input  logic [ADDR_W-1:0] req_addr_i,
  input  logic [31:0]       req_wdata_i,
  input  logic [3:0]        req_wstrb_i,

  output logic              rsp_valid_o,
  input  logic              rsp_ready_i,
  output logic [31:0]       rsp_rdata_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                            rsp_fault_o,

  output logic              busy_o,
  output logic [31:0]       req_count_o,
  output logic [31:0]       rsp_count_o,
  output logic              last_store_o,
  output logic [ADDR_W-1:0] last_addr_o,
  output logic [31:0]       last_wdata_o,
  output logic [3:0]        last_wstrb_o
);
  import vsp_mem_common_pkg::*;

  logic pending_q;
  logic rsp_valid_q;
  logic [31:0] rsp_rdata_q;

  assign req_ready_o = rst_ni && accept_enable_i &&
                       !pending_q && !rsp_valid_q;
  assign rsp_valid_o = rsp_valid_q;
  assign rsp_rdata_o = rsp_rdata_q;
  assign rsp_fault_o = VSP_MEM_FAULT_NONE;
  assign busy_o = pending_q || rsp_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_responder
    if (!rst_ni) begin
      pending_q    <= 1'b0;
      rsp_valid_q  <= 1'b0;
      rsp_rdata_q  <= '0;
      req_count_o  <= '0;
      rsp_count_o  <= '0;
      last_store_o <= 1'b0;
      last_addr_o  <= '0;
      last_wdata_o <= '0;
      last_wstrb_o <= '0;
    end else begin
      if (rsp_valid_q && rsp_ready_i) begin
        rsp_valid_q <= 1'b0;
        rsp_count_o <= rsp_count_o + 32'd1;
      end

      if (pending_q && response_enable_i) begin
        pending_q   <= 1'b0;
        rsp_valid_q <= 1'b1;
      end

      if (req_valid_i && req_ready_o) begin
        pending_q    <= 1'b1;
        rsp_rdata_q  <= req_store_i ? 32'b0 :
                         (req_addr_i[31:0] ^ READ_DATA_XOR);
        req_count_o  <= req_count_o + 32'd1;
        last_store_o <= req_store_i;
        last_addr_o  <= req_addr_i;
        last_wdata_o <= req_wdata_i;
        last_wstrb_o <= req_wstrb_i;
      end
    end
  end

`ifndef SYNTHESIS
  logic rsp_stalled_q;
  logic [31:0] rsp_rdata_stalled_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_assertions
    if (!rst_ni) begin
      rsp_stalled_q       <= 1'b0;
      rsp_rdata_stalled_q <= '0;
    end else begin
      if (rsp_stalled_q) begin
        assert (rsp_valid_o)
          else $error("vsp_dmem_tb_registered_responder: response valid dropped while stalled");
        assert (rsp_rdata_o == rsp_rdata_stalled_q)
          else $error("vsp_dmem_tb_registered_responder: response data changed while stalled");
      end
      assert (!(req_ready_o && rsp_valid_o))
        else $error("vsp_dmem_tb_registered_responder: accepted request with live response");

      rsp_stalled_q <= rsp_valid_o && !rsp_ready_i;
      rsp_rdata_stalled_q <= rsp_rdata_o;
    end
  end
`endif

endmodule
/* verilator lint_on DECLFILENAME */


// Executable integration shell around vsp_dmem_subsystem_wrapper.
//
// Static physical regions are four non-overlapping 4 KiB windows:
//
//   entry 0: 0x1000..0x1fff -> CACHEABLE
//   entry 1: 0x2000..0x2fff -> UNCACHED
//   entry 2: 0x3000..0x3fff -> DEVICE
//   entry 3: 0x4000..0x4fff -> LOCAL
//
// Endpoint control-vector indices deliberately equal the COMMON endpoint
// encodings.  Therefore bit 0 controls CACHEABLE, bit 1 UNCACHED, bit 2
// DEVICE, and bit 3 LOCAL.  Addresses outside these windows exercise the
// physical-region no-match path.  A direct LOCAL request bypasses this table.
module vsp_dmem_subsystem_wrapper_tb_top #(
  parameter integer PADDR_W = 40,
  parameter logic TRANSLATION_ENABLE = 1'b1,
  parameter integer MMU_CONTEXT_COUNT = 4,
  parameter integer ASID_W = 9,
  parameter integer I_TLB_ENTRY_COUNT = 4,
  parameter integer D_TLB_ENTRY_COUNT = 8,
  parameter integer TLB_EPOCH_W = 8
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

  // Test-controlled endpoint and PTW backpressure.  A pending response is
  // generated only while its response-enable bit is high.
  input  logic [3:0]                                endpoint_req_enable_i,
  input  logic [3:0]                                endpoint_rsp_enable_i,
  input  logic                                      ptw_req_enable_i,
  input  logic                                      ptw_rsp_enable_i,
  input  logic [31:0]                               ptw_model_rsp_rdata_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     ptw_model_rsp_fault_i,

  input  logic                                      protocol_error_clear_i,

  output logic                                      lsu_idle_o,
  output logic                                      lsu_busy_o,
  output logic                                      space_router_idle_o,
  output logic                                      region_router_idle_o,
  output logic                                      region_config_overlap_o,
  output logic                                      region_diag_rsp_valid_o,
  output logic                                      region_diag_match_valid_o,
  output logic [1:0]                                region_diag_match_index_o,
  output logic                                      region_diag_overlap_o,
  output logic                                      region_diag_endpoint_valid_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_ENDPOINT_W-1:0]
                                                     region_diag_endpoint_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     region_diag_fault_o,
  output logic                                      mmu_init_done_o,
  output logic                                      mmu_quiescent_o,
  output logic                                      mmu_busy_o,
  output logic [TLB_EPOCH_W-1:0]                    i_tlb_epoch_o,
  output logic [TLB_EPOCH_W-1:0]                    d_tlb_epoch_o,
  output logic                                      i_tlb_epoch_exhausted_o,
  output logic                                      d_tlb_epoch_exhausted_o,
  output logic                                      internal_quiescent_o,
  output logic                                      internal_busy_o,
  output logic                                      lsu_protocol_error_o,
  output logic                                      mmu_protocol_error_o,
  output logic                                      protocol_error_o,
  output logic                                      ptw_pte_fault_paddr_valid_o,
  output logic [PADDR_W-1:0]                        ptw_pte_fault_paddr_o,

  output logic [3:0]                                endpoint_busy_o,
  output logic                                      ptw_model_busy_o,
  output logic [31:0]                               dmem_req_count_o,
  output logic [31:0]                               dmem_rsp_count_o,
  output logic [31:0]                               cache_req_count_o,
  output logic [31:0]                               cache_rsp_count_o,
  output logic [31:0]                               local_req_count_o,
  output logic [31:0]                               local_rsp_count_o,
  output logic [31:0]                               uncached_req_count_o,
  output logic [31:0]                               uncached_rsp_count_o,
  output logic [31:0]                               device_req_count_o,
  output logic [31:0]                               device_rsp_count_o,
  output logic [31:0]                               ptw_req_count_o,
  output logic [31:0]                               ptw_rsp_count_o,

  output logic                                      last_cache_store_o,
  output logic [31:0]                               last_cache_eaddr_o,
  output logic [PADDR_W-1:0]                        last_cache_paddr_o,
  output logic [31:0]                               last_cache_wdata_o,
  output logic [3:0]                                last_cache_wstrb_o,
  output logic                                      last_local_store_o,
  output logic [PADDR_W-1:0]                        last_local_addr_o,
  output logic [31:0]                               last_local_wdata_o,
  output logic [3:0]                                last_local_wstrb_o,
  output logic                                      last_uncached_store_o,
  output logic [PADDR_W-1:0]                        last_uncached_addr_o,
  output logic [31:0]                               last_uncached_wdata_o,
  output logic [3:0]                                last_uncached_wstrb_o,
  output logic                                      last_device_store_o,
  output logic [PADDR_W-1:0]                        last_device_addr_o,
  output logic [31:0]                               last_device_wdata_o,
  output logic [3:0]                                last_device_wstrb_o,
  output logic [PADDR_W-1:0]                        last_ptw_paddr_o
);
  import vsp_mem_common_pkg::*;

  localparam integer REGION_COUNT = 4;
  localparam integer REGION_INDEX_W = 2;
  localparam logic [PADDR_W-1:0] REGION_PAGE_MASK =
      {PADDR_W{1'b1}} & ~PADDR_W'(12'hfff);
  localparam logic [REGION_COUNT*PADDR_W-1:0] STATIC_REGION_BASE = {
    PADDR_W'(32'h0000_4000),
    PADDR_W'(32'h0000_3000),
    PADDR_W'(32'h0000_2000),
    PADDR_W'(32'h0000_1000)
  };
  localparam logic [REGION_COUNT*PADDR_W-1:0] STATIC_REGION_MASK = {
    REGION_PAGE_MASK, REGION_PAGE_MASK, REGION_PAGE_MASK, REGION_PAGE_MASK
  };
  localparam logic [REGION_COUNT*VSP_MEM_ENDPOINT_W-1:0]
      STATIC_REGION_ENDPOINT = {
        VSP_MEM_ENDPOINT_LOCAL,
        VSP_MEM_ENDPOINT_DEVICE,
        VSP_MEM_ENDPOINT_UNCACHED,
        VSP_MEM_ENDPOINT_CACHEABLE
      };

  logic i_tr_req_ready;
  logic i_tr_rsp_valid;
  logic [PADDR_W-1:0] i_tr_rsp_paddr;
  logic [VSP_MEM_FAULT_W-1:0] i_tr_rsp_fault;
  logic [31:0] i_tr_rsp_fault_vaddr;

  logic ptw_mem_req_valid;
  logic ptw_mem_req_ready;
  logic [PADDR_W-1:0] ptw_mem_req_paddr;
  logic ptw_mem_rsp_valid_q;
  logic ptw_mem_rsp_ready;
  logic [31:0] ptw_mem_rsp_rdata_q;
  logic [VSP_MEM_FAULT_W-1:0] ptw_mem_rsp_fault_q;
  logic ptw_pending_q;

  logic cache_req_valid;
  logic cache_req_ready;
  logic [VSP_MEM_ACCESS_W-1:0] cache_req_access;
  logic [31:0] cache_req_eaddr;
  logic [PADDR_W-1:0] cache_req_paddr;
  logic [31:0] cache_req_wdata;
  logic [3:0] cache_req_wstrb;
  logic cache_rsp_valid;
  logic cache_rsp_ready;
  logic [31:0] cache_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] cache_rsp_fault;

  logic local_req_valid;
  logic local_req_ready;
  logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0] local_req_op;
  logic [PADDR_W-1:0] local_req_addr;
  logic [31:0] local_req_wdata;
  logic [3:0] local_req_wstrb;
  logic local_rsp_valid;
  logic local_rsp_ready;
  logic [31:0] local_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] local_rsp_fault;

  logic uncached_req_valid;
  logic uncached_req_ready;
  logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0] uncached_req_op;
  logic [PADDR_W-1:0] uncached_req_addr;
  logic [31:0] uncached_req_wdata;
  logic [3:0] uncached_req_wstrb;
  logic uncached_rsp_valid;
  logic uncached_rsp_ready;
  logic [31:0] uncached_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] uncached_rsp_fault;

  logic device_req_valid;
  logic device_req_ready;
  logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0] device_req_op;
  logic [PADDR_W-1:0] device_req_addr;
  logic [31:0] device_req_wdata;
  logic [3:0] device_req_wstrb;
  logic device_rsp_valid;
  logic device_rsp_ready;
  logic [31:0] device_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] device_rsp_fault;

  logic barrier_ready;
  logic barrier_rsp_valid;
  logic [VSP_MEM_FAULT_W-1:0] barrier_rsp_status;
  logic policy_maint_req_valid;
  logic [VSP_MEM_BARRIER_OP_W-1:0] policy_maint_req_op;
  logic [31:0] policy_maint_req_eaddr;
  logic [7:0] policy_maint_req_context;
  logic policy_maint_rsp_ready;

  assign ptw_mem_req_ready = rst_ni && ptw_req_enable_i &&
                             !ptw_pending_q && !ptw_mem_rsp_valid_q;
  assign ptw_model_busy_o = ptw_pending_q || ptw_mem_rsp_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_top_counters
    if (!rst_ni) begin
      dmem_req_count_o <= '0;
      dmem_rsp_count_o <= '0;
    end else begin
      if (dmem_req_valid_i && dmem_req_ready_o)
        dmem_req_count_o <= dmem_req_count_o + 32'd1;
      if (dmem_rsp_valid_o && dmem_rsp_ready_i)
        dmem_rsp_count_o <= dmem_rsp_count_o + 32'd1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_ptw_responder
    if (!rst_ni) begin
      ptw_pending_q       <= 1'b0;
      ptw_mem_rsp_valid_q <= 1'b0;
      ptw_mem_rsp_rdata_q <= '0;
      ptw_mem_rsp_fault_q <= VSP_MEM_FAULT_NONE;
      ptw_req_count_o     <= '0;
      ptw_rsp_count_o     <= '0;
      last_ptw_paddr_o    <= '0;
    end else begin
      if (ptw_mem_rsp_valid_q && ptw_mem_rsp_ready) begin
        ptw_mem_rsp_valid_q <= 1'b0;
        ptw_rsp_count_o <= ptw_rsp_count_o + 32'd1;
      end

      if (ptw_pending_q && ptw_rsp_enable_i) begin
        ptw_pending_q       <= 1'b0;
        ptw_mem_rsp_valid_q <= 1'b1;
      end

      if (ptw_mem_req_valid && ptw_mem_req_ready) begin
        ptw_pending_q       <= 1'b1;
        ptw_mem_rsp_rdata_q <= ptw_model_rsp_rdata_i;
        ptw_mem_rsp_fault_q <= ptw_model_rsp_fault_i;
        ptw_req_count_o     <= ptw_req_count_o + 32'd1;
        last_ptw_paddr_o    <= ptw_mem_req_paddr;
      end
    end
  end

  vsp_dmem_tb_registered_responder #(
    .ADDR_W(PADDR_W),
    .READ_DATA_XOR(32'hcace_0000)
  ) u_cache_responder (
    .clk_i,
    .rst_ni,
    .accept_enable_i(endpoint_req_enable_i[VSP_MEM_ENDPOINT_CACHEABLE]),
    .response_enable_i(endpoint_rsp_enable_i[VSP_MEM_ENDPOINT_CACHEABLE]),
    .req_valid_i(cache_req_valid),
    .req_ready_o(cache_req_ready),
    .req_store_i(cache_req_access == VSP_MEM_ACCESS_STORE),
    .req_addr_i(cache_req_paddr),
    .req_wdata_i(cache_req_wdata),
    .req_wstrb_i(cache_req_wstrb),
    .rsp_valid_o(cache_rsp_valid),
    .rsp_ready_i(cache_rsp_ready),
    .rsp_rdata_o(cache_rsp_rdata),
    .rsp_fault_o(cache_rsp_fault),
    .busy_o(endpoint_busy_o[VSP_MEM_ENDPOINT_CACHEABLE]),
    .req_count_o(cache_req_count_o),
    .rsp_count_o(cache_rsp_count_o),
    .last_store_o(last_cache_store_o),
    .last_addr_o(last_cache_paddr_o),
    .last_wdata_o(last_cache_wdata_o),
    .last_wstrb_o(last_cache_wstrb_o)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_cache_eaddr_trace
    if (!rst_ni)
      last_cache_eaddr_o <= '0;
    else if (cache_req_valid && cache_req_ready)
      last_cache_eaddr_o <= cache_req_eaddr;
  end

  vsp_dmem_tb_registered_responder #(
    .ADDR_W(PADDR_W),
    .READ_DATA_XOR(32'h0ca0_0000)
  ) u_uncached_responder (
    .clk_i,
    .rst_ni,
    .accept_enable_i(endpoint_req_enable_i[VSP_MEM_ENDPOINT_UNCACHED]),
    .response_enable_i(endpoint_rsp_enable_i[VSP_MEM_ENDPOINT_UNCACHED]),
    .req_valid_i(uncached_req_valid),
    .req_ready_o(uncached_req_ready),
    .req_store_i(uncached_req_op == vsp_lsu_backend_pkg::VSP_LSU_OP_STORE),
    .req_addr_i(uncached_req_addr),
    .req_wdata_i(uncached_req_wdata),
    .req_wstrb_i(uncached_req_wstrb),
    .rsp_valid_o(uncached_rsp_valid),
    .rsp_ready_i(uncached_rsp_ready),
    .rsp_rdata_o(uncached_rsp_rdata),
    .rsp_fault_o(uncached_rsp_fault),
    .busy_o(endpoint_busy_o[VSP_MEM_ENDPOINT_UNCACHED]),
    .req_count_o(uncached_req_count_o),
    .rsp_count_o(uncached_rsp_count_o),
    .last_store_o(last_uncached_store_o),
    .last_addr_o(last_uncached_addr_o),
    .last_wdata_o(last_uncached_wdata_o),
    .last_wstrb_o(last_uncached_wstrb_o)
  );

  vsp_dmem_tb_registered_responder #(
    .ADDR_W(PADDR_W),
    .READ_DATA_XOR(32'hde10_0000)
  ) u_device_responder (
    .clk_i,
    .rst_ni,
    .accept_enable_i(endpoint_req_enable_i[VSP_MEM_ENDPOINT_DEVICE]),
    .response_enable_i(endpoint_rsp_enable_i[VSP_MEM_ENDPOINT_DEVICE]),
    .req_valid_i(device_req_valid),
    .req_ready_o(device_req_ready),
    .req_store_i(device_req_op == vsp_lsu_backend_pkg::VSP_LSU_OP_STORE),
    .req_addr_i(device_req_addr),
    .req_wdata_i(device_req_wdata),
    .req_wstrb_i(device_req_wstrb),
    .rsp_valid_o(device_rsp_valid),
    .rsp_ready_i(device_rsp_ready),
    .rsp_rdata_o(device_rsp_rdata),
    .rsp_fault_o(device_rsp_fault),
    .busy_o(endpoint_busy_o[VSP_MEM_ENDPOINT_DEVICE]),
    .req_count_o(device_req_count_o),
    .rsp_count_o(device_rsp_count_o),
    .last_store_o(last_device_store_o),
    .last_addr_o(last_device_addr_o),
    .last_wdata_o(last_device_wdata_o),
    .last_wstrb_o(last_device_wstrb_o)
  );

  vsp_dmem_tb_registered_responder #(
    .ADDR_W(PADDR_W),
    .READ_DATA_XOR(32'h10ca_0000)
  ) u_local_responder (
    .clk_i,
    .rst_ni,
    .accept_enable_i(endpoint_req_enable_i[VSP_MEM_ENDPOINT_LOCAL]),
    .response_enable_i(endpoint_rsp_enable_i[VSP_MEM_ENDPOINT_LOCAL]),
    .req_valid_i(local_req_valid),
    .req_ready_o(local_req_ready),
    .req_store_i(local_req_op == vsp_lsu_backend_pkg::VSP_LSU_OP_STORE),
    .req_addr_i(local_req_addr),
    .req_wdata_i(local_req_wdata),
    .req_wstrb_i(local_req_wstrb),
    .rsp_valid_o(local_rsp_valid),
    .rsp_ready_i(local_rsp_ready),
    .rsp_rdata_o(local_rsp_rdata),
    .rsp_fault_o(local_rsp_fault),
    .busy_o(endpoint_busy_o[VSP_MEM_ENDPOINT_LOCAL]),
    .req_count_o(local_req_count_o),
    .rsp_count_o(local_rsp_count_o),
    .last_store_o(last_local_store_o),
    .last_addr_o(last_local_addr_o),
    .last_wdata_o(last_local_wdata_o),
    .last_wstrb_o(last_local_wstrb_o)
  );

  vsp_dmem_subsystem_wrapper #(
    .PADDR_W(PADDR_W),
    .TRANSLATION_ENABLE(TRANSLATION_ENABLE),
    .MMU_CONTEXT_COUNT(MMU_CONTEXT_COUNT),
    .ASID_W(ASID_W),
    .I_TLB_ENTRY_COUNT(I_TLB_ENTRY_COUNT),
    .D_TLB_ENTRY_COUNT(D_TLB_ENTRY_COUNT),
    .TLB_EPOCH_W(TLB_EPOCH_W),
    .REGION_COUNT(REGION_COUNT),
    .REGION_INDEX_W(REGION_INDEX_W),
    .REGION_ENABLE(4'b1111),
    .REGION_BASE(STATIC_REGION_BASE),
    .REGION_MASK(STATIC_REGION_MASK),
    .REGION_ENDPOINT(STATIC_REGION_ENDPOINT),
    .REGION_READ_OK(4'b1111),
    .REGION_WRITE_OK(4'b1111),
    .REGION_EXECUTE_OK(4'b0000),
    .REGION_IDEMPOTENT(4'b1011)
  ) u_dut (
    .clk_i,
    .rst_ni,
    .dmem_req_valid_i,
    .dmem_req_ready_o,
    .dmem_req_op_i,
    .dmem_req_eaddr_i,
    .dmem_req_addr_space_i,
    .dmem_req_addr_context_i,
    .dmem_req_wdata_i,
    .dmem_req_wstrb_i,
    .dmem_rsp_valid_o,
    .dmem_rsp_ready_i,
    .dmem_rsp_rdata_o,
    .dmem_rsp_fault_cause_o,
    .i_tr_req_valid_i(1'b0),
    .i_tr_req_ready_o(i_tr_req_ready),
    .i_tr_req_vaddr_i(32'b0),
    .i_tr_req_addr_context_i(8'b0),
    .i_tr_req_access_i(VSP_MEM_ACCESS_FETCH),
    .i_tr_rsp_valid_o(i_tr_rsp_valid),
    .i_tr_rsp_ready_i(1'b1),
    .i_tr_rsp_paddr_o(i_tr_rsp_paddr),
    .i_tr_rsp_fault_o(i_tr_rsp_fault),
    .i_tr_rsp_fault_vaddr_o(i_tr_rsp_fault_vaddr),
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
    .tlb_inv_req_valid_i,
    .tlb_inv_req_ready_o,
    .tlb_inv_req_scope_i,
    .tlb_inv_req_asid_i,
    .tlb_inv_req_vaddr_i,
    .tlb_inv_rsp_valid_o,
    .tlb_inv_rsp_ready_i,
    .tlb_inv_rsp_status_o,
    .ptw_mem_req_valid_o(ptw_mem_req_valid),
    .ptw_mem_req_ready_i(ptw_mem_req_ready),
    .ptw_mem_req_paddr_o(ptw_mem_req_paddr),
    .ptw_mem_rsp_valid_i(ptw_mem_rsp_valid_q),
    .ptw_mem_rsp_ready_o(ptw_mem_rsp_ready),
    .ptw_mem_rsp_rdata_i(ptw_mem_rsp_rdata_q),
    .ptw_mem_rsp_fault_i(ptw_mem_rsp_fault_q),
    .ptw_pte_fault_paddr_valid_o,
    .ptw_pte_fault_paddr_o,
    .cache_req_valid_o(cache_req_valid),
    .cache_req_ready_i(cache_req_ready),
    .cache_req_access_o(cache_req_access),
    .cache_req_eaddr_o(cache_req_eaddr),
    .cache_req_paddr_o(cache_req_paddr),
    .cache_req_wdata_o(cache_req_wdata),
    .cache_req_wstrb_o(cache_req_wstrb),
    .cache_rsp_valid_i(cache_rsp_valid),
    .cache_rsp_ready_o(cache_rsp_ready),
    .cache_rsp_rdata_i(cache_rsp_rdata),
    .cache_rsp_fault_cause_i(cache_rsp_fault),
    .local_req_valid_o(local_req_valid),
    .local_req_ready_i(local_req_ready),
    .local_req_op_o(local_req_op),
    .local_req_addr_o(local_req_addr),
    .local_req_wdata_o(local_req_wdata),
    .local_req_wstrb_o(local_req_wstrb),
    .local_rsp_valid_i(local_rsp_valid),
    .local_rsp_ready_o(local_rsp_ready),
    .local_rsp_rdata_i(local_rsp_rdata),
    .local_rsp_fault_cause_i(local_rsp_fault),
    .uncached_req_valid_o(uncached_req_valid),
    .uncached_req_ready_i(uncached_req_ready),
    .uncached_req_op_o(uncached_req_op),
    .uncached_req_addr_o(uncached_req_addr),
    .uncached_req_wdata_o(uncached_req_wdata),
    .uncached_req_wstrb_o(uncached_req_wstrb),
    .uncached_rsp_valid_i(uncached_rsp_valid),
    .uncached_rsp_ready_o(uncached_rsp_ready),
    .uncached_rsp_rdata_i(uncached_rsp_rdata),
    .uncached_rsp_fault_cause_i(uncached_rsp_fault),
    .device_req_valid_o(device_req_valid),
    .device_req_ready_i(device_req_ready),
    .device_req_op_o(device_req_op),
    .device_req_addr_o(device_req_addr),
    .device_req_wdata_o(device_req_wdata),
    .device_req_wstrb_o(device_req_wstrb),
    .device_rsp_valid_i(device_rsp_valid),
    .device_rsp_ready_o(device_rsp_ready),
    .device_rsp_rdata_i(device_rsp_rdata),
    .device_rsp_fault_cause_i(device_rsp_fault),
    .barrier_valid_i(1'b0),
    .barrier_ready_o(barrier_ready),
    .barrier_op_i(VSP_MEM_BARRIER_DRAIN),
    .barrier_eaddr_i(32'b0),
    .barrier_context_i(8'b0),
    .barrier_rsp_valid_o(barrier_rsp_valid),
    .barrier_rsp_ready_i(1'b1),
    .barrier_rsp_status_o(barrier_rsp_status),
    .policy_maint_req_valid_o(policy_maint_req_valid),
    .policy_maint_req_ready_i(1'b1),
    .policy_maint_req_op_o(policy_maint_req_op),
    .policy_maint_req_eaddr_o(policy_maint_req_eaddr),
    .policy_maint_req_context_o(policy_maint_req_context),
    .policy_maint_rsp_valid_i(1'b0),
    .policy_maint_rsp_ready_o(policy_maint_rsp_ready),
    .policy_maint_rsp_fault_i(VSP_MEM_FAULT_NONE),
    .lsu_idle_o,
    .lsu_busy_o,
    .space_router_idle_o,
    .region_router_idle_o,
    .region_config_overlap_o,
    .region_diag_rsp_valid_o,
    .region_diag_match_valid_o,
    .region_diag_match_index_o,
    .region_diag_overlap_o,
    .region_diag_endpoint_valid_o,
    .region_diag_endpoint_o,
    .region_diag_fault_o,
    .mmu_init_done_o,
    .mmu_quiescent_o,
    .mmu_busy_o,
    .i_tlb_epoch_o,
    .d_tlb_epoch_o,
    .i_tlb_epoch_exhausted_o,
    .d_tlb_epoch_exhausted_o,
    .internal_quiescent_o,
    .internal_busy_o,
    .protocol_error_clear_i,
    .lsu_protocol_error_o,
    .mmu_protocol_error_o,
    .protocol_error_o
  );

  // These interfaces are intentionally inactive in the D-side integration
  // harness.  Consume their outputs explicitly so strict lint distinguishes
  // deliberate ties from accidental omissions.
  /* verilator lint_off UNUSED */
  wire unused_sideband_outputs = &{
    1'b0,
    i_tr_req_ready,
    i_tr_rsp_valid,
    i_tr_rsp_paddr,
    i_tr_rsp_fault,
    i_tr_rsp_fault_vaddr,
    barrier_ready,
    barrier_rsp_valid,
    barrier_rsp_status,
    policy_maint_req_valid,
    policy_maint_req_op,
    policy_maint_req_eaddr,
    policy_maint_req_context,
    policy_maint_rsp_ready
  };
  /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
