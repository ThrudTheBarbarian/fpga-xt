# Sprite engine — hardware-accelerated sprite compositor for 1080p scan-out

**Status**: design draft, 2026-05-14. No implementation started.

## Motivation

The legacy Atari ANTIC/GTIA pipeline produces an 8-bit indexed frame via
the `compositor` → `line_buffer` → `scan_out` → `palette_lut` chain.
This is faithful to the original hardware but offers no way to overlay
modern UI elements, real-time game sprites, or animated backgrounds on
top of the Atari framebuffer without CPU-driven frame-buffer blits.

A dedicated sprite engine eliminates CPU overhead for per-frame
compositing, decouples sprite animation from the Atari display list
timing, and provides collision detection as a free side-effect of the
scan-out pipeline.

The design targets the **Zynq-7020** PL fabric with pixel data stored in
**PS DDR3** and fetched over a dedicated AXI HP port during scan-out.

## High-level architecture

```
DDR3 (shared 512 MB / 1 GB)
┌────────────────────────────────────────────────────────────────────┐
│  Framebuffer (RGB565)     Sprite Arena (64 MB, 8192×4096×16-bit)  │
│  1920×1080×2 = ~4 MB      ┌──────────────────────────────────────┐│
│                           │  Sprite pixel data, row-major        ││
│                           │  Power-of-2 rectangles               ││
│                           │  Max: 16 sprites × 1024×1024         ││
│                           └──────────────────────────────────────┘│
└──────────────────────────┬───────────────────────────────────────┬┘
                           │                                       │
                    AXI HP1                                 AXI HP2
                           │                                       │
              ┌────────────▼────────────┐     ┌───────────────────▼──┐
              │ Framebuffer scan-out    │     │ Sprite line fetcher  │
              │ (AXI burst → line buf)  │     │ (per-scanline fetch) │
              └────────────┬────────────┘     └───────────┬───────────┘
                           │                               │
                    ┌──────▼───────┐          ┌────────────▼───────────┐
                    │ 16-bit       │          │ Sprite line cache      │
                    │ RGB565 pixel │          │ (8 BRAM36K, dual-port) │
                    └──────┬───────┘          └────────────┬───────────┘
                           │                               │
                           └───────────────┬───────────────┘
                                           │
                                   ┌───────▼────────┐
                                   │ Sprite          │
                                   │ compositor      │
                                   │ (pixel pipeline)│
                                   └───────┬────────┘
                                           │
                                   ┌───────▼────────┐
                                   │ RGB565 + sync  │
                                   │ → SiI9022A     │
                                   └────────────────┘
```

### Clock domains

| Domain | Frequency | Purpose |
|--------|-----------|---------|
| `clk_pix` | 148.5 MHz | Pixel scan-out, sprite compositor |
| `clk_fetch` | ≥ 162 MHz (same as `clk_bus` or faster PLL output) | Sprite line fetcher, AXI burst control |
| `clk_bus` | 162 MHz | Register writes from SALLY, descriptor updates |

The sprite line cache BRAMs are dual-port:
- **Port A** (clk_fetch): line fetcher writes next scanline's data
- **Port B** (clk_pix): compositor reads current scanline's data

No CDC FIFOs needed — dual-port BRAM handles the clock crossing.

## Sprite arena

All sprite pixel data lives in a fixed 64 MB region of PS DDR3:

```
Arena: 8192 columns × 4096 rows × 16-bit per pixel = 64 MB

Byte address for pixel (col, row):
  addr = ARENA_BASE + (row << 14) + (col << 1)    // row×8192×2 + col×2

ARENA_BASE = 0x2000_0000 (or whatever base is free in the PS address map)
```

### Why 8192 × 4096?

- **8192** = 2^13. The row stride (8192 × 2 = 16384 bytes = 2^14) is a
  power of two, so the address calculation is a shift-and-add — no
  hardware multiplier needed.
- **4096** = 2^12 rows. Gives enough vertical room for 4 full frames of
  1080p sprite data or a large tileset.
