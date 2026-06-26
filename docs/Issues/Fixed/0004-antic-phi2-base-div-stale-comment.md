# Issue #0004 — `fpga_xt_top` comment misstates ANTIC's phi2 divider (`BASE_DIV=68`, actually 90)

- **Component:** ANTIC integration — `fpga_xt_top` instantiation comment
- **Severity:** Low (stale comment; no functional effect)
- **Status:** Open
- **Found:** 2026-05-30 (while reframing the stale clk_bus rate comments in `antic_top.sv`)
- **Files:** `hdl/fpga_xt_top.sv` (~line 761), cf. `hdl/antic_top.sv:327`

---

## Summary

The comment above the `antic_top` instantiation in `fpga_xt_top.sv` claims ANTIC
derives its synthetic phi2 with `BASE_DIV=68`, and calls `BASE_DIV` an "internal
parameter [that] needs to match":

```
// antic_top generates its own phi2 from clk_bus using BASE_DIV=68 (adjusted
// from 90 for our clock rate).
// ...
// Its internal BASE_DIV parameter needs to match
```

Both halves are wrong against the current RTL:

1. **The value is 90, not 68.** `antic_top.sv:327` is
   `localparam int unsigned BASE_DIV = 90;`. phi2 = clk_bus / 90 — at the
   production clk_bus of 150 MHz (clk_sys) that is ≈1.67 MHz.
2. **It is a `localparam`, not a parameter.** It cannot be overridden from
   `fpga_xt_top` and there is nothing to "match" — the instantiation does not (and
   cannot) set it.

## Impact

None functional — phi2 is correct (the RTL uses the real `BASE_DIV=90`). This is
purely a misleading comment that will send the next reader looking for a 68 divider
or an overridable parameter that doesn't exist.

## Fix

Reword the `fpga_xt_top.sv` comment to state the truth: ANTIC derives phi2 as
`clk_bus / BASE_DIV`, `BASE_DIV` is a fixed `localparam = 90` inside `antic_top`
(not instantiation-overridable), and at clk_bus = clk_sys = 150 MHz phi2 ≈ 1.67 MHz.
Drop the "adjusted from 90 → 68" and "needs to match" language. Per the docs
convention ([[docs_no_historical_framing]]) describe only the current behaviour.

## Related

Surfaced alongside the `antic_top.sv` clk_bus reframe (the old "161.08 MHz / ×90
NTSC / SALLY speed grades" default, now `POKEY_CLK_BUS_HZ = 150_000_000` clk_sys).
The 68-vs-90 discrepancy is the mirror-image stale note on the `fpga_xt_top` side.
