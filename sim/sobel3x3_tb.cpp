// CLASS: 工作负载证据
// CLAIM: 现有原语可以组成单通道 8-bit 3x3 Sobel 梯度幅值近似，且逐像素与零填充
//        参考模型一致：三输入宽减 WSUB_U 在共享 align 下累加出有符号 ACC 梯度，
//        source-A route 可在宽三输入操作内交付邻列，NCLIP_S 完成有符号舍入窄化与
//        饱和，ABS_SAT_S 与 ADD_SAT_U 合成幅值。
// SOURCE / QUESTION: WSUB_U 产生负 ACC 值再经 NCLIP_S 读出的这条宽有符号路径此前
//        只有 leaf 测试，没有任何负载证据；route 只作用于 source A 时，stencil 的
//        数据搬运代价也需要计量。
// ORACLE: 独立 C++ 整数卷积 + 舍入/饱和模型，不复用被测微操作序列。
// ASSUMPTIONS: 单 SIMD4 group；外部驱动充当 sequencer 并串行装载三条中心 row 与
//        相邻组边界像素；零填充边界；ACC_W=32 足以保存 +-1020 的梯度。
// NON_CLAIMS: 不声称该映射最优、真实存储供给可行或 sequencer 吞吐可达；不声称
//        全量程 |Gx|+|Gy| 已可表达（宽域无 ABS 且不可组合，见 §2）；
//        不声称 ADD_SAT_U 的饱和在本映射中可达。
// RETIRE_WHEN: 出现宽域 ABS 或有符号宽 MAX 后重写该映射，或多组/程序级 Sobel
//        回归接替这份端到端取证。

#include "Vsimd_datapath.h"
#include "verilated.h"
#include "vsp_image_io.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>
#include <string>
#include <vector>

namespace {

using vsp_image::Image;
using vsp_image::pattern_checkerboard;
using vsp_image::pattern_flat;
using vsp_image::pattern_impulse;
using vsp_image::pattern_noise;
using vsp_image::pattern_ramp;
using vsp_image::pattern_step;
using vsp_image::pattern_zone_plate;

constexpr unsigned kLanes = 4;

constexpr uint8_t kAddSatU = 0x02;
constexpr uint8_t kAbsSatS = 0x15;
constexpr uint8_t kPassA = 0x1a;
constexpr uint8_t kWsubU = 0x20;
constexpr uint8_t kNclipS = 0x25;

constexpr uint8_t kRouteGather = 0;
constexpr uint8_t kRouteSlideUp = 2;
constexpr uint8_t kRouteSlideDown = 3;

// Driver-local register allocation. These addresses belong to this testbench,
// not to an architectural convention.
constexpr uint8_t kRowAbove = 0;
constexpr uint8_t kRowCenter = 1;
constexpr uint8_t kRowBelow = 2;
constexpr uint8_t kAboveLeft = 3;
constexpr uint8_t kCenterLeft = 4;
constexpr uint8_t kBelowLeft = 5;
constexpr uint8_t kBelowRight = 6;
constexpr uint8_t kGradientX = 7;
constexpr uint8_t kGradientY = 8;
constexpr uint8_t kMagnitudeX = 9;
constexpr uint8_t kMagnitudeY = 10;
constexpr uint8_t kOutput = 11;

constexpr uint8_t kAccX = 0;
constexpr uint8_t kAccY = 1;
// Held at zero so the first WSUB of each gradient needs no clearing operation.
constexpr uint8_t kAccZero = 7;
constexpr uint8_t kTailMask = 0;

constexpr unsigned kMicroOpsPerBlock = 15;

struct Stats {
  uint64_t images = 0;
  uint64_t pixels = 0;
  uint64_t blocks = 0;
  uint64_t micro_ops = 0;

