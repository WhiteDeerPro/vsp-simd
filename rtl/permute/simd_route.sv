module simd_route #(
  parameter int LANES    = 4,
  parameter int DATA_W   = 8,
  parameter int INDEX_W  = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int OFFSET_W = $clog2(LANES + 1)
) (
  input  logic [simd_pkg::ROUTE_OP_W-1:0] op_i,
  input  logic [(LANES*DATA_W)-1:0]       data_i,

  // GATHER uses all indices independently. BROADCAST uses only
  // broadcast_index_i and deliberately permits one source to feed all lanes.
  input  logic [(LANES*INDEX_W)-1:0]      index_i,
  input  logic [INDEX_W-1:0]              broadcast_index_i,

  // SLIDE_UP moves values toward higher-numbered lanes and reads missing low
  // lanes from lower_i. SLIDE_DOWN is the mirror operation using upper_i.
  // Tying lower_i/upper_i to zero gives zero-fill slide semantics. Connecting
  // adjacent SIMD groups permits a wider logical vector without a global
  // crossbar. Amount LANES transfers the complete adjacent group.
  input  logic [OFFSET_W-1:0]             slide_amount_i,
  input  logic [(LANES*DATA_W)-1:0]       lower_i,
  input  logic [(LANES*DATA_W)-1:0]       upper_i,

  output logic [(LANES*DATA_W)-1:0]       data_o,
  // Marks outputs sourced from lower_i/upper_i; it is not an execution mask.
  output logic [LANES-1:0]                boundary_mask_o,
  output logic                            illegal_o
);
  import simd_pkg::*;

  logic [(LANES*INDEX_W)-1:0] crossbar_select;
  logic [(LANES*DATA_W)-1:0] crossbar_data;
  logic crossbar_illegal;
  logic control_illegal;
  int unsigned slide_amount;

  simd_crossbar #(
    .PORTS(LANES),
    .DATA_W(DATA_W),
    .INDEX_W(INDEX_W)
  ) u_crossbar (
    .data_i(data_i),
    .select_i(crossbar_select),
    .data_o(crossbar_data),
    .illegal_o(crossbar_illegal)
  );

  always_comb begin
    crossbar_select = '0;
    boundary_mask_o = '0;
    control_illegal = 1'b0;
    slide_amount = int'(slide_amount_i);

    case (op_i)
      // Arbitrary output-to-input mapping. This covers both a bijective
      // permutation and gather/multicast with repeated source indices.
      ROUTE_OP_GATHER: begin
        crossbar_select = index_i;
      end

      // A compact encoding of gather in which every output selects one lane.
      ROUTE_OP_BROADCAST: begin
        for (int lane = 0; lane < LANES; lane++) begin
          crossbar_select[(lane*INDEX_W) +: INDEX_W] = broadcast_index_i;
        end
      end

      ROUTE_OP_SLIDE_UP: begin
        if (slide_amount <= LANES) begin
          for (int lane = 0; lane < LANES; lane++) begin
            if (lane >= slide_amount) begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'(lane - slide_amount);
            end else begin
              boundary_mask_o[lane] = 1'b1;
            end
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      ROUTE_OP_SLIDE_DOWN: begin
        if (slide_amount <= LANES) begin
          for (int lane = 0; lane < LANES; lane++) begin
            if ((lane + slide_amount) < LANES) begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'(lane + slide_amount);
            end else begin
              boundary_mask_o[lane] = 1'b1;
            end
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      default: control_illegal = 1'b1;
    endcase
  end

  always_comb begin
    data_o = crossbar_data;

    if (control_illegal) begin
      data_o = '0;
    end else if (op_i == ROUTE_OP_SLIDE_UP) begin
      for (int lane = 0; lane < LANES; lane++) begin
        if (boundary_mask_o[lane]) begin
          data_o[(lane*DATA_W) +: DATA_W] =
              lower_i[((LANES-slide_amount+lane)*DATA_W) +: DATA_W];
        end
      end
    end else if (op_i == ROUTE_OP_SLIDE_DOWN) begin
      for (int lane = 0; lane < LANES; lane++) begin
        if (boundary_mask_o[lane]) begin
          data_o[(lane*DATA_W) +: DATA_W] =
              upper_i[((lane+slide_amount-LANES)*DATA_W) +: DATA_W];
        end
      end
    end
  end

  assign illegal_o = control_illegal || crossbar_illegal;

  initial begin
    if (LANES < 1) $error("LANES must be positive");
    if (DATA_W < 1) $error("DATA_W must be positive");
    if (INDEX_W != ((LANES <= 2) ? 1 : $clog2(LANES))) begin
      $error("INDEX_W must match LANES");
    end
    if (OFFSET_W != $clog2(LANES + 1)) begin
      $error("OFFSET_W must represent slide amounts 0 through LANES");
    end
  end
endmodule
