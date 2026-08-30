// Leaf reference for pairing dependent route fragments before execution.
// It owns no execution resource and is intentionally not integrated yet.
module vsp_route_rendezvous_table #(
  parameter int ENTRY_COUNT       = 4,
  parameter int CONTEXT_COUNT     = 2,
  parameter int EPOCH_W           = 4,
  parameter int ROUTE_ID_W        = 8,
  parameter int PARTICIPANT_COUNT = 2,
  parameter int TOKEN_W           = 8,
  parameter int PAYLOAD_W         = 32,
  parameter int CAUSE_W           = 4,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int PARTICIPANT_W = (PARTICIPANT_COUNT <= 2) ? 1 :
                                $clog2(PARTICIPANT_COUNT),
  parameter int INDEX_W = (ENTRY_COUNT <= 2) ? 1 : $clog2(ENTRY_COUNT),
  parameter int COUNT_W = (ENTRY_COUNT <= 1) ? 1 :
                          $clog2(ENTRY_COUNT + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic                         fragment_valid_i,
  output logic                         fragment_ready_o,
  input  logic                         fragment_legal_i,
  input  logic [CAUSE_W-1:0]           fragment_cause_i,
  input  logic [CONTEXT_W-1:0]         fragment_context_i,
  input  logic [EPOCH_W-1:0]           fragment_epoch_i,
  input  logic [ROUTE_ID_W-1:0]        fragment_route_id_i,
  // DEP_IN and DEP_OUT are the only collectable partial roles. Other route
  // modes become terminal rejects rather than waiting for a nonexistent peer.
  input  logic [vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W-1:0]
                                             fragment_role_i,
  input  logic [PARTICIPANT_W-1:0]     fragment_participant_i,
  input  logic [TOKEN_W-1:0]           fragment_retire_token_i,
  input  logic [PAYLOAD_W-1:0]         fragment_payload_i,

  // Frontier/token comparison is unsigned and valid only within one epoch.
  // Tokens must not wrap while any entry from that epoch remains live.
  input  logic [(PARTICIPANT_COUNT*TOKEN_W)-1:0]
                                               participant_frontier_i,

  // Exact epoch flush and epoch advance both release orphaned entries through
  // explicit CANCEL terminals rather than silently dropping accepted work.
  // Architectural order is retained in each opaque payload and enforced by
  // the downstream retirement path, not by this table's terminal arbitration.
  input  logic                         flush_valid_i,
  input  logic [CONTEXT_W-1:0]         flush_context_i,
  input  logic [EPOCH_W-1:0]           flush_epoch_i,
  input  logic                         epoch_advance_valid_i,
  input  logic [CONTEXT_W-1:0]         epoch_advance_context_i,
  input  logic [EPOCH_W-1:0]           epoch_advance_new_epoch_i,

  output logic                         terminal_valid_o,
  input  logic                         terminal_ready_i,
  // 0=WAVE, 1=REJECT, 2=CANCEL. REJECT wins if a fragment fault races a
  // cancellation. Once copied into this stall-stable terminal stage, a later
  // flush does not rewrite the terminal; downstream epoch handling owns it.
  output logic [1:0]                   terminal_kind_o,
  output logic [CAUSE_W-1:0]           terminal_cause_o,
  output logic [CONTEXT_W-1:0]         terminal_context_o,
  output logic [EPOCH_W-1:0]           terminal_epoch_o,
  output logic [ROUTE_ID_W-1:0]        terminal_route_id_o,
  output logic                         terminal_in_valid_o,
  output logic [PARTICIPANT_W-1:0]     terminal_in_participant_o,
  output logic [TOKEN_W-1:0]           terminal_in_token_o,
  output logic [PAYLOAD_W-1:0]         terminal_in_payload_o,
  output logic                         terminal_out_valid_o,
  output logic [PARTICIPANT_W-1:0]     terminal_out_participant_o,
  output logic [TOKEN_W-1:0]           terminal_out_token_o,
  output logic [PAYLOAD_W-1:0]         terminal_out_payload_o,
  // A malformed role or conflicting duplicate cannot replace an already
  // collected IN/OUT slot. Preserve that accepted fragment separately so a
  // downstream abort/reject path can retire every captured identity.
  output logic                         terminal_fault_valid_o,
  output logic [vsp_exec_uword_pkg::VSP_EXEC_ROUTE_IO_W-1:0]
                                             terminal_fault_role_o,
  output logic [PARTICIPANT_W-1:0]     terminal_fault_participant_o,
  output logic [TOKEN_W-1:0]           terminal_fault_token_o,
  output logic [PAYLOAD_W-1:0]         terminal_fault_payload_o,
  output logic [COUNT_W-1:0]           occupancy_o
);
  import vsp_exec_uword_pkg::*;

  localparam logic [1:0] TERM_WAVE   = 2'd0;
  localparam logic [1:0] TERM_REJECT = 2'd1;
  localparam logic [1:0] TERM_CANCEL = 2'd2;
  localparam logic [CAUSE_W-1:0] CAUSE_BAD_FRAGMENT = CAUSE_W'(1);
  localparam logic [CAUSE_W-1:0] CAUSE_ROLE_CONFLICT = CAUSE_W'(2);
  localparam logic [CAUSE_W-1:0] CAUSE_PARTICIPANT_CONFLICT = CAUSE_W'(3);

  logic valid_q [ENTRY_COUNT];
  logic in_valid_q [ENTRY_COUNT];
  logic out_valid_q [ENTRY_COUNT];
  logic reject_q [ENTRY_COUNT];
  logic cancel_q [ENTRY_COUNT];
  logic [CAUSE_W-1:0] cause_q [ENTRY_COUNT];
  logic [CONTEXT_W-1:0] context_q [ENTRY_COUNT];
  logic [EPOCH_W-1:0] epoch_q [ENTRY_COUNT];
  logic [ROUTE_ID_W-1:0] route_id_q [ENTRY_COUNT];
  logic [PARTICIPANT_W-1:0] in_participant_q [ENTRY_COUNT];
  logic [TOKEN_W-1:0] in_token_q [ENTRY_COUNT];
  logic [PAYLOAD_W-1:0] in_payload_q [ENTRY_COUNT];
  logic [PARTICIPANT_W-1:0] out_participant_q [ENTRY_COUNT];
  logic [TOKEN_W-1:0] out_token_q [ENTRY_COUNT];
  logic [PAYLOAD_W-1:0] out_payload_q [ENTRY_COUNT];
  logic fault_valid_q [ENTRY_COUNT];
  logic [VSP_EXEC_ROUTE_IO_W-1:0] fault_role_q [ENTRY_COUNT];
  logic [PARTICIPANT_W-1:0] fault_participant_q [ENTRY_COUNT];
  logic [TOKEN_W-1:0] fault_token_q [ENTRY_COUNT];
  logic [PAYLOAD_W-1:0] fault_payload_q [ENTRY_COUNT];

  logic key_found;
  logic free_found;
  logic [INDEX_W-1:0] key_index;
  logic [INDEX_W-1:0] free_index;
  logic terminal_found;
  logic [INDEX_W-1:0] terminal_index;
  logic terminal_capture;
  logic [INDEX_W-1:0] terminal_rr_q;
  logic [ENTRY_COUNT-1:0] entry_cancel_effective;
  logic fragment_cancel_now;
  logic terminal_key_busy;

  logic terminal_valid_q;
  logic [1:0] terminal_kind_q;
  logic [CAUSE_W-1:0] terminal_cause_q;
  logic [CONTEXT_W-1:0] terminal_context_q;
  logic [EPOCH_W-1:0] terminal_epoch_q;
  logic [ROUTE_ID_W-1:0] terminal_route_id_q;
  logic terminal_in_valid_q;
  logic [PARTICIPANT_W-1:0] terminal_in_participant_q;
  logic [TOKEN_W-1:0] terminal_in_token_q;
  logic [PAYLOAD_W-1:0] terminal_in_payload_q;
  logic terminal_out_valid_q;
  logic [PARTICIPANT_W-1:0] terminal_out_participant_q;
  logic [TOKEN_W-1:0] terminal_out_token_q;
  logic [PAYLOAD_W-1:0] terminal_out_payload_q;
  logic terminal_fault_valid_q;
  logic [VSP_EXEC_ROUTE_IO_W-1:0] terminal_fault_role_q;
  logic [PARTICIPANT_W-1:0] terminal_fault_participant_q;
  logic [TOKEN_W-1:0] terminal_fault_token_q;
  logic [PAYLOAD_W-1:0] terminal_fault_payload_q;

  function automatic integer wrap_index(input integer value);
    wrap_index = value % ENTRY_COUNT;
  endfunction

  // The frontier vector names globally monotonic participant streams.  If a
  // future profile numbers tokens per context, this input must gain a context
  // dimension; context/epoch matching alone cannot repair ambiguous tokens.
  function automatic logic token_reached(
      input logic [PARTICIPANT_W-1:0] participant,
      input logic [TOKEN_W-1:0] token);
    token_reached = int'(participant) < PARTICIPANT_COUNT &&
        participant_frontier_i[(int'(participant)*TOKEN_W) +: TOKEN_W] >=
            token;
  endfunction

  always_comb begin
    key_found = 1'b0;
    free_found = 1'b0;
    key_index = '0;
    free_index = '0;
    for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
      if (!key_found && valid_q[entry] &&
          context_q[entry] == fragment_context_i &&
          epoch_q[entry] == fragment_epoch_i &&
          route_id_q[entry] == fragment_route_id_i) begin
        key_found = 1'b1;
        key_index = INDEX_W'(entry);
      end
      if (!free_found && !valid_q[entry]) begin
        free_found = 1'b1;
        free_index = INDEX_W'(entry);
      end
    end

    terminal_key_busy = terminal_valid_q &&
        terminal_context_q == fragment_context_i &&
        terminal_epoch_q == fragment_epoch_i &&
        terminal_route_id_q == fragment_route_id_i;
    fragment_cancel_now =
        (flush_valid_i && fragment_context_i == flush_context_i &&
         fragment_epoch_i == flush_epoch_i) ||
        (epoch_advance_valid_i &&
         fragment_context_i == epoch_advance_context_i &&
         fragment_epoch_i != epoch_advance_new_epoch_i);
    // Once both roles are present, collection is closed even while retirement
    // frontiers delay terminal emission.  This avoids accepting a fragment in
    // the same cycle that the completed entry is captured and freed. A key in
    // terminal staging also remains reserved until its terminal is accepted.
    fragment_ready_o = rst_ni && !terminal_key_busy &&
        (key_found ? !(reject_q[key_index] ||
                       entry_cancel_effective[key_index] ||
                       (in_valid_q[key_index] && out_valid_q[key_index])) :
                     free_found);
  end

  always_comb begin
    for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
      entry_cancel_effective[entry] = cancel_q[entry] ||
          (flush_valid_i && valid_q[entry] &&
           context_q[entry] == flush_context_i &&
           epoch_q[entry] == flush_epoch_i) ||
          (epoch_advance_valid_i && valid_q[entry] &&
           context_q[entry] == epoch_advance_context_i &&
           epoch_q[entry] != epoch_advance_new_epoch_i);
    end

    terminal_found = 1'b0;
    terminal_index = '0;
    // Ready entries are drained round-robin. Architectural ordering remains
    // attached to each opaque participant payload; an unpaired older key must
    // not head-of-line block an independent reject, cancel, or complete wave.
    for (int offset = 0; offset < ENTRY_COUNT; offset++) begin
      logic [INDEX_W-1:0] entry;
      logic ready_entry;
      entry = INDEX_W'(wrap_index(int'(terminal_rr_q) + offset));
      ready_entry = valid_q[entry] &&
          (reject_q[entry] || entry_cancel_effective[entry] ||
           (in_valid_q[entry] && out_valid_q[entry] &&
            token_reached(in_participant_q[entry], in_token_q[entry]) &&
            token_reached(out_participant_q[entry], out_token_q[entry])));
      if (ready_entry && !terminal_found) begin
        terminal_found = 1'b1;
        terminal_index = entry;
      end
    end
    terminal_capture = terminal_found &&
                       (!terminal_valid_q || terminal_ready_i);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      terminal_rr_q <= '0;
      terminal_valid_q <= 1'b0;
      terminal_kind_q <= TERM_WAVE;
      terminal_cause_q <= '0;
      terminal_context_q <= '0;
      terminal_epoch_q <= '0;
      terminal_route_id_q <= '0;
      terminal_in_valid_q <= 1'b0;
      terminal_in_participant_q <= '0;
      terminal_in_token_q <= '0;
      terminal_in_payload_q <= '0;
      terminal_out_valid_q <= 1'b0;
      terminal_out_participant_q <= '0;
      terminal_out_token_q <= '0;
      terminal_out_payload_q <= '0;
      terminal_fault_valid_q <= 1'b0;
      terminal_fault_role_q <= '0;
      terminal_fault_participant_q <= '0;
      terminal_fault_token_q <= '0;
      terminal_fault_payload_q <= '0;
      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        valid_q[entry] <= 1'b0;
        in_valid_q[entry] <= 1'b0;
        out_valid_q[entry] <= 1'b0;
        reject_q[entry] <= 1'b0;
        cancel_q[entry] <= 1'b0;
        cause_q[entry] <= '0;
        fault_valid_q[entry] <= 1'b0;
        fault_role_q[entry] <= '0;
        fault_participant_q[entry] <= '0;
        fault_token_q[entry] <= '0;
        fault_payload_q[entry] <= '0;
      end
    end else begin
      if (terminal_valid_q && terminal_ready_i) terminal_valid_q <= 1'b0;

      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        if (flush_valid_i && valid_q[entry] &&
            context_q[entry] == flush_context_i &&
            epoch_q[entry] == flush_epoch_i) begin
          cancel_q[entry] <= 1'b1;
        end
        if (epoch_advance_valid_i && valid_q[entry] &&
            context_q[entry] == epoch_advance_context_i &&
            epoch_q[entry] != epoch_advance_new_epoch_i) begin
          cancel_q[entry] <= 1'b1;
        end
      end

      if (fragment_valid_i && fragment_ready_o) begin
        logic [INDEX_W-1:0] entry;
        logic role_valid;
        logic context_valid;
        logic participant_valid;
        logic role_occupied;
        logic duplicate_match;
        entry = key_found ? key_index : free_index;
        role_valid = vsp_exec_route_mode_pair_required(fragment_role_i);
        context_valid = int'(fragment_context_i) < CONTEXT_COUNT;
        participant_valid = int'(fragment_participant_i) <
                            PARTICIPANT_COUNT;
        role_occupied = 1'b0;
        duplicate_match = 1'b0;

        if (!key_found) begin
          valid_q[entry] <= 1'b1;
          in_valid_q[entry] <= 1'b0;
          out_valid_q[entry] <= 1'b0;
          reject_q[entry] <= !fragment_legal_i || !role_valid ||
              int'(fragment_context_i) >= CONTEXT_COUNT ||
              !participant_valid;
          cancel_q[entry] <= fragment_cancel_now;
          cause_q[entry] <= !fragment_legal_i ? fragment_cause_i :
              ((!role_valid ||
                int'(fragment_context_i) >= CONTEXT_COUNT ||
                int'(fragment_participant_i) >= PARTICIPANT_COUNT) ?
                   CAUSE_BAD_FRAGMENT : '0);
          context_q[entry] <= fragment_context_i;
          epoch_q[entry] <= fragment_epoch_i;
          route_id_q[entry] <= fragment_route_id_i;
          in_participant_q[entry] <= '0;
          in_token_q[entry] <= '0;
          in_payload_q[entry] <= '0;
          out_participant_q[entry] <= '0;
          out_token_q[entry] <= '0;
          out_payload_q[entry] <= '0;
          fault_valid_q[entry] <= 1'b0;
          fault_role_q[entry] <= '0;
          fault_participant_q[entry] <= '0;
          fault_token_q[entry] <= '0;
          fault_payload_q[entry] <= '0;
        end

        if (!role_valid) begin
          reject_q[entry] <= 1'b1;
          cause_q[entry] <= !fragment_legal_i ? fragment_cause_i :
                                                   CAUSE_BAD_FRAGMENT;
          fault_valid_q[entry] <= 1'b1;
          fault_role_q[entry] <= fragment_role_i;
          fault_participant_q[entry] <= fragment_participant_i;
          fault_token_q[entry] <= fragment_retire_token_i;
          fault_payload_q[entry] <= fragment_payload_i;
        end else begin
          if (fragment_role_i == VSP_EXEC_ROUTE_IO_DEP_IN) begin
            role_occupied = key_found && in_valid_q[entry];
            duplicate_match = role_occupied &&
                in_participant_q[entry] == fragment_participant_i &&
                in_token_q[entry] == fragment_retire_token_i &&
                in_payload_q[entry] == fragment_payload_i;
          end else begin
            role_occupied = key_found && out_valid_q[entry];
            duplicate_match = role_occupied &&
                out_participant_q[entry] == fragment_participant_i &&
                out_token_q[entry] == fragment_retire_token_i &&
                out_payload_q[entry] == fragment_payload_i;
          end

          if (!fragment_legal_i || !context_valid || !participant_valid) begin
            reject_q[entry] <= 1'b1;
            cause_q[entry] <= !fragment_legal_i ? fragment_cause_i :
                                                     CAUSE_BAD_FRAGMENT;
            if (role_occupied) begin
              fault_valid_q[entry] <= 1'b1;
              fault_role_q[entry] <= fragment_role_i;
              fault_participant_q[entry] <= fragment_participant_i;
              fault_token_q[entry] <= fragment_retire_token_i;
              fault_payload_q[entry] <= fragment_payload_i;
            end else if (fragment_role_i == VSP_EXEC_ROUTE_IO_DEP_IN) begin
              in_valid_q[entry] <= 1'b1;
              in_participant_q[entry] <= fragment_participant_i;
              in_token_q[entry] <= fragment_retire_token_i;
              in_payload_q[entry] <= fragment_payload_i;
            end else begin
              out_valid_q[entry] <= 1'b1;
              out_participant_q[entry] <= fragment_participant_i;
              out_token_q[entry] <= fragment_retire_token_i;
              out_payload_q[entry] <= fragment_payload_i;
            end
          end else if (!role_occupied) begin
            if (fragment_role_i == VSP_EXEC_ROUTE_IO_DEP_IN) begin
              in_valid_q[entry] <= 1'b1;
              in_participant_q[entry] <= fragment_participant_i;
              in_token_q[entry] <= fragment_retire_token_i;
              in_payload_q[entry] <= fragment_payload_i;
              if (key_found && out_valid_q[entry] &&
                  out_participant_q[entry] == fragment_participant_i) begin
                reject_q[entry] <= 1'b1;
                cause_q[entry] <= CAUSE_PARTICIPANT_CONFLICT;
              end
            end else begin
              out_valid_q[entry] <= 1'b1;
              out_participant_q[entry] <= fragment_participant_i;
              out_token_q[entry] <= fragment_retire_token_i;
              out_payload_q[entry] <= fragment_payload_i;
              if (key_found && in_valid_q[entry] &&
                  in_participant_q[entry] == fragment_participant_i) begin
                reject_q[entry] <= 1'b1;
                cause_q[entry] <= CAUSE_PARTICIPANT_CONFLICT;
              end
            end
          end else if (!duplicate_match) begin
            // A second distinct action cannot overwrite the first role slot.
            // Preserve it in the fault slot so no accepted identity vanishes.
            reject_q[entry] <= 1'b1;
            cause_q[entry] <= CAUSE_ROLE_CONFLICT;
            fault_valid_q[entry] <= 1'b1;
            fault_role_q[entry] <= fragment_role_i;
            fault_participant_q[entry] <= fragment_participant_i;
            fault_token_q[entry] <= fragment_retire_token_i;
            fault_payload_q[entry] <= fragment_payload_i;
          end
          // An exact descriptor replay falls through idempotently and creates
          // no second retirement obligation. Distinct architectural actions
          // must use a distinct key and/or payload identity.
        end

        if (fragment_cancel_now) cancel_q[entry] <= 1'b1;
      end

      if (terminal_capture) begin
        terminal_valid_q <= 1'b1;
        terminal_kind_q <= reject_q[terminal_index] ? TERM_REJECT :
                           (entry_cancel_effective[terminal_index] ?
                                TERM_CANCEL : TERM_WAVE);
        terminal_cause_q <= cause_q[terminal_index];
        terminal_context_q <= context_q[terminal_index];
        terminal_epoch_q <= epoch_q[terminal_index];
        terminal_route_id_q <= route_id_q[terminal_index];
        terminal_in_valid_q <= in_valid_q[terminal_index];
        terminal_in_participant_q <= in_participant_q[terminal_index];
        terminal_in_token_q <= in_token_q[terminal_index];
        terminal_in_payload_q <= in_payload_q[terminal_index];
        terminal_out_valid_q <= out_valid_q[terminal_index];
        terminal_out_participant_q <= out_participant_q[terminal_index];
        terminal_out_token_q <= out_token_q[terminal_index];
        terminal_out_payload_q <= out_payload_q[terminal_index];
        terminal_fault_valid_q <= fault_valid_q[terminal_index];
        terminal_fault_role_q <= fault_role_q[terminal_index];
        terminal_fault_participant_q <=
            fault_participant_q[terminal_index];
        terminal_fault_token_q <= fault_token_q[terminal_index];
        terminal_fault_payload_q <= fault_payload_q[terminal_index];
        valid_q[terminal_index] <= 1'b0;
        in_valid_q[terminal_index] <= 1'b0;
        out_valid_q[terminal_index] <= 1'b0;
        reject_q[terminal_index] <= 1'b0;
        cancel_q[terminal_index] <= 1'b0;
        fault_valid_q[terminal_index] <= 1'b0;
        terminal_rr_q <= INDEX_W'(
            wrap_index(int'(terminal_index) + 1));
      end
    end
  end

  always_comb begin
    int unsigned count;
    count = 0;
    for (int entry = 0; entry < ENTRY_COUNT; entry++)
      if (valid_q[entry]) count++;
    occupancy_o = COUNT_W'(count);
  end

  assign terminal_valid_o = terminal_valid_q;
  assign terminal_kind_o = terminal_kind_q;
  assign terminal_cause_o = terminal_cause_q;
  assign terminal_context_o = terminal_context_q;
  assign terminal_epoch_o = terminal_epoch_q;
  assign terminal_route_id_o = terminal_route_id_q;
  assign terminal_in_valid_o = terminal_in_valid_q;
  assign terminal_in_participant_o = terminal_in_participant_q;
  assign terminal_in_token_o = terminal_in_token_q;
  assign terminal_in_payload_o = terminal_in_payload_q;
  assign terminal_out_valid_o = terminal_out_valid_q;
  assign terminal_out_participant_o = terminal_out_participant_q;
  assign terminal_out_token_o = terminal_out_token_q;
  assign terminal_out_payload_o = terminal_out_payload_q;
  assign terminal_fault_valid_o = terminal_fault_valid_q;
  assign terminal_fault_role_o = terminal_fault_role_q;
  assign terminal_fault_participant_o = terminal_fault_participant_q;
  assign terminal_fault_token_o = terminal_fault_token_q;
  assign terminal_fault_payload_o = terminal_fault_payload_q;

  initial begin
    if (ENTRY_COUNT < 1) $error("ENTRY_COUNT must be positive");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (PARTICIPANT_COUNT < 2)
      $error("PARTICIPANT_COUNT must be at least two");
    if (EPOCH_W < 1 || ROUTE_ID_W < 1 || TOKEN_W < 1 || PAYLOAD_W < 1 ||
        CAUSE_W < 1)
      $error("epoch, route ID, token, payload and cause widths must be positive");
    if (CONTEXT_W != ((CONTEXT_COUNT <= 2) ? 1 :
                      $clog2(CONTEXT_COUNT)))
      $error("CONTEXT_W must match CONTEXT_COUNT");
    if (PARTICIPANT_W != ((PARTICIPANT_COUNT <= 2) ? 1 :
                          $clog2(PARTICIPANT_COUNT)))
      $error("PARTICIPANT_W must match PARTICIPANT_COUNT");
    if (INDEX_W != ((ENTRY_COUNT <= 2) ? 1 : $clog2(ENTRY_COUNT)))
      $error("INDEX_W must match ENTRY_COUNT");
    if (COUNT_W != ((ENTRY_COUNT <= 1) ? 1 :
                    $clog2(ENTRY_COUNT + 1)))
      $error("COUNT_W must match ENTRY_COUNT");
  end
endmodule
