---
title: String 0.3 (legacy)
description: "The byte-oriented String surface as it stood in 0.3 — removed from the hosted targets in 0.4, still the live surface on xt6502."
---

:::caution[This is the 0.3 surface]
In **0.4** the hosted String (arm64 / x86_64 / win64) renamed every method
that indexes into the string, so the name says whether it counts **bytes**
or **characters** — and `charAt` / `appendChar` changed meaning. The
spellings below no longer compile on the hosted targets, with two dangerous
exceptions ([reused names](/compiler/usage/migration/#the-two-reused-names)).
The current reference is [String (UTF-8)](/compiler/api/string/); porting is
covered by the [0.3 → 0.4 migration guide](/compiler/usage/migration/).

On **xt6502** this page is still the truth: the 6502 String stays
byte-oriented (indexes are `u16` there), keeps every name below, and adds
aliases under the 0.4 Byte-names so shared byte-only source compiles
everywhere from one file.
:::

A heap-owned, NUL-terminated byte string. `charAt(i)` returns **the i-th
byte** — on this surface a "char" is a `u8`, exactly as in C.

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
| **Read** | `length()`, `isEmpty()`, `charAt(i)`, `cString()`, `copyCString()` |
| **Search** | `indexOf(needle)`, `indexOfChar(c)`, `lastIndexOfChar(c)`, `contains(s)`, `hasPrefix(s)`, `hasSuffix(s)` |
| **Slice** | `substring(from, len)`, `substringFrom(from)`, `substringTo(to)` |
| **Mutate** | `append(s)`, `appendChar(c)`, `appendCString(p)` — and `appending(s)`, which returns a new String instead |
| **Case** | `uppercased()`, `lowercased()`, `caseInsensitiveCompare(s)`, `equalsIgnoringCase(s)` |
| **Other** | `trimmed()`, `split(sep)` → `Array*`, `String.join(parts, sep)`, `replacing(find, sub)`, `description()` |
| **Value** | `equals(other)`, `compare(other)`, `hash()` — FNV-1a over the bytes |

Out-of-range slicing **clamps to empty** rather than faulting —
`substringFrom(999)` is an empty String, the same choice Foundation makes for
a clamped range.

`split` yields empty components for consecutive, leading or trailing
separators, so `"a,,b"` is three fields. That is what a CSV needs; filter the
empties out if you want tokens.

Ordering is lexicographic by unsigned byte, then by length — so a prefix
sorts before its extension (`"go"` before `"gone"`).

**`cString()` is a borrow.** It returns a pointer into the String's own
buffer, and any mutation that grows the String — `append`, `appendChar`,
`appendCString`, `appendFormat`, `insert` — may reallocate that buffer and
free the old one. The pointer is valid until the String is next grown; after
that it dangles, and it *usually still appears to work*, which is exactly the
failure that survives testing. A `string` is not a class pointer, so holding
one neither retains the String nor stops it growing. If the bytes must
outlive the next mutation, take a copy: `copyCString()` returns a fresh heap
copy that the caller owns (and frees with `delete`).

## The 0.4 Byte-name aliases (xt6502)

So that byte-only code can be written once for every target, the xt6502
String also accepts the 0.4 spellings, each a thin alias for the method
above it:

| 0.4 spelling (alias) | xt6502 implementation |
|---|---|
| `byteLength()` | `length()` |
| `byteAt(i)` | `charAt(i)` |
| `appendByte(c)` | `appendChar(c)` |
| `byteIndexOf(needle[, from])` | `indexOf(…)` |
| `indexOfByte(c)` / `lastIndexOfByte(c)` | `indexOfChar(c)` / `lastIndexOfChar(c)` |
| `substringBytes(from, len)` / `substringFromByte(from)` / `substringToByte(to)` | `substring(…)` / `substringFrom(…)` / `substringTo(…)` |
| `insertAtByte(at, s)` / `insertByte(at, c)` / `insertCStringAtByte(at, p)` | `insert(…)` / `insertChar(…)` / `insertCString(…)` |
| `deleteByteRange(at, len)` / `replaceByteRange(at, len, s)` | `deleteRange(…)` / `replaceRange(…)` |
| `byteIndexOfSet(cs)` / `lastByteIndexOfSet(cs)` / `containsByteFromSet(cs)` | `indexOfCharacterFrom(cs)` / `lastIndexOfCharacterFrom(cs)` / `containsCharacterFrom(cs)` |
| `splitOnSet(cs)` / `splitOnByte(sep)` | `split(cs)` / `split(sep)` |

There is **no character layer** on xt6502 — no `charCount`, no code-point
`charAt`, no encodings. A UTF-8 decoder is the wrong tax on a 6502.
