---
title: Standard library
description: Classes shipped with the xcc compiler — I/O, math, timing, heap introspection, interrupts, assertions, sorting.
---

The xcc standard library is a set of `.xc` classes that ship alongside the compiler. Each class is `#import`-able by name; methods are predominantly `static`, so most calls look like `Stdio.print("hi\n")` or `Math.rand()` with no instance needed.

## Where the files live

```
support/
  generic/lib/        ← portable classes: work on every target
    Foundation.xc       ← umbrella: Object + Number + String + Data + Array + Map + Set
    Object.xc           ← the runtime's root class
    Number.xc  String.xc  Data.xc  Array.xc  Map.xc  Set.xc  CharacterSet.xc
    Comparable.xc  Hashable.xc  Enumerable.xc  Copying.xc  Error.xc   ← protocols
    Thread.xc  Mutex.xc  Cond.xc  Sem.xc  Atomic.xc  ThreadLocal.xc  Pool.xc
    Assert.xc  Sort.xc
    Platform.xc         ← auto-included prelude
  arm64/lib/          ← macOS / Linux on 64-bit ARM
    Stdio.xc  Math.xc  Time.xc  Heap.xc  FILE.xc  Files.xc  Process.xc
    Gfx*.xc  GfxFactory.xc  Platform.xc
  x86_64/lib/         ← Linux (musl)
    Stdio.xc  Math.xc  Time.xc  Heap.xc  FILE.xc  Platform.xc
  win64/lib/          ← Windows; the rest comes from x86_64/ and generic/
    Platform.xc
  arm9/lib/           ← AArch32 / XTOS, plus the GEM app framework
    Stdio.xc  Math.xc  Time.xc  Heap.xc  FILE.xc  Files.xc  Process.xc  Runtime.xc
    GApplication.xc  GEvent.xc  XTGem.xc  Gfx*.xc  Platform.xc
  atarist/lib/        ← Atari ST / TT (m68k)
    Stdio.xc  Math.xc  Time.xc  Heap.xc  FILE.xc  Gfx*.xc  Platform.xc
  xt6502/lib/         ← the banked 6502
    Stdio.xc  Math.xc  Time.xc  Heap.xc  System.xc  Vbi.xc  FILE.xc  Memory.xc
    Array.xc  Map.xc  Set.xc  String.xc  Data.xc  Number.xc   ← 6502 Foundation build
    Enumerable.xc  Hashable.xc                                ← 6502-width protocols
    Gfx*.xc  GfxFactory.xc  mapData.xc  symbols.xc  Platform.xc
  xt6502/asm/         ← 6502 assembly runtime (mul/div, heap, float) — not .xc classes
  xt6502/layouts/     ← .lnk memory maps
  <target>/runtime/   ← the small C host runtime linked into native builds
```

In an **installed** toolchain this whole tree is `lib/xc/` under the install root
(`xc\` on Windows) — see [Install](/compiler/usage/install/). The paths above are
what a source checkout looks like; both resolve.

The compiler's `#import` machinery searches the active target's directory first, then falls through to `generic/lib/`, so a class with the same name in both wins on the active platform. That's how `Stdio.xc` gets per-platform implementations — and how Foundation ships two builds behind one API: a 32-bit one in `generic/lib/` and a 6502-tuned one in `xt6502/lib/`. Files with no width in them (`Object`, `Comparable`, `Error`, `Assert`, `Sort`, the `Foundation` umbrella) exist once and are shared by both; the width-bearing ones — the containers, plus `Hashable` and `Enumerable` — are duplicated. Every target except xt6502 uses the `generic/lib/` Foundation directly. The **threading** classes (`Thread`, `Mutex`, `Cond`, `Sem`, `Atomic`, `ThreadLocal`, `Pool`) live in `generic/lib/` too, but are a hard `#error` on xt6502 and m68k rather than a stub — see [Threading](/compiler/language/threading/).

`Platform.xc` is the odd one out: the compiler emits an implicit `#import "Platform.xc"` before every compilation, so it is the seam where a target's system bindings live and the user's source stays platform-agnostic. Every shipped copy is currently an empty placeholder.

:::caution[Not everything in `generic/lib/` is portable]
Everything in `generic/lib/` works on every target. `Memory.xc` used to sit there and did not — its bodies are inline **6502** assembly — so it now lives in `xt6502/lib/` where it belongs. There is deliberately no placeholder: importing it on another target is a missing-class error naming the file, which is a better outcome than a class that compiles and silently does nothing.
:::

## How `static` makes calling concise

Most library methods are `static`. You can call them three ways:

```c
#import <Stdio.xc>

void main(void) {
    Stdio.print("explicit\n");      // class.method()
}
```

```c
#import <Stdio.xc>

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
| [`Memory`](/compiler/api/memory/) | bulk `memset` / `memclr` / `memcpy` / `memmove` | `xt6502/lib/` — **xt6502 only** |

Not on the site yet, and landing in a follow-up pass: the graphics classes (`Gfx`, `Gfx6`/`7`/`8`/`15`, `GfxFactory`), `FILE` (a `stdio`-shaped file layer, on both live targets), and the `mapData` / `symbols` helpers.

:::note[Not every class exists on every target]
The `Where` column is load-bearing. A class present only under `xt6502/lib/` is a compile error on the native backends — `#import <System.xc>` does not resolve at all under `-A arm64` — and a class present in both may still expose a narrower API on one of them. The per-class pages call out where the two diverge.
:::

## A note on overload resolution by return type

xcc supports overloading by **return type** for zero-arg static methods, and the standard library exploits this for `Math.rand()` and the math constants. `auto x = Math.rand();` is ambiguous; the compiler needs to know what type you want:

```c
u8     a = Math.rand();      // resolves to the u8 overload
u16    b = Math.rand();      // resolves to the u16 overload
float  c = Math.rand();      // resolves to the float overload
double d = Math.rand();      // resolves to the double overload
```

Same for `Math.PI()`, `Math.E()`, etc. — each has a `float`-returning and a `double`-returning overload, picked by the receiving variable's type.
