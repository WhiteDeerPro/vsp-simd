#include "Vvsp_vector_memory_engine.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

constexpr unsigned kGroups = 16;
constexpr unsigned kRowBytes = 4;
constexpr uint16_t kFullMask = 0xffff;
constexpr unsigned kLoad = 0;
constexpr unsigned kStore = 1;
constexpr unsigned kUnitStride = 0;
constexpr unsigned kIndexU8 = 1;
constexpr unsigned kTranslated = 2;
constexpr unsigned kFaultNone = 0;
constexpr unsigned kFaultPermission = 2;
constexpr unsigned kStatusOk = 0;
constexpr unsigned kStatusMemoryFault = 3;

uint64_t checks = 0;

[[noreturn]] void fail(const char* what, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << what << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const char* what, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(what, expected, actual);
}

uint32_t pack_bytes(const std::array<uint8_t, kRowBytes>& bytes) {
  uint32_t word = 0;
  for (unsigned lane = 0; lane < kRowBytes; ++lane)
    word |= uint32_t{bytes[lane]} << (8 * lane);
  return word;
}

unsigned byte_at(uint32_t word, unsigned lane) {
  return (word >> (8 * lane)) & 0xffu;
}

uint32_t memory_word(uint32_t address) {
  return 0x6d5a3c17u ^ (address * 0x01020409u);
}

void store_word(std::array<uint8_t, 2048>& bytes, uint32_t address,
                uint32_t data, unsigned strobe) {
  for (unsigned lane = 0; lane < kRowBytes; ++lane) {
    if ((strobe >> lane) & 1u)
      bytes.at(address + lane) = uint8_t(data >> (8 * lane));
  }
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
  dut.cmd_op_i = kLoad;
  dut.cmd_addr_mode_i = kIndexU8;
  dut.cmd_exec_context_i = 0;
  dut.cmd_tag_i = 0;
  dut.cmd_addr_space_i = kTranslated;
  dut.cmd_addr_context_i = 0;
  dut.cmd_base_eaddr_i = 0;
  dut.cmd_eaddr_offset_i = 0;
  dut.cmd_group_mask_i = 0;
  dut.cmd_vrf_row_i = 0;
  dut.cmd_index_vrf_row_i = 0;
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
  uint8_t tag = 0;
  uint32_t base = 0;
  uint8_t data_row = 9;
  uint8_t index_row = 6;
  bool indexed = true;
  uint8_t span = 0;
};

struct RowModel {
  std::array<uint32_t, kGroups> index{};
  std::array<uint32_t, kGroups> data{};
};

struct MemoryRequest {
  unsigned op;
  uint32_t eaddr;
  uint32_t data;
  unsigned strobe;
};

struct VrfRead {
  unsigned group;
  unsigned row;
};

struct VrfWrite {
  unsigned group;
  unsigned row;
  unsigned mask;
  uint32_t data;
};

struct Result {
  unsigned status = 0;
  unsigned fault_cause = 0;
  uint32_t fault_eaddr = 0;
  unsigned requested = 0;
  unsigned completed = 0;
  unsigned failed = 0;
  unsigned bytes = 0;
  bool partial = false;
  std::vector<MemoryRequest> requests;
  std::vector<VrfRead> reads;
  std::vector<VrfWrite> writes;
  std::array<uint8_t, 2048> memory{};
};

void drive_command(Vvsp_vector_memory_engine& dut,
                   const Command& command) {
  dut.cmd_valid_i = 1;
  dut.cmd_op_i = command.store ? kStore : kLoad;
  dut.cmd_addr_mode_i = command.indexed ? kIndexU8 : kUnitStride;
  dut.cmd_exec_context_i = 0;
  dut.cmd_tag_i = command.tag;
  dut.cmd_addr_space_i = kTranslated;
  dut.cmd_addr_context_i = 0x5a;
  dut.cmd_base_eaddr_i = command.base;
  dut.cmd_eaddr_offset_i = 0;
  dut.cmd_group_mask_i = kFullMask;
  dut.cmd_vrf_row_i = command.data_row;
  dut.cmd_index_vrf_row_i = command.index_row;
  dut.cmd_span_bytes_i = command.span;
}

