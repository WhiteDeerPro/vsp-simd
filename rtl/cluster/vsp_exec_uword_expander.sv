module vsp_exec_uword_expander #(
  parameter int VREGS = 16,
  parameter int AREGS = 8,
  parameter int MREGS = 4
) (
  input  logic                                      base_valid_i,
  input  logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_W-1:0]
                                                     base_word_i,
  // extension_valid_i describes an extension associated with this base word,
  // not an unrelated next stream word.  The packet collector that establishes
  // that association remains outside this combinational expander.
  input  logic                                      extension_valid_i,
  input  logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_W-1:0]
                                                     extension_word_i,

  output logic                                      extension_required_o,
  output logic                                      out_valid_o,
  output logic                                      legal_o,
  output logic [vsp_exec_uword_pkg::VSP_EXEC_UWORD_ERROR_W-1:0]
                                                     error_cause_o,

  // Canonical EXEC controls for the current 16/8/4-row SIMD4 profile.
  output logic [simd_pkg::SIMD_OP_W-1:0]           op_o,
  output logic [simd_pkg::ELEM_MODE_W-1:0]         elem_mode_o,
  output logic [3:0]                                src_a_addr_o,
  output logic [3:0]                                src_b_addr_o,
  output logic                                      use_imm_o,
  output logic [31:0]                               imm_o,
  output logic [3:0]                                dst_vrf_addr_o,
  output logic [2:0]                                src_arf_addr_o,
  output logic [2:0]                                dst_arf_addr_o,
  output logic                                      mask_enable_o,
  output logic [1:0]                                mask_addr_o,
  output logic [1:0]                                select_mask_addr_o,
  output logic [1:0]                                dst_mrf_addr_o,
  output logic                                      write_vrf_o,
  output logic                                      write_arf_o,
  output logic                                      write_mrf_o,
  output logic                                      reduce_enable_o,
  output logic [simd_pkg::REDUCE_OP_W-1:0]         reduce_op_o,
  output logic                                      export_narrow_o,

  // Format D is a register-indexed vector route.  The source and index VRF
  // addresses use the ordinary A/B fields.  These legacy local-route control
  // outputs remain in the canonical bundle for interface compatibility, but
  // a legal Format-D word always drives GATHER. Bits 27:26 preserve the
  // route-wave mode.  LOCAL (00) is self-contained; dependent modes retain
  // their OUT/IN roles for a future peer-aware admission stage.  Other
  // immediate controls remain zero.
  output logic                                      route_enable_o,
  output logic [vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W-1:0]
                                                     route_io_mode_o,
  output logic [simd_pkg::ROUTE_OP_W-1:0]          route_op_o,
  output logic [7:0]                                route_index_o,
  output logic [1:0]                                route_broadcast_index_o,
  output logic [2:0]                                route_slide_amount_o,
  output logic [31:0]                               route_lower_o,
  output logic [31:0]                               route_upper_o,

  output logic                                      requires_result_o,
  output logic                                      result_has_narrow_o,
  output logic                                      result_has_reduce_o,
  output logic                                      result_has_count_o
);
  import simd_pkg::*;
  import vsp_exec_uword_pkg::*;

  localparam logic [1:0] IMM_KIND_NONE    = 2'd0;
  localparam logic [1:0] IMM_KIND_ELEMENT = 2'd1;
  localparam logic [1:0] IMM_KIND_SHIFT   = 2'd2;

  logic [VSP_EXEC_UWORD_FORMAT_W-1:0] format;
  logic format_ok;
  logic subop_ok;
  logic reserved_ok;
  logic unused_ok;
  logic address_ok;
  logic mask_ok;
  logic reduce_sel_ok;
  logic immediate_ok;
  logic export_ok;
  logic extension_required_raw;
  logic extension_ok;
  logic mask_selector_present;
  logic [2:0] mask_sel;
  logic [2:0] reduce_sel;
  logic [1:0] immediate_kind;
  logic raw_reads_vrf_a;
  logic raw_reads_vrf_b;
  logic raw_reads_arf;
  logic raw_reads_mrf_a;
  logic raw_reads_mrf_b;

  logic [SIMD_OP_W-1:0] raw_op;
  logic [ELEM_MODE_W-1:0] raw_elem_mode;
  logic [3:0] raw_src_a_addr;
  logic [3:0] raw_src_b_addr;
  logic raw_use_imm;
  logic [31:0] raw_imm;
  logic [3:0] raw_dst_vrf_addr;
  logic [2:0] raw_src_arf_addr;
  logic [2:0] raw_dst_arf_addr;
  logic raw_mask_enable;
  logic [1:0] raw_mask_addr;
  logic [1:0] raw_select_mask_addr;
  logic [1:0] raw_dst_mrf_addr;
  logic raw_write_vrf;
  logic raw_write_arf;
  logic raw_write_mrf;
  logic raw_reduce_enable;
  logic [REDUCE_OP_W-1:0] raw_reduce_op;
  logic raw_export_narrow;
  logic raw_route_enable;
  logic [VSP_EXEC_ROUTE_IO_W-1:0] raw_route_io_mode;
  logic [ROUTE_OP_W-1:0] raw_route_op;
  logic [7:0] raw_route_index;
  logic [1:0] raw_route_broadcast_index;
  logic [2:0] raw_route_slide_amount;
  logic [31:0] raw_route_lower;
  logic [31:0] raw_route_upper;

  logic mode_legal;
  logic writeback_legal;
  logic reduce_legal;
  logic route_legal_unused;
  logic uop_legal_unused;
  logic decode_error;
  logic [VSP_EXEC_UWORD_ERROR_W-1:0] selected_error;

  assign format = base_word_i[31:28];

  // Format parsing produces a canonical candidate and orthogonal diagnostic
  // predicates.  The candidate is exposed only when every predicate succeeds;
  // malformed words therefore cannot leak writeback or result obligations.
  always_comb begin
    format_ok = vsp_exec_uword_format_defined(format);
    subop_ok = 1'b1;
    reserved_ok = 1'b1;
    unused_ok = 1'b1;
    address_ok = 1'b1;
    mask_selector_present = 1'b0;
    mask_sel = VSP_EXEC_MASK_NONE;
    reduce_sel = VSP_EXEC_REDUCE_NONE;
    extension_required_raw =
        vsp_exec_uword_extension_required(base_word_i);
    immediate_kind = IMM_KIND_NONE;
    raw_reads_vrf_a = 1'b0;
    raw_reads_vrf_b = 1'b0;
    raw_reads_arf = 1'b0;
    raw_reads_mrf_a = 1'b0;
    raw_reads_mrf_b = 1'b0;

    raw_op = SIMD_OP_ADD;
    raw_elem_mode = ELEM_MODE_BYTE;
    raw_src_a_addr = '0;
    raw_src_b_addr = '0;
    raw_use_imm = 1'b0;
    raw_imm = '0;
    raw_dst_vrf_addr = '0;
    raw_src_arf_addr = '0;
    raw_dst_arf_addr = '0;
    raw_mask_enable = 1'b0;
    raw_mask_addr = '0;
    raw_select_mask_addr = '0;
    raw_dst_mrf_addr = '0;
    raw_write_vrf = 1'b0;
    raw_write_arf = 1'b0;
    raw_write_mrf = 1'b0;
    raw_reduce_enable = 1'b0;
    raw_reduce_op = REDUCE_OP_SUM_U;
    raw_export_narrow = 1'b0;
    raw_route_enable = 1'b0;
    raw_route_io_mode = VSP_EXEC_ROUTE_IO_LOCAL;
    raw_route_op = ROUTE_OP_GATHER;
    raw_route_index = '0;
    raw_route_broadcast_index = '0;
    raw_route_slide_amount = '0;
    raw_route_lower = '0;
    raw_route_upper = '0;

    unique case (format)
      VSP_EXEC_UWORD_FMT_ALU: begin
        unique case (base_word_i[27:23])
          VSP_EXEC_ALU_ADD:       raw_op = SIMD_OP_ADD;
          VSP_EXEC_ALU_SUB:       raw_op = SIMD_OP_SUB;
          VSP_EXEC_ALU_ADD_SAT_U: raw_op = SIMD_OP_ADD_SAT_U;
          VSP_EXEC_ALU_SUB_SAT_U: raw_op = SIMD_OP_SUB_SAT_U;
          VSP_EXEC_ALU_ADD_SAT_S: raw_op = SIMD_OP_ADD_SAT_S;
          VSP_EXEC_ALU_SUB_SAT_S: raw_op = SIMD_OP_SUB_SAT_S;
          VSP_EXEC_ALU_MIN_U:     raw_op = SIMD_OP_MIN_U;
          VSP_EXEC_ALU_MAX_U:     raw_op = SIMD_OP_MAX_U;
          VSP_EXEC_ALU_MIN_S:     raw_op = SIMD_OP_MIN_S;
          VSP_EXEC_ALU_MAX_S:     raw_op = SIMD_OP_MAX_S;
          VSP_EXEC_ALU_ABSDIFF_U: raw_op = SIMD_OP_ABSDIFF_U;
          VSP_EXEC_ALU_AVG_U:     raw_op = SIMD_OP_AVG_U;
          VSP_EXEC_ALU_AVG_S:     raw_op = SIMD_OP_AVG_S;
          VSP_EXEC_ALU_AND:       raw_op = SIMD_OP_AND;
          VSP_EXEC_ALU_OR:        raw_op = SIMD_OP_OR;
          VSP_EXEC_ALU_XOR:       raw_op = SIMD_OP_XOR;
          VSP_EXEC_ALU_SHL:       raw_op = SIMD_OP_SHL;
          VSP_EXEC_ALU_SHR_U:     raw_op = SIMD_OP_SHR_U;
          VSP_EXEC_ALU_SHR_S:     raw_op = SIMD_OP_SHR_S;
          VSP_EXEC_ALU_ABS_SAT_S: raw_op = SIMD_OP_ABS_SAT_S;
          VSP_EXEC_ALU_PASS_A:    raw_op = SIMD_OP_PASS_A;
          default: subop_ok = 1'b0;
        endcase
        raw_elem_mode = base_word_i[22:21];
        raw_reads_vrf_a = 1'b1;
        raw_reads_vrf_b = 1'b1;
        raw_src_a_addr = base_word_i[20:17];
        raw_src_b_addr = base_word_i[16:13];
        raw_dst_vrf_addr = base_word_i[12:9];
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[8:6];
        raw_use_imm = extension_required_raw;
        raw_write_vrf = base_word_i[4];
        raw_export_narrow = base_word_i[3];
        reduce_sel = base_word_i[2:0];
        immediate_kind = extension_required_raw ? IMM_KIND_ELEMENT :
                                                   IMM_KIND_NONE;
        if (extension_required_raw) begin
          raw_reads_vrf_b = 1'b0;
          unused_ok = unused_ok && (base_word_i[16:13] == 4'h0);
          raw_src_b_addr = '0;
        end
        if ((base_word_i[27:23] == VSP_EXEC_ALU_ABS_SAT_S) ||
            (base_word_i[27:23] == VSP_EXEC_ALU_PASS_A)) begin
          raw_reads_vrf_b = 1'b0;
          unused_ok = unused_ok && !base_word_i[5] &&
                      (base_word_i[16:13] == 4'h0);
          raw_src_b_addr = '0;
        end
        unused_ok = unused_ok &&
                    (raw_write_vrf || (base_word_i[12:9] == 4'h0));
      end

      VSP_EXEC_UWORD_FMT_CMP: begin
        unique case (base_word_i[27:26])
          VSP_EXEC_CMP_EQ:   raw_op = SIMD_OP_CMPEQ;
          VSP_EXEC_CMP_GT_U: raw_op = SIMD_OP_CMPGT_U;
          VSP_EXEC_CMP_GT_S: raw_op = SIMD_OP_CMPGT_S;
          default: subop_ok = 1'b0;
        endcase
        raw_elem_mode = base_word_i[25:24];
        raw_reads_vrf_a = 1'b1;
        raw_reads_vrf_b = 1'b1;
        raw_src_a_addr = base_word_i[23:20];
        raw_src_b_addr = base_word_i[19:16];
        raw_dst_vrf_addr = base_word_i[15:12];
        raw_dst_mrf_addr = base_word_i[11:10];
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[9:7];
        raw_use_imm = extension_required_raw;
        raw_write_vrf = base_word_i[5];
        raw_write_mrf = base_word_i[4];
        raw_export_narrow = base_word_i[3];
        immediate_kind = extension_required_raw ? IMM_KIND_ELEMENT :
                                                   IMM_KIND_NONE;
        reserved_ok = base_word_i[2:0] == 3'h0;
        if (extension_required_raw) begin
          raw_reads_vrf_b = 1'b0;
          unused_ok = unused_ok && (base_word_i[19:16] == 4'h0);
          raw_src_b_addr = '0;
        end
        unused_ok = unused_ok &&
                    (raw_write_vrf || (base_word_i[15:12] == 4'h0)) &&
                    (raw_write_mrf || (base_word_i[11:10] == 2'h0));
      end

      VSP_EXEC_UWORD_FMT_SELECT: begin
        raw_op = SIMD_OP_SELECT;
        raw_reads_vrf_a = 1'b1;
        raw_reads_vrf_b = 1'b1;
        raw_reads_mrf_b = 1'b1;
        raw_elem_mode = base_word_i[27:26];
        raw_src_a_addr = base_word_i[25:22];
        raw_src_b_addr = base_word_i[21:18];
        raw_dst_vrf_addr = base_word_i[17:14];
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[13:11];
        raw_select_mask_addr = base_word_i[10:9];
        raw_use_imm = extension_required_raw;
        raw_write_vrf = base_word_i[7];
        raw_export_narrow = base_word_i[6];
        reduce_sel = base_word_i[5:3];
        immediate_kind = extension_required_raw ? IMM_KIND_ELEMENT :
                                                   IMM_KIND_NONE;
        reserved_ok = base_word_i[2:0] == 3'h0;
        if (extension_required_raw) begin
          raw_reads_vrf_b = 1'b0;
          unused_ok = unused_ok && (base_word_i[21:18] == 4'h0);
          raw_src_b_addr = '0;
        end
        unused_ok = unused_ok &&
                    (raw_write_vrf || (base_word_i[17:14] == 4'h0));
      end

      VSP_EXEC_UWORD_FMT_MUL: begin
        raw_op = base_word_i[27] ? SIMD_OP_MUL_S : SIMD_OP_MUL_U;
        raw_reads_vrf_a = 1'b1;
        raw_reads_vrf_b = 1'b1;
        raw_src_a_addr = base_word_i[26:23];
        raw_src_b_addr = base_word_i[22:19];
        raw_dst_vrf_addr = base_word_i[18:15];
        raw_dst_arf_addr = base_word_i[14:12];
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[11:9];
        raw_use_imm = extension_required_raw;
        raw_write_vrf = base_word_i[7];
        raw_write_arf = base_word_i[6];
        raw_export_narrow = base_word_i[5];
        reduce_sel = base_word_i[4:2];
        immediate_kind = extension_required_raw ? IMM_KIND_ELEMENT :
                                                   IMM_KIND_NONE;
        reserved_ok = base_word_i[1:0] == 2'h0;
        if (extension_required_raw) begin
          raw_reads_vrf_b = 1'b0;
          unused_ok = unused_ok && (base_word_i[22:19] == 4'h0);
          raw_src_b_addr = '0;
        end
        unused_ok = unused_ok &&
                    (raw_write_vrf || (base_word_i[18:15] == 4'h0)) &&
                    (raw_write_arf || (base_word_i[14:12] == 3'h0));
      end

      VSP_EXEC_UWORD_FMT_MAC_RR,
      VSP_EXEC_UWORD_FMT_MAC_RI: begin
        raw_op = base_word_i[27] ? SIMD_OP_MAC_S : SIMD_OP_MAC_U;
        raw_reads_vrf_a = 1'b1;
        raw_reads_vrf_b = 1'b1;
        raw_reads_arf = 1'b1;
        raw_src_a_addr = base_word_i[26:23];
        raw_src_b_addr = base_word_i[22:19];
        raw_src_arf_addr = base_word_i[18:16];
        raw_dst_arf_addr = base_word_i[15:13];
        raw_dst_vrf_addr = base_word_i[12:9];
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[8:6];
        raw_write_vrf = base_word_i[5];
        raw_write_arf = base_word_i[4];
        raw_export_narrow = base_word_i[3];
        reduce_sel = base_word_i[2:0];
        raw_use_imm = extension_required_raw;
        immediate_kind = extension_required_raw ? IMM_KIND_ELEMENT :
                                                   IMM_KIND_NONE;
        if (extension_required_raw) begin
          raw_reads_vrf_b = 1'b0;
          unused_ok = unused_ok && (base_word_i[22:19] == 4'h0);
          raw_src_b_addr = '0;
        end
        unused_ok = unused_ok &&
                    (raw_write_vrf || (base_word_i[12:9] == 4'h0)) &&
                    (raw_write_arf || (base_word_i[15:13] == 3'h0));
      end

      VSP_EXEC_UWORD_FMT_WIDE_CONVERT: begin
        unique case (base_word_i[27:25])
          VSP_EXEC_WIDE_WIDEN_U: begin
            raw_op = SIMD_OP_WIDEN_U;
            raw_reads_vrf_a = 1'b1;
            raw_src_a_addr = base_word_i[24:21];
            raw_dst_arf_addr = base_word_i[15:13];
            raw_write_arf = base_word_i[8];
            address_ok = !base_word_i[16];
          end
          VSP_EXEC_WIDE_WIDEN_S: begin
            raw_op = SIMD_OP_WIDEN_S;
            raw_reads_vrf_a = 1'b1;
            raw_src_a_addr = base_word_i[24:21];
            raw_dst_arf_addr = base_word_i[15:13];
            raw_write_arf = base_word_i[8];
            address_ok = !base_word_i[16];
          end
          VSP_EXEC_WIDE_RSHIFT_U: begin
            raw_op = SIMD_OP_RSHIFT_RND_U;
            raw_reads_arf = 1'b1;
            raw_src_arf_addr = base_word_i[23:21];
            raw_dst_arf_addr = base_word_i[15:13];
            raw_write_arf = base_word_i[8];
            address_ok = !base_word_i[24] && !base_word_i[16];
          end
          VSP_EXEC_WIDE_RSHIFT_S: begin
            raw_op = SIMD_OP_RSHIFT_RND_S;
            raw_reads_arf = 1'b1;
            raw_src_arf_addr = base_word_i[23:21];
            raw_dst_arf_addr = base_word_i[15:13];
            raw_write_arf = base_word_i[8];
            address_ok = !base_word_i[24] && !base_word_i[16];
          end
          VSP_EXEC_WIDE_NCLIP_U: begin
            raw_op = SIMD_OP_NCLIP_U;
            raw_reads_arf = 1'b1;
            raw_src_arf_addr = base_word_i[23:21];
            raw_dst_vrf_addr = base_word_i[16:13];
            raw_write_vrf = base_word_i[8];
            address_ok = !base_word_i[24];
          end
          VSP_EXEC_WIDE_NCLIP_S: begin
            raw_op = SIMD_OP_NCLIP_S;
            raw_reads_arf = 1'b1;
            raw_src_arf_addr = base_word_i[23:21];
            raw_dst_vrf_addr = base_word_i[16:13];
            raw_write_vrf = base_word_i[8];
            address_ok = !base_word_i[24];
          end
          VSP_EXEC_WIDE_NSLICE: begin
            raw_op = SIMD_OP_NSLICE;
            raw_reads_arf = 1'b1;
            raw_src_arf_addr = base_word_i[23:21];
            raw_dst_vrf_addr = base_word_i[16:13];
            raw_write_vrf = base_word_i[8];
            address_ok = !base_word_i[24];
          end
          default: subop_ok = 1'b0;
        endcase
        raw_src_b_addr = base_word_i[20:17];
        raw_reads_vrf_b = 1'b1;
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[12:10];
        raw_use_imm = extension_required_raw;
        raw_export_narrow = base_word_i[7];
        reduce_sel = base_word_i[6:4];
        immediate_kind = extension_required_raw ? IMM_KIND_SHIFT :
                                                   IMM_KIND_NONE;
        reserved_ok = base_word_i[3:0] == 4'h0;
        if (extension_required_raw) begin
          raw_reads_vrf_b = 1'b0;
          unused_ok = unused_ok && (base_word_i[20:17] == 4'h0);
          raw_src_b_addr = '0;
        end
        unused_ok = unused_ok &&
                    (base_word_i[8] || (base_word_i[16:13] == 4'h0));
      end

      VSP_EXEC_UWORD_FMT_WADD_WSUB: begin
        unique case (base_word_i[27:26])
          VSP_EXEC_WADD_U: raw_op = SIMD_OP_WADD_U;
          VSP_EXEC_WADD_S: raw_op = SIMD_OP_WADD_S;
          VSP_EXEC_WSUB_U: raw_op = SIMD_OP_WSUB_U;
          VSP_EXEC_WSUB_S: raw_op = SIMD_OP_WSUB_S;
          default: subop_ok = 1'b0;
        endcase
        raw_src_a_addr = base_word_i[25:22];
        raw_src_b_addr = base_word_i[21:18];
        raw_src_arf_addr = base_word_i[17:15];
        raw_reads_vrf_a = 1'b1;
        raw_reads_vrf_b = 1'b1;
        raw_reads_arf = 1'b1;
        raw_dst_arf_addr = base_word_i[14:12];
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[11:9];
        raw_use_imm = 1'b1;
        raw_imm[4:0] = base_word_i[8:4];
        raw_write_arf = base_word_i[3];
        reserved_ok = base_word_i[2:0] == 3'h0;
        unused_ok = unused_ok &&
                    (raw_write_arf || (base_word_i[14:12] == 3'h0));
      end

      VSP_EXEC_UWORD_FMT_COMPACT: begin
        raw_op = base_word_i[27] ? SIMD_OP_EXPAND : SIMD_OP_COMPRESS;
        raw_reads_vrf_a = 1'b1;
        raw_elem_mode = base_word_i[26:25];
        raw_src_a_addr = base_word_i[24:21];
        raw_dst_vrf_addr = base_word_i[20:17];
        mask_selector_present = 1'b1;
        mask_sel = base_word_i[16:14];
        raw_dst_mrf_addr = base_word_i[13:12];
        raw_write_vrf = base_word_i[11];
        raw_write_mrf = base_word_i[10];
        raw_export_narrow = base_word_i[9];
        reduce_sel = base_word_i[8:6];
        reserved_ok = base_word_i[5:0] == 6'h0;
        unused_ok = unused_ok &&
                    (raw_write_vrf || (base_word_i[20:17] == 4'h0)) &&
                    (raw_write_mrf || (base_word_i[13:12] == 2'h0));
      end

      VSP_EXEC_UWORD_FMT_MRF_LOGIC: begin
        unique case (base_word_i[27:26])
          VSP_EXEC_MRF_AND: raw_op = SIMD_OP_MAND;
          VSP_EXEC_MRF_OR:  raw_op = SIMD_OP_MOR;
          VSP_EXEC_MRF_XOR: raw_op = SIMD_OP_MXOR;
          VSP_EXEC_MRF_NOT: raw_op = SIMD_OP_MNOT;
          default: subop_ok = 1'b0;
        endcase
        // MRF boolean operations reuse the two physical MRF read ports as
        // data inputs.  mask_enable remains clear because ma is not an
        // execution predicate in this format.
        raw_mask_addr = base_word_i[25:24];
        raw_select_mask_addr = base_word_i[23:22];
        raw_reads_mrf_a = 1'b1;
        raw_reads_mrf_b = 1'b1;
        raw_dst_mrf_addr = base_word_i[21:20];
        raw_dst_vrf_addr = base_word_i[19:16];
        raw_write_mrf = base_word_i[15];
        raw_write_vrf = base_word_i[14];
        raw_export_narrow = base_word_i[13];
        reserved_ok = base_word_i[12:0] == 13'h0;
        if (base_word_i[27:26] == VSP_EXEC_MRF_NOT) begin
          raw_reads_mrf_b = 1'b0;
          unused_ok = unused_ok && (base_word_i[23:22] == 2'h0);
          raw_select_mask_addr = '0;
        end
        unused_ok = unused_ok &&
                    (raw_write_mrf || (base_word_i[21:20] == 2'h0)) &&
                    (raw_write_vrf || (base_word_i[19:16] == 4'h0));
      end

      VSP_EXEC_UWORD_FMT_ROUTE: begin
        // A route word names source-data, index and destination VRF rows.  It
        // remains an EXEC-class byte-mode PASS_A action, but the route map is
        // read from VRF-B rather than embedded in the word.  Broadcast and
        // slide are expressed by constructing the corresponding index row.
        raw_op = SIMD_OP_PASS_A;
        raw_elem_mode = ELEM_MODE_BYTE;
        // LOCAL consumes both operands and writes vd.  For a dependent
        // fragment bit 1 publishes the source and bit 0 consumes the index
        // and destination.  Partial fragments never execute separately.
        raw_reads_vrf_a = (base_word_i[27:26] == 2'b00) ||
                          base_word_i[27];
        raw_reads_vrf_b = (base_word_i[27:26] == 2'b00) ||
                          base_word_i[26];
        raw_src_a_addr = raw_reads_vrf_a ? base_word_i[25:22] : 4'h0;
        raw_src_b_addr = raw_reads_vrf_b ? base_word_i[9:6] : 4'h0;
        raw_dst_vrf_addr = raw_reads_vrf_b ? base_word_i[21:18] : 4'h0;
        raw_write_vrf = raw_reads_vrf_b;
        raw_route_enable = 1'b1;
        raw_route_io_mode = base_word_i[27:26];
        raw_route_op = ROUTE_OP_GATHER;
        reserved_ok = (base_word_i[17:10] == 8'h00) &&
                      (base_word_i[5:0] == 6'h00);
      end

      default: begin
        // Safe defaults above form the canonical candidate for a bad format.
      end
    endcase

    if (mask_selector_present && vsp_exec_mask_sel_defined(mask_sel)) begin
      raw_mask_enable = mask_sel != VSP_EXEC_MASK_NONE;
      raw_mask_addr = raw_mask_enable ? (mask_sel[1:0] - 2'd1) : 2'h0;
      raw_reads_mrf_a = raw_mask_enable;
    end

    if (vsp_exec_reduce_sel_defined(reduce_sel)) begin
      raw_reduce_enable = reduce_sel != VSP_EXEC_REDUCE_NONE;
      raw_reduce_op = raw_reduce_enable ? (reduce_sel - 3'd1) :
                                          REDUCE_OP_SUM_U;
    end else begin
      raw_reduce_enable = 1'b1;
      raw_reduce_op = reduce_sel - 3'd1;
    end

    if (extension_required_raw && extension_valid_i)
      raw_imm = extension_word_i;

    address_ok = address_ok &&
        (!raw_reads_vrf_a || (int'(raw_src_a_addr) < VREGS)) &&
        (!raw_reads_vrf_b || (int'(raw_src_b_addr) < VREGS)) &&
        (!raw_write_vrf || (int'(raw_dst_vrf_addr) < VREGS)) &&
        (!raw_reads_arf || (int'(raw_src_arf_addr) < AREGS)) &&
        (!raw_write_arf || (int'(raw_dst_arf_addr) < AREGS)) &&
        (!raw_reads_mrf_a || (int'(raw_mask_addr) < MREGS)) &&
        (!raw_reads_mrf_b || (int'(raw_select_mask_addr) < MREGS)) &&
        (!raw_write_mrf || (int'(raw_dst_mrf_addr) < MREGS));
  end

  assign mask_ok = !mask_selector_present ||
                   vsp_exec_mask_sel_defined(mask_sel);
  assign reduce_sel_ok = vsp_exec_reduce_sel_defined(reduce_sel);
  assign extension_ok = extension_valid_i == extension_required_raw;

  always_comb begin
    immediate_ok = 1'b1;
    if (extension_required_raw && extension_valid_i) begin
      unique case (immediate_kind)
        IMM_KIND_ELEMENT: begin
          unique case (raw_elem_mode)
            ELEM_MODE_BYTE:
              immediate_ok = extension_word_i[31:8] == 24'h0;
            ELEM_MODE_HALF:
              immediate_ok = extension_word_i[31:16] == 16'h0;
            ELEM_MODE_WORD:
              immediate_ok = 1'b1;
            default:
              // Let the dedicated mode diagnostic win for an undefined mode.
              immediate_ok = 1'b1;
          endcase
        end
        IMM_KIND_SHIFT:
          immediate_ok = extension_word_i[31:5] == 27'h0;
        default:
          immediate_ok = 1'b1;
      endcase
    end
  end

  simd_uop_legal u_uop_legal (
    .op_i(raw_op),
    .elem_mode_i(raw_elem_mode),
    .write_vrf_i(raw_write_vrf),
    .write_arf_i(raw_write_arf),
    .write_mrf_i(raw_write_mrf),
    .reduce_enable_i(raw_reduce_enable),
    .route_enable_i(raw_route_enable),
    .mode_legal_o(mode_legal),
    .writeback_legal_o(writeback_legal),
    .reduce_legal_o(reduce_legal),
    .route_legal_o(route_legal_unused),
    .legal_o(uop_legal_unused)
  );

  assign export_ok = !raw_export_narrow || simd_op_can_write_vrf(raw_op);

  // Decoder diagnostics use a stable priority so malformed words have one
  // deterministic ordered completion cause.  NO_EFFECT is intentionally not
  // generated in v0: a canonical operation with only a normal completion
  // remains legal, matching the existing decoded EXEC boundary.
  always_comb begin
    selected_error = VSP_EXEC_UWORD_ERROR_NONE;
    if (!format_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_BAD_FORMAT;
    else if (!subop_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_BAD_SUBOP;
    else if (!reserved_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_RESERVED_BITS;
    else if (!extension_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_EXTENSION;
    else if (!immediate_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_IMMEDIATE;
    else if (!mask_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_MASK;
    else if (!reduce_sel_ok || !reduce_legal)
      selected_error = VSP_EXEC_UWORD_ERROR_REDUCTION;
    else if (!mode_legal)
      selected_error = VSP_EXEC_UWORD_ERROR_MODE;
    else if (!writeback_legal || !export_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_WRITEBACK_OR_EXPORT;
    else if (!address_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_ADDRESS;
    else if (!unused_ok)
      selected_error = VSP_EXEC_UWORD_ERROR_UNUSED_FIELD;
  end

  assign decode_error = selected_error != VSP_EXEC_UWORD_ERROR_NONE;

  always_comb begin
    extension_required_o = base_valid_i && extension_required_raw;
    // The input is an already-collected packet.  extension_valid_i therefore
    // means "this entry contains an extension", not "an extension may arrive
    // later".  A missing required word is emitted as one ordered illegal
    // record instead of stalling this stateless expander forever.
    out_valid_o = base_valid_i;
    legal_o = out_valid_o && !decode_error;
    error_cause_o = base_valid_i ? selected_error :
                                   VSP_EXEC_UWORD_ERROR_NONE;

    op_o = '0;
    elem_mode_o = '0;
    src_a_addr_o = '0;
    src_b_addr_o = '0;
    use_imm_o = 1'b0;
    imm_o = '0;
    dst_vrf_addr_o = '0;
    src_arf_addr_o = '0;
    dst_arf_addr_o = '0;
    mask_enable_o = 1'b0;
    mask_addr_o = '0;
    select_mask_addr_o = '0;
    dst_mrf_addr_o = '0;
    write_vrf_o = 1'b0;
    write_arf_o = 1'b0;
    write_mrf_o = 1'b0;
    reduce_enable_o = 1'b0;
    reduce_op_o = '0;
    export_narrow_o = 1'b0;

    route_enable_o = 1'b0;
    route_io_mode_o = VSP_EXEC_ROUTE_IO_LOCAL;
    route_op_o = '0;
    route_index_o = '0;
    route_broadcast_index_o = '0;
    route_slide_amount_o = '0;
    route_lower_o = '0;
    route_upper_o = '0;

    requires_result_o = 1'b0;
    result_has_narrow_o = 1'b0;
    result_has_reduce_o = 1'b0;
    result_has_count_o = 1'b0;

    if (legal_o) begin
      op_o = raw_op;
      elem_mode_o = raw_elem_mode;
      src_a_addr_o = raw_src_a_addr;
      src_b_addr_o = raw_src_b_addr;
      use_imm_o = raw_use_imm;
      imm_o = raw_use_imm ? raw_imm : 32'h0;
      dst_vrf_addr_o = raw_write_vrf ? raw_dst_vrf_addr : 4'h0;
      src_arf_addr_o = raw_src_arf_addr;
      dst_arf_addr_o = raw_write_arf ? raw_dst_arf_addr : 3'h0;
      mask_enable_o = raw_mask_enable;
      mask_addr_o = raw_mask_addr;
      select_mask_addr_o = raw_select_mask_addr;
      dst_mrf_addr_o = raw_write_mrf ? raw_dst_mrf_addr : 2'h0;
      write_vrf_o = raw_write_vrf;
      write_arf_o = raw_write_arf;
      write_mrf_o = raw_write_mrf;
      reduce_enable_o = raw_reduce_enable;
      reduce_op_o = raw_reduce_enable ? raw_reduce_op : REDUCE_OP_SUM_U;
      export_narrow_o = raw_export_narrow;

      route_enable_o = raw_route_enable;
      route_io_mode_o = raw_route_enable ? raw_route_io_mode :
                                            VSP_EXEC_ROUTE_IO_LOCAL;
      route_op_o = raw_route_enable ? raw_route_op : ROUTE_OP_GATHER;
      route_index_o = raw_route_enable ? raw_route_index : 8'h0;
      route_broadcast_index_o = raw_route_enable ?
                                    raw_route_broadcast_index : 2'h0;
      route_slide_amount_o = raw_route_enable ?
                                 raw_route_slide_amount : 3'h0;
      route_lower_o = raw_route_enable ? raw_route_lower : 32'h0;
      route_upper_o = raw_route_enable ? raw_route_upper : 32'h0;

      result_has_narrow_o = raw_export_narrow;
      result_has_reduce_o = raw_reduce_enable;
      result_has_count_o = (raw_op == SIMD_OP_COMPRESS) ||
                           (raw_op == SIMD_OP_EXPAND);
      requires_result_o = simd_exec_requires_result(
          raw_op, raw_export_narrow, raw_reduce_enable);
    end
  end

  /* verilator lint_off UNUSED */
  logic legality_outputs_used;
  assign legality_outputs_used = route_legal_unused && uop_legal_unused;
  /* verilator lint_on UNUSED */

  initial begin
    if ((VREGS < 1) || (VREGS > 16))
      $error("profile v0 requires 1..16 VRF rows");
    if ((AREGS < 1) || (AREGS > 8))
      $error("profile v0 requires 1..8 ARF rows");
    if ((MREGS < 1) || (MREGS > 4))
      $error("profile v0 requires 1..4 MRF rows");
  end
endmodule
