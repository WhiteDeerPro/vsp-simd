#include "Vvsp_cluster_controller_wrapper.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

namespace {

constexpr uint8_t kClassExec = 0;
constexpr uint8_t kClassMemory = 1;
constexpr uint8_t kClassControl = 2;
constexpr uint8_t kControlEnd = 0;
constexpr uint8_t kStatusOk = 0;
constexpr uint8_t kStatusDecode = 1;
constexpr uint8_t kStatusOwner = 2;
constexpr uint8_t kStatusExec = 3;
constexpr uint8_t kStatusMemory = 4;
constexpr uint8_t kMemLoad = 0;
constexpr uint8_t kMemStore = 1;
constexpr uint8_t kAddrLocal = 0;
constexpr uint8_t kFaultNone = 0;
constexpr uint8_t kFaultTranslation = 1;
constexpr uint8_t kMemCplOk = 0;
constexpr uint8_t kMemCplFault = 3;
constexpr uint8_t kUwordBadFormat = 1;

uint64_t checks = 0;

[[noreturn]] void fail(const std::string& what, uint64_t expected,
                       uint64_t actual) {
  std::cerr << "FAIL " << what << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << '\n';
  std::exit(1);
}

void expect_eq(const std::string& what, uint64_t expected,
               uint64_t actual) {
  ++checks;
  if (expected != actual) fail(what, expected, actual);
}

uint32_t load_word(const std::array<uint8_t, 512>& bytes,
                   uint32_t address) {
  uint32_t value = 0;
  for (unsigned byte = 0; byte < 4; ++byte)
    value |= uint32_t{bytes.at(address + byte)} << (8 * byte);
  return value;
}

void store_word(std::array<uint8_t, 512>& bytes, uint32_t address,
                uint32_t data, uint8_t strobe) {
  for (unsigned byte = 0; byte < 4; ++byte) {
    if ((strobe >> byte) & 1U)
      bytes.at(address + byte) = uint8_t(data >> (8 * byte));
  }
}

struct Action {
  uint8_t action_class = kClassControl;
  uint8_t context = 0;
  uint8_t tag = 0;
  uint8_t group_mask = 0;
  bool legal = true;
  uint8_t decode_error = 0;
  uint8_t control_op = kControlEnd;
  uint32_t exec_base = 0;
  bool exec_extension_valid = false;
  uint32_t exec_extension = 0;
  uint8_t memory_op = kMemLoad;
  uint32_t memory_base = 0;
  int16_t memory_offset = 0;
  uint8_t memory_row = 0;
  uint8_t memory_span = 0;
};

struct ExpectedCompletion {
  uint8_t action_class;
  uint8_t context;
  uint8_t tag;
  uint8_t status;
  uint8_t decode_error = 0;
  bool end = false;
  uint8_t exec_group_mask = 0;
  bool exec_illegal = false;
  uint8_t mem_op = 0;
  uint8_t mem_status = 0;
  uint8_t mem_fault = 0;
  uint32_t mem_fault_eaddr = 0;
  uint8_t mem_requested = 0;
  uint8_t mem_completed = 0;
  uint8_t mem_failed = 0;
  uint8_t mem_bytes = 0;
  bool mem_partial = false;
  uint8_t exec_result_mask = 0;
  uint8_t exec_illegal_group_mask = 0;
  bool exec_rejected = false;
  bool exec_empty_mask = false;
  bool exec_owner_mismatch = false;
};

Action make_memory(uint8_t op, uint8_t context, uint8_t tag,
                   uint32_t base, uint8_t mask, uint8_t row,
                   uint8_t span) {
  Action action;
  action.action_class = kClassMemory;
  action.context = context;
  action.tag = tag;
  action.group_mask = mask;
  action.memory_op = op;
  action.memory_base = base;
  action.memory_row = row;
  action.memory_span = span;
  return action;
}

Action make_add_immediate(uint8_t tag, uint8_t src, uint8_t dst,
                          uint8_t immediate,
                          bool export_narrow = false) {
  Action action;
  action.action_class = kClassExec;
  action.tag = tag;
  action.group_mask = 0xf;
  // EXEC profile-v0 ALU format:
  // fmt=1, ADD=0, BYTE=0, va=src, vb=0, vd=dst, unmasked,
  // bimm=1, write_vrf=1, no export/reduction.
  action.exec_base = (uint32_t{1} << 28) |
                     (uint32_t(src & 0xfU) << 17) |
                     (uint32_t(dst & 0xfU) << 9) |
                     (uint32_t{1} << 5) | (uint32_t{1} << 4) |
                     (uint32_t(export_narrow) << 3);
  action.exec_extension_valid = true;
  action.exec_extension = immediate;
  return action;
}

Action make_end(uint8_t context, uint8_t tag) {
  Action action;
  action.action_class = kClassControl;
  action.context = context;
  action.tag = tag;
  return action;
}

struct LocalMemory {
  std::array<uint8_t, 512> bytes{};
  uint64_t cycle = 0;
  bool response_pending = false;
  unsigned response_delay = 0;
  uint32_t response_data = 0;
  uint8_t response_fault = kFaultNone;
  uint32_t fault_address = std::numeric_limits<uint32_t>::max();
  uint8_t fault_cause = kFaultNone;
  uint64_t requests = 0;
  uint64_t loads = 0;
  uint64_t stores = 0;
  uint64_t request_stalls = 0;

