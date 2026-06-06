---
title: "VDI reference"
description: "The supported GEM VDI calls — control, output, attributes, raster, inquiry, input, and the NVDI/FSM extensions."
---

The VDI is the drawing layer. Opcodes are the standard GEM ones; GDP sub-opcodes are written
`11.n`. Every primitive is clipped to the workstation's clip rectangle. The device is
true-colour (RGBA-8888); see the [GEM overview](/os/gem/) for how applications detect that.

## Control

| Call | Op | Notes |
|------|----|-------|
| `v_opnwk` | 1 | open a physical device. id 1–10 = screen; 31–40 = metafile; 21–30 (printer) reserved for the planned PDF device |
| `v_clswk` | 2 | close a physical workstation (finalises a metafile) |
| `v_clrwk` | 3 | clear the workstation to pen 0 |
| `v_updwk` | 4 | flush (a no-op for the screen; the PDF device will flush a page) |
| `v_opnvwk` | 100 | open a virtual workstation (16 slots; handle 1 = the physical screen) |
| `v_clsvwk` | 101 | close a virtual workstation |
| `vq_extnd` | 102 | extended inquiry; reports true colour (`work_out[5]==0`, 32 planes) and arbitrary text rotation |
| `vs_clip` | 129 | per-workstation clip rectangle; honoured by every primitive |
| `vst_load_fonts` | 119 | map `OS/Fonts` files to ids 2…N (opened on first use); returns the count |
| `vst_unload_fonts` | 120 | no-op (faces are cheap and kept) |

The device mechanism is driver-based, so adding a device is a driver behind `v_opnwk`. The
**metafile** device (id 31–40) records subsequent calls to a `.gem` file and replays them onto
any workstation; raster copies are inlined into the record so images survive replay.

## Output

| Call | Op | Notes |
|------|----|-------|
| `v_pline` | 6 | polyline; Cohen–Sutherland clipped, width + dash, end styles |
| `v_gtext` | 8 | graphic text; FreeType, UTF-8, sized / aligned / rotated / effected |
| `v_fillarea` | 9 | filled polygon (even-odd, pattern-masked) |
| `v_cellarray` | 10 | grid of coloured cells scaled into a rectangle |
| `v_contourfill` | 103 | 4-connected seed fill (boundary or seed-colour) |
| `v_bar` | 11.1 | filled rectangle |
| `v_arc` | 11.2 | circular arc (line colour) |
| `v_pieslice` | 11.3 | filled pie slice |
| `v_circle` | 11.4 | filled circle |
| `v_ellipse` | 11.5 | filled ellipse |
| `v_ellarc` | 11.6 | elliptical arc |
| `v_ellpie` | 11.7 | filled elliptical pie |
| `v_rbox` | 11.8 | rounded-rectangle outline |
| `v_rfbox` | 11.9 | filled rounded rectangle |
| `v_justified` | 11.10 | text spread to a width (word and/or character spacing) |
| `v_pmarker` | 7 | polymarkers (dot, plus, asterisk, square, cross, diamond) |
| `vr_recfl` | 114 | fill rectangle (honours interior / style / perimeter) |

Curves are adaptively segmented, so arcs and rounded boxes stay smooth at any size or line
width. The line pen is round, giving uniform thickness at every angle, and dash phase is
distance-projected so dashes don't "walk" as a line rotates.

## Attributes

| Call | Op | Notes |
|------|----|-------|
| `vs_color` | 14 | set a palette pen (RGB 0–1000) |
| `vsl_type` | 15 | line type 1 (solid) … 6, 7 = user (`vsl_udsty`) |
| `vsl_width` | 16 | line width (round pen) |
| `vsl_color` | 17 | line colour |
| `vsl_ends` | 108 | end styles: square (flat) / arrow / round, per end |
| `vsl_udsty` | 113 | user-defined 16-bit dash mask (used by line type 7) |
| `vsm_type` / `vsm_height` / `vsm_color` | 18 / 19 / 20 | marker type / size / colour |
| `vst_height` | 12 | text size in pixels |
| `vst_point` | 107 | text size in points (72 dpi ⇒ 1pt = 1px) |
| `vst_color` | 22 | text colour |
| `vst_rotation` | 13 | text baseline angle, any angle (1/10°, CCW) |
| `vst_effects` | 106 | bold / light / italic / underline / outline / shadow (combinable) |
| `vst_alignment` | 39 | horizontal (left/centre/right) + vertical anchor |
| `vst_font` | 21 | select a face by id (1 = system; 2…N from `OS/Fonts`, opened on first use) |
| `vsf_interior` | 23 | hollow / solid / pattern / hatch / user |
| `vsf_style` | 24 | fill style index (24 patterns + 12 hatches) |
| `vsf_color` | 25 | fill colour |
| `vsf_perimeter` | 104 | outline filled areas |
| `vsf_udpat` | 112 | user-defined 16×16 fill pattern |
| `vswr_mode` | 32 | writing mode: replace / transparent / XOR / reverse-transparent |

### Extended attributes (NVDI / FSM)

