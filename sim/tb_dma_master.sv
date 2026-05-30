// tb_dma_master.sv — verify dma_master against an MMU stub.
//
// Setup:
//   - clk = FPGA fabric clock (100 MHz here for sim brevity).
//   - phi2 = Atari bus clock, generated as a divided clock at
//     CLOCK_DIV cycles per half — long enough that the FPGA can
//     comfortably resolve edges. Real Atari is ~1.79 MHz with
//     CLOCK_MULT=12 → 12 fabric cycles per phi2 half-cycle.
//   - MMU stub: 64 KB array initialised so memory[a] = (a & 0xFF) ^
//     (a >> 8). Returns memory[addr_o] on the D bus while bus_oe = 1.
//
// Phase A — single fetch:
//   - Drive req=1, req_addr=0x1234. Verify /HALT timing:
//     - halt_n drops the cycle after req is accepted
//     - addr_o + rw_o = 1 + bus_oe = 1 during the second phi2 cycle
//     - data_valid pulses with req_data = mmu[0x1234]
//     - halt_n returns high after the sample
//
// Phase B — 1024 sequential fetches:
//   - Drive a sequence of addresses 0x0000..0x03FF. After each,
//     verify req_data matches the MMU oracle. Track total fetches
//     completed.

`default_nettype none
`timescale 1ns / 1ps

module tb_dma_master;

    logic clk = 1'b0;
    always #5 clk = ~clk;       // 100 MHz fabric

    logic rst = 1'b1;

    // phi2 generator. CLOCK_DIV fabric cycles per half-period.
    // CLOCK_DIV=6 → 12 fabric cycles per phi2 cycle.
    localparam int CLOCK_DIV = 6;
    logic [3:0] phi2_div = 4'd0;
    logic       phi2     = 1'b0;
    always @(posedge clk) begin
        if (phi2_div == (CLOCK_DIV - 1)) begin
            phi2_div <= 4'd0;
            phi2     <= ~phi2;
        end else begin
            phi2_div <= phi2_div + 4'd1;
        end
    end

    // DUT side signals.
    logic        req      = 1'b0;
    logic [15:0] req_addr = 16'h0;
    wire         ack;
    wire         data_valid;
    wire  [7:0]  req_data;
    wire         busy;

    wire         halt_n;
    wire  [15:0] addr_o;
    wire         rw_o;
    wire         bus_oe;

    // MMU stub: a synthetic 64 KB memory keyed on addr_o while bus_oe=1.
    logic [7:0] mmu [0:65535];
    initial begin
        integer k;
        for (k = 0; k < 65536; k = k + 1) begin
            mmu[k] = (k & 8'hFF) ^ (k >> 8);
        end
    end

    // Drive D bus only while the FPGA is reading; otherwise leave high-Z
    // (modelled here as 0xZZ — the DUT shouldn't sample it then).
    wire [7:0] data_i = bus_oe ? mmu[addr_o] : 8'hZZ;

    dma_master u_dut (
        .clk(clk), .rst(rst),
        .phi2(phi2),
        .req(req), .req_addr(req_addr),
        .ack(ack), .data_valid(data_valid),
        .req_data(req_data), .busy(busy),
        .halt_n(halt_n), .addr_o(addr_o), .rw_o(rw_o),
        .bus_oe(bus_oe), .data_i(data_i));

    int  fail_count    = 0;
    int  fetches_done  = 0;
    logic [7:0] last_byte;
    logic [15:0] last_addr_observed;

    // Capture data + observe a few bus-level invariants on each fetch.
    int halt_low_cycles = 0;
    int oe_high_cycles  = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (~halt_n) halt_low_cycles = halt_low_cycles + 1;
            if (bus_oe)  oe_high_cycles  = oe_high_cycles  + 1;
            // Bus must not drive while halt is high (released).
            if (bus_oe && halt_n) begin
                if (fail_count < 4)
                    $display("[bus] FAIL bus_oe=1 while halt_n=1 at t=%0t addr=%04h",
                             $time, addr_o);
                fail_count = fail_count + 1;
            end
            // While bus_oe is asserted, addr_o + rw_o must be stable (rw=1 read).
            if (bus_oe && rw_o !== 1'b1) begin
                if (fail_count < 4)
                    $display("[bus] FAIL rw_o=%0b while bus_oe=1 (expected 1)", rw_o);
                fail_count = fail_count + 1;
            end
        end
    end

    // Capture observed bus addresses while driving.
    always @(posedge clk) begin
        if (!rst && bus_oe) last_addr_observed <= addr_o;
    end

    task automatic do_fetch(input logic [15:0] a, output logic [7:0] got);
        @(posedge clk);
        req      <= 1'b1;
        req_addr <= a;
        @(posedge clk);
        // Hold one extra cycle so DUT's S_IDLE→S_HALT_WAIT decode catches req.
        req      <= 1'b0;
        // Wait for data_valid pulse.
        wait (data_valid);
        @(posedge clk);
        got = req_data;
        // Wait for DUT to return to IDLE.
        wait (!busy);
        @(posedge clk);
    endtask

    initial begin
        $display("[dma] start");
        repeat (10) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ===== Phase A — single fetch =================================
        do_fetch(16'h1234, last_byte);
        if (last_byte !== mmu[16'h1234]) begin
            $display("[A/data] FAIL addr=$1234 got=$%02h expected=$%02h",
                     last_byte, mmu[16'h1234]);
            fail_count++;
        end else begin
            $display("[dma/A] single fetch addr=$1234 → $%02h OK", last_byte);
        end

        // ===== Phase B — 1024 sequential fetches ======================
        begin : phase_b
            integer i;
            logic [15:0] a;
            logic [7:0]  got, exp;
            int          mismatches;
            mismatches = 0;
            for (i = 0; i < 1024; i = i + 1) begin
                a = i[15:0];
                do_fetch(a, got);
                exp = mmu[a];
                if (got !== exp) begin
                    if (mismatches < 4)
                        $display("[B] FAIL i=%0d addr=$%04h got=$%02h exp=$%02h",
                                 i, a, got, exp);
                    mismatches++;
                    fail_count++;
                end
                fetches_done = fetches_done + 1;
            end
            $display("[dma/B] %0d fetches, %0d mismatches", fetches_done, mismatches);
        end

        $display("[dma] halt_low=%0d cycles bus_oe=%0d cycles",
                 halt_low_cycles, oe_high_cycles);

        if (fail_count == 0) begin
            $display("*** DMA OK *** 1 + 1024 fetches verified vs. MMU oracle");
            $finish;
        end else begin
            $display("*** DMA FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;       // 50 ms watchdog (1024 fetches × ~5µs each ~ 5ms)
        $display("FAIL: tb_dma watchdog (fetches=%0d)", fetches_done);
        $fatal(1);
    end

endmodule

`default_nettype wire
