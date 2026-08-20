---
title: String (UTF-8)
description: "The 0.4 String: UTF-8 inside, with Byte and Char in every method name that indexes — bytes and characters are different units, and the name tells you which one you are using."
---

A heap-owned, NUL-terminated **UTF-8** string. Since **0.4** the class is
honest about the two units it deals in:

- **`Byte` in the name → byte semantics.** Indexes, lengths and slices count
  raw bytes. O(1) indexing, and the right unit for parsing, protocols and
  file formats.
- **`Char` in the name → character semantics.** Indexes and counts are Unicode
  code points, decoded from the UTF-8. `charAt(1)` of `"héllo"` is `U+00E9`,
  not the second byte of its encoding.
- **No unit in the name → whole-string.** `append`, `trimmed`, `split`,
  `equals`, `hasPrefix` … operate on the string as a value and never took an
  index in the first place.

Before 0.4 the byte operations carried the short names (`length`, `charAt`,
`substring`, `indexOf` …), and `charAt` returned a **byte**. Those spellings
are gone from the hosted String — a 0.3 program fails to compile, loudly,
rather than silently changing meaning. The renames, the two exceptions that
*were* reused, and the `--migrate` flag that turns them loud too are all in
the [0.3 → 0.4 migration guide](/compiler/usage/migration/). The old surface
is documented on the [String 0.3 (legacy)](/compiler/api/string-03/) page —
which is also, deliberately, still the shape of the **xt6502** String (see
[Targets](#targets) below).

```c
String* s = String.withCString("h");
s.appendChar((u32)$E9);          // é   U+00E9 — appended as 2 UTF-8 bytes
s.appendCString("llo");
s.appendChar((u32)$26A1);        // ⚡  U+26A1 — 3 bytes

s.byteLength();                  // 9   bytes
s.charCount();                   // 6   code points
s.byteAt((u32)1);                // $C3 — first byte of é's encoding
s.charAt((u32)1);                // $E9 — the character é itself
s.substringChars((u32)1, (u32)2) // "él" — slicing by characters
```

## The byte surface

| | |
|---|---|
| **Build** | `String.withCString(p)`, `withString(s)`, `withBytes(p, n)`, `withFormat(fmt, …)` |
| **Numbers** | `String.withI32(v)`, `withU32(v)`, `withI64(v)`, `withU64(v)`, `withI16(v)`, `withU16(v)`, `withFloat(v[, precision])` |
| **Read** | `byteLength()`, `isEmpty()`, `byteAt(i)`, `cString()`, `copyCString()` |
| **Search** | `byteIndexOf(needle[, from])`, `indexOfByte(c)`, `lastIndexOfByte(c)`, `contains(s)`, `hasPrefix(s)`, `hasSuffix(s)` |
| **Slice** | `substringBytes(from, len)`, `substringFromByte(from)`, `substringToByte(to)` |
| **Mutate** | `append(s)`, `appendByte(c)`, `appendCString(p)`, `appendBytes(p, n)`, `appendFormat(fmt, …)`, `insertAtByte(at, s)`, `insertByte(at, c)`, `insertCStringAtByte(at, p)`, `deleteByteRange(at, len)`, `replaceByteRange(at, len, s)`, `clear()`, `setTo(s)`, `setCString(p)` — and `appending(s)`, which returns a new String instead |
| **Character sets** | `byteIndexOfSet(cs)`, `lastByteIndexOfSet(cs)`, `containsByteFromSet(cs)`, `trimmed(cs)`, `splitOnSet(cs)`, `asCharacterSet()` |
| **Case** | `uppercased()`, `lowercased()`, `caseInsensitiveCompare(s)`, `equalsIgnoringCase(s)` — ASCII only, by design |
| **Paths** | `isAbsolutePath()`, `lastPathComponent()`, `deletingLastPathComponent()`, `pathExtension()`, `deletingPathExtension()`, `appendingPathComponent(s)`, `appendingPathExtension(s)` |
| **Other** | `trimmed()`, `splitOnByte(sep)` → `Array*`, `String.join(parts, sep)`, `replacing(find, sub)`, `description()` |
| **Value** | `equals(other)`, `compare(other)`, `hash()` — FNV-1a over the bytes |

Searching returns a byte index, and a miss is `String.notFound()` rather than
a negative number. Out-of-range slicing **clamps to empty** rather than
faulting. `splitOnByte` yields empty components for consecutive, leading or
trailing separators, so `"a,,b"` is three fields — what a CSV needs; filter
the empties if you want tokens.

Because UTF-8 preserves code-point order under byte comparison, `equals`,
`compare` and `hash` needed no character-aware variants: byte order **is**
character order. Ordering is lexicographic by unsigned byte, then by length,
so a prefix sorts before its extension (`"go"` before `"gone"`).

## The character surface

All `since("0.4")`, all hosted-targets-only (see [Targets](#targets)).

| | |
|---|---|
| **Count / index** | `charCount()` — code points, O(n); `charAt(n)` — the n-th code point, O(n); `byteIndexOfChar(n)` — where the n-th character's bytes start |
| **By byte position** | `charAtByte(at)` — the code point whose encoding starts at byte `at`; `charByteLength(at)` — how many bytes it occupies; `nextCharByte(at)` / `prevCharByte(at)` — walk boundaries; `isCharBoundary(at)` |
| **Build / mutate** | `String.withChar(cp)`, `appendChar(cp)` — encodes the code point as UTF-8 |
| **Slice** | `substringChars(fromChar, count)` |
| **Validation** | `isValidUtf8()`, `sanitizedUtf8()` |

**Walk by byte index, not by character index.** `charAt(n)` restarts from the
front each call, so a `charAt` loop is O(n²). The idiomatic scan is linear:

```c
u32 i = (u32)0;
while (i < s.byteLength()) {
    u32 cp = s.charAtByte(i);
    // … use cp …
    i = s.nextCharByte(i);
}
```

### Malformed bytes

A String is a byte buffer first — nothing stops `appendByte` from writing
half a sequence, and bytes from the outside world arrive as they arrive. The
decoder is strict (overlong encodings, unpaired surrogates, values above
`U+10FFFF` and truncated sequences are all invalid) and the reading rules are
predictable:

- `charAtByte` returns **U+FFFD** for a byte position that does not start a
  valid sequence; the walk functions treat each invalid byte as one
  character, so iteration always terminates and never reads past the end.
- `isValidUtf8()` answers for the whole string.
- `sanitizedUtf8()` returns a repaired **copy**: each maximal invalid subpart
  becomes one U+FFFD — the Unicode-recommended repair, the same choice a
  browser makes. Valid input comes back byte-identical.

## Other encodings

Internally a String is always UTF-8 — there is no per-String encoding mode.
Other encodings are transcoded **at the edge**, on the way in or out:

```c
enum StrEncoding = {ENC_UTF8, ENC_ASCII, ENC_LATIN1, ENC_UTF16LE, ENC_UTF16BE};

String* s = String.withEncodedBytes(buf, n, ENC_LATIN1);   // decode: bytes -> String
Data*   d = Data.withStringEncoded(s, ENC_ASCII);          // encode: String -> bytes
```

- **Decoding** repairs malformed input to U+FFFD — an unpaired UTF-16
  surrogate, an odd trailing byte, an ASCII byte above 127. Latin-1 cannot be
  malformed: a byte *is* its code point.
- **Encoding** substitutes `?` for a code point the target cannot express
  (Latin-1 above U+00FF, ASCII above U+007F) — the caller chose the narrower
  world. UTF-16 output emits surrogate pairs for the astral planes.
- `ENC_UTF8` out is a plain byte copy, **including** any invalid bytes the
  String carries: export does not silently repair. Call `sanitizedUtf8()`
  first if that is what you want.

The exporter lives on `Data`, not `String`, because Data already imports
String and the house rule keeps the bridge on one side.

## `cString()` is a borrow

It returns a pointer into the String's own buffer, and any mutation that
grows the String — `append`, `appendChar`, `appendByte`, `appendFormat`,
`insertAtByte` — may reallocate that buffer and free the old one. The pointer
is valid until the String is next grown; after that it dangles, and it
*usually still appears to work*, which is exactly the failure that survives
testing. A `string` is not a class pointer, so holding one neither retains
the String nor stops it growing. If the bytes must outlive the next mutation,
take a copy: `copyCString()` returns a fresh heap copy the caller owns (and
frees with `delete`).

## Targets

The Byte/Char split and the character layer are the String of the **hosted
targets** — arm64, x86_64, win64. The **xt6502** String stays byte-oriented
(a UTF-8 decoder is the wrong tax on a 6502) and keeps the 0.3 surface, plus
`since("0.4")` aliases for the Byte-named spellings — so shared source that
sticks to byte operations under the new names compiles everywhere from one
file. There is no `charCount`/`charAt`-as-code-point layer on xt6502: code
that needs it is code that should not be running there anyway.

## Worked example

Compiles and runs on the hosted targets; `examples/compiler/strings.xc`.

```c
// strings.xc — the 0.4 String: bytes and characters, named apart.
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    // "héllo⚡" — 6 characters, 9 bytes: é is 2 bytes, ⚡ is 3.
    String* s = String.withCString("h");
    s.appendChar((u32)$E9);          // é   U+00E9, encoded as 2 bytes
    s.appendCString("llo");
    s.appendChar((u32)$26A1);        // ⚡  U+26A1, encoded as 3 bytes

    Stdio.printf("bytes %d, chars %d\n",
                 (i16)s.byteLength(), (i16)s.charCount());

    // Byte in the name = byte semantics; Char = code points.
    Stdio.printf("byteAt(1) %lx, charAt(1) U+%lx\n",
                 (u32)s.byteAt((u32)1), s.charAt((u32)1));

    Stdio.printf("slice chars '%s'\n",
                 s.substringChars((u32)1, (u32)2).cString());

    // Walking characters by byte index — no O(n^2) charAt loop.
    u32 i = (u32)0;
    while (i < s.byteLength()) {
        Stdio.printf("U+%lx ", s.charAtByte(i));
        i = s.nextCharByte(i);
    }
    Stdio.printf("\n");

    // Malformed bytes read as U+FFFD; sanitizedUtf8 repairs a copy.
    String* bad = String.withCString("a");
    bad.appendByte((u8)$C3);         // a lead byte with no continuation
    bad.appendCString("z");
    Stdio.printf("valid %d, chars %d, repaired chars %d\n",
                 (i16)(bad.isValidUtf8() ? 1 : 0),
                 (i16)bad.charCount(),
                 (i16)bad.sanitizedUtf8().charCount());

    // Other encodings transcode at the edge; inside it is always UTF-8.
    u8 latin[3];
    latin[0] = (u8)'c'; latin[1] = (u8)$E9; latin[2] = (u8)'!';   // "cé!" in Latin-1
    String* dec = String.withEncodedBytes(&latin[0], (u32)3, ENC_LATIN1);
    Stdio.printf("latin-1 in: '%s' (%d bytes)\n",
                 dec.cString(), (i16)dec.byteLength());

    Data* enc = Data.withStringEncoded(dec, ENC_ASCII);           // é -> '?'
    Stdio.printf("ascii out: %s\n", enc.hexString().cString());
    return 0;
}
```

```
bytes 9, chars 6
byteAt(1) 000000C3, charAt(1) U+000000E9
slice chars 'él'
U+00000068 U+000000E9 U+0000006C U+0000006C U+0000006F U+000026A1
valid 0, chars 3, repaired chars 3
latin-1 in: 'cé!' (4 bytes)
ascii out: 633f21
```
