module sm3_block_pool #(
    parameter int POOL_DEPTH = 256,
    parameter int SLOT_W = (POOL_DEPTH <= 1) ? 1 : $clog2(POOL_DEPTH),
    parameter int COUNT_W = $clog2(POOL_DEPTH + 1)
) (
    input  logic                 clk,
    input  logic                 rst_n,

    output logic                 init_done,
    output logic [COUNT_W-1:0]   free_count,

    // One allocation/write per cycle.
    input  logic                 alloc_valid,
    output logic                 alloc_ready,
    output logic [SLOT_W-1:0]    alloc_slot,
    input  logic [511:0]         alloc_block,
    input  logic                 alloc_first,
    input  logic                 alloc_last,

    // One slot can be returned per cycle by the scheduler when it pops a queue.
    input  logic                 free_valid,
    input  logic [SLOT_W-1:0]    free_slot,

    // Per-slot linked-list metadata. The block payload itself stays in BRAM.
    input  logic                 link_wr_en,
    input  logic [SLOT_W-1:0]    link_wr_slot,
    input  logic [SLOT_W-1:0]    link_wr_next,
    input  logic                 link_rd_en,
    input  logic [SLOT_W-1:0]    link_rd_slot,
    output logic [SLOT_W-1:0]    link_rd_next,

    // Synchronous payload read used by dispatch.
    input  logic                 rd_en,
    input  logic [SLOT_W-1:0]    rd_slot,
    output logic [511:0]         rd_block,
    output logic                 rd_first,
    output logic                 rd_last
);

    localparam int PTR_W = SLOT_W;

    (* ram_style = "block" *) logic [513:0] block_mem [0:POOL_DEPTH-1];
    logic [SLOT_W-1:0] next_mem [0:POOL_DEPTH-1];
    logic [SLOT_W-1:0] free_fifo [0:POOL_DEPTH-1];

    // Two-stage synchronous link lookup:
    // cycle N captures the slot; N+1 reads next_mem into link_rd_next.
    // The engine retires the head update in cycle N+2.
    logic [SLOT_W-1:0] link_rd_slot_q;
    logic link_rd_valid_q;

    logic [PTR_W-1:0] free_rd_ptr, free_wr_ptr;
    logic [SLOT_W-1:0] init_idx;
    logic alloc_fire;

    assign alloc_ready = init_done && (free_count != 0);
    assign alloc_slot  = free_fifo[free_rd_ptr];
    assign alloc_fire  = alloc_valid && alloc_ready;
    // No asynchronous next_mem read on the core-commit -> ctx_head path.

    function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] ptr);
        begin
            if (ptr == PTR_W'(POOL_DEPTH-1))
                ptr_inc = '0;
            else
                ptr_inc = ptr + 1'b1;
        end
    endfunction

    // Keep the wide payload RAM in its own reset-free synchronous process.
    // This matches FPGA block-RAM inference templates much better than mixing
    // the RAM accesses into the pool/free-list process with an async reset.
    // The read outputs are only consumed after rd_en has launched a valid slot,
    // so they do not require reset initialization.
    always_ff @(posedge clk) begin
        if (alloc_fire)
            block_mem[alloc_slot] <= {alloc_first, alloc_last, alloc_block};

        if (rd_en)
            {rd_first, rd_last, rd_block} <= block_mem[rd_slot];
    end

    // Free-list storage is a single-write, asynchronous-read RAM. During pool
    // initialization it is filled sequentially; after init the same write port
    // is used only when a slot is returned.
    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (!init_done)
                free_fifo[init_idx] <= init_idx;
            else if (free_valid)
                free_fifo[free_wr_ptr] <= free_slot;
        end
    end

    // A link is only meaningful once a successor exists. A freshly allocated
    // single-element queue never consumes next_mem, so there is no need for the
    // old "self link" write on allocation. Keeping one write port lets this
    // metadata infer as RAM instead of a register/mux matrix.
    always_ff @(posedge clk) begin
        if (rst_n && link_wr_en)
            next_mem[link_wr_slot] <= link_wr_next;

        if (link_rd_en)
            link_rd_slot_q <= link_rd_slot;
        if (link_rd_valid_q)
            link_rd_next <= next_mem[link_rd_slot_q];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            link_rd_valid_q <= 1'b0;
        else
            link_rd_valid_q <= link_rd_en;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            init_done   <= 1'b0;
            init_idx    <= '0;
            free_rd_ptr <= '0;
            free_wr_ptr <= '0;
            free_count  <= '0;
        end else if (!init_done) begin
            // Build the free list one entry per cycle. Keeping reset out of the
            // payload memory allows block_mem to infer as BRAM in Vivado.
            if (init_idx == SLOT_W'(POOL_DEPTH-1)) begin
                init_done   <= 1'b1;
                init_idx    <= '0;
                free_rd_ptr <= '0;
                free_wr_ptr <= '0;
                free_count  <= COUNT_W'(POOL_DEPTH);
            end else begin
                init_idx <= init_idx + 1'b1;
            end
        end else begin
            if (alloc_fire) begin
                free_rd_ptr <= ptr_inc(free_rd_ptr);
            end

            if (free_valid) begin
                free_wr_ptr <= ptr_inc(free_wr_ptr);
            end

            case ({alloc_fire, free_valid})
                2'b10: free_count <= free_count - 1'b1;
                2'b01: free_count <= free_count + 1'b1;
                default: free_count <= free_count;
            endcase

        end
    end

endmodule
