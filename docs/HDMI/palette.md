# Palette LUT — NTSC / PAL switching

## What the LUT stores

`hdl/palette_lut.sv` is a 256-entry × 24-bit RAM. The address is the
8-bit Atari hue:luma value coming out of `color_resolver`
(bits[7:4] = hue 0..15, bits[3:1] = luma 0..7, bit[0] mirrors luma's
LSB and is otherwise ignored). The data is straight RGB888.

The TMDS / DVI scan-out path reads `palette_lut[resolved_color]` once
per pixel-clock and feeds the 24-bit result into the encoder.

## Why two reference palettes

Atari's NTSC and PAL hardware encode the colour-burst phase
differently. The hue → carrier-phase mapping is rotated, the
saturation is slightly different, and PAL's alternating-line phase
reversal kills the chroma-distortion issue NTSC has. Result: the same
hue:luma byte produces *visibly different* colours on a real NTSC vs
PAL Atari. Programs that target one region picked their hue values
to look right under that region's palette.

To stay colour-accurate, we need both reference palettes available.

## Two ways to load

The LUT is fully writeable at runtime via the chiplet-ext registers:

```
$D483 PAL_R    write red byte
$D484 PAL_G    write green byte
$D485 PAL_B    write blue byte
$D486 PAL_IDX  write 8-bit Atari index — commits {R,G,B} into entry IDX
```

Two delivery options for the boot defaults:

1. **Synth-time bake-in.** Pass `INIT_FILE` to `palette_lut`:

   ```
   palette_lut #(.INIT_FILE("hdl/palette/atari_ntsc.hex")) u_lut (...);
   ```

   Two reference tables ship in the repo:
   - `hdl/palette/atari_ntsc.hex` — NTSC-shaped colour wheel
   - `hdl/palette/atari_pal.hex`  — PAL-shaped colour wheel

   Pick whichever matches the dominant target region. The other one
   ships in firmware as a 768-byte blob and gets paged in via the
   chiplet-ext writes when the user toggles region.

2. **Pure firmware-driven.** Leave `INIT_FILE` empty (LUT comes up
   black at /G_RST), and have the RP2354 firmware push 256 entries
   via SET writes to $D483-$D486 during the cold-boot sequence.
   Region toggle = re-push the other table (≈ 1 ms at 1.79 MHz bus).

We default to the synth-time bake-in since it gives a sensible
power-on display before any RP firmware has loaded.

## File format

`atari_ntsc.hex` / `atari_pal.hex` are plain `$readmemh`-compatible
hex files: 256 lines, one 24-bit RGB888 per line, MSB = R, LSB = B.
Header lines (`//`) are tolerated by `$readmemh` so the files are
self-documenting.

The two reference tables in this repo are **derived approximations**
based on the NTSC and PAL hue-rotation tables widely quoted in the
Atari hardware manuals + Altirra. They aren't claimed to be
pixel-exact reproductions of any specific real silicon's analogue
colour-burst output — the chiplet-ext write path lets you replace
them with whatever your favourite reference says.
