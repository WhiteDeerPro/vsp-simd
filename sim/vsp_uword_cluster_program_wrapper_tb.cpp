#include "Vvsp_uword_cluster_program_wrapper.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint32_t kBasePc = 0x20;
constexpr uint8_t kExec = 0;
constexpr uint8_t kMemory = 1;
constexpr uint8_t kControl = 2;
constexpr uint8_t kStatusOk = 0;
constexpr uint8_t kStatusDecode = 1;
constexpr uint8_t kLoad = 0;
constexpr uint8_t kStore = 1;
constexpr uint8_t kLocal = 0;
constexpr uint8_t kBadSubop = 2;
constexpr uint8_t kBadExtension = 4;
constexpr uint8_t kBadImmediate = 5;

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

void eval_low(Vvsp_uword_cluster_program_wrapper& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Vvsp_uword_cluster_program_wrapper& dut) {
  eval_low(dut);
  dut.clk_i = 1;
  dut.eval();
  dut.clk_i = 0;
  dut.eval();
}

void clear_inputs(Vvsp_uword_cluster_program_wrapper& dut) {
  dut.store_write_valid_i = 0;
  dut.store_write_pc_i = 0;
  dut.store_write_data_i = 0;
  dut.start_valid_i = 0;
  dut.start_pc_i = 0;
  dut.end_pc_i = 0;
  dut.start_context_i = 0;
  dut.start_group_mask_i = 0;
  dut.start_tag_seed_i = 0;
  dut.action_cpl_ready_i = 1;
  dut.exec_result_ready_i = 1;
  dut.dmem_req_ready_i = 1;
  dut.dmem_rsp_valid_i = 0;
  dut.dmem_rsp_rdata_i = 0;
  dut.dmem_rsp_fault_cause_i = 0;
  dut.protocol_error_clear_i = 0;
}

void reset(Vvsp_uword_cluster_program_wrapper& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  for (int cycle = 0; cycle < 3; ++cycle) tick(dut);
  dut.rst_ni = 1;
  tick(dut);
  expect_eq("reset program inactive", 0, dut.program_active_o);
  expect_eq("reset program error clear", 0, dut.program_error_o);
}

std::vector<uint32_t> read_hex(const std::string& path) {
  std::ifstream input(path);
  if (!input) throw std::runtime_error("cannot open generated hex: " + path);
  std::vector<uint32_t> words;
  std::string line;
  while (std::getline(input, line)) {
    if (!line.empty())
      words.push_back(static_cast<uint32_t>(std::stoul(line, nullptr, 16)));
  }
  return words;
}

void wait_start_ready(Vvsp_uword_cluster_program_wrapper& dut) {
  for (int cycle = 0; cycle < 80; ++cycle) {
    eval_low(dut);
    if (dut.start_ready_o) return;
    tick(dut);
  }
  fail("start ready timeout", 1, dut.start_ready_o);
}

void program_store_at(Vvsp_uword_cluster_program_wrapper& dut,
                      uint32_t base_pc,
                      const std::vector<uint32_t>& words) {
  for (size_t index = 0; index < words.size(); ++index) {
    for (int cycle = 0; cycle < 80; ++cycle) {
      dut.store_write_valid_i = 1;
      dut.store_write_pc_i = base_pc + static_cast<uint32_t>(4 * index);
      dut.store_write_data_i = words[index];
      eval_low(dut);
      if (dut.store_write_ready_o) break;
      tick(dut);
      if (cycle == 79) fail("store write ready timeout", 1, 0);
    }
    tick(dut);
    dut.store_write_valid_i = 0;
  }
}

void program_store(Vvsp_uword_cluster_program_wrapper& dut,
                   const std::vector<uint32_t>& words) {
  program_store_at(dut, kBasePc, words);
}

