// CLASS: integrated dependent route-wave execution pipeline
// CLAIM: retirement-gated OUT/IN fragments acquire their union resource once,
//        drive a real split-mask VRF gather through result/commit, and fan the
//        completion out losslessly while a later wave collects during RUN.
// NON_CLAIMS: multiple active route engines, external resource arbitration,
//             VRF bank timing, instruction decode, or final route throughput.

#include "Vvsp_cluster_route_wave_pipeline.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kLanes = 4;
constexpr unsigned kRows = 16;
constexpr uint8_t kRoleIn = 1;
constexpr uint8_t kRoleOut = 2;
constexpr uint8_t kTermWave = 0;
constexpr uint8_t kTermCancel = 2;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& label, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << label << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& label, uint64_t expected,
               uint64_t actual) {
  ++checks;
  if (expected != actual) fail(label, expected, actual);
}

void expect(bool condition, const std::string& label) {
  expect_eq(label, 1, condition ? 1 : 0);
}

uint64_t slot_field(uint64_t packed, unsigned slot, unsigned width) {
  const uint64_t mask = (uint64_t{1} << width) - 1;
  return (packed >> (slot * width)) & mask;
}

void settle(Vvsp_cluster_route_wave_pipeline& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_cluster_route_wave_pipeline& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

struct VrfModel {
  std::array<std::array<uint32_t, kRows>, kGroups> rows{};

  bool read_cpl_pending = false;
  bool read_rsp_pending = false;
  uint8_t read_context = 0;
  uint8_t read_tag = 0;
  uint8_t read_group = 0;
  uint8_t read_row = 0;
  uint8_t read_mask = 0;

  bool write_cpl_pending = false;
  uint8_t write_context = 0;
  uint8_t write_tag = 0;
  uint8_t write_group = 0;

  bool block_write_request = false;
  uint64_t reads = 0;
  uint64_t writes = 0;

  void drive(Vvsp_cluster_route_wave_pipeline& dut) const {
    dut.vrf_read_ready_i = 1;
    dut.vrf_read_cpl_valid_i = read_cpl_pending;
    dut.vrf_read_cpl_context_i = read_context;
    dut.vrf_read_cpl_tag_i = read_tag;
    dut.vrf_read_cpl_group_i = read_group;
    dut.vrf_read_cpl_error_i = 0;
    dut.vrf_read_rsp_valid_i = read_rsp_pending;
    dut.vrf_read_rsp_context_i = read_context;
    dut.vrf_read_rsp_tag_i = read_tag;
    dut.vrf_read_rsp_group_i = read_group;
    dut.vrf_read_rsp_data_i = rows[read_group][read_row];
    dut.vrf_read_rsp_mask_i = read_mask;
    dut.vrf_read_rsp_error_i = 0;

    dut.vrf_write_ready_i = !block_write_request;
    dut.vrf_write_cpl_valid_i = write_cpl_pending;
    dut.vrf_write_cpl_context_i = write_context;
    dut.vrf_write_cpl_tag_i = write_tag;
    dut.vrf_write_cpl_group_i = write_group;
    dut.vrf_write_cpl_error_i = 0;
  }

  void step(Vvsp_cluster_route_wave_pipeline& dut) {
    drive(dut);
    settle(dut);

    const bool finish_read_cpl =
        dut.vrf_read_cpl_valid_i && dut.vrf_read_cpl_ready_o;
    const bool finish_read_rsp =
        dut.vrf_read_rsp_valid_i && dut.vrf_read_rsp_ready_o;
    const bool finish_write =
        dut.vrf_write_cpl_valid_i && dut.vrf_write_cpl_ready_o;
    const bool accept_read = dut.vrf_read_valid_o && dut.vrf_read_ready_i;
    const bool accept_write = dut.vrf_write_valid_o && dut.vrf_write_ready_i;

    const uint8_t next_read_context = dut.vrf_read_context_o;
    const uint8_t next_read_tag = dut.vrf_read_tag_o;
    const uint8_t next_read_group = dut.vrf_read_group_o;
    const uint8_t next_read_row = dut.vrf_read_row_o;
    const uint8_t next_read_mask = dut.vrf_read_mask_o;
    const uint8_t next_write_context = dut.vrf_write_context_o;
    const uint8_t next_write_tag = dut.vrf_write_tag_o;
    const uint8_t next_write_group = dut.vrf_write_group_o;
    const uint8_t next_write_row = dut.vrf_write_row_o;
    const uint8_t next_write_mask = dut.vrf_write_mask_o;
    const uint32_t next_write_data = dut.vrf_write_data_o;

    tick(dut);

    if (finish_read_cpl) read_cpl_pending = false;
    if (finish_read_rsp) read_rsp_pending = false;
    if (finish_write) write_cpl_pending = false;

    if (accept_read) {
      expect(!read_cpl_pending && !read_rsp_pending,
             "VRF model single read outstanding");
      read_cpl_pending = true;
      read_rsp_pending = true;
      read_context = next_read_context;
      read_tag = next_read_tag;
      read_group = next_read_group;
      read_row = next_read_row;
      read_mask = next_read_mask;
      ++reads;
    }

    if (accept_write) {
      expect(!write_cpl_pending, "VRF model single write outstanding");
      write_cpl_pending = true;
      write_context = next_write_context;
      write_tag = next_write_tag;
      write_group = next_write_group;
      for (unsigned lane = 0; lane < kLanes; ++lane) {
        if ((next_write_mask >> lane) & 1u) {
          const uint32_t byte_mask = uint32_t{0xff} << (8 * lane);
          rows[next_write_group][next_write_row] =
              (rows[next_write_group][next_write_row] & ~byte_mask) |
              (next_write_data & byte_mask);
        }
      }
      ++writes;
    }
  }
};

struct Fragment {
  uint8_t context = 0;
  uint8_t epoch = 0;
  uint8_t route_id = 0;
  uint8_t role = kRoleIn;
  uint8_t participant = 0;
  uint8_t token = 0;
  uint8_t tag = 0;
  uint8_t group_mask = 0;
  uint8_t source_row = 0;
  uint8_t index_row = 0;
  uint8_t destination_row = 0;
};

void clear_fragment(Vvsp_cluster_route_wave_pipeline& dut) {
  dut.fragment_valid_i = 0;
  dut.fragment_legal_i = 1;
  dut.fragment_cause_i = 0;
  dut.fragment_context_i = 0;
  dut.fragment_epoch_i = 0;
  dut.fragment_route_id_i = 0;
  dut.fragment_role_i = kRoleIn;
  dut.fragment_participant_i = 0;
  dut.fragment_retire_token_i = 0;
  dut.fragment_tag_i = 0;
  dut.fragment_group_mask_i = 0;
  dut.fragment_source_row_i = 0;
  dut.fragment_index_row_i = 0;
  dut.fragment_destination_row_i = 0;
}

void clear_inputs(Vvsp_cluster_route_wave_pipeline& dut) {
  clear_fragment(dut);
  dut.participant_frontier_i = 0;
  dut.flush_valid_i = 0;
  dut.flush_context_i = 0;
  dut.flush_epoch_i = 0;
  dut.epoch_advance_valid_i = 0;
  dut.epoch_advance_context_i = 0;
  dut.epoch_advance_new_epoch_i = 0;
  dut.resource_ready_i = 0;
  dut.cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_cluster_route_wave_pipeline& dut, VrfModel& vrf) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  vrf.step(dut);
  vrf.step(dut);
  dut.rst_ni = 1;
  vrf.step(dut);
  expect_eq("reset collection empty", 0, dut.collect_occupancy_o);
  expect_eq("reset no resource request", 0, dut.resource_valid_o);
  expect_eq("reset no completion", 0, dut.cpl_valid_o);
  expect_eq("reset idle", 0, dut.busy_o);
  expect_eq("reset protocol clean", 0, dut.protocol_error_o);
}

