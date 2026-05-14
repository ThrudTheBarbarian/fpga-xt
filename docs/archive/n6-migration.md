# N6 migration — RP2354 framebuffer → STM32N6 graphics co-processor

## What changed

The earlier rp-XT design used a **paired RP2354** as smart video RAM: it held
the framebuffer in its 520 KB SRAM, served per-cycle FETCH requests from the
FPGA over a bidirectional PIO bus, and ran VDI drawing primitives in software
on its second core.

The STM32N6 replaces this paired RP2354 entirely. It also absorbs the
**peri-RP** (the separate RP2354 that handled SD card, SIO, POTs, and FPGA
configuration). There are no RP2354s in the video or peripheral path — the N6
handles everything.

## High-level architecture

```
6502 (in FPGA Ti60)                    STM32N655
@ 165 MHz modern / 1.79 MHz legacy     @ 800 MHz, 4.2 MB SRAM + 16 MB HyperRAM
16 MB HyperRAM                         
       │                                        │
       │  DRAW commands + bulk pixel uploads    │
       │ ─────────────────────────────> PSSI    │
       │   (18 pins, FPGA→N6, ~150 MB/s)        │
       │                                        │
       │  RPC, filesystem, getpixel, status     │
       │ <───────────────────────────── FMC     │
       │   (19 pins, N6 master; bulk N6→FPGA,   │
       │    small reads back; 256-byte address  │
       │    space, ~30–50 MB/s)                 │
       │                                        │
       │  Event payload pull (post-IRQ)         │
       │ <───────────────────────────── SPI     │
       │   (4 pins, FPGA master)                │
       │                                        │
       │  Out-of-band event signaling           │
       │ <───────────────────────────> IRQ × 4  │
       │   (2 each direction; HP=real-time,     │
       │    LP=status/deferred)                 │
       │                                        │
       │  Continuous video stream               │
       │ <───────────────────────────── LTDC    │
       │   (28 pins, N6→FPGA, 25–74 MHz)        │
       │                                        │
       │  LVGL canvas widget ← DRAW dispatch    │
       │  NeoChrom + DMA2D (LVGL draw units)    │
       │  LTDC display output                   │
       │  USB HID mouse + keyboard              │
       │  SD card boot + asset storage          │
```

## Channels between FPGA and N6

The old bidirectional PIO bus (FETCH/SET/DRAW, 44 pins, 3.3 V, needed
4× LVC8T245 level translators) is replaced by four data channels plus
two event-signalling GPIOs. All run at **1.8 V** — direct connect, no
level translation:

| Channel | Direction | Pins | Bandwidth | Purpose |
|---------|-----------|-----:|----------|---------|
| **PSSI** | FPGA → N6 | 18 | ~150–155 MB/s sustained (160 theor.) @ 80 MHz | DRAW commands, bulk pixel uploads |
| **FMC** | N6 → FPGA (bulk); FPGA → N6 (small) | 19 | ~30–50 MB/s sustained @ 100 MHz | RPC, filesystem, getpixel, status (8-bit data, 8-bit address — full memory-mapped peripheral) |
| **SPI** | FPGA master, reads N6 | 4 | ~1.5 MB/s @ 25 MHz | Event payload pull, post-IRQ |
| **LTDC** | N6 → FPGA | 28 | 25–74 Mpix/s | Continuous video stream |
| **Event IRQs** | bidir, 2+2 GPIO | 4 | — | Out-of-band async wake-up with HP/LP priority split each direction |

Channel roles split by traffic class:

