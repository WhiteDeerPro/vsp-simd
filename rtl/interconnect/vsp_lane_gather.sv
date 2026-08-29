// Fixed full-crossbar gather stage spanning several SIMD groups. This is a
// deliberate temporary routing baseline rather than a chosen network: every
// output lane owns one source index, so no route-setting search exists and a
// runtime index vector costs no extra control state. The price is the
// O(LANES^2) mux fabric.
//
// Named static patterns sit next to the dynamic index vector because most
// image mappings need only a few fixed permutations, and a small mode field
// encodes those far more cheaply than LANES*INDEX_W index bits. Reserved mode
// encodings are kept free for later routing schemes.
//
// The stage is gather-only: repeated source indices are legal, so one input may
// feed several outputs, but no output is ever written twice. It is not wired
// into the datapath. The stripe of a wide logical vector over group VRF rows,
// index provenance, resource reservation and the writeback transaction all
// remain undefined.
module vsp_lane_gather #(
  parameter int LANES   = 16,
  parameter int DATA_W  = 8,
  parameter int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES),
  parameter int MODE_W  = 4
) (
  input  logic [MODE_W-1:0]          mode_i,
  input  logic [(LANES*DATA_W)-1:0]  data_i,

  // Read by GATHER only. Repeated indices form multicast/broadcast.
  input  logic [(LANES*INDEX_W)-1:0] index_i,

  // Source lane for BROADCAST; rotate distance for ROTATE_UP/ROTATE_DOWN.
  input  logic [INDEX_W-1:0]         amount_i,

  output logic [(LANES*DATA_W)-1:0]  data_o,

  // Marks outputs whose rotate source wrapped past the vector end. Masking
  // these lanes off at the consumer turns a rotate into a zero-fill shift.
  // It is not an execution mask.
  output logic [LANES-1:0]           wrap_mask_o,
  output logic                       illegal_o
);
  // Every output lane selects its own source, so the fabric is one crossbar
  // and the mode only generates select bits.
  localparam logic [MODE_W-1:0] MODE_IDENTITY     = MODE_W'(0);
  localparam logic [MODE_W-1:0] MODE_GATHER       = MODE_W'(1);
  localparam logic [MODE_W-1:0] MODE_BROADCAST    = MODE_W'(2);
  localparam logic [MODE_W-1:0] MODE_ROTATE_UP    = MODE_W'(3);
  localparam logic [MODE_W-1:0] MODE_ROTATE_DOWN  = MODE_W'(4);
  localparam logic [MODE_W-1:0] MODE_REVERSE      = MODE_W'(5);
  localparam logic [MODE_W-1:0] MODE_TRANSPOSE    = MODE_W'(6);
  localparam logic [MODE_W-1:0] MODE_DEINTERLEAVE = MODE_W'(7);
  localparam logic [MODE_W-1:0] MODE_INTERLEAVE   = MODE_W'(8);

  // TRANSPOSE reads the vector as a square tile; DEINTERLEAVE/INTERLEAVE split
  // it into two halves. Both are illegal when LANES cannot express the shape.
  function automatic int floor_sqrt(input int value);
    int root;
    root = 0;
    while (((root + 1) * (root + 1)) <= value) begin
      root = root + 1;
    end
    return root;
  endfunction

  localparam int TILE_SIDE = floor_sqrt(LANES);
  localparam bit SQUARE_OK = ((TILE_SIDE * TILE_SIDE) == LANES);
  localparam int HALF_LANES = LANES / 2;
  localparam bit EVEN_OK = ((HALF_LANES * 2) == LANES);

  logic [(LANES*INDEX_W)-1:0] crossbar_select;
  logic [(LANES*DATA_W)-1:0] crossbar_data;
  logic crossbar_illegal;
  logic control_illegal;
  int unsigned amount;

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
    wrap_mask_o = '0;
    control_illegal = 1'b0;
    amount = int'(amount_i);

    case (mode_i)
      MODE_IDENTITY: begin
        for (int lane = 0; lane < LANES; lane++) begin
          crossbar_select[(lane*INDEX_W) +: INDEX_W] = INDEX_W'(lane);
        end
      end

      // Arbitrary runtime mapping. The crossbar needs no setup for this, which
      // is the reason a full fabric is the cheap answer for dynamic routing.
      MODE_GATHER: begin
        crossbar_select = index_i;
      end

      MODE_BROADCAST: begin
        if (amount < LANES) begin
          for (int lane = 0; lane < LANES; lane++) begin
            crossbar_select[(lane*INDEX_W) +: INDEX_W] = amount_i;
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      // Cyclic move toward higher lane numbers. Wrapped lanes are reported
      // instead of being filled from an adjacent group.
      MODE_ROTATE_UP: begin
        if (amount < LANES) begin
          for (int lane = 0; lane < LANES; lane++) begin
            if (lane >= int'(amount)) begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'(lane - int'(amount));
            end else begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'(LANES + lane - int'(amount));
              wrap_mask_o[lane] = 1'b1;
            end
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      MODE_ROTATE_DOWN: begin
        if (amount < LANES) begin
          for (int lane = 0; lane < LANES; lane++) begin
            if ((lane + int'(amount)) < LANES) begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'(lane + int'(amount));
            end else begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'(lane + int'(amount) - LANES);
              wrap_mask_o[lane] = 1'b1;
            end
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      // Horizontal mirror of the whole logical vector.
      MODE_REVERSE: begin
        for (int lane = 0; lane < LANES; lane++) begin
          crossbar_select[(lane*INDEX_W) +: INDEX_W] =
              INDEX_W'(LANES - 1 - lane);
        end
      end

      // Square tile transpose: output row-major lane (r,c) reads input (c,r).
      // This is how a column of a tile becomes lane-parallel.
      MODE_TRANSPOSE: begin
        if (SQUARE_OK) begin
          for (int lane = 0; lane < LANES; lane++) begin
            int row;
            int col;
            row = lane / TILE_SIDE;
            col = lane % TILE_SIDE;
            crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                INDEX_W'((col * TILE_SIDE) + row);
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      // Even lanes to the low half, odd lanes to the high half.
      MODE_DEINTERLEAVE: begin
        if (EVEN_OK) begin
          for (int lane = 0; lane < LANES; lane++) begin
            if (lane < HALF_LANES) begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] = INDEX_W'(2 * lane);
            end else begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'((2 * (lane - HALF_LANES)) + 1);
            end
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      // Exact inverse of DEINTERLEAVE.
      MODE_INTERLEAVE: begin
        if (EVEN_OK) begin
          for (int lane = 0; lane < LANES; lane++) begin
            if ((lane % 2) == 0) begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] = INDEX_W'(lane / 2);
            end else begin
              crossbar_select[(lane*INDEX_W) +: INDEX_W] =
                  INDEX_W'(HALF_LANES + (lane / 2));
            end
          end
        end else begin
          control_illegal = 1'b1;
        end
      end

      // Reserved for later routing schemes.
      default: control_illegal = 1'b1;
    endcase
  end

  // A rejected control word produces no data. An out-of-range GATHER index
  // only zeroes its own output lane, matching simd_crossbar.
  always_comb begin
    data_o = crossbar_data;
    if (control_illegal) begin
      data_o = '0;
    end
  end

  assign illegal_o = control_illegal || crossbar_illegal;

  initial begin
    if (LANES < 1) $error("LANES must be positive");
    if (DATA_W < 1) $error("DATA_W must be positive");
    if (INDEX_W != ((LANES <= 2) ? 1 : $clog2(LANES))) begin
      $error("INDEX_W must match LANES");
    end
    if (MODE_W < 4) $error("MODE_W must hold the defined mode encodings");
  end
endmodule
