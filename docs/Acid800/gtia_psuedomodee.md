# gtia_psuedomodee — GTIA: Pseudo mode E

**Pins down:** the artefact in which switching GTIA mode at a precise cycle
produces a display that behaves like ANTIC mode E when it should not.

Source: [`src/gtia_psuedomodee.s`](src/gtia_psuedomodee.s). Two assertions.

```
_ASSERT1 result0, $04, c"Cycle 14 test failed: %x"
_ASSERT1 result1, $0f, c"Cycle 15 test failed: %x"
```

Two probes, **one cycle apart** (14 and 15), with different expected values —
the same shape as the other boundary tests in the suite. The setup uses
`VSCROL = $01`, a single player (`GRAFP0 = $00`, `SIZEP0 = $03`) at `HPOSP0 =
$80`, `DMACTL = $22` and a DLI.

The `$0f` result is the tell: all four playfield-collision bits set, which is
the hi-res "everything collides as PF2"-adjacent behaviour appearing where the
mode nominally should not produce it.

## To pass this test you must have

1. GTIA mode changes taking effect at a cycle-accurate point mid-scanline.
2. The resulting hybrid display state, rather than snapping cleanly from one
   mode to the other at a line boundary.

This is closely related to [`gtia_collision2`](gtia_collision2.md)'s hi-res
rules and to [`antic_hiresbug`](antic_hiresbug.md): all three are consequences of
GTIA seeing a pixel stream whose interpretation changes with `PRIOR`/mode at a
point that need not align with anything.
