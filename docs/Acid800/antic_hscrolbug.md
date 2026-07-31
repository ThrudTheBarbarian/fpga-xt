# antic_hscrolbug — ANTIC: HSCROL bug

**Pins down:** that glitching `HSCROL` mid-line moves the playfield **stop**
cycle such that ANTIC **fails to stop the playfield counter at all**, and keeps
fetching through horizontal blank — advancing the line-buffer address.

Source: [`src/antic_hscrolbug.s`](src/antic_hscrolbug.s). Eight assertions, in
two sets of four (even-cycle and odd-cycle variants).

This test carries the best comment in the suite: a full narrative plus an ASCII
DMA-cycle map of both scanlines. Read it in the source. The essentials:

> *"At HSCROL=0, hscrolled narrow mode E fetches bytes every two clocks at clocks
> 19-97. What we do here is temporarily glitch HSCROL to move the PF stop cycle,
> which causes ANTIC to fail to stop the playfield counter. This causes it to
> continue fetching through horizontal blank."*

`HSCROL` is restored immediately so the next scanline's fetch pattern lines up
again — otherwise ANTIC would fetch at double rate and display the OR of
adjacent bytes. The observable result is that the second scanline is **shifted
left by 17 bytes**, the number of extra fetches in HBLANK.

## The DMA map, and a detail it reveals

The comment draws both scanlines cycle by cycle with this legend:

```
^  Extra cycle location
F  Playfield fetch w/DMA cycle
#  Playfield fetch, but DMA cycle suppressed
R  Memory refresh cycle
```

**`R` is worth noticing: ANTIC's DRAM refresh cycles are part of the pattern.**
They appear interleaved with the playfield fetches (`F.FRF.FRF.FRF…`). Any DMA
model that accounts only for playfield, display-list and P/M fetches is missing
a class of stolen cycle. This project already knows refresh is subtle — a
preempted refresh is *lost* after one cycle rather than re-sought (see the
`antic_dma_sched` work) — and this test is where that shows up.

The `#` symbol is equally telling: a playfield fetch whose DMA cycle is
*suppressed*. Fetch and DMA-cycle-consumption are not the same event.

## The readout

Analysis mode replays the line buffer onto an extra mode `$0D` line, exposing
its internal contents:

```
55 AA 55 AA 55 AA 55 AA 55 AA 55 AA 55 AA 55 AA
55 AA 55 AA 55 AA 55 AA FF 00 00 00 00 00 00 00
```

> The test requires the `$FF` byte at buffer position `$18` to be displayed at
> horizontal positions `$78`–`$7B` — the normal position for byte `$12` — which
> means **the line buffer address was advanced by six additional locations**.

Assertions, per variant: `cl=$04`, `cr=$04`, `l=$01` (`$02` for the odd-cycle
variant), `r=$00`. The odd-cycle repeat is described as "more" demanding.

## To pass this test you must have

1. A playfield counter whose **stop** is a cycle comparison that can genuinely
   be missed, not a "stop after N bytes" counter.
2. Fetching that continues into HBLANK when the stop is missed.
3. A line buffer whose write address advances with those extra fetches.
4. Memory-refresh cycles modelled as part of the DMA pattern.
5. The distinction between a playfield fetch and a consumed DMA cycle.

Point 1 is the structural one: implement playfield stop as a byte count and this
test is unreachable, because a byte count cannot fail to terminate.
