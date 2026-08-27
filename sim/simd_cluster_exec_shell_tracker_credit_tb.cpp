#include "Vsimd_cluster_exec_shell.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr uint8_t kOpAdd = 0x00;
constexpr uint8_t kTagSlot0 = 0x41;
constexpr uint8_t kTagSlot1 = 0x82;
constexpr uint8_t kResourceSlot0 = 0xa1;
constexpr uint8_t kResourceSlot1 = 0xb2;

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

void clear_inputs(Vsimd_cluster_exec_shell& dut) {
  clear_command(dut);
  dut.group_owner_valid_i = 0;
  dut.group_owner_i = 0;
  dut.issue_slot_grant_i = 0;
  dut.state_write_valid_i = 0;
  dut.state_write_group_i = 0;
  dut.state_write_context_i = 0;
  dut.state_write_tag_i = 0;
  dut.state_write_file_i = 0;
  dut.state_write_addr_i = 0;
  dut.state_write_mask_i = 0;
  for (int word = 0; word < 4; ++word) dut.state_write_data_i[word] = 0;
  dut.state_cpl_ready_i = 0;
  dut.cpl_ready_i = 0;
  dut.result_ready_i = 1;
  dut.protocol_error_clear_i = 0;
}

void enqueue(Vsimd_cluster_exec_shell& dut, uint8_t context, uint8_t tag,
             uint8_t group_mask, uint8_t resource, uint8_t destination) {
  clear_command(dut);
  dut.cmd_valid_i = 1;
  dut.cmd_context_i = context;
  dut.cmd_tag_i = tag;
  dut.cmd_group_mask_i = group_mask;
  dut.cmd_exact_resource_i = resource;
  dut.cmd_op_i = kOpAdd;
  dut.cmd_src_a_addr_i = 0;
  dut.cmd_src_b_addr_i = 1;
  dut.cmd_dst_vrf_addr_i = destination;
  dut.cmd_write_vrf_i = 1;

  for (int timeout = 0; timeout < 20; ++timeout) {
    eval_low(dut);
    expect_eq("enqueue context remains valid", 0, dut.cmd_context_error_o);
    if (dut.cmd_ready_o) {
      tick(dut);
      clear_command(dut);
      return;
    }
    tick(dut);
  }
  std::cerr << "timeout enqueue tag=0x" << std::hex << unsigned(tag) << '\n';
  std::exit(1);
}

void wait_for_both_slots(Vsimd_cluster_exec_shell& dut) {
  for (int timeout = 0; timeout < 20; ++timeout) {
    eval_low(dut);
    if (dut.issue_slot_valid_o == 0x3) return;
    expect_eq("no issue while all grants are withheld", 0,
              dut.issue_accept_o);
    tick(dut);
  }
  fail("both issue slots become resident", 0x3, dut.issue_slot_valid_o);
}

void wait_for_completion(Vsimd_cluster_exec_shell& dut, uint8_t context,
                         uint8_t tag, uint8_t group_mask) {
  for (int timeout = 0; timeout < 40; ++timeout) {
    eval_low(dut);
    if (dut.cpl_valid_o) {
      expect_eq("completion context", context, dut.cpl_context_o);
      expect_eq("completion tag", tag, dut.cpl_tag_o);
      expect_eq("completion group mask", group_mask, dut.cpl_group_mask_o);
      expect_eq("completion has no result", 0, dut.cpl_result_mask_o);
      expect_eq("completion is legal", 0, dut.cpl_illegal_o);
      expect_eq("completion has no illegal child", 0,
                dut.cpl_illegal_group_mask_o);
      expect_eq("completion is not a reject", 0, dut.cpl_rejected_o);
      dut.cpl_ready_i = 1;
      tick(dut);
      dut.cpl_ready_i = 0;
      return;
    }
    tick(dut);
  }
  std::cerr << "timeout completion tag=0x" << std::hex << unsigned(tag)
            << '\n';
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

  // Physical groups 0/1 belong to context 0; groups 2/3 belong to context 1.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0xc;
  dut.issue_slot_grant_i = 0;
  eval_low(dut);
  expect_eq("tracker empty after reset", 0, dut.tracker_occupancy_o);
  expect_eq("no protocol error after reset", 0, dut.protocol_error_o);

  // RR starts at context 0, so these become stable slot0 and slot1 heads.  No
  // issue grant is present while both commands are made resident.
  enqueue(dut, 0, kTagSlot0, 0x1, kResourceSlot0, 2);
  enqueue(dut, 1, kTagSlot1, 0x4, kResourceSlot1, 3);
  wait_for_both_slots(dut);
  eval_low(dut);
  expect_eq("slot0 group mask", 0x1,
            dut.issue_slot_group_mask_o & 0xf);
  expect_eq("slot1 group mask", 0x4,
            (dut.issue_slot_group_mask_o >> 4) & 0xf);
  expect_eq("slot0 resource metadata", kResourceSlot0,
            dut.issue_slot_resource_o & 0xff);
  expect_eq("slot1 resource metadata", kResourceSlot1,
            (dut.issue_slot_resource_o >> 8) & 0xff);

  // With only one tracker entry, an ungranted slot0 must not preview-reserve
  // that entry.  Slot1 is otherwise independent and must fire immediately.
  dut.issue_slot_grant_i = 0x2;
  eval_low(dut);
  expect_eq("slot1 receives the sole tracker credit", 0x2,
            dut.issue_accept_o);
  expect_eq("slot0 does not issue without grant", 0,
            dut.issue_accept_o & 0x1);
  expect_eq("ingress is empty before the accepting edge", 0,
            dut.group_ingress_valid_o);
  tick(dut);
  expect_eq("one tracker entry allocated to slot1", 1,
            dut.tracker_occupancy_o);
  expect_eq("slot1 entered only group2 ingress", 0x4,
            dut.group_ingress_valid_o);
  expect_eq("slot0 remains resident", 0x1,
            dut.issue_slot_valid_o & 0x1);

  wait_for_completion(dut, 1, kTagSlot1, 0x4);

  // The completion returned the unique entry.  Granting slot0 now lets the
  // older held command make forward progress and complete normally.
  dut.issue_slot_grant_i = 0x1;
  bool slot0_fired = false;
  for (int timeout = 0; timeout < 10; ++timeout) {
    eval_low(dut);
    if (dut.issue_accept_o == 0x1) {
      slot0_fired = true;
      tick(dut);
      break;
    }
    expect_eq("slot1 cannot reissue", 0, dut.issue_accept_o & 0x2);
    tick(dut);
  }
  expect_eq("slot0 fires after credit returns", 1, slot0_fired);
  wait_for_completion(dut, 0, kTagSlot0, 0x1);

  dut.issue_slot_grant_i = 0;
  for (int timeout = 0; timeout < 10; ++timeout) {
    eval_low(dut);
    if (dut.tracker_occupancy_o == 0 &&
        dut.group_ingress_valid_o == 0 &&
        dut.queue_occupancy_o == 0) {
      break;
    }
    tick(dut);
  }
  eval_low(dut);
  expect_eq("tracker drains", 0, dut.tracker_occupancy_o);
  expect_eq("ingress drains", 0, dut.group_ingress_valid_o);
  expect_eq("both queues drain", 0, dut.queue_occupancy_o);
  expect_eq("no terminal protocol error", 0, dut.protocol_error_o);
  expect_eq("no result record", 0, dut.result_valid_o);

  dut.final();
  std::cout << "PASS simd_cluster_exec_shell_tracker_credit " << checks
            << " checks\n";
  return 0;
}
