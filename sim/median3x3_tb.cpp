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

constexpr uint8_t kMinU = 0x06;
constexpr uint8_t kMaxU = 0x07;
constexpr uint8_t kPassA = 0x1a;
constexpr uint8_t kRouteGather = 0;

constexpr uint8_t kTailMask = 0;

// VRF addresses for the 3×3 window and intermediate results
constexpr uint8_t kP0 = 0;
constexpr uint8_t kP1 = 1;
constexpr uint8_t kP2 = 2;
constexpr uint8_t kP3 = 3;
constexpr uint8_t kP4 = 4;
constexpr uint8_t kP5 = 5;
constexpr uint8_t kP6 = 6;
constexpr uint8_t kP7 = 7;
constexpr uint8_t kP8 = 8;
constexpr uint8_t kTmp = 9;

// 19-comparator median-of-nine selection network.  It does not fully sort
// every output; after the final comparator, row p4 contains the fifth order
// statistic independently in each physical lane.
constexpr std::array<std::array<uint8_t, 2>, 19> kMedianPairs = {{
    {{1, 2}}, {{4, 5}}, {{7, 8}},
    {{0, 1}}, {{3, 4}}, {{6, 7}},
    {{1, 2}}, {{4, 5}}, {{7, 8}},
    {{0, 3}}, {{5, 8}}, {{4, 7}},
    {{3, 6}}, {{1, 4}}, {{2, 5}},
    {{4, 7}}, {{4, 2}}, {{6, 4}}, {{4, 2}},
}};

struct Stats {
  uint64_t images = 0;
  uint64_t pixels = 0;
  uint64_t blocks = 0;
  uint64_t micro_ops = 0;
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
  dut.src_arf_addr_i = 0;
  dut.dst_arf_addr_i = 0;
  dut.dst_vrf_addr_i = 0;
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
  dut.eval();
}

void write_vrf(Vsimd_datapath& dut, uint8_t address,
               const std::array<uint8_t, kLanes>& lanes) {
  clear_controls(dut);
  dut.cfg_vrf_write_i = 1;
  dut.cfg_vrf_addr_i = address;
  dut.cfg_vrf_mask_i = 0xf;
  dut.cfg_vrf_data_i = pack8(lanes);
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

std::array<uint8_t, kLanes> read_vrf(Vsimd_datapath& dut, uint8_t address) {
  clear_controls(dut);
  dut.op_i = kPassA;
  dut.src_a_addr_i = address;
  dut.eval();
  return unpack8(dut.narrow_result_o);
}

// Issue one masked VRF operation and hold issue_i through the active edge.
void issue_vrf(Vsimd_datapath& dut, uint8_t op, uint8_t src_a,
               uint8_t src_b, uint8_t dst) {
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = op;
  dut.src_a_addr_i = src_a;
  dut.src_b_addr_i = src_b;
  dut.dst_vrf_addr_i = dst;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kTailMask;
  dut.write_vrf_i = 1;
  dut.eval();
  if (dut.illegal_o) fail("legal median-network operation was reported illegal");
  tick(dut);
  clear_controls(dut);
}

// Reference median filter
Image median_reference(const Image& image) {
  Image output = vsp_image::make_image(image.width, image.height);
  for (int y = 0; y < image.height; ++y) {
    for (int x = 0; x < image.width; ++x) {
      std::array<uint8_t, 9> window;
      int idx = 0;
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
          window[idx++] = image.at(x + dx, y + dy);
        }
      }
      std::nth_element(window.begin(), window.begin() + 4, window.end());
      output.ref(x, y) = window[4];
    }
  }
  return output;
}

void verify_median_network() {
  std::array<uint8_t, 9> values = {{0, 1, 2, 3, 4, 5, 6, 7, 8}};
  uint64_t permutations = 0;
  do {
    auto routed = values;
    for (const auto& pair : kMedianPairs) {
      if (routed[pair[0]] > routed[pair[1]])
        std::swap(routed[pair[0]], routed[pair[1]]);
    }
    if (routed[4] != 4) fail("median selection network proof failed");
    ++permutations;
  } while (std::next_permutation(values.begin(), values.end()));
  if (permutations != 362880)
    fail("median selection network did not cover every rank permutation");
}

// Run the same selection network lane-wise.  With one narrow VRF write port,
// an in-place compare-exchange takes three EXEC operations:
//   MAX(a,b)->tmp; MIN(a,b)->a; PASS_A(tmp)->b.
void median_network(Vsimd_datapath& dut) {
  auto sort_pair = [&](uint8_t a, uint8_t b) {
    issue_vrf(dut, kMaxU, a, b, kTmp);
    issue_vrf(dut, kMinU, a, b, a);
    issue_vrf(dut, kPassA, kTmp, 0, b);
  };

  for (const auto& pair : kMedianPairs)
    sort_pair(static_cast<uint8_t>(kP0 + pair[0]),
              static_cast<uint8_t>(kP0 + pair[1]));
}

