(* blackbox *)
module sm3_core #(
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
endmodule
