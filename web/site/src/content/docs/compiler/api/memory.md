---
title: Memory
description: Bulk fill, clear, copy and move primitives — self-modifying 6502 inner loops for page-aligned bulk work.
---

`Memory` is a static class of bulk byte primitives: fill, clear, copy, and an overlap-safe move. All four take **raw `u16` addresses**, not typed pointers — take the address of the first element and cast:

```c
#import <Memory.xc>

u8 screen[960];
Memory.memclr((u16)&screen[0], (u16)960);
```

:::caution[xt6502 only]
Despite living under `support/generic/lib/`, `Memory`'s method bodies are inline **6502 assembly**. A program that calls one of them fails to assemble on the native backends (`unrecognized instruction mnemonic`). It is an xt6502 class that happens to sit in the shared directory.
:::

## Methods

```c
static void memset(u16 addr, u8 val, u16 len);   // fill
static void memclr(u16 addr, u16 len);           // fill with 0
static void memcpy(u16 dst, u16 src, u16 len);   // copy, NO overlap
static void memmove(u16 dst, u16 src, u16 len);  // copy, overlap-safe
```

`memclr(addr, len)` is exactly `memset(addr, $00, len)`. All four return immediately on `len == 0`.

## `memset` — three phases

`memset` handles an arbitrary `[addr, len)` in three parts: leading bytes up to the next page boundary go through a simple per-byte loop, the page-aligned middle runs an unrolled 16-`STA` inner loop, and the trailing bytes fall back to the simple loop. The bulk middle costs about **5.7 cycles/byte** against roughly **11 cycles/byte** for a naive `(ptr),Y` loop.

## `memcpy` — alignment decides the speed

Source and destination **must not overlap**. If overlap is possible, or you don't know, use `memmove`.

There are two paths, picked by a 4-cycle check at the top of the call:

| Case | Inner loop | Cost |
|---|---|---|
| `src` **and** `dst` both page-aligned | unrolled 16×(`LDA`+`STA`) absolute,Y, high bytes patched once per page | ~10 cycles/byte |
| anything else, and every trailing partial page | simple indirect-`Y` loop | ~16 cycles/byte |

The fast path needs *both* addresses on a page boundary — the 16 absolute-addressed stores would otherwise cross a page mid-loop. It pays for its check as soon as a copy spans even one full aligned page, so there is no reason to hand-pick between the two.

## `memmove` — overlap-safe

When `dst <= src` (or the regions don't overlap at all) `memmove` simply forwards to `memcpy`. When `dst > src` and they might overlap, it walks **backward** from the highest byte so the source isn't clobbered mid-copy. The backward path is the simple indirect-`Y` loop with no unrolling — overlapping copies are typically small in-buffer shifts, where the page-aligned win wouldn't apply anyway.

## Self-modifying code

The unrolled paths patch the high byte of their own `LDA` / `STA` instructions once per page. That means the method body has to live in **writable RAM** — which xtc methods always do, whatever their placement (`:main`, `:banked`, `:shadow`), so this is a fact about the implementation rather than something you have to arrange.

## Reachability

A program that never calls `memset` / `memclr` / `memcpy` / `memmove` gets the bodies stripped at link time. `#import`ing the file alone costs nothing.
