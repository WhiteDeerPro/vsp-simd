module vsp_uword_action_adapter #(
  parameter int PC_W = 32,
  parameter int GROUP_COUNT = 4,
  parameter int CONTEXT_COUNT = 2,
  parameter int TAG_W = 8,
  parameter int MEM_EADDR_W = 32,
  parameter int STATE_REGS = 32,
  parameter int VREGS = 16,
  parameter int MAX_SPAN_BYTES =
      ((GROUP_COUNT*4) < vsp_uword_pkg::VSP_MEMORY_UWORD_MAX_SPAN_BYTES) ?
          (GROUP_COUNT*4) :
          vsp_uword_pkg::VSP_MEMORY_UWORD_MAX_SPAN_BYTES,
  parameter int DECODE_ERROR_W =
      vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W,
  parameter int STATE_REG_INDEX_W = (STATE_REGS <= 2) ? 1 :
                                    $clog2(STATE_REGS),
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

  // CONTROL-state actions remain in the ordered record stream but are
  // executed by the sequencer-local state engine rather than by the cluster
  // controller.  A legal state action uses an otherwise undefined CONTROL op
  // value so an integration mistake cannot silently turn it into END.
  output logic                                      action_is_state_o,
  output logic [vsp_sequencer_state_pkg::VSP_STATE_OP_W-1:0]
                                                     action_state_op_o,
  output logic [STATE_REG_INDEX_W-1:0]              action_state_rd_o,
  output logic [STATE_REG_INDEX_W-1:0]              action_state_rs1_o,
  output logic [STATE_REG_INDEX_W-1:0]              action_state_rs2_o,
  output logic [31:0]                               action_state_imm_o,

  // Branches are CONTROL actions executed by the single-PC sequencing
  // wrapper.  Like state actions, they remain visible at this ordered action
  // boundary and must not be forwarded to the generic cluster controller.
  output logic                                      action_is_branch_o,
  output logic [vsp_sequencer_state_pkg::VSP_BRANCH_COND_W-1:0]
                                                     action_branch_cond_o,
  output logic [STATE_REG_INDEX_W-1:0]              action_branch_rs1_o,
  output logic [STATE_REG_INDEX_W-1:0]              action_branch_rs2_o,
  output logic signed [31:0]                        action_branch_offset_o,

  // The MEMORY decoder queries sequencer state combinationally.  Its resolved
  // base and all other descriptor fields must be sampled on action admission;
  // no downstream engine may live-read the state RF.
  output logic                                      memory_base_read_valid_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_STATE_REG_W-1:0]
                                                     memory_base_read_reg_o,
  input  logic [MEM_EADDR_W-1:0]                    memory_base_read_data_i,
  input  logic                                      memory_base_read_legal_i,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]         action_memory_op_o,
  output logic [vsp_pkg::VSP_MEM_ADDR_MODE_W-1:0]
                                                     action_memory_addr_mode_o,
  output logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
                                                     action_memory_addr_space_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_ADDR_CONTEXT_W-1:0]
                                                     action_memory_addr_context_o,
  output logic [MEM_EADDR_W-1:0]                    action_memory_base_eaddr_o,
  output logic signed [vsp_uword_pkg::VSP_MEMORY_UWORD_OFFSET_W-1:0]
                                                     action_memory_eaddr_offset_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_VRF_ROW_W-1:0]
                                                     action_memory_vrf_row_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_VRF_ROW_W-1:0]
                                                     action_memory_index_vrf_row_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0]
                                                     action_memory_span_bytes_o,

  // Trace-only metadata remains aligned with action_valid_o and is useful for
  // associating an ordered rejection with its source byte PC.
  output logic [PC_W-1:0]                           action_start_pc_o,
  output logic                                      action_is_control_end_o
);
  import vsp_action_pkg::*;
  import vsp_exec_uword_pkg::*;
  import vsp_pkg::*;
  import vsp_uword_pkg::*;

  logic [CONTEXT_W-1:0] context_q;
  logic [GROUP_COUNT-1:0] group_mask_q;
  logic [TAG_W-1:0] tag_q;

  logic [VSP_UWORD_W-1:0] header;
  logic expected_exec_extension;
  logic exec_shape_ok;
  logic complete_shape;
  logic action_fire;

  logic control_out_valid;
  logic control_is_end;
  logic control_is_state;
  logic control_legal;
  logic [VSP_EXEC_UWORD_ERROR_W-1:0] control_error;
  logic [vsp_sequencer_state_pkg::VSP_STATE_OP_W-1:0]
      control_state_op;
  logic [STATE_REG_INDEX_W-1:0] control_state_rd;
  logic [STATE_REG_INDEX_W-1:0] control_state_rs1;
  logic [STATE_REG_INDEX_W-1:0] control_state_rs2;
  logic [31:0] control_state_imm;
  logic control_is_branch;
  logic [vsp_sequencer_state_pkg::VSP_BRANCH_COND_W-1:0]
      control_branch_cond;
  logic [STATE_REG_INDEX_W-1:0] control_branch_rs1;
  logic [STATE_REG_INDEX_W-1:0] control_branch_rs2;
  logic signed [31:0] control_branch_offset;

  logic memory_out_valid;
  logic memory_legal;
  logic [VSP_EXEC_UWORD_ERROR_W-1:0] memory_error;
  logic [vsp_pkg::VSP_MEM_OP_W-1:0] memory_op;
  logic [vsp_pkg::VSP_MEM_ADDR_MODE_W-1:0] memory_addr_mode;
  logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] memory_addr_space;
  logic [VSP_MEMORY_UWORD_ADDR_CONTEXT_W-1:0] memory_addr_context;
  logic [MEM_EADDR_W-1:0] memory_base_eaddr;
  logic signed [VSP_MEMORY_UWORD_OFFSET_W-1:0] memory_eaddr_offset;
  logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0] memory_vrf_row;
  logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0] memory_index_vrf_row;
  logic [VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0] memory_span_bytes;
  logic [VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0]
      full_selected_span_bytes;

  // UNIT_STRIDE code zero is the only MEMORY field whose meaning depends on
  // the launch envelope.  Resolve it here, after group_mask_q has captured
  // that envelope, so every downstream command carries an ordinary byte
  // count.  INDEX_U8 also decodes span zero but must keep it unchanged.
  always_comb begin : resolve_full_selected_span
    int unsigned selected_groups;
    selected_groups = 0;
    for (int group = 0; group < GROUP_COUNT; group++) begin
      if (group_mask_q[group]) selected_groups++;
    end
    full_selected_span_bytes = VSP_MEMORY_UWORD_SPAN_BYTES_W'(
        selected_groups * VSP_MEMORY_UWORD_GROUP_BYTES);
  end

  assign header = record_words_i[0 +: VSP_UWORD_W];
  assign expected_exec_extension =
      vsp_exec_uword_extension_required(header);
  assign complete_shape = !record_truncated_i &&
      (record_present_word_count_i == record_word_count_i);
  assign exec_shape_ok = complete_shape &&
      (record_word_count_i ==
       (expected_exec_extension ? VSP_UWORD_WORD_COUNT_W'(2) :
                                  VSP_UWORD_WORD_COUNT_W'(1)));
  vsp_control_uword_decoder #(
    .STATE_REGS(STATE_REGS),
    .STATE_REG_INDEX_W(STATE_REG_INDEX_W)
  ) u_control_decoder (
    .record_valid_i(record_valid_i &&
                    record_class_i == VSP_ACTION_CLASS_CONTROL),
    .record_word_count_i,
    .record_present_word_count_i,
    .record_words_i,
    .record_truncated_i,
    .out_valid_o(control_out_valid),
    .is_control_end_o(control_is_end),
    .is_state_o(control_is_state),
    .legal_o(control_legal),
    .error_cause_o(control_error),
    .state_op_o(control_state_op),
    .state_rd_o(control_state_rd),
    .state_rs1_o(control_state_rs1),
    .state_rs2_o(control_state_rs2),
    .state_imm_o(control_state_imm),
    .is_branch_o(control_is_branch),
    .branch_cond_o(control_branch_cond),
    .branch_rs1_o(control_branch_rs1),
    .branch_rs2_o(control_branch_rs2),
    .branch_offset_o(control_branch_offset)
  );

  vsp_memory_uword_decoder #(
    .MEM_EADDR_W(MEM_EADDR_W),
    .STATE_REGS(STATE_REGS),
    .VREGS(VREGS),
    .MAX_SPAN_BYTES(MAX_SPAN_BYTES)
  ) u_memory_decoder (
    .record_valid_i(record_valid_i &&
                    record_class_i == VSP_ACTION_CLASS_MEMORY),
    .record_word_count_i,
    .record_present_word_count_i,
    .record_words_i,
    .record_truncated_i,
    .base_read_valid_o(memory_base_read_valid_o),
    .base_read_reg_o(memory_base_read_reg_o),
    .base_read_data_i(memory_base_read_data_i),
    .base_read_legal_i(memory_base_read_legal_i),
    .out_valid_o(memory_out_valid),
    .legal_o(memory_legal),
    .error_cause_o(memory_error),
    .op_o(memory_op),
    .addr_mode_o(memory_addr_mode),
    .addr_space_o(memory_addr_space),
    .addr_context_o(memory_addr_context),
    .base_eaddr_o(memory_base_eaddr),
    .eaddr_offset_o(memory_eaddr_offset),
    .vrf_row_o(memory_vrf_row),
    .index_vrf_row_o(memory_index_vrf_row),
    .span_bytes_o(memory_span_bytes)
  );

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
    action_is_state_o = 1'b0;
    action_state_op_o = '0;
    action_state_rd_o = '0;
    action_state_rs1_o = '0;
    action_state_rs2_o = '0;
    action_state_imm_o = '0;
    action_is_branch_o = 1'b0;
    action_branch_cond_o = '0;
    action_branch_rs1_o = '0;
    action_branch_rs2_o = '0;
    action_branch_offset_o = '0;
    action_memory_op_o = '0;
    action_memory_addr_mode_o = VSP_MEM_ADDR_MODE_UNIT_STRIDE;
    action_memory_addr_space_o = '0;
    action_memory_addr_context_o = '0;
    action_memory_base_eaddr_o = '0;
    action_memory_eaddr_offset_o = '0;
    action_memory_vrf_row_o = '0;
    action_memory_index_vrf_row_o = '0;
    action_memory_span_bytes_o = '0;
    action_start_pc_o = record_start_pc_i;
    action_is_control_end_o = control_is_end;

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
          action_legal_o = memory_legal;
          action_decode_error_o = DECODE_ERROR_W'(memory_error);
          action_memory_op_o = memory_op;
          action_memory_addr_mode_o = memory_addr_mode;
          action_memory_addr_space_o = memory_addr_space;
          action_memory_addr_context_o = memory_addr_context;
          action_memory_base_eaddr_o = memory_base_eaddr;
          action_memory_eaddr_offset_o = memory_eaddr_offset;
          action_memory_vrf_row_o = memory_vrf_row;
          action_memory_index_vrf_row_o = memory_index_vrf_row;
          if ((memory_addr_mode == VSP_MEM_ADDR_MODE_UNIT_STRIDE) &&
              (memory_span_bytes == '0)) begin
            action_memory_span_bytes_o = full_selected_span_bytes;
          end else begin
            action_memory_span_bytes_o = memory_span_bytes;
          end
        end

        VSP_ACTION_CLASS_CONTROL: begin
          action_group_mask_o = '0;
          action_is_state_o = control_is_state;
          action_state_op_o = control_state_op;
          action_state_rd_o = control_state_rd;
          action_state_rs1_o = control_state_rs1;
          action_state_rs2_o = control_state_rs2;
          action_state_imm_o = control_state_imm;
          action_is_branch_o = control_is_branch;
          action_branch_cond_o = control_branch_cond;
          action_branch_rs1_o = control_branch_rs1;
          action_branch_rs2_o = control_branch_rs2;
          action_branch_offset_o = control_branch_offset;
          if (control_is_end && record_control_end_allowed_i) begin
            action_legal_o = 1'b1;
            action_decode_error_o =
                DECODE_ERROR_W'(VSP_EXEC_UWORD_ERROR_NONE);
          end else if (control_is_state) begin
            // 2'h1 is intentionally undefined by vsp_action_pkg.  Legal state
            // records are intercepted by the sequencer wrapper; accidentally
            // forwarding one to the generic controller yields CONTROL_ERROR
            // instead of terminating the program.
            action_control_op_o = VSP_CONTROL_OP_W'(1);
            action_legal_o = control_legal;
            action_decode_error_o = DECODE_ERROR_W'(control_error);
          end else if (control_is_branch) begin
            // 2'h2 is intentionally undefined by vsp_action_pkg.  The
            // sequencer wrapper intercepts every recognized branch record,
            // including malformed ones that need an ordered decode error.
            action_control_op_o = VSP_CONTROL_OP_W'(2);
            action_legal_o = control_legal;
            action_decode_error_o = DECODE_ERROR_W'(control_error);
          end else begin
            action_decode_error_o = DECODE_ERROR_W'(
                control_is_end ? VSP_EXEC_UWORD_ERROR_BAD_SUBOP :
                                 control_error);
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
    if (MEM_EADDR_W < 1) $error("MEM_EADDR_W must be positive");
    if (STATE_REGS < 1 || STATE_REGS > 32)
      $error("STATE_REGS must fit the current five-bit profile");
    if (VREGS < 1 || VREGS > 16)
      $error("VREGS must fit the current four-bit profile");
    if (MAX_SPAN_BYTES < 1 ||
        MAX_SPAN_BYTES > VSP_MEMORY_UWORD_MAX_SPAN_BYTES)
      $error("MAX_SPAN_BYTES must fit the resolved 1..64-byte profile");
    if (DECODE_ERROR_W != VSP_EXEC_UWORD_ERROR_W)
      $error("adapter diagnostics require EXEC-uword error width");
  end

  /* verilator lint_off UNUSED */
  logic decoder_observability_used;
  assign decoder_observability_used = control_out_valid ^ memory_out_valid;
  /* verilator lint_on UNUSED */
endmodule
