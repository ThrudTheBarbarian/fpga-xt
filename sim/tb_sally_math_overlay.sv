// tb_sally_math_overlay.sv — integrated math-page overlay READ round-trip.
//
// Reproduces (and then guards against) the HW defect where the 6502 can WRITE
// the math page overlaid on $4000-$5FFF ($D5C6.0 MAP=1) but a read-back returns
// stale/neighbour data instead of what was written.
//
// Neither tb_mathcop nor tb_gp0_mux catch this: they read math_cop.cpu_rdata
// DIRECTLY, every clk_cpu edge, with no stall cycles and no advancing address
// bus.  tb_sally_mem exercises the sally_mem read pipeline but TIES OFF the math
// signals.  This TB is the missing integration: sally_mem + a REAL math_cop,
// wired exactly as fpga_xt_top does, driven through sally_mem's rdy-gated
// read-after-write pipeline WITH stall cycles.
//
// The bug: math_cop's CPU-side page read (cpu_rd_word_q) free-ran on clk_cpu,
// while sally_mem's overlay SELECT (was_math_q) and BRAM shadow (bram_dout_q)
// are rdy-gated.  On the real CPU the MAR advances to the next fetch the cycle
// after presenting a read address, then RDY drops for the stall.  During those
// stall cycles the free-running read chased the advanced address, so cpu_rdata
// held a NEIGHBOURING page word by the time the CPU sampled it.  Writes work
// because the write enable (math_cpu_we = rdy && !rw && math_mapped) is itself
// rdy-gated and never fires during a stall.
//
// Modes:
//   default            — cpu_rden = rdy  (the fix): reads round-trip -> PASS
//   -D MATH_RDEN_FREE  — cpu_rden = 1'b1 (old free-running behaviour): the
//                        stalled read returns the neighbour word -> the repro
//                        assertion fires, documenting the HW failure.

`timescale 1ns / 1ps
`default_nettype none

module tb_sally_math_overlay;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst = 1'b1;

    // ---- sally_mem CPU-side memory port ----
    logic [15:0] addr    = 16'h0000;
    logic [7:0]  data_in = 8'h00;
    logic        rw      = 1'b1;
    logic        tb_rdy  = 1'b1;      // = SALLY rdy (step/stall clock-enable)
    wire  [7:0]  data_out;
    wire         mem_busy;

    // hwreg stub
    wire [15:0] hwreg_addr;
    wire        hwreg_we;
    wire [7:0]  hwreg_din;
    logic [7:0] hwreg_dout = 8'hFF;

    // ---- sally_mem <-> math_cop aperture wiring (mirrors fpga_xt_top) ----
    wire [12:0] scrn_cpu_addr;
    wire        scrn_cpu_we;
    wire [7:0]  scrn_cpu_wdata;
    wire        math_map;
    wire        math_exec_we, math_chunk_we;
    wire        math_cpu_we;
    wire [7:0]  math_cpu_rdata;
    wire [7:0]  scrn_bank_wval;
    wire        scrn_cpu_bank_we, scrn_antic_bank_we;

    // math_cop status back into sally_mem (unused by the read path here)
    wire        math_done, math_busy, math_chunk_ready;

    // cpu_rden select — the knob that distinguishes buggy vs fixed behaviour.
`ifdef MATH_RDEN_FREE
    wire mc_rden = 1'b1;              // reproduce the pre-fix free-running read
`else
    wire mc_rden = tb_rdy;           // the fix: freeze the read reg while stalled
