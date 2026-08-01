# antic_vcount — ANTIC: VCOUNT timing

**Pins down:** the scanline cycle at which `VCOUNT` (`$D40B`) advances, and the
single-scanline rollover at the bottom of the frame.

Source: [`src/antic_vcount.s`](src/antic_vcount.s). Eight assertions (four
region-independent, then two each for NTSC and PAL).

## Part 1 — where the advance happens

Interrupts off, then four measurements. Each re-synchronises with `sta wsync`
(so the CPU resumes at cycle 105), burns a known number of cycles, and reads
`VCOUNT`. The two shapes differ by exactly one cycle:

```
sta wsync            ;end scan line 3
bit $00              ;*, 105, 106          (zero-page BIT, 3 cycles)
lda vcount           ;107, 108, 109, 110   -> the read lands on 110
sta d0
```
```
sta wsync            ;end scan line 5
bit $0100            ;*, 105, 106, 107     (absolute BIT, 4 cycles)
lda vcount           ;108, 109, 110, 111   -> the read lands on 111
sta d2
```

| var | expect | read lands on |
|---|---|---|
| `d0` | `$01` | cycle 110 |
| `d1` | `$02` | cycle 110, next line |
| `d2` | `$03` | cycle 111 |
| `d3` | `$03` | cycle 112, next line |

The four together bracket the advance: the pair that reads at 110 tracks the
line it is on, and the pair that reads at 111/112 shows the counter having
already moved. This is the origin of the landmark used throughout this project:

> **VCOUNT advances at scanline cycle 111.**

Any model that advances it at the start or end of the line gets two of these
four wrong.

## Part 2 — "the nasty one: single cycle rollover"

`VCOUNT` is the scanline counter's **upper 8 bits of 9** — i.e. it reports the
scanline number **divided by two**. So it runs:

| region | scanlines | `scanline >> 1` max | test expects |
|---|---|---|---|
| NTSC | 262 | 130 | **131** |
| PAL  | 312 | 155 | **156** |

**Where the extra value comes from.** Both frame heights are EVEN, so
`scanline >> 1` never reaches 131 or 156 — an earlier draft of this note claimed
the frame had an odd number of scanlines and the last one "had no partner",
which is simply wrong. The real mechanism follows from part 1: **VCOUNT advances
at cycle 111 of every scanline, including the last one.** On the final scanline
it therefore advances to `lines / 2`, and the frame wrap at the *end* of that
line resets it to 0.

It is cleared **one cycle later**, at 112, by a comparator — not at the end of
the line. So `VCOUNT` reads 131 (NTSC) for **exactly one cycle per frame**, which
is what the test's name means literally.

The two rollover probes make that unmistakable once you notice they sit on the
**same scanline** and differ only in how many cycles they burn after the WSYNC:

```
d0:  bit $0100        ;*, 105, 106, 107
     lda vcount       ;108, 109, 110, 111   -> reads on 111, must be 131
d1:  bit $00          ;*, 105, 106
     nop              ;107, 108
     lda vcount       ;109, 110, 111, 112   -> reads on 112, must be 0
```

A model that clears `VCOUNT` at the line wrap gives 131 for both.

The test detects the region by reading `PAL` (`$D014`; `$0F` means NTSC), waits
for `VCOUNT` to reach 130 (NTSC) or 155 (PAL), and then asserts:

| var | NTSC | PAL | meaning |
|---|---|---|---|
| `d0` | 131 | 156 | there IS a scanline on which VCOUNT reads one past the nominal maximum |
| `d1` | 0 | 0 | and the very next one has wrapped to zero |

A model that clamps at 130/155 — the obvious reading of "262 lines / 2" — never
produces `d0`. A model that resets VCOUNT when the scanline counter wraps at the
START of the line, rather than at the end, misses the window too.

## To pass this test you must have

1. `VCOUNT` advancing at scanline cycle **111**.
2. `VCOUNT` = scanline >> 1, **9-bit**, not an 8-bit counter that wraps early.
3. The advance at cycle 111 happening on the LAST scanline too, so VCOUNT reads
   131 (NTSC) / 156 (PAL) for exactly one cycle, cleared at 112 rather than at
   the end of the line.
4. `PAL` (`$D014`) reporting the region, since the expected values depend on it.
