---
title: "Theming"
description: "The 9-slice theme engine and on-disk theme format that dress every GEM widget — a baked RGBA atlas, slice table, and colours."
---

Every AES widget is drawn from a **theme** — a bitmap atlas plus a table of named slices —
rather than from hard-coded lines. The reference theme is derived from Cappuccino's *Aristo2*,
giving the desktop a modern Aqua-style look. Applications never reference the theme directly;
they create [AES](/os/gem/aes/) objects and the theme is applied for them.

## 9-slice rendering

Almost every widget is a **9-slice** (nine-patch): four fixed corners, four edges stretched
along one axis, and a centre stretched both ways. A window, button, text field, scrollbar
track and menu are all 9-slice (or its degenerate cases — a 3-slice strip, or a single
sprite). Corners stay 1:1 at any size, so a button scales cleanly to any label width.

The renderer is `theme_blit`, which issues the nine sub-blits through
[`vr_transfer_bits`](/os/gem/vdi/#raster) in its `VR_OVER` (per-pixel src-over alpha) mode — so
the artwork's anti-aliased edges and soft shadows composite correctly. `theme_draw(name, rect)`
looks a slice up by name and blits it; that is the single call the AES uses to render a widget.

## On-disk format

A theme lives in `OS/Themes/<name>/<scale>/` (the `<scale>` directory leaves room for a `@2x`
high-DPI set later):

- **`artwork.tex`** — a raw RGBA-8888 atlas (`GTEX` header + width/height + pixel rows). It is
  **baked from PNGs ahead of time**, so the target needs no PNG decoder at runtime; the atlas
  loads straight into an off-screen bitmap workstation.
- **`locations.txt`** — one line per slice: `name  x y w h  l t r b  fill`, where `x y w h` is
  the slice's rectangle in the atlas, `l t r b` the 9-slice insets, and `fill` is
  `stretch` / `tile` / `none`.
- **`theme.ini`** — the colours (`fg`, `highlight`, `sel_bg`, `border`, `disabled`), since those
  come from the theme's descriptor, not the artwork.

## Baking a theme

The host tool `themepack` builds the atlas from a recipe. Each recipe line names an element, a
type, and its source PNGs:

```text
window    nine    window-standard-top-left … window-standard-bottom-right
button    h3      button-bezel-left button-bezel-center button-bezel-right
close     sprite  window-standard-close-button
```

- **Types** — `sprite` (1 image), `h3` (left / centre / right), `v3` (top / centre / bottom),
  `nine` (the nine corners/edges/centre).
- The 9-slice **insets are derived automatically** from the corner slice sizes.
- A source token can carry a suffix: **`@90/180/270`** rotates the slice (the vertical
  scrollbar reuses the date-picker arrows rotated), **`~N`** trims N px from the centre of a
  strip (narrowing a track to its arrows), and **`^RRGGBB`** colour-tints a slice (the blue
  default button is the grey bezel tinted).

`themepack` decodes the PNGs (via ImageMagick on the host), composes each element, packs them
into one atlas, and writes the three files above. Adding a widget is a recipe line, not code.

## Widget coverage

The reference theme covers: the window frame + titlebar (active / inactive) + traffic-light
controls; push buttons (normal / default / pressed / disabled); checkboxes (off / on / mixed)
and radio buttons; popups, combos and text fields (with focused / disabled states); menus +
tick mark; sliders (horizontal / vertical / circular); scrollbars (both axes, track + thumb +
arrows); steppers; the table header; and the alert icons.