Result run_command(Vvsp_vector_memory_engine& dut, const Command& command,
                   const RowModel& rows, int fault_request = -1) {
  Result result;
  bool command_pending = true;
  bool memory_response_pending = false;
  uint32_t memory_response_data = 0;
  unsigned memory_response_fault = kFaultNone;
  bool write_completion_pending = false;
  unsigned write_context = 0;
  unsigned write_tag = 0;
  unsigned write_group = 0;
  bool read_completion_pending = false;
  bool read_response_pending = false;
  unsigned read_context = 0;
  unsigned read_tag = 0;
  unsigned read_group = 0;
  uint32_t read_data = 0;
  unsigned request_ordinal = 0;

  for (unsigned cycle = 0; cycle < 5000; ++cycle) {
    clear_inputs(dut);
    if (command_pending) drive_command(dut, command);
    dut.dmem_req_ready_i = 1;
    dut.vrf_write_ready_i = 1;
    dut.vrf_read_ready_i = 1;
    dut.cpl_ready_i = 1;

    if (memory_response_pending) {
      dut.dmem_rsp_valid_i = 1;
      dut.dmem_rsp_rdata_i = memory_response_data;
      dut.dmem_rsp_fault_cause_i = memory_response_fault;
    }
    if (write_completion_pending) {
      dut.vrf_write_cpl_valid_i = 1;
      dut.vrf_write_cpl_exec_context_i = write_context;
      dut.vrf_write_cpl_tag_i = write_tag;
      dut.vrf_write_cpl_group_i = write_group;
    }
    if (read_completion_pending) {
      dut.vrf_read_cpl_valid_i = 1;
      dut.vrf_read_cpl_exec_context_i = read_context;
      dut.vrf_read_cpl_tag_i = read_tag;
      dut.vrf_read_cpl_group_i = read_group;
    }
    if (read_response_pending) {
      dut.vrf_read_rsp_valid_i = 1;
      dut.vrf_read_rsp_exec_context_i = read_context;
      dut.vrf_read_rsp_tag_i = read_tag;
      dut.vrf_read_rsp_group_i = read_group;
      dut.vrf_read_rsp_data_i = read_data;
      dut.vrf_read_rsp_mask_i = 0xf;
    }
    dut.eval();

    const bool command_fire = dut.cmd_valid_i && dut.cmd_ready_o;
    const bool memory_request_fire =
        dut.dmem_req_valid_o && dut.dmem_req_ready_i;
    const bool memory_response_fire =
        dut.dmem_rsp_valid_i && dut.dmem_rsp_ready_o;
    const bool write_fire = dut.vrf_write_valid_o && dut.vrf_write_ready_i;
    const bool write_completion_fire =
        dut.vrf_write_cpl_valid_i && dut.vrf_write_cpl_ready_o;
    const bool read_fire = dut.vrf_read_valid_o && dut.vrf_read_ready_i;
    const bool read_completion_fire =
        dut.vrf_read_cpl_valid_i && dut.vrf_read_cpl_ready_o;
    const bool read_response_fire =
        dut.vrf_read_rsp_valid_i && dut.vrf_read_rsp_ready_o;
    const bool completion_fire = dut.cpl_valid_o && dut.cpl_ready_i;

    if (command_fire) command_pending = false;

    if (memory_response_fire) memory_response_pending = false;
    if (memory_request_fire) {
      const bool request_faults =
          fault_request == static_cast<int>(request_ordinal);
      expect_eq("memory request address space", kTranslated,
                dut.dmem_req_addr_space_o);
      expect_eq("memory request address context", 0x5a,
                dut.dmem_req_addr_context_o);
      result.requests.push_back(
          {unsigned(dut.dmem_req_op_o), uint32_t(dut.dmem_req_eaddr_o),
           uint32_t(dut.dmem_req_wdata_o),
           unsigned(dut.dmem_req_wstrb_o)});
      memory_response_pending = true;
      memory_response_data = memory_word(dut.dmem_req_eaddr_o);
      memory_response_fault = request_faults ? kFaultPermission : kFaultNone;
      if (command.store && !request_faults) {
        store_word(result.memory, dut.dmem_req_eaddr_o,
                   dut.dmem_req_wdata_o, dut.dmem_req_wstrb_o);
      }
      ++request_ordinal;
    }

    if (write_completion_fire) write_completion_pending = false;
    if (write_fire) {
      expect_eq("VRF write context", 0, dut.vrf_write_exec_context_o);
      expect_eq("VRF write tag", command.tag, dut.vrf_write_tag_o);
      result.writes.push_back(
          {unsigned(dut.vrf_write_group_o), unsigned(dut.vrf_write_row_o),
           unsigned(dut.vrf_write_mask_o),
           uint32_t(dut.vrf_write_data_o)});
      write_completion_pending = true;
      write_context = dut.vrf_write_exec_context_o;
      write_tag = dut.vrf_write_tag_o;
      write_group = dut.vrf_write_group_o;
    }

    if (read_completion_fire) read_completion_pending = false;
    if (read_response_fire) read_response_pending = false;
    if (read_fire) {
      expect_eq("VRF read context", 0, dut.vrf_read_exec_context_o);
      expect_eq("VRF read tag", command.tag, dut.vrf_read_tag_o);
      const unsigned group = dut.vrf_read_group_o;
      const unsigned row = dut.vrf_read_row_o;
      result.reads.push_back({group, row});
      read_completion_pending = true;
      read_response_pending = true;
      read_context = dut.vrf_read_exec_context_o;
      read_tag = dut.vrf_read_tag_o;
      read_group = group;
      read_data = row == command.index_row ? rows.index.at(group)
                                           : rows.data.at(group);
    }

    if (completion_fire) {
      expect_eq("completion operation", command.store ? kStore : kLoad,
                dut.cpl_op_o);
      expect_eq("completion context", 0, dut.cpl_exec_context_o);
      expect_eq("completion tag", command.tag, dut.cpl_tag_o);
      result.status = dut.cpl_status_o;
      result.fault_cause = dut.cpl_fault_cause_o;
      result.fault_eaddr = dut.cpl_fault_eaddr_o;
      result.requested = dut.cpl_requested_group_mask_o;
      result.completed = dut.cpl_completed_group_mask_o;
      result.failed = dut.cpl_failed_group_mask_o;
      result.bytes = dut.cpl_bytes_committed_o;
      result.partial = dut.cpl_partial_o;
    }

    tick(dut);
    if (completion_fire) {
      clear_inputs(dut);
      dut.eval();
      expect_eq("engine idle after completion", 0, dut.busy_o);
      return result;
    }
  }

  fail("command completion timeout", 1, 0);
}

