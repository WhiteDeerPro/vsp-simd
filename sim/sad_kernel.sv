module sad_kernel #(
  parameter int LANES  = 8,
  parameter int ELEM_W = 8,
  parameter int ACC_W  = 32
) (
  input  logic [LANES-1:0]               mask_i,
  input  logic [(LANES*ELEM_W)-1:0]      src_a_i,
  input  logic [(LANES*ELEM_W)-1:0]      src_b_i,
  output logic [ACC_W-1:0]               sad_o,
  output logic                           valid_o,
  output logic                           illegal_o
);
  import simd_pkg::*;

  localparam int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES);

  logic [(LANES*ELEM_W)-1:0] differences;
  logic [(LANES*ACC_W)-1:0] unused_wide;
  logic [LANES-1:0] unused_predicate;
  logic exec_illegal;
  logic reduce_illegal;
  logic [INDEX_W-1:0] unused_index;

  simd_exec #(
    .LANES(LANES),
    .ELEM_W(ELEM_W),
    .ACC_W(ACC_W)
  ) u_exec (
    .op_i(SIMD_OP_ABSDIFF_U),
    .elem_mode_i(ELEM_MODE_BYTE),
    .mask_i(mask_i),
    .select_i('0),
    .src_a_i(src_a_i),
    .src_b_i(src_b_i),
    .align_i('0),
    .merge_i('0),
    .acc_i('0),
    .result_o(differences),
    .wide_o(unused_wide),
    .predicate_o(unused_predicate),
    .illegal_o(exec_illegal)
  );

  simd_reduce #(
    .LANES(LANES),
    .DATA_W(ELEM_W),
    .ACC_W(ACC_W)
  ) u_reduce (
    .op_i(REDUCE_OP_SUM_U),
    .mask_i(mask_i),
    .data_i(differences),
    .value_o(sad_o),
    .index_o(unused_index),
    .valid_o(valid_o),
    .illegal_o(reduce_illegal)
  );

  always_comb illegal_o = exec_illegal | reduce_illegal;
endmodule
