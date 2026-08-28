#include "Vvsp_uword_program_frontend.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePc = 0x20;
constexpr uint32_t kFullEndPc = 0x48;
constexpr uint8_t kExec = 0;
constexpr uint8_t kMemory = 1;
constexpr uint8_t kControl = 2;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& what, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << what << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& what, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(what, expected, actual);
}

void eval_low(Vvsp_uword_program_frontend& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_uword_program_frontend& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_uword_program_frontend& dut) {
  dut.store_write_valid_i = 0;
  dut.store_write_pc_i = 0;
  dut.store_write_data_i = 0;
  dut.start_valid_i = 0;
  dut.start_pc_i = 0;
  dut.end_pc_i = 0;
  dut.record_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_uword_program_frontend& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 3; ++cycle) tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  expect_eq("record invalid after reset", 0, dut.record_valid_o);
  expect_eq("frontend idle after reset", 0, dut.running_o);
  expect_eq("delivery done clear after reset", 0,
            dut.record_delivery_done_o);
}

std::vector<uint32_t> read_hex(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot open generated hex: " + path);
  std::vector<uint32_t> words;
  std::string line;
  while (std::getline(input, line)) {
    if (line.empty()) continue;
    words.push_back(static_cast<uint32_t>(std::stoul(line, nullptr, 16)));
  }
  return words;
}

void program_store(Vvsp_uword_program_frontend& dut,
                   const std::vector<uint32_t>& words) {
  for (size_t index = 0; index < words.size(); ++index) {
    dut.store_write_valid_i = 1;
    dut.store_write_pc_i = kBasePc + static_cast<uint32_t>(4 * index);
    dut.store_write_data_i = words[index];
    eval_low(dut);
    expect_eq("program write ready", 1, dut.store_write_ready_o);
    tick(dut);
  }
  dut.store_write_valid_i = 0;
  eval_low(dut);
  expect_eq("programming caused no error", 0, dut.protocol_error_o);
}

void start(Vvsp_uword_program_frontend& dut, uint32_t start_pc,
           uint32_t end_pc) {
  dut.start_valid_i = 1;
  dut.start_pc_i = start_pc;
  dut.end_pc_i = end_pc;
  eval_low(dut);
  expect_eq("start ready", 1, dut.start_ready_o);
  tick(dut);
  dut.start_valid_i = 0;
}

struct ExpectedRecord {
  uint8_t dispatch_class;
  uint32_t pc;
  uint8_t required;
  uint8_t present;
  bool truncated;
  std::array<uint32_t, 4> words;
};

struct Snapshot {
  uint8_t dispatch_class;
  uint8_t major_defined;
  uint32_t pc;
  uint8_t required;
  uint8_t present;
  uint8_t truncated;
  std::array<uint32_t, 4> words;
};

Snapshot snapshot(const Vvsp_uword_program_frontend& dut) {
  Snapshot value{};
  value.dispatch_class = dut.record_class_o;
  value.major_defined = dut.record_major_defined_o;
  value.pc = dut.record_start_pc_o;
  value.required = dut.record_word_count_o;
  value.present = dut.record_present_word_count_o;
  value.truncated = dut.record_truncated_o;
  for (int index = 0; index < 4; ++index)
    value.words[index] = dut.record_words_o[index];
  return value;
}

void check_snapshot(const Snapshot& actual, const ExpectedRecord& expected,
                    const std::string& prefix) {
  expect_eq(prefix + " class", expected.dispatch_class,
            actual.dispatch_class);
  expect_eq(prefix + " major defined", 1, actual.major_defined);
  expect_eq(prefix + " PC", expected.pc, actual.pc);
  expect_eq(prefix + " required count", expected.required, actual.required);
  expect_eq(prefix + " present count", expected.present, actual.present);
  expect_eq(prefix + " truncated", expected.truncated, actual.truncated);
  for (int index = 0; index < 4; ++index)
    expect_eq(prefix + " word " + std::to_string(index),
              expected.words[index], actual.words[index]);
}

