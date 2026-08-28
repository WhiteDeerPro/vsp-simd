module vsp_uword_bundle_assembler #(
  parameter int PC_W = 32,
  parameter int BUNDLE_WORDS = 4,
  parameter int BUNDLE_COUNT_W = (BUNDLE_WORDS < 2) ? 1 :
                                 $clog2(BUNDLE_WORDS + 1)
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  input  logic                                      bundle_valid_i,
  output logic                                      bundle_ready_o,
  input  logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
                                                     bundle_words_i,
  input  logic [BUNDLE_COUNT_W-1:0]                 bundle_word_count_i,
  input  logic [PC_W-1:0]                           bundle_base_pc_i,
  input  logic                                      bundle_last_i,

  // One stall-stable record at a time. word_count is the structural length;
  // present_word_count is smaller only for a final truncated record.
  output logic                                      record_valid_o,
  input  logic                                      record_ready_i,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     record_class_o,
  output logic                                      record_major_defined_o,
  output logic [PC_W-1:0]                           record_start_pc_o,
  output logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_word_count_o,
  output logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_present_word_count_o,
  output logic [(vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]    record_words_o,
  output logic                                      record_truncated_o,

  // record_delivery_done pulses when the final complete/truncated record
  // transfers. It is a framing event, not execution of CONTROL.END.
  output logic                                      record_delivery_done_o,
  output logic                                      idle_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      protocol_error_o
);
  import vsp_uword_pkg::*;

  localparam int BUFFER_WORDS = BUNDLE_WORDS +
                                VSP_UWORD_MAX_RECORD_WORDS - 1;
  localparam int BUFFER_COUNT_W = (BUFFER_WORDS < 2) ? 1 :
                                  $clog2(BUFFER_WORDS + 1);

  logic [VSP_UWORD_W-1:0] word_q [BUFFER_WORDS];
  logic [BUFFER_COUNT_W-1:0] word_count_q;
  logic [PC_W-1:0] base_pc_q;
  logic [PC_W-1:0] expected_bundle_pc_q;
  logic expected_bundle_pc_valid_q;
  logic end_seen_q;
  logic discard_until_last_q;
  logic record_delivery_done_q;
  logic protocol_error_q;

  logic bundle_fire;
  logic record_fire;
  logic bundle_count_ok;
  logic bundle_pc_aligned;
  logic bundle_contiguous;
  logic record_complete;
  logic record_truncated;
  integer required_words;
  integer present_words;
  integer consume_words;
  integer buffered_words;
  integer bundle_words;
  integer copy_index;
  integer shift_index;

  always_comb begin
    buffered_words = int'(word_count_q);
    bundle_words = int'(bundle_word_count_i);
    required_words = (buffered_words == 0) ? 1 :
        int'(vsp_uword_record_word_count(word_q[0]));
    record_complete = (buffered_words != 0) &&
                      (buffered_words >= required_words);
    record_truncated = (buffered_words != 0) && end_seen_q &&
                       !record_complete;
    record_valid_o = record_complete || record_truncated;
    present_words = record_truncated ? buffered_words :
                    (record_complete ? required_words : 0);
    consume_words = record_valid_o ? present_words : 0;

    // A bundle is accepted only when no complete output owns the prefix.
    // If no record is visible, the buffer contains at most three partial
    // words, so another full four-word bundle always fits BUFFER_WORDS=7.
    bundle_ready_o = rst_ni && !end_seen_q && !record_valid_o;
    bundle_count_ok = (bundle_words > 0) &&
                      (bundle_words <= BUNDLE_WORDS);
    bundle_pc_aligned = bundle_base_pc_i[1:0] == 2'b00;
    bundle_contiguous = !expected_bundle_pc_valid_q ||
                        (bundle_base_pc_i == expected_bundle_pc_q);

    record_class_o = VSP_UWORD_CLASS_UNDEFINED;
    record_major_defined_o = 1'b0;
    record_start_pc_o = base_pc_q;
    record_word_count_o = VSP_UWORD_WORD_COUNT_W'(required_words);
    record_present_word_count_o =
        VSP_UWORD_WORD_COUNT_W'(record_valid_o ? present_words : 0);
    record_words_o = '0;
    record_truncated_o = record_truncated;
    if (buffered_words != 0) begin
      record_class_o = vsp_uword_dispatch_class(word_q[0]);
      record_major_defined_o = vsp_uword_major_defined(word_q[0]);
      for (copy_index = 0; copy_index < VSP_UWORD_MAX_RECORD_WORDS;
           copy_index = copy_index + 1) begin
        if (copy_index < present_words)
          record_words_o[(copy_index*VSP_UWORD_W) +: VSP_UWORD_W] =
              word_q[copy_index];
      end
    end
  end

  assign bundle_fire = bundle_valid_i && bundle_ready_o;
  assign record_fire = record_valid_o && record_ready_i;
  assign record_delivery_done_o = record_delivery_done_q;
  assign idle_o = (word_count_q == 0) && !end_seen_q &&
                  !discard_until_last_q;
  assign protocol_error_o = protocol_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      word_count_q <= '0;
      base_pc_q <= '0;
      expected_bundle_pc_q <= '0;
      expected_bundle_pc_valid_q <= 1'b0;
      end_seen_q <= 1'b0;
      discard_until_last_q <= 1'b0;
      record_delivery_done_q <= 1'b0;
      protocol_error_q <= 1'b0;
      for (shift_index = 0; shift_index < BUFFER_WORDS;
           shift_index = shift_index + 1)
        word_q[shift_index] <= '0;
    end else begin
      record_delivery_done_q <= 1'b0;
      if (protocol_error_clear_i && idle_o)
        protocol_error_q <= 1'b0;

      if (bundle_fire) begin
        if (discard_until_last_q) begin
          // Drain the invalid source transaction without exposing any of its
          // younger words as records. Reset or the final bundle closes it.
          if (bundle_last_i)
            discard_until_last_q <= 1'b0;
        end else if (!bundle_count_ok || !bundle_pc_aligned ||
                     !bundle_contiguous) begin
          protocol_error_q <= 1'b1;
          word_count_q <= '0;
          base_pc_q <= '0;
          expected_bundle_pc_q <= '0;
          expected_bundle_pc_valid_q <= 1'b0;
          end_seen_q <= 1'b0;
          discard_until_last_q <= !bundle_last_i;
          for (shift_index = 0; shift_index < BUFFER_WORDS;
               shift_index = shift_index + 1)
            word_q[shift_index] <= '0;
        end else begin
          if (word_count_q == 0)
            base_pc_q <= bundle_base_pc_i;
          for (shift_index = 0; shift_index < BUFFER_WORDS;
               shift_index = shift_index + 1) begin
            if (shift_index < bundle_words)
              word_q[buffered_words + shift_index] <=
                  bundle_words_i[(shift_index*VSP_UWORD_W) +: VSP_UWORD_W];
          end
          word_count_q <= BUFFER_COUNT_W'(buffered_words + bundle_words);
          expected_bundle_pc_q <=
              bundle_base_pc_i + PC_W'(bundle_words * 4);
          expected_bundle_pc_valid_q <= 1'b1;
          if (bundle_last_i)
            end_seen_q <= 1'b1;
        end
      end else if (record_fire) begin
        for (shift_index = 0; shift_index < BUFFER_WORDS;
             shift_index = shift_index + 1) begin
          if ((shift_index + consume_words) < buffered_words)
            word_q[shift_index] <= word_q[shift_index + consume_words];
          else
            word_q[shift_index] <= '0;
        end
        word_count_q <= BUFFER_COUNT_W'(buffered_words - consume_words);
        base_pc_q <= base_pc_q + PC_W'(consume_words * 4);
        if (end_seen_q && (consume_words == buffered_words)) begin
          end_seen_q <= 1'b0;
          expected_bundle_pc_q <= '0;
          expected_bundle_pc_valid_q <= 1'b0;
          record_delivery_done_q <= 1'b1;
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
    if (VSP_UWORD_MAX_RECORD_WORDS != 4)
      $error("stream assembler expects four-word maximum records");
  end
endmodule
