# Issue #0005 — `tb_snoop` MODE_SNOOP check is stale; asserts old `$D481`-writable behaviour

- **Component:** Verification — `sim/tb_snoop.sv` ($D481 MODE check)
- **Severity:** Medium (a real `make snoop` failure; the design is correct, the test is wrong)
- **Status:** Resolved (2026-06-26)
- **Found:** 2026-05-30 (running the suite after the `antic_top` clk_bus reframe;
  confirmed pre-existing — fails identically against the committed `antic_top.sv`)
- **Files:** `sim/tb_snoop.sv:158,215-218`; design ref `hdl/antic_regs.sv:186-189,138`

---

## Summary

`make snoop` fails:

```
FAIL MODE_SNOOP: expected 0 after $D481 write of 0, got 1
*** SNOOP FAIL *** 1 failures
```

The test (`tb_snoop.sv:158`) writes 0 to `$D481` and then asserts
(`:215-218`) that `mode_snoop` flipped to 0 ("DMA mode"). The design holds
`mode_snoop` at 1, so the check fails.

## Root cause — the test encodes superseded behaviour, the design is correct

`$D481` is **not** a writable MODE register in the current design.
`hdl/antic_regs.sv:186-189` treats it as a stock ANTIC mirror of `$D401` (CHACTL)
— real ANTIC aliases `$D400-$D4FF` onto its 16 registers — and `mode_snoop` is
**reset-locked to 1 (snoop)** and not bus-writable (`antic_regs.sv:138`). This is
deliberate: a stray `$D481` write (the stock CHACTL mirror) must not clobber the
snoop/DMA mode. See [[antic_render_d481_modesnoop]] — locking `mode_snoop` to snoop
was the fix that made the BASIC READY screen render correctly.

`tb_snoop` was written against the earlier design where `$D481` bit 0 *was* the
writable MODE_SNOOP control. The behaviour was intentionally changed; the test was
never updated. So this is a stale-test failure, not a design regression.

## Confirmation it is pre-existing / unrelated to recent work

Rebuilt `tb_snoop` against the committed (unmodified) `antic_top.sv` — same failure,
same line. The 2026-05-30 `POKEY_CLK_BUS_HZ` default reframe (161→150 MHz) only
touches POKEY's clock dividers and has nothing to do with `$D481`/`mode_snoop`.

## Fix

Update `tb_snoop.sv`:

- Drop the "write 0 to $D481 flips to DMA mode" stimulus/expectation
  (`:158`, `:215-218`), or repurpose the check to assert the **current** contract:
  `mode_snoop` stays 1 across a `$D481` write (i.e. the mirror does not disturb it),
  and that `$D481` writes alias to `$D401`/CHACTL as the RTL intends.
- Keep the rest of the snoop coverage (e.g. the `$D210` → `stereo_active_q` check at
  `:283` already passes).

The design needs no change. Once the test matches the current `$D481` contract,
`make snoop` should rejoin the green suite.

## Resolution (2026-06-26)

Fixed, test-only (no RTL change). `tb_snoop.sv` now writes 0 to `$D481` and asserts
`mode_snoop` **stays 1** (snoop) — i.e. the lock holds — rather than the old
"flips to 0 (DMA)" expectation. `make snoop` → `*** SNOOP OK ***`.

Nuance worth recording: the "Fix" note above suggested also asserting that `$D481`
*aliases to CHACTL*, but that only holds in the **canonical (locked)** decode. The
test runs at the **native/unlocked default** (`unlock_antic` resets to 1), where
`$D481` is the *chiplet MODE register* with `mode_snoop` reset-locked — it does **not**
touch CHACTL (which is why the test's existing `CHACTL==$02` check already passed).
So the robust, decode-independent assertion is simply "a `$D481` write leaves
`mode_snoop` at 1", which is true in both decodes.
