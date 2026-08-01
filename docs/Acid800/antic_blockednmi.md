# antic_blockednmi — ANTIC: Blocked NMIs

**Pins down:** the arbitration between an arriving NMI and a `BRK` already in
flight — and specifically the **one-cycle boundary** between "the BRK wins and
the NMI is lost" and "the NMI hijacks the BRK".

Source: [`src/antic_blockednmi.s`](src/antic_blockednmi.s). No `_ASSERT1`s —
it asserts by *control flow*: four handlers, three of which call `_FAIL` if they
are ever entered.

Skipped on a CMOS CPU (`_SKIP c"65C02/65C816 detected."`), because this is an
NMOS behaviour.

## Method

Both halves set up a VBI NMI to arrive at a known point, then execute a `BRK`
whose cycles straddle that point. Which handler runs is the answer.

```
mwa #irq vimirq          ; the BRK/IRQ vector path
mwa #nmi vvblki          ; the NMI (VBI) path
```

`_FAIL` sites: `nmi` ("VBI handler should not have executed"), `after`
("Execution went past BRK insn #1"), `irq2` ("BRK handler should not have
executed").

## Half 1 — the BRK wins, the NMI is lost

```
brktest:
    mva #$40 nmien      ;*, 104, 105, 106, 107, 108
    lda $0100           ;109, 110, 111, 112
    nop                 ;113, 0
    nop                 ;1, 2
    brk                 ;3, 4, 5, 6, 7, 8, 9
after:
    _FAIL c"Execution went past BRK insn #1."
```

Expected: control reaches **`irq`** — i.e. `BRK` vectors normally through
`$FFFE`. The `nmi` handler must **not** run, and execution must not fall through
to `after`.

So with the `BRK` occupying cycles **3–9**, the NMI is *swallowed*.

## Half 2 — the NMI hijacks the BRK

The `irq` handler re-arms everything and repeats the measurement with the `BRK`
shifted **one cycle later** (an extra `lda $ff` before it):

```
    lda $ff             ;1, 2, 3
    brk                 ;4, 5, 6, 7, 8, 9, 10
after:
    _FAIL c"Execution went past BRK insn #2."
```

Expected: control reaches **`nmi2`**, and `irq2` (the BRK handler) must **not**
run. `nmi2` then checks the return address on the stack:

```
    tsx
    lda $0105,x / cmp #<(irq.after+1)
    lda $0106,x / cmp #>(irq.after+1)
```

`irq.after+1` is the address `BRK` itself pushed — `BRK` is one byte but pushes
`PC+2`, skipping its padding byte. So the assertion is precise:

> The NMI handler runs with **the BRK's own pushed return address**. The push
> sequence was the BRK's; only the vector was replaced.

That is the classic NMI-hijacks-BRK behaviour: the pushes happen as BRK's
(including `B` set in the pushed status), and the vector fetched at the end is
`$FFFA` rather than `$FFFE`.

## The point

The two halves differ by **one cycle** in when the `BRK` begins, and the
outcomes are opposite:

| BRK cycles | outcome |
|---|---|
| 3–9 | BRK completes through `$FFFE`; the NMI never happens |
| 4–10 | NMI hijacks; `$FFFA` is fetched with BRK's pushed state |

A model that implements "NMI always hijacks BRK" passes half 2 and fails half 1.
A model that implements "BRK always wins" does the reverse. Only a model that
polls the NMI at the correct cycle within the BRK sequence passes both.

## To pass this test you must have

1. NMI recognition at the correct cycle *inside* the BRK sequence, not merely at
   instruction boundaries. The VBI request lands at scanline cycle 6, so half 1
   puts it on BRK cycle 4 and half 2 on BRK cycle 3: **the vector is committed
   at the end of the sequence's third cycle**, immediately after the PCH push.
   An NMI latched at or before that cycle diverts; one latched after it is
   **swallowed** — not deferred, since half 1's `irq` handler does not clear
   `NMIEN` for several instructions and a deferred NMI would run the forbidden
   handler at the very next instruction boundary.
2. The hijack replacing **only the vector** — the pushed PC and the `B` flag stay
   BRK's.
3. `NMIEN` enabling the VBI mid-scanline generating (or not generating) the
   request at the right cycle — half 1's NMI must be genuinely lost, not merely
   deferred.
4. `_SKIP` behaviour is irrelevant to us (we are NMOS), but note the suite
   considers this NMOS-only.
