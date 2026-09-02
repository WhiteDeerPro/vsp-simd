// SPDX-License-Identifier: MIT

#include "Vvsp_uword_cached_program_wrapper_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Dut = Vvsp_uword_cached_program_wrapper_tb_top;

constexpr std::uint32_t kBasePc = 0x20;
constexpr std::uint32_t kInputBase = 0x1040;
constexpr std::uint32_t kOutputBase = 0x1140;
constexpr unsigned kVectorBytes = 48;
constexpr std::uint8_t kIncrement = 40;

constexpr std::uint8_t kExec = 0;
constexpr std::uint8_t kMemory = 1;
constexpr std::uint8_t kControl = 2;
constexpr std::uint8_t kLoad = 0;
constexpr std::uint8_t kStore = 1;
constexpr std::uint8_t kStatusOk = 0;
constexpr std::uint8_t kFaultNone = 0;
constexpr std::uint8_t kMaintInvalidateAll = 2;

std::uint64_t checks = 0;
std::uint64_t cycles = 0;
std::uint64_t read_hits = 0;
std::uint64_t read_misses = 0;
std::uint64_t write_hits = 0;
std::uint64_t write_misses = 0;

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

void eval_low(Dut& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Dut& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  ++cycles;
  read_hits += dut.perf_dcache_read_hit_o != 0;
  read_misses += dut.perf_dcache_read_miss_o != 0;
  write_hits += dut.perf_dcache_write_hit_o != 0;
  write_misses += dut.perf_dcache_write_miss_o != 0;
  dut.clk_i = 0;
  dut.eval();
}

template <typename Predicate>
void wait_for(Dut& dut, Predicate predicate, const std::string& label,
              unsigned limit = 12000) {
  for (unsigned waited = 0; waited < limit; ++waited) {
    eval_low(dut);
    if (predicate()) return;
    tick(dut);
  }
  std::cerr << "FAIL timeout waiting for " << label << '\n';
  std::exit(EXIT_FAILURE);
}

void clear_inputs(Dut& dut) {
  dut.store_write_valid_i = 0;
  dut.store_write_pc_i = 0;
  dut.store_write_data_i = 0;
  dut.start_valid_i = 0;
  dut.start_pc_i = 0;
  dut.end_pc_i = 0;
  dut.start_context_i = 0;
  dut.start_group_mask_i = 0;
  dut.start_tag_seed_i = 0;
  dut.action_cpl_ready_i = 1;

  dut.backing_init_valid_i = 0;
  dut.backing_init_paddr_i = 0;
  dut.backing_init_wdata_i = 0;
  dut.backing_init_wstrb_i = 0;
  dut.backing_peek_paddr_i = kInputBase;
  dut.dcache_maint_req_valid_i = 0;
  dut.dcache_maint_req_op_i = 0;
  dut.dcache_maint_req_paddr_i = 0;
  dut.dcache_maint_rsp_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Dut& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  for (unsigned cycle = 0; cycle < 3; ++cycle) tick(dut);
  expect_eq("reset blocks program start", 0, dut.start_ready_o);
  expect_eq("reset clears program active", 0, dut.program_active_o);
  expect_eq("reset clears integration error", 0, dut.protocol_error_o);

  dut.rst_ni = 1;
  wait_for(dut,
           [&dut]() {
             return dut.memory_ready_o && dut.memory_quiescent_o &&
                    dut.start_ready_o;
           },
           "program and memory initialization");
  expect_eq("management available after initialization", 1,
            dut.management_allowed_o);
  expect_eq("management inactive after initialization", 0,
            dut.management_active_o);
}

std::vector<std::uint32_t> read_hex(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot open generated hex: " + path);
  std::vector<std::uint32_t> words;
  std::string line;
  while (std::getline(input, line)) {
    if (!line.empty())
      words.push_back(
          static_cast<std::uint32_t>(std::stoul(line, nullptr, 16)));
  }
  return words;
}

