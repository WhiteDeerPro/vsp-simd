#include "Vsimd_dynamic_alu.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

namespace {

constexpr uint8_t ADD = 0x00;
constexpr uint8_t SUB = 0x01;
constexpr uint8_t MIN_U = 0x06;
constexpr uint8_t MAX_U = 0x07;
constexpr uint8_t MIN_S = 0x08;
constexpr uint8_t MAX_S = 0x09;
constexpr uint8_t SHL = 0x0f;
constexpr uint8_t SHR_U = 0x10;
constexpr uint8_t SHR_S = 0x11;
constexpr uint8_t CMPEQ = 0x12;
constexpr uint8_t CMPGT_U = 0x13;
constexpr uint8_t CMPGT_S = 0x14;

struct Reference {
  uint32_t result;
  uint8_t predicate;
};

uint64_t width_mask(unsigned width) {
  return (uint64_t{1} << width) - 1;
}

int64_t signed_value(uint64_t value, unsigned width) {
  const uint64_t sign_bit = uint64_t{1} << (width - 1u);
  return (value & sign_bit)
             ? static_cast<int64_t>(value) -
                   static_cast<int64_t>(uint64_t{1} << width)
             : static_cast<int64_t>(value);
}

Reference reference(uint8_t op, uint8_t mode, uint32_t a, uint32_t b) {
  const unsigned width = 8u << mode;
  const unsigned elements = 32u / width;
  const unsigned lanes_per_element = width / 8u;
  const uint64_t mask = width_mask(width);
  Reference reference{0, 0};

  for (unsigned element = 0; element < elements; ++element) {
    const unsigned base = element * width;
    const uint64_t av = (uint64_t{a} >> base) & mask;
    const uint64_t bv = (uint64_t{b} >> base) & mask;
    const int64_t as = signed_value(av, width);
    const int64_t bs = signed_value(bv, width);
    const unsigned shift = static_cast<unsigned>(bv & (width - 1u));
    uint64_t value = 0;
    bool predicate = false;

    switch (op) {
      case ADD: value = (av + bv) & mask; break;
      case SUB: value = (av - bv) & mask; break;
      case MIN_U: value = (av < bv) ? av : bv; break;
      case MAX_U: value = (av > bv) ? av : bv; break;
      case MIN_S: value = (as < bs) ? av : bv; break;
      case MAX_S: value = (as > bs) ? av : bv; break;
      case SHL: value = (av << shift) & mask; break;
      case SHR_U: value = av >> shift; break;
      case SHR_S: {
        value = static_cast<uint64_t>(as >> shift) & mask;
        break;
      }
      case CMPEQ: predicate = av == bv; value = predicate ? mask : 0; break;
      case CMPGT_U: predicate = av > bv; value = predicate ? mask : 0; break;
      case CMPGT_S: predicate = as > bs; value = predicate ? mask : 0; break;
      default: std::abort();
    }
    reference.result |= static_cast<uint32_t>(value << base);
    if (predicate) {
      const uint8_t element_mask = static_cast<uint8_t>(
          ((1u << lanes_per_element) - 1u) <<
          (element * lanes_per_element));
      reference.predicate |= element_mask;
    }
  }
  return reference;
}

[[noreturn]] void fail(unsigned test, uint8_t op, uint8_t mode,
                       uint32_t a, uint32_t b, const Reference& expected,
                       const Vsimd_dynamic_alu& dut) {
  std::cerr << "FAIL test=" << std::dec << test
            << " op=0x" << std::hex << unsigned(op)
            << " mode=" << std::dec << unsigned(mode)
            << " a=0x" << std::hex << a << " b=0x" << b
            << " expected=0x" << expected.result
            << " actual=0x" << dut.result_o
            << " expected_predicate=0x" << unsigned(expected.predicate)
            << " actual_predicate=0x" << unsigned(dut.predicate_o)
            << " illegal=" << unsigned(dut.illegal_o) << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_dynamic_alu dut;
  std::mt19937 rng(0x44594e41u);
  constexpr uint8_t ops[]{ADD, SUB, MIN_U, MAX_U, MIN_S, MAX_S,
                          SHL, SHR_U, SHR_S, CMPEQ, CMPGT_U, CMPGT_S};
  constexpr unsigned kRandomPerModeOp = 20000;
  unsigned test = 0;

  for (uint8_t mode = 0; mode < 3; ++mode) {
    for (uint8_t op : ops) {
      for (unsigned iteration = 0; iteration < kRandomPerModeOp;
           ++iteration) {
        const uint32_t a = rng();
        const uint32_t b = rng();
        dut.op_i = op;
        dut.elem_mode_i = mode;
        dut.a_i = a;
        dut.b_i = b;
        dut.eval();
        const Reference expected = reference(op, mode, a, b);
        if (dut.illegal_o || dut.result_o != expected.result ||
            dut.predicate_o != expected.predicate) {
          fail(test, op, mode, a, b, expected, dut);
        }
        ++test;
      }
    }
  }

  for (uint8_t op : ops) {
    dut.op_i = op;
    dut.elem_mode_i = 3;
    dut.eval();
    if (!dut.illegal_o || dut.result_o != 0 || dut.predicate_o != 0) {
      fail(test, op, 3, dut.a_i, dut.b_i, {0, 0}, dut);
    }
  }

  dut.final();
  std::cout << "PASS: " << test
            << " partitioned BYTE/HALF/WORD add/sub/shift/min/max/compare cases"
            << " plus reserved-mode check\n";
  return 0;
}
