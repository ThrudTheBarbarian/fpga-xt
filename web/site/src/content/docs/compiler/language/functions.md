---
title: Functions
description: Declarations, tuple returns, varargs, overloading, function annotations.
---

## Declaration

A function is a return type, a name, a parenthesised parameter list, and a block:

```c
u16 add(u8 a, u8 b) {
    return a + b;
}

void greet(string name) {
    Stdio.printf("hello, %s\n", name);
}
```

Forward declarations (signature without a body, terminated with `;`) work the same as in C, but they're rarely needed — xtc lets you call a function defined later in the same compilation unit. The main use of forward declarations is to declare external functions in headers.

## Return types and tuples

A function may return more than one value. The return type is a comma-separated list of types; the `return` statement provides a matching list of values.

```c
u8, u16 myFunc(void) {
    return 42, 1969;
}
```

Tuple returns are unpacked at the call site, either declaring fresh variables:

```c
(u8 x, u16 y) = myFunc();
```

…or assigning to existing ones:

```c
u8  x;
u16 y;
(x, y) = myFunc();
```

If the function's return type is `void`, the `return` statement has no arguments.

## Variable arguments (varargs)

A function with `...` in its parameter list takes a variable number of trailing arguments:

```c
void printAll(string fmt, ...) {
    // …
}
```

Inside the body, walk the argument pack with `va_start`, `va_arg`, and `va_end`. The cursor `ap` is a `u8` that the compiler advances as each read consumes bytes from the shared pack buffer.

```c
u8 ap;
va_start(ap);
u16    n = va_arg(ap, u16);
string s = va_arg(ap, string);
va_end(ap);
```

Supported `va_arg` types: `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, `float`, `double`, `string` (`u8@`), and `T@` for any pointer-to-type.

### Pointer-to-struct from varargs

`va_arg(ap, T@)` where `T` is a user-defined struct returns a typed pointer **into the pack buffer** pointing at the struct's raw bytes, and advances the cursor by `sizeof(T)`. Read fields through the returned pointer with `->`:

```c
typedef struct { u8 r; u8 g; u8 b; } RGB;

void logColor(string tag, ...) {
    u8 ap;
    va_start(ap);
    RGB@ sp = va_arg(ap, RGB@);     // pointer into the pack buffer
    u8 red   = sp->r;
    u8 green = sp->g;
    u8 blue  = sp->b;
    va_end(ap);
}

