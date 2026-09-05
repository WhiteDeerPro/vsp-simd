// SPDX-License-Identifier: MIT

#include "Vvsp_uword_memory_system_wrapper_tb_top.h"
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

using Dut = Vvsp_uword_memory_system_wrapper_tb_top;

constexpr std::uint32_t kBasePc = 0x20;
constexpr std::uint32_t kInputBase = 0x1040;
constexpr std::uint32_t kOutputBase = 0x1140;
constexpr unsigned kVectorBytes = 48;
constexpr std::uint8_t kIncrement = 40;

constexpr std::uint8_t kAddrSpacePhysical = 1;
constexpr std::uint8_t kAddrSpaceTranslated = 2;
constexpr std::uint32_t kVirtualPc = 0x00400020;
constexpr std::uint32_t kRootEntry = 0x2004;
constexpr std::uint32_t kLeafEntry = 0x3000;
constexpr std::uint32_t kExecutablePte = 0x5b;  // V | R | X | U | A, PPN=0
constexpr std::uint8_t kExec = 0;
constexpr std::uint8_t kMemory = 1;
constexpr std::uint8_t kControl = 2;
constexpr std::uint8_t kLoad = 0;
constexpr std::uint8_t kStore = 1;
constexpr std::uint8_t kStatusOk = 0;
constexpr std::uint8_t kFaultNone = 0;
constexpr std::uint8_t kMaintIInvalidateAll = 4;
constexpr std::uint8_t kMaintFenceI = 9;
constexpr std::uint8_t kMaintStepQuiesce = 2;
constexpr std::uint8_t kMaintStepFabricDrain = 3;
constexpr std::uint8_t kMaintStepDCacheDrain = 4;
constexpr std::uint8_t kMaintStepICacheInvalidate = 6;
constexpr std::uint8_t kMaintStepTlbInvalidate = 7;
constexpr std::uint8_t kMaintStepCompletion = 8;
constexpr std::uint8_t kMmuCfgValidField = 0;

std::uint64_t checks = 0;
std::uint64_t cycles = 0;
std::uint64_t icache_hits = 0;
std::uint64_t icache_misses = 0;
std::uint64_t dcache_read_hits = 0;
std::uint64_t dcache_read_misses = 0;
std::uint64_t dcache_write_hits = 0;
std::uint64_t dcache_write_misses = 0;

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
  icache_hits += dut.perf_icache_read_hit_o != 0;
  icache_misses += dut.perf_icache_read_miss_o != 0;
  dcache_read_hits += dut.perf_dcache_read_hit_o != 0;
  dcache_read_misses += dut.perf_dcache_read_miss_o != 0;
  dcache_write_hits += dut.perf_dcache_write_hit_o != 0;
  dcache_write_misses += dut.perf_dcache_write_miss_o != 0;
  dut.clk_i = 0;
  dut.eval();
}

template <typename Predicate>
void wait_for(Dut& dut, Predicate predicate, const std::string& label,
              unsigned limit = 30000) {
  for (unsigned waited = 0; waited < limit; ++waited) {
    eval_low(dut);
    if (predicate()) return;
    tick(dut);
  }
  std::cerr << "FAIL timeout waiting for " << label << '\n';
  std::exit(EXIT_FAILURE);
}

