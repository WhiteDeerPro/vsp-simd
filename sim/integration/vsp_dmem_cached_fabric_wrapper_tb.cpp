// SPDX-License-Identifier: MIT

#include "Vvsp_dmem_cached_fabric_wrapper_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using Dut = Vvsp_dmem_cached_fabric_wrapper_tb_top;

constexpr std::uint8_t kLoad = 0;
constexpr std::uint8_t kStore = 1;
constexpr std::uint8_t kLocal = 0;
constexpr std::uint8_t kPhysical = 1;
constexpr std::uint8_t kTranslated = 2;
constexpr std::uint8_t kFaultNone = 0;
constexpr std::uint8_t kFaultAccess = 3;
constexpr std::uint8_t kStatusOk = 0;
constexpr std::uint8_t kMaintInvalidateAll = 2;

constexpr std::uint8_t kCfgValid = 0;
constexpr std::uint8_t kCfgMode = 1;
constexpr std::uint8_t kCfgRootPpn = 2;
constexpr std::uint8_t kCfgAsid = 3;
constexpr std::uint8_t kCfgPrivilege = 4;
constexpr std::uint8_t kCfgMxr = 5;
constexpr std::uint8_t kCfgSum = 6;
constexpr std::uint8_t kCfgAllowFetch = 7;
constexpr std::uint8_t kCfgAllowLoad = 8;
constexpr std::uint8_t kCfgAllowStore = 9;
constexpr std::uint8_t kModeBare = 0;

std::uint64_t checks = 0;
std::uint64_t cycles = 0;
std::uint64_t read_hits = 0;
std::uint64_t read_misses = 0;
std::uint64_t write_hits = 0;
std::uint64_t write_misses = 0;

[[noreturn]] void fail(const std::string& label, std::uint64_t expected,
                       std::uint64_t actual) {
  std::cerr << "FAIL " << label << " expected=0x" << std::hex << expected
            << " actual=0x" << actual << std::dec << '\n';
  std::exit(EXIT_FAILURE);
}

void expect_eq(const std::string& label, std::uint64_t expected,
               std::uint64_t actual) {
  ++checks;
  if (expected != actual) fail(label, expected, actual);
}

void eval_low(Dut& dut) {
  dut.clk_i = 0;
  dut.eval();
}

void tick(Dut& dut) {
  dut.clk_i = 0;
  dut.eval();
  dut.clk_i = 1;
  dut.eval();
  ++cycles;
  read_hits += dut.perf_dcache_read_hit_o != 0;
  read_misses += dut.perf_dcache_read_miss_o != 0;
  write_hits += dut.perf_dcache_write_hit_o != 0;
  write_misses += dut.perf_dcache_write_miss_o != 0;
  dut.clk_i = 0;
  dut.eval();
}

template <typename Predicate>
void wait_for(Dut& dut, Predicate predicate, const std::string& label,
              unsigned limit = 4096) {
  for (unsigned waited = 0; waited < limit; ++waited) {
    eval_low(dut);
    if (predicate()) return;
    tick(dut);
  }
  std::cerr << "FAIL timeout waiting for " << label << '\n';
  std::exit(EXIT_FAILURE);
}

void clear_inputs(Dut& dut) {
  dut.dmem_req_valid_i = 0;
  dut.dmem_req_op_i = kLoad;
  dut.dmem_req_eaddr_i = 0;
  dut.dmem_req_addr_space_i = kLocal;
  dut.dmem_req_addr_context_i = 0;
  dut.dmem_req_wdata_i = 0;
  dut.dmem_req_wstrb_i = 0;
  dut.dmem_rsp_ready_i = 0;

  dut.mmu_cfg_valid_i = 0;
  dut.mmu_cfg_write_i = 0;
  dut.mmu_cfg_context_i = 0;
  dut.mmu_cfg_field_i = 0;
  dut.mmu_cfg_wdata_i = 0;
  dut.mmu_cfg_rsp_ready_i = 0;

  dut.dcache_maint_req_valid_i = 0;
  dut.dcache_maint_req_op_i = 0;
  dut.dcache_maint_req_paddr_i = 0;
  dut.dcache_maint_rsp_ready_i = 0;
  dut.fabric_drain_req_i = 0;

  dut.backing_init_valid_i = 0;
  dut.backing_init_paddr_i = 0;
  dut.backing_init_wdata_i = 0;
  dut.backing_init_wstrb_i = 0;
  dut.backing_peek_paddr_i = 0x1000;
  dut.protocol_error_clear_i = 0;
}

