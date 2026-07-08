# Math coprocessor (A9-offloaded FPU + integer + SIMD)

A memory-mapped math coprocessor for the 6502 (and the xtc runtime): operands
and a short op *program* go into an 8 KB **math page**, one doorbell write runs
the whole program on the A9 (native VFP + libm), and the results come back into
the same page.  Replaces bespoke software floating point with hardware IEEE-754
single + double, the full libm, integer mul/div, and vector (SIMD) ops — at
**one round-trip per expression**, not per operation.

Status: HW-validated — the full smoke test (`docs/video/math-cop-test.bas`:
i32 MUL + f64 SQRT + 4-lane VMUL) passes on hardware, and the doorbell → answer
round-trip measures ~23 µs (see Latency budget).  PL sim-validated (`make
mathcop` / `gp0_mux` / `sally_math_overlay` + full regressions).

## Why offload to the A9 (not build FP in fabric)

The A9 already has a hardware FPU, so IEEE-754 + libm come essentially free;
building float IP in the PL would reinvent that at fabric cost.  6502 software
FP runs hundreds of cycles (add) to tens of thousands (transcendentals); the
mailbox round-trip is a few µs and **flat** — the math itself is nanoseconds,
so a transcendental costs the same as an add, and a whole batched expression
costs about the same as one op.

## Both FPU-less realms benefit

- **6502 (X realm)** runs in fabric and reaches the A9 through this mailbox.
- **m68k (T realm)** runs *on* the A9 (JIT), so 68881/68882 instructions map
  1:1 onto VFP with no mailbox at all — a shorter path to the same silicon.

## Architecture

```
6502                     PL (fabric)                         A9 (FreeRTOS)
----                     -----------                         -------------
$D5C6.0=1  ── map ──►  math page (8 KB BRAM, resident)
store slots/program       │  CPU byte port on the $4000-$5FFF aperture
$D5C7 write (EXEC) ──►  flush DIRTY 64 B lines ──► DDR chunk (0x2080_0000+)
                          │                            ▲ Normal-NC = coherent
                        event FIFO ──► IRQ_F2P[1] ──► ISR ──► worker task
poll $D5C7.0 (done)                                    runs program (VFP+libm)
read result slots  ◄── reload result span ◄── MATH_DONE ◄── results+STATUS
```

- **The math page is a dedicated, always-resident 8 KB BRAM** overlaid on the
  CPU's view of the `$4000-$5FFF` aperture by `$D5C6.0` — a register flip, no
  copy, so entering/leaving the page costs nothing in a hot loop.  The screen
  bank (`$D5C3`) keeps its chunk untouched underneath, ANTIC never sees the
  math page, and an in-flight video page-flip carries on concurrently.
- **Per-task banks are DDR chunks** in the screen_bank stack (`0x2080_0000`,
  8 KB × 256): the OS allocates one chunk per math-using task and retargets
  the page with `$D5C8` on context switch (spill dirty lines to the old chunk,
  fill all of the new — tens of µs, on the context-switch path, never per
  call).  Chunk 0 = none.  A task preempted mid-batch just leaves its state in
  its own chunk; results land there and arrive with the chunk's next fill.
- **The chunk is the mailbox.**  EXEC flushes only the page's dirty lines
  (128-bit line bitmap) to the chunk over screen_bank's S_AXI_GP0 port (shared
  through `gp0_axi_mux`, math priority), then pushes the chunk index into a
  16-deep event FIFO whose non-empty level is **IRQ_F2P[1] (GIC SPI 62)**.
  The chunk stack is a cacheable DMA buffer on the A9 (`mmu.c` sections
  `0x208`/`0x209`, Normal WB-WA): the service invalidates the chunk before
  reading the PL-flushed operands and cleans the result span to the point of
  coherency (DCCMVAC) before the doorbell, so the PL and A9 stay coherent across
  the round-trip.  The clean is what makes the A9's results visible to the PL's
  DDR read — a barrier alone does not order writes across the two master ports.
- **The A9 service** (`loader/test/freertos/mathcop.{c,h}`): an integer-only
  ISR drains the FIFO and notifies a top-priority FPU worker task (this port
  does not save VFP state on the IRQ path), which interprets the program
  against a cached local copy (bulk op fetch, demand slot loads, dirty-only
  writeback), writes results + STATUS into the chunk, and pokes `MATH_DONE`;
  the PL reloads the result span into the page (if that chunk is still
  resident) and raises `$D5C7.0`.