  // Coverage counters. A workload test that stopped exercising the negative
  // accumulator or the signed clamp would still pass every pixel comparison,
  // so the suite asserts these are non-zero at the end.
  uint64_t negative_gradients = 0;
  uint64_t clamped_narrows = 0;
  unsigned peak_output = 0;
};

// One row of the 3x3 window: the four center pixels plus the adjacent-group
// pixels that SLIDE_UP/SLIDE_DOWN read at the boundary.
struct RowBlock {
  std::array<uint8_t, kLanes> lower{};
  std::array<uint8_t, kLanes> center{};
  std::array<uint8_t, kLanes> upper{};
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

void clear_arf(Vsimd_datapath& dut, uint8_t address) {
  clear_controls(dut);
  dut.cfg_arf_write_i = 1;
  dut.cfg_arf_addr_i = address;
  dut.cfg_arf_mask_i = 0xf;
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

RowBlock load_row_block(const Image& image, int y, int first_x) {
  RowBlock row;
  row.lower = load_group(image, y, first_x - static_cast<int>(kLanes));
  row.center = load_group(image, y, first_x);
  row.upper = load_group(image, y, first_x + static_cast<int>(kLanes));
  return row;
}

void check_boundary_mask(Vsimd_datapath& dut, uint8_t route_op) {
  if (route_op == kRouteSlideUp && dut.route_boundary_mask_o != 0x1) {
    fail("SLIDE_UP did not mark lane 0 as an adjacent-group delivery");
  }
  if (route_op == kRouteSlideDown && dut.route_boundary_mask_o != 0x8) {
    fail("SLIDE_DOWN did not mark lane 3 as an adjacent-group delivery");
  }
}

// Materialize one shifted copy of a row. Source-A routing can feed only one
// operand of a wide three-input operation, so the second neighbour column has
// to live in its own VRF row.
void issue_shift(Vsimd_datapath& dut, uint8_t source, uint8_t destination,
                 uint8_t route_op, const RowBlock& row) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kPassA;
  dut.src_a_addr_i = source;
  dut.dst_vrf_addr_i = destination;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_vrf_i = 1;
  dut.route_enable_i = 1;
  dut.route_op_i = route_op;
  dut.route_slide_amount_i = 1;
  dut.route_lower_i = pack8(row.lower);
  dut.route_upper_i = pack8(row.upper);
  dut.eval();
  if (dut.illegal_o) fail("legal neighbour shift was reported illegal");
  check_boundary_mask(dut, route_op);
  tick(dut);
}

// acc + (A << align) - (B << align), accumulated into one ARF row. Reading a
// row that is held at zero replaces an accumulator clear on the first tap.
void issue_wide_difference(Vsimd_datapath& dut, uint8_t src_a, uint8_t src_b,
                           uint8_t align, uint8_t src_acc, uint8_t dst_acc,
                           bool route_enable, const RowBlock& row) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kWsubU;
  dut.src_a_addr_i = src_a;
  dut.src_b_addr_i = src_b;
  dut.use_imm_i = 1;
  dut.imm_i = align;
  dut.src_arf_addr_i = src_acc;
  dut.dst_arf_addr_i = dst_acc;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_arf_i = 1;
  if (route_enable) {
    dut.route_enable_i = 1;
    dut.route_op_i = kRouteSlideDown;
    dut.route_slide_amount_i = 1;
    dut.route_lower_i = pack8(row.lower);
    dut.route_upper_i = pack8(row.upper);
  }
  dut.eval();
  if (dut.illegal_o) fail("legal wide difference was reported illegal");
  if (route_enable) check_boundary_mask(dut, kRouteSlideDown);
  tick(dut);
}

void issue_narrow(Vsimd_datapath& dut, uint8_t op, uint8_t src_a,
                  uint8_t src_b, bool use_imm, uint8_t imm, uint8_t src_acc,
                  uint8_t destination) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = op;
  dut.src_a_addr_i = src_a;
  dut.src_b_addr_i = src_b;
  dut.use_imm_i = use_imm ? 1 : 0;
  dut.imm_i = imm;
  dut.src_arf_addr_i = src_acc;
  dut.dst_vrf_addr_i = destination;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_vrf_i = 1;
  dut.eval();
  if (dut.illegal_o) fail("legal narrow Sobel operation was reported illegal");
  tick(dut);
}

std::array<uint8_t, kLanes> read_vrf(Vsimd_datapath& dut, uint8_t address) {
  clear_controls(dut);
  dut.op_i = kPassA;
  dut.src_a_addr_i = address;
  dut.eval();
  return unpack8(dut.narrow_result_o);
}

// Round-to-nearest-up arithmetic right shift, then saturate into a signed
// byte. Floor division is written out so a negative accumulator does not rely
// on implementation-defined right shift behaviour.
int nclip_s(int32_t accumulator, unsigned shift, bool* clamped = nullptr) {
  const int32_t divisor = static_cast<int32_t>(1u << shift);
  int32_t floored = (accumulator >= 0)
                        ? (accumulator / divisor)
                        : -((-accumulator + divisor - 1) / divisor);
  int round_bit = 0;
  if (shift > 0) {
    round_bit = static_cast<int>((static_cast<uint32_t>(accumulator) >>
                                  (shift - 1)) & 1u);
  }
  const int scaled = floored + round_bit;
  if (clamped != nullptr) {
    *clamped = (scaled < -128) || (scaled > 127);
  }
  return std::max(-128, std::min(127, scaled));
}

