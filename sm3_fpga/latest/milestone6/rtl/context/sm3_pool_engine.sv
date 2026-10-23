module sm3_pool_engine #(
    parameter int CORE_NUM   = 8,
    parameter int CTX_NUM    = 32,
    parameter int MSG_ID_W   = 32,
    parameter int FAST_DEPTH = 32,
    parameter int POOL_DEPTH = 256,
    parameter int FAST_QUOTA = 3,
    parameter int STICKY_QUANTUM_BUSY = 2,
    parameter int STICKY_QUANTUM_IDLE = 8,
    parameter int FAST_WATERMARK = 1,
    parameter int FAST_PRESSURE_HOLD = 32,
    parameter int CTX_ID_W   = (CTX_NUM <= 1) ? 1 : $clog2(CTX_NUM),
    parameter int CORE_ID_W  = (CORE_NUM <= 1) ? 1 : $clog2(CORE_NUM),
    parameter int CTX_RR_W   = (CTX_NUM <= 1) ? 1 : $clog2(CTX_NUM),
    parameter int FAST_PTR_W = (FAST_DEPTH <= 1) ? 1 : $clog2(FAST_DEPTH),
    parameter int FAST_CNT_W = $clog2(FAST_DEPTH + 1),
    parameter int POOL_SLOT_W = (POOL_DEPTH <= 1) ? 1 : $clog2(POOL_DEPTH),
    parameter int POOL_CNT_W  = $clog2(POOL_DEPTH + 1),
    parameter int FAST_BURST_W = (FAST_QUOTA <= 1) ? 1 : $clog2(FAST_QUOTA + 1),
    parameter int MAX_STICKY_QUANTUM = (STICKY_QUANTUM_IDLE > STICKY_QUANTUM_BUSY)
                                     ? STICKY_QUANTUM_IDLE : STICKY_QUANTUM_BUSY,
    parameter int QUANTUM_W = (MAX_STICKY_QUANTUM <= 1) ? 1 : $clog2(MAX_STICKY_QUANTUM + 1),
    parameter int PRESSURE_W = (FAST_PRESSURE_HOLD <= 1) ? 1 : $clog2(FAST_PRESSURE_HOLD + 1),
    parameter int TAG_W      = 1 + MSG_ID_W + CTX_ID_W
) (
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     block_valid,
    output logic                     block_ready,
    input  logic [511:0]             block_data,
    input  logic [CTX_ID_W-1:0]      block_ctx_id_in,
    input  logic [MSG_ID_W-1:0]      msg_id_in,
    input  logic                     block_first_in,
    input  logic                     block_last_in,

    output logic                     result_valid,
    input  logic                     result_ready,
    output logic [255:0]             digest_out,
    output logic [MSG_ID_W-1:0]      msg_id_out,
    output logic [CTX_ID_W-1:0]      ctx_id_out,
    output logic                     result_fast,

    output logic [CORE_NUM-1:0]      core_occupied,
    output logic [CTX_NUM-1:0]       ctx_valid_bitmap,
    output logic [CTX_NUM-1:0]       ctx_pending_bitmap,
    output logic [CTX_NUM-1:0]       ctx_inflight_bitmap,
    output logic [FAST_CNT_W-1:0]    fast_level,
    output logic [POOL_CNT_W-1:0]    pool_free_count,
    output logic                     pool_init_done,

    output logic                     dbg_dispatch_valid,
    output logic                     dbg_dispatch_fast,
    output logic [CTX_ID_W-1:0]      dbg_dispatch_ctx_id,
    output logic                     dbg_commit_valid,
    output logic                     dbg_commit_fast,
    output logic [CTX_ID_W-1:0]      dbg_commit_ctx_id,
    output logic                     dbg_commit_last,
    output logic                     dbg_sticky_valid
);

    localparam logic [255:0] SM3_IV =
        256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    // ------------------------------------------------------------------
    // Per-message context metadata. Payload blocks are no longer stored in
    // the context. Each context owns a linked list of slots in the global pool.
    // ------------------------------------------------------------------
    logic [CTX_NUM-1:0] ctx_valid;
    logic [CTX_NUM-1:0] ctx_pending_valid;
    logic [CTX_NUM-1:0] ctx_inflight;
    logic [CTX_NUM-1:0] ctx_last_accepted;
    logic [MSG_ID_W-1:0] ctx_msg_id [0:CTX_NUM-1];
    logic [POOL_SLOT_W-1:0] ctx_head [0:CTX_NUM-1];
    logic [POOL_SLOT_W-1:0] ctx_tail [0:CTX_NUM-1];
    logic                   ctx_single [0:CTX_NUM-1];

    assign ctx_valid_bitmap    = ctx_valid;
    assign ctx_pending_bitmap  = ctx_pending_valid;
    assign ctx_inflight_bitmap = ctx_inflight;

    // Hash state remains one entry per active multi-block message.
    (* ram_style = "block" *) logic [255:0] hash_mem [0:CTX_NUM-1];
    logic hash_rd_en;
    logic [CTX_ID_W-1:0] hash_rd_addr;
    logic [255:0] hash_rd_state;
    logic hash_wr_en;
    logic [CTX_ID_W-1:0] hash_wr_addr;
    logic [255:0] hash_wr_data;

    // ------------------------------------------------------------------
    // Fast FIFO for single-block messages.
    // ------------------------------------------------------------------
    (* ram_style = "distributed" *) logic [511:0]        fast_block_mem [0:FAST_DEPTH-1];
    (* ram_style = "distributed" *) logic [MSG_ID_W-1:0] fast_msg_mem   [0:FAST_DEPTH-1];
    (* ram_style = "distributed" *) logic [CTX_ID_W-1:0] fast_ctx_mem   [0:FAST_DEPTH-1];
    logic [FAST_PTR_W-1:0] fast_wr_ptr, fast_rd_ptr;
    logic [FAST_CNT_W-1:0] fast_count;
    logic fast_push, fast_pop;
    logic fast_full, fast_empty;

    assign fast_full  = (fast_count == FAST_CNT_W'(FAST_DEPTH));
    assign fast_empty = (fast_count == 0);
    assign fast_level = fast_count;

    // ------------------------------------------------------------------
    // Global multi-block pool.
    // ------------------------------------------------------------------
    logic                  pool_alloc_valid;
    logic                  pool_alloc_ready;
    logic [POOL_SLOT_W-1:0] pool_alloc_slot;
    logic                  pool_free_valid;
    logic [POOL_SLOT_W-1:0] pool_free_slot;
    logic                  pool_link_wr_en;
    logic [POOL_SLOT_W-1:0] pool_link_wr_slot;
    logic [POOL_SLOT_W-1:0] pool_link_wr_next;
    logic                  pool_link_rd_en;
    logic [POOL_SLOT_W-1:0] pool_link_rd_slot;
    logic [POOL_SLOT_W-1:0] pool_link_rd_next;
    logic                  pool_rd_en;
    logic [POOL_SLOT_W-1:0] pool_rd_slot;
    logic [511:0]          pool_rd_block;
    logic                  pool_rd_first;
    logic                  pool_rd_last;

    localparam int CTX_EXT_W = CTX_ID_W + 1;

    logic [CTX_ID_W-1:0] input_ctx_idx;
    logic input_ctx_in_range;
    logic input_is_fast;
    logic input_multi_ok;
    logic multi_push;
    logic [CTX_ID_W-1:0] push_ctx_idx;

    always_comb begin
        input_ctx_idx = block_ctx_id_in;
        input_ctx_in_range = ({1'b0, block_ctx_id_in} < CTX_EXT_W'(CTX_NUM));
        input_is_fast = block_first_in && block_last_in;
        input_multi_ok = 1'b0;

        if (!input_is_fast && input_ctx_in_range) begin
            if (block_first_in)
                input_multi_ok = !ctx_valid[input_ctx_idx];
            else
                // The top-level block router keeps continuation blocks on the
                // context allocated for their message, so the full 32-bit
                // message-ID comparison is redundant here and is removed from
                // the block-ready -> ctx_head timing path.
                input_multi_ok = ctx_valid[input_ctx_idx]
                              && !ctx_last_accepted[input_ctx_idx];
        end

        if (input_is_fast)
            block_ready = !fast_full;
        else
            block_ready = input_multi_ok && pool_alloc_ready;
    end

    assign fast_push = block_valid && block_ready && input_is_fast;
    assign multi_push = block_valid && block_ready && !input_is_fast;
    assign push_ctx_idx = input_ctx_idx;
    assign pool_alloc_valid = block_valid && !input_is_fast && input_multi_ok;

    // ------------------------------------------------------------------
    // Core bank and launch pipeline.
    // ------------------------------------------------------------------
    logic [CORE_NUM-1:0] core_in_valid;
    logic [CORE_NUM-1:0] core_in_ready;
    logic [CORE_NUM-1:0] core_out_valid;
    logic [CORE_NUM-1:0] core_out_ready;
    logic [CORE_NUM-1:0] core_reserved;
    logic [CORE_NUM-1:0] core_commit_mask;
    logic [255:0]        core_hash_out [0:CORE_NUM-1];
    logic [TAG_W-1:0]    core_tag_out  [0:CORE_NUM-1];
    logic                core_last_out [0:CORE_NUM-1];

    logic [CORE_ID_W-1:0] sched_core_sel;
    logic                 sched_core_found;
    logic [CTX_ID_W-1:0]  sched_ctx_sel;
    logic                 sched_ctx_found;
    logic [CTX_NUM-1:0]   ctx_ready;
    logic [CTX_NUM-1:0]   ctx_ready_ge;
    logic [CTX_NUM-1:0]   ctx_ready_lt;
    logic [CTX_RR_W-1:0] ctx_rr_ptr;
    logic   sched_use_fast;
    logic   sched_candidate;
    logic   sched_accept;
    logic   sched_issue;
    logic   sched_gnt_valid_q;
    logic [CTX_ID_W-1:0]  sched_gnt_ctx_q;
    logic [CORE_ID_W-1:0] sched_gnt_core_q;
    logic   sched_gnt_fast_q;
    logic   sched_gnt_ctx_found_q;
    (* max_fanout = 32 *) logic   launch_valid;
    (* max_fanout = 32 *) logic   launch_pending;
    logic   launch_is_fast;
    logic [CTX_ID_W-1:0] launch_ctx_id;
    logic [MSG_ID_W-1:0] launch_msg_id;
    logic [511:0]        launch_fast_block;
    logic [511:0]        launch_block_q;
    logic [255:0]        launch_hash_q;
    logic                launch_last_q;
    logic [CORE_ID_W-1:0] launch_core_id;
    logic   launch_fire;
    logic   launch_pipe_ready;
    (* max_fanout = 32 *) logic   launch_slot_busy;
    logic [FAST_BURST_W-1:0] fast_burst_count;
    logic [QUANTUM_W-1:0] core_quantum [0:CORE_NUM-1];
    logic                  launch_hash_bypass;
    logic [255:0]          launch_hash_value;
    logic                  sticky_issue;
    logic [QUANTUM_W-1:0] sticky_quantum_limit;
    logic [PRESSURE_W-1:0] fast_pressure_count;

    logic [511:0]      core_launch_block;
    logic [255:0]      core_launch_hash;
    logic              core_launch_last;
    logic [TAG_W-1:0] core_launch_tag;

    assign sticky_quantum_limit = ((fast_count >= FAST_CNT_W'(FAST_WATERMARK))
                                  || (fast_pressure_count != 0))
                                ? QUANTUM_W'(STICKY_QUANTUM_BUSY)
                                : QUANTUM_W'(STICKY_QUANTUM_IDLE);

    assign launch_fire       = launch_valid && core_in_ready[launch_core_id];
    assign launch_pipe_ready = !launch_valid || launch_fire;
    assign launch_slot_busy  = launch_valid || launch_pending;

    always_comb begin
        sched_core_sel   = '0;
        sched_core_found = 1'b0;
        sched_ctx_sel    = '0;
        sched_use_fast   = 1'b0;
        ctx_ready        = '0;
        ctx_ready_ge     = '0;
        ctx_ready_lt     = '0;

        for (int c = 0; c < CTX_NUM; c = c + 1) begin
            ctx_ready[c] = ctx_valid[c] && ctx_pending_valid[c] && !ctx_inflight[c];
            if (c >= ctx_rr_ptr)
                ctx_ready_ge[c] = ctx_ready[c];
            else
                ctx_ready_lt[c] = ctx_ready[c];
        end

        // The grant valid only needs to know whether any context is ready; the
        // round-robin index is a separate, wider data path.
        sched_ctx_found = |ctx_ready;

        if (launch_pipe_ready) begin
            for (int k = 0; k < CORE_NUM; k = k + 1) begin
                if (!sched_core_found && core_in_ready[k] && !core_commit_mask[k]) begin
                    sched_core_sel   = CORE_ID_W'(k);
                    sched_core_found = 1'b1;
                end
            end

            // Round-robin across ready contexts: lowest ready ID at or above
            // ctx_rr_ptr, otherwise wrap to the lowest ready ID below it.
            if (|ctx_ready_ge) begin
                for (int c = CTX_NUM-1; c >= 0; c = c - 1)
                    if (ctx_ready_ge[c])
                        sched_ctx_sel = CTX_ID_W'(c);
            end else begin
                for (int c = CTX_NUM-1; c >= 0; c = c - 1)
                    if (ctx_ready_lt[c])
                        sched_ctx_sel = CTX_ID_W'(c);
            end

            if (!fast_empty && !sched_ctx_found)
                sched_use_fast = 1'b1;
            else if (!fast_empty && (fast_burst_count < FAST_BURST_W'(FAST_QUOTA)))
                sched_use_fast = 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Completion arbitration.
    // ------------------------------------------------------------------
    // Core completion first enters a one-entry commit register.  This removes
    // the 16:1 live-core arbitration and the wide core output muxes from the
    // path that updates ctx_head / link state in the following cycle.
    logic [CORE_ID_W-1:0] commit_core_sel;
    logic                 commit_core_found;
    logic                 commit_accept;
    logic                 commit_valid_q;
    logic [CORE_ID_W-1:0] commit_core_q;
    logic [255:0]         commit_hash_q;
    logic [TAG_W-1:0]     commit_tag_q;
    logic                 commit_last_q;
    logic                 commit_ctx_in_range_q;
    logic                 commit_ctx_pending_q;
    logic                 commit_ctx_valid_q;
    logic                 commit_ctx_inflight_q;
    logic                 commit_sticky_ok_q;
    logic                 commit_can_consume;
    logic                 commit_ctx_in_range;
    logic   commit_fire;
    logic   commit_last;
    logic   commit_is_fast;
    logic [CTX_ID_W-1:0] commit_ctx_id;
    logic [MSG_ID_W-1:0] commit_msg_id;
    logic [255:0] commit_hash;
    logic result_slot_available;

    assign result_slot_available = !result_valid || result_ready;
    assign commit_accept = !commit_valid_q;

    always_comb begin
        commit_core_sel   = '0;
        commit_core_found = 1'b0;
        core_out_ready    = '0;
        for (int k = 0; k < CORE_NUM; k = k + 1) begin
            if (!commit_core_found && core_out_valid[k]) begin
                commit_core_sel   = CORE_ID_W'(k);
                commit_core_found = 1'b1;
            end
        end

        // The core is released as soon as its result is captured.  Its
        // reservation is held until the commit register is processed so the
        // scheduler cannot reuse it during the one-cycle gap.
        if (commit_core_found && commit_accept)
            core_out_ready[commit_core_sel] = 1'b1;
    end

    // A final or fast result needs room in the result register.  Other blocks
    // only update context metadata and may retire immediately.
    always_comb begin
        commit_can_consume = 1'b0;
        if (commit_valid_q)
            commit_can_consume = commit_last_q || commit_tag_q[TAG_W-1]
                               ? result_slot_available : 1'b1;
    end

    assign commit_fire = commit_valid_q && commit_can_consume;

    always_comb begin
        commit_last    = commit_last_q;
        commit_hash    = commit_hash_q;
        commit_is_fast = commit_tag_q[TAG_W-1];
        commit_msg_id  = commit_tag_q[CTX_ID_W +: MSG_ID_W];
        commit_ctx_id  = commit_tag_q[CTX_ID_W-1:0];
        commit_ctx_in_range = ({1'b0, commit_tag_q[CTX_ID_W-1:0]}
                               < CTX_EXT_W'(CTX_NUM));
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            commit_valid_q <= 1'b0;
            commit_core_q  <= '0;
            commit_hash_q  <= '0;
            commit_tag_q   <= '0;
            commit_last_q  <= 1'b0;
            commit_ctx_in_range_q <= 1'b0;
            commit_ctx_pending_q  <= 1'b0;
            commit_ctx_valid_q    <= 1'b0;
            commit_ctx_inflight_q <= 1'b0;
            commit_sticky_ok_q    <= 1'b0;
        end else begin
            if (commit_accept && commit_core_found) begin
                commit_valid_q <= 1'b1;
                commit_core_q  <= commit_core_sel;
                commit_hash_q  <= core_hash_out[commit_core_sel];
                commit_tag_q   <= core_tag_out[commit_core_sel];
                commit_last_q  <= core_last_out[commit_core_sel];
                commit_ctx_in_range_q <=
                    ({1'b0, core_tag_out[commit_core_sel][CTX_ID_W-1:0]}
                     < CTX_EXT_W'(CTX_NUM));
                commit_ctx_pending_q <=
                    ({1'b0, core_tag_out[commit_core_sel][CTX_ID_W-1:0]}
                     < CTX_EXT_W'(CTX_NUM))
                    ? ctx_pending_valid[core_tag_out[commit_core_sel][CTX_ID_W-1:0]]
                    : 1'b0;
                commit_ctx_valid_q <=
                    ({1'b0, core_tag_out[commit_core_sel][CTX_ID_W-1:0]}
                     < CTX_EXT_W'(CTX_NUM))
                    ? ctx_valid[core_tag_out[commit_core_sel][CTX_ID_W-1:0]]
                    : 1'b0;
                commit_ctx_inflight_q <=
                    ({1'b0, core_tag_out[commit_core_sel][CTX_ID_W-1:0]}
                     < CTX_EXT_W'(CTX_NUM))
                    ? ctx_inflight[core_tag_out[commit_core_sel][CTX_ID_W-1:0]]
                    : 1'b0;
                commit_sticky_ok_q <=
                    (core_quantum[commit_core_sel] < sticky_quantum_limit);
            end else if (commit_fire) begin
                commit_valid_q <= 1'b0;
            end
        end
    end

    // A core whose result is being captured, or still sitting in the commit
    // register, must not be selected for a new launch.  core_reserved covers
    // the normal launch pipeline; this mask also covers the commit stage.
    always_comb begin
        for (int k = 0; k < CORE_NUM; k = k + 1)
            core_commit_mask[k] = core_reserved[k]
                                || (core_out_valid[k] && commit_accept)
                                || (commit_valid_q
                                    && (commit_core_q == CORE_ID_W'(k)));
    end

    // Sticky continuation consumes the next queued slot directly on the core
    // that just completed, bypassing a hash-RAM write/read round trip.
    always_comb begin
        sticky_issue = 1'b0;
        // Only the launch-slot occupancy matters here.  Using launch_pipe_ready
        // would pull core_in_ready / core busy into the ctx_head write-enable
        // path.  When a normal launch is still waiting, skip sticky for this
        // commit; the scheduler will pick the context up again.
        // Equivalent to commit_fire for the non-final/non-fast case, but it
        // does not pull result_ready into the sticky/pop logic.
        if (!launch_slot_busy
            && !sched_gnt_valid_q
            && commit_valid_q
            && !commit_is_fast
            && !commit_last
            && commit_ctx_in_range_q
            && commit_ctx_pending_q
            && commit_sticky_ok_q)
            sticky_issue = 1'b1;
    end

    // The round-robin scan feeds a one-entry grant register.  The following
    // cycle performs the pop/launch using registered grant metadata, keeping
    // the 32-context scan off the ctx_head write-enable path.
    assign sched_candidate = sched_core_found
                          && (sched_use_fast || sched_ctx_found);
    // Use launch-slot occupancy, not launch_pipe_ready, for the grant/pop
    // stages.  launch_pipe_ready includes core_in_ready, which would otherwise
    // put core out_valid/busy back on the ctx_head write-enable path.
    assign sched_accept = !sticky_issue
                       && !sched_gnt_valid_q
                       && !launch_valid
                       && sched_candidate;
    assign sched_issue = sched_gnt_valid_q && !launch_slot_busy;
    assign fast_pop = sched_issue && sched_gnt_fast_q;

    // One context queue slot is popped whenever a normal context dispatch or
    // sticky continuation is selected. Payload launch stays one cycle; metadata
    // link lookup and slot recycle are retimed through two more cycles.
    // Delaying frees prevents a recycled slot from overwriting next_mem before
    // its old successor is read.
    logic pop_head_s1, pop_head_s2;
    logic [CTX_ID_W-1:0] pop_head_ctx_s1, pop_head_ctx_s2;
    logic pop_single_s1, pop_single_s2;
    logic pop_push_same, pop_push_same_s1, pop_push_same_s2;
    logic [POOL_SLOT_W-1:0] pop_new_slot_s1, pop_new_slot_s2;
    logic pop_free_s1, pop_free_s2;
    logic [POOL_SLOT_W-1:0] pop_free_slot_s1, pop_free_slot_s2;

    logic ctx_pop;
    logic [CTX_ID_W-1:0] pop_ctx_idx;
    logic [POOL_SLOT_W-1:0] pop_slot;
    logic pop_single_old;
    logic [POOL_SLOT_W-1:0] pop_head_new;
    logic [POOL_SLOT_W-1:0] pop_tail_next;

    always_comb begin
        ctx_pop = sticky_issue || (sched_issue && !sched_gnt_fast_q);
        pop_ctx_idx = '0;
        if (sticky_issue)
            pop_ctx_idx = commit_ctx_id;
        else if (sched_issue && !sched_gnt_fast_q)
            pop_ctx_idx = sched_gnt_ctx_q;

        pop_slot = '0;
        pop_single_old = 1'b0;
        if (ctx_pop) begin
            pop_slot = ctx_head[pop_ctx_idx];
            pop_single_old = ctx_single[pop_ctx_idx];
        end
        pop_push_same = ctx_pop && multi_push
                     && (push_ctx_idx == pop_ctx_idx);
    end

    // Data used to retire a pop at E2.  The head is either the linked
    // successor or the freshly pushed slot for a one-element queue.  The
    // single-element flag is recomputed against the tail that will exist after
    // any push in the same cycle, so it stays exact without carrying a wide
    // per-context count through the dispatch path.
    always_comb begin
        pop_head_new = pool_link_rd_next;
        if (pop_single_s2 && pop_push_same_s2)
            pop_head_new = pop_new_slot_s2;

        pop_tail_next = ctx_tail[pop_head_ctx_s2];
        if (multi_push && (push_ctx_idx == pop_head_ctx_s2))
            pop_tail_next = pool_alloc_slot;
    end

    assign pool_rd_en         = ctx_pop;
    assign pool_rd_slot       = pop_slot;
    assign pool_link_rd_en    = ctx_pop;
    assign pool_link_rd_slot  = pop_slot;
    assign pool_free_valid    = pop_free_s2;
    assign pool_free_slot     = pop_free_slot_s2;

    // E0: capture address/slot; E1: block-pool link read completes;
    // E2: update ctx_head and return the old slot to the free list.
    // A context with a pending non-single head update is already inflight,
    // so it cannot dispatch the same context again before the update retires.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pop_head_s1      <= 1'b0;
            pop_head_s2      <= 1'b0;
            pop_head_ctx_s1  <= '0;
            pop_head_ctx_s2  <= '0;
            pop_single_s1    <= 1'b0;
            pop_single_s2    <= 1'b0;
            pop_push_same_s1 <= 1'b0;
            pop_push_same_s2 <= 1'b0;
            pop_new_slot_s1  <= '0;
            pop_new_slot_s2  <= '0;
            pop_free_s1      <= 1'b0;
            pop_free_s2      <= 1'b0;
            pop_free_slot_s1 <= '0;
            pop_free_slot_s2 <= '0;
        end else begin
            pop_head_s1 <= pool_link_rd_en;
            pop_head_s2 <= pop_head_s1;
            pop_single_s1 <= pop_single_old;
            pop_single_s2 <= pop_single_s1;
            pop_push_same_s1 <= pop_push_same;
            pop_push_same_s2 <= pop_push_same_s1;
            pop_new_slot_s1  <= pool_alloc_slot;
            pop_new_slot_s2  <= pop_new_slot_s1;
            if (pool_link_rd_en)
                pop_head_ctx_s1 <= pop_ctx_idx;
            if (pop_head_s1)
                pop_head_ctx_s2 <= pop_head_ctx_s1;

            pop_free_s1 <= ctx_pop;
            pop_free_s2 <= pop_free_s1;
            if (ctx_pop)
                pop_free_slot_s1 <= pop_slot;
            if (pop_free_s1)
                pop_free_slot_s2 <= pop_free_slot_s1;
        end
    end

    // Link the previous tail to a newly allocated slot whenever the pushed
    // block extends an existing queue.  The old implementation suppressed this
    // write when a one-element queue was popped in the same cycle as a push;
    // that made the BRAM write-enable depend on the whole commit/pop path.
    // Writing the link unconditionally is safe: the popped slot is not returned
    // to the free list until two cycles later, and its stale successor is
    // overwritten before the slot can be used as a non-single-element tail.
    assign pool_link_wr_en   = multi_push && ctx_pending_valid[push_ctx_idx];
    assign pool_link_wr_slot = ctx_tail[push_ctx_idx];
    assign pool_link_wr_next = pool_alloc_slot;

    // Hash RAM read is needed for normal context dispatch only. Sticky uses the
    // completion result directly as hash_in.
    assign hash_rd_en   = sched_issue && !sched_gnt_fast_q;
    assign hash_rd_addr = sched_gnt_ctx_q;
    assign hash_wr_en   = commit_fire && !commit_is_fast && !commit_last && !sticky_issue;
    assign hash_wr_addr = commit_ctx_id;
    assign hash_wr_data = commit_hash;

    always_ff @(posedge clk) begin
        if (hash_wr_en)
            hash_mem[hash_wr_addr] <= hash_wr_data;
        if (hash_rd_en)
            hash_rd_state <= hash_mem[hash_rd_addr];
    end

    always_comb begin
        core_in_valid = '0;
        if (launch_valid)
            core_in_valid[launch_core_id] = 1'b1;

        // The block-pool synchronous read is captured one cycle after issue.
        // Launching from this register removes the BRAM output -> core w load
        // path from the launch cycle.
        if (launch_is_fast) begin
            core_launch_block = launch_fast_block;
            core_launch_hash  = SM3_IV;
            core_launch_last  = 1'b1;
        end else begin
            core_launch_block = launch_block_q;
            core_launch_hash  = launch_hash_q;
            core_launch_last  = launch_last_q;
        end
        core_launch_tag   = {launch_is_fast,
                             (launch_is_fast ? launch_msg_id : {MSG_ID_W{1'b0}}),
                             launch_ctx_id};
    end

    assign dbg_dispatch_valid  = launch_fire;
    assign dbg_dispatch_fast   = launch_fire && launch_is_fast;
    assign dbg_dispatch_ctx_id = launch_ctx_id;
    assign dbg_commit_valid    = commit_fire;
    assign dbg_commit_fast     = commit_fire && commit_is_fast;
    assign dbg_commit_ctx_id   = commit_ctx_id;
    assign dbg_commit_last     = commit_last;
    assign dbg_sticky_valid    = sticky_issue;

    always_comb begin
        for (int k = 0; k < CORE_NUM; k = k + 1)
            core_occupied[k] = (~core_in_ready[k]) | core_commit_mask[k];
    end

    // Fast FIFO storage is deliberately isolated from reset/control logic so
    // synthesis can infer distributed RAM instead of 32 x 550 bits of FFs.
    always_ff @(posedge clk) begin
        if (fast_push) begin
            fast_block_mem[fast_wr_ptr] <= block_data;
            fast_msg_mem[fast_wr_ptr]   <= msg_id_in;
            fast_ctx_mem[fast_wr_ptr]   <= block_ctx_id_in;
        end
    end

    // ------------------------------------------------------------------
    // Sequential metadata/control state.
    // ------------------------------------------------------------------
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctx_valid         <= '0;
            ctx_pending_valid <= '0;
            ctx_inflight      <= '0;
            ctx_last_accepted <= '0;
            core_reserved     <= '0;
            sched_gnt_valid_q <= 1'b0;
            sched_gnt_ctx_q   <= '0;
            sched_gnt_core_q  <= '0;
            sched_gnt_fast_q  <= 1'b0;
            sched_gnt_ctx_found_q <= 1'b0;
            launch_valid      <= 1'b0;
            launch_pending    <= 1'b0;
            launch_is_fast    <= 1'b0;
            launch_ctx_id     <= '0;
            launch_msg_id     <= '0;
            launch_fast_block <= '0;
            launch_block_q    <= '0;
            launch_hash_q     <= '0;
            launch_last_q     <= 1'b0;
            launch_core_id    <= '0;
            launch_hash_bypass <= 1'b0;
            launch_hash_value  <= '0;
            fast_wr_ptr       <= '0;
            fast_rd_ptr       <= '0;
            fast_count        <= '0;
            fast_burst_count  <= '0;
            ctx_rr_ptr         <= '0;
            fast_pressure_count <= '0;
            result_valid <= 1'b0;
            digest_out   <= '0;
            msg_id_out   <= '0;
            ctx_id_out   <= '0;
            result_fast  <= 1'b0;

            for (i = 0; i < CTX_NUM; i = i + 1) begin
                ctx_msg_id[i] <= '0;
                ctx_head[i]   <= '0;
                ctx_tail[i]   <= '0;
                ctx_single[i] <= 1'b0;
            end
            for (i = 0; i < CORE_NUM; i = i + 1)
                core_quantum[i] <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;

            if (fast_push) begin
                if (fast_wr_ptr == FAST_PTR_W'(FAST_DEPTH-1))
                    fast_wr_ptr <= '0;
                else
                    fast_wr_ptr <= fast_wr_ptr + 1'b1;
            end

            // Context ownership and message identity are established on the
            // first multi-block enqueue. Later blocks may accumulate freely in
            // the global pool while an earlier block is inflight.
            if (multi_push) begin
                if (block_first_in) begin
                    ctx_valid[push_ctx_idx]         <= 1'b1;
                    ctx_msg_id[push_ctx_idx]        <= msg_id_in;
                    ctx_last_accepted[push_ctx_idx] <= block_last_in;
                end else if (block_last_in) begin
                    ctx_last_accepted[push_ctx_idx] <= 1'b1;
                end
            end

            // Queue metadata update, including simultaneous enqueue/dequeue of
            // the same context.  ctx_single is an exact one-element flag in
            // steady state; after a multi-element pop it is recomputed when
            // pop_head_s2 commits the successor.
            if (multi_push && !ctx_pop) begin
                if (!ctx_pending_valid[push_ctx_idx]) begin
                    ctx_head[push_ctx_idx] <= pool_alloc_slot;
                    ctx_tail[push_ctx_idx] <= pool_alloc_slot;
                    ctx_pending_valid[push_ctx_idx] <= 1'b1;
                    ctx_single[push_ctx_idx] <= 1'b1;
                end else begin
                    ctx_tail[push_ctx_idx] <= pool_alloc_slot;
                    ctx_single[push_ctx_idx] <= 1'b0;
                end
            end else if (!multi_push && ctx_pop) begin
                if (pop_single_old)
                    ctx_pending_valid[pop_ctx_idx] <= 1'b0;
                // The successor commit below re-evaluates whether a
                // multi-element queue became single.
                ctx_single[pop_ctx_idx] <= 1'b0;
            end else if (multi_push && ctx_pop) begin
                if (push_ctx_idx == pop_ctx_idx) begin
                    // The new slot is linked after the old tail (the link write
                    // above is unconditional).  The head advances through the
                    // normal pop_head_s2 path, including the one-element case.
                    ctx_tail[pop_ctx_idx] <= pool_alloc_slot;
                    ctx_pending_valid[pop_ctx_idx] <= 1'b1;
                    ctx_single[pop_ctx_idx] <= pop_single_old;
                end else begin
                    // Push context.
                    if (!ctx_pending_valid[push_ctx_idx]) begin
                        ctx_head[push_ctx_idx] <= pool_alloc_slot;
                        ctx_tail[push_ctx_idx] <= pool_alloc_slot;
                        ctx_pending_valid[push_ctx_idx] <= 1'b1;
                        ctx_single[push_ctx_idx] <= 1'b1;
                    end else begin
                        ctx_tail[push_ctx_idx] <= pool_alloc_slot;
                        ctx_single[push_ctx_idx] <= 1'b0;
                    end
                    // Pop context.
                    if (pop_single_old)
                        ctx_pending_valid[pop_ctx_idx] <= 1'b0;
                    ctx_single[pop_ctx_idx] <= 1'b0;
                end
            end

            // Retire a linked-list pop after its synchronous RAM lookup.
            // pop_head_new/pop_tail_next also maintain the exact one-element
            // flag, including late pushes in the same cycle.
            if (pop_head_s2) begin
                if (pop_single_s2 && pop_push_same_s2)
                    ctx_head[pop_head_ctx_s2] <= pop_new_slot_s2;
                else if (!pop_single_s2)
                    ctx_head[pop_head_ctx_s2] <= pool_link_rd_next;

                if (!pop_single_s2 || pop_push_same_s2)
                    ctx_single[pop_head_ctx_s2] <= (pop_head_new == pop_tail_next);
            end

            // Capture the synchronous block-pool/hash read one cycle after
            // issue.  The following cycle launches from these registers, so
            // the BRAM output does not have to reach the core w load in the
            // same cycle.  The wide payload registers capture every cycle to
            // keep launch_pending off a 700+ fanout clock-enable net.
            if (launch_pending) begin
                launch_valid   <= 1'b1;
                launch_pending <= 1'b0;
            end else if (launch_fire) begin
                launch_valid <= 1'b0;
            end
            launch_block_q <= pool_rd_block;
            launch_hash_q  <= launch_hash_bypass ? launch_hash_value
                            : (pool_rd_first ? SM3_IV : hash_rd_state);
            launch_last_q  <= pool_rd_last;

            if (launch_fire)
                core_reserved[launch_core_id] <= 1'b0;

            if (sched_accept) begin
                sched_gnt_valid_q     <= 1'b1;
                sched_gnt_ctx_q       <= sched_ctx_sel;
                sched_gnt_core_q      <= sched_core_sel;
                sched_gnt_fast_q      <= sched_use_fast;
                sched_gnt_ctx_found_q <= sched_ctx_found;
            end else if (sched_issue) begin
                sched_gnt_valid_q <= 1'b0;
            end

            if (sched_issue) begin
                launch_pending     <= 1'b1;
                launch_is_fast     <= sched_gnt_fast_q;
                launch_core_id     <= sched_gnt_core_q;
                launch_hash_bypass <= 1'b0;
                core_reserved[sched_gnt_core_q] <= 1'b1;
                core_quantum[sched_gnt_core_q] <= sched_gnt_fast_q ? '0 : QUANTUM_W'(1);

                if (sched_gnt_fast_q) begin
                    launch_ctx_id     <= fast_ctx_mem[fast_rd_ptr];
                    launch_msg_id     <= fast_msg_mem[fast_rd_ptr];
                    launch_fast_block <= fast_block_mem[fast_rd_ptr];
                    if (fast_rd_ptr == FAST_PTR_W'(FAST_DEPTH-1))
                        fast_rd_ptr <= '0;
                    else
                        fast_rd_ptr <= fast_rd_ptr + 1'b1;
                end else begin
                    launch_ctx_id <= sched_gnt_ctx_q;
                    launch_msg_id <= '0;
                    ctx_inflight[sched_gnt_ctx_q] <= 1'b1;
                    if (sched_gnt_ctx_q == CTX_ID_W'(CTX_NUM-1))
                        ctx_rr_ptr <= '0;
                    else
                        ctx_rr_ptr <= sched_gnt_ctx_q + 1'b1;
                end
            end

            if (sticky_issue) begin
                launch_pending     <= 1'b1;
                launch_is_fast     <= 1'b0;
                launch_ctx_id      <= commit_ctx_id;
                launch_msg_id      <= '0;
                launch_core_id     <= commit_core_q;
                launch_hash_bypass <= 1'b1;
                launch_hash_value  <= commit_hash;
                core_reserved[commit_core_q] <= 1'b1;
                core_quantum[commit_core_q] <= core_quantum[commit_core_q] + 1'b1;
            end

            if (fast_push)
                fast_pressure_count <= PRESSURE_W'(FAST_PRESSURE_HOLD);
            else if (fast_pressure_count != 0)
                fast_pressure_count <= fast_pressure_count - 1'b1;

            case ({fast_push, fast_pop})
                2'b10: fast_count <= fast_count + 1'b1;
                2'b01: fast_count <= fast_count - 1'b1;
                default: fast_count <= fast_count;
            endcase

            if (sched_issue) begin
                if (sched_gnt_fast_q) begin
                    if (sched_gnt_ctx_found_q) begin
                        if (fast_burst_count < FAST_BURST_W'(FAST_QUOTA))
                            fast_burst_count <= fast_burst_count + 1'b1;
                    end else begin
                        fast_burst_count <= '0;
                    end
                end else begin
                    fast_burst_count <= '0;
                end
            end

            if (commit_fire) begin
                if (commit_is_fast) begin
                    result_valid <= 1'b1;
                    digest_out   <= commit_hash;
                    msg_id_out   <= commit_msg_id;
                    ctx_id_out   <= commit_ctx_id;
                    result_fast  <= 1'b1;
                    core_quantum[commit_core_q] <= '0;
                end else if (!commit_ctx_in_range) begin
`ifndef SYNTHESIS
                    $error("SM3 commit returned invalid context id %0d", commit_ctx_id);
`endif
                end else if (!commit_ctx_valid_q || !commit_ctx_inflight_q) begin
`ifndef SYNTHESIS
                    $error("SM3 commit on inactive/non-inflight context %0d", commit_ctx_id);
`endif
                end else if (commit_last) begin
`ifndef SYNTHESIS
                    if (ctx_pending_valid[commit_ctx_id])
                        $error("SM3 final commit while context %0d still has queued blocks", commit_ctx_id);
`endif
                    result_valid <= 1'b1;
                    digest_out   <= commit_hash;
                    msg_id_out   <= ctx_msg_id[commit_ctx_id];
                    ctx_id_out   <= commit_ctx_id;
                    result_fast  <= 1'b0;
                    ctx_valid[commit_ctx_id]         <= 1'b0;
                    ctx_pending_valid[commit_ctx_id] <= 1'b0;
                    ctx_inflight[commit_ctx_id]      <= 1'b0;
                    ctx_last_accepted[commit_ctx_id] <= 1'b0;
                    core_quantum[commit_core_q] <= '0;
                end else if (!sticky_issue) begin
                    ctx_inflight[commit_ctx_id] <= 1'b0;
                    core_quantum[commit_core_q] <= '0;
                end
            end
        end
    end

    sm3_block_pool #(
        .POOL_DEPTH(POOL_DEPTH)
    ) u_block_pool (
        .clk          (clk),
        .rst_n        (rst_n),
        .init_done    (pool_init_done),
        .free_count   (pool_free_count),
        .alloc_valid  (pool_alloc_valid),
        .alloc_ready  (pool_alloc_ready),
        .alloc_slot   (pool_alloc_slot),
        .alloc_block  (block_data),
        .alloc_first  (block_first_in),
        .alloc_last   (block_last_in),
        .free_valid   (pool_free_valid),
        .free_slot    (pool_free_slot),
        .link_wr_en   (pool_link_wr_en),
        .link_wr_slot (pool_link_wr_slot),
        .link_wr_next (pool_link_wr_next),
        .link_rd_en   (pool_link_rd_en),
        .link_rd_slot (pool_link_rd_slot),
        .link_rd_next (pool_link_rd_next),
        .rd_en        (pool_rd_en),
        .rd_slot      (pool_rd_slot),
        .rd_block     (pool_rd_block),
        .rd_first     (pool_rd_first),
        .rd_last      (pool_rd_last)
    );

    genvar g;
    generate
        for (g = 0; g < CORE_NUM; g = g + 1) begin : g_core
            sm3_core #(.MSG_ID_W(TAG_W)) u_core (
                .clk            (clk),
                .rst_n          (rst_n),
                .in_valid       (core_in_valid[g]),
                .in_ready       (core_in_ready[g]),
                .block_data     (core_launch_block),
                .hash_in        (core_launch_hash),
                .msg_id_in      (core_launch_tag),
                .block_last_in  (core_launch_last),
                .out_valid      (core_out_valid[g]),
                .out_ready      (core_out_ready[g]),
                .hash_out       (core_hash_out[g]),
                .msg_id_out     (core_tag_out[g]),
                .block_last_out (core_last_out[g])
            );
        end
    endgenerate

endmodule
