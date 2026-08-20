---
title: Stdio
description: Screen output, cursor positioning, and formatted print for xcc programs.
---

`Stdio` is the screen-I/O class. It writes characters to the active text-mode screen, positions the cursor, and offers a `printf`-style formatter that handles every primitive type plus structs and classes.

```c
#import <Stdio.xc>
```

All methods are `static`. The class is typically promoted with `use Stdio;` or the `#use Stdio` shorthand so callers can write `print(...)` and `printf(...)` bare — but every method is reachable in its qualified `Stdio.xxx` form too.

## Basic output

```c
static void putChar(u8 ch);          // emit one character        — xt6502 only
static void scroll(void);            // scroll the screen up one line — xt6502 only
static void setCursor(u8 x, u8 y);   // move cursor to column x, row y
```

```c
Stdio.putChar('H');
Stdio.putChar('i');
Stdio.putChar('\n');
Stdio.setCursor(10, 5);
Stdio.print("centred-ish\n");
```

`putChar` and `scroll` are screen-model operations and exist only in the xt6502 build; calling either on a native backend is a compile error (`No method 'putChar' on class 'Stdio'`). `print`, `printf`, `printfAt` and `setCursor` are on both.

## `print` — type-overloaded direct printing

`Stdio.print` is overloaded across every primitive xcc type. The compiler picks the right implementation based on the argument's type:

```c
static void print(string s);
static void print(u16 v);
static void print(i16 v);
static void print(u32 v);
static void print(i32 v);
static void print(float f);
static void print(double d);
```

```c
Stdio.print("hello\n");
Stdio.print((u16)1000);
Stdio.print((i32)-50000);
Stdio.print((float)3.14);
```

`print` does not append a newline — supply one explicitly when needed.

There's no `print(u8)` overload because `u8` widens implicitly to `u16`. Pass `u8` values directly; the compiler promotes for you.

## `printHex` — type-overloaded hex printing

```c
static void printHex(u8 n);          // 2 hex digits
static void printHex(u16 v);         // 4 hex digits
static void printHex(u32 v);         // 8 hex digits
```

```c
Stdio.printHex((u8)$2A);             // 2A
Stdio.printHex((u16)$1234);          // 1234
Stdio.printHex((u32)$DEADBEEF);      // DEADBEEF
```

Output is uppercase, left-zero-padded to the type's full width — no `$` prefix is emitted.

## `printf` — formatted print

```c
static void printf(string fmt, ...);
static void printfAt(u8 x, u8 y, string fmt, ...);
```

`printfAt` is `setCursor(x, y)` followed by `printf` — convenient for table-style screens.

### Format specifiers

| Specifier | Argument type | Output |
|-----------|---------------|--------|
| `%d` | `i16` | signed decimal |
| `%u` | `u16` | unsigned decimal |
| `%x` | `u16` | hex, 4 digits |
| `%ld` | `i32` | signed decimal, 32-bit |
| `%lu` | `u32` | unsigned decimal, 32-bit |
| `%lx` | `u32` | hex, 8 digits |
| `%lld` | `i64` | signed decimal, 64-bit |
| `%llu` | `u64` | unsigned decimal, 64-bit |
| `%llx` | `u64` | hex, 16 digits |
| `%f` | `float` | floating-point |
| `%lf` | `double` | double-precision floating-point |
| `%c` | `u8` | character (no width promotion) |
| `%s` | `string` (`u8*`) | null-terminated string |
| `%e` | enum value (must be statically typed as an enum) | textual name of the enum value — rewritten to `%s` at compile time |
| `%@` | class instance | calls the object's `description()` through its vtable |
| `%%` | — | literal `%` |

```c
u16 score = 1234;
i32 millis = -50000;
float pi   = 3.14159;
string name = "Player 1";

Stdio.printf("%s scored %u in %ld ms\n", name, score, millis);
Stdio.printf("pi ≈ %f\n", pi);
Stdio.printf("ratio: %u%%\n", (u16)42);   // "ratio: 42%"
```

### Objects: `%@`

`%@` takes a **class instance** and prints whatever its `description()` method
returns, dispatched through the vtable. `Object` supplies a default, so any class
works; override `description()` and every `%@` in the program follows:

