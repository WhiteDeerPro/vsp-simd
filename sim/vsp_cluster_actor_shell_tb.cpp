// Integration checks for the shell in which one MEMORY span actor and one
// row-level EXCHANGE actor share the single group VRF boundary through
// vsp_cluster_vrf_service.
//
// CLASS:        protocol safety + decoded integration
// CLAIM:        the row exchange engine reaches real group VRF rows through the
//               shared service, and both actors can be in flight concurrently
//               without corrupting each other's returns.
// ORACLE:       an independent C++ Benes reference for the permutation, a byte
//               array for local memory, and an inverse-route metamorphic check.
// ASSUMPTIONS:  4 groups, 4-byte rows, one context owning every group.
// NON_CLAIMS:   no route table, class router, program-order enforcement,
//               owner/resource controller, or physical local SRAM.
// RETIRE_WHEN:  a class router owns cross-class ordering and this hand-built
//               sequencing is replaced by decoded program order.

#include "Vvsp_cluster_actor_shell.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kRowBytes = 4;
constexpr unsigned kStages = 3;             // 2*log2(4) - 1
constexpr unsigned kSwitchesPerStage = 2;   // 4 / 2
constexpr unsigned kControlBits = kStages * kSwitchesPerStage;

constexpr uint8_t kMemLoad = 0;
constexpr uint8_t kMemStore = 1;
constexpr uint8_t kAddrLocal = 0;
constexpr uint8_t kFaultNone = 0;
constexpr uint8_t kMemCplOk = 0;
constexpr uint8_t kXchgCplOk = 0;
constexpr uint8_t kOpAdd = 0x00;
constexpr uint8_t kElemByte = 0;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& what, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << what << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& what, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(what, expected, actual);
}

// Independent Benes reference. This mirrors the network's wiring rule, not the
// exchange engine's sequencing, so it stays usable as a data-path oracle.
template <typename T>
std::array<T, kGroups> route_reference(unsigned control,
                                      std::array<T, kGroups> wires) {
  for (unsigned stage = 0; stage < kStages; ++stage) {
    std::array<T, kGroups> switched{};
    for (unsigned sw = 0; sw < kSwitchesPerStage; ++sw) {
      const unsigned even = 2 * sw;
      const unsigned odd = even + 1;
      const bool cross = (control >> (stage * kSwitchesPerStage + sw)) & 1u;
      switched[even] = cross ? wires[odd] : wires[even];
      switched[odd] = cross ? wires[even] : wires[odd];
    }
    if (stage == kStages - 1) return switched;

    std::array<T, kGroups> next{};
    for (unsigned link = 0; link < kGroups; ++link) {
      unsigned next_link;
      if (stage == 0) {
        next_link = ((link << 1) & (kGroups - 1)) | (link >> 1);
      } else {
        next_link = (link >> 1) | ((link & 1u) << 1);
      }
      next[next_link] = switched[link];
    }
    wires = next;
  }
  std::abort();
}

// permutation(control)[destination] == contributing source group.
std::array<unsigned, kGroups> permutation(unsigned control) {
  return route_reference<unsigned>(control, {0, 1, 2, 3});
}

unsigned find_control(const std::array<unsigned, kGroups>& target) {
  for (unsigned control = 0; control < (1u << kControlBits); ++control) {
    if (permutation(control) == target) return control;
  }
  fail("permutation is reachable", 1, 0);
}

unsigned pack_masks(const std::array<unsigned, kGroups>& masks) {
  unsigned packed = 0;
  for (unsigned group = 0; group < kGroups; ++group)
    packed |= (masks[group] & 0xfu) << (group * kRowBytes);
  return packed;
}

