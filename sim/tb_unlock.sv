// tb_unlock.sv — XT register-unlock mirror-conditional decode (antic_regs).
//
// Exercises the ANTIC_CHIPLET gate (docs/Zynq/register-unlock.md): when
// unlock_antic=1 the $D480-$D4FF chiplet registers are live; when 0 they fall
// back to the plain ANTIC 16-byte mirror of $D400-$D40F, for BOTH writes and
// reads.  This is the "one piece needing care" — verify it directly:
//
//   unlocked: $D483 write latches PAL_R; $D483 read returns it.
//   locked:   $D483 write decodes as the mirror $D403 (DLISTH); $D483 read
//             returns $FF (write-only mirror); the chiplet PAL_R is untouched.

`default_nettype none
`timescale 1ns / 1ps

module tb_unlock;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    logic        we    = 1'b0;
    logic [7:0]  waddr = 8'h0;
    logic [7:0]  wdata = 8'h0;
    logic [7:0]  raddr = 8'h0;
    wire  [7:0]  rdata;
    logic        unlock_antic  = 1'b1;
    logic        unlock_sprite = 1'b1;
    logic        unlock_blit   = 1'b1;

    wire         wsync_pending, nmires_strobe, pal_write_strobe;
    wire  [7:0]  pal_r_q, pal_g_q, pal_b_q, pal_idx_q;
    wire  [7:0]  nmien_q, dmactl_q, chactl_q, dlistl_q, dlisth_q;
    wire  [7:0]  hscrol_q, vscrol_q, pmbase_q, chbase_q;
    wire         mode_snoop_q, cpu_internal_q;
    wire  [7:0]  clock_mult_q, output_mode_q;
    wire  [15:0] os_rom_addr_q;
    wire  [7:0]  os_rom_data_q;
    wire         os_rom_we, os_rom_locked_q;

    antic_regs u_dut (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata),
        .wsync_pending(wsync_pending),
        .nmires_strobe(nmires_strobe),
        .pal_write_strobe(pal_write_strobe),
        .pal_r_q(pal_r_q), .pal_g_q(pal_g_q),
        .pal_b_q(pal_b_q), .pal_idx_q(pal_idx_q),
        .dmactl_q(dmactl_q), .chactl_q(chactl_q),
        .dlistl_q(dlistl_q), .dlisth_q(dlisth_q),
        .hscrol_q(hscrol_q), .vscrol_q(vscrol_q),
        .pmbase_q(pmbase_q), .chbase_q(chbase_q),
        .nmien_q(nmien_q),
        .mode_snoop_q(mode_snoop_q),
        .cpu_internal_q(cpu_internal_q),
        .clock_mult_q(clock_mult_q),
        .output_mode_q(output_mode_q),
        .os_rom_addr_q(os_rom_addr_q),
        .os_rom_data_q(os_rom_data_q),
        .os_rom_we(os_rom_we),
        .os_rom_locked_q(os_rom_locked_q),
        .vcount_in(8'h00),
        .nmist_in(8'h00),
        .serial_clock_mult_in(8'h00),
        .bus_rd4_in(1'b1), .bus_rd5_in(1'b1),
        .bus_mpd_n_in(1'b1), .bus_extirq_n_in(1'b1),
        .unlock_antic(unlock_antic),
        .unlock_sprite(unlock_sprite),
        .unlock_blit(unlock_blit)
    );

    int fails = 0;

    task automatic write_reg(input logic [7:0] a, input logic [7:0] d);
        @(negedge clk);
        waddr <= a; wdata <= d; we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        we <= 1'b0;
    endtask

    task automatic check(input string tag, input logic [7:0] got,
                         input logic [7:0] exp);
        if (got !== exp) begin
            $display("[%-22s] FAIL got $%02h expected $%02h", tag, got, exp);
            fails++;
        end else begin
            $display("[%-22s] ok  $%02h", tag, got);
        end
    endtask

    // Combinational read: drive raddr, settle, compare rdata.
    task automatic rd_check(input string tag, input logic [7:0] a,
                            input logic [7:0] exp);
        raddr = a;
        #1;
        check(tag, rdata, exp);
    endtask

    initial begin
        $display("[unlock] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ---- UNLOCKED: chiplet registers live --------------------------
        unlock_antic = 1'b1;
        write_reg(8'h83, 8'hAA);            // $D483 PAL_R
        write_reg(8'h82, 8'h3C);            // $D482 OUTPUT_MODE
        rd_check("unlocked $D483 read",  8'h83, 8'hAA);
        check   ("unlocked PAL_R_q",     pal_r_q,       8'hAA);
        rd_check("unlocked $D482 read",  8'h82, 8'h3C);
        check   ("unlocked OUTPUT_MODE", output_mode_q, 8'h3C);

        // ---- LOCKED: $D483/$D482 become the ANTIC mirror ---------------
        // $D483 -> canonical $D403 = DLISTH (write-only); $D482 -> $D402 = DLISTL.
        unlock_antic = 1'b0;
        write_reg(8'h83, 8'h55);            // should land in DLISTH, NOT PAL_R
        write_reg(8'h82, 8'h99);            // should land in DLISTL, NOT OUTPUT_MODE
        check("locked DLISTH write",   dlisth_q,            8'h55);
        check("locked DLISTL write",   dlistl_q,            8'h99);
        check   ("locked PAL_R untouched", pal_r_q,       8'hAA);  // chiplet reg preserved
        check   ("locked OUTMODE untouchd",output_mode_q, 8'h3C);
        rd_check("locked $D483 read=mirror", 8'h83, 8'hFF); // DLISTH write-only -> $FF
        rd_check("locked $D481 read=mirror", 8'h81, 8'hFF); // CHACTL write-only -> $FF
        // Canonical $D40x still works while locked (never gated):
        write_reg(8'h00, 8'h22);            // $D400 DMACTL
        check   ("locked DMACTL canon",   dmactl_q,       8'h22);

        // ---- RE-UNLOCK: chiplet state survived the locked window -------
        unlock_antic = 1'b1;
        rd_check("re-unlocked $D483 read", 8'h83, 8'hAA);
        check   ("re-unlocked PAL_R_q",    pal_r_q,       8'hAA);

        // ---- PER-GROUP MIRROR: the bug the user hit (0xFB = BLITTER locked,
        // ANTIC/SPRITE still live).  $D4Cx must be the STOCK ANTIC MIRROR for the
        // 6502, NOT a dead chiplet read.  $D4C3 -> canonical $D403 = DLISTH. -----
        unlock_antic = 1'b1; unlock_sprite = 1'b1; unlock_blit = 1'b0;  // 0xFB
        write_reg(8'hC3, 8'h77);             // $D4C3 (blitter slice) -> DLISTH mirror
        check   ("BLITlock $D4C3=DLISTH mirror", dlisth_q,         8'h77);
        rd_check("BLITlock $D4C3 read=mirror",   8'hC3,            8'hFF); // DLISTH WO -> $FF
        rd_check("BLITlock $D4CB read=VCOUNT",   8'hCB,            8'h00); // $D40B VCOUNT (vcount_in=0)
        // ANTIC slice still live in the same 0xFB state (its lock is independent):
        write_reg(8'h83, 8'hE1);             // $D483 PAL_R — chiplet, NOT a mirror
        check   ("BLITlock $D483=PAL_R (live)",  pal_r_q,          8'hE1);
        // Flip it: unlock BLITTER → $D4C3 is the blitter's again (chiplet-ignored here):
        unlock_blit = 1'b1;
        rd_check("BLITunlock $D4C3 read=chiplet", 8'hC3,           8'h00); // claimed -> chiplet default

        if (fails == 0)
            $display("*** UNLOCK OK *** mirror-conditional chiplet decode verified");
        else
            $display("*** UNLOCK FAIL *** %0d failures", fails);
        if (fails != 0) $fatal(1);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_unlock watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
