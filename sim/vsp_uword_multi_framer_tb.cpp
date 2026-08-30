#include "Vvsp_uword_multi_framer.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

constexpr int kBundleWords = 4;
constexpr int kAdmitSlots = 3;
uint64_t checks = 0;

[[noreturn]] void fail(const std::string& name, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << name << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& name, uint64_t expected, uint64_t actual) {
  ++checks;
  if (expected != actual) fail(name, expected, actual);
}

void eval_low(Vvsp_uword_multi_framer& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_uword_multi_framer& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_uword_multi_framer& dut) {
  dut.bundle_valid_i = 0;
  dut.bundle_word_count_i = 0;
  dut.bundle_base_pc_i = 0;
  dut.bundle_last_i = 0;
  for (int word = 0; word < kBundleWords; ++word)
    dut.bundle_words_i[word] = 0;
  dut.record_ready_i = 0;
  dut.terminal_clear_i = 0;
  dut.stream_abort_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_uword_multi_framer& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  expect_eq("reset idle", 1, dut.idle_o);
  expect_eq("reset records", 0, dut.record_valid_o);
  expect_eq("reset stop", 0, dut.stop_fetch_o);
  expect_eq("reset halted", 0, dut.halted_o);
  expect_eq("reset error", 0, dut.protocol_error_o);
}

void drive_bundle(Vvsp_uword_multi_framer& dut, uint32_t pc, uint8_t count,
                  bool last, const std::array<uint32_t, kBundleWords>& words) {
  dut.bundle_valid_i = 1;
  dut.bundle_base_pc_i = pc;
  dut.bundle_word_count_i = count;
  dut.bundle_last_i = last;
  for (int word = 0; word < kBundleWords; ++word)
    dut.bundle_words_i[word] = words[word];
}

void send_bundle(Vvsp_uword_multi_framer& dut, uint32_t pc, uint8_t count,
                 bool last,
                 const std::array<uint32_t, kBundleWords>& words) {
  drive_bundle(dut, pc, count, last, words);
  eval_low(dut);
  expect_eq("bundle ready", 1, dut.bundle_ready_o);
  tick(dut);
  dut.bundle_valid_i = 0;
  eval_low(dut);
}

uint32_t record_word(const Vvsp_uword_multi_framer& dut, int slot, int word) {
  return dut.record_words_o[slot * 4 + word];
}

uint32_t record_pc(const Vvsp_uword_multi_framer& dut, int slot) {
  return dut.record_start_pc_o[slot];
}

uint32_t packed_field(uint32_t value, int slot, int width) {
  return (value >> (slot * width)) & ((1U << width) - 1U);
}

