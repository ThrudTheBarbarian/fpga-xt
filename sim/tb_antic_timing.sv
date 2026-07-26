// tb_antic_timing.sv — directed bench for the cycle-serial ANTIC timing
// machine (hdl/antic_timing.sv).  Every check is an Altirra/Avery cycle
// anchor from docs/a800/HANDOFF.md §0e-0h:
//
//   T1  the line counter advances entering cycle 111 (VCOUNT increment)
//   T2  WSYNC: write in cycle K -> /RDY still high in K+1 (delay slot),
//       low in K+2; release -> first ready cycle is 103
//   T3  VBI: NMIST bit6 entering (248,7); /NMI 2-cycle pulse when enabled;
//       NMIRES clears
//   T4  DL machine on the nmist probe list (70 70 70 F0 F0 41): DLI NMIST
//       at lines 39 and 47 cycle 7 (the ACID antic_nmist anchor); JVB parks
//   T5  vscroldli bracket on the real test's list (70 70 70 28 F0 70 28 F0
//       41): VS-exit rows are 1 line (raster 40 and 57); a VSCROL=1 write
//       at cycle 3 of the exit line SUPPRESSES that line's DLI (sampled at
//       6), a write at cycle 7 does NOT (fires) — the coincidence the old
//       parse/walk architecture could not express.

`default_nettype none
`timescale 1ns / 1ps

