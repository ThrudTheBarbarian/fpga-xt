# VDI software implementation guide — xt-blitter interface

This document describes how a PS-side GEM-like graphics stack maps
each VDI call to blitter register writes.  It assumes a FreeRTOS task
on the Cortex-A9 (or bare-metal loop) that reads the `busy` status
bit and pokes the blitter's $D4xx register window.

Each section below covers one VDI function, the blitter command it
maps to, the register setup the PS must perform, and any multi-pass
or alignment rules.

---

## 1.  Blitter calling convention (all commands)

1. Write all parameter registers ($D4B0..$D4BF, $D4C0..$D4CF).
2. Optionally write FLAGS ($D4C8) with modifier bits (see below).
3. Write CMD ($D4BC) with the command byte.
4. Poll `busy` (read chip select at any $D4xx address, bit 0 or
   dedicated status register) until it clears.
5. The blitter has latched all registers at the CMD write strobe;
   registers can be reused for the next call immediately after
   `busy` goes low.

Register writes are **byte-wide**.  16-bit values are written
little-endian: low byte first, then high byte.  All register
addresses live in the $D4xx page of the SALLY hwreg bus.

### 1.1  FLAGS register ($D4C8)

Optional 8-bit qualifier written before CMD.  Default 0x00.

| Bit | Name    | Effect when set |
|-----|---------|----------------|
| 0   | BLEND   | Alpha-blend with destination (for primitives that support it) |
| 1   | BILINEAR| Use bilinear filtering instead of nearest-neighbour |
| 2   | FONT    | Font raster mode — alpha coverage from font BRAM region |
| 7:3 | —       | Reserved (write 0) |

CMD + FLAGS is the primary API.

---

## 2.  Font format

**32 rows × up to 128 pixels** per glyph, stored in the same RAMB36E1
as the pattern memory (dual-port read in font mode).

Each byte = one pixel's **alpha coverage** (0 = transparent,
255 = fully opaque).  Four coverage bytes are packed per 32-bit word:

```
word[31:24] = pixel at x+3  (MSB)
word[23:16] = pixel at x+2
word[15:8]  = pixel at x+1
word[7:0]   = pixel at x    (LSB)
```

Row-major, little-endian byte order within the row.  Row stride
in words = ceil(width / 4).  Loaded via `FONT_DATA` byte-stream
register (similar to `PAT_DATA`).

**Font source — recommended toolchain:**

1. Convert TTF/OTF to a coverage bitmap on a development PC
   (FreeType `FT_RENDER_MODE_NORMAL` or `FT_RENDER_MODE_SDF`).
2. Pack 4 coverage bytes per word, write into a small tool that
   emits the font as a C header or flat binary.
3. At boot, the PS loads all needed glyphs into the font region
   of the blitter BRAM (dual-port halves), or loads on demand.

### 2.1  Size limit and large-glyph fallback

The font BRAM region holds **512 words = 2048 coverage bytes**
(assuming 512 words reserved for the RGBA pattern).  At 4 pixels
per word this gives **32 rows × 128 pixels** maximum.  That covers
body text up to ≈24pt at 150 DPI.

For glyphs larger than the BRAM limit (zoomed UI, DTP, posters):

1. The PS renders the glyph at full size into a **temporary DDR3
   buffer** as RGBA-8888, with the pattern colour already baked
   into R/G/B and coverage in A.  PS-side rendering at this stage
   is straightforward — iterate over the glyph outline with the
   chosen pattern colour, writing into the DDR3 buffer.
2. Composite to the framebuffer via **bilinear scaled blit with
   alpha blend** (CMD=0x86 — see §14.2).

This path is slower (DDR3 reads for source + DDR3 read for
destination per pixel) but handles arbitrarily large glyphs.  The
PS switches between CMD=0x05 and CMD=0x04 + FLAGS.BILINEAR|BLEND
based on glyph size:

```
if (glyph_w <= 32 && glyph_h * ((glyph_w + 3) / 4) <= 512)
    use CMD=0x05                      // BRAM-resident glyph, fast path
else
    render glyph to DDR3 at full RGBA
    FLAGS = BILINEAR | BLEND          // bilinear + alpha blend
    CMD = 0x04                        // DDR3-backed scaled blit
```

---

## 3.  Pattern format (unchanged from existing rect fill)

Up to 32×32 pixels of RGBA-8888, row-major.  Loaded via `PAT_DATA`
byte stream:  `R, G, B, A` per pixel, auto-advancing.  A 1×1
pattern gives a solid fill colour.

For font raster (CMD=0x05): the pattern provides the **texture**
applied to the glyph — each pixel in the pattern is a full RGBA
value.  The glyph alpha-map modulates the pattern's alpha channel.

