---
title: Heap, ARC & weak refs
description: "new and delete, automatic reference counting, weak: references, manual -farc=off mode."
---

xtc has a coalescing free-list heap with reference-counted ownership. It is available on any memory layout that declares a `[heap]` region — currently `xl-shadow`, `xe-nobank`, `xt`, `xe-heap`, and the `rambo*` / `compy*` extended-memory variants. On those targets `-falloc=heap` is the default; layouts without a `[heap]` region fall back to a bump allocator (heap-only statements are rejected at sema time).

Banked-heap targets reserve one or more 16 KB bank pages for the heap, and the runtime selects the appropriate bank on each allocator call transparently.

## Allocation

Three `new` forms cover scalar and array allocation for primitives, structs, and classes. Every successful `new` zero-fills the payload and initialises its reference count to 1:

```c
MyClass@ p   = new MyClass();       // class instance — init() runs
MyClass@ q   = new MyClass(4, 2);   // parameterised init
RGB@ pixel   = new RGB;             // struct scalar
u8@ buf      = new u8[128];         // array of primitives
MyClass@ mob = new MyClass[8];      // array of class instances
```

`new T[N]` is the only way to allocate an array on the heap. For arrays of class instances, every element is zero-filled and its `init()` runs. On out-of-memory, `new` returns null — callers that care should check.

## Automatic reference counting (ARC)

By default (`-farc` is on), the compiler manages reference counts automatically. Every heap block carries a 4-byte header immediately before the payload:

- 15-bit size
- 1 free-flag bit
- 16-bit retain count

The compiler emits retain / release operations at the right places:

| Event | What the compiler emits |
|-------|--------------------------|
| `Foo@ a = new Foo()` | take the allocator's +1; no extra retain |
| `Foo@ b = a` | a borrowed read → retain `a`'s pointee |
| `var = expr` | release the old pointee; retain the new one (if borrowed), or absorb the +1 (if `expr` is a value producer like `new` or a function call) |
| **scope exit** | release every tracked strong class-pointer local, LIFO |
| **class dealloc** | when refcount hits zero, the aggregate walker releases every strong class-pointer ivar recursively before returning the bytes to the free list |

Two calling-convention rules follow from those:

