// SPDX-License-Identifier: MIT
#include "Vvsp_mmio_system_tb_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {
using Dut = Vvsp_mmio_system_tb_top;
enum Register : unsigned {
  ID = 0x000, VERSION = 0x004, STATUS = 0x008, COMMAND = 0x00c,
  START_PC = 0x010, END_PC = 0x014, GROUP_MASK = 0x018,
  FETCH_CONTEXT = 0x01c, TAG_SEED = 0x020, IRQ_ENABLE = 0x024,
  IRQ_PENDING = 0x028, RESULT_STATUS = 0x030, TERMINAL_PC = 0x034,
  ACTION_COUNT = 0x038, FIRST_ERROR_INFO = 0x03c, FIRST_ERROR_TAG = 0x040,
  MEM_FAULT_INFO = 0x044, MEM_FAULT_EADDR = 0x048, MEM_MASKS = 0x04c,
  MEM_FAILED_MASK = 0x050, MEM_BYTES = 0x054, IFETCH_INFO = 0x058,
  IFETCH_EADDR = 0x05c, IFETCH_PADDR_LO = 0x060, IFETCH_PADDR_HI = 0x064,
  MMU_CONTEXT = 0x070, MMU_FIELD = 0x074, MMU_WDATA = 0x078,
  MMU_RDATA = 0x07c, MGMT_STATUS = 0x080, MAINT_OP = 0x084
};
enum Command : unsigned {
  START = 1, ACK_RESULT = 2, MMU_READ = 3, MMU_WRITE = 4, MAINTENANCE = 5
};
std::uint64_t cycles = 0, checks = 0;

[[noreturn]] void fail(const std::string& what) {
  std::cerr << "FAIL at cycle " << cycles << ": " << what << '\n';
  std::exit(1);
}
void check(const std::string& what, std::uint64_t expected, std::uint64_t value) {
  ++checks;
  if (expected != value) {
    std::cerr << std::hex << "expected 0x" << expected << " got 0x" << value
              << std::dec << '\n';
    fail(what);
  }
}
void eval(Dut& d) { d.clk_i = 0; d.eval(); }
void tick(Dut& d) {
  eval(d); d.clk_i = 1; d.eval(); ++cycles; eval(d);
}
template <class F> void wait(Dut& d, F ready, const std::string& what) {
  for (unsigned n = 0; n < 50000; ++n) {
    eval(d);
    if (ready()) return;
    tick(d);
  }
  fail("timeout: " + what);
}

std::uint32_t mmio(Dut& d, unsigned address, bool write,
                   std::uint32_t value = 0, unsigned strobes = 15,
                   bool expect_error = false, unsigned response_hold = 0) {
  d.mmio_req_addr_i = address;
  d.mmio_req_write_i = write;
  d.mmio_req_wdata_i = value;
  d.mmio_req_wstrb_i = strobes;
  d.mmio_req_valid_i = 1;
  d.mmio_rsp_ready_i = 0;
  wait(d, [&]() { return d.mmio_req_ready_o; }, "MMIO request");
  tick(d);
  d.mmio_req_valid_i = 0;
  // Accepted request fields may change while its response is held.
  d.mmio_req_addr_i = 0xffc;
  d.mmio_req_wdata_i = 0xdeadbeef;
  wait(d, [&]() { return d.mmio_rsp_valid_o; }, "MMIO response");
  const std::uint32_t result = d.mmio_rsp_rdata_o;
  const bool error = d.mmio_rsp_error_o;
  for (unsigned n = 0; n < response_hold; ++n) tick(d);
  check("MMIO held response valid", 1, d.mmio_rsp_valid_o);
  check("MMIO held response data", result, d.mmio_rsp_rdata_o);
  check("MMIO held response error", error, d.mmio_rsp_error_o);
  check("MMIO expected status", expect_error, error);
  if (expect_error) check("error response data zero", 0, result);
  d.mmio_rsp_ready_i = 1;
  tick(d);
  d.mmio_rsp_ready_i = 0;
  return result;
}
std::uint32_t read(Dut& d, unsigned address) { return mmio(d, address, false); }
void write(Dut& d, unsigned address, std::uint32_t value) {
  mmio(d, address, true, value);
}
std::uint32_t poll(Dut& d, unsigned address, unsigned mask, unsigned expected) {
  for (unsigned n = 0; n < 10000; ++n) {
    const auto value = read(d, address);
    if ((value & mask) == expected) return value;
  }
  fail("register poll");
}

