# Hardware bring-up checklist

Plan of attack for the first power-on of the MyIR Z-Turn Z7-Lite SOM
(xc7z020-2clg400, 1 GB DDR3L, on-SOM SiI9022A HDMI transmitter).
Each phase has a success criterion and the most likely failure mode
so we don't burn an afternoon debugging the wrong layer.

## Loading mechanism — JTAG first, SD second

Three options for getting the bitstream + PS app onto the board:

| Path  | Iteration speed | Self-contained boot | When to use                         |
|-------|-----------------|---------------------|-------------------------------------|
| JTAG  | seconds         | no                  | bring-up, day-to-day dev            |
| SD    | minutes         | yes (FSBL + BOOT.BIN) | demo runs, regression               |
| QSPI  | minutes         | yes (production)    | not needed until ship-time          |

**Plan**: JTAG for the entire bring-up sweep below.  Switch to SD
once the system runs end-to-end so demos work without a host
attached.  QSPI is a future-work item.

JTAG drives via `xsct` (Xilinx Software Command-line Tool) over the
on-board FTDI bridge — Z-Turn exposes both the USB-UART console and
the JTAG channel on the same micro-USB.  `program_flash -bit … -url
tcp:host:port` from a remote machine works too if the host runs
`hw_server`.

## Prerequisites — to do BEFORE hardware lands

Single source of truth for everything we'd be missing on day-one
if we waited.  Grouped by what kind of work it is.

### RTL adds (FPGA side)

Small, cheap to do now, expensive to add when we're elbows-deep in
debug.

- [ ] **PLL lock → debug LED.**  Bring `pll_pix_locked` (and ideally
      all PLL locked signals) out to one of `dbg[0]` / `dbg[1]`.
      Phase 1 diagnostic — without this, "no signal" can mean PLL
      didn't lock OR PLL locked but downstream is broken, and we
      have to scope to tell them apart.
- [ ] **Heartbeat counter → debug LED.**  A simple divider off
      `clk_50` driving the remaining `dbg[]` at ~1 Hz.  Phase 1
      signal-of-life that proves the bitstream loaded and the
      oscillator is feeding the PL.
- [ ] **Test-pattern mux on fb_scanout.**  A build-time parameter
      (`SCANOUT_TEST_PATTERN`) that bypasses the AXI HP fill and
      drives a deterministic gradient / colour-bar split instead.
      Phase 2 needs this — proving HDMI without depending on
      blitter + DDR3 first.
- [ ] **Optional: ROM-init via AXI-Lite registers.**  An AXI-Lite
      slave window into `sally_mem`'s `rom_addr` / `rom_data` /
      `rom_we` ports so the PS can load a tiny 6502 ROM at boot
      without an SD card or QSPI flash for the OS image.  Phase 7
      needs *something* — this is the simplest path.

### PS-side software (Vitis)

- [ ] **Vitis platform** built off the v0.29 `post_synth.dcp` (or
      whatever is current at bring-up time).  Standard flow:
      `xsa` export from Vivado → `platform create` in Vitis →
      generate BSP.  Z-Turn's PS DDR3 preset is shipped by MyIR;
      use it verbatim, don't hand-edit timings.
- [ ] **FSBL** — generated from the platform, no custom code
      beyond default PS init.  Lives in `vitis/fsbl/`.  **Current
      status (2026-05-16):** Vitis 2025.x's auto FSBL BSP creation
      hits "Cannot find source file: ps7_init.c" even though
      `vivado/build.tcl` now injects `ps7_init.*` into the XSA
      root.  Deferred — see `vitis/scripts/create_platform.py`
      for the inheritance trail of things tried.  JTAG iteration
      (Phase 0-7 of this doc) doesn't need an FSBL.
- [ ] **Bare-metal "blink + UART hello" app.**  Lives in
      `vitis/app_blink/`.  Minimum viable: configures the UART,
      prints "fpga-xt boot OK", strobes a GPIO pin connected to
      one of the SOM LEDs once a second.  Promotes to FreeRTOS
      later — not day 1.
