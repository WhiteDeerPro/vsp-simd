module simd_group_wrapper #(
  parameter int LANES         = 4,
  parameter int ELEM_W        = 8,
  parameter int ACC_W         = 32,
  parameter int VREGS         = 16,
  parameter int AREGS         = 8,
  parameter int MREGS         = 4,
  parameter int CONTEXT_COUNT = 2,
  parameter int TAG_W         = 8,
  // Stable topology identity. This is not the cluster-local array slot and
  // therefore remains eight bits even in a four-group cluster.
  parameter int SIMD4_ID_W    = 8,
  parameter logic [SIMD4_ID_W-1:0] SIMD4_ID = '0,
  parameter int VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter int ARF_ADDR_W = (AREGS <= 2) ? 1 : $clog2(AREGS),
  parameter int MRF_ADDR_W = (MREGS <= 2) ? 1 : $clog2(MREGS),
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int INDEX_W  = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1),
  parameter int RF_ADDR_W =
      (VRF_ADDR_W >= ARF_ADDR_W) ?
          ((VRF_ADDR_W >= MRF_ADDR_W) ? VRF_ADDR_W : MRF_ADDR_W) :
          ((ARF_ADDR_W >= MRF_ADDR_W) ? ARF_ADDR_W : MRF_ADDR_W)
) (
  input  logic clk_i,
  input  logic rst_ni,

  output logic [SIMD4_ID_W-1:0]            simd4_id_o,

  // Canonical, already-decoded SIMD execution transaction.  This interface
  // deliberately stays on the decoded side of any future compact-uword
  // decoder.  All fields must remain stable until exec_valid_i &&
  // exec_ready_o.
  input  logic                             exec_valid_i,
  output logic                             exec_ready_o,
  input  logic [CONTEXT_W-1:0]             exec_context_i,
  input  logic [TAG_W-1:0]                 exec_tag_i,
  input  logic                             exec_export_narrow_i,
  input  logic [simd_pkg::SIMD_OP_W-1:0]  exec_op_i,
  input  logic [simd_pkg::ELEM_MODE_W-1:0] exec_elem_mode_i,
  input  logic [VRF_ADDR_W-1:0]            exec_src_a_addr_i,
  input  logic [VRF_ADDR_W-1:0]            exec_src_b_addr_i,
  input  logic                             exec_use_imm_i,
  input  logic [(4*ELEM_W)-1:0]            exec_imm_i,
  input  logic [VRF_ADDR_W-1:0]            exec_dst_vrf_addr_i,
  input  logic [ARF_ADDR_W-1:0]            exec_src_arf_addr_i,
  input  logic [ARF_ADDR_W-1:0]            exec_dst_arf_addr_i,
  input  logic                             exec_mask_enable_i,
  input  logic [MRF_ADDR_W-1:0]            exec_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]            exec_select_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]            exec_dst_mrf_addr_i,
  input  logic                             exec_write_vrf_i,
  input  logic                             exec_write_arf_i,
  input  logic                             exec_write_mrf_i,
  input  logic                             exec_reduce_enable_i,
  input  logic [simd_pkg::REDUCE_OP_W-1:0] exec_reduce_op_i,
  input  logic                             exec_route_enable_i,
  input  logic [simd_pkg::ROUTE_OP_W-1:0]  exec_route_op_i,
  input  logic [(LANES*INDEX_W)-1:0]       exec_route_index_i,
  input  logic [INDEX_W-1:0]               exec_route_broadcast_index_i,
  input  logic [OFFSET_W-1:0]              exec_route_slide_amount_i,
  input  logic [(LANES*ELEM_W)-1:0]        exec_route_lower_i,
  input  logic [(LANES*ELEM_W)-1:0]        exec_route_upper_i,

  // One atomic register-file row write subrequest. A future vector memory
  // engine supplies both routing metadata and state_write_data_i on this
  // endpoint; program-level RF_FILL is a command that may expand into several
  // of these beats. This request is not a SIMD arithmetic opcode or an encoded
  // ISA field, and its data does not live in the instruction queue.
  input  logic                              state_write_valid_i,
  output logic                              state_write_ready_o,
  input  logic [CONTEXT_W-1:0]              state_write_context_i,
  input  logic [TAG_W-1:0]                  state_write_tag_i,
  input  logic [simd_pkg::SIMD_RF_FILE_W-1:0] state_write_file_i,
  input  logic [RF_ADDR_W-1:0]              state_write_addr_i,
  input  logic [LANES-1:0]                  state_write_mask_i,
  input  logic [(LANES*ACC_W)-1:0]          state_write_data_i,

  // One atomic VRF row read subrequest. It shares the existing VRF source-A
  // read port with EXEC, so request arbitration admits at most one of EXEC,
  // state-write, or state-read per cycle. Every accepted request produces one
  // completion and one data response, in either sink-observed order, including
  // on error. These channels are deliberately separate from EXEC's
  // completion/result channels and therefore never enter its tracker.
  input  logic                              state_read_valid_i,
  output logic                              state_read_ready_o,
  input  logic [CONTEXT_W-1:0]              state_read_context_i,
  input  logic [TAG_W-1:0]                  state_read_tag_i,
  input  logic [VRF_ADDR_W-1:0]             state_read_addr_i,
  input  logic [LANES-1:0]                  state_read_mask_i,

  output logic                              state_read_cpl_valid_o,
  input  logic                              state_read_cpl_ready_i,
  output logic [CONTEXT_W-1:0]              state_read_cpl_context_o,
  output logic [TAG_W-1:0]                  state_read_cpl_tag_o,
  output logic                              state_read_cpl_illegal_o,

  output logic                              state_read_rsp_valid_o,
  input  logic                              state_read_rsp_ready_i,
  output logic [CONTEXT_W-1:0]              state_read_rsp_context_o,
  output logic [TAG_W-1:0]                  state_read_rsp_tag_o,
  output logic                              state_read_rsp_illegal_o,
  output logic [(LANES*ELEM_W)-1:0]         state_read_rsp_data_o,
  output logic [LANES-1:0]                  state_read_rsp_mask_o,

  // Every accepted group subrequest produces exactly one group
  // completion.  This is not a program-level RF_FILL completion.  The
  // optional EXEC result travels independently so normal completions do not
  // carry the widest datapath payload.
  output logic                              cpl_valid_o,
  input  logic                              cpl_ready_i,
  output logic [CONTEXT_W-1:0]              cpl_context_o,
  output logic [TAG_W-1:0]                  cpl_tag_o,
  output logic [simd_pkg::SIMD_GROUP_REQ_KIND_W-1:0] cpl_kind_o,
  output logic                              cpl_illegal_o,
  output logic                              cpl_has_result_o,

  output logic                              rsp_valid_o,
  input  logic                              rsp_ready_i,
  output logic [CONTEXT_W-1:0]              rsp_context_o,
  output logic [TAG_W-1:0]                  rsp_tag_o,
  output logic                              rsp_illegal_o,
  output logic                              rsp_has_narrow_o,
  output logic [(LANES*ELEM_W)-1:0]         rsp_narrow_o,
  output logic [LANES-1:0]                  rsp_narrow_mask_o,
  output logic                              rsp_has_reduce_o,
  output logic [ACC_W-1:0]                  rsp_reduce_value_o,
  output logic [INDEX_W-1:0]                rsp_reduce_index_o,
  output logic                              rsp_has_count_o,
  output logic [OFFSET_W-1:0]               rsp_count_o
);
  import simd_pkg::*;

  assign simd4_id_o = SIMD4_ID;

  // The wrapper owns a one-entry elastic operand stage.  Source addresses are
  // presented to the asynchronous RF ports while an EXEC request is being
  // admitted; the returned operands and all execute-side control are captured
  // here.  The following cycle performs route/execute/reduction and commits the
  // RF write plus completion/result records.  This is the first real internal
  // SIMD4 pipeline cut: it separates RF lookup from arithmetic rather than
  // merely delaying an already-decoded command.
  typedef struct packed {
    logic                              export_narrow;
    logic [SIMD_OP_W-1:0]             op;
    logic [ELEM_MODE_W-1:0]            elem_mode;
    logic                              use_imm;
    logic [(4*ELEM_W)-1:0]             imm;
    logic [VRF_ADDR_W-1:0]             dst_vrf_addr;
    logic [ARF_ADDR_W-1:0]             dst_arf_addr;
    logic                              mask_enable;
    logic [MRF_ADDR_W-1:0]             dst_mrf_addr;
    logic                              write_vrf;
    logic                              write_arf;
    logic                              write_mrf;
    logic                              reduce_enable;
    logic [REDUCE_OP_W-1:0]            reduce_op;
    logic                              route_enable;
    logic [ROUTE_OP_W-1:0]             route_op;
    logic [(LANES*INDEX_W)-1:0]        route_index;
    logic [INDEX_W-1:0]                route_broadcast_index;
    logic [OFFSET_W-1:0]               route_slide_amount;
    logic [(LANES*ELEM_W)-1:0]         route_lower;
    logic [(LANES*ELEM_W)-1:0]         route_upper;
  } exec_pipe_ctrl_t;

  logic exec_pipe_valid_q;
  exec_pipe_ctrl_t exec_pipe_ctrl_q;
  logic [CONTEXT_W-1:0] exec_pipe_context_q;
  logic [TAG_W-1:0] exec_pipe_tag_q;
  logic exec_pipe_endpoint_illegal_q;
  logic exec_pipe_rsp_required_q;
  logic [(LANES*ELEM_W)-1:0] exec_pipe_src_a_q;
  logic [(LANES*ELEM_W)-1:0] exec_pipe_src_b_q;
  logic [(LANES*ACC_W)-1:0] exec_pipe_acc_q;
  logic [LANES-1:0] exec_pipe_mask_q;
  logic [LANES-1:0] exec_pipe_select_mask_q;

  logic exec_pipe_can_commit;
  logic exec_pipe_ready;
  logic exec_commit;
  logic [(LANES*ELEM_W)-1:0] capture_src_a;
  logic [(LANES*ELEM_W)-1:0] capture_src_b;
  logic [(LANES*ACC_W)-1:0] capture_acc;
  logic [LANES-1:0] capture_exec_mask;
  logic [LANES-1:0] capture_select_mask;

  // Round-robin next preference: 0=EXEC, 1=state-write, 2=state-read.
  logic [1:0] request_rr_q;

  logic cpl_valid_q;
  logic [CONTEXT_W-1:0] cpl_context_q;
  logic [TAG_W-1:0] cpl_tag_q;
  logic [SIMD_GROUP_REQ_KIND_W-1:0] cpl_kind_q;
  logic cpl_illegal_q;
  logic cpl_has_result_q;

  logic rsp_valid_q;
  logic [CONTEXT_W-1:0] rsp_context_q;
  logic [TAG_W-1:0] rsp_tag_q;
  logic rsp_illegal_q;
  logic rsp_has_narrow_q;
  logic [(LANES*ELEM_W)-1:0] rsp_narrow_q;
  logic [LANES-1:0] rsp_narrow_mask_q;
  logic rsp_has_reduce_q;
  logic [ACC_W-1:0] rsp_reduce_value_q;
  logic [INDEX_W-1:0] rsp_reduce_index_q;
  logic rsp_has_count_q;
  logic [OFFSET_W-1:0] rsp_count_q;

  logic state_read_cpl_valid_q;
  logic [CONTEXT_W-1:0] state_read_cpl_context_q;
  logic [TAG_W-1:0] state_read_cpl_tag_q;
  logic state_read_cpl_illegal_q;
  logic state_read_rsp_valid_q;
  logic [CONTEXT_W-1:0] state_read_rsp_context_q;
  logic [TAG_W-1:0] state_read_rsp_tag_q;
  logic state_read_rsp_illegal_q;
  logic [(LANES*ELEM_W)-1:0] state_read_rsp_data_q;
  logic [LANES-1:0] state_read_rsp_mask_q;

  logic cpl_can_push;
  logic rsp_can_push;
  logic state_read_cpl_can_push;
  logic state_read_rsp_can_push;
  logic exec_rsp_required_in;
  logic exec_eligible;
  logic state_write_eligible;
  logic state_read_eligible;
  logic exec_fire;
  logic state_write_fire;
  logic state_read_fire;
  logic state_write_file_valid;
  logic state_write_addr_valid;
  logic state_write_illegal;
  logic state_read_addr_valid;
  logic state_read_illegal;
  logic exec_endpoint_illegal;
  logic exec_request_illegal;
  logic exec_issue;

  logic cfg_vrf_write;
  logic cfg_arf_write;
  logic cfg_mrf_write;
  logic datapath_illegal;
  logic [(LANES*ELEM_W)-1:0] datapath_narrow;
  // Wide results feed the ARF forwarding path even though F1 exports only
  // narrow/scalar results. The boundary mask remains reserved for a future
  // external route endpoint.
  /* verilator lint_off UNUSED */
  logic [LANES-1:0] datapath_boundary_mask_unused;
  /* verilator lint_on UNUSED */
  logic [(LANES*ACC_W)-1:0] datapath_wide;
  logic [LANES-1:0] datapath_predicate;
  logic [LANES-1:0] datapath_exec_mask;
  logic [ACC_W-1:0] datapath_reduce_value;
  logic [INDEX_W-1:0] datapath_reduce_index;
  logic datapath_reduce_valid;
  logic [OFFSET_W-1:0] datapath_compact_count;
  logic datapath_compact_valid;
  logic compact_op;
  logic mask_logic_op;
  logic group_op;
  logic [LANES-1:0] exec_write_mask;
  logic [LANES-1:0] exec_narrow_mask;
  logic [VRF_ADDR_W-1:0] datapath_src_a_addr;
  logic [(LANES*ELEM_W)-1:0] datapath_vrf_src_a;
  logic [(LANES*ELEM_W)-1:0] datapath_vrf_src_b;
  logic [(LANES*ACC_W)-1:0] datapath_arf_src;
  logic [LANES-1:0] datapath_mrf_exec;
  logic [LANES-1:0] datapath_mrf_select;

  assign cpl_can_push = !cpl_valid_q || cpl_ready_i;
  assign rsp_can_push = !rsp_valid_q || rsp_ready_i;
  assign state_read_cpl_can_push = !state_read_cpl_valid_q ||
                                   state_read_cpl_ready_i;
  assign state_read_rsp_can_push = !state_read_rsp_valid_q ||
                                   state_read_rsp_ready_i;
  assign compact_op = (exec_pipe_ctrl_q.op == SIMD_OP_COMPRESS) ||
                      (exec_pipe_ctrl_q.op == SIMD_OP_EXPAND);
  assign mask_logic_op = (exec_pipe_ctrl_q.op == SIMD_OP_MAND) ||
                         (exec_pipe_ctrl_q.op == SIMD_OP_MOR) ||
                         (exec_pipe_ctrl_q.op == SIMD_OP_MXOR) ||
                         (exec_pipe_ctrl_q.op == SIMD_OP_MNOT);
  assign group_op = compact_op || mask_logic_op;
  assign exec_write_mask = group_op ? {LANES{1'b1}} :
                                      datapath_exec_mask;
  assign exec_rsp_required_in = simd_exec_requires_result(
      exec_op_i, exec_export_narrow_i, exec_reduce_enable_i);
  // Export is a narrow-result consumer, so it follows the same operation
  // capability as VRF writeback.  Rejecting it at the endpoint also prevents
  // an otherwise legal wide write from committing as part of a malformed
  // request.  Context range checks provide a final guard even when an outer
  // dispatcher is expected to validate canonical traffic.
  assign exec_endpoint_illegal =
      (int'(exec_context_i) >= CONTEXT_COUNT) ||
      (exec_export_narrow_i && !simd_op_can_write_vrf(exec_op_i));
  assign exec_pipe_can_commit = rst_ni && exec_pipe_valid_q && cpl_can_push &&
                                (!exec_pipe_rsp_required_q || rsp_can_push);
  assign exec_pipe_ready = !exec_pipe_valid_q || exec_pipe_can_commit;
  assign exec_commit = exec_pipe_can_commit;
  assign exec_eligible = rst_ni && exec_pipe_ready;
  // State-transfer traffic shares the physical RF ports.  Do not admit it in
  // the same cycle that a resident EXEC stage is committing; this keeps the
  // state endpoint atomic and avoids an implicit read-during-write policy.
  assign state_write_eligible = rst_ni && !exec_pipe_valid_q && cpl_can_push;
  assign state_read_eligible = rst_ni && !exec_pipe_valid_q &&
                               state_read_cpl_can_push &&
                               state_read_rsp_can_push;

  always_comb begin
    exec_ready_o = 1'b0;
    state_write_ready_o = 1'b0;
    state_read_ready_o = 1'b0;

    if (exec_valid_i || state_write_valid_i || state_read_valid_i) begin
      // Scan from the rotating preference and skip absent or blocked request
      // classes. A grant is exclusive even though the return paths differ.
      unique case (request_rr_q)
        2'd0: begin
          if (exec_valid_i && exec_eligible) exec_ready_o = 1'b1;
          else if (state_write_valid_i && state_write_eligible)
            state_write_ready_o = 1'b1;
          else if (state_read_valid_i && state_read_eligible)
            state_read_ready_o = 1'b1;
        end
        2'd1: begin
          if (state_write_valid_i && state_write_eligible)
            state_write_ready_o = 1'b1;
          else if (state_read_valid_i && state_read_eligible)
            state_read_ready_o = 1'b1;
          else if (exec_valid_i && exec_eligible) exec_ready_o = 1'b1;
        end
        default: begin
          if (state_read_valid_i && state_read_eligible)
            state_read_ready_o = 1'b1;
          else if (exec_valid_i && exec_eligible) exec_ready_o = 1'b1;
          else if (state_write_valid_i && state_write_eligible)
            state_write_ready_o = 1'b1;
        end
      endcase
    end else begin
      // Advertise independent capacity while idle. Once one or more valids are
      // present, the exclusive arbiter exposes ready on only the winner.
      exec_ready_o = exec_eligible;
      state_write_ready_o = state_write_eligible;
      state_read_ready_o = state_read_eligible;
    end
  end

  assign exec_fire = exec_valid_i && exec_ready_o;
  assign exec_issue = exec_commit && !exec_pipe_endpoint_illegal_q;
  assign state_write_fire = state_write_valid_i && state_write_ready_o;
  assign state_read_fire = state_read_valid_i && state_read_ready_o;

  always_comb begin
    state_write_file_valid = 1'b1;
    state_write_addr_valid = 1'b0;
    unique case (state_write_file_i)
      SIMD_RF_VRF: state_write_addr_valid = int'(state_write_addr_i) < VREGS;
      SIMD_RF_ARF: state_write_addr_valid = int'(state_write_addr_i) < AREGS;
      SIMD_RF_MRF: state_write_addr_valid = int'(state_write_addr_i) < MREGS;
      default: begin
        state_write_file_valid = 1'b0;
        state_write_addr_valid = 1'b0;
      end
    endcase
  end
  assign state_write_illegal =
      (int'(state_write_context_i) >= CONTEXT_COUNT) ||
      !state_write_file_valid || !state_write_addr_valid;
  assign state_read_addr_valid = int'(state_read_addr_i) < VREGS;
  assign state_read_illegal =
      (int'(state_read_context_i) >= CONTEXT_COUNT) ||
      !state_read_addr_valid;
  assign exec_request_illegal = exec_pipe_endpoint_illegal_q ||
                                datapath_illegal;

  // The asynchronous VRF A port observes the state-read row only on the
  // granted request. An illegal address is replaced with row zero so even a
  // non-power-of-two experimental profile cannot index storage out of range.
  assign datapath_src_a_addr = state_read_fire
                                   ? (state_read_illegal
                                          ? '0 : state_read_addr_i)
                                   : exec_src_a_addr_i;

  assign cfg_vrf_write = state_write_fire && !state_write_illegal &&
                          (state_write_file_i == SIMD_RF_VRF);
  assign cfg_arf_write = state_write_fire && !state_write_illegal &&
                          (state_write_file_i == SIMD_RF_ARF);
  assign cfg_mrf_write = state_write_fire && !state_write_illegal &&
                          (state_write_file_i == SIMD_RF_MRF);

  always_comb begin
    if (mask_logic_op) exec_narrow_mask = {LANES{1'b1}};
    else if (compact_op) exec_narrow_mask = datapath_predicate;
    else exec_narrow_mask = datapath_exec_mask;
  end

  // Same-edge forwarding closes the only RAW hole introduced by the operand
  // stage.  RF arrays write on the commit edge, while a replacement command
  // captures its asynchronous reads on that same edge.  Merge only lanes that
  // the retiring command actually writes; untouched lanes keep the raw RF
  // value.  State transfers cannot overlap a resident EXEC stage and therefore
  // need no corresponding bypass case.
  always_comb begin
    capture_src_a = datapath_vrf_src_a;
    capture_src_b = datapath_vrf_src_b;
    capture_acc = datapath_arf_src;
    capture_exec_mask = datapath_mrf_exec;
    capture_select_mask = datapath_mrf_select;

    if (exec_commit && !exec_request_illegal) begin
      if (exec_pipe_ctrl_q.write_vrf) begin
        for (int lane = 0; lane < LANES; lane++) begin
          if (exec_write_mask[lane]) begin
            if (exec_src_a_addr_i == exec_pipe_ctrl_q.dst_vrf_addr)
              capture_src_a[(lane*ELEM_W) +: ELEM_W] =
                  datapath_narrow[(lane*ELEM_W) +: ELEM_W];
            if (exec_src_b_addr_i == exec_pipe_ctrl_q.dst_vrf_addr)
              capture_src_b[(lane*ELEM_W) +: ELEM_W] =
                  datapath_narrow[(lane*ELEM_W) +: ELEM_W];
          end
        end
      end

      if (exec_pipe_ctrl_q.write_arf &&
          (exec_src_arf_addr_i == exec_pipe_ctrl_q.dst_arf_addr)) begin
        for (int lane = 0; lane < LANES; lane++) begin
          if (datapath_exec_mask[lane])
            capture_acc[(lane*ACC_W) +: ACC_W] =
                datapath_wide[(lane*ACC_W) +: ACC_W];
        end
      end

      if (exec_pipe_ctrl_q.write_mrf) begin
        for (int lane = 0; lane < LANES; lane++) begin
          if (exec_write_mask[lane]) begin
            if (exec_mask_addr_i == exec_pipe_ctrl_q.dst_mrf_addr)
              capture_exec_mask[lane] = datapath_predicate[lane];
            if (exec_select_mask_addr_i == exec_pipe_ctrl_q.dst_mrf_addr)
              capture_select_mask[lane] = datapath_predicate[lane];
          end
        end
      end
    end
  end

  simd_datapath #(
    .LANES(LANES),
    .ELEM_W(ELEM_W),
    .ACC_W(ACC_W),
    .VREGS(VREGS),
    .AREGS(AREGS),
    .MREGS(MREGS),
    .VRF_ADDR_W(VRF_ADDR_W),
    .ARF_ADDR_W(ARF_ADDR_W),
    .MRF_ADDR_W(MRF_ADDR_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W)
  ) u_datapath (
    .clk_i(clk_i),
    .issue_i(exec_issue),
    .op_i(exec_pipe_ctrl_q.op),
    .elem_mode_i(exec_pipe_ctrl_q.elem_mode),
    .src_a_addr_i(datapath_src_a_addr),
    .src_b_addr_i(exec_src_b_addr_i),
    .use_imm_i(exec_pipe_ctrl_q.use_imm),
    .imm_i(exec_pipe_ctrl_q.imm),
    .dst_vrf_addr_i(exec_pipe_ctrl_q.dst_vrf_addr),
    .src_arf_addr_i(exec_src_arf_addr_i),
    .dst_arf_addr_i(exec_pipe_ctrl_q.dst_arf_addr),
    .mask_enable_i(exec_pipe_ctrl_q.mask_enable),
    .exec_mask_addr_i(exec_mask_addr_i),
    .select_mask_addr_i(exec_select_mask_addr_i),
    .dst_mrf_addr_i(exec_pipe_ctrl_q.dst_mrf_addr),
    .write_vrf_i(exec_pipe_ctrl_q.write_vrf),
    .write_arf_i(exec_pipe_ctrl_q.write_arf),
    .write_mrf_i(exec_pipe_ctrl_q.write_mrf),
    .reduce_enable_i(exec_pipe_ctrl_q.reduce_enable),
    .reduce_op_i(exec_pipe_ctrl_q.reduce_op),
    .route_enable_i(exec_pipe_ctrl_q.route_enable),
    .route_op_i(exec_pipe_ctrl_q.route_op),
    .route_index_i(exec_pipe_ctrl_q.route_index),
    .route_broadcast_index_i(exec_pipe_ctrl_q.route_broadcast_index),
    .route_slide_amount_i(exec_pipe_ctrl_q.route_slide_amount),
    .route_lower_i(exec_pipe_ctrl_q.route_lower),
    .route_upper_i(exec_pipe_ctrl_q.route_upper),
    .cfg_vrf_write_i(cfg_vrf_write),
    .cfg_vrf_addr_i(state_write_addr_i[VRF_ADDR_W-1:0]),
    .cfg_vrf_mask_i(state_write_mask_i),
    .cfg_vrf_data_i(state_write_data_i[0 +: (LANES*ELEM_W)]),
    .cfg_arf_write_i(cfg_arf_write),
    .cfg_arf_addr_i(state_write_addr_i[ARF_ADDR_W-1:0]),
    .cfg_arf_mask_i(state_write_mask_i),
    .cfg_arf_data_i(state_write_data_i),
    .cfg_mrf_write_i(cfg_mrf_write),
    .cfg_mrf_addr_i(state_write_addr_i[MRF_ADDR_W-1:0]),
    .cfg_mrf_mask_i(state_write_mask_i),
    .cfg_mrf_data_i(state_write_data_i[0 +: LANES]),
    .operand_override_i(1'b1),
    .operand_src_a_i(exec_pipe_src_a_q),
    .operand_src_b_i(exec_pipe_src_b_q),
    .operand_acc_i(exec_pipe_acc_q),
    .operand_exec_mask_i(exec_pipe_mask_q),
    .operand_select_mask_i(exec_pipe_select_mask_q),
    .vrf_src_a_data_o(datapath_vrf_src_a),
    .vrf_src_b_data_o(datapath_vrf_src_b),
    .arf_src_data_o(datapath_arf_src),
    .mrf_exec_data_o(datapath_mrf_exec),
    .mrf_select_data_o(datapath_mrf_select),
    .narrow_result_o(datapath_narrow),
    .wide_result_o(datapath_wide),
    .predicate_result_o(datapath_predicate),
    .exec_mask_o(datapath_exec_mask),
    .reduce_value_o(datapath_reduce_value),
    .reduce_index_o(datapath_reduce_index),
    .reduce_valid_o(datapath_reduce_valid),
    .compact_count_o(datapath_compact_count),
    .compact_valid_o(datapath_compact_valid),
    .route_boundary_mask_o(datapath_boundary_mask_unused),
    .illegal_o(datapath_illegal)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      request_rr_q <= 2'd0;
      exec_pipe_valid_q <= 1'b0;
      exec_pipe_ctrl_q <= '0;
      exec_pipe_context_q <= '0;
      exec_pipe_tag_q <= '0;
      exec_pipe_endpoint_illegal_q <= 1'b0;
      exec_pipe_rsp_required_q <= 1'b0;
      exec_pipe_src_a_q <= '0;
      exec_pipe_src_b_q <= '0;
      exec_pipe_acc_q <= '0;
      exec_pipe_mask_q <= '0;
      exec_pipe_select_mask_q <= '0;
      cpl_valid_q <= 1'b0;
      cpl_context_q <= '0;
      cpl_tag_q <= '0;
      cpl_kind_q <= SIMD_GROUP_REQ_EXEC;
      cpl_illegal_q <= 1'b0;
      cpl_has_result_q <= 1'b0;
      rsp_valid_q <= 1'b0;
      rsp_context_q <= '0;
      rsp_tag_q <= '0;
      rsp_illegal_q <= 1'b0;
      rsp_has_narrow_q <= 1'b0;
      rsp_narrow_q <= '0;
      rsp_narrow_mask_q <= '0;
      rsp_has_reduce_q <= 1'b0;
      rsp_reduce_value_q <= '0;
      rsp_reduce_index_q <= '0;
      rsp_has_count_q <= 1'b0;
      rsp_count_q <= '0;
      state_read_cpl_valid_q <= 1'b0;
      state_read_cpl_context_q <= '0;
      state_read_cpl_tag_q <= '0;
      state_read_cpl_illegal_q <= 1'b0;
      state_read_rsp_valid_q <= 1'b0;
      state_read_rsp_context_q <= '0;
      state_read_rsp_tag_q <= '0;
      state_read_rsp_illegal_q <= 1'b0;
      state_read_rsp_data_q <= '0;
      state_read_rsp_mask_q <= '0;
    end else begin
      if (cpl_ready_i) cpl_valid_q <= 1'b0;
      if (rsp_ready_i) rsp_valid_q <= 1'b0;
      if (state_read_cpl_ready_i) state_read_cpl_valid_q <= 1'b0;
      if (state_read_rsp_ready_i) state_read_rsp_valid_q <= 1'b0;

      if (exec_commit) exec_pipe_valid_q <= 1'b0;
      if (exec_fire) begin
        exec_pipe_valid_q <= 1'b1;
        exec_pipe_ctrl_q.export_narrow <= exec_export_narrow_i;
        exec_pipe_ctrl_q.op <= exec_op_i;
        exec_pipe_ctrl_q.elem_mode <= exec_elem_mode_i;
        exec_pipe_ctrl_q.use_imm <= exec_use_imm_i;
        exec_pipe_ctrl_q.imm <= exec_imm_i;
        exec_pipe_ctrl_q.dst_vrf_addr <= exec_dst_vrf_addr_i;
        exec_pipe_ctrl_q.dst_arf_addr <= exec_dst_arf_addr_i;
        exec_pipe_ctrl_q.mask_enable <= exec_mask_enable_i;
        exec_pipe_ctrl_q.dst_mrf_addr <= exec_dst_mrf_addr_i;
        exec_pipe_ctrl_q.write_vrf <= exec_write_vrf_i;
        exec_pipe_ctrl_q.write_arf <= exec_write_arf_i;
        exec_pipe_ctrl_q.write_mrf <= exec_write_mrf_i;
        exec_pipe_ctrl_q.reduce_enable <= exec_reduce_enable_i;
        exec_pipe_ctrl_q.reduce_op <= exec_reduce_op_i;
        exec_pipe_ctrl_q.route_enable <= exec_route_enable_i;
        exec_pipe_ctrl_q.route_op <= exec_route_op_i;
        exec_pipe_ctrl_q.route_index <= exec_route_index_i;
        exec_pipe_ctrl_q.route_broadcast_index <=
            exec_route_broadcast_index_i;
        exec_pipe_ctrl_q.route_slide_amount <= exec_route_slide_amount_i;
        exec_pipe_ctrl_q.route_lower <= exec_route_lower_i;
        exec_pipe_ctrl_q.route_upper <= exec_route_upper_i;
        exec_pipe_context_q <= exec_context_i;
        exec_pipe_tag_q <= exec_tag_i;
        exec_pipe_endpoint_illegal_q <= exec_endpoint_illegal;
        exec_pipe_rsp_required_q <= exec_rsp_required_in;
        exec_pipe_src_a_q <= capture_src_a;
        exec_pipe_src_b_q <= capture_src_b;
        exec_pipe_acc_q <= capture_acc;
        exec_pipe_mask_q <= capture_exec_mask;
        exec_pipe_select_mask_q <= capture_select_mask;
        request_rr_q <= 2'd1;
      end else if (state_write_fire) begin
        request_rr_q <= 2'd2;
      end else if (state_read_fire) begin
        request_rr_q <= 2'd0;
      end

      if (exec_commit) begin
        cpl_valid_q <= 1'b1;
        cpl_context_q <= exec_pipe_context_q;
        cpl_tag_q <= exec_pipe_tag_q;
        cpl_kind_q <= SIMD_GROUP_REQ_EXEC;
        cpl_illegal_q <= exec_request_illegal;
        cpl_has_result_q <= exec_pipe_rsp_required_q;

        if (exec_pipe_rsp_required_q) begin
          rsp_valid_q <= 1'b1;
          rsp_context_q <= exec_pipe_context_q;
          rsp_tag_q <= exec_pipe_tag_q;
          rsp_illegal_q <= exec_request_illegal;
          rsp_has_narrow_q <= exec_pipe_ctrl_q.export_narrow &&
                              !exec_request_illegal;
          rsp_narrow_q <= (exec_pipe_ctrl_q.export_narrow &&
                           !exec_request_illegal)
                              ? datapath_narrow : '0;
          rsp_narrow_mask_q <= (exec_pipe_ctrl_q.export_narrow &&
                                !exec_request_illegal)
                                   ? exec_narrow_mask : '0;
          rsp_has_reduce_q <= exec_pipe_ctrl_q.reduce_enable &&
                              datapath_reduce_valid &&
                              !exec_request_illegal;
          rsp_reduce_value_q <= (exec_pipe_ctrl_q.reduce_enable &&
                                 datapath_reduce_valid &&
                                 !exec_request_illegal)
                                    ? datapath_reduce_value : '0;
          rsp_reduce_index_q <= (exec_pipe_ctrl_q.reduce_enable &&
                                 datapath_reduce_valid &&
                                 !exec_request_illegal)
                                    ? datapath_reduce_index : '0;
          rsp_has_count_q <= datapath_compact_valid &&
                             !exec_request_illegal;
          rsp_count_q <= (datapath_compact_valid && !exec_request_illegal)
                             ? datapath_compact_count : '0;
        end
      end else if (state_write_fire) begin
        cpl_valid_q <= 1'b1;
        cpl_context_q <= state_write_context_i;
        cpl_tag_q <= state_write_tag_i;
        cpl_kind_q <= SIMD_GROUP_REQ_STATE_WRITE;
        cpl_illegal_q <= state_write_illegal;
        cpl_has_result_q <= 1'b0;
      end else if (state_read_fire) begin
        state_read_cpl_valid_q <= 1'b1;
        state_read_cpl_context_q <= state_read_context_i;
        state_read_cpl_tag_q <= state_read_tag_i;
        state_read_cpl_illegal_q <= state_read_illegal;
        state_read_rsp_valid_q <= 1'b1;
        state_read_rsp_context_q <= state_read_context_i;
        state_read_rsp_tag_q <= state_read_tag_i;
        state_read_rsp_illegal_q <= state_read_illegal;
        state_read_rsp_data_q <= state_read_illegal
                                     ? '0 : datapath_vrf_src_a;
        state_read_rsp_mask_q <= state_read_illegal
                                     ? '0 : state_read_mask_i;
      end
    end
  end

  assign state_read_cpl_valid_o = state_read_cpl_valid_q;
  assign state_read_cpl_context_o = state_read_cpl_context_q;
  assign state_read_cpl_tag_o = state_read_cpl_tag_q;
  assign state_read_cpl_illegal_o = state_read_cpl_illegal_q;

  assign state_read_rsp_valid_o = state_read_rsp_valid_q;
  assign state_read_rsp_context_o = state_read_rsp_context_q;
  assign state_read_rsp_tag_o = state_read_rsp_tag_q;
  assign state_read_rsp_illegal_o = state_read_rsp_illegal_q;
  assign state_read_rsp_data_o = state_read_rsp_data_q;
  assign state_read_rsp_mask_o = state_read_rsp_mask_q;

  assign cpl_valid_o = cpl_valid_q;
  assign cpl_context_o = cpl_context_q;
  assign cpl_tag_o = cpl_tag_q;
  assign cpl_kind_o = cpl_kind_q;
  assign cpl_illegal_o = cpl_illegal_q;
  assign cpl_has_result_o = cpl_has_result_q;

  assign rsp_valid_o = rsp_valid_q;
  assign rsp_context_o = rsp_context_q;
  assign rsp_tag_o = rsp_tag_q;
  assign rsp_illegal_o = rsp_illegal_q;
  assign rsp_has_narrow_o = rsp_has_narrow_q;
  assign rsp_narrow_o = rsp_narrow_q;
  assign rsp_narrow_mask_o = rsp_narrow_mask_q;
  assign rsp_has_reduce_o = rsp_has_reduce_q;
  assign rsp_reduce_value_o = rsp_reduce_value_q;
  assign rsp_reduce_index_o = rsp_reduce_index_q;
  assign rsp_has_count_o = rsp_has_count_q;
  assign rsp_count_o = rsp_count_q;

  initial begin
    if (SIMD4_ID_W != 8) $error("SIMD4 identity is defined as 8 bits");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (TAG_W < 1) $error("TAG_W must be positive");
    if (ACC_W < ELEM_W) $error("ACC_W must be at least ELEM_W");
    if (RF_ADDR_W < VRF_ADDR_W || RF_ADDR_W < ARF_ADDR_W ||
        RF_ADDR_W < MRF_ADDR_W) begin
      $error("RF_ADDR_W must cover every RF address");
    end
  end
endmodule
