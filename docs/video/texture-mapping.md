# Texture mapping on the 2D blitter

**Status**: design draft, 2026-06-01. No implementation started.

## Motivation

The blitter (`hdl/xt_blitter.sv`) already contains almost everything a
texture-mapping unit needs: a bilinear 2×2 sampler, fractional-weight
interpolation, alpha and destination blending, arbitrary-address source
reads, and a burst-accumulating writeback path — all timing-closed at
`clk_sys`. The one thing it does **not** do is map a source region onto a
rotated, sheared, or perspective-distorted destination: today's
"scaled blit" derives source `(u,v)` from **separable per-axis Bresenham**
stepping, which only expresses an axis-aligned rectangle→rectangle map.

Replacing that coordinate generator with a 2D linear (affine) iterator
turns the existing sampler into a real texture-mapping unit. The piece
added is smaller than the piece removed, and the entire sample/blend/write
back half of the pipeline is reused verbatim.

This document scopes the change in four tiers — affine point-sampled,
affine bilinear, textured triangles, and perspective-correct — and gives
the register map and FSM states for the first two (the easy, high-value
ones).

## What already exists (the reusable core)

The bilinear scaled-blit path (`CMD=0x06`, or `CMD=0x04 + FLAGS.BILINEAR`)
walks these states:

```
SC_BL_RD  → SC_BL_W  → SC_BL_WT  → SC_BL_ACC → SC_BL_BLEND → SC_BL_ACC2
(tap fetch) (latch)   (divider)   (weights)   (blend)        (writeback)
```

Of these:

| State          | Role                                              | Reuse for texture mapping |
|----------------|---------------------------------------------------|---------------------------|
| `SC_BL_RD`     | issue 4 single-beat AR reads (P00/P10/P01/P11)     | **verbatim** — fed new `sx_int/sy_int` |
| `SC_BL_W`      | latch tap pixels into `p00_q..p11_q`              | **verbatim** |
| `SC_BL_WT`     | 8-cycle sequential divider → `fx8/fy8`            | **deleted** (see below) |
| `SC_BL_ACC`    | compute weights `(256-fx)(256-fy)>>8`, etc.       | **verbatim** |
| `SC_BL_BLEND`  | 4-tap weighted sum → `bl_pixel_q`                 | **verbatim** |
| `SC_BL_ACC2`   | alpha-aware writeback / dest-read dispatch         | **verbatim** |

The burst accumulator (`burst_data`/`burst_strb`/`S_PEND`/`S_AW`/`S_W`/
`S_B`), the command queue, the register tap, and the partial-alpha
destination-blend pipeline (`SC_SBLEND*`) are all untouched.

The **only** texture-mapping-specific logic is the coordinate generator
that feeds `sx_int`, `sy_int`, `fx8`, `fy8`. Today that is:

```systemverilog
// SC_ROW / SC_NEXT / SC_NEXT2 — separable per-axis Bresenham
sx_accum_q += src_w_q;  if (sx_accum_q >= dst_w_q) { sx_step_q++; sx_accum_q -= dst_w_q; }
sy_accum_q += src_h_q;  if (sy_accum_q >= dst_h_q) { sy_cur_q++;  sy_accum_q -= dst_h_q; }
// SC_BL_WT then divides the accumulators to recover fx8/fy8.
```

This is axis-aligned: `u = src_x + (src_w/dst_w)·cx`,
`v = src_y + (src_h/dst_h)·cy`. No cross terms → no rotation, no shear.

## Tier 1 + 2: affine texture mapping

### The idea

Carry `u` and `v` as **signed fixed-point accumulators** (16.16) and step
them with a full 2×2 gradient instead of two independent 1D Bresenhams:

```
per pixel  (cx++):  u += dudx;  v += dvdx
per row    (cy++):  u_row += dudy;  v_row += dvdy;  u = u_row;  v = v_row
```

Then the source coordinate and the bilinear fraction fall straight out of
the accumulator with **no divider**:

```
sx_int = u[31:16]          fx8 = u[15:8]
sy_int = v[31:16]          fy8 = v[15:8]
```

Two consequences:

1. The 8-cycle sequential divider (`SC_BL_WT`, `xt_blitter.sv:2532`) is
   **deleted** — fractions are just the accumulator's low bits. The new
   path is shorter and faster per pixel than today's scaled blit.
2. `SC_BL_RD/W/ACC/BLEND/ACC2` are reused unchanged; they consume the new
   `sx_int/sy_int/fx8/fy8` exactly as they consume the divider's output.

