module vsp_decoded_action_controller #(
  parameter int GROUP_COUNT          = 4,
  parameter int CONTEXT_COUNT        = 2,
  parameter int TAG_W                = 8,
  parameter int DECODE_ERROR_W       = 4,
  parameter int EXEC_PAYLOAD_W       = 1,
  parameter int MEMORY_PAYLOAD_W     = 1,
  parameter int EXEC_CPL_PAYLOAD_W   = 1,
  parameter int MEMORY_CPL_PAYLOAD_W = 1,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One already-decoded action.  Class-specific payloads remain opaque to
  // this controller so instruction layout and engine request layout can
  // evolve independently of the ordering state machine.
  input  logic                                      action_valid_i,
  output logic                                      action_ready_o,
  input  logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     action_class_i,
  input  logic                                      action_legal_i,
  input  logic [DECODE_ERROR_W-1:0]                 action_decode_error_i,
  input  logic [vsp_action_pkg::VSP_CONTROL_OP_W-1:0]
                                                     action_control_op_i,
  input  logic [CONTEXT_W-1:0]                      action_context_i,
  input  logic [TAG_W-1:0]                          action_tag_i,
  input  logic [GROUP_COUNT-1:0]                    action_group_mask_i,
  input  logic [EXEC_PAYLOAD_W-1:0]                 action_exec_payload_i,
  input  logic [MEMORY_PAYLOAD_W-1:0]               action_memory_payload_i,

  // The first controller profile applies the same ownership check to EXEC
  // and MEMORY.  This closes the gap where a memory parent could otherwise
  // write a group owned by a different execution context.
  input  logic [GROUP_COUNT-1:0]                    group_owner_valid_i,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]        group_owner_i,

  // END is accepted into the ordered stream, then waits here until every
  // internal engine and result obligation is safely drained.  External
  // completion/result consumers need not themselves be empty.
  input  logic                                      end_quiescent_i,

  output logic                                      exec_cmd_valid_o,
  input  logic                                      exec_cmd_ready_i,
  output logic [CONTEXT_W-1:0]                      exec_cmd_context_o,
  output logic [TAG_W-1:0]                          exec_cmd_tag_o,
  output logic [GROUP_COUNT-1:0]                    exec_cmd_group_mask_o,
  output logic [EXEC_PAYLOAD_W-1:0]                 exec_cmd_payload_o,

  input  logic                                      exec_cpl_valid_i,
  output logic                                      exec_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]                      exec_cpl_context_i,
  input  logic [TAG_W-1:0]                          exec_cpl_tag_i,
  input  logic                                      exec_cpl_error_i,
  input  logic [EXEC_CPL_PAYLOAD_W-1:0]             exec_cpl_payload_i,

  output logic                                      memory_cmd_valid_o,
  input  logic                                      memory_cmd_ready_i,
  output logic [CONTEXT_W-1:0]                      memory_cmd_context_o,
  output logic [TAG_W-1:0]                          memory_cmd_tag_o,
  output logic [GROUP_COUNT-1:0]                    memory_cmd_group_mask_o,
  output logic [MEMORY_PAYLOAD_W-1:0]               memory_cmd_payload_o,

  input  logic                                      memory_cpl_valid_i,
  output logic                                      memory_cpl_ready_o,
  input  logic [CONTEXT_W-1:0]                      memory_cpl_context_i,
  input  logic [TAG_W-1:0]                          memory_cpl_tag_i,
  input  logic                                      memory_cpl_error_i,
  input  logic [MEMORY_CPL_PAYLOAD_W-1:0]           memory_cpl_payload_i,

  // Unified, ordered command completion.  group_mask preserves the original
  // request envelope even for a controller-local rejection.  Class-specific
  // payloads describe child-engine completions; both are zero for a local
  // decode/control/owner error, and the unselected payload is always zero.
  output logic                                      action_cpl_valid_o,
  input  logic                                      action_cpl_ready_i,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     action_cpl_class_o,
  output logic [CONTEXT_W-1:0]                      action_cpl_context_o,
  output logic [TAG_W-1:0]                          action_cpl_tag_o,
  output logic [GROUP_COUNT-1:0]                    action_cpl_group_mask_o,
  output logic [vsp_action_pkg::VSP_ACTION_CPL_STATUS_W-1:0]
                                                     action_cpl_status_o,
  output logic [DECODE_ERROR_W-1:0]                 action_cpl_decode_error_o,
  output logic [EXEC_CPL_PAYLOAD_W-1:0]             action_cpl_exec_payload_o,
  output logic [MEMORY_CPL_PAYLOAD_W-1:0]           action_cpl_memory_payload_o,
  output logic                                      action_cpl_end_o,

  // A pulse on the successful END completion handshake.  Holding an END
  // completion under backpressure never repeats this pulse.  Earlier action
  // failures are not accumulated here; the sequencer owns abort policy.
  output logic                                      program_done_o,
  output logic                                      busy_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      protocol_error_o
);
  import vsp_action_pkg::*;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_WAIT_EXEC,
    STATE_WAIT_MEMORY,
    STATE_WAIT_END
  } controller_state_e;

  controller_state_e state_q;
  logic [CONTEXT_W-1:0] active_context_q;
  logic [TAG_W-1:0] active_tag_q;
  logic [GROUP_COUNT-1:0] active_group_mask_q;

  logic cpl_valid_q;
  logic [VSP_ACTION_CLASS_W-1:0] cpl_class_q;
  logic [CONTEXT_W-1:0] cpl_context_q;
  logic [TAG_W-1:0] cpl_tag_q;
  logic [GROUP_COUNT-1:0] cpl_group_mask_q;
  logic [VSP_ACTION_CPL_STATUS_W-1:0] cpl_status_q;
  logic [DECODE_ERROR_W-1:0] cpl_decode_error_q;
  logic [EXEC_CPL_PAYLOAD_W-1:0] cpl_exec_payload_q;
  logic [MEMORY_CPL_PAYLOAD_W-1:0] cpl_memory_payload_q;
  logic cpl_end_q;

  logic context_valid;
  logic owner_match;
  logic action_local_error;
  logic [VSP_ACTION_CPL_STATUS_W-1:0] action_local_status;
  logic action_fire;
  logic exec_cmd_fire;
  logic memory_cmd_fire;
  logic exec_cpl_fire;
  logic memory_cpl_fire;
  logic action_cpl_fire;
  logic unexpected_exec_cpl;
  logic unexpected_memory_cpl;
  logic exec_cpl_expected;
  logic memory_cpl_expected;
  logic exec_identity_mismatch;
  logic memory_identity_mismatch;

  always_comb begin
    context_valid = int'(action_context_i) < CONTEXT_COUNT;
    owner_match = context_valid;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (action_group_mask_i[group] &&
          (!group_owner_valid_i[group] ||
           group_owner_i[(group*CONTEXT_W) +: CONTEXT_W] !=
               action_context_i)) begin
        owner_match = 1'b0;
      end
    end

    action_local_error = 1'b0;
    action_local_status = VSP_ACTION_CPL_OK;
    if (!action_legal_i || !context_valid ||
        !vsp_action_class_defined(action_class_i)) begin
      action_local_error = 1'b1;
      action_local_status = VSP_ACTION_CPL_DECODE_ERROR;
    end else if (action_class_i == VSP_ACTION_CLASS_CONTROL &&
                 (!vsp_control_op_defined(action_control_op_i) ||
                  (|action_group_mask_i))) begin
      action_local_error = 1'b1;
      action_local_status = VSP_ACTION_CPL_CONTROL_ERROR;
    end else if ((action_class_i == VSP_ACTION_CLASS_EXEC ||
                  action_class_i == VSP_ACTION_CLASS_MEMORY) &&
                 !owner_match) begin
      action_local_error = 1'b1;
      action_local_status = VSP_ACTION_CPL_OWNER_MISMATCH;
    end
  end

  always_comb begin
    action_ready_o = 1'b0;
    exec_cmd_valid_o = 1'b0;
    exec_cmd_context_o = action_context_i;
    exec_cmd_tag_o = action_tag_i;
    exec_cmd_group_mask_o = action_group_mask_i;
    exec_cmd_payload_o = action_exec_payload_i;
    memory_cmd_valid_o = 1'b0;
    memory_cmd_context_o = action_context_i;
    memory_cmd_tag_o = action_tag_i;
    memory_cmd_group_mask_o = action_group_mask_i;
    memory_cmd_payload_o = action_memory_payload_i;

    if (rst_ni && state_q == STATE_IDLE && !cpl_valid_q) begin
      if (action_local_error ||
          action_class_i == VSP_ACTION_CLASS_CONTROL) begin
        action_ready_o = 1'b1;
      end else if (action_class_i == VSP_ACTION_CLASS_EXEC) begin
        exec_cmd_valid_o = action_valid_i;
        action_ready_o = exec_cmd_ready_i;
      end else if (action_class_i == VSP_ACTION_CLASS_MEMORY) begin
        memory_cmd_valid_o = action_valid_i;
        action_ready_o = memory_cmd_ready_i;
      end
    end
  end

  assign action_fire = action_valid_i && action_ready_o;
  assign exec_cmd_fire = exec_cmd_valid_o && exec_cmd_ready_i;
  assign memory_cmd_fire = memory_cmd_valid_o && memory_cmd_ready_i;

  // Completion storage is reserved by the single-active rule, so child
  // completions are always drainable.  Unexpected records are consumed and
  // diagnosed instead of wedging an engine indefinitely.
  assign exec_cpl_ready_o = rst_ni;
  assign memory_cpl_ready_o = rst_ni;
  assign exec_cpl_fire = exec_cpl_valid_i && exec_cpl_ready_o;
  assign memory_cpl_fire = memory_cpl_valid_i && memory_cpl_ready_o;
  // A child may complete in the command-accept cycle or later.  The engines
  // used by the current integration are registered, but accepting a legal
  // zero-latency endpoint here keeps this generic ordering block independent
  // of that implementation choice.
  assign exec_cpl_expected = state_q == STATE_WAIT_EXEC ||
      (state_q == STATE_IDLE && exec_cmd_fire);
  assign memory_cpl_expected = state_q == STATE_WAIT_MEMORY ||
      (state_q == STATE_IDLE && memory_cmd_fire);
  assign unexpected_exec_cpl = exec_cpl_fire && !exec_cpl_expected;
  assign unexpected_memory_cpl = memory_cpl_fire && !memory_cpl_expected;
  assign exec_identity_mismatch = exec_cpl_fire && exec_cpl_expected &&
      (exec_cpl_context_i != (state_q == STATE_WAIT_EXEC ?
                              active_context_q : action_context_i) ||
       exec_cpl_tag_i != (state_q == STATE_WAIT_EXEC ?
                          active_tag_q : action_tag_i));
  assign memory_identity_mismatch = memory_cpl_fire &&
      memory_cpl_expected &&
      (memory_cpl_context_i != (state_q == STATE_WAIT_MEMORY ?
                                active_context_q : action_context_i) ||
       memory_cpl_tag_i != (state_q == STATE_WAIT_MEMORY ?
                            active_tag_q : action_tag_i));

  assign action_cpl_valid_o = cpl_valid_q;
  assign action_cpl_class_o = cpl_class_q;
  assign action_cpl_context_o = cpl_context_q;
  assign action_cpl_tag_o = cpl_tag_q;
  assign action_cpl_group_mask_o = cpl_group_mask_q;
  assign action_cpl_status_o = cpl_status_q;
  assign action_cpl_decode_error_o = cpl_decode_error_q;
  assign action_cpl_exec_payload_o = cpl_exec_payload_q;
  assign action_cpl_memory_payload_o = cpl_memory_payload_q;
  assign action_cpl_end_o = cpl_end_q;
  assign action_cpl_fire = cpl_valid_q && action_cpl_ready_i;
  assign program_done_o = action_cpl_fire && cpl_end_q &&
                          cpl_status_q == VSP_ACTION_CPL_OK;
  assign busy_o = state_q != STATE_IDLE || cpl_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= STATE_IDLE;
      active_context_q <= '0;
      active_tag_q <= '0;
      active_group_mask_q <= '0;
      cpl_valid_q <= 1'b0;
      cpl_class_q <= '0;
      cpl_context_q <= '0;
      cpl_tag_q <= '0;
      cpl_group_mask_q <= '0;
      cpl_status_q <= VSP_ACTION_CPL_OK;
      cpl_decode_error_q <= '0;
      cpl_exec_payload_q <= '0;
      cpl_memory_payload_q <= '0;
      cpl_end_q <= 1'b0;
      protocol_error_o <= 1'b0;
    end else begin
      if (protocol_error_clear_i) protocol_error_o <= 1'b0;
      if (unexpected_exec_cpl || unexpected_memory_cpl ||
          exec_identity_mismatch || memory_identity_mismatch) begin
        protocol_error_o <= 1'b1;
      end

      if (action_cpl_fire) begin
        cpl_valid_q <= 1'b0;
        cpl_class_q <= '0;
        cpl_context_q <= '0;
        cpl_tag_q <= '0;
        cpl_group_mask_q <= '0;
        cpl_status_q <= VSP_ACTION_CPL_OK;
        cpl_decode_error_q <= '0;
        cpl_exec_payload_q <= '0;
        cpl_memory_payload_q <= '0;
        cpl_end_q <= 1'b0;
      end

      unique case (state_q)
        STATE_IDLE: begin
          if (action_fire) begin
            active_context_q <= action_context_i;
            active_tag_q <= action_tag_i;
            active_group_mask_q <= action_group_mask_i;
            if (action_local_error) begin
              cpl_valid_q <= 1'b1;
              cpl_class_q <= action_class_i;
              cpl_context_q <= action_context_i;
              cpl_tag_q <= action_tag_i;
              cpl_group_mask_q <= action_group_mask_i;
              cpl_status_q <= action_local_status;
              cpl_decode_error_q <=
                  action_local_status == VSP_ACTION_CPL_DECODE_ERROR ?
                  action_decode_error_i : '0;
              cpl_exec_payload_q <= '0;
              cpl_memory_payload_q <= '0;
              cpl_end_q <= 1'b0;
            end else if (action_class_i == VSP_ACTION_CLASS_EXEC &&
                         exec_cmd_fire) begin
              if (exec_cpl_fire) begin
                cpl_valid_q <= 1'b1;
                cpl_class_q <= VSP_ACTION_CLASS_EXEC;
                cpl_context_q <= action_context_i;
                cpl_tag_q <= action_tag_i;
                cpl_group_mask_q <= action_group_mask_i;
                cpl_status_q <= exec_identity_mismatch ?
                    VSP_ACTION_CPL_PROTOCOL_ERROR :
                    (exec_cpl_error_i ? VSP_ACTION_CPL_EXEC_ERROR :
                                        VSP_ACTION_CPL_OK);
                cpl_decode_error_q <= '0;
                cpl_exec_payload_q <= exec_cpl_payload_i;
                cpl_memory_payload_q <= '0;
                cpl_end_q <= 1'b0;
              end else begin
                state_q <= STATE_WAIT_EXEC;
              end
            end else if (action_class_i == VSP_ACTION_CLASS_MEMORY &&
                         memory_cmd_fire) begin
              if (memory_cpl_fire) begin
                cpl_valid_q <= 1'b1;
                cpl_class_q <= VSP_ACTION_CLASS_MEMORY;
                cpl_context_q <= action_context_i;
                cpl_tag_q <= action_tag_i;
                cpl_group_mask_q <= action_group_mask_i;
                cpl_status_q <= memory_identity_mismatch ?
                    VSP_ACTION_CPL_PROTOCOL_ERROR :
                    (memory_cpl_error_i ? VSP_ACTION_CPL_MEMORY_ERROR :
                                          VSP_ACTION_CPL_OK);
                cpl_decode_error_q <= '0;
                cpl_exec_payload_q <= '0;
                cpl_memory_payload_q <= memory_cpl_payload_i;
                cpl_end_q <= 1'b0;
              end else begin
                state_q <= STATE_WAIT_MEMORY;
              end
            end else if (action_class_i == VSP_ACTION_CLASS_CONTROL) begin
              state_q <= STATE_WAIT_END;
            end
          end
        end

        STATE_WAIT_EXEC: begin
          if (exec_cpl_fire) begin
            state_q <= STATE_IDLE;
            cpl_valid_q <= 1'b1;
            cpl_class_q <= VSP_ACTION_CLASS_EXEC;
            cpl_context_q <= active_context_q;
            cpl_tag_q <= active_tag_q;
            cpl_group_mask_q <= active_group_mask_q;
            cpl_status_q <= exec_identity_mismatch ?
                VSP_ACTION_CPL_PROTOCOL_ERROR :
                (exec_cpl_error_i ? VSP_ACTION_CPL_EXEC_ERROR :
                                    VSP_ACTION_CPL_OK);
            cpl_decode_error_q <= '0;
            cpl_exec_payload_q <= exec_cpl_payload_i;
            cpl_memory_payload_q <= '0;
            cpl_end_q <= 1'b0;
          end
        end

        STATE_WAIT_MEMORY: begin
          if (memory_cpl_fire) begin
            state_q <= STATE_IDLE;
            cpl_valid_q <= 1'b1;
            cpl_class_q <= VSP_ACTION_CLASS_MEMORY;
            cpl_context_q <= active_context_q;
            cpl_tag_q <= active_tag_q;
            cpl_group_mask_q <= active_group_mask_q;
            cpl_status_q <= memory_identity_mismatch ?
                VSP_ACTION_CPL_PROTOCOL_ERROR :
                (memory_cpl_error_i ? VSP_ACTION_CPL_MEMORY_ERROR :
                                      VSP_ACTION_CPL_OK);
            cpl_decode_error_q <= '0;
            cpl_exec_payload_q <= '0;
            cpl_memory_payload_q <= memory_cpl_payload_i;
            cpl_end_q <= 1'b0;
          end
        end

        STATE_WAIT_END: begin
          if (end_quiescent_i) begin
            state_q <= STATE_IDLE;
            cpl_valid_q <= 1'b1;
            cpl_class_q <= VSP_ACTION_CLASS_CONTROL;
            cpl_context_q <= active_context_q;
            cpl_tag_q <= active_tag_q;
            cpl_group_mask_q <= active_group_mask_q;
            cpl_status_q <= VSP_ACTION_CPL_OK;
            cpl_decode_error_q <= '0;
            cpl_exec_payload_q <= '0;
            cpl_memory_payload_q <= '0;
            cpl_end_q <= 1'b1;
          end
        end

        default: begin
          state_q <= STATE_IDLE;
          protocol_error_o <= 1'b1;
        end
      endcase
    end
  end

  initial begin
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (TAG_W < 1 || DECODE_ERROR_W < 1 || EXEC_PAYLOAD_W < 1 ||
        MEMORY_PAYLOAD_W < 1 || EXEC_CPL_PAYLOAD_W < 1 ||
        MEMORY_CPL_PAYLOAD_W < 1) begin
      $error("action controller field widths must be positive");
    end
    if (CONTEXT_W != ((CONTEXT_COUNT <= 2) ? 1 :
                      $clog2(CONTEXT_COUNT))) begin
      $error("CONTEXT_W must match CONTEXT_COUNT");
    end
  end
endmodule
