---
title: "Display compositor, sprites & desktop boot"
description: "The always-on 1080p60 plane compositor in which the Atari XL is a movable, scalable window — surfaces, planes, scaling, sprites, and AXI HP allocation."
---


The display is a single always-on 1080p60 desktop compositor: each emulation —
and the desktop itself — is a movable, integer-scalable window rather than
owning the screen.  `fpga_xt_top` drives the display with `vbeam` (raster) +
`plane_fetch` ×N (per-plane DDR3 line read) + `plane_compositor`
(depth/scale/clip mixer).

## 0. Goals

- One always-on **1080p60** output.  The compositor owns the screen.
- The ARM runs a windowed desktop (`desktop.app`); the Atari XL is a
  **window** within it — movable, integer-scalable (1–5×), or full-screen.
- Architecture must extend, with no rework, to a second live system (Atari
  STe/TT on the second ARM as a software 68k) running concurrently.
- A **unified sprite engine** serves every emulation (XL P/M, a full-colour
  `Sprite.xt` class, ST/TT sprites) and the desktop cursor.
- v1 ships a minimal stack: blue desktop + the XL auto-started in a window,
  booting to BASIC.  GEM, windowing and input routing land later.

## 1. Principles

1. **Every window is a DDR3 surface** (RGBA8888).  The compositor is a small
   set of hardware *planes* that read those surfaces.
2. **GEM windows are software-composited** by the blitter into the desktop
   surface — they are NOT hardware planes.  Only sources that update
   independently of the desktop (the desktop FB, each live emulation, the
   cursor) are hardware planes.  So the plane count is small (~4 for v1).
3. **Move / scale / restack = register writes only.**  No redraw, no
   re-rasterisation.
4. **Decouple producer rate from 1080p60** via double-buffered surfaces.

## 2. Layered model

```
 ┌───────────────────────────────────────────────────────┐
 │ plane compositor (clk_pix, 148.4375 MHz, 1920×1080)   │
 │                                                       │
 │depth 0     : desktop surface   (DDR3, blitter-drawn)  │
 │depth 1     : Atari XL window    (DDR3, ANTIC-written) │
 │depth 2     : [future] Atari ST window (DDR3, soft-68k)│
 │depth (top) : mouse cursor       (sprite)              │
 │                                                       │
 │  each plane: {surface, src_w/h, origin, scale, depth, │
 │               window_rect, clip_rect, enable}         │
 │  + per-window sprites composited INSIDE the plane,    │
 │    before the depth mux, clipped to clip_rect         │
 └───────────────────────────────────────────────────────┘
                            │ RGB565 + sync
                            ▼  SiI9022A → HDMI
```

Producers write DDR3 surfaces independently:

```
   ARM core0 (GEM via blitter, fabric) 
   	─ HP1 write   ─► desktop surface
   	
   ANTIC (fabric)                       
    ─ HP3 write   ─► XL surface (double-buffered)
    
   ARM core1 (soft-68k, CPU→DDR direct) 
    ─ no HP port  ─► ST surface [future]
```

(HP ports carry *fabric* masters only; an ARM core writing a surface uses the
PS DDR path directly — see §10.0.)

## 3. DDR3 surface model

A **surface** is a linear RGBA8888 framebuffer:

```
surface = { base, stride_bytes, width, height }   // RGBA8888, R in low byte
```

**Double buffering** (live sources only — desktop FB is single-buffered, it's
drawn incrementally):

- Two buffers `base_A` / `base_B`.  The producer writes the back buffer and,
  on its own vblank, flips a `front_sel` bit.
- The compositor samples `front_sel` at *its* frame start (clk_pix vblank) and
  reads the indicated buffer for the whole frame → no tearing, no lock.
- `front_sel` crosses producer-clock → clk_pix as a 2-FF synchronised bit
  (single bit, glitch-free).

DDR3 map (1 GB, `0x0000_0000`–`0x3FFF_FFFF`; PS/FSBL/app low):