module tb_antic_timing;

    logic clk = 0;  always #5 clk = ~clk;
    logic rst = 1;

    // phi2 grid: 1 machine cycle = 4 clks (fast sim; grid ratio is irrelevant
    // to the machine, only the tick matters)
    logic [1:0] div = 0;
    wire phi2_tick = (div == 2'd3);
    always @(posedge clk) div <= div + 2'd1;

    logic        reg_we = 0;
    logic [3:0]  reg_addr = 0;
    logic [7:0]  reg_wdata = 0;

    wire        mem_req;
    wire [15:0] mem_addr;
    logic [7:0] mem [0:65535];
    logic [7:0] mem_rdata;
    always @(posedge clk) if (mem_req) mem_rdata <= mem[mem_addr];

    wire [7:0] vcount_w, nmist_w;
    wire       nmi_n_w, rdy_n_w;
    wire [2:0] ct_w;
    wire [6:0] hc_w;
    wire [8:0] line_w;
    wire [3:0] rowctr_w;
    wire [7:0] dlctl_w;
    wire [15:0] dlpc_w;

    antic_timing dut (
        .clk(clk), .rst(rst), .phi2_tick(phi2_tick), .cold(1'b0),
        .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_rdata(mem_rdata),
        .vcount(vcount_w), .nmist(nmist_w), .nmi_n(nmi_n_w),
        .rdy_n_q(rdy_n_w), .cycle_type(ct_w),
        .dbg_hcount(hc_w), .dbg_line(line_w), .dbg_rowctr(rowctr_w),
        .dbg_dlctl(dlctl_w), .dbg_dlpc(dlpc_w)
    );

    int nfail = 0;

    task automatic wr(input [3:0] a, input [7:0] d);
        @(negedge clk); reg_we = 1; reg_addr = a; reg_wdata = d;
        @(negedge clk); reg_we = 0;
    endtask

    // run to the START of (line, cycle): wait until the counters read it
    task automatic run_to(input [8:0] l, input [6:0] c);
        while (!(line_w == l && hc_w == c)) @(posedge clk);
    endtask

    // step N machine cycles
    task automatic mc(input int n);
        repeat (n) begin
            do @(posedge clk); while (!phi2_tick);
            @(posedge clk);
        end
    endtask

    initial begin
        // nmist probe DL at $2C00
        for (int i = 0; i < 65536; i++) mem[i] = 8'h00;
        mem['h2C00]='h70; mem['h2C01]='h70; mem['h2C02]='h70;
        mem['h2C03]='hF0; mem['h2C04]='hF0; mem['h2C05]='h41;
        mem['h2C06]='h00; mem['h2C07]='h2C;

        repeat (8) @(negedge clk); rst = 0;

        // ---------------- T1: line advance entering 111 ------------------
        run_to(9'd20, 7'd110);
        if (line_w !== 9'd20) begin $display("FAIL T1: line=%0d at 110", line_w); nfail++; end
        run_to(9'd21, 7'd0);   // implicit: 111..113 belong to line 21 already
        $display("  ok  T1: line advances entering cycle 111 (vcount=%0d)", vcount_w);

        // ---------------- T2: WSYNC delay slot + release 105 -------------
        run_to(9'd30, 7'd10);
        wr(4'hA, 8'h00);                    // write lands in cycle ~10-11
        begin
            logic [6:0] wc; wc = hc_w;      // cycle the write completed in
            // delay slot: /RDY still high through wc+1
            run_to(9'd30, wc + 7'd1);
            if (rdy_n_w !== 1'b1) begin $display("FAIL T2: no delay slot (rdy low at K+1)"); nfail++; end
            run_to(9'd30, wc + 7'd2);
            if (rdy_n_w !== 1'b0) begin $display("FAIL T2: not stalled at K+2"); nfail++; end
        end
        run_to(9'd30, 7'd104);
        if (rdy_n_w !== 1'b0) begin $display("FAIL T2: released early (ready during 104)"); nfail++; end
        run_to(9'd30, 7'd105);
        if (rdy_n_w !== 1'b1) begin $display("FAIL T2: /RDY not up entering 105"); nfail++; end
        $display("  ok  T2: WSYNC release -> /RDY up entering 105 (fid-effective resume 104)");

        // ---------------- T3: VBI NMIST at (248,6), pulse 8-9, NMIRES ----
        wr(4'hE, 8'h40);                    // NMIEN = VBI
        run_to(9'd248, 7'd6);
        if (nmist_w[6] !== 1'b0) begin $display("FAIL T3: VBI bit early"); nfail++; end
        run_to(9'd248, 7'd7);
        if (nmist_w[6] !== 1'b1) begin $display("FAIL T3: no VBI bit at (248,7)"); nfail++; end
        run_to(9'd248, 7'd8);
        if (nmi_n_w  !== 1'b0)  begin $display("FAIL T3: /NMI not low at 8"); nfail++; end
        run_to(9'd248, 7'd9);
        if (nmi_n_w  !== 1'b0)  begin $display("FAIL T3: /NMI not low at 9"); nfail++; end
        run_to(9'd248, 7'd10);
        if (nmi_n_w  !== 1'b1)  begin $display("FAIL T3: /NMI still low at 10"); nfail++; end
        wr(4'hF, 8'h00);                    // NMIRES
        mc(2);
        if (nmist_w[7:6] !== 2'b00) begin $display("FAIL T3: NMIRES did not clear"); nfail++; end
        $display("  ok  T3: VBI NMIST at (248,7), /NMI pulse 8-9, NMIRES clears");

        // ---------------- T4: DL DLIs on the nmist list ------------------
        wr(4'h2, 8'h00); wr(4'h3, 8'h2C);   // DLIST = $2C00
        wr(4'h0, 8'h20);                    // DL DMA on
        wr(4'hE, 8'h00);                    // no delivery; NMIST is the witness
        // next frame: blanks 8-31, F0 32-39 (DLI at 39), F0 40-47 (DLI 47)
        run_to(9'd39, 7'd4);
        wr(4'hF, 8'h00);                    // clear
        run_to(9'd39, 7'd7);
        if (nmist_w[7] !== 1'b1) begin $display("FAIL T4: no DLI at (39,7) nmist=%02h dlctl=%02h row=%0d", nmist_w, dlctl_w, rowctr_w); nfail++; end
        run_to(9'd47, 7'd4);
        wr(4'hF, 8'h00);
        run_to(9'd47, 7'd7);
        if (nmist_w[7] !== 1'b1) begin $display("FAIL T4: no DLI at (47,7)"); nfail++; end
        run_to(9'd60, 7'd0);
        wr(4'hF, 8'h00);
        run_to(9'd200, 7'd10);
        if (nmist_w[7] !== 1'b0) begin $display("FAIL T4: stray DLI after JVB park (nmist=%02h)", nmist_w); nfail++; end
        $display("  ok  T4: DLIs at (39,7)+(47,7), none after JVB park");

        // ---------------- T5: vscroldli bracket --------------------------
        // real test's DL: 3x blank8, VS mode8, exit F0, blank8, VS mode8, exit F0, JVB
        mem['h2C00]='h70; mem['h2C01]='h70; mem['h2C02]='h70;
        mem['h2C03]='h28; mem['h2C04]='hF0; mem['h2C05]='h70;
        mem['h2C06]='h28; mem['h2C07]='hF0; mem['h2C08]='h41;
        mem['h2C09]='h00; mem['h2C0A]='h2C;
        wr(4'h2, 8'h00); wr(4'h3, 8'h2C);   // mark dirty -> reload at restart
        wr(4'h5, 8'h00);                    // VSCROL = 0
        // wait for a fresh frame under the new list
        run_to(9'd0, 7'd0);
        // probe 1: write VSCROL=1 at (40,3) -> sampled at 6 -> DLI SUPPRESSED
        run_to(9'd40, 7'd3);
        wr(4'h5, 8'h01);
        run_to(9'd40, 7'd6);
        wr(4'hF, 8'h00);
        run_to(9'd40, 7'd8);
        if (nmist_w[7] !== 1'b0) begin $display("FAIL T5a: DLI fired despite cycle-3 write (nmist=%02h row=%0d)", nmist_w, rowctr_w); nfail++; end
        wr(4'h5, 8'h00);                    // restore
        // probe 2: write VSCROL=1 at (57,7) -> AFTER the sample -> DLI fires
        run_to(9'd57, 7'd5);
        wr(4'hF, 8'h00);
        run_to(9'd57, 7'd7);
        wr(4'h5, 8'h01);                    // lands during/after 7 — too late
        run_to(9'd57, 7'd9);
        if (nmist_w[7] !== 1'b1) begin $display("FAIL T5b: DLI missing despite late write (nmist=%02h row=%0d dlctl=%02h)", nmist_w, rowctr_w, dlctl_w); nfail++; end
        wr(4'h5, 8'h00);
        $display("  ok  T5: vscroldli bracket — cycle-3 write suppresses, cycle-7 write doesn't");

        // ---------------- T6: single-cycle VCOUNT rollover ---------------
        // Avery's "nasty one": VCOUNT reads 131 for exactly one cycle at
        // the end of line 261 (NTSC) before resetting to 0.
        // NOTE ON COORDINATES: a line BEGINS at its cycle 111 (the counter
        // advances there), so "line 261, cycle 110" is late in that line and
        // the rollover tick is where line becomes 262.
        run_to(9'd261, 7'd110);
        if (vcount_w !== 8'd130) begin $display("FAIL T6: vcount=%0d at (261,110), want 130", vcount_w); nfail++; end
        run_to(9'd262, 7'd111);
        if (vcount_w !== 8'd131) begin $display("FAIL T6: vcount=%0d at the rollover tick, want 131 (single-cycle)", vcount_w); nfail++; end
        run_to(9'd0, 7'd112);
        if (vcount_w !== 8'd0)   begin $display("FAIL T6: vcount=%0d at 112, want 0", vcount_w); nfail++; end
        $display("  ok  T6: VCOUNT single-cycle rollover (130 -> 131 for one cycle -> 0)");

        // ---------------- T7: VS state survives the VBI ------------------
        // ACID antic_vscroll #5: a list whose VS mode line straddles the
        // vertical blank.  After the frame restart the "previous line" the
        // next VS-exit compares against must still be that straddling line
        // (Altirra mDLControl = mDLControlPrev), not a cleared slate.
        wr(4'h0, 8'h00);                    // DL DMA off: freeze the machine
        force dut.dl_ctl_prev = 8'hA2;      // mode 2 + VS + DLI, as dlist3's
        wr(4'h0, 8'h22);                    // DL DMA on -> restart at line 8
        run_to(9'd8, 7'd4);
        release dut.dl_ctl_prev;
        if (dut.vs_prev !== 1'b1) begin
            $display("FAIL T7: vs_prev=%b after restart, want 1 (VS straddle lost)", dut.vs_prev);
            nfail++;
        end else $display("  ok  T7: VS state carried across the VBI restart");

        // ---------------- T8: DL DMA stops for the vertical blank --------
        // Real ANTIC fetches the display list only between the first
        // display line and the VBI; a list still running at line 248 is
        // suspended and resumes next frame (ACID antic_vscroll #5).
        wr(4'h2, 8'h00); wr(4'h3, 8'h2C); wr(4'h0, 8'h22);
        // (line 20 = still walking the list; by 200 it has parked on its JVB)
        run_to(9'd20, 7'd20);
        if (dut.dl_active !== 1'b1) begin $display("FAIL T8: DL inactive mid-frame"); nfail++; end
        run_to(9'd250, 7'd20);
        if (dut.dl_active !== 1'b0) begin $display("FAIL T8: DL still active during VBI"); nfail++; end
        run_to(9'd20, 7'd20);
        if (dut.dl_active !== 1'b1) begin $display("FAIL T8: DL did not resume after the VBI"); nfail++; end
        $display("  ok  T8: DL DMA suspended across the vertical blank");

        if (nfail == 0) $display("*** ANTIC_TIMING OK ***");
        else            $display("*** ANTIC_TIMING FAIL *** %0d failure(s)", nfail);
        $finish;
    end

    initial begin #80_000_000; $display("*** ANTIC_TIMING TIMEOUT ***"); $finish; end

endmodule

`default_nettype wire
