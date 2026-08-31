// CLASS: Readability-first algorithm and image smoke regression.
// CLAIM: The current SIMD4 datapath can compose three small byte algorithms:
//        saturating brightness adjustment, strict binary thresholding, and
//        masked intensity summation. Directed boundaries and complete images,
//        including partial final groups, match scalar software references.
// SOURCE / QUESTION: Small algorithm examples should make basic datapath use
//        easier to understand and failures easier to localize than the larger
//        stencil workload regressions alone.
// ORACLE: Explicit directed tables plus scalar, per-pixel references that do
//        not reuse the SIMD operation sequence.
// ASSUMPTIONS: One four-lane group, BYTE elements, unsigned pixels, and a host
//        driver standing in for image tiling, instruction issue, and register
//        initialization.
// NON_CLAIMS: This does not exercise uword decode, multiple groups, memory,
//        or a complete image-processing program.
// RETIRE_WHEN: A comparably small program-level regression covers the same
//        algorithms through instruction fetch, memory, and result checking.

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

constexpr unsigned kLanes = 4;

constexpr uint8_t kAddSatU = 0x02;
constexpr uint8_t kCmpGtU = 0x13;
constexpr uint8_t kPassA = 0x1a;
constexpr uint8_t kSelect = 0x1b;
constexpr uint8_t kReduceSumU = 0;

constexpr uint8_t kInput = 0;
constexpr uint8_t kOutput = 1;
constexpr uint8_t kZero = 2;
constexpr uint8_t kWhite = 3;
constexpr uint8_t kPredicate = 0;
constexpr uint8_t kActiveLanes = 1;

using Pixels = std::array<uint8_t, kLanes>;
using vsp_image::Image;
using vsp_image::make_image;
using vsp_image::pattern_checkerboard;
using vsp_image::pattern_flat;
using vsp_image::pattern_noise;
using vsp_image::pattern_ramp;
using vsp_image::pattern_step;
using vsp_image::pattern_zone_plate;

struct BrightnessCase {
  const char* name;
  Pixels input;
  uint8_t increment;
  Pixels expected;
};

struct ThresholdCase {
  const char* name;
  Pixels input;
  uint8_t threshold;
  Pixels expected;
};

struct SumCase {
  const char* name;
  Pixels input;
  uint8_t mask;
  bool expected_valid;
  uint32_t expected;
};

struct ReductionResult {
  bool valid = false;
  uint32_t value = 0;
};

struct NamedImage {
  const char* name;
  Image image;
};

struct ImageStats {
  uint64_t images = 0;
  uint64_t pixels = 0;
  uint64_t blocks = 0;
  uint64_t micro_ops = 0;
};

uint32_t pack(const Pixels& pixels) {
  uint32_t value = 0;
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    value |= static_cast<uint32_t>(pixels[lane]) << (lane * 8);
  }
  return value;
}

Pixels unpack(uint32_t value) {
  Pixels pixels{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    pixels[lane] = static_cast<uint8_t>(value >> (lane * 8));
  }
  return pixels;
}

void tick(Vsimd_datapath& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_controls(Vsimd_datapath& dut) {
  dut.issue_i = 0;
  dut.op_i = kPassA;
  dut.elem_mode_i = 0;
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
  dut.route_op_i = 0;
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
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    dut.cfg_arf_data_i[lane] = 0;
  }
  dut.cfg_mrf_write_i = 0;
  dut.cfg_mrf_addr_i = 0;
  dut.cfg_mrf_mask_i = 0;
  dut.cfg_mrf_data_i = 0;
}

[[noreturn]] void fail_illegal(const char* algorithm, const char* test_case) {
  std::cerr << "FAIL: " << algorithm << '/' << test_case
            << " issued a legal operation but illegal_o was asserted\n";
  std::exit(1);
}