  void drive(Vvsp_cluster_controller_wrapper& dut) {
    dut.dmem_req_ready_i =
        !response_pending && ((cycle % 4) != 1) && ((cycle % 7) != 3);
    dut.dmem_rsp_valid_i = response_pending && response_delay == 0;
    dut.dmem_rsp_rdata_i = response_data;
    dut.dmem_rsp_fault_cause_i = response_fault;
  }

  void update_after_edge(bool request_fire, uint8_t request_op,
                         uint32_t request_address, uint32_t request_wdata,
                         uint8_t request_wstrb, bool response_fire) {
    const bool old_pending = response_pending;
    if (response_fire) response_pending = false;
    else if (old_pending && response_delay != 0) --response_delay;

    if (request_fire) {
      expect_eq("single-outstanding memory model", 0,
                old_pending && !response_fire);
      ++requests;
      response_fault = request_address == fault_address ? fault_cause
                                                        : kFaultNone;
      if (request_op == kMemLoad) {
        ++loads;
        response_data = load_word(bytes, request_address);
      } else {
        ++stores;
        if (response_fault == kFaultNone)
          store_word(bytes, request_address, request_wdata, request_wstrb);
        response_data = 0;
      }
      response_pending = true;
      response_delay = 1 + unsigned((cycle >> 1) & 1U);
    }
    ++cycle;
  }
};

struct CompletionSnapshot {
  bool valid = false;
  uint8_t action_class = 0;
  uint8_t context = 0;
  uint8_t tag = 0;
  uint8_t group_mask = 0;
  uint8_t status = 0;
  uint8_t decode_error = 0;
  bool end = false;
  uint32_t exec_bits = 0;
  uint64_t memory_bits = 0;
};

void clear_action_inputs(Vvsp_cluster_controller_wrapper& dut) {
  dut.action_valid_i = 0;
  dut.action_class_i = kClassControl;
  dut.action_legal_i = 1;
  dut.action_decode_error_i = 0;
  dut.action_control_op_i = kControlEnd;
  dut.action_context_i = 0;
  dut.action_tag_i = 0;
  dut.action_group_mask_i = 0;
  dut.action_exec_base_word_i = 0;
  dut.action_exec_extension_valid_i = 0;
  dut.action_exec_extension_word_i = 0;
  dut.action_memory_op_i = kMemLoad;
  dut.action_memory_addr_space_i = kAddrLocal;
  dut.action_memory_addr_context_i = 0x5a;
  dut.action_memory_base_eaddr_i = 0;
  dut.action_memory_eaddr_offset_i = 0;
  dut.action_memory_vrf_row_i = 0;
  dut.action_memory_span_bytes_i = 0;
}

void drive_action(Vvsp_cluster_controller_wrapper& dut,
                  const Action& action) {
  clear_action_inputs(dut);
  dut.action_valid_i = 1;
  dut.action_class_i = action.action_class;
  dut.action_legal_i = action.legal;
  dut.action_decode_error_i = action.decode_error;
  dut.action_control_op_i = action.control_op;
  dut.action_context_i = action.context;
  dut.action_tag_i = action.tag;
  dut.action_group_mask_i = action.group_mask;
  dut.action_exec_base_word_i = action.exec_base;
  dut.action_exec_extension_valid_i = action.exec_extension_valid;
  dut.action_exec_extension_word_i = action.exec_extension;
  dut.action_memory_op_i = action.memory_op;
  dut.action_memory_addr_space_i = kAddrLocal;
  dut.action_memory_addr_context_i = 0x5a;
  dut.action_memory_base_eaddr_i = action.memory_base;
  dut.action_memory_eaddr_offset_i = uint16_t(action.memory_offset);
  dut.action_memory_vrf_row_i = action.memory_row;
  dut.action_memory_span_bytes_i = action.memory_span;
}

void check_completion(Vvsp_cluster_controller_wrapper& dut,
                      const ExpectedCompletion& expected,
                      uint8_t expected_group_mask) {
  expect_eq("completion class", expected.action_class,
            dut.action_cpl_class_o);
  expect_eq("completion context", expected.context,
            dut.action_cpl_context_o);
  expect_eq("completion tag", expected.tag, dut.action_cpl_tag_o);
  expect_eq("completion requested group mask", expected_group_mask,
            dut.action_cpl_group_mask_o);
  expect_eq("completion status", expected.status, dut.action_cpl_status_o);
  expect_eq("completion decode error", expected.decode_error,
            dut.action_cpl_decode_error_o);
  expect_eq("completion END flag", expected.end, dut.action_cpl_end_o);
  expect_eq("completion EXEC group mask", expected.exec_group_mask,
            dut.action_cpl_exec_group_mask_o);
  expect_eq("completion EXEC result mask", expected.exec_result_mask,
            dut.action_cpl_exec_result_mask_o);
  expect_eq("completion EXEC illegal", expected.exec_illegal,
            dut.action_cpl_exec_illegal_o);
  expect_eq("completion EXEC illegal group mask",
            expected.exec_illegal_group_mask,
            dut.action_cpl_exec_illegal_group_mask_o);
  expect_eq("completion EXEC rejected", expected.exec_rejected,
            dut.action_cpl_exec_rejected_o);
  expect_eq("completion EXEC empty mask", expected.exec_empty_mask,
            dut.action_cpl_exec_empty_mask_o);
  expect_eq("completion EXEC owner mismatch",
            expected.exec_owner_mismatch,
            dut.action_cpl_exec_owner_mismatch_o);
  expect_eq("completion MEMORY op", expected.mem_op,
            dut.action_cpl_memory_op_o);
  expect_eq("completion MEMORY status", expected.mem_status,
            dut.action_cpl_memory_status_o);
  expect_eq("completion MEMORY fault", expected.mem_fault,
            dut.action_cpl_memory_fault_cause_o);
  expect_eq("completion MEMORY fault address", expected.mem_fault_eaddr,
            dut.action_cpl_memory_fault_eaddr_o);
  expect_eq("completion MEMORY requested", expected.mem_requested,
            dut.action_cpl_memory_requested_group_mask_o);
  expect_eq("completion MEMORY completed", expected.mem_completed,
            dut.action_cpl_memory_completed_group_mask_o);
  expect_eq("completion MEMORY failed", expected.mem_failed,
            dut.action_cpl_memory_failed_group_mask_o);
  expect_eq("completion MEMORY bytes", expected.mem_bytes,
            dut.action_cpl_memory_bytes_committed_o);
  expect_eq("completion MEMORY partial", expected.mem_partial,
            dut.action_cpl_memory_partial_o);
}

void check_stall_stability(Vvsp_cluster_controller_wrapper& dut,
                           CompletionSnapshot& snapshot) {
  const uint32_t exec_bits =
      uint32_t(dut.action_cpl_exec_group_mask_o) |
      (uint32_t(dut.action_cpl_exec_result_mask_o) << 4) |
      (uint32_t(dut.action_cpl_exec_illegal_o) << 8) |
      (uint32_t(dut.action_cpl_exec_illegal_group_mask_o) << 9) |
      (uint32_t(dut.action_cpl_exec_rejected_o) << 13) |
      (uint32_t(dut.action_cpl_exec_empty_mask_o) << 14) |
      (uint32_t(dut.action_cpl_exec_owner_mismatch_o) << 15);
  const uint64_t memory_bits =
      uint64_t(dut.action_cpl_memory_op_o) |
      (uint64_t(dut.action_cpl_memory_status_o) << 1) |
      (uint64_t(dut.action_cpl_memory_fault_cause_o) << 4) |
      (uint64_t(dut.action_cpl_memory_fault_eaddr_o) << 7) |
      (uint64_t(dut.action_cpl_memory_requested_group_mask_o) << 39) |
      (uint64_t(dut.action_cpl_memory_completed_group_mask_o) << 43) |
      (uint64_t(dut.action_cpl_memory_failed_group_mask_o) << 47) |
      (uint64_t(dut.action_cpl_memory_bytes_committed_o) << 51) |
      (uint64_t(dut.action_cpl_memory_partial_o) << 56);

  if (snapshot.valid) {
    expect_eq("stalled completion remains valid", 1,
              dut.action_cpl_valid_o);
    expect_eq("stalled completion class", snapshot.action_class,
              dut.action_cpl_class_o);
    expect_eq("stalled completion context", snapshot.context,
              dut.action_cpl_context_o);
    expect_eq("stalled completion tag", snapshot.tag,
              dut.action_cpl_tag_o);
    expect_eq("stalled completion requested mask", snapshot.group_mask,
              dut.action_cpl_group_mask_o);
    expect_eq("stalled completion status", snapshot.status,
              dut.action_cpl_status_o);
    expect_eq("stalled completion decode error", snapshot.decode_error,
              dut.action_cpl_decode_error_o);
    expect_eq("stalled completion END", snapshot.end,
              dut.action_cpl_end_o);
    expect_eq("stalled completion EXEC detail", snapshot.exec_bits,
              exec_bits);
    expect_eq("stalled completion MEMORY detail", snapshot.memory_bits,
              memory_bits);
  }

  if (dut.action_cpl_valid_o && !dut.action_cpl_ready_i &&
      !snapshot.valid) {
    snapshot.valid = true;
    snapshot.action_class = dut.action_cpl_class_o;
    snapshot.context = dut.action_cpl_context_o;
    snapshot.tag = dut.action_cpl_tag_o;
    snapshot.group_mask = dut.action_cpl_group_mask_o;
    snapshot.status = dut.action_cpl_status_o;
    snapshot.decode_error = dut.action_cpl_decode_error_o;
    snapshot.end = dut.action_cpl_end_o;
    snapshot.exec_bits = exec_bits;
    snapshot.memory_bits = memory_bits;
  }

  if (!dut.action_cpl_valid_o || dut.action_cpl_ready_i)
    snapshot.valid = false;
}

struct StreamResult {
  std::vector<uint64_t> accept_cycles;
  std::vector<uint64_t> completion_cycles;
  uint64_t done_pulses = 0;
};

StreamResult run_stream(Vvsp_cluster_controller_wrapper& dut,
                        LocalMemory& memory,
                        const std::vector<Action>& actions,
                        const std::vector<ExpectedCompletion>& expected,
                        uint64_t& global_cycle) {
  expect_eq("action/completion stream sizes", actions.size(),
            expected.size());
  StreamResult result;
  CompletionSnapshot stalled_completion;
  std::size_t action_index = 0;
  std::size_t completion_index = 0;

  for (int timeout = 0; timeout < 10000; ++timeout) {
    if (action_index < actions.size()) drive_action(dut, actions[action_index]);
    else clear_action_inputs(dut);

    // Deterministic completion backpressure: every visible completion is held
    // for at least one cycle on some phase of this four-cycle pattern.
    dut.action_cpl_ready_i = (global_cycle % 4) == 3;
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();

    if (action_index < actions.size() &&
        actions[action_index].action_class == kClassExec &&
        actions[action_index].exec_extension_valid) {
      expect_eq("ADDI extension required", 1,
                dut.action_exec_extension_required_diag_o);
    }

    const bool action_fire = dut.action_valid_i && dut.action_ready_o;
    const bool completion_fire =
        dut.action_cpl_valid_o && dut.action_cpl_ready_i;
    const bool request_valid = dut.dmem_req_valid_o;
    const bool request_fire = request_valid && dut.dmem_req_ready_i;
    const bool response_fire = dut.dmem_rsp_valid_i && dut.dmem_rsp_ready_o;
    if (request_valid && !dut.dmem_req_ready_i) ++memory.request_stalls;

    check_stall_stability(dut, stalled_completion);
    if (dut.action_cpl_valid_o) {
      expect_eq("completion index in range", 1,
                completion_index < expected.size());
      check_completion(dut, expected[completion_index],
                       actions[completion_index].group_mask);
    }
    if (dut.program_done_o) {
      ++result.done_pulses;
      expect_eq("done accompanies completion fire", 1, completion_fire);
      expect_eq("done completion is END", 1, dut.action_cpl_end_o);
    }

    uint8_t request_op = 0;
    uint32_t request_address = 0;
    uint32_t request_wdata = 0;
    uint8_t request_wstrb = 0;
    if (request_fire) {
      request_op = dut.dmem_req_op_o;
      request_address = dut.dmem_req_eaddr_o;
      request_wdata = dut.dmem_req_wdata_o;
      request_wstrb = dut.dmem_req_wstrb_o;
      expect_eq("local address space", kAddrLocal,
                dut.dmem_req_addr_space_o);
      expect_eq("memory address context", 0x5a,
                dut.dmem_req_addr_context_o);
      expect_eq("memory request in range", 1,
                request_address + 4 <= memory.bytes.size());
    }

    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();

    memory.update_after_edge(request_fire, request_op, request_address,
                             request_wdata, request_wstrb, response_fire);
    if (action_fire) {
      result.accept_cycles.push_back(global_cycle);
      ++action_index;
    }
    if (completion_fire) {
      result.completion_cycles.push_back(global_cycle);
      ++completion_index;
      stalled_completion.valid = false;
    }
    ++global_cycle;

    if (action_index == actions.size() &&
        completion_index == expected.size() && !dut.controller_busy_o &&
        !memory.response_pending) {
      clear_action_inputs(dut);
      dut.action_cpl_ready_i = 0;
      return result;
    }
  }

  std::cerr << "timeout running ordered action stream\n";
  std::exit(1);
}

void reset(Vvsp_cluster_controller_wrapper& dut, LocalMemory& memory,
           uint64_t& global_cycle) {
  clear_action_inputs(dut);
  dut.group_owner_valid_i = 0xf;
  dut.group_owner_i = 0;
  dut.action_cpl_ready_i = 0;
  dut.exec_result_ready_i = 1;
  dut.protocol_error_clear_i = 0;
  dut.dmem_req_ready_i = 0;
  dut.dmem_rsp_valid_i = 0;
  dut.dmem_rsp_rdata_i = 0;
  dut.dmem_rsp_fault_cause_i = kFaultNone;
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 4; ++cycle) {
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();
    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();
    ++memory.cycle;
    ++global_cycle;
  }
  dut.rst_ni = 1;
  memory.drive(dut);
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
  ++memory.cycle;
  ++global_cycle;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Vvsp_cluster_controller_wrapper dut;
  LocalMemory memory;
  uint64_t global_cycle = 0;

