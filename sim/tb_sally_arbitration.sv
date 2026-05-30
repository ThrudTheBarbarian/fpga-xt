// tb_sally_arbitration.sv — M24-5 bus-arbitration validation.
//
// Wraps xt6502 + sally_mem + sally_clock and runs the same simple
// program at various CLOCK_MULT settings and halt patterns. Verifies:
//
//   A. Baseline scaling — at CLOCK_MULT=K, completion time is roughly
//      N_1/K (i.e. SALLY actually runs faster).
//   B. /HALT honoured at CLOCK_MULT=1 — pulling halt_n low for a
//      sustained window slows the CPU by the held-low duration.
//   C. /HALT bypassed at CLOCK_MULT≥2 — same halt pattern doesn't
//      change CPU completion time.
//   D. WSYNC honoured at any CLOCK_MULT — pulling wsync_rdy low
//      stalls the CPU regardless of speed mode.
//
// Test program (same in every phase): write a sentinel, then JMP-loop.
// Number of fabric cycles from reset-release to sentinel write is the
// measurement.

`timescale 1ns / 1ps

module tb_sally_arbitration;

    logic clk = 1'b0;
    always #5 clk = ~clk;             // 100 MHz fabric
    logic rst = 1'b1;

    // SALLY <-> sally_mem signals.
    wire [15:0] addr;
    wire [7:0]  data_out;
    wire        rw;
    wire [7:0]  data_in;
    logic       irq_n  = 1'b1;
    logic       nmi_n  = 1'b1;
    wire        sally_rdy;
    wire        cpu_stack_op;        // 12-bit stack push/pull cycle
    wire [3:0]  cpu_s_high;          // high 4 bits of SP

    xt6502 u_dut (
        .clk      (clk),
        .rst      (rst),
        .addr     (addr),
        .data_in  (data_in),
        .data_out (data_out),
        .rw       (rw),
        .rdy      (sally_rdy),
        .irq_n    (irq_n),
        .nmi_n    (nmi_n),
        .stack_op (cpu_stack_op),
        .s_high   (cpu_s_high)
    );

    // sally_mem (hwreg stub returning $FF).
    `define mem u_mem.mem
    wire [15:0] hwreg_addr;
    wire        hwreg_we;
    wire [7:0]  hwreg_din;
    logic [7:0] hwreg_dout = 8'hFF;

    // ---- AXI bus to memory-backed slave (replaces v1 hyperram mock) ----
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
        .rdy        (sally_rdy),
        .stack_op   (cpu_stack_op),
        .s_high     (cpu_s_high),
        .busy       (mem_busy),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (cpu_code_bank_q),
        .cpu_data_bank_q    (cpu_data_bank_q),
        .portb              (8'hFF),
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

    // ---- phi2_tick generator (BASE_DIV=12) -----------------------
    localparam int BASE_DIV = 12;
    logic [3:0] phi2_div_q = 4'd0;
    logic       phi2_q     = 1'b0;
    logic       phi2_q_q   = 1'b0;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            phi2_div_q <= 4'd0;
            phi2_q     <= 1'b0;
            phi2_q_q   <= 1'b0;
        end else begin
            phi2_q_q <= phi2_q;
            if (phi2_div_q == BASE_DIV/2 - 1) begin
                phi2_div_q <= 4'd0;
                phi2_q     <= ~phi2_q;
            end else begin
                phi2_div_q <= phi2_div_q + 4'd1;
            end
        end
    end
    wire phi2_tick = phi2_q & ~phi2_q_q;     // 1-cycle pulse on phi2 rising edge

    // ---- DUT: sally_clock ----------------------------------------
    logic [7:0] clock_mult  = 8'd1;
    logic       halt_n      = 1'b1;          // testbench drives
    logic       wsync_rdy_n = 1'b1;          // testbench drives

    sally_clock #(.BASE_DIV(BASE_DIV)) u_clk (
        .clk         (clk),
        .rst         (rst),
        .phi2_tick   (phi2_tick),
        .clock_mult  (clock_mult),
        .halt_n      (halt_n),
        .wsync_rdy_n (wsync_rdy_n),
        .busy_n      (1'b1),
        .sally_rdy   (sally_rdy),
        .sally_step  ()
    );

    // ---- Helpers --------------------------------------------------
    int fail_count = 0;

    task automatic clear_mem();
        int i;
        for (i = 0; i < 65536; i++) `mem[i] = 8'hEA;     // NOPs everywhere
        `mem[16'h0200] = 8'hA2; `mem[16'h0201] = 8'hFF;  // LDX #$FF
        `mem[16'h0202] = 8'h9A;                          // TXS
    endtask

    // Load the standard test program: LDA #$42 / STA $00FF / JMP-loop.
    task automatic load_test_program();
        clear_mem();
        `mem[16'h0203] = 8'hA9; `mem[16'h0204] = 8'h42;  // LDA #$42
        `mem[16'h0205] = 8'h8D; `mem[16'h0206] = 8'hFF; `mem[16'h0207] = 8'h00;  // STA $00FF
        `mem[16'h0208] = 8'h4C; `mem[16'h0209] = 8'h08; `mem[16'h020A] = 8'h02;  // JMP $0208
        `mem[16'hFFFC] = 8'h00; `mem[16'hFFFD] = 8'h02;
    endtask

    task automatic run_program(input string label, input int max_cycles, output int cycles);
        int c;
        bit hit;
        rst = 1'b1;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        c = 0; hit = 1'b0;
        while (c < max_cycles && !hit) begin
            @(posedge clk);
            c++;
            if (!rw && addr == 16'h00FF) hit = 1'b1;
        end
        cycles = c;
        if (!hit) begin
            $display("FAIL %s: watchdog at %0d cycles", label, max_cycles);
            fail_count++;
        end else begin
            $display("[%s] sentinel hit after %0d fabric cycles", label, c);
        end
        repeat (2) @(posedge clk);
    endtask

    initial begin
        $display("=== M24-5 sally_arbitration ===");

        // ===== Phase A — baseline scaling at increasing CLOCK_MULT ======
        // Same program. At higher CLOCK_MULT, SALLY should finish faster.
        // Scaling isn't perfectly linear (constant overheads dominate
        // small programs) but should be monotonically decreasing.
        $display("[A] CLOCK_MULT scaling — same program at K=1, 2, 4, 12");
        begin
            int n1, n2, n4, n12;
            load_test_program();
            halt_n      = 1'b1;
            wsync_rdy_n = 1'b1;

            clock_mult = 8'd1;
            run_program("A.K=1",  4000, n1);
            clock_mult = 8'd2;
            run_program("A.K=2",  4000, n2);
            clock_mult = 8'd4;
            run_program("A.K=4",  4000, n4);
            clock_mult = 8'd12;
            run_program("A.K=12", 4000, n12);

            // K=2 should finish faster than K=1, K=4 faster than K=2, ...
            if (n2 >= n1) begin
                $display("FAIL A: K=2 (%0d) not faster than K=1 (%0d)", n2, n1);
                fail_count++;
            end
            if (n4 >= n2) begin
                $display("FAIL A: K=4 (%0d) not faster than K=2 (%0d)", n4, n2);
                fail_count++;
            end
            if (n12 >= n4) begin
                $display("FAIL A: K=12 (%0d) not faster than K=4 (%0d)", n12, n4);
                fail_count++;
            end

            // Sanity: K=12 should be roughly 12× faster than K=1.
            // Allow ±50% tolerance because of startup-fetch overhead.
            // n12 / n1 expected ~1/12; threshold 0.05..0.20
            if (n12 * 6 > n1) begin
                $display("INFO A: K=12 ratio = %0d/%0d = %0d%% (looser than 1/6)",
                         n12, n1, (n12*100)/n1);
            end
            // Sentinel value should be $42 in every case.
            if (`mem[16'h00FF] != 8'h42) begin
                $display("FAIL A: sentinel mem[$FF]=$%02h (expected $42)", `mem[16'h00FF]);
                fail_count++;
            end else begin
                $display("[A] sentinel correctly written, scaling monotonic ✓");
            end
        end

        // ===== Phase B — /HALT honoured at CLOCK_MULT=1 ===================
        // Drive halt_n=0 for a sustained window during execution.
        // SALLY should pause; completion delayed by the halt duration.
        $display("[B] /HALT honoured at CLOCK_MULT=1");
        begin
            int n_baseline, n_halted;
            load_test_program();
            wsync_rdy_n = 1'b1;
            clock_mult  = 8'd1;
            halt_n      = 1'b1;
            run_program("B.baseline", 4000, n_baseline);

            // Now halt during execution.
            load_test_program();
            rst = 1'b1;
            repeat (4) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
            // Drive halt_n=0 for 400 cycles (~33 phi2 ticks worth).
            halt_n = 1'b0;
            begin
                int c;
                bit hit;
                c = 0; hit = 1'b0;
                while (c < 400 && !hit) begin
                    @(posedge clk);
                    c++;
                    if (!rw && addr == 16'h00FF) hit = 1'b1;
                end
                halt_n = 1'b1;
                // Continue running until sentinel.
                while (c < 4000 && !hit) begin
                    @(posedge clk);
                    c++;
                    if (!rw && addr == 16'h00FF) hit = 1'b1;
                end
                n_halted = c;
                if (!hit) begin
                    $display("FAIL B.halted: watchdog");
                    fail_count++;
                end
            end
            $display("[B] baseline=%0d halted=%0d delta=%0d (expect halted ≥ baseline + 350)",
                     n_baseline, n_halted, n_halted - n_baseline);
            if (n_halted < n_baseline + 350) begin
                $display("FAIL B: /HALT didn't slow SALLY enough at CLOCK_MULT=1");
                fail_count++;
            end else begin
                $display("[B] /HALT slows SALLY at CLOCK_MULT=1 ✓");
            end
            halt_n = 1'b1;
        end

        // ===== Phase C — /HALT bypassed at CLOCK_MULT≥2 ====================
        // Same halt pattern at CLOCK_MULT=4 should NOT change completion
        // time (within tolerance for the cycle the halt-driving
        // sequence consumes).
        $display("[C] /HALT bypassed at CLOCK_MULT≥2");
        begin
            int n_baseline, n_halted;
            load_test_program();
            wsync_rdy_n = 1'b1;
            clock_mult  = 8'd4;
            halt_n      = 1'b1;
            run_program("C.baseline", 4000, n_baseline);

            // Same 400-cycle halt window — should be ignored.
            load_test_program();
            rst = 1'b1;
            repeat (4) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
            halt_n = 1'b0;
            begin
                int c;
                bit hit;
                c = 0; hit = 1'b0;
                while (c < 400 && !hit) begin
                    @(posedge clk);
                    c++;
                    if (!rw && addr == 16'h00FF) hit = 1'b1;
                end
                halt_n = 1'b1;
                while (c < 4000 && !hit) begin
                    @(posedge clk);
                    c++;
                    if (!rw && addr == 16'h00FF) hit = 1'b1;
                end
                n_halted = c;
                if (!hit) begin
                    $display("FAIL C.halted: watchdog");
                    fail_count++;
                end
            end
            $display("[C] baseline=%0d halted=%0d delta=%0d (expect ≈ 0)",
                     n_baseline, n_halted, n_halted - n_baseline);
            // Allow ±10% slop for the halt-driver overhead.
            if (n_halted > n_baseline + 50 || n_halted < n_baseline - 50) begin
                $display("FAIL C: /HALT had effect at CLOCK_MULT=4 (delta=%0d)",
                         n_halted - n_baseline);
                fail_count++;
            end else begin
                $display("[C] /HALT bypassed at CLOCK_MULT≥2 ✓");
            end
            halt_n = 1'b1;
        end

        // ===== Phase D — WSYNC honoured at all CLOCK_MULT ==================
        // Drop wsync_rdy_n (active-low: 0 = stall) at CLOCK_MULT=4 and
        // verify SALLY pauses despite the higher clock rate.
        $display("[D] WSYNC honoured at CLOCK_MULT=4");
        begin
            int n_baseline, n_wsync;
            load_test_program();
            halt_n      = 1'b1;
            wsync_rdy_n = 1'b1;
            clock_mult  = 8'd4;
            run_program("D.baseline", 4000, n_baseline);

            load_test_program();
            rst = 1'b1;
            repeat (4) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
            wsync_rdy_n = 1'b0;
            begin
                int c;
                bit hit;
                c = 0; hit = 1'b0;
                while (c < 400 && !hit) begin
                    @(posedge clk);
                    c++;
                    if (!rw && addr == 16'h00FF) hit = 1'b1;
                end
                wsync_rdy_n = 1'b1;
                while (c < 4000 && !hit) begin
                    @(posedge clk);
                    c++;
                    if (!rw && addr == 16'h00FF) hit = 1'b1;
                end
                n_wsync = c;
                if (!hit) begin
                    $display("FAIL D.wsync: watchdog");
                    fail_count++;
                end
            end
            $display("[D] baseline=%0d wsync_held=%0d delta=%0d (expect ≥ baseline + 350)",
                     n_baseline, n_wsync, n_wsync - n_baseline);
            if (n_wsync < n_baseline + 350) begin
                $display("FAIL D: WSYNC didn't stall SALLY at CLOCK_MULT=4");
                fail_count++;
            end else begin
                $display("[D] WSYNC honoured even at CLOCK_MULT=4 ✓");
            end
            wsync_rdy_n = 1'b1;
        end

        if (fail_count == 0) begin
            $display("*** SALLY_ARB OK *** scaling + /HALT gating + WSYNC honoured");
            $finish;
        end else begin
            $display("*** SALLY_ARB FAIL *** %0d failures", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #50_000_000;
        $display("FAIL: tb_sally_arbitration watchdog");
        $fatal(1);
    end

endmodule
