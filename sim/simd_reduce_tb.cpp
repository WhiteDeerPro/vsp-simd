#include "Vsimd_reduce.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

namespace {

constexpr unsigned kLanes = 8;

enum ReduceOp : uint8_t {
  SUM_U = 0,
  SUM_S = 1,
  MIN_U = 2,
  MIN_S = 3,
  MAX_U = 4,
  MAX_S = 5
};

uint64_t pack(const std::array<uint8_t, kLanes>& data) {
  uint64_t packed = 0;
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    packed |= static_cast<uint64_t>(data[lane]) << (lane * 8);
  }
  return packed;
}

[[noreturn]] void fail(uint8_t op, unsigned iteration, const char* field,
                       uint64_t expected, uint64_t actual) {
  std::cerr << "FAIL op=" << unsigned(op) << " iteration=" << iteration
            << " field=" << field << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_reduce dut;
  std::mt19937 rng(0x52454455u);

  for (uint8_t op = SUM_U; op <= MAX_S; ++op) {
    for (unsigned iteration = 0; iteration < 2000; ++iteration) {
      std::array<uint8_t, kLanes> data{};
      for (auto& value : data) value = static_cast<uint8_t>(rng());
      if (iteration == 0) data.fill(0x55);  // Explicitly exercise tie-breaking.

      const uint8_t mask = iteration == 1 ? 0u : static_cast<uint8_t>(rng());
      dut.op_i = op;
      dut.mask_i = mask;
      dut.data_i = pack(data);
      dut.eval();

      const bool expected_valid = mask != 0;
      uint32_t expected_value = 0;
      unsigned expected_index = 0;

      if (expected_valid) {
        bool first = true;
        int64_t sum = 0;
        int best = 0;
        for (unsigned lane = 0; lane < kLanes; ++lane) {
          if ((mask & (1u << lane)) == 0) continue;
          const int value = (op == SUM_S || op == MIN_S || op == MAX_S)
                                ? static_cast<int8_t>(data[lane])
                                : data[lane];
          if (op == SUM_U || op == SUM_S) {
            sum += value;
          } else if (first ||
                     ((op == MIN_U || op == MIN_S) && value < best) ||
                     ((op == MAX_U || op == MAX_S) && value > best)) {
            best = value;
            expected_index = lane;
          }
          first = false;
        }
        expected_value = (op == SUM_U || op == SUM_S)
                             ? static_cast<uint32_t>(sum)
                             : static_cast<uint32_t>(best);
      }

      if (dut.illegal_o) fail(op, iteration, "illegal", 0, 1);
      if (bool(dut.valid_o) != expected_valid) {
        fail(op, iteration, "valid", expected_valid, dut.valid_o);
      }
      if (dut.value_o != expected_value) {
        fail(op, iteration, "value", expected_value, dut.value_o);
      }
      if (expected_valid && op >= MIN_U && dut.index_o != expected_index) {
        fail(op, iteration, "index", expected_index, dut.index_o);
      }
    }
  }

  dut.op_i = 7;
  dut.mask_i = 0xff;
  dut.eval();
  if (!dut.illegal_o || dut.valid_o) fail(7, 0, "illegal", 1, dut.illegal_o);

  dut.final();
  std::cout << "PASS: 12000 randomized masked reduction vectors\n";
  return 0;
}

