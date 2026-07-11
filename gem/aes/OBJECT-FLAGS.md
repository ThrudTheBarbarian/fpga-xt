# fpga-xt/gem AES — OBJECT flag/type conventions (for GemRCS)

How the fpga-xt/gem runtime interprets `ob_type`, `ob_flags` and `ob_state`.
The `.rsc` format round-trips all three as **raw 16-bit fields**, so files are
lossless regardless of how an editor labels the bits — this document says what
each bit *means*, so the runtime and GemRCS agree.

The constants live in two places that are kept identical: `gem/aes/aes.h`
(the runtime; compiled with `-DRSC_NO_STATE_FLAGS` so the shared codec uses
these) and the shared interchange header `fpga-gem/src/rsc.h` (which defines the
same `OF_`/`OS_`/`BOX_ROUND_`/`G_` sets, including the two desktop extensions
below, for any consumer that doesn't already provide them). Either is
authoritative — they match by construction.

Standard classic-GEM values are used throughout **except** where noted as an
extension. The runtime does **not** implement GEM's 3D-style flags — 3D shading
is standard and baked into the themes — so those bit positions are deliberately
reused (see `ob_flags`).

---

## 1. `ob_type` — low byte = widget type

| Value | Type | `ob_spec` |
|------:|------|-----------|
| 20 | `G_BOX` | inline box word (see §4) |
| 21 | `G_TEXT` | `TEDINFO*` |
| 22 | `G_BOXTEXT` | `TEDINFO*` |
| 23 | `G_IMAGE` | embedded P7 PAM (extension) |
| 24 | `G_USERDEF` | — |
| 25 | `G_IBOX` | inline box word |
| 26 | `G_BUTTON` | `char*` |
| 27 | `G_BOXCHAR` | inline box word |
| 28 | `G_STRING` | `char*` |
| 29 | `G_FTEXT` | `TEDINFO*` |
| 30 | `G_FBOXTEXT` | `TEDINFO*` |
| 31 | `G_ICON` | `ICONBLK*` (monochrome) |
| 32 | `G_TITLE` | `char*` |
| **40** | `G_CHECKBOX` *(ext)* | `char*` label; on = `OS_SELECTED` |
| **41** | `G_RADIO` *(ext)* | `char*` label; use `OF_RBUTTON`, group = same parent |
| **42** | `G_POPUP` *(ext)* | `char*` current value; linked tree in high byte |
| **43** | `G_FIELD` *(ext)* | `TEDINFO*` editable field |
| **44** | `G_CICON` *(ext)* | embedded P7 PAM (RGBA colour icon) |

Types 40–44 are fpga-xt/gem extensions the stock AES does not define.

## 2. `ob_type` — high byte ("extended" byte), by type

The high byte's meaning depends on the low-byte type. All uses survive a
`.rsc` round-trip.

- **Box types** (`G_BOX` 20, `G_IBOX` 25, `G_BOXCHAR` 27): per-corner rounding,
  OR-combined —
  `BOX_ROUND_TL 0x10`, `BOX_ROUND_TR 0x20`, `BOX_ROUND_BR 0x40`, `BOX_ROUND_BL 0x80`.
  Set the corners you want rounded (0 = square). Rendered by the theme.
- **`G_POPUP` (42)**: the high byte is the **index of the linked menu tree** —
  the tree whose `G_STRING` items are the popup's choices. `0` = no linked tree.
  The runtime opens that tree as a popup and copies the chosen item's text into
  the popup's value.
- **Editable fields** (`G_FTEXT` 29, `G_FBOXTEXT` 30, `G_FIELD` 43): bit 0 =
  "rounded bezel" (cosmetic hint only; the runtime draws field borders from the
  theme, so it is ignored at runtime — safe to keep for the editor's sake).
- **Other types**: high byte is 0 (unused).

## 3. `ob_flags` (16-bit)

Standard classic-GEM bits `0x01`–`0x80`. The runtime does **not** use
`INDIRECT` (0x100), `SUBMENU` (0x800), or the 3D flags (`FL3DIND`/`FL3DBAK`/
`FL3DACT`), and **reuses two freed 3D bits** for its own flags (both now defined
in the shared `rsc.h`, so GemRCS and the runtime name them identically):

| Bit | Name | Meaning |
|----:|------|---------|
| 0x0000 | `OF_NONE` | — |
| 0x0001 | `OF_SELECTABLE` | selectable |
| 0x0002 | `OF_DEFAULT` | default object — Return/Enter fires it |
| 0x0004 | `OF_EXIT` | exit object (a click on it ends the form) |
| 0x0008 | `OF_EDITABLE` | editable text field |
| 0x0010 | `OF_RBUTTON` | radio button (exclusive within its parent) |
| 0x0020 | `OF_LASTOB` | last object in the tree |
| 0x0040 | `OF_TOUCHEXIT` | exit on touch (button-down) |
| 0x0080 | `OF_HIDETREE` | this object + its subtree are hidden |
| **0x0200** | **`OF_CANCEL`** *(ext — reuses `FL3DIND`)* | **Esc fires this object** (the Cancel affordance) |
| **0x0400** | **`OF_MOVEABLE`** *(ext — reuses `FL3DBAK`)* | **on the tree ROOT only: the dialog is movable** (drag by its fly-corner or any inert area) |

`0x100`, `0x600`, `0x800` are free/unused by the runtime.

## 4. `ob_state` (16-bit)

Standard classic-GEM bits. `OS_WHITEBAK` (0x40) is the standard WHITEBAK
convention and carries the mnemonic index in the high bits. The runtime does
**not** use `DRAW3D` (0x80).

| Bit | Name | Meaning |
|----:|------|---------|
| 0x0000 | `OS_NORMAL` | — |
| 0x0001 | `OS_SELECTED` | selected/on (also = a checkbox/radio's checked state) |
| 0x0002 | `OS_CROSSED` | crossed |
| 0x0004 | `OS_CHECKED` | menu tick |
| 0x0008 | `OS_DISABLED` | greyed / non-interactive |
| 0x0010 | `OS_OUTLINED` | outlined |
| 0x0020 | `OS_SHADOWED` | shadowed |
| 0x0040 | `OS_WHITEBAK` | **mnemonic present**: bits 8–14 hold the 0-based index of the underlined shortcut character in the object's label (bit 15 reserved) |

Mnemonic index accessor: `(state >> 8) & 0x7F`, valid when `OS_WHITEBAK` is set
— `WB_INDEX(state)` in `aes.h`, `RSC_WB_INDEX(state)` in the shared `rsc.h`.

## 5. Box "inline word" (`ob_spec` for `G_BOX`/`G_IBOX`/`G_BOXCHAR`)

`(character << 24) | (thickness << 16) | colour_word` — standard GEM. The 16-bit
colour word is `border(15-12) text(11-8) textMode(7) fillPattern(6-4) inside(3-0)`.

---

*The runtime constants live in `gem/aes/aes.h`; the shared `.rsc` codec is
`fpga-gem/src/rsc.c`. If either changes, update this note.*
