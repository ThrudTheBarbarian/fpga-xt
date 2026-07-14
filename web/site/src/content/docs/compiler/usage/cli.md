---
title: CLI flag reference
description: Every command-line option for xtc, grouped by purpose.
---

Every flag the `xtc` driver accepts. Grouped by purpose; for a flat alphabetical dump, run `xtc -h`.

## Inputs and outputs

```bash
xtc [options] <input.xt> [<input2.xt> …]
```

| Flag | Effect |
|------|--------|
| `-o <path>`, `--output <path>` | Output file. The extension (`.asm`, `.xex`, `.exe`, `.bin`, `.com`, `.prg`) selects the format. Default: stdout. |
| `-a`, `--assemble-only` | Stop after producing `.asm` — don't invoke the assembler. Useful for inspection and toolchain integration. |
| `-E <path>`, `--preprocessed <path>` | Write the preprocessed source to `<path>` and continue compilation. Lets you see exactly what the lexer sees. |
| `-I <path>` | Add `<path>` to the include-search path. Repeatable. |
| `-D <name>[=<value>]` | Define a preprocessor symbol. `-DDEBUG` is `#define DEBUG 1`; `-DLEVEL=3` defines `LEVEL` as `3`. |
| `-q`, `--quiet` | Suppress informational output. Errors still print. |
| `-h`, `--help` | Print the full flag listing and exit. |

## Target architecture

| Flag | Effect |
|------|--------|
| `-A <arch>`, `--arch <arch>` | Target architecture. One of `6502` (default), `arm64`, `arm9`, `m68k`, `x86_64`. |

| `-A` | Target | Output |
|---|---|---|
| `6502` *(default)* | banked **xt6502** | Atari `.xex` — run under `xts` |
| `arm64` | native macOS / Linux host | Mach-O / ELF executable — run it |
| `arm9` | AArch32 / **XTOS** | ELF executable, or a `.so` (see below) |
| `m68k` | Atari ST | GEMDOS `.tos` — run under `xst` |
| `x86_64` | Linux (musl) | ELF executable |

`-m` (below) selects the *memory layout* within a target; it applies to the 6502 path. The
native targets have no memory model to load — their libraries come from `support/<arch>/`.

## Shared libraries

Only on `arm9`, which is the target with a dynamic loader.

| Flag | Effect |
|------|--------|
| `--emit-lib` | Emit a **shared library** (`.so`) instead of an executable, with its public interface embedded in the binary. |
| `-L <path>`, `--library-path <path>` | Add a search path for `#import <Lib>`, which resolves to `lib<Lib>.so`. Repeatable. |

```bash
xtc -A arm9 --emit-lib -o libXtg.so xtg.xt     # build the library
xtc -A arm9 -L . -o app.so app.xt              # build a client against it
```

`#import <Lib>` type-checks the client against the **actual binary** — there is no header to
drift out of sync. It also works on a plain **C** `.so`, whose DWARF supplies its functions,
types and enum constants. See
[Modules & shared libraries](/compiler/language/modules/).

## Memory model and platform

| Flag | Effect |
|------|--------|
| `-m <layout>` | Load a memory layout (6502 only — the native backends ignore it). Searches `<layout>` as a path (appends `.lnk` if needed), then `support/layouts/<layout>.lnk`, then `support/<platform>/layouts/<layout>.lnk`. Default: `xt`. |
| `-ll`, `--list-layouts` | List every built-in layout, grouped by platform. Exits without compiling. |
| `--dump-layout` | Print the active layout's memory-map diagram and exit. Use with `-m`. |
| `-H <path>`, `--xtc-home <path>` | Set the xtc home directory (overrides `XTC_HOME`). Affects the search path for layouts, library classes, and runtime asm. |

See [Memory models](/compiler/usage/memory-models/) for the full discussion of the available layouts.

## Optimisation

| Flag | Effect |
|------|--------|
| `-O0` | No optimisation — straight-through codegen. The default. |
| `-O`, `-O1` | Peephole + register tracking. |
| `-O2` | Adds: const propagation, dead code / dead store elimination, tail-call optimisation, leaf-function inlining, loop unrolling for small trip counts. |
| `-O3` | Adds: branch inversion, branch threading, strength reduction, cross-function dead-code elimination, label cleanup. |
| `-Fli <n>`, `--fn-leaf-inline <n>` | Max leaf-function size (in instructions) eligible for inlining. Default: 100. Requires `-O2+`. |
| `-Flu <n>`, `--fn-loop-unroll <n>` | Auto-unroll counted `for`-loops with trip count ≤ `<n>`. Default: 5 at `-O2+`, 0 below. |

Full discussion on [Optimisation](/compiler/usage/optimization/).

## Allocator and ARC

| Flag | Effect |
|------|--------|
| `-falloc=bump` | Inline bump allocator. Fast `new`, no `delete`. |
| `-falloc=heap` | Coalescing free-list allocator. Supports `delete`, `release`, `dealloc`. Default on layouts with a dedicated `[heap]` region. |
| `-farc[=on\|off]` | Automatic reference counting. `on` (default) emits retains and releases automatically and rejects manual `retain` / `release` statements; `off` disables auto-emit and accepts manual lifecycle. Accepts `on/yes/1` or `off/no/0`. |

See [Allocator & ARC](/compiler/usage/allocator-arc/) for the lifecycle implications.

## Stack control

| Flag | Effect |
|------|--------|
| `-S`, `--xtc-stack` | Use the xtc software stack globally for return addresses and saved registers. Slower but unbounded. |
| `-ss <n>`, `--stack-size <n>` | Cap the xtc stack at `<n>` bytes. Accepts decimal, `$hex`, or `0xhex`; range 1..65535. On a flat-heap layout the bytes you reclaim are handed to the heap. No effect on banked-heap or non-heap targets. |

## Runtime behaviour

| Flag | Effect |
|------|--------|
| `-Q rts`, `--quit-style rts` | When `main` returns, issue an `RTS` to the caller (DOS). Default. |
| `-Q loop`, `--quit-style loop` | When `main` returns, jump to an infinite loop. Useful for "the program owns the machine" demos and for cases where the caller doesn't expect control back. |

## Warnings

Suppress a category with `-Wno-<category>`. All warnings on by default.

| Category | Triggered by |
|----------|--------------|
| `asm-clobbers` | `asm{}` block's `clobbers` annotation disagrees with the registers the compiler thinks were touched |
| `class-init` | bad initialiser passed to a stack-allocated class |
| `escape` | a stack-allocated address is stored into a longer-lived variable (global, heap field, outer scope) — likely dangling |
| `new-in-loop` | `new` inside a loop body — likely a leak unless deliberately accumulating |
| `unknown-annotation` | unrecognised function annotation (e.g. `:foo`) — caught at sema time |
| `unknown-pragma` | unrecognised `#`-directive |

Example:

```bash
xtc app.xt -o app.xex -O2 -Wno-new-in-loop
```

## Combined examples

```bash
# Plain build, default xl flat memory model
xtc hello.xt -o hello.xex

# 130XE with banking, full optimisation, looped exit
xtc -m xe -O3 -Q loop game.xt -o game.xex

# Inspect the optimiser's output without invoking the assembler
xtc -O2 -a app.xt -o app.asm

# See what the active layout looks like
xtc --dump-layout -m xt

# Build with a custom layout file
xtc -m ./my-layout.lnk app.xt -o app.xex

# Manual lifecycle, larger stack, debug build
xtc -farc=off -ss $0400 -DDEBUG -O0 game.xt -o game.xex
```