void init_word(Dut& dut, std::uint32_t address, std::uint32_t value) {
  dut.backing_init_paddr_i = address;
  dut.backing_init_wdata_i = value;
  dut.backing_init_wstrb_i = 0xf;
  dut.backing_init_valid_i = 1;
  wait_for(dut, [&dut]() { return dut.backing_init_ready_o != 0; },
           "backing SRAM initialization");
  expect_eq("backing initialization address accepted", 0,
            dut.backing_init_error_o);
  tick(dut);
  dut.backing_init_valid_i = 0;
}

std::uint32_t peek_word(Dut& dut, std::uint32_t address) {
  dut.backing_peek_paddr_i = address;
  eval_low(dut);
  expect_eq("backing peek address accepted", 0, dut.backing_peek_error_o);
  return static_cast<std::uint32_t>(dut.backing_peek_rdata_o);
}

template <std::size_t N>
std::uint32_t pack_word(const std::array<std::uint8_t, N>& bytes,
                        std::size_t offset) {
  std::uint32_t value = 0;
  for (unsigned byte = 0; byte < 4; ++byte)
    value |= std::uint32_t{bytes.at(offset + byte)} << (8 * byte);
  return value;
}

std::uint8_t reference(std::uint8_t input) {
  const unsigned sum = unsigned{input} + kIncrement;
  return static_cast<std::uint8_t>(sum > 255 ? 255 : sum);
}

void load_program(Dut& dut, const std::vector<std::uint32_t>& words) {
  for (std::size_t index = 0; index < words.size(); ++index) {
    dut.store_write_valid_i = 1;
    dut.store_write_pc_i = kBasePc + static_cast<std::uint32_t>(4 * index);
    dut.store_write_data_i = words[index];
    wait_for(dut, [&dut]() { return dut.store_write_ready_o != 0; },
             "control-store write");
    tick(dut);
    dut.store_write_valid_i = 0;
  }
}

void launch(Dut& dut, std::size_t word_count) {
  wait_for(dut, [&dut]() { return dut.start_ready_o != 0; },
           "program launch admission");
  dut.start_valid_i = 1;
  dut.start_pc_i = kBasePc;
  dut.end_pc_i = kBasePc + static_cast<std::uint32_t>(4 * word_count);
  dut.start_context_i = 0;
  dut.start_group_mask_i = 0xf;
  dut.start_tag_seed_i = 0x10;
  eval_low(dut);
  expect_eq("launch handshake is ready", 1, dut.start_ready_o);
  tick(dut);
  dut.start_valid_i = 0;

  // Launch metadata is snapshotted; later pin changes cannot change ownership.
  dut.start_group_mask_i = 0x3;
  dut.start_tag_seed_i = 0xee;
}

struct Completion {
  std::uint8_t action_class;
  std::uint8_t tag;
  std::uint8_t group_mask;
  std::uint8_t status;
  bool end;
  std::uint8_t memory_op;
  std::uint8_t memory_status;
  std::uint8_t memory_fault;
  std::uint32_t memory_fault_eaddr;
  std::uint8_t memory_requested_mask;
  std::uint8_t memory_completed_mask;
  std::uint8_t memory_failed_mask;
  std::uint8_t memory_bytes_committed;
  bool memory_partial;
};

Completion sample_completion(const Dut& dut) {
  return {
      static_cast<std::uint8_t>(dut.action_cpl_class_o),
      static_cast<std::uint8_t>(dut.action_cpl_tag_o),
      static_cast<std::uint8_t>(dut.action_cpl_group_mask_o),
      static_cast<std::uint8_t>(dut.action_cpl_status_o),
      static_cast<bool>(dut.action_cpl_end_o),
      static_cast<std::uint8_t>(dut.action_cpl_memory_op_o),
      static_cast<std::uint8_t>(dut.action_cpl_memory_status_o),
      static_cast<std::uint8_t>(dut.action_cpl_memory_fault_cause_o),
      static_cast<std::uint32_t>(dut.action_cpl_memory_fault_eaddr_o),
      static_cast<std::uint8_t>(
          dut.action_cpl_memory_requested_group_mask_o),
      static_cast<std::uint8_t>(
          dut.action_cpl_memory_completed_group_mask_o),
      static_cast<std::uint8_t>(dut.action_cpl_memory_failed_group_mask_o),
      static_cast<std::uint8_t>(dut.action_cpl_memory_bytes_committed_o),
      static_cast<bool>(dut.action_cpl_memory_partial_o)};
}

