// -----------------------------------------------------------------------------
// Cluster-scaled SM3 accelerator top.
//
// The public descriptor/payload/result interface is identical to the frozen
// single-engine sm3_accel_top.  Messages are routed to one of CLUSTER_NUM
// independent clusters; all blocks of a message stay in that cluster.  The
// top-level path carries only the narrow descriptor/status/result metadata and
// a shared 128-bit payload bus.  A two-entry result FIFO decouples the
// cluster-local result backpressure from the public result stream.
// -----------------------------------------------------------------------------
module sm3_accel_cluster_top #(
    parameter int CORE_NUM   = 16,
    parameter int CTX_NUM    = 32,
    parameter int MSG_ID_W   = 32,
    parameter int FAST_DEPTH = 32,
    parameter int POOL_DEPTH = 512,
    parameter int CLUSTER_NUM = 4,

    localparam int CORE_PER_CLUSTER = CORE_NUM / CLUSTER_NUM,
    localparam int CTX_PER_CLUSTER  = CTX_NUM / CLUSTER_NUM,
    localparam int FAST_PER_CLUSTER  = FAST_DEPTH / CLUSTER_NUM,
    localparam int POOL_PER_CLUSTER  = POOL_DEPTH / CLUSTER_NUM,

    localparam int CLUSTER_ID_W = (CLUSTER_NUM <= 1) ? 1 : $clog2(CLUSTER_NUM),
    localparam int FAST_CNT_W   = $clog2(FAST_DEPTH + 1),
    localparam int POOL_CNT_W   = $clog2(POOL_DEPTH + 1),
    localparam int FAST_LOCAL_CNT_W = $clog2(FAST_PER_CLUSTER + 1),
    localparam int POOL_LOCAL_CNT_W = $clog2(POOL_PER_CLUSTER + 1),
    localparam int CTX_CNT_W    = $clog2(CTX_PER_CLUSTER + 1)
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    desc_valid,
    output logic                    desc_ready,
    input  logic [MSG_ID_W-1:0]     desc_msg_id,
    input  logic [31:0]             desc_len_bytes,

    input  logic                    s_valid,
    output logic                    s_ready,
    input  logic [127:0]            s_data,
    input  logic [15:0]             s_keep,

    output logic                    result_valid,
    input  logic                    result_ready,
    output logic [255:0]            digest_out,
    output logic [MSG_ID_W-1:0]     result_msg_id,

    output logic [CORE_NUM-1:0]     dbg_core_occupied,
    output logic [CTX_NUM-1:0]      dbg_ctx_allocated,
    output logic [FAST_CNT_W-1:0]   dbg_fast_level,
    output logic [POOL_CNT_W-1:0]   dbg_pool_free,
    output logic                    dbg_pool_init_done
);

    // Per-cluster status and streams.
    logic [CLUSTER_NUM-1:0] cl_desc_ready;
    logic [CLUSTER_NUM-1:0] cl_desc_valid;
    logic [CLUSTER_NUM-1:0] cl_s_ready;
    logic [CLUSTER_NUM-1:0] cl_s_valid;
    logic [CLUSTER_NUM-1:0] cl_result_valid;
    logic [CLUSTER_NUM-1:0] cl_result_ready;
    logic [CLUSTER_NUM-1:0] cl_pool_init_done;

    logic [MSG_ID_W-1:0] cl_result_msg_id [0:CLUSTER_NUM-1];
    logic [255:0]        cl_result_digest [0:CLUSTER_NUM-1];

    logic [CORE_PER_CLUSTER-1:0]    cl_core_occupied [0:CLUSTER_NUM-1];
    logic [CTX_PER_CLUSTER-1:0]     cl_ctx_allocated [0:CLUSTER_NUM-1];
    logic [FAST_LOCAL_CNT_W-1:0]    cl_fast_level [0:CLUSTER_NUM-1];
    logic [POOL_LOCAL_CNT_W-1:0]    cl_pool_free [0:CLUSTER_NUM-1];

    // Message router state.  Only one message descriptor/payload may be active
    // at the top, matching the existing single-stream front end.
    logic                    active;
    logic [CLUSTER_ID_W-1:0] active_cluster;
    logic                    all_init;
    logic                    need_ctx;
    logic                    sel_found;
    logic [CLUSTER_ID_W-1:0] sel;
    logic [7:0]              sel_score;
    logic [7:0]              cl_load [0:CLUSTER_NUM-1];
    logic [CTX_CNT_W-1:0]    cl_ctx_count [0:CLUSTER_NUM-1];

    // Two-entry result FIFO.  A cluster result is retired when it is written
    // into this FIFO, so the local context can be reused before the public
    // result stream drains.
    logic [1:0]              res_count;
    logic [0:0]              res_wr_ptr;
    logic [0:0]              res_rd_ptr;
    logic [255:0]            res_digest [0:1];
    logic [MSG_ID_W-1:0]     res_msg_id [0:1];
    logic                    res_push;
    logic                    res_pop;
    logic                    result_fifo_space;
    logic                    merge_found;
    logic [CLUSTER_ID_W-1:0] merge_pick;
    logic [CLUSTER_ID_W-1:0] merge_rr;

    logic [FAST_CNT_W:0]     fast_sum;
    logic [POOL_CNT_W:0]     pool_sum;

    assign all_init = &cl_pool_init_done;
    assign dbg_pool_init_done = all_init;

    // A message of 0..55 bytes fits in one padded block.  Longer messages need
    // at least one local multi-block context, so only clusters with a free
    // context are eligible.
    assign need_ctx = (desc_len_bytes > 32'd55);

    always_comb begin
        for (int i = 0; i < CLUSTER_NUM; i = i + 1) begin
            cl_ctx_count[i] = CTX_CNT_W'($countones(cl_ctx_allocated[i]));
            cl_load[i] = 8'($countones(cl_core_occupied[i]))
                       + 8'(cl_ctx_count[i])
                       + 8'(cl_fast_level[i]);
        end
    end

    // Pick the least-loaded ready cluster.  Ties are resolved toward cluster 0;
    // the load score includes running cores, allocated contexts and queued
    // single-block work, so short messages still distribute across clusters.
    always_comb begin
        sel_found = 1'b0;
        sel       = '0;
        sel_score = '0;
        for (int i = 0; i < CLUSTER_NUM; i = i + 1) begin
            if (cl_desc_ready[i] && (!need_ctx || (cl_ctx_count[i] < CTX_PER_CLUSTER))) begin
                if (!sel_found || (cl_load[i] < sel_score)) begin
                    sel_found = 1'b1;
                    sel       = CLUSTER_ID_W'(i);
                    sel_score = cl_load[i];
                end
            end
        end
    end

    assign desc_ready = !active && all_init && sel_found;

    always_comb begin
        for (int i = 0; i < CLUSTER_NUM; i = i + 1) begin
            cl_desc_valid[i] = desc_valid && !active && all_init && sel_found
                             && (sel == CLUSTER_ID_W'(i));
            cl_s_valid[i]    = s_valid && active
                             && (active_cluster == CLUSTER_ID_W'(i));
        end
    end

    assign s_ready = active ? cl_s_ready[active_cluster] : 1'b0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active         <= 1'b0;
            active_cluster <= '0;
        end else if (!active) begin
            if (desc_valid && desc_ready) begin
                active         <= 1'b1;
                active_cluster <= sel;
            end
        end else begin
            // The cluster block builder only raises desc_ready after its final
            // block has been accepted by the local engine.
            if (cl_desc_ready[active_cluster])
                active <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // Result merge: select one valid cluster into the two-entry FIFO.
    // ------------------------------------------------------------------
    always_comb begin
        merge_found = 1'b0;
        merge_pick  = '0;
        for (int k = 0; k < CLUSTER_NUM; k = k + 1) begin
            int idx;
            idx = (merge_rr + k) % CLUSTER_NUM;
            if (!merge_found && cl_result_valid[idx]) begin
                merge_found = 1'b1;
                merge_pick  = CLUSTER_ID_W'(idx);
            end
        end
    end

    assign result_fifo_space = (res_count < 2);
    assign res_push = merge_found && result_fifo_space;
    assign res_pop  = (res_count != 0) && result_ready;

    assign result_valid  = (res_count != 0);
    assign digest_out    = res_digest[res_rd_ptr];
    assign result_msg_id = res_msg_id[res_rd_ptr];

    always_comb begin
        for (int i = 0; i < CLUSTER_NUM; i = i + 1) begin
            cl_result_ready[i] = merge_found && result_fifo_space
                               && (merge_pick == CLUSTER_ID_W'(i));
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_count  <= 2'd0;
            res_wr_ptr <= 1'b0;
            res_rd_ptr <= 1'b0;
            merge_rr   <= '0;
        end else begin
            if (res_push) begin
                res_digest[res_wr_ptr] <= cl_result_digest[merge_pick];
                res_msg_id[res_wr_ptr] <= cl_result_msg_id[merge_pick];
                res_wr_ptr <= ~res_wr_ptr;
                merge_rr   <= (merge_pick == CLUSTER_ID_W'(CLUSTER_NUM - 1))
                            ? '0 : (merge_pick + 1'b1);
            end
            if (res_pop)
                res_rd_ptr <= ~res_rd_ptr;

            case ({res_push, res_pop})
                2'b10:   res_count <= res_count + 2'd1;
                2'b01:   res_count <= res_count - 2'd1;
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Status aggregation.
    // ------------------------------------------------------------------
    always_comb begin
        fast_sum = '0;
        pool_sum = '0;
        for (int i = 0; i < CLUSTER_NUM; i = i + 1) begin
            dbg_core_occupied[i*CORE_PER_CLUSTER +: CORE_PER_CLUSTER] = cl_core_occupied[i];
            dbg_ctx_allocated[i*CTX_PER_CLUSTER +: CTX_PER_CLUSTER] = cl_ctx_allocated[i];
            fast_sum = fast_sum + FAST_CNT_W'(cl_fast_level[i]);
            pool_sum = pool_sum + POOL_CNT_W'(cl_pool_free[i]);
        end
        dbg_fast_level = fast_sum[FAST_CNT_W-1:0];
        dbg_pool_free  = pool_sum[POOL_CNT_W-1:0];
    end

    // ------------------------------------------------------------------
    // Cluster instances.
    // ------------------------------------------------------------------
    genvar gi;
    generate
        for (gi = 0; gi < CLUSTER_NUM; gi = gi + 1) begin : u_clusters
            sm3_accel_cluster #(
                .CORE_NUM  (CORE_PER_CLUSTER),
                .CTX_NUM   (CTX_PER_CLUSTER),
                .MSG_ID_W  (MSG_ID_W),
                .FAST_DEPTH(FAST_PER_CLUSTER),
                .POOL_DEPTH(POOL_PER_CLUSTER)
            ) u_cluster (
                .clk              (clk),
                .rst_n            (rst_n),
                .desc_valid       (cl_desc_valid[gi]),
                .desc_ready       (cl_desc_ready[gi]),
                .desc_msg_id      (desc_msg_id),
                .desc_len_bytes   (desc_len_bytes),
                .s_valid          (cl_s_valid[gi]),
                .s_ready          (cl_s_ready[gi]),
                .s_data           (s_data),
                .s_keep           (s_keep),
                .result_valid     (cl_result_valid[gi]),
                .result_ready     (cl_result_ready[gi]),
                .digest_out       (cl_result_digest[gi]),
                .result_msg_id    (cl_result_msg_id[gi]),
                .core_occupied    (cl_core_occupied[gi]),
                .ctx_allocated    (cl_ctx_allocated[gi]),
                .fast_level       (cl_fast_level[gi]),
                .pool_free_count  (cl_pool_free[gi]),
                .pool_init_done   (cl_pool_init_done[gi])
            );
        end
    endgenerate

endmodule
