---
title: Inline assembly
description: asm blocks, byte-extract operators, accessing xtc variables, the clobbers annotation.
---

xtc supports embedded assembly via `asm { ... }` blocks. Inside the block the assembler grammar is the same as `xcc-as`'s — see the [xcc-as reference](/compiler/api/) — but with the added ability to refer to xtc identifiers by name and pull individual bytes out of wider values.

## The asm block

```c
asm {
    lda #$ff;
    sta $D40E;          // disable VBLANK interrupts
}

asm ((
    lda #$ff;
    sta $D40E;
))
```

`{ ... }` and `(( ... ))` are interchangeable, exactly as in xtc statement bodies.

By default the compiler scans the block, determines which registers it thinks will be written, and emits save / restore around the block. That is usually what you want — but if your block has *intended* side effects on a register the compiler thinks you didn't touch (or vice versa), you can override with a `clobbers` annotation:

```c
asm {
    lda #$00;
    tax;
    tay;
} : clobbers A, X, Y
```

Mismatch warnings (compiler thought you'd touch A but you didn't, or vice versa) are emitted under the `asm-clobbers` warning category and may be suppressed with `-Wno-asm-clobbers` if you've audited and disagreed.

## Accessing xtc variables

Identifiers declared in xtc are visible inside `asm` blocks under their declared names. The assembler resolves them to their allocated address, so they can stand in anywhere a label or constant would normally appear.

```c
u16 score = 0;

void incScore(void) {
    asm {
        inc score;          // 16-bit increment
        bne done;
        inc score+1;
        done:
    }
}
```

The same applies to global symbols, struct ivar offsets, and class-instance ivars — the compiler emits the right computed address.

## Byte-extract operators

Wider values (`u16`, `u32`, addresses of arrays / classes / functions) can't fit in a single 6502 immediate. The four byte-extract prefix operators pull the byte you want:

| Prefix | Range |
|--------|-------|
| `<x` | bits 0..7 (low byte) |
| `>x` | bits 8..15 |
| `>>x` | bits 16..23 |
| `>>>x` | bits 24..31 |

```c
u16 val = $1234;

asm {
    lda #<val;        // LDA #$34
    ldx #>val;        // LDX #$12
}

u32 big = $11223344;

asm {
    lda #<big;        // LDA #$44
    ldx #>big;        // LDX #$33
    ldy #>>big;       // LDY #$22
    sta #>>>big;      // STA #$11    (pseudo, illustrative)
}
```

These prefixes are recognised by the assembler grammar inside `asm` blocks; they are syntactically distinct from the xtc-level `<` / `>` comparison operators because the assembler accepts only constants and symbols after them. (See [Operators → Byte-extract prefixes](/compiler/language/operators/#byte-extract-prefixes-asm-context).)

## What the assembler accepts

Every official instruction is recognised, with operand modes encoded the standard way. For example the 6502 supports:

| Mode | Example |
|------|---------|
| Accumulator | `asl;` |
| Immediate | `lda #$00;` |
| Zero-page | `lda $80;` |
| ZP, X | `lda $80,x;` |
| Absolute | `lda $1234;` |
| Absolute, X / Y | `lda $1234,x;` |
| Indirect | `jmp ($fffc);` |
| (ZP, X) | `lda ($80,x);` |
| (ZP), Y | `lda ($80),y;` |

Instruction lines end with `;` (matching xtc's statement terminator). Labels are bare identifiers followed by `:`, addressable locally to the current `asm` block.

Platform memory-map symbols are predefined for the active target — on Atari that's `POKMSK`, `SDMCTL`, `AUDF1`, and the rest of the OS shadow / hardware register names — so you can use them directly without re-declaring constants. The symbol table the assembler loads lives at `support/<platform>/symbols/*.sym`; check there for the exact set available on a given platform, or to add your own. Each `.sym` file is a list of `NAME = $hex` lines (anything after `;` on a line is a comment), so adding a symbol is a one-line edit.

## A complete example

A small inline-asm helper that disables and re-enables NMI generation around a critical section, demonstrating variable access, control flow, and the `clobbers` annotation:

```c
volatile u8* NMIEN = (u8*)$D40E;

void atomic(void(*body)(void)) {
    u8 saved;

    asm {
        lda NMIEN;
        sta saved;
        lda #$00;
        sta NMIEN;
    } : clobbers A

    body();

    asm {
        lda saved;
        sta NMIEN;
    } : clobbers A
}
```

For larger helpers — multi-byte arithmetic, bank-switching trampolines, hardware-seeded PRNGs — the convention is to lift the routine into a hand-written `.asm` file under `support/` (see the source repo's `support/generic/asm/` and `support/<platform>/asm/` directories) and `JSR` to it from xtc. Inline `asm` blocks are best reserved for short, intent-revealing intercessions inline in xtc code.
