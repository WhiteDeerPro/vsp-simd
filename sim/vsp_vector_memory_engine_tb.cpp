#include "Vvsp_vector_memory_engine.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kRowBytes = 4;

constexpr unsigned kOpLoad = 0;
constexpr unsigned kOpStore = 1;

constexpr unsigned kAddrSpaceLocal = 0;
constexpr unsigned kAddrSpacePhysical = 1;
constexpr unsigned kAddrSpaceTranslated = 2;

constexpr unsigned kFaultNone = 0;
constexpr unsigned kFaultTranslation = 1;
constexpr unsigned kFaultPermission = 2;
constexpr unsigned kFaultAccess = 3;
constexpr unsigned kFaultBus = 4;
constexpr unsigned kFaultDataIntegrity = 5;

constexpr unsigned kStatusOk = 0;
constexpr unsigned kStatusBadRequest = 1;
constexpr unsigned kStatusBadEaddr = 2;
constexpr unsigned kStatusMemoryFault = 3;
constexpr unsigned kStatusVrfError = 4;

uint64_t checks = 0;

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

uint32_t next_random(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

unsigned popcount(unsigned value) {
  unsigned count = 0;
  for (; value != 0; value >>= 1) count += value & 1u;
  return count;
}

unsigned low_mask(unsigned bytes) {
  return bytes == kRowBytes ? 0xfu : ((1u << bytes) - 1u);
}

uint32_t memory_word(uint32_t address) {
  return 0x9e3779b9u ^ (address * 0x01010101u);
}

uint32_t vrf_word(unsigned context, unsigned tag, unsigned group) {
  return 0x40000000u | (context << 28) | (tag << 12) |
         (group * 0x01010101u);
}

void tick(Vvsp_vector_memory_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_vector_memory_engine& dut) {
  dut.cmd_valid_i = 0;
  dut.cmd_op_i = kOpLoad;
  dut.cmd_exec_context_i = 0;
  dut.cmd_tag_i = 0;
  dut.cmd_addr_space_i = kAddrSpaceLocal;
  dut.cmd_addr_context_i = 0;
  dut.cmd_base_eaddr_i = 0;
  dut.cmd_eaddr_offset_i = 0;
  dut.cmd_group_mask_i = 0;
  dut.cmd_vrf_row_i = 0;
  dut.cmd_span_bytes_i = 0;
  dut.dmem_req_ready_i = 0;
  dut.dmem_rsp_valid_i = 0;
  dut.dmem_rsp_rdata_i = 0;
  dut.dmem_rsp_fault_cause_i = kFaultNone;
  dut.vrf_write_ready_i = 0;
  dut.vrf_write_cpl_valid_i = 0;
  dut.vrf_write_cpl_exec_context_i = 0;
  dut.vrf_write_cpl_tag_i = 0;
  dut.vrf_write_cpl_group_i = 0;
  dut.vrf_write_cpl_error_i = 0;
  dut.vrf_read_ready_i = 0;
  dut.vrf_read_cpl_valid_i = 0;
  dut.vrf_read_cpl_exec_context_i = 0;
  dut.vrf_read_cpl_tag_i = 0;
  dut.vrf_read_cpl_group_i = 0;
  dut.vrf_read_cpl_error_i = 0;
  dut.vrf_read_rsp_valid_i = 0;
  dut.vrf_read_rsp_exec_context_i = 0;
  dut.vrf_read_rsp_tag_i = 0;
  dut.vrf_read_rsp_group_i = 0;
  dut.vrf_read_rsp_data_i = 0;
  dut.vrf_read_rsp_mask_i = 0;
  dut.vrf_read_rsp_error_i = 0;
  dut.cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

struct Command {
  bool store = false;
  unsigned exec_context = 0;
  unsigned tag = 0;
  uint32_t base_eaddr = 0;
  int eaddr_offset = 0;
  unsigned group_mask = 0;
  unsigned vrf_row = 0;
  unsigned span = 0;
  unsigned addr_space = kAddrSpaceLocal;
  unsigned addr_context = 0;
};

struct RunOptions {
  bool random_backpressure = false;
  int memory_fault_group = -1;
  int vrf_error_group = -1;
  bool store_rsp_first = false;
  bool store_same_cycle = false;
  unsigned completion_stall = 0;
  unsigned memory_fault_cause = kFaultBus;
  int store_rsp_error_group = -1;
  unsigned store_rsp_error_mask = 0;
};

struct WriteRecord {
  unsigned group;
  unsigned mask;
  uint32_t data;
};

struct MemoryRecord {
  unsigned op;
  uint32_t eaddr;
  unsigned addr_space;
  unsigned addr_context;
  uint32_t data;
  unsigned strobe;
};

struct RunResult {
  unsigned status = 0;
  unsigned requested = 0;
  unsigned completed = 0;
  unsigned failed = 0;
  unsigned bytes = 0;
  unsigned partial = 0;
  unsigned fault_cause = kFaultNone;
  uint32_t fault_eaddr = 0;
  std::vector<WriteRecord> vrf_writes;
  std::vector<unsigned> vrf_reads;
  std::vector<MemoryRecord> memory_requests;
};

std::vector<unsigned> selected_groups(unsigned mask) {
  std::vector<unsigned> groups;
  for (unsigned group = 0; group < kGroups; ++group) {
    if ((mask >> group) & 1u) groups.push_back(group);
  }
  return groups;
}

void drive_command(Vvsp_vector_memory_engine& dut, const Command& command) {
  dut.cmd_valid_i = 1;
  dut.cmd_op_i = command.store ? kOpStore : kOpLoad;
  dut.cmd_exec_context_i = command.exec_context;
  dut.cmd_tag_i = command.tag;
  dut.cmd_addr_space_i = command.addr_space;
  dut.cmd_addr_context_i = command.addr_context;
  dut.cmd_base_eaddr_i = command.base_eaddr;
  dut.cmd_eaddr_offset_i = static_cast<uint16_t>(command.eaddr_offset);
  dut.cmd_group_mask_i = command.group_mask;
  dut.cmd_vrf_row_i = command.vrf_row;
  dut.cmd_span_bytes_i = command.span;
}

RunResult run_command(Vvsp_vector_memory_engine& dut, const Command& command,
                      const RunOptions& options, uint32_t& rng) {
  RunResult result;
  const std::vector<unsigned> groups = selected_groups(command.group_mask);
  unsigned memory_index = 0;
  bool command_pending = true;
  bool mem_response_pending = false;
  unsigned mem_response_fault_cause = kFaultNone;
  uint32_t mem_response_data = 0;
  bool write_completion_pending = false;
  bool read_completion_pending = false;
  bool read_response_pending = false;
  unsigned child_context = 0;
  unsigned child_tag = 0;
  unsigned child_group = 0;
  unsigned child_mask = 0;
  uint32_t child_data = 0;
  unsigned completion_stall_left = options.completion_stall;
  bool held_completion = false;
  std::array<uint32_t, 11> held_fields{};
  bool held_mem_request = false;
  std::array<uint32_t, 6> held_mem_request_fields{};
  bool held_vrf_write = false;
  std::array<uint32_t, 6> held_vrf_write_fields{};
  bool held_vrf_read = false;
  std::array<uint32_t, 5> held_vrf_read_fields{};

  for (unsigned cycle = 0; cycle < 20000; ++cycle) {
    clear_inputs(dut);
    if (command_pending) drive_command(dut, command);

    auto ready_value = [&](unsigned salt) {
      if (!options.random_backpressure) return true;
      return ((next_random(rng) >> salt) & 3u) != 0;
    };
    dut.dmem_req_ready_i = ready_value(0);
    dut.vrf_write_ready_i = ready_value(2);
    dut.vrf_read_ready_i = ready_value(4);

    if (mem_response_pending && ready_value(6)) {
      dut.dmem_rsp_valid_i = 1;
      dut.dmem_rsp_rdata_i = mem_response_data;
      dut.dmem_rsp_fault_cause_i = mem_response_fault_cause;
    }
    if (write_completion_pending && ready_value(8)) {
      dut.vrf_write_cpl_valid_i = 1;
      dut.vrf_write_cpl_exec_context_i = child_context;
      dut.vrf_write_cpl_tag_i = child_tag;
      dut.vrf_write_cpl_group_i = child_group;
      dut.vrf_write_cpl_error_i =
          options.vrf_error_group == static_cast<int>(child_group);
    }

    bool allow_store_cpl = true;
    bool allow_store_rsp = true;
    if (options.store_rsp_first && read_completion_pending &&
        read_response_pending) {
      allow_store_cpl = false;
    }
    if (!options.store_same_cycle && !options.store_rsp_first &&
        read_completion_pending && read_response_pending) {
      allow_store_rsp = false;
    }
    if (read_completion_pending && allow_store_cpl && ready_value(10)) {
      dut.vrf_read_cpl_valid_i = 1;
      dut.vrf_read_cpl_exec_context_i = child_context;
      dut.vrf_read_cpl_tag_i = child_tag;
      dut.vrf_read_cpl_group_i = child_group;
      dut.vrf_read_cpl_error_i =
          options.vrf_error_group == static_cast<int>(child_group);
    }
    if (read_response_pending && allow_store_rsp && ready_value(12)) {
      const bool response_error =
          options.store_rsp_error_group == static_cast<int>(child_group);
      dut.vrf_read_rsp_valid_i = 1;
      dut.vrf_read_rsp_exec_context_i = child_context;
      dut.vrf_read_rsp_tag_i = child_tag;
      dut.vrf_read_rsp_group_i = child_group;
      dut.vrf_read_rsp_data_i = child_data;
      dut.vrf_read_rsp_mask_i = response_error
                                     ? options.store_rsp_error_mask
                                     : child_mask;
      dut.vrf_read_rsp_error_i = response_error;
    }

    if (dut.cpl_valid_o) {
      if (completion_stall_left != 0) {
        --completion_stall_left;
        dut.cpl_ready_i = 0;
      } else {
        dut.cpl_ready_i = ready_value(14);
      }
    }
    dut.eval();

    if (held_mem_request) {
      expect_eq("stalled memory request remains valid", 1,
                dut.dmem_req_valid_o);
      expect_eq("stalled memory request operation", held_mem_request_fields[0],
                dut.dmem_req_op_o);
      expect_eq("stalled memory request eaddr", held_mem_request_fields[1],
                dut.dmem_req_eaddr_o);
      expect_eq("stalled memory request address space",
                held_mem_request_fields[2], dut.dmem_req_addr_space_o);
      expect_eq("stalled memory request address context",
                held_mem_request_fields[3], dut.dmem_req_addr_context_o);
      expect_eq("stalled memory request data", held_mem_request_fields[4],
                dut.dmem_req_wdata_o);
      expect_eq("stalled memory request strobe", held_mem_request_fields[5],
                dut.dmem_req_wstrb_o);
    }
    if (held_vrf_write) {
      expect_eq("stalled VRF write remains valid", 1,
                dut.vrf_write_valid_o);
      expect_eq("stalled VRF write context", held_vrf_write_fields[0],
                dut.vrf_write_exec_context_o);
      expect_eq("stalled VRF write tag", held_vrf_write_fields[1],
                dut.vrf_write_tag_o);
      expect_eq("stalled VRF write group", held_vrf_write_fields[2],
                dut.vrf_write_group_o);
      expect_eq("stalled VRF write address", held_vrf_write_fields[3],
                dut.vrf_write_row_o);
      expect_eq("stalled VRF write mask", held_vrf_write_fields[4],
                dut.vrf_write_mask_o);
      expect_eq("stalled VRF write data", held_vrf_write_fields[5],
                dut.vrf_write_data_o);
    }
    if (held_vrf_read) {
      expect_eq("stalled VRF read remains valid", 1, dut.vrf_read_valid_o);
      expect_eq("stalled VRF read context", held_vrf_read_fields[0],
                dut.vrf_read_exec_context_o);
      expect_eq("stalled VRF read tag", held_vrf_read_fields[1],
                dut.vrf_read_tag_o);
      expect_eq("stalled VRF read group", held_vrf_read_fields[2],
                dut.vrf_read_group_o);
      expect_eq("stalled VRF read address", held_vrf_read_fields[3],
                dut.vrf_read_row_o);
      expect_eq("stalled VRF read mask", held_vrf_read_fields[4],
                dut.vrf_read_mask_o);
    }

    if (held_completion) {
      expect_eq("stalled completion remains valid", 1, dut.cpl_valid_o);
      expect_eq("stalled completion operation", held_fields[0], dut.cpl_op_o);
      expect_eq("stalled completion context", held_fields[1],
                dut.cpl_exec_context_o);
      expect_eq("stalled completion tag", held_fields[2], dut.cpl_tag_o);
      expect_eq("stalled completion status", held_fields[3], dut.cpl_status_o);
      expect_eq("stalled completion fault cause", held_fields[4],
                dut.cpl_fault_cause_o);
      expect_eq("stalled completion fault eaddr", held_fields[5],
                dut.cpl_fault_eaddr_o);
      expect_eq("stalled completion completed", held_fields[6],
                dut.cpl_completed_group_mask_o);
      expect_eq("stalled completion failed", held_fields[7],
                dut.cpl_failed_group_mask_o);
      expect_eq("stalled completion bytes", held_fields[8],
                dut.cpl_bytes_committed_o);
      expect_eq("stalled completion requested", held_fields[9],
                dut.cpl_requested_group_mask_o);
      expect_eq("stalled completion partial", held_fields[10],
                dut.cpl_partial_o);
    }

    const bool cmd_fire = dut.cmd_valid_i && dut.cmd_ready_o;
    const bool mem_req_fire = dut.dmem_req_valid_o && dut.dmem_req_ready_i;
    const bool mem_rsp_fire = dut.dmem_rsp_valid_i && dut.dmem_rsp_ready_o;
    const bool write_fire = dut.vrf_write_valid_o && dut.vrf_write_ready_i;
    const bool write_cpl_fire = dut.vrf_write_cpl_valid_i &&
                                dut.vrf_write_cpl_ready_o;
    const bool read_fire = dut.vrf_read_valid_o && dut.vrf_read_ready_i;
    const bool read_cpl_fire = dut.vrf_read_cpl_valid_i &&
                               dut.vrf_read_cpl_ready_o;
    const bool read_rsp_fire = dut.vrf_read_rsp_valid_i &&
                               dut.vrf_read_rsp_ready_o;
    const bool completion_fire = dut.cpl_valid_o && dut.cpl_ready_i;

    if (cmd_fire) command_pending = false;
    if (mem_req_fire) {
      const unsigned group = groups.empty() ? 0 : groups[memory_index];
      result.memory_requests.push_back(
          {unsigned(dut.dmem_req_op_o), uint32_t(dut.dmem_req_eaddr_o),
           unsigned(dut.dmem_req_addr_space_o),
           unsigned(dut.dmem_req_addr_context_o),
           uint32_t(dut.dmem_req_wdata_o),
           unsigned(dut.dmem_req_wstrb_o)});
      mem_response_pending = true;
      mem_response_fault_cause =
          options.memory_fault_group == static_cast<int>(group)
              ? options.memory_fault_cause : kFaultNone;
      mem_response_data = memory_word(dut.dmem_req_eaddr_o);
      ++memory_index;
    }
    if (mem_rsp_fire) mem_response_pending = false;
    if (write_fire) {
      result.vrf_writes.push_back(
          {unsigned(dut.vrf_write_group_o),
           unsigned(dut.vrf_write_mask_o),
           uint32_t(dut.vrf_write_data_o)});
      write_completion_pending = true;
      child_context = dut.vrf_write_exec_context_o;
      child_tag = dut.vrf_write_tag_o;
      child_group = dut.vrf_write_group_o;
    }
    if (write_cpl_fire) write_completion_pending = false;
    if (read_fire) {
      result.vrf_reads.push_back(dut.vrf_read_group_o);
      read_completion_pending = true;
      read_response_pending = true;
      child_context = dut.vrf_read_exec_context_o;
      child_tag = dut.vrf_read_tag_o;
      child_group = dut.vrf_read_group_o;
      child_mask = dut.vrf_read_mask_o;
      child_data = vrf_word(child_context, child_tag, child_group);
    }
    if (read_cpl_fire) read_completion_pending = false;
    if (read_rsp_fire) read_response_pending = false;

    held_mem_request = dut.dmem_req_valid_o && !dut.dmem_req_ready_i;
    if (held_mem_request) {
      held_mem_request_fields = {
          unsigned(dut.dmem_req_op_o), uint32_t(dut.dmem_req_eaddr_o),
          unsigned(dut.dmem_req_addr_space_o),
          unsigned(dut.dmem_req_addr_context_o),
          uint32_t(dut.dmem_req_wdata_o),
          unsigned(dut.dmem_req_wstrb_o)};
    }
    held_vrf_write = dut.vrf_write_valid_o && !dut.vrf_write_ready_i;
    if (held_vrf_write) {
      held_vrf_write_fields = {
          unsigned(dut.vrf_write_exec_context_o),
          unsigned(dut.vrf_write_tag_o), unsigned(dut.vrf_write_group_o),
          unsigned(dut.vrf_write_row_o),
          unsigned(dut.vrf_write_mask_o), uint32_t(dut.vrf_write_data_o)};
    }
    held_vrf_read = dut.vrf_read_valid_o && !dut.vrf_read_ready_i;
    if (held_vrf_read) {
      held_vrf_read_fields = {
          unsigned(dut.vrf_read_exec_context_o),
          unsigned(dut.vrf_read_tag_o), unsigned(dut.vrf_read_group_o),
          unsigned(dut.vrf_read_row_o),
          unsigned(dut.vrf_read_mask_o)};
    }

    held_completion = dut.cpl_valid_o && !dut.cpl_ready_i;
    if (held_completion) {
      held_fields = {unsigned(dut.cpl_op_o),
                     unsigned(dut.cpl_exec_context_o),
                     unsigned(dut.cpl_tag_o), unsigned(dut.cpl_status_o),
                     unsigned(dut.cpl_fault_cause_o),
                     uint32_t(dut.cpl_fault_eaddr_o),
                     unsigned(dut.cpl_completed_group_mask_o),
                     unsigned(dut.cpl_failed_group_mask_o),
                     unsigned(dut.cpl_bytes_committed_o),
                     unsigned(dut.cpl_requested_group_mask_o),
                     unsigned(dut.cpl_partial_o)};
    }

    if (completion_fire) {
      result.status = dut.cpl_status_o;
      result.requested = dut.cpl_requested_group_mask_o;
      result.completed = dut.cpl_completed_group_mask_o;
      result.failed = dut.cpl_failed_group_mask_o;
      result.bytes = dut.cpl_bytes_committed_o;
      result.partial = dut.cpl_partial_o;
      result.fault_cause = dut.cpl_fault_cause_o;
      result.fault_eaddr = dut.cpl_fault_eaddr_o;
      expect_eq("completion operation", command.store ? kOpStore : kOpLoad,
                dut.cpl_op_o);
      expect_eq("completion context", command.exec_context,
                dut.cpl_exec_context_o);
      expect_eq("completion tag", command.tag, dut.cpl_tag_o);
      tick(dut);
      clear_inputs(dut);
      dut.eval();
      expect_eq("controller idle after completion", 0, dut.busy_o);
      return result;
    }
    tick(dut);
  }
  fail("command timed out", 1, 0);
}

void expect_success(const Command& command, const RunResult& result) {
  expect_eq("success status", kStatusOk, result.status);
  expect_eq("success requested mask", command.group_mask, result.requested);
  expect_eq("success completed mask", command.group_mask, result.completed);
  expect_eq("success failed mask", 0, result.failed);
  expect_eq("success bytes", command.span, result.bytes);
  expect_eq("success is not partial", 0, result.partial);
  expect_eq("success has no memory fault", kFaultNone, result.fault_cause);
  expect_eq("success has no fault eaddr", 0, result.fault_eaddr);
}

void check_mapping(const Command& command, const RunResult& result) {
  const std::vector<unsigned> groups = selected_groups(command.group_mask);
  expect_eq("one memory request per selected group", groups.size(),
            result.memory_requests.size());
  if (command.store) {
    expect_eq("one VRF read per selected group", groups.size(),
              result.vrf_reads.size());
  } else {
    expect_eq("one VRF write per selected group", groups.size(),
              result.vrf_writes.size());
  }
  const uint32_t effective = command.base_eaddr + command.eaddr_offset;
  const unsigned final_bytes = command.span % kRowBytes == 0
                                   ? kRowBytes
                                   : command.span % kRowBytes;
  for (unsigned index = 0; index < groups.size(); ++index) {
    const unsigned group = groups[index];
    const unsigned mask = index + 1 == groups.size() ? low_mask(final_bytes)
                                                     : 0xfu;
    const MemoryRecord& memory = result.memory_requests[index];
    expect_eq("packed memory eaddr", effective + index * kRowBytes,
              memory.eaddr);
    expect_eq("memory request operation",
              command.store ? kOpStore : kOpLoad, memory.op);
    expect_eq("memory request address space", command.addr_space,
              memory.addr_space);
    expect_eq("memory request address context", command.addr_context,
              memory.addr_context);
    if (command.store) {
      expect_eq("store group order", group, result.vrf_reads[index]);
      expect_eq("store byte strobe", mask, memory.strobe);
      expect_eq("store packed data",
                vrf_word(command.exec_context, command.tag, group),
                memory.data);
    } else {
      const WriteRecord& write = result.vrf_writes[index];
      expect_eq("load group order", group, write.group);
      expect_eq("load tail mask", mask, write.mask);
      expect_eq("load memory data", memory_word(memory.eaddr), write.data);
    }
  }
}

void check_single_flight_ordering(Vvsp_vector_memory_engine& dut) {
  const Command first{false, 0, 0x60, 0x6800, 0, 0x1, 2, 4,
                      kAddrSpaceTranslated, 0x11};
  const Command second{false, 1, 0x61, 0x6c00, 0, 0x2, 3, 4,
                       kAddrSpacePhysical, 0x22};

  clear_inputs(dut);
  drive_command(dut, first);
  dut.eval();
  expect_eq("first command admitted", 1, dut.cmd_ready_o);
  tick(dut);

  // A second producer may hold a command while the first request is stalled,
  // but it cannot replace the active parent's request metadata.
  for (unsigned cycle = 0; cycle < 3; ++cycle) {
    clear_inputs(dut);
    drive_command(dut, second);
    dut.dmem_req_ready_i = 0;
    dut.eval();
    expect_eq("second command blocked during request stall", 0,
              dut.cmd_ready_o);
    expect_eq("first request remains presented", 1, dut.dmem_req_valid_o);
    expect_eq("first request eaddr retained", first.base_eaddr,
              dut.dmem_req_eaddr_o);
    expect_eq("first request address space retained", first.addr_space,
              dut.dmem_req_addr_space_o);
    expect_eq("first request address context retained", first.addr_context,
              dut.dmem_req_addr_context_o);
    tick(dut);
  }

  clear_inputs(dut);
  drive_command(dut, second);
  dut.dmem_req_ready_i = 1;
  dut.eval();
  expect_eq("second command blocked when first request fires", 0,
            dut.cmd_ready_o);
  expect_eq("first request fires once", 1, dut.dmem_req_valid_o);
  tick(dut);

  // No second request can appear while the only outstanding response is
  // absent. The held second command also remains unaccepted.
  for (unsigned cycle = 0; cycle < 2; ++cycle) {
    clear_inputs(dut);
    drive_command(dut, second);
    dut.dmem_req_ready_i = 1;
    dut.eval();
    expect_eq("second command blocked while response outstanding", 0,
              dut.cmd_ready_o);
    expect_eq("no second request before ordered response", 0,
              dut.dmem_req_valid_o);
    tick(dut);
  }

  clear_inputs(dut);
  drive_command(dut, second);
  dut.dmem_rsp_valid_i = 1;
  dut.dmem_rsp_rdata_i = memory_word(first.base_eaddr);
  dut.eval();
  expect_eq("first response accepted", 1, dut.dmem_rsp_ready_o);
  expect_eq("second command blocked during first response", 0,
            dut.cmd_ready_o);
  tick(dut);

  clear_inputs(dut);
  drive_command(dut, second);
  dut.vrf_write_ready_i = 1;
  dut.eval();
  expect_eq("first VRF write presented", 1, dut.vrf_write_valid_o);
  expect_eq("first VRF write context", first.exec_context,
            dut.vrf_write_exec_context_o);
  expect_eq("first VRF write tag", first.tag, dut.vrf_write_tag_o);
  tick(dut);

  clear_inputs(dut);
  drive_command(dut, second);
  dut.vrf_write_cpl_valid_i = 1;
  dut.vrf_write_cpl_exec_context_i = first.exec_context;
  dut.vrf_write_cpl_tag_i = first.tag;
  dut.vrf_write_cpl_group_i = 0;
  dut.eval();
  expect_eq("first VRF completion accepted", 1,
            dut.vrf_write_cpl_ready_o);
  tick(dut);

  // Parent completion retains ownership until its own handshake. The second
  // command becomes admissible only on the following idle cycle.
  for (unsigned cycle = 0; cycle < 3; ++cycle) {
    clear_inputs(dut);
    drive_command(dut, second);
    dut.cpl_ready_i = 0;
    dut.eval();
    expect_eq("first parent completion held", 1, dut.cpl_valid_o);
    expect_eq("first parent completion tag held", first.tag, dut.cpl_tag_o);
    expect_eq("second command blocked by completion", 0, dut.cmd_ready_o);
    expect_eq("no second request during completion", 0,
              dut.dmem_req_valid_o);
    tick(dut);
  }

  clear_inputs(dut);
  drive_command(dut, second);
  dut.cpl_ready_i = 1;
  dut.eval();
  expect_eq("first parent completion retires", 1, dut.cpl_valid_o);
  expect_eq("second command not co-accepted with retirement", 0,
            dut.cmd_ready_o);
  tick(dut);
  dut.eval();
  expect_eq("second command admissible after retirement", 1,
            dut.cmd_ready_o);

  // Remove the offered second command before the next edge; the main test can
  // later submit it normally without a hidden acceptance here.
  clear_inputs(dut);
  dut.eval();
  expect_eq("engine idle after ordering check", 0, dut.busy_o);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_vector_memory_engine dut;
  clear_inputs(dut);
  uint32_t rng = 0x6d219af3u;

  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("idle after reset", 0, dut.busy_o);
  expect_eq("command ready after reset", 1, dut.cmd_ready_o);
  expect_eq("protocol clean after reset", 0, dut.protocol_error_o);

  // One merged LOAD span maps sparse groups in ascending group order.  Positive
  // base displacement and a two-byte tail are both observable.
  Command sparse_load{false, 0, 0x10, 0x1000, 0x20, 0xa, 3, 6,
                      kAddrSpaceTranslated, 0x2a};
  RunResult result = run_command(
      dut, sparse_load, {true, -1, -1, false, false, 5}, rng);
  expect_success(sparse_load, result);
  check_mapping(sparse_load, result);

  // A negative signed displacement is sign-extended before alignment/range
  // checks.  This is a distinct parent tag, not merged with the prior command.
  Command negative_load{false, 1, 0x11, 0x2040, -0x20, 0x5, 4, 8,
                        kAddrSpacePhysical, 0x03};
  result = run_command(dut, negative_load, {true}, rng);
  expect_success(negative_load, result);
  check_mapping(negative_load, result);

  // STORE completion and response may arrive response-first, completion-first,
  // or together.  Exercise all three orders with sparse and tail spans.
  const std::array<RunOptions, 3> store_orders{{
      {true, -1, -1, true, false, 0},
      {true, -1, -1, false, false, 0},
      {true, -1, -1, false, true, 3}}};
  for (unsigned order = 0; order < store_orders.size(); ++order) {
    Command store{true, order & 1u, 0x20 + order,
                  0x3000u + order * 0x100u, 0,
                  order == 1 ? 0x9u : 0x6u, 7, 6};
    result = run_command(dut, store, store_orders[order], rng);
    expect_success(store, result);
    check_mapping(store, result);
  }

  // Static descriptor/address rejects commit no memory or VRF side effects.
  const std::array<std::pair<Command, unsigned>, 5> rejects{{
      {{false, 0, 0x30, 0x1000, 0, 0x0, 0, 4}, kStatusBadRequest},
      {{false, 0, 0x31, 0x1000, 0, 0x3, 0, 4}, kStatusBadRequest},
      {{false, 0, 0x32, 0x1000, 2, 0x1, 0, 4}, kStatusBadEaddr},
      {{true, 1, 0x33, 0x4, -8, 0x1, 0, 4}, kStatusBadEaddr},
      {{false, 0, 0x34, 0x1000, 0, 0x1, 0, 4, 3, 0},
       kStatusBadRequest}}};
  for (const auto& test : rejects) {
    result = run_command(dut, test.first, {true, -1, -1, false, false, 2},
                         rng);
    expect_eq("static reject status", test.second, result.status);
    expect_eq("static reject commits no groups", 0, result.completed);
    expect_eq("static reject commits no bytes", 0, result.bytes);
    expect_eq("static reject has no memory traffic", 0,
              result.memory_requests.size());
    expect_eq("static reject has no VRF writes", 0,
              result.vrf_writes.size());
    expect_eq("static reject has no VRF reads", 0,
              result.vrf_reads.size());
    expect_eq("static reject has no downstream fault", kFaultNone,
              result.fault_cause);
    expect_eq("static reject has no fault eaddr", 0, result.fault_eaddr);
  }

  // Runtime memory and VRF failures report only the already committed prefix.
  Command failing_load{false, 0, 0x40, 0x4000, 0, 0xb, 2, 12,
                       kAddrSpaceTranslated, 0x31};
  result = run_command(
      dut, failing_load,
      {true, 1, -1, false, false, 4, kFaultTranslation}, rng);
  expect_eq("load memory fault status", kStatusMemoryFault, result.status);
  expect_eq("load translation fault cause", kFaultTranslation,
            result.fault_cause);
  expect_eq("load translation fault eaddr", 0x4004, result.fault_eaddr);
  expect_eq("load memory committed prefix", 0x1, result.completed);
  expect_eq("load memory failed group", 0x2, result.failed);
  expect_eq("load memory committed bytes", 4, result.bytes);
  expect_eq("load memory partial", 1, result.partial);

  result = run_command(dut, failing_load, {true, -1, 1}, rng);
  expect_eq("load VRF error status", kStatusVrfError, result.status);
  expect_eq("load VRF error has no memory cause", kFaultNone,
            result.fault_cause);
  expect_eq("load VRF committed prefix", 0x1, result.completed);
  expect_eq("load VRF failed group", 0x2, result.failed);
  expect_eq("load VRF committed bytes", 4, result.bytes);

  Command failing_store{true, 1, 0x41, 0x5000, 0, 0xe, 5, 12,
                        kAddrSpaceTranslated, 0x32};
  result = run_command(
      dut, failing_store,
      {true, 2, -1, false, false, 3, kFaultPermission}, rng);
  expect_eq("store memory fault status", kStatusMemoryFault, result.status);
  expect_eq("store permission fault cause", kFaultPermission,
            result.fault_cause);
  expect_eq("store permission fault eaddr", 0x5004, result.fault_eaddr);
  expect_eq("store memory committed prefix", 0x2, result.completed);
  expect_eq("store memory failed group", 0x4, result.failed);
  expect_eq("store memory committed bytes", 4, result.bytes);
  result = run_command(dut, failing_store,
                       {true, -1, 2, false, true, 0}, rng);
  expect_eq("store VRF error status", kStatusVrfError, result.status);
  expect_eq("store VRF error has no memory cause", kFaultNone,
            result.fault_cause);
  expect_eq("store VRF committed prefix", 0x2, result.completed);
  expect_eq("store VRF failed group", 0x4, result.failed);

  // An error response still carries matching parent identity, but its data and
  // mask are not meaningful. A zero mask must terminate the parent as a normal
  // VRF runtime error without also setting the protocol-error sticky bit.
  expect_eq("protocol clean before STORE response error", 0,
            dut.protocol_error_o);
  RunOptions response_error;
  response_error.random_backpressure = true;
  response_error.store_rsp_first = true;
  response_error.store_rsp_error_group = 2;
  response_error.store_rsp_error_mask = 0;
  result = run_command(dut, failing_store, response_error, rng);
  expect_eq("STORE response error status", kStatusVrfError, result.status);
  expect_eq("STORE response error has no memory cause", kFaultNone,
            result.fault_cause);
  expect_eq("STORE response error committed prefix", 0x2,
            result.completed);
  expect_eq("STORE response error failed group", 0x4, result.failed);
  expect_eq("STORE response error committed bytes", 4, result.bytes);
  expect_eq("STORE response error issues no failing-group memory request", 1,
            result.memory_requests.size());
  expect_eq("STORE response error leaves protocol sticky clear", 0,
            dut.protocol_error_o);

  // Every defined downstream fault class propagates without changing the
  // single-outstanding accounting contract. The engine derives fault_eaddr
  // from its one active request rather than requiring a response transaction ID.
  const std::array<unsigned, 5> fault_causes{{
      kFaultTranslation, kFaultPermission, kFaultAccess, kFaultBus,
      kFaultDataIntegrity}};
  for (unsigned index = 0; index < fault_causes.size(); ++index) {
    Command faulting{false, index & 1u, 0x48u + index,
                     0x5800u + index * 0x40u, 0, 0x1, index, 4,
                     kAddrSpaceTranslated, 0x40u + index};
    result = run_command(
        dut, faulting,
        {true, 0, -1, false, false, 2, fault_causes[index]}, rng);
    expect_eq("fault matrix parent status", kStatusMemoryFault,
              result.status);
    expect_eq("fault matrix cause", fault_causes[index],
              result.fault_cause);
    expect_eq("fault matrix effective address", faulting.base_eaddr,
              result.fault_eaddr);
    expect_eq("fault matrix commits no group", 0, result.completed);
    expect_eq("fault matrix marks first group", 1, result.failed);
    expect_eq("fault matrix commits no bytes", 0, result.bytes);
    expect_eq("fault matrix is not partial", 0, result.partial);
  }

  // A mismatched child completion is consumed, terminates the parent with a
  // VRF error, and sets the protocol sticky bit.  Clear and reset are explicit.
  Command mismatch{false, 0, 0x50, 0x6000, 0, 0x1, 0, 4};
  drive_command(dut, mismatch);
  dut.eval();
  expect_eq("mismatch command accepted", 1, dut.cmd_ready_o);
  tick(dut);
  clear_inputs(dut);
  while (!dut.dmem_req_valid_o) {
    dut.dmem_req_ready_i = 1;
    tick(dut);
  }
  dut.dmem_req_ready_i = 1;
  tick(dut);
  clear_inputs(dut);
  dut.dmem_rsp_valid_i = 1;
  dut.dmem_rsp_rdata_i = memory_word(0x6000);
  tick(dut);
  clear_inputs(dut);
  dut.vrf_write_ready_i = 1;
  while (!dut.vrf_write_valid_o) tick(dut);
  tick(dut);
  clear_inputs(dut);
  dut.vrf_write_cpl_valid_i = 1;
  dut.vrf_write_cpl_exec_context_i = 0;
  dut.vrf_write_cpl_tag_i = 0x51;
  dut.vrf_write_cpl_group_i = 0;
  while (!dut.vrf_write_cpl_ready_o) tick(dut);
  tick(dut);
  clear_inputs(dut);
  dut.eval();
  expect_eq("mismatch sets sticky protocol error", 1, dut.protocol_error_o);
  expect_eq("mismatch produces completion", 1, dut.cpl_valid_o);
  expect_eq("mismatch is VRF error", kStatusVrfError, dut.cpl_status_o);
  dut.cpl_ready_i = 1;
  tick(dut);
  clear_inputs(dut);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  clear_inputs(dut);
  expect_eq("protocol clear", 0, dut.protocol_error_o);

  check_single_flight_ordering(dut);

  // Random legal spans add sustained backpressure coverage across both paths.
  for (unsigned test = 0; test < 250; ++test) {
    const unsigned group_count = 1 + (next_random(rng) % kGroups);
    unsigned mask = 0;
    while (popcount(mask) < group_count) {
      mask |= 1u << (next_random(rng) % kGroups);
    }
    const unsigned min_span = (group_count - 1) * kRowBytes + 1;
    const unsigned span = min_span +
        (next_random(rng) % (group_count * kRowBytes - min_span + 1));
    Command random_command{
        bool(next_random(rng) & 1u), next_random(rng) & 1u,
        (0x80u + test) & 0xffu, 0x8000u + test * 0x40u,
        (next_random(rng) & 1u) ? 0 : 4,
        mask, next_random(rng) & 0xfu, span};
    random_command.addr_space = next_random(rng) % 3;
    random_command.addr_context = next_random(rng) & 0xffu;
    result = run_command(dut, random_command,
                         {true, -1, -1,
                          bool(next_random(rng) & 1u),
                          bool(next_random(rng) & 1u),
                          next_random(rng) & 3u}, rng);
    expect_success(random_command, result);
    check_mapping(random_command, result);
  }

  // Reset clears a live transaction and sticky state without a ghost
  // completion, and restores command admission.
  Command live{false, 1, 0x70, 0x7000, 0, 0xf, 0, 16};
  drive_command(dut, live);
  tick(dut);
  clear_inputs(dut);
  expect_eq("live command makes controller busy", 1, dut.busy_o);
  dut.rst_ni = 0;
  dut.eval();
  expect_eq("reset clears busy", 0, dut.busy_o);
  expect_eq("reset clears completion", 0, dut.cpl_valid_o);
  expect_eq("reset clears protocol error", 0, dut.protocol_error_o);
  tick(dut);
  clear_inputs(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("post-reset command ready", 1, dut.cmd_ready_o);

  dut.final();
  std::cout << "PASS: " << checks
            << " vector memory engine checks across address-space metadata, "
               "ordered single-flight access, structured faults, sparse spans, "
               "backpressure, and reset\n";
  return 0;
}
