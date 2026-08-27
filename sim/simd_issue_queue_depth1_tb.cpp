#include "Vsimd_issue_queue.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

uint64_t checks = 0;

[[noreturn]] void fail(const char* field, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << field << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const char* field, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(field, expected, actual);
}

void tick(Vsimd_issue_queue& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vsimd_issue_queue& dut) {
  dut.enq_valid_i = 0;
  dut.enq_context_i = 0;
  dut.enq_tag_i = 0;
  dut.enq_uword_i = 0;
  dut.enq_resolved_i = 0;
  dut.enq_sched_meta_i = 0;
  dut.head_ready_i = 0;
}

void drive_entry(Vsimd_issue_queue& dut, uint8_t base) {
  dut.enq_valid_i = 1;
  dut.enq_context_i = 0;
  dut.enq_tag_i = base;
  dut.enq_uword_i = uint8_t(base + 1);
  dut.enq_resolved_i = uint8_t(base + 2);
  dut.enq_sched_meta_i = uint8_t(base + 3);
}

void expect_entry(Vsimd_issue_queue& dut, uint8_t base) {
  dut.eval();
  expect_eq("head valid", 1, dut.head_valid_o);
  expect_eq("occupancy", 1, dut.occupancy_o);
  expect_eq("full", 1, dut.full_o);
  expect_eq("tag", base, dut.head_tag_o);
  expect_eq("uword", uint8_t(base + 1), dut.head_uword_o);
  expect_eq("resolved", uint8_t(base + 2), dut.head_resolved_o);
  expect_eq("sched meta", uint8_t(base + 3), dut.head_sched_meta_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_issue_queue dut;
  clear_inputs(dut);

  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  clear_inputs(dut);
  dut.eval();
  expect_eq("empty after reset", 0, dut.head_valid_o);
  expect_eq("zero occupancy after reset", 0, dut.occupancy_o);

  // An empty queue never falls through even when its consumer is ready.
  drive_entry(dut, 0x10);
  dut.head_ready_i = 1;
  dut.eval();
  expect_eq("empty enqueue ready", 1, dut.enq_ready_o);
  expect_eq("no empty fallthrough", 0, dut.head_valid_o);
  tick(dut);
  expect_entry(dut, 0x10);

  // A full single-entry queue rejects a new entry when the old head stays.
  drive_entry(dut, 0x20);
  dut.head_ready_i = 0;
  dut.eval();
  expect_eq("full blocks enqueue", 0, dut.enq_ready_o);
  tick(dut);
  expect_entry(dut, 0x10);

  // With pop and push together, the old payload transfers before the edge and
  // the same physical cell contains the replacement after the edge.
  drive_entry(dut, 0x30);
  dut.head_ready_i = 1;
  dut.eval();
  expect_eq("full replacement ready", 1, dut.enq_ready_o);
  expect_entry(dut, 0x10);
  tick(dut);
  expect_entry(dut, 0x30);

  // A pop without replacement empties the queue and zeros its visible head.
  clear_inputs(dut);
  dut.head_ready_i = 1;
  tick(dut);
  clear_inputs(dut);
  dut.eval();
  expect_eq("empty after pop", 0, dut.head_valid_o);
  expect_eq("zero occupancy after pop", 0, dut.occupancy_o);
  expect_eq("zero head after pop", 0, dut.head_uword_o);

  // Reset with a live entry clears ownership, and the one physical slot is
  // immediately reusable afterward.
  drive_entry(dut, 0x40);
  tick(dut);
  expect_entry(dut, 0x40);
  dut.rst_ni = 0;
  dut.eval();
  expect_eq("reset clears live head", 0, dut.head_valid_o);
  tick(dut);
  dut.rst_ni = 1;
  clear_inputs(dut);
  drive_entry(dut, 0x50);
  tick(dut);
  clear_inputs(dut);
  expect_entry(dut, 0x50);

  dut.final();
  std::cout << "PASS: " << checks
            << " single-entry issue queue checks across no-fallthrough, "
               "full replacement, pop, and reset reuse\n";
  return 0;
}
