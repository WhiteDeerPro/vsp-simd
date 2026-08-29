// CLASS: 组件性质
// CLAIM: 16-lane gather-only crossbar 的九种 mode（含动态 GATHER）、rotate
//        wrap 报告和保留 mode 的无数据拒绝符合各自定义。
// SOURCE / QUESTION: 动态 route-setting 难以实现；固定 crossbar 是否能作为
//        临时基线支撑需要跨组置换的 8-bit 图像映射。
// ORACLE: C++ 逐 lane 参考映射，外加不复制 select 生成算法的可逆性/置换性质。
// ASSUMPTIONS: 组合、无状态、无 mask;  16 lane 单一 elaboration profile。
// NON_CLAIMS: 不声称该网络规模、分级、流水或面积合适；不声称已接入数据通路、
//        已定义 stripe/索引来源/资源预留/写回事务；不声称它是最终路由方案。
// RETIRE_WHEN: 选定正式跨组路由方案并定义写回事务后，由该方案的测试接替。

#include "Vvsp_lane_gather.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>
#include <string>

namespace {

constexpr unsigned LANES = 16;
constexpr unsigned TILE_SIDE = 4;
constexpr unsigned HALF = LANES / 2;

constexpr unsigned MODE_IDENTITY = 0;
constexpr unsigned MODE_GATHER = 1;
constexpr unsigned MODE_BROADCAST = 2;
constexpr unsigned MODE_ROTATE_UP = 3;
constexpr unsigned MODE_ROTATE_DOWN = 4;
constexpr unsigned MODE_REVERSE = 5;
constexpr unsigned MODE_TRANSPOSE = 6;
constexpr unsigned MODE_DEINTERLEAVE = 7;
constexpr unsigned MODE_INTERLEAVE = 8;
constexpr unsigned MODE_FIRST_RESERVED = 9;

using Vec = std::array<uint8_t, LANES>;

uint64_t checks = 0;

void set_data(Vvsp_lane_gather& dut, const Vec& lanes) {
  for (unsigned word = 0; word < 4; ++word) {
    uint32_t packed = 0;
    for (unsigned byte = 0; byte < 4; ++byte) {
      packed |= static_cast<uint32_t>(lanes[(word * 4) + byte]) << (byte * 8);
    }
    dut.data_i[word] = packed;
  }
}

Vec get_data(const Vvsp_lane_gather& dut) {
  Vec lanes{};
  for (unsigned lane = 0; lane < LANES; ++lane) {
    lanes[lane] = static_cast<uint8_t>(dut.data_o[lane / 4] >> ((lane % 4) * 8));
  }
  return lanes;
}

uint64_t pack_indices(const Vec& indices) {
  uint64_t packed = 0;
  for (unsigned lane = 0; lane < LANES; ++lane) {
    packed |= static_cast<uint64_t>(indices[lane] & 0xf) << (lane * 4);
  }
  return packed;
}

[[noreturn]] void fail(const std::string& label, const char* field) {
  std::cerr << "FAIL " << label << " field=" << field << '\n';
  std::exit(1);
}

// One evaluation of the stateless stage. wrap and illegal are returned so the
// caller can check them or feed data_o back for a composition property.
Vec apply(Vvsp_lane_gather& dut, unsigned mode, const Vec& input,
          uint64_t indices, unsigned amount, uint16_t* wrap = nullptr,
          bool* illegal = nullptr) {
  dut.mode_i = static_cast<uint8_t>(mode);
  set_data(dut, input);
  dut.index_i = indices;
  dut.amount_i = static_cast<uint8_t>(amount);
  dut.eval();
  if (wrap != nullptr) {
    *wrap = static_cast<uint16_t>(dut.wrap_mask_o);
  }
  if (illegal != nullptr) {
    *illegal = dut.illegal_o != 0;
  }
  return get_data(dut);
}

void expect(Vvsp_lane_gather& dut, const std::string& label, unsigned mode,
            const Vec& input, uint64_t indices, unsigned amount,
            const Vec& expected, uint16_t expected_wrap,
            bool expected_illegal) {
  uint16_t wrap = 0;
  bool illegal = false;
  const Vec actual = apply(dut, mode, input, indices, amount, &wrap, &illegal);
  if (actual != expected) {
    fail(label, "data");
  }
  if (wrap != expected_wrap) {
    fail(label, "wrap mask");
  }
  if (illegal != expected_illegal) {
    fail(label, "illegal");
  }
  ++checks;
}

Vec ramp() {
  Vec lanes{};
  for (unsigned lane = 0; lane < LANES; ++lane) {
    lanes[lane] = static_cast<uint8_t>(0x10 + lane);
  }
  return lanes;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_lane_gather dut;

  const Vec data = ramp();
  Vec identity_indices{};
  for (unsigned lane = 0; lane < LANES; ++lane) {
    identity_indices[lane] = static_cast<uint8_t>(lane);
  }
  const uint64_t identity_packed = pack_indices(identity_indices);

  expect(dut, "identity", MODE_IDENTITY, data, 0, 0, data, 0, false);

  // Hand-written anchors. These are written out rather than generated so they
  // do not share a helper with the select-generation logic under test.
  const Vec reversed{0x1f, 0x1e, 0x1d, 0x1c, 0x1b, 0x1a, 0x19, 0x18,
                     0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11, 0x10};
  expect(dut, "reverse", MODE_REVERSE, data, 0, 0, reversed, 0, false);

  const Vec transposed{0x10, 0x14, 0x18, 0x1c, 0x11, 0x15, 0x19, 0x1d,
                       0x12, 0x16, 0x1a, 0x1e, 0x13, 0x17, 0x1b, 0x1f};
  expect(dut, "transpose", MODE_TRANSPOSE, data, 0, 0, transposed, 0, false);

  const Vec deinterleaved{0x10, 0x12, 0x14, 0x16, 0x18, 0x1a, 0x1c, 0x1e,
                          0x11, 0x13, 0x15, 0x17, 0x19, 0x1b, 0x1d, 0x1f};
  expect(dut, "deinterleave", MODE_DEINTERLEAVE, data, 0, 0, deinterleaved, 0,
         false);

  const Vec interleaved{0x10, 0x18, 0x11, 0x19, 0x12, 0x1a, 0x13, 0x1b,
                        0x14, 0x1c, 0x15, 0x1d, 0x16, 0x1e, 0x17, 0x1f};
  expect(dut, "interleave", MODE_INTERLEAVE, data, 0, 0, interleaved, 0, false);

  // Every broadcast source, and every rotate distance in both directions.
  for (unsigned source = 0; source < LANES; ++source) {
    Vec expected{};
    expected.fill(data[source]);
    expect(dut, "broadcast", MODE_BROADCAST, data, 0, source, expected, 0,
           false);
  }

  for (unsigned amount = 0; amount < LANES; ++amount) {
    Vec up{};
    Vec down{};
    uint16_t up_wrap = 0;
    uint16_t down_wrap = 0;
    for (unsigned lane = 0; lane < LANES; ++lane) {
      up[lane] = data[(lane + LANES - amount) % LANES];
      down[lane] = data[(lane + amount) % LANES];
      if (lane < amount) {
        up_wrap |= static_cast<uint16_t>(1u << lane);
      }
      if ((lane + amount) >= LANES) {
        down_wrap |= static_cast<uint16_t>(1u << lane);
      }
    }
    expect(dut, "rotate up", MODE_ROTATE_UP, data, 0, amount, up, up_wrap,
           false);
    expect(dut, "rotate down", MODE_ROTATE_DOWN, data, 0, amount, down,
           down_wrap, false);
  }

  // Reserved encodings must reject without delivering data.
  for (unsigned mode = MODE_FIRST_RESERVED; mode < 16; ++mode) {
    Vec zero{};
    zero.fill(0);
    expect(dut, "reserved mode", mode, data, identity_packed, 3, zero, 0, true);
  }

  std::mt19937 rng(0x16c8u);
  for (unsigned test = 0; test < 20000; ++test) {
    Vec random_data{};
    Vec indices{};
    for (unsigned lane = 0; lane < LANES; ++lane) {
      random_data[lane] = static_cast<uint8_t>(rng());
      indices[lane] = static_cast<uint8_t>(rng() % LANES);
    }

    Vec expected{};
    for (unsigned lane = 0; lane < LANES; ++lane) {
      expected[lane] = random_data[indices[lane]];
    }
    expect(dut, "dynamic gather", MODE_GATHER, random_data,
           pack_indices(indices), 0, expected, 0, false);

    // A bijective index vector must deliver a permutation of the input. This
    // property does not reuse the per-lane mapping above.
    Vec permutation = identity_indices;
    std::shuffle(permutation.begin(), permutation.end(), rng);
    const Vec routed = apply(dut, MODE_GATHER, random_data,
                             pack_indices(permutation), 0);
    Vec sorted_input = random_data;
    Vec sorted_output = routed;
    std::sort(sorted_input.begin(), sorted_input.end());
    std::sort(sorted_output.begin(), sorted_output.end());
    if (sorted_input != sorted_output) {
      fail("permutation multiset", "data");
    }
    ++checks;

    // Cross-mode consistency: the compact static encodings must agree with the
    // equivalent dynamic index vector.
    const unsigned source = rng() % LANES;
    Vec broadcast_indices{};
    broadcast_indices.fill(static_cast<uint8_t>(source));
    if (apply(dut, MODE_BROADCAST, random_data, 0, source) !=
        apply(dut, MODE_GATHER, random_data, pack_indices(broadcast_indices),
              0)) {
      fail("broadcast versus gather", "data");
    }
    ++checks;

    if (apply(dut, MODE_IDENTITY, random_data, 0, 0) !=
        apply(dut, MODE_GATHER, random_data, identity_packed, 0)) {
      fail("identity versus gather", "data");
    }
    ++checks;
  }

  // Inverse-composition properties. Each one is an external invariant rather
  // than a copy of the select-generation algorithm.
  for (unsigned test = 0; test < 4000; ++test) {
    Vec random_data{};
    for (unsigned lane = 0; lane < LANES; ++lane) {
      random_data[lane] = static_cast<uint8_t>(rng());
    }

    if (apply(dut, MODE_REVERSE, apply(dut, MODE_REVERSE, random_data, 0, 0), 0,
              0) != random_data) {
      fail("reverse twice", "data");
    }
    ++checks;

    if (apply(dut, MODE_TRANSPOSE,
              apply(dut, MODE_TRANSPOSE, random_data, 0, 0), 0, 0) !=
        random_data) {
      fail("transpose twice", "data");
    }
    ++checks;

    if (apply(dut, MODE_INTERLEAVE,
              apply(dut, MODE_DEINTERLEAVE, random_data, 0, 0), 0, 0) !=
        random_data) {
      fail("deinterleave then interleave", "data");
    }
    ++checks;

    const unsigned amount = rng() % LANES;
    if (apply(dut, MODE_ROTATE_DOWN,
              apply(dut, MODE_ROTATE_UP, random_data, 0, amount), 0, amount) !=
        random_data) {
      fail("rotate up then down", "data");
    }
    ++checks;

    // Masking the reported wrap lanes off must turn a rotate into a zero-fill
    // shift, which is what a stencil needs from a wide logical vector.
    uint16_t wrap = 0;
    Vec rotated = apply(dut, MODE_ROTATE_UP, random_data, 0, amount, &wrap);
    Vec shifted{};
    for (unsigned lane = 0; lane < LANES; ++lane) {
      shifted[lane] = (lane >= amount) ? random_data[lane - amount] : 0;
      if ((wrap & (1u << lane)) != 0) {
        rotated[lane] = 0;
      }
    }
    if (rotated != shifted) {
      fail("wrap mask gives zero-fill shift", "data");
    }
    ++checks;
  }


  dut.final();
  std::cout << "PASS: " << std::dec << checks
            << " 16-lane gather crossbar checks across dynamic indices, "
               "static patterns, rotate wrap reporting, inverse-composition "
               "properties and reserved-mode rejection\n";
  return 0;
}
