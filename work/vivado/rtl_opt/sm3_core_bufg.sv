// -----------------------------------------------------------------------------
// OOC timing wrapper: inserts a real BUFG so place/route see a buffered clock.
// No functional change to sm3_core.
// -----------------------------------------------------------------------------
module sm3_core_bufg #(
    parameter int MSG_ID_W = 32
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  in_valid,
    output logic                  in_ready,
    input  logic [511:0]          block_data,
    input  logic [255:0]          hash_in,
    input  logic [MSG_ID_W-1:0]   msg_id_in,
    input  logic                  block_last_in,

    output logic                  out_valid,
    input  logic                  out_ready,
    output logic [255:0]          hash_out,
    output logic [MSG_ID_W-1:0]   msg_id_out,
    output logic                  block_last_out
);

    logic clk_buf;

    BUFG u_bufg (
        .I (clk),
        .O (clk_buf)
    );

    sm3_core #(
        .MSG_ID_W (MSG_ID_W)
    ) u_core (
        .clk           (clk_buf),
        .rst_n         (rst_n),
        .in_valid      (in_valid),
        .in_ready      (in_ready),
        .block_data    (block_data),
        .hash_in       (hash_in),
        .msg_id_in     (msg_id_in),
        .block_last_in (block_last_in),
        .out_valid     (out_valid),
        .out_ready     (out_ready),
        .hash_out      (hash_out),
        .msg_id_out    (msg_id_out),
        .block_last_out(block_last_out)
    );

endmodule
