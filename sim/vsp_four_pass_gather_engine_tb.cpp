// CLASS: 事务性质
// CLAIM: four-pass gather engine 完整快照命令，恰执行四个 route beat，并在
//        result backpressure 下稳定保存 data/mask/oob/identity。
// SOURCE / QUESTION: 组合 phase 如何成为可由 cluster 调用的多周期共享 engine。
// ORACLE: 独立逐 byte gather 参考式与显式 valid/ready 时序检查。
// ASSUMPTIONS: single-outstanding、4 groups x SIMD4、结果尚未绑定 VRF commit。
// NON_CLAIMS: 不验证指令编码、cluster hazard、RF端口、完整action latency或PPA。
// RETIRE_WHEN: 正式 cluster capture/commit wrapper 覆盖相同事务合同后合并测试。

#include "Vvsp_four_pass_gather_engine.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <random>
#include <string>

namespace {

constexpr unsigned kLanes = 16;
using Bytes = std::array<uint8_t, kLanes>;

struct Expected {
  Bytes data{};
  uint16_t write_mask = 0;
  uint16_t oob_mask = 0;
  uint8_t context = 0;
  uint8_t tag = 0;
};

uint64_t checks = 0;

template <typename Wide>
void set_wide(Wide& signal, const Bytes& bytes) {
  for (unsigned word = 0; word < 4; ++word) {
    uint32_t packed = 0;
    for (unsigned byte = 0; byte < 4; ++byte) {
      packed |= static_cast<uint32_t>(bytes[(word * 4) + byte]) <<
                (byte * 8);
    }
    signal[word] = packed;
  }
}

template <typename Wide>
Bytes get_wide(const Wide& signal) {
  Bytes bytes{};
  for (unsigned word = 0; word < 4; ++word) {
    for (unsigned byte = 0; byte < 4; ++byte) {
      bytes[(word * 4) + byte] =
          static_cast<uint8_t>(signal[word] >> (byte * 8));
    }
  }
  return bytes;
}

void settle(Vvsp_four_pass_gather_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_four_pass_gather_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

[[noreturn]] void fail(const std::string& label, const std::string& field) {
  std::cerr << "FAIL " << label << " field=" << field << '\n';
  std::exit(1);
}

Expected reference(const Bytes& source, const Bytes& index,
                   uint16_t active_mask, uint8_t context, uint8_t tag) {
  Expected expected;
  expected.context = context;
  expected.tag = tag;
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    if (((active_mask >> lane) & 1u) == 0) continue;
    if (index[lane] < kLanes) {
      expected.data[lane] = source[index[lane]];
      expected.write_mask |= static_cast<uint16_t>(1u << lane);
    } else {
      expected.oob_mask |= static_cast<uint16_t>(1u << lane);
    }
  }
  return expected;
}

void drive_command(Vvsp_four_pass_gather_engine& dut, const Bytes& source,
                   const Bytes& index, uint16_t active_mask,
                   uint8_t context, uint8_t tag) {
  set_wide(dut.cmd_source_i, source);
  set_wide(dut.cmd_index_i, index);
  dut.cmd_active_mask_i = active_mask;
  dut.cmd_context_i = context;
  dut.cmd_tag_i = tag;
  dut.cmd_valid_i = 1;
  settle(dut);
}

void corrupt_command_inputs(Vvsp_four_pass_gather_engine& dut) {
  Bytes corrupt_source{};
  Bytes corrupt_index{};
  corrupt_source.fill(0xee);
  corrupt_index.fill(255);
  set_wide(dut.cmd_source_i, corrupt_source);
  set_wide(dut.cmd_index_i, corrupt_index);
  dut.cmd_active_mask_i = 0;
  dut.cmd_context_i = 0;
  dut.cmd_tag_i = 0;
}

void check_result(const Vvsp_four_pass_gather_engine& dut,
                  const std::string& label, const Expected& expected) {
  if (!dut.result_valid_o) fail(label, "result valid");
  if (get_wide(dut.result_data_o) != expected.data) fail(label, "data");
  if (dut.result_write_mask_o != expected.write_mask) {
    fail(label, "write mask");
  }
  if (dut.result_oob_mask_o != expected.oob_mask) fail(label, "oob mask");
  if (dut.result_context_o != expected.context) fail(label, "context");
  if (dut.result_tag_o != expected.tag) fail(label, "tag");
  ++checks;
}

void accept_and_run(Vvsp_four_pass_gather_engine& dut,
                    const std::string& label, const Bytes& source,
                    const Bytes& index, uint16_t active_mask,
                    uint8_t context, uint8_t tag) {
  const Expected expected =
      reference(source, index, active_mask, context, tag);
  drive_command(dut, source, index, active_mask, context, tag);
  if (!dut.cmd_ready_o) fail(label, "command ready");
  tick(dut);
  dut.cmd_valid_i = 0;
  corrupt_command_inputs(dut);
  settle(dut);

  for (unsigned phase = 0; phase < 4; ++phase) {
    if (!dut.busy_o) fail(label, "early busy drop");
    if (dut.phase_o != phase) fail(label, "phase");
    if (dut.result_valid_o) fail(label, "early result");
    if (dut.cmd_ready_o) fail(label, "ready while busy");
    tick(dut);
  }

  if (dut.busy_o) fail(label, "busy after phase three");
  check_result(dut, label, expected);
}

void consume_result(Vvsp_four_pass_gather_engine& dut) {
  dut.result_ready_i = 1;
  tick(dut);
  dut.result_ready_i = 0;
  settle(dut);
  if (dut.result_valid_o) fail("consume", "valid did not clear");
  if (!dut.cmd_ready_o) fail("consume", "command did not reopen");
}

Bytes ramp(uint8_t base) {
  Bytes value{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    value[lane] = static_cast<uint8_t>(base + lane);
  }
  return value;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_four_pass_gather_engine dut;
  dut.cmd_valid_i = 0;
  dut.result_ready_i = 0;
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  settle(dut);

  if (!dut.cmd_ready_o || dut.busy_o || dut.result_valid_o) {
    fail("reset", "idle state");
  }

  const Bytes source = ramp(0x30);
  Bytes identity{};
  for (unsigned lane = 0; lane < kLanes; ++lane) {
    identity[lane] = static_cast<uint8_t>(lane);
  }

  accept_and_run(dut, "identity snapshot", source, identity, 0xffffu, 2,
                 0x51);

  // A stalled result owns the output state and blocks another command.
  const Bytes stalled_data = get_wide(dut.result_data_o);
  const uint16_t stalled_write_mask = dut.result_write_mask_o;
  const uint16_t stalled_oob_mask = dut.result_oob_mask_o;
  const uint8_t stalled_context = dut.result_context_o;
  const uint8_t stalled_tag = dut.result_tag_o;
  for (unsigned cycle = 0; cycle < 7; ++cycle) {
    drive_command(dut, source, identity, 0xffffu, 1, 0x22);
    if (dut.cmd_ready_o) fail("result stall", "accepted command");
    tick(dut);
    if (!dut.result_valid_o || get_wide(dut.result_data_o) != stalled_data ||
        dut.result_write_mask_o != stalled_write_mask ||
        dut.result_oob_mask_o != stalled_oob_mask ||
        dut.result_context_o != stalled_context ||
        dut.result_tag_o != stalled_tag) {
      fail("result stall", "unstable response");
    }
  }
  dut.cmd_valid_i = 0;

  // Pop the old result and push a broadcast command on the same edge.
  Bytes broadcast{};
  broadcast.fill(7);
  drive_command(dut, source, broadcast, 0xa55au, 3, 0x72);
  dut.result_ready_i = 1;
  settle(dut);
  if (!dut.cmd_ready_o) fail("pop push", "ready");
  tick(dut);
  dut.cmd_valid_i = 0;
  dut.result_ready_i = 0;
  corrupt_command_inputs(dut);
  settle(dut);
  const Expected broadcast_expected =
      reference(source, broadcast, 0xa55au, 3, 0x72);
  for (unsigned phase = 0; phase < 4; ++phase) tick(dut);
  check_result(dut, "pop push broadcast", broadcast_expected);
  consume_result(dut);

  Bytes oob = identity;
  oob[0] = 16;
  oob[5] = 31;
  oob[10] = 255;
  oob[15] = 99;
  accept_and_run(dut, "oob and mask", source, oob, 0x7bdeu, 1, 0x91);
  consume_result(dut);

  // Reset aborts an inflight command and never exposes its partial result.
  drive_command(dut, source, identity, 0xffffu, 2, 0x33);
  tick(dut);
  dut.cmd_valid_i = 0;
  tick(dut);
  if (!dut.busy_o) fail("reset abort", "not busy before reset");
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  settle(dut);
  if (dut.busy_o || dut.result_valid_o || !dut.cmd_ready_o) {
    fail("reset abort", "post-reset state");
  }

  std::mt19937 rng(0x6e6713u);
  for (unsigned test = 0; test < 10000; ++test) {
    Bytes random_source{};
    Bytes random_index{};
    for (unsigned lane = 0; lane < kLanes; ++lane) {
      random_source[lane] = static_cast<uint8_t>(rng());
      random_index[lane] = static_cast<uint8_t>(rng());
    }
    const uint16_t active_mask = static_cast<uint16_t>(rng());
    const uint8_t context = static_cast<uint8_t>(rng() & 0x3u);
    const uint8_t tag = static_cast<uint8_t>(rng());
    accept_and_run(dut, "random", random_source, random_index, active_mask,
                   context, tag);

    // Random response stalls exercise stability without changing semantics.
    const unsigned stalls = rng() % 5;
    const Expected expected =
        reference(random_source, random_index, active_mask, context, tag);
    for (unsigned cycle = 0; cycle < stalls; ++cycle) {
      tick(dut);
      check_result(dut, "random stall", expected);
    }
    consume_result(dut);
  }

  dut.final();
  std::cout << "PASS: " << checks
            << " four-pass gather engine response checks\n";
  return 0;
}
