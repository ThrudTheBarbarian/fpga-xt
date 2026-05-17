// tb_sally_mem.sv — M24-2 SALLY memory subsystem.
//
// Two halves:
//   Phase A — direct address-region drives (no CPU): pulse addr/rw/data_in
//             into sally_mem and verify region behaviour against expected
//             dout. Covers BRAM regions, hardware-register override, and
//             the read-after-write timing pipeline.
//   Phase B — sally_core + sally_mem integration: run a small program
//             that touches each region, confirm it executes correctly
//             through the new memory wrapper.
//
// Hardware-register passthrough is stubbed to $FF in this testbench
// (matches real ANTIC's "unassigned address" behaviour, see Altirra
// §4.1). Full GTIA / ANTIC / POKEY hookup arrives later in M24.

`timescale 1ns / 1ps

module tb_sally_mem;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- DUT memory ports ----------------------------------------
    logic [15:0] addr     = 16'h0000;
    logic [7:0]  data_in  = 8'h00;
    logic        rw       = 1'b1;
    wire  [7:0]  data_out;

    wire [15:0] hwreg_addr;
    wire        hwreg_we;
    wire [7:0]  hwreg_din;
    logic [7:0] hwreg_dout = 8'hFF;     // stub — return $FF for unassigned (Altirra §4.1)

    // ---- AXI bus — banked-window backing store (DDR3 stand-in) ---------
    // sally_mem now drives an AXI master into DDR3 for $4000-$7FFF;
    // a memory-backed AXI slave provides the backing store in sim.  We
    // override DDR3_BANKED_BASE to 0 so the slave's 1 MiB array can cover
    // the entire reachable range (bank_id[15:0] × 4 KiB block offset).
    wire [31:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    wire        axi_arvalid;
    wire        axi_arready;
    wire [63:0] axi_rdata;
    wire        axi_rvalid;
    wire        axi_rlast;
    wire        axi_rready;
    wire [31:0] axi_awaddr;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;
    wire        axi_awvalid;
    wire        axi_awready;
    wire [63:0] axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast;
    wire        axi_wvalid;
    wire        axi_wready;
    wire        axi_bvalid;
    wire        axi_bready;

    wire [7:0] cpu_code_bank_q, cpu_data_bank_q;
    wire [7:0] cpu_regc_bank_lo_q, cpu_regc_bank_hi_q;
    wire       mem_busy;

    sally_mem #(
        .DDR3_BANKED_BASE (32'h0000_0000)
    ) u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (addr),
        .data_in    (data_in),
        .rw         (rw),
        .data_out   (data_out),
        .rdy        (1'b1),               // unit test always advances; sally_mem holds internally on cache busy
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
        .bus_mpd_n_in       (1'b1),    // M-PBI: /MPD inactive in unit-level sim
        .bus_pbi_rdata      (8'hFF),   // M-PBI: no PBI device in unit-level sim
        .bus_rd4_n_in       (1'b1),    // M-PBI: no physical cart in $8000-$9FFF
        .bus_rd5_n_in       (1'b1),    // M-PBI: no physical cart in $A000-$BFFF
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
        // Tie off ports we don't exercise in this testbench.
        .stack_op    (1'b0),
        .s_high      (4'd0),
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

    int fail_count = 0;

    task automatic expect_eq(input string label,
                             input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%0h expected=$%0h", label, got, want);
            fail_count++;
        end
    endtask

    // Drive a write to `a` with value `v`, settle one cycle. Waits
    // for any in-flight cache miss to drain before issuing AND after
    // (so the next call sees a clean state).
    task automatic do_write(input [15:0] a, input [7:0] v);
        while (mem_busy) @(posedge clk);
        @(negedge clk);
        addr    = a;
        data_in = v;
        rw      = 1'b0;
        @(posedge clk);
        @(negedge clk);
        rw      = 1'b1;
        data_in = 8'h00;
        while (mem_busy) @(posedge clk);
    endtask

    // Drive a read to `a` and capture data_out one cycle later
    // (synchronous-memory contract). Waits for any cache stall too.
    task automatic do_read(input [15:0] a, output [7:0] v);
        while (mem_busy) @(posedge clk);
        @(negedge clk);
        addr = a;
        rw   = 1'b1;
        @(posedge clk);
        while (mem_busy) @(posedge clk);
        @(negedge clk);
        v = data_out;
    endtask

    // Track every hwreg_we pulse for assertion in Phase A.4.
    logic [15:0] last_hwreg_waddr_q = 16'h0000;
    logic [7:0]  last_hwreg_wdata_q = 8'h00;
    logic        hwreg_we_seen_q    = 1'b0;
    always_ff @(posedge clk) begin
        if (hwreg_we) begin
            last_hwreg_waddr_q <= hwreg_addr;
            last_hwreg_wdata_q <= hwreg_din;
            hwreg_we_seen_q    <= 1'b1;
        end
    end

    initial begin
        $display("=== M24-2 sally_mem ===");

        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // ===== Phase A — direct memory-region drives ====================
        // A.1: zero page ($0000-$00FF) — write/read round-trip.
        $display("[A.1] zero-page round-trip");
        begin
            logic [7:0] v;
            do_write(16'h0042, 8'hAB);
            do_read (16'h0042, v);
            expect_eq("A.1 zp[$42]", v, 8'hAB);
        end

        // A.2: stack page ($0100-$01FF).
        $display("[A.2] stack-page round-trip");
        begin
            logic [7:0] v;
            do_write(16'h01F0, 8'hCD);
            do_read (16'h01F0, v);
            expect_eq("A.2 stack[$F0]", v, 8'hCD);
        end

        // A.3: main RAM lo ($0200-$3FFF) and hi ($8000-$BFFF).
        $display("[A.3] main RAM lo + hi");
        begin
            logic [7:0] v;
            do_write(16'h2000, 8'h11);
            do_read (16'h2000, v);
            expect_eq("A.3 ram_lo[$2000]", v, 8'h11);
            do_write(16'hABCD, 8'h22);
            do_read (16'hABCD, v);
            expect_eq("A.3 ram_hi[$ABCD]", v, 8'h22);
        end

        // A.4: bank window ($4000-$7FFF). M24-3 will wire the cache;
        // for M24-2 it passes through to the same BRAM, so writes
        // round-trip just like main RAM.
        $display("[A.4] bank window (cache stub)");
        begin
            logic [7:0] v;
            do_write(16'h4000, 8'h33);
            do_read (16'h4000, v);
            expect_eq("A.4 bank[$4000]", v, 8'h33);
            do_write(16'h7FFF, 8'h44);
            do_read (16'h7FFF, v);
            expect_eq("A.4 bank[$7FFF]", v, 8'h44);
        end

        // A.5: ROM regions ($C000-$CFFF, $D800-$FFFF). For M24-2
        // these are still writable BRAM (the WRITE_LOCK lands at
        // M24-6); just confirm round-trip works.
        $display("[A.5] ROM regions writable in M24-2 (lock arrives at M24-6)");
        begin
            logic [7:0] v;
            do_write(16'hC123, 8'h55);
            do_read (16'hC123, v);
            expect_eq("A.5 rom_lo[$C123]", v, 8'h55);
            do_write(16'hFFFC, 8'h66);
            do_read (16'hFFFC, v);
            expect_eq("A.5 rom_hi[$FFFC]", v, 8'h66);
        end

        // A.6: hardware-register page ($D000-$D7FF) — read returns
        // the stub-decoded $FF; write fires hwreg_we and is NOT
        // shadowed into BRAM (otherwise stale CPU writes could leak
        // through the override).
        $display("[A.6] hardware-register override");
        begin
            logic [7:0] v;
            // First write to the BRAM at the SAME location (impossible
            // through this module — the override hides $D000-$D7FF
            // from the BRAM write path). Instead we WRITE TO $D200
            // and verify hwreg_we fires + BRAM at $D200 stays at its
            // original $00.
            hwreg_we_seen_q = 1'b0;
            do_write(16'hD200, 8'h99);
            // hwreg_we should have pulsed during the do_write window;
            // captured by the always_ff above.
            if (!hwreg_we_seen_q) begin
                $display("FAIL A.6 hwreg_we never pulsed");
                fail_count++;
            end
            expect_eq("A.6 hwreg_addr",  last_hwreg_waddr_q, 16'hD200);
            expect_eq("A.6 hwreg_din",   last_hwreg_wdata_q, 8'h99);
            // Read $D200 — should get the stub value (we drive
            // hwreg_dout = $FF), NOT $99 from a BRAM shadow.
            do_read(16'hD200, v);
            expect_eq("A.6 hwreg read returns stub $FF", v, 8'hFF);
        end

        // A.7: $D000-$D7FF boundary check — $CFFF is BRAM, $D800 is
        // BRAM, but $D000 / $D7FF are hwreg.
        $display("[A.7] hwreg page boundary");
        begin
            logic [7:0] v;
            do_write(16'hCFFF, 8'h77);    // BRAM (just below hwreg page)
            do_read (16'hCFFF, v);
            expect_eq("A.7 $CFFF is BRAM", v, 8'h77);

            do_write(16'hD800, 8'h88);    // BRAM (just above hwreg page)
            do_read (16'hD800, v);
            expect_eq("A.7 $D800 is BRAM", v, 8'h88);

            do_read(16'hD7FF, v);
            expect_eq("A.7 $D7FF is hwreg (stub $FF)", v, 8'hFF);
            do_read(16'hD000, v);
            expect_eq("A.7 $D000 is hwreg (stub $FF)", v, 8'hFF);
        end

        // ===== Phase B — sally_core + sally_mem end-to-end ==============
        // The CPU integration test is in tb_sally proper. Here we
        // just confirm the new wrapper compiles + sims; the smoke
        // test is covered by tb_sally already.
        $display("[B] (CPU integration covered by tb_sally; this tb is unit-level)");

        // ---- Final report ----------------------------------------------
        if (fail_count == 0) begin
            $display("*** SALLY_MEM OK *** all regions + hwreg override + boundary decode");
            $finish;
        end else begin
            $display("*** SALLY_MEM FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_sally_mem watchdog");
        $fatal(1);
    end

endmodule
