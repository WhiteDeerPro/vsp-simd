#include "Vsimd_datapath.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>
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

constexpr uint8_t kRowAbove = 0;
constexpr uint8_t kRowCenter = 1;
constexpr uint8_t kRowBelow = 2;
constexpr uint8_t kOutput = 11;
constexpr uint8_t kAccumulator = 0;
constexpr uint8_t kTailMask = 0;

struct Stats {
  uint64_t images = 0;
  uint64_t pixels = 0;
  uint64_t blocks = 0;
  uint64_t micro_ops = 0;
};

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

uint8_t sample_zero_padded(const std::vector<uint8_t>& image, int width,
                           int height, int x, int y) {
  if (x < 0 || x >= width || y < 0 || y >= height) return 0;
  return image[static_cast<size_t>(y * width + x)];
}

std::array<uint8_t, kLanes> load_group(const std::vector<uint8_t>& image,
                                       int width, int height, int y,
                                       int first_x) {
  std::array<uint8_t, kLanes> group{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    group[lane] = sample_zero_padded(image, width, height,
                                     first_x + static_cast<int>(lane), y);
  }
  return group;
}

RowBlock load_row_block(const std::vector<uint8_t>& image, int width,
                        int height, int y, int first_x) {
  RowBlock row;
  row.lower = load_group(image, width, height, y,
                         first_x - static_cast<int>(kLanes));
  row.center = load_group(image, width, height, y, first_x);
  row.upper = load_group(image, width, height, y,
                         first_x + static_cast<int>(kLanes));
  return row;
}

void issue_product(Vsimd_datapath& dut, bool first_product,
                   uint8_t row_address, uint8_t coefficient,
                   bool route_enable, uint8_t route_op,
                   const RowBlock& row) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = first_product ? kMulU : kMacU;
  dut.src_a_addr_i = row_address;
  dut.use_imm_i = 1;
  dut.imm_i = coefficient;
  dut.src_arf_addr_i = kAccumulator;
  dut.dst_arf_addr_i = kAccumulator;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_arf_i = 1;

  dut.route_enable_i = route_enable;
  dut.route_op_i = route_op;
  dut.route_slide_amount_i = route_enable ? 1 : 0;
  dut.route_lower_i = pack8(row.lower);
  dut.route_upper_i = pack8(row.upper);
  dut.eval();

  if (dut.illegal_o) fail("legal Gaussian tap was reported illegal");
  if (route_enable && route_op == kRouteSlideUp &&
      dut.route_boundary_mask_o != 0x1) {
    fail("SLIDE_UP did not mark lane 0 as an adjacent-group delivery");
  }
  if (route_enable && route_op == kRouteSlideDown &&
      dut.route_boundary_mask_o != 0x8) {
    fail("SLIDE_DOWN did not mark lane 3 as an adjacent-group delivery");
  }
  tick(dut);
}

void issue_nclip(Vsimd_datapath& dut) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kNclipU;
  dut.use_imm_i = 1;
  dut.imm_i = 4;
  dut.src_arf_addr_i = kAccumulator;
  dut.dst_vrf_addr_i = kOutput;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_vrf_i = 1;
  dut.eval();
  if (dut.illegal_o) fail("Gaussian NCLIP was reported illegal");
  tick(dut);
}

std::array<uint8_t, kLanes> read_vrf(Vsimd_datapath& dut,
                                     uint8_t address) {
  clear_controls(dut);
  dut.op_i = kPassA;
  dut.src_a_addr_i = address;
  dut.eval();
  return unpack8(dut.narrow_result_o);
}

uint8_t gaussian_reference_pixel(const std::vector<uint8_t>& image,
                                 int width, int height, int x, int y) {
  constexpr int weights[3][3] = {
      {1, 2, 1},
      {2, 4, 2},
      {1, 2, 1},
  };

  unsigned sum = 0;
  for (int dy = -1; dy <= 1; ++dy) {
    for (int dx = -1; dx <= 1; ++dx) {
      sum += weights[dy + 1][dx + 1] *
             sample_zero_padded(image, width, height, x + dx, y + dy);
    }
  }
  return static_cast<uint8_t>((sum + 8) >> 4);
}

std::vector<uint8_t> gaussian_reference(const std::vector<uint8_t>& image,
                                        int width, int height) {
  std::vector<uint8_t> output(image.size());
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      output[static_cast<size_t>(y * width + x)] =
          gaussian_reference_pixel(image, width, height, x, y);
    }
  }
  return output;
}

