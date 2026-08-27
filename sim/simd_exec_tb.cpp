#include "Vsimd_exec.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

namespace {

constexpr unsigned kLanes = 4;

enum Op : uint8_t {
  ADD       = 0x00,
  SUB       = 0x01,
  ADD_SAT_U = 0x02,
  SUB_SAT_U = 0x03,
  ADD_SAT_S = 0x04,
  SUB_SAT_S = 0x05,
  MIN_U     = 0x06,
  MAX_U     = 0x07,
  MIN_S     = 0x08,
  MAX_S     = 0x09,
  ABSDIFF_U = 0x0a,
  AVG_U     = 0x0b,
  AND       = 0x0c,
  OR        = 0x0d,
  XOR       = 0x0e,
  SHL       = 0x0f,
  SHR_U     = 0x10,
  SHR_S     = 0x11,
  CMPEQ     = 0x12,
  CMPGT_U   = 0x13,
  CMPGT_S   = 0x14,
  ABS_SAT_S = 0x15,
  MUL_U     = 0x16,
  MUL_S     = 0x17,
  MAC_U     = 0x18,
  MAC_S     = 0x19,
  PASS_A    = 0x1a,
  SELECT    = 0x1b,
  WIDEN_U   = 0x1c,
  WIDEN_S   = 0x1d,
  WADD_U    = 0x1e,
  WADD_S    = 0x1f,
  WSUB_U    = 0x20,
  WSUB_S    = 0x21,
  RSHIFT_RND_U = 0x22,
  RSHIFT_RND_S = 0x23,
  NCLIP_U   = 0x24,
  NCLIP_S   = 0x25,
  NSLICE    = 0x26,
  AVG_S     = 0x27
};

struct LaneResult {
  uint8_t narrow;
  uint32_t wide;
  bool predicate;
};

uint32_t pack8(const std::array<uint8_t, kLanes>& lanes) {
  uint32_t value = 0;
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    value |= static_cast<uint32_t>(lanes[lane]) << (lane * 8);
  }
  return value;
}

uint8_t lane8(uint32_t packed, unsigned lane) {
  return static_cast<uint8_t>((packed >> (lane * 8)) & 0xffu);
}

uint8_t signed_sat(int value) {
  if (value > 127) return 0x7f;
  if (value < -128) return 0x80;
  return static_cast<uint8_t>(static_cast<int8_t>(value));
}

