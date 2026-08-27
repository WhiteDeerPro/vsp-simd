#include "Vsad_kernel.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

namespace {

constexpr unsigned kLanes = 8;

uint64_t pack(const std::array<uint8_t, kLanes>& data) {
  uint64_t packed = 0;
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    packed |= static_cast<uint64_t>(data[lane]) << (lane * 8);
  }
  return packed;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsad_kernel dut;
  std::mt19937 rng(0x534144u);

  for (unsigned iteration = 0; iteration < 10000; ++iteration) {
    std::array<uint8_t, kLanes> a{};
    std::array<uint8_t, kLanes> b{};
    for (auto& value : a) value = static_cast<uint8_t>(rng());
    for (auto& value : b) value = static_cast<uint8_t>(rng());
    const uint8_t mask = static_cast<uint8_t>(rng());

    uint32_t expected = 0;
    for (unsigned lane = 0; lane < kLanes; ++lane) {
      if (mask & (1u << lane)) {
        expected += a[lane] >= b[lane] ? a[lane] - b[lane]
                                       : b[lane] - a[lane];
      }
    }

    dut.mask_i = mask;
    dut.src_a_i = pack(a);
    dut.src_b_i = pack(b);
    dut.eval();

    if (dut.illegal_o || bool(dut.valid_o) != (mask != 0) ||
        dut.sad_o != expected) {
      std::cerr << "FAIL iteration=" << iteration
                << " mask=0x" << std::hex << unsigned(mask)
                << " expected=" << expected << " actual=" << dut.sad_o
                << " valid=" << unsigned(dut.valid_o)
                << " illegal=" << unsigned(dut.illegal_o) << '\n';
      return 1;
    }
  }

  dut.final();
  std::cout << "PASS: 10000 composed masked SAD vectors\n";
  return 0;
}

