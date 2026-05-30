# Self-Hosting Roadmap

## Motivation

The xtc compiler is currently written in Objective-C and runs on macOS / Linux
(GNUstep).  This is fine for development, but it means:

- Every developer needs an ObjC toolchain.
- The compiler can't be ported to platforms that don't have ObjC (native
  Windows, bare-metal, the ARM side of the Zynq).
- The compiler never compiles itself, so the language doesn't eat its own
  dogfood — slower to shake out bugs in the std lib, the IR, the codegen,
  and the runtime.
- The ~81K LOC of ObjC is harder to maintain than an equivalent xtc program
  would be, because ObjC's noisier syntax obscures the compiler logic.

Goal: **the xtc compiler compiled by xtc**, producing a binary that runs on
the Zynq hardware and can compile real programs (including itself).

## Target Platform Context

The target for "on the box" compilation is a **Zynq 7020** (MyIR board):

| Resource | Detail |
|----------|--------|
| CPU      | Dual ARM Cortex-A9 @ 867 MHz |
| RAM      | 1 GB DDR3 |
| FPGA     | Artix-7 class fabric running a 6502 soft-core @ ~100 MHz |
| 6502 memory | Up to 32 MB accessible (banked model) |
| OS       | FreeRTOS on one ARM core; SD card / FAT32 routed to the 6502 |
| Toolchain| xtc (ObjC, host) → 6502 asm → .xex, or IR → ARM binary |

This is *very* different from the original Atari 8-bit target (64 KB RAM,
1.79 MHz).  The Zynq's ARM cores have enough headroom to run the compiler
natively at useful speed.

## Two Routes to Self-Hosting

### Route A — Native ARM (recommended)

1. An ARM back-end is added to the IR pipeline.
2. The compiler is written in xtc.
3. The ObjC xtc compiler compiles `xtc.xt` → ARM binary.
4. That ARM binary runs directly on the Zynq's Cortex-A9.
5. It can then compile itself (bootstrap verified) and produce 6502 .xex
   binaries for the soft-core.

Advantages:
- ARM at 867 MHz is fast enough for practical compilation.
- 1 GB heap — the full AST of a multi-thousand-line program fits
  trivially.
- Standard OS interface (FreeRTOS file I/O, argc/argv).

### Route B — 6502 Soft-Core

Write the compiler in xtc, compile to 6502, run on the FPGA core at 100 MHz
with 32 MB addressable space.

This is *possible* — 32 MB is plenty for the AST — but the 6502's three
register files and single ALU make compiler-style workloads (hash lookups,
pointer-chasing tree walks, string scanning) ~50-100× slower than the ARM
at a comparable clock.  Even at 100 MHz, compiling a non-trivial source
file would take minutes.

**Verdict:** Route A is the goal.  Route B is a useful intermediate
milestone to validate the compiler's correctness on real hardware, but
not the primary path.

## Current State of the Pipeline

The IR refactoring has already laid the foundation:

```
Source .xt
  │
  ├─ PP ── Lex ── Parse ── Sema ── IR Lowering ── [optimise] ── 6502 Lowering ── .asm
  │                                          │
  │                              (future)    ├── ARM Lowering ── .s
  │                                          ├── 68k Lowering ── .s
  │                                          └── ...
```

| Component | Status | LOC |
|-----------|--------|-----|
| Preprocessor | ObjC, works | 1,243 |
| Lexer | ObjC, works | ~400 |
| Parser | ObjC, Pratt-style RD | 2,173 |
| Semantic analyser | ObjC, works | ~4,800 |
| AST→IR lowering (`XTIRLowering`) | ObjC, works, target-agnostic | 4,245 |
| IR definition (`XTIR.h`) | ObjC, works | 294 |
| IR peephole / SSA (`XTIRPeephole`, `XTIRSSA`) | ObjC, works | 5,303 |
| **6502 back-end** (`XT6502Lowering`) | **ObjC, works** | **4,452** |
| **ARM back-end** | **does not exist** | **0** |
| 6502 asm optimiser (`XTOptimiser`) | ObjC, works | ~3,189 |
| Assembler / linker (`XAAssembler`) | ObjC, works | ~3,050 |
| Driver / CLI | ObjC, works | ~2,006 |
| Std lib (Array.xt, Map.xt, String.xt, …) | xtc, works | ~12,000 |

