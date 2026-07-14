---
title: Future work
description: What's planned, in progress, and known-incomplete in xtc.
---

xtc is pre-1.0. This page tracks where it's going, what's known-incomplete, and what's
recently landed — sourced from the project's `doc/Issues` log. Pre-1.0 software is more
useful when its rough edges are visible than when they're hidden.

## Where things stand

The back-end rebuild that dominated the last stretch is **done**. The compiler lowers to a
single architecture-neutral IR and out through **five live backends** — xt6502, arm64, arm9,
m68k, x86_64 — and every one of them passes the full fixture corpus. The old AST code
generator has been removed; the IR pipeline is the only path.

On top of that, `arm9` grew a real module system: shared libraries, an interface that travels
*inside* the `.so`, and protocol dispatch that works between libraries built in complete
ignorance of each other. See [Modules & shared libraries](/compiler/language/modules/).

## What's next

1. **Graphics — the remaining modes.** `Gfx8` (GR.8), `Gfx7`, `Gfx6` and `Gfx15` ship with
   the full primitive set: plot/line, hline/vline, rect/fillRect, circle/oval/arc/pie + filled
   variants, bezier, drawText, floodFill, setupNative, setupSplit. The remaining Atari modes
   (GR.0–GR.5) are further `Gfx` subclasses; first deliverable per mode is line draw. `Gfx` is
   also **not ported to x86_64** — that target has no framebuffer to draw into.

2. **Shared libraries beyond arm9.** `--emit-lib` needs a dynamic loader, so today it is
   arm9-only; the other four targets are whole-program. Nothing in the design is
   arm9-specific — it is a matter of the target having somewhere to load a `.so`.

## Planned features

### Bank memory via pointer

Direct user-level access to bank pages, something like `u8@ data = bank(4);`. An escape hatch
to deliberately route reads and writes through a chosen bank when the compiler's automatic
placement isn't what you want.

### Intra-function banking

Banking is **function-granular**: a function lives in one bank. A single function larger than
a bank window (~22 KB) therefore cannot be placed at all. Splitting a function across banks
is the fix, and is not yet attempted.

### `inline:method()` on banked-heap targets

The inlined body's `(selfPtr),Y` accesses to receiver ivars need bank brackets so the read
lands in the heap's bank, matching what regular method dispatch already does via the call
wrapper. Needs care around nested inlines targeting different banks.

## Accepted limitations

These are tradeoffs in algorithm choice, not bugs — they won't be "fixed":

- **CORDIC trig** is ~14-bit accurate. Tests handle this via `APPROX_TOLERANCE`.
- **`fpTan` precision degrades near ±π/2** — inherent to the identity used.
- **NaN compares "equal"** per `fpCmp` — deterministic, non-IEEE.
- **A single 6502 heap block cannot exceed one bank** (~12 KB). Multi-bank layouts hold more
  *in total*, but no one allocation spans a bank boundary. By design.
- **A bound method (`^`) widened in two *different* modules compares unequal.** Two `^`s
  widened in the *same* module are always equal — which is the case that matters, since a
  program registers and unregisters its own callbacks. Closing the exotic case would need a
  canonical trampoline address, which the loader cannot provide.

## Recently shipped

- **Shared libraries (`--emit-lib`) and `#import <Lib>`.** A library carries its own
  interface inside the `.so`, so a client type-checks against the *real binary* rather than a
  header that may have drifted from it. Classes, protocols, structs (by value, in and out),
  enums (constants **and** type names), free functions, typedefs, `weak:` fields, bound
  methods, and C types re-exported from *other* libraries all cross the boundary.
- **Protocols across a `.so`.** A protocol method is identified by its index within its own
  declaration, and the protocol by a hash of its *name* — both derived identically by every
  module, with no coordination. Two libraries built in ignorance of each other compose, and a
  class conforming to a protocol from each dispatches correctly through both.
- **`extern` globals.** Globals are scoped to the module they are compiled in; `extern` refers
  to one defined elsewhere instead of silently defining a second copy.
- **Bound methods (`^`) and optional protocol methods.** `&obj.method` is a storable,
  callable `{receiver, code}` value, and a plain function *widens* into the same type. An
  unimplemented `optional` protocol method leaves a null slot, so testing a `^` **is**
  `respondsTo`. Together these make the delegate and target/action patterns work.
- **`weak:` without a table.** Weak slots are threaded onto an intrusive list whose head lives
  in the referent's own heap header — no capacity limit, O(1) stores, and destroying an object
  with *no* weak references costs **one null test** instead of a full table scan. Works on a
  stored `^` too (`weak: act_t^`), which is the idiomatic action field.
- **`final`.** Opts a method back out of the vtable under `--emit-lib`, where whole-program
  devirtualisation is unsound because the program isn't whole.
- **m68k and x86_64 backends.** Atari ST (with the `xst` simulator) and Linux/musl, both at
  full corpus parity.
- **The IR back-end rebuild, completed.** Architecture-neutral IR, ~21 optimisation passes,
  five backends, and the legacy AST code generator removed.
- **A differential fuzzer.** Generates random programs and compiles them through every
  backend; any divergence between two targets is a bug. It found seven the corpus had missed.
- **Collections.** `Array`, `Map`, `Set`, `String`, `Data`, `Number` and `Sort`, plus the
  `Comparable` / `Hashable` / `Enumerable` protocols, all under `support/generic/lib/` — one
  implementation shared by every backend.
- **Free-list heap allocator** with `_heap_init` / `_heap_alloc` / `_heap_free`. `delete ptr;`
  runs ARC `release()` walks before the block is freed; class arrays iterate release across
  every element. Gated by `-falloc=heap`.
- **Class inheritance, protocols and runtime downcasts.** Single-inheritance chains, virtual
  dispatch, `super.method(...)`, and runtime-checked `T@` downcasts (with the failable
  `(T@ ?)` form). See [Inheritance & protocols](/compiler/language/inheritance/).
- **Array slicing in for-in.** `arr[m..n]` / `arr[..n]` / `arr[m..]` / `arr[m...n]` produce a
  slice the for-in loop walks element by element, on fixed-size arrays and heap pointers
  alike; bounds may be runtime expressions.
- **`use Klass;` / `#use Klass`.** Static-method bare-call promotion: after `use Stdio;`, a
  bare `printf(...)` resolves to `Stdio.printf(...)`.

## Known issues

None outstanding at the time of writing. Bug reports through [the feedback form](/feedback/)
feed straight into the canonical `doc/Issues` log.
