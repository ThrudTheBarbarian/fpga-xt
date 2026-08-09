# cpu_illegal — CPU: Illegal instructions

**Pins down:** the results of the undocumented NMOS opcodes.

Source: [`src/cpu_illegal.s`](src/cpu_illegal.s). Asserts by control flow.
Skipped twice over: `_SKIP c"Illegal instructions option disabled."` and
`_SKIP c"65C02/65C816 detected."`.

## Method

A table-driven executor: for each opcode it loads a register/flag context, copies
the instruction into a scratch execution slot, runs it, and compares the whole
resulting machine state:

```
;load instruction / setup temp registers / stash A / load X / stash Y
;stash P / load d5 / load Y / load A / load P / execute insn
```

## Subsumed by Tom Harte

`emu/test/harte.c` covers **all 256 opcodes** — documented and undocumented
alike — checking final registers, final RAM *and* the exact cycle-by-cycle bus
trace, over 277,600 cases. That is strictly stronger than a table of
result comparisons.

`xt6502.c` implements the full undocumented set with the conventions taken from
this repo's own `hdl/xt6502f/xt6502f.sv`, so the software and fabric cores agree
by construction:

* stable: `LAX SAX DCP ISC SLO RLA SRE RRA ANC ALR ARR SBX` and the undoc-NOPs
* unstable: `ANE`/`LXA` with magic constant `$EE`; `SHA`/`SHX`/`SHY`/`TAS` as
  `reg & (H+1)` with the page-cross high-byte quirk; `LAS`; `KIL`/`JAM` lock-up
  with its address dance

So this test should pass on the strength of the existing gate. Worth running as
a cross-check of the *conventions* — the unstable opcodes are the one place two
correct-looking implementations can legitimately disagree, and if this test
disagrees with Harte, the magic-constant choice is the first suspect.
