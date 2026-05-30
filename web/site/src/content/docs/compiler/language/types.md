---
title: Types
description: Primitives, struct, enum, pointers, arrays, type inference, casting.
---

## Primitive types

| Type | Size | Meaning |
|------|------|---------|
| `u8`, `i8` | 1 byte | 8-bit unsigned / signed integer |
| `u16`, `i16` | 2 bytes | 16-bit unsigned / signed integer |
| `u32`, `i32` | 4 bytes | 32-bit unsigned / signed integer |
| `float` | 5 bytes | binary floating-point: 1 sign byte + 1 signed binary exponent + 3-byte (24-bit) mantissa with implicit leading 1 |
| `double` | 8 bytes | binary floating-point: same shape as `float`, with a 48-bit mantissa for ~15 digits of precision |
| `bool` | 1 byte | alias of `u8`; values are `true` and `false` |
| `void` | — | absence of value (function returns, parameter list `(void)`) |
| `string` | 2 bytes | alias of `u8@` (pointer to null-terminated bytes) |
| `pointer` | varies* | arbitrary pointer-to-type |

*: On the Atari 8-bit range, pointers are 3-bytes: {lo, hi, bank}, but on larger machines they are the appropriate native size, arm64 uses 8-byte pointers, for example.

Truncation rules are predictable:

- Assigning a wider integer to a narrower one **truncates**, with no sign-extension.
- Assigning a `float` or `double` to an integer transfers the **integral part** only — truncated toward zero (`(i32)3.7` is `3`, `(i32)-3.7` is `-3`). Magnitudes that overflow the destination's i32 range saturate to `0`; `(u8)200.5` first goes to `i32`-via-`fpToI32` then narrows, so an out-of-range float silently lands as `0` instead of an undefined high byte.

## Structs

Structs gather related data into a packed value type. On the 6502 they are packed byte-aligned because the 6502 is byte-oriented, other architectures use their natural alignment. Structs have copy semantics — they are passed and returned by value.

```c
typedef struct {
    u16 x;
    u8  y;
} CursorPos;

CursorPos topRight = {319, 0};
CursorPos middle   = {159, 100};
```

Initialisers may use `{ ... }` or `[ ... ]` interchangeably. Members listed in declaration order; any omitted trailing members are zero-filled. Providing more elements than the struct holds is a compile-time error.

A struct can be returned by value:

```c
CursorPos centre(void) {
    CursorPos c = {160, 96};
    return c;
}
```

But you may **not** return a pointer to a stack-resident struct — the storage goes away when the scope ends:

```c
CursorPos@ bad(void) {
    CursorPos c = {1, 2};
    return &c;        // illegal — c dies at scope exit
}
```

Passing a `&struct` as an argument to another function is fine because the receiver only holds the pointer for the duration of the call.

`Stdio.printf` understands `%@` to recursively format a struct's members.

## Enumerations

```c
enum suits = {hearts, clubs, diamonds, spades};
enum directions = {N = 4, S, E, W};      // 4, 5, 6, 7
```

Enumerations start at 0 unless an explicit value is given; subsequent entries increment by 1. The compiler picks the smallest unsigned type that holds every value.

## Arrays

```c
u8 cakes[3];
u8 spaces[]  = {' ', '\t', '\n'};        // size inferred from initialiser
u16 scores[8] = {100, 87};               // remaining 6 slots zero-filled
```

Array size is part of the type; if an initialiser is provided, the size in `[ ]` may be omitted.

### Range initialiser

Fixed-size arrays of integer-element type also accept a range expression as the initialiser:

```c
u8 buf[10] = 0..10;       // 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
u8 b2[5]   = 1...5;       // 1, 2, 3, 4, 5  (inclusive)
u16 b3[4]  = 100..104;    // 100, 101, 102, 103  (each stored as u16)
i8  b4[3]  = -2..1;       // -2, -1, 0
```

Both bounds must constant-fold and the produced count must match the declared `elementCount`; size mismatches and non-literal bounds are rejected at compile time. The element type must be an integer scalar — float / struct / class arrays still need the `{ ... }` form.

