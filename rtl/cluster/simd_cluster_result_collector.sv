module simd_cluster_result_collector #(
  parameter int GROUP_COUNT   = 4,
  parameter int LANES         = 4,
  parameter int ELEM_W        = 8,
  parameter int ACC_W         = 32,
  parameter int CONTEXT_COUNT = 2,
  parameter int TAG_W         = 8,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One response channel per simd_group_wrapper.  A wrapper must hold every
  // field stable while valid is asserted and its ready bit is low.
  input  logic [GROUP_COUNT-1:0]                     group_rsp_valid_i,
  output logic [GROUP_COUNT-1:0]                     group_rsp_ready_o,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]         group_rsp_context_i,
  input  logic [(GROUP_COUNT*TAG_W)-1:0]             group_rsp_tag_i,
  input  logic [GROUP_COUNT-1:0]                     group_rsp_illegal_i,
  input  logic [GROUP_COUNT-1:0]                     group_rsp_has_narrow_i,
  input  logic [(GROUP_COUNT*LANES*ELEM_W)-1:0]      group_rsp_narrow_i,
  input  logic [(GROUP_COUNT*LANES)-1:0]             group_rsp_narrow_mask_i,
  input  logic [GROUP_COUNT-1:0]                     group_rsp_has_reduce_i,
  input  logic [(GROUP_COUNT*ACC_W)-1:0]             group_rsp_reduce_value_i,
  input  logic [(GROUP_COUNT*INDEX_W)-1:0]           group_rsp_reduce_index_i,
  input  logic [GROUP_COUNT-1:0]                     group_rsp_has_count_i,
  input  logic [(GROUP_COUNT*OFFSET_W)-1:0]          group_rsp_count_i,

  // A single cluster-level decoupled response.  This register is the point at
  // which ownership transfers from a group wrapper to the collector.
  output logic                                        result_valid_o,
  input  logic                                        result_ready_i,
  output logic [GROUP_ID_W-1:0]                       result_group_id_o,
  output logic [CONTEXT_W-1:0]                        result_context_o,
  output logic [TAG_W-1:0]                            result_tag_o,
  output logic                                        result_illegal_o,
  output logic                                        result_has_narrow_o,
  output logic [(LANES*ELEM_W)-1:0]                   result_narrow_o,
  output logic [LANES-1:0]                            result_narrow_mask_o,
  output logic                                        result_has_reduce_o,
  output logic [ACC_W-1:0]                            result_reduce_value_o,
  output logic [INDEX_W-1:0]                          result_reduce_index_o,
  output logic                                        result_has_count_o,
  output logic [OFFSET_W-1:0]                         result_count_o,

  // These signals connect directly to simd_group_completion_tracker.  A
  // retire pulse means that the collector captured the response, not that the
  // external cluster-result consumer has retired it.  Backpressure after this
  // point is therefore owned entirely by the collector's output register.
  output logic [GROUP_COUNT-1:0]                     child_rsp_retire_o,
  output logic [(GROUP_COUNT*CONTEXT_W)-1:0]         child_rsp_context_o,
  output logic [(GROUP_COUNT*TAG_W)-1:0]             child_rsp_tag_o
);
  logic [GROUP_ID_W-1:0] rr_group_q;
  logic select_valid;
  logic [GROUP_ID_W-1:0] select_group;
  logic can_capture;
  logic capture;

  logic result_valid_q;
  logic [GROUP_ID_W-1:0] result_group_id_q;
  logic [CONTEXT_W-1:0] result_context_q;
  logic [TAG_W-1:0] result_tag_q;
  logic result_illegal_q;
  logic result_has_narrow_q;
  logic [(LANES*ELEM_W)-1:0] result_narrow_q;
  logic [LANES-1:0] result_narrow_mask_q;
  logic result_has_reduce_q;
  logic [ACC_W-1:0] result_reduce_value_q;
  logic [INDEX_W-1:0] result_reduce_index_q;
  logic result_has_count_q;
  logic [OFFSET_W-1:0] result_count_q;

  assign can_capture = rst_ni && (!result_valid_q || result_ready_i);

  // Rotating-priority selection.  At most one ready bit is asserted, so a
  // response can never be captured twice even when several groups are valid.
  always_comb begin
    select_valid = 1'b0;
    select_group = '0;

    for (int offset = 0; offset < GROUP_COUNT; offset++) begin
      int candidate;
      candidate = int'(rr_group_q) + offset;
      if (candidate >= GROUP_COUNT) candidate = candidate - GROUP_COUNT;
      if (!select_valid && group_rsp_valid_i[candidate]) begin
        select_valid = 1'b1;
        select_group = GROUP_ID_W'(candidate);
      end
    end
  end

  always_comb begin
    group_rsp_ready_o = '0;
    if (can_capture && select_valid) begin
      group_rsp_ready_o[select_group] = 1'b1;
    end
  end

  assign capture = select_valid && group_rsp_valid_i[select_group] &&
                   group_rsp_ready_o[select_group];

  // The tracker metadata is meaningful only on the one-hot retire pulse.  It
  // is kept sparse here so accidental use of an inactive group's fields is
  // conspicuous in simulation.
  always_comb begin
    child_rsp_retire_o = '0;
    child_rsp_context_o = '0;
    child_rsp_tag_o = '0;

    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (capture && (int'(select_group) == group)) begin
        child_rsp_retire_o[group] = 1'b1;
        child_rsp_context_o[(group*CONTEXT_W) +: CONTEXT_W] =
            group_rsp_context_i[(group*CONTEXT_W) +: CONTEXT_W];
        child_rsp_tag_o[(group*TAG_W) +: TAG_W] =
            group_rsp_tag_i[(group*TAG_W) +: TAG_W];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rr_group_q <= '0;
      result_valid_q <= 1'b0;
      result_group_id_q <= '0;
      result_context_q <= '0;
      result_tag_q <= '0;
      result_illegal_q <= 1'b0;
      result_has_narrow_q <= 1'b0;
      result_narrow_q <= '0;
      result_narrow_mask_q <= '0;
      result_has_reduce_q <= 1'b0;
      result_reduce_value_q <= '0;
      result_reduce_index_q <= '0;
      result_has_count_q <= 1'b0;
      result_count_q <= '0;
    end else begin
      if (result_valid_q && result_ready_i) result_valid_q <= 1'b0;

      if (capture) begin
        result_valid_q <= 1'b1;
        result_group_id_q <= select_group;
        result_context_q <=
            group_rsp_context_i[(select_group*CONTEXT_W) +: CONTEXT_W];
        result_tag_q <= group_rsp_tag_i[(select_group*TAG_W) +: TAG_W];
        result_illegal_q <= group_rsp_illegal_i[select_group];
        result_has_narrow_q <= group_rsp_has_narrow_i[select_group];
        result_narrow_q <= group_rsp_narrow_i[
            (select_group*LANES*ELEM_W) +: (LANES*ELEM_W)];
        result_narrow_mask_q <= group_rsp_narrow_mask_i[
            (select_group*LANES) +: LANES];
        result_has_reduce_q <= group_rsp_has_reduce_i[select_group];
        result_reduce_value_q <= group_rsp_reduce_value_i[
            (select_group*ACC_W) +: ACC_W];
        result_reduce_index_q <= group_rsp_reduce_index_i[
            (select_group*INDEX_W) +: INDEX_W];
        result_has_count_q <= group_rsp_has_count_i[select_group];
        result_count_q <= group_rsp_count_i[
            (select_group*OFFSET_W) +: OFFSET_W];

        if (int'(select_group) == (GROUP_COUNT - 1)) rr_group_q <= '0;
        else rr_group_q <= select_group + 1'b1;
      end
    end
  end

  assign result_valid_o = result_valid_q;
  assign result_group_id_o = result_group_id_q;
  assign result_context_o = result_context_q;
  assign result_tag_o = result_tag_q;
  assign result_illegal_o = result_illegal_q;
  assign result_has_narrow_o = result_has_narrow_q;
  assign result_narrow_o = result_narrow_q;
  assign result_narrow_mask_o = result_narrow_mask_q;
  assign result_has_reduce_o = result_has_reduce_q;
  assign result_reduce_value_o = result_reduce_value_q;
  assign result_reduce_index_o = result_reduce_index_q;
  assign result_has_count_o = result_has_count_q;
  assign result_count_o = result_count_q;

  initial begin
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (LANES < 1) $error("LANES must be positive");
    if (ELEM_W < 1) $error("ELEM_W must be positive");
    if (ACC_W < ELEM_W) $error("ACC_W must be at least ELEM_W");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (TAG_W < 1) $error("TAG_W must be positive");
    if (CONTEXT_W != ((CONTEXT_COUNT <= 2) ? 1 :
                      $clog2(CONTEXT_COUNT))) begin
      $error("CONTEXT_W must match CONTEXT_COUNT");
    end
    if (GROUP_ID_W != ((GROUP_COUNT <= 2) ? 1 :
                       $clog2(GROUP_COUNT))) begin
      $error("GROUP_ID_W must match GROUP_COUNT");
    end
    if (INDEX_W != ((LANES <= 2) ? 1 : $clog2(LANES))) begin
      $error("INDEX_W must match LANES");
    end
    if (OFFSET_W != $clog2(LANES + 1)) begin
      $error("OFFSET_W must represent zero through LANES");
    end
  end
endmodule
