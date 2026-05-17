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

- [x] **PLL lock + heartbeat → debug LEDs** — `dbg[0]` =
      heartbeat from a `clk_50` divider, `dbg[1]` = combined PLL
      lock from `mmcm1` + `mmcm2`, `dbg[2]` = `bl_busy`.  Drives
      Phase 1 diagnostics.  Committed in 844e155.
- [x] **Test-pattern mux on fb_scanout** — `SCANOUT_TEST_PATTERN`
      build parameter bypasses the AXI HP fill and drives a
      deterministic gradient instead.  Phase 2 leverage.
      Committed in 844e155.
- [x] **ROM-init via AXI-Lite (`sally_rom_loader`)** — AXI-Lite
      slave window into `sally_mem`'s `rom_addr` / `rom_data` /
      `rom_we` ports so the PS can load a tiny 6502 ROM at boot
      without SD or QSPI.  Phase 7 prereq.  Committed in a4ca8c3.

### PS-side software (Vitis)

- [x] **Vitis platform** built from `vivado/build/fpga_xt_top.xsa`
      via `vitis/scripts/create_platform.py`.  Wraps the
      Vitis Unified Python API and adds `xilffs` + `xilrsa` to
      the standalone BSP so the FSBL build works.
- [x] **FSBL** — generated via the same `create_platform.py`
      using the empty-application + manual-source-import
      workaround (Vitis 2025.2.1's auto-FSBL path doesn't
      populate the source dir on its own).  Lives in
      `vitis/workspace/fsbl/build/fsbl.elf` (~85 KB).  Set
      `VITIS_NO_FSBL=1` to skip when iterating on the app only.
- [x] **Bare-metal UART hello — `vitis/app_blink/src/main.c`.**
      Prints `fpga-xt boot OK`, smoke-tests the GP0 → blitter
      bridge via `xt_blitter_status()`, then loops with a
      1-second `tick N` heartbeat.  GPIO LED toggling waits on
      Z-Turn MIO mapping confirmation.
- [x] **AXI poke helper — `vitis/app_blink/src/xt_blitter.{h,c}`.**
      Symbolic register offsets + command opcodes + GEM raster
      ops, plus convenience wrappers (`xt_blitter_status`,
      `xt_blitter_wait_idle`, `xt_blitter_set_dst`,
      `xt_blitter_fire`, etc.).  Targets the AXI-Lite bridge at
      `0x43C0_0000`.

### Build / load tooling

- [x] **`vivado/run-win10.sh` + `vitis/run-win10.sh`** — Mac-side
      scp + PowerShell-over-SSH wrappers driving the win10 Vivado
      and Vitis builds.  Match the run.sh patterns for the ubuntu
      box but use scp (no rsync on win10) and PowerShell instead
      of bash + settings64.sh.
