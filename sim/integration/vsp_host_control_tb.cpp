// SPDX-License-Identifier: MIT

#include "Vvsp_host_control_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using Dut = Vvsp_host_control_tb_top;
enum Register : std::uint16_t {
  ID = 0x000, VERSION = 0x004, STATUS = 0x008, COMMAND = 0x00c,
  START_PC = 0x010, END_PC = 0x014, GROUP_MASK = 0x018,
  FETCH_CONTEXT = 0x01c, TAG_SEED = 0x020, IRQ_ENABLE = 0x024,
  IRQ_PENDING = 0x028, FETCH_PC = 0x02c, RESULT_STATUS = 0x030,
  TERMINAL_PC = 0x034, ACTION_COUNT = 0x038, FIRST_ERROR_INFO = 0x03c,
  FIRST_ERROR_TAG = 0x040, MEM_FAULT_INFO = 0x044, MEM_FAULT_EADDR = 0x048,
  MEM_MASKS = 0x04c, MEM_FAILED_MASK = 0x050, MEM_BYTES = 0x054,
  IFETCH_INFO = 0x058, IFETCH_EADDR = 0x05c, IFETCH_PADDR_LO = 0x060,
  IFETCH_PADDR_HI = 0x064, MMU_CONTEXT = 0x070, MMU_FIELD = 0x074,
  MMU_WDATA = 0x078, MMU_RDATA = 0x07c, MGMT_STATUS = 0x080,
  MAINT_OP = 0x084, MAINT_EADDR = 0x088, MAINT_PADDR_LO = 0x08c,
  MAINT_PADDR_HI = 0x090, MAINT_CONTEXT = 0x094, MAINT_ASID = 0x098
};
enum Command : std::uint32_t {
  START = 1, ACK_RESULT = 2, MMU_READ = 3, MMU_WRITE = 4,
  MAINTENANCE = 5, CLEAR_PROTOCOL = 6
};

constexpr std::array<Register, 14> kResultRegisters = {
    RESULT_STATUS, TERMINAL_PC, ACTION_COUNT, FIRST_ERROR_INFO,
    FIRST_ERROR_TAG, MEM_FAULT_INFO, MEM_FAULT_EADDR, MEM_MASKS,
    MEM_FAILED_MASK, MEM_BYTES, IFETCH_INFO, IFETCH_EADDR,
    IFETCH_PADDR_LO, IFETCH_PADDR_HI};

std::uint64_t checks = 0;
std::uint64_t cycles = 0;

[[noreturn]] void fail(const std::string& label, std::uint64_t expected,
                       std::uint64_t actual) {
  std::cerr << "FAIL cycle=" << cycles << " " << label
            << " expected=0x" << std::hex << expected << " actual=0x"
            << actual << std::dec << '\n';
  std::exit(EXIT_FAILURE);
}

void expect(const std::string& label, std::uint64_t expected,
            std::uint64_t actual) {
  ++checks;
  if (expected != actual) fail(label, expected, actual);
}

struct Bench {
  Dut dut;
  unsigned starts = 0;
  unsigned mmu_requests = 0;
  unsigned maintenance_requests = 0;
  unsigned protocol_clears = 0;
  bool start_stalled = false;
  bool mmu_stalled = false;
  bool maintenance_stalled = false;
  std::array<std::uint64_t, 6> start_snapshot{};
  std::array<std::uint64_t, 4> mmu_snapshot{};
  std::array<std::uint64_t, 5> maintenance_snapshot{};

  void eval() {
    dut.clk_i = 0;
    dut.eval();
  }

  template <std::size_t N>
  void check_stall(const std::string& label, bool valid, bool ready,
                   const std::array<std::uint64_t, N>& payload,
                   bool& stalled, std::array<std::uint64_t, N>& snapshot) {
    if (stalled) {
      expect(label + " holds valid until handshake", 1, valid);
      for (std::size_t i = 0; i < N; ++i)
        expect(label + " holds payload field " + std::to_string(i),
               snapshot[i], payload[i]);
    }
    stalled = valid && !ready;
    snapshot = payload;
  }

