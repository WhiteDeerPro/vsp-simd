#include "Vsimd_mask_alu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr uint8_t MAND = 0x2a;
constexpr uint8_t MOR = 0x2b;
constexpr uint8_t MXOR = 0x2c;
constexpr uint8_t MNOT = 0x2d;

uint8_t reference(uint8_t op, uint8_t a, uint8_t b) {
  switch (op) {
    case MAND: return static_cast<uint8_t>(a & b);
    case MOR:  return static_cast<uint8_t>(a | b);
    case MXOR: return static_cast<uint8_t>(a ^ b);
    case MNOT: return static_cast<uint8_t>(~a);
    default: std::abort();
  }
}

[[noreturn]] void fail(uint8_t op, uint8_t a, uint8_t b,
                       uint8_t expected, const Vsimd_mask_alu& dut) {
  std::cerr << "FAIL op=0x" << std::hex << unsigned(op)
            << " a=0x" << unsigned(a) << " b=0x" << unsigned(b)
            << " expected=0x" << unsigned(expected)
            << " actual=0x" << unsigned(dut.result_o)
            << " illegal=" << unsigned(dut.illegal_o) << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_mask_alu dut;
  uint64_t tests = 0;

  for (unsigned op = MAND; op <= MNOT; ++op) {
    for (unsigned a = 0; a < 256; ++a) {
      for (unsigned b = 0; b < 256; ++b) {
        dut.op_i = op;
        dut.a_i = a;
        dut.b_i = b;
        dut.eval();
        const uint8_t expected = reference(op, a, b);
        if (dut.illegal_o || dut.result_o != expected) {
          fail(op, a, b, expected, dut);
        }
        ++tests;
      }
    }
  }

  dut.op_i = 0x3f;
  dut.eval();
  if (!dut.illegal_o || dut.result_o != 0) {
    fail(0x3f, dut.a_i, dut.b_i, 0, dut);
  }

  dut.final();
  std::cout << "PASS: " << tests
            << " exhaustive 8-lane MAND/MOR/MXOR/MNOT operand pairs"
            << " plus illegal-op check\n";
  return 0;
}
