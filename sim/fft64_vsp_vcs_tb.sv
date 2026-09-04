`timescale 1ns/1ps

// VCS end-to-end regression for the generated static-BFP8 FFT program.
// The image enters through backing_init_*; execution then follows the normal
// PC -> I-cache -> decode -> SIMD/D-memory -> D-cache -> shared SRAM path.
module fft64_vsp_vcs_tb;
  localparam integer PROGRAM_WORDS = 93;
  localparam integer DATA_WORDS = 224;
  localparam integer GOLDEN_WORDS = 32;
  localparam integer EXPECTED_ACTIONS = 449;
  localparam integer SETUP_ACTIONS = 13;
  localparam integer ACTIONS_PER_BATCH = 36;
  localparam integer BATCHES_PER_STAGE = 2;
  localparam integer BFP_STAGE_COUNT = 6;
  localparam logic [31:0] PROGRAM_BASE = 32'h0000_0020;
  localparam logic [39:0] DATA_BASE = 40'h0000_001000;
  localparam logic [39:0] REAL_BASE = 40'h0000_001000;
  localparam logic [39:0] IMAG_BASE = 40'h0000_001040;
  localparam logic [39:0] BFP_EXPONENT_IN_BASE = 40'h0000_001360;
  localparam logic [39:0] BFP_EXPONENT_OUT_BASE = 40'h0000_001370;
  localparam integer EXPONENT_DATA_WORD =
      (BFP_EXPONENT_IN_BASE - DATA_BASE) / 4;

  logic clk_i;
  logic rst_ni;
  logic start_valid_i;
  logic start_ready_o;
  logic [31:0] start_pc_i;
  logic [31:0] end_pc_i;
  logic start_context_i;
  logic [3:0] start_group_mask_i;
  logic [7:0] start_tag_seed_i;
  logic [vsp_mem_common_pkg::VSP_MEM_ADDR_SPACE_W-1:0]
      start_ifetch_addr_space_i;
  logic [vsp_ifetch_adapter_pkg::VSP_IFETCH_CONTEXT_W-1:0]
      start_ifetch_addr_context_i;

  logic [31:0] fetch_pc_o;
  logic fetch_running_o;
  logic program_active_o;
  logic program_done_o;
  logic program_failed_o;
  logic program_error_o;
  logic program_halted_o;
  logic [31:0] program_terminal_pc_o;

  logic action_cpl_valid_o;
  logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0] action_cpl_class_o;
  logic [vsp_action_pkg::VSP_ACTION_CPL_STATUS_W-1:0]
      action_cpl_status_o;
  logic [vsp_pkg::VSP_MEM_CPL_STATUS_W-1:0]
      action_cpl_memory_status_o;
  logic [vsp_pkg::VSP_MEM_FAULT_CAUSE_W-1:0]
      action_cpl_memory_fault_cause_o;
  logic [3:0] action_cpl_memory_failed_group_mask_o;
  logic action_cpl_memory_partial_o;

  logic backing_init_valid_i;
  logic backing_init_ready_o;
  logic [39:0] backing_init_paddr_i;
  logic [31:0] backing_init_wdata_i;
  logic [3:0] backing_init_wstrb_i;
  logic backing_init_error_o;
  logic [39:0] backing_peek_paddr_i;
  logic [31:0] backing_peek_rdata_o;
  logic backing_peek_error_o;

  logic system_ready_o;
  logic system_quiescent_o;
  logic perf_icache_read_hit_o;
  logic perf_icache_read_miss_o;
  logic perf_dcache_read_hit_o;
  logic perf_dcache_read_miss_o;
  logic perf_dcache_write_hit_o;
  logic perf_dcache_write_miss_o;
  logic fetch_protocol_error_o;
  logic cluster_protocol_error_o;
  logic ifetch_path_protocol_error_o;
  logic dmem_path_protocol_error_o;
  logic maint_protocol_error_o;
  logic protocol_error_o;
  logic [31:0] lower_req_count_o;
  logic [31:0] lower_read_req_count_o;
  logic [31:0] lower_write_req_count_o;
  logic [31:0] lower_rsp_count_o;

  logic [31:0] program_image [0:PROGRAM_WORDS-1];
  logic [31:0] data_image [0:DATA_WORDS-1];
  logic [31:0] golden_image [0:GOLDEN_WORDS-1];
  logic [31:0] rtl_output_image [0:GOLDEN_WORDS-1];

  // One-bin-per-cycle post-run view of the completed spectrum.  These signals
  // deliberately remain at the testbench boundary so Verdi can display them
  // without reaching through the memory-system hierarchy.
  logic plot_valid;
  logic [5:0] plot_bin;
  logic signed [7:0] plot_real_mantissa;
  logic signed [7:0] plot_imag_mantissa;
  logic signed [7:0] plot_exponent;
  real plot_real_value;
  real plot_imag_value;
  real plot_magnitude;
  real plot_power;
  logic signed [31:0] plot_real_q16_16;
  logic signed [31:0] plot_imag_q16_16;
  logic signed [31:0] plot_magnitude_q16_16;
  logic signed [31:0] plot_power_q16_16;
  logic [31:0] bfp_output_exponent_word_actual;
  logic signed [7:0] actual_bfp_exponent;
  logic signed [7:0] input_bfp_exponent_byte;
  logic signed [7:0] expected_output_bfp_exponent_byte;
  logic [31:0] expected_input_bfp_exponent_word;
  logic [31:0] expected_output_bfp_exponent_word;

  integer checks;
  integer cycles;
  integer completed_actions;
  integer completion_errors;
  integer icache_hits;
  integer icache_misses;
  integer dcache_read_hits;
  integer dcache_read_misses;
  integer dcache_write_hits;
  integer dcache_write_misses;
  integer fft_batch;
  integer fft_stage;
  integer bfp_exponent;
  integer input_bfp_exponent;
  integer expected_output_bfp_exponent;
  integer value_scale_numerator;
  integer value_scale_denominator;
  integer index;
  integer timeout;
  integer workload_cycles;
  integer spectrum_fd;
  integer scan_real_integer;
  integer scan_imag_integer;
  integer scan_exponent_integer;
  real scan_scale;
  logic done_seen;
  logic failed_seen;
  string program_hex;
  string data_hex;
  string golden_hex;
  string output_hex;
  string wave_file;
  string csv_file;

  vsp_uword_memory_system_wrapper_tb_top dut (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .start_valid_i(start_valid_i),
    .start_ready_o(start_ready_o),
    .start_pc_i(start_pc_i),
    .end_pc_i(end_pc_i),
    .start_context_i(start_context_i),
    .start_group_mask_i(start_group_mask_i),
    .start_tag_seed_i(start_tag_seed_i),
    .start_ifetch_addr_space_i(start_ifetch_addr_space_i),
    .start_ifetch_addr_context_i(start_ifetch_addr_context_i),
    .fetch_pc_o(fetch_pc_o),
    .fetch_running_o(fetch_running_o),
    .program_active_o(program_active_o),
    .program_done_o(program_done_o),
    .program_failed_o(program_failed_o),
    .program_error_o(program_error_o),
    .program_halted_o(program_halted_o),
    .program_terminal_pc_o(program_terminal_pc_o),
    .action_cpl_valid_o(action_cpl_valid_o),
    .action_cpl_ready_i(1'b1),
    .action_cpl_class_o(action_cpl_class_o),
    .action_cpl_tag_o(),
    .action_cpl_group_mask_o(),
    .action_cpl_status_o(action_cpl_status_o),
    .action_cpl_end_o(),
    .action_cpl_memory_op_o(),
    .action_cpl_memory_status_o(action_cpl_memory_status_o),
    .action_cpl_memory_fault_cause_o(action_cpl_memory_fault_cause_o),
    .action_cpl_memory_fault_eaddr_o(),
    .action_cpl_memory_requested_group_mask_o(),
    .action_cpl_memory_completed_group_mask_o(),
    .action_cpl_memory_failed_group_mask_o(
        action_cpl_memory_failed_group_mask_o),
    .action_cpl_memory_bytes_committed_o(),
    .action_cpl_memory_partial_o(action_cpl_memory_partial_o),
    .mmu_cfg_valid_i(1'b0),
    .mmu_cfg_ready_o(),
    .mmu_cfg_write_i(1'b0),
    .mmu_cfg_context_i('0),
    .mmu_cfg_field_i('0),
    .mmu_cfg_wdata_i('0),
    .mmu_cfg_rsp_valid_o(),
    .mmu_cfg_rsp_ready_i(1'b1),
    .mmu_cfg_rsp_rdata_o(),
    .mmu_cfg_rsp_status_o(),
    .maint_cmd_valid_i(1'b0),
    .maint_cmd_ready_o(),
    .maint_cmd_op_i('0),
    .maint_cmd_eaddr_i('0),
    .maint_cmd_paddr_i('0),
    .maint_cmd_addr_context_i('0),
    .maint_cmd_asid_i('0),
    .maint_cpl_valid_o(),
    .maint_cpl_ready_i(1'b1),
    .maint_cpl_status_o(),
    .maint_cpl_fault_o(),
    .maint_busy_o(),
    .maint_quiescent_o(),
    .maint_current_step_o(),
    .backing_init_valid_i(backing_init_valid_i),
    .backing_init_ready_o(backing_init_ready_o),
    .backing_init_paddr_i(backing_init_paddr_i),
    .backing_init_wdata_i(backing_init_wdata_i),
    .backing_init_wstrb_i(backing_init_wstrb_i),
    .backing_init_error_o(backing_init_error_o),
    .backing_peek_paddr_i(backing_peek_paddr_i),
    .backing_peek_rdata_o(backing_peek_rdata_o),
    .backing_peek_error_o(backing_peek_error_o),
    .system_ready_o(system_ready_o),
    .system_quiescent_o(system_quiescent_o),
    .system_busy_o(),
    .dmem_path_ready_o(),
    .ifetch_path_ready_o(),
    .mmu_init_done_o(),
    .dcache_init_done_o(),
    .icache_init_done_o(),
    .fabric_quarantine_o(),
    .i_region_config_overlap_o(),
    .d_region_config_overlap_o(),
    .perf_icache_read_hit_o(perf_icache_read_hit_o),
    .perf_icache_read_miss_o(perf_icache_read_miss_o),
    .perf_dcache_read_hit_o(perf_dcache_read_hit_o),
    .perf_dcache_read_miss_o(perf_dcache_read_miss_o),
    .perf_dcache_write_hit_o(perf_dcache_write_hit_o),
    .perf_dcache_write_miss_o(perf_dcache_write_miss_o),
    .protocol_error_clear_i(1'b0),
    .fetch_protocol_error_o(fetch_protocol_error_o),
    .cluster_protocol_error_o(cluster_protocol_error_o),
    .ifetch_path_protocol_error_o(ifetch_path_protocol_error_o),
    .dmem_path_protocol_error_o(dmem_path_protocol_error_o),
    .maint_protocol_error_o(maint_protocol_error_o),
    .protocol_error_o(protocol_error_o),
    .lower_req_count_o(lower_req_count_o),
    .lower_read_req_count_o(lower_read_req_count_o),
    .lower_write_req_count_o(lower_write_req_count_o),
    .lower_rsp_count_o(lower_rsp_count_o)
  );

  always #5 clk_i = ~clk_i;

  task automatic expect_equal;
    input string label;
    input logic [63:0] expected;
    input logic [63:0] actual;
    begin
      checks = checks + 1;
      if (actual !== expected) begin
        $display("FAIL %0s expected=0x%0h actual=0x%0h", label,
                 expected, actual);
        $fatal(1);
      end
    end
  endtask

  task automatic initialize_word;
    input logic [39:0] address;
    input logic [31:0] value;
    integer ready_timeout;
    begin
      @(negedge clk_i);
      backing_init_paddr_i = address;
      backing_init_wdata_i = value;
      backing_init_wstrb_i = 4'hf;
      backing_init_valid_i = 1'b1;
      ready_timeout = 0;
      while (!backing_init_ready_o) begin
        @(negedge clk_i);
        ready_timeout = ready_timeout + 1;
        if (ready_timeout == 10000)
          $fatal(1, "backing SRAM initialization ready timeout");
      end
      @(posedge clk_i);
      #1;
      expect_equal("backing SRAM initialization address", 0,
                   backing_init_error_o);
      @(negedge clk_i);
      backing_init_valid_i = 1'b0;
    end
  endtask

  function automatic [7:0] extract_packed_byte;
    input logic [31:0] word;
    input integer lane;
    begin
      case (lane)
        0: extract_packed_byte = word[7:0];
        1: extract_packed_byte = word[15:8];
        2: extract_packed_byte = word[23:16];
        default: extract_packed_byte = word[31:24];
      endcase
    end
  endfunction

  always @(posedge clk_i) begin
    if (!rst_ni) begin
      cycles <= 0;
      completed_actions <= 0;
      completion_errors <= 0;
      icache_hits <= 0;
      icache_misses <= 0;
      dcache_read_hits <= 0;
      dcache_read_misses <= 0;
      dcache_write_hits <= 0;
      dcache_write_misses <= 0;
      fft_batch <= 0;
      fft_stage <= 0;
      bfp_exponent <= input_bfp_exponent;
    end else begin
      cycles <= cycles + 1;
      if (perf_icache_read_hit_o) icache_hits <= icache_hits + 1;
      if (perf_icache_read_miss_o) icache_misses <= icache_misses + 1;
      if (perf_dcache_read_hit_o) dcache_read_hits <= dcache_read_hits + 1;
      if (perf_dcache_read_miss_o)
        dcache_read_misses <= dcache_read_misses + 1;
      if (perf_dcache_write_hit_o) dcache_write_hits <= dcache_write_hits + 1;
      if (perf_dcache_write_miss_o)
        dcache_write_misses <= dcache_write_misses + 1;

      if (action_cpl_valid_o) begin
        completed_actions <= completed_actions + 1;
        if (action_cpl_status_o !== '0)
          completion_errors <= completion_errors + 1;
        if ((action_cpl_class_o !== 2'd0) &&
            (action_cpl_class_o !== 2'd1) &&
            (action_cpl_class_o !== 2'd2))
          completion_errors <= completion_errors + 1;
        if ((action_cpl_class_o === 2'd1) &&
            ((action_cpl_memory_status_o !== '0) ||
             (action_cpl_memory_fault_cause_o !== '0) ||
             (action_cpl_memory_failed_group_mask_o !== '0) ||
             (action_cpl_memory_partial_o !== 1'b0)))
          completion_errors <= completion_errors + 1;

        if ((completed_actions + 1) >= SETUP_ACTIONS &&
            (completed_actions + 1) <
                (SETUP_ACTIONS + 12 * ACTIONS_PER_BATCH)) begin
          fft_batch <= (completed_actions + 1 - SETUP_ACTIONS) /
                       ACTIONS_PER_BATCH;
          fft_stage <= ((completed_actions + 1 - SETUP_ACTIONS) /
                        ACTIONS_PER_BATCH) / BATCHES_PER_STAGE;
        end
        if ((completed_actions + 1) > SETUP_ACTIONS &&
            (completed_actions + 1) <=
                (SETUP_ACTIONS + 12 * ACTIONS_PER_BATCH) &&
            (((completed_actions + 1 - SETUP_ACTIONS) %
              (ACTIONS_PER_BATCH * BATCHES_PER_STAGE)) == 0))
          bfp_exponent <= input_bfp_exponent +
                          (completed_actions + 1 - SETUP_ACTIONS) /
                          (ACTIONS_PER_BATCH * BATCHES_PER_STAGE);
      end
    end
  end

`ifdef FFT64_VCS_WAVE
  initial begin
    if (!$value$plusargs("WAVE_FILE=%s", wave_file))
      wave_file = "fft64_vsp.vpd";
    $vcdplusfile(wave_file);
    $vcdpluson(2, fft64_vsp_vcs_tb);
  end
