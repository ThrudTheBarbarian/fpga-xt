---
title: Functions
description: Declarations, tuple returns, varargs, overloading, function annotations.
---

## Declaration

A function is a return type, a name, a parenthesised parameter list, and a block:

```c
u16 add(u16 a, u16 b) {
    return a + b;
}

void greet(string name) {
    Stdio.printf("hello, %s\n", name);
}
```

:::note[The parameters are `u16`, deliberately]
`u16 add(u8 a, u8 b)` would be misleading: `a + b` is a **u8** addition that
wraps at 8 bits, and the `u16` return type does not change that — it converts
the already-wrapped result on the way out. Widening is what the *assignment*
does, never what the operator does. See
[Types → Conversions](/compiler/language/types/#conversions).
:::

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

Supported `va_arg` types: `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, `float`, `double`, `string` (`u8*`), and `T*` for any pointer-to-type.

### Pointer-to-struct from varargs

`va_arg(ap, T*)` where `T` is a user-defined struct returns a typed pointer **into the pack buffer** pointing at the struct's raw bytes, and advances the cursor by `sizeof(T)`. Read fields through the returned pointer with `->`:

```c
typedef struct { u8 r; u8 g; u8 b; } RGB;

void logColor(string tag, ...) {
    u8 ap;
    va_start(ap);
    RGB* sp = va_arg(ap, RGB*);     // pointer into the pack buffer
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

**Almost every annotation is xt6502-only.** They exist to control a machine with
a 256-byte hardware stack, a banked address space and an OS ROM that can be
mapped over RAM — none of which the register targets have. Grouped by where
they apply:

| Annotation | Applies to | Purpose |
|---|---|---|
| `:naked` | **all targets** | no prologue / epilogue at all |
| `:hwStack` | xt6502 | use the 6502 hardware stack |
| `:xtcStack` | xt6502 | use the xtc software stack throughout |
| `:irq` | xt6502 | hardware-IRQ handler, ends with `RTI` |
| `:vbi` | xt6502 | vertical-blank handler, chains through the OS |
| `:needsOS` | xt6502 | wrap the body with ROM enable / disable |
| `:banked` | xt6502 | force into the code-bank window |
| `:main` | xt6502 | force into main RAM, opting out of auto-banking |
| `:shadow` | xt6502 | place under the OS ROM — no shipped layout declares one |
| `:cloaked` | *(retired)* | applied to the removed `xe` family; accepted but inert |

On `arm64`, `x86_64`, `win64`, `arm9` and `m68k` the placement and stack
annotations are **ignored** — those targets have one flat code space and a
hardware stack that is not a scarce resource, so there is nothing to choose.
`:naked` is the exception and means the same thing everywhere.

```c
void fn(void) :naked      { ... }    // no register save, just user code — all targets

// xt6502 only, from here down
void fn(void) :hwStack    { ... }    // use the 6502 hardware stack
void fn(void) :xtcStack   { ... }    // use the xtc software stack
void fn(void) :needsOS    { ... }    // requires OS ROM mapped in
void fn(void) :irq        { ... }    // hardware-IRQ handler, ends with RTI
void fn(void) :vbi        { ... }    // VBI handler — install via Vbi.addImmediate()
void fn(void) :banked     { ... }    // place in the bank window
void fn(void) :main       { ... }    // place in main RAM, opt out of auto-bank
void fn(void) :shadow     { ... }    // place in shadow RAM (no current layout has one)
```

### Calling convention / prologue (xt6502)

- `:naked` — no prologue or epilogue. The compiler does not save A / X / Y or set up a frame; you write whatever your body needs. Mutually exclusive with `:irq` / `:vbi`.
- `:hwStack` — force the function to use the 6502 hardware stack for return addresses and saved registers. Parameters always go on the xtc software stack regardless.
- `:xtcStack` — force the function to use the xtc software stack throughout. The hardware stack is much smaller (256 bytes), so deep recursion needs the software stack.

### Interrupt handlers (xt6502)

- `:irq` — emitted naked, with `RTI` instead of `RTS` so the 6502 pops the flags + return PC the IRQ pushed. Install the address into `$FFFE/$FFFF` (or your platform's appropriate vector) yourself.
- `:vbi` — Vertical-Blank-Interrupt handler. The prologue saves A/X/Y, the body runs, the epilogue restores A/X/Y and `JMP`s through `XITVBV` (`$E462`) so the OS finishes the interrupt. Install via `Vbi.addImmediate(&fn)` or `Vbi.addDeferred(&fn)`; remove with `Vbi.removeImmediate()` / `Vbi.removeDeferred()` (both routes call `SETVBV` `$E45C` for an SEI-safe atomic write).

On the banked `xt` target, `:irq` and `:vbi` handlers are placed in main RAM at a stable address — the OS dispatcher `JMP`s through their vector slot directly, with no opportunity for the bank-switch trampoline to swap the right page in. The codegen handles this automatically.

### Placement (xt6502)

`:banked`, `:main`, and `:shadow` are mutually exclusive and control where in the address space the function lives. They apply to the **6502** target only; every other backend ignores them. Defaults stay as they are (free functions auto-bank on `xt`; unbanked RAM otherwise), so most programs don't need to think about them.

- `:banked` — force into the code-bank window. On a target with no banking, the compiler warns and falls through to `:main`.
- `:main` — force into main RAM, even on `xt` where it would otherwise auto-bank. Useful for hot routines where the cross-bank trampoline cost matters, or for code that an `:irq` / `:vbi` handler calls (since handlers can't trampoline).
- `:shadow` — place under the OS ROM, on a layout that declares a `[shadow]` section. No shipped layout does — `xt6502` reaches its extra RAM through the bank windows — so on the shipped targets the compiler warns and falls through to `:main`. Cross-bank-style calls work either way — but `:shadow` code is unreachable when ROM is mapped in, so don't call it from inside a `:needsOS` function.
- `:cloaked` / `:cloaked(<id>)` — place in a layout-declared cloaked region. **Retired in practice**: it applied to the `xe`-family Atari models, which are gone, and no shipped layout declares a cloaked region — the annotation and `-fauto-cloak` are still accepted but inert. Kept because the machinery is still in the IR and a future layout could declare one. Bare `:cloaked` auto-packs into the layout's first declared region, with overflow spilling forward to the next region (and finally to `:main`). The id form pins the decl to a named region — useful when the layout has both `lib` (banking-off, exposed in main RAM) and numbered-bank `extN` regions and you want a specific one. The compiler errors on a target without cloaking support or on an unknown id; see [Linker scripts — `[cloaked]`](/compiler/usage/linker-scripts/#cloaked--code-regions-for-cloaked-decls) for the layout side. Auto-cloak (`-fauto-cloak={never,auto,always}`) promotes cloak-safe decls automatically, so most programs don't need the manual annotation.

### Shadow-target helpers (xt6502)

- `:needsOS` — wraps the body with ROM enable / disable on shadow targets (no-op on non-shadow). Keep `:needsOS` functions small and self-contained — many calls from one of them into shadow-resident code means the ROM swap fires repeatedly and erases the speed advantage of shadow RAM.

## Default calling convention

By default, parameters pass on the **xtc software stack**, return addresses and saved registers go on the **6502 hardware stack**. The `-S` / `--xtc-stack` command-line flag forces all stack traffic onto the software stack — larger but slower.

`:hwStack` and `:xtcStack` annotations override the command-line default per-function. Parameters always travel on the software stack regardless of which annotation wins.

## Worked example

Overloading, multiple return values, tuple unpacking, varargs and recursion:

```c
// functions.xc — overloading, multiple return values, tuple unpacking,
// varargs, and recursion.
#import "Foundation.xc"
#import "Stdio.xc"

// ---- Overloading -----------------------------------------------------------
// Same name, different parameter types. The compiler picks by argument type,
// scoring conversions so the closest match wins.
u16 area(u16 side)             { return side * side; }
u16 area(u16 w, u16 h)         { return w * h; }
float area(float radius)       { return 3.14159 * radius * radius; }

// ---- Multiple return values ------------------------------------------------
// A function may return several values: the return types are a comma-separated
// list before the name, and `return` takes a matching list. The CALL SITE
// parenthesises, not the declaration.
u16, u16 divmod(u16 n, u16 d)
{
    return n / d, n % d;
}

// Three, of mixed type — the list is not restricted to one width.
u16, u16, bool minMax(u16 a, u16 b)
{
    if (a <= b) return a, b, true;
    return b, a, false;
}

// ---- Varargs ---------------------------------------------------------------
// `...` after the fixed parameters. The cursor is a plain `u8` that `va_start`
// initialises — there is no `va_list` type and no `va_end`. Each argument is
// read with a WIDTH-NAMED accessor (`va_arg_u16`, `va_arg_i32`, `va_arg_double`,
// `va_arg_ptr`, …) rather than a type parameter, and as in C the count has to
// come from somewhere — here a leading argument.
u32 sumOf(u16 count, ...)
{
    u32 total = (u32)0;
    u8  ap;
    va_start(ap);
    for (u16 i = (u16)0; i < count; i = i + (u16)1)
        total = total + (u32)va_arg_u16(ap);
    return total;
}

// ---- Recursion -------------------------------------------------------------
// Self-recursion is ordinary. At -O2 and above a TAIL call becomes a loop, so
// this costs no stack depth per step.
u32 factorial(u16 n)
{
    if (n <= (u16)1) return (u32)1;
    return (u32)n * factorial(n - (u16)1);
}

// A default-free "out parameter" is just a pointer.
void bump(u16* slot, u16 by) { *slot = *slot + by; }

i32 main(void)
{
    // Overloads resolve on the argument types.
    Stdio.printf("area square %d, rect %d, circle %f\n",
                 area((u16)5), area((u16)3, (u16)4), area(2.0));

    // Tuple unpacking: declare the variables, then assign the call to them
    // as a parenthesised list.
    u16 q, r;
    (q, r) = divmod((u16)17, (u16)5);
    Stdio.printf("17/5 = %d rem %d\n", q, r);

    u16 lo, hi;
    bool ordered;
    (lo, hi, ordered) = minMax((u16)9, (u16)4);
    Stdio.printf("minMax(9,4) = %d %d ordered=%d\n",
                 lo, hi, ordered ? (u16)1 : (u16)0);

    // Varargs.
    Stdio.printf("sum %ld\n", sumOf((u16)4, (u16)10, (u16)20, (u16)30, (u16)40));

    // Recursion.
    Stdio.printf("10! = %ld\n", factorial((u16)10));

    // Out parameter.
    u16 counter = (u16)100;
    bump(&counter, (u16)5);
    Stdio.printf("counter %d\n", counter);
    return 0;
}
```

```
area square 25, rect 12, circle 12.566360
17/5 = 3 rem 2
minMax(9,4) = 4 9 ordered=0
sum 100
10! = 3628800
counter 105
```

Two things that differ from C and catch people out: the multiple-return **types** are a bare comma-separated list before the function name, while the **unpacking** at the call site is parenthesised — the opposite of what the shapes suggest. And varargs use a plain `u8` cursor with width-named accessors (`va_arg_u16`, `va_arg_double`, …) instead of `va_list` and a type parameter; there is no `va_end`.
