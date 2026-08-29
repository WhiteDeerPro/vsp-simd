// CLASS: 工作负载证据（比较集合）
// CLAIM: 可分离 [1,2,1] 两 pass 映射可以用现有 byte 原语闭合，逐像素与独立的
//        同算术参考模型一致；它与精确九 tap 单次舍入结果的偏差有界且可计量，
//        偏差与微操作计量共同说明 HALF 中间值支持能买到什么。
// SOURCE / QUESTION: docs/workloads/gaussian3x3.md 第 7 节把可分离 Gaussian 列为
//        受阻项：水平中间值最大 1020 需要 10 bit，8-bit VRF 无法无损保存，而
//        MUL/MAC 是 byte-only。今天唯一可闭合的方案是每 pass 都缩回 8 bit，
//        接受两次舍入；本测试测量这个方案的代价。
// ORACLE: 两个彼此独立的 C++ 模型——(1) 同为两次舍入的可分离算术，作为正确性
//        oracle；(2) 精确九 tap 单次舍入，作为精度标尺。RTL 只执行可分离映射。
// ASSUMPTIONS: 单 SIMD4 group；水平中间值整幅保存在驱动侧，代表硬件尚不存在的
//        line buffer / 本地存储；零填充边界；两个 pass 都不会饱和（1020 -> 255）。
// NON_CLAIMS: 不声称可分离映射在当前硬件上更快（无中间行复用时它更慢，见 §4）；
//        不声称 line buffer 已有 RTL；不声称九 tap 直接映射的数值覆盖（那仍由
//        gaussian3x3_tb 负责）；不声称偏差上界是解析证明，它是本输入域下的实测界。
// RETIRE_WHEN: 出现 HALF 粒度的 ACC->VRF 导出或 HALF MUL/MAC 后，用无损单次舍入
//        的可分离映射替换本测试，并把偏差比较改为两种实现之间的对比。

#include "Vsimd_datapath.h"
#include "verilated.h"
#include "vsp_image_io.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <random>
#include <string>
#include <vector>

namespace {

constexpr unsigned kLanes = 4;

constexpr uint8_t kMulU = 0x16;
constexpr uint8_t kMacU = 0x18;
constexpr uint8_t kPassA = 0x1a;
constexpr uint8_t kNclipU = 0x24;

constexpr uint8_t kRouteGather = 0;
constexpr uint8_t kRouteSlideUp = 2;
constexpr uint8_t kRouteSlideDown = 3;

// Driver-local allocation. Pass one needs a single source row; pass two needs
// the three horizontally filtered rows.
constexpr uint8_t kRowA = 0;
constexpr uint8_t kRowB = 1;
constexpr uint8_t kRowC = 2;
constexpr uint8_t kOutput = 11;
constexpr uint8_t kAccumulator = 0;
constexpr uint8_t kTailMask = 0;

constexpr unsigned kOpsPerPass = 4;

using vsp_image::Deviation;
using vsp_image::Image;
using vsp_image::pattern_checkerboard;
using vsp_image::pattern_flat;
using vsp_image::pattern_impulse;
using vsp_image::pattern_noise;
using vsp_image::pattern_ramp;
using vsp_image::pattern_step;
using vsp_image::pattern_zone_plate;
using vsp_image::read_pgm;

struct Stats {
  uint64_t images = 0;
  uint64_t pixels = 0;
  uint64_t horizontal_blocks = 0;
  uint64_t vertical_blocks = 0;
  uint64_t micro_ops = 0;
  Deviation deviation;
};

uint32_t pack8(const std::array<uint8_t, kLanes>& lanes) {
  uint32_t packed = 0;
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    packed |= static_cast<uint32_t>(lanes[lane]) << (lane * 8);
  }
  return packed;
}

std::array<uint8_t, kLanes> unpack8(uint32_t packed) {
  std::array<uint8_t, kLanes> lanes{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    lanes[lane] = static_cast<uint8_t>(packed >> (lane * 8));
  }
  return lanes;
}

