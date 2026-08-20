---
title: xcc
description: A statically-typed, ObjC-like language with classes, protocols, ARC and bound methods, compiling through one architecture-neutral IR to six targets — from a banked 6502 to native arm64, x86-64, Windows, ARM32 and 68000.
---

**xcc** is a small, statically-typed, ObjC-like language with classes, single inheritance,
protocols and automatic reference counting. It compiles through one architecture-neutral
SSA intermediate representation to **six live backends**, from an 8-bit banked 6502 to
64-bit macOS, Linux and Windows.

The same source and the same standard library run on all of them. Where a machine needs
it, bank-switched RAM is a first-class resource: programs spread code and data across paged
windows and grow well beyond normal RAM limits, with the compiler deciding what lives
where. Where it doesn't, the same program is an ordinary native executable.

The compiler is called `xcc`, and it behaves like a C compiler:

```bash
xcc -o hello hello.xc                 # a native binary for THIS machine
xcc -A 6502 -o hello.xex hello.xc     # the same source, for the banked 6502
```

That is the whole invocation for a simple program. Nothing selects the host, no
environment variable points at the libraries, and the standard library comes along
automatically.

## Targets

With no `-A`, `xcc` builds for the machine it is running on. Pass `-A` to cross-compile.

| `-A` | Target | Output | Run with |
|---|---|---|---|
| *(none)* | the host you are on | native executable | run it |
| `arm64` | macOS / Linux on 64-bit ARM | Mach-O / ELF | run it |
| `x86_64` | Linux (musl) | ELF | run it |
| `win64` | Windows | PE/COFF `.exe` | run it, or Wine |
| `arm9` | AArch32 — the **XTOS** loader | ELF, or a shared library (`--emit-lib`) | the board, or QEMU |
| `m68k` | Atari ST / TT | GEMDOS `.tos` | `xcc-sim-68k` |
| `6502` | banked **xt6502** — a custom FPGA 6502 with a 4 KB hidden hardware stack and SP-relative addressing | Atari `.xex` (banked) | `xcc-sim-6502` |

Every target passes the full fixture corpus. The native targets assemble and link
**in-house** — `xcc` carries its own assemblers, linkers and Mach-O / ELF / PE writers — so
a build needs no system toolchain.

The 6502 path has two more pieces: **`xcc-as`**, a two-pass assembler that emits XEX with
RUNAD/INITAD and banked preload, and **`xcc-sim-6502`**, a headless simulator that runs
`.xex` files with the same memory-model semantics the codegen targets. The `m68k` path has
its own simulator, **`xcc-sim-68k`**.

## What the language gives you

- **Classes** with single inheritance from a root `Object`, virtual dispatch, and
  `init` / `dealloc` that chain automatically up the hierarchy — including for a subclass
  that declares neither.
- **Protocols**, including **optional methods** — an unimplemented one leaves a null slot,
  so `&delegate.method` doubles as `respondsTo`. That is what makes the delegate pattern
  work.
- **Bound methods** (`^`). `&obj.method` yields a `{receiver, code}` value you can store and
  call later; a plain function *widens* into the same type, so one `action` field accepts
  either. This is target/action, with no protocol and no context pointer. See
  [Bound methods & callbacks](/compiler/language/bound-methods/).
- **ARC**, with `weak:` references that auto-zero when their referent dies — including on a
  stored `^`, which is what stops a view hierarchy becoming one enormous retain cycle.
- **Typed collections** — `Array<String>*`, `Map<Point>*`, `Set<String>*`. The element type
  is checked at compile time and erased at run time, so there is no code-size cost per
  instantiation. See [Collections & strings](/compiler/language/collections/).
- **Threading** on the native targets: `Thread`, `Mutex`, `Cond`, `Sem`, `Atomic` and
  `Pool.forRange`, with ARC refcounts automatically made atomic in any module that spawns a
  thread. See [Threading](/compiler/language/threading/).
- **Errors as a checked effect** — a function that can fail is marked `throws`, and a caller
  must handle it or be `throws` itself. See [Errors](/compiler/language/errors/).
- **Shared libraries.** `--emit-lib` produces a library carrying its own interface, and
  `#import <Lib>` type-checks a client against the real binary. Classes, protocols (with
  working cross-module dispatch), structs, enums, `weak:` fields, bound methods and C types
  re-exported from *other* libraries all cross the boundary. See
  [Modules & shared libraries](/compiler/language/modules/).
- **Fixed-width types** — `i8`…`u64`, `float`, `double`, `bool`, `pointer` — with no C-style
  promotion to `int`: same-width arithmetic stays at that width.
- **Inline assembly** on every target, with byte-extract operators and `clobbers`.

## These pages

- **[Install](/compiler/usage/install/)** — where the toolchain goes and how it finds its
  own libraries. Start here.
- **[Language reference](/compiler/language/)** — syntax, types, classes, protocols, ARC,
  collections, threading, modules, inline assembly. Each page carries a worked example that
  compiles and runs.
- **[Standard library](/compiler/api/)** — the classes shipped with the compiler, with
  method signatures and example usage.
- **[Compiler usage](/compiler/usage/)** — CLI flags, optimisation levels, allocator and
  memory-model selection, banking, and linker scripts.
- **[Future work](/compiler/future-work/)** — what's next, and what's known-incomplete.

Prebuilt binaries for macOS, Linux and Windows are on the [Downloads](/compiler/downloads/) page.
