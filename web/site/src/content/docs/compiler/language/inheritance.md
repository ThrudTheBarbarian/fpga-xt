---
title: Inheritance & protocols
description: Single inheritance, virtual dispatch, casting objects, and protocols.
---

xcc supports **single inheritance** between classes and **multiple-protocol conformance** for cross-tree interfaces. The two solve different problems: inheritance is for sharing implementation down a single line of descent, protocols are for sharing a *calling convention* across unrelated trees.

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

Overridden methods dispatch through a per-class **vtable**. Every class gets a unique 16-bit **class id**, `new` stamps it into the first word of the allocation, and a call site reads the id and indexes the class's vtable for the method slot. Sixteen bits, not eight — a program is not limited to 255 classes, and the RTTI check below depends on the full width.

Methods that are **never overridden** keep a direct `JSR` — the vtable only kicks in when it actually has something to resolve.

A `super.method()` call always goes direct to the parent's body and skips the vtable, regardless of how many further subclasses exist.

## Casting objects

Class pointers can move both **up** the hierarchy (subclass → ancestor) and **down** it (ancestor → subclass), but the two directions follow different rules. Same-class casts and casts between unrelated trees are also discussed here.

### Upcasts — always implicit

A `Dog*` is accepted anywhere an `Animal*` is expected because every Dog *is* an Animal. The compiler emits no runtime check; it's a compile-time no-op.

```c
Dog*    d = new Dog();
Animal* a = d;            // implicit upcast — no check, no cast syntax needed
```

Unrelated class pointers do not silently alias. Within the same line of descent the upcast is free, but assigning a `Cat*` to a `Dog*` is a compile-time error because the trees diverge.

### Downcasts — runtime-checked

Going the other direction — handing back a `Dog*` value that's stored in an `Animal*` variable — needs a runtime check because the actual runtime type isn't known statically. xcc expresses this with the existing `(type)` cast syntax; the compiler detects when the source and target are related classes in opposite directions and inserts a class-id check.

Two cast forms cover the two failure-handling preferences:

| Cast | Behaviour on mismatch |
|------|------------------------|
| `(Dog*) animal` | **traps** (executes a `BRK`) |
| `(Dog* ?) animal` | **failable** — yields `(Dog*)0` |

```c
Animal* a = new Dog();
Dog* d   = (Dog* ?)a;    // d != 0; dispatch through Dog's vtable
Cat* c   = (Cat* ?)a;    // c == 0; a isn't a Cat
Dog* d2  = (Dog*)a;      // succeeds; no check fires on match
```

The check itself is the 16-bit class id `new` stamped at payload offset 0, walked up the `__class_parent` table until the target's id matches or the walk hits `Object`.

Slot 0 does double duty: a class that needs a vtable stores its vtable *pointer* there instead. The two are told apart by magnitude — a class id is below `0xFFFF` and any real vtable address is above it — which is why the id has to be a full 16-bit value rather than a byte.

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

A protocol name in a type position denotes a value that conforms to the protocol. The pointer form (`Drawable*`) is the common one — it holds a pointer to any conforming instance regardless of concrete class:

```c
void render(Drawable* d) {
    d.draw();
}

void main(void) {
    Sprite*  s = new Sprite();
    Terrain* t = new Terrain();
    render(s);      // calls Sprite.draw
    render(t);      // calls Terrain.draw
}
```

Passing a non-conforming instance is a compile-time error:

```c
class Vehicle { u8 wheels; }

void main(void) {
    Vehicle* v = new Vehicle();
    render(v);      // error: 'Vehicle' does not conform to protocol 'Drawable'
}
```

### Optional methods

A protocol method marked `optional` need not be implemented. That is what makes the
**delegate pattern** work — a delegate implements the two callbacks it cares about and
ignores the rest.

```c
protocol WindowDelegate {
    void willClose(void);
    optional void didResize(u16 w, u16 h);   // may be absent
}

class Lazy <WindowDelegate> {
    void willClose(void) { … }               // didResize omitted — legal
}
```