---

## 4.  v_gtext — draw text

```c
void v_gtext(int16_t handle, int16_t x, int16_t y, int8_t *string);
```

**Blitter command:** CMD=0x05 (font raster)

**PS-side setup (per character):**

1. Look up glyph width, height, and bitmap data from the font table.
2. If the glyph is not already loaded into the font BRAM region:
   write FONT_DATA bytes to load it (max 1024 words = 4096 bytes =
   32×128 coverage pixels; a typical 16×20 glyph is 320 bytes).
3. Write `PAT_LOG_W`, `PAT_LOG_H` with pattern dimensions.
4. Load pattern (solid colour = 1×1, tiled texture = up to 32×32).
5. Write `DST_X_LO/HI = x`, `DST_Y_LO/HI = y` (adjusted for
   alignment — see `vst_alignment`).
6. Write `CMD = 0x05`.

The blitter composites:

```
pat    = pattern[(cx + phase_x) & (pw-1)][(cy + phase_y) & (ph-1)]
cover  = font_coverage[cy][cx]          // 8-bit alpha from font data
alpha  = (cover * pat[7:0]) >> 8        // modulated by pattern alpha

if alpha == 0:     skip pixel
elif alpha == 255: write pat (RGB unchanged, A=255) directly
else:              read destination, blend:
                     out = (pat * alpha + dst * (255-alpha) + 128) >> 8
```

**Proportional fonts:** each character is a separate CMD=0x05 call.
The PS advances `x` by the glyph's width (plus kerning if any).

**Monospace fonts:** the PS can batch a whole line into one call
if all glyphs share the same cell width and are packed into the
pattern+font memory as one composite bitmap.  Not required for
v0.7 but an optimisation for later.

**Large glyphs (>32 rows or >128 px wide):** fall back to the
DDR3-render + CMD=0x86 path described in §2.1.  For each large
character the PS:

1. Renders the glyph at full resolution into a small DDR3 buffer
   (RGBA-8888, pattern colour baked in, coverage in A channel).
2. Sets `FLAGS = BILINEAR | BLEND`, then `CMD = 0x04` (scaled blit
   with bilinear filtering + alpha blend) to composite the DDR3
   buffer onto the framebuffer at `(x, y)`.  Scaling factor can
   be 1:1 for exact size, or any other ratio.
3. Advances `x` by the glyph width and repeats for the next
   character.

Large-glyph rendering is slower (5 AXI reads per destination
pixel vs zero for BRAM-resident) but this path is only hit for
unusual cases like zoomed views or DTP print preview.

---

## 5.  vst_font — select font face

```c
int16_t vst_font(int16_t handle, int16_t font_id);
```

PS-side only.  The PS maintains a font table in DDR3; `vst_font`
selects the active font by index.  No blitter interaction.

---

## 6.  vst_height — set font height

```c
int16_t vst_height(int16_t handle, int16_t height, int16_t *used_height);
```

The PS selects the closest available font size from its loaded
fonts.  If exact match not available:

- **Larger glyphs:** use the NN scaled blit (CMD=0x04) to upscale
  the nearest cache-resident glyph size to the desired height,
  then composite via font raster.

- **Smaller glyphs:** either downscale with bilinear (CMD=0x04 + FLAGS.BILINEAR) or
  use a pre-rendered set.

Realistically, for v0.7 the PS stores 1–2 sizes per face and
uses CMD=0x04 (with FLAGS) for the rest.

---

## 7.  vst_effects — text effects

```c
int16_t vst_effects(int16_t handle, uint16_t effects);
```

Bitmask:  bold(0)  italic(1)  underline(2)  outline(3)  shadow(4)  thin(5)

**Two code paths depending on glyph size:**

Small glyphs (fit in BRAM, §2.1): effects are implemented by the
PS making **multiple blitter calls** per glyph (described below).
The blitter has no native effect logic.

Large glyphs (DDR3-rendered, CMD=0x86 path): effects are applied
**during the PS rendering step**.  The PS draws the glyph outline
at full resolution with the effect baked in — bold = thicker
stroke, italic = shear transform, outline = stroke + fill,
shadow = offset + reduced alpha, etc.  Then a single CMD=0x86
call composites the result.

### 7.1  Bold (bit 0)

**Preferred:** use a bold variant of the font face if available.
Select a different `font_id` that maps to the bold weight.

**Fallback (simulated bold):** composite the glyph twice, offset by
(1, 0) and (0, 0), using the same pattern.  The alpha-blend in
CMD=0x05 handles the overlap.

