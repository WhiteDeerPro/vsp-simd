#include "Vvsp_cluster_memory_wrapper.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr uint8_t kMemLoad = 0;
constexpr uint8_t kMemStore = 1;
constexpr uint8_t kAddrModeUnitStride = 0;
constexpr uint8_t kAddrModeIndexU8 = 1;
constexpr uint8_t kAddrLocal = 0;
constexpr uint8_t kFaultNone = 0;
constexpr uint8_t kCplOk = 0;
constexpr uint8_t kOpAdd = 0x00;
constexpr uint8_t kElemByte = 0;

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

uint32_t load_word(const std::array<uint8_t, 256>& bytes, uint32_t address) {
  uint32_t value = 0;
  for (unsigned byte = 0; byte < 4; ++byte)
    value |= uint32_t{bytes.at(address + byte)} << (8 * byte);
  return value;
}

void store_word(std::array<uint8_t, 256>& bytes, uint32_t address,
                uint32_t data, uint8_t strobe) {
  for (unsigned byte = 0; byte < 4; ++byte) {
    if ((strobe >> byte) & 1U)
      bytes.at(address + byte) = uint8_t(data >> (8 * byte));
  }
}

struct LocalMemory {
  std::array<uint8_t, 256> bytes{};
  uint64_t cycle = 0;
  bool response_pending = false;
  unsigned response_delay = 0;
  uint32_t response_data = 0;
  uint8_t response_fault = kFaultNone;
  uint64_t request_stall_cycles = 0;
  uint64_t requests = 0;
  uint64_t loads = 0;
  uint64_t stores = 0;

  void drive(Vvsp_cluster_memory_wrapper& dut) {
    // Refuse one out of every three request cycles. This is sufficient to
    // exercise sustained valid/ready behavior without introducing another
    // outstanding transaction into the blocking reference memory.
    dut.dmem_req_ready_i = !response_pending && ((cycle % 3) != 1);
    dut.dmem_rsp_valid_i = response_pending && response_delay == 0;
    dut.dmem_rsp_rdata_i = response_data;
    dut.dmem_rsp_fault_cause_i = response_fault;
  }

  void step(Vvsp_cluster_memory_wrapper& dut) {
    drive(dut);
    dut.clk_i = 0;
    dut.eval();

    const bool request_valid = dut.dmem_req_valid_o != 0;
    const bool request_fire = request_valid && dut.dmem_req_ready_i;
    const bool response_fire = dut.dmem_rsp_valid_i && dut.dmem_rsp_ready_o;
    if (request_valid && !dut.dmem_req_ready_i) ++request_stall_cycles;

    uint8_t request_op = 0;
    uint32_t request_address = 0;
    uint32_t request_wdata = 0;
    uint8_t request_wstrb = 0;
    if (request_fire) {
      request_op = dut.dmem_req_op_o;
      request_address = dut.dmem_req_eaddr_o;
      request_wdata = dut.dmem_req_wdata_o;
      request_wstrb = dut.dmem_req_wstrb_o;
      expect_eq("local address space", kAddrLocal,
                dut.dmem_req_addr_space_o);
      expect_eq("address context", 0x5a, dut.dmem_req_addr_context_o);
      expect_eq("request is in SRAM range", 1,
                request_address + 4 <= bytes.size());
    }

    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();

    const bool old_pending = response_pending;
    if (response_fire) response_pending = false;
    else if (old_pending && response_delay != 0) --response_delay;

    if (request_fire) {
      expect_eq("single-outstanding memory model", 0,
                old_pending && !response_fire);
      ++requests;
      if (request_op == kMemLoad) {
        ++loads;
        response_data = load_word(bytes, request_address);
      } else {
        ++stores;
        store_word(bytes, request_address, request_wdata, request_wstrb);
        response_data = 0;
      }
      response_fault = kFaultNone;
      response_pending = true;
      response_delay = 1 + unsigned((cycle / 2) & 1U);
    }

    ++cycle;
  }
};

void clear_exec_command(Vvsp_cluster_memory_wrapper& dut) {
  dut.exec_cmd_valid_i = 0;
  dut.exec_cmd_context_i = 0;
  dut.exec_cmd_tag_i = 0;
  dut.exec_cmd_group_mask_i = 0;
  dut.exec_cmd_exact_resource_i = 0;
  dut.exec_cmd_export_narrow_i = 0;
  dut.exec_cmd_op_i = 0;
  dut.exec_cmd_elem_mode_i = 0;
  dut.exec_cmd_src_a_addr_i = 0;
  dut.exec_cmd_src_b_addr_i = 0;
  dut.exec_cmd_use_imm_i = 0;
  dut.exec_cmd_imm_i = 0;
  dut.exec_cmd_dst_vrf_addr_i = 0;
  dut.exec_cmd_src_arf_addr_i = 0;
  dut.exec_cmd_dst_arf_addr_i = 0;
  dut.exec_cmd_mask_enable_i = 0;
  dut.exec_cmd_mask_addr_i = 0;
  dut.exec_cmd_select_mask_addr_i = 0;
  dut.exec_cmd_dst_mrf_addr_i = 0;
  dut.exec_cmd_write_vrf_i = 0;
  dut.exec_cmd_write_arf_i = 0;
  dut.exec_cmd_write_mrf_i = 0;
  dut.exec_cmd_reduce_enable_i = 0;
  dut.exec_cmd_reduce_op_i = 0;
}