## 6502 registers (CCTL gap, BANK unlock group)

| Reg | Access | Meaning |
|-----|--------|---------|
| `$D5C6` | RW | bit 0 = MAP: overlay the math page on `$4000-$5FFF` (CPU view) |
| `$D5C7` | W  | EXEC doorbell — every write fires (strobe, not value-change) |
| `$D5C7` | R  | bit 0 = done, bit 1 = busy (informational), bit 2 = chunk ready |
| `$D5C8` | RW | backing chunk index; write = spill/fill (poll bit 2) |
| `$D5C9-$D5CC` | R | op-latency counter (LE u32): `clk_sally` cycles from the EXEC write to `done` rising; latched, static between ops. Raw 100 MHz fabric cycles (not step-gated) so it is turbo-independent — `count/100` = µs |

Protocol: fill slots + program, write the op count, strobe `$D5C7`, poll
`$D5C7.0`, read results.  **Between EXEC and done the page must not be
touched** — it *is* the in-flight mailbox (this quiescence is also what makes
the dirty-bitmap clock crossing safe).  `done` clears on EXEC/`$D5C8` writes
with no stale window (the PL masks the CDC round-trip on the CPU side).

## Page layout (8 KB — the ABI in `loader/test/freertos/mathcop.h`)

| Offset | Contents |
|--------|----------|
| `0x0000` | u16 op count (32-bit words used; a vector op counts as 2) |
| `0x0002` | u8 ABI version |
| `0x0003` | u8 STATUS (A9-written: OK / DIV0 / INVALID / BADOP / RANGE) |
| `0x0040` | slots S0..S255, 8 bytes each (2 KB) — also the vector memory |
| `0x0840` | op words, 4 bytes each, up to 1024 (4 KB) |
| `0x1840` | reserved / scratch (never touched by the A9) |

A slot holds one scalar in its low bytes (f32/i32 in bytes 0-3, f64/i64 in
0-7), LSB-first (matches both the 6502 and the A9).

## Operation encoding

**Scalar op word** (4 bytes): byte 0 = 2-bit element type
(`f32`/`f64`/`i32`/`i64`) + 6-bit operation; bytes 1-3 = `src1`, `src2`, `dst`
slot indices — 3-address form, `dst = op(src1, src2)`.  A result left in a
slot feeds a later op without leaving the A9, so a compound expression is one
program and one round-trip:

```
; y = a·x² + b·x + c   (S0=a S1=b S2=c S3=x — Horner form)
MUL S0,S3 -> S4
ADD S4,S1 -> S4
MUL S4,S3 -> S4
ADD S4,S2 -> S4        ; y in S4 — four ops, ONE doorbell, one result read
```

Ops: `+ − × ÷`, neg/abs/sqrt/min/max/cmp/rem, the libm transcendentals
(sin cos tan asin acos atan atan2 exp log log10 pow floor ceil round trunc —
FP types only), int↔float↔double conversions (type field = destination,
src2[1:0] = source type), and integer and/or/xor/not/shl/shr/sar.

**Vector (SIMD) op — two consecutive op words.**  Word 0 is the scalar form
(op in the vector range; the slot bytes become *base* slots); word 1 packs the
lane geometry:

| word 1 byte | field |
|------|-------|
| 0 | lane count (0 means 256) |
| 1 | src1 stride  — signed, in **elements**; |
| 2 | src2 stride  — 0 on a source = broadcast that one element |
| 3 | dst stride |

Elements are packed from the base slot's byte offset (element *i* of a vector
based at slot *B* with stride *s* is at byte `B*8 + i*s*esize`) and must stay
inside the slot region.  Ops: vadd vsub vmul vdiv vmin vmax vabs vneg vsqrt,
vmla (`dst[i] += s1[i]*s2[i]`), vcopy (gather/scatter/broadcast), **vdot** and
**vsum** (reductions into a single slot), vcvt.

This is the 6502-side win for bulk math: a 32-element multiply is **one
8-byte op pair** instead of 32 scalar ops, and a 4×4 matrix multiply is 16
VDOTs (row stride 1, column stride 4) instead of 112 scalar ops.  Strides make
matrix columns, interleaved buffers and reversals addressable without any
CPU-side reshuffling; stride-0 broadcast gives scale/axpy forms via vmla.

### xtc lowering