LaneResult reference(uint8_t op, uint8_t a, uint8_t b, uint32_t acc,
                     uint8_t align, bool select_a) {
  LaneResult r{0, 0, false};
  const int sa = static_cast<int8_t>(a);
  const int sb = static_cast<int8_t>(b);

  switch (op) {
    case ADD:       r.narrow = static_cast<uint8_t>(a + b); break;
    case SUB:       r.narrow = static_cast<uint8_t>(a - b); break;
    case ADD_SAT_U: r.narrow = (unsigned(a) + unsigned(b) > 255u)
                                  ? 255u : static_cast<uint8_t>(a + b); break;
    case SUB_SAT_U: r.narrow = (a < b) ? 0u : static_cast<uint8_t>(a - b); break;
    case ADD_SAT_S: r.narrow = signed_sat(sa + sb); break;
    case SUB_SAT_S: r.narrow = signed_sat(sa - sb); break;
    case MIN_U:     r.narrow = (a < b) ? a : b; break;
    case MAX_U:     r.narrow = (a > b) ? a : b; break;
    case MIN_S:     r.narrow = (sa < sb) ? a : b; break;
    case MAX_S:     r.narrow = (sa > sb) ? a : b; break;
    case ABSDIFF_U: r.narrow = (a >= b) ? uint8_t(a - b) : uint8_t(b - a); break;
    case AVG_U:     r.narrow = static_cast<uint8_t>((unsigned(a) + unsigned(b) + 1u) >> 1); break;
    case AVG_S: {
      const int sum = sa + sb;
      const int average = (sum >= 0) ? ((sum + 1) / 2) : (sum / 2);
      r.narrow = static_cast<uint8_t>(static_cast<int8_t>(average));
      break;
    }
    case AND:       r.narrow = a & b; break;
    case OR:        r.narrow = a | b; break;
    case XOR:       r.narrow = a ^ b; break;
    case SHL:       r.narrow = static_cast<uint8_t>(unsigned(a) << (b & 7u)); break;
    case SHR_U:     r.narrow = static_cast<uint8_t>(a >> (b & 7u)); break;
    case SHR_S:     r.narrow = static_cast<uint8_t>(static_cast<int8_t>(a) >> (b & 7u)); break;
    case CMPEQ:
      r.predicate = (a == b);
      r.narrow = r.predicate ? 0xffu : 0u;
      break;
    case CMPGT_U:
      r.predicate = (a > b);
      r.narrow = r.predicate ? 0xffu : 0u;
      break;
    case CMPGT_S:
      r.predicate = (sa > sb);
      r.narrow = r.predicate ? 0xffu : 0u;
      break;
    case ABS_SAT_S:
      r.narrow = (sa == -128) ? 0x7fu : static_cast<uint8_t>(sa < 0 ? -sa : sa);
      break;
    case MUL_U: {
      const uint32_t product = unsigned(a) * unsigned(b);
      r.narrow = static_cast<uint8_t>(product);
      r.wide = product;
      return r;
    }
    case MUL_S: {
      const int32_t product = sa * sb;
      r.narrow = static_cast<uint8_t>(product);
      r.wide = static_cast<uint32_t>(product);
      return r;
    }
    case MAC_U: {
      const uint32_t product = unsigned(a) * unsigned(b);
      r.narrow = static_cast<uint8_t>(product);
      r.wide = acc + product;
      return r;
    }
    case MAC_S: {
      const int32_t product = sa * sb;
      r.narrow = static_cast<uint8_t>(product);
      r.wide = acc + static_cast<uint32_t>(product);
      return r;
    }
    case PASS_A: r.narrow = a; break;
    case SELECT: r.narrow = select_a ? a : b; break;
    case WIDEN_U:
      r.wide = static_cast<uint32_t>(a) << (b & 31u);
      r.narrow = static_cast<uint8_t>(r.wide);
      return r;
    case WIDEN_S:
      r.wide = static_cast<uint32_t>(static_cast<int32_t>(sa)) << (b & 31u);
      r.narrow = static_cast<uint8_t>(r.wide);
      return r;
    case WADD_U:
      r.wide = acc +
               (static_cast<uint32_t>(a) << (align & 31u)) +
               (static_cast<uint32_t>(b) << (align & 31u));
      r.narrow = static_cast<uint8_t>(r.wide);
      return r;
    case WADD_S: {
      const uint32_t shifted_a =
          static_cast<uint32_t>(static_cast<int32_t>(sa)) << (align & 31u);
      const uint32_t shifted_b =
          static_cast<uint32_t>(static_cast<int32_t>(sb)) << (align & 31u);
      r.wide = acc + shifted_a + shifted_b;
      r.narrow = static_cast<uint8_t>(r.wide);
      return r;
    }
    case WSUB_U: {
      const uint32_t shifted_a =
          static_cast<uint32_t>(a) << (align & 31u);
      const uint32_t shifted_b =
          static_cast<uint32_t>(b) << (align & 31u);
      r.wide = acc + shifted_a - shifted_b;
      r.narrow = static_cast<uint8_t>(r.wide);
      return r;
    }
    case WSUB_S: {
      const uint32_t shifted_a =
          static_cast<uint32_t>(static_cast<int32_t>(sa)) << (align & 31u);
      const uint32_t shifted_b =
          static_cast<uint32_t>(static_cast<int32_t>(sb)) << (align & 31u);
      r.wide = acc + shifted_a - shifted_b;
      r.narrow = static_cast<uint8_t>(r.wide);
      return r;
    }
    case RSHIFT_RND_U:
    case RSHIFT_RND_S:
    case NCLIP_U:
    case NCLIP_S: {
      const unsigned shift = b & 31u;
      const uint32_t increment = shift == 0 ? 0u : ((acc >> (shift - 1)) & 1u);
      if (op == RSHIFT_RND_U || op == NCLIP_U) {
        const uint32_t rounded = (acc >> shift) + increment;
        r.narrow = (op == NCLIP_U && rounded > 255u)
                       ? 255u
                       : static_cast<uint8_t>(rounded);
        r.wide = (op == NCLIP_U) ? r.narrow : rounded;
      } else {
        const int64_t signed_acc = (acc & 0x80000000u)
                                       ? static_cast<int64_t>(acc) - 0x100000000ll
                                       : static_cast<int64_t>(acc);
        const int64_t rounded = (signed_acc >> shift) + increment;
        if (op == NCLIP_S) {
          r.narrow = signed_sat(static_cast<int>(rounded));
          r.wide = r.narrow;
        } else {
          r.narrow = static_cast<uint8_t>(rounded);
          r.wide = static_cast<uint32_t>(rounded);
        }
      }
      return r;
    }
    case NSLICE:
      r.narrow = static_cast<uint8_t>(acc >> (b & 31u));
      r.wide = r.narrow;
      return r;
    default: break;
  }

  r.wide = r.narrow;
  return r;
}