- **64 MB total** is a negligible fraction of a 512 MB DDR3 allocation.
  Even with all 16 sprites at max 1024×1024, you use 32 MB.

### Sprite layout within the arena

Sprites are **power-of-two rectangles** placed at arbitrary (arena_x,
arena_y) positions. The pixel at local position (lx, ly) within a sprite
of size 2^N × 2^N lives at:

```
arena_pixel(arena_x + lx, arena_y + ly)
```

The arena has no concept of "allocated vs. free" — software manages
placement (simple linear allocator or pre-baked layout at build time).

## Sprite descriptor

Each sprite is defined by a 64-bit descriptor, writable by SALLY via
the indexed register interface:

```
63      60    55      48    47      40    35      32    31      24    23      16    15       8    7        0
┌────────┬────────┬────────┬────────┬────────┬────────┬──────────┬─────────┐
│  prio  │  log2  │  arena │  arena │ screen │ screen │ reserved │   en    │
│  (5b)  │  size  │  _y    │  _x    │  _y    │  _x    │          │  (1b)   │
│        │  (4b)  │  (12b) │  (13b) │ (13b)  │ (13b)  │          │         │
└────────┴────────┴────────┴────────┴────────┴────────┴──────────┴─────────┘
```

| Field | Bits | Range | Description |
|-------|------|-------|-------------|
| `en` | 1 | 0/1 | Sprite enable |
| `log2_size` | 4 | 7..12 (128..4096) | Sprite is 2^N × 2^N pixels |
| `arena_x` | 13 | 0..8191 | Column of sprite's top-left in arena |
| `arena_y` | 12 | 0..4095 | Row of sprite's top-left in arena |
| `screen_x` | 13 (signed) | -4096..4095 | Screen X position of sprite's top-left |
| `screen_y` | 13 (signed) | -4096..4095 | Screen Y position of sprite's top-left |
| `priority` | 5 | 0..31 | Higher = draws on top |

**Size constraint**: log2_size encodes the sprite's width AND height
(always square, power of two). A 128×128 sprite uses `log2_size=7`, a
1024×1024 sprite uses `log2_size=10`.

**Off-screen positioning**: Negative screen_x/screen_y allow sprites to
scroll partially or fully off the visible area. The fetcher handles
clipping automatically (only reads pixels that intersect the visible
1920×1080 rectangle).

**Priority ordering**: 0 = lowest, 31 = highest. Software assigns
priority; the hardware does not re-order descriptors. The compositor's
priority encoder selects the highest value among sprites that cover the
current pixel and have alpha=1.

## Pixel format

Sprites use **RGBA 5:5:5:1** (16-bit):

```
bit 15       bit 10     bit 5      bit 0
┌────────────┬──────────┬──────────┬──┐
│  Red[4:0]  │ Green    │ Blue     │ A│
│            │ [4:0]    │ [4:0]    │  │
└────────────┴──────────┴──────────┴──┘
```

- A = 1: pixel is opaque, drawn on screen
- A = 0: pixel is transparent, compositor falls through to next sprite
  or framebuffer

There is no partial alpha. The 5:5:5 RGB maps directly into the RGB565
output format (MSB-aligned, so R and B use bits 4:0→4:0, G uses 4:0→5:1
with bit 0 replicated into bit 0, or simply left-shifted).

## Module: sprite_engine

### Ports

