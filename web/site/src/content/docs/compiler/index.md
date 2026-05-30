---
title: xtc
description: The compiler for 'xt' — an ObjC-like language that compiles to 6502, with bank switching, classes, and ARC, plus the xta assembler and xts simulator.
---

**xtc** is an ObjC-like language that compiles to 6502 assembly for the Atari 8-bit family amongst other targets. On machines that need it, it treats bank-switched RAM as a first-class resource — programs spread code and data across paged windows and grow well beyond normal RAM limits, with the compiler deciding what lives where — and the language provides Classes (single
inheritance from a root class, with Protocols for cross-class behaviour), and automatic reference counting on top of fixed-width types to optimise the best performance out of machines from 8 to 64 bits.

For the Atari 8-bit ranges, the toolchain presents as a cross-compiler with three pieces: **xtc**, the compiler (`.xt` source → 6502 assembly, or straight to a runnable Atari `.xex`); **xta**, a two-pass assembler that emits XEX with RUNAD/INITAD and banked preload; and **xts**, a headless simulator that runs `.xex` files with the same memory-model semantics the codegen targets.

These pages cover the language and its toolchain:

- **[Language reference](/compiler/language/)** — syntax, types, memory models, classes, inheritance,
  ARC, and inline assembly. Start here for *what xtc is*.
- **[Standard library](/compiler/api/)** — the classes shipped under `support/lib/`, with method
  signatures and example usage — *what's already built for you*.
- **[Compiler usage](/compiler/usage/)** — CLI flags, optimisation levels, allocator and memory-model
  selection, banking, and linker scripts — *how to get the best output*.
- **[Future work](/compiler/future-work/)** — the in-progress back-end rebuild around an
  architecture-neutral IR with pluggable backends: a native arm64 backend and a redesigned FPGA 6502
  core with a hidden hardware stack.

Prebuilt binaries for macOS, Linux, and Windows are on the [Downloads](/downloads/) page.