std::vector<uint8_t> run_gaussian(Vsimd_datapath& dut,
                                  const std::vector<uint8_t>& image,
                                  int width, int height, Stats& stats) {
  std::vector<uint8_t> output(image.size());

  for (int y = 0; y < height; ++y) {
    for (int first_x = 0; first_x < width;
         first_x += static_cast<int>(kLanes)) {
      const RowBlock above =
          load_row_block(image, width, height, y - 1, first_x);
      const RowBlock center =
          load_row_block(image, width, height, y, first_x);
      const RowBlock below =
          load_row_block(image, width, height, y + 1, first_x);

      write_vrf(dut, kRowAbove, above.center);
      write_vrf(dut, kRowCenter, center.center);
      write_vrf(dut, kRowBelow, below.center);

      const unsigned active_lanes =
          std::min<unsigned>(kLanes, static_cast<unsigned>(width - first_x));
      const uint8_t tail_mask =
          static_cast<uint8_t>((1u << active_lanes) - 1u);
      write_mrf(dut, kTailMask, tail_mask);

      issue_product(dut, true, kRowAbove, 1, true,
                    kRouteSlideUp, above);
      issue_product(dut, false, kRowAbove, 2, false,
                    kRouteGather, above);
      issue_product(dut, false, kRowAbove, 1, true,
                    kRouteSlideDown, above);

      issue_product(dut, false, kRowCenter, 2, true,
                    kRouteSlideUp, center);
      issue_product(dut, false, kRowCenter, 4, false,
                    kRouteGather, center);
      issue_product(dut, false, kRowCenter, 2, true,
                    kRouteSlideDown, center);

      issue_product(dut, false, kRowBelow, 1, true,
                    kRouteSlideUp, below);
      issue_product(dut, false, kRowBelow, 2, false,
                    kRouteGather, below);
      issue_product(dut, false, kRowBelow, 1, true,
                    kRouteSlideDown, below);

      issue_nclip(dut);
      const auto result = read_vrf(dut, kOutput);
      for (unsigned lane = 0; lane < active_lanes; ++lane) {
        output[static_cast<size_t>(y * width + first_x + lane)] = result[lane];
      }

      ++stats.blocks;
      stats.micro_ops += 10;
    }
  }

  ++stats.images;
  stats.pixels += image.size();
  return output;
}

void check_image(Vsimd_datapath& dut, const std::vector<uint8_t>& image,
                 int width, int height, Stats& stats) {
  const auto expected = gaussian_reference(image, width, height);
  const auto actual = run_gaussian(dut, image, width, height, stats);
  for (size_t index = 0; index < image.size(); ++index) {
    if (actual[index] != expected[index]) {
      const int y = static_cast<int>(index) / width;
      const int x = static_cast<int>(index) % width;
      std::cerr << "FAIL Gaussian image=" << stats.images << " x=" << x
                << " y=" << y << " expected=" << unsigned(expected[index])
                << " actual=" << unsigned(actual[index]) << '\n';
      std::exit(1);
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_datapath dut;
  clear_controls(dut);

  Stats stats;

  check_image(dut, {0}, 1, 1, stats);
  check_image(dut, std::vector<uint8_t>(7 * 5, 255), 7, 5, stats);

  std::vector<uint8_t> impulse(9 * 7, 0);
  impulse[3 * 9 + 4] = 255;
  check_image(dut, impulse, 9, 7, stats);

  std::vector<uint8_t> ramp(13 * 4);
  for (size_t index = 0; index < ramp.size(); ++index) {
    ramp[index] = static_cast<uint8_t>((index * 37 + 11) & 0xff);
  }
  check_image(dut, ramp, 13, 4, stats);

  std::mt19937 rng(0x47555353u);
  std::uniform_int_distribution<int> width_distribution(1, 31);
  std::uniform_int_distribution<int> height_distribution(1, 19);
  for (unsigned iteration = 0; iteration < 250; ++iteration) {
    const int width = width_distribution(rng);
    const int height = height_distribution(rng);
    std::vector<uint8_t> image(static_cast<size_t>(width * height));
    for (auto& pixel : image) pixel = static_cast<uint8_t>(rng());
    check_image(dut, image, width, height, stats);
  }

  dut.final();
  std::cout << "PASS: " << stats.images << " zero-padded Gaussian images, "
            << stats.pixels << " pixels, " << stats.blocks
            << " SIMD4 blocks, and " << stats.micro_ops
            << " issued micro-operations\n";
  return 0;
}
