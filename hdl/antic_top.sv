// fpga-antic top-level. ANTIC + CTIA/GTIA + DVI/HDMI scan-out for the
// rp-XT 168-pin slot. See docs/architecture.md.
//
// Bus is exposed as split data_in/data_out/data_oe so the synthesis
// wrapper that connects to package pads instantiates the vendor
// tristate IO buffer; the testbench drives bus_data_in directly and
// observes bus_data_out/bus_data_oe.
//
// No /ANTIC_* tag CS lines — fpga-antic classifies its own snoop
// traffic in fabric. See docs/wire-protocol.md § "No /ANTIC_* tag
// CS lines".

`default_nettype none

module antic_top #(
    // Clock-domain frequencies — parametric so the system can run at
    // any clock multiplier. Default = NTSC 1.7898 MHz × 90, matching
    // the M-cache-rework Step 5b clk_bus deployment (BASE_DIV=90 →
    // 161.08 MHz, 90 clean SALLY speed grades). The parameter feeds
    // POKEY's reference dividers (64 kHz / 15.7 kHz audio refs and
    // the 64 kHz POT scan) and the I2S sample-rate phase increment;
    // every consumer re-derives at synth time so the audio/SIO
    // physical rates stay correct as clk_bus scales.
    parameter int unsigned POKEY_CLK_BUS_HZ = 161_079_525,    // 90 × 1_789_772.5 NTSC phi2
    // HDMI audio sample rate (POKEY → packetiser).
    parameter int unsigned AUDIO_SAMPLE_HZ  = 48_000,
    // N6 migration knob — see docs/n6-hdl-migration.md. Phase 0 ports
    // are declared regardless; this gates which transport actually
    // drives behaviour once the per-channel HDL lands in Phases 1–4.
    //   1 = LEGACY_RP: paired-RP / peri-RP transports active (current default)
    //   0 = N6 transports active (PSSI / FMC / SPI / LTDC / IRQs)
    parameter bit          LEGACY_RP        = 1'b1
) (
    // System clock + reset
    input  wire        clk_bus,         // phi2 × CLOCK_MULT — see register $D480
    // task-0013 step 3: clk_pix input removed — the 800×600 display chain
    // (line_buffer/scan_out/palette_lut/hdmi_out) is deleted; ANTIC is paced
    // by the phi2 raster (antic_raster) and is a window *source*, not a display.
    // Zynq build: clk_pssi removed (no PSSI).
    input  wire        rst_n,           // /G_RST, active-low (sync'd internally)
    // Zynq build: rst_pssi_n removed (no PSSI).

    // CPU bus inputs
    input  wire [15:0] bus_addr,        // A[15:0]
    input  wire [7:0]  bus_data_in,     // D[7:0] from bus
    input  wire        bus_rw,          // 1 = read, 0 = write (matches 6502 R/W)

    // Page selects (active-low) — system-wide rp-XT convention.
    input  wire        d0xx_n,          // /D0xx — GTIA page
    input  wire        d4xx_n,          // /D4xx — ANTIC page

    // CPU bus outputs (D drive)
    output wire [7:0]  bus_data_out,
    output wire        bus_data_oe,

    // ---- M-PBI: external 6502 bus + cart slot + PBI + ECI -----------------
    // FPGA drives the external bus pins on every CLOCK_MULT=1 cycle so that
    // cart-slot / PBI / ECI peripherals can respond as if a real Atari 6502
    // were driving the bus. There is no external CPU socket — these are
    // slave-side fan-outs, not arbitration points.
    //
    // Gating: all of these output flops hold D=Q when `ext_bus_active` is
    // low, so at CLOCK_MULT >= 2 the FPGA pads stay static — no SSO event,
    // no EMI, no dynamic power. See architecture.md § External bus
    // interfaces and future-work.md § M-PBI.
    //
    // Outbound (FPGA -> external, address-decoded from snooped SALLY bus):
    output wire [15:0] bus_addr_o,      // A[15:0] outbound
    output wire        bus_rw_o,        // R/W outbound (1=read, 0=write)
    output wire        bus_d0xx_n_o,    // /D0xx — GTIA page select
    output wire        bus_d4xx_n_o,    // /D4xx — ANTIC page select
    output wire        bus_d1xx_n_o,    // /D1xx — PBI page select (= /EXTSEL on PBI connector)
    output wire        bus_s4_n_o,      // cart-slot CS, $8000-$9FFF
    output wire        bus_s5_n_o,      // cart-slot CS, $A000-$BFFF
    output wire        bus_cctl_n_o,    // cart control region select ($D5xx)
    output wire        bus_extenb_n_o,  // PBI master-enable (active-low)
    output wire        phi2_o,          // synthetic phi2 clock to cart/PBI/ECI (gated to CLOCK_MULT=1)

    // ---- M-aux-audio — PCM1808 I²S RX ----------------------------------
    // 3-pin slave-mode I²S RX bus to the on-board PCM1808 stereo ADC:
    //   Lin  ← SIO AUDIO_IN  (cassette / SIO-device audio)
    //   Rin  ← PBI/cart AUDIO_IN  (cart-edge AUDIO_IN, fanned to both)
    // Each channel is mono; pokey_i2s_tx sums both into both L and R of
    // the HDMI stereo output with soft saturation.
    output wire        adc_bclk_o,      // 3.072 MHz (= 64 × SAMPLE_HZ)
    output wire        adc_lrck_o,      // 48 kHz
    input  wire        adc_sdata_i,     // PCM1808 DOUT, MSB-first I²S left-justified

    // Inbound (external -> FPGA). 2-FF synchronised into clk_bus; latched
    // values are honoured at fast mode without needing a transient drop to
    // CLOCK_MULT=1 (cart-detect / PBI status are static enough that fast-
    // mode sampling of the latched value is correct).
    input  wire        bus_mpd_n_in,    // PBI Math-Pack Disable
    input  wire        bus_extirq_n_in, // PBI IRQ (open-drain, wired-OR with /IRQ)
    input  wire        bus_rd4_in,      // cart-present, $8000-$9FFF range
    input  wire        bus_rd5_in,      // cart-present, $A000-$BFFF range

    // Diagnostic surface for the synchronised input flops (keeps them
    // live in synth until the M-PBI dispatch logic that consumes them
    // lands). {/MPD, RD4, RD5}. /EXTIRQ wires into the IRQ tree directly.
    output wire [2:0]  bus_pbi_in_status_o,

    // ANTIC-driven status (active-low)
    output wire        nmi_n,
    output wire        halt_n,
    output wire        rdy_n,

    // POKEY-driven IRQ (active-low). Asserted while any IRQEN-enabled
    // POKEY source has its latch set. Goes to the SALLY core (M24)
    // once that lands; meanwhile the synth wrapper drives it onto
    // the external IRQ_n bus pin.
    output wire        irq_n,

    // M23-7 — POKEY → HDMI audio packet feed. 4 stereo subpackets,
    // 24-bit LPCM @ 48 kHz, IEC 192-frame block tracking. Consumed
    // by hdmi_pkt_source once hdmi_out is integrated; meanwhile
    // dangles as a top-level output for sim observation.
    output wire [23:0] audio_l0, audio_l1, audio_l2, audio_l3,
    output wire [23:0] audio_r0, audio_r1, audio_r2, audio_r3,
    output wire [3:0]  audio_present,
    output wire [3:0]  audio_flat,
    output wire [3:0]  audio_block_start,
    output wire        audio_frame_ready,

    // DMA-mode bus master output (active when dma_mode_q=1, i.e. when
    // the chiplet-extension register $D481[0]=0). At the FPGA pads
    // these multiplex with bus_addr / bus_rw / bus_data_in via the
    // package-level tristate buffers; in sim they're separate so the
    // testbench can model the address-out path independently.
    output wire [15:0] dma_addr_o,
    output wire        dma_rw_o,
    output wire        dma_oe,

    // ---- TMDS / RGB video output — REMOVED (task-0013 step 3) ---------
    // The 800×600 display chain that owned these pads (hdmi_out's TMDS
    // serializers + the parallel RGB565/SiI9022A path) is deleted.  In the
    // compositor model the HDMI pads are driven by the top-level compositor →
    // sprite chain, not by ANTIC.  clk_bit (the 5× serializer clock) goes with
    // it.  The ANTIC image now reaches the screen via the §5 writeback tap
    // (wb_* below) → DDR3 XL surface → compositor.

    // Diagnostic counters (consumed by serial-link logic in later milestones)
    output wire [31:0] diag_wsync_overdue_count,

    // ---- Keyboard event ingest (M23-4) -----------------------------------
    // Pre-translated Atari KBCODE byte (scan code [5:0] + shift [6] +
    // ctrl [7]) from the RP2354's USB-HID handler. A 1-cycle valid
    // pulse loads the byte into POKEY's KBCODE register and pulses
    // KEY_INT. Side channel is one of the spare RP→FPGA control wires
    // (per pinmap.h); the synth wrapper above re-clocks the pulse
    // into clk_bus before it reaches this port.
    input  wire        kbd_event_valid,
    input  wire [7:0]  kbd_event_code,

    // ---- Peripheral RP link (M25-2 + M25-2c-rev + M25-3c) --------------
    // The peri-RP2354B handles POT / SIO / SD card. peri_pot_bridge
    // (M25-3c) wraps peri_link for POT-scan traffic — the POT pins
    // moved off antic_top entirely and live on the peri-RP's GPIO.
    // SIO + SD bridges land in M25-4 / M25-5 above peri_link.
    output wire        spi_clk,            // SPI MODE 0, ≈5 MHz at 162 MHz clk_bus
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n,           // active-low slave select
    input  wire        spi_irq,            // active-low (open-drain on peri-RP)

    // ---- Joystick PCAL9722 link (M25-2c-rev) ----------------------------
    // PCAL9722 GPIO expander hosts the 4×5 joystick + fire pins on
    // its 5 V VDDP side. Its 1.8 V VDDI side ties directly to FPGA
    // HSIO (no LVC8T245 needed — the chip's split-supply design
    // does the level translation internally).
    //
    // 4-pin SPI MODE 0 (CPOL=0, CPHA=0) at ≈5 MHz: FPGA = master,
    // PCAL9722 = slave. 24-bit /CS-framed transactions: cmd byte
    // (device addr + R/W) + reg addr byte + data byte. INT_N is
    // active-low, asserted on any unmasked input change — used by
    // joy_bridge to short-circuit the polling wait when the user
    // moves a stick or presses fire.
    //
    // pia_regs's joy_*_out / _oe inputs and the PIA-shadow joy_*_in
    // outputs both stay internal; only the SPI pads cross the
    // antic_top boundary.
    output wire        joy_spi_clk,
    output wire        joy_spi_mosi,
    input  wire        joy_spi_miso,
    output wire        joy_spi_cs_n,
    input  wire        joy_spi_int_n,

    // ---- ANTIC DMA read port → external BRAM (sally_mem's dma port) ----
    // ANTIC's dl_parser and compositor read scanline data through a
    // bram_shim into this port.  On the Zynq build the BRAM lives in
    // sally_mem (its second port at clk_bus), so SALLY writes are
    // visible to ANTIC without a separate shadow memory.
    output wire [15:0] bram_addr,
    input  wire [7:0]  bram_rdata,

    // ---- M24-int-1 — internal SALLY observability ----------------------
    // Internal SALLY's bus is exposed as an observation port for the
    // synth wrapper / external bus pin-out. M24-int-2 will mux the
    // existing external bus_addr / bus_data / bus_rw inputs against
    // this internal CPU bus; today the internal CPU runs in parallel
    // with the external one and these ports surface for synth + diag.
    // Zynq build: shadow SALLY core + bank_translator + N6 PSSI removed.
    // The main CPU in fpga_xt_top handles everything.

    // Zynq build: N6 PSSI stream removed — no co-processor on Zynq.

    // ---- FMC slave: 8-bit memory-mapped peripheral to N6 ----------------
    // N6 is FMC master; 256-byte address space. Async mode (no source-sync
    // clock from N6). Bidirectional data uses the project's split-pad
    // convention: data_in / data_out / data_oe at RTL level; the synth
    // wrapper combines them with a vendor IO primitive.
    // Zynq build: input  wire [7:0]  n6_fmc_addr           = 8'h00,  -- removed (no N6)
    // Zynq build: input  wire [7:0]  n6_fmc_data_in        = 8'h00,  -- removed (no N6)
    // Zynq build: output wire [7:0]  n6_fmc_data_out,  -- removed (no N6)
    // Zynq build: output wire        n6_fmc_data_oe,  -- removed (no N6)
    // Zynq build: input  wire        n6_fmc_cs_n           = 1'b1,   // /CS de-asserted  -- removed (no N6)
    // Zynq build: input  wire        n6_fmc_oe_n           = 1'b1,   // /OE de-asserted  -- removed (no N6)
    // Zynq build: input  wire        n6_fmc_we_n           = 1'b1,   // /WE de-asserted  -- removed (no N6)

    // ---- SPI master: 4-wire event payload pull (FPGA master, MODE 0) ----
    output wire        n6_spi_clk,
    output wire        n6_spi_mosi,
    input  wire        n6_spi_miso           = 1'b0,
    output wire        n6_spi_cs_n,

    // ---- LTDC capture: 24-bit RGB888 + sync video input -----------------
    // N6 LTDC scans out its framebuffer; FPGA captures and feeds TMDS.
    // 28 pins total: 24 data + HSYNC + VSYNC + DE + PIXCLK.
    input  wire [7:0]  n6_ltdc_r             = 8'h00,
    input  wire [7:0]  n6_ltdc_g             = 8'h00,
    input  wire [7:0]  n6_ltdc_b             = 8'h00,
    input  wire        n6_ltdc_hsync         = 1'b0,
    input  wire        n6_ltdc_vsync         = 1'b0,
    input  wire        n6_ltdc_de            = 1'b0,
    input  wire        n6_ltdc_pixclk        = 1'b0,

    // ---- Event IRQs: 4 GPIOs (2 each direction, HP/LP priority split) ---
    // FPGA → N6: HP = latency-sensitive (RPC request); LP = status/error.
    // N6 → FPGA: HP = user input / RPC response; LP = system notify.
    output wire        n6_irq_to_n6_hp,
    output wire        n6_irq_to_n6_lp,
    input  wire        n6_irq_to_fpga_hp     = 1'b0,
    input  wire        n6_irq_to_fpga_lp     = 1'b0,

    // PORTB ($D301) state — needed by sally_mem for ROM vs RAM control.
    output wire [7:0]  portb_q,

    // ---- ANTIC render tap → compositor writeback (video-arch §5, phase 2) --
    // The per-pixel-pair render stream, palette writes and frame/line pulses
    // that drive the ANTIC->DDR3 writeback master (antic_writeback) at the
    // top level.  All clk_bus domain (= clk_sys in this build).  This is now
    // ANTIC's ONLY image output path — the 800×600 line_buffer/scan_out/
    // palette_lut/hdmi_out display chain was deleted in task-0013 step 3.
    output wire        wb_pix_valid,    // 1-cycle pulse: a pixel-PAIR is ready
    output wire [7:0]  wb_pix_pair,     // pair index within the line (col/2)
    output wire [7:0]  wb_color_lo,     // 8-bit Atari colour code, even column
    output wire [7:0]  wb_color_hi,     //                          odd  column
    output wire [7:0]  wb_atari_row,    // ANTIC row being rendered (0..191)
    output wire        wb_row_flush,    // pulse (line_start): row complete -> DMA
    output wire        wb_frame_done,   // pulse (vbi): flip the double buffer
    output wire        wb_pal_we,       // palette write strobe (clk_bus origin)
    output wire [7:0]  wb_pal_idx,      // palette index
    output wire [23:0] wb_pal_rgb       // {R,G,B} palette entry
);

    // Synchronise /G_RST into the bus_clk domain.
    logic rst_n_q1, rst_n_q2;
    always_ff @(posedge clk_bus) begin
        rst_n_q1 <= rst_n;
        rst_n_q2 <= rst_n_q1;
    end
    wire rst_bus = ~rst_n_q2;

    // ---- M-PBI: external-bus inputs (2-FF synchronisers) ---------------
    // /MPD, /EXTIRQ, RD4, RD5 are 3.3 V-domain inputs from cart/PBI
    // devices. 2-FF sync into clk_bus; the synchronised value is honoured
    // at any CLOCK_MULT (input-direction LVC8T245s stay enabled at fast
    // mode, since their pads don't toggle and cost nothing in power).
    // Declared up here (rather than alongside the output gating block
    // further down) because /EXTIRQ feeds the IRQ tree that SALLY
    // instantiates well before the gating block.
    logic [1:0] mpd_n_sync_q, extirq_n_sync_q, rd4_sync_q, rd5_sync_q;
    // M-PBI step 3: 2-FF sync of bus_data_in[7:0] for PBI / cart reads.
    // The cart/PBI device drives D[7:0] during reads from its decoded
    // window (/D1xx, /MPD $D800-$DFFF, cart slots) — async to clk_bus,
    // so we sync per-bit before SALLY consumes it.
    logic [7:0] data_in_sync0_q, data_in_sync1_q;
    always_ff @(posedge clk_bus) begin
        if (rst_bus) begin
            mpd_n_sync_q    <= 2'b11;   // inactive (no MPD assert)
            extirq_n_sync_q <= 2'b11;   // inactive (no IRQ)
            rd4_sync_q      <= 2'b11;   // no cart present
            rd5_sync_q      <= 2'b11;   // no cart present
            data_in_sync0_q <= 8'hFF;
            data_in_sync1_q <= 8'hFF;
        end else begin
            mpd_n_sync_q    <= {mpd_n_sync_q[0],    bus_mpd_n_in};
            extirq_n_sync_q <= {extirq_n_sync_q[0], bus_extirq_n_in};
            rd4_sync_q      <= {rd4_sync_q[0],      bus_rd4_in};
            rd5_sync_q      <= {rd5_sync_q[0],      bus_rd5_in};
            data_in_sync0_q <= bus_data_in;
            data_in_sync1_q <= data_in_sync0_q;
        end
    end
    wire bus_mpd_n_q    = mpd_n_sync_q[1];
    wire bus_extirq_n_q = extirq_n_sync_q[1];
    wire bus_rd4_q      = rd4_sync_q[1];
    wire bus_rd5_q      = rd5_sync_q[1];
    wire [7:0] bus_data_in_q = data_in_sync1_q;
    assign bus_pbi_in_status_o = {bus_mpd_n_q, bus_rd4_q, bus_rd5_q};

    // Synthetic phi2 derived from the bus clock. clk_bus runs at
    // BASE_DIV × phi2 ≈ 161 MHz at the M-cache-rework Step 5b
    // ceiling (BASE_DIV=90 → 12 clean SALLY speed grades). The
    // counter wraps at BASE_DIV/2-1 and toggles `phi2`, giving
    // phi2 = clk_bus / BASE_DIV. The 1-cycle phi2_tick pulse on
    // each phi2 rising edge is exposed for use by POKEY's
    // high-freq channel mode and fast pot-scan path (no
    // multiplier hardcoded in any POKEY-side logic — phi2_tick
    // is the only contract).
    localparam int unsigned BASE_DIV    = 90;
    localparam int unsigned PHI2_CTR_W  = $clog2(BASE_DIV);
    localparam int unsigned PHI2_HALF   = (BASE_DIV / 2) - 1;       // 44 at BASE_DIV=90

    logic [PHI2_CTR_W-1:0] phi2_div = '0;
    logic                  phi2     = 1'b0;
    logic                  phi2_q   = 1'b0;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) begin
            phi2_div <= '0;
            phi2     <= 1'b0;
            phi2_q   <= 1'b0;
        end else begin
            phi2_q <= phi2;
            if (phi2_div == PHI2_CTR_W'(PHI2_HALF)) begin
                phi2_div <= '0;
                phi2     <= ~phi2;
            end else begin
                phi2_div <= phi2_div + 1'b1;
            end
        end
    end
    wire phi2_tick = phi2 & ~phi2_q;     // 1-cycle pulse on phi2 rising edge
    wire phi2_fall = phi2_q & ~phi2;     // 1-cycle pulse on phi2 falling edge

    // ---- ANTIC native raster timer (video-arch §5.1, task-0013) ----------
    // phi2-paced raster heartbeat — replaces the 800×600 hdmi_out vbeam as the
    // source of atari_row / line_start / vbi_start / vcount (the display chain
    // is bypassed for output; see §5.1).  Locked to phi2 so VCOUNT/WSYNC/VBI
    // cadence is correct vs the CPU.  All clk_bus — no CDC.
    wire [8:0] ar_scanline;
    wire [7:0] ar_phi2_in_line;
    wire       ar_line_start, ar_vbi_start;
    wire [7:0] ar_atari_row, ar_vcount;
    antic_raster u_antic_raster (
        .clk          (clk_bus),
        .rst          (rst_bus),
        .phi2_tick    (phi2_tick),
        .scanline     (ar_scanline),
        .phi2_in_line (ar_phi2_in_line),
        .line_start   (ar_line_start),
        .vbi_start    (ar_vbi_start),
        .atari_row    (ar_atari_row),
        .vcount       (ar_vcount)
    );

    // ---- M-PBI deferred #1: phi2-cycle-gated bus_data_in capture --------
    // Capture the 2-FF-synced external D[7:0] on phi2 falling edge, when
    // any PBI/cart slave has had the full phi2-high window to drive the
    // bus. Hold the captured value through phi2-low into the next phi2-
    // high until the next capture. SALLY consumes this stable, late-
    // phi2-cycle sample (instead of the live `bus_data_in_q`) for /D1xx
    // and /MPD-window reads. Eliminates the "stale data" concern when a
    // slow slave hasn't yet driven by the time SALLY would otherwise
    // sample.
    logic [7:0] bus_pbi_rdata_q;
    always_ff @(posedge clk_bus) begin
        if (rst_bus)        bus_pbi_rdata_q <= 8'hFF;
        else if (phi2_fall) bus_pbi_rdata_q <= bus_data_in_q;
    end

    // ---- Snoop dispatch -------------------------------------------------
    wire [15:0] snoop_addr;
    wire [7:0]  snoop_data;
    wire        snoop_we_gtia;
    wire        snoop_we_antic;
    wire        snoop_we_pokey_l, snoop_we_pokey_r;
    wire        snoop_we_cache;
    wire        snoop_we_pia;
    wire        snoop_we_screen;
    wire        snoop_re_gtia;
    wire        snoop_re_antic;
    wire        snoop_re_pokey_l, snoop_re_pokey_r;
    wire        snoop_re_cache;

    // Zynq build: no internal SALLY stack — snoop always reads the
    // external bus (from the main CPU in fpga_xt_top).
    wire [15:0] snoop_bus_addr_w   = bus_addr;
    wire [7:0]  snoop_bus_data_w   = bus_data_in;
    wire        snoop_bus_rw_w     = bus_rw;
    wire [15:0] read_addr_w        = bus_addr;

    bus_snoop u_snoop (
        .clk              (clk_bus),
        .rst              (rst_bus),
        .bus_addr         (snoop_bus_addr_w),
        .bus_data_in      (snoop_bus_data_w),
        .bus_rw           (snoop_bus_rw_w),
        .d0xx_n           (d0xx_n),
        .d4xx_n           (d4xx_n),
        .snoop_addr       (snoop_addr),
        .snoop_data       (snoop_data),
        .snoop_we_gtia    (snoop_we_gtia),
        .snoop_we_antic   (snoop_we_antic),
        .snoop_we_pokey_l (snoop_we_pokey_l),
        .snoop_we_pokey_r (snoop_we_pokey_r),
        .snoop_we_cache   (snoop_we_cache),
        .snoop_we_pia     (snoop_we_pia),
        .snoop_we_screen  (snoop_we_screen),
        .snoop_re_gtia    (snoop_re_gtia),
        .snoop_re_antic   (snoop_re_antic),
        .snoop_re_pokey_l (snoop_re_pokey_l),
        .snoop_re_pokey_r (snoop_re_pokey_r),
        .snoop_re_cache   (snoop_re_cache)
    );

    // ---- Diagnostic counters --------------------------------------------
    // wsync_overdue is now driven by wsync_gen (M13 wiring closed by
    // M-wsync-105). Forward declaration; the actual signal comes from
    // u_wsync_gen further down.
    wire [31:0] wsync_overdue_count_q;
    assign diag_wsync_overdue_count = wsync_overdue_count_q;

    // ---- ANTIC register file --------------------------------------------
    // Write port is registered (1-cycle latency from bus sample).
    // Read port is combinational from live bus_addr — the master expects
    // D valid during CLK-high of the same cycle.
    wire [7:0] antic_read_data;
    wire       wsync_pending;             // M13: drives wsync_gen
    wire       nmires_strobe;             // M12: drives nmi_gen
    wire       pal_write_strobe;          // M-video-int: 1-cycle commit pulse to palette_lut
    wire [7:0] pal_r_q, pal_g_q, pal_b_q;
    wire [7:0] pal_idx_q;
    wire [7:0] dmactl_q, chactl_q, dlistl_q, dlisth_q;
    wire [7:0] hscrol_q, vscrol_q, pmbase_q, chbase_q, nmien_q;
    wire       mode_snoop_q;
    wire       cpu_internal_q;
    wire [7:0] clock_mult_q, output_mode_q;

    // ANTIC has no banking under the xtc memory model — it reads the flat
    // 64 KB BRAM directly via sally_mem's dma port.  The antic_regs
    // $D488-$D48B "bank" registers are now vestigial (writable/readable but
    // unwired), so their outputs are left unconnected at the instance below.
    // M24-6 — OS ROM load path (chiplet-ext $D48C-$D48F). Streams a
    // baked-in OS image into sally_mem's BRAM at boot, then locks.
    wire [15:0] os_rom_addr_q;
    wire [7:0]  os_rom_data_q;
    wire        os_rom_we;
    wire        os_rom_locked_q;

    // ---- Raster heartbeat — phi2-paced (antic_raster, instanced above) --
    // VCOUNT / atari_row / line_start / vbi_start all come from the phi2
    // raster timer now.  The old 800×600 vbeam-feedback CDC (clk_pix →
    // clk_bus 2-FF sync of hdmi_out's vbeam) was deleted in task-0013 step 3
    // along with the display chain that drove it.
    //
    // Forward declarations for nmi_gen outputs (block further down).
    wire [7:0]  nmist_q;
    wire [7:0]  nmi_cur_row;
    wire        nmi_cur_row_dli;
    wire        nmi_n_w;

    wire        vbi_start_pulse_bus  = ar_vbi_start;
    wire        line_start_pulse_bus = ar_line_start;

    antic_regs u_antic_regs (
        .clk                  (clk_bus),
        .rst                  (rst_bus),
        .we                   (snoop_we_antic),
        .waddr                (snoop_addr[7:0]),
        .wdata                (snoop_data),
        .raddr                (read_addr_w[7:0]),
        .rdata                (antic_read_data),
        .wsync_pending        (wsync_pending),
        .nmires_strobe        (nmires_strobe),
        .pal_write_strobe     (pal_write_strobe),
        .pal_r_q              (pal_r_q),
        .pal_g_q              (pal_g_q),
        .pal_b_q              (pal_b_q),
        .pal_idx_q            (pal_idx_q),
        .dmactl_q             (dmactl_q),
        .chactl_q             (chactl_q),
        .dlistl_q             (dlistl_q),
        .dlisth_q             (dlisth_q),
        .hscrol_q             (hscrol_q),
        .vscrol_q             (vscrol_q),
        .pmbase_q             (pmbase_q),
        .chbase_q             (chbase_q),
        .nmien_q              (nmien_q),
        .mode_snoop_q         (mode_snoop_q),
        .cpu_internal_q       (cpu_internal_q),
        .clock_mult_q         (clock_mult_q),
        .output_mode_q        (output_mode_q),
        // antic_*_bank_q ($D488-$D48B) left unconnected — ANTIC no longer banks.
        .os_rom_addr_q        (os_rom_addr_q),
        .os_rom_data_q        (os_rom_data_q),
        .os_rom_we            (os_rom_we),
        .os_rom_locked_q      (os_rom_locked_q),
        .vcount_in            (ar_vcount),             // VCOUNT from the phi2 raster timer
        .nmist_in             (nmist_q),               // from nmi_gen
        .serial_clock_mult_in (8'd12),                 // boot default; serial-link push later

        // M-PBI step 2 — PBI / cart-detect status into $D481 read bits [7:4].
        .bus_rd4_in       (bus_rd4_q),
        .bus_rd5_in       (bus_rd5_q),
        .bus_mpd_n_in     (bus_mpd_n_q),
        .bus_extirq_n_in  (bus_extirq_n_q)
    );

    // ---- GTIA register file ---------------------------------------------
    wire [7:0] gtia_read_data;
    wire [7:0] hposp_q [0:3];
    wire [7:0] hposm_q [0:3];
    wire [7:0] sizep_q [0:3];
    wire [7:0] sizem_q;
    wire [7:0] grafp_q [0:3];
    wire [7:0] grafm_q;
    wire [7:0] colpm_q [0:3];
    wire [7:0] colpf_q [0:3];
    wire [7:0] colbk_q;
    wire [7:0] prior_q;
    wire [7:0] vdelay_q;
    wire [7:0] gractl_q;
    wire [7:0] consol_w_q;
    wire       hitclr_strobe;

    // Collision latches come from the compositor (mpf_q/ppf_q/mpl_q/ppl_q
    // are 16-bit packed, gtia_regs takes 4× 8-bit arrays). We unpack each
    // 4-bit nibble into the low nibble of an 8-bit slot.
    wire [15:0] cmp_mpf_q;
    wire [15:0] cmp_ppf_q;
    wire [15:0] cmp_mpl_q;
    wire [15:0] cmp_ppl_q;
    wire [7:0]  m_pf_in [0:3];
    wire [7:0]  p_pf_in [0:3];
    wire [7:0]  m_pl_in [0:3];
    wire [7:0]  p_pl_in [0:3];
    wire [7:0]  trig_high [0:3];
    // Forward-declared so the generate block below can reference the
    // peri_bridge shadow at line ~1180. iverilog's elaborator binds
    // generate-block references at parse time and would otherwise fail
    // to resolve w_joy_fire[i].
    wire [3:0]  w_joy_fire;
    genvar i;
    generate
        for (i = 0; i < 4; i++) begin : g_collision
            assign m_pf_in[i] = {4'h0, cmp_mpf_q[4*i +: 4]};
            assign p_pf_in[i] = {4'h0, cmp_ppf_q[4*i +: 4]};
            assign m_pl_in[i] = {4'h0, cmp_mpl_q[4*i +: 4]};
            assign p_pl_in[i] = {4'h0, cmp_ppl_q[4*i +: 4]};
            // M25-1: TRIG0..TRIG3 sourced from w_joy_fire[i] (active-low
            // shadow of peri-RP TRIG register → active-high "pressed"
            // semantics matching GTIA's trig_in (bit 0 = 1 when
            // pressed). The gtia_regs read flips bit 0 to match Atari's
            // "0 = button pressed" register convention.
            assign trig_high[i] = {7'h00, w_joy_fire[i]};
        end
    endgenerate

    gtia_regs u_gtia_regs (
        .clk            (clk_bus),
        .rst            (rst_bus),
        .we             (snoop_we_gtia),
        .waddr          (snoop_addr[7:0]),
        .wdata          (snoop_data),
        .raddr                (read_addr_w[7:0]),
        .rdata          (gtia_read_data),
        .hposp_q        (hposp_q),
        .hposm_q        (hposm_q),
        .sizep_q        (sizep_q),
        .sizem_q        (sizem_q),
        .grafp_q        (grafp_q),
        .grafm_q        (grafm_q),
        .colpm_q        (colpm_q),
        .colpf_q        (colpf_q),
        .colbk_q        (colbk_q),
        .prior_q        (prior_q),
        .vdelay_q       (vdelay_q),
        .gractl_q       (gractl_q),
        .consol_w_q     (consol_w_q),
        .m_pf_in        (m_pf_in),
        .p_pf_in        (p_pf_in),
        .m_pl_in        (m_pl_in),
        .p_pl_in        (p_pl_in),
        .trig_in        (trig_high),
        .pal_sense_in   (8'h02),         // NTSC sense default
        .consol_r_in    (8'h07),         // no console keys pressed default
        .hitclr_strobe  (hitclr_strobe)
    );

    // ---- POKEY × 2 (stereo, M23-1..M23-7) -------------------------------
    // Two POKEY instances — left at $D20x (full I/O: keyboard, POT,
    // serial / IRQ aggregation), right at $D21x (audio-only stereo
    // companion, all I/O tied off, irq_n unused). The 130XE-style
    // stereo mod address decoding lives in bus_snoop.
    //
    // Per-side channel outputs feed pokey_i2s_tx, which builds the
    // 4-deep HDMI audio packet buffer. SEROUT / SKCTL outputs dangle
    // for the future SIO state machine (M25); right-side equivalents
    // are unused.
    wire [7:0] pokey_l_read_data, pokey_r_read_data;
    wire [3:0] pokey_l_ch1, pokey_l_ch2, pokey_l_ch3, pokey_l_ch4;
    wire [3:0] pokey_r_ch1, pokey_r_ch2, pokey_r_ch3, pokey_r_ch4;
    wire [7:0] pokey_l_serout_byte;
    wire       pokey_l_serout_strobe;
    wire [7:0] pokey_l_skctl;
    wire       pokey_l_irq_n;       // POKEY's own irq_n, before M-PBI /EXTIRQ wired-OR
    // IRQ tree: POKEY irq_n wired-OR with PBI /EXTIRQ (both active-low, AND combines).
    // Drives both the external irq_n pin and SALLY's .irq_n input.
    wire       irq_n_combined = pokey_l_irq_n & bus_extirq_n_q;
    assign irq_n = irq_n_combined;
    wire       pokey_r_irq_n_unused;        // intentionally ignored

    // M25-3c POT + M25-4 SIO shadow signals from peri_bridge
    // (instantiated near peri_link below). Forward-declared so the
    // pokey instances + the bridge can both reference them.
    wire [7:0] pot_shadow_0, pot_shadow_1, pot_shadow_2, pot_shadow_3;
    wire [7:0] pot_shadow_4, pot_shadow_5, pot_shadow_6, pot_shadow_7;
    wire [7:0] pot_shadow_allpot;
    wire       pot_bridge_potgo_pulse;
    wire       pot_bridge_fast_scan;
    // SIO bridge wires.
    wire [7:0] sio_bridge_in_byte;
    wire       sio_bridge_in_byte_pulse;
    wire       sio_bridge_framing_err;
    wire       sio_bridge_input_overrun;
    wire       sio_bridge_input_busy;
    wire       sio_bridge_break_key_pulse;
    wire       sio_bridge_out_ready_pulse;
    wire       sio_bridge_out_complete;

    pokey #(.CLK_BUS_HZ(POKEY_CLK_BUS_HZ)) u_pokey_l (
        .clk                  (clk_bus),
        .rst                  (rst_bus),
        .phi2_tick            (phi2_tick),
        .we                   (snoop_we_pokey_l),
        .waddr                (snoop_addr[7:0]),
        .wdata                (snoop_data),
        .re                   (snoop_re_pokey_l),
        .re_addr              (snoop_addr[7:0]),
        .raddr                (read_addr_w[7:0]),
        .rdata                (pokey_l_read_data),
        .kbd_event_valid      (kbd_event_valid),
        .kbd_event_code       (kbd_event_code),
        .shadow_pot0          (pot_shadow_0),
        .shadow_pot1          (pot_shadow_1),
        .shadow_pot2          (pot_shadow_2),
        .shadow_pot3          (pot_shadow_3),
        .shadow_pot4          (pot_shadow_4),
        .shadow_pot5          (pot_shadow_5),
        .shadow_pot6          (pot_shadow_6),
        .shadow_pot7          (pot_shadow_7),
        .shadow_allpot        (pot_shadow_allpot),
        .bridge_potgo_pulse   (pot_bridge_potgo_pulse),
        .bridge_fast_scan     (pot_bridge_fast_scan),
        .ch1_out              (pokey_l_ch1),
        .ch2_out              (pokey_l_ch2),
        .ch3_out              (pokey_l_ch3),
        .ch4_out              (pokey_l_ch4),
        // M25-4: SIO via peri_bridge ↔ peri-RP firmware
        .ser_out_ready_pulse  (sio_bridge_out_ready_pulse),
        .ser_out_complete     (sio_bridge_out_complete),
        .ser_in_byte_pulse    (sio_bridge_in_byte_pulse),
        .ser_in_byte          (sio_bridge_in_byte),
        .break_key_pulse      (sio_bridge_break_key_pulse),
        .ser_framing_err      (sio_bridge_framing_err),
        .ser_input_overrun    (sio_bridge_input_overrun),
        .ser_input_busy       (sio_bridge_input_busy),
        .irq_n                (pokey_l_irq_n),
        .serout_byte          (pokey_l_serout_byte),
        .serout_strobe        (pokey_l_serout_strobe),
        .skctl_out            (pokey_l_skctl)
    );

    // Right POKEY ($D21x) — audio-only. Keyboard, POT shadow, and all
    // serial / IRQ sources tied off. The OS doesn't know about a
    // second POKEY for IRQ purposes, so its IRQ output is intentionally
    // dropped on the floor here.
    wire [7:0] pokey_r_serout_byte_unused;
    wire       pokey_r_serout_strobe_unused;
    wire [7:0] pokey_r_skctl_unused;
    wire       pokey_r_bridge_potgo_unused;
    wire       pokey_r_bridge_fast_unused;

    pokey #(.CLK_BUS_HZ(POKEY_CLK_BUS_HZ)) u_pokey_r (
        .clk                  (clk_bus),
        .rst                  (rst_bus),
        .phi2_tick            (phi2_tick),
        .we                   (snoop_we_pokey_r),
        .waddr                (snoop_addr[7:0]),
        .wdata                (snoop_data),
        .re                   (snoop_re_pokey_r),
        .re_addr              (snoop_addr[7:0]),
        .raddr                (read_addr_w[7:0]),
        .rdata                (pokey_r_read_data),
        .kbd_event_valid      (1'b0),
        .kbd_event_code       (8'h00),
        .shadow_pot0          (8'h00),
        .shadow_pot1          (8'h00),
        .shadow_pot2          (8'h00),
        .shadow_pot3          (8'h00),
        .shadow_pot4          (8'h00),
        .shadow_pot5          (8'h00),
        .shadow_pot6          (8'h00),
        .shadow_pot7          (8'h00),
        .shadow_allpot        (8'h00),
        .bridge_potgo_pulse   (pokey_r_bridge_potgo_unused),
        .bridge_fast_scan     (pokey_r_bridge_fast_unused),
        .ch1_out              (pokey_r_ch1),
        .ch2_out              (pokey_r_ch2),
        .ch3_out              (pokey_r_ch3),
        .ch4_out              (pokey_r_ch4),
        .ser_out_ready_pulse  (1'b0),
        .ser_out_complete     (1'b1),
        .ser_in_byte_pulse    (1'b0),
        .ser_in_byte          (8'h00),
        .break_key_pulse      (1'b0),
        .ser_framing_err      (1'b0),
        .ser_input_overrun    (1'b0),
        .ser_input_busy       (1'b0),
        .irq_n                (pokey_r_irq_n_unused),
        .serout_byte          (pokey_r_serout_byte_unused),
        .serout_strobe        (pokey_r_serout_strobe_unused),
        .skctl_out            (pokey_r_skctl_unused)
    );

    // M23-stereo: dual-mono fallback until software identifies itself
    // as stereo-aware by writing to $D21x. The Atari OS and the
    // overwhelming majority of titles only know about a single POKEY
    // at $D200, so playing back POKEY-R as silence by default would
    // give those titles half-volume mono on the left channel only.
    // Instead, we mirror POKEY-L to the right output until the first
    // $D21x write, then switch to true stereo. There is no published
    // register-based way for software to detect dual-POKEY, so the
    // first $D21x write is the de-facto opt-in signal.
    //
    // Once latched, the flag stays set until /G_RST. Stereo titles
    // that do their own initialisation will overwrite the
    // POKEY-R registers from idle anyway; mono titles after a stereo
    // title would see the previous program's POKEY-R state, but
    // that's identical to running on real hardware with two physical
    // POKEY chips and no soft-reset between programs.
    logic stereo_active_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus)                  stereo_active_q <= 1'b0;
        else if (snoop_we_pokey_r)    stereo_active_q <= 1'b1;
    end

    // Right-channel mux: dual-mono until stereo_active_q goes high.
    wire [3:0] ch1_r_mix_w = stereo_active_q ? pokey_r_ch1 : pokey_l_ch1;
    wire [3:0] ch2_r_mix_w = stereo_active_q ? pokey_r_ch2 : pokey_l_ch2;
    wire [3:0] ch3_r_mix_w = stereo_active_q ? pokey_r_ch3 : pokey_l_ch3;
    wire [3:0] ch4_r_mix_w = stereo_active_q ? pokey_r_ch4 : pokey_l_ch4;

    // ---- M-aux-audio — PCM1808 I²S RX ----------------------------------
    // Drives BCK / LRCK out + samples SDATA. Outputs adc_l_w / adc_r_w
    // (24-bit signed two's complement) feed pokey_i2s_tx's mixer.
    wire signed [23:0] adc_l_w;
    wire signed [23:0] adc_r_w;
    pcm1808_rx #(
        .CLK_BUS_HZ (POKEY_CLK_BUS_HZ),
        .SAMPLE_HZ  (48_000),
        .PHASE_BITS (24)
    ) u_pcm1808_rx (
        .clk        (clk_bus),
        .rst        (rst_bus),
        .adc_bclk_o (adc_bclk_o),
        .adc_lrck_o (adc_lrck_o),
        .adc_sdata_i(adc_sdata_i),
        .adc_l      (adc_l_w),
        .adc_r      (adc_r_w),
        .adc_strobe ()        // unused — pokey_i2s_tx has its own sample-rate strobe
    );

    // M23-7 — stereo audio mixer feeding hdmi_pkt_source.
    pokey_i2s_tx #(.CLK_BUS_HZ(POKEY_CLK_BUS_HZ),
                   .SAMPLE_HZ(AUDIO_SAMPLE_HZ)) u_audio_pack (
        .clk               (clk_bus),
        .rst               (rst_bus),
        .ch1_l             (pokey_l_ch1), .ch2_l (pokey_l_ch2),
        .ch3_l             (pokey_l_ch3), .ch4_l (pokey_l_ch4),
        .ch1_r             (ch1_r_mix_w), .ch2_r (ch2_r_mix_w),
        .ch3_r             (ch3_r_mix_w), .ch4_r (ch4_r_mix_w),
        .adc_l_in          (adc_l_w),       // M-aux-audio: PCM1808 L channel (SIO AUDIO_IN)
        .adc_r_in          (adc_r_w),       // M-aux-audio: PCM1808 R channel (PBI AUDIO_IN)
        .audio_l0          (audio_l0), .audio_l1 (audio_l1),
        .audio_l2          (audio_l2), .audio_l3 (audio_l3),
        .audio_r0          (audio_r0), .audio_r1 (audio_r1),
        .audio_r2          (audio_r2), .audio_r3 (audio_r3),
        .audio_present     (audio_present),
        .audio_flat        (audio_flat),
        .audio_block_start (audio_block_start),
        .frame_ready       (audio_frame_ready),
        .sample_strobe     (),
        .last_sample_l     (),
        .last_sample_r     ()
    );

    // ---- CPU shadow RAM (HyperRAM-backed) -------------------------------
    // System RAM lives off-chip in HyperRAM via the Efinix HyperRAM
    // Controller IP, accessed through hyperram_shim:
    //   - bus_snoop drives the write port (snoop_we_screen / snoop_addr /
    //     snoop_data); the shim's wready is currently unobserved (1-deep
    //     write FIFO; bus_snoop fires ≤ 1× per ~12 fabric cycles, well
    //     below the shim's drain rate, so saturation is not expected).
    //   - dl_parser reads via shim port A; compositor via port B —
    //     mirroring the dual read ports the earlier byte_ram_dp gave us.
    //   - mem_read_mux per consumer routes between the shim (snoop mode,
    //     dma_mode_q=0) and dma_master via the arbiter (DMA mode,
    //     dma_mode_q=1). Multi-cycle shim latency propagates back to the
    //     consumer via sh_ready / caller_ready.
    //
    // PHY-side ports come up to antic_top (here) and are wired to the
    // FPGA's HyperRAM I/O pins by the synthesis wrapper. The 200 MHz
    // ram_clk + ram_clk_cal come from the Efinix PLL; in sim they are
    // driven by tb stubs (or left floating — the mock ignores them).
    wire [15:0] dl_raddr,  cmp_raddr;
    wire [7:0]  dl_rdata,  cmp_rdata;
    wire        dl_req,    cmp_req;
    wire        dl_ready,  cmp_ready;

    // shim read-port handshake to mem_read_mux (snoop-side).
    wire [15:0] dl_sh_raddr, cmp_sh_raddr;
    wire        dl_sh_req,   cmp_sh_req;
    wire [7:0]  dl_sh_rdata, cmp_sh_rdata;
    wire        dl_sh_ready, cmp_sh_ready;

    // bram_shim replaces the Efinix-era u_cpu_shadow (hyperram_shim).
    // SALLY writes propagate to sally_mem's BRAM directly via its
    // normal bus interface; ANTIC reads the same BRAM through its
    // second port (sally_mem.dma_addr/dma_rdata at clk_bus).  No
    // separate shadow memory is needed, and the long HyperRAM PHY
    // port plumbing falls away.
    bram_shim #(.ADDR_W(16)) u_bram_shim (
        .clk           (clk_bus),
        .rst           (rst_bus),
        .bram_addr     (bram_addr),
        .bram_rdata    (bram_rdata),
        .req_a         (dl_sh_req),
        .raddr_a       (dl_sh_raddr),
        .rdata_a       (dl_sh_rdata),
        .ready_a       (dl_sh_ready),
        .req_b         (cmp_sh_req),
        .raddr_b       (cmp_sh_raddr),
        .rdata_b       (cmp_sh_rdata),
        .ready_b       (cmp_sh_ready)
    );

    // ---- dma_mode latch (vsync-aligned, snapped at dl_start_pulse) -----
    // dl_start_pulse fires once per "frame" (the kick_counter wraps).
    // Snapshotting mode_snoop_q at that boundary keeps the dma_mode
    // stable for the duration of a parse + compose cycle. (Forward
    // declaration; dl_start_pulse is driven by the kick FSM below.)
    logic dl_start_pulse;
    logic cmp_start_pulse;
    logic dma_mode_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus)
            dma_mode_q <= 1'b0;             // boot in snoop (BRAM) mode
        else if (dl_start_pulse)
            dma_mode_q <= ~mode_snoop_q;    // $D481[0]=0 means DMA
    end

    // ---- dma_master + arbiter ------------------------------------------
    wire        dl_dma_req,   cmp_dma_req;
    wire [15:0] dl_dma_addr,  cmp_dma_addr;
    wire        dl_dma_ack,   cmp_dma_ack;
    wire        dl_dma_dvalid, cmp_dma_dvalid;
    wire [7:0]  dl_dma_rdata, cmp_dma_rdata;
    wire        dma_busy_w;

    wire        arb_dma_req;
    wire [15:0] arb_dma_addr;
    wire        arb_dma_ack;
    wire        arb_dma_dvalid;
    wire [7:0]  arb_dma_rdata;

    dma_arbiter u_dma_arb (
        .clk(clk_bus), .rst(rst_bus),
        .p0_req(dl_dma_req),   .p0_addr(dl_dma_addr),
        .p0_ack(dl_dma_ack),   .p0_data_valid(dl_dma_dvalid),
        .p0_rdata(dl_dma_rdata),
        .p1_req(cmp_dma_req),  .p1_addr(cmp_dma_addr),
        .p1_ack(cmp_dma_ack),  .p1_data_valid(cmp_dma_dvalid),
        .p1_rdata(cmp_dma_rdata),
        .dma_req(arb_dma_req), .dma_addr(arb_dma_addr),
        .dma_ack(arb_dma_ack), .dma_data_valid(arb_dma_dvalid),
        .dma_rdata(arb_dma_rdata), .dma_busy(dma_busy_w));

    dma_master u_dma_master (
        .clk(clk_bus), .rst(rst_bus), .phi2(phi2),
        .req(arb_dma_req), .req_addr(arb_dma_addr),
        .ack(arb_dma_ack), .data_valid(arb_dma_dvalid),
        .req_data(arb_dma_rdata), .busy(dma_busy_w),
        .halt_n(halt_n), .addr_o(dma_addr_o),
        .rw_o(dma_rw_o), .bus_oe(dma_oe),
        .data_i(bus_data_in));

    // ---- mem_read_mux per consumer -------------------------------------
    mem_read_mux #(.ADDR_W(16)) u_mux_dl (
        .clk(clk_bus), .rst(rst_bus), .dma_mode(dma_mode_q),
        .caller_raddr(dl_raddr), .caller_req(dl_req),
        .caller_rdata(dl_rdata), .caller_ready(dl_ready),
        .sh_raddr(dl_sh_raddr), .sh_req(dl_sh_req),
        .sh_rdata(dl_sh_rdata), .sh_ready(dl_sh_ready),
        .dma_req(dl_dma_req), .dma_addr(dl_dma_addr),
        .dma_ack(dl_dma_ack), .dma_data_valid(dl_dma_dvalid),
        .dma_rdata(dl_dma_rdata), .dma_busy(dma_busy_w));

    mem_read_mux #(.ADDR_W(16)) u_mux_cmp (
        .clk(clk_bus), .rst(rst_bus), .dma_mode(dma_mode_q),
        .caller_raddr(cmp_raddr), .caller_req(cmp_req),
        .caller_rdata(cmp_rdata), .caller_ready(cmp_ready),
        .sh_raddr(cmp_sh_raddr), .sh_req(cmp_sh_req),
        .sh_rdata(cmp_sh_rdata), .sh_ready(cmp_sh_ready),
        .dma_req(cmp_dma_req), .dma_addr(cmp_dma_addr),
        .dma_ack(cmp_dma_ack), .dma_data_valid(cmp_dma_dvalid),
        .dma_rdata(cmp_dma_rdata), .dma_busy(dma_busy_w));

    // ---- dl_parser ------------------------------------------------------
    // Tied to a periodic kick for now (every 256K cycles ≈ ~12 ms at
    // 21.5 MHz, faster than VBI but acceptable for synth). Real start-of-
    // VBI scheduling is a downstream M-int task tied to vbeam.
    logic [17:0] kick_counter;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) begin
            kick_counter    <= 18'h0;
            dl_start_pulse  <= 1'b0;
            cmp_start_pulse <= 1'b0;
        end else begin
            kick_counter    <= kick_counter + 18'd1;
            dl_start_pulse  <= (kick_counter == 18'h0);
            cmp_start_pulse <= (kick_counter == 18'h00400);  // 1024 cycles after parse start
        end
    end

    wire [7:0]  meta_row_q;
    wire [3:0]  dl_meta_mode;
    wire        dl_meta_dli;
    wire [15:0] dl_meta_lms;
    wire [3:0]  dl_meta_sub;
    wire        dl_meta_hscrol_en;
    wire        dl_meta_vscrol_en;
    wire        dl_done;
    wire [31:0] dl_count;

    dl_parser u_dl_parser (
        .clk(clk_bus), .rst(rst_bus), .start_parse(dl_start_pulse),
        .dlistl(dlistl_q), .dlisth(dlisth_q),
        .vscrol(vscrol_q[3:0]),
        .mem_raddr(dl_raddr), .mem_rdata(dl_rdata),
        .mem_req(dl_req), .mem_ready(dl_ready),
        .meta_row(meta_row_q),
        .meta_mode(dl_meta_mode), .meta_dli(dl_meta_dli),
        .meta_lms_addr(dl_meta_lms), .meta_sub_row(dl_meta_sub),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .dli_row(nmi_cur_row),
        .dli_at(nmi_cur_row_dli),
        .parse_done(dl_done), .parse_count(dl_count)
    );

    // ---- NMI generator (M12) -----------------------------------------
    // Instantiated in clk_bus. Vbeam-domain pulses (vbi_start, line_start)
    // arrive via the 2-FF synchronisers above. cur_row from nmi_gen
    // closes the DLI loop with dl_parser via combinational dli_at.
    nmi_gen u_nmi_gen (
        .clk           (clk_bus),
        .rst           (rst_bus),
        .nmien         (nmien_q),
        .nmires_strobe (nmires_strobe),
        .vbi_start     (vbi_start_pulse_bus),
        .line_start    (line_start_pulse_bus),
        .cur_row       (nmi_cur_row),
        .cur_row_dli   (nmi_cur_row_dli),
        .atari_row_in  (ar_atari_row),
        .nmist_q       (nmist_q),
        .nmi_n         (nmi_n_w)
    );

    // ---- WSYNC handler: release at bus cycle 105 of the line ---------
    // ANTIC's real /RDY release point is bus cycle 105 of the current scan
    // line (start of horizontal blank).  The phi2-cycle-within-line count now
    // comes from antic_raster (ar_phi2_in_line, 0..113) — which is what makes
    // this correct: the old local counter was reset by the 140 kHz vbeam
    // line_start (~12 phi2 cycles), so it never reached 105 and WSYNC never
    // released.  phi2-paced line_start fixes it.
    wire cycle_105_pulse = phi2_tick && (ar_phi2_in_line == 8'd105);

    wire        wsync_rdy_w;             // 1 = ready, 0 = stalled
    wsync_gen u_wsync_gen (
        .clk                (clk_bus),
        .rst                (rst_bus),
        .wsync_pending      (wsync_pending),
        .line_start         (cycle_105_pulse),     // release on cycle-105, not next-line
        .rdy_n              (wsync_rdy_w),
        .wsync_overdue_count(wsync_overdue_count_q)
    );

    // ---- Compositor -----------------------------------------------------
    wire [1:0]  cmp_cmd_tag;
    wire [23:0] cmp_cmd_addr;
    wire [23:0] cmp_cmd_data;
    wire        cmp_cmd_valid;
    // Zynq build: rp_tx removed.  Back-pressure from the downstream RP
    // queue would surface here on the Efinix build — tied to always-ready
    // until the M17-3 RP handler lands.
    wire        cmp_cmd_ready = 1'b1;
    wire        cmp_done;
    wire [31:0] cmp_count;

    compositor u_compositor (
        .clk(clk_bus), .rst(rst_bus), .start_compose(cmp_start_pulse),
        .meta_row(meta_row_q),
        .meta_mode(dl_meta_mode), .meta_lms_addr(dl_meta_lms),
        .meta_sub_row(dl_meta_sub),
        .meta_hscrol_en(dl_meta_hscrol_en),
        .meta_vscrol_en(dl_meta_vscrol_en),
        .chbase(chbase_q), .chactl(chactl_q),
        .pmbase(pmbase_q), .dmactl(dmactl_q), .gractl(gractl_q),
        .hposp0(hposp_q[0]), .hposp1(hposp_q[1]),
        .hposp2(hposp_q[2]), .hposp3(hposp_q[3]),
        .hposm0(hposm_q[0]), .hposm1(hposm_q[1]),
        .hposm2(hposm_q[2]), .hposm3(hposm_q[3]),
        .sizep0(sizep_q[0][1:0]), .sizep1(sizep_q[1][1:0]),
        .sizep2(sizep_q[2][1:0]), .sizep3(sizep_q[3][1:0]),
        .sizem(sizem_q), .vdelay(vdelay_q),
        .hscrol(hscrol_q[3:0]), .vscrol(vscrol_q[3:0]),
        .prior(prior_q),
        .mpf_q(cmp_mpf_q), .ppf_q(cmp_ppf_q),
        .mpl_q(cmp_mpl_q), .ppl_q(cmp_ppl_q),
        .hitclr(hitclr_strobe),
        .mem_raddr(cmp_raddr), .mem_rdata(cmp_rdata),
        .mem_req(cmp_req), .mem_ready(cmp_ready),
        .cmd_tag(cmp_cmd_tag), .cmd_addr(cmp_cmd_addr),
        .cmd_data(cmp_cmd_data), .cmd_valid(cmp_cmd_valid),
        .cmd_ready(cmp_cmd_ready),
        .compose_done(cmp_done), .compose_count(cmp_count)
    );

    // ---- DRAW chiplet-ext register port (M17-2) ------------------------
    // Software stages opcode + 5 16-bit args at $D488-$D492, strobes
    // DRAW_GO at $D493. draw_regs handles the latching + pending flag
    // Zynq build: rp_tx removed.
    // back-pressure from the RP queue is tied off until the RP-side
    // handler lands at M17-3 (will surface as a top-level input).
    wire [7:0]  draw_read_data;
    wire        draw_cmd_valid_w;
    // Same RP-queue back-pressure story as cmp_cmd_ready above — tied to
    // always-ready until the M17-3 handler is wired in.
    wire        draw_cmd_ready_w = 1'b1;
    wire [7:0]  draw_op_w;
    wire [15:0] draw_arg0_w, draw_arg1_w, draw_arg2_w, draw_arg3_w;
    wire [15:0] draw_arg4_w, draw_arg5_w, draw_arg6_w;
    wire [15:0] draw_arg7_w, draw_arg8_w;

    draw_regs u_draw_regs (
        .clk            (clk_bus),
        .rst            (rst_bus),
        .we             (snoop_we_antic),
        .waddr          (snoop_addr[7:0]),
        .wdata          (snoop_data),
        .raddr                (read_addr_w[7:0]),
        .rdata          (draw_read_data),
        .draw_cmd_valid (draw_cmd_valid_w),
        .draw_cmd_ready (draw_cmd_ready_w),
        .draw_op        (draw_op_w),
        .draw_arg0      (draw_arg0_w),
        .draw_arg1      (draw_arg1_w),
        .draw_arg2      (draw_arg2_w),
        .draw_arg3      (draw_arg3_w),
        .draw_arg4      (draw_arg4_w),
        .draw_arg5      (draw_arg5_w),
        .draw_arg6      (draw_arg6_w),
        .draw_arg7      (draw_arg7_w),
        .draw_arg8      (draw_arg8_w)
    );


    // Zynq build: cache_regs + shadow SALLY stack removed.

    // ---- M25-1 — PIA shadow at $D300-$D37F -----------------------------
    // Owns PORTA / PORTB / PACTL / PBCTL. PORTB writes feed the
    // 130XE banking translator below (replaces the standalone portb_q
    // latch that previously lived here); PORTA / PORTB reads return
    // joystick pin state when the matching control register is in
    // port mode (PACTL[2] / PBCTL[2] = 1). The fire buttons enter
    // GTIA at TRIG0-3 above — keeping pia_regs strictly directional
    // (PORTA + PORTB are direction inputs only). pia_read_data is
    // forward-declared up at the sally_hwreg_dout mux.
    //
    // M25-2c: joy_porta_in / joy_portb_in / joy_fire / joy_*_out /
    // joy_*_oe all stay internal — peri_bridge below shadows them
    // over SPI to/from the peripheral RP2354B.
    // portb_q is now an output port (declared above), no internal wire needed.
    wire [7:0] w_joy_porta_in,  w_joy_portb_in;
    wire [7:0] w_joy_porta_out, w_joy_porta_oe;
    wire [7:0] w_joy_portb_out, w_joy_portb_oe;
    wire [7:0] pia_read_data;   // $D3xx PIA read data (PORTA/PORTB/PACTL/PBCTL)
    // w_joy_fire forward-declared near the GTIA collision generate.

    pia_regs u_pia_regs (
        .clk           (clk_bus),
        .rst           (rst_bus),
        .we            (snoop_we_pia),
        .waddr         (snoop_addr),
        .wdata         (snoop_data),
        .raddr         (read_addr_w),
        .rdata         (pia_read_data),   // boot blocker #3: feed PIA reads to the bus mux
        .joy_porta_in  (w_joy_porta_in),
        .joy_portb_in  (w_joy_portb_in),
        .joy_porta_out (w_joy_porta_out),
        .joy_porta_oe  (w_joy_porta_oe),
        .joy_portb_out (w_joy_portb_out),
        .joy_portb_oe  (w_joy_portb_oe),
        .portb_out_q   (portb_q)
    );

    // ---- M25-2c-rev — joy_bridge (PCAL9722 path) -----------------------
    // Sits between pia_regs / GTIA and the PCAL9722 SPI link. Owns
    // all four 8-bit joy_*_out / _oe write-through state and the
    // polled Input port 0/1/2 shadow that feeds joy_*_in / joy_fire.
    joy_bridge u_joy_bridge (
        .clk           (clk_bus),
        .rst           (rst_bus),
        .joy_porta_out (w_joy_porta_out),
        .joy_porta_oe  (w_joy_porta_oe),
        .joy_portb_out (w_joy_portb_out),
        .joy_portb_oe  (w_joy_portb_oe),
        .joy_porta_in  (w_joy_porta_in),
        .joy_portb_in  (w_joy_portb_in),
        .joy_fire      (w_joy_fire),
        .spi_clk       (joy_spi_clk),
        .spi_mosi      (joy_spi_mosi),
        .spi_miso      (joy_spi_miso),
        .spi_cs_n      (joy_spi_cs_n),
        .spi_int_n     (joy_spi_int_n)
    );

    // ---- M25-3c/M25-4 — peri_bridge (POT + SIO via peri_link) ----------
    // Unified bridge: POT (POTGO writes, STATUS/ALLPOT/POT0..7 read
    // chain) + SIO (SIO_OUT writes, SIO_IN/SIO_STAT read chain on
    // sio_rx flag). Owns the peri-RP SPI link pads. SD bridging
    // (M25-5) lands as additional registers and a third read chain.
    peri_bridge u_peri_bridge (
        .clk                 (clk_bus),
        .rst                 (rst_bus),
        .potgo_pulse         (pot_bridge_potgo_pulse),
        .fast_scan           (pot_bridge_fast_scan),
        .pot0                (pot_shadow_0),
        .pot1                (pot_shadow_1),
        .pot2                (pot_shadow_2),
        .pot3                (pot_shadow_3),
        .pot4                (pot_shadow_4),
        .pot5                (pot_shadow_5),
        .pot6                (pot_shadow_6),
        .pot7                (pot_shadow_7),
        .allpot              (pot_shadow_allpot),
        .serout_byte         (pokey_l_serout_byte),
        .serout_strobe       (pokey_l_serout_strobe),
        .ser_in_byte         (sio_bridge_in_byte),
        .ser_in_byte_pulse   (sio_bridge_in_byte_pulse),
        .ser_framing_err     (sio_bridge_framing_err),
        .ser_input_overrun   (sio_bridge_input_overrun),
        .ser_input_busy      (sio_bridge_input_busy),
        .break_key_pulse     (sio_bridge_break_key_pulse),
        .ser_out_ready_pulse (sio_bridge_out_ready_pulse),
        .ser_out_complete    (sio_bridge_out_complete),
        .spi_clk             (spi_clk),
        .spi_mosi            (spi_mosi),
        .spi_miso            (spi_miso),
        .spi_cs_n            (spi_cs_n),
        .spi_irq             (spi_irq)
    );



    // ---- Color resolvers (M-video-int) -------------------------------
    // Two color_resolver instances — one per pixel in the cmd_data pair
    // — convert the compositor's 12-bit idx_buf (M10c: 4-bit M-only
    // nibble + 8-bit GTIA palette index) into an 8-bit Atari hue:luma
    // value. The two 8-bit results pack into the line-buffer write
    // word.
    wire [7:0] resolved_color_lo, resolved_color_hi;

    color_resolver u_color_lo (
        .idx_buf  (cmp_cmd_data[11:0]),
        .prior    (prior_q),
        .colpm0   (colpm_q[0]), .colpm1(colpm_q[1]),
        .colpm2   (colpm_q[2]), .colpm3(colpm_q[3]),
        .colpf0   (colpf_q[0]), .colpf1(colpf_q[1]),
        .colpf2   (colpf_q[2]), .colpf3(colpf_q[3]),
        .colbk    (colbk_q),
        .color_out(resolved_color_lo)
    );
    color_resolver u_color_hi (
        .idx_buf  (cmp_cmd_data[23:12]),
        .prior    (prior_q),
        .colpm0   (colpm_q[0]), .colpm1(colpm_q[1]),
        .colpm2   (colpm_q[2]), .colpm3(colpm_q[3]),
        .colpf0   (colpf_q[0]), .colpf1(colpf_q[1]),
        .colpf2   (colpf_q[2]), .colpf3(colpf_q[3]),
        .colbk    (colbk_q),
        .color_out(resolved_color_hi)
    );

    // ---- Bus read response ----------------------------------------------
    // /D0xx + R/W=1 → drive D with gtia_read_data.
    // /D4xx + R/W=1 → drive D with antic_read_data.
    // Else tristate. Output enable goes high for the cycle the read is
    // active. The wrapper instantiates the tristate IO buffer at the pad.
    wire d0xx_read = (~d0xx_n) & bus_rw;
    wire d4xx_read = (~d4xx_n) & bus_rw;
    // POKEY at $D2xx has no dedicated page-select pin; bus_snoop
    // decodes the address internally. The 130XE-style stereo split
    // is by addr[4]: even mirrors → left chip, odd mirrors → right
    // chip. Re-derive live so bus_data_out drives the same cycle the
    // read fires.
    wire d2xx_read   = (bus_addr[15:8] == 8'hD2) & bus_rw;
    wire d2xx_read_l = d2xx_read & ~bus_addr[4];
    wire d2xx_read_r = d2xx_read &  bus_addr[4];
    // PIA at $D3xx (boot blocker #3): PORTA/PORTB/PACTL/PBCTL reads.
    // No dedicated page-select pin; decode straight off the address.
    wire d3xx_read   = (bus_addr[15:8] == 8'hD3) & bus_rw;

    wire [7:0] bus_data_out_w = d0xx_read   ? gtia_read_data
                              : d4xx_read   ? (antic_read_data | draw_read_data )
                              : d2xx_read_l ? pokey_l_read_data
                              : d2xx_read_r ? pokey_r_read_data
                              : d3xx_read   ? pia_read_data
                              : 8'h00;
    wire       bus_data_oe_w  = d0xx_read | d4xx_read | d2xx_read | d3xx_read;

    // ---- M-PBI: external-bus gating + output flops ---------------------
    // ext_bus_active controls whether the external 6502 bus + cart/PBI/ECI
    // outputs are allowed to change. In production (cpu_internal_q=1) the
    // bus is active only at CLOCK_MULT=1 (1.79 MHz phi2). In testbench mode
    // (cpu_internal_q=0) the bus is always active so existing test
    // stimulus still observes register-read responses on bus_data_out/oe.
    //
    // When ext_bus_active=0 each output flop holds D=Q, so the FPGA pads
    // stay static at fast mode — no SSO event, no EMI radiation off the
    // FPGA package and the short FPGA-to-LVC8T245 board traces, no
    // dynamic-power burn. LVC8T245 OE-disable is secondary safety
    // handled at the synth wrapper.
    //
    // Active when in testbench mode (cpu_internal_q=0) OR when running
    // at base clock_mult (1× → phi2 = 1.79 MHz, the legitimate Atari
    // bus rate).  Holds the pads frozen otherwise.
    wire ext_bus_active = !cpu_internal_q || (clock_mult_q == 8'd1);

    // Address-decoded outbound control signals, combinational (registered
    // below for the pad drive).
    wire d1xx_decode_n = ~(snoop_bus_addr_w[15:8] == 8'hD1);
    wire s4_decode_n   = ~(snoop_bus_addr_w[15:13] == 3'b100);  // $8000-$9FFF
    wire s5_decode_n   = ~(snoop_bus_addr_w[15:13] == 3'b101);  // $A000-$BFFF
    wire cctl_decode_n = ~(snoop_bus_addr_w[15:8] == 8'hD5);

    // Output flops with D=Q hold when ext_bus_active=0. Reset values are
    // "inactive" (all active-low controls high, addr/data parked).
    logic [15:0] bus_addr_o_q;
    logic        bus_rw_o_q;
    logic        bus_d0xx_n_q, bus_d4xx_n_q, bus_d1xx_n_q;
    logic        bus_s4_n_q, bus_s5_n_q, bus_cctl_n_q;
    logic        bus_extenb_n_q;

    always_ff @(posedge clk_bus) begin
        if (rst_bus) begin
            bus_addr_o_q   <= 16'hFFFF;
            bus_rw_o_q     <= 1'b1;
            bus_d0xx_n_q   <= 1'b1;
            bus_d4xx_n_q   <= 1'b1;
            bus_d1xx_n_q   <= 1'b1;
            bus_s4_n_q     <= 1'b1;
            bus_s5_n_q     <= 1'b1;
            bus_cctl_n_q   <= 1'b1;
            bus_extenb_n_q <= 1'b1;
        end else if (ext_bus_active) begin
            bus_addr_o_q   <= snoop_bus_addr_w;
            bus_rw_o_q     <= snoop_bus_rw_w;
            bus_d0xx_n_q   <= ~(snoop_bus_addr_w[15:8] == 8'hD0);
            bus_d4xx_n_q   <= ~(snoop_bus_addr_w[15:8] == 8'hD4);
            bus_d1xx_n_q   <= d1xx_decode_n;
            bus_s4_n_q     <= s4_decode_n;
            bus_s5_n_q     <= s5_decode_n;
            bus_cctl_n_q   <= cctl_decode_n;
            bus_extenb_n_q <= 1'b0;          // PBI bank decode enabled while bus is live
        end
        // else: hold — D=Q feedback keeps the pad static at fast mode.
    end

    assign bus_addr_o     = bus_addr_o_q;
    assign bus_rw_o       = bus_rw_o_q;
    assign bus_d0xx_n_o   = bus_d0xx_n_q;
    assign bus_d4xx_n_o   = bus_d4xx_n_q;
    assign bus_d1xx_n_o   = bus_d1xx_n_q;
    assign bus_s4_n_o     = bus_s4_n_q;
    assign bus_s5_n_o     = bus_s5_n_q;
    assign bus_cctl_n_o   = bus_cctl_n_q;
    assign bus_extenb_n_o = bus_extenb_n_q;

    // phi2_o: synthetic phi2 clock to cart/PBI/ECI slaves. Gated to
    // CLOCK_MULT=1 production cycles — at fast mode (or in testbench
    // mode with no production gating active), holds low so the pad
    // doesn't toggle when no external slave is listening. Combinational
    // gate (not registered) keeps the rising/falling edges aligned with
    // the internal phi2 — cart/PBI slaves expect a real Atari-rate
    // clock for their address-decode timing.
    assign phi2_o = ext_bus_active ? phi2 : 1'b0;

    // bus_data_out / bus_data_oe stay combinationally driven (existing
    // testbenches check them on the same cycle as the read fires).
    // M-PBI step 3 adds a third drive case: in production mode
    // (cpu_internal_q=1) at CLOCK_MULT=1, the FPGA drives D[7:0] for
    // every SALLY *write* cycle so PBI / cart / ECI slaves can latch
    // the data. Testbench mode (cpu_internal_q=0) leaves writes
    // un-driven (matches the pre-step-3 behaviour that tb_read /
    // tb_snoop rely on; ext_bus_active=1 in test mode but
    // prod_write_drive is gated by cpu_internal_q).
    //
    // At fast mode (cpu_internal_q=1, clock_mult_q != 1) ext_bus_active
    // forces both signals to {0, 8'h00} — the synth wrapper's pad-
    // register flop sees a stable D and doesn't toggle.
    wire prod_write_drive = 1'b0;
    wire [7:0] bus_data_drive_w = prod_write_drive ? snoop_bus_data_w
                                : bus_data_oe_w    ? bus_data_out_w
                                                   : 8'h00;
    wire       bus_data_oe_full_w = bus_data_oe_w | prod_write_drive;
    assign bus_data_oe  = ext_bus_active ? bus_data_oe_full_w : 1'b0;
    assign bus_data_out = ext_bus_active ? bus_data_drive_w   : 8'h00;

    // ---- Status pin defaults --------------------------------------------
    // M-vbeam-feedback: NMI is now driven by nmi_gen for both the
    // internal SALLY (above) and the external bus pin (below).
    // M-wsync-105: RDY is driven by wsync_gen (released at bus cycle
    // 105 of the line, not at next line_start).
    assign nmi_n  = nmi_n_w;
    // halt_n is driven by dma_master (M16-int).
    assign rdy_n  = wsync_rdy_w;       // 1 = ready, 0 = stall (active-high naming, despite the _n suffix)

    // ---- ANTIC render-tap source (video-arch §5) --------------------
    // The 800×600 display chain (compositor → line_buffer → scan_out →
    // palette_lut → hdmi_out → TMDS pads) was deleted in task-0013 step 3.
    // In the compositor model ANTIC is a window *source*: its rendered line
    // is captured by the §5 writeback into a DDR3 XL surface and scanned out
    // by the top-level 1080p compositor, not by a local display.
    //
    // What remains is the clk_bus render-stream generator that feeds the
    // writeback tap (wb_pix_* below): a per-line column-pair counter advanced
    // by each accepted compositor pair and reset by the phi2 raster's
    // line_start_pulse_bus.  (The old clk_pix CDC, line_buffer, scan_out,
    // display palette_lut and hdmi_out are gone — line_start_pulse_bus now
    // comes from antic_raster, not a vbeam.)
    localparam int LB_WIDTH    = 384;                // active playfield (px)
    localparam int LB_WR_AW    = $clog2(LB_WIDTH/2); // 8 (column-pair index)

    // Column-pair counter (clk_bus). Resets at line_start, increments per
    // accepted compositor pair; the held registers source the render tap.
    logic [LB_WR_AW-1:0] lb_wr_pair_bus_q;
    logic [15:0]         lb_wr_data_bus_q;
    logic                lb_wr_strobe_bus_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) begin
            lb_wr_pair_bus_q   <= '0;
            lb_wr_data_bus_q   <= 16'h0000;
            lb_wr_strobe_bus_q <= 1'b0;
        end else begin
            lb_wr_strobe_bus_q <= 1'b0;          // 1-cycle pulse default
            if (line_start_pulse_bus) lb_wr_pair_bus_q <= '0;
            if (cmp_cmd_valid && cmp_cmd_ready
                && lb_wr_pair_bus_q != LB_WR_AW'(LB_WIDTH/2 - 1)) begin
                lb_wr_data_bus_q   <= {resolved_color_hi, resolved_color_lo};
                lb_wr_strobe_bus_q <= 1'b1;
                lb_wr_pair_bus_q   <= lb_wr_pair_bus_q + 1'b1;
            end
        end
    end

    // (No clk_pix CDC / line_buffer / scan_out / display palette_lut /
    // hdmi_out / RGB565 output here any more — task-0013 step 3 deleted the
    // 800×600 display chain.  lb_wr_pair_bus_q / lb_wr_data_bus_q /
    // lb_wr_strobe_bus_q above are surfaced directly to the §5 writeback tap
    // at the bottom of this module.)

    // ============================================================
    // N6 PERIPHERAL INTERFACE — Zynq build stubs
    // ============================================================
    // n6_pssi_*, n6_fmc_* removed — no N6 co-processor on Zynq.
    // SPI / LTDC / IRQ ports remain with defaults for future use.

    assign n6_spi_clk       = 1'b0;
    assign n6_spi_mosi      = 1'b0;
    assign n6_spi_cs_n      = 1'b1;   // /CS de-asserted

    assign n6_irq_to_n6_hp  = 1'b0;
    assign n6_irq_to_n6_lp  = 1'b0;

    // ---- ANTIC render tap → compositor writeback (video-arch §5) -------
    // Surface the clk_bus render stream / palette / frame pulses for the
    // top-level antic_writeback master.  lb_wr_pair_bus_q / _data_bus_q /
    // _strobe_bus_q advance one column-pair per accepted compositor pair;
    // atari_row / line_start / vbi_start come from the phi2 raster timer
    // (antic_raster) — see line_start_pulse_bus / vbi_start_pulse_bus above.
    assign wb_pix_valid = lb_wr_strobe_bus_q;
    assign wb_pix_pair  = lb_wr_pair_bus_q;
    assign wb_color_lo  = lb_wr_data_bus_q[7:0];
    assign wb_color_hi  = lb_wr_data_bus_q[15:8];
    assign wb_atari_row = ar_atari_row;
    assign wb_row_flush = line_start_pulse_bus;
    assign wb_frame_done = vbi_start_pulse_bus;
    assign wb_pal_we    = pal_write_strobe;
    assign wb_pal_idx   = pal_idx_q;
    assign wb_pal_rgb   = {pal_r_q, pal_g_q, pal_b_q};

    // Keep unconnected N6 inputs alive in synth (prevents "unused
    // port" pruning during Phase 0). The reduction-OR is purely a
    // sentinel — Phases 1–4 replace it with real consumers.
    /* verilator lint_off UNUSED */
    wire _n6_inputs_alive = |{
        n6_spi_miso,
        n6_ltdc_r, n6_ltdc_g, n6_ltdc_b,
        n6_ltdc_hsync, n6_ltdc_vsync, n6_ltdc_de, n6_ltdc_pixclk,
        n6_irq_to_fpga_hp, n6_irq_to_fpga_lp
    };
    /* verilator lint_on UNUSED */

endmodule

`default_nettype wire
