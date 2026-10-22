module sm3_multiblock_engine #(
    parameter int CORE_NUM = 8,
    parameter int CTX_NUM  = 32,
    parameter int MSG_ID_W = 32,
    parameter int CTX_ID_W = (CTX_NUM <= 1) ? 1 : $clog2(CTX_NUM)
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // Pre-padded 512-bit SM3 block stream.
    // ctx_id is allocated by the upstream descriptor/context allocator.
    input  logic                     block_valid,
    output logic                     block_ready,
    input  logic [511:0]             block_data,
    input  logic [CTX_ID_W-1:0]      block_ctx_id_in,
    input  logic [MSG_ID_W-1:0]      msg_id_in,
    input  logic                     block_first_in,
    input  logic                     block_last_in,

    // One digest per message. Completion order may differ from arrival order.
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

    output logic                     dbg_dispatch_valid,
    output logic [CTX_ID_W-1:0]      dbg_dispatch_ctx_id,
    output logic                     dbg_commit_valid,
    output logic [CTX_ID_W-1:0]      dbg_commit_ctx_id,
    output logic                     dbg_commit_last
);

    localparam logic [255:0] SM3_IV =
        256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    logic [CTX_NUM-1:0] ctx_valid;
    logic [CTX_NUM-1:0] ctx_pending_valid;
    logic [CTX_NUM-1:0] ctx_inflight;
    logic [CTX_NUM-1:0] ctx_last_accepted;
    logic [MSG_ID_W-1:0] ctx_msg_id [0:CTX_NUM-1];

    // Context/block RAM interface.
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

    // Core bank.
    logic [CORE_NUM-1:0] core_in_valid;
    logic [CORE_NUM-1:0] core_in_ready;
    logic [CORE_NUM-1:0] core_out_valid;
    logic [CORE_NUM-1:0] core_out_ready;
    logic [CORE_NUM-1:0] core_reserved;
    logic [255:0]        core_hash_out [0:CORE_NUM-1];
    logic [CTX_ID_W-1:0] core_ctx_out  [0:CORE_NUM-1];
    logic                core_last_out [0:CORE_NUM-1];

    // Scheduler select stage and synchronous-RAM launch stage.
    integer sched_core_sel;
    integer sched_ctx_sel;
    logic   sched_fire;
    logic   launch_valid;
    logic [CTX_ID_W-1:0] launch_ctx_id;
    logic [(CORE_NUM <= 1 ? 1 : $clog2(CORE_NUM))-1:0] launch_core_id;
    logic   launch_fire;
    logic   launch_pipe_ready;

    // Completion arbitration.
    integer commit_core_sel;
    integer commit_ctx_idx;
    logic   commit_fire;
    logic   commit_last;
    logic [CTX_ID_W-1:0] commit_ctx_id;
    logic [255:0] commit_hash;
    logic result_slot_available;

    integer input_ctx_idx;

    assign ctx_valid_bitmap    = ctx_valid;
    assign ctx_pending_bitmap  = ctx_pending_valid;
    assign ctx_inflight_bitmap = ctx_inflight;

    // ------------------------------------------------------------------
    // Input admission. A context supports one inflight + one pending block.
    // ------------------------------------------------------------------
    always_comb begin
        input_ctx_idx = int'(block_ctx_id_in);
        block_ready = 1'b0;
        if (input_ctx_idx < CTX_NUM) begin
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

    assign store_block_wr_en    = block_valid && block_ready;
    assign store_block_wr_addr  = block_ctx_id_in;
    assign store_block_wr_data  = block_data;
    assign store_block_wr_first = block_first_in;
    assign store_block_wr_last  = block_last_in;

    // ------------------------------------------------------------------
    // Scheduler select stage. It reserves a core and starts a synchronous
    // Context/Block RAM read. Actual core launch happens one cycle later.
    // ------------------------------------------------------------------
    assign launch_fire = launch_valid && core_in_ready[launch_core_id];
    assign launch_pipe_ready = !launch_valid || launch_fire;

    always_comb begin
        sched_core_sel = -1;
        sched_ctx_sel  = -1;

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
        end
    end

    assign sched_fire = (sched_core_sel >= 0) && (sched_ctx_sel >= 0);
    assign store_rd_en   = sched_fire;
    assign store_rd_addr = (sched_ctx_sel >= 0) ? CTX_ID_W'(sched_ctx_sel) : '0;

    // Launch the RAM output into exactly the reserved core.
    always_comb begin
        core_in_valid = '0;
        if (launch_valid)
            core_in_valid[launch_core_id] = 1'b1;
    end

    assign dbg_dispatch_valid  = launch_fire;
    assign dbg_dispatch_ctx_id = launch_ctx_id;

    // ------------------------------------------------------------------
    // Completion arbiter. Non-final commits always progress; final commits
    // wait only when the one-entry result register is full.
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
            if (!core_last_out[commit_core_sel] || result_slot_available)
                core_out_ready[commit_core_sel] = 1'b1;
        end
    end

    always_comb begin
        commit_fire    = 1'b0;
        commit_last    = 1'b0;
        commit_ctx_id  = '0;
        commit_hash    = '0;
        commit_ctx_idx = 0;

        if (commit_core_sel >= 0) begin
            commit_fire    = core_out_valid[commit_core_sel]
                           && core_out_ready[commit_core_sel];
            commit_last    = core_last_out[commit_core_sel];
            commit_ctx_id  = core_ctx_out[commit_core_sel];
            commit_hash    = core_hash_out[commit_core_sel];
            commit_ctx_idx = int'(core_ctx_out[commit_core_sel]);
        end
    end

    assign dbg_commit_valid  = commit_fire;
    assign dbg_commit_ctx_id = commit_ctx_id;
    assign dbg_commit_last   = commit_last;

    assign store_hash_wr_en   = commit_fire && !commit_last;
    assign store_hash_wr_addr = commit_ctx_id;
    assign store_hash_wr_data = commit_hash;

    always_comb begin
        for (int k = 0; k < CORE_NUM; k = k + 1)
            core_occupied[k] = (~core_in_ready[k]) | core_reserved[k];
    end

    // ------------------------------------------------------------------
    // Metadata, reservation, and result-register updates.
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
            launch_ctx_id     <= '0;
            launch_core_id    <= '0;

            result_valid <= 1'b0;
            digest_out   <= '0;
            msg_id_out   <= '0;
            ctx_id_out   <= '0;

            for (i = 0; i < CTX_NUM; i = i + 1)
                ctx_msg_id[i] <= '0;
        end else begin
            if (result_valid && result_ready)
                result_valid <= 1'b0;

            // Input block becomes the pending block of its context.
            if (block_valid && block_ready) begin
                if (block_first_in) begin
                    ctx_valid[input_ctx_idx]         <= 1'b1;
                    ctx_msg_id[input_ctx_idx]        <= msg_id_in;
                    ctx_last_accepted[input_ctx_idx] <= block_last_in;
                end else if (block_last_in) begin
                    ctx_last_accepted[input_ctx_idx] <= 1'b1;
                end
                ctx_pending_valid[input_ctx_idx] <= 1'b1;
            end

            // Previous RAM-read launch is consumed by its reserved core.
            if (launch_fire) begin
                launch_valid <= 1'b0;
                core_reserved[launch_core_id] <= 1'b0;
            end

            // Select next context/core and reserve both through the RAM read.
            if (sched_fire) begin
                launch_valid   <= 1'b1;
                launch_ctx_id  <= CTX_ID_W'(sched_ctx_sel);
                launch_core_id <= $clog2(CORE_NUM)'(sched_core_sel);
                core_reserved[sched_core_sel] <= 1'b1;

                ctx_pending_valid[sched_ctx_sel] <= 1'b0;
                ctx_inflight[sched_ctx_sel]      <= 1'b1;
            end

            if (commit_fire) begin
                if ((commit_ctx_idx < 0) || (commit_ctx_idx >= CTX_NUM)) begin
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
                end else begin
                    ctx_inflight[commit_ctx_idx] <= 1'b0;
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
                .MSG_ID_W(CTX_ID_W)
            ) u_core (
                .clk            (clk),
                .rst_n          (rst_n),
                .in_valid       (core_in_valid[g]),
                .in_ready       (core_in_ready[g]),
                .block_data     (store_rd_block_data),
                .hash_in        (store_rd_block_first ? SM3_IV : store_rd_hash_state),
                .msg_id_in      (launch_ctx_id),
                .block_last_in  (store_rd_block_last),
                .out_valid      (core_out_valid[g]),
                .out_ready      (core_out_ready[g]),
                .hash_out       (core_hash_out[g]),
                .msg_id_out     (core_ctx_out[g]),
                .block_last_out (core_last_out[g])
            );
        end
    endgenerate

endmodule
