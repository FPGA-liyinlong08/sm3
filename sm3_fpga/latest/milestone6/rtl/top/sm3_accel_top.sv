module sm3_accel_top #(
    parameter int CORE_NUM   = 8,
    parameter int CTX_NUM    = 32,
    parameter int MSG_ID_W   = 32,
    parameter int FAST_DEPTH = 32,
    parameter int POOL_DEPTH = 256,
    parameter int CTX_ID_W   = (CTX_NUM <= 1) ? 1 : $clog2(CTX_NUM),
    parameter int FAST_CNT_W = $clog2(FAST_DEPTH + 1),
    parameter int POOL_CNT_W = $clog2(POOL_DEPTH + 1)
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Raw-message descriptor.
    input  logic                    desc_valid,
    output logic                    desc_ready,
    input  logic [MSG_ID_W-1:0]     desc_msg_id,
    input  logic [31:0]             desc_len_bytes,

    // Raw payload, 128-bit / beat, MSB-first byte packing.
    input  logic                    s_valid,
    output logic                    s_ready,
    input  logic [127:0]            s_data,
    input  logic [15:0]             s_keep,

    // One digest per message; completion may be out of submission order.
    output logic                    result_valid,
    input  logic                    result_ready,
    output logic [255:0]            digest_out,
    output logic [MSG_ID_W-1:0]     result_msg_id,

    // Debug/status.
    output logic [CORE_NUM-1:0]     dbg_core_occupied,
    output logic [CTX_NUM-1:0]      dbg_ctx_allocated,
    output logic [FAST_CNT_W-1:0]   dbg_fast_level,
    output logic [POOL_CNT_W-1:0]   dbg_pool_free,
    output logic                    dbg_pool_init_done
);

    // Block-builder stream.
    logic                  bb_valid;
    logic                  bb_desc_ready;
    logic                  bb_ready;
    logic [511:0]          bb_data;
    logic [MSG_ID_W-1:0]   bb_msg_id;
    logic                  bb_first;
    logic                  bb_last;

    // Context allocator. A context stays allocated until the corresponding
    // final digest is accepted at the top-level result interface.
    logic [CTX_NUM-1:0] free_bitmap;
    logic               stream_ctx_valid;
    logic [CTX_ID_W-1:0] stream_ctx_id;
    logic alloc_scan_available;
    logic [CTX_ID_W-1:0] alloc_scan_ctx_id;
    logic alloc_grant_valid;
    logic [CTX_ID_W-1:0] alloc_grant_ctx_id;
    logic first_multi;
    logic continuation_ok;
    logic block_route_ok;
    logic block_fire;
    logic [CTX_ID_W-1:0] block_ctx_id;
    logic head_needs_alloc;
    logic head_ctx_valid_q;
    logic [CTX_ID_W-1:0] head_ctx_id_q;

    // Two-entry block FIFO between the block builder and the engine.  The
    // builder/allocator path is long and would otherwise feed the engine's
    // ctx_head write enables combinationally.  The FIFO's input ready depends
    // only on its own occupancy, so the engine's context/message comparison is
    // also kept off the public s_ready path.
    logic [1:0]            in_buf_valid;
    logic                  in_buf_ready;
    logic [511:0]          in_buf_data [0:1];
    logic [MSG_ID_W-1:0]   in_buf_msg_id [0:1];
    logic                  in_buf_first [0:1];
    logic                  in_buf_last [0:1];
    logic [CTX_ID_W-1:0]   in_buf_ctx_id [0:1];
    logic                  in_buf_needs_alloc [0:1];
    logic                  in_buf_fire;

    // Engine block stream.
    logic eng_block_valid;
    logic eng_block_ready;
    logic [CTX_ID_W-1:0] eng_block_ctx_id;
    logic [511:0] eng_block_data;
    logic [MSG_ID_W-1:0] eng_block_msg_id;
    logic eng_block_first;
    logic eng_block_last;

    // Engine result metadata.
    logic [CTX_ID_W-1:0] eng_result_ctx_id;
    logic eng_result_fast;

    // Engine debug not exported individually.

    assign dbg_ctx_allocated = ~free_bitmap;

    // Scan the free bitmap into a one-entry allocation grant.  The scan ends
    // at a register (alloc_grant_ctx_id) instead of feeding bb_ready
    // combinationally.  Without this, free_bitmap -> block_route_ok ->
    // bb_ready -> block_builder s_ready is a long cross-module path back into
    // the builder's remaining_q counter.
    always_comb begin
        alloc_scan_available = 1'b0;
        alloc_scan_ctx_id    = '0;
        for (int c = 0; c < CTX_NUM; c = c + 1) begin
            if (!alloc_scan_available && free_bitmap[c]) begin
                alloc_scan_available = 1'b1;
                alloc_scan_ctx_id    = CTX_ID_W'(c);
            end
        end
    end

    assign first_multi = bb_first && !bb_last;

    // A first multi-block is written into the FIFO with a placeholder context
    // ID.  The real context is allocated when that entry reaches the FIFO head,
    // so bb_ready no longer has to wait for the free-bitmap grant.  Continuation
    // blocks still wait for stream_ctx_valid, which is set at head allocation.
    assign continuation_ok = bb_first || stream_ctx_valid;
    assign block_route_ok = continuation_ok;
    assign block_ctx_id = (bb_first && bb_last) ? '0
                        : (first_multi ? '0 : stream_ctx_id);

    assign in_buf_ready = !(in_buf_valid[0] && in_buf_valid[1]);
    assign bb_ready = in_buf_ready && block_route_ok;
    assign block_fire = bb_valid && bb_ready;

    assign head_needs_alloc = in_buf_valid[0] && in_buf_needs_alloc[0];
    assign eng_block_valid = in_buf_valid[0]
                          && (head_ctx_valid_q || !in_buf_needs_alloc[0]);
    assign eng_block_data  = in_buf_data[0];
    assign eng_block_msg_id = in_buf_msg_id[0];
    assign eng_block_first = in_buf_first[0];
    assign eng_block_last  = in_buf_last[0];
    assign eng_block_ctx_id = head_ctx_valid_q ? head_ctx_id_q : in_buf_ctx_id[0];
    assign in_buf_fire = eng_block_valid && eng_block_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_bitmap       <= '1;
            stream_ctx_valid  <= 1'b0;
            stream_ctx_id     <= '0;
            alloc_grant_valid <= 1'b0;
            alloc_grant_ctx_id <= '0;
            head_ctx_valid_q  <= 1'b0;
            head_ctx_id_q     <= '0;
        end else begin
            // Keep one free-context grant ready.  The scan itself is allowed
            // to take a cycle; a first multi-block waits on the registered
            // grant instead of on the free-bitmap priority encoder.
            if (!alloc_grant_valid) begin
                alloc_grant_valid  <= alloc_scan_available;
                alloc_grant_ctx_id <= alloc_scan_ctx_id;
            end

            // Reserve a context for the FIFO head one cycle before the engine
            // sees it.  The engine then consumes a registered context ID, so
            // neither the grant scan nor free_bitmap feeds the pool's context
            // write-enable logic combinationally.
            if (!head_ctx_valid_q && head_needs_alloc && alloc_grant_valid) begin
                head_ctx_valid_q <= 1'b1;
                head_ctx_id_q    <= alloc_grant_ctx_id;
                alloc_grant_valid <= 1'b0;
                free_bitmap[alloc_grant_ctx_id] <= 1'b0;
                stream_ctx_valid <= 1'b1;
                stream_ctx_id    <= alloc_grant_ctx_id;
            end

            if (in_buf_fire)
                head_ctx_valid_q <= 1'b0;

            // The mapping is no longer needed after the last block is accepted,
            // but the context remains allocated until its digest retires.
            if (block_fire && !bb_first && bb_last)
                stream_ctx_valid <= 1'b0;

            // Single-block messages bypass contexts; only multi-block results free one.
            if (result_valid && result_ready && !eng_result_fast)
                free_bitmap[eng_result_ctx_id] <= 1'b1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_buf_valid <= 2'b00;
            for (int i = 0; i < 2; i = i + 1) begin
                in_buf_data[i]   <= '0;
                in_buf_msg_id[i] <= '0;
                in_buf_first[i]  <= 1'b0;
                in_buf_last[i]   <= 1'b0;
                in_buf_ctx_id[i] <= '0;
                in_buf_needs_alloc[i] <= 1'b0;
            end
        end else begin
            if (in_buf_fire) begin
                in_buf_valid[0]  <= in_buf_valid[1];
                in_buf_data[0]   <= in_buf_data[1];
                in_buf_msg_id[0] <= in_buf_msg_id[1];
                in_buf_first[0]  <= in_buf_first[1];
                in_buf_last[0]   <= in_buf_last[1];
                in_buf_ctx_id[0] <= in_buf_ctx_id[1];
                in_buf_needs_alloc[0] <= in_buf_needs_alloc[1];
                in_buf_valid[1]  <= 1'b0;
            end

            if (block_fire) begin
                if (in_buf_fire) begin
                    if (in_buf_valid[1]) begin
                        in_buf_valid[1]  <= 1'b1;
                        in_buf_data[1]   <= bb_data;
                        in_buf_msg_id[1] <= bb_msg_id;
                        in_buf_first[1]  <= bb_first;
                        in_buf_last[1]   <= bb_last;
                        in_buf_ctx_id[1] <= block_ctx_id;
                        in_buf_needs_alloc[1] <= first_multi;
                    end else begin
                        in_buf_valid[0]  <= 1'b1;
                        in_buf_data[0]   <= bb_data;
                        in_buf_msg_id[0] <= bb_msg_id;
                        in_buf_first[0]  <= bb_first;
                        in_buf_last[0]   <= bb_last;
                        in_buf_ctx_id[0] <= block_ctx_id;
                        in_buf_needs_alloc[0] <= first_multi;
                    end
                end else if (in_buf_valid[0]) begin
                    in_buf_valid[1]  <= 1'b1;
                    in_buf_data[1]   <= bb_data;
                    in_buf_msg_id[1] <= bb_msg_id;
                    in_buf_first[1]  <= bb_first;
                    in_buf_last[1]   <= bb_last;
                    in_buf_ctx_id[1] <= block_ctx_id;
                    in_buf_needs_alloc[1] <= first_multi;
                end else begin
                    in_buf_valid[0]  <= 1'b1;
                    in_buf_data[0]   <= bb_data;
                    in_buf_msg_id[0] <= bb_msg_id;
                    in_buf_first[0]  <= bb_first;
                    in_buf_last[0]   <= bb_last;
                    in_buf_ctx_id[0] <= block_ctx_id;
                    in_buf_needs_alloc[0] <= first_multi;
                end
            end
        end
    end

    // Hold the public message interface until the block-pool free list has
    // completed its one-time post-reset initialization.
    assign desc_ready = bb_desc_ready && dbg_pool_init_done;

    sm3_block_builder #(
        .MSG_ID_W(MSG_ID_W)
    ) u_block_builder (
        .clk           (clk),
        .rst_n         (rst_n),
        .desc_valid    (desc_valid && dbg_pool_init_done),
        .desc_ready    (bb_desc_ready),
        .desc_msg_id   (desc_msg_id),
        .desc_len_bytes(desc_len_bytes),
        .s_valid       (s_valid),
        .s_ready       (s_ready),
        .s_data        (s_data),
        .s_keep        (s_keep),
        .block_valid   (bb_valid),
        .block_ready   (bb_ready),
        .block_data    (bb_data),
        .block_msg_id  (bb_msg_id),
        .block_first   (bb_first),
        .block_last    (bb_last)
    );

    sm3_pool_engine #(
        .CORE_NUM  (CORE_NUM),
        .CTX_NUM   (CTX_NUM),
        .MSG_ID_W  (MSG_ID_W),
        .FAST_DEPTH(FAST_DEPTH),
        .POOL_DEPTH(POOL_DEPTH)
    ) u_engine (
        .clk                  (clk),
        .rst_n                (rst_n),
        .block_valid          (eng_block_valid),
        .block_ready          (eng_block_ready),
        .block_data           (eng_block_data),
        .block_ctx_id_in      (eng_block_ctx_id),
        .msg_id_in            (eng_block_msg_id),
        .block_first_in       (eng_block_first),
        .block_last_in        (eng_block_last),
        .result_valid         (result_valid),
        .result_ready         (result_ready),
        .digest_out           (digest_out),
        .msg_id_out           (result_msg_id),
        .ctx_id_out           (eng_result_ctx_id),
        .result_fast          (eng_result_fast),
        .core_occupied        (dbg_core_occupied),
        .ctx_valid_bitmap     (),
        .ctx_pending_bitmap   (),
        .ctx_inflight_bitmap  (),
        .fast_level           (dbg_fast_level),
        .pool_free_count      (dbg_pool_free),
        .pool_init_done       (dbg_pool_init_done),
        .dbg_dispatch_valid   (),
        .dbg_dispatch_fast    (),
        .dbg_dispatch_ctx_id  (),
        .dbg_commit_valid     (),
        .dbg_commit_fast      (),
        .dbg_commit_ctx_id    (),
        .dbg_commit_last      (),
        .dbg_sticky_valid     ()
    );

endmodule