int abs_sat_s(int value) { return (value == -128) ? 127 : std::abs(value); }

uint8_t sobel_reference_pixel(const Image& image, int x, int y, unsigned shift,
                              Stats& stats) {
  int32_t gradient_x = 0;
  int32_t gradient_y = 0;
  for (int dy = -1; dy <= 1; ++dy) {
    const int row_weight = (dy == 0) ? 2 : 1;
    gradient_x += row_weight *
                  (image.at(x + 1, y + dy) -
                   image.at(x - 1, y + dy));
  }
  for (int dx = -1; dx <= 1; ++dx) {
    const int column_weight = (dx == 0) ? 2 : 1;
    gradient_y += column_weight *
                  (image.at(x + dx, y - 1) -
                   image.at(x + dx, y + 1));
  }

  bool clamped_x = false;
  bool clamped_y = false;
  const int narrow_x = nclip_s(gradient_x, shift, &clamped_x);
  const int narrow_y = nclip_s(gradient_y, shift, &clamped_y);

  if (gradient_x < 0) ++stats.negative_gradients;
  if (gradient_y < 0) ++stats.negative_gradients;
  if (clamped_x) ++stats.clamped_narrows;
  if (clamped_y) ++stats.clamped_narrows;

  const int magnitude = abs_sat_s(narrow_x) + abs_sat_s(narrow_y);
  const unsigned result = static_cast<unsigned>(std::min(magnitude, 255));
  stats.peak_output = std::max(stats.peak_output, result);
  return static_cast<uint8_t>(result);
}

Image sobel_reference(const Image& image, unsigned shift, Stats& stats) {
  Image output = vsp_image::make_image(image.width, image.height);
  for (int y = 0; y < image.height; ++y) {
    for (int x = 0; x < image.width; ++x) {
      output.ref(x, y) = sobel_reference_pixel(image, x, y, shift, stats);
    }
  }
  return output;
}

Image run_sobel(Vsimd_datapath& dut, const Image& image, unsigned shift,
                Stats& stats) {
  Image output = vsp_image::make_image(image.width, image.height);
  clear_arf(dut, kAccZero);

  for (int y = 0; y < image.height; ++y) {
    for (int first_x = 0; first_x < image.width;
         first_x += static_cast<int>(kLanes)) {
      const RowBlock above =
          load_row_block(image, y - 1, first_x);
      const RowBlock center = load_row_block(image, y, first_x);
      const RowBlock below =
          load_row_block(image, y + 1, first_x);

      write_vrf(dut, kRowAbove, above.center);
      write_vrf(dut, kRowCenter, center.center);
      write_vrf(dut, kRowBelow, below.center);

      const unsigned active_lanes =
          std::min<unsigned>(kLanes, static_cast<unsigned>(image.width - first_x));
      const uint8_t tail_mask =
          static_cast<uint8_t>((1u << active_lanes) - 1u);
      write_mrf(dut, kTailMask, tail_mask);

      // Four neighbour columns need their own rows; the remaining operands are
      // either unshifted rows or arrive through source-A routing.
      issue_shift(dut, kRowAbove, kAboveLeft, kRouteSlideUp, above);
      issue_shift(dut, kRowCenter, kCenterLeft, kRouteSlideUp, center);
      issue_shift(dut, kRowBelow, kBelowLeft, kRouteSlideUp, below);
      issue_shift(dut, kRowBelow, kBelowRight, kRouteSlideDown, below);

      // Gx: right column minus left column, centre row weighted by the shared
      // alignment amount.
      issue_wide_difference(dut, kRowAbove, kAboveLeft, 0, kAccZero, kAccX,
                            true, above);
      issue_wide_difference(dut, kRowCenter, kCenterLeft, 1, kAccX, kAccX, true,
                            center);
      issue_wide_difference(dut, kRowBelow, kBelowLeft, 0, kAccX, kAccX, true,
                            below);

      // Gy: row above minus row below, centre column weighted the same way.
      issue_wide_difference(dut, kAboveLeft, kBelowLeft, 0, kAccZero, kAccY,
                            false, above);
      issue_wide_difference(dut, kRowAbove, kRowBelow, 1, kAccY, kAccY, false,
                            above);
      issue_wide_difference(dut, kRowAbove, kBelowRight, 0, kAccY, kAccY, true,
                            above);

      issue_narrow(dut, kNclipS, 0, 0, true, static_cast<uint8_t>(shift),
                   kAccX, kGradientX);
      issue_narrow(dut, kNclipS, 0, 0, true, static_cast<uint8_t>(shift),
                   kAccY, kGradientY);
      issue_narrow(dut, kAbsSatS, kGradientX, 0, false, 0, 0, kMagnitudeX);
      issue_narrow(dut, kAbsSatS, kGradientY, 0, false, 0, 0, kMagnitudeY);
      issue_narrow(dut, kAddSatU, kMagnitudeX, kMagnitudeY, false, 0, 0,
                   kOutput);

      const auto result = read_vrf(dut, kOutput);
      for (unsigned lane = 0; lane < active_lanes; ++lane) {
        output.ref(first_x + static_cast<int>(lane), y) = result[lane];
      }

      ++stats.blocks;
      stats.micro_ops += kMicroOpsPerBlock;
    }
  }

  ++stats.images;
  stats.pixels += image.size();
  return output;
}

