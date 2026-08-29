module vsp_ordered_dmem_model #(
  // Behavioral byte-addressed endpoint for the canonical dmem request/
  // response contract.  It is useful as a simulation/bring-up memory and as
  // an executable specification for a later SRAM/cache adapter; it is not a
  // cache, MMU, DMA engine, or timing model of a specific memory macro.
  parameter int MEM_EADDR_W = 32,
  parameter int BEAT_BYTES = 4,
  parameter int MEM_BYTES = 4096,
  parameter logic [MEM_EADDR_W-1:0] BASE_EADDR = '0,
  parameter int ADDR_CONTEXT_W = 8,
  parameter int OUTSTANDING_DEPTH = 4,
  // Responses are always returned in request order.  A request accepted at
  // edge N becomes eligible no earlier than edge N + RESPONSE_LATENCY.
  parameter int RESPONSE_LATENCY = 2,
  // Bit n permits address-space encoding n to access this backing array.
  // The default accepts LOCAL only.  Unsupported TRANSLATED requests report
  // TRANSLATION; other unsupported spaces report ACCESS.
  parameter logic [3:0] ACCEPT_ADDR_SPACE_MASK = 4'b0001,
  parameter int OUTSTANDING_COUNT_W = (OUTSTANDING_DEPTH <= 1) ? 1 :
                                      $clog2(OUTSTANDING_DEPTH + 1)
) (
  input  logic clk_i,
  // Reset discards queued responses but deliberately retains backing bytes,
  // matching an SRAM-like data lifetime.
  input  logic rst_ni,

  input  logic                              req_valid_i,
  output logic                              req_ready_o,
  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0] req_op_i,
  input  logic [MEM_EADDR_W-1:0]            req_eaddr_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                               req_addr_space_i,
  input  logic [ADDR_CONTEXT_W-1:0]         req_addr_context_i,
  input  logic [(BEAT_BYTES*8)-1:0]         req_wdata_i,
  input  logic [BEAT_BYTES-1:0]             req_wstrb_i,

  output logic                              rsp_valid_o,
  input  logic                              rsp_ready_i,
  output logic [(BEAT_BYTES*8)-1:0]         rsp_rdata_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                               rsp_fault_cause_o,

  // Simulation/bring-up sideband.  It is intentionally separate from dmem
  // so test code can initialize and inspect the backing bytes without
  // pretending those accesses were issued by the VSP.
  input  logic                              init_valid_i,
  output logic                              init_ready_o,
  input  logic [MEM_EADDR_W-1:0]            init_eaddr_i,
  input  logic [(BEAT_BYTES*8)-1:0]         init_wdata_i,
  input  logic [BEAT_BYTES-1:0]             init_wstrb_i,
  output logic                              init_error_o,

  input  logic [MEM_EADDR_W-1:0]            peek_eaddr_i,
  output logic [(BEAT_BYTES*8)-1:0]         peek_rdata_o,
  output logic                              peek_error_o,

  output logic [OUTSTANDING_COUNT_W-1:0]    outstanding_count_o,
  output logic                              idle_o
);
  import vsp_pkg::*;

  localparam int DATA_W = BEAT_BYTES * 8;
  localparam int QUEUE_PTR_W = (OUTSTANDING_DEPTH <= 2) ? 1 :
                               $clog2(OUTSTANDING_DEPTH);
  localparam int LATENCY_W = (RESPONSE_LATENCY <= 1) ? 1 :
                             $clog2(RESPONSE_LATENCY + 1);

  logic [7:0] memory_q [MEM_BYTES];

  logic [DATA_W-1:0] response_data_q [OUTSTANDING_DEPTH];
  logic [VSP_MEM_FAULT_CAUSE_W-1:0]
      response_fault_q [OUTSTANDING_DEPTH];
  logic [LATENCY_W-1:0] response_delay_q [OUTSTANDING_DEPTH];
  logic response_valid_q [OUTSTANDING_DEPTH];
  logic [QUEUE_PTR_W-1:0] head_q;
  logic [QUEUE_PTR_W-1:0] tail_q;
  logic [OUTSTANDING_COUNT_W-1:0] outstanding_count_q;

  logic [MEM_EADDR_W:0] request_delta;
  logic [MEM_EADDR_W:0] request_end_delta;
  logic request_aligned;
  logic request_range_ok;
  logic request_space_ok;
  logic request_shape_ok;
  logic [VSP_MEM_FAULT_CAUSE_W-1:0] request_fault;
  logic [DATA_W-1:0] request_read_data;

  logic [MEM_EADDR_W:0] init_delta;
  logic [MEM_EADDR_W:0] init_end_delta;
  logic init_address_ok;
  logic [MEM_EADDR_W:0] peek_delta;
  logic [MEM_EADDR_W:0] peek_end_delta;
  logic peek_address_ok;

  logic request_fire;
  logic response_fire;
  logic init_fire;

  integer byte_index;
  integer queue_index;

  function automatic logic [QUEUE_PTR_W-1:0] next_queue_ptr(
      input logic [QUEUE_PTR_W-1:0] pointer);
    if (int'(pointer) == (OUTSTANDING_DEPTH - 1))
      next_queue_ptr = '0;
    else
      next_queue_ptr = pointer + QUEUE_PTR_W'(1);
  endfunction

  always_comb begin
    request_delta = {1'b0, req_eaddr_i} - {1'b0, BASE_EADDR};
    request_end_delta = request_delta + (MEM_EADDR_W+1)'(BEAT_BYTES);
    request_aligned =
        (req_eaddr_i & MEM_EADDR_W'(BEAT_BYTES - 1)) == '0;
    request_range_ok = !request_delta[MEM_EADDR_W] &&
        (request_end_delta <= (MEM_EADDR_W+1)'(MEM_BYTES));
    request_space_ok = ACCEPT_ADDR_SPACE_MASK[int'(req_addr_space_i)];
    request_shape_ok =
        ((req_op_i == VSP_MEM_OP_LOAD) && !(|req_wstrb_i)) ||
        ((req_op_i == VSP_MEM_OP_STORE) && (|req_wstrb_i));

    request_fault = VSP_MEM_FAULT_NONE;
    if (!request_space_ok) begin
      request_fault =
          (req_addr_space_i == VSP_MEM_ADDR_SPACE_TRANSLATED) ?
              VSP_MEM_FAULT_TRANSLATION : VSP_MEM_FAULT_ACCESS;
    end else if (!request_aligned || !request_range_ok) begin
      request_fault = VSP_MEM_FAULT_ACCESS;
    end else if (!request_shape_ok) begin
      request_fault = VSP_MEM_FAULT_PROTOCOL;
    end

    request_read_data = '0;
    if ((request_fault == VSP_MEM_FAULT_NONE) &&
        (req_op_i == VSP_MEM_OP_LOAD)) begin
      for (byte_index = 0; byte_index < BEAT_BYTES;
           byte_index = byte_index + 1) begin
        request_read_data[(byte_index*8) +: 8] =
            memory_q[int'(request_delta) + byte_index];
      end
    end
  end

  always_comb begin
    init_delta = {1'b0, init_eaddr_i} - {1'b0, BASE_EADDR};
    init_end_delta = init_delta + (MEM_EADDR_W+1)'(BEAT_BYTES);
    init_address_ok =
        !init_delta[MEM_EADDR_W] &&
        (init_end_delta <= (MEM_EADDR_W+1)'(MEM_BYTES)) &&
        ((init_eaddr_i & MEM_EADDR_W'(BEAT_BYTES - 1)) == '0);
    init_error_o = init_valid_i && !init_address_ok;

    peek_delta = {1'b0, peek_eaddr_i} - {1'b0, BASE_EADDR};
    peek_end_delta = peek_delta + (MEM_EADDR_W+1)'(BEAT_BYTES);
    peek_address_ok =
        !peek_delta[MEM_EADDR_W] &&
        (peek_end_delta <= (MEM_EADDR_W+1)'(MEM_BYTES)) &&
        ((peek_eaddr_i & MEM_EADDR_W'(BEAT_BYTES - 1)) == '0);
    peek_error_o = !peek_address_ok;
    peek_rdata_o = '0;
    if (peek_address_ok) begin
      for (byte_index = 0; byte_index < BEAT_BYTES;
           byte_index = byte_index + 1) begin
        peek_rdata_o[(byte_index*8) +: 8] =
            memory_q[int'(peek_delta) + byte_index];
      end
    end
  end

  assign rsp_valid_o = rst_ni && (outstanding_count_q != 0) &&
                       response_valid_q[head_q] &&
                       (response_delay_q[head_q] == 0);
  assign rsp_rdata_o = response_data_q[head_q];
  assign rsp_fault_cause_o = response_fault_q[head_q];
  assign response_fire = rsp_valid_o && rsp_ready_i;

  // A full queue may accept a replacement in the same cycle that its head
  // response transfers.  No request ID is required because retirement is
  // strictly FIFO ordered.
  assign req_ready_o = rst_ni &&
      ((int'(outstanding_count_q) < OUTSTANDING_DEPTH) || response_fire);
  assign request_fire = req_valid_i && req_ready_o;

  // A held dmem request blocks initialization, keeping the model sideband
  // from changing memory underneath a not-yet-accepted architectural access.
  assign init_ready_o = rst_ni && !req_valid_i;
  assign init_fire = init_valid_i && init_ready_o && init_address_ok;

  assign outstanding_count_o = outstanding_count_q;
  assign idle_o = outstanding_count_q == 0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      head_q <= '0;
      tail_q <= '0;
      outstanding_count_q <= '0;
      for (queue_index = 0; queue_index < OUTSTANDING_DEPTH;
           queue_index = queue_index + 1) begin
        response_data_q[queue_index] <= '0;
        response_fault_q[queue_index] <= VSP_MEM_FAULT_NONE;
        response_delay_q[queue_index] <= '0;
        response_valid_q[queue_index] <= 1'b0;
      end
    end else begin
      for (queue_index = 0; queue_index < OUTSTANDING_DEPTH;
           queue_index = queue_index + 1) begin
        if (response_valid_q[queue_index] &&
            (response_delay_q[queue_index] != 0)) begin
          response_delay_q[queue_index] <=
              response_delay_q[queue_index] - LATENCY_W'(1);
        end
      end

      if (response_fire) begin
        response_valid_q[head_q] <= 1'b0;
        head_q <= next_queue_ptr(head_q);
      end

      if (request_fire) begin
        response_data_q[tail_q] <= request_read_data;
        response_fault_q[tail_q] <= request_fault;
        response_delay_q[tail_q] <= LATENCY_W'(RESPONSE_LATENCY);
        response_valid_q[tail_q] <= 1'b1;
        tail_q <= next_queue_ptr(tail_q);

        if ((request_fault == VSP_MEM_FAULT_NONE) &&
            (req_op_i == VSP_MEM_OP_STORE)) begin
          for (byte_index = 0; byte_index < BEAT_BYTES;
               byte_index = byte_index + 1) begin
            if (req_wstrb_i[byte_index]) begin
              memory_q[int'(request_delta) + byte_index] <=
                  req_wdata_i[(byte_index*8) +: 8];
            end
          end
        end
      end

      if (init_fire) begin
        for (byte_index = 0; byte_index < BEAT_BYTES;
             byte_index = byte_index + 1) begin
          if (init_wstrb_i[byte_index]) begin
            memory_q[int'(init_delta) + byte_index] <=
                init_wdata_i[(byte_index*8) +: 8];
          end
        end
      end

      unique case ({request_fire, response_fire})
        2'b10: outstanding_count_q <= outstanding_count_q +
                                             OUTSTANDING_COUNT_W'(1);
        2'b01: outstanding_count_q <= outstanding_count_q -
                                             OUTSTANDING_COUNT_W'(1);
        default: outstanding_count_q <= outstanding_count_q;
      endcase
    end
  end

  initial begin
    if (MEM_EADDR_W < 3) $error("MEM_EADDR_W must be at least 3");
    if (BEAT_BYTES < 1 || (BEAT_BYTES & (BEAT_BYTES - 1)) != 0)
      $error("BEAT_BYTES must be a positive power of two");
    if (MEM_BYTES < BEAT_BYTES || (MEM_BYTES % BEAT_BYTES) != 0)
      $error("MEM_BYTES must be a positive multiple of BEAT_BYTES");
    if ((BASE_EADDR & MEM_EADDR_W'(BEAT_BYTES - 1)) != '0)
      $error("BASE_EADDR must be beat aligned");
    if (ADDR_CONTEXT_W < 1) $error("ADDR_CONTEXT_W must be positive");
    if (OUTSTANDING_DEPTH < 1)
      $error("OUTSTANDING_DEPTH must be positive");
    if (RESPONSE_LATENCY < 1)
      $error("RESPONSE_LATENCY must be at least one cycle");
    if ((2**OUTSTANDING_COUNT_W) <= OUTSTANDING_DEPTH)
      $error("OUTSTANDING_COUNT_W cannot represent OUTSTANDING_DEPTH");
  end

  // The local backing model does not interpret the opaque address context.
  // Keep the field on the interface so attaching the model cannot erase the
  // contract expected by a future translation or protection adapter.
  logic unused_addr_context;
  assign unused_addr_context = ^req_addr_context_i;
endmodule
