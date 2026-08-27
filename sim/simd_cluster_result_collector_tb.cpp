#include "Vsimd_cluster_result_collector.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kLanes = 2;
constexpr unsigned kContextWidth = 2;
constexpr unsigned kTagWidth = 8;
constexpr unsigned kNarrowWidth = 16;
constexpr unsigned kAccWidth = 16;
constexpr unsigned kIndexWidth = 1;
constexpr unsigned kCountWidth = 2;

uint64_t checks = 0;

struct Result {
  unsigned group;
  unsigned context;
  unsigned tag;
  bool illegal;
  bool has_narrow;
  uint16_t narrow;
  unsigned narrow_mask;
  bool has_reduce;
  uint16_t reduce_value;
  unsigned reduce_index;
  bool has_count;
  unsigned count;
};

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

constexpr uint64_t width_mask(unsigned width) {
  return width == 64 ? ~uint64_t{0} : ((uint64_t{1} << width) - 1);
}

uint64_t field(uint64_t packed, unsigned index, unsigned width) {
  return (packed >> (index * width)) & width_mask(width);
}

void tick(Vsimd_cluster_result_collector& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_group_inputs(Vsimd_cluster_result_collector& dut) {
  dut.group_rsp_valid_i = 0;
  dut.group_rsp_context_i = 0;
  dut.group_rsp_tag_i = 0;
  dut.group_rsp_illegal_i = 0;
  dut.group_rsp_has_narrow_i = 0;
  dut.group_rsp_narrow_i = 0;
  dut.group_rsp_narrow_mask_i = 0;
  dut.group_rsp_has_reduce_i = 0;
  dut.group_rsp_reduce_value_i = 0;
  dut.group_rsp_reduce_index_i = 0;
  dut.group_rsp_has_count_i = 0;
  dut.group_rsp_count_i = 0;
}

void clear_inputs(Vsimd_cluster_result_collector& dut) {
  clear_group_inputs(dut);
  dut.result_ready_i = 0;
}

void reset(Vsimd_cluster_result_collector& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  dut.eval();
}

void drive_result(Vsimd_cluster_result_collector& dut, const Result& result) {
  const unsigned group = result.group;
  dut.group_rsp_valid_i |= uint32_t{1} << group;
  dut.group_rsp_context_i |=
      uint32_t(result.context) << (group * kContextWidth);
  dut.group_rsp_tag_i |= uint32_t(result.tag) << (group * kTagWidth);
  dut.group_rsp_illegal_i |= uint32_t(result.illegal) << group;
  dut.group_rsp_has_narrow_i |= uint32_t(result.has_narrow) << group;
  dut.group_rsp_narrow_i |= uint64_t(result.narrow)
                            << (group * kNarrowWidth);
  dut.group_rsp_narrow_mask_i |=
      uint32_t(result.narrow_mask) << (group * kLanes);
  dut.group_rsp_has_reduce_i |= uint32_t(result.has_reduce) << group;
  dut.group_rsp_reduce_value_i |= uint64_t(result.reduce_value)
                                  << (group * kAccWidth);
  dut.group_rsp_reduce_index_i |=
      uint32_t(result.reduce_index) << (group * kIndexWidth);
  dut.group_rsp_has_count_i |= uint32_t(result.has_count) << group;
  dut.group_rsp_count_i |= uint32_t(result.count)
                           << (group * kCountWidth);
}

void expect_output(Vsimd_cluster_result_collector& dut,
                   const Result& expected) {
  expect_eq("result valid", 1, dut.result_valid_o);
  expect_eq("result group", expected.group, dut.result_group_id_o);
  expect_eq("result context", expected.context, dut.result_context_o);
  expect_eq("result tag", expected.tag, dut.result_tag_o);
  expect_eq("result illegal", expected.illegal, dut.result_illegal_o);
  expect_eq("result has narrow", expected.has_narrow,
            dut.result_has_narrow_o);
  expect_eq("result narrow", expected.narrow, dut.result_narrow_o);
  expect_eq("result narrow mask", expected.narrow_mask,
            dut.result_narrow_mask_o);
  expect_eq("result has reduce", expected.has_reduce,
            dut.result_has_reduce_o);
  expect_eq("result reduce value", expected.reduce_value,
            dut.result_reduce_value_o);
  expect_eq("result reduce index", expected.reduce_index,
            dut.result_reduce_index_o);
  expect_eq("result has count", expected.has_count,
            dut.result_has_count_o);
  expect_eq("result count", expected.count, dut.result_count_o);
}

Result make_result(unsigned group, unsigned serial) {
  return Result{
      group,
      (serial + group) % 3,
      (serial * 17 + group * 29) & 0xffu,
      ((serial + group) & 7u) == 0,
      ((serial + group) & 1u) != 0,
      uint16_t(0x1000u ^ (serial * 37u) ^ (group * 0x111u)),
      (serial + group) & 0x3u,
      ((serial + group) & 2u) != 0,
      uint16_t(0x8000u ^ (serial * 53u) ^ (group * 0x222u)),
      (serial + group) & 0x1u,
      ((serial + group) & 4u) != 0,
      (serial + group) & 0x3u,
  };
}

uint32_t next_random(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

unsigned expected_select(const std::array<std::deque<Result>, kGroups>& queues,
                         unsigned rr_group) {
  for (unsigned offset = 0; offset < kGroups; ++offset) {
    const unsigned group = (rr_group + offset) % kGroups;
    if (!queues[group].empty()) return group;
  }
  return kGroups;
}

void directed_checks(Vsimd_cluster_result_collector& dut) {
  reset(dut);
  expect_eq("reset result empty", 0, dut.result_valid_o);
  expect_eq("reset retire empty", 0, dut.child_rsp_retire_o);

  const Result first{2, 1, 0xa5, true, true, 0xcafe, 0x2,
                     true, 0x3456, 1, true, 2};
  drive_result(dut, first);
  dut.eval();
  expect_eq("single group ready", 1u << first.group, dut.group_rsp_ready_o);
  expect_eq("single capture retires", 1u << first.group,
            dut.child_rsp_retire_o);
  expect_eq("retire context", first.context,
            field(dut.child_rsp_context_o, first.group, kContextWidth));
  expect_eq("retire tag", first.tag,
            field(dut.child_rsp_tag_o, first.group, kTagWidth));
  tick(dut);
  clear_group_inputs(dut);
  dut.eval();
  expect_output(dut, first);

  // Backpressure owns the buffered record and blocks every group input.
  const Result blocked = make_result(1, 99);
  drive_result(dut, blocked);
  for (unsigned cycle = 0; cycle < 5; ++cycle) {
    dut.result_ready_i = 0;
    dut.eval();
    expect_output(dut, first);
    expect_eq("stalled group ready", 0, dut.group_rsp_ready_o);
    expect_eq("stalled retire", 0, dut.child_rsp_retire_o);
    tick(dut);
  }

  // Pop and refill in the same cycle; there is no collector bubble.
  dut.result_ready_i = 1;
  dut.eval();
  expect_eq("refill group ready", 1u << blocked.group,
            dut.group_rsp_ready_o);
  expect_eq("refill retire", 1u << blocked.group, dut.child_rsp_retire_o);
  tick(dut);
  clear_group_inputs(dut);
  dut.result_ready_i = 0;
  dut.eval();
  expect_output(dut, blocked);

  dut.result_ready_i = 1;
  tick(dut);
  dut.result_ready_i = 0;
  dut.eval();
  expect_eq("directed drain", 0, dut.result_valid_o);

  // With all requesters continuously valid, RR must visit every group in
  // numerical order and wrap without starving any requester.
  reset(dut);
  dut.result_ready_i = 1;
  for (unsigned cycle = 0; cycle < 32; ++cycle) {
    clear_group_inputs(dut);
    for (unsigned group = 0; group < kGroups; ++group) {
      drive_result(dut, make_result(group, cycle));
    }
    dut.eval();
    const unsigned expected_group = cycle % kGroups;
    expect_eq("RR ready", 1u << expected_group, dut.group_rsp_ready_o);
    expect_eq("RR retire", 1u << expected_group, dut.child_rsp_retire_o);
    tick(dut);
    expect_output(dut, make_result(expected_group, cycle));
  }
}

void randomized_checks(Vsimd_cluster_result_collector& dut) {
  reset(dut);

  std::array<std::deque<Result>, kGroups> queues;
  for (unsigned group = 0; group < kGroups; ++group) {
    for (unsigned serial = 0; serial < 300; ++serial) {
      // Different source depths exercise sparse as well as simultaneous
      // arbitration near the end of the run.
      if ((serial % (group + 2)) != 0 || serial < 16) {
        queues[group].push_back(make_result(group, 1000 + serial));
      }
    }
  }

  bool buffered_valid = false;
  Result buffered{};
  unsigned rr_group = 0;
  uint32_t rng = 0x6d2b79f5u;

  for (unsigned cycle = 0; cycle < 20000; ++cycle) {
    clear_group_inputs(dut);
    for (unsigned group = 0; group < kGroups; ++group) {
      if (!queues[group].empty()) drive_result(dut, queues[group].front());
    }
    dut.result_ready_i = (next_random(rng) & 3u) != 0;
    dut.eval();

    if (buffered_valid) expect_output(dut, buffered);
    else expect_eq("random output empty", 0, dut.result_valid_o);

    const bool output_fire = buffered_valid && dut.result_ready_i;
    const bool capacity = !buffered_valid || dut.result_ready_i;
    const unsigned selected = expected_select(queues, rr_group);
    const unsigned expected_ready =
        (capacity && selected < kGroups) ? (1u << selected) : 0;
    expect_eq("random ready", expected_ready, dut.group_rsp_ready_o);
    expect_eq("random retire", expected_ready, dut.child_rsp_retire_o);

    bool captured_valid = false;
    Result captured{};
    if (expected_ready != 0) {
      captured = queues[selected].front();
      captured_valid = true;
      expect_eq("random retire context", captured.context,
                field(dut.child_rsp_context_o, selected, kContextWidth));
      expect_eq("random retire tag", captured.tag,
                field(dut.child_rsp_tag_o, selected, kTagWidth));
    }

    tick(dut);

    if (output_fire) buffered_valid = false;
    if (captured_valid) {
      buffered = captured;
      buffered_valid = true;
      queues[selected].pop_front();
      rr_group = (selected + 1) % kGroups;
    }

    bool sources_empty = true;
    for (const auto& queue : queues) sources_empty &= queue.empty();
    if (sources_empty && !buffered_valid) {
      clear_inputs(dut);
      dut.eval();
      expect_eq("random final output empty", 0, dut.result_valid_o);
      return;
    }
  }

  fail("randomized test timeout", 0, 1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_cluster_result_collector dut;

  directed_checks(dut);
  randomized_checks(dut);

  std::cout << "PASS simd_cluster_result_collector checks=" << checks << '\n';
  return 0;
}