  void tick() {
    eval();
    if (dut.rst_ni) {
      check_stall("START", dut.start_valid_o, dut.start_ready_i,
                  std::array<std::uint64_t, 6>{dut.start_pc_o, dut.end_pc_o,
                      dut.start_group_mask_o, dut.start_tag_seed_o,
                      dut.start_ifetch_addr_space_o,
                      dut.start_ifetch_addr_context_o},
                  start_stalled, start_snapshot);
      check_stall("MMU", dut.mmu_cfg_valid_o, dut.mmu_cfg_ready_i,
                  std::array<std::uint64_t, 4>{dut.mmu_cfg_write_o,
                      dut.mmu_cfg_context_o, dut.mmu_cfg_field_o,
                      dut.mmu_cfg_wdata_o}, mmu_stalled, mmu_snapshot);
      check_stall("maintenance", dut.maint_cmd_valid_o, dut.maint_cmd_ready_i,
                  std::array<std::uint64_t, 5>{dut.maint_cmd_op_o,
                      dut.maint_cmd_eaddr_o, dut.maint_cmd_paddr_o,
                      dut.maint_cmd_addr_context_o, dut.maint_cmd_asid_o},
                  maintenance_stalled, maintenance_snapshot);
      starts += dut.start_valid_o && dut.start_ready_i;
      mmu_requests += dut.mmu_cfg_valid_o && dut.mmu_cfg_ready_i;
      maintenance_requests += dut.maint_cmd_valid_o && dut.maint_cmd_ready_i;
      protocol_clears += dut.protocol_error_clear_o;
    } else {
      start_stalled = mmu_stalled = maintenance_stalled = false;
    }
    dut.clk_i = 1;
    dut.eval();
    ++cycles;
    if (cycles > 20000) fail("global cycle timeout", 20000, cycles);
    eval();
  }

  void reset() {
    dut.mmio_req_valid_i = 0;
    dut.mmio_req_write_i = 0;
    dut.mmio_req_addr_i = 0;
    dut.mmio_req_wdata_i = 0;
    dut.mmio_req_wstrb_i = 0;
    dut.mmio_rsp_ready_i = 0;
    dut.start_ready_i = 0;
    dut.fetch_pc_i = 0;
    dut.program_active_i = 0;
    dut.program_done_i = 0;
    dut.program_failed_i = 0;
    dut.program_error_i = 0;
    dut.program_terminal_pc_i = 0;
    dut.system_ready_i = 1;
    dut.system_quiescent_i = 1;
    dut.system_busy_i = 0;
    dut.ifetch_fault_valid_i = 0;
    dut.ifetch_fault_cause_i = 0;
    dut.ifetch_fault_eaddr_i = 0;
    dut.ifetch_fault_paddr_i = 0;
    dut.ifetch_fault_addr_space_i = 0;
    dut.ifetch_fault_addr_context_i = 0;
    dut.action_cpl_valid_i = 0;
    dut.action_cpl_class_i = 0;
    dut.action_cpl_tag_i = 0;
    dut.action_cpl_status_i = 0;
    dut.action_cpl_decode_error_i = 0;
    dut.action_cpl_memory_op_i = 0;
    dut.action_cpl_memory_status_i = 0;
    dut.action_cpl_memory_fault_cause_i = 0;
    dut.action_cpl_memory_fault_eaddr_i = 0;
    dut.action_cpl_memory_requested_group_mask_i = 0;
    dut.action_cpl_memory_completed_group_mask_i = 0;
    dut.action_cpl_memory_failed_group_mask_i = 0;
    dut.action_cpl_memory_bytes_committed_i = 0;
    dut.action_cpl_memory_partial_i = 0;
    dut.mmu_cfg_ready_i = 0;
    dut.mmu_cfg_rsp_valid_i = 0;
    dut.mmu_cfg_rsp_rdata_i = 0;
    dut.mmu_cfg_rsp_status_i = 0;
    dut.maint_cmd_ready_i = 0;
    dut.maint_cpl_valid_i = 0;
    dut.maint_cpl_status_i = 0;
    dut.maint_cpl_fault_i = 0;
    dut.rst_ni = 0;
    tick();
    tick();
    expect("reset MMIO response", 0, dut.mmio_rsp_valid_o);
    expect("reset START request", 0, dut.start_valid_o);
    expect("reset MMU request", 0, dut.mmu_cfg_valid_o);
    expect("reset maintenance request", 0, dut.maint_cmd_valid_o);
    expect("reset IRQ", 0, dut.irq_o);
    dut.rst_ni = 1;
    starts = mmu_requests = maintenance_requests = protocol_clears = 0;
    eval();
  }

