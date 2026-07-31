# gtia_pmretrigger — GTIA: P/M retriggering

**Pins down:** that writing `HPOS` mid-scanline **retriggers** a player so it is
drawn a second time on the same line, and the exact cycle by which that write
must land.

Source: [`src/gtia_pmretrigger.s`](src/gtia_pmretrigger.s). Seven assertions.

| assertion | expect |
|---|---|
| `Player did not retrigger properly.` | `$06` |
| `Player retrigger timing test #1 failed: $%x.` | `$04` |

The second is annotated *"try retriggering one cycle too early"* — so this is
another one-cycle boundary, this time on the horizontal-position comparator.

## The behaviour

GTIA draws a player when the colour-clock counter matches `HPOS`. It does not
latch "already drawn this line", so moving `HPOS` ahead of the beam mid-line
makes the comparator match again and the player is drawn twice. Write it one
cycle too early and the match is missed — the difference between `$06` and `$04`
in the collision readout.

## To pass this test you must have

1. `HPOS` compared against the live colour-clock position **continuously**, not
   sampled once per scanline.
2. No once-per-line "already emitted" interlock.
3. The comparison boundary correct to the cycle.

Point 1 is the structural one and it is the same shape as the playfield rule: a
renderer that decides sprite positions at the start of the line cannot retrigger
at all.
