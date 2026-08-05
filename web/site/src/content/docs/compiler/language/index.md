---
title: Language reference
description: The xtc language — syntax, types, classes, protocols, memory, collections, threading and inline assembly.
---

xtc is a small, statically-typed language with C-family syntax, ObjC-like classes
and protocols, and a focus on producing dense code on machines that cannot afford
waste. Every page below carries a **worked example that compiles and runs** — the
programs live in the repository and are built by a script, so a code block here
cannot drift from what the compiler actually does.

## Where to start

If you're reading top-to-bottom, this is the recommended order:

1. [**Lexical structure**](/compiler/language/lexical/) — comments, identifiers, numeric and string literals, reserved words.
2. [**Preprocessor**](/compiler/language/preprocessor/) — `#include` / `#import`, `#define`, conditional compilation.
3. [**Types**](/compiler/language/types/) — the fixed-width scalars including `i64`/`u64`, structs, enums, pointers, arrays, inference, casting.
4. [**Operators**](/compiler/language/operators/) — the full precedence table, including the rotate (`<:` `:>`) and byte-extract (`<` `>` `>>` `>>>`) operators.
5. [**Statements & control flow**](/compiler/language/statements/) — declaration modifiers, `if`, `switch`, the two `for` loops, `while`, `defer`, `:unroll`.
6. [**Functions**](/compiler/language/functions/) — declarations, multiple return values, varargs, overloading, function annotations.
7. [**Classes**](/compiler/language/classes/) — heap and stack allocation, methods, properties, `init` / `dealloc`.
8. [**Inheritance & protocols**](/compiler/language/inheritance/) — single inheritance, virtual dispatch, downcasts (`(Dog*)a` and the failable `(Dog* ?)a`), protocols and optional methods.
9. [**Bound methods & callbacks**](/compiler/language/bound-methods/) — `^`, target/action, and why a callback needs no context pointer.
10. [**Errors**](/compiler/language/errors/) — the `throws` effect, `throw`, typed and untyped `catch` arms, the `Error` protocol.
11. [**Heap, ARC & weak refs**](/compiler/language/memory/) — `new` / `delete`, automatic reference counting, `weak:` references, manual `-farc=off` mode.
12. [**Collections & strings**](/compiler/language/collections/) — `Array<T>`, `Map<V>`, `Set<T>`, `String`, and how element types are checked then erased.
13. [**Threading**](/compiler/language/threading/) — `Thread`, `Mutex`, `Atomic`, `Pool`, and the automatic atomic-refcount decision. Native targets only.
14. [**Modules & shared libraries**](/compiler/language/modules/) — `--emit-lib`, `#import <Lib>`, what crosses a library boundary, and `extern` globals.
15. [**Inline assembly**](/compiler/language/inline-asm/) — `asm { … }` blocks, byte-extract operators, reaching xtc variables, the `clobbers` annotation.

For day-to-day reference, jump straight to the page you need from the sidebar.

## Things that differ from C

Worth knowing before you write the first program:

- **The pointer sigil binds to the type.** `u8* a, b;` declares **two pointers**,
  not a pointer and an integer.
- **No promotion to `int`.** Same-width arithmetic stays at that width, so
  `u8 + u8` wraps at 8 bits. Only genuinely mixed-width operands widen.
- **`printf` widths are explicit.** `%d` is 16-bit and `%ld` is 32-bit, both
  signed. The compiler checks the format string against the argument types.
- **Source files are `.xc`.** (`.xt` still resolves, transitionally.)
- **`@` used to be the pointer sigil** and is still accepted, but `*` is the
  spelling everywhere now.

## What's not on these pages

- **Compiler flags, optimisation levels, memory-model selection** live in
  [Compiler usage](/compiler/usage/) — they shape the output but are not part of
  the language. Start with [Install](/compiler/usage/install/).
- **Standard library classes** (`Stdio`, `Math`, `Heap`, `Assert`, …) live in the
  [Standard library reference](/compiler/api/).
- **Memory-model internals** (the two bank windows, the hardware stack) are
  summarised where they affect semantics; the full map is in
  [Compiler usage → Memory models](/compiler/usage/memory-models/).
