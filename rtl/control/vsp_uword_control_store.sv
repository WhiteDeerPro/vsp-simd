module vsp_uword_control_store #(
  parameter int PC_W = 32,
  parameter int STORE_WORDS = 64,
  parameter logic [PC_W-1:0] STORE_BASE_PC = '0,
  parameter int BUNDLE_WORDS = 4,
  parameter int BUNDLE_COUNT_W = (BUNDLE_WORDS < 2) ? 1 :
                                 $clog2(BUNDLE_WORDS + 1)
) (
  input  logic                                      clk_i,
  input  logic                                      rst_ni,

  // Full-word programming port. The behavioral array is intentionally not
  // reset, matching a ROM/SRAM-like control-store data lifetime.
  input  logic                                      write_valid_i,
  output logic                                      write_ready_o,
  input  logic [PC_W-1:0]                           write_pc_i,
  input  logic [vsp_uword_pkg::VSP_UWORD_W-1:0]    write_data_i,

  input  logic                                      req_valid_i,
  output logic                                      req_ready_o,
  input  logic [PC_W-1:0]                           req_pc_i,
  input  logic [BUNDLE_COUNT_W-1:0]                 req_word_count_i,

  output logic                                      rsp_valid_o,
  input  logic                                      rsp_ready_i,
  output logic [(BUNDLE_WORDS*vsp_uword_pkg::VSP_UWORD_W)-1:0]
                                                     rsp_words_o,
  output logic                                      rsp_fault_o,

  input  logic                                      protocol_error_clear_i,
  output logic                                      protocol_error_o
);
  import vsp_uword_pkg::*;

  localparam int STORE_INDEX_W = (STORE_WORDS <= 2) ? 1 :
                                 $clog2(STORE_WORDS);

  logic [VSP_UWORD_W-1:0] store_q [STORE_WORDS];
  logic rsp_valid_q;
  logic [(BUNDLE_WORDS*VSP_UWORD_W)-1:0] rsp_words_q;
  logic rsp_fault_q;
  logic protocol_error_q;

  logic write_fire;
  logic write_address_ok;
  logic request_ok;
  logic [STORE_INDEX_W-1:0] write_index;
  logic [STORE_INDEX_W-1:0] request_index;
  integer request_words;
  integer read_index;

  function automatic logic pc_range_in_window(
      input logic [PC_W-1:0] pc,
      input integer word_count);
    logic [PC_W:0] byte_delta;
    logic [PC_W:0] first_word;
    logic [PC_W:0] final_word;
    logic count_ok;
    begin
      byte_delta = {1'b0, pc} - {1'b0, STORE_BASE_PC};
      first_word = byte_delta >> 2;
      final_word = first_word + (PC_W+1)'(word_count);
      count_ok = (word_count > 0) && (word_count <= STORE_WORDS);
      pc_range_in_window = (pc[1:0] == 2'b00) &&
                           !byte_delta[PC_W] &&
                           count_ok &&
                           (final_word <= (PC_W+1)'(STORE_WORDS));
    end
  endfunction

  assign write_ready_o = rst_ni && !rsp_valid_q && !req_valid_i;
  // A fetch request wins a same-cycle programming collision. This avoids a
  // mutual-ready deadlock if two independent clients hold both valids high;
  // the integrated frontend normally prevents the collision altogether.
  assign req_ready_o = rst_ni && (!rsp_valid_q || rsp_ready_i);
  assign write_fire = write_valid_i && write_ready_o;

  assign write_address_ok = pc_range_in_window(write_pc_i, 1);
  assign request_words = int'(req_word_count_i);
  assign request_ok = (request_words > 0) &&
                      (request_words <= BUNDLE_WORDS) &&
                      pc_range_in_window(req_pc_i, request_words);
  assign write_index = STORE_INDEX_W'(
      ($unsigned(write_pc_i) - $unsigned(STORE_BASE_PC)) >> 2);
  assign request_index = STORE_INDEX_W'(
      ($unsigned(req_pc_i) - $unsigned(STORE_BASE_PC)) >> 2);

  assign rsp_valid_o = rsp_valid_q;
  assign rsp_words_o = rsp_words_q;
  assign rsp_fault_o = rsp_fault_q;
  assign protocol_error_o = protocol_error_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_valid_q <= 1'b0;
      rsp_words_q <= '0;
      rsp_fault_q <= 1'b0;
      protocol_error_q <= 1'b0;
    end else begin
      if (protocol_error_clear_i)
        protocol_error_q <= 1'b0;

      if (write_fire) begin
        if (write_address_ok)
          store_q[write_index] <= write_data_i;
        else
          protocol_error_q <= 1'b1;
      end

      if (req_ready_o) begin
        rsp_valid_q <= req_valid_i;
        if (req_valid_i) begin
          rsp_words_q <= '0;
          rsp_fault_q <= !request_ok;
          if (request_ok) begin
            for (read_index = 0; read_index < BUNDLE_WORDS;
                 read_index = read_index + 1) begin
              if (read_index < request_words)
                rsp_words_q[(read_index*VSP_UWORD_W) +: VSP_UWORD_W] <=
                    store_q[int'(request_index) + read_index];
            end
          end
        end else begin
          rsp_words_q <= '0;
          rsp_fault_q <= 1'b0;
        end
      end
    end
  end

  initial begin
    if (PC_W < 3)
      $error("PC_W must hold a byte-aligned word address");
    if (STORE_WORDS <= 0)
      $error("STORE_WORDS must be positive");
    if (STORE_BASE_PC[1:0] != 2'b00)
      $error("STORE_BASE_PC must be four-byte aligned");
    if (BUNDLE_WORDS <= 0)
      $error("BUNDLE_WORDS must be positive");
    if ((2**BUNDLE_COUNT_W) <= BUNDLE_WORDS)
      $error("BUNDLE_COUNT_W cannot represent BUNDLE_WORDS");
  end
endmodule
