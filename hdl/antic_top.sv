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
    // any clk_bus rate. antic_top is clocked from clk_sys, so the top
    // level (fpga_xt_top) overrides this to clk_sys's 150 MHz; the
    // default here matches that. The parameter feeds POKEY's reference
    // dividers (64 kHz / 15.7 kHz audio refs and the 64 kHz POT scan)
    // and the I2S sample-rate phase increment; every consumer
    // re-derives at synth time so the audio/SIO physical rates stay
    // correct as clk_bus scales.
    parameter int unsigned POKEY_CLK_BUS_HZ = 150_000_000,    // clk_sys (clk_bus) nominal
    // HDMI audio sample rate (POKEY → packetiser).
    parameter int unsigned AUDIO_SAMPLE_HZ  = 48_000
) (
    // System clock + reset
    input  wire        clk_bus,         // phi2 × CLOCK_MULT — see register $D480
    // ANTIC is paced by the phi2 raster (antic_raster); it is a window
    // *source*, not a display.
    input  wire        rst_n,           // /G_RST, active-low (sync'd internally)
    input  wire        sally_cold,      // SALLYRST cold-boot level -> power-on-clear NMIEN/DMACTL

    // ---- Keypad->joystick override (clk_bus = clk_sys; from xt_gp0_regs) ----
    // When [31]=1, [7:0] replaces the joy_bridge PORTA pin shadow feeding
    // pia_regs (STICK0 bits[3:0], STICK1 bits[7:4], active-low) and [8] replaces
    // the TRIG0 fire pin (active-low). Lets the Mac keypad drive STICK0 with no
    // physical PCAL9722 joystick present. [31]=0 = joy_bridge drives as normal.
    input  wire [31:0] joy_ovr,
    input  wire [7:0]  consol_keys,   // CONSOL ($D01F) value the 6502 reads (active-low console keys; kernel holds OPTION to keep BASIC off)

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
    // Ungated combinational register read mux for the INTERNAL CPU read-back
    // path (hwreg_rd_cdc).  bus_data_out above is gated by ext_bus_active for
    // the external-bus pads (EMI), which starves the internal CPU's register
    // reads at turbo (cpu_internal_q=1, clock_mult!=1) — they would all read
    // $00.  The internal read path must tap this ungated value instead.
    output wire [7:0]  bus_rdata_int,

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

    // ANTIC's raw phi2 level (clk_bus domain) — the single timing master. The
    // fidelity 6502 core syncs THIS into clk_sally and edge-detects it to pace
    // its machine cycles, so the fid CPU's cycle grid is identical to ANTIC's
    // (no second free-running divider to drift against). See fpga_xt_top.sv.
    output wire        phi2_level_o,

    // ANTIC-driven status (active-low)
    output wire        nmi_n,
    output wire        halt_n,
    output wire        rdy_n,
    output wire        wsync_write_immune,   // 1 = writes ignore WSYNC /RDY (cfg[15]=0)

    // Cycle-exact ANTIC DMA cycle-steal (active-HIGH: 1 = ANTIC takes this
    // machine cycle from the CPU).  Consumed by sally_clock at CLOCK_MULT=1
    // (gated off at turbo) to reproduce real-Atari bus-stealing timing.
    output wire        dma_steal,

    // Optional DMACTL screen-blanking: when 1, honour DMACTL like real silicon —
    // playfield/DL DMA off (DMACTL[1:0]==0 or DMACTL[5]==0) shows COLBK.  From a
    // PS config bit (gp0_ctrl[4]); 0 = ignore DMACTL (legacy: always render).
    input  wire        dmactl_honor,

    // XT register-unlock — the per-group mirror-conditional $D4xx decode lives
    // in antic_regs (register-unlock.md).  antic_top routes all three $D4xx-
    // owning group bits in (registered below) so each slice falls back to the
    // stock ANTIC mirror under ITS OWN lock; unlock_antic also gates draw_regs.
    input  wire        unlock_antic,
    input  wire        unlock_sprite,
    input  wire        unlock_blit,

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

    // ---- Video output: none here ---------------------------------------
    // ANTIC drives no display pads.  The HDMI pads are driven by the
    // top-level compositor → sprite chain; the ANTIC image reaches the
    // screen via the §5 writeback tap (wb_* below) → DDR3 XL surface →
    // compositor.

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
    input  wire        kbd_release,         // all-keys-up strobe -> SKSTAT key-down clear
    input  wire        kbd_break_pulse,     // F12 -> Atari BREAK (OR'd with the SIO break)

    // ---- Peripheral RP link (M25-2 + M25-2c-rev + M25-3c) --------------
    // The peri-RP2354B handles POT / SIO / SD card. peri_pot_bridge
    // (M25-3c) wraps peri_link for POT-scan traffic — the POT pins
    // moved off antic_top entirely and live on the peri-RP's GPIO.
    // SIO + SD bridges land in M25-4 / M25-5 above peri_link.
    output wire        spi_clk,            // SPI MODE 0, ≈5 MHz at 150 MHz clk_bus
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

    // PORTB ($D301) state — needed by sally_mem for ROM vs RAM control.
    output wire [7:0]  portb_q,

    // ---- ANTIC render tap → compositor writeback (video-arch §5, phase 2) --
    // The per-pixel-pair render stream, palette writes and frame/line pulses
    // that drive the ANTIC->DDR3 writeback master (antic_writeback) at the
    // top level.  All clk_bus domain (= clk_sys in this build).  This is
    // ANTIC's ONLY image output path.
    output wire        wb_pix_valid,    // 1-cycle pulse: a pixel-PAIR is ready
    output wire [7:0]  wb_pix_pair,     // pair index within the line (col/2)
    output wire [7:0]  wb_color_lo,     // 8-bit Atari colour code, even column
    output wire [7:0]  wb_color_hi,     //                          odd  column
    output wire [7:0]  wb_atari_row,    // ANTIC row being rendered (0..191)
    output wire        wb_row_flush,    // pulse (line_start): row complete -> DMA
    output wire        wb_frame_done,   // pulse (vbi): flip the double buffer
    output wire        wb_pal_we,       // palette write strobe (clk_bus origin)
    output wire [7:0]  wb_pal_idx,      // palette index
    output wire [23:0] wb_pal_rgb,      // {R,G,B} palette entry
    // ---- TEMP debug: live ANTIC/GTIA register state (clk_sys) for `mem` readback ----
    output wire [31:0] dbg_gtia,        // {colpf0, colpf1, colpf2, colbk}
    output wire [31:0] dbg_antic,       // {colpf3, prior, chbase, dmactl}

    // ---- ANTIC timebase debug probe (DBG_TB_*, GP0 DEBUG block) --------
    // A configurable 16-entry capture ring that records WHERE in the frame
    // (scanline + horizontal machine-cycle) a selected ANTIC event fired,
    // plus its data byte.  cfg is A9-set (clk_sys) and 2-FF synced in here;
    // stat/cap are produced in clk_bus and 2-FF synced on the GP0 side.
    input  wire [28:0] dbg_tb_cfg,      // {[28:26]=wsync_shape,[25]=circular,[24]=clear,[19:16]=read_idx,[11:4]=match_addr,[3]=visible_only,[2:0]=mode}
    output wire [31:0] dbg_tb_stat,     // {[25]=armed,[24]=full,[20:16]=wr_idx,[15:0]=trig_count}
    output wire [24:0] dbg_tb_cap       // ring[read_idx] = {scanline[8:0],phi2[7:0],data[7:0]}
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

    // Synthetic phi2 derived from the bus clock (clk_bus = clk_sys = 133.3 MHz).
    // The counter wraps at BASE_DIV/2-1 and toggles `phi2`, giving
    // phi2 = clk_bus / BASE_DIV = 133.3/74 ≈ 1.80 MHz ≈ real NTSC phi2, so the
    // raster/VBI cadence is ~60 Hz.  BASE_DIV tracks clk_sys as
    // round(clk_sys_MHz / 1.79); keep this phi2 RATE matched to the CPU's
    // sally_clock BASE_DIV (which divides clk_sally, hence a different value).
    // The 1-cycle phi2_tick pulse on each phi2 rising edge is exposed for use by
    // POKEY's high-freq channel mode and fast pot-scan path (no multiplier
    // hardcoded in any POKEY-side logic — phi2_tick is the only contract).
    localparam int unsigned BASE_DIV    = 74;
    localparam int unsigned PHI2_CTR_W  = $clog2(BASE_DIV);
    localparam int unsigned PHI2_HALF   = (BASE_DIV / 2) - 1;       // 36 at BASE_DIV=74

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

    // Dedicated, lightly-loaded launch FF for the fid-core CDC.  The fid 6502
    // (clk_sally) paces its machine cycles off ANTIC's phi2 so the two grids
    // are identical (fpga_xt_top.sv syncs + edge-detects this level).  Driving
    // the CDC from a private replica of `phi2` — not the main phi2 reg — keeps
    // that reg's fanout/timing unburdened.  DONT_TOUCH pins the replica so the
    // synth-side set_max_delay on phi2_cdc_src_reg -> phi2f_s0_reg has a cell.
    (* DONT_TOUCH = "true" *) logic phi2_cdc_src = 1'b0;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) phi2_cdc_src <= 1'b0;
        else         phi2_cdc_src <= phi2;
    end
    assign phi2_level_o = phi2_cdc_src;

    // ---- ANTIC native raster timer (video-arch §5.1) ---------------------
    // phi2-paced raster heartbeat — replaces the 800×600 hdmi_out vbeam as the
    // source of atari_row / line_start / vbi_start / vcount (the display chain
    // is bypassed for output; see §5.1).  Locked to phi2 so VCOUNT/WSYNC/VBI
    // cadence is correct vs the CPU.  All clk_bus — no CDC.
    wire [8:0] ar_scanline;
    // The display-list parse kicks LATE in vblank, not at vbi_start (248):
    // the XL OS copies its DLIST shadows at ~248-250 and tests arm their DL
    // around ~250-252, and a parse that has already run at 248 would show
    // the OLD list for a full frame (real ANTIC fetches the DL live, so a
    // vblank write always affects the very next frame — ACID800 antic_nmist
    // and the whole DLI cluster arm exactly this way).  Line 260 is after
    // every normal vblank write yet still ~10 scanlines (>100 us) before
    // display, orders of magnitude beyond the parse's needs.
    localparam [8:0] PARSE_KICK_LINE = 9'd260;
    wire       ar_line_start, ar_vbi_start;
    wire parse_kick_pulse = ar_line_start && (ar_scanline == PARSE_KICK_LINE);
    logic      scanline_is_vbi_q;      // registered (ar_scanline == PARSE_KICK_LINE); start_parse gate
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) scanline_is_vbi_q <= 1'b0;
        else         scanline_is_vbi_q <= (ar_scanline == PARSE_KICK_LINE);
    end
    wire [7:0] ar_phi2_in_line;
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
    wire       dlistl_we_w, dlisth_we_w;  // DLIST write pulses -> dl_parser live DL PC
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
    // raster timer.
    //
    // Forward declarations for nmi_gen outputs (block further down).
    wire [7:0]  nmist_q;
    wire [7:0]  nmi_cur_row;
    wire        nmi_cur_row_dli;
    wire [7:0]  dbg_dli_rows;      // dl_parser line_dli_p snapshot (temp DLI diag)
    wire [4:0]  dbg_dli_listcnt;   // dl_parser DLI-row list count
    wire        dbg_dli_has23;     // list contains raster row 23
    wire        nmi_n_w;

    wire        vbi_start_pulse_bus  = ar_vbi_start;
    wire        line_start_pulse_bus = ar_line_start;

    // fmax: register unlock_antic at the boundary so the quasi-static unlock bit
    // arrives inside antic_top as a clean local FF — it must NOT sit on a long
    // cross-die combinational route into the timing-critical compositor/GTIA
    // region (that route burned ~70 ps of clk_sys and glitched the SALLY when
    // toggled).  A 1-cycle delay on a register that changes only on an unlock
    // poke is irrelevant.  (* keep *) stops it being merged back into fanout.
    (* keep = "true" *) logic unlock_antic_q, unlock_sprite_q, unlock_blit_q;
    always_ff @(posedge clk_bus) begin
        unlock_antic_q  <= unlock_antic;
        unlock_sprite_q <= unlock_sprite;
        unlock_blit_q   <= unlock_blit;
    end

    // SALLYRST cold-boot, 2-FF synced into clk_bus (source is clk_sys = clk_bus, but
    // keep the sync so it is domain-safe if clk_bus is ever a derived clock).
    (* ASYNC_REG = "TRUE" *) reg [1:0] sally_cold_sync = 2'b00;
    always_ff @(posedge clk_bus) sally_cold_sync <= {sally_cold_sync[0], sally_cold};
    wire cold_boot_bus = sally_cold_sync[1];

    antic_regs u_antic_regs (
        .clk                  (clk_bus),
        .rst                  (rst_bus),
        .cold_boot            (cold_boot_bus),
        .we                   (snoop_we_antic),
        .waddr                (snoop_addr[7:0]),
        .wdata                (snoop_data),
        .raddr                (read_addr_w[7:0]),
        .rdata                (antic_read_data),
        .wsync_pending        (wsync_pending),
        .nmires_strobe        (nmires_strobe),
        .dlistl_we            (dlistl_we_w),
        .dlisth_we            (dlisth_we_w),
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
        .bus_extirq_n_in  (bus_extirq_n_q),
        .unlock_antic     (unlock_antic_q),
        .unlock_sprite    (unlock_sprite_q),
        .unlock_blit      (unlock_blit_q)
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
    // TEMP diag: colours (colpf0/colpf1/colpf2/colbk) for `mem` readback. dbg_antic (DLI
    // counter + NMIEN/NMIST/mode) is assigned lower down, after dl_meta_mode is declared.
    assign dbg_gtia  = {colpf_q[0], colpf_q[1], colpf_q[2], colbk_q};
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
    // Keypad->joystick override MUX (joy_ovr[31]): when enabled, TRIG0 fire is
    // forced from joy_ovr[8] (active-low), TRIG1 forced released (1). When
    // disabled, the raw joy_bridge/PCAL9722 shadow drives TRIG0/TRIG1.
    // Combinational mux — both sources are clk_bus, no CDC.
    //
    // TRIG2/TRIG3 (bits 3:2) are HARD-TIED released (1) in BOTH paths: the 800XL
    // has no joystick ports 3/4, and — critically — GTIA TRIG3 ($D013) is what the
    // XL OS reads as the $A000 cartridge-present line for its cartridge interlock
    // (VBI: LDA $D013 / CMP GINTLK $03FA / BNE $C0DF-lockup). Sourcing TRIG3 from
    // the glitchy joy_bridge shadow (or letting the override flip it) drifts it off
    // the value GINTLK latched at coldstart, tripping the OS's anti-cart-swap lockup
    // (Despatch Rider ~20s hang / crash-on-input). A stable TRIG3 keeps the interlock
    // satisfied for all disk-booted (cartridge-less) titles.
    // No-override idle = 4'b1111 (all triggers RELEASED). w_joy_fire (joy_bridge/
    // PCAL9722) is tied-off = $00 = "all fire pressed" every frame, so the game
    // auto-fires garbage; re-source from w_joy_fire[1:0] when the companion MCU
    // drives the expander. TRIG3/2 stay 1 (no j3/j4 ports; TRIG3 = the $A000
    // cartridge-interlock line the XL OS checks — see the GINTLK $C0DF lockup).
    wire [3:0]  pia_joy_fire = joy_ovr[31] ? {2'b11, 1'b1, joy_ovr[8]}
                                           : 4'b1111;
    genvar i;
    generate
        for (i = 0; i < 4; i++) begin : g_collision
            assign m_pf_in[i] = {4'h0, cmp_mpf_q[4*i +: 4]};
            assign p_pf_in[i] = {4'h0, cmp_ppf_q[4*i +: 4]};
            assign m_pl_in[i] = {4'h0, cmp_mpl_q[4*i +: 4]};
            assign p_pl_in[i] = {4'h0, cmp_ppl_q[4*i +: 4]};
            // M25-1: TRIG0..TRIG3 sourced from pia_joy_fire[i] (active-low
            // shadow → active-high "pressed" semantics matching GTIA's trig_in
            // (bit 0 = 1 when pressed). The gtia_regs read flips bit 0 to match
            // Atari's "0 = button pressed" register convention.
            assign trig_high[i] = {7'h00, pia_joy_fire[i]};
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
        // $D014 PAL/NTSC sense. NTSC GTIA reads $0F, PAL reads $01 — this was
        // $02, which is neither, so every standard-detect took the PAL branch
        // despite our 262-line NTSC frame. Found via ACID800 antic_vcount, which
        // hung forever in `cpx:rne vcount` waiting for VCOUNT==155 (the PAL
        // rollover) on a frame whose leading VCOUNT tops out at 131.
        .pal_sense_in   (8'h0F),         // NTSC
        .consol_r_in    (consol_keys),   // console keys from GP0 CTRL_CONSOL (kernel holds OPTION $03 for games -> BASIC off)
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
        .cold_boot            (cold_boot_bus),
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
        .kbd_release          (kbd_release),
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
        .break_key_pulse      (sio_bridge_break_key_pulse | kbd_break_pulse),
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
        .cold_boot            (cold_boot_bus),
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
        .kbd_release          (1'b0),
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

    // ---- CPU RAM access (BRAM via bram_shim) ----------------------------
    // System RAM lives in sally_mem's BRAM; ANTIC reads it through a
    // bram_shim on sally_mem's second port (clk_bus), so SALLY writes are
    // visible to ANTIC without a separate shadow memory:
    //   - bus_snoop drives the write port (snoop_we_screen / snoop_addr /
    //     snoop_data); the shim's wready is currently unobserved (1-deep
    //     write FIFO; bus_snoop fires ≤ 1× per ~12 fabric cycles, well
    //     below the shim's drain rate, so saturation is not expected).
    //   - dl_parser reads via shim port A; compositor via port B.
    //   - mem_read_mux per consumer routes between the shim (snoop mode,
    //     dma_mode_q=0) and dma_master via the arbiter (DMA mode,
    //     dma_mode_q=1). Multi-cycle shim latency propagates back to the
    //     consumer via sh_ready / caller_ready.
    wire [15:0] dl_raddr,  cmp_raddr;
    wire [7:0]  dl_rdata,  cmp_rdata;
    wire        dl_req,    cmp_req;
    wire        dl_ready,  cmp_ready;

    // shim read-port handshake to mem_read_mux (snoop-side).
    wire [15:0] dl_sh_raddr, cmp_sh_raddr;
    wire        dl_sh_req,   cmp_sh_req;
    wire [7:0]  dl_sh_rdata, cmp_sh_rdata;
    wire        dl_sh_ready, cmp_sh_ready;

    // SALLY writes propagate to sally_mem's BRAM directly via its normal
    // bus interface; ANTIC reads the same BRAM through its second port
    // (sally_mem.dma_addr/dma_rdata at clk_bus).  No separate shadow
    // memory is needed.
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
    // dl_start_pulse fires once per frame at vbi_start (driven by the
    // antic_seq render sequencer below).  Snapshotting mode_snoop_q at that
    // frame boundary keeps dma_mode stable for the whole frame's parse +
    // per-scanline compose.  (Forward declaration; both pulses are driven by
    // the u_antic_seq instance further down.)
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

    // dl_parser status (declared here so the render sequencer below can gate
    // the first compose on parse_done; the parser itself is instanced after).
    wire        dl_done;
    wire [31:0] dl_count;

    // ---- ANTIC native-raster render sequencer (video-arch §5.1) ----------
    // Replaces the old free-running kick_counter scaffold (a fixed ~12 ms timer
    // unrelated to the emulated frame).  Render is now locked to the phi2
    // raster (antic_raster): dl_start_pulse fires once per frame at vbi_start
    // (parse the whole DL during vblank); cmp_start_pulse fires once per active
    // scanline at line_start, composing the row ar_atari_row in raster order.
    // The compositor runs in option-(b) mode (one row per start_compose,
    // row_in = ar_atari_row) so mid-frame register writes / DLIs land on the
    // correct scanline relative to the CPU.
    //
    // Timing budget: clk_bus = phi2 × BASE_DIV (=74), so one scanline = 114 ×
    // 90 = 10,260 clk_bus cycles.  In snoop mode (the v1 config, mem_ready tied
    // high) a row's compose is a few hundred cycles + the writeback row DMA is a
    // few hundred — both fit with ~10× margin.  DMA mode (deferred banked path)
    // is phi2-paced per byte and is tighter for dense rows; revisit with
    // explicit overrun handling when that path is brought up.  An overrun
    // (cmp_start while the compositor is still busy on the previous row) is
    // safe-degrading, not corrupting: the compositor ignores start_compose
    // outside S_IDLE, so the row would simply be skipped (stale buffer data).
    antic_seq u_antic_seq (
        .clk        (clk_bus),
        .rst        (rst_bus),
        .vbi_start  (parse_kick_pulse),     // parse trigger: LATE-vblank kick (see PARSE_KICK_LINE)
        .line_start (line_start_pulse_bus),
        .active_row (ar_atari_row != 8'hFF),
        .parse_done (dl_done),
        .dl_start   (dl_start_pulse),
        .cmp_start  (cmp_start_pulse)
    );

    // ---- dl_parser ------------------------------------------------------
    wire [7:0]  meta_row_q;
    wire [3:0]  dl_meta_mode;
    wire        dl_meta_dli;
    wire [15:0] dl_meta_lms;
    wire [3:0]  dl_meta_sub;
    wire        dl_meta_hscrol_en;
    wire        dl_meta_vscrol_en;
    // TEMP diag: expose NMIEN/NMIST + a CUMULATIVE count of DLIs that fire with
    // NMIEN[7] set -> dbg_antic (routed to diag8, GP0 0x41C).  Cumulative (not
    // per-frame) so a before/after delta around one xexload isolates whether the
    // DLI-enabled event EVER occurs on the ANTIC side for that test.
    //   dbg_dli_cnt delta > 0  => DLI fires with NMIEN[7] on ANTIC; bug is DELIVERY to CPU
    //   dbg_dli_cnt delta == 0 => NMIEN[7] never coincides with a DLI row; bug is earlier
    reg  [7:0]  dbg_dli_cnt;      // DLI rows that fire WITH nmien[7] set (gated)
    reg  [7:0]  dbg_dliu_cnt;     // DLI rows that fire regardless of nmien (ungated)
    reg  [7:0]  dbg_nmien_or;     // sticky OR of nmien_q — was bit7 EVER set?
    wire        dbg_dli_fire  = ar_line_start & nmi_cur_row_dli & nmien_q[7];
    wire        dbg_dliu_fire = ar_line_start & nmi_cur_row_dli;
    always_ff @(posedge clk_bus) begin
        if (rst_bus) begin
            dbg_dli_cnt  <= 8'h0;
            dbg_dliu_cnt <= 8'h0;
            dbg_nmien_or <= 8'h0;
        end else begin
            if (dbg_dli_fire)  dbg_dli_cnt  <= dbg_dli_cnt  + 8'h1;
            if (dbg_dliu_fire) dbg_dliu_cnt <= dbg_dliu_cnt + 8'h1;
            dbg_nmien_or <= dbg_nmien_or | nmien_q;
        end
    end
    // nmien[7] is HELD through the dli1 phase (clr_pc = _testEnd), yet gated=0,
    // so dl_parser never flags the test DL's DLI rows.  Capture the DL address
    // dl_parser is actually using WHILE nmien[7] is set (the dli1 phase): if it
    // is not $2C00 the wrong DL is parsed; if it is, the DL data read is stale.
    reg [15:0] dbg_dlist_at_n7;
    always_ff @(posedge clk_bus) begin
        if (rst_bus)        dbg_dlist_at_n7 <= 16'h0;
        else if (nmien_q[7]) dbg_dlist_at_n7 <= {dlisth_q, dlistl_q};
    end
    // dl_parser uses the RIGHT DL ($2C00) but no DLI fires. Split stale-data (B)
    // from parse/lookup (C): capture the DL bytes dl_parser actually reads at
    // $2C00 (should be $70) and $2C02 (should be $F0, blank-8+DLI), plus whether
    // line_dli_p[23] is ever seen set at the raster row nmi_gen looks up.
    reg  [7:0]  dbg_dl_b00, dbg_dl_b02;
    reg  [15:0] dl_raddr_q;
    reg         dl_ready_q;
    reg         dbg_raster23;    // sticky: raster reached atari_row 23
    reg         dbg_dlip23;      // sticky: line_dli_p[23] set when raster at row 23
    always_ff @(posedge clk_bus) begin
        dl_raddr_q <= dl_raddr;
        dl_ready_q <= dl_ready;
        if (dl_ready && dl_raddr == 16'h2C00) dbg_dl_b00 <= dl_rdata;
        if (dl_ready && dl_raddr == 16'h2C02) dbg_dl_b02 <= dl_rdata;
        if (rst_bus) begin dbg_raster23 <= 1'b0; dbg_dlip23 <= 1'b0; end
        else if (ar_atari_row == 8'd23) begin
            dbg_raster23 <= 1'b1;
            if (nmi_cur_row_dli) dbg_dlip23 <= 1'b1;   // line_dli_p[23] set at row 23
        end
    end
    // Snapshot dl_parser's line_dli_p rows {41,40,25,24,23,22,16,8} WHILE the
    // dli1 DL is active (nmien[7]) — shows WHICH rows dl_parser flags for the
    // pfstart DL (expected: bit 23 and 41 set) vs what nmi_gen looks up.
    reg  [7:0] dbg_dlirows_n7;
    always_ff @(posedge clk_bus) begin
        if (rst_bus)              dbg_dlirows_n7 <= 8'h0;
        else if (nmien_q[7] && dbg_dli_rows != 8'h0) dbg_dlirows_n7 <= dbg_dli_rows;
    end
    // line_dli_p[23] is set (snapshot) but 0 when the raster is at row 23
    // (scanline 31) -> the parse sets it TOO LATE. Capture the scanline at the
    // rising edge of line_dli_p[23] (dbg_dli_rows[3]) during dli1: if it is >31
    // (or past row 23's scanline) the parse finishes after the raster needs it.
    reg        dlirow23_q;
    reg  [8:0] dbg_scan_at_set;   // ar_scanline when line_dli_p[23] went 0->1
    always_ff @(posedge clk_bus) begin
        dlirow23_q <= dbg_dli_rows[3];
        if (rst_bus) dbg_scan_at_set <= 9'h0;
        else if (nmien_q[7] && dbg_dli_rows[3] && !dlirow23_q)
            dbg_scan_at_set <= ar_scanline;   // rising edge of line_dli_p[23]
    end
    // Resolve the contradiction: at the instant the raster is AT row 23, sample
    // BOTH the constant-index read (dbg_dli_rows[3] = line_dli_p[23]) and the
    // variable-index read (nmi_cur_row_dli = dli_at = line_dli_p[dli_row]).
    //   const=1, var=0 => inference: the variable read disagrees (ram_style not
    //                     enough) -> the fix is in the read structure
    //   const=0, var=0 => line_dli_p[23] is genuinely CLEARED by scanline 31
    // line_dli_p[23] rises at 248 but is 0 at scanline 31, and antic_seq only
    // clears at vbi_start(248) -> capture the FALLING-edge scanline to find the
    // hidden re-clear.
    reg [8:0] dbg_scan_at_clr;
    always_ff @(posedge clk_bus) begin
        if (rst_bus) dbg_scan_at_clr <= 9'h0;
        else if (nmien_q[7] && !dbg_dli_rows[3] && dlirow23_q)   // 1->0 edge
            dbg_scan_at_clr <= ar_scanline;
    end
    // line_dli_p[23] is cleared at scanline 17, but start_parse should only fire
    // at vbi_start(248). Capture where dl_start_pulse actually fires and where
    // the parse completes: dl_start@17 => spurious trigger; parse crossing into
    // the visible frame => the long DL parse re-clears mid-display.
    reg [8:0] dbg_vbi_bad;       // scanline of any vbi_start NOT at 248
    reg [8:0] dbg_dlstart_bad;   // scanline of any dl_start NOT at 248
    reg [7:0] dbg_vbi_cnt;       // total vbi_start pulses during nmien[7]
    always_ff @(posedge clk_bus) begin
        if (rst_bus) begin
            dbg_vbi_bad<=9'h0; dbg_dlstart_bad<=9'h0; dbg_vbi_cnt<=8'h0;
        end else if (nmien_q[7]) begin
            if (vbi_start_pulse_bus) begin
                dbg_vbi_cnt <= dbg_vbi_cnt + 8'd1;
                if (ar_scanline != 9'd248) dbg_vbi_bad <= ar_scanline;
            end
            if (dl_start_pulse && ar_scanline != PARSE_KICK_LINE) dbg_dlstart_bad <= ar_scanline;
        end
    end
    // DEFINITIVE generation-vs-delivery split. cycle-8 DLI fire = the exact
    // condition nmi_gen uses for the DLI /NMI. If gated_c8 fires but the fid
    // core never dispatches (fid-side nmist7~0), the bug is DELIVERY; if
    // gated_c8 stays 0 with the list populated, generation is still broken.
    wire c8 = phi2_tick && (ar_phi2_in_line == 8'd8);
    reg [7:0] dbg_gated_c8;
    reg [4:0] dbg_listcnt_n7;
    reg       dbg_has23_n7;
    always_ff @(posedge clk_bus) begin
        if (rst_bus) begin dbg_gated_c8<=0; dbg_listcnt_n7<=0; dbg_has23_n7<=0; end
        else begin
            if (c8 && nmi_cur_row_dli && nmien_q[7]) dbg_gated_c8 <= dbg_gated_c8 + 8'd1;
            if (nmien_q[7]) begin
                if (dbg_dli_listcnt != 0) dbg_listcnt_n7 <= dbg_dli_listcnt;
                if (dbg_dli_has23)        dbg_has23_n7   <= 1'b1;
            end
        end
    end
    // Sample dli_cnt + dli_at AT scanline 31 (raster row 23), cycle 8 — exactly
    // where/when the DLI must fire. dli_cnt_at23==0 => list cleared by then;
    // dli_cnt_at23>0 && dli_at23==0 => comparator/dli_row broken; both good =>
    // generation works and the bug is delivery.
    reg [4:0] dbg_cnt_at23;
    reg       dbg_at23, dbg_hit23seen;
    always_ff @(posedge clk_bus) begin
        if (rst_bus) begin dbg_cnt_at23<=0; dbg_at23<=0; dbg_hit23seen<=0; end
        else if (nmien_q[7] && c8 && ar_atari_row==8'd23) begin
            dbg_hit23seen <= 1'b1;
            dbg_cnt_at23  <= dbg_dli_listcnt;      // list size at scanline 31 cyc 8
            if (nmi_cur_row_dli) dbg_at23 <= 1'b1; // dli_at at scanline 31 cyc 8
        end
    end
    // {dlstart_bad scanline[31:23], dlstart_cnt[22:15], pdone scanline...[14:8],
    //  ungated[7:0]}.  dlstart_bad != 0 => start_parse fires at a wrong scanline
    // (spurious re-parse clears the DLI state mid-frame).
    // {vbi_bad scanline[31:23], dlstart_bad[22:14], vbi_cnt[13:6]... , ungated[5:0]}.
    wire [3:0] dbg_parser_state;
    wire [1:0] dbg_parser_phase;
    // Parser is in one of its WAIT states (2=OP, 5=LMS_LO, 8=LMS_HI,
    // 11=JMP_LO, 14=JMP_HI): the cycle mem_ready completes a fetch.
    wire dl_in_wait = (dbg_parser_state == 4'd2)  || (dbg_parser_state == 4'd5)
                   || (dbg_parser_state == 4'd8)  || (dbg_parser_state == 4'd11)
                   || (dbg_parser_state == 4'd14);
    // diag8: {[31:28]=parser state, [27:26]=emit phase, [25:24]=0,
    //         [23:16]=parse_count[7:0], [15:8]=dlstart_bad[7:0], [7:0]=ungated DLI count}
    assign dbg_antic = {dbg_parser_state, dbg_parser_phase, 2'b00,
                        dl_count[7:0], dbg_dlstart_bad[7:0], dbg_dliu_cnt};

    dl_parser u_dl_parser (
        // start_parse is GATED to the true frame boundary: the only legitimate
        // dl_start_pulse fires at vbi_start (scanline 248), and a spurious
        // pulse anywhere else (measured mid-frame on hardware, build-dependent)
        // would re-enter the parse FSM and wipe the live row metadata the
        // display is reading.  Rejecting it here bounds that whole fault class.
        // The compare is REGISTERED (scanline holds for a whole line, so a
        // 1-clk-late flag is equally valid) to keep ar_scanline's fanout off
        // the timing-critical pulse path.
        .clk(clk_bus), .rst(rst_bus),
        .cold_abort(cold_boot_bus),
        .dbg_state(dbg_parser_state), .dbg_emit_phase(dbg_parser_phase),
        .start_parse(dl_start_pulse && scanline_is_vbi_q),
        .dlistl(dlistl_q), .dlisth(dlisth_q),
        .dlistl_we(dlistl_we_w), .dlisth_we(dlisth_we_w),
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
        .dbg_dli_rows(dbg_dli_rows),
        .dbg_dli_cnt(dbg_dli_listcnt),
        .dbg_dli_has23(dbg_dli_has23),
        .parse_done(dl_done), .parse_count(dl_count)
    );

    // ---- Cycle-exact ANTIC DMA cycle-steal -----------------------------
    // Drives the CPU's /HALT (through sally_clock at CLOCK_MULT=1) so the
    // emulated 6502 loses bus cycles to refresh/DL/playfield/P-M DMA exactly as
    // on real hardware.  Combinational on the current machine cycle (phi2 raster
    // position) + the current row's mode/sub-row + DMACTL.  dl_meta_mode/_sub are
    // the metadata for the row being rendered (meta_row_q tracks ar_atari_row).
    wire dma_steal_comb;
    antic_dma_steal u_dma_steal (
        .cyc      (ar_phi2_in_line),
        .mode     (dl_meta_mode),
        .is_first (dl_meta_sub == 4'd0),
        .active   (ar_atari_row != 8'hFF),
        .dmactl   (dmactl_q),
        .steal    (dma_steal_comb)
    );
    // Register in clk_bus so the cross-domain CDC source (into clk_sally) is a
    // flop, like the other ANTIC->SALLY status bits.  The 1-clk_bus latency is
    // negligible: the steal envelope is stable for a whole machine cycle (~74
    // clk_bus = one phi2).
    reg dma_steal_q;
    always_ff @(posedge clk_bus or posedge rst_bus)
        if (rst_bus) dma_steal_q <= 1'b0;
        else         dma_steal_q <= dma_steal_comb;
    assign dma_steal = dma_steal_q;

    // ---- Cycle-8 NMI strobe (M-antic-dli) ----------------------------
    // Real ANTIC raises the DLI / VBI NMI at machine cycle 8 of the scan
    // line, not cycle 0 (where line_start / vbi_start pulse).  Derive a
    // cycle-8 strobe (parallel to the cycle-105 WSYNC strobe below) and
    // feed nmi_gen's DLI/VBI triggers from it.  All clk_bus — no CDC, like
    // vbi_start_pulse_bus / line_start_pulse_bus.  cur_row_dli is a
    // combinational lookup that is stable across the whole line, so
    // sampling it at cycle 8 (rather than cycle 0) is fine.
    wire cycle_8_pulse = phi2_tick && (ar_phi2_in_line == 8'd8);
    wire cycle_6_pulse = phi2_tick && (ar_phi2_in_line == 8'd7);   // NMIST status tick
    // (cycle 7, matching Altirra's mX==7 NMIST slot: hardware-bisected —
    //  8 fails 'set too late (>cycle 6)', 6 fails 'set too early (<cycle 6)')

    // The VBI marker (ar_vbi_start) pulses at cycle 0 of the VBLANK line;
    // latch it and release the VBI NMI at that same line's cycle-8 strobe
    // so the VBI lands on the same machine cycle as a DLI.
    logic vbi_c8_pending;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus)                  vbi_c8_pending <= 1'b0;
        else if (vbi_start_pulse_bus) vbi_c8_pending <= 1'b1;
        else if (cycle_8_pulse)       vbi_c8_pending <= 1'b0;
    end
    wire vbi_c8_pulse = cycle_8_pulse && vbi_c8_pending;
    wire vbi_c6_pulse = cycle_6_pulse && vbi_c8_pending;   // status leads the /NMI

    // ---- NMI generator (M12) -----------------------------------------
    // Instantiated in clk_bus. cur_row from nmi_gen closes the DLI loop
    // with dl_parser via combinational dli_at. DLI/VBI triggers come from
    // the cycle-8 strobe above (cycle_8_pulse for DLI, vbi_c8_pulse for VBI).
    nmi_gen u_nmi_gen (
        .clk           (clk_bus),
        .rst           (rst_bus),
        .nmien         (nmien_q),
        .nmires_strobe (nmires_strobe),
        .status_tick   (phi2_tick),
        .vbi_status    (vbi_c6_pulse),
        .vbi_start     (vbi_c8_pulse),
        .line_status   (cycle_6_pulse),
        .line_start    (cycle_8_pulse),
        .cur_row       (nmi_cur_row),
        .cur_row_dli   (nmi_cur_row_dli),
        .atari_row_in  (ar_atari_row),
        .nmist_q       (nmist_q),
        .nmi_n         (nmi_n_w)
    );

    // ================================================================
    // ANTIC timebase debug probe (DBG_TB_*) — GP0 DEBUG block.
    //
    // A 16-entry capture ring + configurable trigger.  On the selected
    // event it records the 2D timebase — ar_scanline (0..261) and
    // ar_phi2_in_line (machine-cycle 0..113) — plus a data byte.  This is
    // the measurement tool for the ACID800 ANTIC-timing test family: it
    // answers "on which scanline and which horizontal cycle did this
    // register write / DLI / VBI / WSYNC happen?".
    //
    // All logic runs in clk_bus (the snoop + antic_raster domain).  The A9
    // config word is slow control and 2-FF synced in with cdc_sync_bit;
    // the status/capture words are stable (written at most once per event)
    // and 2-FF synced on the clk_sys (GP0) side.  The probe is purely
    // observational — it drives nothing in the ANTIC datapath.
    //
    // cfg: [2:0]=mode [11:4]=match_addr [19:16]=read_idx [24]=clear [25]=circular
    // mode: 0=off 1=$D4xx wr@match 2=$D4xx rd@match 3=DLI-line 4=VBI
    //       5=WSYNC($D40A wr) 6=any $D4xx wr 7=every ar_line_start
    // circular: 0 = stop-on-full (hold the FIRST 16 triggers, then freeze);
    //           1 = wrap (hold the LAST 16 triggers — the ring rolls so it
    //           always shows the most-recent events; pairs with xexload --hold
    //           to capture steady-state / failing-assert timing, not boot).
    // ================================================================
    wire [28:0] dbg_tb_cfg_s;
    // Slow A9 config: every field (mode/match/read_idx/clear/circular) is quasi-
    // static — set and left to settle before the probe is armed or read back.
    // cdc-lint: independent-bits — quasi-static config, per-bit 2-FF skew is benign
    cdc_sync_bit #(.WIDTH(29)) u_tb_cfg_sync (
        .dst_clk (clk_bus),
        .src_sig (dbg_tb_cfg),
        .dst_sig (dbg_tb_cfg_s)
    );

    wire [2:0] tb_mode       = dbg_tb_cfg_s[2:0];
    wire [7:0] tb_match_addr = dbg_tb_cfg_s[11:4];
    wire [3:0] tb_read_idx   = dbg_tb_cfg_s[19:16];
    wire       tb_clear      = dbg_tb_cfg_s[24];
    wire       tb_circular   = dbg_tb_cfg_s[25];

    // Edge-detect the (synced) clear so one cfg write with clear=1 arms and
    // resets the ring for exactly one fresh capture pass.
    logic tb_clear_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) tb_clear_q <= 1'b0;
        else         tb_clear_q <= tb_clear;
    end
    wire tb_clear_pulse = tb_clear & ~tb_clear_q;

    // cfg[12] narrows mode 3 to DLIs that actually ASSERT /NMI (nmien[7] set),
    // which is the only way to tell "the DL never raised a DLI" apart from "it
    // raised one while DLIs were masked".  Without it the 16-entry ring fills
    // with masked boot/framework DLIs and the interesting frame is never
    // visible (ACID800 nmist/dlitiming/pfstart-stop all hinge on this).
    wire tb_dli_nmi_only = dbg_tb_cfg_s[12];
    // cfg[13]: retarget mode 2 from the ANTIC ($D4xx) read strobe to the LEFT
    // POKEY ($D2xx).  The ACID800 suite times WSYNC by reading POKEY RANDOM
    // ($D20A) as a cycle-exact clock, so measuring WHICH machine cycle that read
    // lands on is the only way to see a 1-cycle CPU timing error directly rather
    // than inferring it from the returned byte.
    wire tb_pokey_rd     = dbg_tb_cfg_s[13];

    // Trigger select (single-cycle pulse; write/read modes are qualified by
    // the snoop write/read strobe).
    logic tb_trig;
    always_comb begin
        unique case (tb_mode)
            3'd1:    tb_trig = snoop_we_antic & (snoop_addr[7:0] == tb_match_addr);
            3'd2:    tb_trig = (tb_pokey_rd ? snoop_re_pokey_l : snoop_re_antic)
                             & (snoop_addr[7:0] == tb_match_addr);
            // DLI at the REAL gate cycle (8), matching nmi_gen — captures nmien_q.
            3'd3:    tb_trig = cycle_8_pulse & nmi_cur_row_dli
                             & (~tb_dli_nmi_only | nmien_q[7]);
            3'd4:    tb_trig = vbi_c8_pulse;
            3'd5:    tb_trig = snoop_we_antic & (snoop_addr[7:0] == 8'h0A); // WSYNC $D40A
            3'd6:    tb_trig = snoop_we_antic;
            3'd7:    tb_trig = tb_dli_nmi_only ? (dl_ready & dl_in_wait)
                                               : ar_line_start;   // cfg[12]: parser-fetch capture
            default: tb_trig = 1'b0;                                       // mode 0 = off
        endcase
    end

    // One capture per bus access.  snoop_re_antic / snoop_we_antic are LEVELS
    // (held for the whole bus phase), so a level-sensitive trigger fired TWICE
    // per access and the second sample caught the live bus_addr read mux after
    // it had already moved on — recording a garbage $FF alongside every good
    // value.  Edge-detect so each access captures exactly once, on the cycle the
    // data is still valid.  The pure-event modes (3=DLI, 4=VBI, 7=line) are
    // already 1-cycle pulses, so their rising edge is the same cycle: unaffected.
    logic tb_trig_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) tb_trig_q <= 1'b0;
        else         tb_trig_q <= tb_trig;
    end
    wire tb_trig_edge = tb_trig & ~tb_trig_q;

    // cfg[3] = visible-only: ignore triggers during vertical blank (scanline >=
    // 240).  The ACID800 framework's `cmp:rne vcount` sync loops hammer $D40B in
    // vblank and otherwise monopolise the 16-entry ring, hiding the test's own
    // measurement reads (the ones whose cycle position is actually under test).
    // clk_sys closes with ~zero margin, so the scanline compare is REGISTERED out
    // of the capture-enable path (scanline only changes once per 114 cycles, so a
    // 1-cycle-stale visible flag is exact at every trigger except a line boundary).
    wire tb_visible_only = dbg_tb_cfg_s[3];
    logic tb_scan_vis_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) tb_scan_vis_q <= 1'b1;
        else         tb_scan_vis_q <= (ar_scanline < 9'd240);
    end
    wire tb_scan_ok = ~tb_visible_only | tb_scan_vis_q;

    // Capture payload byte: the write byte for write modes, the ANTIC
    // register read mux (valid at snoop_addr during a $D4xx read, since
    // antic_regs.raddr = bus_addr = snoop_addr) for the read mode, else the
    // live NMIEN for the pure-event modes (3=DLI, 4=VBI, 7=line) — so a DLI-line
    // capture records the gating NMIEN value at that scanline (is bit7 set?).
    wire [7:0] tb_data8 =
          (tb_mode == 3'd1 || tb_mode == 3'd5 || tb_mode == 3'd6) ? snoop_data
        : (tb_mode == 3'd2)  ? (tb_pokey_rd ? pokey_l_read_data : antic_read_data)
        :                                                           nmien_q;

    // 16-entry ring in distributed RAM: {scanline[8:0], phi2_in_line[7:0], data[7:0]}.
    logic [24:0] tb_ring [0:15];
    logic [4:0]  tb_wr_idx;      // stop-on-full: 0..16, bit[4]=full (saturates).
                                 // circular: bit[4]=0, [3:0]=next write slot (wraps 0..15).
    logic [15:0] tb_trig_count;  // 16-bit saturating trigger count since clear
    logic        tb_armed;
    // stop-on-full: full once the index reaches 16 (bit4). circular: full once the
    // ring has wrapped (>=16 triggers seen), i.e. all 16 slots are recent events.
    wire         tb_full = tb_circular ? (tb_trig_count >= 16'd16) : tb_wr_idx[4];

    // The capture is PIPELINED one clk_bus: payload + accept decision are
    // registered before touching the 16x25 ring.  The payload latches on the
    // SAME edge the trigger is evaluated (bus data still valid — see the
    // double-sample note above), only the ring WRITE lands a cycle later.
    // clk_sys closes with ~no margin and the scanline→ring-CE cone was the
    // design's WNS path; scanline/cycle values are stable for ~90 clk_bus,
    // so the recorded values are identical.
    logic        tb_accept_q;
    logic [24:0] tb_payload_q;
    logic [15:0] tb_fetch_stage_q;   // {ready-cycle data, addr} staging for fetch mode
    logic        tb_fetch_acc1;      // fetch-mode capture pipeline stage 1
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) begin
            tb_accept_q  <= 1'b0;
            tb_payload_q <= 25'd0;
            tb_fetch_acc1 <= 1'b0;
            tb_fetch_stage_q <= 16'd0;
        end else begin
            // mode 7 + cfg[12]: parser-fetch capture —
            //   {ready-cycle data[8:1], 1'b0, addr low[7:0], NEXT-cycle data[7:0]}
            // The shim/mux chain has a one-cycle data ambiguity (the shim's
            // registered rdata is one transaction stale during its ready
            // cycle, and dl_parser consumes JMP/JVB high bytes ON ready but
            // opcodes one cycle AFTER) — capturing both cycles' bytes per
            // fetch shows which carries the truth and what the other holds.
            // Two-stage: the trigger cycle snapshots {data, addr}; the next
            // cycle assembles the payload with the live (next-cycle) data.
            if (tb_mode == 3'd7 && tb_dli_nmi_only) begin
                tb_fetch_acc1 <= tb_armed && tb_trig_edge && tb_scan_ok;
                if (tb_trig_edge) tb_fetch_stage_q <= {dl_rdata, dl_raddr[7:0]};
                tb_accept_q   <= tb_fetch_acc1;
                if (tb_fetch_acc1)
                    tb_payload_q <= {tb_fetch_stage_q[15:8], 1'b0,
                                     tb_fetch_stage_q[7:0], dl_rdata};
            end else begin
                tb_fetch_acc1 <= 1'b0;
                tb_accept_q   <= tb_armed && (tb_mode != 3'd0) && tb_trig_edge && tb_scan_ok;
                tb_payload_q  <= {ar_scanline, ar_phi2_in_line, tb_data8};
            end
        end
    end

    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) begin
            tb_wr_idx     <= 5'd0;
            tb_trig_count <= 16'd0;
            tb_armed      <= 1'b0;
        end else if (tb_clear_pulse) begin
            tb_wr_idx     <= 5'd0;
            tb_trig_count <= 16'd0;
            tb_armed      <= 1'b1;      // arm a fresh capture pass
        end else if (tb_accept_q) begin
            if (tb_circular) begin
                // Circular: always write, wrap the 4-bit slot; never freeze. The
                // ring holds the LAST 16 triggers; wr_idx (=next slot) is the OLDEST.
                tb_ring[tb_wr_idx[3:0]] <= tb_payload_q;
                tb_wr_idx               <= {1'b0, tb_wr_idx[3:0] + 4'd1};
            end else if (!tb_full) begin
                // Stop-on-full (default): fill once, then freeze on the FIRST 16.
                tb_ring[tb_wr_idx[3:0]] <= tb_payload_q;
                tb_wr_idx               <= tb_wr_idx + 5'd1;   // stops at 16 (bit4 set)
            end
            if (tb_trig_count != 16'hFFFF)
                tb_trig_count <= tb_trig_count + 16'd1;
        end
    end

    // Read-out: stable once cfg (hence read_idx) has settled, so a plain
    // 2-FF sync on the GP0 side is safe.
    assign dbg_tb_cap  = tb_ring[tb_read_idx];
    assign dbg_tb_stat = {6'd0, tb_armed, tb_full, 3'd0, tb_wr_idx, tb_trig_count};

    // ---- WSYNC handler ---------------------------------------------------
    // The CPU resumes on bus cycle 105 of the scan line (start of horizontal
    // blank).  The phi2-cycle-within-line count comes from antic_raster
    // (ar_phi2_in_line, 0..113) — which is what makes this correct: a counter
    // reset by the 140 kHz vbeam line_start (~12 phi2 cycles) never reaches
    // 105, so WSYNC would never release.
    //
    // /RDY is a registered output of wsync_gen's WSYNC latch and trails it by
    // one machine cycle in both directions, so the latch is cleared at 103.
    // For plain-STA code that is cycle-identical to a combinational /RDY
    // released at 103 (both edges shift together), which is what keeps the
    // OS coldstart resume point where it boots; the register stage is what
    // gives an INC WSYNC's second write its delay slot (ACID800 antic_wsync).
    //
    // Both the release point and the /RDY shape are runtime-tunable from
    // the DBG_TB config register, because the fid core's coldstart is sensitive
    // to WSYNC timing and each candidate would otherwise cost a full rebuild:
    //   cfg[23:20] = signed offset applied to the 103 release cycle
    //   cfg[28:26] = /RDY shape mask {latch,q1,q2} (0 = default = 011, q1|q2)
    //   cfg[14]    = /RDY combinational fallback (0 = registered, default)
    //   cfg[15]    = DISABLE CPU-side write-immunity (0 = immune, boots)
    // Release cycle 104: with the registered-set latch + q1 shape this puts
    // the post-WSYNC resume on the cycle real hardware resumes on — measured
    // on HW as the single release value where antic_vcount's VCOUNT reads
    // land on 111/112 (103 reads a cycle early, 105 a cycle late) while
    // antic_wsync, whose poly clock resynchronises to the release, passes at
    // any offset.
    wire signed [3:0] wsync_rel_adj  = dbg_tb_cfg_s[23:20];
    wire       [7:0]  wsync_rel_cyc  = 8'd104 + {{4{wsync_rel_adj[3]}}, wsync_rel_adj};
    wire       [2:0]  wsync_shape    = dbg_tb_cfg_s[28:26];
    wire              wsync_comb_sel = dbg_tb_cfg_s[14];
    assign wsync_write_immune = ~dbg_tb_cfg_s[15];              // out to fpga_xt_top
    wire wsync_release_pulse = phi2_tick && (ar_phi2_in_line == wsync_rel_cyc);

    wire        wsync_rdy_w;             // 1 = ready, 0 = stalled
    // The one-cycle "delay slot" before /RDY falls lives in wsync_gen's output
    // pipeline, so the write pulse goes straight in: a read-modify-write's
    // second write re-sets an already-set latch and must not restart it.  See
    // wsync_gen.sv for the logic-analyser trace this is modelled on.
    //
    // NOTE the ACID800 SOURCE COMMENTS are wrong on cycle numbers ("the code is
    // checked against a real Atari, but the comments aren't") — do not
    // re-derive timing from them.  antic_wsync's asserted RANDOM values are
    // $95, $0D, $44 and $34, at 9-bit-poly steps 113, 342, 569 and 1253.
    wsync_gen u_wsync_gen (
        .clk                (clk_bus),
        .rst                (rst_bus),
        .phi2_tick          (phi2_tick),
        .phi2_fall          (phi2_fall),
        .shape_sel          (wsync_shape),
        .comb_sel           (wsync_comb_sel),
        .wsync_pending      (wsync_pending),
        .line_start         (wsync_release_pulse),
        .rdy_n              (wsync_rdy_w),
        .wsync_overdue_count(wsync_overdue_count_q)
    );

    // ---- Compositor -----------------------------------------------------
    wire [1:0]  cmp_cmd_tag;
    wire [23:0] cmp_cmd_addr;
    wire [23:0] cmp_cmd_data;
    wire        cmp_cmd_valid;
    // No downstream back-pressure consumer yet, so the compositor command
    // channel is tied always-ready.
    wire        cmp_cmd_ready = 1'b1;
    wire        cmp_done;
    wire [31:0] cmp_count;

    compositor u_compositor (
        .clk(clk_bus), .rst(rst_bus), .start_compose(cmp_start_pulse),
        .row_in(ar_atari_row),                 // compose this row
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
        // GRAFPx/GRAFM shape registers — CPU-written shapes render without DMA;
        // the P/M DMA fetch overwrites them per scanline when DMA is enabled.
        .grafp0(grafp_q[0]), .grafp1(grafp_q[1]),
        .grafp2(grafp_q[2]), .grafp3(grafp_q[3]),
        .grafm(grafm_q),
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
        // ANTIC_CHIPLET-gated: locked → the DRAW engine ($D488-$D49B) is dead and
        // those addresses fall through to the stock ANTIC mirror in antic_regs.
        .we             (snoop_we_antic & unlock_antic_q),
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

    // Keypad->joystick override MUX (joy_ovr[31]): PORTA pin shadow feeding
    // pia_regs is forced from joy_ovr[7:0] (active-low STICK0/1) when enabled.
    // When NOT overridden the idle value must be $FF = all directions RELEASED
    // (STICK0/1 = $0F centred). The joy_bridge/PCAL9722 poll shadow (w_joy_porta_in)
    // is NOT used here: with no companion MCU the SPI reads a tied-off expander =
    // $00, i.e. "all four directions pressed" every frame, which the game reads as
    // garbage input (bike uncontrollable / needs fire to start). Re-source from
    // w_joy_porta_in once the companion MCU actually drives the expander.
    wire [7:0] pia_joy_porta_in = joy_ovr[31] ? joy_ovr[7:0] : 8'hFF;

    pia_regs u_pia_regs (
        .clk           (clk_bus),
        .rst           (rst_bus),
        .we            (snoop_we_pia),
        .waddr         (snoop_addr),
        .wdata         (snoop_data),
        .raddr         (read_addr_w),
        .rdata         (pia_read_data),   // boot blocker #3: feed PIA reads to the bus mux
        .joy_porta_in  (pia_joy_porta_in),  // keypad-override muxed (joy_ovr[31] ? joy_ovr[7:0] : joy_bridge shadow)
        // XL/XE PORTB is MEMORY MANAGEMENT (OS-ROM/BASIC/self-test/bank), NOT a
        // joystick port (only the 400/800 had joysticks 3/4 on PORTB; the XL has 2
        // ports, both on PORTA). Its input-configured bits float high. Routing the
        // companion's joystick reads here made the OS read OS-ROM-enable (bit0) as a
        // joystick 0 and its PORTB read-modify-write turned the OS ROM OFF mid-
        // coldstart (STA $D301 at $C310, banking in the self-test) -> next fetch = RAM
        // -> BRK/IRQ derail. Tie to all-1s: input bits read high, so the RMW keeps the
        // driven memory-management bits intact. Found via /bin/6502 (breakpoint+trace).
        .joy_portb_in  (8'hFF),
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

    // Hi-res modes (ANTIC 2/3 text + F = GR.8): the lit pixel takes its LUMA
    // from COLPF1 but its HUE from COLPF2.  REGISTERED on clk_bus so the fan-out from
    // dl_meta_mode (4-bit) to two color_resolver instances stays local to a
    // flop — feeding it combinationally cost ~155 ps of clk_sally margin in
    // testing (it pulled cells into the placement region next to sally_mem,
    // pushing the page_cache cone past timing).  dl_meta_mode is stable for
    // the duration of the row being rendered, so the 1-clk_bus latency to
    // catch a mode change is invisible — the compositor's first pixel for a
    // newly-parsed DL row arrives many cycles after dl_meta_mode updates.
    reg  colpf1_luma_only_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) colpf1_luma_only_q <= 1'b0;
        else         colpf1_luma_only_q <= (dl_meta_mode == 4'd2)   // GR.0 hi-res text
                                         || (dl_meta_mode == 4'd3)
                                         || (dl_meta_mode == 4'hF);  // GR.8 hi-res 1bpp
    end
    wire colpf1_luma_only = colpf1_luma_only_q;

    // cmd_data layout (apply_pm_overlay): {m_hi[3:0], m_lo[3:0], hi8[7:0], lo8[7:0]}.
    // Each resolver wants a 12-bit {M-nibble[11:8], owner[7:0]} pixel — so the
    // halves are NOT contiguous: lo = {m_lo, lo8} = {[19:16],[7:0]};
    // hi = {m_hi, hi8} = {[23:20],[15:8]}.  (Slicing [11:0]/[23:12] put the
    // wrong byte in the HI owner field — every odd COLPF pixel mis-resolved.)
    // DMACTL screen-blank: real ANTIC shows COLBK when the playfield isn't being
    // DMA'd (DMACTL playfield width = 0, or DL DMA disabled).  Forcing the
    // resolver's pixel command to 0 (owner=COLBK, no P/M overlay) blanks the
    // whole playfield to COLBK while the CPU keeps drawing into screen RAM —
    // re-enabling DMACTL brings the finished picture back next frame.  Gated by
    // dmactl_honor (PS opt-in) so legacy behaviour (always render) is the default.
    wire       dmactl_blank   = dmactl_honor
                              && ((dmactl_q[1:0] == 2'b00) || ~dmactl_q[5]);
    wire [23:0] cmp_cmd_eff   = dmactl_blank ? 24'd0 : cmp_cmd_data;

    color_resolver u_color_lo (
        .idx_buf  ({cmp_cmd_eff[19:16], cmp_cmd_eff[7:0]}),
        .prior    (prior_q),
        .colpm0   (colpm_q[0]), .colpm1(colpm_q[1]),
        .colpm2   (colpm_q[2]), .colpm3(colpm_q[3]),
        .colpf0   (colpf_q[0]), .colpf1(colpf_q[1]),
        .colpf2   (colpf_q[2]), .colpf3(colpf_q[3]),
        .colbk    (colbk_q),
        .colpf1_luma_only(colpf1_luma_only),
        .color_out(resolved_color_lo)
    );
    color_resolver u_color_hi (
        .idx_buf  ({cmp_cmd_eff[23:20], cmp_cmd_eff[15:8]}),
        .prior    (prior_q),
        .colpm0   (colpm_q[0]), .colpm1(colpm_q[1]),
        .colpm2   (colpm_q[2]), .colpm3(colpm_q[3]),
        .colpf0   (colpf_q[0]), .colpf1(colpf_q[1]),
        .colpf2   (colpf_q[2]), .colpf3(colpf_q[3]),
        .colbk    (colbk_q),
        .colpf1_luma_only(colpf1_luma_only),
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

    // Ungated read mux for the internal CPU's register read-back (hwreg_rd_cdc).
    // NOT gated by ext_bus_active — the internal CPU must read GTIA/POKEY/PIA/
    // ANTIC at turbo, where the external-bus pad drive (bus_data_out) is held.
    assign bus_rdata_int = bus_data_out_w;

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
    // ANTIC is a window *source*: its rendered line
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
    logic [LB_WR_AW-1:0] lb_wr_pair_bus_q;   // running counter (next pair to fill)
    logic [LB_WR_AW-1:0] lb_wr_pairidx_q;    // index OF the strobed pair (pre-increment)
    logic [15:0]         lb_wr_data_bus_q;
    logic                lb_wr_strobe_bus_q;
    always_ff @(posedge clk_bus or posedge rst_bus) begin
        if (rst_bus) begin
            lb_wr_pair_bus_q   <= '0;
            lb_wr_pairidx_q    <= '0;
            lb_wr_data_bus_q   <= 16'h0000;
            lb_wr_strobe_bus_q <= 1'b0;
        end else begin
            lb_wr_strobe_bus_q <= 1'b0;          // 1-cycle pulse default
            if (line_start_pulse_bus) lb_wr_pair_bus_q <= '0;
            if (cmp_cmd_valid && cmp_cmd_ready
                && lb_wr_pair_bus_q != LB_WR_AW'(LB_WIDTH/2 - 1)) begin
                lb_wr_data_bus_q   <= {resolved_color_hi, resolved_color_lo};
                // wb_pix_pair must label the pair being strobed THIS accept —
                // i.e. the counter value BEFORE the increment.  Surfacing the
                // running counter directly would lead the data by one (the
                // writeback would shift the row right one column-pair and never
                // write column 0).
                lb_wr_pairidx_q    <= lb_wr_pair_bus_q;
                lb_wr_strobe_bus_q <= 1'b1;
                lb_wr_pair_bus_q   <= lb_wr_pair_bus_q + 1'b1;
            end
        end
    end

    // (lb_wr_pair_bus_q / lb_wr_data_bus_q / lb_wr_strobe_bus_q above are
    // surfaced directly to the §5 writeback tap
    // at the bottom of this module.)

    // ---- ANTIC render tap → compositor writeback (video-arch §5) -------
    // Surface the clk_bus render stream / palette / frame pulses for the
    // top-level antic_writeback master.  lb_wr_pair_bus_q / _data_bus_q /
    // _strobe_bus_q advance one column-pair per accepted compositor pair;
    // atari_row / line_start / vbi_start come from the phi2 raster timer
    // (antic_raster) — see line_start_pulse_bus / vbi_start_pulse_bus above.
    assign wb_pix_valid = lb_wr_strobe_bus_q;
    assign wb_pix_pair  = lb_wr_pairidx_q;   // index OF the strobed pair (not the running counter)
    assign wb_color_lo  = lb_wr_data_bus_q[7:0];
    assign wb_color_hi  = lb_wr_data_bus_q[15:8];
    assign wb_atari_row = ar_atari_row;
    assign wb_row_flush = line_start_pulse_bus;
    assign wb_frame_done = vbi_start_pulse_bus;
    assign wb_pal_we    = pal_write_strobe;
    assign wb_pal_idx   = pal_idx_q;
    assign wb_pal_rgb   = {pal_r_q, pal_g_q, pal_b_q};

endmodule

`default_nettype wire
