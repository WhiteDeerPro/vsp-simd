// SPDX-License-Identifier: MIT

`default_nettype none

// Focused integration harness for the UNCACHED/DEVICE fixed-beat merge.
// This wrapper intentionally adds no buffering or response model: the C++
// test drives both sides directly so arbitration-lock and ownership behavior
// remain observable cycle by cycle.
module vsp_uncached_device_merge_tb_top #(
  parameter integer ADDR_W = 16
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                  uncached_req_valid_i,
  output logic                  uncached_req_ready_o,
  input  logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_OP_W-1:0]
                                 uncached_req_op_i,
  input  logic [ADDR_W-1:0]     uncached_req_addr_i,
  input  logic [31:0]           uncached_req_wdata_i,
  input  logic [3:0]            uncached_req_wstrb_i,
  output logic                  uncached_rsp_valid_o,
  input  logic                  uncached_rsp_ready_i,
  output logic [31:0]           uncached_rsp_rdata_o,
  output logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_FAULT_W-1:0]
                                 uncached_rsp_fault_cause_o,

  input  logic                  device_req_valid_i,
  output logic                  device_req_ready_o,
  input  logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_OP_W-1:0]
                                 device_req_op_i,
  input  logic [ADDR_W-1:0]     device_req_addr_i,
  input  logic [31:0]           device_req_wdata_i,
  input  logic [3:0]            device_req_wstrb_i,
  output logic                  device_rsp_valid_o,
  input  logic                  device_rsp_ready_i,
  output logic [31:0]           device_rsp_rdata_o,
  output logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_FAULT_W-1:0]
                                 device_rsp_fault_cause_o,

  output logic                  shared_req_valid_o,
  input  logic                  shared_req_ready_i,
  output logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_OP_W-1:0]
                                 shared_req_op_o,
  output logic [ADDR_W-1:0]     shared_req_addr_o,
  output logic [31:0]           shared_req_wdata_o,
  output logic [3:0]            shared_req_wstrb_o,
  input  logic                  shared_rsp_valid_i,
  output logic                  shared_rsp_ready_o,
  input  logic [31:0]           shared_rsp_rdata_i,
  input  logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_FAULT_W-1:0]
                                 shared_rsp_fault_cause_i,

  output logic                  idle_o,
  output logic                  protocol_error_o,
  input  logic                  protocol_error_clear_i
);

  vsp_uncached_device_merge #(
    .ADDR_W(ADDR_W)
  ) u_dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .uncached_req_valid_i(uncached_req_valid_i),
    .uncached_req_ready_o(uncached_req_ready_o),
    .uncached_req_op_i(uncached_req_op_i),
    .uncached_req_addr_i(uncached_req_addr_i),
    .uncached_req_wdata_i(uncached_req_wdata_i),
    .uncached_req_wstrb_i(uncached_req_wstrb_i),
    .uncached_rsp_valid_o(uncached_rsp_valid_o),
    .uncached_rsp_ready_i(uncached_rsp_ready_i),
    .uncached_rsp_rdata_o(uncached_rsp_rdata_o),
    .uncached_rsp_fault_cause_o(uncached_rsp_fault_cause_o),
    .device_req_valid_i(device_req_valid_i),
    .device_req_ready_o(device_req_ready_o),
    .device_req_op_i(device_req_op_i),
    .device_req_addr_i(device_req_addr_i),
    .device_req_wdata_i(device_req_wdata_i),
    .device_req_wstrb_i(device_req_wstrb_i),
    .device_rsp_valid_o(device_rsp_valid_o),
    .device_rsp_ready_i(device_rsp_ready_i),
    .device_rsp_rdata_o(device_rsp_rdata_o),
    .device_rsp_fault_cause_o(device_rsp_fault_cause_o),
    .shared_req_valid_o(shared_req_valid_o),
    .shared_req_ready_i(shared_req_ready_i),
    .shared_req_op_o(shared_req_op_o),
    .shared_req_addr_o(shared_req_addr_o),
    .shared_req_wdata_o(shared_req_wdata_o),
    .shared_req_wstrb_o(shared_req_wstrb_o),
    .shared_rsp_valid_i(shared_rsp_valid_i),
    .shared_rsp_ready_o(shared_rsp_ready_o),
    .shared_rsp_rdata_i(shared_rsp_rdata_i),
    .shared_rsp_fault_cause_i(shared_rsp_fault_cause_i),
    .idle_o(idle_o),
    .protocol_error_o(protocol_error_o),
    .protocol_error_clear_i(protocol_error_clear_i)
  );

endmodule

`default_nettype wire
