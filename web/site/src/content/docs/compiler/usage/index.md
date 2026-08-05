---
title: Compiler usage
description: How to drive the xtc toolchain — CLI flags, optimisation, memory models, allocator selection, linker scripts.
---

This section is the practical guide to **driving** the xtc toolchain — picking flags, choosing memory models, tuning the optimiser, configuring the allocator, and (when needed) writing your own linker script. Language-level details (syntax, types, classes) live in the [Language reference](/compiler/language/); standard-library APIs live under [Standard library](/compiler/api/). This section is about the bits that affect the **binary** rather than the **source**.

## A typical invocation

```bash
xcc -o game game.xc
```

That is the whole thing for a native build: no `-A` means "this machine", the
standard library is found relative to the `xcc` binary, and the optimiser runs
at `-O3`. Cross-compiling adds one flag:

```bash
xcc -A 6502 -Q loop -o game.xex game.xc
```

```
xtc: optimised -O3 (9877 → 9698 instructions)
xtc: compiled 'game.xc' -> 'game.xex' (0 warnings, 0 errors)
xcc-as: assembled -> 'game.xex' (19975 bytes, 1 segments)
```

The compiler produces a short summary by default — what the optimiser did, what got compiled, and what the assembler emitted. `-q` silences the informational output for build-script use.

## What's where

- **[Install](/compiler/usage/install/)** — where `make install` puts things, and how `xcc` locates its own libraries. Read this first.
- **[CLI flag reference](/compiler/usage/cli/)** — every command-line option, grouped by purpose. Start here when you want to know what a specific flag does.
- **[Optimisation](/compiler/usage/optimization/)** — what each `-O` level adds, the tuning knobs (`-Fli`, `-Flu`), how to read the optimiser's "before/after" instruction count.
- **[Memory models](/compiler/usage/memory-models/)** — the `xt6502` map: two bank windows, the 4 KB hardware stack, and the on-demand banked heap. 6502-only; the native targets have no layout to choose.
- **[Allocator & ARC](/compiler/usage/allocator-arc/)** — `-falloc=bump` vs `-falloc=heap`, and the `-farc=on|off` choice between automatic and manual reference counting.
- **[Linker scripts (.lnk)](/compiler/usage/linker-scripts/)** — the file format that defines a memory model. Customise an existing layout or write a new one for non-standard hardware.

## What's not in this section

- **Function annotations** — `:banked`, `:main`, `:shadow`, `:irq`, `:vbi`, `:naked`, `:hwStack`, `:xtcStack`, `:needsOS` — these are language-level placement and calling-convention markers and live on the [Functions](/compiler/language/functions/#function-annotations) page.
- **Memory-model implementation details** — bank-switching mechanics, the `_xcall` trampoline, ZP byte allocation — those are documented inline in the language pages where they affect semantics ([Functions](/compiler/language/functions/), [Heap, ARC & weak refs](/compiler/language/memory/), [Inline assembly](/compiler/language/inline-asm/)).
- **Standard-library APIs** — `Heap.size()`, `Vbi.addDeferred()`, etc. live under [Standard library](/compiler/api/).

## Output format selection

On a **native** target (`arm64`, `x86_64`, `win64`, `arm9`) the output is a runnable executable unless `-o` ends in `.s` (assembly) or `.o` (object); `--emit-lib` produces a shared library instead. No system assembler or linker is involved — `xcc` carries its own.

On **6502** and **m68k** the `-o` extension picks the container, or the `[output]` section of the active `.lnk` file does:

| Extension | Format |
|-----------|--------|
| `.asm` | assembly source (stops before the assembler) |
| `.xex`, `.exe`, `.bin`, `.com` | Atari XEX binary (6502) |
| `.tos`, `.prg` | GEMDOS executable (m68k) |

Asking for `.asm` or `.s` stops the pipeline after codegen — useful for inspecting what the compiler produced.

## Support file search order

`xcc` locates its support tree (standard library, linker scripts, runtime asm) by probing each of these roots for `lib/xc`, then `xc`, then `support`:

```
-H <path> > $XCC_HOME > $XTC_HOME > the directory holding xcc, and its parent
          > cwd > ~/xcc > ~/xtc > /opt/xcc/<version> > /opt/xcc
          > /usr/local/xcc > /usr/local/xtc > /opt/xtc
```

The binary-relative step is what makes an install self-locating, so in normal use you set nothing at all. `-H` (or `$XCC_HOME`) is for pointing a specific compiler at a specific tree — most often running one straight out of a source checkout. `-V` prints which root won. Full detail on [Install](/compiler/usage/install/).