The op stream is exactly what a compiler back-end emits: the xtc expression
tree lowers to 3-address ops with the register allocator targeting the slot
file, and array expressions lower to vector ops.  A float/integer expression
compiles into a coprocessor program, emitting only "read the result slot".

## A9-side interface (GP0 `MATH` block, `0x43C00600`)

| Offset | Access | Meaning |
|--------|--------|---------|
| `0x00` | R | `MATH_EVT` {valid[8], chunk[7:0]} — a read pops one doorbell event |
| `0x04` | W | `MATH_DONE` {line count[23:16], first line[15:8], chunk[7:0]} |
| `0x08` | R | `MATH_STAT` engine busy / resident chunk / FIFO fill / diag |

`IRQ_F2P[1]` (GIC SPI 62) is level = event FIFO non-empty; one ISR pass drains
every queued doorbell, so concurrent tasks' ops coalesce into one interrupt.

## Latency budget (as built)

**HW-measured** (`$D5C9` counter, doorbell → answer ready) ≈ **23 µs** for a
3-op batch (i32 MUL + f64 SQRT + 4-lane VMUL).  The cost is a fixed
**per-doorbell floor** dominated by the FreeRTOS round-trip — GIC IRQ latency +
notify + context-switch into the FPU worker and back — *not* the flush or the
math (which are sub-µs / nanoseconds):

- IRQ → worker-task wakeup + FPU-worker switch: the bulk of the floor.
- EXEC dirty flush: ~sub-µs, scales with dirty bytes (worst case +1 in-flight
  screen-flip burst on the shared port — the mux re-arbitrates per burst).
- Program: nanoseconds of math; interpreter overhead ~0.1-0.3 µs/op plus a
  cacheable demand load per first-touch slot.
- Result writeback + span reload + done: ~1-2 µs.

Because the floor is per-*doorbell*, not per-op, **batch aggressively** — pack
many op words into one EXEC and the ~23 µs amortizes toward zero-per-op.  The
floor is real wall-clock (the counter is turbo-independent), so the
inline-vs-offload decision is **speed-dependent**, and the comparison is against
the *software* cycle cost of the op, not its instruction count.  At 1× the floor
is only ~42 6502 cycles — below almost any real op (a software 32-bit MUL is
~1-2k cycles, a 32-bit DIV ~2-3k, any float op thousands), so at 1× nearly
everything wins, floats by orders of magnitude.  At the 56× top turbo tier the
floor is ~2300 6502 cycles (~700-odd instructions): *cheap* integer work (adds, a
single narrow multiply) is now quicker inline, but a divide, a short expression
like `y = x/b*c` (~4k cycles), or any float op still favour offload even at the
top tier — it does **not** take vector/matrix batches to win; those are just where
the margin is widest.  The xtc cost model must take the target `CLOCK_MULT` as an
input.  Fast-path headroom if
ever needed: ACP-coherent chunk traffic, NEON in the worker, a spin-polling
worker to cut the IRQ→task handoff.

## Caveats

