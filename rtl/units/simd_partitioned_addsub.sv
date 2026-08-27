module simd_partitioned_addsub #(
  parameter int LANES   = 4,
  parameter int SLICE_W = 8
) (
  input  logic [simd_pkg::ELEM_MODE_W-1:0] elem_mode_i,
  input  logic                              subtract_i,
  input  logic [(LANES*SLICE_W)-1:0]        a_i,
  input  logic [(LANES*SLICE_W)-1:0]        b_i,
  output logic [(LANES*SLICE_W)-1:0]        result_o,
  output logic                              illegal_o
);
  import simd_pkg::*;

  logic carry;
  logic [SLICE_W:0] slice_sum;
  logic element_start;

  always_comb begin
    result_o = '0;
    carry = subtract_i;
    slice_sum = '0;
    element_start = 1'b0;
    illegal_o = elem_mode_i == 2'h3;

    for (int lane = 0; lane < LANES; lane++) begin
      unique case (elem_mode_i)
        ELEM_MODE_BYTE: element_start = 1'b1;
        ELEM_MODE_HALF: element_start = (lane % 2) == 0;
        ELEM_MODE_WORD: element_start = (lane % 4) == 0;
        default:        element_start = 1'b1;
      endcase

      if (element_start) carry = subtract_i;
      slice_sum = {1'b0, a_i[(lane*SLICE_W) +: SLICE_W]} +
                  {1'b0, (b_i[(lane*SLICE_W) +: SLICE_W] ^
                           {SLICE_W{subtract_i}})} +
                  {{SLICE_W{1'b0}}, carry};
      result_o[(lane*SLICE_W) +: SLICE_W] = slice_sum[SLICE_W-1:0];
      carry = slice_sum[SLICE_W];
    end

    if (illegal_o) result_o = '0;
  end

  initial begin
    if ((LANES % 4) != 0) begin
      $error("LANES must be divisible by four for WORD element mode");
    end
  end
endmodule
