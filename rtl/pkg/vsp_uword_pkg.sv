package vsp_uword_pkg;
  // Reference framing for the current sequencer control-word stream.  It
  // reuses the defined EXEC profile formats and reserves two formerly unused
  // format nibbles for class routing.  Generic framing treats every body as
  // opaque; profile-local field constants below are consumed only by the
  // class-specific semantic decoders.  This package is not itself a decoder
  // or an external instruction-set definition.
  localparam int VSP_UWORD_W = 32;
  localparam int VSP_UWORD_MAJOR_W = 4;
  localparam int VSP_UWORD_WORD_COUNT_W = 3;
  localparam int VSP_UWORD_MAX_RECORD_WORDS = 4;

  localparam logic [VSP_UWORD_MAJOR_W-1:0] VSP_UWORD_MAJOR_MEMORY = 4'hb;
  localparam logic [VSP_UWORD_MAJOR_W-1:0] VSP_UWORD_MAJOR_CONTROL = 4'hc;

  // MEMORY profile v0 is one header plus one signed-offset body word.  The
  // header keeps the generic body-count field at 1 so framing remains owned
  // by vsp_uword_record_word_count(); the class decoder later requires this
  // exact two-word shape before it may query sequencer address state.
  //
  //   word 0 [31:28] major          = 4'hb
  //          [27:26] body words     = 2'b01
  //          [25]    operation      = 0 LOAD, 1 STORE
  //          [24:23] address space  = vsp_pkg::vsp_mem_addr_space_e
  //          [22:15] address context
  //          [14:10] state base-register index
  //          [9:6]   VRF row
  //          [5:1]   LOAD/STORE byte-span code
  //          [5:2]   GATHER/SCATTER index VRF row
  //          [1]     GATHER/SCATTER reserved = 0
  //          [0]     address mode   = 0 UNIT_STRIDE, 1 INDEX_U8
  //   word 1 [31:0]  signed address offset
  //
  // For UNIT_STRIDE, span code 0 means four bytes for every group selected
  // by the launch envelope.  Codes 1..31 are explicit byte spans.  The
  // decoder preserves code 0 as a sentinel; the action adapter resolves it
  // against the captured launch group mask before a memory command is
  // issued.  INDEX_U8 continues to decode a zero span payload.
  //
  // The offset word must be a canonical sign extension of the downstream
  // MEM_OFFSET_W (16 in profile v0).  These constants describe the current
  // internal record profile; they do not turn it into a frozen external ISA.
  localparam int VSP_MEMORY_UWORD_RECORD_WORDS = 2;
  localparam logic [1:0] VSP_MEMORY_UWORD_BODY_WORDS = 2'd1;
  localparam int VSP_MEMORY_UWORD_ADDR_CONTEXT_W = 8;
  localparam int VSP_MEMORY_UWORD_STATE_REG_W = 5;
  localparam int VSP_MEMORY_UWORD_VRF_ROW_W = 4;
  localparam int VSP_MEMORY_UWORD_SPAN_CODE_W = 5;
  localparam int VSP_MEMORY_UWORD_SPAN_BYTES_W = 7;
  localparam int VSP_MEMORY_UWORD_OFFSET_W = 16;
  localparam int VSP_MEMORY_UWORD_GROUP_BYTES = 4;
  localparam int VSP_MEMORY_UWORD_MAX_EXPLICIT_SPAN_BYTES =
      (1 << VSP_MEMORY_UWORD_SPAN_CODE_W) - 1;
  localparam int VSP_MEMORY_UWORD_MAX_SPAN_BYTES = 64;

  localparam int VSP_MEMORY_UWORD_OP_BIT = 25;
  localparam int VSP_MEMORY_UWORD_ADDR_MODE_BIT = 0;
  localparam int VSP_MEMORY_UWORD_ADDR_SPACE_MSB = 24;
  localparam int VSP_MEMORY_UWORD_ADDR_SPACE_LSB = 23;
  localparam int VSP_MEMORY_UWORD_ADDR_CONTEXT_MSB = 22;
  localparam int VSP_MEMORY_UWORD_ADDR_CONTEXT_LSB = 15;
  localparam int VSP_MEMORY_UWORD_STATE_REG_MSB = 14;
  localparam int VSP_MEMORY_UWORD_STATE_REG_LSB = 10;
  localparam int VSP_MEMORY_UWORD_VRF_ROW_MSB = 9;
  localparam int VSP_MEMORY_UWORD_VRF_ROW_LSB = 6;
  localparam int VSP_MEMORY_UWORD_SPAN_BYTES_MSB = 5;
  localparam int VSP_MEMORY_UWORD_SPAN_BYTES_LSB = 1;
  localparam int VSP_MEMORY_UWORD_INDEX_VRF_ROW_MSB = 5;
  localparam int VSP_MEMORY_UWORD_INDEX_VRF_ROW_LSB = 2;
  localparam int VSP_MEMORY_UWORD_INDEX_RESERVED_BIT = 1;

  // The current stream profile gives END one canonical, body-free CONTROL
  // header.  Keep recognition here so every stateful framer applies the same
  // rule after finding a record boundary; an opaque body word with this value
  // is not an END record.
  localparam logic [VSP_UWORD_W-1:0] VSP_UWORD_CONTROL_END =
      {VSP_UWORD_MAJOR_CONTROL, 28'h0000000};

  function automatic logic vsp_uword_is_control_end(
      input logic [VSP_UWORD_W-1:0] header);
    vsp_uword_is_control_end = header == VSP_UWORD_CONTROL_END;
  endfunction

  // 2'b11 is deliberately outside vsp_action_class_e.  Undefined headers are
  // still framed as one-word records so a later ordered error path can retire
  // them without losing the boundary of every following record.
  localparam logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
      VSP_UWORD_CLASS_UNDEFINED = '1;

  function automatic logic vsp_uword_major_defined(
      input logic [VSP_UWORD_W-1:0] header);
    logic [VSP_UWORD_MAJOR_W-1:0] major;
    begin
      major = header[VSP_UWORD_W-1 -: VSP_UWORD_MAJOR_W];
      vsp_uword_major_defined =
          vsp_exec_uword_pkg::vsp_exec_uword_format_defined(major) ||
          (major == VSP_UWORD_MAJOR_MEMORY) ||
          (major == VSP_UWORD_MAJOR_CONTROL);
    end
  endfunction

  function automatic logic [vsp_action_pkg::VSP_ACTION_CLASS_W-1:0]
      vsp_uword_dispatch_class(input logic [VSP_UWORD_W-1:0] header);
    logic [VSP_UWORD_MAJOR_W-1:0] major;
    begin
      major = header[VSP_UWORD_W-1 -: VSP_UWORD_MAJOR_W];
      if (vsp_exec_uword_pkg::vsp_exec_uword_format_defined(major))
        vsp_uword_dispatch_class = vsp_action_pkg::VSP_ACTION_CLASS_EXEC;
      else if (major == VSP_UWORD_MAJOR_MEMORY)
        vsp_uword_dispatch_class = vsp_action_pkg::VSP_ACTION_CLASS_MEMORY;
      else if (major == VSP_UWORD_MAJOR_CONTROL)
        vsp_uword_dispatch_class = vsp_action_pkg::VSP_ACTION_CLASS_CONTROL;
      else
        vsp_uword_dispatch_class = VSP_UWORD_CLASS_UNDEFINED;
    end
  endfunction

  function automatic logic [VSP_UWORD_WORD_COUNT_W-1:0]
      vsp_uword_record_word_count(input logic [VSP_UWORD_W-1:0] header);
    logic [VSP_UWORD_MAJOR_W-1:0] major;
    begin
      major = header[VSP_UWORD_W-1 -: VSP_UWORD_MAJOR_W];
      if (vsp_exec_uword_pkg::vsp_exec_uword_format_defined(major)) begin
        vsp_uword_record_word_count =
            vsp_exec_uword_pkg::vsp_exec_uword_extension_required(header) ?
                3'd2 : 3'd1;
      end else if ((major == VSP_UWORD_MAJOR_MEMORY) ||
                   (major == VSP_UWORD_MAJOR_CONTROL)) begin
        // For the two non-EXEC classes, bits 27:26 are the number of body
        // words following the header.  A record therefore occupies 1..4
        // contiguous words.  Body words are never interpreted as headers.
        vsp_uword_record_word_count = {1'b0, header[27:26]} + 3'd1;
      end else begin
        vsp_uword_record_word_count = 3'd1;
      end
    end
  endfunction
endpackage