The codegen unrolls the initialiser into one `LDA #$.. / STA $..` pair per element-byte (so a `u16 buf[4]` produces 8 stores). For globals the bytes are baked into the data section instead.

### `.length`

Both fixed-size arrays and heap-allocated pointers expose a `.length` pseudo-property of type `u16`:

```c
u16 local[8];
u16 n1 = local.length;        // compile-time constant: 8

u16@ heap = new u16[64];
u16 n2 = heap.length;         // runtime: read from heap header → 64
```

`.length` on a non-heap pointer (a `T@` that didn't come from `new T[N]`) is undefined — the codegen reads whatever bytes happen to live before the pointer. Bump-allocator targets store no header, so `.length` is meaningful only on heap-allocator targets (`xl-shadow`, `xe-nobank`, `xt`, `xe-heap`, the rambo / compy family).

## Pointers

Pointer syntax uses `@` instead of C's `*`. The variable is 'at' a place in memory. Whitespace around `@` is irrelevant — these all declare the same pointer-to-`u8`:

```c
u8@ p;
u8 @p;
u8 @ p;
```

`&` takes the address of a value, just like C:

```c
u8  myVal = 42;
u8@ myPtr = &myVal;
```

Pointer-literals and dereferencing both use `@` as a prefix:

```c
u8@ x = $400;        // x points at address $400
@x  = 4;             // store 4 at $400
u8  v = @x;          // load from $400

volatile u16@ dosvec = @10;     // 16-bit pointer-literal at address 10
@dosvec = $1234;
@dosvec = $4567;     // both stores happen even at -O2+ (volatile)
```

The `->` operator is sugar for "dereference and reach a member": `p->x` is `(@p).x`. Unlike C, **`.` on a pointer-to-struct or pointer-to-class also works** — the compiler auto-dereferences. Class-typed receivers conventionally use `.` because a class instance is almost always reached through a pointer (`sprite.draw()` reads more naturally than `sprite->draw()`).

## Casting

Casting uses C's `(type)` syntax:

```c
u16 n = (u16)x;
```

Two extensions handle class-pointer traffic:

- `(Dog@) animal` — runtime-checked downcast. On mismatch the program traps (`BRK`).
- `(Dog@ ?) animal` — failable downcast. On mismatch yields `(Dog@)0`; on success yields the retyped pointer. Pair with an `if (d != 0)` guard.

Upcasts, same-class casts, and non-class-pointer casts are unaffected. The full story is on the [Inheritance & protocols](/compiler/language/inheritance/) page.

## Type inference: `auto`

The `auto` keyword infers a variable's type from its initialiser.

```c
auto x = 3;          // u8
auto x = -3;         // i8
auto x = 257;        // u16
auto x = -259;       // i16
auto x = 65589;      // u32
auto x = -555_555;   // i32
auto x = 4.5;        // float
auto x = "hi";       // string (u8@)
auto x = true;       // bool
```

Integer literals pick the smallest type that holds them; positive values become unsigned, negative values become signed.

Inference also follows expressions and function returns. The result type widens where necessary:

```c
u8 a = 4, b = 5;
auto c = a + b;       // c is u8

u8 a = 4; u16 d = 500;
auto e = a + d;       // e is u16  (widened)

// given:  u8 fn(void) { ... }
auto v = fn();        // v is u8
```

Explicit types are still preferred — `auto` is for cases where the expression makes the type obvious and a redundant restatement would be noise.

## Type aliases: `typedef`

Any type can be aliased to a shorter or more meaningful name:

```c
typedef u16   Tick;
typedef u8@   bytes;
typedef RGB[] palette;
```

Aliases are transparent — `Tick` and `u16` are interchangeable in every context.

## Protocols

A `protocol` is a named interface — a list of method signatures with no bodies. Protocols and class conformance are covered on [Inheritance & protocols](/compiler/language/inheritance/); the type-system view is simply that a protocol name used in a type position (typically as a pointer, e.g. `Drawable@`) accepts any conforming class instance.
