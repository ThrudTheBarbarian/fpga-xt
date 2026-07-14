---
title: Foundation classes
description: "Number, String, Data, Array — Object-style wrappers around primitive values plus the first heterogeneous container, the building blocks for Foundation-style collections."
---

`Number`, `String`, and `Data` are Object-style wrappers around xtc's primitives. `Array` is the first heterogeneous container — a NSMutableArray-style mutable list whose elements are `Object@` (any heap-class instance). The classes live under `support/generic/lib/` so they work on every platform.

```c
#import <Number.xt>
#import <String.xt>
#import <Data.xt>
#import <Array.xt>
```

For convenience, `Foundation.xt` is an umbrella that pulls in all four plus the `Comparable` protocol:

```c
#import <Foundation.xt>
```

All four inherit from the runtime's built-in `Object` root class — every parentless `class X` does — so a `Number@`, `String@`, `Data@`, or any user class fits anywhere an `Object@` is expected. No `: Object` annotation is needed in source.

All three need a real heap allocator (the `-falloc=heap` free-list path), which is the default on the 6502 `xt` layouts and on every native backend. A bump-only target rejects the `new u8[N]` calls these classes use internally.

## `Number`

A box around a single primitive value. Two storage kinds: integer (held bit-preserving as `i32`) and float (held as the native 5-byte `float`). The kind decides which `as*` getter is meaningful.

### Factories

The type-pinned factories spell out the source kind, so the call site always picks an unambiguous overload:

```c
static Number@ withI8(i8 v);
static Number@ withU8(u8 v);
static Number@ withI16(i16 v);
static Number@ withU16(u16 v);
static Number@ withI32(i32 v);
static Number@ withU32(u32 v);
static Number@ withFloat(float v);
```

Each returns a fresh `Number@` of the matching kind.

The shorter `with()` family is overloaded across the same primitive set; the compiler picks the right factory from the argument's type:

```c
static Number@ with(i8 v);     static Number@ with(u8 v);
static Number@ with(i16 v);    static Number@ with(u16 v);
static Number@ with(i32 v);    static Number@ with(u32 v);
static Number@ with(float v);
```

```c
Number.with((i16)42);          // routes to withI16
Number.with((float)3.14);      // routes to withFloat
```

The typed `withXxx` form remains useful when the source value is itself a literal whose type the compiler would infer differently — `Number.with(42)` defaults to whatever `42`'s minimal-fitting signed type is; cast or use `withI16(42)` if you need a specific kind.

### Setters

Same family as factories, but mutate an existing instance:

```c
void setI8(i8 v);    void setU8(u8 v);
void setI16(i16 v);  void setU16(u16 v);
void setI32(i32 v);  void setU32(u32 v);
void setFloat(float v);
```

The overloaded short form picks the right one from the argument:

```c
void set(i8 v);      void set(u8 v);    // (… one per primitive …)
void set(float v);
```

### Getters

```c
i8    asI8(void);      u8    asU8(void);
i16   asI16(void);     u16   asU16(void);
i32   asI32(void);     u32   asU32(void);
float asFloat(void);
```

The `value()` form is overloaded by **return type** rather than parameter type, so the compiler picks based on the destination context:

```c
i16  v = n.value();    // routes to asI16
float f = n.value();   // routes to asFloat
```

This relies on xtc's return-type-aware overload resolution (the same machinery `Math.rand()` uses to pick `i16` vs `float` from context). When the destination is ambiguous (e.g. an untyped expression context), spell out the typed `asXxx` form instead.

Same-kind retrieval is exact. Cross-kind (e.g. `asFloat` on an Int Number) reads the inactive field and returns whatever default was last written there — guard with `isInt()` / `isFloat()` first.

Within the integer kind, casts are bit-preserving: `Number.withU32($FFFFFFFF).asI32()` returns `-1`, and `Number.withI32(-5).asU16()` returns the low two bytes of the sign-extended `i32`. Same convention as the language-level `(i32)` / `(u32)` casts.

### Predicates and equality

```c
bool isInt(void);
bool isFloat(void);
bool equals(Number@ other);
bool equals(Object@ other);    // Comparable conformance
```

Same-kind comparison stays bit-exact: an Int / Int compare goes byte-for-byte through `_i`, a Float / Float compare uses the runtime float comparator. Cross-kind comparison promotes both sides through `asFloat()` and compares the resulting floats — `Number.withI16(42).equals(Number.withFloat(42.0))` is `true`, and a non-integer float never compares equal to any int (`Number.withI16(42).equals(Number.withFloat(42.5))` is `false`).

The `equals(Object@)` overload satisfies the `Comparable` protocol below — it safe-casts the argument to `Number@` and forwards to the typed equality, returning false on type mismatch.

## `Comparable` protocol

A single-method protocol that lets heterogeneous `Object@` collections compare elements by value:

```c
protocol Comparable {
    bool equals(Object@ other);
}
```

`Number`, `String`, and `Data` all conform. Reaching equality through a `Comparable@` pointer dispatches via the protocol's vtable, so a generic comparator doesn't need to know the concrete type:

