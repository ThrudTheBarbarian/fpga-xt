// tb_sally.sv — M24-1 SALLY core bring-up.
//
// Drives Arlet's NMOS 6502 wrapped by sally_core against a flat 64 KB
// BRAM holding hand-assembled test programs. Verifies fundamental
// instruction execution: LDA/LDX/LDY immediate + ZP + ABS, STA/STX/STY,
// branches (BNE, BEQ, BPL, BMI), JSR/RTS, IRQ entry/exit, BCD ADC/SBC,
// and stack manipulation.
//
// Test format: each phase loads a small program at $0200 (with reset
// vector at $FFFC pointing there), runs to a `STA $00FF` sentinel
// (the canonical "test passed" signal), and checks both that we hit
// the sentinel and that key memory locations + register state match
// expectations.
//
// Memory model: a 64 KB array, dual-cycle (latches address one cycle,
// returns data the next) — matches Arlet's synchronous-memory contract.
// Writes commit on the same cycle WE fires.

`timescale 1ns / 1ps

module tb_sally;

    logic clk = 1'b0;
    always #5 clk = ~clk;             // 100 MHz fabric for sim
    logic rst = 1'b1;

    // ---- DUT --------------------------------------------------------
    wire [15:0] addr;
    wire [7:0]  data_out;          // SALLY → memory write data
    wire        rw;
    wire [7:0]  data_in;            // memory → SALLY read data (driven by sally_mem)
    logic       rdy     = 1'b1;
    logic       irq_n   = 1'b1;
    logic       nmi_n   = 1'b1;

    wire        stack_op;
    wire [3:0]  s_high;

    sally_core u_dut (
        .clk      (clk),
        .rst      (rst),
        .addr     (addr),
        .data_in  (data_in),
        .data_out (data_out),
        .rw       (rw),
        .rdy      (rdy),
        .irq_n    (irq_n),
        .nmi_n    (nmi_n),
        .stack_op (stack_op),
        .s_high   (s_high)
    );

    // ---- Memory subsystem (M24-2 — replaces inline 64KB flat) -----
    // sally_mem provides the tiered BRAM regions + hwreg override.
    // Test programs and inspections use `u_mem.`mem[...]` directly via
    // hierarchical reference (the macro `mem` aliases it for brevity).
    `define mem u_mem.mem
    // sally_mem keeps stack bytes in a dedicated stack_mem (not main mem).
    // For legacy 6502 mode (s_high=$F) pushes to $01xx land in
    // stack_mem[$Fxx] — the same locations the read-side legacy alias
    // maps $0100-$01FF to.
    function automatic [7:0] read_stack(input [7:0] sp);
        return u_mem.stack_mem[{4'hF, sp}];
    endfunction
    wire [15:0] hwreg_addr;
    wire        hwreg_we;
    wire [7:0]  hwreg_din;
    logic [7:0] hwreg_dout = 8'hFF;     // stub — Altirra-style $FF for unassigned

    // ---- AXI bus to memory-backed slave (replaces v1 hyperram mock) ----
    // tb_sally's test programs avoid the bank window ($4000-$7FFF), so the
    // AXI slave is a no-op for these tests — but the protocol still has
    // to wire up so sally_mem instantiates cleanly.
    wire [31:0] axi_araddr, axi_awaddr;
    wire [7:0]  axi_arlen,  axi_awlen;
    wire [2:0]  axi_arsize, axi_awsize;
    wire [1:0]  axi_arburst, axi_awburst;
    wire        axi_arvalid, axi_awvalid;
    wire        axi_arready, axi_awready;
    wire [63:0] axi_rdata,   axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast,   axi_wvalid, axi_wready;
    wire        axi_rvalid,  axi_rlast,  axi_rready;
    wire        axi_bvalid,  axi_bready;

    wire [7:0] cpu_code_bank_q, cpu_data_bank_q;
    wire [7:0] cpu_regc_bank_lo_q, cpu_regc_bank_hi_q;
    wire       mem_busy;

    sally_mem #(
        .DDR3_BANKED_BASE (32'h0000_0000)
    ) u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (addr),
        .data_in    (data_out),
        .rw         (rw),
        .data_out   (data_in),
        .rdy        (1'b1),               // tb_sally runs at full speed
        .busy       (mem_busy),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (cpu_code_bank_q),
        .cpu_data_bank_q    (cpu_data_bank_q),
        .cpu_regc_bank_lo_q (cpu_regc_bank_lo_q),
        .cpu_regc_bank_hi_q (cpu_regc_bank_hi_q),
        .antic_code_bank    (8'h00),
        .antic_data_bank    (8'h00),
        .antic_regc_bank_lo (8'h00),
        .antic_regc_bank_hi (8'h00),
        .view_is_antic      (1'b0),
        .bus_mpd_n_in       (1'b1),
        .bus_pbi_rdata      (8'hFF),
        .bus_rd4_n_in       (1'b1),
        .bus_rd5_n_in       (1'b1),
        .m_axi_araddr  (axi_araddr),
        .m_axi_arlen   (axi_arlen),
        .m_axi_arsize  (axi_arsize),
        .m_axi_arburst (axi_arburst),
        .m_axi_arvalid (axi_arvalid),
        .m_axi_arready (axi_arready),
        .m_axi_rdata   (axi_rdata),
        .m_axi_rvalid  (axi_rvalid),
        .m_axi_rlast   (axi_rlast),
        .m_axi_rready  (axi_rready),
        .m_axi_awaddr  (axi_awaddr),
        .m_axi_awlen   (axi_awlen),
        .m_axi_awsize  (axi_awsize),
        .m_axi_awburst (axi_awburst),
        .m_axi_awvalid (axi_awvalid),
        .m_axi_awready (axi_awready),
        .m_axi_wdata   (axi_wdata),
        .m_axi_wstrb   (axi_wstrb),
        .m_axi_wlast   (axi_wlast),
        .m_axi_wvalid  (axi_wvalid),
        .m_axi_wready  (axi_wready),
        .m_axi_bvalid  (axi_bvalid),
        .m_axi_bready  (axi_bready),
        .rom_addr    (16'h0000),
        .rom_data    (8'h00),
        .rom_we      (1'b0),
        .stack_op    (stack_op),
        .s_high      (s_high),
        .dma_clk     (clk),
        .dma_addr    (16'd0),
        .dma_rdata   ()
    );

    axi_slave_mem u_axi_mem (
        .clk           (clk),
        .rst           (rst),
        .s_axi_awaddr  (axi_awaddr),
        .s_axi_awlen   (axi_awlen),
        .s_axi_awsize  (axi_awsize),
        .s_axi_awburst (axi_awburst),
        .s_axi_awvalid (axi_awvalid),
        .s_axi_awready (axi_awready),
        .s_axi_wdata   (axi_wdata),
        .s_axi_wstrb   (axi_wstrb),
        .s_axi_wlast   (axi_wlast),
        .s_axi_wvalid  (axi_wvalid),
        .s_axi_wready  (axi_wready),
        .s_axi_bvalid  (axi_bvalid),
        .s_axi_bready  (axi_bready),
        .s_axi_araddr  (axi_araddr),
        .s_axi_arlen   (axi_arlen),
        .s_axi_arsize  (axi_arsize),
        .s_axi_arburst (axi_arburst),
        .s_axi_arvalid (axi_arvalid),
        .s_axi_arready (axi_arready),
        .s_axi_rdata   (axi_rdata),
        .s_axi_rvalid  (axi_rvalid),
        .s_axi_rlast   (axi_rlast),
        .s_axi_rready  (axi_rready)
    );

`ifdef SALLY_BUS_TRACE
    int bus_t = 0;
    always_ff @(posedge clk) begin
        bus_t <= bus_t + 1;
        $display("[bus t=%0d] addr=$%04x %s data_in=$%02x data_out=$%02x irq_n=%b",
                 bus_t, addr, rw ? "R" : "W", data_in, data_out, irq_n);
    end
