// SPDX-License-Identifier: MIT
`default_nettype none

// Passive 32-bit host-register target for the single-context memory system.
// See docs/integration/host-mmio.md for the software-visible ABI.
module vsp_host_control #(
  parameter integer GROUP_COUNT = 4,
  parameter integer PADDR_W = 40,
  parameter integer TAG_W = 8,
  parameter integer ASID_W = 9,
  parameter integer DECODE_ERROR_W =
      vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W,
  parameter integer SPAN_BYTES_W = $clog2((GROUP_COUNT * 4) + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic mmio_req_valid_i,
  output logic mmio_req_ready_o,
  input  logic mmio_req_write_i,
  input  logic [11:0] mmio_req_addr_i,
  input  logic [31:0] mmio_req_wdata_i,
  input  logic [3:0] mmio_req_wstrb_i,
  output logic mmio_rsp_valid_o,
  input  logic mmio_rsp_ready_i,
  output logic [31:0] mmio_rsp_rdata_o,
  output logic mmio_rsp_error_o,
  output logic irq_o,

  output logic start_valid_o,
  input  logic start_ready_i,
  output logic [31:0] start_pc_o,
  output logic [31:0] end_pc_o,
  output logic [GROUP_COUNT-1:0] start_group_mask_o,
  output logic [TAG_W-1:0] start_tag_seed_o,
  output logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
      start_ifetch_addr_space_o,
  output logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
      start_ifetch_addr_context_o,
  input  logic [31:0] fetch_pc_i,
  input  logic program_active_i,
  input  logic program_done_i,
  input  logic program_failed_i,
  input  logic program_error_i,
  input  logic [31:0] program_terminal_pc_i,
  input  logic system_ready_i,
  input  logic system_quiescent_i,
  input  logic system_busy_i,

  input  logic ifetch_fault_valid_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0]
      ifetch_fault_cause_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_EADDR_W-1:0]
      ifetch_fault_eaddr_i,
  input  logic [PADDR_W-1:0] ifetch_fault_paddr_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
      ifetch_fault_addr_space_i,
  input  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
      ifetch_fault_addr_context_i,

  input  logic action_cpl_valid_i,
  output logic action_cpl_ready_o,
  input  logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
      action_cpl_class_i,
  input  logic [TAG_W-1:0] action_cpl_tag_i,
  input  logic [vsp_action_pkg::VSP_ACTION_CPL_STATUS_W-1:0]
      action_cpl_status_i,
  input  logic [DECODE_ERROR_W-1:0] action_cpl_decode_error_i,
  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0] action_cpl_memory_op_i,
  input  logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
      action_cpl_memory_status_i,
  input  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
      action_cpl_memory_fault_cause_i,
  input  logic [31:0] action_cpl_memory_fault_eaddr_i,
  input  logic [GROUP_COUNT-1:0] action_cpl_memory_requested_group_mask_i,
  input  logic [GROUP_COUNT-1:0] action_cpl_memory_completed_group_mask_i,
  input  logic [GROUP_COUNT-1:0] action_cpl_memory_failed_group_mask_i,
  input  logic [SPAN_BYTES_W-1:0] action_cpl_memory_bytes_committed_i,
  input  logic action_cpl_memory_partial_i,
  output logic exec_result_ready_o,

  output logic mmu_cfg_valid_o,
  input  logic mmu_cfg_ready_i,
  output logic mmu_cfg_write_o,
  output logic [vsp_mmu_pkg::VSP_MMU_CONTEXT_W-1:0] mmu_cfg_context_o,
  output logic [vsp_mmu_pkg::VSP_MMU_CFG_FIELD_W-1:0] mmu_cfg_field_o,
  output logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0] mmu_cfg_wdata_o,
  input  logic mmu_cfg_rsp_valid_i,
  output logic mmu_cfg_rsp_ready_o,
  input  logic [vsp_mmu_pkg::VSP_MMU_CFG_WDATA_W-1:0] mmu_cfg_rsp_rdata_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_STATUS_W-1:0]
      mmu_cfg_rsp_status_i,

  output logic maint_cmd_valid_o,
  input  logic maint_cmd_ready_i,
  output logic [vsp_mem_common_pkg::VSP_MEM_MAINT_OP_W-1:0] maint_cmd_op_o,
  output logic [31:0] maint_cmd_eaddr_o,
  output logic [PADDR_W-1:0] maint_cmd_paddr_o,
  output logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
      maint_cmd_addr_context_o,
  output logic [ASID_W-1:0] maint_cmd_asid_o,
  input  logic maint_cpl_valid_i,
  output logic maint_cpl_ready_o,
  input  logic [vsp_mem_common_pkg::VSP_MEM_MAINT_CPL_STATUS_W-1:0]
      maint_cpl_status_i,
  input  logic [vsp_mem_common_pkg::VSP_MEM_FAULT_W-1:0] maint_cpl_fault_i,
  output logic protocol_error_clear_o
);
  import vsp_host_mmio_pkg::*;

  typedef enum logic [2:0] {
    HOST_IDLE, HOST_START, HOST_RUN, HOST_DRAIN,
    HOST_MMU_REQ, HOST_MMU_RSP, HOST_MAINT_REQ, HOST_MAINT_RSP
  } host_phase_e;
  host_phase_e phase_q;

  logic [31:0] start_pc_q, end_pc_q, group_mask_q, fetch_context_q, tag_seed_q;
  logic [31:0] mmu_context_q, mmu_field_q, mmu_wdata_q, mmu_rdata_q;
  logic [31:0] maint_op_q, maint_eaddr_q, maint_paddr_lo_q, maint_paddr_hi_q;
  logic [31:0] maint_context_q, maint_asid_q;
  logic [2:0] irq_enable_q, irq_pending_q;
  logic [31:0] mgmt_status_q;

  // Working retire records are not software visible until publication. The
  // frozen record is a different register bank, so later management work or
  // live core diagnostics cannot overwrite an unread job result.
  typedef struct packed {
    logic [31:0] action_count;
    logic [31:0] first_error_info;
    logic [31:0] first_error_tag;
    logic [31:0] mem_fault_info;
    logic [31:0] mem_fault_eaddr;
    logic [31:0] mem_masks;
    logic [31:0] mem_failed_mask;
    logic [31:0] mem_bytes;
  } retire_record_t;
  typedef struct packed {
    logic [31:0] status;
    logic [31:0] terminal_pc;
    retire_record_t retired;
    logic [31:0] ifetch_info;
    logic [31:0] ifetch_eaddr;
    logic [31:0] ifetch_paddr_lo;
    logic [31:0] ifetch_paddr_hi;
  } job_result_t;
  retire_record_t retired_q, retired_next;
  job_result_t result_q, publication;
  logic terminal_done_q, terminal_failed_q;
  logic [31:0] terminal_pc_q;

  logic req_fire, write_fire;
  logic req_mapped, req_writable, req_error, command_allowed;
  logic [31:0] req_rdata;
  logic host_idle, management_busy, job_owned, new_work_allowed;
  logic start_config_valid, mmu_config_valid, maint_config_valid;
  logic job_publish, mmu_publish, maint_publish;
  logic [2:0] irq_events, irq_clear;

  initial begin : p_profile_guards
    if ((GROUP_COUNT < 1) || (GROUP_COUNT > 16))
      $fatal(1, "vsp_host_control: GROUP_COUNT must be 1..16");
    if ((PADDR_W != 32) && (PADDR_W != 40))
      $fatal(1, "vsp_host_control: PADDR_W must be 32 or 40");
    if ((TAG_W < 1) || (TAG_W > 8) || (ASID_W < 1) || (ASID_W > 9))
      $fatal(1, "vsp_host_control: TAG_W/ASID_W exceed host ABI widths");
    if ((DECODE_ERROR_W < 1) || (DECODE_ERROR_W > 8) ||
        (SPAN_BYTES_W < 1) || (SPAN_BYTES_W > 32))
      $fatal(1, "vsp_host_control: completion widths exceed host ABI fields");
  end

  function automatic logic [31:0] merge_bytes(
    input logic [31:0] old_value,
    input logic [31:0] new_value,
    input logic [3:0] strobes
  );
    logic [31:0] merged;
    begin
      merged = old_value;
      for (integer lane = 0; lane < 4; lane = lane + 1)
        if (strobes[lane]) merged[lane*8 +: 8] = new_value[lane*8 +: 8];
      merge_bytes = merged;
    end
  endfunction

  assign host_idle = phase_q == HOST_IDLE;
  assign management_busy = (phase_q == HOST_MMU_REQ) ||
      (phase_q == HOST_MMU_RSP) || (phase_q == HOST_MAINT_REQ) ||
      (phase_q == HOST_MAINT_RSP);
  assign job_owned = (phase_q == HOST_START) || (phase_q == HOST_RUN) ||
      (phase_q == HOST_DRAIN);
  assign new_work_allowed = host_idle && system_ready_i && system_quiescent_i;

  assign start_config_valid = (start_pc_q[1:0] == 2'b00) &&
      (end_pc_q[1:0] == 2'b00) && (start_pc_q < end_pc_q) &&
      (group_mask_q != 32'b0) && ((group_mask_q >> GROUP_COUNT) == 32'b0) &&
      ((tag_seed_q >> TAG_W) == 32'b0) &&
      ((fetch_context_q & 32'hffff00fc) == 32'b0) &&
      ((fetch_context_q[1:0] == vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_PHYSICAL) ||
       (fetch_context_q[1:0] == vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_TRANSLATED));
  assign mmu_config_valid = (mmu_context_q[31:8] == 24'b0) &&
      (mmu_field_q <= 32'd9);
  assign maint_config_valid = (maint_op_q <= 32'd10) &&
      (maint_context_q[31:8] == 24'b0) &&
      ((maint_asid_q >> ASID_W) == 32'b0) &&
      ((maint_paddr_hi_q >> (PADDR_W - 32)) == 32'b0);

  // A request owns its payload registers from COMMAND acceptance through the
  // downstream handshake. Mutable software staging registers never drive a
  // pending downstream transaction.
  assign start_valid_o = rst_ni && (phase_q == HOST_START);
  assign mmu_cfg_valid_o = rst_ni && (phase_q == HOST_MMU_REQ);
  assign mmu_cfg_rsp_ready_o = rst_ni && (phase_q == HOST_MMU_RSP);
  assign maint_cmd_valid_o = rst_ni && (phase_q == HOST_MAINT_REQ);
  assign maint_cpl_ready_o = rst_ni && (phase_q == HOST_MAINT_RSP);
  assign action_cpl_ready_o = rst_ni;
  assign exec_result_ready_o = rst_ni;

  // Deliberately no same-cycle response replacement: at most one accepted
  // MMIO transaction is outstanding, with read data snapshotted at admission.
  assign mmio_req_ready_o = rst_ni && !mmio_rsp_valid_o;
  assign req_fire = mmio_req_valid_i && mmio_req_ready_o;
  assign write_fire = req_fire && mmio_req_write_i && !req_error;
  assign irq_o = rst_ni && (|(irq_pending_q & irq_enable_q));

  always_comb begin : p_command_validation
    command_allowed = 1'b0;
    case (mmio_req_wdata_i)
      VSP_HOST_CMD_START:
        command_allowed = new_work_allowed && !result_q.status[0] &&
                          start_config_valid;
      VSP_HOST_CMD_ACK_RESULT, VSP_HOST_CMD_CLEAR_PROTOCOL:
        command_allowed = host_idle;
      VSP_HOST_CMD_MMU_READ, VSP_HOST_CMD_MMU_WRITE:
        command_allowed = new_work_allowed && mmu_config_valid;
      VSP_HOST_CMD_MAINTENANCE:
        command_allowed = new_work_allowed && maint_config_valid;
      default: command_allowed = 1'b0;
    endcase
  end

  always_comb begin : p_register_read
    req_mapped = 1'b1;
    req_writable = 1'b0;
    req_rdata = 32'b0;
    case (mmio_req_addr_i)
      VSP_HOST_REG_ID: req_rdata = VSP_HOST_ID;
      VSP_HOST_REG_VERSION: req_rdata = VSP_HOST_VERSION;
      VSP_HOST_REG_STATUS: begin
        req_rdata[0] = system_ready_i;
        req_rdata[1] = system_quiescent_i;
        req_rdata[2] = !host_idle || system_busy_i;
        req_rdata[3] = program_active_i;
        req_rdata[4] = result_q.status[0];
        req_rdata[5] = phase_q == HOST_START;
        req_rdata[6] = management_busy;
      end
      VSP_HOST_REG_COMMAND: req_writable = 1'b1;
      VSP_HOST_REG_START_PC: begin req_rdata = start_pc_q; req_writable = 1'b1; end
      VSP_HOST_REG_END_PC: begin req_rdata = end_pc_q; req_writable = 1'b1; end
      VSP_HOST_REG_GROUP_MASK: begin req_rdata = group_mask_q; req_writable = 1'b1; end
      VSP_HOST_REG_FETCH_CONTEXT: begin req_rdata = fetch_context_q; req_writable = 1'b1; end
      VSP_HOST_REG_TAG_SEED: begin req_rdata = tag_seed_q; req_writable = 1'b1; end
      VSP_HOST_REG_IRQ_ENABLE: begin req_rdata = {29'b0, irq_enable_q}; req_writable = 1'b1; end
      VSP_HOST_REG_IRQ_PENDING: begin req_rdata = {29'b0, irq_pending_q}; req_writable = 1'b1; end
      VSP_HOST_REG_FETCH_PC: req_rdata = fetch_pc_i;
      VSP_HOST_REG_RESULT_STATUS: req_rdata = result_q.status;
      VSP_HOST_REG_TERMINAL_PC: req_rdata = result_q.terminal_pc;
      VSP_HOST_REG_ACTION_COUNT: req_rdata = result_q.retired.action_count;
      VSP_HOST_REG_FIRST_ERROR_INFO: req_rdata = result_q.retired.first_error_info;
      VSP_HOST_REG_FIRST_ERROR_TAG: req_rdata = result_q.retired.first_error_tag;
      VSP_HOST_REG_MEM_FAULT_INFO: req_rdata = result_q.retired.mem_fault_info;
      VSP_HOST_REG_MEM_FAULT_EADDR: req_rdata = result_q.retired.mem_fault_eaddr;
      VSP_HOST_REG_MEM_MASKS: req_rdata = result_q.retired.mem_masks;
      VSP_HOST_REG_MEM_FAILED_MASK: req_rdata = result_q.retired.mem_failed_mask;
      VSP_HOST_REG_MEM_BYTES: req_rdata = result_q.retired.mem_bytes;
      VSP_HOST_REG_IFETCH_INFO: req_rdata = result_q.ifetch_info;
      VSP_HOST_REG_IFETCH_EADDR: req_rdata = result_q.ifetch_eaddr;
      VSP_HOST_REG_IFETCH_PADDR_LO: req_rdata = result_q.ifetch_paddr_lo;
      VSP_HOST_REG_IFETCH_PADDR_HI: req_rdata = result_q.ifetch_paddr_hi;
      VSP_HOST_REG_MMU_CONTEXT: begin req_rdata = mmu_context_q; req_writable = 1'b1; end
      VSP_HOST_REG_MMU_FIELD: begin req_rdata = mmu_field_q; req_writable = 1'b1; end
      VSP_HOST_REG_MMU_WDATA: begin req_rdata = mmu_wdata_q; req_writable = 1'b1; end
      VSP_HOST_REG_MMU_RDATA: req_rdata = mmu_rdata_q;
      VSP_HOST_REG_MGMT_STATUS: req_rdata = mgmt_status_q;
      VSP_HOST_REG_MAINT_OP: begin req_rdata = maint_op_q; req_writable = 1'b1; end
      VSP_HOST_REG_MAINT_EADDR: begin req_rdata = maint_eaddr_q; req_writable = 1'b1; end
      VSP_HOST_REG_MAINT_PADDR_LO: begin req_rdata = maint_paddr_lo_q; req_writable = 1'b1; end
      VSP_HOST_REG_MAINT_PADDR_HI: begin req_rdata = maint_paddr_hi_q; req_writable = 1'b1; end
      VSP_HOST_REG_MAINT_CONTEXT: begin req_rdata = maint_context_q; req_writable = 1'b1; end
      VSP_HOST_REG_MAINT_ASID: begin req_rdata = maint_asid_q; req_writable = 1'b1; end
      default: req_mapped = 1'b0;
    endcase
    req_error = (mmio_req_addr_i[1:0] != 2'b00) || !req_mapped ||
        (mmio_req_write_i && !req_writable) ||
        (mmio_req_write_i && (mmio_req_addr_i == VSP_HOST_REG_COMMAND) &&
         ((mmio_req_wstrb_i != 4'b1111) || !command_allowed));
    if (req_error || mmio_req_write_i) req_rdata = 32'b0;
  end

  always_comb begin : p_retirement
    retired_next = retired_q;
    if (job_owned && action_cpl_valid_i && action_cpl_ready_o) begin
      retired_next.action_count = retired_q.action_count + 32'd1;
      if (!retired_q.first_error_info[0] &&
          ((action_cpl_status_i != vsp_action_pkg::VSP_ACTION_CPL_OK) ||
           (action_cpl_decode_error_i != '0))) begin
        retired_next.first_error_info = {
            8'(action_cpl_decode_error_i), 8'(action_cpl_status_i),
            8'(action_cpl_class_i), 8'h01};
        retired_next.first_error_tag = 32'(action_cpl_tag_i);
      end
      if (!retired_q.mem_fault_info[0] &&
          (action_cpl_class_i == vsp_action_pkg::VSP_ACTION_CLASS_MEMORY) &&
          (action_cpl_memory_status_i != vsp_pkg::VSP_MEM_CPL_OK)) begin
        retired_next.mem_fault_info = {
            8'(action_cpl_memory_fault_cause_i), 8'(action_cpl_memory_status_i),
            8'(action_cpl_memory_op_i), 6'b0, action_cpl_memory_partial_i, 1'b1};
        retired_next.mem_fault_eaddr = action_cpl_memory_fault_eaddr_i;
        retired_next.mem_masks = {
            16'(action_cpl_memory_completed_group_mask_i),
            16'(action_cpl_memory_requested_group_mask_i)};
        retired_next.mem_failed_mask = 32'(action_cpl_memory_failed_group_mask_i);
        retired_next.mem_bytes = 32'(action_cpl_memory_bytes_committed_i);
      end
    end
  end

  assign job_publish = rst_ni && (phase_q == HOST_DRAIN) && system_quiescent_i;
  assign mmu_publish = mmu_cfg_rsp_valid_i && mmu_cfg_rsp_ready_o;
  assign maint_publish = maint_cpl_valid_i && maint_cpl_ready_o;
  always_comb begin : p_publication
    publication = '0;
    publication.status[0] = 1'b1;
    publication.status[1] = terminal_done_q;
    publication.status[2] = terminal_failed_q;
    publication.status[3] = program_error_i || terminal_failed_q ||
        retired_next.first_error_info[0] || retired_next.mem_fault_info[0] ||
        ifetch_fault_valid_i;
    publication.terminal_pc = terminal_pc_q;
    publication.retired = retired_next;
    // These diagnostics describe the final fetch path. Do not accumulate
    // program_error or IFetch valid during RUN: a committed redirect can
    // legitimately clear a speculative transport fault before termination.
    if (ifetch_fault_valid_i) begin
      publication.ifetch_info[0] = 1'b1;
      publication.ifetch_info[6:4] = ifetch_fault_cause_i;
      publication.ifetch_info[9:8] = ifetch_fault_addr_space_i;
      publication.ifetch_info[23:16] = ifetch_fault_addr_context_i;
      publication.ifetch_eaddr = ifetch_fault_eaddr_i;
      publication.ifetch_paddr_lo = 32'(ifetch_fault_paddr_i);
      publication.ifetch_paddr_hi = 32'(64'(ifetch_fault_paddr_i) >> 32);
    end
    irq_events = 3'b0;
    if (job_publish)
      irq_events = VSP_HOST_IRQ_COMPLETE |
          (publication.status[3] ? VSP_HOST_IRQ_ERROR : 3'b0);
    if (mmu_publish || maint_publish)
      irq_events = irq_events | VSP_HOST_IRQ_MANAGEMENT;
    irq_clear = 3'b0;
    if (write_fire && (mmio_req_addr_i == VSP_HOST_REG_IRQ_PENDING) &&
        mmio_req_wstrb_i[0])
      irq_clear = mmio_req_wdata_i[2:0];
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state
    if (!rst_ni) begin
      phase_q <= HOST_IDLE;
      start_pc_q <= '0;
      end_pc_q <= '0;
      group_mask_q <= (32'h1 << GROUP_COUNT) - 32'd1;
      fetch_context_q <= 32'h00000001;
      tag_seed_q <= '0;
      mmu_context_q <= '0;
      mmu_field_q <= '0;
      mmu_wdata_q <= '0;
      mmu_rdata_q <= '0;
      maint_op_q <= '0;
      maint_eaddr_q <= '0;
      maint_paddr_lo_q <= '0;
      maint_paddr_hi_q <= '0;
      maint_context_q <= '0;
      maint_asid_q <= '0;
      irq_enable_q <= '0;
      irq_pending_q <= '0;
      mgmt_status_q <= '0;
      retired_q <= '0;
      result_q <= '0;
      terminal_done_q <= 1'b0;
      terminal_failed_q <= 1'b0;
      terminal_pc_q <= '0;
      start_pc_o <= '0;
      end_pc_o <= '0;
      start_group_mask_o <= '0;
      start_tag_seed_o <= '0;
      start_ifetch_addr_space_o <= '0;
      start_ifetch_addr_context_o <= '0;
      mmu_cfg_write_o <= 1'b0;
      mmu_cfg_context_o <= '0;
      mmu_cfg_field_o <= '0;
      mmu_cfg_wdata_o <= '0;
      maint_cmd_op_o <= '0;
      maint_cmd_eaddr_o <= '0;
      maint_cmd_paddr_o <= '0;
      maint_cmd_addr_context_o <= '0;
      maint_cmd_asid_o <= '0;
      protocol_error_clear_o <= 1'b0;
      mmio_rsp_valid_o <= 1'b0;
      mmio_rsp_rdata_o <= '0;
      mmio_rsp_error_o <= 1'b0;
    end else begin
      protocol_error_clear_o <= 1'b0;
      retired_q <= retired_next;
      // Events dominate simultaneous software W1C; enables only affect irq_o.
      irq_pending_q <= (irq_pending_q & ~irq_clear) | irq_events;

      if (mmio_rsp_valid_o && mmio_rsp_ready_i)
        mmio_rsp_valid_o <= 1'b0;
      if (req_fire) begin
        mmio_rsp_valid_o <= 1'b1;
        mmio_rsp_rdata_o <= req_rdata;
        mmio_rsp_error_o <= req_error;
      end

      case (phase_q)
        HOST_START: if (start_valid_o && start_ready_i) phase_q <= HOST_RUN;
        HOST_RUN: begin
          if (program_done_i || program_failed_i) begin
            terminal_done_q <= program_done_i;
            terminal_failed_q <= program_failed_i;
            terminal_pc_q <= program_terminal_pc_i;
            phase_q <= HOST_DRAIN;
          end
        end
        HOST_DRAIN: begin
          if (job_publish) begin
            result_q <= publication;
            phase_q <= HOST_IDLE;
          end
        end
        HOST_MMU_REQ:
          if (mmu_cfg_valid_o && mmu_cfg_ready_i) phase_q <= HOST_MMU_RSP;
        HOST_MMU_RSP: begin
          if (mmu_publish) begin
            mmu_rdata_q <= mmu_cfg_rsp_rdata_i;
            mgmt_status_q <= {5'b0, 3'b0, 5'b0, 3'(mmu_cfg_rsp_status_i),
                6'b0, 2'd1, 6'b0,
                (mmu_cfg_rsp_status_i != vsp_mem_common_pkg::VSP_MEM_STATUS_OK),
                1'b1};
            phase_q <= HOST_IDLE;
          end
        end
        HOST_MAINT_REQ:
          if (maint_cmd_valid_o && maint_cmd_ready_i) phase_q <= HOST_MAINT_RSP;
        HOST_MAINT_RSP: begin
          if (maint_publish) begin
            mgmt_status_q <= {5'b0, 3'(maint_cpl_fault_i),
                5'b0, 3'(maint_cpl_status_i), 6'b0, 2'd2, 6'b0,
                ((maint_cpl_status_i != vsp_mem_common_pkg::VSP_MEM_MAINT_CPL_OK) ||
                 (maint_cpl_fault_i != vsp_mem_common_pkg::VSP_MEM_FAULT_NONE)),
                1'b1};
            phase_q <= HOST_IDLE;
          end
        end
        default: begin end
      endcase

      if (write_fire) begin
        case (mmio_req_addr_i)
          VSP_HOST_REG_START_PC: start_pc_q <= merge_bytes(start_pc_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_END_PC: end_pc_q <= merge_bytes(end_pc_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_GROUP_MASK: group_mask_q <= merge_bytes(group_mask_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_FETCH_CONTEXT: fetch_context_q <= merge_bytes(fetch_context_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_TAG_SEED: tag_seed_q <= merge_bytes(tag_seed_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_IRQ_ENABLE:
            if (mmio_req_wstrb_i[0]) irq_enable_q <= mmio_req_wdata_i[2:0];
          VSP_HOST_REG_MMU_CONTEXT: mmu_context_q <= merge_bytes(mmu_context_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MMU_FIELD: mmu_field_q <= merge_bytes(mmu_field_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MMU_WDATA: mmu_wdata_q <= merge_bytes(mmu_wdata_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MAINT_OP: maint_op_q <= merge_bytes(maint_op_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MAINT_EADDR: maint_eaddr_q <= merge_bytes(maint_eaddr_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MAINT_PADDR_LO: maint_paddr_lo_q <= merge_bytes(maint_paddr_lo_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MAINT_PADDR_HI: maint_paddr_hi_q <= merge_bytes(maint_paddr_hi_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MAINT_CONTEXT: maint_context_q <= merge_bytes(maint_context_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_MAINT_ASID: maint_asid_q <= merge_bytes(maint_asid_q, mmio_req_wdata_i, mmio_req_wstrb_i);
          VSP_HOST_REG_COMMAND: begin
            case (mmio_req_wdata_i)
              VSP_HOST_CMD_START: begin
                start_pc_o <= start_pc_q;
                end_pc_o <= end_pc_q;
                start_group_mask_o <= group_mask_q[GROUP_COUNT-1:0];
                start_tag_seed_o <= tag_seed_q[TAG_W-1:0];
                start_ifetch_addr_space_o <= fetch_context_q[1:0];
                start_ifetch_addr_context_o <= fetch_context_q[15:8];
                retired_q <= '0;
                terminal_done_q <= 1'b0;
                terminal_failed_q <= 1'b0;
                terminal_pc_q <= '0;
                phase_q <= HOST_START;
              end
              VSP_HOST_CMD_ACK_RESULT: result_q <= '0;
              VSP_HOST_CMD_CLEAR_PROTOCOL: protocol_error_clear_o <= 1'b1;
              VSP_HOST_CMD_MMU_READ, VSP_HOST_CMD_MMU_WRITE: begin
                mmu_cfg_write_o <= mmio_req_wdata_i == VSP_HOST_CMD_MMU_WRITE;
                mmu_cfg_context_o <= mmu_context_q[7:0];
                mmu_cfg_field_o <= mmu_field_q[3:0];
                mmu_cfg_wdata_o <= mmu_wdata_q;
                mgmt_status_q <= '0;
                phase_q <= HOST_MMU_REQ;
              end
              VSP_HOST_CMD_MAINTENANCE: begin
                maint_cmd_op_o <= maint_op_q[3:0];
                maint_cmd_eaddr_o <= maint_eaddr_q;
                maint_cmd_paddr_o <= PADDR_W'({maint_paddr_hi_q, maint_paddr_lo_q});
                maint_cmd_addr_context_o <= maint_context_q[7:0];
                maint_cmd_asid_o <= maint_asid_q[ASID_W-1:0];
                mgmt_status_q <= '0;
                phase_q <= HOST_MAINT_REQ;
              end
              default: begin end
            endcase
          end
          default: begin end
        endcase
      end
    end
  end

endmodule

`default_nettype wire
