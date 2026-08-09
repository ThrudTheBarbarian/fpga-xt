# antic_vscroll — ANTIC: Vertical scrolling

**Pins down:** how `VSCROL` changes the number of scanlines a display-list row
occupies, across a table of cases.

Source: [`src/antic_vscroll.s`](src/antic_vscroll.s). One `_FAIL` site, driven
from a table:

```
_FAIL c"Failed test #%d: expected %d, got %d"
```

The message shape is the useful part: the test is **data-driven**, walking a
list of (start `VSCROL`, end `VSCROL`, mode) cases and comparing the resulting
row height against an expected count. A failure names the case index and both
numbers, so the failure alone tells you which scrolling combination is wrong and
by how much.

## Relationship to the other VSCROL test

[`antic_vscroldli`](antic_vscroldli.md) pins down *when* a `VSCROL` write is
sampled (by cycle 3 of the scanline). This one pins down *what the value does*
once sampled — the row-height arithmetic, including the wrap cases where the end
value is below the start value.

Together they are the pair a scrolling implementation has to satisfy: right
value, right instant.

## To pass this test you must have

1. Row height computed from the `VSCROL` start/end pair rather than a fixed
   per-mode line count.
2. Correct behaviour when end < start (the row runs long).
3. The same arithmetic across the modes the table covers.
