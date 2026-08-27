#include "Vsimd_datapath.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr uint8_t ADD_SAT_U = 0x02;
constexpr uint8_t ADD = 0x00;
constexpr uint8_t SUB = 0x01;
constexpr uint8_t MIN_U = 0x06;
constexpr uint8_t MIN_S = 0x08;
constexpr uint8_t CMPEQ = 0x12;
constexpr uint8_t CMPGT_U = 0x13;
constexpr uint8_t CMPGT_S = 0x14;
constexpr uint8_t MAC_U = 0x18;
constexpr uint8_t PASS_A = 0x1a;
constexpr uint8_t SELECT = 0x1b;
constexpr uint8_t WIDEN_U = 0x1c;
constexpr uint8_t WADD_U = 0x1e;
constexpr uint8_t WADD_S = 0x1f;
constexpr uint8_t WSUB_U = 0x20;
constexpr uint8_t WSUB_S = 0x21;
constexpr uint8_t RSHIFT_RND_U = 0x22;
constexpr uint8_t NSLICE = 0x26;
constexpr uint8_t COMPRESS = 0x28;
constexpr uint8_t EXPAND = 0x29;
constexpr uint8_t MAND = 0x2a;
constexpr uint8_t MOR = 0x2b;
constexpr uint8_t MXOR = 0x2c;
constexpr uint8_t MNOT = 0x2d;
constexpr uint8_t ABSDIFF_U = 0x0a;
constexpr uint8_t SHL = 0x0f;
constexpr uint8_t REDUCE_SUM_U = 0;
constexpr uint8_t ROUTE_GATHER = 0;
constexpr uint8_t ROUTE_BROADCAST = 1;
constexpr uint8_t ROUTE_SLIDE_UP = 2;

uint32_t pack8(const std::array<uint8_t, 4>& lanes) {
  uint32_t packed = 0;
  for (unsigned lane = 0; lane < 4; ++lane) {
    packed |= static_cast<uint32_t>(lanes[lane]) << (lane * 8);
  }
  return packed;
}

uint8_t pack_indices(const std::array<uint8_t, 4>& indices) {
  uint8_t packed = 0;
  for (unsigned lane = 0; lane < 4; ++lane) {
    packed |= static_cast<uint8_t>(indices[lane] << (lane * 2));
  }
  return packed;
}

uint32_t materialize_mask(uint8_t mask) {
  uint32_t packed = 0;
  for (unsigned lane = 0; lane < 4; ++lane) {
    if (mask & (1u << lane)) packed |= 0xffu << (lane * 8);
  }
  return packed;
}

