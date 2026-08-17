# Display compositor, sprites & desktop boot — design spec

Status: design, agreed 2026-05-25.  **Supersedes** the full-screen
`LEGACY_VIDEO` mux + pillarbox approach (a patch that assumed the Atari XL
owns the screen).  This spec describes the real model: a single always-on
1080p60 desktop compositor in which each emulation (and the desktop itself)
is a window.

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
   ┌──────────────────────────────────────────────────────────────┐
   │  plane compositor (clk_pix, 148.4375 MHz, 1920×1080)           │
   │                                                                │
   │   depth 0 (back) : desktop surface   (DDR3, blitter-drawn)     │
   │   depth 1        : Atari XL window    (DDR3, ANTIC-written)     │
   │   depth 2        : [future] Atari ST window (DDR3, soft-68k)    │
   │   depth top      : mouse cursor       (sprite)                  │
   │                                                                │
   │   each plane: {surface, src_w/h, origin, scale, depth,         │
   │                window_rect, clip_rect, enable}                 │
   │   + per-window sprites composited INSIDE the plane, before     │
   │     the inter-plane depth mux, clipped to clip_rect            │
   └──────────────────────────────────────────────────────────────┘
                              │ RGB565 + sync
                              ▼  SiI9022A → HDMI
```

Producers write DDR3 surfaces independently:

```
   ARM core0 (GEM via blitter, fabric) ─ HP1 write   ─► desktop surface
   ANTIC (fabric)                       ─ HP3 write   ─► XL surface (double-buffered)
   ARM core1 (soft-68k, CPU→DDR direct) ─ no HP port  ─► ST surface [future]
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

Generalises `fb_scanout` (single-plane DDR3 read + line buffer) to **N planes
with depth + integer scale + clip**.  `fb_scanout`'s AXI-read + ping-pong
line-buffer machinery becomes the per-plane *fetch unit*.

### 4.1 Per-plane registers (ARM-writable via GP0)

```
PLANE[i]:
  enable        : 1
  surface_base  : 32   (front buffer; producer-flipped for live planes)
  stride_bytes  : 16
  src_w, src_h  : 12,12   // source pixels (tracks the producer's active size)
  origin_x,y    : 12,12   // top-left on the 1920×1080 screen (signed-capable)
  scale         : 3       // integer 1..5 (see §7)
  depth         : 4       // unique per enabled plane; higher = nearer front
  clip_x,y,w,h  : client (visible) rect on screen; ⊆ window rect; sprites+
                  playfield clip to this.  v1: = window rect.
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

ANTIC currently renders `compositor → line_buffer(384) → scan_out →
palette_lut → hdmi_out(800×600 native)`.  The native `hdmi_out`/`scan_out`
chain is **bypassed for output**; instead:

```
ANTIC compositor (palette indices, per Atari row)
   → palette_lut → RGBA8888
   → AXI write master → XL surface (double-buffered) in DDR3
   → flip front_sel on ANTIC vblank
