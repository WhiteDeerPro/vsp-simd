// SPDX-License-Identifier: MIT

`default_nettype none

// Fault/redirect harness around the production I-side client.  MMU responses
// are driven through the public interface; cache initialization is real.
// Disabled regions also allow an ACCESS fault carrying a full 40-bit paddr
// after successful translation, without issuing any lower-memory traffic.
module vsp_ifetch_fault_tb_top (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         source_admit_enable_i,
  input  logic         redirect_commit_i,
  input  logic [7:0]   source_addr_context_i,
  input  logic         source_req_valid_i,
  output logic         source_req_ready_o,
  input  logic [31:0]  source_req_pc_i,
  input  logic [2:0]   source_req_word_count_i,
  output logic         source_rsp_valid_o,
  input  logic         source_rsp_ready_i,
  output logic [127:0] source_rsp_words_o,
  output logic         source_rsp_fault_o,
  output logic [2:0]   source_rsp_fault_cause_o,
  output logic [31:0]  source_rsp_fault_eaddr_o,
  output logic [39:0]  source_rsp_fault_paddr_o,

  output logic         i_tr_req_valid_o,
  input  logic         i_tr_req_ready_i,
  output logic [31:0]  i_tr_req_vaddr_o,
  output logic [7:0]   i_tr_req_addr_context_o,
  output logic [1:0]   i_tr_req_access_o,
  input  logic         i_tr_rsp_valid_i,
  output logic         i_tr_rsp_ready_o,
  input  logic [39:0]  i_tr_rsp_paddr_i,
  input  logic [2:0]   i_tr_rsp_fault_i,
  input  logic [31:0]  i_tr_rsp_fault_vaddr_i,

  output logic         ready_o,
  output logic         quiescent_o,
  output logic         bridge_idle_o,
  output logic         icache_init_done_o,
  output logic         lower_request_o,
  output logic         protocol_error_o
);
  import vsp_mem_common_pkg::*;

  logic ic_mem_cmd_valid;
  logic ic_mem_w_valid;

  assign lower_request_o = ic_mem_cmd_valid || ic_mem_w_valid;

  /* verilator lint_off PINCONNECTEMPTY */
  vsp_ifetch_cached_client_wrapper #(
    .PADDR_W(40),
    .TRANSLATION_ENABLE(1'b1),
    .REGION_COUNT(4),
    .REGION_ENABLE(4'b0000),
    .ICACHE_SET_COUNT(4),
    .ICACHE_WAY_COUNT(2)
  ) u_dut (
    .clk_i,
    .rst_ni,
    .source_admit_enable_i,
    .redirect_commit_i,
    .source_addr_space_i(VSP_MEM_ADDR_SPACE_TRANSLATED),
    .source_addr_context_i,
    .source_req_valid_i,
    .source_req_ready_o,
    .source_req_pc_i,
    .source_req_word_count_i,
    .source_rsp_valid_o,
    .source_rsp_ready_i,
    .source_rsp_words_o,
    .source_rsp_fault_o,
    .source_rsp_fault_cause_o,
    .source_rsp_fault_eaddr_o,
    .source_rsp_fault_paddr_o,
    .i_tr_req_valid_o,
    .i_tr_req_ready_i,
    .i_tr_req_vaddr_o,
    .i_tr_req_addr_context_o,
    .i_tr_req_access_o,
    .i_tr_rsp_valid_i,
    .i_tr_rsp_ready_o,
    .i_tr_rsp_paddr_i,
    .i_tr_rsp_fault_i,
    .i_tr_rsp_fault_vaddr_i,
    .inv_req_valid_i(1'b0),
    .inv_req_ready_o(),
    .inv_req_all_i(1'b0),
    .inv_req_paddr_i('0),
    .inv_rsp_valid_o(),
    .inv_rsp_ready_i(1'b0),
    .inv_rsp_status_o(),
    .ic_mem_cmd_valid_o(ic_mem_cmd_valid),
    .ic_mem_cmd_ready_i(1'b0),
    .ic_mem_cmd_id_o(),
    .ic_mem_cmd_op_o(),
    .ic_mem_cmd_paddr_o(),
    .ic_mem_cmd_beats_o(),
    .ic_mem_w_valid_o(ic_mem_w_valid),
    .ic_mem_w_ready_i(1'b0),
    .ic_mem_w_id_o(),
    .ic_mem_w_data_o(),
    .ic_mem_wstrb_o(),
    .ic_mem_w_last_o(),
    .ic_mem_r_valid_i(1'b0),
    .ic_mem_r_ready_o(),
    .ic_mem_r_id_i('0),
    .ic_mem_r_data_i('0),
    .ic_mem_r_last_i(1'b0),
    .ic_mem_r_status_i(cache_pkg::CACHE_STATUS_OK),
    .ic_mem_r_fault_paddr_i('0),
    .ic_mem_b_valid_i(1'b0),
    .ic_mem_b_ready_o(),
    .ic_mem_b_id_i('0),
    .ic_mem_b_status_i(cache_pkg::CACHE_STATUS_OK),
    .ic_mem_b_fault_paddr_i('0),
    .ready_o,
    .quiescent_o,
    .busy_o(),
    .bridge_idle_o,
    .bridge_busy_o(),
    .ifetch_init_done_o(),
    .ifetch_idle_o(),
    .icache_init_busy_o(),
    .icache_init_done_o,
    .icache_adapter_idle_o(),
    .region_router_idle_o(),
    .region_config_overlap_o(),
    .perf_icache_read_hit_o(),
    .perf_icache_read_miss_o(),
    .protocol_error_clear_i(1'b0),
    .bridge_protocol_error_o(),
    .ifetch_protocol_error_o(),
    .icache_adapter_protocol_error_o(),
    .protocol_error_o
  );
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

`default_nettype wire
