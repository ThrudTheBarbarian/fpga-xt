# Zynq architecture — single-chip pivot from FPGA+N6

## Why this exists

The paired-FPGA + STM32N6 design (see [n6-migration.md](./n6-migration.md))
is functionally clean but costs ~$150–170 per board at small-batch
volumes — high for a ≤100-unit hobbyist project, and the HyperRAM
ceiling caps the design at 1280×720 with RGB565 double-buffering.

Replacing both the Ti60 and the STM32N6 with a single **Xilinx
Zynq-7020 SoC** brings the design under $100/board, gives access to
DDR3 bandwidth for native 1080p, and removes the entire FPGA↔co-processor
transport layer (PSSI / FMC / SPI / IRQ pins) by collapsing it into
on-chip AXI.

This document is the pivot plan: target architecture, what survives
from the existing work, what gets discarded, and a phased migration.

## High-level architecture

```
Atari I/O                  Zynq-7020 (XC7Z020-1CLG484C)
  cart, SIO,               ┌──────────────────────────────────────────┐
  joysticks, PBI ──────────┤ PL (FPGA fabric, 85K LUTs, 220 KB BRAM)  │
                           │                                          │
                           │  - SALLY 6502 core                       │
                           │  - ANTIC / GTIA / POKEY (legacy chiplets)│
                           │  - 2D GPU ("xt-blitter": fill / blit /   │
                           │    scale / alpha / rotate / text)        │
                           │  - HDMI transmitter (1080p capable)      │
                           │  - DDR3 memory controller (via PS)       │
                           │  - Bus snoop / DRAW dispatch             │
                           │  - PCM1808 I²S RX (audio in)             │
                           │  - PCAL9722 joystick GPIO link           │
                           │            ↕ AXI4 interconnect           │
                           │  PS (Cortex-A9 ×2 @ 766 MHz)             │
                           │  - FreeRTOS (Xilinx BSP)                 │
                           │  - LVGL (LV_COLOR_DEPTH 16, RGB565)      │
                           │  - GEMDOS shim (FatFs over SD)           │
                           │  - USB HID via TinyUSB / XUSBPS          │
                           │  - xt-blitter access via AXI register    │
                           │    pokes (no kernel driver needed)       │
                           │                                          │
                           │  Boot time: < 1 second cold from POR     │
                           │  (Atari-style "turn it on and it's       │
                           │  there" preserved)                       │
                           └──────────────────────────────────────────┘
                              │       │        │       │
                            DDR3   HDMI     USB/SD   1× Ethernet
                          (shared) out      (PS host)  (PHY on board)
```

**One chip, one DDR3, one HDMI output, one toolchain.** The Atari I/O
hangs directly off the PL pins via the existing peripheral modules.
Modern services (Linux filesystem, USB HID, networking) ride the PS
side.

## Hardware target

