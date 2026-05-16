# fpga-xt — Atari-XT system on Xilinx Zynq-7020

A modern Atari 8-bit-class computer built around the Xilinx Zynq-7020
SoC via the MyIR Z-Turn SOM. FPGA fabric hosts a SALLY 6502 core and
the ANTIC/GTIA/POKEY pipeline; the dual Cortex-A9 PS hosts the modern
half (FreeRTOS, USB HID, SD filesystem, GEM AES helpers). A custom 2D
blitter (`xt-blitter`) in fabric replaces the discrete N6 graphics
co-processor that the earlier paired-FPGA design used.

## Hardware target

- **MyIR Z-Turn (full)** SOM — XC7Z020-2CLG400, 1 GB DDR3, microSD,
  USB host, GbE, on-SOM SiI9022A HDMI transmitter (RGB565 wiring),
  on-SOM 5 V / 3.3 V PMICs
- **Carrier-exposed pin budget**: 78 PL GPIO + 9 MIO
- **Custom carrier** exposing Atari I/O: cart slot, SIO, PBI, 4×
  joystick, expansion ×2, audio in (PCM1808)
- **Estimated cost** at ≤100 units: ~$150/board (Option A — Z-Turn +
  thin carrier; Option B bare-Zynq drops to ~$120 but needs 3 respins)

## Build flows

- **HDL (Vivado)**: [`vivado/`](vivado/) — `cd vivado && ./run.sh synth`
  drives Vivado ML Standard on a remote Linux box over SSH. Default
  top is `sally_synth_top`, part `xc7z020-2clg400` (-2 speed grade).
- **Simulation (iverilog)**: [`sim/`](sim/) — `make -C sim all` runs
  the per-module testbench suite locally. Works without Vivado.

## Document map

| Doc | Scope |
|-----|-------|
| [docs/zynq-architecture.md](docs/zynq-architecture.md) | **Primary** — Zynq-7020 target spec, BoM, pin budget, phased migration |
| [docs/GEM/VDI-opcodes.md](docs/VDI-opcodes.md) | Wire format for 6502 → 2D-GPU drawing commands (target-independent) |
| [docs/GEM/GEM-implementation.md](docs/GEM-implementation.md) | GEM port plan — AES on 6502, VDI dispatch, GEMDOS shim. Pre-pivot; needs an N6→Zynq sweep. |
| [docs/architecture.md](docs/architecture.md), [docs/FPGA.md](docs/FPGA.md), [docs/hdmi.md](docs/hdmi.md), [docs/wire-protocol.md](docs/wire-protocol.md) | Pre-pivot architecture notes — some still apply, some are Ti60/Efinity/N6-specific. Sweep TBD. |
| [docs/palette.md](docs/palette.md), [docs/register-map.md](docs/register-map.md), [docs/pin-map.md](docs/pin-map.md) | Atari-specific reference. |
| [docs//Altirra/altirra-*.md](docs/), [docs/Altirra/altirra-reference-manual.pdf](docs/altirra-reference-manual.pdf) | Reference material from the Altirra Atari emulator |
| [docs/future-work.md](docs/future-work.md) | Ongoing project ideas / deferred items |
| [refs/](refs/) | Hardware reference (Z-Turn schematic, board dimensions) |

## Layout

```
fpga-xt/
├── README.md          this file
├── hdl/               SystemVerilog modules (SALLY, ANTIC, GTIA, POKEY, …)
├── sim/               iverilog testbenches (49 currently)
├── vivado/            Vivado batch-mode build (Zynq target)
├── efinity/           (archived) Efinity batch-mode build (Ti60 target)
├── docs/              architecture, plans, references
│   └── archive/       Generation 1/2 historical docs
├── refs/              hardware reference (Z-Turn schematic, etc.)
└── rp/                pre-pivot RP-related sub-project
```

## What's new vs Generation 2

| Aspect | Gen 2 (Ti60+N6) | This (Zynq) |
|--------|-----------------|-------------|
| Silicon | 2× FPGAs + HyperRAM + SiI9022 (carrier) | 1× Zynq-7020 + DDR3 + SiI9022A (SOM) |
| Modern half | STM32N655 BGA-264 on custom HDI PCB | Dual Cortex-A9 PS inside Zynq, no extra chip |
| Transport | 85 inter-chip pins (PSSI / FMC / IRQ) | AXI inside the die |
| Framebuffer | 1280×720 RGB565 ceiling (SRAM-bound) | 1080p RGB565 double-buffered (DDR3) |
| HDMI | Direct TMDS from fabric | SiI9022A on-SOM, parallel RGB565 + sync |
| Audio in | PCM1808 stereo I²S | PCM1808 stereo I²S (unchanged) |
| Carrier PCB | 6-layer HDI (0.8 mm BGA) | 2-layer (no BGA, no DDR3 routing) |
| Toolchain | Efinity + STM32CubeIDE | Vivado ML Standard + Vitis (single vendor) |
| Per-board cost (≤100u) | ~$160 + assembly risk | ~$150 (Option A) |