void launch_range(Vvsp_uword_cluster_program_wrapper& dut,
                  uint32_t start_pc, uint32_t end_pc, uint8_t context,
                  uint8_t group_mask, uint8_t tag_seed) {
  wait_start_ready(dut);
  dut.start_valid_i = 1;
  dut.start_pc_i = start_pc;
  dut.end_pc_i = end_pc;
  dut.start_context_i = context;
  dut.start_group_mask_i = group_mask;
  dut.start_tag_seed_i = tag_seed;
  eval_low(dut);
  expect_eq("launch ready", 1, dut.start_ready_o);
  tick(dut);
  dut.start_valid_i = 0;

  // Prove that the launch envelope, rather than live input pins, owns every
  // later action.
  dut.start_context_i = context ^ 1U;
  dut.start_group_mask_i = 0xa;
  dut.start_tag_seed_i = 0xee;
}

void launch(Vvsp_uword_cluster_program_wrapper& dut, uint32_t end_pc,
            uint8_t context, uint8_t group_mask, uint8_t tag_seed) {
  launch_range(dut, kBasePc, end_pc, context, group_mask, tag_seed);
}

struct Completion {
  uint8_t action_class;
  uint8_t context;
  uint8_t tag;
  uint8_t group_mask;
  uint8_t status;
  uint8_t decode_error;
  bool end;
};

void expect_completion_stable(const Completion& expected,
                              const Completion& actual) {
  expect_eq("stalled completion class", expected.action_class,
            actual.action_class);
  expect_eq("stalled completion context", expected.context, actual.context);
  expect_eq("stalled completion tag", expected.tag, actual.tag);
  expect_eq("stalled completion group mask", expected.group_mask,
            actual.group_mask);
  expect_eq("stalled completion status", expected.status, actual.status);
  expect_eq("stalled completion decode error", expected.decode_error,
            actual.decode_error);
  expect_eq("stalled completion END", expected.end, actual.end);
}

struct Result {
  uint8_t group;
  uint8_t context;
  uint8_t tag;
  uint32_t narrow;
  uint8_t narrow_mask;
};

struct DmemRequest {
  uint8_t op = 0;
  uint32_t eaddr = 0;
  uint8_t addr_space = 0;
  uint8_t addr_context = 0;
  uint32_t wdata = 0;
  uint8_t wstrb = 0;
};

struct DmemModel {
  std::array<uint8_t, 512> bytes{};
  bool response_pending = false;
  int response_delay = 0;
  uint32_t response_data = 0;
  uint8_t response_fault = 0;
  bool held_request_valid = false;
  DmemRequest held_request;
  std::vector<DmemRequest> requests;
};

struct Run {
  bool done = false;
  bool failed = false;
  bool error = false;
  uint64_t dmem_requests = 0;
  std::vector<Completion> completions;
  std::vector<Result> results;
};

void check_dmem_request(const DmemRequest& expected,
                        const DmemRequest& actual,
                        const std::string& name) {
  expect_eq(name + " op", expected.op, actual.op);
  expect_eq(name + " eaddr", expected.eaddr, actual.eaddr);
  expect_eq(name + " address space", expected.addr_space,
            actual.addr_space);
  expect_eq(name + " address context", expected.addr_context,
            actual.addr_context);
  expect_eq(name + " write data", expected.wdata, actual.wdata);
  expect_eq(name + " write strobe", expected.wstrb, actual.wstrb);
}

DmemRequest sample_dmem_request(
    const Vvsp_uword_cluster_program_wrapper& dut) {
  return {static_cast<uint8_t>(dut.dmem_req_op_o),
          static_cast<uint32_t>(dut.dmem_req_eaddr_o),
          static_cast<uint8_t>(dut.dmem_req_addr_space_o),
          static_cast<uint8_t>(dut.dmem_req_addr_context_o),
          static_cast<uint32_t>(dut.dmem_req_wdata_o),
          static_cast<uint8_t>(dut.dmem_req_wstrb_o)};
}

void update_dmem_model(DmemModel& model, bool request_fire,
                       const DmemRequest& request, bool response_fire) {
  if (response_fire) model.response_pending = false;
  if (model.response_pending && model.response_delay > 0)
    --model.response_delay;

  if (request_fire) {
    expect_eq("data-memory remains single-outstanding", 0,
              model.response_pending);
    model.requests.push_back(request);
    model.response_pending = true;
    model.response_delay = 2;
    model.response_fault = 0;
    if (request.op == kLoad) {
      model.response_data = load_word(model.bytes, request.eaddr);
    } else {
      store_word(model.bytes, request.eaddr, request.wdata, request.wstrb);
      model.response_data = 0;
    }
  }
}