- **SoC**: **Xilinx XC7Z020-2CLG400** — the same part MyIR Z-Turn (full)
  ships at $129. -2 speed grade, CLG400 package (400-ball BGA, 1.0 mm
  pitch).
  - 85K LUTs, 140 × 36 Kb BRAM (~630 KB), 220 DSP slices
  - Dual Cortex-A9 @ 766 MHz (-2 grade), 256 KB on-chip RAM
  - At the chip level: 106 PL IO + 54 MIO. On the **Z-Turn SOM**: only
    78 PL GPIO + 9 MIO are routed to the expansion connectors (the
    rest are consumed by on-SOM peripherals: DDR3, USB, Ethernet,
    SiI9022A, microSD, etc.).
  - Native DDR3 controller, USB 2.0 host, SDIO, GbE MAC built in
  - 1.0 mm pitch BGA: **no HDI PCB required** (vs N655's 0.8 mm)
- **DDR3**: 1 GB DDR3L on Z-Turn full. Bandwidth ~1–3 GB/s sustained —
  at least 5× the HyperRAM ceiling. Drives the framebuffer at 1080p
  RGB565 DB easily (~4 MB), with room for assets + Linux/FreeRTOS
  working set.
- **HDMI output**: **SiI9022A HDMI transmitter** (on Z-Turn SOM) — Zynq
  drives parallel **RGB565 + HSYNC/VSYNC/DE/PIXCLK** to the SiI9022A
  *internally* on the module. The SOM only routes 16 of the SiI9022A's
  RGB lanes (board-level pin tradeoff on Z-Turn), so the framebuffer
  format is RGB565 throughout. The chip still handles TMDS encoding,
  InfoFrames, hot-plug detection, and the HDMI connector. We don't
  budget those pins against our carrier. Existing `tmds_*` fabric
  modules become unused (~1K LUTs recovered).
- **Audio input**: **PCM1808 stereo I²S ADC** — 3 PL pins (BCK, LRCK,
  DOUT). Zynq's XADC was considered as a single-chip alternative but
  Z-Turn only routes the VP/VN differential pair to the carrier (one
  analog channel total, not enough for stereo). PCM1808 stays.
- **Modern-half OS**: **FreeRTOS** with Xilinx BSP. Sub-second cold
  boot; preserves the "turn it on and it's there" feel. Linux/PetaLinux
  was considered and rejected — too heavyweight for the system services
  we actually need.
- **Tooling**: Vivado ML Standard (free, Webpack-tier for 7-series) +
  Vitis (free, FreeRTOS + bare-metal app development). No PetaLinux
  build pipeline.

### Fabric speed — 28 nm vs 16 nm

Zynq-7000 is on TSMC 28 nm; Ti60 is on TSMC 16 nm FinFET. For tight
combinational paths like the SALLY core's instruction-decode and the
JMPI critical path, this matters somewhat — but the -2 speed grade
silicon (which Z-Turn already ships at scale) recovers most of the gap:

| | Ti60 -3 (today) | Zynq-7020 -1 | Zynq-7020 **-2 (target)** |
|---|---:|---:|---:|
| SALLY core fmax (est.) | ~165 MHz | ~100–130 MHz | **~130–160 MHz** |

So SALLY lands within ~10 % of today's fmax. GEM AES, modern-mode
xtc programs, all workloads stay essentially as snappy as today.

**Default plan**: -2 grade throughout (it's what Z-Turn parts ship as,
proving distribution volume is there). The -1 grade is not part of
the design.

### Pin budget on Z-Turn (78 PL GPIO + 9 MIO carrier-exposed)

Key insights that shrink the budget vs the original N6-path inheritance:

- **Cart and PBI share most signals** (data + address + control + power
  + clock). Wired in parallel from one FPGA bus to both connectors;
  only the connector-unique senses (cart RD4 / RD5 / CCTL; PBI MPD /
  EXTSEL / EXTIRQ) need separate pins.
- **SiI9022A RGB + sync pins are on-SOM** — internal to the Z-Turn
  module, not exposed to the carrier and not in our pin budget.
- **PCAL9722 SPI + INT** moves to MIO (Zynq has 2 SPI controllers on
  MIO; we use one).
- **Console UART** likely consumes 2 of the 9 carrier-exposed MIO
  (Z-Turn typically wires a UART to its onboard FTDI). The remaining
  MIO host PCAL9722 and possibly one expansion-port UART.

| Pin group | Pins | Bus | Notes |
|-----------|-----:|-----|-------|
| Atari cart + PBI (shared bus) | ~35 | PL | data + addr + control + connector-unique senses |
| SIO (13-pin signal subset) | ~10 | PL | |
| PCM1808 I²S (BCK + LRCK + DOUT) | 3 | PL | |
| Expansion ×2 SPI | 8 | PL | 4 wires × 2 ports, instantiated in fabric |
| Expansion ×2 UART (1× in fabric, 1× on MIO if free) | 2 | PL | second port's TX+RX if no MIO available |
| LEDs / buttons / strapping | ~5 | PL | |
| **PL total** | **~63 / 78** | | ~15 pins headroom |
| Console UART | 2 | MIO | Z-Turn onboard FTDI |
| PCAL9722 SPI + INT | 5 | MIO | CLK, MOSI, MISO, CS, INT |
| Expansion UART ×1 | 2 | MIO | second one falls back to PL |
| **MIO total** | **9 / 9** | | exactly fills the budget |

PL is comfortable with ~15 pins headroom. MIO is exactly used. If a
particular sub-bus pushes things, joystick edge can collapse behind
PCAL9722 (already on MIO SPI) freeing more PL margin.

## What survives from existing work

The architectural side of the project transfers almost entirely. The
N6-specific transport / firmware doesn't.

| Asset | Fate | Notes |
|-------|------|-------|
| `sally/`, `sally_core`, `sally_mem`, `sally_clock`, `prefetch`, `bank_cache`, `bank_translator`, `bank_xlat`, `cache_*` | **Keep**, port to Xilinx 7-series | SystemVerilog ports cleanly; primitive-level differences (BRAM, DSP slice names) handled by Vivado inference |
| `antic_regs`, `dl_parser`, `dma_arbiter`, `dma_master`, `vbeam`, `wsync_gen`, `nmi_gen`, `gtia_regs`, `pia_regs`, `pokey_*`, `compositor`, `color_resolver`, `line_buffer`, `scan_out`, `palette_lut` | **Keep**, port | Legacy ANTIC/GTIA/POKEY pipeline. Plain RTL, no vendor primitives. |
| `tmds_*`, `terc4_encoder`, `hdmi_*` | **Discard** | HDMI is via the on-SOM SiI9022A transmitter; Zynq outputs parallel RGB565 + sync. ~1K LUTs recovered. Existing modules archived for reference. |
| `bus_snoop`, `draw_regs`, `pssi_tx`, `pssi_bytes` (just built) | **Re-purpose** | `pssi_tx` becomes an AXI-stream master into xt-blitter command parser instead of pad-driving outputs. ~50–70 % of the RTL is preserved. |
| `hyperram_phy`, `hyperram_shim`, `hyperram_mock` | **Discard** | DDR3 via the PS handles all off-chip memory; no HyperRAM in this design. |
| `peri_bridge`, `peri_link`, `rp_rx`, `rp_tx`, `rp_bus_mock`, `joy_bridge`, `joy_link` | **Discard / re-evaluate** | Joystick PCAL9722 link probably stays (the expander is independent of FPGA choice); RP bridges go away |
| `pcm1808_rx` | **Keep**, port | PCM1808 stays (Z-Turn doesn't route enough XADC channels to the carrier for stereo). Primitive-free SystemVerilog should port cleanly. |

Documentation:

| Doc | Fate |
|-----|------|
| [VDI-opcodes.md](./VDI-opcodes.md) | **Keep entirely.** The wire format is the 6502↔GPU contract regardless of physical transport. |
| [GEM-implementation.md](./GEM-implementation.md) | **Mostly keep.** "N6 firmware" becomes "Linux process + FPGA driver"; everything above that (AES design, GEMDOS RPC over FMC) maps cleanly. The SALLY tasking extensions section is unchanged. |
| [n6-migration.md](./n6-migration.md) | **Archive.** Historical reference for the architecture this pivot replaced. |
| [n6-hdl-migration.md](./n6-hdl-migration.md) | **Archive.** The phased plan is largely obsolete; some HDL files survive but the migration shape changes. |
| **This document** | New. The pivot plan and the architecture it lands on. |

## What's net-new

### xt-blitter (FPGA-side 2D GPU)

Replaces NeoChrom. Single AXI-master block in the PL with the
following primitives, sized by my estimates in the chat:

| Primitive | Approx. LUTs | DSP slices |
|-----------|-------------:|----------:|
| Rect fill (solid colour) | 300 | 0 |
| Line draw (Bresenham) | 400 | 0 |
| Circle / ellipse | 500 | 0 |
| Block blit (axis-aligned copy) | 800 | 0 |
| Scaled blit (nearest-neighbour) | 1,300 | 0 |
| Scaled blit (bilinear) | 2,800 | 4 |
| Alpha blend | 700 | 4 |
| Rotated blit | 2,500 | 8 |
| Bitmap font raster | 600 | 0 |
| AXI master + DMA arbiter | 1,000 | 0 |
| Command parser (consumes DRAW byte stream) | 800 | 0 |
| **Total** | **~11,700 LUTs, 16 DSPs** | well within Zynq-7020 |

Command parser feeds from the existing pssi_tx FIFO (re-purposed as
an AXI-stream source). 6502 software emits VDI opcodes via $D49C
exactly as in the N6 design; instead of crossing to another chip,
the byte stream lands in an AXI fabric block.

### FreeRTOS + LVGL on the PS

The Cortex-A9s run a FreeRTOS image built with Xilinx Vitis. Userspace
processes (in the Linux sense) don't exist — everything is FreeRTOS
tasks statically linked into a single image. The mini-services:

- **LVGL** compiled with `LV_COLOR_DEPTH 16` (RGB565) — matches the
  Z-Turn's SiI9022A wiring, which only routes 16 RGB lanes to the
  transmitter. One config across all resolutions; no per-resolution
  flush-callback colour-depth conversion. Display flush callback writes
  pixels via the xt-blitter command ring or directly to the DDR3
  framebuffer.
- **xt-blitter "driver"** — not a kernel driver at all, just a thin C
  module that pokes AXI registers from a FreeRTOS task. ~few hundred
  lines.
- **GEMDOS shim** — maps GEMDOS syscalls onto FatFs `f_open` /
  `f_read` / `f_write` against the SD card filesystem. ~few hundred
  lines.
- **USB HID daemon task** — uses TinyUSB or Xilinx's XUSBPS stack; reads
  mouse / keyboard reports, pushes events into the existing chiplet
  event queue via AXI register writes.

AES itself runs on the 6502 (xtc-compiled) — not on the PS side. The
PS hosts only the "boring" system services: filesystem, USB input,
optional LVGL drawing for modern UI elements. This keeps the modern
half deliberately minimal — sub-second boot, easy to debug, easy to
iterate on.

### DDR3 framebuffer

All framebuffers and bulk assets live in DDR3 via the PS DDR
controller. The PL accesses them through high-performance AXI ports
(HP0–HP3, each 64-bit @ 600 MB/s). At 1080p RGB565 DB:

- Single framebuffer: 1920×1080×2 = ~4 MB
- Double-buffered: ~8 MB total — easily fits in 1 GB DDR3 alongside
  Linux/FreeRTOS working set, GEM assets, etc.
- Scan-out: 1920×1080×2×60 = 249 MB/s — well below DDR3 ceiling
- GPU writes: opportunistic, up to ~800 MB/s peak

The previous design's "RGB565 only at 1280×720" compromise was a
SRAM-size constraint on the N6. DDR3 lifts that entirely — every
resolution up to 1080p fits comfortably double-buffered.

## What still applies from the N6 design

These decisions all stand:

- **6502 talks to the modern half via $D4xx chiplet-extension
  registers.** Same address map ($D49C PSSI_BYTE, $D49D PSSI_STATUS).
  The byte stream just goes to AXI instead of off-chip pads.
- **VDI wire format is 8-bit indexed (classic ops) + RGB888 (extended
  ops at 0xC1–0xCF).** Unchanged — wire format is target-independent;
  framebuffer downsampling to RGB565 happens at flush time.
- **LVGL configured `LV_COLOR_DEPTH 16` (RGB565)** to match the
  SiI9022A's 16-lane wiring on the Z-Turn carrier.
- **Mailbox / RPC semantics from FMC** — re-cast as PS-side AXI
  registers, same source-bitmap-with-counters pattern. The wire format
  for the RPC payload itself is identical.
- **SALLY tasking extensions** (SP_BANK, ZP_BANK, wider SP, etc.)
  unchanged — they're 6502-core mods, independent of off-chip
  architecture.
- **GEM port plan** (AES on 6502, VDI dispatch, GEMDOS RPC) unchanged
  in shape, just hosted on a different "modern" half.

## Phased migration

Designed so each phase ends with a passing test, and the
already-tested HDL keeps running through the port.

### Phase 0 — environment + port baseline (2 sprints)

- Install Vivado ML Standard + Vitis + PetaLinux. Confirm a hello-world
  Zynq-7020 design synthesises and runs on a reference board (e.g.
  Z-Turn Lite, ~$99) before the custom board exists.
- Port `sally_*`, `cache_*`, `bank_*`, `bus_snoop`, `byte_ram*` to a
  Vivado project; run the existing per-module testbenches under Vivado
  XSIM.
- Stand up DDR3 controller and a 32 KB AXI scratchpad as the substrate
  for everything else.

**Exit gate**: SALLY core boots, executes from DDR3, passes the existing
`tb_sally` / `tb_sally_mem` testbenches under Xilinx tooling.

### Phase 1 — ANTIC pipeline + parallel RGB output (3 sprints)

- Port `antic_regs`, `dl_parser`, `dma_*`, `vbeam`, `wsync_gen`,
  `nmi_gen`, `gtia_regs`, `pia_regs`, `pokey_*`, `compositor`,
  `color_resolver`, `line_buffer`, `scan_out`, `palette_lut`.
- Replace direct TMDS path with parallel RGB565 + sync output to drive
  the on-SOM SiI9022A. Existing `tmds_*` modules archived.
- I²C config block (FreeRTOS task or small fabric I²C master) brings up
  SiI9022A at boot for the desired pixel clock / format.
- Run `tb_visual`, `tb_pbi`, `tb_dl_parse`, `tb_dma_int`, `tb_pokey`,
  `tb_pokey_i2s` under XSIM. (TMDS testbenches archived.)

**Exit gate**: 640×480 legacy ANTIC video over HDMI on a Z-Turn-class
dev board with a real Atari mode-2 test pattern, driven through the
SiI9022; all per-module testbenches pass.

### Phase 2 — xt-blitter v0 (4 sprints)

- Implement command parser consuming the existing `pssi_tx`-style byte
  FIFO. Convert to AXI-stream upstream of the parser.
- Implement primitives in order: rect fill → line → block blit →
  scaled blit (nearest) → bitmap font raster → alpha blend → scaled
  blit (bilinear). Rotated blit can be Phase 4.
- AXI master writing into DDR3 framebuffer region.
- Unit testbenches per primitive; integration testbench: emit a VDI
  opcode stream via `pssi_bytes`-equivalent registers, verify DDR3
  framebuffer contents match.

**Exit gate**: a 6502 program emitting line / rect / blit ops via
$D49C lands pixels in DDR3 at the right addresses; HDMI scan-out
shows the result.

### Phase 3 — FreeRTOS + LVGL + xt-blitter access (2 sprints)

- Vitis FreeRTOS BSP image: scheduler, FatFs over SDIO, TinyUSB host or
  XUSBPS, simple Xilinx UART console.
- Thin xt-blitter "driver" — C module that owns the AXI command ring
  and exposes a callable submit-command API to other FreeRTOS tasks.
  No kernel-mode anything.
- Compile LVGL for `LV_COLOR_DEPTH 16`; display flush callback either
  goes through xt-blitter (hardware accelerated) or writes directly
  to DDR3 (software fallback).
- LVGL renders into DDR3; xt-blitter or framebuffer scan-out displays it.

**Exit gate**: LVGL "Hello world" widget shows on HDMI through the
xt-blitter path. USB mouse moves the cursor. Cold-boot to first widget
visible: < 1 second.

### Phase 4 — Atari I/O integration (2 sprints)

- Port `pcm1808_rx`. Port joystick interface (`joy_bridge` /
  `joy_link` or re-implement against Zynq pins).
- Re-implement cart slot / SIO / PBI bridges against PL pins. Most of
  this is straightforward RTL — the legacy chiplets are already
  wired in earlier phases.
- Stress-test with a real Atari cart inserted into a prototype board.

**Exit gate**: a real Atari cart loads and runs on the Zynq board; SIO
device responds; joystick input works.

### Phase 5 — GEM port (parallel with Phase 4) (3–6 months)

Per [GEM-implementation.md](./GEM-implementation.md), adapted: AES
runs on the 6502 (xtc); VDI dispatch crosses into the xt-blitter via
the existing chiplet registers; GEMDOS RPC lands on the FreeRTOS side
via PS-mapped AXI registers (the FMC mailbox map → AXI register map,
same semantics).

### Phase 6 — board respin, soak, ship (1 sprint)

- Custom carrier board around the Zynq SoC if we don't ride a Z-Turn
  Lite. Bring up DDR3, HDMI, Atari I/O.
- Real-hardware soak.
- Documentation pass, archive `n6-migration.md` and `n6-hdl-migration.md`
  with redirects to this doc.

## Revised BoM at ≤100 units

Two paths, each viable. **Option A is the recommended starting point**
at this scale; Option B becomes attractive only at higher volume.

### Option A — Z-Turn (full) + custom carrier (recommended)

| Component | Approx. unit cost |
|-----------|------------------:|
| **MyIR Z-Turn (full)** SOM — XC7Z020-2CLG400, 1 GB DDR3, QSPI flash, microSD, USB, Ethernet PHY, **SiI9022A HDMI transmitter (RGB565 wiring) + HDMI connector**, on-board PMICs (5 V + 3.3 V on header pins) | $129 |
| PCAL9722 GPIO expander (joystick fan-out) | $2 |
| PCM1808 stereo I²S ADC + analog input passives (audio in) | $2 |
| Level shifters / buffers for 5 V Atari side | $2 |
| Atari cart + SIO + PBI + 4× joystick + expansion ×2 connectors | $0 (from existing supply for ≤100 units; production sourcing noted as a risk) |
| Passives + LEDs + buttons | $4 |
| 2-layer carrier PCB + assembly (no BGA, no DDR3, no SOM-side bring-up) | $10–15 |
| **Total per board** | **~$149–154** |

This is the carrier reduced to its essentials: connectors + level
translation + PCAL9722 + PCM1808 + a few passives. No HDMI transmitter
(already on the SOM), no Atari-side power circuit (5 V / 3.3 V on the
SOM header). The Z-Turn module brings everything modern.

Trade-off: more expensive per-unit than a fully custom Zynq board, but
**no Zynq+DDR3 bring-up effort, no fragile BGA placement, no
multi-rail PMIC, no SiI9022 integration work**. The SOM already
integrates everything that's risky. Iteration cycle is days, not
weeks. For ≤100 units this is the clear winner.

Note on Atari connectors: the user has an existing supply for low-
volume runs, so they're $0 BoM cost up to that supply's depletion. At
production volume, sourcing the cart-edge connector in particular
becomes a real challenge — but that's an availability problem more
than a cost problem.

### Option B — bare Zynq custom board

| Component | Approx. unit cost |
|-----------|------------------:|
| XC7Z020-2CLG400 | $35–45 |
| DDR3L 512 MB (4 chips × 16-bit, or 1× 64-bit module) | $5–8 |
| QSPI flash 32 MB (Zynq boot + user storage) | $2–3 |
| SiI9022A HDMI transmitter + HDMI connector | $4 |
| SD card slot, USB host connector | $3 |
| PCAL9722 GPIO expander | $2 |
| PCM1808 stereo I²S ADC + input passives | $2 |
| 4× joystick DB-9 + Atari connectors | $26 |
| Power (3.3 V + 1.8 V + 1.5 V DDR3 + 0.9 V VCC_INT + USB-C) | $5 |
| Passives + LEDs + buttons | $5 |
| 6-layer PCB + assembly (Zynq BGA-400, 1.0 mm — no HDI) | $25–35 |
| **Total per board** | **~$113–137** |

~$30–40 cheaper per board than Option A *at full sourcing cost*, but
requires ~3 board respins to get the DDR3 routing / power sequencing /
clocking right. Engineering NRE only amortises at 200+ units.

## Risks

1. **HDL re-port effort.** Several thousand lines of SystemVerilog need
   verification under Vivado XSIM. Most should "just work" — the code
   is primitive-free except for the TMDS / HDMI chain. Estimate 2–4
   weeks if no surprises.

2. **DDR3 controller learning curve.** Zynq's PS-side DDR3 controller
   is the standard route; lots of existing tutorials. Bandwidth + AXI
   port setup is non-trivial first time but well-documented.

3. **SALLY fmax on 28 nm fabric.** Zynq-7020 is 28 nm vs Ti60's 16 nm,
   so the SALLY core's tight combinational paths will close ~25–40 %
   slower on -1 speed grade (~110 MHz vs Ti60's 165 MHz). Mitigations:
   -2 speed grade (~$10–15 more) recovers most of the gap; an extra
   pipeline stage on JMPI / decode buys it back on -1. See "Fabric
   speed — 28 nm vs 16 nm" above.

4. **HDMI on Xilinx 7-series at 1080p.** Possible but requires careful
   IO planning (LVDS pairs, PLL configuration). Reference designs
   exist from Xilinx and the community.

5. **FreeRTOS + TinyUSB integration.** USB host on Zynq-7020 needs
   either the Xilinx XUSBPS standalone driver or a port of TinyUSB.
   Both are well-trodden but unfamiliar to this team; budget 1–2
   weeks for getting a mouse/keyboard event reading reliably.

6. **Disposing of N6 design work.** Sunk cost. We invested ~10
   sessions converging on the N6 transport. ~30–40 % of the design
   thinking (VDI opcodes, GEM plan, mailbox semantics) survives; the
   rest (PSSI wire on pads, FMC, IRQ aggregation) is archived.

7. **PL pin count fits the Z-Turn carrier-exposed budget.** With
   PSSI/FMC/LTDC/HyperRAM removed and the SiI9022A on-SOM, ~63 of the
   **78 PL GPIO routed to the carrier** are needed for the Atari I/O
   + PCM1808 + expansion + joystick paths. ~15 PL headroom; MIO budget
   (9 carrier-exposed) is tight but workable. Joystick edge can
   collapse further behind PCAL9722 if a sub-bus pushes things.

## Decision: pivot or continue

The Zynq pivot:
- Lands BoM at ~$150/board at ≤100 units via Z-Turn SOM (Option A);
  the original sub-$100 target requires Option B (bare custom Zynq
  board) and ~3 respin cycles
- Lifts the framebuffer ceiling — every resolution up to **1080p
  RGB565** fits double-buffered in DDR3 (vs N6 path's 1280×720 RGB565
  ceiling that was SRAM-size constrained)
- Eliminates ~85 inter-chip pins worth of transport
- Removes the BGA-264 HDI PCB constraint (1.0 mm pitch CLG400, no HDI)
- Single-vendor toolchain (Vivado ML Standard, free for Zynq-7020)
- Total project effort *comparable* to continuing the N6 path

The cost: archive ~30–40 % of the design work (n6-migration architecture,
FMC mailbox detail, PSSI-on-pads protocol) and re-port the HDL to
Xilinx tooling.

My recommendation: **pivot now**, before more N6-specific HDL lands
(FMC slave, LTDC capture, etc., are next in the n6-hdl-migration phase
plan; that work would be wasted). The work we have already shipped
(pssi_tx + pssi_bytes + the VDI opcode spec) survives the pivot.

## References

- [VDI-opcodes.md](./VDI-opcodes.md) — survives unchanged
- [GEM-implementation.md](./GEM-implementation.md) — surviv mostly
  unchanged; substrate becomes Linux on Cortex-A9 instead of N6 M55
- [n6-migration.md](./n6-migration.md) — archived after pivot
- [n6-hdl-migration.md](./n6-hdl-migration.md) — archived after pivot
- Z-Turn Lite product page — $99 reference platform for Phase 0–3
  bring-up before the custom carrier board exists
- Xilinx UG585 (Zynq-7000 TRM) — DDR3 controller, AXI HP ports, USB
  host, etc.
- Xilinx UG1208 (FreeRTOS BSP for Zynq-7000) — official FreeRTOS port,
  ships with Vitis
- TinyUSB project — open-source USB host stack, has Zynq-7000 examples
- LVGL FreeRTOS port — official LVGL reference for embedded RTOS use
