// SPDX-License-Identifier: MIT

#include "Vvsp_uword_memory_system_wrapper_tb_top.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <locale>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Dut = Vvsp_uword_memory_system_wrapper_tb_top;

constexpr std::uint32_t kProgramBase = 0x0020;
constexpr std::uint32_t kDataBase = 0x1000;
constexpr std::uint32_t kRealBase = 0x1000;
constexpr std::uint32_t kImagBase = 0x1040;
constexpr std::uint32_t kBfpExponentInBase = 0x1360;
constexpr std::uint32_t kBfpExponentOutBase = 0x1370;
constexpr std::size_t kFftPoints = 64;
constexpr std::size_t kGoldenWords = 2 * kFftPoints / 4;
constexpr std::uint64_t kExpectedActions = 449;
constexpr int kFftStages = 6;
constexpr std::uint8_t kAddrSpacePhysical = 1;
constexpr std::uint8_t kActionStatusOk = 0;
constexpr std::uint8_t kMemoryStatusOk = 0;
constexpr std::uint8_t kFaultNone = 0;

struct FftOutputWords {
  std::array<std::uint32_t, kFftPoints / 4> real{};
  std::array<std::uint32_t, kFftPoints / 4> imag{};
};

std::uint64_t checks = 0;
std::uint64_t cycles = 0;
std::uint64_t sim_time = 0;
std::uint64_t completions = 0;
std::uint64_t icache_hits = 0;
std::uint64_t icache_misses = 0;
std::uint64_t dcache_read_hits = 0;
std::uint64_t dcache_read_misses = 0;
std::uint64_t dcache_write_hits = 0;
std::uint64_t dcache_write_misses = 0;
VerilatedVcdC* trace = nullptr;

[[noreturn]] void fail(const std::string& label, std::uint64_t expected,
                       std::uint64_t actual) {
  std::cerr << "FAIL " << label << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << std::dec << '\n';
  std::exit(EXIT_FAILURE);
}

void expect_eq(const std::string& label, std::uint64_t expected,
               std::uint64_t actual) {
  ++checks;
  if (expected != actual) fail(label, expected, actual);
}

void expect_true(const std::string& label, bool value) {
  expect_eq(label, 1, value ? 1 : 0);
}

void evaluate(Dut& dut) {
  dut.eval();
  if (trace != nullptr) trace->dump(sim_time);
  ++sim_time;
}

void sample_completion(const Dut& dut) {
  if (dut.action_cpl_valid_o && dut.action_cpl_ready_i) {
    ++completions;
    expect_eq("retired action status", kActionStatusOk,
              dut.action_cpl_status_o);
    if (dut.action_cpl_class_o == 1) {
      expect_eq("retired memory status", kMemoryStatusOk,
                dut.action_cpl_memory_status_o);
      expect_eq("retired memory fault", kFaultNone,
                dut.action_cpl_memory_fault_cause_o);
      expect_eq("retired memory failed mask", 0,
                dut.action_cpl_memory_failed_group_mask_o);
      expect_eq("retired memory is not partial", 0,
                dut.action_cpl_memory_partial_o);
    }
  }
}

void sample_performance(const Dut& dut) {
  icache_hits += dut.perf_icache_read_hit_o != 0;
  icache_misses += dut.perf_icache_read_miss_o != 0;
  dcache_read_hits += dut.perf_dcache_read_hit_o != 0;
  dcache_read_misses += dut.perf_dcache_read_miss_o != 0;
  dcache_write_hits += dut.perf_dcache_write_hit_o != 0;
  dcache_write_misses += dut.perf_dcache_write_miss_o != 0;
}

void eval_low(Dut& dut) {
  dut.clk_i = 0;
  evaluate(dut);
}

void tick(Dut& dut) {
  dut.clk_i = 0;
  evaluate(dut);
  sample_completion(dut);
  dut.clk_i = 1;
  evaluate(dut);
  sample_performance(dut);
  ++cycles;
  dut.clk_i = 0;
  evaluate(dut);
}

