# antic_linebuffering — ANTIC: Line buffering

**Pins down:** that ANTIC **fetches into a line buffer** and displays from it, so
fetch time and display time are different instants — and what happens when
`DMACTL` is changed between the two.

Source: [`src/antic_linebuffering.s`](src/antic_linebuffering.s). Asserts by
control flow (`_FAIL` on a mismatched readout), eight scenarios.

This is the test behind the first "design in now" rule in
[`../../emu/antic-design.md`](../../emu/antic-design.md). An ANTIC that fetches
and displays in the same step cannot pass it, and retrofitting a line buffer
afterwards means rewriting the renderer.

## Method — read the playfield back with missiles

```
mva #$aa grafm          ; a missile bit pattern
mva #0   sizem
ldx #$44 / jsr setMissilePos
...
sta hitclr
sta wsync
jsr checkMissiles       ; reads the missile/playfield collision registers
beq check1_ok
_FAIL c"Readout incorrect for initial mode E: %x%x%x%x"
```

Missiles are placed across the line and their playfield collisions are read
back, so `checkMissiles` effectively **samples what was actually displayed** at
four positions. The failure message prints all four nibbles, so a wrong readout
tells you *where* along the line the display diverged.

## The scenarios

| `_FAIL` message | what it exercises |
|---|---|
| `initial mode E` | baseline — the display list's own mode, nothing changed |
| `aliased mode 8` | `DMACTL` changed *after* the fetch, so mode 8 data is displayed under different windowing than it was fetched with |
| `aliased narrow mode 8` | same, into a narrow playfield |
| `aliased mode F` | same for mode F |
| `mid-interrupted mode 8/center` | DMA disabled partway through the line — centre |
| `mid-interrupted mode 8/left` | …left |
| `mid-interrupted mode 8/right` | …right |
| `mid-interrupted replayed mode 8/right` | the buffer **re-displayed** after interruption |

The sequence that produces the aliasing is explicit in the source:

```
mva #$20 dmactl         ; playfield DMA off
sta wsync               ;end scan 34
ldx #$80 / jsr setMissilePosX4
lda #$22
sta wsync               ;end scan 35
sta dmactl              ; back on, at a different width
sta hitclr
sta wsync               ;end scan 36
jsr checkMissiles
```

## What it establishes

1. **The line buffer is real.** Data fetched under one `DMACTL` is displayed
   under whatever `DMACTL` says at *display* time. The two are decoupled.
2. **Interrupting DMA mid-line does not blank the rest of the line** — the
   buffer still holds what was fetched, and the "replayed" case shows it being
   displayed again.
3. The left/centre/right variants pin down *which portion* of the buffer
   survives an interruption, so the buffer's fill pointer and the display
   pointer are separately observable.

## To pass this test you must have

1. A genuine **line buffer**: fetch fills it, display reads it, and the two use
   the register values current at their own moment.
2. `DMACTL` affecting fetch and display independently, per the start/stop
   sampling points in [`antic_pfstarttiming`](antic_pfstarttiming.md) and
   [`antic_pfstoptiming`](antic_pfstoptiming.md).
3. Buffer contents persisting when playfield DMA is disabled mid-line, and being
   re-displayable.
4. Missile/playfield collision detection (the readout) — another test that
   depends on GTIA collisions being right first.

## Design consequence

Combined with `antic_dmapattern` (which says exactly which cycles the fetches
occupy) and the playfield-timing pair (which says when the window registers are
sampled), this test fixes the shape of the renderer:

> Fetch on the cycles `antic_dmapattern` specifies, into a buffer. Display from
> that buffer on its own schedule, consulting `DMACTL`/`HSCROL` as sampled at the
> display-side points. Never render straight from memory.