void expect_success(const Result& result) {
  expect_eq("success status", kStatusOk, result.status);
  expect_eq("success requested mask", kFullMask, result.requested);
  expect_eq("success completed mask", kFullMask, result.completed);
  expect_eq("success failed mask", 0, result.failed);
  expect_eq("success committed bytes", 64, result.bytes);
  expect_eq("success partial flag", 0, result.partial);
  expect_eq("success fault cause", kFaultNone, result.fault_cause);
  expect_eq("success fault address", 0, result.fault_eaddr);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_vector_memory_engine dut;
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("idle after reset", 0, dut.busy_o);
  expect_eq("ready after reset", 1, dut.cmd_ready_o);

  // Exercise the seven-bit physical span at the architectural group bound.
  // The uword adapter resolves UNIT_STRIDE code zero to this ordinary 64-byte
  // engine command; the focused program-wrapper test separately covers that
  // code-zero resolution for sparse masks.
  RowModel unused_rows;
  Command linear_load{false, 0x2f, 0x080, 8, 0};
  linear_load.indexed = false;
  linear_load.span = 64;
  const Result linear = run_command(dut, linear_load, unused_rows);
  expect_success(linear);
  expect_eq("full unit-stride has no VRF reads", 0, linear.reads.size());
  expect_eq("full unit-stride memory request count", 16,
            linear.requests.size());
  expect_eq("full unit-stride destination-write count", 16,
            linear.writes.size());
  for (unsigned group = 0; group < kGroups; ++group) {
    expect_eq("unit-stride request operation", kLoad,
              linear.requests[group].op);
    expect_eq("unit-stride request address", linear_load.base + 4 * group,
              linear.requests[group].eaddr);
    expect_eq("unit-stride destination group", group,
              linear.writes[group].group);
    expect_eq("unit-stride destination mask", 0xf,
              linear.writes[group].mask);
    expect_eq("unit-stride destination data",
              memory_word(linear_load.base + 4 * group),
              linear.writes[group].data);
  }

  RowModel gather_rows;
  for (unsigned group = 0; group < kGroups; ++group) {
    std::array<uint8_t, kRowBytes> indices{};
    for (unsigned lane = 0; lane < kRowBytes; ++lane)
      indices[lane] = uint8_t(group * kRowBytes + lane);
    gather_rows.index[group] = pack_bytes(indices);
  }

  const Command gather{false, 0x30, 0x101, 9, 6};
  const Result gathered = run_command(dut, gather, gather_rows);
  expect_success(gathered);
  expect_eq("full gather index-read count", 16, gathered.reads.size());
  expect_eq("full gather destination-write count", 16,
            gathered.writes.size());
  expect_eq("full gather memory request count", 64,
            gathered.requests.size());
  for (unsigned group = 0; group < kGroups; ++group) {
    expect_eq("gather index group order", group,
              gathered.reads[group].group);
    expect_eq("gather index row", gather.index_row,
              gathered.reads[group].row);
    expect_eq("gather destination group order", group,
              gathered.writes[group].group);
    expect_eq("gather destination row", gather.data_row,
              gathered.writes[group].row);
    expect_eq("gather destination mask", 0xf,
              gathered.writes[group].mask);

    uint32_t expected_word = 0;
    for (unsigned lane = 0; lane < kRowBytes; ++lane) {
      const unsigned ordinal = group * kRowBytes + lane;
      const uint32_t byte_eaddr = gather.base + ordinal;
      const uint32_t beat_eaddr = byte_eaddr & ~uint32_t{3};
      const unsigned beat_lane = byte_eaddr & 3u;
      const MemoryRequest& request = gathered.requests[ordinal];
      expect_eq("gather request operation", kLoad, request.op);
      expect_eq("gather request group/lane order", beat_eaddr,
                request.eaddr);
      expect_eq("gather request write strobe", 0, request.strobe);
      expected_word |= byte_at(memory_word(beat_eaddr), beat_lane)
                       << (8 * lane);
    }
    expect_eq("gather extracted row", expected_word,
              gathered.writes[group].data);
  }
  expect_eq("gather reaches group 15", 15, gathered.writes.back().group);

  RowModel scatter_rows;
  for (unsigned group = 0; group < kGroups; ++group) {
    std::array<uint8_t, kRowBytes> indices{};
    std::array<uint8_t, kRowBytes> data{};
    for (unsigned lane = 0; lane < kRowBytes; ++lane) {
      const unsigned ordinal = group * kRowBytes + lane;
      indices[lane] = uint8_t(ordinal);
      data[lane] = uint8_t(ordinal + 1);
    }
    scatter_rows.index[group] = pack_bytes(indices);
    scatter_rows.data[group] = pack_bytes(data);
  }
  // First and last lanes deliberately alias. Ascending group/lane issue makes
  // group 15 lane 3 the deterministic final writer.
  scatter_rows.index[0] =
      (scatter_rows.index[0] & 0xffffff00u) | 200u;
  scatter_rows.index[15] =
      (scatter_rows.index[15] & 0x00ffffffu) | (200u << 24);

  const Command scatter{true, 0x31, 0x200, 10, 7};
  const Result scattered = run_command(dut, scatter, scatter_rows);
  expect_success(scattered);
  expect_eq("full scatter VRF-read count", 32, scattered.reads.size());
  expect_eq("full scatter has no VRF writes", 0, scattered.writes.size());
  expect_eq("full scatter memory request count", 64,
            scattered.requests.size());
  for (unsigned group = 0; group < kGroups; ++group) {
    expect_eq("scatter index-read group order", group,
              scattered.reads[2 * group].group);
    expect_eq("scatter index-read row", scatter.index_row,
              scattered.reads[2 * group].row);
    expect_eq("scatter data-read group order", group,
              scattered.reads[2 * group + 1].group);
    expect_eq("scatter data-read row", scatter.data_row,
              scattered.reads[2 * group + 1].row);
    for (unsigned lane = 0; lane < kRowBytes; ++lane) {
      const unsigned ordinal = group * kRowBytes + lane;
      const unsigned offset = byte_at(scatter_rows.index[group], lane);
      const unsigned data_byte = byte_at(scatter_rows.data[group], lane);
      const uint32_t byte_eaddr = scatter.base + offset;
      const uint32_t beat_eaddr = byte_eaddr & ~uint32_t{3};
      const unsigned beat_lane = byte_eaddr & 3u;
      const MemoryRequest& request = scattered.requests[ordinal];
      expect_eq("scatter request operation", kStore, request.op);
      expect_eq("scatter request group/lane order", beat_eaddr,
                request.eaddr);
      expect_eq("scatter request one-hot strobe", 1u << beat_lane,
                request.strobe);
      expect_eq("scatter request byte placement", data_byte << (8 * beat_lane),
                request.data);
    }
  }
  expect_eq("scatter duplicate destination uses last writer", 64,
            scattered.memory.at(scatter.base + 200));
  expect_eq("scatter final request is group 15 lane 3", 64,
            byte_at(scattered.requests.back().data, 0));

  // A late fault demonstrates that the widened masks and seven-bit committed
  // byte counter retain the 60-byte completed prefix at the scaling bound.
  const Command faulting_scatter{true, 0x32, 0x400, 10, 7};
  const Result faulted =
      run_command(dut, faulting_scatter, scatter_rows, 62);
  expect_eq("late fault status", kStatusMemoryFault, faulted.status);
  expect_eq("late fault cause", kFaultPermission, faulted.fault_cause);
  expect_eq("late fault exact byte address", 0x43e,
            faulted.fault_eaddr);
  expect_eq("late fault requested mask", kFullMask, faulted.requested);
  expect_eq("late fault completed group prefix", 0x7fff,
            faulted.completed);
  expect_eq("late fault marks group 15", 0x8000, faulted.failed);
  expect_eq("late fault committed byte prefix", 62, faulted.bytes);
  expect_eq("late fault is partial", 1, faulted.partial);
  expect_eq("late fault stops before lane 63", 63,
            faulted.requests.size());

  expect_eq("protocol remains clean", 0, dut.protocol_error_o);
  dut.final();
  std::cout << "PASS: " << checks
            << " 16-group/64-byte unit-stride and indexed-memory checks\n";
  return 0;
}
