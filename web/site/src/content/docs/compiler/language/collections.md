---
title: Collections & strings
description: Array, Map, Set and String — element types in angle brackets, checked at compile time and erased at run time.
---

The containers are ordinary xtc classes, shipped with the compiler and written in
the same language you are writing. What makes them pleasant is the **element
type** in angle brackets:

```c
Array<String>* names = new Array();
names.add(String.withCString("ada"));
String* first = names.get((u32)0);       // a String*, with no cast
```

`Array<String>` stores and returns `String*`. Nothing at the use site casts, and
putting the wrong type in is a compile error rather than a crash somewhere later.

The type argument is **erased at run time** — one `Array` implementation serves
every element type, and there is no code-size cost per instantiation. It is a
static check, not a template expansion. This matters on the 6502, where a
per-instantiation container would be unaffordable.

## Declaring and constructing

The element type goes on the *declaration*. `new Array()` needs no type argument
because it takes it from the slot it is assigned into.

```c
Array<String>* names  = new Array();
Array<Point>*  path   = new Array();
Map<Point>*    places = new Map();
Set<String>*   seen   = new Set();
```

There is **one type argument per collection**. For `Map` it names the *value*
type; keys are anything conforming to `Hashable`, which `String` and `Number`
both do. There is no `Map<K,V>` spelling yet.

## What the element type buys you

Three things, and the third is the one that catches bugs:

```c
Array<String>* names = new Array();

String* s = names.get((u32)0);        // 1. no cast on the way out
for (String* n in names) { … }        // 2. the loop variable is typed

names.add(Number.withU32((u32)7));    // 3. error: Number is not a subclass of String
```

A subclass goes in wherever the superclass is expected, so an
`Array<Animal>` accepts a `Dog`, and reading one back gives an `Animal*`. A
protocol works as the element type too — `Array<Comparable>*` holds anything
that conforms.

## Primitive element types

A primitive element travels **boxed**: a `Number` goes into the container, and an
`i32` comes back out. Conformance is still judged by the declared type, so an
`Array<i32>` refuses a `float` at compile time even though both box into the same
`Number`.

Every scalar width works as an element type — `i8` through `u64`, `float` and
`double`. `Number` stores integers in an `i64` slot and floating point in a
`double` slot, so nothing is lost either way: an `Array<i64>` round-trips 2^40,
and an `Array<double>` round-trips a value with no exact `float` form.

:::note[On xt6502, 64-bit elements are opt-in]
Widening `Number` costs about 4.5 KB in *any* 6502 program that touches the
class, so on that target the wide storage is gated behind `-DENABLE_64BIT=1`
(the other five targets are wide unconditionally). Without it, `Array<i64>` and
`Array<double>` are a **compile error** rather than a silent truncation — a box
that cannot hold the value does not pretend to.
:::

The unboxing is decided by the **collection**, not by where the read appears.
`scores` was declared to hold `i32`, so `scores.get(i)` is an `i32` — the
compiler rewrites it to `((Number*)scores.get(i)).asI32()` wherever it occurs:

```c
Array<i32>* scores = new Array();
scores.add((i32)70);
scores.add((i32)95);

i32 v    = scores.get((u32)0);        // 70   declaration
v        = scores.get((u32)1);        // 95   assignment
i32 sum  = scores.get(i) + (i32)5;    // 75   arithmetic
bool hit = scores.get(i) == (i32)70;  // true comparison
Stdio.printf("%ld\n", scores.get(i)); // 70   vararg
i32 pick = c ? scores.get(i) : (i32)0; // 70  ternary arm
for (i32 x in scores) { … }           // 70, 95
```

:::note[This was bug 046]
Until 2026-08, the unbox fired only where a site had been written for it —
declaration, assignment, return and typed call argument — and three of the
seven contexts above silently produced the *box*: a pointer-shaped integer,
and in the comparison's case a plausible `false`. If you are on an older
compiler, bind the value to a variable first.
:::

## `description` and `%@`

`%@` prints an object by calling its `description()` method through the vtable.
`Object` supplies a default; override it and every `%@`, every container dump and
every debug print follows:

```c
class Point : Object
{
    i32 x;
    i32 y;
    String* description(void) { return String.withFormat("(%ld|%ld)", x, y); }
}

Stdio.printf("last %@\n", path.last());     // last (3|4)
```

## String

`String` is a **mutable object with a value identity**. Both halves of that
matter:

- `append` grows the receiver in place and returns nothing; `appending` leaves
  the receiver alone and returns a new string.
- `equals` compares *bytes*; `==` compares *addresses*. Two separately
  constructed `"ada"` strings are `equals` but not `==`.

```c
String* greeting = String.withCString("hello");
String* longer   = greeting.appending(String.withCString(", world"));
greeting.appendCString("!");
// greeting is now "hello!", longer is "hello, world"
```

Hand the bytes to `printf`'s `%s` with `.cString()`.

### Formatting

`String` formats with the same specifiers `Stdio.printf` uses — same width
contract, same `%@`-dispatches-`description()` behaviour — either into a new
string or onto an existing one:

```c
String* s = String.withFormat("(%ld|%ld)", x, y);   // construct
s.appendFormat(" tint=%d", tint);                   // append
```

