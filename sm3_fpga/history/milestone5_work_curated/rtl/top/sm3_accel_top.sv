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
    logic alloc_available;
    logic [CTX_ID_W-1:0] alloc_ctx_id;
    logic first_multi;
    logic continuation_ok;
    logic block_route_ok;
    logic block_fire;

    // Engine block stream.
    logic eng_block_valid;
    logic eng_block_ready;
    logic [CTX_ID_W-1:0] eng_block_ctx_id;

    // Engine result metadata.
    logic [CTX_ID_W-1:0] eng_result_ctx_id;
    logic eng_result_fast;

    // Engine debug not exported individually.

    assign dbg_ctx_allocated = ~free_bitmap;

    always_comb begin
        alloc_available = 1'b0;
        alloc_ctx_id    = '0;
        for (int c = 0; c < CTX_NUM; c = c + 1) begin
            if (!alloc_available && free_bitmap[c]) begin
                alloc_available = 1'b1;
                alloc_ctx_id    = CTX_ID_W'(c);
            end
        end
    end

    assign first_multi = bb_first && !bb_last;
    assign continuation_ok = bb_first || stream_ctx_valid;
    assign block_route_ok = continuation_ok && (!first_multi || alloc_available);

    assign eng_block_valid = bb_valid && block_route_ok;
    assign eng_block_ctx_id = (bb_first && bb_last) ? '0
                            : (first_multi ? alloc_ctx_id : stream_ctx_id);
    assign bb_ready = eng_block_ready && block_route_ok;
    assign block_fire = bb_valid && bb_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            free_bitmap     <= '1;
            stream_ctx_valid <= 1'b0;
            stream_ctx_id    <= '0;
        end else begin
            // A multi-block first block claims a context for all later blocks.
            if (block_fire && first_multi) begin
                free_bitmap[alloc_ctx_id] <= 1'b0;
                stream_ctx_valid <= 1'b1;
                stream_ctx_id    <= alloc_ctx_id;
            end

            // The mapping is no longer needed after the last block is accepted,
            // but the context remains allocated until its digest retires.
            if (block_fire && !bb_first && bb_last)
                stream_ctx_valid <= 1'b0;

            // Single-block messages bypass contexts; only multi-block results free one.
            if (result_valid && result_ready && !eng_result_fast)
                free_bitmap[eng_result_ctx_id] <= 1'b1;
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
        .block_data           (bb_data),
        .block_ctx_id_in      (eng_block_ctx_id),
        .msg_id_in            (bb_msg_id),
        .block_first_in       (bb_first),
        .block_last_in        (bb_last),
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