void init_word(Dut& d, std::uint32_t addr, std::uint32_t value) {
  d.backing_init_valid_i = 1;
  d.backing_init_paddr_i = addr;
  d.backing_init_wdata_i = value;
  d.backing_init_wstrb_i = 15;
  wait(d, [&]() { return d.backing_init_ready_o; }, "shared RAM preparation");
  check("RAM initialization accepted", 0, d.backing_init_error_o);
  tick(d); d.backing_init_valid_i = 0;
}
std::uint32_t peek(Dut& d, std::uint32_t addr) {
  d.backing_peek_paddr_i = addr; eval(d);
  check("host RAM read in range", 0, d.backing_peek_error_o);
  return d.backing_peek_rdata_o;
}
std::vector<std::uint32_t> read_hex(const std::string& path) {
  std::ifstream file(path);
  if (!file) fail("cannot read " + path);
  std::vector<std::uint32_t> words;
  std::string line;
  while (std::getline(file, line))
    if (!line.empty()) words.push_back(std::stoul(line, nullptr, 16));
  return words;
}
void image(Dut& d, std::uint32_t base, const std::vector<std::uint32_t>& words) {
  for (unsigned n = 0; n < words.size(); ++n) init_word(d, base + 4 * n, words[n]);
}
std::uint8_t input_byte(unsigned lane, unsigned phase) {
  return static_cast<std::uint8_t>(lane * 11 + phase * 37);
}
void install_data(Dut& d, unsigned phase) {
  for (unsigned n = 0; n < 48; n += 4) {
    std::uint32_t word = 0;
    for (unsigned b = 0; b < 4; ++b) word |= std::uint32_t(input_byte(n+b, phase)) << (8*b);
    init_word(d, 0x1040 + n, word);
    init_word(d, 0x1140 + n, 0xcccccccc);
  }
  init_word(d, 0x113c, 0xa5a5a5a5);
  init_word(d, 0x1170, 0x3c3c3c3c);
}
void check_data(Dut& d, unsigned phase) {
  check("published result has drained memory", 1, d.system_quiescent_o);
  check("all lower memory responses returned", d.lower_requests_o, d.lower_responses_o);
  for (unsigned n = 0; n < 48; n += 4) {
    std::uint32_t expected = 0;
    for (unsigned b = 0; b < 4; ++b) {
      unsigned x = input_byte(n+b, phase) + 40;
      expected |= std::uint32_t(x > 255 ? 255 : x) << (8*b);
    }
    check("host-visible computed vector", expected, peek(d, 0x1140 + n));
  }
  check("lower output guard", 0xa5a5a5a5, peek(d, 0x113c));
  check("upper output guard", 0x3c3c3c3c, peek(d, 0x1170));
}
void launch_config(Dut& d, unsigned pc, unsigned words, unsigned fetch_context,
                   unsigned tag = 0x10) {
  write(d, START_PC, pc); write(d, END_PC, pc + words * 4);
  write(d, GROUP_MASK, 15); write(d, FETCH_CONTEXT, fetch_context);
  write(d, TAG_SEED, tag);
}
void acknowledge(Dut& d) {
  write(d, COMMAND, ACK_RESULT);
  check("acknowledged result hidden", 0, read(d, RESULT_STATUS));
  write(d, IRQ_PENDING, 7);
  check("interrupt acknowledged", 0, d.irq_o);
}
void maintain(Dut& d, unsigned operation) {
  write(d, MAINT_OP, operation); write(d, COMMAND, MAINTENANCE);
  const auto status = poll(d, MGMT_STATUS, 1, 1);
  check("successful maintenance result", 0x201, status);
}
void mmu_write(Dut& d, unsigned field, unsigned value) {
  write(d, MMU_CONTEXT, 1); write(d, MMU_FIELD, field);
  write(d, MMU_WDATA, value); write(d, COMMAND, MMU_WRITE);
  check("successful MMU result", 0x101, poll(d, MGMT_STATUS, 1, 1));
}
void reset(Dut& d) {
  d.rst_ni = 0;
  d.mmio_req_valid_i = 0; d.mmio_req_write_i = 0;
  d.mmio_req_addr_i = 0; d.mmio_req_wdata_i = 0; d.mmio_req_wstrb_i = 0;
  d.mmio_rsp_ready_i = 0;
  d.backing_init_valid_i = 0; d.backing_init_paddr_i = 0;
  d.backing_init_wdata_i = 0; d.backing_init_wstrb_i = 0;
  d.backing_peek_paddr_i = 0;
  for (unsigned n = 0; n < 3; ++n) tick(d);
  check("reset clears IRQ", 0, d.irq_o);
  d.rst_ni = 1; tick(d);
  poll(d, STATUS, 3, 3);
}
}  // namespace

