# gtia_phantomdma — GTIA: Phantom PMG DMA

**Pins down:** that GTIA latches a player byte from a DMA cycle that ANTIC
performs even when it "should not" have — phantom DMA.

Source: [`src/gtia_phantomdma.s`](src/gtia_phantomdma.s). One assertion.

```
mva #$02 gractl        ; player DMA only
inc wsync              ;end 32
inc wsync              ;end 33
...
_ASSERT1 d0, $ad, c"Phantom DMA byte #1 was not $AD (was $%x).",0
```

The expected byte is a specific value (`$AD`) from a specific address, so the
test proves not merely that *a* fetch happened but *which* one GTIA latched.

This is the GTIA half of the `antic_pmdma` story: ANTIC decides which cycles are
P/M DMA cycles, `GRACTL` decides whether GTIA latches what appears on the bus
during them, and the two are separately observable. A phantom fetch is one where
the DMA cycle occurs and GTIA takes the data even though the configuration
suggests it should not.

## To pass this test you must have

1. P/M DMA cycles occurring per ANTIC's schedule independently of `GRACTL`.
2. GTIA latching from the bus on those cycles according to `GRACTL`.
3. The two decoupled, so a cycle can happen without a latch and — as here — a
   latch can happen where naive gating would suppress it.

See also [`antic_pmdma`](antic_pmdma.md), whose "player DMA was not implicitly
enabled" assertion is the mirror image of this one.
