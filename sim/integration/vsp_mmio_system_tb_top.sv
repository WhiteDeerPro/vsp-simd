// SPDX-License-Identifier: MIT
`default_nettype none

// CPU behavior is modeled by the public MMIO port. The sideband SRAM loader
// represents the host preparing shared memory, not access to private VSP RFs.
module vsp_mmio_system_tb_top (
  input  logic clk_i,
  input  logic rst_ni,
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
  input  logic backing_init_valid_i,
  output logic backing_init_ready_o,
  input  logic [39:0] backing_init_paddr_i,
  input  logic [31:0] backing_init_wdata_i,
  input  logic [3:0] backing_init_wstrb_i,
  output logic backing_init_error_o,
  input  logic [39:0] backing_peek_paddr_i,
  output logic [31:0] backing_peek_rdata_o,
  output logic backing_peek_error_o,
  output logic [31:0] lower_requests_o,
  output logic [31:0] lower_responses_o,
  output logic system_quiescent_o
);
  import vsp_mem_common_pkg::*;
  logic lower_req_valid, lower_req_ready, lower_req_write;
  logic [39:0] lower_req_paddr;
  logic [31:0] lower_req_wdata;
  logic [3:0] lower_req_wstrb;
  logic lower_rsp_valid, lower_rsp_ready;
  logic [31:0] lower_rsp_rdata;
  logic [vsp_memory_endpoints_pkg::VSP_LOWER_STATUS_W-1:0] lower_rsp_status;
  logic backing_quiescent;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lower_requests_o <= '0;
      lower_responses_o <= '0;
    end else begin
      if (lower_req_valid && lower_req_ready)
        lower_requests_o <= lower_requests_o + 32'd1;
      if (lower_rsp_valid && lower_rsp_ready)
        lower_responses_o <= lower_responses_o + 32'd1;
    end
  end

  /* verilator lint_off PINCONNECTEMPTY */
  vsp_mmio_system_wrapper #(
    .GROUP_COUNT(4),
    .PADDR_W(40),
    .MMU_CONTEXT_COUNT(2),
    .I_TLB_ENTRY_COUNT(2),
    .D_TLB_ENTRY_COUNT(4),
    .TLB_EPOCH_W(8),
    .REGION_COUNT(4),
    .REGION_ENABLE(4'b0011),
    .REGION_BASE({40'd0, 40'd0, 40'h1000, 40'd0}),
    .REGION_MASK({40'd0, 40'd0, 40'hfffffff000, 40'hfffffff000}),
    .REGION_ENDPOINT({4{VSP_MEM_ENDPOINT_CACHEABLE}}),
    .REGION_READ_OK(4'b0010),
    .REGION_WRITE_OK(4'b0010),
    .REGION_EXECUTE_OK(4'b0001),
    .REGION_IDEMPOTENT(4'b0011),
    .ICACHE_SET_COUNT(4),
    .DCACHE_SET_COUNT(4),
    .LOCAL_DEPTH_WORDS(256)
  ) u_dut (
    .clk_i, .rst_ni,
    .mmio_req_valid_i, .mmio_req_ready_o, .mmio_req_write_i,
    .mmio_req_addr_i, .mmio_req_wdata_i, .mmio_req_wstrb_i,
    .mmio_rsp_valid_o, .mmio_rsp_ready_i, .mmio_rsp_rdata_o,
    .mmio_rsp_error_o, .irq_o,
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
    .system_ready_o(), .system_quiescent_o, .system_busy_o()
  );

  vsp_fabric_ordered_sram #(
    .PADDR_W(40), .DATA_W(32), .BASE_ADDR(40'd0),
    .DEPTH_BEATS(4096), .INIT_FILE("")
  ) u_shared_memory (
    .clk_i, .rst_ni,
    .req_valid_i(lower_req_valid), .req_ready_o(lower_req_ready),
    .req_write_i(lower_req_write), .req_paddr_i(lower_req_paddr),
    .req_wdata_i(lower_req_wdata), .req_wstrb_i(lower_req_wstrb),
    .rsp_valid_o(lower_rsp_valid), .rsp_ready_i(lower_rsp_ready),
    .rsp_rdata_o(lower_rsp_rdata), .rsp_status_o(lower_rsp_status),
    .idle_o(), .quiescent_o(backing_quiescent),
    .init_valid_i(backing_init_valid_i), .init_ready_o(backing_init_ready_o),
    .init_paddr_i(backing_init_paddr_i), .init_wdata_i(backing_init_wdata_i),
    .init_wstrb_i(backing_init_wstrb_i), .init_error_o(backing_init_error_o),
    .peek_paddr_i(backing_peek_paddr_i), .peek_rdata_o(backing_peek_rdata_o),
    .peek_error_o(backing_peek_error_o)
  );
  /* verilator lint_on PINCONNECTEMPTY */
endmodule
`default_nettype wire
