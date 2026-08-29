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
using vsp_image::pattern_salt_pepper;
using vsp_image::pattern_step;
using vsp_image::pattern_zone_plate;

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

uint8_t gaussian_reference_pixel(const Image& image, int x, int y) {
  constexpr int weights[3][3] = {
      {1, 2, 1},
      {2, 4, 2},
      {1, 2, 1},
  };

  unsigned sum = 0;
  for (int dy = -1; dy <= 1; ++dy) {
    for (int dx = -1; dx <= 1; ++dx) {
      sum += weights[dy + 1][dx + 1] * image.at(x + dx, y + dy);
    }
  }
  return static_cast<uint8_t>((sum + 8) >> 4);
}

Image gaussian_reference(const Image& image) {
  Image output = vsp_image::make_image(image.width, image.height);
  for (int y = 0; y < image.height; ++y) {
    for (int x = 0; x < image.width; ++x) {
      output.ref(x, y) = gaussian_reference_pixel(image, x, y);
    }
  }
  return output;
}

Image run_gaussian(Vsimd_datapath& dut, const Image& image, Stats& stats) {
  Image output = vsp_image::make_image(image.width, image.height);

  for (int y = 0; y < image.height; ++y) {
    for (int first_x = 0; first_x < image.width;
         first_x += static_cast<int>(kLanes)) {
      const RowBlock above =
          load_row_block(image, y - 1, first_x);
      const RowBlock center =
          load_row_block(image, y, first_x);
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
        output.ref(first_x + static_cast<int>(lane), y) = result[lane];
      }

      ++stats.blocks;
      stats.micro_ops += 10;
    }
  }

  ++stats.images;
  stats.pixels += image.size();
  return output;
}

void check_image(Vsimd_datapath& dut, const Image& image, Stats& stats,
                 Image* captured = nullptr) {
  const Image expected = gaussian_reference(image);
  const Image actual = run_gaussian(dut, image, stats);
  for (size_t index = 0; index < image.size(); ++index) {
    if (actual.pixels[index] != expected.pixels[index]) {
      const int y = static_cast<int>(index) / image.width;
      const int x = static_cast<int>(index) % image.width;
      std::cerr << "FAIL Gaussian image=" << stats.images << " x=" << x
                << " y=" << y << " expected=" << unsigned(expected.pixels[index])
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
    vsp_image::Writer writer(argv[2], "gaussian");
    std::mt19937 rng(0x47555353u);

    struct Named { const char* name; Image image; };
    std::vector<Named> patterns;
    patterns.push_back({"ramp", pattern_ramp(64, 48)});
    patterns.push_back({"zone_plate", pattern_zone_plate(64, 48)});
    patterns.push_back({"step_diagonal", pattern_step(64, 48, 2)});
    patterns.push_back({"checker4", pattern_checkerboard(64, 48, 4)});
    patterns.push_back({"impulse", pattern_impulse(64, 48)});
    patterns.push_back({"noise", pattern_noise(64, 48, rng)});
    patterns.push_back({"salt_pepper_10", pattern_salt_pepper(64, 48, 10, rng)});

    for (auto& pattern : patterns) {
      Image output;
      check_image(dut, pattern.image, stats, &output);
      writer.emit(pattern.name, "input", pattern.image);
      writer.emit(pattern.name, "output", output);
    }

    dut.final();
    std::printf("dumped %llu Gaussian images to %s\n",
                static_cast<unsigned long long>(stats.images), argv[2]);
    return 0;
  }

  check_image(dut, pattern_flat(9, 7, 0), stats);
  check_image(dut, pattern_impulse(9, 7), stats);
  check_image(dut, pattern_ramp(13, 4), stats);

  std::mt19937 rng(0x47555353u);
  std::uniform_int_distribution<int> width_distribution(1, 31);
  std::uniform_int_distribution<int> height_distribution(1, 19);
  for (unsigned iteration = 0; iteration < 250; ++iteration) {
    const int width = width_distribution(rng);
    const int height = height_distribution(rng);
    check_image(dut, pattern_noise(width, height, rng), stats);
  }

  dut.final();
  std::cout << "PASS: " << stats.images << " zero-padded Gaussian images, "
            << stats.pixels << " pixels, " << stats.blocks
            << " SIMD4 blocks, and " << stats.micro_ops
            << " issued micro-operations\n";
  return 0;
}