void drive_launch_fields(Dut& dut, std::size_t word_count,
                         std::uint8_t tag_seed) {
  dut.start_pc_i = kBasePc;
  dut.end_pc_i = kBasePc + static_cast<std::uint32_t>(4 * word_count);
  dut.start_context_i = 0;
  dut.start_group_mask_i = 0xf;
  dut.start_tag_seed_i = tag_seed;
  dut.start_ifetch_addr_space_i = kAddrSpacePhysical;
  dut.start_ifetch_addr_context_i = 0x5a;
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
  dut.maint_cpl_ready_i = 0;

  dut.backing_init_valid_i = 0;
  dut.backing_init_paddr_i = 0;
  dut.backing_init_wdata_i = 0;
  dut.backing_init_wstrb_i = 0;
  dut.backing_peek_paddr_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Dut& dut, std::size_t word_count) {
  clear_inputs(dut);
  drive_launch_fields(dut, word_count, 0x10);
  dut.rst_ni = 0;
  for (unsigned cycle = 0; cycle < 3; ++cycle) tick(dut);
  expect_eq("reset blocks program start", 0, dut.start_ready_o);
  expect_eq("reset clears program active", 0, dut.program_active_o);
  expect_eq("reset clears integration error", 0, dut.protocol_error_o);

  // Observe admission while idle.  Cache tag scans and physical-fabric
  // dequarantine must keep ready low; a real launch is asserted later and then
  // held until handshake by launch_program().
  dut.rst_ni = 1;
  eval_low(dut);
  expect_eq("cold initialization blocks launch combinationally", 0,
            dut.start_ready_o);
  tick(dut);
  expect_eq("cold initialization does not start program", 0,
            dut.program_active_o);
  expect_eq("cold initialization still blocks launch", 0,
            dut.start_ready_o);
  wait_for(dut,
           [&dut]() {
             return dut.system_ready_o && dut.system_quiescent_o &&
                    dut.start_ready_o;
           },
           "I/D/MMU/fabric initialization");
  expect_eq("MMU initialized", 1, dut.mmu_init_done_o);
  expect_eq("D-cache initialized", 1, dut.dcache_init_done_o);
  expect_eq("I-cache initialized", 1, dut.icache_init_done_o);
  expect_eq("D path ready", 1, dut.dmem_path_ready_o);
  expect_eq("I path ready", 1, dut.ifetch_path_ready_o);
  expect_eq("fabric left reset quarantine", 0, dut.fabric_quarantine_o);
  expect_eq("I region table has no overlap", 0,
            dut.i_region_config_overlap_o);
  expect_eq("D region table has no overlap", 0,
            dut.d_region_config_overlap_o);
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

void install_image(Dut& dut, const std::vector<std::uint32_t>& program,
                   const std::array<std::uint8_t, kVectorBytes>& input) {
  for (std::size_t index = 0; index < program.size(); ++index)
    init_word(dut, kBasePc + static_cast<std::uint32_t>(4 * index),
              program[index]);

  for (unsigned offset = 0; offset < kVectorBytes; offset += 4) {
    init_word(dut, kInputBase + offset, pack_word(input, offset));
    init_word(dut, kOutputBase + offset, 0x5a5a5a5aU);
  }
  init_word(dut, kOutputBase - 4, 0xa5a5a5a5U);
  init_word(dut, kOutputBase + kVectorBytes, 0x3c3c3c3cU);
}

void launch(Dut& dut, std::size_t word_count, std::uint8_t tag_seed,
            std::uint32_t pc = kBasePc,
            std::uint8_t space = kAddrSpacePhysical,
            std::uint8_t context = 0x5a) {
  wait_for(dut, [&dut]() { return dut.start_ready_o != 0; },
           "program launch admission");
  drive_launch_fields(dut, word_count, tag_seed);
  dut.start_pc_i = pc;
  dut.end_pc_i = pc + static_cast<std::uint32_t>(4 * word_count);
  dut.start_ifetch_addr_space_i = space;
  dut.start_ifetch_addr_context_i = context;
  dut.start_valid_i = 1;
  eval_low(dut);
  expect_eq("launch handshake is ready", 1, dut.start_ready_o);
  tick(dut);
  dut.start_valid_i = 0;
  expect_eq("accepted launch clears IFetch diagnosis", 0,
            dut.ifetch_fault_valid_o);

  // All launch metadata is owned by the accepted run, not by live pins.
  dut.start_group_mask_i = 0x3;
  dut.start_tag_seed_i = 0xee;
  dut.start_ifetch_addr_space_i = 0;
  dut.start_ifetch_addr_context_i = 0xa5;
}

void check_maintenance_gate_while_active(Dut& dut) {
  dut.action_cpl_ready_i = 0;
  wait_for(dut, [&dut]() { return dut.program_active_o != 0; },
           "program active before maintenance rejection");

  dut.maint_cmd_op_i = kMaintIInvalidateAll;
  dut.maint_cmd_paddr_i = 0;
  for (unsigned hold = 0; hold < 4; ++hold) {
    eval_low(dut);
    expect_eq("active program withholds maintenance ready", 0,
              dut.maint_cmd_ready_o);
    expect_eq("maintenance controller remains idle during program", 0,
              dut.maint_busy_o);
    expect_eq("idle maintenance controller has no completion", 0,
              dut.maint_cpl_valid_o);
    expect_eq("maintenance probe leaves program active", 1,
              dut.program_active_o);
    expect_eq("active program keeps full system non-quiescent", 0,
              dut.system_quiescent_o);
    expect_eq("active program keeps full system busy", 1,
              dut.system_busy_o);
    tick(dut);
  }
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

  for (unsigned cycle = 0; cycle < 30000; ++cycle) {
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
    result.error |= dut.program_error_o != 0;
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

void check_run(const Run& run, std::uint8_t first_tag,
               const std::string& run_label) {
  expect_eq(run_label + " completed", 1, run.done);
  expect_eq(run_label + " did not transport-fail", 0, run.failed);
  expect_eq(run_label + " accumulated no architectural error", 0,
            run.error);
  expect_eq(run_label + " completion count", 18, run.completions.size());

  std::size_t completion = 0;
  std::uint8_t tag = first_tag;
  for (unsigned setup = 0; setup < 2; ++setup) {
    const std::string label = run_label + " setup " +
                              std::to_string(setup);
    check_completion(run.completions.at(completion++), kControl, tag++, 0,
                     false, label);
  }

  const std::array<std::uint8_t, 5> loop_classes = {
      kMemory, kExec, kMemory, kControl, kControl};
  for (unsigned block = 0; block < 3; ++block) {
    for (unsigned action = 0; action < loop_classes.size(); ++action) {
      const std::string label = run_label + " block " +
          std::to_string(block) + " action " + std::to_string(action);
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
                   true, run_label + " END");
  expect_eq(run_label + " checked every completion", run.completions.size(),
            completion);
}

void check_memory_image(
    Dut& dut, const std::array<std::uint8_t, kVectorBytes>& input,
    const std::array<std::uint8_t, kVectorBytes>& expected,
    const std::string& label) {
  for (unsigned offset = 0; offset < kVectorBytes; offset += 4) {
    expect_eq(label + " input word " + std::to_string(offset),
              pack_word(input, offset), peek_word(dut, kInputBase + offset));
    expect_eq(label + " output word " + std::to_string(offset),
              pack_word(expected, offset),
              peek_word(dut, kOutputBase + offset));
  }
  expect_eq(label + " lower output guard", 0xa5a5a5a5U,
            peek_word(dut, kOutputBase - 4));
  expect_eq(label + " upper output guard", 0x3c3c3c3cU,
            peek_word(dut, kOutputBase + kVectorBytes));
}

void exercise_mmu_cfg_ownership(Dut& dut) {
  wait_for(dut,
           [&dut]() {
             return dut.system_quiescent_o && dut.mmu_cfg_ready_o &&
                    dut.maint_cmd_ready_o;
           },
           "MMU configuration admission");

  const std::uint32_t reqs_before = dut.lower_req_count_o;
  dut.mmu_cfg_valid_i = 1;
  dut.mmu_cfg_write_i = 0;
  dut.mmu_cfg_context_i = 0;
  dut.mmu_cfg_field_i = kMmuCfgValidField;
  dut.mmu_cfg_wdata_i = 0;
  dut.mmu_cfg_rsp_ready_i = 0;
  eval_low(dut);
  expect_eq("MMU configuration request accepted into owner slot", 1,
            dut.mmu_cfg_ready_o);
  tick(dut);
  dut.mmu_cfg_valid_i = 0;

  // Change the live pins after acceptance and present maintenance.  The
  // buffered request must retain its original payload and ownership until its
  // response retires; the younger maintenance request cannot withdraw it.
  dut.mmu_cfg_field_i = 0xf;
  dut.mmu_cfg_context_i = 0xff;
  dut.maint_cmd_valid_i = 1;
  dut.maint_cmd_op_i = kMaintIInvalidateAll;
  dut.maint_cpl_ready_i = 0;
  for (unsigned waited = 0; waited < 100; ++waited) {
    eval_low(dut);
    expect_eq("accepted MMU config blocks younger maintenance", 0,
              dut.maint_cmd_ready_o);
    expect_eq("MMU config ownership keeps system non-quiescent", 0,
              dut.system_quiescent_o);
    if (dut.mmu_cfg_rsp_valid_o) break;
    tick(dut);
    if (waited == 99) fail("MMU configuration response timeout", 1, 0);
  }

  expect_eq("captured MMU config field remains valid", kStatusOk,
            dut.mmu_cfg_rsp_status_o);
  expect_eq("default context valid bit reads zero", 0,
            dut.mmu_cfg_rsp_rdata_o);
  tick(dut);
  expect_eq("MMU config response holds under backpressure", 1,
            dut.mmu_cfg_rsp_valid_o);
  expect_eq("younger maintenance remains blocked by held response", 0,
            dut.maint_cmd_ready_o);

  dut.mmu_cfg_rsp_ready_i = 1;
  tick(dut);
  eval_low(dut);
  expect_eq("MMU config response retires", 0, dut.mmu_cfg_rsp_valid_o);
  expect_eq("maintenance becomes eligible after config retirement", 1,
            dut.maint_cmd_ready_o);
  tick(dut);
  dut.maint_cmd_valid_i = 0;
  wait_for(dut, [&dut]() { return dut.maint_cpl_valid_o != 0; },
           "younger maintenance completion");
  expect_eq("younger maintenance completes successfully", kStatusOk,
            dut.maint_cpl_status_o);
  expect_eq("younger maintenance reports no fault", kFaultNone,
            dut.maint_cpl_fault_o);
  dut.maint_cpl_ready_i = 1;
  tick(dut);
  dut.maint_cpl_ready_i = 0;
  wait_for(dut,
           [&dut]() {
             return dut.maint_quiescent_o && dut.system_quiescent_o;
           },
           "younger maintenance retirement");
  expect_eq("MMU configuration does not access lower memory", reqs_before,
            dut.lower_req_count_o);
}

void fence_instruction_stream(Dut& dut) {
  wait_for(dut,
           [&dut]() {
             return dut.system_quiescent_o && dut.maint_quiescent_o &&
                    dut.maint_cmd_ready_o;
           },
           "post-program maintenance admission");

  const std::uint32_t reqs_before = dut.lower_req_count_o;
  const std::uint32_t rsps_before = dut.lower_rsp_count_o;
  dut.maint_cmd_valid_i = 1;
  dut.maint_cmd_op_i = kMaintFenceI;
  dut.maint_cmd_eaddr_i = 0;
  dut.maint_cmd_paddr_i = 0;
  dut.maint_cmd_addr_context_i = 0;
  dut.maint_cmd_asid_i = 0;
  dut.maint_cpl_ready_i = 0;
  // Present an MMU configuration request on the same cycle.  Global
  // maintenance owns this arbitration point; the stalled config request is
  // held until maintenance retires and is then accepted in program order.
  dut.mmu_cfg_valid_i = 1;
  dut.mmu_cfg_write_i = 0;
  dut.mmu_cfg_context_i = 0;
  dut.mmu_cfg_field_i = kMmuCfgValidField;
  dut.mmu_cfg_wdata_i = 0;
  dut.mmu_cfg_rsp_ready_i = 0;
  eval_low(dut);
  expect_eq("FENCE_I command accepted", 1, dut.maint_cmd_ready_o);
  expect_eq("same-cycle MMU config yields to maintenance", 0,
            dut.mmu_cfg_ready_o);
  tick(dut);
  dut.maint_cmd_valid_i = 0;

  std::uint32_t seen_steps = 0;
  for (unsigned waited = 0; waited < 30000; ++waited) {
    eval_low(dut);
    seen_steps |= std::uint32_t{1} << dut.maint_current_step_o;
    if (dut.maint_cpl_valid_o) break;
    tick(dut);
    if (waited == 29999) fail("FENCE_I completion timeout", 1, 0);
  }
  expect_true("FENCE_I observes client quiesce",
              seen_steps & (std::uint32_t{1} << kMaintStepQuiesce));
  expect_true("FENCE_I observes fabric drain",
              seen_steps & (std::uint32_t{1} << kMaintStepFabricDrain));
  expect_true("FENCE_I drains D-cache",
              seen_steps & (std::uint32_t{1} << kMaintStepDCacheDrain));
  expect_true("FENCE_I invalidates I-cache",
              seen_steps &
                  (std::uint32_t{1} << kMaintStepICacheInvalidate));
  expect_true("FENCE_I invalidates unified TLB",
              seen_steps & (std::uint32_t{1} << kMaintStepTlbInvalidate));
  expect_true("FENCE_I reaches completion",
              seen_steps & (std::uint32_t{1} << kMaintStepCompletion));
  expect_eq("FENCE_I completion status", kStatusOk,
            dut.maint_cpl_status_o);
  expect_eq("FENCE_I completion fault", kFaultNone,
            dut.maint_cpl_fault_o);
  expect_eq("stalled MMU config produces no early response", 0,
            dut.mmu_cfg_rsp_valid_o);
  expect_eq("maintenance remains busy while completion stalls", 1,
            dut.maint_busy_o);
  expect_eq("maintenance completion blocks launch", 0, dut.start_ready_o);
  tick(dut);
  expect_eq("maintenance completion holds under backpressure", 1,
            dut.maint_cpl_valid_o);
  expect_eq("maintenance completion status holds", kStatusOk,
            dut.maint_cpl_status_o);

  dut.maint_cpl_ready_i = 1;
  tick(dut);
  dut.maint_cpl_ready_i = 0;
  wait_for(dut, [&dut]() { return dut.mmu_cfg_ready_o != 0; },
           "post-maintenance MMU configuration admission");
  expect_eq("held MMU config keeps launch blocked", 0, dut.start_ready_o);
  tick(dut);
  dut.mmu_cfg_valid_i = 0;
  wait_for(dut, [&dut]() { return dut.mmu_cfg_rsp_valid_o != 0; },
           "post-maintenance MMU configuration response");
  expect_eq("post-maintenance MMU config status", kStatusOk,
            dut.mmu_cfg_rsp_status_o);
  expect_eq("post-maintenance MMU config read data", 0,
            dut.mmu_cfg_rsp_rdata_o);
  dut.mmu_cfg_rsp_ready_i = 1;
  tick(dut);
  wait_for(dut,
           [&dut]() {
             return !dut.maint_busy_o && dut.maint_quiescent_o &&
                    dut.system_quiescent_o && dut.start_ready_o;
           },
           "maintenance retirement and launch reopening");
  expect_eq("clean FENCE_I emits no lower request", reqs_before,
            dut.lower_req_count_o);
  expect_eq("clean FENCE_I emits no lower response", rsps_before,
            dut.lower_rsp_count_o);
}

void write_mmu_field(Dut& dut, std::uint8_t field, std::uint32_t value) {
  dut.mmu_cfg_context_i = 1;
  dut.mmu_cfg_field_i = field;
  dut.mmu_cfg_wdata_i = value;
  dut.mmu_cfg_write_i = 1;
  dut.mmu_cfg_rsp_ready_i = 0;
  dut.mmu_cfg_valid_i = 1;
  wait_for(dut, [&dut]() { return dut.mmu_cfg_ready_o != 0; },
           "Sv32 context configuration admission");
  tick(dut);
  dut.mmu_cfg_valid_i = 0;
  wait_for(dut, [&dut]() { return dut.mmu_cfg_rsp_valid_o != 0; },
           "Sv32 context configuration response");
  expect_eq("Sv32 configuration status", kStatusOk, dut.mmu_cfg_rsp_status_o);
  dut.mmu_cfg_rsp_ready_i = 1;
  tick(dut);
}

void invalidate_instruction_state(Dut& dut) {
  dut.maint_cmd_op_i = kMaintFenceI;
  dut.maint_cmd_valid_i = 1;
  dut.maint_cpl_ready_i = 0;
  wait_for(dut, [&dut]() { return dut.maint_cmd_ready_o != 0; },
           "instruction maintenance admission");
  tick(dut);
  dut.maint_cmd_valid_i = 0;
  wait_for(dut, [&dut]() { return dut.maint_cpl_valid_o != 0; },
           "instruction maintenance completion");
  expect_eq("instruction maintenance status", kStatusOk,
            dut.maint_cpl_status_o);
  expect_eq("instruction maintenance fault", kFaultNone,
            dut.maint_cpl_fault_o);
  dut.maint_cpl_ready_i = 1;
  tick(dut);
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "instruction maintenance drain");
}

void check_fault_record(const Dut& dut, unsigned cause, std::uint32_t eaddr,
                        std::uint64_t paddr, unsigned space, unsigned context,
                        const std::string& label) {
  expect_eq(label + " diagnosis valid", 1, dut.ifetch_fault_valid_o);
  expect_eq(label + " cause", cause, dut.ifetch_fault_cause_o);
  expect_eq(label + " effective address", eaddr, dut.ifetch_fault_eaddr_o);
  expect_eq(label + " physical diagnostic address", paddr,
            dut.ifetch_fault_paddr_o);
  expect_eq(label + " address space", space, dut.ifetch_fault_addr_space_o);
  expect_eq(label + " accepted address context", context,
            dut.ifetch_fault_addr_context_o);
}

void faulting_launch(Dut& dut, unsigned cause, std::uint32_t pc,
                     std::uint64_t fault_paddr, unsigned space,
                     unsigned context, unsigned expected_ptw_reads,
                     unsigned expected_lower_reads, const std::string& label) {
  const auto ptw_before = dut.page_table_read_count_o;
  const auto lower_before = dut.lower_read_req_count_o;
  const auto writes_before = dut.lower_write_req_count_o;
  launch(dut, 1, 0x90, pc, space, context);
  const Run run = run_program(dut);
  expect_eq(label + " failed terminal", 1, run.failed);
  expect_eq(label + " no successful END", 0, run.done);
  expect_eq(label + " program error", 1, run.error);
  expect_eq(label + " no partial instruction issued", 0, run.completions.size());
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           label + " drain");
  expect_eq(label + " PTW traffic", expected_ptw_reads,
            dut.page_table_read_count_o - ptw_before);
  expect_eq(label + " lower read traffic", expected_lower_reads,
            dut.lower_read_req_count_o - lower_before);
  expect_eq(label + " no memory side effects", writes_before,
            dut.lower_write_req_count_o);
  check_fault_record(dut, cause, pc, fault_paddr, space, context, label);

  // Clearing transport diagnostics must not erase the host's first-fault
  // record.  Mutating launch pins while idle is not a new launch either.
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  dut.start_pc_i = 0xfeed0000;
  dut.start_ifetch_addr_space_i = 0;
  dut.start_ifetch_addr_context_i = 0xee;
  for (unsigned hold = 0; hold < 3; ++hold) {
    tick(dut);
    check_fault_record(dut, cause, pc, fault_paddr, space, context,
                       label + " retained");
  }
  expect_eq(label + " lower ownership balanced", dut.lower_req_count_o,
            dut.lower_rsp_count_o);
  expect_eq(label + " no I-side protocol violation", 0,
            dut.ifetch_path_protocol_error_o);
}

void translated_fetch_and_faults(
    Dut& dut, const std::vector<std::uint32_t>& program,
    const std::vector<std::uint32_t>& redirect_prefix,
    const std::array<std::uint8_t, kVectorBytes>& input,
    const std::array<std::uint8_t, kVectorBytes>& expected) {
  // VA 0x00400020 -> root[1] -> L0[0] -> PA 0x00000020.
  // Real PTW reads bypass region policy; the executable I-side must still
  // pass its final-physical execute permission check after translation.
  init_word(dut, kRootEntry, (3U << 10) | 1U);
  init_word(dut, kLeafEntry, kExecutablePte);
  write_mmu_field(dut, 0, 0);  // configure while invalid
  write_mmu_field(dut, 1, 1);  // Sv32
  write_mmu_field(dut, 2, 2);  // root PPN
  write_mmu_field(dut, 3, 7);  // ASID
  write_mmu_field(dut, 4, 0);  // U privilege
  write_mmu_field(dut, 7, 1);  // allow fetch
  write_mmu_field(dut, 0, 1);
  invalidate_instruction_state(dut);

  const auto ptw_before = dut.page_table_read_count_o;
  const auto misses_before = icache_misses;
  launch(dut, program.size(), 0x60, kVirtualPc, kAddrSpaceTranslated, 1);
  check_run(run_program(dut), 0x60, "Sv32 translated branch program");
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "translated program drain");
  expect_eq("real two-level Sv32 walk", 2,
            dut.page_table_read_count_o - ptw_before);
  expect_eq("translated program refills physical instruction lines", 2,
            icache_misses - misses_before);
  expect_eq("translated END retains virtual PC",
            kVirtualPc + 4 * (program.size() - 1), dut.program_terminal_pc_o);
  expect_eq("successful translation has no IFetch diagnosis", 0,
            dut.ifetch_fault_valid_o);
  check_memory_image(dut, input, expected, "translated execution");

  const auto warm_ptw = dut.page_table_read_count_o;
  const auto warm_misses = icache_misses;
  launch(dut, program.size(), 0x80, kVirtualPc, kAddrSpaceTranslated, 1);
  check_run(run_program(dut), 0x80, "warm iTLB translated program");
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "warm translated program drain");
  expect_eq("warm iTLB avoids PTW lower traffic", warm_ptw,
            dut.page_table_read_count_o);
  expect_eq("warm physical I-cache avoids refill", warm_misses, icache_misses);

  faulting_launch(dut, 3, kVirtualPc, 0, kAddrSpaceTranslated, 0xfe,
                   0, 0, "invalid translation context");
  write_mmu_field(dut, 7, 0);
  faulting_launch(dut, 2, kVirtualPc, 0, kAddrSpaceTranslated, 1,
                   0, 0, "context disallows fetch");
  write_mmu_field(dut, 7, 1);

  init_word(dut, kLeafEntry, 0);  // invalid leaf
  invalidate_instruction_state(dut);
  faulting_launch(dut, 1, kVirtualPc, 0, kAddrSpaceTranslated, 1,
                   2, 2, "unmapped instruction page");

  init_word(dut, kLeafEntry, 0x53);  // V | R | U | A, no X
  invalidate_instruction_state(dut);
  faulting_launch(dut, 2, kVirtualPc, 0, kAddrSpaceTranslated, 1,
                   2, 2, "non-executable PTE");

  init_word(dut, kLeafEntry, (1U << 10) | kExecutablePte);
  invalidate_instruction_state(dut);
  faulting_launch(dut, 2, kVirtualPc, 0x1020, kAddrSpaceTranslated, 1,
                   2, 2, "physical region overrides executable PTE");

  // The region permits this page but the lower SRAM has no target there.
  // eaddr identifies the requested word; paddr identifies the failed refill
  // beat and intentionally need not have the same low address bits.
  init_word(dut, kLeafEntry, (4U << 10) | kExecutablePte);
  invalidate_instruction_state(dut);
  faulting_launch(dut, 3, kVirtualPc + 4, 0x4020, kAddrSpaceTranslated, 1,
                   2, 3, "lower target rejects instruction refill");

  init_word(dut, kLeafEntry, kExecutablePte);
  invalidate_instruction_state(dut);
  expect_eq("maintenance preserves diagnosis until a new launch", 1,
            dut.ifetch_fault_valid_o);
  launch(dut, program.size(), 0xa0, kVirtualPc, kAddrSpaceTranslated, 1);
  check_run(run_program(dut), 0xa0, "recovery without reset");
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "recovered program drain");
  check_memory_image(dut, input, expected, "recovered execution");
  expect_eq("new successful launch leaves no old diagnosis", 0,
            dut.ifetch_fault_valid_o);
  expect_eq("recovery leaves no transport error", 0, dut.protocol_error_o);

  // A sequential fetch fault may already have been consumed when an older
  // branch eventually executes. Its redirect cancels that path's diagnosis
  // just as it cancels source_store_fault and transport_failure.
  expect_eq("redirect prefix occupies exactly one bundle", 4,
            redirect_prefix.size());
  for (unsigned word = 0; word < redirect_prefix.size(); ++word)
    init_word(dut, 0xff0 + 4 * word, redirect_prefix[word]);
  init_word(dut, 0, program.back());  // END at translated target's PA 0
  init_word(dut, kLeafEntry + 4, 0);  // sequential VA page is unmapped
  init_word(dut, kLeafEntry + 8, kExecutablePte);  // target maps to PA page 0
  invalidate_instruction_state(dut);
  constexpr std::uint32_t redirect_start = 0x00400ff0;
  constexpr std::uint32_t redirect_target = 0x00402000;
  dut.action_cpl_ready_i = 0;
  launch(dut, (redirect_target + 4 - redirect_start) / 4, 0xc0,
         redirect_start, kAddrSpaceTranslated, 1);
  wait_for(dut, [&dut]() { return dut.ifetch_fault_valid_o != 0; },
           "sequential fault consumed behind an older stalled action");
  expect_eq("older action prevents premature failure", 1, dut.program_active_o);
  expect_eq("older completion is held", 1, dut.action_cpl_valid_o);
  expect_eq("older held action tag", 0xc0, dut.action_cpl_tag_o);
  check_fault_record(dut, 1, 0x00401000, 0, kAddrSpaceTranslated, 1,
                     "provisional sequential-path fault");
  const Run redirected = run_program(dut);
  expect_eq("redirected program reaches END", 1, redirected.done);
  expect_eq("discarded fault does not fail program", 0, redirected.failed);
  expect_eq("only LI, J and target END execute", 3,
            redirected.completions.size());
  for (unsigned index = 0; index < redirected.completions.size(); ++index)
    check_completion(redirected.completions[index], kControl, 0xc0 + index,
                     0, index == 2, "redirect recovery action");
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "redirect recovery drain");
  expect_eq("committed redirect clears consumed stale diagnosis", 0,
            dut.ifetch_fault_valid_o);
  expect_eq("redirected target terminal PC", redirect_target,
            dut.program_terminal_pc_o);
  expect_eq("discarded transport failure leaves no final error", 0,
            dut.program_error_o);
  expect_eq("redirect recovery has no final protocol error", 0,
            dut.protocol_error_o);

  faulting_launch(dut, 2, 0x1020, 0x1020, kAddrSpacePhysical, 0x77,
                   0, 0, "physical non-executable page");
  reset(dut, program.size());
  expect_eq("reset clears IFetch diagnosis valid", 0, dut.ifetch_fault_valid_o);
  expect_eq("reset clears IFetch diagnosis cause", 0, dut.ifetch_fault_cause_o);
  expect_eq("reset clears IFetch diagnosis eaddr", 0, dut.ifetch_fault_eaddr_o);
  expect_eq("reset clears IFetch diagnosis paddr", 0, dut.ifetch_fault_paddr_o);
}

}  // namespace

