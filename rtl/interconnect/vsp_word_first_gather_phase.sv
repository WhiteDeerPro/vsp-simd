// One combinational pass of the 4-group word-first register-gather reference.
//
// Packing is group-major and then lane-minor:
//   flat_lane = (group * 4) + lane
//
// During phase p, each destination group j consumes index[j][p].  The high
// two index bits select one captured 32-bit source word through a multicast
// crossbar; the low two bits select one byte from that word.  Only destination
// byte [j][p] is eligible for the later staged write.  Four passes therefore
// cover all sixteen destinations without route-setting or conflict retry.
//
// This is deliberately an exact 4-group x SIMD4 byte profile.  It is a PPA
// reference for the route-domain study, not a generic cluster network.
module vsp_word_first_gather_phase (
  input  logic [127:0] source_i,
  input  logic [127:0] index_i,
  input  logic [15:0]  active_mask_i,
  input  logic [1:0]   phase_i,

  // One selected byte and one write decision per destination group.  The
  // engine places byte j at destination lane (j * 4) + phase_i.
  output logic [31:0]  selected_byte_o,
  output logic [3:0]   selected_we_o,
  output logic [3:0]   selected_oob_o
);
  localparam int GROUPS = 4;
  localparam int LANES_PER_GROUP = 4;
  localparam int DATA_W = 8;
  localparam int INDEX_ELEM_W = 8;
  localparam int GROUP_WORD_W = LANES_PER_GROUP * DATA_W;
  localparam int TOTAL_LANES = GROUPS * LANES_PER_GROUP;

  logic [(GROUPS*2)-1:0]            word_select;
  logic [(GROUPS*GROUP_WORD_W)-1:0] selected_words;
  logic [(GROUPS*2)-1:0]            byte_select;
  logic [GROUPS-1:0]                index_valid;
  logic                              word_crossbar_illegal;

  simd_crossbar #(
    .PORTS(GROUPS),
    .DATA_W(GROUP_WORD_W),
    .INDEX_W(2)
  ) u_word_crossbar (
    .data_i(source_i),
    .select_i(word_select),
    .data_o(selected_words),
    .illegal_o(word_crossbar_illegal)
  );

  // Derive the word and byte selects directly from the captured full-byte
  // index.  Out-of-range indices select a harmless word/byte zero here but
  // never assert the later byte write-enable; they must not wrap via [3:0].
  always_comb begin
    word_select = '0;
    byte_select = '0;
    index_valid = '0;

    for (int group = 0; group < GROUPS; group++) begin
      int unsigned flat_lane;
      int unsigned index_value;

      flat_lane = (group * LANES_PER_GROUP) + int'(phase_i);
      index_value = int'(
          index_i[(flat_lane*INDEX_ELEM_W) +: INDEX_ELEM_W]);

      if (index_value < TOTAL_LANES) begin
        index_valid[group] = 1'b1;
        word_select[(group*2) +: 2] = index_value[3:2];
        byte_select[(group*2) +: 2] = index_value[1:0];
      end
    end
  end

  // A standard output-driven crossbar permits repeated word_select entries,
  // so all destination groups may consume the same source word.  The second
  // loop is the destination-local 4:1 byte selector.
  always_comb begin
    selected_byte_o = '0;
    selected_we_o = '0;
    selected_oob_o = '0;

    for (int group = 0; group < GROUPS; group++) begin
      int unsigned selected_lane;

      selected_lane = int'(byte_select[(group*2) +: 2]);
      selected_we_o[group] =
          active_mask_i[(group*LANES_PER_GROUP) + int'(phase_i)] &&
          index_valid[group];
      selected_oob_o[group] =
          active_mask_i[(group*LANES_PER_GROUP) + int'(phase_i)] &&
          !index_valid[group];

      if (index_valid[group]) begin
        selected_byte_o[(group*DATA_W) +: DATA_W] =
            selected_words[(group*GROUP_WORD_W) +
                           (selected_lane*DATA_W) +: DATA_W];
      end
    end
  end

  // All generated word selectors are in range.  Keep this invariant visible
  // to simulation without turning an architectural OOB gather element into a
  // protocol error.
  always_comb begin
    assert (!word_crossbar_illegal)
      else $error("word-first gather generated an illegal word selector");
  end
endmodule