- [ ] **AXI poke helper.**  Tiny C library in
      `vitis/lib_xtblit/` with `xt_blit_write(reg, val)` and
      `xt_blit_read(reg)` wrappers.  Phase 4 needs this; better
      to write it once and reuse than to inline `Xil_Out32` calls
      in each test.

### Build / load tooling

- [ ] **`vivado/scripts/jtag_load.tcl`** — one-shot xsct flow:
      `connect; fpga -file build/fpga_xt_top.bit; targets -set
      -filter {name =~ "ARM*#0"}; dow vitis/app_blink/app.elf;
      con`.  Reduces "load new build" to one command.
- [ ] **`Makefile` rule for boot.bin** — wraps FSBL + bitstream
      + app via `bootgen -arch zynq -image bif`.  Used for SD-boot
      once JTAG bring-up is done.
- [ ] **CI smoke step** that runs the iverilog `tb_sally_isa`
      suite per commit.  Already works locally via `make -C sim`;
      just needs a GH Actions runner or similar.  Defer if no CI
      pressure yet.

### Physical / desk setup

- [ ] **A 1080p HDMI monitor** with a long-enough cable to sit
      next to the dev box.  EDID matters — older monitors that
      report only 720p over their EDID will make the SiI9022A
      pick a different timing.  Test with a known-good display
      first.
- [ ] **USB-UART terminal** ready (115200 8N1).  Z-Turn's
      USB-micro is dual JTAG + UART via FTDI; one cable carries
      both.  Pick a terminal program that survives connect/
      disconnect cleanly (picocom, screen, putty).
- [ ] **microSD card** formatted FAT32, ≥ 1 GB.  Empty for now;
      gets populated when SD-boot becomes relevant (Phase 3+).
- [ ] **A scope or LA**, even a cheap one (DSLogic / Saleae /
      Hantek).  Phase 1 / 2 / 6 diagnostics call for probing
      `rgb_pixclk` (148.4 MHz), `rgb_hsync` / `rgb_vsync`
      polarity, and HSYNC-to-DE timing.  Without one, "HDMI
      doesn't work" is unsearchable.
- [ ] **A second host** running `hw_server` if the dev box is
      remote from the bench.  Otherwise the JTAG over USB is
      whatever machine the SOM is plugged into.

## Phase 0 — power-on smoke test

Power up the Z-Turn standalone (no PL bitstream loaded, factory
boot in QSPI if there is one — otherwise just confirm the PMICs
come up).

**Pass**: Z-Turn power LEDs on, no smoke, no smell, current draw
sane (~300–500 mA at 5 V from the PMIC monitor or external supply).

**Likely fail**: bad supply, reversed barrel-jack polarity, dead
SOM.  Diagnostic: meter the 3.3 V and 1.8 V rails on a header pin.

## Phase 1 — PL standalone (clocks + LEDs)

Load just the bitstream over JTAG — no PS app, no FSBL.  Vivado's
hardware manager → "Program Device" picks up the FTDI channel.
The PL clock domains start running from the on-board 50 MHz
oscillator via our PLL.

**Pass**: heartbeat LED blinks at ~1 Hz (see RTL-adds prereqs:
heartbeat counter on `dbg[]`).  PLL-lock LED solid on (also a
prereq).  Scope on `rgb_pixclk` (PL pin R17) reads 148.4 MHz ±
100 ppm.

**Likely fail**:
- Heartbeat LED dark → bitstream didn't load, or `clk_50` not
  reaching the PL.  Re-flash via JTAG; if no improvement, scope
  the 50 MHz oscillator output.
- Heartbeat LED on but PLL-lock LED dark → PLL config wrong or
  unstable.  Check the `pll_pix.sv` config matches CEA-861 1080p60
  (148.5 MHz from 50 MHz input means M/D ratio 99/(N×D); pick
  appropriate Xilinx MMCM/PLL parameters).
