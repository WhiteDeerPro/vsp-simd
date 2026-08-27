module simd_datapath #(
  parameter int LANES    = 4,
  parameter int ELEM_W   = 8,
  parameter int ACC_W    = 32,
  parameter int VREGS    = 16,
  parameter int AREGS    = 8,
  parameter int MREGS    = 4,
  parameter int VRF_ADDR_W = (VREGS <= 2) ? 1 : $clog2(VREGS),
  parameter int ARF_ADDR_W = (AREGS <= 2) ? 1 : $clog2(AREGS),
  parameter int MRF_ADDR_W = (MREGS <= 2) ? 1 : $clog2(MREGS),
  parameter int INDEX_W  = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1)
) (
  input  logic clk_i,

  // Externally issued micro-operation. There is no fetch/decode stage here.
  input  logic                            issue_i,
  input  logic [simd_pkg::SIMD_OP_W-1:0] op_i,
  input  logic [simd_pkg::ELEM_MODE_W-1:0] elem_mode_i,
  input  logic [VRF_ADDR_W-1:0]           src_a_addr_i,
  input  logic [VRF_ADDR_W-1:0]           src_b_addr_i,
  // Immediate form replaces VRF source B with one value broadcast at the
  // selected logical element width. The sequencer supplies up to four bytes.
  input  logic                            use_imm_i,
  input  logic [(4*ELEM_W)-1:0]           imm_i,
  input  logic [VRF_ADDR_W-1:0]           dst_vrf_addr_i,
  input  logic [ARF_ADDR_W-1:0]           src_arf_addr_i,
  input  logic [ARF_ADDR_W-1:0]           dst_arf_addr_i,
  input  logic                            mask_enable_i,
  input  logic [MRF_ADDR_W-1:0]           exec_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]           select_mask_addr_i,
  input  logic [MRF_ADDR_W-1:0]           dst_mrf_addr_i,
  input  logic                            write_vrf_i,
  input  logic                            write_arf_i,
  input  logic                            write_mrf_i,
  input  logic                            reduce_enable_i,
  input  logic [simd_pkg::REDUCE_OP_W-1:0] reduce_op_i,

  // Optional routing of VRF source A before lane execution. PASS_A plus a VRF
  // writeback forms a standalone route instruction; other ALU operations may
  // consume the routed source directly without a temporary register.
  input  logic                            route_enable_i,
  input  logic [simd_pkg::ROUTE_OP_W-1:0] route_op_i,
  input  logic [(LANES*INDEX_W)-1:0]      route_index_i,
  input  logic [INDEX_W-1:0]              route_broadcast_index_i,
  input  logic [OFFSET_W-1:0]             route_slide_amount_i,
  input  logic [(LANES*ELEM_W)-1:0]       route_lower_i,
  input  logic [(LANES*ELEM_W)-1:0]       route_upper_i,

  // External initialization/state transfer ports. They have priority over an
  // issued write to the same register file in the same cycle.
  input  logic                            cfg_vrf_write_i,
  input  logic [VRF_ADDR_W-1:0]           cfg_vrf_addr_i,
  input  logic [LANES-1:0]                cfg_vrf_mask_i,
  input  logic [(LANES*ELEM_W)-1:0]       cfg_vrf_data_i,
  input  logic                            cfg_arf_write_i,
  input  logic [ARF_ADDR_W-1:0]           cfg_arf_addr_i,
  input  logic [LANES-1:0]                cfg_arf_mask_i,
  input  logic [(LANES*ACC_W)-1:0]        cfg_arf_data_i,
  input  logic                            cfg_mrf_write_i,
  input  logic [MRF_ADDR_W-1:0]           cfg_mrf_addr_i,
  input  logic [LANES-1:0]                cfg_mrf_mask_i,
  input  logic [LANES-1:0]                cfg_mrf_data_i,

  output logic [(LANES*ELEM_W)-1:0]       narrow_result_o,
  output logic [(LANES*ACC_W)-1:0]        wide_result_o,
  output logic [LANES-1:0]                predicate_result_o,
  output logic [LANES-1:0]                exec_mask_o,
  output logic [ACC_W-1:0]                reduce_value_o,
  output logic [INDEX_W-1:0]              reduce_index_o,
  output logic                            reduce_valid_o,
  // Scalar result of COMPRESS/EXPAND for sequencer-side stream accounting.
  output logic [OFFSET_W-1:0]             compact_count_o,
  output logic                            compact_valid_o,
  output logic [LANES-1:0]                route_boundary_mask_o,
  output logic                            illegal_o
);
  import simd_pkg::*;

  localparam int SCALE_W = (ACC_W <= 2) ? 1 : $clog2(ACC_W);

  logic [(2*LANES*ELEM_W)-1:0] vrf_read_data;
  logic [(LANES*ACC_W)-1:0] arf_read_data;
  logic [(2*LANES)-1:0] mrf_read_data;
  logic [(LANES*ELEM_W)-1:0] src_a;
  logic [(LANES*ELEM_W)-1:0] src_b;
  logic [(LANES*ELEM_W)-1:0] routed_src_a;
  logic [(LANES*ELEM_W)-1:0] exec_src_a;
  logic [(LANES*ELEM_W)-1:0] exec_src_b;
  logic [(LANES*ELEM_W)-1:0] imm_broadcast;
  logic [(LANES*ELEM_W)-1:0] lane_narrow_result;
  logic [(LANES*ACC_W)-1:0] lane_wide_result;
  logic [LANES-1:0] lane_predicate_result;
  logic [SCALE_W-1:0] wide_align;
  logic wide_ternary_op;
  logic compact_op;
  logic expand_op;
  logic group_rearrange_op;
  logic mask_logic_op;
  logic group_op;
  logic [(LANES*ELEM_W)-1:0] compact_result;
  logic [LANES-1:0] compact_result_mask;
  logic [OFFSET_W-1:0] raw_compact_count;
  logic [LANES-1:0] mask_logic_result;
  logic [(LANES*ELEM_W)-1:0] mask_narrow_result;
  logic mask_logic_illegal;
  logic [LANES-1:0] result_mask;
  logic [(LANES*ACC_W)-1:0] acc_src;
  logic [LANES-1:0] stored_exec_mask;
  logic [LANES-1:0] select_mask;
  logic [LANES-1:0] raw_exec_mask;
  logic [LANES-1:0] effective_select_mask;
  logic elem_mode_illegal;
  logic lane_exec_illegal;
  logic exec_illegal;
  logic route_illegal;
  logic operation_illegal;
  logic uop_illegal;
  logic uop_shape_legal;
  logic uop_mode_legal;
  logic uop_writeback_legal;
  logic uop_reduce_shape_legal;
  logic uop_route_shape_legal;
  logic uop_combined_legal;
  logic [LANES-1:0] raw_route_boundary_mask;
  logic reduce_illegal;
  logic raw_reduce_valid;
  logic [ACC_W-1:0] raw_reduce_value;
  logic [INDEX_W-1:0] raw_reduce_index;

  logic vrf_write_enable;
  logic [VRF_ADDR_W-1:0] vrf_write_addr;
  logic [LANES-1:0] vrf_write_mask;
  logic [(LANES*ELEM_W)-1:0] vrf_write_data;
  logic arf_write_enable;
  logic [ARF_ADDR_W-1:0] arf_write_addr;
  logic [LANES-1:0] arf_write_mask;
  logic [(LANES*ACC_W)-1:0] arf_write_data;
  logic mrf_write_enable;
  logic [MRF_ADDR_W-1:0] mrf_write_addr;
  logic [LANES-1:0] mrf_write_mask;
  logic [LANES-1:0] mrf_write_data;

  assign src_a = vrf_read_data[0 +: (LANES*ELEM_W)];
  assign src_b = vrf_read_data[(LANES*ELEM_W) +: (LANES*ELEM_W)];
  assign acc_src = arf_read_data;
  assign stored_exec_mask = mrf_read_data[0 +: LANES];
  assign select_mask = mrf_read_data[LANES +: LANES];
  assign raw_exec_mask = mask_enable_i ? stored_exec_mask : {LANES{1'b1}};
  assign exec_src_a = route_enable_i ? routed_src_a : src_a;
  assign compact_op = op_i == SIMD_OP_COMPRESS;
  assign expand_op = op_i == SIMD_OP_EXPAND;
  assign group_rearrange_op = compact_op || expand_op;
  assign mask_logic_op = (op_i == SIMD_OP_MAND) ||
                         (op_i == SIMD_OP_MOR) ||
                         (op_i == SIMD_OP_MXOR) ||
                         (op_i == SIMD_OP_MNOT);
  assign group_op = group_rearrange_op || mask_logic_op;
  assign wide_ternary_op = (op_i == SIMD_OP_WADD_U) ||
                           (op_i == SIMD_OP_WADD_S) ||
                           (op_i == SIMD_OP_WSUB_U) ||
                           (op_i == SIMD_OP_WSUB_S);
  // WADD/WSUB consume both VRF ports as data. Their immediate is instead a
  // common fixed-point alignment; without an immediate the alignment is zero.
  assign exec_src_b = (use_imm_i && !wide_ternary_op)
                          ? imm_broadcast : src_b;
  assign wide_align = (use_imm_i && wide_ternary_op)
                          ? imm_i[SCALE_W-1:0] : '0;
  // Rearrangement and MRF logic are whole-group operations. They bypass the
  // independent lane ALU, which intentionally reports their opcodes illegal.
  assign exec_illegal = group_rearrange_op ? 1'b0 :
                        mask_logic_op ? mask_logic_illegal : lane_exec_illegal;
  assign operation_illegal = elem_mode_illegal || !uop_shape_legal ||
                             exec_illegal ||
                             (route_enable_i && route_illegal);
  // A malformed optional reduction invalidates the complete issued
  // transaction. Reporting illegal while still committing the main ALU result
  // would violate the controller's no-side-effect error contract.
  assign uop_illegal = operation_illegal ||
                       (reduce_enable_i && reduce_illegal);
  assign uop_shape_legal = uop_combined_legal && uop_mode_legal &&
                           uop_writeback_legal && uop_reduce_shape_legal &&
                           uop_route_shape_legal;
  assign narrow_result_o = mask_logic_op ? mask_narrow_result :
                           group_rearrange_op ? compact_result :
                           lane_narrow_result;
  assign wide_result_o = group_op ? '0 : lane_wide_result;
  assign predicate_result_o = mask_logic_op ? mask_logic_result :
                                group_rearrange_op ? compact_result_mask :
                                lane_predicate_result;
  assign result_mask = mask_logic_op ? {LANES{1'b1}} :
                       group_rearrange_op ? compact_result_mask : exec_mask_o;
  assign route_boundary_mask_o = route_enable_i
                                     ? raw_route_boundary_mask : '0;

  // MRF storage remains one bit per physical byte lane. Wider logical
  // elements are active only when every constituent byte is active; the
  // effective mask is then replicated back across the complete element.
  always_comb begin
    exec_mask_o = '0;
    effective_select_mask = '0;
    imm_broadcast = '0;
    elem_mode_illegal = 1'b0;

    unique case (elem_mode_i)
      ELEM_MODE_BYTE: begin
        exec_mask_o = raw_exec_mask;
        effective_select_mask = select_mask;
        for (int lane = 0; lane < LANES; lane++) begin
          imm_broadcast[(lane*ELEM_W) +: ELEM_W] = imm_i[0 +: ELEM_W];
        end
      end
      ELEM_MODE_HALF: begin
        for (int element = 0; element < (LANES/2); element++) begin
          exec_mask_o[(element*2) +: 2] =
              {2{&raw_exec_mask[(element*2) +: 2]}};
          effective_select_mask[(element*2) +: 2] =
              {2{&select_mask[(element*2) +: 2]}};
          imm_broadcast[(element*2*ELEM_W) +: (2*ELEM_W)] =
              imm_i[0 +: (2*ELEM_W)];
        end
      end
      ELEM_MODE_WORD: begin
        for (int element = 0; element < (LANES/4); element++) begin
          exec_mask_o[(element*4) +: 4] =
              {4{&raw_exec_mask[(element*4) +: 4]}};
          effective_select_mask[(element*4) +: 4] =
              {4{&select_mask[(element*4) +: 4]}};
          imm_broadcast[(element*4*ELEM_W) +: (4*ELEM_W)] =
              imm_i[0 +: (4*ELEM_W)];
        end
      end
      default: elem_mode_illegal = 1'b1;
    endcase
  end

  simd_regfile #(
    .REG_COUNT(VREGS),
    .LANES(LANES),
    .ELEM_W(ELEM_W),
    .READ_PORTS(2),
    .ADDR_W(VRF_ADDR_W)
  ) u_vrf (
    .clk_i(clk_i),
    .read_addr_i({src_b_addr_i, src_a_addr_i}),
    .read_data_o(vrf_read_data),
    .write_enable_i(vrf_write_enable),
    .write_addr_i(vrf_write_addr),
    .write_mask_i(vrf_write_mask),
    .write_data_i(vrf_write_data)
  );

  simd_regfile #(
    .REG_COUNT(AREGS),
    .LANES(LANES),
    .ELEM_W(ACC_W),
    .READ_PORTS(1),
    .ADDR_W(ARF_ADDR_W)
  ) u_arf (
    .clk_i(clk_i),
    .read_addr_i(src_arf_addr_i),
    .read_data_o(arf_read_data),
    .write_enable_i(arf_write_enable),
    .write_addr_i(arf_write_addr),
    .write_mask_i(arf_write_mask),
    .write_data_i(arf_write_data)
  );

  simd_regfile #(
    .REG_COUNT(MREGS),
    .LANES(LANES),
    .ELEM_W(1),
    .READ_PORTS(2),
    .ADDR_W(MRF_ADDR_W)
  ) u_mrf (
    .clk_i(clk_i),
    .read_addr_i({select_mask_addr_i, exec_mask_addr_i}),
    .read_data_o(mrf_read_data),
    .write_enable_i(mrf_write_enable),
    .write_addr_i(mrf_write_addr),
    .write_mask_i(mrf_write_mask),
    .write_data_i(mrf_write_data)
  );

  simd_exec #(
    .LANES(LANES),
    .ELEM_W(ELEM_W),
    .ACC_W(ACC_W)
  ) u_exec (
    .op_i(op_i),
    .elem_mode_i(elem_mode_i),
    .mask_i(exec_mask_o),
    .select_i(effective_select_mask),
    .src_a_i(exec_src_a),
    .src_b_i(exec_src_b),
    .align_i(wide_align),
    .merge_i('0),
    .acc_i(acc_src),
    .result_o(lane_narrow_result),
    .wide_o(lane_wide_result),
    .predicate_o(lane_predicate_result),
    .illegal_o(lane_exec_illegal)
  );

  simd_uop_legal u_uop_legal (
    .op_i(op_i),
    .elem_mode_i(elem_mode_i),
    .write_vrf_i(write_vrf_i),
    .write_arf_i(write_arf_i),
    .write_mrf_i(write_mrf_i),
    .reduce_enable_i(reduce_enable_i),
    .route_enable_i(route_enable_i),
    .mode_legal_o(uop_mode_legal),
    .writeback_legal_o(uop_writeback_legal),
    .reduce_legal_o(uop_reduce_shape_legal),
    .route_legal_o(uop_route_shape_legal),
    .legal_o(uop_combined_legal)
  );

  simd_compact #(
    .LANES(LANES),
    .DATA_W(ELEM_W),
    .COUNT_W(OFFSET_W)
  ) u_compact (
    .expand_i(expand_op),
    .data_i(exec_src_a),
    .mask_i(exec_mask_o),
    .data_o(compact_result),
    .valid_mask_o(compact_result_mask),
    .count_o(raw_compact_count)
  );

  simd_mask_alu #(
    .LANES(LANES)
  ) u_mask_alu (
    .op_i(op_i),
    .a_i(stored_exec_mask),
    .b_i(select_mask),
    .result_o(mask_logic_result),
    .illegal_o(mask_logic_illegal)
  );

  generate
    for (genvar lane = 0; lane < LANES; lane++) begin : gen_mask_narrow
      assign mask_narrow_result[(lane*ELEM_W) +: ELEM_W] =
          {ELEM_W{mask_logic_result[lane]}};
    end
  endgenerate

  simd_route #(
    .LANES(LANES),
    .DATA_W(ELEM_W),
    .INDEX_W(INDEX_W),
    .OFFSET_W(OFFSET_W)
  ) u_route (
    .op_i(route_op_i),
    .data_i(src_a),
    .index_i(route_index_i),
    .broadcast_index_i(route_broadcast_index_i),
    .slide_amount_i(route_slide_amount_i),
    .lower_i(route_lower_i),
    .upper_i(route_upper_i),
    .data_o(routed_src_a),
    .boundary_mask_o(raw_route_boundary_mask),
    .illegal_o(route_illegal)
  );

  simd_reduce #(
    .LANES(LANES),
    .DATA_W(ELEM_W),
    .ACC_W(ACC_W),
    .INDEX_W(INDEX_W)
  ) u_reduce (
    .op_i(reduce_op_i),
    .mask_i(result_mask),
    .data_i(narrow_result_o),
    .value_o(raw_reduce_value),
    .index_o(raw_reduce_index),
    .valid_o(raw_reduce_valid),
    .illegal_o(reduce_illegal)
  );

  always_comb begin
    vrf_write_enable = issue_i && write_vrf_i && !uop_illegal;
    vrf_write_addr = dst_vrf_addr_i;
    // Rearrangement writes the complete row so inactive destinations become
    // defined zeros. compact_result_mask separately records which lanes carry
    // data after the rearrangement.
    vrf_write_mask = group_op ? {LANES{1'b1}} : exec_mask_o;
    vrf_write_data = narrow_result_o;
    if (cfg_vrf_write_i) begin
      vrf_write_enable = 1'b1;
      vrf_write_addr = cfg_vrf_addr_i;
      vrf_write_mask = cfg_vrf_mask_i;
      vrf_write_data = cfg_vrf_data_i;
    end

    arf_write_enable = issue_i && write_arf_i && !uop_illegal;
    arf_write_addr = dst_arf_addr_i;
    arf_write_mask = exec_mask_o;
    arf_write_data = wide_result_o;
    if (cfg_arf_write_i) begin
      arf_write_enable = 1'b1;
      arf_write_addr = cfg_arf_addr_i;
      arf_write_mask = cfg_arf_mask_i;
      arf_write_data = cfg_arf_data_i;
    end

    mrf_write_enable = issue_i && write_mrf_i && !uop_illegal;
    mrf_write_addr = dst_mrf_addr_i;
    mrf_write_mask = group_op ? {LANES{1'b1}} : exec_mask_o;
    mrf_write_data = predicate_result_o;
    if (cfg_mrf_write_i) begin
      mrf_write_enable = 1'b1;
      mrf_write_addr = cfg_mrf_addr_i;
      mrf_write_mask = cfg_mrf_mask_i;
      mrf_write_data = cfg_mrf_data_i;
    end

    reduce_value_o = (issue_i && reduce_enable_i && raw_reduce_valid &&
                      !uop_illegal)
                         ? raw_reduce_value : '0;
    reduce_index_o = (issue_i && reduce_enable_i && raw_reduce_valid &&
                      !uop_illegal)
                         ? raw_reduce_index : '0;
    reduce_valid_o = issue_i && reduce_enable_i && raw_reduce_valid &&
                     !uop_illegal;
    compact_count_o = (issue_i && group_rearrange_op && !uop_illegal)
                          ? raw_compact_count : '0;
    compact_valid_o = issue_i && group_rearrange_op && !uop_illegal;
    illegal_o = issue_i && uop_illegal;
  end

  initial begin
    if (VRF_ADDR_W != ((VREGS <= 2) ? 1 : $clog2(VREGS))) begin
      $error("VRF_ADDR_W must match VREGS");
    end
    if (ARF_ADDR_W != ((AREGS <= 2) ? 1 : $clog2(AREGS))) begin
      $error("ARF_ADDR_W must match AREGS");
    end
    if (MRF_ADDR_W != ((MREGS <= 2) ? 1 : $clog2(MREGS))) begin
      $error("MRF_ADDR_W must match MREGS");
    end
    if (INDEX_W != ((LANES <= 2) ? 1 : $clog2(LANES))) begin
      $error("INDEX_W must match LANES");
    end
    if (OFFSET_W != $clog2(LANES + 1)) begin
      $error("OFFSET_W must represent slide amounts 0 through LANES");
    end
  end
endmodule
