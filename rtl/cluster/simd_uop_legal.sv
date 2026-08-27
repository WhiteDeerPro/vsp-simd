module simd_uop_legal (
  input  logic [simd_pkg::SIMD_OP_W-1:0]  op_i,
  input  logic [simd_pkg::ELEM_MODE_W-1:0] elem_mode_i,
  input  logic                             write_vrf_i,
  input  logic                             write_arf_i,
  input  logic                             write_mrf_i,
  input  logic                             reduce_enable_i,
  input  logic                             route_enable_i,
  output logic                             mode_legal_o,
  output logic                             writeback_legal_o,
  output logic                             reduce_legal_o,
  output logic                             route_legal_o,
  output logic                             legal_o
);
  import simd_pkg::*;

  always_comb begin
    mode_legal_o = simd_op_mode_legal(op_i, elem_mode_i);
    writeback_legal_o = (!write_vrf_i || simd_op_can_write_vrf(op_i)) &&
                        (!write_arf_i || simd_op_can_write_arf(op_i)) &&
                        (!write_mrf_i || simd_op_can_write_mrf(op_i));
    reduce_legal_o = !reduce_enable_i ||
                     simd_op_can_reduce(op_i, elem_mode_i);
    route_legal_o = !route_enable_i || simd_op_can_route_a(op_i);
    legal_o = mode_legal_o && writeback_legal_o &&
              reduce_legal_o && route_legal_o;
  end
endmodule
