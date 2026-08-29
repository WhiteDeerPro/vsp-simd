#include "Vvsp_exec_uword_expander.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

unsigned checks = 0;

constexpr uint32_t kFmtAlu = 0x1;
constexpr uint32_t kFmtCmp = 0x2;
constexpr uint32_t kFmtSelect = 0x3;
constexpr uint32_t kFmtMul = 0x4;
constexpr uint32_t kFmtMacRr = 0x5;
constexpr uint32_t kFmtMacRi = 0x6;
constexpr uint32_t kFmtWide = 0x7;
constexpr uint32_t kFmtWadd = 0x8;
constexpr uint32_t kFmtCompact = 0x9;
constexpr uint32_t kFmtMrf = 0xa;
constexpr uint32_t kFmtRoute = 0xd;

constexpr uint32_t kErrNone = 0x0;
constexpr uint32_t kErrBadFormat = 0x1;
constexpr uint32_t kErrBadSubop = 0x2;
constexpr uint32_t kErrReserved = 0x3;
constexpr uint32_t kErrExtension = 0x4;
constexpr uint32_t kErrImmediate = 0x5;
constexpr uint32_t kErrMask = 0x6;
constexpr uint32_t kErrReduction = 0x7;
constexpr uint32_t kErrMode = 0x8;
constexpr uint32_t kErrWriteback = 0x9;
constexpr uint32_t kErrAddress = 0xa;
constexpr uint32_t kErrUnused = 0xb;

constexpr uint32_t kModeByte = 0;
constexpr uint32_t kModeHalf = 1;
constexpr uint32_t kModeWord = 2;

constexpr uint32_t kOpAdd = 0x00;
constexpr uint32_t kOpSub = 0x01;
constexpr uint32_t kOpAddSatU = 0x02;
constexpr uint32_t kOpSubSatU = 0x03;
constexpr uint32_t kOpAddSatS = 0x04;
constexpr uint32_t kOpSubSatS = 0x05;
constexpr uint32_t kOpMinU = 0x06;
constexpr uint32_t kOpMaxU = 0x07;
constexpr uint32_t kOpMinS = 0x08;
constexpr uint32_t kOpMaxS = 0x09;
constexpr uint32_t kOpAbsdiffU = 0x0a;
constexpr uint32_t kOpAvgU = 0x0b;
constexpr uint32_t kOpAnd = 0x0c;
constexpr uint32_t kOpOr = 0x0d;
constexpr uint32_t kOpXor = 0x0e;
constexpr uint32_t kOpShl = 0x0f;
constexpr uint32_t kOpShrU = 0x10;
constexpr uint32_t kOpShrS = 0x11;
constexpr uint32_t kOpCmpEq = 0x12;
constexpr uint32_t kOpCmpGtU = 0x13;
constexpr uint32_t kOpCmpGtS = 0x14;
constexpr uint32_t kOpAbsSatS = 0x15;
constexpr uint32_t kOpMulU = 0x16;
constexpr uint32_t kOpMulS = 0x17;
constexpr uint32_t kOpMacU = 0x18;
constexpr uint32_t kOpMacS = 0x19;
constexpr uint32_t kOpPassA = 0x1a;
constexpr uint32_t kOpSelect = 0x1b;
constexpr uint32_t kOpWidenU = 0x1c;
constexpr uint32_t kOpWaddU = 0x1e;
constexpr uint32_t kOpWaddS = 0x1f;
constexpr uint32_t kOpWsubU = 0x20;
constexpr uint32_t kOpWsubS = 0x21;
constexpr uint32_t kOpRshiftU = 0x22;
constexpr uint32_t kOpNclipS = 0x25;
constexpr uint32_t kOpAvgS = 0x27;
constexpr uint32_t kOpCompress = 0x28;
constexpr uint32_t kOpExpand = 0x29;
constexpr uint32_t kOpMand = 0x2a;
constexpr uint32_t kOpMor = 0x2b;
constexpr uint32_t kOpMxor = 0x2c;
constexpr uint32_t kOpMnot = 0x2d;

[[noreturn]] void fail(const std::string& what, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << what << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& what, uint64_t expected,
               uint64_t actual) {
  ++checks;
  if (expected != actual) fail(what, expected, actual);
}

