// fpga_xt_top.sv — Phase 1 top-level: SALLY + ANTIC integrated on Zynq-7020.
//
// Clock domains:
//   clk_sally (121 MHz) — SALLY core, sally_mem, banked_axi_reader
//   clk_sys   (162 MHz) — ANTIC pipeline (DL parser, GTIA, POKEY, compositor)
//   clk_pix   (25.175 MHz) — RGB565 pixel output to SiI9022A HDMI transmitter
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

    // ---- AXI4 burst master to PS DDR3 (banked-window port) ----------------
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    input  wire        m_axi_rlast,
    output wire        m_axi_rready,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [7:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    // ---- Debug UART (through PS MIO) --------------------------------------
    output wire        uart_tx,
    input  wire        uart_rx
);

    // ====================================================================
    // Clock generation
    // ====================================================================
    // Phase 1: use generated clocks via PLL.  For synth-probe (out_of_context),
    // the XDC creates virtual clocks; for impl, the PLL is instantiated or
    // we use the PS's FCLK outputs.
    //
    // Target frequencies:
    //   clk_sally: 121.7045 MHz (= 68 × 1.7897725 MHz NTSC phi2)
    //   clk_sys:   162 MHz (or whatever the PLL can produce)
    //   clk_pix:   25.175 MHz (640×480 VESA)
    //
    // For the first pass, clk_sally and clk_sys are shorted (single
    // 121 MHz domain).  Clock split comes in Phase 1b.

    wire clk = clk_50;   // placeholder: replace with PLL output
    wire clk_pix_int;     // placeholder: PLL-generated pixel clock

    // For now, use the 50 MHz input directly as a stand-in for both clocks.
    // The XDC overrides these with the real target frequencies for timing
    // analysis; the physical PLL instantiation lands when we have a board.
    assign clk_pix_int = clk_50;

    // ---- Reset synchroniser ----------------------------------------------
    logic rst_sync_ff0, rst_sync_ff1;
    wire  rst;
    always_ff @(posedge clk) begin
        rst_sync_ff0 <= ~rst_n;
        rst_sync_ff1 <= rst_sync_ff0;
    end
    assign rst = rst_sync_ff1;

    // ====================================================================
    // SALLY + memory (runs on clk_sally)
    // ====================================================================
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_din, cpu_dout;
    wire        cpu_rw;
    wire        sally_rdy;

    // sally_clock wires
    wire        phi2_tick;
    wire        halt_n_sally;      // /HALT after CDC (if needed)
    wire        wsync_rdy_n;       // from ANTIC WSYNC
    wire        mem_busy_n;        // from sally_mem (1 = ready)
    wire        sally_step;

    // Bank-select state (from SALLY zero-page snoop)
    wire [7:0]  cpu_code_bank, cpu_data_bank;
    wire [7:0]  cpu_regc_bank_lo, cpu_regc_bank_hi;

    // ANTIC-view bank select state (from chiplet-ext registers)
    wire [7:0]  antic_code_bank, antic_data_bank;
    wire [7:0]  antic_regc_bank_lo, antic_regc_bank_hi;
    wire        view_is_antic;

    // Hardware register passthrough (SALLY→ANTIC bus via CDC FIFO)
    wire [15:0] hwreg_addr;
    wire [7:0]  hwreg_din;
    wire        hwreg_we;
    wire [7:0]  hwreg_dout;

    // AXI bus to DDR3 (banked-window port)
    wire [31:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    wire        axi_arvalid, axi_arready;
    wire [63:0] axi_rdata;
    wire        axi_rvalid, axi_rlast;
    wire        axi_rready;
    wire [31:0] axi_awaddr;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;
    wire        axi_awvalid, axi_awready;
    wire [63:0] axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast;
    wire        axi_wvalid, axi_wready;
    wire        axi_bvalid, axi_bready;

    // ANTIC DMA BRAM read port (reserved for Phase 1b when we bypass
    // hyperram_shim for direct reads from sally_mem's second BRAM port).
    // Tied off for now — hyperram_shim (BRAM-backed, inside antic_top)
    // handles DMA reads via its own internal BRAM.
    wire [15:0] dma_addr_unused;
    wire [7:0]  dma_rdata_unused;
    assign dma_addr_unused = 16'h0000;

    // ---- sally_clock -----------------------------------------------------
    // CLOCK_MULT=68 gives ~121 MHz from 1.79 MHz phi2.
    // /HALT is bypassed at CLOCK_MULT>=2, so halt_n is tied high.
    // wsync_rdy_n comes from ANTIC via CDC.
    // busy_n comes from sally_mem (1 = ready, 0 = cache miss stall).

    sally_clock #(
        .BASE_DIV (68)
    ) u_sally_clock (
        .clk           (clk),
        .rst           (rst),
        .phi2_tick     (phi2_tick),
        .clock_mult    (8'd68),
        .halt_n        (1'b1),         // bypassed at CLOCK_MULT>=2
        .wsync_rdy_n   (wsync_rdy_n),
        .busy_n        (~mem_busy_n),  // sally_mem.busy: 1=busy, invert to busy_n
        .sally_rdy     (sally_rdy),
        .sally_step    (sally_step)
    );

    // ---- sally_core ------------------------------------------------------
    sally_core u_sally_core (
        .clk      (clk),
        .rst      (rst),
        .addr     (cpu_addr),
        .data_in  (cpu_din),
        .data_out (cpu_dout),
        .rw       (cpu_rw),
        .rdy      (sally_rdy),
        .irq_n    (irq_n_sync),      // from ANTIC via CDC
        .nmi_n    (nmi_n_sync)       // from ANTIC via CDC
    );

    // ---- sally_mem -------------------------------------------------------
    sally_mem #(
        .OS_ROM_HEX_PATH (""),
        .DDR3_BANKED_BASE (32'h2000_0000)
    ) u_sally_mem (
        .clk        (clk),
        .rst        (rst),
        .addr       (cpu_addr),
        .data_in    (cpu_dout),
        .rw         (cpu_rw),
        .data_out   (cpu_din),
        .rdy        (sally_rdy),
        .busy       (mem_busy_n),
        .hwreg_addr (hwreg_addr),
        .hwreg_we   (hwreg_we),
        .hwreg_din  (hwreg_din),
        .hwreg_dout (hwreg_dout),
        .cpu_code_bank_q    (cpu_code_bank),
        .cpu_data_bank_q    (cpu_data_bank),
        .cpu_regc_bank_lo_q (cpu_regc_bank_lo),
        .cpu_regc_bank_hi_q (cpu_regc_bank_hi),
        .antic_code_bank    (antic_code_bank),
        .antic_data_bank    (antic_data_bank),
        .antic_regc_bank_lo (antic_regc_bank_lo),
        .antic_regc_bank_hi (antic_regc_bank_hi),
        .view_is_antic      (view_is_antic),
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
        .rom_addr    (16'h0000),
        .rom_data    (8'h00),
        .rom_we      (1'b0),
        .dma_clk     (1'b0),          // tied off — hyperram_shim handles DMA reads
        .dma_addr    (dma_addr_unused),
        .dma_rdata   (dma_rdata_unused)
    );

    // ====================================================================
    // CDC: register writes SALLY → ANTIC
    // ====================================================================
    // SALLY's hwreg_we/hwreg_addr/hwreg_din are the bus register write
    // interface.  For Phase 1a (single clock), wire directly.  When clocks
    // split, insert cdc_fifo_1w1r here.

    wire [15:0] bus_addr_antic      = hwreg_addr;
    wire [7:0]  bus_data_in_antic   = hwreg_din;
    wire        bus_rw_antic        = !hwreg_we;   // invert: 1=read for antic_top
    wire        d0xx_n_antic        = ~(hwreg_we && (hwreg_addr[15:8] == 8'hD0));
    wire        d4xx_n_antic        = ~(hwreg_we && (hwreg_addr[15:8] == 8'hD4));

    // ====================================================================
    // CDC: status signals ANTIC → SALLY
    // ====================================================================
    wire nmi_n_antic, irq_n_antic, halt_n_antic, rdy_n_antic;
    wire nmi_n_sync, irq_n_sync;

    cdc_sync_bit #(.WIDTH(2)) u_sync_irq_nmi (
        .dst_clk (clk),
        .src_sig ({nmi_n_antic, irq_n_antic}),
        .dst_sig ({nmi_n_sync,   irq_n_sync})
    );

    // halt_n from ANTIC: at CLOCK_MULT>=2, sally_clock bypasses it.
    // We keep it wired for the CLOCK_MULT=1 fallback path, but never
    // gate on it at our operating point.
    cdc_sync_bit #(.WIDTH(1)) u_sync_halt (
        .dst_clk (clk),
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
        .POKEY_CLK_BUS_HZ (121_704_500),    // 68 × 1.7897725 MHz
        .LEGACY_RP        (1'b1)             // keep RP interfaces active
    ) u_antic_top (
        .clk_bus            (clk),
        .clk_pix            (clk_pix_int),
        .rst_n              (rst_n),
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
        .kbd_event_valid    (1'b0),
        .kbd_event_code     (8'h00),
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
        .ram_clk            (1'b0),
        .ram_clk_cal        (1'b0),
        .hbc_cal_pass       (),
        .hbc_ck_p_LO        (),
        .hbc_ck_p_HI        (),
        .hbc_cs_n           (),
        .hbc_rst_n          (),
        .hbc_dq_OE          (),
        .hbc_dq_IN_LO       (8'h00),
        .hbc_dq_IN_HI       (8'h00),
        .hbc_dq_OUT_LO      (),
        .hbc_dq_OUT_HI      (),
        .hbc_rwds_OE        (),
        .hbc_rwds_IN_LO     (1'b0),
        .hbc_rwds_IN_HI     (1'b0),
        .hbc_rwds_OUT_LO    (),
        .hbc_rwds_OUT_HI    (),
        .hbc_cal_SHIFT_SEL  (),
        .hbc_cal_SHIFT      (),
        .hbc_cal_SHIFT_ENA  (),
        .hbc_cal_debug_info (),
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
    // Video output: RGB565 + sync (replaces TMDS)
    // ====================================================================
    // Driven directly from antic_top's new parallel RGB565 ports.
    // These are registered on clk_pix inside antic_top (from palette_lut
    // output + vbeam timing signals).  The SiI9022A on the Z-Turn SOM
    // samples on pixclk rising edge.

    assign rgb_r      = antic_rgb_r;
    assign rgb_g      = antic_rgb_g;
    assign rgb_b      = antic_rgb_b;
    assign rgb_hsync  = antic_rgb_hsync;
    assign rgb_vsync  = antic_rgb_vsync;
    assign rgb_de     = antic_rgb_de;
    assign rgb_pixclk = antic_rgb_pixclk;

    // ====================================================================
    // AXI output pad registers
    // ====================================================================
    // Registered at the pads so the timing report measures internal logic,
    // not pad-to-pad delays.  (Matches the style used in sally_synth_top.)

    logic [31:0] m_axi_araddr_q;
    logic [7:0]  m_axi_arlen_q;
    logic [2:0]  m_axi_arsize_q;
    logic [1:0]  m_axi_arburst_q;
    logic        m_axi_arvalid_q;
    logic        m_axi_rready_q;
    logic [31:0] m_axi_awaddr_q;
    logic [7:0]  m_axi_awlen_q;
    logic [2:0]  m_axi_awsize_q;
    logic [1:0]  m_axi_awburst_q;
    logic        m_axi_awvalid_q;
    logic [63:0] m_axi_wdata_q;
    logic [7:0]  m_axi_wstrb_q;
    logic        m_axi_wlast_q;
    logic        m_axi_wvalid_q;
    logic        m_axi_bready_q;

    logic        m_axi_arready_q;
    logic [63:0] m_axi_rdata_q;
    logic        m_axi_rvalid_q;
    logic        m_axi_rlast_q;
    logic        m_axi_awready_q;
    logic        m_axi_wready_q;
    logic        m_axi_bvalid_q;

    always_ff @(posedge clk) begin
        m_axi_araddr_q  <= axi_araddr;
        m_axi_arlen_q   <= axi_arlen;
        m_axi_arsize_q  <= axi_arsize;
        m_axi_arburst_q <= axi_arburst;
        m_axi_arvalid_q <= axi_arvalid;
        m_axi_rready_q  <= axi_rready;
        m_axi_awaddr_q  <= axi_awaddr;
        m_axi_awlen_q   <= axi_awlen;
        m_axi_awsize_q  <= axi_awsize;
        m_axi_awburst_q <= axi_awburst;
        m_axi_awvalid_q <= axi_awvalid;
        m_axi_wdata_q   <= axi_wdata;
        m_axi_wstrb_q   <= axi_wstrb;
        m_axi_wlast_q   <= axi_wlast;
        m_axi_wvalid_q  <= axi_wvalid;
        m_axi_bready_q  <= axi_bready;
        m_axi_arready_q <= m_axi_arready;
        m_axi_rdata_q   <= m_axi_rdata;
        m_axi_rvalid_q  <= m_axi_rvalid;
        m_axi_rlast_q   <= m_axi_rlast;
        m_axi_awready_q <= m_axi_awready;
        m_axi_wready_q  <= m_axi_wready;
        m_axi_bvalid_q  <= m_axi_bvalid;
    end

    assign m_axi_araddr  = m_axi_araddr_q;
    assign m_axi_arlen   = m_axi_arlen_q;
    assign m_axi_arsize  = m_axi_arsize_q;
    assign m_axi_arburst = m_axi_arburst_q;
    assign m_axi_arvalid = m_axi_arvalid_q;
    assign m_axi_rready  = m_axi_rready_q;
    assign m_axi_awaddr  = m_axi_awaddr_q;
    assign m_axi_awlen   = m_axi_awlen_q;
    assign m_axi_awsize  = m_axi_awsize_q;
    assign m_axi_awburst = m_axi_awburst_q;
    assign m_axi_awvalid = m_axi_awvalid_q;
    assign m_axi_wdata   = m_axi_wdata_q;
    assign m_axi_wstrb   = m_axi_wstrb_q;
    assign m_axi_wlast   = m_axi_wlast_q;
    assign m_axi_wvalid  = m_axi_wvalid_q;
    assign m_axi_bready  = m_axi_bready_q;

endmodule

`default_nettype wire
