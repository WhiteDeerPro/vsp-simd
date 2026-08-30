#include "Vvsp_control_uword_decoder.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

uint64_t checks = 0;

constexpr uint8_t kBranchJ = 0;
constexpr uint8_t kBranchBeq = 1;
constexpr uint8_t kBranchBne = 2;

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

uint32_t branch_header(uint8_t condition, uint8_t rs1 = 0,
                       uint8_t rs2 = 0) {
  return 0xc7000000U | (static_cast<uint32_t>(condition) << 22) |
         (static_cast<uint32_t>(rs1) << 17) |
         (static_cast<uint32_t>(rs2) << 12);
}

void drive_record(Vvsp_control_uword_decoder& dut, uint32_t header,
                  uint32_t body, uint8_t word_count = 2,
                  uint8_t present_word_count = 2, bool truncated = false) {
  dut.record_valid_i = 1;
  dut.record_word_count_i = word_count;
  dut.record_present_word_count_i = present_word_count;
  dut.record_truncated_i = truncated;
  dut.record_words_i[0] = header;
  dut.record_words_i[1] = body;
  dut.record_words_i[2] = 0;
  dut.record_words_i[3] = 0;
  dut.eval();
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_control_uword_decoder dut;

  drive_record(dut, branch_header(kBranchJ), 0xfffffff8U);
  expect_eq("J recognized", 1, dut.is_branch_o);
  expect_eq("J is not state", 0, dut.is_state_o);
  expect_eq("J legal", 1, dut.legal_o);
  expect_eq("J condition", kBranchJ, dut.branch_cond_o);
  expect_eq("J negative displacement", 0xfffffff8U,
            static_cast<uint32_t>(dut.branch_offset_o));
  expect_eq("J rs1 clear", 0, dut.branch_rs1_o);
  expect_eq("J rs2 clear", 0, dut.branch_rs2_o);

  drive_record(dut, branch_header(kBranchBeq, 3, 4), 20U);
  expect_eq("BEQ recognized", 1, dut.is_branch_o);
  expect_eq("BEQ legal", 1, dut.legal_o);
  expect_eq("BEQ condition", kBranchBeq, dut.branch_cond_o);
  expect_eq("BEQ rs1", 3, dut.branch_rs1_o);
  expect_eq("BEQ rs2", 4, dut.branch_rs2_o);
  expect_eq("BEQ displacement", 20, dut.branch_offset_o);

  drive_record(dut, branch_header(kBranchBne, 4, 1), 0U);
  expect_eq("BNE legal", 1, dut.legal_o);
  expect_eq("BNE condition", kBranchBne, dut.branch_cond_o);
  expect_eq("BNE rs1", 4, dut.branch_rs1_o);
  expect_eq("BNE rs2", 1, dut.branch_rs2_o);

  drive_record(dut, branch_header(3), 0U);
  expect_eq("reserved condition keeps branch identity", 1,
            dut.is_branch_o);
  expect_eq("reserved condition rejected", 0, dut.legal_o);
  expect_eq("reserved condition diagnostic", 2, dut.error_cause_o);
  expect_eq("rejected condition does not leak", 0, dut.branch_cond_o);

  drive_record(dut, branch_header(kBranchBeq, 1, 2) | 1U, 0U);
  expect_eq("reserved header bit rejected", 0, dut.legal_o);
  expect_eq("reserved header diagnostic", 3, dut.error_cause_o);

  drive_record(dut, branch_header(kBranchJ, 1, 0), 0U);
  expect_eq("J operands rejected", 0, dut.legal_o);
  expect_eq("J operands unused diagnostic", 0xb, dut.error_cause_o);

  // This test target uses STATE_REGS=5.  Full encoded register numbers are
  // validated before narrowing to the three-bit decoder interface.
  drive_record(dut, branch_header(kBranchBeq, 5, 0), 0U);
  expect_eq("out-of-range branch register rejected", 0, dut.legal_o);
  expect_eq("out-of-range register diagnostic", 0xa, dut.error_cause_o);

  drive_record(dut, branch_header(kBranchBne, 1, 2), 2U);
  expect_eq("unaligned displacement rejected", 0, dut.legal_o);
  expect_eq("unaligned displacement diagnostic", 5, dut.error_cause_o);

  drive_record(dut, branch_header(kBranchJ), 0U, 1, 1, false);
  expect_eq("bad shape keeps branch identity", 1, dut.is_branch_o);
  expect_eq("bad shape rejected", 0, dut.legal_o);
  expect_eq("bad shape diagnostic", 4, dut.error_cause_o);

  drive_record(dut, branch_header(kBranchJ), 0U, 2, 1, true);
  expect_eq("truncated branch identity", 1, dut.is_branch_o);
  expect_eq("truncated branch rejected", 0, dut.legal_o);
  expect_eq("truncated branch diagnostic", 4, dut.error_cause_o);

  // Existing canonical END and state families must retain their priority and
  // identity after assigning state-op code 3 to branches.
  drive_record(dut, 0xc0000000U, 0U, 1, 1, false);
  expect_eq("END recognized", 1, dut.is_control_end_o);
  expect_eq("END not branch", 0, dut.is_branch_o);
  expect_eq("END legal", 1, dut.legal_o);

  drive_record(dut, 0xc4000000U | (1U << 19), 0x12345678U);
  expect_eq("SMOVI remains state", 1, dut.is_state_o);
  expect_eq("SMOVI not branch", 0, dut.is_branch_o);
  expect_eq("SMOVI legal", 1, dut.legal_o);
  expect_eq("SMOVI destination", 1, dut.state_rd_o);
  expect_eq("SMOVI immediate", 0x12345678U, dut.state_imm_o);

  dut.final();
  std::cout << "vsp_control_uword_decoder_tb: " << checks
            << " J/BEQ/BNE decode and malformed-record checks passed\n";
  return 0;
}
