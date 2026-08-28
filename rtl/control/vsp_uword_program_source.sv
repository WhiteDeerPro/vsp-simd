module vsp_uword_program_source #(
  parameter int PC_W = 32,
  parameter int BUNDLE_WORDS = 4,
  parameter int BUNDLE_COUNT_W = (BUNDLE_WORDS < 2) ? 1 :
                                 $clog2(BUNDLE_WORDS + 1)
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  // One contiguous half-open program range [start_pc, end_pc). Both values
  // are byte addresses. A zero-length range completes without a request.
  input  logic                                      start_valid_i,
  output logic                                      start_ready_o,
  input  logic [PC_W-1:0]                           start_pc_i,
  input  logic [PC_W-1:0]                           end_pc_i,

  // Logical control-store request/response. The source permits one request
  // outstanding and keeps the complete response stable as a bundle.
  output logic                                      store_req_valid_o,
  input  logic                                      store_req_ready_i,
  output logic [PC_W-1:0]                           store_req_pc_o,
  output logic [BUNDLE_COUNT_W-1:0]                 store_req_word_count_o,
  input  logic                                      store_rsp_valid_i,
  output logic                                      store_rsp_ready_o,
  input  logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
                                                     store_rsp_words_i,
  input  logic                                      store_rsp_fault_i,

  // Word i in a bundle owns byte address bundle_base_pc_o + 4*i. Accepting
  // the bundle advances the source PC by 4*bundle_word_count_o.
  output logic                                      bundle_valid_o,
  input  logic                                      bundle_ready_i,
  output logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
                                                     bundle_words_o,
  output logic [BUNDLE_COUNT_W-1:0]                 bundle_word_count_o,
  output logic [PC_W-1:0]                           bundle_base_pc_o,
  output logic                                      bundle_last_o,

  output logic [PC_W-1:0]                           current_pc_o,
  output logic                                      running_o,
  // delivery_done is a source-side pulse: the final bundle has transferred.
  // It does not mean its records have retired or CONTROL.END has executed.
  output logic                                      delivery_done_o,
  output logic                                      store_fault_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      protocol_error_o
);
  import vsp_uword_pkg::*;

  logic [PC_W-1:0] pc_q;
  logic [PC_W-1:0] end_pc_q;
  logic running_q;
  logic request_outstanding_q;
  logic [PC_W-1:0] request_pc_q;
  logic [BUNDLE_COUNT_W-1:0] request_word_count_q;
  logic request_last_q;
  logic bundle_valid_q;
  logic [(BUNDLE_WORDS*VSP_UWORD_W)-1:0] bundle_words_q;
  logic [BUNDLE_COUNT_W-1:0] bundle_word_count_q;
  logic [PC_W-1:0] bundle_base_pc_q;
  logic bundle_last_q;
  logic delivery_done_q;
  logic store_fault_q;
  logic protocol_error_q;

  logic start_fire;
  logic store_req_fire;
  logic store_rsp_fire;
  logic bundle_fire;
  logic start_range_ok;
  logic [BUNDLE_COUNT_W-1:0] requested_word_count;
  logic [PC_W:0] remaining_word_span;
  logic requested_bundle_last;

  always_comb begin
    remaining_word_span = '0;
    requested_word_count = '0;
    requested_bundle_last = 1'b0;
    if (running_q && !request_outstanding_q && !bundle_valid_q) begin
      remaining_word_span =
          ({1'b0, end_pc_q} - {1'b0, pc_q}) >> 2;
      requested_word_count =
          (remaining_word_span > (PC_W+1)'(BUNDLE_WORDS)) ?
          BUNDLE_COUNT_W'(BUNDLE_WORDS) :
          BUNDLE_COUNT_W'(remaining_word_span);
      requested_bundle_last =
          remaining_word_span <= (PC_W+1)'(BUNDLE_WORDS);
    end

    store_req_valid_o = running_q && !request_outstanding_q &&
                        !bundle_valid_q;
    store_req_pc_o = pc_q;
    store_req_word_count_o = requested_word_count;
    store_rsp_ready_o = request_outstanding_q && !bundle_valid_q;

    bundle_valid_o = bundle_valid_q;
    bundle_words_o = bundle_words_q;
    bundle_word_count_o = bundle_word_count_q;
    bundle_base_pc_o = bundle_base_pc_q;
    bundle_last_o = bundle_last_q;
  end

  assign start_ready_o = rst_ni && !running_q && !request_outstanding_q &&
                         !bundle_valid_q;
  assign start_range_ok = (start_pc_i[1:0] == 2'b00) &&
                          (end_pc_i[1:0] == 2'b00) &&
                          ($unsigned(start_pc_i) <= $unsigned(end_pc_i));
  assign start_fire = start_valid_i && start_ready_o;
  assign store_req_fire = store_req_valid_o && store_req_ready_i;
  assign store_rsp_fire = store_rsp_valid_i && store_rsp_ready_o;
  assign bundle_fire = bundle_valid_o && bundle_ready_i;

  assign current_pc_o = pc_q;
  assign running_o = running_q || request_outstanding_q || bundle_valid_q;
  assign delivery_done_o = delivery_done_q;
  assign store_fault_o = store_fault_q;
  assign protocol_error_o = protocol_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= '0;
      end_pc_q <= '0;
      running_q <= 1'b0;
      request_outstanding_q <= 1'b0;
      request_pc_q <= '0;
      request_word_count_q <= '0;
      request_last_q <= 1'b0;
      bundle_valid_q <= 1'b0;
      bundle_words_q <= '0;
      bundle_word_count_q <= '0;
      bundle_base_pc_q <= '0;
      bundle_last_q <= 1'b0;
      delivery_done_q <= 1'b0;
      store_fault_q <= 1'b0;
      protocol_error_q <= 1'b0;
    end else begin
      delivery_done_q <= 1'b0;
      if (protocol_error_clear_i) begin
        protocol_error_q <= 1'b0;
        store_fault_q <= 1'b0;
      end

      if (start_fire) begin
        if (!start_range_ok) begin
          protocol_error_q <= 1'b1;
        end else begin
          pc_q <= start_pc_i;
          end_pc_q <= end_pc_i;
          store_fault_q <= 1'b0;
          if (start_pc_i == end_pc_i) begin
            running_q <= 1'b0;
            delivery_done_q <= 1'b1;
          end else begin
            running_q <= 1'b1;
          end
        end
      end

      if (store_req_fire) begin
        request_outstanding_q <= 1'b1;
        request_pc_q <= pc_q;
        request_word_count_q <= requested_word_count;
        request_last_q <= requested_bundle_last;
      end

      if (store_rsp_fire) begin
        request_outstanding_q <= 1'b0;
        if (store_rsp_fault_i) begin
          running_q <= 1'b0;
          store_fault_q <= 1'b1;
        end else begin
          bundle_valid_q <= 1'b1;
          bundle_words_q <= store_rsp_words_i;
          bundle_word_count_q <= request_word_count_q;
          bundle_base_pc_q <= request_pc_q;
          bundle_last_q <= request_last_q;
        end
      end

      if (bundle_fire) begin
        bundle_valid_q <= 1'b0;
        pc_q <= pc_q + PC_W'(int'(bundle_word_count_q) * 4);
        if (bundle_last_q) begin
          running_q <= 1'b0;
          delivery_done_q <= 1'b1;
        end
      end
    end
  end

  initial begin
    if (PC_W < 3)
      $error("PC_W must hold a byte-aligned word address");
    if (BUNDLE_WORDS <= 0)
      $error("BUNDLE_WORDS must be positive");
    if ((2**BUNDLE_COUNT_W) <= BUNDLE_WORDS)
      $error("BUNDLE_COUNT_W cannot represent BUNDLE_WORDS");
  end
endmodule
