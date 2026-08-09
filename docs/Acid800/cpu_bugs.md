# cpu_bugs — CPU: Bugs

**Pins down:** the NMOS 6502's famous documented bugs, in a system context.
NMOS-only — `_SKIP c"65C02/65C816 detected."`.

Source: [`src/cpu_bugs.s`](src/cpu_bugs.s). Two assertions plus control-flow
`_FAIL`s.

## The "very famous bug"

The test's own comment calls it that, and the structure gives it away: it
synchronises to scanlines 245–247, sets up an NMI, and executes a `BRK`, with
`_FAIL` sites at:

* `Execution went past a BRK insn.`
* `BRK handler should not have executed.`

— then checks *where* the handler returned to. This is the **NMI-hijacks-BRK**
behaviour, the same ground as [`antic_blockednmi`](antic_blockednmi.md) but
approached from the CPU side: when an NMI arrives during a `BRK`, the pushes
happen as `BRK`'s but the vector fetched is the NMI's, so the `BRK` handler
never runs and the interrupt is effectively lost as a `BRK`.

## Our implementation

`emu/xt6502.c` implements the hijack in `interrupt()`, deciding the vector
**after** the pushes so a late NMI still wins:

```c
push(c, (uint8_t)(brk ? (c->p | XTF_B | XTF_U) : ((c->p | XTF_U) & ~XTF_B)));
/* NMI hijacks a BRK/IRQ already in flight: the vector is chosen HERE */
if (c->nmi_pend) { vec = 0xFFFA; c->nmi_pend = 0; }
```

Note what [`antic_blockednmi`](antic_blockednmi.md) adds that this test does not:
there is a **one-cycle boundary** at which the NMI is instead *lost entirely*
and the `BRK` completes normally. Implementing "NMI always hijacks BRK" satisfies
this test and fails half of that one, so the two must be read together.

## To pass this test you must have

1. NMI hijack of an in-flight `BRK`, vector chosen after the pushes.
2. The pushed PC and `B` flag remaining `BRK`'s.
3. Whatever else the remaining assertions cover (the JMP `($xxFF)` page-wrap bug
   is the other classic; `xt6502.c` implements it in the `$6C` case).
