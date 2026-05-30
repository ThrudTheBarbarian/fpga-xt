---
title: "Current state"
description: "Implementation snapshot — the SuperSally-v2 xt6502 core, the ANTIC video pipeline, full-system OS boot, timing closure, and what's left before on-hardware bring-up."
---

Snapshot date: 2026-05-27.

## Headline

`main` is **SuperSally-v2** (tag `SuperSally-v2`): the clean-sheet **xt6502**
turbo core driving the full ANTIC / GTIA / POKEY video pipeline on a single
Zynq-7020, with a 1080p60 plane compositor + 2D blitter + sprite engine on
the scan-out side. In whole-system simulation the emulated 6502 **boots the
real Atari XL OS to a rendered BASIC `READY` prompt**. Real-PS bitstream
timing is closed on all three clock domains. The only thing standing between
here and a running board is the physical Z-Turn SOM, due around the end of
May 2026.

- **CPU** — xt6502: full 6502 ISA + the xt embellishments, **~120 MHz**
  `clk_sally`, one fabric clock per emulated cycle ≈ **67× turbo** over a
  stock 1.79 MHz Atari. Passes the full Klaus functional test and the
  ISA / integration testbench suite.
- **Video** — ANTIC native phi2-paced raster + render tap → DDR3 writeback →
  plane compositor → SiI9022A. The legacy Atari image is integer-upscaled
  and pillarboxed into the fixed 1080p frame.
- **OS** — the full-system `tb_boot` sim cold-starts the real XL OS ROM,
  cross-checked against an Atari800 golden trace, and reaches the BASIC
  cartridge `READY` prompt.
- **Hardware** — bitstream timing-closed with the real PS block design;
  on-hardware bring-up is blocked only on the board arriving.

## Overall goal

See the [architecture overview](/hardware/) for the full plan. In short:
replace the earlier Efinix Ti60 + STM32N6 dual-chip design with a single
Zynq-7020 SoC on a Z-Turn SOM, targeting ~$150/board at ≤100 units.

## What exists

### Top level — `fpga_xt_top` (hdl/fpga_xt_top.sv)

xt6502 CPU + `sally_mem` + the ANTIC/GTIA/POKEY chain + the plane compositor
+ blitter + sprite engine, across three clock domains derived from a single
50 MHz reference by two MMCMs:

| Domain | Frequency | Drives |
|--------|----------:|--------|
| `clk_sally` | 120.000 MHz | xt6502, sally_mem, sally_clock |
| `clk_sys` | 150.000 MHz | antic_top, plane_fetch AXI, xt_blitter, sprite_engine, AXI HP |
| `clk_pix` | 148.4375 MHz | plane_compositor + vbeam + 8888→565 Bayer dither; RGB565 + sync to the SiI9022A (CEA-861 1080p60, −0.042 % error) |

The xt6502 core is clocked at 120 MHz from MMCM #1 (`CLKOUT0 /10`).

Reset: each domain has an async-assert / sync-deassert pipeline gated by
`rst_n & mmcm1_locked & mmcm2_locked`. `clk_sys` modules use **synchronous**
reset on purpose (fixed the earlier flaky `clk_sys` hold).

CDC: `cdc_fifo_1w1r` carries SALLY hwreg writes (`clk_sally`) → ANTIC bus
(`clk_sys`); `hwreg_rd_cdc` carries the register read round-trip back;
`cdc_sync_bit` syncs ANTIC status (NMI/IRQ/HALT) to SALLY; the compositor's
`line_start` crosses `clk_pix → clk_sys` by toggle + 2-FF + edge detect.

Subsystems:

1. **xt6502 CPU** — clean-sheet, registered-MAR 6502 core. Full documented ISA + IRQ/NMI + the xt embellishments
   (4 KB hidden stack, 12-bit SP, SP-relative addressing, PSH/PLL, BRA,
   `BIT #imm`, SP-indirect). One fabric clock per emulated cycle. Passes
   Klaus ($3469) and the `sally_isa_xt` / `sally_xt` testbenches against the
   real `sally_mem`. `clk_sally` closes at 120 MHz.
2. **`sally_mem`** — 64 KB dual-port BRAM (the second port serves ANTIC DMA
   reads) + a banked-window AXI reader for the DDR3-backed bank windows.
   `hwreg_dout` is registered locally to close `clk_sally` at 120 MHz. The
   bank-select registers live at **$D5C0 (code) / $D5C1 (data)** in the CCTL
   I/O gap and are readable (see [register map](/hardware/register-map/)).
3. **ANTIC / GTIA / POKEY** — the full chain: display-list parser, a native
   **phi2-paced raster sequencer** (`antic_raster` + `antic_seq`), the
   per-mode compositor, GTIA colour resolution + collisions, the palette
   LUT, and a render tap that writes finished rows back to DDR3. The old
   800×600 display chain has been retired.