The critical missing piece is the ARM back-end.  Everything else is
already in place to be used *by* the compiler — the std lib provides
the data structures, the IR provides the lowering API, and the pipeline
provides the driver skeleton.

## What the xtc Language Provides (for Writing a Compiler)

- **`Array.xt`** — resizable `Object@` list with retain/release, grow,
  insert, remove, dealloc.  Autoboxing means primitives work too.
- **`Map.xt`** — open-addressing hash map with linear probing, tombstone
  remove, geometric resize up to 256 slots.  Good enough for symbol tables.
- **`String.xt`** — heap-backed `u8@` wrapper with length, charAt,
  withCString, equals, hash.
- **`Set.xt`** — hash set backed by Map.
- **`Sort.xt`** — quicksort for Array.
- **`Number.xt` / `Comparable.xt` / `Hashable.xt`** — protocol
  conformance so compiler data types fit into the container classes.
- **ARC** — automatic retain/release on class instances, so AST nodes
  and tokens don't need manual memory management.
- **`int main(int argc, char **argv)`** — entry-point signature already
  supported; just needs runtime wiring on the Zynq side.
- **Autoboxing** — `Array.add(42)` wraps the integer in a `Number`
  automatically.
- **Inline `asm { }`** — for the few places that need raw register
  access or hardware-specific sequences in the runtime.

### Gaps

| Gap | Impact | Workaround |
|-----|--------|------------|
| No reflection | Can't iterate type tables / class metadata at runtime | The compiler writes its type-table lookup as straight-line code (the ObjC version already does this — the type table is explicitly enumerated). |
| No NSScanner | A handful of ad-hoc parsing sites in the ObjC codegen use it | Replace with explicit character scanning (the source is a `u8@` — subscript is cheap). |
| No file I/O in std lib on Zynq | Not yet wired through FreeRTOS | The Atari-side `FILE.xt` exists; a Zynq-side device driver for the SD card path is < 200 lines of C on the FreeRTOS side, exposed as a new trap class. |
| No dynamic code loading | Can't compile-and-run | Not needed for batch compilation. |

None of these are blockers.

## The ARM Back-End

The IR is already designed for multiple targets.  `XT6502Lowering.m`
is 4,452 lines and does:

1. **Register allocation** — assign virtual registers to real registers
   (6502: A, X, Y, or ZP spill slots).  ARM has 16 GPRs; allocation is
   *easier*, not harder.
2. **Instruction selection** — for each `XTIROpcode`, emit the
   corresponding ARM instruction(s).  ARM has `add` / `sub` / `mul` /
   `udiv` / `sdiv` natively, `ldr`/`str` for any width, `cmp` + `b{cond}`,
   `bl` for calls.  No multi-byte synthesis needed.
3. **Calling convention** — follow AAPCS (args in R0-R3, return in R0,
   callee-saves R4-R11).
4. **Stack frame** — ARM's `push`/`pop` with `stmfd`/`ldmfd` or the
   modern `str`/`ldr` with SP-relative offsets.

A rough estimate: **~3,000 lines of ObjC** for a first `XTARMLowering.m`,
structurally parallel to the 6502 version.  The ARM has *more* registers
and *fewer* special cases (no ZP, no bank switching, no 16-bit synthesis
from 8-bit ops), so the per-instruction lowering logic is actually simpler
per opcode.

### Choices

**ARM vs Thumb-2:** The Zynq Cortex-A9 supports both.  ARM mode (32-bit
instructions) is simpler for a compiler to target and has all 16 GPRs
available.  Thumb-2 would produce smaller binaries but restrict register
usage.  Recommend **ARM mode** for the initial back-end; Thumb can come
later if code size becomes an issue.

**Hardware float:** The Cortex-A9 has a VFPv3 FPU.  The xtc run-time math
library already has software float/double routines; for the ARM back-end
these can be replaced with VFP instructions (`vmov`, `vadd`, `vmul`,
`vcmp`, etc.) for a large speedup.  Initial version can use the same
software routines (ported to ARM asm) to get correct behaviour first,
then optimise to VFP.

