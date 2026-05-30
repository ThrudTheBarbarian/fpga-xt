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

The following identifiers are reserved and may not be used as names. They cover types, control flow, declaration modifiers, class machinery, and inline-asm syntax.

`asm`, `auto`, `bool`, `break`, `case`, `class`, `clobbers`, `continue`, `default`, `delete`, `dealloc`, `do`, `double`, `else`, `enum`, `false`, `float`, `for`, `global`, `i8`, `i16`, `i32`, `if`, `in`, `init`, `inline`, `naked`, `new`, `pointer`, `protocol`, `register`, `release`, `retain`, `return`, `self`, `sizeof`, `static`, `string`, `struct`, `super`, `switch`, `true`, `typedef`, `u8`, `u16`, `u32`, `va_arg`, `va_end`, `va_start`, `void`, `volatile`, `weak`, `while`.

The exact set is what the lexer recognises; the parser may accept more in context (e.g. function annotations like `:hwStack`, `:irq`, `:vbi`) which are documented on the [Functions](/compiler/language/functions/) page.

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
