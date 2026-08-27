#include "Vsimd_cluster_issue_frontend.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kQueues = 2;
constexpr unsigned kSlots = 2;
constexpr unsigned kDepth = 3;
constexpr unsigned kFieldWidth = 8;
constexpr unsigned kCountWidth = 2;

struct Entry {
  uint8_t tag;
  uint8_t payload;
  uint8_t resolved;
  uint8_t sched_meta;
  uint8_t group_mask;
};

using Model = std::array<std::deque<Entry>, kQueues>;

struct Fires {
  bool push;
  uint8_t pop_mask;
  uint8_t accept_mask;
  uint8_t reject_mask;
};

struct LockedSnapshot {
  bool valid = false;
  unsigned queue = 0;
  Entry entry{};
};

uint64_t checks = 0;
std::array<LockedSnapshot, kSlots> locked_snapshots;

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

uint32_t field(uint32_t packed, unsigned index, unsigned width) {
  return (packed >> (index * width)) & ((1u << width) - 1u);
}

uint32_t next_random(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

unsigned popcount(uint32_t value) {
  unsigned count = 0;
  for (; value != 0; value >>= 1) count += value & 1u;
  return count;
}

void tick(Vsimd_cluster_issue_frontend& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_enqueue(Vsimd_cluster_issue_frontend& dut) {
  dut.enq_valid_i = 0;
  dut.enq_queue_i = 0;
  dut.enq_tag_i = 0;
  dut.enq_payload_i = 0;
  dut.enq_resolved_i = 0;
  dut.enq_sched_meta_i = 0;
  dut.enq_group_mask_i = 0;
}

void drive_enqueue(Vsimd_cluster_issue_frontend& dut, unsigned queue,
                   const Entry& entry) {
  dut.enq_valid_i = 1;
  dut.enq_queue_i = queue;
  dut.enq_tag_i = entry.tag;
  dut.enq_payload_i = entry.payload;
  dut.enq_resolved_i = entry.resolved;
  dut.enq_sched_meta_i = entry.sched_meta;
  dut.enq_group_mask_i = entry.group_mask;
}

void clear_locked_snapshots() {
  for (auto& snapshot : locked_snapshots) snapshot = {};
}

void check_state(Vsimd_cluster_issue_frontend& dut, const Model& model) {
  dut.eval();

  uint32_t expected_head_valid = 0;
  uint32_t expected_full = 0;
  uint32_t expected_occupancy = 0;
  for (unsigned queue = 0; queue < kQueues; ++queue) {
    expected_head_valid |= uint32_t(!model[queue].empty()) << queue;
    expected_full |= uint32_t(model[queue].size() == kDepth) << queue;
    expected_occupancy |= uint32_t(model[queue].size())
                          << (queue * kCountWidth);
  }
  expect_eq("queue head valid", expected_head_valid,
            dut.queue_head_valid_o);
  expect_eq("queue full", expected_full, dut.queue_full_o);
  expect_eq("queue occupancy", expected_occupancy,
            dut.queue_occupancy_o);

  uint32_t claimed = 0;
  uint32_t terminal_pop = 0;
  uint32_t expected_group_valid = 0;
  uint32_t expected_group_slot = 0;
  const uint32_t terminal = dut.slot_accept_o | dut.slot_reject_o;

  for (unsigned slot = 0; slot < kSlots; ++slot) {
    const bool valid = (dut.slot_valid_o >> slot) & 1u;
    const bool locked = (dut.slot_locked_o >> slot) & 1u;
    expect_eq("locked implies valid", 0, locked && !valid);

    if (!valid) {
      locked_snapshots[slot] = {};
      continue;
    }

    const unsigned queue = field(dut.slot_queue_o, slot, 1);
    expect_eq("slot queue in range", 1, queue < kQueues);
    expect_eq("queue claimed once", 0, (claimed >> queue) & 1u);
    claimed |= 1u << queue;
    expect_eq("presented queue nonempty", 1, !model[queue].empty());
    const Entry& expected = model[queue].front();
    expect_eq("slot tag", expected.tag,
              field(dut.slot_tag_o, slot, kFieldWidth));
    expect_eq("slot payload", expected.payload,
              field(dut.slot_payload_o, slot, kFieldWidth));
    expect_eq("slot resolved", expected.resolved,
              field(dut.slot_resolved_o, slot, kFieldWidth));
    expect_eq("slot sched meta", expected.sched_meta,
              field(dut.slot_sched_meta_o, slot, kFieldWidth));
    expect_eq("slot group mask", expected.group_mask,
              field(dut.slot_group_mask_o, slot, kGroups));

    if (locked) {
      if (locked_snapshots[slot].valid) {
        const LockedSnapshot& snapshot = locked_snapshots[slot];
        expect_eq("locked queue stable", snapshot.queue, queue);
        expect_eq("locked tag stable", snapshot.entry.tag, expected.tag);
        expect_eq("locked payload stable", snapshot.entry.payload,
                  expected.payload);
        expect_eq("locked resolved stable", snapshot.entry.resolved,
                  expected.resolved);
        expect_eq("locked meta stable", snapshot.entry.sched_meta,
                  expected.sched_meta);
        expect_eq("locked group mask stable", snapshot.entry.group_mask,
                  expected.group_mask);
      } else {
        locked_snapshots[slot] = {true, queue, expected};
      }
    } else {
      locked_snapshots[slot] = {};
    }

    const bool accepted = (dut.slot_accept_o >> slot) & 1u;
    const bool rejected = (dut.slot_reject_o >> slot) & 1u;
    expect_eq("accept reject exclusive", 0, accepted && rejected);

    bool owners_match = expected.group_mask != 0;
    bool groups_ready = true;
    for (unsigned group = 0; group < kGroups; ++group) {
      if ((expected.group_mask >> group) & 1u) {
        const unsigned owner = (dut.group_owner_i >> group) & 1u;
        owners_match &= ((dut.group_owner_valid_i >> group) & 1u) &&
                        owner == queue;
        groups_ready &= (dut.group_ready_i >> group) & 1u;
      }
    }

    if (accepted) {
      expect_eq("accepted ownership", 1, owners_match);
      expect_eq("accepted readiness", 1, groups_ready);
      expect_eq("accepted shared-resource credit", 1,
                (dut.slot_resource_ready_i >> slot) & 1u);
      for (unsigned group = 0; group < kGroups; ++group) {
        if ((expected.group_mask >> group) & 1u) {
          expected_group_valid |= 1u << group;
          expected_group_slot |= slot << group;
        }
      }
    }
    if (rejected) {
      expect_eq("reject has credit", 1,
                (dut.reject_ready_i >> slot) & 1u);
      expect_eq("reject is malformed", 1, !owners_match);
    }
    if (((terminal >> slot) & 1u) != 0) {
      expect_eq("one terminal per queue", 0,
                (terminal_pop >> queue) & 1u);
      terminal_pop |= 1u << queue;
    }
  }

  expect_eq("claimed queues", claimed, dut.queue_claimed_o);
  expect_eq("terminal queue pop", terminal_pop, dut.queue_pop_o);
  expect_eq("group valid from accepted masks", expected_group_valid,
            dut.group_issue_valid_o);
  expect_eq("group slot from accepted masks", expected_group_slot,
            dut.group_issue_slot_o);

  const unsigned enq_queue = dut.enq_queue_i;
  const bool expected_enq_ready = dut.rst_ni && enq_queue < kQueues &&
      (model[enq_queue].size() < kDepth ||
       ((terminal_pop >> enq_queue) & 1u));
  expect_eq("enqueue ready", expected_enq_ready, dut.enq_ready_o);
  expect_eq("legal queue has no admission error", 0,
            dut.enq_queue_error_o);
}

Fires update_model_from_inputs(Vsimd_cluster_issue_frontend& dut,
                               Model& model) {
  const uint8_t accept = dut.slot_accept_o;
  const uint8_t reject = dut.slot_reject_o;
  const uint8_t terminal = accept | reject;
  uint8_t pop_mask = 0;

  for (unsigned slot = 0; slot < kSlots; ++slot) {
    if ((terminal >> slot) & 1u) {
      const unsigned queue = field(dut.slot_queue_o, slot, 1);
      pop_mask |= 1u << queue;
      model[queue].pop_front();
    }
  }

  const bool push = dut.enq_valid_i && dut.enq_ready_o;
  if (push) {
    model[dut.enq_queue_i].push_back(
        {static_cast<uint8_t>(dut.enq_tag_i),
         static_cast<uint8_t>(dut.enq_payload_i),
         static_cast<uint8_t>(dut.enq_resolved_i),
         static_cast<uint8_t>(dut.enq_sched_meta_i),
         static_cast<uint8_t>(dut.enq_group_mask_i)});
  }
  return {push, pop_mask, accept, reject};
}

Fires step(Vsimd_cluster_issue_frontend& dut, Model& model) {
  check_state(dut, model);
  const Fires fires = update_model_from_inputs(dut, model);
  tick(dut);
  check_state(dut, model);
  return fires;
}

void drain(Vsimd_cluster_issue_frontend& dut, Model& model) {
  clear_enqueue(dut);
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0;
  dut.group_ready_i = 0xf;
  dut.slot_resource_ready_i = 0x3;
  dut.reject_ready_i = 0x3;
  while (!model[0].empty() || !model[1].empty()) step(dut, model);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_cluster_issue_frontend dut;
  Model model;
  clear_enqueue(dut);
  dut.group_owner_valid_i = 0;
  dut.group_owner_i = 0;
  dut.group_ready_i = 0;
  dut.slot_resource_ready_i = 0;
  dut.reject_ready_i = 0;

  dut.rst_ni = 0;
  tick(dut);
  clear_locked_snapshots();
  dut.rst_ni = 1;
  check_state(dut, model);

  // Fill both queues while execution is blocked, then release two disjoint
  // group cohorts together. Groups 0/1 belong to queue 0; 2/3 to queue 1.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0xc;
  dut.group_ready_i = 0;
  dut.slot_resource_ready_i = 0x3;
  dut.reject_ready_i = 0x3;
  drive_enqueue(dut, 0, {0x10, 0x20, 0x30, 0x40, 0x3});
  step(dut, model);
  drive_enqueue(dut, 1, {0x11, 0x21, 0x31, 0x41, 0xc});
  step(dut, model);
  clear_enqueue(dut);
  dut.group_ready_i = 0xf;
  const Fires dual = step(dut, model);
  expect_eq("dual issue accepted", 0x3, dual.accept_mask);
  expect_eq("dual issue popped both queues", 0x3, dual.pop_mask);

  // A slot-specific shared resource (for example a completion-tracker entry)
  // must be granted in the same cycle as queue pop and multicast. Denial locks
  // the stable slot without producing a partial group issue.
  dut.group_ready_i = 0xf;
  dut.slot_resource_ready_i = 0;
  drive_enqueue(dut, 0, {0x12, 0x22, 0x32, 0x42, 0x3});
  step(dut, model);
  clear_enqueue(dut);
  step(dut, model);
  expect_eq("resource-blocked request locks", 1,
            dut.slot_locked_o != 0);
  expect_eq("resource denial produces no group issue", 0,
            dut.group_issue_valid_o);
  unsigned resource_slot = 0;
  while (((dut.slot_locked_o >> resource_slot) & 1u) == 0) ++resource_slot;
  dut.slot_resource_ready_i = 1u << resource_slot;
  const Fires resource_released = step(dut, model);
  expect_eq("resource release accepts once", 1,
            popcount(resource_released.accept_mask));
  expect_eq("resource release pops queue", 0x1,
            resource_released.pop_mask);
  dut.slot_resource_ready_i = 0x3;

  // A partially ready multicast locks its live head and remains bit-stable
  // until every target group can accept it atomically.
  dut.group_ready_i = 0;
  drive_enqueue(dut, 0, {0x22, 0x32, 0x42, 0x52, 0x3});
  step(dut, model);
  clear_enqueue(dut);
  dut.group_ready_i = 0x1;
  step(dut, model);
  expect_eq("backpressured request locked", 1,
            dut.slot_locked_o != 0);
  for (unsigned hold = 0; hold < 4; ++hold) step(dut, model);
  dut.group_ready_i = 0x3;
  const Fires released = step(dut, model);
  expect_eq("locked multicast eventually accepted", 1,
            released.accept_mask != 0);

  // An ownership error may not dequeue until the error sink grants credit.
  dut.group_ready_i = 0xf;
  dut.slot_resource_ready_i = 0;
  dut.reject_ready_i = 0;
  drive_enqueue(dut, 1, {0x33, 0x43, 0x53, 0x63, 0x1});
  step(dut, model);
  clear_enqueue(dut);
  step(dut, model);
  expect_eq("error waits in locked slot", 1, dut.slot_locked_o != 0);
  for (unsigned hold = 0; hold < 3; ++hold) step(dut, model);
  dut.reject_ready_i = 0x3;
  const Fires rejected = step(dut, model);
  expect_eq("credited error rejected", 1, rejected.reject_mask != 0);
  expect_eq("credited error popped", 0x2, rejected.pop_mask);
  dut.slot_resource_ready_i = 0x3;

  // A malformed locked request owns only its queue entry. It must not reserve
  // the named group and block that group's rightful owner while error credit
  // is unavailable.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0x1;  // Group 0 belongs to queue 1.
  dut.group_ready_i = 0x1;
  dut.reject_ready_i = 0;
  drive_enqueue(dut, 0, {0x34, 0x44, 0x54, 0x64, 0x1});
  step(dut, model);
  clear_enqueue(dut);
  step(dut, model);
  expect_eq("malformed request locked without credit", 1,
            dut.slot_locked_o != 0);
  drive_enqueue(dut, 1, {0x35, 0x45, 0x55, 0x65, 0x1});
  step(dut, model);
  clear_enqueue(dut);
  const Fires rightful = step(dut, model);
  expect_eq("rightful owner bypasses malformed lock", 1,
            rightful.accept_mask != 0);
  expect_eq("rightful owner queue popped", 0x2, rightful.pop_mask);
  expect_eq("malformed queue remains pending", 1, !model[0].empty());
  dut.reject_ready_i = 0x3;
  const Fires malformed_retire = step(dut, model);
  expect_eq("malformed lock retires only with credit", 1,
            malformed_retire.reject_mask != 0);
  expect_eq("malformed queue finally popped", 0x1,
            malformed_retire.pop_mask);

  // Fill queue 0 completely behind a locked head. A fourth enqueue is accepted
  // in the exact cycle that the old head fires, preserving full occupancy.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0xc;
  dut.reject_ready_i = 0x3;
  dut.group_ready_i = 0;
  drive_enqueue(dut, 0, {0x40, 0x50, 0x60, 0x70, 0x3});
  step(dut, model);
  drive_enqueue(dut, 0, {0x41, 0x51, 0x61, 0x71, 0x3});
  step(dut, model);
  drive_enqueue(dut, 0, {0x42, 0x52, 0x62, 0x72, 0x3});
  step(dut, model);
  drive_enqueue(dut, 0, {0x43, 0x53, 0x63, 0x73, 0x3});
  dut.eval();
  expect_eq("full locked queue blocks enqueue", 0, dut.enq_ready_o);
  dut.group_ready_i = 0x3;
  dut.eval();
  expect_eq("terminal pop enables full replacement", 1, dut.enq_ready_o);
  const Fires replacement = step(dut, model);
  expect_eq("full replacement pushed", 1, replacement.push);
  expect_eq("full replacement popped", 0x1, replacement.pop_mask);
  clear_enqueue(dut);
  drain(dut, model);

  // Mid-flight asynchronous reset clears FIFO ownership and locked shadows,
  // even with a producer still presenting another entry.
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0xc;
  dut.group_ready_i = 0;
  drive_enqueue(dut, 0, {0x70, 0x71, 0x72, 0x73, 0x1});
  step(dut, model);
  drive_enqueue(dut, 0, {0x74, 0x75, 0x76, 0x77, 0x1});
  step(dut, model);
  drive_enqueue(dut, 1, {0x78, 0x79, 0x7a, 0x7b, 0x4});
  step(dut, model);
  drive_enqueue(dut, 0, {0x7c, 0x7d, 0x7e, 0x7f, 0x1});
  dut.rst_ni = 0;
  dut.eval();
  model = {};
  clear_locked_snapshots();
  check_state(dut, model);
  expect_eq("reset clears slot valid", 0, dut.slot_valid_o);
  expect_eq("reset clears slot locks", 0, dut.slot_locked_o);
  expect_eq("reset clears queue claims", 0, dut.queue_claimed_o);
  expect_eq("reset produces no terminal", 0,
            dut.slot_accept_o | dut.slot_reject_o | dut.queue_pop_o);
  expect_eq("reset produces no group issue", 0, dut.group_issue_valid_o);
  tick(dut);
  clear_enqueue(dut);
  dut.rst_ni = 1;
  check_state(dut, model);
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0xc;
  dut.group_ready_i = 0x1;
  dut.reject_ready_i = 0x3;
  drive_enqueue(dut, 0, {0x80, 0x81, 0x82, 0x83, 0x1});
  step(dut, model);
  clear_enqueue(dut);
  const Fires after_reset = step(dut, model);
  expect_eq("post-reset request accepted once", 1,
            popcount(after_reset.accept_mask));
  expect_eq("post-reset request popped once", 0x1,
            after_reset.pop_mask);

  // Randomized ownership, readiness, error credit and admission. The oracle
  // checks FIFO order without reproducing RTL pointers or round-robin state.
  uint32_t rng = 0x4f29b31du;
  uint32_t sequence = 0;
  bool pending = false;
  unsigned pending_queue = 0;
  Entry pending_entry{};
  unsigned pushes = 0;
  unsigned accepts = 0;
  unsigned rejects = 0;
  unsigned dual_accepts = 0;
  unsigned locked_cycles = 0;
  unsigned full_replacements = 0;
  constexpr unsigned kRandomCycles = 100000;

  for (unsigned cycle = 0; cycle < kRandomCycles; ++cycle) {
    dut.group_owner_valid_i = next_random(rng) & 0xfu;
    dut.group_owner_i = next_random(rng) & 0xfu;
    dut.group_ready_i = next_random(rng) & 0xfu;
    dut.slot_resource_ready_i = next_random(rng) & 0x3u;
    dut.reject_ready_i = next_random(rng) & 0x3u;

    clear_enqueue(dut);
    if (!pending && (next_random(rng) & 3u) != 0) {
      pending = true;
      pending_queue = next_random(rng) & 1u;
      pending_entry = {
          static_cast<uint8_t>(sequence),
          static_cast<uint8_t>(sequence * 3u + 1u),
          static_cast<uint8_t>(sequence * 5u + 2u),
          static_cast<uint8_t>(sequence * 7u + 3u),
          static_cast<uint8_t>(next_random(rng) & 0xfu)};
      ++sequence;
    }
    if (pending) drive_enqueue(dut, pending_queue, pending_entry);

    dut.eval();
    const bool was_full = pending &&
                          model[pending_queue].size() == kDepth;
    const Fires fires = step(dut, model);
    if (fires.push) {
      ++pushes;
      if (was_full && ((fires.pop_mask >> pending_queue) & 1u)) {
        ++full_replacements;
      }
      pending = false;
    }
    accepts += popcount(fires.accept_mask);
    rejects += popcount(fires.reject_mask);
    if (popcount(fires.accept_mask) == 2) ++dual_accepts;
    if (dut.slot_locked_o != 0) ++locked_cycles;
  }

  pending = false;
  drain(dut, model);
  clear_enqueue(dut);
  check_state(dut, model);
  expect_eq("random covered pushes", 1, pushes != 0);
  expect_eq("random covered accepts", 1, accepts != 0);
  expect_eq("random covered rejects", 1, rejects != 0);
  expect_eq("random covered dual accepts", 1, dual_accepts != 0);
  expect_eq("random covered locked cycles", 1, locked_cycles != 0);
  expect_eq("random covered full replacement", 1,
            full_replacements != 0);

  dut.final();
  std::cout << "PASS: " << checks
            << " 4-group/2-queue frontend checks across live issue, locked "
               "shadow stability, shared-resource gating, malformed isolation, "
               "reset, reject credit, elastic replacement, and randomized "
               "scheduling\n";
  return 0;
}
