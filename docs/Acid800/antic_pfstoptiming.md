# antic_pfstoptiming — ANTIC: Playfield stop timing

**Pins down:** the scanline cycle at which `DMACTL` and `HSCROL` are sampled to
decide where the playfield **stops** — the right-edge counterpart to
[`antic_pfstarttiming`](antic_pfstarttiming.md).

Source: [`src/antic_pfstoptiming.s`](src/antic_pfstoptiming.s). Eight
assertions, in four early/late pairs.

## Method

Identical to the start-timing test: measure the edge indirectly through
player/playfield collisions, `(p0pf << 2) | p1pf + 12`, inside a DLI that writes
the register under test at a counted cycle. The `HSCROL` pair is annotated
`;write at 95`, placing this test's boundary near the **right** edge of the
playfield rather than the left.

## The four pairs

| register | mode | early | late |
|---|---|---|---|
| `DMACTL` | character | **18** | **16** |
| `DMACTL` | bitmap | **18** | **16** |
| `HSCROL` | character | **21** | **20** |
| `HSCROL` | bitmap | **21** | **20** |

**The direction is reversed relative to the start test**, and that is the point.
At the left edge, being late means the change misses and the playfield keeps the
old (narrower) start — stride goes *up* from 16 to 18. At the right edge, being
late means the playfield has already been told to stop, so the stride goes
*down*, 18 to 16.

The same asymmetry between the registers holds: `DMACTL` moves the measurement
by 2, `HSCROL` by 1.

## Why both tests exist

Together the pair establishes that ANTIC samples the windowing registers
**twice per scanline** — once to open the playfield and once to close it — and
that a write landing between the two sampling points affects one edge but not
the other. A model that samples `DMACTL`/`HSCROL` once per line, at the start,
passes `antic_pfstarttiming` and fails this one; a model that latches them at
the line boundary fails both.

This is the concrete form of the "the playfield window is computed, not fixed"
rule in [`../../emu/antic-design.md`](../../emu/antic-design.md).

## To pass this test you must have

1. A **second** sampling point for `DMACTL`/`HSCROL` at the right edge, distinct
   from the left-edge one at cycle 16/17.
2. Mid-scanline register writes able to change one edge without the other.
3. The same behaviour in character and bitmap modes.
4. Working collision detection (the readout) — see the note at the end of
   `antic_pfstarttiming.md`.
