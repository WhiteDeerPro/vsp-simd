#include "Vsimd_issue_dispatch.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr unsigned kGroups = 8;
constexpr unsigned kSlots = 3;
constexpr unsigned kContexts = 3;
constexpr unsigned kContextWidth = 2;
constexpr unsigned kSlotWidth = 2;

struct Expected {
  uint32_t ready = 0;
  uint32_t accept = 0;
  uint32_t reject = 0;
  uint32_t group_valid = 0;
  uint32_t group_slot = 0;
  uint32_t empty = 0;
  uint32_t owner_mismatch = 0;
  uint32_t backpressured = 0;
  uint32_t conflict = 0;
};

uint32_t field(uint32_t packed, unsigned index, unsigned width) {
  return (packed >> (index * width)) & ((1u << width) - 1u);
}

Expected reference(uint32_t valid, uint32_t contexts, uint32_t masks,
                   uint32_t owner_valid, uint32_t owners,
                   uint32_t group_ready, uint32_t resource_ready,
                   uint32_t reject_ready) {
  Expected expected;
  uint32_t reserved = 0;

  for (unsigned slot = 0; slot < kSlots; ++slot) {
    const unsigned context = field(contexts, slot, kContextWidth);
    const uint32_t requested = field(masks, slot, kGroups);
    bool owners_match = context < kContexts;
    bool all_ready = true;

    for (unsigned group = 0; group < kGroups; ++group) {
      if ((requested >> group) & 1u) {
        const unsigned owner = field(owners, group, kContextWidth);
        owners_match &= ((owner_valid >> group) & 1u) &&
                        owner < kContexts && owner == context;
        all_ready &= (group_ready >> group) & 1u;
      }
    }

    const bool overlaps = (requested & reserved) != 0;
    const bool request_error = requested == 0 || !owners_match;
    const bool slot_resource_ready = (resource_ready >> slot) & 1u;
    const bool can_execute = !request_error && all_ready &&
                             slot_resource_ready && !overlaps;
    const bool slot_valid = (valid >> slot) & 1u;

    expected.ready |=
        uint32_t(request_error ? ((reject_ready >> slot) & 1u) : can_execute)
        << slot;
    expected.accept |= uint32_t(slot_valid && can_execute) << slot;
    expected.reject |= uint32_t(slot_valid && request_error &&
                                ((reject_ready >> slot) & 1u)) << slot;
    expected.empty |= uint32_t(slot_valid && requested == 0) << slot;
    expected.owner_mismatch |=
        uint32_t(slot_valid && requested != 0 && !owners_match) << slot;
    expected.backpressured |=
        uint32_t(slot_valid && requested != 0 && owners_match &&
                 (!all_ready || !slot_resource_ready))
        << slot;
    expected.conflict |=
        uint32_t(slot_valid && requested != 0 && owners_match && all_ready &&
                 slot_resource_ready && overlaps)
        << slot;

    if (slot_valid && can_execute) {
      reserved |= requested;
      for (unsigned group = 0; group < kGroups; ++group) {
        if ((requested >> group) & 1u) {
          expected.group_valid |= 1u << group;
          expected.group_slot |= slot << (group * kSlotWidth);
        }
      }
    }
  }
  return expected;
}

uint32_t next_random(uint32_t& state) {
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
}

[[noreturn]] void fail(unsigned test_case, const char* field_name,
                       uint32_t expected, uint32_t actual) {
  std::cerr << "FAIL case=" << test_case << ' ' << field_name
            << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_issue_dispatch dut;
  uint32_t random_state = 0x7a31d5e9u;
  constexpr unsigned kTests = 250000;

  for (unsigned test_case = 0; test_case < kTests; ++test_case) {
    const uint32_t valid = next_random(random_state) & 0x7u;
    const uint32_t contexts = next_random(random_state) & 0x3fu;
    const uint32_t masks = next_random(random_state) & 0x00ffffffu;
    const uint32_t owner_valid = next_random(random_state) & 0xffu;
    const uint32_t owners = next_random(random_state) & 0xffffu;
    const uint32_t group_ready = next_random(random_state) & 0xffu;
    const uint32_t resource_ready = next_random(random_state) & 0x7u;
    const uint32_t reject_ready = next_random(random_state) & 0x7u;

    dut.issue_valid_i = valid;
    dut.issue_context_i = contexts;
    dut.issue_group_mask_i = masks;
    dut.issue_resource_ready_i = resource_ready;
    dut.issue_reject_ready_i = reject_ready;
    dut.group_owner_valid_i = owner_valid;
    dut.group_owner_i = owners;
    dut.group_ready_i = group_ready;
    dut.eval();

    const Expected expected = reference(valid, contexts, masks, owner_valid,
                                        owners, group_ready, resource_ready,
                                        reject_ready);
    if (dut.issue_ready_o != expected.ready) {
      fail(test_case, "ready", expected.ready, dut.issue_ready_o);
    }
    if (dut.issue_accept_o != expected.accept) {
      fail(test_case, "accept", expected.accept, dut.issue_accept_o);
    }
    if (dut.issue_reject_o != expected.reject) {
      fail(test_case, "reject", expected.reject, dut.issue_reject_o);
    }
    if (dut.group_issue_valid_o != expected.group_valid) {
      fail(test_case, "group_valid", expected.group_valid,
           dut.group_issue_valid_o);
    }
    if (dut.group_issue_slot_o != expected.group_slot) {
      fail(test_case, "group_slot", expected.group_slot,
           dut.group_issue_slot_o);
    }
    if (dut.empty_mask_o != expected.empty) {
      fail(test_case, "empty", expected.empty, dut.empty_mask_o);
    }
    if (dut.owner_mismatch_o != expected.owner_mismatch) {
      fail(test_case, "owner_mismatch", expected.owner_mismatch,
           dut.owner_mismatch_o);
    }
    if (dut.backpressured_o != expected.backpressured) {
      fail(test_case, "backpressured", expected.backpressured,
           dut.backpressured_o);
    }
    if (dut.conflict_o != expected.conflict) {
      fail(test_case, "conflict", expected.conflict, dut.conflict_o);
    }
  }

  dut.final();
  std::cout << "PASS: " << kTests
            << " randomized 8-group/3-slot/3-context dispatch cases\n";
  return 0;
}
