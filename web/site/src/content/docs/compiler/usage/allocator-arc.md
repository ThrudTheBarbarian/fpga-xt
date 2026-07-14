---
title: Allocator & ARC
description: Picking between -falloc=bump and -falloc=heap, and between -farc=on automatic and -farc=off manual reference counting.
---

xtc has two orthogonal flags that shape how heap allocation behaves:

- **`-falloc=bump|heap`** — picks the *allocator*. Bump is fast and one-way; heap supports `delete` / `release`.
- **`-farc=on|off`** — picks the *lifecycle policy*. ARC-on emits retains and releases automatically; ARC-off leaves lifecycle to the user.

The two flags compose. The defaults (`heap` on layouts with a `[heap]` region; `arc=on` everywhere) are the right answer for most programs; reach for the others when your program has a specific reason.

## Allocator: `-falloc=bump|heap`

```bash
xtc -falloc=bump tiny.xt -o tiny.xex
xtc -falloc=heap full.xt -o full.xex
```

### Bump allocator

```c
u8@ buf = new u8[256];          // bump pointer advances by 256
// ... use buf ...
// no free — the bytes stay allocated for the rest of the program
```

A **bump allocator** reserves space by simply advancing a pointer. Allocation is dirt cheap (a 16-bit add and a bounds check). Deallocation doesn't exist — `delete` is rejected at sema time, ARC has nothing to call into. When you run out of room, you stop.

Use bump when:

- The program allocates a fixed set of long-lived buffers up front and never needs to free.
- Binary size is at a premium and the heap allocator's coalescing logic isn't worth the bytes.
- You're targeting a layout that doesn't have a dedicated `[heap]` region.

The bump allocator is **always available** — every layout supports it. It's also the **default** on layouts without a `[heap]` region.

### Heap allocator

```c
u8@ buf = new u8[256];
// ... use buf ...
delete buf;                     // returns the bytes to the free list
```

The **heap allocator** is a coalescing free-list — every allocation carries a 4-byte header (15-bit size, 1 free bit, 16-bit retain count), and every free returns the block to the list and merges it with adjacent free blocks if any exist. Allocation cost is O(free-block count) for first-fit traversal; free is O(1) for the release plus O(neighbour) for coalescing.

Use heap when:

- The program needs to free and reuse memory.
- Class instances come and go (heap classes need `dealloc`, which needs `release`, which needs the heap allocator).
- The program needs the `Heap.size()` / `Heap.largest()` / `Heap.totalSize()` introspection helpers.

The heap allocator is **available on any layout that declares a `[heap]` region** — the shipped 6502 `xt` layouts do — and on all four native backends. On those targets `-falloc=heap` is the default. A layout without a `[heap]` region falls back to bump and rejects heap-only constructs (`delete`, `release`, the introspection helpers) at sema time.

### Mixing

You can't. The allocator choice is global per compile — `-falloc` is a single flag, not a per-class toggle. If you need both behaviours in one program, pick `heap` and use static / register variables for things you'd otherwise bump.

## Reference counting: `-farc=on|off`

```bash
xtc -farc=on   game.xt -o game.xex      # default
xtc -farc=off  game.xt -o game.xex      # manual lifecycle
```

ARC and the manual mode are **mutually exclusive per compile** — you can't mix them in the same program.

### `-farc=on` — automatic (default)

The compiler emits retains and releases at the right places: when one slot is initialised from another (`Foo@ b = a;` → retain), at scope exit (release every tracked strong class-pointer local, LIFO), inside aggregate dealloc (release every strong class-pointer ivar before bytes return to the free list), and so on. **You never write `retain` or `release`** — those statements are rejected at sema time.

Function calling convention follows from the emit rules:

- A function returning a class pointer hands the caller a `+1` reference. The caller doesn't have to retain.
- A class-pointer parameter is retained on entry and released on exit. Net-neutral for transient use; a store that outlives the call automatically picks up the `+1` the retain provided.

Full mechanics are on [Heap, ARC & weak refs](/compiler/language/memory/).

### `-farc=off` — manual

```c
Foo@ p = new Foo();             // arrives with refcount 1
Foo@ q = p;                     // q holds a *borrowed* reference
retain p;                       // refcount 2
// ... share / pass around ...
release p;                      // refcount 1
release q;                      // refcount 0 → dealloc → free
```

Manual mode disables every automatic retain / release the compiler would emit under ARC. The user writes `retain` / `release` (or the deprecated `delete` alias) explicitly.

The semantics of `retain` and `release` are identical to what ARC emits internally — both are null-safe, and `retain` saturates at `$FFFF` rather than wrapping, so pathological loops can't underflow through zero and trigger spurious frees.

Use manual mode when:

- You're integrating with a hand-written runtime that has its own lifecycle rules.
- You want explicit control for a specific lifecycle pattern (large pool, short-lived ownership transfer, etc.) and the ARC emit pattern doesn't match.
- You're debugging a refcount mismatch and want to single-step retains / releases manually.

For the vast majority of code, ARC is the right choice — it eliminates an entire class of bugs (forgotten releases, double frees, dangling references via cycles when paired with `weak:`) at the cost of a few JSRs the program would have emitted anyway.

## The compose table

|             | `-farc=on` (default) | `-farc=off` |
|-------------|----------------------|-------------|
| `-falloc=heap` | **The default for capable layouts.** Allocator manages the heap; compiler manages refcounts. Write `new`; everything else is implicit. | Allocator manages the heap; user writes `retain` / `release`. |
| `-falloc=bump` | New allocations succeed but nothing is ever freed. ARC retains / releases happen but no `dealloc` runs at refcount 0 (allocator can't reclaim). Use only if you intentionally want a leak-by-design. | New allocations succeed; user has no way to free. Effectively the same as ARC-on. |

In practice the diagonal — `bump + arc=on` — is the unusual one and should only be picked deliberately. The natural pairings are `heap + arc=on` (default ergonomic build) and `heap + arc=off` (heap with hand-written lifecycle).

## Stack allocations are unaffected

Both flags only govern **heap** allocation. Stack-allocated class instances (`MyClass mine;` rather than `MyClass@ p = new MyClass();`) live in the enclosing scope's local storage; their lifetime is the scope, not the refcount. ARC mode doesn't change them, allocator choice doesn't change them — they're free, they're predictable, and they're always reused at scope exit.

For a refresher on stack vs heap class allocation, see [Classes → Two ways to allocate](/compiler/language/classes/#two-ways-to-allocate).