```systemverilog
module sprite_engine #(
    parameter int ARENA_BASE = 32'h2000_0000,
    parameter int N_SPRITES  = 16
) (
    // ---- Clocks & reset ------------------------------------------------
    input  wire        clk_fetch,      // AXI bus clock (≥162 MHz)
    input  wire        clk_pix,        // Pixel clock (148.5 MHz @ 1080p)
    input  wire        rst,

    // ---- Vbeam sync (from hdmi_out, CDC'd to clk_fetch) ----------------
    input  wire        line_start,     // 1-cycle pulse, start of new scanline
    input  wire [11:0] vcount,         // current vertical line number (0..1124)

    // ---- Register interface (from SALLY via hwreg bus, clk_bus) -------
    input  wire        reg_we,
    input  wire [7:0]  reg_addr,
    input  wire [7:0]  reg_wdata,      // 8-bit Atari-style bus
    output wire [7:0]  reg_rdata,

    // ---- Framebuffer pixel input (rgb565, from framebuffer scan-out) ---
    input  wire [15:0] fb_pixel,
    input  wire        fb_de,          // data enable (in active video)

    // ---- Composited pixel output (rgb565) ------------------------------
    output logic [15:0] out_pixel,
    output logic        out_de,

    // ---- AXI4 burst read master (dedicated HP port) --------------------
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire        m_axi_rvalid,
    input  wire        m_axi_rlast,
    output wire        m_axi_rready
);
```

### Submodules

#### 1. Descriptor register file

16 × 64-bit descriptors, implemented as flip-flops (not BRAM — they're
small and writes come from the 8-bit SALLY bus). Accessed via an indexed
register pair:

```
$D4A0  SPRITE_SEL    (W)  — Select sprite index 0-15 for subsequent access
$D4A1  SPRITE_B0     (R/W) — Byte 0:  priority[4:0], reserved[7:5]
$D4A2  SPRITE_B1     (R/W) — Byte 1:  log2_size[3:0], reserved[7:4]
$D4A3  SPRITE_B2     (R/W) — Byte 2:  arena_y[7:0]
$D4A4  SPRITE_B3     (R/W) — Byte 3:  arena_y[11:8], arena_x[12:8]
$D4A5  SPRITE_B4     (R/W) — Byte 4:  arena_x[7:0]
$D4A6  SPRITE_B5     (R/W) — Byte 5:  screen_y[7:0] (signed, 2's complement)
$D4A7  SPRITE_B6     (R/W) — Byte 6:  screen_y[12:8], screen_x[12:8]
$D4A8  SPRITE_B7     (R/W) — Byte 7:  screen_x[7:0]
```

Writing byte 7 ($D4A8) commits the descriptor — all 8 bytes are latched
into the selected descriptor slot. Reading any of $D4A1-$D4A8 returns
the corresponding byte of the currently selected descriptor.

#### 2. Sprite line fetcher (clk_fetch domain)

The fetcher is a state machine that runs continuously, one scanline
ahead of the compositor.

**Operation:**

1. On `line_start` (rising edge, CDC'd from clk_pix to clk_fetch):
   - Record `vcount` as the current scanline being composed
   - Start fetching data for scanline `vcount + 1` (the next scanline)

2. For each sprite i = 0..15 (iterated in priority order):
   ```
   sprite_height = 1 << desc[i].log2_size
   local_y = (vcount + 1) - desc[i].screen_y

   if desc[i].en && local_y >= 0 && local_y < sprite_height:
       // This sprite intersects the next scanline
       arena_row = desc[i].arena_y + local_y          // 12-bit add
       base_addr = ARENA_BASE + (arena_row << 14)
       col_start = desc[i].arena_x
       width     = 1 << desc[i].log2_size

       // Clip to visible screen width (1920 pixels)
       screen_x_start = desc[i].screen_x
       if screen_x_start < 0:
           col_start += -screen_x_start
           width     -= -screen_x_start
       if screen_x_start + width > 1920:
           width = 1920 - screen_x_start

       if width > 0:
           byte_addr = base_addr + (col_start << 1)
           byte_len  = width << 1
           Issue AXI burst(s) for byte_addr..byte_addr+byte_len-1
           Write returned data into sprite line cache at
             cache_addr = {sprite_id[3:0], pixel_x[10:0]}
   ```

3. The fetcher has a **byte budget** counter (initialised per scanline).
   After each sprite fetch, the budget is decremented by byte_len. When
   the budget is exhausted, remaining sprites silently skip rendering
   for this scanline. Next scanline, the budget resets and all sprites
   are re-evaluated.

   Budget calculation (set as a parameter or writable register):
   ```
   FETCH_BUDGET = 13440  // bytes per scanline ≈ 70% of AXI HP port BW
   ```

4. The fetcher uses **AXI burst length 8** (8 × 8 bytes = 64 bytes per
   burst = 32 sprite pixels). For a 128-pixel-wide sprite, this is 4
   bursts. For a 1024-pixel-wide sprite, this is 32 bursts.

5. **AXI signal mapping:**
   - `arsize = 3'b011` (8 bytes per beat — 64-bit bus)
   - `arburst = 2'b01` (INCR burst)
   - `arlen = 8'd7` (8 beats per burst — 64 bytes)
   - `araddr` increments by 8 each beat within a burst; the fetcher
     issues a new AR for each 64-byte chunk of sprite data

#### 3. Sprite line cache (BRAM, dual-port)

**Layout:** 8 BRAM36K blocks, each configured as 2K×18 (true dual-port).
Two sprites pack into each BRAM:

| BRAM block | Sprites | Address within BRAM |
|------------|---------|---------------------|
| BRAM0 | 0, 1 | `{sprite_id[0], pixel_x[10:0]}` → 0..2047 |
| BRAM1 | 2, 3 | |
| BRAM2 | 4, 5 | |
| ... | ... | |
| BRAM7 | 14, 15 | |

Each entry holds one 16-bit RGBA pixel. The address is a concatenation
of the sprite's low bit and the local X coordinate (0..1023 for a
1024-wide sprite, using 11 bits). 2048 entries per BRAM covers two
sprites at 1024 pixels each.

