// tb_antic_dli.sv — DLI fires on the correct PHYSICAL scanline, integrated.
//
// Reproduces (in sim, on the REAL antic_top path) the ACID800 antic_nmist /
// antic_dlitiming failure class: a display list whose DLI bits sit on BLANK
// lines behind a block of leading-overscan blanks.  dl_parser skips the
// leading overscan and used to record DLIs in that COMPRESSED row space, but
// nmi_gen looks them up with the LIVE raster row (antic_raster's ar_atari_row =
// scanline - DISPLAY_TOP).  The two spaces diverge by the skipped-blank count,
// so on real hardware the DLI fired at the wrong scanline — or not at all —
// even though the unit sims (tb_nmi / tb_dl_parse, which drive the compressed
// row directly) passed.  This test drives the whole chain
//   bram -> dl_parser -> antic_raster -> nmi_gen -> /NMI
// and asserts the DLI /NMI asserts at the physically-correct raster rows.
//
// Display list (mirrors antic_nmist):
//   $1000: 70 70 70    3x blank-8   -> scanlines 8..31   (ar 0..23, overscan)
//   $1003: F0          blank-8 +DLI -> scanlines 32..39  (ar 24..31, DLI @ 39)
//   $1004: F0          blank-8 +DLI -> scanlines 40..47  (ar 32..39, DLI @ 47)
//   $1005: 41 00 10    JVB $1000
// DISPLAY_TOP = 8, so DLI on the LAST scanline of each $F0 lands at
//   ar_atari_row 31 (scanline 39) and 39 (scanline 47).
// The OLD compressed behaviour would have fired near ar 8 / lost the 2nd DLI.

`default_nettype none
`timescale 1ns / 1ps