- Per-batch round-trips suit scalar/expression math and small-vector work.
  For **bulk** DSP over big arrays, hand the A9 the array (it's all DDR) —
  the page is an 8 KB window, not a streaming interface.
- `$D5C7.0` done is a fast-path convenience for the not-preempted case; a task
  rescheduled after completion learns of it from the OS (the service knows
  chunk→task) and finds its results in its chunk.
- The doorbell is ignored (sticky diag bit in `MATH_STAT`) when no chunk is
  mapped (`$D5C8` = 0).

## Stored / named programs

A program can be uploaded inline on every call (id 0), or **registered once under
an id** and invoked by reference, so a repeat call is just one op word plus the
operand slots.  Uploading inline re-`POKE`s the same up-to-4 KB program each
doorbell — thousands of 6502 cycles for a repeated kernel; a stored program pays
that once.  This does not shrink the ~23 µs FreeRTOS round-trip floor, but it
removes the large **6502-side** restaging cost — the decisive win for tight loops
of one kernel (matmul, FIR/`VMLA`, Horner), exactly where offload pays off.  It
also flushes less: a run-by-id only dirties the slot lines, so the EXEC flush
carries operands, not the program.

**Entirely A9-side — no fabric change.**  The PL treats op words as opaque data;
all interpretation is in the worker, so this rides in the `mathcop.{c,h}` build
(rebuild the ELF), not a bitstream respin.

### Commands are control ops in the op stream

No new registers or header fields.  Commands ride the op stream as control ops,
using the free `0x21-0x24` block (`0x20` is `CVT`, `0x28-0x2E` the integer
bitwise ops).  Byte 0 `[7:6]` = element type (live on `CALL`), `[5:0]` = op;
bytes 1-2 = `s16` id; byte 3 = `CALL` arg-base slot.

| op | id | effect |
|----|----|--------|
| `CALL` `0x21` | `>0` user / `<0` builtin | run the program against the current slots (nestable, depth ≤ 8) |
| `DEF` `0x22` | `>0` | begin capturing op words under `id` … |
| `END` `0x23` | — | … until here; store the captured body |
| `UNDEF` `0x24` | `>0` | free a user program |

`id = 0` on `CALL` is illegal (`NOPROG`).  `DEF`s don't nest.  Because `CALL` is
just an op word, a stored program can call another — **composition falls out**.

### ID space & storage

`0` = inline (unchanged); `>0` = user program (interpreted op-word stream);
`<0` = predefined builtin (native C).  User programs live in a **per-task**
table (worker knows chunk→task), a growable heap array that **doubles** on
growth (no fixed cap — a linear-scan lookup and one-time copy into the
interpreter's local buffer make static no faster).

### Builtins (negative ids, native C, slot-only)

`CALL` passes an arg-base slot `b` in byte 3; each builtin reads an `i32` param
header at `S[b]` then float data in the following slots, element-typed by the
`CALL` type field, all within the 256-slot region.  Dot product is already
`VDOT`, so no builtin for it.

| id | kernel | slot layout (from base `b`) |
|----|--------|------------------------------|
| `MATMUL` `-1` | `C = A·B` | `S[b]=i32{M,K,N}`; `A[M*K]`, `B[K*N]` follow; `C[M*N]` after |
| `FFT` `-2` | N-pt complex, in-place | `S[b]=i32{N,dir}`; `N` complex `(re,im)` follow; N ≤ 128 |
| `CONV` `-3` | convolution | `S[b]=i32{L,K}`; `sig[L]`, `kern[K]` follow; `out[L+K-1]` after |
| `CROSS` `-4` | 3-vector `a×b` | `a=S[b..b+2]`, `b=S[b+3..b+5]` → `c=S[b+6..b+8]` |
| `QROOTS` `-5` | roots of `a·x²+b·x+c` | `a,b,c=S[b..b+2]` → `(re₁,im₁,re₂,im₂)=S[b+3..b+6]`, f64 |

### Status additions

`NOPROG 0x20` (CALL of an unknown id), `PROGFULL 0x40` (DEF out of memory) —
both keep bit 7 clear.  `MC_ABI_VERSION` is **2** with the stored-program run path live.

### Idioms

```
first use:   [DEF 5][ …kernel ops… ][END][CALL 5,b=0]   define + run, one doorbell
thereafter:  set input slots ; [CALL 5,b=0]             one op word, no restage
builtin:     set A,B,dims ; [CALL -1(f64),b=0]          matmul, zero upload ever
```

### Implementation status

Implemented in `mathcop.{c,h}` (`MC_ABI_VERSION` = 2): the full ABI, the per-task
table (`mc_prog_store/find/free`, doubling), the interpreter factored into a
reusable `mc_run_ops(page, ops, nops, st, depth)`, and control-op dispatch.
**`DEF`/`END`/`UNDEF` and `CALL` of a user program (id>0) all work** — `CALL`
recurses into `mc_run_ops` against the shared slots, guarded to depth 8, so
programs compose.  Still stubbed: the five **native builtins** (`CALL` id<0
returns `NOPROG`).  Program storage is currently one global table — keying it by
owning task (chunk→task) is a TODO.  **Inline mode is unchanged**: a stream with
no control ops runs inline exactly as before — you never have to store a program.

## Implementation map

- PL: `hdl/math_cop.sv` (page BRAM + dirty bitmap + flush/fill FSM + event
  FIFO), `hdl/gp0_axi_mux.sv`, decode in `sally_mem.sv`, GP0 block in
  `xt_gp0_regs.sv` / `hdl/regmap/xt_gp0.json`; `sim/tb_mathcop.sv`
  (`make mathcop`).
- PS: `loader/test/freertos/mathcop.{c,h}` (+ IRQ 62 dispatch in `zynq.c`,
  init in `main.c`, newlib libm in the kernel link).
- BD: `IRQ_F2P` widened via xlconcat in `gen_ps_bd.tcl` (blitter = GIC 61,
  math = GIC 62).