The dual-port nature means:
- **Port A (clk_fetch)**: fetcher writes scanline data for the next
  frame while the current frame is being read
- **Port B (clk_pix)**: compositor reads the current scanline's sprite
  data, one address per pixel clock

#### 4. Sprite compositor (clk_pix domain, 4-stage pipeline)

Processes one pixel per clock at 148.5 MHz. The pipeline depth matches
the BRAM read latency.

**Stage 1 — Bounds check (combinational):**

For each sprite i (0..15), in parallel:

```systemverilog
wire [15:0] sprite_hits;
for (i = 0; i < 16; i++) begin
    wire signed [12:0] local_x = $signed(h_count) - $signed(desc[i].screen_x);
    wire signed [12:0] local_y = $signed(vcount)  - $signed(desc[i].screen_y);
    wire [12:0]        size    = 13'd1 << desc[i].log2_size;
    sprite_hits[i] = desc[i].en &&
                      local_x >= 0 && local_x < size &&
                      local_y >= 0 && local_y < size;
end
```

16 parallel comparisons = 64 comparators. ~150 LUTs.

**Stage 2 — BRAM read (registered, 1 cycle):**

Address all 8 BRAMs with `{sprite_id[0], local_x[10:0]}` to retrieve
pixel data for all 16 sprites at the current pixel position.

**Stage 3 — Alpha test + priority resolve (combinational):**

```systemverilog
// Alpha bits — bit 15 of each sprite's cache data
wire [15:0] alpha = sprite_hits & pixel_alpha_from_cache;

// Priority encoder: find highest-priority sprite with alpha=1
wire [15:0] priority_values;  // from descriptors, gated by alpha
wire [3:0]  winner_id;

priority_encoder #(.N(16)) u_prio (
    .values  (priority_values),
    .onehot  (winner_onehot),
    .id      (winner_id),
    .any     (any_hit)
);
```

**Stage 4 — Collision update (combinational):**

For every pair of sprites (i, j) with i ≠ j, if both have alpha=1 at
this pixel, the collision bit is set:

```systemverilog
always_ff @(posedge clk_pix) begin
    for (i = 0; i < 16; i++) begin
        for (j = 0; j < 16; j++) begin
            if (i != j && alpha[i] && alpha[j])
                collision[i][j] <= 1'b1;   // sticky, cleared by write-1
        end
    end
end
```

120 pairwise comparisons per pixel. 240 collision flip-flops (16 × 16
matrix with self-pairs unused).

**Stage 5 — Output mux (combinational):**