void set_frontiers(Vvsp_cluster_route_wave_pipeline& dut, uint8_t first,
                   uint8_t second) {
  dut.participant_frontier_i =
      uint16_t{first} | (uint16_t{second} << 8);
  settle(dut);
}

void drive_fragment(Vvsp_cluster_route_wave_pipeline& dut,
                    const Fragment& fragment) {
  dut.fragment_valid_i = 1;
  dut.fragment_legal_i = 1;
  dut.fragment_cause_i = 0;
  dut.fragment_context_i = fragment.context;
  dut.fragment_epoch_i = fragment.epoch;
  dut.fragment_route_id_i = fragment.route_id;
  dut.fragment_role_i = fragment.role;
  dut.fragment_participant_i = fragment.participant;
  dut.fragment_retire_token_i = fragment.token;
  dut.fragment_tag_i = fragment.tag;
  dut.fragment_group_mask_i = fragment.group_mask;
  dut.fragment_source_row_i = fragment.source_row;
  dut.fragment_index_row_i = fragment.index_row;
  dut.fragment_destination_row_i = fragment.destination_row;
}

void send_fragment(Vvsp_cluster_route_wave_pipeline& dut, VrfModel& vrf,
                   const Fragment& fragment, const std::string& label,
                   bool require_run = false) {
  drive_fragment(dut, fragment);
  vrf.drive(dut);
  settle(dut);
  expect_eq(label + " ready", 1, dut.fragment_ready_o);
  if (require_run) expect_eq(label + " overlaps RUN", 1, dut.run_active_o);
  vrf.step(dut);
  clear_fragment(dut);
  vrf.drive(dut);
  settle(dut);
  if (require_run)
    expect_eq(label + " RUN remains active", 1, dut.run_active_o);
}

