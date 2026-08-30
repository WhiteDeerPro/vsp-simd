module vsp_vector_memory_engine #(
  // A group contributes one SIMD4 byte row. The baseline is four groups
  // (16 bytes); the architectural scaling bound is sixteen groups (64 bytes).
  parameter int GROUP_COUNT          = 4,
  parameter int VRF_ROW_BYTES        = 4,
  parameter int VRF_ROWS             = 16,
  parameter int EXEC_CONTEXT_COUNT   = 1,
  parameter int CMD_TAG_W            = 8,
  parameter int MEM_EADDR_W          = 32,
  parameter int MEM_OFFSET_W         = 16,
  parameter int ADDR_CONTEXT_W       = 8,
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int VRF_ROW_ADDR_W = (VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS),
  parameter int EXEC_CONTEXT_ID_W = (EXEC_CONTEXT_COUNT <= 2) ? 1 :
                                    $clog2(EXEC_CONTEXT_COUNT),
  parameter int SPAN_BYTES_W = ((GROUP_COUNT*VRF_ROW_BYTES) <= 1) ? 1 :
                               $clog2((GROUP_COUNT*VRF_ROW_BYTES) + 1)
) (
  input  logic clk_i,
  // The memory and VRF child endpoints discard outstanding responses with
  // this transaction-domain reset; this baseline has no response epoch.
  input  logic rst_ni,

  input  logic                              cmd_valid_i,
  output logic                              cmd_ready_o,
  input  logic [vsp_pkg::VSP_MEM_OP_W-1:0] cmd_op_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_MODE_W-1:0] cmd_addr_mode_i,
  input  logic [EXEC_CONTEXT_ID_W-1:0]      cmd_exec_context_i,
  input  logic [CMD_TAG_W-1:0]              cmd_tag_i,
  input  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                               cmd_addr_space_i,
  input  logic [ADDR_CONTEXT_W-1:0]         cmd_addr_context_i,
  input  logic [MEM_EADDR_W-1:0]            cmd_base_eaddr_i,
  input  logic signed [MEM_OFFSET_W-1:0]    cmd_eaddr_offset_i,
  input  logic [GROUP_COUNT-1:0]            cmd_group_mask_i,
  // LOAD/GATHER write this row; STORE/SCATTER read it.
  input  logic [VRF_ROW_ADDR_W-1:0]         cmd_vrf_row_i,
  // INDEX_U8 reads unsigned byte offsets from this distributed row.
  input  logic [VRF_ROW_ADDR_W-1:0]         cmd_index_vrf_row_i,
  // UNIT_STRIDE uses an explicit span. INDEX_U8 requires zero and activates
  // all four byte lanes of every selected group.
  input  logic [SPAN_BYTES_W-1:0]           cmd_span_bytes_i,

  // Ordered single-outstanding memory boundary. INDEX_U8 is lowered here to
  // aligned ordinary LOAD/STORE beats with byte selection/strobes, so a future
  // cache/TLB/MMU adapter need not implement a vector-route request type.
  output logic                              dmem_req_valid_o,
  input  logic                              dmem_req_ready_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0] dmem_req_op_o,
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

  // One VRF read client is reused serially for index and scatter-data rows.
  // Completion and response may arrive in either order.
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

  output logic                              cpl_valid_o,
  input  logic                              cpl_ready_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0] cpl_op_o,
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
  localparam int LANE_ID_W = (VRF_ROW_BYTES <= 2) ? 1 :
                             $clog2(VRF_ROW_BYTES);

  typedef enum logic [3:0] {
    STATE_IDLE,
    STATE_LINEAR_LOAD_DMEM_REQ,
    STATE_LINEAR_LOAD_DMEM_RSP,
    STATE_VRF_WRITE_REQ,
    STATE_VRF_WRITE_CPL,
    STATE_VRF_READ_REQ,
    STATE_VRF_READ_WAIT,
    STATE_LINEAR_STORE_DMEM_REQ,
    STATE_LINEAR_STORE_DMEM_RSP,
    STATE_INDEXED_DMEM_REQ,
    STATE_INDEXED_DMEM_RSP,
    STATE_DONE
  } state_e;

  typedef enum logic [1:0] {
    READ_LINEAR_STORE,
    READ_INDEX,
    READ_SCATTER_DATA
  } read_kind_e;

  state_e state_q;
  read_kind_e read_kind_q;

  logic [VSP_MEM_OP_W-1:0] command_op_q;
  logic [VSP_MEM_ADDR_MODE_W-1:0] command_addr_mode_q;
  logic [EXEC_CONTEXT_ID_W-1:0] command_exec_context_q;
  logic [CMD_TAG_W-1:0] command_tag_q;
  logic [VSP_MEM_ADDR_SPACE_W-1:0] command_addr_space_q;
  logic [ADDR_CONTEXT_W-1:0] command_addr_context_q;
  logic [GROUP_COUNT-1:0] requested_group_mask_q;
  logic [GROUP_COUNT-1:0] remaining_group_mask_q;
  logic [GROUP_COUNT-1:0] completed_group_mask_q;
  logic [VRF_ROW_ADDR_W-1:0] command_vrf_row_q;
  logic [VRF_ROW_ADDR_W-1:0] command_index_vrf_row_q;
  logic [MEM_EADDR_W-1:0] window_base_eaddr_q;
  logic [MEM_EADDR_W-1:0] linear_eaddr_q;
  logic [GROUP_ID_W-1:0] current_group_q;
  logic [LANE_ID_W-1:0] current_lane_q;
  logic [VRF_ROW_BYTES-1:0] final_byte_mask_q;
  logic [SPAN_BYTES_W-1:0] bytes_committed_q;
  logic [VRF_ROW_W-1:0] load_data_q;
  logic [VRF_ROW_W-1:0] store_data_q;
  logic [VRF_ROW_W-1:0] index_data_q;
  logic [VRF_ROW_W-1:0] read_data_q;

  logic read_cpl_seen_q;
  logic read_rsp_seen_q;
  logic read_vrf_error_q;

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
  logic command_is_indexed;
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
  logic current_lane_is_last;

  logic [7:0] current_index_byte;
  logic [7:0] current_scatter_byte;
  logic [EADDR_EXT_W-1:0] indexed_eaddr_ext;
  logic [MEM_EADDR_W-1:0] indexed_byte_eaddr;
  logic [MEM_EADDR_W-1:0] indexed_aligned_eaddr;
  logic [LANE_ID_W-1:0] indexed_beat_lane;
  logic indexed_eaddr_error;
  logic [7:0] indexed_load_byte;

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
  logic read_cpl_seen_after;
  logic read_rsp_seen_after;
  logic read_vrf_error_after;
  logic [VRF_ROW_W-1:0] read_data_after;
  logic [VRF_ROW_BYTES-1:0] read_expected_mask;
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

    command_is_indexed = cmd_addr_mode_i == VSP_MEM_ADDR_MODE_INDEX_U8;
    command_base_ext = $signed({1'b0, cmd_base_eaddr_i});
    command_offset_ext = EADDR_EXT_W'($signed(cmd_eaddr_offset_i));
    command_eaddr_sum = command_base_ext + command_offset_ext;
    command_effective_addr = command_eaddr_sum[MEM_EADDR_W-1:0];

    last_beat_offset = (selected_groups == 0)
        ? 0 : ((selected_groups * VRF_ROW_BYTES) - 1);
    command_last_beat_end = {1'b0, command_effective_addr} +
                            EADDR_EXT_W'(last_beat_offset);

    command_fields_error =
        !vsp_mem_addr_mode_defined(cmd_addr_mode_i) ||
        (int'(cmd_exec_context_i) >= EXEC_CONTEXT_COUNT) ||
        (int'(cmd_vrf_row_i) >= VRF_ROWS) ||
        !vsp_mem_addr_space_defined(cmd_addr_space_i) ||
        (selected_groups == 0);
    if (command_is_indexed) begin
      command_fields_error |=
          (int'(cmd_index_vrf_row_i) >= VRF_ROWS) || (span_bytes != 0);
    end else begin
      command_fields_error |= (span_bytes == 0) ||
          (span_bytes > (GROUP_COUNT * VRF_ROW_BYTES)) ||
          (required_groups != selected_groups);
    end

    command_eaddr_error = command_eaddr_sum[EADDR_EXT_W-1];
    if (!command_is_indexed) begin
      command_eaddr_error |=
          (|(command_effective_addr & MEM_EADDR_W'(VRF_ROW_BYTES - 1))) ||
          command_last_beat_end[EADDR_EXT_W-1];
    end

    command_final_byte_mask = command_is_indexed ?
        {VRF_ROW_BYTES{1'b1}} : low_byte_mask(final_bytes);
    command_first_group = first_group(cmd_group_mask_i);
  end

  always_comb begin
    current_group_onehot = '0;
    if (int'(current_group_q) < GROUP_COUNT)
      current_group_onehot[int'(current_group_q)] = 1'b1;
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
    current_lane_is_last = int'(current_lane_q) == (VRF_ROW_BYTES - 1);
  end

  always_comb begin
    current_index_byte =
        index_data_q[(int'(current_lane_q)*8) +: 8];
    current_scatter_byte =
        store_data_q[(int'(current_lane_q)*8) +: 8];
    indexed_eaddr_ext = {1'b0, window_base_eaddr_q} +
                        EADDR_EXT_W'(current_index_byte);
    indexed_byte_eaddr = indexed_eaddr_ext[MEM_EADDR_W-1:0];
    indexed_aligned_eaddr = indexed_byte_eaddr &
        ~MEM_EADDR_W'(VRF_ROW_BYTES - 1);
    indexed_beat_lane = LANE_ID_W'(
        indexed_byte_eaddr & MEM_EADDR_W'(VRF_ROW_BYTES - 1));
    indexed_eaddr_error = indexed_eaddr_ext[EADDR_EXT_W-1];
    indexed_load_byte =
        dmem_rsp_rdata_i[(int'(indexed_beat_lane)*8) +: 8];
  end

  always_comb begin
    read_expected_mask = (read_kind_q == READ_LINEAR_STORE) ?
                         current_byte_mask :
                         {VRF_ROW_BYTES{1'b1}};
    read_data_after = vrf_read_rsp_fire ? vrf_read_rsp_data_i : read_data_q;
  end

  always_comb begin
    cmd_ready_o = rst_ni && (state_q == STATE_IDLE);
    busy_o = state_q != STATE_IDLE;

    dmem_req_valid_o = 1'b0;
    dmem_req_op_o = command_op_q;
    dmem_req_eaddr_o = linear_eaddr_q;
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
    vrf_write_mask_o = (command_addr_mode_q == VSP_MEM_ADDR_MODE_INDEX_U8) ?
                       {VRF_ROW_BYTES{1'b1}} : current_byte_mask;
    vrf_write_data_o = load_data_q;
    vrf_write_cpl_ready_o = 1'b0;

    vrf_read_valid_o = 1'b0;
    vrf_read_exec_context_o = command_exec_context_q;
    vrf_read_tag_o = command_tag_q;
    vrf_read_group_o = current_group_q;
    vrf_read_row_o = (read_kind_q == READ_INDEX) ?
                     command_index_vrf_row_q : command_vrf_row_q;
    vrf_read_mask_o = read_expected_mask;
    vrf_read_cpl_ready_o = 1'b0;
    vrf_read_rsp_ready_o = 1'b0;

    unique case (state_q)
      STATE_LINEAR_LOAD_DMEM_REQ: dmem_req_valid_o = 1'b1;
      STATE_LINEAR_LOAD_DMEM_RSP: dmem_rsp_ready_o = 1'b1;
      STATE_VRF_WRITE_REQ: vrf_write_valid_o = 1'b1;
      STATE_VRF_WRITE_CPL: vrf_write_cpl_ready_o = 1'b1;
      STATE_VRF_READ_REQ: vrf_read_valid_o = 1'b1;
      STATE_VRF_READ_WAIT: begin
        vrf_read_cpl_ready_o = !read_cpl_seen_q;
        vrf_read_rsp_ready_o = !read_rsp_seen_q;
      end
      STATE_LINEAR_STORE_DMEM_REQ: begin
        dmem_req_valid_o = 1'b1;
        dmem_req_wstrb_o = current_byte_mask;
      end
      STATE_LINEAR_STORE_DMEM_RSP: dmem_rsp_ready_o = 1'b1;
      STATE_INDEXED_DMEM_REQ: begin
        dmem_req_valid_o = !indexed_eaddr_error;
        dmem_req_eaddr_o = indexed_aligned_eaddr;
        dmem_req_wdata_o = '0;
        dmem_req_wstrb_o = '0;
        if (command_op_q == VSP_MEM_OP_STORE) begin
          dmem_req_wdata_o[(int'(indexed_beat_lane)*8) +: 8] =
              current_scatter_byte;
          dmem_req_wstrb_o[int'(indexed_beat_lane)] = 1'b1;
        end
      end
      STATE_INDEXED_DMEM_RSP: dmem_rsp_ready_o = 1'b1;
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
  // SCATTER may fail after part of its current group has reached memory.
  assign cpl_partial_o = (completion_status_q != VSP_MEM_CPL_OK) &&
                         (bytes_committed_q != '0);
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
       ((vrf_read_rsp_mask_i & read_expected_mask) != read_expected_mask));

  assign read_cpl_seen_after = read_cpl_seen_q || vrf_read_cpl_fire;
  assign read_rsp_seen_after = read_rsp_seen_q || vrf_read_rsp_fire;
  assign read_vrf_error_after = read_vrf_error_q ||
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
      read_kind_q <= READ_LINEAR_STORE;
      command_op_q <= VSP_MEM_OP_LOAD;
      command_addr_mode_q <= VSP_MEM_ADDR_MODE_UNIT_STRIDE;
      command_exec_context_q <= '0;
      command_tag_q <= '0;
      command_addr_space_q <= VSP_MEM_ADDR_SPACE_LOCAL;
      command_addr_context_q <= '0;
      requested_group_mask_q <= '0;
      remaining_group_mask_q <= '0;
      completed_group_mask_q <= '0;
      command_vrf_row_q <= '0;
      command_index_vrf_row_q <= '0;
      window_base_eaddr_q <= '0;
      linear_eaddr_q <= '0;
      current_group_q <= '0;
      current_lane_q <= '0;
      final_byte_mask_q <= '0;
      bytes_committed_q <= '0;
      load_data_q <= '0;
      store_data_q <= '0;
      index_data_q <= '0;
      read_data_q <= '0;
      read_cpl_seen_q <= 1'b0;
      read_rsp_seen_q <= 1'b0;
      read_vrf_error_q <= 1'b0;
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
            command_addr_mode_q <= cmd_addr_mode_i;
            command_exec_context_q <= cmd_exec_context_i;
            command_tag_q <= cmd_tag_i;
            command_addr_space_q <= cmd_addr_space_i;
            command_addr_context_q <= cmd_addr_context_i;
            requested_group_mask_q <= cmd_group_mask_i;
            remaining_group_mask_q <= cmd_group_mask_i;
            completed_group_mask_q <= '0;
            command_vrf_row_q <= cmd_vrf_row_i;
            command_index_vrf_row_q <= cmd_index_vrf_row_i;
            window_base_eaddr_q <= command_effective_addr;
            linear_eaddr_q <= command_effective_addr;
            current_group_q <= command_first_group;
            current_lane_q <= '0;
            final_byte_mask_q <= command_final_byte_mask;
            bytes_committed_q <= '0;
            load_data_q <= '0;
            store_data_q <= '0;
            index_data_q <= '0;
            read_data_q <= '0;
            completion_status_q <= VSP_MEM_CPL_OK;
            completion_fault_cause_q <= VSP_MEM_FAULT_NONE;
            completion_fault_eaddr_q <= '0;
            completion_failed_mask_q <= '0;
            read_cpl_seen_q <= 1'b0;
            read_rsp_seen_q <= 1'b0;
            read_vrf_error_q <= 1'b0;

            if (command_fields_error) begin
              completion_status_q <= VSP_MEM_CPL_BAD_REQUEST;
              state_q <= STATE_DONE;
            end else if (command_eaddr_error) begin
              completion_status_q <= VSP_MEM_CPL_BAD_EADDR;
              state_q <= STATE_DONE;
            end else if (command_is_indexed) begin
              read_kind_q <= READ_INDEX;
              state_q <= STATE_VRF_READ_REQ;
            end else if (cmd_op_i == VSP_MEM_OP_STORE) begin
              read_kind_q <= READ_LINEAR_STORE;
              state_q <= STATE_VRF_READ_REQ;
            end else begin
              state_q <= STATE_LINEAR_LOAD_DMEM_REQ;
            end
          end
        end

        STATE_LINEAR_LOAD_DMEM_REQ: begin
          if (dmem_req_fire) state_q <= STATE_LINEAR_LOAD_DMEM_RSP;
        end

        STATE_LINEAR_LOAD_DMEM_RSP: begin
          if (dmem_rsp_fire) begin
            if (dmem_rsp_fault_cause_i != VSP_MEM_FAULT_NONE) begin
              completion_status_q <= VSP_MEM_CPL_MEMORY_FAULT;
              completion_fault_cause_q <= dmem_rsp_fault_cause_i;
              completion_fault_eaddr_q <= linear_eaddr_q;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              load_data_q <= dmem_rsp_rdata_i;
              state_q <= STATE_VRF_WRITE_REQ;
            end
          end
        end

        STATE_VRF_WRITE_REQ: begin
          if (vrf_write_fire) state_q <= STATE_VRF_WRITE_CPL;
        end

        STATE_VRF_WRITE_CPL: begin
          if (vrf_write_cpl_fire) begin
            if (vrf_write_cpl_error_i || vrf_write_cpl_mismatch) begin
              completion_status_q <= VSP_MEM_CPL_VRF_ERROR;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              remaining_group_mask_q <= remaining_after_current;
              completed_group_mask_q <= completed_after_current;
              bytes_committed_q <= bytes_after_current;
              if (current_is_last) begin
                completion_status_q <= VSP_MEM_CPL_OK;
                state_q <= STATE_DONE;
              end else begin
                current_group_q <= next_group;
                load_data_q <= '0;
                if (command_addr_mode_q == VSP_MEM_ADDR_MODE_UNIT_STRIDE) begin
                  linear_eaddr_q <= linear_eaddr_q +
                                      MEM_EADDR_W'(VRF_ROW_BYTES);
                  state_q <= STATE_LINEAR_LOAD_DMEM_REQ;
                end else begin
                  current_lane_q <= '0;
                  read_kind_q <= READ_INDEX;
                  state_q <= STATE_VRF_READ_REQ;
                end
              end
            end
          end
        end

        STATE_VRF_READ_REQ: begin
          if (vrf_read_fire) begin
            read_cpl_seen_q <= 1'b0;
            read_rsp_seen_q <= 1'b0;
            read_vrf_error_q <= 1'b0;
            state_q <= STATE_VRF_READ_WAIT;
          end
        end

        STATE_VRF_READ_WAIT: begin
          if (vrf_read_cpl_fire) read_cpl_seen_q <= 1'b1;
          if (vrf_read_rsp_fire) begin
            read_rsp_seen_q <= 1'b1;
            read_data_q <= vrf_read_rsp_data_i;
          end
          if ((vrf_read_cpl_fire &&
               (vrf_read_cpl_error_i || vrf_read_cpl_mismatch)) ||
              (vrf_read_rsp_fire &&
               (vrf_read_rsp_error_i || vrf_read_rsp_mismatch)))
            read_vrf_error_q <= 1'b1;

          if (read_cpl_seen_after && read_rsp_seen_after) begin
            read_cpl_seen_q <= 1'b0;
            read_rsp_seen_q <= 1'b0;
            read_vrf_error_q <= 1'b0;
            if (read_vrf_error_after) begin
              completion_status_q <= VSP_MEM_CPL_VRF_ERROR;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              unique case (read_kind_q)
                READ_LINEAR_STORE: begin
                  store_data_q <= read_data_after;
                  state_q <= STATE_LINEAR_STORE_DMEM_REQ;
                end
                READ_INDEX: begin
                  index_data_q <= read_data_after;
                  current_lane_q <= '0;
                  if (command_op_q == VSP_MEM_OP_STORE) begin
                    read_kind_q <= READ_SCATTER_DATA;
                    state_q <= STATE_VRF_READ_REQ;
                  end else begin
                    state_q <= STATE_INDEXED_DMEM_REQ;
                  end
                end
                READ_SCATTER_DATA: begin
                  store_data_q <= read_data_after;
                  current_lane_q <= '0;
                  state_q <= STATE_INDEXED_DMEM_REQ;
                end
                default: begin
                  completion_status_q <= VSP_MEM_CPL_VRF_ERROR;
                  completion_failed_mask_q <= current_group_onehot;
                  protocol_error_q <= 1'b1;
                  state_q <= STATE_DONE;
                end
              endcase
            end
          end
        end

        STATE_LINEAR_STORE_DMEM_REQ: begin
          if (dmem_req_fire) state_q <= STATE_LINEAR_STORE_DMEM_RSP;
        end

        STATE_LINEAR_STORE_DMEM_RSP: begin
          if (dmem_rsp_fire) begin
            if (dmem_rsp_fault_cause_i != VSP_MEM_FAULT_NONE) begin
              completion_status_q <= VSP_MEM_CPL_MEMORY_FAULT;
              completion_fault_cause_q <= dmem_rsp_fault_cause_i;
              completion_fault_eaddr_q <= linear_eaddr_q;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              remaining_group_mask_q <= remaining_after_current;
              completed_group_mask_q <= completed_after_current;
              bytes_committed_q <= bytes_after_current;
              if (current_is_last) begin
                completion_status_q <= VSP_MEM_CPL_OK;
                state_q <= STATE_DONE;
              end else begin
                current_group_q <= next_group;
                linear_eaddr_q <= linear_eaddr_q +
                                    MEM_EADDR_W'(VRF_ROW_BYTES);
                read_kind_q <= READ_LINEAR_STORE;
                state_q <= STATE_VRF_READ_REQ;
              end
            end
          end
        end

        STATE_INDEXED_DMEM_REQ: begin
          if (indexed_eaddr_error) begin
            completion_status_q <= VSP_MEM_CPL_BAD_EADDR;
            completion_failed_mask_q <= current_group_onehot;
            state_q <= STATE_DONE;
          end else if (dmem_req_fire) begin
            state_q <= STATE_INDEXED_DMEM_RSP;
          end
        end

        STATE_INDEXED_DMEM_RSP: begin
          if (dmem_rsp_fire) begin
            if (dmem_rsp_fault_cause_i != VSP_MEM_FAULT_NONE) begin
              completion_status_q <= VSP_MEM_CPL_MEMORY_FAULT;
              completion_fault_cause_q <= dmem_rsp_fault_cause_i;
              // Report the exact byte address, not its aligned request beat.
              completion_fault_eaddr_q <= indexed_byte_eaddr;
              completion_failed_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else if (command_op_q == VSP_MEM_OP_LOAD) begin
              load_data_q[(int'(current_lane_q)*8) +: 8] <= indexed_load_byte;
              if (current_lane_is_last) begin
                state_q <= STATE_VRF_WRITE_REQ;
              end else begin
                current_lane_q <= current_lane_q + LANE_ID_W'(1);
                state_q <= STATE_INDEXED_DMEM_REQ;
              end
            end else begin
              // Global group/lane ascending order makes duplicate SCATTER
              // offsets deterministic: the highest active lane writes last.
              bytes_committed_q <= bytes_committed_q + SPAN_BYTES_W'(1);
              if (current_lane_is_last) begin
                remaining_group_mask_q <= remaining_after_current;
                completed_group_mask_q <= completed_after_current;
                if (current_is_last) begin
                  completion_status_q <= VSP_MEM_CPL_OK;
                  state_q <= STATE_DONE;
                end else begin
                  current_group_q <= next_group;
                  current_lane_q <= '0;
                  read_kind_q <= READ_INDEX;
                  state_q <= STATE_VRF_READ_REQ;
                end
              end else begin
                current_lane_q <= current_lane_q + LANE_ID_W'(1);
                state_q <= STATE_INDEXED_DMEM_REQ;
              end
            end
          end
        end

        STATE_DONE: begin
          if (completion_fire) state_q <= STATE_IDLE;
        end

        default: begin
          protocol_error_q <= 1'b1;
          completion_status_q <= VSP_MEM_CPL_VRF_ERROR;
          completion_failed_mask_q <= remaining_group_mask_q;
          state_q <= STATE_DONE;
        end
      endcase
    end
  end

  initial begin
    if (GROUP_COUNT < 1 || GROUP_COUNT > 16)
      $error("GROUP_COUNT must be in the architectural range 1..16");
    if ((GROUP_COUNT * VRF_ROW_BYTES) > 64)
      $error("indexed vector domain must not exceed 64 bytes");
    if (VRF_ROW_BYTES != 4)
      $error("the current memory profile requires one four-byte SIMD4 row");
    if (VRF_ROWS < 1) $error("VRF_ROWS must be positive");
    if (EXEC_CONTEXT_COUNT < 1)
      $error("EXEC_CONTEXT_COUNT must be positive");
    if (CMD_TAG_W < 1 || MEM_EADDR_W < 8 || MEM_OFFSET_W < 1 ||
        ADDR_CONTEXT_W < 1)
      $error("command tag, address, offset, and context widths are invalid");
    if (MEM_OFFSET_W > EADDR_EXT_W)
      $error("MEM_OFFSET_W must not exceed MEM_EADDR_W+1");
    if (GROUP_ID_W != ((GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT)))
      $error("GROUP_ID_W does not match GROUP_COUNT");
    if (VRF_ROW_ADDR_W != ((VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS)))
      $error("VRF_ROW_ADDR_W does not match VRF_ROWS");
    if (EXEC_CONTEXT_ID_W != ((EXEC_CONTEXT_COUNT <= 2) ? 1 :
                              $clog2(EXEC_CONTEXT_COUNT)))
      $error("EXEC_CONTEXT_ID_W does not match EXEC_CONTEXT_COUNT");
    if (SPAN_BYTES_W != (((GROUP_COUNT*VRF_ROW_BYTES) <= 1) ? 1 :
                        $clog2((GROUP_COUNT*VRF_ROW_BYTES) + 1)))
      $error("SPAN_BYTES_W does not cover the maximum command span");
  end
endmodule
