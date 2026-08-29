module vsp_ordered_action_window #(
  parameter int GROUP_COUNT = 4,
  parameter int WINDOW_DEPTH = 4,
  // Four fetched words may frame fewer or more records.  The default window
  // admission width follows the present two EXEC lanes plus one side lane,
  // rather than assuming one record per fetched word.
  parameter int ADMIT_LANES = 3,
  parameter int EXEC_SLOTS = 2,
  parameter int SIDE_SLOTS = 1,
  parameter int COMPLETION_LANES = 3,
  parameter int RETIRE_SLOTS = 3,
  parameter int PC_W = 32,
  parameter int SEQ_W = 16,
  parameter int RAW_RECORD_W = 128,
  parameter int RECORD_WORD_COUNT_W = 3,
  // These dependency bits name window-global resources such as scalar
  // registers, address-generation state, and memory-ordering domains.
  // Group-local register ordering is enforced separately by group_mask.
  parameter int DEP_W = 8,
  parameter int INDEX_W = (WINDOW_DEPTH < 2) ? 1 : $clog2(WINDOW_DEPTH),
  parameter int COUNT_W = (WINDOW_DEPTH < 1) ? 1 : $clog2(WINDOW_DEPTH + 1)
) (
  input  logic clk_i,
  input  logic rst_ni,
  // A program restart/redirect may synchronously discard the independent
  // window.  Integration must not use clear_i as architectural cancellation
  // without first arranging the corresponding engine flush.
  input  logic clear_i,

  // Up to ADMIT_LANES already-framed records arrive in program order. Valid
  // lanes need not be contiguous; accepted records are compacted while lane
  // number still defines their age. A lane after an accepted END is rejected.
  input  logic [ADMIT_LANES-1:0] admit_valid_i,
  output logic [ADMIT_LANES-1:0] admit_ready_o,
  output logic [(ADMIT_LANES*SEQ_W)-1:0] admit_seq_o,
  input  logic [(ADMIT_LANES*PC_W)-1:0] admit_pc_i,
  input  logic [(ADMIT_LANES*vsp_action_pkg::VSP_ACTION_CLASS_W)-1:0]
      admit_class_i,
  input  logic [(ADMIT_LANES*GROUP_COUNT)-1:0] admit_group_mask_i,
  input  logic [(ADMIT_LANES*RAW_RECORD_W)-1:0] admit_raw_record_i,
  input  logic [(ADMIT_LANES*RECORD_WORD_COUNT_W)-1:0]
      admit_record_word_count_i,
  input  logic [(ADMIT_LANES*DEP_W)-1:0] admit_dep_read_i,
  input  logic [(ADMIT_LANES*DEP_W)-1:0] admit_dep_write_i,
  input  logic [ADMIT_LANES-1:0] admit_split_ok_i,
  input  logic [ADMIT_LANES-1:0] admit_serializing_i,
  input  logic [ADMIT_LANES-1:0] admit_end_i,

  // Two vector EXEC views by default. Each view is the oldest currently
  // issueable EXEC entry not already selected by a lower-numbered slot.
  output logic [EXEC_SLOTS-1:0] exec_issue_valid_o,
  input  logic [EXEC_SLOTS-1:0] exec_issue_ready_i,
  // A split command may accept only the intersection with group_ready_i.
  // A non-split command accepts no child until its entire offered mask is
  // ready. accept_mask_o is the authoritative per-cycle issue feedback.
  input  logic [(EXEC_SLOTS*GROUP_COUNT)-1:0]
      exec_issue_group_ready_i,
  output logic [(EXEC_SLOTS*GROUP_COUNT)-1:0]
      exec_issue_accept_mask_o,
  output logic [(EXEC_SLOTS*SEQ_W)-1:0] exec_issue_seq_o,
  output logic [(EXEC_SLOTS*PC_W)-1:0] exec_issue_pc_o,
  output logic [(EXEC_SLOTS*GROUP_COUNT)-1:0]
      exec_issue_group_mask_o,
  output logic [(EXEC_SLOTS*GROUP_COUNT)-1:0]
      exec_issue_target_mask_o,
  output logic [(EXEC_SLOTS*RAW_RECORD_W)-1:0]
      exec_issue_raw_record_o,
  output logic [(EXEC_SLOTS*RECORD_WORD_COUNT_W)-1:0]
      exec_issue_record_word_count_o,
  output logic [(EXEC_SLOTS*DEP_W)-1:0] exec_issue_dep_read_o,
  output logic [(EXEC_SLOTS*DEP_W)-1:0] exec_issue_dep_write_o,
  output logic [EXEC_SLOTS-1:0] exec_issue_split_ok_o,

  // A side slot chooses the oldest ready non-EXEC record: MEMORY, CONTROL, or
  // an undefined class that must reach the ordered reject path. This is
  // deliberately not one fixed lane per class: the current throughput model
  // is 2 vector EXEC + 1 structural controller-side command per cycle. It is
  // not an implemented scalar ALU lane; a future scalar engine can consume
  // CONTROL actions through this class-router boundary.
  output logic [SIDE_SLOTS-1:0] side_issue_valid_o,
  input  logic [SIDE_SLOTS-1:0] side_issue_ready_i,
  input  logic [(SIDE_SLOTS*GROUP_COUNT)-1:0]
      side_issue_group_ready_i,
  output logic [(SIDE_SLOTS*GROUP_COUNT)-1:0]
      side_issue_accept_mask_o,
  output logic [(SIDE_SLOTS*SEQ_W)-1:0] side_issue_seq_o,
  output logic [(SIDE_SLOTS*PC_W)-1:0] side_issue_pc_o,
  output logic [(SIDE_SLOTS*vsp_action_pkg::VSP_ACTION_CLASS_W)-1:0]
      side_issue_class_o,
  output logic [(SIDE_SLOTS*GROUP_COUNT)-1:0]
      side_issue_group_mask_o,
  output logic [(SIDE_SLOTS*GROUP_COUNT)-1:0]
      side_issue_target_mask_o,
  output logic [(SIDE_SLOTS*RAW_RECORD_W)-1:0]
      side_issue_raw_record_o,
  output logic [(SIDE_SLOTS*RECORD_WORD_COUNT_W)-1:0]
      side_issue_record_word_count_o,
  output logic [(SIDE_SLOTS*DEP_W)-1:0] side_issue_dep_read_o,
  output logic [(SIDE_SLOTS*DEP_W)-1:0] side_issue_dep_write_o,
  output logic [SIDE_SLOTS-1:0] side_issue_split_ok_o,
  output logic [SIDE_SLOTS-1:0] side_issue_serializing_o,
  output logic [SIDE_SLOTS-1:0] side_issue_end_o,

  // Completion is reported by sequence identity. Group completions may merge
  // several children in one lane. complete_action_i completes only a
  // zero-group (controller/scalar) action. A same-cycle issue/completion is
  // intentionally not supported; the child must first become issued state.
  // Every presented completion is consumed. Unknown, duplicate, unissued, or
  // incorrectly-shaped reports are discarded and recorded as protocol error,
  // so a conforming ready/valid producer can always make forward progress.
  input  logic [COMPLETION_LANES-1:0] complete_valid_i,
  output logic [COMPLETION_LANES-1:0] complete_ready_o,
  input  logic [(COMPLETION_LANES*SEQ_W)-1:0] complete_seq_i,
  input  logic [(COMPLETION_LANES*GROUP_COUNT)-1:0]
      complete_group_mask_i,
  input  logic [COMPLETION_LANES-1:0] complete_action_i,
  input  logic protocol_error_clear_i,
  output logic protocol_error_o,

  // Completion may happen out of order, but architectural observation leaves
  // through a packed in-order retirement prefix. RETIRE_SLOTS defaults to the
  // three-command consume width so the window is a short dependency buffer,
  // not a one-retirement-per-cycle throughput bottleneck.
  output logic [RETIRE_SLOTS-1:0] retire_valid_o,
  input  logic [RETIRE_SLOTS-1:0] retire_ready_i,
  output logic [RETIRE_SLOTS-1:0] retire_accept_o,
  output logic [(RETIRE_SLOTS*SEQ_W)-1:0] retire_seq_o,
  output logic [(RETIRE_SLOTS*PC_W)-1:0] retire_pc_o,
  output logic [(RETIRE_SLOTS*vsp_action_pkg::VSP_ACTION_CLASS_W)-1:0]
      retire_class_o,
  output logic [(RETIRE_SLOTS*GROUP_COUNT)-1:0] retire_group_mask_o,
  output logic [(RETIRE_SLOTS*GROUP_COUNT)-1:0] retire_done_mask_o,
  output logic [(RETIRE_SLOTS*RAW_RECORD_W)-1:0] retire_raw_record_o,
  output logic [(RETIRE_SLOTS*RECORD_WORD_COUNT_W)-1:0]
      retire_record_word_count_o,
  output logic [(RETIRE_SLOTS*DEP_W)-1:0] retire_dep_read_o,
  output logic [(RETIRE_SLOTS*DEP_W)-1:0] retire_dep_write_o,
  output logic [RETIRE_SLOTS-1:0] retire_split_ok_o,
  output logic [RETIRE_SLOTS-1:0] retire_serializing_o,
  output logic [RETIRE_SLOTS-1:0] retire_end_o,
  output logic program_end_retired_o,

  output logic halt_fetch_o,
  output logic empty_o,
  output logic full_o,
  output logic [COUNT_W-1:0] occupancy_o
);
  import vsp_action_pkg::*;

  logic valid_q [WINDOW_DEPTH];
  logic [SEQ_W-1:0] seq_q [WINDOW_DEPTH];
  logic [PC_W-1:0] pc_q [WINDOW_DEPTH];
  logic [VSP_ACTION_CLASS_W-1:0] class_q [WINDOW_DEPTH];
  logic [GROUP_COUNT-1:0] target_mask_q [WINDOW_DEPTH];
  logic [GROUP_COUNT-1:0] issued_mask_q [WINDOW_DEPTH];
  logic [GROUP_COUNT-1:0] done_mask_q [WINDOW_DEPTH];
  logic scalar_issued_q [WINDOW_DEPTH];
  logic scalar_done_q [WINDOW_DEPTH];
  logic [RAW_RECORD_W-1:0] raw_record_q [WINDOW_DEPTH];
  logic [RECORD_WORD_COUNT_W-1:0] record_word_count_q [WINDOW_DEPTH];
  logic [DEP_W-1:0] dep_read_q [WINDOW_DEPTH];
  logic [DEP_W-1:0] dep_write_q [WINDOW_DEPTH];
  logic split_ok_q [WINDOW_DEPTH];
  logic serializing_q [WINDOW_DEPTH];
  logic end_q [WINDOW_DEPTH];

  logic [INDEX_W-1:0] head_q;
  logic [COUNT_W-1:0] count_q;
  logic [SEQ_W-1:0] next_seq_q;
  logic end_seen_q;
  logic program_end_retired_q;
  logic protocol_error_q;
  logic completion_protocol_error;

  logic [WINDOW_DEPTH-1:0] entry_complete;
  logic [WINDOW_DEPTH-1:0] entry_issueable;
  logic [GROUP_COUNT-1:0] entry_issue_mask [WINDOW_DEPTH];

  logic [ADMIT_LANES-1:0] admit_fire;
  logic [INDEX_W-1:0] admit_index [ADMIT_LANES];
  integer admit_count;

  logic [INDEX_W-1:0] exec_selected_index [EXEC_SLOTS];
  logic [INDEX_W-1:0] side_selected_index [SIDE_SLOTS];
  logic [GROUP_COUNT-1:0] exec_selected_mask [EXEC_SLOTS];
  logic [GROUP_COUNT-1:0] side_selected_mask [SIDE_SLOTS];
  logic [EXEC_SLOTS-1:0] exec_lock_valid_q;
  logic [INDEX_W-1:0] exec_lock_index_q [EXEC_SLOTS];
  logic [GROUP_COUNT-1:0] exec_lock_mask_q [EXEC_SLOTS];
  logic [SIDE_SLOTS-1:0] side_lock_valid_q;
  logic [INDEX_W-1:0] side_lock_index_q [SIDE_SLOTS];
  logic [GROUP_COUNT-1:0] side_lock_mask_q [SIDE_SLOTS];
  logic [EXEC_SLOTS-1:0] exec_issue_accepted;
  logic [SIDE_SLOTS-1:0] side_issue_accepted;
  logic [GROUP_COUNT-1:0] issue_mask_accum [WINDOW_DEPTH];
  logic [WINDOW_DEPTH-1:0] scalar_issue_accum;
  logic [GROUP_COUNT-1:0] completion_mask_accum [WINDOW_DEPTH];
  logic [WINDOW_DEPTH-1:0] scalar_completion_accum;

  integer retire_count;

  function automatic integer wrap_index(input integer value);
    wrap_index = value % WINDOW_DEPTH;
  endfunction

  always_comb begin : complete_state
    for (int entry = 0; entry < WINDOW_DEPTH; entry++) begin
      entry_complete[entry] = valid_q[entry] &&
          ((|target_mask_q[entry])
               ? ((done_mask_q[entry] & target_mask_q[entry]) ==
                  target_mask_q[entry])
               : scalar_done_q[entry]);
    end
  end

  // Admission is compacted in increasing lane order. An accepted retirement
  // prefix is reusable immediately; retirement depends only on registered
  // completion state, so this adds no admission/issue combinational loop.
  always_comb begin : admission
    integer accepted;
    logic end_before_lane;

    admit_ready_o = '0;
    admit_seq_o = '0;
    admit_fire = '0;
    for (int lane = 0; lane < ADMIT_LANES; lane++)
      admit_index[lane] = '0;

    accepted = 0;
    end_before_lane = end_seen_q;
    for (int lane = 0; lane < ADMIT_LANES; lane++) begin
      admit_ready_o[lane] = !end_before_lane &&
          (accepted < (WINDOW_DEPTH - int'(count_q) + retire_count));
      admit_fire[lane] = admit_valid_i[lane] && admit_ready_o[lane];
      admit_seq_o[(lane*SEQ_W) +: SEQ_W] =
          next_seq_q + SEQ_W'(accepted);
      admit_index[lane] = INDEX_W'(
          wrap_index(int'(head_q) + int'(count_q) + accepted));
      if (admit_fire[lane]) begin
        accepted = accepted + 1;
        if (admit_end_i[lane])
          end_before_lane = 1'b1;
      end
    end
    admit_count = accepted;
  end

  // Compute each entry's issueable group subset in one global age walk.
  // A completed child releases only its own group, so a split action can make
  // progress behind a still-live older parent. Shared dependency bits remain
  // action-wide and release when the older action is complete.
  always_comb begin : readiness_by_age
    logic [GROUP_COUNT-1:0] older_pending_groups;
    logic [DEP_W-1:0] older_reads;
    logic [DEP_W-1:0] older_writes;
    logic older_serializing;

    entry_issueable = '0;
    for (int entry = 0; entry < WINDOW_DEPTH; entry++)
      entry_issue_mask[entry] = '0;

    older_pending_groups = '0;
    older_reads = '0;
    older_writes = '0;
    older_serializing = 1'b0;

    for (int age = 0; age < WINDOW_DEPTH; age++) begin
      logic [INDEX_W-1:0] entry;
      logic shared_conflict;
      logic issue_blocked;
      logic [GROUP_COUNT-1:0] unissued_groups;
      logic [GROUP_COUNT-1:0] eligible_groups;

      entry = INDEX_W'(wrap_index(int'(head_q) + age));
      shared_conflict = 1'b0;
      issue_blocked = 1'b1;
      unissued_groups = '0;
      eligible_groups = '0;

      if ((age < int'(count_q)) && valid_q[entry]) begin
        shared_conflict =
            |(older_writes & (dep_read_q[entry] | dep_write_q[entry])) ||
            |(older_reads & dep_write_q[entry]);
        issue_blocked = entry_complete[entry] || older_serializing ||
                        shared_conflict ||
                        (serializing_q[entry] && (age != 0));

        if (!issue_blocked) begin
          if (|target_mask_q[entry]) begin
            unissued_groups = target_mask_q[entry] &
                              ~issued_mask_q[entry];
            eligible_groups = unissued_groups & ~older_pending_groups;
            if (split_ok_q[entry]) begin
              entry_issue_mask[entry] = eligible_groups;
              entry_issueable[entry] = |eligible_groups;
            end else begin
              entry_issue_mask[entry] = target_mask_q[entry];
              entry_issueable[entry] =
                  !(|issued_mask_q[entry]) &&
                  (eligible_groups == target_mask_q[entry]);
            end
          end else begin
            entry_issueable[entry] = !scalar_issued_q[entry];
          end
        end

        older_pending_groups |= target_mask_q[entry] &
                                ~done_mask_q[entry];
        if (!entry_complete[entry]) begin
          older_reads |= dep_read_q[entry];
          older_writes |= dep_write_q[entry];
        end
        // A serializing action remains an issue barrier until it retires.
        older_serializing |= serializing_q[entry];
      end
    end
  end

  always_comb begin : select_exec
    exec_issue_valid_o = '0;
    exec_issue_seq_o = '0;
    exec_issue_pc_o = '0;
    exec_issue_group_mask_o = '0;
    exec_issue_target_mask_o = '0;
    exec_issue_raw_record_o = '0;
    exec_issue_record_word_count_o = '0;
    exec_issue_dep_read_o = '0;
    exec_issue_dep_write_o = '0;
    exec_issue_split_ok_o = '0;
    for (int slot = 0; slot < EXEC_SLOTS; slot++) begin
      exec_selected_index[slot] = '0;
      exec_selected_mask[slot] = '0;
      if (exec_lock_valid_q[slot]) begin
        logic [INDEX_W-1:0] entry;
        entry = exec_lock_index_q[slot];
        exec_issue_valid_o[slot] = valid_q[entry] &&
                                   !entry_complete[entry] &&
                                   (class_q[entry] ==
                                    VSP_ACTION_CLASS_EXEC);
        exec_selected_index[slot] = entry;
        exec_selected_mask[slot] = exec_lock_mask_q[slot];
      end else begin
        for (int age = 0; age < WINDOW_DEPTH; age++) begin
          logic [INDEX_W-1:0] entry;
          logic selected_earlier;
          logic locked_elsewhere;
          entry = INDEX_W'(wrap_index(int'(head_q) + age));
          selected_earlier = 1'b0;
          locked_elsewhere = 1'b0;
          for (int prior = 0; prior < slot; prior++) begin
            selected_earlier |= exec_issue_valid_o[prior] &&
                (exec_selected_index[prior] == entry);
          end
          for (int other = 0; other < EXEC_SLOTS; other++) begin
            if (other != slot)
              locked_elsewhere |= exec_lock_valid_q[other] &&
                  (exec_lock_index_q[other] == entry);
          end
          if (!exec_issue_valid_o[slot] && !selected_earlier &&
              !locked_elsewhere && (age < int'(count_q)) &&
              valid_q[entry] && entry_issueable[entry] &&
              (class_q[entry] == VSP_ACTION_CLASS_EXEC)) begin
            exec_issue_valid_o[slot] = 1'b1;
            exec_selected_index[slot] = entry;
            exec_selected_mask[slot] = entry_issue_mask[entry];
          end
        end
      end
      if (exec_issue_valid_o[slot]) begin
        logic [INDEX_W-1:0] entry;
        entry = exec_selected_index[slot];
        exec_issue_seq_o[(slot*SEQ_W) +: SEQ_W] = seq_q[entry];
        exec_issue_pc_o[(slot*PC_W) +: PC_W] = pc_q[entry];
        exec_issue_group_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT] =
            exec_selected_mask[slot];
        exec_issue_target_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT] =
            target_mask_q[entry];
        exec_issue_raw_record_o[(slot*RAW_RECORD_W) +: RAW_RECORD_W] =
            raw_record_q[entry];
        exec_issue_record_word_count_o[
            (slot*RECORD_WORD_COUNT_W) +: RECORD_WORD_COUNT_W] =
            record_word_count_q[entry];
        exec_issue_dep_read_o[(slot*DEP_W) +: DEP_W] = dep_read_q[entry];
        exec_issue_dep_write_o[(slot*DEP_W) +: DEP_W] = dep_write_q[entry];
        exec_issue_split_ok_o[slot] = split_ok_q[entry];
      end
    end
  end

  always_comb begin : select_side
    side_issue_valid_o = '0;
    side_issue_seq_o = '0;
    side_issue_pc_o = '0;
    side_issue_class_o = '0;
    side_issue_group_mask_o = '0;
    side_issue_target_mask_o = '0;
    side_issue_raw_record_o = '0;
    side_issue_record_word_count_o = '0;
    side_issue_dep_read_o = '0;
    side_issue_dep_write_o = '0;
    side_issue_split_ok_o = '0;
    side_issue_serializing_o = '0;
    side_issue_end_o = '0;
    for (int slot = 0; slot < SIDE_SLOTS; slot++) begin
      side_selected_index[slot] = '0;
      side_selected_mask[slot] = '0;
      if (side_lock_valid_q[slot]) begin
        logic [INDEX_W-1:0] entry;
        entry = side_lock_index_q[slot];
        side_issue_valid_o[slot] = valid_q[entry] &&
                                   !entry_complete[entry] &&
                                   (class_q[entry] !=
                                    VSP_ACTION_CLASS_EXEC);
        side_selected_index[slot] = entry;
        side_selected_mask[slot] = side_lock_mask_q[slot];
      end else begin
        for (int age = 0; age < WINDOW_DEPTH; age++) begin
          logic [INDEX_W-1:0] entry;
          logic selected_earlier;
          logic locked_elsewhere;
          logic side_class;
          entry = INDEX_W'(wrap_index(int'(head_q) + age));
          selected_earlier = 1'b0;
          locked_elsewhere = 1'b0;
          for (int prior = 0; prior < slot; prior++) begin
            selected_earlier |= side_issue_valid_o[prior] &&
                (side_selected_index[prior] == entry);
          end
          for (int other = 0; other < SIDE_SLOTS; other++) begin
            if (other != slot)
              locked_elsewhere |= side_lock_valid_q[other] &&
                  (side_lock_index_q[other] == entry);
          end
          side_class = class_q[entry] != VSP_ACTION_CLASS_EXEC;
          if (!side_issue_valid_o[slot] && !selected_earlier &&
              !locked_elsewhere && side_class &&
              (age < int'(count_q)) && valid_q[entry] &&
              entry_issueable[entry]) begin
            side_issue_valid_o[slot] = 1'b1;
            side_selected_index[slot] = entry;
            side_selected_mask[slot] = entry_issue_mask[entry];
          end
        end
      end
      if (side_issue_valid_o[slot]) begin
        logic [INDEX_W-1:0] entry;
        entry = side_selected_index[slot];
        side_issue_seq_o[(slot*SEQ_W) +: SEQ_W] = seq_q[entry];
        side_issue_pc_o[(slot*PC_W) +: PC_W] = pc_q[entry];
        side_issue_class_o[(slot*VSP_ACTION_CLASS_W) +:
                           VSP_ACTION_CLASS_W] = class_q[entry];
        side_issue_group_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT] =
            side_selected_mask[slot];
        side_issue_target_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT] =
            target_mask_q[entry];
        side_issue_raw_record_o[(slot*RAW_RECORD_W) +: RAW_RECORD_W] =
            raw_record_q[entry];
        side_issue_record_word_count_o[
            (slot*RECORD_WORD_COUNT_W) +: RECORD_WORD_COUNT_W] =
            record_word_count_q[entry];
        side_issue_dep_read_o[(slot*DEP_W) +: DEP_W] = dep_read_q[entry];
        side_issue_dep_write_o[(slot*DEP_W) +: DEP_W] = dep_write_q[entry];
        side_issue_split_ok_o[slot] = split_ok_q[entry];
        side_issue_serializing_o[slot] = serializing_q[entry];
        side_issue_end_o[slot] = end_q[entry];
      end
    end
  end

  always_comb begin : accumulate_issue
    for (int entry = 0; entry < WINDOW_DEPTH; entry++)
      issue_mask_accum[entry] = '0;
    scalar_issue_accum = '0;
    exec_issue_accept_mask_o = '0;
    side_issue_accept_mask_o = '0;
    exec_issue_accepted = '0;
    side_issue_accepted = '0;

    for (int slot = 0; slot < EXEC_SLOTS; slot++) begin
      logic [INDEX_W-1:0] entry;
      logic [GROUP_COUNT-1:0] offered_groups;
      logic [GROUP_COUNT-1:0] accepted_groups;
      entry = exec_selected_index[slot];
      offered_groups =
          exec_issue_group_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT];
      accepted_groups = offered_groups &
          exec_issue_group_ready_i[(slot*GROUP_COUNT) +: GROUP_COUNT];
      if (exec_issue_valid_o[slot] && exec_issue_ready_i[slot]) begin
        if (|target_mask_q[entry]) begin
          if (!split_ok_q[entry] && (accepted_groups != offered_groups))
            accepted_groups = '0;
          issue_mask_accum[entry] |= accepted_groups;
          exec_issue_accept_mask_o[
              (slot*GROUP_COUNT) +: GROUP_COUNT] = accepted_groups;
          exec_issue_accepted[slot] = |accepted_groups;
        end else begin
          scalar_issue_accum[entry] = 1'b1;
          exec_issue_accepted[slot] = 1'b1;
        end
      end
    end
    for (int slot = 0; slot < SIDE_SLOTS; slot++) begin
      logic [INDEX_W-1:0] entry;
      logic [GROUP_COUNT-1:0] offered_groups;
      logic [GROUP_COUNT-1:0] accepted_groups;
      entry = side_selected_index[slot];
      offered_groups =
          side_issue_group_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT];
      accepted_groups = offered_groups &
          side_issue_group_ready_i[(slot*GROUP_COUNT) +: GROUP_COUNT];
      if (side_issue_valid_o[slot] && side_issue_ready_i[slot]) begin
        if (|target_mask_q[entry]) begin
          if (!split_ok_q[entry] && (accepted_groups != offered_groups))
            accepted_groups = '0;
          issue_mask_accum[entry] |= accepted_groups;
          side_issue_accept_mask_o[
              (slot*GROUP_COUNT) +: GROUP_COUNT] = accepted_groups;
          side_issue_accepted[slot] = |accepted_groups;
        end else begin
          scalar_issue_accum[entry] = 1'b1;
          side_issue_accepted[slot] = 1'b1;
        end
      end
    end
  end

  always_comb begin : accept_completion
    complete_ready_o = {COMPLETION_LANES{rst_ni && !clear_i}};
    completion_protocol_error = 1'b0;
    for (int entry = 0; entry < WINDOW_DEPTH; entry++) begin
      completion_mask_accum[entry] = '0;
      scalar_completion_accum[entry] = 1'b0;
    end

    for (int lane = 0; lane < COMPLETION_LANES; lane++) begin
      logic matched;
      logic lane_error;
      logic [GROUP_COUNT-1:0] reported_groups;
      matched = 1'b0;
      lane_error = 1'b0;
      reported_groups =
          complete_group_mask_i[(lane*GROUP_COUNT) +: GROUP_COUNT];
      for (int entry = 0; entry < WINDOW_DEPTH; entry++) begin
        logic [GROUP_COUNT-1:0] new_done_groups;
        logic [GROUP_COUNT-1:0] already_done_groups;
        logic new_scalar_done;
        logic scalar_already_done;
        new_done_groups = '0;
        already_done_groups = done_mask_q[entry] |
                              completion_mask_accum[entry];
        new_scalar_done = 1'b0;
        scalar_already_done = scalar_done_q[entry] |
                              scalar_completion_accum[entry];
        if (complete_valid_i[lane] && valid_q[entry] &&
            (complete_seq_i[(lane*SEQ_W) +: SEQ_W] == seq_q[entry])) begin
          matched = 1'b1;
          if (|target_mask_q[entry]) begin
            new_done_groups = reported_groups & issued_mask_q[entry] &
                              ~already_done_groups;
            completion_mask_accum[entry] |= new_done_groups;
            // Group actions use child bits, never action_done. Zero reports,
            // unissued bits, and already-consumed bits are malformed.
            lane_error |= complete_action_i[lane] ||
                          !(|reported_groups) ||
                          |(reported_groups & ~issued_mask_q[entry]) ||
                          |(reported_groups & already_done_groups);
          end else begin
            new_scalar_done = complete_action_i[lane] &&
                              scalar_issued_q[entry] &&
                              !scalar_already_done;
            scalar_completion_accum[entry] |= new_scalar_done;
            // A zero-group action has exactly one action-level completion.
            lane_error |= !complete_action_i[lane] ||
                          (|reported_groups) ||
                          !scalar_issued_q[entry] ||
                          scalar_already_done;
          end
        end
      end
      if (complete_valid_i[lane]) begin
        lane_error |= !matched;
        completion_protocol_error |= lane_error;
      end
    end
  end

  always_comb begin : retirement
    logic valid_prefix;
    logic accept_prefix;

    retire_valid_o = '0;
    retire_accept_o = '0;
    retire_seq_o = '0;
    retire_pc_o = '0;
    retire_class_o = '0;
    retire_group_mask_o = '0;
    retire_done_mask_o = '0;
    retire_raw_record_o = '0;
    retire_record_word_count_o = '0;
    retire_dep_read_o = '0;
    retire_dep_write_o = '0;
    retire_split_ok_o = '0;
    retire_serializing_o = '0;
    retire_end_o = '0;
    retire_count = 0;
    valid_prefix = 1'b1;
    accept_prefix = 1'b1;

    for (int slot = 0; slot < RETIRE_SLOTS; slot++) begin
      logic [INDEX_W-1:0] entry;
      entry = INDEX_W'(wrap_index(int'(head_q) + slot));
      retire_valid_o[slot] = valid_prefix &&
          (slot < int'(count_q)) && valid_q[entry] &&
          entry_complete[entry];
      valid_prefix &= retire_valid_o[slot];
      retire_accept_o[slot] = accept_prefix && retire_valid_o[slot] &&
                              retire_ready_i[slot];
      accept_prefix &= retire_accept_o[slot];
      if (retire_accept_o[slot])
        retire_count = retire_count + 1;

      if (retire_valid_o[slot]) begin
        retire_seq_o[(slot*SEQ_W) +: SEQ_W] = seq_q[entry];
        retire_pc_o[(slot*PC_W) +: PC_W] = pc_q[entry];
        retire_class_o[(slot*VSP_ACTION_CLASS_W) +:
                       VSP_ACTION_CLASS_W] = class_q[entry];
        retire_group_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT] =
            target_mask_q[entry];
        retire_done_mask_o[(slot*GROUP_COUNT) +: GROUP_COUNT] =
            done_mask_q[entry];
        retire_raw_record_o[(slot*RAW_RECORD_W) +: RAW_RECORD_W] =
            raw_record_q[entry];
        retire_record_word_count_o[
            (slot*RECORD_WORD_COUNT_W) +: RECORD_WORD_COUNT_W] =
            record_word_count_q[entry];
        retire_dep_read_o[(slot*DEP_W) +: DEP_W] = dep_read_q[entry];
        retire_dep_write_o[(slot*DEP_W) +: DEP_W] = dep_write_q[entry];
        retire_split_ok_o[slot] = split_ok_q[entry];
        retire_serializing_o[slot] = serializing_q[entry];
        retire_end_o[slot] = end_q[entry];
      end
    end
  end

  assign program_end_retired_o = program_end_retired_q;
  assign protocol_error_o = protocol_error_q;
  assign halt_fetch_o = end_seen_q;
  assign empty_o = count_q == 0;
  assign full_o = int'(count_q) == WINDOW_DEPTH;
  assign occupancy_o = count_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : state
    if (!rst_ni) begin
      head_q <= '0;
      count_q <= '0;
      next_seq_q <= '0;
      end_seen_q <= 1'b0;
      program_end_retired_q <= 1'b0;
      protocol_error_q <= 1'b0;
      exec_lock_valid_q <= '0;
      side_lock_valid_q <= '0;
      for (int slot = 0; slot < EXEC_SLOTS; slot++) begin
        exec_lock_index_q[slot] <= '0;
        exec_lock_mask_q[slot] <= '0;
      end
      for (int slot = 0; slot < SIDE_SLOTS; slot++) begin
        side_lock_index_q[slot] <= '0;
        side_lock_mask_q[slot] <= '0;
      end
      for (int entry = 0; entry < WINDOW_DEPTH; entry++) begin
        valid_q[entry] <= 1'b0;
        seq_q[entry] <= '0;
        pc_q[entry] <= '0;
        class_q[entry] <= '0;
        target_mask_q[entry] <= '0;
        issued_mask_q[entry] <= '0;
        done_mask_q[entry] <= '0;
        scalar_issued_q[entry] <= 1'b0;
        scalar_done_q[entry] <= 1'b0;
        raw_record_q[entry] <= '0;
        record_word_count_q[entry] <= '0;
        dep_read_q[entry] <= '0;
        dep_write_q[entry] <= '0;
        split_ok_q[entry] <= 1'b0;
        serializing_q[entry] <= 1'b0;
        end_q[entry] <= 1'b0;
      end
    end else if (clear_i) begin
      head_q <= '0;
      count_q <= '0;
      next_seq_q <= '0;
      end_seen_q <= 1'b0;
      program_end_retired_q <= 1'b0;
      protocol_error_q <= 1'b0;
      exec_lock_valid_q <= '0;
      side_lock_valid_q <= '0;
      for (int entry = 0; entry < WINDOW_DEPTH; entry++) begin
        valid_q[entry] <= 1'b0;
        issued_mask_q[entry] <= '0;
        done_mask_q[entry] <= '0;
        scalar_issued_q[entry] <= 1'b0;
        scalar_done_q[entry] <= 1'b0;
      end
    end else begin
      program_end_retired_q <= 1'b0;
      if (protocol_error_clear_i)
        protocol_error_q <= 1'b0;
      if (completion_protocol_error)
        protocol_error_q <= 1'b1;

      // A scheduling view becomes stall-stable once it is offered without an
      // accepted child. This prevents a newly unblocked older entry from
      // changing a decoupled payload underneath a stalled endpoint.
      for (int slot = 0; slot < EXEC_SLOTS; slot++) begin
        if (exec_lock_valid_q[slot]) begin
          if (!exec_issue_valid_o[slot] || exec_issue_accepted[slot])
            exec_lock_valid_q[slot] <= 1'b0;
        end else if (exec_issue_valid_o[slot] &&
                     !exec_issue_accepted[slot]) begin
          exec_lock_valid_q[slot] <= 1'b1;
          exec_lock_index_q[slot] <= exec_selected_index[slot];
          exec_lock_mask_q[slot] <= exec_selected_mask[slot];
        end
      end
      for (int slot = 0; slot < SIDE_SLOTS; slot++) begin
        if (side_lock_valid_q[slot]) begin
          if (!side_issue_valid_o[slot] || side_issue_accepted[slot])
            side_lock_valid_q[slot] <= 1'b0;
        end else if (side_issue_valid_o[slot] &&
                     !side_issue_accepted[slot]) begin
          side_lock_valid_q[slot] <= 1'b1;
          side_lock_index_q[slot] <= side_selected_index[slot];
          side_lock_mask_q[slot] <= side_selected_mask[slot];
        end
      end

      for (int entry = 0; entry < WINDOW_DEPTH; entry++) begin
        if (valid_q[entry]) begin
          issued_mask_q[entry] <= issued_mask_q[entry] |
                                  issue_mask_accum[entry];
          done_mask_q[entry] <= done_mask_q[entry] |
                                completion_mask_accum[entry];
          scalar_issued_q[entry] <= scalar_issued_q[entry] |
                                    scalar_issue_accum[entry];
          scalar_done_q[entry] <= scalar_done_q[entry] |
                                  scalar_completion_accum[entry];
        end
      end

      for (int slot = 0; slot < RETIRE_SLOTS; slot++) begin
        logic [INDEX_W-1:0] entry;
        entry = INDEX_W'(wrap_index(int'(head_q) + slot));
        if (retire_accept_o[slot]) begin
          valid_q[entry] <= 1'b0;
          if (end_q[entry])
            program_end_retired_q <= 1'b1;
        end
      end
      if (retire_count != 0)
        head_q <= INDEX_W'(
            wrap_index(int'(head_q) + retire_count));

      for (int lane = 0; lane < ADMIT_LANES; lane++) begin
        logic [INDEX_W-1:0] entry;
        entry = admit_index[lane];
        if (admit_fire[lane]) begin
          valid_q[entry] <= 1'b1;
          seq_q[entry] <= admit_seq_o[(lane*SEQ_W) +: SEQ_W];
          pc_q[entry] <= admit_pc_i[(lane*PC_W) +: PC_W];
          class_q[entry] <= admit_class_i[
              (lane*VSP_ACTION_CLASS_W) +: VSP_ACTION_CLASS_W];
          target_mask_q[entry] <=
              admit_group_mask_i[(lane*GROUP_COUNT) +: GROUP_COUNT];
          issued_mask_q[entry] <= '0;
          done_mask_q[entry] <= '0;
          scalar_issued_q[entry] <= 1'b0;
          scalar_done_q[entry] <= 1'b0;
          raw_record_q[entry] <= admit_raw_record_i[
              (lane*RAW_RECORD_W) +: RAW_RECORD_W];
          record_word_count_q[entry] <= admit_record_word_count_i[
              (lane*RECORD_WORD_COUNT_W) +: RECORD_WORD_COUNT_W];
          dep_read_q[entry] <=
              admit_dep_read_i[(lane*DEP_W) +: DEP_W];
          dep_write_q[entry] <=
              admit_dep_write_i[(lane*DEP_W) +: DEP_W];
          split_ok_q[entry] <= admit_split_ok_i[lane];
          serializing_q[entry] <= admit_serializing_i[lane] |
                                  admit_end_i[lane];
          end_q[entry] <= admit_end_i[lane];
          if (admit_end_i[lane])
            end_seen_q <= 1'b1;
        end
      end

      count_q <= COUNT_W'(int'(count_q) + admit_count - retire_count);
      next_seq_q <= next_seq_q + SEQ_W'(admit_count);
    end
  end

  initial begin
    if (GROUP_COUNT < 1) $error("GROUP_COUNT must be positive");
    if (WINDOW_DEPTH < 1) $error("WINDOW_DEPTH must be positive");
    if (ADMIT_LANES < 1) $error("ADMIT_LANES must be positive");
    if (EXEC_SLOTS < 1) $error("EXEC_SLOTS must be positive");
    if (SIDE_SLOTS < 1) $error("SIDE_SLOTS must be positive");
    if (COMPLETION_LANES < 1)
      $error("COMPLETION_LANES must be positive");
    if (RETIRE_SLOTS < 1) $error("RETIRE_SLOTS must be positive");
    if (PC_W < 3) $error("PC_W must hold a byte-aligned word address");
    if (SEQ_W < 1) $error("SEQ_W must be positive");
    if (SEQ_W < $clog2(WINDOW_DEPTH + 1))
      $error("SEQ_W must distinguish every live window entry");
    if (RAW_RECORD_W < 1) $error("RAW_RECORD_W must be positive");
    if (RECORD_WORD_COUNT_W < 1)
      $error("RECORD_WORD_COUNT_W must be positive");
    if (DEP_W < 1) $error("DEP_W must be positive");
    if (INDEX_W != ((WINDOW_DEPTH < 2) ? 1 : $clog2(WINDOW_DEPTH)))
      $error("INDEX_W must match WINDOW_DEPTH");
    if (COUNT_W != ((WINDOW_DEPTH < 1) ? 1 :
                    $clog2(WINDOW_DEPTH + 1)))
      $error("COUNT_W must match WINDOW_DEPTH");
  end
endmodule