template <typename Predicate>
void wait_for(Dut& dut, Predicate predicate, const std::string& label,
              unsigned limit = 2000000) {
  for (unsigned waited = 0; waited < limit; ++waited) {
    eval_low(dut);
    if (predicate()) return;
    tick(dut);
  }
  std::cerr << "FAIL timeout waiting for " << label << '\n';
  std::exit(EXIT_FAILURE);
}

std::vector<std::uint32_t> read_hex_words(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot open hex image: " + path);
  std::vector<std::uint32_t> words;
  std::string line;
  while (std::getline(input, line)) {
    if (!line.empty()) {
      words.push_back(
          static_cast<std::uint32_t>(std::stoul(line, nullptr, 16)));
    }
  }
  return words;
}

std::uint64_t parse_positive_integer(const char* text_value,
                                     const std::string& label) {
  if (text_value == nullptr || text_value[0] == '\0') {
    throw std::runtime_error(label + " is empty");
  }
  for (const char* character = text_value; *character != '\0'; ++character) {
    if (*character < '0' || *character > '9') {
      throw std::runtime_error(label + " must be a positive integer");
    }
  }
  std::size_t parsed = 0;
  std::uint64_t value = 0;
  try {
    value = std::stoull(text_value, &parsed, 10);
  } catch (const std::exception&) {
    throw std::runtime_error(label + " must be a positive integer");
  }
  if (parsed != std::string(text_value).size() || value == 0) {
    throw std::runtime_error(label + " must be a positive integer");
  }
  return value;
}

void clear_inputs(Dut& dut) {
  dut.start_valid_i = 0;
  dut.start_pc_i = 0;
  dut.end_pc_i = 0;
  dut.start_context_i = 0;
  dut.start_group_mask_i = 0;
  dut.start_tag_seed_i = 0;
  dut.start_ifetch_addr_space_i = kAddrSpacePhysical;
  dut.start_ifetch_addr_context_i = 0;
  dut.action_cpl_ready_i = 1;

  dut.mmu_cfg_valid_i = 0;
  dut.mmu_cfg_write_i = 0;
  dut.mmu_cfg_context_i = 0;
  dut.mmu_cfg_field_i = 0;
  dut.mmu_cfg_wdata_i = 0;
  dut.mmu_cfg_rsp_ready_i = 1;

  dut.maint_cmd_valid_i = 0;
  dut.maint_cmd_op_i = 0;
  dut.maint_cmd_eaddr_i = 0;
  dut.maint_cmd_paddr_i = 0;
  dut.maint_cmd_addr_context_i = 0;
  dut.maint_cmd_asid_i = 0;
  dut.maint_cpl_ready_i = 1;

  dut.backing_init_valid_i = 0;
  dut.backing_init_paddr_i = 0;
  dut.backing_init_wdata_i = 0;
  dut.backing_init_wstrb_i = 0;
  dut.backing_peek_paddr_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Dut& dut, std::size_t program_words) {
  clear_inputs(dut);
  dut.start_pc_i = kProgramBase;
  dut.end_pc_i = kProgramBase + 4 * program_words;
  dut.start_group_mask_i = 0xf;
  dut.start_ifetch_addr_context_i = 0x5a;
  dut.rst_ni = 0;
  for (unsigned count = 0; count < 3; ++count) tick(dut);
  expect_eq("reset blocks launch", 0, dut.start_ready_o);
  expect_eq("reset clears protocol error", 0, dut.protocol_error_o);

  dut.rst_ni = 1;
  wait_for(dut,
           [&dut]() {
             return dut.system_ready_o && dut.system_quiescent_o &&
                    dut.start_ready_o;
           },
           "I-cache, D-cache, MMU and backing SRAM initialization");
  expect_eq("I-cache initialized", 1, dut.icache_init_done_o);
  expect_eq("D-cache initialized", 1, dut.dcache_init_done_o);
  expect_eq("MMU initialized", 1, dut.mmu_init_done_o);
}

void init_word(Dut& dut, std::uint32_t address, std::uint32_t value) {
  dut.backing_init_paddr_i = address;
  dut.backing_init_wdata_i = value;
  dut.backing_init_wstrb_i = 0xf;
  dut.backing_init_valid_i = 1;
  wait_for(dut, [&dut]() { return dut.backing_init_ready_o != 0; },
           "backing SRAM initialization port");
  expect_eq("backing SRAM initialization address", 0,
            dut.backing_init_error_o);
  tick(dut);
  dut.backing_init_valid_i = 0;
}

