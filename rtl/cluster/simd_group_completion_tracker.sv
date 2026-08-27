module simd_group_completion_tracker #(
  // The first integration profile has four SIMD4 groups and two issue slots.
  // Entry count is an implementation capacity, not an instruction-set limit.
  parameter int GROUP_COUNT     = 4,
  parameter int ALLOC_SLOTS     = 2,
  parameter int CONTEXT_COUNT   = 2,
  parameter int TAG_W           = 8,
  parameter int ENTRY_COUNT     = 4,
  parameter int CONTEXT_W = (CONTEXT_COUNT <= 2) ? 1 :
                            $clog2(CONTEXT_COUNT),
  parameter int ENTRY_W = (ENTRY_COUNT <= 2) ? 1 : $clog2(ENTRY_COUNT),
  parameter int COUNT_W = (ENTRY_COUNT <= 1) ? 1 :
                          $clog2(ENTRY_COUNT + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,

  // alloc_valid_i presents stable candidate metadata independently of ready.
  // The shell includes alloc_ready_o in final resource arbitration, then
  // pulses alloc_commit_i exactly when that same command atomically fires to
  // its groups. Splitting eligibility from commit prevents tracker-only issue.
  input  logic [ALLOC_SLOTS-1:0]                     alloc_valid_i,
  output logic [ALLOC_SLOTS-1:0]                     alloc_ready_o,
  input  logic [ALLOC_SLOTS-1:0]                     alloc_commit_i,
  input  logic [(ALLOC_SLOTS*CONTEXT_W)-1:0]         alloc_context_i,
  input  logic [(ALLOC_SLOTS*TAG_W)-1:0]             alloc_tag_i,
  input  logic [(ALLOC_SLOTS*GROUP_COUNT)-1:0]       alloc_group_mask_i,
  input  logic [(ALLOC_SLOTS*GROUP_COUNT)-1:0]       alloc_result_mask_i,
  output logic [ALLOC_SLOTS-1:0]                     alloc_error_o,
  output logic [ALLOC_SLOTS-1:0]                     alloc_tag_busy_o,
  output logic [ALLOC_SLOTS-1:0]                     alloc_no_space_o,
  output logic [ALLOC_SLOTS-1:0]                     alloc_commit_error_o,

  // One completion lane is physically associated with each group, so the
  // lane number is the child group_id. Only GROUP_EXEC child completions are
  // routed here; state-write/MEMORY children use their own parent tracker.
  input  logic [GROUP_COUNT-1:0]                     child_cpl_valid_i,
  output logic [GROUP_COUNT-1:0]                     child_cpl_ready_o,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]         child_cpl_context_i,
  input  logic [(GROUP_COUNT*TAG_W)-1:0]             child_cpl_tag_i,
  input  logic [GROUP_COUNT-1:0]                     child_cpl_illegal_i,
  input  logic [GROUP_COUNT-1:0]                     child_cpl_has_result_i,
  output logic [GROUP_COUNT-1:0]                     child_cpl_unknown_o,
  output logic [GROUP_COUNT-1:0]                     child_cpl_wrong_group_o,
  output logic [GROUP_COUNT-1:0]                     child_cpl_duplicate_o,
  output logic [GROUP_COUNT-1:0]                     child_cpl_result_mismatch_o,

  // A result-retire pulse is an observation of a successful handshake at the
  // independent group-result collector. It is not the result payload itself.
  input  logic [GROUP_COUNT-1:0]                     child_rsp_retire_i,
  input  logic [(GROUP_COUNT*CONTEXT_W)-1:0]         child_rsp_context_i,
  input  logic [(GROUP_COUNT*TAG_W)-1:0]             child_rsp_tag_i,
  output logic [GROUP_COUNT-1:0]                     child_rsp_unknown_o,
  output logic [GROUP_COUNT-1:0]                     child_rsp_wrong_group_o,
  output logic [GROUP_COUNT-1:0]                     child_rsp_duplicate_o,

  // This output means every requested group child completion was accepted.
  // It does not carry result data. The entry remains tag-busy after this
  // handshake until every expected result record has independently retired.
  output logic                                       cmd_cpl_valid_o,
  input  logic                                       cmd_cpl_ready_i,
  output logic [CONTEXT_W-1:0]                       cmd_cpl_context_o,
  output logic [TAG_W-1:0]                           cmd_cpl_tag_o,
  output logic [GROUP_COUNT-1:0]                     cmd_cpl_group_mask_o,
  // Reconciled result obligation after every child has reported
  // has_result; it may differ from admission metadata only on protocol fault.
  output logic [GROUP_COUNT-1:0]                     cmd_cpl_result_mask_o,
  output logic                                       cmd_cpl_illegal_o,
  output logic [GROUP_COUNT-1:0]                     cmd_cpl_illegal_group_mask_o,

  // Quiescent observes execution children only. tag_busy also includes a
  // command whose completion was reported while result records remain live.
  output logic [CONTEXT_COUNT-1:0]                   context_exec_inflight_o,
  output logic [CONTEXT_COUNT-1:0]                   context_tag_busy_o,
  output logic [CONTEXT_COUNT-1:0]                   context_quiescent_o,
  output logic [ENTRY_COUNT-1:0]                     entries_active_o,
  output logic                                       full_o,
  output logic [COUNT_W-1:0]                         occupancy_o,

  input  logic                                       protocol_error_clear_i,
  output logic                                       protocol_error_o
);
  logic [ENTRY_COUNT-1:0] entry_valid_q;
  logic [CONTEXT_W-1:0] entry_context_q [0:ENTRY_COUNT-1];
  logic [TAG_W-1:0] entry_tag_q [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] entry_group_mask_q [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] entry_result_mask_q [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] entry_pending_cpl_q [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] entry_rsp_seen_q [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0]
      entry_illegal_group_mask_q [0:ENTRY_COUNT-1];
  logic [ENTRY_COUNT-1:0] entry_completion_reported_q;

  logic [ENTRY_W-1:0] alloc_entry_index [0:ALLOC_SLOTS-1];
  logic [GROUP_COUNT-1:0] cpl_clear_by_entry [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] cpl_illegal_by_entry [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] cpl_result_update_by_entry [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] cpl_result_value_by_entry [0:ENTRY_COUNT-1];
  logic [GROUP_COUNT-1:0] rsp_seen_by_entry [0:ENTRY_COUNT-1];

  logic done_hold_valid_q;
  logic [ENTRY_W-1:0] done_hold_index_q;
  logic [ENTRY_W-1:0] done_rr_q;
  logic done_select_valid;
  logic [ENTRY_W-1:0] done_select_index;
  logic cmd_cpl_fire;
  logic protocol_fault;

  function automatic logic [ENTRY_W-1:0] increment_entry(
      input logic [ENTRY_W-1:0] entry_id);
    if (int'(entry_id) == (ENTRY_COUNT - 1)) increment_entry = '0;
    else increment_entry = entry_id + 1'b1;
  endfunction

  // Allocate distinct free entries to the valid slots in deterministic slot
  // order. A live context+tag remains busy until both its command completion
  // is reported and all expected result records retire.
  always_comb begin
    logic [ENTRY_COUNT-1:0] free_reserved;

    alloc_ready_o = '0;
    alloc_error_o = '0;
    alloc_tag_busy_o = '0;
    alloc_no_space_o = '0;
    free_reserved = '0;

    for (int slot = 0; slot < ALLOC_SLOTS; slot++) begin
      logic [CONTEXT_W-1:0] request_context;
      logic [TAG_W-1:0] request_tag;
      logic [GROUP_COUNT-1:0] request_group_mask;
      logic [GROUP_COUNT-1:0] request_result_mask;
      logic fields_valid;
      logic key_busy;
      logic free_found;

      request_context = alloc_context_i[
          (slot*CONTEXT_W) +: CONTEXT_W];
      request_tag = alloc_tag_i[(slot*TAG_W) +: TAG_W];
      request_group_mask = alloc_group_mask_i[
          (slot*GROUP_COUNT) +: GROUP_COUNT];
      request_result_mask = alloc_result_mask_i[
          (slot*GROUP_COUNT) +: GROUP_COUNT];
      fields_valid = (int'(request_context) < CONTEXT_COUNT) &&
                     (|request_group_mask) &&
                     !(|(request_result_mask & ~request_group_mask));
      key_busy = 1'b0;
      free_found = 1'b0;
      alloc_entry_index[slot] = '0;

      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        if (entry_valid_q[entry] &&
            entry_context_q[entry] == request_context &&
            entry_tag_q[entry] == request_tag) begin
          key_busy = 1'b1;
        end
      end

      for (int prior = 0; prior < ALLOC_SLOTS; prior++) begin
        if (prior < slot && alloc_valid_i[prior] &&
            alloc_ready_o[prior] &&
            alloc_context_i[(prior*CONTEXT_W) +: CONTEXT_W] ==
                request_context &&
            alloc_tag_i[(prior*TAG_W) +: TAG_W] == request_tag) begin
          key_busy = 1'b1;
        end
      end

      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        if (!free_found && !entry_valid_q[entry] &&
            !free_reserved[entry]) begin
          free_found = 1'b1;
          alloc_entry_index[slot] = ENTRY_W'(entry);
        end
      end

      if (rst_ni && fields_valid && !key_busy && free_found) begin
        alloc_ready_o[slot] = 1'b1;
      end
      alloc_error_o[slot] = alloc_valid_i[slot] && !fields_valid;
      alloc_tag_busy_o[slot] = alloc_valid_i[slot] && fields_valid &&
                               key_busy;
      alloc_no_space_o[slot] = alloc_valid_i[slot] && fields_valid &&
                               !key_busy && !free_found;
      if (alloc_valid_i[slot] && alloc_ready_o[slot]) begin
        free_reserved[int'(alloc_entry_index[slot])] = 1'b1;
      end
    end
  end

  // Keep the commit-protocol check outside the allocation chooser.  The
  // enclosing cluster intentionally feeds alloc_ready into dispatch and
  // dispatch accept back into alloc_commit; mixing this diagnostic into the
  // same combinational block would create an artificial ready/commit loop
  // even though entry selection does not semantically depend on commit.
  always_comb begin
    alloc_commit_error_o = '0;
    for (int slot = 0; slot < ALLOC_SLOTS; slot++) begin
      alloc_commit_error_o[slot] = rst_ni && alloc_commit_i[slot] &&
                                   !(alloc_valid_i[slot] &&
                                     alloc_ready_o[slot]);
    end
  end

  // Child completion records are always drainable after reset because their
  // scoreboard capacity was reserved at command allocation. Protocol-invalid
  // records are consumed and reported rather than wedging a group forever.
  always_comb begin
    child_cpl_ready_o = rst_ni ? {GROUP_COUNT{1'b1}} : '0;
    child_cpl_unknown_o = '0;
    child_cpl_wrong_group_o = '0;
    child_cpl_duplicate_o = '0;
    child_cpl_result_mismatch_o = '0;
    child_rsp_unknown_o = '0;
    child_rsp_wrong_group_o = '0;
    child_rsp_duplicate_o = '0;

    for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
      cpl_clear_by_entry[entry] = '0;
      cpl_illegal_by_entry[entry] = '0;
      cpl_result_update_by_entry[entry] = '0;
      cpl_result_value_by_entry[entry] = '0;
      rsp_seen_by_entry[entry] = '0;
    end

    for (int group = 0; group < GROUP_COUNT; group++) begin
      logic [CONTEXT_W-1:0] cpl_context;
      logic [TAG_W-1:0] cpl_tag;
      logic cpl_key_found;
      logic [ENTRY_W-1:0] cpl_entry;
      logic [CONTEXT_W-1:0] rsp_context;
      logic [TAG_W-1:0] rsp_tag;
      logic rsp_key_found;
      logic [ENTRY_W-1:0] rsp_entry;

      cpl_context = child_cpl_context_i[
          (group*CONTEXT_W) +: CONTEXT_W];
      cpl_tag = child_cpl_tag_i[(group*TAG_W) +: TAG_W];
      cpl_key_found = 1'b0;
      cpl_entry = 0;
      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        if (!cpl_key_found && entry_valid_q[entry] &&
            entry_context_q[entry] == cpl_context &&
            entry_tag_q[entry] == cpl_tag) begin
          cpl_key_found = 1'b1;
          cpl_entry = ENTRY_W'(entry);
        end
      end

      if (rst_ni && child_cpl_valid_i[group]) begin
        if (!cpl_key_found) begin
          child_cpl_unknown_o[group] = 1'b1;
        end else if (!entry_group_mask_q[int'(cpl_entry)][group]) begin
          child_cpl_wrong_group_o[group] = 1'b1;
        end else if (!entry_pending_cpl_q[int'(cpl_entry)][group]) begin
          child_cpl_duplicate_o[group] = 1'b1;
        end else begin
          logic result_mismatch;

          result_mismatch = child_cpl_has_result_i[group] !=
                            entry_result_mask_q[int'(cpl_entry)][group];
          cpl_clear_by_entry[int'(cpl_entry)][group] = 1'b1;
          cpl_illegal_by_entry[int'(cpl_entry)][group] =
              child_cpl_illegal_i[group] || result_mismatch;
          cpl_result_update_by_entry[int'(cpl_entry)][group] = 1'b1;
          cpl_result_value_by_entry[int'(cpl_entry)][group] =
              child_cpl_has_result_i[group];
          child_cpl_result_mismatch_o[group] = result_mismatch;
        end
      end

      rsp_context = child_rsp_context_i[
          (group*CONTEXT_W) +: CONTEXT_W];
      rsp_tag = child_rsp_tag_i[(group*TAG_W) +: TAG_W];
      rsp_key_found = 1'b0;
      rsp_entry = 0;
      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        if (!rsp_key_found && entry_valid_q[entry] &&
            entry_context_q[entry] == rsp_context &&
            entry_tag_q[entry] == rsp_tag) begin
          rsp_key_found = 1'b1;
          rsp_entry = ENTRY_W'(entry);
        end
      end

      if (rst_ni && child_rsp_retire_i[group]) begin
        if (!rsp_key_found) begin
          child_rsp_unknown_o[group] = 1'b1;
        end else if (!entry_group_mask_q[int'(rsp_entry)][group]) begin
          child_rsp_wrong_group_o[group] = 1'b1;
        end else if (entry_rsp_seen_q[int'(rsp_entry)][group]) begin
          child_rsp_duplicate_o[group] = 1'b1;
        end else begin
          // Record an early response even if admission metadata said that no
          // result was expected. The later child completion is authoritative
          // for recovery and may turn this into an already-retired result.
          rsp_seen_by_entry[int'(rsp_entry)][group] = 1'b1;
          if (!entry_result_mask_q[int'(rsp_entry)][group]) begin
            child_rsp_wrong_group_o[group] = 1'b1;
          end
        end
      end
    end
  end

  // A one-entry selection hold makes the command completion interface stable
  // if another entry becomes complete while the current output is stalled.
  always_comb begin
    done_select_valid = 1'b0;
    done_select_index = '0;

    if (done_hold_valid_q) begin
      done_select_valid = 1'b1;
      done_select_index = done_hold_index_q;
    end else begin
      logic found;
      found = 1'b0;
      for (int offset = 0; offset < ENTRY_COUNT; offset++) begin
        int candidate;
        candidate = int'(done_rr_q) + offset;
        if (candidate >= ENTRY_COUNT) candidate -= ENTRY_COUNT;
        if (!found && entry_valid_q[candidate] &&
            !(|entry_pending_cpl_q[candidate]) &&
            !entry_completion_reported_q[candidate]) begin
          found = 1'b1;
          done_select_valid = 1'b1;
          done_select_index = ENTRY_W'(candidate);
        end
      end
    end

    cmd_cpl_valid_o = rst_ni && done_select_valid;
    cmd_cpl_context_o = '0;
    cmd_cpl_tag_o = '0;
    cmd_cpl_group_mask_o = '0;
    cmd_cpl_result_mask_o = '0;
    cmd_cpl_illegal_o = 1'b0;
    cmd_cpl_illegal_group_mask_o = '0;
    if (done_select_valid) begin
      cmd_cpl_context_o = entry_context_q[int'(done_select_index)];
      cmd_cpl_tag_o = entry_tag_q[int'(done_select_index)];
      cmd_cpl_group_mask_o =
          entry_group_mask_q[int'(done_select_index)];
      cmd_cpl_result_mask_o =
          entry_result_mask_q[int'(done_select_index)];
      cmd_cpl_illegal_group_mask_o =
          entry_illegal_group_mask_q[int'(done_select_index)];
      cmd_cpl_illegal_o =
          |entry_illegal_group_mask_q[int'(done_select_index)];
    end
  end

  assign cmd_cpl_fire = cmd_cpl_valid_o && cmd_cpl_ready_i;

  always_comb begin
    int unsigned occupancy;

    context_exec_inflight_o = '0;
    context_tag_busy_o = '0;
    entries_active_o = entry_valid_q;
    occupancy = 0;
    for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
      if (entry_valid_q[entry]) begin
        occupancy++;
        context_tag_busy_o[int'(entry_context_q[entry])] = 1'b1;
        if (|entry_pending_cpl_q[entry]) begin
          context_exec_inflight_o[int'(entry_context_q[entry])] = 1'b1;
        end
      end
    end
    context_quiescent_o = ~context_exec_inflight_o;
    full_o = &entry_valid_q;
    occupancy_o = COUNT_W'(occupancy);
  end

  always_comb begin
    // A live context+tag is an ordinary allocation dependency: the shell
    // backpressures that slot until the prior result lifetime ends.  It is not
    // a malformed transaction and therefore does not set the protocol sticky.
    protocol_fault = (|alloc_error_o) || (|alloc_commit_error_o) ||
                     (|child_cpl_unknown_o) ||
                     (|child_cpl_wrong_group_o) ||
                     (|child_cpl_duplicate_o) ||
                     (|child_cpl_result_mismatch_o) ||
                     (|child_rsp_unknown_o) ||
                     (|child_rsp_wrong_group_o) ||
                     (|child_rsp_duplicate_o);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_valid_q <= '0;
      entry_completion_reported_q <= '0;
      done_hold_valid_q <= 1'b0;
      done_hold_index_q <= '0;
      done_rr_q <= '0;
      protocol_error_o <= 1'b0;
      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        entry_context_q[entry] <= '0;
        entry_tag_q[entry] <= '0;
        entry_group_mask_q[entry] <= '0;
        entry_result_mask_q[entry] <= '0;
        entry_pending_cpl_q[entry] <= '0;
        entry_rsp_seen_q[entry] <= '0;
        entry_illegal_group_mask_q[entry] <= '0;
      end
    end else begin
      if (protocol_error_clear_i) protocol_error_o <= 1'b0;
      if (protocol_fault) protocol_error_o <= 1'b1;

      if (done_hold_valid_q) begin
        if (cmd_cpl_fire) done_hold_valid_q <= 1'b0;
      end else if (done_select_valid && !cmd_cpl_ready_i) begin
        done_hold_valid_q <= 1'b1;
        done_hold_index_q <= done_select_index;
      end
      if (cmd_cpl_fire) done_rr_q <= increment_entry(done_select_index);

      for (int entry = 0; entry < ENTRY_COUNT; entry++) begin
        if (entry_valid_q[entry]) begin
          logic [GROUP_COUNT-1:0] remaining_rsp;

          remaining_rsp = entry_result_mask_q[entry] &
                          ~(entry_rsp_seen_q[entry] |
                            rsp_seen_by_entry[entry]);
          entry_pending_cpl_q[entry] <=
              entry_pending_cpl_q[entry] & ~cpl_clear_by_entry[entry];
          entry_result_mask_q[entry] <=
              (entry_result_mask_q[entry] &
               ~cpl_result_update_by_entry[entry]) |
              (cpl_result_value_by_entry[entry] &
               cpl_result_update_by_entry[entry]);
          entry_rsp_seen_q[entry] <=
              entry_rsp_seen_q[entry] | rsp_seen_by_entry[entry];
          entry_illegal_group_mask_q[entry] <=
              entry_illegal_group_mask_q[entry] |
              cpl_illegal_by_entry[entry];

          if (cmd_cpl_fire &&
              int'(done_select_index) == entry) begin
            if (!(|remaining_rsp)) begin
              entry_valid_q[entry] <= 1'b0;
              entry_completion_reported_q[entry] <= 1'b0;
            end else begin
              entry_completion_reported_q[entry] <= 1'b1;
            end
          end else if (entry_completion_reported_q[entry] &&
                       !(|remaining_rsp)) begin
            entry_valid_q[entry] <= 1'b0;
            entry_completion_reported_q[entry] <= 1'b0;
          end
        end
      end

      for (int slot = 0; slot < ALLOC_SLOTS; slot++) begin
        if (alloc_commit_i[slot] && alloc_valid_i[slot] &&
            alloc_ready_o[slot]) begin
          entry_valid_q[int'(alloc_entry_index[slot])] <= 1'b1;
          entry_context_q[int'(alloc_entry_index[slot])] <= alloc_context_i[
              (slot*CONTEXT_W) +: CONTEXT_W];
          entry_tag_q[int'(alloc_entry_index[slot])] <=
              alloc_tag_i[(slot*TAG_W) +: TAG_W];
          entry_group_mask_q[int'(alloc_entry_index[slot])] <=
              alloc_group_mask_i[
              (slot*GROUP_COUNT) +: GROUP_COUNT];
          entry_result_mask_q[int'(alloc_entry_index[slot])] <=
              alloc_result_mask_i[
              (slot*GROUP_COUNT) +: GROUP_COUNT];
          entry_pending_cpl_q[int'(alloc_entry_index[slot])] <=
              alloc_group_mask_i[
              (slot*GROUP_COUNT) +: GROUP_COUNT];
          entry_rsp_seen_q[int'(alloc_entry_index[slot])] <= '0;
          entry_illegal_group_mask_q[int'(alloc_entry_index[slot])] <= '0;
          entry_completion_reported_q[int'(alloc_entry_index[slot])] <=
              1'b0;
        end
      end
    end
  end

  initial begin
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (ALLOC_SLOTS < 1) $error("ALLOC_SLOTS must be positive");
    if (CONTEXT_COUNT < 1) $error("CONTEXT_COUNT must be positive");
    if (TAG_W < 1) $error("TAG_W must be positive");
    if (ENTRY_COUNT < 1) $error("ENTRY_COUNT must be positive");
    if (CONTEXT_W != ((CONTEXT_COUNT <= 2) ? 1 :
                      $clog2(CONTEXT_COUNT))) begin
      $error("CONTEXT_W must match CONTEXT_COUNT");
    end
    if (ENTRY_W != ((ENTRY_COUNT <= 2) ? 1 :
                    $clog2(ENTRY_COUNT))) begin
      $error("ENTRY_W must match ENTRY_COUNT");
    end
    if (COUNT_W != ((ENTRY_COUNT <= 1) ? 1 :
                    $clog2(ENTRY_COUNT + 1))) begin
      $error("COUNT_W must represent zero through ENTRY_COUNT");
    end
  end
endmodule