  // Producers keep valid and payload asserted through the accepting edge.
  // Responses are deliberately left blocked until finish_response().
  void submit(bool write, std::uint16_t address, std::uint32_t data = 0,
              std::uint8_t strobes = 0xf) {
    dut.mmio_req_valid_i = 1;
    dut.mmio_req_write_i = write;
    dut.mmio_req_addr_i = address;
    dut.mmio_req_wdata_i = data;
    dut.mmio_req_wstrb_i = strobes;
    dut.mmio_rsp_ready_i = 0;
    eval();
    unsigned waited = 0;
    while (!dut.mmio_req_ready_o) {
      if (++waited > 32) fail("MMIO request timeout", 1, 0);
      tick();
    }
    tick();
    dut.mmio_req_valid_i = 0;
    eval();
    waited = 0;
    while (!dut.mmio_rsp_valid_o) {
      if (++waited > 32) fail("MMIO response timeout", 1, 0);
      tick();
    }
  }

  void held_response(std::uint32_t data, bool error, unsigned duration = 3) {
    for (unsigned i = 0; i < duration; ++i) {
      expect("blocked response valid", 1, dut.mmio_rsp_valid_o);
      expect("blocked response snapshot", data, dut.mmio_rsp_rdata_o);
      expect("blocked response error", error, dut.mmio_rsp_error_o);
      expect("one outstanding request", 0, dut.mmio_req_ready_o);
      tick();
    }
  }

  std::uint32_t finish_response(bool error = false) {
    expect("response valid at consumption", 1, dut.mmio_rsp_valid_o);
    expect("response error", error, dut.mmio_rsp_error_o);
    const std::uint32_t data = dut.mmio_rsp_rdata_o;
    if (error) expect("error response zero data", 0, data);
    dut.mmio_rsp_ready_i = 1;
    tick();
    dut.mmio_rsp_ready_i = 0;
    eval();
    expect("one response per accepted request", 0, dut.mmio_rsp_valid_o);
    return data;
  }

  std::uint32_t read(std::uint16_t address, bool error = false) {
    submit(false, address);
    return finish_response(error);
  }

  void write(std::uint16_t address, std::uint32_t data,
             std::uint8_t strobes = 0xf, bool error = false) {
    submit(true, address, data, strobes);
    expect("write response zero data", 0, finish_response(error));
  }

  void command(Command value, bool error = false) {
    write(COMMAND, value, 0xf, error);
  }

  void configure_start() {
    write(START_PC, 0x100);
    write(END_PC, 0x140);
    write(GROUP_MASK, 5);
    write(FETCH_CONTEXT, 0xab02);  // TRANSLATED, opaque context 0xab.
    write(TAG_SEED, 0x7b);
  }

  void start_payload() {
    expect("owned START valid", 1, dut.start_valid_o);
    expect("owned START PC", 0x100, dut.start_pc_o);
    expect("owned END PC", 0x140, dut.end_pc_o);
    expect("owned group mask", 5, dut.start_group_mask_o);
    expect("owned tag seed", 0x7b, dut.start_tag_seed_o);
    expect("owned fetch space", 2, dut.start_ifetch_addr_space_o);
    expect("owned fetch context", 0xab, dut.start_ifetch_addr_context_o);
  }