void install_image(Dut& dut, const std::vector<std::uint32_t>& program,
                   const std::vector<std::uint32_t>& data) {
  for (std::size_t index = 0; index < program.size(); ++index) {
    init_word(dut, kProgramBase + 4 * index, program[index]);
  }
  for (std::size_t index = 0; index < data.size(); ++index) {
    init_word(dut, kDataBase + 4 * index, data[index]);
  }
  expect_eq("image installation bypasses transaction accounting", 0,
            dut.lower_req_count_o);
}

void launch(Dut& dut, std::size_t program_words) {
  wait_for(dut, [&dut]() { return dut.start_ready_o != 0; },
           "program launch admission");
  dut.start_valid_i = 1;
  dut.start_pc_i = kProgramBase;
  dut.end_pc_i = kProgramBase + 4 * program_words;
  dut.start_context_i = 0;
  dut.start_group_mask_i = 0xf;
  dut.start_tag_seed_i = 0x20;
  dut.start_ifetch_addr_space_i = kAddrSpacePhysical;
  dut.start_ifetch_addr_context_i = 0x5a;
  eval_low(dut);
  expect_eq("program launch handshake", 1, dut.start_ready_o);
  tick(dut);
  dut.start_valid_i = 0;
}

void run_program(Dut& dut) {
  bool done = false;
  bool failed = false;
  for (unsigned waited = 0; waited < 2000000; ++waited) {
    eval_low(dut);
    done |= dut.program_done_o != 0;
    failed |= dut.program_failed_o != 0;
    if ((done || failed) && !dut.program_active_o) break;
    tick(dut);
    if (waited == 1999999) {
      std::cerr << "FAIL FFT program terminal timeout\n";
      std::exit(EXIT_FAILURE);
    }
  }
  expect_eq("FFT program completed", 1, done);
  expect_eq("FFT program did not fail", 0, failed);
  expect_eq("FFT program accumulated no architectural error", 0,
            dut.program_error_o);
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "post-FFT memory-system quiescence");
}

std::uint32_t peek_word(Dut& dut, std::uint32_t address) {
  dut.backing_peek_paddr_i = address;
  eval_low(dut);
  expect_eq("backing SRAM peek address", 0, dut.backing_peek_error_o);
  return static_cast<std::uint32_t>(dut.backing_peek_rdata_o);
}

std::int8_t byte_at(std::uint32_t word, unsigned lane) {
  return static_cast<std::int8_t>((word >> (8 * lane)) & 0xffU);
}

std::uint32_t replicated_byte_word(std::int8_t value) {
  return static_cast<std::uint32_t>(static_cast<std::uint8_t>(value)) *
         0x01010101U;
}

