---
title: Migrating 0.3 → 0.4
description: "The 0.4 String renamed every index-taking method to say bytes or chars — and reused two names with new meanings. since() annotations and --migrate=0.3:0.4 turn all of it into loud compile errors."
---

**0.4 broke the String API on purpose.** Every method that indexes into a
string now says which unit it counts — `Byte` or `Char` — because 0.3's
`charAt()` returned a byte while the class was becoming UTF-8-aware, and a
byte and a character are no longer the same thing. The full story is on the
[String (UTF-8)](/compiler/api/string/) page; the old surface is preserved on
[String 0.3 (legacy)](/compiler/api/string-03/). This page is the porting
recipe.

Only the **hosted targets** (arm64, x86_64, win64) are affected. An xt6502
program needs no changes: the 6502 String keeps the 0.3 names, and also
accepts the 0.4 Byte-spellings, so byte-only code can be written once for
both worlds.

## The renames

Mechanical — same behaviour, new name, all byte-denominated:

| 0.3 | 0.4 |
|---|---|
| `length()` | `byteLength()` *(already existed in 0.3)* |
| `charAt(i)` → `u8` | `byteAt(i)` |
| `indexOf(needle[, from])` | `byteIndexOf(needle[, from])` |
| `indexOfChar(c)` / `lastIndexOfChar(c)` | `indexOfByte(c)` / `lastIndexOfByte(c)` |
| `substring(from, len)` / `substringFrom(f)` / `substringTo(t)` | `substringBytes(…)` / `substringFromByte(…)` / `substringToByte(…)` |
| `appendChar(c)` *(byte)* | `appendByte(c)` |
| `insert(at, s)` / `insertChar(at, c)` / `insertCString(at, p)` | `insertAtByte(…)` / `insertByte(…)` / `insertCStringAtByte(…)` |
| `deleteRange(at, len)` / `replaceRange(at, len, s)` | `deleteByteRange(…)` / `replaceByteRange(…)` |
| `indexOfCharacterFrom(cs)` / `lastIndexOfCharacterFrom(cs)` / `containsCharacterFrom(cs)` | `byteIndexOfSet(cs)` / `lastByteIndexOfSet(cs)` / `containsByteFromSet(cs)` |
| `split(sep)` / `split(cs)` | `splitOnByte(sep)` / `splitOnSet(cs)` |

Whole-string operations that never took an index — `append`, `trimmed`,
`equals`, `hasPrefix`, `join`, `replacing`, `uppercased`, … — are unchanged.

## The two reused names

Renamed methods fail loudly: an old call site is a compile error with a
position. Two names were **reused with new meanings**, and those do *not*
fail — they compile silently and do something different:

| Name | 0.3 meaning | 0.4 meaning |
|---|---|---|
| `charAt(i)` | the i-th **byte**, as `u8` | the i-th **code point**, as `u32`, O(n) |
| `appendChar(c)` | append one raw **byte** | encode a **code point** as 1–4 UTF-8 bytes |

For ASCII data the two behave identically — which makes the difference
*worse*, because the program appears migrated until the first non-ASCII
input. This is the trap `--migrate` exists to close.

## `--migrate=0.3:0.4`

Compile **as if the library were still 0.3**:

```
xcc --migrate=0.3:0.4 -o prog prog.xc
```

Every member the library gained after 0.3 is annotated at its declaration:

```c
since("0.4") u32 charAt(u32 n) { … }
```

Under `--migrate`, members whose `since` is newer than the base version
vanish from method lookup. A 0.3-era `s.charAt(i)` no longer resolves to the
new code-point `charAt` — it becomes a plain *"No method 'charAt' on class
'String'"* error with a file, line and column, exactly like the renamed
methods. The workflow is:

1. Build with `--migrate=0.3:0.4`.
2. Fix every error the compiler reports — for byte-indexed code that is the
   rename table above, one spelling for another. Where the *intent* was
   characters, this is the moment to switch to the
   [character surface](/compiler/api/string/#the-character-surface) instead.
3. Drop the flag. Done — there is nothing left that changed meaning silently.

Let the compiler find the call sites rather than grepping: only the compiler
knows whether a given `.length()` receiver is a `String`, an `Array`, or a
class of yours that happens to share the name.

Two scoping rules keep the filter usable: a member is always visible inside
its own class (0.4 methods may call their 0.4 siblings), and to any caller
itself marked newer than the base (new library code composes). Versions
compare component-wise, so a future `"0.10"` is newer than `"0.9"`.

## `since("V")` in your own code

The annotation is general — any method can carry it:

```c
class Api
{
    u32 v1call(void) { … }
    since("2.0") u32 v2call(void) { … }
}
```

A library that reuses or repurposes a name across its own versions can offer
its users the same structured migration: annotate what changed, and the
user compiles with `--migrate=<their-version>:<yours>` to surface every
affected call site.
