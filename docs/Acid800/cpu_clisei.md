# cpu_clisei — CPU: CLI/SEI timing

**Pins down:** the NMOS interrupt-poll semantics — the one-instruction delay
after `CLI`, the fact that a `CLI`/`SEI` pair still takes the interrupt (with `I`
**set** in the pushed status), and that `RTI`'s `I` is *not* delayed the way
`CLI`'s is.

Source: [`src/cpu_clisei.s`](src/cpu_clisei.s). Five assertions.

**This is the test Tom Harte cannot replace.** Harte ties the interrupt lines
inactive, so passing 256/256 there says nothing about *when* an interrupt is
taken. Everything below is invisible to it.

## Setup

The test drives a real IRQ source — POKEY's serial-output-complete interrupt
(`IRQEN = $08`) — and `_SKIP`s if that IRQ is not responding, so it degrades
honestly rather than passing vacuously. The handler records `X`, the pushed
status byte and the pushed PC.

## The three scenarios

### 1 — exactly one instruction after `CLI`

```
ldx #$ff / stx d0
inx          ; X = $00
cli
inx          ; X = $01   <- the IRQ lands after THIS
inx / inx / sei
_ASSERT1 d0, $01, c"CPU did not execute 1 insn after CLI: $%x != $01"
```

The NMOS part samples the interrupt lines during the **penultimate** cycle, so
`CLI`'s own poll still sees `I` set and the following instruction runs to
completion.

### 2 — a `CLI`/`SEI` pair interrupts anyway, with `I` set

```
inx          ; X = $00
cli
sei          ; <- the IRQ lands after this, X still $00
_ASSERT1 d0, $00, c"CPU did not interrupt within in CLI/SEI pair"
_ASSERTA $04, c"I flag was not set on stack after CLI/SEI/IRQ"
```

Both halves matter. The poll at `SEI`'s penultimate cycle sees the `I` that
`CLI` cleared, so the interrupt **is** taken — the comment in the source says
*"we successfully interrupt with I set (!)"*. But `SEI` has completed by the
time the status is pushed, so the pushed byte has `I` **set**.

### 3 — `RTI`/`SEI`: the interrupt lands between them, `I` clear

```
lda #>next / pha / lda #<next / pha / lda #$20 / pha
rti          ; <- the IRQ lands right after
next: sei
_ASSERT1 d0, $00, c"CPU did not interrupt between RTI/SEI pair"
_ASSERTA $00, c"I flag was set on stack after RTI/SEI"
```

`RTI` pulls the status at its **4th of 6** cycles, so the penultimate-cycle poll
already sees the pulled `I`. `RTI`'s `I` is therefore not delayed the way
`CLI`'s is — and since nothing has re-set it, the pushed status has `I` clear.

## Our implementation

`emu/xt6502.c` models this with a two-deep poll pipeline (`poll` / `poll_prev`)
clocked by the bus helpers, so `poll_prev` always holds the sample from one
cycle back — which at instruction end is the penultimate cycle. All three
scenarios then fall out without special-casing:

* `CLI` writes `P` *after* its final `rd()`, so that cycle's poll still sees the
  old `I`.
* `SEI` likewise, so its penultimate poll sees `CLI`'s cleared `I` while the
  register already has `I` set by push time.
* `RTI` pulls `P` mid-instruction, so the penultimate poll sees the new value
  for free.

**All three are checked on every build** by `emu/test/irq.c` (`make irq`),
rewritten from this test's scenarios, plus a fourth case for NMI edge-triggering
and one-shot behaviour. They pass.

## To pass this test you must have

1. Interrupt lines polled at the **penultimate** cycle, not at the instruction
   boundary.
2. Flag writes ordered relative to that poll (`CLI`/`SEI` late, `RTI` mid).
3. The pushed status reflecting the register **at push time**, not at poll time.
4. A working IRQ source, or the test skips.
