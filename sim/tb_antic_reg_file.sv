`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_reg_file — ANTIC's registers, $D400-$D40F.
//
// T5-T8 are the WSYNC behaviours, and they are the hard-won ones:
//
//   T5  /RDY trails the latch by ONE MACHINE CYCLE. Avery Lee's capture of a
//       real XE: a write in cycle N leaves /RDY high through N and stalls from
//       N+1. A combinational /RDY has no delay slot and parks the CPU a
//       position early.
//   T6  the delay is on BOTH edges, so the release trails too.
//   T7  a read-modify-write writes $D40A twice; the latch is level state, so
//       the second write changes nothing and the stall is timed from the first.
//   T8  CLEAR BEATS SET — a write coinciding with the release must not start a
//       fresh line-long stall (antic_wsync's "Late INC WSYNC").
//
module tb_antic_reg_file;

    localparam int CYC = 114;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       tick;
    logic [6:0] hcount;
    logic [7:0] addr, wdata;
    logic       we;
    logic [7:0] vcount, nmist;

    wire [7:0] rdata;
    wire [7:0] dmactl, chactl, hscrol, vscrol, pmbase, chbase, nmien;
    wire       dlist_we_l, dlist_we_h, nmires, rdy_n;
    wire [7:0] dlist_wdata;

    antic_reg_file dut (
        .wsync_rel(7'd104),
        .clk(clk), .rst(rst), .tick(tick), .hcount(hcount),
        .addr(addr), .we(we), .wdata(wdata), .rdata(rdata),
        .vcount(vcount), .nmist(nmist),
        .dmactl(dmactl), .chactl(chactl), .hscrol(hscrol), .vscrol(vscrol),
        .pmbase(pmbase), .chbase(chbase), .nmien(nmien),
        .dlist_we_l(dlist_we_l), .dlist_we_h(dlist_we_h),
        .dlist_wdata(dlist_wdata), .nmires(nmires), .rdy_n(rdy_n)
    );

    int fail = 0;
    int dl_l_count, dl_h_count;

    always @(posedge clk) if (!rst) begin
        if (dlist_we_l) dl_l_count++;
        if (dlist_we_h) dl_h_count++;
    end

    task automatic step;
        begin
            @(negedge clk); tick = 1'b1;
            @(negedge clk); tick = 1'b0;
                            hcount = (hcount == 7'(CYC-1)) ? 7'd0 : hcount + 7'd1;
        end
    endtask

    task automatic wr(input [7:0] a, input [7:0] d);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1'b1;
            @(negedge clk); we = 1'b0;
        end
    endtask

    // A write held across several clocks, as a stalled bus cycle would be.
    task automatic wr_held(input [7:0] a, input [7:0] d, input int clocks);
        begin
            @(negedge clk); addr = a; wdata = d; we = 1'b1;
            repeat (clocks) @(negedge clk);
            we = 1'b0;
        end
    endtask

    task automatic rd(input [7:0] a, output [7:0] v);
        begin
            @(negedge clk); addr = a; #1; v = rdata;
        end
    endtask

    logic [7:0] v;

    initial begin
        tick = 0; hcount = 0; addr = 0; wdata = 0; we = 0;
        vcount = 8'h5A; nmist = 8'h9F;
        dl_l_count = 0; dl_h_count = 0;

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- T1: the writable registers -----------------------------------
        wr(8'h00, 8'h22); wr(8'h01, 8'h02); wr(8'h04, 8'h07);
        wr(8'h05, 8'h03); wr(8'h07, 8'h70); wr(8'h09, 8'hE0);
        wr(8'h0E, 8'hC0);
        @(negedge clk);
        if (dmactl !== 8'h22) begin $display("FAIL T1 DMACTL $%02h", dmactl); fail++; end
        if (chactl !== 8'h02) begin $display("FAIL T1b CHACTL $%02h", chactl); fail++; end
        if (hscrol !== 8'h07) begin $display("FAIL T1c HSCROL $%02h", hscrol); fail++; end
        if (vscrol !== 8'h03) begin $display("FAIL T1d VSCROL $%02h", vscrol); fail++; end
        if (pmbase !== 8'h70) begin $display("FAIL T1e PMBASE $%02h", pmbase); fail++; end
        if (chbase !== 8'hE0) begin $display("FAIL T1f CHBASE $%02h", chbase); fail++; end
        if (nmien  !== 8'hC0) begin $display("FAIL T1g NMIEN $%02h", nmien); fail++; end

        // ---- T2: only VCOUNT and NMIST read anything ----------------------
        rd(8'h0B, v);
        if (v !== 8'h5A) begin $display("FAIL T2: VCOUNT read $%02h", v); fail++; end
        rd(8'h0F, v);
        if (v !== 8'h9F) begin $display("FAIL T2b: NMIST read $%02h", v); fail++; end
        for (int i = 0; i < 16; i++) begin
            if (i == 11 || i == 15) continue;
            rd(8'(i), v);
            if (v !== 8'hFF) begin
                $display("FAIL T2c: $D40%01h read $%02h, expected $FF (write-only)", i, v);
                fail++;
            end
        end

        // ---- T3: sixteen addresses, mirrored sixteen times ----------------
        // antic_addrmirror: ANTIC decodes four bits and nothing above them.
        wr(8'hF0, 8'h11);               // $D4F0 is DMACTL
        @(negedge clk);
        if (dmactl !== 8'h11) begin
            $display("FAIL T3: a write to $D4F0 did not reach DMACTL (got $%02h)", dmactl);
            fail++;
        end
        rd(8'h8B, v);                   // $D48B is VCOUNT
        if (v !== 8'h5A) begin
            $display("FAIL T3b: $D48B read $%02h, expected VCOUNT", v); fail++;
        end

        // ---- T4: the display list pointer is forwarded, not held -----------
        dl_l_count = 0; dl_h_count = 0;
        wr(8'h02, 8'h34);
        @(negedge clk);
        if (dl_l_count != 1 || dlist_wdata !== 8'h34) begin
            $display("FAIL T4: DLISTL write not forwarded (count %0d data $%02h)",
                     dl_l_count, dlist_wdata);
            fail++;
        end
        wr(8'h03, 8'h12);
        @(negedge clk);
        if (dl_h_count != 1) begin
            $display("FAIL T4b: DLISTH write not forwarded"); fail++;
        end
        rd(8'h02, v);
        if (v !== 8'hFF) begin
            $display("FAIL T4c: DLISTL read $%02h — ANTIC never drives it", v); fail++;
        end

        // ---- T5: /RDY trails the latch by one machine cycle ---------------
        // The write lands in cycle N; /RDY is still high through N and the CPU
        // stalls from N+1.  That gap is the delay slot an RMW needs.
        hcount = 7'd20;
        wr(8'h0A, 8'h00);               // the write, inside cycle 20
        if (rdy_n) begin
            $display("FAIL T5: /RDY went low in the same cycle as the write — there is no delay slot");
            fail++;
        end
        step();                          // finish cycle 20, enter 21
        if (!rdy_n) begin
            $display("FAIL T5b: /RDY did not go low one cycle after the write");
            fail++;
        end

        // ---- T6: the delay is on BOTH edges -------------------------------
        // Delaying only the assert breaks the straddle-the-release case.
        while (hcount != 7'd104) step();
        if (!rdy_n) begin
            $display("FAIL T6: /RDY came back before the release cycle"); fail++;
        end
        step();                          // cycle 104: the latch clears...
        if (!rdy_n) begin
            $display("FAIL T6b: /RDY came back in the release cycle itself — the release is delayed too");
            fail++;
        end
        step();                          // ...and /RDY follows one cycle later
        if (rdy_n) begin
            $display("FAIL T6c: /RDY did not come back one cycle after the release");
            fail++;
        end

        // ---- T7: an RMW's second write changes nothing --------------------
        // The latch is level state, so the stall is timed from the FIRST write
        // and the RMW's extra machine cycle is the delay slot it needs.
        hcount = 7'd20;
        wr(8'h0A, 8'h00);               // the RMW's first write
        step();
        wr(8'h0A, 8'h00);               // ...and its second
        if (!rdy_n) begin
            $display("FAIL T7: not stalled after an RMW WSYNC"); fail++;
        end
        while (hcount != 7'd104) step();
        step(); step();
        if (rdy_n) begin
            $display("FAIL T7b: the RMW's second write extended the stall past the release");
            fail++;
        end

        // ---- T8: CLEAR BEATS SET ------------------------------------------
        // A write landing on the release cycle must not park the CPU for a
        // whole fresh scanline.
        while (hcount != 7'd104) step();
        wr(8'h0A, 8'h00);               // straddles the release
        step(); step(); step();
        if (rdy_n) begin
            $display("FAIL T8: a write on the release cycle started a new line-long stall");
            fail++;
        end

        // ---- T8b: a held write still only sets a level --------------------
        // Held as an edge-triggered strobe this is harmless; held as a level
        // that re-arms, the machine would never restart.
        hcount = 7'd20;
        wr_held(8'h0A, 8'h00, 12);
        while (hcount != 7'd104) step();
        step(); step();
        if (rdy_n) begin
            $display("FAIL T8b: /RDY never came back after a long held write");
            fail++;
        end

        // ---- T8: NMIRES is a one-clock strobe ------------------------------
        begin
            int n;
            n = 0;
            @(negedge clk); addr = 8'h0F; wdata = 8'h00; we = 1'b1;
            for (int i = 0; i < 6; i++) begin
                @(posedge clk); if (nmires) n++;
            end
            @(negedge clk); we = 1'b0;
            if (n != 1) begin
                $display("FAIL T8: a held NMIRES write pulsed %0d times, expected 1", n);
                fail++;
            end
        end

        if (fail == 0) $display("tb_antic_reg_file: all checks PASS");
        else           $display("tb_antic_reg_file: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
