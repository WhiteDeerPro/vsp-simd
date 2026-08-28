package simd_pkg;
  localparam int SIMD_OP_W = 6;

  // Kind of a child transaction accepted by one group wrapper. This is
  // canonical internal metadata, not an encoded ISA field or the controller
  // dispatch class (GROUP_EXEC/MEMORY/CONTROLLER). A future
  // sequencer may derive it from a compact action word without exposing that
  // encoding at the SIMD4 boundary.
  localparam int SIMD_GROUP_REQ_KIND_W = 1;

  typedef enum logic [SIMD_GROUP_REQ_KIND_W-1:0] {
    SIMD_GROUP_REQ_EXEC        = 1'b0,
    SIMD_GROUP_REQ_STATE_WRITE = 1'b1
  } simd_group_req_kind_e;

  localparam int SIMD_RF_FILE_W = 2;

  typedef enum logic [SIMD_RF_FILE_W-1:0] {
    SIMD_RF_VRF = 2'h0,
    SIMD_RF_ARF = 2'h1,
    SIMD_RF_MRF = 2'h2
  } simd_rf_file_e;

  localparam int ELEM_MODE_W = 2;

  typedef enum logic [ELEM_MODE_W-1:0] {
    // The physical register and route granularity remains one base lane. The
    // mode groups 1, 2, or 4 adjacent base lanes into one logical element.
    ELEM_MODE_BYTE = 2'h0,
    ELEM_MODE_HALF = 2'h1,
    ELEM_MODE_WORD = 2'h2
  } elem_mode_e;

  typedef enum logic [SIMD_OP_W-1:0] {
    // Narrow lane-local arithmetic. ADD/SUB wrap at ELEM_W.
    SIMD_OP_ADD          = 6'h00,
    SIMD_OP_SUB          = 6'h01,

    // Saturating ELEM_W arithmetic in unsigned and signed domains.
    SIMD_OP_ADD_SAT_U    = 6'h02,
    SIMD_OP_SUB_SAT_U    = 6'h03,
    SIMD_OP_ADD_SAT_S    = 6'h04,
    SIMD_OP_SUB_SAT_S    = 6'h05,

    // Per-lane extrema. The suffix selects unsigned or signed comparison.
    SIMD_OP_MIN_U        = 6'h06,
    SIMD_OP_MAX_U        = 6'h07,
    SIMD_OP_MIN_S        = 6'h08,
    SIMD_OP_MAX_S        = 6'h09,

    // Unsigned absolute difference and ceil((a + b) / 2).
    SIMD_OP_ABSDIFF_U    = 6'h0a,
    SIMD_OP_AVG_U        = 6'h0b,

    // Bitwise operations on ELEM_W lanes.
    SIMD_OP_AND          = 6'h0c,
    SIMD_OP_OR           = 6'h0d,
    SIMD_OP_XOR          = 6'h0e,

    // Per-lane shifts. The low log2(ELEM_W) bits of b are the shift amount.
    SIMD_OP_SHL          = 6'h0f,
    SIMD_OP_SHR_U        = 6'h10,
    SIMD_OP_SHR_S        = 6'h11,

    // Comparisons write predicate_o and also return all-ones or zero.
    SIMD_OP_CMPEQ        = 6'h12,
    SIMD_OP_CMPGT_U      = 6'h13,
    SIMD_OP_CMPGT_S      = 6'h14,

    // Signed absolute value; the most-negative input saturates to max-positive.
    SIMD_OP_ABS_SAT_S    = 6'h15,

    // Full-width multiply. result_o receives the low ELEM_W product bits;
    // wide_o receives the complete signed or unsigned product.
    SIMD_OP_MUL_U        = 6'h16,
    SIMD_OP_MUL_S        = 6'h17,

    // ACC_W multiply-accumulate: wide_o = acc_i + (a * b), wrapping at ACC_W.
    // result_o still receives the low ELEM_W product bits.
    SIMD_OP_MAC_U        = 6'h18,
    SIMD_OP_MAC_S        = 6'h19,

    // Data selection. SELECT chooses a or b using the independent select_i bit;
    // mask_i remains the execution/commit mask at the vector wrapper.
    SIMD_OP_PASS_A       = 6'h1a,
    SIMD_OP_SELECT       = 6'h1b,

    // Convert source a to ACC_W, then shift it left by the low log2(ACC_W)
    // bits of source b. A zero shift retains ordinary widening semantics.
    SIMD_OP_WIDEN_U      = 6'h1c,
    SIMD_OP_WIDEN_S      = 6'h1d,

    // Three-input wide arithmetic. Sources a and b are independently extended
    // and shifted by one shared scalar alignment amount before entering an
    // ACC_W 3:2 compressor with acc_i.
    // WADD: acc_i + aligned_a + aligned_b.
    SIMD_OP_WADD_U       = 6'h1e,
    SIMD_OP_WADD_S       = 6'h1f,

    // WSUB: acc_i + aligned_a - aligned_b. Encodings remain distinct so the
    // unsigned domain does not need to construct a negative source value.
    SIMD_OP_WSUB_U       = 6'h20,
    SIMD_OP_WSUB_S       = 6'h21,

    // Round-to-nearest-up scaling of acc_i. The low log2(ACC_W) bits of b
    // select a logical (U) or arithmetic (S) right shift amount.
    SIMD_OP_RSHIFT_RND_U = 6'h22,
    SIMD_OP_RSHIFT_RND_S = 6'h23,

    // Fused rounded right shift, saturation, and narrowing to ELEM_W.
    SIMD_OP_NCLIP_U      = 6'h24,
    SIMD_OP_NCLIP_S      = 6'h25,

    // Logical right shift of acc_i followed by direct ELEM_W-bit slicing.
    // Unlike NCLIP, this operation performs neither rounding nor saturation.
    SIMD_OP_NSLICE       = 6'h26,

    // Signed round-to-nearest-up average. Kept at the next free encoding so
    // existing experimental operation numbers remain stable.
    SIMD_OP_AVG_S        = 6'h27,

    // Group-level stable mask rearrangement. These operations are handled by
    // simd_datapath's compaction path rather than by each independent lane.
    SIMD_OP_COMPRESS     = 6'h28,
    SIMD_OP_EXPAND       = 6'h29,

    // MRF boolean operations. The two MRF read ports are data operands rather
    // than execution/select controls while one of these operations is issued.
    SIMD_OP_MAND         = 6'h2a,
    SIMD_OP_MOR          = 6'h2b,
    SIMD_OP_MXOR         = 6'h2c,
    SIMD_OP_MNOT         = 6'h2d
  } simd_op_e;

  localparam int REDUCE_OP_W = 3;

  typedef enum logic [REDUCE_OP_W-1:0] {
    // SUM wraps at ACC_W. index_o is not meaningful for SUM.
    REDUCE_OP_SUM_U = 3'h0,
    REDUCE_OP_SUM_S = 3'h1,

    // MIN/MAX return both the extended value and the winning lane index.
    // Equal values select the lowest active lane index.
    REDUCE_OP_MIN_U = 3'h2,
    REDUCE_OP_MIN_S = 3'h3,
    REDUCE_OP_MAX_U = 3'h4,
    REDUCE_OP_MAX_S = 3'h5
  } reduce_op_e;

  localparam int ROUTE_OP_W = 2;

  typedef enum logic [ROUTE_OP_W-1:0] {
    // Every output independently selects an input lane. Unique indices form a
    // permutation; repeated indices implement gather, multicast or broadcast.
    ROUTE_OP_GATHER     = 2'h0,

    // All output lanes select broadcast_index_i. This is a compact control
    // form of GATHER rather than a different data network.
    ROUTE_OP_BROADCAST  = 2'h1,

    // Move toward higher lane numbers. Missing low lanes come from the lower
    // adjacent SIMD group, or become zero when lower_i is tied low.
    ROUTE_OP_SLIDE_UP   = 2'h2,

    // Move toward lower lane numbers. Missing high lanes come from the upper
    // adjacent SIMD group, or become zero when upper_i is tied low.
    ROUTE_OP_SLIDE_DOWN = 2'h3
  } route_op_e;

  // Operation capability helpers are shared by the group datapath and the
  // future cluster controller. They describe architectural result shapes;
  // merely having a value on a combinational result bus does not make that
  // value a legal writeback for every operation.
  function automatic logic simd_op_defined(
      input logic [SIMD_OP_W-1:0] op);
    case (op)
      SIMD_OP_ADD, SIMD_OP_SUB,
      SIMD_OP_ADD_SAT_U, SIMD_OP_SUB_SAT_U,
      SIMD_OP_ADD_SAT_S, SIMD_OP_SUB_SAT_S,
      SIMD_OP_MIN_U, SIMD_OP_MAX_U, SIMD_OP_MIN_S, SIMD_OP_MAX_S,
      SIMD_OP_ABSDIFF_U, SIMD_OP_AVG_U, SIMD_OP_AVG_S,
      SIMD_OP_AND, SIMD_OP_OR, SIMD_OP_XOR,
      SIMD_OP_SHL, SIMD_OP_SHR_U, SIMD_OP_SHR_S,
      SIMD_OP_CMPEQ, SIMD_OP_CMPGT_U, SIMD_OP_CMPGT_S,
      SIMD_OP_ABS_SAT_S,
      SIMD_OP_MUL_U, SIMD_OP_MUL_S, SIMD_OP_MAC_U, SIMD_OP_MAC_S,
      SIMD_OP_PASS_A, SIMD_OP_SELECT,
      SIMD_OP_WIDEN_U, SIMD_OP_WIDEN_S,
      SIMD_OP_WADD_U, SIMD_OP_WADD_S,
      SIMD_OP_WSUB_U, SIMD_OP_WSUB_S,
      SIMD_OP_RSHIFT_RND_U, SIMD_OP_RSHIFT_RND_S,
      SIMD_OP_NCLIP_U, SIMD_OP_NCLIP_S, SIMD_OP_NSLICE,
      SIMD_OP_COMPRESS, SIMD_OP_EXPAND,
      SIMD_OP_MAND, SIMD_OP_MOR, SIMD_OP_MXOR, SIMD_OP_MNOT:
        simd_op_defined = 1'b1;
      default: simd_op_defined = 1'b0;
    endcase
  endfunction

  function automatic logic simd_op_mode_legal(
      input logic [SIMD_OP_W-1:0] op,
      input logic [ELEM_MODE_W-1:0] mode);
    logic supports_dynamic_mode;
    begin
      case (op)
        SIMD_OP_ADD, SIMD_OP_SUB,
        SIMD_OP_MIN_U, SIMD_OP_MAX_U, SIMD_OP_MIN_S, SIMD_OP_MAX_S,
        SIMD_OP_AND, SIMD_OP_OR, SIMD_OP_XOR,
        SIMD_OP_SHL, SIMD_OP_SHR_U, SIMD_OP_SHR_S,
        SIMD_OP_CMPEQ, SIMD_OP_CMPGT_U, SIMD_OP_CMPGT_S,
        SIMD_OP_PASS_A, SIMD_OP_SELECT,
        SIMD_OP_COMPRESS, SIMD_OP_EXPAND:
          supports_dynamic_mode = 1'b1;
        default: supports_dynamic_mode = 1'b0;
      endcase

      simd_op_mode_legal = simd_op_defined(op) &&
          (supports_dynamic_mode
               ? ((mode == ELEM_MODE_BYTE) ||
                  (mode == ELEM_MODE_HALF) ||
                  (mode == ELEM_MODE_WORD))
               : (mode == ELEM_MODE_BYTE));
    end
  endfunction

  function automatic logic simd_op_can_write_vrf(
      input logic [SIMD_OP_W-1:0] op);
    case (op)
      SIMD_OP_ADD, SIMD_OP_SUB,
      SIMD_OP_ADD_SAT_U, SIMD_OP_SUB_SAT_U,
      SIMD_OP_ADD_SAT_S, SIMD_OP_SUB_SAT_S,
      SIMD_OP_MIN_U, SIMD_OP_MAX_U, SIMD_OP_MIN_S, SIMD_OP_MAX_S,
      SIMD_OP_ABSDIFF_U, SIMD_OP_AVG_U, SIMD_OP_AVG_S,
      SIMD_OP_AND, SIMD_OP_OR, SIMD_OP_XOR,
      SIMD_OP_SHL, SIMD_OP_SHR_U, SIMD_OP_SHR_S,
      SIMD_OP_CMPEQ, SIMD_OP_CMPGT_U, SIMD_OP_CMPGT_S,
      SIMD_OP_ABS_SAT_S,
      SIMD_OP_MUL_U, SIMD_OP_MUL_S, SIMD_OP_MAC_U, SIMD_OP_MAC_S,
      SIMD_OP_PASS_A, SIMD_OP_SELECT,
      SIMD_OP_NCLIP_U, SIMD_OP_NCLIP_S, SIMD_OP_NSLICE,
      SIMD_OP_COMPRESS, SIMD_OP_EXPAND,
      SIMD_OP_MAND, SIMD_OP_MOR, SIMD_OP_MXOR, SIMD_OP_MNOT:
        simd_op_can_write_vrf = 1'b1;
      default: simd_op_can_write_vrf = 1'b0;
    endcase
  endfunction

  function automatic logic simd_op_can_write_arf(
      input logic [SIMD_OP_W-1:0] op);
    case (op)
      SIMD_OP_MUL_U, SIMD_OP_MUL_S, SIMD_OP_MAC_U, SIMD_OP_MAC_S,
      SIMD_OP_WIDEN_U, SIMD_OP_WIDEN_S,
      SIMD_OP_WADD_U, SIMD_OP_WADD_S,
      SIMD_OP_WSUB_U, SIMD_OP_WSUB_S,
      SIMD_OP_RSHIFT_RND_U, SIMD_OP_RSHIFT_RND_S:
        simd_op_can_write_arf = 1'b1;
      default: simd_op_can_write_arf = 1'b0;
    endcase
  endfunction

  function automatic logic simd_op_can_write_mrf(
      input logic [SIMD_OP_W-1:0] op);
    case (op)
      SIMD_OP_CMPEQ, SIMD_OP_CMPGT_U, SIMD_OP_CMPGT_S,
      SIMD_OP_COMPRESS, SIMD_OP_EXPAND,
      SIMD_OP_MAND, SIMD_OP_MOR, SIMD_OP_MXOR, SIMD_OP_MNOT:
        simd_op_can_write_mrf = 1'b1;
      default: simd_op_can_write_mrf = 1'b0;
    endcase
  endfunction

  function automatic logic simd_op_can_reduce(
      input logic [SIMD_OP_W-1:0] op,
      input logic [ELEM_MODE_W-1:0] mode);
    logic narrow_reducible;
    begin
      case (op)
        SIMD_OP_ADD, SIMD_OP_SUB,
        SIMD_OP_ADD_SAT_U, SIMD_OP_SUB_SAT_U,
        SIMD_OP_ADD_SAT_S, SIMD_OP_SUB_SAT_S,
        SIMD_OP_MIN_U, SIMD_OP_MAX_U, SIMD_OP_MIN_S, SIMD_OP_MAX_S,
        SIMD_OP_ABSDIFF_U, SIMD_OP_AVG_U, SIMD_OP_AVG_S,
        SIMD_OP_AND, SIMD_OP_OR, SIMD_OP_XOR,
        SIMD_OP_SHL, SIMD_OP_SHR_U, SIMD_OP_SHR_S,
        SIMD_OP_ABS_SAT_S,
        SIMD_OP_MUL_U, SIMD_OP_MUL_S, SIMD_OP_MAC_U, SIMD_OP_MAC_S,
        SIMD_OP_PASS_A, SIMD_OP_SELECT,
        SIMD_OP_NCLIP_U, SIMD_OP_NCLIP_S, SIMD_OP_NSLICE,
        SIMD_OP_COMPRESS, SIMD_OP_EXPAND:
          narrow_reducible = 1'b1;
        default: narrow_reducible = 1'b0;
      endcase
      // simd_reduce consumes physical byte lanes. Wider logical-element
      // reduction must first be made explicit by narrow/slice micro-ops.
      simd_op_can_reduce = narrow_reducible && (mode == ELEM_MODE_BYTE);
    end
  endfunction

  function automatic logic simd_op_can_route_a(
      input logic [SIMD_OP_W-1:0] op);
    case (op)
      SIMD_OP_RSHIFT_RND_U, SIMD_OP_RSHIFT_RND_S,
      SIMD_OP_NCLIP_U, SIMD_OP_NCLIP_S, SIMD_OP_NSLICE,
      SIMD_OP_MAND, SIMD_OP_MOR, SIMD_OP_MXOR, SIMD_OP_MNOT:
        simd_op_can_route_a = 1'b0;
      default: simd_op_can_route_a = simd_op_defined(op);
    endcase
  endfunction

  // Canonical GROUP_EXEC transactions return a separate result record only
  // when the caller explicitly exports the narrow value, requests a
  // reduction, or executes a compact operation whose count is observable.
  // Keep this predicate shared by the group endpoint and the cluster tracker
  // so admission never reserves a different result lifetime than the child
  // later reports in its completion.
  function automatic logic simd_exec_requires_result(
      input logic [SIMD_OP_W-1:0] op,
      input logic export_narrow,
      input logic reduce_enable);
    simd_exec_requires_result = export_narrow || reduce_enable ||
        (op == SIMD_OP_COMPRESS) || (op == SIMD_OP_EXPAND);
  endfunction
endpackage
