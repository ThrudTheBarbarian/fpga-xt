---
title: ChangeLog
description: Release notes for the xtc toolchain — bug fixes and new features per version.
---

## Unreleased — new-IR backend + new-xt core (in development)

This work lives in the active development tree and is **not in a released
build** — the [downloads](/downloads/) are still the 0.12 AST-codegen
compiler. It tracks a ground-up reimplementation of the code generator
around an architecture-neutral IR plus a redesigned 6502 target, so the
items below are progress notes, not shipped features.

### New-IR pipeline

A new **architecture-neutral IR** sits between the semantic analyser and
code generation, with pluggable backends. Two exist today:

- **arm64** — a native macOS / Linux backend that runs the lowered IR
  directly. Its job is fast, end-to-end validation (and `lldb` debugging)
  of the arch-neutral lowering; it's also the first step toward genuinely
  native targets (e.g. an ARM microcontroller).
- **xt6502** — the new-xt 6502 core (below). Codegen here is mid-flight.

Libraries now resolve by **architecture × platform**: the backend's CPU
tree (`support/arm64/lib`, the 6502 runtime) is searched alongside the
board / OS platform (`support/atari/lib`, `support/commodore/lib`) and the
arch-neutral `support/generic/lib`. The 6502 runtime asm moved out of
`support/generic/asm` into a 6502-arch tree (`support/6502/asm`);
`generic/` is now arch-neutral content only.

### New-xt 6502 core (SALLY embellishments)

The `xt` target is being redesigned around a **custom FPGA 6502** with a
**4 KB hidden hardware stack** (12-bit SP), **SP-relative addressing**
(`LDA/STA d,SP`, `ADC/SBC/CMP d,SP`), and newer **indirect / indexed
SP** modes (`(d,SP),Y` to dereference a stack-resident pointer in place,
`d,SP,X` for indexed in-frame aggregates). This replaces the old
three-window bank-switched `xt` described under [Memory models](/compiler/usage/memory-models/).

### Fixes shaken out along the way

- arm64: short-circuit `||` / `&&` / `?:` evaluated one side
  unconditionally — a `CondBranch` phi-copy clobbered the branch condition
  register before the test.
- arm64: pointer equality compared only the low 32 bits, so `p == null`
  (and any pointer `==`/`!=`) could be wrong on 64-bit hosts.
- protocol / virtual dispatch: the vtable slot numbering disagreed between
  sema and the lowering, so a call could land on the wrong method body.
- inline-`asm{}` references to xtc locals now bind to the local's storage
  instead of leaking as undefined symbols.
- Foundation `Map` / `Set` slot tags compare the full pointer rather than a
  `(u16)` truncation that could alias a live 64-bit key onto the
  empty/tombstone sentinels.

## Version 0.12

### New features

The headline change is **3-byte heap pointers on banked-heap layouts**. A heap pointer now carries its bank byte alongside lo/hi, so a class instance, struct, or array allocated in any heap bank can be passed, returned, stored as an ivar, or stashed in a collection without losing track of which bank it lives in. The migration touched every codegen path that moves a heap pointer — ARC retains/releases, member access, ivar stores, multi-return tuples, downcasts, weak slots, stack-array zero-init / scope-exit walkers, subscript stores (const- and dyn-indexed), chained writes (`o.mid.leaf = …`), Foundation `Array` / `Map` / `Set` storage. Programs running on `xt`, `rambo*`, `compy*`, and `xe-heap` can now spread their object graph across the full heap without trampolining through main RAM.

The **bank-switch bracket optimiser** was widened across many more multi-byte field-access patterns:

- width=2 path-A bracket gate
- multi-byte heap-pointer field reads
- width=4 global-base banked field reads
- ARC field stores + struct copies
- multi-byte banked-store clusters (ExprAssign, ExprMembers)
- width=2 / width=4 dyn-banked-array reads
- xe-family bracket coverage

Each one shaves a save/restore around bank-select registers when the cluster shares a bank. The cumulative effect is meaningfully fewer cycles per banked field touch on real programs.

**Bank-register addresses are now layout-configurable.** Layouts may pin the bank-select hardware registers (previously hardcoded `$82`/`$83`/`$84`/`$85`) to any address — useful for cart-mapped designs that expose the bank latches outside zero page. The compiler, xta preload-stub generator, and xts simulator all honour the layout's choice.

**Graphics:**

- `Gfx7` — GR.7 (160×96 4-colour) shipped with bulk-byte hline / vline fast paths
- `Gfx15` — GR.15 (160×192 4-colour) shipped with the same bulk-byte path
- `gfxCreate(mode, textRows)` factory in `GfxFactory.xt`, with `GFX_<w>_<h>_<b>` aliases (`GFX_320_192_1`, etc.) — picks the right subclass and returns a `Gfx@` for polymorphic use. Best called as `inline:gfxCreate(MODE, ROWS)` when the mode is a compile-time constant: the asm-level branch-elimination then drops the dead subclass arms (~5 KB savings on a typical factory call)
- `Gfx.clear()` hoisted to the base so it dispatches through `Gfx@`