  void accept_start() {
    start_payload();
    dut.start_ready_i = 1;
    tick();
    dut.start_ready_i = 0;
    dut.system_quiescent_i = 0;
    dut.system_busy_i = 1;
    dut.program_active_i = 1;
    eval();
    expect("accepted START removed", 0, dut.start_valid_o);
  }

  void launch() {
    configure_start();
    command(START);
    accept_start();
  }

  void retire_action() {
    dut.action_cpl_valid_i = 1;
    eval();
    unsigned waited = 0;
    while (!dut.action_cpl_ready_o) {
      if (++waited > 32) fail("action consumer timeout", 1, 0);
      tick();
    }
    tick();
    dut.action_cpl_valid_i = 0;
    eval();
  }

  void terminal(bool failed = false) {
    dut.program_active_i = 0;
    dut.program_terminal_pc_i = 0x13c;
    dut.program_done_i = !failed;
    dut.program_failed_i = failed;
    tick();
    dut.program_done_i = 0;
    dut.program_failed_i = 0;
    eval();
  }

  void quiesce() {
    dut.system_busy_i = 0;
    dut.system_quiescent_i = 1;
    tick();
    tick();
  }

  void invisible_result() {
    for (auto address : kResultRegisters)
      expect("unpublished/acknowledged result hidden", 0, read(address));
  }
};

void test_transport_and_validation(Bench& b) {
  b.reset();
  expect("ID", 0x56535031, b.read(ID));
  expect("VERSION", 0x00010000, b.read(VERSION));
  expect("reset group mask", 0xf, b.read(GROUP_MASK));
  expect("reset PHYSICAL fetch context", 1, b.read(FETCH_CONTEXT));
  expect("idle ready and quiescent", 3, b.read(STATUS));
  expect("COMMAND reads zero", 0, b.read(COMMAND));
  expect("EXEC debug sink always ready", 1, b.dut.exec_result_ready_o);
  b.invisible_result();

  b.write(START_PC, 0x11223344);
  b.write(START_PC, 0xaabbccdd, 0x5);
  expect("ordinary byte strobes merge", 0x11bb33dd, b.read(START_PC));
  b.write(START_PC, 0xdeadbeef, 0);
  expect("zero strobes preserve ordinary RW", 0x11bb33dd, b.read(START_PC));
  for (std::uint16_t address : {0x068, 0xffc, 0x011}) {
    b.write(address, 0, 0xf, true);
    expect("invalid read returns zero", 0, b.read(address, true));
  }
  b.write(ID, 0, 0xf, true);
  b.write(STATUS, 0, 0, true);
  expect("rejected writes preserve ID", 0x56535031, b.read(ID));
  expect("rejected unaligned writes preserve adjacent RW", 0x11bb33dd,
         b.read(START_PC));
  b.configure_start();
  b.write(COMMAND, START, 0x7, true);
  b.write(COMMAND, 7, 0xf, true);
  b.write(GROUP_MASK, 0);
  b.command(START, true);
  b.write(GROUP_MASK, 0x10);
  b.command(START, true);
  b.write(GROUP_MASK, 5);
  b.write(FETCH_CONTEXT, 0x100ab02);
  b.command(START, true);
  b.write(FETCH_CONTEXT, 0xab02);
  b.write(END_PC, 0x100);
  b.command(START, true);
  b.write(END_PC, 0x140);
  b.dut.system_ready_i = 0;
  b.command(START, true);
  b.dut.system_ready_i = 1;
  b.dut.system_quiescent_i = 0;
  b.command(MMU_READ, true);
  b.command(MAINTENANCE, true);
  b.dut.system_quiescent_i = 1;
  expect("rejected commands produce no START", 0, b.dut.start_valid_o);
  expect("rejected commands produce no MMU request", 0, b.dut.mmu_cfg_valid_o);
  expect("rejected commands produce no maintenance", 0, b.dut.maint_cmd_valid_o);

  b.dut.fetch_pc_i = 0x1234;
  b.submit(false, FETCH_PC);
  b.dut.fetch_pc_i = 0x5678;
  b.held_response(0x1234, false);
  expect("read acceptance snapshots live PC", 0x1234, b.finish_response());
  expect("later read sees new live PC", 0x5678, b.read(FETCH_PC));

  b.submit(true, COMMAND, CLEAR_PROTOCOL);
  b.held_response(0, false, 6);
  b.finish_response();
  expect("blocked COMMAND executes once", 1, b.protocol_clears);
}