uint32_t enc_alu(unsigned alu_op, unsigned mode, unsigned va, unsigned vb,
                 unsigned vd, unsigned mask, bool bimm, bool write_vrf,
                 bool export_narrow, unsigned reduce) {
  return (kFmtAlu << 28) | (alu_op << 23) | (mode << 21) | (va << 17) |
         (vb << 13) | (vd << 9) | (mask << 6) |
         (uint32_t(bimm) << 5) | (uint32_t(write_vrf) << 4) |
         (uint32_t(export_narrow) << 3) | reduce;
}

uint32_t enc_cmp(unsigned cmp_op, unsigned mode, unsigned va, unsigned vb,
                 unsigned vd, unsigned md, unsigned mask, bool bimm,
                 bool write_vrf, bool write_mrf, bool export_narrow,
                 unsigned reserved = 0) {
  return (kFmtCmp << 28) | (cmp_op << 26) | (mode << 24) | (va << 20) |
         (vb << 16) | (vd << 12) | (md << 10) | (mask << 7) |
         (uint32_t(bimm) << 6) | (uint32_t(write_vrf) << 5) |
         (uint32_t(write_mrf) << 4) |
         (uint32_t(export_narrow) << 3) | reserved;
}

uint32_t enc_select(unsigned mode, unsigned va, unsigned vb, unsigned vd,
                    unsigned mask, unsigned select_mrf, bool bimm,
                    bool write_vrf, bool export_narrow, unsigned reduce,
                    unsigned reserved = 0) {
  return (kFmtSelect << 28) | (mode << 26) | (va << 22) | (vb << 18) |
         (vd << 14) | (mask << 11) | (select_mrf << 9) |
         (uint32_t(bimm) << 8) | (uint32_t(write_vrf) << 7) |
         (uint32_t(export_narrow) << 6) | (reduce << 3) | reserved;
}

uint32_t enc_mul(bool is_signed, unsigned va, unsigned vb, unsigned vd,
                 unsigned ad, unsigned mask, bool bimm, bool write_vrf,
                 bool write_arf, bool export_narrow, unsigned reduce,
                 unsigned reserved = 0) {
  return (kFmtMul << 28) | (uint32_t(is_signed) << 27) | (va << 23) |
         (vb << 19) | (vd << 15) | (ad << 12) | (mask << 9) |
         (uint32_t(bimm) << 8) | (uint32_t(write_vrf) << 7) |
         (uint32_t(write_arf) << 6) |
         (uint32_t(export_narrow) << 5) | (reduce << 2) | reserved;
}

uint32_t enc_mac(unsigned format, bool is_signed, unsigned va, unsigned vb,
                 unsigned as, unsigned ad, unsigned vd, unsigned mask,
                 bool write_vrf, bool write_arf, bool export_narrow,
                 unsigned reduce) {
  return (format << 28) | (uint32_t(is_signed) << 27) | (va << 23) |
         (vb << 19) | (as << 16) | (ad << 13) | (vd << 9) |
         (mask << 6) | (uint32_t(write_vrf) << 5) |
         (uint32_t(write_arf) << 4) |
         (uint32_t(export_narrow) << 3) | reduce;
}

uint32_t enc_wide(unsigned wide_op, unsigned src0, unsigned vb,
                  unsigned dst, unsigned mask, bool bimm, bool write_dst,
                  bool export_narrow, unsigned reduce,
                  unsigned reserved = 0) {
  return (kFmtWide << 28) | (wide_op << 25) | (src0 << 21) | (vb << 17) |
         (dst << 13) | (mask << 10) | (uint32_t(bimm) << 9) |
         (uint32_t(write_dst) << 8) |
         (uint32_t(export_narrow) << 7) | (reduce << 4) | reserved;
}

uint32_t enc_wadd(unsigned wide_op, unsigned va, unsigned vb, unsigned as,
                  unsigned ad, unsigned mask, unsigned align,
                  bool write_arf, unsigned reserved = 0) {
  return (kFmtWadd << 28) | (wide_op << 26) | (va << 22) | (vb << 18) |
         (as << 15) | (ad << 12) | (mask << 9) | (align << 4) |
         (uint32_t(write_arf) << 3) | reserved;
}

uint32_t enc_compact(bool expand, unsigned mode, unsigned va, unsigned vd,
                     unsigned mask, unsigned md, bool write_vrf,
                     bool write_mrf, bool export_narrow, unsigned reduce,
                     unsigned reserved = 0) {
  return (kFmtCompact << 28) | (uint32_t(expand) << 27) | (mode << 25) |
         (va << 21) | (vd << 17) | (mask << 14) | (md << 12) |
         (uint32_t(write_vrf) << 11) | (uint32_t(write_mrf) << 10) |
         (uint32_t(export_narrow) << 9) | (reduce << 6) | reserved;
}

