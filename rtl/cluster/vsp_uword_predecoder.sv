module vsp_uword_predecoder #(
  parameter int BUNDLE_WORDS = 4,
  parameter int BUNDLE_COUNT_W = (BUNDLE_WORDS < 2) ? 1 :
                                 $clog2(BUNDLE_WORDS + 1),
  parameter int BUNDLE_INDEX_W = (BUNDLE_WORDS <= 2) ? 1 :
                                 $clog2(BUNDLE_WORDS)
) (
  // The valid portion of a bundle is contiguous and starts at word zero.
  // Word n occupies bundle_words_i[n*32 +: 32].  This block is combinational;
  // a bundle assembler owns ready/valid state and carries an incomplete tail
  // into the next bundle.
  input  logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
                                                   bundle_words_i,
  input  logic [BUNDLE_COUNT_W-1:0]               bundle_word_count_i,

  // Up to BUNDLE_WORDS complete records are emitted in stream order. Record n
  // is normalized into one four-word slot; unused body words are zero.
  output logic [BUNDLE_WORDS-1:0]                 record_valid_o,
  output logic [BUNDLE_WORDS-1:0]                 record_major_defined_o,
  output logic [(BUNDLE_WORDS*vsp_action_pkg::VSP_ACTION_CLASS_W)-1:0]
                                                   record_class_o,
  output logic [(BUNDLE_WORDS*BUNDLE_INDEX_W)-1:0]
                                                   record_start_index_o,
  output logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W)-1:0]
                                                   record_word_count_o,
  output logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]  record_words_o,
  // Scheduling-only route metadata.  This is intentionally much smaller
  // than full EXEC decode: a nonzero mode is a predecessor barrier, while a
  // partial IN/OUT role must be intercepted by a future atomic pairer rather
  // than entering the single-active route engine by itself.
  output logic [BUNDLE_WORDS-1:0]                 record_route_o,
  output logic [(BUNDLE_WORDS*
                vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W)-1:0]
                                                   record_route_io_mode_o,
  output logic [BUNDLE_WORDS-1:0]                 record_barrier_before_o,
  output logic [BUNDLE_WORDS-1:0]                 record_route_pair_required_o,
  output logic [BUNDLE_COUNT_W-1:0]               record_count_o,
  output logic [BUNDLE_COUNT_W-1:0]               consumed_word_count_o,

  // An incomplete final record is not emitted.  The normalized tail and both
  // counts let a later bundle assembler append only the missing words without
  // reparsing or confusing a body word with a new header.
  output logic                                    tail_valid_o,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                   tail_class_o,
  output logic [BUNDLE_INDEX_W-1:0]               tail_start_index_o,
  output logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                   tail_required_word_count_o,
  output logic [BUNDLE_COUNT_W-1:0]               tail_present_word_count_o,
  output logic [(vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]  tail_words_o,

  // Counts outside 0..BUNDLE_WORDS are an interface error. No records or tail
  // are emitted in that case, preventing an out-of-range dynamic selection.
  output logic                                    count_error_o
);
  import vsp_uword_pkg::*;

  logic [VSP_UWORD_W-1:0] bundle_word [BUNDLE_WORDS];

  integer word_index;
  integer scan_index;
  integer copy_index;
  integer cursor;
  integer record_index;
  integer valid_count;
  integer required_count;
  integer remaining_count;
  logic stop_scan;
  logic [VSP_UWORD_W-1:0] header;

  always_comb begin
    for (word_index = 0; word_index < BUNDLE_WORDS;
         word_index = word_index + 1)
      bundle_word[word_index] =
          bundle_words_i[(word_index*VSP_UWORD_W) +: VSP_UWORD_W];

    record_valid_o = '0;
    record_major_defined_o = '0;
    record_class_o = '0;
    record_start_index_o = '0;
    record_word_count_o = '0;
    record_words_o = '0;
    record_route_o = '0;
    record_route_io_mode_o = '0;
    record_barrier_before_o = '0;
    record_route_pair_required_o = '0;
    record_count_o = '0;
    consumed_word_count_o = '0;

    tail_valid_o = 1'b0;
    tail_class_o = VSP_UWORD_CLASS_UNDEFINED;
    tail_start_index_o = '0;
    tail_required_word_count_o = '0;
    tail_present_word_count_o = '0;
    tail_words_o = '0;

    valid_count = int'(bundle_word_count_i);
    count_error_o = valid_count > BUNDLE_WORDS;
    cursor = 0;
    record_index = 0;
    required_count = 0;
    remaining_count = 0;
    stop_scan = count_error_o;
    header = '0;

    // A bounded unrolled scan is sufficient: every complete record consumes
    // at least one input word, so no bundle can contain more than BUNDLE_WORDS
    // records.  cursor advances by the decoded record length.
    for (scan_index = 0; scan_index < BUNDLE_WORDS;
         scan_index = scan_index + 1) begin
      if (!stop_scan && (cursor < valid_count)) begin
        header = bundle_word[cursor];
        required_count = int'(vsp_uword_record_word_count(header));
        remaining_count = valid_count - cursor;

        if (remaining_count >= required_count) begin
          record_valid_o[record_index] = 1'b1;
          record_major_defined_o[record_index] =
              vsp_uword_major_defined(header);
          record_class_o[
              (record_index*vsp_action_pkg::VSP_ACTION_CLASS_W) +:
              vsp_action_pkg::VSP_ACTION_CLASS_W] =
                  vsp_uword_dispatch_class(header);
          record_start_index_o[(record_index*BUNDLE_INDEX_W) +:
                               BUNDLE_INDEX_W] = BUNDLE_INDEX_W'(cursor);
          record_word_count_o[
              (record_index*VSP_UWORD_WORD_COUNT_W) +:
              VSP_UWORD_WORD_COUNT_W] =
                  VSP_UWORD_WORD_COUNT_W'(required_count);

          if (vsp_exec_uword_pkg::vsp_exec_uword_is_route(header)) begin
            logic [vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W-1:0]
                route_mode;
            route_mode = header[27:26];
            record_route_o[record_index] = 1'b1;
            record_route_io_mode_o[
                (record_index*
                 vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W) +:
                vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W] = route_mode;
            record_barrier_before_o[record_index] =
                vsp_exec_uword_pkg::vsp_exec_route_mode_dependent(
                    route_mode);
            record_route_pair_required_o[record_index] =
                vsp_exec_uword_pkg::vsp_exec_route_mode_pair_required(
                    route_mode);
          end

          for (copy_index = 0;
               copy_index < VSP_UWORD_MAX_RECORD_WORDS;
               copy_index = copy_index + 1) begin
            if (copy_index < required_count)
              record_words_o[
                  ((record_index*VSP_UWORD_MAX_RECORD_WORDS + copy_index) *
                   VSP_UWORD_W) +: VSP_UWORD_W] =
                      bundle_word[cursor + copy_index];
          end

          cursor = cursor + required_count;
          record_index = record_index + 1;
        end else begin
          tail_valid_o = 1'b1;
          tail_class_o = vsp_uword_dispatch_class(header);
          tail_start_index_o = BUNDLE_INDEX_W'(cursor);
          tail_required_word_count_o =
              VSP_UWORD_WORD_COUNT_W'(required_count);
          tail_present_word_count_o = BUNDLE_COUNT_W'(remaining_count);
          for (copy_index = 0;
               copy_index < VSP_UWORD_MAX_RECORD_WORDS;
               copy_index = copy_index + 1) begin
            if (copy_index < remaining_count)
              tail_words_o[(copy_index*VSP_UWORD_W) +: VSP_UWORD_W] =
                  bundle_word[cursor + copy_index];
          end
          stop_scan = 1'b1;
        end
      end
    end

    if (!count_error_o) begin
      record_count_o = BUNDLE_COUNT_W'(record_index);
      consumed_word_count_o = BUNDLE_COUNT_W'(cursor);
    end
  end

  initial begin
    if (BUNDLE_WORDS <= 0)
      $error("BUNDLE_WORDS must be positive");
    if ((2**BUNDLE_COUNT_W) <= BUNDLE_WORDS)
      $error("BUNDLE_COUNT_W cannot represent BUNDLE_WORDS");
    if ((2**BUNDLE_INDEX_W) < BUNDLE_WORDS)
      $error("BUNDLE_INDEX_W cannot address every bundle word");
    if (VSP_UWORD_W != vsp_exec_uword_pkg::VSP_EXEC_UWORD_W)
      $error("mixed uword framing requires the EXEC profile word width");
    if (VSP_UWORD_MAX_RECORD_WORDS != 4)
      $error("predecoder output layout expects four-word records");
    if (vsp_exec_uword_pkg::vsp_exec_uword_format_defined(
            VSP_UWORD_MAJOR_MEMORY) ||
        vsp_exec_uword_pkg::vsp_exec_uword_format_defined(
            VSP_UWORD_MAJOR_CONTROL))
      $error("mixed uword class majors overlap the EXEC profile");
  end
endmodule
