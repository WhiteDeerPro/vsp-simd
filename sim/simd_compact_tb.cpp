#include "Vsimd_compact.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

namespace {

struct Expected {
  uint64_t data;
  uint8_t valid_mask;
  uint8_t count;
};

Expected reference(uint64_t input, uint8_t mask, bool expand) {
  Expected expected{0, 0, 0};
  unsigned cursor = 0;

  for (unsigned lane = 0; lane < 8; ++lane) {
    if ((mask & (1u << lane)) == 0) continue;

    if (expand) {
      const uint64_t element = (input >> (cursor * 8)) & 0xffu;
      expected.data |= element << (lane * 8);
      expected.valid_mask |= static_cast<uint8_t>(1u << lane);
    } else {
      const uint64_t element = (input >> (lane * 8)) & 0xffu;
      expected.data |= element << (cursor * 8);
      expected.valid_mask |= static_cast<uint8_t>(1u << cursor);
    }
    ++cursor;
  }

  expected.count = static_cast<uint8_t>(cursor);
  return expected;
}

[[noreturn]] void fail(unsigned test, bool expand, uint64_t input,
                       uint8_t mask, const Expected& expected,
                       const Vsimd_compact& dut) {
  std::cerr << "FAIL test=" << std::dec << test
            << " op=" << (expand ? "expand" : "compress")
            << " input=0x" << std::hex << input
            << " mask=0x" << unsigned(mask)
            << " expected_data=0x" << expected.data
            << " actual_data=0x" << dut.data_o
            << " expected_valid=0x" << unsigned(expected.valid_mask)
            << " actual_valid=0x" << unsigned(dut.valid_mask_o)
            << " expected_count=" << std::dec << unsigned(expected.count)
            << " actual_count=" << unsigned(dut.count_o) << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_compact dut;
  std::mt19937_64 rng(0x434f4d50414354ULL);
  constexpr unsigned kSamplesPerMask = 64;
  unsigned test = 0;

  for (unsigned mask = 0; mask < 256; ++mask) {
    for (unsigned sample = 0; sample < kSamplesPerMask; ++sample) {
      const uint64_t input = rng();
      for (unsigned expand = 0; expand < 2; ++expand) {
        dut.expand_i = expand;
        dut.data_i = input;
        dut.mask_i = mask;
        dut.eval();

        const Expected expected = reference(input, mask, expand != 0);
        if (dut.data_o != expected.data ||
            dut.valid_mask_o != expected.valid_mask ||
            dut.count_o != expected.count) {
          fail(test, expand != 0, input, static_cast<uint8_t>(mask),
               expected, dut);
        }
        ++test;
      }
    }
  }

  dut.final();
  std::cout << "PASS: " << test
            << " stable 8-lane COMPRESS/EXPAND cases across every mask\n";
  return 0;
}