uint32_t enc_mrf(unsigned mask_op, unsigned ma, unsigned mb, unsigned md,
                 unsigned vd, bool write_mrf, bool write_vrf,
                 bool export_narrow, unsigned reserved = 0) {
  return (kFmtMrf << 28) | (mask_op << 26) | (ma << 24) | (mb << 22) |
         (md << 20) | (vd << 16) | (uint32_t(write_mrf) << 15) |
         (uint32_t(write_vrf) << 14) |
         (uint32_t(export_narrow) << 13) | reserved;
}

uint32_t enc_route(unsigned route_op, unsigned va, unsigned vd,
                   unsigned mask, bool write_vrf, bool export_narrow,
                   unsigned reduce, unsigned route_ctrl,
                   unsigned reserved = 0) {
  return (kFmtRoute << 28) | (route_op << 26) | (va << 22) | (vd << 18) |
         (mask << 15) | (uint32_t(write_vrf) << 14) |
         (uint32_t(export_narrow) << 13) | (reduce << 10) |
         (route_ctrl << 2) | reserved;
}

struct Expected {
  uint32_t op = 0;
  uint32_t mode = 0;
  uint32_t src_a = 0;
  uint32_t src_b = 0;
  bool use_imm = false;
  uint32_t imm = 0;
  uint32_t dst_vrf = 0;
  uint32_t src_arf = 0;
  uint32_t dst_arf = 0;
  bool mask_enable = false;
  uint32_t mask_addr = 0;
  uint32_t select_mask_addr = 0;
  uint32_t dst_mrf = 0;
  bool write_vrf = false;
  bool write_arf = false;
  bool write_mrf = false;
  bool reduce_enable = false;
  uint32_t reduce_op = 0;
  bool export_narrow = false;
  bool route_enable = false;
  uint32_t route_op = 0;
  uint32_t route_index = 0;
  uint32_t route_broadcast = 0;
  uint32_t route_slide = 0;
  uint32_t route_lower = 0;
  uint32_t route_upper = 0;
  bool has_count = false;
};

void apply_mask(Expected& expected, unsigned mask_sel) {
  expected.mask_enable = mask_sel != 0;
  expected.mask_addr = mask_sel == 0 ? 0 : mask_sel - 1;
}

void apply_reduce(Expected& expected, unsigned reduce_sel) {
  expected.reduce_enable = reduce_sel != 0;
  expected.reduce_op = reduce_sel == 0 ? 0 : reduce_sel - 1;
}

void drive(Vvsp_exec_uword_expander& dut, uint32_t base,
           bool extension_valid = false, uint32_t extension = 0) {
  dut.base_valid_i = 1;
  dut.base_word_i = base;
  dut.extension_valid_i = extension_valid;
  dut.extension_word_i = extension;
  dut.eval();
}

void expect_zero_canonical(Vvsp_exec_uword_expander& dut,
                           const std::string& name) {
  expect_eq(name + " zero op", 0, dut.op_o);
  expect_eq(name + " zero mode", 0, dut.elem_mode_o);
  expect_eq(name + " zero src a", 0, dut.src_a_addr_o);
  expect_eq(name + " zero src b", 0, dut.src_b_addr_o);
  expect_eq(name + " zero use imm", 0, dut.use_imm_o);
  expect_eq(name + " zero imm", 0, dut.imm_o);
  expect_eq(name + " zero dst vrf", 0, dut.dst_vrf_addr_o);
  expect_eq(name + " zero src arf", 0, dut.src_arf_addr_o);
  expect_eq(name + " zero dst arf", 0, dut.dst_arf_addr_o);
  expect_eq(name + " zero mask enable", 0, dut.mask_enable_o);
  expect_eq(name + " zero mask addr", 0, dut.mask_addr_o);
  expect_eq(name + " zero select mask", 0, dut.select_mask_addr_o);
  expect_eq(name + " zero dst mrf", 0, dut.dst_mrf_addr_o);
  expect_eq(name + " zero write vrf", 0, dut.write_vrf_o);
  expect_eq(name + " zero write arf", 0, dut.write_arf_o);
  expect_eq(name + " zero write mrf", 0, dut.write_mrf_o);
  expect_eq(name + " zero reduce", 0, dut.reduce_enable_o);
  expect_eq(name + " zero reduce op", 0, dut.reduce_op_o);
  expect_eq(name + " zero export", 0, dut.export_narrow_o);
  expect_eq(name + " zero route enable", 0, dut.route_enable_o);
  expect_eq(name + " zero route op", 0, dut.route_op_o);
  expect_eq(name + " zero route index", 0, dut.route_index_o);
  expect_eq(name + " zero route broadcast", 0,
            dut.route_broadcast_index_o);
  expect_eq(name + " zero route slide", 0, dut.route_slide_amount_o);
  expect_eq(name + " zero route lower", 0, dut.route_lower_o);
  expect_eq(name + " zero route upper", 0, dut.route_upper_o);
  expect_eq(name + " zero result obligation", 0, dut.requires_result_o);
  expect_eq(name + " zero narrow result", 0, dut.result_has_narrow_o);
  expect_eq(name + " zero reduce result", 0, dut.result_has_reduce_o);
  expect_eq(name + " zero count result", 0, dut.result_has_count_o);
}

