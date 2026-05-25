// fpga_xt_top.sv — Phase 1 top-level: SALLY + ANTIC integrated on Zynq-7020.
//
// Clock domains:
//   clk_sally (100 MHz) — SALLY core, sally_mem, banked_axi_reader
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
//   from sally_mem's second BRAM port via a lightweight bram_shim that
//   replaces the Efinix-specific hyperram_shim.
//
// Build variants:
//   synth:  fpga_xt_top — standalone synth probe (out_of_context)
//   impl:   fpga_xt_top — full place+route (needs Zynq PS block)
//   bit:    full bitstream (needs Zynq PS block + board)

`default_nettype none

module fpga_xt_top #(
    // Bring-up Phase 2 build switch: when 1, fb_scanout overrides the
    // framebuffer read path with an on-fabric 8-colour-bar test pattern
    // so HDMI can be verified before DDR3 / AXI HP is functional.
    // Default 0 = normal operation.  See docs/bring-up.md.
    parameter bit SCANOUT_TEST_PATTERN = 1'b0,
    // Boot blocker #4 (prompts/task-0004): display-source select for the
    // RGB pins.
    //   0 = fb_scanout -> sprite_engine (1080p60 DDR3 framebuffer; GEM/native)
    //   1 = legacy ANTIC RGB path
    // Default 0 preserves the validated 1080p output.  NOTE: the ANTIC path
    // is NOT yet 1080p-correct — antic_top's hdmi_out raster is 800x600 and
    // scan_out only spans 768 native px (384 Atari px * 2), so mode 1 will
    // produce a valid picture only once the 1080p pillarbox upscaler lands
    // (see prompts/task-0004 + docs/TODO.txt).  The mux below is the
    // infrastructure that lets that source be selected.
    parameter bit LEGACY_VIDEO = 1'b0
) (
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
    //     CLKOUT0 /12 → 100.000 MHz clk_sally
    //                    (Phase 1a fmax-limited target; Arlet ALU carry
    //                    chain caps us here at ~107 MHz)
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

    // ---- MMCM #1: 100 MHz (clk_sally) + 133 MHz (clk_sys) from 50 MHz reference ---
    wire mmcm1_fb_in, mmcm1_fb_out;
    wire clk_sally_unbuf, clk_sys_unbuf;
    wire mmcm1_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD    (20.000),
        // Z7020 Artix-7 production config: sally 100 MHz, sys 150 MHz.
        // VCO = 1200 MHz (MULT_F=24); CLKOUT0_F=12 → 100 MHz sally,
        // CLKOUT1=8 → 150 MHz sys.
        //
        // Z7030 Kintex-7 fabric headroom note (probed 2026-05-18): same
        // logic closes timing at sally 135 MHz on -2 Kintex (WNS +0.079
        // ns post-route) — a 35% sally speedup if/when a Z7030 board
        // becomes worthwhile.  Limit is Arlet's CPU pipeline (11 logic
        // levels from BRAM read through IR/ALU to BRAM write).
        .CLKFBOUT_MULT_F  (24.000),
        .DIVCLK_DIVIDE    (1),
        .CLKOUT0_DIVIDE_F (12.000),
        .CLKOUT1_DIVIDE   (8),
        .BANDWIDTH        ("OPTIMIZED")
    ) u_mmcm1 (
        .CLKIN1   (clk_50),
        .CLKFBIN  (mmcm1_fb_in),
        .CLKFBOUT (mmcm1_fb_out),
        .CLKOUT0  (clk_sally_unbuf),
        .CLKOUT1  (clk_sys_unbuf),
        .CLKOUT2  (),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .RST      (~rst_n),
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
        .CLKIN1   (clk_50),
        .CLKFBIN  (mmcm2_fb_in),
        .CLKFBOUT (mmcm2_fb_out),
        .CLKOUT0  (clk_pix_unbuf),
        .CLKOUT1  (),
        .CLKOUT2  (),
        .CLKOUT3  (),
        .CLKOUT4  (),
        .CLKOUT5  (),
        .CLKOUT6  (),
        .RST      (~rst_n),
        .PWRDWN   (1'b0),
        .LOCKED   (mmcm2_locked)
    );

    BUFG u_bufg_fb2 (.I(mmcm2_fb_out),  .O(mmcm2_fb_in));
    BUFG u_bufg_pix (.I(clk_pix_unbuf), .O(clk_pix));

    // ---- Per-domain reset synchronisers ---------------------------------
    // Async-assert / sync-deassert.  Reset stays held until rst_n is high
    // AND both MMCMs are locked.
    wire rst_release_n = rst_n & mmcm1_locked & mmcm2_locked;

    logic [2:0] rst_sally_pipe, rst_sys_pipe, rst_pix_pipe;
    always_ff @(posedge clk_sally or negedge rst_release_n) begin
        if (!rst_release_n) rst_sally_pipe <= 3'b111;
        else                rst_sally_pipe <= {rst_sally_pipe[1:0], 1'b0};
    end
    always_ff @(posedge clk_sys or negedge rst_release_n) begin
        if (!rst_release_n) rst_sys_pipe <= 3'b111;
        else                rst_sys_pipe <= {rst_sys_pipe[1:0], 1'b0};
    end
    always_ff @(posedge clk_pix or negedge rst_release_n) begin
        if (!rst_release_n) rst_pix_pipe <= 3'b111;
        else                rst_pix_pipe <= {rst_pix_pipe[1:0], 1'b0};
    end
    wire rst_sally   = rst_sally_pipe[2];
    wire rst_sys     = rst_sys_pipe[2];
    wire rst_pix     = rst_pix_pipe[2];
    wire rst_sally_n = ~rst_sally;
    wire rst_sys_n   = ~rst_sys;

    // ====================================================================
    // SALLY + memory (runs on clk_sally)
    // ====================================================================
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_din, cpu_dout;
    wire        cpu_rw;
    wire        sally_rdy;

    // sally_clock wires
    // phi2_tick gating is bypassed at clock_mult >= 2 (we run at 68); the
    // strobe input is still required by the port, so tie it off.  antic_top
    // computes its own phi2_tick internally for its consumers (vbeam etc.).
    wire        phi2_tick = 1'b0;
    wire        halt_n_sally;      // /HALT after CDC (if needed)
    wire        wsync_rdy_n;       // from ANTIC WSYNC
    wire        mem_busy_n;        // from sally_mem (1 = ready)
    wire        sally_step;

    // Register read-back CDC (boot blocker #3, prompts/task-0003) —
    // declared early so sally_clock can fold hwreg_rd_busy into its stall.
    // Driven by u_hwreg_rd_cdc further down.
    wire        cdc_bus_read;      // clk_sys: CDC owns the ANTIC bus for a read
    wire [15:0] cdc_bus_addr;      // clk_sys: read address presented to ANTIC
    wire [7:0]  cdc_rd_data;       // clk_sally: returned register byte
    wire        hwreg_rd_busy;     // clk_sally: stall SALLY during the round-trip

    // Bank-select state (from SALLY zero-page snoop)
    wire [7:0]  cpu_code_bank, cpu_data_bank;

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

    // AXI bus to DDR3 (banked-window port) — tied off in Phase 2a/b since
    // the SALLY core runs entirely from BRAM; banked_axi_reader is unused.
    // Outputs from sally_mem left open; inputs tied to 0 (slave never ready).
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
    wire        axi_arready = 1'b0;
    wire [63:0] axi_rdata   = 64'd0;
    wire        axi_rvalid  = 1'b0;
    wire        axi_rlast   = 1'b0;
    wire        axi_awready = 1'b0;
    wire        axi_wready  = 1'b0;
    wire        axi_bvalid  = 1'b0;

    // ---- AXI HP port connections — routed through internal HP stub ---------
    // HP0 — fb_scanout (read-only AXI4 master → AXI3 slave)
    // Note: fb_scanout uses 8-bit arlen (AXI4); AXI3 truncates to lower 4 bits.
    wire [31:0] hp0_araddr;
    wire [7:0]  hp0_arlen;     // 8-bit from fb_scanout; truncated to 4-bit at stub
    wire [2:0]  hp0_arsize;
    wire [1:0]  hp0_arburst;
    wire        hp0_arvalid;
    wire        hp0_arready;
    wire [63:0] hp0_rdata;
    wire        hp0_rvalid;
    wire        hp0_rlast;
    wire        hp0_rready;
    // HP0 write channel — tied (fb_scanout is read-only)
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

    // ANTIC's BRAM read port — driven by antic_top's u_bram_shim and
    // serviced by sally_mem's second BRAM port (clk_sys side).  SALLY
    // writes propagate naturally through sally_mem; ANTIC sees the
    // same state without a shadow memory.
    wire [15:0] antic_bram_addr;
    wire [7:0]  antic_bram_rdata;

    // PORTB ($D301) from PIA — controls ROM vs banked/BRAM visibility.
    wire [7:0]  portb_q;

    // Keyboard inject (boot blocker #5, prompts/task-0005): the PS writes an
    // Atari KBCODE byte via the GP0 blitter-register bridge ($D4CF); that
    // pulses ANTIC's kbd_event into POKEY (loads KBCODE + raises the
    // keyboard IRQ).  Bridge and antic_top both run on clk_sys, so no CDC.
    logic       kbd_event_valid_q;
    logic [7:0] kbd_event_code_q;

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
    // CLOCK_MULT=68 gives ~121 MHz from 1.79 MHz phi2.
    // /HALT is bypassed at CLOCK_MULT>=2, so halt_n is tied high.
    // wsync_rdy_n comes from ANTIC via CDC.
    // busy_n comes from sally_mem (1 = ready, 0 = cache miss stall).

    sally_clock #(
        .BASE_DIV (68)
    ) u_sally_clock (
        .clk           (clk_sally),
        .rst           (rst_sally),
        .phi2_tick     (phi2_tick),
        .clock_mult    (8'd68),
        .halt_n        (1'b1),         // bypassed at CLOCK_MULT>=2
        .wsync_rdy_n   (wsync_rdy_n),
        .busy_n        (~(mem_busy_n | hwreg_rd_busy)),  // stall on sally_mem cache miss OR hwreg-read CDC round-trip
        .sally_rdy     (sally_rdy),
        .sally_step    (sally_step)
    );

    // ---- sally_core ------------------------------------------------------
    wire        cpu_stack_op;
    wire [3:0]  cpu_s_high;

    sally_core u_sally_core (
        .clk      (clk_sally),
        .rst      (rst_sally),
        .addr     (cpu_addr),
        .data_in  (cpu_din),
        .data_out (cpu_dout),
        .rw       (cpu_rw),
        .rdy      (sally_rdy),
        .irq_n    (irq_n_sync),      // from ANTIC via CDC
        .nmi_n    (nmi_n_sync),      // from ANTIC via CDC
        .stack_op (cpu_stack_op),    // SALLY Stage A: 12-bit stack push/pull cycle
        .s_high   (cpu_s_high)       // SALLY Stage A: high 4 bits of SP
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
        .DDR3_BANKED_BASE (32'h2000_0000),
        .DDR3_DATA_BASE   (32'h2040_0000)
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
        .dma_rdata   (antic_bram_rdata)
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
    wire        hwreg_cdc_rd   = hwreg_page_rd & ~is_blitter_reg;

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
        .bus_rdata (antic_bus_data_out)   // ANTIC's combinational read mux
    );

    // ====================================================================
    // CDC: status signals ANTIC → SALLY
    // ====================================================================
    wire nmi_n_antic, irq_n_antic, halt_n_antic, rdy_n_antic;
    wire nmi_n_sync, irq_n_sync;

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

    // ====================================================================
    // ANTIC pipeline (runs on clk_sys / same clock for Phase 1a)
    // ====================================================================
    // ANTIC reads display data from hyperram_shim (BRAM-backed on Zynq,
    // replaces the Efinix HyperRAM Controller).  SALLY writes to main
    // memory propagate to the shim via snoop_we_screen inside antic_top.
    wire [7:0]  antic_bus_data_out;
    wire        antic_bus_data_oe;
    wire        antic_nmi_n, antic_halt_n, antic_rdy_n, antic_irq_n;

    // ANTIC-side phi2 — generated from clk by antic_top internally.
    // We just provide the phi2_tick strobe.  antic_top generates its
    // own phi2 from clk_bus using BASE_DIV=68 (adjusted from 90 for
    // our clock rate).
    //
    // For the Phase 1a single-clock integration, antic_top gets the
    // raw clock.  Its internal BASE_DIV parameter needs to match
    // our sally_clock BASE_DIV.

    wire [4:0] antic_rgb_r;
    wire [5:0] antic_rgb_g;
    wire [4:0] antic_rgb_b;
    wire       antic_rgb_hsync, antic_rgb_vsync, antic_rgb_de, antic_rgb_pixclk;

    antic_top #(
        .POKEY_CLK_BUS_HZ (150_000_000),    // clk_sys nominal (150 MHz)
        .LEGACY_RP        (1'b1)             // keep RP interfaces active
    ) u_antic_top (
        .clk_bus            (clk_sys),
        .clk_pix            (clk_pix),
        .rst_n              (rst_sys_n),
        .bus_addr           (bus_addr_antic),
        .bus_data_in        (bus_data_in_antic),
        .bus_rw             (bus_rw_antic),
        .d0xx_n             (d0xx_n_antic),
        .d4xx_n             (d4xx_n_antic),
        .bus_data_out       (antic_bus_data_out),
        .bus_data_oe        (antic_bus_data_oe),
        .nmi_n              (antic_nmi_n),
        .halt_n             (antic_halt_n),
        .rdy_n              (antic_rdy_n),
        .irq_n              (antic_irq_n),
        .bus_pbi_in_status_o(),
        .audio_l0(), .audio_l1(), .audio_l2(), .audio_l3(),
        .audio_r0(), .audio_r1(), .audio_r2(), .audio_r3(),
        .audio_present(), .audio_flat(), .audio_block_start(),
        .audio_frame_ready(),
        .dma_addr_o         (),
        .dma_rw_o           (),
        .dma_oe             (),
        .clk_bit            (1'b0),
        .tmds_r             (),
        .tmds_g             (),
        .tmds_b             (),
        .tmds_clk           (),
        .rgb_r_o            (antic_rgb_r),
        .rgb_g_o            (antic_rgb_g),
        .rgb_b_o            (antic_rgb_b),
        .rgb_hsync_o        (antic_rgb_hsync),
        .rgb_vsync_o        (antic_rgb_vsync),
        .rgb_de_o           (antic_rgb_de),
        .rgb_pixclk_o       (antic_rgb_pixclk),
        .diag_wsync_overdue_count(),
        .kbd_event_valid    (kbd_event_valid_q),
        .kbd_event_code     (kbd_event_code_q),
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
    // DDR3 framebuffer scan-out — Phase 2a native / GEM-mode video path
    // ====================================================================
    // fb_scanout owns its own raster (vbeam at 1080p60), its own AXI HP
    // read master, and a ping-pong line buffer fed from DDR3.  For Phase
    // 2a the scan-out output goes straight to the rgb_* pads, replacing
    // the legacy ANTIC chain at the pin level (ANTIC's pipeline still
    // synthesises and runs but its rgb_o outputs are observed only — a
    // future mode mux will wire it in for legacy-Atari mode at 1080p
    // with a 5× pillarbox upscaler).

    wire [4:0]  fb_rgb_r;
    wire [5:0]  fb_rgb_g;
    wire [4:0]  fb_rgb_b;
    wire        fb_rgb_hsync, fb_rgb_vsync, fb_rgb_de, fb_rgb_pixclk;
    wire [11:0] fb_h_count, fb_v_count;
    wire        fb_line_start, fb_frame_start;

    fb_scanout #(
        .FB_BASE      (32'h3000_0000),
        .H_ACTIVE     (1920),
        .H_FRONT_PORCH(88),
        .H_SYNC_WIDTH (44),
        .H_BACK_PORCH (148),
        .V_ACTIVE     (1080),
        .V_FRONT_PORCH(4),
        .V_SYNC_WIDTH (5),
        .V_BACK_PORCH (36),
        .TEST_PATTERN (SCANOUT_TEST_PATTERN)
    ) u_fb_scanout (
        .clk_sys         (clk_sys),
        .rst_sys         (rst_sys),
        .clk_pix         (clk_pix),
        .rst_pix         (rst_pix),
        .enable          (1'b1),
        .m_axi_araddr    (hp0_araddr),
        .m_axi_arlen     (hp0_arlen),
        .m_axi_arsize    (hp0_arsize),
        .m_axi_arburst   (hp0_arburst),
        .m_axi_arvalid   (hp0_arvalid),
        .m_axi_arready   (hp0_arready),
        .m_axi_rdata     (hp0_rdata),
        .m_axi_rvalid    (hp0_rvalid),
        .m_axi_rlast     (hp0_rlast),
        .m_axi_rready    (hp0_rready),
        .rgb_r           (fb_rgb_r),
        .rgb_g           (fb_rgb_g),
        .rgb_b           (fb_rgb_b),
        .rgb_hsync       (fb_rgb_hsync),
        .rgb_vsync       (fb_rgb_vsync),
        .rgb_de          (fb_rgb_de),
        .rgb_pixclk      (fb_rgb_pixclk),
        .h_count_o       (fb_h_count),
        .v_count_o       (fb_v_count),
        .line_start_o    (fb_line_start),
        .frame_start_o   (fb_frame_start)
    );

    // ====================================================================
    // sprite_engine — sprite compositor between fb_scanout and SOM RGB pins
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
    wire sprite_reg_we = antic_we_q
                        && (bus_addr_antic_q[15:8] == 8'hD4)
                        && ((bus_addr_antic_q[7:4] == 4'hA)
                            || (bus_addr_antic_q[7:4] == 4'hD));
    wire [7:0] sprite_reg_rdata_unused;

    sprite_engine u_sprite_engine (
        .clk_fetch     (clk_sys),
        .clk_pix       (clk_pix),
        .rst           (rst_pix),

        .h_count       (fb_h_count),
        .v_count       (fb_v_count),
        .line_start    (fb_line_start),
        .frame_start   (fb_frame_start),

        .reg_we        (sprite_reg_we),
        .reg_addr      (bus_addr_antic_q[7:0]),
        .reg_wdata     (bus_data_in_antic_q),
        .reg_rdata     (sprite_reg_rdata_unused),

        .fb_pixel      ({fb_rgb_r, fb_rgb_g, fb_rgb_b}),
        .fb_de         (fb_rgb_de),
        .fb_hsync      (fb_rgb_hsync),
        .fb_vsync      (fb_rgb_vsync),

        .rgb_r         (spr_rgb_r),
        .rgb_g         (spr_rgb_g),
        .rgb_b         (spr_rgb_b),
        .rgb_de        (spr_rgb_de),
        .rgb_hsync     (spr_rgb_hsync),
        .rgb_vsync     (spr_rgb_vsync),

        // AXI HP2 master — dangled for the scaffold.  When the line
        // fetcher lands these connect to the PS BD's M_AXI_HP2 (bit
        // flow) or the OOC stub.
        .m_axi_araddr  (),
        .m_axi_arlen   (),
        .m_axi_arsize  (),
        .m_axi_arburst (),
        .m_axi_arvalid (),
        .m_axi_arready (1'b0),
        .m_axi_rdata   (64'd0),
        .m_axi_rvalid  (1'b0),
        .m_axi_rlast   (1'b0),
        .m_axi_rready  ()
    );

    // ---- Display-source mux (boot blocker #4) ----------------------------
    // Selects which video source drives the RGB pins.  Both sources are in
    // the clk_pix domain.  Mode 0 (fb_scanout -> sprite_engine, 1080p60) is
    // the validated default and preserves current behaviour.  Mode 1 routes
    // the legacy ANTIC chain to the pins — valid only once that chain is
    // re-rastered to 1080p with the pillarbox upscaler (see the LEGACY_VIDEO
    // parameter note above).
    assign rgb_r      = LEGACY_VIDEO ? antic_rgb_r      : spr_rgb_r;
    assign rgb_g      = LEGACY_VIDEO ? antic_rgb_g      : spr_rgb_g;
    assign rgb_b      = LEGACY_VIDEO ? antic_rgb_b      : spr_rgb_b;
    assign rgb_hsync  = LEGACY_VIDEO ? antic_rgb_hsync  : spr_rgb_hsync;
    assign rgb_vsync  = LEGACY_VIDEO ? antic_rgb_vsync  : spr_rgb_vsync;
    assign rgb_de     = LEGACY_VIDEO ? antic_rgb_de     : spr_rgb_de;
    assign rgb_pixclk = LEGACY_VIDEO ? antic_rgb_pixclk : fb_rgb_pixclk;

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
    `else
    wire        bl_bridge_we   = 1'b0;
    wire [5:0]  bl_bridge_addr = 6'd0;
    wire [7:0]  bl_bridge_data = 8'd0;
    `endif

    // Reconstruct full 16-bit bus_addr from bridge's 6-bit register addr.
    //   bl_bridge_addr[5] = 1 → $D4Bx page, bl_bridge_addr[5] = 0 → $D4Cx page
    //   bus_addr[7:4] = 4'b1011 for $D4Bx, 4'b1100 for $D4Cx
    //   bus_addr[3:0] = register index within page
    wire [15:0] bridge_bus_addr;
    assign bridge_bus_addr[15:8] = 8'hD4;
    assign bridge_bus_addr[7:4]  = bl_bridge_addr[5] ? 4'b1011 : 4'b1100;
    assign bridge_bus_addr[3:0]  = bl_bridge_addr[3:0];

    // Keyboard-inject decode (boot blocker #5).  A PS write through the GP0
    // bridge to $D4CF carries an Atari KBCODE byte; pulse kbd_event for one
    // clk_sys cycle.  The blitter only decodes $D4Bx and the sprite engine
    // $D4Ax/$D4Dx, so $D4CF is free.  Gated on bl_bridge_we (PS-originated)
    // so a stray SALLY write can't fake a keypress.  ASCII->KBCODE mapping
    // is done PS-side.  (OOC build: bl_bridge_we is tied 0, so this is inert.)
    wire kbd_inject_we = bl_bridge_we && (bridge_bus_addr == 16'hD4CF);
    always_ff @(posedge clk_sys) begin
        if (rst_sys) begin
            kbd_event_valid_q <= 1'b0;
            kbd_event_code_q  <= 8'h00;
        end else begin
            kbd_event_valid_q <= kbd_inject_we;          // 1-cycle pulse
            if (kbd_inject_we) kbd_event_code_q <= bl_bridge_data;
        end
    end

    // Mux: bridge takes priority when bl_bridge_we is asserted.
    // Both sources run on clk_sys and produce single-cycle strobes.
    wire        bl_we_mux   = bl_bridge_we | antic_we_q;
    wire [15:0] bl_addr_mux = bl_bridge_we ? bridge_bus_addr : bus_addr_antic_q;
    wire [7:0]  bl_data_mux = bl_bridge_we ? bl_bridge_data  : bus_data_in_antic_q;

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
    // The done flag is observed-only for now — the fb_scanout drives its
    // pixel clock and sync signals regardless, and the SiI9022A will begin
    // outputting valid TMDS once its PLL locks to the programmed pixel rate.

    wire hdmi_cfg_done;

    hdmi_config u_hdmi_config (
        .clk_i       (clk_sys),
        .rst_n_i     (rst_sys_n),
        .sda_io      (hdmi_sda),
        .scl_io      (hdmi_scl),
        .done_o      (hdmi_cfg_done)
    );

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
                            ? bl_seq_counter_sally[15:8]
                      : is_blitter_reg
                            ? 8'hFF              // other blitter regs: no readback
                      : cdc_rd_data;             // ANTIC/GTIA/POKEY/PIA via read-back CDC

    // ---- Bring-up debug LEDs --------------------------------------------
    // Z-Turn Z7-Lite carrier exposes 3 LEDs as dbg[2:0] (Y16 / Y17 / R14).
    // Bit 3 has no pin and is just there to round out the byte.
    //
    //   dbg[0] = heartbeat from clk_50 — proves the bitstream loaded and
    //            the on-board oscillator is reaching the PL.  ~1.5 Hz
    //            blink (50 MHz / 2^25).  Runs free of rst, so it lights
    //            up the moment the bitstream loads — even if rst_n is
    //            stuck low or both MMCMs fail to lock.
    //   dbg[1] = PLL lock — both MMCMs locked.  Solid on once the SOM is
    //            stable; flickers / off = clock subsystem trouble.  Cross
    //            from clk_50 with a tiny 2-FF synchroniser since the
    //            LOCKED outputs are async to clk_50.
    //   dbg[2] = bl_busy — handy ongoing-dev signal kept across bring-up;
    //            the blitter pulses this whenever a command is in flight.
    //   dbg[3] = unused (no pin on the carrier).
    //
    // Bring-up Phase 1: heartbeat blinks, PLL-lock LED solid.  See
    // docs/bring-up.md.
    reg [24:0] heartbeat_cnt = '0;
    always_ff @(posedge clk_50) heartbeat_cnt <= heartbeat_cnt + 1'b1;

    reg [1:0] pll_lock_sync = '0;
    always_ff @(posedge clk_50)
        pll_lock_sync <= {pll_lock_sync[0], mmcm1_locked & mmcm2_locked};

    assign dbg = {1'b0, bl_busy, pll_lock_sync[1], heartbeat_cnt[24]};

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
    // the PL fabric.  HP0 serves fb_scanout (framebuffer read), HP1
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
    // Extra AXI3 signals — tie-offs for master inputs (bridge doesn't drive)
    wire [11:0] gp0_bid;
    wire [11:0] gp0_rid;
    wire        gp0_rlast;
    assign gp0_bid   = 12'd0;
    assign gp0_rid   = 12'd0;
    assign gp0_rlast = 1'b1;

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
        .s_axi_gp0_aclk     (clk_sys),
        .m_axi_hp0_araddr   (hp0_araddr[31:0]),
        .m_axi_hp0_arburst  (hp0_arburst[1:0]),
        .m_axi_hp0_arcache  (4'd0),
        .m_axi_hp0_arid     (6'd0),
        .m_axi_hp0_arlen    (hp0_arlen[3:0]),
        .m_axi_hp0_arlock   (2'd0),
        .m_axi_hp0_arprot   (3'd0),
        .m_axi_hp0_arqos    (4'd0),
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

        // GP0 — ARM PS AXI3 master → PL bridge (blitter register writes).
        // Extra AXI3 signals not used by the AXI4-Lite bridge are left
        // unconnected on the PS output side; bridge input tie-offs are
        // driven via gp0_bid/gp0_rid/gp0_rlast assignments above.
        .m_axi_gp0_araddr   (gp0_araddr),
        .m_axi_gp0_arburst  (),
        .m_axi_gp0_arcache  (),
        .m_axi_gp0_arid     (),
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
        .m_axi_gp0_awid     (),
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
    // sub-windows of the 64 KB GP0 mapping:
    //   * blitter bridge — offsets $0000-$001F (32 bytes)
    //   * ROM-init loader (sally_rom_loader) — everything else, with
    //     awaddr[15:0] mapped 1:1 to SALLY rom_addr
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

    axi_blitter_bridge u_axi_bridge (
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
        .bl_busy         (bl_busy),
        .bl_queue_full   (bl_cq_full),
        .bl_pat_blocked  (bl_pat_blocked),
        .bl_seq_counter  (bl_seq_counter)
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
    // Provides AXI3 slave targets for fb_scanout (HP0, read) and xt_blitter
    // (HP1, write) so the AXI master logic is preserved in OOC synthesis.
    // The stub implements simple always-ready responders; the real PS BD
    // wrapper replaces this for bitstream builds.
    //
    // Extra AXI3 signals (id, cache, lock, prot, qos) are tied to 0 since
    // our PL-side masters don't drive them.

    zynq_ps_hp_stub u_hp_stub (
        .clk                (clk_sys),

        // HP0 — fb_scanout (read-only)
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
        .s_axi_hp1_wvalid   (hp1_wvalid)
    );
    `endif

endmodule

`default_nettype wire
