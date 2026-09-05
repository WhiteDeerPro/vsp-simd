// SPDX-License-Identifier: MIT

`default_nettype none

// Exercise the production register target with an independently controlled
// core/management peer. No execution or memory-system RTL is substituted.
module vsp_host_control_tb_top (
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

  output logic start_valid_o,
  input  logic start_ready_i,
  output logic [31:0] start_pc_o,
  output logic [31:0] end_pc_o,
  output logic [3:0] start_group_mask_o,
  output logic [7:0] start_tag_seed_o,
  output logic [1:0] start_ifetch_addr_space_o,
  output logic [7:0] start_ifetch_addr_context_o,
  input  logic [31:0] fetch_pc_i,
  input  logic program_active_i,
  input  logic program_done_i,
  input  logic program_failed_i,
  input  logic program_error_i,
  input  logic [31:0] program_terminal_pc_i,
  input  logic system_ready_i,
  input  logic system_quiescent_i,
  input  logic system_busy_i,

  input  logic ifetch_fault_valid_i,
  input  logic [2:0] ifetch_fault_cause_i,
  input  logic [31:0] ifetch_fault_eaddr_i,
  input  logic [39:0] ifetch_fault_paddr_i,
  input  logic [1:0] ifetch_fault_addr_space_i,
  input  logic [7:0] ifetch_fault_addr_context_i,
  input  logic action_cpl_valid_i,
  output logic action_cpl_ready_o,
  input  logic [1:0] action_cpl_class_i,
  input  logic [7:0] action_cpl_tag_i,
  input  logic [2:0] action_cpl_status_i,
  input  logic [3:0] action_cpl_decode_error_i,
  input  logic action_cpl_memory_op_i,
  input  logic [2:0] action_cpl_memory_status_i,
  input  logic [2:0] action_cpl_memory_fault_cause_i,
  input  logic [31:0] action_cpl_memory_fault_eaddr_i,
  input  logic [3:0] action_cpl_memory_requested_group_mask_i,
  input  logic [3:0] action_cpl_memory_completed_group_mask_i,
  input  logic [3:0] action_cpl_memory_failed_group_mask_i,
  input  logic [4:0] action_cpl_memory_bytes_committed_i,
  input  logic action_cpl_memory_partial_i,
  output logic exec_result_ready_o,

  output logic mmu_cfg_valid_o,
  input  logic mmu_cfg_ready_i,
  output logic mmu_cfg_write_o,
  output logic [7:0] mmu_cfg_context_o,
  output logic [3:0] mmu_cfg_field_o,
  output logic [31:0] mmu_cfg_wdata_o,
  input  logic mmu_cfg_rsp_valid_i,
  output logic mmu_cfg_rsp_ready_o,
  input  logic [31:0] mmu_cfg_rsp_rdata_i,
  input  logic [2:0] mmu_cfg_rsp_status_i,

  output logic maint_cmd_valid_o,
  input  logic maint_cmd_ready_i,
  output logic [3:0] maint_cmd_op_o,
  output logic [31:0] maint_cmd_eaddr_o,
  output logic [39:0] maint_cmd_paddr_o,
  output logic [7:0] maint_cmd_addr_context_o,
  output logic [8:0] maint_cmd_asid_o,
  input  logic maint_cpl_valid_i,
  output logic maint_cpl_ready_o,
  input  logic maint_cpl_status_i,
  input  logic [2:0] maint_cpl_fault_i,
  output logic protocol_error_clear_o
);
  vsp_host_control #(
    .GROUP_COUNT(4), .PADDR_W(40), .TAG_W(8), .ASID_W(9),
    .DECODE_ERROR_W(4), .SPAN_BYTES_W(5)
  ) u_dut (.*);
endmodule

`default_nettype wire
