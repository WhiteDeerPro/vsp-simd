#include "Vsimd_issue_dispatch.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>

namespace {

constexpr unsigned kGroups = 4;
constexpr unsigned kSlots = 2;

struct Expected {
  uint8_t ready = 0;
  uint8_t accept = 0;
  uint8_t reject = 0;
  uint8_t group_valid = 0;
  uint8_t group_slot = 0;
  uint8_t empty = 0;
  uint8_t owner_mismatch = 0;
  uint8_t backpressured = 0;
  uint8_t conflict = 0;
};

unsigned field(uint32_t packed, unsigned index, unsigned width) {
  return (packed >> (index * width)) & ((1u << width) - 1u);
}

Expected reference(uint8_t valid, uint8_t contexts, uint8_t masks,
                   uint8_t owner_valid, uint8_t owners,
                   uint8_t group_ready, uint8_t resource_ready) {
  Expected expected;
  uint8_t reserved = 0;

  for (unsigned slot = 0; slot < kSlots; ++slot) {
    const unsigned context = field(contexts, slot, 1);
    const uint8_t requested = field(masks, slot, kGroups);
    bool owners_match = true;
    bool all_ready = true;

    for (unsigned group = 0; group < kGroups; ++group) {
      if ((requested >> group) & 1u) {
        owners_match &= ((owner_valid >> group) & 1u) &&
                        field(owners, group, 1) == context;
        all_ready &= (group_ready >> group) & 1u;
      }
    }

    const bool overlaps = (requested & reserved) != 0;
    const bool request_error = requested == 0 || !owners_match;
    const bool slot_resource_ready = (resource_ready >> slot) & 1u;
    const bool can_execute = !request_error && all_ready &&
                             slot_resource_ready && !overlaps;
    const bool ready = request_error || can_execute;
    const bool slot_valid = (valid >> slot) & 1u;
    const bool accept = slot_valid && can_execute;
    const bool reject = slot_valid && request_error;

    expected.ready |= uint8_t(ready) << slot;
    expected.accept |= uint8_t(accept) << slot;
    expected.reject |= uint8_t(reject) << slot;
    expected.empty |= uint8_t(slot_valid && requested == 0) << slot;
    expected.owner_mismatch |=
        uint8_t(slot_valid && requested != 0 && !owners_match) << slot;
    expected.backpressured |=
        uint8_t(slot_valid && requested != 0 && owners_match &&
                (!all_ready || !slot_resource_ready))
        << slot;
    expected.conflict |=
        uint8_t(slot_valid && requested != 0 && owners_match && all_ready &&
                slot_resource_ready && overlaps)
        << slot;

    if (accept) {
      reserved |= requested;
      for (unsigned group = 0; group < kGroups; ++group) {
        if ((requested >> group) & 1u) {
          expected.group_valid |= 1u << group;
          expected.group_slot |= slot << group;
        }
      }
    }
  }

  return expected;
}

[[noreturn]] void fail(uint32_t case_index, const char* field_name,
                       unsigned expected, unsigned actual) {
  std::cerr << "FAIL case=" << case_index << ' ' << field_name
            << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vsimd_issue_dispatch dut;
  uint32_t case_index = 0;

  // Exhaust every unowned/context-0/context-1 group state, request mask,
  // context, ready and valid combination. Base-3 ownership avoids enumerating
  // duplicate owner bits while owner_valid is clear.
  for (unsigned ownership_state = 0; ownership_state < 81;
       ++ownership_state) {
    unsigned encoded_state = ownership_state;
    unsigned owner_valid = 0;
    unsigned owners = 0;
    for (unsigned group = 0; group < kGroups; ++group) {
      const unsigned state = encoded_state % 3;
      encoded_state /= 3;
      if (state != 0) {
        owner_valid |= 1u << group;
        owners |= (state - 1) << group;
      }
    }
    for (unsigned contexts = 0; contexts < 4; ++contexts) {
      for (unsigned masks = 0; masks < 256; ++masks) {
        for (unsigned group_ready = 0; group_ready < 16; ++group_ready) {
          for (unsigned valid = 0; valid < 4; ++valid, ++case_index) {
            dut.issue_valid_i = valid;
            dut.issue_context_i = contexts;
            dut.issue_group_mask_i = masks;
            dut.issue_resource_ready_i = 0x3;
            dut.issue_reject_ready_i = 0x3;
            dut.group_owner_valid_i = owner_valid;
            dut.group_owner_i = owners;
            dut.group_ready_i = group_ready;
            dut.eval();

            const Expected expected = reference(
                valid, contexts, masks, owner_valid, owners, group_ready,
                0x3);
            if (dut.issue_ready_o != expected.ready) {
              fail(case_index, "ready", expected.ready, dut.issue_ready_o);
            }
            if (dut.issue_accept_o != expected.accept) {
              fail(case_index, "accept", expected.accept,
                   dut.issue_accept_o);
            }
            if (dut.issue_reject_o != expected.reject) {
              fail(case_index, "reject", expected.reject,
                   dut.issue_reject_o);
            }
            if (dut.group_issue_valid_o != expected.group_valid) {
              fail(case_index, "group_valid", expected.group_valid,
                   dut.group_issue_valid_o);
            }
            if (dut.group_issue_slot_o != expected.group_slot) {
              fail(case_index, "group_slot", expected.group_slot,
                   dut.group_issue_slot_o);
            }
            if (dut.empty_mask_o != expected.empty) {
              fail(case_index, "empty", expected.empty, dut.empty_mask_o);
            }
            if (dut.owner_mismatch_o != expected.owner_mismatch) {
              fail(case_index, "owner_mismatch", expected.owner_mismatch,
                   dut.owner_mismatch_o);
            }
            if (dut.backpressured_o != expected.backpressured) {
              fail(case_index, "backpressured", expected.backpressured,
                   dut.backpressured_o);
            }
            if (dut.conflict_o != expected.conflict) {
              fail(case_index, "conflict", expected.conflict,
                   dut.conflict_o);
            }
          }
        }
      }
    }
  }

  // A malformed request remains at the queue head until an ordered error sink
  // has capacity; diagnostics stay visible while ready/reject remain low.
  dut.issue_valid_i = 0x1;
  dut.issue_context_i = 0;
  dut.issue_group_mask_i = 0;
  dut.issue_resource_ready_i = 0;
  dut.issue_reject_ready_i = 0;
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0;
  dut.group_ready_i = 0xf;
  dut.eval();
  if ((dut.issue_ready_o & 0x1u) != 0) {
    fail(case_index, "reject credit blocks ready", 0,
         dut.issue_ready_o & 0x1u);
  }
  if ((dut.issue_reject_o & 0x1u) != 0) {
    fail(case_index, "reject credit blocks reject", 0,
         dut.issue_reject_o & 0x1u);
  }
  if ((dut.empty_mask_o & 0x1u) == 0) {
    fail(case_index, "blocked reject keeps diagnostic", 1, 0);
  }

  dut.issue_reject_ready_i = 0x1;
  dut.eval();
  if ((dut.issue_ready_o & 0x1u) == 0) {
    fail(case_index, "reject credit releases ready", 1, 0);
  }
  if ((dut.issue_reject_o & 0x1u) == 0) {
    fail(case_index, "reject credit releases reject", 1, 0);
  }
  ++case_index;

  // Shared-resource denial stalls an otherwise legal request, but a blocked
  // higher-priority slot does not reserve groups or prevent an eligible lower
  // slot from issuing the same mask.
  dut.issue_valid_i = 0x3;
  dut.issue_context_i = 0;
  dut.issue_group_mask_i = 0x11;
  dut.issue_resource_ready_i = 0x2;
  dut.issue_reject_ready_i = 0x3;
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0;
  dut.group_ready_i = 0xf;
  dut.eval();
  if (dut.issue_accept_o != 0x2) {
    fail(case_index, "resource gate lower-slot bypass", 0x2,
         dut.issue_accept_o);
  }
  if (dut.group_issue_valid_o != 0x1 || dut.group_issue_slot_o != 0x1) {
    fail(case_index, "resource gate atomic group issue", 0x1,
         dut.group_issue_valid_o);
  }
  if ((dut.backpressured_o & 0x1u) == 0 || dut.conflict_o != 0) {
    fail(case_index, "resource gate diagnostic", 0x1,
         dut.backpressured_o & 0x1u);
  }
  ++case_index;

  dut.final();
  std::cout << "PASS: " << case_index
            << " exhaustive dual-issue ownership, rejection, atomic "
               "multicast, backpressure, and conflict cases\n";
  return 0;
}
