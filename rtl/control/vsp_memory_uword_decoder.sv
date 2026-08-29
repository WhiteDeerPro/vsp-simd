module vsp_memory_uword_decoder #(
  // MEMORY-uword profile v0 carries fixed-width state/row/context/offset
  // fields.  Only the resolved effective-address width and implemented RF
  // capacities remain parameters at this semantic boundary.
  parameter int MEM_EADDR_W = 32,
  parameter int STATE_REGS = 32,
  parameter int VREGS = 16,
  parameter int MAX_SPAN_BYTES =
      vsp_uword_pkg::VSP_MEMORY_UWORD_MAX_SPAN_BYTES
) (
  // One already-framed record.  The decoder never requests a missing body
  // word; an incomplete record becomes one deterministic ordered rejection.
  input  logic                                      record_valid_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_word_count_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_present_word_count_i,
  input  logic [(vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]    record_words_i,
  input  logic                                      record_truncated_i,

  // Combinational query into sequencer-local address state.  Integration
  // supplies the execution context separately and must sample base_eaddr_o
  // with the accepted action; a memory engine must never live-read this RF.
  output logic                                      base_read_valid_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_STATE_REG_W-1:0]
                                                     base_read_reg_o,
  input  logic [MEM_EADDR_W-1:0]                    base_read_data_i,
  input  logic                                      base_read_legal_i,

  output logic                                      out_valid_o,
  output logic                                      legal_o,
  output logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W-1:0]
                                                     error_cause_o,
  output logic [vsp_pkg::VSP_MEM_OP_W-1:0]         op_o,
  output logic [vsp_pkg::VSP_MEM_ADDR_SPACE_W-1:0] addr_space_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_ADDR_CONTEXT_W-1:0]
                                                     addr_context_o,
  output logic [MEM_EADDR_W-1:0]                    base_eaddr_o,
  output logic signed [vsp_uword_pkg::VSP_MEMORY_UWORD_OFFSET_W-1:0]
                                                     eaddr_offset_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_VRF_ROW_W-1:0]
                                                     vrf_row_o,
  output logic [vsp_uword_pkg::VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0]
                                                     span_bytes_o
);
  import vsp_exec_uword_pkg::*;
  import vsp_pkg::*;
  import vsp_uword_pkg::*;

  logic [VSP_UWORD_W-1:0] header;
  logic [VSP_UWORD_W-1:0] offset_word;
  logic [VSP_UWORD_MAJOR_W-1:0] raw_major;
  logic [VSP_MEM_OP_W-1:0] raw_op;
  logic [VSP_MEM_ADDR_SPACE_W-1:0] raw_addr_space;
  logic [VSP_MEMORY_UWORD_ADDR_CONTEXT_W-1:0] raw_addr_context;
  logic [VSP_MEMORY_UWORD_STATE_REG_W-1:0] raw_state_reg;
  logic [VSP_MEMORY_UWORD_VRF_ROW_W-1:0] raw_vrf_row;
  logic [VSP_MEMORY_UWORD_SPAN_BYTES_W-1:0] raw_span_bytes;
  logic signed [VSP_MEMORY_UWORD_OFFSET_W-1:0] raw_offset;

  logic format_ok;
  logic shape_ok;
  logic reserved_ok;
  logic offset_ok;
  logic addr_space_ok;
  logic state_reg_ok;
  logic vrf_row_ok;
  logic span_ok;
  logic address_ok;
  logic [VSP_EXEC_UWORD_ERROR_W-1:0] selected_error;

  assign header = record_words_i[0 +: VSP_UWORD_W];
  assign offset_word = record_words_i[VSP_UWORD_W +: VSP_UWORD_W];
  assign raw_major = header[VSP_UWORD_W-1 -: VSP_UWORD_MAJOR_W];
  assign raw_op = header[VSP_MEMORY_UWORD_OP_BIT];
  assign raw_addr_space =
      header[VSP_MEMORY_UWORD_ADDR_SPACE_MSB:
             VSP_MEMORY_UWORD_ADDR_SPACE_LSB];
  assign raw_addr_context =
      header[VSP_MEMORY_UWORD_ADDR_CONTEXT_MSB:
             VSP_MEMORY_UWORD_ADDR_CONTEXT_LSB];
  assign raw_state_reg =
      header[VSP_MEMORY_UWORD_STATE_REG_MSB:
             VSP_MEMORY_UWORD_STATE_REG_LSB];
  assign raw_vrf_row =
      header[VSP_MEMORY_UWORD_VRF_ROW_MSB:
             VSP_MEMORY_UWORD_VRF_ROW_LSB];
  assign raw_span_bytes =
      header[VSP_MEMORY_UWORD_SPAN_BYTES_MSB:
             VSP_MEMORY_UWORD_SPAN_BYTES_LSB];
  assign raw_offset = offset_word[VSP_MEMORY_UWORD_OFFSET_W-1:0];

  assign format_ok =
      (raw_major == VSP_UWORD_MAJOR_MEMORY) &&
      (header[27:26] == VSP_MEMORY_UWORD_BODY_WORDS);
  assign shape_ok = !record_truncated_i &&
      (record_word_count_i ==
          VSP_UWORD_WORD_COUNT_W'(VSP_MEMORY_UWORD_RECORD_WORDS)) &&
      (record_present_word_count_i ==
          VSP_UWORD_WORD_COUNT_W'(VSP_MEMORY_UWORD_RECORD_WORDS));
  assign reserved_ok = !header[VSP_MEMORY_UWORD_RESERVED_BIT];
  assign offset_ok =
      offset_word[VSP_UWORD_W-1:VSP_MEMORY_UWORD_OFFSET_W] ==
          {(VSP_UWORD_W-VSP_MEMORY_UWORD_OFFSET_W){
              offset_word[VSP_MEMORY_UWORD_OFFSET_W-1]}};
  assign addr_space_ok = vsp_mem_addr_space_defined(raw_addr_space);
  assign state_reg_ok = int'(raw_state_reg) < STATE_REGS;
  assign vrf_row_ok = int'(raw_vrf_row) < VREGS;
  assign span_ok = (int'(raw_span_bytes) > 0) &&
                   (int'(raw_span_bytes) <= MAX_SPAN_BYTES);
  assign address_ok = state_reg_ok && base_read_legal_i &&
                      vrf_row_ok && span_ok;

  // Query only after the complete two-word MEMORY shape is visible.  A bad
  // register index is rejected locally rather than being truncated into a
  // different sequencer-state address.
  assign base_read_valid_o = record_valid_i && format_ok && shape_ok &&
                             reserved_ok && offset_ok && addr_space_ok &&
                             state_reg_ok && vrf_row_ok && span_ok;
  assign base_read_reg_o = raw_state_reg;

  // Use the established four-bit ordered-decode diagnostic lane.  MEMORY
  // shares only the generic structural/immediate/address causes; execution
  // function-specific causes remain exclusive to the EXEC expander.
  always_comb begin
    selected_error = VSP_EXEC_UWORD_ERROR_NONE;
    if (!format_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_BAD_FORMAT;
    else if (!shape_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_EXTENSION;
    else if (!reserved_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_RESERVED_BITS;
    else if (!offset_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_IMMEDIATE;
    else if (!addr_space_ok || !address_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_ADDRESS;
  end

  always_comb begin
    out_valid_o = record_valid_i;
    legal_o = out_valid_o &&
              (selected_error == VSP_EXEC_UWORD_ERROR_NONE);
    error_cause_o = out_valid_o ? selected_error :
                                  VSP_EXEC_UWORD_ERROR_NONE;

    // Illegal records cannot leak a partially decoded memory side effect.
    op_o = VSP_MEM_OP_LOAD;
    addr_space_o = VSP_MEM_ADDR_SPACE_LOCAL;
    addr_context_o = '0;
    base_eaddr_o = '0;
    eaddr_offset_o = '0;
    vrf_row_o = '0;
    span_bytes_o = '0;
    if (legal_o) begin
      op_o = raw_op;
      addr_space_o = raw_addr_space;
      addr_context_o = raw_addr_context;
      base_eaddr_o = base_read_data_i;
      eaddr_offset_o = raw_offset;
      vrf_row_o = raw_vrf_row;
      span_bytes_o = raw_span_bytes;
    end
  end

  initial begin
    if (MEM_EADDR_W < 1) $error("MEM_EADDR_W must be positive");
    if ((STATE_REGS < 1) ||
        (STATE_REGS > (2**VSP_MEMORY_UWORD_STATE_REG_W))) begin
      $error("MEMORY profile state-register capacity is 1..32");
    end
    if ((VREGS < 1) ||
        (VREGS > (2**VSP_MEMORY_UWORD_VRF_ROW_W))) begin
      $error("MEMORY profile VRF-row capacity is 1..16");
    end
    if ((MAX_SPAN_BYTES < 1) ||
        (MAX_SPAN_BYTES > VSP_MEMORY_UWORD_MAX_SPAN_BYTES)) begin
      $error("MEMORY profile span capacity is 1..16 bytes");
    end
  end
endmodule
