# Math coprocessor (A9-offloaded FPU + integer)

> **Proposed design — not built.** A memory-mapped math coprocessor for the 6502
> (and the xtc runtime / other backends) that offloads the actual arithmetic to a
> spare Cortex-A9 core. Same doorbell/mailbox pattern as the GEM service.

## Concept

Write operands to register slots, select an operation, and a spare A9 core does
the math on its native VFP/NEON (+ libm) and writes the result back. Replaces
bespoke software floating point with hardware-accelerated **IEEE-754 single +
double**, the **full libm** (sqrt, trig, log, exp, pow…), and **integer mul/div**
(the 6502 has no hardware multiply). Fits the project's "PS does the compute, PL
is plumbing + register hooks" split.

## Why offload to the A9 (not build FP in fabric)

The A9 already has a hardware FPU, so IEEE-754 + libm come essentially free;
building float IP in the PL would reinvent that at fabric cost. And it is fast:
6502 software FP runs hundreds of cycles (add) to thousands (mul/div) to tens of
thousands (transcendentals); the A9 round-trip is ~2–4 µs on the naïve MMIO path,
dropping toward sub-µs with a burst or OCM mailbox (see *Latency budget*). Net ≈
10× (mul) to ~100× (transcendental) at the ~100 MHz turbo, and far more at
real-Atari speed. Crucially it is **flat cost** — the math itself is nanoseconds,
so a transcendental costs the same as an add; the round-trip dominates everything.

## Both FPU-less realms benefit

Neither emulated CPU has a hardware FPU — the 6502 never did, and the base
ST/STe 68000 doesn't either (FP there is slow software). On the Atari-XT both get
the A9's hardware VFP + libm, by different routes:

- **6502 (X realm)** runs in fabric, so it reaches the A9 through this
  memory-mapped mailbox — the doorbell round-trip described here.
- **m68k (T realm)** already runs *on* the A9 (JIT), so it gets fast FP with **no
  fabric round-trip at all**: 68881/68882 FPU instructions map 1:1 onto A9 VFP, and
  68000 soft-float library calls can be high-level-emulated straight onto native
  FP. So the m68k doesn't use this mailbox — it has a shorter path to the same
  silicon.

Same underlying win — fast FP for two CPUs that never had it — just two paths to
the A9's FP unit.

## Register model

- **Per-task banks.** Each task gets its own register bank in the top bank-page
  MMIO region (same mechanism as GEM / the `$D5C0`/`$D5C1` bank-select). Solves
  multitasking reentrancy with no save/restore and no locking — the cost is just
  address space, which is the cheap resource here.
- **Uniform 8-byte operand slots.** Every slot is 8 bytes; a float uses the low 4
  (upper 4 don't-care), a double uses all 8. The 6502 writes 4 bytes (float) or 8
  (double).
- **A register file, not a single X/Y/Z** — multiple operand slots (`S0..Sn`) per task.
- **A command buffer + an execute/op register + a status register** per bank — the
  6502 writes a short *program* of ops into the command buffer (a single op is just
  a 1-op program; see *Expression-level amortization*).
- Byte order LSB-first (matches the A9; the 6502 writes low byte first).

## Operation encoding

The op byte carries a **2-bit type field** — `float / double / int32 / int64` —
plus ~6 bits of operation (≈64 ops): `+ − × ÷`, sqrt / neg / abs / compare, the
libm transcendentals (sin, cos, tan, atan2, exp, log, log10, pow), integer
mul/div/mod, and int↔float↔double conversions.

Ops **name their source and destination slots** (`X = slot a`, `Y = slot b`,
`Z → slot c`). This is the key feature — see *Expression-level amortization*.

## Handshake / doorbell

- The doorbell is a **write-strobe on the op register** — *every* write fires,
  even if the value is unchanged, so a loop of identical ops each fire (not "on
  value change").
- The strobe sets the bank's bit in a **global pending bitmap** (one bit per
  task-bank). The A9 polls that single word, then services whichever banks are
  flagged — no N-bank polling. (A small event FIFO is an alternative.)
- The A9 reads the flagged bank as **one AXI burst** (lay the bank out
  contiguous), does the op, writes the result, then sets `STATUS = done` last. The
  6502 polls `STATUS`, then reads the result slot.
- **Coherency:** the op-write is last through the ordered CDC FIFO, so the A9
  always sees a consistent operand snapshot. The A9 reaches every bank over AXI
  regardless of which bank the 6502 currently has mapped — the per-task
  bank-select is purely the 6502's view and never races the A9.
- **Servicing: interrupt, not a dedicated poll.** The 2nd A9 core runs the TT/m68k
  emulator, so it can't babysit the mailbox. The doorbell instead raises a **PL→PS
  interrupt** (one of the `IRQ_F2P` lines via the GIC), pinned by **GIC affinity to
  the OS core (core 0)** so the emulator core (core 1) runs undisturbed. The handler
  is a short, self-contained ISR — read the pending bitmap, burst-read the flagged
  bank(s), do the math, write back, set `done` — inline, no task deferral (the work
  is nanoseconds). The **pending bitmap coalesces**: one IRQ drains every flagged
  bank, so concurrent ops from several tasks don't storm the core. (The mailbox
  traffic is purely the fabric 6502's — the m68k reaches the A9's FP a shorter way,
  see *Both FPU-less realms benefit* — which is another reason the OS core is its
  natural home.)