void tick(Vsimd_datapath& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

[[noreturn]] void fail(const char* message) {
  std::cerr << "FAIL: " << message << '\n';
  std::exit(1);
}

void clear_controls(Vsimd_datapath& dut) {
  dut.issue_i = 0;
  dut.elem_mode_i = 0;
  dut.op_i = kPassA;
  dut.src_a_addr_i = 0;
  dut.src_b_addr_i = 0;
  dut.use_imm_i = 0;
  dut.imm_i = 0;
  dut.dst_vrf_addr_i = 0;
  dut.src_arf_addr_i = 0;
  dut.dst_arf_addr_i = 0;
  dut.mask_enable_i = 0;
  dut.exec_mask_addr_i = 0;
  dut.select_mask_addr_i = 0;
  dut.dst_mrf_addr_i = 0;
  dut.write_vrf_i = 0;
  dut.write_arf_i = 0;
  dut.write_mrf_i = 0;
  dut.reduce_enable_i = 0;
  dut.reduce_op_i = 0;

  dut.route_enable_i = 0;
  dut.route_op_i = kRouteGather;
  dut.route_index_i = 0;
  dut.route_broadcast_index_i = 0;
  dut.route_slide_amount_i = 0;
  dut.route_lower_i = 0;
  dut.route_upper_i = 0;

  dut.cfg_vrf_write_i = 0;
  dut.cfg_vrf_addr_i = 0;
  dut.cfg_vrf_mask_i = 0;
  dut.cfg_vrf_data_i = 0;
  dut.cfg_arf_write_i = 0;
  dut.cfg_arf_addr_i = 0;
  dut.cfg_arf_mask_i = 0;
  for (unsigned word = 0; word < 4; ++word) dut.cfg_arf_data_i[word] = 0;
  dut.cfg_mrf_write_i = 0;
  dut.cfg_mrf_addr_i = 0;
  dut.cfg_mrf_mask_i = 0;
  dut.cfg_mrf_data_i = 0;
}

void write_vrf(Vsimd_datapath& dut, uint8_t address,
               const std::array<uint8_t, kLanes>& data) {
  clear_controls(dut);
  dut.cfg_vrf_write_i = 1;
  dut.cfg_vrf_addr_i = address;
  dut.cfg_vrf_mask_i = 0xf;
  dut.cfg_vrf_data_i = pack8(data);
  tick(dut);
}

void write_mrf(Vsimd_datapath& dut, uint8_t address, uint8_t mask) {
  clear_controls(dut);
  dut.cfg_mrf_write_i = 1;
  dut.cfg_mrf_addr_i = address;
  dut.cfg_mrf_mask_i = 0xf;
  dut.cfg_mrf_data_i = mask;
  tick(dut);
}

std::array<uint8_t, kLanes> load_group(const Image& image, int y,
                                       int first_x) {
  std::array<uint8_t, kLanes> group{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    group[lane] = image.at(first_x + static_cast<int>(lane), y);
  }
  return group;
}

// One tap of a [1,2,1] pass. route_op selects the neighbour column; the centre
// tap needs no routing.
void issue_tap(Vsimd_datapath& dut, bool first_tap, uint8_t row_address,
               uint8_t coefficient, bool route_enable, uint8_t route_op,
               uint32_t route_lower, uint32_t route_upper) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = first_tap ? kMulU : kMacU;
  dut.src_a_addr_i = row_address;
  dut.use_imm_i = 1;
  dut.imm_i = coefficient;
  dut.src_arf_addr_i = kAccumulator;
  dut.dst_arf_addr_i = kAccumulator;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_arf_i = 1;
  dut.route_enable_i = route_enable ? 1 : 0;
  dut.route_op_i = route_op;
  dut.route_slide_amount_i = route_enable ? 1 : 0;
  dut.route_lower_i = route_lower;
  dut.route_upper_i = route_upper;
  dut.eval();
  if (dut.illegal_o) fail("legal separable tap was reported illegal");
  tick(dut);
}

// (accumulator + 2) >> 2. Both passes scale by four, so neither saturates.
void issue_narrow_down(Vsimd_datapath& dut) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kNclipU;
  dut.use_imm_i = 1;
  dut.imm_i = 2;
  dut.src_arf_addr_i = kAccumulator;
  dut.dst_vrf_addr_i = kOutput;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_vrf_i = 1;
  dut.eval();
  if (dut.illegal_o) fail("legal separable narrowing was reported illegal");
  tick(dut);
}

std::array<uint8_t, kLanes> read_vrf(Vsimd_datapath& dut, uint8_t address) {
  clear_controls(dut);
  dut.op_i = kPassA;
  dut.src_a_addr_i = address;
  dut.eval();
  return unpack8(dut.narrow_result_o);
}