```
// Pass 1 — left
set DST_X = x
CMD = 0x05   // font raster
// Pass 2 — right
set DST_X = x + 1
CMD = 0x05
```

### 7.2  Italic (bit 1)

**Preferred:** use an italic font face.

**Fallback (simulated italic):** shear the glyph bitmap on the PS
side before loading into font memory.  For each row, shift the
coverage bytes by `(row * shear) >> SHIFT` pixels, where
`shear = 2` and `SHIFT = 4` (≈0.125 pixels per row).  Load the
sheared bitmap into font memory and call CMD=0x05 normally.

A dedicated shear FSM in the blitter would be faster but isn't
needed for v0.7 — small shears are cheap on the Cortex-A9 for a
single glyph at a time.

### 7.3  Underline (bit 2)

A rect fill (CMD=0x01) after the font raster:

```
// Determine underline position and thickness from the font header:
//   ul_y   = baseline + 1
//   ul_h   = max(1, height/12)
font_raster(DST_X, DST_Y, glyph);   // draw text
rect_fill(DST_X, baseline+1, text_width, ul_h, underline_pattern);
```

### 7.4  Outline (bit 3)

Three-pass font raster (simple approach, good for small to
medium sizes):

```
// Pass 1 — outline colour, offset left-up
set pattern = outline_colour (1×1)
set DST_X = x - 1, DST_Y = y - 1
CMD = 0x05

// Pass 2 — outline colour, offset right-down
set DST_X = x + 1, DST_Y = y + 1
CMD = 0x05

// Pass 3 — text colour, centred
set pattern = text_colour (1×1)
set DST_X = x, DST_Y = y
CMD = 0x05
```

For larger text (>24pt), a 1-pixel outline is too thin.  Use
offsets of ±2 or ±3 and 4–8 passes (cardinal + diagonal), or
switch to a two-pass dilatation kernel on the PS side before
loading into font memory.

### 7.5  Shadow (bit 4)

Two-pass font raster:

```
// Pass 1 — shadow colour, offset right-down, reduced alpha
set pattern = shadow_colour with A = 128  (1×1 or texture)
set DST_X = x + 2, DST_Y = y + 2
CMD = 0x05

// Pass 2 — text colour
set pattern = text_colour (1×1)
set DST_X = x, DST_Y = y
CMD = 0x05
```

The shadow offset (2, 2) is conventional;  (1, 1) or (3, 3) can
be used for smaller or larger shadows.

### 7.6  Thin (bit 5)

Use the standard font but the PS halves the pattern alpha before
the font raster call, or applies a 50% outline colour.  Equivalent
to rendering the text at full weight then blending down.

```
set pattern = text_colour with A / 2
CMD = 0x05
```

---

## 8.  vst_color — set text colour

```c
int16_t vst_color(int16_t handle, int16_t color_index);
```

The PS maintains a colour lookup table (CLUT) mapping VDI colour
indices to RGBA-8888 values.  `vst_color` selects an entry; when
`v_gtext` is called, the PS writes the RGBA value as a 1×1 pattern
(or selects a preloaded pattern index).

For a tiled-texture effect, the PS can load a non-1×1 pattern and
ignore `vst_color` for that specific call.

---

## 9.  vst_alignment — set text alignment

```c
int16_t vst_alignment(int16_t handle, int16_t h_align, int16_t v_align);
```

`h_align`: 0=left, 1=centre, 2=right
`v_align`: 0=baseline, 1=top, 2=centre, 3=bottom

The PS adjusts `DST_X, DST_Y` before the CMD=0x05 call:

- **Horizontal:** compute total string width via the font header
  width table (or `vqt_extent`).  For centre: `DST_X = x - w/2`.
  For right: `DST_X = x - w`.

- **Vertical:** adjust `DST_Y` by the font ascent/descent.
  For top: `DST_Y = y` (no change from baseline behaviour).
  For centre: `DST_Y = y - (ascent + descent)/2`.
  For bottom: `DST_Y = y - ascent - descent`.

The blitter always places the glyph top-left at `(DST_X, DST_Y)`;
all alignment is software-side.

---

## 10.  v_pline — draw polyline

```c
int16_t v_pline(int16_t handle, int16_t count, int16_t *points);
```

**Blitter command:** CMD=0x02 (line draw) per segment.

For each consecutive pair of points `(x1,y1) → (x2,y2)`:

```
DST_X = x1, DST_Y = y1
DST_W = x2 - x1    // signed DX
DST_H = y2 - y1    // signed DY
CMD = 0x02
```

The blitter handles all octants (signed Bresenham).  The first
pixel plots at `(x1, y1)`, the last at `(x2, y2)`.

