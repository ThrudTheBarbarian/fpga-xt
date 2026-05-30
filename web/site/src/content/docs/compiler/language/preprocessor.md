---
title: Preprocessor
description: "#include, #import, #define with arguments and varargs, conditional compilation, #warning and #error."
---

The preprocessor runs before the lexer and produces preprocessed source the rest of the compiler operates on. It exists alongside the language proper rather than as part of it — its job is meta (file inclusion, conditional compilation, simple macro substitution) rather than semantic.

## File inclusion

```c
#include <file.xt>      // search the system / -I paths only
#include "file.xt"      // search next to the current file first

#import  <Stdio.xt>     // include-once form, same search rules
#import  "Sprite.xt"
```

The two quote forms select different search orders, matching C/C++ convention:

- **`"file.xt"`** — look next to the file doing the include first, then fall through to the system directories and any `-I` paths. Use this for files that live alongside your source.
- **`<file.xt>`** — skip the current source's directory and go straight to system / `-I` paths. Use this for library headers so a same-named file in your project can't silently shadow the real library.

Filename matching is **case-sensitive** even on case-insensitive filesystems. `#import <Sort.xt>` will never match a sibling `sort.xt`, even on macOS's HFS+/APFS — this prevents a classic collision where a user names their program after a library they import.

`#import` is identical to `#include` except that the named file is included only once across the entire compilation unit. Library headers should always use `#import` so a user can `#import` them freely without two copies of the contents ending up in scope.

## Importing and promoting a class: `#use`

`#use` is sugar for the common case of *"import a library class and let me call its static methods bare."* It expands to `#import "ClassName.xt"` followed by [`use ClassName;`](/compiler/language/classes/#bare-call-promotion-use-classname) (the language-level directive) — one line replaces two.

```c
#use Stdio          // == #import "Stdio.xt" + use Stdio;
#use Math
#use <Time>         // angle-bracket and quote forms also accepted
#use "Sprite"

void main(void) {
    printf("answer = %u\n", 42);    // resolves to Stdio.printf
    u8 r = rand((u8)100);           // resolves to Math.rand
}
```

The class name may be written bare (`#use Stdio`), in angle brackets (`#use <Stdio>`), or in quotes (`#use "Stdio"`). The trailing `.xt` extension is stripped automatically if you include it. The same `< >` vs `" "` search-order rule as `#include` / `#import` applies to the underlying file lookup.

After `#use Stdio`, calling `printf("hi")` resolves the same way as `Stdio.printf("hi")` would — the receiver class is implied. This is bare-call sugar only; explicit `Klass.method(...)` calls, free functions, and local variables are unaffected. The full resolution rules — overload scoring, ambiguity diagnostics when multiple `use`'d classes both expose a method with the same name, and the file-local scope of the promotion — live with the [language-level `use` directive](/compiler/language/classes/#bare-call-promotion-use-classname).

## Macros

```c
#define DBL(x)   (double(x))
#define ZP_BASE  $80
#define ENABLE_DOUBLE 1
```

`#define` introduces a macro, optionally taking comma-separated arguments. At each later occurrence, the comma-separated actuals are substituted for the placeholders. Macros can be removed with `#undef`.

### Variadic macros

A macro whose last parameter is `...` is variadic; substitute the variadic tail with `__VA_ARGS__` in the body:

```c
#define LOG(level, ...)   Stdio.printf("[" level "] " __VA_ARGS__)

LOG("warn", "value=%d\n", x);
// expands to: Stdio.printf("[" "warn" "] " "value=%d\n", x);
```

This follows the standard C model.

## Conditional compilation

```c
#ifndef ENABLE_DOUBLE
 #define ENABLE_DOUBLE 1
#endif

#if ENABLE_DOUBLE
 // …double-precision code…
#elif ENABLE_FLOAT
 // …single-precision fallback…
#else
 #error neither double nor float enabled
#endif

#ifdef DEBUG
 Stdio.print("debug build\n");
#endif
```

`#ifdef` / `#ifndef` test for the presence (or absence) of a macro definition. `#if` evaluates a constant integer expression. The chain may include any number of `#elif` clauses and an optional `#else`, terminated by `#endif`.

Macros may be defined on the command line with `-D`:

```bash
xtc app.xt -DENABLE_DOUBLE=0 -DDEBUG -o app.xex
```

## Diagnostics from source

```c
#warning need to implement doFrobble()
#error neither ATARI nor C64 layout selected
```

`#warning` produces a compile-time warning containing the text and lets the build continue. `#error` produces a fatal error and stops compilation. Both honour conditional compilation — use them inside `#if` chains to enforce build-configuration invariants.
