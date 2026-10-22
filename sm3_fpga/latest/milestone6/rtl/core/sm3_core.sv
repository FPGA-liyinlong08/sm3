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

    (* max_fanout = 32 *) logic busy;
    logic [5:0] round_idx;

    logic [31:0] a, b, c, d, e, f, g, h;
    logic [255:0] hash_base;
    logic [31:0] w [0:15];
    logic [MSG_ID_W-1:0] msg_id_q;
    logic last_q;

    logic [31:0] wj, wj4, wnext, wpj;
    logic [31:0] tj_rot_q;
    logic [31:0] a12, ss1, ss2, tt1, tt2;
    logic [31:0] an, bn, cn, dn, en, fn, gn, hn;
    logic [255:0] round_state_next;

    function automatic logic [31:0] rol32(input logic [31:0] x, input integer sh);
        integer n;
        begin
            n = sh & 31;
            if (n == 0)
                rol32 = x;
            else
                rol32 = (x << n) | (x >> (32-n));
        end
    endfunction

    function automatic logic [31:0] p0(input logic [31:0] x);
        p0 = x ^ rol32(x, 9) ^ rol32(x, 17);
    endfunction

    function automatic logic [31:0] p1(input logic [31:0] x);
        p1 = x ^ rol32(x, 15) ^ rol32(x, 23);
    endfunction

    function automatic logic [31:0] ff(
        input logic [31:0] x,
        input logic [31:0] y,
        input logic [31:0] z,
        input logic [5:0]  j
    );
        if (j < 16)
            ff = x ^ y ^ z;
        else
            ff = (x & y) | (x & z) | (y & z);
    endfunction

    function automatic logic [31:0] gg(
        input logic [31:0] x,
        input logic [31:0] y,
        input logic [31:0] z,
        input logic [5:0]  j
    );
        if (j < 16)
            gg = x ^ y ^ z;
        else
            gg = (x & y) | ((~x) & z);
    endfunction

    // Allow a new block to be accepted in the same cycle that the previous
    // result is consumed. This removes the otherwise mandatory one-cycle
    // output-to-input turnaround bubble without changing the 64-round datapath.
    // Do not accept a new block in the same cycle that the previous result is
    // handed off.  Keeping out_valid out of the in_ready equation breaks the
    // combinational loop core_out_valid -> commit_accept -> core_out_ready ->
    // core_in_ready -> scheduler -> ctx_head.  Cost is one bubble per block
    // (~1.5% at the 65-cycle service interval).
    assign in_ready = ~busy & ~out_valid;

    // Replicate the load enable so the 1000+ flip-flop enable pins are not
    // driven by a single long high-fanout net.
    (* max_fanout = 32 *) logic load_en;
    assign load_en = in_valid && in_ready;

    always_comb begin
        wj    = w[0];
        wj4   = w[4];
        wpj   = wj ^ wj4;
        wnext = p1(w[0] ^ w[7] ^ rol32(w[13], 15)) ^ rol32(w[3], 7) ^ w[10];

        // Tj <<< j is pre-computed one cycle ahead into tj_rot_q so the
        // variable rotate is not in the round combinational path.
        a12    = rol32(a, 12);
        ss1    = rol32(a12 + e + tj_rot_q, 7);
        ss2    = ss1 ^ a12;
        tt1    = (ff(a, b, c, round_idx) + d) + (ss2 + wpj);
        tt2    = (gg(e, f, g, round_idx) + h) + (ss1 + wj);

        an = tt1;
        bn = a;
        cn = rol32(b, 9);
        dn = c;
        en = p0(tt2);
        fn = e;
        gn = rol32(f, 19);
        hn = g;

        round_state_next = {an, bn, cn, dn, en, fn, gn, hn};
    end

    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy           <= 1'b0;
            round_idx       <= '0;
            tj_rot_q        <= 32'h79cc4519;
            a               <= '0;
            b               <= '0;
            c               <= '0;
            d               <= '0;
            e               <= '0;
            f               <= '0;
            g               <= '0;
            h               <= '0;
            hash_base       <= '0;
            msg_id_q        <= '0;
            last_q          <= 1'b0;
            out_valid       <= 1'b0;
            hash_out        <= '0;
            msg_id_out      <= '0;
            block_last_out  <= 1'b0;
            for (i = 0; i < 16; i = i + 1)
                w[i] <= '0;
        end else begin
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            if (load_en) begin
                busy      <= 1'b1;
                round_idx <= 6'd0;
                tj_rot_q  <= 32'h79cc4519;

                a <= hash_in[255:224];
                b <= hash_in[223:192];
                c <= hash_in[191:160];
                d <= hash_in[159:128];
                e <= hash_in[127:96];
                f <= hash_in[95:64];
                g <= hash_in[63:32];
                h <= hash_in[31:0];

                hash_base <= hash_in;
                msg_id_q  <= msg_id_in;
                last_q    <= block_last_in;

                for (i = 0; i < 16; i = i + 1)
                    w[i] <= block_data[511 - i*32 -: 32];
            end else if (busy) begin
                a <= an;
                b <= bn;
                c <= cn;
                d <= dn;
                e <= en;
                f <= fn;
                g <= gn;
                h <= hn;

                for (i = 0; i < 15; i = i + 1)
                    w[i] <= w[i+1];
                w[15] <= wnext;

                tj_rot_q <= rol32(((round_idx + 6'd1) < 16) ? 32'h79cc4519
                                                           : 32'h7a879d8a,
                                  int'(round_idx + 6'd1));

                if (round_idx == 6'd63) begin
                    busy          <= 1'b0;
                    round_idx     <= '0;
                    out_valid     <= 1'b1;
                    hash_out      <= round_state_next ^ hash_base;
                    msg_id_out    <= msg_id_q;
                    block_last_out <= last_q;
                end else begin
                    round_idx <= round_idx + 6'd1;
                end
            end
        end
    end

endmodule
