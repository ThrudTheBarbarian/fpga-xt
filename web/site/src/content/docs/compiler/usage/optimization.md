---
title: Optimisation
description: What -O0 through -O3 add, the tuning knobs (-Fli, -Flu), how to read the optimiser's summary line.
---

xtc has four optimisation levels, plus two tuning knobs that modulate the most expensive transforms (leaf inlining and loop unrolling). The default is `-O0` because optimised builds are slower to compile and take work to debug at the assembly level — opt in deliberately when you want the cycles and bytes.

```bash
xtc -O3 game.xt -o game.xex
```

```
xtc: optimised -O3 (9877 → 9698 instructions)
```

The "before / after" instruction count is printed when any optimisation pass actually moved the needle — useful as a sanity check that a flag did what you expect.

## The four levels

### `-O0` — no optimisation (default)

Straight codegen. Every variable gets a stable home, every expression evaluates left-to-right with intermediate stores, every JSR / RTS pair is emitted. The output is **predictable** — what you see in the source is roughly what comes out — which makes single-stepping in `xts` and reasoning about code paths much easier. Use during development and for asm debugging.

### `-O1` (`-O`) — peephole + register tracking

Two cheap, local transforms:

- **Peephole.** Adjacent instruction patterns get replaced with shorter equivalents (e.g. `LDA #0; STA x` followed by `LDA x` collapses; `LDX foo; CPX #0` collapses to a flag-set form). All local, all reversible inspection in the listing.
- **Register tracking.** The codegen carries a model of A / X / Y across instruction boundaries, so a value that's already in the right register isn't reloaded.

Compile time is essentially the same as `-O0`. There's almost no reason not to ship at least `-O1`.

### `-O2` — the heavy lifters

Adds, on top of `-O1`:

- **Constant propagation** — replace reads of compile-time-known values with the immediate value.
- **Dead code elimination** — drop blocks that are statically unreachable.
- **Dead store elimination** — drop writes to a variable whose subsequent reads can be proven to come from a later write.
- **Tail-call optimisation** — convert a `JSR` immediately followed by `RTS` into a `JMP`, freeing a hardware-stack slot per recursion depth.
- **Leaf-function inlining** — expand small leaf functions at the call site instead of emitting a `JSR`. Tunable via [`-Fli`](#fli-leaf-inline-cap).
- **Loop unrolling** — unroll `for` loops with small constant trip counts. Tunable via [`-Flu`](#flu-loop-unroll-cap).

`-O2` is the recommended baseline for shipped programs.

### `-O3` — aggressive

Adds, on top of `-O2`:

- **Branch inversion** — flip a comparison and its branch when that produces shorter code (e.g. avoid a `JMP` past a body).
- **Branch threading** — when one branch's target is itself an unconditional branch, retarget the original directly.
- **Strength reduction** — replace expensive operations with cheaper equivalents (multiply by a power of two becomes a shift; constant divide becomes a multiply-and-shift; array index multiplication folds when the element size is a power of two).
- **Cross-function DCE** — remove functions that are statically never reached. The reachability analysis traces every call edge in the program.
- **Label cleanup** — collapse redundant labels and remove labels that nothing branches to.

`-O3` makes meaningfully smaller / faster binaries on most programs but pushes the codegen further from the source — set breakpoints by line number rather than by inspecting the listing.

## Tuning knobs

### `-Fli` — leaf inline cap

```bash
xtc -O2 -Fli 200 app.xt -o app.xex
```

Maximum leaf-function size, **in 6502 instructions**, that the inliner will expand at a call site. Default: 100. Requires `-O2+`.

A leaf function is one that calls no other functions in its body. The inliner picks them off because they have no further call chain to worry about — the inlined copy doesn't need a frame, doesn't touch the stack, and folds completely into the caller's flow. Larger caps inline more aggressively (smaller binary cycle counts, larger binary byte counts). Set lower if your binary is bumping up against a memory budget.

### `-Flu` — loop-unroll cap

```bash
xtc -O2 -Flu 16 app.xt -o app.xex
```

Auto-unroll counted `for` loops whose trip count is **≤ `<n>`** at compile time. Default: 5 at `-O2+`, 0 below. Set to 0 to disable.

The threshold trades binary size for cycle count. A loop with 12 iterations unrolls into 12 copies of the body; the loop overhead (compare / branch / step) disappears, but you've spent 12× the body in code bytes. Default 5 is conservative — generous enough to handle obviously-small loops without bloating the binary by accident.

You can also force-unroll a specific loop irrespective of the cap with the `:unroll` annotation — see [Statements & control flow → Manual unrolling](/compiler/language/statements/#manual-unrolling-unroll).

## How to read "9877 → 9698 instructions"

The summary line shows the **6502-instruction** count before and after the optimiser ran on the program's intermediate representation. It's a rough proxy for binary size — most 6502 instructions are 2 or 3 bytes, so the byte-count delta tracks the instruction-count delta closely.

A small delta on `-O2` or `-O3` doesn't mean the optimiser did nothing — register tracking and peephole at `-O1` may have already done the heavy work, and the higher levels just polish. A program that's already tight at `-O1` often gains ≤2 % at `-O3`; a program with redundant loads and unreachable branches can shrink 15–20 %.

## Choosing a level

| When | Pick |
|------|------|
| Active development / asm-level debugging | `-O0` |
| CI builds, smoke tests | `-O1` |
| Default ship build | `-O2` |
| Small-binary / cycle-critical | `-O3` (and consider raising `-Fli` cautiously) |
| Profiling / measuring real overhead | match the ship build (`-O2` or `-O3`) — `-O0` numbers don't predict shipped behaviour |

## Caveat: `volatile` and inline assembly

The optimiser respects `volatile` — declared accesses to a `volatile`-marked variable always emit the read or write. Hardware register pokes belong in `volatile` slots so `-O2`'s dead-store elimination doesn't quietly remove them.

`asm { ... }` blocks are likewise opaque to the optimiser: the compiler saves and restores the registers it thinks the block touched (you can override with `clobbers`, see [Inline assembly](/compiler/language/inline-asm/)), and treats the block as a memory barrier — values held in compiler-tracked registers are flushed to memory before the block runs and reloaded after.