`endif

  initial begin
    clk_i = 1'b0;
    rst_ni = 1'b0;
    start_valid_i = 1'b0;
    start_pc_i = PROGRAM_BASE;
    end_pc_i = PROGRAM_BASE + 4 * PROGRAM_WORDS;
    start_context_i = 1'b0;
    start_group_mask_i = 4'hf;
    start_tag_seed_i = 8'h20;
    start_ifetch_addr_space_i = 1;
    start_ifetch_addr_context_i = 8'h5a;
    backing_init_valid_i = 1'b0;
    backing_init_paddr_i = '0;
    backing_init_wdata_i = '0;
    backing_init_wstrb_i = '0;
    backing_peek_paddr_i = '0;
    checks = 0;
    done_seen = 1'b0;
    failed_seen = 1'b0;
    workload_cycles = 0;
    plot_valid = 1'b0;
    plot_bin = '0;
    plot_real_mantissa = '0;
    plot_imag_mantissa = '0;
    plot_exponent = '0;
    plot_real_value = 0.0;
    plot_imag_value = 0.0;
    plot_magnitude = 0.0;
    plot_power = 0.0;
    plot_real_q16_16 = '0;
    plot_imag_q16_16 = '0;
    plot_magnitude_q16_16 = '0;
    plot_power_q16_16 = '0;
    bfp_output_exponent_word_actual = '0;
    actual_bfp_exponent = '0;
    input_bfp_exponent = 0;
    expected_output_bfp_exponent = BFP_STAGE_COUNT;
    input_bfp_exponent_byte = '0;
    expected_output_bfp_exponent_byte = BFP_STAGE_COUNT;
    expected_input_bfp_exponent_word = '0;
    expected_output_bfp_exponent_word = '0;
    value_scale_numerator = 1;
    value_scale_denominator = 8;

    if (!$value$plusargs("PROGRAM_HEX=%s", program_hex))
      $fatal(1, "PROGRAM_HEX plusarg is required");
    if (!$value$plusargs("DATA_HEX=%s", data_hex))
      $fatal(1, "DATA_HEX plusarg is required");
    if (!$value$plusargs("GOLDEN_HEX=%s", golden_hex))
      $fatal(1, "GOLDEN_HEX plusarg is required");
    if (!$value$plusargs("OUTPUT_HEX=%s", output_hex))
      $fatal(1, "OUTPUT_HEX plusarg is required");
    if (!$value$plusargs("CSV_FILE=%s", csv_file))
      csv_file = "fft64_vsp_spectrum.csv";
    if (!$value$plusargs("SCALE_NUM=%d", value_scale_numerator))
      value_scale_numerator = 1;
    if (!$value$plusargs("SCALE_DEN=%d", value_scale_denominator))
      value_scale_denominator = 8;
    if ((value_scale_numerator <= 0) || (value_scale_denominator <= 0))
      $fatal(1, "SCALE_NUM and SCALE_DEN must both be positive");
    $readmemh(program_hex, program_image);
    $readmemh(data_hex, data_image);
    $readmemh(golden_hex, golden_image);

    // The fixture owns the execution exponent.  Reading it from the SRAM
    // image keeps this testbench valid for every generated waveform profile.
    input_bfp_exponent_byte =
        $signed(extract_packed_byte(data_image[EXPONENT_DATA_WORD], 0));
    input_bfp_exponent = $signed(input_bfp_exponent_byte);
    expected_output_bfp_exponent = input_bfp_exponent + BFP_STAGE_COUNT;
    if ((expected_output_bfp_exponent < -128) ||
        (expected_output_bfp_exponent > 127))
      $fatal(1, "output execution exponent exceeds signed-int8 range");
    expected_output_bfp_exponent_byte = expected_output_bfp_exponent;
    expected_input_bfp_exponent_word = {4{input_bfp_exponent_byte}};
    expected_output_bfp_exponent_word =
        {4{expected_output_bfp_exponent_byte}};

    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;
    timeout = 0;
    while (!(system_ready_o && system_quiescent_o && start_ready_o)) begin
      @(posedge clk_i);
      timeout = timeout + 1;
      if (timeout == 10000) $fatal(1, "memory-system initialization timeout");
    end

    for (index = 0; index < PROGRAM_WORDS; index = index + 1)
      initialize_word(PROGRAM_BASE + 4 * index, program_image[index]);
    for (index = 0; index < DATA_WORDS; index = index + 1)
      initialize_word(DATA_BASE + 4 * index, data_image[index]);
    expect_equal("image initialization emits no lower request", 0,
                 lower_req_count_o);

    @(negedge clk_i);
    start_valid_i = 1'b1;
    expect_equal("launch is ready", 1, start_ready_o);
    @(posedge clk_i);
    @(negedge clk_i);
    start_valid_i = 1'b0;

    timeout = 0;
    while (!(done_seen || failed_seen)) begin
      @(posedge clk_i);
      #1;
      done_seen = done_seen || program_done_o;
      failed_seen = failed_seen || program_failed_o;
      timeout = timeout + 1;
      if (timeout == 2000000) $fatal(1, "FFT program timeout");
    end
    timeout = 0;
    while (program_active_o) begin
      @(posedge clk_i);
      timeout = timeout + 1;
      if (timeout == 2000000) $fatal(1, "program-active drain timeout");
    end
    timeout = 0;
    while (!system_quiescent_o) begin
      @(posedge clk_i);
      timeout = timeout + 1;
      if (timeout == 2000000) $fatal(1, "memory-system quiescence timeout");
    end
    #1;
    // Subsequent waveform scanning intentionally consumes 64 cycles.  Preserve
    // the actual FFT workload latency before that visualization-only phase.
    workload_cycles = cycles;

    expect_equal("FFT program completed", 1, done_seen);
    expect_equal("FFT program did not fail", 0, failed_seen);
    expect_equal("FFT program accumulated no error", 0, program_error_o);
    expect_equal("all actions retired", EXPECTED_ACTIONS, completed_actions);
    expect_equal("all action completions are clean", 0, completion_errors);

    for (index = 0; index < 16; index = index + 1) begin
      backing_peek_paddr_i = REAL_BASE + 4 * index;
      #1;
      rtl_output_image[index] = backing_peek_rdata_o;
      expect_equal("FFT real output word", golden_image[index],
                   rtl_output_image[index]);
      expect_equal("FFT real peek address", 0, backing_peek_error_o);
      backing_peek_paddr_i = IMAG_BASE + 4 * index;
      #1;
      rtl_output_image[index + 16] = backing_peek_rdata_o;
      expect_equal("FFT imag output word", golden_image[index + 16],
                   rtl_output_image[index + 16]);
      expect_equal("FFT imag peek address", 0, backing_peek_error_o);
    end
    for (index = 0; index < 4; index = index + 1) begin
      backing_peek_paddr_i = BFP_EXPONENT_IN_BASE + 4 * index;
      #1;
      expect_equal("BFP input exponent word", expected_input_bfp_exponent_word,
                   backing_peek_rdata_o);
      expect_equal("BFP input exponent peek address", 0,
                   backing_peek_error_o);
      backing_peek_paddr_i = BFP_EXPONENT_OUT_BASE + 4 * index;
      #1;
      if (index == 0)
        bfp_output_exponent_word_actual = backing_peek_rdata_o;
      expect_equal("BFP output exponent word", expected_output_bfp_exponent_word,
                   backing_peek_rdata_o);
      expect_equal("BFP exponent peek address", 0, backing_peek_error_o);
    end

    expect_equal("combined protocol error", 0, protocol_error_o);
    expect_equal("fetch protocol error", 0, fetch_protocol_error_o);
    expect_equal("cluster protocol error", 0, cluster_protocol_error_o);
    expect_equal("I-side protocol error", 0, ifetch_path_protocol_error_o);
    expect_equal("D-side protocol error", 0, dmem_path_protocol_error_o);
    expect_equal("maintenance protocol error", 0, maint_protocol_error_o);
    expect_equal("every lower request has a response", lower_req_count_o,
                 lower_rsp_count_o);
    if (icache_hits == 0 || icache_misses == 0 ||
        dcache_read_hits == 0 || dcache_read_misses == 0 ||
        (dcache_write_hits + dcache_write_misses) == 0 ||
        lower_read_req_count_o == 0 || lower_write_req_count_o == 0)
      $fatal(1, "FFT did not exercise the required cache/RAM paths");
    $writememh(output_hex, rtl_output_image);

    // Decode the execution exponent from the value actually read at 0x1370.
    // The separate SCALE_NUM/SCALE_DEN pair maps result mantissas into the
    // user's signal convention (for example, 64/127 for q/127 input samples).
    actual_bfp_exponent =
        $signed(extract_packed_byte(bfp_output_exponent_word_actual, 0));
    scan_exponent_integer = $signed(actual_bfp_exponent);
    scan_scale = $itor(value_scale_numerator) /
                 $itor(value_scale_denominator);

    spectrum_fd = $fopen(csv_file, "w");
    if (spectrum_fd == 0)
      $fatal(1, "cannot open FFT spectrum CSV %0s", csv_file);
    $fwrite(spectrum_fd,
            "bin,real_mantissa,imag_mantissa,execution_exponent,value_scale,real_value,imag_value,magnitude,power\n");

    for (index = 0; index < 64; index = index + 1) begin
      @(negedge clk_i);
      plot_valid = 1'b1;
      plot_bin = index;
      plot_real_mantissa = $signed(extract_packed_byte(
          rtl_output_image[index / 4], index % 4));
      plot_imag_mantissa = $signed(extract_packed_byte(
          rtl_output_image[16 + index / 4], index % 4));
      plot_exponent = actual_bfp_exponent;
      scan_real_integer = $signed(plot_real_mantissa);
      scan_imag_integer = $signed(plot_imag_mantissa);
      plot_real_value = $itor(scan_real_integer) * scan_scale;
      plot_imag_value = $itor(scan_imag_integer) * scan_scale;
      plot_power = plot_real_value * plot_real_value +
                   plot_imag_value * plot_imag_value;
      plot_magnitude = $sqrt(plot_power);
      plot_real_q16_16 = $rtoi(plot_real_value * 65536.0);
      plot_imag_q16_16 = $rtoi(plot_imag_value * 65536.0);
      plot_magnitude_q16_16 = $rtoi(plot_magnitude * 65536.0);
      plot_power_q16_16 = $rtoi(plot_power * 65536.0);
      $fwrite(spectrum_fd, "%0d,%0d,%0d,%0d,%0.17g,%0.17g,%0.17g,%0.17g,%0.17g\n",
              index, scan_real_integer, scan_imag_integer,
              scan_exponent_integer, scan_scale, plot_real_value,
              plot_imag_value, plot_magnitude, plot_power);
    end
    @(negedge clk_i);
    plot_valid = 1'b0;
    $fclose(spectrum_fd);
    $display("FFT64 spectrum CSV: %0s", csv_file);

    $display("FFT64 static-BFP8 spectrum: Ein=%0d, Eout=%0d, value_scale=%0d/%0d",
             input_bfp_exponent, scan_exponent_integer,
             value_scale_numerator, value_scale_denominator);
    $display("PASS fft64_vsp_vcs_tb: %0d checks, %0d actions, %0d cycles, %0d I-cache misses, %0d D-cache read misses, %0d RAM beats",
             checks, completed_actions, workload_cycles, icache_misses,
             dcache_read_misses, lower_req_count_o);
`ifdef FFT64_VCS_WAVE
    $vcdplusoff;
`endif
    $finish;
  end
endmodule
