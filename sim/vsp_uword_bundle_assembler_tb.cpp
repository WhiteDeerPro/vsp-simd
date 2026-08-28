#include "Vvsp_uword_bundle_assembler.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& name, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << name << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& name, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(name, expected, actual);
}

void eval_low(Vvsp_uword_bundle_assembler& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_uword_bundle_assembler& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_uword_bundle_assembler& dut) {
  dut.bundle_valid_i = 0;
  dut.bundle_word_count_i = 0;
  dut.bundle_base_pc_i = 0;
  dut.bundle_last_i = 0;
  for (int index = 0; index < 4; ++index) dut.bundle_words_i[index] = 0;
  dut.record_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_uword_bundle_assembler& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  expect_eq("reset idle", 1, dut.idle_o);
  expect_eq("reset record invalid", 0, dut.record_valid_o);
  expect_eq("reset delivery clear", 0, dut.record_delivery_done_o);
  expect_eq("reset protocol clear", 0, dut.protocol_error_o);
}

void send_bundle(Vvsp_uword_bundle_assembler& dut, uint32_t pc,
                 uint8_t count, bool last,
                 const std::array<uint32_t, 4>& words) {
  dut.bundle_valid_i = 1;
  dut.bundle_base_pc_i = pc;
  dut.bundle_word_count_i = count;
  dut.bundle_last_i = last;
  for (int index = 0; index < 4; ++index)
    dut.bundle_words_i[index] = words[index];
  eval_low(dut);
  expect_eq("bundle ready", 1, dut.bundle_ready_o);
  tick(dut);
  dut.bundle_valid_i = 0;
}

void clear_error(Vvsp_uword_bundle_assembler& dut) {
  expect_eq("clear only while idle", 1, dut.idle_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  eval_low(dut);
  expect_eq("protocol error cleared", 0, dut.protocol_error_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_uword_bundle_assembler dut;

  // Continuity is tracked even after a complete record drains the buffer.
  reset(dut);
  send_bundle(dut, 0x100, 1, false, {0x10000010U, 0, 0, 0});
  expect_eq("single record visible", 1, dut.record_valid_o);
  expect_eq("single record PC", 0x100, dut.record_start_pc_o);
  dut.record_ready_i = 1;
  tick(dut);
  dut.record_ready_i = 0;
  expect_eq("buffer drained", 1, dut.idle_o);
  send_bundle(dut, 0x108, 1, true, {0xc0000000U, 0, 0, 0});
  expect_eq("gap diagnosed", 1, dut.protocol_error_o);
  expect_eq("gap emits no record", 0, dut.record_valid_o);
  expect_eq("gap is not delivery", 0, dut.record_delivery_done_o);
  clear_error(dut);

  // A discontinuity must not be used as the opaque continuation of a tail.
  reset(dut);
  send_bundle(dut, 0x200, 1, false, {0xb8000015U, 0, 0, 0});
  expect_eq("partial record held", 0, dut.record_valid_o);
  expect_eq("partial record not idle", 0, dut.idle_o);
  send_bundle(dut, 0x208, 1, true, {0x60000000U, 0, 0, 0});
  expect_eq("partial gap diagnosed", 1, dut.protocol_error_o);
  expect_eq("partial gap emits no record", 0, dut.record_valid_o);
  expect_eq("partial gap is not delivery", 0, dut.record_delivery_done_o);
  clear_error(dut);

  // After a non-final fault, drain through the declared final bundle without
  // exposing younger words or claiming successful delivery.
  reset(dut);
  send_bundle(dut, 0x300, 1, false, {0xb8000015U, 0, 0, 0});
  send_bundle(dut, 0x308, 1, false, {0x11111111U, 0, 0, 0});
  expect_eq("discard state active", 0, dut.idle_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("active discard keeps error", 1, dut.protocol_error_o);
  send_bundle(dut, 0x30c, 1, true, {0xc0000000U, 0, 0, 0});
  expect_eq("discard drained", 1, dut.idle_o);
  expect_eq("discard emits no record", 0, dut.record_valid_o);
  expect_eq("discard is not delivery", 0, dut.record_delivery_done_o);
  clear_error(dut);

  // A legitimate split record still consumes opaque words that resemble
  // EXEC/CONTROL headers and completes only after the record handshake.
  reset(dut);
  send_bundle(dut, 0x400, 1, false, {0xb8000015U, 0, 0, 0});
  send_bundle(dut, 0x404, 2, true,
              {0x60000000U, 0xc0000000U, 0, 0});
  expect_eq("split record visible", 1, dut.record_valid_o);
  expect_eq("split record class MEMORY", 1, dut.record_class_o);
  expect_eq("split record PC", 0x400, dut.record_start_pc_o);
  expect_eq("split record required", 3, dut.record_word_count_o);
  expect_eq("split record present", 3, dut.record_present_word_count_o);
  expect_eq("split record body zero", 0x60000000U,
            dut.record_words_o[1]);
  expect_eq("split record body one", 0xc0000000U,
            dut.record_words_o[2]);
  expect_eq("delivery waits for record", 0, dut.record_delivery_done_o);
  dut.record_ready_i = 1;
  tick(dut);
  dut.record_ready_i = 0;
  expect_eq("split record delivered", 1, dut.record_delivery_done_o);
  tick(dut);
  expect_eq("delivery is a pulse", 0, dut.record_delivery_done_o);

  dut.final();
  std::cout << "vsp_uword_bundle_assembler_tb: " << std::dec << checks
            << " continuity, discard and delivery checks passed\n";
  return 0;
}
