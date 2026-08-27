module simd_regfile #(
  parameter int REG_COUNT  = 16,
  parameter int LANES      = 4,
  parameter int ELEM_W     = 8,
  parameter int READ_PORTS = 2,
  parameter int ADDR_W     = (REG_COUNT <= 2) ? 1 : $clog2(REG_COUNT)
) (
  input  logic                                  clk_i,
  input  logic [(READ_PORTS*ADDR_W)-1:0]        read_addr_i,
  output logic [(READ_PORTS*LANES*ELEM_W)-1:0] read_data_o,
  input  logic                                  write_enable_i,
  input  logic [ADDR_W-1:0]                     write_addr_i,
  // Per-lane write enable. An inactive lane preserves its stored element.
  input  logic [LANES-1:0]                      write_mask_i,
  input  logic [(LANES*ELEM_W)-1:0]             write_data_i
);
  logic [(LANES*ELEM_W)-1:0] registers [0:REG_COUNT-1];

  generate
    for (genvar port_index = 0; port_index < READ_PORTS; port_index++) begin : gen_read
      always_comb begin
        read_data_o[(port_index*LANES*ELEM_W) +: (LANES*ELEM_W)] =
            registers[read_addr_i[(port_index*ADDR_W) +: ADDR_W]];
      end
    end
  endgenerate

  always_ff @(posedge clk_i) begin
    if (write_enable_i) begin
      for (int lane = 0; lane < LANES; lane++) begin
        if (write_mask_i[lane]) begin
          registers[write_addr_i][(lane*ELEM_W) +: ELEM_W] <=
              write_data_i[(lane*ELEM_W) +: ELEM_W];
        end
      end
    end
  end

  initial begin
    if (REG_COUNT < 2) $error("REG_COUNT must be at least 2");
    if ((REG_COUNT & (REG_COUNT - 1)) != 0) begin
      $error("REG_COUNT must be a power of two");
    end
    if (LANES < 1) $error("LANES must be positive");
    if (ELEM_W < 1) $error("ELEM_W must be positive");
    if (READ_PORTS < 1) $error("READ_PORTS must be positive");
    if (ADDR_W != ((REG_COUNT <= 2) ? 1 : $clog2(REG_COUNT))) begin
      $error("ADDR_W must match REG_COUNT");
    end
  end
endmodule
