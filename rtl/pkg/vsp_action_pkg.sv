package vsp_action_pkg;
  // Canonical controller-side categories.  These values classify decoded
  // actions; they are not an external instruction encoding.
  localparam int VSP_ACTION_CLASS_W = 2;

  typedef enum logic [VSP_ACTION_CLASS_W-1:0] {
    VSP_ACTION_CLASS_EXEC    = 2'h0,
    VSP_ACTION_CLASS_MEMORY  = 2'h1,
    VSP_ACTION_CLASS_CONTROL = 2'h2
  } vsp_action_class_e;

  function automatic logic vsp_action_class_defined(
      input logic [VSP_ACTION_CLASS_W-1:0] action_class);
    case (action_class)
      VSP_ACTION_CLASS_EXEC,
      VSP_ACTION_CLASS_MEMORY,
      VSP_ACTION_CLASS_CONTROL: vsp_action_class_defined = 1'b1;
      default: vsp_action_class_defined = 1'b0;
    endcase
  endfunction

  localparam int VSP_CONTROL_OP_W = 2;

  typedef enum logic [VSP_CONTROL_OP_W-1:0] {
    // END terminates one ordered action stream after internal engines have
    // reached the controller-provided quiescent condition.
    VSP_CONTROL_OP_END = 2'h0
  } vsp_control_op_e;

  function automatic logic vsp_control_op_defined(
      input logic [VSP_CONTROL_OP_W-1:0] control_op);
    vsp_control_op_defined = control_op == VSP_CONTROL_OP_END;
  endfunction

  // Internal action-completion semantics.  These values are neither an ISA
  // trap encoding nor a host software ABI.
  localparam int VSP_ACTION_CPL_STATUS_W = 3;

  typedef enum logic [VSP_ACTION_CPL_STATUS_W-1:0] {
    VSP_ACTION_CPL_OK             = 3'h0,
    VSP_ACTION_CPL_DECODE_ERROR   = 3'h1,
    VSP_ACTION_CPL_OWNER_MISMATCH = 3'h2,
    VSP_ACTION_CPL_EXEC_ERROR     = 3'h3,
    VSP_ACTION_CPL_MEMORY_ERROR   = 3'h4,
    VSP_ACTION_CPL_CONTROL_ERROR  = 3'h5,
    VSP_ACTION_CPL_PROTOCOL_ERROR = 3'h6
  } vsp_action_cpl_status_e;

endpackage
