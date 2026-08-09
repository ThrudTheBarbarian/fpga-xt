---
title: Linker scripts (.lnk)
description: The .lnk format that defines a memory model — sections, address syntax, banking and shadow specs, and how to write your own.
---

A **linker script** (`.lnk`) is a UTF-8 text file that describes a complete target layout: zero-page reservations, address spaces, banking mechanism (if any), shadow-mode configuration, stack and heap placement, and the startup hook. Each shipped memory model (`xt`, `xt-heap`) is a `.lnk` file under `support/xt6502/layouts/`.

:::note[The format is broader than the shipped layouts]
The `.lnk` parser still understands the `[shadow]` and `[cloaked]` sections described below, but **no shipped layout uses them** — they belonged to the retired stock-Atari `xl` / `xe` models. They are documented here because the format supports them and a custom layout may want them; the `xt6502` target reaches its extra RAM through the two bank windows instead.
:::

```bash
xcc -m ./my-layout.lnk app.xc -o app.xex     # use a custom layout
xcc -m xt             app.xc -o app.xex      # use a shipped layout by name
xcc --dump-layout -m xt                       # print a layout's diagram
```

Custom hardware (cartridge slots, non-stock RAM expansions, smaller / larger screen areas) can be supported without touching the compiler — write a `.lnk` and pass it.

## Format overview

INI-style sections, `key = value` entries, `#` comments to end of line.

```ini
# A trimmed example
[zp]
sp       = $82-$83        # stack pointer (2-byte pair)
tmp      = $84-$85
hp       = $86-$87
vars     = $88-$AF, $BC-$FF
runtime  = $B0-$BB

[memory]
main     = $2000-$9FFF

[stack]
range    = after-code

[heap]
range    = before-screen
```

### Value syntax

| Form | Meaning |
|------|---------|
| `$XXXX` | hex address (16-bit) |
| `1234`, `42` | decimal |
| `$XXXX-$YYYY` | inclusive address range |
| `$XXXX:$MM` | hardware register at `$XXXX` with bitmask `$MM` |
| `after-code`, `after-system`, `before-screen` | symbolic — linker resolves after layout |
| `key1 = a, b, c` | comma-separated list |
| `true` / `false` | booleans |

**Disambiguation rule:** `-` always means "address range"; `:` always means "bitmask on a hardware register"; bitmask values are always hex-prefixed (`$XX`). There is no "address:size" notation — use a range instead. Even a single 2-byte ZP pair is written as a range (`$82-$83`).

## Sections

### `[zp]` — zero-page layout

Names the ZP slots the codegen and runtime depend on. Every entry is a range, even for a 2-byte slot.

```ini
[zp]
sp       = $82-$83        # stack pointer (2 bytes)
tmp      = $84-$85        # scratch pair
hp       = $86-$87        # heap pointer (2 bytes)
vars     = $88-$AF, $BC-$FF     # allocatable user-var region(s)
runtime  = $B0-$BB        # reserved for runtime params
```

Named entries (`sp`, `tmp`, `hp`, `runtime`) are fixed reservations the codegen references by name. `vars` declares allocatable runs the ZP allocator draws from.

On banked targets, additional entries appear:

```ini
bankReg  = $82-$83        # bank-select register pair (xt code-bank selector + region B)
```

### `[memory]` — address-space regions

Named regions as comma-separated address ranges. The linker packs code and data into the `main` region first-fit across all listed runs.

```ini
[memory]
main     = $2000-$9FFF
screen   = $8000-$9FFF
```

Multi-run main regions (shadow mode):

```ini
[memory]
main     = $A000-$BFFF, $C000-$CFFF, $D800-$FFF9
system   = $2000-$3FFF
screen   = $8000-$9FFF
```

The linker treats each comma-separated range as an independent run: functions are packed within a single run and never straddle a gap. Overflow spills to banked pages if banking is configured, or surfaces as a diagnostic error if not.

### `[banking]` — bank-switched memory

Describes the hardware banking mechanism: which register(s) control bank selection, which address range is the bank window, how large each page is. The codegen derives the bank-select instruction sequence from the descriptors.

