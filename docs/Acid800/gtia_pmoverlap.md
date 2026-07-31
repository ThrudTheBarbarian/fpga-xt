# gtia_pmoverlap — GTIA: Player overlap

**Pins down:** the colour produced where players overlap each other, across
positions and priority settings.

Source: [`src/gtia_pmoverlap.s`](src/gtia_pmoverlap.s). The largest GTIA test
source (605 lines). Asserts by control flow from a table:

```
_FAIL c"Pass %d.%d: Pos=%x, Expected %x, Got %x"
```

The message shape gives away the structure: a two-level pass index, a horizontal
**position**, and expected-versus-got colour. So it sweeps overlapping players
across positions and checks the resulting colour at each.

Where two players overlap, GTIA does not simply pick one — the overlap region
takes a colour derived from **both** players' colour registers (the ORed-bits
behaviour of the P/M colour priority logic), and which one wins where depends on
`PRIOR`. The per-position sweep is there because the answer changes at the
boundaries of the overlap, not just inside it.

## To pass this test you must have

1. Player-player overlap colour from the P/M priority logic, not "topmost wins".
2. Correct behaviour at the overlap **edges**, per colour clock.
3. The interaction with `PRIOR`.

## Note

With 605 lines and a positional sweep this is a breadth test, and it is one of
the later ones to bring up — it depends on players rendering correctly at all
sizes and positions first, so [`gtia_pmresize`](gtia_pmresize.md) and
[`gtia_pmretrigger`](gtia_pmretrigger.md) should pass before this is meaningful.
