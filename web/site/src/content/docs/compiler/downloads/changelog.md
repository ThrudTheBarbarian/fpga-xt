---
title: ChangeLog
description: Release notes for the xtc toolchain — bug fixes and new features per version.
---

## Version 0.2 — five backends, shared libraries, bound methods

A new version line. 0.12 was the last of the AST code generator; **0.2** is the first of the
IR compiler, which replaces it entirely. The old code generator has been removed.

### Five backends, one IR

The compiler lowers to a single architecture-neutral IR and out through five live backends,
each passing the full fixture corpus:

| `-A` | Target | Output |
|---|---|---|
| `6502` *(default)* | banked **xt6502** — 4 KB hidden hardware stack, SP-relative addressing | Atari `.xex`, run under `xcc-sim-6502` |
| `arm64` | native macOS / Linux host | Mach-O / ELF executable |
| `arm9` | AArch32 / **XTOS** | ELF executable, or a `.so` |
| `m68k` | Atari ST | GEMDOS `.tos`, run under `xcc-sim-68k` |
| `x86_64` | Linux (musl) | ELF executable |

Standard-library classes resolve by **architecture × platform**, so one source serves all of
them.

The Atari `xl` / `xe` flat and PORTB memory models, and the Commodore `c64` target, are
**retired**.

### Shared libraries — `--emit-lib` and `#import <Lib>`

On `arm9`, a program can be split into a library and its clients:

```bash
xcc -A arm9 --emit-lib -o libXtg.so xtg.xc
xcc -A arm9 -L . -o app.so app.xc
```

The library carries its **own interface inside the `.so`**, so `#import <Xtg>` type-checks
the client against the real binary — there is no header to drift out of sync. Classes (with
inheritance and virtual dispatch back into a client subclass), protocols, structs by value,
enums (constants *and* type names), free functions, typedefs, `weak:` fields, bound methods,
and C types re-exported from *other* libraries all cross the boundary.

`#import <Foo>` also reads a plain **C** library's DWARF for its functions, types and enum
constants. (Build the C library with `-fno-eliminate-unused-debug-types` or gcc drops the
enum constants — see [Modules](/compiler/language/modules/).)

### Protocols across a `.so`

A protocol method is identified by its **index within its own declaration**, and the protocol
by a hash of its **name** — both derived identically by every module with no coordination. So
two libraries built in complete ignorance of each other compose, and a class conforming to a
protocol from each dispatches correctly through both.

### Bound methods (`^`) and optional protocol methods

`&obj.method` yields a storable, callable `{receiver, code}` value; a plain function or a
static method **widens** into the same type, so one `action` field takes any of them. A
stored `^` never owns its receiver and auto-zeroes when the receiver dies.

An `optional` protocol method may be left unimplemented, leaving a **null slot** — so testing
a `^` *is* `respondsTo`:

```c
act_t^ resized = &delegate.didResize;
if (resized) { resized(w, h); }
```

Together these make the delegate and target/action patterns work.

### `extern` globals

Globals are scoped to the module they are compiled in. `extern u16 gCounter;` refers to one
defined elsewhere without reserving storage for a second copy — which is what an imported
library's globals need.

### `weak:` without a table

Weak slots are threaded onto an **intrusive list** whose head lives in the referent's own
heap header. No capacity limit (the old bounded side table is gone, along with its
`[weak] entries` knob), O(1) stores, and destroying an object with **no** weak references
costs *one null test* instead of a full table scan. Works on a stored `^` too
(`weak: act_t^`).

### `final`

Opts a method back out of the vtable under `--emit-lib`, where whole-program devirtualisation
is unsound because the program isn't whole.

### Diagnostics

A long-standing habit of *degrading silently rather than refusing* has been swept out. A
store to a non-existent struct field, an unknown type name, an unresolvable imported type, and
a construct the lowering cannot express are now **errors**, not notes that let the build
succeed with the code quietly missing.

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

**Bank-register addresses are now layout-configurable.** Layouts may pin the bank-select hardware registers (previously hardcoded `$82`/`$83`/`$84`/`$85`) to any address — useful for cart-mapped designs that expose the bank latches outside zero page. The compiler, xcc-as preload-stub generator, and xcc-sim-6502 simulator all honour the layout's choice.

**Graphics:**

- `Gfx7` — GR.7 (160×96 4-colour) shipped with bulk-byte hline / vline fast paths
- `Gfx15` — GR.15 (160×192 4-colour) shipped with the same bulk-byte path
- `gfxCreate(mode, textRows)` factory in `GfxFactory.xc`, with `GFX_<w>_<h>_<b>` aliases (`GFX_320_192_1`, etc.) — picks the right subclass and returns a `Gfx@` for polymorphic use. Best called as `inline:gfxCreate(MODE, ROWS)` when the mode is a compile-time constant: the asm-level branch-elimination then drops the dead subclass arms (~5 KB savings on a typical factory call)
- `Gfx.clear()` hoisted to the base so it dispatches through `Gfx@`

**Other:**

- `inline:method()` on banked-heap (xe) now PORTB-brackets the inlined body
- Vtable reachability now uses the call-site × instantiation cross product, so dead vtable slots get zeroed instead of dangling
- Dead ARC retval stash/restore pairs are elided
- `xcc-as` warns on indirect-indexed addressing through a non-ZP operand
- `xcc-as` enforces split-bank size limits in `writeBankedXEX`

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
- xcc-sim-6502: keep SAVMSC at $8000 for explicit banked targets
- xcc-as: keep longbr trio together when previous line has its `; longbr` comment
- xcc-as: bank-page overflow handling
- stdio: use BOTSCR (1-based row count), not BOTSCR-1
- stdio: port scroll() into cloaked Stdio variant
- optimiser: incorrect CMP #$00 elision in for-in range loops
- foundation: Number lazy cross-kind cache + float-cast ivar store fix