```systemverilog
always_comb begin
    if (fb_de && any_hit) begin
        // Sprite RGBA 5:5:5:1 → RGB565
        out_pixel = {winner_data[14:10],   // R[4:0] → RGB565 R[4:0]
                     winner_data[9:5],     // G[4:0] → RGB565 G[5:1]
                     winner_data[4:0]};    // B[4:0] → RGB565 B[4:0]
    end else if (fb_de) begin
        out_pixel = fb_pixel;
    end else begin
        out_pixel = 16'h0000;   // blank during blanking
    end
    out_de = fb_de;
end
```

*Green mapping: sprite G[4:0] maps to RGB565 G[5:1], so G[0] is always
0. Can be improved to G[4:0]→G[5:1] with G[0] = G[1] (duplicate LSB)
for smoother colour steps.*

## FPGA resource estimate

| Resource | Count | Zynq-7020 available | Utilization |
|----------|-------|---------------------|-------------|
| **BRAM36K** (line cache: 2 sprites/BRAM) | 8 | 140 | **6 %** |
| **Flip-flops** (descriptors + pipeline + collision) | ~3,000 | 106,400 | **3 %** |
| **LUTs** (comparators + encoders + FSM + address gen) | ~1,800 | 53,200 | **3 %** |
| **DSP48** | 0 | 220 | **0 %** |

Total sprite engine: under 10 % of Zynq-7020 fabric.

## Bandwidth analysis

### Assumptions

- AXI HP port: 64-bit @ 162 MHz → 1.296 GB/s theoretical peak
- Practical sustainable throughput: ~70 % = ~0.9 GB/s (limited by DDR
  controller arbitration and row activation)
- Per scanline (2200 pixel clocks at 148.5 MHz):
  - Available bus cycles: 2200 × (162/148.5) ≈ **2,400**
  - Available bytes at 70 %: 2,400 × 8 × 0.7 = **13,440 bytes**
  - Available sprite pixels: 13,440 / 2 = **6,720 pixels**

### Per-scanline budget

| Sprite mix | Pixels/line | Bytes/line | Bursts | Cycles | Budget |
|---|---|---|---|---|---|
| 16 sprites × 420 px wide | 6,720 | 13,440 | 210 | 2,100 | **87 %** |
| 8 × 128 + 4 × 256 + 2 × 512 + 2 × 64 | 3,200 | 6,400 | 100 | 1,000 | **42 %** |
| 4 × 1024 (full-width backgrounds) | 4,096 | 8,192 | 128 | 1,280 | **53 %** |
| 16 × 128 (typical arcade) | 2,048 | 4,096 | 64 | 640 | **27 %** |
| 12 × 64 (very light) | 768 | 1,536 | 24 | 240 | **10 %** |

### Budget oversubscription

If total visible sprite pixels on a scanline exceeds ~6,700, the fetcher
stops fetching lower-priority sprites once its byte budget is exhausted.
Those sprites silently disappear from that scanline (they only miss one
scanline, which is invisible at 60 fps). The budget resets each scanline
so sprites return naturally.

Implications:
- **No bus storm.** The fetcher never exceeds its AXI budget.
- **No frame corruption.** Skipped sprites are invisible for at most
  1/60,000 of a second (one scanline).
- **Deterministic.** A game developer can compute the exact per-scanline
  fetch cost from the descriptor table and verify their layout fits.

### Framebuffer (separate AXI HP port)

The framebuffer scan-out uses its own AXI HP port (HP1), not the sprite
fetcher's port (HP2). They do not compete.

| Metric | Value |
|--------|-------|
| Per scanline | 1920 × 2 = 3,840 bytes |
| Bursts | 60 (64 bytes each) |
| Cycles | 600 |
| Budget | **25 %** of its own HP port |

## Integration with existing pipeline

The sprite engine inserts between the palette_lut / framebuffer output
and the hdmi_out / parallel RGB output:

```
Existing:                             New:
                                       ┌──────────────────┐
  palette_lut / framebuffer ──────────┤ sprite_engine    ├──→ hdmi_out
      (RGB565 pixel)                  │ (composits on    │      │
      (de) ──────────────────────────►│  top of fb)      │──────┘
                                       └──────────────────┘
```

