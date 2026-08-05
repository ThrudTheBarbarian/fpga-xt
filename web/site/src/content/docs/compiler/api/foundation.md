---
title: Foundation classes
description: "Object, Number, String, Data, Array, Map, Set — value wrappers, containers, insertion-ordered iteration, sorting and the functional methods, with the Comparable / Hashable / Enumerable / Error protocols behind them."
---

Foundation is xtc's standard object library: value wrappers (`Number`, `String`, `Data`),
containers (`Array`, `Map`, `Set`), and the three protocols they are built on (`Comparable`,
`Hashable`, `Enumerable`).

```c
#import "Foundation.xc"        // the umbrella
```

The umbrella pulls in `Object`, `Comparable`, `Enumerable`, `Hashable`, `Number`, `String`, `Data`,
`Array`, `Map` and `Set` — everything below except the [`Error`](#error) protocol, which is imported
by name.

Every class inherits from the runtime's built-in `Object` root — every parentless `class X`
does — so a `Number*`, a `String*`, or any class of your own fits wherever an `Object*` is
expected. No `: Object` annotation is needed.

All of it needs a real heap (`-falloc=heap`), which is the default on the 6502 `xt` layouts
and on every native backend.

:::note[Two implementations, one API]
Foundation exists twice. `support/generic/lib/` is the 32-bit build — arm64, arm9, m68k,
x86_64 — with `u32` indices and a `u32` hash, bounded only by memory. `support/xt6502/lib/`
is the 6502 build, with `u16` indices and a `u8` hash, because four-byte index arithmetic on
every compare is not something an 8-bit CPU should pay for.

**Same API, different implementation.** Portable source compiles against both: a narrower
caller index widens at the call boundary, so `for (u16 i = 0; i < a.count(); i++)` means what
it says on either.
:::

## Element types

Every container takes an optional **element type** in angle brackets. It is a
compile-time check that is *erased* at run time — one `Array` implementation
serves every element type, so there is no code-size cost per instantiation:

```c
Array<String>* names = new Array();      // new Array() needs no type argument
names.add(String.withCString("ada"));
String* s = names.get((u32)0);           // a String*, no cast

names.add(Number.withU32((u32)7));       // error: Number is not a subclass of String
```

`Map<V>` names the **value** type; keys are anything conforming to `Hashable`.
There is one type argument per collection — no `Map<K,V>` spelling yet.

A primitive element type works and is enforced (`Array<i32>` refuses a `float`),
but the value travels boxed in a `Number`, and unboxing happens in **assignment
context**: `i32 v = a.get(i)`. Full discussion, and the `for ... in` caveat, on
[Collections & strings](/compiler/language/collections/).

Untyped `Array*` / `Map*` / `Set*` remain valid everywhere — the signatures
below are the erased ones, in terms of `Object*` and `Hashable*`.

## `Array`

An ordered, resizable list of `Object*`. Holds a strong reference to every element.

```c
Array* a = new Array();
a.add(Number.with((i32)42));
a.add(String.withCString("hi"));

for (Object* o in a) {                 // Enumerable
    Number* n = (Number* ?)o;          // safe-checked downcast
    if (n != 0) Stdio.printf("%d\n", n.asI16());
}
```

| | |
|---|---|
| **Build** | `new Array()`, `Array.withCapacity(n)`, `Array.withArray(other)` |
| **Read** | `count()` (`length()` is an alias), `isEmpty()`, `capacity()`, `get(i)`, `first()`, `last()` |
| **Mutate** | `add(o)`, `insert(i, o)`, `set(i, o)`, `addAll(other)`, `removeAt(i)`, `removeFirst()`, `removeLast()`, `removeAll()` |
| **Search** | `indexOf(o)` / `contains(o)` — pointer identity; `indexOfEqual(c)` / `containsEqual(c)` — value equality |
| **Enumerable** | `enumLength()`, `enumAt(i)` — what `for-in` dispatches through |
| **Order** | `sort()`, `sortUsing(cmp^)`, `sorted()`, `sortedUsing(cmp^)`, `isSortedUsing(cmp^)` |
| **Structure** | `reverse()`, `reversed()`, `swapAt(i, j)`, `subarray(from, len)` |
| **Functional** | `filtered(p^)`, `mapped(f^)`, `forEach(v^)`, `firstWhere(p^)`, `indexWhere(p^)`, `countWhere(p^)`, `anySatisfy(p^)`, `allSatisfy(p^)` |

`indexOf` and `indexWhere` return **`Array.notFound()`** when there is no match — not a
hardcoded `$FFFF`, which is a perfectly valid index once a container can hold more than 65535
things.

### The functional methods take a `^`

That is the point of them. A predicate can be a plain function *or* a **bound method that
carries its receiver** — so a filter's state lives on the filter, not in a global, and the
same Array can be filtered two different ways at once.

```c
class Threshold {
    i16 limit;
    bool above(Object* o) {
        Number* n = (Number* ?)o;
        return n != 0 && n.asI16() > limit;
    }
}

Threshold* t = new Threshold();
t.limit = (i16)3;
Array* big = rows.filtered(&t.above);      // the receiver comes along
t.limit = (i16)10;
Array* bigger = rows.filtered(&t.above);   // same ^, different answer
```

`mapped` skips a `null` result rather than storing it, so a transform doubles as a filter in
one pass.

### Sorting

`sortUsing` takes a comparator; `sort()` uses the elements' own order.

```c
a.sort();                      // Comparable.compare on the elements
a.sortUsing(&byLastName);      // a free function
a.sortUsing(&cfg.byColumn);    // …or a bound method, so the column is configuration
```

**`sort()` returns `false`, and changes nothing, when the elements define no order.** It does
not invent one. See [Comparable](#comparable) below.

## `Map`

A hash map keyed by anything that is `Hashable` + `Comparable`. Retains both keys and values.

```c
Map* m = new Map();
m.set(String.withCString("width"), Number.with((i32)320));

Number* w = (Number* ?)m.get(String.withCString("width"));
for (Object* key in m) { … }               // for-in yields the KEYS
```

| | |
|---|---|
| **Build** | `new Map()`, `Map.withCapacity(n)` |
| **Read** | `count()`, `isEmpty()`, `get(k)`, `getOrDefault(k, fallback)`, `containsKey(k)` — `contains(k)` is an alias |
| **Views** | `allKeys()`, `allValues()` — each an `Array*` |
| **Mutate** | `set(k, v)`, `remove(k)`, `removeAll()` |
| **Enumerable** | `enumLength()`, `enumAt(i)` — `for-in` over a Map yields its **keys** |

`containsKey` asks whether the **key** is present, which is a different question from "is
`get(k)` non-null" — a key stored with a null value is still a key.

## `Set`

A hash set of `Hashable` + `Comparable` elements, and the algebra that makes one worth having
over an Array.

```c
Set* online = Set.withArray(currentUsers);
Set* known  = Set.withArray(allUsers);

Set* newcomers = online.subtract(known);       // who is new
Set* shared    = online.intersect(known);      // who is in both
```

| | |
|---|---|
| **Build** | `new Set()`, `Set.withCapacity(n)`, `Set.withArray(a)` |
| **Read** | `count()`, `isEmpty()`, `contains(e)`, `allObjects()` |
| **Mutate** | `add(e)`, `remove(e)`, `removeAll()` |
| **Algebra** | `unionWith(s)`, `intersect(s)`, `subtract(s)`, `symmetricDifference(s)` |
| **Relations** | `isSubsetOf(s)`, `isSupersetOf(s)`, `intersects(s)`, `isDisjointFrom(s)`, `equalsSet(s)` |
| **Enumerable** | `enumLength()`, `enumAt(i)` |

Every algebra method returns a **new** Set; neither operand is modified.

## Map and Set iterate in insertion order

:::note[Behaviour change]
`Map` and `Set` used to enumerate in **hash order**. They now enumerate in **insertion order** — the order keys and elements were first added. `for-in`, `allKeys()`, `allValues()`, `allObjects()` and `enumAt(i)` all follow it, and `allKeys()` / `allValues()` line up index for index.
:::

Hash order was not merely arbitrary, it was *unstable*. The default `Object.hash` is derived from the instance's **address**, so a Map keyed by objects of your own classes enumerated in heap-layout order — which differs between runs. Anything ordered that way reaching a program's output made that output non-reproducible.

```c
Map* m = new Map();
m.set(String.withCString("zebra"), Number.with((i32)1));
m.set(String.withCString("apple"), Number.with((i32)2));
m.set(String.withCString("mango"), Number.with((i32)3));

for (Object* k in m) { … }          // zebra, apple, mango — every run
```

Re-`set`ting an existing key updates its value **in place** and leaves its position alone; only a key that is genuinely new goes on the end. `remove` closes the gap, so the survivors keep their relative order.

Two more things follow from the dense order array behind it:

- **`enumAt(i)` is O(1)** for any access pattern — a plain index. It used to rescan the slot table, which made a nested loop over the same Map O(n²).
- **Iteration is O(count), not O(capacity)** — a walk over a contiguous array rather than a strided scan across a table 1.33–2.67× the live-entry count.

The cost, and it is a real one: **`remove` is O(count)** rather than O(1), because the gap has to be closed to keep the index dense. Plus one index slot's worth of memory per table slot. A remove-heavy workload over a large Map is the case where you notice.

## `String`

A heap-owned, NUL-terminated byte string.

```c
String* s = String.withCString("  Hello, World  ");
String* t = s.trimmed();                             // "Hello, World"

if (t.hasPrefix(String.withCString("Hello"))) { … }

Array* fields = String.withCString("a,b,,c").split((u8)',');   // 4 parts — the gap counts
String* back  = String.join(fields, String.withCString("-"));  // "a-b--c"
```

| | |
|---|---|
| **Build** | `String.withCString(p)`, `withString(s)`, `withBytes(p, n)` |
| **Numbers** | `String.withI32(v)`, `withU32(v)`, `withI16(v)`, `withU16(v)`, `withFloat(v)` |
| **Read** | `length()`, `isEmpty()`, `charAt(i)`, `cString()` |
| **Search** | `indexOf(needle)`, `indexOfChar(c)`, `lastIndexOfChar(c)`, `contains(s)`, `hasPrefix(s)`, `hasSuffix(s)` |
| **Slice** | `substring(from, len)`, `substringFrom(from)`, `substringTo(to)` |
| **Mutate** | `append(s)`, `appendChar(c)`, `appendCString(p)` — and `appending(s)`, which returns a new String instead |
| **Case** | `uppercased()`, `lowercased()`, `caseInsensitiveCompare(s)`, `equalsIgnoringCase(s)` |
| **Other** | `trimmed()`, `split(sep)` → `Array*`, `String.join(parts, sep)`, `replacing(find, sub)`, `description()` |
| **Value** | `equals(other)`, `compare(other)`, `hash()` — FNV-1a over the bytes |

Out-of-range slicing **clamps to empty** rather than faulting — `substringFrom(999)` is an
empty String, the same choice Foundation makes for a clamped range.

`split` yields empty components for consecutive, leading or trailing separators, so `"a,,b"`
is three fields. That is what a CSV needs; filter the empties out if you want tokens.

Ordering is lexicographic by unsigned byte, then by length — so a prefix sorts before its
extension (`"go"` before `"gone"`).

## `Data`

An opaque byte block. No trailing NUL, no character semantics.

```c
Data* d = Data.withBytes(&raw[0], (u32)4);
Stdio.printf("%s\n", d.hexString().cString());     // "deadbeef"
```

| | |
|---|---|
| **Build** | `Data.withBytes(p, n)`, `withCapacity(n)`, `withData(other)` |
| **Read** | `length()`, `isEmpty()`, `bytes()`, `byteAt(i)` |
| **Mutate** | `setByteAt(i, v)`, `appendByte(b)`, `append(other)`, `appendBytes(p, n)` |
| **Slice** | `subdata(from, len)`, `subdataFrom(from)` |
| **Search** | `indexOfByte(b)`, `containsByte(b)`, `Data.notFound()` |
| **Text** | `hexString()`, `description()` |
| **Value** | `equals(other)`, `compare(other)`, `hash()` — FNV-1a over the bytes |

## `Number`

A wrapper around any sized integer or a float. Conversion between the two is lazy and cached.

```c
Number* n = Number.with((i32)-42);
Stdio.printf("%s\n", n.description().cString());   // "-42"

Number* f = Number.withFloat(3.25);
Stdio.printf("%s\n", f.description().cString());   // "3.250"
```

`with(v)` picks the storage kind from the argument's type; `withI8` / `withU16` / `withI32` /
`withFloat` pin it explicitly. `asI32()` / `asFloat()` / `asI16()` … read it back, and
`value()` is return-type-overloaded so it takes its kind from the destination.

`isInt()` and `isFloat()` report which kind is stored, and `equals` / `compare` / `hash` give it
value semantics.

`description()` renders an Int exactly and a Float to **three decimal places** — deliberately
not a general float formatter, and candid about being exactly that.

Cross-kind comparison promotes to float, so `Number.with((i16)42)` and
`Number.withFloat(42.0)` are **equal**, and `compare` agrees with `equals`.

## `Object`

The root class. Every `class X` with no explicit parent inherits from it implicitly, so there is
nothing to write — but its three methods are the defaults your own classes override, and they are
what a `Map`, `Set` or `Array` sees when you don't.

```c
class Object <Hashable, Comparable>
{
    u32     hash(void);            // u8 on the 6502 build
    bool    equals(Object* other);
    String* description(void);
}
```

- **`equals`** is pointer identity — two `Object*`s compare equal only when they point at the same
  heap block.
- **`hash`** folds the receiver's **address**. Distinct instances live at distinct addresses, so they
  hash apart by construction. It is deliberately not cached on the instance: a one-byte cache field
  on every object in the program would cost more than a two-instruction hash ever saves.
- **`description`** returns `<Object>`. It is what `Stdio.printf`'s `%@` dispatches through, so
  overriding it is how your class prints.

Override `equals`/`hash` together when your class wants **value** semantics — `Number` compares by
stored numeric value, `String` and `Data` fold over their bytes. Address-derived hashing is also why
`Map` and `Set` had to stop iterating in hash order (above): it varies between runs.

## The protocols

### `Comparable`

```c
protocol Comparable
{
    bool equals(Object* other);
    optional i8 compare(Object* other);      // <0 / 0 / >0, as NSComparisonResult
}
```

`equals` is required. **`compare` is optional, on purpose:** equality is universal and
ordering is not — a colour can be compared for sameness without any colour being "less than"
another.

A class that omits `compare` simply has no order, and the language says so honestly. An
unimplemented optional method leaves a **null vtable slot**, so:

```c
cmp1_t^ f = &obj.compare;      // null when the class doesn't implement it
if (f) { … }                   // this IS respondsTo
```

`Array.sort()` runs exactly that test and returns `false` rather than inventing an order for
things that define none. If you want those sorted, say what the order is:
`sortUsing(&yourComparator)`.

`Number`, `String` and `Data` all implement `compare`.

### `Hashable`

```c
protocol Hashable
{
    u32  hash(void);           // u8 on the 6502 build
    bool equals(Object* other);
}
```

Equal keys must hash equally. `String` and `Data` use FNV-1a over their bytes; `Number`
scrambles its 32-bit value; `Object`'s default hashes the instance's address, so distinct
instances hash apart.

A class can list both `<Comparable, Hashable>` and satisfy the shared `equals` slot with a
single method body.

### `Enumerable`

```c
protocol Enumerable
{
    u32     enumLength(void);      // u16 on the 6502 build
    Object* enumAt(u32 i);
}
```

What `for (x in collection)` dispatches through. Implement the two methods and your class
works with for-in. `Array`, `Map` (yielding keys) and `Set` all conform.

The loop variable is **borrowed** — the element belongs to the container — so the loop never
retains or releases it.

### `Error`

```c
protocol Error
{
    String* message(void);
}
```

What a value must conform to in order to be [`throw`](/compiler/language/errors/)n. One requirement,
so a handler can always say something useful about what it caught without knowing the concrete type.

```c
class ParseError <Error>
{
    String* msg;
    void init(String* m)  { msg = m; }
    String* message(void) { return msg; }
}
```

Errors are ordinary heap objects following ordinary ARC — nothing about `throw` makes them special.
A caught error is a strong local, released at the end of its `catch` scope. That is deliberate: the
error model reuses protocols, RTTI and the object model rather than adding a mechanism beside them.

`Error.xc` is **not** part of the `Foundation.xc` umbrella. Import it by name:

```c
#import <Error.xc>
```

## Ownership

Containers hold a **strong** reference to everything they store, and release it when the
element is removed or the container dies. Sorting and reversing move pointers only; no
refcount changes. `sorted()`, `filtered()`, `mapped()`, `subarray()` and the Set algebra all
return **new** containers, leaving the originals untouched.