void test_launch_ownership_redirect_and_publication(Bench& b) {
  b.reset();
  b.configure_start();
  b.write(IRQ_ENABLE, 3);
  b.submit(true, COMMAND, START);
  b.held_response(0, false);
  b.start_payload();
  b.finish_response();
  expect("launch pending and busy", 0x24, b.read(STATUS) & 0x24);
  b.command(START, true);
  b.write(START_PC, 0x200);
  b.write(END_PC, 0x240);
  b.write(GROUP_MASK, 2);
  b.write(FETCH_CONTEXT, 0x5501);
  b.write(TAG_SEED, 0x19);
  b.start_payload();
  b.accept_start();
  for (unsigned i = 0; i < 3; ++i) b.tick();
  expect("START accepted exactly once", 1, b.starts);
  b.command(START, true);
  b.command(ACK_RESULT, true);
  b.command(CLEAR_PROTOCOL, true);

  // A speculative IFetch fault can disappear on a committed redirect. The
  // host sees the same live inputs clearing that the real wrapper provides.
  b.dut.program_error_i = 1;
  b.dut.ifetch_fault_valid_i = 1;
  b.dut.ifetch_fault_cause_i = 4;
  b.dut.ifetch_fault_eaddr_i = 0x128;
  b.dut.ifetch_fault_paddr_i = 0xab00100128ULL;
  b.dut.ifetch_fault_addr_space_i = 2;
  b.dut.ifetch_fault_addr_context_i = 0xab;
  b.tick();
  expect("speculation has no result", 0, b.read(RESULT_STATUS));
  expect("speculation has no IRQ", 0, b.dut.irq_o);
  b.dut.program_error_i = 0;
  b.dut.ifetch_fault_valid_i = 0;
  b.retire_action();
  b.retire_action();
  b.terminal();
  b.dut.program_terminal_pc_i = 0xdeadbeef;
  b.invisible_result();
  expect("terminal waits for quiescence before IRQ", 0, b.dut.irq_o);
  b.command(ACK_RESULT, true);

  // Publishing while this already accepted read is stalled must not update
  // the held response, even though the register and IRQ change underneath.
  b.submit(false, RESULT_STATUS);
  b.quiesce();
  b.held_response(0, false);
  expect("job publication independent of MMIO ready", 1, b.dut.irq_o);
  b.finish_response();
  expect("redirected run succeeds", 3, b.read(RESULT_STATUS));
  expect("one-cycle terminal PC retained", 0x13c, b.read(TERMINAL_PC));
  expect("retired action count", 2, b.read(ACTION_COUNT));
  expect("discarded fetch diagnosis hidden", 0, b.read(IFETCH_INFO));
  expect("discarded fetch address hidden", 0, b.read(IFETCH_EADDR));
  expect("only COMPLETE event", 1, b.read(IRQ_PENDING));
  b.command(START, true);
  b.command(CLEAR_PROTOCOL);
  expect("protocol clear preserves unread result", 3, b.read(RESULT_STATUS));
  b.command(ACK_RESULT);
  b.invisible_result();
  expect("result ACK preserves IRQ pending", 1, b.read(IRQ_PENDING));
  b.command(ACK_RESULT);  // Idempotent while idle.
  b.configure_start();
  b.command(START);
  b.accept_start();
  expect("ACK releases next START", 2, b.starts);
}