**Assembly syntax:** GAS (GNU Assembler) `.s` format is the most portable
choice — it can be fed to GCC/LLVM's assembler for linking, and it's
well-supported on ARM Linux, QEMU, and bare-metal toolchains.

## The Compiler Itself (Written in xtc)

### Structural Similarity vs. Fresh Design

Your question — should the xtc compiler look like the ObjC compiler,
or be a fresh design?  There are arguments both ways.

**Keep similar structure** — if the xtc version mirrors the ObjC version's
class hierarchy (`XTPreprocessor`, `XTLexer`, `XTParser`,
`XTSemanticAnalyzer`, `XTIRLowering`, `XT6502Lowering`), then:

- Bug fixes and feature additions can be ported between the two versions
  mechanically.
- Developers who know one can navigate the other immediately.
- The self-hosted version evolves alongside the ObjC bootstrap compiler,
  so there's never a gap where only one of them supports a feature.

**Fresh design** — if starting from scratch, one would naturally:

- Collapse the many per-category ObjC files (46 `.m` files in `codegen/`)
  into fewer xtc modules.
- Use xtc's visitor dispatch with protocols instead of the ObjC
  `@protocol` / `@optional` pattern.
- Build the symbol table directly with `Map.xt` and `Array.xt` instead
  of wrapping Foundation's `NSDictionary` and `NSMutableArray`.
- Skip the ObjC `@property` / `@synthesize` boilerplate.
- Use xtc tuples / multiple return values instead of `&out` parameters
  where that's cleaner.

**Recommendation:** Start *structurally similar* but let the design drift
organically.  The ObjC and xtc versions will diverge over time as the
xtc version takes advantage of the host language's features, and that's
OK — the ObjC version only needs to stay healthy long enough to bootstrap
the xtc version.  After that the ObjC version becomes a legacy reference
and the bootstrap path is:

```
ObjC xtc ──▶ xtc.xt ──▶ ARM binary (v1)
                           │
                    compiles xtc.xt ──▶ ARM binary (v2, self-hosted)
                           │
                    compiles everything else
```

### Size Estimate

| Component | ObjC (LOC) | xtc (LOC, similar struct.) | xtc (LOC, fresh) |
|-----------|-----------|---------------------------|------------------|
| Lexer | ~400 | ~400 | ~350 |
| Preprocessor | 1,243 | ~1,500 | ~1,200 |
| Parser | 2,173 | ~2,500 | ~2,000 |
| Semantic analyser | ~4,800 | ~3,500 | ~2,500 |
| IR lowering | 4,245 | ~1,500 | ~1,200 |
| 6502 back-end | 4,452 | ~1,000 | ~800 |
| ARM back-end | 0 | ~3,000 | ~2,500 |
| Driver / CLI | ~2,000 | ~1,000 | ~800 |
| Support utilities | ~2,000 | ~500 | ~400 |
| **Total** | **~81,000** | **~40,000** | **~18,000** |

The "similar structure" version is ~40K LOC because you carry over the
same architecture with the same comment density; the "fresh" version is
~18K because you drop the ObjC noise and the per-category file splits.
Neither number is a problem for the hardware.

### Platform for Development

The compiler *can* be written and tested on macOS using the ObjC compiler
to produce ARM binaries that run under a Zynq emulator (QEMU system-mode
for Cortex-A9) or on the actual hardware via JTAG / network boot.
Alternatively, `xts` could gain an ARM execution mode — less useful than
real hardware but fine for initial bring-up.

## Bootstrap Sequence