4. **Plane-compositor scan-out** — `vbeam` (1080p60 raster) + per-plane
   `plane_fetch` (DDR3 line read + ping-pong buffer + 8888→565 Bayer dither)
   + `plane_compositor` (depth / scale / clip mixing across N planes) +
   `sprite_engine` overlay → the RGB565 pads. `legacy_upscale` provides the
   integer pillarbox for the legacy-Atari plane. (`fb_scanout` is superseded
   and no longer instantiated.)
5. **xt-blitter (v0.17)** — rect fill, line draw, block blit, NN + bilinear
   scaled blit, alpha-blend, font raster, and the 16 GEM raster ops, all on
   RGBA-8888 memory, with the $D4Bx/$D4Cx register interface and an AXI-Lite
   GP0 bridge (`axi_blitter_bridge`) for PS-side access. Closes 150 MHz with
   the full PS BD.
6. **Sprite engine** — hardware sprite compositor on the 1080p scan-out path
   (see the [sprite engine](/project/sprite-engine/) page).
7. **Peripheral I/O** — PIA shadow ($D300, real PORTA/PORTB semantics),
   `joy_bridge` (PCAL9722 SPI), `peri_bridge` (SIO + POT), the PCM1808 I²S
   ADC, and the bus-snoop for M-PBI cart/PBI mastering.
8. **OS-boot validation** — the `tb_boot` full-system testbench plus
   `tools/cosim_diff.py`, which differentially compares the emulated boot
   against an Atari800 golden trace.

## Timing

The real-PS bitstream (with the full PS block design) closes all three
domains with positive slack and 0 failing endpoints:

- **`clk_sys` 150 MHz**, **`clk_sally` 120 MHz** (xt6502), **`clk_pix`
  148.4 MHz**. Margins are thin (placer-variance), held via
  `cascade_height=1` on the 64 KB memory, the HP ports placed on `clk_sys`,
  `ExtraTimingOpt` placement, and a setup-recovery loop in `build.tcl`.
- `clk_sally` reached 120 MHz by registering `hwreg_dout` locally in
  `sally_mem` plus the xt6502 fmax levers (early `sp_eff`, the `sally_mem`
  read-mux, `PSH_CALC`, and the PSH/PLL guard byte). The CPU is no longer
  the binding path — residual variance is in the `clk_sys` / ANTIC fabric.

(Exact post-route slack should be read from the latest `build/*_timing.rpt`;
the figures above are the latest known closure on the real PS BD.)

**How the blitter reached 150 MHz** (condensed history): closing `clk_sys`
at 150 MHz with the blitter in the design took four pipeline splits — the
bilinear blend weights (`SC_BL_BLEND`), the alpha-blend dst + product
registers (`BL_RACC_BLEND`/`BL_RACC_BLEND2`), the `cx ≥ dst_w` compare
register, and the Bresenham step-flag split (`L_STEP`/`L_STEP2`) — plus a
2-deep AXI register slice at the PS HP1 boundary. Those landed across
v0.12–v0.17; the blitter is now I/O-bound, not logic-bound.

## Test status

The iverilog testbench suite (`make` under `sim/`) passes. Highlights:

| Area | Tests |
|------|-------|
| 6502 conformance | **Klaus** functional test — both SALLY (`klaus`) and xt6502 (`klaus_xt`) reach $3469 (~96M cycles) |
| xt6502 | `sally_isa_xt` (29 ISA cases), `sally_xt` (vs the real `sally_mem`), `sally_stack` |
| OS boot | `tb_boot` / `boot_xt` — cold boot of the real XL OS ROM to a rendered BASIC `READY`, golden-trace-checked against Atari800 |
| ANTIC | `antic_raster`, `antic_seq`, `antic_modes`, `antic_display`, plus `dl_parse` / `prior` / `nmi` / `wsync` / `palette` / `dma_master` |
| Blitter / display | `xt_blitter`, `plane_compositor`, `plane_fetch`, `antic_writeback`, `legacy_upscale` |
| Sprites | `sprite_regs`, `sprite_fetcher`, `sprite_compositor` |
| Memory / peripherals | `sally_mem`, `bank_xlat`, `hwreg_rd_cdc`, `pia_regs`, `pokey`, `peri_link` / `joy_link` / `joy_bridge` / `peri_bridge`, `pbi`, `pcm1808_rx` |

(Vivado XSIM is still not set up locally; the suite runs under iverilog.)

## Exit gates