void main(void) {
    RGB c = {$11, $22, $33};
    logColor("probe", c);            // caller packs 3 raw bytes
}
```

The returned pointer is **only valid for the lifetime of the variadic call**. The pack buffer gets reused for the next variadic invocation — don't stash the pointer in a global or return it.

### Shared pack buffer and reentrance

All varargs functions share a single 64-byte pack buffer (on Atari it lives at `$0480-$04BF`; the address varies by platform — see the `[buffers] printf` entry of the active layout, or the compiler-defined `XT_PRINTF_BUF` / `XT_PRINTF_DATA_BUF` macros).

A consequence: a variadic `F` that has called `va_start` **cannot call another variadic `G`** — the call would clobber `F`'s buffer mid-walk and `F`'s subsequent `va_arg` reads would return scrambled bytes. Sema diagnoses this at compile time.

**Pure forwarders** (variadics that never call `va_start` and exist only to pass their `...` tail through to another variadic) are exempt — that's how `Stdio.printfAt` delegates to `Stdio.printf`.

The total payload per variadic call is capped at 62 bytes (64 minus the 2-byte fmt-pointer header); `printfAt` uses 7 header bytes, so its payload ceiling is 57.

## Inline expansion at the call site

Prefix any call with `inline:` to ask the compiler to inline the callee, removing the JSR and any stack management:

```c
u8 myVal = inline:calculate(4, 5);
```

This is independent of `-O2`'s leaf-inliner heuristic; `inline:` is a directive, the heuristic is automatic.

## Function overloading

Functions can be overloaded by parameter type. Sema picks the most specific match.

```c
void show(u32 val)   { Stdio.printf("u32: %d",   val); }
void show(u8  val)   { Stdio.printf("u8 : %d",   val); }
void show(string s)  { Stdio.printf("string:%s", s);   }
```

Overloading by **return type** also works — Sema picks based on what the result is being assigned to:

```c
float  myValue(void) { ... }
i16    myValue(void) { ... }
string myValue(void) { ... }
```

## Function annotations

Annotations sit after the parameter list, separated by `:`. They control calling convention, prologue / epilogue shape, and where in the memory map the function lives. All annotations are case-insensitive.

```c
void fn(void) :naked      { ... }    // no register save, just user code
void fn(void) :hwStack    { ... }    // use the 6502 hardware stack
void fn(void) :xtcStack   { ... }    // use the xtc software stack
void fn(void) :needsOS    { ... }    // requires OS ROM mapped in
void fn(void) :irq        { ... }    // hardware-IRQ handler, ends with RTI
void fn(void) :vbi        { ... }    // VBI handler — install via Vbi.install()
void fn(void) :banked     { ... }    // place in the bank window (xt / xe)
void fn(void) :main       { ... }    // place in main RAM, opt out of auto-bank
void fn(void) :shadow     { ... }    // place in shadow RAM (xl / xt / xe-shadow)
void fn(void) :cloaked    { ... }    // place in a cloaked region (xe family)
void fn(void) :cloaked(ext1) { ... } // pin to a named cloaked region
```

### Calling convention / prologue

- `:naked` — no prologue or epilogue. The compiler does not save A / X / Y or set up a frame; you write whatever your body needs. Mutually exclusive with `:irq` / `:vbi`.
- `:hwStack` — force the function to use the 6502 hardware stack for return addresses and saved registers. Parameters always go on the xtc software stack regardless.
- `:xtcStack` — force the function to use the xtc software stack throughout. The hardware stack is much smaller (256 bytes), so deep recursion needs the software stack.

### Interrupt handlers

- `:irq` — emitted naked, with `RTI` instead of `RTS` so the 6502 pops the flags + return PC the IRQ pushed. Install the address into `$FFFE/$FFFF` (or your platform's appropriate vector) yourself.
- `:vbi` — Vertical-Blank-Interrupt handler. The prologue saves A/X/Y, the body runs, the epilogue restores A/X/Y and `JMP`s through `XITVBV` (`$E462`) so the OS finishes the interrupt. Install via `Vbi.addImmediate(&fn)` or `Vbi.addDeferred(&fn)`; remove with `Vbi.removeImmediate()` / `Vbi.removeDeferred()` (both routes call `SETVBV` `$E45C` for an SEI-safe atomic write).

On banked targets (xt / xe), `:irq` and `:vbi` handlers are placed in main RAM at a stable address — the OS dispatcher `JMP`s through their vector slot directly, with no opportunity for the bank-switch trampoline to swap the right page in. The codegen handles this automatically.

### Placement

`:banked`, `:main`, and `:shadow` are mutually exclusive and control where in the address space the function lives. Defaults stay as they are (auto-bank free functions on xt / xe; main RAM otherwise), so most programs don't need to think about them.

- `:banked` — force into the bank window. On a target with no banking (e.g. plain `xl`), the compiler warns and falls through to `:main`.
- `:main` — force into main RAM, even on xt / xe where it would otherwise auto-bank. Useful for hot routines where the cross-bank trampoline cost matters, or for code that an `:irq` / `:vbi` handler calls (since handlers can't trampoline).
- `:shadow` — place under the OS ROM (`$C000-$CFFF` and `$D800-$FFF9` on Atari shadow targets). On a target without shadow RAM, the compiler warns and falls through to `:main`. Cross-bank-style calls work either way — but `:shadow` code is unreachable when ROM is mapped in, so don't call it from inside a `:needsOS` function.
- `:cloaked` / `:cloaked(<id>)` — place in a layout-declared cloaked region. xe-family-only. Bare `:cloaked` auto-packs into the layout's first declared region, with overflow spilling forward to the next region (and finally to `:main`). The id form pins the decl to a named region — useful when the layout has both `lib` (banking-off, exposed in main RAM) and numbered-bank `extN` regions and you want a specific one. The compiler errors on a target without cloaking support or on an unknown id; see [Linker scripts — `[cloaked]`](/compiler/usage/linker-scripts/#cloaked--code-regions-for-cloaked-decls) for the layout side. Auto-cloak (`-fauto-cloak={never,auto,always}`) promotes cloak-safe decls automatically, so most programs don't need the manual annotation.

### Shadow-target helpers

- `:needsOS` — wraps the body with ROM enable / disable on shadow targets (no-op on non-shadow). Keep `:needsOS` functions small and self-contained — many calls from one of them into shadow-resident code means the ROM swap fires repeatedly and erases the speed advantage of shadow RAM.

## Default calling convention

By default, parameters pass on the **xtc software stack**, return addresses and saved registers go on the **6502 hardware stack**. The `-S` / `--xtc-stack` command-line flag forces all stack traffic onto the software stack — larger but slower.

`:hwStack` and `:xtcStack` annotations override the command-line default per-function. Parameters always travel on the software stack regardless of which annotation wins.
