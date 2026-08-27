module simd_partitioned_shifter #(
  parameter int LANES   = 4,
  parameter int SLICE_W = 8
) (
  input  logic [simd_pkg::ELEM_MODE_W-1:0] elem_mode_i,
  input  logic                              left_i,
  input  logic                              arithmetic_i,
  input  logic [(LANES*SLICE_W)-1:0]        data_i,
  // The low log2(element width) bits of each logical element select its own
  // shift amount. Higher bytes of an amount operand are ordinary data bits.
  input  logic [(LANES*SLICE_W)-1:0]        amount_i,
  output logic [(LANES*SLICE_W)-1:0]        result_o,
  output logic                              illegal_o
);
  import simd_pkg::*;

  localparam int GROUP_W = LANES * SLICE_W;
  localparam int WORD_W = 4 * SLICE_W;
  localparam int STAGES = (WORD_W <= 2) ? 1 : $clog2(WORD_W);

  // Each unpacked entry is one feed-forward barrel-shifter stage. The lint
  // implementation flattens this array and mistakes it for feedback.
  /* verilator lint_off UNOPTFLAT */
  logic [GROUP_W-1:0] stage_data [0:STAGES];
  /* verilator lint_on UNOPTFLAT */

  function automatic logic same_element(input integer lhs,
                                        input integer rhs);
    case (elem_mode_i)
      ELEM_MODE_BYTE:
        same_element = (lhs / SLICE_W) == (rhs / SLICE_W);
      ELEM_MODE_HALF:
        same_element = (lhs / (2*SLICE_W)) == (rhs / (2*SLICE_W));
      ELEM_MODE_WORD:
        same_element = (lhs / (4*SLICE_W)) == (rhs / (4*SLICE_W));
      default: same_element = 1'b0;
    endcase
  endfunction

  function automatic logic shift_control(input integer bit_index,
                                         input integer level);
    integer element_base;
    begin
      shift_control = 1'b0;
      element_base = 0;
      case (elem_mode_i)
        ELEM_MODE_BYTE: begin
          element_base = (bit_index / SLICE_W) * SLICE_W;
          if (level < $clog2(SLICE_W)) begin
            shift_control = amount_i[element_base + level];
          end
        end
        ELEM_MODE_HALF: begin
          element_base = (bit_index / (2*SLICE_W)) * (2*SLICE_W);
          if (level < $clog2(2*SLICE_W)) begin
            shift_control = amount_i[element_base + level];
          end
        end
        ELEM_MODE_WORD: begin
          element_base = (bit_index / (4*SLICE_W)) * (4*SLICE_W);
          if (level < $clog2(4*SLICE_W)) begin
            shift_control = amount_i[element_base + level];
          end
        end
        default: shift_control = 1'b0;
      endcase
    end
  endfunction

  function automatic logic element_sign(input integer bit_index);
    begin
      case (elem_mode_i)
        ELEM_MODE_BYTE:
          element_sign =
              data_i[((bit_index / SLICE_W) * SLICE_W) + SLICE_W - 1];
        ELEM_MODE_HALF:
          element_sign = data_i[
              ((bit_index / (2*SLICE_W)) * (2*SLICE_W)) +
              (2*SLICE_W) - 1];
        ELEM_MODE_WORD:
          element_sign = data_i[
              ((bit_index / (4*SLICE_W)) * (4*SLICE_W)) +
              (4*SLICE_W) - 1];
        default: element_sign = 1'b0;
      endcase
    end
  endfunction

  assign stage_data[0] = data_i;

  generate
    for (genvar level = 0; level < STAGES; level++) begin : gen_stage
      localparam int OFFSET = 1 << level;

      for (genvar bit_index = 0; bit_index < GROUP_W;
           bit_index++) begin : gen_bit
        logic left_candidate;
        logic right_candidate;
        logic shifted_candidate;

        if (bit_index >= OFFSET) begin : gen_left_source
          assign left_candidate =
              same_element(bit_index, bit_index-OFFSET)
                  ? stage_data[level][bit_index-OFFSET] : 1'b0;
        end else begin : gen_left_fill
          assign left_candidate = 1'b0;
        end

        if ((bit_index + OFFSET) < GROUP_W) begin : gen_right_source
          assign right_candidate =
              same_element(bit_index, bit_index+OFFSET)
                  ? stage_data[level][bit_index+OFFSET]
                  : (arithmetic_i ? element_sign(bit_index) : 1'b0);
        end else begin : gen_right_fill
          assign right_candidate = arithmetic_i ? element_sign(bit_index)
                                                 : 1'b0;
        end

        assign shifted_candidate = left_i ? left_candidate : right_candidate;
        assign stage_data[level+1][bit_index] =
            shift_control(bit_index, level)
                ? shifted_candidate : stage_data[level][bit_index];
      end
    end
  endgenerate

  assign result_o = (elem_mode_i == 2'h3) ? '0 : stage_data[STAGES];
  assign illegal_o = elem_mode_i == 2'h3;

  initial begin
    if ((LANES % 4) != 0) begin
      $error("LANES must be divisible by four for WORD element mode");
    end
    if ((SLICE_W & (SLICE_W-1)) != 0) begin
      $error("SLICE_W must be a power of two");
    end
  end
endmodule
