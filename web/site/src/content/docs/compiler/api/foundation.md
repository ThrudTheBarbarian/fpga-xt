---
title: Foundation classes
description: "Object, Number, String, Data, Array, Map, Set — value wrappers, containers, ordering, sorting and the functional methods, with the Comparable / Hashable / Enumerable protocols behind them."
---

Foundation is xtc's standard object library: value wrappers (`Number`, `String`, `Data`),
containers (`Array`, `Map`, `Set`), and the three protocols they are built on (`Comparable`,
`Hashable`, `Enumerable`).

```c
#import "Foundation.xt"        // the umbrella — everything below
```

Every class inherits from the runtime's built-in `Object` root — every parentless `class X`
does — so a `Number@`, a `String@`, or any class of your own fits wherever an `Object@` is
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

## `Array`

An ordered, resizable list of `Object@`. Holds a strong reference to every element.

```c
Array@ a = new Array();
a.add(Number.with((i32)42));
a.add(String.withCString("hi"));

for (Object@ o in a) {                 // Enumerable
    Number@ n = (Number@ ?)o;          // safe-checked downcast
    if (n != 0) Stdio.printf("%d\n", n.asI16());
}
```

| | |
|---|---|
| **Build** | `new Array()`, `Array.withCapacity(n)`, `Array.withArray(other)` |
| **Read** | `count()`, `isEmpty()`, `capacity()`, `get(i)`, `first()`, `last()` |
| **Mutate** | `add(o)`, `insert(i, o)`, `set(i, o)`, `addAll(other)`, `removeAt(i)`, `removeFirst()`, `removeLast()`, `removeAll()` |
| **Search** | `indexOf(o)` / `contains(o)` — pointer identity; `indexOfEqual(c)` / `containsEqual(c)` — value equality |
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
    bool above(Object@ o) {
        Number@ n = (Number@ ?)o;
        return n != 0 && n.asI16() > limit;
    }
}

Threshold@ t = new Threshold();
t.limit = (i16)3;
Array@ big = rows.filtered(&t.above);      // the receiver comes along
t.limit = (i16)10;
Array@ bigger = rows.filtered(&t.above);   // same ^, different answer
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
Map@ m = new Map();
m.set(String.withCString("width"), Number.with((i32)320));

Number@ w = (Number@ ?)m.get(String.withCString("width"));
for (Object@ key in m) { … }               // for-in yields the KEYS
```

| | |
|---|---|
| **Build** | `new Map()`, `Map.withCapacity(n)` |
| **Read** | `count()`, `isEmpty()`, `get(k)`, `getOrDefault(k, fallback)`, `containsKey(k)` |
| **Views** | `allKeys()`, `allValues()` — each an `Array@` |
| **Mutate** | `set(k, v)`, `remove(k)`, `removeAll()` |

`containsKey` asks whether the **key** is present, which is a different question from "is
`get(k)` non-null" — a key stored with a null value is still a key.

## `Set`

A hash set of `Hashable` + `Comparable` elements, and the algebra that makes one worth having
over an Array.

```c
Set@ online = Set.withArray(currentUsers);
Set@ known  = Set.withArray(allUsers);

Set@ newcomers = online.subtract(known);       // who is new
Set@ shared    = online.intersect(known);      // who is in both
```

| | |
|---|---|
| **Build** | `new Set()`, `Set.withCapacity(n)`, `Set.withArray(a)` |
| **Read** | `count()`, `isEmpty()`, `contains(e)`, `allObjects()` |
| **Mutate** | `add(e)`, `remove(e)`, `removeAll()` |
| **Algebra** | `unionWith(s)`, `intersect(s)`, `subtract(s)`, `symmetricDifference(s)` |
| **Relations** | `isSubsetOf(s)`, `isSupersetOf(s)`, `intersects(s)`, `isDisjointFrom(s)`, `equalsSet(s)` |

Every algebra method returns a **new** Set; neither operand is modified.

## `String`

A heap-owned, NUL-terminated byte string.

```c
String@ s = String.withCString("  Hello, World  ");
String@ t = s.trimmed();                             // "Hello, World"

if (t.hasPrefix(String.withCString("Hello"))) { … }

Array@ fields = String.withCString("a,b,,c").split((u8)',');   // 4 parts — the gap counts
String@ back  = String.join(fields, String.withCString("-"));  // "a-b--c"
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
| **Other** | `trimmed()`, `split(sep)` → `Array@`, `String.join(parts, sep)`, `replacing(find, sub)` |

Out-of-range slicing **clamps to empty** rather than faulting — `substringFrom(999)` is an
empty String, the same choice Foundation makes for a clamped range.

`split` yields empty components for consecutive, leading or trailing separators, so `"a,,b"`
is three fields. That is what a CSV needs; filter the empties out if you want tokens.

Ordering is lexicographic by unsigned byte, then by length — so a prefix sorts before its
extension (`"go"` before `"gone"`).

## `Data`

An opaque byte block. No trailing NUL, no character semantics.

```c
Data@ d = Data.withBytes(&raw[0], (u32)4);
Stdio.printf("%s\n", d.hexString().cString());     // "deadbeef"
```

| | |
|---|---|
| **Build** | `Data.withBytes(p, n)`, `withCapacity(n)`, `withData(other)` |
| **Read** | `length()`, `isEmpty()`, `bytes()`, `byteAt(i)` |
| **Mutate** | `setByteAt(i, v)`, `appendByte(b)`, `append(other)`, `appendBytes(p, n)` |
| **Slice** | `subdata(from, len)`, `subdataFrom(from)` |
| **Search** | `indexOfByte(b)`, `containsByte(b)` |
| **Text** | `hexString()`, `description()` |

## `Number`

A wrapper around any sized integer or a float. Conversion between the two is lazy and cached.

```c
Number@ n = Number.with((i32)-42);
Stdio.printf("%s\n", n.description().cString());   // "-42"

Number@ f = Number.withFloat(3.25);
Stdio.printf("%s\n", f.description().cString());   // "3.250"
```

`with(v)` picks the storage kind from the argument's type; `withI8` / `withU16` / `withI32` /
`withFloat` pin it explicitly. `asI32()` / `asFloat()` / `asI16()` … read it back, and
`value()` is return-type-overloaded so it takes its kind from the destination.

`description()` renders an Int exactly and a Float to **three decimal places** — deliberately
not a general float formatter, and candid about being exactly that.

Cross-kind comparison promotes to float, so `Number.with((i16)42)` and
`Number.withFloat(42.0)` are **equal**, and `compare` agrees with `equals`.

## The protocols

### `Comparable`

```c
protocol Comparable
{
    bool equals(Object@ other);
    optional i8 compare(Object@ other);      // <0 / 0 / >0, as NSComparisonResult
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
    bool equals(Object@ other);
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
    Object@ enumAt(u32 i);
}
```

What `for (x in collection)` dispatches through. Implement the two methods and your class
works with for-in. `Array`, `Map` (yielding keys) and `Set` all conform.

The loop variable is **borrowed** — the element belongs to the container — so the loop never
retains or releases it.

## Ownership

Containers hold a **strong** reference to everything they store, and release it when the
element is removed or the container dies. Sorting and reversing move pointers only; no
refcount changes. `sorted()`, `filtered()`, `mapped()`, `subarray()` and the Set algebra all
return **new** containers, leaving the originals untouched.