| Region            | Base          | Notes                                   |
|-------------------|---------------|-----------------------------------------|
| Desktop surface   | `0x3000_0000` | existing `FB_BASE`, 1920×1080, stride 8192 |
| XL surface A/B    | `0x3100_0000` / `0x3110_0000` | ≤ 384×240×4 ≈ 368 KB each |
| ST surface A/B    | `0x3200_0000` / `0x3210_0000` | [future] up to 1920×1080×4 = 8 MB |
| Sprite images     | `0x3300_0000` | shared pool                             |

(Illustrative; finalised in implementation.  Keep clear of the deferred
banked-DDR3 region at `0x2000_0000`.)

## 4. Plane compositor

Reads **N planes from DDR3 with per-plane depth + integer scale + clip**.  Each
plane has its own *fetch unit* — an AXI read + ping-pong line buffer
(`plane_fetch`).

### 4.1 Per-plane registers (ARM-writable via GP0)

```
PLANE[i]:
 enable        : 1
 surface_base  : 32   (front buffer; flipped for live planes)
 stride_bytes  : 16
 src_w, src_h  : 12,12   // source pixels (tracks the active size)
 origin_x,y    : 12,12   // TL on the 1920×1080 screen (signed)
 scale         : 3       // integer 1..5 (see §7)
 depth         : 4       // per enabled plane; higher = nearer top
 clip_x,y,w,h  : client (visible) rect on screen;
                 ⊆ window rect; 
                 sprites+playfield clip to this.  
                 v1: = window rect.
```

Derived window rect: `[origin_x, origin_x + src_w*scale) × [origin_y, … + src_h*scale)`.

### 4.2 Integer scaling — accumulator, not shift

Scales 2/3/4/5 are **not** all powers of two, so back-mapping uses a
divider-free accumulator (nearest-neighbour upscale):

```
// horizontal, per output pixel within the plane's clip span:
at clip-left:  src_col = src_x0;  sub = 0
each output x: if (++sub == scale) { sub = 0; src_col++ }
// vertical, per output scanline within the plane's clip span: same with src_row.
```

