#include "Vsimd_cluster_exec_shell.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <set>
#include <string>

namespace {

constexpr uint8_t kOpAdd = 0x00;
constexpr uint8_t kOpPassA = 0x1a;
constexpr uint8_t kRfVrf = 0;

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

void eval_low(Vsimd_cluster_exec_shell& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vsimd_cluster_exec_shell& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_command(Vsimd_cluster_exec_shell& dut) {
  dut.cmd_valid_i = 0;
  dut.cmd_context_i = 0;
  dut.cmd_tag_i = 0;
  dut.cmd_group_mask_i = 0;
  dut.cmd_exact_resource_i = 0;
  dut.cmd_export_narrow_i = 0;
  dut.cmd_op_i = 0;
  dut.cmd_elem_mode_i = 0;
  dut.cmd_src_a_addr_i = 0;
  dut.cmd_src_b_addr_i = 0;
  dut.cmd_use_imm_i = 0;
  dut.cmd_imm_i = 0;
  dut.cmd_dst_vrf_addr_i = 0;
  dut.cmd_src_arf_addr_i = 0;
  dut.cmd_dst_arf_addr_i = 0;
  dut.cmd_mask_enable_i = 0;
  dut.cmd_mask_addr_i = 0;
  dut.cmd_select_mask_addr_i = 0;
  dut.cmd_dst_mrf_addr_i = 0;
  dut.cmd_write_vrf_i = 0;
  dut.cmd_write_arf_i = 0;
  dut.cmd_write_mrf_i = 0;
  dut.cmd_reduce_enable_i = 0;
  dut.cmd_reduce_op_i = 0;
  dut.cmd_route_enable_i = 0;
  dut.cmd_route_op_i = 0;
  dut.cmd_route_index_i = 0;
  dut.cmd_route_broadcast_index_i = 0;
  dut.cmd_route_slide_amount_i = 0;
  dut.cmd_route_lower_i = 0;
  dut.cmd_route_upper_i = 0;
}

void clear_state_write(Vsimd_cluster_exec_shell& dut) {
  dut.state_write_valid_i = 0;
  dut.state_write_group_i = 0;
  dut.state_write_context_i = 0;
  dut.state_write_tag_i = 0;
  dut.state_write_file_i = 0;
  dut.state_write_addr_i = 0;
  dut.state_write_mask_i = 0;
  for (int word = 0; word < 4; ++word) dut.state_write_data_i[word] = 0;
}

void clear_inputs(Vsimd_cluster_exec_shell& dut) {
  clear_command(dut);
  clear_state_write(dut);
  dut.group_owner_valid_i = 0;
  dut.group_owner_i = 0;
  dut.issue_slot_grant_i = 0;
  dut.state_cpl_ready_i = 0;
  dut.cpl_ready_i = 0;
  dut.result_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void wait_cycles(Vsimd_cluster_exec_shell& dut, int cycles) {
  for (int cycle = 0; cycle < cycles; ++cycle) tick(dut);
}

void enqueue(Vsimd_cluster_exec_shell& dut, uint8_t context, uint8_t tag,
             uint8_t group_mask, uint8_t op, uint8_t src_a,
             uint8_t src_b, uint8_t dst, bool write_vrf,
             bool export_narrow = false, uint8_t exact_resource = 0) {
  clear_command(dut);
  dut.cmd_valid_i = 1;
  dut.cmd_context_i = context;
  dut.cmd_tag_i = tag;
  dut.cmd_group_mask_i = group_mask;
  dut.cmd_exact_resource_i = exact_resource;
  dut.cmd_op_i = op;
  dut.cmd_elem_mode_i = 0;
  dut.cmd_src_a_addr_i = src_a;
  dut.cmd_src_b_addr_i = src_b;
  dut.cmd_dst_vrf_addr_i = dst;
  dut.cmd_write_vrf_i = write_vrf;
  dut.cmd_export_narrow_i = export_narrow;

  for (int timeout = 0; timeout < 100; ++timeout) {
    eval_low(dut);
    if (dut.cmd_ready_o) {
      tick(dut);
      clear_command(dut);
      return;
    }
    tick(dut);
  }
  std::cerr << "timeout enqueue tag=" << unsigned(tag) << '\n';
  std::exit(1);
}

void issue_vrf_write(Vsimd_cluster_exec_shell& dut, uint8_t group,
                     uint8_t row, uint32_t data, uint8_t tag) {
  clear_state_write(dut);
  dut.state_write_valid_i = 1;
  dut.state_write_group_i = group;
  dut.state_write_context_i = 0;
  dut.state_write_tag_i = tag;
  dut.state_write_file_i = kRfVrf;
  dut.state_write_addr_i = row;
  dut.state_write_mask_i = 0xf;
  dut.state_write_data_i[0] = data;

  for (int timeout = 0; timeout < 100; ++timeout) {
    eval_low(dut);
    expect_eq("valid state group is in range", 0,
              dut.state_write_group_error_o);
    if (dut.state_write_ready_o) {
      tick(dut);
      clear_state_write(dut);
      return;
    }
    tick(dut);
    if (timeout == 99) {
      std::cerr << "timeout state-write request\n";
      std::exit(1);
    }
  }
}

void write_vrf(Vsimd_cluster_exec_shell& dut, uint8_t group,
               uint8_t row, uint32_t data, uint8_t tag) {
  issue_vrf_write(dut, group, row, data, tag);

  for (int timeout = 0; timeout < 100; ++timeout) {
    eval_low(dut);
    if (dut.state_cpl_valid_o) {
      expect_eq("state completion group", group, dut.state_cpl_group_o);
      expect_eq("state completion tag", tag, dut.state_cpl_tag_o);
      expect_eq("state completion legal", 0, dut.state_cpl_illegal_o);
      dut.state_cpl_ready_i = 1;
      tick(dut);
      dut.state_cpl_ready_i = 0;
      return;
    }
    tick(dut);
  }
  std::cerr << "timeout state-write completion\n";
  std::exit(1);
}

struct Completion {
  uint8_t context;
  uint8_t tag;
  uint8_t group_mask;
  uint8_t result_mask;
  bool illegal;
  uint8_t illegal_group_mask;
  bool rejected;
  bool empty_mask;
  bool owner_mismatch;
};

Completion consume_completion(Vsimd_cluster_exec_shell& dut) {
  for (int timeout = 0; timeout < 300; ++timeout) {
    eval_low(dut);
    if (dut.cpl_valid_o) {
      const Completion cpl{static_cast<uint8_t>(dut.cpl_context_o),
                           static_cast<uint8_t>(dut.cpl_tag_o),
                           static_cast<uint8_t>(dut.cpl_group_mask_o),
                           static_cast<uint8_t>(dut.cpl_result_mask_o),
                           dut.cpl_illegal_o != 0,
                           static_cast<uint8_t>(
                               dut.cpl_illegal_group_mask_o),
                           dut.cpl_rejected_o != 0,
                           dut.cpl_empty_mask_o != 0,
                           dut.cpl_owner_mismatch_o != 0};
      dut.cpl_ready_i = 1;
      tick(dut);
      dut.cpl_ready_i = 0;
      return cpl;
    }
    tick(dut);
  }
  std::cerr << "timeout command completion\n";
  std::exit(1);
}

void expect_normal_completion(const Completion& cpl, uint8_t context,
                              uint8_t tag, uint8_t mask,
                              uint8_t result_mask = 0) {
  expect_eq("completion context", context, cpl.context);
  expect_eq("completion tag", tag, cpl.tag);
  expect_eq("completion group mask", mask, cpl.group_mask);
  expect_eq("completion result mask", result_mask, cpl.result_mask);
  expect_eq("completion legal", 0, cpl.illegal);
  expect_eq("completion illegal mask", 0, cpl.illegal_group_mask);
  expect_eq("completion not rejected", 0, cpl.rejected);
  expect_eq("completion not empty-mask reject", 0, cpl.empty_mask);
  expect_eq("completion not owner reject", 0, cpl.owner_mismatch);
}

struct Result {
  uint8_t group;
  uint8_t context;
  uint8_t tag;
  uint32_t narrow;
  uint8_t mask;
};

Result consume_result(Vsimd_cluster_exec_shell& dut) {
  for (int timeout = 0; timeout < 300; ++timeout) {
    eval_low(dut);
    if (dut.result_valid_o) {
      expect_eq("result legal", 0, dut.result_illegal_o);
      expect_eq("result has narrow", 1, dut.result_has_narrow_o);
      expect_eq("result has no reduce", 0, dut.result_has_reduce_o);
      expect_eq("result has no count", 0, dut.result_has_count_o);
      const Result result{static_cast<uint8_t>(dut.result_group_o),
                          static_cast<uint8_t>(dut.result_context_o),
                          static_cast<uint8_t>(dut.result_tag_o),
                          static_cast<uint32_t>(dut.result_narrow_o),
                          static_cast<uint8_t>(dut.result_narrow_mask_o)};
      dut.result_ready_i = 1;
      tick(dut);
      dut.result_ready_i = 0;
      return result;
    }
    tick(dut);
  }
  std::cerr << "timeout result\n";
  std::exit(1);
}

void wait_cluster_empty(Vsimd_cluster_exec_shell& dut) {
  for (int timeout = 0; timeout < 300; ++timeout) {
    eval_low(dut);
    if (dut.tracker_occupancy_o == 0 &&
        dut.group_ingress_valid_o == 0) {
      return;
    }
    tick(dut);
  }
  std::cerr << "timeout cluster empty\n";
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_cluster_exec_shell dut;
  clear_inputs(dut);

  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  dut.issue_slot_grant_i = 0x3;
  // First phase: context 0 owns every group for one-command multicast.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0x0;
  eval_low(dut);
  expect_eq("empty tracker after reset", 0, dut.tracker_occupancy_o);
  expect_eq("empty ingress after reset", 0, dut.group_ingress_valid_o);
  expect_eq("no protocol error after reset", 0, dut.protocol_error_o);

  std::array<uint32_t, 4> expected_sum{};
  for (uint8_t group = 0; group < 4; ++group) {
    const uint32_t a = 0x04030201u + 0x01010101u * group;
    const uint32_t b = 0x10101010u + 0x01010101u * group;
    // Every byte stays below 0xff, so packed integer addition matches four
    // independent byte additions without cross-byte carries.
    expected_sum[group] = a + b;
    write_vrf(dut, group, 0, a, static_cast<uint8_t>(0x80 + group));
    write_vrf(dut, group, 1, b, static_cast<uint8_t>(0x90 + group));
  }

  // A state completion selected while blocked must not be replaced by a
  // newly arriving lower-priority group.  This directly checks the arbiter's
  // selection hold rather than relying only on sequential helper traffic.
  issue_vrf_write(dut, 2, 6, 0x22222222u, 0xa2);
  eval_low(dut);
  expect_eq("blocked state completion visible", 1, dut.state_cpl_valid_o);
  expect_eq("blocked state completion starts at group2", 2,
            dut.state_cpl_group_o);
  issue_vrf_write(dut, 1, 6, 0x11111111u, 0xa1);
  for (int cycle = 0; cycle < 4; ++cycle) {
    eval_low(dut);
    expect_eq("state selection stable under competition", 2,
              dut.state_cpl_group_o);
    expect_eq("state tag stable under competition", 0xa2,
              dut.state_cpl_tag_o);
    tick(dut);
  }
  dut.state_cpl_ready_i = 1;
  tick(dut);
  dut.state_cpl_ready_i = 0;
  eval_low(dut);
  expect_eq("second state completion follows", 1, dut.state_cpl_valid_o);
  expect_eq("second state completion group", 1, dut.state_cpl_group_o);
  expect_eq("second state completion tag", 0xa1, dut.state_cpl_tag_o);
  dut.state_cpl_ready_i = 1;
  tick(dut);
  dut.state_cpl_ready_i = 0;

  enqueue(dut, 0, 1, 0xf, kOpAdd, 0, 1, 2, true);
  expect_normal_completion(consume_completion(dut), 0, 1, 0xf);

  // Export verifies that the multicast command reached all four independent
  // register files and that the result collector preserves physical group ID.
  enqueue(dut, 0, 2, 0xf, kOpPassA, 2, 0, 0, false, true);
  expect_normal_completion(consume_completion(dut), 0, 2, 0xf, 0xf);
  std::set<uint8_t> seen_groups;
  for (int record = 0; record < 4; ++record) {
    const Result result = consume_result(dut);
    expect_eq("export context", 0, result.context);
    expect_eq("export tag", 2, result.tag);
    expect_eq("export mask", 0xf, result.mask);
    expect_eq("export group unique", 0, seen_groups.count(result.group));
    seen_groups.insert(result.group);
    expect_eq("export payload", expected_sum[result.group], result.narrow);
  }
  wait_cluster_empty(dut);

  // Result backpressure must freeze the collector output.  The command may
  // complete first, but its tag remains busy until all four records have been
  // captured by the collector.
  enqueue(dut, 0, 3, 0xf, kOpPassA, 2, 0, 0, false, true);
  const Completion export_cpl = consume_completion(dut);
  expect_normal_completion(export_cpl, 0, 3, 0xf, 0xf);
  eval_low(dut);
  expect_eq("first blocked result visible", 1, dut.result_valid_o);
  const uint8_t held_group = dut.result_group_o;
  const uint8_t held_tag = dut.result_tag_o;
  const uint32_t held_data = dut.result_narrow_o;
  for (int cycle = 0; cycle < 8; ++cycle) {
    expect_eq("blocked result group stable", held_group,
              dut.result_group_o);
    expect_eq("blocked result tag stable", held_tag, dut.result_tag_o);
    expect_eq("blocked result data stable", held_data,
              dut.result_narrow_o);
    tick(dut);
  }

  // Reusing the same context/tag is accepted into the ordered queue but may
  // not issue while old result obligations remain live.
  enqueue(dut, 0, 3, 0x1, kOpAdd, 0, 1, 3, true);
  for (int cycle = 0; cycle < 5; ++cycle) {
    eval_low(dut);
    expect_eq("busy tag prevents issue", 0, dut.issue_accept_o);
    tick(dut);
  }

  seen_groups.clear();
  for (int record = 0; record < 4; ++record) {
    const Result result = consume_result(dut);
    expect_eq("blocked export tag", 3, result.tag);
    expect_eq("blocked export unique", 0, seen_groups.count(result.group));
    seen_groups.insert(result.group);
  }
  expect_normal_completion(consume_completion(dut), 0, 3, 0x1);
  wait_cluster_empty(dut);

  // Split ownership and hold both slots before dispatch.  Releasing the slot
  // grants demonstrates one-cycle dual issue for disjoint group masks.
  dut.group_owner_i = 0xc;  // group 0/1 -> context 0, 2/3 -> context 1.
  dut.issue_slot_grant_i = 0;
  enqueue(dut, 0, 10, 0x3, kOpAdd, 0, 1, 4, true, false, 0x1);
  enqueue(dut, 1, 11, 0xc, kOpAdd, 0, 1, 4, true, false, 0x2);
  wait_cycles(dut, 2);
  eval_low(dut);
  expect_eq("slot grants hold both commands", 0, dut.issue_accept_o);
  expect_eq("both resource requests visible", 0x3,
            dut.issue_slot_valid_o);
  for (int slot = 0; slot < 2; ++slot) {
    const uint8_t mask =
        (dut.issue_slot_group_mask_o >> (slot * 4)) & 0xf;
    const uint8_t resource =
        (dut.issue_slot_resource_o >> (slot * 8)) & 0xff;
    if (mask == 0x3) expect_eq("context0 exact resource", 0x1, resource);
    else if (mask == 0xc)
      expect_eq("context1 exact resource", 0x2, resource);
    else fail("unexpected held slot mask", 0x3, mask);
  }
  dut.issue_slot_grant_i = 0x3;
  eval_low(dut);
  expect_eq("two disjoint slots accept together", 0x3,
            dut.issue_accept_o);
  tick(dut);
  eval_low(dut);
  expect_eq("four group ingress entries fire together", 0xf,
            dut.group_exec_fire_o);
  tick(dut);

  const Completion dual_a = consume_completion(dut);
  const Completion dual_b = consume_completion(dut);
  const Completion* context0 = dual_a.context == 0 ? &dual_a : &dual_b;
  const Completion* context1 = dual_a.context == 1 ? &dual_a : &dual_b;
  expect_normal_completion(*context0, 0, 10, 0x3);
  expect_normal_completion(*context1, 1, 11, 0xc);
  wait_cluster_empty(dut);

  // Pre-dispatch failures have a real buffered completion destination and do
  // not touch any group.  First test an empty mask, then an owner mismatch.
  enqueue(dut, 0, 20, 0x0, kOpAdd, 0, 1, 5, true);
  Completion rejected = consume_completion(dut);
  expect_eq("empty reject tag", 20, rejected.tag);
  expect_eq("empty reject illegal", 1, rejected.illegal);
  expect_eq("empty reject marked", 1, rejected.rejected);
  expect_eq("empty reject cause", 1, rejected.empty_mask);
  expect_eq("empty reject no owner cause", 0, rejected.owner_mismatch);
  expect_eq("empty reject has no group", 0, rejected.group_mask);

  enqueue(dut, 0, 21, 0x8, kOpAdd, 0, 1, 5, true);
  rejected = consume_completion(dut);
  expect_eq("owner reject tag", 21, rejected.tag);
  expect_eq("owner reject illegal", 1, rejected.illegal);
  expect_eq("owner reject marked", 1, rejected.rejected);
  expect_eq("owner reject not empty", 0, rejected.empty_mask);
  expect_eq("owner reject cause", 1, rejected.owner_mismatch);
  expect_eq("owner reject mask", 0x8, rejected.group_mask);

  // An illegal canonical operation is dispatched, completes exactly once and
  // reports the physical child that rejected it; this is distinct from a
  // pre-dispatch ownership error.
  enqueue(dut, 0, 22, 0x1, 0x3f, 0, 1, 5, false);
  const Completion illegal = consume_completion(dut);
  expect_eq("endpoint illegal tag", 22, illegal.tag);
  expect_eq("endpoint illegal", 1, illegal.illegal);
  expect_eq("endpoint illegal group", 0x1,
            illegal.illegal_group_mask);
  expect_eq("endpoint illegal not reject", 0, illegal.rejected);
  wait_cluster_empty(dut);

  eval_low(dut);
  expect_eq("no final protocol error", 0, dut.protocol_error_o);
  expect_eq("final tracker empty", 0, dut.tracker_occupancy_o);
  expect_eq("final ingress empty", 0, dut.group_ingress_valid_o);

  std::cout << "PASS simd_cluster_exec_shell " << checks << " checks\n";
  return 0;
}