void tick(Vsimd_datapath& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

[[noreturn]] void fail(const char* field, uint64_t expected, uint64_t actual) {
  std::cerr << "FAIL " << field << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void write_vrf(Vsimd_datapath& dut, uint8_t addr,
               const std::array<uint8_t, 4>& data) {
  dut.cfg_vrf_write_i = 1;
  dut.cfg_vrf_addr_i = addr;
  dut.cfg_vrf_mask_i = 0xf;
  dut.cfg_vrf_data_i = pack8(data);
  tick(dut);
  dut.cfg_vrf_write_i = 0;
}

void write_arf(Vsimd_datapath& dut, uint8_t addr,
               const std::array<uint32_t, 4>& data) {
  dut.cfg_arf_write_i = 1;
  dut.cfg_arf_addr_i = addr;
  dut.cfg_arf_mask_i = 0xf;
  for (unsigned lane = 0; lane < 4; ++lane) dut.cfg_arf_data_i[lane] = data[lane];
  tick(dut);
  dut.cfg_arf_write_i = 0;
}

void write_mrf(Vsimd_datapath& dut, uint8_t addr, uint8_t data) {
  dut.cfg_mrf_write_i = 1;
  dut.cfg_mrf_addr_i = addr;
  dut.cfg_mrf_mask_i = 0xf;
  dut.cfg_mrf_data_i = data;
  tick(dut);
  dut.cfg_mrf_write_i = 0;
}

void clear_controls(Vsimd_datapath& dut) {
  dut.issue_i = 0;
  dut.elem_mode_i = 0;
  dut.write_vrf_i = 0;
  dut.write_arf_i = 0;
  dut.write_mrf_i = 0;
  dut.reduce_enable_i = 0;
  dut.route_enable_i = 0;
  dut.route_index_i = 0;
  dut.route_broadcast_index_i = 0;
  dut.route_slide_amount_i = 0;
  dut.route_lower_i = 0;
  dut.route_upper_i = 0;
  dut.mask_enable_i = 0;
  dut.use_imm_i = 0;
  dut.imm_i = 0;
  dut.cfg_vrf_write_i = 0;
  dut.cfg_arf_write_i = 0;
  dut.cfg_mrf_write_i = 0;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_datapath dut;
  clear_controls(dut);

  write_vrf(dut, 0, {0, 0, 0, 0});
  write_vrf(dut, 1, {250, 10, 100, 20});
  write_vrf(dut, 2, {10, 20, 50, 30});
  write_vrf(dut, 3, {9, 9, 9, 9});
  write_vrf(dut, 4, {0, 0, 0, 0});
  write_arf(dut, 0, {1000, 2000, 3000, 4000});
  write_arf(dut, 1, {7, 7, 7, 7});
  write_mrf(dut, 0, 0x5);

  // Masked narrow write: inactive lanes in v3 must remain unchanged.
  dut.issue_i = 1;
  dut.op_i = ADD_SAT_U;
  dut.src_a_addr_i = 1;
  dut.src_b_addr_i = 2;
  dut.dst_vrf_addr_i = 3;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 0;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 3;
  dut.eval();
  if (dut.narrow_result_o != pack8({255, 9, 150, 9})) {
    fail("masked VRF write", pack8({255, 9, 150, 9}), dut.narrow_result_o);
  }

  // Predicate write to MRF, followed by SELECT consuming that predicate.
  dut.issue_i = 1;
  dut.op_i = CMPGT_U;
  dut.src_a_addr_i = 1;
  dut.src_b_addr_i = 2;
  dut.dst_mrf_addr_i = 1;
  dut.write_mrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = SELECT;
  dut.src_a_addr_i = 1;
  dut.src_b_addr_i = 2;
  dut.select_mask_addr_i = 1;
  dut.dst_vrf_addr_i = 4;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 4;
  dut.eval();
  if (dut.narrow_result_o != pack8({250, 20, 100, 30})) {
    fail("predicate SELECT", pack8({250, 20, 100, 30}), dut.narrow_result_o);
  }

  // Masked wide write: ARF lanes 1 and 3 must preserve their prior value.
  dut.issue_i = 1;
  dut.op_i = MAC_U;
  dut.src_a_addr_i = 1;
  dut.src_b_addr_i = 2;
  dut.src_arf_addr_i = 0;
  dut.dst_arf_addr_i = 1;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 0;
  dut.write_arf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = RSHIFT_RND_U;
  dut.src_b_addr_i = 0;
  dut.src_arf_addr_i = 1;
  dut.eval();
  const std::array<uint32_t, 4> expected_arf{3500, 7, 8000, 7};
  for (unsigned lane = 0; lane < 4; ++lane) {
    if (dut.wide_result_o[lane] != expected_arf[lane]) {
      fail("masked ARF write", expected_arf[lane], dut.wide_result_o[lane]);
    }
  }

  // A malformed optional reduction invalidates the complete transaction. The
  // legal ADD portion must not commit while illegal_o reports the bad reduce.
  write_vrf(dut, 12, {1, 2, 3, 4});
  write_vrf(dut, 13, {10, 20, 30, 40});
  write_vrf(dut, 14, {90, 91, 92, 93});
  dut.issue_i = 1;
  dut.op_i = ADD;
  dut.src_a_addr_i = 12;
  dut.src_b_addr_i = 13;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  dut.reduce_enable_i = 1;
  dut.reduce_op_i = 7;
  tick(dut);
  if (!dut.illegal_o) fail("illegal reduction status", 1, dut.illegal_o);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({90, 91, 92, 93})) {
    fail("illegal reduction write suppression", pack8({90, 91, 92, 93}),
         dut.narrow_result_o);
  }

  // WADD consumes both VRF read ports as data and adds both extended values to
  // the ARF source. With no immediate, their common alignment is zero.
  write_vrf(dut, 10, {5, 250, 7, 200});
  write_vrf(dut, 11, {10, 20, 30, 40});
  write_arf(dut, 3, {1000, 2000, 3000, 4000});
  dut.issue_i = 1;
  dut.op_i = WADD_U;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.src_arf_addr_i = 3;
  dut.dst_arf_addr_i = 4;
  dut.write_arf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = RSHIFT_RND_U;
  dut.src_b_addr_i = 0;
  dut.src_arf_addr_i = 4;
  dut.eval();
  const std::array<uint32_t, 4> expected_wadd_u{1015, 2270, 3037, 4240};
  for (unsigned lane = 0; lane < 4; ++lane) {
    if (dut.wide_result_o[lane] != expected_wadd_u[lane]) {
      fail("WADD_U ARF+A+B", expected_wadd_u[lane],
           dut.wide_result_o[lane]);
    }
  }

  // In the WADD/WSUB family, the scalar immediate is a common alignment and
  // does not replace the second VRF data source.
  dut.issue_i = 1;
  dut.op_i = WADD_U;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.use_imm_i = 1;
  dut.imm_i = 2;
  dut.src_arf_addr_i = 3;
  dut.dst_arf_addr_i = 4;
  dut.write_arf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = RSHIFT_RND_U;
  dut.src_b_addr_i = 0;
  dut.src_arf_addr_i = 4;
  dut.eval();
  const std::array<uint32_t, 4> expected_wadd_imm{1060, 3080, 3148, 4960};
  for (unsigned lane = 0; lane < 4; ++lane) {
    if (dut.wide_result_o[lane] != expected_wadd_imm[lane]) {
      fail("WADD_U common immediate alignment", expected_wadd_imm[lane],
           dut.wide_result_o[lane]);
    }
  }

  write_vrf(dut, 12, {0xff, 0x80, 0x7f, 0x01});
  write_arf(dut, 5, {1000, 2000, 3000, 4000});
  dut.issue_i = 1;
  dut.op_i = WADD_S;
  dut.src_a_addr_i = 12;
  dut.src_b_addr_i = 11;
  dut.src_arf_addr_i = 5;
  dut.dst_arf_addr_i = 6;
  dut.write_arf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = RSHIFT_RND_U;
  dut.src_b_addr_i = 0;
  dut.src_arf_addr_i = 6;
  dut.eval();
  const std::array<uint32_t, 4> expected_wadd_s{1009, 1892, 3157, 4041};
  for (unsigned lane = 0; lane < 4; ++lane) {
    if (dut.wide_result_o[lane] != expected_wadd_s[lane]) {
      fail("WADD_S ARF+A+B", expected_wadd_s[lane],
           dut.wide_result_o[lane]);
    }
  }

  // WSUB keeps the same three inputs and computes ARF + A - B.
  dut.issue_i = 1;
  dut.op_i = WSUB_U;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.src_arf_addr_i = 3;
  dut.dst_arf_addr_i = 4;
  dut.write_arf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = RSHIFT_RND_U;
  dut.src_b_addr_i = 0;
  dut.src_arf_addr_i = 4;
  dut.eval();
  const std::array<uint32_t, 4> expected_wsub_u{995, 2230, 2977, 4160};
  for (unsigned lane = 0; lane < 4; ++lane) {
    if (dut.wide_result_o[lane] != expected_wsub_u[lane]) {
      fail("WSUB_U ARF+A-B", expected_wsub_u[lane],
           dut.wide_result_o[lane]);
    }
  }

  dut.issue_i = 1;
  dut.op_i = WSUB_S;
  dut.src_a_addr_i = 12;
  dut.src_b_addr_i = 11;
  dut.src_arf_addr_i = 5;
  dut.dst_arf_addr_i = 6;
  dut.write_arf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = RSHIFT_RND_U;
  dut.src_b_addr_i = 0;
  dut.src_arf_addr_i = 6;
  dut.eval();
  const std::array<uint32_t, 4> expected_wsub_s{989, 1852, 3097, 3961};
  for (unsigned lane = 0; lane < 4; ++lane) {
    if (dut.wide_result_o[lane] != expected_wsub_s[lane]) {
      fail("WSUB_S ARF+A-B", expected_wsub_s[lane],
           dut.wide_result_o[lane]);
    }
  }

  // Composed masked SAD reduction is returned directly to the sequencer.
  dut.issue_i = 1;
  dut.op_i = ABSDIFF_U;
  dut.src_a_addr_i = 1;
  dut.src_b_addr_i = 2;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 0;
  dut.reduce_enable_i = 1;
  dut.reduce_op_i = REDUCE_SUM_U;
  dut.eval();
  if (!dut.reduce_valid_o || dut.reduce_value_o != 290 || dut.illegal_o) {
    fail("masked SAD reduction", 290, dut.reduce_value_o);
  }
  clear_controls(dut);

  // One shared source-A crossbar implements arbitrary gather, including
  // repeated source indices. PASS_A turns it into a standalone route write.
  dut.issue_i = 1;
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 1;
  dut.dst_vrf_addr_i = 5;
  dut.write_vrf_i = 1;
  dut.route_enable_i = 1;
  dut.route_op_i = ROUTE_GATHER;
  dut.route_index_i = pack_indices({3, 1, 1, 0});
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 5;
  dut.eval();
  if (dut.narrow_result_o != pack8({20, 10, 10, 250})) {
    fail("routed gather write", pack8({20, 10, 10, 250}),
         dut.narrow_result_o);
  }

  dut.issue_i = 1;
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 1;
  dut.dst_vrf_addr_i = 6;
  dut.write_vrf_i = 1;
  dut.route_enable_i = 1;
  dut.route_op_i = ROUTE_BROADCAST;
  dut.route_broadcast_index_i = 2;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 6;
  dut.eval();
  if (dut.narrow_result_o != pack8({100, 100, 100, 100})) {
    fail("lane broadcast write", pack8({100, 100, 100, 100}),
         dut.narrow_result_o);
  }

  // A slide can take its missing low lanes from the adjacent lower SIMD group.
  dut.issue_i = 1;
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 1;
  dut.dst_vrf_addr_i = 7;
  dut.write_vrf_i = 1;
  dut.route_enable_i = 1;
  dut.route_op_i = ROUTE_SLIDE_UP;
  dut.route_slide_amount_i = 2;
  dut.route_lower_i = pack8({1, 2, 3, 4});
  dut.eval();
  if (dut.route_boundary_mask_o != 0x3) {
    fail("slide boundary mask", 0x3, dut.route_boundary_mask_o);
  }
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 7;
  dut.eval();
  if (dut.narrow_result_o != pack8({3, 4, 250, 10})) {
    fail("adjacent slide write", pack8({3, 4, 250, 10}),
         dut.narrow_result_o);
  }

  // NSLICE transfers exact ARF bit slices to VRF without rounding or
  // saturation. Each lane may select a different starting bit.
  write_arf(dut, 2,
            {0x123456f0u, 0x89abcdefu, 0x10203040u, 0xffeeddccu});
  write_vrf(dut, 8, {0, 8, 16, 24});
  dut.issue_i = 1;
  dut.op_i = NSLICE;
  dut.src_b_addr_i = 8;
  dut.src_arf_addr_i = 2;
  dut.dst_vrf_addr_i = 9;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 9;
  dut.eval();
  if (dut.narrow_result_o != pack8({0xf0, 0xcd, 0x20, 0xff})) {
    fail("NSLICE ARF-to-VRF write", pack8({0xf0, 0xcd, 0x20, 0xff}),
         dut.narrow_result_o);
  }

  // Immediate form broadcasts one decoded value in place of VRF-B. It can
  // drive ordinary ALU operations without materializing a constant vector.
  write_vrf(dut, 13, {1, 2, 3, 4});
  dut.issue_i = 1;
  dut.op_i = ADD;
  dut.src_a_addr_i = 13;
  dut.src_b_addr_i = 11;
  dut.use_imm_i = 1;
  dut.imm_i = 10;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({11, 12, 13, 14})) {
    fail("immediate ADD broadcast", pack8({11, 12, 13, 14}),
         dut.narrow_result_o);
  }

  // Shifted WIDEN and immediate NSLICE form a VRF -> ARF -> VRF round trip.
  dut.issue_i = 1;
  dut.op_i = WIDEN_U;
  dut.src_a_addr_i = 13;
  dut.src_b_addr_i = 11;
  dut.use_imm_i = 1;
  dut.imm_i = 8;
  dut.dst_arf_addr_i = 7;
  dut.write_arf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = NSLICE;
  dut.src_arf_addr_i = 7;
  dut.src_b_addr_i = 11;
  dut.use_imm_i = 1;
  dut.imm_i = 8;
  dut.dst_vrf_addr_i = 15;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 15;
  dut.eval();
  if (dut.narrow_result_o != pack8({1, 2, 3, 4})) {
    fail("immediate shifted WIDEN/NSLICE round trip",
         pack8({1, 2, 3, 4}), dut.narrow_result_o);
  }

  // Stable compaction uses the execution MRF as a source-selection mask,
  // packs active elements toward lane zero, and exposes both count and packed
  // validity to the sequencer/MRF write path.
  write_mrf(dut, 2, 0xa);
  dut.issue_i = 1;
  dut.op_i = COMPRESS;
  dut.src_a_addr_i = 1;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 2;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  dut.dst_mrf_addr_i = 3;
  dut.write_mrf_i = 1;
  dut.eval();
  if (dut.narrow_result_o != pack8({10, 20, 0, 0}) ||
      dut.predicate_result_o != 0x3 || !dut.compact_valid_o ||
      dut.compact_count_o != 2 || dut.illegal_o) {
    fail("COMPRESS result/count", pack8({10, 20, 0, 0}),
         dut.narrow_result_o);
  }
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({10, 20, 0, 0})) {
    fail("COMPRESS full-row write", pack8({10, 20, 0, 0}),
         dut.narrow_result_o);
  }
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 3;
  dut.eval();
  if (dut.exec_mask_o != 0x3) {
    fail("COMPRESS packed MRF", 0x3, dut.exec_mask_o);
  }
  clear_controls(dut);

  // EXPAND consumes packed low lanes and places them at mask-selected output
  // positions. Unselected positions are defined zero and the output predicate
  // reproduces the expansion mask.
  dut.issue_i = 1;
  dut.op_i = EXPAND;
  dut.src_a_addr_i = 14;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 2;
  dut.dst_vrf_addr_i = 15;
  dut.write_vrf_i = 1;
  dut.dst_mrf_addr_i = 3;
  dut.write_mrf_i = 1;
  dut.eval();
  if (dut.narrow_result_o != pack8({0, 10, 0, 20}) ||
      dut.predicate_result_o != 0xa || !dut.compact_valid_o ||
      dut.compact_count_o != 2 || dut.illegal_o) {
    fail("EXPAND result/count", pack8({0, 10, 0, 20}),
         dut.narrow_result_o);
  }
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 15;
  dut.eval();
  if (dut.narrow_result_o != pack8({0, 10, 0, 20})) {
    fail("EXPAND full-row write", pack8({0, 10, 0, 20}),
         dut.narrow_result_o);
  }
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 3;
  dut.eval();
  if (dut.exec_mask_o != 0xa) {
    fail("EXPAND output MRF", 0xa, dut.exec_mask_o);
  }
  clear_controls(dut);

  // An empty mask is a valid rearrangement producing an empty packet, not an
  // illegal operation. compact_valid distinguishes it from no issued result.
  write_mrf(dut, 2, 0x0);
  dut.issue_i = 1;
  dut.op_i = COMPRESS;
  dut.src_a_addr_i = 1;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 2;
  dut.eval();
  if (dut.narrow_result_o != 0 || dut.predicate_result_o != 0 ||
      !dut.compact_valid_o || dut.compact_count_o != 0 || dut.illegal_o) {
    fail("empty COMPRESS", 0, dut.narrow_result_o);
  }
  clear_controls(dut);

  // MRF boolean operations treat both MRF ports as data. They ignore
  // mask_enable_i, write every predicate bit (including zeros), and also
  // materialize true/false as all-ones/zero narrow lane values.
  write_mrf(dut, 0, 0xa);
  write_mrf(dut, 1, 0xc);
  struct MaskCase {
    uint8_t op;
    uint8_t expected;
  };
  const std::array<MaskCase, 4> mask_cases{{
      {MAND, 0x8}, {MOR, 0xe}, {MXOR, 0x6}, {MNOT, 0x5}}};
  for (unsigned test = 0; test < mask_cases.size(); ++test) {
    dut.issue_i = 1;
    dut.op_i = mask_cases[test].op;
    dut.exec_mask_addr_i = 0;
    dut.select_mask_addr_i = 1;
    dut.mask_enable_i = 0;
    dut.dst_mrf_addr_i = 3;
    dut.write_mrf_i = 1;
    if (test == 0) {
      dut.dst_vrf_addr_i = 13;
      dut.write_vrf_i = 1;
    }
    dut.eval();
    const uint32_t expected_narrow =
        materialize_mask(mask_cases[test].expected);
    if (dut.predicate_result_o != mask_cases[test].expected ||
        dut.narrow_result_o != expected_narrow || dut.illegal_o) {
      fail("MRF boolean result", expected_narrow, dut.narrow_result_o);
    }
    tick(dut);
    clear_controls(dut);

    dut.op_i = PASS_A;
    dut.mask_enable_i = 1;
    dut.exec_mask_addr_i = 3;
    dut.eval();
    if (dut.exec_mask_o != mask_cases[test].expected) {
      fail("MRF boolean full write", mask_cases[test].expected,
           dut.exec_mask_o);
    }
    clear_controls(dut);
  }

  dut.op_i = PASS_A;
  dut.src_a_addr_i = 13;
  dut.eval();
  if (dut.narrow_result_o != materialize_mask(0x8)) {
    fail("MAND VRF materialization", materialize_mask(0x8),
         dut.narrow_result_o);
  }

  // HALF addition propagates carry within each 16-bit element and cuts it at
  // the boundary between the two elements.
  write_vrf(dut, 10, {0xff, 0x00, 0xff, 0xff});
  write_vrf(dut, 11, {0x01, 0x00, 0x01, 0x00});
  dut.issue_i = 1;
  dut.op_i = ADD;
  dut.elem_mode_i = 1;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({0x00, 0x01, 0x00, 0x00})) {
    fail("HALF partitioned ADD", pack8({0x00, 0x01, 0x00, 0x00}),
         dut.narrow_result_o);
  }

  // WORD subtraction carries a borrow through all four physical byte lanes.
  write_vrf(dut, 10, {0x00, 0x00, 0x01, 0x00});
  write_vrf(dut, 11, {0x01, 0x00, 0x00, 0x00});
  dut.issue_i = 1;
  dut.op_i = SUB;
  dut.elem_mode_i = 2;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({0xff, 0xff, 0x00, 0x00})) {
    fail("WORD partitioned SUB", pack8({0xff, 0xff, 0x00, 0x00}),
         dut.narrow_result_o);
  }

  // Two HALF elements use independent shift amounts while sharing one
  // partitionable group shifter.
  write_vrf(dut, 10, {0x80, 0x00, 0x01, 0x00});
  write_vrf(dut, 11, {0x01, 0x00, 0x04, 0x00});
  dut.issue_i = 1;
  dut.op_i = SHL;
  dut.elem_mode_i = 1;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({0x00, 0x01, 0x10, 0x00})) {
    fail("HALF independent SHL", pack8({0x00, 0x01, 0x10, 0x00}),
         dut.narrow_result_o);
  }

  // A WORD immediate is consumed as one 32-bit scalar rather than four copies
  // of its low byte.
  write_vrf(dut, 10, {0x01, 0x01, 0x01, 0x01});
  dut.issue_i = 1;
  dut.op_i = ADD;
  dut.elem_mode_i = 2;
  dut.src_a_addr_i = 10;
  dut.use_imm_i = 1;
  dut.imm_i = 0x01020304u;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != 0x02030405u) {
    fail("WORD immediate ADD", 0x02030405u, dut.narrow_result_o);
  }

  // HALF MIN selects a complete 16-bit element. It must not mix independently
  // selected low and high bytes from different sources.
  write_vrf(dut, 10, {0x00, 0x01, 0x00, 0x80});
  write_vrf(dut, 11, {0xff, 0x00, 0xff, 0x7f});
  dut.issue_i = 1;
  dut.op_i = MIN_U;
  dut.elem_mode_i = 1;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({0xff, 0x00, 0xff, 0x7f})) {
    fail("HALF unsigned whole-element MIN",
         pack8({0xff, 0x00, 0xff, 0x7f}), dut.narrow_result_o);
  }

  dut.issue_i = 1;
  dut.op_i = MIN_S;
  dut.elem_mode_i = 1;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({0xff, 0x00, 0x00, 0x80})) {
    fail("HALF signed whole-element MIN",
         pack8({0xff, 0x00, 0x00, 0x80}), dut.narrow_result_o);
  }

  // Equality and greater-than produce one predicate per logical element and
  // replicate it across the element's physical byte lanes for MRF storage.
  write_vrf(dut, 10, {0x34, 0x12, 0x78, 0x56});
  write_vrf(dut, 11, {0x34, 0x12, 0x79, 0x56});
  dut.issue_i = 1;
  dut.op_i = CMPEQ;
  dut.elem_mode_i = 1;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.dst_mrf_addr_i = 3;
  dut.write_mrf_i = 1;
  dut.eval();
  if (dut.narrow_result_o != pack8({0xff, 0xff, 0x00, 0x00}) ||
      dut.predicate_result_o != 0x3 || dut.illegal_o) {
    fail("HALF CMPEQ replicated predicate", 0x3,
         dut.predicate_result_o);
  }
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 3;
  dut.eval();
  if (dut.exec_mask_o != 0x3) {
    fail("HALF CMPEQ MRF write", 0x3, dut.exec_mask_o);
  }
  clear_controls(dut);

  write_vrf(dut, 10, {0x00, 0x00, 0x00, 0x80});
  write_vrf(dut, 11, {0xff, 0xff, 0xff, 0x7f});
  dut.issue_i = 1;
  dut.op_i = CMPGT_U;
  dut.elem_mode_i = 2;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.eval();
  if (dut.narrow_result_o != 0xffffffffu ||
      dut.predicate_result_o != 0xf || dut.illegal_o) {
    fail("WORD unsigned CMPGT", 0xf, dut.predicate_result_o);
  }
  dut.op_i = CMPGT_S;
  dut.eval();
  if (dut.narrow_result_o != 0 || dut.predicate_result_o != 0 ||
      dut.illegal_o) {
    fail("WORD signed CMPGT", 0, dut.predicate_result_o);
  }
  clear_controls(dut);

  // A malformed HALF mask cannot partially update an element: all byte bits
  // belonging to an element must be set before its effective mask becomes 1.
  write_vrf(dut, 14, {9, 9, 9, 9});
  write_vrf(dut, 10, {1, 2, 3, 4});
  write_vrf(dut, 11, {10, 20, 30, 40});
  write_mrf(dut, 2, 0xd);
  dut.issue_i = 1;
  dut.op_i = ADD;
  dut.elem_mode_i = 1;
  dut.src_a_addr_i = 10;
  dut.src_b_addr_i = 11;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = 2;
  dut.dst_vrf_addr_i = 14;
  dut.write_vrf_i = 1;
  dut.eval();
  if (dut.exec_mask_o != 0xc) {
    fail("HALF normalized execution mask", 0xc, dut.exec_mask_o);
  }
  tick(dut);
  clear_controls(dut);
  dut.op_i = PASS_A;
  dut.src_a_addr_i = 14;
  dut.eval();
  if (dut.narrow_result_o != pack8({9, 9, 33, 44})) {
    fail("HALF atomic masked write", pack8({9, 9, 33, 44}),
         dut.narrow_result_o);
  }

  dut.final();
  std::cout << "PASS: datapath state, dynamic BYTE/HALF/WORD add/sub/shift/min/max/compare, predicate replication, data movement, reduction, compaction, and MRF logic\n";
  return 0;
}