So `src_col` advances once every `scale` output pixels; any integer scale,
no divider.  (This corrects `legacy_upscale`'s power-of-two-only shift.)

### 4.3 Per-scanline / per-pixel algorithm

```
per scanline y:
  for each plane i:
     active[i] = enable[i] && (y in clip_rect_y[i])
     if active[i]: prefetch scaled source row (src_row = (y-origin_y)/scale)
                   from DDR3 into plane i's ping-pong line buffer
per pixel x:
  cover = { i : active[i] && (x in clip_rect_x[i]) }
  winner = argmax_{i in cover} depth[i]      // priority encoder
  pixel  = (cover empty) ? BG_COLOR
                         : line_buf[winner][ (x-origin_x[winner])/scale ]
```

Cost: N range-comparators + a priority encoder + a mux in the pixel path; N
line-buffer fetch units.  Fully combinational select; deterministic.
**"Bring window forward" = write `depth`.**

### 4.4 Depth = rectangle priority (NOT a depth bitmap)

Because GEM windows are software-composited into the desktop FB, the hardware
only sees a few planes, so rectangle+priority is sufficient and cheap.  A
per-pixel ownership/depth bitmap (needed only for arbitrary non-rect occlusion
of *live* planes by *arbitrary* desktop windows) is **deferred** — it costs an
extra full-screen read every frame plus ARM rasterisation of the window stack.

Not-cornered upgrade path:
- **Clip rect** (already in the register set) handles a lot of partial
  occlusion: a window clipped to its visible sub-region.
- A future **bitmap mode** can override the priority-encoder result with a
  looked-up window-ID for the regions that need it — additive, not a rewrite.

Hard requirement met: bring XL/ST forward = depth write.  Desktop-window-over-
live-window = deferred (clip-rect promotion, then bitmap mode).

## 5. ANTIC → DDR3 writeback (the XL plane source)

ANTIC renders to a DDR3 surface (the XL plane source) rather than to a display
output of its own:

```
ANTIC compositor (palette indices, per Atari row)
   → palette_lut → RGBA8888
   → AXI write master (`antic_writeback`) → XL surface (double-buffered) in DDR3
   → flip front_sel on ANTIC vblank
```

- Decoupled from the 1080p compositor: ANTIC writes at the Atari frame rate;
  the compositor reads the front buffer at 1080p60.
- `src_w/src_h` track the live playfield (narrow/normal/wide; ≤ 384×240); the
  writeback reports the active dimensions so the plane geometry follows.
- Reuses `palette_lut`; the streaming AXI write master and the double-buffer /
  vblank-flip are the writeback's own logic.
- `legacy_upscale`'s BRAM frame store is dropped; its integer scaler is
  replaced by the compositor's §4.2 accumulator scaler.

### 5.1 ANTIC native raster

ANTIC renders at its **own native raster, paced by phi2**, not by a display
pixel clock.  A phi2-derived raster timer inside `antic_top` (using `phi2_tick`)
generates the line/frame cadence:

```
scanline = 114 machine cycles (NTSC) ;  frame = 262 lines (NTSC) / 312 (PAL)
count phi2_tick: 114 → line_start, atari_row++
count lines:     262 → vbi_start, atari_row = 0
```

- `atari_row` spans the true active region (0..191 nominal; up to 0..239
  overscan) — no line-doubling, no letterbox.  ANTIC renders its true native
  resolution at the true Atari frame rate.
- Pacing off phi2 keeps ANTIC's VCOUNT / WSYNC / DLI+VBI NMI cadence locked to
  the CPU, which the emulation depends on (the OS times off VBI/RTCLOK).
- `line_start` / `vbi_start` / `atari_row` feed `nmi_gen` and the §5 writeback;
  the §4 compositor consumes the writeback's DDR3 surface and is independent of
  ANTIC's raster source — a clean module boundary.

The render *sequencer* (`antic_seq`) runs off the same timer: it parses the
whole display list into `dl_parser`'s 192-entry meta table once per frame at
`vbi_start`, and issues `cmp_start` once per active scanline at `line_start`.
The `compositor` composes one row per `start_compose` (row = `ar_atari_row`), so
the frame is walked in raster order in lockstep with the CPU — mid-frame
register writes and DLIs land on the correct scanline.

## 6. Unified sprite engine

One scalable engine; sprites live in their **owning window's native
coordinate space** and inherit that window's `{scale, origin, depth,
clip_rect}`.

### 6.1 Per-sprite descriptor

```
SPRITE[s]:
  enable      : 1
  window      : which plane it belongs to 
                (provides scale/origin/clip/depth)
  image_base  : DDR3 (or BRAM cache) pointer
  fmt         : full-colour RGBA (Sprite.xt) | paletted/P-M (XL)
  native_x,y  : position in window-native pixels
  w, h        : sprite size in native pixels
  priority    : vs the window's playfield and among sprites
  key/alpha   : transparency (colour-key or alpha)