```
Phase 0 (current):
  ObjC xtc ──▶ 6502 .xex (via IR path or legacy codegen)
  ObjC xtc ──▶ IR dump (--emit-ir diagnostic)

Phase 1 — ARM back-end (~3 weeks):
  Add XTARMLowering.m + XTARMLowering.h
  Add ARM runtime routines (startup, heap, stdio)
  Add a Zynq memory model (.lnk)
  Test: compile a trivial xtc program ──▶ ARM binary ──▶ runs on Zynq

Phase 2 — Compiler in xtc, v1 (~8-12 weeks):
  Write xtc.xt covering:
    - Lexer + preprocessor + parser (subset: enough to parse itself)
    - Semantic analyser (type checking + overload resolution + ARC)
    - IR lowering (uses existing XTIRLowering-style dispatch)
    - ARM back-end (uses existing XTARMLowering)
    - Driver / CLI / file I/O
  Compile with ObjC xtc ──▶ arm-xtc binary
  Test: compile simple .xt files on the Zynq

Phase 3 — Bootstrap (~1 week):
  arm-xtc xtc.xt -o arm-xtc-v2
  Verify arm-xtc-v2 produces byte-identical output for a test suite
  ➜ Self-hosting achieved

Phase 4 — Feature parity (~4-6 weeks):
  Add parser coverage for remaining constructs
  Add -O1/-O2/-O3 IR optimiser passes
  Add 6502 back-end to the self-hosted compiler
  Port any remaining std lib dependencies needed for real programs
  Start compiling everything with the self-hosted compiler

Phase 5 — Dogfood:
  All new xtc development happens in xtc
  ObjC compiler is maintained for bootstrapping only
  When the language changes, update both versions (mostly mechanical)
```

### How Long Until ObjC Can Be Retired?

The ObjC compiler needs to be maintained until:
1. The xtc compiler can compile itself (Phase 3).
2. The xtc compiler can produce 6502 binaries for the soft-core (Phase 4).
3. The xtc compiler has feature parity with the ObjC compiler for all
   shipping programs.

After that, the ObjC version is a historical artifact.  New features
are added to the xtc version first; the ObjC version can be updated
from it (not the other way around) for as long as anyone cares to
keep the bootstrap path alive.

Realistically, maintaining both versions across weekly development would
be a tax.  The better model is:

1. Cut over to the xtc compiler as soon as it can compile itself and
   produce working 6502 binaries.
2. Keep the ObjC compiler in a known-good state (like a tagged release)
   for recovery, but don't evolve it further.
3. All new development on the xtc compiler, in xtc.

## What Goes Wrong (Risks)

| Risk | Impact | Mitigation |
|------|--------|------------|
| ARM back-end is harder than expected | Phase 1 slips | Start with a minimal subset (no float, no varargs, no ARC intrinsics) and add later. |
| xtc compiler is too slow on ARM | Wastes developer time | Profile and optimise the hot paths (lexer, parser). The heaviest workloads are character scanning and tree allocation — both are cache-friendly on ARM. |
| Self-hosted compiler produces wrong code for the 6502 back-end | Hard to debug cross-target | Keep the 6502 back-end simple at first; compare output to the ObjC compiler's 6502 output for the same source. |
| ARC / autoboxing bugs found at scale | The compiler exercises every alloc/free edge case | Run the compiler on itself repeatedly; use the existing test suite as a regression harness. |
| ObjC compiler changes are copied to xtc version with bugs | Drift between the two | For Phase 2, implement each feature once in xtc and once in ObjC, testing both paths with the same test suite. |

## Immediate Next Steps (If This Is Greenlit)

1. **Write the ARM back-end.**  Start with `XTARMLowering.m` as a
   structural copy of `XT6502Lowering.m`, replacing 6502 instruction
   selection with ARM.  This can be done in parallel with everything
   else and produces immediate value (any program can be compiled to
   ARM for testing on the Zynq).

2. **Port the std lib file I/O to the Zynq side.**  `FILE.xt` exists
   for Atari; a Zynq device driver (FreeRTOS → FAT32 via SD) is the
   only missing piece.  This is an afternoon's work in C on the
   FreeRTOS side.

3. **Write a minimal `xtc.xt`.**  Even 200 lines of xtc that can lex
   and parse a subset of itself, emitting ARM asm, would be a useful
   milestone.  The full compiler can grow incrementally.

4. **Benchmark a simple parse on the Zynq.**  Before committing to
   the full effort, compile a test program to ARM, run it on the
   Zynq, and measure throughput (source bytes / second through the
   lexer + parser).  This validates the performance assumption.

## Related Work

- `doc/Issues` — contains the existing "68k and/or arm backend" entry.
- `doc/xtc.bnf` — the full grammar, needed by the parser writer.
- `src/xtc/ir/XTIR.h` — IR opcodes and type system.
- `src/xtc/ir/XT6502Lowering.m` — reference for the ARM back-end.
- `docs/optimisation.md` — IR-level optimiser roadmap (relevant once
  the ARM back-end exists and the self-hosted compiler needs -O2/-O3).
