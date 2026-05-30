# Debug images from sim runs

Every testbench that drives the compositor dumps a binary PPM (P6) of the
resulting framebuffer into this directory at end-of-test. Filenames are
`<tb>_<phase>.ppm`. Run `make` from `sim/` to regenerate; `make clean`
deletes them.

## Palette (debug, not Atari-accurate)

`idx_buf` is the per-pixel layered index emitted by the compositor.
Highest set bit wins in this palette — players over playfield, with
distinct hues per layer for "where is each layer?" inspection. Real
Atari color resolution (PRIOR + COLPMx + COLPFx) lands in M10.

| Bit | Source | Color   |
|-----|--------|---------|
| 7   | P3     | magenta |
| 6   | P2     | pink    |
| 5   | P1     | yellow  |
| 4   | P0     | red     |
| 3   | PF3    | orange  |
| 2   | PF2    | green   |
| 1   | PF1    | cyan    |
| 0   | PF0    | blue    |
| —   | bg     | dark gray |

## Stretching

Width is always 1:1 (one image px per atari px → 320 wide for full
displays) so the geometry stays recognizable; only the height is
replicated by `vstretch` to keep short tests legible. Defaults: 3x
vstretch for tests producing many rows (mode_f, pm), 3x for the
8-row char/gfx tests. View with `open foo.ppm` and let the viewer
zoom.

## Format

PPM P6 (binary): three header lines (`P6`, `<W> <H>`, `255`) followed by
raw `R G B` triples. Open in any image viewer (`open foo.ppm` on macOS,
`feh`/`gimp`/`xdg-open` on Linux). For thumbnails in a terminal,
`chafa visual/*.ppm`.
