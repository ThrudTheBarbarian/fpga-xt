# Banked screen RAM (dual CPU/ANTIC bank) — design proposal

Status: proposal. Sibling to `video-architecture.md` (the plane compositor) and
`texture-mapping.md` (the blitter TMU).

## Goal

Atari-level page flipping: let the CPU build a complete screen — display list
*and* screen data (and optionally the font) — in an off-screen bank while ANTIC
displays another, then reveal it with a single register write. Backed by a DDR
"stack" of 8 KB screen chunks, paged into BRAM, in the same spirit as the
existing CPU code/data banks (`$D5C0` / `$D5C1`, see `bank_xlat.sv`).

The wrinkle versus the existing banks: **two** bank registers over one aperture —
one the CPU draws through, one ANTIC fetches through — so the two can point at
the *same* chunk (normal single screen) or *different* chunks (double/N-buffer).

### Relationship to the RGBA triple buffer (orthogonal — they stack)

Two independent layers, do not conflate them:

| Layer | What it decouples | Mechanism |
|---|---|---|
| **Screen-RAM banking** (this doc) | *what ANTIC renders* (Atari page flip) | `$D5C3` selects ANTIC's source chunk |
| **RGBA triple buffer** (`xl_buffer_ctrl`) | the *rendered pixels* from the HDMI scan-out | mailbox triple buffer, vblank adopt |

Composed: CPU flips `$D5C3` → ANTIC re-renders the new chunk → writeback → triple
buffer → tear-free scan-out. Because the triple buffer already guarantees the
display never tears, **the screen-bank flip does not need to be vblank-synced for
tear-avoidance** — it only has to be atomic, which a single register write is.

## Registers (CCTL I/O gap, next to `$D5C0`/`$D5C1`)

| Addr | Name | Width | Semantics |
|---|---|---|---|
| `$D5C2` | `SCRNBANK_CPU`   | 8 | Chunk the CPU draws/reads through the aperture. **Takes effect immediately** on write. |
| `$D5C3` | `SCRNBANK_ANTIC` | 8 | Chunk ANTIC fetches. Written any time, but **latched to the effective value only at VBI** (`antic_bank_eff`). |

8-bit index → up to 256 × 8 KB = 2 MB of screen chunks in DDR. Bank policy
(when/whether to flip, allocator) lives in PS/6502 software; the PL provides only
the two registers + the paging plumbing (the usual split — cf. the build-config
memory note).

**Why VBI-latch ANTIC but not the CPU:** ANTIC must read a *stable* chunk for a
whole frame, so its effective bank can only change between frames. The CPU's view
is its own; it changes the instant software writes `$D5C2`.

## The 8 KB aperture

Fixed location, defined in the memory-map layout (we already carve out screen
RAM; the aperture *is* that region). If init needs to stamp a base register,
fine, but it does not move at runtime — the flexibility comes from the banks, not
a movable window.

Layout within a chunk, **flat/linear across the 4 KB seam** so a GR.8-size screen
(≈7680 B) plots contiguously (`PLOT`/line/etc. behave as expected):

```
offset 0x0000  ┌─────────────────────────┐
               │  display list           │  ANTIC reads DL here (banked with data)
               ├─────────────────────────┤
               │  screen data            │  LMS points into the aperture
               │  (up to ~GR.8, 8 KB)    │
   (optional)  ├─────────────────────────┤
               │  font (text modes)      │  CHBASE points here; see below
0x2000         └─────────────────────────┘
```

**ANTIC's bank covers the display list AND the screen data** (both in the
aperture). That is the point — "set up the screen exactly how you want, complete
with the perfect display list, and just swap."

**Font/charset (text modes):** no special hardware. A text mode can bank its font
by placing it in the aperture *after* the screen data and pointing `CHBASE` at
that address; whenever the chunk is banked in, the font is at that location too.
Text screens are small (DL + 40×24 data ≪ 8 KB), so a font fits. Bitmap modes
(GR.8) have no font and use the full aperture for data.

## Coherency model

One BRAM holds the **ANTIC** chunk (the displayed one). The CPU's writes are
routed by comparing `SCRNBANK_CPU` against the **effective** ANTIC bank:

- **`cpu_bank == antic_bank_eff`** (single-buffer / drawing the live screen):
  CPU writes go **straight into the ANTIC BRAM** — exactly what the snoop path
  (`bus_snoop` → `bram_shim`) does today. No DDR round-trip. (This case is
  unchanged from the current design, which is why the lift is small.)

- **`cpu_bank != antic_bank_eff`** (drawing off-screen): CPU writes are
  **write-through to DDR** chunk `cpu_bank` — never the ANTIC BRAM, so the
  displayed page is untouched.

- **VBI, when `antic_bank_eff` changes** (a flip): in the vblank window,
  **write back the outgoing BRAM → DDR** (only if a *dirty* bit is set — skip the
  redundant write in pure ping-pong double-buffering), then **read the incoming
  chunk DDR → BRAM**. 8 KB out + 8 KB in is a few µs against a ~1.3 ms vblank, so
  timing is a non-issue; a small interlock stalls CPU screen-writes during the
  reload as belt-and-braces.

This keeps the hard part — cross-view coherency — reduced to "write-through +
reload," reusing the existing `banked_page_cache` DDR↔BRAM machinery.

### Usage (software)

- **Single buffer:** `cpu_bank == antic_bank`. Drawing while ANTIC displays the
  same chunk can tear *at the Atari level* (ANTIC reads a half-drawn BRAM) — this
  is **official Atari behaviour**; the triple buffer does not mask it. Avoid it by
  drawing during the VBI, or (easier) by double-buffering.
- **Double / N buffer (recommended):** draw into an off-screen bank
  (`cpu_bank != antic_bank`, writes → DDR), then point `$D5C3` at it. At the next
  VBI ANTIC reloads it and reveals a complete, glitch-free frame.

## Plumbing (PL)

1. **ANTIC read path:** route in-aperture reads (DL + screen data) from the
   `mem_read_mux` consumers (`dl_parser`, `compositor`) to the ANTIC chunk BRAM
   (cache of `antic_bank_eff`); out-of-aperture reads stay on the main 64 KB
   shadow.
2. **CPU write router:** the `cpu_bank == antic_bank_eff` comparator (both
   registers are 6502-written, so it sits naturally in `clk_sally`); in-aperture
   writes go to BRAM (`==`) or DDR (`!=`). Only `antic_bank_eff` needs a 2-FF sync
   into `clk_sys` for ANTIC's fetch (changes once per frame).
3. **VBI FSM:** a slimmed `banked_page_cache` — on `antic_bank_eff` change, dirty
   writeback then reload, with the CPU-screen-write interlock.

## Open points

- **Off-screen CPU *reads* / read-modify-write.** The model above handles
  off-screen *writes* (write-through). Off-screen RMW drawing (XOR lines, etc.)
  needs a CPU-side read path from DDR `cpu_bank` — either add a CPU-side cache
  (a second `banked_page_cache` instance) or declare off-screen banks
  write-only. Decide based on whether the OS/clients do off-screen RMW.
- **Aperture base register vs hard-coded layout** — leaning hard-coded; revisit
  if a client needs to relocate it.
- **Interaction with the existing `$D5C0`/`$D5C1` windows** if the screen
  aperture overlaps them (it should be disjoint).