void expect_completion_stable(const Completion& expected,
                              const Completion& actual) {
  expect_eq("stalled completion class", expected.action_class,
            actual.action_class);
  expect_eq("stalled completion tag", expected.tag, actual.tag);
  expect_eq("stalled completion group mask", expected.group_mask,
            actual.group_mask);
  expect_eq("stalled completion status", expected.status, actual.status);
  expect_eq("stalled completion END", expected.end, actual.end);
  expect_eq("stalled completion MEMORY op", expected.memory_op,
            actual.memory_op);
  expect_eq("stalled completion MEMORY status", expected.memory_status,
            actual.memory_status);
  expect_eq("stalled completion MEMORY fault", expected.memory_fault,
            actual.memory_fault);
  expect_eq("stalled completion MEMORY fault address",
            expected.memory_fault_eaddr, actual.memory_fault_eaddr);
  expect_eq("stalled completion MEMORY requested mask",
            expected.memory_requested_mask, actual.memory_requested_mask);
  expect_eq("stalled completion MEMORY completed mask",
            expected.memory_completed_mask, actual.memory_completed_mask);
  expect_eq("stalled completion MEMORY failed mask",
            expected.memory_failed_mask, actual.memory_failed_mask);
  expect_eq("stalled completion MEMORY committed bytes",
            expected.memory_bytes_committed, actual.memory_bytes_committed);
  expect_eq("stalled completion MEMORY partial", expected.memory_partial,
            actual.memory_partial);
}

struct Run {
  bool done = false;
  bool failed = false;
  bool error = false;
  std::vector<Completion> completions;
};

Run run_program(Dut& dut) {
  Run result;
  bool held_valid = false;
  Completion held{};

  for (unsigned cycle = 0; cycle < 20000; ++cycle) {
    dut.action_cpl_ready_i = (cycle % 7) >= 3;
    eval_low(dut);
    const Completion visible = sample_completion(dut);

    if (held_valid) {
      expect_eq("stalled completion remains valid", 1,
                dut.action_cpl_valid_o);
      expect_completion_stable(held, visible);
    }
    if (dut.action_cpl_valid_o && !dut.action_cpl_ready_i && !held_valid) {
      held_valid = true;
      held = visible;
    }
    if (dut.action_cpl_valid_o && dut.action_cpl_ready_i) {
      result.completions.push_back(visible);
      held_valid = false;
    }

    result.done |= dut.program_done_o != 0;
    result.failed |= dut.program_failed_o != 0;
    result.error = dut.program_error_o != 0;
    if ((result.done || result.failed) && !dut.program_active_o) {
      tick(dut);
      dut.action_cpl_ready_i = 1;
      return result;
    }
    tick(dut);
  }

  fail("program terminal timeout", 1, 0);
}

void check_completion(const Completion& actual, std::uint8_t action_class,
                      std::uint8_t tag, std::uint8_t group_mask, bool end,
                      const std::string& label) {
  expect_eq(label + " class", action_class, actual.action_class);
  expect_eq(label + " tag", tag, actual.tag);
  expect_eq(label + " group mask", group_mask, actual.group_mask);
  expect_eq(label + " status", kStatusOk, actual.status);
  expect_eq(label + " END", end, actual.end);

  if (action_class != kMemory) {
    expect_eq(label + " non-MEMORY op is canonical zero", 0,
              actual.memory_op);
    expect_eq(label + " non-MEMORY status is canonical zero", 0,
              actual.memory_status);
    expect_eq(label + " non-MEMORY requested mask is zero", 0,
              actual.memory_requested_mask);
    expect_eq(label + " non-MEMORY completed mask is zero", 0,
              actual.memory_completed_mask);
    expect_eq(label + " non-MEMORY committed bytes is zero", 0,
              actual.memory_bytes_committed);
  }
}