void check_stable(const Snapshot& before, const Snapshot& after,
                  const std::string& prefix) {
  expect_eq(prefix + " class stable", before.dispatch_class,
            after.dispatch_class);
  expect_eq(prefix + " defined stable", before.major_defined,
            after.major_defined);
  expect_eq(prefix + " PC stable", before.pc, after.pc);
  expect_eq(prefix + " required stable", before.required, after.required);
  expect_eq(prefix + " present stable", before.present, after.present);
  expect_eq(prefix + " truncated stable", before.truncated, after.truncated);
  for (int index = 0; index < 4; ++index)
    expect_eq(prefix + " payload stable " + std::to_string(index),
              before.words[index], after.words[index]);
}

std::vector<uint32_t> run(Vvsp_uword_program_frontend& dut, uint32_t end_pc,
                          const std::vector<ExpectedRecord>& expected) {
  start(dut, kBasePc, end_pc);
  std::vector<uint32_t> observed_pcs = {dut.current_pc_o};
  uint32_t last_pc = dut.current_pc_o;
  size_t record_index = 0;
  int done_pulses = 0;

  for (int cycle = 0; cycle < 300 && done_pulses == 0; ++cycle) {
    eval_low(dut);
    expect_eq("run has no protocol error", 0, dut.protocol_error_o);
    expect_eq("run has no store fault", 0, dut.store_fault_o);
    if (dut.record_valid_o) {
      if (record_index >= expected.size())
        fail("unexpected extra record", expected.size(), record_index + 1);
      const Snapshot held = snapshot(dut);
      check_snapshot(held, expected[record_index],
                     "record " + std::to_string(record_index));

      const int stall_cycles = 1 + static_cast<int>(record_index % 3);
      for (int stall = 0; stall < stall_cycles; ++stall) {
        dut.record_ready_i = 0;
        tick(dut);
        expect_eq("stalled record remains valid", 1, dut.record_valid_o);
        check_stable(held, snapshot(dut), "stalled record");
      }

      dut.record_ready_i = 1;
      eval_low(dut);
      check_stable(held, snapshot(dut), "record before handshake");
      tick(dut);
      dut.record_ready_i = 0;
      ++record_index;
    } else {
      tick(dut);
    }

    if (dut.current_pc_o != last_pc) {
      observed_pcs.push_back(dut.current_pc_o);
      last_pc = dut.current_pc_o;
    }
    if (dut.record_delivery_done_o) ++done_pulses;
  }

  expect_eq("all records observed", expected.size(), record_index);
  expect_eq("exactly one done pulse", 1, done_pulses);
  expect_eq("frontend stopped", 0, dut.running_o);
  tick(dut);
  expect_eq("delivery done pulse cleared", 0,
            dut.record_delivery_done_o);
  return observed_pcs;
}

std::vector<ExpectedRecord> full_records(const std::vector<uint32_t>& words) {
  return {
      {kExec, 0x20, 1, 1, false, {words[0], 0, 0, 0}},
      {kExec, 0x24, 2, 2, false, {words[1], words[2], 0, 0}},
      {kMemory, 0x2c, 3, 3, false,
       {words[3], words[4], words[5], 0}},
      {kExec, 0x38, 1, 1, false, {words[6], 0, 0, 0}},
      {kExec, 0x3c, 2, 2, false, {words[7], words[8], 0, 0}},
      {kControl, 0x44, 1, 1, false, {words[9], 0, 0, 0}},
  };
}

