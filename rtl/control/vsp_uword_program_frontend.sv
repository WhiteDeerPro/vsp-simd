module vsp_uword_program_frontend #(
  parameter int PC_W = 32,
  parameter int STORE_WORDS = 64,
  parameter logic [PC_W-1:0] STORE_BASE_PC = '0,
  parameter int BUNDLE_WORDS = 4,
  parameter int BUNDLE_COUNT_W = (BUNDLE_WORDS < 2) ? 1 :
                                 $clog2(BUNDLE_WORDS + 1)
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  input  logic                                      store_write_valid_i,
  output logic                                      store_write_ready_o,
  input  logic [PC_W-1:0]                           store_write_pc_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_W-1:0]    store_write_data_i,

  input  logic                                      start_valid_i,
  output logic                                      start_ready_o,
  input  logic [PC_W-1:0]                           start_pc_i,
  input  logic [PC_W-1:0]                           end_pc_i,

  output logic                                      record_valid_o,
  input  logic                                      record_ready_i,
  output logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
                                                     record_class_o,
  output logic                                      record_major_defined_o,
  output logic [PC_W-1:0]                           record_start_pc_o,
  output logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_word_count_o,
  output logic [vsp_uword_pkg::VSP_UWORD_WORD_COUNT_W-1:0]
                                                     record_present_word_count_o,
  output logic [(vsp_uword_pkg::VSP_UWORD_MAX_RECORD_WORDS*
                vsp_uword_pkg::VSP_UWORD_W)-1:0]    record_words_o,
  output logic                                      record_truncated_o,

  output logic [PC_W-1:0]                           current_pc_o,
  output logic                                      running_o,
  // All records in [start_pc_i,end_pc_i) have been delivered. This is not a
  // semantic program-success or CONTROL.END retirement indication.
  output logic                                      record_delivery_done_o,
  output logic                                      store_fault_o,
  input  logic                                      protocol_error_clear_i,
  output logic                                      protocol_error_o
);
  logic source_start_ready;
  logic source_start_valid;
  /* verilator lint_off UNUSED */
  logic source_redirect_ready_unused;
  /* verilator lint_on UNUSED */
  logic store_write_ready;
  logic store_write_valid;
  logic store_req_valid;
  logic store_req_ready;
  logic [PC_W-1:0] store_req_pc;
  logic [BUNDLE_COUNT_W-1:0] store_req_word_count;
  logic store_rsp_valid;
  logic store_rsp_ready;
  logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
      store_rsp_words;
  logic store_rsp_fault;
  logic control_store_protocol_error;
  logic source_bundle_valid;
  logic source_bundle_ready;
  logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
      source_bundle_words;
  logic [BUNDLE_COUNT_W-1:0] source_bundle_word_count;
  logic [PC_W-1:0] source_bundle_base_pc;
  logic source_bundle_last;
  logic source_running;
  logic source_delivery_done;
  logic source_store_fault;
  logic source_protocol_error;
  logic assembler_record_delivery_done;
  logic assembler_idle;
  logic assembler_protocol_error;

  assign source_start_valid = start_valid_i && assembler_idle;
  assign start_ready_o = source_start_ready && assembler_idle;
  assign running_o = source_running || !assembler_idle;
  assign store_write_valid = store_write_valid_i && !running_o;
  assign store_write_ready_o = store_write_ready && !running_o;
  // A nonempty stream finishes delivery only after the assembler's final
  // record is accepted. The source-side pulse is used only for an empty range.
  assign record_delivery_done_o = !protocol_error_o && !source_store_fault &&
      (assembler_record_delivery_done ||
       (source_delivery_done && assembler_idle));
  assign store_fault_o = source_store_fault;
  assign protocol_error_o = control_store_protocol_error ||
                            source_protocol_error ||
                            assembler_protocol_error;

  vsp_uword_control_store #(
    .PC_W(PC_W),
    .STORE_WORDS(STORE_WORDS),
    .STORE_BASE_PC(STORE_BASE_PC),
    .BUNDLE_WORDS(BUNDLE_WORDS),
    .BUNDLE_COUNT_W(BUNDLE_COUNT_W)
  ) u_control_store (
    .clk_i,
    .rst_ni,
    .write_valid_i(store_write_valid),
    .write_ready_o(store_write_ready),
    .write_pc_i(store_write_pc_i),
    .write_data_i(store_write_data_i),
    .req_valid_i(store_req_valid),
    .req_ready_o(store_req_ready),
    .req_pc_i(store_req_pc),
    .req_word_count_i(store_req_word_count),
    .rsp_valid_o(store_rsp_valid),
    .rsp_ready_i(store_rsp_ready),
    .rsp_words_o(store_rsp_words),
    .rsp_fault_o(store_rsp_fault),
    .protocol_error_clear_i,
    .protocol_error_o(control_store_protocol_error)
  );

  vsp_uword_program_source #(
    .PC_W(PC_W),
    .BUNDLE_WORDS(BUNDLE_WORDS),
    .BUNDLE_COUNT_W(BUNDLE_COUNT_W)
  ) u_program_source (
    .clk_i,
    .rst_ni,
    .start_valid_i(source_start_valid),
    .start_ready_o(source_start_ready),
    .start_pc_i,
    .end_pc_i,
    // This standalone framing harness remains a linear-stream component.
    // Program-level CONTROL flow is owned by the cluster program wrapper.
    .redirect_valid_i(1'b0),
    .redirect_ready_o(source_redirect_ready_unused),
    .redirect_pc_i('0),
    .store_req_valid_o(store_req_valid),
    .store_req_ready_i(store_req_ready),
    .store_req_pc_o(store_req_pc),
    .store_req_word_count_o(store_req_word_count),
    .store_rsp_valid_i(store_rsp_valid),
    .store_rsp_ready_o(store_rsp_ready),
    .store_rsp_words_i(store_rsp_words),
    .store_rsp_fault_i(store_rsp_fault),
    .bundle_valid_o(source_bundle_valid),
    .bundle_ready_i(source_bundle_ready),
    .bundle_words_o(source_bundle_words),
    .bundle_word_count_o(source_bundle_word_count),
    .bundle_base_pc_o(source_bundle_base_pc),
    .bundle_last_o(source_bundle_last),
    .current_pc_o,
    .running_o(source_running),
    .delivery_done_o(source_delivery_done),
    .store_fault_o(source_store_fault),
    .protocol_error_clear_i,
    .protocol_error_o(source_protocol_error)
  );

  vsp_uword_bundle_assembler #(
    .PC_W(PC_W),
    .BUNDLE_WORDS(BUNDLE_WORDS),
    .BUNDLE_COUNT_W(BUNDLE_COUNT_W)
  ) u_stream_assembler (
    .clk_i,
    .rst_ni,
    .bundle_valid_i(source_bundle_valid),
    .bundle_ready_o(source_bundle_ready),
    .bundle_words_i(source_bundle_words),
    .bundle_word_count_i(source_bundle_word_count),
    .bundle_base_pc_i(source_bundle_base_pc),
    .bundle_last_i(source_bundle_last),
    .record_valid_o,
    .record_ready_i,
    .record_class_o,
    .record_major_defined_o,
    .record_start_pc_o,
    .record_word_count_o,
    .record_present_word_count_o,
    .record_words_o,
    .record_truncated_o,
    .record_delivery_done_o(assembler_record_delivery_done),
    .idle_o(assembler_idle),
    .protocol_error_clear_i,
    .protocol_error_o(assembler_protocol_error)
  );
endmodule