void check_memory_completion(const Completion& actual, std::uint8_t op,
                             const std::string& label) {
  expect_eq(label + " op", op, actual.memory_op);
  expect_eq(label + " memory status", kStatusOk, actual.memory_status);
  expect_eq(label + " fault", kFaultNone, actual.memory_fault);
  expect_eq(label + " fault address", 0, actual.memory_fault_eaddr);
  expect_eq(label + " requested mask", 0xf,
            actual.memory_requested_mask);
  expect_eq(label + " completed mask", 0xf,
            actual.memory_completed_mask);
  expect_eq(label + " failed mask", 0, actual.memory_failed_mask);
  expect_eq(label + " committed bytes", 16,
            actual.memory_bytes_committed);
  expect_eq(label + " partial", 0, actual.memory_partial);
}

void test_management_interlock(Dut& dut) {
  wait_for(dut, [&dut]() { return dut.management_allowed_o != 0; },
           "management admission after program");
  dut.dcache_maint_req_valid_i = 1;
  dut.dcache_maint_req_op_i = kMaintInvalidateAll;
  dut.dcache_maint_req_paddr_i = 0;
  eval_low(dut);
  expect_eq("D-cache maintenance request accepted", 1,
            dut.dcache_maint_req_ready_o);
  tick(dut);
  dut.dcache_maint_req_valid_i = 0;

  eval_low(dut);
  expect_eq("management lane owns accepted command", 1,
            dut.management_active_o);
  expect_eq("management lane closes further admission", 0,
            dut.management_allowed_o);

  // An otherwise legal launch cannot pass an in-flight management command.
  dut.start_valid_i = 1;
  dut.start_pc_i = kBasePc;
  dut.end_pc_i = kBasePc + 4;
  dut.start_context_i = 0;
  dut.start_group_mask_i = 0xf;
  dut.start_tag_seed_i = 0x80;
  eval_low(dut);
  expect_eq("management command blocks launch", 0, dut.start_ready_o);
  dut.start_valid_i = 0;

  wait_for(dut, [&dut]() { return dut.dcache_maint_rsp_valid_o != 0; },
           "serialized D-cache maintenance response");
  expect_eq("maintenance response status", kStatusOk,
            dut.dcache_maint_rsp_status_o);
  expect_eq("management remains active under response backpressure", 1,
            dut.management_active_o);
  tick(dut);
  expect_eq("maintenance response holds under backpressure", 1,
            dut.dcache_maint_rsp_valid_o);
  expect_eq("maintenance status holds under backpressure", kStatusOk,
            dut.dcache_maint_rsp_status_o);

  dut.dcache_maint_rsp_ready_i = 1;
  tick(dut);
  dut.dcache_maint_rsp_ready_i = 0;
  wait_for(dut,
           [&dut]() {
             return !dut.management_active_o && dut.management_allowed_o &&
                    dut.start_ready_o;
           },
           "management retirement and launch reopening");
}

}  // namespace

