---
title: Memory models
description: The -m flag and the xt6502 memory map — two bank windows, a 4 KB hardware stack, and the on-demand banked heap.
---

A **memory model** is the layout a 6502 build targets: where code lives, where data lives,
how banking works, and where the stack and heap sit. Pick one with `-m <name>`.

```bash
xtc -m xt app.xt -o app.xex
```

Memory models apply to the **6502 backend only**. The other four targets
(`arm64`, `arm9`, `m68k`, `x86_64`) are native platforms with a loader and an OS of their
own — they have no layout to choose, and `-m` is ignored.

To see every layout the compiler ships with:

```bash
xtc -ll
```

To inspect a layout's memory map:

```bash
xtc --dump-layout -m xt
```

## The xt6502 target

There is **one** 6502 target: **xt6502**, a custom FPGA 6502 core. The stock-Atari `xl`
(flat 64 KB) and `xe` (PORTB-banked) models, the `rambo*` / `compy*` expansion variants, and
the Commodore `c64` target have all been **retired** — `-m xl`, `-m xe` and `-m c64` now
hard-error rather than silently producing something that won't run.

The shipped layouts are:

```
xt         ← the standard model: two bank windows + on-demand banked heap
xt-heap    ← the same map with a fixed heap reservation
```

`support/xt6502/layouts/xt.lnk` is the **single source of truth** for the map. The code
generator, the assembler (`xta`) and the simulator (`xts`) all read the bank registers and
regions out of it — nothing is hardcoded in any of them.

## The map

```
$0500-$07FF   spill-frame region (grows up)
$2400-$3FFF   system region — entry point, startup, descriptors, literals
$4000-$5FFF   screen RAM
$6000-$9FFF   CODE bank window — one 16 KB page, selected by $D5C0
$A000-$CFFF   DATA bank window — one 12 KB page, selected by $D5C1
$D800-$FFF9   unbanked code
```

Entry is at `$2400`.

### Two windows, memory-mapped selectors

The bank selectors are **memory-mapped registers**, not zero page: **`$D5C0`** selects the
code window, **`$D5C1`** the data window. (Zero-page selectors were the old design; the boot
ROM's RAM-clear loop zeroes zero page mid-init, which is exactly the wrong moment.) Generated
code and the runtime asm see them as the symbols `__bank_code_reg` / `__bank_data_reg`, taken
from the layout.

With an 8-bit selector each:

| Window | Page size | Pages | Addressable |
|---|---|---|---|
| Code (`$6000-$9FFF`) | 16 KB | 256 | **4 MB** of code |
| Data (`$A000-$CFFF`) | 12 KB | 256 | **3 MB** of data |

**Code lives in exactly two places** — the code-bank pages and the unbanked `$D800-$FFF9`
region. It is **never** placed in the data window. `main` and a few must-stay-resident helpers
run unbanked; everything else is packed into 16 KB code pages and reached through the unbanked
`_xcall` trampoline, which saves the current code bank, switches, calls, and restores.

From the source's point of view, banking does not exist:

```c
class World  { … }     // lands in some code bank
class Player { … }     // possibly a different one

i16 main(void)
{
    World@  w = new World();
    Player@ p = new Player();
    p.bumpInto(w);      // cross-bank call — the trampoline handles it
    return 0;
}
```

Banking is **function-granular**, so a single function larger than the 16 KB window cannot be
placed at all; `xta` fails the build rather than spilling code somewhere it can't run. Split
it into smaller functions. (See [Future work](/compiler/future-work/) — intra-function banking
is a planned fix.)

### Pointers carry their bank

xtc's 6502 pointers are **three bytes**: `[addr-lo, addr-hi, data-bank]`. The backend writes
`$D5C1` from byte 2 on **every** dereference, so a pointer into any of the 256 data pages is
just a pointer — no annotation, no manual bank juggling.

### The hardware stack

The xt6502 core has a **4 KB hidden hardware stack** (12-bit SP) with SP-relative addressing
(`d,SP`, `(d,SP),Y`, `d,SP,X`). That is the primary stack: it carries frames, parameters and
register spills, and the runtime libraries push their recursion frames on it too. Its top 256
bytes alias `$0100-$01FF`, so legacy `TSX` + `$0100,X` code still works.

There is exactly **one** software stack pointer (SSP), used only for the rare non-leaf spill
frame whose pinned locals don't fit in zero page; those frames live in the `$0500-$07FF`
region.

### The heap grows on demand

`xt` declares a **banked free-list heap** in the data window, which is what makes
`-falloc=heap` (and therefore ARC, `new` / `delete`) the default on this target. It is
*on-demand*: it claims one data bank at a time from a shared bank bitmap as allocation needs
it, grows up to the window's last page (3 MB), and gives empty banks back.

There is no fixed reservation to tune — a program uses as much heap as it needs without
editing the layout. The one limit: **a single allocation cannot span a bank boundary**, so no
one object may exceed ~12 KB. Total heap is unaffected. This is by design.

`xt-heap` is the variant with a fixed heap reservation instead, for when you want the
allocation deterministic.

## Libraries resolve by architecture × platform

The standard library is selected on **two** axes: the backend's CPU tree
(`support/xt6502/`, `support/arm64/`) and the arch-neutral `support/generic/lib` beneath it,
with a platform-specific file of the same name winning. That is how one `Stdio.xt` or
`Math.xt` source serves a banked 6502 and a 64-bit host.

## Customising or writing your own

Every memory model is a `.lnk` file under `support/xt6502/layouts/`. Open one — the format is
documented (and self-documenting) at
[Linker scripts (.lnk)](/compiler/usage/linker-scripts/). Copy and modify; pass your own file
with `-m ./my-layout.lnk`, or drop it next to the shipped layouts and reference it by name.