Run run_until_terminal(Vvsp_uword_cluster_program_wrapper& dut,
                       DmemModel* dmem = nullptr) {
  Run run;
  bool held_completion_valid = false;
  Completion held_completion{};
  for (int cycle = 0; cycle < 800; ++cycle) {
    // Exercise multi-cycle completion backpressure without changing stream
    // order, and check the unified state/cluster mux holds every field.
    dut.action_cpl_ready_i = (cycle % 7) >= 3;
    dut.exec_result_ready_i = (cycle % 4) != 1;
    dut.dmem_req_ready_i = dmem == nullptr || (cycle % 3) != 1;
    dut.dmem_rsp_valid_i =
        dmem != nullptr && dmem->response_pending &&
        dmem->response_delay == 0;
    dut.dmem_rsp_rdata_i =
        dmem != nullptr ? dmem->response_data : 0;
    dut.dmem_rsp_fault_cause_i =
        dmem != nullptr ? dmem->response_fault : 0;
    eval_low(dut);

    const Completion visible_completion = {
        static_cast<uint8_t>(dut.action_cpl_class_o),
        static_cast<uint8_t>(dut.action_cpl_context_o),
        static_cast<uint8_t>(dut.action_cpl_tag_o),
        static_cast<uint8_t>(dut.action_cpl_group_mask_o),
        static_cast<uint8_t>(dut.action_cpl_status_o),
        static_cast<uint8_t>(dut.action_cpl_decode_error_o),
        static_cast<bool>(dut.action_cpl_end_o)};
    if (held_completion_valid) {
      expect_eq("stalled completion remains valid", 1,
                dut.action_cpl_valid_o);
      expect_completion_stable(held_completion, visible_completion);
    }
    if (dut.action_cpl_valid_o && !dut.action_cpl_ready_i &&
        !held_completion_valid) {
      held_completion_valid = true;
      held_completion = visible_completion;
    }

    if (dmem != nullptr && dmem->held_request_valid) {
      expect_eq("stalled data-memory request remains valid", 1,
                dut.dmem_req_valid_o);
      check_dmem_request(dmem->held_request, sample_dmem_request(dut),
                         "stalled data-memory request remains stable");
    }

    const bool request_fire =
        dut.dmem_req_valid_o && dut.dmem_req_ready_i;
    const bool response_fire =
        dut.dmem_rsp_valid_i && dut.dmem_rsp_ready_o;
    const DmemRequest request = sample_dmem_request(dut);
    if (dmem != nullptr && dut.dmem_req_valid_o &&
        !dut.dmem_req_ready_i && !dmem->held_request_valid) {
      dmem->held_request_valid = true;
      dmem->held_request = request;
    }
    if (dmem != nullptr && request_fire)
      dmem->held_request_valid = false;

    if (dut.action_cpl_valid_o && dut.action_cpl_ready_i) {
      run.completions.push_back(
          {static_cast<uint8_t>(dut.action_cpl_class_o),
           static_cast<uint8_t>(dut.action_cpl_context_o),
           static_cast<uint8_t>(dut.action_cpl_tag_o),
           static_cast<uint8_t>(dut.action_cpl_group_mask_o),
           static_cast<uint8_t>(dut.action_cpl_status_o),
           static_cast<uint8_t>(dut.action_cpl_decode_error_o),
           static_cast<bool>(dut.action_cpl_end_o)});
      held_completion_valid = false;
    }
    if (dut.exec_result_valid_o && dut.exec_result_ready_i) {
      run.results.push_back(
          {static_cast<uint8_t>(dut.exec_result_group_o),
           static_cast<uint8_t>(dut.exec_result_context_o),
           static_cast<uint8_t>(dut.exec_result_tag_o),
           static_cast<uint32_t>(dut.exec_result_narrow_o),
           static_cast<uint8_t>(dut.exec_result_narrow_mask_o)});
    }
    if (request_fire)
      ++run.dmem_requests;
    if (dut.program_done_o) run.done = true;
    if (dut.program_failed_o) run.failed = true;
    run.error = dut.program_error_o;

    if ((run.done || run.failed) && !dut.program_active_o) {
      tick(dut);
      if (dmem != nullptr)
        update_dmem_model(*dmem, request_fire, request, response_fire);
      dut.action_cpl_ready_i = 1;
      dut.exec_result_ready_i = 1;
      dut.dmem_req_ready_i = 1;
      dut.dmem_rsp_valid_i = 0;
      return run;
    }
    tick(dut);
    if (dmem != nullptr)
      update_dmem_model(*dmem, request_fire, request, response_fire);
  }
  fail("program terminal timeout", 1, 0);
}