void test_retired_fault_freeze_and_irq_masking(Bench& b) {
  b.reset();
  b.launch();
  b.dut.action_cpl_class_i = 0;  // EXEC error precedes MEMORY fault.
  b.dut.action_cpl_status_i = 3;
  b.dut.action_cpl_decode_error_i = 9;
  b.dut.action_cpl_tag_i = 0x21;
  b.retire_action();

  b.dut.action_cpl_class_i = 1;
  b.dut.action_cpl_status_i = 4;
  b.dut.action_cpl_decode_error_i = 0;
  b.dut.action_cpl_tag_i = 0x22;
  b.dut.action_cpl_memory_op_i = 1;
  b.dut.action_cpl_memory_status_i = 3;
  b.dut.action_cpl_memory_fault_cause_i = 4;
  b.dut.action_cpl_memory_fault_eaddr_i = 0x456;
  b.dut.action_cpl_memory_requested_group_mask_i = 0xf;
  b.dut.action_cpl_memory_completed_group_mask_i = 3;
  b.dut.action_cpl_memory_failed_group_mask_i = 0xc;
  b.dut.action_cpl_memory_bytes_committed_i = 8;
  b.dut.action_cpl_memory_partial_i = 1;
  b.retire_action();
  b.dut.action_cpl_tag_i = 0x99;
  b.dut.action_cpl_memory_fault_eaddr_i = 0x999;
  b.dut.action_cpl_memory_completed_group_mask_i = 0;
  b.dut.action_cpl_memory_failed_group_mask_i = 0xf;
  b.dut.action_cpl_memory_bytes_committed_i = 0;
  b.dut.action_cpl_memory_partial_i = 0;
  b.retire_action();
  b.terminal();  // DONE and live program_error=0 cannot erase retired errors.
  b.quiesce();
  expect("DONE plus retired ERROR is not success", 0xb, b.read(RESULT_STATUS));
  expect("first action error kept separately", 0x09030001,
         b.read(FIRST_ERROR_INFO));
  expect("first action error tag frozen", 0x21, b.read(FIRST_ERROR_TAG));
  expect("first MEMORY fault and partial status", 0x04030103,
         b.read(MEM_FAULT_INFO));
  expect("first MEMORY effective address", 0x456, b.read(MEM_FAULT_EADDR));
  expect("first MEMORY requested/completed masks", 0x0003000f, b.read(MEM_MASKS));
  expect("first MEMORY failed groups", 0xc, b.read(MEM_FAILED_MASK));
  expect("first MEMORY committed bytes", 8, b.read(MEM_BYTES));
  expect("each retired action counted", 3, b.read(ACTION_COUNT));
  b.dut.program_error_i = 1;
  b.dut.program_terminal_pc_i = 0xffff;
  b.dut.ifetch_fault_valid_i = 1;
  b.retire_action();  // Idle observations cannot mutate a published result.
  expect("published terminal PC frozen", 0x13c, b.read(TERMINAL_PC));
  expect("published count frozen", 3, b.read(ACTION_COUNT));
  expect("published IFetch diagnosis frozen", 0, b.read(IFETCH_INFO));
  expect("events latch while masked", 3, b.read(IRQ_PENDING));
  expect("masked events do not assert IRQ", 0, b.dut.irq_o);
  b.write(IRQ_ENABLE, 0xfffffffa);
  expect("IRQ_ENABLE exposes only implemented bits", 2, b.read(IRQ_ENABLE));
  expect("unmasking existing ERROR asserts IRQ", 1, b.dut.irq_o);
  b.write(IRQ_PENDING, 2, 2);
  b.write(IRQ_PENDING, 2, 0);
  expect("W1C ignores disabled byte lanes", 3, b.read(IRQ_PENDING));
  b.write(IRQ_PENDING, 2, 1);
  expect("W1C clears selected event only", 1, b.read(IRQ_PENDING));
  expect("cleared enabled event lowers IRQ", 0, b.dut.irq_o);
  b.write(IRQ_ENABLE, 1);
  expect("unmask COMPLETE asserts IRQ", 1, b.dut.irq_o);
  b.command(ACK_RESULT);
  b.invisible_result();
  expect("ACK does not acknowledge interrupt", 1, b.read(IRQ_PENDING));
  b.write(IRQ_PENDING, 1);
  expect("W1C removes final IRQ", 0, b.dut.irq_o);
}

