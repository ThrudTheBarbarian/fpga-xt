# Issue #0006 — HDMI "no signal" / monitor wakes but won't sync

- **Component:** Video clocking (MMCM reference) + SiI9022A TPI init (`fpga_xt_top`,
  `gen_ps_bd.tcl`, `xtos` SiI9022 driver)
- **Severity:** High (no display output on real hardware)
- **Status:** Fixed (2026-05-30 — confirmed on hardware: 1080p60 colour-bar test
  pattern displays on an HDMI monitor)
- **Found:** 2026-05-30 (on-hardware, after [[0003]] got PS↔PL GP0 working)
- **Files:**
  - `vivado/bd/gen_ps_bd.tcl` — export PS `FCLK_CLK1` @ 50 MHz
  - `hdl/fpga_xt_top.sv` — both MMCMs fed from `FCLK_CLK1`, not the `clk_50` pin
  - `vivado/constraints/sally_synth_probe.xdc` — `clk_50` constraint = 12 MHz (real)
  - `vitis/xtos/src/main.c` — `sii_enable_output()`: HDMI mode + AVI InfoFrame

---

## Summary

With the board booting and GP0 AXI working, there was **no picture on HDMI**. The
symptom changed in two distinct stages as the two independent root causes were
fixed: first the monitor saw nothing at all ("no signal"), then — after the clock
fix — it *woke up* (detected a TMDS clock) but **could not lock the raster** and
went back to sleep. Both had to be fixed to get a stable picture.

Crucially, every SiI9022 *register* read back perfectly the whole time (device ID
`0xB0`, video-mode regs, `H_RES=2200`, `V_RES=1125`, TCLK stable), which is exactly
why this was hard to diagnose: those values are all **clock-count ratios** and are
blind to the absolute pixel-clock frequency.

## Root cause 1 — the PL reference clock is 12 MHz, not 50 MHz

The design assumed a 50 MHz oscillator on the `clk_50` pin (U14) and configured both
`MMCME2_BASE` blocks with `CLKIN1_PERIOD = 20.000` (`×23.75/8 = 148.4375 MHz` for
`clk_pix`, `×24/...` for `clk_sys`/`clk_sally`). **There is no 50 MHz oscillator on
this board** — the schematic (sheet 10) shows the PL clock pin is driven by a **12
MHz crystal (X2)**; the only other crystals are the 33.33 MHz PS clock and a 24 MHz
USB clock.

So every derived clock ran at `12/50 ≈ 1/4` of its intended frequency:
`clk_pix ≈ 37 MHz` (far below the 1080p60 TMDS range → monitor reports "no signal"),
`clk_sys ≈ 37 MHz`, `clk_sally ≈ 30 MHz`. Vivado never flagged it because static
timing trusts the *declared* `CLKIN1_PERIOD` — the design closed timing for
148.4/150/120 MHz and simply ran 4× slow on silicon.

Diagnosed by a `vbeam` frame counter exposed in the GP0 diag word
(`0x43C0001C [31:24]`): it advanced ~15 frames/sec, not 60. `sleep(1)` was confirmed
accurate (the PS heartbeat LED toggled at 1 Hz), so 15 fps × (2200 × 1125) ≈ 37 MHz
pixel clock — exactly `148.4375 / 4`.

## Root cause 2 — bare DVI with no AVI InfoFrame

Once the clock was corrected the monitor woke (TMDS clock now in range) but would not
sync. The chip was being driven as **DVI** (`0x1A` bit0 = 0) with no AVI InfoFrame.
A modern HDMI sink needs **HDMI mode + a valid AVI InfoFrame** to identify the format
and lock — the SiI9022A TPI reference's hot-plug Step 4 states it explicitly ("for an
HDMI sink, write the AVI InfoFrame registers; for a DVI sink these must be cleared"),
and the `sii902x` Linux driver (which drives this exact monitor on the MyIR reference
image) does exactly this for an HDMI sink.

## Resolution

**Clock (root cause 1):** clock both MMCMs from a PS **FCLK_CLK1 = exact 50 MHz**
(derived from the accurate 33.33 MHz PS crystal, delivered into the fabric — no pin),
instead of the 12 MHz `clk_50` pin. `gen_ps_bd.tcl` enables/buffers/exports it
(`PCW_EN_CLK1_PORT=1`, `PCW_FCLK_CLK1_BUF=TRUE`, `PCW_FPGA1_PERIPHERAL_FREQMHZ=50`,
`make_bd_pins_external`); `fpga_xt_top.sv` wires `ps_bd.FCLK_CLK1_0 → fclk_50 → both
MMCM .CLKIN1`. The `×23.75/8` multiplier (unchanged) now yields a true 148.4375 MHz
`clk_pix` (post-route timing confirms 6.737 ns, sourced from `PS7_i/FCLKCLK[1]`). The
`clk_50` pin now drives only the heartbeat LED; its `create_clock` was corrected to
83.333 ns (12 MHz). This also restored SALLY to its true 120 MHz — it had been
clock-starved at ~30 MHz, and already met timing at 120.

**SiI9022 (root cause 2):** `sii_enable_output()` now drives **HDMI mode** (`0x1A`
bit0 = 1) and writes a valid **1080p60 RGB AVI InfoFrame** (`0x0C–0x19`, VIC=16, 16:9,
runtime two's-complement checksum); writing `0x19` commits it; TMDS is enabled last
(`0x1A = 0x01`). The full working init order (all in D0, on HPD-high) is: HW reset
pulse → `0xC7=00` (enter TPI) → poll `0x1B`==0xB0 → `0x1A=11` (HDMI, TMDS off) →
`0x1E=00` (D0 — video regs only latch in D0) → video mode `0x00-0x07` → `0x08/09/0A`
(RGB) → AVI InfoFrame `0x0C-0x19` → `0x60=00` (external sync, **must** follow `0x19`)
→ `0x63=00` (DE generator OFF — we drive an external `DE_IN` from `vbeam`; the
generator is only for sources lacking DE) → source termination → `0x1A=01` (HDMI,
TMDS ON).

**Confirmed on hardware:** the colour-bar test pattern (`TEST_PATTERN=1`,
White/Yellow/Cyan/Green/Magenta/Red/Blue + a half-width black bar where 1920 px / 256
leaves 7.5 bars) displays stably at 1080p60.

## Notes / follow-ups

- A residual **−28 ps `clk_sally` setup miss** appeared after the clock fix (placer
  variance on a `sally_mem` page-cache path). Benign — it only matters now that SALLY
  actually runs at 120 MHz; close it with an impl re-run if it ever misbehaves.
- The SiI9022 cannot be `i2cdump`-ed from the MyIR Linux image — the `sii902x` kernel
  driver owns the I2C device (reads fail / show `UU`).
- DE diagnostics added to `xtos`: `H_RES`/`V_RES` (RO, expect 2200/1125 — read
  `V_RES` after a frame settles, a fresh read mid-frame gives a partial count) and the
  TCLK-stable interrupt (`0x72[1]`).
