---
title: Types
description: The fixed-width scalars, structs, enums, pointers, arrays, type inference and casting.
---

## Primitive types

| Type | Size | Meaning |
|------|------|---------|
| `u8`, `i8` | 1 byte | 8-bit unsigned / signed integer |
| `u16`, `i16` | 2 bytes | 16-bit unsigned / signed integer |
| `u32`, `i32` | 4 bytes | 32-bit unsigned / signed integer |
| `u64`, `i64` | 8 bytes | 64-bit unsigned / signed integer |
| `float` | 4 bytes | IEEE-754 binary32 |
| `double` | 8 bytes | IEEE-754 binary64 |
| `bool` | 1 byte | alias of `u8`; values are `true` and `false` |
| `void` | — | absence of value (function returns, parameter list `(void)`) |
| `string` | pointer | alias of `u8*` (pointer to null-terminated bytes) |
| `pointer` | target-defined | typeless pointer |

Every width is the same on every target — a `u32` is four bytes on the 6502 as
well as on arm64. Only **pointers** vary: 3 bytes on the banked xt6502 (`{lo, hi,
bank}`), 8 bytes on the 64-bit hosts, 4 on arm9/m68k. Code that needs the number
should use `sizeof(T*)` rather than a baked-in constant.

Floating point is **IEEE-754 on every target**, including the 6502, where the
arithmetic is done by a software runtime. The bespoke 5-byte format the compiler
once used is gone; a literal carries IEEE bytes from the lexer all the way to the
back end.

### `i64` / `u64` and the narrow targets

64-bit arithmetic works on the 64-bit hosts — `arm64`, `x86_64`, `win64`. The
narrow targets (`xt6502`, `m68k`, `arm9`) **refuse** it with a diagnostic rather
than miscompiling it. They still report `sizeof(i64)` as 8, because width is a
layout contract and capability is not: a struct containing an `i64` must lay out
identically everywhere even where you cannot do arithmetic on the field.

### Conversions

- Assigning a wider integer to a narrower one **truncates**, with no sign
  extension.
- Assigning `float`/`double` to an integer takes the **integral part**, truncated
  toward zero: `(i32)3.7` is `3`, `(i32)-3.7` is `-3`. Magnitudes that overflow
  the destination saturate to `0`.
- **Same-width arithmetic stays at that width.** There is no C-style promotion to
  `int`, so `u8 + u8` wraps at 8 bits. Only genuinely mixed-width operands widen
  (`u8 + u16` → `u16`). To get a wider result, widen the *operands*:

```c
// types.xc — the scalar types, integer width rules, and pointers.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    // Widths are in the name. i = signed, u = unsigned.
    //   i8/u8  i16/u16  i32/u32  i64/u64   bool   float   double
    // `string` is an alias for u8*.
    u8  small = (u8)200;
    u16 mid   = (u16)60000;
    i32 wide  = (i32)-100000;
    u64 huge  = (u64)1 << (u64)40;      // 64-bit works on every target
    // printf's width contract: %d is 16-BIT and %ld is 32-bit, and both are
    // signed — which is why 60000 in a u16 prints as -5536. Cast to the width
    // you want to see.
    Stdio.printf("u8=%d u16=%d (as i32 %ld) i32=%ld\n", small, mid, (i32)mid, wide);
    Stdio.printf("2^40 = %ld:%ld (hi:lo)\n", (u32)(huge >> (u64)32), (u32)huge);

    // Same-width arithmetic stays at that width: u8 + u8 wraps at 8 bits, so
    // 200 + 100 is 44 rather than 300. There is no C-style "promote everything
    // to int" step.
    u8 a = (u8)200, b = (u8)100;
    u8  wrapped = a + b;                 // 300 & 0xFF = 44
    // Widening the DESTINATION does not help — `u16 w = a + b;` is still a u8
    // add, and still 44. To get the true sum, widen the OPERANDS.
    u16 widened = (u16)a + (u16)b;       // 300
    Stdio.printf("u8 200+100 -> %d   widened -> %d\n", (u16)wrapped, widened);

    // Literal prefixes: $ hex, % binary, _ ignored anywhere in a literal.
    u16 hex = $BEEF;
    u8  bin = %1010_0101;
    u32 big = 1_000_000;
    Stdio.printf("hex=%ld bin=%d big=%ld\n", (i32)hex, (u16)bin, big);

    // Pointers use *, & takes an address, -> is sugar for (*p).field.
    u16 value = (u16)1234;
    u16* p = &value;
    Stdio.printf("*p = %d\n", *p);
    *p = (u16)4321;
    Stdio.printf("value now %d\n", value);

    // The sigil binds to the TYPE, so this declares TWO pointers — unlike C,
    // where `u16* x, y` gives you a pointer and an integer.
    u16* x, y;
    x = &value; y = &value;
    Stdio.printf("both pointers: %d %d\n", *x, *y);

    // bool, and float/double.
    bool ok = true;
    float f = 1.5;
    double d = 3.1d;
    Stdio.printf("bool=%d float=%f double=%lf\n", ok ? (u16)1 : (u16)0, f, d);
    return 0;
}
```

```
u8=200 u16=-5536 (as i32 60000) i32=-100000
2^40 = 256:0 (hi:lo)
u8 200+100 -> 44   widened -> 300
hex=48879 bin=165 big=1000000
*p = 1234
value now 4321
both pointers: 4321 4321
bool=1 float=1.500000 double=3.1000000000
```