**Pattern:** the line draws with the current pattern (same as rect
fill).  A solid line uses a 1×1 pattern; a dashed line uses a
pattern where alternating pixels are transparent.

---

## 11.  vr_recfl — fill rectangle

```c
int16_t vr_recfl(int16_t handle, int16_t *xy_array);
```

**Blitter command:** CMD=0x01 (rect fill) or CMD=0x05 (alpha-blend
rect fill).

```
DST_X = x1, DST_Y = y1
DST_W = x2 - x1 + 1
DST_H = y2 - y1 + 1
// For opaque pattern:          CMD = 0x01
// For pattern with RGBA-alpha: CMD = 0x05
```

`xy_array` contains `(x1, y1, x2, y2)` — note VDI uses inclusive
coordinates.  Width = `x2 - x1 + 1`, height = `y2 - y1 + 1`.

---

## 12.  v_bar — draw filled bar (with colour)

```c
int16_t v_bar(int16_t handle, int16_t *xy_array);
```

Same as `vr_recfl` but always uses the current fill colour as a
1×1 pattern.  The PS loads a 1×1 pattern from the fill colour and
calls CMD=0x01.

For bars with fill pattern (indexed fill), load the pattern,
write `PAT_PHASE_X/Y` for tiling origin, and call CMD=0x01.

---

## 13.  vro_cpyfm — block copy with raster op

```c
int16_t vro_cpyfm(int16_t handle, int16_t w, int16_t h,
                   int16_t *src_xy, int16_t *dst_xy, int16_t op);
```

**Blitter command:** CMD=0x03 (block blit).

Constraints:
- Source X and destination X must have the same parity
  (`src_x[0] == dst_x[0]`).
- Width must be even (each AXI beat transfers 2 pixels).

Raster ops (GEM `op` parameter) are **not yet implemented** in
hardware.  For v0.7, only `op=3` (direct copy, the most common
GEM operation for transparent sprite compositing) is supported.
Other ops must be emulated in software:

| op | GEM name | PS fallback |
|----|----------|-------------|
| 3  | ALL → DST | blitter CMD=0x03 (native) |
| 0  | ZERO → DST | fill with black rect |
| 1  | SRC AND DST | read-modify-write in software |
| 2  | SRC AND NOT DST | software |
| 4  | NOT SRC → DST | invert src colour before blit |
| 5  | DST → DST | no-op |
| 6  | SRC OR DST | software |
| 7  | SRC → DST | CMD=0x03 (same as op=3 for opaque) |
| 8–15 | misc | software |

Future blitter revisions may include a raster-op register.

---

## 14.  vr_trnfm — stretch bitblock (scaled blit)

```c
int16_t vr_trnfm(int16_t handle, int16_t *src_xy, int16_t *dst_xy,
                  int16_t *src_dim, int16_t *dst_dim);
```

**Blitter command:** CMD=0x04 (scaled blit) with FLAGS modifier.

```
SRC_X = src_x, SRC_Y = src_y
SRC_W = src_w, SRC_H = src_h
DST_X = dst_x, DST_Y = dst_y
DST_W = dst_w, DST_H = dst_h

FLAGS = 0                 // see CMD=0x04 + FLAGS combinations below
CMD = 0x04
```

| FLAGS bits | Behaviour |
|---|---|
| `0` | Nearest-neighbour, opaque (fast, no dest read) |
| `BILINEAR` | Bilinear, opaque (4 AXI reads/px, smoother) |
| `BLEND` | NN + alpha-blend (reads dest when 0<α<255) |
| `BILINEAR \| BLEND` | Bilinear + alpha-blend (5 AXI reads/px when 0<α<255) |

The bilinear modes read 4 single-pixel 4-byte AXI reads per
destination pixel and compute 8-bit fractional weights via a
sequential divider; there is no alignment constraint on the source
X coordinate (unlike block blit).

When `BLEND` is set, the blitter reads the destination pixel
(fifth AXI read) when the sampled source pixel has 0 < α < 255,
and blends using the same arithmetic as the alpha-blend rect fill
(§11):

```
out = (src * α + dst * (255-α) + 128) >> 8   per channel
```

Shortcuts: α=255 → write directly (no dest read), α=0 → skip
(wstrb=0).  The `BLEND` + `BILINEAR` combination is used for
compositing large glyphs from a DDR3 glyph cache (see §2.1).

The old dedicated commands `CMD=0x06` (bilinear opaque) and
`CMD=0x86` (bilinear blend) are **not used**.  They are equivalent
to `CMD=0x04 + FLAGS.BILINEAR` and `CMD=0x04 + FLAGS.BILINEAR|BLEND`
respectively.  New code should use the FLAGS-based API.