void expect_slot(const Vvsp_uword_multi_framer& dut, int slot, uint32_t pc,
                 uint32_t header, uint32_t words, uint32_t present,
                 uint32_t action_class, bool truncated, bool terminal,
                 const std::string& name) {
  expect_eq(name + " valid", 1, (dut.record_valid_o >> slot) & 1U);
  expect_eq(name + " pc", pc, record_pc(dut, slot));
  expect_eq(name + " header", header, record_word(dut, slot, 0));
  expect_eq(name + " length", words,
            packed_field(dut.record_word_count_o, slot, 3));
  expect_eq(name + " present", present,
            packed_field(dut.record_present_word_count_o, slot, 3));
  expect_eq(name + " class", action_class,
            packed_field(dut.record_class_o, slot, 2));
  expect_eq(name + " truncated", truncated,
            (dut.record_truncated_o >> slot) & 1U);
  expect_eq(name + " terminal", terminal,
            (dut.record_terminal_o >> slot) & 1U);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_uword_multi_framer dut;

  // Four fetched words and three admission slots are independent.  A
  // non-prefix ready vector may accept only its oldest ready prefix.
  reset(dut);
  send_bundle(dut, 0x100, 4, false,
              {0x80000000U, 0xb0000011U, 0xc0000001U, 0xd0000000U});
  expect_eq("three-record admission prefix", 0x7, dut.record_valid_o);
  expect_slot(dut, 0, 0x100, 0x80000000U, 1, 1, 0, false, false,
              "slot0 EXEC");
  expect_slot(dut, 1, 0x104, 0xb0000011U, 1, 1, 1, false, false,
              "slot1 MEMORY");
  expect_slot(dut, 2, 0x108, 0xc0000001U, 1, 1, 2, false, false,
              "slot2 non-END CONTROL");
  expect_eq("ordinary CONTROL does not stop", 0, dut.stop_fetch_o);

  const uint32_t stalled_pc0 = record_pc(dut, 0);
  const uint32_t stalled_word0 = record_word(dut, 0, 0);
  tick(dut);
  expect_eq("full stall PC stable", stalled_pc0, record_pc(dut, 0));
  expect_eq("full stall payload stable", stalled_word0, record_word(dut, 0, 0));

  dut.record_ready_i = 0x6;
  eval_low(dut);
  expect_eq("ready cannot skip slot zero", 0, dut.record_accept_o);
  dut.record_ready_i = 0x5;
  eval_low(dut);
  expect_eq("accept stops at first not-ready slot", 0x1,
            dut.record_accept_o);
  tick(dut);
  dut.record_ready_i = 0;
  expect_slot(dut, 0, 0x104, 0xb0000011U, 1, 1, 1, false, false,
              "remaining oldest rebased");
  expect_slot(dut, 2, 0x10c, 0xd0000000U, 1, 1, 3, false, false,
              "fourth undefined record exposed");
  dut.record_ready_i = 0x7;
  tick(dut);
  dut.record_ready_i = 0;
  expect_eq("all four records drained", 0, dut.record_valid_o);

  // A four-word MEMORY record crosses the fetch boundary.  Its body may look
  // exactly like END without terminating the stream.
  reset(dut);
  send_bundle(dut, 0x200, 2, false,
              {0xbc000055U, 0x11111111U, 0, 0});
  expect_eq("split record held", 0, dut.record_valid_o);
  send_bundle(dut, 0x208, 4, true,
              {0xc0000000U, 0x22222222U, 0x80000000U, 0xd0000000U});
  expect_eq("split plus two records", 0x7, dut.record_valid_o);
  expect_slot(dut, 0, 0x200, 0xbc000055U, 4, 4, 1, false, false,
              "cross-bundle MEMORY");
  expect_eq("opaque END-looking body retained", 0xc0000000U,
            record_word(dut, 0, 2));
  expect_eq("opaque body does not stop", 0, dut.stop_fetch_o);
  expect_slot(dut, 1, 0x210, 0x80000000U, 1, 1, 0, false, false,
              "post-memory EXEC");
  dut.record_ready_i = 0x7;
  tick(dut);
  dut.record_ready_i = 0;
  expect_eq("EOF completion pulse", 1, dut.record_delivery_done_o);
  expect_eq("EOF drain idle", 1, dut.idle_o);
  tick(dut);
  expect_eq("EOF completion clears", 0, dut.record_delivery_done_o);

  // END beyond the three admission slots stops fetch immediately, then moves
  // into slot zero after the older prefix transfers.
  reset(dut);
  send_bundle(dut, 0x300, 4, false,
              {0x80000000U, 0x80000001U, 0xd0000000U, 0xc0000000U});
  expect_eq("END beyond admission stops fetch", 1, dut.stop_fetch_o);
  expect_eq("END beyond admission PC", 0x30c, dut.terminal_pc_o);
  expect_eq("only older prefix visible", 0x7, dut.record_valid_o);
  expect_eq("terminal not yet admitted", 0, dut.record_terminal_o);
  expect_eq("stopped framer rejects bundle", 0, dut.bundle_ready_o);
  dut.record_ready_i = 0x7;
  tick(dut);
  dut.record_ready_i = 0;
  expect_slot(dut, 0, 0x30c, 0xc0000000U, 1, 1, 2, false, true,
              "deferred END");
  dut.record_ready_i = 0x1;
  eval_low(dut);
  expect_eq("terminal handshake metadata", 1, dut.terminal_accept_o);
  tick(dut);
  dut.record_ready_i = 0;
  expect_eq("END leaves no record", 0, dut.record_valid_o);
  expect_eq("END enters halted state", 1, dut.halted_o);
  expect_eq("END stop remains sticky", 1, dut.stop_fetch_o);
  dut.terminal_clear_i = 1;
  tick(dut);
  dut.terminal_clear_i = 0;
  expect_eq("terminal clear releases fetch", 0, dut.stop_fetch_o);
  expect_eq("terminal clear returns idle", 1, dut.idle_o);

  // Records younger than END in the same fetch response are never exposed.
  reset(dut);
  send_bundle(dut, 0x380, 4, false,
              {0x80000000U, 0xc0000000U, 0xd0000000U, 0xb0000000U});
  expect_eq("END cuts visible prefix", 0x3, dut.record_valid_o);
  expect_eq("END is second", 0x2, dut.record_terminal_o);
  expect_eq("cutoff terminal PC", 0x384, dut.terminal_pc_o);
  dut.record_ready_i = 0x1;
  tick(dut);
  dut.record_ready_i = 0;
  expect_eq("only END remains after cutoff", 0x1, dut.record_valid_o);
  expect_eq("younger records stayed discarded", 0xc0000000U,
            record_word(dut, 0, 0));

  // A final incomplete record is a transport truncation, not semantic END.
  reset(dut);
  send_bundle(dut, 0x400, 2, true,
              {0xbc000077U, 0x12345678U, 0, 0});
  expect_slot(dut, 0, 0x400, 0xbc000077U, 4, 2, 1, true, false,
              "EOF-truncated MEMORY");
  expect_eq("truncation does not stop fetch semantically", 0,
            dut.stop_fetch_o);
  dut.record_ready_i = 0x1;
  tick(dut);
  dut.record_ready_i = 0;
  expect_eq("truncated final delivery", 1, dut.record_delivery_done_o);

  // Prefix dequeue and the next fetch response may transfer together.  This
  // is the common steady-state path when four fetched words frame no more
  // than three consumed records on average.
  reset(dut);
  send_bundle(dut, 0x500, 4, false,
              {0x80000000U, 0x80000001U, 0x80000002U, 0x80000003U});
  drive_bundle(dut, 0x510, 4, true,
               {0xd0000000U, 0xd0000001U, 0xd0000002U, 0xd0000003U});
  dut.record_ready_i = 0x7;
  eval_low(dut);
  expect_eq("simultaneous prefix dequeue", 0x7, dut.record_accept_o);
  expect_eq("simultaneous next bundle intake", 1, dut.bundle_ready_o);
  tick(dut);
  dut.bundle_valid_i = 0;
  dut.record_ready_i = 0;
  expect_slot(dut, 0, 0x50c, 0x80000003U, 1, 1, 0, false, false,
              "old fourth record preserved");
  expect_slot(dut, 1, 0x510, 0xd0000000U, 1, 1, 3, false, false,
              "new first undefined record appended");

  // A transport fault may arrive while a record tail waits for another
  // bundle. Abort discards that state without claiming successful EOF and
  // clears continuity so a later stream may start at an unrelated PC.
  reset(dut);
  send_bundle(dut, 0x600, 2, false,
              {0xbc000099U, 0x11111111U, 0, 0});
  expect_eq("abort setup holds incomplete tail", 0, dut.record_valid_o);
  expect_eq("abort setup is not idle", 0, dut.idle_o);
  dut.stream_abort_i = 1;
  eval_low(dut);
  expect_eq("abort blocks concurrent bundle", 0, dut.bundle_ready_o);
  expect_eq("abort transfers no record", 0, dut.record_accept_o);
  tick(dut);
  dut.stream_abort_i = 0;
  expect_eq("abort clears incomplete tail", 0, dut.record_valid_o);
  expect_eq("abort returns nonterminal stream idle", 1, dut.idle_o);
  expect_eq("abort is not successful EOF", 0, dut.record_delivery_done_o);
  send_bundle(dut, 0x900, 1, true, {0x80000000U, 0, 0, 0});
  expect_slot(dut, 0, 0x900, 0x80000000U, 1, 1, 0, false, false,
              "post-abort unrelated stream");

  // A non-contiguous bundle cannot become the opaque continuation of an
  // incomplete record.  A discontinuity on the declared final bundle drops
  // both pieces, returns the transport to idle, and leaves a sticky error for
  // explicit software/controller acknowledgement.
  reset(dut);
  send_bundle(dut, 0xb00, 2, false,
              {0xbc0000aaU, 0x11111111U, 0, 0});
  expect_eq("discontinuity setup holds incomplete tail", 0,
            dut.record_valid_o);
  expect_eq("discontinuity setup not idle", 0, dut.idle_o);
  send_bundle(dut, 0xb0c, 1, true,
              {0xc0000000U, 0, 0, 0});
  expect_eq("discontinuity emits no record", 0, dut.record_valid_o);
  expect_eq("discontinuity sets sticky protocol error", 1,
            dut.protocol_error_o);
  expect_eq("final discontinuity returns idle", 1, dut.idle_o);
  expect_eq("discontinuity is not successful delivery", 0,
            dut.record_delivery_done_o);
  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  expect_eq("idle clear acknowledges discontinuity", 0,
            dut.protocol_error_o);

  // Abort may discard the buffered END record, but it cannot revoke an END
  // that framing has already recognized.
  reset(dut);
  send_bundle(dut, 0xa00, 1, false, {0xc0000000U, 0, 0, 0});
  expect_eq("END before abort stops fetch", 1, dut.stop_fetch_o);
  dut.stream_abort_i = 1;
  tick(dut);
  dut.stream_abort_i = 0;
  expect_eq("END abort drops buffered record", 0, dut.record_valid_o);
  expect_eq("END abort remains halted", 1, dut.halted_o);
  expect_eq("END abort preserves stop", 1, dut.stop_fetch_o);
  expect_eq("END abort preserves terminal PC", 0xa00, dut.terminal_pc_o);
  expect_eq("END abort is not EOF", 0, dut.record_delivery_done_o);

  dut.final();
  std::cout << "vsp_uword_multi_framer_tb: " << std::dec << checks
            << " multi-record, prefix, split and END checks passed\n";
  return 0;
}
