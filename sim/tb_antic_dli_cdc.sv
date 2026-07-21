// tb_antic_dli_cdc.sv — reproduce (or refute) the HW-proven DLI coincidence
// failure by driving NMIEN through the SAME clk_sally -> CDC-FIFO -> clk_sys
// register-write path the real fpga_xt_top uses, instead of the snoop bus.
//
// The existing tb_antic_dli / tb_nmi PASS because they drive antic_top's bus
// (bus_addr/bus_data_in/bus_rw/d4xx_n) directly, in the SAME clock domain as
// the raster.  On HW the NMIEN ($D40E) write travels:
//   fid-core (clk_sally)
//     -> sally_mem hwreg_we/hwreg_addr/hwreg_din
//       -> cdc_fifo_1w1r  (4-deep async, clk_sally -> clk_sys)
//         -> antic_we_q / bus_addr_antic_q / bus_data_in_antic_q  (clk_sys)
//           -> antic_top bus_addr/bus_data_in/bus_rw/d4xx_n -> bus_snoop -> nmien_q
//
// HW evidence (GP0 diag, ACID800 antic_nmist):
//   nmien_or[7]=1        (bit7 DID reach nmien_q at some time)
//   dli_event_count=48   (DLI events DO fire on their lines)
//   dli_nmi_count=0      (but never gated through: nmien[7] low at every DLI)
//   nmien_dli_coincide=0 (nmien_q[7] never high AT a DLI line-start)
//   vbi_nmi_count=81     (VBI, nmien[6], works fine)
//
// This bench replicates the FIFO + the antic_we_q/bus_*_antic_q pipeline from
// fpga_xt_top.sv (lines ~1266-1307) EXACTLY, on two async clocks at the HW
// ratio (clk_sally 100 MHz : clk_sys 133.3 MHz), and exercises TWO phases:
//
//   PHASE A — NMIEN=$C0 written ONCE then held ("timed like the test").
//             Question: does static CDC latency lose the DLI?  (Prime hypothesis.)
//
//   PHASE B — NMIEN clobbered every frame: $40 (VBI-only) at the top of the
//             frame, $C0 only late (near VBI).  Question: what write PATTERN
//             actually reproduces the HW coincide=0 / dli_nmi=0 signature?
//
// Both phases drive NMIEN through the identical CDC path, so any difference is
// due to the write TIMING/VALUE, not the crossing.

`default_nettype none
`timescale 1ns / 1ps

