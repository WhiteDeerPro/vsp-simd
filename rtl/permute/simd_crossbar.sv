module simd_crossbar #(
  parameter int PORTS   = 4,
  parameter int DATA_W  = 8,
  parameter int INDEX_W = (PORTS <= 2) ? 1 : $clog2(PORTS)
) (
  input  logic [(PORTS*DATA_W)-1:0]  data_i,
  // Each output owns one source index. Repeated indices are legal and form
  // multicast/broadcast; unique indices describe a permutation.
  input  logic [(PORTS*INDEX_W)-1:0] select_i,
  output logic [(PORTS*DATA_W)-1:0]  data_o,
  output logic                       illegal_o
);
  always_comb begin
    data_o = '0;
    illegal_o = 1'b0;

    for (int output_port = 0; output_port < PORTS; output_port++) begin
      int unsigned source_port;
      source_port = int'(select_i[(output_port*INDEX_W) +: INDEX_W]);
      if (source_port < PORTS) begin
        data_o[(output_port*DATA_W) +: DATA_W] =
            data_i[(source_port*DATA_W) +: DATA_W];
      end else begin
        illegal_o = 1'b1;
      end
    end
  end

  initial begin
    if (PORTS < 1) $error("PORTS must be positive");
    if (DATA_W < 1) $error("DATA_W must be positive");
    if (INDEX_W != ((PORTS <= 2) ? 1 : $clog2(PORTS))) begin
      $error("INDEX_W must match PORTS");
    end
  end
endmodule