A general 2×2 gradient `{dudx, dvdx, dudy, dvdy}` expresses any affine
map — scale, rotation, shear, flip (negative gradients), and combinations
— i.e. an arbitrary source **parallelogram** mapped to the destination
rectangle. Point-sampled (Tier 1) drops the fraction and issues one read
per pixel; bilinear (Tier 2) keeps it and issues four.

### Setup lives in PS software

Computing `{dudx, dvdx, dudy, dvdy, u0, v0}` from quad/triangle vertices
needs division and is done **once per primitive on the A9**, then written
to registers — consistent with the project rule that config/setup lives in
PS software and the fabric only plumbs hardware (see the PS-does-config
memory). The fabric iterates; it never divides for setup.

For a destination rectangle of width `W`, height `H`, mapping to source
corners `(u00,v00)` top-left and so on, the PS computes:

```
dudx = (u_topright - u_topleft) / W      (16.16 fixed)
dvdx = (v_topright - v_topleft) / W
dudy = (u_botleft  - u_topleft) / H
dvdy = (v_botleft  - v_topleft) / H
u0   = u_topleft,  v0 = v_topleft         (+ half-texel bias if desired)
```

### Register map

The gradients are 32-bit signed (16.16). Eight new little-endian byte
registers in the chiplet-extension page, plus a new command code. The
`$D4D0..$D4DF` block is free; the source-rectangle registers
(`$D4C0..$D4C7`) are unused in affine mode and could alias, but a fresh
block keeps the two paths independent.

```
  $D4D0  TEX_U0_0    W   u0  byte 0 (LSB)   16.16 source U origin (signed)
  $D4D1  TEX_U0_1    W   u0  byte 1
  $D4D2  TEX_U0_2    W   u0  byte 2
  $D4D3  TEX_U0_3    W   u0  byte 3 (MSB)
  $D4D4  TEX_V0_0..3 W   v0  (4 bytes)       16.16 source V origin (signed)
  $D4D8  TEX_DUDX    W   dudx (4 bytes)      16.16 dU/dx
  $D4DC  TEX_DVDX    W   dvdx (4 bytes)      16.16 dV/dx
  ---- second bank (dy gradients) reuses SRC_W/SRC_H slots, which are
       unused in affine mode: ----
  $D4C4  TEX_DUDY    W   dudy (4 bytes)      16.16 dU/dy  (overlays SRC_W/SRC_H)
  $D4C8  FLAGS       W   bit 1 (BILINEAR) selects Tier 2 vs Tier 1, as today
```

(Final slot assignment is cosmetic; the point is six 32-bit values plus
the existing `DST_X/Y/W/H` rectangle and `FLAGS.BILINEAR`.)

New command:

```
  $D4BC  CMD = 0x08 → affine textured blit
                      DST_X/Y/W/H = destination rectangle (bounding box)
                      TEX_*       = source affine coefficients
                      FLAGS.BILINEAR → 2×2 bilinear vs point sample
                      FLAGS.BLEND    → alpha-blend result with destination
```

`u0,v0,dudx,dvdx,dudy,dvdy` are snapshotted into the command FIFO at
`CMD` write, alongside the existing register snapshot
(`cmd_snapshot_in`, `xt_blitter.sv:558`). The 192-bit snapshot grows to
hold the six new 32-bit coefficients (or they ride in a parallel FIFO).

### New / changed FSM states

```
TX_ROW   : u_row += dudy; v_row += dvdy   (or load u0/v0 on first row)
           u = u_row; v = v_row; cx = 0
           → TX_RD            (bilinear)  or  TX_CALC (point)

TX_RD    : sx_int = u[31:16]; sy_int = v[31:16]; fx8 = u[15:8]; fy8 = v[15:8]
           (clamp/wrap sx_int,sy_int to source bounds — see below)
           issue tap read(s)  → reuse SC_BL_RD body  (bilinear)
                              or single read         (point, reuse SC_CALC)

  ... SC_BL_W / SC_BL_ACC / SC_BL_BLEND / SC_BL_ACC2 unchanged ...

TX_NEXT  : u += dudx; v += dvdx; cx++
           if (cx >= dst_w_q) → flush row (S_PEND) → TX_ROW or S_DONE
           else               → TX_RD
```

`SC_BL_WT` is bypassed entirely. `SC_ROW/SC_NEXT/SC_NEXT2`'s Bresenham
accumulate-and-loop is replaced by single adds — fewer logic levels, so
timing risk is low (we remove a multi-cycle divider and a
compare-subtract loop, and add four 32-bit adders).