[[noreturn]] void fail(uint8_t op, unsigned iteration, unsigned lane,
                       const char* field, uint64_t expected, uint64_t actual) {
  std::cerr << "FAIL op=0x" << std::hex << unsigned(op)
            << " iteration=" << std::dec << iteration
            << " lane=" << lane << " field=" << field
            << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_exec dut;
  std::mt19937 rng(0x565350u);
  dut.elem_mode_i = 0;

  for (uint8_t op = ADD; op <= AVG_S; ++op) {
    for (unsigned iteration = 0; iteration < 300; ++iteration) {
      std::array<uint8_t, kLanes> a{};
      std::array<uint8_t, kLanes> b{};
      std::array<uint8_t, kLanes> merge{};
      std::array<uint32_t, kLanes> acc{};

      for (unsigned lane = 0; lane < kLanes; ++lane) {
        a[lane] = static_cast<uint8_t>(rng());
        b[lane] = static_cast<uint8_t>(rng());
        merge[lane] = static_cast<uint8_t>(rng());
        acc[lane] = rng();
        dut.acc_i[lane] = acc[lane];
      }

      const uint8_t mask = static_cast<uint8_t>(rng() & 0x0fu);
      const uint8_t select = static_cast<uint8_t>(rng() & 0x0fu);
      const uint8_t align = static_cast<uint8_t>(rng() & 31u);
      dut.op_i = op;
      dut.mask_i = mask;
      dut.select_i = select;
      dut.src_a_i = pack8(a);
      dut.src_b_i = pack8(b);
      dut.align_i = align;
      dut.merge_i = pack8(merge);
      dut.eval();

      if (dut.illegal_o) fail(op, iteration, 0, "illegal", 0, 1);

      for (unsigned lane = 0; lane < kLanes; ++lane) {
        LaneResult expected = reference(op, a[lane], b[lane], acc[lane],
                                        align, (select >> lane) & 1u);
        if ((mask & (1u << lane)) == 0) {
          expected.narrow = merge[lane];
          expected.wide = acc[lane];
          expected.predicate = false;
        }

        const uint8_t actual_narrow = lane8(dut.result_o, lane);
        const uint32_t actual_wide = dut.wide_o[lane];
        const bool actual_predicate = (dut.predicate_o >> lane) & 1u;

        if (actual_narrow != expected.narrow) {
          fail(op, iteration, lane, "narrow", expected.narrow, actual_narrow);
        }
        if (actual_wide != expected.wide) {
          fail(op, iteration, lane, "wide", expected.wide, actual_wide);
        }
        if (actual_predicate != expected.predicate) {
          fail(op, iteration, lane, "predicate", expected.predicate, actual_predicate);
        }
      }
    }
  }

  // NSLICE is an exact bit slice: it does not round or saturate.
  dut.op_i = NSLICE;
  dut.mask_i = 0x0f;
  dut.src_b_i = pack8({0, 8, 16, 24});
  dut.align_i = 0;
  dut.merge_i = 0;
  dut.acc_i[0] = 0x123456f0u;
  dut.acc_i[1] = 0x89abcdefu;
  dut.acc_i[2] = 0x10203040u;
  dut.acc_i[3] = 0xffeeddccu;
  dut.eval();
  const uint32_t expected_slices = pack8({0xf0, 0xcd, 0x20, 0xff});
  if (dut.result_o != expected_slices) {
    fail(NSLICE, 300, 0, "directed byte slices", expected_slices,
         dut.result_o);
  }

  // AVG_S uses an ELEM_W+1 signed sum and round-to-nearest-up, including
  // negative half-way cases rounding toward positive infinity.
  dut.op_i = AVG_S;
  dut.src_a_i = pack8({0x7f, 0x80, 0xff, 0x7f});
  dut.src_b_i = pack8({0x7f, 0x80, 0x00, 0x80});
  dut.eval();
  const uint32_t expected_signed_averages =
      pack8({0x7f, 0x80, 0x00, 0x00});
  if (dut.result_o != expected_signed_averages) {
    fail(AVG_S, 300, 0, "directed signed averages",
         expected_signed_averages, dut.result_o);
  }

  // WADD consumes both narrow sources and the accumulator through a 3:2
  // compressor. One scalar alignment applies to both narrow addends.
  dut.op_i = WADD_U;
  dut.src_a_i = pack8({1, 2, 3, 4});
  dut.src_b_i = pack8({10, 20, 30, 40});
  dut.align_i = 2;
  dut.acc_i[0] = 1000;
  dut.acc_i[1] = 2000;
  dut.acc_i[2] = 3000;
  dut.acc_i[3] = 4000;
  dut.eval();
  const std::array<uint32_t, kLanes> expected_shifted_wadd{
      1044, 2088, 3132, 4176};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    const uint32_t expected = expected_shifted_wadd[lane];
    if (dut.wide_o[lane] != expected) {
      fail(WADD_U, 300, lane, "aligned three-input add", expected,
           dut.wide_o[lane]);
    }
  }

  // WSUB uses the same three inputs and computes acc + aligned(A) - aligned(B).
  dut.op_i = WSUB_U;
  dut.eval();
  const std::array<uint32_t, kLanes> expected_shifted_wsub{
      964, 1928, 2892, 3856};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    const uint32_t expected = expected_shifted_wsub[lane];
    if (dut.wide_o[lane] != expected) {
      fail(WSUB_U, 300, lane, "aligned three-input subtract", expected,
           dut.wide_o[lane]);
    }
  }

  dut.op_i = 0x3f;
  dut.mask_i = 0x0f;
  dut.eval();
  if (!dut.illegal_o) fail(0x3f, 0, 0, "illegal", 1, 0);

  dut.final();
  std::cout << "PASS: 12000 randomized vectors (48000 lanes), signed/unsigned rounded averages, aligned three-input WADD/WSUB, exact NSLICE bytes, plus illegal-op check\n";
  return 0;
}
