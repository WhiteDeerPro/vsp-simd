module simd_issue_queue #(
  parameter int CONTEXT_COUNT = 4,
  parameter int DEPTH         = 4,
  parameter int TAG_W         = 8,
  parameter int UWORD_W       = 32,
  parameter int RESOLVED_W    = 16,
  parameter int SCHED_META_W  = 16,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int PTR_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
  parameter int COUNT_W = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // One admission lane is enough to establish the queue contract. A future
  // controller may arbitrate several sequencers before this port or replicate
  // the admission lane without changing the per-context head interface.
  // The integration contract requires sched_meta_i to come from a trusted
  // hardware predecoder, not from an independently programmable resource
  // declaration. That predecoder is not part of this FIFO module.
  input  logic                         enq_valid_i,
  output logic                         enq_ready_o,
  input  logic [CONTEXT_W-1:0]         enq_context_i,
  input  logic [TAG_W-1:0]             enq_tag_i,
  input  logic [UWORD_W-1:0]           enq_uword_i,
  input  logic [RESOLVED_W-1:0]        enq_resolved_i,
  input  logic [SCHED_META_W-1:0]      enq_sched_meta_i,
  // Invalid non-power-of-two context encodings are not consumed. The
  // admission/reject stage, rather than this raw FIFO, owns ordered error
  // completion generation.
  output logic                         enq_context_error_o,

  // Every context exposes one ordered head. Different contexts may transfer
  // in the same cycle; one context never exposes a younger entry alongside
  // its head. There is no empty-queue fall-through: a newly enqueued entry
  // becomes visible after the committing edge. head_ready_i means final
  // dequeue/ownership release, not scheduler selection or a shadow-slot load.
  // A locked-shadow controller asserts it only when the selected engine fires
  // or an error record is actually accepted.
  output logic [CONTEXT_COUNT-1:0]                 head_valid_o,
  input  logic [CONTEXT_COUNT-1:0]                 head_ready_i,
  output logic [(CONTEXT_COUNT*TAG_W)-1:0]         head_tag_o,
  output logic [(CONTEXT_COUNT*UWORD_W)-1:0]       head_uword_o,
  output logic [(CONTEXT_COUNT*RESOLVED_W)-1:0]    head_resolved_o,
  output logic [(CONTEXT_COUNT*SCHED_META_W)-1:0]  head_sched_meta_o,

  output logic [CONTEXT_COUNT-1:0]                 full_o,
  output logic [(CONTEXT_COUNT*COUNT_W)-1:0]       occupancy_o
);
  logic [PTR_W-1:0] read_ptr_q [0:CONTEXT_COUNT-1];
  logic [PTR_W-1:0] write_ptr_q [0:CONTEXT_COUNT-1];
  logic [COUNT_W-1:0] count_q [0:CONTEXT_COUNT-1];

  logic [TAG_W-1:0] tag_mem [0:CONTEXT_COUNT-1][0:DEPTH-1];
  logic [UWORD_W-1:0] uword_mem [0:CONTEXT_COUNT-1][0:DEPTH-1];
  logic [RESOLVED_W-1:0] resolved_mem [0:CONTEXT_COUNT-1][0:DEPTH-1];
  logic [SCHED_META_W-1:0]
      sched_meta_mem [0:CONTEXT_COUNT-1][0:DEPTH-1];

  logic [CONTEXT_COUNT-1:0] head_fire;
  logic enq_context_valid;
  logic enq_fire;

  function automatic logic [PTR_W-1:0] increment_ptr(
      input logic [PTR_W-1:0] pointer);
    if (int'(pointer) == (DEPTH - 1)) increment_ptr = '0;
    else increment_ptr = pointer + 1'b1;
  endfunction

  always_comb begin
    head_valid_o = '0;
    head_tag_o = '0;
    head_uword_o = '0;
    head_resolved_o = '0;
    head_sched_meta_o = '0;
    full_o = '0;
    occupancy_o = '0;

    for (int ctx = 0; ctx < CONTEXT_COUNT; ctx++) begin
      head_valid_o[ctx] = count_q[ctx] != 0;
      full_o[ctx] = int'(count_q[ctx]) == DEPTH;
      occupancy_o[(ctx*COUNT_W) +: COUNT_W] = count_q[ctx];

      if (count_q[ctx] != 0) begin
        head_tag_o[(ctx*TAG_W) +: TAG_W] =
            tag_mem[ctx][read_ptr_q[ctx]];
        head_uword_o[(ctx*UWORD_W) +: UWORD_W] =
            uword_mem[ctx][read_ptr_q[ctx]];
        head_resolved_o[(ctx*RESOLVED_W) +: RESOLVED_W] =
            resolved_mem[ctx][read_ptr_q[ctx]];
        head_sched_meta_o[(ctx*SCHED_META_W) +: SCHED_META_W] =
            sched_meta_mem[ctx][read_ptr_q[ctx]];
      end
    end
  end

  assign head_fire = head_valid_o & head_ready_i;
  assign enq_context_valid = int'(enq_context_i) < CONTEXT_COUNT;

  always_comb begin
    enq_ready_o = 1'b0;
    if (rst_ni && enq_context_valid) begin
      enq_ready_o = !full_o[int'(enq_context_i)] ||
                    head_fire[int'(enq_context_i)];
    end
  end

  assign enq_fire = enq_valid_i && enq_ready_o;
  assign enq_context_error_o = rst_ni && enq_valid_i &&
                               !enq_context_valid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int ctx = 0; ctx < CONTEXT_COUNT; ctx++) begin
        read_ptr_q[ctx] <= '0;
        write_ptr_q[ctx] <= '0;
        count_q[ctx] <= '0;
      end
    end else begin
      for (int ctx = 0; ctx < CONTEXT_COUNT; ctx++) begin
        logic push_this_context;
        push_this_context = enq_fire &&
                            (int'(enq_context_i) == ctx);

        unique case ({push_this_context, head_fire[ctx]})
          2'b01: count_q[ctx] <= count_q[ctx] - 1'b1;
          2'b10: count_q[ctx] <= count_q[ctx] + 1'b1;
          default: count_q[ctx] <= count_q[ctx];
        endcase

        if (head_fire[ctx]) begin
          read_ptr_q[ctx] <= increment_ptr(read_ptr_q[ctx]);
        end

        if (push_this_context) begin
          tag_mem[ctx][write_ptr_q[ctx]] <= enq_tag_i;
          uword_mem[ctx][write_ptr_q[ctx]] <= enq_uword_i;
          resolved_mem[ctx][write_ptr_q[ctx]] <= enq_resolved_i;
          sched_meta_mem[ctx][write_ptr_q[ctx]] <=
              enq_sched_meta_i;
          write_ptr_q[ctx] <= increment_ptr(write_ptr_q[ctx]);
        end
      end
    end
  end

  initial begin
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (DEPTH < 1) $error("DEPTH must be positive");
    if (TAG_W < 1 || UWORD_W < 1 || RESOLVED_W < 1 || SCHED_META_W < 1) begin
      $error("queue entry field widths must be positive");
    end
    if (CONTEXT_W != ((CONTEXT_COUNT <= 2) ? 1 :
                       $clog2(CONTEXT_COUNT))) begin
      $error("CONTEXT_W must match CONTEXT_COUNT");
    end
    if (PTR_W != ((DEPTH <= 1) ? 1 : $clog2(DEPTH))) begin
      $error("PTR_W must match DEPTH");
    end
    if (COUNT_W != ((DEPTH <= 1) ? 1 : $clog2(DEPTH + 1))) begin
      $error("COUNT_W must represent values zero through DEPTH");
    end
  end
endmodule
