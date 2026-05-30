// tb_wsync.sv — M13 WSYNC / RDY verification.
//
// Stack: antic_regs (for wsync_pending) + wsync_gen (for /RDY).
// Drives the bus to write $D40A at chosen offsets within a synthesised
// "scanline" and asserts /RDY tracks the wsync_pending → line_start
// release window.

`default_nettype none
`timescale 1ns / 1ps

`include "bus_opcodes.vh"

module tb_wsync;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;

    // ---- antic_regs ---------------------------------------------------
    logic        we    = 1'b0;
    logic [7:0]  waddr = 8'h0;
    logic [7:0]  wdata = 8'h0;
    wire  [7:0]  rdata;
    wire         wsync_pending;
    wire         nmires_strobe;
    wire  [7:0]  nmien_q;
    wire  [7:0]  dmactl_q, chactl_q, dlistl_q, dlisth_q;
    wire  [7:0]  hscrol_q, vscrol_q, pmbase_q, chbase_q;
    wire         mode_snoop_q;
    wire  [7:0]  clock_mult_q, output_mode_q;

    antic_regs u_antic_regs (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .wdata(wdata),
        .raddr(8'h00), .rdata(rdata),
        .wsync_pending(wsync_pending),
        .nmires_strobe(nmires_strobe),
        .dmactl_q(dmactl_q), .chactl_q(chactl_q),
        .dlistl_q(dlistl_q), .dlisth_q(dlisth_q),
        .hscrol_q(hscrol_q), .vscrol_q(vscrol_q),
        .pmbase_q(pmbase_q), .chbase_q(chbase_q),
        .nmien_q(nmien_q),
        .mode_snoop_q(mode_snoop_q),
        .clock_mult_q(clock_mult_q),
        .output_mode_q(output_mode_q),
        .vcount_in(8'h00),
        .nmist_in(8'h00),
        .serial_clock_mult_in(8'h00)
    );

    // ---- wsync_gen ----------------------------------------------------
    logic        line_start = 1'b0;
    wire         rdy_n;
    wire  [31:0] overdue;

    wsync_gen u_wsync_gen (
        .clk(clk), .rst(rst),
        .wsync_pending(wsync_pending),
        .line_start(line_start),
        .rdy_n(rdy_n),
        .wsync_overdue_count(overdue)
    );

    task automatic write_reg(input logic [7:0] a, input logic [7:0] d);
        @(negedge clk);
        waddr <= a; wdata <= d; we <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        we <= 1'b0;
    endtask

    task automatic pulse_line();
        @(negedge clk);
        line_start <= 1'b1;
        @(posedge clk);
        @(negedge clk);
        line_start <= 1'b0;
    endtask

    int fail_count = 0;

    task automatic expect_b(input string tag,
                             input logic got,
                             input logic expected);
        if (got !== expected) begin
            $display("[%s] FAIL got %b expected %b", tag, got, expected);
            fail_count++;
        end
    endtask

    initial begin
        $display("[wsync] start");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // ===== Phase 1: idle — /RDY high, no overdue ======================
        @(negedge clk);
        expect_b("p1/idle", rdy_n, 1'b1);
        if (overdue !== 32'h0) begin
            $display("[p1/overdue] FAIL got $%08h expected 0", overdue);
            fail_count++;
        end

        // ===== Phase 2: WSYNC write asserts /RDY low ======================
        write_reg(8'h0A, 8'h00);
        @(negedge clk);
        expect_b("p2/asserted", rdy_n, 1'b0);

        // Wait a few cycles, /RDY should remain low.
        repeat (10) @(posedge clk);
        @(negedge clk);
        expect_b("p2/still-low", rdy_n, 1'b0);

        // line_start releases /RDY.
        pulse_line();
        @(negedge clk);
        expect_b("p2/released", rdy_n, 1'b1);

        // Subsequent line_start without WSYNC: /RDY stays high.
        pulse_line();
        @(negedge clk);
        expect_b("p2/idle-line", rdy_n, 1'b1);

        // ===== Phase 3: WSYNC pulse + line_start same cycle → set wins ====
        // antic_regs adds 1 cycle of delay between the $D40A write and
        // the wsync_pending pulse, so to land them coincidently at
        // wsync_gen we issue the write first, then pulse line_start on
        // the cycle wsync_pending fires.
        @(negedge clk);
        waddr <= 8'h0A; wdata <= 8'h00; we <= 1'b1;
        @(posedge clk);     // write captured; wsync_pending will be 1 at next posedge
        @(negedge clk);
        we         <= 1'b0;
        line_start <= 1'b1; // visible on the next posedge alongside wsync_pending=1
        @(posedge clk);
        @(negedge clk);
        line_start <= 1'b0;
        // wsync_gen's set-wins rule: WSYNC dominates the same-cycle
        // line_start, so /RDY stays low.
        expect_b("p3/coincident", rdy_n, 1'b0);

        // Next pulse_line with wsync_pending=0 should release.
        pulse_line();
        @(negedge clk);
        expect_b("p3/released", rdy_n, 1'b1);

        // ===== Phase 4: overdue counter ====================================
        // Issue WSYNC, then withhold line_start past OVERDUE_THRESHOLD
        // (default 256 clk_bus cycles in wsync_gen).
        write_reg(8'h0A, 8'h00);
        repeat (300) @(posedge clk);
        @(negedge clk);
        if (overdue === 32'h0) begin
            $display("[p4/overdue] FAIL counter never advanced (got %0d)",
                     overdue);
            fail_count++;
        end
        // Release.
        pulse_line();
        @(negedge clk);
        expect_b("p4/released", rdy_n, 1'b1);

        if (fail_count == 0) begin
            $display("*** WSYNC OK *** assert / release / coincident / overdue verified (overdue=%0d)",
                     overdue);
            $finish;
        end else begin
            $display("*** WSYNC FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_wsync watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