double sc_time_stamp() { return static_cast<double>(cycles); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 3) {
    std::cerr << "usage: " << argv[0] << " PROGRAM.hex REDIRECT_PREFIX.hex\n";
    return 2;
  }

  const std::vector<std::uint32_t> program = read_hex(argv[1]);
  const std::vector<std::uint32_t> redirect_prefix = read_hex(argv[2]);
  if (program.size() != 15) {
    std::cerr << "physical-memory branch program currently encodes to 15 "
                 "words\n";
    return 1;
  }

  std::array<std::uint8_t, kVectorBytes> input{};
  std::array<std::uint8_t, kVectorBytes> expected{};
  const std::array<std::uint8_t, 16> pattern = {
      0,   1,   39,  40,  64,  127, 128, 192,
      200, 214, 215, 216, 217, 240, 254, 255};
  for (unsigned index = 0; index < kVectorBytes; ++index) {
    input[index] = pattern[index % pattern.size()];
    expected[index] = reference(input[index]);
  }

  Dut dut;
  reset(dut, program.size());
  install_image(dut, program, input);
  expect_eq("image installation causes no lower transaction", 0,
            dut.lower_req_count_o);

  const std::uint64_t first_i_miss_start = icache_misses;
  const std::uint32_t first_lower_start = dut.lower_req_count_o;
  launch(dut, program.size(), 0x10);
  check_maintenance_gate_while_active(dut);
  Run first = run_program(dut);
  check_run(first, 0x10, "first run");
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "first-run memory-system quiescence");
  check_memory_image(dut, input, expected, "first run");

  expect_eq("cold run has two I-cache line misses", 2,
            icache_misses - first_i_miss_start);
  expect_eq("cold run issues 44 shared-lower beats", 44,
            dut.lower_req_count_o - first_lower_start);
  expect_eq("cold run reads two code and two data cache lines", 32,
            dut.lower_read_req_count_o);
  expect_eq("cold run writes twelve output beats", 12,
            dut.lower_write_req_count_o);
  expect_eq("every cold-run lower request has a response",
            dut.lower_req_count_o, dut.lower_rsp_count_o);

  exercise_mmu_cfg_ownership(dut);
  fence_instruction_stream(dut);
  const std::uint64_t second_i_miss_start = icache_misses;
  const std::uint32_t second_lower_start = dut.lower_req_count_o;
  const std::uint32_t second_lower_read_start = dut.lower_read_req_count_o;
  const std::uint32_t second_lower_write_start = dut.lower_write_req_count_o;

  launch(dut, program.size(), 0x40);
  Run second = run_program(dut);
  check_run(second, 0x40, "second run");
  wait_for(dut, [&dut]() { return dut.system_quiescent_o != 0; },
           "second-run memory-system quiescence");
  check_memory_image(dut, input, expected, "second run");

  expect_eq("post-invalidate rerun misses both instruction lines", 2,
            icache_misses - second_i_miss_start);
  expect_eq("warm-D rerun issues 28 shared-lower beats", 28,
            dut.lower_req_count_o - second_lower_start);
  expect_eq("warm-D rerun reads only two instruction lines", 16,
            dut.lower_read_req_count_o - second_lower_read_start);
  expect_eq("rerun writes twelve output beats", 12,
            dut.lower_write_req_count_o - second_lower_write_start);
  expect_eq("every final lower request has a response",
            dut.lower_req_count_o, dut.lower_rsp_count_o);

  expect_true("I-cache also records hit traffic", icache_hits > 0);
  expect_eq("first run has two D-cache read misses", 2,
            dcache_read_misses);
  expect_true("second run reuses warm D-cache input", dcache_read_hits >= 12);
  expect_eq("write-no-allocate produces no D-cache write hits", 0,
            dcache_write_hits);
  expect_eq("two runs issue twenty-four D-cache write misses", 24,
            dcache_write_misses);
  expect_eq("final END leaves fetch halted", 1, dut.program_halted_o);
  expect_eq("integration reports no protocol error", 0,
            dut.protocol_error_o);
  expect_eq("fetch path reports no protocol error", 0,
            dut.fetch_protocol_error_o);
  expect_eq("cluster reports no protocol error", 0,
            dut.cluster_protocol_error_o);
  expect_eq("I path reports no protocol error", 0,
            dut.ifetch_path_protocol_error_o);
  expect_eq("D path reports no protocol error", 0,
            dut.dmem_path_protocol_error_o);
  expect_eq("maintenance reports no protocol error", 0,
            dut.maint_protocol_error_o);

  std::cout << "vsp_uword_memory_system_wrapper_tb: " << checks
            << " product integration checks passed in " << cycles
            << " cycles; " << dut.lower_req_count_o
            << " shared-lower beats, " << icache_misses
            << " I-cache misses\n";
  const auto extended_checks = checks;
  const auto extended_cycles = cycles;
  translated_fetch_and_faults(dut, program, redirect_prefix, input, expected);
  std::cout << "Sv32/IFetch diagnosis: " << checks - extended_checks
            << " additional checks passed in " << cycles - extended_cycles
            << " cycles (" << checks << " total checks)\n";
  return 0;
}
