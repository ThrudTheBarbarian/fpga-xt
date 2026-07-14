---
title: Heap
description: Introspection helpers for the coalescing free-list heap allocator.
---

`Heap` exposes three static helpers for inspecting the allocator's state at runtime — total free bytes, the size of the biggest single free extent, and the compile-time heap capacity. All methods are `static`.

```c
#import <Heap.xt>
```

`Heap` is meaningful only under `-falloc=heap` — the default on the 6502 `xt` layouts and on every native backend. On a bump-allocator target the allocator keeps no free-list metadata, so `size()` and `largest()` would return misleading values.

## Methods

```c
static u32 size(void);               // current free bytes (across every reserved bank)
static u16 largest(void);            // biggest single contiguous free extent
static u32 totalSize(void);          // compile-time heap capacity (constant)
```

```c
u32 free  = Heap.size();
u16 max   = Heap.largest();
u32 total = Heap.totalSize();

Stdio.printf("heap: %lu free of %lu (largest extent: %u)\n", free, total, max);
```

## Why the types differ

- **`size()` and `totalSize()` are `u32`** because a multi-bank heap easily exceeds 64 KB. The 6502 `xt` heap grows on demand across the data window's 256 pages — up to 3 MB.
- **`largest()` is `u16`** because a single free extent cannot span a bank boundary — it's bounded by the flat region size or one 16 KB bank, both of which fit in 16 bits.

## What "free" means

All three counts are in **bytes** and **include** the 4-byte per-block header (2-byte size + 2-byte retain count) that the allocator stores in front of every allocation. A `new u8[100]` therefore consumes **104** bytes from the `size()` total, not 100.

## Use it for "will my allocation fit?"

`size()` reports total free bytes summed across every free extent. First-fit allocation can't satisfy a request larger than the **largest** single extent, even if `size()` is much bigger — fragmentation can leave you with plenty of total free and nothing usefully large.

```c
if (Heap.largest() < (u16)needed + 4) {
    Stdio.print("not enough contiguous heap; bailing\n");
    return;
}
u8@ buf = new u8[needed];
```

The `+4` accounts for the per-block header overhead; if you forget it the allocator will refuse the request even though `largest()` says yes.

## Performance

- `size()` walks the free list in every reserved bank — O(free-block count). Safe to call often, but not free.
- `largest()` walks the same lists with a running max — same cost class as `size()`.
- `totalSize()` is a linker-resolved constant (`heap_total_bytes`) emitted at build time. **Free at runtime.**
