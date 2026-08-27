module simd_exec #(
  parameter int LANES  = 4,
  parameter int ELEM_W = 8,
  parameter int ACC_W  = 32
) (
  input  logic [simd_pkg::SIMD_OP_W-1:0] op_i,
  input  logic [simd_pkg::ELEM_MODE_W-1:0] elem_mode_i,
  input  logic [LANES-1:0]                mask_i,
  input  logic [LANES-1:0]                select_i,
  input  logic [(LANES*ELEM_W)-1:0]       src_a_i,
  input  logic [(LANES*ELEM_W)-1:0]       src_b_i,
  // Shared fixed-point alignment for the three-input WADD/WSUB family.
  input  logic [((ACC_W <= 2) ? 1 : $clog2(ACC_W))-1:0] align_i,
  input  logic [(LANES*ELEM_W)-1:0]       merge_i,
  input  logic [(LANES*ACC_W)-1:0]        acc_i,
  output logic [(LANES*ELEM_W)-1:0]       result_o,
  output logic [(LANES*ACC_W)-1:0]        wide_o,
  output logic [LANES-1:0]                predicate_o,
  output logic                            illegal_o
);
  logic [LANES-1:0] lane_illegal;
  logic [(LANES*ELEM_W)-1:0] dynamic_result;
  logic [LANES-1:0] dynamic_predicate;
  logic dynamic_op;
  logic dynamic_illegal;

  assign dynamic_op = (op_i == simd_pkg::SIMD_OP_ADD) ||
                      (op_i == simd_pkg::SIMD_OP_SUB) ||
                      (op_i == simd_pkg::SIMD_OP_MIN_U) ||
                      (op_i == simd_pkg::SIMD_OP_MAX_U) ||
                      (op_i == simd_pkg::SIMD_OP_MIN_S) ||
                      (op_i == simd_pkg::SIMD_OP_MAX_S) ||
                      (op_i == simd_pkg::SIMD_OP_SHL) ||
                      (op_i == simd_pkg::SIMD_OP_SHR_U) ||
                      (op_i == simd_pkg::SIMD_OP_SHR_S) ||
                      (op_i == simd_pkg::SIMD_OP_CMPEQ) ||
                      (op_i == simd_pkg::SIMD_OP_CMPGT_U) ||
                      (op_i == simd_pkg::SIMD_OP_CMPGT_S);
  simd_dynamic_alu #(
    .LANES(LANES),
    .SLICE_W(ELEM_W)
  ) u_dynamic_alu (
    .op_i(op_i),
    .elem_mode_i(elem_mode_i),
    .a_i(src_a_i),
    .b_i(src_b_i),
    .result_o(dynamic_result),
    .predicate_o(dynamic_predicate),
    .illegal_o(dynamic_illegal)
  );

  generate
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_lanes
      logic [ELEM_W-1:0] lane_result;
      logic [ACC_W-1:0] lane_wide;
      logic lane_predicate;

      simd_lane #(
        .ELEM_W(ELEM_W),
        .ACC_W(ACC_W)
      ) u_lane (
        .op_i(op_i),
        .a_i(src_a_i[(lane*ELEM_W) +: ELEM_W]),
        .b_i(src_b_i[(lane*ELEM_W) +: ELEM_W]),
        .align_i(align_i),
        .acc_i(acc_i[(lane*ACC_W) +: ACC_W]),
        .select_i(select_i[lane]),
        .result_o(lane_result),
        .wide_o(lane_wide),
        .predicate_o(lane_predicate),
        .illegal_o(lane_illegal[lane])
      );

      always_comb begin
        if (mask_i[lane]) begin
          if (dynamic_op) begin
            result_o[(lane*ELEM_W) +: ELEM_W] =
                dynamic_result[(lane*ELEM_W) +: ELEM_W];
            wide_o[(lane*ACC_W) +: ACC_W] =
                {{(ACC_W-ELEM_W){1'b0}},
                 dynamic_result[(lane*ELEM_W) +: ELEM_W]};
            predicate_o[lane] = dynamic_predicate[lane];
          end else begin
            result_o[(lane*ELEM_W) +: ELEM_W] = lane_result;
            wide_o[(lane*ACC_W) +: ACC_W] = lane_wide;
            predicate_o[lane] = lane_predicate;
          end
        end else begin
          result_o[(lane*ELEM_W) +: ELEM_W] =
              merge_i[(lane*ELEM_W) +: ELEM_W];
          wide_o[(lane*ACC_W) +: ACC_W] =
              acc_i[(lane*ACC_W) +: ACC_W];
          predicate_o[lane] = 1'b0;
        end
      end
    end
  endgenerate

  always_comb illegal_o = dynamic_op ? dynamic_illegal : |lane_illegal;
endmodule
