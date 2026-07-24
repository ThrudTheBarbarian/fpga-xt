---
title: Language reference
description: The xtc language — syntax, types, classes, memory, and inline assembly.
---

xtc is a small, statically-typed language with C-family syntax and a focus on producing dense code. The language is small enough that the reference fits in twelve short pages.

## Where to start

If you're reading top-to-bottom, this is the recommended order:

1. [**Lexical structure**](/compiler/language/lexical/) — comments, identifiers, numeric and string literals, reserved words.
2. [**Preprocessor**](/compiler/language/preprocessor/) — `#include` / `#import`, `#define`, conditional compilation.
3. [**Types**](/compiler/language/types/) — primitives, structs, enums, pointers, arrays, type inference, casting.
4. [**Operators**](/compiler/language/operators/) — full precedence table including the rotate (`<:` `:>`) and byte-extract (`<` `>` `>>` `>>>`) operators.
5. [**Statements & control flow**](/compiler/language/statements/) — variable declaration modifiers, `if`, `switch`, the two `for` loops, `while`, `defer`, `:unroll`.
6. [**Functions**](/compiler/language/functions/) — declarations, tuple returns, varargs, overloading, function annotations.
7. [**Classes**](/compiler/language/classes/) — instance and stack allocation, methods, properties (getter / setter rewrites), `init` / `dealloc`.
8. [**Inheritance & protocols**](/compiler/language/inheritance/) — single inheritance, virtual dispatch, downcasts (`(Dog@)a` and the failable `(Dog@ ?)a`), protocols.
9. [**Errors**](/compiler/language/errors/) — the `throws` effect, `throw`, typed and untyped `catch` arms, and the `Error` protocol.
10. [**Heap, ARC & weak refs**](/compiler/language/memory/) — `new` / `delete`, automatic reference counting, `weak:` references, manual `-farc=off` mode.
11. [**Modules & shared libraries**](/compiler/language/modules/) — `--emit-lib`, `#import <Lib>`, what crosses a `.so` boundary, and `extern` globals.
12. [**Inline assembly**](/compiler/language/inline-asm/) — `asm { ... }` blocks, byte-extract operators, accessing xtc variables and the `clobbers` annotation.

For day-to-day reference, jump straight to the page you need from the sidebar.

## What's not on these pages

- **Compiler flags, optimisation levels, memory-model selection** live in [Compiler usage](/compiler/usage/) — they shape the output but aren't part of the language.
- **Standard library classes** (`Stdio`, `Math`, `Heap`, `Vbi`, `Assert`, …) live in the [Standard library reference](/compiler/api/).
- **Memory-model internals** (zero-page layout, the two bank windows, the hardware stack) are summarised throughout the language pages where they affect semantics, but the full map lives in [Compiler usage → Memory models](/compiler/usage/memory-models/).
