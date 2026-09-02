// SPDX-License-Identifier: MIT

`default_nettype none

// Product I-side client for the shared VSP MMU and physical fabric.
//
// The wrapper deliberately stops at two protocol-neutral boundaries:
//   * i_tr_* is the instruction client of the shared MMU;
//   * ic_mem_* is the native read-only cache master of the physical fabric.
// It contains no AXI/NoC logic and no SoC target decoder.
module vsp_ifetch_cached_client_wrapper #(
  parameter integer PADDR_W = 40,
  parameter logic TRANSLATION_ENABLE = 1'b1,

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

  parameter integer FRONT_DATA_W = 128,
  parameter integer LOWER_DATA_W = 32,
  parameter integer ICACHE_LINE_BYTES = 32,
  parameter integer ICACHE_SET_COUNT = 64,
  parameter integer ICACHE_WAY_COUNT = 2,
  parameter integer ICACHE_RAM_RD_LATENCY = 1,
  parameter integer CACHE_REQ_ID_W = 1,
  parameter integer CACHE_USER_W = 1,
  parameter integer CACHE_MEM_BEATS_W =
      ((ICACHE_LINE_BYTES / (LOWER_DATA_W / 8)) <= 1) ? 1 :
      $clog2((ICACHE_LINE_BYTES / (LOWER_DATA_W / 8)) + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Legacy provider shape exported by vsp_uword_cluster_program_wrapper.
  // source_admit_enable_i only controls acceptance of a new source request;
  // accepted bridge/cache/MMU work always remains able to drain.
  input  logic                                      source_admit_enable_i,
  input  logic                                      redirect_commit_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                                     source_addr_space_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
                                                     source_addr_context_i,
  input  logic                                      source_req_valid_i,
  output logic                                      source_req_ready_o,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_EADDR_W-1:0]
                                                     source_req_pc_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_WORD_COUNT_W-1:0]
                                                     source_req_word_count_i,
  output logic                                      source_rsp_valid_o,
  input  logic                                      source_rsp_ready_i,
  output logic [(vsp_ifetch_adapter_pkg::VSP_IFETCH_MAX_WORDS *
                 vsp_ifetch_adapter_pkg::VSP_IFETCH_WORD_W)-1:0]
                                                     source_rsp_words_o,
  output logic                                      source_rsp_fault_o,

  // Shared instruction-translation client.
  output logic                                      i_tr_req_valid_o,
  input  logic                                      i_tr_req_ready_i,
  output logic [vsp_mmu_pkg::VSP_MMU_VADDR_W-1:0]  i_tr_req_vaddr_o,
  output logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0]
                                                     i_tr_req_addr_context_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_ACCESS_W-1:0]
                                                     i_tr_req_access_o,
  input  logic                                      i_tr_rsp_valid_i,
  output logic                                      i_tr_rsp_ready_o,
  input  logic [PADDR_W-1:0]                        i_tr_rsp_paddr_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     i_tr_rsp_fault_i,
  input  logic [vsp_mmu_pkg::VSP_MMU_VADDR_W-1:0]
                                                     i_tr_rsp_fault_vaddr_i,

  // I-cache invalidate ingress.  V1 supports line or all invalidation; a
  // global maintenance controller supplies this channel in the full system.
  input  logic                                      inv_req_valid_i,
  output logic                                      inv_req_ready_o,
  input  logic                                      inv_req_all_i,
  input  logic [PADDR_W-1:0]                        inv_req_paddr_i,
  output logic                                      inv_rsp_valid_o,
  input  logic                                      inv_rsp_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
                                                     inv_rsp_status_o,

  // Native read-only I-cache master for vsp_physical_fabric.
  output logic                                      ic_mem_cmd_valid_o,
  input  logic                                      ic_mem_cmd_ready_i,
  output logic [CACHE_REQ_ID_W-1:0]                 ic_mem_cmd_id_o,
  output logic [cache_pkg::CACHE_MEM_OP_W-1:0]     ic_mem_cmd_op_o,
  output logic [PADDR_W-1:0]                        ic_mem_cmd_paddr_o,
  output logic [CACHE_MEM_BEATS_W-1:0]              ic_mem_cmd_beats_o,
  output logic                                      ic_mem_w_valid_o,
  input  logic                                      ic_mem_w_ready_i,
  output logic [CACHE_REQ_ID_W-1:0]                 ic_mem_w_id_o,
  output logic [LOWER_DATA_W-1:0]                   ic_mem_w_data_o,
  output logic [(LOWER_DATA_W/8)-1:0]               ic_mem_wstrb_o,
  output logic                                      ic_mem_w_last_o,
  input  logic                                      ic_mem_r_valid_i,
  output logic                                      ic_mem_r_ready_o,
  input  logic [CACHE_REQ_ID_W-1:0]                 ic_mem_r_id_i,
  input  logic [LOWER_DATA_W-1:0]                   ic_mem_r_data_i,
  input  logic                                      ic_mem_r_last_i,
  input  logic [cache_pkg::CACHE_STATUS_W-1:0]     ic_mem_r_status_i,
  input  logic [PADDR_W-1:0]                        ic_mem_r_fault_paddr_i,
  input  logic                                      ic_mem_b_valid_i,
  output logic                                      ic_mem_b_ready_o,
  input  logic [CACHE_REQ_ID_W-1:0]                 ic_mem_b_id_i,
  input  logic [cache_pkg::CACHE_STATUS_W-1:0]     ic_mem_b_status_i,
  input  logic [PADDR_W-1:0]                        ic_mem_b_fault_paddr_i,

  output logic                                      ready_o,
  output logic                                      quiescent_o,
  output logic                                      busy_o,
  output logic                                      bridge_idle_o,
  output logic                                      bridge_busy_o,
  output logic                                      ifetch_init_done_o,
  output logic                                      ifetch_idle_o,
  output logic                                      icache_init_busy_o,
  output logic                                      icache_init_done_o,
  output logic                                      icache_adapter_idle_o,
  output logic                                      region_router_idle_o,
  output logic                                      region_config_overlap_o,
  output logic                                      perf_icache_read_hit_o,
  output logic                                      perf_icache_read_miss_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      bridge_protocol_error_o,
  output logic                                      ifetch_protocol_error_o,
  output logic                                      icache_adapter_protocol_error_o,
  output logic                                      protocol_error_o
);
  import vsp_mem_common_pkg::*;

  localparam integer FRONT_BYTES = FRONT_DATA_W / 8;
  localparam integer LOWER_BYTES = LOWER_DATA_W / 8;
  localparam integer LINE_BEATS = ICACHE_LINE_BYTES / LOWER_BYTES;

  logic gated_source_req_valid;
  logic bridge_source_req_ready;
  logic canonical_req_valid;
  logic canonical_req_ready;
  logic [31:0] canonical_req_eaddr;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_WORD_COUNT_W-1:0]
      canonical_req_word_count;
  logic [VSP_MEM_ADDR_SPACE_W-1:0] canonical_req_addr_space;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
      canonical_req_addr_context;
  logic canonical_rsp_valid;
  logic canonical_rsp_ready;
  logic [127:0] canonical_rsp_words;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_WORD_COUNT_W-1:0]
      canonical_rsp_word_count;
  logic [VSP_MEM_FAULT_W-1:0] canonical_rsp_fault;
  logic [31:0] canonical_rsp_fault_eaddr;
  logic [PADDR_W-1:0] canonical_rsp_fault_paddr;

  logic region_req_valid;
  logic region_req_ready;
  logic [PADDR_W-1:0] region_req_paddr;
  logic [VSP_MEM_ACCESS_W-1:0] region_req_access;
  logic [7:0] region_req_context;
  logic region_rsp_valid;
  logic region_rsp_ready;
  logic region_rsp_endpoint_valid;
  logic [VSP_MEM_ENDPOINT_W-1:0] region_rsp_endpoint;
  logic region_rsp_match_valid;
  logic [VSP_MEM_FAULT_W-1:0] region_rsp_fault;

  logic beat_req_valid;
  logic beat_req_ready;
  logic [VSP_MEM_ACCESS_W-1:0] beat_req_access;
  logic [31:0] beat_req_eaddr;
  logic [PADDR_W-1:0] beat_req_paddr;
  logic [FRONT_DATA_W-1:0] beat_req_wdata;
  logic [FRONT_BYTES-1:0] beat_req_wstrb;
  logic beat_rsp_valid;
  logic beat_rsp_ready;
  logic [FRONT_DATA_W-1:0] beat_rsp_rdata;
  logic [VSP_MEM_FAULT_W-1:0] beat_rsp_fault;
  logic [31:0] beat_rsp_fault_eaddr;
  logic [PADDR_W-1:0] beat_rsp_fault_paddr;

  logic beat_maint_req_valid;
  logic beat_maint_req_ready;
  logic [VSP_MEM_CACHE_MAINT_OP_W-1:0] beat_maint_req_op;
  logic [PADDR_W-1:0] beat_maint_req_paddr;
  logic beat_maint_rsp_valid;
  logic beat_maint_rsp_ready;
  logic [VSP_MEM_STATUS_W-1:0] beat_maint_rsp_status;

  logic cache_req_valid;
  logic cache_req_ready;
  logic [CACHE_REQ_ID_W-1:0] cache_req_id;
  logic [cache_pkg::CACHE_REQ_OP_W-1:0] cache_req_op;
  logic [PADDR_W-1:0] cache_req_paddr;
  logic [FRONT_DATA_W-1:0] cache_req_wdata;
  logic [FRONT_BYTES-1:0] cache_req_wstrb;
  logic [CACHE_USER_W-1:0] cache_req_user;
  logic cache_rsp_valid;
  logic cache_rsp_ready;
  logic [CACHE_REQ_ID_W-1:0] cache_rsp_id;
  logic [FRONT_DATA_W-1:0] cache_rsp_rdata;
  logic [cache_pkg::CACHE_STATUS_W-1:0] cache_rsp_status;
  logic [PADDR_W-1:0] cache_rsp_fault_paddr;
  logic [CACHE_USER_W-1:0] cache_rsp_user;

  logic cache_maint_valid;
  logic cache_maint_ready;
  logic [CACHE_REQ_ID_W-1:0] cache_maint_id;
  logic [cache_pkg::CACHE_MAINT_OP_W-1:0] cache_maint_op;
  logic [PADDR_W-1:0] cache_maint_paddr;
  logic cache_maint_rsp_valid;
  logic cache_maint_rsp_ready;
  logic [CACHE_REQ_ID_W-1:0] cache_maint_rsp_id;
  logic [cache_pkg::CACHE_STATUS_W-1:0] cache_maint_rsp_status;

  logic unused_region_read_ok;
  logic unused_region_write_ok;
  logic unused_region_execute_ok;
  logic unused_region_idempotent;
  logic [REGION_INDEX_W-1:0] unused_region_match_index;
  logic unused_region_overlap;
  logic unused_local_req_valid;
  logic [VSP_MEM_ACCESS_W-1:0] unused_local_req_access;
  logic [31:0] unused_local_req_eaddr;
  logic [PADDR_W-1:0] unused_local_req_addr;
  logic unused_local_rsp_ready;
  logic unused_ifetch_busy;
  logic unused_perf_write_hit;
  logic unused_perf_write_miss;

  initial begin : p_parameter_guards
    if ((PADDR_W != 32) && (PADDR_W != 40))
      $fatal(1, "vsp_ifetch_cached_client_wrapper: PADDR_W must be 32 or 40");
    if ((FRONT_DATA_W != 32) && (FRONT_DATA_W != 128))
      $fatal(1, "vsp_ifetch_cached_client_wrapper: FRONT_DATA_W must be 32 or 128");
    if ((LOWER_DATA_W != 32) && (LOWER_DATA_W != 64) &&
        (LOWER_DATA_W != 128))
      $fatal(1, "vsp_ifetch_cached_client_wrapper: unsupported lower width");
    if ((ICACHE_LINE_BYTES % FRONT_BYTES) != 0 ||
        (ICACHE_LINE_BYTES % LOWER_BYTES) != 0)
      $fatal(1, "vsp_ifetch_cached_client_wrapper: line/beat geometry mismatch");
    if (CACHE_MEM_BEATS_W < $clog2(LINE_BEATS + 1))
      $fatal(1, "vsp_ifetch_cached_client_wrapper: beat-count field too narrow");
    if ((vsp_ifetch_adapter_pkg::VSP_IFETCH_MAX_WORDS != 4) ||
        (vsp_ifetch_adapter_pkg::VSP_IFETCH_WORD_W != 32) ||
        (vsp_ifetch_adapter_pkg::VSP_IFETCH_EADDR_W != 32) ||
        (vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W != 8))
      $fatal(1, "vsp_ifetch_cached_client_wrapper: incompatible IFetch ABI");
  end

  assign ready_o = rst_ni && icache_init_done_o && ifetch_init_done_o &&
                   !region_config_overlap_o;
  assign gated_source_req_valid = source_req_valid_i && ready_o &&
                                  source_admit_enable_i;
  assign source_req_ready_o = bridge_source_req_ready && ready_o &&
                              source_admit_enable_i;
  assign quiescent_o = bridge_idle_o && ifetch_idle_o &&
                       icache_adapter_idle_o && region_router_idle_o &&
                       icache_init_done_o;
  assign busy_o = !quiescent_o;
  assign protocol_error_o = bridge_protocol_error_o ||
      ifetch_protocol_error_o || icache_adapter_protocol_error_o;

  vsp_ifetch_request_bridge u_request_bridge (
    .clk_i,
    .rst_ni,
    .redirect_commit_i,
    .source_addr_space_i,
    .source_addr_context_i,
    .store_req_valid_i(gated_source_req_valid),
    .store_req_ready_o(bridge_source_req_ready),
    .store_req_pc_i(source_req_pc_i),
    .store_req_word_count_i(source_req_word_count_i),
    .store_rsp_valid_o(source_rsp_valid_o),
    .store_rsp_ready_i(source_rsp_ready_i),
    .store_rsp_words_o(source_rsp_words_o),
    .store_rsp_fault_o(source_rsp_fault_o),
    .fetch_req_valid_o(canonical_req_valid),
    .fetch_req_ready_i(canonical_req_ready),
    .fetch_req_eaddr_o(canonical_req_eaddr),
    .fetch_req_word_count_o(canonical_req_word_count),
    .fetch_req_addr_space_o(canonical_req_addr_space),
    .fetch_req_addr_context_o(canonical_req_addr_context),
    .fetch_rsp_valid_i(canonical_rsp_valid),
    .fetch_rsp_ready_o(canonical_rsp_ready),
    .fetch_rsp_words_i(canonical_rsp_words),
    .fetch_rsp_word_count_i(canonical_rsp_word_count),
    .fetch_rsp_fault_cause_i(canonical_rsp_fault),
    .fetch_rsp_fault_eaddr_i(canonical_rsp_fault_eaddr),
    .idle_o(bridge_idle_o),
    .busy_o(bridge_busy_o),
    .protocol_error_o(bridge_protocol_error_o),
    .protocol_error_clear_i
  );

  vsp_ifetch_cache_adapter #(
    .PADDR_W(PADDR_W),
    .FRONT_DATA_W(FRONT_DATA_W),
    .LINE_BYTES(ICACHE_LINE_BYTES),
    .TRANSLATION_ENABLE(TRANSLATION_ENABLE),
    .REGION_CHECK_ENABLE(1'b1),
    .LOCAL_ENABLE(1'b0)
  ) u_ifetch (
    .clk_i,
    .rst_ni,
    .cache_init_done_i(icache_init_done_o),
    .fetch_accept_enable_i(source_admit_enable_i || bridge_busy_o),
    .fetch_req_valid_i(canonical_req_valid),
    .fetch_req_ready_o(canonical_req_ready),
    .fetch_req_eaddr_i(canonical_req_eaddr),
    .fetch_req_word_count_i(canonical_req_word_count),
    .fetch_req_addr_space_i(canonical_req_addr_space),
    .fetch_req_addr_context_i(canonical_req_addr_context),
    .fetch_rsp_valid_o(canonical_rsp_valid),
    .fetch_rsp_ready_i(canonical_rsp_ready),
    .fetch_rsp_words_o(canonical_rsp_words),
    .fetch_rsp_word_count_o(canonical_rsp_word_count),
    .fetch_rsp_fault_cause_o(canonical_rsp_fault),
    .fetch_rsp_fault_eaddr_o(canonical_rsp_fault_eaddr),
    .fetch_rsp_fault_paddr_o(canonical_rsp_fault_paddr),
    .tr_req_valid_o(i_tr_req_valid_o),
    .tr_req_ready_i(i_tr_req_ready_i),
    .tr_req_vaddr_o(i_tr_req_vaddr_o),
    .tr_req_addr_context_o(i_tr_req_addr_context_o),
    .tr_req_access_o(i_tr_req_access_o),
    .tr_rsp_valid_i(i_tr_rsp_valid_i),
    .tr_rsp_ready_o(i_tr_rsp_ready_o),
    .tr_rsp_paddr_i(i_tr_rsp_paddr_i),
    .tr_rsp_fault_i(i_tr_rsp_fault_i),
    .tr_rsp_fault_vaddr_i(i_tr_rsp_fault_vaddr_i),
    .region_req_valid_o(region_req_valid),
    .region_req_ready_i(region_req_ready),
    .region_req_paddr_o(region_req_paddr),
    .region_req_access_o(region_req_access),
    .region_req_context_o(region_req_context),
    .region_rsp_valid_i(region_rsp_valid),
    .region_rsp_ready_o(region_rsp_ready),
    .region_rsp_endpoint_valid_i(region_rsp_endpoint_valid),
    .region_rsp_endpoint_i(region_rsp_endpoint),
    .region_rsp_match_valid_i(region_rsp_match_valid),
    .region_rsp_fault_i(region_rsp_fault),
    .cache_req_valid_o(beat_req_valid),
    .cache_req_ready_i(beat_req_ready),
    .cache_req_access_o(beat_req_access),
    .cache_req_eaddr_o(beat_req_eaddr),
    .cache_req_paddr_o(beat_req_paddr),
    .cache_req_wdata_o(beat_req_wdata),
    .cache_req_wstrb_o(beat_req_wstrb),
    .cache_rsp_valid_i(beat_rsp_valid),
    .cache_rsp_ready_o(beat_rsp_ready),
    .cache_rsp_rdata_i(beat_rsp_rdata),
    .cache_rsp_fault_cause_i(beat_rsp_fault),
    .cache_rsp_fault_eaddr_i(beat_rsp_fault_eaddr),
    .cache_rsp_fault_paddr_i(beat_rsp_fault_paddr),
    .local_req_valid_o(unused_local_req_valid),
    .local_req_ready_i(1'b0),
    .local_req_access_o(unused_local_req_access),
    .local_req_eaddr_o(unused_local_req_eaddr),
    .local_req_addr_o(unused_local_req_addr),
    .local_rsp_valid_i(1'b0),
    .local_rsp_ready_o(unused_local_rsp_ready),
    .local_rsp_rdata_i('0),
    .local_rsp_fault_cause_i(VSP_MEM_FAULT_NONE),
    .inv_req_valid_i,
    .inv_req_ready_o,
    .inv_req_all_i,
    .inv_req_paddr_i,
    .inv_rsp_valid_o,
    .inv_rsp_ready_i,
    .inv_rsp_status_o,
    .cache_maint_req_valid_o(beat_maint_req_valid),
    .cache_maint_req_ready_i(beat_maint_req_ready),
    .cache_maint_req_op_o(beat_maint_req_op),
    .cache_maint_req_paddr_o(beat_maint_req_paddr),
    .cache_maint_rsp_valid_i(beat_maint_rsp_valid),
    .cache_maint_rsp_ready_o(beat_maint_rsp_ready),
    .cache_maint_rsp_status_i(beat_maint_rsp_status),
    .init_done_o(ifetch_init_done_o),
    .idle_o(ifetch_idle_o),
    .busy_o(unused_ifetch_busy),
    .protocol_error_o(ifetch_protocol_error_o),
    .protocol_error_clear_i
  );

  vsp_address_region_router #(
    .PADDR_W(PADDR_W),
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
  ) u_region_router (
    .clk_i,
    .rst_ni,
    .region_req_valid_i(region_req_valid),
    .region_req_ready_o(region_req_ready),
    .region_req_paddr_i(region_req_paddr),
    .region_req_access_i(region_req_access),
    .region_req_context_i(region_req_context),
    .region_rsp_valid_o(region_rsp_valid),
    .region_rsp_ready_i(region_rsp_ready),
    .region_rsp_endpoint_valid_o(region_rsp_endpoint_valid),
    .region_rsp_endpoint_o(region_rsp_endpoint),
    .region_rsp_read_ok_o(unused_region_read_ok),
    .region_rsp_write_ok_o(unused_region_write_ok),
    .region_rsp_execute_ok_o(unused_region_execute_ok),
    .region_rsp_idempotent_o(unused_region_idempotent),
    .region_rsp_fault_o(region_rsp_fault),
    .region_rsp_match_valid_o(region_rsp_match_valid),
    .region_rsp_match_index_o(unused_region_match_index),
    .region_rsp_overlap_o(unused_region_overlap),
    .region_config_overlap_o(region_config_overlap_o),
    .idle_o(region_router_idle_o)
  );

  vsp_icache_beat_adapter #(
    .PADDR_W(PADDR_W),
    .EADDR_W(32),
    .FRONT_DATA_W(FRONT_DATA_W),
    .LINE_BYTES(ICACHE_LINE_BYTES),
    .REQ_ID_W(CACHE_REQ_ID_W),
    .USER_W(CACHE_USER_W),
    .CACHE_READ_ONLY(1'b1)
  ) u_beat_adapter (
    .clk_i,
    .rst_ni,
    .cache_init_done_i(icache_init_done_o),
    .req_valid_i(beat_req_valid),
    .req_ready_o(beat_req_ready),
    .req_access_i(beat_req_access),
    .req_eaddr_i(beat_req_eaddr),
    .req_paddr_i(beat_req_paddr),
    .req_wdata_i(beat_req_wdata),
    .req_wstrb_i(beat_req_wstrb),
    .rsp_valid_o(beat_rsp_valid),
    .rsp_ready_i(beat_rsp_ready),
    .rsp_rdata_o(beat_rsp_rdata),
    .rsp_fault_cause_o(beat_rsp_fault),
    .rsp_fault_eaddr_o(beat_rsp_fault_eaddr),
    .rsp_fault_paddr_o(beat_rsp_fault_paddr),
    .maint_req_valid_i(beat_maint_req_valid),
    .maint_req_ready_o(beat_maint_req_ready),
    .maint_req_op_i(beat_maint_req_op),
    .maint_req_paddr_i(beat_maint_req_paddr),
    .maint_rsp_valid_o(beat_maint_rsp_valid),
    .maint_rsp_ready_i(beat_maint_rsp_ready),
    .maint_rsp_status_o(beat_maint_rsp_status),
    .idle_o(icache_adapter_idle_o),
    .protocol_error_o(icache_adapter_protocol_error_o),
    .cache_req_valid_o(cache_req_valid),
    .cache_req_ready_i(cache_req_ready),
    .cache_req_id_o(cache_req_id),
    .cache_req_op_o(cache_req_op),
    .cache_req_paddr_o(cache_req_paddr),
    .cache_req_wdata_o(cache_req_wdata),
    .cache_req_wstrb_o(cache_req_wstrb),
    .cache_req_user_o(cache_req_user),
    .cache_rsp_valid_i(cache_rsp_valid),
    .cache_rsp_ready_o(cache_rsp_ready),
    .cache_rsp_id_i(cache_rsp_id),
    .cache_rsp_rdata_i(cache_rsp_rdata),
    .cache_rsp_status_i(cache_rsp_status),
    .cache_rsp_fault_paddr_i(cache_rsp_fault_paddr),
    .cache_rsp_user_i(cache_rsp_user),
    .cache_maint_valid_o(cache_maint_valid),
    .cache_maint_ready_i(cache_maint_ready),
    .cache_maint_id_o(cache_maint_id),
    .cache_maint_op_o(cache_maint_op),
    .cache_maint_paddr_o(cache_maint_paddr),
    .cache_maint_rsp_valid_i(cache_maint_rsp_valid),
    .cache_maint_rsp_ready_o(cache_maint_rsp_ready),
    .cache_maint_rsp_id_i(cache_maint_rsp_id),
    .cache_maint_rsp_status_i(cache_maint_rsp_status)
  );

  param_cache #(
    .PADDR_W(PADDR_W),
    .FRONT_DATA_W(FRONT_DATA_W),
    .LOWER_DATA_W(LOWER_DATA_W),
    .LINE_BYTES(ICACHE_LINE_BYTES),
    .SET_COUNT(ICACHE_SET_COUNT),
    .WAY_COUNT(ICACHE_WAY_COUNT),
    .REQ_ID_W(CACHE_REQ_ID_W),
    .USER_W(CACHE_USER_W),
    .RAM_RD_LATENCY(ICACHE_RAM_RD_LATENCY),
    .READ_ONLY(1'b1),
    .MEM_BEATS_W(CACHE_MEM_BEATS_W)
  ) u_icache (
    .clk_i,
    .rst_ni,
    .req_valid_i(cache_req_valid),
    .req_ready_o(cache_req_ready),
    .req_id_i(cache_req_id),
    .req_op_i(cache_req_op),
    .req_paddr_i(cache_req_paddr),
    .req_wdata_i(cache_req_wdata),
    .req_wstrb_i(cache_req_wstrb),
    .req_user_i(cache_req_user),
    .rsp_valid_o(cache_rsp_valid),
    .rsp_ready_i(cache_rsp_ready),
    .rsp_id_o(cache_rsp_id),
    .rsp_rdata_o(cache_rsp_rdata),
    .rsp_status_o(cache_rsp_status),
    .rsp_fault_paddr_o(cache_rsp_fault_paddr),
    .rsp_user_o(cache_rsp_user),
    .maint_valid_i(cache_maint_valid),
    .maint_ready_o(cache_maint_ready),
    .maint_id_i(cache_maint_id),
    .maint_op_i(cache_maint_op),
    .maint_paddr_i(cache_maint_paddr),
    .maint_rsp_valid_o(cache_maint_rsp_valid),
    .maint_rsp_ready_i(cache_maint_rsp_ready),
    .maint_rsp_id_o(cache_maint_rsp_id),
    .maint_rsp_status_o(cache_maint_rsp_status),
    .mem_cmd_valid_o(ic_mem_cmd_valid_o),
    .mem_cmd_ready_i(ic_mem_cmd_ready_i),
    .mem_cmd_id_o(ic_mem_cmd_id_o),
    .mem_cmd_op_o(ic_mem_cmd_op_o),
    .mem_cmd_paddr_o(ic_mem_cmd_paddr_o),
    .mem_cmd_beats_o(ic_mem_cmd_beats_o),
    .mem_w_valid_o(ic_mem_w_valid_o),
    .mem_w_ready_i(ic_mem_w_ready_i),
    .mem_w_id_o(ic_mem_w_id_o),
    .mem_w_data_o(ic_mem_w_data_o),
    .mem_wstrb_o(ic_mem_wstrb_o),
    .mem_w_last_o(ic_mem_w_last_o),
    .mem_r_valid_i(ic_mem_r_valid_i),
    .mem_r_ready_o(ic_mem_r_ready_o),
    .mem_r_id_i(ic_mem_r_id_i),
    .mem_r_data_i(ic_mem_r_data_i),
    .mem_r_last_i(ic_mem_r_last_i),
    .mem_r_status_i(ic_mem_r_status_i),
    .mem_r_fault_paddr_i(ic_mem_r_fault_paddr_i),
    .mem_b_valid_i(ic_mem_b_valid_i),
    .mem_b_ready_o(ic_mem_b_ready_o),
    .mem_b_id_i(ic_mem_b_id_i),
    .mem_b_status_i(ic_mem_b_status_i),
    .mem_b_fault_paddr_i(ic_mem_b_fault_paddr_i),
    .init_busy_o(icache_init_busy_o),
    .init_done_o(icache_init_done_o),
    .perf_read_hit_o(perf_icache_read_hit_o),
    .perf_read_miss_o(perf_icache_read_miss_o),
    .perf_write_hit_o(unused_perf_write_hit),
    .perf_write_miss_o(unused_perf_write_miss)
  );

  /* verilator lint_off UNUSED */
  wire unused_observation = &{1'b0, canonical_rsp_fault_paddr,
      unused_region_read_ok, unused_region_write_ok,
      unused_region_execute_ok, unused_region_idempotent,
      unused_region_match_index, unused_region_overlap,
      unused_local_req_valid, unused_local_req_access,
      unused_local_req_eaddr, unused_local_req_addr,
      unused_local_rsp_ready, unused_ifetch_busy, unused_perf_write_hit,
      unused_perf_write_miss};
  /* verilator lint_on UNUSED */

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk_i) begin : p_contract_assertions
    if (rst_ni) begin
      assert (!(source_req_ready_o && !source_admit_enable_i))
        else $error("vsp_ifetch_cached_client_wrapper: source admitted while quiesced");
      assert (!ic_mem_w_valid_o)
        else $error("vsp_ifetch_cached_client_wrapper: read-only I-cache emitted write data");
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule

`default_nettype wire
