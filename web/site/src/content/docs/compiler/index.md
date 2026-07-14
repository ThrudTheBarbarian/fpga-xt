---
title: xtc
description: An ObjC-like language with classes, protocols, ARC and bound methods, compiling through one architecture-neutral IR to five targets — from a banked 6502 to native arm64, ARM32, 68000 and x86-64 — with shared libraries and cross-module protocol dispatch.
---

**xtc** is a small, statically-typed, ObjC-like language with classes, single inheritance,
protocols and automatic reference counting — compiling through one architecture-neutral IR
to **five live backends**, from an 8-bit banked 6502 to a 64-bit host.

The same source and the same standard library run on all of them. Where a machine needs it,
bank-switched RAM is a first-class resource: programs spread code and data across paged
windows and grow well beyond normal RAM limits, with the compiler deciding what lives
where. Where it doesn't, the same program is a native executable.

## Targets

| `-A` | Target | Output | Run with |
|---|---|---|---|
| `6502` *(default)* | banked **xt6502** — a custom FPGA 6502 with a 4 KB hidden hardware stack and SP-relative addressing | Atari `.xex` (banked) | `xts` |
| `arm64` | native macOS / Linux host | Mach-O / ELF executable | run it |
| `arm9` | AArch32 — the **XTOS** loader | ELF executable, or a **shared library** (`--emit-lib`) | the board, or QEMU |
| `m68k` | Atari ST | GEMDOS `.tos` | `xst` |
| `x86_64` | Linux (musl) | ELF executable | run it |

Every target passes the full fixture corpus.

For the Atari 8-bit path the toolchain has three pieces: **xtc**, the compiler (`.xt` source
→ 6502 assembly, or straight to a runnable Atari `.xex`); **xta**, a two-pass assembler that
emits XEX with RUNAD/INITAD and banked preload; and **xts**, a headless simulator that runs
`.xex` files with the same memory-model semantics the codegen targets. The `m68k` path has
its own simulator, **xst**.

## What the language gives you

- **Classes** with single inheritance from a root `Object`, virtual dispatch, and
  `init` / `dealloc` that chain automatically up the hierarchy — including for a subclass
  that declares neither.
- **Protocols**, including **optional methods** — an unimplemented one leaves a null slot,
  so `&delegate.method` doubles as `respondsTo`. That is what makes the delegate pattern
  work.
- **Bound methods** (`^`). `&obj.method` yields a `{receiver, code}` value you can store and
  call later; a plain function *widens* into the same type, so one `action` field accepts
  either. This is target/action.
- **ARC**, with `weak:` references that auto-zero when their referent dies — including on a
  stored `^`, which is what stops a view hierarchy becoming one enormous retain cycle.
- **Shared libraries** on `arm9`. `--emit-lib` produces a `.so` carrying its own interface,
  and `#import <Lib>` type-checks a client against the real binary. Classes, protocols
  (with working cross-module dispatch), structs, enums, `weak:` fields, bound methods and C
  types re-exported from *other* libraries all cross the boundary. See
  [Modules & shared libraries](/compiler/language/modules/).
- **Fixed-width types** (`i8`…`u32`, `float`, `double`, `bool`, `pointer`) with no implicit
  same-width promotion — `u8 + u8` wraps, even when the result is stored into a `u16`.
- **Inline assembly** on every target, with byte-extract operators and `clobbers`.

## These pages

- **[Language reference](/compiler/language/)** — syntax, types, classes, protocols, ARC,
  modules, inline assembly. Start here for *what xtc is*.
- **[Standard library](/compiler/api/)** — the classes shipped under `support/`, with method
  signatures and example usage — *what's already built for you*.
- **[Compiler usage](/compiler/usage/)** — CLI flags, optimisation levels, allocator and
  memory-model selection, banking, and linker scripts — *how to get the best output*.
- **[Future work](/compiler/future-work/)** — what's next, and what's known-incomplete.

Prebuilt binaries for macOS, Linux, and Windows are on the [Downloads](/compiler/downloads/) page.
