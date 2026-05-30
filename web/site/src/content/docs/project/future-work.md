---
title: "Future work"
description: "Parking lot of deferred hardware and software ideas, plus a log of completed expansion items."
---


Ideas that aren't in the current milestone scope but are worth recording so
they don't get lost. Anything here is a deliberate "later, not now" — not
a TODO that should be picked up speculatively.

## RS-232 serial port via the second POKEY

Once the second POKEY (M23-stereo, $D21x) lands, its serial port (SEROUT /
SERIN / SKCTL) is unused — the first POKEY's serial port handles SIO.

If we have our own OS, we could repurpose the second POKEY's serial port
as a **standard RS-232 connector** on the rear of the rp-XT board. RS-232
swings ±12 V, so we'd need an external level translator (MAX232-class or
equivalent) between the FPGA's 3.3 V/1.8 V output and the DB9 connector.

Details:
- POKEY's serial port can run at internal-clocked baud rates from
  ~600 baud up to 128 kilobaud (Altirra Manual §5.6).
- DB9 standard pinout: TXD (out), RXD (in), GND, plus optional handshake
  lines (RTS / CTS / DTR / DSR / DCD / RI). For minimum useful, just
  TXD / RXD / GND (3 wires).
- Level translator: MAX232 (charge-pump-based, generates ±10 V from a
  single 5 V supply) or modern equivalent (SP3232, ICL3232) at 3.3 V.
  Sits between the FPGA's 1.8 V → 3.3 V translator stage and the DB9
  pins.
- Pin budget: 2 FPGA pins (TX + RX) + 1 connector. No new HVIO required
  if it shares the SIO bank.
- Software: a custom serial driver in our OS uses the second POKEY's
  POTGO / SEROUT / SERIN / IRQEN bits exactly the same way the first
  POKEY's are used for SIO; the OS routes baud-rate generation through
  AUDF1+AUDF2 (or AUDF3+AUDF4) on the second POKEY.

Why not now: original Atari OS would not understand a second POKEY's
serial port, and routing this through the SIO subsystem requires kernel
changes. Park until "our own OS" milestone.

## COVOX-style DMA-fed sample playback