```ini
# xt — 16-bit ZP pair (implicit :$FF on each byte)
[banking]
window   = $4000-$5FFF
pageSize = $2000
register = $82-$83        # 16-bit selector pair, full byte each

# xe (128 KB, 4 banks): bits 2-3 of PORTB
[banking]
window   = $4000-$7FFF
pageSize = $4000
register = $D301:$0C      # PORTB, mask = bits 2-3

# rambo256 (8 banks): bits 2-3, 6 of PORTB
[banking]
window   = $4000-$7FFF
pageSize = $4000
register = $D301:$4C      # PORTB, mask = bits 2-3 + bit 6
```

Bit-mask layouts that need a non-contiguous set of bits use the union of bits (e.g. `$4C` = `$0C | $40` for bits 2-3 plus bit 6). The codegen generates the deposit pattern from the mask — you specify the bits, the compiler does the bit twiddling.

### `[shadow]` — ROM-disable configuration

Describes how to flip the OS ROM out and back in for shadow targets:

```ini
[shadow]
register = $D301:$01      # PORTB bit 0 controls OS ROM
charsetCopy = $E000       # source address of the charset to copy
```

The `:needsOS` function annotation drives the runtime save / disable / call / restore sequence around any function flagged with it.

### `[cloaked]` — code regions for `:cloaked` decls

Each `[cloaked]` block declares one region of the bank window where source-level `:cloaked` code can live. A layout may have several `[cloaked]` blocks; together they form a pool that auto-cloak's overflow ladder spills through.

```ini
# Banking-off region — code lives in main RAM at $4000-$7FFF and the
# call site sets PORTB to expose it.
[cloaked]
range = $4000-$7FFF
bank  = none
id    = lib

# Numbered-bank region — code loads into bank 2's image of the
# window; the call site sets PORTB to select bank 2.
[cloaked]
range = $4000-$7FFF
bank  = 2
id    = ext1
```

The `range` field is the address span the region occupies inside the bank window. `bank` is `none` for a banking-off region (PORTB bit 4 = 1) or a decimal bank index for a numbered region; codegen emits the matching PORTB bracket per region. `id` is the user-facing name used by source-level annotations (`:cloaked(<id>)`); plain `:cloaked` (no id) auto-packs into the first declared region.

#### Pool form: `bank = N-M` + `id = <prefix><n>`

Layouts with many available banks can declare a pool in one block:

```ini
[cloaked]
range = $4000-$7FFF
bank  = 4-12
id    = ext<n>
```

The `<n>` placeholder is mandatory in the `id` template — it's substituted with each bank's index, so the example above expands to nine concrete regions: `ext4`, `ext5`, …, `ext12`. Each becomes selectable from source as `:cloaked(ext7)` etc, and the auto-spill ladder walks them in declaration order on overflow.

Validation rejects:

- a range form without `<n>` in the id (the expansion would yield duplicate ids),
- a single-bank form with `<n>` in the id (the placeholder has nothing to bind to),
- duplicate ids across all `[cloaked]` blocks in the file (a `:cloaked(<id>)` annotation would be ambiguous).

Each region's bank is also reserved with the page tracker so `:banked` decls aren't packed on top of cloaked code. Empty regions cost nothing — codegen + xcc-as both skip zero-byte buffers — so a layout can over-declare its pool without runtime overhead. No shipped layout uses the pool form today.

`[cloaked]` applied to the **retired** `xe`-family Atari models, which used PORTB-style banking. No shipped layout declares the section, so in practice it is inert — the parser still accepts it, and `xt` (which reaches its extra RAM through the two bank windows instead) rejects a `:cloaked` annotation.

### `[stack]` — xtc software stack

```ini
[stack]
range = after-code        # symbolic — the linker places the stack right after the code/data block
size  = $0100             # optional explicit cap (otherwise grows toward the heap)
```

### `[heap]` — heap region (optional)

A layout that **declares** `[heap]` makes the coalescing free-list allocator available; one that omits the section forces `-falloc=bump`.

```ini
[heap]
range = before-screen     # symbolic — heap grows down from just below screen RAM
```