std::int8_t check_output(Dut& dut,
                         const std::vector<std::uint32_t>& golden,
                         std::int8_t input_exponent,
                         std::int8_t expected_output_exponent) {
  expect_eq("golden image size", kGoldenWords, golden.size());
  for (std::size_t index = 0; index < kFftPoints / 4; ++index) {
    expect_eq("FFT real word " + std::to_string(index), golden[index],
              peek_word(dut, kRealBase + 4 * index));
    expect_eq("FFT imag word " + std::to_string(index),
              golden[index + kFftPoints / 4],
              peek_word(dut, kImagBase + 4 * index));
  }

  const std::uint32_t bin8_real_word = peek_word(dut, kRealBase + 8);
  const std::uint32_t bin8_imag_word = peek_word(dut, kImagBase + 8);
  const std::uint32_t bin56_real_word = peek_word(dut, kRealBase + 56);
  const std::uint32_t bin56_imag_word = peek_word(dut, kImagBase + 56);
  expect_eq("bin 8 real",
            static_cast<std::uint8_t>(byte_at(golden[8 / 4], 0)),
            static_cast<std::uint8_t>(byte_at(bin8_real_word, 0)));
  expect_eq("bin 8 imag",
            static_cast<std::uint8_t>(
                byte_at(golden[kFftPoints / 4 + 8 / 4], 0)),
            static_cast<std::uint8_t>(byte_at(bin8_imag_word, 0)));
  expect_eq("bin 56 real",
            static_cast<std::uint8_t>(byte_at(golden[56 / 4], 0)),
            static_cast<std::uint8_t>(byte_at(bin56_real_word, 0)));
  expect_eq("bin 56 imag",
            static_cast<std::uint8_t>(
                byte_at(golden[kFftPoints / 4 + 56 / 4], 0)),
            static_cast<std::uint8_t>(byte_at(bin56_imag_word, 0)));
  const std::uint32_t expected_input_exponent_word =
      replicated_byte_word(input_exponent);
  const std::uint32_t expected_output_exponent_word =
      replicated_byte_word(expected_output_exponent);
  std::int8_t output_exponent = 0;
  for (std::size_t index = 0; index < 4; ++index) {
    const std::uint32_t output_exponent_word =
        peek_word(dut, kBfpExponentOutBase + 4 * index);
    expect_eq("BFP input exponent word " + std::to_string(index),
              expected_input_exponent_word,
              peek_word(dut, kBfpExponentInBase + 4 * index));
    expect_eq("BFP output exponent word " + std::to_string(index),
              expected_output_exponent_word, output_exponent_word);
    if (index == 0) output_exponent = byte_at(output_exponent_word, 0);
  }
  return output_exponent;
}

FftOutputWords write_output(Dut& dut, const std::string& path) {
  std::ofstream output(path);
  if (!output) throw std::runtime_error("cannot create RTL output: " + path);
  FftOutputWords words;
  output << std::hex << std::setfill('0');
  for (std::size_t index = 0; index < kFftPoints / 4; ++index) {
    words.real[index] = peek_word(dut, kRealBase + 4 * index);
    output << std::setw(8) << words.real[index] << '\n';
  }
  for (std::size_t index = 0; index < kFftPoints / 4; ++index) {
    words.imag[index] = peek_word(dut, kImagBase + 4 * index);
    output << std::setw(8) << words.imag[index] << '\n';
  }
  output.flush();
  if (!output) throw std::runtime_error("cannot write RTL output: " + path);
  return words;
}

void write_csv(const FftOutputWords& words, std::int8_t execution_exponent,
               std::uint64_t scale_num, std::uint64_t scale_den,
               const std::string& path) {
  if (path.empty()) throw std::runtime_error("CSV output path is empty");
  std::ofstream output(path, std::ios::out | std::ios::trunc);
  if (!output) throw std::runtime_error("cannot create CSV output: " + path);

  output.imbue(std::locale::classic());
  output << "bin,real_mantissa,imag_mantissa,execution_exponent,value_scale,"
            "real_value,imag_value,magnitude,power\n";
  output << std::setprecision(17);
  const double value_scale = static_cast<double>(scale_num) /
                             static_cast<double>(scale_den);
  for (std::size_t bin = 0; bin < kFftPoints; ++bin) {
    const std::size_t word_index = bin / 4;
    const unsigned lane = static_cast<unsigned>(bin % 4);
    const std::int8_t real_mantissa = byte_at(words.real[word_index], lane);
    const std::int8_t imag_mantissa = byte_at(words.imag[word_index], lane);
    const double real_value = static_cast<double>(real_mantissa) * value_scale;
    const double imag_value = static_cast<double>(imag_mantissa) * value_scale;
    const double power =
        real_value * real_value + imag_value * imag_value;
    const double magnitude = std::sqrt(power);
    output << bin << ',' << static_cast<int>(real_mantissa) << ','
           << static_cast<int>(imag_mantissa) << ','
           << static_cast<int>(execution_exponent) << ',' << value_scale << ','
           << real_value << ',' << imag_value << ',' << magnitude << ','
           << power << '\n';
  }
  output.flush();
  if (!output) throw std::runtime_error("cannot write CSV output: " + path);
}

}  // namespace

