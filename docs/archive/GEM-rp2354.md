# GEM for rp-XT

**GEM** (Graphical Environment Manager) — a windowing GUI system for the rp-XT
platform, implemented as an xtc library. This document covers the architecture,
feasibility, and implementation plan.

Original GEM sources: http://www.retroarchive.org/cpm/archive/unofficial/gemworld.html

## Table of Contents

1. [Hardware context](#1-hardware-context)
2. [Architecture overview](#2-architecture-overview)
3. [The three CPUs and their roles](#3-the-three-cpus-and-their-roles)
4. [Communication paths](#4-communication-paths)
5. [The blit bottleneck](#5-the-blit-bottleneck)
6. [Memory budget](#6-memory-budget)
7. [DRAW command set](#7-draw-command-set)
8. [Hardware cursor](#8-hardware-cursor)
9. [Event system](#9-event-system)
10. [Timeline](#10-timeline)
11. [Open questions](#11-open-questions)
12. [Variant: STM32N6 replaces the paired RP2354](#12-variant-stm32n6-replaces-the-paired-rp2354)

---

## 1. Hardware context

rp-XT is a five-chip Atari 130XE-compatible system using RP2354
microcontrollers plus an Efinix Ti60 FPGA:

| Chip | Role | CPU | Speed | Memory | Notes |
|------|------|-----|------:|--------|-------|
| **FPGA** (Ti60) | Everything realtime | 6502 (SALLY, Arlet core) + ANTIC + GTIA/CTIA + HyperRAM controller + POKEY | 6502 @ ~130 MHz, fabric at bus rate | 64 KB BlockRAM cpu_shadow + 16 MB HyperRAM (system RAM) | All realtime paths in fabric — compositor, DL parser, TMDS encoder, palette |
| **RP2354** (paired) | Smart video RAM + GPU | Dual ARM Cortex-M33 | 360 MHz | 520 KB SRAM (307 KB = framebuffer, remainder = code + buffers) | Private to FPGA — NOT on system bus |
| rp-MMU | Main memory | RP2354 | 528 MHz | HyperRAM | System RAM + banked extensions |
| rp-POKEY/PIA | Sound + I/O | RP2354 | 528 MHz | — | SIO, joystick, keyboard |
| rp-syscontroller | Boot + clock | RP2354 | 528 MHz | — | PLL, reset sequencing, serial config |

### Why this architecture

The earlier `rp-antic` design (ANTIC entirely on an RP2354) was abandoned
because a single ARM CPU couldn't close timing on all the realtime work:
bus snoop, register dispatch, display-list parsing, per-scanline composition,
collision, PRIOR, HSTX DMA chains, and /NMI//HALT/RDY pin assertion all
fought for the same ~32 µs scanline budget.

The `fpga-antic` design moves **every realtime path into FPGA fabric** where
the compositor is a continuous pipeline with no IRQ concept. The RP2354 keeps
only the work that has no per-pixel deadline: bulk framebuffer storage and
queued DRAW opcodes.

---

## 2. Architecture overview

```
6502 (in FPGA)                          RP2354 (paired)
@ ~130 MHz, 16 MB HyperRAM              @ 360 MHz, 520 KB SRAM
┌──────────────────────┐               ┌──────────────────────┐
│  AES layer           │               │  VDI layer           │
│                      │               │                      │
│  ┌────────────────┐  │  $D4xx regs   │  ┌────────────────┐  │
│  │ Window manager │──┼──────────────┐│  │ DRAW opcode    │  │
│  │ (structs, Z,   │  │  write DRAW  ││  │ dispatch (C)   │  │
│  │  focus, events)│  │  commands    ││  │                │  │
│  │                │  │              ││  │ LINE, FILL,    │  │
│  │  All xtc code  │  │  FPGA snoops ││  │ BLIT, TEXT,    │  │
│  │  on 6502       │  │  $D4xx →     ││  │ CIRCLE, ARC    │  │
│  │                │  │  queues DRAW ││  │                │  │
│  │  Generates     │  │  on FPGA→RP  ││  │  Framebuffer   │  │
│  │  high-level    │  │  bus         ││  │  640×480×1     │  │
│  │  draw commands │  │              ││  │  = 307 KB      │  │
│  └────────────────┘  │              ││  │                │  │
│                      │  FETCH/SET/  ││  │  Off-screen    │  │
│  ┌────────────────┐  │  DRAW bus    ││  │  buffers       │  │
│  │ FPGA compositor│◄─┼──────────────┼──┤  (window caches)│  │
│  │ reads RP2354   │  │  @ ~100 MHz  ││  └────────────────┘  │
│  │ framebuffer    │  │  16-bit wide ││                      │
│  │ via FETCH      │  │  200 MB/s    ││                      │
│  │                │  └──────────────┘│                      │
│  │ → palette LUT  │                  └──────────────────────┘
│  │ → TMDS → HDMI  │
│  └────────────────┘
│
│  HyperRAM (16 MB)
│  ┌────────────────┐
│  │ System RAM     │
│  │ + Window data  │
│  │ + Fonts        │
│  │ + Bitmaps      │
│  │ + Icons        │
│  └────────────────┘
└──────────────────────┘
```

### Data flow for a GEM draw operation

1. **6502** (running xtc AES code) decides to draw a button. It writes
   command parameters to `$D4E0`–`$D4EF` (chiplet-extension registers):
   ```
   @($D4E0) = GEM_FILL_RECT;     // opcode
   @($D4E2) = 100;               // x (lo)
   @($D4E3) = 100 >> 8;          // x (hi)
   @($D4E4) = 50;                // y
   ...                           // w, h, colour
   @($D4E1) = 1;                 // commit strobe
   ```

2. **FPGA** snoops the $D4xx writes (same snoop pipeline as ANTIC register
   dispatch). The register decode collects the parameters and assembles a
   16-byte DRAW packet in a FIFO. The FPGA's RP-side PIO SM sends it:
   ```
   tag=DRAW  payload={ opcode=FILL_RECT, x=100, y=50, w=40, h=20, colour=$B4 }
   ```

3. **RP2354** receives the DRAW packet on its PIO input. Core 1's dispatch
   loop picks it up and executes it on the framebuffer:
   ```c
   void cmd_fill_rect(DrawCmd* cmd) {
       uint8_t* fb = framebuffer;
       for (int y = cmd->y; y < cmd->y + cmd->h; y++)
           memset(&fb[y * 640 + cmd->x], cmd->colour, cmd->w);
   }
   ```

4. **FPGA compositor** (running in fabric, continuous) reads the framebuffer
   from the RP2354 one scanline ahead of scan-out via FETCH commands. The
   FPGA applies the palette LUT and drives TMDS to HDMI. GEM's drawn pixel
   appears on screen — no per-frame upload needed.

---

## 3. The three CPUs and their roles

### 3.1 6502 (in FPGA fabric, ~130 MHz) — AES

Runs all application logic in xtc. Responsibilities:

| Module | Complexity | Notes |
|--------|-----------:|-------|
| **Window manager** | ~2000 lines | Create/destroy/move/resize. Z-order linked list. Focus tracking. 16 MB HyperRAM = unlimited windows. |
| **Event router** | ~500 lines | Read mouse from $D010–$D013 (serial-pushed by rp-POKEY), keyboard from $D200. Route to focused window's handler. Timer events via VBI NMI. |
| **Control library** | ~3000 lines | Button, checkbox, radio, scrollbar, text field, list box, menu, dialog. Geometry + state on 6502; drawing commands dispatched to DRAW queue. |
| **Desktop** | ~1000 lines | Wallpaper, icon grid, app launcher, file selector. |
| **Layout engine** | ~1000 lines | Dialog layout, window chrome sizing, control positioning. |

**Total AES: ~7500 lines of xtc.** The 6502 at 130 MHz with 16 MB HyperRAM
handles this comfortably. All data structures are in HyperRAM; the 6502
accesses them through the FPGA's internal bus (snooped into cpu_shadow
for the 64 KB window, or directly via HyperRAM for the full 16 MB).

### 3.2 FPGA fabric — compositor + display

Runs continuously, no software involvement once configured:

| Block | Role |
|-------|------|
| **ANTIC compositor** | ANTIC-mode scanline generation (playfield + charset + P/M + collision). Reads from local cpu_shadow BlockRAM. |
| **GEM compositor** | Extended mode: reads framebuffer from RP2354 via FETCH bus, one line ahead of scan-out. Applies extended palette LUT. |
| **TMDS encoder** | Serialises 8-bit colour-index to 3-channel TMDS at 5× pixel clock. |
| **DRAW queue** | Receives DRAW opcodes from $D4xx register writes, queues them in a small FIFO, sends to RP2354 via FPGA→RP PIO. |
| **HyperRAM streamer** | For BLIT_FROM_HYPERRAM opcode: reads source data from HyperRAM and pipes it as SET bursts to the RP2354. |

The compositor is the same pipeline whether ANTIC-compat mode (line-doubled
640×240 or line-tripled 800×200) or fullres extended mode (640×480, one
scanline per framebuffer row). The only difference is the read address
generation and the bus fetch rate (5 MHz vs 10 MHz sustained).

### 3.3 RP2354 ARM Cortex-M33 (360 MHz dual-core) — VDI

Runs DRAW opcodes. The two cores:

| Core | Role | Budget |
|------|------|-------:|
| **Core 0** | PIO service: serves FPGA FETCH/SET to SRAM, handles scan-out prefetch reads. | Mostly idle (PIO does the work) |
| **Core 1** | DRAW command dispatch: executes LINE, FILL_RECT, BLIT, DRAW_TEXT, CIRCLE, etc. | 10–30% typical GUI load |

```c
// DRAW dispatch — runs on RP2354 core 1
void draw_dispatch_loop(void) {
    DrawCmd cmd;
    while (1) {
        while (!draw_queue_pop(&cmd))   // spin, or WFE
            ;
        switch (cmd.opcode) {
        case GEM_FILL_RECT:
            for (int y = cmd.y; y < cmd.y + cmd.h; y++)
                memset(&fb[y * 640 + cmd.x], cmd.colour, cmd.w);
            break;
        case GEM_BLIT:
            memcpy(&fb[cmd.dst], &fb[cmd.src], cmd.w * cmd.h);
            break;
        case GEM_DRAW_LINE:
            bresenham_line(cmd.x0, cmd.y0, cmd.x1, cmd.y1, cmd.colour);
            break;
        case GEM_DRAW_TEXT:
            render_glyphs(cmd.x, cmd.y, cmd.str, cmd.font_id, cmd.colour);
            break;
        // ... etc
        }
    }
}
```

---

## 4. Communication paths

### 4.1 6502 → FPGA (load, store, register write)

Standard 6502 bus. FPGA snoops every cycle:

- **Write to $0000–$BFFF** (not in $Dxxx): → `cpu_shadow[addr] = data`
  (64 KB mirror in BlockRAM). HyperRAM is also updated for non-cpu_shadow
  pages via the FPGA's HyperRAM controller.

- **Write to $D0xx** (/D0xx low): → GTIA register dispatch. GEM doesn't
  touch these normally.

- **Write to $D4xx** (/D4xx low): → ANTIC + chiplet-ext register dispatch.
  **GEM's primary command channel.** $D4E0–$D4EF are allocated for GEM.

- **Write to $D200** (/POKEY low): → rp-POKEY/PIA. Keyboard output.

- **Read from $D0xx or $D4xx**: → FPGA drives D bus with register value.
  Used for mouse position ($D010–$D013), timer ($D40B VCOUNT), status.

### 4.2 FPGA → RP2354 (FETCH/SET/DRAW bus)

Private tagged bus, 27 FPGA→RP lines + 17 RP→FPGA lines, source-synchronous
clock at ~100 MHz.

| Opcode | Tag | Payload | RP response | Purpose |
|--------|:---:|---------|-------------|---------|
| FETCH  | 00  | 24-bit address | 16-bit word at addr | Scan-out prefetch reads framebuffer |
| SET    | 01  | 24-bit addr + 16-bit data | none | FPGA writes pixel data to framebuffer |
| DRAW   | 10  | 8-bit op + 16-bit context | status (optional) | Execute drawing primitive |
| NOP    | 11  | — | — | Bus idle |

The FPGA queues DRAW commands into a small FIFO and sends them to the RP2354
on a best-effort basis between scan-out FETCHes. The queue depth is sized to
absorb bursts (~64 entries, 1 KB of BlockRAM). Back-pressure: if the queue
fills, the FPGA stalls the 6502 via /RDY on the next $D4xx GEM register write.

### 4.3 RP2354 → FPGA (framebuffer scan-out reads)

For every scanline, the FPGA sends FETCH(addr) for each 16-bit word of the
framebuffer row. The RP2354 responds with the pixel data on the RP→FPGA bus.
At 640×480 fullres:

- 320 FETCHes per scanline (640 pixels, 2 pixels per 16-bit word)
- 31.8 µs per scanline window
- 10.1 MHz sustained beat rate
- RP2354 PIO handles this easily at 360 MHz

### 4.4 FPGA → HyperRAM (system memory reads)

The FPGA's HyperRAM controller accesses the 16 MB HyperRAM for:

- OS ROM reads (on boot, or when 6502 accesses $C000–$FFFF region that
  falls through cpu_shadow)
- Bank-switched data reads (130XE-style $4000–$7FFF banking)
- **BLIT_FROM_HYPERRAM source reads** — the FPGA reads bitmap data from
  HyperRAM and streams it to the RP2354 via SET commands

No direct path exists from the RP2354 to HyperRAM. All HyperRAM access goes
through the FPGA.

---

## 5. The blit bottleneck

### 5.1 Why it's a concern

Source data for bitmaps, fonts, and icons lives in HyperRAM (FPGA side).
The destination is the framebuffer (RP2354 side). Every byte that moves
from HyperRAM to the framebuffer must cross **three hops**:

```
HyperRAM ──→ FPGA internal ──→ FPGA→RP PIO bus ──→ RP2354 SRAM
```

The FPGA→RP bus at 100 MHz × 16 bits = 200 MB/s theoretical. Practically
~150 MB/s after protocol overhead.

### 5.2 Bandwidth budget

| Operation | Size | Bus time at 150 MB/s | At 60 Hz |
|---|---|---|---|
| Full 640×480 repaint | 307 KB | 2.0 ms | 12% |
| 200×200 window blit (drag) | 40 KB | 260 µs | 1.6% |
| 100×100 dialog bitmap | 10 KB | 65 µs | 0.4% |
| 50×50 icon | 2.5 KB | 16 µs | 0.1% |
| 8×16 font glyph | 16 B | 0.1 µs | negligible |

A pathological frame: full repaint + 3 window drags + 10 icons = ~2.8 ms =
~17% of one 16.7 ms frame. The bus is **not a bottleneck for GUI workloads**
even in worst-case scenarios.

### 5.3 Strategies to stay comfortable

**1. Off-screen buffers on the RP2354 (in-SRAM)**
When a window is created, an off-screen buffer is allocated on the RP2354
for its content. Blitting between off-screen buffers is a pure `memcpy` on
the ARM — zero bus traffic:

```c
void cmd_blit(DrawCmd* cmd) {
    // Both src and dst are within RP2354 SRAM
    uint8_t* src = &osbuffer[cmd->src_buf * BUF_SIZE + cmd->src_offset];
    uint8_t* dst = &osbuffer[cmd->dst_buf * BUF_SIZE + cmd->dst_offset];
    for (int y = 0; y < cmd->h; y++)
        memcpy(dst + y * 640, src + y * 640, cmd->w);
}
```

**2. Asset cache on RP2354**
Load bitmaps, fonts, and icons from HyperRAM once, cache them on the
RP2354. Subsequent draws use the cached copy — no bus traffic:

| Cache | Size | Load cost | Hit rate |
|---|---|---|---|
| Glyph cache (128 chars × 16×16) | 4 KB | 26 µs (one-time) | Near-100% |
| Icon cache (32 icons × 32×32) | 32 KB | 210 µs (one-time) | Near-100% |
| Window chrome bitmaps | ~10 KB | 70 µs | Per-theme |

**3. Dirty-rect tracking**
Only DMA the changed regions of the framebuffer. A GEM window that's idle
generates zero bus traffic.

**4. Double-buffered drag**
During a window drag, blit the window's off-screen buffer to a scratch
buffer on the RP2354, then composite at the new position from the scratch.
No HyperRAM reads during drag.

### 5.4 The BLIT_FROM_HYPERRAM opcode

For the initial load of bitmap data (not cached), the FPGA provides a
streaming opcode:

```c
void cmd_blit_from_hyperram(DrawCmd* cmd) {
    // FPGA side:
    //   1. FPGA reads source data from HyperRAM at addr
    //   2. FPGA sends SET bursts to RP2354:
    //      SET(fb_dst_addr + 0, pixels[0..1])
    //      SET(fb_dst_addr + 2, pixels[2..3])
    //      ... (16 bits per bus cycle)
    // RP2354 side:
    //   PIO receives SET commands → writes directly to SRAM
    //   ARM is not involved in the data path
}
```

Because the PIO writes directly to SRAM, the ARM cores are free to continue
servicing other DRAW commands while the FPGA streams bitmap data. The only
cost is bus bandwidth.

---

## 6. Memory budget

### 6.1 RP2354 (520 KB SRAM)

```
┌──────────────────────────────────────────────────────┬──────────┐
│ Region                                               │    Size  │
├──────────────────────────────────────────────────────┼──────────┤
│ Framebuffer (640×480 fullres)                        │ 307,200  │
│   or (640×240 ANTIC-compat, line-doubled)            │ 153,600  │
│   or (800×200 ANTIC-compat, line-tripled)            │ 160,000  │
│                                                      │          │
│ Off-screen window buffers (8 × 100×100 windows)      │  80,000  │
│ Asset cache (glyphs, icons, chrome)                  │  50,000  │
│ DRAW command queue (128 entries × 16 bytes)          │   2,048  │
│ PIO program + DMA descriptors                        │   4,000  │
│ ARM firmware code + stack (scratch_x + scratch_y)    │  50,000  │
│ PIO FIFOs + ring buffers                             │   8,000  │
├──────────────────────────────────────────────────────┼──────────┤
│ Total (fullres, 8 windows, cached)                   │ ~501,000 │
│ RP2354 total SRAM                                    │  532,480 │
│ Headroom                                              │  ~31,000 │
└──────────────────────────────────────────────────────┴──────────┘
```

The budget is tight but viable in fullres mode. In ANTIC-compat mode
(307 → 154 KB framebuffer saving) the headroom balloons to ~180 KB,
allowing more off-screen buffers and a larger asset cache.

If more memory is needed, two options exist:
- **ANTIC-compat output** saves 153 KB of framebuffer at the cost of
  line-doubled vertical resolution (fine for GEM's 8×16 fonts and standard
  window chrome).
- **Second RP2354** on the same FPGA bus for extended buffer storage
  (future-proofing).

### 6.2 HyperRAM (16 MB — 6502 side)

All GEM data structures live here, accessed by the 6502 through the
FPGA's HyperRAM controller:

```
Window table             256 × 128 bytes  =   32 KB
Control tree             256 ×  64 bytes  =   16 KB
Event queue               64 ×  32 bytes  =    2 KB
Font data (proportional)                   =  500 KB
Icon library             256 × 1024 bytes =  256 KB
Desktop config           ~10 KB
Application code + data  ~2 MB
Free                                 ~13 MB
```

16 MB is generous. A typical GEM program uses <5 MB total.

---

## 7. DRAW command set

Each command is a fixed-size packet (16 bytes) written by the 6502 to
$D4E0–$D4EF, or pushed directly by the FPGA for BLIT_FROM_HYPERRAM.

| Opcode | Name | Parameters | Cycles per call | Notes |
|-------:|------|------------|----------------:|-------|
| 0x01 | FILL_RECT | x, y, w, h, colour | `O(w)` | memset |
| 0x02 | BLIT | src_buf, dst_buf, src_x, src_y, dst_x, dst_y, w, h | `O(w·h)` | memcpy on ARM |
| 0x03 | BLIT_HYPER | hyper_addr, dst_x, dst_y, w, h | `O(w·h)` | FPGA streams from HyperRAM |
| 0x04 | DRAW_LINE | x0, y0, x1, y1, colour | `O(max(dx,dy))` | Bresenham |
| 0x05 | FILL_CIRCLE | cx, cy, r, colour | `O(r)` | Bresenham |
| 0x06 | DRAW_TEXT | x, y, font_id, string_ptr(8B), colour | `O(chars·glyph_w)` | Glyph cache lookup |
| 0x07 | SET_CLIP | x, y, w, h | O(1) | Per-core clip state |
| 0x08 | SET_PALETTE | index, r, g, b | O(1) | Extended palette entry |
| 0x09 | FLOOD_FILL | x, y, colour | O(area) | Scanline fill |
| 0x0A | COMPOSITE | dst_buf, src_bufs(bitmask), mode | O(w·h·n) | Blend N layers |
| 0x0B | FILL_ARC | cx, cy, r, quadrants, colour | `O(r)` | Bresenham |
| 0x0C | DRAW_OVAL | cx, cy, rx, ry, colour | `O(max(rx,ry))` | Midpoint |
| 0x0D | FREE_BUFFER | buffer_id | O(1) | Release off-screen buffer |
| 0x0E | LOAD_FONT | font_id, hyper_addr, size | `O(size)` | Cache a font on RP2354 |
| 0x0F | LOAD_ICON | icon_id, hyper_addr, size | `O(size)` | Cache an icon |

Default: $D4E0 = opcode, $D4E1 = commit strobe, $D4E2–$D4EF = parameters.
Writing to $D4E1 (#1) triggers the FPGA to assemble and queue the packet.

### Number of 6502 bus cycles per DRAW command

Each GEM command requires 1–8 byte writes to $D4xx registers. At 130 MHz
6502, a write takes ~60 ns. A full 8-register command sequence takes
~500 ns = negligible.

---

## 8. Hardware cursor

The GEM compositor on the RP2354 composites a cursor layer on top of the
window layers. The cursor is a small off-screen buffer (typically 32×32 =
1 KB) that is blended into the framebuffer at the current mouse position
during the COMPOSITE pass:

```c
void composite_cursor(int mx, int my) {
    // Read cursor sprite from cursor buffer
    // Write to framebuffer at (mx, my) with transparency
    // (colour index 0 = transparent)
    for (int y = 0; y < 32 && (my + y) < 480; y++) {
        for (int x = 0; x < 32 && (mx + x) < 640; x++) {
            uint8_t pixel = cursor_buf[y * 32 + x];
            if (pixel != 0)     // colour 0 = transparent
                fb[(my + y) * 640 + mx + x] = pixel;
        }
    }
}
```

At 360 MHz, compositing a 32×32 cursor takes ~5 µs (0.03% of a frame).
The cursor position is updated once per VBI from the mouse state pushed
by rp-POKEY.

Alternatively, the FPGA could own the cursor as an additional compositor
layer (similar to ANTIC's P/M sprite overlays), making the cursor
completely free. This is a future optimisation.

---

## 9. Event system

### Input sources

| Input | Source | Path | 6502 access |
|-------|--------|------|-------------|
| **Mouse position** | rp-POKEY/PIA → serial → FPGA | FPGA updates $D010–$D013 registers (using the existing TRIG/POT serial-push path) | Read $D010–$D013 |
| **Mouse buttons** | rp-POKEY/PIA → serial → FPGA | Same | Read $D010 bits 7-6 |
| **Keyboard** | rp-POKEY/PIA → $D200 | POKEY serial data | Read $D200 (KBCODE) |
| **Timer** | ANTIC VBI NMI | FPGA asserts /NMI at 60 Hz | ISR increments frame counter |
| **Console keys** | rp-syscontroller → serial → FPGA | FPGA updates $D01F (CONSOL) | Read $D01F |

### Event loop (6502 xtc code)

```xtc
// GEM event loop — runs on 6502
void gem_mainloop(void) {
    while (true) {
        // Read input state from FPGA registers
        u16 mx  = peek($D010);
        u16 my  = peek($D012);
        u8  btn = peek($D010) >> 6;   // bits 7-6
        u8  key = peek($D200);        // POKEY KBCODE
        
        // Generate GEM events
        if (mx != prev_mx || my != prev_my) {
            post_event(EVT_MOUSE_MOVE, mx, my, btn);
        }
        if (btn != prev_btn && btn != 0) {
            post_event(EVT_MOUSE_DOWN, mx, my, btn);
        }
        if (key != 0) {
            post_event(EVT_KEY_DOWN, (u16)key, 0, 0);
        }
        
        // Process event queue
        process_events();
        
        // Idle: draw pending updates
        flush_draw_queue();
        
        prev_mx = mx; prev_my = my; prev_btn = btn;
    }
}
```

The mouse position is updated by rp-POKEY/PIA via the inter-chip serial
link to the FPGA at 60-100 Hz. The 6502 reads it from $D010–$D013 on
every event loop iteration. At 130 MHz, polling costs ~100 ns = nothing.

---

## 10. Timeline

Estimates for one developer familiar with the existing fpga-antic codebase,
Verilog, and ARM Cortex-M C programming.

### Phase 1: DRAW command infrastructure (3-4 weeks)

| Week | Deliverable |
|:----:|-------------|
| 1 | Define DRAW opcode set. Implement FPGA $D4xx register decode for GEM window ($D4E0–$D4EF). Add DRAW FIFO + FPGA→RP PIO send path. |
| 2 | Implement FILL_RECT, BLIT, DRAW_LINE dispatch on RP2354 core 1. Basic framebuffer write path works. |
| 3 | Implement SET_CLIP, BLIT_FROM_HYPERRAM (FPGA-side HyperRAM reader + SET burst streamer). Asset caching allocator. |
| 4 | Implement DRAW_TEXT with glyph cache. FILL_CIRCLE, FILL_ARC. Off-screen buffer allocator (<32 lines of C). |

**Milestone**: 6502 can draw rectangles, lines, circles, and text on screen
via DRAW commands. Bitmaps can be loaded from HyperRAM.

### Phase 2: Compositor + cursor (1-2 weeks)

| Week | Deliverable |
|:----:|-------------|
| 1 | Off-screen buffer compositor on RP2354: composite N buffers into framebuffer with Z-order. Dirty-rect tracking. |
| 2 | Hardware cursor overlay. Window chrome drawing (title bar, borders via composite). ANTIC-compat vs fullres mode support. |

**Milestone**: Two overlapping windows with independent content, composited
correctly. Cursor tracks mouse.

### Phase 3: Event system (2 weeks)

| Week | Deliverable |
|:----:|-------------|
| 1 | Plumb mouse (rp-POKEY/PIA serial → FPGA $D010) and keyboard ($D200) to GEM event queue on 6502. VBI timer. |
| 2 | Event routing: mouse-to-window hit-test, focus management, keyboard focus, timer events. |

**Milestone**: Mouse clicks reach windows. Keyboard input works. Timer events fire.

### Phase 4: AES controls + desktop (5-7 weeks)

| Week | Deliverable |
|:----:|-------------|
| 1-2 | Button, checkbox, radio button, label controls. Drawing via DRAW commands, hit-test via rect check. |
| 2-3 | Scrollbar (vertical + horizontal). Thumb tracking, click-to-page, drag-to-scroll. |
| 3-4 | Text field (single-line): cursor blink, character insert/delete, selection. |
| 4-5 | Menu bar + pulldown menus. Menu tracking, keyboard accelerators. |
| 5-6 | Dialog manager: modal loop, focus scope, default button, ESC to cancel. |
| 6-7 | Desktop: wallpaper, icon grid, app launcher. File selector dialog. |

**Milestone**: Working GEM desktop with menus, dialogs, and interactive
controls.

### Phase 5: Polish (2-3 weeks)

| Week | Deliverable |
|:----:|-------------|
| 1 | Window chrome: drag shadows, resize handles, close button, minimise/maximise. |
| 2 | Font tuning: proportional font support, anti-aliased glyphs (1-bit → 2-bit). Performance profiling. |
| 3 | ANTIC-compat output mode support. Edge cases: screen resolution switching, colour depth. Documentation. |

**Milestone**: Ship-ready GEM library.

### Total: ~26-30 weeks (~7 months)

---

## 11. Open questions

These are things that need hardware-level answers before the design can be
finalised:

### 11.1 $D4xx register decode

The existing $D4xx extension window ($D480–$D4FF) is partially allocated.
Can we reserve $D4E0–$D4EF for GEM? That's 16 registers, each 1 byte wide.
The FPGA must decode these addresses and route them to the DRAW command
FIFO rather than the ANTIC register file.

**Proposed allocation:**

```
$D4E0  GEM_OPCODE      (W)  8-bit opcode
$D4E1  GEM_COMMIT      (W)  write strobe — assembles + queues the packet
$D4E2  GEM_P0_LO       (W)  parameter 0 low byte
$D4E3  GEM_P0_HI       (W)  parameter 0 high byte
$D4E4  GEM_P1_LO       (W)  parameter 1 low byte
$D4E5  GEM_P1_HI       (W)  parameter 1 high byte
$D4E6  GEM_P2          (W)  parameter 2 (8-bit)
$D4E7  GEM_FLAGS       (W)  flags (clip enable, blend mode, layer select)
$D4E8  GEM_LENGTH      (W)  payload length for variable-length ops; 0 = fixed-length (FPGA knows from opcode)
$D4E9  GEM_RESERVED    (W)  —
$D4EA  GEM_STATUS      (R)  status byte (queue depth bits 0-5, overflow bit 6)
$D4EB  GEM_RESP_DATA   (R)  response data byte (getpixel value, ack code)
$D4EC–$D4EF reserved
```

**Fixed-length ops** (most DRAW commands): 6502 writes opcode + params + flags,
then strobes COMMIT. The FPGA looks up the expected param count from the opcode
table and assembles a fixed-size packet. GEM_LENGTH is ignored (stays 0).

**Variable-length ops** (BULK_TRANSFER, TEXT_STRING): 6502 writes opcode + params
+ length + flags, then strobes COMMIT. The FPGA reads `length` bytes from
HyperRAM (for BULK_TRANSFER) or the 6502's subsequent register writes (for short
strings) and appends them as packet payload.

**PSSI wire format** (what the N6 parses):

```
Byte 0:       opcode
Byte 1:       flags
Bytes 2-3:    payload_length (16-bit, little-endian; 0 = fixed-length)
Bytes 4..k:   opcode-specific params (fixed per opcode table)
Bytes k+1..:  variable-length payload (present iff payload_length > 0)
```

The M55 dispatch loop reads byte 0 to classify the command, byte 2-3 to know
how many total bytes to consume from the PSSI ring buffer before the next
packet starts. This is the critical fix: **without an explicit length in the
wire format, the parser can't know where one command ends and the next
begins**, making BULK_TRANSFER impossible to implement correctly.

### 11.2 DRAW queue overflow

If the 6502 sends DRAW commands faster than the RP2354 can consume them
(extremely unlikely — a 130 MHz 6502 vs 360 MHz ARM), the FPGA needs to
back-pressure the 6502. Options:

a) Stall via /RDY on the next $D4E1 write.
b) Return a "queue full" status on $D4EA read and let the 6502 poll.

Option (a) is simpler. The FPGA just holds /RDY low until the DRAW FIFO
has room.

### 11.3 BLIT_FROM_HYPERRAM — bus mastering

The FPGA needs to read from HyperRAM and simultaneously write to the
RP2354 PIO bus. This means the HyperRAM controller (already in the FPGA
design) must support concurrent requests — or at least be able to insert
a GEM-initiated read between ANTIC's HyperRAM accesses.

The existing architecture already supports this: The FPGA's HyperRAM
controller arbitrates between ANTIC reads (DL parse, compositor character
reads) and CPU accesses (cpu_shadow miss, bank window access). GEM blit
reads are just another requestor with lower priority.

### 11.4 Screen resolution

The FPGA supports two output modes:

- **640×480 @ 60 Hz** (25.175 MHz pixel clock, default)
- **800×600 @ 60 Hz** (40 MHz pixel clock, wide-playfield mode)

GEM should support both. The framebuffer layout on the RP2354 needs to
be configurable at boot time. The existing `$D482 OUTPUT_MODE` register
selects between them.

In ANTIC-compat mode, the framebuffer is:
- 640×240 (line-doubled) for 640×480 output
- 800×200 (line-tripled) for 800×600 output

GEM's drawing primitives need to know the active output resolution and
framebuffer stride. This can be read from $D482 at boot.

### 11.5 ANTIC-compat vs. fullres mode

ANTIC-compat mode saves framebuffer memory but gives a half-height
logical screen (240 or 200 rows, each row driving 2–3 physical scanlines).
Fullres mode uses the full 307 KB framebuffer but gives native 480-line
vertical resolution.

For GEM, fullres mode is strongly preferred:
- Higher-quality text rendering (16-pixel font height = clear at 480 lines)
- Finer window positioning
- Better cursor tracking

ANTIC-compat mode is useful for programs that mix GEM windows with legacy
ANTIC display modes (e.g., running an Atari game in one window). GEM
should detect the output mode at boot and adapt.

### 11.6 Mouse resolution

The mouse position (from rp-POKEY/PIA over serial) provides 8-bit X and
Y values. At 640 horizontal pixels, 8 bits (256 positions) gives
640/256 = 2.5 pixels per unit — too coarse for a GUI.

Options:
a) Increase to 10-bit X via rp-POKEY/PIA firmware change (2560 positions
   = 4 pixels per unit at 10240).
b) Subdivide: use the existing POT inputs (8-bit each, four pots) for
   higher-resolution mouse tracking.
c) Interpolate on the FPGA: receive low-res mouse updates and smooth to
   pixel-level precision using delta tracking.

Option (b) is the most compatible with existing Atari hardware conventions.
The POT[A-D] registers ($D200–$D20B) provide 8-bit analog readings. With
a suitable mouse (CX80 trackball, or a modern USB→POT converter), this
gives usable precision.

### 11.7 Colour depth

The current architecture uses 8-bit indexed colour (256-entry palette).
Each pixel is one byte. The palette maps indices to 24-bit RGB via the FPGA's
palette LUT.

GEM can use this directly:
- Colour 0 = transparent (for cursor and window compositing)
- Colours 1–15 = system colours (window chrome, desktop, text)
- Colours 16–255 = application colours

The extended palette ($D483–$D486 registers) supports writing individual
(r, g, b) entries. GEM can pre-define a standard palette at boot.

Future work: 16-bit (RGB565) colour depth for higher-quality rendering.
This doubles the framebuffer to 614 KB, which requires either:
- ANTIC-compat mode (154 KB → 308 KB, still fits in RP2354 SRAM)
- A second RP2354 for the additional buffer memory

---

## Appendix: Existing infrastructure that GEM reuses

| Component | Already exists | GEM reuse |
|-----------|---------------|-----------|
| FPGA 6502 core | ✅ Arlet SALLY in fabric | Runs AES code |
| FPGA bus snoop | ✅ Snoop pipeline for ANTIC | Snoops $D4E0 writes for DRAW commands |
| FPGA $D4xx register decode | ✅ ANTIC register file | Decodes $D4E0–$D4EF for GEM |
| FPGA HyperRAM controller | ✅ HyperRAM IP | Reads bitmap source data for BLIT ops |
| FPGA→RP PIO bus | ✅ FETCH/SET/DRAW protocol | Sends DRAW opcodes, receives status |
| RP→FPGA PIO bus | ✅ Returns 16-bit data | Framebuffer scan-out reads |
| RP2354 PIO service | ✅ Core 0 serves FPGA requests | Same (unmodified) |
| RP2354 SRAM framebuffer | ✅ 640×480×1-byte or ANTIC-compat | GEM draws here |
| RP2354 dual-core | ✅ Core 0 = PIO, core 1 = free | Core 1 = DRAW dispatch |
| FPGA TMDS scan-out | ✅ HSTX→HDMI pipeline | Unmodified |
| FPGA compositor | ✅ ANTIC playfield+charset+PM | Extended for GEM fullres mode |
| FPGA palette LUT | ✅ 256-entry, 24-bit RGB | Standard GEM palette |
| FPGA /NMI generation | ✅ VBI, DLI | VBI timer for events |
| rp-POKEY/PIA serial | ✅ Pushes joystick/trigger state | Extended for mouse |
| Inter-chip serial | ✅ FPGA ↔ rp-POKEY/PIA | Mouse position updates |
| 6502 HyperRAM access | ✅ Through FPGA controller | Window data structures |

---

## 12. Variant: STM32N6 replaces the paired RP2354

The RP2354 paired with the FPGA works, but its 520 KB SRAM is tight for
a full-resolution GUI. The **STM32N6** (Cortex-M55 @ 800 MHz, 4.2 MB
internal SRAM, NeoChrom 2.5D GPU) provides 8× the memory and hardware
graphics acceleration — but has no PIO, so the FPGA↔RP bus protocol
doesn't port directly.

The following design uses both chips' complementary strengths via
**three independent unidirectional channels**, eliminating the per-cycle
direction-switching problem entirely.

### 12.1 Interfaces

| Channel | Direction | Master | Protocol | FPGA I/O | N6 I/O | Bandwidth | Purpose |
|---------|-----------|--------|----------|---------:|-------:|----------:|---------|
| **PSSI** | FPGA → N6 | FPGA | Parallel (8/16-bit), source-sync clock | 8/16 data + 1 clock + 1 qualifier = **10–18** | same | ~100–200 MB/s | DRAW commands, bulk pixel uploads |
| **SPI** | N6 → FPGA | FPGA | SPI (4-wire) | 4 (SCK, MOSI, MISO, CS) | 4 | ~1–10 MB/s | getpixel responses, command acks, queue depth, VSYNC timestamp |
| **LTDC** | N6 → FPGA | N6 | Parallel RGB + syncs | 24 (RGB) + 4 (HSYNC, VSYNC, DE, PCLK) = **28** | same | 25–40 Mpix/s | Continuous video stream from N6 framebuffer |

**Total I/O:** 10–18 (PSSI) + 4 (SPI) + 28 (LTDC) = **42–50 FPGA pins**,
well within the Ti60F256's HSIO bank capacity (~96 GPIO in BGA256).

These three channels replace the previous single bidirectional FETCH/SET/DRAW
bus. Each is **unidirectional and statically configured** — no per-cycle
direction switching, no PIO needed.

### 12.2 Voltage domains and level translation

The Ti60F256 has two I/O bank classes with different voltage capabilities:

| Bank | Pins | Voltage | Used for (current RP design) | Used for (N6 variant) |
|------|-----:|--------|------------------------------|------------------------|
| **HVIO** (left edge) | 27 | 3.3 V | rp_rx (RP→FPGA, 17 pins), peri-RP SPI (5 pins) | Peri-RP SPI (unaffected); freed rp_rx pins repurposed for cart/expansion |
| **HSIO** (top/bottom/right) | 142 | **1.8 V** | rp_tx (FPGA→RP, 27 pins via 4× LVC8T245), HyperRAM PHY, HDMI TMDS, 6502 bus (via 4× LVC8T245), joy SPI, FPGA config | PSSI + SPI + LTDC + all existing HSIO groups (HyperRAM, HDMI, 6502 bus) |

**Key win: the N6 variant eliminates all FPGA↔RP level translators.**

The current RP2354 design needs 4× LVC8T245 (16 channels total) to convert
between the FPGA's 1.8 V HSIO and the RP2354's 3.3 V I/O on `rp_tx`.
Additionally, `rp_rx` sits on HVIO at 3.3 V (direct connect, no translators —
but still a 17-pin bundle at a different voltage than the HSIO banks).

With the N6 variant:

| Interface | FPGA bank | FPGA voltage | N6 voltage | Translation |
|-----------|-----------|-------------|------------|-------------|
| **PSSI** (FPGA→N6, 10–18 pins) | HSIO | 1.8 V LVCMOS | VDDIO bank @ 1.8 V | **None** — direct connect |
| **SPI** (FPGA↔N6, 4 pins) | HSIO | 1.8 V LVCMOS | VDDIO bank @ 1.8 V | **None** — direct connect |
| **LTDC** (N6→FPGA, 28 pins) | HSIO | 1.8 V LVCMOS | VDDIO bank @ 1.8 V | **None** — direct connect |

The STM32N6 has independent VDDIO domains per I/O bank, each configurable
to 1.8 V or 3.3 V. PSSI, SPI, and LTDC all sit on banks powered by a 1.8 V
VDDIO rail shared with (or derived from) the FPGA's HSIO VCCIO. At 1.8 V
LVCMOS, the N6's I/O timing comfortably meets:
- PSSI at 100 MHz (parallel, source-sync clock from FPGA)
- LTDC at 25–40 MHz (parallel RGB with syncs)
- SPI at 1–10 MHz (master clock from FPGA)

**BOM impact:** Removing the 4× LVC8T245 level translators (used for `rp_tx`)
saves ~$1.20 and frees board area. The FPGA's `rp_tx` pins (27 HSIO) are
repurposed for PSSI, SPI, and LTDC. The HVIO bank's `rp_rx` pins (17) are
freed for cart-slot expansion or other 3.3 V peripherals.

**Caveat:** verify the N6's specific VDDIO pin assignments against the
chosen package (N657 BGA) — some packages restrict which banks can be
powered at 1.8 V vs 3.3 V. All N6 series devices support 1.8 V LVCMOS on
at least two I/O banks, which is sufficient for the three interfaces above.
Early production reports confirm 1.8 V operation on PSSI and LTDC pins at
the required frequencies.

### 12.3 Hardware assumptions

- **FPGA: Efinix Ti60F256** (not T20). 60 K LUTs, ~3.7 Mb BlockRAM, HSIO
  banks with MIPI D-PHY support. TI60 is the current production target; all
  the Ti60-specific SerDes/CSI capability is available if needed later.
- **STM32N6** via the $14 N657 (4.2 MB SRAM) or the lower-cost N655 (3.2 MB)
  / N653 (1.2 MB) depending on budget. All three share the same peripheral
  set (SPI, PSSI, LTDC, NeoChrom). The N6's SPI peripherals support slave
  mode up to 50 MHz with hardware chip-select and configurable data size —
  more than adequate for the control-plane traffic described below.
- **FPGA drives HDMI** (including audio over TMDS data islands). The LTDC
  stream provides pixel data; the FPGA inserts audio samples from the
  on-FPGA POKEY core into the HDMI blanking intervals. No separate audio
  path needed.
- **LTDC pixel clock** can be sourced from the FPGA or generated internally
  by the N6. The simplest approach: the FPGA generates `pix_clk`
  (25.175 MHz for 640×480, 40 MHz for 800×600) and feeds it to the N6's
  LTDC as its pixel clock input. Both sides then run from the same clock,
  inherently synchronised.
- **Maximum native resolution** of the N6's LTDC is 1280×720 @ 60 Hz
  (88 MHz pixel clock ceiling). For higher 4:3 resolutions such as
  1280×960, the FPGA nearest-neighbour-doubles from a 640×480 base —
  the N6 renders at the lower resolution, the FPGA repeats each pixel
  and scanline during scan-out. This uses ~40 LUTs and a single line
  buffer; no software changes are needed on the 6502 or N6 side.

### 12.4 Data flows

#### DRAW path (6502 → STM32N6 NeoChrom GPU)

```
6502 writes $D4E0–$D4EF
      │
      ▼
FPGA captures (existing snoop pipeline)
      │
      ▼
FPGA assembles DRAW packet in PSSI FIFO
      │
      ▼
PSSI (FPGA → N6, parallel, source-sync clock)
      │
      ▼
STM32N6 PSSI peripheral receives packet
      │
      ▼
Core dispatches to NeoChrom GPU or software rasteriser
      │
      ▼
NeoChrom renders into internal SRAM framebuffer
```

PSSI is the ideal fit here: it's designed for **parallel slave receive**
(master provides clock + data, slave captures). The FPGA drives the clock
and 8-16 data lines, pushing one DRAW command per bus beat. The N6's PSSI
receives with deterministic latency (no OS jitter — it's a peripheral, not
an interrupt). At 100 MHz × 16-bit, a 16-byte DRAW command arrives in
~160 ns.

#### Video out path (STM32N6 → FPGA → HDMI)

```
STM32N6 NeoChrom GPU renders into internal framebuffer
      │
      ▼
LTDC reads framebuffer from SRAM at line rate
      │
      ▼
LTDC outputs parallel RGB (24-bit or 16-bit)
      + HSYNC, VSYNC, DE, PCLK
      │
      ▼
FPGA captures RGB stream on dedicated I/O pins
      │
      ▼
FPGA feeds pixels into TMDS encoder
      │
FPGA inserts audio samples into TMDS data islands
      │
      ▼
HDMI out (with embedded audio)
```

The LTDC (LCD-TFT Display Controller) is a standard STM32 peripheral that
reads a framebuffer from internal SRAM and outputs it as a continuous
parallel RGB video stream with sync signals. It generates its own timing
(HSYNC/VSYNC/DE) from programmed H and V totals, or can use an external
pixel clock.

Key advantage: **the FPGA never actively fetches the framebuffer.** It
simply captures the stream the N6 is already producing. The scan-out
bandwidth problem (which required the PIO-based per-cycle FETCH protocol)
disappears entirely.

#### Bulk data path (FPGA → N6 via PSSI)

For loading bitmaps, fonts, and icons from HyperRAM into the N6's SRAM:

```
6502 issues BLIT_FROM_HYPERRAM command via $D4xx
      │
      ▼
FPGA reads source data from HyperRAM
      │
      ▼
FPGA streams over PSSI: [BULK_TRANSFER opcode | dst_addr | length | pixel data…]
      │
      ▼
PSSI DMA writes the whole packet (header + payload) to a ring buffer in SRAM
      │
      ▼
M55 parses the 8-byte header: "BULK_TRANSFER to $20040000, 16384 bytes"
      │
      ▼
M55 reconfigures a DMA channel: src = ring buffer + 8, dst = $20040000, len = 16384
      │
      ▼
DMA copies payload to destination; M55 returns to DRAW dispatch
```

The CPU is involved for exactly one thing: **parsing the 8-byte header and
reprogramming the DMA descriptor.** This takes ~50 cycles on the 800 MHz M55
(~60 ns). The actual data move (16 KB of bitmap) happens in the background
while the M55 processes the next DRAW command.

Contrast with a non-bulk DRAW opcode (e.g. FILL_RECT):
```
PSSI receives [FILL_RECT | params…]
      │
      ▼
M55 parses header: "FILL_RECT, x=100 y=50 w=40 h=20 colour=$B4"
      │
      ▼
M55 writes NeoChrom registers → GPU executes in hardware
```

In both cases the CPU parses every packet header — PSSI is a dumb shift
register and has no opcode awareness. The difference is whether the payload
goes to NeoChrom (one register write) or to SRAM (DMA setup then background
copy). For bulk transfers the CPU is free after the DMA descriptor is
programmed; the data path avoids a memcpy through the CPU's register file.

#### Control/status path (N6 → FPGA via SPI)

```
STM32N6 (SPI slave)
      │
      ▼
FPGA (SPI master) initiates 3-byte transactions on register reads
  • getpixel(x, y) → N6 clocks back pixel value
  • Read queue depth
  • Write "command complete" status
  • Write VSYNC timestamp
      │
      ▼
FPGA presents results to 6502 via $D4EA/$D4EB (status + data)
```

The FPGA is SPI master because it already owns the pixel clock and line
counter — it knows exactly when to poll (VBI boundary, or on demand when
the 6502 writes a GETPIXEL command). The N6's SPI slave peripheral
responds within a few SPI clocks; no interrupt, no OS scheduling jitter.
FPGA-side state machine is ~50 LUTs — the simplest possible request/response
sequencer.

**Why SPI beats FMC here:**
- 4 wires vs 40+ for a parallel async SRAM interface
- No timing closure headache (SPI at 1–10 MHz is trivial in fabric)
- Every STM32 variant has SPI; FMC is not available on all packages
- The data volume is microscopic — under 10 bytes/frame for all control
  operations combined. SPI at 10 MHz saturates that in 8 µs.

### 12.5 Data flow for a typical frame

```
FRAME N:
  6502 processes events, updates window state
  6502 sends DRAW commands for changed regions:
    FILL_RECT (window background)
    DRAW_TEXT (window title, button labels)
    BLIT (transfer off-screen buffer to composite)
  FPGA captures $D4xx writes, pushes to PSSI FIFO
  PSSI delivers commands to N6 at ~200 MB/s
  N6 NeoChrom GPU renders into SRAM framebuffer
    (blit, fill, text — all hardware-accelerated)
  LTDC continuously streams completed framebuffer
    to FPGA at 25/40 MHz pixel clock
  FPGA captures RGB stream, TMDS-encodes, adds audio
  HDMI output with embedded audio

FRAME N+1:
  N6 LTDC is still streaming frame N while NeoChrom
    renders frame N+1 into the back-buffer
  FPGA never misses a beat — it just captures whatever
    LTDC sends
  VBI NMI fires from FPGA's ANTIC (synchronised to
    LTDC VSYNC or running freely with small FIFO)
```

### 12.6 Memory budget (STM32N657, 4.2 MB SRAM)

| Region | Size | Notes |
|--------|-----:|-------|
| **Framebuffer 0** (front) | 614 KB | 640×480×16-bit (RGB565). LTDC reads from here. |
| **Framebuffer 1** (back) | 614 KB | NeoChrom renders here while LTDC scans out FB0. |
| **Off-screen window buffers** (200 × 100×100) | 2,000 KB | One per window. Content cached; blit to framebuffer is a NeoChrom register write. |
| **Font cache** (4 typefaces × 128 KB) | 512 KB | Proportional fonts, multiple sizes. |
| **Icon cache** (128 icons × 64×64) | 512 KB | System icons, app icons. |
| **PSSI DMA ring** | 16 KB | Command FIFO for DRAW opcodes. |
| **SPI register window** | 1 KB | FPGA register file mirror (tiny — SPI carries bytes, not pages). |
| **ARM firmware + stack** | 256 KB | DRAW dispatch loop, device drivers. |
| **Free** | ~670 KB | Spare — additional buffers, app data. |
| **Total** | **4,200 KB** | |

This fits comfortably in a single N657 (4.2 MB) with room to spare. Even
the N653 (1.2 MB) fits a basic configuration (614 KB front buffer + 512 KB
back buffer = tight but workable with careful buffer management).

### 12.7 What NeoChrom GPU buys

The NeoChrom GPU is a 2.5D hardware accelerator with dedicated rasteriser,
blitter, and transform engine. For GEM, the relevant primitives:

| Operation | RP2354 software (C on M33) | NeoChrom (HW register) | Δ |
|---|---|---|---|
| **BLIT** (32×32 icon) | ~500 cycles | **1 register write** | ~500× |
| **FILL_RECT** (200×200) | ~40,000 cycles | **1 register write** | ~40,000× |
| **Alpha blend** (per pixel) | ~5 cycles | **0 cycles** (pipeline) | Free |
| **90° rotate** | ~2 cycles/pixel | **0 cycles** (hardware) | Free |
| **Full-screen composite** (blend 5 layers) | ~3 ms | **~0.1 ms** | ~30× |

NeoChrom doesn't just make things faster — it eliminates the DRAW dispatch
cost for common operations. A button press becomes: write `BLIT(src=button_buf,
dst=framebuffer)` to NeoChrom registers → GPU executes in background → done.
The M55 is free to process the next command immediately.

### 12.8 LTDC synchronisation

Two approaches to keep the FPGA's VBI generation in sync with the LTDC video
stream:

**A. Shared pixel clock (recommended)**
The FPGA generates `pix_clk` from its internal PLL (25.175 or 40 MHz) and
feeds it to the STM32N6's LTDC as its pixel clock input. Both sides use the
same clock edge. The FPGA's ANTIC core counts lines from the same `pix_clk`
divider that drives the LTDC's H/V counters. VSYNC from the LTDC is
optionally fed back to the FPGA as a phase check.

```
FPGA PLL ──pix_clk──→ STM32N6 LTDC PCLK input
                 │
                 └──→ FPGA video timing generator
                        (line counter, VBI generation)
```

**B. Free-running with line FIFO**
Both sides run at 60 Hz from independent clocks (close but not identical).
The FPGA captures LTDC output into a small line FIFO (2-4 scanlines). As
long as the average rate matches (both sweep ~525 lines × 60 fps), the
FIFO never underflows or overflows. VBI fires from the FPGA's internal
timing, not the LTDC's VSYNC.

Approach A is simpler and eliminates the FIFO. The Ti60 has sufficient PLL
resources to drive both the internal fabric and an external clock output
simultaneously.

### 12.9 Timeline delta

Switching from RP2354 to STM32N6 changes the engineering work:

| Phase | RP2354 variant | N6 variant | Notes |
|-------|----------------|------------|-------|
| **DRAW dispatch** | Implement DRAW ops in C on M33 | Implement DRAW ops using NeoChrom registers + PSSI DMA | Less C code, more register config. ~same time. |
| **FPGA↔chip bus** | PIO-based FETCH/SET/DRAW (proven) | PSSI TX + SPI master + LTDC capture (new) | New HDL for PSSI master, SPI master, LTDC capture. SPI is trivial (~50 LUTs), PSSI is ~200 LUTs. **~2 weeks** instead of 3. |
| **Framebuffer out** | Per-cycle FETCH from FPGA | LTDC capture (FPGA receives) | Simpler on the FPGA side (capture is easier than active fetch). ~same time. |
| **NeoChrom integration** | N/A | New: configure NeoChrom pipeline, link to DRAW dispatch | ~2 weeks. |
| **Memory management** | Tight 520 KB budget | Generous 4.2 MB budget | Less work (no buffer squeezing). |
| **Toolchain** | One (pico-sdk) | **Two** (pico-sdk + STM32Cube) | Setup, flashing, debugging across two vendors. ~1 week overhead. |

**Net delta: +3-5 weeks** over the RP2354 timeline. Replacing FMC with SPI
saves ~1 week of HDL effort and eliminates a timing-closure risk.

### 12.10 N6 vs RP2354: decision matrix

| Factor | RP2354 (current) | STM32N6 (variant) |
|---|---|---|
| **Memory** | 520 KB (tight) | **4.2 MB** (generous) |
| **GPU** | Software (C on M33) | **NeoChrom 2.5D HW** |
| **Cost** | ~$2-3 | ~$14 (N657) / ~$8 (N653) |
| **Toolchain** | pico-sdk (familiar) | pico-sdk + STM32Cube |
| **FPGA interface** | **PIO works now** (no new HDL) | PSSI + SPI + LTDC (new HDL; SPI is ~50 LUTs) |
| **Scan-out** | Per-cycle FETCH (works) | LTDC capture (simpler FPGA side) |
| **Audio over HDMI** | FPGA TMDS data islands | Same (FPGA unchanged) |
| **Part availability** | Good | Unknown |
| **Board complexity** | Two-layer feasible | More complex (BGA, routing) |
| **I/O count** | 44 (FETCH/SET/DRAW bus) | **42–50** (PSSI ~18 + SPI 4 + LTDC 28) |
| **Risk** | Low (prototype-proven path) | Medium (new interfaces) |

### 12.11 Recommendation

The RP2354 variant is **lower risk and faster to ship** — the PIO-based bus
works now, the toolchain is familiar, and the FPGA↔RP link is already
designed. The 520 KB SRAM is tight but workable, especially if you use
ANTIC-compat mode (154 KB framebuffer → 366 KB free for buffers).

**Switch to the N6 variant if**:
- You need 16-bit colour (RGB565) or double-buffered display, which
  push the RP2354's 520 KB over budget
- You want hardware-accelerated compositing for many overlapping windows
  (NeoChrom makes window drag with alpha shadows free)
- You're already doing the Ti60 PCB spin and the marginal cost of adding
  an N6 BGA is small relative to the board cost
- The 4-6 week schedule hit and dual-toolchain overhead are acceptable

**Go with a cost-reduced N6** (N653 at 1.2 MB, ~$8) if you only need the
memory and can live without NeoChrom acceleration — the M55 at 800 MHz
is fast enough for software rendering of GUI primitives, and 1.2 MB gives
comfortable room for a 614 KB framebuffer plus off-screen buffers.

**Stick with the RP2354** if you want to ship this year and can accept
the memory constraints (640×240 ANTIC-compat × 8-bit colour = comfortable).
The RP2354 path is less engineering, one toolchain, and proven hardware. A
future board revision can swap in an N6 once the interfaces are validated.
