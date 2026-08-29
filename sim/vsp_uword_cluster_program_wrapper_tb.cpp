#include "Vvsp_uword_cluster_program_wrapper.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePc = 0x20;
constexpr uint8_t kExec = 0;
constexpr uint8_t kMemory = 1;
constexpr uint8_t kControl = 2;
constexpr uint8_t kStatusOk = 0;
constexpr uint8_t kStatusDecode = 1;
constexpr uint8_t kBadFormat = 1;
constexpr uint8_t kBadSubop = 2;
constexpr uint8_t kBadExtension = 4;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& what, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << what << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& what, uint64_t expected,
               uint64_t actual) {
  ++checks;
  if (expected != actual) fail(what, expected, actual);
}

void eval_low(Vvsp_uword_cluster_program_wrapper& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_uword_cluster_program_wrapper& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_uword_cluster_program_wrapper& dut) {
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
  dut.exec_result_ready_i = 1;
  dut.dmem_req_ready_i = 1;
  dut.dmem_rsp_valid_i = 0;
  dut.dmem_rsp_rdata_i = 0;
  dut.dmem_rsp_fault_cause_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_uword_cluster_program_wrapper& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 3; ++cycle) tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  expect_eq("reset program inactive", 0, dut.program_active_o);
  expect_eq("reset program error clear", 0, dut.program_error_o);
}

std::vector<uint32_t> read_hex(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot open generated hex: " + path);
  std::vector<uint32_t> words;
  std::string line;
  while (std::getline(input, line)) {
    if (!line.empty())
      words.push_back(static_cast<uint32_t>(std::stoul(line, nullptr, 16)));
  }
  return words;
}

void wait_start_ready(Vvsp_uword_cluster_program_wrapper& dut) {
  for (int cycle = 0; cycle < 80; ++cycle) {
    eval_low(dut);
    if (dut.start_ready_o) return;
    tick(dut);
  }
  fail("start ready timeout", 1, dut.start_ready_o);
}

void program_store_at(Vvsp_uword_cluster_program_wrapper& dut,
                      uint32_t base_pc,
                      const std::vector<uint32_t>& words) {
  for (size_t index = 0; index < words.size(); ++index) {
    for (int cycle = 0; cycle < 80; ++cycle) {
      dut.store_write_valid_i = 1;
      dut.store_write_pc_i = base_pc + static_cast<uint32_t>(4 * index);
      dut.store_write_data_i = words[index];
      eval_low(dut);
      if (dut.store_write_ready_o) break;
      tick(dut);
      if (cycle == 79) fail("store write ready timeout", 1, 0);
    }
    tick(dut);
    dut.store_write_valid_i = 0;
  }
}

void program_store(Vvsp_uword_cluster_program_wrapper& dut,
                   const std::vector<uint32_t>& words) {
  program_store_at(dut, kBasePc, words);
}

void launch_range(Vvsp_uword_cluster_program_wrapper& dut,
                  uint32_t start_pc, uint32_t end_pc, uint8_t context,
                  uint8_t group_mask, uint8_t tag_seed) {
  wait_start_ready(dut);
  dut.start_valid_i = 1;
  dut.start_pc_i = start_pc;
  dut.end_pc_i = end_pc;
  dut.start_context_i = context;
  dut.start_group_mask_i = group_mask;
  dut.start_tag_seed_i = tag_seed;
  eval_low(dut);
  expect_eq("launch ready", 1, dut.start_ready_o);
  tick(dut);
  dut.start_valid_i = 0;

  // Prove that the launch envelope, rather than live input pins, owns every
  // later action.
  dut.start_context_i = context ^ 1U;
  dut.start_group_mask_i = 0xa;
  dut.start_tag_seed_i = 0xee;
}

void launch(Vvsp_uword_cluster_program_wrapper& dut, uint32_t end_pc,
            uint8_t context, uint8_t group_mask, uint8_t tag_seed) {
  launch_range(dut, kBasePc, end_pc, context, group_mask, tag_seed);
}

struct Completion {
  uint8_t action_class;
  uint8_t context;
  uint8_t tag;
  uint8_t group_mask;
  uint8_t status;
  uint8_t decode_error;
  bool end;
};

struct Result {
  uint8_t group;
  uint8_t context;
  uint8_t tag;
  uint32_t narrow;
  uint8_t narrow_mask;
};

struct Run {
  bool done = false;
  bool failed = false;
  bool error = false;
  uint64_t dmem_requests = 0;
  std::vector<Completion> completions;
  std::vector<Result> results;
};