uint8_t tail_mask_for(int width, int first_x) {
  const unsigned active =
      std::min<unsigned>(kLanes, static_cast<unsigned>(width - first_x));
  return static_cast<uint8_t>((1u << active) - 1u);
}

// Pass one: horizontal [1,2,1] over the source image. The result is kept in
// the driver, standing in for a line buffer the hardware does not have yet.
Image run_horizontal(Vsimd_datapath& dut, const Image& source, Stats& stats) {
  Image intermediate;
  intermediate.width = source.width;
  intermediate.height = source.height;
  intermediate.pixels.assign(source.pixels.size(), 0);

  for (int y = 0; y < source.height; ++y) {
    for (int first_x = 0; first_x < source.width;
         first_x += static_cast<int>(kLanes)) {
      const uint32_t lower =
          pack8(load_group(source, y, first_x - static_cast<int>(kLanes)));
      const uint32_t centre = pack8(load_group(source, y, first_x));
      const uint32_t upper =
          pack8(load_group(source, y, first_x + static_cast<int>(kLanes)));

      write_vrf(dut, kRowA, unpack8(centre));
      write_mrf(dut, kTailMask, tail_mask_for(source.width, first_x));

      issue_tap(dut, true, kRowA, 1, true, kRouteSlideUp, lower, upper);
      issue_tap(dut, false, kRowA, 2, false, kRouteGather, lower, upper);
      issue_tap(dut, false, kRowA, 1, true, kRouteSlideDown, lower, upper);
      issue_narrow_down(dut);

      const auto result = read_vrf(dut, kOutput);
      const unsigned active = std::min<unsigned>(
          kLanes, static_cast<unsigned>(source.width - first_x));
      for (unsigned lane = 0; lane < active; ++lane) {
        intermediate.pixels[static_cast<size_t>(y * source.width + first_x +
                                                lane)] = result[lane];
      }

      ++stats.horizontal_blocks;
      stats.micro_ops += kOpsPerPass;
    }
  }

  return intermediate;
}

// Pass two: vertical [1,2,1] over the intermediate. Vertical neighbours are
// separate rows, so this pass needs no routing at all.
Image run_vertical(Vsimd_datapath& dut, const Image& intermediate,
                   Stats& stats) {
  Image output;
  output.width = intermediate.width;
  output.height = intermediate.height;
  output.pixels.assign(intermediate.pixels.size(), 0);

  for (int y = 0; y < intermediate.height; ++y) {
    for (int first_x = 0; first_x < intermediate.width;
         first_x += static_cast<int>(kLanes)) {
      write_vrf(dut, kRowA, load_group(intermediate, y - 1, first_x));
      write_vrf(dut, kRowB, load_group(intermediate, y, first_x));
      write_vrf(dut, kRowC, load_group(intermediate, y + 1, first_x));
      write_mrf(dut, kTailMask, tail_mask_for(intermediate.width, first_x));

      issue_tap(dut, true, kRowA, 1, false, kRouteGather, 0, 0);
      issue_tap(dut, false, kRowB, 2, false, kRouteGather, 0, 0);
      issue_tap(dut, false, kRowC, 1, false, kRouteGather, 0, 0);
      issue_narrow_down(dut);

      const auto result = read_vrf(dut, kOutput);
      const unsigned active = std::min<unsigned>(
          kLanes, static_cast<unsigned>(intermediate.width - first_x));
      for (unsigned lane = 0; lane < active; ++lane) {
        output.pixels[static_cast<size_t>(y * intermediate.width + first_x +
                                          lane)] = result[lane];
      }

      ++stats.vertical_blocks;
      stats.micro_ops += kOpsPerPass;
    }
  }

  return output;
}

// Oracle 1: the same two-rounding arithmetic, written independently of the
// micro-operation sequence. This checks the RTL, not the algorithm choice.
Image separable_reference(const Image& source) {
  Image intermediate;
  intermediate.width = source.width;
  intermediate.height = source.height;
  intermediate.pixels.assign(source.pixels.size(), 0);
  for (int y = 0; y < source.height; ++y) {
    for (int x = 0; x < source.width; ++x) {
      const unsigned sum = source.at(x - 1, y) + 2u * source.at(x, y) +
                           source.at(x + 1, y);
      intermediate.pixels[static_cast<size_t>(y * source.width + x)] =
          static_cast<uint8_t>((sum + 2u) >> 2);
    }
  }

  Image output;
  output.width = source.width;
  output.height = source.height;
  output.pixels.assign(source.pixels.size(), 0);
  for (int y = 0; y < source.height; ++y) {
    for (int x = 0; x < source.width; ++x) {
      const unsigned sum = intermediate.at(x, y - 1) +
                           2u * intermediate.at(x, y) +
                           intermediate.at(x, y + 1);
      output.pixels[static_cast<size_t>(y * source.width + x)] =
          static_cast<uint8_t>((sum + 2u) >> 2);
    }
  }
  return output;
}

