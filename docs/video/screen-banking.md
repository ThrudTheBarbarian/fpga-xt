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
| `$D5C2` | `SCRNBANK_CPU`   | 8 | Chunk the CPU draws/reads through the aperture. A write is a **request**: the PL writes the CPU-BRAM back to its old DDR slot (if dirty), loads the new slot into CPU-BRAM, then sets `SCRNBANK_STAT.ready`. |
| `$D5C3` | `SCRNBANK_ANTIC` | 8 | Chunk ANTIC fetches. Written any time, but **latched to the effective value only at VBI** (`antic_bank_eff`); the ANTIC-BRAM reloads from DDR on the change. |
| `$D5C4` | `SCRNBANK_STAT`  | 8 | bit0 `ready`: 0 while a `$D5C2` copy is in flight, 1 when CPU-BRAM holds the requested bank. **CPU must poll `ready` before touching screen RAM again** after writing `$D5C2`. |

8-bit index → up to 256 × 8 KB = 2 MB of screen chunks in DDR. Bank policy
(when/whether to flip, allocator) lives in PS/6502 software; the PL provides only
the two registers + the paging plumbing (the usual split — cf. the build-config
memory note).

**Why VBI-latch ANTIC but not the CPU:** ANTIC must read a *stable* chunk for a
whole frame, so its effective bank can only change between frames. The CPU's view
is its own BRAM; it changes when the `$D5C2` copy completes (poll `ready`).

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

**Two independent BRAM caches** over one DDR chunk-stack — symmetric, no
write-path comparator, no special "live" case. The CPU always works against its
own BRAM (fast read/modify/write); DDR is touched only on a bank switch.

- **CPU-BRAM** (cache of `cpu_bank`): the aperture as the 6502 sees it, full
  read/write. Writing `$D5C2` is a **request** handled by a `banked_page_cache`-
  style engine: write the CPU-BRAM back to the *old* `cpu_bank` DDR slot (skip if
  a **dirty** bit says it's unchanged), load the *new* slot into CPU-BRAM, then
  set `SCRNBANK_STAT.ready`. The CPU **polls `ready`** before touching screen RAM
  again. RMW (XOR lines, etc.) is always BRAM-speed — no per-byte DDR access.

- **ANTIC-BRAM** (cache of `antic_bank_eff`): **read-only** — ANTIC never writes
  screen RAM, so it needs **no writeback**, only a reload. `$D5C3` latches at VBI;
  on a change the engine reads the new chunk DDR → ANTIC-BRAM inside the ~1.3 ms
  vblank (8 KB ≈ a few µs), with a small interlock against the (idle) fetch path.

Data path: `CPU-BRAM → DDR → ANTIC-BRAM`. Software sequences it; the two caches
never alias because the flush and the reload are explicit, register-driven steps.

Polling (not a CPU bus stall) is deliberate: an 8 KB copy is ~tens of µs, so the
CPU should be free to do other work meanwhile rather than wait-stated.

### Usage (software) — the canonical double-buffer flip

```
draw frame into CPU-BRAM (bank A)         ; fast BRAM R/M/W
write $D5C2 = B                           ; flush A -> DDR[A], load DDR[B] -> CPU-BRAM
poll  $D5C4.ready                          ; wait for the copy
write $D5C3 = A                           ; ask ANTIC to show A
  ; at VBI: ANTIC-BRAM <- DDR[A]; the finished frame appears, tear-free
draw next frame into CPU-BRAM (bank B) ... ; ping-pong
```

Single-buffer (`cpu_bank == antic_bank`, live drawing into the displayed page) is
**not** a shared-BRAM mode here — the two caches are separate copies, so the CPU's
edits only reach ANTIC via a flush+reload. That's fine: live single-buffer
drawing tears at the Atari level anyway (official Atari behaviour); the
double-buffer flow above is both cleaner and the recommended path.

## Plumbing (PL)

1. **CPU aperture + copy engine:** an 8 KB CPU-BRAM mapped at the aperture for the
   6502 (read/write), plus a `banked_page_cache`-style engine driven by `$D5C2`
   writes (dirty writeback → reload → set `ready`). Both bank registers are
   6502-written so they live in `clk_sally`.
2. **ANTIC read path + reload engine:** route in-aperture reads (DL + screen data)
   from the `mem_read_mux` consumers (`dl_parser`, `compositor`) to the 8 KB
   ANTIC-BRAM (cache of `antic_bank_eff`); out-of-aperture reads stay on the main
   64 KB shadow. `antic_bank_eff` is latched at VBI (2-FF sync into `clk_sys`);
   on change, reload-only (no writeback — read-only cache).
3. **Shared DDR chunk-stack** on an HP port; the CPU copy engine and the ANTIC
   reload engine are the only masters. **Neither copy is latency-critical** — a
   bank switch (and thus its DDR traffic) is never required to complete
   *immediately*, so the engine can run at low priority / share bandwidth without
   stalling anything on the hot path.

> **Open work / next steps** are tracked in [NextSteps.md](../NextSteps.md) — see "Video / compositor / sprites / textures".
