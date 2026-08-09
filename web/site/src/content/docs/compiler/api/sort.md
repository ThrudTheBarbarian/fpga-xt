---
title: Sort
description: In-place quicksort with a user-supplied comparator.
---

`Sort` is an in-place quicksort over a `u16` array, with the ordering supplied by a user-written comparator function. The standard C `qsort` convention applies — the comparator returns negative / zero / positive for less / equal / greater. The class lives under `support/generic/lib/`, so it works the same on every platform.

```c
#import <Sort.xc>
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
static void qsort(u16* base, u16 n, cmpU16_t* cmp);
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

## A historical caveat: global arrays

`Sort.xc`'s own header comment still warns that `base` must be a **local** array — that global array names decay to pointers with a corrupted high byte, so `Sort.qsort(globalArr, …)` silently reads the wrong memory.

That no longer reproduces. Sorting a module-scope `u16[]` gives the correct result on **both** live backends (arm64 and xt6502), at `-O0` and at the default `-O3`:

```c
u16 g[4] = {4, 1, 3, 2};

void main(void) {
    Sort.qsort(g, (u16)4, &ascending);
    // 1 2 3 4
}
```

The warning is left in the library source and recorded here because it was real; if you do see a global sort misbehave, that is the shape the old bug had, and it is worth reporting rather than working around.

## Recursion and the call stack

On **xt6502**, `Sort.qsort`'s internal driver is recursive, so it allocates its frame on the software stack rather than taking the static-frame fast path — the codegen marks recursive functions ineligible for it. Non-recursive comparators stay eligible, so the comparator itself costs no more than an indirect `JSR`. On the register targets the frame is an ordinary stack frame and none of this applies.

For arrays of thousands of elements, watch the depth: worst-case quicksort is O(N) deep on already-sorted input. The xtc stack is tunable with the `-ss` / `--stack-size` flag if you need more headroom.
