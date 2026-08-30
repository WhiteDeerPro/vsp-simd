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

  // A redirect replaces the sequential source PC within the most recently
  // accepted launch range.  The source accepts aligned targets in the closed
  // interval [start_pc,end_pc]: redirecting to end_pc is a legal empty tail
  // and produces one delivery_done pulse.  A sequencer may impose the
  // stronger taken-control-flow rule target < end_pc before driving this
  // transport interface.
  input  logic                                      redirect_valid_i,
  output logic                                      redirect_ready_o,
  input  logic [PC_W-1:0]                           redirect_pc_i,

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
  logic [PC_W-1:0] start_pc_q;
  logic [PC_W-1:0] end_pc_q;
  logic range_valid_q;
  logic running_q;
  logic request_outstanding_q;
  // The request interface has no cancellation tag.  A redirect therefore
  // leaves an already accepted request outstanding and drains its response
  // without exposing it as a bundle before issuing at the new PC.
  logic discard_response_q;
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
  logic redirect_fire;
  logic redirect_range_ok;
  logic redirect_commit;
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
                        !bundle_valid_q && !redirect_valid_i;
    store_req_pc_o = pc_q;
    store_req_word_count_o = requested_word_count;
    store_rsp_ready_o = request_outstanding_q && !bundle_valid_q;

    // A redirect is a synchronous flow discontinuity.  Suppress an old held
    // bundle in its commit cycle so a consumer cannot simultaneously accept
    // data which the sequential path is about to discard.
    bundle_valid_o = bundle_valid_q && !redirect_commit;
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
  // Redirect is always sink-ready after reset.  The integration lifecycle
  // makes launch and redirect mutually exclusive (launch only while idle,
  // redirect only for an active branch); keeping ready independent of either
  // request avoids a wrapper-level ready/flush combinational cycle.
  assign redirect_ready_o = rst_ni;
  assign redirect_fire = redirect_valid_i && redirect_ready_o;
  assign redirect_range_ok = range_valid_q &&
      (redirect_pc_i[1:0] == 2'b00) &&
      ($unsigned(redirect_pc_i) >= $unsigned(start_pc_q)) &&
      ($unsigned(redirect_pc_i) <= $unsigned(end_pc_q));
  assign redirect_commit = redirect_fire && redirect_range_ok;
  assign store_req_fire = store_req_valid_o && store_req_ready_i;
  assign store_rsp_fire = store_rsp_valid_i && store_rsp_ready_o;
  assign bundle_fire = bundle_valid_o && bundle_ready_i;

  assign current_pc_o = pc_q;
  assign running_o = running_q || request_outstanding_q || bundle_valid_q;
  assign delivery_done_o = delivery_done_q && !redirect_commit;
  assign store_fault_o = store_fault_q;
  assign protocol_error_o = protocol_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pc_q <= '0;
      start_pc_q <= '0;
      end_pc_q <= '0;
      range_valid_q <= 1'b0;
      running_q <= 1'b0;
      request_outstanding_q <= 1'b0;
      discard_response_q <= 1'b0;
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
          range_valid_q <= 1'b0;
        end else begin
          pc_q <= start_pc_i;
          start_pc_q <= start_pc_i;
          end_pc_q <= end_pc_i;
          range_valid_q <= 1'b1;
          store_fault_q <= 1'b0;
          discard_response_q <= 1'b0;
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
        discard_response_q <= 1'b0;
        request_pc_q <= pc_q;
        request_word_count_q <= requested_word_count;
        request_last_q <= requested_bundle_last;
      end

      if (store_rsp_fire) begin
        request_outstanding_q <= 1'b0;
        if (discard_response_q || redirect_commit) begin
          // The response belongs to the path preceding a redirect.  Its data
          // and fault indication are both non-architectural.
          discard_response_q <= 1'b0;
          request_pc_q <= '0;
          request_word_count_q <= '0;
          request_last_q <= 1'b0;
        end else if (store_rsp_fault_i) begin
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

      // Redirect has final flow-state priority over a same-cycle response or
      // old-bundle transfer.  An accepted old request cannot be cancelled at
      // this interface, so retain only that response obligation and poison it.
      // No new request can fire in this cycle because redirect_valid gates the
      // request valid above.
      if (redirect_fire) begin
        if (!redirect_range_ok) begin
          protocol_error_q <= 1'b1;
        end else begin
          pc_q <= redirect_pc_i;
          bundle_valid_q <= 1'b0;
          bundle_words_q <= '0;
          bundle_word_count_q <= '0;
          bundle_base_pc_q <= '0;
          bundle_last_q <= 1'b0;
          // A fault from the discarded sequential path is speculative with
          // respect to the committed redirect and must not survive it.
          store_fault_q <= 1'b0;
          delivery_done_q <= redirect_pc_i == end_pc_q;
          running_q <= redirect_pc_i != end_pc_q;

          // If the old response also transfers now, it has already drained;
          // otherwise preserve precisely one poisoned response obligation.
          request_outstanding_q <= request_outstanding_q && !store_rsp_fire;
          discard_response_q <= request_outstanding_q && !store_rsp_fire;
          if (store_rsp_fire) begin
            request_pc_q <= '0;
            request_word_count_q <= '0;
            request_last_q <= 1'b0;
          end
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
