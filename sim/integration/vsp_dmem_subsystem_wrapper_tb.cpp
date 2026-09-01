// SPDX-License-Identifier: MIT

#include "Vvsp_dmem_subsystem_wrapper_tb_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using Dut = Vvsp_dmem_subsystem_wrapper_tb_top;

vluint64_t sim_time = 0;
std::uint64_t checks = 0;
std::uint64_t completed_transactions = 0;

constexpr std::uint8_t kLoad = 0;
constexpr std::uint8_t kStore = 1;

constexpr std::uint8_t kLocalSpace = 0;
constexpr std::uint8_t kPhysicalSpace = 1;
constexpr std::uint8_t kTranslatedSpace = 2;

constexpr std::uint8_t kFaultNone = 0;
constexpr std::uint8_t kFaultAccess = 3;
constexpr std::uint8_t kFaultBus = 4;
constexpr std::uint8_t kFaultProtocol = 6;

constexpr std::uint8_t kStatusOk = 0;
constexpr std::uint8_t kInvAll = 0;

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
constexpr std::uint8_t kModeSv32 = 1;
constexpr std::uint8_t kPrivilegeUser = 0;

constexpr std::uint8_t kEndpointCacheable = 0;
constexpr std::uint8_t kEndpointUncached = 1;
constexpr std::uint8_t kEndpointDevice = 2;
constexpr std::uint8_t kAllEndpoints = 0x0f;

constexpr std::uint32_t kCacheXor = 0xcace0000U;
constexpr std::uint32_t kUncachedXor = 0x0ca00000U;
constexpr std::uint32_t kDeviceXor = 0xde100000U;
constexpr std::uint32_t kLocalXor = 0x10ca0000U;

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
  ++sim_time;
  dut.clk_i = 1;
  dut.eval();
  ++sim_time;
  dut.clk_i = 0;
  dut.eval();
  ++sim_time;
}

