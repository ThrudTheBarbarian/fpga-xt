# gtia_consol — GTIA: CONSOL test

**Pins down:** that `CONSOL` (`$D01F`) reads back the **complement** of what was
written, in the low three bits.

Source: [`src/gtia_consol.s`](src/gtia_consol.s). Three assertions.

```
mva #$0c consol / lda consol / sta d0
mva #$0a consol / lda consol / sta d1
mva #$09 consol / lda consol / sta d2
```

| written | read back | `~written & $07` |
|---|---|---|
| `$0c` | `$03` | `$03` ✓ |
| `$0a` | `$05` | `$05` ✓ |
| `$09` | `$06` | `$06` ✓ |

`CONSOL`'s write side **drives the console-switch lines low**; the read side
returns the actual line state. With no switch pressed, a driven line reads 0 and
an undriven one reads 1 — so the readback is the complement of the written
value, masked to three bits.

## A wrong failure message (three of them)

The assertions read:

```
_ASSERT1 d0, $03, c"CONSOL value #1 bad: $%x != $04"
_ASSERT1 d1, $05, c"CONSOL value #2 bad: $%x != $02"
_ASSERT1 d2, $06, c"CONSOL value #3 bad: $%x != $01"
```

The **asserted** values are `$03`/`$05`/`$06`; the **messages** say
`$04`/`$02`/`$01`. The assertions are what run. This is the second such
mismatch found in the suite — see the note in
[`antic_dlitiming`](antic_dlitiming.md) — so treat any Acid800 failure message's
"expected" number as commentary and read the `_ASSERT` line for the truth.

## To pass this test you must have

`CONSOL` implemented as drive-low outputs plus a read of the resulting line
state, not as a plain readable register. A register that returns what was
written fails all three.
