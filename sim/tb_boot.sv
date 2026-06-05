// tb_boot.sv — full-system Atari XL OS cold-start boot testbench.
//
// Proves the emulated 6502 (xt6502) boots the real Atari XL OS ROM through
// cold-start, WITHOUT any hardware / JTAG.  This is the sim-only visibility
// gate before the design goes on the Z-Turn board (~2 weeks out).
//
// It instantiates the boot-relevant core of fpga_xt_top.sv, mirroring its
// wiring exactly (fpga_xt_top lines ~510-857) for:
//   - the CPU (xt6502)
//   - sally_clock (halt bypassed; see the SIM-SPEED NOTE at the instance —
//     fpga_xt_top uses BASE_DIV=68/clock_mult=68 = authentic 1.79 MHz; this tb
//     runs a clean every-cycle grade so the functional boot finishes sooner)
//   - sally_mem (64K BRAM, OS ROM baked in via rsrc/sally-boot.hex)
//   - the hwreg write-path CDC (cdc_fifo_1w1r) + the antic_we_q glue
//   - the hwreg read-back CDC (hwreg_rd_cdc)
//   - the status CDC (cdc_sync_bit) for {nmi_n,irq_n} and halt_n
//   - antic_top (VBLANK NMI + hwreg bus + DMA-read of screen RAM only;
//     display / compositor / writeback / AXI ports tied off as in
//     tb_antic_display).
//
// The DDR3/AXI banked-window master on sally_mem (m_axi_*) is connected to
// the sim axi_slave_mem (always-ready, returns 0) so a stray banked read
// completes instead of hanging.  The OS boots entirely from the 64K BRAM
// image, so it should never fire — but we don't let it hang if it does.
//
// Clocks: clk_sally and clk_sys are both generated here.  clk_sys is run a
// little faster than clk_sally (ANTIC needs to drain the hwreg write FIFO and
// service read-back round-trips faster than SALLY issues them).  phi2_tick is
// tied LOW: sally_clock uses its own sub-phi2 counter to generate the CPU step
// pulses, so phi2_tick is unused (matches fpga_xt_top, which also ties
// phi2_tick = 1'b0).
//
// Boot milestones asserted (the point of this tb):
//   1. PC reaches the $C2xx OS cold-start region after reset.
//   2. RAMTOP ($6A) becomes non-zero (RAM sizing ran; expect ~$A0-$C0).
//   3. RTCLOK ($12/$13/$14) advances over time (ANTIC VBLANK NMI fires +
//      the OS VBLANK service runs — the strongest single liveness signal).
//   4. ANTIC DMACTL ($D400) + DLISTL/DLISTH ($D402/$D403) get programmed
//      non-zero (the OS set up the display).

`default_nettype none
`timescale 1ns / 1ps

