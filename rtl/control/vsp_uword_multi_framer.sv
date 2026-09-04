module vsp_uword_multi_framer #(
  parameter int PC_W = 32,
  parameter int BUNDLE_WORDS = 4,
  parameter int ADMIT_SLOTS = 3,
  parameter int BUNDLE_COUNT_W = (BUNDLE_WORDS < 2) ? 1 :
                                 $clog2(BUNDLE_WORDS + 1)
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  // Fetch width and record-admission width are deliberately independent.
  // Word n owns byte address bundle_base_pc_i + 4*n.
  input  logic                                      bundle_valid_i,
  output logic                                      bundle_ready_o,
  input  logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
                                                     bundle_words_i,
  input  logic [BUNDLE_COUNT_W-1:0]                 bundle_word_count_i,
  input  logic [PC_W-1:0]                           bundle_base_pc_i,
  input  logic                                      bundle_last_i,

  // Complete records form a packed prefix. ready_i is interpreted as a
  // prefix-dequeue request: slot n can transfer only when every older valid
  // slot transfers in the same cycle. record_accept_o is authoritative when
  // ready_i itself is not a prefix.
  output logic [ADMIT_SLOTS-1:0]                    record_valid_o,
  input  logic [ADMIT_SLOTS-1:0]                    record_ready_i,
  output logic [ADMIT_SLOTS-1:0]                    record_accept_o,
  output logic [(ADMIT_SLOTS*vsp_action_pkg::VSP_ACTION_CLASS_W)-1:0]
                                                     record_class_o,
  output logic [ADMIT_SLOTS-1:0]                    record_major_defined_o,
  output logic [(ADMIT_SLOTS*PC_W)-1:0]             record_start_pc_o,
  output logic [(ADMIT_SLOTS*
                vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W)-1:0]
                                                     record_word_count_o,
  output logic [(ADMIT_SLOTS*
                vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W)-1:0]
                                                     record_present_word_count_o,
  output logic [(ADMIT_SLOTS*
                vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]    record_words_o,
  output logic [ADMIT_SLOTS-1:0]                    record_truncated_o,
  output logic [ADMIT_SLOTS-1:0]                    record_terminal_o,

  // stop_fetch rises as soon as a structurally decoded END is buffered,
  // including when END is younger than this cycle's admission prefix.  It is
  // sticky so a fetch source cannot miss it. terminal_clear_i starts a new
  // stream after the END record has transferred and the framer is halted.
  output logic                                      stop_fetch_o,
  output logic [PC_W-1:0]                           terminal_pc_o,
  output logic                                      terminal_accept_o,
  output logic                                      halted_o,
  input  logic                                      terminal_clear_i,

  // EOF is a transport boundary distinct from semantic CONTROL.END.
  // stream_abort synchronously discards an incomplete/faulted transport
  // stream.  It is not successful EOF and does not clear a previously
  // recognized END or a sticky protocol error.
  input  logic                                      stream_abort_i,
  // A committed control-flow redirect is stronger than a transport abort: it
  // discards every buffered sequential-path word and all continuity/EOF/END
  // state so the next bundle may begin at an unrelated PC.  A sticky framing
  // protocol error is diagnostic history and is deliberately preserved.
  input  logic                                      redirect_flush_i,
  output logic                                      record_delivery_done_o,
  output logic                                      idle_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      protocol_error_o
);
  import vsp_uword_pkg::*;

  // Three carry words are sufficient for the longest record crossing a
  // four-word fetch boundary.  Additional complete records naturally apply
  // bundle backpressure when fetch outruns ADMIT_SLOTS.
  localparam int BUFFER_WORDS = BUNDLE_WORDS +
                                VSP_UWORD_MAX_RECORD_WORDS - 1;
  localparam int BUFFER_COUNT_W = (BUFFER_WORDS < 2) ? 1 :
                                  $clog2(BUFFER_WORDS + 1);

  logic [VSP_UWORD_W-1:0] word_q [BUFFER_WORDS];
  logic [VSP_UWORD_W-1:0] word_d [BUFFER_WORDS];
  logic [BUFFER_COUNT_W-1:0] word_count_q;
  logic [BUFFER_COUNT_W-1:0] word_count_d;
  logic [PC_W-1:0] base_pc_q;
  logic [PC_W-1:0] base_pc_d;
  logic [PC_W-1:0] expected_bundle_pc_q;
  logic [PC_W-1:0] expected_bundle_pc_d;
  logic expected_bundle_pc_valid_q;
  logic expected_bundle_pc_valid_d;
  logic eof_seen_q;
  logic eof_seen_d;
  logic discard_until_last_q;
  logic discard_until_last_d;
  logic terminal_stop_q;
  logic terminal_stop_d;
  logic [PC_W-1:0] terminal_pc_q;
  logic [PC_W-1:0] terminal_pc_d;
  logic record_delivery_done_q;
  logic record_delivery_done_d;
  logic protocol_error_q;
  logic protocol_error_d;

  logic bundle_fire;
  logic bundle_count_ok;
  logic bundle_pc_aligned;
  logic bundle_contiguous;
  logic terminal_found;
  logic [PC_W-1:0] terminal_found_pc;
  logic prefix_open;

  integer buffered_words;
  integer valid_bundle_words;
  integer cursor;
  integer scan_index;
  integer record_index;
  integer copy_index;
  integer shift_index;
  integer state_index;
  integer required_words;
  integer present_words;
  integer remaining_words;
  integer terminal_boundary_words;
  integer effective_words;
  integer accepted_words;
  integer accepted_records;
  integer retained_words;
  integer capacity_bundle_words;

  always_comb begin
    buffered_words = int'(word_count_q);
    valid_bundle_words = int'(bundle_word_count_i);
    bundle_count_ok = (valid_bundle_words > 0) &&
                      (valid_bundle_words <= BUNDLE_WORDS);
    bundle_pc_aligned = bundle_base_pc_i[1:0] == 2'b00;
    bundle_contiguous = !expected_bundle_pc_valid_q ||
                        (bundle_base_pc_i == expected_bundle_pc_q);

    record_valid_o = '0;
    record_accept_o = '0;
    record_class_o = '0;
    record_major_defined_o = '0;
    record_start_pc_o = '0;
    record_word_count_o = '0;
    record_present_word_count_o = '0;
    record_words_o = '0;
    record_truncated_o = '0;
    record_terminal_o = '0;

    cursor = 0;
    record_index = 0;
    required_words = 0;
    present_words = 0;
    remaining_words = 0;
    terminal_found = 1'b0;
    terminal_found_pc = terminal_pc_q;
    terminal_boundary_words = buffered_words;

    // Scan every buffered record, not only the admission prefix.  This makes
    // stop_fetch independent of downstream stalls and ADMIT_SLOTS.  A body
    // word is skipped according to its header length and is never inspected.
    for (scan_index = 0; scan_index < BUFFER_WORDS;
         scan_index = scan_index + 1) begin
      if (!terminal_found && (cursor < buffered_words)) begin
        required_words = int'(vsp_uword_record_word_count(word_q[cursor]));
        remaining_words = buffered_words - cursor;
        present_words = (remaining_words >= required_words) ?
                        required_words : remaining_words;

        if ((remaining_words >= required_words) || eof_seen_q) begin
          if (record_index < ADMIT_SLOTS) begin
            record_valid_o[record_index] = 1'b1;
            record_class_o[
                (record_index*vsp_action_pkg::VSP_ACTION_CLASS_W) +:
                vsp_action_pkg::VSP_ACTION_CLASS_W] =
                    vsp_uword_dispatch_class(word_q[cursor]);
            record_major_defined_o[record_index] =
                vsp_uword_major_defined(word_q[cursor]);
            record_start_pc_o[(record_index*PC_W) +: PC_W] =
                base_pc_q + PC_W'(cursor * 4);
            record_word_count_o[
                (record_index*VSP_UWORD_WORD_COUNT_W) +:
                VSP_UWORD_WORD_COUNT_W] =
                    VSP_UWORD_WORD_COUNT_W'(required_words);
            record_present_word_count_o[
                (record_index*VSP_UWORD_WORD_COUNT_W) +:
                VSP_UWORD_WORD_COUNT_W] =
                    VSP_UWORD_WORD_COUNT_W'(present_words);
            record_truncated_o[record_index] =
                remaining_words < required_words;
            for (copy_index = 0;
                 copy_index < VSP_UWORD_MAX_RECORD_WORDS;
                 copy_index = copy_index + 1) begin
              if (copy_index < present_words)
                record_words_o[
                    ((record_index*VSP_UWORD_MAX_RECORD_WORDS + copy_index) *
                     VSP_UWORD_W) +: VSP_UWORD_W] =
                        word_q[cursor + copy_index];
            end
          end

          // END is one complete canonical record.  A truncated final CONTROL
          // header cannot be END because the canonical END requires one word.
          if ((remaining_words >= required_words) &&
              vsp_uword_is_control_end(word_q[cursor])) begin
            terminal_found = 1'b1;
            terminal_found_pc = base_pc_q + PC_W'(cursor * 4);
            terminal_boundary_words = cursor + required_words;
            if (record_index < ADMIT_SLOTS)
              record_terminal_o[record_index] = 1'b1;
          end

          cursor = cursor + present_words;
          record_index = record_index + 1;
          // An EOF-truncated record necessarily consumes every remaining word.
          if (present_words < required_words)
            cursor = buffered_words;
        end else begin
          // Preserve the incomplete tail until the next contiguous bundle.
          cursor = buffered_words;
        end
      end
    end

    prefix_open = 1'b1;
    accepted_words = 0;
    accepted_records = 0;
    for (scan_index = 0; scan_index < ADMIT_SLOTS;
         scan_index = scan_index + 1) begin
      record_accept_o[scan_index] = !stream_abort_i && !redirect_flush_i &&
          prefix_open &&
          record_valid_o[scan_index] && record_ready_i[scan_index];
      if (record_accept_o[scan_index]) begin
        accepted_words = accepted_words + int'(
            record_present_word_count_o[
                (scan_index*VSP_UWORD_WORD_COUNT_W) +:
                VSP_UWORD_WORD_COUNT_W]);
        accepted_records = accepted_records + 1;
      end
      prefix_open = prefix_open && record_accept_o[scan_index];
    end

    effective_words = terminal_found ? terminal_boundary_words :
                                        buffered_words;
    retained_words = effective_words - accepted_words;
    capacity_bundle_words = bundle_count_ok ? valid_bundle_words :
                                             BUNDLE_WORDS;

    // Suppress stale control/data handshakes in the redirect commit cycle.
    // The registered state is cleared at the following edge.
    stop_fetch_o = !redirect_flush_i &&
                   (terminal_stop_q || terminal_found);
    terminal_pc_o = terminal_found ? terminal_found_pc : terminal_pc_q;
    terminal_accept_o = |(record_accept_o & record_terminal_o);
    halted_o = !redirect_flush_i && terminal_stop_q &&
               (word_count_q == 0);
    idle_o = (word_count_q == 0) && !eof_seen_q &&
             !discard_until_last_q && !terminal_stop_q;
    record_delivery_done_o = record_delivery_done_q && !redirect_flush_i;
    protocol_error_o = protocol_error_q;

    // A valid producer holds count and payload stable with valid.  Using the
    // declared count here admits a short final bundle without tying fetch
    // width to record-admission width.  Invalid counts reserve a full bundle
    // so the bad transfer can still be accepted and diagnosed once space is
    // available.
    bundle_ready_o = rst_ni && !stream_abort_i && !redirect_flush_i &&
        (discard_until_last_q ||
         (!stop_fetch_o && !eof_seen_q &&
          ((retained_words + capacity_bundle_words) <= BUFFER_WORDS)));
    bundle_fire = bundle_valid_i && bundle_ready_o;

    for (shift_index = 0; shift_index < BUFFER_WORDS;
         shift_index = shift_index + 1) begin
      word_d[shift_index] = '0;
      if ((shift_index + accepted_words) < effective_words)
        word_d[shift_index] = word_q[shift_index + accepted_words];
    end
    word_count_d = BUFFER_COUNT_W'(retained_words);
    base_pc_d = base_pc_q + PC_W'(accepted_words * 4);
    expected_bundle_pc_d = expected_bundle_pc_q;
    expected_bundle_pc_valid_d = expected_bundle_pc_valid_q;
    eof_seen_d = eof_seen_q;
    discard_until_last_d = discard_until_last_q;
    terminal_stop_d = terminal_stop_q || terminal_found;
    terminal_pc_d = terminal_found ? terminal_found_pc : terminal_pc_q;
    record_delivery_done_d = 1'b0;
    protocol_error_d = protocol_error_q;

    if (protocol_error_clear_i && idle_o)
      protocol_error_d = 1'b0;

    if (terminal_clear_i && halted_o) begin
      terminal_stop_d = 1'b0;
      terminal_pc_d = '0;
      expected_bundle_pc_d = '0;
      expected_bundle_pc_valid_d = 1'b0;
      eof_seen_d = 1'b0;
    end

    if (bundle_fire) begin
      if (discard_until_last_q) begin
        if (bundle_last_i)
          discard_until_last_d = 1'b0;
      end else if (!bundle_count_ok || !bundle_pc_aligned ||
                   !bundle_contiguous) begin
        protocol_error_d = 1'b1;
        word_count_d = '0;
        base_pc_d = '0;
        expected_bundle_pc_d = '0;
        expected_bundle_pc_valid_d = 1'b0;
        eof_seen_d = 1'b0;
        discard_until_last_d = !bundle_last_i;
        for (shift_index = 0; shift_index < BUFFER_WORDS;
             shift_index = shift_index + 1)
          word_d[shift_index] = '0;
      end else begin
        if (retained_words == 0)
          base_pc_d = bundle_base_pc_i;
        for (shift_index = 0; shift_index < BUFFER_WORDS;
             shift_index = shift_index + 1) begin
          if (shift_index < valid_bundle_words)
            word_d[retained_words + shift_index] =
                bundle_words_i[(shift_index*VSP_UWORD_W) +: VSP_UWORD_W];
        end
        word_count_d =
            BUFFER_COUNT_W'(retained_words + valid_bundle_words);
        expected_bundle_pc_d =
            bundle_base_pc_i + PC_W'(valid_bundle_words * 4);
        expected_bundle_pc_valid_d = 1'b1;
        if (bundle_last_i)
          eof_seen_d = 1'b1;
      end
    end

    // Reaching a physical EOF is reported after its last record transfers.
    // END has an independent terminal handshake and may stop a non-final
    // fetch stream.
    if (!bundle_fire && eof_seen_q && (retained_words == 0) &&
        (accepted_records != 0)) begin
      eof_seen_d = 1'b0;
      expected_bundle_pc_d = '0;
      expected_bundle_pc_valid_d = 1'b0;
      record_delivery_done_d = 1'b1;
    end

    // Abort has final next-state priority over transport consumption and EOF
    // reporting.  END recognition still wins semantically: once observed it
    // remains a sticky halt until terminal_clear_i is applied while halted.
    if (stream_abort_i) begin
      word_count_d = '0;
      base_pc_d = '0;
      expected_bundle_pc_d = '0;
      expected_bundle_pc_valid_d = 1'b0;
      eof_seen_d = 1'b0;
      discard_until_last_d = 1'b0;
      terminal_stop_d = terminal_stop_q || terminal_found;
      terminal_pc_d = terminal_found ? terminal_found_pc : terminal_pc_q;
      record_delivery_done_d = 1'b0;
      for (shift_index = 0; shift_index < BUFFER_WORDS;
           shift_index = shift_index + 1)
        word_d[shift_index] = '0;
    end

    // Redirect is the final data-state priority.  Unlike stream_abort it also
    // revokes a recognized END, because the sequencer has committed a new PC.
    // Preserve protocol_error_q even if the old stream becomes idle here;
    // only the explicit diagnostic-clear path may acknowledge it later.
    if (redirect_flush_i) begin
      word_count_d = '0;
      base_pc_d = '0;
      expected_bundle_pc_d = '0;
      expected_bundle_pc_valid_d = 1'b0;
      eof_seen_d = 1'b0;
      discard_until_last_d = 1'b0;
      terminal_stop_d = 1'b0;
      terminal_pc_d = '0;
      record_delivery_done_d = 1'b0;
      protocol_error_d = protocol_error_q;
      for (shift_index = 0; shift_index < BUFFER_WORDS;
           shift_index = shift_index + 1)
        word_d[shift_index] = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      word_count_q <= '0;
      base_pc_q <= '0;
      expected_bundle_pc_q <= '0;
      expected_bundle_pc_valid_q <= 1'b0;
      eof_seen_q <= 1'b0;
      discard_until_last_q <= 1'b0;
      terminal_stop_q <= 1'b0;
      terminal_pc_q <= '0;
      record_delivery_done_q <= 1'b0;
      protocol_error_q <= 1'b0;
      for (state_index = 0; state_index < BUFFER_WORDS;
           state_index = state_index + 1)
        word_q[state_index] <= '0;
    end else begin
      word_count_q <= word_count_d;
      base_pc_q <= base_pc_d;
      expected_bundle_pc_q <= expected_bundle_pc_d;
      expected_bundle_pc_valid_q <= expected_bundle_pc_valid_d;
      eof_seen_q <= eof_seen_d;
      discard_until_last_q <= discard_until_last_d;
      terminal_stop_q <= terminal_stop_d;
      terminal_pc_q <= terminal_pc_d;
      record_delivery_done_q <= record_delivery_done_d;
      protocol_error_q <= protocol_error_d;
      for (state_index = 0; state_index < BUFFER_WORDS;
           state_index = state_index + 1)
        word_q[state_index] <= word_d[state_index];
    end
  end

  initial begin
    if (PC_W < 3)
      $error("PC_W must hold a byte-aligned word address");
    if (BUNDLE_WORDS <= 0)
      $error("BUNDLE_WORDS must be positive");
    if (ADMIT_SLOTS <= 0)
      $error("ADMIT_SLOTS must be positive");
    if ((2**BUNDLE_COUNT_W) <= BUNDLE_WORDS)
      $error("BUNDLE_COUNT_W cannot represent BUNDLE_WORDS");
    if (VSP_UWORD_MAX_RECORD_WORDS != 4)
      $error("multi framer expects four-word maximum records");
  end
endmodule
