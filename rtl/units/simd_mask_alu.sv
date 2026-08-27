module simd_mask_alu #(
  parameter int LANES = 4
) (
  input  logic [simd_pkg::SIMD_OP_W-1:0] op_i,
  input  logic [LANES-1:0]                a_i,
  input  logic [LANES-1:0]                b_i,
  output logic [LANES-1:0]                result_o,
  output logic                            illegal_o
);
  import simd_pkg::*;

  always_comb begin
    result_o = '0;
    illegal_o = 1'b0;

    unique case (op_i)
      SIMD_OP_MAND: result_o = a_i & b_i;
      SIMD_OP_MOR:  result_o = a_i | b_i;
      SIMD_OP_MXOR: result_o = a_i ^ b_i;
      SIMD_OP_MNOT: result_o = ~a_i;
      default: begin
        result_o = '0;
        illegal_o = 1'b1;
      end
    endcase
  end
endmodule
