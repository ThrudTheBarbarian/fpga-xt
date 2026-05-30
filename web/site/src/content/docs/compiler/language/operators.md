---
title: Operators
description: Full operator precedence table including the rotate and byte-extract operators.
---

xtc operators are largely a subset of C's, with two notable additions: a pair of **rotate** operators (`<:` and `:>`) that map directly to the 6502's `ROL` / `ROR` instructions, and four **byte-extract** prefix operators (`<`, `>`, `>>`, `>>>`) that pull individual bytes out of wider constants and symbols. The byte-extract operators only mean anything inside [`asm { ... }`](/compiler/language/inline-asm/) blocks.

## Precedence table

Listed from highest to lowest. Rows at the same level have the same precedence; within a level, **Assoc** records the associativity.

| Operators | Assoc | Notes |
|-----------|-------|-------|
| `a[i]`, `f(...)`, `.`, `->`, postfix `++`, postfix `--` | left | primary |
| prefix `+ -`, `!`, `~`, prefix `++`, prefix `--`, `@` (deref), `&` (addr-of), `(type)` cast, `sizeof()`, `<` `>` `>>` `>>>` (byte extract, asm) | right | unary |
| `*`, `/`, `%` | left | multiplicative |
| `+`, `-` | left | additive |
| `<:`, `:>` | left | rotate (ROL / ROR) |
| `<<`, `>>` | left | shift (ASL / ASR) |
| `<`, `>`, `<=`, `=>` | left | relational |
| `==`, `!=` | left | equality |
| `&` | left | bitwise AND |
| `^` | left | bitwise XOR |
| `\|` | left | bitwise OR |
| `&&` | left | logical AND |
| `\|\|` | left | logical OR |
| `? :` | right | ternary |
| `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `<<=`, `>>=`, `<:=`, `:>=` | right | assignment |

## Notes on specific operators

### Rotate vs shift

`<:` and `:>` are **rotate** through carry — they map to the 6502 `ROL` / `ROR` instructions, which read and write the carry flag. `<<` and `>>` are **arithmetic shift** (`ASL` / `ASR` for the right shift). Use rotate when you want to chain bytes through carry; use shift when you want a regular multiply / divide by powers of two.

```c
u8 a = $80;
u8 b = a <: 1;    // a is rotated left through carry; one-bit shift left + carry-in
u8 c = a << 1;    // arithmetic left shift; bit 7 lost
```

### Pointer dereference and address-of

`@` is the unary dereference operator; `&` takes an address. They're inverses:

```c
u8 v   = 42;
u8@ p  = &v;
u8 q   = @p;     // q == 42
@p     = 99;     // v becomes 99
```

`->` is sugar for "dereference then access a member": `p->x` is exactly `(@p).x`. xtc also accepts the dot form `p.x` directly on a pointer — the compiler auto-dereferences. See [Types → Pointers](/compiler/language/types/#pointers) for the rationale.

### Cast extensions

Inside the `(type)` cast, two forms have non-C semantics:

- `(Dog@) animal` — runtime-checked downcast. Traps on mismatch.
- `(Dog@ ?) animal` — failable downcast. Yields `(Dog@)0` on mismatch.

These are class-pointer-only; `(u16 ?)x` is a compile-time error. Details on [Inheritance & protocols](/compiler/language/inheritance/).

### `sizeof`

`sizeof(T)` evaluates to a compile-time `u16` byte count. Works on any type, including `struct` and `class`.

### Byte-extract prefixes (asm context)

These operators have meaning only inside an `asm { ... }` block, where they let you reach individual bytes of a constant or symbol that the assembler would otherwise treat as a 16- or 32-bit address:

| Prefix | Meaning |
|--------|---------|
| `<x`   | low 8 bits of `x` |
| `>x`   | bits 8..15 of `x` |
| `>>x`  | bits 16..23 of `x` |
| `>>>x` | bits 24..31 of `x` |

```c
u16 val = $1234;

asm {
    lda #<val;    // LDA #$34
    ldx #>val;    // LDX #$12
}
```

Outside an `asm` block these tokens parse as their normal precedences — `<` and `>` as relational comparisons, `>>` as the shift operator. The byte-extract reading is unambiguous in context because the assembler-level grammar accepts only constants and symbols after the prefix.

## Compound assignment

Every binary operator that's also an arithmetic, bitwise, or shift operation has a compound-assignment form: `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, plus the rotate forms `<:=` and `:>=`. They behave exactly as their expansion suggests:

```c
x += 1;            // x = x + 1
flags &= ~MASK;    // flags = flags & ~MASK
acc <:= 1;         // acc = acc <: 1
```

When the left-hand side goes through a property setter (see [Classes → Properties](/compiler/language/classes/#properties)), the desugaring evaluates the base expression twice — free for identifiers and `self`, watch-out only if the base has a side effect.
