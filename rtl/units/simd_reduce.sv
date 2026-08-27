module simd_reduce #(
  parameter int LANES  = 4,
  parameter int DATA_W = 8,
  parameter int ACC_W  = 32,
  parameter int INDEX_W = (LANES <= 2) ? 1 : $clog2(LANES)
) (
  input  logic [simd_pkg::REDUCE_OP_W-1:0] op_i,
  input  logic [LANES-1:0]                  mask_i,
  input  logic [(LANES*DATA_W)-1:0]         data_i,
  output logic [ACC_W-1:0]                  value_o,
  output logic [INDEX_W-1:0]                 index_o,
  output logic                              valid_o,
  output logic                              illegal_o
);
  import simd_pkg::*;

  localparam int NODES = (2 * LANES) - 1;
  localparam int FIRST_LEAF = LANES - 1;

  // Complete binary tree in heap order. Leaves and then internal nodes are
  // evaluated from the largest index toward the root in one combinational block.
  logic [ACC_W-1:0] tree_value [0:NODES-1];
  logic [INDEX_W-1:0] tree_index [0:NODES-1];
  logic tree_valid [0:NODES-1];

  logic signed_domain;

  always_comb begin
    for (int node = 0; node < NODES; node++) begin
      tree_value[node] = '0;
      tree_index[node] = '0;
      tree_valid[node] = 1'b0;
    end

    case (op_i)
      REDUCE_OP_SUM_S,
      REDUCE_OP_MIN_S,
      REDUCE_OP_MAX_S: signed_domain = 1'b1;
      default: signed_domain = 1'b0;
    endcase

    case (op_i)
      REDUCE_OP_SUM_U,
      REDUCE_OP_SUM_S,
      REDUCE_OP_MIN_U,
      REDUCE_OP_MIN_S,
      REDUCE_OP_MAX_U,
      REDUCE_OP_MAX_S: illegal_o = 1'b0;
      default: illegal_o = 1'b1;
    endcase

    for (int lane = 0; lane < LANES; lane++) begin
      tree_valid[FIRST_LEAF+lane] = mask_i[lane];
      tree_index[FIRST_LEAF+lane] = INDEX_W'(lane);
      if (signed_domain) begin
        tree_value[FIRST_LEAF+lane] =
            {{(ACC_W-DATA_W){data_i[(lane*DATA_W)+DATA_W-1]}},
             data_i[(lane*DATA_W) +: DATA_W]};
      end else begin
        tree_value[FIRST_LEAF+lane] =
            {{(ACC_W-DATA_W){1'b0}},
             data_i[(lane*DATA_W) +: DATA_W]};
      end
    end

    for (int node = FIRST_LEAF - 1; node >= 0; node--) begin
      tree_valid[node] = tree_valid[(2*node)+1] | tree_valid[(2*node)+2];

      if (tree_valid[(2*node)+1] && !tree_valid[(2*node)+2]) begin
        tree_value[node] = tree_value[(2*node)+1];
        tree_index[node] = tree_index[(2*node)+1];
      end else if (!tree_valid[(2*node)+1] && tree_valid[(2*node)+2]) begin
        tree_value[node] = tree_value[(2*node)+2];
        tree_index[node] = tree_index[(2*node)+2];
      end else if (tree_valid[(2*node)+1] && tree_valid[(2*node)+2]) begin
        case (op_i)
          REDUCE_OP_SUM_U,
          REDUCE_OP_SUM_S: begin
            tree_value[node] =
                tree_value[(2*node)+1] + tree_value[(2*node)+2];
            tree_index[node] = tree_index[(2*node)+1];
          end

          REDUCE_OP_MIN_U: begin
            if (tree_value[(2*node)+2] < tree_value[(2*node)+1]) begin
              tree_value[node] = tree_value[(2*node)+2];
              tree_index[node] = tree_index[(2*node)+2];
            end else begin
              tree_value[node] = tree_value[(2*node)+1];
              tree_index[node] = tree_index[(2*node)+1];
            end
          end

          REDUCE_OP_MIN_S: begin
            if ($signed(tree_value[(2*node)+2]) <
                $signed(tree_value[(2*node)+1])) begin
              tree_value[node] = tree_value[(2*node)+2];
              tree_index[node] = tree_index[(2*node)+2];
            end else begin
              tree_value[node] = tree_value[(2*node)+1];
              tree_index[node] = tree_index[(2*node)+1];
            end
          end

          REDUCE_OP_MAX_U: begin
            if (tree_value[(2*node)+2] > tree_value[(2*node)+1]) begin
              tree_value[node] = tree_value[(2*node)+2];
              tree_index[node] = tree_index[(2*node)+2];
            end else begin
              tree_value[node] = tree_value[(2*node)+1];
              tree_index[node] = tree_index[(2*node)+1];
            end
          end

          REDUCE_OP_MAX_S: begin
            if ($signed(tree_value[(2*node)+2]) >
                $signed(tree_value[(2*node)+1])) begin
              tree_value[node] = tree_value[(2*node)+2];
              tree_index[node] = tree_index[(2*node)+2];
            end else begin
              tree_value[node] = tree_value[(2*node)+1];
              tree_index[node] = tree_index[(2*node)+1];
            end
          end

          default: begin
            tree_value[node] = '0;
            tree_index[node] = '0;
            tree_valid[node] = 1'b0;
          end
        endcase
      end
    end

    valid_o = tree_valid[0] && !illegal_o;
    value_o = valid_o ? tree_value[0] : '0;
    index_o = valid_o ? tree_index[0] : '0;
  end

  initial begin
    if (LANES < 2) $error("LANES must be at least 2");
    if ((LANES & (LANES - 1)) != 0) begin
      $error("LANES must be a power of two");
    end
    if (DATA_W < 1) $error("DATA_W must be positive");
    if (ACC_W < (DATA_W + $clog2(LANES))) begin
      $error("ACC_W is too narrow for a full-lane sum");
    end
    if (INDEX_W != ((LANES <= 2) ? 1 : $clog2(LANES))) begin
      $error("INDEX_W must match LANES");
    end
  end
endmodule