The shipped `xt` heap is *on-demand*: it claims one data bank at a time from a shared bitmap as allocation needs it, and gives empty banks back. The runtime selects the right bank on each allocator call.

### `[entry]` — entry point address

```ini
[entry]
address = $2000           # where main() lands; sets the XEX RUNAD
```

### `[startup]` — startup template

```ini
[startup]
template = startup/xl.asm     # hand-written .asm template under support/<platform>/startup/
```

The template is a 6502 assembly file with placeholder substitutions (sentinels the linker fills in with addresses derived from the rest of the layout). Banked targets ship startup that loads each bank page directly into the bank window at boot via INITAD preload stubs.

### `[output]` — binary format

```ini
[output]
format = atari-xex
```

Used when the user passes `-o file` without an extension; otherwise the extension wins.

## Memory-map diagram (comment header)

By convention, every shipped `.lnk` opens with a Unicode box-art comment showing the actual memory layout the file describes:

```ini
# flat.lnk — a hypothetical flat 6502 target (no banking, no shadow)
#
# ┌──────────────────────────────────────────────┐
# │ $0000-$0081  OS/hardware zero page           │
# │ $0082-$00BB  xtc ZP: SP, tmp, HP, vars       │
# │ $00B0-$00BB  runtime params (reserved)       │
# │ $00BC-$00FF  xtc ZP: vars (continued)        │
# ├──────────────────────────────────────────────┤
# │ $2000-$9FFF  Main region (32 KB)             │
# │   $2000      Code + data (entry point here)  │
# │              Stack ↑ (grows up after code)   │
# │              (free RAM)                      │
# │   $9FFF      Heap ↓ (grows down from here)   │
# ├──────────────────────────────────────────────┤
# │ $A000-$BFFF  Unused / OS area                │
# │ $C000-$CFFF  OS self-test ROM                │
# │ $D000-$D7FF  Hardware I/O                    │
# │ $D800-$FFFF  OS ROM                          │
# └──────────────────────────────────────────────┘
```

The diagram is for the human reader — the linker doesn't parse it. `xcc --dump-layout -m <name>` reproduces the same diagram from the parsed config, which is how you confirm a custom file describes what you think it does.

## Built-in models

```bash
xcc -ll
```

Prints every shipped layout grouped by platform. Each one is a `.lnk` file you can copy as a starting point for a custom variant.

The shipped layouts are `xt` (the standard xt6502 model — two bank windows and an on-demand
banked heap) and `xt-heap` (the same map with a fixed heap reservation). Layouts apply to the
6502 backend only; the native targets have no layout to choose.

See [Memory models](/compiler/usage/memory-models/) for what each one is for and when to pick it.

## Writing your own

The fastest path is **copy and modify**:

1. Run `xcc --dump-layout -m <closest match>` to see the layout you're starting from.
2. Copy `support/<platform>/layouts/<closest>.lnk` to a new file.
3. Edit the sections you need to change — typically `[memory]`, `[banking]` (if your hardware has different bank-bit pattern), and the comment-header diagram.
4. Run `xcc --dump-layout -m ./your-file.lnk` and verify the printed diagram matches your intent.
5. Compile with `-m ./your-file.lnk`. If the file lives next to the shipped layouts under `support/<platform>/layouts/`, you can reference it by name without the path.

If you write a layout for a piece of hardware that's likely to be useful to others (a memory expansion, a cartridge form factor, a unique screen-RAM placement), upstream it — every shipped `.lnk` was a custom layout once.

## CLI surface

| Flag | Purpose |
|------|---------|
| `-m <layout>` | Activate a layout. Searches `<layout>` as a path (appends `.lnk` if needed), then `support/layouts/<layout>.lnk`, then `support/<platform>/layouts/<layout>.lnk`. |
| `-ll`, `--list-layouts` | List every built-in layout. |
| `--dump-layout` | Print the active layout's parsed diagram and exit. |
| `-H <path>` / `XTC_HOME=...` | Point the search at a specific xtc home (so a custom `support/` tree is preferred over the system one). |