```

### 6.2 Compositing

- Sprites composite **inside the owning window, before the inter-plane depth
  mux**: `window_pixel = playfield ⊕ sprites(by priority)`, all in the
  window's native space, then scaled and depth-muxed as one plane.
- `screen_pos = origin + native*scale`; each sprite pixel is a `scale×scale`
  block.
- **Clipping to the window edge is structural**: sprites are evaluated in
  native coords and only emitted within the plane, and additionally bounded by
  `clip_rect` (the client area, excluding chrome).  A sprite straddling the
  edge is cut **pixel-accurately regardless of scale** (the test is per output
  pixel).  This is *why* sprites composite per-window, not globally — globally
  they would bleed across windows and force explicit clipping.
- **Mouse cursor**: a window-less sprite at top depth, `clip_rect` = full
  screen.

### 6.3 Usage

- **XL**: the emulation programs P/M graphics onto the engine; they scale with
  the window automatically.  `Sprite.xt` adds full-colour native sprites.
- **ST/TT** [future]: same engine, ST/TT resolutions, native 1080p, or scaled.

The existing `sprite_engine` (descriptor regs `$D4Ax/$D4Dx`, between the
compositor and the pins) generalises into this; its descriptors move into
the compositor register space and/or stay emulation-programmable.

## 7. Resolutions & integer scaling

Output is always 1920×1080.  Per-plane integer scale; centre or position via
`origin`.  Scales that fit:

| Emulation / mode | Native    | Scales (fit in 1920×1080)            |
|------------------|-----------|--------------------------------------|
| Atari XL         | ≤384×240 (nominal 320×200) | 1,2,3,4,5 (320×5=1600, 200×5=1000) |
| STe/TT 320×200   | 320×200   | 1..5                                 |
| STe/TT 640×200   | 640×200   | 2 (1280×400), 3 (1920×600)           |
| STe/TT 640×400   | 640×400   | 2 (1280×800)                         |
| STe/TT GEM       | 1920×1080 | 1 (native)                           |

Full-screen = the largest fitting scale, centred (pillarbox/letterbox is just
the background showing where no plane covers).

## 8. v1 bring-up (minimal stack)

**Boot:** first-stage bootloader (ARM core0) — FSBL brings up PS / DDR3 /
clocks / MIO, loads the bitstream, starts the app.  v1 `desktop.app` is baked
into the FreeRTOS image (loading an external app from SD is a later feature).

**v1 `desktop.app`:**
1. Clear the desktop surface to blue (direct fill or blitter rect).
2. Configure the desktop plane: depth 0, scale 1, full screen, enable.
3. Configure the XL plane: surface = XL front buffer, origin/scale (e.g. 3×,
   centred), depth 1, enable.
4. Release the XL core from reset; it boots to BASIC inside its plane.

**Result:** a blue 1080p desktop with the Atari XL booting to `READY` in a
scaled window.  Exercises the real pipeline: plane compositor (2 planes),
ANTIC→DDR3 writeback, and the XL core (gaps 1–3).  No GEM, no windowing, no
input routing yet; XL keyboard via the existing `$D4CF` GP0 inject path (or
the debug UART) for poking.

## 9. Register map (GP0 @ `0x43C0_0000`)

The GP0 AXI-Lite window needs a clean device decode (currently blitter
`$0000–$001F` + ROM-loader claiming the rest 1:1 — that conflicts with adding
register blocks).  Proposed offset map (migration item):

| Offset range  | Device                                  |
|---------------|-----------------------------------------|
| `$0000–$00FF` | blitter registers                       |
| `$0100–$02FF` | compositor: global + PLANE[0..3]        |
| `$0300–$05FF` | sprite engine: SPRITE[0..N]             |
| `$0800–$08FF` | XL window control (reset, kbd inject)   |
| `$1000–$FFFF` | ROM-loader (SALLY rom_addr 1:1)         |

Global compositor regs: `BG_COLOR`, frame status/IRQ.  Plane/sprite regs per
§4.1 / §6.1.

## 10. AXI HP port allocation + bandwidth

### 10.0 The model — HP ports are for *PL* masters only

The Zynq-7020 has **4 AXI-HP slave ports** (HP0–HP3), each 64-bit, full-duplex
(independent read + write channels), 133.3 MHz.  They exist so **PL-fabric
masters reach PS DDR3**.  The **ARM cores reach DDR natively** through L1/L2 +
the DDR controller — they *never* use an HP port.  Consequences:

- An emulation hosted *on an ARM core* (the future ST/TT soft-68k on core1)
  accesses its emulated RAM through the ARM's own memory path — *higher*
  bandwidth than any HP port, and not on this map at all.
- A surface *written by an ARM core* (the ST/TT surface, written by the
  soft-68k as CPU stores) needs **no HP write master**.  Only a surface
  written by *fabric* does — ANTIC, hence `antic_writeback`.
- A surface *read by the compositor* always needs an HP **read** channel
  (the plane fetch is fabric), whoever produced it.
- **SALLY** is fabric, but its main memory is BRAM (bank 0); boot-to-BASIC
  touches no DDR.  Only the *extended banked-memory* model (deferred) needs an
  HP port — `sally_mem`'s `m_axi_*`, on `clk_sally` (100 MHz), tied off.

So "what needs a port" is just the fabric masters, and one full-duplex port
can host a read master and a write master at once.  Where more masters than
ports exist, a BD **SmartConnect** fans several into one HP port (arbitration,
shared bandwidth) — §10.2 shows there is ample headroom.

### 10.1 Port allocation

| Port | Read channel | Write channel | Clock |
|------|--------------|---------------|-------|
| HP0  | compositor reads — desktop + ST/TT + sprite-image fetch (SmartConnect) | — | clk_pix/clk_sys |
| HP1  | blitter source | blitter dest (desktop surface) | clk_sys |
| HP2  | SALLY banked DDR (extended model) | SALLY banked DDR | clk_sally (100 MHz) |
| HP3  | XL plane fetch | XL writeback (`antic_writeback`) | clk_sys |

Notes:
- **HP3 is the XL *window* port, not a generic "compositor" port** — XL fetch
  (R) + XL writeback (W).
- **Sprites share HP0**: sprites are light and homogeneous with the other
  clk_sys plane reads, so the sprite-image fetch rides HP0's read SmartConnect;
  HP2 is dedicated to SALLY's banked window (its own `clk_sally` domain —
  keeping it isolated avoids a clock converter and the 100 MHz path dragging
  the 133.3 MHz compositor reads).
- **ST/TT adds no new port**: emulated RAM is ARM/DDR-direct; the surface is
  ARM-written (no write master); the compositor's ST plane fetch is just
  another read on HP0's SmartConnect.
- Spare for later: the **ACP** (cache-coherent ARM↔PL) and **S_AXI_GP**
  ports are unused — available if a master wants its own port.

### 10.2 Bandwidth (sanity-check)

clk_pix = 148.4375 MHz; 2200×1125 total per frame.  Each active plane fetches
one source line into its line buffer **per source-row change** — a scaled
plane presents the same row for `scale` scanlines and `plane_fetch` skips the
duplicate fetches, so its read traffic is the surface's, not the screen's.  A
scale-1 plane fetches every scanline; one `plane_fetch` unit sustains a single
plane on HP0.

- DDR3-1066 ×32-bit ≈ 4.3 GB/s peak, ~2.5–3 GB/s usable; each HP port ≈
  1.07 GB/s (64-bit @ 133.3 MHz).
- Desktop fetch (full-screen, scale 1) ≈ 1920×1080×4×60 ≈ 0.5 GB/s.  A
  full-screen ST/TT plane ≈ another 0.5 GB/s.  XL fetch/writeback and sprites
  are tiny (XL ≈ 320 px/line × window lines × 60 ≈ tens of MB/s).
- So even desktop + full-screen ST/TT ≈ 1 GB/s total — split across ports
  (≈0.5 GB/s each, comfortably under a port's ~1.07 GB/s), well under DDR.
  **The constraint is port count/arbitration, not bandwidth** — and
  SmartConnect handles count.

Full-line fetch (including occluded spans) is fine at this N; visible-span-only
fetch is a later optimisation.

## 11. Deferred / future

- Desktop-window-over-live-window occlusion (clip-rect promotion, then bitmap
  mode, §4.4).
- GEM-on-ARM, the windowing system, input routing (keyboard/mouse from the
  companion MCU → focused window).
- STe/TT emulation on ARM core1 (software 68k); its DDR3 surface + plane.
- Configurable boot-direct-to-XL (skip the desktop).
- Visible-span-only plane fetch (bandwidth optimisation).
