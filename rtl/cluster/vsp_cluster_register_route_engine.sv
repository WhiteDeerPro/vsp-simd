// Blocking VRF-backed register gather for one route domain.
//
// The first deployed profile is four SIMD4 groups: four source rows and four
// index rows are snapshotted through the shared VRF transaction boundary,
// routed as one 16-byte vector, then committed as four destination rows.  The
// route result is registered between the complete snapshot and the first
// destination write, giving capture, route, and commit explicit timing and
// ownership boundaries.  The serial transport is an integration choice, not
// an architectural promise; the snapshot/gather/commit contract also admits a
// later parallel RF port.
module vsp_cluster_register_route_engine #(
  parameter int GROUP_COUNT       = 4,
  parameter int LANES_PER_GROUP   = 4,
  parameter int ELEM_W            = 8,
  parameter int INDEX_ELEM_W      = 8,
  parameter int VRF_ROWS          = 16,
  parameter int CONTEXT_COUNT     = 2,
  parameter int TAG_W             = 8,
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int VRF_ADDR_W = (VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS),
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT)
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,

  input  logic                              cmd_valid_i,
  output logic                              cmd_ready_o,
  input  logic                              cmd_legal_i,
  input  logic [CONTEXT_W-1:0]              cmd_context_i,
  input  logic [TAG_W-1:0]                  cmd_tag_i,
  // Source capture and destination/index capture are separate domains for a
  // paired DEP_OUT/DEP_IN wave. LOCAL and role-complete DEP_INOUT simply drive
  // the same mask on both inputs.
  input  logic [GROUP_COUNT-1:0]            cmd_source_group_mask_i,
  input  logic [GROUP_COUNT-1:0]            cmd_destination_group_mask_i,
  input  logic [VRF_ADDR_W-1:0]             cmd_source_row_i,
  input  logic [VRF_ADDR_W-1:0]             cmd_index_row_i,
  input  logic [VRF_ADDR_W-1:0]             cmd_destination_row_i,
  input  logic [1:0]                        cmd_io_mode_i,

  output logic                              cpl_valid_o,
  input  logic                              cpl_ready_i,
  output logic [CONTEXT_W-1:0]              cpl_context_o,
  output logic [TAG_W-1:0]                  cpl_tag_o,
  output logic [GROUP_COUNT-1:0]            cpl_group_mask_o,
  output logic                              cpl_illegal_o,
  output logic [GROUP_COUNT-1:0]            cpl_illegal_group_mask_o,
  output logic                              cpl_rejected_o,
  output logic                              cpl_empty_mask_o,
  output logic [(GROUP_COUNT*LANES_PER_GROUP)-1:0]
                                                   cpl_invalid_element_mask_o,

  output logic                              vrf_read_valid_o,
  input  logic                              vrf_read_ready_i,
  output logic [CONTEXT_W-1:0]              vrf_read_context_o,
  output logic [TAG_W-1:0]                  vrf_read_tag_o,
  output logic [GROUP_ID_W-1:0]             vrf_read_group_o,
  output logic [VRF_ADDR_W-1:0]             vrf_read_row_o,
  output logic [LANES_PER_GROUP-1:0]        vrf_read_mask_o,

  input  logic                              vrf_read_cpl_valid_i,
  output logic                              vrf_read_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]              vrf_read_cpl_context_i,
  input  logic [TAG_W-1:0]                  vrf_read_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_read_cpl_group_i,
  input  logic                              vrf_read_cpl_error_i,

  input  logic                              vrf_read_rsp_valid_i,
  output logic                              vrf_read_rsp_ready_o,
  input  logic [CONTEXT_W-1:0]              vrf_read_rsp_context_i,
  input  logic [TAG_W-1:0]                  vrf_read_rsp_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_read_rsp_group_i,
  input  logic [(LANES_PER_GROUP*ELEM_W)-1:0]
                                                   vrf_read_rsp_data_i,
  input  logic [LANES_PER_GROUP-1:0]        vrf_read_rsp_mask_i,
  input  logic                              vrf_read_rsp_error_i,

  output logic                              vrf_write_valid_o,
  input  logic                              vrf_write_ready_i,
  output logic [CONTEXT_W-1:0]              vrf_write_context_o,
  output logic [TAG_W-1:0]                  vrf_write_tag_o,
  output logic [GROUP_ID_W-1:0]             vrf_write_group_o,
  output logic [VRF_ADDR_W-1:0]             vrf_write_row_o,
  output logic [LANES_PER_GROUP-1:0]        vrf_write_mask_o,
  output logic [(LANES_PER_GROUP*ELEM_W)-1:0]
                                                   vrf_write_data_o,

  input  logic                              vrf_write_cpl_valid_i,
  output logic                              vrf_write_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]              vrf_write_cpl_context_i,
  input  logic [TAG_W-1:0]                  vrf_write_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             vrf_write_cpl_group_i,
  input  logic                              vrf_write_cpl_error_i,

  output logic                              busy_o,
  input  logic                              protocol_error_clear_i,
  output logic                              protocol_error_o
);
  localparam int TOTAL_LANES = GROUP_COUNT * LANES_PER_GROUP;
  localparam int ROW_W = LANES_PER_GROUP * ELEM_W;
  localparam int VECTOR_W = TOTAL_LANES * ELEM_W;

  typedef enum logic [2:0] {
    STATE_IDLE,
    STATE_READ_REQUEST,
    STATE_READ_RESPONSE,
    STATE_ROUTE_RESULT,
    STATE_WRITE_REQUEST,
    STATE_WRITE_RESPONSE,
    STATE_COMPLETE
  } route_state_e;

  route_state_e state_q;
  logic read_index_q;
  logic [GROUP_ID_W-1:0] group_q;
  logic [CONTEXT_W-1:0] context_q;
  logic [TAG_W-1:0] tag_q;
  logic [GROUP_COUNT-1:0] group_mask_q;
  logic [GROUP_COUNT-1:0] source_group_mask_q;
  logic [GROUP_COUNT-1:0] destination_group_mask_q;
  logic [VRF_ADDR_W-1:0] source_row_q;
  logic [VRF_ADDR_W-1:0] index_row_q;
  logic [VRF_ADDR_W-1:0] destination_row_q;

  logic [VECTOR_W-1:0] source_data_q;
  logic [(TOTAL_LANES*INDEX_ELEM_W)-1:0] index_data_q;
  logic [TOTAL_LANES-1:0] source_valid_q;
  logic [TOTAL_LANES-1:0] destination_active_q;
  logic [GROUP_COUNT-1:0] error_group_mask_q;

  logic read_cpl_seen_q;
  logic read_rsp_seen_q;
  logic read_cpl_error_q;
  logic read_rsp_error_q;
  logic [ROW_W-1:0] read_rsp_data_q;
  logic [LANES_PER_GROUP-1:0] read_rsp_mask_q;

  logic cpl_valid_q;
  logic cpl_illegal_q;
  logic cpl_rejected_q;
  logic cpl_empty_mask_q;
  logic [TOTAL_LANES-1:0] cpl_invalid_mask_q;
  logic protocol_error_q;

  logic [VECTOR_W-1:0] gathered_data;
  logic [TOTAL_LANES-1:0] gathered_write_mask;
  logic [TOTAL_LANES-1:0] gathered_invalid_mask;
  logic [VECTOR_W-1:0] route_result_data_q;
  logic [TOTAL_LANES-1:0] route_result_write_mask_q;

  logic read_cpl_fire;
  logic read_rsp_fire;
  logic read_cpl_seen_next;
  logic read_rsp_seen_next;
  logic read_current_error;
  logic [ROW_W-1:0] read_rsp_data_next;
  logic [LANES_PER_GROUP-1:0] read_rsp_mask_next;
  logic read_identity_error;
  logic write_cpl_fire;
  logic write_identity_error;

  logic first_destination_group_valid;
  logic [GROUP_ID_W-1:0] first_destination_group;
  logic next_source_group_valid;
  logic [GROUP_ID_W-1:0] next_source_group;
  logic next_destination_group_valid;
  logic [GROUP_ID_W-1:0] next_destination_group;

  always_comb begin
    first_destination_group_valid = 1'b0;
    first_destination_group = '0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (!first_destination_group_valid &&
          destination_group_mask_q[group]) begin
        first_destination_group_valid = 1'b1;
        first_destination_group = GROUP_ID_W'(group);
      end
    end

    next_source_group_valid = 1'b0;
    next_source_group = '0;
    next_destination_group_valid = 1'b0;
    next_destination_group = '0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (!next_source_group_valid && group > int'(group_q) &&
          source_group_mask_q[group]) begin
        next_source_group_valid = 1'b1;
        next_source_group = GROUP_ID_W'(group);
      end
      if (!next_destination_group_valid && group > int'(group_q) &&
          destination_group_mask_q[group]) begin
        next_destination_group_valid = 1'b1;
        next_destination_group = GROUP_ID_W'(group);
      end
    end
  end

  vsp_vrf_gather #(
    .LANES(TOTAL_LANES),
    .DATA_W(ELEM_W),
    .INDEX_ELEM_W(INDEX_ELEM_W)
  ) u_gather (
    .source_data_i(source_data_q),
    .source_valid_i(source_valid_q),
    .index_data_i(index_data_q),
    .destination_active_i(destination_active_q),
    .result_data_o(gathered_data),
    .result_write_mask_o(gathered_write_mask),
    .result_invalid_mask_o(gathered_invalid_mask)
  );

  assign cmd_ready_o = rst_ni && state_q == STATE_IDLE && !cpl_valid_q;
  assign busy_o = state_q != STATE_IDLE || cpl_valid_q;

  assign vrf_read_valid_o = state_q == STATE_READ_REQUEST;
  assign vrf_read_context_o = context_q;
  assign vrf_read_tag_o = tag_q;
  assign vrf_read_group_o = group_q;
  assign vrf_read_row_o = read_index_q ? index_row_q : source_row_q;
  assign vrf_read_mask_o = {LANES_PER_GROUP{1'b1}};

  assign vrf_read_cpl_ready_o = state_q == STATE_READ_RESPONSE &&
                                !read_cpl_seen_q;
  assign vrf_read_rsp_ready_o = state_q == STATE_READ_RESPONSE &&
                                !read_rsp_seen_q;
  assign read_cpl_fire = vrf_read_cpl_valid_i && vrf_read_cpl_ready_o;
  assign read_rsp_fire = vrf_read_rsp_valid_i && vrf_read_rsp_ready_o;
  assign read_cpl_seen_next = read_cpl_seen_q || read_cpl_fire;
  assign read_rsp_seen_next = read_rsp_seen_q || read_rsp_fire;
  assign read_identity_error =
      (read_cpl_fire &&
       (vrf_read_cpl_context_i != context_q ||
        vrf_read_cpl_tag_i != tag_q ||
        vrf_read_cpl_group_i != group_q)) ||
      (read_rsp_fire &&
       (vrf_read_rsp_context_i != context_q ||
        vrf_read_rsp_tag_i != tag_q ||
        vrf_read_rsp_group_i != group_q));
  assign read_current_error = read_cpl_error_q || read_rsp_error_q ||
      (read_cpl_fire && vrf_read_cpl_error_i) ||
      (read_rsp_fire && vrf_read_rsp_error_i) || read_identity_error;
  assign read_rsp_data_next = read_rsp_fire ? vrf_read_rsp_data_i :
                                              read_rsp_data_q;
  assign read_rsp_mask_next = read_rsp_fire ? vrf_read_rsp_mask_i :
                                              read_rsp_mask_q;

  assign vrf_write_valid_o = state_q == STATE_WRITE_REQUEST;
  assign vrf_write_context_o = context_q;
  assign vrf_write_tag_o = tag_q;
  assign vrf_write_group_o = group_q;
  assign vrf_write_row_o = destination_row_q;
  assign vrf_write_mask_o = route_result_write_mask_q[
      (group_q*LANES_PER_GROUP) +: LANES_PER_GROUP];
  assign vrf_write_data_o = route_result_data_q[(group_q*ROW_W) +: ROW_W];
  assign vrf_write_cpl_ready_o = state_q == STATE_WRITE_RESPONSE;
  assign write_cpl_fire = vrf_write_cpl_valid_i && vrf_write_cpl_ready_o;
  assign write_identity_error = write_cpl_fire &&
      (vrf_write_cpl_context_i != context_q ||
       vrf_write_cpl_tag_i != tag_q ||
       vrf_write_cpl_group_i != group_q);

  assign cpl_valid_o = cpl_valid_q;
  assign cpl_context_o = context_q;
  assign cpl_tag_o = tag_q;
  assign cpl_group_mask_o = group_mask_q;
  assign cpl_illegal_o = cpl_illegal_q;
  assign cpl_illegal_group_mask_o = error_group_mask_q;
  assign cpl_rejected_o = cpl_rejected_q;
  assign cpl_empty_mask_o = cpl_empty_mask_q;
  assign cpl_invalid_element_mask_o = cpl_invalid_mask_q;
  assign protocol_error_o = protocol_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= STATE_IDLE;
      read_index_q <= 1'b0;
      group_q <= '0;
      context_q <= '0;
      tag_q <= '0;
      group_mask_q <= '0;
      source_group_mask_q <= '0;
      destination_group_mask_q <= '0;
      source_row_q <= '0;
      index_row_q <= '0;
      destination_row_q <= '0;
      source_data_q <= '0;
      index_data_q <= '0;
      source_valid_q <= '0;
      destination_active_q <= '0;
      error_group_mask_q <= '0;
      read_cpl_seen_q <= 1'b0;
      read_rsp_seen_q <= 1'b0;
      read_cpl_error_q <= 1'b0;
      read_rsp_error_q <= 1'b0;
      read_rsp_data_q <= '0;
      read_rsp_mask_q <= '0;
      cpl_valid_q <= 1'b0;
      cpl_illegal_q <= 1'b0;
      cpl_rejected_q <= 1'b0;
      cpl_empty_mask_q <= 1'b0;
      cpl_invalid_mask_q <= '0;
      route_result_data_q <= '0;
      route_result_write_mask_q <= '0;
      protocol_error_q <= 1'b0;
    end else begin
      if (protocol_error_clear_i) protocol_error_q <= 1'b0;

      // Records outside the state that owns them are consumed by the arbiter
      // client only when ready is asserted.  Identity mismatches are still a
      // protocol error and make the parent command illegal.
      if (read_identity_error || write_identity_error)
        protocol_error_q <= 1'b1;

      unique case (state_q)
        STATE_IDLE: begin
          if (cmd_valid_i && cmd_ready_o) begin
            context_q <= cmd_context_i;
            tag_q <= cmd_tag_i;
            group_mask_q <= cmd_source_group_mask_i |
                            cmd_destination_group_mask_i;
            source_group_mask_q <= cmd_source_group_mask_i;
            destination_group_mask_q <= cmd_destination_group_mask_i;
            source_row_q <= cmd_source_row_i;
            index_row_q <= cmd_index_row_i;
            destination_row_q <= cmd_destination_row_i;
            source_data_q <= '0;
            index_data_q <= '0;
            source_valid_q <= '0;
            destination_active_q <= '0;
            error_group_mask_q <= '0;
            cpl_illegal_q <= 1'b0;
            cpl_rejected_q <= 1'b0;
            cpl_empty_mask_q <= 1'b0;
            cpl_invalid_mask_q <= '0;
            route_result_data_q <= '0;
            route_result_write_mask_q <= '0;

            for (int group = 0; group < GROUP_COUNT; group++) begin
              for (int lane = 0; lane < LANES_PER_GROUP; lane++) begin
                destination_active_q[(group*LANES_PER_GROUP) + lane] <=
                    cmd_destination_group_mask_i[group];
              end
            end

            // LOCAL is a complete route with no implicit peer. DEP_INOUT is
            // role-complete after the upstream cross-slot barrier has drained
            // older work. Partial DEP_OUT/DEP_IN descriptors are
            // useful only after a peer-aware admission stage has merged them;
            // never accept half a wave and wait for a future command here.
            if (!cmd_legal_i ||
                (cmd_io_mode_i != 2'b00 && cmd_io_mode_i != 2'b11) ||
                int'(cmd_context_i) >= CONTEXT_COUNT ||
                int'(cmd_source_row_i) >= VRF_ROWS ||
                int'(cmd_index_row_i) >= VRF_ROWS ||
                int'(cmd_destination_row_i) >= VRF_ROWS) begin
              cpl_illegal_q <= 1'b1;
              cpl_rejected_q <= 1'b1;
              error_group_mask_q <= cmd_source_group_mask_i |
                                    cmd_destination_group_mask_i;
              cpl_valid_q <= 1'b1;
              state_q <= STATE_COMPLETE;
            end else if (!(|cmd_source_group_mask_i) ||
                         !(|cmd_destination_group_mask_i)) begin
              cpl_rejected_q <= 1'b1;
              cpl_empty_mask_q <= 1'b1;
              cpl_valid_q <= 1'b1;
              state_q <= STATE_COMPLETE;
            end else begin
              // The command mask is nonempty; derive its first group directly
              // from the command rather than the just-written snapshot.
              for (int group = GROUP_COUNT-1; group >= 0; group--) begin
                if (cmd_source_group_mask_i[group])
                  group_q <= GROUP_ID_W'(group);
              end
              read_index_q <= 1'b0;
              state_q <= STATE_READ_REQUEST;
            end
          end
        end

        STATE_READ_REQUEST: begin
          if (vrf_read_valid_o && vrf_read_ready_i) begin
            read_cpl_seen_q <= 1'b0;
            read_rsp_seen_q <= 1'b0;
            read_cpl_error_q <= 1'b0;
            read_rsp_error_q <= 1'b0;
            read_rsp_data_q <= '0;
            read_rsp_mask_q <= '0;
            state_q <= STATE_READ_RESPONSE;
          end
        end

        STATE_READ_RESPONSE: begin
          if (read_cpl_fire) begin
            read_cpl_seen_q <= 1'b1;
            read_cpl_error_q <= vrf_read_cpl_error_i ||
                                read_identity_error;
          end
          if (read_rsp_fire) begin
            read_rsp_seen_q <= 1'b1;
            read_rsp_error_q <= vrf_read_rsp_error_i ||
                                read_identity_error;
            read_rsp_data_q <= vrf_read_rsp_data_i;
            read_rsp_mask_q <= vrf_read_rsp_mask_i;
          end

          if (read_cpl_seen_next && read_rsp_seen_next) begin
            if (read_current_error) begin
              error_group_mask_q[group_q] <= 1'b1;
              cpl_illegal_q <= 1'b1;
            end else if (read_index_q) begin
              index_data_q[(group_q*LANES_PER_GROUP*INDEX_ELEM_W) +:
                           (LANES_PER_GROUP*INDEX_ELEM_W)] <=
                  read_rsp_data_next;
              // The response mask is authoritative for tail/invalid bytes.
              // A missing index byte is an inactive destination and therefore
              // preserves its old vd element rather than consuming index zero.
              destination_active_q[(group_q*LANES_PER_GROUP) +:
                                   LANES_PER_GROUP] <=
                  destination_active_q[(group_q*LANES_PER_GROUP) +:
                                       LANES_PER_GROUP] & read_rsp_mask_next;
            end else begin
              source_data_q[(group_q*ROW_W) +: ROW_W] <=
                  read_rsp_data_next;
              source_valid_q[(group_q*LANES_PER_GROUP) +:
                             LANES_PER_GROUP] <= read_rsp_mask_next;
            end

            if ((!read_index_q && next_source_group_valid) ||
                (read_index_q && next_destination_group_valid)) begin
              group_q <= read_index_q ? next_destination_group :
                                        next_source_group;
              state_q <= STATE_READ_REQUEST;
            end else if (!read_index_q) begin
              if (!first_destination_group_valid) begin
                // Both masks were checked at admission; reaching this branch
                // without a destination is an internal protocol failure.
                protocol_error_q <= 1'b1;
                cpl_illegal_q <= 1'b1;
                cpl_rejected_q <= 1'b1;
                cpl_valid_q <= 1'b1;
                state_q <= STATE_COMPLETE;
              end else begin
                read_index_q <= 1'b1;
                group_q <= first_destination_group;
                state_q <= STATE_READ_REQUEST;
              end
            end else if (read_current_error || |error_group_mask_q) begin
              // Abort before the first destination write if any snapshot is
              // unavailable.  This preserves vd on every read-side failure.
              cpl_valid_q <= 1'b1;
              state_q <= STATE_COMPLETE;
            end else begin
              group_q <= first_destination_group;
              state_q <= STATE_ROUTE_RESULT;
            end
          end
        end

        STATE_ROUTE_RESULT: begin
          // All source and index rows are now immutable snapshots.  Register
          // the complete route result before advertising the first write so
          // the wide gather path cannot become part of the VRF request path.
          // This remains a single-active engine: the result stage is a timing
          // boundary, not a second outstanding command slot.
          route_result_data_q <= gathered_data;
          route_result_write_mask_q <= gathered_write_mask;
          cpl_invalid_mask_q <= gathered_invalid_mask;
          state_q <= STATE_WRITE_REQUEST;
        end

        STATE_WRITE_REQUEST: begin
          if (vrf_write_valid_o && vrf_write_ready_i) begin
            state_q <= STATE_WRITE_RESPONSE;
          end
        end

        STATE_WRITE_RESPONSE: begin
          if (write_cpl_fire) begin
            if (vrf_write_cpl_error_i || write_identity_error) begin
              error_group_mask_q[group_q] <= 1'b1;
              cpl_illegal_q <= 1'b1;
            end
            if (next_destination_group_valid) begin
              group_q <= next_destination_group;
              state_q <= STATE_WRITE_REQUEST;
            end else begin
              cpl_valid_q <= 1'b1;
              state_q <= STATE_COMPLETE;
            end
          end
        end

        STATE_COMPLETE: begin
          if (cpl_valid_q && cpl_ready_i) begin
            cpl_valid_q <= 1'b0;
            state_q <= STATE_IDLE;
          end
        end

        default: state_q <= STATE_IDLE;
      endcase
    end
  end

  initial begin
    if (GROUP_COUNT < 1 || LANES_PER_GROUP < 1 || ELEM_W != 8)
      $error("cluster route transport requires positive 8-bit lane groups");
    if (TOTAL_LANES > (1 << INDEX_ELEM_W))
      $error("route domain must fit in one index element");
    if (INDEX_ELEM_W != 8)
      $error("cluster route indices are full bytes");
    if (VRF_ROWS < 2 || CONTEXT_COUNT < 1 || TAG_W < 1)
      $error("route engine capacities must be valid");
  end
endmodule