| Gate | Status |
|------|--------|
| SALLY core boots from BRAM | ✅ xt6502 core; `clk_sally` 120 MHz closed. |
| 6502 ISA conformance | ✅ Klaus passes on both SALLY and xt6502 ($3469). |
| ANTIC pipeline produces video | ✅ Native phi2 raster + render tap; the compositor drives the pads. |
| Full-system OS boot | ✅ `tb_boot` boots the real XL OS to a rendered BASIC `READY` (sim), golden-trace verified. |
| HDMI output via SiI9022A | ✅ Plane compositor drives parallel RGB565 + sync at 148.4375 MHz. |
| Three independent clock domains | ✅ Two MMCMs → `clk_sally` / `clk_sys` / `clk_pix`; CDC FIFO + sync bits; async clock groups. |
| 1080p60 pixel clock | ✅ MMCM #2 at 148.4375 MHz (−0.042 % CEA-861, well inside HDMI ±0.5 %). |
| DDR3 framebuffer scan-out | ✅ `plane_fetch` + `plane_compositor` (the generalised successor to `fb_scanout`). |
| xt-blitter (full feature set) | ✅ v0.17 — fill / line / block / scaled / blend / font / GEM raster ops; closes 150 MHz with the PS BD. |
| Zynq PS block design | ✅ `gen_ps_bd.tcl` (HP0/HP1, GP0, DDR3 1 GB, FCLK 150 MHz); integrated into both OOC and bitstream builds. |
| Real-PS bitstream timing | ✅ All three domains closed, 0 failing endpoints (margins thin). |
| On-hardware DDR3 + HDMI | ⚠️ Blocked on the physical Z-Turn board. |
| Vivado XSIM regression | ⚠️ Not set up; the iverilog suite is the regression gate today. |

## Next steps

1. **On-hardware bring-up** (board due ~end May 2026): flash the bitstream
   over JTAG (JTAG-HS3 → Z-turn J1), build a minimal Vitis FSBL + FreeRTOS
   BSP on the Cortex-A9s, exercise the AXI-Lite GP0 window into the blitter
   (write CMD → poll STATUS busy at $D4BD), and bring up HDMI out.
2. **FreeRTOS + LVGL** on the PS (Phase 3): FatFs over SDIO, USB HID, the
   blitter command-ring driver, and LVGL (`LV_COLOR_DEPTH 32`, RGBA-8888)
   rendering into the DDR3 framebuffer; the compositor's 8888→565 dither
   handles the downsample at scan-out.
3. **Atari I/O integration** (Phase 4): PCM1808, cart slot, SIO, and the PBI
   bridges against real PL pins.
4. **SALLY multitasking kernel** (Phase 5): the stack embellishments and
   banked-stack context switching are designed (see
   [multitasking](/os/multitasking/)); implementation follows once the PS
   pipeline is up.

### Build commands

```bash
# OOC fmax probe (fast):
vivado -mode batch -source build.tcl -tclargs synth fpga_xt_top xc7z020clg400-2

# Full bitstream with the PS BD (final verification):
vivado -mode batch -source build.tcl -tclargs bit fpga_xt_top xc7z020clg400-2
```

## Files

| File | Purpose |
|------|---------|
| `hdl/fpga_xt_top.sv` | Top-level integration (xt6502 + ANTIC + plane compositor + sprite engine + blitter, dual MMCM, PS BD / HP stub) |
| `hdl/xt6502.sv` | Clean-sheet registered-MAR 6502 — the system CPU |
| `hdl/sally_mem.sv` | 64 KB dual-port BRAM + banked-window AXI reader + hwreg CDC |
| `hdl/sally_clock.sv` | Clock-enable + RDY gating |
| `hdl/antic_top.sv` | ANTIC/GTIA/POKEY pipeline + peripheral I/O |
| `hdl/antic_raster.sv` / `hdl/antic_seq.sv` | Native phi2-paced raster timer + render sequencer |
| `hdl/plane_compositor.sv` | 1080p60 N-plane compositor (depth/scale/clip) → RGB565 pads |
| `hdl/plane_fetch.sv` | Per-plane DDR3 line fetch (AXI HP read + ping-pong buffer + dither) |
| `hdl/legacy_upscale.sv` | Integer pillarbox upscaler for the legacy-Atari plane |
| `hdl/sprite_engine.sv` | Hardware sprite compositor on the scan-out path |
| `hdl/fb_scanout.sv` | **Superseded** single-plane scan-out; replaced by `plane_fetch` + `plane_compositor` |
| `hdl/xt_blitter.sv` | 2D blitter v0.17 (fill/line/blit/scale/blend/font/raster-ops) |
| `hdl/axi_blitter_bridge.sv` | AXI-Lite GP0 → blitter register bridge |
| `hdl/vbeam.sv` | Parametrisable raster timing generator |
| `hdl/cdc_fifo_1w1r.sv` / `hdl/cdc_sync_bit.sv` | SALLY→ANTIC write FIFO + single-bit synchroniser |
| `sim/tb_boot.sv` | Full-system OS-boot testbench (real XL OS ROM) |
| `tools/cosim_diff.py` | Golden-trace differential boot verification vs Atari800 |
| `vivado/build.tcl` | Non-project Vivado build (OOC synth + impl + setup-recovery loop) |
| `vivado/bd/gen_ps_bd.tcl` | Zynq PS block design generator (HP0/HP1, GP0, DDR3, FCLK) |
| `vivado/run-win10.sh` | rsync + remote Vivado/Vitis build wrapper |
