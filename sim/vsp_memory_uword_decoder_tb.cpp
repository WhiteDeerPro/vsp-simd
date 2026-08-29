#include "Vvsp_memory_uword_decoder.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

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

uint32_t memory_header(uint8_t span) {
  return 0xb4000000U | (0x12U << 15) | (1U << 10) | (2U << 6) |
         (static_cast<uint32_t>(span) << 1);
}

void drive_record(Vvsp_memory_uword_decoder& dut, uint32_t header,
                  uint32_t offset) {
  dut.record_valid_i = 1;
  dut.record_word_count_i = 2;
  dut.record_present_word_count_i = 2;
  dut.record_truncated_i = 0;
  dut.record_words_i[0] = header;
  dut.record_words_i[1] = offset;
  dut.record_words_i[2] = 0;
  dut.record_words_i[3] = 0;
  dut.base_read_data_i = 0x100;
  dut.base_read_legal_i = 1;
  dut.eval();
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_memory_uword_decoder dut;

  // This instance represents one four-byte SIMD4 group.  A span which fits
  // the encoded five-bit field but exceeds the physical profile must reject
  // before any width narrowing or state query occurs.
  drive_record(dut, memory_header(4), 0xfffffff0U);
  expect_eq("legal maximum queries state", 1, dut.base_read_valid_o);
  expect_eq("legal maximum accepted", 1, dut.legal_o);
  expect_eq("legal maximum error clear", 0, dut.error_cause_o);
  expect_eq("legal maximum base", 0x100, dut.base_eaddr_o);
  expect_eq("legal maximum offset", 0xfff0, dut.eaddr_offset_o);
  expect_eq("legal maximum row", 2, dut.vrf_row_o);
  expect_eq("legal maximum span", 4, dut.span_bytes_o);

  drive_record(dut, memory_header(9), 0);
  expect_eq("oversize span does not query state", 0,
            dut.base_read_valid_o);
  expect_eq("oversize span rejected", 0, dut.legal_o);
  expect_eq("oversize span address diagnostic", 0xa, dut.error_cause_o);
  expect_eq("oversize span cannot leak base", 0, dut.base_eaddr_o);
  expect_eq("oversize span cannot be narrowed into command", 0,
            dut.span_bytes_o);

  drive_record(dut, memory_header(4), 0x00008000U);
  expect_eq("noncanonical offset does not query state", 0,
            dut.base_read_valid_o);
  expect_eq("noncanonical offset rejected", 0, dut.legal_o);
  expect_eq("noncanonical offset immediate diagnostic", 5,
            dut.error_cause_o);

  drive_record(dut, memory_header(4), 0);
  dut.base_read_legal_i = 0;
  dut.eval();
  expect_eq("illegal state base rejected", 0, dut.legal_o);
  expect_eq("illegal state base address diagnostic", 0xa,
            dut.error_cause_o);

  dut.final();
  std::cout << "vsp_memory_uword_decoder_tb: " << checks
            << " semantic range, canonical offset and base-query checks passed\n";
  return 0;
}