template <typename Predicate>
void wait_for(Dut& dut, Predicate predicate, const std::string& label,
              unsigned limit = 2048) {
  for (unsigned waited = 0; waited < limit; ++waited) {
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
  dut.dmem_req_addr_space_i = kLocalSpace;
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

  dut.tlb_inv_req_valid_i = 0;
  dut.tlb_inv_req_scope_i = kInvAll;
  dut.tlb_inv_req_asid_i = 0;
  dut.tlb_inv_req_vaddr_i = 0;
  dut.tlb_inv_rsp_ready_i = 0;

  dut.endpoint_req_enable_i = kAllEndpoints;
  dut.endpoint_rsp_enable_i = kAllEndpoints;
  dut.ptw_req_enable_i = 1;
  dut.ptw_rsp_enable_i = 1;
  dut.ptw_model_rsp_rdata_i = 0;
  dut.ptw_model_rsp_fault_i = kFaultNone;
  dut.protocol_error_clear_i = 0;
}

void wait_for_initialized(Dut& dut, const std::string& label) {
  wait_for(dut, [&dut]() { return dut.mmu_init_done_o != 0; },
           label + " MMU initialization");
  wait_for(dut, [&dut]() { return dut.mmu_quiescent_o != 0; },
           label + " MMU quiescence");
  wait_for(dut, [&dut]() { return dut.internal_quiescent_o != 0; },
           label + " wrapper quiescence");
}

void reset(Dut& dut) {
  clear_inputs(dut);
  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  expect_eq("reset blocks dmem request", 0, dut.dmem_req_ready_o);
  expect_eq("reset hides dmem response", 0, dut.dmem_rsp_valid_o);
  expect_eq("reset clears MMU init", 0, dut.mmu_init_done_o);
  expect_eq("reset clears protocol diagnostic", 0, dut.protocol_error_o);

  dut.rst_ni = 1;
  eval_low(dut);
  wait_for_initialized(dut, "post-reset");
  expect_eq("static regions do not overlap", 0,
            dut.region_config_overlap_o);
  expect_eq("initial dmem request count", 0, dut.dmem_req_count_o);
  expect_eq("initial dmem response count", 0, dut.dmem_rsp_count_o);
}

void cfg_write(Dut& dut, std::uint8_t context, std::uint8_t field,
               std::uint32_t value) {
  dut.mmu_cfg_rsp_ready_i = 0;
  dut.mmu_cfg_write_i = 1;
  dut.mmu_cfg_context_i = context;
  dut.mmu_cfg_field_i = field;
  dut.mmu_cfg_wdata_i = value;
  dut.mmu_cfg_valid_i = 1;

  wait_for(dut, [&dut]() { return dut.mmu_cfg_ready_o != 0; },
           "MMU configuration request ready");
  tick(dut);
  dut.mmu_cfg_valid_i = 0;

  wait_for(dut, [&dut]() { return dut.mmu_cfg_rsp_valid_o != 0; },
           "MMU configuration response");
  expect_eq("MMU configuration status", kStatusOk,
            dut.mmu_cfg_rsp_status_o);
  expect_eq("MMU configuration write rdata", 0,
            dut.mmu_cfg_rsp_rdata_o);

  const auto held_status = dut.mmu_cfg_rsp_status_o;
  tick(dut);
  expect_eq("MMU configuration response holds valid", 1,
            dut.mmu_cfg_rsp_valid_o);
  expect_eq("MMU configuration response holds status", held_status,
            dut.mmu_cfg_rsp_status_o);

  dut.mmu_cfg_rsp_ready_i = 1;
  tick(dut);
  dut.mmu_cfg_rsp_ready_i = 0;
  wait_for(dut, [&dut]() { return dut.mmu_quiescent_o != 0; },
           "MMU quiescence after configuration");
}

void configure_context(Dut& dut, std::uint8_t context, std::uint8_t mode,
                       std::uint32_t root_ppn, std::uint32_t asid,
                       bool allow_load = true, bool allow_store = true) {
  cfg_write(dut, context, kCfgValid, 0);
  cfg_write(dut, context, kCfgMode, mode);
  cfg_write(dut, context, kCfgRootPpn, root_ppn);
  cfg_write(dut, context, kCfgAsid, asid);
  cfg_write(dut, context, kCfgPrivilege, kPrivilegeUser);
  cfg_write(dut, context, kCfgMxr, 0);
  cfg_write(dut, context, kCfgSum, 0);
  cfg_write(dut, context, kCfgAllowFetch, 0);
  cfg_write(dut, context, kCfgAllowLoad, allow_load ? 1U : 0U);
  cfg_write(dut, context, kCfgAllowStore, allow_store ? 1U : 0U);
  cfg_write(dut, context, kCfgValid, 1);
}

struct Response {
  std::uint32_t rdata;
  std::uint8_t fault;
};

void issue_request(Dut& dut, const std::string& label, std::uint8_t op,
                   std::uint8_t address_space, std::uint32_t eaddr,
                   std::uint8_t context, std::uint32_t wdata = 0,
                   std::uint8_t wstrb = 0) {
  wait_for(dut, [&dut]() { return dut.dmem_req_ready_o != 0; },
           label + " dmem ready");
  dut.dmem_req_op_i = op;
  dut.dmem_req_eaddr_i = eaddr;
  dut.dmem_req_addr_space_i = address_space;
  dut.dmem_req_addr_context_i = context;
  dut.dmem_req_wdata_i = wdata;
  dut.dmem_req_wstrb_i = wstrb;
  dut.dmem_req_valid_i = 1;
  eval_low(dut);
  expect_eq(label + " request handshakes", 1, dut.dmem_req_ready_o);
  tick(dut);
  dut.dmem_req_valid_i = 0;
  eval_low(dut);
}

Response collect_response(Dut& dut, const std::string& label,
                          unsigned hold_cycles = 2,
                          bool expect_protocol_error = false) {
  wait_for(dut, [&dut]() { return dut.dmem_rsp_valid_o != 0; },
           label + " dmem response");
  const Response response{
      static_cast<std::uint32_t>(dut.dmem_rsp_rdata_o),
      static_cast<std::uint8_t>(dut.dmem_rsp_fault_cause_o)};

  for (unsigned cycle = 0; cycle < hold_cycles; ++cycle) {
    tick(dut);
    expect_eq(label + " response holds valid", 1,
              dut.dmem_rsp_valid_o);
    expect_eq(label + " response holds data", response.rdata,
              dut.dmem_rsp_rdata_o);
    expect_eq(label + " response holds fault", response.fault,
              dut.dmem_rsp_fault_cause_o);
  }

  dut.dmem_rsp_ready_i = 1;
  tick(dut);
  dut.dmem_rsp_ready_i = 0;
  eval_low(dut);
  expect_eq(label + " response retires", 0, dut.dmem_rsp_valid_o);
  wait_for(dut, [&dut]() { return dut.internal_quiescent_o != 0; },
           label + " wrapper returns quiescent");
  expect_eq(label + " protocol diagnostic",
            expect_protocol_error ? 1U : 0U, dut.protocol_error_o);
  ++completed_transactions;
  return response;
}

Response transact(Dut& dut, const std::string& label, std::uint8_t op,
                  std::uint8_t address_space, std::uint32_t eaddr,
                  std::uint8_t context, std::uint32_t wdata = 0,
                  std::uint8_t wstrb = 0, unsigned hold_cycles = 2,
                  bool expect_protocol_error = false) {
  issue_request(dut, label, op, address_space, eaddr, context, wdata,
                wstrb);
  return collect_response(dut, label, hold_cycles,
                          expect_protocol_error);
}

void expect_success(const std::string& label, const Response& response,
                    std::uint32_t expected_data) {
  expect_eq(label + " fault", kFaultNone, response.fault);
  expect_eq(label + " data", expected_data, response.rdata);
}

void expect_fault(const std::string& label, const Response& response,
                  std::uint8_t expected_fault) {
  expect_eq(label + " fault", expected_fault, response.fault);
}

void invalidate_all(Dut& dut) {
  const auto old_i_epoch = dut.i_tlb_epoch_o;
  const auto old_d_epoch = dut.d_tlb_epoch_o;

  dut.tlb_inv_req_scope_i = kInvAll;
  dut.tlb_inv_req_asid_i = 0;
  dut.tlb_inv_req_vaddr_i = 0;
  dut.tlb_inv_rsp_ready_i = 0;
  dut.tlb_inv_req_valid_i = 1;
  wait_for(dut, [&dut]() { return dut.tlb_inv_req_ready_o != 0; },
           "TLB invalidate request ready");
  tick(dut);
  dut.tlb_inv_req_valid_i = 0;

  wait_for(dut, [&dut]() { return dut.tlb_inv_rsp_valid_o != 0; },
           "TLB invalidate response");
  expect_eq("TLB invalidate status", kStatusOk,
            dut.tlb_inv_rsp_status_o);
  tick(dut);
  expect_eq("TLB invalidate response holds", 1,
            dut.tlb_inv_rsp_valid_o);
  dut.tlb_inv_rsp_ready_i = 1;
  tick(dut);
  dut.tlb_inv_rsp_ready_i = 0;
  wait_for(dut, [&dut]() { return dut.mmu_quiescent_o != 0; },
           "MMU quiescence after TLB invalidate");
  expect_eq("iTLB epoch advances", static_cast<std::uint64_t>(old_i_epoch + 1U),
            dut.i_tlb_epoch_o);
  expect_eq("dTLB epoch advances", static_cast<std::uint64_t>(old_d_epoch + 1U),
            dut.d_tlb_epoch_o);
}

void test_direct_and_physical_routes(Dut& dut) {
  std::cout << "[TEST] direct-local and physical endpoint routing\n";

  const auto direct_local =
      transact(dut, "direct local load", kLoad, kLocalSpace, 0x44, 0);
  expect_success("direct local load", direct_local, kLocalXor ^ 0x44U);
  expect_eq("direct local request count", 1, dut.local_req_count_o);
  expect_eq("direct local address", 0x44, dut.last_local_addr_o);

  const auto cache = transact(dut, "physical cache load", kLoad,
                              kPhysicalSpace, 0x1004, 0);
  expect_success("physical cache load", cache, kCacheXor ^ 0x1004U);
  expect_eq("cache request count", 1, dut.cache_req_count_o);
  expect_eq("cache effective address", 0x1004, dut.last_cache_eaddr_o);
  expect_eq("cache physical address", 0x1004, dut.last_cache_paddr_o);

  const auto uncached_store =
      transact(dut, "physical uncached store", kStore, kPhysicalSpace,
               0x2008, 0, 0xa1b2c3d4U, 0x5);
  expect_success("physical uncached store", uncached_store, 0);
  expect_eq("uncached request count", 1, dut.uncached_req_count_o);
  expect_eq("uncached operation is store", 1, dut.last_uncached_store_o);
  expect_eq("uncached write data", 0xa1b2c3d4U,
            dut.last_uncached_wdata_o);
  expect_eq("uncached byte strobe", 0x5, dut.last_uncached_wstrb_o);

  const auto device = transact(dut, "physical device load", kLoad,
                               kPhysicalSpace, 0x300c, 0);
  expect_success("physical device load", device, kDeviceXor ^ 0x300cU);
  expect_eq("device request count", 1, dut.device_req_count_o);

  const auto region_local =
      transact(dut, "region-selected local load", kLoad, kPhysicalSpace,
               0x4010, 0);
  expect_success("region-selected local load", region_local,
                 kLocalXor ^ 0x4010U);
  expect_eq("combined local request count", 2, dut.local_req_count_o);
  expect_eq("region-selected local address", 0x4010,
            dut.last_local_addr_o);
}

void test_translation_and_faults(Dut& dut) {
  std::cout << "[TEST] BARE translation, PTW fault and local rejects\n";

  configure_context(dut, 1, kModeBare, 0, 0x11);
  const auto translated =
      transact(dut, "translated BARE cache load", kLoad,
               kTranslatedSpace, 0x1014, 1);
  expect_success("translated BARE cache load", translated,
                 kCacheXor ^ 0x1014U);
  expect_eq("BARE path reaches cache", 2, dut.cache_req_count_o);
  expect_eq("BARE path does not walk", 0, dut.ptw_req_count_o);

  const auto invalid_context =
      transact(dut, "invalid translation context", kLoad,
               kTranslatedSpace, 0x1020, 3);
  expect_fault("invalid translation context", invalid_context,
               kFaultAccess);
  expect_eq("invalid context avoids endpoints", 2,
            dut.cache_req_count_o);

  configure_context(dut, 2, kModeSv32, 1, 0x22);
  dut.ptw_model_rsp_fault_i = kFaultBus;
  const auto ptw_fault =
      transact(dut, "Sv32 PTW bus fault", kLoad, kTranslatedSpace,
               0x80000000U, 2);
  expect_fault("Sv32 PTW bus fault", ptw_fault, kFaultBus);
  expect_eq("PTW request count after bus fault", 1, dut.ptw_req_count_o);
  expect_eq("PTW response count after bus fault", 1, dut.ptw_rsp_count_o);
  dut.ptw_model_rsp_fault_i = kFaultNone;

  const auto no_match = transact(dut, "physical region no-match", kLoad,
                                 kPhysicalSpace, 0x9000, 0);
  expect_fault("physical region no-match", no_match, kFaultAccess);

  const auto unaligned = transact(dut, "unaligned direct local", kLoad,
                                  kLocalSpace, 0x45, 0);
  expect_fault("unaligned direct local", unaligned, kFaultAccess);

  const auto bad_shape = transact(dut, "load with write strobe", kLoad,
                                  kLocalSpace, 0x48, 0, 0, 0x1, 2, true);
  expect_fault("load with write strobe", bad_shape, kFaultProtocol);

  dut.protocol_error_clear_i = 1;
  tick(dut);
  dut.protocol_error_clear_i = 0;
  eval_low(dut);
  expect_eq("protocol diagnostic clears", 0, dut.protocol_error_o);

  expect_eq("local rejects avoid endpoint", 2, dut.local_req_count_o);
  invalidate_all(dut);
}

void test_endpoint_backpressure(Dut& dut) {
  std::cout << "[TEST] endpoint request/response backpressure\n";

  const auto cache_before = dut.cache_req_count_o;
  dut.endpoint_req_enable_i =
      kAllEndpoints & ~(1U << kEndpointCacheable);
  issue_request(dut, "cache request stall", kLoad, kPhysicalSpace,
                0x1024, 0);
  for (unsigned cycle = 0; cycle < 4; ++cycle) tick(dut);
  expect_eq("stalled cache request not accepted", cache_before,
            dut.cache_req_count_o);
  expect_eq("LSU stays busy on cache request stall", 1, dut.lsu_busy_o);
  expect_eq("no response during cache request stall", 0,
            dut.dmem_rsp_valid_o);

  dut.endpoint_req_enable_i = kAllEndpoints;
  const auto cache_response = collect_response(dut, "cache request stall");
  expect_success("cache request stall", cache_response,
                 kCacheXor ^ 0x1024U);
  expect_eq("released cache request accepted", cache_before + 1U,
            dut.cache_req_count_o);

  const auto uncached_before = dut.uncached_req_count_o;
  dut.endpoint_rsp_enable_i =
      kAllEndpoints & ~(1U << kEndpointUncached);
  issue_request(dut, "uncached response stall", kLoad, kPhysicalSpace,
                0x2028, 0);
  wait_for(dut,
           [&dut, uncached_before]() {
             return dut.uncached_req_count_o == uncached_before + 1U;
           },
           "uncached endpoint request acceptance");
  for (unsigned cycle = 0; cycle < 4; ++cycle) tick(dut);
  expect_eq("no dmem response while endpoint response disabled", 0,
            dut.dmem_rsp_valid_o);
  expect_eq("uncached responder retains work", 1,
            (dut.endpoint_busy_o >> kEndpointUncached) & 1U);

  dut.endpoint_rsp_enable_i = kAllEndpoints;
  const auto uncached_response =
      collect_response(dut, "uncached response stall");
  expect_success("uncached response stall", uncached_response,
                 kUncachedXor ^ 0x2028U);
}

void test_reset_cancels_outstanding(Dut& dut) {
  std::cout << "[TEST] shared reset cancels an outstanding endpoint response\n";

  const auto device_before = dut.device_req_count_o;
  dut.endpoint_rsp_enable_i =
      kAllEndpoints & ~(1U << kEndpointDevice);
  issue_request(dut, "device transaction before reset", kLoad,
                kPhysicalSpace, 0x3030, 0);
  wait_for(dut,
           [&dut, device_before]() {
             return dut.device_req_count_o == device_before + 1U;
           },
           "device request before reset");
  tick(dut);
  expect_eq("device responder busy before reset", 1,
            (dut.endpoint_busy_o >> kEndpointDevice) & 1U);

  dut.rst_ni = 0;
  tick(dut);
  tick(dut);
  expect_eq("reset removes pending dmem response", 0,
            dut.dmem_rsp_valid_o);
  expect_eq("reset clears endpoint pending state", 0,
            dut.endpoint_busy_o);
  expect_eq("reset clears dmem accounting", 0, dut.dmem_req_count_o);

  clear_inputs(dut);
  dut.rst_ni = 1;
  wait_for_initialized(dut, "outstanding-reset recovery");
  for (unsigned cycle = 0; cycle < 4; ++cycle) tick(dut);
  expect_eq("cancelled response does not reappear", 0,
            dut.dmem_rsp_valid_o);

  const auto recovery = transact(dut, "post-reset local recovery", kLoad,
                                 kLocalSpace, 0x4c, 0);
  expect_success("post-reset local recovery", recovery,
                 kLocalXor ^ 0x4cU);
}

}  // namespace

