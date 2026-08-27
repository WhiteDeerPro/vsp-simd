module benes_network #(
  parameter int PORTS  = 4,
  parameter int DATA_W = 8
) (
  input  logic [(PORTS*DATA_W)-1:0] data_i,
  input  logic [(((2*$clog2(PORTS))-1)*(PORTS/2))-1:0] ctrl_i,
  output logic [(PORTS*DATA_W)-1:0] data_o
);
  localparam int LOG_PORTS = $clog2(PORTS);
  localparam int STAGES = (2 * LOG_PORTS) - 1;
  localparam int SWITCHES_PER_STAGE = PORTS / 2;

  typedef logic [(PORTS*DATA_W)-1:0] network_bus_t;
  // Every generated slice is feed-forward. Verilator 4.x merges the unpacked
  // arrays into one lint node and reports a false combinational feedback path.
  /* verilator lint_off UNOPTFLAT */
  network_bus_t stage_input [0:STAGES-1];
  network_bus_t stage_switched [0:STAGES-1];
  /* verilator lint_on UNOPTFLAT */

  assign stage_input[0] = data_i;

  generate
    for (genvar stage = 0; stage < STAGES; stage++) begin : gen_stage
      for (genvar sw = 0; sw < SWITCHES_PER_STAGE; sw++) begin : gen_switch
        localparam int CTRL_INDEX = (stage * SWITCHES_PER_STAGE) + sw;
        localparam int EVEN_PORT = 2 * sw;
        localparam int ODD_PORT = EVEN_PORT + 1;

        assign stage_switched[stage][(EVEN_PORT*DATA_W) +: DATA_W] =
            ctrl_i[CTRL_INDEX]
                ? stage_input[stage][(ODD_PORT*DATA_W) +: DATA_W]
                : stage_input[stage][(EVEN_PORT*DATA_W) +: DATA_W];
        assign stage_switched[stage][(ODD_PORT*DATA_W) +: DATA_W] =
            ctrl_i[CTRL_INDEX]
                ? stage_input[stage][(EVEN_PORT*DATA_W) +: DATA_W]
                : stage_input[stage][(ODD_PORT*DATA_W) +: DATA_W];
      end

      if (stage < (STAGES - 1)) begin : gen_interstage
        for (genvar link = 0; link < PORTS; link++) begin : gen_link
          if (stage < (LOG_PORTS - 1)) begin : gen_forward_shuffle
            localparam int NEXT_LINK =
                ((link << 1) & (PORTS - 1)) | (link >> (LOG_PORTS - 1));
            assign stage_input[stage+1][(NEXT_LINK*DATA_W) +: DATA_W] =
                stage_switched[stage][(link*DATA_W) +: DATA_W];
          end else begin : gen_reverse_shuffle
            localparam int NEXT_LINK =
                (link >> 1) | ((link & 1) << (LOG_PORTS - 1));
            assign stage_input[stage+1][(NEXT_LINK*DATA_W) +: DATA_W] =
                stage_switched[stage][(link*DATA_W) +: DATA_W];
          end
        end
      end
    end
  endgenerate

  assign data_o = stage_switched[STAGES-1];

  initial begin
    if (PORTS < 2) $error("PORTS must be at least 2");
    if ((PORTS & (PORTS - 1)) != 0) begin
      $error("PORTS must be a power of two");
    end
    if (DATA_W < 1) $error("DATA_W must be positive");
  end
endmodule
