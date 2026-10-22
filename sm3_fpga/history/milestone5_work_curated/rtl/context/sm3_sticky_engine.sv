module sm3_sticky_engine #(
    parameter int CORE_NUM   = 8,
    parameter int CTX_NUM    = 32,
    parameter int MSG_ID_W   = 32,
    parameter int FAST_DEPTH = 32,
    parameter int FAST_QUOTA = 3,
    parameter int STICKY_QUANTUM = 4,
    parameter int CTX_ID_W   = (CTX_NUM <= 1) ? 1 : $clog2(CTX_NUM),
    parameter int CORE_ID_W  = (CORE_NUM <= 1) ? 1 : $clog2(CORE_NUM),
    parameter int FAST_PTR_W = (FAST_DEPTH <= 1) ? 1 : $clog2(FAST_DEPTH),
    parameter int FAST_CNT_W = $clog2(FAST_DEPTH + 1),
    parameter int FAST_BURST_W = (FAST_QUOTA <= 1) ? 1 : $clog2(FAST_QUOTA + 1),
    parameter int QUANTUM_W = (STICKY_QUANTUM <= 1) ? 1 : $clog2(STICKY_QUANTUM + 1),
    parameter int TAG_W      = 1 + MSG_ID_W + CTX_ID_W
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Pre-padded 512-bit SM3 block stream.
    // Single-block messages (first && last) bypass Context RAM.
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

    // Debug/status.
    output logic [CORE_NUM-1:0]      core_occupied,
    output logic [CTX_NUM-1:0]       ctx_valid_bitmap,
    output logic [CTX_NUM-1:0]       ctx_pending_bitmap,
    output logic [CTX_NUM-1:0]       ctx_inflight_bitmap,
    output logic [FAST_CNT_W-1:0]    fast_level,

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
    // Context metadata for multi-block messages.
    // ------------------------------------------------------------------
    logic [CTX_NUM-1:0] ctx_valid;
    logic [CTX_NUM-1:0] ctx_pending_valid;
    logic [CTX_NUM-1:0] ctx_inflight;
    logic [CTX_NUM-1:0] ctx_last_accepted;
    logic [MSG_ID_W-1:0] ctx_msg_id [0:CTX_NUM-1];

    assign ctx_valid_bitmap    = ctx_valid;
    assign ctx_pending_bitmap  = ctx_pending_valid;
    assign ctx_inflight_bitmap = ctx_inflight;

    // ------------------------------------------------------------------
    // Fast FIFO for independent single-block messages.
    // This is intentionally small and decouples input admission from core issue.
    // ------------------------------------------------------------------
    logic [511:0]        fast_block_mem [0:FAST_DEPTH-1];
    logic [MSG_ID_W-1:0] fast_msg_mem   [0:FAST_DEPTH-1];
    logic [CTX_ID_W-1:0] fast_ctx_mem   [0:FAST_DEPTH-1];
    logic [FAST_PTR_W-1:0] fast_wr_ptr, fast_rd_ptr;
    logic [FAST_CNT_W-1:0] fast_count;
    logic fast_push, fast_pop;
    logic fast_full, fast_empty;

    assign fast_full  = (fast_count == FAST_CNT_W'(FAST_DEPTH));
    assign fast_empty = (fast_count == 0);
    assign fast_level = fast_count;

    // ------------------------------------------------------------------
    // Context/block RAM interface.
    // ------------------------------------------------------------------
    logic                store_block_wr_en;
    logic [CTX_ID_W-1:0] store_block_wr_addr;
    logic [511:0]        store_block_wr_data;
    logic                store_block_wr_first;
    logic                store_block_wr_last;
    logic                store_hash_wr_en;
    logic [CTX_ID_W-1:0] store_hash_wr_addr;
    logic [255:0]        store_hash_wr_data;
    logic                store_rd_en;
    logic [CTX_ID_W-1:0] store_rd_addr;
    logic [511:0]        store_rd_block_data;
    logic                store_rd_block_first;
    logic                store_rd_block_last;
    logic [255:0]        store_rd_hash_state;

    // ------------------------------------------------------------------
    // Core bank. sm3_core's msg_id field is used as an opaque completion tag.
    // tag = {is_fast, actual_msg_id, ctx_id}.
    // ------------------------------------------------------------------
    logic [CORE_NUM-1:0] core_in_valid;
    logic [CORE_NUM-1:0] core_in_ready;
    logic [CORE_NUM-1:0] core_out_valid;
    logic [CORE_NUM-1:0] core_out_ready;
    logic [CORE_NUM-1:0] core_reserved;
    logic [255:0]        core_hash_out [0:CORE_NUM-1];
    logic [TAG_W-1:0]    core_tag_out  [0:CORE_NUM-1];
    logic                core_last_out [0:CORE_NUM-1];

    // One-entry issue pipeline. Context reads are synchronous; fast blocks are
    // latched at scheduler selection so both sources share the same launch slot.
    integer sched_core_sel;
    integer sched_ctx_sel;
    logic   sched_use_fast;
    logic   sched_fire;
    logic   launch_valid;
    logic   launch_is_fast;
    logic [CTX_ID_W-1:0] launch_ctx_id;
    logic [MSG_ID_W-1:0] launch_msg_id;
    logic [511:0]        launch_fast_block;
    logic [CORE_ID_W-1:0] launch_core_id;
    logic   launch_fire;
    logic   launch_pipe_ready;
    logic [FAST_BURST_W-1:0] fast_burst_count;
    logic [QUANTUM_W-1:0] core_quantum [0:CORE_NUM-1];
    logic                  launch_hash_bypass;
    logic [255:0]          launch_hash_value;
    logic                  sticky_issue;

    logic [511:0]      core_launch_block;
    logic [255:0]      core_launch_hash;
    logic              core_launch_last;
    logic [TAG_W-1:0] core_launch_tag;

    // Completion arbitration.
    integer commit_core_sel;
    integer commit_ctx_idx;
    logic   commit_fire;
    logic   commit_last;
    logic   commit_is_fast;
    logic [CTX_ID_W-1:0] commit_ctx_id;
    logic [MSG_ID_W-1:0] commit_msg_id;
    logic [255:0] commit_hash;
        logic result_slot_available;

    integer input_ctx_idx;
    logic input_is_fast;

    // ------------------------------------------------------------------
    // Input admission.
    // Single-block messages never allocate/touch Context RAM.
    // Multi-block contexts support one inflight + one pending block.
    // ------------------------------------------------------------------
    always_comb begin
        input_ctx_idx = int'(block_ctx_id_in);
        input_is_fast = block_first_in && block_last_in;
        block_ready = 1'b0;

        if (input_is_fast) begin
            block_ready = !fast_full;
        end else if (input_ctx_idx < CTX_NUM) begin
            if (block_first_in) begin
                block_ready = !ctx_valid[input_ctx_idx];
            end else begin
                block_ready = ctx_valid[input_ctx_idx]
                           && (ctx_msg_id[input_ctx_idx] == msg_id_in)
                           && !ctx_pending_valid[input_ctx_idx]
                           && !ctx_last_accepted[input_ctx_idx];
            end
        end
    end

    assign fast_push = block_valid && block_ready && input_is_fast;

    assign store_block_wr_en    = block_valid && block_ready && !input_is_fast;
    assign store_block_wr_addr  = block_ctx_id_in;
    assign store_block_wr_data  = block_data;
    assign store_block_wr_first = block_first_in;
    assign store_block_wr_last  = block_last_in;

    // ------------------------------------------------------------------
    // Scheduler: choose one free core and one source per cycle.
    // If both sources are continuously ready, FAST_QUOTA fast blocks are
    // followed by one context block, preventing multi-block starvation.
    // ------------------------------------------------------------------
    assign launch_fire       = launch_valid && core_in_ready[launch_core_id];
    assign launch_pipe_ready = !launch_valid || launch_fire;

    always_comb begin
        sched_core_sel = -1;
        sched_ctx_sel  = -1;
        sched_use_fast = 1'b0;

        if (launch_pipe_ready) begin
            for (int k = 0; k < CORE_NUM; k = k + 1) begin
                if ((sched_core_sel < 0) && core_in_ready[k] && !core_reserved[k])
                    sched_core_sel = k;
            end

            for (int c = 0; c < CTX_NUM; c = c + 1) begin
                if ((sched_ctx_sel < 0)
                    && ctx_valid[c]
                    && ctx_pending_valid[c]
                    && !ctx_inflight[c]) begin
                    sched_ctx_sel = c;
                end
            end

            if (!fast_empty && (sched_ctx_sel < 0)) begin
                sched_use_fast = 1'b1;
            end else if (!fast_empty && (fast_burst_count < FAST_BURST_W'(FAST_QUOTA))) begin
                sched_use_fast = 1'b1;
            end
        end
    end

    assign sched_fire = !sticky_issue
                     && (sched_core_sel >= 0)
                     && (sched_use_fast || (sched_ctx_sel >= 0));
    assign fast_pop = sched_fire && sched_use_fast;

    assign store_rd_en = sticky_issue || (sched_fire && !sched_use_fast);
    assign store_rd_addr = sticky_issue ? commit_ctx_id
                         : ((sched_ctx_sel >= 0) ? CTX_ID_W'(sched_ctx_sel) : '0);

    always_comb begin
        core_in_valid = '0;
        if (launch_valid)
            core_in_valid[launch_core_id] = 1'b1;

        core_launch_block = launch_is_fast ? launch_fast_block : store_rd_block_data;
        core_launch_hash  = launch_is_fast ? SM3_IV
                         : (launch_hash_bypass ? launch_hash_value
                         : (store_rd_block_first ? SM3_IV : store_rd_hash_state));
        core_launch_last  = launch_is_fast ? 1'b1 : store_rd_block_last;
        core_launch_tag   = {launch_is_fast,
                             (launch_is_fast ? launch_msg_id : {MSG_ID_W{1'b0}}),
                             launch_ctx_id};
    end

    assign dbg_dispatch_valid  = launch_fire;
    assign dbg_dispatch_fast   = launch_fire && launch_is_fast;
    assign dbg_dispatch_ctx_id = launch_ctx_id;

    // ------------------------------------------------------------------
    // Completion arbiter. Fast completions and final context completions need
    // the result slot. Non-final context commits can always make progress.
    // ------------------------------------------------------------------
    assign result_slot_available = !result_valid || result_ready;

    always_comb begin
        commit_core_sel = -1;
        core_out_ready  = '0;
        for (int k = 0; k < CORE_NUM; k = k + 1) begin
            if ((commit_core_sel < 0) && core_out_valid[k])
                commit_core_sel = k;
        end

        if (commit_core_sel >= 0) begin
            if ((!core_tag_out[commit_core_sel][TAG_W-1]
                 && !core_last_out[commit_core_sel]) || result_slot_available)
                core_out_ready[commit_core_sel] = 1'b1;
        end
    end

    always_comb begin
        commit_fire    = 1'b0;
        commit_last    = 1'b0;
        commit_is_fast = 1'b0;
        commit_ctx_id  = '0;
        commit_msg_id  = '0;
        commit_hash    = '0;
        commit_ctx_idx = 0;

        if (commit_core_sel >= 0) begin
            commit_fire    = core_out_valid[commit_core_sel]
                           && core_out_ready[commit_core_sel];
            commit_last    = core_last_out[commit_core_sel];
            commit_hash    = core_hash_out[commit_core_sel];
            commit_is_fast = core_tag_out[commit_core_sel][TAG_W-1];
            commit_msg_id  = core_tag_out[commit_core_sel][CTX_ID_W +: MSG_ID_W];
            commit_ctx_id  = core_tag_out[commit_core_sel][CTX_ID_W-1:0];
            commit_ctx_idx = int'(core_tag_out[commit_core_sel][CTX_ID_W-1:0]);
        end
    end

    // A non-final context completion may immediately consume its already
    // prefetched next block on the same core. The synchronous RAM read occupies
    // the shared issue port for one cycle.
    always_comb begin
        sticky_issue = 1'b0;
        if (launch_pipe_ready
            && commit_fire
            && !commit_is_fast
            && !commit_last
            && (commit_ctx_idx >= 0)
            && (commit_ctx_idx < CTX_NUM)
            && ctx_pending_valid[commit_ctx_idx]
            && (core_quantum[commit_core_sel] < QUANTUM_W'(STICKY_QUANTUM))) begin
            sticky_issue = 1'b1;
        end
    end

    assign dbg_sticky_valid = sticky_issue;

    assign dbg_commit_valid  = commit_fire;
    assign dbg_commit_fast   = commit_fire && commit_is_fast;
    assign dbg_commit_ctx_id = commit_ctx_id;
    assign dbg_commit_last   = commit_last;

    assign store_hash_wr_en   = commit_fire && !commit_is_fast && !commit_last
                              && !sticky_issue;
    assign store_hash_wr_addr = commit_ctx_id;
    assign store_hash_wr_data = commit_hash;

    always_comb begin
        for (int k = 0; k < CORE_NUM; k = k + 1)
            core_occupied[k] = (~core_in_ready[k]) | core_reserved[k];
    end

    // ------------------------------------------------------------------
    // State updates.
    // ------------------------------------------------------------------
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctx_valid         <= '0;
            ctx_pending_valid <= '0;
            ctx_inflight      <= '0;
            ctx_last_accepted <= '0;
            core_reserved     <= '0;
            launch_valid      <= 1'b0;
            launch_is_fast    <= 1'b0;
            launch_ctx_id     <= '0;
            launch_msg_id     <= '0;
            launch_fast_block <= '0;
            launch_core_id    <= '0;
            launch_hash_bypass <= 1'b0;
            launch_hash_value  <= '0;
            fast_wr_ptr       <= '0;
            fast_rd_ptr       <= '0;
            fast_count        <= '0;
            fast_burst_count  <= '0;

            result_valid <= 1'b0;
            digest_out   <= '0;
            msg_id_out   <= '0;
            ctx_id_out   <= '0;

            for (i = 0; i < CTX_NUM; i = i + 1)
                ctx_msg_id[i] <= '0;
            for (i = 0; i < CORE_NUM; i = i + 1)
                core_quantum[i] <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;

            // Fast FIFO push.
            if (fast_push) begin
                fast_block_mem[fast_wr_ptr] <= block_data;
                fast_msg_mem[fast_wr_ptr]   <= msg_id_in;
                fast_ctx_mem[fast_wr_ptr]   <= block_ctx_id_in;
                if (fast_wr_ptr == FAST_PTR_W'(FAST_DEPTH-1))
                    fast_wr_ptr <= '0;
                else
                    fast_wr_ptr <= fast_wr_ptr + 1'b1;
            end

            // Multi-block input becomes the pending block of its context.
            if (block_valid && block_ready && !input_is_fast) begin
                if (block_first_in) begin
                    ctx_valid[input_ctx_idx]         <= 1'b1;
                    ctx_msg_id[input_ctx_idx]        <= msg_id_in;
                    ctx_last_accepted[input_ctx_idx] <= block_last_in;
                end else if (block_last_in) begin
                    ctx_last_accepted[input_ctx_idx] <= 1'b1;
                end
                ctx_pending_valid[input_ctx_idx] <= 1'b1;
            end

            // Consume previous launch slot.
            if (launch_fire) begin
                launch_valid <= 1'b0;
                core_reserved[launch_core_id] <= 1'b0;
            end

            // Reserve selected core and source into launch slot.
            if (sched_fire) begin
                launch_valid       <= 1'b1;
                launch_is_fast     <= sched_use_fast;
                launch_core_id     <= CORE_ID_W'(sched_core_sel);
                launch_hash_bypass <= 1'b0;
                core_reserved[sched_core_sel] <= 1'b1;
                core_quantum[sched_core_sel] <= sched_use_fast ? '0 : QUANTUM_W'(1);

                if (sched_use_fast) begin
                    launch_ctx_id     <= fast_ctx_mem[fast_rd_ptr];
                    launch_msg_id     <= fast_msg_mem[fast_rd_ptr];
                    launch_fast_block <= fast_block_mem[fast_rd_ptr];
                    if (fast_rd_ptr == FAST_PTR_W'(FAST_DEPTH-1))
                        fast_rd_ptr <= '0;
                    else
                        fast_rd_ptr <= fast_rd_ptr + 1'b1;
                end else begin
                    launch_ctx_id  <= CTX_ID_W'(sched_ctx_sel);
                    launch_msg_id  <= '0;
                    ctx_pending_valid[sched_ctx_sel] <= 1'b0;
                    ctx_inflight[sched_ctx_sel]      <= 1'b1;
                end
            end

            // Sticky continuation keeps the context inflight and feeds the
            // completion hash directly into the next block on the same core.
            if (sticky_issue) begin
                launch_valid       <= 1'b1;
                launch_is_fast     <= 1'b0;
                launch_ctx_id      <= commit_ctx_id;
                launch_msg_id      <= '0;
                launch_core_id     <= CORE_ID_W'(commit_core_sel);
                launch_hash_bypass <= 1'b1;
                launch_hash_value  <= commit_hash;
                core_reserved[commit_core_sel] <= 1'b1;
                ctx_pending_valid[commit_ctx_idx] <= 1'b0;
                core_quantum[commit_core_sel] <= core_quantum[commit_core_sel] + 1'b1;
            end

            // Fast FIFO occupancy supports simultaneous push/pop.
            case ({fast_push, fast_pop})
                2'b10: fast_count <= fast_count + 1'b1;
                2'b01: fast_count <= fast_count - 1'b1;
                default: fast_count <= fast_count;
            endcase

            // Weighted source quota counts only successful scheduler selections.
            if (sched_fire) begin
                if (sched_use_fast) begin
                    if (sched_ctx_sel >= 0) begin
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
                    // Single-block messages never touch context state.
                    result_valid <= 1'b1;
                    digest_out   <= commit_hash;
                    msg_id_out   <= commit_msg_id;
                    ctx_id_out   <= commit_ctx_id;
                    core_quantum[commit_core_sel] <= '0;
                end else if ((commit_ctx_idx < 0) || (commit_ctx_idx >= CTX_NUM)) begin
                    $error("SM3 commit returned invalid context id %0d", commit_ctx_idx);
                end else if (!ctx_valid[commit_ctx_idx] || !ctx_inflight[commit_ctx_idx]) begin
                    $error("SM3 commit on inactive/non-inflight context %0d", commit_ctx_idx);
                end else if (commit_last) begin
                    result_valid <= 1'b1;
                    digest_out   <= commit_hash;
                    msg_id_out   <= ctx_msg_id[commit_ctx_idx];
                    ctx_id_out   <= commit_ctx_id;

                    ctx_valid[commit_ctx_idx]         <= 1'b0;
                    ctx_pending_valid[commit_ctx_idx] <= 1'b0;
                    ctx_inflight[commit_ctx_idx]      <= 1'b0;
                    ctx_last_accepted[commit_ctx_idx] <= 1'b0;
                    core_quantum[commit_core_sel] <= '0;
                end else if (!sticky_issue) begin
                    ctx_inflight[commit_ctx_idx] <= 1'b0;
                    core_quantum[commit_core_sel] <= '0;
                end
            end
        end
    end

    sm3_context_store #(
        .CTX_NUM (CTX_NUM),
        .CTX_ID_W(CTX_ID_W)
    ) u_context_store (
        .clk            (clk),
        .block_wr_en    (store_block_wr_en),
        .block_wr_addr  (store_block_wr_addr),
        .block_wr_data  (store_block_wr_data),
        .block_wr_first (store_block_wr_first),
        .block_wr_last  (store_block_wr_last),
        .hash_wr_en     (store_hash_wr_en),
        .hash_wr_addr   (store_hash_wr_addr),
        .hash_wr_data   (store_hash_wr_data),
        .rd_en          (store_rd_en),
        .rd_addr        (store_rd_addr),
        .rd_block_data  (store_rd_block_data),
        .rd_block_first (store_rd_block_first),
        .rd_block_last  (store_rd_block_last),
        .rd_hash_state  (store_rd_hash_state)
    );

    genvar g;
    generate
        for (g = 0; g < CORE_NUM; g = g + 1) begin : g_core
            sm3_core #(
                .MSG_ID_W(TAG_W)
            ) u_core (
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