double sc_time_stamp() { return static_cast<double>(cycles); }
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc != 3) { std::cerr << "usage: TEST PROGRAM.hex MEMORY_FAULT.hex\n"; return 2; }
  const auto program = read_hex(argv[1]);
  const auto memory_fault = read_hex(argv[2]);
  Dut d; reset(d);
  check("VSP register ID", 0x56535031, read(d, ID));
  check("VSP ABI version", 0x10000, read(d, VERSION));
  image(d, 0x20, program); image(d, 0x200, memory_fault); install_data(d, 0);

  launch_config(d, 0x20, program.size(), 1);
  write(d, COMMAND, START);
  mmio(d, COMMAND, true, START, 15, true);  // busy doorbell is rejected
  write(d, START_PC, 0x2000);  // next-job staging must not alter active work
  write(d, FETCH_CONTEXT, 0xfe02);
  check("physical job result", 3, poll(d, RESULT_STATUS, 1, 1));
  check("one launch, eighteen actions", 18, read(d, ACTION_COUNT));
  check("physical terminal PC", 0x20 + 4 * (program.size()-1), read(d, TERMINAL_PC));
  check("no spurious fault", 0, read(d, IFETCH_INFO));
  check_data(d, 0);
  check("event retained while masked", 1, read(d, IRQ_PENDING));
  check("IRQ masked", 0, d.irq_o);
  write(d, IRQ_ENABLE, 1); check("late enable sees completion", 1, d.irq_o);
  mmio(d, COMMAND, true, START, 15, true);  // unread result protected
  check("rejected START preserves result", 3, read(d, RESULT_STATUS));
  acknowledge(d);

  // A second host submission uses real Sv32 translation, configured entirely
  // through MMIO. Changed input data also exercises host-issued D invalidation.
  init_word(d, 0x2004, 0xc01); init_word(d, 0x3000, 0x5b);
  mmu_write(d, 0, 0); mmu_write(d, 1, 1); mmu_write(d, 2, 2);
  mmu_write(d, 4, 0); mmu_write(d, 7, 1); mmu_write(d, 0, 1);
  write(d, MMU_FIELD, 2); write(d, COMMAND, MMU_READ);
  check("MMU read completed", 0x101, poll(d, MGMT_STATUS, 1, 1));
  check("MMU root readback", 2, read(d, MMU_RDATA));
  install_data(d, 1); maintain(d, 2); maintain(d, 9);
  write(d, IRQ_PENDING, 7); write(d, IRQ_ENABLE, 3);
  launch_config(d, 0x00400020, program.size(), 0x102, 0x40);
  // Execution and IRQ publication must progress even when the MMIO START
  // response remains unconsumed. The held bus response is only submission ACK.
  mmio(d, COMMAND, true, START, 15, false, 1500);
  check("translated completion IRQ", 1, d.irq_o);
  check("translated result", 3, read(d, RESULT_STATUS));
  check("translated launch ran once", 18, read(d, ACTION_COUNT));
  check("virtual terminal PC preserved", 0x00400020 + 4*(program.size()-1), read(d, TERMINAL_PC));
  check_data(d, 1); acknowledge(d);

  // Invalid fetch context must survive the one-cycle failed pulse as a frozen
  // multi-register diagnostic; no instructions or data operations can execute.
  launch_config(d, 0x00400020, 1, 0xfe02, 0x60);
  write(d, COMMAND, START);
  check("fetch failed result", 13, poll(d, RESULT_STATUS, 1, 1));
  check("fetch error pending", 3, read(d, IRQ_PENDING));
  check("fetch failure has no action", 0, read(d, ACTION_COUNT));
  check("fetch failure metadata", 0xfe0231, read(d, IFETCH_INFO));
  check("fetch failure VA", 0x00400020, read(d, IFETCH_EADDR));
  check("translation failure PA low", 0, read(d, IFETCH_PADDR_LO));
  check("translation failure PA high", 0, read(d, IFETCH_PADDR_HI));
  maintain(d, 9);
  check("maintenance cannot erase frozen job diagnostic", 0xfe0231, read(d, IFETCH_INFO));
  acknowledge(d);

  // A MEMORY action failure is not program_failed in the current core model:
  // legal END still occurs, so software must observe DONE together with ERROR.
  launch_config(d, 0x200, memory_fault.size(), 1, 0x80);
  write(d, COMMAND, START);
  check("memory failure followed by END", 11, poll(d, RESULT_STATUS, 1, 1));
  check("memory fault retirement count", 3, read(d, ACTION_COUNT));
  check("first action error is MEMORY_ERROR", 0x00040101, read(d, FIRST_ERROR_INFO));
  check("failed action tag", 0x81, read(d, FIRST_ERROR_TAG));
  check("memory ACCESS diagnosis", 0x03030001, read(d, MEM_FAULT_INFO));
  check("memory failed byte address", 0x2000, read(d, MEM_FAULT_EADDR));
  check("memory masks requested but none completed", 15, read(d, MEM_MASKS));
  check("first group failed", 1, read(d, MEM_FAILED_MASK));
  check("memory no bytes committed", 0, read(d, MEM_BYTES));
  check("previous IFetch fault not inherited", 0, read(d, IFETCH_INFO));
  check("all main memory work drained", d.lower_requests_o, d.lower_responses_o);
  acknowledge(d);

  launch_config(d, 0x20, program.size(), 1, 0xa0);
  write(d, COMMAND, START);
  check("recovery succeeds without reset", 3, poll(d, RESULT_STATUS, 1, 1));
  check("recovery clears first error", 0, read(d, FIRST_ERROR_INFO));
  check_data(d, 1);
  reset(d);
  check("reset removes old host result", 0, read(d, RESULT_STATUS));
  check("reset removes interrupt pending", 0, read(d, IRQ_PENDING));
  std::cout << "PASS MMIO VSP system: " << checks << " checks, " << cycles
            << " cycles; physical/Sv32 jobs, maintenance, IRQ, faults and restart\n";
  return 0;
}
