package vsp_exec_uword_pkg;
  // Experimental compact representation used between a VSP sequencer and
  // the canonical EXEC boundary.  Profile v0 deliberately targets the
  // current SIMD4 shape (8-bit physical lanes, 32-bit accumulators,
  // 16/8/4 VRF/ARF/MRF rows).  It is not an architectural instruction-set
  // encoding. Register-to-register routing is intentionally not assigned an
  // executable format in this profile; it remains an independently driven
  // cluster experiment.
  localparam int VSP_EXEC_UWORD_W = 32;
  localparam int VSP_EXEC_UWORD_FORMAT_W = 4;
  // Internal route-wave roles retained for the standalone route experiment.
  // They are not decoded from a profile-v0 EXEC word.
  localparam int VSP_EXEC_ROUTE_IO_W = 2;
  localparam logic [VSP_EXEC_ROUTE_IO_W-1:0]
      VSP_EXEC_ROUTE_IO_LOCAL     = 2'b00;
  localparam logic [VSP_EXEC_ROUTE_IO_W-1:0]
      VSP_EXEC_ROUTE_IO_DEP_IN    = 2'b01;
  localparam logic [VSP_EXEC_ROUTE_IO_W-1:0]
      VSP_EXEC_ROUTE_IO_DEP_OUT   = 2'b10;
  localparam logic [VSP_EXEC_ROUTE_IO_W-1:0]
      VSP_EXEC_ROUTE_IO_DEP_INOUT = 2'b11;

  // Internal route-wave terminal categories.  These belong to the
  // rendezvous/completion protocol rather than the instruction encoding.
  localparam int VSP_ROUTE_TERMINAL_KIND_W = 2;
  localparam logic [VSP_ROUTE_TERMINAL_KIND_W-1:0]
      VSP_ROUTE_TERMINAL_WAVE   = 2'd0;
  localparam logic [VSP_ROUTE_TERMINAL_KIND_W-1:0]
      VSP_ROUTE_TERMINAL_REJECT = 2'd1;
  localparam logic [VSP_ROUTE_TERMINAL_KIND_W-1:0]
      VSP_ROUTE_TERMINAL_CANCEL = 2'd2;

  // Pairing remains an internal property of the standalone route-wave
  // protocol, not an instruction predecode result.
  function automatic logic vsp_exec_route_mode_pair_required(
      input logic [VSP_EXEC_ROUTE_IO_W-1:0] mode);
    vsp_exec_route_mode_pair_required =
        mode == VSP_EXEC_ROUTE_IO_DEP_IN ||
        mode == VSP_EXEC_ROUTE_IO_DEP_OUT;
  endfunction

  typedef enum logic [VSP_EXEC_UWORD_FORMAT_W-1:0] {
    VSP_EXEC_UWORD_FMT_ALU          = 4'h1,
    VSP_EXEC_UWORD_FMT_CMP          = 4'h2,
    VSP_EXEC_UWORD_FMT_SELECT       = 4'h3,
    VSP_EXEC_UWORD_FMT_MUL          = 4'h4,
    VSP_EXEC_UWORD_FMT_MAC_RR       = 4'h5,
    VSP_EXEC_UWORD_FMT_MAC_RI       = 4'h6,
    VSP_EXEC_UWORD_FMT_WIDE_CONVERT = 4'h7,
    VSP_EXEC_UWORD_FMT_WADD_WSUB    = 4'h8,
    VSP_EXEC_UWORD_FMT_COMPACT      = 4'h9,
    VSP_EXEC_UWORD_FMT_MRF_LOGIC    = 4'ha
  } vsp_exec_uword_format_e;

  // ALU-format sub-functions.  Values 21..31 remain available to a later
  // profile revision and are rejected by profile v0.
  localparam logic [4:0] VSP_EXEC_ALU_ADD       = 5'd0;
  localparam logic [4:0] VSP_EXEC_ALU_SUB       = 5'd1;
  localparam logic [4:0] VSP_EXEC_ALU_ADD_SAT_U = 5'd2;
  localparam logic [4:0] VSP_EXEC_ALU_SUB_SAT_U = 5'd3;
  localparam logic [4:0] VSP_EXEC_ALU_ADD_SAT_S = 5'd4;
  localparam logic [4:0] VSP_EXEC_ALU_SUB_SAT_S = 5'd5;
  localparam logic [4:0] VSP_EXEC_ALU_MIN_U     = 5'd6;
  localparam logic [4:0] VSP_EXEC_ALU_MAX_U     = 5'd7;
  localparam logic [4:0] VSP_EXEC_ALU_MIN_S     = 5'd8;
  localparam logic [4:0] VSP_EXEC_ALU_MAX_S     = 5'd9;
  localparam logic [4:0] VSP_EXEC_ALU_ABSDIFF_U = 5'd10;
  localparam logic [4:0] VSP_EXEC_ALU_AVG_U     = 5'd11;
  localparam logic [4:0] VSP_EXEC_ALU_AVG_S     = 5'd12;
  localparam logic [4:0] VSP_EXEC_ALU_AND       = 5'd13;
  localparam logic [4:0] VSP_EXEC_ALU_OR        = 5'd14;
  localparam logic [4:0] VSP_EXEC_ALU_XOR       = 5'd15;
  localparam logic [4:0] VSP_EXEC_ALU_SHL       = 5'd16;
  localparam logic [4:0] VSP_EXEC_ALU_SHR_U     = 5'd17;
  localparam logic [4:0] VSP_EXEC_ALU_SHR_S     = 5'd18;
  localparam logic [4:0] VSP_EXEC_ALU_ABS_SAT_S = 5'd19;
  localparam logic [4:0] VSP_EXEC_ALU_PASS_A    = 5'd20;

  localparam logic [1:0] VSP_EXEC_CMP_EQ   = 2'd0;
  localparam logic [1:0] VSP_EXEC_CMP_GT_U = 2'd1;
  localparam logic [1:0] VSP_EXEC_CMP_GT_S = 2'd2;

  localparam logic [2:0] VSP_EXEC_WIDE_WIDEN_U  = 3'd0;
  localparam logic [2:0] VSP_EXEC_WIDE_WIDEN_S  = 3'd1;
  localparam logic [2:0] VSP_EXEC_WIDE_RSHIFT_U = 3'd2;
  localparam logic [2:0] VSP_EXEC_WIDE_RSHIFT_S = 3'd3;
  localparam logic [2:0] VSP_EXEC_WIDE_NCLIP_U  = 3'd4;
  localparam logic [2:0] VSP_EXEC_WIDE_NCLIP_S  = 3'd5;
  localparam logic [2:0] VSP_EXEC_WIDE_NSLICE   = 3'd6;

  localparam logic [1:0] VSP_EXEC_WADD_U = 2'd0;
  localparam logic [1:0] VSP_EXEC_WADD_S = 2'd1;
  localparam logic [1:0] VSP_EXEC_WSUB_U = 2'd2;
  localparam logic [1:0] VSP_EXEC_WSUB_S = 2'd3;

  localparam logic [1:0] VSP_EXEC_MRF_AND = 2'd0;
  localparam logic [1:0] VSP_EXEC_MRF_OR  = 2'd1;
  localparam logic [1:0] VSP_EXEC_MRF_XOR = 2'd2;
  localparam logic [1:0] VSP_EXEC_MRF_NOT = 2'd3;

  // mask_sel combines the execution-mask enable and row.  Zero means
  // unmasked; one through four select MRF0 through MRF3.
  localparam logic [2:0] VSP_EXEC_MASK_NONE = 3'd0;
  localparam logic [2:0] VSP_EXEC_MASK_M0   = 3'd1;
  localparam logic [2:0] VSP_EXEC_MASK_M1   = 3'd2;
  localparam logic [2:0] VSP_EXEC_MASK_M2   = 3'd3;
  localparam logic [2:0] VSP_EXEC_MASK_M3   = 3'd4;

  // reduction_sel similarly combines enable and function.  Nonzero values
  // map to simd_pkg::reduce_op_e by subtracting one.
  localparam logic [2:0] VSP_EXEC_REDUCE_NONE  = 3'd0;
  localparam logic [2:0] VSP_EXEC_REDUCE_SUM_U = 3'd1;
  localparam logic [2:0] VSP_EXEC_REDUCE_SUM_S = 3'd2;
  localparam logic [2:0] VSP_EXEC_REDUCE_MIN_U = 3'd3;
  localparam logic [2:0] VSP_EXEC_REDUCE_MIN_S = 3'd4;
  localparam logic [2:0] VSP_EXEC_REDUCE_MAX_U = 3'd5;
  localparam logic [2:0] VSP_EXEC_REDUCE_MAX_S = 3'd6;

  localparam int VSP_EXEC_UWORD_ERROR_W = 4;

  // Profile-local diagnostics carried by an ordered illegal completion.  They
  // are decoder errors, not architectural exceptions.  The numeric order is
  // also the priority used when one word violates more than one rule.
  typedef enum logic [VSP_EXEC_UWORD_ERROR_W-1:0] {
    VSP_EXEC_UWORD_ERROR_NONE                = 4'h0,
    VSP_EXEC_UWORD_ERROR_BAD_FORMAT          = 4'h1,
    VSP_EXEC_UWORD_ERROR_BAD_SUBOP           = 4'h2,
    VSP_EXEC_UWORD_ERROR_RESERVED_BITS       = 4'h3,
    VSP_EXEC_UWORD_ERROR_EXTENSION           = 4'h4,
    VSP_EXEC_UWORD_ERROR_IMMEDIATE           = 4'h5,
    VSP_EXEC_UWORD_ERROR_MASK                = 4'h6,
    VSP_EXEC_UWORD_ERROR_REDUCTION           = 4'h7,
    VSP_EXEC_UWORD_ERROR_MODE                = 4'h8,
    VSP_EXEC_UWORD_ERROR_WRITEBACK_OR_EXPORT = 4'h9,
    VSP_EXEC_UWORD_ERROR_ADDRESS             = 4'ha,
    VSP_EXEC_UWORD_ERROR_UNUSED_FIELD        = 4'hb,
    VSP_EXEC_UWORD_ERROR_NO_EFFECT           = 4'hc,
    VSP_EXEC_UWORD_ERROR_INTERNAL            = 4'hd
  } vsp_exec_uword_error_e;

  function automatic logic vsp_exec_uword_format_defined(
      input logic [VSP_EXEC_UWORD_FORMAT_W-1:0] format);
    case (format)
      VSP_EXEC_UWORD_FMT_ALU,
      VSP_EXEC_UWORD_FMT_CMP,
      VSP_EXEC_UWORD_FMT_SELECT,
      VSP_EXEC_UWORD_FMT_MUL,
      VSP_EXEC_UWORD_FMT_MAC_RR,
      VSP_EXEC_UWORD_FMT_MAC_RI,
      VSP_EXEC_UWORD_FMT_WIDE_CONVERT,
      VSP_EXEC_UWORD_FMT_WADD_WSUB,
      VSP_EXEC_UWORD_FMT_COMPACT,
      VSP_EXEC_UWORD_FMT_MRF_LOGIC:
        vsp_exec_uword_format_defined = 1'b1;
      default: vsp_exec_uword_format_defined = 1'b0;
    endcase
  endfunction

  // Record framing needs to know whether an EXEC base word owns the following
  // stream word before the full canonical decode runs. Keep that decision in
  // the profile package so a uword-bundle predecoder and the canonical
  // expander cannot silently disagree about EXEC packet boundaries.
  /* verilator lint_off UNUSED */
  function automatic logic vsp_exec_uword_extension_required(
      input logic [VSP_EXEC_UWORD_W-1:0] base_word);
    unique case (base_word[31:28])
      VSP_EXEC_UWORD_FMT_ALU:
        vsp_exec_uword_extension_required = base_word[5];
      VSP_EXEC_UWORD_FMT_CMP:
        vsp_exec_uword_extension_required = base_word[6];
      VSP_EXEC_UWORD_FMT_SELECT,
      VSP_EXEC_UWORD_FMT_MUL:
        vsp_exec_uword_extension_required = base_word[8];
      VSP_EXEC_UWORD_FMT_MAC_RI:
        vsp_exec_uword_extension_required = 1'b1;
      VSP_EXEC_UWORD_FMT_WIDE_CONVERT:
        vsp_exec_uword_extension_required = base_word[9];
      default:
        vsp_exec_uword_extension_required = 1'b0;
    endcase
  endfunction
  /* verilator lint_on UNUSED */

  function automatic logic vsp_exec_mask_sel_defined(
      input logic [2:0] mask_sel);
    vsp_exec_mask_sel_defined = mask_sel <= VSP_EXEC_MASK_M3;
  endfunction

  function automatic logic vsp_exec_reduce_sel_defined(
      input logic [2:0] reduce_sel);
    vsp_exec_reduce_sel_defined = reduce_sel <= VSP_EXEC_REDUCE_MAX_S;
  endfunction
endpackage
