// SPDX-License-Identifier: MIT

`default_nettype none

// Merge the final-physical UNCACHED and DEVICE endpoint channels onto the
// single fixed-beat master implemented by vsp_physical_fabric.
//
// The two classes deliberately keep separate request/response channels above
// this block so region policy and architectural diagnostics remain visible.
// Below the block they share the same strictly ordered, non-prefetching access
// semantics; the physical address remains available to the SoC's lower decode
// to distinguish ordinary memory from MMIO.
//
// Only one merged request may be outstanding.  A stalled arbitration grant is
// locked until request acceptance; the accepted source then owns the shared
// response until that response is consumed.  This is required even though the
// current LSU is also single-outstanding: neither request stability nor
// response ownership may depend on later live request-valid signals.
module vsp_uncached_device_merge #(
  parameter integer ADDR_W = 40
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic uncached_req_valid_i,
  output logic uncached_req_ready_o,
  input  logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_OP_W-1:0]
               uncached_req_op_i,
  input  logic [ADDR_W-1:0] uncached_req_addr_i,
  input  logic [31:0] uncached_req_wdata_i,
  input  logic [3:0] uncached_req_wstrb_i,
  output logic uncached_rsp_valid_o,
  input  logic uncached_rsp_ready_i,
  output logic [31:0] uncached_rsp_rdata_o,
  output logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_FAULT_W-1:0]
               uncached_rsp_fault_cause_o,

  input  logic device_req_valid_i,
  output logic device_req_ready_o,
  input  logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_OP_W-1:0]
               device_req_op_i,
  input  logic [ADDR_W-1:0] device_req_addr_i,
  input  logic [31:0] device_req_wdata_i,
  input  logic [3:0] device_req_wstrb_i,
  output logic device_rsp_valid_o,
  input  logic device_rsp_ready_i,
  output logic [31:0] device_rsp_rdata_o,
  output logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_FAULT_W-1:0]
               device_rsp_fault_cause_o,

  output logic shared_req_valid_o,
  input  logic shared_req_ready_i,
  output logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_OP_W-1:0]
               shared_req_op_o,
  output logic [ADDR_W-1:0] shared_req_addr_o,
  output logic [31:0] shared_req_wdata_o,
  output logic [3:0] shared_req_wstrb_o,
  input  logic shared_rsp_valid_i,
  output logic shared_rsp_ready_o,
  input  logic [31:0] shared_rsp_rdata_i,
  input  logic [vsp_memory_endpoints_pkg::VSP_ENDPOINT_FAULT_W-1:0]
               shared_rsp_fault_cause_i,

  output logic idle_o,
  output logic protocol_error_o,
  input  logic protocol_error_clear_i
);
  import vsp_memory_endpoints_pkg::*;

  typedef enum logic {
    OWNER_UNCACHED,
    OWNER_DEVICE
  } owner_e;

  logic owner_valid_q;
  owner_e owner_q;
  logic grant_locked_q;
  owner_e grant_owner_q;
  logic select_device;
  logic shared_req_fire;
  logic shared_rsp_fire;
  logic overlapping_requests;
  logic orphan_response;

  initial begin : p_parameter_guards
    if (ADDR_W < 2)
      $fatal(1, "vsp_uncached_device_merge: ADDR_W must be at least 2");
    if (VSP_ENDPOINT_OP_W != 1)
      $fatal(1, "vsp_uncached_device_merge: unsupported endpoint op width");
    if (VSP_ENDPOINT_FAULT_W != 3)
      $fatal(1, "vsp_uncached_device_merge: unsupported endpoint fault width");
  end

  // UNCACHED wins only in the illegal case where both sources present a new
  // request together.  The overlap is diagnosed and DEVICE remains stalled;
  // no request is duplicated or silently accepted twice.
  // Once a shared request has been presented without being accepted, retain
  // that source selection until handshake.  This is an arbitration lock (the
  // source still owns and must hold its payload), not an extra request queue.
  // It prevents a newly arriving higher-priority source from changing the
  // shared payload under downstream backpressure.
  assign select_device = grant_locked_q ?
      (grant_owner_q == OWNER_DEVICE) :
      (!uncached_req_valid_i && device_req_valid_i);
  assign shared_req_valid_o = rst_ni && !owner_valid_q &&
      (select_device ? device_req_valid_i : uncached_req_valid_i);
  assign shared_req_op_o = select_device ? device_req_op_i :
                                           uncached_req_op_i;
  assign shared_req_addr_o = select_device ? device_req_addr_i :
                                             uncached_req_addr_i;
  assign shared_req_wdata_o = select_device ? device_req_wdata_i :
                                              uncached_req_wdata_i;
  assign shared_req_wstrb_o = select_device ? device_req_wstrb_i :
                                              uncached_req_wstrb_i;

  assign uncached_req_ready_o = rst_ni && !owner_valid_q &&
                                 !select_device &&
                                 uncached_req_valid_i &&
                                 shared_req_ready_i;
  assign device_req_ready_o = rst_ni && !owner_valid_q &&
                               select_device &&
                               device_req_valid_i && shared_req_ready_i;

  assign uncached_rsp_valid_o = rst_ni && owner_valid_q &&
                                (owner_q == OWNER_UNCACHED) &&
                                shared_rsp_valid_i;
  assign device_rsp_valid_o = rst_ni && owner_valid_q &&
                              (owner_q == OWNER_DEVICE) &&
                              shared_rsp_valid_i;
  assign uncached_rsp_rdata_o = shared_rsp_rdata_i;
  assign device_rsp_rdata_o = shared_rsp_rdata_i;
  assign uncached_rsp_fault_cause_o = shared_rsp_fault_cause_i;
  assign device_rsp_fault_cause_o = shared_rsp_fault_cause_i;

  // Consume an impossible orphan so a broken child cannot wedge the shared
  // response channel.  The sticky diagnostic preserves evidence of it.
  assign shared_rsp_ready_o = !owner_valid_q ? 1'b1 :
      ((owner_q == OWNER_DEVICE) ? device_rsp_ready_i :
                                   uncached_rsp_ready_i);

  assign shared_req_fire = shared_req_valid_o && shared_req_ready_i;
  assign shared_rsp_fire = shared_rsp_valid_i && shared_rsp_ready_o;
  assign overlapping_requests = !owner_valid_q && uncached_req_valid_i &&
                                device_req_valid_i;
  assign orphan_response = shared_rsp_valid_i && !owner_valid_q;
  assign idle_o = !owner_valid_q && !grant_locked_q && !shared_req_valid_o &&
                  !shared_rsp_valid_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_owner
    if (!rst_ni) begin
      owner_valid_q <= 1'b0;
      owner_q <= OWNER_UNCACHED;
      grant_locked_q <= 1'b0;
      grant_owner_q <= OWNER_UNCACHED;
      protocol_error_o <= 1'b0;
    end else begin
      if (protocol_error_clear_i)
        protocol_error_o <= 1'b0;

      if (overlapping_requests || orphan_response)
        protocol_error_o <= 1'b1;

      if (shared_req_fire) begin
        owner_valid_q <= 1'b1;
        owner_q <= select_device ? OWNER_DEVICE : OWNER_UNCACHED;
        grant_locked_q <= 1'b0;
      end else if (!owner_valid_q && shared_req_valid_o &&
                   !shared_req_ready_i && !grant_locked_q) begin
        grant_locked_q <= 1'b1;
        grant_owner_q <= select_device ? OWNER_DEVICE : OWNER_UNCACHED;
      end

      if (shared_rsp_fire && owner_valid_q)
        owner_valid_q <= 1'b0;
    end
  end

`ifndef SYNTHESIS
  logic stalled_req_q;
  logic [VSP_ENDPOINT_OP_W-1:0] stalled_op_q;
  logic [ADDR_W-1:0] stalled_addr_q;
  logic [31:0] stalled_wdata_q;
  logic [3:0] stalled_wstrb_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_assertions
    if (!rst_ni) begin
      stalled_req_q <= 1'b0;
      stalled_op_q <= VSP_ENDPOINT_OP_LOAD;
      stalled_addr_q <= '0;
      stalled_wdata_q <= '0;
      stalled_wstrb_q <= '0;
    end else begin
      assert (!(uncached_req_ready_o && device_req_ready_o))
        else $error("vsp_uncached_device_merge: accepted two request owners");
      assert (!(uncached_rsp_valid_o && device_rsp_valid_o))
        else $error("vsp_uncached_device_merge: exposed response to two owners");

      if (stalled_req_q) begin
        assert (shared_req_valid_o)
          else $error("vsp_uncached_device_merge: shared request valid dropped while stalled");
        assert ((shared_req_op_o === stalled_op_q) &&
                (shared_req_addr_o === stalled_addr_q) &&
                (shared_req_wdata_o === stalled_wdata_q) &&
                (shared_req_wstrb_o === stalled_wstrb_q))
          else $error("vsp_uncached_device_merge: shared request changed while stalled");
      end

      stalled_req_q <= shared_req_valid_o && !shared_req_ready_i;
      if (shared_req_valid_o && !shared_req_ready_i) begin
        stalled_op_q <= shared_req_op_o;
        stalled_addr_q <= shared_req_addr_o;
        stalled_wdata_q <= shared_req_wdata_o;
        stalled_wstrb_q <= shared_req_wstrb_o;
      end
    end
  end
`endif

endmodule

`default_nettype wire
