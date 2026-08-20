---
title: Math
description: Random numbers, square root, trigonometry, log/exp/pow, and a complete set of float and double constants.
---

`Math` provides random-number generation, integer and floating-point arithmetic helpers, transcendental functions, and a full set of mathematical constants. All methods are `static`.

```c
#import <Math.xc>
```

The class makes heavy use of xcc's overloading by **return type** for zero-argument methods — `Math.rand()` and the constants like `Math.PI()` resolve based on the variable being assigned to. The compiler emits the version that produces the requested type.

## Random numbers

xcc's RNG is a small linear-feedback generator. By default it auto-seeds from the Atari hardware (`RANDOM` register at `$D20A`) at first use; you can also seed it explicitly.

```c
static void setSeed(u16 seed);       // re-seed the generator
static void step(void);              // advance the generator one tick
```

### Unbounded `rand()` overloads

```c
static u8     rand(void);
static u16    rand(void);
static u32    rand(void);
static float  rand(void);            // 0.0 ≤ x < 1.0
static double rand(void);            // 0.0 ≤ x < 1.0
```

```c
u8     b = Math.rand();              // 0..255
u16    w = Math.rand();              // 0..65535
u32    l = Math.rand();              // 0..2^32-1
float  f = Math.rand();              // 0.0 ≤ f < 1.0
double d = Math.rand();              // 0.0 ≤ d < 1.0
```

### Bounded `rand` overloads

```c
static u8  rand(u8 max);             // 0 ≤ x < max
static u8  rand(u8 lo, u8 hi);       // lo ≤ x ≤ hi
static u16 rand(u16 max);            // 0 ≤ x < max
static u16 rand(u16 lo, u16 hi);     // lo ≤ x ≤ hi
```

```c
u8  d6   = Math.rand((u8)1, (u8)6);          // dice roll
u16 cell = Math.rand((u16)40);                // 0..39
```

## Absolute value

```c
static i8     abs(i8 v);
static i16    abs(i16 v);
static i32    abs(i32 v);
static float  abs(float v);
static double abs(double v);
```

```c
i32 delta = Math.abs(target - current);
```

## Square root

```c
static float  sqrt(float v);
static double sqrt(double v);
```

```c
float hypot = Math.sqrt(dx * dx + dy * dy);
```

## Logarithms and exponentials

```c
static float  ln(float v);
static double ln(double v);
static float  exp(float x);
static double exp(double x);
```

`ln` is natural log (base `e`); `exp` is `e^x`. For other bases, multiply / divide by `Math.LN2()`, `Math.LN10()`, etc.

## Powers

`pow` is overloaded by exponent type — for integer exponents the integer-typed overload is much cheaper than the float-by-float version.

```c
static float  pow(float base, float power);
static float  pow(float base, i16 power);
static double pow(double base, double power);
static double pow(double base, i16 power);
static double pow(double base, i32 power);
static double pow(double base, u32 power);
```

```c
float r2 = Math.pow(r, (i16)2);              // squared, integer fast path
float v  = Math.pow((float)2.0, (float)0.5); // square root via pow
```

## Trigonometry

Angles are in **radians**. All four functions exist in both `float` and `double` precision.

```c
static float  sin(float angle);
static float  cos(float angle);
static float  tan(float angle);
static float  atan(float x);

static double sin(double angle);
static double cos(double angle);
static double tan(double angle);
static double atan(double x);
```

```c
float a = Math.PI() / 4;
float s = Math.sin(a);                       // ≈ 0.7071
float c = Math.cos(a);
```

## Constants

Both `float` and `double` versions of the standard constants are available; the compiler picks based on the assignment target.

| Method | Value |
|--------|-------|
| `Math.E()` | Euler's number |
| `Math.LOG2E()` | log₂(e) |
| `Math.LOG10E()` | log₁₀(e) |
| `Math.LN2()` | ln(2) |
| `Math.LN10()` | ln(10) |
| `Math.PI()` | π |
| `Math.PI_2()` | π / 2 |
| `Math.PI_4()` | π / 4 |
| `Math.INV_PI()` | 1 / π |
| `Math.TWO_PI()` | 2π |
| `Math.TWO_SQRTPI()` | 2 / √π |
| `Math.SQRT2()` | √2 |
| `Math.SQRT1_2()` | √(1/2) |

```c
float  pi_f = Math.PI();             // float overload
double pi_d = Math.PI();             // double overload
```

## A note on the float format

`float` is **IEEE-754 binary32** (4 bytes) and `double` is **IEEE-754 binary64**
(8 bytes), on every target including the 6502. A literal carries IEEE bytes from
the lexer through to the back end, so a value written in source, stored to a
file on one target and read back on another is bit-identical.

The bespoke 5-byte format xcc used to define (1 sign byte + 1 exponent byte +
24-bit mantissa) is **retired**; if you have code or data files that assume it,
they need converting.

**It is not the Atari OS math pack format either.** The Atari ROM uses
**BCD**-encoded floats with a 6-decimal-digit mantissa. xcc is pure binary,
which is far cheaper to multiply and divide on a CPU with no decimal arithmetic,
at the cost of needing a binary↔ASCII conversion to print.

On the register machines the arithmetic is native hardware floating point. On
xt6502 the hand-written routines in `support/xt6502/asm/float/` and
`support/xt6502/asm/double/` implement add, subtract, multiply, divide and the
math functions; the code generator emits `JSR` to them automatically, and links
only the ones a program actually reaches.

## Code-size gating

`Math.xc` uses conditional compilation extensively — every transcendental, the entire `double` family, the `pow` overloads, and the constants are gated behind feature flags (`ENABLE_DOUBLE`, `ENABLE_TRIG`, etc.) so a program that only needs `rand()` doesn't pay the binary cost of `sin` and `cos`. The defaults pull in everything; pass `-DENABLE_DOUBLE=0`, `-DENABLE_TRIG=0`, etc. to opt out per feature.

## Platform notes

`Math` is reimplemented per-architecture (`support/xt6502/lib/Math.xc`, `support/arm64/lib/Math.xc`, …). The API is the same everywhere — same overloads, same constants — and because both formats are IEEE-754, the bit-level layout of values is identical across targets. Only the helper routines differ.