Run run_until_terminal(Vvsp_uword_cluster_program_wrapper& dut) {
  Run run;
  for (int cycle = 0; cycle < 800; ++cycle) {
    // Exercise completion backpressure without changing stream order.
    dut.action_cpl_ready_i = (cycle % 5) != 2;
    dut.exec_result_ready_i = (cycle % 4) != 1;
    eval_low(dut);

    if (dut.action_cpl_valid_o && dut.action_cpl_ready_i) {
      run.completions.push_back(
          {static_cast<uint8_t>(dut.action_cpl_class_o),
           static_cast<uint8_t>(dut.action_cpl_context_o),
           static_cast<uint8_t>(dut.action_cpl_tag_o),
           static_cast<uint8_t>(dut.action_cpl_group_mask_o),
           static_cast<uint8_t>(dut.action_cpl_status_o),
           static_cast<uint8_t>(dut.action_cpl_decode_error_o),
           static_cast<bool>(dut.action_cpl_end_o)});
    }
    if (dut.exec_result_valid_o && dut.exec_result_ready_i) {
      run.results.push_back(
          {static_cast<uint8_t>(dut.exec_result_group_o),
           static_cast<uint8_t>(dut.exec_result_context_o),
           static_cast<uint8_t>(dut.exec_result_tag_o),
           static_cast<uint32_t>(dut.exec_result_narrow_o),
           static_cast<uint8_t>(dut.exec_result_narrow_mask_o)});
    }
    if (dut.dmem_req_valid_o && dut.dmem_req_ready_i)
      ++run.dmem_requests;
    if (dut.program_done_o) run.done = true;
    if (dut.program_failed_o) run.failed = true;
    run.error = dut.program_error_o;

    if ((run.done || run.failed) && !dut.program_active_o) {
      tick(dut);
      dut.action_cpl_ready_i = 1;
      dut.exec_result_ready_i = 1;
      return run;
    }
    tick(dut);
  }
  fail("program terminal timeout", 1, 0);
}

