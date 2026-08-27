#include "Vvsp_benes_exchange_engine.h"
#include "verilated.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kRowBytes = 4;
constexpr unsigned kStages = 3;
constexpr unsigned kSwitchesPerStage = 2;
constexpr unsigned kControlBits = 6;

constexpr unsigned kCplOk = 0;
constexpr unsigned kCplBadRoute = 2;
constexpr unsigned kCplReadError = 3;
constexpr unsigned kCplWriteError = 4;
constexpr unsigned kCplProtocolError = 5;

uint64_t checks = 0;
uint64_t read_stalls = 0;
uint64_t write_stalls = 0;
uint64_t completion_stalls = 0;

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

void tick(Vvsp_benes_exchange_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

uint32_t next_random(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

template <typename T>
std::array<T, kGroups> route_reference(unsigned control,
                                       std::array<T, kGroups> wires) {
  for (unsigned stage = 0; stage < kStages; ++stage) {
    std::array<T, kGroups> switched{};
    for (unsigned sw = 0; sw < kSwitchesPerStage; ++sw) {
      const unsigned even = 2 * sw;
      const unsigned odd = even + 1;
      const bool cross =
          (control >> (stage * kSwitchesPerStage + sw)) & 1u;
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
  for (unsigned group = 0; group < kGroups; ++group) {
    packed |= (masks[group] & 0xfu) << (group * kRowBytes);
  }
  return packed;
}

unsigned group_mask(const std::array<unsigned, kGroups>& masks) {
  unsigned result = 0;
  for (unsigned group = 0; group < kGroups; ++group) {
    if (masks[group] != 0) result |= 1u << group;
  }
  return result;
}

unsigned byte_count(const std::array<unsigned, kGroups>& masks) {
  unsigned result = 0;
  for (unsigned mask : masks) result += __builtin_popcount(mask & 0xfu);
  return result;
}

struct Command {
  unsigned context = 0;
  unsigned tag = 0;
  unsigned src_row = 0;
  unsigned dst_row = 0;
  bool route_valid = true;
  unsigned route_control = 0;
  std::array<unsigned, kGroups> source_masks{0xf, 0xf, 0xf, 0xf};
  unsigned source_group_mask = 0xf;
  unsigned expected_destination_mask = 0xf;
  std::array<uint32_t, kGroups> source_data{};
};

struct Options {
  bool random_ready = false;
  bool mutate_command_after_accept = false;
  bool simultaneous_read_returns = false;
  int read_error_group = -1;
  int read_response_error_group = -1;
  int read_protocol_group = -1;
  int write_error_group = -1;
  bool require_all_reads_before_write = false;
  uint32_t seed = 1;
};

struct WriteRecord {
  unsigned group;
  unsigned row;
  unsigned mask;
  uint32_t data;
};

struct Completion {
  unsigned context = 0;
  unsigned tag = 0;
  unsigned status = 0;
  unsigned requested_source = 0;
  unsigned requested_destination = 0;
  unsigned completed = 0;
  unsigned failed = 0;
  bool partial = false;
};

struct RunResult {
  Completion completion;
  std::vector<unsigned> reads;
  std::vector<WriteRecord> writes;
};

void clear_inputs(Vvsp_benes_exchange_engine& dut) {
  dut.cmd_valid_i = 0;
  dut.cmd_exec_context_i = 0;
  dut.cmd_tag_i = 0;
  dut.cmd_src_vrf_row_i = 0;
  dut.cmd_dst_vrf_row_i = 0;
  dut.cmd_route_entry_valid_i = 0;
  dut.cmd_route_ctrl_i = 0;
  dut.cmd_src_group_mask_i = 0;
  dut.cmd_src_byte_mask_i = 0;
  dut.cmd_expected_dst_group_mask_i = 0;
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
  dut.vrf_write_ready_i = 0;
  dut.vrf_write_cpl_valid_i = 0;
  dut.vrf_write_cpl_exec_context_i = 0;
  dut.vrf_write_cpl_tag_i = 0;
  dut.vrf_write_cpl_group_i = 0;
  dut.vrf_write_cpl_error_i = 0;
  dut.cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_benes_exchange_engine& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  dut.rst_ni = 1;
  dut.eval();
  expect_eq("reset idle", 0, dut.busy_o);
  expect_eq("reset command ready", 1, dut.cmd_ready_o);
  expect_eq("reset protocol clean", 0, dut.protocol_error_o);
}

void drive_command(Vvsp_benes_exchange_engine& dut, const Command& command) {
  dut.cmd_valid_i = 1;
  dut.cmd_exec_context_i = command.context;
  dut.cmd_tag_i = command.tag;
  dut.cmd_src_vrf_row_i = command.src_row;
  dut.cmd_dst_vrf_row_i = command.dst_row;
  dut.cmd_route_entry_valid_i = command.route_valid;
  dut.cmd_route_ctrl_i = command.route_control;
  dut.cmd_src_group_mask_i = command.source_group_mask;
  dut.cmd_src_byte_mask_i = pack_masks(command.source_masks);
  dut.cmd_expected_dst_group_mask_i = command.expected_destination_mask;
}

uint64_t read_tuple(const Vvsp_benes_exchange_engine& dut) {
  return uint64_t(dut.vrf_read_exec_context_o) |
         (uint64_t(dut.vrf_read_tag_o) << 4) |
         (uint64_t(dut.vrf_read_group_o) << 16) |
         (uint64_t(dut.vrf_read_row_o) << 20) |
         (uint64_t(dut.vrf_read_mask_o) << 28);
}

uint64_t write_tuple_low(const Vvsp_benes_exchange_engine& dut) {
  return uint64_t(dut.vrf_write_exec_context_o) |
         (uint64_t(dut.vrf_write_tag_o) << 4) |
         (uint64_t(dut.vrf_write_group_o) << 16) |
         (uint64_t(dut.vrf_write_row_o) << 20) |
         (uint64_t(dut.vrf_write_mask_o) << 28);
}

uint64_t completion_tuple(const Vvsp_benes_exchange_engine& dut) {
  return uint64_t(dut.cpl_exec_context_o) |
         (uint64_t(dut.cpl_tag_o) << 4) |
         (uint64_t(dut.cpl_status_o) << 16) |
         (uint64_t(dut.cpl_requested_src_group_mask_o) << 20) |
         (uint64_t(dut.cpl_requested_dst_group_mask_o) << 24) |
         (uint64_t(dut.cpl_completed_group_mask_o) << 28) |
         (uint64_t(dut.cpl_failed_group_mask_o) << 32) |
         (uint64_t(dut.cpl_partial_o) << 36);
}

RunResult run_command(Vvsp_benes_exchange_engine& dut, const Command& command,
                      Options options = {}) {
  RunResult result;
  uint32_t random = options.seed ? options.seed : 1;
  bool command_pending = true;
  bool command_accepted = false;

  bool read_cpl_pending = false;
  bool read_rsp_pending = false;
  unsigned read_cpl_delay = 0;
  unsigned read_rsp_delay = 0;
  unsigned pending_read_group = 0;

  bool write_cpl_pending = false;
  unsigned write_cpl_delay = 0;
  unsigned pending_write_group = 0;

  bool held_read = false;
  bool held_write = false;
  bool held_completion = false;
  uint64_t held_read_fields = 0;
  uint64_t held_write_fields = 0;
  uint32_t held_write_data = 0;
  uint64_t held_completion_fields = 0;

  for (unsigned cycle = 0; cycle < 2000; ++cycle) {
    clear_inputs(dut);
    if (command_pending) {
      drive_command(dut, command);
    } else if (options.mutate_command_after_accept) {
      dut.cmd_exec_context_i = command.context ^ 1u;
      dut.cmd_tag_i = command.tag ^ 0xffu;
      dut.cmd_src_vrf_row_i = command.src_row ^ 0xfu;
      dut.cmd_dst_vrf_row_i = command.dst_row ^ 0xfu;
      dut.cmd_route_entry_valid_i = 0;
      dut.cmd_route_ctrl_i = command.route_control ^ 0x3fu;
      dut.cmd_src_group_mask_i = command.source_group_mask ^ 0xfu;
      dut.cmd_src_byte_mask_i = pack_masks(command.source_masks) ^ 0xffffu;
      dut.cmd_expected_dst_group_mask_i =
          command.expected_destination_mask ^ 0xfu;
    }

    const uint32_t entropy = next_random(random);
    dut.vrf_read_ready_i =
        !options.random_ready || ((entropy & 3u) != 0);
    dut.vrf_write_ready_i =
        !options.random_ready || (((entropy >> 2) & 3u) != 0);
    dut.cpl_ready_i =
        !options.random_ready || (((entropy >> 4) & 3u) != 0);

    if (read_cpl_pending && read_cpl_delay == 0) {
      dut.vrf_read_cpl_valid_i = 1;
      dut.vrf_read_cpl_exec_context_i = command.context;
      dut.vrf_read_cpl_tag_i = command.tag;
      dut.vrf_read_cpl_group_i = pending_read_group;
      dut.vrf_read_cpl_error_i =
          int(pending_read_group) == options.read_error_group;
      if (int(pending_read_group) == options.read_protocol_group)
        dut.vrf_read_cpl_tag_i = command.tag ^ 1u;
    }
    if (read_rsp_pending && read_rsp_delay == 0) {
      dut.vrf_read_rsp_valid_i = 1;
      dut.vrf_read_rsp_exec_context_i = command.context;
      dut.vrf_read_rsp_tag_i = command.tag;
      dut.vrf_read_rsp_group_i = pending_read_group;
      dut.vrf_read_rsp_data_i = command.source_data[pending_read_group];
      dut.vrf_read_rsp_error_i =
          int(pending_read_group) == options.read_response_error_group;
      // Error responses carry no usable bytes.  Context/tag/group still have
      // to match, but the engine must not require a data-valid mask on error.
      dut.vrf_read_rsp_mask_i = dut.vrf_read_rsp_error_i
                                    ? 0u
                                    : command.source_masks[pending_read_group];
    }
    if (write_cpl_pending && write_cpl_delay == 0) {
      dut.vrf_write_cpl_valid_i = 1;
      dut.vrf_write_cpl_exec_context_i = command.context;
      dut.vrf_write_cpl_tag_i = command.tag;
      dut.vrf_write_cpl_group_i = pending_write_group;
      dut.vrf_write_cpl_error_i =
          int(pending_write_group) == options.write_error_group;
    }

    dut.eval();

    if (held_read) {
      expect_eq("stalled read remains valid", 1, dut.vrf_read_valid_o);
      expect_eq("stalled read fields stable", held_read_fields,
                read_tuple(dut));
    }
    if (held_write) {
      expect_eq("stalled write remains valid", 1, dut.vrf_write_valid_o);
      expect_eq("stalled write fields stable", held_write_fields,
                write_tuple_low(dut));
      expect_eq("stalled write data stable", held_write_data,
                dut.vrf_write_data_o);
    }
    if (held_completion) {
      expect_eq("stalled completion remains valid", 1, dut.cpl_valid_o);
      expect_eq("stalled completion fields stable", held_completion_fields,
                completion_tuple(dut));
    }

    const bool command_fire = dut.cmd_valid_i && dut.cmd_ready_o;
    const bool read_fire = dut.vrf_read_valid_o && dut.vrf_read_ready_i;
    const bool read_cpl_fire =
        dut.vrf_read_cpl_valid_i && dut.vrf_read_cpl_ready_o;
    const bool read_rsp_fire =
        dut.vrf_read_rsp_valid_i && dut.vrf_read_rsp_ready_o;
    const bool write_fire = dut.vrf_write_valid_o && dut.vrf_write_ready_i;
    const bool write_cpl_fire =
        dut.vrf_write_cpl_valid_i && dut.vrf_write_cpl_ready_o;
    const bool completion_fire = dut.cpl_valid_o && dut.cpl_ready_i;

    if (command_fire) {
      command_pending = false;
      command_accepted = true;
    }
    if (read_fire) {
      expect_eq("read context", command.context,
                dut.vrf_read_exec_context_o);
      expect_eq("read tag", command.tag, dut.vrf_read_tag_o);
      expect_eq("read row", command.src_row, dut.vrf_read_row_o);
      const unsigned group = dut.vrf_read_group_o;
      expect_eq("read group selected", 1,
                (command.source_group_mask >> group) & 1u);
      expect_eq("read byte mask", command.source_masks[group],
                dut.vrf_read_mask_o);
      result.reads.push_back(group);
      pending_read_group = group;
      read_cpl_pending = true;
      read_rsp_pending = true;
      // Alternate response order by group, then let endpoint backpressure
      // perturb it further.
      if (options.simultaneous_read_returns) {
        read_cpl_delay = 0;
        read_rsp_delay = 0;
      } else {
        read_cpl_delay = group & 1u ? 2u : 0u;
        read_rsp_delay = group & 1u ? 0u : 2u;
      }
    }
    if (read_cpl_fire) read_cpl_pending = false;
    if (read_rsp_fire) read_rsp_pending = false;

    if (write_fire) {
      if (options.require_all_reads_before_write) {
        expect_eq("all source rows captured before first write",
                  __builtin_popcount(command.source_group_mask),
                  result.reads.size());
      }
      result.writes.push_back(
          {unsigned(dut.vrf_write_group_o),
           unsigned(dut.vrf_write_row_o),
           unsigned(dut.vrf_write_mask_o),
           uint32_t(dut.vrf_write_data_o)});
      pending_write_group = dut.vrf_write_group_o;
      write_cpl_pending = true;
      write_cpl_delay = options.random_ready ? ((entropy >> 7) & 3u) : 0u;
    }
    if (write_cpl_fire) write_cpl_pending = false;

    if (completion_fire) {
      result.completion = {
          unsigned(dut.cpl_exec_context_o),
          unsigned(dut.cpl_tag_o),
          unsigned(dut.cpl_status_o),
          unsigned(dut.cpl_requested_src_group_mask_o),
          unsigned(dut.cpl_requested_dst_group_mask_o),
          unsigned(dut.cpl_completed_group_mask_o),
          unsigned(dut.cpl_failed_group_mask_o),
          bool(dut.cpl_partial_o)};
      tick(dut);
      expect_eq("command was accepted", 1, command_accepted);
      expect_eq("idle after completion", 0, dut.busy_o);
      return result;
    }

    held_read = dut.vrf_read_valid_o && !dut.vrf_read_ready_i;
    held_write = dut.vrf_write_valid_o && !dut.vrf_write_ready_i;
    held_completion = dut.cpl_valid_o && !dut.cpl_ready_i;
    if (held_read) {
      held_read_fields = read_tuple(dut);
      ++read_stalls;
    }
    if (held_write) {
      held_write_fields = write_tuple_low(dut);
      held_write_data = dut.vrf_write_data_o;
      ++write_stalls;
    }
    if (held_completion) {
      held_completion_fields = completion_tuple(dut);
      ++completion_stalls;
    }

    if (read_cpl_pending && read_cpl_delay != 0) --read_cpl_delay;
    if (read_rsp_pending && read_rsp_delay != 0) --read_rsp_delay;
    if (write_cpl_pending && write_cpl_delay != 0) --write_cpl_delay;
    tick(dut);
  }
  fail("command timeout", 1, 0);
}

Command make_command(unsigned control,
                     std::array<unsigned, kGroups> masks,
                     unsigned tag) {
  Command command;
  command.tag = tag & 0xffu;
  command.context = command.tag & 1u;
  command.src_row = command.tag & 0xfu;
  command.dst_row = (command.tag + 5u) & 0xfu;
  command.route_control = control;
  command.source_masks = masks;
  command.source_group_mask = group_mask(masks);
  const auto routed_masks = route_reference<unsigned>(control, masks);
  command.expected_destination_mask = group_mask(routed_masks);
  for (unsigned group = 0; group < kGroups; ++group) {
    command.source_data[group] = 0x10000000u * (group + 1u) ^
                                 (0x01010101u * command.tag) ^
                                 (0x00010203u * (group + 3u));
  }
  return command;
}

void expect_success(const Command& command, const RunResult& result) {
  expect_eq("completion context", command.context, result.completion.context);
  expect_eq("completion tag", command.tag, result.completion.tag);
  expect_eq("completion success", kCplOk, result.completion.status);
  expect_eq("completion requested source", command.source_group_mask,
            result.completion.requested_source);
  expect_eq("completion requested destination",
            command.expected_destination_mask,
            result.completion.requested_destination);
  expect_eq("completion completed", command.expected_destination_mask,
            result.completion.completed);
  expect_eq("completion failed empty", 0, result.completion.failed);
  expect_eq("completion not partial", 0, result.completion.partial);
}

void expect_routing(const Command& command, const RunResult& result) {
  const auto output_source = permutation(command.route_control);
  const auto routed_masks =
      route_reference<unsigned>(command.route_control, command.source_masks);
  expect_eq("one read per active source",
            __builtin_popcount(command.source_group_mask), result.reads.size());
  expect_eq("one write per active destination",
            __builtin_popcount(command.expected_destination_mask),
            result.writes.size());

  unsigned emitted_bytes = 0;
  unsigned seen_destinations = 0;
  for (const WriteRecord& write : result.writes) {
    const unsigned source = output_source[write.group];
    expect_eq("write row", command.dst_row, write.row);
    expect_eq("routed data", command.source_data[source], write.data);
    expect_eq("routed byte mask", routed_masks[write.group], write.mask);
    expect_eq("destination written once", 0,
              seen_destinations & (1u << write.group));
    seen_destinations |= 1u << write.group;
    emitted_bytes += __builtin_popcount(write.mask);
  }
  expect_eq("destination set", command.expected_destination_mask,
            seen_destinations);
  expect_eq("byte-valid conservation", byte_count(command.source_masks),
            emitted_bytes);
}

void apply_writes(std::array<uint32_t, kGroups>& rows,
                  const std::vector<WriteRecord>& writes) {
  for (const WriteRecord& write : writes) {
    uint32_t expanded_mask = 0;
    for (unsigned byte = 0; byte < kRowBytes; ++byte) {
      if ((write.mask >> byte) & 1u) expanded_mask |= 0xffu << (8 * byte);
    }
    rows[write.group] = (rows[write.group] & ~expanded_mask) |
                        (write.data & expanded_mask);
  }
}

uint32_t broadcast_byte(uint32_t row, unsigned byte) {
  const uint32_t value = (row >> (8 * byte)) & 0xffu;
  return value * 0x01010101u;
}

void directed_routes(Vvsp_benes_exchange_engine& dut) {
  const std::array<std::array<unsigned, kGroups>, 4> routes{{
      {0, 1, 2, 3},
      {1, 0, 3, 2},
      {3, 2, 1, 0},
      {3, 0, 1, 2},
  }};
  const std::array<std::array<unsigned, kGroups>, 4> masks{{
      {0xf, 0xf, 0xf, 0xf},
      {0x1, 0x2, 0x4, 0x8},
      {0xf, 0x0, 0x5, 0x0},
      {0x3, 0xc, 0x9, 0x6},
  }};

  for (unsigned index = 0; index < routes.size(); ++index) {
    Command command =
        make_command(find_control(routes[index]), masks[index], 0x10 + index);
    Options options;
    options.random_ready = index != 0;
    options.mutate_command_after_accept = index == 3;
    options.simultaneous_read_returns = index == 0;
    options.require_all_reads_before_write = true;
    options.seed = 0x13579bdu ^ index;
    const RunResult result = run_command(dut, command, options);
    expect_success(command, result);
    expect_routing(command, result);
  }
}

void invalid_commands(Vvsp_benes_exchange_engine& dut) {
  Command invalid_route = make_command(0, {0xf, 0, 0, 0}, 0x30);
  invalid_route.route_valid = false;
  RunResult result = run_command(dut, invalid_route);
  expect_eq("invalid route status", kCplBadRoute,
            result.completion.status);
  expect_eq("invalid route no reads", 0, result.reads.size());
  expect_eq("invalid route no writes", 0, result.writes.size());

  Command bad_source_mask = make_command(0, {0xf, 0, 0, 0}, 0x31);
  bad_source_mask.source_group_mask = 0x3;
  result = run_command(dut, bad_source_mask);
  expect_eq("source mask mismatch status", kCplBadRoute,
            result.completion.status);
  expect_eq("source mask mismatch no reads", 0, result.reads.size());
  expect_eq("source mask mismatch no writes", 0, result.writes.size());

  Command bad_destination_mask = make_command(0, {0xf, 0, 0, 0}, 0x32);
  bad_destination_mask.expected_destination_mask ^= 0x2;
  result = run_command(dut, bad_destination_mask);
  expect_eq("destination mask mismatch status", kCplBadRoute,
            result.completion.status);
  expect_eq("destination mask mismatch no reads", 0, result.reads.size());
  expect_eq("destination mask mismatch no writes", 0,
            result.writes.size());
}

void error_paths(Vvsp_benes_exchange_engine& dut) {
  Command write_error = make_command(0, {0xf, 0xf, 0xf, 0xf}, 0x40);
  Options write_options;
  write_options.write_error_group = 1;
  write_options.random_ready = true;
  write_options.seed = 0x456789abu;
  RunResult result = run_command(dut, write_error, write_options);
  expect_eq("write failure status", kCplWriteError,
            result.completion.status);
  expect_eq("write failure completed prefix", 0x1,
            result.completion.completed);
  expect_eq("write failure group", 0x2, result.completion.failed);
  expect_eq("write failure partial", 1, result.completion.partial);
  expect_eq("write stop on first count", 2, result.writes.size());
  expect_eq("write stop first group", 0, result.writes[0].group);
  expect_eq("write stop failing group", 1, result.writes[1].group);

  Command read_error = make_command(0, {0xf, 0xf, 0xf, 0xf}, 0x41);
  Options read_options;
  read_options.read_error_group = 1;
  read_options.random_ready = true;
  read_options.seed = 0x89abcdefu;
  result = run_command(dut, read_error, read_options);
  expect_eq("read failure status", kCplReadError,
            result.completion.status);
  expect_eq("read failure group", 0x2, result.completion.failed);
  expect_eq("read failure no writes", 0, result.writes.size());
  expect_eq("read stops after failed group", 2, result.reads.size());

  Command response_error = make_command(0, {0xf, 0xf, 0, 0}, 0x43);
  Options response_error_options;
  response_error_options.read_response_error_group = 0;
  result = run_command(dut, response_error, response_error_options);
  expect_eq("read response failure status", kCplReadError,
            result.completion.status);
  expect_eq("read response failure group", 0x1,
            result.completion.failed);
  expect_eq("read response failure no writes", 0, result.writes.size());

  reset(dut);
  Command protocol = make_command(0, {0xf, 0xf, 0, 0}, 0x42);
  Options protocol_options;
  protocol_options.read_protocol_group = 0;
  result = run_command(dut, protocol, protocol_options);
  expect_eq("protocol failure status", kCplProtocolError,
            result.completion.status);
  expect_eq("protocol failure group", 0x1, result.completion.failed);
  expect_eq("protocol failure no writes", 0, result.writes.size());
  expect_eq("protocol sticky set", 1, dut.protocol_error_o);
  expect_eq("protocol sticky blocks new commands", 0, dut.cmd_ready_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  dut.eval();
  expect_eq("protocol sticky clears", 0, dut.protocol_error_o);
  expect_eq("command ready after external flush and clear", 1,
            dut.cmd_ready_o);
}

void multipass_37_bytes(Vvsp_benes_exchange_engine& dut) {
  const unsigned identity = find_control({0, 1, 2, 3});
  const std::array<std::array<unsigned, kGroups>, 3> masks{{
      {0xf, 0xf, 0xf, 0xf},
      {0xf, 0xf, 0xf, 0xf},
      {0xf, 0x1, 0x0, 0x0},
  }};
  unsigned total_bytes = 0;
  for (unsigned pass = 0; pass < masks.size(); ++pass) {
    Command command = make_command(identity, masks[pass], 0x50 + pass);
    command.src_row = pass;
    command.dst_row = 8 + pass;
    Options options;
    options.random_ready = true;
    options.seed = 0xa5a50000u + pass;
    const RunResult result = run_command(dut, command, options);
    expect_success(command, result);
    expect_routing(command, result);
    total_bytes += byte_count(masks[pass]);
  }
  expect_eq("three upper-level passes make 37 bytes", 37, total_bytes);
}

void word_distribution_and_reassembly(Vvsp_benes_exchange_engine& dut) {
  // This is the compositional sequence discussed for a row-level network:
  // repeatedly read one WORD row, send one byte plane to each group, perform
  // local broadcast in software, then use four bijective passes to rebuild
  // the WORD in every group.  No individual Bênes pass ever broadcasts.
  constexpr uint32_t word = 0xd3c2b1a0u;
  std::array<uint32_t, kGroups> plane_rows{};

  for (unsigned destination = 0; destination < kGroups; ++destination) {
    std::array<unsigned, kGroups> output_source{0, 1, 2, 3};
    std::swap(output_source[0], output_source[destination]);
    std::array<unsigned, kGroups> masks{};
    masks[0] = 1u << destination;
    Command command = make_command(find_control(output_source), masks,
                                   0x60 + destination);
    command.source_data = {word, 0, 0, 0};
    const RunResult result = run_command(dut, command);
    expect_success(command, result);
    expect_routing(command, result);
    apply_writes(plane_rows, result.writes);
  }

  std::array<uint32_t, kGroups> homogeneous_rows{};
  for (unsigned group = 0; group < kGroups; ++group) {
    homogeneous_rows[group] = broadcast_byte(plane_rows[group], group);
    expect_eq("local byte-plane broadcast",
              broadcast_byte(word, group), homogeneous_rows[group]);
  }

  std::array<uint32_t, kGroups> rebuilt_rows{};
  const std::array<unsigned, kGroups> plane_masks{0x1, 0x2, 0x4, 0x8};
  for (unsigned pass = 0; pass < kGroups; ++pass) {
    std::array<unsigned, kGroups> output_source{};
    for (unsigned destination = 0; destination < kGroups; ++destination)
      output_source[destination] = (destination + pass) % kGroups;
    Command command = make_command(find_control(output_source), plane_masks,
                                   0x68 + pass);
    command.source_data = homogeneous_rows;
    const RunResult result = run_command(dut, command);
    expect_success(command, result);
    expect_routing(command, result);
    apply_writes(rebuilt_rows, result.writes);
  }
  for (unsigned group = 0; group < kGroups; ++group)
    expect_eq("multi-pass WORD rebuilt without network broadcast", word,
              rebuilt_rows[group]);
}

void randomized(Vvsp_benes_exchange_engine& dut) {
  uint32_t random = 0xc001d00du;
  for (unsigned transaction = 0; transaction < 400; ++transaction) {
    const unsigned control = next_random(random) & 0x3fu;
    std::array<unsigned, kGroups> masks{};
    do {
      for (unsigned group = 0; group < kGroups; ++group) {
        const unsigned candidate = next_random(random) & 0xfu;
        masks[group] = (next_random(random) & 3u) == 0 ? 0 : candidate;
      }
    } while (group_mask(masks) == 0);

    Command command = make_command(control, masks, 0x80 + transaction);
    Options options;
    options.random_ready = true;
    options.mutate_command_after_accept = (transaction & 7u) == 0;
    options.require_all_reads_before_write = true;
    options.seed = next_random(random);
    const RunResult result = run_command(dut, command, options);
    expect_success(command, result);
    expect_routing(command, result);
    expect_eq("random protocol clean", 0, dut.protocol_error_o);
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_benes_exchange_engine dut;
  reset(dut);

  directed_routes(dut);
  invalid_commands(dut);
  error_paths(dut);
  multipass_37_bytes(dut);
  word_distribution_and_reassembly(dut);
  randomized(dut);

  expect_eq("read stalls exercised", 1, read_stalls != 0);
  expect_eq("write stalls exercised", 1, write_stalls != 0);
  expect_eq("completion stalls exercised", 1, completion_stalls != 0);
  dut.final();
  std::cout << "PASS: VSP row-level Benes exchange engine " << checks
            << " checks, including backpressure, errors, and multi-pass\n";
  return 0;
}
