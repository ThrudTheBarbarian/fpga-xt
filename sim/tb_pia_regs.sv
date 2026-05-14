// tb_pia_regs.sv — M25-1 PIA shadow unit test.
//
// Exercises the $D300-$D37F PIA register file in isolation (no
// antic_top). Drives `we`/`waddr`/`wdata` directly (stand-in for
// bus_snoop output) and reads back via `raddr`/`rdata`. Joystick
// pins driven via task-level pokes.
//
// Coverage:
//   - Reset defaults: PORTB output latch = $FF (matches Atari boot
//     state where banking is disabled), PACTL/PBCTL = 0.
//   - PORTA/PORTB read in port mode: returns joy_*_in pin state.
//   - PORTA/PORTB read in DDR mode: returns the DDR latch.
//   - PORTA/PORTB writes route to DDR / output latch per PACTL[2] /
//     PBCTL[2].
//   - PORTB write always updates portb_out_q (130XE banking semantics).
//   - PACTL / PBCTL round-trip.
//   - $D300-$D303 mirrors every 4 bytes through $D37F.
//   - Out-of-window writes are ignored.

`default_nettype none
`timescale 1ns / 1ps

module tb_pia_regs;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic        we    = 1'b0;
    logic [15:0] waddr = 16'h0000;
    logic [7:0]  wdata = 8'h00;

    logic [15:0] raddr = 16'h0000;
    wire  [7:0]  rdata;

    logic [7:0]  joy_porta_in = 8'hFF;
    logic [7:0]  joy_portb_in = 8'hFF;
    wire  [7:0]  joy_porta_out, joy_porta_oe;
    wire  [7:0]  joy_portb_out, joy_portb_oe;
    wire  [7:0]  portb_out_q;

    pia_regs u_dut (
        .clk           (clk),
        .rst           (rst),
        .we            (we),
        .waddr         (waddr),
        .wdata         (wdata),
        .raddr         (raddr),
        .rdata         (rdata),
        .joy_porta_in  (joy_porta_in),
        .joy_portb_in  (joy_portb_in),
        .joy_porta_out (joy_porta_out),
        .joy_porta_oe  (joy_porta_oe),
        .joy_portb_out (joy_portb_out),
        .joy_portb_oe  (joy_portb_oe),
        .portb_out_q   (portb_out_q)
    );

    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input logic [7:0] got, input logic [7:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%02h expected=$%02h", label, got, want);
            fail_count++;
        end
    endtask

    task automatic do_write(input logic [15:0] a, input logic [7:0] d);
        @(negedge clk);
        we    = 1'b1;
        waddr = a;
        wdata = d;
        @(posedge clk);
        @(negedge clk);
        we    = 1'b0;
        waddr = 16'h0000;
        wdata = 8'h00;
        @(posedge clk);   // settle one cycle so write commits
    endtask

    task automatic do_read(input logic [15:0] a, output logic [7:0] v);
        @(negedge clk);
        raddr = a;
        @(posedge clk);
        #1;
        v = rdata;
    endtask

    initial begin
        $display("=== M25-1 pia_regs ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Reset defaults — portb latch should be $FF (banking disabled),
        // PACTL/PBCTL = $00 (DDR mode by default — matches a 6520 reset).
        expect_eq("reset.portb_out", portb_out_q, 8'hFF);
        begin
            logic [7:0] v;
            do_read(16'hD302, v); expect_eq("reset.PACTL", v, 8'h00);
            do_read(16'hD303, v); expect_eq("reset.PBCTL", v, 8'h00);
        end

        // ---- PORTA in DDR mode (PACTL[2]=0): writes go to DDRA. ----
        do_write(16'hD300, 8'h55);
        begin
            logic [7:0] v;
            do_read(16'hD300, v); expect_eq("DDR.PORTA-readback", v, 8'h55);
        end

        // ---- Switch PACTL to port mode (bit 2 = 1) ----
        do_write(16'hD302, 8'h04);   // PACTL[2]=1
        begin
            logic [7:0] v;
            do_read(16'hD302, v); expect_eq("PACTL.set", v, 8'h04);
        end

        // ---- PORTA read now returns joy_porta_in. ----
        joy_porta_in = 8'h7E;
        @(posedge clk);
        begin
            logic [7:0] v;
            do_read(16'hD300, v); expect_eq("port.PORTA", v, 8'h7E);
        end

        // ---- PORTB writes always latch portb_out_q (130XE banking). ----
        do_write(16'hD301, 8'h11);
        expect_eq("portb.banking-latch.11", portb_out_q, 8'h11);
        do_write(16'hD301, 8'hC3);
        expect_eq("portb.banking-latch.C3", portb_out_q, 8'hC3);

        // PORTB read in DDR mode (PBCTL[2]=0 still) returns DDRB —
        // which got loaded from the recent PORTB write because in DDR
        // mode the same write commits to DDRB. Last write was $C3.
        begin
            logic [7:0] v;
            do_read(16'hD301, v); expect_eq("DDR.PORTB", v, 8'hC3);
        end

        // ---- Switch PBCTL to port mode and read joy_portb_in. ----
        do_write(16'hD303, 8'h04);
        joy_portb_in = 8'hA5;
        @(posedge clk);
        begin
            logic [7:0] v;
            do_read(16'hD301, v); expect_eq("port.PORTB", v, 8'hA5);
        end

        // PORTB writes in port mode still update portb_out_q (banking).
        do_write(16'hD301, 8'h0F);
        expect_eq("portb.banking-port-mode", portb_out_q, 8'h0F);

        // ---- $D300-$D303 mirrors through $D37F. ----
        // Mirror at $D305 = $D301.
        do_write(16'hD305, 8'hFE);
        expect_eq("portb.mirror.D305", portb_out_q, 8'hFE);
        // Mirror at $D37F = PBCTL ($D303).
        do_write(16'hD37F, 8'h00);   // back to DDR mode
        begin
            logic [7:0] v;
            do_read(16'hD377, v);    // PBCTL via mirror
            expect_eq("PBCTL.mirror.D377", v, 8'h00);
        end

        // ---- Bidirectional joystick pin output (XEP80 / mouse / etc.) ----
        // PORTA pins are bidirectional per-bit. Set DDRA = $0F (lower
        // nibble outputs, upper nibble inputs); switch to port mode;
        // write PORTA = $A5; verify joy_porta_oe matches DDRA when in
        // port mode and joy_porta_out matches the latched PORTA value.
        do_write(16'hD302, 8'h00);   // PACTL DDR mode
        do_write(16'hD300, 8'h0F);   // DDRA = $0F (outs in low nibble)
        do_write(16'hD302, 8'h04);   // back to port mode
        do_write(16'hD300, 8'hA5);   // PORTA out latch = $A5
        expect_eq("joy_porta_out.A5",   joy_porta_out, 8'hA5);
        expect_eq("joy_porta_oe.0F",    joy_porta_oe,  8'h0F);
        // Switching PACTL[2]=0 (DDR mode) drops the FPGA-side OE — the
        // pin floats from the FPGA's perspective so software can read
        // back the DDR latch on the bus without fighting the line.
        do_write(16'hD302, 8'h00);
        expect_eq("joy_porta_oe.DDRmode", joy_porta_oe, 8'h00);
        // Restore port mode.
        do_write(16'hD302, 8'h04);

        // PORTB the same shape — but PORTB writes always commit to the
        // banking latch (portb_out_q) regardless of mode, so we run
        // the bidir check via PBCTL rather than DDRB.
        do_write(16'hD303, 8'h00);   // PBCTL DDR mode
        do_write(16'hD301, 8'hF0);   // DDRB = $F0 (outs in high nibble)
        do_write(16'hD303, 8'h04);   // back to port mode
        do_write(16'hD301, 8'h5A);   // PORTB out latch = $5A
        expect_eq("joy_portb_out.5A",   joy_portb_out, 8'h5A);
        expect_eq("joy_portb_oe.F0",    joy_portb_oe,  8'hF0);

        // ---- Out-of-window writes are ignored. ----
        // $D380 lands in cache_regs territory — pia_regs must NOT
        // touch portb_out_q from a write there.
        begin
            logic [7:0] portb_before;
            portb_before = portb_out_q;
            do_write(16'hD380, 8'h00);     // would clobber if we mis-decoded
            expect_eq("oow.D380.portb-untouched", portb_out_q, portb_before);
        end

        if (fail_count == 0) begin
            $display("*** PIA_REGS OK *** all checks passed");
            $finish;
        end else begin
            $display("*** PIA_REGS FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_pia_regs watchdog");
        $fatal(1);
    end

endmodule
