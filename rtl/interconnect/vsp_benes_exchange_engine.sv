module vsp_benes_exchange_engine #(
  // One command is one physical row pass.  The first profile routes one
  // 4-byte VRF row per SIMD4 group; longer logical vectors and fanout are
  // sequencer-visible multi-pass operations.
  parameter int GROUP_COUNT        = 4,
  parameter int VRF_ROW_BYTES      = 4,
  parameter int VRF_ROWS           = 16,
  parameter int EXEC_CONTEXT_COUNT = 2,
  parameter int CMD_TAG_W          = 8,
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int VRF_ROW_ADDR_W = (VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS),
  parameter int EXEC_CONTEXT_ID_W = (EXEC_CONTEXT_COUNT <= 2) ? 1 :
                                    $clog2(EXEC_CONTEXT_COUNT),
  parameter int BENES_CTRL_W =
      (((2*$clog2(GROUP_COUNT))-1)*(GROUP_COUNT/2))
) (
  input  logic clk_i,
  // Reset belongs to the same transaction domain as both VRF child
  // endpoints.  Because the interface has no epoch, an in-flight reset must
  // also discard any old child completion/response.
  input  logic rst_ni,

  // Canonical EXCHANGE parent action.  The route fields are the resolved,
  // immutable snapshot of an external route-register entry; they are not an
  // instruction immediate.  src_byte_mask is grouped as four byte-valid bits
  // per source group.  The expected destination mask is cached scheduling
  // metadata and is checked against the actual routed valid bits before any
  // source read or destination write is allowed to commit.
  input  logic                                cmd_valid_i,
  output logic                                cmd_ready_o,
  input  logic [EXEC_CONTEXT_ID_W-1:0]        cmd_exec_context_i,
  input  logic [CMD_TAG_W-1:0]                cmd_tag_i,
  input  logic [VRF_ROW_ADDR_W-1:0]           cmd_src_vrf_row_i,
  input  logic [VRF_ROW_ADDR_W-1:0]           cmd_dst_vrf_row_i,
  input  logic                                cmd_route_entry_valid_i,
  input  logic [BENES_CTRL_W-1:0]             cmd_route_ctrl_i,
  input  logic [GROUP_COUNT-1:0]              cmd_src_group_mask_i,
  input  logic [(GROUP_COUNT*VRF_ROW_BYTES)-1:0]
                                                 cmd_src_byte_mask_i,
  input  logic [GROUP_COUNT-1:0]              cmd_expected_dst_group_mask_i,

  // Abstract single-row VRF read child.  Every accepted request must return
  // one completion and one data response, in either order, including on
  // error.  The first engine serializes reads, so only one group is live here.
  output logic                                vrf_read_valid_o,
  input  logic                                vrf_read_ready_i,
  output logic [EXEC_CONTEXT_ID_W-1:0]        vrf_read_exec_context_o,
  output logic [CMD_TAG_W-1:0]                vrf_read_tag_o,
  output logic [GROUP_ID_W-1:0]               vrf_read_group_o,
  output logic [VRF_ROW_ADDR_W-1:0]           vrf_read_row_o,
  output logic [VRF_ROW_BYTES-1:0]            vrf_read_mask_o,
  input  logic                                vrf_read_cpl_valid_i,
  output logic                                vrf_read_cpl_ready_o,
  input  logic [EXEC_CONTEXT_ID_W-1:0]        vrf_read_cpl_exec_context_i,
  input  logic [CMD_TAG_W-1:0]                vrf_read_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]               vrf_read_cpl_group_i,
  input  logic                                vrf_read_cpl_error_i,
  input  logic                                vrf_read_rsp_valid_i,
  output logic                                vrf_read_rsp_ready_o,
  input  logic [EXEC_CONTEXT_ID_W-1:0]        vrf_read_rsp_exec_context_i,
  input  logic [CMD_TAG_W-1:0]                vrf_read_rsp_tag_i,
  input  logic [GROUP_ID_W-1:0]               vrf_read_rsp_group_i,
  input  logic [(VRF_ROW_BYTES*8)-1:0]        vrf_read_rsp_data_i,
  input  logic [VRF_ROW_BYTES-1:0]            vrf_read_rsp_mask_i,
  input  logic                                vrf_read_rsp_error_i,

  // One masked VRF write child.  Output groups are submitted in increasing
  // group order and each accepted write is retired before the next begins.
  output logic                                vrf_write_valid_o,
  input  logic                                vrf_write_ready_i,
  output logic [EXEC_CONTEXT_ID_W-1:0]        vrf_write_exec_context_o,
  output logic [CMD_TAG_W-1:0]                vrf_write_tag_o,
  output logic [GROUP_ID_W-1:0]               vrf_write_group_o,
  output logic [VRF_ROW_ADDR_W-1:0]           vrf_write_row_o,
  output logic [VRF_ROW_BYTES-1:0]            vrf_write_mask_o,
  output logic [(VRF_ROW_BYTES*8)-1:0]        vrf_write_data_o,
  input  logic                                vrf_write_cpl_valid_i,
  output logic                                vrf_write_cpl_ready_o,
  input  logic [EXEC_CONTEXT_ID_W-1:0]        vrf_write_cpl_exec_context_i,
  input  logic [CMD_TAG_W-1:0]                vrf_write_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]               vrf_write_cpl_group_i,
  input  logic                                vrf_write_cpl_error_i,

  // Exactly one lossless parent completion is produced per accepted command.
  // completed_group_mask counts successful destination writes.  A read-side
  // failure reports its source group in failed_group_mask; a write-side
  // failure reports its destination group.  Stop-on-first means no later
  // destination is attempted after the first failure.
  output logic                                cpl_valid_o,
  input  logic                                cpl_ready_i,
  output logic [EXEC_CONTEXT_ID_W-1:0]        cpl_exec_context_o,
  output logic [CMD_TAG_W-1:0]                cpl_tag_o,
  output logic [vsp_pkg::VSP_EXCHANGE_CPL_STATUS_W-1:0]
                                                 cpl_status_o,
  output logic [GROUP_COUNT-1:0]              cpl_requested_src_group_mask_o,
  output logic [GROUP_COUNT-1:0]              cpl_requested_dst_group_mask_o,
  output logic [GROUP_COUNT-1:0]              cpl_completed_group_mask_o,
  output logic [GROUP_COUNT-1:0]              cpl_failed_group_mask_o,
  output logic                                cpl_partial_o,

  output logic                                busy_o,
  // A protocol fault blocks new commands.  Clear is honored only in IDLE and
  // is not itself a flush: the controller must first drain/flush both child
  // endpoints, or use the shared transaction-domain reset.
  input  logic                                protocol_error_clear_i,
  output logic                                protocol_error_o
);
  import vsp_pkg::*;

  localparam int VRF_ROW_W = VRF_ROW_BYTES * 8;
  localparam int BUNDLE_W = VRF_ROW_W + VRF_ROW_BYTES;

  typedef enum logic [3:0] {
    STATE_IDLE,
    STATE_READ_REQ,
    STATE_READ_WAIT,
    STATE_ROUTE_LATCH,
    STATE_WRITE_REQ,
    STATE_WRITE_CPL,
    STATE_DONE
  } state_e;

  state_e state_q;

  logic [EXEC_CONTEXT_ID_W-1:0] command_exec_context_q;
  logic [CMD_TAG_W-1:0] command_tag_q;
  logic [VRF_ROW_ADDR_W-1:0] command_src_vrf_row_q;
  logic [VRF_ROW_ADDR_W-1:0] command_dst_vrf_row_q;
  logic [BENES_CTRL_W-1:0] command_route_ctrl_q;
  logic [GROUP_COUNT-1:0] requested_src_group_mask_q;
  logic [GROUP_COUNT-1:0] requested_dst_group_mask_q;
  logic [(GROUP_COUNT*VRF_ROW_BYTES)-1:0] command_src_byte_mask_q;

  logic [GROUP_COUNT-1:0] remaining_src_group_mask_q;
  logic [GROUP_COUNT-1:0] remaining_dst_group_mask_q;
  logic [GROUP_COUNT-1:0] completed_group_mask_q;
  logic [GROUP_COUNT-1:0] failed_group_mask_q;
  logic [GROUP_ID_W-1:0] current_group_q;
  logic [VSP_EXCHANGE_CPL_STATUS_W-1:0] completion_status_q;

  logic [(GROUP_COUNT*VRF_ROW_W)-1:0] captured_rows_q;
  logic [(GROUP_COUNT*BUNDLE_W)-1:0] routed_rows_q;
  logic [VRF_ROW_W-1:0] pending_read_data_q;
  logic read_cpl_seen_q;
  logic read_rsp_seen_q;
  logic read_child_error_q;
  logic read_protocol_error_q;
  logic protocol_error_q;

  logic [(GROUP_COUNT*VRF_ROW_BYTES)-1:0] command_routed_valid;
  logic [GROUP_COUNT-1:0] command_derived_src_group_mask;
  logic [GROUP_COUNT-1:0] command_derived_dst_group_mask;
  logic command_request_error;
  logic command_route_error;

  logic [(GROUP_COUNT*BUNDLE_W)-1:0] network_input;
  logic [(GROUP_COUNT*BUNDLE_W)-1:0] network_output;
  logic [GROUP_COUNT-1:0] network_dst_group_mask;

  logic [GROUP_COUNT-1:0] current_group_onehot;
  logic [GROUP_COUNT-1:0] remaining_src_after_current;
  logic [GROUP_COUNT-1:0] remaining_dst_after_current;
  logic [GROUP_COUNT-1:0] completed_after_current;
  logic [GROUP_ID_W-1:0] next_src_group;
  logic [GROUP_ID_W-1:0] next_dst_group;
  logic [VRF_ROW_BYTES-1:0] current_src_byte_mask;
  logic [VRF_ROW_BYTES-1:0] current_dst_byte_mask;
  logic [VRF_ROW_W-1:0] current_dst_data;

  logic command_fire;
  logic vrf_read_fire;
  logic vrf_read_cpl_fire;
  logic vrf_read_rsp_fire;
  logic vrf_write_fire;
  logic vrf_write_cpl_fire;
  logic completion_fire;

  logic vrf_read_cpl_mismatch;
  logic vrf_read_rsp_mismatch;
  logic vrf_write_cpl_mismatch;
  logic read_cpl_seen_after;
  logic read_rsp_seen_after;
  logic read_child_error_after;
  logic read_protocol_error_after;
  logic [VRF_ROW_W-1:0] read_data_after;
  logic protocol_fault;

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

  // This narrow shadow route lets admission verify the destination resource
  // mask before the data transaction starts.  It is the same one-to-one
  // topology as the 36-bit data network and cannot introduce broadcast.
  benes_network #(
    .PORTS(GROUP_COUNT),
    .DATA_W(VRF_ROW_BYTES)
  ) u_command_valid_route (
    .data_i(cmd_src_byte_mask_i),
    .ctrl_i(cmd_route_ctrl_i),
    .data_o(command_routed_valid)
  );

  always_comb begin
    command_derived_src_group_mask = '0;
    command_derived_dst_group_mask = '0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      command_derived_src_group_mask[group] =
          |cmd_src_byte_mask_i[(group*VRF_ROW_BYTES) +: VRF_ROW_BYTES];
      command_derived_dst_group_mask[group] =
          |command_routed_valid[(group*VRF_ROW_BYTES) +: VRF_ROW_BYTES];
    end

    command_request_error =
        (int'(cmd_exec_context_i) >= EXEC_CONTEXT_COUNT) ||
        (int'(cmd_src_vrf_row_i) >= VRF_ROWS) ||
        (int'(cmd_dst_vrf_row_i) >= VRF_ROWS);
    command_route_error = !cmd_route_entry_valid_i ||
        !(|cmd_src_group_mask_i) ||
        !(|cmd_expected_dst_group_mask_i) ||
        (command_derived_src_group_mask != cmd_src_group_mask_i) ||
        (command_derived_dst_group_mask !=
         cmd_expected_dst_group_mask_i);
  end

  always_comb begin
    network_input = '0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      network_input[(group*BUNDLE_W) +: VRF_ROW_W] =
          captured_rows_q[(group*VRF_ROW_W) +: VRF_ROW_W];
      network_input[(group*BUNDLE_W)+VRF_ROW_W +: VRF_ROW_BYTES] =
          command_src_byte_mask_q[(group*VRF_ROW_BYTES) +:
                                  VRF_ROW_BYTES];
    end
  end

  benes_network #(
    .PORTS(GROUP_COUNT),
    .DATA_W(BUNDLE_W)
  ) u_data_route (
    .data_i(network_input),
    .ctrl_i(command_route_ctrl_q),
    .data_o(network_output)
  );

  always_comb begin
    network_dst_group_mask = '0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      network_dst_group_mask[group] =
          |network_output[(group*BUNDLE_W)+VRF_ROW_W +: VRF_ROW_BYTES];
    end
  end

  always_comb begin
    current_group_onehot = '0;
    if (int'(current_group_q) < GROUP_COUNT) begin
      current_group_onehot[int'(current_group_q)] = 1'b1;
    end
    remaining_src_after_current =
        remaining_src_group_mask_q & ~current_group_onehot;
    remaining_dst_after_current =
        remaining_dst_group_mask_q & ~current_group_onehot;
    completed_after_current = completed_group_mask_q | current_group_onehot;
    next_src_group = first_group(remaining_src_after_current);
    next_dst_group = first_group(remaining_dst_after_current);

    current_src_byte_mask = '0;
    current_dst_byte_mask = '0;
    current_dst_data = '0;
    if (int'(current_group_q) < GROUP_COUNT) begin
      current_src_byte_mask =
          command_src_byte_mask_q[(int'(current_group_q)*VRF_ROW_BYTES) +:
                                  VRF_ROW_BYTES];
      current_dst_data =
          routed_rows_q[(int'(current_group_q)*BUNDLE_W) +: VRF_ROW_W];
      current_dst_byte_mask =
          routed_rows_q[(int'(current_group_q)*BUNDLE_W)+VRF_ROW_W +:
                        VRF_ROW_BYTES];
    end
  end

  always_comb begin
    cmd_ready_o = rst_ni && (state_q == STATE_IDLE) && !protocol_error_q;
    busy_o = state_q != STATE_IDLE;

    vrf_read_valid_o = 1'b0;
    vrf_read_exec_context_o = command_exec_context_q;
    vrf_read_tag_o = command_tag_q;
    vrf_read_group_o = current_group_q;
    vrf_read_row_o = command_src_vrf_row_q;
    vrf_read_mask_o = current_src_byte_mask;
    vrf_read_cpl_ready_o = 1'b0;
    vrf_read_rsp_ready_o = 1'b0;

    vrf_write_valid_o = 1'b0;
    vrf_write_exec_context_o = command_exec_context_q;
    vrf_write_tag_o = command_tag_q;
    vrf_write_group_o = current_group_q;
    vrf_write_row_o = command_dst_vrf_row_q;
    vrf_write_mask_o = current_dst_byte_mask;
    vrf_write_data_o = current_dst_data;
    vrf_write_cpl_ready_o = 1'b0;

    unique case (state_q)
      STATE_READ_REQ: begin
        vrf_read_valid_o = 1'b1;
      end
      STATE_READ_WAIT: begin
        vrf_read_cpl_ready_o = !read_cpl_seen_q;
        vrf_read_rsp_ready_o = !read_rsp_seen_q;
      end
      STATE_WRITE_REQ: begin
        vrf_write_valid_o = 1'b1;
      end
      STATE_WRITE_CPL: begin
        vrf_write_cpl_ready_o = 1'b1;
      end
      default: begin
      end
    endcase
  end

  assign cpl_valid_o = state_q == STATE_DONE;
  assign cpl_exec_context_o = command_exec_context_q;
  assign cpl_tag_o = command_tag_q;
  assign cpl_status_o = completion_status_q;
  assign cpl_requested_src_group_mask_o = requested_src_group_mask_q;
  assign cpl_requested_dst_group_mask_o = requested_dst_group_mask_q;
  assign cpl_completed_group_mask_o = completed_group_mask_q;
  assign cpl_failed_group_mask_o = failed_group_mask_q;
  assign cpl_partial_o = (completion_status_q != VSP_EXCHANGE_CPL_OK) &&
                         (|completed_group_mask_q);
  assign protocol_error_o = protocol_error_q;

  assign command_fire = cmd_valid_i && cmd_ready_o;
  assign vrf_read_fire = vrf_read_valid_o && vrf_read_ready_i;
  assign vrf_read_cpl_fire = vrf_read_cpl_valid_i &&
                              vrf_read_cpl_ready_o;
  assign vrf_read_rsp_fire = vrf_read_rsp_valid_i &&
                              vrf_read_rsp_ready_o;
  assign vrf_write_fire = vrf_write_valid_o && vrf_write_ready_i;
  assign vrf_write_cpl_fire = vrf_write_cpl_valid_i &&
                               vrf_write_cpl_ready_o;
  assign completion_fire = cpl_valid_o && cpl_ready_i;

  assign vrf_read_cpl_mismatch =
      (vrf_read_cpl_exec_context_i != command_exec_context_q) ||
      (vrf_read_cpl_tag_i != command_tag_q) ||
      (vrf_read_cpl_group_i != current_group_q);
  assign vrf_read_rsp_mismatch =
      (vrf_read_rsp_exec_context_i != command_exec_context_q) ||
      (vrf_read_rsp_tag_i != command_tag_q) ||
      (vrf_read_rsp_group_i != current_group_q) ||
      (!vrf_read_rsp_error_i &&
       ((vrf_read_rsp_mask_i & current_src_byte_mask) !=
        current_src_byte_mask));
  assign vrf_write_cpl_mismatch =
      (vrf_write_cpl_exec_context_i != command_exec_context_q) ||
      (vrf_write_cpl_tag_i != command_tag_q) ||
      (vrf_write_cpl_group_i != current_group_q);

  assign read_cpl_seen_after = read_cpl_seen_q || vrf_read_cpl_fire;
  assign read_rsp_seen_after = read_rsp_seen_q || vrf_read_rsp_fire;
  assign read_child_error_after = read_child_error_q ||
      (vrf_read_cpl_fire && vrf_read_cpl_error_i) ||
      (vrf_read_rsp_fire && vrf_read_rsp_error_i);
  assign read_protocol_error_after = read_protocol_error_q ||
      (vrf_read_cpl_fire && vrf_read_cpl_mismatch) ||
      (vrf_read_rsp_fire && vrf_read_rsp_mismatch);
  assign read_data_after = vrf_read_rsp_fire ? vrf_read_rsp_data_i :
                                               pending_read_data_q;
  assign protocol_fault =
      (vrf_read_cpl_fire && vrf_read_cpl_mismatch) ||
      (vrf_read_rsp_fire && vrf_read_rsp_mismatch) ||
      (vrf_write_cpl_fire && vrf_write_cpl_mismatch);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= STATE_IDLE;
      command_exec_context_q <= '0;
      command_tag_q <= '0;
      command_src_vrf_row_q <= '0;
      command_dst_vrf_row_q <= '0;
      command_route_ctrl_q <= '0;
      requested_src_group_mask_q <= '0;
      requested_dst_group_mask_q <= '0;
      command_src_byte_mask_q <= '0;
      remaining_src_group_mask_q <= '0;
      remaining_dst_group_mask_q <= '0;
      completed_group_mask_q <= '0;
      failed_group_mask_q <= '0;
      current_group_q <= '0;
      completion_status_q <= VSP_EXCHANGE_CPL_OK;
      captured_rows_q <= '0;
      routed_rows_q <= '0;
      pending_read_data_q <= '0;
      read_cpl_seen_q <= 1'b0;
      read_rsp_seen_q <= 1'b0;
      read_child_error_q <= 1'b0;
      read_protocol_error_q <= 1'b0;
      protocol_error_q <= 1'b0;
    end else begin
      if (protocol_error_clear_i && (state_q == STATE_IDLE))
        protocol_error_q <= 1'b0;
      if (protocol_fault) protocol_error_q <= 1'b1;

      unique case (state_q)
        STATE_IDLE: begin
          if (command_fire) begin
            command_exec_context_q <= cmd_exec_context_i;
            command_tag_q <= cmd_tag_i;
            command_src_vrf_row_q <= cmd_src_vrf_row_i;
            command_dst_vrf_row_q <= cmd_dst_vrf_row_i;
            command_route_ctrl_q <= cmd_route_ctrl_i;
            requested_src_group_mask_q <= cmd_src_group_mask_i;
            requested_dst_group_mask_q <=
                cmd_expected_dst_group_mask_i;
            command_src_byte_mask_q <= cmd_src_byte_mask_i;
            remaining_src_group_mask_q <= cmd_src_group_mask_i;
            remaining_dst_group_mask_q <=
                cmd_expected_dst_group_mask_i;
            completed_group_mask_q <= '0;
            failed_group_mask_q <= '0;
            current_group_q <= first_group(cmd_src_group_mask_i);
            completion_status_q <= VSP_EXCHANGE_CPL_OK;
            captured_rows_q <= '0;
            routed_rows_q <= '0;
            pending_read_data_q <= '0;
            read_cpl_seen_q <= 1'b0;
            read_rsp_seen_q <= 1'b0;
            read_child_error_q <= 1'b0;
            read_protocol_error_q <= 1'b0;

            if (command_request_error) begin
              completion_status_q <= VSP_EXCHANGE_CPL_BAD_REQUEST;
              state_q <= STATE_DONE;
            end else if (command_route_error) begin
              completion_status_q <= VSP_EXCHANGE_CPL_BAD_ROUTE;
              state_q <= STATE_DONE;
            end else begin
              state_q <= STATE_READ_REQ;
            end
          end
        end

        STATE_READ_REQ: begin
          if (vrf_read_fire) begin
            read_cpl_seen_q <= 1'b0;
            read_rsp_seen_q <= 1'b0;
            read_child_error_q <= 1'b0;
            read_protocol_error_q <= 1'b0;
            pending_read_data_q <= '0;
            state_q <= STATE_READ_WAIT;
          end
        end

        STATE_READ_WAIT: begin
          if (vrf_read_cpl_fire) read_cpl_seen_q <= 1'b1;
          if (vrf_read_rsp_fire) begin
            read_rsp_seen_q <= 1'b1;
            pending_read_data_q <= vrf_read_rsp_data_i;
          end
          if (vrf_read_cpl_fire && vrf_read_cpl_error_i)
            read_child_error_q <= 1'b1;
          if (vrf_read_rsp_fire && vrf_read_rsp_error_i)
            read_child_error_q <= 1'b1;
          if ((vrf_read_cpl_fire && vrf_read_cpl_mismatch) ||
              (vrf_read_rsp_fire && vrf_read_rsp_mismatch)) begin
            read_protocol_error_q <= 1'b1;
          end

          if (read_cpl_seen_after && read_rsp_seen_after) begin
            if (read_protocol_error_after) begin
              completion_status_q <= VSP_EXCHANGE_CPL_PROTOCOL_ERROR;
              failed_group_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else if (read_child_error_after) begin
              completion_status_q <= VSP_EXCHANGE_CPL_VRF_READ_ERROR;
              failed_group_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              captured_rows_q[(int'(current_group_q)*VRF_ROW_W) +:
                              VRF_ROW_W] <= read_data_after;
              remaining_src_group_mask_q <= remaining_src_after_current;
              if (|remaining_src_after_current) begin
                current_group_q <= next_src_group;
                state_q <= STATE_READ_REQ;
              end else begin
                state_q <= STATE_ROUTE_LATCH;
              end
            end
          end
        end

        STATE_ROUTE_LATCH: begin
          if (network_dst_group_mask != requested_dst_group_mask_q) begin
            protocol_error_q <= 1'b1;
            completion_status_q <= VSP_EXCHANGE_CPL_PROTOCOL_ERROR;
            failed_group_mask_q <= requested_dst_group_mask_q;
            state_q <= STATE_DONE;
          end else begin
            routed_rows_q <= network_output;
            remaining_dst_group_mask_q <= requested_dst_group_mask_q;
            current_group_q <= first_group(requested_dst_group_mask_q);
            state_q <= STATE_WRITE_REQ;
          end
        end

        STATE_WRITE_REQ: begin
          if (vrf_write_fire) state_q <= STATE_WRITE_CPL;
        end

        STATE_WRITE_CPL: begin
          if (vrf_write_cpl_fire) begin
            if (vrf_write_cpl_mismatch) begin
              completion_status_q <= VSP_EXCHANGE_CPL_PROTOCOL_ERROR;
              failed_group_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else if (vrf_write_cpl_error_i) begin
              completion_status_q <= VSP_EXCHANGE_CPL_VRF_WRITE_ERROR;
              failed_group_mask_q <= current_group_onehot;
              state_q <= STATE_DONE;
            end else begin
              completed_group_mask_q <= completed_after_current;
              remaining_dst_group_mask_q <= remaining_dst_after_current;
              if (|remaining_dst_after_current) begin
                current_group_q <= next_dst_group;
                state_q <= STATE_WRITE_REQ;
              end else begin
                completion_status_q <= VSP_EXCHANGE_CPL_OK;
                state_q <= STATE_DONE;
              end
            end
          end
        end

        STATE_DONE: begin
          if (completion_fire) state_q <= STATE_IDLE;
        end

        default: begin
          protocol_error_q <= 1'b1;
          completion_status_q <= VSP_EXCHANGE_CPL_PROTOCOL_ERROR;
          failed_group_mask_q <= remaining_dst_group_mask_q;
          state_q <= STATE_DONE;
        end
      endcase
    end
  end

  initial begin
    if (GROUP_COUNT < 2 ||
        (GROUP_COUNT & (GROUP_COUNT - 1)) != 0) begin
      $error("GROUP_COUNT must be a power of two and at least two");
    end
    if (VRF_ROW_BYTES != 4) begin
      $error("the first exchange profile requires a 4-byte VRF row");
    end
    if (VRF_ROWS < 1 || EXEC_CONTEXT_COUNT < 1 || CMD_TAG_W < 1) begin
      $error("VRF rows, context count, and tag width must be positive");
    end
    if (GROUP_ID_W != ((GROUP_COUNT <= 2) ? 1 :
                       $clog2(GROUP_COUNT))) begin
      $error("GROUP_ID_W does not match GROUP_COUNT");
    end
    if (VRF_ROW_ADDR_W != ((VRF_ROWS <= 2) ? 1 :
                           $clog2(VRF_ROWS))) begin
      $error("VRF_ROW_ADDR_W does not match VRF_ROWS");
    end
    if (EXEC_CONTEXT_ID_W != ((EXEC_CONTEXT_COUNT <= 2) ? 1 :
                              $clog2(EXEC_CONTEXT_COUNT))) begin
      $error("EXEC_CONTEXT_ID_W does not match EXEC_CONTEXT_COUNT");
    end
    if (BENES_CTRL_W !=
        (((2*$clog2(GROUP_COUNT))-1)*(GROUP_COUNT/2))) begin
      $error("BENES_CTRL_W does not match GROUP_COUNT");
    end
  end
endmodule
