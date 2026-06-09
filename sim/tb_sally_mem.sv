// tb_sally_mem.sv — M24-2 SALLY memory subsystem.
//
// Two halves:
//   Phase A — direct address-region drives (no CPU): pulse addr/rw/data_in
//             into sally_mem and verify region behaviour against expected
//             dout. Covers BRAM regions, hardware-register override, and
//             the read-after-write timing pipeline.
//   Phase B — CPU + sally_mem integration: run a small program
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
    wire       mem_busy;
    logic [7:0] portb = 8'h02;     // default (XL): OS off (bit0=0) + BASIC off (bit1=1) -> both windows RAM
    logic       tb_rdy = 1'b1;     // CPU RDY: 1 for the existing tests; A.5 toggles it to
                                   // exercise the banked-read busy-persist (rdy drops mid-fill).

    sally_mem #(
        .DDR3_BANKED_BASE (32'h0000_0000),  // code base
        .DDR3_DATA_BASE   (32'h0008_0000)   // data base = +512 KB (within the 1 MiB slave)
    ) u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (addr),
        .data_in    (data_in),
        .rw         (rw),
        .data_out   (data_out),
        .rdy        (tb_rdy),             // default 1 (existing tests); A.5 drops it mid-fill
        .busy       (mem_busy),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (cpu_code_bank_q),
        .cpu_data_bank_q    (cpu_data_bank_q),
        .unlock_bank        (1'b1),
        .portb              (portb),
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

        // A.4: code window ($6000-$9FFF). Bank 0 = flat BRAM (writable,
        // ANTIC-coherent); a non-zero $D5C0 selects a DDR3-backed page.
        // Boot runs entirely on bank 0 — this is the gap-1 contract.
        $display("[A.4] code window: bank 0 = BRAM, bank!=0 = DDR3");
        begin
            logic [7:0] v;
            // Bank 0 -> BRAM: full write/read round-trip. The OS needs
            // $6000-$9FFF as RAM (RAM-sizing, GR.0 screen ~$9C00).
            do_write(16'h6000, 8'h33);
            do_read (16'h6000, v);
            expect_eq("A.4 code bank0 BRAM[$6000]", v, 8'h33);
            do_write(16'h9FFF, 8'h44);
            do_read (16'h9FFF, v);
            expect_eq("A.4 code bank0 BRAM[$9FFF]", v, 8'h44);

            // Select code bank 1 ($D5C0=1) -> DDR3 page cache.
            //   axi = DDR3_BANKED_BASE + (bank<<14) + offset
            //       = 0 + (1<<14) + 0 = 0x0000_4000 for $6000.
            do_write(16'hD5C0, 8'h01);
            // read-back: $D5C0/$D5C1 are readable, returned locally by sally_mem
            // (off the ANTIC CDC) — relocated from write-only zero-page $82/$83.
            do_read (16'hD5C0, v);
            expect_eq("A.4 ctl-reg read-back $D5C0", v, 8'h01);
            u_axi_mem.seed_byte(32'h0000_4000, 8'hAA);
            do_read (16'h6000, v);
            expect_eq("A.4 code bank1 DDR3[$6000]", v, 8'hAA);

            // Back to bank 0: the BRAM contents are intact (the DDR3
            // page read did not clobber them).
            do_write(16'hD5C0, 8'h00);
            do_read (16'h6000, v);
            expect_eq("A.4 code bank0 intact[$6000]", v, 8'h33);
        end

        // A.5: banked-read PERSIST — the DDR3 hazard the OS boot never hit (it
        // runs from BRAM).  The real CPU advances off the read address one cycle
        // after presenting it (busy_n is registered in sally_clock), so RDY drops
        // mid-fill.  busy MUST stay asserted across that drop, or the CPU consumes
        // a half-filled line.  Pre-fix, busy = (rdy && is_in_window) && !ready
        // collapsed to 0 the instant RDY dropped; the bank_inflight_q persist
        // (sally_mem) holds it.
        $display("[A.5] banked-read persist: busy holds when RDY drops mid-fill");
        begin
            do_write(16'hD5C0, 8'h02);                  // code bank 2 (fresh) -> DDR3 cache MISS
            u_axi_mem.seed_byte(32'h0000_8000, 8'h5A);  // axi = (2<<14)+0 for $6000 bank 2
            @(negedge clk); addr = 16'h6000; rw = 1'b1; tb_rdy = 1'b1;
            @(posedge clk);                             // present cycle: cache MISS -> fill kicks off
            if (!mem_busy) begin
                $display("FAIL A.5: no fill (unexpected cache hit) — persist not exercised");
                fail_count++;
            end
            @(negedge clk); tb_rdy = 1'b0; addr = 16'hC000;  // CPU advances: RDY drops, addr moves
            @(posedge clk);
            if (!mem_busy) begin
                $display("FAIL A.5: busy released the cycle RDY dropped — no persist (CPU would read a half-filled line)");
                fail_count++;
            end
            while (mem_busy) @(posedge clk);            // stall holds until the fill completes
            @(negedge clk); tb_rdy = 1'b1; addr = 16'h6000; rw = 1'b1;  // re-present, consume
            @(posedge clk); while (mem_busy) @(posedge clk); #1;
            expect_eq("A.5 banked read returns DDR3 byte after persist", data_out, 8'h5A);
            do_write(16'hD5C0, 8'h00);                  // restore bank 0
        end

        // A.4b: data window ($A000-$CFFF). Same contract: bank 0 = BRAM,
        // non-zero $D5C1 = DDR3. portb default ($41) leaves both ROMs
        // disabled so the window is RAM, not ROM.
        $display("[A.4b] data window: bank 0 = BRAM, bank!=0 = DDR3");
        begin
            logic [7:0] v;
            do_write(16'hA000, 8'h55);
            do_read (16'hA000, v);
            expect_eq("A.4b data bank0 BRAM[$A000]", v, 8'h55);
            do_write(16'hCFFF, 8'h66);
            do_read (16'hCFFF, v);
            expect_eq("A.4b data bank0 BRAM[$CFFF]", v, 8'h66);

            // Select data bank 1 ($D5C1=1) -> DDR3.
            //   axi = DDR3_DATA_BASE + (bank<<14) + offset
            //       = 0x0008_0000 + (1<<14) = 0x0008_4000 for $A000.
            do_write(16'hD5C1, 8'h01);
            u_axi_mem.seed_byte(32'h0008_4000, 8'hBB);
            do_read (16'hA000, v);
            expect_eq("A.4b data bank1 DDR3[$A000]", v, 8'hBB);

            do_write(16'hD5C1, 8'h00);
            do_read (16'hA000, v);
            expect_eq("A.4b data bank0 intact[$A000]", v, 8'h55);
        end

        // A.5: OS-high BRAM ($D800-$FFFF) — direct BRAM, outside any
        // banked window.  Round-trip works regardless of PORTB.
        $display("[A.5] OS-high BRAM ($D800-$FFFF)");
        begin
            logic [7:0] v;
            do_write(16'hD800, 8'h77);
            do_read (16'hD800, v);
            expect_eq("A.5 bram[$D800]", v, 8'h77);
            do_write(16'hFFFC, 8'h88);
            do_read (16'hFFFC, v);
            expect_eq("A.5 bram[$FFFC]", v, 8'h88);
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

        // A.8: PORTB BASIC ROM enabled (bit1=0 -> ROM visible at $A000-$BFFF).
        // Writes should be blocked (cpu_w gated by !rom_override); reads
        // return the BASIC ROM content from BRAM init (sally-boot.hex).
        $display("[A.8] PORTB BASIC ROM enabled (bit1=0)");
        begin
            logic [7:0] v;
            portb = 8'h00;          // bit1=0 (BASIC ROM on), bit0=0 (OS RAM) -> BASIC visible
            #1;
            // Write to $A000 should NOT modify BRAM (blocked by rom_override).
            do_write(16'hA000, 8'hAA);
            do_read (16'hA000, v);
            // BRAM was pre-loaded from sally-boot.hex.  $A000 is BASIC ROM;
            // the hex file has BASIC at $A000-$BFFF.  We can't predict the
            // exact byte, but it won't be $AA (our blocked write).
            if (v == 8'hAA) begin
                $display("FAIL A.8 BASIC ROM write went through (got $AA, expected ROM content)");
                fail_count++;
            end else begin
                $display("A.8 BASIC ROM block OK (read $%h from $A000, not $AA)", v);
            end
        end

        // A.9: PORTB BASIC ROM disabled (portb[0]=1 -> RAM at $A000-$BFFF).
        // With data bank 0 (default) the RAM-under-ROM is the flat BRAM,
        // so this is a plain BRAM write/read round-trip.
        $display("[A.9] PORTB BASIC disabled (portb[0]=1) -> RAM at $A000");
        begin
            logic [7:0] v;
            portb = 8'h02;          // OS off (bit0=0) + BASIC off (bit1=1) -> RAM
            #1;
            do_write(16'hA000, 8'hBB);
            do_read (16'hA000, v);
            expect_eq("A.9 $A000 RAM (bank0 BRAM)", v, 8'hBB);
        end

        // A.10: PORTB OS ROM enabled (bit0=1 -> ROM visible at
        // $C000-$CFFF + $D800-$FFFF).  Writes blocked, reads return
        // OS ROM content from BRAM init.
        $display("[A.10] PORTB OS ROM enabled (bit0=1)");
        begin
            logic [7:0] v;
            portb = 8'h03;          // bit0=1 (OS ROM on), bit1=1 (BASIC RAM) -> OS visible
            #1;
            do_write(16'hC000, 8'hCC);
            do_read (16'hC000, v);
            if (v == 8'hCC) begin
                $display("FAIL A.10 OS ROM write went through (got $CC, expected ROM content)");
                fail_count++;
            end else begin
                $display("A.10 OS ROM block OK (read $%h from $C000, not $CC)", v);
            end
        end

        // A.11: PORTB OS ROM disabled (portb[1]=1 -> backing RAM visible).
        // $C000-$CFFF is data-window RAM; with bank 0 (default) that is
        // the flat BRAM. $D800-$FFFF is direct BRAM.
        $display("[A.11] PORTB OS disabled (portb[1]=1) -> RAM at $C000");
        begin
            logic [7:0] v;
            portb = 8'h02;          // OS off (bit0=0) + BASIC off (bit1=1) -> RAM
            #1;
            do_write(16'hC000, 8'hDD);
            do_read (16'hC000, v);
            expect_eq("A.11 $C000 RAM (bank0 BRAM)", v, 8'hDD);
            // $FFFC - BRAM (outside banked window).  Round-trip.
            do_write(16'hFFFC, 8'hEE);
            do_read (16'hFFFC, v);
            expect_eq("A.11 BRAM[$FFFC]", v, 8'hEE);
        end

        // Reset portb to default for any subsequent tests.
        portb = 8'h02;
        #1;

        // ===== Phase B — CPU + sally_mem end-to-end ====================
        // The full CPU integration test is in tb_sally_arbitration
        // (xt6502 + sally_mem + sally_clock). Here we just confirm the
        // wrapper compiles + sims; this tb is unit-level.
        $display("[B] (CPU integration covered by tb_sally_arbitration; this tb is unit-level)");

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
