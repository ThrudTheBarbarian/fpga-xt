---
title: Classes
description: Class declaration, instance and stack allocation, methods, init/dealloc, properties, static methods.
---

A class is a struct with state and behaviour — instance variables (ivars), methods, optional static methods, an `init` constructor, and a `dealloc` destructor. Classes are normally declared one per file, named `<classname>.xt` so `#import "Foo.xt"` resolves them, but the compiler does **not** enforce this — multiple classes may live in a single file, and the filename need not match the class name.

```c
class Gfx {
    u8 red;
    u8 green;
    u8 blue;

    void hLine(u16 x, u8 y, u8 len) {
        // …
    }
}
```

## Two ways to allocate

Pick whichever fits the lifetime — the syntax tells the compiler everything it needs.

In what follows, the **enclosing scope** of a declaration is the block — delimited by `{ }` or `(( ))` — that contains the declaration. That's usually a function body, a loop body, or a branch of an `if` or `switch`. When the closing brace executes, the variable falls out of scope: its storage stops being live, and (under default ARC) any heap reference it held is automatically released.

### Stack instance

```c
MyClass mine;          // zero-filled, init() runs, storage reclaimed at scope exit
```

A bare `MyClass mine;` allocates the instance directly in the enclosing scope's local storage — zero-page if the ivars fit, spilled to the data section otherwise. The storage is zero-filled on entry to the scope, the parameterless `init()` (if present) runs automatically, and the bytes are reused as soon as the scope closes. **No heap touch.** Safe to declare inside a loop body because the same storage is reused across iterations.

### Heap instance

```c
MyClass@ mine = new MyClass();
```

Allocates on the heap and returns a pointer to a block whose **reference count is 1**. That part is invariant — true regardless of `-farc` mode. What differs is who balances the reference:

- **Under default ARC** (`-farc=on`, the default): the variable holding the pointer owns the reference. When its scope exits, the compiler emits a `release` automatically; if that release drops the refcount to zero, the block's `dealloc()` runs and the bytes return to the free list. You write `new MyClass()` and walk away — the lifecycle is implicit.
- **Under `-farc=off`**: the compiler emits **no automatic releases**. The variable still receives the `+1` from `new`, but you must call `release ptr;` (or its alias `delete ptr;`) yourself before the last reference disappears, otherwise the block leaks.

In both modes, this is the form to reach for when the instance needs to outlive the scope it was created in. Full lifecycle on [Heap, ARC & weak refs](/compiler/language/memory/).

### Parameterised construction

Both forms accept an argument list, dispatched to a matching `init(...)` defined on the class. A class may declare several `init` overloads that differ in their parameter types — the compiler picks the one whose signature matches the call.

```c
class Sprite {
    u16 x;
    u16 y;
    u8  tint;

    void init(void)                       { x = 0;   y = 0;   tint = 0; }
    void init(u16 px, u16 py)             { x = px;  y = py;  tint = 0; }
    void init(u16 px, u16 py, u8 t)       { x = px;  y = py;  tint = t; }
}

void main(void) {
    Sprite  origin;                       // stack, init()        → (0, 0, tint 0)
    Sprite  ship(160, 96);                // stack, init(160, 96) → (160, 96, tint 0)
    Sprite@ boss = new Sprite(80, 40, 7); // heap,  init(80, 40, 7)
}
```

Reaching `init(160, 96)` requires that overload to exist on the class — calling `Sprite ship(160, 96);` against a `Sprite` that only declares `init(void)` is a compile-time error. See [Functions → Function overloading](/compiler/language/functions/#function-overloading) for how the resolution rules work in general.

## Methods

Methods are declared inside the class body. The receiver `self` is implicit:

```c
class Counter {
    u16 n;

    void init(void)    { n = 0; }
    void tick(void)    { n = n + 1; }
    u16  value(void)   { return n; }
}

void main(void) {
    Counter c;
    c.tick();
    c.tick();
    Stdio.printInt(c.value());      // 2
}
```

A class instance is almost always reached through a pointer (whether stack-resident or heap-resident, the method receiver is a pointer behind the scenes), so dot-syntax method calls (`c.tick()`) read naturally regardless of allocation flavour.

## Constructors: `init`

Any method named `init` whose signature matches the construction arguments is the constructor. xtc supports multiple `init` overloads through the same parameter-type-overloading machinery as ordinary functions:

```c
class Sprite {
    u16 x; u16 y;

    void init(void)              { x = 0;  y = 0;  }
    void init(u16 px, u16 py)    { x = px; y = py; }
}
```

`Sprite a;` calls `init()`; `Sprite b(160, 96);` calls `init(160, 96)`.

There is **no operator overloading** in xtc — only method overloading.

## Destructor: `dealloc`

`dealloc(void)` runs when a heap-allocated class instance's refcount hits zero, before the bytes return to the free list. Every class gets an auto-generated empty `dealloc` stub; override it only when the instance owns external state (opened files, mapped I/O, caches the ARC walker doesn't see).