void check_completion(const Completion& actual, uint8_t action_class,
                      uint8_t context, uint8_t tag, uint8_t group_mask,
                      uint8_t status, uint8_t decode_error, bool end,
                      const std::string& name) {
  expect_eq(name + " class", action_class, actual.action_class);
  expect_eq(name + " context", context, actual.context);
  expect_eq(name + " tag", tag, actual.tag);
  expect_eq(name + " group mask", group_mask, actual.group_mask);
  expect_eq(name + " status", status, actual.status);
  expect_eq(name + " decode error", decode_error, actual.decode_error);
  expect_eq(name + " END", end, actual.end);
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 3) {
    std::cerr << "usage: " << argv[0]
              << " EXEC_PROGRAM.hex MEMORY_STATE_PROGRAM.hex\n";
    return 2;
  }

  const std::vector<uint32_t> program = read_hex(argv[1]);
  const std::vector<uint32_t> golden = {
      0x17822210U, 0x10020430U, 0x00000007U, 0xc0000000U};
  if (program != golden) {
    std::cerr << "generated executable example differs from golden\n";
    return 1;
  }

  const std::vector<uint32_t> memory_state_program = read_hex(argv[2]);
  const std::vector<uint32_t> memory_state_golden = {
      0xc4080000U, 0x00000100U, 0xc4100000U, 0x00000004U,
      0xc1184400U, 0xc620c000U, 0xfffffff8U, 0xb4151048U,
      0x00000004U, 0x10020430U, 0x00000001U, 0xb6150c88U,
      0x00000000U, 0xc0000000U};
  if (memory_state_program != memory_state_golden) {
    std::cerr << "generated MEMORY/state example differs from golden\n";
    return 1;
  }

  Vvsp_uword_cluster_program_wrapper dut;
  reset(dut);

  program_store(dut, program);
  launch(dut, kBasePc + static_cast<uint32_t>(4 * program.size()),
         0, 0x5, 0x40);
  Run normal = run_until_terminal(dut);
  expect_eq("normal completed", 1, normal.done);
  expect_eq("normal did not fail", 0, normal.failed);
  expect_eq("normal has no accumulated error", 0, normal.error);
  expect_eq("normal completion count", 3, normal.completions.size());
  for (size_t index = 0; index < 2; ++index) {
    check_completion(normal.completions[index], kExec, 0,
                     static_cast<uint8_t>(0x40 + index), 0x5,
                     kStatusOk, 0, false,
                     "normal EXEC " + std::to_string(index));
  }
  check_completion(normal.completions[2], kControl, 0, 0x42, 0,
                   kStatusOk, 0, true, "normal END");
  expect_eq("normal EXEC stream has no implicit export", 0,
            normal.results.size());
  expect_eq("normal issued no data-memory request", 0,
            normal.dmem_requests);

  // Exercise the reverse engine boundary as well: a cluster EXEC completion
  // must retire before the following sequencer-local state command can fire.
  const std::vector<uint32_t> exec_then_state = {
      0x10000010U, 0xc4280000U, 0x00000200U, 0xc0000000U};
  program_store(dut, exec_then_state);
  launch(dut, kBasePc + 16, 0, 0x1, 0x44);
  Run reverse_order = run_until_terminal(dut);
  expect_eq("EXEC then state completed", 1, reverse_order.done);
  expect_eq("EXEC then state has no error", 0, reverse_order.error);
  expect_eq("EXEC then state completion count", 3,
            reverse_order.completions.size());
  check_completion(reverse_order.completions[0], kExec, 0, 0x44, 0x1,
                   kStatusOk, 0, false, "reverse-order EXEC");
  check_completion(reverse_order.completions[1], kControl, 0, 0x45, 0,
                   kStatusOk, 0, false, "reverse-order SMOVI");
  check_completion(reverse_order.completions[2], kControl, 0, 0x46, 0,
                   kStatusOk, 0, true, "reverse-order END");

  // State records construct both addresses, the load feeds VRF1, EXEC adds
  // one to each byte into VRF2, and the store returns the transformed row.
  program_store(dut, memory_state_program);
  launch(dut,
         kBasePc + static_cast<uint32_t>(4 * memory_state_program.size()),
         0, 0x1, 0x48);
  DmemModel dmem;
  store_word(dmem.bytes, 0x100, 0x04030201U, 0xf);
  Run memory_state = run_until_terminal(dut, &dmem);
  expect_eq("MEMORY/state program completed", 1, memory_state.done);
  expect_eq("MEMORY/state program did not fail", 0, memory_state.failed);
  expect_eq("MEMORY/state program has no accumulated error", 0,
            memory_state.error);
  expect_eq("MEMORY/state completion count", 8,
            memory_state.completions.size());
  for (size_t index = 0; index < 4; ++index) {
    check_completion(memory_state.completions[index], kControl, 0,
                     static_cast<uint8_t>(0x48 + index), 0,
                     kStatusOk, 0, false,
                     "state CONTROL " + std::to_string(index));
  }
  check_completion(memory_state.completions[4], kMemory, 0, 0x4c, 0x1,
                   kStatusOk, 0, false, "semantic VLOAD");
  check_completion(memory_state.completions[5], kExec, 0, 0x4d, 0x1,
                   kStatusOk, 0, false, "loaded-row EXEC");
  check_completion(memory_state.completions[6], kMemory, 0, 0x4e, 0x1,
                   kStatusOk, 0, false, "semantic VSTORE");
  check_completion(memory_state.completions[7], kControl, 0, 0x4f, 0,
                   kStatusOk, 0, true, "MEMORY/state END");
  expect_eq("MEMORY/state exports no EXEC result", 0,
            memory_state.results.size());
  expect_eq("MEMORY/state request count", 2, memory_state.dmem_requests);
  expect_eq("data-memory model captured both requests", 2,
            dmem.requests.size());
  check_dmem_request({kLoad, 0x100, kLocal, 0x2a, 0, 0},
                     dmem.requests[0], "semantic VLOAD request");
  check_dmem_request({kStore, 0x104, kLocal, 0x2a,
                      0x05040302U, 0xf},
                     dmem.requests[1], "semantic VSTORE request");
  expect_eq("semantic VSTORE updates memory model", 0x05040302U,
            load_word(dmem.bytes, 0x104));
  expect_eq("no response remains after MEMORY/state END", 0,
            dmem.response_pending);

  // Indexed MEMORY records replace the former register-route instruction.
  // VLOAD seeds row 1 with byte offsets {3,0,7,4}; VGATHER reads those four
  // bytes into row 2, and VSCATTER writes them to the same offsets in a new
  // 256-byte address window.
  const std::vector<uint32_t> indexed_memory_program = {
      0xc4080000U, 0x00000100U,
      0xb4150448U, 0x00000020U,
      0xb4150485U, 0x00000000U,
      0xb6150485U, 0x00000040U,
      0xc0000000U};
  program_store(dut, indexed_memory_program);
  launch(dut,
         kBasePc + static_cast<uint32_t>(4 * indexed_memory_program.size()),
         0, 0x1, 0x50);
  DmemModel indexed_dmem;
  store_word(indexed_dmem.bytes, 0x100, 0x44332211U, 0xf);
  store_word(indexed_dmem.bytes, 0x104, 0x88776655U, 0xf);
  store_word(indexed_dmem.bytes, 0x120, 0x04070003U, 0xf);
  Run indexed_memory = run_until_terminal(dut, &indexed_dmem);
  expect_eq("indexed MEMORY program completed", 1, indexed_memory.done);
  expect_eq("indexed MEMORY program did not fail", 0,
            indexed_memory.failed);
  expect_eq("indexed MEMORY program has no accumulated error", 0,
            indexed_memory.error);
  expect_eq("indexed MEMORY completion count", 5,
            indexed_memory.completions.size());
  check_completion(indexed_memory.completions[0], kControl, 0, 0x50, 0,
                   kStatusOk, 0, false, "indexed base SMOVI");
  check_completion(indexed_memory.completions[1], kMemory, 0, 0x51, 0x1,
                   kStatusOk, 0, false, "index-row VLOAD");
  check_completion(indexed_memory.completions[2], kMemory, 0, 0x52, 0x1,
                   kStatusOk, 0, false, "semantic VGATHER");
  check_completion(indexed_memory.completions[3], kMemory, 0, 0x53, 0x1,
                   kStatusOk, 0, false, "semantic VSCATTER");
  check_completion(indexed_memory.completions[4], kControl, 0, 0x54, 0,
                   kStatusOk, 0, true, "indexed MEMORY END");
  expect_eq("indexed MEMORY has no EXEC result", 0,
            indexed_memory.results.size());
  expect_eq("indexed MEMORY request count", 9,
            indexed_memory.dmem_requests);
  expect_eq("indexed data-memory model captured every request", 9,
            indexed_dmem.requests.size());
  check_dmem_request({kLoad, 0x120, kLocal, 0x2a, 0, 0},
                     indexed_dmem.requests[0], "index-row VLOAD request");
  check_dmem_request({kLoad, 0x100, kLocal, 0x2a, 0, 0},
                     indexed_dmem.requests[1], "VGATHER lane 0 request");
  check_dmem_request({kLoad, 0x100, kLocal, 0x2a, 0, 0},
                     indexed_dmem.requests[2], "VGATHER lane 1 request");
  check_dmem_request({kLoad, 0x104, kLocal, 0x2a, 0, 0},
                     indexed_dmem.requests[3], "VGATHER lane 2 request");
  check_dmem_request({kLoad, 0x104, kLocal, 0x2a, 0, 0},
                     indexed_dmem.requests[4], "VGATHER lane 3 request");
  check_dmem_request({kStore, 0x140, kLocal, 0x2a,
                      0x44000000U, 0x8},
                     indexed_dmem.requests[5], "VSCATTER lane 0 request");
  check_dmem_request({kStore, 0x140, kLocal, 0x2a,
                      0x00000011U, 0x1},
                     indexed_dmem.requests[6], "VSCATTER lane 1 request");
  check_dmem_request({kStore, 0x144, kLocal, 0x2a,
                      0x88000000U, 0x8},
                     indexed_dmem.requests[7], "VSCATTER lane 2 request");
  check_dmem_request({kStore, 0x144, kLocal, 0x2a,
                      0x00000055U, 0x1},
                     indexed_dmem.requests[8], "VSCATTER lane 3 request");
  expect_eq("VSCATTER lower destination word", 0x44000011U,
            load_word(indexed_dmem.bytes, 0x140));
  expect_eq("VSCATTER upper destination word", 0x88000055U,
            load_word(indexed_dmem.bytes, 0x144));
  expect_eq("no response remains after indexed MEMORY END", 0,
            indexed_dmem.response_pending);

  // UNIT_STRIDE span code zero expands at the action boundary to four bytes
  // for every launch-selected group.  A sparse {G2,G0} mask therefore moves
  // eight compact bytes without encoding the unrepresentable literal 64.
  const std::vector<uint32_t> full_selected_span_program = {
      0xc4080000U, 0x00000180U,
      0xb4000580U, 0x00000000U,
      0xb6000580U, 0x00000020U,
      0xc0000000U};
  program_store(dut, full_selected_span_program);
  launch(dut,
         kBasePc +
             static_cast<uint32_t>(4 * full_selected_span_program.size()),
         0, 0x5, 0x58);
  DmemModel full_span_dmem;
  store_word(full_span_dmem.bytes, 0x180, 0x04030201U, 0xf);
  store_word(full_span_dmem.bytes, 0x184, 0x08070605U, 0xf);
  Run full_span = run_until_terminal(dut, &full_span_dmem);
  expect_eq("full-selected span program completed", 1, full_span.done);
  expect_eq("full-selected span program did not fail", 0,
            full_span.failed);
  expect_eq("full-selected span program has no accumulated error", 0,
            full_span.error);
  expect_eq("full-selected span completion count", 4,
            full_span.completions.size());
  check_completion(full_span.completions[0], kControl, 0, 0x58, 0,
                   kStatusOk, 0, false, "full-span SMOVI");
  check_completion(full_span.completions[1], kMemory, 0, 0x59, 0x5,
                   kStatusOk, 0, false, "full-span VLOAD");
  check_completion(full_span.completions[2], kMemory, 0, 0x5a, 0x5,
                   kStatusOk, 0, false, "full-span VSTORE");
  check_completion(full_span.completions[3], kControl, 0, 0x5b, 0,
                   kStatusOk, 0, true, "full-span END");
  expect_eq("full-selected span request count", 4,
            full_span.dmem_requests);
  expect_eq("full-selected span captured every request", 4,
            full_span_dmem.requests.size());
  check_dmem_request({kLoad, 0x180, kLocal, 0, 0, 0},
                     full_span_dmem.requests[0],
                     "full-span VLOAD group 0 request");
  check_dmem_request({kLoad, 0x184, kLocal, 0, 0, 0},
                     full_span_dmem.requests[1],
                     "full-span VLOAD group 2 request");
  check_dmem_request({kStore, 0x1a0, kLocal, 0,
                      0x04030201U, 0xf},
                     full_span_dmem.requests[2],
                     "full-span VSTORE group 0 request");
  check_dmem_request({kStore, 0x1a4, kLocal, 0,
                      0x08070605U, 0xf},
                     full_span_dmem.requests[3],
                     "full-span VSTORE group 2 request");
  expect_eq("full-selected span lower destination word", 0x04030201U,
            load_word(full_span_dmem.bytes, 0x1a0));
  expect_eq("full-selected span upper destination word", 0x08070605U,
            load_word(full_span_dmem.bytes, 0x1a4));
  expect_eq("no response remains after full-selected span END", 0,
            full_span_dmem.response_pending);

  // An exact END-looking word in an opaque MEMORY body is data, not a header.
  // The MEMORY parent rejects in order, then the following real END retires.
  const std::vector<uint32_t> opaque_memory = {
      0xb4000000U, 0xc0000000U, 0xc0000000U};
  program_store(dut, opaque_memory);
  launch(dut, kBasePc + 12, 0, 0x3, 0x60);
  Run memory = run_until_terminal(dut);
  expect_eq("opaque memory reaches later END", 1, memory.done);
  expect_eq("opaque memory does not terminal-fail", 0, memory.failed);
  expect_eq("opaque memory accumulates rejection", 1, memory.error);
  expect_eq("opaque memory completion count", 2, memory.completions.size());
  check_completion(memory.completions[0], kMemory, 0, 0x60, 0x3,
                   kStatusDecode, kBadImmediate, false, "opaque MEMORY");
  check_completion(memory.completions[1], kControl, 0, 0x61, 0,
                   kStatusOk, 0, true, "opaque MEMORY following END");
  expect_eq("rejected memory issued no dmem request", 0,
            memory.dmem_requests);

  // C0000001 shares the CONTROL major but is neither canonical END nor the
  // required two-word shape of its numerically selected SMOVI sub-operation.
  const std::vector<uint32_t> other_control = {
      0xc0000001U, 0xc0000000U};
  program_store(dut, other_control);
  launch(dut, kBasePc + 8, 0, 0x1, 0x70);
  Run control = run_until_terminal(dut);
  expect_eq("other CONTROL reaches real END", 1, control.done);
  expect_eq("other CONTROL completion count", 2,
            control.completions.size());
  check_completion(control.completions[0], kControl, 0, 0x70, 0,
                   kStatusDecode, kBadExtension, false, "other CONTROL");
  check_completion(control.completions[1], kControl, 0, 0x71, 0,
                   kStatusOk, 0, true, "other CONTROL following END");

  // A base word whose extension lies beyond end_pc is emitted as a truncated
  // record, rejected in order, then closes as a missing-END failure.
  const std::vector<uint32_t> truncated = {0x10020430U};
  program_store(dut, truncated);
  launch(dut, kBasePc + 4, 0, 0xf, 0x80);
  Run short_exec = run_until_terminal(dut);
  expect_eq("truncated EXEC has no END completion", 0, short_exec.done);
  expect_eq("truncated EXEC fails drained program", 1, short_exec.failed);
  expect_eq("truncated EXEC completion count", 1,
            short_exec.completions.size());
  check_completion(short_exec.completions[0], kExec, 0, 0x80, 0xf,
                   kStatusDecode, kBadExtension, false,
                   "truncated EXEC");

  // A legal empty byte range contains no END and must fail rather than leave
  // the wrapper permanently active.
  launch(dut, kBasePc, 0, 0x5, 0x90);
  Run empty = run_until_terminal(dut);
  expect_eq("empty range not done", 0, empty.done);
  expect_eq("empty range fails", 1, empty.failed);
  expect_eq("empty range has no completion", 0, empty.completions.size());

  // END is required to be the final record in [start_pc,end_pc).  The early
  // END is rejected, younger words are drained without entering EXEC, and the
  // program reports failure.
  const std::vector<uint32_t> early_end = {
      0xc0000000U, 0x17822210U};
  program_store(dut, early_end);
  launch(dut, kBasePc + 8, 0, 0x5, 0xa0);
  Run early = run_until_terminal(dut);
  expect_eq("early END not successful", 0, early.done);
  expect_eq("early END fails", 1, early.failed);
  expect_eq("early END completion count", 1, early.completions.size());
  check_completion(early.completions[0], kControl, 0, 0xa0, 0,
                   kStatusDecode, kBadSubop, false, "early END");
  expect_eq("younger EXEC after early END not executed", 0,
            early.results.size());

  // The local store ends at 0x60 in this test configuration.  Three complete
  // EXEC records at 0x50 precede a four-word MEMORY header at
  // 0x5c whose body would require a fetch at 0x60.  That fetch faults: all
  // three older records still retire in order, the incomplete tail is
  // aborted, and the frontend becomes restartable.
  const std::vector<uint32_t> faulting_tail = {
      0x17822210U, 0x17822210U, 0x17822210U, 0xbc000000U};
  program_store_at(dut, 0x50, faulting_tail);
  launch_range(dut, 0x50, 0x6c, 0, 0x4, 0xb0);
  Run fetch_fault = run_until_terminal(dut);
  expect_eq("cross-bundle fetch fault not done", 0, fetch_fault.done);
  expect_eq("cross-bundle fetch fault fails", 1, fetch_fault.failed);
  expect_eq("older complete actions survive fetch fault", 3,
            fetch_fault.completions.size());
  for (size_t index = 0; index < 3; ++index) {
    check_completion(fetch_fault.completions[index], kExec, 0,
                     static_cast<uint8_t>(0xb0 + index), 0x4,
                     kStatusOk, 0, false,
                     "pre-fault EXEC " + std::to_string(index));
  }

  const std::vector<uint32_t> end_only = {0xc0000000U};
  program_store(dut, end_only);
  launch(dut, kBasePc + 4, 0, 0x1, 0xc0);
  Run recovered = run_until_terminal(dut);
  expect_eq("restart after fetch fault completes", 1, recovered.done);
  expect_eq("restart after fetch fault does not fail", 0,
            recovered.failed);
  expect_eq("restart after fetch fault clears launch error", 0,
            recovered.error);
  expect_eq("restart END completion count", 1,
            recovered.completions.size());
  check_completion(recovered.completions[0], kControl, 0, 0xc0, 0,
                   kStatusOk, 0, true, "restart END");

  dut.final();
  std::cout << "vsp_uword_cluster_program_wrapper_tb: " << std::dec << checks
            << " executable-stream, END, rejection and drain checks passed\n";
  return 0;
}