  reset(dut, memory, global_cycle);

  constexpr uint32_t kLoadBase = 0x20;
  constexpr uint32_t kStoreBase = 0x80;
  const std::array<uint32_t, 4> source_words = {
      0x04030201U, 0x281e140aU, 0xfdfcfbfaU, 0xff800700U};
  const std::array<uint32_t, 4> expected_words = {
      0x07060504U, 0x2b21170dU, 0x00fffefdU, 0x02830a03U};
  for (unsigned group = 0; group < source_words.size(); ++group)
    store_word(memory.bytes, kLoadBase + 4 * group, source_words[group], 0xf);

  const std::vector<Action> success_actions = {
      make_memory(kMemLoad, 0, 0x31, kLoadBase, 0xf, 2, 16),
      make_add_immediate(0x42, 2, 3, 3),
      make_memory(kMemStore, 0, 0x53, kStoreBase, 0xf, 3, 16),
      make_end(0, 0x64)};
  const std::vector<ExpectedCompletion> success_expected = {
      {kClassMemory, 0, 0x31, kStatusOk, 0, false, 0, false,
       kMemLoad, kMemCplOk, kFaultNone, 0, 0xf, 0xf, 0, 16, false},
      {kClassExec, 0, 0x42, kStatusOk, 0, false, 0xf, false},
      {kClassMemory, 0, 0x53, kStatusOk, 0, false, 0, false,
       kMemStore, kMemCplOk, kFaultNone, 0, 0xf, 0xf, 0, 16, false},
      {kClassControl, 0, 0x64, kStatusOk, 0, true}};
  const StreamResult success =
      run_stream(dut, memory, success_actions, success_expected, global_cycle);
  expect_eq("success accepted all actions", 4, success.accept_cycles.size());
  expect_eq("success retired all actions", 4,
            success.completion_cycles.size());
  for (std::size_t index = 1; index < success.accept_cycles.size(); ++index) {
    expect_eq("no cross-class issue before prior retire", 1,
              success.accept_cycles[index] >=
                  success.completion_cycles[index - 1]);
  }
  expect_eq("one successful program-done pulse", 1, success.done_pulses);
  expect_eq("LOAD request count", 4, memory.loads);
  expect_eq("STORE request count", 4, memory.stores);
  expect_eq("memory request backpressure occurred", 1,
            memory.request_stalls != 0);
  for (unsigned group = 0; group < expected_words.size(); ++group) {
    expect_eq("stored transformed group " + std::to_string(group),
              expected_words[group],
              load_word(memory.bytes, kStoreBase + 4 * group));
  }