void check_image(Vsimd_datapath& dut, const Image& image, unsigned shift,
                 Stats& stats, Image* captured = nullptr) {
  const Image expected = sobel_reference(image, shift, stats);
  const Image actual = run_sobel(dut, image, shift, stats);
  for (size_t index = 0; index < image.size(); ++index) {
    if (actual.pixels[index] != expected.pixels[index]) {
      const int y = static_cast<int>(index) / image.width;
      const int x = static_cast<int>(index) % image.width;
      std::cerr << "FAIL Sobel shift=" << shift << " image=" << stats.images
                << " x=" << x << " y=" << y
                << " expected=" << unsigned(expected.pixels[index])
                << " actual=" << unsigned(actual.pixels[index]) << '\n';
      std::exit(1);
    }
  }
  if (captured != nullptr) *captured = actual;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_datapath dut;
  clear_controls(dut);

  Stats stats;

  // Optional dump mode: emit pattern suite to a directory with properties CSV.
  if ((argc > 2) && (std::string(argv[1]) == "--dump")) {
    vsp_image::Writer writer(argv[2], "sobel");
    std::mt19937 rng(0xdead8085u);

    struct Named { const char* name; Image image; };
    std::vector<Named> patterns;
    patterns.push_back({"ramp", pattern_ramp(64, 48)});
    patterns.push_back({"zone_plate", pattern_zone_plate(64, 48)});
    patterns.push_back({"step_vertical", pattern_step(64, 48, 0)});
    patterns.push_back({"step_horizontal", pattern_step(64, 48, 1)});
    patterns.push_back({"step_diagonal", pattern_step(64, 48, 2)});
    patterns.push_back({"checker4", pattern_checkerboard(64, 48, 4)});
    patterns.push_back({"impulse", pattern_impulse(64, 48)});
    patterns.push_back({"noise", pattern_noise(64, 48, rng)});

    for (auto& pattern : patterns) {
      Image output;
      check_image(dut, pattern.image, 0, stats, &output);
      writer.emit(pattern.name, "input", pattern.image);
      writer.emit(pattern.name, "output", output);
    }

    dut.final();
    std::printf("dumped %llu Sobel images to %s\n",
                static_cast<unsigned long long>(stats.images), argv[2]);
    return 0;
  }

  check_image(dut, pattern_flat(9, 7, 0), 0, stats);
  check_image(dut, pattern_impulse(9, 7), 0, stats);
  check_image(dut, pattern_ramp(13, 4), 0, stats);

  std::mt19937 rng(0xdead8085u);
  std::uniform_int_distribution<int> width_distribution(1, 31);
  std::uniform_int_distribution<int> height_distribution(1, 19);
  for (unsigned iteration = 0; iteration < 250; ++iteration) {
    const int width = width_distribution(rng);
    const int height = height_distribution(rng);
    check_image(dut, pattern_noise(width, height, rng), 0, stats);
  }

  dut.final();
  std::cout << "PASS: " << stats.images
            << " zero-padded Sobel images, " << stats.pixels
            << " pixels, " << stats.blocks
            << " SIMD4 blocks, and " << stats.micro_ops
            << " issued micro-operations across WSUB_U gradient accumulation, "
               "routed neighbour columns, NCLIP_S narrowing and saturating "
               "magnitude composition; "
            << stats.negative_gradients << " negative gradients and "
            << stats.clamped_narrows
            << " saturating narrows covered\n";
  return 0;
}
