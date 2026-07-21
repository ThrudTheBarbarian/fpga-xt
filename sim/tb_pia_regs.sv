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
//   - PORTA/PORTB read in port mode: pin level — output bits (DDR=1)
//     read the driven output latch, input bits read joy_*_in.
//   - PORTA/PORTB read in DDR mode: returns the DDR latch.
//   - PORTA/PORTB writes route to DDR / output latch per PACTL[2] /
//     PBCTL[2] (real PIA — DDR-mode writes do NOT touch the latch).
//   - PORTB write updates portb_out_q (130XE banking) in port mode.
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

        // ---- PACTL / PBCTL IRQ-flag mask (ACID800 pia_irq) ----
        // The top two bits of PACTL/PBCTL are read-only IRQ-status flags.
        // Writing $FF sets only the control bits [5:0]; a read masks the
        // status bits (no CA1/CA2 edge source wired → they read 0), so
        // $FF must read back $3F — NOT $FF.
        begin
            logic [7:0] v;
            do_write(16'hD302, 8'hFF);
            do_read(16'hD302, v); expect_eq("PACTL.FF-masks-3F", v, 8'h3F);
            do_write(16'hD303, 8'hFF);
            do_read(16'hD303, v); expect_eq("PBCTL.FF-masks-3F", v, 8'h3F);
            // A mid-range control value keeps its low 6 bits and clears [7:6].
            do_write(16'hD302, 8'hC5);   // $C5 -> read $05
            do_read(16'hD302, v); expect_eq("PACTL.C5-masks-05", v, 8'h05);
            // Restore port mode for the checks that follow.
            do_write(16'hD302, 8'h04);
        end

        // ---- ACID800 pia_irq: CA2 output->input edge sets IRQA2 (bit 6) ----
        // Replays the pia_irq "turn on IRQA2 flag" sequence:
        //   PACTL $34 (CA2 output LOW) -> $3C (output HIGH) -> $14 (input,
        //   low->high edge select).  The $34->$3C low->high output edge
        //   arms IRQA2; reading PACTL must return $54 (bit6 set | $14).
        //   Then: a DDRA read (PACTL DDR-mode read) must NOT clear bit 6,
        //   but a PORTA data read ($D300) MUST clear it.
        begin
            logic [7:0] v;
            do_write(16'hD302, 8'h34);      // CA2 output low
            do_write(16'hD302, 8'h3C);      // CA2 output high  (low->high edge)
            do_write(16'hD302, 8'h14);      // CA2 input, low->high select
            do_read(16'hD302, v); expect_eq("pia_irq.IRQA2-set.54", v, 8'h54);

            // Reading PACTL again (and putting PORTA into DDR mode) must not
            // clear IRQA2: write $00 (control), read PACTL -> $40.
            do_write(16'hD302, 8'h00);      // control write (input mode) keeps flag
            do_read(16'hD302, v); expect_eq("pia_irq.IRQA2-DDRread-keeps.40", v, 8'h40);

            // A read of the PORTA DATA register ($D300) clears IRQA2.
            do_write(16'hD302, 8'h04);      // port mode so $D300 reads the data reg
            do_read(16'hD300, v);           // PORTA data read -> clears bit 6
            do_read(16'hD302, v); expect_eq("pia_irq.IRQA2-PORTAread-clears.04", v, 8'h04);

            // Symmetric CB2 / IRQB2 (PBCTL) check: same dance, PORTB read clears.
            do_write(16'hD303, 8'h34);
            do_write(16'hD303, 8'h3C);
            do_write(16'hD303, 8'h14);
            do_read(16'hD303, v); expect_eq("pia_irq.IRQB2-set.54", v, 8'h54);
            do_write(16'hD303, 8'h04);      // port mode so $D301 reads the data reg
            do_read(16'hD301, v);           // PORTB data read -> clears bit 6
            do_read(16'hD303, v); expect_eq("pia_irq.IRQB2-PORTBread-clears.04", v, 8'h04);

            // Restore control regs to port mode for the checks that follow.
            do_write(16'hD302, 8'h04);
            do_write(16'hD303, 8'h04);
        end

        // ---- PORTA read in port mode returns the PIN: an OUTPUT bit (DDRA=1)
        //      reads the driven output latch, an INPUT bit reads joy_porta_in.
        //      Set DDRA=$00 (all inputs) so this reads pure joy_porta_in. ----
        do_write(16'hD302, 8'h00);   // PACTL DDR mode
        do_write(16'hD300, 8'h00);   // DDRA = $00 (all inputs)
        do_write(16'hD302, 8'h04);   // PACTL port mode
        joy_porta_in = 8'h7E;
        @(posedge clk);
        begin
            logic [7:0] v;
            do_read(16'hD300, v); expect_eq("port.PORTA", v, 8'h7E);
        end

        // ---- PORTB write latches portb_out_q ONLY in port mode (real PIA;
        //      130XE banking writes $D301 in port mode after OS init). ----
        do_write(16'hD303, 8'h04);   // PBCTL port mode (bit 2 = 1)
        do_write(16'hD301, 8'h11);
        expect_eq("portb.banking-latch.11", portb_out_q, 8'h11);
        do_write(16'hD301, 8'hC3);
        expect_eq("portb.banking-latch.C3", portb_out_q, 8'hC3);

        // ---- PORTB write in DDR mode goes to DDRB, NOT the output latch;
        //      reading $D301 in DDR mode returns DDRB.  The banking latch
        //      (portb_out_q) stays at its last port-mode value ($C3) — this
        //      is what lets the XL OS IHW1 init clear the $D3xx page in DDR
        //      mode without switching the OS ROM off. ----
        do_write(16'hD303, 8'h00);   // PBCTL DDR mode
        do_write(16'hD301, 8'h3C);   // DDRB = $3C
        begin
            logic [7:0] v;
            do_read(16'hD301, v); expect_eq("DDR.PORTB", v, 8'h3C);
        end
        expect_eq("portb.latch-untouched-in-DDR", portb_out_q, 8'hC3);

        // ---- PORTB read in port mode with DDRB=$00 returns joy_portb_in. ----
        do_write(16'hD301, 8'h00);   // DDRB = $00 (still DDR mode → all inputs)
        do_write(16'hD303, 8'h04);   // PBCTL port mode
        joy_portb_in = 8'hA5;
        @(posedge clk);
        begin
            logic [7:0] v;
            do_read(16'hD301, v); expect_eq("port.PORTB", v, 8'hA5);
        end

        // PORTB write in port mode updates portb_out_q (banking).
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

        // PORTB the same shape: a DDR-mode write sets DDRB, a port-mode
        // write sets the output latch (= portb_out_q banking value).
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