`endif

    // ---- sally_mem banked-window AXI (unused by aperture ops; needs a slave) ----
    wire [31:0] axi_araddr; wire [7:0] axi_arlen; wire [2:0] axi_arsize;
    wire [1:0]  axi_arburst; wire axi_arvalid, axi_arready;
    wire [63:0] axi_rdata;   wire axi_rvalid, axi_rlast, axi_rready;
    wire [31:0] axi_awaddr;  wire [7:0] axi_awlen; wire [2:0] axi_awsize;
    wire [1:0]  axi_awburst; wire axi_awvalid, axi_awready;
    wire [63:0] axi_wdata;   wire [7:0] axi_wstrb; wire axi_wlast, axi_wvalid, axi_wready;
    wire        axi_bvalid,  axi_bready;

    sally_mem #(
        .DDR3_BANKED_BASE (32'h0000_0000),
        .DDR3_DATA_BASE   (32'h0008_0000),
        .BANKED_CACHE     ("LINE")
    ) u_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (addr),
        .data_in    (data_in),
        .rw         (rw),
        .data_out   (data_out),
        .rdy        (tb_rdy),
        .busy       (mem_busy),
        .stack_op   (1'b0),
        .s_high     (4'd0),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (),
        .cpu_data_bank_q    (),
        .scrn_cpu_bank_q    (),
        .scrn_antic_bank_q  (),
        .scrn_cpu_bank_we   (scrn_cpu_bank_we),
        .scrn_antic_bank_we (scrn_antic_bank_we),
        .scrn_bank_wval     (scrn_bank_wval),
        .scrn_ready         (1'b1),
        .scrn_cpu_addr      (scrn_cpu_addr),
        .scrn_cpu_we        (scrn_cpu_we),
        .scrn_cpu_wdata     (scrn_cpu_wdata),
        .scrn_cpu_rdata     (8'h00),
        .math_map_q         (math_map),
        .math_chunk_q       (),
        .math_exec_we       (math_exec_we),
        .math_chunk_we      (math_chunk_we),
        .math_done          (math_done),
        .math_busy          (math_busy),
        .math_chunk_ready   (math_chunk_ready),
        .math_cpu_we        (math_cpu_we),
        .math_cpu_rdata     (math_cpu_rdata),
        .unlock_bank        (1'b1),
        .portb              (8'h02),
        .bus_mpd_n_in       (1'b1),
        .bus_pbi_rdata      (8'hFF),
        .bus_rd4_n_in       (1'b1),
        .bus_rd5_n_in       (1'b1),
        .m_axi_araddr  (axi_araddr),  .m_axi_arlen  (axi_arlen),  .m_axi_arsize (axi_arsize),
        .m_axi_arburst (axi_arburst), .m_axi_arvalid(axi_arvalid),.m_axi_arready(axi_arready),
        .m_axi_rdata   (axi_rdata),   .m_axi_rvalid (axi_rvalid), .m_axi_rlast  (axi_rlast),
        .m_axi_rready  (axi_rready),
        .m_axi_awaddr  (axi_awaddr),  .m_axi_awlen  (axi_awlen),  .m_axi_awsize (axi_awsize),
        .m_axi_awburst (axi_awburst), .m_axi_awvalid(axi_awvalid),.m_axi_awready(axi_awready),
        .m_axi_wdata   (axi_wdata),   .m_axi_wstrb  (axi_wstrb),  .m_axi_wlast  (axi_wlast),
        .m_axi_wvalid  (axi_wvalid),  .m_axi_wready (axi_wready),
        .m_axi_bvalid  (axi_bvalid),  .m_axi_bready (axi_bready),
        .rom_addr    (16'h0000),
        .rom_data    (8'h00),
        .rom_we      (1'b0),
        .dma_clk     (clk),
        .dma_addr    (16'd0),
        .dma_rdata   ()
    );

    axi_slave_mem u_axi_mem (
        .clk (clk), .rst (rst),
        .s_axi_awaddr (axi_awaddr), .s_axi_awlen (axi_awlen), .s_axi_awsize (axi_awsize),
        .s_axi_awburst(axi_awburst),.s_axi_awvalid(axi_awvalid),.s_axi_awready(axi_awready),
        .s_axi_wdata  (axi_wdata),  .s_axi_wstrb (axi_wstrb), .s_axi_wlast (axi_wlast),
        .s_axi_wvalid (axi_wvalid), .s_axi_wready(axi_wready),
        .s_axi_bvalid (axi_bvalid), .s_axi_bready(axi_bready),
        .s_axi_araddr (axi_araddr), .s_axi_arlen (axi_arlen), .s_axi_arsize (axi_arsize),
        .s_axi_arburst(axi_arburst),.s_axi_arvalid(axi_arvalid),.s_axi_arready(axi_arready),
        .s_axi_rdata  (axi_rdata),  .s_axi_rvalid(axi_rvalid), .s_axi_rlast (axi_rlast),
        .s_axi_rready (axi_rready)
    );

    // ---- real math_cop, wired as fpga_xt_top does (clk_cpu = the CPU clk) ----
    // The GP0/engine side is quiescent: no EXEC/CHUNK/DONE, so the FSM stays in
    // IDLE and never touches AXI.  Tie the e_axi readies low.
    math_cop #(.STACK_BASE(32'h2080_0000), .APERTURE_LOG2(13)) u_math (
        .clk        (clk),  .rst      (rst),
        .clk_cpu    (clk),
        .cpu_addr   (scrn_cpu_addr), .cpu_we (math_cpu_we), .cpu_wdata (scrn_cpu_wdata),
        .cpu_rden   (mc_rden),
        .cpu_rdata  (math_cpu_rdata),
        .exec_we    (math_exec_we),
        .chunk_wval (scrn_bank_wval), .chunk_we (math_chunk_we),
        .math_done  (math_done), .math_busy (math_busy), .chunk_ready (math_chunk_ready),
        .evt_data   (), .evt_pop (1'b0), .evt_irq (),
        .done_word  (24'd0), .done_we (1'b0), .stat_word (),
        .e_axi_araddr(), .e_axi_arlen(), .e_axi_arsize(), .e_axi_arburst(),
        .e_axi_arvalid(), .e_axi_arready(1'b0), .e_axi_rdata(32'd0),
        .e_axi_rvalid(1'b0), .e_axi_rlast(1'b0), .e_axi_rready(),
        .e_axi_awaddr(), .e_axi_awlen(), .e_axi_awsize(), .e_axi_awburst(),
        .e_axi_awvalid(), .e_axi_awready(1'b0), .e_axi_wdata(), .e_axi_wstrb(),
        .e_axi_wlast(), .e_axi_wvalid(), .e_axi_wready(1'b0),
        .e_axi_bvalid(1'b0), .e_axi_bready()
    );

    int fail_count = 0;
    task automatic expect_eq(input string label, input [7:0] got, input [7:0] want);
        if (got !== want) begin
            $display("FAIL %s: got=$%02h expected=$%02h", label, got, want);
            fail_count++;
        end else begin
            $display("  ok  %s = $%02h", label, got);
        end
    endtask

    // Set $D5C6 MAP bit through the CPU bus (one rdy=1 write cycle).
    task automatic set_map(input logic on);
        @(negedge clk); addr = 16'hD5C6; data_in = {7'b0, on}; rw = 1'b0; tb_rdy = 1'b1;
        @(posedge clk);
        @(negedge clk); rw = 1'b1; data_in = 8'h00;
    endtask

    // CPU write to a math-aperture byte (rdy=1 active cycle -> math_cpu_we).
    task automatic cpu_write(input [15:0] a, input [7:0] v);
        @(negedge clk); addr = a; data_in = v; rw = 1'b0; tb_rdy = 1'b1;
        @(posedge clk);                 // active edge: page_bram (+shadow) written
        @(negedge clk); rw = 1'b1; data_in = 8'h00;
    endtask

    // CPU read of `a` WITH `nstall` stall cycles, faithfully modelling the
    // registered-MAR core: present `a` for one rdy=1 cycle, then RDY drops and
    // the address bus advances to `nextaddr` (the CPU's next fetch) for the
    // stall, then RDY re-asserts and the CPU samples data_out.
    task automatic cpu_read_stalled(input [15:0] a, input [15:0] nextaddr,
                                    input int nstall, output [7:0] d);
        // active cycle: present the read address
        @(negedge clk); addr = a; rw = 1'b1; tb_rdy = 1'b1;
        @(posedge clk);                 // edge E: was_math_q/bram_dout_q latch for `a`
        // stall: CPU frozen, MAR has advanced -> address bus shows nextaddr
        @(negedge clk); addr = nextaddr; tb_rdy = 1'b0;
        repeat (nstall) @(posedge clk);
        // next active cycle: CPU consumes data_out (sample before the edge)
        @(negedge clk); tb_rdy = 1'b1;
        #1 d = data_out;
        @(posedge clk);
        @(negedge clk);
    endtask

    // Plain read, no stall (turbo-equivalent: rdy=1 every cycle).
    task automatic cpu_read(input [15:0] a, output [7:0] d);
        @(negedge clk); addr = a; rw = 1'b1; tb_rdy = 1'b1;
        @(posedge clk);
        @(negedge clk);
        #1 d = data_out;
    endtask

    initial begin
        logic [7:0] v;
`ifdef MATH_RDEN_FREE
        $display("=== math overlay round-trip (BUG-REPRO: cpu_rden tied high) ===");