- [x] **`vivado/scripts/jtag_load.tcl`** — one-shot xsct flow.
      Reduces "load new build" to one command — see [Running
      jtag_load.tcl](#running-jtag_loadtcl) below for usage.
- [x] **`vitis/scripts/build_boot_bin.sh`** — wraps FSBL +
      bitstream + app via `bootgen -arch zynq`.  Used for SD-boot
      once JTAG bring-up is done — see [Building BOOT.BIN](#building-bootbin)
      below for usage.
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

## Running jtag_load.tcl

Every Phase 3+ step uses the same xsct sequence: connect to
`hw_server`, load the bitstream, init the PS via `ps7_init.tcl`,
download an ELF, run.  `vivado/scripts/jtag_load.tcl` packages
that.  Works with any cable Vivado's `hw_server` recognises —
Digilent JTAG-HS3 in particular needs nothing beyond the standard
driver install.

### Quick start (defaults — newest local build):

```
xsct vivado/scripts/jtag_load.tcl
```

Defaults to `vivado/build/fpga_xt_top.bit` +
`vitis/workspace/app_blink/build/app_blink.elf` +
`hw_server` on `127.0.0.1:3121`.

### Positional args:

```
xsct vivado/scripts/jtag_load.tcl <bit> <elf>          # custom paths
xsct vivado/scripts/jtag_load.tcl <bit> <elf> <host>   # remote hw_server
```

`<host>` is an xsct URL — `TCP:host:port` for a remote `hw_server`
(useful when the JTAG cable lives on a different machine than the
dev box).  Start the remote side with `hw_server -d` first.

### Env-var overrides (lower priority than positional args):

| Var            | Default                                          |
|----------------|--------------------------------------------------|
| `BITSTREAM`    | `vivado/build/fpga_xt_top.bit`                   |
| `ELF`          | `vitis/workspace/app_blink/build/app_blink.elf`  |
| `HW_SERVER`    | `TCP:127.0.0.1:3121`                             |
| `PS7_INIT_TCL` | auto-discovered relative to the bitstream's dir  |
| `JTAG_DRY_RUN` | unset (set `=1` to skip the connect step)        |

`PS7_INIT_TCL` is auto-resolved by walking up from the bitstream
to find the BD's `ps7_init.tcl` — works on both the Mac-side
`vivado/bd/...` layout and the flatter win10 layout `run-win10.sh`
produces.  Override directly when neither applies.

`JTAG_DRY_RUN=1` resolves and prints all paths and exits before
touching JTAG.  Handy as a pre-flight check that no file paths
have drifted.

## Building BOOT.BIN

Once JTAG bring-up is solid, SD-boot is the next step.
`vitis/scripts/build_boot_bin.sh` wraps `bootgen` — it generates
a BIF that lists `fsbl.elf` + `fpga_xt_top.bit` + `app_blink.elf`
in the right order for Zynq-7000, runs `bootgen` on win10 (where
the tool and the artefacts live), and pulls the resulting
4 MB BOOT.BIN back.

### Usage:

```
./vitis/scripts/build_boot_bin.sh                  # default output
./vitis/scripts/build_boot_bin.sh path/to/out.bin  # custom output path
```

### Prerequisites:

The script just packages — it doesn't build anything.  Before
running it:

1. `vivado/run-win10.sh bit` — produces the bitstream on win10
2. `ssh win10` + `cd vitis && vitis -s scripts/create_platform.py` —
   produces fsbl.elf and app_blink.elf on win10

### Env-var overrides:

| Var          | Default                                                    |
|--------------|------------------------------------------------------------|
| `REMOTE`     | `win10`                                                    |
| `REMOTE_DIR` | `C:/Users/simon/fpga`                                      |
| `BOOTGEN`    | `C:\Xilinx\2025.2.1\Vitis\bin\bootgen.bat`                 |
| `FSBL`       | `$REMOTE_DIR/vitis/workspace/fsbl/build/fsbl.elf`          |
| `BIT`        | `$REMOTE_DIR/build/fpga_xt_top.bit`                        |
| `APP`        | `$REMOTE_DIR/vitis/workspace/app_blink/build/app_blink.elf`|

### Using the output:

- **SD boot**: copy BOOT.BIN to the root of a FAT32-formatted
  microSD, set the Z-Turn's boot-mode jumpers to SD, power-cycle.
  FSBL initialises the PS, loads the bitstream, and starts
  `app_blink`.
- **JTAG-load BOOT.BIN** (for testing without the SD card):
  `xsct` + `dow BOOT.BIN`, run from the FSBL load address.  Use
  this to validate the BOOT.BIN against the same hardware that
  the JTAG iteration path runs against.
- **QSPI flash**: `program_flash -f BOOT.BIN -fsbl fsbl.elf
  -flash_type qspi_single` via xsct — only needed for
  production-style boot with no SD card.

### Expected output (good case):

```
fpga-xt boot OK
build: <date> <time>
blitter @0x43c00000: status=0x00 seq=0
tick 0
tick 1
...
```

### Common failure modes:

- **`Cannot connect to hw_server`** — `hw_server` isn't running.
  Start it with `hw_server -d` on the machine the cable is on, or
  let Vivado start one for you if the cable is on the same box.
- **`No targets after `targets -set -filter ...``** — cable not
  detected, or no power to the SOM, or the device's IDCODE doesn't
  match the filter.  Sanity-check with bare `targets` (no filter).
- **`status=0xff seq=ffff`** in the UART output — AXI bridge isn't
  responding; reads are returning all-ones (bus default).  GP0
  clock not running, PS isn't out of reset, or `axi_blitter_bridge`
  isn't being clocked.  Probe `clk_sys` on the dbg pins.
- **`status=0x02` at boot** — queue already full before any CMD
  was written.  Probably a stuck strobe from the SALLY CDC path
  (`bl_we_mux` glitching).

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

Switch from "PL bitstream only" to "PS + bitstream" via JTAG.
`vivado/scripts/jtag_load.tcl` runs the whole sequence (see
[Running jtag_load.tcl](#running-jtag_loadtcl) for usage) — it
loads the bitstream, sources `ps7_init.tcl` to bring up DDR3 /
clocks / MIO, downloads `app_blink.elf`, and runs.  No FSBL on
this path — FSBL is for SD/QSPI standalone boot.

**Pass** — UART console (115200 8N1) prints the app's boot
banner within ~2 seconds of `con`:

```
fpga-xt boot OK
build: <date> <time>
blitter @0x43c00000: status=0x00 seq=0
tick 0
tick 1
...
```

**Likely fail**:
- DDR3 calibration silently broken — ps7_init.tcl finishes but
  the heap / .bss region in DDR3 is uninitialised.  Visible as
  the app crashing in early init.  Re-check the PS DDR config in
  the BD against MyIR's Z-Turn preset; their preset is shipped
  known-good, don't hand-edit timings.
- No banner — UART pinmux / baud wrong, or the app is stuck
  before xil_printf.  Probe TX with a scope; if it's dead, the
  PS MIO config for UART1 is wrong (Z-Turn maps the on-SOM FTDI
  UART to MIO 48/49 by default).
- Banner reaches "fpga-xt boot OK" but no tick lines — `sleep(1)`
  hung.  Usually means the global timer (xtimer) isn't ticking;
  the standalone BSP relies on the PS timer being initialised by
  ps7_init.  Re-run jtag_load.tcl; if it persists, the PS timer
  config in the BD is wrong.

## Phase 4 — PS↔PL AXI register access

`app_blink` already does this at boot — the
`blitter @0x43c00000: status=0x?? seq=??` line proves the PS →
GP0 → AXI-Lite-bridge → blitter-register-bus path is live.

**Pass**: that line reads `status=0x00 seq=0` — clean idle state.

**Likely fail** — what each non-idle reading means:
- `status=0xff seq=ffff` — AXI bridge is silent and the bus is
  reading back its all-ones default.  Either `clk_sys` isn't
  running (PLL didn't lock — check `dbg[1]`), `axi_blitter_bridge`
  isn't being clocked (no `s_axi_gp0_aclk` from the PS BD), or
  the GP0 mapping is wrong (BD address allocator put us elsewhere).
- `status=0x02` — queue is reported full before any CMD was
  written.  Usually a stuck strobe from the SALLY CDC path
  (`bl_we_mux` glitching).  Triage by re-running with the PS
  app stripped down to just the read — if it persists, the bug
  is in the PL.
- `status=0x04` — sticky `pat_blocked` set, meaning a pat/font
  write got dropped while the blitter was already busy.  At boot
  the blitter is idle so this shouldn't fire.  If it does, check
  for spurious writes during PL reset deassertion.

To extend coverage, edit `app_blink/src/main.c` to also pump a
few register writes through `xt_blitter_write8()` and read the
SEQ counter to confirm CMD-issue → seq-bump works.  Side-effect
registers (`PAT_DATA`, `FONT_DATA`) auto-advance internal
pointers so they can't simply be written and read back; use
`SEQ_LO`/`SEQ_HI` as the proxy for "did the blitter see my CMD".

## Phase 5 — Blitter smoke test

Goal: prove the blitter writes to DDR3 framebuffer correctly.
Smallest test that exercises everything: a single rect fill.

PS-side sequence (use the driver helpers in `xt_blitter.h`):

1. Wait for idle: `xt_blitter_wait_idle(1000)`.
2. Set up a fully-opaque pattern.  For a 1×1 white pattern:
   `xt_blitter_set_pat_log(0, 0)`,
   `xt_blitter_write_pat({0xFF,0xFF,0xFF,0xFF}, 4)` — RGBA.
3. Set the destination rect:
   `xt_blitter_set_dst(10, 10, 100, 100)`.
4. Fire the command: `xt_blitter_fire(XT_BL_CMD_RECT_FILL)`.
5. Poll `xt_blitter_busy()` until cleared, or wait via
   `xt_blitter_wait_idle()`.
6. Read back a few framebuffer pixels through PS → DDR3 at
   `FB_BASE = 0x3000_0000`, stride 8192 bytes per row (so pixel
   `(x, y)` lives at `FB_BASE + y * 8192 + x * 4` for RGBA-8888).

**Pass**: the 100×100 region at (10, 10) reads back as the
pattern; surrounding pixels untouched.  No AXI errors logged.

**Likely fail**:
- AXI master timeout / queue stays full — blitter's HP1 port
  unwired or clock mismatch.  Check `m_axi_aclk` connection in
  the BD; the HP1 master is driven by `clk_sys` (150 MHz).
- Stride wrong — fill renders at the wrong pitch (visible in
  Phase 6 as a smeared rectangle).  Re-check
  `FB_STRIDE_B = 8192` matches the value the blitter was
  parameterised with.
- Bytes swapped — endianness mismatch on the AXI HP burst.
  Zynq AXI HP is little-endian by default; the blitter packs
  RGBA-8888 with R in the low byte (lane 0), A in the high
  byte (lane 3).
- `pat_blocked` sticky set — pattern bytes were written while
  the previous CMD was still busy.  Always check
  `xt_blitter_wait_idle()` before re-pumping pattern data.

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

Load a tiny 6502 ROM into `sally_mem` via `sally_rom_loader`'s
AXI-Lite window (allocated alongside the blitter bridge under
the GP0 mapping — see `fpga_xt_top.sv:1245-1252`).  ROM: a
~16-byte program that writes `$AA` to some hwreg and loops on
a JMP.

PS-side sequence (no driver helpers yet — use `Xil_Out32`):

1. Pulse `sally_rst` from the PS (via the dedicated reset bit
   in the ROM-loader window).
2. Stream the program bytes through the `rom_addr` / `rom_data`
   / `rom_we` ports.  The loader auto-increments `rom_addr` on
   each `rom_we` pulse so software writes a flat byte stream.
3. Include `$FFFC/$FFFD` = reset vector pointing at the program's
   start address.
4. De-assert the rom-load gate, release `sally_rst`.

**Pass**: hwreg read from PS (via the blitter bridge or via
ANTIC's snoop) shows `$AA`.  SALLY is running.

**Likely fail**:
- CPU stuck in reset — `rst` polarity wrong.  `sally_core` wants
  active-high; the wiring through `sally_clock` should invert
  the SOM-side active-low.  Probe the actual signal at
  `sally_core.rst`.
- CPU running but at wrong PC — reset vector at `$FFFC/$FFFD`
  uninitialised.  ROM-load sequence must include those two bytes
  before releasing reset.
- `sally_rom_loader` not in the GP0 mapping — check the OR-mux
  at `fpga_xt_top.sv:1264-1273` is routing both bridge and
  loader responses back to GP0.

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