void check_completion(const Completion& actual, uint8_t action_class,
                      uint8_t context, uint8_t tag, uint8_t group_mask,
                      uint8_t status, uint8_t decode_error, bool end,
                      const std::string& name) {
  expect_eq(name + " class", action_class, actual.action_class);
  expect_eq(name + " context", context, actual.context);
  expect_eq(name + " tag", tag, actual.tag);
  expect_eq(name + " group mask", group_mask, actual.group_mask);
  expect_eq(name + " status", status, actual.status);
  expect_eq(name + " decode error", decode_error, actual.decode_error);
  expect_eq(name + " END", end, actual.end);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 2) {
    std::cerr << "usage: " << argv[0] << " PROGRAM.hex\n";
    return 2;
  }

  const std::vector<uint32_t> program = read_hex(argv[1]);
  const std::vector<uint32_t> golden = {
      0x17822210U, 0x10020430U, 0x00000007U, 0xd48c6004U,
      0xc0000000U};
  if (program != golden) {
    std::cerr << "generated executable example differs from golden\n";
    return 1;
  }

  Vvsp_uword_cluster_program_wrapper dut;
  reset(dut);

  program_store(dut, program);
  launch(dut, kBasePc + static_cast<uint32_t>(4 * program.size()),
         1, 0x5, 0x40);
  Run normal = run_until_terminal(dut);
  expect_eq("normal completed", 1, normal.done);
  expect_eq("normal did not fail", 0, normal.failed);
  expect_eq("normal has no accumulated error", 0, normal.error);
  expect_eq("normal completion count", 4, normal.completions.size());
  for (size_t index = 0; index < 3; ++index) {
    check_completion(normal.completions[index], kExec, 1,
                     static_cast<uint8_t>(0x40 + index), 0x5,
                     kStatusOk, 0, false,
                     "normal EXEC " + std::to_string(index));
  }
  check_completion(normal.completions[3], kControl, 1, 0x43, 0,
                   kStatusOk, 0, true, "normal END");
  expect_eq("normal exported two selected groups", 2,
            normal.results.size());
  for (const Result& result : normal.results) {
    expect_eq("result context captured", 1, result.context);
    expect_eq("route result tag", 0x42, result.tag);
    expect_eq("route result value", 0x07070707U, result.narrow);
    expect_eq("route result lane mask", 0xf, result.narrow_mask);
    expect_eq("result group belongs to mask", 1,
              result.group == 0 || result.group == 2);
  }
  expect_eq("normal issued no data-memory request", 0,
            normal.dmem_requests);

  // An exact END-looking word in an opaque MEMORY body is data, not a header.
  // The MEMORY parent rejects in order, then the following real END retires.
  const std::vector<uint32_t> opaque_memory = {
      0xb4000000U, 0xc0000000U, 0xc0000000U};
  program_store(dut, opaque_memory);
  launch(dut, kBasePc + 12, 0, 0x3, 0x60);
  Run memory = run_until_terminal(dut);
  expect_eq("opaque memory reaches later END", 1, memory.done);
  expect_eq("opaque memory does not terminal-fail", 0, memory.failed);
  expect_eq("opaque memory accumulates rejection", 1, memory.error);
  expect_eq("opaque memory completion count", 2, memory.completions.size());
  check_completion(memory.completions[0], kMemory, 0, 0x60, 0x3,
                   kStatusDecode, kBadFormat, false, "opaque MEMORY");
  check_completion(memory.completions[1], kControl, 0, 0x61, 0,
                   kStatusOk, 0, true, "opaque MEMORY following END");
  expect_eq("rejected memory issued no dmem request", 0,
            memory.dmem_requests);

  // C0000001 shares the CONTROL major but is not the canonical END word.
  const std::vector<uint32_t> other_control = {
      0xc0000001U, 0xc0000000U};
  program_store(dut, other_control);
  launch(dut, kBasePc + 8, 1, 0x1, 0x70);
  Run control = run_until_terminal(dut);
  expect_eq("other CONTROL reaches real END", 1, control.done);
  expect_eq("other CONTROL completion count", 2,
            control.completions.size());
  check_completion(control.completions[0], kControl, 1, 0x70, 0,
                   kStatusDecode, kBadSubop, false, "other CONTROL");
  check_completion(control.completions[1], kControl, 1, 0x71, 0,
                   kStatusOk, 0, true, "other CONTROL following END");

  // A base word whose extension lies beyond end_pc is emitted as a truncated
  // record, rejected in order, then closes as a missing-END failure.
  const std::vector<uint32_t> truncated = {0x10020430U};
  program_store(dut, truncated);
  launch(dut, kBasePc + 4, 0, 0xf, 0x80);
  Run short_exec = run_until_terminal(dut);
  expect_eq("truncated EXEC has no END completion", 0, short_exec.done);
  expect_eq("truncated EXEC fails drained program", 1, short_exec.failed);
  expect_eq("truncated EXEC completion count", 1,
            short_exec.completions.size());
  check_completion(short_exec.completions[0], kExec, 0, 0x80, 0xf,
                   kStatusDecode, kBadExtension, false,
                   "truncated EXEC");

  // A legal empty byte range contains no END and must fail rather than leave
  // the wrapper permanently active.
  launch(dut, kBasePc, 1, 0x5, 0x90);
  Run empty = run_until_terminal(dut);
  expect_eq("empty range not done", 0, empty.done);
  expect_eq("empty range fails", 1, empty.failed);
  expect_eq("empty range has no completion", 0, empty.completions.size());

  // END is required to be the final record in [start_pc,end_pc).  The early
  // END is rejected, younger words are drained without entering EXEC, and the
  // program reports failure.
  const std::vector<uint32_t> early_end = {
      0xc0000000U, 0xd48c6004U};
  program_store(dut, early_end);
  launch(dut, kBasePc + 8, 0, 0x5, 0xa0);
  Run early = run_until_terminal(dut);
  expect_eq("early END not successful", 0, early.done);
  expect_eq("early END fails", 1, early.failed);
  expect_eq("early END completion count", 1, early.completions.size());
  check_completion(early.completions[0], kControl, 0, 0xa0, 0,
                   kStatusDecode, kBadSubop, false, "early END");
  expect_eq("younger route after early END not executed", 0,
            early.results.size());

  // The local store ends at 0x60 in this test configuration.  Three complete
  // EXEC records at 0x50 precede a four-word MEMORY header at
  // 0x5c whose body would require a fetch at 0x60.  That fetch faults: all
  // three older records still retire in order, the incomplete tail is
  // aborted, and the frontend becomes restartable.
  const std::vector<uint32_t> faulting_tail = {
      0x17822210U, 0x17822210U, 0x17822210U, 0xbc000000U};
  program_store_at(dut, 0x50, faulting_tail);
  launch_range(dut, 0x50, 0x6c, 1, 0x4, 0xb0);
  Run fetch_fault = run_until_terminal(dut);
  expect_eq("cross-bundle fetch fault not done", 0, fetch_fault.done);
  expect_eq("cross-bundle fetch fault fails", 1, fetch_fault.failed);
  expect_eq("older complete actions survive fetch fault", 3,
            fetch_fault.completions.size());
  for (size_t index = 0; index < 3; ++index) {
    check_completion(fetch_fault.completions[index], kExec, 1,
                     static_cast<uint8_t>(0xb0 + index), 0x4,
                     kStatusOk, 0, false,
                     "pre-fault EXEC " + std::to_string(index));
  }

  const std::vector<uint32_t> end_only = {0xc0000000U};
  program_store(dut, end_only);
  launch(dut, kBasePc + 4, 0, 0x1, 0xc0);
  Run recovered = run_until_terminal(dut);
  expect_eq("restart after fetch fault completes", 1, recovered.done);
  expect_eq("restart after fetch fault does not fail", 0,
            recovered.failed);
  expect_eq("restart after fetch fault clears launch error", 0,
            recovered.error);
  expect_eq("restart END completion count", 1,
            recovered.completions.size());
  check_completion(recovered.completions[0], kControl, 0, 0xc0, 0,
                   kStatusOk, 0, true, "restart END");

  dut.final();
  std::cout << "vsp_uword_cluster_program_wrapper_tb: " << std::dec << checks
            << " executable-stream, END, rejection and drain checks passed\n";
  return 0;
}
