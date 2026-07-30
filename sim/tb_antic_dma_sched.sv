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
    wire [7:0] bytes_per_line;
    wire [6:0] dma_start, dma_stop, disp_start, disp_stop;
    wire [8:0] px_start, px_stop;
    wire [2:0] hs_delay;
    wire       hs_fine;

    antic_pf_geom u_geom (
        .pf_width(pf_width), .hscrol_en(1'b0), .hscrol(4'd0),
        .is_char(is_char), .bpp(bpp), .px_width(px_width),
        .pf_on(pf_on), .bytes_per_line(bytes_per_line),
        .dma_start(dma_start), .dma_stop(dma_stop),
        .disp_start(disp_start), .disp_stop(disp_stop),
        .px_start(px_start), .px_stop(px_stop),
        .hs_delay(hs_delay), .hs_fine(hs_fine)
    );

    wire [7:0] span = (pf_width == 2'd1) ? 8'd64 :
                      (pf_width == 2'd2) ? 8'd80 : 8'd96;

    wire steal;

    antic_dma_sched dut (
        .clk(clk), .rst(rst), .line_start(line_start), .tick(tick),
        .hcount(hcount), .first_row(first_row), .is_char(is_char),
        .is_display(is_display), .bytes_per_line(bytes_per_line),
        .dma_start(dma_start), .span(span), .lms(1'b1),
        .dl_dma_en(1'b1), .missile_dma_en(1'b0), .player_dma_en(1'b0),
        .steal(steal)
    );

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
            for (int c = 0; c < CYC; c++) begin
                hcount = 7'(c);
                @(negedge clk); tick = 1'b1;
                #1;
                // The map is written cycle 0 first, so bit CYC-1 is cycle 0.
                if (steal) got[CYC-1-c] = 1'b1;
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

        if (fail == 0)
            $display("tb_antic_dma_sched: all checks PASS (%0d of %0d ACID DMA maps reproduced exactly)",
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
