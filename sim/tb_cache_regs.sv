// tb_cache_regs.sv — M-cache-rework Step 1 unit test.
//
// Exercises the $D380-$D3FF register file + per-bank attribute SRAM
// in isolation (no antic_top). Drives `we`/`waddr`/`wdata` directly
// (stand-in for bus_snoop output) and reads back via `raddr`/`rdata`.
//
// Coverage:
//   - Reset defaults: enable_partition=0, code_lines=24, others 0.
//   - Round-trip read/write of $D380, $D381, $D382, $D383, $D384, $D386.
//   - $D387 write generates a 1-cycle flush_pulse.
//   - Attribute SRAM round-trip via $D382/$D383/$D384 + $D385:
//       * Region A (256 banks)
//       * Region B (256 banks)
//       * Region C (1024 banks via 10-bit composed id)
//   - $D385 reads the attribute at the currently-selected bank.
//   - Out-of-window writes are ignored.
//   - Reserved registers ($D388+) read $00, writes ignored.
//   - Cache attribute lookup port returns the expected nibble for an
//     address recently written via the software path.

`default_nettype none
`timescale 1ns / 1ps

module tb_cache_regs;

    logic clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz
    logic rst = 1'b1;

    logic        we    = 1'b0;
    logic [15:0] waddr = 16'h0000;
    logic [7:0]  wdata = 8'h00;

    logic [15:0] raddr = 16'h0000;
    wire  [7:0]  rdata;

    wire        enable_partition_q;
    wire [7:0]  code_lines_q;
    wire [3:0]  current_task_q;
    wire        flush_pulse;

    logic [11:0] attr_lookup_idx = 12'h000;
    wire  [3:0]  attr_lookup_data;

    cache_regs u_dut (
        .clk                (clk),
        .rst                (rst),
        .we                 (we),
        .waddr              (waddr),
        .wdata              (wdata),
        .raddr              (raddr),
        .rdata              (rdata),
        .enable_partition_q (enable_partition_q),
        .code_lines_q       (code_lines_q),
        .current_task_q     (current_task_q),
        .flush_pulse        (flush_pulse),
        .attr_lookup_idx    (attr_lookup_idx),
        .attr_lookup_data   (attr_lookup_data)
    );

    int fail_count = 0;
    int flush_pulse_count = 0;

    // Count flush pulses across the run.
    always_ff @(posedge clk) if (flush_pulse) flush_pulse_count++;

    task automatic expect_eq(input string label,
                             input logic [7:0] actual,
                             input logic [7:0] expected);
        if (actual !== expected) begin
            $display("FAIL %s: got $%02h, expected $%02h", label, actual, expected);
            fail_count++;
        end
    endtask

    task automatic expect_bit(input string label,
                              input logic actual,
                              input logic expected);
        if (actual !== expected) begin
            $display("FAIL %s: got %0b, expected %0b", label, actual, expected);
            fail_count++;
        end
    endtask

    // do_write: 1-cycle pulse on `we` aligned with the snoop's
    // 1-cycle-delayed write contract (stand-in for bus_snoop's output).
    task automatic do_write(input logic [15:0] addr, input logic [7:0] d);
        @(negedge clk);
        we    = 1'b1;
        waddr = addr;
        wdata = d;
        @(posedge clk);
        @(negedge clk);
        we    = 1'b0;
        waddr = 16'h0000;
        wdata = 8'h00;
    endtask

    // do_read: combinational read at raddr; one cycle to settle.
    task automatic do_read(input logic [15:0] addr, output logic [7:0] r);
        @(negedge clk);
        raddr = addr;
        @(posedge clk);
        #1;
        r = rdata;
    endtask

    // Helper: select the bank for the attribute SRAM (region + id).
    task automatic select_bank(input logic [1:0] region,
                               input logic [1:0] id_hi,
                               input logic [7:0] id_lo);
        do_write(16'hD382, {6'h00, region});
        do_write(16'hD383, id_lo);
        do_write(16'hD384, {6'h00, id_hi});
    endtask

    logic [7:0] r;

    initial begin
        $display("[cache_regs] start");
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (4) @(posedge clk);

        // ---- Reset defaults -----------------------------------------
        do_read(16'hD380, r); expect_eq("reset $D380",  r, 8'h00);   // ENABLE_PARTITION=0
        do_read(16'hD381, r); expect_eq("reset $D381",  r, 8'd32);   // CACHE_CODE_LINES=32
        do_read(16'hD382, r); expect_eq("reset $D382",  r, 8'h00);
        do_read(16'hD383, r); expect_eq("reset $D383",  r, 8'h00);
        do_read(16'hD384, r); expect_eq("reset $D384",  r, 8'h00);
        do_read(16'hD386, r); expect_eq("reset $D386",  r, 8'h00);
        do_read(16'hD387, r); expect_eq("reset $D387",  r, 8'h00);
        expect_bit("reset enable_partition_q", enable_partition_q, 1'b0);
        expect_eq("reset code_lines_q", code_lines_q, 8'd32);

        // ---- $D380 CACHE_CTL bit 0 ----------------------------------
        do_write(16'hD380, 8'h01);
        do_read (16'hD380, r); expect_eq("$D380 = 1", r, 8'h01);
        expect_bit("enable_partition_q after write 1", enable_partition_q, 1'b1);
        do_write(16'hD380, 8'hFE);   // bit 0 = 0; high bits ignored
        do_read (16'hD380, r); expect_eq("$D380 = 0 (high bits ignored)", r, 8'h00);
        expect_bit("enable_partition_q after write 0", enable_partition_q, 1'b0);

        // ---- $D381 CACHE_CODE_LINES (full byte) ---------------------
        do_write(16'hD381, 8'd40);
        do_read (16'hD381, r); expect_eq("$D381 = 40", r, 8'd40);
        expect_eq("code_lines_q after write", code_lines_q, 8'd40);

        // ---- $D386 CURRENT_TASK_ID (4 bits) -------------------------
        do_write(16'hD386, 8'hCA);   // expect to see 4 LSBs
        do_read (16'hD386, r); expect_eq("$D386 keeps low 4 bits", r, 8'h0A);
        expect_eq("current_task_q", current_task_q, 4'hA);

        // ---- $D387 CACHE_FLUSH (write-any → 1-cycle pulse) ----------
        flush_pulse_count = 0;
        do_write(16'hD387, 8'h00);
        repeat (3) @(posedge clk);
        if (flush_pulse_count !== 1) begin
            $display("FAIL flush_pulse: expected 1 pulse, got %0d", flush_pulse_count);
            fail_count++;
        end
        do_read(16'hD387, r); expect_eq("$D387 reads zero", r, 8'h00);

        // ---- Attribute SRAM round-trip ------------------------------
        // Region A: bank 0x05 → attribute $A
        select_bank(2'b00, 2'b00, 8'h05);
        do_write(16'hD385, 8'h0A);
        repeat (2) @(posedge clk);
        do_read (16'hD385, r); expect_eq("attr A:0x05 readback", r, 8'h0A);

        // Region B: bank 0x33 → attribute $7
        select_bank(2'b01, 2'b00, 8'h33);
        do_write(16'hD385, 8'h07);
        repeat (2) @(posedge clk);
        do_read (16'hD385, r); expect_eq("attr B:0x33 readback", r, 8'h07);

        // Region C: 10-bit bank 0x2AB → attribute $C (high 4 bits ignored)
        select_bank(2'b10, 2'b10, 8'hAB);
        do_write(16'hD385, 8'hFC);   // expect low 4 bits: $C
        repeat (2) @(posedge clk);
        do_read (16'hD385, r); expect_eq("attr C:0x2AB readback (low nibble)", r, 8'h0C);

        // Re-select region A bank 0x05; expect the original $A still there.
        select_bank(2'b00, 2'b00, 8'h05);
        repeat (2) @(posedge clk);
        do_read (16'hD385, r); expect_eq("attr A:0x05 still $A", r, 8'h0A);

        // Distinct entry isolation: region A bank 0x06 should still be $0
        // (untouched).
        select_bank(2'b00, 2'b00, 8'h06);
        repeat (2) @(posedge clk);
        do_read (16'hD385, r); expect_eq("attr A:0x06 untouched", r, 8'h00);

        // ---- Attribute lookup port (cache miss path) ----------------
        // Region B bank 0x33 lives at composed addr {2'b01, 2'b00, 8'h33}
        // = 12'h433. Drive attr_lookup_idx = 12'h433 — 1-cycle latency.
        @(negedge clk);
        attr_lookup_idx = 12'h433;
        @(posedge clk);   // launch read
        @(posedge clk);   // settle
        #1;
        if (attr_lookup_data !== 4'h7) begin
            $display("FAIL attr_lookup B:0x33: got $%01h, expected $7",
                     attr_lookup_data);
            fail_count++;
        end
        // Region A bank 0x05 = composed 12'h005. attr should be $A.
        @(negedge clk);
        attr_lookup_idx = 12'h005;
        @(posedge clk);
        @(posedge clk);
        #1;
        if (attr_lookup_data !== 4'hA) begin
            $display("FAIL attr_lookup A:0x05: got $%01h, expected $A",
                     attr_lookup_data);
            fail_count++;
        end

        // ---- Out-of-window writes are ignored -----------------------
        // $D200 (POKEY page) and $D300 (PIA proper, addr[7]=0) must
        // not affect any cache reg. Use $D380 = 1 as a marker, then
        // try a $D200/$D300 write of $00 and confirm $D380 is unchanged.
        do_write(16'hD380, 8'h01);
        do_write(16'hD200, 8'h00);
        do_write(16'hD300, 8'h00);
        do_write(16'hD37F, 8'h00);   // last addr before the cache window
        do_read (16'hD380, r); expect_eq("$D380 untouched by out-of-window", r, 8'h01);

        // ---- Reserved registers --------------------------------------
        // $D388-$D3FF read $00; writes ignored.
        do_read (16'hD388, r); expect_eq("$D388 reserved reads zero", r, 8'h00);
        do_read (16'hD3FF, r); expect_eq("$D3FF reserved reads zero", r, 8'h00);
        do_write(16'hD388, 8'hFF);   // ignored
        do_write(16'hD3FF, 8'hFF);   // ignored
        do_read (16'hD388, r); expect_eq("$D388 still zero", r, 8'h00);

        if (fail_count == 0) begin
            $display("*** CACHE_REGS OK *** all checks passed");
            $finish;
        end else begin
            $display("*** CACHE_REGS FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #1_000_000;
        $display("FAIL: tb_cache_regs watchdog expired"); $fatal(1);
    end

endmodule

`default_nettype wire
