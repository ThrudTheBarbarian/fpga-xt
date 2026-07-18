// fpga_xt_top.sv — Phase 1 top-level: SALLY + ANTIC integrated on Zynq-7020.
//
// Clock domains:
//   clk_sally (120 MHz) — SALLY core, sally_mem, banked_axi_reader
//   clk_sys   (150 MHz) — ANTIC pipeline, I2C HDMI config, blitter,
//                         AXI HP fetch (raised from 100 MHz via
//                         BL_RACC pipeline + AXI register slice)
//   clk_pix   (148.44 MHz) — RGB565 pixel output to SiI9022A HDMI transmitter
//
// CDC:
//   - SALLY→ANTIC register writes: async FIFO (cdc_fifo_1w1r)
//   - ANTIC→SALLY status (nmi_n, irq_n, halt_n, rdy_n): 2-FF sync
//   - ANTIC DMA reads from sally_mem BRAM via dual-port (dma_clk = clk_sys)
//   - SALLY bank-select state → ANTIC: 2-FF sync on update strobe
//
// DMA path:
//   ANTIC's dma_master is wired but unused.  At our operating point
//   (CLOCK_MULT≫1), sally_clock bypasses /HALT.  ANTIC reads display data
//   from sally_mem's second BRAM port via a lightweight bram_shim.
//
// Build variants:
//   synth:  fpga_xt_top — standalone synth probe (out_of_context)
//   impl:   fpga_xt_top — full place+route (needs Zynq PS block)
//   bit:    full bitstream (needs Zynq PS block + board)

