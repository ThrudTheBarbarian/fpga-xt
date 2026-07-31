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

| region | scanlines | VCOUNT range |
|---|---|---|
| NTSC | 262 | 0 … 130, then a final **131**, then 0 |
| PAL  | 312 | 0 … 155, then a final **156**, then 0 |

The test detects the region by reading `PAL` (`$D014`; `$0F` means NTSC), waits
for `VCOUNT` to reach 130 (NTSC) or 155 (PAL), and then asserts:

| var | NTSC | PAL | meaning |
|---|---|---|---|
| `d0` | 131 | 156 | there IS a scanline on which VCOUNT reads one past the nominal maximum |
| `d1` | 0 | 0 | and the very next one has wrapped to zero |

Because the frame has an odd number of scanlines, the last one has no partner to
pair with, so the halved counter shows a value one above the maximum for exactly
one line before wrapping. A model that wraps at 130/155 — the obvious reading of
"262 lines / 2" — fails `d0`. A model that wraps one line late fails `d1`.

## To pass this test you must have

1. `VCOUNT` advancing at scanline cycle **111**.
2. `VCOUNT` = scanline >> 1, **9-bit**, not an 8-bit counter that wraps early.
3. The odd final scanline showing 131 (NTSC) / 156 (PAL) for one line.
4. `PAL` (`$D014`) reporting the region, since the expected values depend on it.