`else
        $display("=== math overlay round-trip (FIXED: cpu_rden = rdy) ===");
`endif
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        // Enable the math page overlay on $4000-$5FFF.
        set_map(1'b1);

        // Seed two distinct page words:
        //   $4040 (line 1, word 8, boff 0) = $6F  (111 — the HW POKE value)
        //   $4048 (line 1, word 9, boff 0) = $FB  (251 — the HW neighbour value)
        cpu_write(16'h4040, 8'h6F);
        cpu_write(16'h4048, 8'hFB);

        // T1 — no-stall overlay read round-trip (works even pre-fix).
        $display("[T1] no-stall overlay read");
        cpu_read(16'h4040, v);
        expect_eq("T1 read $4040 (no stall)", v, 8'h6F);

        // T2 — THE REPRO.  Read $4040 while the CPU stalls and its MAR advances
        // to the neighbour $4048.  Correct = $6F (what was written).  Pre-fix
        // the free-running read chases $4048 and returns $FB — exactly the HW
        // symptom (POKE 16448,111 : PRINT PEEK(16448) -> 251).
        $display("[T2] stalled overlay read (MAR advances to neighbour)");
        cpu_read_stalled(16'h4040, 16'h4048, 4, v);
`ifdef MATH_RDEN_FREE
        if (v === 8'h6F) begin
            $display("FAIL T2(repro): expected the BUG ($FB) but read $6F — bug not reproduced");
            fail_count++;
        end else begin
            $display("  REPRO ok: stalled read of $4040 returned $%02h (stale neighbour $4048), NOT $6F", v);
            expect_eq("T2 repro shows stale neighbour", v, 8'hFB);
        end
`else
        expect_eq("T2 read $4040 (stalled, MAR->$4048)", v, 8'h6F);
`endif

        // T3 — same, longer stall + a non-aperture next fetch ($E000, ROM/RAM).
        // Correct read must still be $6F.
        $display("[T3] stalled overlay read, next fetch outside the aperture");
        cpu_read_stalled(16'h4040, 16'hE000, 6, v);
`ifndef MATH_RDEN_FREE
        expect_eq("T3 read $4040 (stalled, MAR->$E000)", v, 8'h6F);
`else
        $display("  (repro mode) T3 stalled read returned $%02h", v);
`endif

        // T4 — prove the read genuinely comes from the math PAGE, not the BRAM
        // shadow: poke the page word directly (hierarchical) to a value the
        // shadow never saw, then read it back.  $4050 = line 1, word 10, boff 0.
        $display("[T4] overlay read sources the math page, not the shadow");
        u_math.page_bram[10] = 64'h0000_0000_0000_0033;  // word 10 byte0 = $33
        // shadow mem[$4050] is still whatever init left it (never written $33)
`ifndef MATH_RDEN_FREE
        cpu_read_stalled(16'h4050, 16'h4058, 3, v);
        expect_eq("T4 read $4050 = page byte $33", v, 8'h33);
`else
        $display("  (repro mode) T4 skipped");
`endif

        if (fail_count == 0) begin
            $display("*** SALLY_MATH_OVERLAY OK ***");
            $finish;
        end else begin
            $display("*** SALLY_MATH_OVERLAY FAIL *** %0d failure(s)", fail_count);
            $fatal(1);
        end
    end

    initial begin
        #2_000_000;
        $display("FAIL: tb_sally_math_overlay watchdog");
        $fatal(1);
    end

endmodule

`default_nettype wire