double sc_time_stamp() { return static_cast<double>(sim_time); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 9) {
    std::cerr << "usage: " << argv[0]
              << " PROGRAM.hex DATA.hex GOLDEN.hex OUTPUT.hex WAVE.vcd "
                 "SPECTRUM.csv SCALE_NUM SCALE_DEN\n";
    return 2;
  }
  if (argv[6][0] == '\0') {
    std::cerr << "FAIL CSV output path is empty\n";
    return 2;
  }

  try {
    const std::vector<std::uint32_t> program = read_hex_words(argv[1]);
    const std::vector<std::uint32_t> data = read_hex_words(argv[2]);
    const std::vector<std::uint32_t> golden = read_hex_words(argv[3]);
    const std::uint64_t scale_num =
        parse_positive_integer(argv[7], "scale numerator");
    const std::uint64_t scale_den =
        parse_positive_integer(argv[8], "scale denominator");
    expect_eq("generated program word count", 93, program.size());
    expect_eq("generated data word count", 224, data.size());
    const std::size_t input_exponent_word_index =
        (kBfpExponentInBase - kDataBase) / 4;
    const std::int8_t input_exponent =
        byte_at(data[input_exponent_word_index], 0);
    const int expected_output_exponent_value =
        static_cast<int>(input_exponent) + kFftStages;
    if (expected_output_exponent_value < -128 ||
        expected_output_exponent_value > 127) {
      throw std::runtime_error("output execution exponent exceeds int8 range");
    }
    const std::int8_t expected_output_exponent =
        static_cast<std::int8_t>(expected_output_exponent_value);

    Verilated::traceEverOn(true);
    Dut dut;
    VerilatedVcdC trace_file;
    trace = &trace_file;
    dut.trace(&trace_file, 4);
    trace_file.open(argv[5]);

    reset(dut, program.size());
    install_image(dut, program, data);
    launch(dut, program.size());
    run_program(dut);
    const std::int8_t output_exponent =
        check_output(dut, golden, input_exponent, expected_output_exponent);
    const FftOutputWords output_words = write_output(dut, argv[4]);
    write_csv(output_words, output_exponent, scale_num, scale_den, argv[6]);

    expect_eq("all uword actions retired", kExpectedActions, completions);
    expect_true("instruction cache observed hits", icache_hits > 0);
    expect_true("instruction cache observed misses", icache_misses > 0);
    expect_true("data cache observed read hits", dcache_read_hits > 0);
    expect_true("data cache observed read misses", dcache_read_misses > 0);
    expect_true("data cache observed writes",
                dcache_write_hits + dcache_write_misses > 0);
    expect_true("shared lower RAM observed reads",
                dut.lower_read_req_count_o > 0);
    expect_true("shared lower RAM observed writes",
                dut.lower_write_req_count_o > 0);
    expect_eq("every lower request has a response", dut.lower_req_count_o,
              dut.lower_rsp_count_o);
    expect_eq("combined protocol error", 0, dut.protocol_error_o);
    expect_eq("fetch protocol error", 0, dut.fetch_protocol_error_o);
    expect_eq("cluster protocol error", 0, dut.cluster_protocol_error_o);
    expect_eq("I-side protocol error", 0,
              dut.ifetch_path_protocol_error_o);
    expect_eq("D-side protocol error", 0, dut.dmem_path_protocol_error_o);
    expect_eq("maintenance protocol error", 0,
              dut.maint_protocol_error_o);

    trace_file.close();
    trace = nullptr;
    dut.final();
    std::cout << "PASS fft64_vsp_memory_system_tb: " << checks
              << " checks, " << completions << " actions, " << cycles
              << " cycles, " << icache_misses << " I-cache misses, "
              << dcache_read_misses << " D-cache read misses, "
              << dut.lower_req_count_o << " shared-RAM beats; waveform="
              << argv[5] << ", output=" << argv[4]
              << ", BFP Ein=" << static_cast<int>(input_exponent)
              << " Eout=" << static_cast<int>(output_exponent)
              << ", value_scale=" << scale_num << '/' << scale_den << '\n';
  } catch (const std::exception& error) {
    std::cerr << "FAIL " << error.what() << '\n';
    return 1;
  }
  return 0;
}
