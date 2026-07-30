`timescale 1ns/1ps
`default_nettype none
//
// tb_gtia_priority — the priority walk.
//
// T5 is the one that matters most in practice: PRIOR = $00 is the power-on
// value, so an ordinary display must survive it. It does, because $00 asserts no
// ordering, which lights nothing — the same answer as every ordering
// disagreeing. Playfield-only displays are unaffected (the four tables rank the
// playfield identically), a player over background still wins, and only a real
// player/playfield overlap goes black. That is what the hardware does with
// GPRIOR left alone, and it falls out with no special case.
//
// T8 is antic_hiresbug: a lit hi-res pixel RANKS as playfield 2 but is REPORTED
// as the hi-res blend, so it loses to a player exactly as PF2 would while still
// being coloured COLPF1-luma over COLPF2-hue.
//
module tb_gtia_priority;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       start;
    logic [7:0] pres;
    logic [2:0] pf_src;
    logic [7:0] prior;

    wire [3:0] win_src;
    wire       win_black, win_multi01, win_multi23, valid;

    gtia_priority dut (
        .clk(clk), .rst(rst),
        .start(start), .pres(pres), .pf_src(pf_src), .prior(prior),
        .win_src(win_src), .win_black(win_black),
        .win_multi01(win_multi01), .win_multi23(win_multi23), .valid(valid)
    );

    int fail = 0;

    localparam int W_BK  = 0, W_PF0 = 1, W_PF1 = 2, W_PF2 = 3, W_PF3 = 4;
    localparam int W_HR  = 5, W_PM0 = 6, W_PM1 = 7, W_PM2 = 8, W_PM3 = 9;

    logic [3:0] got_src;
    logic       got_black, got_m01, got_m23;

    task automatic resolve(input [7:0] p, input [2:0] pf, input [7:0] pr);
        int guard;
        begin
            pres = p; pf_src = pf; prior = pr;
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            guard = 0;
            while (!valid && guard < 64) begin @(negedge clk); guard++; end
            if (guard >= 64) begin
                $display("FAIL: priority walk never settled"); fail++;
            end
            got_src = win_src; got_black = win_black;
            got_m01 = win_multi01; got_m23 = win_multi23;
            @(negedge clk);
        end
    endtask

    task automatic chk(input int want, input string tag);
        begin
            if (got_black) begin
                $display("FAIL %s: came out BLACK, expected source %0d", tag, want);
                fail++;
            end else if (int'(got_src) != want) begin
                $display("FAIL %s: source %0d, expected %0d", tag, got_src, want);
                fail++;
            end
        end
    endtask

    task automatic chk_black(input string tag);
        begin
            if (!got_black) begin
                $display("FAIL %s: source %0d, expected BLACK", tag, got_src);
                fail++;
            end
        end
    endtask

    initial begin
        start = 0; pres = 8'h00; pf_src = 3'd0; prior = 8'h01;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: PRIOR $01 — players above the whole playfield
        // ================================================================
        resolve(8'h00, 3'd0, 8'h01);  chk(W_BK,  "T1 nothing -> background");
        resolve(8'h00, 3'd1, 8'h01);  chk(W_PF0, "T1b playfield alone");
        resolve(8'h01, 3'd1, 8'h01);  chk(W_PM0, "T1c P0 over PF0");
        resolve(8'h08, 3'd1, 8'h01);  chk(W_PM3, "T1d even P3 beats PF0");
        resolve(8'h0A, 3'd0, 8'h01);  chk(W_PM1, "T1e P1 beats P3");
        // Playfield ranks PF0 > PF1 > PF2 > PF3 in every ordering.
        resolve(8'h00, 3'd4, 8'h01);  chk(W_PF3, "T1f PF3 alone");

        // ================================================================
        // T2: PRIOR $04 — the whole playfield above the players
        // ================================================================
        resolve(8'h01, 3'd1, 8'h04);  chk(W_PF0, "T2 PF0 over P0");
        resolve(8'h01, 3'd4, 8'h04);  chk(W_PF3, "T2b even PF3 beats P0");
        resolve(8'h01, 3'd0, 8'h04);  chk(W_PM0, "T2c P0 still beats background");

        // ================================================================
        // T3: PRIOR $02 — P0/P1 above the playfield, P2/P3 below it
        // ================================================================
        resolve(8'h01, 3'd1, 8'h02);  chk(W_PM0, "T3 P0 over PF0");
        resolve(8'h04, 3'd1, 8'h02);  chk(W_PF0, "T3b PF0 over P2");
        resolve(8'h04, 3'd0, 8'h02);  chk(W_PM2, "T3c P2 over background");
        resolve(8'h05, 3'd1, 8'h02);  chk(W_PM0, "T3d P0 outranks both");

        // ================================================================
        // T4: PRIOR $08 — PF0/PF1 above the players, PF2/PF3 below
        // ================================================================
        resolve(8'h01, 3'd1, 8'h08);  chk(W_PF0, "T4 PF0 over P0");
        resolve(8'h01, 3'd2, 8'h08);  chk(W_PF1, "T4b PF1 over P0");
        resolve(8'h01, 3'd3, 8'h08);  chk(W_PM0, "T4c P0 over PF2");
        resolve(8'h01, 3'd4, 8'h08);  chk(W_PM0, "T4d P0 over PF3");

        // ================================================================
        // T5: PRIOR $00 — the power-on value must not break a display
        // ================================================================
        // Playfield only: all four orderings rank the playfield the same way,
        // so they agree and the display is completely normal.
        resolve(8'h00, 3'd1, 8'h00);  chk(W_PF0, "T5 PF0 alone with PRIOR $00");
        resolve(8'h00, 3'd2, 8'h00);  chk(W_PF1, "T5b PF1");
        resolve(8'h00, 3'd3, 8'h00);  chk(W_PF2, "T5c PF2");
        resolve(8'h00, 3'd4, 8'h00);  chk(W_PF3, "T5d PF3");
        resolve(8'h00, 3'd0, 8'h00);  chk(W_BK,  "T5e background");
        // A player over background wins in every ordering, so it shows.
        resolve(8'h01, 3'd0, 8'h00);  chk(W_PM0, "T5f P0 over background");
        // A player over the playfield is the genuine conflict, and goes black.
        resolve(8'h01, 3'd1, 8'h00);  chk_black("T5g P0 over PF0 with PRIOR $00");

        // ================================================================
        // T6: PRIOR $10 — the fifth player
        // ================================================================
        // Without it a missile takes its player's colour and priority...
        resolve(8'h10, 3'd0, 8'h01);  chk(W_PM0, "T6 missile 0 as player 0");
        resolve(8'h80, 3'd0, 8'h01);  chk(W_PM3, "T6b missile 3 as player 3");
        // ...and with it, all four become COLPF3.
        resolve(8'h10, 3'd0, 8'h11);  chk(W_PF3, "T6c missile 0 as the fifth player");
        resolve(8'h80, 3'd0, 8'h11);  chk(W_PF3, "T6d missile 3 as the fifth player");
        // As PF3 it now loses to a player under $01...
        resolve(8'h11, 3'd0, 8'h11);  chk(W_PM0, "T6e P0 beats the fifth player");
        // ...and beats one under $04.
        resolve(8'h11, 3'd0, 8'h14);  chk(W_PF3, "T6f the fifth player beats P0 under $04");

        // ================================================================
        // T7: PRIOR $20 — multi-colour players recolour, they do not re-rank
        // ================================================================
        resolve(8'h03, 3'd0, 8'h21);
        chk(W_PM0, "T7 P0/P1 overlap still ranks as P0");
        if (!got_m01) begin
            $display("FAIL T7b: P0/P1 overlap did not report multi-colour"); fail++;
        end
        if (got_m23) begin
            $display("FAIL T7c: P2/P3 multi-colour reported with neither present");
            fail++;
        end
        resolve(8'h0C, 3'd0, 8'h21);
        if (!got_m23) begin
            $display("FAIL T7d: P2/P3 overlap did not report multi-colour"); fail++;
        end
        // Only ONE of the pair present is not an overlap.
        resolve(8'h01, 3'd0, 8'h21);
        if (got_m01) begin
            $display("FAIL T7e: multi-colour reported for P0 alone"); fail++;
        end
        // ...and it needs the PRIOR bit.
        resolve(8'h03, 3'd0, 8'h01);
        if (got_m01) begin
            $display("FAIL T7f: multi-colour reported with PRIOR bit 5 clear"); fail++;
        end

        // ================================================================
        // T8: the hi-res quirk (antic_hiresbug)
        // ================================================================
        // A lit hi-res pixel is REPORTED as the blend...
        resolve(8'h00, 3'd5, 8'h01);  chk(W_HR,  "T8 hi-res lit alone");
        // ...but RANKS as PF2, so under $08 it loses to a player exactly as
        // PF2 does, and wins over one under $04 exactly as PF2 does.
        resolve(8'h01, 3'd5, 8'h08);  chk(W_PM0, "T8b P0 beats hi-res under $08");
        resolve(8'h01, 3'd5, 8'h04);  chk(W_HR,  "T8c hi-res beats P0 under $04");
        // The proof it is PF2 and not PF0: PF0 would WIN under $08.
        resolve(8'h01, 3'd1, 8'h08);  chk(W_PF0, "T8d PF0 beats P0 under $08");

        // ================================================================
        // T9: conflicting orderings go black
        // ================================================================
        // $05 = $01 (players first) and $04 (playfield first) together.
        resolve(8'h01, 3'd1, 8'h05);  chk_black("T9 P0 over PF0 with PRIOR $05");
        // Where they agree there is no conflict.
        resolve(8'h00, 3'd1, 8'h05);  chk(W_PF0, "T9b playfield alone under $05");
        resolve(8'h01, 3'd0, 8'h05);  chk(W_PM0, "T9c player over background under $05");
        resolve(8'h00, 3'd0, 8'h05);  chk(W_BK,  "T9d background under $05");

        // ================================================================
        // T10: the background always wins if nothing else is present
        // ================================================================
        for (int p = 0; p < 16; p++) begin
            resolve(8'h00, 3'd0, 8'(p));
            if (got_black || int'(got_src) != W_BK) begin
                $display("FAIL T10: PRIOR $%02h with nothing present gave source %0d black=%0b",
                         p, got_src, got_black);
                fail++;
            end
        end

        if (fail == 0) $display("tb_gtia_priority: all checks PASS");
        else           $display("tb_gtia_priority: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
