---
title: "Issue #0001 — PSH guard byte"
description: "A resolved off-by-one in the xt6502 PSH frame layout that let in-frame pushes corrupt saved registers."
---

:::tip[Resolved]
Fixed 2026-05-26 and covered by a regression test; kept here as a case study.
:::


- **Component:** xt6502 core — PSH/PLL frame sequencer
- **Severity:** High (ABI-breaking; defeats documented interrupt-safety and "SEI needs no CLI" guarantees)
- **Status:** Fixed (2026-05-26, xt6502 + spec; see Resolution below)
- **Found:** 2026-05-26 (compiler ABI investigation; surfaced while chasing `array_arc` T1)
- **Files:** `hdl/xt6502/xt6502.sv` (PSH/PLL), `docs/6502/6502-embellishments.md` §3
- **Tests:** `sim/tb_sally_isa_xt.sv` Tests 13/14/15 (pass — but structurally cannot expose this)

---

## Summary

After `PSH #N`, the stack pointer points **at** the saved-P byte (`SP+0`), not at a
free slot below it. Because this machine pushes **post-decrement** (write at the
current SP, then `SP--`), `SP+0` is also the *next push target*. Therefore the first
push of any kind executed while the frame is live — `PHA`/`PHP`, `PUSH X/Y`, `JSR`,
or a hardware IRQ/NMI/BRK — overwrites the saved register slots that `PLL` later
restores from.

This is an off-by-one: PSH is missing a one-byte guard slot between SP and the
lowest occupied frame byte.

## Root cause (confirmed in RTL, not just the spec)

1. **Push is post-decrement.** `ST_PUSH` writes to `stk_addr = sp12` (the current SP),
   and the sequential block then commits `S <= sp12_dec`
   (`hdl/xt6502/xt6502.sv:599`, `:868–870`). JSR (`ST_JSR_PCH/PCL`) and BRK/IRQ
   (`ST_BRK_PCH/PCL/P`) share this convention. The next free slot is offset **+0**
   from SP.

2. **PSH commits SP onto the saved-P slot.** `ST_PSH0` writes `P` at
   `sp_new_psh = SP − (N+6)` (`hdl/xt6502/xt6502.sv:752–754`), and the frame commits
   `S <= sp_new_q` (`:907–908`). So after PSH, `SP == address of saved P == SP+0`,
   with no guard byte beneath it.

Combine the two: `SP+0` is simultaneously "saved P" and "where the next push goes."

## Blast radius

The corruption is not limited to P, and it triggers on the convention's own happy path:

- **Bare `JSR`** is a double hit: `ST_JSR_PCH` writes PCH at `SP` → clobbers saved P;
  `ST_JSR_PCL` writes PCL at `SP−1` → clobbers saved SP_lo.
- **Hardware IRQ/NMI/BRK** pushes three bytes → clobbers saved P, SP_lo, and SP_hi.
- **Any non-leaf function corrupts its own saved registers** the moment it pushes its
  first outgoing parameter: per the §4 calling convention the caller does `PHA`
  (params) then `JSR`, and at that point SP is still sitting on its own saved-P slot.

Net effect: PSH/PLL as built is safe only for a leaf that never pushes, never JSRs,
and runs with interrupts masked — which defeats the purpose of having call-tree frames.

## Contradictions in the spec (`docs/6502/6502-embellishments.md` §3)

- The stack diagram draws `saved P ← at SP+0` **and** a `(free / interrupt safe) ← SP`
  slot below it. Both cannot be true — the author intended a guard byte, but the
  offset table, the worked example, and the RTL omit it.
- The interrupt-safety claim ("any interrupt push would land strictly below the frame,
  never corrupting register saves or locals") is **false** against the implementation:
  an interrupt push lands *on* saved P.
- The "SEI needs no CLI" / scope-bounded-critical-section guarantee fails because
  saved P is the first byte destroyed.

## Why the test suite passes

Tests 13/14/15 in `sim/tb_sally_isa_xt.sv` never push between PSH and PLL — the frame
body uses only immediate loads (`LDA/LDX/LDY #imm`, `tb_sally_isa_xt.sv:504–506`) or
SP-relative ops. The defect lives entirely in a scenario the suite does not exercise.

## Proposed fix — reserve one guard byte

Restore the machine's post-decrement invariant ("SP = next free slot; everything above
SP is occupied") by having PSH leave SP one byte below the lowest written slot:

- PSH allocates and commits `SP = entry − (N + 7)` (was `N + 6`).
- Slot layout shifts up by one: saved P at `SP+1`, SP_lo `+2`, SP_hi `+3`, Y `+4`,
  X `+5`, A `+6`; `local[0]` at `SP+7`, `local[k]` at `SP+7+k`.
- PLL reads slots from `SP+1..SP+6` and deallocates `N + 7`.
- Update `docs/6502/6502-embellishments.md` §3 (operation, offset table, worked
  example, diagram) and the §4 param-access displacements (all `+1`).

Cost: 1 byte per frame. This is the only correct fix that preserves 6502 push
semantics — redefining push as pre-decrement would break legacy/Klaus compatibility
and is a non-starter.

## Regression test to add

`PSH #0` → push something (`PHA` and/or `JSR` to a trivial `RTS`) → `PLL #0`, then
assert that saved P and SP_lo survive the round trip. A second variant should fire a
hardware IRQ inside the live frame and assert the same.

## Resolution (2026-05-26)

Applied the proposed guard-byte fix to **xt6502** and the **spec** (the issue's
declared scope; SALLY's `cpu.v` is the soon-retired fallback and is left as-is):

- `hdl/xt6502/xt6502.sv`: PSH now allocates/commits `SP = entry − (N + 7)`
  (`psh_sub`/`pll_add` use `13'd7`); PSH writes P at `sp_new_q + 1` and the rest
  at `+2..+6`; PLL reads `sp12 + 1..+6` and deallocates `N + 7`.  `SP+0` is the
  guard byte.
- `docs/6502/6502-embellishments.md` §3 (operation, offset table, worked
  example, diagram) and §4 (param/local displacements, all `+1`).
- `sim/tb_sally_isa_xt.sv`: Tests 13/15/21 updated for the +1 slot layout, and a
  **new Test 30 (`test_psh_guard_byte`)** is the regression — `SEC; PSH #0;
  PHA #$00; PLA; CLC; PLL #0` then `ADC #$00`: asserts the restored C is 1,
  i.e. the in-frame push landed on the guard byte and left saved P intact.
  (Confirmed it fails on the pre-fix `N+6` layout and passes after.)  Full
  29+1-test suite + `sally_xt` (vs real `sally_mem`) + Klaus all green.

## Open question — relation to `array_arc` T1

This guard-byte defect is genuine and worth fixing regardless. Whether it is the cause
of the `array_arc` T1 failure is **not** confirmed here — that test is compiler-side and
not in this repo. If `array_arc`'s generated code interleaves a push/JSR inside a live
PSH frame, it should be ruled back *in* before closing that thread; otherwise the two
are separable.
