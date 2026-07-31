# gtia_pmresize — GTIA: Player resizing

**Pins down:** what happens when a player's **size is changed mid-object** —
every transition between 1×, 2× and 4× widths.

Source: [`src/gtia_pmresize.s`](src/gtia_pmresize.s). Asserts by control flow,
seven `_FAIL` sites, each printing an index and both values:

```
_FAIL c"4x-to-1x failed at index %d: expected $%x, got $%x"
_FAIL c"4x-to-2x failed at index %d: ..."
_FAIL c"2x-to-4x failed at index %d: ..."
_FAIL c"1x-to-2x failed at index %d: ..."
_FAIL c"1x-to-4x failed at index %d: ..."
_FAIL c"2x-to-1xalt failed at index %d: ..."
_FAIL c"4x-to-1xalt failed at index %d: ..."
```

Seven transitions, including two marked **`alt`** — the same nominal transition
reached by a different route, which produces a *different* result. That is the
tell: the outcome depends not only on the old and new sizes but on the internal
state of the size counter when the write lands.

## Why this is hard

A player's width is implemented as a shift-clock divider. Changing `SIZEP`
mid-object does not restart the object; it changes the divide ratio **with the
counter part-way through**, so the remaining pixels come out at the new width
from wherever the phase happened to be. The `alt` cases exist precisely because
two paths to the same size leave the counter in different phases.

## To pass this test you must have

1. Player width as a **live divider with observable phase**, not a
   precomputed pixel run.
2. `SIZEP` writes taking effect immediately, mid-object.
3. The phase preserved across the change rather than reset.

A renderer that expands a player to a pixel run at object start cannot express
any of the seven.
