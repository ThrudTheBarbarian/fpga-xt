`timescale 1ns/1ps
`default_nettype none
//
// tb_antic_dma_sched — the DMA schedule against ACID's own expected maps.
//
// antic_dmapattern carries its expected DMA patterns as bit masks at $3800.
// antic_dma_maps.mem is those masks, decoded straight out of the test binary,
// one 114-bit scanline per line; antic_dma_cfg.mem is the mode, width and
// first/later-row flag for each. So this is not a testbench asserting what I
// think ANTIC does — it is the hardware's own answer, 50 scanlines of it.
//
// It also derives bytes_per_line and the window from antic_mode_tbl and
// antic_pf_geom rather than from a private table, so a disagreement between
// those modules and the maps shows up here too.
//
// The pass condition is all 50, exactly — every display mode, both playfield
// widths, first and later scanlines. Any mismatch prints the expected and
// actual scanline side by side.
//
module tb_antic_dma_sched;

    localparam int NREC = 50;
    localparam int CYC  = 114;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic       line_start, tick;
    logic [6:0] hcount;
    logic       first_row, lms;
    logic [3:0] mode;
    logic [1:0] pf_width;

    // ---- the mode's shape, from the real modules ------------------------
    wire       is_char, descender_u, is_display;
    wire [1:0] bpp;
    wire [3:0] px_width;
    wire [4:0] rows_u;

    antic_mode_tbl u_tbl (
        .mode(mode), .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .rows(rows_u), .descender(descender_u), .is_display(is_display)
    );

    wire       pf_on;
    wire [7:0] bytes_per_line, pf_step;
    wire [6:0] dma_start, dma_stop, disp_start, disp_stop;
    wire [8:0] px_start, px_stop;
    wire [2:0] hs_delay;
    wire       hs_fine;

    antic_pf_geom u_geom (
        .pf_width(pf_width), .hscrol_en(1'b0), .hscrol(4'd0),
        .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .pf_on(pf_on), .bytes_per_line(bytes_per_line), .pf_step(pf_step),
        .dma_start(dma_start), .dma_stop(dma_stop),
        .disp_start(disp_start), .disp_stop(disp_stop),
        .px_start(px_start), .px_stop(px_stop),
        .hs_delay(hs_delay), .hs_fine(hs_fine)
    );

    wire [7:0] span = (pf_width == 2'd1) ? 8'd64 :
                      (pf_width == 2'd2) ? 8'd80 : 8'd96;

    wire steal;
    wire pf_fetch, pf_fetch_glyph;

    // The 50 maps all run the window the geometry computes.  Abnormal DMA
    // needs the two edges on DIFFERENT PHASES, which consistent geometry can
    // never produce -- so the run-on case drives them by hand.
    logic       ovr_en = 1'b0;
    logic [6:0] ovr_start, ovr_stop;
    wire  [6:0] sch_start = ovr_en ? ovr_start : dma_start;
    wire  [6:0] sch_stop  = ovr_en ? ovr_stop  : dma_stop;

    antic_dma_sched dut (
        .clk(clk), .rst(rst), .line_start(line_start), .tick(tick),
        .hcount(hcount), .first_row(first_row), .is_char(is_char),
        .is_display(is_display), .bytes_per_line(bytes_per_line),
        .dma_start(sch_start), .dma_stop(sch_stop), .step(pf_step), .lms(1'b1),
        .dl_dma_en(1'b1), .missile_dma_en(1'b0), .player_dma_en(1'b0),
        .steal(steal), .pf_fetch(pf_fetch), .pf_fetch_glyph(pf_fetch_glyph)
    );

    // Cycles from PF_HBLANK_FIRST (106) on still FETCH but steal nothing, so
    // `steal` cannot see a run-on at all.  This can.
    int hblank_fetches;

    // ---- the oracle -------------------------------------------------------
    logic [CYC-1:0] omap [0:NREC-1];
    logic [11:0]    ocfg [0:NREC-1];

    logic [CYC-1:0] got;

    int fail = 0;
    int r;

    task automatic run_line;
        begin
            @(negedge clk); line_start = 1'b1; hcount = 7'd0;
            @(negedge clk); line_start = 1'b0;
            got = '0;
            hblank_fetches = 0;
            for (int c = 0; c < CYC; c++) begin
                hcount = 7'(c);
                @(negedge clk); tick = 1'b1;
                #1;
                // The map is written cycle 0 first, so bit CYC-1 is cycle 0.
                if (steal) got[CYC-1-c] = 1'b1;
                if (pf_fetch && c >= 106) hblank_fetches++;
                @(negedge clk); tick = 1'b0;
            end
        end
    endtask

    initial begin
        line_start = 0; tick = 0; hcount = 0;
        first_row = 0; lms = 1; mode = 4'h2; pf_width = 2'd2;

        $readmemb("antic_dma_maps.mem", omap);
        $readmemh("antic_dma_cfg.mem",  ocfg);

        repeat (3) @(posedge clk);
        rst = 0;
        @(posedge clk);

        for (r = 0; r < NREC; r++) begin
            mode      = ocfg[r][11:8];
            pf_width  = ocfg[r][7:4] == 4'd1 ? 2'd1 : 2'd2;
            first_row = (ocfg[r][3:0] != 4'd0);
            @(negedge clk);
            run_line();

            if (got !== omap[r]) begin
                fail++;
                $display("FAIL rec %0d (mode %0h width %0d %s):",
                         r, ocfg[r][11:8], ocfg[r][7:4],
                         first_row ? "first row" : "later row");
                $display("      want %029h", omap[r]);
                $display("      got  %029h", got);
            end
        end

        // ================================================================
        // ABNORMAL DMA: a stop on the wrong phase does not stop anything
        // ================================================================
        // ANTIC does not walk a window.  It has an eight-bit clock with a bit
        // flying round it: the window's start injects a bit at the start's
        // phase and the stop clears one at the stop's phase.  When HSCROL
        // moves the stop off the phase the start injected, the clear removes
        // nothing, the bit keeps flying, and the playfield goes on fetching
        // through horizontal blank and into the next scanline.  That is the
        // whole of antic_hscrolbug: seventeen extra fetches, and the next
        // line's display shifted left by seventeen bytes.
        //
        // Mode E is rate 3 -- one fetch every two cycles -- so its clock mask
        // is 0x55 on an even phase and 0xAA on an odd one.  Start 20 injects
        // 0x55; a stop at 101 asks to clear 0xAA and clears nothing at all.
        //
        // `steal` cannot see this: cycles from 106 on fetch but steal nothing.
        // hblank_fetches counts pf_fetch instead.
        mode = 4'hE; pf_width = 2'd1; first_row = 1'b1;
        ovr_en = 1'b1; ovr_start = 7'd20; ovr_stop = 7'd101;
        @(negedge clk);
        run_line();
        if (hblank_fetches == 0) begin
            $display("FAIL abnormal: stop 101 against start 20 stopped the fetch anyway -- no fetches past cycle 106");
            fail++;
        end

        // ...and the matching case that MUST still stop: same start, a stop on
        // the SAME phase.  Without this the test above would pass on a module
        // that simply never stops.
        ovr_start = 7'd20; ovr_stop = 7'd100;
        @(negedge clk);
        run_line();
        if (hblank_fetches != 0) begin
            $display("FAIL abnormal-b: stop 100 against start 20 is the same phase and must clear, but %0d fetches ran past 106",
                     hblank_fetches);
            fail++;
        end
        ovr_en = 1'b0;

        if (fail == 0)
            $display("tb_antic_dma_sched: all checks PASS (%0d of %0d ACID DMA maps reproduced exactly, plus abnormal DMA)",
                     NREC, NREC);
        else
            $display("tb_antic_dma_sched: %0d FAIL", fail);
        $finish;
    end

    initial begin
        #4000000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