double sc_time_stamp() { return static_cast<double>(cycles); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 2) {
    std::cerr << "usage: " << argv[0] << " PROGRAM.hex\n";
    return 2;
  }

  const std::vector<std::uint32_t> program = read_hex(argv[1]);
  if (program.size() != 15) {
    std::cerr << "physical-memory program must fit the 16-word control store"
              << " and currently encode to 15 words\n";
    return 1;
  }

  Dut dut;
  reset(dut);

  const std::array<std::uint8_t, 16> pattern = {
      0,   1,   39,  40,  64,  127, 128, 192,
      200, 214, 215, 216, 217, 240, 254, 255};
  std::array<std::uint8_t, kVectorBytes> input{};
  std::array<std::uint8_t, kVectorBytes> expected{};
  for (unsigned index = 0; index < kVectorBytes; ++index) {
    input[index] = pattern[index % pattern.size()];
    expected[index] = reference(input[index]);
  }

  for (unsigned offset = 0; offset < kVectorBytes; offset += 4) {
    init_word(dut, kInputBase + offset, pack_word(input, offset));
    init_word(dut, kOutputBase + offset, 0x5a5a5a5aU);
  }
  init_word(dut, kOutputBase - 4, 0xa5a5a5a5U);
  init_word(dut, kOutputBase + kVectorBytes, 0x3c3c3c3cU);

  load_program(dut, program);
  launch(dut, program.size());
  Run run = run_program(dut);

  expect_eq("program completed", 1, run.done);
  expect_eq("program did not transport-fail", 0, run.failed);
  expect_eq("program accumulated no architectural error", 0, run.error);
  expect_eq("program completion count", 18, run.completions.size());

  std::size_t completion = 0;
  std::uint8_t tag = 0x10;
  for (unsigned setup = 0; setup < 2; ++setup) {
    const std::string label = "setup " + std::to_string(setup);
    check_completion(run.completions.at(completion++), kControl, tag++, 0,
                     false, label);
  }

  const std::array<std::uint8_t, 5> loop_classes = {
      kMemory, kExec, kMemory, kControl, kControl};
  for (unsigned block = 0; block < 3; ++block) {
    for (unsigned action = 0; action < loop_classes.size(); ++action) {
      const std::string label = "block " + std::to_string(block) +
                                " action " + std::to_string(action);
      const std::uint8_t action_class = loop_classes[action];
      const std::uint8_t group_mask =
          (action_class == kMemory || action_class == kExec) ? 0xf : 0;
      const Completion& actual = run.completions.at(completion++);
      check_completion(actual, action_class, tag++, group_mask, false, label);
      if (action_class == kMemory)
        check_memory_completion(actual, action == 0 ? kLoad : kStore, label);
    }
  }
  check_completion(run.completions.at(completion++), kControl, tag++, 0,
                   true, "END");
  expect_eq("checked every completion", run.completions.size(), completion);

  wait_for(dut, [&dut]() { return dut.memory_quiescent_o != 0; },
           "memory hierarchy quiescence after END");
  for (unsigned offset = 0; offset < kVectorBytes; offset += 4) {
    expect_eq("input word remains unchanged " + std::to_string(offset),
              pack_word(input, offset), peek_word(dut, kInputBase + offset));
    expect_eq("output word " + std::to_string(offset),
              pack_word(expected, offset),
              peek_word(dut, kOutputBase + offset));
  }
  expect_eq("lower output guard", 0xa5a5a5a5U,
            peek_word(dut, kOutputBase - 4));
  expect_eq("upper output guard", 0x3c3c3c3cU,
            peek_word(dut, kOutputBase + kVectorBytes));

  expect_eq("two cache-line read misses", 2, read_misses);
  expect_eq("ten cache read hits", 10, read_hits);
  expect_eq("write-no-allocate has no output hits", 0, write_hits);
  expect_eq("twelve output write misses", 12, write_misses);
  expect_eq("two refills plus twelve write-through beats", 28,
            dut.lower_req_count_o);
  expect_eq("every lower request receives a response",
            dut.lower_req_count_o, dut.lower_rsp_count_o);

  test_management_interlock(dut);
  expect_eq("management returns available after program", 1,
            dut.management_allowed_o);
  expect_eq("management remains inactive", 0, dut.management_active_o);
  expect_eq("integration reports no protocol error", 0,
            dut.protocol_error_o);

  std::cout << "vsp_uword_cached_program_wrapper_tb: " << checks
            << " integration checks passed in " << cycles << " cycles; "
            << dut.lower_req_count_o << " lower beats\n";
  return 0;
}
