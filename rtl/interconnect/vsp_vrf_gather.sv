// Output-driven byte gather used by the cluster register-route engine.
//
// Each destination owns one full-width index element.  Repeated indices are
// legal and therefore implement multicast without arbitration.  Destination
// activity and source presence are deliberately separate:
//
//   inactive destination        -> no write
//   active + present source     -> selected byte
//   active + OOB/missing source -> no write + invalid bit
//
// Keeping the full index byte until after the range check prevents values
// 16..255 from silently wrapping through a four-bit crossbar select.
module vsp_vrf_gather #(
  parameter int LANES        = 16,
  parameter int DATA_W       = 8,
  parameter int INDEX_ELEM_W = 8
) (
  input  logic [(LANES*DATA_W)-1:0]       source_data_i,
  input  logic [LANES-1:0]                source_valid_i,
  input  logic [(LANES*INDEX_ELEM_W)-1:0] index_data_i,
  input  logic [LANES-1:0]                destination_active_i,

  output logic [(LANES*DATA_W)-1:0]       result_data_o,
  output logic [LANES-1:0]                result_write_mask_o,
  output logic [LANES-1:0]                result_invalid_mask_o
);
  always_comb begin
    result_data_o = '0;
    result_write_mask_o = '0;
    result_invalid_mask_o = '0;

    for (int destination = 0; destination < LANES; destination++) begin
      int unsigned source_index;

      source_index = int'(
          index_data_i[(destination*INDEX_ELEM_W) +: INDEX_ELEM_W]);
      if (destination_active_i[destination]) begin
        if (source_index < LANES && source_valid_i[source_index]) begin
          result_data_o[(destination*DATA_W) +: DATA_W] =
              source_data_i[(source_index*DATA_W) +: DATA_W];
          result_write_mask_o[destination] = 1'b1;
        end else begin
          result_invalid_mask_o[destination] = 1'b1;
        end
      end
    end
  end

  initial begin
    if (LANES < 1 || LANES > (1 << INDEX_ELEM_W))
      $error("LANES must fit in one index element");
    if (DATA_W < 1 || INDEX_ELEM_W < 1)
      $error("gather widths must be positive");
  end
endmodule