unsigned group_mask_of(const std::array<unsigned, kGroups>& masks) {
  unsigned result = 0;
  for (unsigned group = 0; group < kGroups; ++group)
    if (masks[group] != 0) result |= 1u << group;
  return result;
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

// Blocking single-outstanding local memory behind the dmem_* logical port.
// This is a harness model, not evidence of a physical local SRAM.
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

  void drive(Vvsp_cluster_actor_shell& dut) {
    dut.dmem_req_ready_i = !response_pending && ((cycle % 3) != 1);
    dut.dmem_rsp_valid_i = response_pending && response_delay == 0;
    dut.dmem_rsp_rdata_i = response_data;
    dut.dmem_rsp_fault_cause_i = response_fault;
  }

  void step(Vvsp_cluster_actor_shell& dut) {
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
      expect_eq("local address space", kAddrLocal, dut.dmem_req_addr_space_o);
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

void clear_exec_command(Vvsp_cluster_actor_shell& dut) {
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
  dut.exec_cmd_route_enable_i = 0;
  dut.exec_cmd_route_op_i = 0;
  dut.exec_cmd_route_index_i = 0;
  dut.exec_cmd_route_broadcast_index_i = 0;
  dut.exec_cmd_route_slide_amount_i = 0;
  dut.exec_cmd_route_lower_i = 0;
  dut.exec_cmd_route_upper_i = 0;
}

void clear_memory_command(Vvsp_cluster_actor_shell& dut) {
  dut.mem_cmd_valid_i = 0;
  dut.mem_cmd_op_i = kMemLoad;
  dut.mem_cmd_exec_context_i = 0;
  dut.mem_cmd_tag_i = 0;
  dut.mem_cmd_addr_space_i = kAddrLocal;
  dut.mem_cmd_addr_context_i = 0;
  dut.mem_cmd_base_eaddr_i = 0;
  dut.mem_cmd_eaddr_offset_i = 0;
  dut.mem_cmd_group_mask_i = 0;
  dut.mem_cmd_vrf_row_i = 0;
  dut.mem_cmd_span_bytes_i = 0;
}

void clear_exchange_command(Vvsp_cluster_actor_shell& dut) {
  dut.xchg_cmd_valid_i = 0;
  dut.xchg_cmd_exec_context_i = 0;
  dut.xchg_cmd_tag_i = 0;
  dut.xchg_cmd_src_vrf_row_i = 0;
  dut.xchg_cmd_dst_vrf_row_i = 0;
  dut.xchg_cmd_route_entry_valid_i = 0;
  dut.xchg_cmd_route_ctrl_i = 0;
  dut.xchg_cmd_src_group_mask_i = 0;
  dut.xchg_cmd_src_byte_mask_i = 0;
  dut.xchg_cmd_expected_dst_group_mask_i = 0;
}

void clear_inputs(Vvsp_cluster_actor_shell& dut) {
  clear_exec_command(dut);
  clear_memory_command(dut);
  clear_exchange_command(dut);
  dut.group_owner_valid_i = 0;
  dut.group_owner_i = 0;
  dut.exec_cpl_ready_i = 0;
  dut.exec_result_ready_i = 1;
  dut.mem_cpl_ready_i = 0;
  dut.xchg_cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
  dut.dmem_req_ready_i = 0;
  dut.dmem_rsp_valid_i = 0;
  dut.dmem_rsp_rdata_i = 0;
  dut.dmem_rsp_fault_cause_i = kFaultNone;
}

struct ExchangeCommand {
  unsigned context = 0;
  unsigned tag = 0;
  unsigned src_row = 0;
  unsigned dst_row = 0;
  unsigned route_control = 0;
  std::array<unsigned, kGroups> source_masks{0xf, 0xf, 0xf, 0xf};
  unsigned expected_dst_group_mask = 0xf;
};

void apply_exchange_command(Vvsp_cluster_actor_shell& dut,
                            const ExchangeCommand& command) {
  dut.xchg_cmd_valid_i = 1;
  dut.xchg_cmd_exec_context_i = command.context;
  dut.xchg_cmd_tag_i = command.tag;
  dut.xchg_cmd_src_vrf_row_i = command.src_row;
  dut.xchg_cmd_dst_vrf_row_i = command.dst_row;
  dut.xchg_cmd_route_entry_valid_i = 1;
  dut.xchg_cmd_route_ctrl_i = command.route_control;
  dut.xchg_cmd_src_group_mask_i = group_mask_of(command.source_masks);
  dut.xchg_cmd_src_byte_mask_i = pack_masks(command.source_masks);
  dut.xchg_cmd_expected_dst_group_mask_i = command.expected_dst_group_mask;
}

void issue_memory(Vvsp_cluster_actor_shell& dut, LocalMemory& memory,
                  uint8_t op, uint8_t tag, uint32_t base, uint8_t group_mask,
                  uint8_t row, uint8_t span_bytes) {
  clear_memory_command(dut);
  dut.mem_cmd_valid_i = 1;
  dut.mem_cmd_op_i = op;
  dut.mem_cmd_tag_i = tag;
  dut.mem_cmd_addr_context_i = 0x5a;
  dut.mem_cmd_base_eaddr_i = base;
  dut.mem_cmd_group_mask_i = group_mask;
  dut.mem_cmd_vrf_row_i = row;
  dut.mem_cmd_span_bytes_i = span_bytes;

  for (int timeout = 0; timeout < 200; ++timeout) {
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

void issue_exchange(Vvsp_cluster_actor_shell& dut, LocalMemory& memory,
                    const ExchangeCommand& command) {
  clear_exchange_command(dut);
  apply_exchange_command(dut, command);

  for (int timeout = 0; timeout < 200; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    if (dut.xchg_cmd_ready_o) {
      memory.step(dut);
      clear_exchange_command(dut);
      return;
    }
    memory.step(dut);
  }
  std::cerr << "timeout issuing EXCHANGE command\n";
  std::exit(1);
}

void issue_add_immediate(Vvsp_cluster_actor_shell& dut, LocalMemory& memory,
                         uint8_t tag, uint8_t src_row, uint8_t dst_row,
                         uint8_t immediate) {
  clear_exec_command(dut);
  dut.exec_cmd_valid_i = 1;
  dut.exec_cmd_tag_i = tag;
  dut.exec_cmd_group_mask_i = 0xf;
  dut.exec_cmd_op_i = kOpAdd;
  dut.exec_cmd_elem_mode_i = kElemByte;
  dut.exec_cmd_src_a_addr_i = src_row;
  dut.exec_cmd_use_imm_i = 1;
  dut.exec_cmd_imm_i = immediate;
  dut.exec_cmd_dst_vrf_addr_i = dst_row;
  dut.exec_cmd_write_vrf_i = 1;

  for (int timeout = 0; timeout < 200; ++timeout) {
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
  std::cerr << "timeout issuing GROUP_EXEC command\n";
  std::exit(1);
}

void consume_memory_completion(Vvsp_cluster_actor_shell& dut,
                               LocalMemory& memory, uint8_t op, uint8_t tag,
                               uint8_t group_mask, uint8_t bytes) {
  for (int timeout = 0; timeout < 2000; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    if (!dut.mem_cpl_valid_o) {
      memory.step(dut);
      continue;
    }

    expect_eq("MEMORY completion op", op, dut.mem_cpl_op_o);
    expect_eq("MEMORY completion tag", tag, dut.mem_cpl_tag_o);
    expect_eq("MEMORY completion status", kMemCplOk, dut.mem_cpl_status_o);
    expect_eq("MEMORY completion fault", kFaultNone,
              dut.mem_cpl_fault_cause_o);
    expect_eq("MEMORY requested mask", group_mask,
              dut.mem_cpl_requested_group_mask_o);
    expect_eq("MEMORY completed mask", group_mask,
              dut.mem_cpl_completed_group_mask_o);
    expect_eq("MEMORY failed mask", 0, dut.mem_cpl_failed_group_mask_o);
    expect_eq("MEMORY committed bytes", bytes, dut.mem_cpl_bytes_committed_o);
    expect_eq("MEMORY not partial", 0, dut.mem_cpl_partial_o);

    // Hold the parent completion and require every reported field to stay put.
    for (int held = 0; held < 4; ++held) {
      memory.step(dut);
      memory.drive(dut);
      dut.clk_i = 0;
      dut.eval();
      expect_eq("held MEMORY completion valid", 1, dut.mem_cpl_valid_o);
      expect_eq("held MEMORY completion tag", tag, dut.mem_cpl_tag_o);
      expect_eq("held MEMORY completed mask", group_mask,
                dut.mem_cpl_completed_group_mask_o);
      expect_eq("held MEMORY byte count", bytes,
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

void consume_exchange_completion(Vvsp_cluster_actor_shell& dut,
                                 LocalMemory& memory, uint8_t tag,
                                 unsigned src_mask, unsigned dst_mask) {
  for (int timeout = 0; timeout < 2000; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    if (!dut.xchg_cpl_valid_o) {
      memory.step(dut);
      continue;
    }

    expect_eq("EXCHANGE completion tag", tag, dut.xchg_cpl_tag_o);
    expect_eq("EXCHANGE completion status", kXchgCplOk, dut.xchg_cpl_status_o);
    expect_eq("EXCHANGE requested src mask", src_mask,
              dut.xchg_cpl_requested_src_group_mask_o);
    expect_eq("EXCHANGE requested dst mask", dst_mask,
              dut.xchg_cpl_requested_dst_group_mask_o);
    expect_eq("EXCHANGE completed mask", dst_mask,
              dut.xchg_cpl_completed_group_mask_o);
    expect_eq("EXCHANGE failed mask", 0, dut.xchg_cpl_failed_group_mask_o);
    expect_eq("EXCHANGE not partial", 0, dut.xchg_cpl_partial_o);

    for (int held = 0; held < 4; ++held) {
      memory.step(dut);
      memory.drive(dut);
      dut.clk_i = 0;
      dut.eval();
      expect_eq("held EXCHANGE completion valid", 1, dut.xchg_cpl_valid_o);
      expect_eq("held EXCHANGE completion tag", tag, dut.xchg_cpl_tag_o);
      expect_eq("held EXCHANGE completed mask", dst_mask,
                dut.xchg_cpl_completed_group_mask_o);
      expect_eq("held EXCHANGE status", kXchgCplOk, dut.xchg_cpl_status_o);
    }

    dut.xchg_cpl_ready_i = 1;
    memory.step(dut);
    dut.xchg_cpl_ready_i = 0;
    return;
  }
  std::cerr << "timeout waiting for EXCHANGE completion\n";
  std::exit(1);
}

void consume_exec_completion(Vvsp_cluster_actor_shell& dut,
                             LocalMemory& memory, uint8_t tag) {
  for (int timeout = 0; timeout < 2000; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    if (!dut.exec_cpl_valid_o) {
      memory.step(dut);
      continue;
    }

    expect_eq("EXEC completion tag", tag, dut.exec_cpl_tag_o);
    expect_eq("EXEC completion group mask", 0xf, dut.exec_cpl_group_mask_o);
    expect_eq("EXEC completion legal", 0, dut.exec_cpl_illegal_o);
    expect_eq("EXEC not rejected", 0, dut.exec_cpl_rejected_o);
    expect_eq("EXEC owner matched", 0, dut.exec_cpl_owner_mismatch_o);

    dut.exec_cpl_ready_i = 1;
    memory.step(dut);
    dut.exec_cpl_ready_i = 0;
    return;
  }
  std::cerr << "timeout waiting for GROUP_EXEC completion\n";
  std::exit(1);
}

// Present a MEMORY and an EXCHANGE command in the same cycle and let the
// service interleave their VRF children. The two commands must address
// disjoint VRF rows: this shell has no cross-class program order, so overlap
// would be a scheduling question for a future controller, not a shell bug.
void run_concurrent_pair(Vvsp_cluster_actor_shell& dut, LocalMemory& memory,
                         uint8_t mem_tag, uint32_t mem_base,
                         uint8_t mem_row, uint8_t mem_span,
                         const ExchangeCommand& exchange) {
  clear_memory_command(dut);
  clear_exchange_command(dut);
  dut.mem_cmd_valid_i = 1;
  dut.mem_cmd_op_i = kMemLoad;
  dut.mem_cmd_tag_i = mem_tag;
  dut.mem_cmd_addr_context_i = 0x5a;
  dut.mem_cmd_base_eaddr_i = mem_base;
  dut.mem_cmd_group_mask_i = 0xf;
  dut.mem_cmd_vrf_row_i = mem_row;
  dut.mem_cmd_span_bytes_i = mem_span;
  apply_exchange_command(dut, exchange);

  bool memory_accepted = false;
  bool exchange_accepted = false;
  bool memory_done = false;
  bool exchange_done = false;
  const unsigned exchange_src_mask = group_mask_of(exchange.source_masks);

  dut.mem_cpl_ready_i = 1;
  dut.xchg_cpl_ready_i = 1;

  for (int timeout = 0; timeout < 4000; ++timeout) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();

    if (!memory_accepted && dut.mem_cmd_ready_o) memory_accepted = true;
    if (!exchange_accepted && dut.xchg_cmd_ready_o) exchange_accepted = true;

    if (dut.mem_cpl_valid_o) {
      expect_eq("concurrent MEMORY tag", mem_tag, dut.mem_cpl_tag_o);
      expect_eq("concurrent MEMORY status", kMemCplOk, dut.mem_cpl_status_o);
      expect_eq("concurrent MEMORY completed mask", 0xf,
                dut.mem_cpl_completed_group_mask_o);
      expect_eq("concurrent MEMORY not partial", 0, dut.mem_cpl_partial_o);
      expect_eq("MEMORY completion arrives once", 0, memory_done);
      memory_done = true;
    }
    if (dut.xchg_cpl_valid_o) {
      expect_eq("concurrent EXCHANGE tag", exchange.tag, dut.xchg_cpl_tag_o);
      expect_eq("concurrent EXCHANGE status", kXchgCplOk,
                dut.xchg_cpl_status_o);
      expect_eq("concurrent EXCHANGE src mask", exchange_src_mask,
                dut.xchg_cpl_requested_src_group_mask_o);
      expect_eq("concurrent EXCHANGE completed mask",
                exchange.expected_dst_group_mask,
                dut.xchg_cpl_completed_group_mask_o);
      expect_eq("concurrent EXCHANGE not partial", 0, dut.xchg_cpl_partial_o);
      expect_eq("EXCHANGE completion arrives once", 0, exchange_done);
      exchange_done = true;
    }

    memory.step(dut);

    if (memory_accepted) clear_memory_command(dut);
    if (exchange_accepted) clear_exchange_command(dut);
    if (memory_done && exchange_done) {
      dut.mem_cpl_ready_i = 0;
      dut.xchg_cpl_ready_i = 0;
      expect_eq("both commands were accepted", 1,
                memory_accepted && exchange_accepted);
      return;
    }
  }
  std::cerr << "timeout in concurrent MEMORY + EXCHANGE pair\n";
  std::exit(1);
}
}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_cluster_actor_shell dut;
  LocalMemory memory;

  clear_inputs(dut);
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 4; ++cycle) memory.step(dut);
  dut.rst_ni = 1;
  memory.step(dut);

  // Every group belongs to context zero in this integration profile.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0;

  constexpr uint32_t kLoadBase = 0x20;
  constexpr uint32_t kStoreBase = 0x80;
  constexpr uint8_t kSrcRow = 2;
  constexpr uint8_t kXchgRow = 5;
  constexpr uint8_t kBackRow = 6;
  const std::array<uint32_t, kGroups> source_words = {
      0x04030201U, 0x281e140aU, 0xfdfcfbfaU, 0xff800700U};

  for (unsigned group = 0; group < kGroups; ++group)
    store_word(memory.bytes, kLoadBase + 4 * group, source_words[group], 0xf);

  // 1. MEMORY still reaches every group through the shared service.
  issue_memory(dut, memory, kMemLoad, 0x31, kLoadBase, 0xf, kSrcRow, 16);
  consume_memory_completion(dut, memory, kMemLoad, 0x31, 0xf, 16);
  expect_eq("LOAD issued four SRAM reads", 4, memory.loads);
  expect_eq("VRF service idle after LOAD", 0, dut.vrf_service_busy_o);

  // 2. One EXCHANGE pass over real group rows, checked against the reference.
  // A rotation is deliberately not self-inverse, so the recovery check below
  // needs a genuinely different route entry.
  const std::array<unsigned, kGroups> target = {1, 2, 3, 0};
  const unsigned control = find_control(target);
  ExchangeCommand pass;
  pass.tag = 0x44;
  pass.src_row = kSrcRow;
  pass.dst_row = kXchgRow;
  pass.route_control = control;
  pass.expected_dst_group_mask = 0xf;
  issue_exchange(dut, memory, pass);
  consume_exchange_completion(dut, memory, 0x44, 0xf, 0xf);
  expect_eq("EXCHANGE consumed no memory beats", 4, memory.requests);
  expect_eq("VRF service idle after EXCHANGE", 0, dut.vrf_service_busy_o);

  // Store the exchanged row and compare against the independent permutation.
  issue_memory(dut, memory, kMemStore, 0x55, kStoreBase, 0xf, kXchgRow, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x55, 0xf, 16);
  const auto output_source = permutation(control);
  for (unsigned group = 0; group < kGroups; ++group) {
    expect_eq("exchanged group " + std::to_string(group),
              source_words[output_source[group]],
              load_word(memory.bytes, kStoreBase + 4 * group));
  }

  // 3. GROUP_EXEC still runs against the same register file.
  constexpr uint32_t kExecBase = 0xa0;
  issue_add_immediate(dut, memory, 0x62, kSrcRow, 3, 3);
  consume_exec_completion(dut, memory, 0x62);
  issue_memory(dut, memory, kMemStore, 0x63, kExecBase, 0xf, 3, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x63, 0xf, 16);
  for (unsigned group = 0; group < kGroups; ++group) {
    uint32_t expected = 0;
    for (unsigned byte = 0; byte < 4; ++byte) {
      const uint8_t lane = uint8_t(source_words[group] >> (8 * byte));
      expected |= uint32_t(uint8_t(lane + 3)) << (8 * byte);
    }
    expect_eq("ADD-immediate group " + std::to_string(group), expected,
              load_word(memory.bytes, kExecBase + 4 * group));
  }

  // 4. Inverse route recovers the original rows. The oracle here is the
  // metamorphic property, not a second copy of the routing algorithm.
  std::array<unsigned, kGroups> inverse_target{};
  for (unsigned dst = 0; dst < kGroups; ++dst)
    inverse_target[output_source[dst]] = dst;
  const unsigned inverse_control = find_control(inverse_target);
  expect_eq("inverse route differs from forward route", 1,
            inverse_control != control);

  constexpr uint32_t kRecoverBase = 0xc0;
  ExchangeCommand back;
  back.tag = 0x71;
  back.src_row = kXchgRow;
  back.dst_row = kBackRow;
  back.route_control = inverse_control;
  back.expected_dst_group_mask = 0xf;
  issue_exchange(dut, memory, back);
  consume_exchange_completion(dut, memory, 0x71, 0xf, 0xf);
  issue_memory(dut, memory, kMemStore, 0x72, kRecoverBase, 0xf, kBackRow, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x72, 0xf, 16);
  for (unsigned group = 0; group < kGroups; ++group) {
    expect_eq("inverse route restored group " + std::to_string(group),
              source_words[group],
              load_word(memory.bytes, kRecoverBase + 4 * group));
  }

  // 5. Sparse source mask: one group contributes nothing, so its routed
  // destination must be left untouched rather than written with zeros.
  constexpr uint32_t kPrefillBase = 0x40;
  constexpr uint32_t kSparseBase = 0xe0;
  constexpr uint8_t kSparseRow = 7;
  const std::array<uint32_t, kGroups> prefill_words = {
      0x11111111U, 0x22222222U, 0x33333333U, 0x44444444U};
  for (unsigned group = 0; group < kGroups; ++group) {
    store_word(memory.bytes, kPrefillBase + 4 * group, prefill_words[group],
               0xf);
  }
  issue_memory(dut, memory, kMemLoad, 0x81, kPrefillBase, 0xf, kSparseRow, 16);
  consume_memory_completion(dut, memory, kMemLoad, 0x81, 0xf, 16);

  constexpr unsigned kIdleSource = 1;
  ExchangeCommand sparse;
  sparse.tag = 0x82;
  sparse.src_row = kSrcRow;
  sparse.dst_row = kSparseRow;
  sparse.route_control = control;
  sparse.source_masks = {0xf, 0xf, 0xf, 0xf};
  sparse.source_masks[kIdleSource] = 0x0;
  unsigned sparse_dst_mask = 0;
  for (unsigned dst = 0; dst < kGroups; ++dst)
    if (output_source[dst] != kIdleSource) sparse_dst_mask |= 1u << dst;
  sparse.expected_dst_group_mask = sparse_dst_mask;

  issue_exchange(dut, memory, sparse);
  consume_exchange_completion(dut, memory, 0x82,
                              group_mask_of(sparse.source_masks),
                              sparse_dst_mask);
  issue_memory(dut, memory, kMemStore, 0x83, kSparseBase, 0xf, kSparseRow, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x83, 0xf, 16);
  for (unsigned group = 0; group < kGroups; ++group) {
    const bool written = (sparse_dst_mask >> group) & 1u;
    const uint32_t expected = written ? source_words[output_source[group]]
                                     : prefill_words[group];
    expect_eq("sparse exchange group " + std::to_string(group), expected,
              load_word(memory.bytes, kSparseBase + 4 * group));
  }

  // 6. Both actors in flight at once over disjoint rows. This is the claim the
  // reserved second service client existed for.
  constexpr uint8_t kConcurrentLoadRow = 9;
  constexpr uint8_t kConcurrentXchgRow = 10;
  constexpr uint32_t kConcurrentStoreA = 0x60;
  constexpr uint32_t kConcurrentStoreB = 0x00;
  const uint64_t requests_before = memory.requests;

  ExchangeCommand concurrent;
  concurrent.tag = 0x91;
  concurrent.src_row = kXchgRow;
  concurrent.dst_row = kConcurrentXchgRow;
  concurrent.route_control = inverse_control;
  concurrent.expected_dst_group_mask = 0xf;
  run_concurrent_pair(dut, memory, 0x90, kLoadBase, kConcurrentLoadRow, 16,
                      concurrent);
  expect_eq("concurrent pair used four LOAD beats", 4,
            memory.requests - requests_before);
  expect_eq("VRF service idle after concurrent pair", 0,
            dut.vrf_service_busy_o);
  expect_eq("MEMORY engine idle after concurrent pair", 0, dut.mem_busy_o);
  expect_eq("EXCHANGE engine idle after concurrent pair", 0, dut.xchg_busy_o);

  issue_memory(dut, memory, kMemStore, 0x92, kConcurrentStoreA, 0xf,
               kConcurrentLoadRow, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x92, 0xf, 16);
  for (unsigned group = 0; group < kGroups; ++group) {
    expect_eq("concurrent LOAD landed group " + std::to_string(group),
              source_words[group],
              load_word(memory.bytes, kConcurrentStoreA + 4 * group));
  }

  issue_memory(dut, memory, kMemStore, 0x93, kConcurrentStoreB, 0xf,
               kConcurrentXchgRow, 16);
  consume_memory_completion(dut, memory, kMemStore, 0x93, 0xf, 16);
  for (unsigned group = 0; group < kGroups; ++group) {
    expect_eq("concurrent EXCHANGE landed group " + std::to_string(group),
              source_words[group],
              load_word(memory.bytes, kConcurrentStoreB + 4 * group));
  }

  // 7. Everything quiesced and no sticky diagnostics anywhere.
  expect_eq("request backpressure occurred", 1,
            memory.request_stall_cycles != 0);
  expect_eq("MEMORY engine idle", 0, dut.mem_busy_o);
  expect_eq("EXCHANGE engine idle", 0, dut.xchg_busy_o);
  expect_eq("VRF service idle", 0, dut.vrf_service_busy_o);
  expect_eq("EXEC protocol clean", 0, dut.exec_protocol_error_o);
  expect_eq("MEMORY protocol clean", 0, dut.mem_protocol_error_o);
  expect_eq("EXCHANGE protocol clean", 0, dut.xchg_protocol_error_o);
  expect_eq("combined protocol clean", 0, dut.protocol_error_o);

  dut.final();
  std::cout << "PASS: VSP cluster actor shell " << checks
            << " checks across MEMORY, EXCHANGE, inverse recovery, sparse"
               " masks, and concurrent two-client arbitration\n";
  return 0;
}
