module sm3_context_store #(
    parameter int CTX_NUM  = 32,
    parameter int CTX_ID_W = (CTX_NUM <= 1) ? 1 : $clog2(CTX_NUM)
) (
    input  logic                    clk,

    // One pending 512-bit block per context. 1W + 1R.
    input  logic                    block_wr_en,
    input  logic [CTX_ID_W-1:0]     block_wr_addr,
    input  logic [511:0]            block_wr_data,
    input  logic                    block_wr_first,
    input  logic                    block_wr_last,

    // Hash chaining state. Commit path is the only writer.
    input  logic                    hash_wr_en,
    input  logic [CTX_ID_W-1:0]     hash_wr_addr,
    input  logic [255:0]            hash_wr_data,

    // Synchronous dispatch read port.
    input  logic                    rd_en,
    input  logic [CTX_ID_W-1:0]     rd_addr,
    output logic [511:0]            rd_block_data,
    output logic                    rd_block_first,
    output logic                    rd_block_last,
    output logic [255:0]            rd_hash_state
);

    // Keep payload/state memories separate so synthesis can map them to
    // independent BRAM primitives. Metadata bitmaps remain in the scheduler.
    (* ram_style = "block" *) logic [513:0] block_mem [0:CTX_NUM-1];
    (* ram_style = "block" *) logic [255:0] hash_mem  [0:CTX_NUM-1];

    always_ff @(posedge clk) begin
        if (block_wr_en)
            block_mem[block_wr_addr] <= {block_wr_first, block_wr_last, block_wr_data};

        if (hash_wr_en)
            hash_mem[hash_wr_addr] <= hash_wr_data;

        if (rd_en) begin
            {rd_block_first, rd_block_last, rd_block_data} <= block_mem[rd_addr];
            rd_hash_state <= hash_mem[rd_addr];
        end
    end

endmodule
