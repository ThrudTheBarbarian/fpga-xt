# antic_wsync — ANTIC: WSYNC timing

**Pins down:** the exact cycle at which WSYNC releases `/RDY`, and what happens
when a WSYNC write lands *before*, *on* and *after* that cycle — including the
read-modify-write case, which writes `$D40A` twice.

Source: [`src/antic_wsync.s`](src/antic_wsync.s). Six assertions.

## Method

The test turns DMA and interrupts off, so the CPU owns every cycle, then starts
POKEY's LFSR at a known point and uses `RANDOM` as a **one-cycle-resolution
clock** (see the README):

```
mva #$80 audctl      ; long (17-bit) noise
mva #0   skctl
sta wsync
lda #3
sta wsync
sta skctl            ; LFSR out of reset at a known scanline cycle
sta wsync
ldy random           ; *, 105, 106, 107
sty d0               ; 108, 109, 110
```

Each subsequent measurement re-synchronises with `sta wsync`, spends a known
number of cycles, and reads `RANDOM`. The value read *is* the cycle number,
encoded.

## The assertions

| var | expect | assertion | what it establishes |
|---|---|---|---|
| `d0` | `$95` | `Initial RANDOM incorrect` | the LFSR started where the test thinks it did — a self-check; if this fails nothing else in the file means anything |
| `d1` | `$4B` | `STA WSYNC failed` | a plain `STA WSYNC` halts and resumes at the standard point |
| `d2` | `$0D` | `INC WSYNC failed` | the RMW case (skipped on a CMOS CPU — see below) |
| `d3` | `$44` | `Early WSYNC failed` | a WSYNC write completing at cycle **103**, i.e. *before* the release point |
| `d4` | `$E2` | `Late WSYNC failed` | a WSYNC write completing at cycle **104**, i.e. *on* the release point |
| `d5` | `$34` | `Late INC WSYNC failed` | an `INC WSYNC` whose six cycles span **99–104** |

## What the numbers mean

The cycle comments in the source are the specification. After any `sta wsync`,
the next instruction's cycles are annotated `105, 106, 107` — so:

> **WSYNC releases `/RDY` at cycle 104, and the first CPU cycle after the halt
> is 105.**

That matches the fabric path's `release 104` result.

The early/late pair is the sharp part:

```
bit $00     ;95-97
nop         ;98-99
sta wsync   ;100-103     -> d3 = $44   "early"
```
```
bit $0100   ;95-98
nop         ;99-100
sta wsync   ;101-104     -> d4 = $E2   "late"
```

Both write WSYNC on the same scanline, four cycles apart. The early one commits
at 103 and is released almost immediately at 104 — a halt of ~1 cycle. The late
one commits at 104, misses that release, and waits **a whole scanline**. A model
whose release compare is off by a single cycle gets one of these two right and
the other wrong, which is exactly what makes this test worth its weight.

## The RMW case, and why it is separated

```
bit $0100   ;95-98
inc wsync   ;99-104      -> d5 = $34
```

`INC` is a read-modify-write: it reads, writes the **old** value back, then
writes the new one — two writes to `$D40A`, on cycles 103 and 104. The test
asserts a value that distinguishes *which* of those two writes arms the halt.

> The halt arms on the **first** `$D40A` write of the RMW, not the second.

The `d2` INC assertion is explicitly skipped when `_cpuMode` says CMOS, with the
comment *"they do not stop for RDY on write cycles"* — a 65C02 does not honour
`/RDY` during writes at all. On an NMOS 6502 it does.

## To pass this test you must have

1. `/RDY` released at scanline cycle **104**.
2. Writes that are **not** `/RDY`-immune (NMOS behaviour) — but note this
   project's fabric core deliberately made writes RDY-immune to fix a deadlock;
   see the `acid800_wsync_deadlock_fixed` note. The software model must
   reproduce the *observable* result, not that workaround.
3. The WSYNC halt arming on the **first** write of a read-modify-write.
4. A cycle-exact POKEY `RANDOM` LFSR, or the test cannot even start.
