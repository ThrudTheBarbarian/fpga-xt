// tb_bank_cache.sv — M24-3 bank-cache validation.
//
// Standalone test harness wrapping bank_cache + a simple HyperRAM
// mock (flat 1MB BRAM, 1-cycle/byte latency). Phases:
//
//   A — Cold miss: first request to bank N. cpu_ready drops; the
//       FSM walks a full 4 KB fetch from HyperRAM; cpu_ready returns
//       and cpu_rdata = mem[bank N's offset]. ~4100 cycles.
//   B — Warm hit: subsequent reads to the same bank → 1-cycle hit.
//   C — Dirty write + eviction: write to bank N (cache hit, marks
//       dirty), then access bank N+16 (forces eviction). FSM does
//       writeback first, then fetch. Verify HyperRAM has the
//       updated byte at bank N's offset.
//   D — Multi-bank thrash: cycle through 20 distinct banks (more
//       than 16 cache lines). Each new bank is a miss. After the
//       cycle, oldest 4 banks have been evicted.
//
// To keep wall-clock reasonable, we override the cache's LINE_BYTES
// parameter to 64 (instead of production 4096) so each refill is ~70
// cycles instead of ~4100. The cache logic is identical at any line
// size — this just makes the test ~60× faster.

`timescale 1ns / 1ps

module tb_bank_cache;

    // M24-int-cache v2 — 4-way set-associative cache.
    localparam int NUM_SETS     = 4;
    localparam int NUM_WAYS     = 4;
    localparam int LINE_BYTES   = 64;
    localparam int CPU_OFFSET_W = 12;        // full sub-block offset
    localparam int BANK_ID_W    = 8;
    localparam int HR_ADDR_W    = 23;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- DUT signals ----
    logic [CPU_OFFSET_W-1:0] cpu_offset = '0;
    logic [BANK_ID_W-1:0]    cpu_bank_id = '0;
    logic [7:0]              cpu_wdata   = 8'h00;
    logic                    cpu_we      = 1'b0;
    logic                    cpu_req     = 1'b0;
    wire  [7:0]              cpu_rdata;
    wire                     cpu_ready;

    localparam int BYTE_OFFSET_W = $clog2(LINE_BYTES);
    wire [HR_ADDR_W-1:0]      hr_addr;
    wire [BYTE_OFFSET_W-1:0]  hr_burst_len;
    wire [7:0]                hr_wdata;
    wire                      hr_we;
    wire                      hr_req;
    logic [7:0]               hr_rdata  = 8'h00;
    logic                     hr_rvalid = 1'b0;
    logic                     hr_done   = 1'b0;

    bank_cache #(
        .NUM_SETS    (NUM_SETS),
        .NUM_WAYS    (NUM_WAYS),
        .LINE_BYTES  (LINE_BYTES),
        .CPU_OFFSET_W(CPU_OFFSET_W),
        .BANK_ID_W   (BANK_ID_W),
        .HR_ADDR_W   (HR_ADDR_W)
    ) u_dut (
        .clk          (clk),
        .rst          (rst),
        .cpu_offset   (cpu_offset),
        .cpu_bank_id  (cpu_bank_id),
        .cpu_wdata    (cpu_wdata),
        .cpu_we       (cpu_we),
        .cpu_req      (cpu_req),
        .cpu_rdata    (cpu_rdata),
        .cpu_ready    (cpu_ready),
        .hr_addr      (hr_addr),
        .hr_burst_len (hr_burst_len),
        .hr_wdata     (hr_wdata),
        .hr_we        (hr_we),
        .hr_req       (hr_req),
        .hr_rdata     (hr_rdata),
        .hr_rvalid    (hr_rvalid),
        .hr_done      (hr_done)
    );

    // ---- HyperRAM mock — 1 MB flat BRAM, burst-aware ----
    //
    // M-cache-rework Step 5 burst protocol:
    //   - Cache pulses hr_req=1 with hr_addr=start, hr_we, hr_burst_len.
    //     On reads we begin streaming bytes back via hr_rdata + hr_rvalid;
    //     on writes we consume hr_wdata each cycle. Last byte coincides
    //     with hr_done=1.
    //   - Burst length is hr_burst_len + 1 bytes; LINE_BYTES bytes for
    //     a full cache-line transfer. Mock advances 1 byte/clk cycle.
    //
    // hr_addr = {pad, bank_id, sub_block_idx, byte_off}
    //         = {pad, bank_id, cpu_offset[11:0]}
    // Linear: bank N starts at hr_addr = N * 4096.
    logic [7:0] hr_mem [0:1048575];

    logic [HR_ADDR_W-1:0] burst_addr_q;
    logic [BYTE_OFFSET_W:0] burst_remain_q;     // bytes remaining (1..LINE_BYTES)
    logic                 burst_we_q;
    logic                 burst_active_q;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            burst_active_q <= 1'b0;
            burst_remain_q <= '0;
            burst_we_q     <= 1'b0;
            burst_addr_q   <= '0;
            hr_rvalid      <= 1'b0;
            hr_done        <= 1'b0;
            hr_rdata       <= 8'h00;
        end else begin
            hr_rvalid <= 1'b0;
            hr_done   <= 1'b0;

            if (hr_req && !burst_active_q) begin
                // Process the FIRST byte of the burst this cycle.
                if (hr_we) begin
                    hr_mem[hr_addr[19:0]] <= hr_wdata;
                end else begin
                    hr_rdata  <= hr_mem[hr_addr[19:0]];
                    hr_rvalid <= 1'b1;
                end
                if (hr_burst_len == '0) begin
                    // Single-byte burst — done immediately.
                    hr_done <= 1'b1;
                end else begin
                    burst_active_q <= 1'b1;
                    burst_we_q     <= hr_we;
                    burst_addr_q   <= hr_addr + 1'b1;
                    burst_remain_q <= {1'b0, hr_burst_len};   // = N-1 still left
                end
            end else if (burst_active_q) begin
                if (burst_we_q) begin
                    hr_mem[burst_addr_q[19:0]] <= hr_wdata;
                end else begin
                    hr_rdata  <= hr_mem[burst_addr_q[19:0]];
                    hr_rvalid <= 1'b1;
                end
                burst_addr_q <= burst_addr_q + 1'b1;
                if (burst_remain_q == 1) begin
                    hr_done        <= 1'b1;
                    burst_active_q <= 1'b0;
                end else begin
                    burst_remain_q <= burst_remain_q - 1'b1;
                end
            end
        end
    end

    int fail_count = 0;
    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Issue a single request (read or write) and wait for cpu_ready=1.
    task automatic do_req(input [BANK_ID_W-1:0]    bid,
                          input [CPU_OFFSET_W-1:0] off,
                          input                    we,
                          input [7:0]              wdata,
                          output [7:0]             rdata,
                          output int               cycles);
        int c;
        @(negedge clk);
        cpu_bank_id = bid;
        cpu_offset  = off;
        cpu_we      = we;
        cpu_wdata   = wdata;
        cpu_req     = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cpu_req     = 1'b0;
        c = 1;
        // Wait for cpu_ready=1 (it might dip to 0 on miss).
        while (!cpu_ready && c < 10000) begin
            @(posedge clk);
            c = c + 1;
        end
        @(negedge clk);
        rdata = cpu_rdata;
        cycles = c;
    endtask

    initial begin
        $display("=== M24-3 bank_cache ===");

        // Pre-load the HyperRAM mock with a deterministic pattern.
        // M-cache-rework Step 2 layout: hr_addr = bank_id*4096 +
        // cpu_offset (linear). Pre-load each bank's first LINE_BYTES.
        for (int b = 0; b < 256; b++) begin
            for (int o = 0; o < LINE_BYTES; o++) begin
                hr_mem[b*4096 + o] = 8'(b) ^ 8'(o);
            end
        end

        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);

        // ===== Phase A — cold miss =====================================
        $display("[A] cold miss → fetch from HyperRAM");
        begin
            int cycles;
            logic [7:0] v;
            do_req(8'd5, 12'd17, 1'b0, 8'h00, v, cycles);
            // bank 5 ^ offset 17 = 5 ^ 17 = $14
            expect_eq("A.rdata", v, 8'h14);
            $display("[A] miss completed in %0d cycles (expected ~%0d)",
                     cycles, LINE_BYTES + 5);
            if (cycles < LINE_BYTES || cycles > LINE_BYTES * 3) begin
                $display("FAIL A.cycles: %0d outside [%0d, %0d]",
                         cycles, LINE_BYTES, LINE_BYTES * 3);
                fail_count++;
            end
        end

        // ===== Phase B — warm hit ======================================
        $display("[B] warm hit on same bank");
        begin
            int cycles;
            logic [7:0] v;
            // Same bank, different offset (still within line: byte_off=42).
            do_req(8'd5, 12'd42, 1'b0, 8'h00, v, cycles);
            expect_eq("B.rdata", v, 8'h05 ^ 8'h2A);    // = $2F
            $display("[B] hit completed in %0d cycles (expected 1)", cycles);
            if (cycles > 3) begin
                $display("FAIL B.cycles: %0d (expected 1-cycle hit)", cycles);
                fail_count++;
            end
        end

        // ===== Phase C — dirty write + eviction ========================
        // Write to bank 5 (still cached) → marks dirty.
        // Then access enough other banks to force bank 5's eviction.
        // The eviction must writeback to HyperRAM with the modified
        // byte present. After eviction, the rest of bank 5 is still
        // intact in HyperRAM with original values.
        $display("[C] dirty write + eviction writeback");
        begin
            int cycles;
            logic [7:0] v;
            // Write $99 at bank 5, offset 7. Was $5^$7 = $02.
            do_req(8'd5, 12'd7, 1'b1, 8'h99, v, cycles);
            $display("[C.write] bank 5 offset 7 ← $99, %0d cycles", cycles);

            // Force eviction. With 4-way SA per set and all accesses
            // landing in set 0 (offset bits [7:6]=0), the 4 ways fill
            // up after 4 misses to other banks. The 5th miss wraps
            // round-robin back to way 0 (bank 5's slot) and evicts
            // it. We do 5+ misses to ensure bank 5 is evicted.
            for (int i = 0; i < 8; i++) begin
                do_req(8'd100 + i[7:0], 12'd0, 1'b0, 8'h00, v, cycles);
            end

            // Verify HyperRAM at bank 5 / offset 7 was written back.
            // hr_mem layout: bank_id*4096 + cpu_offset (linear).
            expect_eq("C.writeback hr_mem", hr_mem[5*4096 + 7], 8'h99);
            // Verify the rest of bank 5 in HyperRAM is unchanged.
            expect_eq("C.untouched hr_mem", hr_mem[5*4096 + 8], 8'h05 ^ 8'h08);
        end

        // ===== Phase D — re-fetch evicted bank =========================
        // Now access bank 5 again — it's been evicted, so this is
        // a fresh miss. The data should reflect the most-recent
        // HyperRAM state (= the writeback from Phase C, with $99 at
        // offset 7 and original pattern elsewhere).
        $display("[D] re-fetch bank 5 — verifies writeback round-trip");
        begin
            int cycles;
            logic [7:0] v;
            do_req(8'd5, 12'd7, 1'b0, 8'h00, v, cycles);
            expect_eq("D.modified[7]", v, 8'h99);
            do_req(8'd5, 12'd23, 1'b0, 8'h00, v, cycles);
            expect_eq("D.untouched[23]", v, 8'h05 ^ 8'h17);   // = $12
        end

        if (fail_count == 0) begin
            $display("*** BANK_CACHE OK *** miss / hit / dirty-evict / round-trip");
            $finish;
        end else begin
            $display("*** BANK_CACHE FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_bank_cache watchdog");
        $fatal(1);
    end

endmodule
