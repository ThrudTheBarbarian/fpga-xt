// tb_tmds.sv — verify tmds_encoder against the DVI 1.0 spec.
//
// Phases:
//   A. Control codes — drive de=0 with each c[1:0], expect the four
//      fixed control symbols (Figure 3-3).
//   B. Reversibility — drive de=1 with every data byte 0..255 across
//      a long stream; decode the 10-bit output back to 8-bit and
//      check it matches the input.
//   C. DC balance — probe the encoder's internal running disparity
//      counter and verify it stays in [-8, +8] across the sweep
//      (spec bound). Also check the long-term cumulative disparity
//      across all emitted bits is small (well under √N).
//   D. Serializer — feed three known symbols into tmds_serializer
//      and assert the per-cycle output bit matches LSB-first ordering.
//
// The encoder is registered (1-cycle latency), so the test pipelines
// inputs vs. observed outputs.

`default_nettype none
`timescale 1ns / 1ps

module tb_tmds;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [7:0] data;
    logic [1:0] c;
    logic       de;
    wire  [9:0] q_out;

    tmds_encoder u_enc (
        .clk(clk), .rst(rst),
        .data(data), .c(c), .de(de),
        .q_out(q_out));

    // Serializer driven by the same `clk` (treated as bit-clock for the
    // serializer phase). The encoder phases A/B/C don't drive it.
    logic [9:0] ser_symbol = 10'h0;
    wire        ser_out;
    wire  [3:0] ser_phase;

    tmds_serializer u_ser (
        .bit_clk(clk), .rst(rst),
        .symbol(ser_symbol),
        .serial_out(ser_out),
        .bit_phase(ser_phase));

    // Reference 8b/10b decoder. Assumes the 10-bit symbol came from
    // tmds_encoder with de=1 (data symbol, not a control code).
    function automatic logic [7:0] tmds_decode(input logic [9:0] sym);
        logic [7:0] qm_data;
        logic       qm8;
        logic [7:0] d;
        // sym[9] inverted indicator.
        qm_data = sym[9] ? ~sym[7:0] : sym[7:0];
        qm8     = sym[8];
        // Rebuild data from qm_data (XOR if qm8==1, XNOR if qm8==0).
        d[0] = qm_data[0];
        if (qm8) begin
            d[1] = qm_data[1] ^ qm_data[0];
            d[2] = qm_data[2] ^ qm_data[1];
            d[3] = qm_data[3] ^ qm_data[2];
            d[4] = qm_data[4] ^ qm_data[3];
            d[5] = qm_data[5] ^ qm_data[4];
            d[6] = qm_data[6] ^ qm_data[5];
            d[7] = qm_data[7] ^ qm_data[6];
        end else begin
            d[1] = qm_data[1] ~^ qm_data[0];
            d[2] = qm_data[2] ~^ qm_data[1];
            d[3] = qm_data[3] ~^ qm_data[2];
            d[4] = qm_data[4] ~^ qm_data[3];
            d[5] = qm_data[5] ~^ qm_data[4];
            d[6] = qm_data[6] ~^ qm_data[5];
            d[7] = qm_data[7] ~^ qm_data[6];
        end
        return d;
    endfunction

    function automatic int popcount10(input logic [9:0] x);
        int n;
        n = 0;
        for (int i = 0; i < 10; i++) if (x[i]) n++;
        return n;
    endfunction

    int fail_count = 0;
    int max_disp   = 0;
    int min_disp   = 0;
    int running    = 0;     // running cumulative disparity (long-term DC)
    int max_cnt    = 0;
    int min_cnt    = 0;

    initial begin
        $display("[tmds] start");
        data = 8'h00; c = 2'b00; de = 1'b0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== Phase A — control codes =================================
        begin : phase_a
            logic [1:0] cc;
            logic [9:0] expected;
            for (int i = 0; i < 4; i = i + 1) begin
                cc = i[1:0];
                de = 1'b0;
                c  = cc;
                @(posedge clk);
                @(posedge clk);   // 1-cycle pipe latency, then sample
                case (cc)
                    2'b00: expected = 10'b1101010100;
                    2'b01: expected = 10'b0010101011;
                    2'b10: expected = 10'b0101010100;
                    2'b11: expected = 10'b1010101011;
                endcase
                if (q_out !== expected) begin
                    $display("[ctl] FAIL c=%b q=%010b exp=%010b", cc, q_out, expected);
                    fail_count++;
                end
            end
            $display("[tmds/ctl] 4 control codes verified");
        end

        // ===== Phase B + C — sweep + decode + DC balance ===============
        // Drive a deterministic 256-byte stream (data = i). Pipeline lag
        // = 1 cycle: at cycle k, q_out reflects data driven at cycle k-1.
        de = 1'b1;
        c  = 2'b00;
        running = 0;
        max_disp = 0;
        min_disp = 0;
        max_cnt  = 0;
        min_cnt  = 0;
        begin : sweep
            logic [7:0] sent_prev;
            logic [7:0] decoded;
            int         disp;
            int         cnt_signed;
            data = 8'h00;
            @(posedge clk);
            for (int i = 0; i < 256; i = i + 1) begin
                sent_prev = data;
                data      = i[7:0];
                @(posedge clk);
                // q_out now reflects sent_prev's encoding.
                decoded   = tmds_decode(q_out);
                if (decoded !== sent_prev) begin
                    if (fail_count < 8)
                        $display("[rev] FAIL i=%0d sent=$%02h q=%010b decoded=$%02h",
                                 i, sent_prev, q_out, decoded);
                    fail_count++;
                end
                // Update cumulative + per-symbol disparity stats.
                disp = popcount10(q_out) - (10 - popcount10(q_out));
                running += disp;
                if (running > max_disp) max_disp = running;
                if (running < min_disp) min_disp = running;
                cnt_signed = $signed(u_enc.cnt);
                if (cnt_signed > max_cnt) max_cnt = cnt_signed;
                if (cnt_signed < min_cnt) min_cnt = cnt_signed;
            end
            // Final tick to flush the last data byte ($FF).
            sent_prev = data;
            @(posedge clk);
            decoded = tmds_decode(q_out);
            if (decoded !== sent_prev) begin
                $display("[rev] FAIL final sent=$%02h q=%010b decoded=$%02h",
                         sent_prev, q_out, decoded);
                fail_count++;
            end
            disp     = popcount10(q_out) - (10 - popcount10(q_out));
            running += disp;
            cnt_signed = $signed(u_enc.cnt);
            if (cnt_signed > max_cnt) max_cnt = cnt_signed;
            if (cnt_signed < min_cnt) min_cnt = cnt_signed;
        end

        $display("[tmds/sweep] 256 bytes decoded; cumulative disparity end=%0d (range [%0d, %0d]); cnt range [%0d, %0d]",
                 running, min_disp, max_disp, min_cnt, max_cnt);

        // Encoder's per-symbol disparity counter must stay in [-8, +8] —
        // first symbol can hit ±8 from cnt=0; thereafter it self-corrects.
        if (max_cnt > 8 || min_cnt < -8) begin
            $display("[dc/cnt] FAIL encoder cnt out of [-8, +8]: [%0d, %0d]",
                     min_cnt, max_cnt);
            fail_count++;
        end
        // Long-term DC offset across 256 bytes (2560 bits) should be small.
        // Allow generous bound (|end| <= 50) — for a balanced encoder on a
        // sequential sweep this typically lands well under 20.
        if (running > 50 || running < -50) begin
            $display("[dc/long] FAIL cumulative disparity %0d (bound ±50)",
                     running);
            fail_count++;
        end

        // ===== Phase D — serializer ====================================
        // Park a symbol on ser_symbol; sync to ser_phase==9, then the
        // next clk edge is the load edge. From there, 10 cycles of
        // serial_out walk bits 0..9 of the symbol (LSB first).
        // Update ser_symbol on the LAST bit of each symbol so the load
        // edge that follows captures the next symbol.
        de = 1'b0;
        c  = 2'b00;
        begin : phase_d
            logic [9:0] syms [0:2];
            int         sym_i;
            int         bit_i;
            syms[0] = 10'b1101010100;
            syms[1] = 10'b1010101010;
            syms[2] = 10'b1100110011;

            ser_symbol = syms[0];
            // Sync — advance until phase==9, then take the load edge.
            while (ser_phase !== 4'd9) @(posedge clk);
            @(posedge clk);   // load: phase 9→0, shift = syms[0]

            for (sym_i = 0; sym_i < 3; sym_i = sym_i + 1) begin
                for (bit_i = 0; bit_i < 10; bit_i = bit_i + 1) begin
                    if (ser_out !== syms[sym_i][bit_i]) begin
                        if (fail_count < 8)
                            $display("[ser] FAIL sym=%0d bit=%0d got=%0b exp=%0b sym=%010b phase=%0d",
                                     sym_i, bit_i, ser_out,
                                     syms[sym_i][bit_i],
                                     syms[sym_i], ser_phase);
                        fail_count++;
                    end
                    // Stage next symbol so the upcoming load edge picks
                    // it up. Done at bit_i==9 — on this iteration the
                    // following @(posedge clk) IS the load edge.
                    if (bit_i == 9 && sym_i < 2)
                        ser_symbol = syms[sym_i + 1];
                    @(posedge clk);
                end
            end
            $display("[tmds/ser] 3 symbols × 10 bits LSB-first verified");
        end

        if (fail_count == 0) begin
            $display("*** TMDS OK *** ctl + 256 reversibility + DC balance + serializer");
            $finish;
        end else begin
            $display("*** TMDS FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_tmds watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