void clear_memory_command(Vvsp_cluster_memory_wrapper& dut) {
  dut.mem_cmd_valid_i = 0;
  dut.mem_cmd_op_i = kMemLoad;
  dut.mem_cmd_addr_mode_i = kAddrModeUnitStride;
  dut.mem_cmd_exec_context_i = 0;
  dut.mem_cmd_tag_i = 0;
  dut.mem_cmd_addr_space_i = kAddrLocal;
  dut.mem_cmd_addr_context_i = 0;
  dut.mem_cmd_base_eaddr_i = 0;
  dut.mem_cmd_eaddr_offset_i = 0;
  dut.mem_cmd_group_mask_i = 0;
  dut.mem_cmd_vrf_row_i = 0;
  dut.mem_cmd_index_vrf_row_i = 0;
  dut.mem_cmd_span_bytes_i = 0;
}

void clear_inputs(Vvsp_cluster_memory_wrapper& dut) {
  clear_exec_command(dut);
  clear_memory_command(dut);
  dut.group_owner_valid_i = 0;
  dut.group_owner_i = 0;
  dut.exec_cpl_ready_i = 0;
  dut.exec_result_ready_i = 1;
  dut.mem_cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
  dut.dmem_req_ready_i = 0;
  dut.dmem_rsp_valid_i = 0;
  dut.dmem_rsp_rdata_i = 0;
  dut.dmem_rsp_fault_cause_i = kFaultNone;
}

void issue_memory(Vvsp_cluster_memory_wrapper& dut, LocalMemory& memory,
                  uint8_t op, uint8_t addr_mode, uint8_t tag, uint32_t base,
                  uint8_t group_mask, uint8_t row, uint8_t index_row,
                  uint8_t span_bytes) {
  clear_memory_command(dut);
  dut.mem_cmd_valid_i = 1;
  dut.mem_cmd_op_i = op;
  dut.mem_cmd_addr_mode_i = addr_mode;
  dut.mem_cmd_exec_context_i = 0;
  dut.mem_cmd_tag_i = tag;
  dut.mem_cmd_addr_space_i = kAddrLocal;
  dut.mem_cmd_addr_context_i = 0x5a;
  dut.mem_cmd_base_eaddr_i = base;
  dut.mem_cmd_eaddr_offset_i = 0;
  dut.mem_cmd_group_mask_i = group_mask;
  dut.mem_cmd_vrf_row_i = row;
  dut.mem_cmd_index_vrf_row_i = index_row;
  dut.mem_cmd_span_bytes_i = span_bytes;

  for (int timeout = 0; timeout < 100; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    if (dut.mem_cmd_ready_o) {
      memory.step(dut);
      clear_memory_command(dut);
      return;
    }
    memory.step(dut);
  }
  std::cerr << "timeout issuing MEMORY command\n";
  std::exit(1);
}

void issue_add_immediate(Vvsp_cluster_memory_wrapper& dut,
                         LocalMemory& memory, uint8_t tag, uint8_t src_row,
                         uint8_t dst_row, uint8_t immediate) {
  clear_exec_command(dut);
  dut.exec_cmd_valid_i = 1;
  dut.exec_cmd_context_i = 0;
  dut.exec_cmd_tag_i = tag;
  dut.exec_cmd_group_mask_i = 0xf;
  dut.exec_cmd_exact_resource_i = 0;
  dut.exec_cmd_op_i = kOpAdd;
  dut.exec_cmd_elem_mode_i = kElemByte;
  dut.exec_cmd_src_a_addr_i = src_row;
  dut.exec_cmd_use_imm_i = 1;
  dut.exec_cmd_imm_i = immediate;
  dut.exec_cmd_dst_vrf_addr_i = dst_row;
  dut.exec_cmd_write_vrf_i = 1;

  for (int timeout = 0; timeout < 100; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    expect_eq("valid EXEC context", 0, dut.exec_cmd_context_error_o);
    if (dut.exec_cmd_ready_o) {
      memory.step(dut);
      clear_exec_command(dut);
      return;
    }
    memory.step(dut);
  }
  std::cerr << "timeout issuing EXEC command\n";
  std::exit(1);
}