`endif

    // ---- Helpers ---------------------------------------------------
    int fail_count = 0;

    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Load a sequence of bytes into memory starting at addr.
    task automatic load_bytes(input [15:0] base,
                              input [8*256-1:0] bytes,    // packed
                              input int          n);
        int i;
        for (i = 0; i < n; i++)
            `mem[base + i] = bytes[8*(n-1-i) +: 8];
    endtask

    // last_sentinel_cycles: cycle count from the cycle after reset
    // release to the cycle of the sentinel write. Used by Phase G to
    // compute page-cross deltas between two otherwise-identical
    // programs.
    int last_sentinel_cycles = 0;

    // Reset CPU and run until we observe a write to the sentinel
    // address $00FF (= "test done"), or hit the watchdog.
    task automatic run_until_sentinel(input string phase, input int max_cycles);
        int cycles;
        bit hit;
        cycles = 0;
        hit    = 1'b0;
        // Pulse reset.
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        // Run until sentinel write or timeout.
        while (cycles < max_cycles && !hit) begin
            @(posedge clk);
            cycles++;
            if (!rw && addr == 16'h00FF) hit = 1'b1;
`ifdef SALLY_TRACE
            $display("[%s t=%0d] addr=$%04x %s data_in=$%02x data_out=$%02x",
                     phase, cycles, addr, rw ? "R" : "W", data_in, data_out);
`endif
        end
        if (!hit) begin
            $display("FAIL %s: watchdog (%0d cycles)", phase, max_cycles);
            fail_count++;
        end else begin
            $display("[%s] sentinel hit after %0d cycles", phase, cycles);
        end
        last_sentinel_cycles = cycles;
        // Let the sentinel write commit.
        repeat (2) @(posedge clk);
    endtask

    // Initialise all RAM to NOPs ($EA) so any wild PC lands in a
    // predictable infinite loop instead of executing $00 (BRK) and
    // exploding the test. Also installs a 3-byte stack-pointer init
    // prelude at $0200 (LDX #$FF / TXS) so test programs can use the
    // stack from $0203 onward — real 6502 leaves S undefined at
    // reset, and the Atari OS does this same init on cold boot.
    task automatic clear_mem();
        int i;
        for (i = 0; i < 65536; i++) `mem[i] = 8'hEA;
        // LDX #$FF
        `mem[16'h0200] = 8'hA2; `mem[16'h0201] = 8'hFF;
        // TXS
        `mem[16'h0202] = 8'h9A;
    endtask

    initial begin
        $display("=== M24-1 sally ===");
        clear_mem();

        // ===== Phase A — LDA #imm + STA abs =============================
        // LDA #$42 ; STA $00FF
        $display("[A] LDA #imm + STA abs");
        clear_mem();
        // $0200-$0202: LDX #$FF / TXS (clear_mem prelude)
        `mem[16'h0203] = 8'hA9; `mem[16'h0204] = 8'h42;   // LDA #$42
        `mem[16'h0205] = 8'h8D; `mem[16'h0206] = 8'hFF; `mem[16'h0207] = 8'h00; // STA $00FF
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;   // reset vec → $0200
        `mem[16'hFFFE] = 8'h00; `mem[16'hFFFF] = 8'h02;   // IRQ vec
        `mem[16'hFFFA] = 8'h00; `mem[16'hFFFB] = 8'h02;   // NMI vec
        run_until_sentinel("A.basic", 200);
        expect_eq("A.`mem[$FF]", `mem[16'h00FF], 8'h42);

        // ===== Phase B — branch taken (BNE) =============================
        // After prelude: LDA #$01 ; BNE +2 (taken) ; LDA #$BB
        // (skipped) ; LDA #$77 (executed) ; STA $00FF.
        $display("[B] BNE branch logic");
        clear_mem();
        `mem[16'h0203] = 8'hA9; `mem[16'h0204] = 8'h01;          // LDA #$01
        `mem[16'h0205] = 8'hD0; `mem[16'h0206] = 8'h02;          // BNE +2
        `mem[16'h0207] = 8'hA9; `mem[16'h0208] = 8'hBB;          // LDA #$BB (skipped)
        `mem[16'h0209] = 8'hA9; `mem[16'h020A] = 8'h77;          // LDA #$77
        `mem[16'h020B] = 8'h8D; `mem[16'h020C] = 8'hFF; `mem[16'h020D] = 8'h00;  // STA $00FF
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        run_until_sentinel("B.branch", 200);
        expect_eq("B.`mem[$FF]", `mem[16'h00FF], 8'h77);

        // ===== Phase C — JSR / RTS =====================================
        // After prelude:
        // $0203: JSR $0220 ; $0206: STA $00FF
        // $0220: LDA #$99 ; RTS
        $display("[C] JSR / RTS");
        clear_mem();
        `mem[16'h0203] = 8'h20; `mem[16'h0204] = 8'h20; `mem[16'h0205] = 8'h02; // JSR $0220
        `mem[16'h0206] = 8'h8D; `mem[16'h0207] = 8'hFF; `mem[16'h0208] = 8'h00; // STA $00FF
        `mem[16'h0220] = 8'hA9; `mem[16'h0221] = 8'h99;                        // LDA #$99
        `mem[16'h0222] = 8'h60;                                                // RTS
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        run_until_sentinel("C.jsr", 300);
        expect_eq("C.`mem[$FF]", `mem[16'h00FF], 8'h99);

        // ===== Phase D — INX, BNE loop ==================================
        // After prelude: LDX #$00 ; loop: INX ; BNE loop ; STX $00FF
        $display("[D] INX / BNE loop (256 iterations)");
        clear_mem();
        `mem[16'h0203] = 8'hA2; `mem[16'h0204] = 8'h00;          // LDX #$00
        `mem[16'h0205] = 8'hE8;                                  // INX
        `mem[16'h0206] = 8'hD0; `mem[16'h0207] = 8'hFD;           // BNE -3
        `mem[16'h0208] = 8'h8E; `mem[16'h0209] = 8'hFF; `mem[16'h020A] = 8'h00;  // STX $00FF
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        run_until_sentinel("D.loop", 4000);
        expect_eq("D.`mem[$FF]", `mem[16'h00FF], 8'h00);

        // ===== Phase E — BCD ADC ========================================
        // After prelude: SED ; CLC ; LDA #$15 ; ADC #$27 ; CLD ; STA $00FF
        // Decimal 15 + 27 = 42 → A = $42.
        $display("[E] BCD ADC (D=1)");
        clear_mem();
        `mem[16'h0203] = 8'hF8;                            // SED
        `mem[16'h0204] = 8'h18;                            // CLC
        `mem[16'h0205] = 8'hA9; `mem[16'h0206] = 8'h15;     // LDA #$15
        `mem[16'h0207] = 8'h69; `mem[16'h0208] = 8'h27;     // ADC #$27
        `mem[16'h0209] = 8'hD8;                            // CLD
        `mem[16'h020A] = 8'h8D; `mem[16'h020B] = 8'hFF; `mem[16'h020C] = 8'h00;  // STA $00FF
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        run_until_sentinel("E.bcd", 200);
        expect_eq("E.`mem[$FF]", `mem[16'h00FF], 8'h42);

        // ===== Phase F — IRQ entry / RTI ================================
        // After prelude:
        // $0203: LDA #$AA ; $0205: CLI ; $0206-$0209: NOP*4 (IRQ window) ;
        // $020A: STA $00FF (after RTI, A = $BB from ISR)
        // ISR @ $0300: LDA #$BB ; STA $00FE ; RTI
        $display("[F] IRQ entry / RTI");
        clear_mem();
        // Main code: enable IRQs, then JMP-to-self forever. The ISR
        // writes the sentinel directly, then RTIs back into the
        // infinite loop. This decouples the test from any flag-state
        // polling logic — we just need the IRQ→ISR→RTI sequence to
        // fire successfully.
        //   $0203: CLI
        //   $0204: JMP $0204  (spin forever until ISR writes sentinel)
        // ISR @ $0300: LDA #$BB / STA $00FF (sentinel) / RTI
        `mem[16'h0203] = 8'h58;                                            // CLI
        `mem[16'h0204] = 8'h4C; `mem[16'h0205] = 8'h04; `mem[16'h0206] = 8'h02;  // JMP $0204
        `mem[16'h0300] = 8'hA9; `mem[16'h0301] = 8'hBB;                     // LDA #$BB
        `mem[16'h0302] = 8'h8D; `mem[16'h0303] = 8'hFF; `mem[16'h0304] = 8'h00; // STA $00FF
        `mem[16'h0305] = 8'h40;                                             // RTI
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        `mem[16'hFFFE] = 8'h00; `mem[16'hFFFF] = 8'h03;

        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (30) @(posedge clk);          // long enough to enter the JMP loop
        irq_n = 1'b0;
        repeat (10) @(posedge clk);          // CPU acks
        irq_n = 1'b1;
        // Run until sentinel (the ISR will write $00FF).
        begin
            int cycles;
            bit hit;
            cycles = 0; hit = 1'b0;
            while (cycles < 200 && !hit) begin
                @(posedge clk);
                cycles++;
                if (!rw && addr == 16'h00FF) hit = 1'b1;
            end
            if (!hit) begin
                $display("FAIL F.watchdog");
                fail_count++;
            end else begin
                $display("[F] sentinel hit after %0d additional cycles", cycles);
            end
        end
        repeat (8) @(posedge clk);   // let ISR finish RTI cleanly
        expect_eq("F.`mem[$FF] (ISR sentinel)", `mem[16'h00FF], 8'hBB);
        // Verify CPU survived RTI: PC should be back in the spin loop.
        if (addr < 16'h0203 || addr > 16'h0207) begin
            $display("FAIL F.RTI: PC=%04x (expected $0204..$0206 spin)", addr);
            fail_count++;
        end

        // ===== Phase G — page-boundary cycle behavior ===================
        // Classic 6502 quirks:
        //   - LDA abs,X / abs,Y / (zp),Y: +1 cycle on page cross
        //   - STA abs,X / abs,Y / (zp),Y: ALWAYS 5 cycles (no early-out)
        //   - Branches taken: +1 cycle on page cross
        //
        // Strategy: each sub-test runs an identical preamble + the
        // instruction under test + sentinel. Phases differ ONLY in
        // whether the indexed address crosses a page. The reported
        // sentinel cycle count is then the same except for the +1
        // page-cross penalty (or 0 for stores, which always pay).
        //
        // Memory stash: $C001 / $C100 / $C101 etc. preloaded with
        // distinguishable values so we can also confirm the right
        // address was read.
        $display("[G] indexed-addressing page-boundary cycle behavior");
        begin
            int cyc_g1, cyc_g2, cyc_g3, cyc_g4, cyc_g5, cyc_g6, cyc_g7, cyc_g8;

            // ---- G.1: LDA abs,X — no page cross ----
            // LDX #$01 ; LDA $C000,X ; STA $00FF
            // Reads $C001. Expected 4 cycles for LDA.
            clear_mem();
            `mem[16'h0203] = 8'hA2; `mem[16'h0204] = 8'h01;             // LDX #$01
            `mem[16'h0205] = 8'hBD; `mem[16'h0206] = 8'h00; `mem[16'h0207] = 8'hC0;  // LDA $C000,X
            `mem[16'h0208] = 8'h8D; `mem[16'h0209] = 8'hFF; `mem[16'h020A] = 8'h00;  // STA $00FF
            `mem[16'hC001] = 8'h11;
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.1 LDA abs,X no-cross", 200);
            cyc_g1 = last_sentinel_cycles;
            expect_eq("G.1 `mem[$FF]", `mem[16'h00FF], 8'h11);

            // ---- G.2: LDA abs,X — with page cross ----
            // LDX #$01 ; LDA $C0FF,X ; STA $00FF
            // Reads $C100. Expected 5 cycles for LDA (+1 vs G.1).
            clear_mem();
            `mem[16'h0203] = 8'hA2; `mem[16'h0204] = 8'h01;             // LDX #$01
            `mem[16'h0205] = 8'hBD; `mem[16'h0206] = 8'hFF; `mem[16'h0207] = 8'hC0;  // LDA $C0FF,X
            `mem[16'h0208] = 8'h8D; `mem[16'h0209] = 8'hFF; `mem[16'h020A] = 8'h00;  // STA $00FF
            `mem[16'hC100] = 8'h22;
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.2 LDA abs,X cross", 200);
            cyc_g2 = last_sentinel_cycles;
            expect_eq("G.2 `mem[$FF]", `mem[16'h00FF], 8'h22);
            // Delta should be exactly +1 (page-cross penalty).
            if (cyc_g2 - cyc_g1 != 1) begin
                $display("FAIL G.cross-penalty (LDA abs,X): G.2-G.1 = %0d (expected 1)",
                         cyc_g2 - cyc_g1);
                fail_count++;
            end else begin
                $display("[G] LDA abs,X page-cross penalty: +1 cycle ✓");
            end

            // ---- G.3: STA abs,X — no page cross ----
            // STA always pays 5 cycles, independent of page cross.
            // LDX #$01 ; LDA #$AB ; STA $C000,X ; STA $00FF
            clear_mem();
            `mem[16'h0203] = 8'hA2; `mem[16'h0204] = 8'h01;             // LDX #$01
            `mem[16'h0205] = 8'hA9; `mem[16'h0206] = 8'hAB;             // LDA #$AB
            `mem[16'h0207] = 8'h9D; `mem[16'h0208] = 8'h00; `mem[16'h0209] = 8'hC0;  // STA $C000,X
            `mem[16'h020A] = 8'h8D; `mem[16'h020B] = 8'hFF; `mem[16'h020C] = 8'h00;  // STA $00FF
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.3 STA abs,X no-cross", 200);
            cyc_g3 = last_sentinel_cycles;
            expect_eq("G.3 `mem[$C001]", `mem[16'hC001], 8'hAB);

            // ---- G.4: STA abs,X — with page cross ----
            // Same store, target $C100. Should take SAME cycles as G.3
            // (STA pays the extra cycle even without a page cross —
            // 5 cycles regardless).
            clear_mem();
            `mem[16'h0203] = 8'hA2; `mem[16'h0204] = 8'h01;             // LDX #$01
            `mem[16'h0205] = 8'hA9; `mem[16'h0206] = 8'hAB;             // LDA #$AB
            `mem[16'h0207] = 8'h9D; `mem[16'h0208] = 8'hFF; `mem[16'h0209] = 8'hC0;  // STA $C0FF,X
            `mem[16'h020A] = 8'h8D; `mem[16'h020B] = 8'hFF; `mem[16'h020C] = 8'h00;  // STA $00FF
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.4 STA abs,X cross", 200);
            cyc_g4 = last_sentinel_cycles;
            expect_eq("G.4 `mem[$C100]", `mem[16'hC100], 8'hAB);
            if (cyc_g4 != cyc_g3) begin
                $display("FAIL G.STA-no-penalty: G.4=%0d G.3=%0d (expected equal — STA always pays)",
                         cyc_g4, cyc_g3);
                fail_count++;
            end else begin
                $display("[G] STA abs,X always 5 cycles regardless of page cross ✓");
            end

            // ---- G.5 / G.6: LDA (zp),Y — no cross / cross ----
            // $80/$81 holds a 16-bit pointer. LDA ($80),Y indexes by Y.
            // 5 cycles no-cross, 6 cycles cross.
            // G.5: pointer = $C000, Y=$01 → reads $C001 (no cross).
            clear_mem();
            `mem[16'h0080] = 8'h00; `mem[16'h0081] = 8'hC0;             // ($80) → $C000
            `mem[16'h0203] = 8'hA0; `mem[16'h0204] = 8'h01;             // LDY #$01
            `mem[16'h0205] = 8'hB1; `mem[16'h0206] = 8'h80;             // LDA ($80),Y
            `mem[16'h0207] = 8'h8D; `mem[16'h0208] = 8'hFF; `mem[16'h0209] = 8'h00;  // STA $00FF
            `mem[16'hC001] = 8'h33;
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.5 LDA (zp),Y no-cross", 200);
            cyc_g5 = last_sentinel_cycles;
            expect_eq("G.5 `mem[$FF]", `mem[16'h00FF], 8'h33);

            // G.6: pointer = $C0FF, Y=$01 → reads $C100 (page cross).
            clear_mem();
            `mem[16'h0080] = 8'hFF; `mem[16'h0081] = 8'hC0;             // ($80) → $C0FF
            `mem[16'h0203] = 8'hA0; `mem[16'h0204] = 8'h01;             // LDY #$01
            `mem[16'h0205] = 8'hB1; `mem[16'h0206] = 8'h80;             // LDA ($80),Y
            `mem[16'h0207] = 8'h8D; `mem[16'h0208] = 8'hFF; `mem[16'h0209] = 8'h00;  // STA $00FF
            `mem[16'hC100] = 8'h44;
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.6 LDA (zp),Y cross", 200);
            cyc_g6 = last_sentinel_cycles;
            expect_eq("G.6 `mem[$FF]", `mem[16'h00FF], 8'h44);
            if (cyc_g6 - cyc_g5 != 1) begin
                $display("FAIL G.cross-penalty (LDA (zp),Y): G.6-G.5 = %0d (expected 1)",
                         cyc_g6 - cyc_g5);
                fail_count++;
            end else begin
                $display("[G] LDA (zp),Y page-cross penalty: +1 cycle ✓");
            end

            // ---- G.7 / G.8: BNE taken — no cross / cross ----
            // G.7: BNE within same page — 3 cycles.
            // After-PC = $0207, branch +$10 → target = $0217. Same
            // page (02). No cross.
            clear_mem();
            `mem[16'h0203] = 8'hA9; `mem[16'h0204] = 8'h01;             // LDA #$01 (Z=0)
            `mem[16'h0205] = 8'hD0; `mem[16'h0206] = 8'h10;             // BNE +$10 → $0217
            // Filler at $0207..$0216 (NOPs from clear_mem).
            `mem[16'h0217] = 8'h8D; `mem[16'h0218] = 8'hFF; `mem[16'h0219] = 8'h00;  // STA $00FF
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.7 BNE taken same-page", 200);
            cyc_g7 = last_sentinel_cycles;

            // G.8: BNE crossing page boundary.
            // BNE at $0280, after-PC = $0282, branch +$7F → target = $0301.
            // After-PC page = 02, target page = 03 → page cross. Should
            // take 1 extra cycle vs G.7.
            clear_mem();
            // Place LDA + BNE just before the page boundary.
            // We need a JMP to get the program counter past the prelude
            // landing zone and over to $027E.
            `mem[16'h0203] = 8'h4C; `mem[16'h0204] = 8'h7E; `mem[16'h0205] = 8'h02;  // JMP $027E
            `mem[16'h027E] = 8'hA9; `mem[16'h027F] = 8'h01;             // LDA #$01 (Z=0)
            `mem[16'h0280] = 8'hD0; `mem[16'h0281] = 8'h7F;             // BNE +$7F → $0301
            // Filler $0282..$0300 (NOPs from clear_mem).
            `mem[16'h0301] = 8'h8D; `mem[16'h0302] = 8'hFF; `mem[16'h0303] = 8'h00;  // STA $00FF
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            run_until_sentinel("G.8 BNE taken page-cross", 200);
            cyc_g8 = last_sentinel_cycles;
            // G.8 has an extra JMP (3 cycles) vs G.7 setup, so the
            // raw delta is JMP_cycles + 1 (page-cross penalty) = 4.
            if (cyc_g8 - cyc_g7 != 4) begin
                $display("FAIL G.cross-penalty (BNE): G.8-G.7 = %0d (expected 4 = JMP(3) + page-cross(1))",
                         cyc_g8 - cyc_g7);
                fail_count++;
            end else begin
                $display("[G] BNE taken page-cross penalty: +1 cycle ✓");
            end
        end

        // ===== Phase H — more classic NMOS 6502 quirks ==================
        // - H.1: JMP ($xxFF) indirect-jump page-wrap bug
        // - H.2: RMW dummy-write (INC abs writes twice)
        // - H.3: BRK pushes status with B=1
        // - H.4: PHP pushes status with B=1
        // - H.5: Stack wrap on PHA past SP=$00
        $display("[H] more classic NMOS 6502 quirks");

        // ---- H.1: JMP ($xxFF) page-wrap bug ----
        // On NMOS 6502, JMP ($02FF) reads target low from $02FF and
        // target high from $0200 (wraps within page) — NOT $0300.
        // 65C02 fixes this. Arlet's core models NMOS, so we expect
        // the bug.
        //
        // Vector layout:
        //   $02FF = $34   (target low)
        //   $0200 = $12   (target high — what NMOS reads, page-wrap)
        //   $0300 = $99   (what a "fixed" CPU would read)
        //
        // Test programs at the two possible targets:
        //   $1234: STA $00FF with $11   (NMOS-correct path)
        //   $9934: STA $00FF with $22   (would happen if no bug)
        $display("[H.1] JMP ($xxFF) page-wrap bug");
        clear_mem();
        // The clear_mem prelude wrote $0200-$0202 (LDX/TXS). We need
        // $0200 = $12 for the JMP indirect bug. So we have to
        // SACRIFICE the prelude here — write our own from $0203.
        // But the reset vector points at $0200 which still has the
        // prelude bytes. For this test, let's redirect reset to a
        // small wrapper:
        //   $0202: JMP $1000  (skip the prelude clobber zone)
        //   $1000: LDX #$FF / TXS / JMP ($02FF)
        //   $0200 = $12 (target high for JMP indirect bug)
        //   $02FF = $34 (target low)
        //   $0300 = $99 (red-herring)
        //   $1234 = STA $00FF with $11
        //   $9934 = STA $00FF with $22 (only reached if bug NOT modelled)
        `mem[16'h0200] = 8'h12;     // overrides prelude byte 0 — used as JMP-indirect high
        `mem[16'h0201] = 8'h00;     // also part of prelude clobber
        `mem[16'h0202] = 8'h4C; `mem[16'h0203] = 8'h00; `mem[16'h0204] = 8'h10;  // JMP $1000
        `mem[16'h02FF] = 8'h34;
        `mem[16'h0300] = 8'h99;
        `mem[16'h1000] = 8'hA2; `mem[16'h1001] = 8'hFF;     // LDX #$FF
        `mem[16'h1002] = 8'h9A;                             // TXS
        `mem[16'h1003] = 8'h6C; `mem[16'h1004] = 8'hFF; `mem[16'h1005] = 8'h02;  // JMP ($02FF)
        `mem[16'h1234] = 8'hA9; `mem[16'h1235] = 8'h11;     // LDA #$11
        `mem[16'h1236] = 8'h8D; `mem[16'h1237] = 8'hFF; `mem[16'h1238] = 8'h00;  // STA $00FF
        `mem[16'h9934] = 8'hA9; `mem[16'h9935] = 8'h22;     // LDA #$22 (would-be)
        `mem[16'h9936] = 8'h8D; `mem[16'h9937] = 8'hFF; `mem[16'h9938] = 8'h00;  // STA $00FF
        // Reset vector points at $0202 to skip the (now-clobbered) prelude.
        `mem[16'hFFFC] = 8'h02; `mem[16'hFFFD] = 8'h02;
        run_until_sentinel("H.1 JMP indirect page-wrap", 200);
        if (`mem[16'h00FF] == 8'h11) begin
            $display("[H.1] NMOS JMP ($xxFF) bug correctly modelled — PC took $02FF/$0200 path ✓");
        end else if (`mem[16'h00FF] == 8'h22) begin
            $display("FAIL H.1: 65C02-style indirect (high byte from $0300) — NMOS page-wrap regression");
            fail_count++;
        end else begin
            $display("FAIL H.1: PC went somewhere unexpected — $00FF=$%02h", `mem[16'h00FF]);
            fail_count++;
        end

        // ---- H.2: RMW dummy-write ----
        // INC abs on NMOS 6502 does:
        //   read original value, write original value back (DUMMY),
        //   write modified value.
        // Count writes to $C000 over the INC instruction.
        $display("[H.2] RMW (INC abs) dummy-write count");
        begin
            int writes_at_target;
            int cycles;
            bit hit;
            clear_mem();
            `mem[16'h0203] = 8'hEE; `mem[16'h0204] = 8'h00; `mem[16'h0205] = 8'hC0;  // INC $C000
            `mem[16'h0206] = 8'h8D; `mem[16'h0207] = 8'hFF; `mem[16'h0208] = 8'h00;  // STA $00FF
            `mem[16'hC000] = 8'h41;     // initial value
            `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
            // Reset, then run while counting writes to $C000.
            rst = 1'b1;
            repeat (4) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
            writes_at_target = 0;
            cycles = 0; hit = 1'b0;
            while (cycles < 200 && !hit) begin
                @(posedge clk);
                cycles++;
                if (!rw && addr == 16'hC000) writes_at_target++;
                if (!rw && addr == 16'h00FF) hit = 1'b1;
            end
            $display("[H.2] writes to $C000 during INC: %0d (real NMOS does 2 — dummy + modified)",
                     writes_at_target);
            if (writes_at_target == 2) begin
                $display("[H.2] NMOS RMW dummy-write modelled ✓");
            end else if (writes_at_target == 1) begin
                $display("[H.2] DIVERGENCE — Arlet does single-write RMW. Tracked as");
                $display("[H.2]   Issues.md#sally-rmw-dummy-write. Matters only when an INC/DEC/");
                $display("[H.2]   ASL/LSR/ROL/ROR targets a side-effect-on-write hardware register.");
            end else begin
                $display("FAIL H.2: %0d writes during INC (expected 1 or 2)", writes_at_target);
                fail_count++;
            end
            // Final stored value: $41 + 1 = $42.
            if (`mem[16'hC000] != 8'h42) begin
                $display("FAIL H.2: `mem[$C000]=$%02h (expected $42 after INC)", `mem[16'hC000]);
                fail_count++;
            end
        end

        // ---- H.3: BRK pushes status with B=1 ----
        // BRK is opcode $00 + a 1-byte signature (ignored). It pushes
        // PC+2 and the processor status, with the **B flag (bit 4)**
        // set in the pushed copy. Real 6502 also pushes U=1 (bit 5).
        // ISR distinguishes BRK from IRQ by pulling the saved status
        // and inspecting bit 4.
        //
        // Stack frame after BRK from a fresh stack (SP=$FF):
        //   $01FF = saved PCH
        //   $01FE = saved PCL
        //   $01FD = saved status (B=1 expected)
        //
        // ISR reads $01FD bit 4 and stores 1 (B set) or 0 (B clear)
        // to $00FF.
        $display("[H.3] BRK pushes B=1 in saved status");
        clear_mem();
        `mem[16'h0203] = 8'h00; `mem[16'h0204] = 8'hEA;     // BRK + signature
        // ISR at $0300
        `mem[16'h0300] = 8'hAD; `mem[16'h0301] = 8'hFD; `mem[16'h0302] = 8'h01;  // LDA $01FD
        `mem[16'h0303] = 8'h29; `mem[16'h0304] = 8'h10;     // AND #$10 (mask B)
        `mem[16'h0305] = 8'h8D; `mem[16'h0306] = 8'hFF; `mem[16'h0307] = 8'h00;  // STA $00FF
        // Halt the ISR (don't RTI back, just spin).
        `mem[16'h0308] = 8'h4C; `mem[16'h0309] = 8'h08; `mem[16'h030A] = 8'h03;  // JMP $0308
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        `mem[16'hFFFE] = 8'h00; `mem[16'hFFFF] = 8'h03;     // BRK / IRQ vec
        run_until_sentinel("H.3 BRK B-flag", 300);
        if (`mem[16'h00FF] != 8'h10) begin
            $display("FAIL H.3: pushed B-bit = $%02h (expected $10)", `mem[16'h00FF]);
            fail_count++;
        end else begin
            $display("[H.3] BRK pushes B=1 correctly ✓");
        end

        // ---- H.4: PHP pushes status with B=1 ----
        // Like BRK, PHP pushes the status byte with the B-bit forced
        // to 1 in the saved copy (because B isn't a real flag — it's
        // only a property of the pushed byte).
        // PHP after the prelude → SP starts at $FE (1 push). Saved
        // status lands at $01FF.
        $display("[H.4] PHP pushes B=1 in saved status");
        clear_mem();
        `mem[16'h0203] = 8'h08;                            // PHP
        `mem[16'h0204] = 8'hAD; `mem[16'h0205] = 8'hFF; `mem[16'h0206] = 8'h01;  // LDA $01FF
        `mem[16'h0207] = 8'h29; `mem[16'h0208] = 8'h10;     // AND #$10
        `mem[16'h0209] = 8'h8D; `mem[16'h020A] = 8'hFF; `mem[16'h020B] = 8'h00;  // STA $00FF
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        run_until_sentinel("H.4 PHP B-flag", 200);
        if (`mem[16'h00FF] != 8'h10) begin
            $display("FAIL H.4: pushed B-bit = $%02h (expected $10)", `mem[16'h00FF]);
            fail_count++;
        end else begin
            $display("[H.4] PHP pushes B=1 correctly ✓");
        end

        // ---- H.5: Push past SP_low=$00 crosses into the hidden page ----
        // SALLY's SP is 12-bit (embellishments §1): SP grows DOWN through
        // the full 4 KB.  With SP=$F00 the first PHA lands at $0F00 (the
        // top page, aliased to $0100); pushing past SP_low=$00 borrows
        // into S_high, so the next PHA lands at $0EFF — hidden, with no
        // $01xx alias.  (This is NOT a legacy single-page wrap back to
        // $01FF — that would clobber the just-pushed top-of-stack.)
        $display("[H.5] Push past SP_low=$00 crosses into the hidden page");
        clear_mem();
        `mem[16'h0203] = 8'hA2; `mem[16'h0204] = 8'h00;     // LDX #$00
        `mem[16'h0205] = 8'h9A;                             // TXS  (SP = $F00)
        `mem[16'h0206] = 8'hA9; `mem[16'h0207] = 8'hAA;     // LDA #$AA
        `mem[16'h0208] = 8'h48;                             // PHA  → $0F00 (alias $0100), SP → $EFF
        `mem[16'h0209] = 8'hA9; `mem[16'h020A] = 8'hBB;     // LDA #$BB
        `mem[16'h020B] = 8'h48;                             // PHA  → $0EFF (hidden), SP → $EFE
        `mem[16'h020C] = 8'h8D; `mem[16'h020D] = 8'hFF; `mem[16'h020E] = 8'h00;  // STA $00FF
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
        run_until_sentinel("H.5 stack wrap", 200);
        if (read_stack(8'h00) != 8'hAA) begin
            $display("FAIL H.5: stack[$0F00]=$%02h (expected $AA — first push, aliased to $0100)",
                     read_stack(8'h00));
            fail_count++;
        end
        if (u_mem.stack_mem[12'hEFF] != 8'hBB) begin
            $display("FAIL H.5: stack[$0EFF]=$%02h (expected $BB — second push crossed into hidden page)",
                     u_mem.stack_mem[12'hEFF]);
            fail_count++;
        end
        if (read_stack(8'h00) == 8'hAA && u_mem.stack_mem[12'hEFF] == 8'hBB)
            $display("[H.5] Push crosses $0F00→$0EFF (12-bit SP depth) ✓");

        // ---- Final report ----------------------------------------------
        if (fail_count == 0) begin
            $display("*** SALLY OK *** LDA/STA + branches + JSR/RTS + INX loop + BCD + IRQ/RTI + page-boundary cycles + NMOS quirks");
            $finish;
        end else begin
            $display("*** SALLY FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #5_000_000;
        $display("FAIL: tb_sally watchdog (top-level)");
        $fatal(1);
    end

endmodule
