`timescale 1ns/1ps
`default_nettype none
//
// tb_gtia_collide — the sixteen collision latches.
//
// T5 mirrors gtia_collision's actual complaint: with the active-line gate
// removed the latches accumulate all the way down the frame and the test
// reports "P/M collisions were detected in VBLANK". Horizontal windowing alone
// does not fix it, because the problem is per LINE.
//
// T2 pins the self-collision rule from tb_pm_collide T5: bit n of PnPL is always
// clear, but a missile CAN collide with its own player, because they are
// different objects.
//
module tb_gtia_collide;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       start, active, hitclr;
    logic [7:0] pres;
    logic [2:0] pf_src;

    wire [15:0] m_pf, p_pf, m_pl, p_pl;
    wire        busy;

    gtia_collide dut (
        .clk(clk), .rst(rst),
        .start(start), .pres(pres), .pf_src(pf_src),
        .active(active), .hitclr(hitclr),
        .m_pf(m_pf), .p_pf(p_pf), .m_pl(m_pl), .p_pl(p_pl), .busy(busy)
    );

    int fail = 0;

    function automatic logic [3:0] nib(input [15:0] v, input int n);
        nib = v[n*4 +: 4];
    endfunction

    task automatic cc(input [7:0] p, input [2:0] pf);
        int guard;
        begin
            pres = p; pf_src = pf;
            @(negedge clk); start = 1'b1;
            @(negedge clk); start = 1'b0;
            guard = 0;
            while (busy && guard < 32) begin @(negedge clk); guard++; end
            @(negedge clk);
        end
    endtask

    task automatic clear;
        begin
            @(negedge clk); hitclr = 1'b1;
            @(negedge clk); hitclr = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic chk(input [3:0] got, input [3:0] want, input string tag);
        begin
            if (got !== want) begin
                $display("FAIL %s: %04b, expected %04b", tag, got, want);
                fail++;
            end
        end
    endtask

    initial begin
        start = 0; active = 1; hitclr = 0; pres = 8'h00; pf_src = 3'd0;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ================================================================
        // T1: player against playfield
        // ================================================================
        clear();
        cc(8'h01, 3'd1);                        // P0 over PF0
        chk(nib(p_pf, 0), 4'b0001, "T1 P0PF after PF0");
        cc(8'h01, 3'd3);                        // P0 over PF2
        chk(nib(p_pf, 0), 4'b0101, "T1b P0PF accumulates PF2");
        chk(nib(p_pf, 1), 4'b0000, "T1c P1PF untouched");
        // Background is not a playfield.
        clear();
        cc(8'h01, 3'd0);
        chk(nib(p_pf, 0), 4'b0000, "T1d P0 over background collides with nothing");
        // Missiles have their own set.
        clear();
        cc(8'h20, 3'd4);                        // missile 1 over PF3
        chk(nib(m_pf, 1), 4'b1000, "T1e M1PF after PF3");
        chk(nib(p_pf, 1), 4'b0000, "T1f P1PF must not see a missile's hit");

        // ================================================================
        // T2: player against player, and the self rule
        // ================================================================
        clear();
        cc(8'h03, 3'd0);                        // P0 and P1 together
        chk(nib(p_pl, 0), 4'b0010, "T2 P0PL sees P1");
        chk(nib(p_pl, 1), 4'b0001, "T2b P1PL sees P0");
        // Never itself.
        clear();
        cc(8'h0F, 3'd0);                        // all four players
        chk(nib(p_pl, 0), 4'b1110, "T2c P0PL is everyone but P0");
        chk(nib(p_pl, 1), 4'b1101, "T2d P1PL is everyone but P1");
        chk(nib(p_pl, 2), 4'b1011, "T2e P2PL");
        chk(nib(p_pl, 3), 4'b0111, "T2f P3PL");
        // A missile CAN collide with its own player.
        clear();
        cc(8'h11, 3'd0);                        // missile 0 and player 0
        chk(nib(m_pl, 0), 4'b0001, "T2g M0PL sees its own player");
        chk(nib(p_pl, 0), 4'b0000, "T2h a player does not record a missile");

        // ================================================================
        // T3: latches ACCUMULATE across the line
        // ================================================================
        clear();
        cc(8'h03, 3'd0);                        // P0 with P1 here...
        cc(8'h05, 3'd0);                        // ...and with P2 later
        chk(nib(p_pl, 0), 4'b0110, "T3 P0PL keeps both hits");
        // This is the shape of gtia_pmretrigger's assertion: a player that
        // moves mid-line collides with what it passed AND what it reaches.
        if (nib(p_pl, 0) !== 4'b0110) begin
            $display("FAIL T3b: a moved player lost its earlier collision"); fail++;
        end

        // ================================================================
        // T4: HITCLR clears everything
        // ================================================================
        cc(8'h0F, 3'd2);
        clear();
        if (m_pf !== 16'h0 || p_pf !== 16'h0 || m_pl !== 16'h0 || p_pl !== 16'h0) begin
            $display("FAIL T4: HITCLR left %04h %04h %04h %04h",
                     m_pf, p_pf, m_pl, p_pl);
            fail++;
        end

        // ================================================================
        // T5: nothing accumulates off an active display line
        // ================================================================
        clear();
        active = 1'b0;
        for (int i = 0; i < 20; i++) cc(8'hFF, 3'd2);
        if (m_pf !== 16'h0 || p_pf !== 16'h0 || m_pl !== 16'h0 || p_pl !== 16'h0) begin
            $display("FAIL T5: collisions accumulated in VBLANK: %04h %04h %04h %04h",
                     m_pf, p_pf, m_pl, p_pl);
            fail++;
        end
        active = 1'b1;
        cc(8'h03, 3'd2);
        chk(nib(p_pl, 0), 4'b0010, "T5b accumulation resumes on an active line");

        // ================================================================
        // T6: a lit hi-res pixel collides as PLAYFIELD 2 (antic_hiresbug)
        // ================================================================
        clear();
        cc(8'h01, 3'd5);                        // P0 over a lit hi-res pixel
        chk(nib(p_pf, 0), 4'b0100, "T6 hi-res lit collides as PF2");
        // ...and it is not PF1, which is where its luma comes from.
        if (nib(p_pf, 0) & 4'b0010) begin
            $display("FAIL T6b: hi-res collided as PF1 — that is only where its LUMA comes from");
            fail++;
        end

        // ================================================================
        // T7: an absent object records nothing
        // ================================================================
        clear();
        cc(8'h00, 3'd2);
        if (m_pf !== 16'h0 || p_pf !== 16'h0 || m_pl !== 16'h0 || p_pl !== 16'h0) begin
            $display("FAIL T7: an empty colour clock set a latch"); fail++;
        end

        // ================================================================
        // T8: all eight objects and every playfield, in one pass
        // ================================================================
        clear();
        cc(8'hFF, 3'd4);                        // everything over PF3
        for (int n = 0; n < 4; n++) begin
            chk(nib(p_pf, n), 4'b1000, "T8 PnPF");
            chk(nib(m_pf, n), 4'b1000, "T8b MnPF");
            chk(nib(m_pl, n), 4'b1111, "T8c MnPL sees all four players");
        end
        chk(nib(p_pl, 2), 4'b1011, "T8d P2PL is all but itself");

        // ================================================================
        // T9: the gate is LATCHED at the start of the walk, not sampled
        // through it.
        // ================================================================
        // Missile 3 is the eighth and last object visited.  gtia_stage folds
        // the horizontal collision window into `active`, so a walk that begins
        // on the last colour clock GTIA compares in sees the gate go false
        // underneath it — and before this was latched, the tail of the walk was
        // dropped in silence.  On hardware that read as M0PL/M1PL/M2PL = $0F
        // with M3PL = $00, which is ACID gtia_collision's "Missing P/M
        // collisions on right at $DD" exactly.
        clear();
        pres = 8'hFF; pf_src = 3'd4;
        @(negedge clk); start = 1'b1;
        @(negedge clk); start = 1'b0;
        @(negedge clk);                        // one object in...
        active = 1'b0;                         // ...and the window closes
        while (busy) @(negedge clk);
        @(negedge clk);
        active = 1'b1;
        for (int n = 0; n < 4; n++)
            chk(nib(m_pl, n), 4'b1111, $sformatf("T9 M%0dPL survived the gate dropping mid-walk", n));
        chk(nib(m_pf, 3), 4'b1000, "T9b M3PF — the LAST object of the walk");

        // ...and a walk that starts with the gate already closed still records
        // nothing, which is the property T5 pins.
        clear();
        active = 1'b0;
        cc(8'hFF, 3'd4);
        active = 1'b1;
        if (m_pl !== 16'h0 || p_pl !== 16'h0) begin
            $display("FAIL T9c: latched gate let a closed-window walk accumulate"); fail++;
        end

        if (fail == 0) $display("tb_gtia_collide: all checks PASS");
        else           $display("tb_gtia_collide: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