The classic [COVOX Speech Thing](https://en.wikipedia.org/wiki/Covox_Speech_Thing)
add-on lets a memory buffer be streamed to the audio output without CPU
intervention. The CPU fills a buffer with sample data, points the DMA
engine at it, and the audio plays back continuously — either looped or
play-to-end-then-stop.

Implementation sketch:
- A new `pokey_sample_dma` block (or just an extension of `pokey_audio`)
  with these registers, in some chiplet-extension address range:
  - SAMPLE_BASE (24-bit start address into HyperRAM)
  - SAMPLE_LEN  (24-bit length in bytes)
  - SAMPLE_RATE (16-bit divider, gives playback rate)
  - SAMPLE_CTL  (loop / play-once / stop / paused)
  - SAMPLE_STATUS (currently-playing pointer, end-of-stream flag)
- The block uses the existing HyperRAM shim's read port to fetch one byte
  per sample tick (rate-divided). Each fetched byte feeds an extra
  channel into the digital mixer in `pokey_i2s_tx.sv`.
- ANTIC's existing DMA arbitration handles the bus-time accounting.
- An end-of-stream IRQ source could be added to the second POKEY's IRQ
  table (since we're not using its IRQs for anything else).

Two flavours worth supporting:
1. **8-bit mono** — the original COVOX format. Cheap and small.
2. **16-bit stereo** — useful for sample-quality music. Uses 4 bytes per
   sample, doubles the bandwidth.

Why not now: requires HyperRAM read-port time-sharing with the existing
mem_read_mux, which interacts with ANTIC's DMA timing in non-trivial
ways. Worth doing once the M16b HyperRAM stack is fully exercised under
production loads (M22+) and the bandwidth budget is well understood.

## Analog audio fidelity (Altirra Appendix E)

The `docs/altirra-pokey-audit.md` audit identifies four cosmetic
deviations from POKEY's analog output behaviour:

- **Channel-DAC bit weights** aren't perfect powers of 2 (real POKEY
  shows ~{0.12, 0.26, 0.56, 1.12} V).
- **Non-linear saturation** of the channel sum at total volume > 12.
- **Two-stage analog AC coupling** (τ ≈ 2.6 ms first stage, τ ≈ 24.7 ms
  second stage) — gives POKEY its characteristic exponential-decay
  envelope on long pulses.
- **Polarity / DC bias** — real POKEY output is positive at silence.

These could be implemented as a fixed-point post-mixer DSP block in
`pokey_i2s_tx.sv` that applies the saturation curve and the high-pass
filter at the chosen sample rate. The Altirra appendix gives explicit
discrete-time recurrences (e.g., `y_{n+1} = y_n + (x_n - y_n)·(1 -
e^(-1/(τ·fs)))` for the high-pass).

Why not now: not audible to most users; HDMI sinks already AC-couple
their analog stage. Worth doing for completeness if a "purist" mode is
ever requested, but skip until then.

## Multi-clock /HALT latency (CDC stall prediction)

When SALLY and ANTIC run on separate clock domains (`clk_sally` at ~121 MHz,
`clk_sys` at ≥162 MHz), ANTIC's `/HALT` assertion — used to stall SALLY
during display DMA — becomes a clock-domain crossing. The concern:

- Real ANTIC asserts `/HALT` one phi2 cycle before driving the address bus.
  Cycle-exact software (player/missile, raster interrupts) depends on
  SALLY stopping within that window.
- With CDC, the `/HALT` signal needs 2-3 `clk_sys` cycles + 1-2 `clk_sally`
  cycles to propagate. SALLY executes 3-5 extra instructions before halting.
- This breaks cycle-timing for demos and time-critical code.

**Current workaround** (Phase 1): keep the ANTIC DMA request arbiter and the
`/HALT` FSM on `clk_sally` (same domain as SALLY). The display list parser
and DMA address generator stay on `clk_sys`; a small synchroniser bridges
the DMA request across. This gives tight /HALT timing at the cost of adding
logic to the `clk_sally` netlist — which may reduce its fmax below the
standalone probe result.

**Future options** (revisit when we pipeline SALLY or when real fmax data
shows the impact):

1. **Early prediction** — ANTIC asserts `/HALT` N cycles early based on
   its internal state (e.g., end of current DL instruction). The CDC
   latency becomes a known pipeline delay rather than an uncertainty.
   This is what real ANTIC already does at a finer granularity.
2. **Same-clock DMA** — run the full ANTIC display DMA on `clk_sally`
   (not just the /HALT arbiter). The rest of ANTIC (DL parser, GTIA,
   POKEY, compositor, scan-out) stays on `clk_sys`. This adds more
   logic to `clk_sally` but avoids the CDC problem entirely.
3. **Pipe the SALLY core** — add pipeline stages to SALLY's
   decode/execute path. This raises its fmax ceiling so it can match
   `clk_sys`, eliminating the need for separate domains. This is the
   "extra effort" we're deferring (see zynq-architecture.md), but it
   remains the cleanest fix.

**Trigger to revisit**: either (a) the /HALT FSM on `clk_sally` prevents
closing timing at the target 121-133 MHz, or (b) a cycle-tested demo is
identified that breaks due to the extra stall cycles (unlikely with the
same-clock workaround, but recorded in case).

## Clock-domain separated AXI bus

:::note[Largely obsolete — clk_sys is now 150 MHz]
This item was written when `clk_sys` ran at 100 MHz. It now runs at **150 MHz**
(see the [current-state clock table](/project/current-state/)), so `plane_fetch`
and `xt_blitter` already drive their HP ports at 150 MHz (~1.2 GB/s) — the
800 MB/s cap described below no longer applies and a separate `clk_axi` is
unnecessary. The proposal is kept for its reasoning, still relevant if a future
master ever needs its own faster AXI clock. The "100 MHz" figures below are
historical.
:::

The PL-side AXI masters (plane_fetch, xt_blitter) currently run on clk_sys (100 MHz).
The PS HP ports can run at 150+ MHz, so the AXI bandwidth is artificially capped
at 800 MB/s (64-bit × 100 MHz) vs 1.2 GB/s available at 150 MHz.

The fix: create a separate clk_axi (150 MHz from MMCM #1 CLKOUT2, divider /8)
for the AXI interface logic only. Keep the blitter pixel pipeline and the
compositor's plane_fetch raster logic on their existing slower clocks. Async CDC FIFOs bridge the domains:

- **xt_blitter**: pixel pipeline → burst buffer at 100 MHz; drain FIFO → AXI
  write master at 150 MHz. Read-return path similarly FIFO-buffered.
- **plane_fetch**: AXI read master at 150 MHz → line buffer write port. Line
  buffer read port stays on clk_pix (148.44 MHz). The line buffer BRAM is
  already dual-clock; only the AXI fetch FSM changes domain.
- **zynq_ps_hp_stub.sv**: already a simple register slice — stays on clk_axi.

Benefits:
- Rect fill bandwidth: 800 MB/s → 1.2 GB/s (full-screen clear ~8 ms)
- Framebuffer read margin: 3.9 µs slack → 7.5 µs slack per 1080p60 line
- Blitter DMA bursts drain faster → less time with the AXI bus locked

Cost:
- Two async CDC FIFOs (~200 FF + 2 BRAM18 for the blitter's read/write paths;
  plane_fetch reuses the existing line buffer BRAM)
- Extra MMCM output + BUFG for clk_axi
- Constraint update (set_clock_groups for the 4th clock domain)
- ~150 lines of new RTL

Why not now: the DMA fill mode (see Phase 2b blitter changes) already delivers
within-frame rect fills at 100 MHz. The clock-domain separation becomes worth
doing when (a) we want alpha-blend rect fills at fill-rate, (b) we add a second
blitter instance, or (c) we drive a 4K display panel that needs >800 MB/s
framebuffer bandwidth. Not needed for Phase 2b bring-up.

## Other ideas (one-liners, in case we revisit)

- **Sweet 16** as native hardware ops (referenced in M24 — Apple II's
  microcode-style 16-bit pseudo-machine).
- **Variant board: full 3.3 V Atari** (drops the 5 V translation stack;
  loses period-cart compatibility) — see hardware-notes.md.
- **NTSC composite video output** as a third video path (alongside HDMI)
  for CRT enthusiasts. ANTIC already produces the right timing; adding
  a tiny DAC + sync mixer reaches RCA jack output.
- **Cassette tape interface**: POKEY's two-tone FSK mode is already
  designed for it. Adding a 3.5 mm jack + audio amplifier is mechanical
  more than logical.


## DONE WORK
(move things here as they are completed)

### Expansion-trace reservations

Two HDL items have landed:
- `phi2_o` in commit `2d07117` (M-PBI-adjacent)
- PCM1808 integration in commit `6de29c3` (M-aux-audio)

The remaining item is **second POKEY serial port** — peri-RP-side
PCB reservation only, no FPGA HDL change. See below.

#### Cart/PBI AUDIO_IN — PCM1808 stereo ADC ✓ (HDL complete)

**HDL complete** (commit `6de29c3`): `hdl/pcm1808_rx.sv` drives
BCK/LRCK and samples SDATA; `hdl/pokey_i2s_tx.sv` extended with
`adc_l_in` / `adc_r_in` mix inputs + soft saturation. `antic_top`
exposes new top-level pads `adc_bclk_o`, `adc_lrck_o`,
`adc_sdata_i`. Synth: clk_bus 164.9 MHz / +0.105 ns slack;
47/47 sims pass.

**Design** (TI PCM1808, 24-bit stereo I²S ADC, ~$2 Q10): two
analog mono inputs, both summed into both L and R of the final
stereo output:

- **PCM1808 Lin**  ← SIO AUDIO_IN (from the SIO connector pin —
  same line POKEY's cassette FSK reads from; allows software-FFT
  or future cassette playback)
- **PCM1808 Rin**  ← PBI AUDIO_IN (cart-edge AUDIO_IN signal,
  fanned out to both PBI and cart-slot connectors)

Both inputs are mono signals from physically separate sources;
neither is panned. The audio-mix HDL sums each ADC channel into
**both** sides of the final stereo output:

    out_L = sum(POKEY_L_channels) + adc_l + adc_r
    out_R = sum(POKEY_R_channels) + adc_l + adc_r

#### Board

- 1× PCM1808 in slave mode (BCLK + LRCK driven by FPGA, DOUT to
  FPGA). +$2 BOM.
- DC-blocking caps on each input (typically 1 µF X7R).
- 3.3 V VCC for the PCM1808 digital side, +5 V analog if VCCA is
  separate (check datasheet — most pin-strap configurations run
  on a single 3.3 V supply).
- Trace from SIO connector AUDIO_IN pin to PCM1808 Lin.
- Trace from PBI connector AUDIO_IN pin (fanned to cart-edge
  AUDIO_IN too) to PCM1808 Rin.

#### FPGA pads (new external I²S RX bus)

3 new FPGA outputs/inputs (the existing pokey_i2s_tx is internal-
only — its I²S is just a naming convention for the protocol
shape, no external pins):

| FPGA pin | Dir | Connects to |
|----------|-----|-------------|
| `adc_bclk_o`  | out | PCM1808 BCK (3.072 MHz at 48 kHz sample rate × 64) |
| `adc_lrck_o`  | out | PCM1808 LRCK (48 kHz) |
| `adc_sdata_i` | in  | PCM1808 DOUT (serial PCM, 24-bit per channel L-first) |

Slow-rate pins; can go on any HSIO or HVIO bank.

#### HDL (M-aux-audio milestone, future)

- New `pcm1808_rx.sv` module: BCLK/LRCK generator (off the
  existing 48 kHz tick in pokey_i2s_tx), I²S RX state machine,
  registers L/R 24-bit samples into clk_bus domain.
- Extend `pokey_i2s_tx.sv`: add `adc_l_in[23:0]` and
  `adc_r_in[23:0]` ports; sum both into both `lpcm_l` and
  `lpcm_r` before driving hdmi_pkt_source.
- Probable resource cost: ~80 FF (24-bit L/R sample regs + small
  state machine + BCLK counter), ~80-120 LUTs (RX shift register
  + 2 × 25-bit summing adders), 0 BRAM. fMax impact negligible
  (audio-rate clocked logic, well below critical path).

#### Saturation strategy: soft clamp

`pokey_i2s_tx` maps the POKEY channel-sum (0..60) into 24-bit
LPCM by left-shifting. Adding two 24-bit signed ADC inputs can
overflow the sum at peak amplitude.

**Locked: soft saturation** (clamp to ±max on overflow), not
pre-attenuation of the ADC channels. Reasoning:

- The cart and PBI AUDIO_IN paths are **rarely active**. Most
  carts don't drive AUDIO_IN at all; PBI devices that emit audio
  are even rarer. The case "both active simultaneously and both
  loud" is essentially never in practice.
- Pre-attenuating the ADC channels (right-shift by 1-2 bits)
  would silently throw away dynamic range on the *common* case
  where only one of the ADC channels is active (or neither), to
  protect a corner case that doesn't happen.
- Soft saturation matches real-Atari analog-stage behaviour
  (POKEY's analog DAC saturates — see "Analog audio fidelity
  (Altirra Appendix E)" above). The "Atari sound" already
  includes mild saturation at high mix levels.

Implementation: after the 4-input sum (POKEY_L + adc_l + adc_r
on the L side, and the matching sum on the R side), clamp to
the 24-bit signed range. A 26-bit intermediate sum + a clamp on
the top bits is enough — synth costs +2 LUTs per output side over
straight-add behaviour.

#### Second POKEY serial port — peri-RP path

The second POKEY (`u_pokey_r` at $D21x) is byte-level in HDL —
identical interface to the first POKEY. The first POKEY's SIO is
bit-serialised on the **peri-RP firmware side** via peri_link
byte transfers. The second POKEY's RS-232 should follow the same
pattern.

PCB reservations:
- **2 peri-RP pads** routed to a future RS-232 connector
  (TXD + RXD). Peri-RP has 9 spare GPIOs.
- **MAX232 / SP3232 footprint** for level translation between
  peri-RP's 3.3 V and DB9's ±12 V. Or a 3.3 V pin header
  (USB-serial-adapter-compatible).

HDL/firmware work (M-serial milestone, future):
- Extend `peri_bridge.sv` with a second serial channel (pokey_r
  bytes carried over peri_link).
- Peri-RP firmware: software UART (PIO or bit-banged) that
  serialises pokey_r byte payloads to RS-232 frames and reverse.

No FPGA-pad change today.