```

- Decoupled from the 1080p compositor: ANTIC writes at the Atari frame rate;
  the compositor reads the front buffer at 1080p60.
- `src_w/src_h` track the live playfield (narrow/normal/wide; ≤ 384×240); the
  writeback reports the active dimensions so the plane geometry follows.
- Reuses `palette_lut` (already in the chain).  New work: the streaming AXI
  write master + double-buffer/vblank-flip.
- This is task #7 ("ANTIC capture") **retargeted from BRAM to DDR3**.
  `legacy_upscale`'s BRAM frame store is dropped; its integer scaler is
  replaced by the compositor's §4.2 accumulator scaler.

### 5.1 ANTIC native raster — replace the 800×600 display heartbeat

**Decision (2026-05-25):** ANTIC must render at its **own native raster**,
paced by **phi2**, not by a display pixel clock.

Background: `antic_top` still instantiates the legacy display chain
(`hdmi_out` + `vbeam` @ 800×600, `scan_out`, the native `line_buffer`, a
display `palette_lut`).  In the compositor model that whole chain is **dead
weight** — `antic_rgb_*`/`tmds_*` are driven but consumed nowhere; the pads
come from the compositor.  The 800×600 `vbeam` survives only as a *raster
heartbeat*: it generates `atari_row` (0..191), `line_start`, `vbi_start`,
which feed `nmi_gen`, the (now-bypassed) line-buffer swap, and the §5
writeback (`row_flush` / `frame_done` / `atari_row`).

Two problems with that heartbeat:

1. It is clocked by the **148.4375 MHz `clk_pix`** while carrying 800×600@60
   timing (which wants ~40 MHz), so ANTIC "frames" run at ~224 Hz with a
   ~140 kHz line rate.
2. It is **not locked to phi2.**  ANTIC's VCOUNT / WSYNC / DLI+VBI NMI cadence
   therefore drift arbitrarily against the CPU — wrong for the *emulation*
   (the OS times off VBI/RTCLOK), even though a window still appears because
   the §3 double buffer decouples capture from the 1080p60 read.

**Target:** a small **phi2-derived native raster timer** inside `antic_top`,
using the existing `phi2_tick`:

```
scanline = 114 machine cycles (NTSC) ;  frame = 262 lines (NTSC) / 312 (PAL)
count phi2_tick: 114 → line_start, atari_row++
count lines:     262 → vbi_start, atari_row = 0
```

- `atari_row` spans the true active region (0..191 nominal; up to 0..239
  overscan) — **no line-doubling, no letterbox** (both were display
  artifacts).  ANTIC then renders its true native resolution at the true
  Atari frame rate, exactly as §5 / §10 assume.
- This **replaces** the vbeam heartbeat; the §5 writeback and the §4 compositor
  are unchanged (they consume `atari_row`/`line_start`/`vbi_start` + the pixel
  stream regardless of source) — a clean module boundary.
- It also lets `hdmi_out`, `scan_out`, the native `line_buffer`, and the
  display `palette_lut` be **deleted** (the writeback owns its own palette).
- **Coupled scope:** ANTIC's render *trigger* used to be a scaffold
  (`dl_parser`/`compositor` fired off a free-running `kick_counter`, not a real
  per-scanline walk).  Doing it properly means the phi2 timer drives **both**
  the line/frame pulses and per-row compose — i.e. it finishes the ANTIC native
  raster *sequencer*.  This is the emulation-timing-sensitive part; gated
  behind the existing phi2/CPU conformance (Klaus is unaffected — it's already
  phi2-based).  **Done in task-0014** (see below).

Status: **built** (task-0013 + task-0014, 2026-05-25).  task-0013
(`prompts/task-0013-antic-native-raster.md`): `antic_raster` paces ANTIC off
phi2 and the 800×600 display chain is deleted; ANTIC's only image path is the
§5 writeback tap.  task-0014 (`prompts/task-0014-antic-render-sequencer.md`):
the `kick_counter` scaffold is replaced by `antic_seq`, a phi2-raster-locked
sequencer — `dl_start` once per frame at `vbi_start` (parse the whole display
list into dl_parser's 192-entry meta table during vblank), `cmp_start` once per
active scanline at `line_start`.  The `compositor` now composes one row per
`start_compose` (row = `ar_atari_row`), so the frame is walked in raster order
in lockstep with the CPU: mid-frame register writes / DLIs land on the correct
scanline.  ANTIC native raster is now fully done (heartbeat + dead-chain
deletion + sequencer).

### 5.2 Publish the frame on the WRITEBACK'S ROW WRAP, never on ANTIC's vbi

The triple buffer only decouples producer from consumer if the rows landing in a
slot between two publishes are **one contiguous top-to-bottom pass**.  ANTIC's
vbi does NOT give you that: it fires when the **display list ends**, while the
writeback's row index comes from the raster timer and wraps independently.  Any
display list shorter than the nominal 192-line window makes the two diverge, so
the 192 rows written between publishes span two frames — rows `first..191` from
one and `0..first-1` from the next — and the published slot is torn at `first`,
by exactly one frame of motion, with the top band newer.

That was a real bug (fixed 89d143ad).  On hardware every moving object in the XL
plane split at one screen row; the row was constant within a run and different on
every Atari cold start, because it is the wrap phase and that is re-rolled each
time the Atari starts.  BallBlazer's display list is ~144 lines, a test probe's
120, and BASIC's happens to align — which is why the machine looked clean at idle
and tore differently on every launch.

`fpga_xt_top` therefore derives `frame_done` from the writeback's own wrap
(`xl_row_wrap = (wb_row_live < xl_row_q)`), which makes a slot a contiguous pass
by construction whatever the display list does.  `sim/tb_xl_publish.sv` pins it,
and deliberately runs both anchors side by side so it fails if the vbi anchor
ever looks clean.

**When the m68k plane lands it needs the same treatment** — anchor its publish to
its own writeback row wrap, not to any end-of-frame signal from the source
machine.  Nothing in the RTL wires a second plane's publish yet.

### 5.3 Two display probes worth knowing about

Both build a standalone `.xex` and are the reliable way to ask a display question
on hardware, because they hold still or carry their own ruler:

* `tools/tear_probe_scene.py` — one full-height quad-width player on a black
  field whose HPOS advances by a **known** step each frame.  No tear → one
  unbroken bar; tear → segments offset by exactly the step.  Self-calibrating,
  which is what made the tear measurable at all: in the game the offset has to be
  recovered from consecutive frames, and every single-frame detector is fooled by
  the intro's slanted ramp edges.
* `tools/mode9_fifthplayer_scene.py` — a **still** scene in BallBlazer's own
  configuration (PRIOR `$54` = GTIA mode 9 + fifth player, quad players, missiles
  packed), with PRIOR overridable so the two features can be bisected against each
  other.  That bisect found the fifth player being dropped in mode 9 (59395858).

Grab them with `graboverlay`, never `fbgrab`: fbgrab reads the DESKTOP plane and
the emulator window is an alpha=0 hole in it, so it comes out black at any speed.

## 6. Unified sprite engine

One scalable engine; sprites live in their **owning window's native
coordinate space** and inherit that window's `{scale, origin, depth,
clip_rect}`.

### 6.1 Per-sprite descriptor

```
SPRITE[s]:
  enable      : 1
  window      : which plane it belongs to (provides scale/origin/clip/depth)
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

