module sm3_block_builder #(
    parameter int MSG_ID_W = 32
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // One descriptor per message. Length is the original unpadded byte count.
    input  logic                  desc_valid,
    output logic                  desc_ready,
    input  logic [MSG_ID_W-1:0]   desc_msg_id,
    input  logic [31:0]           desc_len_bytes,

    // 128-bit payload stream, bytes packed from MSB to LSB.
    // keep[15] corresponds to data[127:120]. All non-final beats must be full.
    input  logic                  s_valid,
    output logic                  s_ready,
    input  logic [127:0]          s_data,
    input  logic [15:0]           s_keep,

    // Pre-padded SM3 compression blocks.
    output logic                  block_valid,
    input  logic                  block_ready,
    output logic [511:0]          block_data,
    output logic [MSG_ID_W-1:0]   block_msg_id,
    output logic                  block_first,
    output logic                  block_last
);

    typedef enum logic [1:0] {
        PAD_NONE   = 2'd0,
        PAD_EXTRA  = 2'd1,
        PAD_SECOND = 2'd2
    } pad_state_t;

    logic active;
    logic [MSG_ID_W-1:0] msg_id_q;
    logic [31:0] remaining_q;
    logic [63:0] total_bits_q;
    logic [127:0] block_lane0_q;
    logic [127:0] block_lane1_q;
    logic [127:0] block_lane2_q;
    logic [127:0] block_lane3_q;
    logic [511:0] block_buf_combined;
    logic [127:0] block_data0_q;
    logic [127:0] block_data1_q;
    logic [127:0] block_data2_q;
    logic [127:0] block_data3_q;
    logic [6:0] fill_count;
    logic first_block_q;
    pad_state_t pad_state;
    logic finish_after_output;

    // The input interface is 128 bits wide. Before each accepted payload beat,
    // fill_count is therefore restricted to 0/16/32/48. Keep the assembly
    // network lane-based instead of synthesizing a 512-bit variable byte inserter.
    function automatic logic [127:0] mask_lane(
        input logic [127:0] beat,
        input logic [4:0]   nbytes
    );
        logic [127:0] tmp;
        integer j;
        begin
            tmp = '0;
            for (j = 0; j < 16; j = j + 1)
                if (j < nbytes)
                    tmp[127 - j*8 -: 8] = beat[127 - j*8 -: 8];
            mask_lane = tmp;
        end
    endfunction

    function automatic logic [127:0] pad_lane(
        input logic [127:0] beat,
        input logic [4:0]   nbytes
    );
        logic [127:0] tmp;
        integer j;
        begin
            tmp = '0;
            for (j = 0; j < 16; j = j + 1) begin
                if (j < nbytes)
                    tmp[127 - j*8 -: 8] = beat[127 - j*8 -: 8];
                else if (j == nbytes)
                    tmp[127 - j*8 -: 8] = 8'h80;
            end
            pad_lane = tmp;
        end
    endfunction

    function automatic logic [15:0] expected_keep(input logic [4:0] nbytes);
        logic [15:0] mask;
        begin
            if (nbytes >= 16)
                mask = 16'hffff;
            else if (nbytes == 0)
                mask = 16'h0000;
            else
                mask = 16'hffff << (16 - nbytes);
            expected_keep = mask;
        end
    endfunction

    function automatic logic [511:0] padding_only_block(input logic [63:0] total_bits);
        logic [511:0] tmp;
        begin
            tmp = '0;
            tmp[511:504] = 8'h80;
            tmp[63:0] = total_bits;
            padding_only_block = tmp;
        end
    endfunction

    function automatic logic [511:0] length_only_block(input logic [63:0] total_bits);
        logic [511:0] tmp;
        begin
            tmp = '0;
            tmp[63:0] = total_bits;
            length_only_block = tmp;
        end
    endfunction

    logic out_slot_available;
    (* max_fanout = 16 *) logic beat_fire;
    (* max_fanout = 16 *) logic block_data_load;
    (* max_fanout = 16 *) logic block_data0_load;
    (* max_fanout = 16 *) logic block_data1_load;
    (* max_fanout = 16 *) logic block_data2_load;
    (* max_fanout = 16 *) logic block_data3_load;
    logic [127:0] block_data0_next;
    logic [127:0] block_data1_next;
    logic [127:0] block_data2_next;
    logic [127:0] block_data3_next;
    logic empty_msg_pending_q;
    logic empty_msg_emit;
    logic pad_emit;
    logic block_emit_any;
    logic out_slot_ready_q;
    logic beat_emit;

    // Registered per-beat control flags.  Keeping these out of the
    // remaining_q -> s_ready -> block_data CE path is what lets the block
    // builder close at 250 MHz without relying on placement.
    logic [4:0] expected_bytes_q;
    logic [6:0] next_fill_q;
    logic       remaining_gt16_q;
    logic       remaining_le16_q;
    logic       remaining_nonzero_q;
    logic       will_emit_q;
    logic       next_fill_eq64_q;
    logic       next_fill_le55_q;

    logic [31:0] remaining_next;
    logic [6:0]  fill_after;
    logic [4:0]  expected_next;
    logic [6:0]  next_fill_next;
    logic        will_emit_next;

    logic [127:0] lane_masked;
    logic [127:0] lane_padded;
    logic [511:0] beat_merged;
    logic [511:0] beat_with_pad;
    logic [511:0] beat_final;

    // Keep the 64-byte assembly buffer as four independently enabled 128-bit
    // lanes.  A single 512-bit register gives the synthesizer one 512-bit CE
    // and one very high-fanout lane mux, which routes badly even when the
    // builder is confined to a pblock.
    logic block_accumulate;
    logic block_clear;
    (* max_fanout = 16 *) logic block_lane0_sel;
    (* max_fanout = 16 *) logic block_lane1_sel;
    (* max_fanout = 16 *) logic block_lane2_sel;
    (* max_fanout = 16 *) logic block_lane3_sel;
    (* max_fanout = 16 *) logic block_lane0_ce;
    (* max_fanout = 16 *) logic block_lane1_ce;
    (* max_fanout = 16 *) logic block_lane2_ce;
    (* max_fanout = 16 *) logic block_lane3_ce;

    assign block_buf_combined = {block_lane0_q, block_lane1_q,
                                 block_lane2_q, block_lane3_q};
    assign block_data = {block_data0_q, block_data1_q,
                         block_data2_q, block_data3_q};
    assign block_data0_load = block_data_load;
    assign block_data1_load = block_data_load;
    assign block_data2_load = block_data_load;
    assign block_data3_load = block_data_load;
    assign out_slot_available = !block_valid || block_ready;
    assign beat_fire = s_valid && s_ready;

    always_comb begin
        lane_masked = mask_lane(s_data, expected_bytes_q);
        lane_padded = pad_lane(s_data, expected_bytes_q);

        beat_merged = block_buf_combined;
        case (fill_count)
            7'd0:  beat_merged[511:384] = lane_masked;
            7'd16: beat_merged[383:256] = lane_masked;
            7'd32: beat_merged[255:128] = lane_masked;
            7'd48: beat_merged[127:0]   = lane_masked;
            default: beat_merged = block_buf_combined;
        endcase

        // For a partial final beat the 0x80 byte lives in that same 128-bit
        // lane. For a full 16-byte final beat at offsets 0/16/32 it is the
        // first byte of the following lane. The 48+16 case is an exact
        // 64-byte boundary and uses a separate padding block.
        beat_with_pad = beat_merged;
        if (expected_bytes_q < 16) begin
            case (fill_count)
                7'd0:  beat_with_pad[511:384] = lane_padded;
                7'd16: beat_with_pad[383:256] = lane_padded;
                7'd32: beat_with_pad[255:128] = lane_padded;
                7'd48: beat_with_pad[127:0]   = lane_padded;
                default: beat_with_pad = beat_merged;
            endcase
        end else begin
            case (fill_count)
                7'd0:  beat_with_pad[383:376] = 8'h80;
                7'd16: beat_with_pad[255:248] = 8'h80;
                7'd32: beat_with_pad[127:120] = 8'h80;
                default: ;
            endcase
        end

        beat_final = beat_with_pad;
        beat_final[63:0] = total_bits_q;

        desc_ready = !active && out_slot_available;
        // Use a registered view of the output slot for the payload-load
        // decision.  The FIFO occupancy then only has to reach a single
        // register, not the 512-bit block-data mux.  A completed block may be
        // registered while the FIFO is full; block_valid simply waits.
        s_ready = active
               && remaining_nonzero_q
               && (pad_state == PAD_NONE)
               && (!will_emit_q || out_slot_ready_q)
               && !(block_valid && !block_ready);

        // Explicit block_data load enable.  The 512-bit payload register has a
        // single CE; giving it a name lets synthesis replicate the high-fanout
        // enable instead of routing one LUT output to all 512 flops.
        empty_msg_emit = empty_msg_pending_q && out_slot_ready_q;
        pad_emit       = active && (pad_state != PAD_NONE) && out_slot_ready_q;
        beat_emit      = beat_fire
                      && ((remaining_gt16_q && next_fill_eq64_q)
                          || remaining_le16_q);
        block_emit_any = empty_msg_emit || pad_emit || beat_emit;
        // The payload lanes load only when a block is actually emitted.  The
        // empty-message padding block is emitted from a registered pending bit,
        // so the descriptor-length comparator is not on a 512-bit CE path.
        block_data_load = block_emit_any;

        block_data0_next = '0;
        block_data1_next = '0;
        block_data2_next = '0;
        block_data3_next = '0;
        if (empty_msg_emit) begin
            block_data0_next = {8'h80, 120'd0};
        end else if (pad_emit) begin
            if (pad_state == PAD_SECOND) begin
                block_data3_next = {56'd0, total_bits_q};
            end else begin
                block_data0_next = {8'h80, 120'd0};
                block_data3_next = {56'd0, total_bits_q};
            end
        end else if (beat_emit) begin
            if (remaining_gt16_q || next_fill_eq64_q) begin
                block_data0_next = beat_merged[511:384];
                block_data1_next = beat_merged[383:256];
                block_data2_next = beat_merged[255:128];
                block_data3_next = beat_merged[127:0];
            end else if (next_fill_le55_q) begin
                block_data0_next = beat_final[511:384];
                block_data1_next = beat_final[383:256];
                block_data2_next = beat_final[255:128];
                block_data3_next = beat_final[127:0];
            end else begin
                block_data0_next = beat_with_pad[511:384];
                block_data1_next = beat_with_pad[383:256];
                block_data2_next = beat_with_pad[255:128];
                block_data3_next = beat_with_pad[127:0];
            end
        end

        block_accumulate = remaining_gt16_q && !next_fill_eq64_q;
        block_clear = (desc_valid && desc_ready)
                   || (beat_fire && !block_accumulate)
                   || (block_valid && block_ready && block_last
                       && finish_after_output);

        block_lane0_sel = beat_fire && block_accumulate
                       && (fill_count == 7'd0);
        block_lane1_sel = beat_fire && block_accumulate
                       && (fill_count == 7'd16);
        block_lane2_sel = beat_fire && block_accumulate
                       && (fill_count == 7'd32);
        block_lane3_sel = beat_fire && block_accumulate
                       && (fill_count == 7'd48);

        block_lane0_ce = block_clear || block_lane0_sel;
        block_lane1_ce = block_clear || block_lane1_sel;
        block_lane2_ce = block_clear || block_lane2_sel;
        block_lane3_ce = block_clear || block_lane3_sel;
    end

    // Next-beat flags are computed from the current registered state.  The
    // arithmetic result and the flags are registered on beat_fire, so the
    // payload-load enable only sees registered control.
    always_comb begin
        remaining_next = remaining_q - 32'(expected_bytes_q);
        fill_after = next_fill_eq64_q ? 7'd0 : next_fill_q;
        expected_next = (remaining_next >= 16) ? 5'd16 : remaining_next[4:0];
        next_fill_next = fill_after + 7'(expected_next);
        will_emit_next = (remaining_next != 0)
                      && ((next_fill_next == 64) || (remaining_next <= 16));
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active              <= 1'b0;
            msg_id_q            <= '0;
            remaining_q         <= '0;
            total_bits_q        <= '0;
            block_lane0_q       <= '0;
            block_lane1_q       <= '0;
            block_lane2_q       <= '0;
            block_lane3_q       <= '0;
            fill_count          <= '0;
            first_block_q       <= 1'b1;
            pad_state           <= PAD_NONE;
            finish_after_output <= 1'b0;
            empty_msg_pending_q <= 1'b0;
            out_slot_ready_q    <= 1'b0;

            block_valid         <= 1'b0;
            block_data0_q       <= '0;
            block_data1_q       <= '0;
            block_data2_q       <= '0;
            block_data3_q       <= '0;
            block_msg_id        <= '0;
            block_first         <= 1'b0;
            block_last          <= 1'b0;

            expected_bytes_q     <= '0;
            next_fill_q          <= '0;
            remaining_gt16_q     <= 1'b0;
            remaining_le16_q     <= 1'b0;
            remaining_nonzero_q  <= 1'b0;
            will_emit_q          <= 1'b0;
            next_fill_eq64_q     <= 1'b0;
            next_fill_le55_q     <= 1'b0;
        end else begin
            // Keep a registered permission-to-emit.  It is cleared whenever a
            // block is emitted and re-armed only when the output slot is free.
            out_slot_ready_q <= block_emit_any ? 1'b0 : out_slot_available;

            // Four lane-local payload registers.  Each 128-bit lane has its own
            // replicated CE, so a single 512-bit load enable does not have to
            // reach every payload flop across the block builder.
            if (block_data0_load)
                block_data0_q <= block_data0_next;
            if (block_data1_load)
                block_data1_q <= block_data1_next;
            if (block_data2_load)
                block_data2_q <= block_data2_next;
            if (block_data3_load)
                block_data3_q <= block_data3_next;

            if (block_lane0_ce)
                block_lane0_q <= block_lane0_sel ? lane_masked : '0;
            if (block_lane1_ce)
                block_lane1_q <= block_lane1_sel ? lane_masked : '0;
            if (block_lane2_ce)
                block_lane2_q <= block_lane2_sel ? lane_masked : '0;
            if (block_lane3_ce)
                block_lane3_q <= block_lane3_sel ? lane_masked : '0;

            // Consume current output. A new output may replace it below in the
            // same cycle when block_ready is asserted.
            if (block_valid && block_ready) begin
                block_valid <= 1'b0;
                if (block_last && finish_after_output) begin
                    active              <= 1'b0;
                    finish_after_output <= 1'b0;
                    pad_state           <= PAD_NONE;
                    fill_count          <= '0;
                end
            end

            // Accept a new message descriptor only when the previous message
            // has fully retired its final output block.
            if (desc_valid && desc_ready) begin
                active        <= 1'b1;
                msg_id_q      <= desc_msg_id;
                remaining_q   <= desc_len_bytes;
                total_bits_q  <= {29'd0, desc_len_bytes, 3'b000};
                fill_count    <= '0;
                first_block_q <= 1'b1;
                pad_state     <= PAD_NONE;

                expected_bytes_q <= (desc_len_bytes >= 16)
                                  ? 5'd16 : desc_len_bytes[4:0];
                next_fill_q      <= (desc_len_bytes >= 16)
                                  ? 7'd16 : {2'b00, desc_len_bytes[4:0]};
                remaining_gt16_q    <= (desc_len_bytes > 16);
                remaining_le16_q    <= (desc_len_bytes <= 16);
                remaining_nonzero_q <= (desc_len_bytes != 0);
                will_emit_q         <= (desc_len_bytes != 0)
                                    && (desc_len_bytes <= 16);
                next_fill_eq64_q    <= 1'b0;
                next_fill_le55_q    <= 1'b1;

                // Empty messages emit their padding block from a registered
                // pending bit on the next cycle.
                empty_msg_pending_q <= (desc_len_bytes == 0);
                finish_after_output <= 1'b0;
            end

            if (empty_msg_emit) begin
                block_valid         <= 1'b1;
                block_msg_id        <= msg_id_q;
                block_first         <= 1'b1;
                block_last          <= 1'b1;
                first_block_q       <= 1'b0;
                finish_after_output <= 1'b1;
                empty_msg_pending_q <= 1'b0;
            end

            // After a block ending at byte 64 or a 56..63-byte tail, emit the
            // required final padding-only/length block once the output slot is free.
            if (pad_emit) begin
                block_valid  <= 1'b1;
                block_msg_id <= msg_id_q;
                block_first  <= first_block_q;
                block_last   <= 1'b1;
                first_block_q <= 1'b0;
                pad_state    <= PAD_NONE;
                finish_after_output <= 1'b1;
            end

            if (beat_fire) begin
`ifndef SYNTHESIS
                if (s_keep != expected_keep(expected_bytes_q)) begin
                    $error("SM3 frontend keep mismatch: remaining=%0d expected_keep=%h got=%h",
                           remaining_q, expected_keep(expected_bytes_q), s_keep);
                end
`endif

                remaining_q <= remaining_next;
                expected_bytes_q    <= expected_next;
                next_fill_q         <= next_fill_next;
                remaining_gt16_q    <= (remaining_next > 16);
                remaining_le16_q    <= (remaining_next <= 16);
                remaining_nonzero_q <= (remaining_next != 0);
                will_emit_q         <= will_emit_next;
                next_fill_eq64_q    <= (next_fill_next == 64);
                next_fill_le55_q    <= (next_fill_next <= 55);

                if (remaining_gt16_q) begin
                    // Not the final payload beat.
                    if (next_fill_eq64_q) begin
                        block_valid  <= 1'b1;
                        block_msg_id <= msg_id_q;
                        block_first  <= first_block_q;
                        block_last   <= 1'b0;
                        first_block_q <= 1'b0;
                        fill_count   <= '0;
                    end else begin
                        fill_count <= next_fill_q;
                    end
                end else begin
                    // Final payload beat. remaining_q is the number of bytes
                    // accepted on this beat (1..16).
                    if (next_fill_eq64_q) begin
                        // Exact 64-byte boundary: data block first, then an
                        // additional padding block carrying the bit length.
                        block_valid  <= 1'b1;
                        block_msg_id <= msg_id_q;
                        block_first  <= first_block_q;
                        block_last   <= 1'b0;
                        first_block_q <= 1'b0;
                        fill_count   <= '0;
                        pad_state    <= PAD_EXTRA;
                    end else if (next_fill_le55_q) begin
                        // Padding and 64-bit length fit in this block.
                        block_valid  <= 1'b1;
                        block_msg_id <= msg_id_q;
                        block_first  <= first_block_q;
                        block_last   <= 1'b1;
                        first_block_q <= 1'b0;
                        fill_count   <= '0;
                        finish_after_output <= 1'b1;
                    end else begin
                        // 56..63 data bytes: append the '1' byte now, then
                        // emit a second block containing only the length.
                        block_valid  <= 1'b1;
                        block_msg_id <= msg_id_q;
                        block_first  <= first_block_q;
                        block_last   <= 1'b0;
                        first_block_q <= 1'b0;
                        fill_count   <= '0;
                        pad_state    <= PAD_SECOND;
                    end
                end
            end
        end
    end

endmodule
