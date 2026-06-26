---
title: Future work
description: What's planned, in progress, and known-incomplete in xtc.
---

xtc is pre-1.0. This page tracks where it's going, what's known-incomplete, and what's recently landed — sourced from the project's `doc/Issues` log. Pre-1.0 software is more useful when its rough edges are visible than when they're hidden.

## The new-IR / new-xt redesign (current focus)

The largest in-progress effort is a ground-up rebuild of the back end. The shipping 0.12 compiler lowers the AST straight to 6502; the redesign inserts an **architecture-neutral IR** between the semantic analyser and code generation, with pluggable backends, and pairs it with a **redesigned 6502 core**.

- **Architecture-neutral IR + multiple backends.** Two backends exist today. An **arm64** backend runs the lowered IR natively on the host — its job is fast, end-to-end validation (and `lldb` debugging) of the arch-neutral lowering, and it's the first step toward genuinely native targets (an ARM microcontroller later). An **xt6502** backend targets the new core below. Standard-library classes resolve by **architecture × platform**, so the same Foundation source serves both. See the [changelog](/compiler/downloads/changelog/).
- **The new `xt` 6502 core.** A custom FPGA 6502 with a **4 KB hidden hardware stack** (12-bit stack pointer) and **SP-relative addressing** — `LDA/STA d,SP`, plus `(d,SP),Y` to dereference a stack-resident pointer in place and `d,SP,X` for indexed in-frame aggregates. This supersedes the old three-window bank-switched `xt` ([Memory models](/compiler/usage/memory-models/)); the point is to keep locals and temporaries in a real stack frame instead of cramming everything into zero page.