void test_terminal_ifetch_and_event_wins_clear(Bench& b) {
  b.reset();
  b.write(IRQ_ENABLE, 3);
  b.launch();
  b.dut.program_error_i = 1;
  b.dut.ifetch_fault_valid_i = 1;
  b.dut.ifetch_fault_cause_i = 3;
  b.dut.ifetch_fault_eaddr_i = 0x138;
  b.dut.ifetch_fault_paddr_i = 0xab12345678ULL;
  b.dut.ifetch_fault_addr_space_i = 2;
  b.dut.ifetch_fault_addr_context_i = 0xa5;
  b.terminal(true);
  expect("failed terminal also waits for quiescence", 0, b.read(RESULT_STATUS));
  expect("no pre-publication event", 0, b.read(IRQ_PENDING));
  b.eval();
  expect("W1C can be accepted at publication edge", 1, b.dut.mmio_req_ready_o);
  b.dut.system_busy_i = 0;
  b.dut.system_quiescent_i = 1;
  b.submit(true, IRQ_PENDING, 3, 1);
  b.held_response(0, false);
  b.finish_response();
  expect("new job events dominate same-edge W1C", 3, b.read(IRQ_PENDING));
  expect("FAILED and ERROR terminal result", 0xd, b.read(RESULT_STATUS));
  expect("final IFetch cause/space/context", 0x00a50231, b.read(IFETCH_INFO));
  expect("final IFetch failed requested word", 0x138, b.read(IFETCH_EADDR));
  expect("IFetch 40-bit diagnostic low", 0x12345678, b.read(IFETCH_PADDR_LO));
  expect("IFetch 40-bit diagnostic high", 0xab, b.read(IFETCH_PADDR_HI));
  b.dut.ifetch_fault_valid_i = 0;
  b.dut.ifetch_fault_eaddr_i = 0;
  b.dut.ifetch_fault_paddr_i = 0;
  expect("published IFetch address remains frozen", 0x138, b.read(IFETCH_EADDR));
}

