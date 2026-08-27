module vsp_vrf_span_engine #(
  // One physical VRF row is VRF_ROW_BYTES bytes. The first implementation profile
  // uses four 8-bit lanes, so one selected group contributes one 32-bit beat.
  parameter int GROUP_COUNT       = 4,
  parameter int VRF_ROW_BYTES     = 4,
  parameter int VRF_ROWS          = 16,
  parameter int EXEC_CONTEXT_COUNT = 2,
  parameter int CMD_TAG_W         = 8,
  parameter int MEM_EADDR_W       = 32,
  parameter int MEM_OFFSET_W      = 16,
  parameter int ADDR_CONTEXT_W    = 8,
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int VRF_ROW_ADDR_W = (VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS),
  parameter int EXEC_CONTEXT_ID_W = (EXEC_CONTEXT_COUNT <= 2) ? 1 :
                                    $clog2(EXEC_CONTEXT_COUNT),
  parameter int SPAN_BYTES_W = ((GROUP_COUNT*VRF_ROW_BYTES) <= 1) ? 1 :
                               $clog2((GROUP_COUNT*VRF_ROW_BYTES) + 1)
) (
  input  logic clk_i,
  // Reset is a transaction-domain reset: the attached memory and VRF child
  // endpoints must discard their outstanding responses at the same time.
  // This baseline has no response epoch with which to reject a pre-reset beat.
  input  logic rst_ni,

  // One canonical VSP MEMORY parent action. exec_context identifies the
  // sequencer/owner and is deliberately independent of addr_context, which is
  // an opaque handle for a future translation service. The engine only forms
  // and advances effective addresses; it does not translate them.
  input  logic                              cmd_valid_i,
  output logic                              cmd_ready_o,
  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0]  cmd_op_i,
  input  logic [EXEC_CONTEXT_ID_W-1:0]      cmd_exec_context_i,
  input  logic [CMD_TAG_W-1:0]              cmd_tag_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                               cmd_addr_space_i,
  input  logic [ADDR_CONTEXT_W-1:0]         cmd_addr_context_i,
  input  logic [MEM_EADDR_W-1:0]            cmd_base_eaddr_i,
  input  logic signed [MEM_OFFSET_W-1:0]    cmd_eaddr_offset_i,
  input  logic [GROUP_COUNT-1:0]            cmd_group_mask_i,
  input  logic [VRF_ROW_ADDR_W-1:0]         cmd_vrf_row_i,
  input  logic [SPAN_BYTES_W-1:0]           cmd_span_bytes_i,

  // Ordered single-outstanding data-memory access boundary. Address-space and
  // translation-context metadata remain stable with the effective address.
  // A future adapter may translate/route the request; the current engine has
  // no TLB, PTW, cache, transaction ID, replay, or out-of-order response path.
  // Every accepted request, including STORE, returns exactly one response.
  output logic                              dmem_req_valid_o,
  input  logic                              dmem_req_ready_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]  dmem_req_op_o,
  output logic [MEM_EADDR_W-1:0]            dmem_req_eaddr_o,
  output logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                               dmem_req_addr_space_o,
  output logic [ADDR_CONTEXT_W-1:0]         dmem_req_addr_context_o,
  output logic [(VRF_ROW_BYTES*8)-1:0]      dmem_req_wdata_o,
  output logic [VRF_ROW_BYTES-1:0]          dmem_req_wstrb_o,
  input  logic                              dmem_rsp_valid_i,
  output logic                              dmem_rsp_ready_o,
  input  logic [(VRF_ROW_BYTES*8)-1:0]      dmem_rsp_rdata_i,
  input  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                               dmem_rsp_fault_cause_i,

  // LOAD child: one masked VRF row write routed by group_id. The parent does
  // not advance until the accepted state-write child completion returns.
  output logic                              vrf_write_valid_o,
  input  logic                              vrf_write_ready_i,
  output logic [EXEC_CONTEXT_ID_W-1:0]      vrf_write_exec_context_o,
  output logic [CMD_TAG_W-1:0]              vrf_write_tag_o,
  output logic [GROUP_ID_W-1:0]             vrf_write_group_o,
  output logic [VRF_ROW_ADDR_W-1:0]         vrf_write_row_o,
  output logic [VRF_ROW_BYTES-1:0]          vrf_write_mask_o,
  output logic [(VRF_ROW_BYTES*8)-1:0]      vrf_write_data_o,
  input  logic                              vrf_write_cpl_valid_i,
  output logic                              vrf_write_cpl_ready_o,
  input  logic [EXEC_CONTEXT_ID_W-1:0]      vrf_write_cpl_exec_context_i,
  input  logic [CMD_TAG_W-1:0]              vrf_write_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_write_cpl_group_i,
  input  logic                              vrf_write_cpl_error_i,

  // STORE child: request a narrow VRF row export. Completion and data are
  // independent channels and may arrive in either order; both are consumed
  // before the row is written to memory. Every accepted read must produce one
  // completion and one response even on error (an error response may carry
  // zero data and an arbitrary mask), matching the current group-wrapper
  // EXEC/export contract. Response identity remains meaningful and is checked
  // even when error is asserted. This is deliberately VRF-only. An ARF value
  // is first transformed with
  // NSLICE/NCLIP into VRF by the program.
  output logic                              vrf_read_valid_o,
  input  logic                              vrf_read_ready_i,
  output logic [EXEC_CONTEXT_ID_W-1:0]      vrf_read_exec_context_o,
  output logic [CMD_TAG_W-1:0]              vrf_read_tag_o,
  output logic [GROUP_ID_W-1:0]             vrf_read_group_o,
  output logic [VRF_ROW_ADDR_W-1:0]         vrf_read_row_o,
  output logic [VRF_ROW_BYTES-1:0]          vrf_read_mask_o,
  input  logic                              vrf_read_cpl_valid_i,
  output logic                              vrf_read_cpl_ready_o,
  input  logic [EXEC_CONTEXT_ID_W-1:0]      vrf_read_cpl_exec_context_i,
  input  logic [CMD_TAG_W-1:0]              vrf_read_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_read_cpl_group_i,
  input  logic                              vrf_read_cpl_error_i,
  input  logic                              vrf_read_rsp_valid_i,
  output logic                              vrf_read_rsp_ready_o,
  input  logic [EXEC_CONTEXT_ID_W-1:0]      vrf_read_rsp_exec_context_i,
  input  logic [CMD_TAG_W-1:0]              vrf_read_rsp_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_read_rsp_group_i,
  input  logic [(VRF_ROW_BYTES*8)-1:0]      vrf_read_rsp_data_i,
  input  logic [VRF_ROW_BYTES-1:0]          vrf_read_rsp_mask_i,
  input  logic                              vrf_read_rsp_error_i,

  // One completion per accepted parent. Runtime errors stop on the first
  // failed group. Earlier completed groups remain committed and are reported
  // explicitly; the engine does not claim transaction-wide rollback.
  output logic                              cpl_valid_o,
  input  logic                              cpl_ready_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]  cpl_op_o,
  output logic [EXEC_CONTEXT_ID_W-1:0]      cpl_exec_context_o,
  output logic [CMD_TAG_W-1:0]              cpl_tag_o,
  output logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0] cpl_status_o,
  output logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
                                               cpl_fault_cause_o,
  output logic [MEM_EADDR_W-1:0]            cpl_fault_eaddr_o,
  output logic [GROUP_COUNT-1:0]            cpl_requested_group_mask_o,
  output logic [GROUP_COUNT-1:0]            cpl_completed_group_mask_o,
  output logic [GROUP_COUNT-1:0]            cpl_failed_group_mask_o,
  output logic [SPAN_BYTES_W-1:0]           cpl_bytes_committed_o,
  output logic                              cpl_partial_o,

  output logic                              busy_o,
  input  logic                              protocol_error_clear_i,
  output logic                              protocol_error_o
);
  import vsp_pkg::*;

  localparam int VRF_ROW_W = VRF_ROW_BYTES * 8;
  localparam int EADDR_EXT_W = MEM_EADDR_W + 1;

  typedef enum logic [3:0] {
    STATE_IDLE,
    STATE_LOAD_DMEM_REQ,
    STATE_LOAD_DMEM_RSP,
    STATE_LOAD_VRF_REQ,
    STATE_LOAD_VRF_CPL,
    STATE_STORE_VRF_REQ,
    STATE_STORE_VRF_WAIT,
    STATE_STORE_DMEM_REQ,
    STATE_STORE_DMEM_RSP,
    STATE_DONE
  } state_e;

  state_e state_q;

  logic [VSP_MEM_OP_W-1:0] command_op_q;
  logic [EXEC_CONTEXT_ID_W-1:0] command_exec_context_q;
  logic [CMD_TAG_W-1:0] command_tag_q;
  logic [VSP_MEM_ADDR_SPACE_W-1:0] command_addr_space_q;
  logic [ADDR_CONTEXT_W-1:0] command_addr_context_q;
  logic [GROUP_COUNT-1:0] requested_group_mask_q;
  logic [GROUP_COUNT-1:0] remaining_group_mask_q;
  logic [GROUP_COUNT-1:0] completed_group_mask_q;
  logic [VRF_ROW_ADDR_W-1:0] command_vrf_row_q;
  logic [MEM_EADDR_W-1:0] current_eaddr_q;
  logic [GROUP_ID_W-1:0] current_group_q;
  logic [VRF_ROW_BYTES-1:0] final_byte_mask_q;
  logic [SPAN_BYTES_W-1:0] bytes_committed_q;
  logic [VRF_ROW_W-1:0] load_data_q;
  logic [VRF_ROW_W-1:0] store_data_q;

  logic store_cpl_seen_q;
  logic store_rsp_seen_q;
  logic store_vrf_error_q;

  logic [VSP_MEM_CPL_STATUS_W-1:0] completion_status_q;
  logic [VSP_MEM_FAULT_CAUSE_W-1:0] completion_fault_cause_q;
  logic [MEM_EADDR_W-1:0] completion_fault_eaddr_q;
  logic [GROUP_COUNT-1:0] completion_failed_mask_q;
  logic protocol_error_q;

  logic signed [EADDR_EXT_W-1:0] command_base_ext;
  logic signed [EADDR_EXT_W-1:0] command_offset_ext;
  logic signed [EADDR_EXT_W-1:0] command_eaddr_sum;
  logic [MEM_EADDR_W-1:0] command_effective_addr;
  logic [EADDR_EXT_W-1:0] command_last_beat_end;
  logic command_eaddr_error;
  logic command_fields_error;
  logic [VRF_ROW_BYTES-1:0] command_final_byte_mask;
  logic [GROUP_ID_W-1:0] command_first_group;

  logic [GROUP_COUNT-1:0] current_group_onehot;
  logic [GROUP_COUNT-1:0] remaining_after_current;
  logic [GROUP_COUNT-1:0] completed_after_current;
  logic [VRF_ROW_BYTES-1:0] current_byte_mask;
  logic [SPAN_BYTES_W-1:0] current_beat_bytes;
  logic [SPAN_BYTES_W-1:0] bytes_after_current;
  logic [GROUP_ID_W-1:0] next_group;
  logic current_is_last;

  logic command_fire;
  logic dmem_req_fire;
  logic dmem_rsp_fire;
  logic vrf_write_fire;
  logic vrf_write_cpl_fire;
  logic vrf_read_fire;
  logic vrf_read_cpl_fire;
  logic vrf_read_rsp_fire;
  logic completion_fire;

  logic vrf_write_cpl_mismatch;
  logic vrf_read_cpl_mismatch;
  logic vrf_read_rsp_mismatch;
  logic store_cpl_seen_after;
  logic store_rsp_seen_after;
  logic store_vrf_error_after;
  logic protocol_fault;

  function automatic int unsigned count_groups(
      input logic [GROUP_COUNT-1:0] mask);
    int unsigned count;
    count = 0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (mask[group]) count++;
    end
    return count;
  endfunction

  function automatic logic [GROUP_ID_W-1:0] first_group(
      input logic [GROUP_COUNT-1:0] mask);
    logic found;
    first_group = '0;
    found = 1'b0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (!found && mask[group]) begin
        first_group = GROUP_ID_W'(group);
        found = 1'b1;
      end
    end
  endfunction

  function automatic logic [VRF_ROW_BYTES-1:0] low_byte_mask(
      input int unsigned byte_count);
    low_byte_mask = '0;
    for (int byte_index = 0; byte_index < VRF_ROW_BYTES; byte_index++) begin
      if (byte_index < byte_count) low_byte_mask[byte_index] = 1'b1;
    end
  endfunction

  always_comb begin : command_validation
    int unsigned selected_groups;
    int unsigned span_bytes;
    int unsigned required_groups;
    int unsigned final_bytes;
    int unsigned last_beat_offset;

    selected_groups = count_groups(cmd_group_mask_i);
    span_bytes = int'(cmd_span_bytes_i);
    required_groups = (span_bytes + VRF_ROW_BYTES - 1) / VRF_ROW_BYTES;
    final_bytes = span_bytes % VRF_ROW_BYTES;
    if (final_bytes == 0) final_bytes = VRF_ROW_BYTES;

    command_base_ext = $signed({1'b0, cmd_base_eaddr_i});
    command_offset_ext = EADDR_EXT_W'($signed(cmd_eaddr_offset_i));
    command_eaddr_sum = command_base_ext + command_offset_ext;
    command_effective_addr = command_eaddr_sum[MEM_EADDR_W-1:0];

    last_beat_offset = (selected_groups == 0)
        ? 0 : ((selected_groups * VRF_ROW_BYTES) - 1);
    command_last_beat_end = {1'b0, command_effective_addr} +
                            EADDR_EXT_W'(last_beat_offset);

    command_fields_error =
        (int'(cmd_exec_context_i) >= EXEC_CONTEXT_COUNT) ||
        (int'(cmd_vrf_row_i) >= VRF_ROWS) ||
        !vsp_mem_addr_space_defined(cmd_addr_space_i) ||
        (selected_groups == 0) || (span_bytes == 0) ||
        (span_bytes > (GROUP_COUNT * VRF_ROW_BYTES)) ||
        (required_groups != selected_groups);
    command_eaddr_error = command_eaddr_sum[EADDR_EXT_W-1] ||
        (|(command_effective_addr & MEM_EADDR_W'(VRF_ROW_BYTES - 1))) ||
        command_last_beat_end[EADDR_EXT_W-1];

    command_final_byte_mask = low_byte_mask(final_bytes);
    command_first_group = first_group(cmd_group_mask_i);
  end

  always_comb begin
    current_group_onehot = '0;
    if (int'(current_group_q) < GROUP_COUNT) begin
      current_group_onehot[int'(current_group_q)] = 1'b1;
    end
    remaining_after_current =
        remaining_group_mask_q & ~current_group_onehot;
    completed_after_current =
        completed_group_mask_q | current_group_onehot;
    current_is_last = !(|remaining_after_current);
    current_byte_mask = current_is_last ? final_byte_mask_q :
                                          {VRF_ROW_BYTES{1'b1}};
    current_beat_bytes = SPAN_BYTES_W'($countones(current_byte_mask));
    bytes_after_current = bytes_committed_q + current_beat_bytes;
    next_group = first_group(remaining_after_current);
  end

  always_comb begin
    cmd_ready_o = rst_ni && (state_q == STATE_IDLE);
    busy_o = state_q != STATE_IDLE;

    dmem_req_valid_o = 1'b0;
    dmem_req_op_o = command_op_q;
    dmem_req_eaddr_o = current_eaddr_q;
    dmem_req_addr_space_o = command_addr_space_q;
    dmem_req_addr_context_o = command_addr_context_q;
    dmem_req_wdata_o = store_data_q;
    dmem_req_wstrb_o = '0;
    dmem_rsp_ready_o = 1'b0;

    vrf_write_valid_o = 1'b0;
    vrf_write_exec_context_o = command_exec_context_q;
    vrf_write_tag_o = command_tag_q;
    vrf_write_group_o = current_group_q;
    vrf_write_row_o = command_vrf_row_q;
    vrf_write_mask_o = current_byte_mask;
    vrf_write_data_o = load_data_q;
    vrf_write_cpl_ready_o = 1'b0;

    vrf_read_valid_o = 1'b0;
    vrf_read_exec_context_o = command_exec_context_q;
    vrf_read_tag_o = command_tag_q;
    vrf_read_group_o = current_group_q;
    vrf_read_row_o = command_vrf_row_q;
    vrf_read_mask_o = current_byte_mask;
    vrf_read_cpl_ready_o = 1'b0;
    vrf_read_rsp_ready_o = 1'b0;

    unique case (state_q)
      STATE_LOAD_DMEM_REQ: begin
        dmem_req_valid_o = 1'b1;
      end
      STATE_LOAD_DMEM_RSP: begin
        dmem_rsp_ready_o = 1'b1;
      end
      STATE_LOAD_VRF_REQ: begin
        vrf_write_valid_o = 1'b1;
      end
      STATE_LOAD_VRF_CPL: begin
        vrf_write_cpl_ready_o = 1'b1;
      end
      STATE_STORE_VRF_REQ: begin
        vrf_read_valid_o = 1'b1;
      end
      STATE_STORE_VRF_WAIT: begin
        vrf_read_cpl_ready_o = !store_cpl_seen_q;
        vrf_read_rsp_ready_o = !store_rsp_seen_q;
      end
      STATE_STORE_DMEM_REQ: begin
        dmem_req_valid_o = 1'b1;
        dmem_req_wstrb_o = current_byte_mask;
      end
      STATE_STORE_DMEM_RSP: begin
        dmem_rsp_ready_o = 1'b1;
      end
      default: begin
      end
    endcase
  end

  assign cpl_valid_o = state_q == STATE_DONE;
  assign cpl_op_o = command_op_q;
  assign cpl_exec_context_o = command_exec_context_q;
  assign cpl_tag_o = command_tag_q;
  assign cpl_status_o = completion_status_q;
  assign cpl_fault_cause_o = completion_fault_cause_q;
  assign cpl_fault_eaddr_o = completion_fault_eaddr_q;
  assign cpl_requested_group_mask_o = requested_group_mask_q;
  assign cpl_completed_group_mask_o = completed_group_mask_q;
  assign cpl_failed_group_mask_o = completion_failed_mask_q;
  assign cpl_bytes_committed_o = bytes_committed_q;
  assign cpl_partial_o = (completion_status_q != VSP_MEM_CPL_OK) &&
                         (|completed_group_mask_q);
  assign protocol_error_o = protocol_error_q;

  assign command_fire = cmd_valid_i && cmd_ready_o;
  assign dmem_req_fire = dmem_req_valid_o && dmem_req_ready_i;
  assign dmem_rsp_fire = dmem_rsp_valid_i && dmem_rsp_ready_o;
  assign vrf_write_fire = vrf_write_valid_o && vrf_write_ready_i;
  assign vrf_write_cpl_fire = vrf_write_cpl_valid_i &&
                               vrf_write_cpl_ready_o;
  assign vrf_read_fire = vrf_read_valid_o && vrf_read_ready_i;
  assign vrf_read_cpl_fire = vrf_read_cpl_valid_i &&
                              vrf_read_cpl_ready_o;
  assign vrf_read_rsp_fire = vrf_read_rsp_valid_i &&
                              vrf_read_rsp_ready_o;
  assign completion_fire = cpl_valid_o && cpl_ready_i;

  assign vrf_write_cpl_mismatch =
      (vrf_write_cpl_exec_context_i != command_exec_context_q) ||
      (vrf_write_cpl_tag_i != command_tag_q) ||
      (vrf_write_cpl_group_i != current_group_q);
  assign vrf_read_cpl_mismatch =
      (vrf_read_cpl_exec_context_i != command_exec_context_q) ||
      (vrf_read_cpl_tag_i != command_tag_q) ||
      (vrf_read_cpl_group_i != current_group_q);
  assign vrf_read_rsp_mismatch =
      (vrf_read_rsp_exec_context_i != command_exec_context_q) ||
      (vrf_read_rsp_tag_i != command_tag_q) ||
      (vrf_read_rsp_group_i != current_group_q) ||
      (!vrf_read_rsp_error_i &&
       ((vrf_read_rsp_mask_i & current_byte_mask) != current_byte_mask));

  assign store_cpl_seen_after = store_cpl_seen_q || vrf_read_cpl_fire;
  assign store_rsp_seen_after = store_rsp_seen_q || vrf_read_rsp_fire;
  assign store_vrf_error_after = store_vrf_error_q ||
      (vrf_read_cpl_fire &&
       (vrf_read_cpl_error_i || vrf_read_cpl_mismatch)) ||
      (vrf_read_rsp_fire &&
       (vrf_read_rsp_error_i || vrf_read_rsp_mismatch));
  assign protocol_fault =
      (vrf_write_cpl_fire && vrf_write_cpl_mismatch) ||
      (vrf_read_cpl_fire && vrf_read_cpl_mismatch) ||
      (vrf_read_rsp_fire && vrf_read_rsp_mismatch);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= STATE_IDLE;
      command_op_q <= VSP_MEM_OP_LOAD;
      command_exec_context_q <= '0;
      command_tag_q <= '0;
      command_addr_space_q <= VSP_MEM_ADDR_SPACE_LOCAL;
      command_addr_context_q <= '0;
      requested_group_mask_q <= '0;
      remaining_group_mask_q <= '0;
      completed_group_mask_q <= '0;
      command_vrf_row_q <= '0;
      current_eaddr_q <= '0;
      current_group_q <= '0;
      final_byte_mask_q <= '0;
      bytes_committed_q <= '0;
      load_data_q <= '0;
      store_data_q <= '0;
      store_cpl_seen_q <= 1'b0;
      store_rsp_seen_q <= 1'b0;
      store_vrf_error_q <= 1'b0;
      completion_status_q <= VSP_MEM_CPL_OK;
      completion_fault_cause_q <= VSP_MEM_FAULT_NONE;
      completion_fault_eaddr_q <= '0;
      completion_failed_mask_q <= '0;
      protocol_error_q <= 1'b0;
    end else begin
      if (protocol_error_clear_i) protocol_error_q <= 1'b0;
      if (protocol_fault) protocol_error_q <= 1'b1;

      unique case (state_q)
        STATE_IDLE: begin
          if (command_fire) begin
            command_op_q <= cmd_op_i;
            command_exec_context_q <= cmd_exec_context_i;
            command_tag_q <= cmd_tag_i;
            command_addr_space_q <= cmd_addr_space_i;
            command_addr_context_q <= cmd_addr_context_i;
            requested_group_mask_q <= cmd_group_mask_i;
            remaining_group_mask_q <= cmd_group_mask_i;
            completed_group_mask_q <= '0;
            command_vrf_row_q <= cmd_vrf_row_i;
            current_eaddr_q <= command_effective_addr;
            current_group_q <= command_first_group;
            final_byte_mask_q <= command_final_byte_mask;
            bytes_committed_q <= '0;
            completion_status_q <= VSP_MEM_CPL_OK;
            completion_fault_cause_q <= VSP_MEM_FAULT_NONE;
            completion_fault_eaddr_q <= '0;
            completion_failed_mask_q <= '0;
            store_cpl_seen_q <= 1'b0;
            store_rsp_seen_q <= 1'b0;
            store_vrf_error_q <= 1'b0;

            if (command_fields_error) begin
              completion_status_q <= VSP_MEM_CPL_BAD_REQUEST;
              state_q <= STATE_DONE;
            end else if (command_eaddr_error) begin
              completion_status_q <= VSP_MEM_CPL_BAD_EADDR;
              state_q <= STATE_DONE;
            end else if (cmd_op_i == VSP_MEM_OP_STORE) begin
              state_q <= STATE_STORE_VRF_REQ;
            end else begin
              state_q <= STATE_LOAD_DMEM_REQ;
            end
          end
        end

        STATE_LOAD_DMEM_REQ: begin
          if (dmem_req_fire) state_q <= STATE_LOAD_DMEM_RSP;
        end

        STATE_LOAD_DMEM_RSP: begin
          if (dmem_rsp_fire) begin
            if (dmem_rsp_fault_cause_i != VSP_MEM_FAULT_NONE) begin
              completion_status_q <= VSP_MEM_CPL_MEMORY_FAULT;
              completion_fault_cause_q <= dmem_rsp_fault_cause_i;
              completion_fault_eaddr_q <= current_eaddr_q;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              load_data_q <= dmem_rsp_rdata_i;
              state_q <= STATE_LOAD_VRF_REQ;
            end
          end
        end

        STATE_LOAD_VRF_REQ: begin
          if (vrf_write_fire) state_q <= STATE_LOAD_VRF_CPL;
        end

        STATE_LOAD_VRF_CPL: begin
          if (vrf_write_cpl_fire) begin
            if (vrf_write_cpl_error_i || vrf_write_cpl_mismatch) begin
              completion_status_q <= VSP_MEM_CPL_VRF_ERROR;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else if (current_is_last) begin
              remaining_group_mask_q <= remaining_after_current;
              completed_group_mask_q <= completed_after_current;
              bytes_committed_q <= bytes_after_current;
              completion_status_q <= VSP_MEM_CPL_OK;
              state_q <= STATE_DONE;
            end else begin
              remaining_group_mask_q <= remaining_after_current;
              completed_group_mask_q <= completed_after_current;
              bytes_committed_q <= bytes_after_current;
              current_eaddr_q <= current_eaddr_q +
                                 MEM_EADDR_W'(VRF_ROW_BYTES);
              current_group_q <= next_group;
              state_q <= STATE_LOAD_DMEM_REQ;
            end
          end
        end

        STATE_STORE_VRF_REQ: begin
          if (vrf_read_fire) begin
            store_cpl_seen_q <= 1'b0;
            store_rsp_seen_q <= 1'b0;
            store_vrf_error_q <= 1'b0;
            state_q <= STATE_STORE_VRF_WAIT;
          end
        end

        STATE_STORE_VRF_WAIT: begin
          if (vrf_read_cpl_fire) store_cpl_seen_q <= 1'b1;
          if (vrf_read_rsp_fire) begin
            store_rsp_seen_q <= 1'b1;
            store_data_q <= vrf_read_rsp_data_i;
          end
          if ((vrf_read_cpl_fire &&
               (vrf_read_cpl_error_i || vrf_read_cpl_mismatch)) ||
              (vrf_read_rsp_fire &&
               (vrf_read_rsp_error_i || vrf_read_rsp_mismatch))) begin
            store_vrf_error_q <= 1'b1;
          end

          if (store_cpl_seen_after && store_rsp_seen_after) begin
            if (store_vrf_error_after) begin
              completion_status_q <= VSP_MEM_CPL_VRF_ERROR;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              state_q <= STATE_STORE_DMEM_REQ;
            end
          end
        end

        STATE_STORE_DMEM_REQ: begin
          if (dmem_req_fire) state_q <= STATE_STORE_DMEM_RSP;
        end

        STATE_STORE_DMEM_RSP: begin
          if (dmem_rsp_fire) begin
            if (dmem_rsp_fault_cause_i != VSP_MEM_FAULT_NONE) begin
              completion_status_q <= VSP_MEM_CPL_MEMORY_FAULT;
              completion_fault_cause_q <= dmem_rsp_fault_cause_i;
              completion_fault_eaddr_q <= current_eaddr_q;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else if (current_is_last) begin
              remaining_group_mask_q <= remaining_after_current;
              completed_group_mask_q <= completed_after_current;
              bytes_committed_q <= bytes_after_current;
              completion_status_q <= VSP_MEM_CPL_OK;
              state_q <= STATE_DONE;
            end else begin
              remaining_group_mask_q <= remaining_after_current;
              completed_group_mask_q <= completed_after_current;
              bytes_committed_q <= bytes_after_current;
              current_eaddr_q <= current_eaddr_q +
                                 MEM_EADDR_W'(VRF_ROW_BYTES);
              current_group_q <= next_group;
              store_cpl_seen_q <= 1'b0;
              store_rsp_seen_q <= 1'b0;
              store_vrf_error_q <= 1'b0;
              state_q <= STATE_STORE_VRF_REQ;
            end
          end
        end

        STATE_DONE: begin
          if (completion_fire) state_q <= STATE_IDLE;
        end

        default: begin
          // Fail closed if state corruption is observed: retain the parent
          // identity, report its still-active groups, and do not silently
          // release command ownership without a completion.
          protocol_error_q <= 1'b1;
          completion_status_q <= VSP_MEM_CPL_VRF_ERROR;
          completion_failed_mask_q <= remaining_group_mask_q;
          state_q <= STATE_DONE;
        end
      endcase
    end
  end

  initial begin
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (VRF_ROW_BYTES < 1 ||
        (VRF_ROW_BYTES & (VRF_ROW_BYTES - 1)) != 0) begin
      $error("VRF_ROW_BYTES must be a positive power of two");
    end
    if (VRF_ROWS < 1) $error("VRF_ROWS must be positive");
    if (EXEC_CONTEXT_COUNT < 1) begin
      $error("EXEC_CONTEXT_COUNT must be positive");
    end
    if (CMD_TAG_W < 1 || MEM_EADDR_W < 1 || MEM_OFFSET_W < 1 ||
        ADDR_CONTEXT_W < 1) begin
      $error("command tag, address, offset, and context widths must be positive");
    end
    if (MEM_OFFSET_W > EADDR_EXT_W) begin
      $error("MEM_OFFSET_W must not exceed MEM_EADDR_W+1");
    end
    if (GROUP_ID_W != ((GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT))) begin
      $error("GROUP_ID_W does not match GROUP_COUNT");
    end
    if (VRF_ROW_ADDR_W != ((VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS))) begin
      $error("VRF_ROW_ADDR_W does not match VRF_ROWS");
    end
    if (EXEC_CONTEXT_ID_W != ((EXEC_CONTEXT_COUNT <= 2) ? 1 :
                              $clog2(EXEC_CONTEXT_COUNT))) begin
      $error("EXEC_CONTEXT_ID_W does not match EXEC_CONTEXT_COUNT");
    end
    if (SPAN_BYTES_W != (((GROUP_COUNT*VRF_ROW_BYTES) <= 1) ? 1 :
                        $clog2((GROUP_COUNT*VRF_ROW_BYTES) + 1))) begin
      $error("SPAN_BYTES_W does not cover the maximum command span");
    end
  end
endmodule
