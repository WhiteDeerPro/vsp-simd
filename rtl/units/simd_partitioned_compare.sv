module simd_partitioned_compare #(
  parameter int LANES   = 4,
  parameter int SLICE_W = 8
) (
  input  logic [simd_pkg::ELEM_MODE_W-1:0] elem_mode_i,
  input  logic [(LANES*SLICE_W)-1:0]       a_i,
  input  logic [(LANES*SLICE_W)-1:0]       b_i,
  output logic [LANES-1:0]                 eq_o,
  output logic [LANES-1:0]                 gt_u_o,
  output logic [LANES-1:0]                 gt_s_o,
  output logic                             illegal_o
);
  import simd_pkg::*;

  // The chain walks from the least-significant byte toward the most-
  // significant byte. A differing higher byte replaces the relation formed
  // below it; an equal higher byte preserves that relation. Only the final
  // byte of an element uses signed comparison, so no 16/32-bit comparator is
  // instantiated alongside the byte comparators.
  logic [LANES-1:0] slice_eq;
  logic [LANES-1:0] slice_gt_u;
  logic [LANES-1:0] slice_gt_s;
  // This is a strictly feed-forward chain across ascending lane indices.
  // The lint implementation flattens the packed vectors and mistakes the
  // ascending-index dependency for feedback.
  /* verilator lint_off UNOPTFLAT */
  logic [LANES-1:0] prefix_eq;
  logic [LANES-1:0] prefix_gt_u;
  logic [LANES-1:0] prefix_gt_s;
  /* verilator lint_on UNOPTFLAT */

  function automatic logic is_element_start(input integer lane);
    case (elem_mode_i)
      ELEM_MODE_BYTE: is_element_start = 1'b1;
      ELEM_MODE_HALF: is_element_start = (lane % 2) == 0;
      ELEM_MODE_WORD: is_element_start = (lane % 4) == 0;
      default:        is_element_start = 1'b1;
    endcase
  endfunction

  function automatic logic is_element_end(input integer lane);
    case (elem_mode_i)
      ELEM_MODE_BYTE: is_element_end = 1'b1;
      ELEM_MODE_HALF: is_element_end = (lane % 2) == 1;
      ELEM_MODE_WORD: is_element_end = (lane % 4) == 3;
      default:        is_element_end = 1'b1;
    endcase
  endfunction

  generate
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_slice_compare
      logic signed [SLICE_W-1:0] a_signed;
      logic signed [SLICE_W-1:0] b_signed;
      logic signed_relation;

      assign a_signed = $signed(a_i[(lane*SLICE_W) +: SLICE_W]);
      assign b_signed = $signed(b_i[(lane*SLICE_W) +: SLICE_W]);
      assign slice_eq[lane] =
          a_i[(lane*SLICE_W) +: SLICE_W] ==
          b_i[(lane*SLICE_W) +: SLICE_W];
      assign slice_gt_u[lane] =
          a_i[(lane*SLICE_W) +: SLICE_W] >
          b_i[(lane*SLICE_W) +: SLICE_W];
      assign slice_gt_s[lane] = a_signed > b_signed;
      assign signed_relation = is_element_end(lane) ? slice_gt_s[lane]
                                                    : slice_gt_u[lane];

      if (lane == 0) begin : gen_first_slice
        assign prefix_eq[lane] = slice_eq[lane];
        assign prefix_gt_u[lane] = slice_gt_u[lane];
        assign prefix_gt_s[lane] = signed_relation;
      end else begin : gen_following_slice
        assign prefix_eq[lane] = is_element_start(lane)
            ? slice_eq[lane]
            : (prefix_eq[lane-1] && slice_eq[lane]);
        assign prefix_gt_u[lane] = is_element_start(lane)
            ? slice_gt_u[lane]
            : (slice_eq[lane] ? prefix_gt_u[lane-1] : slice_gt_u[lane]);
        assign prefix_gt_s[lane] = is_element_start(lane)
            ? signed_relation
            : (slice_eq[lane] ? prefix_gt_s[lane-1] : signed_relation);
      end
    end
  endgenerate

  always_comb begin
    eq_o = '0;
    gt_u_o = '0;
    gt_s_o = '0;
    illegal_o = 1'b0;

    unique case (elem_mode_i)
      ELEM_MODE_BYTE: begin
        eq_o = prefix_eq;
        gt_u_o = prefix_gt_u;
        gt_s_o = prefix_gt_s;
      end

      ELEM_MODE_HALF: begin
        for (int element = 0; element < (LANES/2); element++) begin
          eq_o[(element*2) +: 2] = {2{prefix_eq[(element*2)+1]}};
          gt_u_o[(element*2) +: 2] = {2{prefix_gt_u[(element*2)+1]}};
          gt_s_o[(element*2) +: 2] = {2{prefix_gt_s[(element*2)+1]}};
        end
      end

      ELEM_MODE_WORD: begin
        for (int element = 0; element < (LANES/4); element++) begin
          eq_o[(element*4) +: 4] = {4{prefix_eq[(element*4)+3]}};
          gt_u_o[(element*4) +: 4] = {4{prefix_gt_u[(element*4)+3]}};
          gt_s_o[(element*4) +: 4] = {4{prefix_gt_s[(element*4)+3]}};
        end
      end

      default: illegal_o = 1'b1;
    endcase

    if (illegal_o) begin
      eq_o = '0;
      gt_u_o = '0;
      gt_s_o = '0;
    end
  end

  initial begin
    if ((LANES % 4) != 0) begin
      $error("LANES must be divisible by four for WORD element mode");
    end
  end
endmodule
