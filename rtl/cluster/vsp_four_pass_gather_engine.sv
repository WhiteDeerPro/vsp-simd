// Snapshot-driven 4-group register-gather reference engine.
//
// This module intentionally stops at a decoupled result transaction.  It does
// not read or write a VRF, allocate a uword encoding, or decide architectural
// trap policy.  A future cluster wrapper may capture two distributed VRF rows,
// submit them here, and atomically commit result_data_o under
// result_write_mask_o after the response handshake.
module vsp_four_pass_gather_engine #(
  parameter int CONTEXT_W = 2,
  parameter int TAG_W = 8
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,

  input  logic                 cmd_valid_i,
  output logic                 cmd_ready_o,
  input  logic [CONTEXT_W-1:0] cmd_context_i,
  input  logic [TAG_W-1:0]     cmd_tag_i,
  input  logic [127:0]         cmd_source_i,
  input  logic [127:0]         cmd_index_i,
  input  logic [15:0]          cmd_active_mask_i,

  output logic                 result_valid_o,
  input  logic                 result_ready_i,
  output logic [CONTEXT_W-1:0] result_context_o,
  output logic [TAG_W-1:0]     result_tag_o,
  output logic [127:0]         result_data_o,
  output logic [15:0]          result_write_mask_o,
  output logic [15:0]          result_oob_mask_o,

  output logic                 busy_o,
  output logic [1:0]           phase_o
);
  localparam int GROUPS = 4;
  localparam int LANES_PER_GROUP = 4;
  localparam int DATA_W = 8;

  logic [127:0] source_q;
  logic [127:0] index_q;
  logic [15:0]  active_mask_q;
  logic [1:0]   phase_q;
  logic         busy_q;

  logic                 result_valid_q;
  logic [CONTEXT_W-1:0] result_context_q;
  logic [TAG_W-1:0]     result_tag_q;
  logic [127:0]         result_data_q;
  logic [15:0]          result_write_mask_q;
  logic [15:0]          result_oob_mask_q;

  logic [31:0] pass_selected_byte;
  logic [3:0]  pass_selected_we;
  logic [3:0]  pass_selected_oob;

  vsp_word_first_gather_phase u_phase (
    .source_i(source_q),
    .index_i(index_q),
    .active_mask_i(active_mask_q),
    .phase_i(phase_q),
    .selected_byte_o(pass_selected_byte),
    .selected_we_o(pass_selected_we),
    .selected_oob_o(pass_selected_oob)
  );

  // A consumed response and the next command may exchange ownership on the
  // same edge.  While a response is stalled, snapshots and result state are
  // immutable and no new command is admitted.
  assign cmd_ready_o = !busy_q && (!result_valid_q || result_ready_i);
  assign result_valid_o = result_valid_q;
  assign result_context_o = result_context_q;
  assign result_tag_o = result_tag_q;
  assign result_data_o = result_data_q;
  assign result_write_mask_o = result_write_mask_q;
  assign result_oob_mask_o = result_oob_mask_q;
  assign busy_o = busy_q;
  assign phase_o = busy_q ? phase_q : 2'b00;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      source_q <= '0;
      index_q <= '0;
      active_mask_q <= '0;
      phase_q <= '0;
      busy_q <= 1'b0;
      result_valid_q <= 1'b0;
      result_context_q <= '0;
      result_tag_q <= '0;
      result_data_q <= '0;
      result_write_mask_q <= '0;
      result_oob_mask_q <= '0;
    end else begin
      if (result_valid_q && result_ready_i) begin
        result_valid_q <= 1'b0;
      end

      if (cmd_valid_i && cmd_ready_o) begin
        source_q <= cmd_source_i;
        index_q <= cmd_index_i;
        active_mask_q <= cmd_active_mask_i;
        phase_q <= '0;
        busy_q <= 1'b1;
        result_context_q <= cmd_context_i;
        result_tag_q <= cmd_tag_i;
        result_data_q <= '0;
        result_write_mask_q <= cmd_active_mask_i;
        result_oob_mask_q <= '0;
      end else if (busy_q) begin
        for (int group = 0; group < GROUPS; group++) begin
          int unsigned destination_lane;

          destination_lane = (group * LANES_PER_GROUP) + int'(phase_q);
          if (pass_selected_we[group]) begin
            result_data_q[(destination_lane*DATA_W) +: DATA_W] <=
                pass_selected_byte[(group*DATA_W) +: DATA_W];
          end
          if (pass_selected_oob[group]) begin
            result_oob_mask_q[destination_lane] <= 1'b1;
          end
        end

        if (phase_q == 2'd3) begin
          phase_q <= '0;
          busy_q <= 1'b0;
          result_valid_q <= 1'b1;
        end else begin
          phase_q <= phase_q + 2'd1;
        end
      end
    end
  end

  initial begin
    if (CONTEXT_W < 1) $error("CONTEXT_W must be positive");
    if (TAG_W < 1) $error("TAG_W must be positive");
  end
endmodule
