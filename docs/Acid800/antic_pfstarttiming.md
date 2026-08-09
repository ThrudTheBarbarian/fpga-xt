# antic_pfstarttiming — ANTIC: Playfield start timing

**Pins down:** the scanline cycle at which `DMACTL` and `HSCROL` are sampled to
decide where the playfield **starts** — separately for character and bitmap
modes.

Source: [`src/antic_pfstarttiming.s`](src/antic_pfstarttiming.s). Eight
assertions, in four early/late pairs. See also
[`antic_pfstoptiming`](antic_pfstoptiming.md), which does the same for the right
edge.

## Method — measure the playfield edge with collision registers

The playfield's left edge cannot be read directly, so the test infers it from
**player/playfield collisions**:

```
sta hitclr
sta wsync
lda p0pf
    asl
    asl
ora p1pf
add #12
_ASSERTA 16, c"Character mode DMACTL early test failed: stride=%d"
```

Two players are positioned so that which playfield regions they overlap depends
on where the playfield begins. `(p0pf << 2) | p1pf` packs both collision masks
into one number, `+12` biases it into a readable "stride", and the expected
value names the edge position. The failure message prints the stride it got, so
a failure says *how far off* the edge was, not merely that it was wrong.

Each measurement runs inside a DLI (`dli1`, `dli2`, …) which re-synchronises
with `sta wsync`, sets `VSCROL`, and then writes the register under test at a
precisely counted cycle.

## The four pairs

Each pair writes the same register one cycle apart. The `EARLY_TIMING` variant
substitutes a 5-cycle `inc a0` for three `nop`s, shifting the store by one
cycle:

```
pha:pla                 ;*, 105 ... 110
pha:pla                 ;111, 112, 113, 0, 1, 2, 3, 4
    inc a0              ; EARLY   (5 cycles)
  / nop:nop:nop         ; LATE    (6 cycles)
sta dmactl              ;13, 14, 15, 16   (early)  /  14, 15, 16, 17 (late)
```

| register | mode | early | late |
|---|---|---|---|
| `DMACTL` | character | **16** | **18** |
| `DMACTL` | bitmap | **16** | **18** |
| `HSCROL` | character | **16** | **17** |
| `HSCROL` | bitmap | **16** | **17** |

Read that as: a write **committing on cycle 16** is still in time to affect this
scanline's playfield start; a write committing on **cycle 17** is not, and the
edge lands where the previous value put it.

Note the asymmetry between the two registers: missing the `DMACTL` deadline
moves the measured stride by **2**, missing the `HSCROL` deadline by **1**.
`DMACTL` changes the playfield *width* (narrow/normal/wide, a two-colour-clock
step at this edge) while `HSCROL` shifts it by a single colour clock.

## To pass this test you must have

1. `DMACTL` and `HSCROL` sampled for the playfield start with the boundary
   between cycles **16 and 17**.
2. The same boundary for character and bitmap modes — the fetch machinery
   differs, the windowing does not.
3. A playfield start that is **computed per scanline** from the current register
   values, not a fixed window. A hard-coded 40-byte playfield cannot express
   this test at all.
4. Working P/M-to-playfield collision detection, since that is the readout —
   which means `gtia_collision` should be passing first, or a failure here is
   ambiguous.

That last point is worth planning around: this test *depends on* GTIA collision
being right. Bring collisions up before trying to debug playfield timing, or you
will be chasing an ANTIC bug that is really a GTIA one.
