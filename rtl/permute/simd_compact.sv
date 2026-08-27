module simd_compact #(
  parameter int LANES   = 4,
  parameter int DATA_W  = 8,
  parameter int COUNT_W = (LANES <= 1) ? 1 : $clog2(LANES + 1)
) (
  // 0: stable compress active input lanes toward lane zero.
  // 1: expand packed low lanes into the active output positions.
  input  logic                              expand_i,
  input  logic [(LANES*DATA_W)-1:0]         data_i,
  input  logic [LANES-1:0]                  mask_i,
  output logic [(LANES*DATA_W)-1:0]         data_o,
  output logic [LANES-1:0]                  valid_mask_o,
  output logic [COUNT_W-1:0]                count_o
);
  integer unsigned cursor;

  always_comb begin
    data_o = '0;
    valid_mask_o = '0;
    cursor = 0;

    for (int lane = 0; lane < LANES; lane++) begin
      if (mask_i[lane]) begin
        if (expand_i) begin
          data_o[(lane*DATA_W) +: DATA_W] =
              data_i[(cursor*DATA_W) +: DATA_W];
          valid_mask_o[lane] = 1'b1;
        end else begin
          data_o[(cursor*DATA_W) +: DATA_W] =
              data_i[(lane*DATA_W) +: DATA_W];
          valid_mask_o[cursor] = 1'b1;
        end
        cursor = cursor + 1;
      end
    end

    count_o = cursor[COUNT_W-1:0];
  end

  initial begin
    if (COUNT_W != ((LANES <= 1) ? 1 : $clog2(LANES + 1))) begin
      $error("COUNT_W must represent values 0 through LANES");
    end
  end
endmodule
