#include "Vsimd_group_wrapper.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>

namespace {

constexpr uint8_t kAdd = 0x00;
constexpr uint8_t kAbsdiffU = 0x0a;
constexpr uint8_t kPassA = 0x1a;
constexpr uint8_t kWidenU = 0x1c;
constexpr uint8_t kNslice = 0x26;
constexpr uint8_t kCompress = 0x28;
constexpr uint8_t kMand = 0x2a;
constexpr uint8_t kByteMode = 0;
constexpr uint8_t kReduceSumU = 0;
constexpr uint8_t kReqExec = 0;
constexpr uint8_t kReqStateWrite = 1;
constexpr uint8_t kVrf = 0;
constexpr uint8_t kArf = 1;
constexpr uint8_t kMrf = 2;

uint32_t checks = 0;

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

void tick(Vsimd_group_wrapper& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_exec(Vsimd_group_wrapper& dut) {
  dut.exec_valid_i = 0;
  dut.exec_context_i = 0;
  dut.exec_tag_i = 0;
  dut.exec_export_narrow_i = 0;
  dut.exec_op_i = kPassA;
  dut.exec_elem_mode_i = kByteMode;
  dut.exec_src_a_addr_i = 0;
  dut.exec_src_b_addr_i = 0;
  dut.exec_use_imm_i = 0;
  dut.exec_imm_i = 0;
  dut.exec_dst_vrf_addr_i = 0;
  dut.exec_src_arf_addr_i = 0;
  dut.exec_dst_arf_addr_i = 0;
  dut.exec_mask_enable_i = 0;
  dut.exec_mask_addr_i = 0;
  dut.exec_select_mask_addr_i = 0;
  dut.exec_dst_mrf_addr_i = 0;
  dut.exec_write_vrf_i = 0;
  dut.exec_write_arf_i = 0;
  dut.exec_write_mrf_i = 0;
  dut.exec_reduce_enable_i = 0;
  dut.exec_reduce_op_i = kReduceSumU;
  dut.exec_route_enable_i = 0;
  dut.exec_route_op_i = 0;
  dut.exec_route_index_i = 0;
  dut.exec_route_broadcast_index_i = 0;
  dut.exec_route_slide_amount_i = 0;
  dut.exec_route_lower_i = 0;
  dut.exec_route_upper_i = 0;
}

void clear_state_write(Vsimd_group_wrapper& dut) {
  dut.state_write_valid_i = 0;
  dut.state_write_context_i = 0;
  dut.state_write_tag_i = 0;
  dut.state_write_file_i = kVrf;
  dut.state_write_addr_i = 0;
  dut.state_write_mask_i = 0;
  for (unsigned word = 0; word < 4; ++word) {
    dut.state_write_data_i[word] = 0;
  }
}

void clear_inputs(Vsimd_group_wrapper& dut) {
  clear_exec(dut);
  clear_state_write(dut);
  dut.cpl_ready_i = 0;
  dut.rsp_ready_i = 0;
}

void drive_state_write(Vsimd_group_wrapper& dut, uint8_t context, uint8_t tag,
                       uint8_t file, uint8_t addr, uint8_t mask,
                       const std::array<uint32_t, 4>& data) {
  clear_state_write(dut);
  dut.state_write_valid_i = 1;
  dut.state_write_context_i = context;
  dut.state_write_tag_i = tag;
  dut.state_write_file_i = file;
  dut.state_write_addr_i = addr;
  dut.state_write_mask_i = mask;
  for (unsigned word = 0; word < data.size(); ++word) {
    dut.state_write_data_i[word] = data[word];
  }
}

void drive_state_write32(Vsimd_group_wrapper& dut, uint8_t context,
                         uint8_t tag, uint8_t file, uint8_t addr,
                         uint8_t mask, uint32_t data) {
  drive_state_write(dut, context, tag, file, addr, mask,
                    {data, 0, 0, 0});
}

void drive_pass_export(Vsimd_group_wrapper& dut, uint8_t context, uint8_t tag,
                       uint8_t source) {
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_context_i = context;
  dut.exec_tag_i = tag;
  dut.exec_export_narrow_i = 1;
  dut.exec_op_i = kPassA;
  dut.exec_src_a_addr_i = source;
}

void accept_state_write(Vsimd_group_wrapper& dut) {
  dut.eval();
  expect_eq("state write ready", 1, dut.state_write_ready_o);
  tick(dut);
  clear_state_write(dut);
}

void accept_exec(Vsimd_group_wrapper& dut) {
  dut.eval();
  expect_eq("exec ready", 1, dut.exec_ready_o);
  tick(dut);
  clear_exec(dut);
}

void expect_completion(Vsimd_group_wrapper& dut, uint8_t context, uint8_t tag,
                       uint8_t req_kind, bool illegal, bool has_result) {
  dut.eval();
  expect_eq("completion valid", 1, dut.cpl_valid_o);
  expect_eq("completion context", context, dut.cpl_context_o);
  expect_eq("completion tag", tag, dut.cpl_tag_o);
  expect_eq("completion kind", req_kind, dut.cpl_kind_o);
  expect_eq("completion illegal", illegal, dut.cpl_illegal_o);
  expect_eq("completion has result", has_result, dut.cpl_has_result_o);
}

void expect_narrow_response(Vsimd_group_wrapper& dut, uint8_t context,
                            uint8_t tag, uint32_t data, uint8_t mask) {
  dut.eval();
  expect_eq("response valid", 1, dut.rsp_valid_o);
  expect_eq("response context", context, dut.rsp_context_o);
  expect_eq("response tag", tag, dut.rsp_tag_o);
  expect_eq("response illegal", 0, dut.rsp_illegal_o);
  expect_eq("response has narrow", 1, dut.rsp_has_narrow_o);
  expect_eq("response narrow", data, dut.rsp_narrow_o);
  expect_eq("response narrow mask", mask, dut.rsp_narrow_mask_o);
}

void pop_completion(Vsimd_group_wrapper& dut) {
  clear_exec(dut);
  clear_state_write(dut);
  dut.cpl_ready_i = 1;
  tick(dut);
  dut.cpl_ready_i = 0;
  dut.eval();
  expect_eq("completion popped", 0, dut.cpl_valid_o);
}

void pop_both(Vsimd_group_wrapper& dut) {
  clear_exec(dut);
  clear_state_write(dut);
  dut.cpl_ready_i = 1;
  dut.rsp_ready_i = 1;
  tick(dut);
  dut.cpl_ready_i = 0;
  dut.rsp_ready_i = 0;
  dut.eval();
  expect_eq("completion popped", 0, dut.cpl_valid_o);
  expect_eq("response popped", 0, dut.rsp_valid_o);
}

uint32_t xorshift32(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

struct ExpectedCompletion {
  uint8_t context;
  uint8_t tag;
  uint8_t req_kind;
  bool has_result;
};

struct ExpectedResponse {
  uint8_t context;
  uint8_t tag;
  uint32_t data;
};

void randomized_backpressure(Vsimd_group_wrapper& dut) {
  constexpr unsigned kTransactions = 96;
  constexpr uint8_t kRow = 8;
  std::deque<ExpectedCompletion> completions;
  std::deque<ExpectedResponse> responses;
  uint32_t rng = 0x71c3a529u;
  uint32_t model_row = 0;
  unsigned next = 0;
  unsigned cycles = 0;
  unsigned completion_replacements = 0;
  unsigned response_replacements = 0;
  unsigned result_interleaves = 0;

  clear_exec(dut);
  clear_state_write(dut);

  while (next < kTransactions || !completions.empty() ||
         !responses.empty() || dut.cpl_valid_o || dut.rsp_valid_o) {
    if (++cycles > 10000) fail("randomized timeout", 0, cycles);

    dut.cpl_ready_i = xorshift32(rng) & 1u;
    dut.rsp_ready_i = xorshift32(rng) & 1u;
    clear_exec(dut);
    clear_state_write(dut);

    const bool is_state_write = next < kTransactions && ((next & 1u) == 0);
    const uint8_t tag = static_cast<uint8_t>(0x80u + next);
    const uint8_t context = next & 1u;
    const uint32_t state_write_value =
        0x01020408u ^ (next * 0x01010101u);
    if (next < kTransactions) {
      if (is_state_write) {
        drive_state_write32(dut, context, tag, kVrf, kRow, 0xf,
                            state_write_value);
      } else {
        drive_pass_export(dut, context, tag, kRow);
      }
    }

    dut.eval();

    expect_eq("random completion occupancy", !completions.empty(),
              dut.cpl_valid_o);
    if (!completions.empty()) {
      const auto& expected = completions.front();
      expect_eq("random completion context", expected.context,
                dut.cpl_context_o);
      expect_eq("random completion tag", expected.tag, dut.cpl_tag_o);
      expect_eq("random completion kind", expected.req_kind,
                dut.cpl_kind_o);
      expect_eq("random completion legal", 0, dut.cpl_illegal_o);
      expect_eq("random completion result", expected.has_result,
                dut.cpl_has_result_o);
    }

    expect_eq("random response occupancy", !responses.empty(),
              dut.rsp_valid_o);
    if (!responses.empty()) {
      const auto& expected = responses.front();
      expect_eq("random response context", expected.context,
                dut.rsp_context_o);
      expect_eq("random response tag", expected.tag, dut.rsp_tag_o);
      expect_eq("random response legal", 0, dut.rsp_illegal_o);
      expect_eq("random response narrow", 1, dut.rsp_has_narrow_o);
      expect_eq("random response data", expected.data, dut.rsp_narrow_o);
      expect_eq("random response mask", 0xf, dut.rsp_narrow_mask_o);
    }

    const bool pop_cpl = dut.cpl_valid_o && dut.cpl_ready_i;
    const bool pop_rsp = dut.rsp_valid_o && dut.rsp_ready_i;
    const bool fire_state_write =
        dut.state_write_valid_i && dut.state_write_ready_o;
    const bool fire_exec = dut.exec_valid_i && dut.exec_ready_o;
    if (fire_state_write && fire_exec) fail("dual fire", 0, 1);

    if (pop_cpl) completions.pop_front();
    if (pop_rsp) responses.pop_front();

    if (pop_cpl && (fire_state_write || fire_exec)) {
      ++completion_replacements;
    }
    if (pop_rsp && fire_exec) ++response_replacements;
    if (!responses.empty() && fire_state_write) ++result_interleaves;

    if (fire_state_write) {
      completions.push_back({context, tag, kReqStateWrite, false});
      model_row = state_write_value;
      ++next;
    } else if (fire_exec) {
      completions.push_back({context, tag, kReqExec, true});
      responses.push_back({context, tag, model_row});
      ++next;
    }

    tick(dut);
  }

  clear_inputs(dut);
  dut.eval();
  expect_eq("random final completion empty", 0, dut.cpl_valid_o);
  expect_eq("random final response empty", 0, dut.rsp_valid_o);
  expect_eq("random covered completion replacement", 1,
            completion_replacements != 0);
  expect_eq("random covered response replacement", 1,
            response_replacements != 0);
  expect_eq("random covered result interleave", 1,
            result_interleaves != 0);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_group_wrapper dut;
  clear_inputs(dut);

  // Reset only the wrapper's protocol state; RF contents are deliberately not
  // part of the reset contract.
  dut.rst_ni = 0;
  dut.exec_valid_i = 1;
  dut.state_write_valid_i = 1;
  dut.eval();
  expect_eq("exec blocked in reset", 0, dut.exec_ready_o);
  expect_eq("state write blocked in reset", 0, dut.state_write_ready_o);
  tick(dut);
  dut.rst_ni = 1;
  clear_inputs(dut);

  // Hold one completion, prove a second state write cannot overwrite it, then
  // pop and push in the same cycle to exercise the elastic replacement case.
  drive_state_write32(dut, 0, 0x11, kVrf, 0, 0xf, 0x04030201u);
  accept_state_write(dut);
  expect_completion(dut, 0, 0x11, kReqStateWrite, false, false);

  drive_state_write32(dut, 1, 0x12, kVrf, 1, 0xf, 0x281e140au);
  dut.eval();
  expect_eq("state write backpressured by completion", 0,
            dut.state_write_ready_o);
  tick(dut);
  expect_completion(dut, 0, 0x11, kReqStateWrite, false, false);

  dut.cpl_ready_i = 1;
  dut.eval();
  expect_eq("state write accepts on completion pop", 1,
            dut.state_write_ready_o);
  tick(dut);
  clear_state_write(dut);
  dut.cpl_ready_i = 0;
  expect_completion(dut, 1, 0x12, kReqStateWrite, false, false);
  pop_completion(dut);

  // Reset clears only protocol records. Pending completion/result state must
  // disappear immediately, requests presented during reset must not write,
  // and previously committed RF contents must remain intact.
  drive_pass_export(dut, 0, 0x13, 0);
  accept_exec(dut);
  expect_completion(dut, 0, 0x13, kReqExec, false, true);
  expect_narrow_response(dut, 0, 0x13, 0x04030201u, 0xf);
  drive_state_write32(dut, 0, 0x14, kVrf, 0, 0xf, 0xdeadbeefu);
  dut.rst_ni = 0;
  dut.eval();
  expect_eq("reset clears pending completion", 0, dut.cpl_valid_o);
  expect_eq("reset clears pending response", 0, dut.rsp_valid_o);
  expect_eq("reset blocks state write", 0, dut.state_write_ready_o);
  tick(dut);
  dut.rst_ni = 1;
  clear_inputs(dut);
  drive_pass_export(dut, 0, 0x15, 0);
  accept_exec(dut);
  expect_narrow_response(dut, 0, 0x15, 0x04030201u, 0xf);
  pop_both(dut);

  // Export a VRF row and hold the result under backpressure.  A later EXEC
  // that needs no result may still make progress because tags disambiguate the
  // two response streams.
  drive_pass_export(dut, 0, 0x21, 0);
  accept_exec(dut);
  expect_completion(dut, 0, 0x21, kReqExec, false, true);
  expect_narrow_response(dut, 0, 0x21, 0x04030201u, 0xf);
  const uint32_t held_narrow = dut.rsp_narrow_o;
  dut.cpl_ready_i = 1;
  for (unsigned stall = 0; stall < 3; ++stall) {
    tick(dut);
    expect_eq("held response valid", 1, dut.rsp_valid_o);
    expect_eq("held response data", held_narrow, dut.rsp_narrow_o);
  }
  dut.cpl_ready_i = 0;

  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_context_i = 1;
  dut.exec_tag_i = 0x22;
  dut.exec_op_i = kAdd;
  dut.exec_src_a_addr_i = 0;
  dut.exec_src_b_addr_i = 1;
  dut.exec_dst_vrf_addr_i = 2;
  dut.exec_write_vrf_i = 1;
  accept_exec(dut);
  expect_completion(dut, 1, 0x22, kReqExec, false, false);
  expect_narrow_response(dut, 0, 0x21, 0x04030201u, 0xf);
  pop_both(dut);

  // The ADD above consumed the two initialized rows. PASS_A observes its
  // committed result through the existing asynchronous RF read ports.
  drive_pass_export(dut, 1, 0x23, 2);
  accept_exec(dut);
  expect_completion(dut, 1, 0x23, kReqExec, false, true);
  expect_narrow_response(dut, 1, 0x23, 0x2c21160bu, 0xf);
  pop_both(dut);

  // A masked state-write beat preserves lanes that are not selected.
  drive_state_write32(dut, 0, 0x24, kVrf, 0, 0x5, 0x281e140au);
  accept_state_write(dut);
  expect_completion(dut, 0, 0x24, kReqStateWrite, false, false);
  pop_completion(dut);
  drive_pass_export(dut, 0, 0x25, 0);
  accept_exec(dut);
  expect_narrow_response(dut, 0, 0x25, 0x041e020au, 0xf);
  pop_both(dut);

  // ARF and MRF use the same state-write endpoint. ARF extraction deliberately
  // remains composed from NSLICE rather than adding a new wide read port.
  drive_state_write(dut, 0, 0x30, kArf, 0, 0xf,
                    {0x44332211u, 0x88776655u, 0xccbbaa99u, 0x00ffeeddu});
  accept_state_write(dut);
  expect_completion(dut, 0, 0x30, kReqStateWrite, false, false);
  pop_completion(dut);
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x31;
  dut.exec_export_narrow_i = 1;
  dut.exec_op_i = kNslice;
  dut.exec_src_arf_addr_i = 0;
  dut.exec_use_imm_i = 1;
  dut.exec_imm_i = 8;
  accept_exec(dut);
  expect_narrow_response(dut, 0, 0x31, 0xeeaa6622u, 0xf);
  pop_both(dut);

  drive_state_write32(dut, 0, 0x32, kMrf, 0, 0xf, 0x5);
  accept_state_write(dut);
  expect_completion(dut, 0, 0x32, kReqStateWrite, false, false);
  pop_completion(dut);
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x33;
  dut.exec_export_narrow_i = 1;
  dut.exec_op_i = kMand;
  dut.exec_mask_addr_i = 0;
  dut.exec_select_mask_addr_i = 0;
  accept_exec(dut);
  expect_narrow_response(dut, 0, 0x33, 0x00ff00ffu, 0xf);
  pop_both(dut);

  // Scalar result capture is independent of narrow export.
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x34;
  dut.exec_op_i = kAbsdiffU;
  dut.exec_src_a_addr_i = 0;
  dut.exec_src_b_addr_i = 1;
  dut.exec_reduce_enable_i = 1;
  dut.exec_reduce_op_i = kReduceSumU;
  accept_exec(dut);
  expect_completion(dut, 0, 0x34, kReqExec, false, true);
  expect_eq("reduce response valid", 1, dut.rsp_valid_o);
  expect_eq("reduce has narrow", 0, dut.rsp_has_narrow_o);
  expect_eq("reduce has value", 1, dut.rsp_has_reduce_o);
  expect_eq("reduce value", 54, dut.rsp_reduce_value_o);
  pop_both(dut);

  // Empty-mask reduction still returns an envelope, preventing a waiter from
  // blocking forever even though it contains no scalar value.
  drive_state_write32(dut, 0, 0x35, kMrf, 1, 0xf, 0x0);
  accept_state_write(dut);
  pop_completion(dut);
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x36;
  dut.exec_op_i = kPassA;
  dut.exec_src_a_addr_i = 0;
  dut.exec_mask_enable_i = 1;
  dut.exec_mask_addr_i = 1;
  dut.exec_reduce_enable_i = 1;
  accept_exec(dut);
  expect_completion(dut, 0, 0x36, kReqExec, false, true);
  expect_eq("empty reduce response", 1, dut.rsp_valid_o);
  expect_eq("empty reduce legal", 0, dut.rsp_illegal_o);
  expect_eq("empty reduce has no value", 0, dut.rsp_has_reduce_o);
  pop_both(dut);

  // COMPRESS requests a count response even without a narrow export.
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x37;
  dut.exec_op_i = kCompress;
  dut.exec_src_a_addr_i = 0;
  dut.exec_mask_enable_i = 1;
  dut.exec_mask_addr_i = 0;
  accept_exec(dut);
  expect_eq("compact response", 1, dut.rsp_valid_o);
  expect_eq("compact has count", 1, dut.rsp_has_count_o);
  expect_eq("compact count", 2, dut.rsp_count_o);
  pop_both(dut);

  // Invalid execution and state-write requests are consumed, report errors,
  // and make no state change.
  drive_state_write32(dut, 0, 0x40, kVrf, 6, 0xf, 0xdeadbeefu);
  accept_state_write(dut);
  pop_completion(dut);
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x41;
  dut.exec_export_narrow_i = 1;
  dut.exec_op_i = 0x3f;
  dut.exec_dst_vrf_addr_i = 6;
  dut.exec_write_vrf_i = 1;
  accept_exec(dut);
  expect_completion(dut, 0, 0x41, kReqExec, true, true);
  expect_eq("illegal response", 1, dut.rsp_valid_o);
  expect_eq("illegal response status", 1, dut.rsp_illegal_o);
  expect_eq("illegal response has no data", 0, dut.rsp_has_narrow_o);
  pop_both(dut);
  drive_pass_export(dut, 0, 0x42, 6);
  accept_exec(dut);
  expect_narrow_response(dut, 0, 0x42, 0xdeadbeefu, 0xf);
  pop_both(dut);

  drive_state_write32(dut, 1, 0x43, 3, 0, 0xf, 0x12345678u);
  accept_state_write(dut);
  expect_completion(dut, 1, 0x43, kReqStateWrite, true, false);
  pop_completion(dut);

  // A wide-only operation cannot claim the narrow export endpoint merely
  // because the combinational datapath happens to carry low bytes. Reject the
  // whole malformed request and prove that its otherwise legal ARF write did
  // not commit.
  drive_state_write(dut, 0, 0x44, kArf, 2, 0xf,
                    {0x11223344u, 0x55667788u, 0x99aabbccu, 0xddeeff00u});
  accept_state_write(dut);
  pop_completion(dut);
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x45;
  dut.exec_export_narrow_i = 1;
  dut.exec_op_i = kWidenU;
  dut.exec_src_a_addr_i = 0;
  dut.exec_dst_arf_addr_i = 2;
  dut.exec_write_arf_i = 1;
  accept_exec(dut);
  expect_completion(dut, 0, 0x45, kReqExec, true, true);
  expect_eq("wide export error response", 1, dut.rsp_valid_o);
  expect_eq("wide export response status", 1, dut.rsp_illegal_o);
  expect_eq("wide export has no narrow data", 0, dut.rsp_has_narrow_o);
  pop_both(dut);
  clear_exec(dut);
  dut.exec_valid_i = 1;
  dut.exec_tag_i = 0x46;
  dut.exec_export_narrow_i = 1;
  dut.exec_op_i = kNslice;
  dut.exec_src_arf_addr_i = 2;
  dut.exec_use_imm_i = 1;
  dut.exec_imm_i = 0;
  accept_exec(dut);
  expect_narrow_response(dut, 0, 0x46, 0x00cc8844u, 0xf);
  pop_both(dut);

  // Simultaneous EXEC/state-write requests are accepted one at a time; the
  // second replaces the first completion only when the sink returns credit.
  drive_pass_export(dut, 0, 0x50, 0);
  dut.exec_export_narrow_i = 0;
  drive_state_write32(dut, 1, 0x51, kVrf, 7, 0xf, 0x76543210u);
  dut.eval();
  expect_eq("one arbitration grant", 1,
            unsigned(dut.exec_ready_o) +
                unsigned(dut.state_write_ready_o));
  const bool exec_first = dut.exec_ready_o;
  tick(dut);
  if (exec_first) clear_exec(dut);
  else clear_state_write(dut);
  dut.cpl_ready_i = 1;
  dut.eval();
  expect_eq("loser proceeds on pop", 1,
            exec_first ? dut.state_write_ready_o : dut.exec_ready_o);
  tick(dut);
  clear_exec(dut);
  clear_state_write(dut);
  dut.cpl_ready_i = 0;
  expect_completion(dut, exec_first ? 1 : 0, exec_first ? 0x51 : 0x50,
                    exec_first ? kReqStateWrite : kReqExec, false, false);
  pop_completion(dut);

  randomized_backpressure(dut);

  dut.final();
  std::cout << "PASS: " << checks
            << " F1 state-write/EXEC arbitration, completion/result elasticity, "
               "state transfer, export, and randomized backpressure checks\n";
  return 0;
}
