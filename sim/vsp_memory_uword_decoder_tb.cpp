#include "Vvsp_memory_uword_decoder.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

uint64_t checks = 0;

constexpr uint8_t kLoad = 0;
constexpr uint8_t kStore = 1;
constexpr uint8_t kUnitStride = 0;
constexpr uint8_t kIndexU8 = 1;

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

uint32_t memory_header(uint8_t op, uint8_t addr_mode,
                       uint8_t span_or_index) {
  uint32_t header = 0xb4000000U | (0x12U << 15) | (1U << 10) |
                    (2U << 6);
  header |= static_cast<uint32_t>(op) << 25;
  header |= static_cast<uint32_t>(addr_mode);
  if (addr_mode == kIndexU8) {
    header |= static_cast<uint32_t>(span_or_index) << 2;
  } else {
    header |= static_cast<uint32_t>(span_or_index) << 1;
  }
  return header;
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
  drive_record(dut, memory_header(kLoad, kUnitStride, 4), 0xfffffff0U);
  expect_eq("legal maximum queries state", 1, dut.base_read_valid_o);
  expect_eq("legal maximum accepted", 1, dut.legal_o);
  expect_eq("legal maximum error clear", 0, dut.error_cause_o);
  expect_eq("legal maximum base", 0x100, dut.base_eaddr_o);
  expect_eq("legal maximum offset", 0xfff0, dut.eaddr_offset_o);
  expect_eq("legal maximum row", 2, dut.vrf_row_o);
  expect_eq("legal maximum span", 4, dut.span_bytes_o);
  expect_eq("load operation", kLoad, dut.op_o);
  expect_eq("load address mode", kUnitStride, dut.addr_mode_o);
  expect_eq("load index row clear", 0, dut.index_vrf_row_o);

  // A zero unit-stride code is a legal sentinel.  This decoder intentionally
  // leaves it at zero because only the action adapter owns the launch mask
  // needed to resolve the selected-group byte count.
  drive_record(dut, memory_header(kLoad, kUnitStride, 0), 0);
  expect_eq("full-selected span queries state", 1,
            dut.base_read_valid_o);
  expect_eq("full-selected span accepted", 1, dut.legal_o);
  expect_eq("full-selected span sentinel preserved", 0,
            dut.span_bytes_o);

  // bit 1 remains the span LSB for unit-stride operations; it is reserved
  // only when the address mode selects the indexed profile.
  drive_record(dut, memory_header(kStore, kUnitStride, 1), 0);
  expect_eq("store with one-byte span accepted", 1, dut.legal_o);
  expect_eq("store operation", kStore, dut.op_o);
  expect_eq("store address mode", kUnitStride, dut.addr_mode_o);
  expect_eq("store span", 1, dut.span_bytes_o);
  expect_eq("store index row clear", 0, dut.index_vrf_row_o);

  // Indexed operations reuse bits 5:2 for their index row and ignore the
  // overlapping sequential span field, even when that raw value is greater
  // than this instance's four-byte MAX_SPAN_BYTES.
  drive_record(dut, memory_header(kLoad, kIndexU8, 7), 4);
  expect_eq("gather accepted", 1, dut.legal_o);
  expect_eq("gather operation", kLoad, dut.op_o);
  expect_eq("gather address mode", kIndexU8, dut.addr_mode_o);
  expect_eq("gather data row", 2, dut.vrf_row_o);
  expect_eq("gather index row", 7, dut.index_vrf_row_o);
  expect_eq("gather span clear", 0, dut.span_bytes_o);

  drive_record(dut, memory_header(kStore, kIndexU8, 15), 8);
  expect_eq("scatter accepted", 1, dut.legal_o);
  expect_eq("scatter operation", kStore, dut.op_o);
  expect_eq("scatter address mode", kIndexU8, dut.addr_mode_o);
  expect_eq("scatter index row", 15, dut.index_vrf_row_o);
  expect_eq("scatter span clear", 0, dut.span_bytes_o);

  drive_record(dut, memory_header(kLoad, kIndexU8, 7) | (1U << 1), 0);
  expect_eq("indexed reserved bit does not query state", 0,
            dut.base_read_valid_o);
  expect_eq("indexed reserved bit rejected", 0, dut.legal_o);
  expect_eq("indexed reserved bit diagnostic", 3, dut.error_cause_o);
  expect_eq("rejected index row cannot leak", 0, dut.index_vrf_row_o);

  drive_record(dut, memory_header(kLoad, kUnitStride, 9), 0);
  expect_eq("oversize span does not query state", 0,
            dut.base_read_valid_o);
  expect_eq("oversize span rejected", 0, dut.legal_o);
  expect_eq("oversize span address diagnostic", 0xa, dut.error_cause_o);
  expect_eq("oversize span cannot leak base", 0, dut.base_eaddr_o);
  expect_eq("oversize span cannot be narrowed into command", 0,
            dut.span_bytes_o);

  drive_record(dut, memory_header(kLoad, kUnitStride, 4), 0x00008000U);
  expect_eq("noncanonical offset does not query state", 0,
            dut.base_read_valid_o);
  expect_eq("noncanonical offset rejected", 0, dut.legal_o);
  expect_eq("noncanonical offset immediate diagnostic", 5,
            dut.error_cause_o);

  drive_record(dut, memory_header(kLoad, kUnitStride, 4), 0);
  dut.base_read_legal_i = 0;
  dut.eval();
  expect_eq("illegal state base rejected", 0, dut.legal_o);
  expect_eq("illegal state base address diagnostic", 0xa,
            dut.error_cause_o);

  dut.final();
  std::cout << "vsp_memory_uword_decoder_tb: " << checks
            << " sequential/indexed field, canonical offset and base-query "
               "checks passed\n";
  return 0;
}