### UV addressing outside the source

A rotated quad samples texels outside the axis-aligned source rectangle
that the scaled-blit path always stayed inside. Three options, cheapest
first:

- **Clamp**: `sx_int = clamp(sx_int, 0, src_w-1)` — two comparators per
  axis. Edge texels smear; fine for UI rotation.
- **Wrap (tile)**: mask `sx_int` to `src_w-1` when `src_w` is a power of
  two (a single AND) — ideal for repeating textures.
- **Guard-band / transparent border**: out-of-range → `wstrb=0`, reusing
  the existing transparent-pixel skip. Lets the PS pre-pad the texture.

A 2-bit `TEX_WRAP` field in `FLAGS` (clamp / wrap-pow2 / border) selects
the mode.

## Tier 3: textured triangles (half-space rasterization)

Tiers 1–2 fill the whole destination **rectangle**. Real 3D wants
triangles. The cheap, modern way: keep iterating the rectangle (the
triangle's bounding box) and add **three half-space edge functions**,
each a linear accumulator stepped exactly like `u/v`:

```
e0 += de0dx (per pixel), += de0dy (per row);   inside = (e0|e1|e2) sign-clear
```

When a pixel is outside any edge, force `wstrb=0` — which drops straight
into the existing transparent-pixel skip in `S_ACCUM_W2`/`SC_BL_ACC2`. No
new writeback logic. Cost: three more accumulators + a sign-AND. The PS
computes the edge coefficients from vertices (same setup pass as the UV
gradients). Effort: roughly ½–1 day on top of Tier 2.

## Tier 4: perspective-correct

Affine mapping is wrong for anything but flat-on quads — textures "swim"
on slanted surfaces. Perspective-correct needs a per-pixel divide:
interpolate `U, V, W` linearly (three more affine accumulators) and emit
`u = U/W, v = V/W`. Two divides per pixel.

The blitter already has a sequential restoring divider to copy
(`SC_BL_WT`, the one Tier 1 deletes). At ~16–24 cycles for two divides
per pixel this is a heavy throughput hit, so use the classic
**per-span perspective**: divide once every 8 or 16 pixels and linearly
interpolate `u/v` between the corrected samples. That adds a subdivision
counter and a second set of step registers — medium effort, and only
worth it once textured triangles (Tier 3) exist.

## The real ceiling: texel bandwidth

The honest caveat. Bilinear sampling issues **four single-beat (4-byte)
AXI reads per output pixel**, each paying full DDR latency, with only the
1-deep `sc_pixel` cache (which helps nearest-neighbour with repeated
addresses, not bilinear). Affine textured fills **work**, but throughput
is DDR-latency-bound, not fabric-bound — fine for UI rotation, sprite
transforms, and small textured polys; not for full-screen 3D.

The throughput upgrade, when wanted, is independent of the coordinate
math:

- Fetch the 2×2 quad as aligned 2-beat reads instead of four scattered
  single-beat reads (halves the AR count when P00/P10 and P01/P11 share an
  8-byte beat).
- A small **BRAM tile/line texture cache** so adjacent output pixels reuse
  texels — the standard fix, and a separate, larger project.

Neither blocks Tiers 1–3; they just raise the pixel rate afterward.

## Effort summary

| Tier | Feature                | Effort        | Notes |
|------|------------------------|---------------|-------|
| 1    | affine point-sampled   | ~1 day        | swap coord gen; reuse SC_ACCUM writeback |
| 2    | affine bilinear        | +½ day        | reuse SC_BL_*; **delete** the divider |
| 3    | textured triangles     | +½–1 day      | 3 edge functions → `wstrb` mask |
| 4    | perspective-correct    | +several days | per-span divide |
| —    | texture cache (perf)   | separate      | the real bottleneck if speed matters |

Tiers 1–2 are a small, low-risk extension that mostly reuses
already-timing-closed logic; the new arithmetic is shorter than what it
replaces. Tiers 3–4 are incremental on the same core.

## Validation

Mirror the existing blitter testbench (`sim/tb_xt_blitter.sv`): load a
known source texture into the framebuffer region, issue `CMD=0x08` with
identity gradients (`dudx=1.0, dvdy=1.0, others 0`) and confirm a textured
blit reproduces a plain copy; then a 90° rotation (`dudx=0, dvdx=1,
dudy=-1, dvdy=0`) and compare against a software-rotated golden. A
half-texel-shifted bilinear case checks the fraction alignment. The
render dump tools (`tools/render_antic_fb.py`) visualise results against
the live framebuffer.