[[noreturn]] void fail_pixels(const char* algorithm, const char* test_case,
                              const Pixels& expected, const Pixels& actual) {
  std::cerr << "FAIL: " << algorithm << '/' << test_case << " expected={";
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    if (lane != 0) std::cerr << ',';
    std::cerr << unsigned(expected[lane]);
  }
  std::cerr << "} actual={";
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    if (lane != 0) std::cerr << ',';
    std::cerr << unsigned(actual[lane]);
  }
  std::cerr << "}\n";
  std::exit(1);
}

[[noreturn]] void fail_image_pixel(const char* algorithm,
                                   const char* image_name, int x, int y,
                                   unsigned expected, unsigned actual) {
  std::cerr << "FAIL: " << algorithm << '/' << image_name << " at (" << x
            << ',' << y << ") expected=" << expected << " actual=" << actual
            << '\n';
  std::exit(1);
}

void write_vrf(Vsimd_datapath& dut, uint8_t address, const Pixels& pixels) {
  clear_controls(dut);
  dut.cfg_vrf_write_i = 1;
  dut.cfg_vrf_addr_i = address;
  dut.cfg_vrf_mask_i = 0xf;
  dut.cfg_vrf_data_i = pack(pixels);
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

Pixels read_vrf(Vsimd_datapath& dut, uint8_t address) {
  clear_controls(dut);
  dut.op_i = kPassA;
  dut.src_a_addr_i = address;
  dut.eval();
  return unpack(dut.narrow_result_o);
}

Pixels execute_brightness(Vsimd_datapath& dut, const Pixels& input,
                          uint8_t increment, uint8_t active_mask,
                          const char* test_case) {
  write_vrf(dut, kInput, input);
  write_mrf(dut, kActiveLanes, active_mask);

  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kAddSatU;
  dut.src_a_addr_i = kInput;
  dut.use_imm_i = 1;
  dut.imm_i = increment;
  dut.dst_vrf_addr_i = kOutput;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kActiveLanes;
  dut.write_vrf_i = 1;
  dut.eval();
  if (dut.illegal_o) fail_illegal("brightness", test_case);
  tick(dut);

  return read_vrf(dut, kOutput);
}

Pixels execute_threshold(Vsimd_datapath& dut, const Pixels& input,
                         uint8_t threshold, uint8_t active_mask,
                         const char* test_case) {
  write_vrf(dut, kInput, input);
  write_vrf(dut, kZero, {0, 0, 0, 0});
  write_vrf(dut, kWhite, {255, 255, 255, 255});
  write_mrf(dut, kActiveLanes, active_mask);

  // First materialize (pixel > threshold) in an MRF row.
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kCmpGtU;
  dut.src_a_addr_i = kInput;
  dut.use_imm_i = 1;
  dut.imm_i = threshold;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kActiveLanes;
  dut.dst_mrf_addr_i = kPredicate;
  dut.write_mrf_i = 1;
  dut.eval();
  if (dut.illegal_o) fail_illegal("threshold", test_case);
  tick(dut);

  // Then select white for true lanes and zero for false lanes.
  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kSelect;
  dut.src_a_addr_i = kWhite;
  dut.src_b_addr_i = kZero;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kActiveLanes;
  dut.select_mask_addr_i = kPredicate;
  dut.dst_vrf_addr_i = kOutput;
  dut.write_vrf_i = 1;
  dut.eval();
  if (dut.illegal_o) fail_illegal("threshold", test_case);
  tick(dut);

  return read_vrf(dut, kOutput);
}

ReductionResult execute_sum(Vsimd_datapath& dut, const Pixels& input,
                            uint8_t active_mask, const char* test_case) {
  write_vrf(dut, kInput, input);
  write_mrf(dut, kActiveLanes, active_mask);

  clear_controls(dut);
  dut.issue_i = 1;
  dut.op_i = kPassA;
  dut.src_a_addr_i = kInput;
  dut.mask_enable_i = 1;
  dut.exec_mask_addr_i = kActiveLanes;
  dut.reduce_enable_i = 1;
  dut.reduce_op_i = kReduceSumU;
  dut.eval();

  if (dut.illegal_o) fail_illegal("masked_sum", test_case);
  return {bool(dut.reduce_valid_o), dut.reduce_value_o};
}

void run_directed_cases(Vsimd_datapath& dut) {
  const std::array<BrightnessCase, 3> brightness_cases{{
      {"ordinary", {0, 1, 100, 200}, 20, {20, 21, 120, 220}},
      {"saturation_boundary", {214, 215, 216, 255}, 40,
       {254, 255, 255, 255}},
      {"zero_increment", {0, 64, 128, 255}, 0, {0, 64, 128, 255}},
  }};
  for (const auto& test_case : brightness_cases) {
    const Pixels actual = execute_brightness(
        dut, test_case.input, test_case.increment, 0xf, test_case.name);
    if (actual != test_case.expected) {
      fail_pixels("brightness", test_case.name, test_case.expected, actual);
    }
  }

  const std::array<ThresholdCase, 3> threshold_cases{{
      {"strict_boundary", {0, 127, 128, 255}, 127, {0, 0, 255, 255}},
      {"zero_threshold", {0, 1, 254, 255}, 0, {0, 255, 255, 255}},
      {"maximum_threshold", {0, 127, 254, 255}, 255, {0, 0, 0, 0}},
  }};
  for (const auto& test_case : threshold_cases) {
    const Pixels actual = execute_threshold(
        dut, test_case.input, test_case.threshold, 0xf, test_case.name);
    if (actual != test_case.expected) {
      fail_pixels("threshold", test_case.name, test_case.expected, actual);
    }
  }

  const std::array<SumCase, 3> sum_cases{{
      {"all_lanes", {1, 2, 3, 250}, 0xf, true, 256},
      {"sparse_mask", {255, 10, 20, 30}, 0xa, true, 40},
      {"empty_mask", {1, 2, 3, 4}, 0x0, false, 0},
  }};
  for (const auto& test_case : sum_cases) {
    const ReductionResult actual =
        execute_sum(dut, test_case.input, test_case.mask, test_case.name);
    if (actual.valid != test_case.expected_valid ||
        actual.value != test_case.expected) {
      std::cerr << "FAIL: masked_sum/" << test_case.name
                << " expected_valid=" << test_case.expected_valid
                << " actual_valid=" << actual.valid
                << " expected=" << test_case.expected
                << " actual=" << actual.value << '\n';
      std::exit(1);
    }
  }
}

uint8_t brightness_reference(uint8_t pixel, uint8_t increment) {
  return static_cast<uint8_t>(
      std::min<unsigned>(255, unsigned(pixel) + unsigned(increment)));
}

uint8_t threshold_reference(uint8_t pixel, uint8_t threshold) {
  return pixel > threshold ? 255 : 0;
}

uint8_t active_mask_for(const Image& image, int first_x) {
  const unsigned active = std::min<unsigned>(
      kLanes, static_cast<unsigned>(image.width - first_x));
  return static_cast<uint8_t>((1u << active) - 1u);
}

Pixels load_block(const Image& image, int y, int first_x) {
  Pixels pixels{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    pixels[lane] = image.at(first_x + static_cast<int>(lane), y);
  }
  return pixels;
}

void check_image(Vsimd_datapath& dut, const NamedImage& source,
                 uint8_t increment, uint8_t threshold, ImageStats& stats,
                 vsp_image::Writer* writer = nullptr) {
  Image brightness = make_image(source.image.width, source.image.height);
  Image binary = make_image(source.image.width, source.image.height);
  uint64_t rtl_sum = 0;
  uint64_t reference_sum = 0;

  for (int y = 0; y < source.image.height; ++y) {
    for (int first_x = 0; first_x < source.image.width;
         first_x += static_cast<int>(kLanes)) {
      const Pixels input = load_block(source.image, y, first_x);
      const uint8_t active_mask = active_mask_for(source.image, first_x);
      const Pixels bright = execute_brightness(
          dut, input, increment, active_mask, source.name);
      const Pixels thresholded = execute_threshold(
          dut, input, threshold, active_mask, source.name);
      const ReductionResult partial_sum =
          execute_sum(dut, input, active_mask, source.name);

      if (!partial_sum.valid) {
        std::cerr << "FAIL: masked_sum/" << source.name
                  << " returned invalid for a non-empty image block\n";
        std::exit(1);
      }
      rtl_sum += partial_sum.value;

      for (unsigned lane = 0; lane < kLanes; ++lane) {
        if ((active_mask & (1u << lane)) == 0) continue;
        const int x = first_x + static_cast<int>(lane);
        const uint8_t expected_brightness =
            brightness_reference(input[lane], increment);
        const uint8_t expected_threshold =
            threshold_reference(input[lane], threshold);
        if (bright[lane] != expected_brightness) {
          fail_image_pixel("brightness", source.name, x, y,
                           expected_brightness, bright[lane]);
        }
        if (thresholded[lane] != expected_threshold) {
          fail_image_pixel("threshold", source.name, x, y,
                           expected_threshold, thresholded[lane]);
        }
        brightness.ref(x, y) = bright[lane];
        binary.ref(x, y) = thresholded[lane];
        reference_sum += input[lane];
      }

      ++stats.blocks;
      stats.micro_ops += 4;  // Brightness + compare/select + reduction.
    }
  }

  if (rtl_sum != reference_sum) {
    std::cerr << "FAIL: masked_sum/" << source.name
              << " expected=" << reference_sum << " actual=" << rtl_sum
              << '\n';
    std::exit(1);
  }

  ++stats.images;
  stats.pixels += source.image.size();
  if (writer != nullptr) {
    writer->emit(source.name, "input", source.image);
    writer->emit(source.name, "brightness", brightness);
    writer->emit(source.name, "threshold", binary);
  }
}

void run_image_regression(Vsimd_datapath& dut, ImageStats& stats) {
  std::mt19937 rng(0x53494d47u);
  std::vector<NamedImage> images;
  images.push_back({"flat", pattern_flat(1, 1, 250)});
  images.push_back({"ramp", pattern_ramp(13, 7)});
  images.push_back({"checker2", pattern_checkerboard(9, 5, 2)});
  images.push_back({"step_diagonal", pattern_step(10, 6, 2)});
  images.push_back({"zone_plate", pattern_zone_plate(17, 9)});
  images.push_back({"noise", pattern_noise(23, 11, rng)});

  for (const auto& image : images) {
    check_image(dut, image, 40, 127, stats);
  }
}

void dump_image_examples(Vsimd_datapath& dut, const char* directory,
                         ImageStats& stats) {
  std::mt19937 rng(0x44554d50u);
  std::vector<NamedImage> images;
  images.push_back({"ramp", pattern_ramp(64, 48)});
  images.push_back({"checker8", pattern_checkerboard(64, 48, 8)});
  images.push_back({"step_diagonal", pattern_step(64, 48, 2)});
  images.push_back({"zone_plate", pattern_zone_plate(64, 48)});
  images.push_back({"noise", pattern_noise(64, 48, rng)});

  vsp_image::Writer writer(directory, "simple_algorithms");
  for (const auto& image : images) {
    check_image(dut, image, 40, 127, stats, &writer);
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_datapath dut;
  clear_controls(dut);
  run_directed_cases(dut);

  ImageStats stats;
  if ((argc > 2) && (std::string(argv[1]) == "--dump")) {
    dump_image_examples(dut, argv[2], stats);
    dut.final();
    std::cout << "PASS: dumped " << stats.images << " checked image sets to "
              << argv[2] << '\n';
    return 0;
  }

  run_image_regression(dut, stats);
  dut.final();
  std::cout << "PASS: 9 directed cases and " << stats.images << " images, "
            << stats.pixels << " pixels, " << stats.blocks
            << " SIMD4 blocks, and " << stats.micro_ops
            << " issued micro-operations\n";
  return 0;
}
