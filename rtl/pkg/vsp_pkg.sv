package vsp_pkg;
  // Canonical VSP memory-control metadata. These values are internal control
  // semantics, not frozen instruction encodings or a system-bus protocol.

  localparam int VSP_MEM_OP_W = 1;

  typedef enum logic [VSP_MEM_OP_W-1:0] {
    VSP_MEM_OP_LOAD  = 1'b0,
    VSP_MEM_OP_STORE = 1'b1
  } vsp_mem_op_e;

  // The vector memory engine carries an effective address plus its
  // address-space kind.
  // LOCAL and PHYSICAL bypass address translation in the future downstream
  // adapter; TRANSLATED selects a translation context. The engine itself does
  // not contain an MMU, TLB, PTW, cache, or address-space router.
  localparam int VSP_MEM_ADDR_SPACE_W = 2;

  typedef enum logic [VSP_MEM_ADDR_SPACE_W-1:0] {
    VSP_MEM_ADDR_SPACE_LOCAL      = 2'h0,
    VSP_MEM_ADDR_SPACE_PHYSICAL   = 2'h1,
    VSP_MEM_ADDR_SPACE_TRANSLATED = 2'h2
  } vsp_mem_addr_space_e;

  function automatic logic vsp_mem_addr_space_defined(
      input logic [VSP_MEM_ADDR_SPACE_W-1:0] addr_space);
    unique case (addr_space)
      VSP_MEM_ADDR_SPACE_LOCAL,
      VSP_MEM_ADDR_SPACE_PHYSICAL,
      VSP_MEM_ADDR_SPACE_TRANSLATED:
        vsp_mem_addr_space_defined = 1'b1;
      default: vsp_mem_addr_space_defined = 1'b0;
    endcase
  endfunction

  // Final result of one accepted downstream data-memory access. A translation
  // adapter may produce TRANSLATION/PERMISSION; a memory endpoint may produce
  // ACCESS/BUS/DATA_INTEGRITY. NONE is the only successful response value.
  // The request source already owns the effective address, so the sequential
  // single-outstanding profile does not return an address or transaction ID.
  localparam int VSP_MEM_FAULT_CAUSE_W = 3;

  typedef enum logic [VSP_MEM_FAULT_CAUSE_W-1:0] {
    VSP_MEM_FAULT_NONE           = 3'h0,
    VSP_MEM_FAULT_TRANSLATION    = 3'h1,
    VSP_MEM_FAULT_PERMISSION     = 3'h2,
    VSP_MEM_FAULT_ACCESS         = 3'h3,
    VSP_MEM_FAULT_BUS            = 3'h4,
    VSP_MEM_FAULT_DATA_INTEGRITY = 3'h5,
    VSP_MEM_FAULT_PROTOCOL       = 3'h6
  } vsp_mem_fault_cause_e;

  // Program-level MEMORY parent completion. Detailed downstream failures use
  // status MEMORY_FAULT plus cpl_fault_cause/cpl_fault_eaddr. Static descriptor
  // and effective-address errors remain local statuses and carry fault NONE.
  localparam int VSP_MEM_CPL_STATUS_W = 3;

  typedef enum logic [VSP_MEM_CPL_STATUS_W-1:0] {
    VSP_MEM_CPL_OK           = 3'h0,
    VSP_MEM_CPL_BAD_REQUEST  = 3'h1,
    VSP_MEM_CPL_BAD_EADDR    = 3'h2,
    VSP_MEM_CPL_MEMORY_FAULT = 3'h3,
    VSP_MEM_CPL_VRF_ERROR    = 3'h4
  } vsp_mem_cpl_status_e;

endpackage