void reset(Dut& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  expect_eq("reset blocks dmem request", 0, dut.dmem_req_ready_o);
  expect_eq("reset clears product protocol error", 0, dut.protocol_error_o);
  // A direct LOCAL request must not bypass the product-level initialization
  // boundary merely because the local SRAM itself can already accept it.
  dut.dmem_req_valid_i = 1;
  dut.rst_ni = 1;
  eval_low(dut);
  expect_eq("initialization keeps D-side path unavailable", 0,
            dut.dmem_path_ready_o);
  expect_eq("initialization gates even LOCAL admission", 0,
            dut.dmem_req_ready_o);
  dut.dmem_req_valid_i = 0;
  wait_for(dut, [&dut]() { return dut.dmem_path_ready_o != 0; },
           "D-side product initialization");
  expect_eq("MMU initialized", 1, dut.mmu_init_done_o);
  expect_eq("D-cache initialized", 1, dut.dcache_init_done_o);
  expect_eq("fabric left quarantine", 0, dut.fabric_quarantine_o);
}

void init_word(Dut& dut, std::uint32_t address, std::uint32_t value) {
  dut.backing_init_paddr_i = address;
  dut.backing_init_wdata_i = value;
  dut.backing_init_wstrb_i = 0xf;
  dut.backing_init_valid_i = 1;
  wait_for(dut, [&dut]() { return dut.backing_init_ready_o != 0; },
           "backing SRAM initialization port");
  expect_eq("backing initialization address accepted", 0,
            dut.backing_init_error_o);
  tick(dut);
  dut.backing_init_valid_i = 0;
}

std::uint32_t peek_word(Dut& dut, std::uint32_t address) {
  dut.backing_peek_paddr_i = address;
  eval_low(dut);
  expect_eq("backing peek address valid", 0, dut.backing_peek_error_o);
  return static_cast<std::uint32_t>(dut.backing_peek_rdata_o);
}

struct Response {
  std::uint32_t data;
  std::uint8_t fault;
};

Response request(Dut& dut, const std::string& label, std::uint8_t op,
                 std::uint8_t address_space, std::uint32_t address,
                 std::uint8_t context = 0, std::uint32_t wdata = 0,
                 std::uint8_t wstrb = 0) {
  dut.dmem_req_op_i = op;
  dut.dmem_req_eaddr_i = address;
  dut.dmem_req_addr_space_i = address_space;
  dut.dmem_req_addr_context_i = context;
  dut.dmem_req_wdata_i = wdata;
  dut.dmem_req_wstrb_i = wstrb;
  dut.dmem_req_valid_i = 1;
  wait_for(dut, [&dut]() { return dut.dmem_req_ready_o != 0; },
           label + " request ready");
  tick(dut);
  dut.dmem_req_valid_i = 0;

  wait_for(dut, [&dut]() { return dut.dmem_rsp_valid_o != 0; },
           label + " response");
  const Response result{
      static_cast<std::uint32_t>(dut.dmem_rsp_rdata_o),
      static_cast<std::uint8_t>(dut.dmem_rsp_fault_cause_o)};

  // The complete product path must preserve the architectural response while
  // the vector memory engine (or this test) applies completion backpressure.
  tick(dut);
  expect_eq(label + " response valid holds", 1, dut.dmem_rsp_valid_o);
  expect_eq(label + " response data holds", result.data,
            dut.dmem_rsp_rdata_o);
  expect_eq(label + " response fault holds", result.fault,
            dut.dmem_rsp_fault_cause_o);

  dut.dmem_rsp_ready_i = 1;
  tick(dut);
  dut.dmem_rsp_ready_i = 0;
  wait_for(dut, [&dut]() { return dut.dmem_rsp_valid_o == 0; },
           label + " response retirement");
  return result;
}