module tb_antic_dli_cdc;

    // ---- Display list (identical to tb_antic_dli phase 1) ----------------
    //   $1000: 70 70 70   3x blank-8 (overscan)  -> ar 0..23
    //   $1003: F0         blank-8 + DLI           -> ar 24..31, DLI @ ar 31 (scanline 39)
    //   $1004: F0         blank-8 + DLI           -> ar 32..39, DLI @ ar 39 (scanline 47)
    //   $1005: 41 00 10   JVB $1000
    localparam logic [15:0] DL_BASE       = 16'h1000;
    localparam int          EXP_DLI_ROW_A = 31;   // scanline 39
    localparam int          EXP_DLI_ROW_B = 39;   // scanline 47

    // ---- Two async clocks at the HW ratio (100 MHz : 133.3 MHz) ----------
    // Absolute frequency is irrelevant to the phi2-derived raster (BASE_DIV
    // divides clk_sys); what matters for the CDC is that clk_sally is the
    // SLOWER writer and clk_sys the faster reader, at ~1.333x, exactly as HW.
    // Deliberately non-harmonic phases so the crossing is not artificially
    // aligned.
    logic clk_sys   = 1'b0; always #3.750 clk_sys   = ~clk_sys;   // 133.3 MHz
    logic clk_sally = 1'b0; always #5.000 clk_sally = ~clk_sally; // 100.0 MHz

    // ---- Resets ----------------------------------------------------------
    logic rst_n     = 1'b0;   // antic_top /reset (active low)
    logic rst_sys   = 1'b1;   // CDC dst reset (active high)
    logic rst_sally = 1'b1;   // CDC src reset (active high)

    // Test phase: 1 = static-hold, 2 = per-frame clobber.
    int   phase = 1;

    // ====================================================================
    // clk_sally write side: hwreg_we/hwreg_addr/hwreg_din (sally_mem output)
    // ====================================================================
    logic        hwreg_we   = 1'b0;
    logic [15:0] hwreg_addr = 16'h0000;
    logic [7:0]  hwreg_din  = 8'h00;

    // ====================================================================
    // CDC + write-strobe regen — EXACT replica of fpga_xt_top.sv ~1266-1307
    // (write path only; the read/cdc_bus_read path is not exercised here, so
    //  cdc_bus_read is held 0 throughout — writes are what the test does).
    // ====================================================================
    wire        hwreg_wr_full_unused;
    wire        hwreg_rd_empty;
    wire [23:0] hwreg_rd_data;
    wire        cdc_bus_read = 1'b0;                       // no register reads here
    wire        hwreg_rd_en  = ~hwreg_rd_empty & ~cdc_bus_read;

    cdc_fifo_1w1r #(.DATA_W(24), .ADDR_W(2)) u_hwreg_cdc (
        .src_clk  (clk_sally),
        .src_rst  (rst_sally),
        .wr_en    (hwreg_we),
        .wr_data  ({hwreg_addr, hwreg_din}),
        .wr_full  (hwreg_wr_full_unused),
        .dst_clk  (clk_sys),
        .dst_rst  (rst_sys),
        .rd_en    (hwreg_rd_en),
        .rd_data  (hwreg_rd_data),
        .rd_empty (hwreg_rd_empty)
    );

    logic        antic_we_q;
    logic [15:0] bus_addr_antic_q;
    logic [7:0]  bus_data_in_antic_q;
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            antic_we_q          <= 1'b0;
            bus_addr_antic_q    <= 16'h0000;
            bus_data_in_antic_q <= 8'h00;
        end else begin
            antic_we_q          <= hwreg_rd_en;
            bus_addr_antic_q    <= hwreg_rd_data[23:8];
            bus_data_in_antic_q <= hwreg_rd_data[7:0];
        end
    end

    wire [15:0] bus_addr_antic    = bus_addr_antic_q;
    wire [7:0]  bus_data_in_antic = bus_data_in_antic_q;
    wire        bus_rw_antic      = ~antic_we_q;
    wire        d0xx_n_antic = ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD0));
    wire        d4xx_n_antic = ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD4));

    // ====================================================================
    // ANTIC-visible 64K memory (bram port) — 1-cycle registered read (clk_sys)
    // ====================================================================
    logic [7:0]  amem [0:65535];
    wire [15:0]  bram_addr;
    logic [7:0]  bram_rdata_r;
    always_ff @(posedge clk_sys) bram_rdata_r <= amem[bram_addr];

    wire [7:0]  bus_data_out;
    wire        bus_data_oe;
    wire        nmi_n, halt_n, rdy_n;
    wire [31:0] diag_wsync_overdue_count;
    wire        wb_pix_valid, wb_row_flush, wb_frame_done;
    wire [7:0]  wb_pix_pair, wb_color_lo, wb_color_hi, wb_atari_row;

    // ====================================================================
    // DUT — antic_top, clk_bus = clk_sys.  Register writes arrive ONLY via
    // the CDC pipeline above (bus_*_antic), exactly like the HW top level.
    // ====================================================================
    antic_top u_dut (
        .clk_bus(clk_sys), .rst_n(rst_n),
        .sally_cold(1'b0),
        .joy_ovr(32'd0), .consol_keys(8'hFF),
        .bus_addr(bus_addr_antic), .bus_data_in(bus_data_in_antic), .bus_rw(bus_rw_antic),
        .d0xx_n(d0xx_n_antic), .d4xx_n(d4xx_n_antic),
        .bus_data_out(bus_data_out), .bus_data_oe(bus_data_oe),
        .nmi_n(nmi_n), .halt_n(halt_n), .rdy_n(rdy_n),
        .dmactl_honor(1'b0),
        .spi_miso(1'b1), .spi_irq(1'b1),
        .joy_spi_miso(1'b1), .joy_spi_int_n(1'b1),
        .adc_sdata_i(1'b0),
        .bus_mpd_n_in(1'b1), .bus_extirq_n_in(1'b1), .bus_rd4_in(1'b1), .bus_rd5_in(1'b1),
        .unlock_antic(1'b1), .unlock_sprite(1'b1), .unlock_blit(1'b1),
        .kbd_event_valid(1'b0), .kbd_event_code(8'h00),
        .kbd_release(1'b0), .kbd_break_pulse(1'b0),
        .bram_addr(bram_addr), .bram_rdata(bram_rdata_r),
        .wb_pix_valid(wb_pix_valid), .wb_pix_pair(wb_pix_pair),
        .wb_color_lo(wb_color_lo), .wb_color_hi(wb_color_hi),
        .wb_atari_row(wb_atari_row), .wb_row_flush(wb_row_flush),
        .wb_frame_done(wb_frame_done),
        .diag_wsync_overdue_count(diag_wsync_overdue_count)
    );

    // ====================================================================
    // hwreg write task (clk_sally domain) — 1-cycle wr_en pulse, exactly the
    // shape sally_mem produces on a $D4xx CPU store.
    // ====================================================================
    task automatic wr_hwreg(input logic [15:0] a, input logic [7:0] d);
        @(negedge clk_sally);
        hwreg_addr = a; hwreg_din = d; hwreg_we = 1'b1;
        @(posedge clk_sally);
        @(negedge clk_sally);
        hwreg_we = 1'b0; hwreg_addr = 16'h0000; hwreg_din = 8'h00;
    endtask

    // ====================================================================
    // Hierarchical taps into the DUT (same style as tb_antic_dli).
    // ====================================================================
    wire       h_dli_event = u_dut.u_nmi_gen.dli_event;
    wire       h_dli_nmi   = u_dut.u_nmi_gen.dli_nmi;
    wire       h_vbi_nmi   = u_dut.u_nmi_gen.vbi_nmi;
    wire [7:0] h_nmien     = u_dut.nmien_q;
    wire [7:0] h_row       = u_dut.ar_atari_row;
    wire [8:0] h_scan      = u_dut.ar_scanline;

    // ====================================================================
    // Per-phase measurement (== HW GP0 diag flags).
    // ====================================================================
    // phase A
    bit      nmien_c0_seen = 0;  realtime nmien_c0_time = 0;  int nmien_c0_scan = -1;
    bit      or7_a  = 0, coincide_a = 0, rowA_a = 0, rowB_a = 0;
    int      ev_a   = 0, nmi_a = 0, vbi_a = 0, logged_a = 0;
    // phase B
    bit      or7_b  = 0, coincide_b = 0;
    int      ev_b   = 0, nmi_b = 0, vbi_b = 0, logged_b = 0;

    always_ff @(posedge clk_sys) begin
        if (rst_n) begin
            if (phase == 1) begin
                if (!nmien_c0_seen && h_nmien == 8'hC0) begin
                    nmien_c0_seen = 1; nmien_c0_time = $realtime; nmien_c0_scan = h_scan;
                    $display("[t=%0t] PHASE A: nmien_q reached $C0 @ scanline %0d (ar_row=%0d)",
                             $realtime, h_scan, h_row);
                end
                if (h_nmien[7]) or7_a = 1;
                if (h_dli_event) begin
                    ev_a++;
                    if (logged_a < 8) begin
                        $display("[t=%0t] PHASE A DLI EVENT #%0d @ scanline %0d ar_row=%0d  nmien_q=$%02h nmien[7]=%0b -> %s",
                                 $realtime, ev_a, h_scan, h_row, h_nmien, h_nmien[7],
                                 h_nmien[7] ? "GATED-THROUGH" : "BLOCKED");
                        logged_a++;
                    end
                end
                if (h_dli_event && h_nmien[7]) coincide_a = 1;
                if (h_dli_nmi) begin
                    nmi_a++;
                    if (h_row == EXP_DLI_ROW_A[7:0]) rowA_a = 1;
                    else if (h_row == EXP_DLI_ROW_B[7:0]) rowB_a = 1;
                end
                if (h_vbi_nmi) vbi_a++;
            end else if (phase == 2) begin
                if (h_nmien[7]) or7_b = 1;
                if (h_dli_event) begin
                    ev_b++;
                    if (logged_b < 8) begin
                        $display("[t=%0t] PHASE B DLI EVENT #%0d @ scanline %0d ar_row=%0d  nmien_q=$%02h nmien[7]=%0b -> %s",
                                 $realtime, ev_b, h_scan, h_row, h_nmien, h_nmien[7],
                                 h_nmien[7] ? "GATED-THROUGH" : "BLOCKED");
                        logged_b++;
                    end
                end
                if (h_dli_event && h_nmien[7]) coincide_b = 1;
                if (h_dli_nmi) nmi_b++;
                if (h_vbi_nmi) vbi_b++;
            end
        end
    end

    // ====================================================================
    // PHASE B clobber driver — rewrites NMIEN every frame through the SAME
    // CDC path: $40 at the top (scanline 2, before the DLI lines 39/47) and
    // $C0 late (scanline 210, before VBI @ 248).  So nmien[7] is HIGH only
    // across scanlines ~210..261 (covers VBI) and LOW across 0..~209 (covers
    // the DLI lines) — the exact HW split.  Guarded on `phase==2`; phase A's
    // stimulus never runs concurrently (it hands off cleanly).
    // ====================================================================
    bit did_lo = 0, did_hi = 0;
    initial begin
        forever begin
            @(posedge clk_sys);
            if (phase == 2) begin
                if (h_scan == 9'd2 && !did_lo) begin
                    did_lo = 1; did_hi = 0;
                    wr_hwreg(16'hD40E, 8'h40);   // VBI-only: DLI OFF for the visible frame
                end else if (h_scan == 9'd210 && !did_hi) begin
                    did_hi = 1; did_lo = 0;
                    wr_hwreg(16'hD40E, 8'hC0);   // re-arm DLI+VBI just before VBI
                end
            end
        end
    end

    // ====================================================================
    // Stimulus
    // ====================================================================
    initial begin
        $display("=== ANTIC_DLI_CDC — NMIEN via clk_sally->CDC->clk_sys path ===");
        for (int i = 0; i < 65536; i++) amem[i] = 8'h00;

        amem[DL_BASE+0] = 8'h70;
        amem[DL_BASE+1] = 8'h70;
        amem[DL_BASE+2] = 8'h70;
        amem[DL_BASE+3] = 8'hF0;   // blank-8 + DLI -> DLI @ ar 31
        amem[DL_BASE+4] = 8'hF0;   // blank-8 + DLI -> DLI @ ar 39
        amem[DL_BASE+5] = 8'h41;
        amem[DL_BASE+6] = DL_BASE[7:0];
        amem[DL_BASE+7] = DL_BASE[15:8];

        repeat (8) @(posedge clk_sys);
        rst_sys = 1'b0;
        repeat (8) @(posedge clk_sally);
        rst_sally = 1'b0;
        repeat (8) @(posedge clk_sys);
        rst_n = 1'b1;
        repeat (16) @(posedge clk_sys);

        // ---- PHASE A: program once, hold ($C0), run ~2.5 frames ----------
        wr_hwreg(16'hD402, DL_BASE[7:0]);    // DLISTL
        wr_hwreg(16'hD403, DL_BASE[15:8]);   // DLISTH
        wr_hwreg(16'hD400, 8'h22);           // DMACTL: normal playfield + DL DMA
        wr_hwreg(16'hD40E, 8'hC0);           // NMIEN: DLI(bit7) + VBI(bit6)
        repeat (5_600_000) @(posedge clk_sys);

        // ---- Hand off to PHASE B at the top of a fresh frame -------------
        @(negedge clk_sys);
        wait (h_scan == 9'd245);             // just before VBI, so the clobber
                                             // driver catches scanline 2 next
        phase = 2;
        // let the pattern settle for a couple of frames, then measure 3 frames
        repeat (6_700_000) @(posedge clk_sys);

        // ================= VERDICT =====================================
        $display("");
        $display("=========================== RESULT ===========================");
        $display("PHASE A (static NMIEN=$C0, held) — tests the CDC-latency hypothesis");
        $display("  nmien_q reached $C0     : %0b  (first @ scanline %0d, t=%0t)",
                 nmien_c0_seen, nmien_c0_scan, nmien_c0_time);
        $display("  nmien_or[7] (sticky)    : %0b        (HW: 1)", or7_a);
        $display("  DLI events detected     : %0d        (HW: 48 per its run)", ev_a);
        $display("  DLI /NMI gated through  : %0d        (HW: 0)",  nmi_a);
        $display("  coincide (nmien7 @ DLI) : %0b        (HW: 0)",  coincide_a);
        $display("  VBI /NMI asserted       : %0d        (HW: 81 per its run)", vbi_a);
        $display("  DLI seen @ ar31 / ar39  : %0b / %0b", rowA_a, rowB_a);
        $display("");
        $display("PHASE B (NMIEN clobbered mid-frame: $40 top, $C0 near VBI)");
        $display("  nmien_or[7] (sticky)    : %0b        (HW: 1)", or7_b);
        $display("  DLI events detected     : %0d       (events fire regardless of NMIEN)", ev_b);
        $display("  DLI /NMI gated through  : %0d        (HW: 0)",  nmi_b);
        $display("  coincide (nmien7 @ DLI) : %0b        (HW: 0)",  coincide_b);
        $display("  VBI /NMI asserted       : %0d        (HW: >0)", vbi_b);
        $display("==============================================================");
        $display("");

        // Verdict logic --------------------------------------------------
        if (nmi_a > 0 && !nmien_c0_seen) begin
            $display("*** INCONCLUSIVE (phase A internally inconsistent) ***");
            $display("*** ANTIC_DLI_CDC: INCONCLUSIVE ***");
            $fatal(1);
        end

        if (nmi_a > 0) begin
            $display("PHASE A: DLI /NMI fired %0d time(s) via the CDC path.", nmi_a);
            $display("  => The CDC-latency-of-a-STATIC-NMIEN-write hypothesis is REFUTED.");
            $display("  => nmien_q settles $C0 at scanline %0d and holds; every DLI event", nmien_c0_scan);
            $display("     (ar31 @ scanline39, ar39 @ scanline47) gates through cleanly.");
        end else if (nmien_c0_seen) begin
            $display("PHASE A: DLI /NMI NEVER gated through while nmien_q=$C0 — matches HW.");
            $display("  => The static CDC path DOES lose the DLI (hypothesis SUPPORTED).");
        end else begin
            $display("*** INCONCLUSIVE: nmien_q never reached $C0 (write lost) ***");
            $display("*** ANTIC_DLI_CDC: INCONCLUSIVE ***");
            $fatal(1);
        end

        $display("");
        if (nmi_b == 0 && or7_b && ev_b > 0) begin
            $display("PHASE B: reproduces the HW signature EXACTLY through the same CDC path:");
            $display("  nmien_or[7]=1, DLI events fire (%0d), but dli_nmi=0 and coincide=0,", ev_b);
            $display("  because nmien[7] is LOW across the DLI lines and HIGH only near VBI.");
            $display("  => The failure is a mid-frame NMIEN clobber (write VALUE/TIMING),");
            $display("     NOT the register-write clock-domain crossing.");
        end else begin
            $display("PHASE B: did not cleanly reproduce (nmi_b=%0d or7_b=%0b ev_b=%0d) —",
                     nmi_b, or7_b, ev_b);
            $display("  clobber timing may need tuning; phase A result stands regardless.");
        end

        // Overall pass verdict token — the bench is diagnostic; a clean
        // phase-A refutation (the actual finding) is a PASS.
        if (nmi_a > 0)
            $display("*** ANTIC_DLI_CDC: NOT-REPRODUCED (CDC-latency hypothesis refuted) ***");
        else
            $display("*** ANTIC_DLI_CDC: BUG-REPRODUCED (static CDC path lost the DLI) ***");
        $finish;
    end

    initial begin
        #300_000_000;
        $display("FAIL: tb_antic_dli_cdc watchdog timeout");
        $fatal(1);
    end

endmodule

`default_nettype wire