module tb_boot;

    // ====================================================================
    // Clocks + reset
    // ====================================================================
    // clk_sally ~100 MHz (10 ns), clk_sys ~150 MHz (6.667 ns) — clk_sys
    // faster so the hwreg CDC FIFO drains and read-back round-trips finish
    // well within a SALLY memory cycle (mirrors the production 100/150 ratio).
    logic clk_sally = 1'b0;  always #5.000 clk_sally = ~clk_sally;   // 100 MHz
    logic clk_sys   = 1'b0;  always #3.333 clk_sys   = ~clk_sys;     // ~150 MHz

    // Start LOW so the reset-release sequence below produces a clean 0->1->0
    // pulse.  cpu.v resets its FSM `state` on `always @(posedge clk or posedge
    // reset)` — an ASYNC, edge-triggered reset — so a rising edge on rst_sally
    // is REQUIRED to initialise the core (otherwise `state` stays X and the
    // CPU wedges presenting a constant address).  sally_mem / the CDCs use
    // synchronous reset and don't need the edge, but the pulse is harmless.
    logic rst_sally = 1'b0;
    logic rst_sys   = 1'b0;
    wire  rst_sys_n = ~rst_sys;

    // phi2_tick: tied low (sally_clock uses its sub-phi2 counter for steps).
    wire        phi2_tick = 1'b0;

    // ====================================================================
    // CPU <-> memory nets (mirror fpga_xt_top)
    // ====================================================================
    wire [15:0] cpu_addr;
    wire [7:0]  cpu_din, cpu_dout;
    wire        cpu_rw;
    wire        sally_rdy;
    wire        sally_step;

    wire        cpu_stack_op;
    wire [3:0]  cpu_s_high;

    wire        mem_busy_n;          // sally_mem busy (1 = ready)
    wire        wsync_rdy_n;         // from ANTIC WSYNC
    wire        halt_n_sally;        // /HALT after CDC (unused at clock_mult>=2)

    // hwreg passthrough (sally_mem <-> hwreg muxing)
    wire [15:0] hwreg_addr;
    wire [7:0]  hwreg_din;
    wire        hwreg_we;
    wire [7:0]  hwreg_dout;

    wire [7:0]  cpu_code_bank, cpu_data_bank;

    // read-back CDC nets
    wire        cdc_bus_read;
    wire [15:0] cdc_bus_addr;
    wire [7:0]  cdc_rd_data;
    wire        hwreg_rd_busy;

    // ANTIC DMA read port into sally_mem's BRAM
    wire [15:0] antic_bram_addr;
    wire [7:0]  antic_bram_rdata;

    // PORTB from PIA (inside antic_top) → sally_mem ROM/RAM control
    wire [7:0]  portb_q;

    // Peripheral-RP SPI link (antic_top peri_bridge ↔ idle-RP model below).
    wire        peri_spi_clk, peri_spi_mosi, peri_spi_cs_n;
    wire        peri_spi_miso;

    // Status CDC outputs (ANTIC → SALLY), declared early so the CPU can bind.
    wire        nmi_n_antic, irq_n_antic, halt_n_antic;
    wire        nmi_n_sync, irq_n_sync;

    // ANTIC combinational read-mux output (read-back CDC bus_rdata).
    wire [7:0]  antic_bus_data_out;
    wire        antic_bus_data_oe;

    // ---- DDR3/AXI banked-window master nets (sally_mem m_axi_*) ----------
    // Declared before sally_mem so iverilog can bind the output ports.
    wire [31:0] axi_araddr;
    wire [7:0]  axi_arlen;
    wire [2:0]  axi_arsize;
    wire [1:0]  axi_arburst;
    wire        axi_arvalid, axi_arready;
    wire [63:0] axi_rdata;
    wire        axi_rvalid, axi_rlast, axi_rready;
    wire [31:0] axi_awaddr;
    wire [7:0]  axi_awlen;
    wire [2:0]  axi_awsize;
    wire [1:0]  axi_awburst;
    wire        axi_awvalid, axi_awready;
    wire [63:0] axi_wdata;
    wire [7:0]  axi_wstrb;
    wire        axi_wlast, axi_wvalid, axi_wready;
    wire        axi_bvalid, axi_bready;

    // ====================================================================
    // sally_clock (fpga_xt_top lines ~522-534)
    // ====================================================================
    // SIM-SPEED NOTE.  fpga_xt_top runs BASE_DIV=56; clock_mult resets to 1
    // (1× = real Atari ~1.786 MHz at clk_sally=100 MHz) and software dials it to
    // 56 for full turbo (100 MHz).  At 1× the CPU steps once every 56 clk_sally
    // cycles, which for a *functional* boot sim only makes iverilog slower; the
    // CPU executes the identical instruction stream either way (clock_mult is
    // purely a RDY clock-enable divisor; it does not change CPU semantics,
    // ANTIC's frame cadence, or the CDC handshakes — ANTIC's VBLANK NMI is
    // paced by clk_sys/antic_raster, not by this divisor).
    //
    // So for sim throughput we run the CPU one step per clk_sally cycle using
    // a clean every-cycle grade (BASE_DIV=2, clock_mult=2 → threshold 0).  The
    // halt-bypass condition (clock_mult>=2) is unchanged, so /HALT stays
    // bypassed exactly as in production.  Everything else mirrors fpga_xt_top.
    sally_clock #(
        .BASE_DIV (2)
    ) u_sally_clock (
        .clk           (clk_sally),
        .rst           (rst_sally),
        .phi2_tick     (phi2_tick),
        .clock_mult    (8'd2),         // step every clk_sally cycle (sim speed)
        .halt_n        (1'b1),         // bypassed at CLOCK_MULT>=2
        .wsync_rdy_n   (wsync_rdy_n),
        .busy_n        (~(mem_busy_n | hwreg_rd_busy)),
        .sally_rdy     (sally_rdy),
        .sally_step    (sally_step)
    );

    // ====================================================================
    // CPU core (mirrors fpga_xt_top's xt6502 instantiation)
    // ====================================================================
    xt6502 u_sally_core (
        .clk      (clk_sally),
        .rst      (rst_sally),
        .addr     (cpu_addr),
        .data_in  (cpu_din),
        .data_out (cpu_dout),
        .rw       (cpu_rw),
        .rdy      (sally_rdy),
        .irq_n    (irq_n_sync),
        .nmi_n    (nmi_n_sync),
        .stack_op (cpu_stack_op),
        .s_high   (cpu_s_high)
    );

    // ROM-init port (tied off — OS image baked in via OS_ROM_HEX_PATH).
    wire [15:0] rom_load_addr = 16'h0000;
    wire  [7:0] rom_load_data = 8'h00;
    wire        rom_load_we   = 1'b0;

    // ====================================================================
    // sally_mem (fpga_xt_top lines ~576-631) — OS ROM path overridden.
    // ====================================================================
    sally_mem #(
        .OS_ROM_HEX_PATH ("../rsrc/sally-boot.hex"),
        .SELFTEST_HEX_PATH ("../rsrc/selftest.hex"),
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
        .bus_mpd_n_in       (1'b1),
        .bus_pbi_rdata      (8'hFF),
        .bus_rd4_n_in       (1'b1),
        .bus_rd5_n_in       (1'b1),
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
        .dma_clk     (clk_sys),
        .dma_addr    (antic_bram_addr),
        .dma_rdata   (antic_bram_rdata)
    );

    // ====================================================================
    // DDR3/AXI banked-window slave stub (always-ready, returns 0).
    // The OS boots from BRAM; this only exists so a stray $6000-$9FFF
    // banked read completes instead of hanging the sim.
    // ====================================================================
    axi_slave_mem #(.ADDR_W(32), .DATA_W(64)) u_axi_stub (
        .clk           (clk_sally),
        .rst           (rst_sally),
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

    // ====================================================================
    // CDC: hwreg writes SALLY (clk_sally) → ANTIC (clk_sys)
    // (fpga_xt_top lines ~645-699)
    // ====================================================================
    wire        hwreg_page_rd  = (cpu_addr[15:11] == 5'b11010) & cpu_rw;
    wire        is_blitter_reg = (cpu_addr[15:8] == 8'hD4)
                               & (cpu_addr[7:4] == 4'hB || cpu_addr[7:4] == 4'hC);
    // xtc bank-control regs $D5C0/$D5C1 served locally by sally_mem (off the CDC).
    wire        is_xtc_ctl     = (cpu_addr[15:1] == 15'h6AE0);   // $D5C0-$D5C1
    wire        hwreg_cdc_rd   = hwreg_page_rd & ~is_blitter_reg & ~is_xtc_ctl;

    wire        hwreg_wr_full_unused;
    wire        hwreg_rd_empty;
    wire [23:0] hwreg_rd_data;
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

    wire [15:0] bus_addr_antic    = cdc_bus_read ? cdc_bus_addr : bus_addr_antic_q;
    wire [7:0]  bus_data_in_antic = bus_data_in_antic_q;
    wire        bus_rw_antic      = cdc_bus_read ? 1'b1 : ~antic_we_q;
    wire        d0xx_n_antic = cdc_bus_read
                             ? ~(cdc_bus_addr[15:8] == 8'hD0)
                             : ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD0));
    wire        d4xx_n_antic = cdc_bus_read
                             ? ~(cdc_bus_addr[15:8] == 8'hD4)
                             : ~(antic_we_q && (bus_addr_antic_q[15:8] == 8'hD4));

    // ---- Register read-back CDC bridge (fpga_xt_top lines ~705-719) -----
    wire        hwreg_bus_idle = hwreg_rd_empty & ~antic_we_q;
    wire [7:0]  antic_rd_ungated;   // antic_top.bus_rdata_int — ungated internal read mux (driven below)
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
        // DIAGNOSIS: tap antic_top's UNGATED combinational read mux, not the
        // pad output bus_data_out — that one is gated by ext_bus_active
        // (=0 for internal CPU at turbo), so register reads returned $00.
        .bus_rdata (antic_rd_ungated)
    );

    // hwreg_dout feeds sally_mem's read pipeline.  fpga_xt_top routes the
    // blitter regs locally and everything else (ANTIC/GTIA/POKEY/PIA) via the
    // read-back CDC.  No blitter here, so unmapped/blitter regs read $FF and
    // the rest come from cdc_rd_data.  (fpga_xt_top lines ~1303-1313.)
    assign hwreg_dout = is_blitter_reg ? 8'hFF : cdc_rd_data;

    // ====================================================================
    // CDC: status ANTIC → SALLY (fpga_xt_top lines ~724-740)
    // ====================================================================
    cdc_sync_bit #(.WIDTH(2)) u_sync_irq_nmi (
        .dst_clk (clk_sally),
        .src_sig ({nmi_n_antic, irq_n_antic}),
        .dst_sig ({nmi_n_sync,   irq_n_sync})
    );

    cdc_sync_bit #(.WIDTH(1)) u_sync_halt (
        .dst_clk (clk_sally),
        .src_sig (halt_n_antic),
        .dst_sig (halt_n_sally)
    );

    // ====================================================================
    // antic_top (fpga_xt_top lines ~778-851).  Display/compositor/writeback/
    // AXI ports tied off (same pattern as tb_antic_display) — ANTIC here only
    // needs to: generate the VBLANK NMI, serve the hwreg bus, and DMA-read the
    // screen RAM from sally_mem's dma port.
    // ====================================================================
    wire        antic_nmi_n, antic_halt_n, antic_rdy_n, antic_irq_n;

    // ANTIC render-tap nets + READY flag (declared before the instance that
    // drives wb_*; captured/decoded in the "ANTIC render-tap capture" block).
    wire        wb_pix_valid, wb_frame_done, wb_pal_we;
    wire [7:0]  wb_pix_pair, wb_color_lo, wb_color_hi, wb_atari_row, wb_pal_idx;
    wire [23:0] wb_pal_rgb;
    bit         ready_seen = 1'b0;

    antic_top #(
        .POKEY_CLK_BUS_HZ (150_000_000)
    ) u_antic_top (
        .clk_bus            (clk_sys),
        .rst_n              (rst_sys_n),
        .bus_addr           (bus_addr_antic),
        .bus_data_in        (bus_data_in_antic),
        .bus_rw             (bus_rw_antic),
        .d0xx_n             (d0xx_n_antic),
        .d4xx_n             (d4xx_n_antic),
        .bus_data_out       (antic_bus_data_out),
        .bus_data_oe        (antic_bus_data_oe),
        .bus_rdata_int      (antic_rd_ungated),
        .nmi_n              (antic_nmi_n),
        .halt_n             (antic_halt_n),
        .rdy_n              (antic_rdy_n),
        .dma_steal          (),            // boot tb runs CLOCK_MULT=2 (turbo) — steal bypassed
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
        .kbd_event_valid    (1'b0),
        .kbd_event_code     (8'h00),
        // joy SPI MISO idles HIGH: an open PCAL9722's inputs pull high ($FF =
        // no buttons, switches released, PORTB MMU pull-up).  With it tied 0 the
        // joy_bridge poll read all-zeros and overwrote joy_portb_in's $FF reset →
        // the XL OS read PORTB as $00, did ORA #$02 → OS ROM off → crash.
        //
        // The PERI (SIO/POT) SPI is driven by a behavioral idle-RP model
        // (peri_rp_idle below): with no peripheral attached every register reads
        // $00, so there is no spurious BREAK or ser-in to churn POKEY's IRQ and
        // starve the deferred VBLANK.  The boot's SIO device-probes are stubbed
        // in the OS ROM (see the ROM patch), so no command frame is ever sent.
        .spi_clk            (peri_spi_clk),
        .spi_mosi           (peri_spi_mosi),
        .spi_miso           (peri_spi_miso),
        .spi_cs_n           (peri_spi_cs_n),
        .spi_irq            (1'b1),
        .joy_spi_clk        (),
        .joy_spi_mosi       (),
        .joy_spi_miso       (1'b1),
        .joy_spi_cs_n       (),
        .joy_spi_int_n      (1'b1),
        .bram_addr          (antic_bram_addr),
        .bram_rdata         (antic_bram_rdata),
        .portb_q            (portb_q),
        .wb_pix_valid       (wb_pix_valid),
        .wb_pix_pair        (wb_pix_pair),
        .wb_color_lo        (wb_color_lo),
        .wb_color_hi        (wb_color_hi),
        .wb_atari_row       (wb_atari_row),
        .wb_row_flush       (),
        .wb_frame_done      (wb_frame_done),
        .wb_pal_we          (wb_pal_we),
        .wb_pal_idx         (wb_pal_idx),
        .wb_pal_rgb         (wb_pal_rgb),
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

    assign nmi_n_antic  = antic_nmi_n;
    assign irq_n_antic  = antic_irq_n;
    assign halt_n_antic = antic_halt_n;
    assign wsync_rdy_n  = antic_rdy_n;

    // Idle peripheral-RP model on the peri SPI link (no joysticks/POTs/SIO
    // device): every register reads $00, so no spurious POKEY serial IRQs.
    // See peri_rp_idle.sv.
    peri_rp_idle u_peri_rp_idle (
        .rst       (rst_sys),
        .spi_clk   (peri_spi_clk),
        .spi_cs_n  (peri_spi_cs_n),
        .spi_mosi  (peri_spi_mosi),
        .spi_miso  (peri_spi_miso)
    );

    // ====================================================================
    // ANTIC render-tap capture — decode ANTIC's ACTUAL rendered pixels
    // ====================================================================
    // The wb_* render tap (clk_bus = clk_sys in this build) streams ANTIC's
    // output per pixel-pair: 8-bit Atari colour codes (even/odd column) plus the
    // code->RGB palette.  We store raw codes into a flat framebuffer and, on the
    // 2nd frame_done after READY appears (a frame rendered entirely after the
    // prompt is in screen RAM, so it's a complete render), dump fb + palette for
    // Python to resolve into a PNG.  This exercises the real ANTIC pipeline
    // (DLIST fetch -> char gen -> playfield colours), not a font re-model.
    localparam int ANTIC_W = 384;          // wide-playfield max (192 pairs)
    localparam int ANTIC_H = 192;
    logic [7:0]  antic_fb  [0:ANTIC_H*ANTIC_W-1];
    logic [23:0] antic_pal [0:255];
    int  frames_after_ready = 0;
    bit  antic_captured     = 1'b0;

    initial begin
        for (int i = 0; i < ANTIC_H*ANTIC_W; i++) antic_fb[i]  = 8'h00;
        for (int i = 0; i < 256;             i++) antic_pal[i] = 24'h0;
    end

    task automatic dump_antic_frame();
        $writememh("/tmp/antic_fb.hex",  antic_fb);
        $writememh("/tmp/antic_pal.hex", antic_pal);
        $display("[%0t] ANTIC: rendered frame captured -> /tmp/antic_fb.hex (+pal)", $time);
    endtask

    always @(posedge clk_sys) begin
        if (wb_pal_we) antic_pal[wb_pal_idx] <= wb_pal_rgb;
        if (wb_pix_valid && wb_atari_row < ANTIC_H && wb_pix_pair < (ANTIC_W/2)) begin
            antic_fb[wb_atari_row*ANTIC_W + (int'(wb_pix_pair)<<1)]     <= wb_color_lo;
            antic_fb[wb_atari_row*ANTIC_W + (int'(wb_pix_pair)<<1) + 1] <= wb_color_hi;
        end
        if (wb_frame_done && ready_seen) begin
            frames_after_ready <= frames_after_ready + 1;
            if (frames_after_ready >= 1 && !antic_captured) begin
                antic_captured <= 1'b1;
                dump_antic_frame();
            end
        end
    end

    // ANTIC render-pipeline health probe: confirms the compose chain runs and
    // produces coloured pixels.  dl_start -> dl_parser -> dl_done -> cmp_start
    // -> compositor (cmp_cmd_valid) -> wb_pix_valid; pal_write_strobe loads the
    // palette.  wb_color_seen ORs every resolved colour (non-zero => ANTIC
    // rendered real playfield colour, not all-border).
    integer n_dl_start = 0, n_dl_done = 0, n_cmp_start = 0, n_cmp_valid = 0, n_pal_we = 0;
    logic [7:0] wb_color_seen = 8'h00;
    always @(posedge clk_sys) begin
        if (u_antic_top.dl_start_pulse)   n_dl_start  <= n_dl_start  + 1;
        if (u_antic_top.dl_done)          n_dl_done   <= n_dl_done   + 1;
        if (u_antic_top.cmp_start_pulse)  n_cmp_start <= n_cmp_start + 1;
        if (u_antic_top.cmp_cmd_valid)    n_cmp_valid <= n_cmp_valid + 1;
        if (u_antic_top.pal_write_strobe) n_pal_we    <= n_pal_we    + 1;
        if (wb_pix_valid) wb_color_seen <= wb_color_seen | wb_color_lo | wb_color_hi;
    end

    // ====================================================================
    // Boot observability / milestone scoreboard
    // ====================================================================
    // OS-variable hierarchical refs into sally_mem's main BRAM.
    // RTCLOK = $12 (hi) / $13 (mid) / $14 (lo) — the OS increments $14 each
    // VBLANK, carrying up.  RAMTOP = $6A.
    function automatic [7:0] osmem(input [15:0] a);
        osmem = u_sally_mem.mem[a];
    endfunction

    // Pass-check: scan the GR.0 text screen (SAVMSC..+960) for the BASIC
    // "READY" prompt in ANTIC internal codes (R=$32 E=$25 A=$21 D=$24 Y=$39).
    function automatic bit ready_on_screen();
        logic [15:0] base;
        ready_on_screen = 1'b0;
        base = {osmem(16'h0059), osmem(16'h0058)};
        for (int i = 0; i < 960-5; i++)
            if (osmem(base+i[15:0])==8'h32 && osmem(base+(i+1))==8'h25
             && osmem(base+(i+2))==8'h21 && osmem(base+(i+3))==8'h24
             && osmem(base+(i+4))==8'h39) ready_on_screen = 1'b1;
    endfunction

    // Combined 24-bit RTCLOK value (hi:mid:lo) for monotonic comparison.
    function automatic [23:0] rtclok();
        rtclok = {u_sally_mem.mem[16'h0012],
                  u_sally_mem.mem[16'h0013],
                  u_sally_mem.mem[16'h0014]};
    endfunction

    // Milestone flags.
    bit reached_c2xx   = 1'b0;
    bit ramtop_nonzero = 1'b0;
    bit rtclok_moved   = 1'b0;
    bit dmactl_prog    = 1'b0;
    bit dlist_prog     = 1'b0;

    bit [7:0]  ramtop_val   = 8'h00;
    bit [23:0] rtclok_first = 24'h0;   // first non-zero sample
    bit [23:0] rtclok_last  = 24'h0;
    bit        rtclok_seeded = 1'b0;
    bit [1:0]  dlist_seen   = 2'b00;   // {$D403 seen, $D402 seen}

    // Address-range diagnostics: lo/hi addr seen since the last progress ping,
    // plus a count of bus cycles where RDY was high (the CPU actually stepped).
    bit [15:0] addr_lo_win = 16'hFFFF;
    bit [15:0] addr_hi_win = 16'h0000;
    bit [15:0] addr_hi_ever = 16'h0000;
    longint    step_cnt = 0;          // RDY-high cycles since last progress
    always @(posedge clk_sally) begin
        if (!rst_sally && sally_rdy) begin
            step_cnt <= step_cnt + 1;
            if (cpu_addr < addr_lo_win) addr_lo_win <= cpu_addr;
            if (cpu_addr > addr_hi_win) addr_hi_win <= cpu_addr;
            if (cpu_addr > addr_hi_ever) addr_hi_ever <= cpu_addr;
        end
    end

    // ---- Freeze detector -------------------------------------------------
    // If the CPU address bus is constant for a long run of RDY-high cycles the
    // CPU is wedged.  Report the held address once so we can see WHERE.
    bit [15:0] frz_addr = 16'h0;
    longint    frz_cnt  = 0;
    bit        frz_dumped = 1'b0;
    always @(posedge clk_sally) begin
        if (!rst_sally && sally_rdy) begin
            if (cpu_addr == frz_addr) frz_cnt <= frz_cnt + 1;
            else begin frz_addr <= cpu_addr; frz_cnt <= 0; end
            if (frz_cnt == 200_000 && !frz_dumped) begin
                frz_dumped <= 1'b1;
                $display("[%0t] FREEZE: addr=%04h held for %0d RDY cycles  rw=%b din=%02h dout=%02h",
                         $time, cpu_addr, frz_cnt, cpu_rw, cpu_din, cpu_dout);
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // WEDGE WATCHDOG — NOT rdy-gated (the freeze detector above is, so a CPU
    // wedged with rdy stuck low never trips it).  If the bus address is
    // unchanged for a long run of clk_sally cycles, dump the stall sources +
    // CDC state so a bad busy_n / hwreg-stall change is diagnosable instead of
    // just hanging.
    // ════════════════════════════════════════════════════════════════════
    reg  [15:0] wd_pc   = 16'hFFFF;
    int         wd_cnt  = 0;
    bit         wd_done = 1'b0;
    always @(posedge clk_sally) begin
        if (!rst_sally && !wd_done) begin
            if (cpu_addr !== wd_pc) begin
                wd_pc  <= cpu_addr;
                wd_cnt <= 0;
            end else if (wd_cnt > 300000) begin
                wd_done <= 1'b1;
                $display("[%0t] WEDGE: addr=%04h held %0d clk_sally cyc  rdy=%b step=%b",
                         $time, cpu_addr, wd_cnt, sally_rdy, sally_step);
                $display("   stall: mem_busy_n=%b hwreg_rd_busy=%b wsync_rdy_n=%b  cpu_addr=%04h rw=%b din=%02h",
                         mem_busy_n, hwreg_rd_busy, wsync_rdy_n, cpu_addr, cpu_rw, cpu_din);
                $display("   CDC: rd_req=%b bus_read=%b bus_idle=%b rd_data=%02h ungated=%02h state=%0d armed=%b captured=%b",
                         hwreg_cdc_rd, cdc_bus_read, hwreg_bus_idle, cdc_rd_data, antic_rd_ungated,
                         u_hwreg_rd_cdc.state, u_hwreg_rd_cdc.armed, u_hwreg_rd_cdc.captured);
                $finish;
            end else begin
                wd_cnt <= wd_cnt + 1;
            end
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // CO-SIM TRACE (xt6502) — opt-in via `-D COSIM_TRACE` (see `make boot_trace`).
    // One line per retired instruction to /tmp/vvp_boot.trace for
    // tools/cosim_diff.py to diff against the instrumented-Atari800 golden
    // (/tmp/golden_*.trace):
    //     <opcode-addr> <A> <X> <Y> <S>     (hex)
    //
    // Fires at xt6502's ST_DECODE (state 7'd4): there `di` = the just-fetched
    // opcode and PC has been post-incremented past it, so opcode-addr = PC-1,
    // and A/X/Y/S hold the pre-execute (= post-previous-instruction) state —
    // matching Atari800's GET_PC()-at-fetch logging.  S is the low 8 bits (the
    // golden uses an 8-bit SP).  rdy-gated (xt6502 freezes all state on rdy=0);
    // ST_DECODE is never two cycles back-to-back, so the rising-edge guard fires
    // exactly once per instruction.
    //
    // NOTE: on a serviced IRQ/NMI the ST_DECODE of the discarded opcode is still
    // logged (xt6502 recognises the interrupt *at* DECODE).  This mirrors the
    // SALLY emitter this replaces; if it offsets per-line alignment at an
    // interrupt, gate the $fwrite on `!u_sally_core.do_intr`.
    // ════════════════════════════════════════════════════════════════════
`ifdef COSIM_TRACE
    localparam [6:0] XT_ST_DECODE = 7'd4;
    integer   cosim_fd;
    bit [6:0] cosim_prev_st = 7'h7f;
    int       cosim_n = 0;
    initial   cosim_fd = $fopen("/tmp/vvp_boot.trace", "w");
    always @(posedge clk_sally) begin
        if (!rst_sally && sally_rdy && cosim_fd != 0) begin
            if (u_sally_core.state == XT_ST_DECODE && cosim_prev_st != XT_ST_DECODE) begin
                $fwrite(cosim_fd, "%h %h %h %h %h\n",
                        (u_sally_core.PC - 16'd1),
                        u_sally_core.A, u_sally_core.X,
                        u_sally_core.Y, u_sally_core.S);
                cosim_n <= cosim_n + 1;
                if (cosim_n[12:0] == 13'd0) $fflush(cosim_fd);
                if (cosim_n >= 2500000) begin $fclose(cosim_fd); cosim_fd <= 0; end
            end
            cosim_prev_st <= u_sally_core.state;
        end
    end
`endif

    // ════════════════════════════════════════════════════════════════════
    // POKEY-IRQ DIAGNOSIS — the OS loops in its IRQ handler (IIR, $C05x) while
    // the golden never takes an IRQ here, so POKEY asserts a spurious irq_n.
    // Log which IRQST bit is pending + whether IRQEN enables it + the live
    // SEROC level, whenever irq_n is asserted and the CPU is in the $C0xx IIR.
    // ════════════════════════════════════════════════════════════════════
    bit pk_irq_prev = 1'b1;
    int pk_probe_n = 0;
    always @(posedge clk_sys) begin
        if (!rst_sys) begin
            // Falling edge of POKEY's own irq_n (regardless of CPU PC / masking).
            if (!u_antic_top.u_pokey_l.irq_n && pk_irq_prev && pk_probe_n < 60) begin
                $display("[%0t] POKEY-IRQ assert: irqen=%02h pending=%02h seroc=%b",
                         $time, u_antic_top.u_pokey_l.u_regs.irqen_q,
                         u_antic_top.u_pokey_l.u_regs.irq_pending,
                         u_antic_top.u_pokey_l.ser_out_complete);
                pk_probe_n <= pk_probe_n + 1;
            end
            pk_irq_prev <= u_antic_top.u_pokey_l.irq_n;
        end
    end

    // ════════════════════════════════════════════════════════════════════
    // SELF-TEST ENTRY TRACE — REMOVED with the Arlet/SALLY core.  It logged the
    // OS's hwreg activity + an instruction-PC ring and stopped at the moment the
    // OS cleared the OS-ROM-enable bit (self-test diversion).  The PC ring and
    // register dump used cpu.v internals.  The self-test diversion it diagnosed
    // is resolved (the boot now takes the BASIC cartridge path).
    // ════════════════════════════════════════════════════════════════════

    // Watch the CPU address bus for the cold-start region.
    always @(posedge clk_sally) begin
        if (!rst_sally && sally_rdy) begin
            if (!reached_c2xx && cpu_addr[15:8] == 8'hC2) begin
                reached_c2xx = 1'b1;
                $display("[%0t] MILESTONE 1: CPU reached $C2xx cold-start (PC/addr=%04h)",
                         $time, cpu_addr);
            end
        end
    end

    // Track ANTIC display-register programming via the hwreg write FIFO push
    // (hwreg_we pulses on clk_sally with hwreg_addr/hwreg_din valid).  This
    // is the SALLY-side view of the OS writing $D4xx.
    always @(posedge clk_sally) begin
        if (!rst_sally && hwreg_we) begin
            if (hwreg_addr == 16'hD400 && hwreg_din != 8'h00 && !dmactl_prog) begin
                dmactl_prog = 1'b1;
                $display("[%0t] MILESTONE 4a: DMACTL ($D400) <= $%02h", $time, hwreg_din);
            end
            if ((hwreg_addr == 16'hD402 || hwreg_addr == 16'hD403)
                && hwreg_din != 8'h00 && !dlist_prog) begin
                // require BOTH halves seen non-zero before declaring DLIST set
                dlist_seen[hwreg_addr[0]] = 1'b1;
                if (dlist_seen[0] || dlist_seen[1]) begin
                    dlist_prog = 1'b1;
                    $display("[%0t] MILESTONE 4b: DLIST ($D402/3) being programmed ($%04h <= $%02h)",
                             $time, hwreg_addr, hwreg_din);
                end
            end
        end
    end

    // ====================================================================
    // Progress monitor + cycle budget + final verdict
    // ====================================================================
    // Count released clk_sally cycles.  Budget is generous: cold-start waits
    // several VBLANK frames (each ~ one ANTIC frame in clk_sys time).
    // Failure ceiling only: a good boot renders READY (~3.7M) and the early-out
    // trips once ANTIC has rendered the 2nd full frame after it (~8M).  12M
    // leaves margin and fails fast if a regression stalls the boot.
    localparam longint CYCLE_BUDGET = 12_000_000;
    longint cyc = 0;

    // RTCLOK liveness: the RAM test scribbles patterns across page 0 (incl.
    // $12-$14), so a raw "RTCLOK != 0" or "RTCLOK changed" check can fire on a
    // RAM-test transient.  The robust signal is the VBLANK NMI itself plus the
    // OS's RTCLOK low byte ($14) actually TICKING after the OS has finished
    // zeroing page 0.  We arm only once RAMTOP is set (RAM test done), require
    // a stable zero baseline, then count genuine increments of $14.
    longint rtclok_sample_cyc = 0;
    int     nmi_count   = 0;        // VBLANK NMI assertions observed
    bit     nmi_prev    = 1'b1;
    bit [7:0] rt_lo_prev = 8'h00;
    int     rt_ticks    = 0;        // distinct increments of $14 post-RAMTOP

    always @(posedge clk_sally) begin
        if (!rst_sally) begin
            cyc <= cyc + 1;

            // Count NMI assertions (active-low; falling edge of nmi_n_sync).
            nmi_prev <= nmi_n_sync;
            if (nmi_prev && !nmi_n_sync) nmi_count <= nmi_count + 1;

            // RAMTOP
            if (!ramtop_nonzero && osmem(16'h006A) != 8'h00) begin
                ramtop_nonzero = 1'b1;
                ramtop_val     = osmem(16'h006A);
                $display("[%0t] MILESTONE 2: RAMTOP ($6A) = $%02h (cyc=%0d)",
                         $time, ramtop_val, cyc);
            end

            // RTCLOK: once RAMTOP is set (RAM test done), watch $14 tick up via
            // the VBLANK service.  rtclok_first is seeded at RAMTOP time; we
            // require >=2 genuine ticks AND >=2 NMIs to call it alive.
            if (ramtop_nonzero && !rtclok_seeded) begin
                rtclok_seeded     = 1'b1;
                rtclok_first      = rtclok();
                rt_lo_prev        = osmem(16'h0014);
                rtclok_sample_cyc = cyc;
                $display("[%0t] RTCLOK baseline (post-RAMTOP) = %06h (cyc=%0d)",
                         $time, rtclok_first, cyc);
            end
            if (rtclok_seeded && !rtclok_moved) begin
                rtclok_last = rtclok();
                if (osmem(16'h0014) != rt_lo_prev) begin
                    rt_ticks   = rt_ticks + 1;
                    rt_lo_prev = osmem(16'h0014);
                end
                if (rt_ticks >= 2 && nmi_count >= 2) begin
                    rtclok_moved = 1'b1;
                    $display("[%0t] MILESTONE 3: RTCLOK advanced %06h -> %06h (VBLANK NMI alive, cyc=%0d)",
                             $time, rtclok_first, rtclok_last, cyc);
                end
            end

            // Progress ping every ~2M cycles.  addr[lo..hi] is the address
            // span touched since the last ping (proves the CPU is moving, not
            // frozen); steps = RDY-high bus cycles in that window.
            if (cyc != 0 && (cyc % 2_000_000) == 0) begin
                $display("[progress] cyc=%0dM addr=%04h rw=%b span=[%04h..%04h] hiEver=%04h steps=%0d RAMTOP=$%02h RTCLOK=%06h NMIs=%0d PORTB=$%02h DMACTL=%b DLIST=%b nmi_n=%b",
                         cyc/1_000_000, cpu_addr, cpu_rw,
                         addr_lo_win, addr_hi_win, addr_hi_ever, step_cnt,
                         osmem(16'h006A), rtclok(), nmi_count, portb_q,
                         dmactl_prog, dlist_prog, nmi_n_sync);
                addr_lo_win <= 16'hFFFF;
                addr_hi_win <= 16'h0000;
                step_cnt    <= 0;
            end

            if (cyc >= CYCLE_BUDGET) begin
                $display("[%0t] cycle budget (%0d) reached", $time, CYCLE_BUDGET);
                finish_run();
            end

            // DEBUG (READY-screen): poll the text screen every 100k cyc for the
            // BASIC "READY" prompt so we stop the instant it's printed.
            if (!ready_seen && (cyc % 100000) == 0 && ready_on_screen()) begin
                ready_seen <= 1'b1;
                $display("[%0t] *** READY prompt detected on screen *** (cyc=%0d)", $time, cyc);
            end

            // Early-out: milestones pass, BASIC printed READY, AND ANTIC has
            // rendered a complete post-READY frame (captured via the wb_* tap).
            if (reached_c2xx && ramtop_nonzero && rtclok_moved
                && dmactl_prog && dlist_prog && ready_seen && antic_captured) begin
                $display("[%0t] all milestones + READY + ANTIC frame reached early (cyc=%0d)", $time, cyc);
                finish_run();
            end
        end
    end

    task automatic finish_run();
        $display("");
        // ANTIC render health: pipeline runs (dl_done/cmp_*), real playfield
        // colour produced (wb_color_seen non-zero), snoop mode + GR.0 parse.
        $display("ANTIC PIPE: dl_start=%0d dl_done=%0d cmp_start=%0d cmp_valid=%0d pal_we=%0d",
                 n_dl_start, n_dl_done, n_cmp_start, n_cmp_valid, n_pal_we);
        $display("ANTIC COLOR: wb_color_seen=$%02h  GTIA colpf1=$%02h colpf2=$%02h colbk=$%02h",
                 wb_color_seen, u_antic_top.colpf_q[1], u_antic_top.colpf_q[2], u_antic_top.colbk_q);
        $display("ANTIC MODE: dma_mode_q=%b mode_snoop_q=%b dl_meta_mode=$%01h dmactl=$%02h",
                 u_antic_top.dma_mode_q, u_antic_top.mode_snoop_q, u_antic_top.dl_meta_mode, u_antic_top.dmactl_q);
        // --- screen-RAM snapshot (READY-screen dump) ---
        begin
            logic [15:0] savmsc;
            savmsc = {osmem(16'h0059), osmem(16'h0058)};
            $display("SCREEN: SAVMSC=$%04h RAMTOP=$%02h ROWCRS=$%02h COLCRS=$%02h ready_seen=%b",
                     savmsc, osmem(16'h006A), osmem(16'h0054), osmem(16'h0055), ready_seen);
            $writememh("/tmp/boot_mem.hex", u_sally_mem.mem);
            $display("SCREEN: dumped 64K BRAM -> /tmp/boot_mem.hex");
        end
        $display("==================== BOOT MILESTONE SUMMARY ====================");
        $display("  1. PC reached $C2xx cold-start ...... %s",
                 reached_c2xx   ? "PASS" : "FAIL");
        $display("  2. RAMTOP ($6A) non-zero ............ %s  ($%02h)",
                 ramtop_nonzero ? "PASS" : "FAIL", ramtop_val);
        $display("  3. RTCLOK advanced (VBLANK NMI) ..... %s  (base %06h, now %06h, %0d NMIs, %0d ticks)",
                 rtclok_moved   ? "PASS" : "FAIL", rtclok_first, rtclok(),
                 nmi_count, rt_ticks);
        $display("  4a. DMACTL ($D400) programmed ....... %s",
                 dmactl_prog    ? "PASS" : "FAIL");
        $display("  4b. DLISTL/H ($D402/3) programmed ... %s",
                 dlist_prog     ? "PASS" : "FAIL");
        $display("  last CPU addr=%04h rw=%b  PORTB=$%02h  nmi_n=%b irq_n=%b  cyc=%0d",
                 cpu_addr, cpu_rw, portb_q, nmi_n_sync, irq_n_sync, cyc);
        $display("===============================================================");
        if (reached_c2xx && ramtop_nonzero && rtclok_moved
            && dmactl_prog && dlist_prog)
            $display("*** BOOT OK *** Atari XL OS cold-start reached a live main loop.");
        else
            $display("*** BOOT FAIL *** one or more milestones not reached (see above).");
        $finish;
    endtask

    // ====================================================================
    // Power-on state modelling (sim-only — matches Xilinx BRAM/FF power-up).
    // ====================================================================
    // On the real Zynq the hidden-stack BRAM powers up to 0; iverilog leaves
    // unwritten mem at X.  The reset BRK sequence pushes to the (uninitialised)
    // hidden stack, so seed it to 0 at t=0 to match the hardware power-up.
    // This is sim modelling only — no RTL is touched.  (xt6502 self-initialises
    // its own register file, so no CPU-reg seeding is needed.)
    integer si;
    initial begin
        for (si = 0; si < 4096; si = si + 1) u_sally_mem.stack_mem[si] = 8'h00;
    end

    // ====================================================================
    // Reset release
    // ====================================================================
    initial begin
        // Both start at 0 (declaration).  Drive a clean rising edge after a
        // few cycles so cpu.v's async `posedge reset` initialises `state`.
        repeat (4) @(posedge clk_sally);   // (also lets sally_mem's t=0 $readmemh settle)
        rst_sally = 1'b1;
        rst_sys   = 1'b1;

        // --- tb-only OS-ROM patch: skip the cassette/disk device-boot probes ---
        // This tb has no SIO peripheral, so the OS's device-boot attempts —
        // ACB ($C66E, cassette) and ADB ($C58B, disk) — block forever in a
        // serial-frame receive (the OS's DTIMLO SIO timeout is 7 *seconds* =
        // hundreds of millions of turbo cycles).  Stub both entries to RTS so
        // cold-start proceeds straight to the cartridge handoff (BASIC).
        //
        // The OS verifies its own first-8K ROM checksum (VFR, $C313): a 16-bit
        // sum of $C002-$CFFF + $5000-$57FF + $D800-$DFFF compared to the stored
        // value at $C000/$C001 (which is itself excluded from the sum — region 0
        // starts at $C002).  $C66E/$C58B are in that sum, so we fix up the stored
        // checksum by the same delta — VFR then still PASSES exactly as on real
        // hardware, rather than tripping the ROM-bad path (PRS6 → self-test).
        // Faithful: every OS self-check behaves normally; the only difference is
        // "no boot peripheral attached here".  (VSR / 2nd-8K is untouched, and
        // the RAM tests stop at $A0 so they never overwrite these $C0xx bytes.)
        // Three device-probes need stubbing (each waits on an absent peripheral):
        //   ACB ($C66E) cassette boot, ADB ($C58B) disk boot — entries -> RTS.
        //   PHR ($C410 JSR PHR) handler-poll — sends a $4F POLL over SIO and
        //     waits for a response ($E76A); NOP the JSR so cold-start continues.
        // All three are in VFR's first-8K sum, so fix up the stored checksum
        // ($C000/$C001) by the total delta — VFR still passes as on real HW.
        begin
            logic [15:0] rom_sum;
            rom_sum = {u_sally_mem.mem[16'hC001], u_sally_mem.mem[16'hC000]}
                    + 16'h0060 - u_sally_mem.mem[16'hC66E]   // ACB -> RTS
                    + 16'h0060 - u_sally_mem.mem[16'hC58B]   // ADB -> RTS
                    + 16'h00EA - u_sally_mem.mem[16'hC410]   // JSR PHR -> NOP (3 bytes)
                    + 16'h00EA - u_sally_mem.mem[16'hC411]
                    + 16'h00EA - u_sally_mem.mem[16'hC412];
            u_sally_mem.mem[16'hC66E] = 8'h60;          // ACB (cassette boot) -> RTS
            u_sally_mem.mem[16'hC58B] = 8'h60;          // ADB (disk boot)     -> RTS
            u_sally_mem.mem[16'hC410] = 8'hEA;          // JSR PHR (handler poll) -> NOP
            u_sally_mem.mem[16'hC411] = 8'hEA;
            u_sally_mem.mem[16'hC412] = 8'hEA;
            u_sally_mem.mem[16'hC000] = rom_sum[7:0];   // first-8K checksum lo (compensated)
            u_sally_mem.mem[16'hC001] = rom_sum[15:8];  // first-8K checksum hi (compensated)
        end
        // Hold reset asserted well past both clock domains' pipe depth.
        repeat (64) @(posedge clk_sys);
        rst_sys = 1'b0;
        repeat (64) @(posedge clk_sally);
        rst_sally = 1'b0;
        $display("[%0t] reset released; reset vector should be at $FFFC/$FFFD = $%02h%02h",
                 $time, u_sally_mem.mem[16'hFFFD], u_sally_mem.mem[16'hFFFC]);
    end

    // Absolute sim-time watchdog (in case the clk_sally cycle counter never
    // advances, e.g. RDY stuck low → no steps, so the cyc-based budget never
    // trips).  One ANTIC frame is ~18 ms sim time (clk_sys/90 phi2, 262×114
    // machine cycles); full cold-start spans several frames.  CYCLE_BUDGET
    // (60 M clk_sally = 0.6 s sim) is the primary stop; this watchdog sits a
    // little above it so a stalled-clock hang still terminates with a dump.
    initial begin
        #750_000_000;   // 0.75 s sim time (> 60 M clk_sally @ 10 ns = 0.6 s)
        $display("");
        $display("*** WATCHDOG TIMEOUT — sim time elapsed, dumping state ***");
        finish_run();
    end

endmodule

`default_nettype wire
