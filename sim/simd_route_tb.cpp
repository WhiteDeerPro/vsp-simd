#include "Vsimd_route.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>

namespace {

constexpr unsigned LANES = 4;
constexpr unsigned GATHER = 0;
constexpr unsigned BROADCAST = 1;
constexpr unsigned SLIDE_UP = 2;
constexpr unsigned SLIDE_DOWN = 3;

uint32_t pack_data(const std::array<uint8_t, LANES>& lanes) {
  uint32_t packed = 0;
  for (unsigned lane = 0; lane < LANES; ++lane) {
    packed |= static_cast<uint32_t>(lanes[lane]) << (lane * 8);
  }
  return packed;
}

uint8_t pack_indices(const std::array<uint8_t, LANES>& indices) {
  uint8_t packed = 0;
  for (unsigned lane = 0; lane < LANES; ++lane) {
    packed |= static_cast<uint8_t>(indices[lane] << (lane * 2));
  }
  return packed;
}

[[noreturn]] void fail(const char* field, unsigned test, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << field << " test=" << std::dec << test
            << " expected=0x" << std::hex << expected << " actual=0x"
            << actual << '\n';
  std::exit(1);
}

void expect(Vsimd_route& dut, unsigned test,
            const std::array<uint8_t, LANES>& expected,
            uint8_t expected_boundary, bool expected_illegal = false) {
  dut.eval();
  if (dut.data_o != pack_data(expected)) {
    fail("data", test, pack_data(expected), dut.data_o);
  }
  if (dut.boundary_mask_o != expected_boundary) {
    fail("boundary mask", test, expected_boundary, dut.boundary_mask_o);
  }
  if (static_cast<bool>(dut.illegal_o) != expected_illegal) {
    fail("illegal", test, expected_illegal, dut.illegal_o);
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_route dut;

  const std::array<uint8_t, LANES> data{10, 20, 30, 40};
  const std::array<uint8_t, LANES> lower{1, 2, 3, 4};
  const std::array<uint8_t, LANES> upper{5, 6, 7, 8};
  dut.data_i = pack_data(data);
  dut.lower_i = pack_data(lower);
  dut.upper_i = pack_data(upper);

  dut.op_i = GATHER;
  dut.index_i = pack_indices({3, 0, 2, 1});
  expect(dut, 0, {40, 10, 30, 20}, 0);

  // Repeated selectors are legal: this is gather/multicast, not a collision.
  dut.index_i = pack_indices({2, 2, 0, 2});
  expect(dut, 1, {30, 30, 10, 30}, 0);

  for (unsigned source = 0; source < LANES; ++source) {
    dut.op_i = BROADCAST;
    dut.broadcast_index_i = source;
    expect(dut, 2 + source,
           {data[source], data[source], data[source], data[source]}, 0);
  }

  dut.op_i = SLIDE_UP;
  dut.slide_amount_i = 2;
  expect(dut, 6, {3, 4, 10, 20}, 0x3);

  dut.op_i = SLIDE_DOWN;
  dut.slide_amount_i = 2;
  expect(dut, 7, {30, 40, 5, 6}, 0xc);

  dut.op_i = SLIDE_UP;
  dut.slide_amount_i = LANES;
  expect(dut, 8, lower, 0xf);

  dut.op_i = SLIDE_DOWN;
  dut.slide_amount_i = LANES;
  expect(dut, 9, upper, 0xf);

  // The local route interface only spans this group and one adjacent group.
  dut.slide_amount_i = LANES + 1;
  expect(dut, 10, {0, 0, 0, 0}, 0, true);

  std::mt19937 rng(0x51deu);
  for (unsigned test = 0; test < 10000; ++test) {
    std::array<uint8_t, LANES> random_data{};
    std::array<uint8_t, LANES> random_lower{};
    std::array<uint8_t, LANES> random_upper{};
    std::array<uint8_t, LANES> indices{};
    std::array<uint8_t, LANES> expected{};
    for (unsigned lane = 0; lane < LANES; ++lane) {
      random_data[lane] = rng();
      random_lower[lane] = rng();
      random_upper[lane] = rng();
      indices[lane] = rng() % LANES;
    }

    dut.data_i = pack_data(random_data);
    dut.lower_i = pack_data(random_lower);
    dut.upper_i = pack_data(random_upper);
    dut.index_i = pack_indices(indices);
    dut.op_i = test % 4;
    dut.broadcast_index_i = rng() % LANES;
    dut.slide_amount_i = rng() % (LANES + 1);
    uint8_t boundary = 0;

    if (dut.op_i == GATHER) {
      for (unsigned lane = 0; lane < LANES; ++lane) {
        expected[lane] = random_data[indices[lane]];
      }
    } else if (dut.op_i == BROADCAST) {
      expected.fill(random_data[dut.broadcast_index_i]);
    } else if (dut.op_i == SLIDE_UP) {
      const unsigned amount = dut.slide_amount_i;
      for (unsigned lane = 0; lane < LANES; ++lane) {
        if (lane >= amount) {
          expected[lane] = random_data[lane - amount];
        } else {
          expected[lane] = random_lower[LANES - amount + lane];
          boundary |= 1u << lane;
        }
      }
    } else {
      const unsigned amount = dut.slide_amount_i;
      for (unsigned lane = 0; lane < LANES; ++lane) {
        if (lane + amount < LANES) {
          expected[lane] = random_data[lane + amount];
        } else {
          expected[lane] = random_upper[lane + amount - LANES];
          boundary |= 1u << lane;
        }
      }
    }
    expect(dut, 11 + test, expected, boundary);
  }

  dut.final();
  std::cout << "PASS: 10000 SIMD crossbar gather, broadcast, and adjacent slide cases\n";
  return 0;
}
