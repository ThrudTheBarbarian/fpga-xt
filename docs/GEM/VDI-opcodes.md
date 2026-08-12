# VDI opcode wire format (v0.1)

This document specifies the wire format for VDI drawing commands flowing
from the FPGA's 6502 over PSSI to the N6 graphics co-processor, plus
the parallel set of VDI inquiry calls that flow over FMC RPC. It is
the protocol contract between the 6502-side xcc VDI library and the
N6-side DRAW dispatcher (see [n6-migration.md](./n6-migration.md) and
[GEM-implementation.md](./GEM-implementation.md) for surrounding
architecture).

The opcode inventory is taken from EmuTOS `vdi/vdi_main.c` (jumptables
`jmptb1` and `jmptb2`), with GDP sub-ops from `vdi_gdp.c` and escape
sub-ops from `vdi_esc.c`. Classic GEM VDI opcode numbers are preserved
1:1 — there is no remapping. EmuTOS is the canonical reference; FreeGEM
matches the same opcode numbering.

## Status

v0.1 — primary draft. Locked enough to start building. Reserved fields
and unimplemented opcodes can be defined later; existing encodings will
not change.

## Transport

Two transports carry VDI traffic, split by direction and nature:

| Class | Transport | Reason |
|-------|-----------|--------|
| **Drawing** (polyline, fill, blit, text, GDP, cursor show/hide, clip) | PSSI byte stream, FPGA → N6 | Bulk one-way, high bandwidth, no per-call response |
| **State setters** (color, line type/width/colour, fill style, write mode, palette load) | PSSI byte stream, FPGA → N6 | N6-side virtual workstation state; no response needed |
| **Inquiries** (vqt_extent, vq_color, vqt_fontinfo, vq_extnd, v_get_pixel, etc.) | FMC RPC mailboxes (0x01 W / 0x01 R) | Round-trip with data back to 6502 |
| **Workstation open / close** (v_opnwk, v_opnvwk, vq_extnd) | FMC RPC | Returns capability arrays |
| **Input bindings** (vex_butv, vex_motv, vex_curv, vex_timv) | FPGA-local; events flow back via SPI event channel | These install callbacks; events come back via the existing event path |
| **Console escape** (v_escape with sub-ops 2–14) | FPGA-local terminal emulator (VT-52) | Legacy alpha-mode I/O; doesn't touch N6 graphics path |

## PSSI packet framing

```
[opcode: u8] [params: implicitly sized by opcode]
```

- Stream of bytes. PSSI is 16-bit @ 80 MHz; the FPGA TX engine packs
  adjacent bytes into 16-bit transfers, padding with a NOP byte if the
  packet ends on an odd boundary.
- Each opcode has a known fixed parameter shape (per the table below).
  The N6 dispatcher reads the opcode, looks up the shape, consumes that
  many bytes, dispatches.
- Variable-length opcodes (polyline, polygon, gtext, fillarea) carry an
  explicit `count` field as the first parameter — the rest of the
  payload is `count` items of the documented item size.
- All multi-byte integers are **little-endian** (matches 6502 native).
- Coordinates are **16-bit signed**, native VDI convention. Sufficient
  for any target resolution up to ±32767 pixels.