- Both LEDs healthy but `rgb_pixclk` not toggling → PLL output
  not reaching the IOB.  Check the clock route in the implementation
  log.
- IOSTANDARD mismatch on `clk_50` (U14) — Vivado would have
  errored at write_bitstream, but worth checking the implementation
  log.

## Phase 2 — HDMI test pattern

Goal: prove the PL → SiI9022A → HDMI signal chain by displaying a
**static, deterministic test pattern** generated entirely in the PL
(no PS-side help yet, no DDR3 read).

Approach: build with `SCANOUT_TEST_PATTERN=1` (RTL-adds prereq).
That bypasses `fb_scanout`'s AXI HP fill and drives a deterministic
gradient / colour-bar split instead, on the same RGB565 + DE +
HSYNC + VSYNC pins.  Avoids depending on the blitter or DDR3 for
the first HDMI test.

The SiI9022A still needs I²C init to come out of reset and accept
the input.  Either:
- **Boot ROM hands the I²C init**: pre-program the SiI9022A
  config sequence into the FSBL.  Requires Phase 3 first.
- **Skip the init**: rely on the SiI9022A's reset defaults to
  pass-through a known input format.  Some Sil9022A revs do this;
  others sit silent until programmed.  Read the datasheet section
  on "Reset / power-on state".

**Pass**: HDMI monitor shows the test pattern, locked at 1920×1080
60 Hz.  Pattern is stable (no flicker, no roll, no tearing).

**Likely fail**:
- Monitor reports "no signal" — pixel clock wrong, HSYNC/VSYNC
  polarity wrong, or the SiI9022A is unconfigured.  Probe DE on
  R16 to confirm timing matches 1080p60 (148.5 MHz pix clock,
  active 1920 × 1080 within 2200 × 1125 total).
- Monitor reports the wrong resolution — check the InfoFrame /
  AVI packet config in the SiI9022A.  Until we send InfoFrames
  the sink does TMDS-clock-period geometry detection; should
  still report 1080p60.
- Colours wrong — RGB565 bit order mismatch.  The mapping in
  `vivado/constraints/zturn_board.xdc` puts LCD_DATA[15:11] →
  rgb_r[4:0], [10:5] → rgb_g[5:0], [4:0] → rgb_b[4:0].  Confirm
  `fb_scanout`'s `o_rgb_r/g/b` widths match.

## Phase 3 — PS boots, talks to UART

Switch from "PL bitstream only" to "PS + bitstream" via the FSBL.
JTAG flow: `xsct` connects, downloads FSBL to OCM, FSBL runs DDR3
calibration, then downloads the app `.elf` and the bitstream.

**Pass**:
- DDR3 calibration succeeds (FSBL stdout reports `MIO is up` and
  `DDR is up`).
- App `printf("hello\n")` reaches the UART console.

