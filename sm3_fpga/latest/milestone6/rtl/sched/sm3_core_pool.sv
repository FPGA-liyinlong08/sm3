module sm3_core_pool #(
    parameter int CORE_NUM = 8,
    parameter int MSG_ID_W = 32
) (
    input  logic                    clk,
    input  logic                    rst_n,

    // Pre-padded single-block request. One request == one SM3 message.
    input  logic                    block_valid,
    output logic                    block_ready,
    input  logic [511:0]            block_data,
    input  logic [MSG_ID_W-1:0]     msg_id_in,

    output logic                    result_valid,
    input  logic                    result_ready,
    output logic [255:0]            digest_out,
    output logic [MSG_ID_W-1:0]     msg_id_out,

    // Occupied includes a core computing or holding an unconsumed result.
    output logic [CORE_NUM-1:0]     core_occupied
);

    localparam logic [255:0] SM3_IV =
        256'h7380166f4914b2b9172442d7da8a0600a96f30bc163138aae38dee4db0fb0e4e;

    logic [CORE_NUM-1:0] core_in_valid;
    logic [CORE_NUM-1:0] core_in_ready;
    logic [CORE_NUM-1:0] core_out_valid;
    logic [CORE_NUM-1:0] core_out_ready;

    logic [255:0]          core_hash_out [0:CORE_NUM-1];
    logic [MSG_ID_W-1:0]   core_msg_out  [0:CORE_NUM-1];
    integer dispatch_sel;
    integer result_sel;

    always_comb begin
        dispatch_sel = -1;
        block_ready = 1'b0;
        core_in_valid = '0;

        for (int k = 0; k < CORE_NUM; k = k + 1) begin
            if ((dispatch_sel < 0) && core_in_ready[k])
                dispatch_sel = k;
        end

        if (dispatch_sel >= 0) begin
            block_ready = 1'b1;
            if (block_valid)
                core_in_valid[dispatch_sel] = 1'b1;
        end
    end

    always_comb begin
        result_sel = -1;
        result_valid = 1'b0;
        digest_out = '0;
        msg_id_out = '0;
        core_out_ready = '0;

        for (int k = 0; k < CORE_NUM; k = k + 1) begin
            if ((result_sel < 0) && core_out_valid[k])
                result_sel = k;
        end

        if (result_sel >= 0) begin
            result_valid = 1'b1;
            digest_out = core_hash_out[result_sel];
            msg_id_out = core_msg_out[result_sel];
            core_out_ready[result_sel] = result_ready;
        end
    end

    always_comb begin
        for (int k = 0; k < CORE_NUM; k = k + 1)
            core_occupied[k] = ~core_in_ready[k];
    end

    genvar g;
    generate
        for (g = 0; g < CORE_NUM; g = g + 1) begin : g_core
            sm3_core #(
                .MSG_ID_W(MSG_ID_W)
            ) u_core (
                .clk            (clk),
                .rst_n          (rst_n),
                .in_valid       (core_in_valid[g]),
                .in_ready       (core_in_ready[g]),
                .block_data     (block_data),
                .hash_in        (SM3_IV),
                .msg_id_in      (msg_id_in),
                .block_last_in  (1'b1),
                .out_valid      (core_out_valid[g]),
                .out_ready      (core_out_ready[g]),
                .hash_out       (core_hash_out[g]),
                .msg_id_out     (core_msg_out[g]),
                .block_last_out ()
            );
        end
    endgenerate

endmodule
