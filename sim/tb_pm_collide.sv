`timescale 1ns/1ps
`default_nettype none
//
// tb_pm_collide — beam-time P/M collision engine.
//
// The headline case mirrors ACID800 gtia_pmretrigger exactly: park player 1
// and player 2 at two separate places on the line, start player 0 on top of
// player 1, then MOVE player 0 onto player 2 partway along the line. On real
// silicon the beam has already passed player 1 by then, so the P0PL latch
// keeps that hit AND picks up the new one — P0PL ends at $06 (collided with
// both p1 and p2). A burst-composed collision cannot produce this: it sees
// player 0 at exactly one position for the whole line.
//
// Geometry (atari_x = 4*cyc - 96, x_left = (hpos-48)*2, normal width 16):
//   p1 @ hpos 60  -> x 24..39   -> cycles ~30..33
//   p2 @ hpos 100 -> x 104..119 -> cycles ~50..53
//   p0 starts @ 60, moves to 100 at cycle 40 (after p1's span, before p2's)
//
module tb_pm_collide;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       phi2_tick;
    logic [7:0] cyc;
    logic [7:0] hposp0;
    logic       hitclr;
    logic       border_mode;    // 1 = stack all 8 objects at border_hpos
    logic [7:0] border_hpos;

    logic [15:0] mpl_q, ppl_q;

    gtia_pm_collide dut (
        .clk(clk), .rst(rst),
        .phi2_tick(phi2_tick), .cyc(cyc),
        .hposp0(border_mode ? border_hpos : hposp0),
        .hposp1(border_mode ? border_hpos : 8'd60),
        .hposp2(border_mode ? border_hpos : 8'd100),
        .hposp3(border_mode ? border_hpos : 8'd0),
        .hposm0(border_mode ? border_hpos : 8'd0),
        .hposm1(border_mode ? border_hpos : 8'd0),
        .hposm2(border_mode ? border_hpos : 8'd0),
        .hposm3(border_mode ? border_hpos : 8'd0),
        .sizep0(2'b00), .sizep1(2'b00), .sizep2(2'b00), .sizep3(2'b00),
        .sizem(8'h00),
        .grafp0(border_mode ? 8'h80 : 8'hFF),
        .grafp1(border_mode ? 8'h80 : 8'hFF),
        .grafp2(border_mode ? 8'h80 : 8'hFF),
        .grafp3(border_mode ? 8'h80 : 8'h00),
        .grafm (border_mode ? 8'hAA : 8'h00),
        .hitclr(hitclr),
        .mpl_q(mpl_q), .ppl_q(ppl_q)
    );

    int fail = 0;

    // Sweep one scanline, applying an HPOSP0 move at `move_cyc` (255 = never).
    task automatic sweep_line(input int move_cyc, input logic [7:0] move_to);
        begin
            for (int c = 0; c < 114; c++) begin
                cyc = c[7:0];
                if (c == move_cyc) hposp0 = move_to;
                @(posedge clk); phi2_tick = 1'b1;
                @(posedge clk); phi2_tick = 1'b0;
                @(posedge clk);
            end
        end
    endtask

    task automatic clear_latches;
        begin
            @(posedge clk); hitclr = 1'b1;
            @(posedge clk); hitclr = 1'b0;
            @(posedge clk);
        end
    endtask

    // Stack every player and missile at one HPOS and sweep a line.
    task automatic border_test(input logic [7:0] hp,
                               input logic [15:0] exp_mpl,
                               input logic [15:0] exp_ppl,
                               input string tag);
        begin
            clear_latches();
            border_hpos = hp; border_mode = 1'b1;
            sweep_line(255, 8'd0);
            if (mpl_q !== exp_mpl) begin
                $display("FAIL %s: mpl=%04h expected %04h", tag, mpl_q, exp_mpl);
                fail++;
            end
            if (ppl_q !== exp_ppl) begin
                $display("FAIL %s: ppl=%04h expected %04h", tag, ppl_q, exp_ppl);
                fail++;
            end
            border_mode = 1'b0;
        end
    endtask

    initial begin
        border_mode = 0; border_hpos = 8'h22;
        phi2_tick = 0; cyc = 0; hitclr = 0; hposp0 = 8'd60;
        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: no move — p0 sits on p1 only -> P0PL = $02 --------------
        clear_latches();
        hposp0 = 8'd60;
        sweep_line(255, 8'd0);
        if (ppl_q[3:0] !== 4'h2) begin
            $display("FAIL T1 static-overlap: P0PL=$%01h expected $2 (p1 only)", ppl_q[3:0]);
            fail++;
        end

        // ---- T2: no move, parked on p2 only -> P0PL = $04 ----------------
        clear_latches();
        hposp0 = 8'd100;
        sweep_line(255, 8'd0);
        if (ppl_q[3:0] !== 4'h4) begin
            $display("FAIL T2 static-overlap-p2: P0PL=$%01h expected $4 (p2 only)", ppl_q[3:0]);
            fail++;
        end

        // ---- T3: THE RETRIGGER — move mid-line, collide with BOTH --------
        clear_latches();
        hposp0 = 8'd60;
        sweep_line(40, 8'd100);
        if (ppl_q[3:0] !== 4'h6) begin
            $display("FAIL T3 retrigger: P0PL=$%01h expected $6 (p1 AND p2)", ppl_q[3:0]);
            fail++;
        end

        // ---- T4: the collision is symmetric -----------------------------
        // p1 must show p0 and p2 must show p0.
        if (ppl_q[7:4] !== 4'h1) begin
            $display("FAIL T4 symmetry P1PL=$%01h expected $1", ppl_q[7:4]);
            fail++;
        end
        if (ppl_q[11:8] !== 4'h1) begin
            $display("FAIL T4 symmetry P2PL=$%01h expected $1", ppl_q[11:8]);
            fail++;
        end

        // ---- T5: a player never collides with itself --------------------
        if (ppl_q[0] !== 1'b0 || ppl_q[5] !== 1'b0 ||
            ppl_q[10] !== 1'b0 || ppl_q[15] !== 1'b0) begin
            $display("FAIL T5 self-collision diagonal set: PPL=$%04h", ppl_q);
            fail++;
        end

        // ---- T6: HITCLR mid-line drops the earlier hit -------------------
        // Clear AFTER p1's span but BEFORE p2's, having moved onto p2: only
        // the p2 hit should survive.
        clear_latches();
        hposp0 = 8'd60;
        for (int c = 0; c < 114; c++) begin
            cyc = c[7:0];
            if (c == 40) hposp0 = 8'd100;
            hitclr = (c == 45);
            @(posedge clk); phi2_tick = 1'b1;
            @(posedge clk); phi2_tick = 1'b0;
            @(posedge clk);
        end
        hitclr = 1'b0;
        if (ppl_q[3:0] !== 4'h4) begin
            $display("FAIL T6 mid-line HITCLR: P0PL=$%01h expected $4 (p1 hit cleared)", ppl_q[3:0]);
            fail++;
        end

        // ---- T7/T8: the left border edge, ported from tb_antic_modes ------
        // All 4 players and all 4 missiles stacked at HPOS $22 with GRAFP=$80
        // (leftmost two pixels lit) land exactly ON the visible low bound and
        // must all collide mutually.  One colour clock further left ($21) is
        // horizontal blank and must produce nothing.  Together these pin the
        // exact boundary, which is why they are worth keeping.
        border_test(8'h22, 16'hFFFF, 16'h7BDE, "T7 border $22");
        border_test(8'h21, 16'h0000, 16'h0000, "T8 border $21 HBLANK");

        if (fail == 0) $display("tb_pm_collide: all checks PASS");
        else           $display("tb_pm_collide: %0d FAIL", fail);
        $finish;
    end

endmodule

`default_nettype wire