```c
Comparable@ a = Number.withI16(42);
Comparable@ b = Number.withI16(42);
Stdio.printf("%u\n", a.equals(b));    // 1
```

Each conforming class's `equals(Object@)` safe-casts the argument back to its own type and returns false on mismatch — comparing a `Number` to a `String` is well-defined and yields false.

## `String`

A heap-owned, null-terminated byte buffer. Conforms to `Comparable`.

### Factory

```c
static String@ withCString(u8@ src);
```

Copies `src` (a null-terminated C-string — could be a string literal, a buffer the caller owns, etc.) into a fresh heap allocation. The copy includes the trailing `\0`. The String owns its own bytes from then on.

### Accessors

```c
u16 length(void);                // bytes before the trailing \0
u8  charAt(u16 idx);             // byte at idx, no bounds check
u8@ cString(void);               // raw pointer for use with %s / strcmp / …
bool equals(String@ other);      // byte-by-byte
bool equals(Object@ other);      // Comparable conformance — safe-casts to String@
```

`length` is cached at construction, so it's `O(1)`. `cString()` returns the underlying buffer, valid as long as the String is.

## `Data`

A heap-owned `(pointer, length)` byte block. Like `String` but without the null terminator and with no character-class operations — bytes are opaque. Conforms to `Comparable`.

### Factories

```c
static Data@ withBytes(u8@ src, u16 len);     // copy len bytes from src
static Data@ withCapacity(u16 len);           // zero-filled allocation
```

### Accessors

```c
u16 length(void);                            // declared length
u8@ bytes(void);                             // raw pointer
u8  byteAt(u16 idx);                         // byte at idx
void setByteAt(u16 idx, u8 value);           // mutate byte at idx
bool equals(Data@ other);                    // byte-by-byte
bool equals(Object@ other);                  // Comparable conformance — safe-casts to Data@
```

`bytes()` returns the underlying buffer; the caller can subscript it directly (`bytes()[i]`) or pass it to memcpy-style routines. Lifetime mirrors the Data instance.

## Why these three first

The intent is heterogeneous collections — `Array@`, `Dictionary@`, `Set@` — that hold mixed primitive values. xtc classes are heap-allocated objects, so a container that stores `T@` (class pointer) is the natural shape for a "list of things". `Number`, `String`, `Data` cover the three primitive-shapes the language doesn't already represent uniformly:

- `Number` collapses six integer types and `float` into a single Object-pointer.
- `String` adds Object identity to a `u8@` C-string.
- `Data` does the same for an arbitrary byte block.

Future container work can then accept `Object@` (or whichever common base / protocol comes out of that design) and hold any of these wrappers — plus user-defined classes — without per-container monomorphisation. Autoboxing (so user code can write `arr.add(42)` rather than `arr.add(Number.withI32(42))`) is a separate, deferred feature.

## `Array`

NSMutableArray-style mutable list of `Object@`. Elements are stored as 2-byte pointer bits in a heap-allocated buffer; capacity grows geometrically (starts at 8, doubles when full). The Array does NOT retain on add — the caller is responsible for keeping element objects alive (via separate strong references) until either the Array drops them or the Array itself is released. ARC-aware retain on add is a future addition.

### Construction

```c
static Array@ withCapacity(u16 cap);     // pre-sized; skips the first resize copy
```

`new Array()` returns an empty Array with capacity 0; the first `add` triggers a `_grow` that bumps capacity to 8.

### Querying

```c
u16     count(void);                     // current element count
u16     length(void);                    // alias of count
bool    isEmpty(void);                   // count == 0
u16     capacity(void);                  // allocated slot count
Object@ get(u16 i);                      // element at index, no bounds check
Object@ first(void);                     // get(0) or 0 when empty
Object@ last(void);                      // get(count-1) or 0 when empty
```

### Mutation

```c
void set(u16 i, Object@ obj);            // replace at index, no shift, count unchanged
void add(Object@ obj);                   // append, _grow if needed
void insert(u16 i, Object@ obj);         // insert at index, shift tail right
void removeAt(u16 i);                    // remove at index, shift tail left
void removeFirst(void);                  // removeAt(0)
void removeLast(void);                   // count--
void removeAll(void);                    // count = 0 (does not free buffer)
```

### Search

```c
u16  indexOf(Object@ obj);               // first match by pointer identity, or $FFFF
bool contains(Object@ obj);              // indexOf != $FFFF
```

`indexOf` and `contains` use **pointer identity**, not value equality — two distinct `Number(42)` instances compare unequal. Use a typed walk (loop + `((Number@)a.get(i)).equals(target)`) for value-equality matching.

### Example

```c
Array@ a = new Array();
Number@ n1 = Number.withI16(-42);
String@ s1 = String.withCString("hello");
a.add(n1);
a.add(s1);

for (u16 i = (u16)0; i < a.count(); i++) {
    Object@ o = a.get(i);
    Number@ n = (Number@ ?)o;            // safe-checked cast — 0 on type mismatch
    if (n != 0) Stdio.printf("number %d\n", n.asI16());
    else        Stdio.printf("non-number at %u\n", i);
}
```

Verified on every live backend — xt6502, arm64, arm9, m68k, x86_64 — at O0/O2/O3.