void clear_protocol_error(Vvsp_uword_program_frontend& dut) {
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  eval_low(dut);
  expect_eq("protocol error cleared", 0, dut.protocol_error_o);
  expect_eq("store fault cleared", 0, dut.store_fault_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 2) {
    std::cerr << "usage: " << argv[0] << " PROGRAM.hex\n";
    return 2;
  }

  const std::vector<uint32_t> words = read_hex(argv[1]);
  const std::vector<uint32_t> exact = {
      0x17822210U, 0x10020430U, 0x00000007U, 0xb8000015U,
      0x60000000U, 0xc0000000U, 0x10046810U, 0x18080a30U,
      0x00000003U, 0xc0000000U};
  if (words != exact) {
    std::cerr << "generated assembler image differs from independent golden\n";
    return 1;
  }

  Vvsp_uword_program_frontend dut;
  reset(dut);
  program_store(dut, words);

  const auto normal_pcs = run(dut, kFullEndPc, full_records(words));
  const std::vector<uint32_t> expected_pcs = {0x20, 0x30, 0x40, 0x48};
  expect_eq("normal PC transition count", expected_pcs.size(),
            normal_pcs.size());
  for (size_t index = 0; index < expected_pcs.size(); ++index)
    expect_eq("normal PC transition", expected_pcs[index], normal_pcs[index]);

  // Ending at 0x30 leaves only the MEMORY header from the first bundle.
  reset(dut);
  const std::vector<ExpectedRecord> truncated = {
      {kExec, 0x20, 1, 1, false, {words[0], 0, 0, 0}},
      {kExec, 0x24, 2, 2, false, {words[1], words[2], 0, 0}},
      {kMemory, 0x2c, 3, 1, true, {words[3], 0, 0, 0}},
  };
  const auto truncated_pcs = run(dut, 0x30, truncated);
  expect_eq("truncated source ended at exclusive PC", 0x30,
            truncated_pcs.back());

  // Reset while a record is visible and blocked, then replay from start. The
  // SRAM-like control-store contents survive reset; all flow state does not.
  reset(dut);
  start(dut, kBasePc, kFullEndPc);
  for (int cycle = 0; cycle < 40 && !dut.record_valid_o; ++cycle) tick(dut);
  expect_eq("record visible before live reset", 1, dut.record_valid_o);
  const Snapshot held = snapshot(dut);
  for (int cycle = 0; cycle < 2; ++cycle) {
    tick(dut);
    check_stable(held, snapshot(dut), "pre-reset stall");
  }
  dut.rst_ni = 0;
  tick(dut);
  expect_eq("reset drops record", 0, dut.record_valid_o);
  expect_eq("reset drops running", 0, dut.running_o);
  dut.rst_ni = 1;
  tick(dut);
  run(dut, kFullEndPc, full_records(words));

  // Empty ranges complete without reading the control store.
  reset(dut);
  start(dut, 0x20, 0x20);
  expect_eq("empty range delivery done", 1,
            dut.record_delivery_done_o);
  expect_eq("empty range idle", 0, dut.running_o);
  tick(dut);
  expect_eq("empty delivery pulse cleared", 0,
            dut.record_delivery_done_o);

  // Misalignment is a source protocol error and never starts the stream.
  start(dut, 0x21, 0x24);
  expect_eq("misaligned launch error", 1, dut.protocol_error_o);
  expect_eq("misaligned launch inactive", 0, dut.running_o);
  clear_protocol_error(dut);

  start(dut, 0x20, 0x23);
  expect_eq("misaligned end error", 1, dut.protocol_error_o);
  expect_eq("misaligned end inactive", 0, dut.running_o);
  clear_protocol_error(dut);

  start(dut, 0x24, 0x20);
  expect_eq("descending range error", 1, dut.protocol_error_o);
  expect_eq("descending range inactive", 0, dut.running_o);
  clear_protocol_error(dut);

  // A full-width PC outside the local store window faults; it does not alias
  // through low address bits into the programmed image.
  start(dut, 0x80, 0x84);
  for (int cycle = 0; cycle < 30 && !dut.store_fault_o; ++cycle) tick(dut);
  expect_eq("out-of-window store fault", 1, dut.store_fault_o);
  expect_eq("fault is not record delivery completion", 0,
            dut.record_delivery_done_o);
  expect_eq("faulted source inactive", 0, dut.running_o);
  clear_protocol_error(dut);

  // Invalid programming addresses are accepted as an ordered diagnostic and
  // never modify an aliased low word.
  dut.store_write_valid_i = 1;
  dut.store_write_pc_i = 0x1c;
  dut.store_write_data_i = 0xdeadbeefU;
  eval_low(dut);
  expect_eq("invalid write accepted for diagnosis", 1,
            dut.store_write_ready_o);
  tick(dut);
  dut.store_write_valid_i = 0;
  expect_eq("invalid write protocol error", 1, dut.protocol_error_o);
  clear_protocol_error(dut);

  dut.final();
  std::cout << "vsp_uword_program_frontend_tb: " << std::dec << checks
            << " PC, framing, backpressure, reset, EOF and fault checks passed\n";
  return 0;
}