// Oracle 2: exact nine-tap with a single final rounding. This is the accuracy
// yardstick, not a correctness oracle for the separable mapping.
Image exact_reference(const Image& source) {
  static const int weights[3][3] = {{1, 2, 1}, {2, 4, 2}, {1, 2, 1}};
  Image output;
  output.width = source.width;
  output.height = source.height;
  output.pixels.assign(source.pixels.size(), 0);
  for (int y = 0; y < source.height; ++y) {
    for (int x = 0; x < source.width; ++x) {
      unsigned sum = 0;
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
          sum += static_cast<unsigned>(weights[dy + 1][dx + 1]) *
                 source.at(x + dx, y + dy);
        }
      }
      output.pixels[static_cast<size_t>(y * source.width + x)] =
          static_cast<uint8_t>((sum + 8u) >> 4);
    }
  }
  return output;
}

// The two roundings can shift the pre-rounding value by at most half a step,
// so the final result can move by one. Two is a deliberately loose measured
// bound over the input domain below, not an analytic proof.
constexpr unsigned kDeviationBound = 2;

Image run_separable(Vsimd_datapath& dut, const Image& source, Stats& stats) {
  const Image intermediate = run_horizontal(dut, source, stats);
  return run_vertical(dut, intermediate, stats);
}

Deviation check_image(Vsimd_datapath& dut, const Image& source,
                     const char* label, Stats& stats,
                     Image* captured = nullptr) {
  const Image expected = separable_reference(source);
  const Image exact = exact_reference(source);
  const Image actual = run_separable(dut, source, stats);

  Deviation deviation;
  for (size_t index = 0; index < source.pixels.size(); ++index) {
    if (actual.pixels[index] != expected.pixels[index]) {
      std::cerr << "FAIL separable Gaussian pattern=" << label << " index="
                << index << " expected="
                << unsigned(expected.pixels[index]) << " actual="
                << unsigned(actual.pixels[index]) << '\n';
      std::exit(1);
    }
    deviation.accumulate(actual.pixels[index], exact.pixels[index]);
  }

  if (deviation.max_absolute > kDeviationBound) {
    std::cerr << "FAIL separable deviation pattern=" << label << " max="
              << deviation.max_absolute << " bound=" << kDeviationBound << '\n';
    std::exit(1);
  }

  ++stats.images;
  stats.pixels += source.pixels.size();
  stats.deviation.merge(deviation);
  if (captured != nullptr) *captured = actual;
  return deviation;
}

// 图样、PGM 读写与性质统计由 sim/vsp_image_io.h 提供，三个图像负载共用同一份定义。

void report(const char* label, const Deviation& deviation) {
  std::printf("  %-22s max=%u  mean=%.4f  differing=%.1f%%\n", label,
              deviation.max_absolute, deviation.mean(),
              deviation.differing_share());
}

