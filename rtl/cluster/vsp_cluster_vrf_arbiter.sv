module vsp_cluster_vrf_arbiter #(
  // The first integration profile has one MEMORY client.
  // The arbiter deliberately permits only one accepted VRF child transaction
  // at a time; program-level overlap and ordering belong to the controller.
  parameter int CLIENT_COUNT       = 2,
  parameter int GROUP_COUNT        = 4,
  parameter int VRF_ROW_BYTES      = 4,
  parameter int VRF_ROWS           = 16,
  parameter int EXEC_CONTEXT_COUNT = 2,
  parameter int TAG_W              = 8,
  parameter int CLIENT_W = (CLIENT_COUNT <= 2) ? 1 : $clog2(CLIENT_COUNT),
  parameter int GROUP_ID_W = (GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT),
  parameter int VRF_ROW_ADDR_W = (VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS),
  parameter int CONTEXT_W = (EXEC_CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(EXEC_CONTEXT_COUNT),
  parameter int REQUEST_LANE_COUNT = 2 * CLIENT_COUNT,
  parameter int REQUEST_LANE_W = (REQUEST_LANE_COUNT <= 2) ? 1 :
                                 $clog2(REQUEST_LANE_COUNT)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Each client presents the same VRF-only child contract used by the span
  // and row-exchange actors.  Packed fields are indexed by client number.
  input  logic [CLIENT_COUNT-1:0]                 client_read_valid_i,
  output logic [CLIENT_COUNT-1:0]                 client_read_ready_o,
  input  logic [(CLIENT_COUNT*CONTEXT_W)-1:0]     client_read_context_i,
  input  logic [(CLIENT_COUNT*TAG_W)-1:0]         client_read_tag_i,
  input  logic [(CLIENT_COUNT*GROUP_ID_W)-1:0]    client_read_group_i,
  input  logic [(CLIENT_COUNT*VRF_ROW_ADDR_W)-1:0]
                                                    client_read_row_i,
  input  logic [(CLIENT_COUNT*VRF_ROW_BYTES)-1:0] client_read_mask_i,

  output logic [CLIENT_COUNT-1:0]                 client_read_cpl_valid_o,
  input  logic [CLIENT_COUNT-1:0]                 client_read_cpl_ready_i,
  output logic [(CLIENT_COUNT*CONTEXT_W)-1:0]     client_read_cpl_context_o,
  output logic [(CLIENT_COUNT*TAG_W)-1:0]         client_read_cpl_tag_o,
  output logic [(CLIENT_COUNT*GROUP_ID_W)-1:0]    client_read_cpl_group_o,
  output logic [CLIENT_COUNT-1:0]                 client_read_cpl_error_o,

  output logic [CLIENT_COUNT-1:0]                 client_read_rsp_valid_o,
  input  logic [CLIENT_COUNT-1:0]                 client_read_rsp_ready_i,
  output logic [(CLIENT_COUNT*CONTEXT_W)-1:0]     client_read_rsp_context_o,
  output logic [(CLIENT_COUNT*TAG_W)-1:0]         client_read_rsp_tag_o,
  output logic [(CLIENT_COUNT*GROUP_ID_W)-1:0]    client_read_rsp_group_o,
  output logic [(CLIENT_COUNT*VRF_ROW_BYTES*8)-1:0]
                                                    client_read_rsp_data_o,
  output logic [(CLIENT_COUNT*VRF_ROW_BYTES)-1:0] client_read_rsp_mask_o,
  output logic [CLIENT_COUNT-1:0]                 client_read_rsp_error_o,

  input  logic [CLIENT_COUNT-1:0]                 client_write_valid_i,
  output logic [CLIENT_COUNT-1:0]                 client_write_ready_o,
  input  logic [(CLIENT_COUNT*CONTEXT_W)-1:0]     client_write_context_i,
  input  logic [(CLIENT_COUNT*TAG_W)-1:0]         client_write_tag_i,
  input  logic [(CLIENT_COUNT*GROUP_ID_W)-1:0]    client_write_group_i,
  input  logic [(CLIENT_COUNT*VRF_ROW_ADDR_W)-1:0]
                                                    client_write_row_i,
  input  logic [(CLIENT_COUNT*VRF_ROW_BYTES)-1:0] client_write_mask_i,
  input  logic [(CLIENT_COUNT*VRF_ROW_BYTES*8)-1:0]
                                                    client_write_data_i,

  output logic [CLIENT_COUNT-1:0]                 client_write_cpl_valid_o,
  input  logic [CLIENT_COUNT-1:0]                 client_write_cpl_ready_i,
  output logic [(CLIENT_COUNT*CONTEXT_W)-1:0]     client_write_cpl_context_o,
  output logic [(CLIENT_COUNT*TAG_W)-1:0]         client_write_cpl_tag_o,
  output logic [(CLIENT_COUNT*GROUP_ID_W)-1:0]    client_write_cpl_group_o,
  output logic [CLIENT_COUNT-1:0]                 client_write_cpl_error_o,

  // One shared cluster-side VRF read endpoint.
  output logic                              cluster_read_valid_o,
  input  logic                              cluster_read_ready_i,
  output logic [CONTEXT_W-1:0]              cluster_read_context_o,
  output logic [TAG_W-1:0]                  cluster_read_tag_o,
  output logic [GROUP_ID_W-1:0]             cluster_read_group_o,
  output logic [VRF_ROW_ADDR_W-1:0]         cluster_read_row_o,
  output logic [VRF_ROW_BYTES-1:0]          cluster_read_mask_o,

  input  logic                              cluster_read_cpl_valid_i,
  output logic                              cluster_read_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]              cluster_read_cpl_context_i,
  input  logic [TAG_W-1:0]                  cluster_read_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             cluster_read_cpl_group_i,
  input  logic                              cluster_read_cpl_error_i,

  input  logic                              cluster_read_rsp_valid_i,
  output logic                              cluster_read_rsp_ready_o,
  input  logic [CONTEXT_W-1:0]              cluster_read_rsp_context_i,
  input  logic [TAG_W-1:0]                  cluster_read_rsp_tag_i,
  input  logic [GROUP_ID_W-1:0]             cluster_read_rsp_group_i,
  input  logic [(VRF_ROW_BYTES*8)-1:0]      cluster_read_rsp_data_i,
  input  logic [VRF_ROW_BYTES-1:0]          cluster_read_rsp_mask_i,
  input  logic                              cluster_read_rsp_error_i,

  // One shared cluster-side VRF write endpoint.
  output logic                              cluster_write_valid_o,
  input  logic                              cluster_write_ready_i,
  output logic [CONTEXT_W-1:0]              cluster_write_context_o,
  output logic [TAG_W-1:0]                  cluster_write_tag_o,
  output logic [GROUP_ID_W-1:0]             cluster_write_group_o,
  output logic [VRF_ROW_ADDR_W-1:0]         cluster_write_row_o,
  output logic [VRF_ROW_BYTES-1:0]          cluster_write_mask_o,
  output logic [(VRF_ROW_BYTES*8)-1:0]      cluster_write_data_o,

  input  logic                              cluster_write_cpl_valid_i,
  output logic                              cluster_write_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]              cluster_write_cpl_context_i,
  input  logic [TAG_W-1:0]                  cluster_write_cpl_tag_i,
  input  logic [GROUP_ID_W-1:0]             cluster_write_cpl_group_i,
  input  logic                              cluster_write_cpl_error_i,

  output logic                              busy_o,
  output logic [CLIENT_W-1:0]               active_client_o,
  output logic                              active_read_o
);
  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_READ,
    STATE_WRITE
  } state_e;

  state_e state_q;
  logic [CLIENT_W-1:0] owner_q;
  logic [REQUEST_LANE_W-1:0] rr_lane_q;
  logic read_cpl_seen_q;
  logic read_rsp_seen_q;

  logic select_valid;
  logic select_read;
  logic [CLIENT_W-1:0] select_client;
  logic [REQUEST_LANE_W-1:0] select_lane;
  logic request_fire;
  logic read_cpl_fire;
  logic read_rsp_fire;
  logic write_cpl_fire;
  logic read_cpl_done;
  logic read_rsp_done;

  always_comb begin
    select_valid = 1'b0;
    select_read = 1'b0;
    select_client = '0;
    select_lane = rr_lane_q;

    for (int offset = 0; offset < REQUEST_LANE_COUNT; offset++) begin
      int candidate;
      logic [CLIENT_W-1:0] candidate_client;
      logic candidate_read;
      candidate = int'(rr_lane_q) + offset;
      if (candidate >= REQUEST_LANE_COUNT)
        candidate -= REQUEST_LANE_COUNT;
      candidate_client = CLIENT_W'(candidate / 2);
      candidate_read = (candidate & 1) == 0;
      if (!select_valid &&
          (candidate_read ? client_read_valid_i[candidate_client]
                          : client_write_valid_i[candidate_client])) begin
        select_valid = 1'b1;
        select_read = candidate_read;
        select_client = CLIENT_W'(candidate_client);
        select_lane = REQUEST_LANE_W'(candidate);
      end
    end
  end

  always_comb begin
    client_read_ready_o = '0;
    client_write_ready_o = '0;

    cluster_read_valid_o = 1'b0;
    cluster_read_context_o = '0;
    cluster_read_tag_o = '0;
    cluster_read_group_o = '0;
    cluster_read_row_o = '0;
    cluster_read_mask_o = '0;

    cluster_write_valid_o = 1'b0;
    cluster_write_context_o = '0;
    cluster_write_tag_o = '0;
    cluster_write_group_o = '0;
    cluster_write_row_o = '0;
    cluster_write_mask_o = '0;
    cluster_write_data_o = '0;

    if (state_q == STATE_IDLE && select_valid) begin
      if (select_read) begin
        cluster_read_valid_o = client_read_valid_i[select_client];
        cluster_read_context_o = client_read_context_i[
            (select_client*CONTEXT_W) +: CONTEXT_W];
        cluster_read_tag_o = client_read_tag_i[
            (select_client*TAG_W) +: TAG_W];
        cluster_read_group_o = client_read_group_i[
            (select_client*GROUP_ID_W) +: GROUP_ID_W];
        cluster_read_row_o = client_read_row_i[
            (select_client*VRF_ROW_ADDR_W) +: VRF_ROW_ADDR_W];
        cluster_read_mask_o = client_read_mask_i[
            (select_client*VRF_ROW_BYTES) +: VRF_ROW_BYTES];
        client_read_ready_o[select_client] = cluster_read_ready_i;
      end else begin
        cluster_write_valid_o = client_write_valid_i[select_client];
        cluster_write_context_o = client_write_context_i[
            (select_client*CONTEXT_W) +: CONTEXT_W];
        cluster_write_tag_o = client_write_tag_i[
            (select_client*TAG_W) +: TAG_W];
        cluster_write_group_o = client_write_group_i[
            (select_client*GROUP_ID_W) +: GROUP_ID_W];
        cluster_write_row_o = client_write_row_i[
            (select_client*VRF_ROW_ADDR_W) +: VRF_ROW_ADDR_W];
        cluster_write_mask_o = client_write_mask_i[
            (select_client*VRF_ROW_BYTES) +: VRF_ROW_BYTES];
        cluster_write_data_o = client_write_data_i[
            (select_client*VRF_ROW_BYTES*8) +: (VRF_ROW_BYTES*8)];
        client_write_ready_o[select_client] = cluster_write_ready_i;
      end
    end
  end

  always_comb begin
    client_read_cpl_valid_o = '0;
    client_read_cpl_context_o = '0;
    client_read_cpl_tag_o = '0;
    client_read_cpl_group_o = '0;
    client_read_cpl_error_o = '0;
    client_read_rsp_valid_o = '0;
    client_read_rsp_context_o = '0;
    client_read_rsp_tag_o = '0;
    client_read_rsp_group_o = '0;
    client_read_rsp_data_o = '0;
    client_read_rsp_mask_o = '0;
    client_read_rsp_error_o = '0;
    client_write_cpl_valid_o = '0;
    client_write_cpl_context_o = '0;
    client_write_cpl_tag_o = '0;
    client_write_cpl_group_o = '0;
    client_write_cpl_error_o = '0;

    cluster_read_cpl_ready_o = 1'b0;
    cluster_read_rsp_ready_o = 1'b0;
    cluster_write_cpl_ready_o = 1'b0;

    if (state_q == STATE_READ) begin
      if (!read_cpl_seen_q) begin
        client_read_cpl_valid_o[owner_q] = cluster_read_cpl_valid_i;
        client_read_cpl_context_o[(owner_q*CONTEXT_W) +: CONTEXT_W] =
            cluster_read_cpl_context_i;
        client_read_cpl_tag_o[(owner_q*TAG_W) +: TAG_W] =
            cluster_read_cpl_tag_i;
        client_read_cpl_group_o[(owner_q*GROUP_ID_W) +: GROUP_ID_W] =
            cluster_read_cpl_group_i;
        client_read_cpl_error_o[owner_q] = cluster_read_cpl_error_i;
        cluster_read_cpl_ready_o = client_read_cpl_ready_i[owner_q];
      end
      if (!read_rsp_seen_q) begin
        client_read_rsp_valid_o[owner_q] = cluster_read_rsp_valid_i;
        client_read_rsp_context_o[(owner_q*CONTEXT_W) +: CONTEXT_W] =
            cluster_read_rsp_context_i;
        client_read_rsp_tag_o[(owner_q*TAG_W) +: TAG_W] =
            cluster_read_rsp_tag_i;
        client_read_rsp_group_o[(owner_q*GROUP_ID_W) +: GROUP_ID_W] =
            cluster_read_rsp_group_i;
        client_read_rsp_data_o[
            (owner_q*VRF_ROW_BYTES*8) +: (VRF_ROW_BYTES*8)] =
            cluster_read_rsp_data_i;
        client_read_rsp_mask_o[(owner_q*VRF_ROW_BYTES) +: VRF_ROW_BYTES] =
            cluster_read_rsp_mask_i;
        client_read_rsp_error_o[owner_q] = cluster_read_rsp_error_i;
        cluster_read_rsp_ready_o = client_read_rsp_ready_i[owner_q];
      end
    end else if (state_q == STATE_WRITE) begin
      client_write_cpl_valid_o[owner_q] = cluster_write_cpl_valid_i;
      client_write_cpl_context_o[(owner_q*CONTEXT_W) +: CONTEXT_W] =
          cluster_write_cpl_context_i;
      client_write_cpl_tag_o[(owner_q*TAG_W) +: TAG_W] =
          cluster_write_cpl_tag_i;
      client_write_cpl_group_o[(owner_q*GROUP_ID_W) +: GROUP_ID_W] =
          cluster_write_cpl_group_i;
      client_write_cpl_error_o[owner_q] = cluster_write_cpl_error_i;
      cluster_write_cpl_ready_o = client_write_cpl_ready_i[owner_q];
    end
  end

  assign request_fire =
      (cluster_read_valid_o && cluster_read_ready_i) ||
      (cluster_write_valid_o && cluster_write_ready_i);
  assign read_cpl_fire = cluster_read_cpl_valid_i &&
                         cluster_read_cpl_ready_o;
  assign read_rsp_fire = cluster_read_rsp_valid_i &&
                         cluster_read_rsp_ready_o;
  assign write_cpl_fire = cluster_write_cpl_valid_i &&
                          cluster_write_cpl_ready_o;
  assign read_cpl_done = read_cpl_seen_q || read_cpl_fire;
  assign read_rsp_done = read_rsp_seen_q || read_rsp_fire;

  assign busy_o = state_q != STATE_IDLE;
  assign active_client_o = owner_q;
  assign active_read_o = state_q == STATE_READ;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= STATE_IDLE;
      owner_q <= '0;
      rr_lane_q <= '0;
      read_cpl_seen_q <= 1'b0;
      read_rsp_seen_q <= 1'b0;
    end else begin
      unique case (state_q)
        STATE_IDLE: begin
          read_cpl_seen_q <= 1'b0;
          read_rsp_seen_q <= 1'b0;
          if (request_fire) begin
            owner_q <= select_client;
            state_q <= select_read ? STATE_READ : STATE_WRITE;
            if (int'(select_lane) == REQUEST_LANE_COUNT - 1)
              rr_lane_q <= '0;
            else rr_lane_q <= select_lane + 1'b1;
          end
        end

        STATE_READ: begin
          if (read_cpl_fire) read_cpl_seen_q <= 1'b1;
          if (read_rsp_fire) read_rsp_seen_q <= 1'b1;
          if (read_cpl_done && read_rsp_done) begin
            state_q <= STATE_IDLE;
            read_cpl_seen_q <= 1'b0;
            read_rsp_seen_q <= 1'b0;
          end
        end

        STATE_WRITE: begin
          if (write_cpl_fire) state_q <= STATE_IDLE;
        end

        default: state_q <= STATE_IDLE;
      endcase
    end
  end

  initial begin
    if (CLIENT_COUNT < 1 || GROUP_COUNT < 1 || VRF_ROW_BYTES < 1 ||
        VRF_ROWS < 1 || EXEC_CONTEXT_COUNT < 1 || TAG_W < 1) begin
      $error("VRF service parameters must be positive");
    end
    if (CLIENT_W != ((CLIENT_COUNT <= 2) ? 1 : $clog2(CLIENT_COUNT))) begin
      $error("CLIENT_W must match CLIENT_COUNT");
    end
    if (GROUP_ID_W != ((GROUP_COUNT <= 2) ? 1 : $clog2(GROUP_COUNT))) begin
      $error("GROUP_ID_W must match GROUP_COUNT");
    end
    if (VRF_ROW_ADDR_W != ((VRF_ROWS <= 2) ? 1 : $clog2(VRF_ROWS))) begin
      $error("VRF_ROW_ADDR_W must match VRF_ROWS");
    end
    if (CONTEXT_W != ((EXEC_CONTEXT_COUNT <= 2) ? 1 :
                      $clog2(EXEC_CONTEXT_COUNT))) begin
      $error("CONTEXT_W must match EXEC_CONTEXT_COUNT");
    end
  end
endmodule
