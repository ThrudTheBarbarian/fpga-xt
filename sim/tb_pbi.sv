// tb_pbi.sv — M-PBI behavioural integration test.
//
// Exercises the external 6502 bus + cart slot + PBI + ECI signal set
// that M-PBI steps 1-3 + deferred items #1 + #2 + #3 added to
// antic_top. Drives the inputs from the testbench, observes the
// outputs + selected internal state via hierarchical reference.
//
// Phases:
//   A. Reset state — output flops at safe defaults
//   B. Address decode — /D0xx, /D1xx, /D4xx, /S4, /S5, /CCTL pages
//   C. Output flop tracking — bus_addr_o follows bus_addr (1-cycle)
//   D. PBI status in $D481 — RD4/RD5/MPD/EXTIRQ visible after sync
//   E. /EXTIRQ → irq_n propagation
//   F. phi2-fall capture — bus_data_in_q -> bus_pbi_rdata_q on phi2_fall
//   G. ext_bus_active gating at fast mode — cpu_internal=1 + clk_mult=12
//      freezes output flops (D=Q hold; pad stays static)
//   H. /EXTIRQ fall-back-to-phi2 mode ($D481[3]=1)

`default_nettype none
`timescale 1ns / 1ps

module tb_pbi;

    // Clock — keep it simple; phi2 = clk_bus/90 internally.  clk_pix/clk_bit
    // dropped — task-0013 step 3 removed antic_top's 800×600 display chain.
    logic clk_bus = 1'b0;
    always #3.5    clk_bus = ~clk_bus;   // ~143 MHz half-period 3.5 ns

    // Bus stimulus inputs.
    logic        rst_n       = 1'b0;
    logic [15:0] bus_addr    = 16'h0000;
    logic [7:0]  bus_data_in = 8'h00;
    logic        bus_rw      = 1'b1;
    logic        d0xx_n      = 1'b1;
    logic        d4xx_n      = 1'b1;

    // M-PBI inputs (all idle/inactive by default).
    logic        bus_mpd_n_in    = 1'b1;
    logic        bus_extirq_n_in = 1'b1;
    logic        bus_rd4_in      = 1'b1;
    logic        bus_rd5_in      = 1'b1;

    // M-PBI outputs.
    wire [7:0]  bus_data_out;
    wire        bus_data_oe;
    wire [15:0] bus_addr_o;
    wire        bus_rw_o;
    wire        bus_d0xx_n_o, bus_d4xx_n_o, bus_d1xx_n_o;
    wire        bus_s4_n_o, bus_s5_n_o, bus_cctl_n_o, bus_extenb_n_o;
    wire [2:0]  bus_pbi_in_status_o;
    wire        nmi_n, halt_n, rdy_n, irq_n;

    antic_top u_dut (
        .clk_bus                  (clk_bus),
        .rst_n                    (rst_n),
        .joy_ovr                  (32'd0),   // keypad->joystick override off (default)
        .bus_addr                 (bus_addr),
        .bus_data_in              (bus_data_in),
        .bus_rw                   (bus_rw),
        .d0xx_n                   (d0xx_n),
        .d4xx_n                   (d4xx_n),
        .bus_data_out             (bus_data_out),
        .bus_data_oe              (bus_data_oe),
        .bus_addr_o               (bus_addr_o),
        .bus_rw_o                 (bus_rw_o),
        .bus_d0xx_n_o             (bus_d0xx_n_o),
        .bus_d4xx_n_o             (bus_d4xx_n_o),
        .bus_d1xx_n_o             (bus_d1xx_n_o),
        .bus_s4_n_o               (bus_s4_n_o),
        .bus_s5_n_o               (bus_s5_n_o),
        .bus_cctl_n_o             (bus_cctl_n_o),
        .bus_extenb_n_o           (bus_extenb_n_o),
        .bus_mpd_n_in             (bus_mpd_n_in),
        .bus_extirq_n_in          (bus_extirq_n_in),
        .bus_rd4_in               (bus_rd4_in),
        .bus_rd5_in               (bus_rd5_in),
        .unlock_antic             (1'b1),
        .unlock_sprite(1'b1),
        .unlock_blit(1'b1),
        .bus_pbi_in_status_o      (bus_pbi_in_status_o),
        .nmi_n                    (nmi_n),
        .halt_n                   (halt_n),
        .rdy_n                    (rdy_n),
        .irq_n                    (irq_n),
        .spi_miso                 (1'b1),
        .spi_irq                  (1'b1),
        .joy_spi_miso             (1'b1),
        .joy_spi_int_n            (1'b1)
    );

    // ---- Test harness ---------------------------------------------------
    int errors = 0;
    task automatic expect_eq(input string label,
                             input logic [31:0] got,
                             input logic [31:0] expect_);
        if (got !== expect_) begin
            $display("FAIL %s: got=%h expected=%h", label, got, expect_);
            errors++;
        end
    endtask

    // Bus-write task for $D4xx page (writes to antic / chiplet-ext regs).
    task automatic write_d4xx(input logic [7:0] addr_lo, input logic [7:0] data);
        @(negedge clk_bus);
        bus_addr    = {8'hD4, addr_lo};
        bus_data_in = data;
        bus_rw      = 1'b0;
        d4xx_n      = 1'b0;
        @(posedge clk_bus);
        @(negedge clk_bus);
        bus_addr    = 16'h0000;
        bus_data_in = 8'h00;
        bus_rw      = 1'b1;
        d4xx_n      = 1'b1;
    endtask

    // Bus-read task for $D4xx.
    task automatic read_d4xx(input logic [7:0] addr_lo, output logic [7:0] data);
        @(negedge clk_bus);
        bus_addr = {8'hD4, addr_lo};
        bus_rw   = 1'b1;
        d4xx_n   = 1'b0;
        @(posedge clk_bus);
        @(posedge clk_bus);                // wait one extra for read flop
        data = bus_data_out;
        @(negedge clk_bus);
        bus_addr = 16'h0000;
        bus_rw   = 1'b1;
        d4xx_n   = 1'b1;
    endtask

    initial begin
        $display("=== M-PBI behavioural integration ===");

        // Reset
        repeat (10) @(posedge clk_bus);
        rst_n = 1'b1;
        repeat (10) @(posedge clk_bus);

        // ===== Phase A — post-reset sanity ===============================
        // The output flops update from bus_addr/bus_rw as soon as reset
        // releases (cpu_internal=0 → ext_bus_active=1 always), so the
        // "reset values" aren't observable here. Skip explicit checks
        // and rely on phase B/C below for output-flop behaviour.
        $display("[A] post-reset sanity (no explicit checks)");

        // ===== Phase B — address decode ==================================
        $display("[B] address decode");
        // $D188 in /D1xx page → bus_d1xx_n_o asserts
        bus_addr = 16'hD188;  bus_rw = 1'b1;
        repeat (3) @(posedge clk_bus);
        expect_eq("addr=$D188 → d1xx_n",  bus_d1xx_n_o, 1'b0);
        expect_eq("addr=$D188 → d0xx_n",  bus_d0xx_n_o, 1'b1);
        expect_eq("addr=$D188 → d4xx_n",  bus_d4xx_n_o, 1'b1);
        expect_eq("addr=$D188 → s4_n",    bus_s4_n_o,   1'b1);
        expect_eq("addr=$D188 → s5_n",    bus_s5_n_o,   1'b1);
        expect_eq("addr=$D188 → cctl_n",  bus_cctl_n_o, 1'b1);

        // $8555 in cart-S4 range → bus_s4_n_o asserts
        bus_addr = 16'h8555;
        repeat (3) @(posedge clk_bus);
        expect_eq("addr=$8555 → s4_n", bus_s4_n_o, 1'b0);
        expect_eq("addr=$8555 → s5_n", bus_s5_n_o, 1'b1);

        // $AAAA in cart-S5 range → bus_s5_n_o asserts
        bus_addr = 16'hAAAA;
        repeat (3) @(posedge clk_bus);
        expect_eq("addr=$AAAA → s4_n", bus_s4_n_o, 1'b1);
        expect_eq("addr=$AAAA → s5_n", bus_s5_n_o, 1'b0);

        // $D533 in /CCTL range → bus_cctl_n_o asserts
        bus_addr = 16'hD533;
        repeat (3) @(posedge clk_bus);
        expect_eq("addr=$D533 → cctl_n", bus_cctl_n_o, 1'b0);

        // ===== Phase C — output flop tracking ============================
        $display("[C] output tracking");
        bus_addr = 16'h1234;
        repeat (3) @(posedge clk_bus);
        expect_eq("bus_addr_o follows", bus_addr_o, 16'h1234);
        bus_addr = 16'hABCD;
        repeat (3) @(posedge clk_bus);
        expect_eq("bus_addr_o follows again", bus_addr_o, 16'hABCD);

        // ===== Phase D — PBI status in $D481 =============================
        $display("[D] PBI status visible in $D481");
        // Assert RD4 (cart in $8000-$9FFF), leave others idle
        bus_rd4_in = 1'b0;
        repeat (5) @(posedge clk_bus);    // 2-FF sync latency
        begin
            logic [7:0] d481;
            read_d4xx(8'h81, d481);
            // [7]=EXTIRQ=1, [6]=MPD=1, [5]=RD5=1, [4]=RD4=0
            expect_eq("$D481[7:4] only RD4",  d481[7:4], 4'b1110);
        end
        // Now assert all four
        bus_rd5_in      = 1'b0;
        bus_mpd_n_in    = 1'b0;
        bus_extirq_n_in = 1'b0;
        repeat (5) @(posedge clk_bus);
        begin
            logic [7:0] d481;
            read_d4xx(8'h81, d481);
            // All asserted (active-low → 0)
            expect_eq("$D481[7:4] all asserted", d481[7:4], 4'b0000);
        end
        // Restore
        bus_rd4_in      = 1'b1;
        bus_rd5_in      = 1'b1;
        bus_mpd_n_in    = 1'b1;
        bus_extirq_n_in = 1'b1;
        repeat (5) @(posedge clk_bus);

        // ===== Phase E — /EXTIRQ → irq_n =================================
        $display("[E] /EXTIRQ propagation to irq_n");
        // irq_n should be high (no IRQ)
        expect_eq("irq_n idle high", irq_n, 1'b1);
        bus_extirq_n_in = 1'b0;
        repeat (5) @(posedge clk_bus);
        expect_eq("irq_n low after EXTIRQ assert", irq_n, 1'b0);
        bus_extirq_n_in = 1'b1;
        repeat (5) @(posedge clk_bus);
        expect_eq("irq_n high after EXTIRQ deassert", irq_n, 1'b1);

        // ===== Phase F — phi2-fall capture ===============================
        $display("[F] phi2-fall capture of bus_data_in");
        // Drive bus_data_in to a recognisable pattern and wait for one
        // full phi2 cycle (90 clk_bus periods at BASE_DIV=90).
        bus_data_in = 8'hA5;
        repeat (200) @(posedge clk_bus);
        expect_eq("bus_pbi_rdata_q=$A5",
                  u_dut.bus_pbi_rdata_q, 8'hA5);
        bus_data_in = 8'h5A;
        repeat (200) @(posedge clk_bus);
        expect_eq("bus_pbi_rdata_q=$5A",
                  u_dut.bus_pbi_rdata_q, 8'h5A);
        bus_data_in = 8'h00;

        // ===== Phase G — /EXTIRQ fall-back-to-phi2 mode ($D481[3]) =======
        // (run before the cpu_internal=1 flip, since that switches the
        // snoop mux to SALLY's bus and testbench-driven $D481 writes
        // stop reaching antic_regs.)
        $display("[G] /EXTIRQ fall-back-to-phi2 ($D481[3]=1)");
        expect_eq("clock_mult before fall-back",
                  u_dut.u_antic_regs.clock_mult_q, 8'd12);
        // Enable fall-back via $D481[3]=1, keep cpu_internal=0.
        write_d4xx(8'h81, 8'b0000_1001);   // mode_snoop=1, auto_phi2=1
        repeat (3) @(posedge clk_bus);
        // Assert /EXTIRQ falling edge → fall-back active → clk_mult=1
        bus_extirq_n_in = 1'b0;
        repeat (5) @(posedge clk_bus);
        expect_eq("clock_mult=1 during fall-back",
                  u_dut.u_antic_regs.clock_mult_q, 8'd1);
        // Deassert /EXTIRQ → fall-back clears → clk_mult restored to 12
        bus_extirq_n_in = 1'b1;
        repeat (5) @(posedge clk_bus);
        expect_eq("clock_mult restored to 12 after EXTIRQ deassert",
                  u_dut.u_antic_regs.clock_mult_q, 8'd12);
        // Clear auto_phi2 for clean state going into phase H
        write_d4xx(8'h81, 8'b0000_0001);   // mode_snoop=1, auto_phi2=0

        // ===== Phase H — ext_bus_active gating at fast mode ==============
        $display("[H] ext_bus_active gating at cpu_internal=1 + clk_mult=12");
        bus_addr = 16'h1111;
        repeat (3) @(posedge clk_bus);
        expect_eq("bus_addr_o follows pre-flip", bus_addr_o, 16'h1111);
        // Flip cpu_internal=1 via $D481 write. clock_mult is hardcoded 12,
        // so ext_bus_active becomes (12==1)=0 → output flops freeze.
        write_d4xx(8'h81, 8'b0000_0011);   // cpu_internal=1, mode_snoop=1
        repeat (3) @(posedge clk_bus);
        // bus_addr_o should now be holding whatever was last captured
        // before cpu_internal flipped to 1.
        begin
            logic [15:0] frozen;
            frozen = bus_addr_o;
            bus_addr = 16'h2222;
            repeat (20) @(posedge clk_bus);
            expect_eq("bus_addr_o frozen at fast mode", bus_addr_o, frozen);
        end

        // ===== Summary ====================================================
        if (errors == 0) begin
            $display("*** PBI OK ***");
            $finish;
        end else begin
            $display("*** PBI FAIL *** %0d failures", errors);
            $fatal(1);
        end
    end

    // Watchdog
    initial begin
        #100_000_000;
        $display("FAIL: tb_pbi watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
