// tb_pia_irq.sv — replay the ACID800 pia_irq CA2/CB2 test vectors
// against pia_regs. Each vector is four control-register writes followed
// by a control-register readback (expected value includes the IRQ flag in
// bit 6) and the expected CPU /IRQ state after write 4.
//
// Vectors are Avery Lee's, from rsrc/acid800/Acid800/standalone/pia_irq.lst
// (testvec_b at $23BF, testvec_a at $23F6). Port B exercises the pending /
// conversion / clear rules; port A adds the edge-select-on-entry rules.

`timescale 1ns/1ps
`default_nettype none

module tb_pia_irq;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;

    logic        we = 0;
    logic [15:0] waddr = '0;
    logic [7:0]  wdata = '0;
    logic [15:0] raddr = 16'hD3FF;   // parked outside the data regs
    wire  [7:0]  rdata;
    wire         pia_irq_n;

    pia_regs dut (
        .clk (clk), .rst (rst),
        .we (we), .waddr (waddr), .wdata (wdata),
        .raddr (raddr), .rdata (rdata),
        .joy_porta_in (8'hFF), .joy_portb_in (8'hFF),
        .joy_porta_out (), .joy_porta_oe (),
        .joy_portb_out (), .joy_portb_oe (),
        .portb_out_q (),
        .pia_irq_n (pia_irq_n)
    );

    int errors = 0;

    task automatic ctl_write(input [15:0] a, input [7:0] d);
        @(negedge clk); we = 1; waddr = a; wdata = d;
        @(negedge clk); we = 0;
    endtask

    // Clear any latched flag + return the port to the reset-ish state by
    // reading the data register, then parking both controls at $00.
    task automatic vec_reset(input [15:0] ctl_addr, input [15:0] data_addr);
        ctl_write(16'hD302, 8'h04);      // port A input mode
        ctl_write(16'hD303, 8'h04);      // port B input mode
        raddr = 16'hD300; repeat (2) @(negedge clk);   // PORTA read clears IRQA2
        raddr = 16'hD301; repeat (2) @(negedge clk);   // PORTB read clears IRQB2
        raddr = 16'hD3FF; @(negedge clk);
        ctl_write(16'hD302, 8'h00);
        ctl_write(16'hD303, 8'h00);
    endtask

    task automatic run_vec(input string tag, input [15:0] ctl_addr,
                           input [15:0] data_addr,
                           input [7:0] w1, w2, w3, w4,
                           input [7:0] exp_rd, input bit exp_irq);
        logic [7:0] got;
        vec_reset(ctl_addr, data_addr);
        ctl_write(ctl_addr, w1);
        ctl_write(ctl_addr, w2);
        ctl_write(ctl_addr, w3);
        ctl_write(ctl_addr, w4);
        raddr = ctl_addr; @(negedge clk); got = rdata; raddr = 16'hD3FF;
        if (got !== exp_rd) begin
            $display("FAIL %s [%02x %02x %02x %02x]: CTL read %02x != %02x",
                     tag, w1, w2, w3, w4, got, exp_rd);
            errors++;
        end
        if (pia_irq_n !== ~exp_irq) begin
            $display("FAIL %s [%02x %02x %02x %02x]: irq_n %b != %b",
                     tag, w1, w2, w3, w4, pia_irq_n, ~exp_irq);
            errors++;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk); rst = 0; repeat (2) @(negedge clk);

        // ---- Port B (PBCTL = $D303, PORTB = $D301) ------------------
        // IRQB2 flag on input mode; the choice of input mode doesn't matter.
        run_vec("B1", 16'hD303, 16'hD301, 8'h34,8'h3c,8'h3c,8'h04, 8'h44, 0);
        run_vec("B2", 16'hD303, 16'hD301, 8'h34,8'h3c,8'h3c,8'h0c, 8'h4c, 1);
        run_vec("B3", 16'hD303, 16'hD301, 8'h34,8'h3c,8'h04,8'h04, 8'h44, 0);
        // Any output mode clears IRQB2.
        run_vec("B4", 16'hD303, 16'hD301, 8'h34,8'h3c,8'h04,8'h24, 8'h24, 0);
        // Handshake can sit between $34:$3C; pulse or input mode cannot.
        run_vec("B5", 16'hD303, 16'hD301, 8'h34,8'h24,8'h3c,8'h04, 8'h44, 0);
        run_vec("B6", 16'hD303, 16'hD301, 8'h34,8'h28,8'h3c,8'h04, 8'h04, 0);
        run_vec("B7", 16'hD303, 16'hD301, 8'h34,8'h04,8'h3c,8'h04, 8'h04, 0);
        // High-low-high does not work.
        run_vec("B8", 16'hD303, 16'hD301, 8'h34,8'h3c,8'h34,8'h04, 8'h04, 0);
        run_vec("B9", 16'hD303, 16'hD301, 8'h3c,8'h34,8'h3c,8'h04, 8'h44, 0);

        // ---- Port A (PACTL = $D302, PORTA = $D300) ------------------
        // IRQA2 needs the line forced low then a rising-select input mode;
        // the line may be raised in any pattern as long as it went low.
        run_vec("A1", 16'hD302, 16'hD300, 8'h3c,8'h3c,8'h3c,8'h14, 8'h14, 0);
        run_vec("A2", 16'hD302, 16'hD300, 8'h3c,8'h3c,8'h34,8'h14, 8'h54, 0);
        run_vec("A3", 16'hD302, 16'hD300, 8'h3c,8'h34,8'h3c,8'h14, 8'h54, 0);
        run_vec("A4", 16'hD302, 16'hD300, 8'h3c,8'h34,8'h3c,8'h1c, 8'h5c, 1);
        run_vec("A5", 16'hD302, 16'hD300, 8'h34,8'h34,8'h34,8'h04, 8'h04, 0);
        // Pulse mode clears the pending transition; handshake does not.
        run_vec("A6", 16'hD302, 16'hD300, 8'h34,8'h34,8'h2c,8'h14, 8'h14, 0);
        run_vec("A7", 16'hD302, 16'hD300, 8'h34,8'h34,8'h24,8'h14, 8'h54, 0);
        // Any output mode clears IRQA2/IRQB2.
        run_vec("A8", 16'hD302, 16'hD300, 8'h34,8'h34,8'h14,8'h34, 8'h34, 0);

        // Flag clears on a DATA-register read (and only then).
        ctl_write(16'hD303, 8'h34);
        ctl_write(16'hD303, 8'h3c);
        ctl_write(16'hD303, 8'h04);
        raddr = 16'hD303; @(negedge clk);
        if (rdata !== 8'h44) begin $display("FAIL RD1: CTL read %02x != 44 (ctl read must NOT clear)", rdata); errors++; end
        raddr = 16'hD301; repeat (2) @(negedge clk);   // PORTB data read
        raddr = 16'hD303; @(negedge clk);
        if (rdata !== 8'h04) begin $display("FAIL RD2: CTL read %02x != 04 after data read", rdata); errors++; end
        raddr = 16'hD3FF;

        if (errors == 0) $display("*** PIA IRQ OK ***");
        else             $display("*** PIA IRQ FAILED: %0d errors ***", errors);
        $finish;
    end

endmodule

`default_nettype wire
