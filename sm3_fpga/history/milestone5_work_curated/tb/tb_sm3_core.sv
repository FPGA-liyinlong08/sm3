`timescale 1ns/1ps
module tb_sm3_core;
    logic clk = 0;
    logic rst_n = 0;
    always #2 clk = ~clk;

    logic         in_valid;
    logic         in_ready;
    logic [511:0] block_data;
    logic [255:0] hash_in;
    logic [31:0]  msg_id_in;
    logic         block_last_in;

    logic         out_valid;
    logic         out_ready;
    logic [255:0] hash_out;
    logic [31:0]  msg_id_out;
    logic         block_last_out;

    sm3_core dut (
        .clk, .rst_n,
        .in_valid, .in_ready, .block_data, .hash_in,
        .msg_id_in, .block_last_in,
        .out_valid, .out_ready, .hash_out,
        .msg_id_out, .block_last_out
    );

    integer fd;
    integer rc;
    integer count;
    integer msg_id_i;
    integer last_i;
    integer wait_cycles;
    logic [511:0] vec_block;
    logic [255:0] vec_state;
    logic [255:0] vec_expected;
    logic [255:0] stable_hash;
    logic [31:0]  stable_id;
    logic stable_last;

    initial begin
        in_valid = 0;
        out_ready = 1;
        block_data = '0;
        hash_in = '0;
        msg_id_in = '0;
        block_last_in = 0;
        count = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        fd = $fopen("sim/sm3_core_vectors.txt", "r");
        if (fd == 0) $fatal(1, "cannot open vector file");

        while (!$feof(fd)) begin
            rc = $fscanf(fd, "%h %h %h %d %d\n",
                         vec_block, vec_state, vec_expected, msg_id_i, last_i);
            if (rc != 5) begin
                if (!$feof(fd)) $fatal(1, "bad vector line after %0d cases, rc=%0d", count, rc);
            end else begin
                while (!in_ready) @(negedge clk);
                block_data = vec_block;
                hash_in = vec_state;
                msg_id_in = msg_id_i[31:0];
                block_last_in = last_i[0];
                in_valid = 1;
                if (count == 0) out_ready = 0;

                @(posedge clk);
                @(negedge clk);
                in_valid = 0;

                wait_cycles = 0;
                while (!out_valid) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                    if (wait_cycles > 70) $fatal(1, "timeout on vector %0d", count);
                end

                if (hash_out !== vec_expected)
                    $fatal(1, "hash mismatch case=%0d msg=%0d\n got=%064h\n exp=%064h",
                           count, msg_id_i, hash_out, vec_expected);
                if (msg_id_out !== msg_id_i[31:0])
                    $fatal(1, "msg_id mismatch case=%0d got=%0d exp=%0d", count, msg_id_out, msg_id_i);
                if (block_last_out !== last_i[0])
                    $fatal(1, "last mismatch case=%0d", count);

                // Explicitly verify valid/data stability under output backpressure.
                if (count == 0) begin
                    stable_hash = hash_out;
                    stable_id = msg_id_out;
                    stable_last = block_last_out;
                    repeat (3) begin
                        @(negedge clk);
                        if (!out_valid || hash_out !== stable_hash ||
                            msg_id_out !== stable_id || block_last_out !== stable_last)
                            $fatal(1, "output changed under backpressure");
                    end
                    out_ready = 1;
                end

                @(posedge clk);
                @(negedge clk);
                count = count + 1;
            end
        end

        $fclose(fd);
        $display("SM3 CORE PASS: %0d compression vectors", count);
        $finish;
    end
endmodule
