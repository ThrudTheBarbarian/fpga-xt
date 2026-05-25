// tb_hwreg_rd_cdc.sv — unit test for the register-read CDC bridge.
//
// Two asynchronous clocks (clk_sally 100 MHz, clk_sys 150 MHz).  A mock
// combinational responder stands in for antic_top's read mux:
//   bus_rdata = bus_addr[7:0] ^ 8'h5A
// so every served read has a predictable expected value.
//
// Checks: rd_busy asserts the cycle a read is presented, the round-trip
// returns the correct byte, and back-to-back reads to different addresses
// each return their own value (the FSM re-issues per rd_req episode).

`default_nettype none
`timescale 1ns / 1ps

module tb_hwreg_rd_cdc;

    logic clk_sally = 1'b0;
    logic clk_sys   = 1'b0;
    always #5.000 clk_sally = ~clk_sally;   // 100 MHz
    always #3.333 clk_sys   = ~clk_sys;     // ~150 MHz (async ratio)

    logic        rst_sally = 1'b1;
    logic        rst_sys   = 1'b1;

    logic        rd_req  = 1'b0;
    logic [15:0] rd_addr = 16'h0000;
    wire         rd_busy;
    wire [7:0]   rd_data;

    wire [15:0]  bus_addr;
    wire         bus_read;
    // Mock antic_top read mux: combinational on bus_addr.
    wire [7:0]   bus_rdata = bus_addr[7:0] ^ 8'h5A;

    hwreg_rd_cdc u_dut (
        .clk_sally (clk_sally),
        .rst_sally (rst_sally),
        .rd_req    (rd_req),
        .rd_addr   (rd_addr),
        .rd_busy   (rd_busy),
        .rd_data   (rd_data),
        .clk_sys   (clk_sys),
        .rst_sys   (rst_sys),
        .bus_idle  (1'b1),          // no competing write path in this unit test
        .bus_addr  (bus_addr),
        .bus_read  (bus_read),
        .bus_rdata (bus_rdata)
    );

    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Present a hwreg read, wait for the round-trip, return the byte.
    task automatic sally_read(input string label, input [15:0] a);
        logic [7:0] expected;
        int guard;
        expected = a[7:0] ^ 8'h5A;
        @(negedge clk_sally);
        rd_addr = a;
        rd_req  = 1'b1;
        @(posedge clk_sally);
        #1;
        // Stall must engage immediately (data not yet available).
        if (rd_busy !== 1'b1) begin
            $display("FAIL %s: rd_busy did not assert at read start", label);
            fail_count++;
        end
        guard = 0;
        while (rd_busy !== 1'b0) begin
            @(posedge clk_sally);
            guard++;
            if (guard > 1000) begin
                $display("FAIL %s: timeout waiting for rd_busy to clear", label);
                $fatal(1);
            end
        end
        expect_eq(label, rd_data, expected);
        @(negedge clk_sally);
        rd_req = 1'b0;
        repeat (4) @(posedge clk_sally);   // let the FSM disarm
    endtask

    initial begin
        $display("=== HWREG_RD_CDC TEST ===");
        repeat (4) @(posedge clk_sally);
        rst_sally = 1'b0;
        rst_sys   = 1'b0;
        repeat (4) @(posedge clk_sally);

        // Idle: no request -> not busy.
        expect_eq("idle.busy", rd_busy, 1'b0);

        // Representative boot-critical register addresses.
        sally_read("D01F CONSOL", 16'hD01F);
        sally_read("D209 KBCODE", 16'hD209);
        sally_read("D20E IRQST",  16'hD20E);
        sally_read("D301 PORTB",  16'hD301);
        sally_read("D40B VCOUNT", 16'hD40B);

        // Back-to-back, distinct addresses (re-issue per episode).
        sally_read("BB.00", 16'hD000);
        sally_read("BB.FF", 16'hD0FF);
        sally_read("BB.55", 16'hD255);

        if (fail_count == 0) begin
            $display("*** HWREG_RD_CDC OK *** round-trip + stall + re-issue");
            $finish;
        end else begin
            $display("*** HWREG_RD_CDC FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #500_000;
        $display("FAIL: tb_hwreg_rd_cdc watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
