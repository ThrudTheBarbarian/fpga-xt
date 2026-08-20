---
title: Lexical structure
description: Comments, identifiers, numeric and string literals, reserved words.
---

## Comments

xcc uses C-family comment syntax:

```c
// single-line — runs to end of line
/* block — runs until the matching closer */
```

## Identifiers

- Case-sensitive (`Foo` and `foo` are distinct).
- Start with a letter; subsequent characters may be letters, digits, or underscore.
- Reserved words may not be used as variable, class, or struct names.

## Numeric literals

Three radix prefixes are recognised, and `_` is silently ignored anywhere inside a numeric literal so you can group digits for readability.

```c
u16 a = 1234;        // decimal
u16 b = $1234;       // hex
u16 c = 0x1234;      // hex, the C spelling — identical to the line above
u8  d = %1010_0101;  // binary, with grouping underscore
u32 big = 16_777_216;
u32 mask = 0xFFFF_0000;   // underscores work in either hex spelling
```

`$` comes from 6502 assembler tradition and `0x` (or `0X`) from C; they mean
exactly the same thing and either can be used anywhere. Binary keeps `%`.

## String and character literals

Strings are double-quoted, null-terminated, but the trailing `\0` is **not** counted in `length`. The recognised escape sequences are:

| Escape | Means |
|--------|-------|
| `\n` | newline (CR + LF) |
| `\r` | carriage return |
| `\t` | tab |
| `\0` | end-of-string marker |
| `\\` | a literal backslash |
| `\"` | a literal `"` inside a string |
| `\'` | a literal `'` inside a character literal |
| `\xNN` | an ASCII byte — exactly 2 hex digits, `00`–`7F` *(since 0.4)* |
| `\uNNNN` | a Unicode code point — exactly 4 hex digits *(since 0.4)* |
| `\UNNNNNNNN` | a Unicode code point — exactly 8 hex digits *(since 0.4)* |

```c
string greeting = "hello\n";
String* s = String.withCString("caf\u00E9 \U0001F600");   // "café 😀"
```

`\u` and `\U` land in the string as **UTF-8** — `"\u00E9"` is the two bytes
`C3 A9` — and a surrogate (`D800`–`DFFF`) or a value above `10FFFF` is a
compile error. The digit counts are fixed, unlike C's greedy `\x`. And `\x`
is deliberately capped at `7F`, also unlike C: a bare byte above `7F` inside
a UTF-8 string is either half a character (which `\u` says better) or
deliberate binary (which `Data`/`appendByte` say better), so the compiler
refuses it rather than silently re-encoding. Source files are UTF-8, so a raw
`é` in a literal is equivalent to `\u00E9`.

A character literal is a single character (or an escape) inside single quotes, evaluated as a `u8`:

```c
u8 tab = '\t';
u8 a   = 'A';
u8 e   = '\u00E9';    // must fit a u8 — the Latin-1 view
```

Spell a non-ASCII character in a char literal with `\u`, not as a raw
character — a raw multi-byte character between single quotes is not portable.

A single string literal never splits across source lines — but **adjacent string
literals concatenate**, as in C, and a newline between them makes no difference:

```c
Stdio.print("one" "two\n");                 // onetwo

Stdio.print("a long message that would "
            "otherwise be one unbreakable "
            "source line as wide as itself\n");
```

The join happens in the parser, so the pieces are one literal by the time
anything else sees them — there is no run-time concatenation and no cost.

## Reserved words

These are the words the **lexer** turns into keyword tokens. They are never identifiers, anywhere.

`asm`, `auto`, `bool`, `break`, `case`, `catch`, `class`, `continue`, `default`, `defer`, `delete`, `double`, `else`, `enum`, `extern`, `false`, `final`, `float`, `for`, `global`, `i8`, `i16`, `i32`, `if`, `in`, `inline`, `new`, `optional`, `pointer`, `protocol`, `register`, `release`, `retain`, `return`, `sizeof`, `static`, `string`, `struct`, `switch`, `throw`, `throws`, `true`, `try`, `typedef`, `u8`, `u16`, `u32`, `use`, `void`, `volatile`, `while`.

Separately, the parser rejects the **C reserved words** as variable names even where xcc gives them no meaning of its own, so that C-shaped source doesn't quietly acquire a different meaning:

`char`, `const`, `do`, `goto`, `int`, `long`, `restrict`, `short`, `signed`, `union`, `unsigned` — plus those above that C also reserves.

### Contextual words

A third group is meaningful only in a particular position, and is an ordinary identifier everywhere else: `self` and `super` inside a method body; `init` and `dealloc` as method names; `weak:`, `banked:`, `main:` and `shadow:` as declaration qualifiers; `va_start` / `va_arg` / `va_end` inside a variadic; `clobbers` after an `asm` block; and the function annotations (`:naked`, `:hwStack`, `:irq`, `:vbi`, …) documented on the [Functions](/compiler/language/functions/) page. Using one of these as a variable name is legal but a reliable way to confuse the next reader.

## Block delimiters

A block is `{ ... }`.

```c
void greet(void) {
    Stdio.print("hi\n");
}
```

:::note[`(( ))` has been removed]
xcc once accepted `(( ... ))` as an alternative block delimiter, so source could
be typed on an **Atari 8-bit keyboard** — which has no `{` or `}` keys. It is
gone, and the compiler now rejects it.

The reason is worth recording: accepting it forced the lexer to fuse adjacent
parentheses into a single block token, which made `((T*)p).f` ambiguous with the
start of a block. Disambiguating needed a lookahead heuristic in the lexer — a
lot of fragility to buy a spelling nothing in the tree used.
:::

## Statement terminator

Statements terminate with `;`. The terminator is not optional — function declarations without a body, variable declarations, and expression statements all end in `;`.
