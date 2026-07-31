# mmu_xlbanking — MMU: XL banking

**Pins down:** the XL/XE `PORTB` (PIA port B) memory-banking bits — which ROMs
appear where, and that ROM is genuinely not writable.

Source: [`src/mmu_xlbanking.s`](src/mmu_xlbanking.s). 10 assertions.
`_SKIP c"Test skipped: <64K of memory."`.

## The sequence

Each step writes `PORTB` and then probes memory, building a 4-bit mask of which
regions read as RAM:

| step | expected mask | assertion |
|---|---|---|
| all ROMs banked out | `$0f` | `Unable to bank out ROMs: mask=$%x.` |
| kernel ROM only | `$03` | `Unable to bank in kernel ROM.` |
| BASIC ROM only | `$0d` | `Unable to bank in BASIC ROM.` |
| self-test ROM only | `$0f` | `Self-test ROM bit failed: mask=$%x.` |
| kernel **and** self-test | `$02` | `Unable to bank in self-test ROM: mask=$%x.` |

The self-test pair is the interesting one. Asking for the self-test ROM *alone*
leaves the mask at `$0f` — i.e. **nothing is banked in** — but asking for kernel
*and* self-test gives `$02`. The self-test ROM only appears when the kernel ROM
is also enabled; its enable is not independent.

The final group *"attempt to complement bytes through ROM; this should fail"*
checks that writes to a banked-in ROM region do not take effect — the write must
not fall through to the RAM underneath.

## Relevance to this project

Directly relevant: this repo already has an XL banking path and an OS ROM window
(`xl_boot.c`, the `romwin_write` loader, `$D5C0`/`$D5C1` DDR banking). The rules
above are the conformance statement for it, and the self-test dependency is
exactly the kind of thing a from-first-principles implementation gets wrong by
treating each `PORTB` bit as an independent enable.

## To pass this test you must have

1. `PORTB` bits decoded per the XL map, with the **self-test ROM dependent on
   the kernel ROM** rather than independently enabled.
2. Reads returning ROM and writes **not** reaching the RAM underneath while a
   region is banked in.
3. The 64 K check, so a small-memory configuration skips rather than fails.