void expect_legal(Vvsp_exec_uword_expander& dut, const std::string& name,
                  uint32_t base, bool extension_valid, uint32_t extension,
                  bool extension_required, const Expected& expected) {
  drive(dut, base, extension_valid, extension);
  expect_eq(name + " extension required", extension_required,
            dut.extension_required_o);
  expect_eq(name + " out valid", 1, dut.out_valid_o);
  expect_eq(name + " legal", 1, dut.legal_o);
  expect_eq(name + " no error", kErrNone, dut.error_cause_o);
  expect_eq(name + " op", expected.op, dut.op_o);
  expect_eq(name + " mode", expected.mode, dut.elem_mode_o);
  expect_eq(name + " src a", expected.src_a, dut.src_a_addr_o);
  expect_eq(name + " src b", expected.src_b, dut.src_b_addr_o);
  expect_eq(name + " use imm", expected.use_imm, dut.use_imm_o);
  expect_eq(name + " imm", expected.imm, dut.imm_o);
  expect_eq(name + " dst vrf", expected.dst_vrf, dut.dst_vrf_addr_o);
  expect_eq(name + " src arf", expected.src_arf, dut.src_arf_addr_o);
  expect_eq(name + " dst arf", expected.dst_arf, dut.dst_arf_addr_o);
  expect_eq(name + " mask enable", expected.mask_enable,
            dut.mask_enable_o);
  expect_eq(name + " mask addr", expected.mask_addr, dut.mask_addr_o);
  expect_eq(name + " select mask", expected.select_mask_addr,
            dut.select_mask_addr_o);
  expect_eq(name + " dst mrf", expected.dst_mrf, dut.dst_mrf_addr_o);
  expect_eq(name + " write vrf", expected.write_vrf, dut.write_vrf_o);
  expect_eq(name + " write arf", expected.write_arf, dut.write_arf_o);
  expect_eq(name + " write mrf", expected.write_mrf, dut.write_mrf_o);
  expect_eq(name + " reduce enable", expected.reduce_enable,
            dut.reduce_enable_o);
  expect_eq(name + " reduce op", expected.reduce_op, dut.reduce_op_o);
  expect_eq(name + " export", expected.export_narrow,
            dut.export_narrow_o);

  const bool has_narrow = expected.export_narrow;
  const bool has_reduce = expected.reduce_enable;
  const bool requires_result = has_narrow || has_reduce || expected.has_count;
  expect_eq(name + " requires result", requires_result,
            dut.requires_result_o);
  expect_eq(name + " result narrow", has_narrow,
            dut.result_has_narrow_o);
  expect_eq(name + " result reduce", has_reduce,
            dut.result_has_reduce_o);
  expect_eq(name + " result count", expected.has_count,
            dut.result_has_count_o);

  expect_eq(name + " route enable", expected.route_enable,
            dut.route_enable_o);
  expect_eq(name + " route op", expected.route_op, dut.route_op_o);
  expect_eq(name + " route index", expected.route_index,
            dut.route_index_o);
  expect_eq(name + " route broadcast", expected.route_broadcast,
            dut.route_broadcast_index_o);
  expect_eq(name + " route slide", expected.route_slide,
            dut.route_slide_amount_o);
  expect_eq(name + " route lower", expected.route_lower,
            dut.route_lower_o);
  expect_eq(name + " route upper", expected.route_upper,
            dut.route_upper_o);
}

void expect_illegal(Vvsp_exec_uword_expander& dut, const std::string& name,
                    uint32_t base, bool extension_valid,
                    uint32_t extension, bool extension_required,
                    bool out_valid, uint32_t cause) {
  drive(dut, base, extension_valid, extension);
  expect_eq(name + " extension required", extension_required,
            dut.extension_required_o);
  expect_eq(name + " out valid", out_valid, dut.out_valid_o);
  expect_eq(name + " illegal", 0, dut.legal_o);
  expect_eq(name + " cause", cause, dut.error_cause_o);
  expect_zero_canonical(dut, name);
}

