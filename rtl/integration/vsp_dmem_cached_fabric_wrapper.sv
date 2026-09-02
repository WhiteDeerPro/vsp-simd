// SPDX-License-Identifier: MIT

`default_nettype none

// Product-oriented D-side memory composition.
//
// This wrapper closes the endpoint seams of vsp_dmem_subsystem_wrapper with a
// writable D-cache, a private local SRAM, one ordered uncached/device adapter,
// and the shared physical fabric.  The fabric's I-cache-native master remains
// exposed so a later I-side integration can share the same lower port without
// changing the D-side composition.
//
// The lower port is deliberately protocol-neutral and single-outstanding.
// AXI/NoC adaptation, reset-epoch quarantine beyond lower_quiescent_i, and
// physical RAM/MMIO decode belong below this boundary.
module vsp_dmem_cached_fabric_wrapper #(
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
  parameter logic [REGION_COUNT-1:0] REGION_IDEMPOTENT = '0,

  parameter integer LOWER_DATA_W = 64,
  parameter integer DCACHE_LINE_BYTES = 32,
  parameter integer DCACHE_SET_COUNT = 64,
  parameter integer DCACHE_WAY_COUNT = 2,
  parameter integer DCACHE_RAM_RD_LATENCY = 1,
  parameter integer CACHE_REQ_ID_W = 1,
  parameter integer CACHE_USER_W = 1,
  parameter integer CACHE_MEM_BEATS_W =
      ((DCACHE_LINE_BYTES / (LOWER_DATA_W / 8)) <= 1) ? 1 :
      $clog2((DCACHE_LINE_BYTES / (LOWER_DATA_W / 8)) + 1),

  parameter logic [PADDR_W-1:0] LOCAL_BASE_ADDR = '0,
  parameter integer LOCAL_DEPTH_WORDS = 1024
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Current VSP blocking D-side beat.
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

  // Shared-MMU instruction translation client.  IFetch physical routing and
  // cache-beat assembly remain outside this D-side composition.
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

  // Direct D-cache maintenance seam.  The caller supplies an already
  // resolved physical address and owns admission quiescence/policy.
  input  logic                                      dcache_maint_req_valid_i,
  output logic                                      dcache_maint_req_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_CACHE_MAINT_OP_W-1:0]
                                                     dcache_maint_req_op_i,
  input  logic [PADDR_W-1:0]                        dcache_maint_req_paddr_i,
  output logic                                      dcache_maint_rsp_valid_o,
  input  logic                                      dcache_maint_rsp_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
                                                     dcache_maint_rsp_status_o,

  // LSU barrier remains a policy seam until global maintenance integration.
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

  // Optional I-cache native lower-memory master.  Tie request valids low when
  // no I-cache is present.  Widths match this wrapper's shared physical fabric.
  input  logic                                      ic_mem_cmd_valid_i,
  output logic                                      ic_mem_cmd_ready_o,
  input  logic [CACHE_REQ_ID_W-1:0]                 ic_mem_cmd_id_i,
  input  logic [cache_pkg::CACHE_MEM_OP_W-1:0]     ic_mem_cmd_op_i,
  input  logic [PADDR_W-1:0]                        ic_mem_cmd_paddr_i,
  input  logic [CACHE_MEM_BEATS_W-1:0]              ic_mem_cmd_beats_i,
  input  logic                                      ic_mem_w_valid_i,
  output logic                                      ic_mem_w_ready_o,
  input  logic [CACHE_REQ_ID_W-1:0]                 ic_mem_w_id_i,
  input  logic [LOWER_DATA_W-1:0]                   ic_mem_w_data_i,
  input  logic [(LOWER_DATA_W/8)-1:0]               ic_mem_wstrb_i,
  input  logic                                      ic_mem_w_last_i,
  output logic                                      ic_mem_r_valid_o,
  input  logic                                      ic_mem_r_ready_i,
  output logic [CACHE_REQ_ID_W-1:0]                 ic_mem_r_id_o,
  output logic [LOWER_DATA_W-1:0]                   ic_mem_r_data_o,
  output logic                                      ic_mem_r_last_o,
  output logic [cache_pkg::CACHE_STATUS_W-1:0]     ic_mem_r_status_o,
  output logic [PADDR_W-1:0]                        ic_mem_r_fault_paddr_o,
  output logic                                      ic_mem_b_valid_o,
  input  logic                                      ic_mem_b_ready_i,
  output logic [CACHE_REQ_ID_W-1:0]                 ic_mem_b_id_o,
  output logic [cache_pkg::CACHE_STATUS_W-1:0]     ic_mem_b_status_o,
  output logic [PADDR_W-1:0]                        ic_mem_b_fault_paddr_o,

  // Shared physical-fabric drain and ordered lower-memory boundary.
  input  logic                                      fabric_drain_req_i,
  output logic                                      fabric_drain_done_o,
  output logic                                      lower_req_valid_o,
  input  logic                                      lower_req_ready_i,
  output logic                                      lower_req_write_o,
  output logic [PADDR_W-1:0]                        lower_req_paddr_o,
  output logic [LOWER_DATA_W-1:0]                   lower_req_wdata_o,
  output logic [(LOWER_DATA_W/8)-1:0]               lower_req_wstrb_o,
  input  logic                                      lower_rsp_valid_i,
  output logic                                      lower_rsp_ready_o,
  input  logic [LOWER_DATA_W-1:0]                   lower_rsp_rdata_i,
  input  logic [vsp_memory_endpoints_pkg::VSP_LOWER_STATUS_W-1:0]
                                                     lower_rsp_status_i,
  input  logic                                      lower_quiescent_i,

  // Integration status and diagnostics.
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
  output logic                                      ptw_pte_fault_paddr_valid_o,
  output logic [PADDR_W-1:0]                        ptw_pte_fault_paddr_o,
  output logic                                      dcache_init_busy_o,
  output logic                                      dcache_init_done_o,
  output logic                                      dcache_idle_o,
  output logic                                      local_idle_o,
  output logic                                      uncached_device_idle_o,
  output logic                                      fabric_idle_o,
  output logic                                      fabric_busy_o,
  output logic                                      fabric_quarantine_o,
  output logic                                      fabric_owner_valid_o,
  output logic [vsp_physical_fabric_pkg::VSP_FABRIC_OWNER_W-1:0]
                                                     fabric_owner_o,
  output logic                                      dmem_path_ready_o,
  output logic                                      dmem_path_quiescent_o,
  output logic                                      dmem_path_busy_o,
  output logic                                      perf_dcache_read_hit_o,
  output logic                                      perf_dcache_read_miss_o,
  output logic                                      perf_dcache_write_hit_o,
  output logic                                      perf_dcache_write_miss_o,
  // Clears diagnostics in children that provide a software-clear input.
  // The imported D-cache adapter diagnostic is reset-only sticky; its
  // dedicated output, and therefore the aggregate, can remain asserted until
  // reset.  Keeping that distinction visible avoids silently losing evidence.
  input  logic                                      protocol_error_clear_i,
  output logic                                      lsu_protocol_error_o,
  output logic                                      mmu_protocol_error_o,
  output logic                                      dcache_protocol_error_o,
  output logic                                      endpoint_merge_protocol_error_o,
  output logic                                      fabric_protocol_error_o,
  output logic                                      protocol_error_o
);
  import cache_pkg::*;
  import vsp_mem_common_pkg::*;
  import vsp_memory_endpoints_pkg::*;

  logic inner_quiescent;
  logic inner_busy;
  logic inner_protocol_error;
  logic inner_dmem_req_valid;
  logic inner_dmem_req_ready;

  logic cache_req_valid;
  logic cache_req_ready;
  logic [VSP_MEM_ACCESS_W-1:0] cache_req_access;
  logic [31:0] cache_req_eaddr;
  logic [PADDR_W-1:0] cache_req_paddr;
  logic [31:0] cache_req_wdata;
  logic [3:0] cache_req_wstrb;
  logic cache_rsp_valid;
  logic cache_rsp_ready;
  logic [31:0] cache_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] cache_rsp_fault;
  logic [31:0] dcache_rsp_fault_eaddr;
  logic [PADDR_W-1:0] dcache_rsp_fault_paddr;

  logic local_req_valid;
  logic local_req_ready;
  logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0] local_req_op;
  logic [PADDR_W-1:0] local_req_addr;
  logic [31:0] local_req_wdata;
  logic [3:0] local_req_wstrb;
  logic local_rsp_valid;
  logic local_rsp_ready;
  logic [31:0] local_rsp_rdata;
  logic [VSP_ENDPOINT_FAULT_W-1:0] local_rsp_fault_endpoint;
  logic [VSP_MEM_FAULT_W-1:0] local_rsp_fault;
  logic [VSP_ENDPOINT_OP_W-1:0] local_req_endpoint_op;

  logic uncached_req_valid;
  logic uncached_req_ready;
  logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0] uncached_req_op;
  logic [PADDR_W-1:0] uncached_req_addr;
  logic [31:0] uncached_req_wdata;
  logic [3:0] uncached_req_wstrb;
  logic uncached_rsp_valid;
  logic uncached_rsp_ready;
  logic [31:0] uncached_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] uncached_rsp_fault;
  logic [VSP_ENDPOINT_OP_W-1:0] uncached_req_endpoint_op;
  logic [VSP_ENDPOINT_FAULT_W-1:0] uncached_rsp_fault_endpoint;

  logic device_req_valid;
  logic device_req_ready;
  logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0] device_req_op;
  logic [PADDR_W-1:0] device_req_addr;
  logic [31:0] device_req_wdata;
  logic [3:0] device_req_wstrb;
  logic device_rsp_valid;
  logic device_rsp_ready;
  logic [31:0] device_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] device_rsp_fault;
  logic [VSP_ENDPOINT_OP_W-1:0] device_req_endpoint_op;
  logic [VSP_ENDPOINT_FAULT_W-1:0] device_rsp_fault_endpoint;

  logic merged_req_valid;
  logic merged_req_ready;
  logic [VSP_ENDPOINT_OP_W-1:0] merged_req_op;
  logic [PADDR_W-1:0] merged_req_addr;
  logic [31:0] merged_req_wdata;
  logic [3:0] merged_req_wstrb;
  logic merged_rsp_valid;
  logic merged_rsp_ready;
  logic [31:0] merged_rsp_rdata;
  logic [VSP_ENDPOINT_FAULT_W-1:0] merged_rsp_fault;
  logic endpoint_merge_idle;

  logic uc_lower_req_valid;
  logic uc_lower_req_ready;
  logic uc_lower_req_write;
  logic [PADDR_W-1:0] uc_lower_req_addr;
  logic [31:0] uc_lower_req_wdata;
  logic [3:0] uc_lower_req_wstrb;
  logic uc_lower_rsp_valid;
  logic uc_lower_rsp_ready;
  logic [31:0] uc_lower_rsp_rdata;
  logic [VSP_LOWER_STATUS_W-1:0] uc_lower_rsp_status;
  logic [PADDR_W-1:0] uc_lower_rsp_fault_paddr;
  logic uc_adapter_idle;

  logic ptw_mem_req_valid;
  logic ptw_mem_req_ready;
  logic [PADDR_W-1:0] ptw_mem_req_paddr;
  logic ptw_mem_rsp_valid;
  logic ptw_mem_rsp_ready;
  logic [31:0] ptw_mem_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] ptw_mem_rsp_fault;
  logic [PADDR_W-1:0] ptw_mem_rsp_fault_paddr;

  logic dc_cache_req_valid;
  logic dc_cache_req_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_cache_req_id;
  logic [CACHE_REQ_OP_W-1:0] dc_cache_req_op;
  logic [PADDR_W-1:0] dc_cache_req_paddr;
  logic [31:0] dc_cache_req_wdata;
  logic [3:0] dc_cache_req_wstrb;
  logic [CACHE_USER_W-1:0] dc_cache_req_user;
  logic dc_cache_rsp_valid;
  logic dc_cache_rsp_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_cache_rsp_id;
  logic [31:0] dc_cache_rsp_rdata;
  logic [CACHE_STATUS_W-1:0] dc_cache_rsp_status;
  logic [PADDR_W-1:0] dc_cache_rsp_fault_paddr;
  logic [CACHE_USER_W-1:0] dc_cache_rsp_user;

  logic dc_cache_maint_valid;
  logic dc_cache_maint_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_cache_maint_id;
  logic [CACHE_MAINT_OP_W-1:0] dc_cache_maint_op;
  logic [PADDR_W-1:0] dc_cache_maint_paddr;
  logic dc_cache_maint_rsp_valid;
  logic dc_cache_maint_rsp_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_cache_maint_rsp_id;
  logic [CACHE_STATUS_W-1:0] dc_cache_maint_rsp_status;

  logic dc_mem_cmd_valid;
  logic dc_mem_cmd_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_mem_cmd_id;
  logic [CACHE_MEM_OP_W-1:0] dc_mem_cmd_op;
  logic [PADDR_W-1:0] dc_mem_cmd_paddr;
  logic [CACHE_MEM_BEATS_W-1:0] dc_mem_cmd_beats;
  logic dc_mem_w_valid;
  logic dc_mem_w_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_mem_w_id;
  logic [LOWER_DATA_W-1:0] dc_mem_w_data;
  logic [(LOWER_DATA_W/8)-1:0] dc_mem_wstrb;
  logic dc_mem_w_last;
  logic dc_mem_r_valid;
  logic dc_mem_r_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_mem_r_id;
  logic [LOWER_DATA_W-1:0] dc_mem_r_data;
  logic dc_mem_r_last;
  logic [CACHE_STATUS_W-1:0] dc_mem_r_status;
  logic [PADDR_W-1:0] dc_mem_r_fault_paddr;
  logic dc_mem_b_valid;
  logic dc_mem_b_ready;
  logic [CACHE_REQ_ID_W-1:0] dc_mem_b_id;
  logic [CACHE_STATUS_W-1:0] dc_mem_b_status;
  logic [PADDR_W-1:0] dc_mem_b_fault_paddr;

  function automatic logic [VSP_ENDPOINT_OP_W-1:0]
      endpoint_op_from_lsu(
        input logic [vsp_lsu_backend_pkg::VSP_LSU_OP_W-1:0] op
      );
    begin
      case (op)
        vsp_lsu_backend_pkg::VSP_LSU_OP_LOAD:
          endpoint_op_from_lsu = VSP_ENDPOINT_OP_LOAD;
        vsp_lsu_backend_pkg::VSP_LSU_OP_STORE:
          endpoint_op_from_lsu = VSP_ENDPOINT_OP_STORE;
        default:
          endpoint_op_from_lsu = 'x;
      endcase
    end
  endfunction

  function automatic logic [VSP_MEM_FAULT_W-1:0]
      common_fault_from_endpoint(
        input logic [VSP_ENDPOINT_FAULT_W-1:0] fault
      );
    begin
      case (fault)
        VSP_ENDPOINT_FAULT_NONE:
          common_fault_from_endpoint = VSP_MEM_FAULT_NONE;
        VSP_ENDPOINT_FAULT_TRANSLATION:
          common_fault_from_endpoint = VSP_MEM_FAULT_TRANSLATION;
        VSP_ENDPOINT_FAULT_PERMISSION:
          common_fault_from_endpoint = VSP_MEM_FAULT_PERMISSION;
        VSP_ENDPOINT_FAULT_ACCESS:
          common_fault_from_endpoint = VSP_MEM_FAULT_ACCESS;
        VSP_ENDPOINT_FAULT_BUS:
          common_fault_from_endpoint = VSP_MEM_FAULT_BUS;
        VSP_ENDPOINT_FAULT_DATA_INTEGRITY:
          common_fault_from_endpoint = VSP_MEM_FAULT_DATA_INTEGRITY;
        VSP_ENDPOINT_FAULT_PROTOCOL:
          common_fault_from_endpoint = VSP_MEM_FAULT_PROTOCOL;
        default:
          common_fault_from_endpoint = VSP_MEM_FAULT_PROTOCOL;
      endcase
    end
  endfunction

  initial begin : p_integration_guards
    if (!((LOWER_DATA_W == 32) || (LOWER_DATA_W == 64) ||
          (LOWER_DATA_W == 128)))
      $fatal(1, "vsp_dmem_cached_fabric_wrapper: unsupported lower width");
    if (CACHE_REQ_ID_W != 1)
      $fatal(1, "vsp_dmem_cached_fabric_wrapper: cache request ID must be one bit");
    if (CACHE_USER_W < 1)
      $fatal(1, "vsp_dmem_cached_fabric_wrapper: cache user width must be positive");
    if ((DCACHE_LINE_BYTES % (LOWER_DATA_W / 8)) != 0)
      $fatal(1, "vsp_dmem_cached_fabric_wrapper: line/lower width mismatch");
    if (CACHE_MEM_BEATS_W < 1)
      $fatal(1, "vsp_dmem_cached_fabric_wrapper: beat-count width must be positive");
    if ((VSP_ENDPOINT_OP_W != vsp_lsu_backend_pkg::VSP_LSU_OP_W) ||
        (VSP_ENDPOINT_OP_LOAD != vsp_lsu_backend_pkg::VSP_LSU_OP_LOAD) ||
        (VSP_ENDPOINT_OP_STORE != vsp_lsu_backend_pkg::VSP_LSU_OP_STORE))
      $fatal(1, "vsp_dmem_cached_fabric_wrapper: LSU/endpoint op mismatch");
    if ((VSP_ENDPOINT_FAULT_W != VSP_MEM_FAULT_W) ||
        (VSP_ENDPOINT_FAULT_NONE != VSP_MEM_FAULT_NONE) ||
        (VSP_ENDPOINT_FAULT_TRANSLATION != VSP_MEM_FAULT_TRANSLATION) ||
        (VSP_ENDPOINT_FAULT_PERMISSION != VSP_MEM_FAULT_PERMISSION) ||
        (VSP_ENDPOINT_FAULT_ACCESS != VSP_MEM_FAULT_ACCESS) ||
        (VSP_ENDPOINT_FAULT_BUS != VSP_MEM_FAULT_BUS) ||
        (VSP_ENDPOINT_FAULT_DATA_INTEGRITY != VSP_MEM_FAULT_DATA_INTEGRITY) ||
        (VSP_ENDPOINT_FAULT_PROTOCOL != VSP_MEM_FAULT_PROTOCOL))
      $fatal(1, "vsp_dmem_cached_fabric_wrapper: endpoint/common fault mismatch");
  end

  assign uncached_device_idle_o = endpoint_merge_idle && uc_adapter_idle;
  assign local_req_endpoint_op = endpoint_op_from_lsu(local_req_op);
  assign uncached_req_endpoint_op = endpoint_op_from_lsu(uncached_req_op);
  assign device_req_endpoint_op = endpoint_op_from_lsu(device_req_op);
  assign local_rsp_fault = common_fault_from_endpoint(
      local_rsp_fault_endpoint);
  assign uncached_rsp_fault = common_fault_from_endpoint(
      uncached_rsp_fault_endpoint);
  assign device_rsp_fault = common_fault_from_endpoint(
      device_rsp_fault_endpoint);
  assign dmem_path_ready_o = rst_ni && mmu_init_done_o &&
      dcache_init_done_o && !fabric_quarantine_o &&
      !region_config_overlap_o;
  // Readiness is an enforced admission boundary, not merely advisory status.
  // In particular, direct LOCAL traffic could otherwise bypass the still-
  // initializing cache/fabric side and make system launch behavior depend on
  // whether each caller remembered an out-of-band readiness rule.
  assign inner_dmem_req_valid = dmem_req_valid_i && dmem_path_ready_o;
  assign dmem_req_ready_o = inner_dmem_req_ready && dmem_path_ready_o;
  assign dmem_path_quiescent_o = inner_quiescent && dcache_idle_o &&
      local_idle_o && uncached_device_idle_o && fabric_idle_o &&
      lower_quiescent_i && dcache_init_done_o;
  assign dmem_path_busy_o = !dmem_path_quiescent_o;
  assign protocol_error_o = inner_protocol_error ||
      dcache_protocol_error_o || endpoint_merge_protocol_error_o ||
      fabric_protocol_error_o;

  vsp_dmem_subsystem_wrapper #(
    .PADDR_W(PADDR_W),
    .TRANSLATION_ENABLE(TRANSLATION_ENABLE),
    .MMU_CONTEXT_COUNT(MMU_CONTEXT_COUNT),
    .ASID_W(ASID_W),
    .I_TLB_ENTRY_COUNT(I_TLB_ENTRY_COUNT),
    .D_TLB_ENTRY_COUNT(D_TLB_ENTRY_COUNT),
    .TLB_EPOCH_W(TLB_EPOCH_W),
    .REGION_COUNT(REGION_COUNT),
    .REGION_INDEX_W(REGION_INDEX_W),
    .REGION_ENABLE(REGION_ENABLE),
    .REGION_BASE(REGION_BASE),
    .REGION_MASK(REGION_MASK),
    .REGION_ENDPOINT(REGION_ENDPOINT),
    .REGION_READ_OK(REGION_READ_OK),
    .REGION_WRITE_OK(REGION_WRITE_OK),
    .REGION_EXECUTE_OK(REGION_EXECUTE_OK),
    .REGION_IDEMPOTENT(REGION_IDEMPOTENT)
  ) u_dmem_subsystem (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .dmem_req_valid_i(inner_dmem_req_valid),
    .dmem_req_ready_o(inner_dmem_req_ready),
    .dmem_req_op_i(dmem_req_op_i),
    .dmem_req_eaddr_i(dmem_req_eaddr_i),
    .dmem_req_addr_space_i(dmem_req_addr_space_i),
    .dmem_req_addr_context_i(dmem_req_addr_context_i),
    .dmem_req_wdata_i(dmem_req_wdata_i),
    .dmem_req_wstrb_i(dmem_req_wstrb_i),
    .dmem_rsp_valid_o(dmem_rsp_valid_o),
    .dmem_rsp_ready_i(dmem_rsp_ready_i),
    .dmem_rsp_rdata_o(dmem_rsp_rdata_o),
    .dmem_rsp_fault_cause_o(dmem_rsp_fault_cause_o),
    .i_tr_req_valid_i(i_tr_req_valid_i),
    .i_tr_req_ready_o(i_tr_req_ready_o),
    .i_tr_req_vaddr_i(i_tr_req_vaddr_i),
    .i_tr_req_addr_context_i(i_tr_req_addr_context_i),
    .i_tr_req_access_i(i_tr_req_access_i),
    .i_tr_rsp_valid_o(i_tr_rsp_valid_o),
    .i_tr_rsp_ready_i(i_tr_rsp_ready_i),
    .i_tr_rsp_paddr_o(i_tr_rsp_paddr_o),
    .i_tr_rsp_fault_o(i_tr_rsp_fault_o),
    .i_tr_rsp_fault_vaddr_o(i_tr_rsp_fault_vaddr_o),
    .mmu_cfg_valid_i(mmu_cfg_valid_i),
    .mmu_cfg_ready_o(mmu_cfg_ready_o),
    .mmu_cfg_write_i(mmu_cfg_write_i),
    .mmu_cfg_context_i(mmu_cfg_context_i),
    .mmu_cfg_field_i(mmu_cfg_field_i),
    .mmu_cfg_wdata_i(mmu_cfg_wdata_i),
    .mmu_cfg_rsp_valid_o(mmu_cfg_rsp_valid_o),
    .mmu_cfg_rsp_ready_i(mmu_cfg_rsp_ready_i),
    .mmu_cfg_rsp_rdata_o(mmu_cfg_rsp_rdata_o),
    .mmu_cfg_rsp_status_o(mmu_cfg_rsp_status_o),
    .tlb_inv_req_valid_i(tlb_inv_req_valid_i),
    .tlb_inv_req_ready_o(tlb_inv_req_ready_o),
    .tlb_inv_req_scope_i(tlb_inv_req_scope_i),
    .tlb_inv_req_asid_i(tlb_inv_req_asid_i),
    .tlb_inv_req_vaddr_i(tlb_inv_req_vaddr_i),
    .tlb_inv_rsp_valid_o(tlb_inv_rsp_valid_o),
    .tlb_inv_rsp_ready_i(tlb_inv_rsp_ready_i),
    .tlb_inv_rsp_status_o(tlb_inv_rsp_status_o),
    .ptw_mem_req_valid_o(ptw_mem_req_valid),
    .ptw_mem_req_ready_i(ptw_mem_req_ready),
    .ptw_mem_req_paddr_o(ptw_mem_req_paddr),
    .ptw_mem_rsp_valid_i(ptw_mem_rsp_valid),
    .ptw_mem_rsp_ready_o(ptw_mem_rsp_ready),
    .ptw_mem_rsp_rdata_i(ptw_mem_rsp_rdata),
    .ptw_mem_rsp_fault_i(ptw_mem_rsp_fault),
    .ptw_pte_fault_paddr_valid_o(ptw_pte_fault_paddr_valid_o),
    .ptw_pte_fault_paddr_o(ptw_pte_fault_paddr_o),
    .cache_req_valid_o(cache_req_valid),
    .cache_req_ready_i(cache_req_ready),
    .cache_req_access_o(cache_req_access),
    .cache_req_eaddr_o(cache_req_eaddr),
    .cache_req_paddr_o(cache_req_paddr),
    .cache_req_wdata_o(cache_req_wdata),
    .cache_req_wstrb_o(cache_req_wstrb),
    .cache_rsp_valid_i(cache_rsp_valid),
    .cache_rsp_ready_o(cache_rsp_ready),
    .cache_rsp_rdata_i(cache_rsp_rdata),
    .cache_rsp_fault_cause_i(cache_rsp_fault),
    .local_req_valid_o(local_req_valid),
    .local_req_ready_i(local_req_ready),
    .local_req_op_o(local_req_op),
    .local_req_addr_o(local_req_addr),
    .local_req_wdata_o(local_req_wdata),
    .local_req_wstrb_o(local_req_wstrb),
    .local_rsp_valid_i(local_rsp_valid),
    .local_rsp_ready_o(local_rsp_ready),
    .local_rsp_rdata_i(local_rsp_rdata),
    .local_rsp_fault_cause_i(local_rsp_fault),
    .uncached_req_valid_o(uncached_req_valid),
    .uncached_req_ready_i(uncached_req_ready),
    .uncached_req_op_o(uncached_req_op),
    .uncached_req_addr_o(uncached_req_addr),
    .uncached_req_wdata_o(uncached_req_wdata),
    .uncached_req_wstrb_o(uncached_req_wstrb),
    .uncached_rsp_valid_i(uncached_rsp_valid),
    .uncached_rsp_ready_o(uncached_rsp_ready),
    .uncached_rsp_rdata_i(uncached_rsp_rdata),
    .uncached_rsp_fault_cause_i(uncached_rsp_fault),
    .device_req_valid_o(device_req_valid),
    .device_req_ready_i(device_req_ready),
    .device_req_op_o(device_req_op),
    .device_req_addr_o(device_req_addr),
    .device_req_wdata_o(device_req_wdata),
    .device_req_wstrb_o(device_req_wstrb),
    .device_rsp_valid_i(device_rsp_valid),
    .device_rsp_ready_o(device_rsp_ready),
    .device_rsp_rdata_i(device_rsp_rdata),
    .device_rsp_fault_cause_i(device_rsp_fault),
    .barrier_valid_i(barrier_valid_i),
    .barrier_ready_o(barrier_ready_o),
    .barrier_op_i(barrier_op_i),
    .barrier_eaddr_i(barrier_eaddr_i),
    .barrier_context_i(barrier_context_i),
    .barrier_rsp_valid_o(barrier_rsp_valid_o),
    .barrier_rsp_ready_i(barrier_rsp_ready_i),
    .barrier_rsp_status_o(barrier_rsp_status_o),
    .policy_maint_req_valid_o(policy_maint_req_valid_o),
    .policy_maint_req_ready_i(policy_maint_req_ready_i),
    .policy_maint_req_op_o(policy_maint_req_op_o),
    .policy_maint_req_eaddr_o(policy_maint_req_eaddr_o),
    .policy_maint_req_context_o(policy_maint_req_context_o),
    .policy_maint_rsp_valid_i(policy_maint_rsp_valid_i),
    .policy_maint_rsp_ready_o(policy_maint_rsp_ready_o),
    .policy_maint_rsp_fault_i(policy_maint_rsp_fault_i),
    .lsu_idle_o(lsu_idle_o),
    .lsu_busy_o(lsu_busy_o),
    .space_router_idle_o(space_router_idle_o),
    .region_router_idle_o(region_router_idle_o),
    .region_config_overlap_o(region_config_overlap_o),
    .region_diag_rsp_valid_o(region_diag_rsp_valid_o),
    .region_diag_match_valid_o(region_diag_match_valid_o),
    .region_diag_match_index_o(region_diag_match_index_o),
    .region_diag_overlap_o(region_diag_overlap_o),
    .region_diag_endpoint_valid_o(region_diag_endpoint_valid_o),
    .region_diag_endpoint_o(region_diag_endpoint_o),
    .region_diag_fault_o(region_diag_fault_o),
    .mmu_init_done_o(mmu_init_done_o),
    .mmu_quiescent_o(mmu_quiescent_o),
    .mmu_busy_o(mmu_busy_o),
    .i_tlb_epoch_o(i_tlb_epoch_o),
    .d_tlb_epoch_o(d_tlb_epoch_o),
    .i_tlb_epoch_exhausted_o(i_tlb_epoch_exhausted_o),
    .d_tlb_epoch_exhausted_o(d_tlb_epoch_exhausted_o),
    .internal_quiescent_o(inner_quiescent),
    .internal_busy_o(inner_busy),
    .protocol_error_clear_i(protocol_error_clear_i),
    .lsu_protocol_error_o(lsu_protocol_error_o),
    .mmu_protocol_error_o(mmu_protocol_error_o),
    .protocol_error_o(inner_protocol_error)
  );

  vsp_dcache_adapter #(
    .PADDR_W(PADDR_W),
    .EADDR_W(32),
    .FRONT_DATA_W(32),
    .LINE_BYTES(DCACHE_LINE_BYTES),
    .REQ_ID_W(CACHE_REQ_ID_W),
    .USER_W(CACHE_USER_W),
    .CACHE_READ_ONLY(1'b0)
  ) u_dcache_adapter (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .cache_init_done_i(dcache_init_done_o),
    .req_valid_i(cache_req_valid),
    .req_ready_o(cache_req_ready),
    .req_access_i(cache_req_access),
    .req_eaddr_i(cache_req_eaddr),
    .req_paddr_i(cache_req_paddr),
    .req_wdata_i(cache_req_wdata),
    .req_wstrb_i(cache_req_wstrb),
    .rsp_valid_o(cache_rsp_valid),
    .rsp_ready_i(cache_rsp_ready),
    .rsp_rdata_o(cache_rsp_rdata),
    .rsp_fault_cause_o(cache_rsp_fault),
    .rsp_fault_eaddr_o(dcache_rsp_fault_eaddr),
    .rsp_fault_paddr_o(dcache_rsp_fault_paddr),
    .maint_req_valid_i(dcache_maint_req_valid_i),
    .maint_req_ready_o(dcache_maint_req_ready_o),
    .maint_req_op_i(dcache_maint_req_op_i),
    .maint_req_paddr_i(dcache_maint_req_paddr_i),
    .maint_rsp_valid_o(dcache_maint_rsp_valid_o),
    .maint_rsp_ready_i(dcache_maint_rsp_ready_i),
    .maint_rsp_status_o(dcache_maint_rsp_status_o),
    .idle_o(dcache_idle_o),
    .protocol_error_o(dcache_protocol_error_o),
    .cache_req_valid_o(dc_cache_req_valid),
    .cache_req_ready_i(dc_cache_req_ready),
    .cache_req_id_o(dc_cache_req_id),
    .cache_req_op_o(dc_cache_req_op),
    .cache_req_paddr_o(dc_cache_req_paddr),
    .cache_req_wdata_o(dc_cache_req_wdata),
    .cache_req_wstrb_o(dc_cache_req_wstrb),
    .cache_req_user_o(dc_cache_req_user),
    .cache_rsp_valid_i(dc_cache_rsp_valid),
    .cache_rsp_ready_o(dc_cache_rsp_ready),
    .cache_rsp_id_i(dc_cache_rsp_id),
    .cache_rsp_rdata_i(dc_cache_rsp_rdata),
    .cache_rsp_status_i(dc_cache_rsp_status),
    .cache_rsp_fault_paddr_i(dc_cache_rsp_fault_paddr),
    .cache_rsp_user_i(dc_cache_rsp_user),
    .cache_maint_valid_o(dc_cache_maint_valid),
    .cache_maint_ready_i(dc_cache_maint_ready),
    .cache_maint_id_o(dc_cache_maint_id),
    .cache_maint_op_o(dc_cache_maint_op),
    .cache_maint_paddr_o(dc_cache_maint_paddr),
    .cache_maint_rsp_valid_i(dc_cache_maint_rsp_valid),
    .cache_maint_rsp_ready_o(dc_cache_maint_rsp_ready),
    .cache_maint_rsp_id_i(dc_cache_maint_rsp_id),
    .cache_maint_rsp_status_i(dc_cache_maint_rsp_status)
  );

  param_cache #(
    .PADDR_W(PADDR_W),
    .FRONT_DATA_W(32),
    .LOWER_DATA_W(LOWER_DATA_W),
    .LINE_BYTES(DCACHE_LINE_BYTES),
    .SET_COUNT(DCACHE_SET_COUNT),
    .WAY_COUNT(DCACHE_WAY_COUNT),
    .REQ_ID_W(CACHE_REQ_ID_W),
    .USER_W(CACHE_USER_W),
    .RAM_RD_LATENCY(DCACHE_RAM_RD_LATENCY),
    .READ_ONLY(1'b0),
    .ENABLE_PERF_EVENTS(1'b1),
    .MEM_BEATS_W(CACHE_MEM_BEATS_W)
  ) u_dcache (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_valid_i(dc_cache_req_valid),
    .req_ready_o(dc_cache_req_ready),
    .req_id_i(dc_cache_req_id),
    .req_op_i(dc_cache_req_op),
    .req_paddr_i(dc_cache_req_paddr),
    .req_wdata_i(dc_cache_req_wdata),
    .req_wstrb_i(dc_cache_req_wstrb),
    .req_user_i(dc_cache_req_user),
    .rsp_valid_o(dc_cache_rsp_valid),
    .rsp_ready_i(dc_cache_rsp_ready),
    .rsp_id_o(dc_cache_rsp_id),
    .rsp_rdata_o(dc_cache_rsp_rdata),
    .rsp_status_o(dc_cache_rsp_status),
    .rsp_fault_paddr_o(dc_cache_rsp_fault_paddr),
    .rsp_user_o(dc_cache_rsp_user),
    .maint_valid_i(dc_cache_maint_valid),
    .maint_ready_o(dc_cache_maint_ready),
    .maint_id_i(dc_cache_maint_id),
    .maint_op_i(dc_cache_maint_op),
    .maint_paddr_i(dc_cache_maint_paddr),
    .maint_rsp_valid_o(dc_cache_maint_rsp_valid),
    .maint_rsp_ready_i(dc_cache_maint_rsp_ready),
    .maint_rsp_id_o(dc_cache_maint_rsp_id),
    .maint_rsp_status_o(dc_cache_maint_rsp_status),
    .mem_cmd_valid_o(dc_mem_cmd_valid),
    .mem_cmd_ready_i(dc_mem_cmd_ready),
    .mem_cmd_id_o(dc_mem_cmd_id),
    .mem_cmd_op_o(dc_mem_cmd_op),
    .mem_cmd_paddr_o(dc_mem_cmd_paddr),
    .mem_cmd_beats_o(dc_mem_cmd_beats),
    .mem_w_valid_o(dc_mem_w_valid),
    .mem_w_ready_i(dc_mem_w_ready),
    .mem_w_id_o(dc_mem_w_id),
    .mem_w_data_o(dc_mem_w_data),
    .mem_wstrb_o(dc_mem_wstrb),
    .mem_w_last_o(dc_mem_w_last),
    .mem_r_valid_i(dc_mem_r_valid),
    .mem_r_ready_o(dc_mem_r_ready),
    .mem_r_id_i(dc_mem_r_id),
    .mem_r_data_i(dc_mem_r_data),
    .mem_r_last_i(dc_mem_r_last),
    .mem_r_status_i(dc_mem_r_status),
    .mem_r_fault_paddr_i(dc_mem_r_fault_paddr),
    .mem_b_valid_i(dc_mem_b_valid),
    .mem_b_ready_o(dc_mem_b_ready),
    .mem_b_id_i(dc_mem_b_id),
    .mem_b_status_i(dc_mem_b_status),
    .mem_b_fault_paddr_i(dc_mem_b_fault_paddr),
    .init_busy_o(dcache_init_busy_o),
    .init_done_o(dcache_init_done_o),
    .perf_read_hit_o(perf_dcache_read_hit_o),
    .perf_read_miss_o(perf_dcache_read_miss_o),
    .perf_write_hit_o(perf_dcache_write_hit_o),
    .perf_write_miss_o(perf_dcache_write_miss_o)
  );

  vsp_local_sram_adapter #(
    .ADDR_W(PADDR_W),
    .BASE_ADDR(LOCAL_BASE_ADDR),
    .DEPTH_WORDS(LOCAL_DEPTH_WORDS)
  ) u_local_endpoint (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_valid_i(local_req_valid),
    .req_ready_o(local_req_ready),
    .req_op_i(local_req_endpoint_op),
    .req_addr_i(local_req_addr),
    .req_wdata_i(local_req_wdata),
    .req_wstrb_i(local_req_wstrb),
    .rsp_valid_o(local_rsp_valid),
    .rsp_ready_i(local_rsp_ready),
    .rsp_rdata_o(local_rsp_rdata),
    .rsp_fault_cause_o(local_rsp_fault_endpoint),
    .idle_o(local_idle_o)
  );

  vsp_uncached_device_merge #(
    .ADDR_W(PADDR_W)
  ) u_uncached_device_merge (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .uncached_req_valid_i(uncached_req_valid),
    .uncached_req_ready_o(uncached_req_ready),
    .uncached_req_op_i(uncached_req_endpoint_op),
    .uncached_req_addr_i(uncached_req_addr),
    .uncached_req_wdata_i(uncached_req_wdata),
    .uncached_req_wstrb_i(uncached_req_wstrb),
    .uncached_rsp_valid_o(uncached_rsp_valid),
    .uncached_rsp_ready_i(uncached_rsp_ready),
    .uncached_rsp_rdata_o(uncached_rsp_rdata),
    .uncached_rsp_fault_cause_o(uncached_rsp_fault_endpoint),
    .device_req_valid_i(device_req_valid),
    .device_req_ready_o(device_req_ready),
    .device_req_op_i(device_req_endpoint_op),
    .device_req_addr_i(device_req_addr),
    .device_req_wdata_i(device_req_wdata),
    .device_req_wstrb_i(device_req_wstrb),
    .device_rsp_valid_o(device_rsp_valid),
    .device_rsp_ready_i(device_rsp_ready),
    .device_rsp_rdata_o(device_rsp_rdata),
    .device_rsp_fault_cause_o(device_rsp_fault_endpoint),
    .shared_req_valid_o(merged_req_valid),
    .shared_req_ready_i(merged_req_ready),
    .shared_req_op_o(merged_req_op),
    .shared_req_addr_o(merged_req_addr),
    .shared_req_wdata_o(merged_req_wdata),
    .shared_req_wstrb_o(merged_req_wstrb),
    .shared_rsp_valid_i(merged_rsp_valid),
    .shared_rsp_ready_o(merged_rsp_ready),
    .shared_rsp_rdata_i(merged_rsp_rdata),
    .shared_rsp_fault_cause_i(merged_rsp_fault),
    .idle_o(endpoint_merge_idle),
    .protocol_error_o(endpoint_merge_protocol_error_o),
    .protocol_error_clear_i(protocol_error_clear_i)
  );

  vsp_uncached_device_adapter #(
    .ADDR_W(PADDR_W)
  ) u_uncached_device_endpoint (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_valid_i(merged_req_valid),
    .req_ready_o(merged_req_ready),
    .req_op_i(merged_req_op),
    .req_addr_i(merged_req_addr),
    .req_wdata_i(merged_req_wdata),
    .req_wstrb_i(merged_req_wstrb),
    .rsp_valid_o(merged_rsp_valid),
    .rsp_ready_i(merged_rsp_ready),
    .rsp_rdata_o(merged_rsp_rdata),
    .rsp_fault_cause_o(merged_rsp_fault),
    .idle_o(uc_adapter_idle),
    .lower_req_valid_o(uc_lower_req_valid),
    .lower_req_ready_i(uc_lower_req_ready),
    .lower_req_write_o(uc_lower_req_write),
    .lower_req_addr_o(uc_lower_req_addr),
    .lower_req_wdata_o(uc_lower_req_wdata),
    .lower_req_wstrb_o(uc_lower_req_wstrb),
    .lower_rsp_valid_i(uc_lower_rsp_valid),
    .lower_rsp_ready_o(uc_lower_rsp_ready),
    .lower_rsp_rdata_i(uc_lower_rsp_rdata),
    .lower_rsp_status_i(uc_lower_rsp_status)
  );

  vsp_physical_fabric #(
    .PADDR_W(PADDR_W),
    .LOWER_DATA_W(LOWER_DATA_W),
    .CACHE_ID_W(CACHE_REQ_ID_W),
    .MEM_BEATS_W(CACHE_MEM_BEATS_W)
  ) u_physical_fabric (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .drain_req_i(fabric_drain_req_i),
    .drain_done_o(fabric_drain_done_o),
    .idle_o(fabric_idle_o),
    .busy_o(fabric_busy_o),
    .quarantine_o(fabric_quarantine_o),
    .owner_valid_o(fabric_owner_valid_o),
    .owner_o(fabric_owner_o),
    .protocol_error_o(fabric_protocol_error_o),
    .protocol_error_clear_i(protocol_error_clear_i),
    .ic_mem_cmd_valid_i(ic_mem_cmd_valid_i),
    .ic_mem_cmd_ready_o(ic_mem_cmd_ready_o),
    .ic_mem_cmd_id_i(ic_mem_cmd_id_i),
    .ic_mem_cmd_op_i(ic_mem_cmd_op_i),
    .ic_mem_cmd_paddr_i(ic_mem_cmd_paddr_i),
    .ic_mem_cmd_beats_i(ic_mem_cmd_beats_i),
    .ic_mem_w_valid_i(ic_mem_w_valid_i),
    .ic_mem_w_ready_o(ic_mem_w_ready_o),
    .ic_mem_w_id_i(ic_mem_w_id_i),
    .ic_mem_w_data_i(ic_mem_w_data_i),
    .ic_mem_wstrb_i(ic_mem_wstrb_i),
    .ic_mem_w_last_i(ic_mem_w_last_i),
    .ic_mem_r_valid_o(ic_mem_r_valid_o),
    .ic_mem_r_ready_i(ic_mem_r_ready_i),
    .ic_mem_r_id_o(ic_mem_r_id_o),
    .ic_mem_r_data_o(ic_mem_r_data_o),
    .ic_mem_r_last_o(ic_mem_r_last_o),
    .ic_mem_r_status_o(ic_mem_r_status_o),
    .ic_mem_r_fault_paddr_o(ic_mem_r_fault_paddr_o),
    .ic_mem_b_valid_o(ic_mem_b_valid_o),
    .ic_mem_b_ready_i(ic_mem_b_ready_i),
    .ic_mem_b_id_o(ic_mem_b_id_o),
    .ic_mem_b_status_o(ic_mem_b_status_o),
    .ic_mem_b_fault_paddr_o(ic_mem_b_fault_paddr_o),
    .dc_mem_cmd_valid_i(dc_mem_cmd_valid),
    .dc_mem_cmd_ready_o(dc_mem_cmd_ready),
    .dc_mem_cmd_id_i(dc_mem_cmd_id),
    .dc_mem_cmd_op_i(dc_mem_cmd_op),
    .dc_mem_cmd_paddr_i(dc_mem_cmd_paddr),
    .dc_mem_cmd_beats_i(dc_mem_cmd_beats),
    .dc_mem_w_valid_i(dc_mem_w_valid),
    .dc_mem_w_ready_o(dc_mem_w_ready),
    .dc_mem_w_id_i(dc_mem_w_id),
    .dc_mem_w_data_i(dc_mem_w_data),
    .dc_mem_wstrb_i(dc_mem_wstrb),
    .dc_mem_w_last_i(dc_mem_w_last),
    .dc_mem_r_valid_o(dc_mem_r_valid),
    .dc_mem_r_ready_i(dc_mem_r_ready),
    .dc_mem_r_id_o(dc_mem_r_id),
    .dc_mem_r_data_o(dc_mem_r_data),
    .dc_mem_r_last_o(dc_mem_r_last),
    .dc_mem_r_status_o(dc_mem_r_status),
    .dc_mem_r_fault_paddr_o(dc_mem_r_fault_paddr),
    .dc_mem_b_valid_o(dc_mem_b_valid),
    .dc_mem_b_ready_i(dc_mem_b_ready),
    .dc_mem_b_id_o(dc_mem_b_id),
    .dc_mem_b_status_o(dc_mem_b_status),
    .dc_mem_b_fault_paddr_o(dc_mem_b_fault_paddr),
    .ptw_mem_req_valid_i(ptw_mem_req_valid),
    .ptw_mem_req_ready_o(ptw_mem_req_ready),
    .ptw_mem_req_paddr_i(ptw_mem_req_paddr),
    .ptw_mem_rsp_valid_o(ptw_mem_rsp_valid),
    .ptw_mem_rsp_ready_i(ptw_mem_rsp_ready),
    .ptw_mem_rsp_rdata_o(ptw_mem_rsp_rdata),
    .ptw_mem_rsp_fault_o(ptw_mem_rsp_fault),
    .ptw_mem_rsp_fault_paddr_o(ptw_mem_rsp_fault_paddr),
    .uc_req_valid_i(uc_lower_req_valid),
    .uc_req_ready_o(uc_lower_req_ready),
    .uc_req_write_i(uc_lower_req_write),
    .uc_req_paddr_i(uc_lower_req_addr),
    .uc_req_wdata_i(uc_lower_req_wdata),
    .uc_req_wstrb_i(uc_lower_req_wstrb),
    .uc_rsp_valid_o(uc_lower_rsp_valid),
    .uc_rsp_ready_i(uc_lower_rsp_ready),
    .uc_rsp_rdata_o(uc_lower_rsp_rdata),
    .uc_rsp_status_o(uc_lower_rsp_status),
    .uc_rsp_fault_paddr_o(uc_lower_rsp_fault_paddr),
    .lower_req_valid_o(lower_req_valid_o),
    .lower_req_ready_i(lower_req_ready_i),
    .lower_req_write_o(lower_req_write_o),
    .lower_req_paddr_o(lower_req_paddr_o),
    .lower_req_wdata_o(lower_req_wdata_o),
    .lower_req_wstrb_o(lower_req_wstrb_o),
    .lower_rsp_valid_i(lower_rsp_valid_i),
    .lower_rsp_ready_o(lower_rsp_ready_o),
    .lower_rsp_rdata_i(lower_rsp_rdata_i),
    .lower_rsp_status_i(lower_rsp_status_i),
    .lower_quiescent_i(lower_quiescent_i)
  );

  // These addresses are retained by their owning adapters for diagnostics;
  // the architectural response crossing back into the LSU carries only the
  // canonical fault cause in the current VSP ABI.
  /* verilator lint_off UNUSED */
  logic [31:0] unused_dcache_fault_eaddr;
  logic [PADDR_W-1:0] unused_dcache_fault_paddr;
  logic [PADDR_W-1:0] unused_ptw_fault_paddr;
  logic [PADDR_W-1:0] unused_uc_fault_paddr;
  logic unused_inner_busy;
  assign unused_dcache_fault_eaddr = dcache_rsp_fault_eaddr;
  assign unused_dcache_fault_paddr = dcache_rsp_fault_paddr;
  assign unused_ptw_fault_paddr = ptw_mem_rsp_fault_paddr;
  assign unused_uc_fault_paddr = uc_lower_rsp_fault_paddr;
  assign unused_inner_busy = inner_busy;
  /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