void expect_response(const std::string& label, const Response& response,
                     std::uint32_t data, std::uint8_t fault) {
  expect_eq(label + " data", data, response.data);
  expect_eq(label + " fault", fault, response.fault);
}

void cfg_write(Dut& dut, std::uint8_t context, std::uint8_t field,
               std::uint32_t value) {
  dut.mmu_cfg_context_i = context;
  dut.mmu_cfg_field_i = field;
  dut.mmu_cfg_wdata_i = value;
  dut.mmu_cfg_write_i = 1;
  dut.mmu_cfg_valid_i = 1;
  wait_for(dut, [&dut]() { return dut.mmu_cfg_ready_o != 0; },
           "MMU configuration request");
  tick(dut);
  dut.mmu_cfg_valid_i = 0;
  wait_for(dut, [&dut]() { return dut.mmu_cfg_rsp_valid_o != 0; },
           "MMU configuration response");
  expect_eq("MMU configuration status", kStatusOk,
            dut.mmu_cfg_rsp_status_o);
  expect_eq("MMU configuration write response data", 0,
            dut.mmu_cfg_rsp_rdata_o);
  dut.mmu_cfg_rsp_ready_i = 1;
  tick(dut);
  dut.mmu_cfg_rsp_ready_i = 0;
}

void configure_bare_context(Dut& dut, std::uint8_t context) {
  cfg_write(dut, context, kCfgValid, 0);
  cfg_write(dut, context, kCfgMode, kModeBare);
  cfg_write(dut, context, kCfgRootPpn, 0);
  cfg_write(dut, context, kCfgAsid, context);
  cfg_write(dut, context, kCfgPrivilege, 0);
  cfg_write(dut, context, kCfgMxr, 0);
  cfg_write(dut, context, kCfgSum, 0);
  cfg_write(dut, context, kCfgAllowFetch, 0);
  cfg_write(dut, context, kCfgAllowLoad, 1);
  cfg_write(dut, context, kCfgAllowStore, 1);
  cfg_write(dut, context, kCfgValid, 1);
}

void invalidate_dcache(Dut& dut) {
  dut.dcache_maint_req_valid_i = 1;
  dut.dcache_maint_req_op_i = kMaintInvalidateAll;
  dut.dcache_maint_req_paddr_i = 0;
  wait_for(dut, [&dut]() { return dut.dcache_maint_req_ready_o != 0; },
           "D-cache invalidate request");
  tick(dut);
  dut.dcache_maint_req_valid_i = 0;
  wait_for(dut, [&dut]() { return dut.dcache_maint_rsp_valid_o != 0; },
           "D-cache invalidate response");
  expect_eq("D-cache invalidate status", kStatusOk,
            dut.dcache_maint_rsp_status_o);
  dut.dcache_maint_rsp_ready_i = 1;
  tick(dut);
  dut.dcache_maint_rsp_ready_i = 0;
}

}  // namespace

