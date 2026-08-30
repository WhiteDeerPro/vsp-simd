// CLASS: cluster register-route transaction
// CLAIM: a VRF-backed 4xSIMD4 route snapshots vs/vi before any vd write,
//        preserves inactive groups and active invalid destination bytes, and
//        holds one lossless completion under backpressure.
// NON_CLAIMS: parallel RF capture/commit timing, final PPA, larger route trees.

#include "Vvsp_cluster_register_route_engine.h"
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
using Bytes = std::array<uint8_t, kGroups * kLanes>;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& label, const std::string& field) {
  std::cerr << "FAIL " << label << " field=" << field << '\n';
  std::exit(1);
}

void expect(bool condition, const std::string& label,
            const std::string& field) {
  ++checks;
  if (!condition) fail(label, field);
}

void settle(Vvsp_cluster_register_route_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_cluster_register_route_engine& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

uint32_t pack_group(const Bytes& bytes, unsigned group) {
  uint32_t word = 0;
  for (unsigned lane = 0; lane < kLanes; ++lane)
    word |= uint32_t{bytes[group * kLanes + lane]} << (8 * lane);
  return word;
}

Bytes unpack_rows(
    const std::array<std::array<uint32_t, kRows>, kGroups>& vrf,
    unsigned row) {
  Bytes bytes{};
  for (unsigned group = 0; group < kGroups; ++group) {
    for (unsigned lane = 0; lane < kLanes; ++lane) {
      bytes[group * kLanes + lane] =
          static_cast<uint8_t>(vrf[group][row] >> (8 * lane));
    }
  }
  return bytes;
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
  bool read_error = false;
  bool block_read_cpl = false;
  bool block_read_rsp = false;
  bool write_pending = false;
  uint8_t write_context = 0;
  uint8_t write_tag = 0;
  uint8_t write_group = 0;
  bool write_error = false;
  bool fail_next_read = false;
  int fail_write_group = -1;
  uint64_t reads = 0;
  uint64_t writes = 0;

  void step(Vvsp_cluster_register_route_engine& dut) {
    dut.vrf_read_ready_i = 1;
    dut.vrf_write_ready_i = 1;

    dut.vrf_read_cpl_valid_i = read_cpl_pending && !block_read_cpl;
    dut.vrf_read_rsp_valid_i = read_rsp_pending && !block_read_rsp;
    dut.vrf_read_cpl_context_i = read_context;
    dut.vrf_read_cpl_tag_i = read_tag;
    dut.vrf_read_cpl_group_i = read_group;
    dut.vrf_read_cpl_error_i = read_error;
    dut.vrf_read_rsp_context_i = read_context;
    dut.vrf_read_rsp_tag_i = read_tag;
    dut.vrf_read_rsp_group_i = read_group;
    dut.vrf_read_rsp_data_i = rows[read_group][read_row];
    dut.vrf_read_rsp_mask_i = read_mask;
    dut.vrf_read_rsp_error_i = read_error;

    dut.vrf_write_cpl_valid_i = write_pending;
    dut.vrf_write_cpl_context_i = write_context;
    dut.vrf_write_cpl_tag_i = write_tag;
    dut.vrf_write_cpl_group_i = write_group;
    dut.vrf_write_cpl_error_i = write_error;
    settle(dut);

    const bool finish_read_cpl = dut.vrf_read_cpl_valid_i &&
                                 dut.vrf_read_cpl_ready_o;
    const bool finish_read_rsp = dut.vrf_read_rsp_valid_i &&
                                 dut.vrf_read_rsp_ready_o;
    const bool finish_write = dut.vrf_write_cpl_valid_i &&
                              dut.vrf_write_cpl_ready_o;
    const bool accept_read = dut.vrf_read_valid_o && dut.vrf_read_ready_i;
    const bool accept_write = dut.vrf_write_valid_o && dut.vrf_write_ready_i;

    uint8_t next_read_context = dut.vrf_read_context_o;
    uint8_t next_read_tag = dut.vrf_read_tag_o;
    uint8_t next_read_group = dut.vrf_read_group_o;
    uint8_t next_read_row = dut.vrf_read_row_o;
    uint8_t next_read_mask = dut.vrf_read_mask_o;
    uint8_t next_write_context = dut.vrf_write_context_o;
    uint8_t next_write_tag = dut.vrf_write_tag_o;
    uint8_t next_write_group = dut.vrf_write_group_o;
    uint8_t next_write_row = dut.vrf_write_row_o;
    uint8_t next_write_mask = dut.vrf_write_mask_o;
    uint32_t next_write_data = dut.vrf_write_data_o;

    tick(dut);

    if (finish_read_cpl) read_cpl_pending = false;
    if (finish_read_rsp) read_rsp_pending = false;
    if (finish_write) {
      write_pending = false;
      write_error = false;
    }

    if (accept_read) {
      expect(!read_cpl_pending && !read_rsp_pending, "VRF model",
             "single read outstanding");
      read_cpl_pending = true;
      read_rsp_pending = true;
      read_context = next_read_context;
      read_tag = next_read_tag;
      read_group = next_read_group;
      read_row = next_read_row;
      read_mask = next_read_mask;
      read_error = fail_next_read;
      fail_next_read = false;
      ++reads;
    }
    if (accept_write) {
      expect(!write_pending, "VRF model", "single write outstanding");
      write_pending = true;
      write_context = next_write_context;
      write_tag = next_write_tag;
      write_group = next_write_group;
      write_error = static_cast<int>(next_write_group) == fail_write_group;
      if (write_error) fail_write_group = -1;
      if (!write_error) {
        for (unsigned lane = 0; lane < kLanes; ++lane) {
          if ((next_write_mask >> lane) & 1u) {
            const uint32_t byte_mask = uint32_t{0xff} << (8 * lane);
            rows[next_write_group][next_write_row] =
                (rows[next_write_group][next_write_row] & ~byte_mask) |
                (next_write_data & byte_mask);
          }
        }
      }
      ++writes;
    }
  }
};

void reset(Vvsp_cluster_register_route_engine& dut, VrfModel& vrf) {
  dut.cmd_valid_i = 0;
  dut.cmd_legal_i = 1;
  dut.cpl_ready_i = 0;
  dut.protocol_error_clear_i = 0;
  dut.rst_ni = 0;
  vrf.step(dut);
  dut.rst_ni = 1;
  settle(dut);
  expect(dut.cmd_ready_o && !dut.busy_o && !dut.cpl_valid_o,
         "reset", "idle");
}

void launch(Vvsp_cluster_register_route_engine& dut, VrfModel& vrf,
            uint8_t mask, uint8_t source, uint8_t index, uint8_t destination,
            uint8_t tag, bool legal = true, uint8_t io_mode = 0) {
  dut.cmd_context_i = 0;
  dut.cmd_tag_i = tag;
  dut.cmd_group_mask_i = mask;
  dut.cmd_source_row_i = source;
  dut.cmd_index_row_i = index;
  dut.cmd_destination_row_i = destination;
  dut.cmd_io_mode_i = io_mode;
  dut.cmd_legal_i = legal;
  dut.cmd_valid_i = 1;
  settle(dut);
  expect(dut.cmd_ready_o, "launch", "ready");
  vrf.step(dut);
  dut.cmd_valid_i = 0;
}

void run_to_completion(Vvsp_cluster_register_route_engine& dut,
                       VrfModel& vrf, unsigned limit = 200) {
  for (unsigned cycle = 0; cycle < limit && !dut.cpl_valid_o; ++cycle)
    vrf.step(dut);
  expect(dut.cpl_valid_o, "run", "completion timeout");
}

void consume(Vvsp_cluster_register_route_engine& dut, VrfModel& vrf) {
  dut.cpl_ready_i = 1;
  vrf.step(dut);
  dut.cpl_ready_i = 0;
  settle(dut);
  expect(!dut.cpl_valid_o && dut.cmd_ready_o, "consume", "reopened");
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_cluster_register_route_engine dut;
  VrfModel vrf;
  reset(dut, vrf);

  // Partial dependent waves remain encoded but cannot execute without a peer.
  for (uint8_t io_mode : {uint8_t{1}, uint8_t{2}}) {
    const uint64_t reads_before_io_reject = vrf.reads;
    const uint64_t writes_before_io_reject = vrf.writes;
    launch(dut, vrf, 0xf, 1, 2, 3,
           static_cast<uint8_t>(0x30 + io_mode), true, io_mode);
    run_to_completion(dut, vrf);
    expect(dut.cpl_illegal_o && dut.cpl_rejected_o,
           "route IO mode reject", "ordered status");
    expect(vrf.reads == reads_before_io_reject &&
               vrf.writes == writes_before_io_reject,
           "route IO mode reject", "no VRF traffic");
    consume(dut, vrf);
  }

  Bytes source{};
  Bytes reverse{};
  for (unsigned lane = 0; lane < source.size(); ++lane) {
    source[lane] = static_cast<uint8_t>(0x20 + lane);
    reverse[lane] = static_cast<uint8_t>(15 - lane);
  }
  for (unsigned group = 0; group < kGroups; ++group) {
    vrf.rows[group][1] = pack_group(source, group);
    vrf.rows[group][2] = pack_group(reverse, group);
    vrf.rows[group][3] = 0xeeeeeeeeu;
  }

  // DEP_INOUT is role-complete, but still carries a dependency barrier at
  // the upstream admission boundary.
  launch(dut, vrf, 0xf, 1, 2, 3, 0x41, true, 3);
  run_to_completion(dut, vrf);
  expect(!dut.cpl_illegal_o && !dut.cpl_rejected_o,
         "reverse", "completion status");
  Bytes expected_reverse{};
  for (unsigned lane = 0; lane < source.size(); ++lane)
    expected_reverse[lane] = source[15 - lane];
  expect(unpack_rows(vrf.rows, 3) == expected_reverse,
         "reverse", "data");
  expect(vrf.reads == 8 && vrf.writes == 4,
         "reverse", "VRF transaction counts");

  // Completion identity and payload must remain stable under backpressure.
  const uint8_t held_tag = dut.cpl_tag_o;
  const uint16_t held_invalid = dut.cpl_invalid_element_mask_o;
  for (unsigned stall = 0; stall < 3; ++stall) {
    vrf.step(dut);
    expect(dut.cpl_valid_o && dut.cpl_tag_o == held_tag &&
               dut.cpl_invalid_element_mask_o == held_invalid,
           "completion stall", "stable");
  }
  consume(dut, vrf);

  // LOCAL (00) is the same complete, self-contained gather without a
  // cross-slot dependency marker.
  for (unsigned group = 0; group < kGroups; ++group)
    vrf.rows[group][14] = 0xccccccccu;
  launch(dut, vrf, 0xf, 1, 2, 14, 0x45);
  run_to_completion(dut, vrf);
  expect(!dut.cpl_illegal_o && !dut.cpl_rejected_o,
         "local route", "completion status");
  expect(unpack_rows(vrf.rows, 14) == expected_reverse,
         "local route", "data");
  consume(dut, vrf);

  // Only groups 0 and 2 exist in this route domain.  Inactive destinations
  // preserve vd; active selections of missing groups or OOB bytes also leave
  // their corresponding destination bytes untouched.
  Bytes partial_index{};
  partial_index.fill(0);
  partial_index[0] = 0;
  partial_index[1] = 4;
  partial_index[2] = 8;
  partial_index[3] = 16;
  partial_index[8] = 11;
  partial_index[9] = 12;
  partial_index[10] = 2;
  partial_index[11] = 255;
  for (unsigned group = 0; group < kGroups; ++group) {
    vrf.rows[group][4] = pack_group(partial_index, group);
    vrf.rows[group][5] = 0xa5a5a5a5u;
  }
  const uint64_t reads_before_partial = vrf.reads;
  const uint64_t writes_before_partial = vrf.writes;
  launch(dut, vrf, 0x5, 1, 4, 5, 0x52);
  run_to_completion(dut, vrf);
  const Bytes partial_result = unpack_rows(vrf.rows, 5);
  expect(partial_result[0] == source[0] && partial_result[1] == 0xa5 &&
             partial_result[2] == source[8] && partial_result[3] == 0xa5,
         "partial", "group zero values");
  expect(partial_result[8] == source[11] && partial_result[9] == 0xa5 &&
             partial_result[10] == source[2] && partial_result[11] == 0xa5,
         "partial", "group two values");
  for (unsigned lane : {4u, 5u, 6u, 7u, 12u, 13u, 14u, 15u})
    expect(partial_result[lane] == 0xa5, "partial", "inactive preserved");
  expect(dut.cpl_invalid_element_mask_o == 0x0a0au,
         "partial", "invalid element mask");
  expect(vrf.reads - reads_before_partial == 4 &&
             vrf.writes - writes_before_partial == 2,
         "partial", "masked transaction counts");
  consume(dut, vrf);

  // One active destination group may mix valid and invalid selections.  The
  // commit is byte-granular: valid lanes update while invalid lanes preserve
  // the old vd bytes in the very same 32-bit VRF row.
  Bytes mixed_index{};
  mixed_index.fill(0);
  mixed_index[0] = 3;    // present source group 0
  mixed_index[1] = 4;    // missing source group 1
  mixed_index[2] = 10;   // missing source group 2
  mixed_index[3] = 200;  // OOB
  for (unsigned group = 0; group < kGroups; ++group)
    vrf.rows[group][9] = pack_group(mixed_index, group);
  vrf.rows[0][13] = 0x44332211u;
  const uint64_t writes_before_mixed = vrf.writes;
  launch(dut, vrf, 0x1, 1, 9, 13, 0x5d);
  run_to_completion(dut, vrf);
  expect(vrf.rows[0][13] == 0x44332223u,
         "mixed validity", "byte-granular preserved destination");
  expect(dut.cpl_invalid_element_mask_o == 0x000eu,
         "mixed validity", "invalid element mask");
  expect(vrf.writes - writes_before_mixed == 1,
         "mixed validity", "one partial group write");
  consume(dut, vrf);

  // An active group whose four selections all miss still completes through a
  // legal zero-mask VRF write transaction.  The transaction keeps completion
  // sequencing simple while changing no destination byte.
  Bytes all_invalid_index{};
  all_invalid_index.fill(255);
  all_invalid_index[8] = 0;    // inactive source group 0
  all_invalid_index[9] = 4;    // inactive source group 1
  all_invalid_index[10] = 12;  // inactive source group 3
  all_invalid_index[11] = 200;  // OOB
  for (unsigned group = 0; group < kGroups; ++group)
    vrf.rows[group][14] = pack_group(all_invalid_index, group);
  vrf.rows[2][15] = 0x78563412u;
  const uint64_t writes_before_all_invalid = vrf.writes;
  launch(dut, vrf, 0x4, 1, 14, 15, 0x5e);
  run_to_completion(dut, vrf);
  expect(vrf.rows[2][15] == 0x78563412u,
         "all invalid", "destination unchanged");
  expect(dut.cpl_invalid_element_mask_o == 0x0f00u,
         "all invalid", "invalid element mask");
  expect(vrf.writes - writes_before_all_invalid == 1,
         "all invalid", "zero-mask group write completes");
  consume(dut, vrf);

  // No-write lanes also preserve the pre-route value when vd aliases vs.
  // Valid lanes must still select from the complete source snapshot.
  Bytes mixed_alias_index{};
  mixed_alias_index.fill(0);
  mixed_alias_index[0] = 3;
  mixed_alias_index[1] = 4;
  mixed_alias_index[2] = 200;
  mixed_alias_index[3] = 0;
  for (unsigned group = 0; group < kGroups; ++group)
    vrf.rows[group][9] = pack_group(mixed_alias_index, group);
  vrf.rows[0][14] = 0x88776655u;
  launch(dut, vrf, 0x1, 14, 9, 14, 0x5f);
  run_to_completion(dut, vrf);
  expect(vrf.rows[0][14] == 0x55776688u,
         "mixed alias", "valid snapshot and invalid preservation");
  expect(dut.cpl_invalid_element_mask_o == 0x0006u,
         "mixed alias", "invalid element mask");
  consume(dut, vrf);

  // All reads precede all writes, so destination/source aliasing is defined.
  Bytes rotate{};
  for (unsigned lane = 0; lane < rotate.size(); ++lane)
    rotate[lane] = static_cast<uint8_t>((lane + 1) & 15u);
  for (unsigned group = 0; group < kGroups; ++group)
    vrf.rows[group][6] = pack_group(rotate, group);
  launch(dut, vrf, 0xf, 1, 6, 1, 0x63);
  run_to_completion(dut, vrf);
  Bytes expected_alias{};
  for (unsigned lane = 0; lane < source.size(); ++lane)
    expected_alias[lane] = source[(lane + 1) & 15u];
  expect(unpack_rows(vrf.rows, 1) == expected_alias,
         "alias", "snapshot before commit");
  consume(dut, vrf);

  // The index row may also alias vd. Exercise both legal response orders while
  // proving that every index byte is captured before the first destination
  // write can destroy the distributed index vector.
  Bytes index_alias_source{};
  Bytes index_alias_map{};
  Bytes expected_index_alias{};
  for (unsigned lane = 0; lane < index_alias_source.size(); ++lane) {
    index_alias_source[lane] = static_cast<uint8_t>(0x60 + lane);
    index_alias_map[lane] = static_cast<uint8_t>((5 * lane + 3) & 15u);
  }
  for (unsigned lane = 0; lane < expected_index_alias.size(); ++lane) {
    expected_index_alias[lane] =
        index_alias_source[index_alias_map[lane]];
  }
  for (unsigned group = 0; group < kGroups; ++group) {
    vrf.rows[group][7] = pack_group(index_alias_source, group);
    vrf.rows[group][8] = pack_group(index_alias_map, group);
  }

  const uint64_t reads_before_index_alias = vrf.reads;
  const uint64_t writes_before_index_alias = vrf.writes;
  launch(dut, vrf, 0xf, 7, 8, 8, 0x69);

  // First child read: data response arrives, then completion is held off.
  vrf.block_read_cpl = true;
  vrf.step(dut);
  expect(vrf.read_cpl_pending && vrf.read_rsp_pending,
         "split read rsp-first", "request captured");
  vrf.step(dut);
  expect(vrf.read_cpl_pending && !vrf.read_rsp_pending &&
             !dut.vrf_read_rsp_ready_o,
         "split read rsp-first", "response retained once");
  for (unsigned stall = 0; stall < 2; ++stall) vrf.step(dut);
  expect(vrf.writes == writes_before_index_alias,
         "split read rsp-first", "no early destination write");
  vrf.block_read_cpl = false;
  vrf.step(dut);
  expect(!vrf.read_cpl_pending && !vrf.read_rsp_pending,
         "split read rsp-first", "completion releases request");

  // Second child read: completion arrives, then the data response is held off.
  vrf.block_read_rsp = true;
  vrf.step(dut);
  expect(vrf.read_cpl_pending && vrf.read_rsp_pending,
         "split read cpl-first", "request captured");
  vrf.step(dut);
  expect(!vrf.read_cpl_pending && vrf.read_rsp_pending &&
             !dut.vrf_read_cpl_ready_o,
         "split read cpl-first", "completion retained once");
  for (unsigned stall = 0; stall < 2; ++stall) vrf.step(dut);
  expect(vrf.writes == writes_before_index_alias,
         "split read cpl-first", "no early destination write");
  vrf.block_read_rsp = false;

  run_to_completion(dut, vrf);
  expect(!dut.cpl_illegal_o && !dut.cpl_rejected_o &&
             dut.cpl_invalid_element_mask_o == 0,
         "index alias", "completion status");
  expect(unpack_rows(vrf.rows, 8) == expected_index_alias,
         "index alias", "complete index snapshot before overwrite");
  expect(vrf.reads - reads_before_index_alias == 8 &&
             vrf.writes - writes_before_index_alias == 4,
         "index alias", "VRF transaction counts");
  consume(dut, vrf);

  const uint64_t reads_before_empty = vrf.reads;
  const uint64_t writes_before_empty = vrf.writes;
  launch(dut, vrf, 0x0, 1, 2, 3, 0x74);
  run_to_completion(dut, vrf);
  expect(dut.cpl_rejected_o && dut.cpl_empty_mask_o && !dut.cpl_illegal_o,
         "empty", "ordered rejection");
  expect(vrf.reads == reads_before_empty && vrf.writes == writes_before_empty,
         "empty", "no VRF traffic");
  consume(dut, vrf);

  // A write-side failure is reported for the exact group, but it cannot roll
  // back earlier commits. The engine continues with later groups, so the
  // resulting architectural state is explicitly partial rather than atomic.
  Bytes write_error_source{};
  Bytes identity_index{};
  for (unsigned lane = 0; lane < write_error_source.size(); ++lane) {
    write_error_source[lane] = static_cast<uint8_t>(0x90 + lane);
    identity_index[lane] = static_cast<uint8_t>(lane);
  }
  for (unsigned group = 0; group < kGroups; ++group) {
    vrf.rows[group][10] = pack_group(write_error_source, group);
    vrf.rows[group][11] = pack_group(identity_index, group);
    vrf.rows[group][12] = 0x5a5a5a5au;
  }
  const uint64_t writes_before_write_error = vrf.writes;
  vrf.fail_write_group = 1;
  launch(dut, vrf, 0xf, 10, 11, 12, 0x7b);
  run_to_completion(dut, vrf);
  expect(dut.cpl_illegal_o && !dut.cpl_rejected_o &&
             dut.cpl_illegal_group_mask_o == 0x2,
         "write error", "exact failed group status");
  const Bytes write_error_result = unpack_rows(vrf.rows, 12);
  for (unsigned lane = 0; lane < write_error_result.size(); ++lane) {
    const uint8_t expected = lane / kLanes == 1
                                 ? uint8_t{0x5a}
                                 : write_error_source[lane];
    expect(write_error_result[lane] == expected,
           "write error", "partial commit data");
  }
  expect(vrf.writes - writes_before_write_error == 4 &&
             vrf.fail_write_group == -1 && !dut.protocol_error_o,
         "write error", "continued commit without protocol fault");
  consume(dut, vrf);

  // A snapshot error aborts before any destination write.
  const auto before_error = vrf.rows;
  const uint64_t writes_before_error = vrf.writes;
  vrf.fail_next_read = true;
  launch(dut, vrf, 0xf, 1, 2, 3, 0x85);
  run_to_completion(dut, vrf);
  expect(dut.cpl_illegal_o && dut.cpl_illegal_group_mask_o != 0,
         "read error", "completion status");
  expect(vrf.writes == writes_before_error && vrf.rows == before_error,
         "read error", "atomic abort");
  consume(dut, vrf);

  dut.final();
  std::cout << "PASS: cluster register-route engine " << checks
            << " checks\n";
  return 0;
}
