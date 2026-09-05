// SPDX-License-Identifier: MIT
package vsp_host_mmio_pkg;
  // Host integration ABI, independent of executable uword encoding.
  localparam logic [31:0] VSP_HOST_ID = 32'h56535031;
  localparam logic [31:0] VSP_HOST_VERSION = 32'h00010000;

  localparam logic [11:0] VSP_HOST_REG_ID                = 12'h000;
  localparam logic [11:0] VSP_HOST_REG_VERSION           = 12'h004;
  localparam logic [11:0] VSP_HOST_REG_STATUS            = 12'h008;
  localparam logic [11:0] VSP_HOST_REG_COMMAND           = 12'h00c;
  localparam logic [11:0] VSP_HOST_REG_START_PC          = 12'h010;
  localparam logic [11:0] VSP_HOST_REG_END_PC            = 12'h014;
  localparam logic [11:0] VSP_HOST_REG_GROUP_MASK        = 12'h018;
  localparam logic [11:0] VSP_HOST_REG_FETCH_CONTEXT     = 12'h01c;
  localparam logic [11:0] VSP_HOST_REG_TAG_SEED          = 12'h020;
  localparam logic [11:0] VSP_HOST_REG_IRQ_ENABLE        = 12'h024;
  localparam logic [11:0] VSP_HOST_REG_IRQ_PENDING       = 12'h028;
  localparam logic [11:0] VSP_HOST_REG_FETCH_PC          = 12'h02c;
  localparam logic [11:0] VSP_HOST_REG_RESULT_STATUS     = 12'h030;
  localparam logic [11:0] VSP_HOST_REG_TERMINAL_PC       = 12'h034;
  localparam logic [11:0] VSP_HOST_REG_ACTION_COUNT      = 12'h038;
  localparam logic [11:0] VSP_HOST_REG_FIRST_ERROR_INFO  = 12'h03c;
  localparam logic [11:0] VSP_HOST_REG_FIRST_ERROR_TAG   = 12'h040;
  localparam logic [11:0] VSP_HOST_REG_MEM_FAULT_INFO    = 12'h044;
  localparam logic [11:0] VSP_HOST_REG_MEM_FAULT_EADDR   = 12'h048;
  localparam logic [11:0] VSP_HOST_REG_MEM_MASKS         = 12'h04c;
  localparam logic [11:0] VSP_HOST_REG_MEM_FAILED_MASK   = 12'h050;
  localparam logic [11:0] VSP_HOST_REG_MEM_BYTES         = 12'h054;
  localparam logic [11:0] VSP_HOST_REG_IFETCH_INFO       = 12'h058;
  localparam logic [11:0] VSP_HOST_REG_IFETCH_EADDR      = 12'h05c;
  localparam logic [11:0] VSP_HOST_REG_IFETCH_PADDR_LO   = 12'h060;
  localparam logic [11:0] VSP_HOST_REG_IFETCH_PADDR_HI   = 12'h064;
  localparam logic [11:0] VSP_HOST_REG_MMU_CONTEXT       = 12'h070;
  localparam logic [11:0] VSP_HOST_REG_MMU_FIELD         = 12'h074;
  localparam logic [11:0] VSP_HOST_REG_MMU_WDATA         = 12'h078;
  localparam logic [11:0] VSP_HOST_REG_MMU_RDATA         = 12'h07c;
  localparam logic [11:0] VSP_HOST_REG_MGMT_STATUS       = 12'h080;
  localparam logic [11:0] VSP_HOST_REG_MAINT_OP          = 12'h084;
  localparam logic [11:0] VSP_HOST_REG_MAINT_EADDR       = 12'h088;
  localparam logic [11:0] VSP_HOST_REG_MAINT_PADDR_LO    = 12'h08c;
  localparam logic [11:0] VSP_HOST_REG_MAINT_PADDR_HI    = 12'h090;
  localparam logic [11:0] VSP_HOST_REG_MAINT_CONTEXT     = 12'h094;
  localparam logic [11:0] VSP_HOST_REG_MAINT_ASID        = 12'h098;

  localparam logic [31:0] VSP_HOST_CMD_START          = 32'd1;
  localparam logic [31:0] VSP_HOST_CMD_ACK_RESULT     = 32'd2;
  localparam logic [31:0] VSP_HOST_CMD_MMU_READ       = 32'd3;
  localparam logic [31:0] VSP_HOST_CMD_MMU_WRITE      = 32'd4;
  localparam logic [31:0] VSP_HOST_CMD_MAINTENANCE    = 32'd5;
  localparam logic [31:0] VSP_HOST_CMD_CLEAR_PROTOCOL = 32'd6;

  localparam logic [2:0] VSP_HOST_IRQ_COMPLETE   = 3'b001;
  localparam logic [2:0] VSP_HOST_IRQ_ERROR      = 3'b010;
  localparam logic [2:0] VSP_HOST_IRQ_MANAGEMENT = 3'b100;
endpackage
