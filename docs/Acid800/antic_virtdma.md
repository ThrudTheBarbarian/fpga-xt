# antic_virtdma — ANTIC: Virtual DMA

**Pins down:** DMA cycles ANTIC takes that fetch nothing visible — the extra
cycles a **wide, horizontally-scrolled** playfield costs even where no data is
displayed.

Source: [`src/antic_virtdma.s`](src/antic_virtdma.s). Four assertions.

## Setup

```
mva #$23 dmactl        ; wide playfield
                       ; horizontally +2 scrolled mode 7 screen
sta gractl             ; collision-detect sprites along the right border
```

The test documents the DMA pattern for the scanlines it cares about as a
comment-drawn cycle ruler (0–113 across three lines), then places sprites along
the **right border** so collisions report where the fetches actually landed.

| assertion | expect |
|---|---|
| `Pattern #1 was not correct: %x != $00` | `$00` |
| `Pattern #2 was not correct: %x != $05` | `$05` |
| `Pattern #3 was not correct: %x != $0c` | `$0c` |
| `Pattern #4 was not correct: %x != $0f` | `$0f` |

## A detail worth stealing

> *"We need to use `STA wsync,X` in order to push the WSYNC write out one cycle
> so that the next cycle is not a DMA cycle."*

`STA abs,X` is a cycle longer than `STA abs` because the indexed store always
spends its address-fixup cycle. The test uses that deliberately to slide the
WSYNC write off a DMA cycle. It is a good reminder that in this suite the
*choice of addressing mode* is often load-bearing timing, not style — and that
our own core has to get the indexed-store cycle count right (it does; Harte
covers it) for these tests to line up at all.

## To pass this test you must have

1. Wide-playfield DMA including the cycles that fetch data which is then not
   displayed.
2. Horizontal scrolling adding its extra fetch at the correct cycles.
3. The interaction of the two, which is what the four patterns sample.

This test is closely tied to [`antic_dmapattern`](antic_dmapattern.md): that one
specifies the per-mode cycle allocation, this one checks the wide+scrolled
corner of it where fetches happen with nothing to show for them.