void consume_memory_completion(Vvsp_cluster_memory_wrapper& dut,
                               LocalMemory& memory, uint8_t op, uint8_t tag,
                               uint8_t group_mask, uint8_t bytes) {
  for (int timeout = 0; timeout < 1000; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    if (!dut.mem_cpl_valid_o) {
      memory.step(dut);
      continue;
    }

    expect_eq("MEMORY completion op", op, dut.mem_cpl_op_o);
    expect_eq("MEMORY completion context", 0,
              dut.mem_cpl_exec_context_o);
    expect_eq("MEMORY completion tag", tag, dut.mem_cpl_tag_o);
    expect_eq("MEMORY completion status", kCplOk, dut.mem_cpl_status_o);
    expect_eq("MEMORY completion fault", kFaultNone,
              dut.mem_cpl_fault_cause_o);
    expect_eq("MEMORY requested mask", group_mask,
              dut.mem_cpl_requested_group_mask_o);
    expect_eq("MEMORY completed mask", group_mask,
              dut.mem_cpl_completed_group_mask_o);
    expect_eq("MEMORY failed mask", 0, dut.mem_cpl_failed_group_mask_o);
    expect_eq("MEMORY committed bytes", bytes,
              dut.mem_cpl_bytes_committed_o);
    expect_eq("MEMORY not partial", 0, dut.mem_cpl_partial_o);

    // Hold completion back for several cycles and require every payload field
    // used by this successful path to remain stable.
    for (int held = 0; held < 4; ++held) {
      memory.step(dut);
      memory.drive(dut);
      dut.clk_i = 0;
      dut.eval();
      expect_eq("held MEMORY completion valid", 1, dut.mem_cpl_valid_o);
      expect_eq("held MEMORY completion tag", tag, dut.mem_cpl_tag_o);
      expect_eq("held MEMORY completion mask", group_mask,
                dut.mem_cpl_completed_group_mask_o);
      expect_eq("held MEMORY completion byte count", bytes,
                dut.mem_cpl_bytes_committed_o);
    }

    dut.mem_cpl_ready_i = 1;
    memory.step(dut);
    dut.mem_cpl_ready_i = 0;
    return;
  }
  std::cerr << "timeout waiting for MEMORY completion\n";
  std::exit(1);
}

