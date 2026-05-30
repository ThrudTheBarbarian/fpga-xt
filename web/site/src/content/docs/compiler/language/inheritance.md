---
title: Inheritance & protocols
description: Single inheritance, virtual dispatch, casting objects, and protocols.
---

xtc supports **single inheritance** between classes and **multiple-protocol conformance** for cross-tree interfaces. The two solve different problems: inheritance is for sharing implementation down a single line of descent, protocols are for sharing a *calling convention* across unrelated trees.

## Single inheritance

A class names a single parent after its name with `: Parent`:

```c
class Animal {
    u8 legs;
    void init(void)        { legs = 4; }
    void describe(void)    { Stdio.printf("animal\n"); }
}

class Dog : Animal {
    u8 tailWag;
    void describe(void)    { Stdio.printf("dog\n"); }   // override
    void wag(void)         { tailWag = tailWag + 1; }   // new
}
```

Ivars and methods declared in the parent are inherited by the child. The child can add new ivars and new methods, and override any inherited method by redeclaring it with the same signature.

Every class that doesn't name an explicit parent inherits from the universal `Object` base — `class Foo { ... }` and `class Foo : Object { ... }` mean the same thing.

## Construction and destruction

`init` and `dealloc` chain automatically:

- When you write an `init` in a subclass, the compiler inserts an implicit call to the parent's matching `init` at the **top** of the method body. If no parent `init` matches the argument list, the class is rejected at compile time.
- `dealloc` chains in **reverse**: the subclass's body runs first, then the compiler emits an implicit call to the parent's `dealloc` at the end.

Both chains walk all the way up to `Object`. You can write the chaining explicitly with `super.init(...)` / `super.dealloc()` — doing so suppresses the automatic call so you can pass different arguments or defer cleanup.

## Virtual dispatch

Overridden methods dispatch through a per-class **vtable**. Every class gets a unique class-id byte, `new` stamps it into the first byte of the allocation, and a call site reads the id and indexes the class's vtable for the method slot.

Methods that are **never overridden** keep a direct `JSR` — the vtable only kicks in when it actually has something to resolve.

A `super.method()` call always goes direct to the parent's body and skips the vtable, regardless of how many further subclasses exist.

## Casting objects

Class pointers can move both **up** the hierarchy (subclass → ancestor) and **down** it (ancestor → subclass), but the two directions follow different rules. Same-class casts and casts between unrelated trees are also discussed here.

### Upcasts — always implicit

A `Dog@` is accepted anywhere an `Animal@` is expected because every Dog *is* an Animal. The compiler emits no runtime check; it's a compile-time no-op.

```c
Dog@    d = new Dog();
Animal@ a = d;            // implicit upcast — no check, no cast syntax needed
```

Unrelated class pointers do not silently alias. Within the same line of descent the upcast is free, but assigning a `Cat@` to a `Dog@` is a compile-time error because the trees diverge.

### Downcasts — runtime-checked

Going the other direction — handing back a `Dog@` value that's stored in an `Animal@` variable — needs a runtime check because the actual runtime type isn't known statically. xtc expresses this with the existing `(type)` cast syntax; the compiler detects when the source and target are related classes in opposite directions and inserts a class-id check.

Two cast forms cover the two failure-handling preferences:

| Cast | Behaviour on mismatch |
|------|------------------------|
| `(Dog@) animal` | **traps** (executes a `BRK`) |
| `(Dog@ ?) animal` | **failable** — yields `(Dog@)0` |

```c
Animal@ a = new Dog();
Dog@ d   = (Dog@ ?)a;    // d != 0; dispatch through Dog's vtable
Cat@ c   = (Cat@ ?)a;    // c == 0; a isn't a Cat
Dog@ d2  = (Dog@)a;      // succeeds; no check fires on match
```

The check itself is the class-id byte `new` stamped at payload offset 0, walked up the `__class_parent` table until the target's id matches or the walk hits `Object`.

### Rules at a glance

- **Upcasts and same-class casts** emit no check — compile-time no-ops.
- **Downcasts** emit a runtime class-id check, with the trapping or failable behaviour selected by the cast syntax.
- **A null operand** passes through unchanged for both downcast flavours.
- **Casts between unrelated class trees** (neither is an ancestor of the other) are rejected at compile time, since the runtime check could never succeed.
- **The `?` marker is class-pointer-only.** Applying it to `(u16 ?)x` is a compile-time error.

## Protocols

A protocol is a named interface — a list of method signatures with no bodies, no ivars, and no implementation.

```c
protocol Drawable {
    void draw(void);
    u8   width(void);
}
```

Bodies, instance variables, static methods, and nested declarations are rejected at parse time inside a protocol.

### Conforming to a protocol

A class names the protocols it adopts in a `< ... >` clause placed after the class name (and after the `: Parent` clause if there is one):

```c
class Sprite <Drawable> {
    u8 w;
    void init(void)      { w = 16; }
    void draw(void)      { Stdio.printf("sprite\n"); }
    u8   width(void)     { return w; }
}

class Terrain <Drawable> {
    u8 h;
    void draw(void)      { Stdio.printf("terrain\n"); }
    u8   width(void)     { return h; }
}

class Badge : Sprite <Labelled> {       // parent + protocol
    void label(void)     { Stdio.printf("badge\n"); }
}
```

Either clause is optional. A class with neither inherits from `Object` and adopts no protocols. A class that claims conformance but forgets a declared method is rejected at compile time:

```c
class Broken <Drawable> {
    u8 w;
    // missing draw and width
}
// error: Class 'Broken' claims conformance to protocol
//        'Drawable' but doesn't implement 'draw'
```

**Subclasses inherit their parent's conformances.** If `Sprite` adopts `Drawable`, any subclass of `Sprite` is accepted where a `Drawable` is expected — the subclass need not re-list `Drawable`.

### Using a protocol as a type

A protocol name in a type position denotes a value that conforms to the protocol. The pointer form (`Drawable@`) is the common one — it holds a pointer to any conforming instance regardless of concrete class:

```c
void render(Drawable@ d) {
    d.draw();
}

void main(void) {
    Sprite@  s = new Sprite();
    Terrain@ t = new Terrain();
    render(s);      // calls Sprite.draw
    render(t);      // calls Terrain.draw
}
```

Passing a non-conforming instance is a compile-time error:

```c
class Vehicle { u8 wheels; }

void main(void) {
    Vehicle@ v = new Vehicle();
    render(v);      // error: 'Vehicle' does not conform to protocol 'Drawable'
}
```

### Dispatch

Calls through a protocol-typed pointer go through the same per-class vtable that class inheritance uses. Every protocol method is assigned its own global slot, and each conforming class's implementation lands in that slot in the class's own vtable. At the call site the compiler reads the instance's class-id byte and uses it to index the vtable — one indirect `JMP` per call, no runtime string lookup.

A class may adopt any number of protocols; the list is order-insensitive. When two protocols declare a method with the same name and signature, they share a single vtable slot, and a class that conforms to both supplies just one implementation covering both.