Supported: `%@` `%s` `%d` `%i` `%u` `%ld` `%lu` `%x` `%lx` `%c` `%f` `%lf` `%%`,
with optional width and zero-padding (`%04lx`). `%d`/`%u`/`%x` are 16-bit and
the `l` forms 32-bit, exactly as in `Stdio.printf`.

This is the idiomatic way to write `description()`:

```c
String* description(void) { return String.withFormat("(%ld|%ld)", x, y); }
```

Searching returns an unsigned index, so a miss is `String.notFound()` rather than
a negative number:

```c
u32 at = longer.indexOf(String.withCString("world"));
if (at != String.notFound()) { … }
```

Numbers convert in both directions, including the 64-bit widths:
`String.withI32`, `withU32`, `withI64`, `withU64`, `withFloat(f, precision)`.

## Worked example

The complete program, which compiles and runs on every target:

```c
// collections.xc — Array, Map, Set and String, with element types.
#import "Stdio.xc"
#import "Foundation.xc"

class Point : Object
{
    i32 x;
    i32 y;
    void init(void) { x = (i32)0; y = (i32)0; }
    static Point* at(i32 px, i32 py) { Point* p = new Point(); p.x = px; p.y = py; return p; }

    String* description(void) { return String.withFormat("(%ld|%ld)", x, y); }
}

i32 main(void)
{
    // ---- Array ----
    Array<String>* names = new Array();
    names.add(String.withCString("ada"));
    names.add(String.withCString("grace"));
    names.add(String.withCString("edsger"));

    Stdio.printf("count %d, first %s\n",
                 (i16)names.count(), names.get((u32)0).cString());

    Stdio.print("names:");
    for (String* n in names) { Stdio.printf(" %s", n.cString()); }
    Stdio.print("\n");

    // ---- Array of your own class ----
    Array<Point>* path = new Array();
    path.add(Point.at((i32)0, (i32)0));
    path.add(Point.at((i32)3, (i32)4));
    Stdio.printf("last %@\n", path.last());

    // ---- Array of a primitive ----
    // A for-in loop variable is a binding, so this reads values, not boxes.
    Array<i32>* scores = new Array();
    scores.add((i32)70);
    scores.add((i32)95);
    i32 total = (i32)0;
    for (i32 v in scores) { total = total + v; }
    Stdio.printf("total %ld\n", total);

    // ---- Map: the type argument is the VALUE type ----
    Map<Point>* places = new Map();
    places.set(String.withCString("origin"), Point.at((i32)0, (i32)0));
    places.set(String.withCString("corner"), Point.at((i32)9, (i32)9));
    Point* corner = places.get(String.withCString("corner"));
    Stdio.printf("corner %@, map holds %d\n", corner, (i16)places.count());
    Stdio.printf("missing is null: %d\n",
                 (i16)(places.get(String.withCString("nowhere")) == 0 ? 1 : 0));

    // ---- Set: membership by VALUE, not identity ----
    Set<String>* seen = new Set();
    seen.add(String.withCString("x"));
    seen.add(String.withCString("y"));
    seen.add(String.withCString("x"));
    Stdio.printf("set holds %d, contains y: %d\n",
                 (i16)seen.count(),
                 (i16)(seen.contains(String.withCString("y")) ? 1 : 0));

    // ---- String ----
    String* greeting = String.withCString("hello");
    String* longer   = greeting.appending(String.withCString(", world"));
    greeting.appendCString("!");
    Stdio.printf("%s / %s (%d chars) / %s\n",
                 greeting.cString(), longer.cString(),
                 (i16)longer.length(), longer.uppercased().cString());

    Stdio.printf("equal by value: %d, same object: %d\n",
                 (i16)(String.withCString("ada").equals(names.get((u32)0)) ? 1 : 0),
                 (i16)(String.withCString("ada") == names.get((u32)0) ? 1 : 0));

    Stdio.printf("index of world: %d, prefix hello: %d, slice %s\n",
                 (i16)longer.indexOf(String.withCString("world")),
                 (i16)(longer.hasPrefix(String.withCString("hello")) ? 1 : 0),
                 longer.substring((u32)7, (u32)5).cString());

    Stdio.printf("i32 %s, u64 %s\n",
                 String.withI32((i32)-42).cString(),
                 String.withU64((u64)1099511627776).cString());
    return 0;
}
```

```
count 3, first ada
names: ada grace edsger
last (3|4)
total 165
corner (9|9), map holds 2
missing is null: 1
set holds 2, contains y: 1
hello! / hello, world (12 chars) / HELLO, WORLD
equal by value: 1, same object: 0
index of world: 7, prefix hello: 1, slice world
i32 -42, u64 1099511627776
```

## Memory

Containers participate in ARC: adding an object retains it, removing releases it,
and a container's own `dealloc` releases everything it holds. A `for ... in` loop
variable is **borrowed** — the container owns the element for the duration of the
loop, so nothing is retained per iteration.

See [Heap, ARC & weak refs](/compiler/language/memory/) for the ownership rules,
and [Foundation](/compiler/api/foundation/) for the complete method lists.