The existing `sprite_engine` (descriptor regs `$D4Ax/$D4Dx`, between
`fb_scanout` and the pins) generalises into this; its descriptors move into
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
(independent read + write channels), 150 MHz.  They exist so **PL-fabric
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
  HP port — `sally_mem`'s `m_axi_*`, on `clk_sally` (100 MHz), tied off today.

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
  (R) + XL writeback (W).  This is what's wired today (phase 2).
- **HP2 conflict resolved**: earlier text had HP2 = sprites *and* a separate plan had
  HP2 = SALLY banked DDR.  Sprites are light and homogeneous with the other
  clk_sys plane reads, so the **sprite-image fetch moves onto HP0's read
  SmartConnect**; HP2 is dedicated to SALLY's banked window (its own
  `clk_sally` domain — keeping it isolated avoids a clock converter and the
  100 MHz path dragging the 150 MHz compositor reads).
- **ST/TT adds no new port**: emulated RAM is ARM/DDR-direct; the surface is
  ARM-written (no write master); the compositor's ST plane fetch is just
  another read on HP0's SmartConnect.
- Spare for later: the **ACP** (cache-coherent ARM↔PL) and **S_AXI_GP**
  ports are unused — available if a master wants its own port.

### 10.2 Bandwidth (sanity)

clk_pix = 148.4375 MHz; 2200×1125 total per frame.  Each active plane fetches
one (scaled) source line per scanline into its line buffer — the pattern
`fb_scanout`/`plane_fetch` already sustains for one plane on HP0.

- DDR3-1066 ×32-bit ≈ 4.3 GB/s peak, ~2.5–3 GB/s usable; each HP port ≈
  1.2 GB/s (64-bit @ 150 MHz).
- Desktop fetch (full-screen, scale 1) ≈ 1920×1080×4×60 ≈ 0.5 GB/s.  A
  full-screen ST/TT plane ≈ another 0.5 GB/s.  XL fetch/writeback and sprites
  are tiny (XL ≈ 320 px/line × window lines × 60 ≈ tens of MB/s).
- So even desktop + full-screen ST/TT ≈ 1 GB/s — under one port, well under
  DDR.  **The constraint is port count/arbitration, not bandwidth** — and
  SmartConnect handles count.

Full-line fetch (including occluded spans) is fine at this N; visible-span-only
fetch is a later optimisation.

## 11. Migration from current RTL

**Keep:** SALLY core + `sally_mem` (gaps 1–3 — XL must function regardless of
display), `xt_blitter`, `palette_lut`, `vbeam`, `line_buffer`,
`cdc_*`, `hwreg_rd_cdc`.

**Generalise:**
- `fb_scanout` → multi-plane compositor (its AXI-read + line buffer = one
  fetch unit; add N planes, depth mux, clip, accumulator scaler).
- `sprite_engine` → unified per-window scaled+clipped sprite engine (§6).
- `legacy_upscale` → its scaler folds into §4.2 (source becomes DDR3; drop the
  BRAM frame store; switch power-of-two shift → integer accumulator).

**Delete:** the `LEGACY_VIDEO` full-screen mux in `fpga_xt_top`.

**New:** ANTIC→DDR3 writeback master (§5); the plane compositor (§4); GP0
register re-partition (§9); double-buffer/front-sel plumbing (§3).

**Retarget:** task #7 (ANTIC capture) → ANTIC→DDR3 writeback.

> **Open work / next steps** are tracked in [NextSteps.md](../NextSteps.md) — see "Video / compositor / sprites / textures".

## 14. Phased implementation

1. **Compositor core**: 2 fixed planes (desktop + one window), depth mux,
   accumulator scaler, clip rect, background colour.  Replace `fb_scanout` at
   the top; default config reproduces today's single desktop plane.
2. **ANTIC→DDR3 writeback**: stream RGBA to the XL surface, double-buffered.
   Wire the XL surface as plane 1.  → first visible windowed XL.
3. **Unified sprite engine**: per-window scaled+clipped sprites; map XL P/M.
4. **v1 desktop.app**: blue fill + plane config + XL auto-start.
5. **GP0 register re-partition** + ARM driver for plane/sprite/window control.

Each phase is independently sim-checkable (compositor + writeback at a reduced
raster, like `tb_legacy_upscale`) before win10 synth + hardware bring-up.
