# antic_dlitiming — ANTIC: DLI timing

**Pins down:** the exact instruction boundary at which a display-list interrupt
is taken, for five different instruction phasings; what happens when `NMIEN` is
toggled off and back on around the DLI point; and how a DLI interacts with a
WSYNC halt.

Source: [`src/antic_dlitiming.s`](src/antic_dlitiming.s). Eight assertions.

## Method — the DLI handler reports where it struck

```
.proc dli
        pha
        txa
        pha
        tsx
    lda $0104,x        ; the low byte of the interrupted PC, off the stack
    sta d0
        pla / tax / pla / rti
.endp
```

After two pushes, `$0104,X` is the low byte of the return address the NMI
sequence pushed. So `d0` is **where the DLI interrupted**, and the test then
computes `d0 - <origin` to get an *instruction offset* from a known label. The
source marks the expected landing point with `<--`.

This is a far sharper instrument than "did an NMI happen": it measures the
interrupt latency to the instruction.

## The display list

```
dlist:  dta $70        ; 8 blank lines            -> scanlines 8..15
        dta $90        ; 2 blank + DLI            -> DLI on 17
        dta $90        ;                          -> DLI on 19
        dta $90        ;                          -> DLI on 21
        dta $90        ;                          -> DLI on 23
        dta $90        ;                          -> DLI on 25
        dta $41,a(dlist)
```

**Every DLI here is on a BLANK-LINE instruction**, and it fires on the **last**
scanline of the block.

Note the encoding, which is easy to get wrong: on a blank-line instruction bits
6–4 are the **line count minus one**, *not* option bits. So `$70` is **8** blank
lines and `$90` is **2** — the DLI bit is bit 7, and bit 6 is part of the count
rather than an LMS flag. Decoding LMS before checking for mode 0 makes `$70`
look like an LMS, eats two bytes of the display list, and derails everything
after it.
That is precisely the case this project's fabric `dl_parser` gets wrong — see
the `acid800_dli_cluster` note — so this test is the one to point a new ANTIC at
first.

## Assertions, part 1 — instruction phasing

Each test re-synchronises with `inc wsync`, then runs a chain of instructions
whose cycle positions are annotated, and records where the DLI landed. The five
differ only in how the instruction stream is phased against the scanline:

| var | expect | name | shape |
|---|---|---|---|
| `d1` | `$0a` | Even count | a chain of 2-cycle `nop`s |
| `d2` | `$09` | Odd count | the chain shifted one cycle by a preceding `sta $ff` |
| `d3` | `$0e` | Phase 1/3 | 3-cycle `lda $ff` chain |
| `d4` | `$0d` | Phase 2/3 | 3-cycle chain shifted by a 4-cycle `lda $0100` |
| `d5` | `$0c` | Phase 3/3 | 3-cycle chain shifted by a 5-cycle `inc d0` |

Together the five sweep the DLI point across every phase of a 2- and 3-cycle
instruction stream, so a model whose NMI is recognised one cycle early or late
fails a subset rather than all of them — which is what makes the failure
pattern diagnostic.

> **Note a typo in the suite:** `d5`'s failure message reads
> `"Phase 3/3 count incorrect: $%x != $09"` but the value asserted is `$0c`. The
> assertion is what counts. Do not tune an emulator to `$09`.

## Assertions, part 2 — NMIEN delay

```
lda #$00 / sta nmien     ; disable across the DLI point
lda $80
nop
lda #$80 / sta nmien     ; re-enable
...
```

| var | expect | name |
|---|---|---|
| `d1` | `$0F` | Delayed odd count |
| `d2` | `$0F` | Delayed even count |

Both phasings give the **same** answer, which is the point: re-enabling `NMIEN`
after the DLI point does not retroactively deliver the interrupt at the moment
of the write — the latched request is delivered on a fixed schedule, so the two
phasings converge.

The schedule is not the same as the status path's, though. Both cases re-enable
`NMIEN` on scanline cycle 7, the same cycle the status bit sets, and the two
assertions are only both satisfiable if the **write** path takes one cycle more
than the status path: the status set raises `/NMI` at cycle 8, a same-cycle
`NMIEN` write raises it at 9.

## Assertions, part 3 — DLI after WSYNC

```
mva #$80 nmien
sta wsync            ;-> (23:105)
origin_test8:
    nop              ; this should execute before DLI because its first cycle has already executed
    nop              ; this should execute after DLI
    nop
```

| var | expect | meaning |
|---|---|---|
| `d1` | `$01` | exactly **one** instruction retires between the WSYNC release and the DLI |

The comment in the source is the specification: an instruction whose **first
cycle has already begun** completes before the interrupt is taken. This is the
standard "interrupts are recognised at instruction boundaries, and the
in-flight instruction finishes" rule, but pinned to a specific cycle by the
WSYNC release at 104.

## To pass this test you must have

1. **Blank-line DLIs firing on the last scanline of the blank block** — the
   known fabric defect.
2. NMI recognised at an instruction boundary with the in-flight instruction
   completing, consistent across all five instruction phasings — and `/NMI`
   asserted **one cycle after** the NMIST bit, not with it. Three of the five
   phasings cannot tell the difference; `d1` and `d3` can.
3. `NMIEN` re-enable **not** retroactively delivering at the write.
4. The DLI landing exactly one instruction after a WSYNC release.
5. A working `VDSLST` vector and NMI push sequence (the handler reads its own
   return address off the stack, so the pushed PC must be right).