This is **in development** — not all of it compiles and runs end-to-end yet (the xt6502 backend's register/stack allocation is mid-flight). The 0.12 AST-codegen compiler remains the shipping toolchain for Atari `xl` / `xe` / `xt` in the meantime.

## What's next

Two roughly-equal-priority candidates:

1. **Graphics library — remaining Atari modes.** `Gfx` + `Gfx8` already cover GR.8 (320×192 1bpp) with the full primitive set: plot/line, hline/vline, rect/fillRect, circle/oval/arc/pie + filled variants, bezier, drawText, floodFill, setupNative, setupSplit. Remaining modes (GR.0-GR.7, GR.15) are additional `Gfx` subclasses; first deliverable per mode is line draw.

2. **Fuzzing.** A grammar fuzzer against `grammar/xtc.bnf` to generate random programs, compile through xtc + xta + xts, and flag any segfault / hang / FAIL. Up until now this has been by hand-rolled probes; a fuzzer would surface the next family of bugs before users hit it. 



## Planned features

### `inline:method()` on banked-heap targets (xe)

The xl/xt path works; xe-style banked-heap is deferred. The inlined body's `(selfPtr),Y` accesses to receiver ivars need PORTB brackets so the read lands in the heap's bank, matching what regular method dispatch already does via the call wrapper. Multi-day effort — needs care around nested inlines that may target different banks, and ARC retain/release of class-pointer params.

### Bank memory via pointer

Direct user-level access to bank pages, something like `u8@ data = bank(4);`. Gives source code an escape hatch to deliberately route reads/writes through a chosen bank when the compiler's automatic placement isn't what you want.

### Automatic GR.0 restore on program exit

Opt-in is already satisfied by `Gfx.restoreGR0()` — programs that took over the display via `Gfx8.setupNative()` can call it before `main` returns. The always-on variant (runtime exit shim does it for every program) is still open; the cost is dragging CIO into every program including console-only ones, plus a few hundred bytes of code. Could become opt-in via a compiler flag if it's worth it.

### Lots more library work

The main focus at this point, once Gfx is written for more than just GR.8, is 
going to be collection types (Array, Dictionary, Set,..) 

### Native ARM target (68k still speculative)

No longer purely speculative: the new-IR work (above) already has an **arm64 backend**, today used to validate the architecture-neutral lowering on the host. Turning that into a *shipping* native target — xtc programs running directly on, say, an RP2354 microcontroller — is the natural follow-on once the IR and its backends settle. A 68k backend remains speculative.


## Accepted limitations

These are tradeoffs in algorithm choice, not bugs — they won't be "fixed":

- **CORDIC trig** is ~14-bit accurate. Tests handle this via `APPROX_TOLERANCE`.
- **`fpTan` precision degrades near ±π/2** — inherent to the identity used.
- **NaN compares "equal"** per `fpCmp` — deterministic, non-IEEE.
- **C64 target compiles but doesn't run yet.** Output PRG isn't exercised under any sim in CI; VICE debugging is needed to validate. Atari targets are the focus, mainly because I don't have much experience with the C64.

## Recently shipped

A short window of "done in the last few months" so users tracking the project can see momentum:

- **Array slicing in for-in.** `arr[m..n]` / `arr[..n]` / `arr[m..]` / `arr[m...n]` produce a slice the for-in loop walks element-by-element, on both fixed-size arrays and heap pointers. Bounds may be runtime expressions; the inclusive form biases the cap by +1 at loop setup so the inner compare stays a plain `idx < cap`. See [Statements — for-in (array slice)](/compiler/language/statements/#for-in-array-slice).
- **Range as fixed-array initialiser.** `u8 buf[10] = 0..10` / `u8 b2[5] = 1...5` fills consecutive slots with the range values. Both bounds must constant-fold and the produced count must match the declared `elementCount`; sema rejects mismatches and non-literal bounds.
- **Extended cloaked code regions across the bank window.** Multi-region `[cloaked]` blocks in the layout: `bank = none` (banking-off region in main RAM) plus numbered-bank regions (`bank = 2` for canonical xe; `bank = 4-12` + `id = ext<n>` for the rambo / compy pool form). Source-level `:cloaked(<id>)` pins a decl; plain `:cloaked` auto-packs into the first declared region with an overflow-spill ladder onto subsequent regions before falling back to `:main`. Cross-region calls work via the `_xcall_cloaked` trampoline (caller_ret + caller PORTB stored in main-RAM static slots so the bank-window switch doesn't unmap the saved state). Same-region calls drop the PORTB bracket entirely — codegen emits a plain JSR. The shipped rambo / compy layouts expose 96 KB → 992 KB of cloaked surface depending on hardware. See [Linker scripts — `[cloaked]`](/compiler/usage/linker-scripts/#cloaked--code-regions-for-cloaked-decls).
- **Free-list heap allocator** with `_heap_init` / `_heap_alloc` / `_heap_free` on all four heap targets (xl-shadow, xe-nobank, xt, xe-heap). `delete ptr;` triggers ARC `release()` walks before block free; class arrays iterate release across every element. Banked-heap + full banked ARC end-to-end as of 2026-04-23. Gated by `-falloc=heap`.
- **Class inheritance + protocols + runtime downcasts.** Single-inheritance chains (`class Dog : Animal`), virtual dispatch through per-class vtables, `protocol Name` interface decls, `super.method(...)`, runtime-checked `T@` downcasts. See [Inheritance & protocols](/compiler/language/inheritance/).
- **xt region C / extended RAM.** Three independent bank windows in $4000-$7FFF: $82-routed code (8 KB pages, 2 MB), $83-routed data (4 KB pages, 2 MB), $84/$85-routed region C (4 KB pages, 4-28 MB on 8/16/32 MB HyperRAM). Pay-for-what-you-use is automatic via per-function transitive analysis. See [Memory models](/compiler/usage/memory-models/).
- **Multi-bank xt-with-heap correctness.** Seven distinct latent bugs fixed in one session — `$82` / `$83` routing in helpers, allocator-Y bank capture, ivar-store / chained-ivar-read / chained-method-call / delete-via-ivar paths in method bodies. Six new fixtures pin the regressions.
- **xe-banked heap-class methods.** Methods on heap classes can ride either `:cloaked` or `:banked` placement on xe-heap. Routes ivar `(self),Y` accesses through `_ivar_load_byte` / `_ivar_store_byte` so reads land in the receiver's heap bank even when the body's PORTB points elsewhere. Subsequent perf pass caches `_ivar_target_portb` once at body prologue — ~60 cycles saved per ivar access.
- **Auto-cloak inference + overflow-driven placement.** Sema infers cloak-safety per decl; codegen auto-promotes via `-fauto-cloak={never,auto,always}`. When `:main` passes 75% of budget the compiler proactively promotes more decls into `:cloaked`. When a cloaked region overflows the driver first spills overflow decls to the next declared cloaked region with headroom; only when no further region has space does it demote back to `:main`. Two-pass banked-spill on banked targets demotes coldest methods to `:banked` until main fits.
- **`Gfx` / `Gfx8` graphics library.** Context-based class hierarchy covering GR.8 with the full primitive set listed above. `Gfx8.line` is an asm fast-path for axis-aligned + 8 octants with phase-5 draw-from-both-ends.
- **`use Klass;` / `#use Klass`.** Static-method bare-call promotion: after `use Stdio;`, bare `printf(...)` resolves to `Stdio.printf(...)`. The hash form (`#use Klass`) is `#import "Klass.xt"` + `use Klass;` combined. Multiple `use` directives compose; ambiguity is a compile error.
- **xta symbol-file directory sweep.** The driver auto-loads every `.sym` under `support/<platform>/symbols/` and `support/generic/symbols/` into the assembler's symbol table. Drop a new `pokey.sym` next to `atari.sym` and its names resolve in inline asm without touching the linker script.
- **Driver introspection.** `--dump-placement` shows per-decl placement; `-du` / `--dump-usage` shows per-bank usage maps. Useful for budget tuning when hand-placing decls.

## Known issues

None outstanding at the time of writing. Bug reports through [the feedback form](/feedback/) feed straight into the canonical `doc/Issues` log.