void test_management_ownership_completion_and_reset(Bench& b) {
  b.reset();
  b.launch();
  b.terminal();
  b.quiesce();  // Leave a completed job unread while management executes.
  b.write(IRQ_PENDING, 7);
  b.write(IRQ_ENABLE, 4);
  b.write(MMU_CONTEXT, 7);
  b.write(MMU_FIELD, 9);
  b.write(MMU_WDATA, 0xaabbccdd);
  b.command(MMU_WRITE);
  b.write(MMU_CONTEXT, 1);
  b.write(MMU_FIELD, 0);
  b.write(MMU_WDATA, 0xdeadbeef);
  expect("stalled MMU request valid", 1, b.dut.mmu_cfg_valid_o);
  expect("owned MMU write", 1, b.dut.mmu_cfg_write_o);
  expect("owned MMU context", 7, b.dut.mmu_cfg_context_o);
  expect("owned MMU field", 9, b.dut.mmu_cfg_field_o);
  expect("owned MMU data", 0xaabbccdd, b.dut.mmu_cfg_wdata_o);
  b.command(MMU_READ, true);
  b.command(ACK_RESULT, true);
  b.command(CLEAR_PROTOCOL, true);
  b.submit(false, MGMT_STATUS);
  b.dut.mmu_cfg_ready_i = 1;
  b.tick();
  b.dut.mmu_cfg_ready_i = 0;
  b.dut.mmu_cfg_rsp_valid_i = 1;
  b.dut.mmu_cfg_rsp_rdata_i = 0x1234abcd;
  b.eval();
  unsigned waited = 0;
  while (!b.dut.mmu_cfg_rsp_ready_o) {
    if (++waited > 32) fail("MMU response consumer timeout", 1, 0);
    b.tick();
  }
  b.tick();
  b.dut.mmu_cfg_rsp_valid_i = 0;
  b.dut.mmu_cfg_rsp_rdata_i = 0xdeaddead;
  b.held_response(0, false);
  expect("management completion bypasses MMIO backpressure", 1, b.dut.irq_o);
  b.finish_response();
  expect("MMU accepted once", 1, b.mmu_requests);
  expect("successful MMU result", 0x101, b.read(MGMT_STATUS));
  expect("MMU result captures accepted response", 0x1234abcd, b.read(MMU_RDATA));
  expect("management preserves unread job", 3, b.read(RESULT_STATUS));
  b.write(IRQ_PENDING, 4);

  b.write(MAINT_OP, 10);
  b.write(MAINT_EADDR, 0x11223344);
  b.write(MAINT_PADDR_LO, 0x89abcdef);
  b.write(MAINT_PADDR_HI, 0xab);
  b.write(MAINT_CONTEXT, 0xa5);
  b.write(MAINT_ASID, 0x1aa);
  b.command(MAINTENANCE);
  expect("next management command clears previous validity", 0,
         b.read(MGMT_STATUS) & 1);
  b.write(MAINT_OP, 0);
  b.write(MAINT_EADDR, 0);
  b.write(MAINT_PADDR_LO, 0);
  b.write(MAINT_PADDR_HI, 0);
  b.write(MAINT_CONTEXT, 0);
  b.write(MAINT_ASID, 0);
  expect("stalled maintenance remains valid", 1, b.dut.maint_cmd_valid_o);
  expect("owned maintenance operation", 10, b.dut.maint_cmd_op_o);
  expect("owned maintenance effective address", 0x11223344, b.dut.maint_cmd_eaddr_o);
  expect("owned maintenance physical address", 0xab89abcdefULL,
         b.dut.maint_cmd_paddr_o);
  expect("owned maintenance context", 0xa5, b.dut.maint_cmd_addr_context_o);
  expect("owned maintenance ASID", 0x1aa, b.dut.maint_cmd_asid_o);
  b.submit(false, MGMT_STATUS);
  const auto empty_status = b.dut.mmio_rsp_rdata_o;
  b.dut.maint_cmd_ready_i = 1;
  b.tick();
  b.dut.maint_cmd_ready_i = 0;
  b.dut.maint_cpl_valid_i = 1;
  b.dut.maint_cpl_status_i = 1;
  b.dut.maint_cpl_fault_i = 4;
  b.eval();
  waited = 0;
  while (!b.dut.maint_cpl_ready_o) {
    if (++waited > 32) fail("maintenance completion consumer timeout", 1, 0);
    b.tick();
  }
  b.tick();
  b.dut.maint_cpl_valid_i = 0;
  b.dut.maint_cpl_status_i = 0;
  b.dut.maint_cpl_fault_i = 0;
  b.held_response(empty_status, false);
  b.finish_response();
  expect("maintenance accepted once", 1, b.maintenance_requests);
  expect("maintenance status and fault captured", 0x04010203, b.read(MGMT_STATUS));
  expect("maintenance completion event", 4, b.read(IRQ_PENDING));
  expect("maintenance preserves MMU readback", 0x1234abcd, b.read(MMU_RDATA));
  expect("maintenance preserves unread job", 3, b.read(RESULT_STATUS));

  b.command(ACK_RESULT);
  b.configure_start();
  b.submit(true, COMMAND, START);
  expect("reset begins with outstanding MMIO response", 1, b.dut.mmio_rsp_valid_o);
  expect("reset begins with stalled START", 1, b.dut.start_valid_o);
  expect("reset begins with asserted IRQ", 1, b.dut.irq_o);
  b.reset();
  b.invisible_result();
  expect("reset clears pending events", 0, b.read(IRQ_PENDING));
  expect("reset clears management result", 0, b.read(MGMT_STATUS));
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Bench bench;
  test_transport_and_validation(bench);
  test_launch_ownership_redirect_and_publication(bench);
  test_retired_fault_freeze_and_irq_masking(bench);
  test_terminal_ifetch_and_event_wins_clear(bench);
  test_management_ownership_completion_and_reset(bench);
  bench.dut.final();
  std::cout << "PASS vsp_host_control " << checks << " checks in " << cycles
            << " cycles\n";
  return EXIT_SUCCESS;
}
