module simd_lane #(
  parameter int ELEM_W = 8,
  parameter int ACC_W  = 32
) (
  input  logic [simd_pkg::SIMD_OP_W-1:0] op_i,
  input  logic [ELEM_W-1:0]               a_i,
  input  logic [ELEM_W-1:0]               b_i,
  input  logic [((ACC_W <= 2) ? 1 : $clog2(ACC_W))-1:0] align_i,
  input  logic [ACC_W-1:0]                acc_i,
  input  logic                            select_i,
  output logic [ELEM_W-1:0]               result_o,
  output logic [ACC_W-1:0]                wide_o,
  output logic                            predicate_o,
  output logic                            illegal_o
);
  import simd_pkg::*;

  localparam int SHAMT_W = (ELEM_W <= 2) ? 1 : $clog2(ELEM_W);
  localparam int SCALE_W = (ACC_W <= 2) ? 1 : $clog2(ACC_W);
  localparam logic [ELEM_W-1:0] SIGNED_MAX =
      {1'b0, {(ELEM_W-1){1'b1}}};
  localparam logic [ELEM_W-1:0] SIGNED_MIN =
      {1'b1, {(ELEM_W-1){1'b0}}};
  localparam logic signed [ACC_W-1:0] SIGNED_MAX_WIDE =
      {{(ACC_W-ELEM_W){1'b0}}, SIGNED_MAX};
  localparam logic signed [ACC_W-1:0] SIGNED_MIN_WIDE =
      {{(ACC_W-ELEM_W){1'b1}}, SIGNED_MIN};

  logic [ELEM_W:0] unsigned_sum;
  logic signed [ELEM_W:0] signed_sum;
  logic [ELEM_W-1:0] wrapped_sum;
  logic [(2*ELEM_W)-1:0] product_u;
  logic signed [(2*ELEM_W)-1:0] product_s;
  logic signed [ELEM_W-1:0] a_s;
  logic signed [ELEM_W-1:0] b_s;
  logic [SHAMT_W-1:0] shift_amount;
  logic [SCALE_W-1:0] scale_amount;
  logic [SCALE_W-1:0] align_amount;
  logic round_increment;
  logic [ACC_W-1:0] round_addend;
  logic [ACC_W-1:0] shifted_u;
  logic [ACC_W-1:0] rounded_shift_u;
  logic signed [ACC_W-1:0] rounded_shift_s;
  logic [ACC_W-1:0] widened_a_u;
  logic signed [ACC_W-1:0] widened_a_s;
  logic [ACC_W-1:0] widened_b_u;
  logic signed [ACC_W-1:0] widened_b_s;
  logic [ACC_W-1:0] shifted_widened_a_u;
  logic signed [ACC_W-1:0] shifted_widened_a_s;
  logic [ACC_W-1:0] aligned_a_u;
  logic signed [ACC_W-1:0] aligned_a_s;
  logic [ACC_W-1:0] aligned_b_u;
  logic signed [ACC_W-1:0] aligned_b_s;
  logic ternary_signed;
  logic ternary_subtract;
  logic [ACC_W-1:0] ternary_a;
  logic [ACC_W-1:0] ternary_b;
  logic [ACC_W-1:0] compressor_b;
  logic [ACC_W-1:0] compressor_sum;
  logic [ACC_W-1:0] compressor_carry;
  logic [ACC_W-1:0] compressor_carry_with_cin;
  logic [ACC_W-1:0] ternary_result;
  logic produces_wide;

  always_comb begin
    unsigned_sum = {1'b0, a_i} + {1'b0, b_i};
    signed_sum = $signed({a_i[ELEM_W-1], a_i}) +
                 $signed({b_i[ELEM_W-1], b_i});
    wrapped_sum = a_i + b_i;
    product_u = a_i * b_i;
    product_s = $signed(a_i) * $signed(b_i);
    a_s = $signed(a_i);
    b_s = $signed(b_i);
    shift_amount = b_i[SHAMT_W-1:0];
    scale_amount = b_i[SCALE_W-1:0];
    align_amount = align_i[SCALE_W-1:0];
    round_increment = (scale_amount == '0)
                          ? 1'b0
                          : acc_i[scale_amount-1'b1];
    round_addend = {{(ACC_W-1){1'b0}}, round_increment};
    shifted_u = acc_i >> scale_amount;
    rounded_shift_u = shifted_u + round_addend;
    rounded_shift_s = ($signed(acc_i) >>> scale_amount) +
                      $signed(round_addend);
    widened_a_u = {{(ACC_W-ELEM_W){1'b0}}, a_i};
    widened_a_s = {{(ACC_W-ELEM_W){a_i[ELEM_W-1]}}, a_i};
    widened_b_u = {{(ACC_W-ELEM_W){1'b0}}, b_i};
    widened_b_s = {{(ACC_W-ELEM_W){b_i[ELEM_W-1]}}, b_i};
    shifted_widened_a_u = widened_a_u << scale_amount;
    shifted_widened_a_s = widened_a_s <<< scale_amount;
    aligned_a_u = widened_a_u << align_amount;
    aligned_a_s = widened_a_s <<< align_amount;
    aligned_b_u = widened_b_u << align_amount;
    aligned_b_s = widened_b_s <<< align_amount;

    // WADD/WSUB are three-input operations. A single 3:2 compressor reduces
    // acc/A/B to carry-save form, followed by one carry-propagate addition.
    // For subtraction, complementing B and inserting the two's-complement one
    // at carry bit zero implements acc + A - B.
    ternary_signed = (op_i == SIMD_OP_WADD_S) ||
                     (op_i == SIMD_OP_WSUB_S);
    ternary_subtract = (op_i == SIMD_OP_WSUB_U) ||
                       (op_i == SIMD_OP_WSUB_S);
    ternary_a = ternary_signed ? aligned_a_s : aligned_a_u;
    ternary_b = ternary_signed ? aligned_b_s : aligned_b_u;
    compressor_b = ternary_subtract ? ~ternary_b : ternary_b;
    compressor_sum = acc_i ^ ternary_a ^ compressor_b;
    compressor_carry = ((acc_i & ternary_a) |
                        (acc_i & compressor_b) |
                        (ternary_a & compressor_b)) << 1;
    compressor_carry_with_cin = compressor_carry |
        {{(ACC_W-1){1'b0}}, ternary_subtract};
    ternary_result = compressor_sum + compressor_carry_with_cin;

    result_o = '0;
    wide_o = '0;
    predicate_o = 1'b0;
    illegal_o = 1'b0;
    produces_wide = 1'b0;

    case (op_i)
      SIMD_OP_ADD: result_o = wrapped_sum;
      SIMD_OP_SUB: result_o = a_i - b_i;

      SIMD_OP_ADD_SAT_U: begin
        result_o = unsigned_sum[ELEM_W] ? {ELEM_W{1'b1}}
                                        : unsigned_sum[ELEM_W-1:0];
      end

      SIMD_OP_SUB_SAT_U: begin
        result_o = (a_i < b_i) ? '0 : (a_i - b_i);
      end

      SIMD_OP_ADD_SAT_S: begin
        if ((a_i[ELEM_W-1] == b_i[ELEM_W-1]) &&
            (wrapped_sum[ELEM_W-1] != a_i[ELEM_W-1])) begin
          result_o = a_i[ELEM_W-1] ? SIGNED_MIN : SIGNED_MAX;
        end else begin
          result_o = wrapped_sum;
        end
      end

      SIMD_OP_SUB_SAT_S: begin
        result_o = a_i - b_i;
        if ((a_i[ELEM_W-1] != b_i[ELEM_W-1]) &&
            (result_o[ELEM_W-1] != a_i[ELEM_W-1])) begin
          result_o = a_i[ELEM_W-1] ? SIGNED_MIN : SIGNED_MAX;
        end
      end

      SIMD_OP_MIN_U: result_o = (a_i < b_i) ? a_i : b_i;
      SIMD_OP_MAX_U: result_o = (a_i > b_i) ? a_i : b_i;
      SIMD_OP_MIN_S: result_o = (a_s < b_s) ? a_i : b_i;
      SIMD_OP_MAX_S: result_o = (a_s > b_s) ? a_i : b_i;

      SIMD_OP_ABSDIFF_U: begin
        result_o = (a_i >= b_i) ? (a_i - b_i) : (b_i - a_i);
      end

      SIMD_OP_AVG_U: begin
        result_o = unsigned_sum[ELEM_W:1] +
                   {{(ELEM_W-1){1'b0}}, unsigned_sum[0]};
      end

      SIMD_OP_AVG_S: begin
        result_o = signed_sum[ELEM_W:1] +
                   {{(ELEM_W-1){1'b0}}, signed_sum[0]};
      end

      SIMD_OP_AND: result_o = a_i & b_i;
      SIMD_OP_OR:  result_o = a_i | b_i;
      SIMD_OP_XOR: result_o = a_i ^ b_i;
      SIMD_OP_SHL:   result_o = a_i << shift_amount;
      SIMD_OP_SHR_U: result_o = a_i >> shift_amount;
      SIMD_OP_SHR_S: result_o = a_s >>> shift_amount;

      SIMD_OP_CMPEQ: begin
        predicate_o = (a_i == b_i);
        result_o = predicate_o ? {ELEM_W{1'b1}} : '0;
      end

      SIMD_OP_CMPGT_U: begin
        predicate_o = (a_i > b_i);
        result_o = predicate_o ? {ELEM_W{1'b1}} : '0;
      end

      SIMD_OP_CMPGT_S: begin
        predicate_o = (a_s > b_s);
        result_o = predicate_o ? {ELEM_W{1'b1}} : '0;
      end

      SIMD_OP_ABS_SAT_S: begin
        if (a_i == SIGNED_MIN) begin
          result_o = SIGNED_MAX;
        end else if (a_i[ELEM_W-1]) begin
          result_o = -a_i;
        end else begin
          result_o = a_i;
        end
      end

      SIMD_OP_MUL_U: begin
        result_o = product_u[ELEM_W-1:0];
        wide_o = {{(ACC_W-(2*ELEM_W)){1'b0}}, product_u};
        produces_wide = 1'b1;
      end

      SIMD_OP_MUL_S: begin
        result_o = product_s[ELEM_W-1:0];
        wide_o = {{(ACC_W-(2*ELEM_W)){product_s[(2*ELEM_W)-1]}}, product_s};
        produces_wide = 1'b1;
      end

      SIMD_OP_MAC_U: begin
        result_o = product_u[ELEM_W-1:0];
        wide_o = acc_i + {{(ACC_W-(2*ELEM_W)){1'b0}}, product_u};
        produces_wide = 1'b1;
      end

      SIMD_OP_MAC_S: begin
        result_o = product_s[ELEM_W-1:0];
        wide_o = acc_i +
                 {{(ACC_W-(2*ELEM_W)){product_s[(2*ELEM_W)-1]}}, product_s};
        produces_wide = 1'b1;
      end

      SIMD_OP_PASS_A: result_o = a_i;

      SIMD_OP_SELECT: result_o = select_i ? a_i : b_i;

      SIMD_OP_WIDEN_U: begin
        wide_o = shifted_widened_a_u;
        result_o = wide_o[ELEM_W-1:0];
        produces_wide = 1'b1;
      end

      SIMD_OP_WIDEN_S: begin
        wide_o = shifted_widened_a_s;
        result_o = wide_o[ELEM_W-1:0];
        produces_wide = 1'b1;
      end

      SIMD_OP_WADD_U: begin
        wide_o = ternary_result;
        result_o = wide_o[ELEM_W-1:0];
        produces_wide = 1'b1;
      end

      SIMD_OP_WADD_S: begin
        wide_o = ternary_result;
        result_o = wide_o[ELEM_W-1:0];
        produces_wide = 1'b1;
      end

      SIMD_OP_WSUB_U: begin
        wide_o = ternary_result;
        result_o = wide_o[ELEM_W-1:0];
        produces_wide = 1'b1;
      end

      SIMD_OP_WSUB_S: begin
        wide_o = ternary_result;
        result_o = wide_o[ELEM_W-1:0];
        produces_wide = 1'b1;
      end

      SIMD_OP_RSHIFT_RND_U: begin
        result_o = rounded_shift_u[ELEM_W-1:0];
        wide_o = rounded_shift_u;
        produces_wide = 1'b1;
      end

      SIMD_OP_RSHIFT_RND_S: begin
        result_o = rounded_shift_s[ELEM_W-1:0];
        wide_o = rounded_shift_s;
        produces_wide = 1'b1;
      end

      SIMD_OP_NCLIP_U: begin
        if (|rounded_shift_u[ACC_W-1:ELEM_W]) begin
          result_o = {ELEM_W{1'b1}};
        end else begin
          result_o = rounded_shift_u[ELEM_W-1:0];
        end
      end

      SIMD_OP_NCLIP_S: begin
        if (rounded_shift_s > SIGNED_MAX_WIDE) begin
          result_o = SIGNED_MAX;
        end else if (rounded_shift_s < SIGNED_MIN_WIDE) begin
          result_o = SIGNED_MIN;
        end else begin
          result_o = rounded_shift_s[ELEM_W-1:0];
        end
      end

      SIMD_OP_NSLICE: begin
        result_o = shifted_u[ELEM_W-1:0];
      end

      default: begin
        illegal_o = 1'b1;
        produces_wide = 1'b1;
      end
    endcase

    if (!produces_wide) begin
      wide_o = {{(ACC_W-ELEM_W){1'b0}}, result_o};
    end
  end

  initial begin
    if (ELEM_W < 2) $error("ELEM_W must be at least 2");
    if (ACC_W < (2 * ELEM_W)) begin
      $error("ACC_W must hold a full product");
    end
    if (ELEM_W < SCALE_W) begin
      $error("ELEM_W must hold an ACC_W shift amount");
    end
  end
endmodule
