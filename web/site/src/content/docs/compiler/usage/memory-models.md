---
title: Memory models
description: Picking the right -m flag — xl, xe, xt, the rambo / compy variants, and the -shadow overlays.
---

A **memory model** is the layout the compiler targets: where code lives, where data lives, what banking (if any) is in play, and how the OS ROM is treated. Pick one with `-m <name>`. The default is `xl` — flat 64 KB, no tricks.

```bash
xtc -m xe app.xt -o app.xex
```

To see every layout the compiler ships with:

```bash
xtc -ll
```

To inspect a specific layout's memory map:

```bash
xtc --dump-layout -m xe-shadow
```

This page covers the shipped layouts and the trade-offs between them. The file format is on [Linker scripts (.lnk)](/compiler/usage/linker-scripts/) — useful if you're customising or writing your own.

## The Atari layouts

```
atari/xl              ← flat 64 KB, no banking, no shadow
atari/xl-shadow       ← shadow ROM disable for ~14 KB extra "always on" RAM
atari/xe              ← 130XE: 128 KB via PORTB-driven 16 KB window
atari/xe-shadow       ← xe + shadow ROM disable
atari/rambo192        ← extended memory variant (192 KB)
atari/rambo256        ← (256 KB)
atari/rambo320        ← (320 KB)
atari/rambo576        ← (576 KB)
atari/rambo1088       ← (1088 KB)
atari/compy320        ← Compy-Shop variant (320 KB)
atari/compy576        ← (576 KB)
atari/xt              ← three-window banked + shadow main + banked heap + regC
atari/xt-no-regC      ← xt without the region-C fallover
atari/xt-no-bank      ← xt with no banked heap (bump heap, OS ROM live)
                        (xt family is CUSTOM HARDWARE — not stock XL/XE)
```

`xtc -ll` is the authoritative list — the catalogue may grow.

## The flat models

### `xl` — standard 800XL, 64 KB

The simplest layout. No banking, no shadow tricks. Roughly:

```
$2000  ┌─────────────────┐
       │ Code + data     │
       ├─────────────────┤  stack_low
       │ Stack ↑         │  SP starts here, grows upward
       │   (free RAM)    │
       │          ↓ Heap │  HP starts at $9FFF, grows downward
$9FFF  └─────────────────┘
$A000  ┌─────────────────┐
       │ OS ROM / I/O    │  CIO, math pack, charset, I/O regs
$FFFF  └─────────────────┘
```

You get the bottom 32 KB minus startup overhead (typically ≈30 KB usable for code + data + stack + heap). Perfect for small programs and the easiest target for first-time exploration. **Default model.**

### `xl-shadow` — flat with ROM disable

Extends `xl` by **disabling the OS ROM** to gain access to the ~14 KB of RAM that lives underneath at `$C000-$CFFF` and `$D800-$FFF9`. Trade-offs:

| Pro | Con |
|-----|-----|
| Zero-overhead access to ~14 KB of "always on" extra RAM | Disabling ROM breaks CIO, the floating-point math pack, and the default character set |
| Predictable code placement — no banking trampolines | Charset must be relocated; a fake-frame VBI trampoline temporarily re-enables ROM for OS calls |
| Fast — the CPU just reads/writes, no register pokes per access | Only one "bank" — content can't be paged in and out |

A function that needs the OS (file I/O, Atari math, etc.) gets annotated `:needsOS` and the codegen brackets the call with a ROM enable / disable pair. Keep `:needsOS` functions small and self-contained — many such calls means the ROM swap fires repeatedly and erases the speed advantage.

## The xe family — single 16 KB bank window

### `xe` — 130XE, 128 KB

The 130XE adds 64 KB of banked RAM on top of the 64 KB base. xtc paged the bank window at `$4000-$7FFF` and selects the active bank by writing to **PORTB** (`$D301`). The codegen does this transparently — every cross-bank call goes through an `_xcall` trampoline that saves the current bank, switches, performs the JSR, and restores. From the source's perspective, banking does not exist:

```c
class World { ... }     // lands in a bank
class Player { ... }    // also a bank — possibly a different one
void main(void) {
    World@ w = new World();
    Player@ p = new Player();
    p.bumpInto(w);                  // cross-bank if w and p are on different pages
}
```

`XTBankPageTracker` first-fit packs classes and free functions across pages, so a large program scales naturally. Hot, always-resident code (runtime, math, main, interrupt handlers) lives in **main RAM** at `$A000-$BFFF` so it's reachable regardless of which bank is selected.

The cost of banking is the per-cross-bank-call trampoline — measurable, but tiny compared to the value of having an extra 64 KB to play with on a 128 KB machine.

### `rambo192` / `rambo256` / `rambo320` / `rambo576` / `rambo1088`

The `rambo*` family is "bigger `xe`s". Same banking mechanism (PORTB-driven 16 KB window), more banks, more total RAM. The trailing number is total kilobytes:

| Layout | Total RAM | Banks |
|--------|-----------|-------|
| `rambo192` | 192 KB | 8 |
| `rambo256` | 256 KB | 12 |
| `rambo320` | 320 KB | 16 |
| `rambo576` | 576 KB | 32 |
| `rambo1088` | 1088 KB | 64 |

The linker script for each model just adjusts which PORTB bits drive the bank selection. Programs that fit in `xe` run on any `rambo*` unchanged; programs that overflow `xe` may compile cleanly against `rambo256` if the bank packer can find room.

### `compy320` / `compy576`

The same idea as the `rambo*` line, but using the bit pattern of the **Compy-Shop** memory expansion. Pick by hardware — the catalogue is per-physical-card.

### `xe-shadow` and the shadow variants

Every banked layout has a **`-shadow`** sibling that combines banking with ROM disable. You get the bank window at `$4000-$7FFF` **and** the ~14 KB of shadow RAM at `$C000-$CFFF` + `$D800-$FFF9`. The `:needsOS` discipline applies — wrap any OS-using function with the annotation, keep them small.