```c
class Buffer {
    u8@ bytes;
    u16 len;

    void init(u16 n) {
        bytes = new u8[n];
        len   = n;
    }

    void dealloc(void) {
        // bytes is a strong class-pointer ivar — the aggregate
        // walker releases it automatically. Override dealloc only
        // for things the compiler can't see (hardware, logging,
        // cache invalidation, …).
    }
}
```

`dealloc` runs **exactly once** when the last owning reference is dropped — never earlier, never twice. For arrays of class instances (`new T[N]`), `dealloc` runs once per element before the whole block is freed.

When inheritance is in play, the `init` chain runs parent-first, the `dealloc` chain runs subclass-first; both walk all the way up to the universal `Object` base. See [Inheritance & protocols → Construction and destruction](/compiler/language/inheritance/#construction-and-destruction).

## Static methods

A `static` method is a class-scoped function — callable without an instance, with no access to instance variables.

```c
class Math {
    static u16 lerp(u16 a, u16 b, u8 t) {
        return a + (((b - a) * t) >> 8);
    }
}

u16 mid = Math.lerp(0, 100, 128);
```

Use static methods when the operation belongs to a class conceptually but doesn't need any per-instance state — namespacing without the dispatch overhead.

### Bare-call promotion: `use ClassName`

`use ClassName;` is a top-level directive that promotes a class's static methods into the bare-identifier call lookup space for the rest of the file. After `use Stdio;`, the user can call `printf("hi\n")` directly instead of writing `Stdio.printf("hi\n")` — the receiver class is implied by the directive.

```c
#import <Stdio.xt>
#import <Math.xt>

use Stdio;
use Math;

void main(void) {
    printf("answer = %u\n", 42);    // resolves to Stdio.printf
    u8 r = rand((u8)100);           // resolves to Math.rand
}
```

Resolution works exactly like a normal `Klass.method(...)` call — overload scoring, varargs handling, the static-init guard, and the implicit `__sdata_<class>` self-pointer are all the same. The only difference is that the receiver is implied by the `use` directive instead of written at the call site.

**Composition.** Multiple `use` directives compose: `use Stdio;` and `use Math;` together let you write `printf(...)` and `rand(...)` bare. If two `use`'d classes both expose a static method with the same name and an overload would match the call, sema reports the call as ambiguous — write the explicit `Klass.method(...)` form to disambiguate.

**Scope.** A `use` directive only affects **bare identifiers** — fields, locally-declared variables, free functions, and explicit `Klass.method(...)` calls all keep their normal lookup. The directive is scoped to the **textual file** (no propagation across `#import`); a class's source can `use` whatever it likes without leaking the promotion into callers' files.

**Pair with `#use` for one-line setup.** The preprocessor offers a single-token shorthand that combines the import and the promotion:

```c
#use Stdio          // == #import "Stdio.xt" + use Stdio;

void main(void) {
    printf("hello\n");
}
```

See [Preprocessor → `#use`](/compiler/language/preprocessor/#importing-and-promoting-a-class-use) for the full preprocessor sugar, including the angle-bracket and quote forms.

## Properties

Dot-syntax member access is rewritten into a method call **when a method by that name exists**. The rule has two halves:

- **Read** `obj.name` rewrites to `obj.name()` when a zero-arg method `name` exists on the class.
- **Write** `obj.name = value` rewrites to `obj.setName(value)` when a one-arg method `setName` exists whose parameter accepts `value`'s type. Camel-casing applies: `foo` ↔ `setFoo`, `lineWidth` ↔ `setLineWidth`.

Each side is resolved independently. You can ship just a getter, just a setter, or both — whichever isn't provided falls through to direct ivar access. If neither is provided, the access behaves like a plain ivar read or write.

```c
class Box {
    u8 _w;                          // backing ivar (underscored by convention)

    void init(void)    { _w = 0; }
    u8   w(void)       { return _w; }
    void setW(u8 v)    { if (v > 100) v = 100; _w = v; }   // clamp
}

void main(void) {
    Box@ b = new Box();
    b.w = 150;          // calls setW(150); _w becomes 100
    u8 v = b.w;         // calls w(); returns 100
}
```

The rewrite goes through the same machinery as a direct method call — virtual dispatch (for overridden accessors in subclasses), banked-heap bank switching, and ARC parameter retain / release all work transparently. Setters that want a different parameter type than the backing ivar are fine: the compiler checks the RHS against the setter's parameter type, not the ivar's type.

### One sharp edge: don't call `self.name` inside the accessor

Writing `self.w` inside the getter `w()` would recurse infinitely. **Read the bare ivar instead** (`_w` in the example). Picking a different name for the ivar than the accessor — the leading-underscore convention is common — avoids the problem entirely.

### Compound assignment through setters

`b.w += 1` rewrites to `b.w = b.w + 1`, so the read side picks up the getter and the write side picks up the setter. The base expression (`b`) is evaluated **twice** in the desugared form — free for identifiers and `self`, watch-out only if the base has a side effect (a function call, for instance).

## What's next

- [Inheritance & protocols](/compiler/language/inheritance/) — single inheritance, virtual dispatch, downcasts, protocols.
- [Heap, ARC & weak refs](/compiler/language/memory/) — lifecycle of heap-allocated class instances.