```c
class Point : Object
{
    i32 x;
    i32 y;
    String* description(void)
    {
        String* s = String.withCString("(");
        s.append(String.withI32(x));
        s.appendCString("|");
        s.append(String.withI32(y));
        s.appendCString(")");
        return s;
    }
}

Stdio.printf("last %@\n", p);        // last (3|4)
```

It is a virtual call on an object, not a structural dump — a plain `struct` has
no vtable and no `description()`, so pass its fields individually.

### Enum names: `%e`

`%e` prints the **textual name** of an enum value. The translation happens entirely at **compile time** — the runtime printf never sees a `%e`:

1. The compiler scans every `printf` / `printfAt` format string at the call site.
2. Each `%e` is rewritten in place to `%s`.
3. The compiler generates a small `_enum_lookup_<EnumName>(value)` helper for any enum reached by a `%e`, and the call site emits a `JSR` to that helper. The helper returns a string pointer, which gets packed as the matching `%s` argument.

So at the level of the binary, every `%e` becomes an ordinary `%s` call, and the cost of the feature is one helper per enum (emitted exactly once, regardless of how many call sites reach it).

```c
enum direction = {N = 1, E, S, W};

direction d = E;
Stdio.printf("heading: %e\n", d);     // heading: E
Stdio.printf("raw    : %u\n", (u16)d); // raw    : 2
```

The argument paired with `%e` **must be statically typed as an enum**. A non-enum argument paired with `%e` (a plain `u8`, a result of arithmetic, an integer cast away from the enum type) is a compile-time error:

```
error: printf '%e' requires an enum argument (got 'u8')
```

If you want the underlying numeric value, use `%u` or `%d` and cast explicitly — there's no silent fallback from `%e` to integer-print, by design.

### Pre-scanning and code-size gating

The compiler scans every `printf` format string in the program at compile time and only links in the specifier handlers that are actually used. A program that only prints strings and `u16`s pays for `%s` and `%u` — none of the floating-point, double, or `%@` machinery makes it into the binary. You can also force-include or force-exclude specifiers via `-DHAS_FFMT=1`, `-DHAS_LFMT=0`, etc.

### Recursive struct print: `%@`

```c
typedef struct {
    u16 x;
    u16 y;
    u8  tint;
} Sprite;

Sprite s = {160, 96, 7};
Stdio.printf("sprite=%@\n", s);
// sprite=(160, 96, 7)
```

Nested structs are formatted recursively with parentheses around each level. The mechanism uses the compiler-generated descriptor for the struct, so user code doesn't need to write any printer.

## Variadic limits (xt6502 only)

On **xt6502** a variadic call marshals its arguments through a single shared 64-byte pack buffer (`__xtc_va_buf`; the address comes from the active layout — see [Functions → Shared pack buffer](/compiler/language/functions/#shared-pack-buffer-and-reentrance)). For `printf` that means:

- Total argument payload per call ≤ 62 bytes (64 minus the 2-byte fmt-pointer header).
- A `printf` call inside another variadic that has called `va_start` will scramble the outer's buffer — sema diagnoses this at compile time.
- `printfAt` is a pure forwarder: it does not call `va_start` itself, so it's exempt from the reentrance check.

The **native** targets (`arm64`, `x86_64`, `win64`, `arm9`) use their platform's own varargs ABI — registers and the stack, per call — so none of the above applies there: there is no shared buffer, no payload cap and no reentrance hazard. Code that stays inside the limit is portable to all of them; code that exceeds it works everywhere except xt6502.

## Platform notes

`Stdio` is reimplemented per-architecture. The 6502 version writes through the Atari OS character output channel; the native backends route through the host runtime. Format specifiers and the `print` / `printf` / `printfAt` / `setCursor` signatures are identical, so a program that uses those for its output is portable across every target without source changes.

The two builds are not exactly the same size, though. `putChar`, `scroll` and the fixed-point helper `printFpDec(double, u8, u8)` exist only under `support/xt6502/lib/`; reach for `print` / `printf` if you want source that compiles everywhere.