  // An illegal encoded EXEC becomes one ordered local completion and has no
  // execution or memory side effect.  fmt=0 is reserved in profile v0.
  Action bad_exec;
  bad_exec.action_class = kClassExec;
  bad_exec.tag = 0x70;
  bad_exec.group_mask = 0xf;
  bad_exec.exec_base = 0;
  const uint64_t requests_before_bad_exec = memory.requests;
  const std::vector<Action> bad_exec_actions = {bad_exec, make_end(0, 0x71)};
  const std::vector<ExpectedCompletion> bad_exec_expected = {
      {kClassExec, 0, 0x70, kStatusDecode, kUwordBadFormat, false},
      {kClassControl, 0, 0x71, kStatusOk, 0, true}};
  const StreamResult bad_exec_result = run_stream(
      dut, memory, bad_exec_actions, bad_exec_expected, global_cycle);
  expect_eq("bad EXEC has no dmem side effect", requests_before_bad_exec,
            memory.requests);
  expect_eq("bad EXEC stream still terminates once", 1,
            bad_exec_result.done_pulses);

  // MEMORY ownership is rejected before the memory engine sees a command.
  const uint64_t requests_before_owner = memory.requests;
  const std::vector<Action> owner_actions = {
      make_memory(kMemLoad, 1, 0x72, 0xc0, 0x1, 4, 4),
      make_end(0, 0x73)};
  const std::vector<ExpectedCompletion> owner_expected = {
      {kClassMemory, 1, 0x72, kStatusOwner},
      {kClassControl, 0, 0x73, kStatusOk, 0, true}};
  run_stream(dut, memory, owner_actions, owner_expected, global_cycle);
  expect_eq("owner reject has no dmem side effect", requests_before_owner,
            memory.requests);

