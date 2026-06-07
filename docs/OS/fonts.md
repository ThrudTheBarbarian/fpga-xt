# Fonts: variable fonts, the catalog, and the registry

## Goal

Ship a useful range of typefaces from a small number of files. The lever is
**variable fonts** (Google Fonts at <https://fonts.google.com>, filtered to
"variable"): a single TTF carries many weights, widths, and slants as a
continuous design space, plus a set of *named instances* that pick out the
familiar ones. One file becomes many selectable fonts.

`tools/fontscan.c` (the host prototype, `make -C gem fontscan`) proves the query
path against real files. Roboto, for example, is one 489 KB file exposing:

```
  family   : Roboto      variable : yes
  axes (2):  wght 100..400..900   wdth 75..100..100
  named instances (18):
     Thin .. Regular .. Black            (wght 100..900, wdth 100)
     Condensed Thin .. Condensed Black   (wght 100..900, wdth 75)
```

Roboto Flex (1.79 MB) carries 13 axes — `wght` (to 1000), `wdth` (25..151),
`slnt` (0..−10), `opsz`, and parametric axes (`XOPQ`, `XTRA`, …) — and 20 named
instances including the italics, which it expresses as `slnt = −10` rather than
an `ital` toggle.

## What the font tells us (so the filename doesn't have to)

Everything we need is queryable through FreeType, so **the filename encodes only
the family** — never the traits:

| Want | Source |
|------|--------|
| Is it variable? | `FT_HAS_MULTIPLE_MASTERS(face)` / `FT_Get_MM_Var()` |
| Family name | `face->family_name` (`name` table) |
| Axes + ranges | `FT_MM_Var.axis[]` → tag (`wght`/`wdth`/`slnt`/`ital`/`opsz`/…), min/def/max (16.16) |
| The selectable list | `FT_MM_Var.namedstyle[]` → per-axis design coords + a name (`strid` → `name` table) |
| Static style (non-VF) | `face->style_name`, `face->style_flags` (BOLD/ITALIC) |

Encoding traits in the filename is redundant, can drift from the truth, and is
meaningless for the variable case (a variable Roboto has no single weight). So:

**Filename convention:** `Family+Name.ttf` — spaces become `+` for shell/path
ergonomics, nothing else. (Keeping the original Google filename is also fine; the
`name` table is authoritative either way.) Filenames are cp437/ASCII (the FatFs
build has `FF_LFN_UNICODE=0`), so non-Latin family names live only in the font's
`name` table, not the filename.

## Three distinct things — keep them separate

- **Catalog** — metadata for *every* instance of every font: `{family, file,
  isVariable, axes[], instances[]{name, coords[]}}`. Small, always resident,
  **persisted to disk** so boot doesn't re-parse fonts. This is what the chooser
  and `vst_name`/`vst_font` resolve against, and what the effect path consults to
  decide real-master vs synthetic.
- **Registry** — the live `(file, coords) → FT_Face` map. Each instance is opened
  lazily on first use via a dedicated `FT_New_Face` (one `FT_Face` per instance),
  deduped so a given instance opens at most once. **It never evicts** — there is
  no LRU. The resident set therefore tracks fonts actually *drawn with* (a handful
  to low tens in a session), each ~file-sized (200–600 KB typical, ~1.7 MB for
  Roboto Flex). On the A9's RAM that is noise, and dropping eviction removes the
  dangling-`font*` hazard entirely. (If a hard bound ever matters, it's an
  additive change at the registry, not a redesign.)
- **Glyph cache** — the existing per-`font` rasterised-coverage cache, released by
  `font_face_flush` / `v_flushcache`. Independent of the registry; this is the
  memory-pressure release valve, not the faces.

Registry ≠ cache: the registry is about identity and lifetime; a cache is about
discardable acceleration. They are not the same concept and are not managed the
same way.

## Boot: skip the parse when nothing changed (no RTC)

There is no on-board RTC, so file mtimes are unusable. Instead, validate the
persisted catalog against a cheap hash of the directory:

1. `f_readdir` over `OS/Fonts/` collecting `(name, fsize)` for each `*.ttf`
   (`fsize` comes free from the readdir `FILINFO` — no file opens).
2. Sort the entries (readdir order isn't stable) and CRC32 the `name:size` list.
   Including size catches a same-name content swap, which a names-only hash would
   miss with no clock to fall back on.
3. Read the index file. If `format_version` and `freetype_major` match and the
   stored hash equals the computed hash → **load the catalog records, parse zero
   fonts.** Otherwise rebuild: parse every font, write the index (temp file +
   rename, or a validity trailer written last, so a power cut can't leave a
   half-index that gets trusted).

The catalog is always reconstructible; the index file is an optimization, never a
source of truth. A missing/corrupt/version-mismatched index just forces a
rebuild. Requires a writable `OS/Fonts` (degrades to "always parse" if read-only).

## Selecting an instance

A logical face is `(file, coords)`. `vst_font` (by id) and `vst_name` (by family)
resolve to one through the catalog, and the registry instantiates it. Set the
variation with `FT_Set_Var_Design_Coordinates(face, n, coords)` (or
`FT_Set_Named_Instance(face, idx)` — 1-based) at open time; because each instance
has its own `FT_Face`, the coords are set once and stay put.

Store the **coordinates** in the catalog (not just the named-instance index):
self-contained, and free of any coupling to the font's internal instance
ordering. The chooser's menu is the named-instance list; an advanced chooser can
expose sliders for the user-facing axes (`wght`, `wdth`, `slnt`, `opsz`) while
hiding parametric ones (FreeType can flag hidden axes via
`FT_Get_Var_Axis_Flags`).

## Real masters beat synthetic effects

Today `FX_BOLD` emboldens the outline and italic is a shear. When the family has
the axis, prefer the **real master** instead:

- bold → the `wght = 700` instance (or the next heavier named instance);
- italic → the `ital = 1` *or* `slnt` axis (Roboto Flex uses `slnt = −10`; check
  both);
- condensed/expanded → the `wdth` axis.

Fall back to the synthetic path only when the axis is absent. The decision is a
pure catalog lookup ("does this family have a `wght` axis?"), no font parse.

This composes for free with the PDF printer: M3 renders text as glyph *outlines*
(`font_get_outline`), so a variable instance simply yields different outline
coordinates — the printer needs no changes to gain real weights/widths.

## Open items

- Confirm the **xilffs** (SD) BSP config also has `FF_USE_LFN` / `FF_MAX_LFN=255`
  (the tinyusb FatFs copy does); long names on the card depend on it.
- `opsz` should ideally track the render pixel size rather than its default.
- Catalog/index on-disk format (binary vs text) and location (`OS/Fonts/.index`?).
- Wire the registry into the existing `font_face`/`font` model (one `FT_Face` per
  instance; `vst_font`/`vst_name` → catalog → registry).
- A Font Chooser UI (named instances as the menu; sliders later).