double sc_time_stamp() { return static_cast<double>(sim_time); }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Dut dut;

  reset(dut);
  test_direct_and_physical_routes(dut);
  test_translation_and_faults(dut);
  test_endpoint_backpressure(dut);
  test_reset_cancels_outstanding(dut);

  expect_eq("final LSU protocol diagnostic", 0,
            dut.lsu_protocol_error_o);
  expect_eq("final MMU protocol diagnostic", 0,
            dut.mmu_protocol_error_o);
  expect_eq("final aggregate protocol diagnostic", 0,
            dut.protocol_error_o);
  expect_eq("final wrapper quiescent", 1, dut.internal_quiescent_o);
  expect_eq("post-reset request accounting", 1, dut.dmem_req_count_o);
  expect_eq("post-reset response accounting", 1, dut.dmem_rsp_count_o);
  expect_eq("post-reset local endpoint request accounting", 1,
            dut.local_req_count_o);
  expect_eq("post-reset local endpoint response accounting", 1,
            dut.local_rsp_count_o);
  expect_eq("final endpoint responders idle", 0, dut.endpoint_busy_o);
  expect_eq("final PTW responder idle", 0, dut.ptw_model_busy_o);

  std::cout << "PASS vsp_dmem_subsystem_wrapper " << checks
            << " checks, " << completed_transactions
            << " completed transactions, " << sim_time
            << " half-cycles\n";
  dut.final();
  return EXIT_SUCCESS;
}