  // A legal EXEC packet can still be rejected by the EXEC child.  Empty mask
  // is dynamic envelope state, not a profile-v0 decode error.
  Action empty_exec = make_add_immediate(0x76, 2, 3, 1);
  empty_exec.group_mask = 0;
  ExpectedCompletion empty_exec_cpl{kClassExec, 0, 0x76, kStatusExec};
  empty_exec_cpl.exec_illegal = true;
  empty_exec_cpl.exec_rejected = true;
  empty_exec_cpl.exec_empty_mask = true;
  const std::vector<Action> empty_exec_actions = {
      empty_exec, make_end(0, 0x77)};
  const std::vector<ExpectedCompletion> empty_exec_expected = {
      empty_exec_cpl,
      {kClassControl, 0, 0x77, kStatusOk, 0, true}};
  run_stream(dut, memory, empty_exec_actions, empty_exec_expected,
             global_cycle);

  // Stop-on-first fault detail survives the unified completion register.
  constexpr uint32_t kFaultBase = 0x100;
  for (unsigned group = 0; group < 4; ++group)
    store_word(memory.bytes, kFaultBase + 4 * group,
               0x11111111U * (group + 1), 0xf);
  memory.fault_address = kFaultBase + 4;
  memory.fault_cause = kFaultTranslation;
  const std::vector<Action> fault_actions = {
      make_memory(kMemLoad, 0, 0x74, kFaultBase, 0xf, 5, 16),
      make_end(0, 0x75)};
  const std::vector<ExpectedCompletion> fault_expected = {
      {kClassMemory, 0, 0x74, kStatusMemory, 0, false, 0, false,
       kMemLoad, kMemCplFault, kFaultTranslation, kFaultBase + 4,
       0xf, 0x1, 0x2, 4, true},
      {kClassControl, 0, 0x75, kStatusOk, 0, true}};
  const StreamResult fault_result =
      run_stream(dut, memory, fault_actions, fault_expected, global_cycle);
  expect_eq("fault stream terminates once", 1, fault_result.done_pulses);
  expect_eq("faulting LOAD issued two beats", 6, memory.loads);
  memory.fault_address = std::numeric_limits<uint32_t>::max();
  memory.fault_cause = kFaultNone;

