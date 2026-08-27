module simd_dynamic_alu #(
  parameter int LANES   = 4,
  parameter int SLICE_W = 8
) (
  input  logic [simd_pkg::SIMD_OP_W-1:0]  op_i,
  input  logic [simd_pkg::ELEM_MODE_W-1:0] elem_mode_i,
  input  logic [(LANES*SLICE_W)-1:0]       a_i,
  input  logic [(LANES*SLICE_W)-1:0]       b_i,
  output logic [(LANES*SLICE_W)-1:0]       result_o,
  output logic [LANES-1:0]                 predicate_o,
  output logic                             illegal_o
);
  import simd_pkg::*;

  logic [(LANES*SLICE_W)-1:0] addsub_result;
  logic [(LANES*SLICE_W)-1:0] shift_result;
  logic addsub_illegal;
  logic shift_illegal;
  logic compare_illegal;
  logic [LANES-1:0] compare_eq;
  logic [LANES-1:0] compare_gt_u;
  logic [LANES-1:0] compare_gt_s;
  logic [(LANES*SLICE_W)-1:0] min_u_result;
  logic [(LANES*SLICE_W)-1:0] max_u_result;
  logic [(LANES*SLICE_W)-1:0] min_s_result;
  logic [(LANES*SLICE_W)-1:0] max_s_result;
  logic [(LANES*SLICE_W)-1:0] eq_result;
  logic [(LANES*SLICE_W)-1:0] gt_u_result;
  logic [(LANES*SLICE_W)-1:0] gt_s_result;
  logic subtract;
  logic shift_left;
  logic shift_arithmetic;

  assign subtract = op_i == SIMD_OP_SUB;
  assign shift_left = op_i == SIMD_OP_SHL;
  assign shift_arithmetic = op_i == SIMD_OP_SHR_S;

  simd_partitioned_addsub #(
    .LANES(LANES),
    .SLICE_W(SLICE_W)
  ) u_addsub (
    .elem_mode_i(elem_mode_i),
    .subtract_i(subtract),
    .a_i(a_i),
    .b_i(b_i),
    .result_o(addsub_result),
    .illegal_o(addsub_illegal)
  );

  simd_partitioned_shifter #(
    .LANES(LANES),
    .SLICE_W(SLICE_W)
  ) u_shifter (
    .elem_mode_i(elem_mode_i),
    .left_i(shift_left),
    .arithmetic_i(shift_arithmetic),
    .data_i(a_i),
    .amount_i(b_i),
    .result_o(shift_result),
    .illegal_o(shift_illegal)
  );

  simd_partitioned_compare #(
    .LANES(LANES),
    .SLICE_W(SLICE_W)
  ) u_compare (
    .elem_mode_i(elem_mode_i),
    .a_i(a_i),
    .b_i(b_i),
    .eq_o(compare_eq),
    .gt_u_o(compare_gt_u),
    .gt_s_o(compare_gt_s),
    .illegal_o(compare_illegal)
  );

  generate
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_compare_result
      assign min_u_result[(lane*SLICE_W) +: SLICE_W] = compare_gt_u[lane]
          ? b_i[(lane*SLICE_W) +: SLICE_W]
          : a_i[(lane*SLICE_W) +: SLICE_W];
      assign max_u_result[(lane*SLICE_W) +: SLICE_W] = compare_gt_u[lane]
          ? a_i[(lane*SLICE_W) +: SLICE_W]
          : b_i[(lane*SLICE_W) +: SLICE_W];
      assign min_s_result[(lane*SLICE_W) +: SLICE_W] = compare_gt_s[lane]
          ? b_i[(lane*SLICE_W) +: SLICE_W]
          : a_i[(lane*SLICE_W) +: SLICE_W];
      assign max_s_result[(lane*SLICE_W) +: SLICE_W] = compare_gt_s[lane]
          ? a_i[(lane*SLICE_W) +: SLICE_W]
          : b_i[(lane*SLICE_W) +: SLICE_W];
      assign eq_result[(lane*SLICE_W) +: SLICE_W] =
          {SLICE_W{compare_eq[lane]}};
      assign gt_u_result[(lane*SLICE_W) +: SLICE_W] =
          {SLICE_W{compare_gt_u[lane]}};
      assign gt_s_result[(lane*SLICE_W) +: SLICE_W] =
          {SLICE_W{compare_gt_s[lane]}};
    end
  endgenerate

  always_comb begin
    result_o = '0;
    predicate_o = '0;
    illegal_o = 1'b0;

    unique case (op_i)
      SIMD_OP_ADD,
      SIMD_OP_SUB: begin
        result_o = addsub_result;
        illegal_o = addsub_illegal;
      end
      SIMD_OP_SHL,
      SIMD_OP_SHR_U,
      SIMD_OP_SHR_S: begin
        result_o = shift_result;
        illegal_o = shift_illegal;
      end
      SIMD_OP_MIN_U: begin
        result_o = min_u_result;
        illegal_o = compare_illegal;
      end
      SIMD_OP_MAX_U: begin
        result_o = max_u_result;
        illegal_o = compare_illegal;
      end
      SIMD_OP_MIN_S: begin
        result_o = min_s_result;
        illegal_o = compare_illegal;
      end
      SIMD_OP_MAX_S: begin
        result_o = max_s_result;
        illegal_o = compare_illegal;
      end
      SIMD_OP_CMPEQ: begin
        result_o = eq_result;
        predicate_o = compare_eq;
        illegal_o = compare_illegal;
      end
      SIMD_OP_CMPGT_U: begin
        result_o = gt_u_result;
        predicate_o = compare_gt_u;
        illegal_o = compare_illegal;
      end
      SIMD_OP_CMPGT_S: begin
        result_o = gt_s_result;
        predicate_o = compare_gt_s;
        illegal_o = compare_illegal;
      end
      default: illegal_o = 1'b1;
    endcase

    if (illegal_o) begin
      result_o = '0;
      predicate_o = '0;
    end
  end
endmodule