The SALLY CPU writes sprite descriptors via the existing hwreg bus at
$D4A0-$D4B2 (chiplet-extension register space, previously marked as
reserved in the register map).

### Changes to existing modules

| Module | Change |
|--------|--------|
| `fpga_xt_top.sv` | Instantiate `sprite_engine`, route AXI HP2 port, add register decode for $D4A0-$D4BF |
| `antic_top.sv` | Expose framebuffer pixel output (RGB565 + de) as a top-level port for the sprite engine |
| `hdmi_out.sv` | No change — already exposes h_count, vcount, line_start, de |
| `register-map.md` | Add $D4A0-$D4BF sprite registers |
| `banked_axi_reader.sv` | No change (sprite engine has its own AXI master) |

## Register interface (SALLY view)

All sprite registers live in the chiplet-extension space ($D4A0-$D4BF).

### Sprite descriptor access

```
$D4A0  SPRITE_SEL    (W)  — Select sprite index 0..15 for subsequent access
$D4A1  SPRITE_B0     (R/W) — Byte 0:  priority[4:0], reserved[7:5]
$D4A2  SPRITE_B1     (R/W) — Byte 1:  log2_size[3:0], reserved[7:4]
$D4A3  SPRITE_B2     (R/W) — Byte 2:  arena_y[7:0]
$D4A4  SPRITE_B3     (R/W) — Byte 3:  arena_y[11:8], arena_x[12:8]
$D4A5  SPRITE_B4     (R/W) — Byte 4:  arena_x[7:0]
$D4A6  SPRITE_B5     (R/W) — Byte 5:  screen_y[7:0] (signed, 2's complement)
$D4A7  SPRITE_B6     (R/W) — Byte 6:  screen_y[12:8], screen_x[12:8]
$D4A8  SPRITE_B7     (R/W) — Byte 7:  screen_x[7:0]
```

Writing byte 7 ($D4A8) commits the descriptor — all 8 bytes are latched
into the selected descriptor slot. Reading any of $D4A1-$D4A8 returns
the corresponding byte of the currently selected descriptor.

### Collision read-back

```
$D4B0  SPRITE_COL_SEL  (W)  — Select sprite index 0..15
$D4B1  SPRITE_COL_LO   (R/W) — Collision bits 7:0, write-1-to-clear
$D4B2  SPRITE_COL_HI   (R/W) — Collision bits 15:8, write-1-to-clear
```

Bit N in the 16-bit read-back value = 1 if selected sprite collided
with sprite N during the current frame (at any pixel). Writing a 1 to a
bit position clears it.

### Control

```
$D4BF  SPRITE_CTRL    (W)  — bit 0 = GLOBAL_ENABLE
                              0: sprites disabled, fb_pixel passes through
                              1: sprite compositing active
```

## Open questions / future work

1. **Green channel mapping.** Sprite G[4:0] → RGB565 G[5:1] loses the
   LSB. Better to map G[4:0] → G[5:1] with G[0] = G[1] (duplicate
   adjacent bit) for 32 half-steps instead of 16 full steps.

2. **Horizontal/vertical flip.** Common sprite feature. Add a flip bit
   in the descriptor that reverses the arena_x or arena_y increment
   direction. Simple to implement (invert the local coordinate).

3. **Palettised sprites.** 8-bit index into a 256-entry palette instead
   of direct 16-bit RGB. Cuts arena bandwidth in half (1 BPP vs 2 BPP)
   at the cost of an extra palette LUT read in the compositor pipeline.

4. **Sprite rotation.** Would need a line buffer and interpolation. Not
   worth the fabric cost for the first cut — software can pre-rotate
   into the arena.

5. **Blitter integration.** The DRAW/chiplet-extension blitter should
   target the sprite arena so the CPU can render sprite surfaces
   without DMA. The Zynq PS (Cortex-A9) can also write to the arena
   over its own AXI port for LVGL/UI rendering.
