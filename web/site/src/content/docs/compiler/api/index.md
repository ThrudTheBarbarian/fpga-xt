---
title: Standard library
description: Classes shipped with the xtc compiler — I/O, math, timing, heap introspection, interrupts, assertions, sorting.
---

The xtc standard library is a set of `.xt` classes that ship alongside the compiler. Each class is `#import`-able by name; methods are predominantly `static`, so most calls look like `Stdio.print("hi\n")` or `Math.rand()` with no instance needed.

## Where the files live

```
support/
  generic/lib/        ← platform-agnostic classes (work on every target)
    Foundation.xt       ← umbrella: Object + Number + String + Data + Array + Map + Set
    Object.xt           ← the runtime's root class
    Number.xt  String.xt  Data.xt  Array.xt  Map.xt  Set.xt  Memory.xt
    Comparable.xt  Hashable.xt  Enumerable.xt   ← protocols
    Assert.xt  Sort.xt
  atari/lib/          ← Atari-specific classes
    Stdio.xt  Math.xt  Time.xt  Heap.xt  System.xt  Vbi.xt  FILE.xt
    Gfx.xt  Gfx6.xt  Gfx7.xt  Gfx8.xt  Gfx15.xt  GfxFactory.xt   ← graphics (not yet documented)
    mapData.xt  symbols.xt                                       ← (not yet documented)
  arm64/lib/          ← host (arm64) target: Stdio / Math / Time / Heap / FILE
  6502/asm/           ← 6502 assembly runtime (mul/div, heap, float) — not .xt classes
```

The compiler's `#import` machinery searches platform-specific paths first, then falls through to `generic/lib/`, so a class with the same name in both wins on the active platform. That's how `Stdio.xt` gets per-platform implementations — and how Foundation ships two builds behind one API: a 32-bit one in `generic/lib/` and a 6502-tuned one in `xt6502/lib/`. Files with no width in them (`Object`, `Comparable`, `Sort`, the `Foundation` umbrella) exist once and are shared by both.

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
| [`Foundation`](/compiler/api/foundation/) | value wrappers + containers: `Object`, `Number`, `String`, `Data`, `Array`, `Map`, `Set`, and the `Comparable` / `Hashable` / `Enumerable` protocols | `generic/lib/` (32-bit) and `xt6502/lib/` (6502) |
| [`Stdio`](/compiler/api/stdio/) | screen output, cursor positioning, formatted print | per-architecture `lib/` |
| [`Math`](/compiler/api/math/) | random numbers, square root, trig, log/exp/pow, constants | per-architecture `lib/` |
| [`Time`](/compiler/api/time/) | RTCLOK access, jiffy / second timing, busy-wait delays | per-architecture `lib/` |
| [`Heap`](/compiler/api/heap/) | heap allocator introspection (free, largest, total) | `atari/lib/` |
| [`Vbi`](/compiler/api/vbi/) | install / remove Vertical-Blank-Interrupt handlers | `atari/lib/` |
| [`System`](/compiler/api/system/) | process control (`exit`) | per-architecture `lib/` |
| [`Assert`](/compiler/api/assert/) | test-fixture assertion helpers; gated to no-ops by `-DNDEBUG` / `-DRELEASE` | `generic/lib/` |
| [`Sort`](/compiler/api/sort/) | in-place quicksort with a user-supplied comparator | `generic/lib/` |

The graphics classes (`Gfx`, `Gfx6`/`7`/`8`/`15`, `GfxFactory`), `FILE`, and the `mapData` / `symbols` helpers aren't on the site yet — they will land in a follow-up pass.

## A note on overload resolution by return type

xtc supports overloading by **return type** for zero-arg static methods, and the standard library exploits this for `Math.rand()` and the math constants. `auto x = Math.rand();` is ambiguous; the compiler needs to know what type you want:

```c
u8     a = Math.rand();      // resolves to the u8 overload
u16    b = Math.rand();      // resolves to the u16 overload
float  c = Math.rand();      // resolves to the float overload
double d = Math.rand();      // resolves to the double overload
```

Same for `Math.PI()`, `Math.E()`, etc. — each has a `float`-returning and a `double`-returning overload, picked by the receiving variable's type.