- Colours on the wire are **8-bit indexed** for classic VDI ops. The N6
  expands indices to **RGB888** (24-bit, 3 bytes/pixel) via the active
  virtual-palette LUT when writing into its framebuffer, to match
  LVGL's `LV_COLOR_DEPTH 24` configuration. Extended drawing ops in the
  `0xC1–0xCF` range carry **direct RGB888 colour parameters** (3 bytes)
  for true-colour-aware apps — see [Extended-color
  opcodes](#extended-color-opcodes-v02-reserved).
- All `count` fields are unsigned 16-bit; a single VDI call can have up
  to 65535 vertices or characters.

### Special bytes

| Value | Meaning |
|------:|---------|
| `0x00` | NOP / padding. Dispatcher skips. Used for 16-bit-alignment padding. |
| `0xFF` | Reserved for future stream-resync marker. Currently treated as NOP. |

All other unrecognised opcodes are an error and should halt the
dispatcher with a stream-fault status flag set in the FMC status
mailbox.

## Opcode classification

The two EmuTOS jumptables define VDI opcodes 1–39 and 100–134. Each
column below indicates the transport class:

| **D** | Drawing — PSSI |
| **S** | State setter — PSSI |
| **I** | Inquiry — FMC RPC |
| **W** | Workstation control (open/close) — FMC RPC |
| **C** | Cursor control — PSSI |
| **B** | Input binding — FPGA-local (callback install) |
| **E** | Console escape — FPGA-local (VT-52) |
| **N** | Not implemented / out of scope |

### Low table (opcodes 1–39)

| Op | Class | Name | Parameters (input) | Wire payload (PSSI/RPC) |
|---:|:----:|------|-------|-------|
|  1 | W | v_opnwk | dev_id, default attrs | FMC RPC: returns 6 ptsout + 45 intout |
|  2 | W | v_clswk | — | FMC RPC, no payload |
|  3 | D | v_clrwk | — | PSSI: opcode only |
|  4 | N | v_updwk | — | Not implemented in EmuTOS; reserve op number |
|  5 | E | v_escape | sub-op + sub-params | FPGA-local; see [Escape sub-ops](#escape-sub-opcodes) |
|  6 | D | v_pline | n points | PSSI: `count_u16, (x_i16, y_i16) × n` |
|  7 | D | v_pmarker | n points | PSSI: `count_u16, (x_i16, y_i16) × n` |
|  8 | D | v_gtext | x, y, n chars | PSSI: `x_i16, y_i16, count_u16, char_u16 × n` |
|  9 | D | v_fillarea | n points | PSSI: `count_u16, (x_i16, y_i16) × n` |
| 10 | N | v_cellarray | — | Stub in EmuTOS; reserve op number |
| 11 | D | v_gdp | sub-op + params | PSSI: `subop_u8, params…` — see [GDP sub-ops](#gdp-sub-opcodes) |
| 12 | S/I | vst_height | height | PSSI: `height_i16`. Inquiry-style return (cell box) is FMC RPC |
| 13 | S/I | vst_rotation | angle | PSSI: `angle_i16` |
| 14 | S | vs_color | index, r, g, b | PSSI: `index_u8, r_u16, g_u16, b_u16` (palette load) |
| 15 | S | vsl_type | type | PSSI: `type_u8` |
| 16 | S | vsl_width | width | PSSI: `width_i16` |
| 17 | S | vsl_color | colour idx | PSSI: `idx_u8` |
| 18 | S | vsm_type | type | PSSI: `type_u8` |
| 19 | S | vsm_height | height | PSSI: `height_i16` |
| 20 | S | vsm_color | colour idx | PSSI: `idx_u8` |
| 21 | S | vst_font | font id | PSSI: `font_u16` |
| 22 | S | vst_color | colour idx | PSSI: `idx_u8` |
| 23 | S | vsf_interior | style | PSSI: `style_u8` |
| 24 | S | vsf_style | index | PSSI: `idx_u8` |
| 25 | S | vsf_color | colour idx | PSSI: `idx_u8` |
| 26 | I | vq_color | index, get_real | FMC RPC: returns 4 intout |
| 27 | N | vq_cellarray | — | Stub |
| 28 | B | v_locator | x, y | FPGA-local; sets locator origin; events via SPI |
| 29 | N | v_valuator | — | Stub |
| 30 | B | v_choice | — | FPGA-local; binding for choice input |
| 31 | B | v_string | — | FPGA-local; binding for string input |
| 32 | S | vswr_mode | mode | PSSI: `mode_u8` (1=replace, 2=transparent, 3=xor, 4=reverse-transparent) |
| 33 | B | vsin_mode | dev, mode | FPGA-local |
| 34 | — | reserved | — | Does not exist in VDI |
| 35 | I | vql_attributes | — | FMC RPC: returns 1 ptsout + 3 intout |
| 36 | I | vqm_attributes | — | FMC RPC: returns 1 ptsout + 3 intout |
| 37 | I | vqf_attributes | — | FMC RPC: returns 5 intout |
| 38 | I | vqt_attributes | — | FMC RPC: returns 2 ptsout + 6 intout |
| 39 | S/I | vst_alignment | h_align, v_align | PSSI: `h_u8, v_u8`. Inquiry return via FMC |

### High table (opcodes 100–134)

| Op | Class | Name | Parameters (input) | Wire payload (PSSI/RPC) |
|---:|:----:|------|-------|-------|
| 100 | W | v_opnvwk | default attrs | FMC RPC: returns 6 ptsout + 45 intout |
| 101 | W | v_clsvwk | — | FMC RPC, no payload |
| 102 | I | vq_extnd | extended_flag | FMC RPC: returns 6 ptsout + 45 intout |
| 103 | D | v_contourfill | x, y, search_colour | PSSI: `x_i16, y_i16, colour_u8` |
| 104 | S | vsf_perimeter | flag | PSSI: `flag_u8` |
| 105 | I | v_get_pixel | x, y | FMC RPC: returns 2 intout (pixel value + index). See [getpixel](./n6-migration.md#getpixel-latency-budget) |
| 106 | S | vst_effects | effect mask | PSSI: `mask_u8` |
| 107 | S/I | vst_point | size_pt | PSSI: `size_i16`. Inquiry return via FMC |
| 108 | S | vsl_ends | beg_style, end_style | PSSI: `beg_u8, end_u8` |
| 109 | D | vro_cpyfm | mode, src_xy, src_xy2, dst_xy, dst_xy2, src_form, dst_form | PSSI: see [blit encoding](#blit-encoding) |
| 110 | D | vr_trnfm | form | FMC RPC (data transfer through bulk mailbox 0x00 W/R) |
| 111 | C | vsc_form | form | PSSI: `form_data…` (16 words form + 16 words mask + hot-x + hot-y + bg/fg colours) |
| 112 | S | vsf_udpat | pattern | PSSI: `(pattern_u16 × 16)` + planes |
| 113 | S | vsl_udsty | style | PSSI: `style_u16` |
| 114 | D | vr_recfl | x1, y1, x2, y2 | PSSI: `x1_i16, y1_i16, x2_i16, y2_i16` (filled rectangle, current fill colour) |
| 115 | I | vqin_mode | dev | FMC RPC: returns 1 intout |
| 116 | I | vqt_extent | n chars | FMC RPC: returns 4 ptsout (bounding box) |
| 117 | I | vqt_width | char | FMC RPC: returns 3 ptsout + 1 intout |
| 118 | B | vex_timv | timer vector | FPGA-local; installs timer callback |
| 119 | D | vst_load_fonts | — | FMC RPC: returns 1 intout (font count loaded) |
| 120 | D | vst_unload_fonts | — | PSSI: opcode only |
| 121 | D | vrt_cpyfm | mode, src_xy, src_xy2, dst_xy, dst_xy2, src_form, dst_form, fg, bg | PSSI: see [blit encoding](#blit-encoding) |
| 122 | C | v_show_c | reset | PSSI: `reset_u8` |
| 123 | C | v_hide_c | — | PSSI: opcode only |
| 124 | I | vq_mouse | — | FMC RPC: returns 1 ptsout + 1 intout |
| 125 | B | vex_butv | vector | FPGA-local; binding |
| 126 | B | vex_motv | vector | FPGA-local; binding |
| 127 | B | vex_curv | vector | FPGA-local; binding |
| 128 | I | vq_key_s | — | FMC RPC: returns 1 intout |
| 129 | S | vs_clip | flag, x1, y1, x2, y2 | PSSI: `flag_u8, x1_i16, y1_i16, x2_i16, y2_i16` |
| 130 | I | vqt_name | element | FMC RPC: returns 33 intout (font name) |
| 131 | I | vqt_fontinfo | — | FMC RPC: returns 5 ptsout + 2 intout |
| 132 | N | vqt_justified | — | PC-GEM only |
| 133 | N | vs_grayoverride | — | PC-GEM/3 only |
| 134 | B | vex_wheelv / v_pat_rotate | — | Milan extension; FPGA-local binding |

## GDP sub-opcodes

Carried by opcode 11 with an 8-bit sub-opcode byte and primitive-specific params.

| Sub | Name | Wire payload after `[opcode=11][subop_u8]` |
|----:|------|-----|
|  1 | Bar (filled rect) | `x1_i16, y1_i16, x2_i16, y2_i16` |
|  2 | Arc | `xc, yc, radius, beg_angle, end_angle` (all `i16`) |
|  3 | Pieslice | same as Arc |
|  4 | Circle | `xc_i16, yc_i16, radius_i16` |
|  5 | Ellipse | `xc, yc, x_radius, y_radius` (all `i16`) |
|  6 | Elliptical arc | `xc, yc, x_rad, y_rad, beg_angle, end_angle` (all `i16`) |
|  7 | Elliptical pieslice | same as Elliptical arc |
|  8 | Rounded box | `x1, y1, x2, y2` (all `i16`) |
|  9 | Rounded filled box | same |
| 10 | Justified text | `x, y, length, count_u16, intermode_u8, charmode_u8, char_u16 × count` |
| 11–12 | reserved | — |
| 13 | Bezier curve | `count_u16, (x_i16, y_i16) × count` |

Sub-opcodes 0, 11, 12 unused — reserved for extension.

## Escape sub-opcodes

Carried by opcode 5 with an 8-bit sub-opcode byte. EmuTOS implements
sub-ops 0–19 plus 99 (bezier quality). Most escape sub-ops are
console / alpha-mode operations that are handled FPGA-local (VT-52
emulation), not forwarded to the N6.

| Sub | Name | Class | Wire |
|----:|------|:----:|-----|
|  0 | (stub) | — | nop |
|  1 | vq_chcells | I | FMC RPC: returns 2 intout (rows, cols) |
|  2 | v_exit_cur | E | FPGA-local |
|  3 | v_enter_cur | E | FPGA-local |
|  4–10 | cursor / clear ops | E | FPGA-local |
| 11 | vs_curaddress | E | FPGA-local: `row_u8, col_u8` |
| 12 | v_curtext | E | FPGA-local: `count_u16, char_u16 × n` |
| 13–14 | reverse video on/off | E | FPGA-local |
| 15 | vq_curaddress | I | FMC RPC: returns 2 intout |
| 16 | vq_tabstatus | I | FMC RPC: returns 1 intout |
| 17 | v_hardcopy | E | FPGA-local; calls Scrdmp |
| 18 | v_dspcur | C | PSSI: opcode 5, sub 18 — same as v_show_c |
| 19 | v_rmcur | C | PSSI: opcode 5, sub 19 — same as v_hide_c |
| 99 | v_bez_qual | S | PSSI: `quality_u8` (sets Bezier subdivision depth) |

## Blit encoding

Both raster-copy primitives (`vro_cpyfm`, `vrt_cpyfm`) carry similar
geometry but `vrt_cpyfm` adds fg/bg colour bytes for monochrome-source
blits.

`vro_cpyfm` (op 109):
```
opcode=109, mode_u8,
sx1_i16, sy1_i16, sx2_i16, sy2_i16,        // source rect (8 bytes)
dx1_i16, dy1_i16, dx2_i16, dy2_i16,        // dest rect (8 bytes)
src_form_id_u16,                            // form handle (8 KB shared on N6, or 0 = screen)
dst_form_id_u16                             // dest form (0 = screen)
```
Total: 22 bytes after opcode.

`vrt_cpyfm` (op 121) adds two bytes:
```
opcode=121, mode_u8, sx1..dst_form (as above),
fg_idx_u8, bg_idx_u8
```
Total: 24 bytes after opcode.

The `form_id` field is an N6-side handle into a registered form cache.
Forms are pre-registered via an FMC RPC ("form_create" returning a
handle), pixel data uploaded via the 0x00 W bulk mailbox.

## State setters and the virtual workstation

State opcodes (line type, fill style, colours, write mode, clip rect)
update the N6-side virtual workstation (Vwk) for the current handle.
Each PSSI packet implicitly targets the currently-bound workstation —
there is one "active" Vwk per stream, switched by a bind opcode at the
start of any drawing burst from a new task.

### Workstation binding (extension opcode)

| Op | Class | Name | Wire |
|---:|:----:|------|-----|
| 0xC0 | S | bind_workstation | `handle_u16` |

When a 6502 task wants to draw, it first emits a `bind_workstation`
packet to set the active Vwk on the N6 side. Subsequent drawing /
state-setter ops apply to that workstation until another bind.

The extension space `0xC0–0xFE` is reserved for protocol extensions
beyond the classic VDI numbering.

### Extended-color opcodes (v0.2, reserved)

Classic VDI is indexed-colour: drawing ops reference an 8-bit palette
index, expanded by the N6 to RGB888 at draw time. For apps that need
direct RGB control (image viewers, paint programs, modern UIs with
gradients), the wire format reserves `0xC1–0xCF` for **RGB-direct
variants** of the common drawing primitives. Each variant takes a
3-byte RGB888 colour parameter in place of the 1-byte palette index;
otherwise the parameter layout matches the indexed sibling.

This is the same separation [fVDI](https://web.archive.org/web/*/http://drac.atari.org/) uses internally —
classic apps continue to talk indexed; true-colour-aware apps use the
RGB-direct path. The two coexist; nothing changes about the indexed
opcodes when these are added.

| Op | Class | Name | Indexed sibling | Wire payload (RGB colour 3 B) |
|---:|:----:|------|----------------:|-----|
| 0xC1 | D | v_pline_rgb | 6 | `r_u8, g_u8, b_u8, count_u16, (x_i16, y_i16) × n` |
| 0xC2 | D | v_pmarker_rgb | 7 | `r_u8, g_u8, b_u8, count_u16, (x_i16, y_i16) × n` |
| 0xC3 | D | v_gtext_rgb | 8 | `r_u8, g_u8, b_u8, x_i16, y_i16, count_u16, char_u16 × n` |
| 0xC4 | D | v_fillarea_rgb | 9 | `r_u8, g_u8, b_u8, count_u16, (x_i16, y_i16) × n` |
| 0xC5 | D | v_recfl_rgb | 114 | `r_u8, g_u8, b_u8, x1_i16, y1_i16, x2_i16, y2_i16` |
| 0xC6 | D | v_gdp_rgb | 11 | `r_u8, g_u8, b_u8, subop_u8, params…` (GDP sub-op with RGB colour) |
| 0xC7 | D | v_contourfill_rgb | 103 | `r_u8, g_u8, b_u8, x_i16, y_i16, search_r_u8, search_g_u8, search_b_u8` |
| 0xC8–0xCF | reserved | — | — | Future RGB-direct ops as identified |

Capability discovery: `vq_extnd` (op 102) reports the workstation's
colour depth and a `supports_rgb_direct` flag. Apps that read the flag
can branch to the RGB-direct path; apps that don't, get the indexed
path and the virtual-palette expansion the N6 always does. v0.1
implementations may stub the RGB ops as "fall through to indexed"
(quantise RGB → nearest palette entry) until the 24-bit path is
implemented.

## Inquiry / RPC mailbox format

Inquiries flow through the FMC RPC mailboxes (0x01 W from N6, 0x01 R
into N6), not PSSI. The 6502 writes a request packet to the 0x01 R FIFO (from
the FPGA's perspective; from the N6's it's the request FIFO it reads
from), waits for the FPGA→N6 IRQ to clear, then reads the response from
the 0x01 W FIFO.

Request packet:
```
[opcode_u8] [vwk_handle_u16] [request-specific params…]
```

Response packet (format is opcode-specific; sizes documented in the
[Opcode classification](#opcode-classification) tables above):
```
[count_u16] [count items of response-specific layout]
```

Inquiry handlers on the N6 side share virtual-workstation state with
the PSSI dispatcher — the request includes the workstation handle so
the right Vwk is queried.

## Worked encoding examples

### Drawing a line from (10, 20) to (100, 80)

```
v_pline with 2 points, line colour previously set
Wire: 06 02 00 0A 00 14 00 64 00 50 00
        ^  ^---^ ^---^ ^---^ ^---^ ^---^
        |  count=2 x=10  y=20  x=100 y=80
        opcode=6
```
Total: 11 bytes (5.5 PSSI cycles at 16 bits per cycle).

### Setting fill colour to palette index 3

```
opcode 25 (vsf_color), 1 byte payload
Wire: 19 03
```
Total: 2 bytes (1 PSSI cycle).

### Filled rectangle (0,0)–(639,479)

```
opcode 114 (vr_recfl)
Wire: 72 00 00 00 00 7F 02 DF 01
        ^  ^---^ ^---^ ^---^ ^---^
        |  x1=0  y1=0  x2=639 y2=479
        opcode=0x72
```
Total: 9 bytes (4.5 PSSI cycles).

### Polyline of 100 points

```
opcode 6, count=100, then 400 bytes of (x,y) pairs
Wire: 06 64 00 [400 bytes of vertex data]
```
Total: 403 bytes (~202 PSSI cycles ≈ 2.5 µs at 80 MHz).

### Drawing 1000 such polylines per frame at 60 Hz

```
1000 × 403 B = 403 KB / frame = 24 MB/s
PSSI sustained: ~150 MB/s → 16% utilization
```
Plenty of headroom for typical AES draw loads.

## Versioning

This document is **v0.1**. Reserved opcodes (`0xC0–0xFE` extension
space, GDP sub-op 0/11/12, escape sub-ops 20–98, unused values in op
4/10/27/29/34/132/133) may gain definitions later. Existing assignments
will not change.

If a backwards-incompatible change becomes necessary, a new wire format
version is signalled by a new `bind_workstation` extension opcode at a
different value, and the N6 dispatcher selects the parsing tables based
on which bind was seen.

> **Open work / next steps** are tracked in [NextSteps.md](../NextSteps.md) — see "GEM (VDI + AES) / desktop".

## References

- EmuTOS `vdi/vdi_main.c`, `vdi/vdi_gdp.c`, `vdi/vdi_esc.c`,
  `vdi/vdi_defs.h` — authoritative source for opcode numbering and
  parameter shapes
- ["The Atari Compendium" — VDI chapter](http://dev-docs.atariforge.org/files/Compendium.pdf) —
  reference for classic GEM VDI calling conventions
- [n6-migration.md](./n6-migration.md) — PSSI / FMC / SPI transport
  details
- [GEM-implementation.md](./GEM-implementation.md) — surrounding port
  architecture
