---
title: Sort
description: In-place quicksort with a user-supplied comparator.
---

`Sort` is an in-place quicksort over a `u16` array, with the ordering supplied by a user-written comparator function. The standard C `qsort` convention applies — the comparator returns negative / zero / positive for less / equal / greater. The class lives under `support/generic/lib/`, so it works the same on every platform.

```c
#import <Sort.xt>
```

## Comparator type

```c
typedef i16 cmpU16_t(u16, u16);
```

Define your own comparator with that signature:

```c
i16 ascending(u16 a, u16 b) {
    if (a < b) { return (i16)-1; }
    if (a > b) { return (i16)1; }
    return (i16)0;
}

i16 descending(u16 a, u16 b) {
    return ascending(b, a);
}
```

### Why `i16` and not `i8`?

The same reason C's `qsort` uses `int`: xtc's codegen currently treats `i8` call results as **unsigned** when they're consumed directly by a relational operator (`cmp(x, y) < 0`), so an `i8` comparator with the obvious `< 0` test would silently never fire on negative returns. Using `i16` sidesteps the issue. Routing the result through a named local before the test is the alternative workaround, but `i16` is simpler.

## The sort

```c
static void qsort(u16@ base, u16 n, cmpU16_t@ cmp);
```

```c
void main(void) {
    u16 arr[8] = {7, 2, 9, 1, 5, 8, 3, 6};
    Sort.qsort(arr, (u16)8, &ascending);
    for (u16 v in arr) {
        Stdio.printf("%u ", v);
    }
    Stdio.print("\n");                       // 1 2 3 5 6 7 8 9
}
```

The implementation is a recursive Lomuto-partition quicksort with the pivot at the high end of the partition. No auxiliary buffers — sorting is in place.

## Caveat: arrays must be local

`base` must be a **local** array. Global array names currently decay to pointers with a corrupted high byte, so:

```c
u16 g[8] = {…};                     // global

void main(void) {
    Sort.qsort(g, (u16)8, &ascending);   // ⚠ silently reads wrong memory
}
```

…compiles but reads garbage at runtime. Until the codegen lifts that restriction, the workaround is to copy the array into a local before sorting:

```c
u16 g[8] = {…};

void main(void) {
    u16 local[8];
    for (u16 i = 0; i < 8; i = i + 1) {
        local[i] = g[i];
    }
    Sort.qsort(local, (u16)8, &ascending);
    // …copy back if needed…
}
```

## Recursion and the call stack

`Sort.qsort`'s internal driver is recursive, so it allocates its frame on the **xtc software stack** rather than the 6502 hardware stack — the codegen's stage-4c eligibility pass marks recursive functions ineligible for the static-frame fast path. Non-recursive comparators stay static-frame eligible under the stage-2 CFA pass, so the comparator itself adds no per-call overhead beyond an indirect JSR.

For arrays of thousands of elements, watch the depth: worst-case quicksort is O(N) deep on already-sorted input. The xtc stack is tunable with the `-ss` / `--stack-size` flag if you need more headroom.
