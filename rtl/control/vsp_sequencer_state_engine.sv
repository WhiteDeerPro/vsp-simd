module vsp_sequencer_state_engine #(
  // This is sequencer-local address/stride/count state, not a scalar CPU.
  // It deliberately owns neither the program PC nor a memory port.
  parameter int STATE_W = 32,
  parameter int STATE_REGS = 32,
  parameter int CONTEXT_COUNT = 2,
  parameter int TAG_W = 8,
  parameter bit ZERO_REGISTER = 1'b1,
  parameter int STATE_REG_INDEX_W = (STATE_REGS <= 2) ? 1 :
                                    $clog2(STATE_REGS),
  parameter int CONTEXT_ID_W = (CONTEXT_COUNT <= 2) ? 1 :
                               $clog2(CONTEXT_COUNT)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One fully decoded state operation.  Arithmetic is modulo 2**STATE_W;
  // there are no flags or overflow exceptions.  Only operands used by the
  // selected operation are range checked.
  input  logic                                      cmd_valid_i,
  output logic                                      cmd_ready_o,
  input  logic [vsp_sequencer_state_pkg::VSP_STATE_OP_W-1:0]
                                                     cmd_op_i,
  input  logic [CONTEXT_ID_W-1:0]                   cmd_context_i,
  input  logic [TAG_W-1:0]                          cmd_tag_i,
  input  logic [STATE_REG_INDEX_W-1:0]              cmd_rd_i,
  input  logic [STATE_REG_INDEX_W-1:0]              cmd_rs1_i,
  input  logic [STATE_REG_INDEX_W-1:0]              cmd_rs2_i,
  input  logic [STATE_W-1:0]                        cmd_imm_i,

  // A combinational query used by a MEMORY semantic decoder.  The decoder
  // must sample the value when it admits the MEMORY action, so a later state
  // update cannot change an already-active transfer.
  input  logic                                      base_read_valid_i,
  input  logic [CONTEXT_ID_W-1:0]                   base_read_context_i,
  input  logic [STATE_REG_INDEX_W-1:0]              base_read_reg_i,
  output logic [STATE_W-1:0]                        base_read_data_o,
  output logic                                      base_read_legal_o,

  // CONTROL-flow gets a separate, combinational two-source view.  It is a
  // query rather than a state command: accepting a branch never changes the
  // state RF and never allocates this engine's completion register.  The
  // strict single-active wrapper currently prevents this query from racing a
  // MEMORY base snapshot, while the separate interface keeps that policy out
  // of the RF implementation.
  input  logic                                      control_read_valid_i,
  input  logic [CONTEXT_ID_W-1:0]                   control_read_context_i,
  input  logic [STATE_REG_INDEX_W-1:0]              control_read_rs1_i,
  input  logic [STATE_REG_INDEX_W-1:0]              control_read_rs2_i,
  output logic [STATE_W-1:0]                        control_read_rs1_data_o,
  output logic [STATE_W-1:0]                        control_read_rs2_data_o,
  output logic                                      control_read_legal_o,

  // Every accepted command produces exactly one registered completion.
  output logic                                      cpl_valid_o,
  input  logic                                      cpl_ready_i,
  output logic [CONTEXT_ID_W-1:0]                   cpl_context_o,
  output logic [TAG_W-1:0]                          cpl_tag_o,
  output logic [vsp_sequencer_state_pkg::VSP_STATE_CPL_STATUS_W-1:0]
                                                     cpl_status_o,
  output logic                                      busy_o
);
  import vsp_sequencer_state_pkg::*;

  logic [STATE_W-1:0] state_q [CONTEXT_COUNT][STATE_REGS];

  logic cpl_valid_q;
  logic [CONTEXT_ID_W-1:0] cpl_context_q;
  logic [TAG_W-1:0] cpl_tag_q;
  logic [VSP_STATE_CPL_STATUS_W-1:0] cpl_status_q;

  logic command_fire;
  logic command_context_legal;
  logic command_rd_legal;
  logic command_rs1_legal;
  logic command_rs2_legal;
  logic command_registers_legal;
  logic command_legal;
  logic [VSP_STATE_CPL_STATUS_W-1:0] command_status;
  logic [STATE_W-1:0] command_rs1_data;
  logic [STATE_W-1:0] command_rs2_data;
  logic [STATE_W-1:0] command_result;
  logic control_pair_selected;
  logic [CONTEXT_ID_W-1:0] pair_read_context;
  logic [STATE_REG_INDEX_W-1:0] pair_read_rs1;
  logic [STATE_REG_INDEX_W-1:0] pair_read_rs2;
  logic pair_read_context_legal;
  logic pair_read_rs1_legal;
  logic pair_read_rs2_legal;
  logic [STATE_W-1:0] pair_read_rs1_data;
  logic [STATE_W-1:0] pair_read_rs2_data;

  integer context_index;
  integer register_index;

  assign cmd_ready_o = rst_ni && (!cpl_valid_q || cpl_ready_i);
  assign command_fire = cmd_valid_i && cmd_ready_o;

  assign command_context_legal = int'(cmd_context_i) < CONTEXT_COUNT;
  assign command_rd_legal = int'(cmd_rd_i) < STATE_REGS;
  assign command_rs1_legal = int'(cmd_rs1_i) < STATE_REGS;
  assign command_rs2_legal = int'(cmd_rs2_i) < STATE_REGS;

  always_comb begin
    unique case (cmd_op_i)
      VSP_STATE_OP_SMOVI:
        command_registers_legal = command_rd_legal;
      VSP_STATE_OP_SADD:
        command_registers_legal = command_rd_legal &&
                                  command_rs1_legal && command_rs2_legal;
      VSP_STATE_OP_SADDI:
        command_registers_legal = command_rd_legal && command_rs1_legal;
      default:
        command_registers_legal = 1'b1;
    endcase
  end

  always_comb begin
    command_status = VSP_STATE_CPL_OK;
    if (!vsp_state_op_defined(cmd_op_i))
      command_status = VSP_STATE_CPL_BAD_OP;
    else if (!command_context_legal)
      command_status = VSP_STATE_CPL_BAD_CONTEXT;
    else if (!command_registers_legal)
      command_status = VSP_STATE_CPL_BAD_REGISTER;
  end
  assign command_legal = command_status == VSP_STATE_CPL_OK;

  // State arithmetic and CONTROL comparison are mutually exclusive in the
  // strict wrapper, so they share the same physical two-read view.  A direct
  // integration presenting both requests gives the state command priority;
  // the CONTROL query reports illegal for that cycle instead of inferring two
  // additional RF read ports.
  assign control_pair_selected = control_read_valid_i && !cmd_valid_i;
  assign pair_read_context = control_pair_selected ?
      control_read_context_i : cmd_context_i;
  assign pair_read_rs1 = control_pair_selected ? control_read_rs1_i :
                                                 cmd_rs1_i;
  assign pair_read_rs2 = control_pair_selected ? control_read_rs2_i :
                                                 cmd_rs2_i;
  assign pair_read_context_legal = int'(pair_read_context) < CONTEXT_COUNT;
  assign pair_read_rs1_legal = int'(pair_read_rs1) < STATE_REGS;
  assign pair_read_rs2_legal = int'(pair_read_rs2) < STATE_REGS;

  always_comb begin
    pair_read_rs1_data = '0;
    pair_read_rs2_data = '0;
    if (pair_read_context_legal && pair_read_rs1_legal &&
        !(ZERO_REGISTER && (pair_read_rs1 == '0))) begin
      pair_read_rs1_data =
          state_q[int'(pair_read_context)][int'(pair_read_rs1)];
    end
    if (pair_read_context_legal && pair_read_rs2_legal &&
        !(ZERO_REGISTER && (pair_read_rs2 == '0))) begin
      pair_read_rs2_data =
          state_q[int'(pair_read_context)][int'(pair_read_rs2)];
    end
  end

  always_comb begin
    command_rs1_data = control_pair_selected ? '0 : pair_read_rs1_data;
    command_rs2_data = control_pair_selected ? '0 : pair_read_rs2_data;

    unique case (cmd_op_i)
      VSP_STATE_OP_SMOVI: command_result = cmd_imm_i;
      VSP_STATE_OP_SADD:  command_result = command_rs1_data +
                                           command_rs2_data;
      VSP_STATE_OP_SADDI: command_result = command_rs1_data + cmd_imm_i;
      default:             command_result = '0;
    endcase

    // Register zero is a deterministic zero source, not an ABI role.  A
    // legal write to it completes successfully and has no state side effect.
    if (ZERO_REGISTER && (cmd_rd_i == '0))
      command_result = '0;
  end

  always_comb begin
    base_read_legal_o = base_read_valid_i &&
                        (int'(base_read_context_i) < CONTEXT_COUNT) &&
                        (int'(base_read_reg_i) < STATE_REGS);
    base_read_data_o = '0;
    if (base_read_legal_o &&
        !(ZERO_REGISTER && (base_read_reg_i == '0))) begin
      base_read_data_o =
          state_q[int'(base_read_context_i)][int'(base_read_reg_i)];
    end
  end

  always_comb begin
    control_read_legal_o = control_pair_selected &&
        pair_read_context_legal && pair_read_rs1_legal &&
        pair_read_rs2_legal;
    control_read_rs1_data_o = control_read_legal_o ?
        pair_read_rs1_data : '0;
    control_read_rs2_data_o = control_read_legal_o ?
        pair_read_rs2_data : '0;
  end

  assign cpl_valid_o = cpl_valid_q;
  assign cpl_context_o = cpl_context_q;
  assign cpl_tag_o = cpl_tag_q;
  assign cpl_status_o = cpl_status_q;
  assign busy_o = cpl_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (context_index = 0; context_index < CONTEXT_COUNT;
           context_index = context_index + 1) begin
        for (register_index = 0; register_index < STATE_REGS;
             register_index = register_index + 1) begin
          state_q[context_index][register_index] <= '0;
        end
      end
      cpl_valid_q <= 1'b0;
      cpl_context_q <= '0;
      cpl_tag_q <= '0;
      cpl_status_q <= VSP_STATE_CPL_OK;
    end else begin
      if (cpl_valid_q && cpl_ready_i)
        cpl_valid_q <= 1'b0;

      if (command_fire) begin
        cpl_valid_q <= 1'b1;
        cpl_context_q <= cmd_context_i;
        cpl_tag_q <= cmd_tag_i;
        cpl_status_q <= command_status;

        if (command_legal &&
            !(ZERO_REGISTER && (cmd_rd_i == '0))) begin
          state_q[int'(cmd_context_i)][int'(cmd_rd_i)] <= command_result;
        end
      end
    end
  end

  initial begin
    if (STATE_W < 1) $error("STATE_W must be positive");
    if (STATE_REGS < 1) $error("STATE_REGS must be positive");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (TAG_W < 1) $error("TAG_W must be positive");
    if ((2**STATE_REG_INDEX_W) < STATE_REGS)
      $error("STATE_REG_INDEX_W cannot address every state register");
    if ((2**CONTEXT_ID_W) < CONTEXT_COUNT)
      $error("CONTEXT_ID_W cannot address every context");
  end
endmodule