`default_nettype none

module fpga_xt_top (
    // ---- Clocks & reset --------------------------------------------------
    input  wire        clk_50,           // 50 MHz reference from onboard osc
    input  wire        rst_n,            // active-low reset (from PS or button)

    // ---- RGB565 parallel output to SiI9022A -------------------------------
    output wire [4:0]  rgb_r,
    output wire [5:0]  rgb_g,
    output wire [4:0]  rgb_b,
    output wire        rgb_hsync,
    output wire        rgb_vsync,
    output wire        rgb_de,
    output wire        rgb_pixclk,

    // ---- Debug UART (through PS MIO) --------------------------------------
    output wire        uart_tx,
    input  wire        uart_rx,

    // ---- SiI9022A I2C configuration bus (open-drain) --------------------
    // Connected to the HDMI transmitter on the Z-Turn baseboard.
    // External 4.7 kΩ pull-ups to 3.3 V on the baseboard.
    inout  wire        hdmi_sda,
    inout  wire        hdmi_scl,

    // ---- Debug observability (OOC synth preserves domains) ----------------
    // Sampled signals from each clock domain.  In OOC synthesis, these give
    // the tool a path from every domain to an output port, preventing the
    // constant-propagation cascade that would otherwise optimise away the
    // AXI masters, SALLY core, and ANTIC pipeline.
        output wire [3:0]  dbg         // {bl_busy, antic_we, sally_step, fb_arvalid}
    );

    // ====================================================================
    // Clock generation — two MMCME2_BASE primitives
    // ====================================================================
    // MMCM #1 (system + CPU domains)
    //   VCO = 50 MHz × 24 = 1200 MHz (within -2 600-1600 MHz range)
    //     CLKOUT0 /10 → 120.000 MHz clk_sally
    //                    (xt6502 operating point; the memory round-trip +
    //                    routing is the binding path, CPU true ceiling ~133+)
    //     CLKOUT1 /8  → 150.000 MHz clk_sys
    //                    (ANTIC pipeline, AXI HP fetch clock;
    //                     raised from 100 MHz via BL_RACC pipeline +
    //                     AXI register slice + cx CARRY4 pipeline
    //                     to close timing at 150 MHz)
    //
    // MMCM #2 (pixel clock — dedicated so MMCM #1 can keep exact 100/150)
    //   VCO = 50 MHz × 23.750 = 1187.5 MHz
    //     CLKOUT0_F /8.000 → 148.4375 MHz clk_pix
    //                    (target 148.500 MHz CEA-861 1080p60, error
    //                    -0.042 % — well inside the HDMI ±0.5 % spec)
    //
    // Two MMCMs keep clk_sys at 133.3 MHz while letting clk_pix
    // sit on its own VCO without forcing a compromise between the two.
    // MMCM utilisation rises to 2/4 — still plenty of headroom.

    wire clk_sally, clk_sys, clk_pix;

    // PL reference clock: an EXACT 50 MHz from the PS (FCLK_CLK1, derived from
    // the 33.33 MHz PS crystal), NOT the clk_50 pin.  The Z-Turn's only PL clock
    // pin (U14) is a 12 MHz crystal (X2, schematic sheet 10) — feeding the MMCMs
    // from it ran every derived clock at 1/4 spec (clk_pix ~37 MHz, HDMI dead).
    // FCLK_CLK1 is buffered in the PS and routed here by gen_ps_bd.tcl.
    wire fclk_50;

    // ---- MMCM #1: 120 MHz (clk_sally) + 150 MHz (clk_sys) from 50 MHz reference ---
    wire mmcm1_fb_in, mmcm1_fb_out;
    wire clk_sally_unbuf, clk_sys_unbuf;
    wire mmcm1_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (20.000),
        // Z7020 Artix-7 production config: sally 120 MHz, sys 150 MHz.
        // VCO = 1200 MHz (MULT_F=24); CLKOUT0_F=10 → 120 MHz sally,
        // CLKOUT1=8 → 150 MHz sys.
        //
        // Z7030 Kintex-7 fabric headroom note (probed 2026-05-18): the
        // same logic has more sally headroom on -2 Kintex if/when a Z7030
        // board becomes worthwhile.  The binding path is the CPU<->memory
        // round-trip + routing, not the xt6502 datapath itself (true core
        // ceiling ~133-155 MHz).
        .CLKFBOUT_MULT_F  (24.000),
        .DIVCLK_DIVIDE    (1),
        // STABLE config: clk_sally = VCO 1200 / 12 = 100 MHz (+0.444 ns,
        // ~56x turbo), clk_sys = VCO 1200 / 9 = 133.3 MHz (clean margin).
        // This is the build whose display + OS boot were confirmed PERFECT on
        // HW (2026-06-02).  120 MHz (DIV_F 10) no longer closes reliably:
        // today's heavier netlist (accumulated display fixes) lands clk_sally
        // marginal-to-failing across seeds (133/120 = -0.022/3, 150/120 =
        // -0.197/61 with clk_sys also -0.364/98).  150 is WORSE than 133 now
        // (clk_sys fails at 150).  Restoring 120 turbo needs real timing
        // closure (floorplan sally_mem), not a seed reroll — a deliberate fmax
        // task.  clk_pix (MMCM #2) untouched = 148.4375 MHz 1080p60.
        .CLKOUT0_DIVIDE_F (12.000),
        .CLKOUT1_DIVIDE   (9),
        .BANDWIDTH        ("OPTIMIZED")
    ) u_mmcm1 (
        .CLKIN1   (fclk_50),     // 50 MHz from PS FCLK_CLK1 (not the 12 MHz pin)
        .CLKFBIN  (mmcm1_fb_in),
        .CLKFBOUT (mmcm1_fb_out),
        .CLKOUT0  (clk_sally_unbuf),
        .CLKOUT1  (clk_sys_unbuf),
        .CLKOUT2  (),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .RST      (1'b0),     // was ~rst_n: R19 (rst_n) floats/glitches on this
                              // board and was periodically RESETTING the MMCM
                              // (pll_lock seen cycling ~1Hz -> clk_sys stops ->
                              // GP0/HP AXI hangs).  MMCM resets via config GSR;
                              // it needs no runtime reset.
        .PWRDWN   (1'b0),
        .LOCKED   (mmcm1_locked)
    );

    BUFG u_bufg_fb1   (.I(mmcm1_fb_out),     .O(mmcm1_fb_in));
    BUFG u_bufg_sally (.I(clk_sally_unbuf),  .O(clk_sally));
    BUFG u_bufg_sys   (.I(clk_sys_unbuf),    .O(clk_sys));

    // ---- MMCM #2: 148.4375 MHz pixel clock -----------------------------
    wire mmcm2_fb_in, mmcm2_fb_out;
    wire clk_pix_unbuf;
    wire mmcm2_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (20.000),
        .CLKFBOUT_MULT_F  (23.750),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (8.000),
        .BANDWIDTH        ("OPTIMIZED")
    ) u_mmcm2 (
        .CLKIN1   (fclk_50),     // 50 MHz from PS FCLK_CLK1 (not the 12 MHz pin)
        .CLKFBIN  (mmcm2_fb_in),
        .CLKFBOUT (mmcm2_fb_out),
        .CLKOUT0  (clk_pix_unbuf),
        .CLKOUT1  (),
        .CLKOUT2  (),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .RST      (1'b0),     // see MMCM1 — decoupled from the glitchy rst_n pin
        .PWRDWN   (1'b0),
        .LOCKED   (mmcm2_locked)
    );

    BUFG u_bufg_fb2 (.I(mmcm2_fb_out),  .O(mmcm2_fb_in));
    // clk_pix rides a BUFGCE (not a plain BUFG) so the video-sleep bit
    // (gp0_ctrl[5]) can gate the WHOLE pixel domain — compositor + the ODDR that
    // forwards the pixel clock to the SiI — for a low-power display-off.  MMCM #2
    // keeps running (its feedback is u_bufg_fb2, independent of clk_pix), so it
    // stays locked and clk_pix resumes cleanly on wake (SiI re-acquire via
    // /OS/proc/video-kick).  CE defaults HIGH (run); driven from clk_sys reg
    // gp0_ctrl below, so wake works even though clk_pix itself was stopped.
    wire pix_clk_ce;                                   // 1 = run, 0 = sleep
    BUFGCE u_bufg_pix (.I(clk_pix_unbuf), .CE(pix_clk_ce), .O(clk_pix));

    // ---- Per-domain reset synchronisers ---------------------------------
    // Async-assert / sync-deassert, each domain gated on ITS OWN MMCM's lock.
    // clk_sally/clk_sys come from MMCM1; clk_pix from MMCM2.  Previously every
    // domain reset on (mmcm1_locked & mmcm2_locked) — which meant MMCM2
    // (clk_pix, 148.4375MHz, fractional) losing lock would yank the clk_sys
    // GP0/HP bridge into reset mid-AXI-transaction -> CPU hangs on a GP0 read.
    // Decoupled: MMCM2 instability no longer disturbs the clk_sys/clk_sally
    // domains.  rst_n (R19) stays dropped — that pin floats on this board (real
    // reset is the PS_SRST button K2); config-GSR + MMCM-lock is the release.
    wire rst_rel_mmcm1_n = mmcm1_locked;   // clk_sally + clk_sys
    wire rst_rel_mmcm2_n = mmcm2_locked;   // clk_pix

    logic [2:0] rst_sally_pipe, rst_sys_pipe, rst_pix_pipe;
    always_ff @(posedge clk_sally or negedge rst_rel_mmcm1_n) begin
        if (!rst_rel_mmcm1_n) rst_sally_pipe <= 3'b111;
        else                  rst_sally_pipe <= {rst_sally_pipe[1:0], 1'b0};
    end
    always_ff @(posedge clk_sys or negedge rst_rel_mmcm1_n) begin
        if (!rst_rel_mmcm1_n) rst_sys_pipe <= 3'b111;
        else                  rst_sys_pipe <= {rst_sys_pipe[1:0], 1'b0};
    end
    always_ff @(posedge clk_pix or negedge rst_rel_mmcm2_n) begin
        if (!rst_rel_mmcm2_n) rst_pix_pipe <= 3'b111;
        else                  rst_pix_pipe <= {rst_pix_pipe[1:0], 1'b0};
    end
    wire rst_sally   = rst_sally_pipe[2];
    wire rst_sys     = rst_sys_pipe[2];
    wire rst_pix     = rst_pix_pipe[2];
    wire rst_sally_n = ~rst_sally;
    wire rst_sys_n   = ~rst_sys;

    // ---- A9-held SALLY reset (CTRL 0x1C bit 0) ---------------------------
    // Cold-boot-per-launch (docs/OS/app-launch.md): the A9 sets the bit, the
    // 6502 core + its clock gen freeze in reset, the A9 rewrites the OS/RAM
    // through the ROM-loader window (which stays ALIVE — it and sally_mem keep
    // plain rst_sally, so uploads work while held), then clears the bit for a
    // fresh coldstart.  Quasi-static 2-FF CDC from clk_sys, initialised 0
    // (running) — the same shape as CMPCFG.  The XT CCTL state a stock guest
    // can't know about ($D5C0/C1, screen banks) is cleared by the patched OS
    // coldstart, not here — sally_mem must not reset (BRAM writes, bank
    // in-flight AXI drain).
    wire [7:0] sallyrst;                     // clk_sys, from xt_gp0_regs
    (* ASYNC_REG = "TRUE" *) reg [1:0] sallyrst_sync = 2'b00;
    always_ff @(posedge clk_sally) sallyrst_sync <= {sallyrst_sync[0], sallyrst[0]};
    wire rst_sally_core = rst_sally | sallyrst_sync[1];

    // ====================================================================
    // PL diagnostic word — read over GP0 at 0x43C0001C (no LED guessing)
    // ====================================================================
    //   diag_word[0]     = mmcm1_locked (clk_sally/clk_sys MMCM)
    //   diag_word[1]     = mmcm2_locked (clk_pix MMCM)
    //   diag_word[15:8]  = clk_pix-alive count — climbs while clk_pix toggles;
    //                      STUCK => clk_pix dead (e.g. mmcm2 not locked)
    //   diag_word[23:16] = mmcm2 unlock-event count — # of falling edges of
    //                      mmcm2_locked since config; 0 => it never dropped
    wire [31:0] diag_word;

    // MMCM LOCKED outputs are asynchronous — sync into clk_sys.
    (* ASYNC_REG = "TRUE" *) reg [1:0] m1_lock_sync = '0, m2_lock_sync = '0;
    always_ff @(posedge clk_sys) begin
        m1_lock_sync <= {m1_lock_sync[0], mmcm1_locked};
        m2_lock_sync <= {m2_lock_sync[0], mmcm2_locked};
    end
    wire mmcm1_lock_s = m1_lock_sync[1];
    wire mmcm2_lock_s = m2_lock_sync[1];

    // clk_pix liveness: a slow toggle on clk_pix, synced + edge-counted in
    // clk_sys, so a running clk_pix makes clk_pix_alive climb.
    reg [16:0] pix_div = '0;
    always_ff @(posedge clk_pix) pix_div <= pix_div + 1'b1;   // bit16 ~566 Hz
    (* ASYNC_REG = "TRUE" *) reg [2:0] pix_tgl_sync = '0;
    reg [7:0] clk_pix_alive = '0;
    always_ff @(posedge clk_sys) begin
        pix_tgl_sync <= {pix_tgl_sync[1:0], pix_div[16]};
        if (pix_tgl_sync[2] ^ pix_tgl_sync[1]) clk_pix_alive <= clk_pix_alive + 1'b1;
    end

    // mmcm2 unlock-event counter (falling edges of the synced lock).
    reg       m2_lock_prev = 1'b0;
    reg [7:0] mmcm2_unlocks = '0;
    always_ff @(posedge clk_sys) begin
        m2_lock_prev <= mmcm2_lock_s;
        if (m2_lock_prev & ~mmcm2_lock_s) mmcm2_unlocks <= mmcm2_unlocks + 1'b1;
    end

    // SiI9022 config now lives in the PS app (it drives I2C0 over EMIO and
    // reads back the device ID), so the PL no longer tracks config state.  Tie
    // the diag bit off; the app reports HDMI status over UART from its own I2C.
    wire hdmi_cfg_done = 1'b0;

    // vbeam frame heartbeat — PROVES vbeam is generating 1080p60 frames.  The
    // clk_pix-alive counter only proves the CLOCK toggles; vbeam itself is
    // rst_pix-gated, so it could be stuck while clk_pix runs.  fb_frame_tgl
    // toggles once per vbeam frame (driven @clk_pix in the video section);
    // edge-count it in clk_sys -> vbeam_frames climbs ~60/sec if vbeam runs.
    reg                                fb_frame_tgl   = 1'b0;  // driven @clk_pix below
    (* ASYNC_REG = "TRUE" *) reg [2:0]  frame_tgl_sync = '0;
    reg [7:0]                          vbeam_frames   = '0;
    always_ff @(posedge clk_sys) begin
        frame_tgl_sync <= {frame_tgl_sync[1:0], fb_frame_tgl};
        if (frame_tgl_sync[2] ^ frame_tgl_sync[1]) vbeam_frames <= vbeam_frames + 1'b1;
    end

    //   diag_word[31:24] = vbeam frame count, [2] = unused
    assign diag_word = {vbeam_frames, mmcm2_unlocks, clk_pix_alive,
                        5'b0, hdmi_cfg_done, mmcm2_lock_s, mmcm1_lock_s};

    // ====================================================================
    // SALLY + memory (runs on clk_sally)
    // ====================================================================
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_din, cpu_dout;
    wire        cpu_rw;
    wire        sally_rdy;

    // sally_clock wires
    // phi2_tick gating is bypassed at clock_mult >= 2 (56 = full turbo); the
    // strobe input is still required by the port, so tie it off.  antic_top
    // computes its own phi2_tick internally for its consumers (vbeam etc.).
    wire        phi2_tick = 1'b0;
    wire        halt_n_sally;      // /HALT after CDC (external-ANTIC mode; unused at our op point)
    wire        antic_dma_steal_w; // ANTIC cycle-steal (clk_sys, active-high) from antic_top
    wire        dma_steal_sally;   // ...CDC'd into clk_sally; gates the CPU at CLOCK_MULT=1
    wire        wsync_rdy_n;       // from ANTIC WSYNC
    wire        mem_busy_n;        // from sally_mem (1 = ready)
    wire        sally_step;

    // Register read-back CDC (boot blocker #3) —
    // declared early so sally_clock can fold hwreg_rd_busy into its stall.
    // Driven by u_hwreg_rd_cdc further down.
    wire        cdc_bus_read;      // clk_sys: CDC owns the ANTIC bus for a read
    wire [15:0] cdc_bus_addr;      // clk_sys: read address presented to ANTIC
    wire [7:0]  cdc_rd_data;       // clk_sally: returned register byte
    wire        hwreg_rd_busy;     // clk_sally: stall SALLY during the round-trip

    // Bank-select state (from SALLY zero-page snoop)
    wire [7:0]  cpu_code_bank, cpu_data_bank;
    // Banked screen RAM ($4000-$5FFF) — sally_mem decodes $D5C3/$D5C4/$D5C5;
    // the screen_bank engine (clk_sys/AXI + ANTIC reload) is wired in a later
    // stage.  Until then scrn_ready is tied high (banking writes are no-ops).
    wire [7:0]  scrn_cpu_bank, scrn_antic_bank, scrn_bank_wval;
    wire        scrn_cpu_bank_we, scrn_antic_bank_we;
    wire        scrn_ready;               // <- screen_bank
    wire [12:0] scrn_cpu_addr;
    wire        scrn_cpu_we;
    wire [7:0]  scrn_cpu_wdata;
    wire [7:0]  scrn_cpu_rdata;           // <- screen_bank CPU port
    wire [7:0]  scrn_antic_rdata;         // <- screen_bank ANTIC port
    wire        scrn_antic_banked;        // <- screen_bank (ANTIC eff bank != 0)

    // Math-coprocessor page (math_cop engine, $D5C6-$D5C8 decoded in sally_mem).
    // Shares scrn_cpu_addr/scrn_cpu_wdata for the aperture byte port and
    // scrn_bank_wval for the $D5C8 chunk value.
    wire        math_map;                 // $D5C6.0 (CPU aperture overlay)
    wire        math_exec_we;             // $D5C7 write strobe (doorbell)
    wire        math_chunk_we;            // $D5C8 write strobe
    wire        math_done, math_busy, math_chunk_ready;   // <- math_cop status
    wire        math_cpu_we;
    wire [7:0]  math_cpu_rdata;           // <- math_cop CPU port
    wire        math_irq;                 // <- math_cop event FIFO non-empty -> IRQ_F2P[1]

    // ANTIC-view bank registers ($D488-$D48B) are currently unused in the
    // Zynq build — ANTIC's DMA reaches RAM via bram_shim, not via
    // sally_mem's CPU bus, so sally_mem never needs to switch to the
    // ANTIC bank context.  Inputs tied to 0 / 1'b0 at the sally_mem
    // instantiation below.

    // Hardware register passthrough (SALLY→ANTIC bus via CDC FIFO)
    wire [15:0] hwreg_addr;
    wire [7:0]  hwreg_din;
    wire        hwreg_we;
    wire [7:0]  hwreg_dout;

    // AXI bus to DDR3 (banked-window port) — banked_page_cache code/data
    // demand-fill + dirty write-back, via S_AXI_ACP (PS BD port 'm_axi_sally').
    // 64-bit; AXI4->AXI3 arlen truncation at the wrapper; ACP non-coherent
    // (aruser/awuser tied 0).  Dormant until $D5C0/$D5C1 select a non-zero bank.
    wire [31:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    wire        axi_arvalid;
    wire        axi_rready;
    wire [31:0] axi_awaddr;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;
    wire        axi_awvalid;
    wire [63:0] axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast;
    wire        axi_wvalid;
    wire        axi_bready;
    wire        axi_arready;   // <- ps_bd m_axi_sally (ACP)
    wire [63:0] axi_rdata;
    wire        axi_rvalid;
    wire        axi_rlast;
    wire        axi_awready;
    wire        axi_wready;
    wire        axi_bvalid;

    // ---- AXI HP port connections — routed through internal HP stub ---------
    // HP0 — plane_fetch (read-only AXI4 master → AXI3 slave)
    // Note: plane_fetch uses 8-bit arlen (AXI4); AXI3 truncates to lower 4 bits.
    wire [31:0] hp0_araddr;
    wire [7:0]  hp0_arlen;     // 8-bit from plane_fetch; truncated to 4-bit at stub
    wire [2:0]  hp0_arsize;
    wire [1:0]  hp0_arburst;
    wire        hp0_arvalid;
    wire        hp0_arready;
    wire [63:0] hp0_rdata;
    wire        hp0_rvalid;
    wire        hp0_rlast;
    wire        hp0_rready;
    // HP0 write channel — tied (plane_fetch is read-only)
    wire [31:0] hp0_awaddr = 32'd0;
    wire [3:0]  hp0_awlen  = 4'd0;
    wire [2:0]  hp0_awsize = 3'd0;
    wire [1:0]  hp0_awburst = 2'd0;
    wire        hp0_awvalid = 1'b0;
    wire        hp0_awready;
    wire [63:0] hp0_wdata = 64'd0;
    wire [7:0]  hp0_wstrb = 8'd0;
    wire        hp0_wlast = 1'b0;
    wire        hp0_wvalid = 1'b0;
    wire        hp0_wready;
    wire        hp0_bvalid;
    wire        hp0_bready = 1'b0;

    // HP1 — xt_blitter (AXI4 read/write master → AXI3 slave)
    // awlen/arlen carried as AXI4 8-bit internally; sliced to 4-bit at the
    // stub / PS BD boundary (see s_axi_hp1_*len connections below).
    wire [31:0] hp1_awaddr;
    wire [7:0]  hp1_awlen;
    wire [2:0]  hp1_awsize;
    wire [1:0]  hp1_awburst;
    wire        hp1_awvalid;
    wire        hp1_awready;
    wire [63:0] hp1_wdata;
    wire [7:0]  hp1_wstrb;
    wire        hp1_wlast;
    wire        hp1_wvalid;
    wire        hp1_wready;
    wire        hp1_bvalid;
    wire        hp1_bready;
    // HP1 read channel — driven by xt_blitter (block blit)
    wire [31:0] hp1_araddr;
    wire [7:0]  hp1_arlen;
    wire [2:0]  hp1_arsize;
    wire [1:0]  hp1_arburst;
    wire        hp1_arvalid;
    wire        hp1_arready;
    wire [63:0] hp1_rdata;
    wire        hp1_rvalid;
    wire        hp1_rlast;
    wire        hp1_rready;

    // HP3 — the XL plane READ port (video-arch §5, §10).  READ-ONLY:
    //   read channel ← plane_fetch1 (XL surface → compositor plane 1).
    // The writeback's WRITE channel moved to HP2 (below) so a write burst can no
    // longer stall this read on the same HP port — that read/write contention
    // tripped plane_fetch's watchdog, abandoning a read mid-burst and leaving a
    // stale line (the beat-correlated ghost line + text glitch).  Write channel
    // tied off at the ps_bd instance.  Runs on clk_sys, like HP0/HP1.
    wire [31:0] hp3_araddr;
    wire [7:0]  hp3_arlen;
    wire [2:0]  hp3_arsize;
    wire [1:0]  hp3_arburst;
    wire        hp3_arvalid;
    wire        hp3_arready;
    wire [63:0] hp3_rdata;
    wire        hp3_rvalid;
    wire        hp3_rlast;
    wire        hp3_rready;

    // HP2 — the XL surface WRITE port, plus the drag-overlay READ:
    //   write channel ← antic_writeback (ANTIC render → DDR3 XL surface).
    //   read  channel ← plane_fetch_overlay (drag-overlay line read).
    // (Was the bring-up hp_read_probe, retired — PL→DDR reads are proven by the
    // live display.)  Separating writeback writes from the XL read (HP3) removes
    // the same-port read/write contention.  The read channel was tied off; the
    // drag-overlay reuses it (writeback is write-only, so AR/R were idle).
    wire [31:0] hp2_awaddr;
    wire [7:0]  hp2_awlen;      // 8-bit (AXI4); AXI3 slave truncates to lower 4
    wire [2:0]  hp2_awsize;
    wire [1:0]  hp2_awburst;
    wire        hp2_awvalid;
    wire        hp2_awready;
    wire [63:0] hp2_wdata;
    wire [7:0]  hp2_wstrb;
    wire        hp2_wlast;
    wire        hp2_wvalid;
    wire        hp2_wready;
    wire        hp2_bvalid;
    wire        hp2_bready;
    // HP2 read channel (drag-overlay plane_fetch master).
    wire [31:0] hp2_araddr;
    wire [7:0]  hp2_arlen;
    wire [2:0]  hp2_arsize;
    wire [1:0]  hp2_arburst;
    wire        hp2_arvalid;
    wire        hp2_arready;
    wire [63:0] hp2_rdata;
    wire        hp2_rvalid;
    wire        hp2_rlast;
    wire        hp2_rready;

    // HP2 read is shared (hp2_rd_mux): drag-overlay (s0) + sprite fetcher (s1).
    // The two masters drive these; the mux drives the hp2_* read channel above.
    wire [31:0] ovl_araddr;  wire [7:0] ovl_arlen;  wire [2:0] ovl_arsize;
    wire [1:0]  ovl_arburst; wire ovl_arvalid, ovl_arready;
    wire [63:0] ovl_rdata;   wire ovl_rvalid, ovl_rlast, ovl_rready;
    wire [31:0] spr_araddr;  wire [7:0] spr_arlen;  wire [2:0] spr_arsize;
    wire [1:0]  spr_arburst; wire spr_arvalid, spr_arready;
    wire [63:0] spr_rdata;   wire spr_rvalid, spr_rlast, spr_rready;

    // ANTIC's BRAM read port — driven by antic_top's u_bram_shim and
    // serviced by sally_mem's second BRAM port (clk_sys side).  SALLY
    // writes propagate naturally through sally_mem; ANTIC sees the
    // same state without a shadow memory.
    wire [15:0] antic_bram_addr;
    wire [7:0]  antic_bram_rdata;
    // ANTIC read mux: sally_mem's flat-shadow read (scrn_shadow_rdata) vs the
    // banked screen_bank ANTIC-BRAM (scrn_antic_rdata).  Select is registered to
    // align with both registered read data (1-cycle, clk_sys).
    wire [7:0]  scrn_shadow_rdata;
    reg         scrn_antic_sel_q;
    always_ff @(posedge clk_sys)
        scrn_antic_sel_q <= (antic_bram_addr[15:13] == 3'b010) && scrn_antic_banked;
    assign antic_bram_rdata = scrn_antic_sel_q ? scrn_antic_rdata : scrn_shadow_rdata;

    // PORTB ($D301) from PIA — controls ROM vs banked/BRAM visibility.
    wire [7:0]  portb_q;

    // Keyboard inject (boot blocker #5): the PS writes an
    // Atari KBCODE byte via the GP0 blitter-register bridge ($D4CF); that
    // pulses ANTIC's kbd_event into POKEY (loads KBCODE + raises the
    // keyboard IRQ).  Bridge and antic_top both run on clk_sys, so no CDC.
    logic       kbd_event_valid_q;
    logic [7:0] kbd_event_code_q;
    logic       kbd_release_q;        // $D4CD write — all-keys-up (clears SKSTAT key-down)
    logic       break_pulse_q;        // $D4CB write — Atari BREAK (POKEY IRQST bit 7)
    logic [7:0] clock_mult_q;         // $D4CA write — SALLY speed multiplier (resets to 1x)

    // ---- XT register-unlock (docs/Zynq/register-unlock.md) ---------------
    // One 8-bit register gating the NATIVE (6502/ANTIC-side) decode of the XT
    // extensions.  Two write ports (A9 via the GP0 bridge = authority; 6502 via
    // $D1DF = self-unlock); the A9/bridge path itself is never gated.  This box
    // is XT-NATIVE — its own desktop+OS depend on the XT registers — so reset
    // defaults to ALL-UNLOCKED; the A9 LOCKS groups (then resets the 6502) only
    // when launching a stock guest.  xt_unlock is quasi-static (changes only on
    // an unlock write), so every consumer takes a *registered* copy near its
    // own logic (xt_unlock_loc here; unlock_antic_q in antic_top; unlock_bank_q
    // synced in sally_mem) — the raw register must not fan a long combinational
    // net across the die onto critical clk_sys paths.
    localparam int UNLK_ANTIC  = 0;   // $D480-$D49F ANTIC chiplet (MODE/pal/DRAW/ROM)
    localparam int UNLK_SPRITE = 1;   // sprite engine $D4Ax/$D4Dx
    localparam int UNLK_BLIT   = 2;   // blitter native $D4Bx/$D4Cx + $D4CA turbo
    localparam int UNLK_BANK   = 3;   // $D5C0/$D5C1 code/data bank select
    localparam int UNLK_GEM    = 4;   // $D5D0-$D5D4 GEM doorbell (reserved; not built)
    localparam int UNLK_KBD    = 5;   // reserved (kbd inject is bridge-only — no native decode)
    localparam logic [7:0] XT_UNLOCK_RESET = 8'hFF;  // XT-native: all groups live at power-on
    logic [7:0] xt_unlock;
    (* keep = "true" *) logic [7:0] xt_unlock_loc;   // local registered copy for the blitter/sprite gates

    // ====================================================================
    // AXI pipeline registers — HP1 (xt_blitter) → PS BD
    // ====================================================================
    // Only used in the PS BD bitstream path (USE_PS_BD).  The OOC stub path
    // (else branch below) connects hp1_* directly to the stub.
    //
    // 2-deep register slice on every AXI signal between xt_blitter and
    // the PS block design.  This cuts the critical path through the PS
    // address decoder CARRY4s (processing_system7_v5_5 address decoder)
    // that was limiting clk_sys to 100 MHz.
    //
    // Forward paths (blitter → PS):
    //   AW: awaddr, awlen, awsize, awburst, awvalid
    //   W:  wdata, wstrb, wlast, wvalid
    //   AR: araddr, arlen, arsize, arburst, arvalid
    // Return paths (PS → blitter):
    //   B:  bvalid
    //   R:  rdata, rvalid, rlast
    // Ready signals are registered in the reverse direction:
    //   Forward-ready (PS→blitter): awready, wready, arready
    //   Return-ready (blitter→PS):  bready, rready

    `ifdef USE_PS_BD
    // Wires to PS BD side of the register slice
    wire [31:0] ps_hp1_awaddr;
    wire [7:0]  ps_hp1_awlen;
    wire [2:0]  ps_hp1_awsize;
    wire [1:0]  ps_hp1_awburst;
    wire        ps_hp1_awvalid;
    wire        ps_hp1_awready;
    wire [63:0] ps_hp1_wdata;
    wire [7:0]  ps_hp1_wstrb;
    wire        ps_hp1_wlast;
    wire        ps_hp1_wvalid;
    wire        ps_hp1_wready;
    wire        ps_hp1_bvalid;
    wire        ps_hp1_bready;
    wire [31:0] ps_hp1_araddr;
    wire [7:0]  ps_hp1_arlen;
    wire [2:0]  ps_hp1_arsize;
    wire [1:0]  ps_hp1_arburst;
    wire        ps_hp1_arvalid;
    wire        ps_hp1_arready;
    wire [63:0] ps_hp1_rdata;
    wire        ps_hp1_rvalid;
    wire        ps_hp1_rlast;
    wire        ps_hp1_rready;

    // ---- Register slices (all on clk_sys) ---------------------------------
    reg [31:0] hp1_awaddr_r, ps_hp1_awaddr_r;
    reg [7:0]  hp1_awlen_r, ps_hp1_awlen_r;
    reg [2:0]  hp1_awsize_r, ps_hp1_awsize_r;
    reg [1:0]  hp1_awburst_r, ps_hp1_awburst_r;
    reg        hp1_awvalid_r, ps_hp1_awvalid_r;
    reg        hp1_awready_r, ps_hp1_awready_r;
    reg [63:0] hp1_wdata_r, ps_hp1_wdata_r;
    reg [7:0]  hp1_wstrb_r, ps_hp1_wstrb_r;
    reg        hp1_wlast_r, ps_hp1_wlast_r;
    reg        hp1_wvalid_r, ps_hp1_wvalid_r;
    reg        hp1_wready_r, ps_hp1_wready_r;
    reg        hp1_bvalid_r, ps_hp1_bvalid_r;
    reg        hp1_bready_r, ps_hp1_bready_r;
    reg [31:0] hp1_araddr_r, ps_hp1_araddr_r;
    reg [7:0]  hp1_arlen_r, ps_hp1_arlen_r;
    reg [2:0]  hp1_arsize_r, ps_hp1_arsize_r;
    reg [1:0]  hp1_arburst_r, ps_hp1_arburst_r;
    reg        hp1_arvalid_r, ps_hp1_arvalid_r;
    reg        hp1_arready_r, ps_hp1_arready_r;
    reg [63:0] hp1_rdata_r, ps_hp1_rdata_r;
    reg        hp1_rvalid_r, ps_hp1_rvalid_r;
    reg        hp1_rlast_r, ps_hp1_rlast_r;
    reg        hp1_rready_r, ps_hp1_rready_r;

    always_ff @(posedge clk_sys) begin
        // Forward: blitter → register stage 1 → register stage 2 → PS
        // (two-stage pipeline for maximum timing isolation)
        //
        // Stage 1: capture blitter outputs
        hp1_awaddr_r    <= hp1_awaddr;
        hp1_awlen_r     <= hp1_awlen;
        hp1_awsize_r    <= hp1_awsize;
        hp1_awburst_r   <= hp1_awburst;
        hp1_awvalid_r   <= hp1_awvalid;
        hp1_wdata_r     <= hp1_wdata;
        hp1_wstrb_r     <= hp1_wstrb;
        hp1_wlast_r     <= hp1_wlast;
        hp1_wvalid_r    <= hp1_wvalid;
        hp1_araddr_r    <= hp1_araddr;
        hp1_arlen_r     <= hp1_arlen;
        hp1_arsize_r    <= hp1_arsize;
        hp1_arburst_r   <= hp1_arburst;
        hp1_arvalid_r   <= hp1_arvalid;
        hp1_bready_r    <= hp1_bready;
        hp1_rready_r    <= hp1_rready;

        // Stage 2: drive to PS
        ps_hp1_awaddr_r   <= hp1_awaddr_r;
        ps_hp1_awlen_r    <= hp1_awlen_r;
        ps_hp1_awsize_r   <= hp1_awsize_r;
        ps_hp1_awburst_r  <= hp1_awburst_r;
        ps_hp1_awvalid_r  <= hp1_awvalid_r;
        ps_hp1_wdata_r    <= hp1_wdata_r;
        ps_hp1_wstrb_r    <= hp1_wstrb_r;
        ps_hp1_wlast_r    <= hp1_wlast_r;
        ps_hp1_wvalid_r   <= hp1_wvalid_r;
        ps_hp1_araddr_r   <= hp1_araddr_r;
        ps_hp1_arlen_r    <= hp1_arlen_r;
        ps_hp1_arsize_r   <= hp1_arsize_r;
        ps_hp1_arburst_r  <= hp1_arburst_r;
        ps_hp1_arvalid_r  <= hp1_arvalid_r;
        ps_hp1_bready_r   <= hp1_bready_r;
        ps_hp1_rready_r   <= hp1_rready_r;

        // Return: PS → register stage 1 → register stage 2 → blitter
        hp1_awready_r     <= ps_hp1_awready;
        hp1_wready_r      <= ps_hp1_wready;
        hp1_arready_r     <= ps_hp1_arready;
        hp1_bvalid_r      <= ps_hp1_bvalid;
        hp1_rdata_r       <= ps_hp1_rdata;
        hp1_rvalid_r      <= ps_hp1_rvalid;
        hp1_rlast_r       <= ps_hp1_rlast;
    end

    // Connect stage-2 outputs to PS BD
    assign ps_hp1_awaddr   = ps_hp1_awaddr_r;
    assign ps_hp1_awlen    = ps_hp1_awlen_r;
    assign ps_hp1_awsize   = ps_hp1_awsize_r;
    assign ps_hp1_awburst  = ps_hp1_awburst_r;
    assign ps_hp1_awvalid  = ps_hp1_awvalid_r;
    assign ps_hp1_wdata    = ps_hp1_wdata_r;
    assign ps_hp1_wstrb    = ps_hp1_wstrb_r;
    assign ps_hp1_wlast    = ps_hp1_wlast_r;
    assign ps_hp1_wvalid   = ps_hp1_wvalid_r;
    assign ps_hp1_araddr   = ps_hp1_araddr_r;
    assign ps_hp1_arlen    = ps_hp1_arlen_r;
    assign ps_hp1_arsize   = ps_hp1_arsize_r;
    assign ps_hp1_arburst  = ps_hp1_arburst_r;
    assign ps_hp1_arvalid  = ps_hp1_arvalid_r;
    assign ps_hp1_bready   = ps_hp1_bready_r;
    assign ps_hp1_rready   = ps_hp1_rready_r;

    // Connect return signals to blitter
    assign hp1_awready = hp1_awready_r;
    assign hp1_wready  = hp1_wready_r;
    assign hp1_arready = hp1_arready_r;
    assign hp1_bvalid  = hp1_bvalid_r;
    assign hp1_rdata   = hp1_rdata_r;
    assign hp1_rvalid  = hp1_rvalid_r;
    assign hp1_rlast   = hp1_rlast_r;
    `else
    // OOC path: direct connection — stub drives hp1_* directly, no pipeline
    // registers.  ps_hp1_* wires are not declared in this branch.
    `endif

    // ---- sally_clock -----------------------------------------------------
    // BASE_DIV sets the 1x (real-Atari) phi2: phi2 = clk_sally / BASE_DIV, so
    // BASE_DIV tracks clk_sally as round(clk_sally_MHz / 1.79).  At clk_sally =
    // 100 MHz, BASE_DIV=56 -> 1.786 MHz ≈ real NTSC phi2; CLOCK_MULT=56 (full
    // turbo) steps every cycle = 100 MHz.  Keep the phi2 RATE matched to
    // antic_top's BASE_DIV (which divides clk_sys, so a different value).
    // /HALT is bypassed at CLOCK_MULT>=2, so halt_n is tied high.
    // wsync_rdy_n comes from ANTIC via CDC.
    // busy_n comes from sally_mem (1 = ready, 0 = cache miss stall).

    sally_clock #(
        .BASE_DIV (56)
    ) u_sally_clock (
        .clk           (clk_sally),
        .rst           (rst_sally_core),     // A9 hold freezes the step gen too
        .phi2_tick     (phi2_tick),
        .clock_mult    (clock_mult_sally),   // runtime-set via $D4CA (REPL `speed`); resets to 1x
        .halt_n        (~dma_steal_sally), // ANTIC DMA bus-steal; gated to CLOCK_MULT=1 inside
        .wsync_rdy_n   (wsync_rdy_n),
        .busy_n        (~(mem_busy_n | hwreg_rd_busy)),  // stall on sally_mem cache miss OR hwreg-read CDC round-trip
        .sally_rdy     (sally_rdy),
        .sally_step    (sally_step)
    );

    // ---- CPU (xt6502) ----------------------------------------------------
    wire        cpu_stack_op;
    wire [3:0]  cpu_s_high;

    // The xt6502 clean-sheet core (registered MAR, mem round-trip in-clock).
    // ---- 6502 debugger (xt6502_debug) wires ----
    wire        cdbg_boundary;
    wire [15:0] cdbg_pc;
    wire [7:0]  cdbg_a, cdbg_x, cdbg_y, cdbg_s, cdbg_p;
    wire [3:0]  cdbg_shigh;
    wire        idbg_wr;
    wire [15:0] idbg_wpc;
    wire [7:0]  idbg_wa, idbg_wx, idbg_wy, idbg_ws, idbg_wp;
    wire [3:0]  idbg_wshigh;
    wire        dbg_core_run;                // gates .rdy (1 = run)
    // control from xt_gp0_regs (clk_sys), synchronised inside the debug block
    wire        gdbg_halt_tog, gdbg_go_tog, gdbg_step_tog, gdbg_commit_tog;
    wire [1:0]  gdbg_cfg;
    wire [15:0] gdbg_bkpt, gdbg_stepcnt, gdbg_wpc;
    wire [31:0] gdbg_waxys;
    wire [11:0] gdbg_wpsh;
    // status back to xt_gp0_regs (clk_sally; coherent when halted)
    wire [3:0]  sdbg_stat;
    wire [15:0] sdbg_pc;
    wire [31:0] sdbg_axys;
    wire [11:0] sdbg_psh;
    wire [31:0] sdbg_icnt;
    // trace-ring control (from GP0) + readback
    wire [1:0]  gdbg_trc_ctrl;
    wire [11:0] gdbg_trc_idx;
    wire [31:0] sdbg_trc_wptr;
    wire [15:0] sdbg_trc_pc;
    wire [31:0] sdbg_trc_axys;
    wire [11:0] sdbg_trc_p;

    xt6502 u_sally_core (
        .clk      (clk_sally),
        .rst      (rst_sally_core),          // A9-held for cold-boot-per-launch
        .addr     (cpu_addr),
        .data_in  (cpu_din),
        .data_out (cpu_dout),
        .rw       (cpu_rw),
        .rdy      (sally_rdy & dbg_core_run), // debugger HALT = non-destructive rdy gate
        .irq_n    (irq_n_sync),      // from ANTIC via CDC
        .nmi_n    (nmi_n_sync),      // from ANTIC via CDC
        .stack_op (cpu_stack_op),    // 12-bit stack push/pull cycle
        .s_high   (cpu_s_high),      // high 4 bits of SP
        // debug taps out
        .dbg_boundary (cdbg_boundary),
        .dbg_pc   (cdbg_pc),
        .dbg_a    (cdbg_a), .dbg_x (cdbg_x), .dbg_y (cdbg_y),
        .dbg_s    (cdbg_s), .dbg_p (cdbg_p), .dbg_shigh (cdbg_shigh),
        // debug register injection in
        .dbg_wr   (idbg_wr),
        .dbg_wpc  (idbg_wpc),
        .dbg_wa   (idbg_wa), .dbg_wx (idbg_wx), .dbg_wy (idbg_wy),
        .dbg_ws   (idbg_ws), .dbg_wp (idbg_wp), .dbg_wshigh (idbg_wshigh)
    );

    // In-fabric 6502 debugger — halt/step/breakpoint/register access (docs/OS/6502-debug.md).
    // Reset by rst_sally (power-on) so it survives a SALLYRST core reset.
    xt6502_debug u_sally_dbg (
        .clk          (clk_sally),
        .rst          (rst_sally),
        .core_rst     (rst_sally_core),
        .dbg_boundary (cdbg_boundary),
        .dbg_pc       (cdbg_pc),
        .dbg_a        (cdbg_a), .dbg_x (cdbg_x), .dbg_y (cdbg_y),
        .dbg_s        (cdbg_s), .dbg_p (cdbg_p), .dbg_shigh (cdbg_shigh),
        .halt_tog     (gdbg_halt_tog),
        .go_tog       (gdbg_go_tog),
        .step_tog     (gdbg_step_tog),
        .commit_tog   (gdbg_commit_tog),
        .cfg          (gdbg_cfg),
        .bkpt_addr    (gdbg_bkpt),
        .step_count   (gdbg_stepcnt),
        .wpc          (gdbg_wpc),
        .waxys        (gdbg_waxys),
        .wpsh         (gdbg_wpsh),
        .dbg_wr       (idbg_wr),
        .dbg_wpc      (idbg_wpc),
        .dbg_wa       (idbg_wa), .dbg_wx (idbg_wx), .dbg_wy (idbg_wy),
        .dbg_ws       (idbg_ws), .dbg_wp (idbg_wp), .dbg_wshigh (idbg_wshigh),
        .core_run     (dbg_core_run),
        .stat         (sdbg_stat),
        .snap_pc      (sdbg_pc),
        .snap_axys    (sdbg_axys),
        .snap_psh     (sdbg_psh),
        .icnt         (sdbg_icnt),
        .trc_ctrl     (gdbg_trc_ctrl),
        .trc_idx      (gdbg_trc_idx),
        .trc_wptr_stat(sdbg_trc_wptr),
        .trc_pc       (sdbg_trc_pc),
        .trc_axys     (sdbg_trc_axys),
        .trc_p        (sdbg_trc_p)
    );

    // ROM-init wires (driven by sally_rom_loader when USE_PS_BD is set;
    // tied to 0 below in the OOC stub path).  Both branches need the
    // declaration so sally_mem sees the same nets either way.
    wire [15:0] rom_load_addr;
    wire  [7:0] rom_load_data;
    wire        rom_load_we;

    `ifndef USE_PS_BD
    assign rom_load_addr = 16'h0000;
    assign rom_load_data = 8'h00;
    assign rom_load_we   = 1'b0;
    `endif

    // ---- sally_mem -------------------------------------------------------
    sally_mem #(
        .OS_ROM_HEX_PATH ("rsrc/sally-boot.hex"),
        .SELFTEST_HEX_PATH ("rsrc/selftest.hex"),  // XL self-test ROM ($5000-$57FF via PORTB[7])
        .DDR3_BANKED_BASE (32'h2000_0000),
        .DDR3_DATA_BASE   (32'h2040_0000),
        // LINE (banked_axi_reader, shallow) not PAGE (banked_page_cache, deep): the
        // page cache's read path blew clk_sally -0.495 in SALLY's 1-cycle mem loop.
        // LINE makes code/data DDR banking functional at a closeable fmax (trades the
        // page cache's residency/write-back for per-line demand reads).
        .BANKED_CACHE     ("LINE")
    ) u_sally_mem (
        .clk        (clk_sally),
        .rst        (rst_sally),
        .addr       (cpu_addr),
        .data_in    (cpu_dout),
        .rw         (cpu_rw),
        .data_out   (cpu_din),
        .rdy        (sally_rdy),
        .stack_op   (cpu_stack_op),
        .s_high     (cpu_s_high),
        .busy       (mem_busy_n),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (cpu_code_bank),
        .cpu_data_bank_q    (cpu_data_bank),
        .scrn_cpu_bank_q    (scrn_cpu_bank),
        .scrn_antic_bank_q  (scrn_antic_bank),
        .scrn_cpu_bank_we   (scrn_cpu_bank_we),
        .scrn_antic_bank_we (scrn_antic_bank_we),
        .scrn_bank_wval     (scrn_bank_wval),
        .scrn_ready         (scrn_ready),
        .scrn_cpu_addr      (scrn_cpu_addr),
        .scrn_cpu_we        (scrn_cpu_we),
        .scrn_cpu_wdata     (scrn_cpu_wdata),
        .scrn_cpu_rdata     (scrn_cpu_rdata),
        .math_map_q         (math_map),
        .math_chunk_q       (),                  // engine takes the write value directly
        .math_exec_we       (math_exec_we),
        .math_chunk_we      (math_chunk_we),
        .math_done          (math_done),
        .math_busy          (math_busy),
        .math_chunk_ready   (math_chunk_ready),
        .math_cpu_we        (math_cpu_we),
        .math_cpu_rdata     (math_cpu_rdata),
        .unlock_bank        (xt_unlock[UNLK_BANK]),
        .portb              (portb_q),
        .bus_mpd_n_in       (1'b1),         // no PBI
        .bus_pbi_rdata      (8'hFF),        // no PBI
        .bus_rd4_n_in       (1'b1),         // no cart
        .bus_rd5_n_in       (1'b1),         // no cart
        .m_axi_araddr       (axi_araddr),
        .m_axi_arlen        (axi_arlen),
        .m_axi_arsize       (axi_arsize),
        .m_axi_arburst      (axi_arburst),
        .m_axi_arvalid      (axi_arvalid),
        .m_axi_arready      (axi_arready),
        .m_axi_rdata        (axi_rdata),
        .m_axi_rvalid       (axi_rvalid),
        .m_axi_rlast        (axi_rlast),
        .m_axi_rready       (axi_rready),
        .m_axi_awaddr       (axi_awaddr),
        .m_axi_awlen        (axi_awlen),
        .m_axi_awsize       (axi_awsize),
        .m_axi_awburst      (axi_awburst),
        .m_axi_awvalid      (axi_awvalid),
        .m_axi_awready      (axi_awready),
        .m_axi_wdata        (axi_wdata),
        .m_axi_wstrb        (axi_wstrb),
        .m_axi_wlast        (axi_wlast),
        .m_axi_wvalid       (axi_wvalid),
        .m_axi_wready       (axi_wready),
        .m_axi_bvalid       (axi_bvalid),
        .m_axi_bready       (axi_bready),
        .rom_addr    (rom_load_addr),
        .rom_data    (rom_load_data),
        .rom_we      (rom_load_we),
        .dma_clk     (clk_sys),       // ANTIC reads sally_mem's BRAM at clk_bus
        .dma_addr    (antic_bram_addr),
        .dma_rdata   (scrn_shadow_rdata)   // muxed with screen_bank ANTIC-BRAM above
    );

    // ====================================================================
    // CDC: register writes SALLY (clk_sally) → ANTIC (clk_sys)
    // ====================================================================
    // SALLY's hwreg_we pulse pushes {hwreg_addr, hwreg_din} into a 4-deep
    // async FIFO.  ANTIC drains it on clk_sys and regenerates a 1-cycle
    // bus write strobe with d0xx_n / d4xx_n decoded.
    //
    // Register-write cadence is bounded by phi2 (~1.5 MHz) and the FIFO
    // drains at clk_sys (133 MHz), so wr_full never asserts in practice.
    // We deliberately ignore it — a half-full warning would be the place
    // to add observability later if this assumption ever breaks.

    // hwreg READ classification (clk_sally).  $D000-$D7FF read, minus the
    // blitter register window $D4B0-$D4CF (served locally in hwreg_dout).
    wire        hwreg_page_rd  = (cpu_addr[15:11] == 5'b11010) & cpu_rw;
    wire        is_blitter_reg = (cpu_addr[15:8] == 8'hD4)
                               & (cpu_addr[7:4] == 4'hB || cpu_addr[7:4] == 4'hC);
    // xtc bank-control regs $D5C0/$D5C1 (sally_mem XTC_CTL_BASE) are served
    // locally by sally_mem's read mux — keep them off the ANTIC read CDC so the
    // read-back is a single cycle (no round-trip / no stall).
    wire        is_xtc_ctl     = (cpu_addr[15:1] == 15'h6AE0);   // $D5C0-$D5C1
    wire        hwreg_cdc_rd   = hwreg_page_rd & ~is_blitter_reg & ~is_xtc_ctl;

    wire        hwreg_wr_full_unused;
    wire        hwreg_rd_empty;
    wire [23:0] hwreg_rd_data;
    // Pause the write-FIFO drain while the CDC owns the bus for a read.
    wire        hwreg_rd_en = ~hwreg_rd_empty & ~cdc_bus_read;

    cdc_fifo_1w1r #(.DATA_W(24), .ADDR_W(2)) u_hwreg_cdc (
        .src_clk  (clk_sally),
        .src_rst  (rst_sally),
        .wr_en    (hwreg_we),
        .wr_data  ({hwreg_addr, hwreg_din}),
        .wr_full  (hwreg_wr_full_unused),
        .dst_clk  (clk_sys),
        .dst_rst  (rst_sys),
        .rd_en    (hwreg_rd_en),
        .rd_data  (hwreg_rd_data),
        .rd_empty (hwreg_rd_empty)
    );

    // Generate 1-cycle write strobe on clk_sys.  rd_en pulses high whenever
    // the FIFO is non-empty; we capture the popped descriptor and present
    // it (with bus_rw low) to antic_top for one clk_sys cycle.
    logic        antic_we_q;
    logic [15:0] bus_addr_antic_q;
    logic [7:0]  bus_data_in_antic_q;
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            antic_we_q          <= 1'b0;
            bus_addr_antic_q    <= 16'h0000;
            bus_data_in_antic_q <= 8'h00;
        end else begin
            antic_we_q          <= hwreg_rd_en;
            bus_addr_antic_q    <= hwreg_rd_data[23:8];
            bus_data_in_antic_q <= hwreg_rd_data[7:0];
        end
    end

    // The CDC read transaction overrides the bus when servicing a SALLY
    // hwreg read (cdc_bus_read); otherwise the write-FIFO drain drives it.
    wire [15:0] bus_addr_antic    = cdc_bus_read ? cdc_bus_addr : bus_addr_antic_q;
    wire [7:0]  bus_data_in_antic = bus_data_in_antic_q;
    wire        bus_rw_antic      = cdc_bus_read ? 1'b1 : ~antic_we_q;
    wire        d0xx_n_antic = cdc_bus_read
                             ? ~(cdc_bus_addr[15:8] == 8'hD0)
                             : ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD0));
    wire        d4xx_n_antic = cdc_bus_read
                             ? ~(cdc_bus_addr[15:8] == 8'hD4)
                             : ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD4));

    // ---- Register read-back CDC bridge (boot blocker #3) ----------------
    // SALLY hwreg reads cross to clk_sys, get presented to ANTIC's
    // combinational read mux, and the byte crosses back.  bus_idle gates
    // the read start so a draining register write can't collide on the bus.
    wire        hwreg_bus_idle = hwreg_rd_empty & ~antic_we_q;
    hwreg_rd_cdc u_hwreg_rd_cdc (
        .clk_sally (clk_sally),
        .rst_sally (rst_sally),
        .rd_req    (hwreg_cdc_rd),
        .rd_addr   (cpu_addr),
        .rd_busy   (hwreg_rd_busy),
        .rd_data   (cdc_rd_data),
        .clk_sys   (clk_sys),
        .rst_sys   (rst_sys),
        .bus_idle  (hwreg_bus_idle),
        .bus_addr  (cdc_bus_addr),
        .bus_read  (cdc_bus_read),
        .bus_rdata (antic_rdata_int)   // ANTIC's UNGATED internal read mux —
                                       // NOT bus_data_out, which is gated by
                                       // ext_bus_active (off for the internal
                                       // CPU at turbo) and would feed back $00.
    );

    // ====================================================================
    // CDC: status signals ANTIC → SALLY
    // ====================================================================
    wire nmi_n_antic, irq_n_antic, halt_n_antic, rdy_n_antic;
    wire nmi_n_sync, irq_n_sync;

    // cdc-lint: independent-bits — nmi_n/irq_n are separate level lines, each
    // sampled on its own 2-FF pair; no multi-bit value, so no torn-carry hazard.
    cdc_sync_bit #(.WIDTH(2)) u_sync_irq_nmi (
        .dst_clk (clk_sally),
        .src_sig ({nmi_n_antic, irq_n_antic}),
        .dst_sig ({nmi_n_sync,   irq_n_sync})
    );

    // halt_n from ANTIC: at CLOCK_MULT>=2, sally_clock bypasses it.
    // We keep it wired for the CLOCK_MULT=1 fallback path, but never
    // gate on it at our operating point.
    cdc_sync_bit #(.WIDTH(1)) u_sync_halt (
        .dst_clk (clk_sally),
        .src_sig (halt_n_antic),
        .dst_sig (halt_n_sally)
    );

    // Cycle-exact ANTIC DMA cycle-steal (antic_top, clk_sys) -> clk_sally.  The
    // steal envelope is stable for a whole machine cycle (~one phi2 = ~56
    // clk_sally cycles), so a 2-FF sync samples it cleanly; the CPU steps once
    // per machine cycle and WSYNC re-aligns CPU<->ANTIC each scanline, so the
    // ~1% phi2 drift between the two clocks stays bounded within a line.
    cdc_sync_bit #(.WIDTH(1)) u_sync_dma_steal (
        .dst_clk (clk_sally),
        .src_sig (antic_dma_steal_w),
        .dst_sig (dma_steal_sally)
    );

    // ====================================================================
    // ANTIC pipeline (runs on clk_sys / same clock for Phase 1a)
    // ====================================================================
    // ANTIC reads display data from sally_mem's second BRAM port via
    // bram_shim.  SALLY writes to main memory propagate to the shim via
    // snoop_we_screen inside antic_top.
    wire [7:0]  antic_bus_data_out;
    wire        antic_bus_data_oe;
    wire [7:0]  antic_rdata_int;   // ANTIC's UNGATED read mux for the internal CPU's
                                   // hwreg read-back CDC (bus_data_out is ext-bus-gated)
    wire        antic_nmi_n, antic_halt_n, antic_rdy_n, antic_irq_n;

    // ANTIC-side phi2 — antic_top generates its own phi2 internally from
    // clk_bus (= clk_sys); we only consume its phi2_tick strobe.  phi2 =
    // clk_bus / BASE_DIV, where BASE_DIV is a fixed localparam = 74 inside
    // antic_top (not overridable from here): at clk_sys = 133.3 MHz that is
    // ≈ 1.80 MHz ≈ real NTSC phi2.  Independent of sally_clock's BASE_DIV —
    // the two divide different clocks (ANTIC divides clk_sys, sally_clock
    // divides clk_sally), so the values differ by design.

    // antic_top has no RGB/TMDS outputs; the HDMI pads are driven by the
    // compositor → sprite chain, and the ANTIC image reaches
    // the screen via the §5 writeback tap below.

    // ANTIC render tap → DDR3 writeback (video-arch §5, phase 2). All clk_sys
    // (= antic_top's clk_bus). Feeds antic_writeback (instantiated below) on
    // HP3; xl_buffer_ctrl picks which XL slot it fills and which plane 1 reads.

    // ---- DDR startup gate (cold-boot robustness) ------------------------
    // On a cold SD boot the PL runs before the PS↔PL DDR path is fully up.
    // plane_fetch reads time out but RECOVER (they have a watchdog); the
    // writeback's axi_line_writer has NO watchdog, so its first write burst
    // waits forever for a BVALID the HP2 path can't yet give and WEDGES (HW:
    // hp2_wbeat stuck at 16, ANTIC frames still climbing) → the XL buffer never
    // fills → permanent garbage (a JTAG reconfig clears it because it restarts
    // warm).  Hold off ALL PL→DDR traffic (writeback flush + both plane reads)
    // for ~224 ms after reset so the first access happens once DDR/AXI is up.
    logic [24:0] ddr_warm_cnt = '0;
    logic        ddr_warm     = 1'b0;     // 0 for ~224 ms (clk_sys 150 MHz), then 1
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            ddr_warm_cnt <= '0;
            ddr_warm     <= 1'b0;
        end else if (!ddr_warm) begin
            if (&ddr_warm_cnt) ddr_warm <= 1'b1;
            else               ddr_warm_cnt <= ddr_warm_cnt + 1'b1;
        end
    end

    wire        antic_wb_pix_valid;
    wire [7:0]  antic_wb_pix_pair;
    wire [7:0]  antic_wb_color_lo, antic_wb_color_hi;
    wire [7:0]  antic_wb_atari_row;
    wire        antic_wb_row_flush, antic_wb_frame_done;
    wire        antic_wb_pal_we;
    wire [7:0]  antic_wb_pal_idx;
    wire [23:0] antic_wb_pal_rgb;

    antic_top #(
        .POKEY_CLK_BUS_HZ (150_000_000)     // clk_sys nominal (150 MHz)
    ) u_antic_top (
        .clk_bus            (clk_sys),
        .rst_n              (rst_sys_n),
        .sally_cold         (sallyrst[0]),      // cold-boot: power-on-clear NMIEN/DMACTL
        .bus_addr           (bus_addr_antic),
        .bus_data_in        (bus_data_in_antic),
        .bus_rw             (bus_rw_antic),
        .d0xx_n             (d0xx_n_antic),
        .d4xx_n             (d4xx_n_antic),
        .bus_data_out       (antic_bus_data_out),
        .bus_data_oe        (antic_bus_data_oe),
        .bus_rdata_int      (antic_rdata_int),   // ungated read mux for hwreg_rd_cdc

        .nmi_n              (antic_nmi_n),
        .halt_n             (antic_halt_n),
        .rdy_n              (antic_rdy_n),
        .dma_steal          (antic_dma_steal_w),
        .dmactl_honor       (gp0_ctrl[4]),    // PS opt-in: honour DMACTL screen-blank
        .unlock_antic       (xt_unlock[UNLK_ANTIC]),  // mirror-conditional $D4xx decode:
        .unlock_sprite      (xt_unlock[UNLK_SPRITE]), //   each $D4xx slice mirrors stock
        .unlock_blit        (xt_unlock[UNLK_BLIT]),   //   under its OWN group's lock
        .irq_n              (antic_irq_n),
        .bus_pbi_in_status_o(),
        .audio_l0(), .audio_l1(), .audio_l2(), .audio_l3(),
        .audio_r0(), .audio_r1(), .audio_r2(), .audio_r3(),
        .audio_present(), .audio_flat(), .audio_block_start(),
        .audio_frame_ready(),
        .dma_addr_o         (),
        .dma_rw_o           (),
        .dma_oe             (),
        .diag_wsync_overdue_count(),
        .kbd_event_valid    (kbd_event_valid_q),
        .kbd_event_code     (kbd_event_code_q),
        .kbd_release        (kbd_release_q),
        .kbd_break_pulse    (break_pulse_q),
        .spi_clk            (),
        .spi_mosi           (),
        .spi_miso           (1'b0),
        .spi_cs_n           (),
        .spi_irq            (1'b1),
        .joy_spi_clk        (),
        .joy_spi_mosi       (),
        .joy_spi_miso       (1'b0),
        .joy_spi_cs_n       (),
        .joy_spi_int_n      (1'b1),
        // ANTIC's BRAM read port — connects to sally_mem's dma port.
        .bram_addr          (antic_bram_addr),
        .bram_rdata         (antic_bram_rdata),
        // PORTB state — consumed by sally_mem for ROM vs RAM control.
        .portb_q            (portb_q),
        // ANTIC render tap → DDR3 writeback (HP3, see antic_writeback below).
        .wb_pix_valid       (antic_wb_pix_valid),
        .wb_pix_pair        (antic_wb_pix_pair),
        .wb_color_lo        (antic_wb_color_lo),
        .wb_color_hi        (antic_wb_color_hi),
        .wb_atari_row       (antic_wb_atari_row),
        .wb_row_flush       (antic_wb_row_flush),
        .wb_frame_done      (antic_wb_frame_done),
        .wb_pal_we          (antic_wb_pal_we),
        .wb_pal_idx         (antic_wb_pal_idx),
        .wb_pal_rgb         (antic_wb_pal_rgb),
        // Zynq build: sally_* / xlat_phys_addr removed (no shadow SALLY core).
        .adc_bclk_o         (),
        .adc_lrck_o         (),
        .adc_sdata_i        (1'b0),
        .bus_addr_o         (),
        .bus_rw_o           (),
        .bus_d0xx_n_o       (),
        .bus_d4xx_n_o       (),
        .bus_d1xx_n_o       (),
        .bus_s4_n_o         (),
        .bus_s5_n_o         (),
        .bus_cctl_n_o       (),
        .bus_extenb_n_o     (),
        .phi2_o             (),
        .bus_mpd_n_in       (1'b1),
        .bus_extirq_n_in    (1'b1),
        .bus_rd4_in         (1'b1),
        .bus_rd5_in         (1'b1)
    );

    // Status signals back to SALLY
    assign nmi_n_antic = antic_nmi_n;
    assign irq_n_antic = antic_irq_n;
    assign halt_n_antic = antic_halt_n;
    assign wsync_rdy_n = antic_rdy_n;

    // ====================================================================
    // ANTIC → DDR3 writeback (the XL plane source) — video-arch §5, phase 2
    // ====================================================================
    // Palette-resolves ANTIC's render tap to RGBA8888, accumulates a scanline,
    // and DMAs it to a TRIPLE-buffered DDR3 XL surface over HP3.  xl_buffer_ctrl
    // (below) owns the rotation: the writeback fills write_idx; the compositor
    // reads display_idx, adopted at the scan-out vblank.  Producer (ANTIC, clk_sys)
    // and consumer (clk_pix) are fully decoupled — no mid-frame swap, no reading a
    // buffer being written — so the ~1 Hz tear and the moving ghost lines are gone.
    //
    // XL surface geometry — three buffers (spec §5), RGBA8888.  The native
    // playfield is the nominal 320×192 GR.0 region (atari_row spans 0..191 from
    // the phi2 raster timer; the active playfield is 320 px = 160 column-pairs).
    localparam [31:0] XL_BASE_0  = 32'h3100_0000;   // triple-buffer slots, 1 MB apart
    localparam [31:0] XL_BASE_1  = 32'h3110_0000;   //   (≤320×192×4 ≈ 240 KB each)
    localparam [31:0] XL_BASE_2  = 32'h3120_0000;
    localparam int    XL_SRC_W   = 320;             // active playfield width (px)
    localparam int    XL_SRC_H   = 192;             // active playfield height (atari rows)
    localparam int    XL_STRIDE  = XL_SRC_W * 4;    // bytes/row (RGBA8888) = 1280

    wire [1:0] xl_write_idx;     // slot the writeback fills
    wire [1:0] xl_display_idx;   // slot the compositor reads (clk_sys)

    // Triple-buffer rotation + clk_pix-vblank adopt (decouples producer/consumer).
    xl_buffer_ctrl u_xl_buf_ctrl (
        .clk_sys     (clk_sys),
        .rst_sys     (rst_sys),
        .frame_done  (antic_wb_frame_done),   // ANTIC vbi: publish + advance
        .write_idx   (xl_write_idx),
        .display_idx (xl_display_idx),
        .clk_pix     (clk_pix),
        .rst_pix     (rst_pix),
        .disp_vbi    (fb_vbi_start)            // scan-out entered vblank: adopt newest
    );

    // The scan-out palette is baked in via the ANTIC_PALETTE_HEX macro in
    // antic_writeback.sv (Atari NTSC table); $D483-$D486 can override at runtime.
    antic_writeback u_antic_writeback (
        .clk_sys      (clk_sys),
        .rst_sys      (rst_sys),
        // Render tap (clk_sys) from antic_top
        .pix_valid    (antic_wb_pix_valid),
        .pix_pair     (antic_wb_pix_pair),
        .color_lo     (antic_wb_color_lo),
        .color_hi     (antic_wb_color_hi),
        .atari_row    (antic_wb_atari_row),
        .row_flush    (antic_wb_row_flush & ddr_warm),   // held off until DDR/AXI up
        // Palette writes (mirror ANTIC's palette)
        .pal_we       (antic_wb_pal_we),
        .pal_idx      (antic_wb_pal_idx),
        .pal_rgb      (antic_wb_pal_rgb),
        // Config — triple-buffer slot bases + the slot to fill this frame
        .base0        (XL_BASE_0),
        .base1        (XL_BASE_1),
        .base2        (XL_BASE_2),
        .write_idx    (xl_write_idx),
        .stride_bytes (16'(XL_STRIDE)),
        .src_w        (12'(XL_SRC_W)),
        // AXI4 write master → HP2 (moved off HP3 so writeback writes can't
        // stall the XL read sharing that port)
        .m_axi_awaddr (hp2_awaddr),  .m_axi_awlen  (hp2_awlen),
        .m_axi_awsize (hp2_awsize),  .m_axi_awburst(hp2_awburst),
        .m_axi_awvalid(hp2_awvalid), .m_axi_awready(hp2_awready),
        .m_axi_wdata  (hp2_wdata),   .m_axi_wstrb  (hp2_wstrb),
        .m_axi_wlast  (hp2_wlast),   .m_axi_wvalid (hp2_wvalid),
        .m_axi_wready (hp2_wready),
        .m_axi_bvalid (hp2_bvalid),  .m_axi_bready (hp2_bready)
    );

    // Production-chain activity counters (clk_sys) — read via diag2_word at GP0
    // offset 0x18.  On hardware these answer "is the emulator actually running?"
    // without any sim: antic_frame_cnt climbs => 6502+ANTIC are producing frames;
    // hp2_wbeat_cnt climbs => the writeback is genuinely DMA-ing pixels to DDR
    // (writeback writes now go to HP2).
    reg [7:0] antic_frame_cnt = 8'd0;
    reg [7:0] hp2_wbeat_cnt   = 8'd0;
    always_ff @(posedge clk_sys) begin
        if (antic_wb_frame_done)     antic_frame_cnt <= antic_frame_cnt + 8'd1;
        if (hp2_wvalid & hp2_wready) hp2_wbeat_cnt   <= hp2_wbeat_cnt   + 8'd1;
    end
    wire [31:0] diag2_word = {16'd0, hp2_wbeat_cnt, antic_frame_cnt};

    // ====================================================================
    // Banked screen RAM engine (screen_bank).  CPU port = clk_sally (sally_mem);
    // ANTIC port + engine/AXI = clk_sys.  AXI master -> S_AXI_GP0 (PL->PS
    // general-purpose; the copies are ~MB/s + non-latency-critical, so no HP
    // port / no contention with scan-out/blitter).  Chunk-stack @ 0x2080_0000
    // (256 x 8 KB = 2 MB) — the "video banks" slot in the SALLY-banks region
    // (after code-bank @0x2000_0000 + data-bank @0x2040_0000).
    // ====================================================================
    wire [31:0] gp0m_araddr;  wire [3:0] gp0m_arlen;  wire [2:0] gp0m_arsize;
    wire [1:0]  gp0m_arburst; wire gp0m_arvalid, gp0m_arready;
    wire [31:0] gp0m_rdata;   wire gp0m_rvalid, gp0m_rlast, gp0m_rready;
    wire [31:0] gp0m_awaddr;  wire [3:0] gp0m_awlen;  wire [2:0] gp0m_awsize;
    wire [1:0]  gp0m_awburst; wire gp0m_awvalid, gp0m_awready;
    wire [31:0] gp0m_wdata;   wire [3:0] gp0m_wstrb;  wire gp0m_wlast, gp0m_wvalid, gp0m_wready;
    wire        gp0m_bvalid,  gp0m_bready;

    // screen_bank and math_cop share S_AXI_GP0 through gp0_axi_mux (transaction-
    // granular arbitration, math priority — see gp0_axi_mux.sv header).
    wire [31:0] sb_araddr;  wire [3:0] sb_arlen;  wire [2:0] sb_arsize;
    wire [1:0]  sb_arburst; wire sb_arvalid, sb_arready;
    wire [31:0] sb_rdata;   wire sb_rvalid, sb_rlast, sb_rready;
    wire [31:0] sb_awaddr;  wire [3:0] sb_awlen;  wire [2:0] sb_awsize;
    wire [1:0]  sb_awburst; wire sb_awvalid, sb_awready;
    wire [31:0] sb_wdata;   wire [3:0] sb_wstrb;  wire sb_wlast, sb_wvalid, sb_wready;
    wire        sb_bvalid,  sb_bready;
    wire [31:0] mc_araddr;  wire [3:0] mc_arlen;  wire [2:0] mc_arsize;
    wire [1:0]  mc_arburst; wire mc_arvalid, mc_arready;
    wire [31:0] mc_rdata;   wire mc_rvalid, mc_rlast, mc_rready;
    wire [31:0] mc_awaddr;  wire [3:0] mc_awlen;  wire [2:0] mc_awsize;
    wire [1:0]  mc_awburst; wire mc_awvalid, mc_awready;
    wire [31:0] mc_wdata;   wire [3:0] mc_wstrb;  wire mc_wlast, mc_wvalid, mc_wready;
    wire        mc_bvalid,  mc_bready;

    screen_bank #(.STACK_BASE(32'h2080_0000), .APERTURE_LOG2(13)) u_screen_bank (
        .clk          (clk_sys),       .rst        (rst_sys),
        .clk_cpu      (clk_sally),
        .cpu_addr     (scrn_cpu_addr), .cpu_we     (scrn_cpu_we), .cpu_wdata (scrn_cpu_wdata),
        .cpu_rden     (sally_rdy),     .cpu_rdata  (scrn_cpu_rdata),
        .cpu_bank_wval(scrn_bank_wval),.cpu_bank_we(scrn_cpu_bank_we),
        .ready        (scrn_ready),
        .clk_antic    (clk_sys),
        .antic_addr   (antic_bram_addr[12:0]), .antic_rdata (scrn_antic_rdata),
        .antic_bank_wval(scrn_bank_wval), .antic_bank_we (scrn_antic_bank_we),
        .vbi          (antic_wb_frame_done),   .antic_banked (scrn_antic_banked),
        .e_axi_araddr (sb_araddr),  .e_axi_arlen (sb_arlen),  .e_axi_arsize (sb_arsize),
        .e_axi_arburst(sb_arburst), .e_axi_arvalid(sb_arvalid),.e_axi_arready(sb_arready),
        .e_axi_rdata  (sb_rdata),   .e_axi_rvalid(sb_rvalid),  .e_axi_rlast (sb_rlast),
        .e_axi_rready (sb_rready),
        .e_axi_awaddr (sb_awaddr),  .e_axi_awlen (sb_awlen),  .e_axi_awsize (sb_awsize),
        .e_axi_awburst(sb_awburst), .e_axi_awvalid(sb_awvalid),.e_axi_awready(sb_awready),
        .e_axi_wdata  (sb_wdata),   .e_axi_wstrb (sb_wstrb),  .e_axi_wlast (sb_wlast),
        .e_axi_wvalid (sb_wvalid),  .e_axi_wready(sb_wready),
        .e_axi_bvalid (sb_bvalid),  .e_axi_bready(sb_bready)
    );

    // ---- math_cop: resident 8 KB math page + doorbell mailbox --------------
    // GP0-side wires (evt/done/stat) run to xt_gp0_regs (same clk_sys domain).
    // Like the blitter-bridge wires, the A9-driven strobes exist only in PS BD
    // builds; the OOC/sim path ties them off (testbenches drive math_cop's
    // GP0-side ports directly on their own instance).
    wire [8:0]  math_evt_data;
    wire [31:0] math_stat_word;
`ifdef USE_PS_BD
    wire        math_evt_pop;        // driven by u_axi_bridge
    wire [23:0] math_done_word;
    wire        math_done_we;
`else
    wire        math_evt_pop   = 1'b0;
    wire [23:0] math_done_word = 24'd0;
    wire        math_done_we   = 1'b0;
`endif

    math_cop #(.STACK_BASE(32'h2080_0000), .APERTURE_LOG2(13)) u_math_cop (
        .clk          (clk_sys),       .rst        (rst_sys),
        .clk_cpu      (clk_sally),
        .cpu_addr     (scrn_cpu_addr), .cpu_we     (math_cpu_we), .cpu_wdata (scrn_cpu_wdata),
        .cpu_rden     (sally_rdy),     // freeze the page read register while the CPU stalls
        .cpu_rdata    (math_cpu_rdata),
        .exec_we      (math_exec_we),
        .chunk_wval   (scrn_bank_wval), .chunk_we  (math_chunk_we),
        .math_done    (math_done),
        .math_busy    (math_busy),
        .chunk_ready  (math_chunk_ready),
        .evt_data     (math_evt_data),  .evt_pop   (math_evt_pop),
        .evt_irq      (math_irq),
        .done_word    (math_done_word), .done_we   (math_done_we),
        .stat_word    (math_stat_word),
        .e_axi_araddr (mc_araddr),  .e_axi_arlen (mc_arlen),  .e_axi_arsize (mc_arsize),
        .e_axi_arburst(mc_arburst), .e_axi_arvalid(mc_arvalid),.e_axi_arready(mc_arready),
        .e_axi_rdata  (mc_rdata),   .e_axi_rvalid(mc_rvalid),  .e_axi_rlast (mc_rlast),
        .e_axi_rready (mc_rready),
        .e_axi_awaddr (mc_awaddr),  .e_axi_awlen (mc_awlen),  .e_axi_awsize (mc_awsize),
        .e_axi_awburst(mc_awburst), .e_axi_awvalid(mc_awvalid),.e_axi_awready(mc_awready),
        .e_axi_wdata  (mc_wdata),   .e_axi_wstrb (mc_wstrb),  .e_axi_wlast (mc_wlast),
        .e_axi_wvalid (mc_wvalid),  .e_axi_wready(mc_wready),
        .e_axi_bvalid (mc_bvalid),  .e_axi_bready(mc_bready)
    );

    gp0_axi_mux u_gp0_axi_mux (
        .clk        (clk_sys),      .rst        (rst_sys),
        .m0_araddr  (sb_araddr),    .m0_arlen   (sb_arlen),   .m0_arsize (sb_arsize),
        .m0_arburst (sb_arburst),   .m0_arvalid (sb_arvalid), .m0_arready(sb_arready),
        .m0_rdata   (sb_rdata),     .m0_rvalid  (sb_rvalid),  .m0_rlast  (sb_rlast),
        .m0_rready  (sb_rready),
        .m0_awaddr  (sb_awaddr),    .m0_awlen   (sb_awlen),   .m0_awsize (sb_awsize),
        .m0_awburst (sb_awburst),   .m0_awvalid (sb_awvalid), .m0_awready(sb_awready),
        .m0_wdata   (sb_wdata),     .m0_wstrb   (sb_wstrb),   .m0_wlast  (sb_wlast),
        .m0_wvalid  (sb_wvalid),    .m0_wready  (sb_wready),
        .m0_bvalid  (sb_bvalid),    .m0_bready  (sb_bready),
        .m1_araddr  (mc_araddr),    .m1_arlen   (mc_arlen),   .m1_arsize (mc_arsize),
        .m1_arburst (mc_arburst),   .m1_arvalid (mc_arvalid), .m1_arready(mc_arready),
        .m1_rdata   (mc_rdata),     .m1_rvalid  (mc_rvalid),  .m1_rlast  (mc_rlast),
        .m1_rready  (mc_rready),
        .m1_awaddr  (mc_awaddr),    .m1_awlen   (mc_awlen),   .m1_awsize (mc_awsize),
        .m1_awburst (mc_awburst),   .m1_awvalid (mc_awvalid), .m1_awready(mc_awready),
        .m1_wdata   (mc_wdata),     .m1_wstrb   (mc_wstrb),   .m1_wlast  (mc_wlast),
        .m1_wvalid  (mc_wvalid),    .m1_wready  (mc_wready),
        .m1_bvalid  (mc_bvalid),    .m1_bready  (mc_bready),
        .s_araddr   (gp0m_araddr),  .s_arlen    (gp0m_arlen), .s_arsize  (gp0m_arsize),
        .s_arburst  (gp0m_arburst), .s_arvalid  (gp0m_arvalid),.s_arready (gp0m_arready),
        .s_rdata    (gp0m_rdata),   .s_rvalid   (gp0m_rvalid), .s_rlast   (gp0m_rlast),
        .s_rready   (gp0m_rready),
        .s_awaddr   (gp0m_awaddr),  .s_awlen    (gp0m_awlen), .s_awsize  (gp0m_awsize),
        .s_awburst  (gp0m_awburst), .s_awvalid  (gp0m_awvalid),.s_awready (gp0m_awready),
        .s_wdata    (gp0m_wdata),   .s_wstrb    (gp0m_wstrb), .s_wlast   (gp0m_wlast),
        .s_wvalid   (gp0m_wvalid),  .s_wready   (gp0m_wready),
        .s_bvalid   (gp0m_bvalid),  .s_bready   (gp0m_bready)
    );

    // Read-path activity counters (clk_sys) — read via diag3_word at GP0 offset
    // 0x14.  The XL writeback proved PL->DDR *writes* work on silicon; these
    // answer whether plane_fetch's PL->DDR *reads* deliver to the compositor
    // (never validated on HW; both planes scan out black).  Per HP read port:
    //   *_ar_cnt    climbs => plane_fetch issues read bursts (AR handshakes)
    //   *_rbeat_cnt climbs => the PS returns read data (R beats)
    // AR but no R  => PS not servicing reads (HP read channel / address).
    // R but black  => the line-buffer -> pixel (clk_sys->clk_pix) path drops it.
    reg [7:0] hp0_ar_cnt    = 8'd0;   // desktop plane (plane 0)
    reg [7:0] hp0_rbeat_cnt = 8'd0;
    reg [7:0] hp3_ar_cnt    = 8'd0;   // XL plane (plane 1)
    reg [7:0] hp3_rbeat_cnt = 8'd0;
    always_ff @(posedge clk_sys) begin
        if (hp0_arvalid & hp0_arready) hp0_ar_cnt    <= hp0_ar_cnt    + 8'd1;
        if (hp0_rvalid  & hp0_rready)  hp0_rbeat_cnt <= hp0_rbeat_cnt + 8'd1;
        if (hp3_arvalid & hp3_arready) hp3_ar_cnt    <= hp3_ar_cnt    + 8'd1;
        if (hp3_rvalid  & hp3_rready)  hp3_rbeat_cnt <= hp3_rbeat_cnt + 8'd1;
    end
    wire [31:0] diag3_word = {hp0_ar_cnt, hp0_rbeat_cnt, hp3_ar_cnt, hp3_rbeat_cnt};

    // First-AR address latch (sticky) — read via diag4/diag5 @ GP0 0x10/0x0C.
    // Confirms plane_fetch drives a SANE read address on silicon (rules out a
    // startup-race garbage AR): HP3(XL) should be ~0x3100_xxxx/0x3110_xxxx,
    // HP0(desktop) ~0x3000_xxxx.  Since reads currently hang after one AR, this
    // captures the only AR each port ever issued.
    reg [31:0] hp3_first_araddr = 32'd0;  reg hp3_ar_seen = 1'b0;
    reg [31:0] hp0_first_araddr = 32'd0;  reg hp0_ar_seen = 1'b0;
    always_ff @(posedge clk_sys) begin
        if (hp3_arvalid & hp3_arready & ~hp3_ar_seen) begin
            hp3_first_araddr <= hp3_araddr; hp3_ar_seen <= 1'b1;
        end
        if (hp0_arvalid & hp0_arready & ~hp0_ar_seen) begin
            hp0_first_araddr <= hp0_araddr; hp0_ar_seen <= 1'b1;
        end
    end
    wire [31:0] diag4_word = hp3_first_araddr;   // XL plane first read address
    wire [31:0] diag5_word = hp0_first_araddr;   // desktop plane first read address

    // ---- plane_fetch read-abort counters (clk_sys) — diag6/7 @ GP0 0x04/0x08 -
    // The HP2 bring-up read-probe is retired (PL->DDR reads proven by the live
    // display).  Its diag slots now count plane_fetch watchdog aborts: a read
    // that times out (DDR-port contention) abandons a line and shows stale data
    // — the beat-correlated ghost line / text glitch.  Moving the writeback off
    // HP3 (to HP2) should drive these to ZERO in steady state; if they keep
    // climbing, contention persists and the abort needs draining.
    //   diag6 @0x04: {xl_abort_cnt[15:0], desk_abort_cnt[15:0]}
    //   diag7 @0x08: {desk_overrun_cnt[15:0], xl_overrun_cnt[15:0]}
    // After the HP3 split + ping-pong hardening + plane_fetch AR-pipelining, all
    // of these should stay 0 in steady state.  desk_overrun_cnt climbing was the
    // desktop-plane tearing (serial fetch couldn't fill a row per scanline);
    // the pipelined plane_fetch should hold it at 0.
    wire xl_read_abort, hp0_read_abort, xl_overrun, hp0_overrun;
    reg [15:0] xl_abort_cnt = 16'd0, desk_abort_cnt = 16'd0;
    reg [15:0] desk_overrun_cnt = 16'd0;
    reg [15:0] xl_overrun_cnt = 16'd0;
    always_ff @(posedge clk_sys) begin
        if (xl_read_abort)  xl_abort_cnt     <= xl_abort_cnt + 16'd1;
        if (hp0_read_abort) desk_abort_cnt   <= desk_abort_cnt + 16'd1;
        if (xl_overrun)     xl_overrun_cnt   <= xl_overrun_cnt + 16'd1;
        if (hp0_overrun)    desk_overrun_cnt <= desk_overrun_cnt + 16'd1;
    end
    wire [31:0] diag6_word = {xl_abort_cnt, desk_abort_cnt};
    wire [31:0] diag7_word = {desk_overrun_cnt, xl_overrun_cnt};

    // ---- ROM-window upload diagnostic (TEMP, localises the dead-upload bug) --
    // The upload logic is sim-clean (tb_rom_integ) but the board's 6502 never
    // sees the patched OS.  Count where it breaks on silicon:
    //   romdiag_axi  (clk_sys)   = window AWs the loader ACCEPTED
    //   romdiag_we   (clk_sally) = rom_we pulses the loader EMITTED to sally_mem
    // axi>0 & we=0 -> loader gets AXI but never drains rom_we (FIFO on silicon).
    // axi=0        -> the PS write never reaches the loader (decode/delivery).
    wire [31:0] diag8_word, diag9_word;
`ifdef USE_PS_BD
    (* keep = "true" *) reg [15:0] romdiag_we   = 16'd0;
    (* keep = "true" *) reg [15:0] romdiag_addr = 16'd0;
    (* keep = "true" *) reg  [7:0] romdiag_data = 8'd0;
    always_ff @(posedge clk_sally) if (rom_load_we) begin
        romdiag_we   <= romdiag_we + 16'd1;
        romdiag_addr <= rom_load_addr;
        romdiag_data <= rom_load_data;
    end
    (* keep = "true" *) reg [15:0] romdiag_axi = 16'd0;
    always_ff @(posedge clk_sys) if (gp0_awvalid && rom_awready)
        romdiag_axi <= romdiag_axi + 16'd1;
    // static after an upload; plain 2-FF sync of the clk_sally fields is fine here
    (* ASYNC_REG = "TRUE" *) reg [15:0] we_s0, we_s1, ad_s0, ad_s1;
    (* ASYNC_REG = "TRUE" *) reg  [7:0] da_s0, da_s1;
    always_ff @(posedge clk_sys) begin
        we_s0 <= romdiag_we;   we_s1 <= we_s0;
        ad_s0 <= romdiag_addr; ad_s1 <= ad_s0;
        da_s0 <= romdiag_data; da_s1 <= da_s0;
    end
    assign diag8_word = {romdiag_axi, we_s1};                 // [31:16]=AXI accepts, [15:0]=rom_we
    assign diag9_word = {8'd0, ad_s1, da_s1};                 // [23:8]=last addr, [7:0]=last data
`else
    assign diag8_word = 32'd0;
    assign diag9_word = 32'd0;
`endif

    // ====================================================================
    // Display: plane compositor (vbeam + plane_fetch x N + plane_compositor)
    // ====================================================================
    // The 1080p60 desktop compositor (docs/video/video-architecture.md). vbeam owns
    // the raster; each plane_fetch streams a DDR3 surface line into a ping-
    // pong line buffer; plane_compositor mixes the planes by depth/scale/clip.
    // Default config = one full-screen desktop plane; the Atari XL becomes
    // plane 1 once the ANTIC->DDR3 writeback (phase 2) feeds it.
    // sprite_engine overlays before the pads.

    // Video path (docs/video/video-architecture.md): vbeam (raster) + per-plane
    // plane_fetch (DDR3 line read) + plane_compositor (depth/scale/clip
    // mixer).  Default config = ONE full-screen desktop plane (scale 1,
    // depth 0).  Plane 1 (the Atari XL window) is wired but DISABLED until
    // the ANTIC->DDR3 writeback (phase 2) feeds it.
    // desktop (depth 0) + drag overlay (depth 1) + XL window (depth 2).
    localparam int CMP_PLANES = 3;

    // ---- vbeam: 1080p60 raster (clk_pix) --------------------------------
    wire [11:0] fb_h_count, fb_v_count;
    wire        vb_de, vb_hsync, vb_vsync;
    wire        fb_line_start, fb_line_start_e, fb_frame_start, fb_vbi_start;

    vbeam #(
        .H_ACTIVE (1920), .H_FRONT_PORCH (88), .H_SYNC_WIDTH (44), .H_BACK_PORCH (148),
        .V_ACTIVE (1080), .V_FRONT_PORCH (4),  .V_SYNC_WIDTH (5),  .V_BACK_PORCH (36),
        .ANTIC_LINES_NATIVE (1080),
        .HSYNC_ACTIVE_LOW (1'b0), .VSYNC_ACTIVE_LOW (1'b0)
    ) u_vbeam (
        .clk_pix (clk_pix), .rst (rst_pix),
        .h_count (fb_h_count), .v_count (fb_v_count),
        .in_active (), .h_active (), .v_active (),
        .hsync (vb_hsync), .vsync (vb_vsync), .de (vb_de),
        .line_start (fb_line_start), .line_start_e (fb_line_start_e), .frame_start (fb_frame_start),
        .vbi_start (fb_vbi_start), .atari_row (), .vcount ()
    );

    // vbeam frame heartbeat toggle (read via diag_word[31:24]) — toggles once
    // per frame, so it ONLY moves if vbeam is actually advancing.  Lets the PS
    // distinguish "clk_pix toggling" from "vbeam producing real frames".
    always_ff @(posedge clk_pix) if (fb_frame_start) fb_frame_tgl <= ~fb_frame_tgl;

    // ---- Frame-aligned plane_fetch arm (cold-boot scan-out determinism) -
    // ddr_warm (clk_sys) says the DDR/AXI path is up.  But just flipping
    // plane_fetch.enable on mid-frame leaves its ping-pong/prefetch pipeline at
    // whatever phase the cold-boot clk_pix↔clk_sys lock landed on — a one-row
    // scan-out offset + a tear that VARY per cold boot.  Instead, hold
    // plane_fetch in reset through warm-up and RELEASE it at a frame boundary,
    // so its pipeline starts frame-aligned and identical every boot.
    wire ddr_warm_pix;
    cdc_sync_bit u_ddrwarm_pix (.dst_clk (clk_pix), .src_sig (ddr_warm), .dst_sig (ddr_warm_pix));
    logic pf_armed = 1'b0;
    always_ff @(posedge clk_pix or posedge rst_pix) begin
        if (rst_pix)                              pf_armed <= 1'b0;
        else if (ddr_warm_pix && fb_frame_start)  pf_armed <= 1'b1;   // arm at frame top
    end
    wire pf_armed_sys;
    cdc_sync_bit u_pfarmed_sys (.dst_clk (clk_sys), .src_sig (pf_armed), .dst_sig (pf_armed_sys));
    wire pf_rst_pix = rst_pix | ~pf_armed;       // held in reset until armed
    wire pf_rst_sys = rst_sys | ~pf_armed_sys;

    // ---- Desktop plane fetch (plane 0): full-screen DDR3 read via HP0 ----
    // fetch_row = next display line (scale 1 => src_row == line); plane_fetch
    // prefetches it during the current line.
    wire [11:0] desk_fetch_row = (fb_v_count >= 12'd1079) ? 12'd0
                                                          : (fb_v_count + 12'd1);
    wire [CMP_PLANES*12-1:0] cmp_src_col, cmp_src_row, cmp_src_row_next;
    wire [31:0]              desk_pixel;

    plane_fetch u_plane_fetch0 (
        .clk_sys (clk_sys), .rst_sys (pf_rst_sys), .enable (1'b1),
        .surface_base (32'h3000_0000), .stride_bytes (16'd8192), .src_w (12'd1920),
        .m_axi_araddr (hp0_araddr), .m_axi_arlen (hp0_arlen), .m_axi_arsize (hp0_arsize),
        .m_axi_arburst (hp0_arburst), .m_axi_arvalid (hp0_arvalid),
        .m_axi_arready (hp0_arready), .m_axi_rdata (hp0_rdata),
        .m_axi_rvalid (hp0_rvalid), .m_axi_rlast (hp0_rlast), .m_axi_rready (hp0_rready),
        .clk_pix (clk_pix), .rst_pix (pf_rst_pix),
        .line_start (fb_line_start), .line_start_e (fb_line_start_e), .fetch_row (desk_fetch_row),
        .rd_col (cmp_src_col[0*12 +: 12]), .rd_pixel (desk_pixel),
        .read_abort (hp0_read_abort), .fetch_overrun (hp0_overrun)
    );

    // ---- XL plane (plane 1): scaled, centred window over the desktop ----
    // Window geometry (video-arch §4/§7): integer scale, centred on 1920×1080.
    // clip rect = window rect for v1.  Tunable on hardware; scale 3 gives a
    // 960×576 window with a clear desktop border.
    localparam int XL_SCALE    = 3;
    localparam int XL_WIN_W    = XL_SRC_W * XL_SCALE;          // 960
    localparam int XL_WIN_H    = XL_SRC_H * XL_SCALE;          // 576
    localparam int XL_ORIGIN_X = (1920 - XL_WIN_W) / 2;        // 480
    localparam int XL_ORIGIN_Y = (1080 - XL_WIN_H) / 2;        // 252
    localparam int XL_CLIP_X0  = XL_ORIGIN_X;                  // 480
    localparam int XL_CLIP_X1  = XL_ORIGIN_X + XL_WIN_W;       // 1440
    localparam int XL_CLIP_Y0  = XL_ORIGIN_Y;                  // 252
    localparam int XL_CLIP_Y1  = XL_ORIGIN_Y + XL_WIN_H;       // 828

    // ---- Runtime XL scale (diagnostic; gp0_ctrl[3:1], "PS does config") --
    // The XL plane scale is normally XL_SCALE (3) but is runtime-overridable
    // from the PS REPL (`scale <n>`) so the scale<->blend-offset correlation
    // can be probed live: an intermittent wrong-row scan-out fetch shows as
    // exactly `scale` output lines of offset, so if the observed READY blend
    // moves by `scale` lines as scale is swept, that IS the mechanism (and if
    // it stays fixed in output-line space, it is not).  gp0_ctrl[3:1] picks
    // the scale; 0 keeps the XL_SCALE default (so legacy 0x00/0x01 ctrl
    // writes — incl. `bars 0|1` — are unchanged).  The window is re-centred
    // for the chosen scale on BOTH axes (pl_scale is isotropic) so the
    // geometry stays valid; clamped to 5 (192*6 = 1152 > 1080).
    wire [2:0] xl_scale_sel = gp0_ctrl[3:1];
    (* ASYNC_REG = "TRUE" *) reg [2:0] xl_scale_s0  = 3'(XL_SCALE);
    (* ASYNC_REG = "TRUE" *) reg [2:0] xl_scale_pix = 3'(XL_SCALE);
    always_ff @(posedge clk_pix) begin
        xl_scale_s0  <= (xl_scale_sel == 3'd0) ? 3'(XL_SCALE) : xl_scale_sel;
        xl_scale_pix <= xl_scale_s0;
    end
    // Geometry is REGISTERED (changes only on a REPL `scale` write) so the
    // compositor sees quasi-static clip/origin inputs — the multiply+subtract
    // sits between register stages, never on a per-pixel comparator path, so
    // clk_pix timing is identical to the old constant case.
    wire [2:0]  xl_scale_c = (xl_scale_pix > 3'd5) ? 3'd5 :
                             (xl_scale_pix < 3'd1) ? 3'd1 : xl_scale_pix;
    wire [11:0] xl_win_w_c = 12'(XL_SRC_W * int'(xl_scale_c));     // 320*s
    wire [11:0] xl_win_h_c = 12'(XL_SRC_H * int'(xl_scale_c));     // 192*s
    wire [11:0] xl_org_x_c = (12'd1920 - xl_win_w_c) >> 1;
    wire [11:0] xl_org_y_c = (12'd1080 - xl_win_h_c) >> 1;
    reg  [2:0]  xl_scale_q = 3'(XL_SCALE);
    reg  [11:0] xl_org_x_r = 12'(XL_ORIGIN_X), xl_org_y_r = 12'(XL_ORIGIN_Y);
    reg  [11:0] xl_clx1_r  = 12'(XL_CLIP_X1),  xl_cly1_r  = 12'(XL_CLIP_Y1);
    always_ff @(posedge clk_pix) begin
        if (xl_win_en_p) begin
            // A9-positioned emulation window: origin/scale/clip from the GP0 rect.
            xl_scale_q <= (xl_win_scale_p == 3'd0) ? 3'd1 : xl_win_scale_p;
            xl_org_x_r <= xl_win_x_p;
            xl_org_y_r <= xl_win_y_p;
            xl_clx1_r  <= xl_win_x_p + xl_win_w_p;
            xl_cly1_r  <= xl_win_y_p + xl_win_h_p;
        end else begin
            // Legacy: gp0_ctrl-scale, centred (pillarbox).
            xl_scale_q <= xl_scale_c;
            xl_org_x_r <= xl_org_x_c;
            xl_org_y_r <= xl_org_y_c;
            xl_clx1_r  <= xl_org_x_c + xl_win_w_c;
            xl_cly1_r  <= xl_org_y_c + xl_win_h_c;
        end
    end

    // Scaled vertical prefetch (deferred from phase 1b-ii): plane_fetch needs
    // the SOURCE row that will DISPLAY on the NEXT scanline.  The compositor
    // computes this divider-free via its §4.2 vertical accumulator and exposes
    // it on src_row_next_o — so we just route plane 1's slice here.  (An
    // earlier `(next_line-clip_y0)/scale` divide at the top became an 18-level
    // carry chain off v_count and broke the clk_pix timing path; the
    // accumulator is a ~3-level derive of registered state.)
    wire [11:0] xl_fetch_row = cmp_src_row_next[2*12 +: 12];   // XL is plane index 2

    // Plane-2 source: a second plane_fetch reading the XL DISPLAY buffer over
    // HP3's read channel.  xl_display_idx (clk_sys, from xl_buffer_ctrl) is
    // adopted at the scan-out vblank and is provably never the slot the writeback
    // is filling, so plane_fetch always reads a complete, stable frame — the old
    // ~1 Hz tear and moving ghost lines (from the async front_sel flip) are gone.
    logic [31:0] xl_surface_base;
    always_comb begin
        unique case (xl_display_idx)
            2'd0:    xl_surface_base = XL_BASE_0;
            2'd1:    xl_surface_base = XL_BASE_1;
            default: xl_surface_base = XL_BASE_2;
        endcase
    end
    wire [31:0] xl_pixel;

    plane_fetch u_plane_fetch1 (
        .clk_sys (clk_sys), .rst_sys (pf_rst_sys), .enable (1'b1),
        .surface_base (xl_surface_base), .stride_bytes (16'(XL_STRIDE)),
        .src_w (12'(XL_SRC_W)),
        .m_axi_araddr (hp3_araddr), .m_axi_arlen (hp3_arlen), .m_axi_arsize (hp3_arsize),
        .m_axi_arburst (hp3_arburst), .m_axi_arvalid (hp3_arvalid),
        .m_axi_arready (hp3_arready), .m_axi_rdata (hp3_rdata),
        .m_axi_rvalid (hp3_rvalid), .m_axi_rlast (hp3_rlast), .m_axi_rready (hp3_rready),
        .clk_pix (clk_pix), .rst_pix (pf_rst_pix),
        .line_start (fb_line_start), .line_start_e (fb_line_start_e), .fetch_row (xl_fetch_row),
        .rd_col (cmp_src_col[2*12 +: 12]), .rd_pixel (xl_pixel),
        .read_abort (xl_read_abort), .fetch_overrun (xl_overrun)
    );

    // ---- Drag overlay (plane 1): movable DDR-backed window surface --------
    // A bounded surface composited above the desktop (depth 1) but below the
    // XL/ST windows (depth 2), used to show a GEM window while it is dragged so
    // moving it is a single (x,y) register write instead of re-blitting it into
    // the desktop plane each frame.  Reads via HP2's idle READ channel (the
    // antic_writeback only uses HP2 writes).  Position is adopted ATOMICALLY in
    // clk_pix on the bridge's commit toggle (stable-data + sync-flag CDC — the
    // clk_sys {x,y,w,h,en} are stable before the 1-bit flag toggles), then
    // applied at the scan-out vblank (fb_vbi_start) so a mid-drag move never
    // tears.  This deliberately avoids a free-running multi-bit 2-FF bus sync
    // (the class of bug behind the old row-128 rainbow-dash; see docs/video).
    wire        ov_commit_pix;
    cdc_sync_bit u_ov_commit (.dst_clk (clk_pix), .src_sig (overlay_commit), .dst_sig (ov_commit_pix));
    reg  ov_commit_d = 1'b0;
    always_ff @(posedge clk_pix) ov_commit_d <= ov_commit_pix;
    wire ov_commit_edge = ov_commit_pix ^ ov_commit_d;        // 1-cyc on either edge

    // Pending = captured atomically on the commit flag; displayed = adopted at
    // vblank (tear-free).  x/y/w/h cross as a stable group gated by the flag.
    reg [11:0] ov_x_pend = 12'd0, ov_y_pend = 12'd0, ov_w_pend = 12'd0, ov_h_pend = 12'd0;
    reg        ov_en_pend = 1'b0;
    always_ff @(posedge clk_pix) if (ov_commit_edge) begin
        ov_x_pend  <= overlay_x;  ov_y_pend  <= overlay_y;
        ov_w_pend  <= overlay_w;  ov_h_pend  <= overlay_h;
        ov_en_pend <= overlay_en;
    end
    reg [11:0] ov_x_d = 12'd0, ov_y_d = 12'd0, ov_w_d = 12'd0, ov_h_d = 12'd0;
    reg        ov_en_d = 1'b0;
    always_ff @(posedge clk_pix) if (fb_vbi_start) begin
        ov_x_d  <= ov_x_pend;  ov_y_d  <= ov_y_pend;
        ov_w_d  <= ov_w_pend;  ov_h_d  <= ov_h_pend;
        ov_en_d <= ov_en_pend;
    end
    wire [11:0] ov_x1_d = ov_x_d + ov_w_d;                    // clip x1 = x + w
    wire [11:0] ov_y1_d = ov_y_d + ov_h_d;                    // clip y1 = y + h
    wire [11:0] ov_fetch_row = cmp_src_row_next[1*12 +: 12];  // overlay is plane index 1
    wire [31:0] overlay_pixel;

    // stride is a COMPILE-TIME CONSTANT (8192 B = 2048 px/row) so plane_fetch's
    // row*stride folds to a shift (like the desktop/XL planes) — a variable
    // stride synthesises a DSP multiply with overlay_w on the HP2-araddr path
    // and busts clk_sys.  The PS renders the drag surface at this fixed stride
    // (see OVL_STRIDE_W in xt_blitter.h); src_w (= overlay_w) still bounds the
    // per-row fetch, so only the window's columns are read (no extra bandwidth).
    plane_fetch u_plane_fetch_overlay (
        .clk_sys (clk_sys), .rst_sys (pf_rst_sys), .enable (overlay_en),
        .surface_base (overlay_base), .stride_bytes (16'd8192),  // 2048 px * 4 (RGBA)
        .src_w (overlay_w),
        .m_axi_araddr (ovl_araddr), .m_axi_arlen (ovl_arlen), .m_axi_arsize (ovl_arsize),
        .m_axi_arburst (ovl_arburst), .m_axi_arvalid (ovl_arvalid),
        .m_axi_arready (ovl_arready), .m_axi_rdata (ovl_rdata),
        .m_axi_rvalid (ovl_rvalid), .m_axi_rlast (ovl_rlast), .m_axi_rready (ovl_rready),
        .clk_pix (clk_pix), .rst_pix (pf_rst_pix),
        .line_start (fb_line_start), .line_start_e (fb_line_start_e), .fetch_row (ov_fetch_row),
        .rd_col (cmp_src_col[1*12 +: 12]), .rd_pixel (overlay_pixel),
        .read_abort (), .fetch_overrun ()
    );

    // ---- Compositor plane arrangement (cmpcfg -> clk_pix) ----------------
    // cmpcfg is QUASI-STATIC: the PS writes it at setup and (rarely) to switch
    // arrangement, so a plain 2-FF sync is correct here — this is NOT a
    // free-running multi-bit bus (the class that needs cdc_flag_data). The sync
    // regs INITIALISE to 0x210 so the compositor boots the shipping arrangement
    // (XL depth 2 on top, overlay 1, desktop 0, all opaque) before any PS write.
    // A skew glitch can only occur the instant the PS rewrites it -> at worst a
    // single-frame flicker during a deliberate mode switch, never at runtime.
    // Route-A flip = PS writes 0x00010132 (desktop depth 2 + alpha, overlay 3,
    // XL 1) so the desktop rides on top and its alpha=0 holes reveal XL below.
    (* ASYNC_REG = "TRUE" *) reg [31:0] cmpcfg_s0  = 32'h0000_0210;
    (* ASYNC_REG = "TRUE" *) reg [31:0] cmpcfg_pix = 32'h0000_0210;
    always_ff @(posedge clk_pix) begin
        cmpcfg_s0  <= cmpcfg;
        cmpcfg_pix <= cmpcfg_s0;
    end
    // Decode into per-plane fields, packed {plane2=XL, plane1=overlay, plane0=desktop}.
    wire [3:0] cc_desk_depth = cmpcfg_pix[3:0];
    wire [3:0] cc_ovl_depth  = cmpcfg_pix[7:4];
    wire [3:0] cc_xl_depth   = cmpcfg_pix[11:8];
    wire       cc_desk_alpha = cmpcfg_pix[16];
    wire       cc_ovl_alpha  = cmpcfg_pix[17];
    wire       cc_xl_alpha   = cmpcfg_pix[18];

    // ---- Plane compositor -----------------------------------------------
    wire [4:0] comp_rgb_r; wire [5:0] comp_rgb_g; wire [4:0] comp_rgb_b;
    wire       comp_de, comp_hsync, comp_vsync;

    plane_compositor #(.N_PLANES(CMP_PLANES), .H_ACTIVE(1920), .V_ACTIVE(1080)) u_compositor (
        .clk_pix (clk_pix), .rst_pix (rst_pix),
        .h_count (fb_h_count), .v_count (fb_v_count),
        .de (vb_de), .hsync (vb_hsync), .vsync (vb_vsync), .line_start (fb_line_start), .line_start_e (fb_line_start_e),
        // Buses pack {plane2, plane1, plane0} = {XL, drag-overlay, desktop}.
        // depth: desktop 0 (back), overlay 1, XL 2 (front) — the overlay rides
        // above the desktop but below the XL/ST windows so a dragged window
        // never jumps in front of them.
        .pl_enable   ({1'b1,       ov_en_d,  1'b1}),          // XL on, overlay gated, desktop on
        .pl_alpha_en ({cc_xl_alpha, cc_ovl_alpha, cc_desk_alpha}), // per-plane, from cmpcfg (CTRL 0x18).
                                                              // Reset: all opaque. Route-A sets the
                                                              // desktop bit so its alpha=0 holes reveal
                                                              // XL. (Retires the old gp0_ctrl[5] tie,
                                                              // which collided with video-sleep.)
        .pl_origin_x ({xl_org_x_r, ov_x_d,   12'd0}),         // XL runtime-scaled (gp0_ctrl[3:1])
        .pl_origin_y ({xl_org_y_r, ov_y_d,   12'd0}),
        .pl_scale    ({xl_scale_q, 3'd1,     3'd1}),
        .pl_depth    ({cc_xl_depth, cc_ovl_depth, cc_desk_depth}), // per-plane, from cmpcfg (CTRL 0x18)
        .pl_clip_x0  ({xl_org_x_r, ov_x_d,   12'd0}),
        .pl_clip_y0  ({xl_org_y_r, ov_y_d,   12'd0}),
        .pl_clip_x1  ({xl_clx1_r,  ov_x1_d,  12'd1920}),
        .pl_clip_y1  ({xl_cly1_r,  ov_y1_d,  12'd1080}),
        .bg_color    (24'h00_00_00),
        .src_col_o   (cmp_src_col),
        .src_row_o   (cmp_src_row),                            // current row (unused at top)
        .src_row_next_o (cmp_src_row_next),                    // next row -> plane_fetch prefetch
        .src_pixel_i ({xl_pixel, overlay_pixel, desk_pixel}), // {plane2, plane1, plane0}
        .rgb_r (comp_rgb_r), .rgb_g (comp_rgb_g), .rgb_b (comp_rgb_b),
        .de_o (comp_de), .hsync_o (comp_hsync), .vsync_o (comp_vsync)
    );

    // ====================================================================
    // sprite_engine — sprite compositor between the plane compositor and SOM RGB pins
    // ====================================================================
    // Scaffold stub: passthrough.  All internal submodules (descriptor
    // regs, line cache, fetcher, compositor) land in subsequent commits.
    wire [4:0] spr_rgb_r;
    wire [5:0] spr_rgb_g;
    wire [4:0] spr_rgb_b;
    wire       spr_rgb_de;
    wire       spr_rgb_hsync;
    wire       spr_rgb_vsync;

    // Sprite engine register snoop — fires on $D4Ax (per-sprite control)
    // and $D4Dx (indexed descriptor + collision + ctrl) writes from the
    // SALLY hwreg path (already at clk_sys post-CDC).  Read-back into
    // SALLY is wired by the d4xx read-path mux in a later commit; until
    // then reg_rdata is observable in sim only.
    // Gated by xt_unlock[SPRITE]: locked → the $D4Ax/$D4Dx writes never reach
    // the sprite engine and fall through to the stock ANTIC mirror.
    wire sprite_reg_we = antic_we_q
                        && xt_unlock_loc[UNLK_SPRITE]
                        && (bus_addr_antic_q[15:8] == 8'hD4)
                        && ((bus_addr_antic_q[7:4] == 4'hA)
                            || (bus_addr_antic_q[7:4] == 4'hD));

    // A9-driven sprite reg writes (GP0 0x22 = reg index, 0x23 = data + strobe,
    // via the bridge).  The sprite engine is a desktop compositor owned by the
    // A9, so the A9 drives reg_* directly (no unlock gate); the dormant SALLY-bus
    // path above is muxed in behind it.
    wire [7:0] spr_reg_addr_a9, spr_reg_data_a9;
    wire       spr_reg_we_a9;
    wire       sprite_reg_we_mux    = spr_reg_we_a9 | sprite_reg_we;
    wire [7:0] sprite_reg_addr_mux  = spr_reg_we_a9 ? spr_reg_addr_a9 : bus_addr_antic_q[7:0];
    wire [7:0] sprite_reg_wdata_mux = spr_reg_we_a9 ? spr_reg_data_a9 : bus_data_in_antic_q;
    wire [7:0]  sprite_reg_rdata_unused;
    wire [15:0] spr_coll_data;            // collision[col_sel] -> GP0 SPR_COLL readback

    sprite_engine u_sprite_engine (
        .clk_fetch     (clk_sys),
        .clk_pix       (clk_pix),
        .rst           (rst_pix),

        .h_count       (fb_h_count),
        .v_count       (fb_v_count),
        .line_start    (fb_line_start),
        .frame_start   (fb_frame_start),

        .reg_we        (sprite_reg_we_mux),
        .reg_addr      (sprite_reg_addr_mux),
        .reg_wdata     (sprite_reg_wdata_mux),
        .reg_rdata     (sprite_reg_rdata_unused),
        .coll_sel_data (spr_coll_data),

        .fb_pixel      ({comp_rgb_r, comp_rgb_g, comp_rgb_b}),
        .fb_de         (comp_de),
        .fb_hsync      (comp_hsync),
        .fb_vsync      (comp_vsync),

        .rgb_r         (spr_rgb_r),
        .rgb_g         (spr_rgb_g),
        .rgb_b         (spr_rgb_b),
        .rgb_de        (spr_rgb_de),
        .rgb_hsync     (spr_rgb_hsync),
        .rgb_vsync     (spr_rgb_vsync),

        // AXI read master (sprite-image fetch).  Shares HP2's read channel with
        // the (intermittent) drag-overlay via hp2_rd_mux below — HP2's write
        // channel is antic_writeback (write-only), so the read channel is free.
        .m_axi_araddr  (spr_araddr),
        .m_axi_arlen   (spr_arlen),
        .m_axi_arsize  (spr_arsize),
        .m_axi_arburst (spr_arburst),
        .m_axi_arvalid (spr_arvalid),
        .m_axi_arready (spr_arready),
        .m_axi_rdata   (spr_rdata),
        .m_axi_rvalid  (spr_rvalid),
        .m_axi_rlast   (spr_rlast),
        .m_axi_rready  (spr_rready)
    );

    // Shared HP2 read: drag-overlay (s0, priority) + sprite fetcher (s1) -> HP2.
    // Multi-outstanding so the overlay keeps its pipelined AR (no drag tearing).
    hp2_rd_mux u_hp2_rd_mux (
        .clk (clk_sys), .rst (pf_rst_sys),
        .s0_araddr (ovl_araddr), .s0_arlen (ovl_arlen), .s0_arsize (ovl_arsize),
        .s0_arburst (ovl_arburst), .s0_arvalid (ovl_arvalid), .s0_arready (ovl_arready),
        .s0_rdata (ovl_rdata), .s0_rvalid (ovl_rvalid), .s0_rlast (ovl_rlast), .s0_rready (ovl_rready),
        .s1_araddr (spr_araddr), .s1_arlen (spr_arlen), .s1_arsize (spr_arsize),
        .s1_arburst (spr_arburst), .s1_arvalid (spr_arvalid), .s1_arready (spr_arready),
        .s1_rdata (spr_rdata), .s1_rvalid (spr_rvalid), .s1_rlast (spr_rlast), .s1_rready (spr_rready),
        .m_araddr (hp2_araddr), .m_arlen (hp2_arlen), .m_arsize (hp2_arsize),
        .m_arburst (hp2_arburst), .m_arvalid (hp2_arvalid), .m_arready (hp2_arready),
        .m_rdata (hp2_rdata), .m_rvalid (hp2_rvalid), .m_rlast (hp2_rlast), .m_rready (hp2_rready)
    );

    // ---- RGB pins -------------------------------------------------------
    // Normal path: compositor -> sprite_engine -> pads (the legacy ANTIC
    // window appears as plane 1 once the ANTIC->DDR3 writeback feeds it).
    //
    // Bring-up TEST PATTERN: 8 vertical SMPTE-style colour bars derived from
    // the raster column (clk_pix), muxed onto the pads ahead of the normal
    // path.  Proves the physical HDMI chain (clk_pix -> RGB565 -> SiI9022 ->
    // display) before the planes carry real pixels.  Sync/DE always come from
    // the compositor, so the timing the SiI9022 sees is the real raster.
    // Test-pattern enable is RUNTIME-controlled: GP0 control register bit0
    // (gp0_ctrl[0] from axi_blitter_bridge, written at byte-offset 0x1C =
    // 0x43C0001C), synchronised clk_sys -> clk_pix.  It RESETS to 1 so the
    // board still boots showing bars; the PS clears it to show the live
    // compositor — no bitstream rebuild to toggle (config belongs in PS sw).
    wire [7:0]  gp0_ctrl;                             // driven by u_axi_bridge
    wire [31:0] cmpcfg;                               // compositor plane arrangement (CTRL 0x18)
    assign pix_clk_ce = ~gp0_ctrl[5];                // video-sleep: gp0_ctrl[5]=1 gates clk_pix off (BUFGCE)
    // Drag-overlay config (clk_sys), driven by u_axi_bridge (offsets 0x21-0x2F).
    wire [31:0] overlay_base;
    wire [11:0] overlay_x, overlay_y, overlay_w, overlay_h;
    wire        overlay_en, overlay_commit;

    // XL compositor-plane window placement (clk_sys), from u_axi_bridge (0x5xx).
    // xl_win_en=1 -> A9 positions the XL plane at this rect (GEM emulation window);
    // xl_win_en=0 -> legacy gp0_ctrl-scale centred placement below.
    wire [11:0] xl_win_x, xl_win_y, xl_win_w, xl_win_h;
    wire [2:0]  xl_win_scale;
    wire        xl_win_en;
    wire        xl_win_we;          // commit strobe (clk_sys)
    // Cross the XL-window rect to clk_pix on the commit strobe — multi-bit, so a
    // data+toggle transfer (cdc_flag_data), never a free-running 2-FF bus sync.
    wire [51:0] xl_win_pix;         // {x[12],y[12],w[12],h[12],scale[3],en[1]}
    cdc_flag_data #(.WIDTH(52)) u_xlwin_cdc (
        .src_clk  (clk_sys),
        .src_data ({xl_win_x, xl_win_y, xl_win_w, xl_win_h, xl_win_scale, xl_win_en}),
        .src_valid(xl_win_we),
        .dst_clk  (clk_pix),
        .dst_data (xl_win_pix),
        .dst_valid()
    );
    wire [11:0] xl_win_x_p     = xl_win_pix[51:40];
    wire [11:0] xl_win_y_p     = xl_win_pix[39:28];
    wire [11:0] xl_win_w_p     = xl_win_pix[27:16];
    wire [11:0] xl_win_h_p     = xl_win_pix[15:4];
    wire [2:0]  xl_win_scale_p = xl_win_pix[3:1];
    wire        xl_win_en_p    = xl_win_pix[0];
    (* ASYNC_REG = "TRUE" *) reg [1:0] tp_en_sync = 2'b11;
    always_ff @(posedge clk_pix) tp_en_sync <= {tp_en_sync[0], gp0_ctrl[0]};
    wire test_pattern_pix = tp_en_sync[1];

    // 8 colour bars selected directly by fb_h_count[10:8] (256-px bars; the 8th
    // (black) is half-width since 1920/256 = 7.5).  This direct bit-slice form
    // is the proven-working one (full 8 colours on the 20:54 HDMI build); an
    // intermediate tp_bar signal (comparator ladder or per-line counter) left
    // bars 4-7 black on HW for reasons TBD — revisit even-width bars later, now
    // that GP0 writes work it can be experimented with live via the REPL.
    reg [4:0] tp_r; reg [5:0] tp_g; reg [4:0] tp_b;
    always_ff @(posedge clk_pix) begin
        unique case (fb_h_count[10:8])
            3'd0: {tp_r,tp_g,tp_b} <= {5'd31,6'd63,5'd31}; // white
            3'd1: {tp_r,tp_g,tp_b} <= {5'd31,6'd63,5'd0 }; // yellow
            3'd2: {tp_r,tp_g,tp_b} <= {5'd0 ,6'd63,5'd31}; // cyan
            3'd3: {tp_r,tp_g,tp_b} <= {5'd0 ,6'd63,5'd0 }; // green
            3'd4: {tp_r,tp_g,tp_b} <= {5'd31,6'd0 ,5'd31}; // magenta
            3'd5: {tp_r,tp_g,tp_b} <= {5'd31,6'd0 ,5'd0 }; // red
            3'd6: {tp_r,tp_g,tp_b} <= {5'd0 ,6'd0 ,5'd31}; // blue
            3'd7: {tp_r,tp_g,tp_b} <= {5'd0 ,6'd0 ,5'd0 }; // black
        endcase
    end

    // Final output stage — register RGB + sync + DE on clk_pix in one place so
    // they launch cleanly and aligned (pack into the IOB output FFs via
    // IOB=TRUE in the XDC), matched to the ODDR-forwarded pixel clock.  When the
    // test pattern is enabled (test_pattern_pix) the sync/DE come straight from
    // vbeam (vb_*), NOT the compositor (spr_*), so the test frame is fully
    // vbeam-sourced and free of the compositor/plane-fetch pipeline (which
    // depends on DDR data we don't have yet).
    reg [4:0] o_r; reg [5:0] o_g; reg [4:0] o_b;
    reg       o_de, o_hs, o_vs;
    always_ff @(posedge clk_pix) begin
        o_r  <= test_pattern_pix ? tp_r     : spr_rgb_r;
        o_g  <= test_pattern_pix ? tp_g     : spr_rgb_g;
        o_b  <= test_pattern_pix ? tp_b     : spr_rgb_b;
        o_de <= test_pattern_pix ? vb_de    : spr_rgb_de;
        o_hs <= test_pattern_pix ? vb_hsync : spr_rgb_hsync;
        o_vs <= test_pattern_pix ? vb_vsync : spr_rgb_vsync;
    end
    assign rgb_r      = o_r;
    assign rgb_g      = o_g;
    assign rgb_b      = o_b;
    assign rgb_hsync  = o_hs;
    assign rgb_vsync  = o_vs;
    assign rgb_de     = o_de;

    // Forward clk_pix to the SiI9022 pixel-clock pin (IDCK) through an ODDR —
    // NOT a plain assign.  A plain assign routes the global clock through the
    // fabric to the IOB and does not present a clean pixel clock; the chip then
    // can't lock TMDS ("no signal").  D1=0/D2=1 emits clk_pix inverted (180°),
    // so the rising edge the SiI9022 samples on lands mid-data-eye (data is
    // launched on clk_pix rising).  If colours come out wrong, flip the chip's
    // input clock-edge bit (TPI reg 0x08) in software — no rebuild.
    ODDR #(
        .DDR_CLK_EDGE ("SAME_EDGE"),
        .INIT         (1'b0),
        .SRTYPE       ("SYNC")
    ) u_pixclk_oddr (
        .Q  (rgb_pixclk),
        .C  (clk_pix),
        .CE (1'b1),
        .D1 (1'b0),
        .D2 (1'b1),
        .R  (1'b0),
        .S  (1'b0)
    );

    // ====================================================================
    // AXI-Lite bridge — GP0 from ARM PS → blitter register bus
    // ====================================================================
    // Bridge signals exist only in PS BD builds; in OOC path they are
    // tied to 0 so the mux below falls through to the SALLY CDC path.
    //
    // Bridge output bus (before reconstructing full bus_addr):
    `ifdef USE_PS_BD
    wire        bl_bridge_we;
    wire [5:0]  bl_bridge_addr;
    wire [7:0]  bl_bridge_data;
    wire        xt_unlock_we;          // A9 unlock-write strobe (GP0 offset 0x20)
    `else
    wire        bl_bridge_we   = 1'b0;
    wire [5:0]  bl_bridge_addr = 6'd0;
    wire [7:0]  bl_bridge_data = 8'd0;
    wire        xt_unlock_we   = 1'b0;
    `endif

    // Reconstruct full 16-bit bus_addr from bridge's 6-bit register addr.
    //   bl_bridge_addr[5:4] = page select: 00=$D4Bx, 01=$D4Cx, 10=$D4Dx, 11=$D4Ex
    //   bus_addr[7:4] = 4'b1011/1100/1101/1110 for B/C/D/E
    //   bus_addr[3:0] = register index within page
    wire [15:0] bridge_bus_addr;
    assign bridge_bus_addr[15:8] = 8'hD4;
    assign bridge_bus_addr[7:4]  = (bl_bridge_addr[5:4] == 2'b00) ? 4'b1011 :  // $D4Bx
                                   (bl_bridge_addr[5:4] == 2'b01) ? 4'b1100 :  // $D4Cx
                                   (bl_bridge_addr[5:4] == 2'b10) ? 4'b1101 :  // $D4Dx
                                                                    4'b1110;   // $D4Ex
    assign bridge_bus_addr[3:0]  = bl_bridge_addr[3:0];

    // Keyboard-inject decode (boot blocker #5).  A PS write through the GP0
    // bridge to $D4CF carries an Atari KBCODE byte; pulse kbd_event for one
    // clk_sys cycle.  The blitter only decodes $D4Bx and the sprite engine
    // $D4Ax/$D4Dx, so $D4CF is free.  Gated on bl_bridge_we (PS-originated)
    // so a stray SALLY write can't fake a keypress.  ASCII->KBCODE mapping
    // is done PS-side.  (OOC build: bl_bridge_we is tied 0, so this is inert.)
    // $D4CF = key-down (KBCODE + keyboard IRQ), $D4CD = all-keys-up (clears the
    // SKSTAT key-down so the OS auto-repeat stops), $D4CB = Atari BREAK (POKEY
    // IRQST bit 7, a separate source from the KBCODE matrix).  All free in the
    // $D4Cx I/O gap; gated on bl_bridge_we so only the PS can drive them.
    wire kbd_inject_we  = bl_bridge_we && (bridge_bus_addr == 16'hD4CF);
    wire kbd_release_we = bl_bridge_we && (bridge_bus_addr == 16'hD4CD);
    wire kbd_break_we   = bl_bridge_we && (bridge_bus_addr == 16'hD4CB);
    // $D4CA = SALLY speed (clock_mult) register — get/set by BOTH the 6502 (POKE,
    // via the muxed bus below) and the A9 (GP0 / REPL `speed`).  Resets to 1
    // (lockstep / safe boot); software dials it up after the OS reaches READY, so
    // turbo never has to survive cold boot.  Read-back at $D4CA (overrides SEQ_HI).
    wire clock_mult_we  = bl_we_mux && (bl_addr_mux == 16'hD4CA);
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            kbd_event_valid_q <= 1'b0;
            kbd_event_code_q  <= 8'h00;
            kbd_release_q     <= 1'b0;
            break_pulse_q     <= 1'b0;
            clock_mult_q      <= 8'd1;
        end else begin
            kbd_event_valid_q <= kbd_inject_we;          // 1-cycle pulse
            if (kbd_inject_we) kbd_event_code_q <= bl_bridge_data;
            kbd_release_q     <= kbd_release_we;          // 1-cycle pulse
            break_pulse_q     <= kbd_break_we;            // 1-cycle pulse
            if (clock_mult_we) clock_mult_q <= bl_data_mux;
        end
    end

    // clock_mult is clk_sys; sally_clock samples it in clk_sally.  It's quasi-
    // static (changed only by a REPL poke), so a plain 2-FF sync is fine — a
    // 1-cycle transient on a change just blips the step rate, no data hazard.
    (* ASYNC_REG = "TRUE" *) logic [7:0] clock_mult_s1, clock_mult_sally;
    always_ff @(posedge clk_sally) begin
        clock_mult_s1    <= clock_mult_q;
        clock_mult_sally <= clock_mult_s1;
    end

    // Read-back returns the *effective* multiplier sally_clock actually applies,
    // not the raw written value: sally_clock normalises any clock_mult that is
    // not a clean divisor of BASE_DIV (56) back to 1× (its case default).  Mirror
    // that here so $D4CA / GP0 0x1E report the real speed and the REPL `speed`
    // verify needs no software grade table.
    // ⚠ Keep this divisor set in sync with sally_clock's case — BASE_DIV=56,
    // divisors {1,2,4,7,8,14,28,56}.
    function automatic [7:0] sally_eff_mult(input [7:0] m);
        case (m)
            8'd1, 8'd2, 8'd4, 8'd7, 8'd8, 8'd14, 8'd28, 8'd56: sally_eff_mult = m;
            default:                                           sally_eff_mult = 8'd1;
        endcase
    endfunction

    wire [7:0] eff_clock_mult_sys   = sally_eff_mult(clock_mult_q);     // clk_sys  -> GP0 0x1E
    wire [7:0] eff_clock_mult_sally = sally_eff_mult(clock_mult_sally); // clk_sally -> $D4CA

    // Mux: bridge takes priority when bl_bridge_we is asserted.
    // Both sources run on clk_sys and produce single-cycle strobes.
    // The NATIVE term is gated by xt_unlock[BLITTER]: locked → the 6502's
    // $D4Bx/$D4Cx writes (and the $D4CA turbo poke, which rides bl_we_mux) never
    // reach the blitter and fall through to the stock ANTIC mirror.  The bridge
    // (A9) term is never gated.
    wire        bl_we_mux   = bl_bridge_we | (antic_we_q & xt_unlock_loc[UNLK_BLIT]);
    wire [15:0] bl_addr_mux = bl_bridge_we ? bridge_bus_addr : bus_addr_antic_q;
    wire [7:0]  bl_data_mux = bl_bridge_we ? bl_bridge_data  : bus_data_in_antic_q;

    // ---- XT register-unlock register (two write ports) -------------------
    // Port A (authority): the A9 via the GP0 bridge (xt_unlock_we strobe + the
    // byte on bl_bridge_data, latched the same cycle by the bridge).
    // Port B: the 6502 via a native write to $D1DF (PBI window — nothing stock
    // writes it; the location is the protection, see register-unlock.md).  The
    // A9 wins a same-cycle tie.  PL reset → 0 (fully locked); a 6502-only reset
    // does NOT clear it, so the A9 owns the personality across a guest reset.
    wire unlock_d1df_we = antic_we_q && (bus_addr_antic_q == 16'hD1DF);
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            xt_unlock     <= XT_UNLOCK_RESET;     // XT-native: all groups live at power-on
            xt_unlock_loc <= XT_UNLOCK_RESET;
        end else begin
            if      (xt_unlock_we)   xt_unlock <= bl_bridge_data;        // A9 (priority)
            else if (unlock_d1df_we) xt_unlock <= bus_data_in_antic_q;   // 6502 self-unlock
            // Local registered copy — feeds the sprite/blitter gates near the
            // (timing-critical) blitter pblock, off the master register's fanout.
            xt_unlock_loc <= xt_unlock;
        end
    end

    // ====================================================================
    // xt_blitter v0 — rect fill with solid RGBA-8888
    // ====================================================================
    // Taps the same clk_sys-domain post-CDC SALLY hwreg bus that ANTIC
    // uses; the blitter address-decodes $D4B0..$D4BF internally so the
    // ANTIC and blitter register spaces are disjoint.  Writes outside
    // $D4Bx are ignored by the blitter.
    //
    // When the AXI-Lite bridge is present (USE_PS_BD), register writes
    // from the ARM Cortex-A9s are merged with the SALLY CDC path via
    // the bl_addr_mux / bl_data_mux / bl_we_mux above.

    wire bl_busy;
    wire bl_blit_irq;            // blitter completion IRQ -> PS IRQ_F2P[0] (GIC ID 61)
    wire bl_cq_full;
    wire bl_pat_blocked;
    wire [15:0] bl_seq_counter;

    xt_blitter #(
        .FB_BASE     (32'h3000_0000),
        .FB_STRIDE_B (8192)
    ) u_xt_blitter (
        .clk             (clk_sys),
        .rst             (rst_sys),
        .bus_addr        (bl_addr_mux),
        .bus_data        (bl_data_mux),
        .bus_we          (bl_we_mux),
        .busy            (bl_busy),
        .irq             (bl_blit_irq),
        .cq_full         (bl_cq_full),
        .pat_blocked     (bl_pat_blocked),
        .seq_counter     (bl_seq_counter),
        .m_axi_awaddr    (hp1_awaddr),
        .m_axi_awlen     (hp1_awlen),
        .m_axi_awsize    (hp1_awsize),
        .m_axi_awburst   (hp1_awburst),
        .m_axi_awvalid   (hp1_awvalid),
        .m_axi_awready   (hp1_awready),
        .m_axi_wdata     (hp1_wdata),
        .m_axi_wstrb     (hp1_wstrb),
        .m_axi_wlast     (hp1_wlast),
        .m_axi_wvalid    (hp1_wvalid),
        .m_axi_wready    (hp1_wready),
        .m_axi_bvalid    (hp1_bvalid),
        .m_axi_bready    (hp1_bready),
        // AXI4 read master (HP1 AR channel)
        .m_axi_araddr    (hp1_araddr),
        .m_axi_arlen     (hp1_arlen),
        .m_axi_arsize    (hp1_arsize),
        .m_axi_arburst   (hp1_arburst),
        .m_axi_arvalid   (hp1_arvalid),
        .m_axi_arready   (hp1_arready),
        .m_axi_rdata     (hp1_rdata),
        .m_axi_rvalid    (hp1_rvalid),
        .m_axi_rlast     (hp1_rlast),
        .m_axi_rready    (hp1_rready)
    );

    // ====================================================================
    // CDC: blitter status (clk_sys → clk_sally) for SALLY register reads
    // ====================================================================
    // busy, queue_full and pat_blocked cross to clk_sally for the $D4BD
    // STATUS readback.  cdc_sync_bit is a 2-FF synchroniser; each bit
    // gets its own pair (no Gray-coding needed since the bits are
    // sampled independently and SW polls until stable).
    wire bl_busy_sally;
    wire bl_cq_full_sally;
    wire bl_pat_blocked_sally;

    cdc_sync_bit #(.WIDTH(1)) u_sync_bl_busy (
        .dst_clk (clk_sally),
        .src_sig (bl_busy),
        .dst_sig (bl_busy_sally)
    );

    cdc_sync_bit #(.WIDTH(1)) u_sync_bl_cq_full (
        .dst_clk (clk_sally),
        .src_sig (bl_cq_full),
        .dst_sig (bl_cq_full_sally)
    );

    cdc_sync_bit #(.WIDTH(1)) u_sync_bl_pat_blocked (
        .dst_clk (clk_sally),
        .src_sig (bl_pat_blocked),
        .dst_sig (bl_pat_blocked_sally)
    );

    // ====================================================================
    // CDC: seq_counter (16-bit, clk_sys → clk_sally) via Gray code
    // ====================================================================
    // The seq counter is a monotonic-on-increment integer; raw multi-bit
    // 2-FF sync would glitch across binary transitions like 0xFF → 0x100
    // (9 bits change at once).  Encode to Gray on the source side: only
    // one bit changes per increment, so each bit can be sync'd
    // independently and the result is always a valid Gray code (possibly
    // one cycle out of date).  Decode back to binary on the destination
    // side via the standard XOR-prefix recurrence.
    wire [15:0] bl_seq_gray = bl_seq_counter ^ (bl_seq_counter >> 1);
    wire [15:0] bl_seq_gray_sally;
    logic [15:0] bl_seq_counter_sally;

    // cdc-lint: gray-coded — bl_seq_gray changes one bit per increment, so each
    // bit syncs independently and the result is always a valid (≤1-old) code.
    cdc_sync_bit #(.WIDTH(16)) u_sync_bl_seq (
        .dst_clk (clk_sally),
        .src_sig (bl_seq_gray),
        .dst_sig (bl_seq_gray_sally)
    );

    // Gray-to-binary decode: counter[i] = XOR of gray[15:i].
    always_comb begin
        bl_seq_counter_sally[15] = bl_seq_gray_sally[15];
        for (int i = 14; i >= 0; i--)
            bl_seq_counter_sally[i] = bl_seq_gray_sally[i] ^ bl_seq_counter_sally[i+1];
    end

    // ====================================================================
    // SiI9022A HDMI transmitter I2C configuration
    // ====================================================================
    // Runs on clk_sys (133 MHz).  After reset deassertion, configures the
    // SiI9022A TPI registers via the bit-banged I2C master for 1080p60
    // RGB565 operation.  The SDA/SCL pins are inout (open-drain) with
    // external pull-ups on the baseboard.
    //
    // The done flag is observed-only for now — the video output drives its
    // pixel clock and sync signals regardless, and the SiI9022A will begin
    // outputting valid TMDS once its PLL locks to the programmed pixel rate.

    // SiI9022A control bus is driven by PS I2C0 over EMIO (see gen_ps_bd.tcl) —
    // exactly as MyIR's working HDMI reference.  The EMIO iic_0 3-state signals
    // come up from u_ps_bd; wrap them in IOBUFs to the open-drain pads P15/P16
    // (external 4.7k pull-ups on the baseboard).  The PL bit-bang hdmi_config is
    // retired: the PS app (XIic) now configures the chip and reads back its ID.
    wire i2c_scl_i, i2c_scl_o, i2c_scl_t;
    wire i2c_sda_i, i2c_sda_o, i2c_sda_t;
    IOBUF u_iic_scl (.I(i2c_scl_o), .O(i2c_scl_i), .T(i2c_scl_t), .IO(hdmi_scl));
    IOBUF u_iic_sda (.I(i2c_sda_o), .O(i2c_sda_i), .T(i2c_sda_t), .IO(hdmi_sda));

    // ---- Hardware register read data (clk_sally) --------------------------
    // hwreg_dout feeds into sally_mem's read pipeline — it must be
    // combinational from hwreg_addr.  Default to 8'hFF (like sally_synth_top)
    // for unassigned addresses.
    //   $D4BD STATUS = {5'b0, pat_blocked, queue_full, busy}
    //   $D4C9 SEQ_LO = low byte of 16-bit SYNC counter
    //   $D4CA SEQ_HI = high byte
    assign hwreg_dout = (hwreg_addr == 16'hD4BD)
                            ? {5'b0, bl_pat_blocked_sally,
                                     bl_cq_full_sally,
                                     bl_busy_sally}
                      : (hwreg_addr == 16'hD4C9)
                            ? bl_seq_counter_sally[7:0]
                      : (hwreg_addr == 16'hD4CA)
                            ? eff_clock_mult_sally   // effective SALLY speed (clock_mult normalised; was SEQ_HI)
                      : is_blitter_reg
                            ? 8'hFF              // other blitter regs: no readback
                      : cdc_rd_data;             // ANTIC/GTIA/POKEY/PIA via read-back CDC

    // ---- Bring-up debug LEDs (RGB LED on the carrier) -------------------
    // VERIFIED pin/colour mapping (MyIR Z-Turn V2 schematic + clg400 pinout):
    //   dbg[0] = Y16 = IO_B34_LP7 = GREEN
    //   dbg[1] = Y17 = IO_B34_LN7 = BLUE
    //   dbg[2] = R14 = IO_B34_LN6 = RED
    //   dbg[3] = no pin.
    // (The earlier comments mislabelled Y17 as "green"; it is BLUE — which is
    // why watching the green LED blink read as "pll-lock dropping" when it was
    // just the heartbeat on green.  Definitive lock state is the GP0 diag_word.)
    //
    // Assignment — glance test = GREEN+BLUE solid, RED blinking:
    //   GREEN (dbg[0]) = mmcm1_locked  (clk_sally/clk_sys MMCM) — solid = OK
    //   BLUE  (dbg[1]) = mmcm2_locked  (clk_pix MMCM)           — solid = OK
    //   RED   (dbg[2]) = clk_50 heartbeat — always blinks once the bitstream
    //                    loads (liveness, independent of either MMCM)
    reg [24:0] heartbeat_cnt = '0;
    always_ff @(posedge clk_50) heartbeat_cnt <= heartbeat_cnt + 1'b1;  // ~1.5 Hz

    //   dbg = {  -,           RED,              BLUE,         GREEN }
    assign dbg = {1'b0, heartbeat_cnt[24], mmcm2_lock_s, mmcm1_lock_s};

    // PL-side UART is a vestigial port (real debug UART runs through the PS
    // MIO, not the PL).  Tie tx idle-high so the synth dangling-port warning
    // doesn't fire; uart_rx (input) is intentionally unused.
    assign uart_tx = 1'b1;

    `ifdef USE_PS_BD
    // ====================================================================
    // Zynq PS — block design (bitstream builds)
    // ====================================================================
    // The ps_bd module is auto-generated from the block design during
    // synth_design elaboration (via read_bd in build.tcl).  It connects
    // DDR3, MIO (UART, etc.) and exposes HP0/HP1 AXI3 slave ports to
    // the PL fabric.  HP0 serves plane_fetch (framebuffer read), HP1
    // serves xt_blitter (rect fill read/write).  Both HP interfaces
    // clock at 150 MHz from the PS FCLK_CLK0 internally; our PL-side
    // masters run on clk_sys (133 MHz from MMCM #1) and rely on AXI
    // handshake for the asynchronous crossing.
    //
    // In non-project mode, read_bd makes the 'ps_bd' module available
    // directly — the ps_bd_wrapper.v wrapper is not auto-generated so
    // we instantiate the BD module itself.

    // GP0 AXI3 signals — connect PS BD M_AXI_GP0 (master) → AXI-Lite bridge
    // AXI4-Lite subset (used by the bridge):
    wire [31:0] gp0_awaddr;
    wire        gp0_awvalid;
    wire        gp0_awready;
    wire [31:0] gp0_wdata;
    wire [3:0]  gp0_wstrb;
    wire        gp0_wvalid;
    wire        gp0_wready;
    wire [1:0]  gp0_bresp;
    wire        gp0_bvalid;
    wire        gp0_bready;
    wire [31:0] gp0_araddr;
    wire        gp0_arvalid;
    wire        gp0_arready;
    wire [31:0] gp0_rdata;
    wire [1:0]  gp0_rresp;
    wire        gp0_rvalid;
    wire        gp0_rready;
    // ---- AXI3 ID reflection (GP0) -----------------------------------------
    // The PS M_AXI_GP0 is full AXI3: it tags every read/write with an ID and
    // will NOT retire the transaction until it receives a response carrying
    // the MATCHING RID/BID.  The blitter and ROM-init bridges are AXI-Lite
    // (no ID ports), and there is no AXI interconnect between them and the PS
    // to reflect the ID for us — so the wrapper must capture AxID and echo it
    // back.  Tying RID/BID to 0 (as before) means any GP0 access the A9 tags
    // with a non-zero ID never completes → the issuing CPU hangs forever on
    // the read.  One transaction in flight per channel here, so a one-deep
    // capture is sufficient; the master holds AxID stable while AxVALID, so
    // sampling on AxVALID lines the captured ID up with R/B VALID.
    wire [11:0] gp0_arid, gp0_awid;     // driven by the PS GP0 master
    reg  [11:0] gp0_arid_q, gp0_awid_q;
    wire [11:0] gp0_bid;
    wire [11:0] gp0_rid;
    wire        gp0_rlast;
    always_ff @(posedge clk_sys) begin
        if (gp0_arvalid) gp0_arid_q <= gp0_arid;  // hold in-flight read ID
        if (gp0_awvalid) gp0_awid_q <= gp0_awid;  // hold in-flight write ID
    end
    assign gp0_rid   = gp0_arid_q;
    assign gp0_bid   = gp0_awid_q;
    assign gp0_rlast = 1'b1;     // AXI-Lite: every read is a single (last) beat

    ps_bd u_ps_bd (
        // DDR + FIXED_IO — tied off; PS dedicated pins are hard-wired on SOM
        .DDR_addr          (),
        .DDR_ba            (),
        .DDR_cas_n         (),
        .DDR_ck_n          (),
        .DDR_ck_p          (),
        .DDR_cke           (),
        .DDR_cs_n          (),
        .DDR_dm            (),
        .DDR_dq            (),
        .DDR_dqs_n         (),
        .DDR_dqs_p         (),
        .DDR_odt           (),
        .DDR_ras_n         (),
        .DDR_reset_n       (),
        .DDR_we_n          (),
        .FIXED_IO_ddr_vrn  (),
        .FIXED_IO_ddr_vrp  (),
        .FIXED_IO_mio      (),
        .FIXED_IO_ps_clk   (),
        .FIXED_IO_ps_porb  (),
        .FIXED_IO_ps_srstb (),
        .FCLK_RESET0_N_0   (),
        .FCLK_CLK1_0        (fclk_50),   // 50 MHz PL reference -> both MMCMs
        .IRQ_F2P_0          (bl_blit_irq), // PL->PS: blitter completion (GIC 61)
        .IRQ_F2P_1          (math_irq),    // PL->PS: math-cop doorbell (GIC 62)
        .s_axi_gp0_aclk     (clk_sys),
        .s_axi_acp_aclk     (clk_sally),   // ACP (sally_mem page cache) runs on clk_sally
        .iic_0_scl_i        (i2c_scl_i),
        .iic_0_scl_o        (i2c_scl_o),
        .iic_0_scl_t        (i2c_scl_t),
        .iic_0_sda_i        (i2c_sda_i),
        .iic_0_sda_o        (i2c_sda_o),
        .iic_0_sda_t        (i2c_sda_t),
        .m_axi_hp0_araddr   (hp0_araddr[31:0]),
        .m_axi_hp0_arburst  (hp0_arburst[1:0]),
        .m_axi_hp0_arcache  (4'b0000),   // scan-out reads: Device/non-bufferable, in-order & urgent.
                                         // The 0011 (bufferable+MODIFIABLE) experiment let the
                                         // interconnect reorder/merge these reads behind write
                                         // bursts -> compositor plane-fetch underran -> HDMI blanked
                                         // on any DDR burst (present/SD DMA). Reverted to known-good.
        .m_axi_hp0_arid     (6'd0),
        .m_axi_hp0_arlen    (hp0_arlen[3:0]),
        .m_axi_hp0_arlock   (2'd0),
        .m_axi_hp0_arprot   (3'd0),
        .m_axi_hp0_arqos    (4'd0),   // (ARQOS is inert on this DDRC without HPR arb config;
                                      // the real fix was the arcache revert above)
        .m_axi_hp0_arready  (hp0_arready),
        .m_axi_hp0_arsize   (hp0_arsize[2:0]),
        .m_axi_hp0_arvalid  (hp0_arvalid),
        .m_axi_hp0_awaddr   (hp0_awaddr[31:0]),
        .m_axi_hp0_awburst  (hp0_awburst[1:0]),
        .m_axi_hp0_awcache  (4'd0),
        .m_axi_hp0_awid     (6'd0),
        .m_axi_hp0_awlen    (hp0_awlen[3:0]),
        .m_axi_hp0_awlock   (2'd0),
        .m_axi_hp0_awprot   (3'd0),
        .m_axi_hp0_awqos    (4'd0),
        .m_axi_hp0_awready  (hp0_awready),
        .m_axi_hp0_awsize   (hp0_awsize[2:0]),
        .m_axi_hp0_awvalid  (hp0_awvalid),
        .m_axi_hp0_bid      (),
        .m_axi_hp0_bready   (hp0_bready),
        .m_axi_hp0_bresp    (),
        .m_axi_hp0_bvalid   (hp0_bvalid),
        .m_axi_hp0_rdata    (hp0_rdata),
        .m_axi_hp0_rid      (),
        .m_axi_hp0_rlast    (hp0_rlast),
        .m_axi_hp0_rready   (hp0_rready),
        .m_axi_hp0_rresp    (),
        .m_axi_hp0_rvalid   (hp0_rvalid),
        .m_axi_hp0_wdata    (hp0_wdata),
        .m_axi_hp0_wid      (6'd0),
        .m_axi_hp0_wlast    (hp0_wlast),
        .m_axi_hp0_wready   (hp0_wready),
        .m_axi_hp0_wstrb    (hp0_wstrb),
        .m_axi_hp0_wvalid   (hp0_wvalid),

        // GP0 (S_AXI_GP0, 32-bit AXI3) — screen_bank chunk-stack DDR master
        .m_axi_scrn_araddr  (gp0m_araddr[31:0]),
        .m_axi_scrn_arburst (gp0m_arburst[1:0]),
        .m_axi_scrn_arcache (4'd0),
        .m_axi_scrn_arid    (6'd0),
        .m_axi_scrn_arlen   (gp0m_arlen[3:0]),
        .m_axi_scrn_arlock  (2'd0),
        .m_axi_scrn_arprot  (3'd0),
        .m_axi_scrn_arqos   (4'd0),
        .m_axi_scrn_arready (gp0m_arready),
        .m_axi_scrn_arsize  (gp0m_arsize[2:0]),
        .m_axi_scrn_arvalid (gp0m_arvalid),
        .m_axi_scrn_awaddr  (gp0m_awaddr[31:0]),
        .m_axi_scrn_awburst (gp0m_awburst[1:0]),
        .m_axi_scrn_awcache (4'd0),
        .m_axi_scrn_awid    (6'd0),
        .m_axi_scrn_awlen   (gp0m_awlen[3:0]),
        .m_axi_scrn_awlock  (2'd0),
        .m_axi_scrn_awprot  (3'd0),
        .m_axi_scrn_awqos   (4'd0),
        .m_axi_scrn_awready (gp0m_awready),
        .m_axi_scrn_awsize  (gp0m_awsize[2:0]),
        .m_axi_scrn_awvalid (gp0m_awvalid),
        .m_axi_scrn_bid     (),
        .m_axi_scrn_bready  (gp0m_bready),
        .m_axi_scrn_bresp   (),
        .m_axi_scrn_bvalid  (gp0m_bvalid),
        .m_axi_scrn_rdata   (gp0m_rdata),
        .m_axi_scrn_rid     (),
        .m_axi_scrn_rlast   (gp0m_rlast),
        .m_axi_scrn_rready  (gp0m_rready),
        .m_axi_scrn_rresp   (),
        .m_axi_scrn_rvalid  (gp0m_rvalid),
        .m_axi_scrn_wdata   (gp0m_wdata),
        .m_axi_scrn_wid     (6'd0),
        .m_axi_scrn_wlast   (gp0m_wlast),
        .m_axi_scrn_wready  (gp0m_wready),
        .m_axi_scrn_wstrb   (gp0m_wstrb),
        .m_axi_scrn_wvalid  (gp0m_wvalid),

        // ACP (S_AXI_ACP, 64-bit AXI3) — banked_page_cache code/data DDR master
        .m_axi_sally_araddr  (axi_araddr[31:0]),
        .m_axi_sally_arburst (axi_arburst[1:0]),
        .m_axi_sally_arcache (4'd0),
        .m_axi_sally_arid    (6'd0),
        .m_axi_sally_arlen   (axi_arlen[3:0]),
        .m_axi_sally_arlock  (2'd0),
        .m_axi_sally_arprot  (3'd0),
        .m_axi_sally_arqos   (4'd0),
        .m_axi_sally_arready (axi_arready),
        .m_axi_sally_arsize  (axi_arsize[2:0]),
        .m_axi_sally_arvalid (axi_arvalid),
        .m_axi_sally_awaddr  (axi_awaddr[31:0]),
        .m_axi_sally_awburst (axi_awburst[1:0]),
        .m_axi_sally_awcache (4'd0),
        .m_axi_sally_awid    (6'd0),
        .m_axi_sally_awlen   (axi_awlen[3:0]),
        .m_axi_sally_awlock  (2'd0),
        .m_axi_sally_awprot  (3'd0),
        .m_axi_sally_awqos   (4'd0),
        .m_axi_sally_awready (axi_awready),
        .m_axi_sally_awsize  (axi_awsize[2:0]),
        .m_axi_sally_awvalid (axi_awvalid),
        .m_axi_sally_bid     (),
        .m_axi_sally_bready  (axi_bready),
        .m_axi_sally_bresp   (),
        .m_axi_sally_bvalid  (axi_bvalid),
        .m_axi_sally_rdata   (axi_rdata),
        .m_axi_sally_rid     (),
        .m_axi_sally_rlast   (axi_rlast),
        .m_axi_sally_rready  (axi_rready),
        .m_axi_sally_rresp   (),
        .m_axi_sally_rvalid  (axi_rvalid),
        .m_axi_sally_wdata   (axi_wdata),
        .m_axi_sally_wid     (6'd0),
        .m_axi_sally_wlast   (axi_wlast),
        .m_axi_sally_wready  (axi_wready),
        .m_axi_sally_wstrb   (axi_wstrb),
        .m_axi_sally_wvalid  (axi_wvalid),

        // HP1 — xt_blitter (read/write) through pipeline registers
        .m_axi_hp1_araddr   (ps_hp1_araddr[31:0]),
        .m_axi_hp1_arburst  (ps_hp1_arburst[1:0]),
        .m_axi_hp1_arcache  (4'd0),
        .m_axi_hp1_arid     (6'd0),
        .m_axi_hp1_arlen    (ps_hp1_arlen[3:0]),
        .m_axi_hp1_arlock   (2'd0),
        .m_axi_hp1_arprot   (3'd0),
        .m_axi_hp1_arqos    (4'd0),
        .m_axi_hp1_arready  (ps_hp1_arready),
        .m_axi_hp1_arsize   (ps_hp1_arsize[2:0]),
        .m_axi_hp1_arvalid  (ps_hp1_arvalid),
        .m_axi_hp1_awaddr   (ps_hp1_awaddr[31:0]),
        .m_axi_hp1_awburst  (ps_hp1_awburst[1:0]),
        .m_axi_hp1_awcache  (4'd0),
        .m_axi_hp1_awid     (6'd0),
        .m_axi_hp1_awlen    (ps_hp1_awlen[3:0]),
        .m_axi_hp1_awlock   (2'd0),
        .m_axi_hp1_awprot   (3'd0),
        .m_axi_hp1_awqos    (4'd0),
        .m_axi_hp1_awready  (ps_hp1_awready),
        .m_axi_hp1_awsize   (ps_hp1_awsize[2:0]),
        .m_axi_hp1_awvalid  (ps_hp1_awvalid),
        .m_axi_hp1_bid      (),
        .m_axi_hp1_bready   (ps_hp1_bready),
        .m_axi_hp1_bresp    (),
        .m_axi_hp1_bvalid   (ps_hp1_bvalid),
        .m_axi_hp1_rdata    (ps_hp1_rdata),
        .m_axi_hp1_rid      (),
        .m_axi_hp1_rlast    (ps_hp1_rlast),
        .m_axi_hp1_rready   (ps_hp1_rready),
        .m_axi_hp1_rresp    (),
        .m_axi_hp1_rvalid   (ps_hp1_rvalid),
        .m_axi_hp1_wdata    (ps_hp1_wdata),
        .m_axi_hp1_wid      (6'd0),
        .m_axi_hp1_wlast    (ps_hp1_wlast),
        .m_axi_hp1_wready   (ps_hp1_wready),
        .m_axi_hp1_wstrb    (ps_hp1_wstrb),
        .m_axi_hp1_wvalid   (ps_hp1_wvalid),

        // HP3 — XL plane READ (video-arch §10): plane_fetch1 reads the XL window
        // framebuffer from DDR -> compositor.  READ-ONLY (write channel tied off;
        // antic_writeback is on HP2).  Connected directly (no pipeline slice —
        // like HP0); the XL read traffic is light vs the blitter on HP1.
        // REQUIRES the BD regenerated with HP3 enabled — run gen_ps_bd.tcl
        // (sets PCW_USE_S_AXI_HP3=1 and exports m_axi_hp3).
        .m_axi_hp3_araddr   (hp3_araddr[31:0]),
        .m_axi_hp3_arburst  (hp3_arburst[1:0]),
        .m_axi_hp3_arcache  (4'b0011),   // read-path expt: bufferable+modifiable (was 0000)
        .m_axi_hp3_arid     (6'd0),
        .m_axi_hp3_arlen    (hp3_arlen[3:0]),
        .m_axi_hp3_arlock   (2'd0),
        .m_axi_hp3_arprot   (3'd0),
        .m_axi_hp3_arqos    (4'd0),
        .m_axi_hp3_arready  (hp3_arready),
        .m_axi_hp3_arsize   (hp3_arsize[2:0]),
        .m_axi_hp3_arvalid  (hp3_arvalid),
        // HP3 write channel tied off — writeback moved to HP2 (read-only now).
        .m_axi_hp3_awaddr   (32'd0),
        .m_axi_hp3_awburst  (2'd0),
        .m_axi_hp3_awcache  (4'd0),
        .m_axi_hp3_awid     (6'd0),
        .m_axi_hp3_awlen    (4'd0),
        .m_axi_hp3_awlock   (2'd0),
        .m_axi_hp3_awprot   (3'd0),
        .m_axi_hp3_awqos    (4'd0),
        .m_axi_hp3_awready  (),
        .m_axi_hp3_awsize   (3'd0),
        .m_axi_hp3_awvalid  (1'b0),
        .m_axi_hp3_bid      (),
        .m_axi_hp3_bready   (1'b0),
        .m_axi_hp3_bresp    (),
        .m_axi_hp3_bvalid   (),
        .m_axi_hp3_rdata    (hp3_rdata),
        .m_axi_hp3_rid      (),
        .m_axi_hp3_rlast    (hp3_rlast),
        .m_axi_hp3_rready   (hp3_rready),
        .m_axi_hp3_rresp    (),
        .m_axi_hp3_rvalid   (hp3_rvalid),
        .m_axi_hp3_wdata    (64'd0),
        .m_axi_hp3_wid      (6'd0),
        .m_axi_hp3_wlast    (1'b0),
        .m_axi_hp3_wready   (),
        .m_axi_hp3_wstrb    (8'd0),
        .m_axi_hp3_wvalid   (1'b0),

        // HP2 — antic_writeback WRITE master (moved off HP3) + the shared READ
        // channel (hp2_rd_mux): drag-overlay (plane_fetch_overlay) + sprite-engine
        // line fetch.  AWCACHE=0011 (bufferable+modifiable) like HP3's write was;
        // ARCACHE matches the HP0/HP3 reads.
        .m_axi_hp2_araddr   (hp2_araddr[31:0]),
        .m_axi_hp2_arburst  (hp2_arburst[1:0]),
        .m_axi_hp2_arcache  (4'b0011),
        .m_axi_hp2_arid     (6'd0),
        .m_axi_hp2_arlen    (hp2_arlen[3:0]),
        .m_axi_hp2_arlock   (2'd0),
        .m_axi_hp2_arprot   (3'd0),
        .m_axi_hp2_arqos    (4'd0),
        .m_axi_hp2_arready  (hp2_arready),
        .m_axi_hp2_arsize   (hp2_arsize[2:0]),
        .m_axi_hp2_arvalid  (hp2_arvalid),
        .m_axi_hp2_awaddr   (hp2_awaddr[31:0]),
        .m_axi_hp2_awburst  (hp2_awburst[1:0]),
        .m_axi_hp2_awcache  (4'b0011),
        .m_axi_hp2_awid     (6'd0),
        .m_axi_hp2_awlen    (hp2_awlen[3:0]),
        .m_axi_hp2_awlock   (2'd0),
        .m_axi_hp2_awprot   (3'd0),
        .m_axi_hp2_awqos    (4'd0),
        .m_axi_hp2_awready  (hp2_awready),
        .m_axi_hp2_awsize   (hp2_awsize[2:0]),
        .m_axi_hp2_awvalid  (hp2_awvalid),
        .m_axi_hp2_bid      (),
        .m_axi_hp2_bready   (hp2_bready),
        .m_axi_hp2_bresp    (),
        .m_axi_hp2_bvalid   (hp2_bvalid),
        .m_axi_hp2_rdata    (hp2_rdata),
        .m_axi_hp2_rid      (),
        .m_axi_hp2_rlast    (hp2_rlast),
        .m_axi_hp2_rready   (hp2_rready),
        .m_axi_hp2_rresp    (),
        .m_axi_hp2_rvalid   (hp2_rvalid),
        .m_axi_hp2_wdata    (hp2_wdata),
        .m_axi_hp2_wid      (6'd0),
        .m_axi_hp2_wlast    (hp2_wlast),
        .m_axi_hp2_wready   (hp2_wready),
        .m_axi_hp2_wstrb    (hp2_wstrb),
        .m_axi_hp2_wvalid   (hp2_wvalid),

        // GP0 — ARM PS AXI3 master → PL bridge (blitter register writes).
        // Extra AXI3 signals not used by the AXI4-Lite bridge are left
        // unconnected on the PS output side; bridge input tie-offs are
        // driven via gp0_bid/gp0_rid/gp0_rlast assignments above.
        .m_axi_gp0_araddr   (gp0_araddr),
        .m_axi_gp0_arburst  (),
        .m_axi_gp0_arcache  (),
        .m_axi_gp0_arid     (gp0_arid),
        .m_axi_gp0_arlen    (),
        .m_axi_gp0_arlock   (),
        .m_axi_gp0_arprot   (),
        .m_axi_gp0_arqos    (),
        .m_axi_gp0_arready  (gp0_arready),
        .m_axi_gp0_arsize   (),
        .m_axi_gp0_arvalid  (gp0_arvalid),
        .m_axi_gp0_awaddr   (gp0_awaddr),
        .m_axi_gp0_awburst  (),
        .m_axi_gp0_awcache  (),
        .m_axi_gp0_awid     (gp0_awid),
        .m_axi_gp0_awlen    (),
        .m_axi_gp0_awlock   (),
        .m_axi_gp0_awprot   (),
        .m_axi_gp0_awqos    (),
        .m_axi_gp0_awready  (gp0_awready),
        .m_axi_gp0_awsize   (),
        .m_axi_gp0_awvalid  (gp0_awvalid),
        .m_axi_gp0_bid      (gp0_bid),
        .m_axi_gp0_bready   (gp0_bready),
        .m_axi_gp0_bresp    (gp0_bresp),
        .m_axi_gp0_bvalid   (gp0_bvalid),
        .m_axi_gp0_rdata    (gp0_rdata),
        .m_axi_gp0_rid      (gp0_rid),
        .m_axi_gp0_rlast    (gp0_rlast),
        .m_axi_gp0_rready   (gp0_rready),
        .m_axi_gp0_rresp    (gp0_rresp),
        .m_axi_gp0_rvalid   (gp0_rvalid),
        .m_axi_gp0_wdata    (gp0_wdata),
        .m_axi_gp0_wid      (),
        .m_axi_gp0_wlast    (),
        .m_axi_gp0_wready   (gp0_wready),
        .m_axi_gp0_wstrb    (gp0_wstrb),
        .m_axi_gp0_wvalid   (gp0_wvalid)
    );

    // ---- AXI-Lite bridge: ARM PS GP0 → blitter register bus ---------------
    // Translates AXI4-Lite writes from the Cortex-A9s (via PS GP0 port) into
    // the blitter's hwreg-style register strobe (bl_we).  Runs on clk_sys
    // (same domain as the blitter), no CDC needed.
    //
    // Bridge outputs are OR'd with the SALLY CDC path via bl_we_mux above.

    // GP0 AXI-Lite is shared between two slaves at non-overlapping
    // sub-windows of the GP0 mapping:
    //   * xt_gp0_regs (control register file) — offsets $0000-$0FFF (4 KB:
    //     per-device 256-byte blocks; see hdl/xt_gp0_regs.sv address map)
    //   * ROM-init loader (sally_rom_loader) — $1000-$FFFF, with awaddr[15:0]
    //     mapped 1:1 to SALLY rom_addr (only ROM regions $5000+ are ever
    //     loaded, so giving up the low 4 KB — SALLY $0000-$0FFF RAM — is safe)
    //
    // Each slave gates its own *_ready / *_valid / *_resp on its
    // window predicate, so the two never both ack the same write.
    // The OR-mux below merges their responses back onto the GP0
    // signals the PS-BD wrapper sees.
    wire        bl_awready, bl_wready, bl_bvalid;
    wire [1:0]  bl_bresp;
    wire        bl_arready, bl_rvalid;
    wire [1:0]  bl_rresp;
    wire [31:0] bl_rdata;

    wire        rom_awready, rom_wready, rom_bvalid;
    wire [1:0]  rom_bresp;
    wire        rom_arready, rom_rvalid;
    wire [1:0]  rom_rresp;
    wire [31:0] rom_rdata;

    assign gp0_awready = bl_awready | rom_awready;
    assign gp0_wready  = bl_wready  | rom_wready;
    assign gp0_bvalid  = bl_bvalid  | rom_bvalid;
    assign gp0_bresp   = bl_bvalid  ? bl_bresp  : rom_bresp;
    assign gp0_arready = bl_arready | rom_arready;
    assign gp0_rvalid  = bl_rvalid  | rom_rvalid;
    assign gp0_rresp   = bl_rvalid  ? bl_rresp  : rom_rresp;
    assign gp0_rdata   = bl_rvalid  ? bl_rdata  : rom_rdata;

    // ---- Hardware entropy: ring-oscillator TRNG (clk_sys) ------------------
    // 24 free-running ring oscillators, sampled + von-Neumann debiased + LFSR-
    // whitened into a 32-bit word, read at GP0 0x7xx (TRNG_RND).  The OS stirs it
    // into /dev/urandom.  clk_sys is always-on (unlike clk_pix, which the new
    // video-sleep bit can gate), so entropy keeps flowing with the display asleep.
    wire [31:0] trng_word;
    xt_trng #(.N_RO(24), .STAGES(3)) u_trng (
        .clk   (clk_sys),
        .rst_n (rst_sys_n),
        .rnd   (trng_word)
    );

    xt_gp0_regs u_axi_bridge (
        .clk             (clk_sys),
        .rst             (rst_sys),

        .s_axi_awaddr    (gp0_awaddr),
        .s_axi_awvalid   (gp0_awvalid),
        .s_axi_awready   (bl_awready),
        .s_axi_wdata     (gp0_wdata),
        .s_axi_wstrb     (gp0_wstrb),
        .s_axi_wvalid    (gp0_wvalid),
        .s_axi_wready    (bl_wready),
        .s_axi_bresp     (bl_bresp),
        .s_axi_bvalid    (bl_bvalid),
        .s_axi_bready    (gp0_bready),

        .s_axi_araddr    (gp0_araddr),
        .s_axi_arvalid   (gp0_arvalid),
        .s_axi_arready   (bl_arready),
        .s_axi_rdata     (bl_rdata),
        .s_axi_rresp     (bl_rresp),
        .s_axi_rvalid    (bl_rvalid),
        .s_axi_rready    (gp0_rready),

        .bl_addr         (bl_bridge_addr),
        .bl_data         (bl_bridge_data),
        .bl_we           (bl_bridge_we),
        .spr_reg_addr    (spr_reg_addr_a9),
        .spr_reg_data    (spr_reg_data_a9),
        .spr_reg_we      (spr_reg_we_a9),
        .spr_coll_data   (spr_coll_data),
        .bl_busy         (bl_busy),
        .bl_queue_full   (bl_cq_full),
        .bl_pat_blocked  (bl_pat_blocked),
        .bl_seq_counter  (bl_seq_counter),
        .diag_word       (diag_word),
        .diag2_word      (diag2_word),
        .diag3_word      (diag3_word),
        .diag4_word      (diag4_word),
        .diag5_word      (diag5_word),
        .diag6_word      (diag6_word),
        .diag7_word      (diag7_word),
        .diag8_word      (diag8_word),
        .diag9_word      (diag9_word),
        .trng_word       (trng_word),        // ring-oscillator entropy (0x7xx)
        .clock_mult      (eff_clock_mult_sys), // effective $D4CA speed, read back at GP0 offset 0x1E
        .gp0_ctrl        (gp0_ctrl),
        .cmpcfg          (cmpcfg),           // compositor plane arrangement (CTRL 0x18)
        .sallyrst        (sallyrst),         // SALLY reset hold (CTRL 0x1C)
        .xt_unlock_we    (xt_unlock_we),     // A9 unlock write strobe (offset 0x20)
        .xt_unlock_state (xt_unlock),        // effective unlock, read-back at 0x20
        .overlay_base    (overlay_base),     // drag-overlay config (offsets 0x21-0x2F)
        .overlay_x       (overlay_x),
        .overlay_y       (overlay_y),
        .overlay_w       (overlay_w),
        .overlay_h       (overlay_h),
        .overlay_en      (overlay_en),
        .overlay_commit  (overlay_commit),
        .xl_win_x        (xl_win_x),         // XL plane window placement (0x5xx)
        .xl_win_y        (xl_win_y),
        .xl_win_w        (xl_win_w),
        .xl_win_h        (xl_win_h),
        .xl_win_scale    (xl_win_scale),
        .xl_win_en       (xl_win_en),
        .xl_win_we       (xl_win_we),
        .math_evt_data   (math_evt_data),    // math-coprocessor mailbox (0x6xx)
        .math_evt_pop    (math_evt_pop),
        .math_done_word  (math_done_word),
        .math_done_we    (math_done_we),
        .math_stat_word  (math_stat_word),
        // ---- 6502 debugger control/status (0x8xx) ----
        .dbg_halt_tog    (gdbg_halt_tog),
        .dbg_go_tog      (gdbg_go_tog),
        .dbg_step_tog    (gdbg_step_tog),
        .dbg_commit_tog  (gdbg_commit_tog),
        .dbg_cfg         (gdbg_cfg),
        .dbg_bkpt_addr   (gdbg_bkpt),
        .dbg_step_count  (gdbg_stepcnt),
        .dbg_wpc         (gdbg_wpc),
        .dbg_waxys       (gdbg_waxys),
        .dbg_wpsh        (gdbg_wpsh),
        .dbg_stat        (sdbg_stat),
        .dbg_snap_pc     (sdbg_pc),
        .dbg_snap_axys   (sdbg_axys),
        .dbg_snap_psh    (sdbg_psh),
        .dbg_icnt        (sdbg_icnt),
        .dbg_beam        (32'd0),            // reserved (future ANTIC/DLI correlation)
        .dbg_trc_ctrl    (gdbg_trc_ctrl),
        .dbg_trc_idx     (gdbg_trc_idx),
        .dbg_trc_wptr    (sdbg_trc_wptr),
        .dbg_trc_pc      (sdbg_trc_pc),
        .dbg_trc_axys    (sdbg_trc_axys),
        .dbg_trc_p       (sdbg_trc_p)
    );

    // ROM-init AXI-Lite slave — see hdl/sally_rom_loader.sv.
    sally_rom_loader u_rom_loader (
        .clk_sys         (clk_sys),
        .rst_sys         (rst_sys),

        .s_axi_awaddr    (gp0_awaddr),
        .s_axi_awvalid   (gp0_awvalid),
        .s_axi_awready   (rom_awready),
        .s_axi_wdata     (gp0_wdata),
        .s_axi_wstrb     (gp0_wstrb),
        .s_axi_wvalid    (gp0_wvalid),
        .s_axi_wready    (rom_wready),
        .s_axi_bresp     (rom_bresp),
        .s_axi_bvalid    (rom_bvalid),
        .s_axi_bready    (gp0_bready),

        .s_axi_araddr    (gp0_araddr),
        .s_axi_arvalid   (gp0_arvalid),
        .s_axi_arready   (rom_arready),
        .s_axi_rdata     (rom_rdata),
        .s_axi_rresp     (rom_rresp),
        .s_axi_rvalid    (rom_rvalid),
        .s_axi_rready    (gp0_rready),

        .clk_sally       (clk_sally),
        .rst_sally       (rst_sally),
        .rom_addr        (rom_load_addr),
        .rom_data        (rom_load_data),
        .rom_we          (rom_load_we)
    );

    `else
    // ====================================================================
    // Zynq PS HP ports — internal AXI3 stub targets (OOC synthesis)
    // ====================================================================
    // Provides AXI3 slave targets for plane_fetch (HP0, read) and xt_blitter
    // (HP1, write) so the AXI master logic is preserved in OOC synthesis.
    // The stub implements simple always-ready responders; the real PS BD
    // wrapper replaces this for bitstream builds.
    //
    // Extra AXI3 signals (id, cache, lock, prot, qos) are tied to 0 since
    // our PL-side masters don't drive them.

    zynq_ps_hp_stub u_hp_stub (
        .clk                (clk_sys),

        // HP0 — plane_fetch (read-only)
        .s_axi_hp0_araddr   (hp0_araddr[31:0]),
        .s_axi_hp0_arburst  (hp0_arburst[1:0]),
        .s_axi_hp0_arcache  (4'd0),
        .s_axi_hp0_arid     (6'd0),
        .s_axi_hp0_arlen    (hp0_arlen[3:0]),
        .s_axi_hp0_arlock   (2'd0),
        .s_axi_hp0_arprot   (3'd0),
        .s_axi_hp0_arqos    (4'd0),
        .s_axi_hp0_arready  (hp0_arready),
        .s_axi_hp0_arsize   (hp0_arsize[2:0]),
        .s_axi_hp0_arvalid  (hp0_arvalid),
        .s_axi_hp0_awaddr   (hp0_awaddr[31:0]),
        .s_axi_hp0_awburst  (hp0_awburst[1:0]),
        .s_axi_hp0_awcache  (4'd0),
        .s_axi_hp0_awid     (6'd0),
        .s_axi_hp0_awlen    (hp0_awlen[3:0]),
        .s_axi_hp0_awlock   (2'd0),
        .s_axi_hp0_awprot   (3'd0),
        .s_axi_hp0_awqos    (4'd0),
        .s_axi_hp0_awready  (hp0_awready),
        .s_axi_hp0_awsize   (hp0_awsize[2:0]),
        .s_axi_hp0_awvalid  (hp0_awvalid),
        .s_axi_hp0_bid      (),
        .s_axi_hp0_bready   (hp0_bready),
        .s_axi_hp0_bresp    (),
        .s_axi_hp0_bvalid   (hp0_bvalid),
        .s_axi_hp0_rdata    (hp0_rdata),
        .s_axi_hp0_rid      (),
        .s_axi_hp0_rlast    (hp0_rlast),
        .s_axi_hp0_rready   (hp0_rready),
        .s_axi_hp0_rresp    (),
        .s_axi_hp0_rvalid   (hp0_rvalid),
        .s_axi_hp0_wdata    (hp0_wdata),
        .s_axi_hp0_wid      (6'd0),
        .s_axi_hp0_wlast    (hp0_wlast),
        .s_axi_hp0_wready   (hp0_wready),
        .s_axi_hp0_wstrb    (hp0_wstrb),
        .s_axi_hp0_wvalid   (hp0_wvalid),

        // HP1 — xt_blitter (read/write)
        .s_axi_hp1_araddr   (hp1_araddr[31:0]),
        .s_axi_hp1_arburst  (hp1_arburst[1:0]),
        .s_axi_hp1_arcache  (4'd0),
        .s_axi_hp1_arid     (6'd0),
        .s_axi_hp1_arlen    (hp1_arlen[3:0]),
        .s_axi_hp1_arlock   (2'd0),
        .s_axi_hp1_arprot   (3'd0),
        .s_axi_hp1_arqos    (4'd0),
        .s_axi_hp1_arready  (hp1_arready),
        .s_axi_hp1_arsize   (hp1_arsize[2:0]),
        .s_axi_hp1_arvalid  (hp1_arvalid),
        .s_axi_hp1_awaddr   (hp1_awaddr[31:0]),
        .s_axi_hp1_awburst  (hp1_awburst[1:0]),
        .s_axi_hp1_awcache  (4'd0),
        .s_axi_hp1_awid     (6'd0),
        .s_axi_hp1_awlen    (hp1_awlen[3:0]),
        .s_axi_hp1_awlock   (2'd0),
        .s_axi_hp1_awprot   (3'd0),
        .s_axi_hp1_awqos    (4'd0),
        .s_axi_hp1_awready  (hp1_awready),
        .s_axi_hp1_awsize   (hp1_awsize[2:0]),
        .s_axi_hp1_awvalid  (hp1_awvalid),
        .s_axi_hp1_bid      (),
        .s_axi_hp1_bready   (hp1_bready),
        .s_axi_hp1_bresp    (),
        .s_axi_hp1_bvalid   (hp1_bvalid),
        .s_axi_hp1_rdata    (hp1_rdata),
        .s_axi_hp1_rid      (),
        .s_axi_hp1_rlast    (hp1_rlast),
        .s_axi_hp1_rready   (hp1_rready),
        .s_axi_hp1_rresp    (),
        .s_axi_hp1_rvalid   (hp1_rvalid),
        .s_axi_hp1_wdata    (hp1_wdata),
        .s_axi_hp1_wid      (6'd0),
        .s_axi_hp1_wlast    (hp1_wlast),
        .s_axi_hp1_wready   (hp1_wready),
        .s_axi_hp1_wstrb    (hp1_wstrb),
        .s_axi_hp1_wvalid   (hp1_wvalid),

        // HP3 — XL plane read: plane_fetch1 (read-only; writeback is on HP2)
        .s_axi_hp3_araddr   (hp3_araddr[31:0]),
        .s_axi_hp3_arburst  (hp3_arburst[1:0]),
        .s_axi_hp3_arcache  (4'd0),
        .s_axi_hp3_arid     (6'd0),
        .s_axi_hp3_arlen    (hp3_arlen[3:0]),
        .s_axi_hp3_arlock   (2'd0),
        .s_axi_hp3_arprot   (3'd0),
        .s_axi_hp3_arqos    (4'd0),
        .s_axi_hp3_arready  (hp3_arready),
        .s_axi_hp3_arsize   (hp3_arsize[2:0]),
        .s_axi_hp3_arvalid  (hp3_arvalid),
        .s_axi_hp3_awaddr   (32'd0),
        .s_axi_hp3_awburst  (2'd0),
        .s_axi_hp3_awcache  (4'd0),
        .s_axi_hp3_awid     (6'd0),
        .s_axi_hp3_awlen    (4'd0),
        .s_axi_hp3_awlock   (2'd0),
        .s_axi_hp3_awprot   (3'd0),
        .s_axi_hp3_awqos    (4'd0),
        .s_axi_hp3_awready  (),
        .s_axi_hp3_awsize   (3'd0),
        .s_axi_hp3_awvalid  (1'b0),
        .s_axi_hp3_bid      (),
        .s_axi_hp3_bready   (1'b0),
        .s_axi_hp3_bresp    (),
        .s_axi_hp3_bvalid   (),
        .s_axi_hp3_rdata    (hp3_rdata),
        .s_axi_hp3_rid      (),
        .s_axi_hp3_rlast    (hp3_rlast),
        .s_axi_hp3_rready   (hp3_rready),
        .s_axi_hp3_rresp    (),
        .s_axi_hp3_rvalid   (hp3_rvalid),
        .s_axi_hp3_wdata    (64'd0),
        .s_axi_hp3_wid      (6'd0),
        .s_axi_hp3_wlast    (1'b0),
        .s_axi_hp3_wready   (),
        .s_axi_hp3_wstrb    (8'd0),
        .s_axi_hp3_wvalid   (1'b0)
    );
    // Non-BD stub has no HP2 port; ack the writeback's HP2 write so it doesn't
    // wedge in a non-BD (sim/lint) build.  The real bit flow (USE_PS_BD) drives
    // these from the PS HP2 slave.
    assign hp2_awready = 1'b1;
    assign hp2_wready  = 1'b1;
    assign hp2_bvalid  = 1'b1;
    // Drag-overlay HP2 read channel: the OOC stub has no HP2 port, so tie the
    // read inputs to benign constants (no functional read in OOC).
    assign hp2_arready = 1'b1;
    assign hp2_rvalid  = 1'b0;
    assign hp2_rlast   = 1'b0;
    assign hp2_rdata   = 64'd0;
    `endif

endmodule

`default_nettype wire