- **Always-`+1` returns.** A function whose return type is a class pointer hands the caller an owning reference. The caller doesn't have to retain — the callee did.
- **Callee-retains-params.** A class-pointer parameter is retained on function entry and released on exit. Net-neutral if the body only uses the pointer transiently; a store that outlives the call (into a global, into another heap object's field) automatically picks up the +1 the retain provided.

Under ARC, the manual `retain`, `release`, and `delete` statements are **rejected at sema time** — the compiler points you to the `-farc=off` escape hatch (below) if you really need them. In normal code you never write them.

### A canonical walk-through

```c
void work(void) {
    Foo@ a = new Foo();   // take allocator's +1.
    Foo@ b = a;           // a borrowed read → retain; refcount = 2.
    a = new Foo();        // release old-a, absorb new +1.
                          //   old-a refcount → 1 (b still holds it).
                          //   new-a refcount = 1.
    // scope exit:
    //   release b → old-a refcount → 0 → dealloc;
    //   release a → new-a refcount → 0 → dealloc.
}
```

## The dealloc callback

When a class-pointer's refcount reaches zero, the class's `dealloc(void)` method runs **before** the bytes are returned to the free list. Every class gets an auto-generated empty `dealloc` stub; classes that own external state override it:

```c
class Buffer {
    u8@ bytes;
    u16 len;

    void init(u16 n) {
        bytes = new u8[n];
        len   = n;
    }

    void dealloc(void) {
        // bytes is a strong class-pointer ivar — the aggregate walker
        // releases it automatically. Override dealloc only for things
        // the compiler can't see (hardware, logging, cache invalidation).
    }
}
```

Releasing an array of class instances (an allocation from `new T[N]`) walks the block and calls `dealloc()` once per element before freeing the whole thing. `dealloc` runs **exactly once** when the last owning reference is dropped — never earlier, never twice.

## Weak references

Pure reference counting leaks on cycles. If `Parent` owns `Child` strongly and `Child` carries a back-pointer to `Parent`, each instance's refcount stays at 1 after every external reference drops — they keep each other alive forever. xtc's answer is the `weak:` qualifier:

```c
class Child {
    weak:Parent@ dad;     // non-owning back-pointer
    u8 tag;
}

class Parent {
    Child@ kid;           // strong, owning
    u8 tag;
}
```

A `weak:T@` slot holds a raw pointer but is **invisible to refcounting** — assigning to it doesn't retain, releasing the pointee doesn't consult it. Instead the runtime tracks every live weak slot in a bounded side table; when a refcount reaches zero, the dealloc path walks the table and writes `$00` through every slot pointing at the dying block. Reads of the slot after that return null.

```c
Parent@ p = new Parent();
p.kid = new Child();
p.kid.dad = p;                   // weak: no retain on p.
// Parent refcount = 1 (held by p).
// Child  refcount = 1 (held by p.kid).
p = (Parent@)0;                  // p's release cascades:
//   Parent refcount → 0; dealloc fires.
//     Aggregate walker releases Parent.kid.
//       Child refcount → 0; dealloc fires.
//         Walker processes Child.dad — it's weak, so the
//         walker just unregisters the slot from the side
//         table. No decref.
//     Child freed.
//   Weak walker zeroes any external weak refs to Parent.
//   Parent freed.
// No leak, no dangling pointer — dad would have read as null
// even if we'd stashed it somewhere before p's release.
```

Weak slots come in all the shapes a strong pointer can take:

```c
weak:Foo@ g;                     // module-scope global
weak:Foo@ local;                 // stack-resident local
weak:Foo@ arr[8];                // stack array of weak slots
class Observer {
    weak:Subject@ target;        // ivar
}
```

### Rules and limits

- **Class pointers only.** `weak:u8@` and similar are rejected at compile time — the side table keys on heap-block addresses, and non-class pointers don't own heap blocks with refcount headers.
- **Use `weak:banked:T@` when the pointee is itself banked.** Bare `weak:T@` in a class ivar means "whatever placement the target uses for a bare T@". On banked-heap layouts that's a 2-byte implicit-bank pointer — fine for ivars holding heap-placement pointees. If you need a per-instance bank byte in the weak slot (because the pointee really is `banked:T@`), say so explicitly.
- **Cycle-detection is your responsibility.** There is no automatic cycle collector; the `weak:` annotation is how you tell the compiler which edge in a cycle is the non-owning one.
- **Reading is a plain pointer read.** A non-null weak slot is guaranteed to point at a live block (the side table is updated eagerly *before* the block's dealloc runs), so `if (w != 0) ...` is sufficient — no special `weak_load` primitive.

### Side-table sizing

The side table is bounded. By default it holds 64 entries; each entry accounts for one declared weak slot (arrays contribute their element count). If the static count of weak declarations in your program exceeds the capacity, sema emits a warning at compile time. To raise the cap, add a `[weak]` section to your `.lnk`:

```ini
[weak]
entries = 128       # default 64; max 255
```

The maximum is **255**. Internally the runtime stores entries across six parallel byte-wide tables (obj lo / hi / bank, slot lo / hi / bank) indexed by the entry number, and the scan loops terminate on `CPX #WEAK_TABLE_ENTRIES / BEQ done` — an 8-bit immediate compare, which is why 256 doesn't fit. Footprint is `6 × N` bytes in main RAM, so the default 64 costs 384 bytes and the ceiling 255 costs 1530 bytes.

## Manual lifecycle (`-farc=off`)

Users who want explicit lifecycle management can opt out with `-farc=off` on the command line. In that mode:

```c
retain ptr;     // refcount++ (saturates at $FFFF, null-safe)
release ptr;    // refcount--; on reach 0 → dealloc + free
delete ptr;     // alias of release — single decrement, not unconditional free
```

The semantics of `retain` and `release` match what ARC emits internally. Both are null-safe; `retain` saturates at `$FFFF` rather than wrapping, so pathological loops can't underflow through zero and trigger spurious frees. `delete` is kept as a deprecated alias for `release`; new manual-mode code should prefer `release` for clarity.

Manual mode and ARC mode are **mutually exclusive per compile** — you can't mix automatic tracking with explicit retain / release in the same program.

## Introspection

The `Heap` library class (`#import <Heap.xt>`) exposes static helpers for inspecting the allocator's state at runtime:

| Method | Type | Meaning |
|--------|------|---------|
| `Heap.size()` | `u32` | total free bytes available across every reserved bank, including 4-byte per-block header overhead |
| `Heap.largest()` | `u16` | size of the biggest single free extent. First-fit can't satisfy a request larger than this even if `size()` is bigger |
| `Heap.totalSize()` | `u32` | compile-time heap capacity (summed across all reserved banks) |

## Limits

- **A single block cannot exceed 16 KB** — that's the size of the bank page holding the heap. Multi-bank layouts (rambo*, compy*) hold more *in total*, but no one allocation spans a bank boundary.
- **Retain counts saturate at `$FFFF`** (65535). Effectively unlimited for normal ownership patterns; not a defect to be worked around with additional retains.
- **Weak-reference side table defaults to 64 entries**; max 255 (see above).
- **On `xt` and `xe-heap`,** any function or method that touches a heap pointer (direct deref, calling a method on a heap-allocated class, running a custom `dealloc`) must be annotated `:main`. A `:banked` function runs with its own bank selected, so the heap bank wouldn't be visible during the call.