double sc_time_stamp() { return static_cast<double>(cycles); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Dut dut;
  reset(dut);

  // Initialize one complete cache line, plus the uncached and device words.
  for (unsigned word = 0; word < 8; ++word)
    init_word(dut, 0x1000 + 4 * word, 0x03020100U + 0x04040404U * word);
  init_word(dut, 0x2000, 0x88776655U);
  init_word(dut, 0x3000, 0x11223344U);

  // Direct LOCAL is the private zero-based aperture.  Write-before-read avoids
  // relying on an inferred SRAM's unspecified power-up contents.
  expect_response("local store",
                  request(dut, "local store", kStore, kLocal, 0x100, 0,
                          0x44332211U, 0xf),
                  0, kFaultNone);
  expect_response("local load",
                  request(dut, "local load", kLoad, kLocal, 0x100),
                  0x44332211U, kFaultNone);
  expect_eq("local endpoint returns idle", 1, dut.local_idle_o);
  expect_eq("local traffic bypasses physical lower", 0,
            dut.lower_req_count_o);

  const auto lower_before_miss = dut.lower_req_count_o;
  expect_response("cacheable miss load",
                  request(dut, "cacheable miss load", kLoad, kPhysical,
                          0x1000),
                  0x03020100U, kFaultNone);
  expect_eq("cache miss refills eight lower32 beats",
            lower_before_miss + 8, dut.lower_req_count_o);

  const auto lower_before_hit = dut.lower_req_count_o;
  expect_response("cacheable hit load",
                  request(dut, "cacheable hit load", kLoad, kPhysical,
                          0x1000),
                  0x03020100U, kFaultNone);
  expect_eq("cache hit emits no lower request", lower_before_hit,
            dut.lower_req_count_o);

  expect_response("cacheable write-through store",
                  request(dut, "cacheable write-through store", kStore,
                          kPhysical, 0x1004, 0, 0xaabbccddU, 0xf),
                  0, kFaultNone);
  expect_eq("write-through reaches backing SRAM", 0xaabbccddU,
            peek_word(dut, 0x1004));
  expect_response("cacheable post-store hit",
                  request(dut, "cacheable post-store hit", kLoad, kPhysical,
                          0x1004),
                  0xaabbccddU, kFaultNone);

  expect_response("uncached load",
                  request(dut, "uncached load", kLoad, kPhysical, 0x2000),
                  0x88776655U, kFaultNone);
  expect_response("device partial store",
                  request(dut, "device partial store", kStore, kPhysical,
                          0x3000, 0, 0xa1b2c3d4U, 0x5),
                  0, kFaultNone);
  expect_eq("device store preserves unselected bytes", 0x11b233d4U,
            peek_word(dut, 0x3000));
  expect_response("device load response owner",
                  request(dut, "device load response owner", kLoad,
                          kPhysical, 0x3000),
                  0x11b233d4U, kFaultNone);
  expect_eq("merged endpoint returns idle", 1,
            dut.uncached_device_idle_o);

  // A BARE context exercises the real shared MMU client without requiring a
  // page-table fixture; the translated result still passes region policy.
  configure_bare_context(dut, 1);
  expect_response("translated BARE cache hit",
                  request(dut, "translated BARE cache hit", kLoad,
                          kTranslated, 0x1000, 1),
                  0x03020100U, kFaultNone);

  const auto lower_before_reject = dut.lower_req_count_o;
  expect_response("physical region miss",
                  request(dut, "physical region miss", kLoad, kPhysical,
                          0x5000),
                  0, kFaultAccess);
  expect_eq("region rejection never reaches lower", lower_before_reject,
            dut.lower_req_count_o);

  invalidate_dcache(dut);
  const auto lower_before_refill = dut.lower_req_count_o;
  expect_response("post-invalidate refill",
                  request(dut, "post-invalidate refill", kLoad, kPhysical,
                          0x1000),
                  0x03020100U, kFaultNone);
  expect_eq("invalidate forces complete refill", lower_before_refill + 8,
            dut.lower_req_count_o);

  dut.fabric_drain_req_i = 1;
  wait_for(dut, [&dut]() { return dut.fabric_drain_done_o != 0; },
           "physical-fabric drain");
  expect_eq("fabric idle while drain acknowledged", 1, dut.fabric_idle_o);
  dut.fabric_drain_req_i = 0;
  tick(dut);

  wait_for(dut, [&dut]() { return dut.dmem_path_quiescent_o != 0; },
           "complete D-side quiescence");
  expect_eq("D-side no longer busy", 0, dut.dmem_path_busy_o);
  expect_eq("all lower requests have responses", dut.lower_req_count_o,
            dut.lower_rsp_count_o);
  expect_eq("no aggregate protocol error", 0, dut.protocol_error_o);
  expect_eq("cache read misses observed", 1, read_misses >= 2);
  expect_eq("cache read hits observed", 1, read_hits >= 3);
  expect_eq("cache write hit observed", 1, write_hits >= 1);
  expect_eq("cache write miss absent", 0, write_misses);

  dut.final();
  std::cout << "vsp_dmem_cached_fabric_wrapper_tb: " << checks
            << " integration checks passed in " << cycles << " cycles; "
            << dut.lower_req_count_o << " lower beats\n";
  return EXIT_SUCCESS;
}
