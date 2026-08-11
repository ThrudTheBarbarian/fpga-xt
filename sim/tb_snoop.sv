// tb_snoop.sv — M1 bus-snoop dispatch.
//
// Drives a sequence of CPU bus cycles to addresses in $D000-$D01F and
// $D400-$D40F + a few $D480 chiplet-ext addresses, plus a few system-
// memory writes, and asserts that:
//
//   - Each /D0xx write lands in the corresponding gtia_regs storage.
//   - Each /D4xx write lands in the corresponding antic_regs storage.
//   - System-memory writes (no page select asserted) land in cpu_shadow.
//   - Hardware-page writes outside /D0xx and /D4xx (e.g. $D200) do
//     NOT land in cpu_shadow.
//   - HITCLR ($D01E write) fires the strobe.
//
// Uses hierarchical references into the DUT's register files and
// shadow RAM — there is no bus-side read path being exercised yet
// (that's M2). This is purely a write-path verification.

`default_nettype none
`timescale 1ns / 1ps

module tb_snoop;

    // ---- Clock + DUT ----------------------------------------------------
    // clk_pix dropped — task-0013 step 3 removed antic_top's 800×600 chain.
    logic clk_bus = 1'b0;
    always #23.256 clk_bus = ~clk_bus;   // ~21.5 MHz

    logic        rst_n       = 1'b0;
    logic [15:0] bus_addr    = 16'h0000;
    logic [7:0]  bus_data_in = 8'h00;
    logic        bus_rw      = 1'b1;          // 1 = read; idle high
    logic        d0xx_n      = 1'b1;
    logic        d4xx_n      = 1'b1;

    wire [7:0]  bus_data_out;
    wire        bus_data_oe;
    wire        nmi_n, halt_n, rdy_n;
    wire [31:0] diag_wsync_overdue_count;

    antic_top u_dut (
        .clk_bus                  (clk_bus),
        .rst_n                    (rst_n),
        .joy_ovr                  (32'd0),   // keypad->joystick override off (default)
        .unlock_antic             (1'b1),
        .unlock_sprite(1'b1),
        .unlock_blit(1'b1),
        .bus_addr                 (bus_addr),
        .bus_data_in              (bus_data_in),
        .bus_rw                   (bus_rw),
        .d0xx_n                   (d0xx_n),
        .d4xx_n                   (d4xx_n),
        .bus_data_out             (bus_data_out),
        .bus_data_oe              (bus_data_oe),
        .nmi_n                    (nmi_n),
        .halt_n                   (halt_n),
        .rdy_n                    (rdy_n),
        // M25-2c-rev: joy / POT / SD / SIO bridged via SPI links.
        .spi_clk                  (),
        .spi_mosi                 (),
        .spi_miso                 (1'b1),
        .spi_cs_n                 (),
        .spi_irq                  (1'b1),
        .joy_spi_clk              (),
        .joy_spi_mosi             (),
        .joy_spi_miso             (1'b1),
        .joy_spi_cs_n             (),
        .joy_spi_int_n            (1'b1),
        .diag_wsync_overdue_count (diag_wsync_overdue_count)
    );

    // ---- Failure tracking -----------------------------------------------
    int fail_count = 0;
    // Phase 6: the POKEY pair is native to the CPU domain; the snoop path's
    // job here is the ADDRESS DECODE (the 130XE addr[4] L/R split).  Count
    // the decode strobes instead of peeking into the departed hierarchy.
    integer snoop_l_hits = 0, snoop_r_hits = 0;
    always @(posedge clk_bus) begin
        if (u_dut.snoop_we_pokey_l) snoop_l_hits = snoop_l_hits + 1;
        if (u_dut.snoop_we_pokey_r) snoop_r_hits = snoop_r_hits + 1;
    end

    task automatic expect_eq(input string label,
                             input logic [7:0] actual,
                             input logic [7:0] expected);
        if (actual !== expected) begin
            $display("FAIL %s: got $%02h, expected $%02h", label, actual, expected);
            fail_count++;
        end
    endtask

    // ---- Bus-cycle drivers ----------------------------------------------
    // 6502-ish convention: A and R/W stable through phi2 (CLK high).
    // Master writes D during phi2 (CLK high). Snoop samples on rising
    // edge — so the data must be set BEFORE the rising edge of bus_clk
    // we want to be sampled.
    task automatic do_write_d0xx(input logic [7:0] addr_lo, input logic [7:0] data);
        @(negedge clk_bus);
        bus_addr    = {8'hD0, addr_lo};
        bus_data_in = data;
        bus_rw      = 1'b0;
        d0xx_n      = 1'b0;
        d4xx_n      = 1'b1;
        @(posedge clk_bus);                  // snoop samples here
        @(negedge clk_bus);
        bus_addr    = 16'h0000;
        bus_data_in = 8'h00;
        bus_rw      = 1'b1;
        d0xx_n      = 1'b1;
    endtask

    task automatic do_write_d4xx(input logic [7:0] addr_lo, input logic [7:0] data);
        @(negedge clk_bus);
        bus_addr    = {8'hD4, addr_lo};
        bus_data_in = data;
        bus_rw      = 1'b0;
        d0xx_n      = 1'b1;
        d4xx_n      = 1'b0;
        @(posedge clk_bus);
        @(negedge clk_bus);
        bus_addr    = 16'h0000;
        bus_data_in = 8'h00;
        bus_rw      = 1'b1;
        d4xx_n      = 1'b1;
    endtask

    task automatic do_write_sysmem(input logic [15:0] addr, input logic [7:0] data);
        @(negedge clk_bus);
        bus_addr    = addr;
        bus_data_in = data;
        bus_rw      = 1'b0;
        d0xx_n      = 1'b1;
        d4xx_n      = 1'b1;
        @(posedge clk_bus);
        @(negedge clk_bus);
        bus_addr    = 16'h0000;
        bus_data_in = 8'h00;
        bus_rw      = 1'b1;
    endtask

    // ---- Test sequence --------------------------------------------------
    initial begin
        $display("[snoop] start");
        repeat (10) @(posedge clk_bus);
        rst_n = 1'b1;
        repeat (4) @(posedge clk_bus);

        // GTIA write side ($D000-$D01F). Spot-check, not exhaustive.
        do_write_d0xx(8'h00, 8'hA1);   // HPOSP0
        do_write_d0xx(8'h04, 8'hB2);   // HPOSM0
        do_write_d0xx(8'h08, 8'h03);   // SIZEP0
        do_write_d0xx(8'h0D, 8'hAA);   // GRAFP0
        do_write_d0xx(8'h12, 8'h55);   // COLPM0
        do_write_d0xx(8'h16, 8'h66);   // COLPF0
        do_write_d0xx(8'h1A, 8'h77);   // COLBK
        do_write_d0xx(8'h1B, 8'h40);   // PRIOR
        do_write_d0xx(8'h1D, 8'h03);   // GRACTL
        do_write_d0xx(8'h1F, 8'h08);   // CONSOL_W

        // ANTIC write side ($D400-$D40F).
        do_write_d4xx(8'h00, 8'h22);   // DMACTL
        do_write_d4xx(8'h01, 8'h02);   // CHACTL
        do_write_d4xx(8'h02, 8'h00);   // DLISTL
        do_write_d4xx(8'h03, 8'h40);   // DLISTH
        do_write_d4xx(8'h04, 8'h05);   // HSCROL
        do_write_d4xx(8'h05, 8'h0A);   // VSCROL
        do_write_d4xx(8'h07, 8'h78);   // PMBASE
        do_write_d4xx(8'h09, 8'hE0);   // CHBASE
        do_write_d4xx(8'h0E, 8'hC0);   // NMIEN

        // ANTIC chiplet-ext $D481 MODE: writing 0 *tries* to clear MODE_SNOOP,
        // but it is reset-locked to 1 (snoop) and not bus-writable — so the
        // write must leave mode_snoop at 1. (A stray $D481 write — the stock
        // CHACTL-mirror address — must never clobber the snoop/DMA mode.)
        do_write_d4xx(8'h81, 8'h00);

        // System-memory writes (should land in cpu_shadow).
        do_write_sysmem(16'h2000, 8'h12);
        do_write_sysmem(16'h2001, 8'h34);
        do_write_sysmem(16'h7FFF, 8'hAB);
        do_write_sysmem(16'hBFFF, 8'hCD);   // top of system RAM

        // Hardware-page write outside /D0xx and /D4xx (e.g. POKEY $D200)
        // should NOT land in cpu_shadow because the address is in
        // $D000-$D7FF.
        do_write_sysmem(16'hD200, 8'hEE);

        // M23-stereo: writes to $D200 (left POKEY, AUDF1) and $D210
        // (right POKEY, AUDF1 mirror) must be routed to separate
        // chips. Pick distinct values so cross-talk is detectable.
        // Verify the dual-mono fallback flag (stereo_active_q) is
        // still 0 before the first $D21x write.
        do_write_sysmem(16'hD200, 8'h11);   // left AUDF1 ← $11
        repeat (4) @(posedge clk_bus);
        if (snoop_r_hits !== 0) begin
            $display("FAIL pokey_r decode before $D21x: expected 0 strobes, got %0d",
                     snoop_r_hits);
            fail_count++;
        end
        do_write_sysmem(16'hD210, 8'h22);   // right AUDF1 ← $22 ($D21x decode)

        // HITCLR strobe ($D01E write).
        do_write_d0xx(8'h1E, 8'h00);

        // ---- Wait for the last write to settle, then verify -----------
        repeat (4) @(posedge clk_bus);

        // GTIA verifications via hierarchical references.
        expect_eq("HPOSP0",    u_dut.u_gtia_regs.hposp[0],  8'hA1);
        expect_eq("HPOSM0",    u_dut.u_gtia_regs.hposm[0],  8'hB2);
        expect_eq("SIZEP0",    u_dut.u_gtia_regs.sizep[0],  8'h03);
        expect_eq("GRAFP0",    u_dut.u_gtia_regs.grafp[0],  8'hAA);
        expect_eq("COLPM0",    u_dut.u_gtia_regs.colpm[0],  8'h55);
        expect_eq("COLPF0",    u_dut.u_gtia_regs.colpf[0],  8'h66);
        expect_eq("COLBK",     u_dut.u_gtia_regs.colbk,     8'h77);
        expect_eq("PRIOR",     u_dut.u_gtia_regs.prior,     8'h40);
        expect_eq("GRACTL",    u_dut.u_gtia_regs.gractl,    8'h03);
        expect_eq("CONSOL_W",  u_dut.u_gtia_regs.consol_w,  8'h08);

        // ANTIC verifications.
        expect_eq("DMACTL",  u_dut.u_antic_regs.dmactl,  8'h22);
        expect_eq("CHACTL",  u_dut.u_antic_regs.chactl,  8'h02);
        expect_eq("DLISTL",  u_dut.u_antic_regs.dlistl,  8'h00);
        expect_eq("DLISTH",  u_dut.u_antic_regs.dlisth,  8'h40);
        expect_eq("HSCROL",  u_dut.u_antic_regs.hscrol,  8'h05);
        expect_eq("VSCROL",  u_dut.u_antic_regs.vscrol,  8'h0A);
        expect_eq("PMBASE",  u_dut.u_antic_regs.pmbase,  8'h78);
        expect_eq("CHBASE",  u_dut.u_antic_regs.chbase,  8'hE0);
        expect_eq("NMIEN",   u_dut.u_antic_regs.nmien,   8'hC0);

        // Chiplet-ext: mode_snoop is reset-locked to 1 (snoop) and NOT
        // bus-writable, so the $D481 write of 0 above must leave it at 1.
        if (u_dut.u_antic_regs.mode_snoop !== 1'b1) begin
            $display("FAIL MODE_SNOOP: expected 1 (snoop, reset-locked) after $D481 write of 0, got %0d",
                     u_dut.u_antic_regs.mode_snoop);
            fail_count++;
        end

        // cpu_shadow content checks: dropped on the Zynq pivot — the
        // Efinix-era u_cpu_shadow (hyperram_shim) → u_ip (hyperram_phy)
        // hierarchy was stripped from antic_top in 3de7955, so the
        // previous u_dut.u_cpu_shadow.u_ip.mem peeks no longer have a
        // referent.  The dispatch behaviour those peeks verified is
        // now exercised by tb_sally_mem (region routing) and
        // tb_xt_blitter (AXI write reach).

        // M23-stereo: confirm the dual-POKEY DECODE split $D200 from $D210
        // on addr[4] — two left strobes ($D200 ×2 above), one right.
        expect_eq("pokey_l decode strobes", snoop_l_hits[7:0], 8'd2);
        expect_eq("pokey_r decode strobes", snoop_r_hits[7:0], 8'd1);

        // ANTIC audit fix #1: write-only registers must read $FF, not
        // their stored value. Issue read cycles to a representative
        // sample — DMACTL ($D400), CHACTL ($D401), HSCROL ($D404), and
        // PMBASE ($D407) — and confirm bus_data_out comes back $FF.
        // (We just wrote real values to all of these above; the read
        // path must NOT leak the stored value.)
        @(negedge clk_bus);
        bus_addr = 16'hD400;  bus_rw = 1'b1;  d4xx_n = 1'b0;
        @(posedge clk_bus);   // antic_regs read mux is combinational
        if (bus_data_out !== 8'hFF) begin
            $display("FAIL DMACTL readback: $%02x expected $FF (write-only)", bus_data_out);
            fail_count++;
        end
        @(negedge clk_bus);
        bus_addr = 16'hD401;
        @(posedge clk_bus);
        if (bus_data_out !== 8'hFF) begin
            $display("FAIL CHACTL readback: $%02x expected $FF (write-only)", bus_data_out);
            fail_count++;
        end
        @(negedge clk_bus);
        bus_addr = 16'hD404;
        @(posedge clk_bus);
        if (bus_data_out !== 8'hFF) begin
            $display("FAIL HSCROL readback: $%02x expected $FF (write-only)", bus_data_out);
            fail_count++;
        end
        @(negedge clk_bus);
        bus_addr = 16'hD407;
        @(posedge clk_bus);
        if (bus_data_out !== 8'hFF) begin
            $display("FAIL PMBASE readback: $%02x expected $FF (write-only)", bus_data_out);
            fail_count++;
        end
        @(negedge clk_bus);
        bus_addr = 16'hD40D;     // PENV — should also read $FF
        @(posedge clk_bus);
        if (bus_data_out !== 8'hFF) begin
            $display("FAIL PENV readback: $%02x expected $FF (no lightpen)", bus_data_out);
            fail_count++;
        end
        // Restore idle bus state.
        @(negedge clk_bus);
        bus_addr = 16'h0000;  d4xx_n = 1'b1;

        // M23-stereo: exactly one $D21x decode landed (the stereo opt-in
        // latch itself lives with the native pair in fpga_xt_top now).
        if (snoop_r_hits !== 1) begin
            $display("FAIL pokey_r decode after $D21x: expected 1 strobe, got %0d",
                     snoop_r_hits);
            fail_count++;
        end

        if (fail_count == 0) begin
            $display("*** SNOOP OK *** all checks passed");
            $finish;
        end else begin
            $display("*** SNOOP FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    // Watchdog.
    initial begin
        #2_000_000;
        $display("FAIL: tb_snoop watchdog expired"); $fatal(1);
    end

endmodule

`default_nettype wire
