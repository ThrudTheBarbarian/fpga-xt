# cpu_timing — CPU: Timing

**Pins down:** instruction cycle counts, measured on real hardware, including
the page-crossing rules.

Source: [`src/cpu_timing.s`](src/cpu_timing.s). 16 assertions via `_ASSERTX`
(asserts the X register), each reporting `%d-5` — the count with the harness's
own 5-cycle overhead subtracted.

| assertion | value | what |
|---|---|---|
| `Incorrect DEX/BNE cycle count` | `$05` | the empty timing loop itself — the calibration |
| `Incorrect NOP cycle count` | `$07` | `NOP` = 2 |
| `Incorrect LDA abs cycle count` | `$09` | `LDA abs` = 4 |
| `Incorrect LDA abs,X (1)` | `$09` | `LDA abs,X` **no** page cross = 4 |
| `Incorrect LDA abs,X (2)` | `$0A` | `LDA abs,X` **crossing** = 5 |
| `Incorrect STA abs,X (1)` | `$0A` | `STA abs,X` no page cross = **5** |

The `LDA abs,X` pair and the `STA abs,X` entry together are the interesting
part: a *read* skips the address-fixup cycle when the index does not cross a
page, but a *store* always spends it. That asymmetry is why `LDA abs,X` costs 4
or 5 depending on the operand while `STA abs,X` costs 5 regardless.

## Relationship to our core

This is the one `cpu_*` test whose content **is** covered by Tom Harte — the
cycle counts are implied by the exact bus traces `emu/test/harte.c` already
checks, opcode by opcode, across 277,600 cases. `xt6502.c` implements the
asymmetry explicitly as `am_absi_r()` versus `am_absi_w()`:

```c
static uint16_t am_absi_r(xt6502 *c, uint8_t i)   /* fixup only on cross */
static uint16_t am_absi_w(xt6502 *c, uint8_t i)   /* fixup always */
```

So this test should pass on the strength of the Harte gate. It is still worth
running: it measures on the real machine with DMA and refresh present, so a
disagreement here after Harte passes points at the *system*, not the CPU.

## Why it matters beyond the CPU

`antic_virtdma` deliberately uses `STA wsync,X` **because** the indexed store
spends that extra cycle, sliding the WSYNC write off a DMA cycle. The suite
treats these counts as load-bearing timing, so they must be right before any
ANTIC test lines up at all.