**Likely fail**:
- DDR3 calibration error — wrong PS DDR config in the BD.  Re-check
  against the MyIR Vitis BSP defaults; Z-Turn ships with a known-good
  preset (use it verbatim, don't hand-edit timings).
- Bitstream not loaded → FSBL falls back to "PS only" boot and PL
  is unconfigured.  Symptoms: app runs but `dbg` LEDs are dark.
  Diagnostic: FSBL stdout reports the bitstream load explicitly;
  if it doesn't appear, check the `boot.bin` partition ordering.

## Phase 4 — PS↔PL AXI register access

App pokes a few xt_blitter registers over AXI-Lite (e.g.,
`STATUS` read, `CMD_QUEUE_BASE` write/read-back).  No actual
drawing yet — just proving the AXI clock-crossing and address
decode work.

**Pass**: write a known value to a R/W register, read it back, get
the same value.  Repeat for several addresses to rule out
single-bit fluke.

**Likely fail**:
- AXI hang on first write — AR/AW handshake never completes.
  Common cause: clk_sys not running (PLL didn't lock) or
  AXI-Lite slave's `aclk` mis-wired.  AXI hangs show as Vitis
  debugger sitting forever in the store instruction.
- Read returns zero or garbage — address decode wrong, or the
  slave register isn't actually R/W (some are reserved /
  side-effect-on-read).  Try a different register.

## Phase 5 — Blitter smoke test

Goal: prove the blitter writes to DDR3 framebuffer correctly.
Smallest test that exercises everything: a single SOLID FILL
command issued via the command-queue ring.

App sequence:
1. Set `BLIT_CMD_BASE` to a 1 KB region in DDR3.
2. Write one command word (opcode = FILL, target = framebuffer A
   at `0x3000_0000`, rect = 100×100 at (10, 10), colour = $FF0000).
3. Increment the producer pointer, ring the doorbell.
4. Poll `STATUS.busy` until clear.
5. Read back a few framebuffer pixels via PS → DDR3 to confirm
   the colour landed at the right address.

**Pass**: framebuffer at the expected addresses contains the fill
colour; surrounding pixels untouched.  No AXI errors logged.

**Likely fail**:
- AXI master timeout — blitter's HP port unwired or clock
  mismatch.  Check `m_axi_aclk` connection in the BD.
- Stride wrong — fill renders at the wrong pitch (visible later
  in Phase 6 as a smeared rectangle).  Re-check the row stride
  config (8192 B, not 7680).
- Bytes swapped — endianness mismatch on the AXI HP burst.
  Zynq AXI HP is little-endian by default; the blitter's
  `m_axi_wdata` should pack low bytes at low addresses.

## Phase 6 — fb_scanout reads DDR3, drives HDMI

Wire `fb_scanout` back to its real input (line-buffer fill from
AXI HP read of the framebuffer base address).  Now the HDMI
output should reflect whatever the blitter has written to DDR3.

**Pass**: the rectangle the blitter drew in Phase 5 is visible on
the HDMI monitor, at the expected screen position, the expected
size, and the expected colour.

**Likely fail**:
- Black screen — `fb_scanout`'s AXI HP read isn't completing in
  time.  Probe its line-buffer fill state machine; check the
  burst arrived before the line started reading from the
  off-buffer.
- Wrong colours — RGBA-8888 → RGB565 truncation wrong.  Should
  drop alpha + take MSBs of R/G/B (5/6/5).  Off-by-one in the
  bit positions shows as a colour cast.
- Tearing — line-buffer ping-pong handoff not aligned with
  HSYNC.  Should be safe because both ends are on `clk_pix` and
  the swap happens at HSYNC, but worth eyeballing.

## Phase 7 — SALLY runs against the bitstream

Load a tiny 6502 ROM into `sally_mem` via the PS (via the
ROM-init AXI-Lite window — RTL-adds prereq).  ROM: a 16-byte
program that writes `$AA` to some hwreg, loops on a JMP.

**Pass**: hwreg read from PS shows `$AA`.  SALLY is running.

**Likely fail**:
- CPU stuck in reset — `rst` polarity wrong on the SOM (we use
  `rst_n` from SW[0] which is active-low; sally_core wants
  active-high `rst`).  The top-level invert should handle this
  but double-check the polarity reaches sally_core correctly.
- CPU running but at wrong PC — reset vector at `$FFFC/$FFFD`
  uninitialised.  ROM-load must include those bytes.

## Phase 8 — full system

ANTIC pulls display-list bytes from sally_mem (snoop mode);
compositor builds scanlines; fb_scanout drives HDMI; SALLY runs
a small Atari demo.  Audio out is a separate sub-track on POKEY
→ I²S → HDMI audio islands.

By this phase the rest of the work is software, not bring-up.
See [docs/roadmap.md](roadmap.md) for what comes next.

## Carrier-board work (deferred)

This checklist is **SOM-only**.  The custom carrier (cart slot,
SIO, joysticks, PBI, expansion, audio in) is its own bring-up
sweep, gated on the basic Zynq + HDMI loop above being solid.
That document doesn't exist yet — when the carrier schematic
lands, add a `bring-up-carrier.md` alongside.