Image run_median(Vsimd_datapath& dut, const Image& image, Stats& stats) {
  Image output = vsp_image::make_image(image.width, image.height);

  for (int y = 0; y < image.height; ++y) {
    for (int first_x = 0; first_x < image.width;
         first_x += static_cast<int>(kLanes)) {
      // Load 3×3 window
      std::array<std::array<uint8_t, kLanes>, 9> window;
      for (int idx = 0; idx < 9; ++idx) {
        const int dy = (idx / 3) - 1;
        const int dx = (idx % 3) - 1;
        for (unsigned lane = 0; lane < kLanes; ++lane) {
          const int x = first_x + static_cast<int>(lane);
          window[idx][lane] = image.at(x + dx, y + dy);
        }
      }

      // Every compare-exchange uses the tail mask; inactive physical lanes do
      // not perturb the four independent output-pixel streams.
      const unsigned active_lanes = std::min<unsigned>(
          kLanes, static_cast<unsigned>(image.width - first_x));
      const uint8_t tail_mask = static_cast<uint8_t>((1u << active_lanes) - 1u);
      write_mrf(dut, kTailMask, tail_mask);

      // Write window to VRF
      for (int idx = 0; idx < 9; ++idx) {
        write_vrf(dut, kP0 + idx, window[idx]);
      }

      // Run median selection network
      median_network(dut);

      // p4 is already a legal STORE source; no artificial cfg-port copy is
      // counted as program work.
      const auto result = read_vrf(dut, kP4);
      for (unsigned lane = 0; lane < active_lanes; ++lane) {
        output.ref(first_x + static_cast<int>(lane), y) = result[lane];
      }

      ++stats.blocks;
      stats.micro_ops += kMedianPairs.size() * 3;
    }
  }

  ++stats.images;
  stats.pixels += image.size();
  return output;
}

void check_image(Vsimd_datapath& dut, const Image& image, Stats& stats,
                 Image* captured = nullptr) {
  const Image expected = median_reference(image);
  const Image actual = run_median(dut, image, stats);

  for (size_t index = 0; index < image.size(); ++index) {
    if (actual.pixels[index] != expected.pixels[index]) {
      const int y = static_cast<int>(index) / image.width;
      const int x = static_cast<int>(index) % image.width;
      std::cerr << "FAIL Median image=" << stats.images << " x=" << x
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
  verify_median_network();
  Vsimd_datapath dut;
  clear_controls(dut);

  Stats stats;

  // Optional dump mode
  if ((argc > 2) && (std::string(argv[1]) == "--dump")) {
    vsp_image::Writer writer(argv[2], "median");
    std::mt19937 rng(0xfede3331u);

    struct Named { const char* name; Image image; };
    std::vector<Named> patterns;
    patterns.push_back({"impulse", pattern_impulse(64, 48)});
    patterns.push_back({"salt_pepper_5", pattern_salt_pepper(64, 48, 5, rng)});
    patterns.push_back({"salt_pepper_10", pattern_salt_pepper(64, 48, 10, rng)});
    patterns.push_back({"salt_pepper_20", pattern_salt_pepper(64, 48, 20, rng)});
    patterns.push_back({"noise", pattern_noise(64, 48, rng)});

    for (auto& pattern : patterns) {
      Image output;
      check_image(dut, pattern.image, stats, &output);
      writer.emit(pattern.name, "input", pattern.image);
      writer.emit(pattern.name, "output", output);
    }

    dut.final();
    std::printf("dumped %llu Median images to %s\n",
                static_cast<unsigned long long>(stats.images), argv[2]);
    return 0;
  }

  // Regression tests
  check_image(dut, pattern_flat(9, 7, 128), stats);
  check_image(dut, pattern_impulse(9, 7), stats);

  std::mt19937 rng(0xfede3331u);
  for (unsigned iteration = 0; iteration < 50; ++iteration) {
    std::uniform_int_distribution<int> width_dist(1, 31);
    std::uniform_int_distribution<int> height_dist(1, 19);
    const int width = width_dist(rng);
    const int height = height_dist(rng);
    check_image(dut, pattern_noise(width, height, rng), stats);
    check_image(dut, pattern_salt_pepper(width, height, 10, rng), stats);
  }

  dut.final();
  std::cout << "PASS: " << stats.images << " zero-padded Median images, "
            << stats.pixels << " pixels, " << stats.blocks
            << " SIMD4 blocks, and " << stats.micro_ops
            << " issued micro-operations\n";
  return 0;
}