module tb_antic_dli;

    localparam logic [15:0] DL_BASE = 16'h1000;
    localparam int EXP_DLI_ROW_A = 31;    // scanline 39
    localparam int EXP_DLI_ROW_B = 39;    // scanline 47

    logic clk_bus = 1'b0;  always #23.256 clk_bus = ~clk_bus;

    logic        rst_n       = 1'b0;
    logic [15:0] bus_addr    = 16'h0000;
    logic [7:0]  bus_data_in = 8'h00;
    logic        bus_rw      = 1'b1;
    logic        d0xx_n      = 1'b1;
    logic        d4xx_n      = 1'b1;

    wire [7:0]  bus_data_out;
    wire        bus_data_oe;
    wire        nmi_n, halt_n, rdy_n;
    wire [31:0] diag_wsync_overdue_count;

    // ANTIC memory (bram port) — 1-cycle registered read.
    logic [7:0]  amem [0:65535];
    wire [15:0]  bram_addr;
    logic [7:0]  bram_rdata_r;
    always_ff @(posedge clk_bus) bram_rdata_r <= amem[bram_addr];

    wire        wb_pix_valid, wb_row_flush, wb_frame_done;
    wire [7:0]  wb_pix_pair, wb_color_lo, wb_color_hi, wb_atari_row;

    antic_top u_dut (
        .clk_bus(clk_bus), .rst_n(rst_n),
        .joy_ovr(32'd0),
        .bus_addr(bus_addr), .bus_data_in(bus_data_in), .bus_rw(bus_rw),
        .d0xx_n(d0xx_n), .d4xx_n(d4xx_n),
        .bus_data_out(bus_data_out), .bus_data_oe(bus_data_oe),
        .nmi_n(nmi_n), .halt_n(halt_n), .rdy_n(rdy_n),
        .spi_miso(1'b1), .spi_irq(1'b1),
        .joy_spi_miso(1'b1), .joy_spi_int_n(1'b1),
        .adc_sdata_i(1'b0),
        .bus_mpd_n_in(1'b1), .bus_extirq_n_in(1'b1), .bus_rd4_in(1'b1), .bus_rd5_in(1'b1),
        .unlock_antic(1'b1), .unlock_sprite(1'b1), .unlock_blit(1'b1),
        .kbd_event_valid(1'b0), .kbd_event_code(8'h00),
        .bram_addr(bram_addr), .bram_rdata(bram_rdata_r),
        .wb_pix_valid(wb_pix_valid), .wb_pix_pair(wb_pix_pair),
        .wb_color_lo(wb_color_lo), .wb_color_hi(wb_color_hi),
        .wb_atari_row(wb_atari_row), .wb_row_flush(wb_row_flush),
        .wb_frame_done(wb_frame_done),
        .diag_wsync_overdue_count(diag_wsync_overdue_count)
    );

    task automatic wr_d4xx(input logic [7:0] a, input logic [7:0] d);
        @(negedge clk_bus); bus_addr = {8'hD4, a}; bus_data_in = d; bus_rw = 1'b0; d4xx_n = 1'b0;
        @(posedge clk_bus);
        @(negedge clk_bus); bus_rw = 1'b1; d4xx_n = 1'b1; bus_addr = 16'h0;
    endtask

    // ---- Scoreboard: watch the DLI/VBI /NMI assertions inside nmi_gen ----
    // phase 1 = blank-line DLIs (physical timing);  phase 2 = a mode-line DLI
    // behind 24 leading blanks (must stay compressed / content-aligned).
    int  fail = 0;
    int  phase = 1;
    int  dli_hits = 0, vbi_hits = 0;
    bit  seen_row_a = 0, seen_row_b = 0;
    bit  seen_wrong_dli = 0;
    int  wrong_row = -1;
    // phase 2 trackers
    int  dli_hits2 = 0;
    bit  seen_mode_row = 0;         // DLI at compressed ar 1 (content-aligned)
    bit  seen_shifted_dli = 0;      // DLI at physical ar 24+ (the game regression)
    int  shifted_row = -1;
    localparam int EXP_MODE_DLI_ROW = 1;   // compressed row 1 (scanline 9)

    always_ff @(posedge clk_bus) begin
        if (rst_n) begin
            // dli_nmi / vbi_nmi are the gated /NMI-assert strobes (cycle-8).
            if (u_dut.u_nmi_gen.dli_nmi) begin
                if (phase == 1) begin
                    dli_hits++;
                    if      (u_dut.ar_atari_row == EXP_DLI_ROW_A[7:0]) seen_row_a = 1;
                    else if (u_dut.ar_atari_row == EXP_DLI_ROW_B[7:0]) seen_row_b = 1;
                    else begin seen_wrong_dli = 1; wrong_row = u_dut.ar_atari_row; end
                end else begin
                    dli_hits2++;
                    if (u_dut.ar_atari_row == EXP_MODE_DLI_ROW[7:0]) seen_mode_row = 1;
                    else if (u_dut.ar_atari_row >= 8'd24 && u_dut.ar_atari_row != 8'hFF)
                        begin seen_shifted_dli = 1; shifted_row = u_dut.ar_atari_row; end
                end
            end
            if (u_dut.u_nmi_gen.vbi_nmi) vbi_hits++;
        end
    end

    initial begin
        $display("=== ANTIC_DLI (physical-scanline DLI) TEST ===");
        for (int i = 0; i < 65536; i++) amem[i] = 8'h00;

        // DL #1 @ $1000: 3x blank-8 (overscan), 2x blank-8+DLI, JVB.
        amem[DL_BASE+0] = 8'h70;
        amem[DL_BASE+1] = 8'h70;
        amem[DL_BASE+2] = 8'h70;
        amem[DL_BASE+3] = 8'hF0;                 // blank-8 + DLI  -> DLI @ ar 31
        amem[DL_BASE+4] = 8'hF0;                 // blank-8 + DLI  -> DLI @ ar 39
        amem[DL_BASE+5] = 8'h41;
        amem[DL_BASE+6] = DL_BASE[7:0];
        amem[DL_BASE+7] = DL_BASE[15:8];

        // DL #2 @ $1100: 3x blank-8 (overscan, skipped) then a mode-F line with
        // a DLI, then plain mode-F rows, JVB.  Real games hang DLIs on visible
        // mode lines; despite the 24 skipped leading blanks the DLI must fire at
        // the COMPRESSED content row (ar 1), not physical ar 24+ — else colour
        // bands land ~24 rows low.
        amem[16'h1100] = 8'h70;
        amem[16'h1101] = 8'h70;
        amem[16'h1102] = 8'h70;
        amem[16'h1103] = 8'h8F;                  // mode-F + DLI  -> fires @ compressed ar 1
        amem[16'h1104] = 8'h0F;                  // mode-F
        amem[16'h1105] = 8'h0F;                  // mode-F
        amem[16'h1106] = 8'h41;
        amem[16'h1107] = 8'h00;
        amem[16'h1108] = 8'h11;

        repeat (8) @(posedge clk_bus);
        rst_n = 1'b1;
        repeat (4) @(posedge clk_bus);

        wr_d4xx(8'h02, DL_BASE[7:0]);            // DLISTL
        wr_d4xx(8'h03, DL_BASE[15:8]);           // DLISTH
        wr_d4xx(8'h00, 8'h22);                   // DMACTL: normal playfield + DL DMA
        wr_d4xx(8'h0E, 8'hC0);                   // NMIEN: DLI + VBI

        // ---- Phase 1: blank-line DLIs fire at physical scanlines ----
        // Run ~3 frames: frame 0 parses, frames 1+ raise DLIs/VBIs.
        repeat (3_100_000) @(posedge clk_bus);

        if (dli_hits == 0) begin
            $display("FAIL[p1]: no DLI /NMI ever asserted (DLIs on skipped blank lines lost)");
            fail++;
        end
        if (!seen_row_a) begin
            $display("FAIL[p1]: DLI never fired at ar_atari_row %0d (scanline 39)", EXP_DLI_ROW_A);
            fail++;
        end
        if (!seen_row_b) begin
            $display("FAIL[p1]: DLI never fired at ar_atari_row %0d (scanline 47)", EXP_DLI_ROW_B);
            fail++;
        end
        if (seen_wrong_dli) begin
            $display("FAIL[p1]: DLI fired at WRONG raster row %0d (compressed-space bug)", wrong_row);
            fail++;
        end
        if (vbi_hits == 0) begin
            $display("FAIL[p1]: no VBI /NMI asserted");
            fail++;
        end

        // ---- Phase 2: mode-line DLI stays content-aligned (no game regression) ----
        @(negedge clk_bus); phase = 2;
        wr_d4xx(8'h02, 8'h00);                   // DLISTL -> $1100
        wr_d4xx(8'h03, 8'h11);                   // DLISTH
        repeat (3_100_000) @(posedge clk_bus);

        if (dli_hits2 == 0) begin
            $display("FAIL[p2]: mode-line DLI never fired");
            fail++;
        end
        if (!seen_mode_row) begin
            $display("FAIL[p2]: mode-line DLI never fired at compressed ar %0d", EXP_MODE_DLI_ROW);
            fail++;
        end
        if (seen_shifted_dli) begin
            $display("FAIL[p2]: mode-line DLI shifted to physical ar %0d (game color-band regression)",
                     shifted_row);
            fail++;
        end

        if (fail == 0) begin
            $display("*** ANTIC_DLI OK *** p1 blank DLIs @ ar 31/39 (%0d), p2 mode DLI @ ar 1 (%0d), %0d VBI",
                     dli_hits, dli_hits2, vbi_hits);
            $finish;
        end else begin
            $display("*** ANTIC_DLI FAIL *** %0d failures (p1 dli=%0d p2 dli=%0d vbi=%0d)",
                     fail, dli_hits, dli_hits2, vbi_hits);
            $fatal(1);
        end
    end

    initial begin
        #800_000_000;
        $display("FAIL: tb_antic_dli watchdog"); $fatal(1);
    end

endmodule

`default_nettype wire
