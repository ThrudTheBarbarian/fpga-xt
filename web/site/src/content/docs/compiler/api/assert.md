---
title: Assert
description: Test-fixture assertion helpers; gated to no-ops by -DNDEBUG / -DRELEASE.
---

`Assert` is a small set of test-assertion helpers used by xtc's own test fixtures and available to user code. Each assertion increments a test counter; failures increment a separate failure counter and print `FAIL T<n>` so the run-fixtures shell script can scan for them. `Assert.summary()` prints `DONE <count>` at the end of a run, plus a `FAIL <m> tests` line if anything failed.

```c
#import <Assert.xt>          // generic — works on every platform
```

`Assert.xt` lives under `support/generic/lib/`, not an architecture directory — it works the same on every target.

## Release-build gating

Compile with `-DNDEBUG` or `-DRELEASE` and **every method body in this class becomes a no-op**. The class and its method signatures still exist, so your call sites compile unchanged — you don't have to wrap each `Assert.*(...)` call in `#ifdef`.

At `-O2` and above, the leaf inliner strips the empty-bodied calls entirely, making the asserts **zero-cost at runtime** in release builds. At `-O0` the calls still emit a JSR through the empty stub, which is fine for the cases where `-O0` is being used anyway.

## Core assertions

```c
static void isTrue(bool ok);
static void isFalse(bool ok);
```

Every other assertion funnels through `isTrue` so the counter bookkeeping and the `FAIL T<n>` print live in one place.

```c
Assert.isTrue(1 + 1 == 2);
Assert.isFalse(needle == 0);
```

## Equality and inequality

`isEqual` and `isNotEqual` are overloaded across the common scalar widths.

```c
static void isEqual(u16 a, u16 b);
static void isEqual(u32 a, u32 b);
static void isEqual(i16 a, i16 b);
static void isEqual(i32 a, i32 b);

static void isNotEqual(u16 a, u16 b);
static void isNotEqual(u32 a, u32 b);
```

```c
Assert.isEqual(counter, (u16)42);
Assert.isEqual(timestamp, (u32)1234567);
Assert.isNotEqual(scoreA, scoreB);
```

## Pointer checks

```c
static void isNull(pointer p);
static void isNotNull(pointer p);
```

```c
Foo@ f = lookup(name);
Assert.isNotNull(f);
```

## Range and ordering

```c
static void isInRange(u16 v, u16 lo, u16 hi);   // lo <= v <= hi
static void isLess(u16 a, u16 b);
static void isGreater(u16 a, u16 b);
```

```c
Assert.isInRange(angle, (u16)0, (u16)360);
Assert.isLess(elapsed, (u16)budget);
```

## Summary and reset

```c
static void summary(void);           // print "DONE <count>" and any failures
static void reset(void);             // zero both counters
```

`summary()` prints a `DONE <count>` line and, if any assertions failed, a `FAIL <m> tests` line. Like every other method on `Assert`, it's a no-op in release builds.

```c
void main(void) {
    Assert.isEqual(1 + 2, (u16)3);
    Assert.isInRange((u16)50, (u16)0, (u16)100);
    Assert.isNotNull("abc");
    Assert.summary();                // DONE 3
}
```

## Accessors

```c
static u16 testCount(void);          // 0 in release builds
static u16 failCount(void);          // 0 in release builds
```

Useful when you want to gate post-test cleanup on whether anything failed. **Accessors return 0 in release builds** even if there were live calls in earlier code; either gate your own logic on the build flavour, or simply don't read these in release.
