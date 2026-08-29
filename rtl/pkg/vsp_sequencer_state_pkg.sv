package vsp_sequencer_state_pkg;
  // Decoded operations for the sequencer-local address state.  These values
  // are internal action semantics, not a frozen CONTROL-uword encoding.
  localparam int VSP_STATE_OP_W = 2;

  typedef enum logic [VSP_STATE_OP_W-1:0] {
    VSP_STATE_OP_SMOVI = 2'h0,
    VSP_STATE_OP_SADD  = 2'h1,
    VSP_STATE_OP_SADDI = 2'h2
  } vsp_state_op_e;

  function automatic logic vsp_state_op_defined(
      input logic [VSP_STATE_OP_W-1:0] state_op);
    unique case (state_op)
      VSP_STATE_OP_SMOVI,
      VSP_STATE_OP_SADD,
      VSP_STATE_OP_SADDI: vsp_state_op_defined = 1'b1;
      default: vsp_state_op_defined = 1'b0;
    endcase
  endfunction

  localparam int VSP_STATE_CPL_STATUS_W = 2;

  typedef enum logic [VSP_STATE_CPL_STATUS_W-1:0] {
    VSP_STATE_CPL_OK           = 2'h0,
    VSP_STATE_CPL_BAD_OP       = 2'h1,
    VSP_STATE_CPL_BAD_CONTEXT  = 2'h2,
    VSP_STATE_CPL_BAD_REGISTER = 2'h3
  } vsp_state_cpl_status_e;
endpackage
