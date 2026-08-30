// CLASS: 组件性质
// CLAIM: 4-group word-first pass 在四个 phase 后等价于 16-byte register
//        gather；full-byte OOB、active mask 和 multicast 语义符合合同。
// SOURCE / QUESTION: 两级 word/local 路由能否无 route-setting 地固定四次
//        完成任意 4xSIMD4 gather。
// ORACLE: 独立逐目的 byte 参考式 dst[i] = src[index[i]]，不复用 RTL 的
//        word/byte 分解控制生成。
// ASSUMPTIONS: 4 groups、每组 4 个 8-bit lane、group-major packing。
// NON_CLAIMS: 不验证时序状态、VRF capture/commit、编码、PPA 或更大网络。
// RETIRE_WHEN: 若 route-domain 物理形状改变，由新形状的等价测试接替。

#include "Vvsp_word_first_gather_phase.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>
#include <string>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kLanesPerGroup = 4;
constexpr unsigned kLanes = kGroups * kLanesPerGroup;

using Bytes = std::array<uint8_t, kLanes>;

uint64_t checks = 0;

template <typename Wide>
void set_wide(Wide& signal, const Bytes& bytes) {
  for (unsigned word = 0; word < 4; ++word) {
    uint32_t packed = 0;
    for (unsigned byte = 0; byte < 4; ++byte) {
      packed |= static_cast<uint32_t>(bytes[(word * 4) + byte]) <<
                (byte * 8);
    }
    signal[word] = packed;
  }
}

[[noreturn]] void fail(const std::string& label, const std::string& field,
                       unsigned phase = 0) {
  std::cerr << "FAIL " << label << " field=" << field
            << " phase=" << phase << '\n';
  std::exit(1);
}

void expect_case(Vvsp_word_first_gather_phase& dut, const std::string& label,
                 const Bytes& source, const Bytes& index, uint16_t active_mask,
                 const Bytes& initial) {
  Bytes actual = initial;
  uint16_t observed_oob = 0;

  set_wide(dut.source_i, source);
  set_wide(dut.index_i, index);
  dut.active_mask_i = active_mask;

  for (unsigned phase = 0; phase < kLanesPerGroup; ++phase) {
    dut.phase_i = static_cast<uint8_t>(phase);
    dut.eval();

    const uint8_t write_enables = dut.selected_we_o;
    const uint8_t oob = dut.selected_oob_o;
    const uint32_t selected = dut.selected_byte_o;

    for (unsigned group = 0; group < kGroups; ++group) {
      const unsigned lane = (group * kLanesPerGroup) + phase;
      const bool active = ((active_mask >> lane) & 1u) != 0;
      const bool in_range = index[lane] < kLanes;

      if ((((write_enables >> group) & 1u) != 0) !=
          (active && in_range)) {
        fail(label, "write enable", phase);
      }
      if ((((oob >> group) & 1u) != 0) != (active && !in_range)) {
        fail(label, "oob", phase);
      }

      if (active && in_range) {
        const uint8_t selected_byte =
            static_cast<uint8_t>(selected >> (group * 8));
        const uint8_t expected_byte = source[index[lane]];
        if (selected_byte != expected_byte) {
          fail(label, "selected byte", phase);
        }
        actual[lane] = selected_byte;
      }
      if (active && !in_range) {
        observed_oob |= static_cast<uint16_t>(1u << lane);
      }
    }
  }

  Bytes expected = initial;
  uint16_t expected_oob = 0;
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    if (((active_mask >> lane) & 1u) == 0) continue;
    if (index[lane] < kLanes) {
      expected[lane] = source[index[lane]];
    } else {
      expected_oob |= static_cast<uint16_t>(1u << lane);
    }
  }

  if (actual != expected) fail(label, "assembled result");
  if (observed_oob != expected_oob) fail(label, "assembled oob");
  ++checks;
}

Bytes ramp(uint8_t base) {
  Bytes value{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    value[lane] = static_cast<uint8_t>(base + lane);
  }
  return value;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_word_first_gather_phase dut;

  const Bytes source = ramp(0x20);
  const Bytes initial = ramp(0xa0);

  Bytes identity{};
  Bytes reverse{};
  Bytes transpose{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    identity[lane] = static_cast<uint8_t>(lane);
    reverse[lane] = static_cast<uint8_t>(kLanes - 1 - lane);
    transpose[lane] = static_cast<uint8_t>(
        ((lane % kLanesPerGroup) * kLanesPerGroup) +
        (lane / kLanesPerGroup));
  }

  expect_case(dut, "identity", source, identity, 0xffffu, initial);
  expect_case(dut, "reverse", source, reverse, 0xffffu, initial);
  expect_case(dut, "transpose", source, transpose, 0xffffu, initial);

  for (unsigned selected_lane = 0; selected_lane < kLanes; ++selected_lane) {
    Bytes broadcast{};
    broadcast.fill(static_cast<uint8_t>(selected_lane));
    expect_case(dut, "broadcast", source, broadcast, 0xffffu, initial);
  }

  Bytes oob = identity;
  oob[0] = 16;
  oob[5] = 31;
  oob[10] = 255;
  oob[15] = 200;
  expect_case(dut, "active oob", source, oob, 0xffffu, initial);
  expect_case(dut, "masked oob", source, oob, 0x7bdeu, initial);
  expect_case(dut, "all inactive", source, oob, 0x0000u, initial);

  // Repeated source words with different bytes and repeated identical bytes
  // exercise both legal multicast cases explicitly.
  const Bytes repeated{0, 1, 2, 3, 0, 0, 3, 3,
                       5, 6, 5, 6, 12, 12, 12, 15};
  expect_case(dut, "mixed multicast", source, repeated, 0xffffu, initial);

  std::mt19937 rng(0x4a71e5u);
  for (unsigned test = 0; test < 20000; ++test) {
    Bytes random_source{};
    Bytes random_index{};
    for (unsigned lane = 0; lane < kLanes; ++lane) {
      random_source[lane] = static_cast<uint8_t>(rng());
      random_index[lane] = static_cast<uint8_t>(rng());
    }
    const uint16_t active_mask = static_cast<uint16_t>(rng());
    expect_case(dut, "random", random_source, random_index, active_mask,
                initial);
  }

  dut.final();
  std::cout << "PASS: " << checks
            << " four-phase word-first gather cases\n";
  return 0;
}
