package vsp_uword_pkg;
  // Reference framing for the current sequencer control-word stream.  It
  // reuses the defined EXEC profile formats and reserves two formerly unused
  // format nibbles for class routing.  The payload below this framing layer is
  // intentionally opaque; this package is not a MEMORY/CONTROL decoder or an
  // external instruction-set definition.
  localparam int VSP_UWORD_W = 32;
  localparam int VSP_UWORD_MAJOR_W = 4;
  localparam int VSP_UWORD_WORD_COUNT_W = 3;
  localparam int VSP_UWORD_MAX_RECORD_WORDS = 4;

  localparam logic [VSP_UWORD_MAJOR_W-1:0] VSP_UWORD_MAJOR_MEMORY = 4'hb;
  localparam logic [VSP_UWORD_MAJOR_W-1:0] VSP_UWORD_MAJOR_CONTROL = 4'hc;

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