- **Exceptions:** div-by-zero / NaN / overflow / inexact surface in `STATUS` from
  the A9's `fpscr`.

## Latency budget

The round-trip is **not** limited by the interrupt or by A9 compute. At ~860 MHz:

- **IRQ entry** (GIC ack → vector → context save) is a few hundred cycles —
  ~0.1–0.3 µs bare-metal, sub-µs under an RTOS. Not the bottleneck.
- **The math** is nanoseconds — negligible.
- **The cost is AXI/MMIO access** — the A9 *stalls* reaching into PL registers. A
  non-cacheable read from the A9 through the GP port to a fabric register is
  ~0.3–0.5 µs *each* (L1/L2 miss → AXI interconnect → PL → clock-domain crossing →
  back), and single AXI-Lite reads don't pipeline. Reading two operands + op +
  status as individual reads ≈ 6 × ~0.3 µs ≈ ~2 µs of pure stall. That, plus the
  CDC hops and the 6502-side byte shuffling, is the ~2–4 µs — i.e. ~3400 *stalled*
  cycles, not compute.

Cutting it:

- **Burst-read the whole bank in one transaction** — a contiguous bank read over an
  **HP port as a single AXI burst** is one ~0.3–0.5 µs transaction for the entire
  bank instead of N single GP reads.
- **Or skip MMIO entirely** — have the PL drop the operands into **OCM (or a DDR
  mailbox)** that the A9 reads as *cacheable* memory; a cache-line fill is ~tens of
  ns, not a fabric round-trip. Likewise for writing the result back.

Either drops the round-trip toward **sub-µs**, and the expression batching below
amortises whatever's left over many ops.

## Expression-level amortization (the point)

Ops are **3-address**: each names a source-1 slot, a source-2 slot and a
destination slot — `dst = op(src1, src2)` — over the per-task slot file
(`S0..Sn`). A result left in a slot feeds a later op *without ever leaving the
A9*, so the 6502 issues a whole expression as one program and reads back only the
final slot.

### Op word

A program is a list of fixed-width op words — one byte-addressable layout
(6502-friendly):

| byte | field |
|------|-------|
| 0 | opcode — 2-bit type (`float`/`double`/`int32`/`int64`) + 6-bit operation |
| 1 | `src1` slot index |
| 2 | `src2` slot index |
| 3 | `dst` slot index |

Constants and variables are just slot data — the 6502 writes the leaf values into
slots first, then the op list references them. (Unary ops ignore `src2`.) A
**single op is simply a 1-op program** — there's no separate "one-shot" path.

### Submission

1. 6502 writes the leaf values into slots (`S0=a`, `S1=x`, …).
2. 6502 writes the op list into the bank's **command buffer**, plus the op count.
3. 6502 strobes the **execute** doorbell (the op-register write).
4. One IRQ → the A9 burst-reads the bank (slots + program), runs the **whole
   program** against a local copy of the slots (each op = one native A9
   instruction), writes the touched slots back, sets `STATUS = done` last.
5. 6502 polls `done`, reads the result slot.

→ **one round-trip per expression**, not per operation.

### Worked example — `y = a·x² + b·x + c` (Horner form)

Slots `S0=a, S1=b, S2=c, S3=x`; program:

```
MUL S0,S3 -> S4    ; a·x
ADD S4,S1 -> S4    ; a·x + b
MUL S4,S3 -> S4    ; (a·x + b)·x
ADD S4,S2 -> S4    ; … + c   → y in S4
```

Four ops, **one** doorbell/IRQ, **one** result read. ~8 µs of per-op round-trips
collapses to ~one.

### xtc lowering

This is exactly what a compiler back-end already emits: the xtc expression tree
lowers to 3-address ops, and the register allocator targets the **slot file**
(`S0..Sn`) instead of CPU registers — so a float/integer expression compiles
directly into a coprocessor program, emitting only "read the result slot" at the
end. Compound expressions become multi-op programs = single round-trips.

### Bounds & batching

The command buffer holds up to *K* ops and the file *N* slots (both just address
space — size them generously). An expression larger than *K*/*N* splits into
back-to-back batches: leave the partial result in a slot and run the next batch —
the 6502 waits only at batch boundaries, not per op. Register pressure beyond *N*
spills to 6502 memory (rare for typical expressions).

### Semantics within a batch

IEEE NaN/Inf propagate through later ops, so a faulting FP op needn't stop the
program — the sticky exception flags accumulate in `STATUS`, which the 6502 reads
once after `done`. Integer divide-by-zero sets a status flag (define the result —
0 or all-ones).

## Caveats

- Per-op round-trips are great for scalar / occasional math. For **bulk** FP (DSP,
  3D inner loops) hand the A9 the whole array/kernel instead of round-tripping per
  element.
- Reentrancy is handled by the per-task banks; a task preempted mid-batch just
  leaves its state in its own bank.

## Effort

- **PL:** a register block in the hwreg decode (per bank: N × 8-byte slots, op,
  status) + the write-strobe doorbell + the pending bitmap + the result-writeback
  path — reusing the existing hwreg / CDC / GP0 patterns — plus sim. ~1–2 days.
- **PS:** an A9 handler — poll the bitmap, burst-read the bank, switch on the op
  via native float / libm / integer, write back. ~hours.
- **Generalize:** it is the same doorbell/mailbox as GEM, so a clean "PS
  coprocessor mailbox" built once carries the FPU, the integer unit, and any
  future accelerator.
