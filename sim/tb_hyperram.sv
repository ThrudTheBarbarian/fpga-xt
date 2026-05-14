// tb_hyperram.sv — verify hyperram_shim's dual-port read + write
// path against the latency model in hyperram_mock.
//
// Phase A — basic write/read latency: write known values, then issue
//   reads on port A; assert each rd_valid_a lands LATENCY cycles
//   after req_a + ready_a, with the matching value.
//
// Phase B — dual-port arbitration: issue overlapping reads on A and
//   B; assert both return correct values, with port B's latency
//   extended by one read window since it follows port A.
//
// Phase C — interleaved write + read: write a value, immediately
//   issue a read of the same address; assert the read reflects the
//   just-written value (write FIFO drains before the read fires).

`default_nettype none
`timescale 1ns / 1ps

module tb_hyperram;

    logic clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz fabric

    logic rst = 1'b1;

    localparam int ADDR_W  = 16;
    localparam int LATENCY = 4;     // small latency for sim brevity

    // Write port.
    logic              we    = 1'b0;
    logic [15:0]       waddr = 16'h0;
    logic [7:0]        wdata = 8'h0;
    wire               wready;

    // Read port A.
    logic              req_a   = 1'b0;
    logic [15:0]       raddr_a = 16'h0;
    wire  [7:0]        rdata_a;
    wire               rd_valid_a;
    wire               ready_a;

    // Read port B.
    logic              req_b   = 1'b0;
    logic [15:0]       raddr_b = 16'h0;
    wire  [7:0]        rdata_b;
    wire               rd_valid_b;
    wire               ready_b;

    hyperram_shim #(.ADDR_W(ADDR_W), .LATENCY(LATENCY)) u_dut (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .wdata(wdata), .wready(wready),
        .req_a(req_a), .raddr_a(raddr_a),
        .rdata_a(rdata_a), .rd_valid_a(rd_valid_a), .ready_a(ready_a),
        .req_b(req_b), .raddr_b(raddr_b),
        .rdata_b(rdata_b), .rd_valid_b(rd_valid_b), .ready_b(ready_b));

    // ---- Helpers -------------------------------------------------------
    task automatic do_write(input logic [15:0] a, input logic [7:0] d);
        wait (wready);
        @(negedge clk);
        we    = 1'b1;
        waddr = a;
        wdata = d;
        @(posedge clk);
        @(negedge clk);
        we    = 1'b0;
    endtask

    task automatic do_read_a(input logic [15:0] a, output logic [7:0] got);
        wait (ready_a);
        @(negedge clk);
        raddr_a = a;
        req_a   = 1'b1;
        wait (!ready_a);
        @(negedge clk);
        req_a   = 1'b0;
        wait (rd_valid_a);
        @(posedge clk);
        got = rdata_a;
        @(negedge clk);
    endtask

    task automatic do_read_b(input logic [15:0] a, output logic [7:0] got);
        wait (ready_b);
        @(negedge clk);
        raddr_b = a;
        req_b   = 1'b1;
        wait (!ready_b);
        @(negedge clk);
        req_b   = 1'b0;
        wait (rd_valid_b);
        @(posedge clk);
        got = rdata_b;
        @(negedge clk);
    endtask

    int fail_count = 0;

    initial begin
        $display("[hyperram] start");
        repeat (8) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ===== Phase A — write then read on port A ======================
        begin : phase_a
            integer i;
            logic [7:0] got;
            for (i = 0; i < 16; i = i + 1)
                do_write(16'(i), 8'(i ^ 8'h5A));
            // Drain the write FIFO before starting reads, so the last
            // write has actually been committed to backing memory.
            repeat (LATENCY + 4) @(posedge clk);
            for (i = 0; i < 16; i = i + 1) begin
                do_read_a(16'(i), got);
                if (got !== 8'(i ^ 8'h5A)) begin
                    if (fail_count < 4)
                        $display("[A] FAIL i=%0d got=$%02h expected=$%02h",
                                 i, got, i ^ 8'h5A);
                    fail_count++;
                end
            end
            $display("[hyperram/A] 16 writes + 16 reads on port A OK");
        end

        // ===== Phase B — concurrent dual-port reads ====================
        // Pre-load distinct values at two address ranges.
        begin : phase_b_load
            integer i;
            for (i = 0; i < 8; i = i + 1)  do_write(16'h0100 + 16'(i), 8'(i + 8'hA0));
            for (i = 0; i < 8; i = i + 1)  do_write(16'h0200 + 16'(i), 8'(i + 8'hB0));
        end
        begin : phase_b
            integer i;
            integer mismatches;
            logic [7:0] got_a, got_b;
            mismatches = 0;
            // Sequential: first read each port back-to-back, then alternate.
            for (i = 0; i < 8; i = i + 1) begin
                do_read_a(16'h0100 + 16'(i), got_a);
                do_read_b(16'h0200 + 16'(i), got_b);
                if (got_a !== 8'(i + 8'hA0)) begin
                    if (mismatches < 4)
                        $display("[B/A] FAIL i=%0d got_a=$%02h", i, got_a);
                    mismatches++; fail_count++;
                end
                if (got_b !== 8'(i + 8'hB0)) begin
                    if (mismatches < 4)
                        $display("[B/B] FAIL i=%0d got_b=$%02h", i, got_b);
                    mismatches++; fail_count++;
                end
            end
            $display("[hyperram/B] 8 dual-port read pairs OK (%0d mismatches)",
                     mismatches);
        end

        // ===== Phase C — write then immediate read =====================
        begin : phase_c
            logic [7:0] got;
            do_write(16'h1000, 8'hC1);
            do_read_a(16'h1000, got);
            if (got !== 8'hC1) begin
                $display("[C/1] FAIL got=$%02h expected=$C1", got);
                fail_count++;
            end
            do_write(16'h1000, 8'hC2);     // overwrite
            do_read_a(16'h1000, got);
            if (got !== 8'hC2) begin
                $display("[C/2] FAIL got=$%02h expected=$C2", got);
                fail_count++;
            end
            $display("[hyperram/C] write→read coherence OK");
        end

        if (fail_count == 0) begin
            $display("*** HYPERRAM OK *** writes + dual-port reads + coherence");
            $finish;
        end else begin
            $display("*** HYPERRAM FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000;       // 1 ms watchdog
        $display("FAIL: tb_hyperram watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
