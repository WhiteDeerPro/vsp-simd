module vsp_ordered_ifetch_model #(
  // Read-only, byte-PC addressed endpoint for the logical I-side bundle
  // contract.  It is an executable memory-boundary model, not an I-cache,
  // replacement policy, instruction decoder, or physical SRAM macro.
  parameter int PC_W = 32,
  parameter int WORD_W = 32,
  parameter int MAX_WORDS = 4,
  parameter int MEM_WORDS = 256,
  parameter logic [PC_W-1:0] BASE_PC = '0,
  parameter int ADDR_CONTEXT_W = 8,
  parameter int OUTSTANDING_DEPTH = 2,
  parameter int RESPONSE_LATENCY = 2,
  parameter logic [3:0] ACCEPT_ADDR_SPACE_MASK = 4'b0001,
  parameter int WORD_COUNT_W = (MAX_WORDS < 2) ? 1 :
                               $clog2(MAX_WORDS + 1),
  parameter int OUTSTANDING_COUNT_W = (OUTSTANDING_DEPTH <= 1) ? 1 :
                                      $clog2(OUTSTANDING_DEPTH + 1)
) (
  input  logic clk_i,
  // Reset drops outstanding fetch responses but preserves programmed words.
  input  logic rst_ni,

  input  logic                                      req_valid_i,
  output logic                                      req_ready_o,
  input  logic [PC_W-1:0]                           req_pc_i,
  input  logic [WORD_COUNT_W-1:0]                   req_word_count_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] req_addr_space_i,
  input  logic [ADDR_CONTEXT_W-1:0]                 req_addr_context_i,

  output logic                                      rsp_valid_o,
  input  logic                                      rsp_ready_i,
  output logic [(MAX_WORDS*WORD_W)-1:0]             rsp_words_o,
  output logic [WORD_COUNT_W-1:0]                   rsp_word_count_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     rsp_fault_cause_o,

  // Test/bring-up programming and observation are kept off the architectural
  // fetch request path.  Each programming transaction writes one whole word.
  input  logic                                      init_valid_i,
  output logic                                      init_ready_o,
  input  logic [PC_W-1:0]                           init_pc_i,
  input  logic [WORD_W-1:0]                         init_word_i,
  output logic                                      init_error_o,

  input  logic [PC_W-1:0]                           peek_pc_i,
  output logic [WORD_W-1:0]                         peek_word_o,
  output logic                                      peek_error_o,

  output logic [OUTSTANDING_COUNT_W-1:0]            outstanding_count_o,
  output logic                                      idle_o
);
  import vsp_pkg::*;

  localparam int WORD_BYTES = WORD_W / 8;
  localparam int WORD_SHIFT = (WORD_BYTES <= 1) ? 0 : $clog2(WORD_BYTES);
  localparam int RESPONSE_W = MAX_WORDS * WORD_W;
  localparam int QUEUE_PTR_W = (OUTSTANDING_DEPTH <= 2) ? 1 :
                               $clog2(OUTSTANDING_DEPTH);
  localparam int LATENCY_W = (RESPONSE_LATENCY <= 1) ? 1 :
                             $clog2(RESPONSE_LATENCY + 1);

  logic [WORD_W-1:0] memory_q [MEM_WORDS];

  logic [RESPONSE_W-1:0] response_words_q [OUTSTANDING_DEPTH];
  logic [WORD_COUNT_W-1:0] response_word_count_q [OUTSTANDING_DEPTH];
  logic [VSP_MEM_FAULT_CAUSE_W-1:0]
      response_fault_q [OUTSTANDING_DEPTH];
  logic [LATENCY_W-1:0] response_delay_q [OUTSTANDING_DEPTH];
  logic response_valid_q [OUTSTANDING_DEPTH];
  logic [QUEUE_PTR_W-1:0] head_q;
  logic [QUEUE_PTR_W-1:0] tail_q;
  logic [OUTSTANDING_COUNT_W-1:0] outstanding_count_q;

  logic [PC_W:0] request_delta;
  logic [PC_W:0] request_end_delta;
  logic request_aligned;
  logic request_range_ok;
  logic request_count_ok;
  logic request_space_defined;
  logic request_space_ok;
  logic [VSP_MEM_FAULT_CAUSE_W-1:0] request_fault;
  logic [RESPONSE_W-1:0] request_words;

  logic [PC_W:0] init_delta;
  logic [PC_W:0] init_end_delta;
  logic init_address_ok;
  logic [PC_W:0] peek_delta;
  logic [PC_W:0] peek_end_delta;
  logic peek_address_ok;

  logic request_fire;
  logic response_fire;
  logic init_fire;

  integer word_index;
  integer queue_index;

  function automatic logic [QUEUE_PTR_W-1:0] next_queue_ptr(
      input logic [QUEUE_PTR_W-1:0] pointer);
    if (int'(pointer) == (OUTSTANDING_DEPTH - 1))
      next_queue_ptr = '0;
    else
      next_queue_ptr = pointer + QUEUE_PTR_W'(1);
  endfunction

  always_comb begin
    request_delta = {1'b0, req_pc_i} - {1'b0, BASE_PC};
    request_end_delta = request_delta +
        (PC_W+1)'(int'(req_word_count_i) * WORD_BYTES);
    request_aligned =
        (req_pc_i & PC_W'(WORD_BYTES - 1)) == '0;
    request_count_ok = (int'(req_word_count_i) > 0) &&
                       (int'(req_word_count_i) <= MAX_WORDS);
    request_range_ok = !request_delta[PC_W] &&
        (request_end_delta <= (PC_W+1)'(MEM_WORDS * WORD_BYTES));
    request_space_defined = vsp_mem_addr_space_defined(req_addr_space_i);
    request_space_ok =
        ACCEPT_ADDR_SPACE_MASK[int'(req_addr_space_i)];

    request_fault = VSP_MEM_FAULT_NONE;
    if (!request_space_defined) begin
      request_fault = VSP_MEM_FAULT_PROTOCOL;
    end else if (!request_space_ok) begin
      request_fault =
          (req_addr_space_i == VSP_MEM_ADDR_SPACE_TRANSLATED) ?
              VSP_MEM_FAULT_TRANSLATION : VSP_MEM_FAULT_ACCESS;
    end else if (!request_count_ok) begin
      request_fault = VSP_MEM_FAULT_PROTOCOL;
    end else if (!request_aligned || !request_range_ok) begin
      request_fault = VSP_MEM_FAULT_ACCESS;
    end

    request_words = '0;
    if (request_fault == VSP_MEM_FAULT_NONE) begin
      for (word_index = 0; word_index < MAX_WORDS;
           word_index = word_index + 1) begin
        if (word_index < int'(req_word_count_i)) begin
          request_words[(word_index*WORD_W) +: WORD_W] =
              memory_q[int'(request_delta >> WORD_SHIFT) + word_index];
        end
      end
    end
  end

  always_comb begin
    init_delta = {1'b0, init_pc_i} - {1'b0, BASE_PC};
    init_end_delta = init_delta + (PC_W+1)'(WORD_BYTES);
    init_address_ok = !init_delta[PC_W] &&
        (init_end_delta <= (PC_W+1)'(MEM_WORDS * WORD_BYTES)) &&
        ((init_pc_i & PC_W'(WORD_BYTES - 1)) == '0);
    init_error_o = init_valid_i && !init_address_ok;

    peek_delta = {1'b0, peek_pc_i} - {1'b0, BASE_PC};
    peek_end_delta = peek_delta + (PC_W+1)'(WORD_BYTES);
    peek_address_ok = !peek_delta[PC_W] &&
        (peek_end_delta <= (PC_W+1)'(MEM_WORDS * WORD_BYTES)) &&
        ((peek_pc_i & PC_W'(WORD_BYTES - 1)) == '0);
    peek_error_o = !peek_address_ok;
    peek_word_o = '0;
    if (peek_address_ok)
      peek_word_o = memory_q[int'(peek_delta >> WORD_SHIFT)];
  end

  assign rsp_valid_o = rst_ni && (outstanding_count_q != 0) &&
                       response_valid_q[head_q] &&
                       (response_delay_q[head_q] == 0);
  assign rsp_words_o = response_words_q[head_q];
  assign rsp_word_count_o = response_word_count_q[head_q];
  assign rsp_fault_cause_o = response_fault_q[head_q];
  assign response_fire = rsp_valid_o && rsp_ready_i;

  // No request IDs are needed while the provider returns responses in FIFO
  // order.  A full queue can accept a replacement when its head transfers.
  assign req_ready_o = rst_ni &&
      ((int'(outstanding_count_q) < OUTSTANDING_DEPTH) || response_fire);
  assign request_fire = req_valid_i && req_ready_o;

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
        response_words_q[queue_index] <= '0;
        response_word_count_q[queue_index] <= '0;
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
        response_words_q[tail_q] <= request_words;
        response_word_count_q[tail_q] <= req_word_count_i;
        response_fault_q[tail_q] <= request_fault;
        response_delay_q[tail_q] <= LATENCY_W'(RESPONSE_LATENCY);
        response_valid_q[tail_q] <= 1'b1;
        tail_q <= next_queue_ptr(tail_q);
      end

      if (init_fire)
        memory_q[int'(init_delta >> WORD_SHIFT)] <= init_word_i;

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
    if (PC_W < 3) $error("PC_W must hold byte-addressed words");
    if (WORD_W < 8 || (WORD_W % 8) != 0)
      $error("WORD_W must be a positive whole number of bytes");
    if (WORD_BYTES < 1 || (WORD_BYTES & (WORD_BYTES - 1)) != 0)
      $error("WORD_BYTES must be a power of two");
    if (MAX_WORDS < 1) $error("MAX_WORDS must be positive");
    if (MEM_WORDS < MAX_WORDS)
      $error("MEM_WORDS must hold one maximum fetch response");
    if ((BASE_PC & PC_W'(WORD_BYTES - 1)) != '0)
      $error("BASE_PC must be word aligned");
    if (ADDR_CONTEXT_W < 1) $error("ADDR_CONTEXT_W must be positive");
    if (OUTSTANDING_DEPTH < 1)
      $error("OUTSTANDING_DEPTH must be positive");
    if (RESPONSE_LATENCY < 1)
      $error("RESPONSE_LATENCY must be at least one cycle");
    if ((2**WORD_COUNT_W) <= MAX_WORDS)
      $error("WORD_COUNT_W cannot represent MAX_WORDS");
    if ((2**OUTSTANDING_COUNT_W) <= OUTSTANDING_DEPTH)
      $error("OUTSTANDING_COUNT_W cannot represent OUTSTANDING_DEPTH");
  end

  // Translation/protection consumes this opaque field in a future adapter;
  // the local backing model intentionally does not interpret it.
  logic unused_addr_context;
  assign unused_addr_context = ^req_addr_context_i;
endmodule
