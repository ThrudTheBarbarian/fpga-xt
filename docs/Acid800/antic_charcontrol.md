# antic_charcontrol — ANTIC: Character control

**Pins down:** the `CHACTL` (`$D401`) character-control bits — invert, blank
(blink) and reflect — across character modes 2 and 3, including mode 3's
descender rows.

Source: [`src/antic_charcontrol.s`](src/antic_charcontrol.s). The largest ANTIC
test source (726 lines), asserting by control flow over a large matrix.

## The matrix

`CHBASE` is set to `$2c` and the test sweeps `CHACTL` settings:

| pass | `CHACTL` |
|---|---|
| 1 | all off |
| 2 | invert on |
| 3 | blink on |
| 4 | reflect on |

and within each, checks a repeating group of cases:

* **mode 2 inverted** — the inverse-video character range in mode 2
* **mode 3 inverted** — the same in mode 3
* **mode 3 inverted descender** — mode 3's lower-region rows, where characters
  `$60`–`$7F` are shifted down two scanlines

The mode-3 descender interaction is repeated in every pass, which is the hint
about where the difficulty is: mode 3 gives characters 8 rows of data out of a
10-scanline row, with the last two rows blank for most characters and used for
descenders on a subrange — and `CHACTL`'s invert/blank/reflect have to apply
correctly *through* that remapping.

## To pass this test you must have

1. `CHACTL` invert (bit 0), blank/blink (bit 1) and reflect (bit 2) applied to
   character data at the right stage.
2. Mode 2 and mode 3 inverse-video ranges handled per-mode.
3. **Mode 3 descenders**: the row-to-data mapping for characters `$60`–`$7F`,
   and `CHACTL` applied consistently across it.
4. `CHBASE` selecting the character set with the correct alignment per mode.

This one is breadth rather than depth — no single-cycle boundaries — but it is
the widest character-mode matrix in the suite, so it is the test that catches a
character generator that is right for the common case and wrong at the edges.
