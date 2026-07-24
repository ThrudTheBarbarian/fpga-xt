---
title: Standard library
description: Classes shipped with the xtc compiler — I/O, math, timing, heap introspection, interrupts, assertions, sorting.
---

The xtc standard library is a set of `.xt` classes that ship alongside the compiler. Each class is `#import`-able by name; methods are predominantly `static`, so most calls look like `Stdio.print("hi\n")` or `Math.rand()` with no instance needed.

## Where the files live

```
support/
  generic/lib/        ← the portable Foundation (works on every target)
    Foundation.xt       ← umbrella: Object + Number + String + Data + Array + Map + Set
    Object.xt           ← the runtime's root class
    Number.xt  String.xt  Data.xt  Array.xt  Map.xt  Set.xt
    Comparable.xt  Hashable.xt  Enumerable.xt  Error.xt   ← protocols
    Assert.xt  Sort.xt  Memory.xt
    Platform.xt         ← auto-included prelude (empty on the generic target)
  xt6502/lib/         ← the banked-6502 target
    Stdio.xt  Math.xt  Time.xt  Heap.xt  System.xt  Vbi.xt  FILE.xt
    Array.xt  Map.xt  Set.xt  String.xt  Data.xt  Number.xt   ← 6502 Foundation build
    Enumerable.xt  Hashable.xt                                ← 6502-width protocols
    Gfx.xt  Gfx6.xt  Gfx7.xt  Gfx8.xt  Gfx15.xt  GfxFactory.xt   ← graphics (not yet documented)
    mapData.xt  symbols.xt  Platform.xt                          ← (not yet documented)
  xt6502/asm/         ← 6502 assembly runtime (mul/div, heap, float) — not .xt classes
  arm64/lib/          ← the native host target
    Stdio.xt  Math.xt  Time.xt  Heap.xt  FILE.xt
    Gfx*.xt  GfxFactory.xt  Platform.xt
```

The compiler's `#import` machinery searches platform-specific paths first, then falls through to `generic/lib/`, so a class with the same name in both wins on the active platform. That's how `Stdio.xt` gets per-platform implementations — and how Foundation ships two builds behind one API: a 32-bit one in `generic/lib/` and a 6502-tuned one in `xt6502/lib/`. Files with no width in them (`Object`, `Comparable`, `Error`, `Assert`, `Sort`, the `Foundation` umbrella) exist once and are shared by both; the width-bearing ones — the containers, plus `Hashable` and `Enumerable` — are duplicated. The arm64 target has no Foundation of its own and uses the `generic/lib/` build directly.

`Platform.xt` is the odd one out: the compiler emits an implicit `#import "Platform.xt"` before every compilation, so it is the seam where a target's system bindings live and the user's source stays platform-agnostic. Every shipped copy is currently an empty placeholder.

:::caution[Not everything in `generic/lib/` is portable]
`Memory.xt` lives there but its bodies are inline **6502** assembly — a program that calls `Memory.memset` / `Memory.memclr` fails to assemble on the native backends. Treat it as an xt6502 class that happens to sit in the shared directory. `Assert` and `Sort` really are portable.
:::

## How `static` makes calling concise

Most library methods are `static`. You can call them three ways:

```c
#import <Stdio.xt>

void main(void) {
    Stdio.print("explicit\n");      // class.method()
}
```

```c
#import <Stdio.xt>

use Stdio;                          // language-level promotion

void main(void) {
    print("bare-call\n");           // resolves to Stdio.print
}
```

```c
#use Stdio                          // preprocessor sugar:
                                    // #import + use in one line

void main(void) {
    print("shortest form\n");
}
```

Bare-call promotion (`use Stdio;` and the `#use` shorthand) is documented under [Classes → Bare-call promotion](/compiler/language/classes/#bare-call-promotion-use-classname) and [Preprocessor → `#use`](/compiler/language/preprocessor/#importing-and-promoting-a-class-use). These pages assume the explicit `Klass.method(...)` form because it's the unambiguous reference style; in your own code, pick whichever you prefer.

## What's documented here

| Class | Role | Where |
|-------|------|-------|
| [`Foundation`](/compiler/api/foundation/) | value wrappers + containers: `Object`, `Number`, `String`, `Data`, `Array`, `Map`, `Set`, and the `Comparable` / `Hashable` / `Enumerable` / `Error` protocols | `generic/lib/` (32-bit) and `xt6502/lib/` (6502) |
| [`Stdio`](/compiler/api/stdio/) | screen output, cursor positioning, formatted print | `xt6502/lib/`, `arm64/lib/` |
| [`Math`](/compiler/api/math/) | random numbers, square root, trig, log/exp/pow, constants | `xt6502/lib/`, `arm64/lib/` |
| [`Time`](/compiler/api/time/) | RTCLOK access, jiffy / second timing, busy-wait delays | `xt6502/lib/`, `arm64/lib/` (reduced) |
| [`Heap`](/compiler/api/heap/) | heap allocator introspection (free, largest, total) | `xt6502/lib/`, `arm64/lib/` |
| [`Vbi`](/compiler/api/vbi/) | install / remove Vertical-Blank-Interrupt handlers | `xt6502/lib/` only |
| [`System`](/compiler/api/system/) | process control (`exit`) | `xt6502/lib/` only |
| [`Assert`](/compiler/api/assert/) | test-fixture assertion helpers; gated to no-ops by `-DNDEBUG` / `-DRELEASE` | `generic/lib/` |
| [`Sort`](/compiler/api/sort/) | in-place quicksort with a user-supplied comparator | `generic/lib/` |
| [`Memory`](/compiler/api/memory/) | bulk `memset` / `memclr` / `memcpy` / `memmove` | `generic/lib/`, but **xt6502 only** (see above) |

Not on the site yet, and landing in a follow-up pass: the graphics classes (`Gfx`, `Gfx6`/`7`/`8`/`15`, `GfxFactory`), `FILE` (a `stdio`-shaped file layer, on both live targets), and the `mapData` / `symbols` helpers.

:::note[Not every class exists on every target]
The `Where` column is load-bearing. A class present only under `xt6502/lib/` is a compile error on the native backends — `#import <System.xt>` does not resolve at all under `-A arm64` — and a class present in both may still expose a narrower API on one of them. The per-class pages call out where the two diverge.
:::

## A note on overload resolution by return type

xtc supports overloading by **return type** for zero-arg static methods, and the standard library exploits this for `Math.rand()` and the math constants. `auto x = Math.rand();` is ambiguous; the compiler needs to know what type you want:

```c
u8     a = Math.rand();      // resolves to the u8 overload
u16    b = Math.rand();      // resolves to the u16 overload
float  c = Math.rand();      // resolves to the float overload
double d = Math.rand();      // resolves to the double overload
```

Same for `Math.PI()`, `Math.E()`, etc. — each has a `float`-returning and a `double`-returning overload, picked by the receiving variable's type.