For best quality with large downscales (dst << src), bilinear is
recommended.  For upscales, nearest-neighbour with the source-pixel
cache is faster and visually acceptable for UI elements.

---

## 15.  v_ellipse / v_ellarc / v_pieslice — ellipses

Not yet supported in hardware.  The PS can approximate small
ellipses by drawing multiple short line segments (CM=0x02) or by
pre-rendering into a DDR3 buffer and using scaled blit.  A
dedicated ellipse primitive is a future candidate.

---

## 16.  v_fillarea — filled polygon

Not yet supported.  Small convex polygons can be CPU-rendered into
a temporary buffer and then block-blitted.  A scanline-fill
primitive is a future candidate.

---

## 17.  vst_rotation — rotated text

```c
int16_t vst_rotation(int16_t handle, int16_t angle);  // tenths of degrees
```

PS-side rotation only for v0.7:

1. Render the glyph into a temporary 32-bit RGBA buffer in DDR3
   (using the font coverage map + pattern colour, all in software
   on the Cortex-A9).
2. Rotate the buffer to the target angle (software bilinear
   interpolation).
3. Composite the rotated buffer via bilinear scaled blit
   (CMD=0x06) to the desired screen position.

For small glyphs (≤32×32) this is fast on a 667 MHz Cortex-A9.
If rotation becomes a bottleneck, a dedicated affine-transform
blit can be added in a later phase.

---

## 18.  Reset pointer and data load registers

| Register | $D4 | Purpose |
|----------|:---:|---------|
| `PAT_LOG_W` | BA | writing ANY value sets log2(pattern_width) [4:0] (0→1, 1→2, ... 5→32 px) AND resets `PAT_DATA` load pointer to 0 |
| `PAT_DATA`  | BB | write RGBA bytes; auto-advances; wraps at 4096 |
| `PAT_LOG_H` | BE | pattern height log2 (does NOT reset load pointer) |
| `FONT_DATA` | CE | write coverage bytes; auto-advances (future) |
| `FONT_CTRL` | CF | writing any value resets `FONT_DATA` load pointer (future) |

The sequence for loading a pattern:

```
// Reset pointer
*(uint8_t *)0xD4BA = log_w;

// Write 4 bytes per pixel, row-major
for (y = 0; y < h; y++)
    for (x = 0; x < w; x++) {
        *(uint8_t *)0xD4BB = pixel[y][x].R;
        *(uint8_t *)0xD4BB = pixel[y][x].G;
        *(uint8_t *)0xD4BB = pixel[y][x].B;
        *(uint8_t *)0xD4BB = pixel[y][x].A;
    }

// Set height
*(uint8_t *)0xD4BE = log_h;
```

The pattern loading pointer wraps at 4096 bytes = 1024 entries, so
it is safe to overshoot the pattern size.

---

## 19.  Addressing and coordinate conventions

- **Framebuffer base:** `FB_BASE = 0x3000_0000` (see memory-map.md).
- **Destination coordinates:** `(DST_X, DST_Y)` are absolute
  framebuffer pixel coordinates in the range 0..2047 (1920×1080
  active area).
- **Source coordinates (blit):** `(SRC_X, SRC_Y)` are absolute
  framebuffer coordinates in the same address space.
- **Stride:** `FB_STRIDE_B = 8192 = 1<<13`.  Row stride is
  hard-coded into the blitter address calculation —
  `pixel_addr = FB_BASE + (y << 13) + (x << 2)`.
- **Pixel format:** RGBA-8888 big-endian in 32-bit words:
  `{R[31:24], G[23:16], B[15:8], A[7:0]}`.  This matches the
  fb_scanout scan-out pipeline.

---

## 20.  Busy polling — STATUS register ($D4BD)

A dedicated read-only **STATUS** register at `$D4BD` returns the
blitter state.  Bit 0 is `busy` (1 = blitter active, 0 = idle);
bits 7:1 are reserved (read 0).

```c
// Poll until idle
while (*(uint8_t *)0xD4BD & 0x01)
    ;
```

Do not write any blitter register while `busy` is asserted; writes
are ignored or may corrupt the in-flight command.  The STATUS
register is safe to read at any time and has no side effects.

### 20.1  Why a dedicated register?

Earlier revisions suggested reading any $D4xx register and checking
bit 0, but that constrains all future register additions — every
readable register would need to return a valid busy bit.  The
dedicated STATUS register at $D4BD decouples polling from all other
register reads, leaving $D4B0..$D4BC / $D4BE..$D4CF free for
write-only parameter and data registers (or future readable
registers with independent semantics).
