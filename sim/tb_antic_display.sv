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

module tb_antic_display;

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
    wire [15:0]  cmp_bram_addr;
    logic [7:0]  cmp_bram_rdata_r;
    always_ff @(posedge clk_bus) cmp_bram_rdata_r <= amem[cmp_bram_addr];

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
        .cmp_bram_addr(cmp_bram_addr), .cmp_bram_rdata(cmp_bram_rdata_r),
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

    // ---- Scoreboard ------------------------------------------------------
    int  fail = 0;
    int  flush_count = 0, frame_count = 0;
    int  prev_row = -1, exp_row;
    int  pixvalid_active = 0;            // wb_pix_valid pulses seen at row 0
    // Row-0 capture: color per pair.
    logic [7:0] cap_lo [0:255];
    logic [7:0] cap_hi [0:255];
    bit         cap_seen [0:255];
    integer     i;

    always_ff @(posedge clk_bus) begin
        if (rst_n) begin
            if (wb_frame_done) frame_count <= frame_count + 1;
            // Row walk: each row_flush, atari_row should advance 0,1,2,… over
            // the active band (0xFF outside).  Only check the active band.
            if (wb_row_flush) begin
                flush_count <= flush_count + 1;
                if (wb_atari_row != 8'hFF) begin
                    exp_row = (prev_row < 0 || prev_row == 8'hFF) ? 0 : prev_row + 1;
                    // allow the very first observed active row to be 0
                    if (prev_row >= 0 && prev_row != 8'hFF && wb_atari_row != exp_row[7:0]
                        && !(prev_row == 191 && wb_atari_row == 0)) begin
                        $display("FAIL row walk: got %0d after %0d", wb_atari_row, prev_row);
                        fail++;
                    end
                    prev_row <= wb_atari_row;
                end
            end
            // Capture row-0 pixel pairs.
            if (wb_pix_valid && wb_atari_row == 8'd0) begin
                pixvalid_active <= pixvalid_active + 1;
                if (wb_pix_pair < 8'd128) begin
                    cap_lo[wb_pix_pair]   <= wb_color_lo;
                    cap_hi[wb_pix_pair]   <= wb_color_hi;
                    cap_seen[wb_pix_pair] <= 1'b1;
                end
            end
        end
    end

    // ---- Stimulus --------------------------------------------------------
    task automatic check_pair(input int p, input logic [7:0] elo, input logic [7:0] ehi,
                              input string what);
        if (!cap_seen[p]) begin
            $display("FAIL row0 pair %0d (%s) never produced", p, what); fail++;
        end else if (cap_lo[p] !== elo || cap_hi[p] !== ehi) begin
            $display("FAIL row0 pair %0d (%s): got {hi=%02h,lo=%02h} exp {hi=%02h,lo=%02h}",
                     p, what, cap_hi[p], cap_lo[p], ehi, elo);
            fail++;
        end
    endtask

    initial begin
        $display("=== ANTIC_DISPLAY TEST ===");
        for (i = 0; i < 65536; i = i + 1) amem[i] = 8'h00;
        for (i = 0; i < 256;   i = i + 1) cap_seen[i] = 1'b0;

        // Display list at $1000: mode F rows 0..3, then JVB back to $1000.
        amem[DL_BASE+0] = 8'h4F;  amem[DL_BASE+1] = SCR_BASE[7:0];  amem[DL_BASE+2] = SCR_BASE[15:8];
        amem[DL_BASE+3] = 8'h0F;  amem[DL_BASE+4] = 8'h0F;  amem[DL_BASE+5] = 8'h0F;
        amem[DL_BASE+6] = 8'h41;  amem[DL_BASE+7] = DL_BASE[7:0];   amem[DL_BASE+8] = DL_BASE[15:8];

        // Row-0 screen bytes: $FF (all set), $00 (all clear), $AA (alternating).
        amem[SCR_BASE+0] = 8'hFF;
        amem[SCR_BASE+1] = 8'h00;
        amem[SCR_BASE+2] = 8'hAA;
        for (i = 3; i < 40; i = i + 1) amem[SCR_BASE+i] = 8'h3C;

        repeat (8) @(posedge clk_bus);
        rst_n = 1'b1;
        repeat (4) @(posedge clk_bus);

        // Program ANTIC + GTIA via the snoop bus.
        wr_d4xx(8'h02, DL_BASE[7:0]);    // DLISTL
        wr_d4xx(8'h03, DL_BASE[15:8]);   // DLISTH
        wr_d4xx(8'h00, 8'h22);           // DMACTL: normal playfield + DL DMA
        wr_d0xx(8'h18, C_PF2);           // COLPF2 (mode-F set bits)
        wr_d0xx(8'h1A, C_BK);            // COLBK  (clear bits)

        // Run ~1.1 frames: frame 0's VBI parses the DL, frame 1 composes it.
        // (frame = 262 lines × 114 phi2 × 90 clk_bus ≈ 2.69 M clk_bus.)
        repeat (3_100_000) @(posedge clk_bus);

        // ---- Checks ----
        if (frame_count < 1) begin $display("FAIL: no wb_frame_done (frame cadence dead)"); fail++; end
        if (flush_count < 200) begin $display("FAIL: too few row_flush pulses (%0d)", flush_count); fail++; end
        if (pixvalid_active == 0) begin $display("FAIL: no pixels composed for row 0 (black screen!)"); fail++; end

        // Row 0 = screen byte 0 ($FF, pairs 0-3) / byte 1 ($00, pairs 4-7) /
        // byte 2 ($AA=10101010, pairs 8-11).  Mode F: set→COLPF2, clear→COLBK.
        check_pair(0,  C_PF2, C_PF2, "byte0 $FF p0");
        check_pair(3,  C_PF2, C_PF2, "byte0 $FF p3");
        check_pair(4,  C_BK,  C_BK,  "byte1 $00 p0");
        check_pair(7,  C_BK,  C_BK,  "byte1 $00 p3");
        check_pair(8,  C_PF2, C_BK,  "byte2 $AA p0");   // lo=bit7=1, hi=bit6=0
        check_pair(9,  C_PF2, C_BK,  "byte2 $AA p1");

        if (fail == 0) begin
            $display("*** ANTIC_DISPLAY OK *** %0d frames, %0d row_flush, row0 pixels match (set=%02h clear=%02h)",
                     frame_count, flush_count, C_PF2, C_BK);
            $finish;
        end else begin
            $display("*** ANTIC_DISPLAY FAIL *** %0d failures", fail);
            $fatal(1);
        end
    end

    initial begin
        #250_000_000;       // ~2 frames of headroom
        $display("FAIL: tb_antic_display watchdog"); $fatal(1);
    end

endmodule

`default_nettype wire