- **PSSI** is the high-rate forward path (DRAW stream + bulk N6-bound bitmap uploads).
- **FMC** is the memory-mapped RPC bus and the reverse bulk path (file reads,
  getpixel results, status). N6 is master; the FPGA presents a 256-byte
  address space mixing FIFO endpoints and byte-addressable status / control
  registers (see [FMC mailbox map](#fmc-mailbox-map) below).
- **SPI** carries small async event payloads. The N6 raises its event-IRQ
  GPIO; the FPGA edge-detects and pulls the event payload over SPI at its
  convenience. Keeps async event traffic *off* the FMC bus.
- **LTDC** is one-way scan-out, captured by the FPGA. Free bandwidth.
- **Event IRQs** are four single-bit GPIO lines — two each direction. The
  pair structure carries priority/QoS information without needing a status
  register dispatch:
  - **FPGA → N6 (HP)**: RPC request pending (6502 blocked, latency-sensitive)
  - **FPGA → N6 (LP)**: Status change, error flag, deferred notification
  - **N6 → FPGA (HP)**: User input event (USB HID), RPC response ready
  - **N6 → FPGA (LP)**: System status, non-blocking notification

The FPGA never actively fetches the framebuffer — it captures whatever the
N6's LTDC sends. Scan-out bandwidth is free.

## FMC mailbox map

FMC exposes 8 address bits (`A[7:0]`), 8 data bits, and independent /OE
(read) and /WE (write) strobes. The FPGA presents a **256-byte
memory-mapped address space** containing a mix of FIFO endpoints (for
streaming bulk and RPC traffic) and byte-addressable status / control
registers. Each (address, direction) pair has its own behaviour
selected by the FPGA-side decoder.

FIFO endpoints behave as streams: the N6 issues repeated reads or
writes to a fixed FIFO address and the FPGA's internal FIFO pointer
advances on each /CS-qualified strobe. The N6's source/destination
buffer pointer advances, but the FMC address is held constant for the
whole transfer.

This is the Linux kernel `iowrite8_rep` / `ioread8_rep` idiom for FIFO
addresses (ARM equivalent: a tight loop with the FMC address pinned).
**Not** `memcpy` — memcpy advances both source and destination and
would step across the FIFO address, corrupting the protocol.

Byte-addressable registers (status, control, scratch) behave like real
memory — the N6 reads or writes individual bytes at their addresses
without FIFO semantics. From N6 software:
`*(volatile uint8_t *)(FMC_BASE + 0x12)` reads status byte 0x12
directly.

### Address allocation

| Address | Dir | Behavior | Role |
|--------:|-----|----------|------|
| `0x00` | W | FIFO | **Bulk outbound** — N6 writes file content / generated bytes (destined for 6502 HyperRAM) |
| `0x00` | R | FIFO | **Bulk inbound** — N6 reads framebuffer regions / file-write content from FPGA-staged buffers |
| `0x01` | W | FIFO | **RPC reply** — N6 writes syscall results / RPC responses destined for 6502 |
| `0x01` | R | FIFO | **RPC request** — N6 reads 6502-originated syscall requests captured by FPGA |
| `0x02–0x07` | W/R | FIFO | Reserved bulk channels (future: font cache stream, icon atlas, glyph upload, etc.) |
| `0x10–0x1F` | R | byte reg | **Status registers** — FIFO fill levels, error flags, request-pending bits, hardware status |
| `0x10–0x1F` | W | byte reg | **Control registers** — mode bits, FIFO reset, IRQ enables/masks |
| `0x20–0x3F` | R/W | byte reg | **Command-parameter scratch** — 32-byte scratchpad for assembling complex commands without FIFO discipline |
| `0x80` | R | byte reg | **HP IRQ source bitmap** — pending FPGA→N6 high-priority sources |
| `0x80` | W | byte reg | **HP IRQ ack** — write 1s to ack those source bits (see [IRQ semantics](#irq-source-semantics) below) |
| `0x81` | R | byte reg | **LP IRQ source bitmap** — pending FPGA→N6 low-priority sources |
| `0x81` | W | byte reg | **LP IRQ ack** — write 1s to ack those source bits |
| `0x82–0x83` | R/W | byte reg | Reserved (future: per-source priority masks, IRQ test/debug) |
| `0x84` | R | byte reg | **VBI tick counter** — saturating count of VBIs since last ack |
| `0x85` | R | byte reg | **PSSI fault counter** — count of stream faults since last ack |
| `0x86` | R | byte reg | **PSSI fault detail** — code identifying most-recent fault type |
| `0x87–0x8F` | reserved | — | Future per-source counters / detail registers |
| Other | — | reserved | Reserved for future expansion |

### IRQ source bitmaps

Each IRQ line carries multiple possible event types; the source bitmap
lets the N6 ISR identify *which* sources are pending without losing
coincident events. Bits stay set until the N6 acks them by writing 1s
to the corresponding ack register. The IRQ line de-asserts when all
source bits in that line's bitmap are 0.

**HP IRQ (FPGA → N6), source bits at `0x80`:**

| Bit | Source | Meaning |
|----:|--------|---------|
| 0 | RPC_REQUEST | Non-empty FIFO at 0x01 R; 6502 issued a syscall |
| 1 | BULK_IN_AVAIL | Non-empty FIFO at 0x00 R; FPGA has data to push |
| 2 | SCRATCH_READY | 6502 finished writing parameter block at 0x20–0x3F |
| 3 | PSSI_FAULT | Unknown opcode or parse error in DRAW stream |
| 4 | HALT_PENDING | 6502 stalled awaiting RPC reply (deadline hint) |
| 5–7 | reserved | — |

**LP IRQ (FPGA → N6), source bits at `0x81`:**

| Bit | Source | Meaning |
|----:|--------|---------|
| 0 | STATUS_CHANGE | A status register's value changed |
| 1 | ERROR_FLAG | Soft error needing attention but not blocking |
| 2 | VBI_TICK | 60 Hz N6-side scheduling wake-up (if used) |
| 3 | MODE_CHANGE | FPGA mode bit flipped (e.g., legacy ↔ modern 6502 clock) |
| 4 | RING_THRESHOLD | PSSI DRAW ring crossed N% full (back-pressure hint) |
| 5–7 | reserved | — |

The symmetric N6 → FPGA direction uses two FPGA-internal source
registers (not FMC-addressable — the FPGA is the receiver here). The
N6 sets bits by writing to dedicated control registers; the FPGA
clears them on service.

**HP IRQ (N6 → FPGA), source bits (FPGA-internal):**

| Bit | Source | Meaning |
|----:|--------|---------|
| 0 | HID_EVENT | USB HID event ready; FPGA pulls via SPI |
| 1 | RPC_RESPONSE | RPC reply ready; release 6502 /HALT, return data |
| 2 | FILE_OP_DONE | Block read / write completed |
| 3–7 | reserved | — |

**LP IRQ (N6 → FPGA), source bits (FPGA-internal):**

| Bit | Source | Meaning |
|----:|--------|---------|
| 0 | SYS_NOTIFY | Non-blocking system notification |
| 1 | N6_ERROR | N6 firmware error or restart notice |
| 2 | SD_STATUS | SD card insert / remove / mount-state change |
| 3–7 | reserved | — |

### IRQ source semantics

The IRQ line is **level-sensitive** on the OR of all source bits — it
stays asserted as long as any source bit is set. This eliminates the
"missed coincident event" race that an edge-triggered design would
suffer. Source bits fall into three patterns depending on what they're
modelling:

**Pattern L — level-sensitive on underlying state** (FIFO-backed
sources). The bit reflects the *current* state of something, not the
moment of an event. Used for: RPC_REQUEST, BULK_IN_AVAIL,
HALT_PENDING.

- Bit value = combinational function of the underlying state (e.g.
  `bit = (FIFO_count > 0)`).
- "Ack" writes 1 to the bit, which **does not unconditionally clear
  it** — it tells the FPGA "I've serviced what I saw; re-evaluate".
  The FPGA then recomputes the bit from current state. If the
  underlying condition is still true (FIFO refilled while N6 was
  servicing), the bit stays / re-asserts and the IRQ fires again.
- N6 takes a possibly-extra ISR entry, but no event is ever lost.

**Pattern S — sticky bit, count register** (rate-significant events).
The bit gets set on first event since last ack; a separate counter
register increments per event. Used for: VBI_TICK (counter at 0x84),
PSSI_FAULT (counter at 0x85, most-recent-detail at 0x86).

- Reading the source bitmap and the counter in the same ISR pass tells
  N6 *both* "there are pending events" *and* "how many".
- Ack clears the bit and zeroes the counter atomically.
- Counter saturates at 0xFF (subsequent events don't wrap to 0; N6
  knows "≥255 occurred").

**Pattern A — sticky bit, no counter** (state-pointer events). The bit
just signals "look at another register for details". Used for:
STATUS_CHANGE, ERROR_FLAG, MODE_CHANGE, SD_STATUS, SYS_NOTIFY,
N6_ERROR.

- Coincident events of the same type coalesce — the bit just stays
  set. N6 reads the relevant detail register(s) for current state.
- Ack clears the bit; the bit re-asserts on the *next* event.

### Atomic ordering rules

To keep the protocol race-free, the FPGA and N6 each follow a strict
visibility ordering:

**FPGA when raising an event:**
1. Write the event data to its FIFO / detail register / underlying state
2. *Then* update the source bit (combinational/latched from current state)
3. IRQ line re-evaluates (OR of all source bits) and asserts if any bit set

**N6 when servicing:**
1. Read the source bitmap (atomic snapshot)
2. *Then* read / drain the event data (FIFO, counter, detail register)
3. *Then* write the ack

This ordering guarantees: **if a bit is set, all corresponding event
data is visible to the N6**; if data is invisible, the bit is clear.
Without this ordering, the N6 could see "bit set, FIFO empty" and
either spin-wait (wasting cycles) or ack-and-miss (losing the event).

FPGA-side state machine: decode `A[7:0] + /CS + (/OE | /WE)` into "this
address falls in range X, behaves as FIFO/register Y, advance pointer
or present/latch byte." Roughly twice the address-decode LUTs of the
earlier 2-bit design — still a small block (~200 LUTs).

The status / control / scratch register layout is purely a software
contract; bit assignments can change without RTL changes as long as
the decoder ranges stay consistent.

## Key component: STM32N655

- **Part:** STM32N655 (264-ball BGA, 0.8 mm pitch)
- **CPU:** Cortex-M55 @ 800 MHz
- **GPU:** NeoChrom 2.5D (blit, fill, alpha, rotate — hardware)
- **SRAM:** 4.2 MB internal (LTDC reads framebuffer from here)
- **HyperRAM:** 16 MB external via XSPI (off-screen buffers, fonts, icons)
- **USB:** Integrated PHY (mouse + keyboard via HID)
- **SD:** SDMMC (boot + asset storage)
- **Display:** LTDC (parallel RGB output to FPGA)
- **FPGA link:** PSSI RX (DRAW + bulk forward), FMC master (RPC + filesystem reverse, 256-byte memory-mapped space mixing FIFOs and registers), SPI slave (event payload pull), 4× IRQ GPIO (2 HP/LP each direction)
- **Status:** In stock

## Boot sequencing

The N6 handles all power sequencing. The FPGA never attempts autonomous boot.

```
1. N6 powers on. FPGA held in reset (/CRESET_N low, driven by N6 GPIO).
2. N6 loads firmware from SD card (SDMMC boot partition).
3. N6 reads fpga.bit from SD card filesystem, checks version against
   cached bitstream in shared QSPI flash.
4. If newer (or flash empty), N6 programs QSPI flash via SPI5 while
   holding FPGA in reset. No contention.
5. N6 releases /CRESET_N. FPGA loads bitstream from QSPI flash (~50 ms).
6. CDONE asserts. FPGA config pins → high-Z. System live.
```

Total cold boot: ~500 ms–1 s. Subsequent boots skip step 4 (~100 ms).

## QSPI flash (FPGA bitstream only)

A single QSPI NOR flash holds the FPGA bitstream — nothing else. N6
firmware lives on the SD card; the QSPI flash is not an N6 boot source.

The FPGA reads the bitstream in 4-bit QSPI mode at boot. The N6 has
write-only access via SPI5 (1-bit SPI) for bitstream updates: it reads
`fpga.bit` from the SD card, compares against the cached version, and
optionally reprograms the flash while the FPGA is held in reset. Three
PCB traces (CLK, DQ0, DQ1) are shared between FPGA and N6 with 22 Ω
series resistors. DQ2 and DQ3 are pulled high (WP#, HOLD#) and unused
by the N6.

```
QSPI Flash ←→ FPGA Ti60 (4-bit QSPI, autonomous boot)
                ↑ 3 shared lines (22Ω)
                N6 SPI5 (1-bit, bitstream update only)
```

No mux, no buffer. N6 SPI5 pins default to high-Z during FPGA boot.

## N6 peripheral map

| Peripheral | Pins | Notes |
|-----------|-----:|-------|
| LTDC (to FPGA) | 28 | RGB24 + syncs. 1.8 V. |
| PSSI (to FPGA) | 18 | 16-bit + PIXCLK + DE. FPGA→N6 forward bulk. 1.8 V. |
| FMC (FPGA slave) | 19 | A[7:0] + D[7:0] + /CS + /OE + /WE (async mode, no separate clock). N6 master; 256-byte address space mixing FIFOs and byte-addressable status/control/scratch registers. 1.8 V. |
| SPI (FPGA master) | 4 | Event payload pull, post-IRQ. 1.8 V. |
| Event IRQs | 4 | 2× FPGA→N6 (HP+LP) + 2× N6→FPGA (HP+LP), edge-triggered. 1.8 V. |
| QSPI flash (FPGA-shared) | 3 | SPI5, 3.3 V, 22Ω series. N6 has write access for bitstream updates only. |
| SDMMC (SD card) | 6 | 4-bit SD, N6 boot source. |
| USB host | 2 | Integrated PHY, mouse + keyboard. |
| SIO (PortP[8:15]) | 8 | Atari SIO protocol, GPIO bit-bang or UART. |
| POTs (PortQ) | 8 | 8× paddle inputs. Write-1-and-time-discharge, IRQ-driven. |
| I2C (shared) | 2 | SDA + SCL. Shared bus for onboard / expansion peripherals. |
| Expansion ×2 | 28 | SPI + UART + parallel bus per port. |
| UART debug | 2 | TX + RX. |
| HyperRAM XSPI | 12 | 8-bit HyperBus, 16 MB. |

Total: ~144 pins committed, ~24 undedicated of 168 available. Spare GPIO
serves single-bit duties: POWER_GOOD, POWER_EN, /CRESET_N, CDONE, status
LEDs, strapping pins.

## N6 firmware stack

```
PSSI RX (DMA → ring buffer)
    ↓
DRAW dispatch loop (parses opcode + length)
    ↓
LVGL canvas widget (full-screen, receives all DRAW commands)
    │
    │   LVGL draw units claim ops in priority order;
    │   anything unclaimed falls through to the next unit:
    │
    ├── NeoChrom draw unit  → blits, scales, rotates, alpha
    ├── DMA2D draw unit     → fills, simple blits (no DMA-clear mode)
    └── Software fallback   → M55 renders anything unclaimed
            │
            ↓
    LVGL display driver → pre-configured LTDC → FPGA → HDMI
```

Key points:
- LTDC is initialised by STM32 HAL (CubeMX) before LVGL starts
- NeoChrom and DMA2D are both first-class LVGL draw units; LVGL handles
  claim-first / fallback-to-software automatically
- No raw NeoChrom register programming needed
- USB HID mouse/keyboard → LVGL input group
- Cursor and sprites (transparent images at arbitrary x,y) live entirely
  on the N6 — no readback to the FPGA, no per-frame cursor uploads
- The 6502 never touches LVGL directly — it sends DRAW opcodes

## Memory hierarchy

| Tier | Size | Contents |
|------|-----:|----------|
| N6 SRAM | 4.2 MB | Active framebuffers: 1.8 MB for RGB888 DB at 640×480, 2.8 MB at 800×600, 3.6 MB for RGB565 DB at 1280×720 (LVGL compiled `LV_COLOR_DEPTH 24`; flush downsamples to RGB565 at 1280×720 only). Plus firmware, stack, PSSI ring buffer |
| N6 HyperRAM | 16 MB | Off-screen buffers, font caches, icon atlases, desktop wallpaper, app scratch |
| FPGA HyperRAM | 16 MB | 6502 system RAM, window data structures (accessed by 6502 through FPGA) |

The two HyperRAM banks are independent in the sense that neither chip
sees the other's RAM as memory-mapped. Bulk data crosses *only* via the
inter-chip channels:

- **FPGA HyperRAM → N6**: PSSI carries bitmap uploads forward (bulk),
  e.g. the 6502 hands a buffer to the N6 for display.
- **N6 → FPGA HyperRAM**: FMC carries file-read content and any
  procedurally generated bytes destined for 6502 RAM, e.g. SD card →
  N6 SRAM/HyperRAM → FMC → FPGA HyperRAM at the 6502-visible address.

## Resolution support

Framebuffer format is **RGB888 for ≤800×600** and **RGB565 for 1280×720**.
LVGL itself is compiled at `LV_COLOR_DEPTH 24` for all modes; the display
flush callback converts 24→16 only when the framebuffer is 16-bit. LTDC
is configured per-mode to scan-out either RGB888 or RGB565 from the
SRAM framebuffer; both formats are supported natively by the peripheral.

| Mode | Pixel clock | FB format | Single | Double-buffered | Notes |
|------|-----------:|-----------|-------:|----------------:|-------|
| 640×480 @ 60 Hz | 25.175 MHz | RGB888 | 900 KB | 1.8 MB | Default; comfortable in 4.2 MB SRAM |
| 800×600 @ 60 Hz | 40 MHz | RGB888 | 1.4 MB | 2.8 MB | DB fits with ~1 MB headroom |
| 1280×720 @ 60 Hz | 74.25 MHz | RGB565 | 1.8 MB | 3.6 MB | **Native ceiling** (LTDC max 88 MHz). RGB565 lets DB fit in SRAM with ~600 KB headroom; conversion from LVGL's 24-bit working buffer happens in the flush callback. Solid UI colours unaffected; gradients band slightly. |

Above 1280×720: FPGA nearest-neighbour doubles from 640×480 (e.g. 1280×960).
~40 LUTs, one line buffer, no software changes.

## What to remove from the existing design

- Paired RP2354 (smart video RAM) — entire chip
- Peri-RP (peripheral mux) — entire chip
- 4× LVC8T245 level translators (1.8 V ↔ 3.3 V for FPGA↔RP bus)
- Bidirectional PIO-based FETCH/SET/DRAW protocol (44 pins)
- PIO state machines on the FPGA side for the above

## What to add

- STM32N655 (BGA264, 0.8 mm)
- PSSI master HDL in FPGA (18-pin 16-bit parallel TX, source-sync clock)
- LTDC capture HDL in FPGA (28-pin parallel RGB + sync input)
- FMC slave HDL in FPGA (19 wires, 8-bit address decoder, mixed FIFO and byte-register dispatch over 256-byte address space; async mode, no source-synchronous clock)
- SPI master HDL in FPGA (4 wires, event payload pull)
- 4× event IRQ pins between FPGA and N6 GPIOs (2 each direction; HP/LP priority split)
- N6 firmware: LVGL + DRAW-to-canvas bridge + USB HID + SD card boot +
  filesystem RPC server behind FMC
- QSPI flash for FPGA bitstream cache (already partially in design)

## What stays unchanged

- Ti60F256 FPGA — same part
- HyperRAM 16 MB (system RAM, accessed by 6502 through FPGA)
- FPGA 6502 core (Arlet SALLY) — still runs AES code
- FPGA ANTIC/GTIA/POKEY cores — still handle legacy modes and audio
- FPGA TMDS encoder + HDMI output — now fed from LTDC capture instead of
  PSSI FETCH reads
- rp-syscontroller, rp-MMU — still on system bus for boot sequencing and
  main memory management
- FPGA palette LUT — still applies colour lookup before TMDS
- FPGA bus snoop pipeline — still captures $D4xx writes for DRAW commands

## getpixel latency budget

The 6502 in this design runs at two different clock rates depending on
mode:

- **Legacy mode** @ 1.79 MHz (~558 ns/cycle) — for original Atari
  games/apps, cycle-accurate compat with ANTIC pacing
- **Modern mode** @ 165 MHz (~6 ns/cycle) — for new-mode / GEM software

The same FMC roundtrip serves both. The FPGA always stretches the read
via /HALT until the result is ready; the visible cost differs by mode.

### Unified API

```
LDA #x : STA $D4xx_X    ; 6 cycles
LDA #y : STA $D4xx_Y    ; 6 cycles — STA Y triggers FMC roundtrip
LDA $D4xx_PIXEL         ; 4 cycles + any stretch
```

Single sequence works at both clocks. No mode-aware code paths in 6502
software or FPGA RTL — the stretch is naturally zero when the FMC
finishes before the LDA arrives.

### FMC roundtrip cost (clock-independent)

| Stage | Time |
|-------|------|
| FPGA decode + /HALT assert (165 MHz fabric, combinational) | ~6 ns |
| Event-IRQ → Cortex-M55 NVIC entry + ISR prologue on N6 (varies with cache pressure) | ~80–250 ns |
| ISR reads (x,y) via FMC (1–2 transactions @ ~50 ns) | ~100 ns |
| Framebuffer lookup in SRAM (cache hit) | ~20 ns |
| Result write back via FMC | ~50 ns |
| FPGA captures, drives data bus, releases /HALT | ~12 ns |
| **Roundtrip total** | **~280–450 ns** |

### Behaviour by mode

| Mode | Cycle time | Stretch | Per-call cost (incl. setup) | Bulk getpixel rate |
|------|-----------:|--------:|---------------------------:|-------------------:|
| Legacy @ 1.79 MHz | 558 ns | 0 cycles (FMC done before LDA arrives) | ~9 µs | ~110k/sec |
| Modern @ 165 MHz | 6 ns | 46–75 cycles | ~300–500 ns | ~2–3 M/sec |

**Legacy mode**: `STA $D4xx_Y` completes at t=0; FMC roundtrip starts.
By the time 6502 fetches and executes the `LDA` (~4 cycles ≈ 2.2 µs
later), the FMC has been done for ~5× the roundtrip time. Read
completes without stretch. Cost invisible to apps.

**Modern mode**: 6502 reaches the `LDA` ~24 ns after `STA Y`; FMC still
has ~250 ns to go. FPGA stretches the read 46–75 cycles — equivalent to
~12–19 dead LDA-absolute slots inserted into the program. Visible but
small for isolated calls.

Note: most legacy software (Atari games, original OS) won't use this
API at all — they read VRAM directly through ANTIC/GTIA, which never
crosses to the N6. The legacy numbers above describe what *would*
happen if a 1.79 MHz program does call getpixel.

### Bulk readback

| Mode | 640×480 via getpixel | 640×480 via FMC bulk-read mailbox |
|------|---------------------:|-----------------------------------:|
| Legacy @ 1.79 MHz | ~2.8 s | ~6–10 ms |
| Modern @ 165 MHz | ~123 ms | ~6–10 ms |

Add an FMC bulk-read mailbox — "dump region (x,y,w,h) from N6
framebuffer into FPGA HyperRAM at address P" — for region grabs. ~15×
faster at 165 MHz and ~300× faster at 1.79 MHz; the mailbox is the
right primitive for any readback larger than a handful of pixels in
either mode.

## Open questions

1. **LVGL canvas widget performance** — verify bulk DRAW command dispatch
   through the canvas API doesn't bottleneck. Batch commands per VBI if
   needed.
2. **SD card failure** — N6 firmware lives on the SD card, so without it
   the N6 cannot boot. The FPGA still loads its cached bitstream from
   QSPI flash, so the 6502, ANTIC, GTIA and POKEY come up and the system
   can render a "NO SD" screen in legacy ANTIC mode (no GEM, no HDMI from
   the N6 path — fallback to FPGA-driven legacy TMDS if the design keeps
   that path live). Practical mitigation is on the user side: keep a
   known-good SD image; the system is unbootable without one.
3. **Memory-mapped sub-protocol design** — the FMC 256-byte address
   space ([FMC mailbox map](#fmc-mailbox-map)) defines where FIFO
   endpoints, status/control registers, and command scratch live; the
   byte-level framing inside each FIFO and the bit assignments inside
   each register are software contracts. Needs a small spec doc before
   firmware bring-up so 6502 syscalls, N6 RPC handlers, and FPGA-side
   FIFO sizing all agree.

### Resolved

- **N6 FMC IO voltage domain** — all N6 GPIO banks (including those carrying
  FMC) operate at 1.8 V; no 3.3 V-only pins identified in the STM32N645/N655
  datasheet (§5.3.19, table 24). No level translators on the FMC bus.
- **FMC max bus clock** — clock tree runs to 200 MHz; bus frequency is
  typically HCLK/2 = 100 MHz, consistent with the bandwidth numbers in
  [Channels between FPGA and N6](#channels-between-fpga-and-n6).
- **Colour format bridge** — LVGL compiled at `LV_COLOR_DEPTH 24` (RGB888)
  for all modes. The 6502 wire format is 8-bit indexed; the N6 DRAW
  dispatcher expands indices via palette LUT to RGB888 before handing
  pixels to LVGL / NeoChrom. Framebuffer format is per-mode: RGB888 at
  ≤800×600 (DB fits in SRAM), RGB565 at 1280×720 (RGB888 DB = 5.4 MB
  exceeds 4.2 MB SRAM, but RGB565 DB = 3.6 MB fits with ~600 KB
  headroom). The LVGL display flush callback converts 24→16 only at
  1280×720; LTDC is configured per-mode to scan-out either format. Solid
  UI colours unaffected by the downsample; smooth gradients band
  slightly at 1280×720.

## References

- **`GEM.md`** — full POR architecture document (553 lines, all N6 details)
- **`GEM-rp2354.md`** — archived RP2354 design for reference (1,168 lines)
- **`pin-map.md`** — Ti60F256 I/O bank allocation
- **`hardware-notes.md`** — voltage domains, level translation details
- **`register-map.md`** — $D4xx chiplet-extension register allocation
