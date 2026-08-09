# antic_pmdma — ANTIC: P/M graphics DMA

**Pins down:** player/missile DMA — one-line versus two-line resolution, which
DMACTL bits imply which DMA, and the `PMBASE` bit that is dormant in one
resolution and live in the other.

Source: [`src/antic_pmdma.s`](src/antic_pmdma.s). Asserts by control flow, five
`_FAIL` sites, each printing the scanline and the bad value.

## What it checks

| `_FAIL` message | establishes |
|---|---|
| `One-line P0 data bad at line %d: $%x != $%x` | player DMA in **one-line** resolution fetches the right byte for each scanline |
| `One-line M0/M1 data bad at line %d: $%x` | missile DMA likewise, with `GRACTL` set for missiles only |
| `Player DMA was not implicitly enabled at line %d: $%x` | enabling **only** player DMA in `DMACTL` still causes missiles to DMA — the two are not independently gated the way the bit names suggest |
| `Two-line DMA bad at line %d: $%x` | switching to **two-line** resolution actually changes the fetch cadence |
| `PMBASE dormant bit 2 test failed at line %d: $%x` | `PMBASE` bit 2 is **ignored in one resolution and significant in the other** |

That last one is the sharp one. The test sets one-line resolution with `PMBASE`
bit 2 set, then switches to two-line **without touching `PMBASE`**, and requires
bit 2 to become active. So the bit is not masked at write time — it is masked at
*use* time, according to the current resolution.

## To pass this test you must have

1. Separate one-line and two-line P/M fetch cadences.
2. `DMACTL`'s player-DMA enable implying missile DMA (not two independent
   gates).
3. `PMBASE` bit 2 masked by the *current* resolution at address-generation time,
   not filtered when the register is written.
4. `GRACTL` selecting whether GTIA latches player data, missile data or neither
   — separately from whether ANTIC fetches it.

Points 2 and 3 are both cases where the obvious implementation (one bit, one
gate; mask on write) passes ordinary software and fails here.