| Call | Op | Notes |
|------|----|-------|
| `vst_arbpt` / `vst_arbpt32` | 246 | arbitrary point size (the 32-bit form takes 16.16) |
| `vst_setsize` / `vst_setsize32` | 252 | character width independent of height (condensed / expanded) |
| `vst_width` | 231 | character width in pixels |
| `vst_skew` | 253 | arbitrary text shear angle |
| `vst_kern` | 237 | pair kerning (engages only if the face has a kern table) |
| `vst_track_offset` | 237 | uniform letter-spacing |
| `vst_charmap` / `vst_map_mode` | 236 | character-set mapping — Unicode-native, so reports Unicode |
| `vst_fg_color` / `vst_bg_color` | 200 / 201 | text foreground / opaque-text background pen |
| `vst_name` | 230 | select a face by family name |
| `v_setrgb` | 138 | set a pen directly from 8-bit RGB |
| `vsf_xperimeter` | 104 | perimeter drawn with the current line style |
| `v_bez` / `v_bez_fill` | 6.13 / 9.13 | Bézier path stroke / fill (adaptive flattening) |
| `v_bez_qual` | 5.99 | Bézier flattening quality (0–100 %) |
| `v_bez_on` / `v_bez_off` | 11.13 | enable / query Bézier capability |

## Raster

| Call | Op | Notes |
|------|----|-------|
| `vro_cpyfm` | 109 | opaque raster copy (device-format MFDB) |
| `vrt_cpyfm` | 121 | colour a 1-bpp source (fg/bg pens) honouring the writing mode |
| `vr_trnfm` | 110 | standard (planar) ↔ device (RGBA chunky) conversion via the palette |
| `v_get_pixel` | 105 | read back the matching palette pen (−1 if no match) |
| `vr_transfer_bits` | 170 | scaled bitmap combine — logic ops, plus extended blends (alpha src-over, additive, subtractive, weighted, highlight) |
| `vr_clip_rects_by_dst` / `_by_src` | 171 | clip a transfer rect pair (and the 32-bit forms) |
| `vs_hilite/min/max/weight_color` | 207 | the colours driving the extended raster blends |
| `vq_hilite/min/max/weight_color` | 209 | read those colours back |

`vr_transfer_bits` is the compositor's scale-and-blend primitive: it does the nearest-neighbour
scaling for window content and the per-pixel alpha compositing the theme engine needs.

## Inquiry

| Call | Op | Notes |
|------|----|-------|
| `vq_color` | 26 | read back a pen (RGB 0–1000) |
| `vql_attributes` / `vqm_` / `vqf_` / `vqt_attributes` | 35–38 | current line / marker / fill / text attributes |
| `vqt_extent` | 116 | text bounding box (4 corners; size / effects / rotation aware) |
| `vqt_width` | 117 | one character's cell width + bearings |
| `vqt_name` | 130 | a font's id + name (enumerate to build a font menu) |
| `vqt_fontinfo` | 131 | structural metrics: char range + the five baseline-relative distances |
| `vqt_f_extent` | 240 | fractional text extent (summed without per-glyph rounding) |
| `vqt_real_extent` | 240.4200 | the tight *inked* bounding box |
| `vqt_advance` / `vqt_advance32` | 247 | sub-pixel character advance (integer + 1/65536, or 16.16) |
| `vqt_pairkern` | 235 | pair-kern delta for two characters |
| `vqt_trackkern` | 234 | track-kerning offset |
| `vqt_justified` | 132 | the per-character offsets a justified line would use |
| `vqt_name_and_id` | 230.100 | look up a font id + canonical name by name |
| `vqt_ext_name` | 130.1 | name + format / classification flags |
| `vqt_char_index` | 190 | encoding map (Unicode-native ⇒ identity) |
| `vq_scrninfo` | 102.1 | screen pixel format (direct RGBA-8888: bpp + per-channel bits/shifts) |
| `vq_cellarray` | 27 | read a region back as a grid of pen indices |

## Input

Input devices read a host-fed state (the SDL backend on the host, the AES event pump on
hardware). Each device has two modes (`vsin_mode`): **request** blocks until the device fires,
**sample** returns the current state at once.

| Call | Op | Notes |
|------|----|-------|
| `vsin_mode` | 33 | request / sample per device class |
| `vrq_locator` / `vsm_locator` | 28 | pointer position + terminator |
| `vrq_valuator` / `vsm_valuator` | 29 | a scalar input (dial / wheel) |
| `vrq_choice` / `vsm_choice` | 30 | a numbered selection |
| `vrq_string` / `vsm_string` | 31 | a typed line |
| `v_show_c` / `v_hide_c` | 122 / 123 | pointer visibility (hide nests) |
| `vq_mouse` | 124 | pointer position + button mask |
| `vq_key_s` | 128 | keyboard shift / ctrl / alt state |
| `vex_butv` / `vex_motv` / `vex_curv` / `vex_timv` | 125–127 / 118 | exchange an input-interrupt vector |
| `vex_wheelv` | 134 | mouse-wheel handler |
| `vsc_form` | 111 | set the mouse-pointer shape (16×16 mono cursor) |

## NVDI control extensions

| Call | Op | Notes |
|------|----|-------|
| `v_opnbm` / `v_clsbm` | 100.1 / 101.1 | open / close an off-screen bitmap as a workstation |
| `v_open_bm` | 100.3 | modern open-bitmap variant |
| `v_resize_bm` | 100.2 | re-point a bitmap workstation at a new MFDB |
| `v_getoutline` / `v_get_outline` | 243 | a glyph's outline as a Bézier path (round-trips through `v_bez`) |
| `v_killoutline` | 242 | free an outline (a no-op — outlines are written to the caller's arrays) |
| `v_flushcache` | 251 | drop the rasterised glyph cache |
