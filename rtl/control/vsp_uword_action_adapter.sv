module vsp_uword_action_adapter #(
  parameter int PC_W = 32,
  parameter int GROUP_COUNT = 4,
  parameter int CONTEXT_COUNT = 2,
  parameter int TAG_W = 8,
  parameter int DECODE_ERROR_W =
      vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT)
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  // A launch transaction defines the common envelope for the following
  // ordered record stream.  The tag advances when a record is accepted by
  // the decoded-action boundary, not when it merely becomes visible here.
  // Integration must not accept an old action in the same cycle as launch;
  // the current program wrapper enforces that lifecycle boundary.
  input  logic                                      launch_fire_i,
  input  logic [CONTEXT_W-1:0]                      launch_context_i,
  input  logic [GROUP_COUNT-1:0]                    launch_group_mask_i,
  input  logic [TAG_W-1:0]                          launch_tag_seed_i,

  input  logic                                      record_valid_i,
  output logic                                      record_ready_o,
  input  logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     record_class_i,
  input  logic                                      record_major_defined_i,
  input  logic [PC_W-1:0]                           record_start_pc_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_word_count_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_present_word_count_i,
  input  logic [(vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]    record_words_i,
  input  logic                                      record_truncated_i,
  // END is legal only when its byte immediately follows the launch range.
  // Keeping this range rule outside the generic framer lets the framer stop
  // fetch as soon as it sees END while this adapter reports an ordered reject
  // for an early END.
  input  logic                                      record_control_end_allowed_i,

  output logic                                      action_valid_o,
  input  logic                                      action_ready_i,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     action_class_o,
  output logic                                      action_legal_o,
  output logic [DECODE_ERROR_W-1:0]                 action_decode_error_o,
  output logic [vsp_action_pkg::VSP_CONTROL_OP_W-1:0]
                                                     action_control_op_o,
  output logic [CONTEXT_W-1:0]                      action_context_o,
  output logic [TAG_W-1:0]                          action_tag_o,
  output logic [GROUP_COUNT-1:0]                    action_group_mask_o,
  output logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_W-1:0]
                                                     action_exec_base_word_o,
  output logic                                      action_exec_extension_valid_o,
  output logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_W-1:0]
                                                     action_exec_extension_word_o,

  // Trace-only metadata remains aligned with action_valid_o and is useful for
  // associating an ordered rejection with its source byte PC.
  output logic [PC_W-1:0]                           action_start_pc_o,
  output logic                                      action_is_control_end_o
);
  import vsp_action_pkg::*;
  import vsp_exec_uword_pkg::*;
  import vsp_uword_pkg::*;

  logic [CONTEXT_W-1:0] context_q;
  logic [GROUP_COUNT-1:0] group_mask_q;
  logic [TAG_W-1:0] tag_q;

  logic [VSP_UWORD_W-1:0] header;
  logic expected_exec_extension;
  logic exec_shape_ok;
  logic complete_shape;
  logic canonical_end;
  logic action_fire;

  assign header = record_words_i[0 +: VSP_UWORD_W];
  assign expected_exec_extension =
      vsp_exec_uword_extension_required(header);
  assign complete_shape = !record_truncated_i &&
      (record_present_word_count_i == record_word_count_i);
  assign exec_shape_ok = complete_shape &&
      (record_word_count_i ==
       (expected_exec_extension ? VSP_UWORD_WORD_COUNT_W'(2) :
                                  VSP_UWORD_WORD_COUNT_W'(1)));
  assign canonical_end = complete_shape &&
      (record_word_count_i == VSP_UWORD_WORD_COUNT_W'(1)) &&
      vsp_uword_is_control_end(header);

  always_comb begin
    action_valid_o = record_valid_i;
    record_ready_o = action_ready_i;
    action_class_o = record_class_i;
    action_legal_o = 1'b0;
    action_decode_error_o = DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_BAD_FORMAT);
    action_control_op_o = VSP_CONTROL_OP_END;
    action_context_o = context_q;
    action_tag_o = tag_q;
    action_group_mask_o = group_mask_q;
    action_exec_base_word_o = header;
    action_exec_extension_valid_o = 1'b0;
    action_exec_extension_word_o =
        record_words_i[VSP_UWORD_W +: VSP_UWORD_W];
    action_start_pc_o = record_start_pc_i;
    action_is_control_end_o = canonical_end;

    if (!record_major_defined_i) begin
      action_decode_error_o =
          DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_BAD_FORMAT);
    end else if (!complete_shape) begin
      action_decode_error_o =
          DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_EXTENSION);
    end else begin
      unique case (record_class_i)
        VSP_ACTION_CLASS_EXEC: begin
          action_exec_extension_valid_o = expected_exec_extension &&
              exec_shape_ok;
          if (exec_shape_ok) begin
            // Final field legality remains the responsibility of the existing
            // EXEC profile expander in vsp_cluster_controller_wrapper.
            action_legal_o = 1'b1;
            action_decode_error_o =
                DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_NONE);
          end else begin
            action_decode_error_o =
                DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_EXTENSION);
          end
        end

        VSP_ACTION_CLASS_MEMORY: begin
          // MEMORY framing is intentionally opaque in this first executable
          // closure.  It must retire as an ordered decode rejection rather
          // than being interpreted as a zero-filled memory descriptor.
          action_decode_error_o =
              DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_BAD_FORMAT);
        end

        VSP_ACTION_CLASS_CONTROL: begin
          action_group_mask_o = '0;
          if (canonical_end && record_control_end_allowed_i) begin
            action_legal_o = 1'b1;
            action_decode_error_o =
                DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_NONE);
          end else begin
            // Profile v0 defines no other CONTROL operation.  In particular,
            // C0000001 and a CONTROL record carrying body words are not END.
            action_decode_error_o =
                DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_BAD_SUBOP);
          end
        end

        default: begin
          action_decode_error_o =
              DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_BAD_FORMAT);
        end
      endcase
    end
  end

  assign action_fire = action_valid_o && action_ready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      context_q <= '0;
      group_mask_q <= '0;
      tag_q <= '0;
    end else begin
      if (launch_fire_i) begin
        context_q <= launch_context_i;
        group_mask_q <= launch_group_mask_i;
        tag_q <= launch_tag_seed_i;
      end else if (action_fire) begin
        tag_q <= tag_q + TAG_W'(1);
      end
    end
  end

  initial begin
    if (PC_W < 3) $error("PC_W must hold a byte-aligned word address");
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (TAG_W < 1) $error("TAG_W must be positive");
    if (DECODE_ERROR_W != VSP_EXEC_UWORD_ERROR_W)
      $error("adapter diagnostics require EXEC-uword error width");
  end
endmodule