void wait_for_resource(Vvsp_cluster_route_wave_pipeline& dut, VrfModel& vrf,
                       const std::string& label, unsigned limit = 40) {
  for (unsigned cycle = 0; cycle < limit; ++cycle) {
    vrf.drive(dut);
    settle(dut);
    if (dut.resource_valid_o) return;
    vrf.step(dut);
  }
  fail(label + " resource timeout", 1, 0);
}

void wait_for_fanout(Vvsp_cluster_route_wave_pipeline& dut, VrfModel& vrf,
                     const std::string& label, unsigned limit = 200) {
  for (unsigned cycle = 0; cycle < limit; ++cycle) {
    vrf.drive(dut);
    settle(dut);
    if (dut.fanout_pending_o && dut.cpl_valid_o) return;
    vrf.step(dut);
  }
  fail(label + " fanout timeout", 1, 0);
}

void expect_completion(const Vvsp_cluster_route_wave_pipeline& dut,
                       unsigned slot, uint8_t route_id, uint8_t role,
                       uint8_t participant, uint8_t token, uint8_t tag,
                       uint8_t group_mask, const std::string& label) {
  expect_eq(label + " valid", 1, (dut.cpl_valid_o >> slot) & 1u);
  expect_eq(label + " kind", kTermWave,
            slot_field(dut.cpl_kind_o, slot, 2));
  expect_eq(label + " route ID", route_id,
            slot_field(dut.cpl_route_id_o, slot, 8));
  expect_eq(label + " role", role,
            slot_field(dut.cpl_role_o, slot, 2));
  expect_eq(label + " participant", participant,
            slot_field(dut.cpl_participant_o, slot, 1));
  expect_eq(label + " token", token,
            slot_field(dut.cpl_retire_token_o, slot, 8));
  expect_eq(label + " tag", tag,
            slot_field(dut.cpl_tag_o, slot, 8));
  expect_eq(label + " group mask", group_mask,
            slot_field(dut.cpl_group_mask_o, slot, 4));
  expect_eq(label + " legal", 0, (dut.cpl_illegal_o >> slot) & 1u);
  expect_eq(label + " not rejected", 0,
            (dut.cpl_rejected_o >> slot) & 1u);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_cluster_route_wave_pipeline dut;
  VrfModel vrf;
  reset(dut, vrf);

  // Wave one publishes source bytes in groups 0/1 but takes its index and
  // commits its destination only in groups 2/3.  This makes accidental reuse
  // of one mask for both halves directly observable in traffic and data.
  vrf.rows[0][5] = 0x04030201u;
  vrf.rows[1][5] = 0x08070605u;
  vrf.rows[2][5] = 0xeeeeeeeeu;
  vrf.rows[3][5] = 0xffffffffu;
  vrf.rows[2][6] = 0x04050607u;  // lanes select 7,6,5,4
  vrf.rows[3][6] = 0x03020100u;  // lanes select 0,1,2,3
  vrf.rows[0][7] = 0x11111111u;
  vrf.rows[1][7] = 0x22222222u;
  vrf.rows[2][7] = 0x33333333u;
  vrf.rows[3][7] = 0x44444444u;

  const Fragment wave1_out{0, 1, 0x31, kRoleOut, 0, 5, 0xa0,
                           0x3, 5, 0, 0};
  const Fragment wave1_in{0, 1, 0x31, kRoleIn, 1, 7, 0xb1,
                          0xc, 0, 6, 7};

  // Both fragments may be resident while their participant frontiers lag, but
  // the integrated route engine must remain completely untouched.
  set_frontiers(dut, 4, 6);
  send_fragment(dut, vrf, wave1_out, "wave1 OUT");
  send_fragment(dut, vrf, wave1_in, "wave1 IN");
  for (unsigned stall = 0; stall < 4; ++stall) {
    vrf.step(dut);
    expect_eq("frontier stall no resource", 0, dut.resource_valid_o);
    expect_eq("frontier stall no read request", 0, dut.vrf_read_valid_o);
    expect_eq("frontier stall no write request", 0, dut.vrf_write_valid_o);
    expect_eq("frontier stall zero reads", 0, vrf.reads);
    expect_eq("frontier stall zero writes", 0, vrf.writes);
  }

  set_frontiers(dut, 5, 7);
  wait_for_resource(dut, vrf, "wave1");
  expect_eq("wave1 launch pending", 1, dut.launch_pending_o);
  expect_eq("wave1 resource context", 0, dut.resource_context_o);
  expect_eq("wave1 resource mask union", 0xf, dut.resource_group_mask_o);
  expect_eq("wave1 resource epoch", 1, dut.resource_epoch_o);
  expect_eq("wave1 resource route ID", 0x31, dut.resource_route_id_o);

  // A denied atomic resource grant freezes LAUNCH and still creates no hidden
  // read-side traffic.  The first write will be held later as a separate
  // route-result/commit boundary check.
  for (unsigned stall = 0; stall < 3; ++stall) {
    vrf.step(dut);
    expect_eq("resource stall valid", 1, dut.resource_valid_o);
    expect_eq("resource stall launch", 1, dut.launch_pending_o);
    expect_eq("resource stall not RUN", 0, dut.run_active_o);
    expect_eq("resource stall context stable", 0, dut.resource_context_o);
    expect_eq("resource stall mask stable", 0xf, dut.resource_group_mask_o);
    expect_eq("resource stall route stable", 0x31,
              dut.resource_route_id_o);
    expect_eq("resource stall zero reads", 0, vrf.reads);
    expect_eq("resource stall zero writes", 0, vrf.writes);
  }

  vrf.block_write_request = true;
  dut.resource_ready_i = 1;
  vrf.step(dut);
  dut.resource_ready_i = 0;
  vrf.drive(dut);
  settle(dut);
  expect_eq("wave1 enters RUN", 1, dut.run_active_o);
  expect_eq("wave1 resource request consumed", 0, dut.resource_valid_o);

  // A second unrelated key is accepted while wave one is using the engine.
  // It cannot launch yet, but both fragment handshakes and the live table entry
  // prove collection is not serialized behind RUN.
  vrf.rows[0][8] = 0x44332211u;
  vrf.rows[1][9] = 0x00010203u;  // lanes select 3,2,1,0
  vrf.rows[1][10] = 0xa5a5a5a5u;
  const Fragment wave2_out{0, 1, 0x32, kRoleOut, 0, 8, 0xc0,
                           0x1, 8, 0, 0};
  const Fragment wave2_in{0, 1, 0x32, kRoleIn, 1, 9, 0xd1,
                          0x2, 0, 9, 10};
  set_frontiers(dut, 8, 9);
  send_fragment(dut, vrf, wave2_out, "wave2 OUT", true);
  send_fragment(dut, vrf, wave2_in, "wave2 IN", true);
  expect_eq("wave2 entry collected during RUN", 1,
            dut.collect_occupancy_o);

  // A complete wave can be staged behind the busy controller.  Flushing its
  // epoch must convert that staged WAVE into CANCEL; it must never acquire the
  // resource or touch the VRF after wave one drains.
  dut.flush_valid_i = 1;
  dut.flush_context_i = wave2_out.context;
  dut.flush_epoch_i = wave2_out.epoch;
  vrf.step(dut);
  dut.flush_valid_i = 0;
  vrf.drive(dut);
  settle(dut);
  expect_eq("flushed staged wave does not disturb active RUN", 1,
            dut.run_active_o);

  // All four reads must complete before the explicit registered route result
  // appears.  Holding the write port proves the full result and byte enable are
  // stable; changing the backing rows afterward cannot affect the snapshot.
  unsigned snapshot_timeout = 0;
  while ((vrf.reads != 4 || vrf.read_cpl_pending ||
          vrf.read_rsp_pending) && snapshot_timeout++ < 100) {
    vrf.step(dut);
  }
  expect(snapshot_timeout < 100, "wave1 snapshot completes");
  vrf.drive(dut);
  settle(dut);
  expect_eq("wave1 split-mask read count", 4, vrf.reads);
  expect_eq("wave1 no early commit", 0, vrf.writes);
  expect_eq("wave1 result stage hides write", 0, dut.vrf_write_valid_o);
  vrf.step(dut);
  expect_eq("wave1 registered write becomes visible", 1,
            dut.vrf_write_valid_o);
  expect_eq("wave1 first commit group", 2, dut.vrf_write_group_o);
  expect_eq("wave1 first commit row", 7, dut.vrf_write_row_o);
  expect_eq("wave1 first commit mask", 0xf, dut.vrf_write_mask_o);
  expect_eq("wave1 first route result", 0x05060708u,
            dut.vrf_write_data_o);
  const uint32_t held_result = dut.vrf_write_data_o;
  const uint8_t held_mask = dut.vrf_write_mask_o;
  vrf.rows[0][5] = 0xffffffffu;
  vrf.rows[1][5] = 0xffffffffu;
  vrf.rows[2][6] = 0xffffffffu;
  for (unsigned stall = 0; stall < 3; ++stall) {
    vrf.step(dut);
    expect_eq("route-result stall valid", 1, dut.vrf_write_valid_o);
    expect_eq("route-result stall group", 2, dut.vrf_write_group_o);
    expect_eq("route-result stall data", held_result,
              dut.vrf_write_data_o);
    expect_eq("route-result stall mask", held_mask,
              dut.vrf_write_mask_o);
    expect_eq("route-result stall no commit", 0, vrf.writes);
  }

  vrf.block_write_request = false;
  wait_for_fanout(dut, vrf, "wave1");
  expect_eq("wave1 completion slots", 0x3, dut.cpl_valid_o);
  expect_eq("wave1 split-mask writes", 2, vrf.writes);
  expect_eq("wave1 inactive destination group0", 0x11111111u,
            vrf.rows[0][7]);
  expect_eq("wave1 inactive destination group1", 0x22222222u,
            vrf.rows[1][7]);
  expect_eq("wave1 destination group2", 0x05060708u, vrf.rows[2][7]);
  expect_eq("wave1 destination group3", 0x04030201u, vrf.rows[3][7]);
  expect_eq("wave1 no invalid elements", 0,
            slot_field(dut.cpl_invalid_element_mask_o, 0, 16));
  expect_eq("wave1 protocol clean", 0, dut.protocol_error_o);

  expect_completion(dut, 0, 0x31, kRoleIn, 1, 7, 0xb1, 0xc,
                    "wave1 IN completion");
  expect_completion(dut, 1, 0x31, kRoleOut, 0, 5, 0xa0, 0x3,
                    "wave1 OUT completion");

  // Consume IN immediately, then independently hold OUT.  Its identity must
  // remain stable and the next collected wave must not steal the route engine
  // until FANOUT is fully drained.
  dut.cpl_ready_i = 0x1;
  vrf.step(dut);
  dut.cpl_ready_i = 0;
  vrf.drive(dut);
  settle(dut);
  expect_eq("IN consumed independently", 0x2, dut.cpl_valid_o);
  expect_eq("OUT keeps FANOUT pending", 1, dut.fanout_pending_o);
  for (unsigned stall = 0; stall < 3; ++stall) {
    vrf.step(dut);
    expect_eq("OUT completion held", 0x2, dut.cpl_valid_o);
    expect_completion(dut, 1, 0x31, kRoleOut, 0, 5, 0xa0, 0x3,
                      "held OUT completion");
    expect_eq("next wave cannot launch through FANOUT", 0,
              dut.resource_valid_o);
    expect_eq("fanout stall creates no extra reads", 4, vrf.reads);
    expect_eq("fanout stall creates no extra writes", 2, vrf.writes);
  }

  dut.cpl_ready_i = 0x2;
  vrf.step(dut);
  dut.cpl_ready_i = 0;
  vrf.drive(dut);
  settle(dut);
  expect_eq("both participant completions drained", 0, dut.cpl_valid_o);
  expect_eq("wave1 FANOUT drained", 0, dut.fanout_pending_o);

  // The terminal-staged wave now emerges only as two CANCEL completions.
  // Granting the resource aggressively makes any accidental parent launch
  // and VRF traffic observable.
  dut.resource_ready_i = 1;
  wait_for_fanout(dut, vrf, "cancelled wave2");
  dut.resource_ready_i = 0;
  expect_eq("cancelled wave2 completion slots", 0x3, dut.cpl_valid_o);
  expect_eq("cancelled wave2 IN kind", kTermCancel,
            slot_field(dut.cpl_kind_o, 0, 2));
  expect_eq("cancelled wave2 OUT kind", kTermCancel,
            slot_field(dut.cpl_kind_o, 1, 2));
  expect_eq("cancelled wave2 creates no resource request", 0,
            dut.resource_valid_o);
  expect_eq("cancelled wave2 creates no extra reads", 4, vrf.reads);
  expect_eq("cancelled wave2 creates no extra writes", 2, vrf.writes);
  expect_eq("cancelled wave2 leaves destination unchanged", 0xa5a5a5a5u,
            vrf.rows[1][10]);
  expect_eq("cancelled wave2 IN illegal groups zero", 0,
            slot_field(dut.cpl_illegal_group_mask_o, 0, 4));
  expect_eq("cancelled wave2 OUT illegal groups zero", 0,
            slot_field(dut.cpl_illegal_group_mask_o, 1, 4));

  dut.cpl_ready_i = 0x3;
  vrf.step(dut);
  dut.cpl_ready_i = 0;
  vrf.drive(dut);
  settle(dut);
  expect_eq("final completions drained", 0, dut.cpl_valid_o);
  expect_eq("final pipeline idle", 0, dut.busy_o);
  expect_eq("final protocol clean", 0, dut.protocol_error_o);

  std::cout << "PASS vsp_cluster_route_wave_pipeline " << checks
            << " checks\n";
  return 0;
}
