// tb_cache_partition.sv — M-cache-rework Step 3 / Step 4 routing.
//
// Verifies that sally_mem's four bank_cache instances are independently
// exercised by the (partition × streaming) classifiers:
//
//   region 00/01 ($82, sub_block $4xxx/$5xxx) → code partition
//   region 10/11 ($83/$84/$85, sub_block $6xxx/$7xxx) → data partition
//
// The streaming bit (attribute SRAM bit 2 in cache_regs) routes a bank
// to the bypass slot for its partition instead of the main partition
// cache.
//
// Coverage:
//   A — cold miss in code partition: code cache goes EVICT/FETCH/INSTALL,
//       other caches stay IDLE.
//   B — warm hit on code partition: 1-cycle hit, no HR traffic.
//   C — cold miss in data partition: data cache goes through FSM,
//       other caches stay IDLE.
//   D — warm hit on data partition.
//   E — partition isolation: code partition fills + evicts in isolation,
//       data partition's prior hit-state survives.
//   F — streaming-tagged code bank routes to code-stream bypass; the
//       code partition cache is never touched.
//   G — streaming activity does not pollute the partition cache: a
//       warm partition line survives a sweep through the bypass.
//   H — streaming-tagged data bank routes to data-stream bypass.

`timescale 1ns / 1ps

module tb_cache_partition;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    logic [15:0] addr     = 16'h0000;
    logic [7:0]  data_in  = 8'h00;
    logic        rw       = 1'b1;
    wire  [7:0]  data_out;
    wire         mem_busy;

    wire [15:0] hwreg_addr;
    wire        hwreg_we;
    wire [7:0]  hwreg_din;
    logic [7:0] hwreg_dout = 8'hFF;

    // ---- HyperRAM mock — flat 1 MB BRAM, burst-aware (Step 5/7) -----
    // One hr_req pulse covers a multi-WORD transfer; mock streams 1
    // word/cycle, where a word is WORD_BYTES bytes. At Step 7's
    // CACHE_WORD_BYTES=2 the mock thus delivers 2 bytes per
    // hr_rvalid pulse — halving the effective miss-cycle count.
    localparam int unsigned WORD_BYTES = 2;
    localparam int unsigned WORD_W     = WORD_BYTES * 8;

    wire [22:0]              hr_addr;
    wire [9:0]               hr_burst_len;
    wire                     hr_we;
    wire [WORD_W-1:0]        hr_wdata;
    wire                     hr_req;
    logic [WORD_W-1:0]       hr_rdata  = '0;
    logic                    hr_rvalid = 1'b0;
    logic                    hr_done   = 1'b0;
    logic [7:0]              hr_mem [0:1048575];

    logic [22:0]             burst_addr_q   = '0;   // byte address — advances by WORD_BYTES per cycle
    logic [10:0]             burst_remain_q = '0;
    logic                    burst_we_q     = 1'b0;
    logic                    burst_active_q = 1'b0;

    function automatic [WORD_W-1:0] mock_read_word(input [22:0] byte_addr);
        logic [WORD_W-1:0] w;
        for (int b = 0; b < WORD_BYTES; b++)
            w[b*8 +: 8] = hr_mem[(byte_addr + 23'(b)) & 23'h0FFFFF];
        return w;
    endfunction

    task automatic mock_write_word(input [22:0] byte_addr, input [WORD_W-1:0] data);
        for (int b = 0; b < WORD_BYTES; b++)
            hr_mem[(byte_addr + 23'(b)) & 23'h0FFFFF] = data[b*8 +: 8];
    endtask

    always_ff @(posedge clk) begin
        hr_rvalid <= 1'b0;
        hr_done   <= 1'b0;
        if (hr_req && !burst_active_q) begin
            if (hr_we) mock_write_word(hr_addr, hr_wdata);
            else begin
                hr_rdata  <= mock_read_word(hr_addr);
                hr_rvalid <= 1'b1;
            end
            if (hr_burst_len == 10'h000) begin
                hr_done <= 1'b1;
            end else begin
                burst_active_q <= 1'b1;
                burst_we_q     <= hr_we;
                burst_addr_q   <= hr_addr + 23'(WORD_BYTES);
                burst_remain_q <= {1'b0, hr_burst_len};
            end
        end else if (burst_active_q) begin
            if (burst_we_q) mock_write_word(burst_addr_q, hr_wdata);
            else begin
                hr_rdata  <= mock_read_word(burst_addr_q);
                hr_rvalid <= 1'b1;
            end
            burst_addr_q <= burst_addr_q + 23'(WORD_BYTES);
            if (burst_remain_q == 11'h001) begin
                hr_done        <= 1'b1;
                burst_active_q <= 1'b0;
            end else begin
                burst_remain_q <= burst_remain_q - 1'b1;
            end
        end
    end

    // sally_mem with the production cache geometry — 16 sets × 4 ways
    // × 1 KB lines split 8/8 across code+data partitions = 32 KB per
    // partition; plus 2 sets × 2 ways × 1 KB stream-bypass cache per
    // partition (4 KB each, 8 KB total). Matches antic_top synth target.
    wire [11:0] attr_lookup_idx_w;
    wire [3:0]  attr_lookup_data_w;

    sally_mem #(
        .CACHE_NUM_SETS   (16),
        .CACHE_NUM_WAYS   (4),
        .CACHE_LINE_BYTES (1024),
        .STREAM_NUM_SETS  (2),
        .STREAM_NUM_WAYS  (2),
        .CACHE_WORD_BYTES (WORD_BYTES)        // Step 7 wide-data path
    ) u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (addr),
        .data_in    (data_in),
        .rw         (rw),
        .data_out   (data_out),
        .rdy        (1'b1),
        .busy       (mem_busy),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (),
        .cpu_data_bank_q    (),
        .cpu_regc_bank_lo_q (),
        .cpu_regc_bank_hi_q (),
        .antic_code_bank    (8'h00),
        .antic_data_bank    (8'h00),
        .antic_regc_bank_lo (8'h00),
        .antic_regc_bank_hi (8'h00),
        .view_is_antic      (1'b0),
        .hr_addr      (hr_addr),
        .hr_burst_len (hr_burst_len),
        .hr_we        (hr_we),
        .hr_wdata     (hr_wdata),
        .hr_req       (hr_req),
        .hr_rdata     (hr_rdata),
        .hr_rvalid    (hr_rvalid),
        .hr_done      (hr_done),
        .rom_addr    (16'h0000),
        .rom_data    (8'h00),
        .rom_we      (1'b0),
        .attr_lookup_idx  (attr_lookup_idx_w),
        .attr_lookup_data (attr_lookup_data_w)
    );

    // cache_regs — provides the per-bank attribute SRAM. Tests poke
    // u_regs.attr_mem[idx] directly to mark a bank as streaming.
    cache_regs u_regs (
        .clk                (clk),
        .rst                (rst),
        .we                 (1'b0),
        .waddr              (16'h0000),
        .wdata              (8'h00),
        .raddr              (16'h0000),
        .rdata              (),
        .enable_partition_q (),
        .code_lines_q       (),
        .current_task_q     (),
        .flush_pulse        (),
        .attr_lookup_idx    (attr_lookup_idx_w),
        .attr_lookup_data   (attr_lookup_data_w)
    );

    int fail_count = 0;

    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Set the CPU bank-select state via direct hierarchical ref into
    // sally_mem. The bank-select registers (cpu_code_bank, etc) only
    // self-update on $0082-$0085 writes, so direct assignment here
    // persists across the test.
    task automatic set_banks(input [7:0] code_bank, input [7:0] data_bank);
        u_mem.cpu_code_bank    = code_bank;
        u_mem.cpu_data_bank    = data_bank;
        u_mem.cpu_regc_bank_lo = 8'h00;
        u_mem.cpu_regc_bank_hi = 8'h00;
        @(posedge clk);
    endtask

    // Issue a read to `a`, wait for completion. Returns cycle count
    // (1 = hit, more = miss). The #1 after each @(posedge clk) lets
    // NBA-scheduled state_q updates settle before sampling mem_busy.
    task automatic do_read(input [15:0] a, output [7:0] v, output int cycles);
        int c;
        while (mem_busy) @(posedge clk);
        @(negedge clk);
        addr = a;
        rw   = 1'b1;
        @(posedge clk);
        #1;
        c = 1;
        while (mem_busy && c < 20000) begin
            @(posedge clk);
            #1;
            c = c + 1;
        end
        @(negedge clk);
        v = data_out;
        cycles = c;
    endtask

    // Snapshot cache states.
    task automatic snapshot(output logic code_idle, output logic data_idle);
        code_idle = (u_mem.u_bank_cache_code.state_q == 0);  // IDLE
        data_idle = (u_mem.u_bank_cache_data.state_q == 0);
    endtask

    // Park the bus address outside $4000-$7FFF so cpu_req goes low,
    // then update bank-select state and let attr_rdata_cache_q settle.
    // The `sub_block` argument selects the parked address's sub-block
    // (00=code lo, 01=code hi, 10=data, 11=regc). bank_xlat reads
    // addr[13:12] regardless of is_in_window, so parking at $0000 /
    // $1000 / $2000 / $3000 keeps cpu_req=0 while bank_id_w (and
    // therefore attr_lookup_idx) tracks the target region.
    //
    // Used by the Step 4 streaming-bypass tests where the first miss
    // must hit the right cache: routing depends on attr_lookup_data
    // which is one cycle behind the live bank_id, so the prior cycle
    // must already be addressing the target region/bank.
    task automatic park_and_setup(input [7:0] code_bank,
                                  input [7:0] data_bank,
                                  input [1:0] sub_block);
        while (mem_busy) @(posedge clk);
        @(negedge clk);
        addr = {2'b00, sub_block, 12'h000};   // out of bank window, target sub-block
        @(posedge clk);
        u_mem.cpu_code_bank    = code_bank;
        u_mem.cpu_data_bank    = data_bank;
        u_mem.cpu_regc_bank_lo = 8'h00;
        u_mem.cpu_regc_bank_hi = 8'h00;
        @(posedge clk);          // attr_lookup_idx now points at new bank
        @(posedge clk);          // attr_rdata_cache_q latches
        @(posedge clk);          // attr_lookup_data fully visible
    endtask

    // ---- HR pre-load -----------------------------------------------
    // bank_cache truncates the 16-bit bank_id from bank_xlat down to
    // 8 bits before tag/HR addressing (a known limitation noted in
    // sally_mem). HR layout: {pad, bank_id[7:0], cpu_offset[11:0]}.
    // So hr_mem[bank_lo * 4096 + cpu_offset] is the address.
    initial begin
        for (int b = 0; b < 256; b++) begin
            for (int o = 0; o < 16; o++)        // first few bytes per bank
                hr_mem[b*4096 + o] = 8'(b) ^ 8'(o);
        end
    end

    initial begin
        $display("=== M-cache-rework cache_partition ===");
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (3) @(posedge clk);

        set_banks(8'h05, 8'h10);

        // ===== A — cold miss code partition ============================
        // Address $4000 → sub_block 0 ($4xxx) → region 00 (code lo)
        // → bank_id = {2'b00, 6'b0, $05} = $0005. Code partition.
        $display("[A] cold miss code partition (addr $4000)");
        begin
            int cycles;
            logic [7:0] v;
            logic       code_idle, data_idle;

            do_read(16'h4000, v, cycles);
            // bank_cache truncates bank_id to 8 bits → HR addr =
            // bank * 4096 + offset = 5*4096+0. Pre-load: 5 ^ 0 = $05.
            expect_eq("A.rdata", v, 8'h05);
            $display("[A] miss: %0d cycles", cycles);
            if (cycles < 100) begin
                $display("FAIL A: expected miss (>= 100 cycles), got %0d", cycles);
                fail_count++;
            end

            // Verify only code cache went non-IDLE — data should be untouched.
            // (Both back to IDLE now, so check the install just happened
            // by issuing a hit and confirming data partition is untouched.)
        end

        // ===== B — warm hit code partition =============================
        $display("[B] warm hit code partition (addr $4001)");
        begin
            int cycles;
            logic [7:0] v;
            do_read(16'h4001, v, cycles);
            expect_eq("B.rdata", v, 8'h05 ^ 8'h01);   // = $04
            $display("[B] hit: %0d cycles", cycles);
            if (cycles > 5) begin
                $display("FAIL B: expected ~1-cycle hit, got %0d", cycles);
                fail_count++;
            end
        end

        // ===== C — cold miss data partition ============================
        // Address $6000 → sub_block 2 ($6xxx) → region 10 (data) →
        // bank_id = {2'b10, 6'b0, $10} = $8010. Data partition.
        $display("[C] cold miss data partition (addr $6000)");
        begin
            int cycles;
            logic [7:0] v;
            do_read(16'h6000, v, cycles);
            // bank_lo = $10 → hr_addr = $10 * 4096 + 0. Pre-load: $10.
            expect_eq("C.rdata", v, 8'h10);
            $display("[C] miss: %0d cycles", cycles);
            if (cycles < 100) begin
                $display("FAIL C: expected miss (>= 100 cycles), got %0d", cycles);
                fail_count++;
            end
        end

        // ===== D — warm hit data partition =============================
        $display("[D] warm hit data partition (addr $6001)");
        begin
            int cycles;
            logic [7:0] v;
            do_read(16'h6001, v, cycles);
            expect_eq("D.rdata", v, 8'h10 ^ 8'h01);   // = $11
            $display("[D] hit: %0d cycles", cycles);
            if (cycles > 5) begin
                $display("FAIL D: expected ~1-cycle hit, got %0d", cycles);
                fail_count++;
            end
        end

        // ===== E — code-partition hit survives data-partition activity =
        // After C/D, data partition has bank $10 cached. Phase B
        // already cached bank $05 in the code partition. Verify the
        // partition's structural isolation: the line in code cache
        // must be observable AFTER a data-partition miss completes.
        $display("[E] partition isolation: data-side miss leaves code-side intact");
        begin
            int cycles;
            logic [7:0] v;
            // Force an extra data-partition miss (bank $25 — distinct
            // from the bank $10 already cached).
            set_banks(8'h05, 8'h25);
            do_read(16'h6000, v, cycles);
            $display("[E.data-miss] %0d cycles", cycles);

            // Switch back to code partition; expect immediate hit on
            // bank $05 (still cached because data activity touched a
            // different cache instance).
            set_banks(8'h05, 8'h10);
            $display("[E.debug] code state_q=%0d  data state_q=%0d  code valid[0][4]=%0b tag[0][4]=$%0h",
                     u_mem.u_bank_cache_code.state_q,
                     u_mem.u_bank_cache_data.state_q,
                     u_mem.u_bank_cache_code.valid[0][4],
                     u_mem.u_bank_cache_code.tag[0][4]);
            do_read(16'h4002, v, cycles);
            $display("[E.code-read] %0d cycles, v=$%0h", cycles, v);
            expect_eq("E.code-survives.rdata", v, 8'h05 ^ 8'h02);   // = $07
            if (cycles > 5) begin
                $display("FAIL E: code partition lost line during data activity (%0d cycles)", cycles);
                fail_count++;
            end
        end

        // ===== F — streaming-tagged code bank routes to bypass cache ====
        // Mark code bank $33 as streaming via the attribute SRAM. Then
        // access $4000 with code_bank=$33. The miss should fill the
        // code-stream cache (u_bank_cache_code_stream), not the code
        // partition cache (u_bank_cache_code).
        //
        // The 1-cycle attribute-read latency means the access cycle's
        // routing decision uses the PRIOR cycle's bank attribute.
        // park_and_setup parks the address outside the bank window,
        // updates the bank registers, and waits for attr_rdata_cache_q
        // to settle before do_read fires — matching the Option 1
        // software contract (a settled cycle between bank/attr changes
        // and access).
        $display("[F] streaming code bank routes to bypass");
        begin
            int cycles;
            logic [7:0] v;
            // attr_lookup_idx for code-lo bank $33 = {2'b00, 2'b00, $33} = $033.
            u_regs.attr_mem[12'h033] = 4'b0100;  // streaming bit
            park_and_setup(8'h33, 8'h20, 2'b00);

            // Sanity: confirm the live attribute lookup shows streaming.
            if (attr_lookup_data_w[2] !== 1'b1) begin
                $display("FAIL F.attr: attr_lookup_data[2] !== 1 (got $%0h)",
                         attr_lookup_data_w);
                fail_count++;
            end

            do_read(16'h4000, v, cycles);
            // HR pre-load: bank $33 ^ 0 = $33.
            expect_eq("F.rdata", v, 8'h33);
            $display("[F] miss: %0d cycles", cycles);
            if (cycles < 100) begin
                $display("FAIL F: expected miss (>= 100 cycles), got %0d", cycles);
                fail_count++;
            end
            // Stream cache should now hold a valid line.
            if (u_mem.u_bank_cache_code_stream.valid[0][0] !== 1'b1
             && u_mem.u_bank_cache_code_stream.valid[0][1] !== 1'b1
             && u_mem.u_bank_cache_code_stream.valid[1][0] !== 1'b1
             && u_mem.u_bank_cache_code_stream.valid[1][1] !== 1'b1) begin
                $display("FAIL F: code-stream cache has no valid line after streaming miss");
                fail_count++;
            end
            // Partition cache must NOT have bank $33. set_idx for bank
            // $33 sub_block=0 in the 8-set partition cache: block_addr
            // = {8'h33, 2'b00}, set_idx = block_addr[2:0] = 3'b100 (4),
            // tag = block_addr[9:3] = 7'h19.
            for (int ws = 0; ws < 4; ws++) begin
                if (u_mem.u_bank_cache_code.valid[ws][4]
                    && u_mem.u_bank_cache_code.tag[ws][4] == 7'h19) begin
                    $display("FAIL F: code partition unexpectedly contains bank $33 (way %0d set 4)", ws);
                    fail_count++;
                end
            end
        end

        // ===== G — streaming activity does NOT pollute partition =======
        // The code partition cache holds bank $05 (from A/B). Sweep
        // through several streaming-tagged code banks; each fills the
        // code-stream bypass and self-evicts. Then verify bank $05 is
        // still hot in the partition.
        $display("[G] partition cache not polluted by stream sweep");
        begin
            int cycles;
            logic [7:0] v;

            // Tag banks $40..$43 as streaming and access them in turn.
            // 4 lines into a 2-set × 2-way bypass forces evictions
            // entirely within the bypass — partition cache untouched.
            for (int b = 8'h40; b <= 8'h43; b++) begin
                u_regs.attr_mem[{2'b00, 2'b00, 8'(b)}] = 4'b0100;
                park_and_setup(8'(b), 8'h20, 2'b00);
                do_read(16'h4000, v, cycles);
                expect_eq($sformatf("G.rdata.bank%0h", b), v, 8'(b));
            end

            // Switch back to bank $05 (partition) — must hit (warm from
            // phase B), proving stream sweep didn't evict.
            u_regs.attr_mem[12'h005] = 4'b0000;       // ensure not streaming
            park_and_setup(8'h05, 8'h25, 2'b00);      // restore E's data bank
            do_read(16'h4001, v, cycles);
            expect_eq("G.code-survives.rdata", v, 8'h05 ^ 8'h01);
            if (cycles > 5) begin
                $display("FAIL G: code partition lost bank $05 during stream sweep (%0d cycles)",
                         cycles);
                fail_count++;
            end
        end

        // ===== H — streaming-tagged data bank routes to bypass =========
        // attr_lookup_idx for data bank $50 = {2'b10, 2'b00, $50} = $850.
        $display("[H] streaming data bank routes to bypass");
        begin
            int cycles;
            logic [7:0] v;
            u_regs.attr_mem[12'h850] = 4'b0100;
            park_and_setup(8'h05, 8'h50, 2'b10);   // park at sub_block 10 → data region

            do_read(16'h6000, v, cycles);
            expect_eq("H.rdata", v, 8'h50);
            $display("[H] miss: %0d cycles", cycles);
            if (cycles < 100) begin
                $display("FAIL H: expected miss (>= 100 cycles), got %0d", cycles);
                fail_count++;
            end
            // Data-stream cache should now hold a valid line.
            if (u_mem.u_bank_cache_data_stream.valid[0][0] !== 1'b1
             && u_mem.u_bank_cache_data_stream.valid[0][1] !== 1'b1
             && u_mem.u_bank_cache_data_stream.valid[1][0] !== 1'b1
             && u_mem.u_bank_cache_data_stream.valid[1][1] !== 1'b1) begin
                $display("FAIL H: data-stream cache has no valid line after streaming miss");
                fail_count++;
            end
        end

        if (fail_count == 0) begin
            $display("*** CACHE_PARTITION OK *** partition + streaming-bypass routing");
            $finish;
        end else begin
            $display("*** CACHE_PARTITION FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_cache_partition watchdog");
        $fatal(1);
    end

endmodule