void consume_exec_completion(Vvsp_cluster_memory_wrapper& dut,
                             LocalMemory& memory, uint8_t tag) {
  for (int timeout = 0; timeout < 1000; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    if (!dut.exec_cpl_valid_o) {
      memory.step(dut);
      continue;
    }

    expect_eq("EXEC completion context", 0, dut.exec_cpl_context_o);
    expect_eq("EXEC completion tag", tag, dut.exec_cpl_tag_o);
    expect_eq("EXEC completion group mask", 0xf,
              dut.exec_cpl_group_mask_o);
    expect_eq("EXEC has no result records", 0,
              dut.exec_cpl_result_mask_o);
    expect_eq("EXEC completion legal", 0, dut.exec_cpl_illegal_o);
    expect_eq("EXEC illegal group mask", 0,
              dut.exec_cpl_illegal_group_mask_o);
    expect_eq("EXEC not rejected", 0, dut.exec_cpl_rejected_o);
    expect_eq("EXEC owner matched", 0, dut.exec_cpl_owner_mismatch_o);

    for (int held = 0; held < 3; ++held) {
      memory.step(dut);
      memory.drive(dut);
      dut.clk_i = 0;
      dut.eval();
      expect_eq("held EXEC completion valid", 1, dut.exec_cpl_valid_o);
      expect_eq("held EXEC completion tag", tag, dut.exec_cpl_tag_o);
      expect_eq("held EXEC completion mask", 0xf,
                dut.exec_cpl_group_mask_o);
    }

    dut.exec_cpl_ready_i = 1;
    memory.step(dut);
    dut.exec_cpl_ready_i = 0;
    return;
  }
  std::cerr << "timeout waiting for EXEC completion\n";
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_cluster_memory_wrapper dut;
  LocalMemory memory;

  clear_inputs(dut);
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 4; ++cycle) memory.step(dut);
  dut.rst_ni = 1;
  memory.step(dut);

  // All four groups belong to context zero in this integration profile.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0;

  constexpr uint32_t kLoadBase = 0x20;
  constexpr uint32_t kIndexBase = 0x40;
  constexpr uint32_t kAddedStoreBase = 0x80;
  constexpr uint32_t kGatherStoreBase = 0xa0;
  constexpr uint32_t kScatterBase = 0xc0;
  const std::array<uint32_t, 4> source_words = {
      0x04030201U, 0x281e140aU, 0xfdfcfbfaU, 0xff800700U};
  const std::array<uint32_t, 4> reverse_index_words = {
      0x0c0d0e0fU, 0x08090a0bU, 0x04050607U, 0x00010203U};
  const std::array<uint32_t, 4> added_words = {
      0x07060504U, 0x2b21170dU, 0x00fffefdU, 0x02830a03U};
  const std::array<uint32_t, 4> gathered_words = {
      0x000780ffU, 0xfafbfcfdU, 0x0a141e28U, 0x01020304U};
  for (unsigned group = 0; group < source_words.size(); ++group)
    store_word(memory.bytes, kLoadBase + 4 * group, source_words[group], 0xf);
  for (unsigned group = 0; group < reverse_index_words.size(); ++group)
    store_word(memory.bytes, kIndexBase + 4 * group,
               reverse_index_words[group], 0xf);

  issue_memory(dut, memory, kMemLoad, kAddrModeUnitStride, 0x31,
               kLoadBase, 0xf, 2, 0, 16);
  consume_memory_completion(dut, memory, kMemLoad, 0x31, 0xf, 16);
  expect_eq("LOAD issued four SRAM reads", 4, memory.loads);
  expect_eq("VRF arbiter idle after LOAD", 0, dut.vrf_arbiter_busy_o);

  issue_add_immediate(dut, memory, 0x42, 2, 3, 3);
  consume_exec_completion(dut, memory, 0x42);
  expect_eq("non-exporting ADD produced no result", 0,
            dut.exec_result_valid_o);

  // Read the EXEC-produced row back through the unchanged unit-stride STORE
  // path so the arithmetic result remains observable at the wrapper boundary.
  issue_memory(dut, memory, kMemStore, kAddrModeUnitStride, 0x53,
               kAddedStoreBase, 0xf, 3, 0, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x53, 0xf, 16);
  for (unsigned group = 0; group < added_words.size(); ++group) {
    expect_eq("stored ADD group " + std::to_string(group),
              added_words[group],
              load_word(memory.bytes, kAddedStoreBase + 4 * group));
  }

  // Initialize the distributed index row with an ordinary linear LOAD. The
  // bytes are 15..0, so INDEX_U8 gathers the source window in reverse order.
  issue_memory(dut, memory, kMemLoad, kAddrModeUnitStride, 0x4a,
               kIndexBase, 0xf, 4, 0, 16);
  consume_memory_completion(dut, memory, kMemLoad, 0x4a, 0xf, 16);
  issue_memory(dut, memory, kMemLoad, kAddrModeIndexU8, 0x5b,
               kLoadBase, 0xf, 5, 4, 0);
  consume_memory_completion(dut, memory, kMemLoad, 0x5b, 0xf, 16);
  expect_eq("unit-stride plus gather SRAM reads", 24, memory.loads);

  // A linear STORE exposes the gathered VRF row without any direct testbench
  // access to the group's register file.
  issue_memory(dut, memory, kMemStore, kAddrModeUnitStride, 0x5c,
               kGatherStoreBase, 0xf, 5, 0, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x5c, 0xf, 16);
  for (unsigned group = 0; group < gathered_words.size(); ++group) {
    expect_eq("stored gather group " + std::to_string(group),
              gathered_words[group],
              load_word(memory.bytes, kGatherStoreBase + 4 * group));
  }

  // Reusing the reverse index row for SCATTER maps the reversed data back to
  // its original byte positions. Each selected lane becomes one byte-strobed
  // ordinary STORE request at the external memory boundary.
  issue_memory(dut, memory, kMemStore, kAddrModeIndexU8, 0x6d,
               kScatterBase, 0xf, 5, 4, 0);
  consume_memory_completion(dut, memory, kMemStore, 0x6d, 0xf, 16);
  for (unsigned group = 0; group < source_words.size(); ++group) {
    expect_eq("scattered source group " + std::to_string(group),
              source_words[group],
              load_word(memory.bytes, kScatterBase + 4 * group));
  }

  expect_eq("all linear and indexed SRAM stores", 24, memory.stores);
  expect_eq("total memory requests", 48, memory.requests);
  expect_eq("request backpressure occurred", 1,
            memory.request_stall_cycles != 0);

  memory.drive(dut);
  dut.clk_i = 0;
  dut.eval();
  expect_eq("EXEC quiescent after arithmetic", 1, dut.exec_quiescent_o);

  expect_eq("memory engine idle", 0, dut.mem_busy_o);
  expect_eq("VRF arbiter idle", 0, dut.vrf_arbiter_busy_o);
  expect_eq("EXEC protocol clean", 0, dut.exec_protocol_error_o);
  expect_eq("MEMORY protocol clean", 0, dut.mem_protocol_error_o);
  expect_eq("combined protocol clean", 0, dut.protocol_error_o);

  dut.final();
  std::cout << "PASS: VSP cluster MEMORY wrapper " << checks
            << " checks across unit-stride LOAD/STORE, EXEC, INDEX_U8 "
               "gather/scatter and backpressure\n";
  return 0;
}
