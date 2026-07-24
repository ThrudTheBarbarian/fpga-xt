---
title: Lexical structure
description: Comments, identifiers, numeric and string literals, reserved words.
---

## Comments

xtc uses C-family comment syntax:

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
u8  c = %1010_0101;  // binary, with grouping underscore
u32 big = 16_777_216;
```

There is no `0x` prefix; xtc inherits `$` from 6502 assembler tradition.

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

```c
string greeting = "hello\n";
```

A character literal is a single character (or two characters where the first is `\`) inside single quotes, evaluated as a `u8`:

```c
u8 tab = '\t';
u8 a   = 'A';
```

String literals never split across source lines.

## Reserved words

These are the words the **lexer** turns into keyword tokens. They are never identifiers, anywhere.

`asm`, `auto`, `bool`, `break`, `case`, `catch`, `class`, `continue`, `default`, `defer`, `delete`, `double`, `else`, `enum`, `extern`, `false`, `final`, `float`, `for`, `global`, `i8`, `i16`, `i32`, `if`, `in`, `inline`, `new`, `optional`, `pointer`, `protocol`, `register`, `release`, `retain`, `return`, `sizeof`, `static`, `string`, `struct`, `switch`, `throw`, `throws`, `true`, `try`, `typedef`, `u8`, `u16`, `u32`, `use`, `void`, `volatile`, `while`.

Separately, the parser rejects the **C reserved words** as variable names even where xtc gives them no meaning of its own, so that C-shaped source doesn't quietly acquire a different meaning:

`char`, `const`, `do`, `goto`, `int`, `long`, `restrict`, `short`, `signed`, `union`, `unsigned` — plus those above that C also reserves.

### Contextual words

A third group is meaningful only in a particular position, and is an ordinary identifier everywhere else: `self` and `super` inside a method body; `init` and `dealloc` as method names; `weak:`, `banked:`, `main:` and `shadow:` as declaration qualifiers; `va_start` / `va_arg` / `va_end` inside a variadic; `clobbers` after an `asm` block; and the function annotations (`:naked`, `:hwStack`, `:irq`, `:vbi`, …) documented on the [Functions](/compiler/language/functions/) page. Using one of these as a variable name is legal but a reliable way to confuse the next reader.

## Block delimiters

Both `{ ... }` and `(( ... ))` introduce a block; they are interchangeable everywhere a block is accepted (function bodies, control flow, inline-asm, and so on).

```c
void greet(void) {
    Stdio.print("hi\n");
}

void greet(void) ((
    Stdio.print("hi\n");
))
```

The `(( ))` form exists so xtc source can be typed on an **Atari 8-bit keyboard**, which has no `{` or `}` keys. The current toolchain is cross-compiled from desktop machines so the alternative form isn't load-bearing today, but it preserves the option of editing or even self-hosting xtc on-target in the future. There is no semantic difference between the two forms.

## Statement terminator

Statements terminate with `;`. The terminator is not optional — function declarations without a body, variable declarations, and expression statements all end in `;`.