An unimplemented `optional` leaves a **null slot**, so testing for it is just a null test on
a [bound method](/compiler/language/classes/#bound-methods):

```c
act_t^ resized = &delegate.didResize;
if (resized) { resized(w, h); }              // this IS respondsTo
```

Calling an `optional` method *directly* is a compile error — it might not be there. Take
`&delegate.method` and test it.

### `final`

Virtuality is inferred whole-program: a method nobody overrides keeps its direct call and
needs no marker. `final` exists for `--emit-lib`, where the program *isn't* whole — there,
every exported instance method is treated as an override root, because the overrides may
live in a client. `final` opts a method back out of the vtable and says so.

### Dispatch

Calls through a protocol-typed pointer go through the receiver's vtable, exactly as class
inheritance does — one indirect call, no runtime string lookup.

A class may adopt any number of protocols; the list is order-insensitive.

On whole-program targets each protocol method gets a slot in the flat vtable. On targets
that can be linked as **multiple modules** (`arm9`), that will not do: two libraries built
in ignorance of each other would number their protocols from the same base, and a class
conforming to one from each could satisfy neither. So there, a protocol method is identified
by its **index within its own protocol** — which every module derives identically, needing no
agreement — and the receiver carries a small table mapping protocol → implementations.

You do not have to think about any of this. It is the reason a protocol works across a `.so`
at all; see [Modules & shared libraries](/compiler/language/modules/).

## Worked example

Single inheritance, virtual dispatch, a protocol as a parameter type, and the
optional-method test — one runnable program:

```c
// protocols.xc
#import "Foundation.xc"
#import "Stdio.xc"

protocol Speaker
{
    String* speak(void);
    optional String* whisper(void);
}

class Animal : Object <Speaker>
{
    String* _name;
    void init(void) { _name = String.withCString("animal"); }
    static Animal* named(String* n) { Animal* a = new Animal(); a._name = n; return a; }
    String* name(void) { return _name; }

    // Virtual by default: a subclass's override wins even through a
    // base-class reference.
    String* speak(void) { return String.withCString("..."); }
    String* description(void) { return _name; }
}

class Dog : Animal
{
    // No init() here — the parent's still runs.
    static Dog* named(String* n) { Dog* d = new Dog(); d._name = n; return d; }
    String* speak(void)   { return String.withCString("Woof"); }
    String* whisper(void) { return String.withCString("woof?"); }   // optional, implemented
}

class Cat : Animal
{
    static Cat* named(String* n) { Cat* c = new Cat(); c._name = n; return c; }
    String* speak(void) { return String.withCString("Meow"); }
    // whisper() deliberately NOT implemented.
}

typedef String* saying_t(void);

// Taking the PROTOCOL as the parameter type means this works for anything that
// conforms, including classes written later.
void introduce(Speaker* s)
{
    Stdio.printf("  %@ says %s\n", s, s.speak().cString());

    // An unimplemented optional leaves a NULL vtable slot, so binding it with
    // `&` doubles as "does it respond to this?" — no respondsTo call and no
    // runtime lookup. Calling an optional method directly is a compile error,
    // which is what forces the check.
    saying_t^ w = &s.whisper;
    if (w != 0) Stdio.printf("    ...and whispers %s\n", w().cString());
    else        Stdio.print("    (does not whisper)\n");
}

i32 main(void)
{
    Animal* d = Dog.named(String.withCString("Rex"));
    Animal* c = Cat.named(String.withCString("Tom"));

    // Virtual dispatch: both are Animal* here, but each speaks for itself.
    Stdio.print("through Animal*:\n");
    Stdio.printf("  %@ -> %s\n", d, d.speak().cString());
    Stdio.printf("  %@ -> %s\n", c, c.speak().cString());

    Stdio.print("through Speaker*:\n");
    introduce(d);
    introduce(c);
    return 0;
}
```

```
through Animal*:
  Rex -> Woof
  Tom -> Meow
through Speaker*:
  Rex says Woof
    ...and whispers woof?
  Tom says Meow
    (does not whisper)
```

`Dog` and `Cat` declare no `init`, and neither declares conformance to `Speaker`
— they inherit both from `Animal`. `%@` reaches `description()` through the same
vtable the `speak()` calls use.

