# antic_dmapattern — ANTIC: DMA pattern

**Pins down:** which scanline cycles ANTIC steals from the CPU, **per mode, per
playfield width** — the complete cycle-allocation specification. Everything else
in the ANTIC suite sits on top of this being right.

Source: [`src/antic_dmapattern.s`](src/antic_dmapattern.s). No `_ASSERT1`s; it
fails with `_FAIL c"Incorrect timing for mode %x-%c"`, naming the mode and the
playfield width.

## The test carries the specification as data

The `testdata` table is a literal per-cycle mask for every mode, in **two**
blocks — **narrow** and **normal** playfield. That is 50 rows, matching the
test's own "We have 50 tests to do". There is no wide-playfield block: wide is
covered by [`antic_virtdma`](antic_virtdma.md) instead, which is where the extra
fetches with nothing to display get measured.

```
;              0123456  78901234  56789012  34567890  ...
dta $08,%01000011,%00000000,%00000000,%01101111,%11111111, ... ,$A5
dta $09,%00000000,%00000000,%00000000,%01000111,%01110111, ... ,$A5
dta $0c,%01000011,...
```

Each row is: **mode byte**, then 14 mask bytes walking the scanline cycle by
cycle, then `$A5` as a terminator. The column header above each block gives the
cycle numbering: a 7-wide first group then thirteen 8-wide groups = 111 cycles,
against 14 mask bytes = 112 bits — so **one bit of the first byte is padding**,
and whether the cycles occupy bits 7..1 or 6..0 is not settled by the ruler
alone.

Polarity is not stated either, but the evidence points one way: for a narrow
mode-8 line, which fetches very few bytes, the middle mask bytes are `$FF` —
consistent with **1 = CPU-available (unhalted)** rather than 1 = blocked. The
test's own comment says it walks the mask *"counting off the unhalted cycles"*.

Both questions are answerable from the scan loop in the test source, and should
be settled there rather than fitted to whatever our ANTIC happens to do.
`tools/acid800_dmatable.py` therefore emits the **raw** bytes
(`emu/acid_dmatable.h`) so no guess is baked into the data.

The mode byte is the display-list instruction, so it encodes more than the mode
number — e.g. `$08` vs `$09` (the same mode with and without DLI/scroll bits)
have visibly different patterns, and `$28`/`$2c` (VSCROL set) differ from
`$20`/`$24`.

Reading the table directly is the fastest way to get ANTIC's DMA right; it is
the thing this project has been inferring one hypothesis at a time.

## How it measures, in the author's own words

The header comment is unusually generous and worth reading in full in the
source. The essentials:

> *"What we're trying to do is determine which cycles are blocked by ANTIC DMA
> during a scan line. However, the CPU can't monitor this directly since it's
> halted, and there isn't a convenient and reliable cycle timer on the A8.
> High-speed POTs almost work for this but have a glitch in HBLANK. Therefore,
> we use trusty RANDOM instead."*

The machinery:

1. **9-bit LFSR mode** (`mva #$80 audctl`). In 9-bit mode nearly the whole LFSR
   is readable through `RANDOM` — but one bit short, so a single sample is
   ambiguous between two positions.
2. **Disambiguate with a second sample exactly 114 cycles later** (one
   scanline). Three generated tables do the lookup: `lfsrtab` (RANDOM values in
   cycle order, 511 entries), and `lfsrlo/hi0` + `lfsrlo/hi1` (one-based index
   given a RANDOM value, assuming the missing high bit is 0 or 1).
3. **Seven skewed passes.** The 6502 can sample `RANDOM` at best once every 7
   cycles, so seven passes each offset by one cycle cover every cycle of the
   line.
4. **Walk the mask and the LFSR sequence in parallel**, counting off the
   *unhalted* cycles. The author notes you cannot simply search the sequence,
   because every value except `00` occurs twice and the duplicates are sometimes
   adjacent (`FF FF` appears).

50 mode/width combinations × 7 passes, four passes per frame, ~1.5 s total.

## Why this one is hard to fake

The measurement is of *when the CPU was allowed to run*, sampled at one-cycle
resolution, against a table that specifies every cycle. There is no partial
credit and no way to pass it with an approximate DMA model: a single
misallocated cycle in any mode names that mode in the failure message.

## To pass this test you must have

1. A cycle-exact **9-bit** POKEY LFSR (`AUDCTL` bit 7), readable through
   `RANDOM` — the 17-bit mode is not enough here.
2. Per-mode, per-width DMA cycle allocation matching the `testdata` masks —
   including the difference the display-list instruction's option bits make.
3. Correct DMA for the display-list fetch and the character-name vs
   character-data fetches, since those are what the masks are made of.
4. `/RDY` halting the CPU on exactly those cycles and no others.

## Note for the software ANTIC

Because `testdata` is the specification in machine-readable form, it is worth
**parsing this table directly into a test fixture** rather than reimplementing
the whole 6502-side measurement: load the masks, run the software ANTIC for a
scanline in each mode, and compare the blocked-cycle set. That gives the same
coverage as the real test with none of the LFSR decoding, and it can run in
milliseconds on the host as a unit test — with the real `.xex` kept as the
end-to-end check.
