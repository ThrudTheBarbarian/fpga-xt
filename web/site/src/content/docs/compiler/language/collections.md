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

The unboxing happens in **assignment context** — that is what triggers the
rewrite to `((Number*)a.get(i)).asI32()`:

```c
Array<i32>* scores = new Array();
scores.add((i32)70);
scores.add((i32)95);

i32 v = scores.get((u32)0);           // 70  — assignment context, unboxes
```

:::caution[Read primitives with an index, not `for ... in`]
`for (i32 v in scores)` does **not** unbox today: the loop variable receives the
`Number*` pointer reinterpreted as an integer, so you get a large meaningless
number rather than the value. This is compiler bug 039. Until it is fixed, walk a
primitive collection with an index:

```c
for (u32 i = (u32)0; i < scores.count(); i = i + (u32)1) {
    i32 v = scores.get(i);
    …
}
```

`for ... in` over a collection of **class** elements is correct — there the
element really is a pointer, and there is nothing to unbox.
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
    String* description(void)
    {
        String* s = String.withCString("(");
        s.append(String.withI32(x));
        s.appendCString("|");
        s.append(String.withI32(y));
        s.appendCString(")");
        return s;
    }
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

    String* description(void)
    {
        String* s = String.withCString("(");
        s.append(String.withI32(x));
        s.appendCString("|");
        s.append(String.withI32(y));
        s.appendCString(")");
        return s;
    }
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
    Array<i32>* scores = new Array();
    scores.add((i32)70);
    scores.add((i32)95);
    i32 total = (i32)0;
    for (u32 i = (u32)0; i < scores.count(); i = i + (u32)1)
    {
        i32 v = scores.get(i);
        total = total + v;
    }
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
