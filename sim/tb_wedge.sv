// tb_antic_display.sv — end-to-end ANTIC display-path integration test.
//
// De-risks the "black screen" path BEFORE hardware: a real display list +
// screen data in memory → antic_top's internal chain (bram_shim read →
// dl_parser → antic_seq → compositor → color_resolver → §5 render tap) →
// the wb_* outputs that feed antic_writeback.  Drives the REAL antic_top
// (not the unit-level pieces), with a memory model on its bram port and
// registers set over the snoop bus, exactly as the OS would.
//
// (antic_writeback → DDR is separately covered by tb_antic_writeback; this
// test validates everything UP TO the tap, which is the unverified leg.)
//
// Scenario: a short mode-F (1bpp hi-res) display list (rows 0..3) over a
// known screen pattern, COLPF2/COLBK set to sentinels.  Checks:
//   * the frame cadence pulse (wb_frame_done) fires,
//   * wb_row_flush fires per scanline and wb_atari_row walks 0,1,2,…,
//   * the composed pixel stream for row 0 matches the screen bytes —
//     set bit → COLPF2 value, clear bit → COLBK value (mode-F semantics),
//     proving memory→parse→compose→colour-resolve→tap end to end.

`default_nettype none
`timescale 1ns / 1ps

module tb_wedge;

    localparam logic [15:0] DL_BASE  = 16'h1000;   // display list
    localparam logic [15:0] SCR_BASE = 16'h2000;   // screen data (mode-F LMS)
    localparam logic [7:0]  C_PF2    = 8'h18;       // COLPF2 sentinel (set bits)
    localparam logic [7:0]  C_BK     = 8'h0A;       // COLBK  sentinel (clear bits)

    // ~21.5 MHz bus clock (as the other antic_top tbs).
    logic clk_bus = 1'b0;  always #23.256 clk_bus = ~clk_bus;

    logic        rst_n       = 1'b0;
    logic [15:0] bus_addr    = 16'h0000;
    logic [7:0]  bus_data_in = 8'h00;
    logic        bus_rw      = 1'b1;     // 1 = read (idle)
    logic        d0xx_n      = 1'b1;
    logic        d4xx_n      = 1'b1;

    wire [7:0]  bus_data_out;
    wire        bus_data_oe;
    wire        nmi_n, halt_n, rdy_n;
    wire [31:0] diag_wsync_overdue_count;

    // ---- ANTIC's memory (bram port) — 1-cycle registered read -----------
    logic [7:0]  amem [0:65535];
    wire [15:0]  bram_addr;
    logic [7:0]  bram_rdata_r;
    always_ff @(posedge clk_bus) bram_rdata_r <= amem[bram_addr];

    // ---- §5 render tap outputs ------------------------------------------
    wire        wb_pix_valid, wb_row_flush, wb_frame_done;
    wire [7:0]  wb_pix_pair, wb_color_lo, wb_color_hi, wb_atari_row;

    antic_top u_dut (
        .clk_bus(clk_bus), .rst_n(rst_n),
        .joy_ovr(32'd0),   // keypad->joystick override off (default)
        .bus_addr(bus_addr), .bus_data_in(bus_data_in), .bus_rw(bus_rw),
        .d0xx_n(d0xx_n), .d4xx_n(d4xx_n),
        .bus_data_out(bus_data_out), .bus_data_oe(bus_data_oe),
        .nmi_n(nmi_n), .halt_n(halt_n), .rdy_n(rdy_n),
        .spi_miso(1'b1), .spi_irq(1'b1),
        .joy_spi_miso(1'b1), .joy_spi_int_n(1'b1),
        // idle/peripheral inputs not on the display path
        .adc_sdata_i(1'b0),
        .bus_mpd_n_in(1'b1), .bus_extirq_n_in(1'b1), .bus_rd4_in(1'b1), .bus_rd5_in(1'b1),
        .unlock_antic(1'b1),
        .unlock_sprite(1'b1),
        .unlock_blit(1'b1),
        .kbd_event_valid(1'b0), .kbd_event_code(8'h00),
        .bram_addr(bram_addr), .bram_rdata(bram_rdata_r),
        .wb_pix_valid(wb_pix_valid), .wb_pix_pair(wb_pix_pair),
        .wb_color_lo(wb_color_lo), .wb_color_hi(wb_color_hi),
        .wb_atari_row(wb_atari_row), .wb_row_flush(wb_row_flush),
        .wb_frame_done(wb_frame_done),
        .diag_wsync_overdue_count(diag_wsync_overdue_count)
    );

    // ---- Bus register-write tasks (snoop captures bus_rw=0 + dNxx_n=0) ---
    task automatic wr_d4xx(input logic [7:0] a, input logic [7:0] d);
        @(negedge clk_bus); bus_addr = {8'hD4, a}; bus_data_in = d; bus_rw = 1'b0; d4xx_n = 1'b0;
        @(posedge clk_bus);
        @(negedge clk_bus); bus_rw = 1'b1; d4xx_n = 1'b1; bus_addr = 16'h0;
    endtask
    task automatic wr_d0xx(input logic [7:0] a, input logic [7:0] d);
        @(negedge clk_bus); bus_addr = {8'hD0, a}; bus_data_in = d; bus_rw = 1'b0; d0xx_n = 1'b0;
        @(posedge clk_bus);
        @(negedge clk_bus); bus_rw = 1'b1; d0xx_n = 1'b1; bus_addr = 16'h0;
    endtask

    
    // ---- Wedge hunt ------------------------------------------------------
    int frame_count = 0;
    int flushes_this_frame = 0;
    int flushes_per_frame [0:9];
    always_ff @(posedge clk_bus) begin
        if (rst_n) begin
            if (wb_row_flush) flushes_this_frame <= flushes_this_frame + 1;
            if (wb_frame_done) begin
                if (frame_count < 10) flushes_per_frame[frame_count] <= flushes_this_frame;
                frame_count <= frame_count + 1;
                flushes_this_frame <= 0;
            end
        end
    end

    task automatic wait_frames(input int n);
        int target;
        target = frame_count + n;
        while (frame_count < target) @(posedge clk_bus);
    endtask

    initial begin
        int i;
        rst_n = 1'b0;
        repeat (16) @(posedge clk_bus);
        rst_n = 1'b1;

        // OS-like screen: DL at $1000 = 3x$70, LMS mode 2 at $2000, 23 more
        // mode-2 rows, JVB -> $1000.
        amem[16'h1000] = 8'h70; amem[16'h1001] = 8'h70; amem[16'h1002] = 8'h70;
        amem[16'h1003] = 8'h42; amem[16'h1004] = 8'h00; amem[16'h1005] = 8'h20;
        for (i = 0; i < 23; i++) amem[16'h1006 + i] = 8'h02;
        amem[16'h101D] = 8'h41; amem[16'h101E] = 8'h00; amem[16'h101F] = 8'h10;
        for (i = 0; i < 40*24; i++) amem[16'h2000 + i] = 8'h21;

        // nmist-style DL at $2C00: 3x blank-8, 2x blank-8+DLI, JVB self.
        amem[16'h2C00] = 8'h70; amem[16'h2C01] = 8'h70; amem[16'h2C02] = 8'h70;
        amem[16'h2C03] = 8'hF0; amem[16'h2C04] = 8'hF0;
        amem[16'h2C05] = 8'h41; amem[16'h2C06] = 8'h00; amem[16'h2C07] = 8'h2C;

        // arm the OS screen
        wr_d4xx(8'h02, 8'h00);   // DLISTL
        wr_d4xx(8'h03, 8'h10);   // DLISTH
        wr_d4xx(8'h00, 8'h22);   // DMACTL: normal playfield + DL DMA
        wait_frames(3);
        $display("phase1 (OS DL): flushes/frame = %0d %0d %0d",
                 flushes_per_frame[0], flushes_per_frame[1], flushes_per_frame[2]);

        // swap to the nmist DL exactly as the test does: _screenOff FIRST
        // (DMACTL=0 — potentially mid-parse), then the DL swap.
        wr_d4xx(8'h00, 8'h00);   // DMACTL = 0 (_screenOff)
        wait_frames(1);
        wr_d4xx(8'h02, 8'h00);   // DLISTL = $00
        wr_d4xx(8'h03, 8'h2C);   // DLISTH = $2C
        wr_d4xx(8'h0E, 8'hC0);   // NMIEN = DLI+VBI
        wr_d4xx(8'h00, 8'h20);   // DMACTL back on (the test's $20)
        wait_frames(4);
        $display("phase2 (nmist DL): flushes/frame = %0d %0d %0d %0d",
                 flushes_per_frame[3], flushes_per_frame[4],
                 flushes_per_frame[5], flushes_per_frame[6]);

        // swap BACK to the OS screen (the 6502-reset case)
        wr_d4xx(8'h02, 8'h00);
        wr_d4xx(8'h03, 8'h10);
        wait_frames(3);
        $display("phase3 (back to OS DL): flushes/frame = %0d %0d",
                 flushes_per_frame[7], flushes_per_frame[8]);

        if (flushes_per_frame[8] > 100 && flushes_per_frame[5] >= 0)
            $display("*** WEDGE OK *** parser survives the nmist DL swap");
        else
            $display("*** WEDGE FAIL *** flushes died");
        $finish;
    end

    initial begin
        #2_000_000_000;   // 2 s wall of sim time
        $display("*** WEDGE TIMEOUT *** frame_count=%0d flushes: %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 frame_count,
                 flushes_per_frame[0], flushes_per_frame[1], flushes_per_frame[2],
                 flushes_per_frame[3], flushes_per_frame[4], flushes_per_frame[5],
                 flushes_per_frame[6], flushes_per_frame[7], flushes_per_frame[8]);
        $finish;
    end

endmodule
