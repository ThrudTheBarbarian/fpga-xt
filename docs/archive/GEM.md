# GEM for rp-XT — POR (STM32N6 variant)

**GEM** (Graphical Environment Manager) — a windowing GUI system for the
rp-XT platform, implemented as an xtc library. This document covers the
architecture using the STM32N6 as the graphics co-processor.

## Table of Contents

1. [Hardware context](#1-hardware-context)
2. [Architecture overview](#2-architecture-overview)
3. [Communication paths](#3-communication-paths)
4. [Voltage domains](#4-voltage-domains)
5. [FPGA configuration — shared QSPI flash](#5-fpga-configuration--shared-qspi-flash)
6. [N6 peripheral map](#6-n6-peripheral-map)
7. [DRAW command set](#7-draw-command-set)
8. [$D4xx register map](#8-d4xx-register-map)
9. [PSSI wire format](#9-pssi-wire-format)
10. [Memory budget](#10-memory-budget)
11. [NeoChrom GPU](#11-neochrom-gpu)
12. [LTDC synchronisation](#12-ltdc-synchronisation)
13. [Resolution](#13-resolution)
14. [Timeline](#14-timeline)
15. [Open questions](#15-open-questions)

---

## 1. Hardware context

rp-XT is a two-chip architecture for the graphics subsystem:

| Chip | Role | CPU | Speed | Memory | Notes |
|------|------|-----|------:|--------|-------|
| **FPGA** (Ti60F256) | Real-time video + CPU | 6502 (SALLY, Arlet core) + ANTIC + GTIA/CTIA + HyperRAM controller + POKEY + TMDS encoder | 6502 @ 165 MHz, fabric at bus rate | 64 KB BlockRAM cpu_shadow + 16 MB HyperRAM (system RAM) | All realtime paths in fabric — compositor, DL parser, TMDS encoder, palette |
| **STM32N6** (N655) | Graphics co-processor + peripherals | Cortex-M55 + NeoChrom GPU | 800 MHz | 4.2 MB internal SRAM + 16 MB external HyperRAM | VDI dispatch, NeoChrom rendering, LTDC video out, SD card, SIO, USB host (mouse, keyboard), FPGA config flash |


No other microcontroller is present in the video/graphics path. The N6
handles all peripheral I/O as well as GPU work — SD card, SIO, USB host (mouse, keyboard), UART,
expansion ports, and FPGA configuration.

---

## 2. Architecture overview

```
6502 (in FPGA)                          STM32N6
@ 165 MHz, 16 MB HyperRAM               @ 800 MHz, 4.2 MB SRAM + 16 MB HyperRAM
┌──────────────────────┐               ┌──────────────────────────┐
│  AES layer           │               │  LVGL + VDI bridge       │
│                      │               │                          │
│  ┌────────────────┐  │  $D4xx regs   │  ┌────────────────────┐  │
│  │ Window manager │──┼──────────────┐│  │ LVGL canvas widget │  │
│  │ (structs, Z,   │  │  write DRAW  ││  │  (full-screen,      │  │
│  │  focus, events)│  │  commands    ││  │   receives all      │  │
│  │                │  │              ││  │   DRAW commands     │  │
│  │  All xtc code  │  │  FPGA snoops ││  │   from PSSI)        │  │
│  │  on 6502       │  │  $D4xx →     ││  │                    │  │
│  │                │  │  PSSI FIFO   ││  │  ┌──────────────┐  │  │
│  │  Generates     │  │              ││  │  │ NeoChrom     │  │  │
│  │  high-level    │  │              ││  │  │ (DMA2D)      │  │  │
│  │  draw commands │  │              ││  │  │ draw unit    │  │  │
│  └────────────────┘  │              ││  │  └──────────────┘  │  │
│                      │  PSSI        ││  │                    │  │
│  ┌────────────────┐  │  (parallel)  ││  │  Framebuffer in    │  │
│  │ FPGA compositor│──┼──────────────┼──┤  │  SRAM (LVGL       │  │
│  │ captures LTDC  │  │  ← LTDC RGB ││  │  display buffer)   │  │
│  │ stream from N6 │  │  + syncs    ││  │                    │  │
│  │                │  │              ││  │  Off-screen        │  │
│  │ → palette LUT  │  │  SPI ↔      ││  │  buffers (HyperRAM)│  │
│  │ → TMDS → HDMI  │  │  (control)  ││  └────────────────────┘  │
│  └────────────────┘  │              ││  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─  │
│                      │  QSPI flash  ││  USB HID (LVGL input)│  │
│  HyperRAM (16 MB)    │  (shared)    ││  LTDC (LVGL display) │  │
│  ┌────────────────┐  │              ││  SPI (ctrl/status)   │  │
│  │ System RAM     │  │              ││  SD card (assets)    │  │
│  │ + Window data  │  └──────────────┘│  SIO, UART, expansion │
│  │ + Fonts        │                  └──────────────────────────┘
│  │ + Bitmaps      │
│  │ + Icons        │
│  └────────────────┘
```

### Data flow for a GEM draw operation

1. **6502** (running xtc AES code) writes command parameters to `$D4E0`–`$D4EF`.
   The FPGA captures each write through its existing bus-snoop pipeline.

2. **FPGA** assembles a DRAW packet and pushes it into the PSSI FIFO, which
   streams it to the STM32N6 over an 8–16-bit parallel source-sync interface.

3. **STM32N6 M55** parses the packet header and calls the corresponding
   LVGL canvas draw function (`lv_canvas_draw_rect`, `lv_canvas_draw_img`,
   etc.). The 6502 never touches LVGL directly — the dispatch loop
   translates DRAW opcodes to LVGL API calls.

4. **LVGL** renders into its display buffer in internal SRAM. NeoChrom
   acceleration is handled transparently by LVGL's DMA2D/NeoChrom draw
   unit — NeoChrom accelerates blit, fill, rotate, and alpha blend where
   possible, falling back to software for unsupported operations.

5. **LTDC** continuously streams the completed framebuffer to the FPGA as
   parallel RGB + syncs at 25–40 MHz pixel clock.

6. **FPGA** captures the LTDC stream, applies the palette LUT, inserts audio
   from the on-fabric POKEY core into TMDS data islands, and drives HDMI.

The key insight: the FPGA never actively fetches the framebuffer. It simply
captures a video stream the N6 is already producing. The scan-out bandwidth
problem (which required the per-cycle PIO FETCH protocol in the RP2354
design) disappears entirely.

---

## 3. Communication paths

### 3.1 PSSI — FPGA → N6 (DRAW commands, bulk data)

Parallel slave receive interface. The FPGA is master (provides clock + data),
the N6's PSSI peripheral captures with deterministic latency.

| Parameter | Value |
|-----------|------:|
| Bus width | 8–16 bits (parallel) |
| Clock | Source-sync from FPGA, up to ~100 MHz |
| Bandwidth | ~100–200 MB/s |
| FPGA pins | 10–18 (data + clock + qualifier) |
| N6 pins | same |

### 3.2 SPI — FPGA ↔ N6 (control / status)

4-wire SPI, FPGA is master, N6 is slave. Carries low-volume control-plane
traffic only.

| Parameter | Value |
|-----------|------:|
| Protocol | SPI mode 0, 8-bit transfers |
| Clock | FPGA-driven, 1–10 MHz |
| Bandwidth | ~1–10 MB/s (vast overkill for ~10 bytes/frame) |
| FPGA pins | 4 (SCK, MOSI, MISO, CS) |
| N6 pins | 4 |

Traffic carried:
- getpixel(x, y) → N6 clocks back pixel value
- Queue depth read (commands pending in PSSI ring)
- Command-complete ack
- VSYNC timestamp
- Status / error flags

### 3.3 LTDC — N6 → FPGA (video stream)

Continuous parallel RGB video output from the N6's LCD-TFT Display Controller.

| Parameter | Value |
|-----------|------:|
| Pixel clock | 25.175 MHz (640×480) / 40 MHz (800×600) / 74.25 MHz (1280×720) |
| Data width | 24-bit RGB888 (LVGL configured `LV_COLOR_DEPTH 24`) |
| Syncs | HSYNC, VSYNC, DE (data enable) |
| FPGA pins | 28 (24 data + 4 sync/clock) |
| N6 pins | same |

The FPGA captures the LTDC stream on dedicated HSIO pins, feeds it through
the palette LUT, and drives the TMDS encoder. Audio from the on-fabric POKEY
core is inserted into HDMI data islands in the blanking intervals.

---

## 4. Voltage domains

The Ti60F256's I/O banks operate at different voltages:

| Bank | Pins | Voltage | Used for |
|------|-----:|--------|----------|
| **HSIO** (top/bottom/right) | 142 | **1.8 V LVCMOS** | PSSI, SPI, LTDC, HyperRAM PHY, HDMI TMDS, 6502 bus (via LVC8T245), joy SPI |
| **HVIO** (left edge) | 27 | **3.3 V LVCMOS** | Remaining 3.3 V peripherals (cart slot, expansion) |

The N6's I/O banks have independent VDDIO domains. PSSI, SPI, and LTDC pins
all sit on banks powered at 1.8 V — the same voltage as the FPGA's HSIO. All
three interfaces are **direct connect, no level translation**:

| Interface | FPGA bank | FPGA voltage | N6 voltage | Translation |
|-----------|-----------|-------------|------------|-------------|
| **PSSI** (10–18 pins) | HSIO | 1.8 V | VDDIO @ 1.8 V | None — direct |
| **SPI** (4 pins) | HSIO | 1.8 V | VDDIO @ 1.8 V | None — direct |
| **LTDC** (28 pins) | HSIO | 1.8 V | VDDIO @ 1.8 V | None — direct |

At 1.8 V LVCMOS, the N6's I/O timing comfortably meets PSSI at 100 MHz,
LTDC at up to 88 MHz, and SPI at 1–10 MHz.

**BOM saving:** The RP2354 variant needed 4× LVC8T245 for FPGA↔RP level
translation (~$1.20 + board area). The N6 variant eliminates all of them.

**Caveat:** Verify the N6's pad supply assignments against the chosen package.
The N655 (264-ball BGA) has multiple VDDIO domains; PSSI, SPI, and LTDC
must be placed on banks powered by 1.8 V.

---

## 5. FPGA configuration — cached QSPI flash + SD card

The N6 boots from SD card (its boot ROM supports SDMMC directly). The FPGA
bitstream lives on the same SD card as a file. A small QSPI NOR flash caches
the bitstream so the FPGA can boot autonomously without waiting for the SD
card filesystem to initialise.

### Wiring

```
QSPI Flash                    FPGA Ti60              N6 SPI5
   ┌──────┐                 ┌──────────┐          ┌─────────┐
   │ CS#  ├─────────────────┤ SSL_N    │          │         │
   │ CLK  ├────22Ω──────────┤ CCK      │    ───── │ SCK     │
   │ DQ0  ├────22Ω──────────┤ CDI0     │    ───── │ MOSI    │
   │ DQ1  ├────22Ω──────────┤ CDI1     │    ───── │ MISO    │
   │ DQ2  ├──┬─22Ω──────────┤ CDI2     │          │ (unused)│
   │      │  │              │          │          │         │
   │      │ ─┴─ 10KΩ ─ VCC  │ (WP# pull-up)       │         │
   │ DQ3  ├──┬─22Ω──────────┤ CDI3     │          │ (unused)│
   │      │  │              │          │          │         │
   │      │ ─┴─ 10KΩ ─ VCC  │ (HOLD# pull-up)     │         │
   └──────┘                 └──────────┘          └─────────┘
```

- **22 Ω series resistors** on all shared lines for signal integrity
- **10 KΩ pull-ups** on DQ2 and DQ3 to hold WP# and HOLD# inactive when the
  flash is in 1-bit SPI mode
- The N6 drives only SCK, MOSI, and MISO (3 of 4 QSPI lines). DQ2 and DQ3
  are unused by the N6 — they stay high-Z with pull-ups active.
- No analogue mux or buffer needed. During FPGA boot the N6's GPIOs default
  to input (high-Z), so the FPGA drives the bus uncontested. After CDONE the
  FPGA releases its config pins, and the N6 can talk to the flash.

### Boot sequencing

The N6 handles all power sequencing — the FPGA never attempts autonomous
boot. /CRESET_N and all FPGA config pins are held in a known state by the
N6 until it decides to release them.

```
1. Power-up: N6 powers on. FPGA held in reset (/CRESET_N low, driven by
   N6 GPIO). All FPGA config pins are high-Z (N6 GPIOs default to input).

2. N6 boot ROM loads firmware from SD card (SDMMC boot partition).
   If no SD card or corrupted image → fall back to QSPI flash for
   last-known-good N6 firmware (optional — requires a small bootloader
   stored there alongside the FPGA bitstream).

3. N6 firmware starts. It reads `fpga.bit` from the SD card filesystem
   and checks the version field against the bitstream cached in QSPI flash.

4. If the SD card bitstream is newer (or flash is empty/corrupt):
   N6 drives SPI5 pins as outputs, programs the QSPI flash with the new
   bitstream → verifies → sets version tag.
   (FPGA is still in reset — no contention.)

5. N6 releases /CRESET_N (GPIO → high).

6. Ti60 loads bitstream from QSPI flash autonomously (4-bit QSPI, ~50 ms).
   N6 GPIOs on the shared lines are high-Z during this phase.

7. CDONE asserts. FPGA config pins → high-Z.

8. System is live — 6502 starts running AES code. N6 begins DRAW dispatch
   and peripheral initialisation (SD card filesystem for assets, USB
   calibration, SPI link to FPGA for control/status).
```

**Total cold boot time:** ~500 ms–1 s (SD card init + filesystem mount +
optional flash reprogram + FPGA boot). Subsequent reboots skip step 4
(version matches the cached bitstream) and take ~100 ms.

The critical property: the FPGA never sees a partially-written bitstream
or an unstable power rail. The N6 controls the entire bring-up sequence
and only releases reset when the flash is ready.

### Field upgrades

An upgrade is a file copy:

1. User copies `firmware.bin` and `fpga.bit` to SD card on their PC.
2. Insert card, power cycle.
3. N6 boots from SD, detects newer bitstream, reprograms QSPI flash.
4. FPGA boots from updated bitstream.

No special tools, no JTAG, no USB cable. Downgrades work the same way
(version comparison is monotonic — re-flash if different).

---

## 6. N6 peripheral map

The STM32N655 (264-ball BGA, 0.8 mm pitch) absorbs all peripheral functions.
Fully configured:

| Peripheral | Pins | Notes |
|-----------|-----:|-------|
| **LTDC** (to FPGA) | 28 | RGB24 + HSYNC + VSYNC + DE + PCLK. 1.8 V HSIO bank. |
| **PSSI** (to FPGA) | 10–18 | 8-bit or 16-bit + clock + qualifier. 1.8 V HSIO bank. |
| **SPI** (to FPGA, control) | 4 | SPI5, FPGA is master. 1.8 V HSIO bank. |
| **QSPI flash** (shared) | 3 | SPI5 pins SCK+MOSI+MISO, 3.3 V (flash VCC). 22 Ω series resistors. |
| **SDMMC** (SD card) | 6 | 4-bit SD + CLK + CMD. 3.3 V bank. |
| **SIO** | 6 | Serial I/O (Atari SIO protocol). GPIO bit-banged or UART. 3.3 V. |
| **USB host** (integrated PHY) | 2 | USB DP/DN. Mouse + keyboard via HID. No external PHY needed. 3.3 V. |
| **Expansion port 1** | 5 | SPI + UART (to external cartridge/dev board). 3.3 V. |
| **Expansion port 2** | 5 | SPI + UART (second expansion). 3.3 V. |
| **UART (debug)** | 2 | TX + RX, 3.3 V. |
| **HyperRAM XSPI** | 12 | 8-bit HyperBus, **16 MB external HyperRAM** for N6-local bulk storage (off-screen buffers, font caches, icon atlases). 1.8 V. |

**Total I/O used: ~83–91 pins.** The N655X0HxQ has ~168 GPIO, leaving
substantial headroom for future expansion.

Mouse and keyboard are USB HID devices connected to the N6's integrated USB
host. The N6 forwards mouse position and key events to the 6502 via the SPI
control channel. Legacy Atari joysticks remain connected to the FPGA (via
the PCAL9722 SPI GPIO expander already in the design) for compatibility with
original software running under the ANTIC compositor.

---

## 7. DRAW command set

The 6502 issues drawing commands via `$D4E0–$D4EF` register writes. The FPGA
captures them, assembles a structured packet, and pushes it over PSSI to
the N6.

| Opcode | Mnemonic | Params | NeoChrom mapping |
|--------|----------|--------|-----------------|
| `$01` | SET_PIXEL | x, y, colour | Write framebuffer byte |
| `$02` | GETPIXEL | x, y | SPI round-trip → result in `$D4EB` |
| `$03` | DRAW_LINE | x1, y1, x2, y2, colour | NeoChrom line engine or software Bresenham |
| `$04` | DRAW_RECT | x, y, w, h, fill_colour | Hardware fill (register write) |
| `$05` | FILL_RECT | x, y, w, h, colour | Hardware fill (register write) |
| `$06` | BLIT | src_x, src_y, dst_x, dst_y, w, h | NeoChrom blitter (register write) |
| `$07` | BLIT_FROM_HYPERRAM | dst_addr, len | FPGA streams pixels over PSSI → DMA to SRAM |
| `$08` | DRAW_TEXT | x, y, font_id, char, colour | NeoChrom text engine or glyph blit |
| `$09` | DRAW_TEXT_STRING | x, y, font_id, str_len, colour | String of glyphs |
| `$0A` | FILL_CIRCLE | cx, cy, r, colour | Software raster (no NeoChrom circle hw) |
| `$0B` | DRAW_CIRCLE | cx, cy, r, colour | Software raster |
| `$0C` | SET_CLIP | x, y, w, h, enable | NeoChrom scissor rect register |
| `$0D` | ALPHA_BLEND | src_addr, dst_addr, w, h, alpha | NeoChrom alpha blend engine |
| `$0E` | ROTATE_90 | src_addr, dst_addr, w, h | NeoChrom rotation engine |
| `$80` | HW_CURSOR_SET | x, y, shape_addr | FPGA hardware cursor registers |
| `$81` | HW_CURSOR_MOVE | dx, dy | FPGA hardware cursor (no PSSI needed) |
| `$FF` | NOP | — | No-op (alignment padding) |

Fixed-length ops (most of the above) need only opcode + params + commit
strobe. Variable-length ops (BLIT_FROM_HYPERRAM, DRAW_TEXT_STRING) also
require the `GEM_LENGTH` register.

---

## 8. $D4xx register map

Reserved in the FPGA's chiplet-extension window ($D480–$D4FF):

```
$D4E0  GEM_OPCODE      (W)  8-bit opcode
$D4E1  GEM_COMMIT      (W)  write strobe — assembles + queues the packet
$D4E2  GEM_P0_LO       (W)  parameter 0 low byte
$D4E3  GEM_P0_HI       (W)  parameter 0 high byte
$D4E4  GEM_P1_LO       (W)  parameter 1 low byte
$D4E5  GEM_P1_HI       (W)  parameter 1 high byte
$D4E6  GEM_P2          (W)  parameter 2 (8-bit)
$D4E7  GEM_FLAGS       (W)  flags (clip enable, blend mode, layer select)
$D4E8  GEM_LENGTH      (W)  payload length for variable-length ops; 0 = fixed-length
$D4E9  GEM_RESERVED    (W)  —
$D4EA  GEM_STATUS      (R)  status byte (queue depth bits 0-5, overflow bit 6)
$D4EB  GEM_RESP_DATA   (R)  response data byte (getpixel value, ack code)
$D4EC–$D4EF reserved
```

Fixed-length ops: 6502 writes opcode + params + flags, then strobes COMMIT.
The FPGA looks up the expected param count from the opcode table and
assembles a fixed-size packet. GEM_LENGTH is ignored (stays 0).

Variable-length ops (BLIT_FROM_HYPERRAM, TEXT_STRING): 6502 writes opcode +
params + length + flags, then strobes COMMIT. The FPGA reads `length` bytes
from HyperRAM (for BLIT_FROM_HYPERRAM) or the 6502's subsequent register
writes (for short strings) and appends them as packet payload.

---

## 9. PSSI wire format

Every PSSI packet starts with a 4-byte header that the M55 dispatch loop
uses to classify the command and determine the total packet length:

```
Byte 0:       opcode
Byte 1:       flags
Bytes 2-3:    payload_length (16-bit little-endian; 0 = fixed-length)
Bytes 4..k:   opcode-specific params (fixed per opcode table)
Bytes k+1..:  variable-length payload (present iff payload_length > 0)
```

The M55 dispatch loop:
1. Reads byte 0 → opcode
2. Reads bytes 2-3 → payload_length
3. Advances ring buffer pointer by `4 + payload_length` bytes
4. Executes command (write NeoChrom registers, set up DMA, etc.)

This length-driven parsing is essential for variable-length ops like
BLIT_FROM_HYPERRAM, where the N6 needs to know where one command ends and
the next begins in the PSSI ring buffer.

---

## 10. Memory budget

The N6 has two memory tiers:

- **Internal SRAM** (4.2 MB on N655): LTDC must read the active
  framebuffer from SRAM. This is the critical fast tier.
- **External HyperRAM** (16 MB via XSPI): bulk storage for off-screen buffers,
  font caches, icon atlases, PSSI ring buffer. Slower than SRAM but still fast
  enough for background data.

Only the active framebuffer(s) occupy SRAM; everything else lives in HyperRAM.

### SRAM allocation

Framebuffers are RGB888 (3 bytes/pixel) to match LVGL's
`LV_COLOR_DEPTH 24` configuration.

| Region | Size | Notes |
|--------|-----:|-------|
| **Framebuffer 0** (front) | 900 KB | 640×480 RGB888. LTDC reads from here. |
| **Framebuffer 1** (back) | 900 KB | NeoChrom renders here while LTDC scans out FB0. |
| **Firmware + stack** | 512 KB | M55 dispatch loop, device drivers, NeoChrom driver. |
| **PSSI DMA ring** | 16 KB | Command FIFO (in SRAM for zero-wait dispatch). |
| **FMC RPC mailbox buffers** | 16 KB | Inbound/outbound FIFO staging. |
| **SPI event buffer** | 1 KB | Event payload staging. |
| **Total SRAM used** | **2,345 KB** | |
| **Free SRAM** | **~1,855 KB** (N655: 4.2 MB) | Spare for additional buffers, app data, off-screen surfaces. |

At 640×480 RGB888 double-buffered, SRAM still has ~1.8 MB headroom.
At 800×600 RGB888 DB (~2.8 MB framebuffers) headroom drops to ~700 KB.
At 1280×720 RGB888 DB (~5.4 MB framebuffers) the double-buffer exceeds
SRAM — single-buffer in SRAM is fine; double-buffer requires the back
buffer in HyperRAM with verified bandwidth budget.

### HyperRAM allocation (16 MB, shared)

| Region | Size | Notes |
|--------|-----:|-------|
| **Off-screen window buffers** (200 × 100×100) | 2,000 KB | One per window. Blit to framebuffer is a NeoChrom register write. |
| **Font cache** (4 typefaces × 128 KB) | 512 KB | Proportional fonts, multiple sizes. |
| **Icon cache** (128 icons × 64×64) | 512 KB | System icons, app icons. |
| **Desktop wallpaper / background** | 900 KB | One full framebuffer-sized image at 640×480 RGB888. |
| **Application scratch** | ~6.4 MB | Temporary surfaces, loaded assets. |
| **NeoChrom GPU DMA buffers** | ~1 MB | Intermediate render targets for layered compositing. |
| **Free** | ~5.3 MB | |
| **Total** | **16,000 KB** | |

The N655's 4.2 MB SRAM accommodates RGB888 double-buffering at 640×480
(900 KB × 2 = 1,800 KB) with ~1.9 MB free for firmware, stacks, and
scratch. At 800×600 RGB888 DB (2,880 KB) headroom is tighter (~800 KB
free). At 1280×720 the framebuffer drops to RGB565 (1,800 KB × 2 =
3,600 KB DB) so it still fits in SRAM with ~600 KB headroom. LVGL is
compiled once at `LV_COLOR_DEPTH 24` for all modes; the display flush
callback converts 24→16 only when the active framebuffer is 16-bit.
LTDC is configured per-mode to scan-out either RGB888 or RGB565. The
16 MB HyperRAM is the primary backing store for bulk graphics data.

---

## 11. LVGL + NeoChrom

LVGL handles all drawing on the N6 side. The full-screen canvas widget
receives DRAW commands translated from the PSSI stream. LVGL's built-in
draw unit architecture automatically uses NeoChrom (via the DMA2D driver)
for accelerated operations and falls back to software for everything else:

| Operation | Without NeoChrom (M55 software) | With NeoChrom | Δ |
|-----------|-------------------------------:|--------------:|--:|
| **BLIT** (32×32 icon) | ~500 cycles | **1 register write** | ~500× |
| **FILL_RECT** (200×200) | ~40,000 cycles | **1 register write** | ~40,000× |
| **Alpha blend** (per pixel) | ~5 cycles | **0 cycles** (pipeline) | Free |
| **90° rotate** | ~2 cycles/pixel | **0 cycles** (hardware) | Free |
| **Full-screen composite** (5 layers) | ~3 ms | **~0.1 ms** | ~30× |

Key benefit: **no NeoChrom register-level code to write.** LVGL's DMA2D
draw unit already knows the NeoChrom register set. Enabling acceleration
is a configuration option in the LVGL port — the draw unit probes the
hardware at init and routes operations accordingly. The M55 dispatch loop
just calls `lv_canvas_draw_*` functions and LVGL decides whether the
hardware handles it.

LVGL also handles:
- **USB HID input** — mouse and keyboard via the N6's integrated USB host
  PHY, routed to LVGL's input group
- **Font rendering** — built-in, anti-aliased, no custom font engine needed
- **Display buffering** — partial update or double buffering, whichever is
  configured in the LVGL display driver

The LTDC itself is configured separately via STM32 HAL (CubeMX-generated
code): clock tree, PLL pixel clock, pin mux, timing parameters (H/VPW,
H/VBP, H/VFP), and layer DMA. LVGL receives the already-initialised display
timing and framebuffer address. This is the standard STM32 + LVGL pattern —
LVGL never touches LTDC registers directly.

---

## 12. LTDC synchronisation

The LTDC (LCD-TFT Display Controller) is an STM32 peripheral that reads a
framebuffer from SRAM and outputs a continuous parallel RGB video stream.

### Shared pixel clock (recommended)

The FPGA generates `pix_clk` from its internal PLL and feeds it to the N6's
LTDC as its pixel clock input. Both sides use the same clock edge. The FPGA's
ANTIC core counts lines from the same pix_clk divider that drives the LTDC's
H/V counters.

```
FPGA PLL ──pix_clk──→ STM32N6 LTDC PCLK input
                 │
                 └──→ FPGA video timing generator
                        (line counter, VBI generation)
```

### Free-running with line FIFO (fallback)

Both sides run at 60 Hz from independent clocks. The FPGA captures LTDC output
into a small line FIFO (2–4 scanlines). As long as the average rate matches,
the FIFO never underflows. VBI fires from the FPGA's internal timing.

---

## 13. Resolution

| Mode | Pixel clock | Framebuffer (8-bit) | Notes |
|------|-----------:|--------------------:|-------|
| 640×480 @ 60 Hz | 25.175 MHz | RGB888: 900 KB / 1.8 MB DB | Default — comfortable in 4.2 MB SRAM |
| 800×600 @ 60 Hz | 40 MHz | RGB888: 1.4 MB / 2.8 MB DB | DB fits with ~800 KB headroom |
| 1280×720 @ 60 Hz | **74.25 MHz** | RGB565: 1.8 MB / 3.6 MB DB | **Native ceiling** — N6 LTDC max 88 MHz. RGB888 DB (5.4 MB) exceeds SRAM, so this mode uses RGB565; LVGL stays at `LV_COLOR_DEPTH 24` and the flush callback converts 24→16. Slight gradient banding; UI colours unaffected. |

For 4:3 resolutions above 640×480 (e.g., 1280×960): the FPGA nearest-neighbour-
doubles from a 640×480 base. The N6 renders at 640×480; the FPGA repeats each
pixel once horizontally and each scanline once vertically during scan-out. This
costs ~40 LUTs and a single line buffer in BlockRAM. No software changes are
needed on the 6502 or N6 side.

---

## 14. Timeline

| Phase | Effort | Notes |
|-------|-------:|-------|
| **PSSI master HDL** (in FPGA) | 1 week | 8–16-bit parallel TX with source-sync clock. FIFO interface to existing $D4xx snoop. |
| **SPI master HDL** (in FPGA) | 0.5 week | Simple state machine, ~50 LUTs. Initiates transactions on register read. |
| **LTDC capture HDL** (in FPGA) | 1 week | Parallel RGB input + sync capture. Feeds into TMDS encoder pipeline. |
| **PSSI RX + DMA** (on N6) | 1 week | Configure PSSI peripheral, DMAMUX, ring buffer. |
| **SPI slave** (on N6) | 0.5 week | SPI slave interrupt handler. Minimal — ~10 bytes/frame. |
| **LTDC init** (HAL) | 0.5 week | CubeMX: clock tree, PLL, pin mux, timing, layer DMA. Standard STM32 work. |
| **LVGL port** | 1.5 weeks | Canvas widget, USB HID input, NeoChrom draw unit enable. Display is pre-configured LTDC. |
| **N6 firmware framework** | 1 week | CubeMX project, SD card filesystem, boot sequencing. |
| **DRAW-to-LVGL bridge** | 1 week | Translate PSSI opcodes to `lv_canvas_draw_*` calls. |
| **AES layer (xtc on 6502)** | 4–6 weeks | Window manager, event router, control library, desktop. |
| **Integration + debug** | 2 weeks | FPGA↔N6 link bring-up. PSSI timing. LTDC capture alignment. |

**Total: ~13–17 weeks** (roughly 3-4 months). LVGL eliminates the raw
NeoChrom register integration — the DMA2D draw unit handles acceleration
transparently once enabled.

---

## 15. Open questions

These need hardware-level answers before the design can be finalised:

### 15.1 LVGL porting

The M55 dispatch loop translates DRAW opcodes to LVGL canvas API calls.
This is straightforward for simple primitives (fill rect, blit, text) but
requires attention for:

- **Canvas widget performance:** LVGL's canvas widget is pixel-addressable
  but not optimised for bulk DRAW command streams. Verify that calling
  `lv_canvas_draw_rect` in a tight loop from the PSSI dispatch does not
  introduce unacceptable overhead. If it does, batch multiple DRAW commands
  into a single LVGL rendering pass per frame.
- **Colour format:** LVGL is compiled at `LV_COLOR_DEPTH 24` (RGB888,
  3 bytes/pixel) for all modes. The 6502 sends 8-bit indexed colour
  commands; the dispatch loop expands indices via palette LUT to RGB888
  before calling LVGL. LUT expansion is a few cycles per pixel —
  negligible for GUI loads. At 1280×720 the framebuffer format drops to
  RGB565 (to fit a double-buffer in the 4.2 MB SRAM); the LVGL display
  flush callback converts 24→16 on the way out. LTDC is configured
  per-mode to scan-out either format natively.

### 15.2 PSSI DMA ring buffer sizing

The PSSI ring buffer in N6 SRAM needs to absorb bursts from the FPGA without
overflowing. The FPGA's DRAW FIFO (in fabric, small) back-pressures the 6502
via /RDY when full. The N6 ring buffer should be sized to handle worst-case:
256 DRAW commands × 64 bytes each = 16 KB (current budget). Verify against
real workload once the 6502 AES code is written.

### 15.3 SD card failure behaviour

The N6 boots from SD card. If the card is missing, corrupted, or the
filesystem is unreadable, the system cannot boot. Mitigations:

a) **Last-known-good cache:** Keep a copy of the N6 firmware in the QSPI
   flash (a small bootloader region). The N6's boot ROM can fall back to
   QSPI if SD card boot fails. The FPGA bitstream is already cached there.
b) **Dedicated recovery flash:** A small (8 MB) QSPI flash with a minimal
   firmware image that can load from USB or re-initialise the SD card.
   This is what the N6's built-in boot ROM supports natively — no
   additional hardware needed.
c) **Accept the risk:** For a desktop computer, swapping SD cards is
   trivial. The FPGA still boots from its cached bitstream even without
   the SD card — the 6502 and ANTIC come up, just the N6 graphics and
   peripherals are offline. The system can show a "NO SD CARD" screen
   via ANTIC-mode display.

Option (c) is worth noting: because the FPGA boots autonomously from QSPI
flash, the 6502 runs regardless of the SD card state. Only the N6 graphics
and peripheral functions are missing.

### 15.4 Mouse resolution (solved)

USB HID mouse via the N6's integrated USB host. Standard mice report at
1/800 inch or finer — at 640×480 that's sub-pixel precision. The N6 forwards
absolute (or delta-accumulated) position to the 6502 via the SPI control
channel. No analog POT path needed for GUI operation.

Legacy analog joysticks remain on the FPGA for Atari software compatibility,
but are not used by GEM.

---

## Appendix: Existing infrastructure that GEM reuses

| Component | Already exists | GEM reuse |
|-----------|---------------|-----------|
| FPGA 6502 core | ✅ Arlet SALLY in fabric | Runs AES code |
| FPGA bus snoop | ✅ Snoop pipeline for ANTIC | Snoops $D4E0 writes for DRAW commands |
| FPGA $D4xx register decode | ✅ ANTIC register file | Decodes $D4E0–$D4EF for GEM |
| FPGA HyperRAM controller | ✅ HyperRAM IP | Reads bitmap source data for BLIT ops |
| FPGA TMDS scan-out | ✅ HDMI pipeline | Unmodified (now fed from LTDC capture) |
| FPGA compositor | ✅ ANTIC playfield+charset+PM | Extended for GEM fullres mode + LTDC input |
| FPGA palette LUT | ✅ 256-entry, 24-bit RGB | Standard GEM palette |
| FPGA /NMI generation | ✅ VBI, DLI | VBI timer for events |
| N6 USB host | ✅ Integrated PHY | USB HID mouse + keyboard forward to 6502 via SPI |
| N6 SPI (mouse forward) | — | N6 sends mouse/keyboard state to 6502 over SPI control channel |
| 6502 HyperRAM access | ✅ Through FPGA controller | Window data structures |
