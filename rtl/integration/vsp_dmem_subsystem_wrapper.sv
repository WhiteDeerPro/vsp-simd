// SPDX-License-Identifier: MIT

`default_nettype none

// VSP-owned blocking data-memory subsystem boundary.
//
// The upstream interface is deliberately identical to the current 32-bit
// effective-address dmem boundary of vsp_vector_memory_engine.  This wrapper
// owns address-space classification, the data client of the shared MMU, final
// physical-region classification, and endpoint dispatch.  It does not own an
// endpoint implementation, a physical fabric, or global-maintenance policy.
//
// The exposed instruction translation client shares the MMU/PTW with the LSU,
// but instruction-side physical-region selection remains the future IFetch
// integration's responsibility.
module vsp_dmem_subsystem_wrapper #(
  parameter integer PADDR_W = 40,
  parameter logic TRANSLATION_ENABLE = 1'b1,
  parameter integer MMU_CONTEXT_COUNT = 8,
  parameter integer ASID_W = 9,
  parameter integer I_TLB_ENTRY_COUNT = 8,
  parameter integer D_TLB_ENTRY_COUNT = 16,
  parameter integer TLB_EPOCH_W = 16,

  parameter integer REGION_COUNT = 4,
  parameter integer REGION_INDEX_W =
      (REGION_COUNT <= 1) ? 1 : $clog2(REGION_COUNT),
  parameter logic [REGION_COUNT-1:0] REGION_ENABLE = '0,
  parameter logic [REGION_COUNT*PADDR_W-1:0] REGION_BASE = '0,
  parameter logic [REGION_COUNT*PADDR_W-1:0] REGION_MASK = '0,
  parameter logic [
      REGION_COUNT*vsp_mem_common_pkg::VSP_MEM_ENDPOINT_W-1:0
  ] REGION_ENDPOINT = '0,
  parameter logic [REGION_COUNT-1:0] REGION_READ_OK = '0,
  parameter logic [REGION_COUNT-1:0] REGION_WRITE_OK = '0,
  parameter logic [REGION_COUNT-1:0] REGION_EXECUTE_OK = '0,
  parameter logic [REGION_COUNT-1:0] REGION_IDEMPOTENT = '0
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Current VSP 32-bit effective-address data-memory ABI.
  input  logic                                      dmem_req_valid_i,
  output logic                                      dmem_req_ready_o,
  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0]         dmem_req_op_i,
  input  logic [31:0]                               dmem_req_eaddr_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] dmem_req_addr_space_i,
  input  logic [7:0]                                dmem_req_addr_context_i,
  input  logic [31:0]                               dmem_req_wdata_i,
  input  logic [3:0]                                dmem_req_wstrb_i,
  output logic                                      dmem_rsp_valid_o,
  input  logic                                      dmem_rsp_ready_i,
  output logic [31:0]                               dmem_rsp_rdata_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     dmem_rsp_fault_cause_o,

  // Future IFetch translation client.  The shared MMU accepts FETCH only on
  // this port and returns a translated paddr or the original-vaddr fault.
  input  logic                                      i_tr_req_valid_i,
  output logic                                      i_tr_req_ready_o,
  input  logic [vsp_mmu_pkg::VSP_MMU_VADDR_W-1:0]  i_tr_req_vaddr_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0]
                                                     i_tr_req_addr_context_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_ACCESS_W-1:0]
                                                     i_tr_req_access_i,
  output logic                                      i_tr_rsp_valid_o,
  input  logic                                      i_tr_rsp_ready_i,
  output logic [PADDR_W-1:0]                        i_tr_rsp_paddr_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     i_tr_rsp_fault_o,
  output logic [vsp_mmu_pkg::VSP_MMU_VADDR_W-1:0]
                                                     i_tr_rsp_fault_vaddr_o,

  // Protocol-neutral MMU context-table configuration.  The MMU only gates
  // this against its own quiescence; system integration must also stop new
  // I/D admission and wait for lsu_idle_o before changing a live context.
  input  logic                                      mmu_cfg_valid_i,
  output logic                                      mmu_cfg_ready_o,
  input  logic                                      mmu_cfg_write_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0]
                                                     mmu_cfg_context_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_CFG_FIELD_W-1:0]
                                                     mmu_cfg_field_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0]
                                                     mmu_cfg_wdata_i,
  output logic                                      mmu_cfg_rsp_valid_o,
  input  logic                                      mmu_cfg_rsp_ready_i,
  output logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0]
                                                     mmu_cfg_rsp_rdata_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
                                                     mmu_cfg_rsp_status_o,

  // Coordinated invalidate for both private TLBs.  As with configuration,
  // the caller owns full I/D quiescence so a request already held above the
  // MMU cannot enter after the invalidate and observe an unintended epoch.
  input  logic                                      tlb_inv_req_valid_i,
  output logic                                      tlb_inv_req_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_TLB_INV_SCOPE_W-1:0]
                                                     tlb_inv_req_scope_i,
  input  logic [ASID_W-1:0]                         tlb_inv_req_asid_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_VADDR_W-1:0]
                                                     tlb_inv_req_vaddr_i,
  output logic                                      tlb_inv_rsp_valid_o,
  input  logic                                      tlb_inv_rsp_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
                                                     tlb_inv_rsp_status_o,

  // Dedicated physical, read-only PTW port.  It must bypass this wrapper's
  // address-space router and must never be fed back into translation.
  output logic                                      ptw_mem_req_valid_o,
  input  logic                                      ptw_mem_req_ready_i,
  output logic [PADDR_W-1:0]                        ptw_mem_req_paddr_o,
  input  logic                                      ptw_mem_rsp_valid_i,
  output logic                                      ptw_mem_rsp_ready_o,
  input  logic [31:0]                               ptw_mem_rsp_rdata_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     ptw_mem_rsp_fault_i,
  output logic                                      ptw_pte_fault_paddr_valid_o,
  output logic [PADDR_W-1:0]                        ptw_pte_fault_paddr_o,

  // CACHEABLE endpoint.  Both addresses are retained so an adapter can use
  // paddr below the cache while attributing a fault to the original eaddr.
  output logic                                      cache_req_valid_o,
  input  logic                                      cache_req_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_ACCESS_W-1:0]
                                                     cache_req_access_o,
  output logic [31:0]                               cache_req_eaddr_o,
  output logic [PADDR_W-1:0]                        cache_req_paddr_o,
  output logic [31:0]                               cache_req_wdata_o,
  output logic [3:0]                                cache_req_wstrb_o,
  input  logic                                      cache_rsp_valid_i,
  output logic                                      cache_rsp_ready_o,
  input  logic [31:0]                               cache_rsp_rdata_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     cache_rsp_fault_cause_i,

  // LOCAL endpoint.  A direct LOCAL request presents zero-extended eaddr;
  // region-selected LOCAL presents the final paddr.
  output logic                                      local_req_valid_o,
  input  logic                                      local_req_ready_i,
  output logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0]
                                                     local_req_op_o,
  output logic [PADDR_W-1:0]                        local_req_addr_o,
  output logic [31:0]                               local_req_wdata_o,
  output logic [3:0]                                local_req_wstrb_o,
  input  logic                                      local_rsp_valid_i,
  output logic                                      local_rsp_ready_o,
  input  logic [31:0]                               local_rsp_rdata_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     local_rsp_fault_cause_i,

  // UNCACHED normal-memory endpoint.
  output logic                                      uncached_req_valid_o,
  input  logic                                      uncached_req_ready_i,
  output logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0]
                                                     uncached_req_op_o,
  output logic [PADDR_W-1:0]                        uncached_req_addr_o,
  output logic [31:0]                               uncached_req_wdata_o,
  output logic [3:0]                                uncached_req_wstrb_o,
  input  logic                                      uncached_rsp_valid_i,
  output logic                                      uncached_rsp_ready_o,
  input  logic [31:0]                               uncached_rsp_rdata_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     uncached_rsp_fault_cause_i,

  // Side-effecting DEVICE endpoint.
  output logic                                      device_req_valid_o,
  input  logic                                      device_req_ready_i,
  output logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0]
                                                     device_req_op_o,
  output logic [PADDR_W-1:0]                        device_req_addr_o,
  output logic [31:0]                               device_req_wdata_o,
  output logic [3:0]                                device_req_wstrb_o,
  input  logic                                      device_rsp_valid_i,
  output logic                                      device_rsp_ready_o,
  input  logic [31:0]                               device_rsp_rdata_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     device_rsp_fault_cause_i,

  // Blocking LSU barrier ingress.
  input  logic                                      barrier_valid_i,
  output logic                                      barrier_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_BARRIER_OP_W-1:0]
                                                     barrier_op_i,
  input  logic [31:0]                               barrier_eaddr_i,
  input  logic [7:0]                                barrier_context_i,
  output logic                                      barrier_rsp_valid_o,
  input  logic                                      barrier_rsp_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     barrier_rsp_status_o,

  // Narrow LSU intent forwarded to an integration-owned maintenance-policy
  // bridge.  This is not the COMMON 4-bit global-maintenance interface.
  output logic                                      policy_maint_req_valid_o,
  input  logic                                      policy_maint_req_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_BARRIER_OP_W-1:0]
                                                     policy_maint_req_op_o,
  output logic [31:0]                               policy_maint_req_eaddr_o,
  output logic [7:0]                                policy_maint_req_context_o,
  input  logic                                      policy_maint_rsp_valid_i,
  output logic                                      policy_maint_rsp_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     policy_maint_rsp_fault_i,

  // Integration and diagnostic status.  internal_quiescent excludes any
  // state retained behind the four endpoint and PTW interfaces.
  output logic                                      lsu_idle_o,
  output logic                                      lsu_busy_o,
  output logic                                      space_router_idle_o,
  output logic                                      region_router_idle_o,
  output logic                                      region_config_overlap_o,
  output logic                                      region_diag_rsp_valid_o,
  output logic                                      region_diag_match_valid_o,
  output logic [REGION_INDEX_W-1:0]                 region_diag_match_index_o,
  output logic                                      region_diag_overlap_o,
  output logic                                      region_diag_endpoint_valid_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_ENDPOINT_W-1:0]
                                                     region_diag_endpoint_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     region_diag_fault_o,
  output logic                                      mmu_init_done_o,
  output logic                                      mmu_quiescent_o,
  output logic                                      mmu_busy_o,
  output logic [TLB_EPOCH_W-1:0]                    i_tlb_epoch_o,
  output logic [TLB_EPOCH_W-1:0]                    d_tlb_epoch_o,
  output logic                                      i_tlb_epoch_exhausted_o,
  output logic                                      d_tlb_epoch_exhausted_o,
  output logic                                      internal_quiescent_o,
  output logic                                      internal_busy_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      lsu_protocol_error_o,
  output logic                                      mmu_protocol_error_o,
  output logic                                      protocol_error_o
);

  logic space_req_valid;
  logic space_req_ready;
  logic [31:0] space_req_eaddr;
  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
        space_req_addr_space;
  logic [vsp_mem_common_pkg::VSP_MEM_ACCESS_W-1:0] space_req_access;
  logic [7:0] space_req_context;
  logic space_rsp_valid;
  logic space_rsp_ready;
  logic space_rsp_route_valid;
  logic [vsp_address_region_router_pkg::VSP_ADDR_ROUTE_W-1:0]
        space_rsp_route;
  logic [31:0] space_rsp_eaddr;
  logic [PADDR_W-1:0] space_rsp_paddr;
  logic [vsp_mem_common_pkg::VSP_MEM_ACCESS_W-1:0] space_rsp_access;
  logic [7:0] space_rsp_context;
  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0] space_rsp_fault;

  logic d_tr_req_valid;
  logic d_tr_req_ready;
  logic [31:0] d_tr_req_vaddr;
  logic [7:0] d_tr_req_addr_context;
  logic [vsp_mem_common_pkg::VSP_MEM_ACCESS_W-1:0] d_tr_req_access;
  logic d_tr_rsp_valid;
  logic d_tr_rsp_ready;
  logic [PADDR_W-1:0] d_tr_rsp_paddr;
  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0] d_tr_rsp_fault;
  logic [31:0] d_tr_rsp_fault_vaddr;

  logic region_req_valid;
  logic region_req_ready;
  logic [PADDR_W-1:0] region_req_paddr;
  logic [vsp_mem_common_pkg::VSP_MEM_ACCESS_W-1:0] region_req_access;
  logic [7:0] region_req_context;
  logic region_rsp_valid;
  logic region_rsp_ready;
  logic region_rsp_endpoint_valid;
  logic [vsp_mem_common_pkg::VSP_MEM_ENDPOINT_W-1:0] region_rsp_endpoint;
  logic region_rsp_read_ok;
  logic region_rsp_write_ok;
  logic region_rsp_execute_ok;
  logic region_rsp_idempotent;
  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0] region_rsp_fault;
  logic region_rsp_match_valid;
  logic [REGION_INDEX_W-1:0] region_rsp_match_index;
  logic region_rsp_overlap;

  initial begin : p_integration_guards
    if (vsp_mem_common_pkg::VSP_MEM_COMMON_ABI_MAJOR != 1)
      $fatal(1, "vsp_dmem_subsystem_wrapper: unsupported COMMON ABI major");
    if (vsp_lsu_backend_pkg::VSP_LSU_BACKEND_ABI_MAJOR != 1)
      $fatal(1, "vsp_dmem_subsystem_wrapper: unsupported LSU ABI major");
    if (vsp_mmu_pkg::VSP_MMU_ABI_MAJOR != 1)
      $fatal(1, "vsp_dmem_subsystem_wrapper: unsupported MMU ABI major");

    if ((PADDR_W != 32) && (PADDR_W != 40))
      $fatal(1, "vsp_dmem_subsystem_wrapper: PADDR_W must be 32 or 40");
    if ((TRANSLATION_ENABLE !== 1'b0) &&
        (TRANSLATION_ENABLE !== 1'b1))
      $fatal(1, "vsp_dmem_subsystem_wrapper: TRANSLATION_ENABLE must be zero or one");
    if (vsp_mmu_pkg::VSP_MMU_VADDR_W != 32)
      $fatal(1, "vsp_dmem_subsystem_wrapper: MMU vaddr must be 32 bits");
    if (vsp_mmu_pkg::VSP_MMU_CONTEXT_W != 8)
      $fatal(1, "vsp_dmem_subsystem_wrapper: MMU context must be 8 bits");
    if (vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W != 32)
      $fatal(1, "vsp_dmem_subsystem_wrapper: MMU cfg data must be 32 bits");
    if ((vsp_mmu_pkg::VSP_MMU_MODE_W != 1) ||
        (vsp_mmu_pkg::VSP_MMU_MODE_BARE != 1'b0) ||
        (vsp_mmu_pkg::VSP_MMU_MODE_SV32 != 1'b1) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_FIELD_W != 4) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_VALID != 4'd0) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_MODE != 4'd1) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_ROOT_PPN != 4'd2) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_ASID != 4'd3) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_PRIVILEGE != 4'd4) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_MXR != 4'd5) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_SUM != 4'd6) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_ALLOW_FETCH != 4'd7) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_ALLOW_LOAD != 4'd8) ||
        (vsp_mmu_pkg::VSP_MMU_CFG_ALLOW_STORE != 4'd9))
      $fatal(1, "vsp_dmem_subsystem_wrapper: MMU encoding mismatch");

    if ((vsp_mem_common_pkg::VSP_MEM_ACCESS_W != 2) ||
        (vsp_mem_common_pkg::VSP_MEM_ACCESS_LOAD != 2'd0) ||
        (vsp_mem_common_pkg::VSP_MEM_ACCESS_STORE != 2'd1) ||
        (vsp_mem_common_pkg::VSP_MEM_ACCESS_FETCH != 2'd2) ||
        (vsp_mem_common_pkg::VSP_MEM_ENDPOINT_W != 2) ||
        (vsp_mem_common_pkg::VSP_MEM_ENDPOINT_CACHEABLE != 2'd0) ||
        (vsp_mem_common_pkg::VSP_MEM_ENDPOINT_UNCACHED != 2'd1) ||
        (vsp_mem_common_pkg::VSP_MEM_ENDPOINT_DEVICE != 2'd2) ||
        (vsp_mem_common_pkg::VSP_MEM_ENDPOINT_LOCAL != 2'd3))
      $fatal(1, "vsp_dmem_subsystem_wrapper: COMMON access/endpoint encoding mismatch");

    if (vsp_pkg::VSP_MEM_OP_W != vsp_lsu_backend_pkg::VSP_LSU_OP_W)
      $fatal(1, "vsp_dmem_subsystem_wrapper: VSP/LSU op width mismatch");
    if ((vsp_pkg::VSP_MEM_OP_LOAD !=
         vsp_lsu_backend_pkg::VSP_LSU_OP_LOAD) ||
        (vsp_pkg::VSP_MEM_OP_STORE !=
         vsp_lsu_backend_pkg::VSP_LSU_OP_STORE))
      $fatal(1, "vsp_dmem_subsystem_wrapper: VSP/LSU op encoding mismatch");

    if (vsp_pkg::VSP_MEM_ADDR_SPACE_W !=
        vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W)
      $fatal(1, "vsp_dmem_subsystem_wrapper: address-space width mismatch");
    if ((vsp_pkg::VSP_MEM_ADDR_SPACE_LOCAL !=
         vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_LOCAL) ||
        (vsp_pkg::VSP_MEM_ADDR_SPACE_PHYSICAL !=
         vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_PHYSICAL) ||
        (vsp_pkg::VSP_MEM_ADDR_SPACE_TRANSLATED !=
         vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_TRANSLATED))
      $fatal(1, "vsp_dmem_subsystem_wrapper: address-space encoding mismatch");

    if (vsp_pkg::VSP_MEM_FAULT_CAUSE_W !=
        vsp_mem_common_pkg::VSP_MEM_FAULT_W)
      $fatal(1, "vsp_dmem_subsystem_wrapper: fault width mismatch");
    if ((vsp_pkg::VSP_MEM_FAULT_NONE !=
         vsp_mem_common_pkg::VSP_MEM_FAULT_NONE) ||
        (vsp_pkg::VSP_MEM_FAULT_TRANSLATION !=
         vsp_mem_common_pkg::VSP_MEM_FAULT_TRANSLATION) ||
        (vsp_pkg::VSP_MEM_FAULT_PERMISSION !=
         vsp_mem_common_pkg::VSP_MEM_FAULT_PERMISSION) ||
        (vsp_pkg::VSP_MEM_FAULT_ACCESS !=
         vsp_mem_common_pkg::VSP_MEM_FAULT_ACCESS) ||
        (vsp_pkg::VSP_MEM_FAULT_BUS !=
         vsp_mem_common_pkg::VSP_MEM_FAULT_BUS) ||
        (vsp_pkg::VSP_MEM_FAULT_DATA_INTEGRITY !=
         vsp_mem_common_pkg::VSP_MEM_FAULT_DATA_INTEGRITY) ||
        (vsp_pkg::VSP_MEM_FAULT_PROTOCOL !=
         vsp_mem_common_pkg::VSP_MEM_FAULT_PROTOCOL))
      $fatal(1, "vsp_dmem_subsystem_wrapper: fault encoding mismatch");

    if ((vsp_address_region_router_pkg::VSP_ADDR_ROUTE_W !=
         vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W) ||
        (vsp_address_region_router_pkg::VSP_ADDR_ROUTE_LOCAL !=
         vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_LOCAL) ||
        (vsp_address_region_router_pkg::VSP_ADDR_ROUTE_PHYSICAL !=
         vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_PHYSICAL) ||
        (vsp_address_region_router_pkg::VSP_ADDR_ROUTE_TRANSLATED !=
         vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_TRANSLATED))
      $fatal(1, "vsp_dmem_subsystem_wrapper: router/common encoding mismatch");
  end

  assign internal_quiescent_o = lsu_idle_o && space_router_idle_o &&
                                region_router_idle_o && mmu_quiescent_o;
  assign internal_busy_o = !internal_quiescent_o;
  assign protocol_error_o = lsu_protocol_error_o || mmu_protocol_error_o;

  assign region_diag_rsp_valid_o = region_rsp_valid;
  assign region_diag_match_valid_o = region_rsp_match_valid;
  assign region_diag_match_index_o = region_rsp_match_index;
  assign region_diag_overlap_o = region_rsp_overlap;
  assign region_diag_endpoint_valid_o = region_rsp_endpoint_valid;
  assign region_diag_endpoint_o = region_rsp_endpoint;
  assign region_diag_fault_o = region_rsp_fault;

  vsp_address_space_router #(
    .PADDR_W(PADDR_W)
  ) u_address_space_router (
    .clk_i                   (clk_i),
    .rst_ni                  (rst_ni),
    .space_req_valid_i       (space_req_valid),
    .space_req_ready_o       (space_req_ready),
    .space_req_eaddr_i       (space_req_eaddr),
    .space_req_addr_space_i  (space_req_addr_space),
    .space_req_access_i      (space_req_access),
    .space_req_context_i     (space_req_context),
    .space_rsp_valid_o       (space_rsp_valid),
    .space_rsp_ready_i       (space_rsp_ready),
    .space_rsp_route_valid_o (space_rsp_route_valid),
    .space_rsp_route_o       (space_rsp_route),
    .space_rsp_eaddr_o       (space_rsp_eaddr),
    .space_rsp_paddr_o       (space_rsp_paddr),
    .space_rsp_access_o      (space_rsp_access),
    .space_rsp_context_o     (space_rsp_context),
    .space_rsp_fault_o       (space_rsp_fault),
    .idle_o                  (space_router_idle_o)
  );

  vsp_address_region_router #(
    .PADDR_W         (PADDR_W),
    .REGION_COUNT    (REGION_COUNT),
    .REGION_INDEX_W  (REGION_INDEX_W),
    .REGION_ENABLE   (REGION_ENABLE),
    .REGION_BASE     (REGION_BASE),
    .REGION_MASK     (REGION_MASK),
    .REGION_ENDPOINT (REGION_ENDPOINT),
    .REGION_READ_OK  (REGION_READ_OK),
    .REGION_WRITE_OK (REGION_WRITE_OK),
    .REGION_EXECUTE_OK(REGION_EXECUTE_OK),
    .REGION_IDEMPOTENT(REGION_IDEMPOTENT)
  ) u_address_region_router (
    .clk_i                       (clk_i),
    .rst_ni                      (rst_ni),
    .region_req_valid_i          (region_req_valid),
    .region_req_ready_o          (region_req_ready),
    .region_req_paddr_i          (region_req_paddr),
    .region_req_access_i         (region_req_access),
    .region_req_context_i        (region_req_context),
    .region_rsp_valid_o          (region_rsp_valid),
    .region_rsp_ready_i          (region_rsp_ready),
    .region_rsp_endpoint_valid_o (region_rsp_endpoint_valid),
    .region_rsp_endpoint_o       (region_rsp_endpoint),
    .region_rsp_read_ok_o        (region_rsp_read_ok),
    .region_rsp_write_ok_o       (region_rsp_write_ok),
    .region_rsp_execute_ok_o     (region_rsp_execute_ok),
    .region_rsp_idempotent_o     (region_rsp_idempotent),
    .region_rsp_fault_o          (region_rsp_fault),
    .region_rsp_match_valid_o    (region_rsp_match_valid),
    .region_rsp_match_index_o    (region_rsp_match_index),
    .region_rsp_overlap_o        (region_rsp_overlap),
    .region_config_overlap_o     (region_config_overlap_o),
    .idle_o                      (region_router_idle_o)
  );

  vsp_mmu #(
    .CONTEXT_COUNT     (MMU_CONTEXT_COUNT),
    .ASID_W            (ASID_W),
    .PADDR_W           (PADDR_W),
    .I_TLB_ENTRY_COUNT (I_TLB_ENTRY_COUNT),
    .D_TLB_ENTRY_COUNT (D_TLB_ENTRY_COUNT),
    .TLB_EPOCH_W       (TLB_EPOCH_W)
  ) u_mmu (
    .clk_i                          (clk_i),
    .rst_ni                         (rst_ni),
    .i_tr_req_valid_i               (i_tr_req_valid_i),
    .i_tr_req_ready_o               (i_tr_req_ready_o),
    .i_tr_req_vaddr_i               (i_tr_req_vaddr_i),
    .i_tr_req_addr_context_i        (i_tr_req_addr_context_i),
    .i_tr_req_access_i              (i_tr_req_access_i),
    .i_tr_rsp_valid_o               (i_tr_rsp_valid_o),
    .i_tr_rsp_ready_i               (i_tr_rsp_ready_i),
    .i_tr_rsp_paddr_o               (i_tr_rsp_paddr_o),
    .i_tr_rsp_fault_o               (i_tr_rsp_fault_o),
    .i_tr_rsp_fault_vaddr_o         (i_tr_rsp_fault_vaddr_o),
    .d_tr_req_valid_i               (d_tr_req_valid),
    .d_tr_req_ready_o               (d_tr_req_ready),
    .d_tr_req_vaddr_i               (d_tr_req_vaddr),
    .d_tr_req_addr_context_i        (d_tr_req_addr_context),
    .d_tr_req_access_i              (d_tr_req_access),
    .d_tr_rsp_valid_o               (d_tr_rsp_valid),
    .d_tr_rsp_ready_i               (d_tr_rsp_ready),
    .d_tr_rsp_paddr_o               (d_tr_rsp_paddr),
    .d_tr_rsp_fault_o               (d_tr_rsp_fault),
    .d_tr_rsp_fault_vaddr_o         (d_tr_rsp_fault_vaddr),
    .cfg_valid_i                    (mmu_cfg_valid_i),
    .cfg_ready_o                    (mmu_cfg_ready_o),
    .cfg_write_i                    (mmu_cfg_write_i),
    .cfg_context_i                  (mmu_cfg_context_i),
    .cfg_field_i                    (mmu_cfg_field_i),
    .cfg_wdata_i                    (mmu_cfg_wdata_i),
    .cfg_rsp_valid_o                (mmu_cfg_rsp_valid_o),
    .cfg_rsp_ready_i                (mmu_cfg_rsp_ready_i),
    .cfg_rsp_rdata_o                (mmu_cfg_rsp_rdata_o),
    .cfg_rsp_status_o               (mmu_cfg_rsp_status_o),
    .tlb_inv_req_valid_i            (tlb_inv_req_valid_i),
    .tlb_inv_req_ready_o            (tlb_inv_req_ready_o),
    .tlb_inv_req_scope_i            (tlb_inv_req_scope_i),
    .tlb_inv_req_asid_i             (tlb_inv_req_asid_i),
    .tlb_inv_req_vaddr_i            (tlb_inv_req_vaddr_i),
    .tlb_inv_rsp_valid_o            (tlb_inv_rsp_valid_o),
    .tlb_inv_rsp_ready_i            (tlb_inv_rsp_ready_i),
    .tlb_inv_rsp_status_o           (tlb_inv_rsp_status_o),
    .ptw_mem_req_valid_o            (ptw_mem_req_valid_o),
    .ptw_mem_req_ready_i            (ptw_mem_req_ready_i),
    .ptw_mem_req_paddr_o            (ptw_mem_req_paddr_o),
    .ptw_mem_rsp_valid_i            (ptw_mem_rsp_valid_i),
    .ptw_mem_rsp_ready_o            (ptw_mem_rsp_ready_o),
    .ptw_mem_rsp_rdata_i            (ptw_mem_rsp_rdata_i),
    .ptw_mem_rsp_fault_i            (ptw_mem_rsp_fault_i),
    .ptw_pte_fault_paddr_valid_o    (ptw_pte_fault_paddr_valid_o),
    .ptw_pte_fault_paddr_o          (ptw_pte_fault_paddr_o),
    .init_done_o                    (mmu_init_done_o),
    .quiescent_o                    (mmu_quiescent_o),
    .busy_o                         (mmu_busy_o),
    .i_tlb_epoch_o                  (i_tlb_epoch_o),
    .d_tlb_epoch_o                  (d_tlb_epoch_o),
    .i_tlb_epoch_exhausted_o        (i_tlb_epoch_exhausted_o),
    .d_tlb_epoch_exhausted_o        (d_tlb_epoch_exhausted_o),
    .protocol_error_o               (mmu_protocol_error_o),
    .protocol_error_clear_i         (protocol_error_clear_i)
  );

  vsp_lsu_backend #(
    .PADDR_W           (PADDR_W),
    .TRANSLATION_ENABLE(TRANSLATION_ENABLE)
  ) u_lsu (
    .clk_i                       (clk_i),
    .rst_ni                      (rst_ni),
    .req_valid_i                 (dmem_req_valid_i),
    .req_ready_o                 (dmem_req_ready_o),
    .req_op_i                    (dmem_req_op_i),
    .req_eaddr_i                 (dmem_req_eaddr_i),
    .req_addr_space_i            (dmem_req_addr_space_i),
    .req_addr_context_i          (dmem_req_addr_context_i),
    .req_wdata_i                 (dmem_req_wdata_i),
    .req_wstrb_i                 (dmem_req_wstrb_i),
    .rsp_valid_o                 (dmem_rsp_valid_o),
    .rsp_ready_i                 (dmem_rsp_ready_i),
    .rsp_rdata_o                 (dmem_rsp_rdata_o),
    .rsp_fault_cause_o           (dmem_rsp_fault_cause_o),
    .space_req_valid_o           (space_req_valid),
    .space_req_ready_i           (space_req_ready),
    .space_req_eaddr_o           (space_req_eaddr),
    .space_req_addr_space_o      (space_req_addr_space),
    .space_req_access_o          (space_req_access),
    .space_req_context_o         (space_req_context),
    .space_rsp_valid_i           (space_rsp_valid),
    .space_rsp_ready_o           (space_rsp_ready),
    .space_rsp_route_valid_i     (space_rsp_route_valid),
    .space_rsp_route_i           (space_rsp_route),
    .space_rsp_eaddr_i           (space_rsp_eaddr),
    .space_rsp_paddr_i           (space_rsp_paddr),
    .space_rsp_access_i          (space_rsp_access),
    .space_rsp_context_i         (space_rsp_context),
    .space_rsp_fault_i           (space_rsp_fault),
    .tr_req_valid_o              (d_tr_req_valid),
    .tr_req_ready_i              (d_tr_req_ready),
    .tr_req_vaddr_o              (d_tr_req_vaddr),
    .tr_req_addr_context_o       (d_tr_req_addr_context),
    .tr_req_access_o             (d_tr_req_access),
    .tr_rsp_valid_i              (d_tr_rsp_valid),
    .tr_rsp_ready_o              (d_tr_rsp_ready),
    .tr_rsp_paddr_i              (d_tr_rsp_paddr),
    .tr_rsp_fault_i              (d_tr_rsp_fault),
    .tr_rsp_fault_vaddr_i        (d_tr_rsp_fault_vaddr),
    .region_req_valid_o          (region_req_valid),
    .region_req_ready_i          (region_req_ready),
    .region_req_paddr_o          (region_req_paddr),
    .region_req_access_o         (region_req_access),
    .region_req_context_o        (region_req_context),
    .region_rsp_valid_i          (region_rsp_valid),
    .region_rsp_ready_o          (region_rsp_ready),
    .region_rsp_endpoint_valid_i (region_rsp_endpoint_valid),
    .region_rsp_endpoint_i       (region_rsp_endpoint),
    .region_rsp_match_valid_i    (region_rsp_match_valid),
    .region_rsp_fault_i          (region_rsp_fault),
    .cache_req_valid_o           (cache_req_valid_o),
    .cache_req_ready_i           (cache_req_ready_i),
    .cache_req_access_o          (cache_req_access_o),
    .cache_req_eaddr_o           (cache_req_eaddr_o),
    .cache_req_paddr_o           (cache_req_paddr_o),
    .cache_req_wdata_o           (cache_req_wdata_o),
    .cache_req_wstrb_o           (cache_req_wstrb_o),
    .cache_rsp_valid_i           (cache_rsp_valid_i),
    .cache_rsp_ready_o           (cache_rsp_ready_o),
    .cache_rsp_rdata_i           (cache_rsp_rdata_i),
    .cache_rsp_fault_cause_i     (cache_rsp_fault_cause_i),
    .local_req_valid_o           (local_req_valid_o),
    .local_req_ready_i           (local_req_ready_i),
    .local_req_op_o              (local_req_op_o),
    .local_req_addr_o            (local_req_addr_o),
    .local_req_wdata_o           (local_req_wdata_o),
    .local_req_wstrb_o           (local_req_wstrb_o),
    .local_rsp_valid_i           (local_rsp_valid_i),
    .local_rsp_ready_o           (local_rsp_ready_o),
    .local_rsp_rdata_i           (local_rsp_rdata_i),
    .local_rsp_fault_cause_i     (local_rsp_fault_cause_i),
    .uncached_req_valid_o        (uncached_req_valid_o),
    .uncached_req_ready_i        (uncached_req_ready_i),
    .uncached_req_op_o           (uncached_req_op_o),
    .uncached_req_addr_o         (uncached_req_addr_o),
    .uncached_req_wdata_o        (uncached_req_wdata_o),
    .uncached_req_wstrb_o        (uncached_req_wstrb_o),
    .uncached_rsp_valid_i        (uncached_rsp_valid_i),
    .uncached_rsp_ready_o        (uncached_rsp_ready_o),
    .uncached_rsp_rdata_i        (uncached_rsp_rdata_i),
    .uncached_rsp_fault_cause_i  (uncached_rsp_fault_cause_i),
    .device_req_valid_o          (device_req_valid_o),
    .device_req_ready_i          (device_req_ready_i),
    .device_req_op_o             (device_req_op_o),
    .device_req_addr_o           (device_req_addr_o),
    .device_req_wdata_o          (device_req_wdata_o),
    .device_req_wstrb_o          (device_req_wstrb_o),
    .device_rsp_valid_i          (device_rsp_valid_i),
    .device_rsp_ready_o          (device_rsp_ready_o),
    .device_rsp_rdata_i          (device_rsp_rdata_i),
    .device_rsp_fault_cause_i    (device_rsp_fault_cause_i),
    .barrier_valid_i             (barrier_valid_i),
    .barrier_ready_o             (barrier_ready_o),
    .barrier_op_i                (barrier_op_i),
    .barrier_eaddr_i             (barrier_eaddr_i),
    .barrier_context_i           (barrier_context_i),
    .barrier_rsp_valid_o         (barrier_rsp_valid_o),
    .barrier_rsp_ready_i         (barrier_rsp_ready_i),
    .barrier_rsp_status_o        (barrier_rsp_status_o),
    .maint_req_valid_o           (policy_maint_req_valid_o),
    .maint_req_ready_i           (policy_maint_req_ready_i),
    .maint_req_op_o              (policy_maint_req_op_o),
    .maint_req_eaddr_o           (policy_maint_req_eaddr_o),
    .maint_req_context_o         (policy_maint_req_context_o),
    .maint_rsp_valid_i           (policy_maint_rsp_valid_i),
    .maint_rsp_ready_o           (policy_maint_rsp_ready_o),
    .maint_rsp_fault_i           (policy_maint_rsp_fault_i),
    .idle_o                      (lsu_idle_o),
    .busy_o                      (lsu_busy_o),
    .protocol_error_o            (lsu_protocol_error_o),
    .protocol_error_clear_i      (protocol_error_clear_i)
  );

  // Region attributes are already enforced by the region router.  Preserve
  // them as explicitly named unused signals so later diagnostics can expose
  // more detail without changing the functional LSU connection.
  /* verilator lint_off UNUSED */
  wire unused_region_attributes = &{1'b0, region_rsp_read_ok,
      region_rsp_write_ok, region_rsp_execute_ok, region_rsp_idempotent};
  /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
