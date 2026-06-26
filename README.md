# fpga-xt — Atari-XT system on Xilinx Zynq-7020

A modern Atari 8-bit-class computer built around the Xilinx Zynq-7020
SoC via the MyIR Z-Turn SOM. FPGA fabric hosts an xt6502 6502 core and
the ANTIC/GTIA/POKEY pipeline; the dual Cortex-A9 PS hosts the modern
half (FreeRTOS, USB HID, SD filesystem, GEM AES helpers). A custom 2D
blitter (`xt_blitter`) in fabric provides graphics acceleration.

## Hardware target

- **MyIR Z-Turn (full)** SOM — XC7Z020-2CLG400, 1 GB DDR3, microSD,
  USB host, GbE, on-SOM SiI9022A HDMI transmitter (RGB565 wiring),
  on-SOM 5 V / 3.3 V PMICs
- **Carrier-exposed pin budget**: 78 PL GPIO + 9 MIO
- **Custom carrier** exposing Atari I/O: cart slot, SIO, PBI, 4×
  joystick, expansion ×2, audio in (PCM1808)
- **Estimated cost** at ≤100 units: ~$150/board (Option A — Z-Turn +
  thin carrier; Option B bare-Zynq drops to ~$120 but needs 3 respins).
  Off-the-shelf board-only options are cheaper still — see Board tiers.

## Board tiers

The platform is settled on Zynq, but the RTL is part-agnostic: it builds
for any Zynq-7000 with only a part-string change, and the one per-board
difference is the video front-end. Measured `clk_sally` fmax across three
off-the-shelf boards (from isolated `-1` / 7010 bit builds):

| Board | Part | DDR3 | Video out | clk_sally (raw / turbo) | Effective¹ | Board price |
|-------|------|------|-----------|-------------------------|-----------|-------------|
| MyIR Z-Turn (reference) | XC7Z020-**2** CLG400 | 1 GB / 32-bit | SiI9022A HDMI (on-SOM) | ~120 MHz / ~67× | ~108× | ~£112² |
| Smart Zynq SL | XC7Z020-**1** CLG484 | 512 MB / 16-bit | native HDMI (fabric TMDS), 24-bit | ~98 MHz / ~55× | ~88× | ~£69 |
| budget 7010 | XC7Z010-**1** CLG400 | board-dependent | VGA (THS8135 DAC), 24-bit, ≤1080p | ~86 MHz / ~48× | ~75–80× | ~£14 |

¹ Effective throughput on a graphics screen. A real Atari's 6502 loses
~34–40% of its cycles to ANTIC DMA cycle-stealing; our ANTIC reads via a
non-contending render-tap, so the emulated CPU keeps all of its cycles
(turbo ÷ duty cycle). Cycle-exact compatibility is preserved — at 1× the
cycle-steal is reconstructed via the CPU `/HALT` line.

² Z-Turn SOM + thin carrier (Option A above); the others are board-only
street prices.

Tradeoffs down the ladder:

- **Video front-end is the only RTL change.** The SiI9022A I²C path gives
  way to a fabric TMDS encoder (native-HDMI boards) or a THS8135
  parallel-RGB path (VGA) — both portable, both arguably simpler.
- **16-bit DDR** (single chip) halves bandwidth vs the Z-Turn's 32-bit but
  comfortably covers the real workload (one full-res plane + small scaled
  legacy windows; legacy source reads are a few MB/s).
- **7010 fit** is real but tight: routes at 88% BRAM / 78% LUT with timing
  closed — no growth headroom, which is fine because the m68k path runs on
  the ARM, not in fabric.
- **Speed grade**: the cheap boards are `-1`, ~18% slower than the Z-Turn's
  `-2`. Accepted as the price; video closes at 1080p on all three.

## Build flows

- **HDL (Vivado)**: [`vivado/`](vivado/) — `cd vivado && ./run-win10.sh synth`
  drives Vivado on the win10 build host over SSH. Default top is
  `fpga_xt_top`, part `xc7z020-2clg400` (-2 speed grade).
- **Simulation (iverilog)**: [`sim/`](sim/) — `make -C sim all` runs
  the per-module testbench suite locally. Works without Vivado.

## Document map

The living reference is the Starlight site under [`web/site/`](web/site/);
the `docs/` tree below is working notes and design drafts (some pre-pivot).

| Doc | Scope |
|-----|-------|
| [docs/NextSteps.md](docs/NextSteps.md) | **Consolidated open-work / TODO tracker** — read first for "what's left" |
| [docs/architecture.md](docs/architecture.md), [docs/video/video-architecture.md](docs/video/video-architecture.md) | System architecture + the current video model (1080p desktop compositor, scalable ANTIC window) |
| [docs/Zynq/](docs/Zynq/) | Zynq-7020 target — [FPGA.md](docs/Zynq/FPGA.md), [memory-map.md](docs/Zynq/memory-map.md), [register-map.md](docs/Zynq/register-map.md), [pin-map.md](docs/Zynq/pin-map.md), board schematic |
| [docs/bring-up.md](docs/bring-up.md) | Hardware bring-up — JTAG, FSBL, board boot |
| [docs/Issues/](docs/Issues/) | Open issue write-ups (e.g. GP0 AXI read hang) |
| [docs/GEM/](docs/GEM/) | GEM port — [VDI-opcodes.md](docs/GEM/VDI-opcodes.md) (6502 → 2D-GPU wire format), [GEM-implementation.md](docs/GEM/GEM-implementation.md), VDI software impl |
| [docs/HDMI/](docs/HDMI/) | [hdmi.md](docs/HDMI/hdmi.md), [palette.md](docs/HDMI/palette.md), SiI9022A datasheets |
| [docs/6502/](docs/6502/), [docs/Altirra/](docs/Altirra/) | 6502 embellishments; Altirra ANTIC/POKEY audits + reference manual |
| [docs/MultiTasking/](docs/MultiTasking/), [docs/OS/](docs/OS/) | Multitasking + OS design notes |
| [docs/Design/](docs/Design/) | Per-feature design specs — sprite engine, banked page cache, [aux audio & reservations](docs/Design/aux-audio-and-reservations.md) |
| [refs/](refs/) | Hardware reference (Z-Turn schematic + dimensions) |

## Layout

```
fpga-xt/
├── README.md          this file
├── hdl/               SystemVerilog modules (xt6502, ANTIC, GTIA, POKEY, …)
├── sim/               iverilog testbenches (46 currently)
├── vivado/            Vivado batch-mode build (Zynq target)
├── vitis/             PS-side software (FSBL, BSP, blitter driver, BOOT.BIN)
├── docs/              architecture, plans, references
├── web/site/          Starlight documentation site (canonical)
├── refs/              hardware reference (Z-Turn schematic, etc.)
└── rp/                pre-pivot RP-related sub-project
```

## License

Copyright © 2026 ThrudTheBarbarian.

Licensed under the **CERN Open Hardware Licence Version 2 – Strongly
Reciprocal (CERN-OHL-S-2.0)**, with one additional Licensor clause:
§3.4 requires that anyone who copies or derives from this work state that
they have done so and link back to the original source
(`https://github.com/ThrudTheBarbarian/fpga-xt`). Because the licence text
is augmented, the SPDX identifier is
`LicenseRef-CERN-OHL-S-2.0-with-attribution`, not bare `CERN-OHL-S-2.0`.
See [LICENSE](LICENSE) for the full text.

Third-party vendor documents under `refs/` and `docs/HDMI/` (MyIR Z-Turn
and Silicon Image SiI9022A references) remain the copyright of their
respective owners and are included for convenience only.