// Dump mode collects one input/output pair per named pattern into a directory,
// alongside the shared properties.csv. It is not part of the regression.
void dump_patterns(Vsimd_datapath& dut, const std::string& directory,
                   Stats& stats) {
  vsp_image::Writer writer(directory, "gaussian_separable");
  std::mt19937 rng(0x9a555131u);

  struct Named {
    const char* name;
    Image image;
  };
  std::vector<Named> patterns;
  patterns.push_back({"ramp", pattern_ramp(64, 48)});
  patterns.push_back({"zone_plate", pattern_zone_plate(64, 48)});
  patterns.push_back({"step_diagonal", pattern_step(64, 48, 2)});
  patterns.push_back({"checker4", pattern_checkerboard(64, 48, 4)});
  patterns.push_back({"impulse", pattern_impulse(64, 48)});
  patterns.push_back({"noise", pattern_noise(64, 48, rng)});

  for (auto& pattern : patterns) {
    Image separable;
    const Deviation deviation =
        check_image(dut, pattern.image, pattern.name, stats, &separable);
    writer.emit(pattern.name, "input", pattern.image);
    writer.emit(pattern.name, "separable", separable, &deviation);
    writer.emit(pattern.name, "exact", exact_reference(pattern.image));
    report(pattern.name, deviation);
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_datapath dut;
  clear_controls(dut);

  Stats stats;

  // Optional manual modes, both outside the regression: --dump writes the
  // pattern suite to a directory, and a bare path filters one external PGM.
  if ((argc > 2) && (std::string(argv[1]) == "--dump")) {
    std::printf("separable [1,2,1] pattern dump -> %s\n", argv[2]);
    dump_patterns(dut, argv[2], stats);
    dut.final();
    return 0;
  }

  if (argc > 1) {
    Image source;
    if (!read_pgm(argv[1], source)) {
      fail("could not read an 8-bit binary PGM from the given path");
    }
    Image separable;
    const Deviation deviation =
        check_image(dut, source, argv[1], stats, &separable);
    const std::string base(argv[1]);
    vsp_image::write_pgm(base + ".separable.pgm", separable);
    vsp_image::write_pgm(base + ".exact.pgm", exact_reference(source));
    std::printf("PGM %dx%d, %llu micro-operations\n", source.width,
                source.height,
                static_cast<unsigned long long>(stats.micro_ops));
    report("external image", deviation);
    dut.final();
    return 0;
  }

  std::mt19937 rng(0x9a555131u);

  std::printf("separable [1,2,1] deviation from the exact nine-tap result:\n");

  const Deviation flat = check_image(dut, pattern_flat(9, 7, 200), "flat", stats);
  report("flat", flat);

  const Deviation ramp = check_image(dut, pattern_ramp(29, 11), "ramp", stats);
  report("horizontal ramp", ramp);

  const Deviation zone =
      check_image(dut, pattern_zone_plate(31, 19), "zone plate", stats);
  report("zone plate", zone);

  Deviation steps;
  for (int direction = 0; direction < 3; ++direction) {
    steps.merge(check_image(dut, pattern_step(14, 12, direction), "step",
                            stats));
  }
  report("step edges (3 dirs)", steps);

  Deviation checkers;
  for (const int period : {1, 2, 4}) {
    checkers.merge(check_image(dut, pattern_checkerboard(16, 12, period),
                              "checkerboard", stats));
  }
  report("checkerboard (1,2,4)", checkers);

  const Deviation impulse =
      check_image(dut, pattern_impulse(11, 9), "impulse", stats);
  report("impulse", impulse);

  Deviation noise;
  for (unsigned iteration = 0; iteration < 40; ++iteration) {
    noise.merge(check_image(dut, pattern_noise(23, 15, rng), "noise", stats));
  }
  report("uniform noise (40)", noise);

  // Random shapes cover tail masks, single-lane widths and the image borders.
  std::uniform_int_distribution<int> width_distribution(1, 31);
  std::uniform_int_distribution<int> height_distribution(1, 19);
  Deviation random_shapes;
  for (unsigned iteration = 0; iteration < 120; ++iteration) {
    const int width = width_distribution(rng);
    const int height = height_distribution(rng);
    random_shapes.merge(
        check_image(dut, pattern_noise(width, height, rng), "random", stats));
  }
  report("random shapes (120)", random_shapes);

  if (stats.deviation.max_absolute == 0) {
    fail("the separable mapping never deviated; the comparison is degenerate");
  }
  // Binary and step content agrees exactly with the nine-tap result by
  // symmetry, so mid-tone content is what must show the double rounding.
  if (noise.max_absolute == 0) {
    fail("mid-tone content produced no deviation; check the patterns");
  }

  dut.final();
  std::printf(
      "PASS: %llu separable Gaussian images, %llu pixels, %llu horizontal and "
      "%llu vertical SIMD4 blocks, %llu micro-operations; deviation from exact "
      "nine-tap max=%u within bound %u\n",
      static_cast<unsigned long long>(stats.images),
      static_cast<unsigned long long>(stats.pixels),
      static_cast<unsigned long long>(stats.horizontal_blocks),
      static_cast<unsigned long long>(stats.vertical_blocks),
      static_cast<unsigned long long>(stats.micro_ops),
      stats.deviation.max_absolute, kDeviationBound);
  return 0;
}
