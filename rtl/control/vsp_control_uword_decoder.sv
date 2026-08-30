module vsp_control_uword_decoder #(
  // The current CONTROL-state profile encodes five-bit register numbers.
  // STATE_REGS may be smaller, in which case the full encoded number is
  // checked before it is narrowed onto the decoded engine interface.
  parameter int STATE_REGS = 32,
  parameter int STATE_REG_INDEX_W = (STATE_REGS <= 2) ? 1 :
                                    $clog2(STATE_REGS)
) (
  input  logic                                      record_valid_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_word_count_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_present_word_count_i,
  input  logic [(vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]    record_words_i,
  input  logic                                      record_truncated_i,

  // out_valid follows the collected record.  is_state/is_branch remain
  // asserted for a recognized family with a malformed shape so the caller
  // can retain its CONTROL identity while retiring the reported decode error.
  // Canonical END has priority over the numerically overlapping SMOVI sub-op.
  output logic                                      out_valid_o,
  output logic                                      is_control_end_o,
  output logic                                      is_state_o,
  output logic                                      legal_o,
  output logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W-1:0]
                                                     error_cause_o,

  // Canonical state-engine controls are nonzero only for a legal state record.
  output logic [vsp_sequencer_state_pkg::VSP_STATE_OP_W-1:0]
                                                     state_op_o,
  output logic [STATE_REG_INDEX_W-1:0]              state_rd_o,
  output logic [STATE_REG_INDEX_W-1:0]              state_rs1_o,
  output logic [STATE_REG_INDEX_W-1:0]              state_rs2_o,
  output logic [31:0]                               state_imm_o,

  // Branch family controls are nonzero only for a legal branch record.  The
  // signed byte offset is relative to the branch header PC; target-range and
  // address-overflow checks belong to the PC redirect owner.
  output logic                                      is_branch_o,
  output logic [vsp_sequencer_state_pkg::VSP_BRANCH_COND_W-1:0]
                                                     branch_cond_o,
  output logic [STATE_REG_INDEX_W-1:0]              branch_rs1_o,
  output logic [STATE_REG_INDEX_W-1:0]              branch_rs2_o,
  output logic signed [31:0]                        branch_offset_o
);
  import vsp_exec_uword_pkg::*;
  import vsp_sequencer_state_pkg::*;
  import vsp_uword_pkg::*;

  // CONTROL state header, profile v0:
  //   [31:28] major C, [27:26] body count, [25:24] state operation,
  //   [23:19] rd, [18:14] rs1, [13:9] rs2, [8:0] reserved zero.
  // SMOVI/SADDI own one immediate body word; SADD is a one-word record.
  // State operation code 2'b11 introduces a distinct, fixed two-word branch
  // family:
  //   [23:21] condition J/BEQ/BNE/BLT/BGE/BLTU/BGEU,
  //   [20:16] rs1, [15:11] rs2, [10:0] reserved zero;
  //   body word = signed PC-relative byte offset.
  localparam int CONTROL_BODY_COUNT_MSB = 27;
  localparam int CONTROL_BODY_COUNT_LSB = 26;
  localparam int CONTROL_STATE_OP_MSB = 25;
  localparam int CONTROL_STATE_OP_LSB = 24;
  localparam int CONTROL_STATE_RD_MSB = 23;
  localparam int CONTROL_STATE_RD_LSB = 19;
  localparam int CONTROL_STATE_RS1_MSB = 18;
  localparam int CONTROL_STATE_RS1_LSB = 14;
  localparam int CONTROL_STATE_RS2_MSB = 13;
  localparam int CONTROL_STATE_RS2_LSB = 9;
  localparam int CONTROL_STATE_RESERVED_MSB = 8;
  localparam int CONTROL_STATE_RESERVED_LSB = 0;
  localparam int CONTROL_ENCODED_REG_W = 5;
  localparam logic [VSP_STATE_OP_W-1:0] CONTROL_BRANCH_FAMILY = 2'b11;
  localparam int CONTROL_BRANCH_COND_MSB = 23;
  localparam int CONTROL_BRANCH_COND_LSB = 21;
  localparam int CONTROL_BRANCH_RS1_MSB = 20;
  localparam int CONTROL_BRANCH_RS1_LSB = 16;
  localparam int CONTROL_BRANCH_RS2_MSB = 15;
  localparam int CONTROL_BRANCH_RS2_LSB = 11;
  localparam int CONTROL_BRANCH_RESERVED_MSB = 10;
  localparam int CONTROL_BRANCH_RESERVED_LSB = 0;

  logic [VSP_UWORD_W-1:0] header;
  logic [VSP_UWORD_W-1:0] body_word;
  logic [VSP_UWORD_MAJOR_W-1:0] major;
  logic [1:0] body_count;
  logic [VSP_STATE_OP_W-1:0] raw_state_op;
  logic [CONTROL_ENCODED_REG_W-1:0] raw_rd;
  logic [CONTROL_ENCODED_REG_W-1:0] raw_rs1;
  logic [CONTROL_ENCODED_REG_W-1:0] raw_rs2;
  logic [VSP_BRANCH_COND_W-1:0] raw_branch_cond;
  logic [CONTROL_ENCODED_REG_W-1:0] raw_branch_rs1;
  logic [CONTROL_ENCODED_REG_W-1:0] raw_branch_rs2;
  logic complete_shape;
  logic exact_end_header;
  logic branch_family;
  logic branch_cond_defined;
  logic branch_shape_ok;
  logic branch_reserved_ok;
  logic branch_unused_ok;
  logic branch_address_ok;
  logic branch_offset_aligned;
  logic state_subop_defined;
  logic state_shape_ok;
  logic state_reserved_ok;
  logic state_unused_ok;
  logic state_address_ok;
  logic [VSP_UWORD_WORD_COUNT_W-1:0] expected_state_words;
  logic [VSP_EXEC_UWORD_ERROR_W-1:0] selected_error;

  assign header = record_words_i[0 +: VSP_UWORD_W];
  assign body_word = record_words_i[VSP_UWORD_W +: VSP_UWORD_W];
  assign major = header[VSP_UWORD_W-1 -: VSP_UWORD_MAJOR_W];
  assign body_count = header[CONTROL_BODY_COUNT_MSB:
                             CONTROL_BODY_COUNT_LSB];
  assign raw_state_op = header[CONTROL_STATE_OP_MSB:
                               CONTROL_STATE_OP_LSB];
  assign raw_rd = header[CONTROL_STATE_RD_MSB:CONTROL_STATE_RD_LSB];
  assign raw_rs1 = header[CONTROL_STATE_RS1_MSB:CONTROL_STATE_RS1_LSB];
  assign raw_rs2 = header[CONTROL_STATE_RS2_MSB:CONTROL_STATE_RS2_LSB];
  assign raw_branch_cond = header[CONTROL_BRANCH_COND_MSB:
                                  CONTROL_BRANCH_COND_LSB];
  assign raw_branch_rs1 = header[CONTROL_BRANCH_RS1_MSB:
                                 CONTROL_BRANCH_RS1_LSB];
  assign raw_branch_rs2 = header[CONTROL_BRANCH_RS2_MSB:
                                 CONTROL_BRANCH_RS2_LSB];

  assign complete_shape = !record_truncated_i &&
      (record_present_word_count_i == record_word_count_i);
  assign exact_end_header = vsp_uword_is_control_end(header);
  assign branch_family = raw_state_op == CONTROL_BRANCH_FAMILY;
  assign state_subop_defined = vsp_state_op_defined(raw_state_op);
  assign branch_cond_defined = vsp_branch_cond_defined(raw_branch_cond);

  assign branch_shape_ok = complete_shape &&
      (record_word_count_i == VSP_UWORD_WORD_COUNT_W'(2)) &&
      (body_count == 2'd1);
  assign branch_reserved_ok =
      header[CONTROL_BRANCH_RESERVED_MSB:CONTROL_BRANCH_RESERVED_LSB] == '0;
  assign branch_unused_ok = (raw_branch_cond != VSP_BRANCH_COND_J) ||
      ((raw_branch_rs1 == '0) && (raw_branch_rs2 == '0));
  assign branch_address_ok = (raw_branch_cond == VSP_BRANCH_COND_J) ||
      ((int'(raw_branch_rs1) < STATE_REGS) &&
       (int'(raw_branch_rs2) < STATE_REGS));
  assign branch_offset_aligned = body_word[1:0] == 2'b00;

  always_comb begin
    expected_state_words = VSP_UWORD_WORD_COUNT_W'(1);
    unique case (raw_state_op)
      VSP_STATE_OP_SMOVI,
      VSP_STATE_OP_SADDI:
        expected_state_words = VSP_UWORD_WORD_COUNT_W'(2);
      default:
        expected_state_words = VSP_UWORD_WORD_COUNT_W'(1);
    endcase
  end

  assign state_shape_ok = complete_shape &&
      (record_word_count_i == expected_state_words) &&
      (body_count == (expected_state_words[1:0] - 2'd1));
  assign state_reserved_ok =
      header[CONTROL_STATE_RESERVED_MSB:CONTROL_STATE_RESERVED_LSB] == '0;

  always_comb begin
    state_unused_ok = 1'b1;
    unique case (raw_state_op)
      VSP_STATE_OP_SMOVI:
        state_unused_ok = (raw_rs1 == '0) && (raw_rs2 == '0);
      VSP_STATE_OP_SADD:
        state_unused_ok = 1'b1;
      VSP_STATE_OP_SADDI:
        state_unused_ok = raw_rs2 == '0;
      default:
        state_unused_ok = 1'b1;
    endcase
  end

  always_comb begin
    state_address_ok = 1'b1;
    unique case (raw_state_op)
      VSP_STATE_OP_SMOVI:
        state_address_ok = int'(raw_rd) < STATE_REGS;
      VSP_STATE_OP_SADD:
        state_address_ok = (int'(raw_rd) < STATE_REGS) &&
                           (int'(raw_rs1) < STATE_REGS) &&
                           (int'(raw_rs2) < STATE_REGS);
      VSP_STATE_OP_SADDI:
        state_address_ok = (int'(raw_rd) < STATE_REGS) &&
                           (int'(raw_rs1) < STATE_REGS);
      default:
        state_address_ok = 1'b1;
    endcase
  end

  always_comb begin
    selected_error = VSP_EXEC_UWORD_ERROR_NONE;
    if (major != VSP_UWORD_MAJOR_CONTROL)
      selected_error = VSP_EXEC_UWORD_ERROR_BAD_FORMAT;
    else if (!complete_shape)
      selected_error = VSP_EXEC_UWORD_ERROR_EXTENSION;
    else if (exact_end_header) begin
      if (record_word_count_i != VSP_UWORD_WORD_COUNT_W'(1))
        selected_error = VSP_EXEC_UWORD_ERROR_EXTENSION;
    end else if (branch_family) begin
      if (!branch_cond_defined)
        selected_error = VSP_EXEC_UWORD_ERROR_BAD_SUBOP;
      else if (!branch_shape_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_EXTENSION;
      else if (!branch_reserved_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_RESERVED_BITS;
      else if (!branch_unused_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_UNUSED_FIELD;
      else if (!branch_address_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_ADDRESS;
      else if (!branch_offset_aligned)
        selected_error = VSP_EXEC_UWORD_ERROR_IMMEDIATE;
    end else begin
      if (!state_subop_defined)
        selected_error = VSP_EXEC_UWORD_ERROR_BAD_SUBOP;
      else if (!state_shape_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_EXTENSION;
      else if (!state_reserved_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_RESERVED_BITS;
      else if (!state_unused_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_UNUSED_FIELD;
      else if (!state_address_ok)
        selected_error = VSP_EXEC_UWORD_ERROR_ADDRESS;
    end
  end

  always_comb begin
    out_valid_o = record_valid_i;
    is_control_end_o = record_valid_i && exact_end_header && complete_shape &&
        (record_word_count_i == VSP_UWORD_WORD_COUNT_W'(1));
    is_state_o = record_valid_i &&
        (major == VSP_UWORD_MAJOR_CONTROL) && !exact_end_header &&
        state_subop_defined;
    is_branch_o = record_valid_i &&
        (major == VSP_UWORD_MAJOR_CONTROL) && !exact_end_header &&
        branch_family;
    legal_o = record_valid_i &&
              (selected_error == VSP_EXEC_UWORD_ERROR_NONE);
    error_cause_o = record_valid_i ? selected_error :
                                     VSP_EXEC_UWORD_ERROR_NONE;

    state_op_o = '0;
    state_rd_o = '0;
    state_rs1_o = '0;
    state_rs2_o = '0;
    state_imm_o = '0;
    branch_cond_o = '0;
    branch_rs1_o = '0;
    branch_rs2_o = '0;
    branch_offset_o = '0;
    if (legal_o && is_state_o) begin
      state_op_o = raw_state_op;
      state_rd_o = STATE_REG_INDEX_W'(raw_rd);
      state_rs1_o = STATE_REG_INDEX_W'(raw_rs1);
      state_rs2_o = STATE_REG_INDEX_W'(raw_rs2);
      if ((raw_state_op == VSP_STATE_OP_SMOVI) ||
          (raw_state_op == VSP_STATE_OP_SADDI)) begin
        state_imm_o = body_word;
      end
    end
    if (legal_o && is_branch_o) begin
      branch_cond_o = raw_branch_cond;
      branch_rs1_o = STATE_REG_INDEX_W'(raw_branch_rs1);
      branch_rs2_o = STATE_REG_INDEX_W'(raw_branch_rs2);
      branch_offset_o = signed'(body_word);
    end
  end

  initial begin
    if (STATE_REGS < 1 || STATE_REGS > (2**CONTROL_ENCODED_REG_W))
      $error("CONTROL-state profile supports 1..32 state registers");
    if ((2**STATE_REG_INDEX_W) < STATE_REGS)
      $error("STATE_REG_INDEX_W cannot address every state register");
  end
endmodule
