// SPDX-License-Identifier: MIT

`default_nettype none

// Executable VSP uword core with a product I/D memory-system composition.
//
// Instruction delivery uses the external provider profile of the program
// core, a redirect-aware compatibility bridge, the shared iMMU, a read-only
// I-cache and the same ordered physical fabric used by D-cache/PTW/uncached
// traffic.  The only system-facing data boundary is still the generic ordered
// lower port; AXI, DMA and SoC target decode remain outside this module.
module vsp_uword_memory_system_wrapper #(
  parameter integer PC_W = 32,
  parameter integer STORE_WORDS = 64,
  parameter logic [PC_W-1:0] STORE_BASE_PC = '0,
  parameter integer FETCH_WORDS = 4,
  parameter integer ADMIT_SLOTS = 3,
  parameter integer GROUP_COUNT = 4,
  parameter integer ISSUE_SLOTS = 1,
  parameter integer QUEUE_DEPTH = 4,
  parameter integer TRACKER_ENTRIES = 4,
  parameter integer LANES = 4,
  parameter integer ELEM_W = 8,
  parameter integer ACC_W = 32,
  parameter integer VREGS = 16,
  parameter integer AREGS = 8,
  parameter integer MREGS = 4,
  parameter integer CONTEXT_COUNT = 1,
  parameter integer TAG_W = 8,
  parameter integer RESOURCE_W = 8,
  parameter integer SIMD4_ID_W = 8,
  parameter logic [SIMD4_ID_W-1:0] SIMD4_BASE_ID = '0,
  parameter integer MEM_OFFSET_W = 16,
  parameter integer STATE_REGS = 32,
  parameter integer DECODE_ERROR_W =
      vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W,
  parameter integer VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter integer CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                                $clog2(CONTEXT_COUNT),
  parameter integer GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 :
                                 $clog2(GROUP_COUNT),
  parameter integer INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter integer OFFSET_W = $clog2(LANES + 1),
  parameter integer SPAN_BYTES_W = ((GROUP_COUNT*LANES) <= 1) ? 1 :
                                   $clog2((GROUP_COUNT*LANES) + 1),

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

  parameter integer LOWER_DATA_W = 32,
  parameter integer DCACHE_LINE_BYTES = 32,
  parameter integer DCACHE_SET_COUNT = 64,
  parameter integer DCACHE_WAY_COUNT = 2,
  parameter integer DCACHE_RAM_RD_LATENCY = 1,
  parameter integer ICACHE_FRONT_DATA_W = 128,
  parameter integer ICACHE_LINE_BYTES = 32,
  parameter integer ICACHE_SET_COUNT = 64,
  parameter integer ICACHE_WAY_COUNT = 2,
  parameter integer ICACHE_RAM_RD_LATENCY = 1,
  parameter integer CACHE_REQ_ID_W = 1,
  parameter integer CACHE_USER_W = 1,
  parameter integer CACHE_MEM_BEATS_W =
      ((((DCACHE_LINE_BYTES > ICACHE_LINE_BYTES) ? DCACHE_LINE_BYTES :
          ICACHE_LINE_BYTES) / (LOWER_DATA_W / 8)) <= 1) ? 1 :
      $clog2((((DCACHE_LINE_BYTES > ICACHE_LINE_BYTES) ?
               DCACHE_LINE_BYTES : ICACHE_LINE_BYTES) /
              (LOWER_DATA_W / 8)) + 1),
  parameter logic [PADDR_W-1:0] LOCAL_BASE_ADDR = '0,
  parameter integer LOCAL_DEPTH_WORDS = 1024
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One launch owns both execution metadata and independent I-side address
  // metadata.  The latter is captured for the full run and is not an ASID.
  input  logic                                      start_valid_i,
  output logic                                      start_ready_o,
  input  logic [PC_W-1:0]                           start_pc_i,
  input  logic [PC_W-1:0]                           end_pc_i,
  input  logic [CONTEXT_W-1:0]                      start_context_i,
  input  logic [GROUP_COUNT-1:0]                    start_group_mask_i,
  input  logic [TAG_W-1:0]                          start_tag_seed_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                                     start_ifetch_addr_space_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
                                                     start_ifetch_addr_context_i,

  output logic [PC_W-1:0]                           fetch_pc_o,
  output logic                                      fetch_running_o,
  output logic                                      fetch_stop_o,
  output logic                                      program_active_o,
  output logic                                      program_done_o,
  output logic                                      program_failed_o,
  output logic                                      program_error_o,
  output logic                                      program_halted_o,
  output logic [PC_W-1:0]                           program_terminal_pc_o,

  // First consumed IFetch fault on this launch's current fetch path.  An
  // older branch can redirect after a speculative fault was consumed, so
  // committed redirect clears this record with the source's transport fault.
  // Reset and actual start also clear it; protocol diagnostic clear and
  // program completion do not.  The physical address is the IFetch IP's
  // diagnostic value, with no implied physical-valid bit.
  output logic                                      ifetch_fault_valid_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     ifetch_fault_cause_o,
  output logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_EADDR_W-1:0]
                                                     ifetch_fault_eaddr_o,
  output logic [PADDR_W-1:0]                        ifetch_fault_paddr_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                                     ifetch_fault_addr_space_o,
  output logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
                                                     ifetch_fault_addr_context_o,

  output logic                                      action_cpl_valid_o,
  input  logic                                      action_cpl_ready_i,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     action_cpl_class_o,
  output logic [CONTEXT_W-1:0]                      action_cpl_context_o,
  output logic [TAG_W-1:0]                          action_cpl_tag_o,
  output logic [GROUP_COUNT-1:0]                    action_cpl_group_mask_o,
  output logic [vsp_action_pkg::VSP_ACTION_CPL_STATUS_W-1:0]
                                                     action_cpl_status_o,
  output logic [DECODE_ERROR_W-1:0]                 action_cpl_decode_error_o,
  output logic                                      action_cpl_end_o,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]         action_cpl_memory_op_o,
  output logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
                                                     action_cpl_memory_status_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                                     action_cpl_memory_fault_cause_o,
  output logic [31:0]                               action_cpl_memory_fault_eaddr_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_requested_group_mask_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_completed_group_mask_o,
  output logic [GROUP_COUNT-1:0]
                                                     action_cpl_memory_failed_group_mask_o,
  output logic [SPAN_BYTES_W-1:0]
                                                     action_cpl_memory_bytes_committed_o,
  output logic                                      action_cpl_memory_partial_o,

  output logic                                      exec_result_valid_o,
  input  logic                                      exec_result_ready_i,
  output logic [GROUP_ID_W-1:0]                     exec_result_group_o,
  output logic [CONTEXT_W-1:0]                      exec_result_context_o,
  output logic [TAG_W-1:0]                          exec_result_tag_o,
  output logic                                      exec_result_illegal_o,
  output logic                                      exec_result_has_narrow_o,
  output logic [(LANES*ELEM_W)-1:0]                 exec_result_narrow_o,
  output logic [LANES-1:0]                          exec_result_narrow_mask_o,
  output logic                                      exec_result_has_reduce_o,
  output logic [ACC_W-1:0]                          exec_result_reduce_value_o,
  output logic [INDEX_W-1:0]                        exec_result_reduce_index_o,
  output logic                                      exec_result_has_count_o,
  output logic [OFFSET_W-1:0]                       exec_result_count_o,

  // MMU context programming remains an out-of-program host operation.
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

  // Global I/D/TLB/fabric maintenance.  Mid-program admission is withheld
  // until the sequencer defines how FENCE.I flushes already framed records.
  input  logic                                      maint_cmd_valid_i,
  output logic                                      maint_cmd_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_MAINT_OP_W-1:0]
                                                     maint_cmd_op_i,
  input  logic [31:0]                               maint_cmd_eaddr_i,
  input  logic [PADDR_W-1:0]                        maint_cmd_paddr_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
                                                     maint_cmd_addr_context_i,
  input  logic [ASID_W-1:0]                         maint_cmd_asid_i,
  output logic                                      maint_cpl_valid_o,
  input  logic                                      maint_cpl_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_MAINT_CPL_STATUS_W-1:0]
                                                     maint_cpl_status_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
                                                     maint_cpl_fault_o,
  output logic                                      maint_busy_o,
  output logic                                      maint_quiescent_o,
  output logic [vsp_memory_maintenance_pkg::VSP_MAINT_STEP_W-1:0]
                                                     maint_current_step_o,

  // Protocol-neutral lower-memory port shared by I-cache, D-cache, PTW and
  // fixed-beat uncached/device traffic.
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

  output logic                                      system_ready_o,
  output logic                                      system_quiescent_o,
  output logic                                      system_busy_o,
  output logic                                      dmem_path_ready_o,
  output logic                                      ifetch_path_ready_o,
  output logic                                      mmu_init_done_o,
  output logic                                      dcache_init_done_o,
  output logic                                      icache_init_done_o,
  output logic                                      fabric_quarantine_o,
  output logic                                      i_region_config_overlap_o,
  output logic                                      d_region_config_overlap_o,
  output logic                                      perf_icache_read_hit_o,
  output logic                                      perf_icache_read_miss_o,
  output logic                                      perf_dcache_read_hit_o,
  output logic                                      perf_dcache_read_miss_o,
  output logic                                      perf_dcache_write_hit_o,
  output logic                                      perf_dcache_write_miss_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      fetch_protocol_error_o,
  output logic                                      cluster_protocol_error_o,
  output logic                                      ifetch_path_protocol_error_o,
  output logic                                      dmem_path_protocol_error_o,
  output logic                                      maint_protocol_error_o,
  output logic                                      protocol_error_o
);
  import vsp_mem_common_pkg::*;

  localparam integer LOWER_BYTES = LOWER_DATA_W / 8;
  localparam integer MAX_LINE_BYTES =
      (DCACHE_LINE_BYTES > ICACHE_LINE_BYTES) ? DCACHE_LINE_BYTES :
                                                ICACHE_LINE_BYTES;
  localparam integer MAX_LINE_BEATS = MAX_LINE_BYTES / LOWER_BYTES;

  logic program_start_valid;
  logic program_start_ready;
  logic program_protocol_error;
  logic program_start_fire;

  logic [VSP_MEM_ADDR_SPACE_W-1:0] ifetch_addr_space_q;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
      ifetch_addr_context_q;
  logic provider_req_valid;
  logic provider_req_ready;
  logic [31:0] provider_req_pc;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_WORD_COUNT_W-1:0]
      provider_req_word_count;
  logic provider_rsp_valid;
  logic provider_rsp_ready;
  logic [127:0] provider_rsp_words;
  logic provider_rsp_fault;
  logic [VSP_MEM_FAULT_W-1:0] provider_rsp_fault_cause;
  logic [31:0] provider_rsp_fault_eaddr;
  logic [PADDR_W-1:0] provider_rsp_fault_paddr;
  logic redirect_commit;

  logic program_dmem_req_valid;
  logic program_dmem_req_ready;
  logic [vsp_pkg::VSP_MEM_OP_W-1:0] program_dmem_req_op;
  logic [31:0] program_dmem_req_eaddr;
  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
      program_dmem_req_addr_space;
  logic [7:0] program_dmem_req_addr_context;
  logic [31:0] program_dmem_req_wdata;
  logic [3:0] program_dmem_req_wstrb;
  logic program_dmem_rsp_valid;
  logic program_dmem_rsp_ready;
  logic [31:0] program_dmem_rsp_rdata;
  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0] program_dmem_rsp_fault;
  logic gated_dmem_req_valid;
  logic raw_dmem_req_ready;

  logic i_tr_req_valid;
  logic i_tr_req_ready;
  logic [31:0] i_tr_req_vaddr;
  logic [7:0] i_tr_req_context;
  logic [VSP_MEM_ACCESS_W-1:0] i_tr_req_access;
  logic i_tr_rsp_valid;
  logic i_tr_rsp_ready;
  logic [PADDR_W-1:0] i_tr_rsp_paddr;
  logic [VSP_MEM_FAULT_W-1:0] i_tr_rsp_fault;
  logic [31:0] i_tr_rsp_fault_vaddr;

  logic ic_mem_cmd_valid;
  logic ic_mem_cmd_ready;
  logic [CACHE_REQ_ID_W-1:0] ic_mem_cmd_id;
  logic [cache_pkg::CACHE_MEM_OP_W-1:0] ic_mem_cmd_op;
  logic [PADDR_W-1:0] ic_mem_cmd_paddr;
  logic [CACHE_MEM_BEATS_W-1:0] ic_mem_cmd_beats;
  logic ic_mem_w_valid;
  logic ic_mem_w_ready;
  logic [CACHE_REQ_ID_W-1:0] ic_mem_w_id;
  logic [LOWER_DATA_W-1:0] ic_mem_w_data;
  logic [(LOWER_DATA_W/8)-1:0] ic_mem_wstrb;
  logic ic_mem_w_last;
  logic ic_mem_r_valid;
  logic ic_mem_r_ready;
  logic [CACHE_REQ_ID_W-1:0] ic_mem_r_id;
  logic [LOWER_DATA_W-1:0] ic_mem_r_data;
  logic ic_mem_r_last;
  logic [cache_pkg::CACHE_STATUS_W-1:0] ic_mem_r_status;
  logic [PADDR_W-1:0] ic_mem_r_fault_paddr;
  logic ic_mem_b_valid;
  logic ic_mem_b_ready;
  logic [CACHE_REQ_ID_W-1:0] ic_mem_b_id;
  logic [cache_pkg::CACHE_STATUS_W-1:0] ic_mem_b_status;
  logic [PADDR_W-1:0] ic_mem_b_fault_paddr;

  logic ifetch_path_quiescent;
  logic ifetch_bridge_idle;
  logic ifetch_bridge_busy;
  logic ifetch_adapter_init_done;
  logic ifetch_adapter_idle;
  logic icache_init_busy;
  logic icache_adapter_idle;
  logic i_region_router_idle;
  logic ifetch_bridge_protocol_error;
  logic ifetch_adapter_protocol_error;
  logic icache_adapter_protocol_error;

  logic dmem_path_quiescent;
  logic lsu_idle;
  logic mmu_quiescent;
  logic dcache_idle;
  logic fabric_idle;
  logic fabric_drain_req;
  logic fabric_drain_done;

  logic maint_i_quiesce;
  logic maint_d_quiesce;
  logic maint_raw_cmd_valid;
  logic maint_raw_cmd_ready;
  logic maint_cmd_allowed;
  logic maint_d_req_valid;
  logic maint_d_req_ready;
  logic [VSP_MEM_CACHE_MAINT_OP_W-1:0] maint_d_req_op;
  logic [PADDR_W-1:0] maint_d_req_paddr;
  logic maint_d_rsp_valid;
  logic maint_d_rsp_ready;
  logic [VSP_MEM_STATUS_W-1:0] maint_d_rsp_status;
  logic maint_i_req_valid;
  logic maint_i_req_ready;
  logic [VSP_MEM_CACHE_MAINT_OP_W-1:0] maint_i_req_op;
  logic [PADDR_W-1:0] maint_i_req_paddr;
  logic maint_i_rsp_valid;
  logic maint_i_rsp_ready;
  logic [VSP_MEM_STATUS_W-1:0] maint_i_rsp_status;
  logic maint_tlb_req_valid;
  logic maint_tlb_req_ready;
  logic [VSP_MEM_TLB_INV_SCOPE_W-1:0] maint_tlb_req_scope;
  logic [ASID_W-1:0] maint_tlb_req_asid;
  logic [31:0] maint_tlb_req_vaddr;
  logic maint_tlb_rsp_valid;
  logic maint_tlb_rsp_ready;
  logic [VSP_MEM_STATUS_W-1:0] maint_tlb_rsp_status;

  logic cfg_active_q;
  logic cfg_req_pending_q;
  logic cfg_write_q;
  logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0] cfg_context_q;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_FIELD_W-1:0] cfg_field_q;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0] cfg_wdata_q;
  logic cfg_request_allowed;
  logic raw_cfg_valid;
  logic raw_cfg_ready;
  logic raw_cfg_rsp_valid;
  logic raw_cfg_rsp_ready;
  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0] raw_cfg_rsp_rdata;
  logic [VSP_MEM_STATUS_W-1:0] raw_cfg_rsp_status;
  logic raw_paths_ready;
  logic raw_paths_quiescent;

  logic unused_store_write_ready;
  logic unused_dmem_busy;
  logic unused_mmu_busy;
  logic unused_ifetch_busy;
  logic unused_fabric_busy;

  initial begin : p_profile_guards
    if ((PC_W != 32) || (FETCH_WORDS != 4))
      $fatal(1, "vsp_uword_memory_system_wrapper: product IFetch requires PC32/FETCH4");
    if ((LANES != 4) || (ELEM_W != 8))
      $fatal(1, "vsp_uword_memory_system_wrapper: D-side beat requires SIMD4x8");
    if (CONTEXT_COUNT != 1)
      $fatal(1, "vsp_uword_memory_system_wrapper: executable profile requires one context");
    if (ICACHE_FRONT_DATA_W != 128)
      $fatal(1, "vsp_uword_memory_system_wrapper: first product I-cache front is 128-bit");
    if ((DCACHE_LINE_BYTES % LOWER_BYTES) != 0 ||
        (ICACHE_LINE_BYTES % LOWER_BYTES) != 0)
      $fatal(1, "vsp_uword_memory_system_wrapper: cache/lower geometry mismatch");
    if (CACHE_MEM_BEATS_W < $clog2(MAX_LINE_BEATS + 1))
      $fatal(1, "vsp_uword_memory_system_wrapper: shared beat-count field too narrow");
  end

  assign raw_paths_ready = dmem_path_ready_o && ifetch_path_ready_o;
  assign raw_paths_quiescent = dmem_path_quiescent &&
                               ifetch_path_quiescent;
  assign system_ready_o = raw_paths_ready && maint_quiescent_o &&
                          !cfg_active_q;
  assign system_quiescent_o = raw_paths_quiescent && maint_quiescent_o &&
                              !cfg_active_q && !program_active_o;
  assign system_busy_o = !system_quiescent_o;

  // A simultaneous host maintenance/config request has deterministic
  // maintenance priority.  Do not cross-gate both valids, which would leave
  // both ready signals low forever if a host holds both requests stable.
  assign maint_cmd_allowed = raw_paths_ready && !program_active_o &&
                             !cfg_active_q;
  assign maint_raw_cmd_valid = maint_cmd_valid_i && maint_cmd_allowed;
  assign maint_cmd_ready_o = maint_raw_cmd_ready && maint_cmd_allowed;

  // Accept configuration into a one-entry ownership register before exposing
  // it to the MMU.  Once raw_cfg_valid rises it therefore cannot be withdrawn
  // by a later maintenance request while the MMU is stalled.  Maintenance has
  // priority only when both host requests first arrive in the same cycle.
  assign cfg_request_allowed = rst_ni && raw_paths_ready &&
      raw_paths_quiescent && !program_active_o && maint_quiescent_o &&
      !maint_cmd_valid_i && !cfg_active_q;
  assign raw_cfg_valid = cfg_req_pending_q;
  assign mmu_cfg_ready_o = cfg_request_allowed;
  assign mmu_cfg_rsp_valid_o = raw_cfg_rsp_valid && cfg_active_q;
  assign raw_cfg_rsp_ready = cfg_active_q ? mmu_cfg_rsp_ready_i : 1'b1;
  assign mmu_cfg_rsp_rdata_o = raw_cfg_rsp_rdata;
  assign mmu_cfg_rsp_status_o = raw_cfg_rsp_status;

  assign start_ready_o = program_start_ready && system_ready_o &&
      system_quiescent_o && !maint_cmd_valid_i && !mmu_cfg_valid_i;
  assign program_start_valid = start_valid_i && system_ready_o &&
      system_quiescent_o && !maint_cmd_valid_i && !mmu_cfg_valid_i;
  assign program_start_fire = program_start_valid && program_start_ready;

  // Acceptance-cycle quiesce has priority over a new D-side beat.  Responses
  // and all downstream ready paths remain unqualified so older work drains.
  assign gated_dmem_req_valid = program_dmem_req_valid && !maint_d_quiesce;
  assign program_dmem_req_ready = raw_dmem_req_ready && !maint_d_quiesce;

  assign protocol_error_o = program_protocol_error ||
      ifetch_path_protocol_error_o || dmem_path_protocol_error_o ||
      maint_protocol_error_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_launch_metadata
    if (!rst_ni) begin
      ifetch_addr_space_q <= VSP_MEM_ADDR_SPACE_PHYSICAL;
      ifetch_addr_context_q <= '0;
    end else if (program_start_fire) begin
      ifetch_addr_space_q <= start_ifetch_addr_space_i;
      ifetch_addr_context_q <= start_ifetch_addr_context_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_ifetch_fault_record
    if (!rst_ni) begin
      ifetch_fault_valid_o <= 1'b0;
      ifetch_fault_cause_o <= VSP_MEM_FAULT_NONE;
      ifetch_fault_eaddr_o <= '0;
      ifetch_fault_paddr_o <= '0;
      ifetch_fault_addr_space_o <= '0;
      ifetch_fault_addr_context_o <= '0;
    end else if (program_start_fire || redirect_commit) begin
      ifetch_fault_valid_o <= 1'b0;
      ifetch_fault_cause_o <= VSP_MEM_FAULT_NONE;
      ifetch_fault_eaddr_o <= '0;
      ifetch_fault_paddr_o <= '0;
      ifetch_fault_addr_space_o <= '0;
      ifetch_fault_addr_context_o <= '0;
    end else if (!ifetch_fault_valid_o && provider_rsp_valid &&
                 provider_rsp_ready && provider_rsp_fault) begin
      // Capture only on consumption: a held response can still be poisoned.
      // Even a consumed fault remains speculative relative to an older
      // branch, so redirect above clears it before the new path can report.
      // The bridge qualifies both fault and metadata before this edge.
      ifetch_fault_valid_o <= 1'b1;
      ifetch_fault_cause_o <= provider_rsp_fault_cause;
      ifetch_fault_eaddr_o <= provider_rsp_fault_eaddr;
      ifetch_fault_paddr_o <= provider_rsp_fault_paddr;
      ifetch_fault_addr_space_o <= ifetch_addr_space_q;
      ifetch_fault_addr_context_o <= ifetch_addr_context_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_cfg_owner
    if (!rst_ni) begin
      cfg_active_q <= 1'b0;
      cfg_req_pending_q <= 1'b0;
      cfg_write_q <= 1'b0;
      cfg_context_q <= '0;
      cfg_field_q <= '0;
      cfg_wdata_q <= '0;
    end else begin
      if (mmu_cfg_valid_i && mmu_cfg_ready_o) begin
        cfg_active_q <= 1'b1;
        cfg_req_pending_q <= 1'b1;
        cfg_write_q <= mmu_cfg_write_i;
        cfg_context_q <= mmu_cfg_context_i;
        cfg_field_q <= mmu_cfg_field_i;
        cfg_wdata_q <= mmu_cfg_wdata_i;
      end
      if (raw_cfg_valid && raw_cfg_ready)
        cfg_req_pending_q <= 1'b0;
      if (raw_cfg_rsp_valid && raw_cfg_rsp_ready) begin
        cfg_active_q <= 1'b0;
        cfg_req_pending_q <= 1'b0;
      end
    end
  end

  vsp_uword_cluster_program_wrapper #(
    .PC_W(PC_W),
    .STORE_WORDS(STORE_WORDS),
    .STORE_BASE_PC(STORE_BASE_PC),
    .FETCH_WORDS(FETCH_WORDS),
    .EXTERNAL_FETCH_PROVIDER(1'b1),
    .ADMIT_SLOTS(ADMIT_SLOTS),
    .GROUP_COUNT(GROUP_COUNT),
    .ISSUE_SLOTS(ISSUE_SLOTS),
    .QUEUE_DEPTH(QUEUE_DEPTH),
    .TRACKER_ENTRIES(TRACKER_ENTRIES),
    .LANES(LANES),
    .ELEM_W(ELEM_W),
    .ACC_W(ACC_W),
    .VREGS(VREGS),
    .AREGS(AREGS),
    .MREGS(MREGS),
    .CONTEXT_COUNT(CONTEXT_COUNT),
    .TAG_W(TAG_W),
    .RESOURCE_W(RESOURCE_W),
    .SIMD4_ID_W(SIMD4_ID_W),
    .SIMD4_BASE_ID(SIMD4_BASE_ID),
    .MEM_EADDR_W(32),
    .MEM_OFFSET_W(MEM_OFFSET_W),
    .ADDR_CONTEXT_W(8),
    .STATE_REGS(STATE_REGS),
    .DECODE_ERROR_W(DECODE_ERROR_W),
    .VRF_ADDR_W(VRF_ADDR_W),
    .CONTEXT_W(CONTEXT_W),
    .GROUP_ID_W(GROUP_ID_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W),
    .SPAN_BYTES_W(SPAN_BYTES_W)
  ) u_program (
    .clk_i,
    .rst_ni,
    .store_write_valid_i(1'b0),
    .store_write_ready_o(unused_store_write_ready),
    .store_write_pc_i('0),
    .store_write_data_i('0),
    .ifetch_provider_req_valid_o(provider_req_valid),
    .ifetch_provider_req_ready_i(provider_req_ready),
    .ifetch_provider_req_pc_o(provider_req_pc),
    .ifetch_provider_req_word_count_o(provider_req_word_count),
    .ifetch_provider_rsp_valid_i(provider_rsp_valid),
    .ifetch_provider_rsp_ready_o(provider_rsp_ready),
    .ifetch_provider_rsp_words_i(provider_rsp_words),
    .ifetch_provider_rsp_fault_i(provider_rsp_fault),
    .ifetch_redirect_commit_o(redirect_commit),
    .start_valid_i(program_start_valid),
    .start_ready_o(program_start_ready),
    .start_pc_i,
    .end_pc_i,
    .start_context_i,
    .start_group_mask_i,
    .start_tag_seed_i,
    .fetch_pc_o,
    .fetch_running_o,
    .fetch_stop_o,
    .program_active_o,
    .program_done_o,
    .program_failed_o,
    .program_error_o,
    .program_halted_o,
    .program_terminal_pc_o,
    .action_cpl_valid_o,
    .action_cpl_ready_i,
    .action_cpl_class_o,
    .action_cpl_context_o,
    .action_cpl_tag_o,
    .action_cpl_group_mask_o,
    .action_cpl_status_o,
    .action_cpl_decode_error_o,
    .action_cpl_end_o,
    .action_cpl_memory_op_o,
    .action_cpl_memory_status_o,
    .action_cpl_memory_fault_cause_o,
    .action_cpl_memory_fault_eaddr_o,
    .action_cpl_memory_requested_group_mask_o,
    .action_cpl_memory_completed_group_mask_o,
    .action_cpl_memory_failed_group_mask_o,
    .action_cpl_memory_bytes_committed_o,
    .action_cpl_memory_partial_o,
    .exec_result_valid_o,
    .exec_result_ready_i,
    .exec_result_group_o,
    .exec_result_context_o,
    .exec_result_tag_o,
    .exec_result_illegal_o,
    .exec_result_has_narrow_o,
    .exec_result_narrow_o,
    .exec_result_narrow_mask_o,
    .exec_result_has_reduce_o,
    .exec_result_reduce_value_o,
    .exec_result_reduce_index_o,
    .exec_result_has_count_o,
    .exec_result_count_o,
    .dmem_req_valid_o(program_dmem_req_valid),
    .dmem_req_ready_i(program_dmem_req_ready),
    .dmem_req_op_o(program_dmem_req_op),
    .dmem_req_eaddr_o(program_dmem_req_eaddr),
    .dmem_req_addr_space_o(program_dmem_req_addr_space),
    .dmem_req_addr_context_o(program_dmem_req_addr_context),
    .dmem_req_wdata_o(program_dmem_req_wdata),
    .dmem_req_wstrb_o(program_dmem_req_wstrb),
    .dmem_rsp_valid_i(program_dmem_rsp_valid),
    .dmem_rsp_ready_o(program_dmem_rsp_ready),
    .dmem_rsp_rdata_i(program_dmem_rsp_rdata),
    .dmem_rsp_fault_cause_i(program_dmem_rsp_fault),
    .protocol_error_clear_i,
    .fetch_protocol_error_o,
    .cluster_protocol_error_o,
    .protocol_error_o(program_protocol_error)
  );

  vsp_ifetch_cached_client_wrapper #(
    .PADDR_W(PADDR_W),
    .TRANSLATION_ENABLE(TRANSLATION_ENABLE),
    .REGION_COUNT(REGION_COUNT),
    .REGION_INDEX_W(REGION_INDEX_W),
    .REGION_ENABLE(REGION_ENABLE),
    .REGION_BASE(REGION_BASE),
    .REGION_MASK(REGION_MASK),
    .REGION_ENDPOINT(REGION_ENDPOINT),
    .REGION_READ_OK(REGION_READ_OK),
    .REGION_WRITE_OK(REGION_WRITE_OK),
    .REGION_EXECUTE_OK(REGION_EXECUTE_OK),
    .REGION_IDEMPOTENT(REGION_IDEMPOTENT),
    .FRONT_DATA_W(ICACHE_FRONT_DATA_W),
    .LOWER_DATA_W(LOWER_DATA_W),
    .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES),
    .ICACHE_SET_COUNT(ICACHE_SET_COUNT),
    .ICACHE_WAY_COUNT(ICACHE_WAY_COUNT),
    .ICACHE_RAM_RD_LATENCY(ICACHE_RAM_RD_LATENCY),
    .CACHE_REQ_ID_W(CACHE_REQ_ID_W),
    .CACHE_USER_W(CACHE_USER_W),
    .CACHE_MEM_BEATS_W(CACHE_MEM_BEATS_W)
  ) u_ifetch (
    .clk_i,
    .rst_ni,
    .source_admit_enable_i(!maint_i_quiesce),
    .redirect_commit_i(redirect_commit),
    .source_addr_space_i(ifetch_addr_space_q),
    .source_addr_context_i(ifetch_addr_context_q),
    .source_req_valid_i(provider_req_valid),
    .source_req_ready_o(provider_req_ready),
    .source_req_pc_i(provider_req_pc),
    .source_req_word_count_i(provider_req_word_count),
    .source_rsp_valid_o(provider_rsp_valid),
    .source_rsp_ready_i(provider_rsp_ready),
    .source_rsp_words_o(provider_rsp_words),
    .source_rsp_fault_o(provider_rsp_fault),
    .source_rsp_fault_cause_o(provider_rsp_fault_cause),
    .source_rsp_fault_eaddr_o(provider_rsp_fault_eaddr),
    .source_rsp_fault_paddr_o(provider_rsp_fault_paddr),
    .i_tr_req_valid_o(i_tr_req_valid),
    .i_tr_req_ready_i(i_tr_req_ready),
    .i_tr_req_vaddr_o(i_tr_req_vaddr),
    .i_tr_req_addr_context_o(i_tr_req_context),
    .i_tr_req_access_o(i_tr_req_access),
    .i_tr_rsp_valid_i(i_tr_rsp_valid),
    .i_tr_rsp_ready_o(i_tr_rsp_ready),
    .i_tr_rsp_paddr_i(i_tr_rsp_paddr),
    .i_tr_rsp_fault_i(i_tr_rsp_fault),
    .i_tr_rsp_fault_vaddr_i(i_tr_rsp_fault_vaddr),
    .inv_req_valid_i(maint_i_req_valid),
    .inv_req_ready_o(maint_i_req_ready),
    .inv_req_all_i(maint_i_req_op == VSP_MEM_CACHE_MAINT_INVALIDATE_ALL),
    .inv_req_paddr_i(maint_i_req_paddr),
    .inv_rsp_valid_o(maint_i_rsp_valid),
    .inv_rsp_ready_i(maint_i_rsp_ready),
    .inv_rsp_status_o(maint_i_rsp_status),
    .ic_mem_cmd_valid_o(ic_mem_cmd_valid),
    .ic_mem_cmd_ready_i(ic_mem_cmd_ready),
    .ic_mem_cmd_id_o(ic_mem_cmd_id),
    .ic_mem_cmd_op_o(ic_mem_cmd_op),
    .ic_mem_cmd_paddr_o(ic_mem_cmd_paddr),
    .ic_mem_cmd_beats_o(ic_mem_cmd_beats),
    .ic_mem_w_valid_o(ic_mem_w_valid),
    .ic_mem_w_ready_i(ic_mem_w_ready),
    .ic_mem_w_id_o(ic_mem_w_id),
    .ic_mem_w_data_o(ic_mem_w_data),
    .ic_mem_wstrb_o(ic_mem_wstrb),
    .ic_mem_w_last_o(ic_mem_w_last),
    .ic_mem_r_valid_i(ic_mem_r_valid),
    .ic_mem_r_ready_o(ic_mem_r_ready),
    .ic_mem_r_id_i(ic_mem_r_id),
    .ic_mem_r_data_i(ic_mem_r_data),
    .ic_mem_r_last_i(ic_mem_r_last),
    .ic_mem_r_status_i(ic_mem_r_status),
    .ic_mem_r_fault_paddr_i(ic_mem_r_fault_paddr),
    .ic_mem_b_valid_i(ic_mem_b_valid),
    .ic_mem_b_ready_o(ic_mem_b_ready),
    .ic_mem_b_id_i(ic_mem_b_id),
    .ic_mem_b_status_i(ic_mem_b_status),
    .ic_mem_b_fault_paddr_i(ic_mem_b_fault_paddr),
    .ready_o(ifetch_path_ready_o),
    .quiescent_o(ifetch_path_quiescent),
    .busy_o(unused_ifetch_busy),
    .bridge_idle_o(ifetch_bridge_idle),
    .bridge_busy_o(ifetch_bridge_busy),
    .ifetch_init_done_o(ifetch_adapter_init_done),
    .ifetch_idle_o(ifetch_adapter_idle),
    .icache_init_busy_o(icache_init_busy),
    .icache_init_done_o(icache_init_done_o),
    .icache_adapter_idle_o(icache_adapter_idle),
    .region_router_idle_o(i_region_router_idle),
    .region_config_overlap_o(i_region_config_overlap_o),
    .perf_icache_read_hit_o,
    .perf_icache_read_miss_o,
    .protocol_error_clear_i,
    .bridge_protocol_error_o(ifetch_bridge_protocol_error),
    .ifetch_protocol_error_o(ifetch_adapter_protocol_error),
    .icache_adapter_protocol_error_o(icache_adapter_protocol_error),
    .protocol_error_o(ifetch_path_protocol_error_o)
  );

  /* verilator lint_off PINCONNECTEMPTY */
  vsp_dmem_cached_fabric_wrapper #(
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
    .REGION_IDEMPOTENT(REGION_IDEMPOTENT),
    .LOWER_DATA_W(LOWER_DATA_W),
    .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),
    .DCACHE_SET_COUNT(DCACHE_SET_COUNT),
    .DCACHE_WAY_COUNT(DCACHE_WAY_COUNT),
    .DCACHE_RAM_RD_LATENCY(DCACHE_RAM_RD_LATENCY),
    .CACHE_REQ_ID_W(CACHE_REQ_ID_W),
    .CACHE_USER_W(CACHE_USER_W),
    .CACHE_MEM_BEATS_W(CACHE_MEM_BEATS_W),
    .LOCAL_BASE_ADDR(LOCAL_BASE_ADDR),
    .LOCAL_DEPTH_WORDS(LOCAL_DEPTH_WORDS)
  ) u_dmem (
    .clk_i,
    .rst_ni,
    .dmem_req_valid_i(gated_dmem_req_valid),
    .dmem_req_ready_o(raw_dmem_req_ready),
    .dmem_req_op_i(program_dmem_req_op),
    .dmem_req_eaddr_i(program_dmem_req_eaddr),
    .dmem_req_addr_space_i(program_dmem_req_addr_space),
    .dmem_req_addr_context_i(program_dmem_req_addr_context),
    .dmem_req_wdata_i(program_dmem_req_wdata),
    .dmem_req_wstrb_i(program_dmem_req_wstrb),
    .dmem_rsp_valid_o(program_dmem_rsp_valid),
    .dmem_rsp_ready_i(program_dmem_rsp_ready),
    .dmem_rsp_rdata_o(program_dmem_rsp_rdata),
    .dmem_rsp_fault_cause_o(program_dmem_rsp_fault),
    .i_tr_req_valid_i(i_tr_req_valid),
    .i_tr_req_ready_o(i_tr_req_ready),
    .i_tr_req_vaddr_i(i_tr_req_vaddr),
    .i_tr_req_addr_context_i(i_tr_req_context),
    .i_tr_req_access_i(i_tr_req_access),
    .i_tr_rsp_valid_o(i_tr_rsp_valid),
    .i_tr_rsp_ready_i(i_tr_rsp_ready),
    .i_tr_rsp_paddr_o(i_tr_rsp_paddr),
    .i_tr_rsp_fault_o(i_tr_rsp_fault),
    .i_tr_rsp_fault_vaddr_o(i_tr_rsp_fault_vaddr),
    .mmu_cfg_valid_i(raw_cfg_valid),
    .mmu_cfg_ready_o(raw_cfg_ready),
    .mmu_cfg_write_i(cfg_write_q),
    .mmu_cfg_context_i(cfg_context_q),
    .mmu_cfg_field_i(cfg_field_q),
    .mmu_cfg_wdata_i(cfg_wdata_q),
    .mmu_cfg_rsp_valid_o(raw_cfg_rsp_valid),
    .mmu_cfg_rsp_ready_i(raw_cfg_rsp_ready),
    .mmu_cfg_rsp_rdata_o(raw_cfg_rsp_rdata),
    .mmu_cfg_rsp_status_o(raw_cfg_rsp_status),
    .tlb_inv_req_valid_i(maint_tlb_req_valid),
    .tlb_inv_req_ready_o(maint_tlb_req_ready),
    .tlb_inv_req_scope_i(maint_tlb_req_scope),
    .tlb_inv_req_asid_i(maint_tlb_req_asid),
    .tlb_inv_req_vaddr_i(maint_tlb_req_vaddr),
    .tlb_inv_rsp_valid_o(maint_tlb_rsp_valid),
    .tlb_inv_rsp_ready_i(maint_tlb_rsp_ready),
    .tlb_inv_rsp_status_o(maint_tlb_rsp_status),
    .dcache_maint_req_valid_i(maint_d_req_valid),
    .dcache_maint_req_ready_o(maint_d_req_ready),
    .dcache_maint_req_op_i(maint_d_req_op),
    .dcache_maint_req_paddr_i(maint_d_req_paddr),
    .dcache_maint_rsp_valid_o(maint_d_rsp_valid),
    .dcache_maint_rsp_ready_i(maint_d_rsp_ready),
    .dcache_maint_rsp_status_o(maint_d_rsp_status),
    .barrier_valid_i(1'b0),
    .barrier_ready_o(),
    .barrier_op_i('0),
    .barrier_eaddr_i('0),
    .barrier_context_i('0),
    .barrier_rsp_valid_o(),
    .barrier_rsp_ready_i(1'b1),
    .barrier_rsp_status_o(),
    .policy_maint_req_valid_o(),
    .policy_maint_req_ready_i(1'b0),
    .policy_maint_req_op_o(),
    .policy_maint_req_eaddr_o(),
    .policy_maint_req_context_o(),
    .policy_maint_rsp_valid_i(1'b0),
    .policy_maint_rsp_ready_o(),
    .policy_maint_rsp_fault_i(VSP_MEM_FAULT_NONE),
    .ic_mem_cmd_valid_i(ic_mem_cmd_valid),
    .ic_mem_cmd_ready_o(ic_mem_cmd_ready),
    .ic_mem_cmd_id_i(ic_mem_cmd_id),
    .ic_mem_cmd_op_i(ic_mem_cmd_op),
    .ic_mem_cmd_paddr_i(ic_mem_cmd_paddr),
    .ic_mem_cmd_beats_i(ic_mem_cmd_beats),
    .ic_mem_w_valid_i(ic_mem_w_valid),
    .ic_mem_w_ready_o(ic_mem_w_ready),
    .ic_mem_w_id_i(ic_mem_w_id),
    .ic_mem_w_data_i(ic_mem_w_data),
    .ic_mem_wstrb_i(ic_mem_wstrb),
    .ic_mem_w_last_i(ic_mem_w_last),
    .ic_mem_r_valid_o(ic_mem_r_valid),
    .ic_mem_r_ready_i(ic_mem_r_ready),
    .ic_mem_r_id_o(ic_mem_r_id),
    .ic_mem_r_data_o(ic_mem_r_data),
    .ic_mem_r_last_o(ic_mem_r_last),
    .ic_mem_r_status_o(ic_mem_r_status),
    .ic_mem_r_fault_paddr_o(ic_mem_r_fault_paddr),
    .ic_mem_b_valid_o(ic_mem_b_valid),
    .ic_mem_b_ready_i(ic_mem_b_ready),
    .ic_mem_b_id_o(ic_mem_b_id),
    .ic_mem_b_status_o(ic_mem_b_status),
    .ic_mem_b_fault_paddr_o(ic_mem_b_fault_paddr),
    .fabric_drain_req_i(fabric_drain_req),
    .fabric_drain_done_o(fabric_drain_done),
    .lower_req_valid_o,
    .lower_req_ready_i,
    .lower_req_write_o,
    .lower_req_paddr_o,
    .lower_req_wdata_o,
    .lower_req_wstrb_o,
    .lower_rsp_valid_i,
    .lower_rsp_ready_o,
    .lower_rsp_rdata_i,
    .lower_rsp_status_i,
    .lower_quiescent_i,
    .lsu_idle_o(lsu_idle),
    .lsu_busy_o(),
    .space_router_idle_o(),
    .region_router_idle_o(),
    .region_config_overlap_o(d_region_config_overlap_o),
    .region_diag_rsp_valid_o(),
    .region_diag_match_valid_o(),
    .region_diag_match_index_o(),
    .region_diag_overlap_o(),
    .region_diag_endpoint_valid_o(),
    .region_diag_endpoint_o(),
    .region_diag_fault_o(),
    .mmu_init_done_o,
    .mmu_quiescent_o(mmu_quiescent),
    .mmu_busy_o(unused_mmu_busy),
    .i_tlb_epoch_o(),
    .d_tlb_epoch_o(),
    .i_tlb_epoch_exhausted_o(),
    .d_tlb_epoch_exhausted_o(),
    .ptw_pte_fault_paddr_valid_o(),
    .ptw_pte_fault_paddr_o(),
    .dcache_init_busy_o(),
    .dcache_init_done_o,
    .dcache_idle_o(dcache_idle),
    .local_idle_o(),
    .uncached_device_idle_o(),
    .fabric_idle_o(fabric_idle),
    .fabric_busy_o(unused_fabric_busy),
    .fabric_quarantine_o,
    .fabric_owner_valid_o(),
    .fabric_owner_o(),
    .dmem_path_ready_o,
    .dmem_path_quiescent_o(dmem_path_quiescent),
    .dmem_path_busy_o(unused_dmem_busy),
    .perf_dcache_read_hit_o,
    .perf_dcache_read_miss_o,
    .perf_dcache_write_hit_o,
    .perf_dcache_write_miss_o,
    .protocol_error_clear_i,
    .lsu_protocol_error_o(),
    .mmu_protocol_error_o(),
    .dcache_protocol_error_o(),
    .endpoint_merge_protocol_error_o(),
    .fabric_protocol_error_o(),
    .protocol_error_o(dmem_path_protocol_error_o)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  vsp_memory_maintenance_controller #(
    .EADDR_W(32),
    .PADDR_W(PADDR_W),
    .CONTEXT_W(8),
    .ASID_W(ASID_W)
  ) u_maintenance (
    .clk_i,
    .rst_ni,
    .cmd_valid_i(maint_raw_cmd_valid),
    .cmd_ready_o(maint_raw_cmd_ready),
    .cmd_op_i(maint_cmd_op_i),
    .cmd_eaddr_i(maint_cmd_eaddr_i),
    .cmd_paddr_i(maint_cmd_paddr_i),
    .cmd_addr_context_i(maint_cmd_addr_context_i),
    .cmd_asid_i(maint_cmd_asid_i),
    .cpl_valid_o(maint_cpl_valid_o),
    .cpl_ready_i(maint_cpl_ready_i),
    .cpl_status_o(maint_cpl_status_o),
    .cpl_fault_o(maint_cpl_fault_o),
    .i_quiesce_req_o(maint_i_quiesce),
    .d_quiesce_req_o(maint_d_quiesce),
    .lsu_idle_i(lsu_idle),
    .ifetch_idle_i(ifetch_bridge_idle && ifetch_adapter_idle),
    .mmu_quiescent_i(mmu_quiescent),
    // mmu_quiescent includes both frontends, both TLBs and the shared PTW.
    .ptw_idle_i(mmu_quiescent),
    .dcache_idle_i(dcache_idle),
    .icache_idle_i(icache_adapter_idle),
    .fabric_drain_req_o(fabric_drain_req),
    .fabric_drain_done_i(fabric_drain_done),
    .downstream_quiescent_i(raw_paths_quiescent && lower_quiescent_i),
    .d_maint_req_valid_o(maint_d_req_valid),
    .d_maint_req_ready_i(maint_d_req_ready),
    .d_maint_req_op_o(maint_d_req_op),
    .d_maint_req_paddr_o(maint_d_req_paddr),
    .d_maint_rsp_valid_i(maint_d_rsp_valid),
    .d_maint_rsp_ready_o(maint_d_rsp_ready),
    .d_maint_rsp_status_i(maint_d_rsp_status),
    .i_maint_req_valid_o(maint_i_req_valid),
    .i_maint_req_ready_i(maint_i_req_ready),
    .i_maint_req_op_o(maint_i_req_op),
    .i_maint_req_paddr_o(maint_i_req_paddr),
    .i_maint_rsp_valid_i(maint_i_rsp_valid),
    .i_maint_rsp_ready_o(maint_i_rsp_ready),
    .i_maint_rsp_status_i(maint_i_rsp_status),
    .tlb_inv_req_valid_o(maint_tlb_req_valid),
    .tlb_inv_req_ready_i(maint_tlb_req_ready),
    .tlb_inv_req_scope_o(maint_tlb_req_scope),
    .tlb_inv_req_asid_o(maint_tlb_req_asid),
    .tlb_inv_req_vaddr_o(maint_tlb_req_vaddr),
    .tlb_inv_rsp_valid_i(maint_tlb_rsp_valid),
    .tlb_inv_rsp_ready_o(maint_tlb_rsp_ready),
    .tlb_inv_rsp_status_i(maint_tlb_rsp_status),
    .busy_o(maint_busy_o),
    .quiescent_o(maint_quiescent_o),
    .current_step_o(maint_current_step_o),
    .protocol_error_o(maint_protocol_error_o),
    .protocol_error_clear_i
  );

  /* verilator lint_off UNUSED */
  wire unused_observation = &{1'b0, unused_store_write_ready,
      ifetch_addr_context_q, ifetch_bridge_busy, ifetch_adapter_init_done,
      icache_init_busy, i_region_router_idle, ifetch_bridge_protocol_error,
      ifetch_adapter_protocol_error, icache_adapter_protocol_error,
      fabric_idle, unused_dmem_busy, unused_mmu_busy, unused_ifetch_busy,
      unused_fabric_busy};
  /* verilator lint_on UNUSED */

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk_i) begin : p_integration_assertions
    if (rst_ni) begin
      if (maint_i_req_valid)
        assert ((maint_i_req_op == VSP_MEM_CACHE_MAINT_INVALIDATE_LINE) ||
                (maint_i_req_op == VSP_MEM_CACHE_MAINT_INVALIDATE_ALL))
          else $error("vsp_uword_memory_system_wrapper: unsupported I-cache maintenance op");
      assert (!(program_dmem_req_ready && maint_d_quiesce))
        else $error("vsp_uword_memory_system_wrapper: D request admitted while quiesced");
    end
  end
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule

`default_nettype wire