**Other:**

- `inline:method()` on banked-heap (xe) now PORTB-brackets the inlined body
- Vtable reachability now uses the call-site × instantiation cross product, so dead vtable slots get zeroed instead of dangling
- Dead ARC retval stash/restore pairs are elided
- `xta` warns on indirect-indexed addressing through a non-ZP operand
- `xta` enforces split-bank size limits in `writeBankedXEX`

### Bug fixes

- codegen: `_virtual_dispatch` tail switched from `JMP (__vt_call_vec)` to self-modifying `JMP $0000` (the indirect form hit the 6502 `JMP ($XXFF)` page-crossing bug at -O3 on xl-shadow / xe-nobank)
- codegen: pin vtable targets to `:main` — virtual dispatch is not bank-aware
- codegen: pre-allocate ZP for inline-asm `(name),Y` operands
- codegen: `_method_call_tramp` routes region-C receivers via `$84`/`$85`
- codegen: `emitMethodDispatch` receiver bank source for heap-w3
- codegen: `_xcall_*_resume` preserves Y across the trampoline
- codegen: bank packer estimator counts long-branch rewrites
- codegen: heap-w3 for-in stores result + bank source for spilled receiver
- codegen: heap-w3 ZP-resident struct field loads slot+2 bank
- codegen: heap-w3 pointer null-check tests lo+hi (was lo only)
- codegen: heap-w3 borrowed-init retain on 3-byte strong class pointer
- codegen: widen narrow call return when target type is wider
- codegen: gate `_cast_op_bank` emit on heap-w3 cast site
- foundation: `Map.contains` delegates to `get`; `Set.contains` uses if/else (avoids `&&` short-circuit bool-return path)
- foundation: `Gfx7.vline` pen=0 erase + colour overwrite

## Version 0.11

### New features

The headline addition is a Foundation-style class library: 
- an `Object` root class, 
- primitive wrappers (`Number` / `String` / `Data`)
- heterogeneous collectins `Array`, hash-based `Map` and `Set`
- the supporting `Comparable` / `Hashable` / `Enumerable` protocols

Autoboxing has been implemented, promoting primitives at `Object@` call sites with matching unboxing into primitive destinations. The language also gained:

- range-based `for-in` (`for (T i in start..end)`, with step and descending forms)
- array slicing (`arr[m..n]`, `arr[..n]`, `arr[m..]`)
- range expressions as fixed-array initialisers; 

To obtain pointers to banks used as data, the `bank(BANK_TYPE, idx)` is now a builtin and `raw:T@` pointer flavour landed. 

On the codegen side, cloaked code regions were extended across the full set of bank windows for a given target via its memory map layout, with transparent cross-region calls, an auto-overflow demote ladder, and same-region bracket elision, meaning that calls inside a bank to functions inside the same bank do not suffer any bank calling-convention penalty.

A new `xt-shadow-heap-regC` layout adds shadow main + region-C heap fallover, and the xt layout pyramid was restructured to promote the use of banking by default.

The toolchain now ships with a `-v/--version` flag which can help determine why your include file isnt being included.

### Bug fixes

- codegen: retbuf-aliasing and banked frame-save symbol leak
- codegen: per-region cloak tracker + xe-heap bank-0 cloak placement
- codegen: zero out vtable slots whose implementation was dropped by reachability
- codegen: preserve Z = retval-lo across banked-call trampolines
- codegen: float→int cast staging bugs
- codegen: drop stackRangeSet gate on auto-cloak; fix xe-heap dispatch
- driver: -H path sanitisation, search-path diagnostics, ASCII output mode
- driver: sanitise XTC_HOME env var on Windows (strip quotes, normalise backslashes)
- driver: use strtoull in parseLongLongAddr for GNUstep portability
- sema: preserve resolved return type on implicit-self bare calls
- arc: set Y to heap_bank_first before stashing _arc_retval_bank
- banked: nested method-call trampoline + Number cross-kind equals
- xl-shadow: reserve screen RAM at $8000-$9FFF; ship Array.dealloc
- xts: keep SAVMSC at $8000 for explicit banked targets
- xta: keep longbr trio together when previous line has its `; longbr` comment
- xta: bank-page overflow handling
- stdio: use BOTSCR (1-based row count), not BOTSCR-1
- stdio: port scroll() into cloaked Stdio variant
- optimiser: incorrect CMP #$00 elision in for-in range loops
- foundation: Number lazy cross-kind cache + float-cast ivar store fix