  // END waits for tracker/result obligations that have not yet reached the
  // finite result collector.  It does not require an already-buffered result
  // to disappear from the external interface: once space is made, the second
  // record is captured, tracker_empty rises and END may retire.
  Action export_a = make_add_immediate(0x78, 2, 6, 0, true);
  Action export_b = make_add_immediate(0x79, 2, 7, 0, true);
  export_a.group_mask = 0x1;
  export_b.group_mask = 0x1;
  const std::vector<Action> drain_actions = {
      export_a, export_b, make_end(0, 0x7a)};
  ExpectedCompletion export_a_cpl{kClassExec, 0, 0x78, kStatusOk,
                                  0, false, 0x1, false};
  ExpectedCompletion export_b_cpl{kClassExec, 0, 0x79, kStatusOk,
                                  0, false, 0x1, false};
  export_a_cpl.exec_result_mask = 0x1;
  export_b_cpl.exec_result_mask = 0x1;
  const std::vector<ExpectedCompletion> drain_expected = {
      export_a_cpl, export_b_cpl,
      {kClassControl, 0, 0x7a, kStatusOk, 0, true}};

  std::size_t drain_action_index = 0;
  std::size_t drain_completion_index = 0;
  unsigned blocked_end_cycles = 0;
  unsigned result_handshakes = 0;
  unsigned drain_done_pulses = 0;
  bool end_accepted = false;
  bool release_results = false;
  bool observed_tracker_block = false;
  for (int timeout = 0; timeout < 2000; ++timeout) {
    if (drain_action_index < drain_actions.size())
      drive_action(dut, drain_actions[drain_action_index]);
    else
      clear_action_inputs(dut);
    dut.action_cpl_ready_i = 1;
    dut.exec_result_ready_i = release_results;
    memory.drive(dut);
    dut.clk_i = 0;
    dut.eval();

    const bool action_fire = dut.action_valid_i && dut.action_ready_o;
    const bool completion_fire =
        dut.action_cpl_valid_o && dut.action_cpl_ready_i;
    const bool result_fire =
        dut.exec_result_valid_o && dut.exec_result_ready_i;
    expect_eq("result-drain scenario has no dmem request", 0,
              dut.dmem_req_valid_o);

    if (dut.action_cpl_valid_o) {
      expect_eq("drain completion index in range", 1,
                drain_completion_index < drain_expected.size());
      check_completion(dut, drain_expected[drain_completion_index],
                       drain_actions[drain_completion_index].group_mask);
      if (!release_results)
        expect_eq("END cannot complete before result staging advances", 0,
                  dut.action_cpl_end_o);
    }
    if (dut.program_done_o) {
      ++drain_done_pulses;
      expect_eq("drain done is an END handshake", 1,
                completion_fire && dut.action_cpl_end_o);
    }
    if (action_fire &&
        drain_actions[drain_action_index].action_class == kClassControl)
      end_accepted = true;

    if (end_accepted && !release_results) {
      if (!(action_fire &&
            drain_actions[drain_action_index].action_class ==
                kClassControl)) {
        expect_eq("END remains busy while result obligation is blocked", 1,
                  dut.controller_busy_o);
      }
      if (!dut.exec_tracker_empty_o && dut.exec_result_valid_o) {
        observed_tracker_block = true;
        ++blocked_end_cycles;
      }
    }

    dut.clk_i = 1;
    dut.eval();
    dut.clk_i = 0;
    dut.eval();
    memory.update_after_edge(false, 0, 0, 0, 0, false);
    if (action_fire) ++drain_action_index;
    if (completion_fire) ++drain_completion_index;
    if (result_fire) ++result_handshakes;
    ++global_cycle;

    if (blocked_end_cycles >= 4) release_results = true;
    if (drain_completion_index == drain_expected.size() &&
        result_handshakes == 2 && !dut.controller_busy_o)
      break;
  }
  expect_eq("END observed finite result-buffer backpressure", 1,
            observed_tracker_block);
  expect_eq("two exported result records drained", 2, result_handshakes);
  expect_eq("result-drain stream retired all completions", 3,
            drain_completion_index);
  expect_eq("result-drain stream has one done pulse", 1,
            drain_done_pulses);
  dut.action_cpl_ready_i = 0;
  dut.exec_result_ready_i = 1;

  expect_eq("controller idle", 0, dut.controller_busy_o);
  expect_eq("memory engine idle", 0, dut.mem_busy_o);
  expect_eq("VRF arbiter idle", 0, dut.vrf_arbiter_busy_o);
  expect_eq("EXEC queue empty", 1, dut.exec_queue_empty_o);
  expect_eq("EXEC tracker empty", 1, dut.exec_tracker_empty_o);
  expect_eq("controller protocol clean", 0,
            dut.controller_protocol_error_o);
  expect_eq("EXEC protocol clean", 0, dut.exec_protocol_error_o);
  expect_eq("MEMORY protocol clean", 0, dut.mem_protocol_error_o);
  expect_eq("combined protocol clean", 0, dut.protocol_error_o);

  dut.final();
  std::cout << "PASS: VSP cluster controller " << checks
            << " checks across decoded LOAD -> encoded EXEC -> decoded "
               "STORE -> END, "
               "ordering, backpressure, owner/decode errors and memory "
               "faults\n";
  return 0;
}