void test_golden_formats(Vvsp_exec_uword_expander& dut) {
  Expected expected;

  expected.op = kOpAdd;
  expected.mode = kModeWord;
  expected.src_a = 3;
  expected.use_imm = true;
  expected.imm = 0xdeadbeef;
  expected.dst_vrf = 7;
  expected.write_vrf = true;
  expected.export_narrow = true;
  apply_mask(expected, 3);
  expect_legal(dut, "fmt1 ALU", enc_alu(0, kModeWord, 3, 0, 7, 3,
                                        true, true, true, 0),
               true, 0xdeadbeef, true, expected);

  expected = {};
  expected.op = kOpCmpGtS;
  expected.mode = kModeHalf;
  expected.src_a = 4;
  expected.src_b = 5;
  expected.dst_vrf = 9;
  expected.dst_mrf = 2;
  expected.write_vrf = true;
  expected.write_mrf = true;
  expected.export_narrow = true;
  apply_mask(expected, 4);
  expect_legal(dut, "fmt2 CMP", enc_cmp(2, kModeHalf, 4, 5, 9, 2, 4,
                                        false, true, true, true),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpSelect;
  expected.mode = kModeByte;
  expected.src_a = 6;
  expected.use_imm = true;
  expected.imm = 0x7f;
  expected.dst_vrf = 8;
  expected.select_mask_addr = 3;
  expected.write_vrf = true;
  expected.export_narrow = true;
  apply_mask(expected, 2);
  apply_reduce(expected, 3);
  expect_legal(dut, "fmt3 SELECT",
               enc_select(kModeByte, 6, 0, 8, 2, 3, true, true, true, 3),
               true, 0x7f, true, expected);

  expected = {};
  expected.op = kOpMulS;
  expected.mode = kModeByte;
  expected.src_a = 2;
  expected.src_b = 3;
  expected.dst_vrf = 4;
  expected.dst_arf = 5;
  expected.write_vrf = true;
  expected.write_arf = true;
  expected.export_narrow = true;
  apply_mask(expected, 1);
  apply_reduce(expected, 2);
  expect_legal(dut, "fmt4 MUL", enc_mul(true, 2, 3, 4, 5, 1, false,
                                        true, true, true, 2),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpMacU;
  expected.mode = kModeByte;
  expected.src_a = 1;
  expected.src_b = 2;
  expected.src_arf = 3;
  expected.dst_arf = 4;
  expected.dst_vrf = 5;
  expected.write_vrf = true;
  expected.write_arf = true;
  apply_mask(expected, 4);
  apply_reduce(expected, 1);
  expect_legal(dut, "fmt5 MAC_RR",
               enc_mac(kFmtMacRr, false, 1, 2, 3, 4, 5, 4,
                       true, true, false, 1),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpMacS;
  expected.mode = kModeByte;
  expected.src_a = 6;
  expected.use_imm = true;
  expected.imm = 0xa5;
  expected.src_arf = 2;
  expected.dst_arf = 7;
  expected.dst_vrf = 9;
  expected.write_vrf = true;
  expected.write_arf = true;
  expected.export_narrow = true;
  expect_legal(dut, "fmt6 MAC_RI",
               enc_mac(kFmtMacRi, true, 6, 0, 2, 7, 9, 0,
                       true, true, true, 0),
               true, 0xa5, true, expected);

  expected = {};
  expected.op = kOpNclipS;
  expected.mode = kModeByte;
  expected.use_imm = true;
  expected.imm = 0x1f;
  expected.src_arf = 6;
  expected.dst_vrf = 10;
  expected.write_vrf = true;
  expected.export_narrow = true;
  apply_mask(expected, 3);
  apply_reduce(expected, 6);
  expect_legal(dut, "fmt7 WIDE_CONVERT",
               enc_wide(5, 6, 0, 10, 3, true, true, true, 6),
               true, 0x1f, true, expected);

  expected = {};
  expected.op = kOpWsubS;
  expected.mode = kModeByte;
  expected.src_a = 4;
  expected.src_b = 5;
  expected.src_arf = 6;
  expected.dst_arf = 7;
  expected.use_imm = true;
  expected.imm = 0x1d;
  expected.write_arf = true;
  apply_mask(expected, 2);
  expect_legal(dut, "fmt8 WADD_WSUB",
               enc_wadd(3, 4, 5, 6, 7, 2, 0x1d, true),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpExpand;
  expected.mode = kModeByte;
  expected.src_a = 7;
  expected.dst_vrf = 8;
  expected.dst_mrf = 3;
  expected.write_vrf = true;
  expected.write_mrf = true;
  expected.has_count = true;
  apply_mask(expected, 4);
  apply_reduce(expected, 4);
  expect_legal(dut, "fmt9 COMPACT",
               enc_compact(true, kModeByte, 7, 8, 4, 3,
                           true, true, false, 4),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpMnot;
  expected.mode = kModeByte;
  expected.mask_addr = 2;
  expected.select_mask_addr = 0;
  expected.dst_mrf = 1;
  expected.dst_vrf = 12;
  expected.write_mrf = true;
  expected.write_vrf = true;
  expected.export_narrow = true;
  expect_legal(dut, "fmtA MRF_LOGIC",
               enc_mrf(3, 2, 0, 1, 12, true, true, true),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpPassA;
  expected.mode = kModeByte;
  expected.src_a = 1;
  expected.dst_vrf = 2;
  expected.write_vrf = true;
  expected.route_enable = true;
  expected.route_op = 0;
  expected.route_index = 0x1b;
  expect_legal(dut, "fmtD ROUTE gather",
               enc_route(0, 1, 2, 0, true, false, 0, 0x1b),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpPassA;
  expected.mode = kModeByte;
  expected.src_a = 3;
  expected.export_narrow = true;
  expected.route_enable = true;
  expected.route_op = 1;
  expected.route_broadcast = 2;
  apply_mask(expected, 1);
  apply_reduce(expected, 3);
  expect_legal(dut, "fmtD ROUTE broadcast result",
               enc_route(1, 3, 0, 1, false, true, 3, 2),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpPassA;
  expected.mode = kModeByte;
  expected.src_a = 4;
  expected.dst_vrf = 5;
  expected.write_vrf = true;
  expected.route_enable = true;
  expected.route_op = 2;
  expected.route_slide = 4;
  expect_legal(dut, "fmtD ROUTE zero-fill slide",
               enc_route(2, 4, 5, 0, true, false, 0, 4),
               false, 0, false, expected);
}

void test_alu_subop_mapping_and_no_effect(
    Vvsp_exec_uword_expander& dut) {
  constexpr uint32_t expected_ops[] = {
      kOpAdd,       kOpSub,     kOpAddSatU, kOpSubSatU, kOpAddSatS,
      kOpSubSatS,   kOpMinU,    kOpMaxU,    kOpMinS,    kOpMaxS,
      kOpAbsdiffU,  kOpAvgU,    kOpAvgS,    kOpAnd,     kOpOr,
      kOpXor,       kOpShl,     kOpShrU,    kOpShrS,    kOpAbsSatS,
      kOpPassA,
  };

  for (unsigned subop = 0; subop < sizeof(expected_ops) / sizeof(*expected_ops);
       ++subop) {
    Expected expected;
    expected.op = expected_ops[subop];
    expected.mode = kModeByte;
    expected.src_a = 1;
    const bool unary = subop == 19 || subop == 20;
    expected.src_b = unary ? 0 : 2;
    expect_legal(dut, "ALU map " + std::to_string(subop),
                 enc_alu(subop, kModeByte, 1, unary ? 0 : 2, 0, 0,
                         false, false, false, 0),
                 false, 0, false, expected);
  }
}

void test_immediate_widths_and_results(Vvsp_exec_uword_expander& dut) {
  for (unsigned mode = kModeByte; mode <= kModeWord; ++mode) {
    const uint32_t legal_imm = mode == kModeByte
                                   ? 0xff
                                   : (mode == kModeHalf ? 0xffff : 0x87654321);
    Expected expected;
    expected.op = kOpAdd;
    expected.mode = mode;
    expected.src_a = 1;
    expected.use_imm = true;
    expected.imm = legal_imm;
    expect_legal(dut, "immediate width legal " + std::to_string(mode),
                 enc_alu(0, mode, 1, 0, 0, 0, true, false, false, 0),
                 true, legal_imm, true, expected);
  }

  expect_illegal(dut, "byte immediate high bit",
                 enc_alu(0, kModeByte, 1, 0, 0, 0,
                         true, false, false, 0),
                 true, 0x100, true, true, kErrImmediate);
  expect_illegal(dut, "half immediate high bit",
                 enc_alu(0, kModeHalf, 1, 0, 0, 0,
                         true, false, false, 0),
                 true, 0x10000, true, true, kErrImmediate);
  expect_illegal(dut, "MUL immediate high bit",
                 enc_mul(false, 1, 0, 0, 0, 0, true,
                         false, false, false, 0),
                 true, 0x100, true, true, kErrImmediate);
  expect_illegal(dut, "WIDE shift immediate high bit",
                 enc_wide(4, 1, 0, 0, 0, true,
                          false, false, 0),
                 true, 0x20, true, true, kErrImmediate);

  // These four records distinguish every result-obligation source.  RF
  // writeback alone does not create a group result; export and reduction do.
  Expected expected;
  expected.op = kOpAdd;
  expected.mode = kModeByte;
  expected.src_a = 1;
  expected.src_b = 2;
  expected.dst_vrf = 3;
  expected.write_vrf = true;
  expect_legal(dut, "result none",
               enc_alu(0, kModeByte, 1, 2, 3, 0,
                       false, true, false, 0),
               false, 0, false, expected);

  expected.export_narrow = true;
  expect_legal(dut, "result narrow",
               enc_alu(0, kModeByte, 1, 2, 3, 0,
                       false, true, true, 0),
               false, 0, false, expected);

  expected.export_narrow = false;
  apply_reduce(expected, 1);
  expect_legal(dut, "result reduce",
               enc_alu(0, kModeByte, 1, 2, 3, 0,
                       false, true, false, 1),
               false, 0, false, expected);

  expected = {};
  expected.op = kOpCompress;
  expected.mode = kModeHalf;
  expected.src_a = 1;
  expected.has_count = true;
  expect_legal(dut, "result compact count",
               enc_compact(false, kModeHalf, 1, 0, 0, 0,
                           false, false, false, 0),
               false, 0, false, expected);
}

void test_illegal_and_priority(Vvsp_exec_uword_expander& dut) {
  expect_illegal(dut, "bad format", 0x00000000, false, 0,
                 false, true, kErrBadFormat);
  expect_illegal(dut, "bad high format", 0xf0000000, false, 0,
                 false, true, kErrBadFormat);
  expect_illegal(dut, "bad ALU subop",
                 enc_alu(21, kModeByte, 1, 2, 0, 0,
                         false, false, false, 0),
                 false, 0, false, true, kErrBadSubop);
  expect_illegal(dut, "bad CMP subop",
                 enc_cmp(3, kModeByte, 1, 2, 0, 0, 0,
                         false, false, false, false),
                 false, 0, false, true, kErrBadSubop);
  expect_illegal(dut, "bad WIDE subop",
                 enc_wide(7, 0, 0, 0, 0, false,
                          false, false, 0),
                 false, 0, false, true, kErrBadSubop);

  expect_illegal(dut, "reserved bits",
                 enc_cmp(0, kModeByte, 1, 2, 0, 0, 0,
                         false, false, false, false, 1),
                 false, 0, false, true, kErrReserved);

  const uint32_t needs_extension =
      enc_alu(0, kModeByte, 1, 0, 0, 0, true, false, false, 0);
  expect_illegal(dut, "missing extension", needs_extension, false, 0,
                 true, true, kErrExtension);
  expect_illegal(dut, "unexpected extension",
                 enc_wadd(0, 1, 2, 3, 0, 0, 0, false),
                 true, 0, false, true, kErrExtension);
  expect_illegal(dut, "MAC_RI missing extension",
                 enc_mac(kFmtMacRi, false, 1, 0, 2, 0, 0, 0,
                         false, false, false, 0),
                 false, 0, true, true, kErrExtension);
  expect_illegal(dut, "MAC_RR unexpected extension",
                 enc_mac(kFmtMacRr, false, 1, 2, 2, 0, 0, 0,
                         false, false, false, 0),
                 true, 0x12, false, true, kErrExtension);

  expect_illegal(dut, "bad mask",
                 enc_alu(0, kModeByte, 1, 2, 0, 5,
                         false, false, false, 0),
                 false, 0, false, true, kErrMask);
  expect_illegal(dut, "undefined reduction",
                 enc_alu(0, kModeByte, 1, 2, 0, 0,
                         false, false, false, 7),
                 false, 0, false, true, kErrReduction);
  expect_illegal(dut, "wide-element reduction",
                 enc_alu(0, kModeHalf, 1, 2, 0, 0,
                         false, false, false, 1),
                 false, 0, false, true, kErrReduction);
  expect_illegal(dut, "undefined mode",
                 enc_alu(0, 3, 1, 2, 0, 0,
                         false, false, false, 0),
                 false, 0, false, true, kErrMode);
  expect_illegal(dut, "byte-only op in HALF",
                 enc_alu(2, kModeHalf, 1, 2, 0, 0,
                         false, false, false, 0),
                 false, 0, false, true, kErrMode);
  expect_illegal(dut, "WIDEN export",
                 enc_wide(0, 1, 2, 3, 0, false,
                          true, true, 0),
                 false, 0, false, true, kErrWriteback);
  expect_illegal(dut, "WIDE ARF source address",
                 enc_wide(2, 8, 1, 2, 0, false,
                          true, false, 0),
                 false, 0, false, true, kErrAddress);
  expect_illegal(dut, "immediate form has vb",
                 enc_alu(0, kModeByte, 1, 2, 0, 0,
                         true, false, false, 0),
                 true, 0x12, true, true, kErrUnused);
  expect_illegal(dut, "disabled destination is nonzero",
                 enc_alu(0, kModeByte, 1, 2, 3, 0,
                         false, false, false, 0),
                 false, 0, false, true, kErrUnused);
  expect_illegal(dut, "MNOT has second source",
                 enc_mrf(3, 1, 2, 0, 0, false, false, false),
                 false, 0, false, true, kErrUnused);
  expect_illegal(dut, "ROUTE reserved bits",
                 enc_route(0, 1, 2, 0, true, false, 0, 0x1b, 1),
                 false, 0, false, true, kErrReserved);
  expect_illegal(dut, "ROUTE broadcast unused control",
                 enc_route(1, 1, 2, 0, true, false, 0, 0x42),
                 false, 0, false, true, kErrUnused);
  expect_illegal(dut, "ROUTE slide amount out of range",
                 enc_route(3, 1, 2, 0, true, false, 0, 5),
                 false, 0, false, true, kErrBadSubop);
  expect_illegal(dut, "ROUTE disabled destination is nonzero",
                 enc_route(0, 1, 2, 0, false, false, 0, 0x1b),
                 false, 0, false, true, kErrUnused);

  // Multi-error cases lock the documented cause priority rather than merely
  // checking that the word is rejected.
  expect_illegal(dut, "priority subop over reserved",
                 enc_wide(7, 0, 0, 0, 0, false,
                          false, false, 0, 1),
                 false, 0, false, true, kErrBadSubop);
  expect_illegal(dut, "priority reserved over extension",
                 enc_wadd(0, 1, 2, 3, 0, 0, 0, false, 1),
                 true, 0, false, true, kErrReserved);
  expect_illegal(dut, "priority mask over reduction",
                 enc_alu(0, kModeByte, 1, 2, 0, 5,
                         false, false, false, 7),
                 false, 0, false, true, kErrMask);
  expect_illegal(dut, "priority reduction over mode",
                 enc_alu(0, 3, 1, 2, 0, 0,
                         false, false, false, 7),
                 false, 0, false, true, kErrReduction);
  expect_illegal(dut, "priority writeback over address",
                 enc_wide(0, 1, 2, 8, 0, false,
                          true, true, 0),
                 false, 0, false, true, kErrWriteback);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_exec_uword_expander dut;

  dut.base_valid_i = 0;
  dut.base_word_i = 0;
  dut.extension_valid_i = 0;
  dut.extension_word_i = 0;
  dut.eval();
  expect_eq("idle extension required", 0, dut.extension_required_o);
  expect_eq("idle out valid", 0, dut.out_valid_o);
  expect_eq("idle legal", 0, dut.legal_o);
  expect_eq("idle cause", kErrNone, dut.error_cause_o);
  expect_zero_canonical(dut, "idle");

  // An extension without an associated base is not itself a transaction.
  dut.extension_valid_i = 1;
  dut.extension_word_i = 0xffffffff;
  dut.eval();
  expect_eq("orphan extension has no output", 0, dut.out_valid_o);
  expect_eq("orphan extension has no cause", kErrNone, dut.error_cause_o);
  expect_zero_canonical(dut, "orphan extension");

  test_golden_formats(dut);
  test_alu_subop_mapping_and_no_effect(dut);
  test_immediate_widths_and_results(dut);
  test_illegal_and_priority(dut);

  dut.final();
  std::cout << "PASS: " << checks
            << " EXEC uword expander checks across every v0 format, "
               "extension completeness, canonical mapping, result "
               "derivation, error priority, and illegal zero side effects\n";
  return 0;
}
