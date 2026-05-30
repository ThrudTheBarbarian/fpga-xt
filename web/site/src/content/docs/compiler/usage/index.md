---
title: Compiler usage
description: How to drive the xtc toolchain — CLI flags, optimisation, memory models, allocator selection, linker scripts.
---

This section is the practical guide to **driving** the xtc toolchain — picking flags, choosing memory models, tuning the optimiser, configuring the allocator, and (when needed) writing your own linker script. Language-level details (syntax, types, classes) live in the [Language reference](/compiler/language/); standard-library APIs live under [Standard library](/compiler/api/). This section is about the bits that affect the **binary** rather than the **source**.

## A typical invocation

```bash
xtc -Q loop -O3 game.xt -o game.xex
```

```
xtc: optimised -O3 (9877 → 9698 instructions)
xtc: compiled 'game.xt' -> 'game.xex' (0 warnings, 0 errors)
xta: assembled -> 'game.xex' (19975 bytes, 1 segments)
```

The compiler produces three lines of summary by default — what optimisation pass did, what got compiled, and what the assembler emitted. `-q` silences the informational output for build-script use.

## What's where

- **[CLI flag reference](/compiler/usage/cli/)** — every command-line option, grouped by purpose. Start here when you want to know what a specific flag does.
- **[Optimisation](/compiler/usage/optimization/)** — what each `-O` level adds, the tuning knobs (`-Fli`, `-Flu`), how to read the optimiser's "before/after" instruction count.
- **[Memory models](/compiler/usage/memory-models/)** — picking among `xl`, `xe`, `xt`, the `rambo*` / `compy*` variants, and the `-shadow` overlays. Includes the trade-offs between shadow RAM and banked RAM.
- **[Allocator & ARC](/compiler/usage/allocator-arc/)** — `-falloc=bump` vs `-falloc=heap`, and the `-farc=on|off` choice between automatic and manual reference counting.
- **[Linker scripts (.lnk)](/compiler/usage/linker-scripts/)** — the file format that defines a memory model. Customise an existing layout or write a new one for non-standard hardware.

## What's not in this section

- **Function annotations** — `:banked`, `:main`, `:shadow`, `:irq`, `:vbi`, `:naked`, `:hwStack`, `:xtcStack`, `:needsOS` — these are language-level placement and calling-convention markers and live on the [Functions](/compiler/language/functions/#function-annotations) page.
- **Memory-model implementation details** — bank-switching mechanics, the `_xcall` trampoline, ZP byte allocation — those are documented inline in the language pages where they affect semantics ([Functions](/compiler/language/functions/), [Heap, ARC & weak refs](/compiler/language/memory/), [Inline assembly](/compiler/language/inline-asm/)).
- **Standard-library APIs** — `Heap.size()`, `Vbi.addDeferred()`, etc. live under [Standard library](/compiler/api/).

## Output format selection

The output format is determined by the `-o` filename extension or by the `[output]` section of the active `.lnk` file:

| Extension | Format |
|-----------|--------|
| `.asm` | 6502 assembly source (no assembler invocation) |
| `.xex`, `.exe`, `.bin`, `.com` | Atari XEX binary |
| `.prg` | Commodore 64 PRG binary |

Asking for `.asm` stops the pipeline after the compiler — useful when integrating with a separate assembler workflow or when inspecting the generated assembly.

## Support file search order

The toolchain looks up the `support/` directory (linker scripts, library classes, runtime asm) in this order:

```
-H <path> > $XTC_HOME > cwd > ~/xtc > /usr/local/xtc > /opt/xtc
```

Set `-H /path/to/xtc` (or export `XTC_HOME=...`) when you have multiple copies of the toolchain installed and need to point at a specific one.
