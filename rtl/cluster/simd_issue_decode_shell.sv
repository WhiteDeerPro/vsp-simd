module simd_issue_decode_shell #(
  parameter int RAW_WORD_W          = 32,
  parameter int RESOLVED_W          = 16,
  parameter int CACHED_META_W       = 16,
  parameter int CONTEXT_W           = 1,
  parameter int TAG_W               = 8,
  parameter int DISPATCH_CLASS_W    = 2,
  parameter int RESPONSE_KIND_W     = 2,
  parameter int GROUP_COUNT         = 4,
  parameter int RESOURCE_W          = 8,
  parameter int CANONICAL_PAYLOAD_W = 32,
  parameter int DECODE_META_W       = 8,
  parameter int ERROR_CAUSE_W       = 4
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One selected, ordered queue entry. raw_word/resolved/cached_meta remain
  // opaque here: this shell deliberately does not assign an ISA bit layout.
  input  logic                           in_valid_i,
  output logic                           in_ready_o,
  input  logic [RAW_WORD_W-1:0]          in_raw_word_i,
  input  logic [RESOLVED_W-1:0]          in_resolved_i,
  input  logic [CACHED_META_W-1:0]       in_cached_meta_i,
  input  logic [CONTEXT_W-1:0]           in_context_i,
  input  logic [TAG_W-1:0]               in_tag_i,

  // Replaceable combinational decode hook.  In the reference configuration
  // these fields are driven by an already-decoded test/sequencer adapter.  A
  // future compact-uword decoder may derive them from raw_word, resolved and
  // cached_meta without changing the canonical output contract below.
  input  logic [DISPATCH_CLASS_W-1:0]    hook_dispatch_class_i,
  input  logic [RESPONSE_KIND_W-1:0]     hook_response_kind_i,
  input  logic [GROUP_COUNT-1:0]         hook_group_mask_i,
  input  logic [RESOURCE_W-1:0]          hook_exact_resource_i,
  input  logic [CANONICAL_PAYLOAD_W-1:0] hook_canonical_payload_i,
  input  logic [DECODE_META_W-1:0]       hook_decode_meta_i,
  input  logic                           hook_legal_i,
  input  logic [ERROR_CAUSE_W-1:0]       hook_error_cause_i,

  // Registered canonical issue candidate.  There is intentionally no
  // fall-through path: once visible, every field remains stable until the
  // downstream class router or ordered error sink accepts the transaction.
  output logic                           out_valid_o,
  input  logic                           out_ready_i,
  output logic [RAW_WORD_W-1:0]          out_raw_word_o,
  output logic [RESOLVED_W-1:0]          out_resolved_o,
  output logic [CACHED_META_W-1:0]       out_cached_meta_o,
  output logic [CONTEXT_W-1:0]           out_context_o,
  output logic [TAG_W-1:0]               out_tag_o,
  output logic [DISPATCH_CLASS_W-1:0]    out_dispatch_class_o,
  output logic [RESPONSE_KIND_W-1:0]     out_response_kind_o,
  output logic [GROUP_COUNT-1:0]         out_group_mask_o,
  output logic [RESOURCE_W-1:0]          out_exact_resource_o,
  output logic [CANONICAL_PAYLOAD_W-1:0] out_canonical_payload_o,
  output logic [DECODE_META_W-1:0]       out_decode_meta_o,
  output logic                           out_legal_o,
  output logic [ERROR_CAUSE_W-1:0]       out_error_cause_o
);
  logic valid_q;
  logic [RAW_WORD_W-1:0] raw_word_q;
  logic [RESOLVED_W-1:0] resolved_q;
  logic [CACHED_META_W-1:0] cached_meta_q;
  logic [CONTEXT_W-1:0] context_q;
  logic [TAG_W-1:0] tag_q;
  logic [DISPATCH_CLASS_W-1:0] dispatch_class_q;
  logic [RESPONSE_KIND_W-1:0] response_kind_q;
  logic [GROUP_COUNT-1:0] group_mask_q;
  logic [RESOURCE_W-1:0] exact_resource_q;
  logic [CANONICAL_PAYLOAD_W-1:0] canonical_payload_q;
  logic [DECODE_META_W-1:0] decode_meta_q;
  logic legal_q;
  logic [ERROR_CAUSE_W-1:0] error_cause_q;

  // An occupied entry may be replaced on the same edge on which it retires.
  // Gating ready with reset avoids claiming ownership while state is reset.
  assign in_ready_o = rst_ni && (!valid_q || out_ready_i);

  assign out_valid_o = valid_q;
  assign out_raw_word_o = raw_word_q;
  assign out_resolved_o = resolved_q;
  assign out_cached_meta_o = cached_meta_q;
  assign out_context_o = context_q;
  assign out_tag_o = tag_q;
  assign out_dispatch_class_o = dispatch_class_q;
  assign out_response_kind_o = response_kind_q;
  assign out_group_mask_o = group_mask_q;
  assign out_exact_resource_o = exact_resource_q;
  assign out_canonical_payload_o = canonical_payload_q;
  assign out_decode_meta_o = decode_meta_q;
  assign out_legal_o = legal_q;
  assign out_error_cause_o = error_cause_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= 1'b0;
      raw_word_q <= '0;
      resolved_q <= '0;
      cached_meta_q <= '0;
      context_q <= '0;
      tag_q <= '0;
      dispatch_class_q <= '0;
      response_kind_q <= '0;
      group_mask_q <= '0;
      exact_resource_q <= '0;
      canonical_payload_q <= '0;
      decode_meta_q <= '0;
      legal_q <= 1'b0;
      error_cause_q <= '0;
    end else if (in_ready_o) begin
      valid_q <= in_valid_i;
      if (in_valid_i) begin
        raw_word_q <= in_raw_word_i;
        resolved_q <= in_resolved_i;
        cached_meta_q <= in_cached_meta_i;
        context_q <= in_context_i;
        tag_q <= in_tag_i;
        dispatch_class_q <= hook_dispatch_class_i;
        response_kind_q <= hook_response_kind_i;
        group_mask_q <= hook_group_mask_i;
        exact_resource_q <= hook_exact_resource_i;
        canonical_payload_q <= hook_canonical_payload_i;
        decode_meta_q <= hook_decode_meta_i;
        legal_q <= hook_legal_i;
        error_cause_q <= hook_error_cause_i;
      end else begin
        raw_word_q <= '0;
        resolved_q <= '0;
        cached_meta_q <= '0;
        context_q <= '0;
        tag_q <= '0;
        dispatch_class_q <= '0;
        response_kind_q <= '0;
        group_mask_q <= '0;
        exact_resource_q <= '0;
        canonical_payload_q <= '0;
        decode_meta_q <= '0;
        legal_q <= 1'b0;
        error_cause_q <= '0;
      end
    end
  end

  initial begin
    if (RAW_WORD_W < 1 || RESOLVED_W < 1 || CACHED_META_W < 1 ||
        CONTEXT_W < 1 || TAG_W < 1 || DISPATCH_CLASS_W < 1 ||
        RESPONSE_KIND_W < 1 || GROUP_COUNT < 1 || RESOURCE_W < 1 ||
        CANONICAL_PAYLOAD_W < 1 || DECODE_META_W < 1 ||
        ERROR_CAUSE_W < 1) begin
      $error("decode-shell field widths must be positive");
    end
  end
endmodule
