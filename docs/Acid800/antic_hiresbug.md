# antic_hiresbug — ANTIC: Hires bug

**Pins down:** that a hi-res (mode F) line causes a **player-to-player collision
that does not occur otherwise**, with everything else held identical.

Source: [`src/antic_hiresbug.s`](src/antic_hiresbug.s). Two assertions.

## The construction

Both halves use the same players — `GRAFP0 = GRAFP1 = $FF`, both at
`HPOSP = $80`, `GRACTL = 0` so the patterns come straight from the registers —
and the same `DMACTL`. The DLI handler reads player-0-to-player-1 collision:

```
dli: sta wsync / sta hitclr / sta wsync / sta wsync
     lda p0pl / and #$02 / sta d1
```

The **only** difference is the display list line the DLI sits on:

```
dlist1: :29 dta $70 / dta $60 / dta $80          / dta $41,a(dlist1)
dlist2: :29 dta $70 / dta $60 / dta $CF,a($2000) / dta $41,a(dlist2)
```

`$80` is a blank line with DLI. `$CF` is **mode F (hi-res) with LMS and DLI**.

| var | expect | assertion |
|---|---|---|
| `d0` | `$00` | `Collision was found without bug` — blank line: no collision |
| `d1` | `$02` | `Collision not found with bug` — hi-res line: collision |

## What it means

Two overlapping players report **no** collision on an ordinary line and **do**
report one when a hi-res line is on screen. The hi-res artefact is therefore not
a rendering curiosity — it changes what GTIA's collision logic sees, and it does
so for player-to-*player* collisions, not just player-to-playfield.

## To pass this test you must have

1. Hi-res modes (2, 3, F) affecting collision detection.
2. The effect present for `P0PL` (player-player), not only the playfield
   collision registers.
3. Collision state that is a function of the **displayed** pixel stream, so a
   mode change on one line changes what collides on that line.

This is another argument for the "collisions are per colour clock, off the real
pixel pipeline" rule in [`../../emu/antic-design.md`](../../emu/antic-design.md):
a collision model that works from sprite/playfield *coordinates* rather than
from emitted pixels cannot produce this at all.