The rule of thumb is: put hot / always-resident code in **shadow RAM**; spill cold or bulky class methods into the **bank window**. The codegen handles the placement automatically given the function annotations described in [Functions → Placement](/compiler/language/functions/#placement).

## The xt family — three independent bank windows

:::note[Being redesigned around the new-xt FPGA core]
The `xt` description below is the **0.12 shipping model** — three
zero-page-selected bank windows. In the active development tree the `xt`
target is being rebuilt around a **custom FPGA 6502** ("new-xt") with a
**4 KB hidden hardware stack** (12-bit SP) and **SP-relative addressing**
(`d,SP`, plus `(d,SP),Y` and `d,SP,X`) in place of the bank-window scheme,
so the compiler can keep locals and temporaries in a real stack frame
instead of zero page. That work is **in development** and not in a released
build — see [Future work](/compiler/future-work/).
:::

:::caution[Requires custom hardware]
The `xt` family targets a banking scheme that **does not exist on stock XL or XE machines**. Selecting `-m xt` produces a binary that pokes zero-page bank-select registers (`$82`/`$83`/`$84`/`$85`) which the standard Atari hardware does not interpret as bank selectors — those are just plain RAM there. Picking `xt` only makes sense if you have (or are designing for) an aftermarket hardware expansion that implements the three-window mapping at those addresses. On unmodified hardware, use `xe` or `rambo*` / `compy*` instead.
:::

### `xt` — three-window banked target

`xt` solves the main pain point of `xe`: when `xe` switches its 16 KB window for a heap access, it also swaps out the caller's own code page. `xt` splits the `$4000-$7FFF` aperture into **three independent windows** with separate selectors:

```
$4000  ┌──────────────────┐
       │ Code bank        │  $82 selects this 8 KB page
       │   (8 KB via $82) │  Classes and :banked functions
$5FFF  └──────────────────┘
$6000  ┌──────────────────┐
       │ Data bank (B)    │  $83 selects this 4 KB page
       │  (4 KB via $83)  │  Heap, spilled struct data, array storage
$6FFF  └──────────────────┘
$7000  ┌──────────────────┐
       │ Region C bank    │  $84/$85 (16-bit pair) selects this 4 KB page
       │ (4 KB via $84/85)│  Extended HyperRAM beyond the first 4 MB
$7FFF  └──────────────────┘
```

Code, data, and region C can each page independently, so switching the data bank for a heap access **doesn't swap out the caller's own code page**. The cost is more zero-page real estate burned on bank registers, plus the requirement that the host hardware implement the three-register mapping (the callout above). See the source repo's `doc/xt-usage.md` for the full hardware story.

The default `xt` layout pulls the full hardware story together: shadow ROM disable for ~22 KB of main code at `$A000-$CFFF` + `$D800-$FFF9`, a banked free-list heap in the data-pool window, and region-C fallover for the regions beyond the first ~2 MB of HyperRAM. Two narrower variants are also available — `xt-no-regC` drops the region-C fallover (frees `$84`/`$85` ZP), and `xt-no-bank` keeps the bank windows wired for `:banked` code but pins the heap to a bump allocator in the system region with the OS ROM still mapped.

### Pay-for-what-you-use (region C)

A program whose call graph never touches `$84`/`$85` produces **byte-identical XEX** to a layout without region C at all. The compiler tracks which functions reach region C (transitively) and gates the entire region-C machinery — ZP reservation of `$84`/`$85`, the region-C-aware `_xcall` trampoline, and the heap.asm region-C variant — on whether the program reaches it.

## The Commodore platform

```
commodore/c64
```

A single layout for the C64 today. The Commodore platform is a sister target that uses the same compiler driver and language but a different output format (`.prg`) and a different standard library implementation (under `support/commodore/lib/`).

:::note[New-IR: libraries resolve by architecture × platform]
The 0.12 standard library is selected by **platform** — `support/atari/lib`
vs `support/commodore/lib`, falling back to the arch-neutral
`support/generic/lib`. The new-IR backends (in development) add an
**architecture** axis on top: each backend also searches its CPU tree —
`support/arm64/lib` for the native arm64 backend, the 6502 runtime for the
6502 backends — so one Foundation source compiles for very different
machines. See [Future work](/compiler/future-work/).
:::

## Choosing a model

| When you have | And you want | Pick |
|---------------|--------------|------|
| 64 KB stock 800XL | The simplest possible build | `xl` |
| 64 KB stock 800XL | Maximum "always on" RAM | `xl-shadow` |
| 130XE / RAM expansion | Transparent bank switching | `xe` |
| 130XE | Maximum RAM **and** ~14 KB extra in shadow | `xe-shadow` |
| Larger Atari RAM expansion | Match your card's bit pattern | `rambo*` or `compy*` |
| Custom three-window hardware | Full configuration (shadow + heap + regC) | `xt` |
| Custom three-window hardware | Heap, no region-C fallover | `xt-no-regC` |
| Custom three-window hardware | Bank windows for explicit `:banked` only, no heap | `xt-no-bank` |
| C64 | C64 PRG output | `commodore/c64` |

If you're not sure, start with **`xl`**. Move to `xe` when you've outgrown 64 KB. Move to a `-shadow` variant when you want the extra RAM in the I/O hole. Reach for `xt` only when you've got the hardware to back it.

## Customising or writing your own

Every memory model is a `.lnk` file shipped under `support/<platform>/layouts/`. Open one in a text editor — the format is documented (and self-documenting) at [Linker scripts (.lnk)](/compiler/usage/linker-scripts/). Copy and modify; pass your custom file with `-m ./my-layout.lnk` or drop it next to the shipped layouts and reference by name.
