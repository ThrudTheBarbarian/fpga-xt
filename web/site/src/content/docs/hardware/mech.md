---
title: "Math co-processor (MECH)"
description: "The Mathematical Expression Co-processor Helper — an A9-offloaded IEEE-754 + libm + integer + SIMD engine the FPU-less 6502 and m68k realms reach through an 8 KB mailbox page, one round-trip per expression."
---

The **Mathematical Expression Co-processor Helper (MECH)** gives the FPU-less CPU
realms a hardware maths engine: IEEE-754 single **and** double precision, the full
`libm` (transcendentals), integer multiply/divide/bitwise, and vector (SIMD) ops.
It is not fabric floating-point IP — it is a thin mailbox in the PL that hands work
to the [Cortex-A9 PS](/hardware/arm/), whose real hardware FPU already has all of the
above essentially for free. Building float IP in the FPGA would reinvent that at
fabric cost; MECH borrows the silicon that already exists.

The defining trick: the cost is **one round-trip per *expression*, not per
operation**. A whole batched expression — or a 32-element vector multiply, or a
transcendental — costs about the same as a single add.

## Both FPU-less realms benefit

- **6502 ([X realm](/hardware/x/))** runs in fabric and reaches the A9 through the
  mailbox page described below.
- **m68k ([T realm](/hardware/t/))** runs *on* the A9 as a JIT, so 68881/68882
  instructions map 1:1 onto the A9's VFP with no mailbox at all — a shorter path to
  the same silicon.

## How it works

The 6502 fills the page and rings a doorbell; work crosses into the fabric, over to
the A9, and the results come back into the same page — one round-trip:

<div style="overflow-x:auto; margin:1.5rem 0;">
<svg viewBox="0 0 860 540" role="img" aria-label="MECH round-trip: the 6502 maps and fills the math page, strobes EXEC; the PL flushes to a DDR chunk and interrupts the A9; the A9 worker runs the program on the VFP and writes results back; the PL reloads them and the 6502 reads the result slots." style="width:100%; min-width:660px; height:auto; font-family:ui-sans-serif,system-ui,sans-serif;">
  <style>
    .lane{fill:var(--sl-color-gray-6);}
    .laneLabel{fill:var(--sl-color-text);font-size:13.5px;font-weight:700;text-anchor:middle;}
    .box{fill:var(--sl-color-bg);stroke:var(--sl-color-gray-4);stroke-width:1.5;}
    .accent{fill:var(--sl-color-accent-low);stroke:var(--sl-color-accent);stroke-width:1.75;}
    .l1{fill:var(--sl-color-text);font-size:12.5px;font-weight:600;}
    .l2{fill:var(--sl-color-gray-2);font-size:11px;}
    .code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;}
    .badge{fill:var(--sl-color-bg);stroke:var(--sl-color-accent);stroke-width:1.75;}
    .bnum{fill:var(--sl-color-accent);font-size:11px;font-weight:700;text-anchor:middle;}
    .arrow{stroke:var(--sl-color-gray-2);stroke-width:2;fill:none;}
    .albl{fill:var(--sl-color-gray-2);font-size:10px;font-weight:600;text-anchor:middle;}
    .albg{fill:var(--sl-color-bg);}
  </style>
  <defs>
    <marker id="ah" viewBox="0 0 10 10" refX="8.5" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
      <path d="M0 0 L10 5 L0 10 z" fill="var(--sl-color-gray-2)"/>
    </marker>
  </defs>
  <!-- lanes -->
  <rect class="lane" x="25"  y="55" width="240" height="455" rx="10"/>
  <rect class="lane" x="310" y="55" width="240" height="455" rx="10"/>
  <rect class="lane" x="595" y="55" width="240" height="455" rx="10"/>
  <text class="laneLabel" x="145" y="42">6502 · X realm</text>
  <text class="laneLabel" x="430" y="42">PL fabric · mailbox</text>
  <text class="laneLabel" x="715" y="42">Cortex-A9 · FreeRTOS</text>
  <!-- arrows (drawn first, boxes cover the ends) -->
  <path class="arrow" d="M145 123 V150"          marker-end="url(#ah)"/>
  <path class="arrow" d="M145 198 V225"          marker-end="url(#ah)"/>
  <path class="arrow" d="M255 249 H320"          marker-end="url(#ah)"/>
  <path class="arrow" d="M540 256 L605 318"      marker-end="url(#ah)"/>
  <path class="arrow" d="M715 348 V372"          marker-end="url(#ah)"/>
  <path class="arrow" d="M605 402 L541 464"      marker-end="url(#ah)"/>
  <path class="arrow" d="M320 468 H256"          marker-end="url(#ah)"/>
  <!-- cross-domain signal labels -->
  <g><rect class="albg" x="558" y="279" width="52" height="15"/><text class="albl" x="584" y="290">IRQ 62</text></g>
  <g><rect class="albg" x="530" y="425" width="86" height="15"/><text class="albl" x="573" y="436">MATH_DONE</text></g>
  <g><rect class="albg" x="268" y="461" width="40" height="15"/><text class="albl" x="288" y="472">done</text></g>
  <!-- step boxes: cx L1=145 L2=430 L3=715, box w=220 -->
  <!-- 1 -->
  <rect class="box" x="35" y="75" width="220" height="48" rx="7"/>
  <circle class="badge" cx="52" cy="99" r="11"/><text class="bnum" x="52" y="99" dominant-baseline="central">1</text>
  <text class="l1" x="70" y="96">Map math page</text>
  <text class="l2 code" x="70" y="112">$D5C6.0 = 1</text>
  <!-- 2 -->
  <rect class="box" x="35" y="150" width="220" height="48" rx="7"/>
  <circle class="badge" cx="52" cy="174" r="11"/><text class="bnum" x="52" y="174" dominant-baseline="central">2</text>
  <text class="l1" x="70" y="171">Write operands + program</text>
  <text class="l2" x="70" y="187">slots <tspan class="code">S0…S255</tspan> + op words</text>
  <!-- 3 EXEC -->
  <rect class="accent" x="35" y="225" width="220" height="48" rx="7"/>
  <circle class="badge" cx="52" cy="249" r="11"/><text class="bnum" x="52" y="249" dominant-baseline="central">3</text>
  <text class="l1" x="70" y="246">Strobe EXEC doorbell</text>
  <text class="l2 code" x="70" y="262">$D5C7</text>
  <!-- 4 flush -->
  <rect class="box" x="320" y="225" width="220" height="48" rx="7"/>
  <circle class="badge" cx="337" cy="249" r="11"/><text class="bnum" x="337" y="249" dominant-baseline="central">4</text>
  <text class="l1" x="355" y="246">Flush dirty lines → chunk</text>
  <text class="l2" x="355" y="262">the DDR mailbox, then IRQ</text>
  <!-- 5 worker -->
  <rect class="box" x="605" y="300" width="220" height="48" rx="7"/>
  <circle class="badge" cx="622" cy="324" r="11"/><text class="bnum" x="622" y="324" dominant-baseline="central">5</text>
  <text class="l1" x="640" y="321">Worker runs program</text>
  <text class="l2" x="640" y="337">on the VFP + libm</text>
  <!-- 6 results -->
  <rect class="box" x="605" y="372" width="220" height="48" rx="7"/>
  <circle class="badge" cx="622" cy="396" r="11"/><text class="bnum" x="622" y="396" dominant-baseline="central">6</text>
  <text class="l1" x="640" y="393">Write results + STATUS</text>
  <text class="l2" x="640" y="409">poke <tspan class="code">MATH_DONE</tspan></text>
  <!-- 7 reload -->
  <rect class="box" x="320" y="444" width="220" height="48" rx="7"/>
  <circle class="badge" cx="337" cy="468" r="11"/><text class="bnum" x="337" y="468" dominant-baseline="central">7</text>
  <text class="l1" x="355" y="465">Reload result span</text>
  <text class="l2" x="355" y="481">raise <tspan class="code">done</tspan></text>
  <!-- 8 read -->
  <rect class="accent" x="35" y="444" width="220" height="48" rx="7"/>
  <circle class="badge" cx="52" cy="468" r="11"/><text class="bnum" x="52" y="468" dominant-baseline="central">8</text>
  <text class="l1" x="70" y="465">Poll done, read results</text>
  <text class="l2 code" x="70" y="481">$D5C7.0</text>
</svg>
</div>

An 8 KB BRAM **math page** is overlaid on the CPU's view of the `$4000-$5FFF`
aperture by a single register flip (`$D5C6.0`) — no copy, so entering and leaving
the page costs nothing in a hot loop. The screen bank underneath is untouched and an
in-flight video page-flip carries on concurrently. On EXEC, the PL flushes only the
page's dirty 64-byte lines to a per-task DDR **chunk** (the mailbox), raises an
interrupt, and a top-priority A9 worker task interprets the program on the VFP and
writes the results back into the chunk; the PL reloads the result span into the page
and raises *done*.

The full register list (`$D5C6`–`$D5CC`), the 8 KB page ABI, the op encoding, and the
A9-side GP0 block live in the [register map](/hardware/register-map/) and
[memory map](/hardware/memory-map/).

## Using it from the 6502

The protocol is deliberately tiny — five steps, no driver:

1. **Map** the page: set `$D5C6.0 = 1`.
2. **Store operands** into the slot file (`S0..S255`, 8 bytes each, LSB-first — the
   layout matches both the 6502 and the A9, so a `POKE` of the raw bytes is the
   operand).
3. **Store the program** — a list of 4-byte op words.
4. **Strobe the doorbell**: write the op count, then write `$D5C7` (EXEC).
5. **Poll** `$D5C7.0` (done), then **read** the result slots.

:::caution
Between EXEC and *done* the page **must not be touched** — it *is* the in-flight
mailbox. This quiescence is also what keeps the clock-domain crossing safe.
:::

### One expression, one round-trip

Each op word is 3-address form — `dst = op(src1, src2)` — and a result left in a slot
feeds a later op *without leaving the A9*. So a compound expression is a single
program and a single doorbell:

```text
; y = a·x² + b·x + c   (S0=a  S1=b  S2=c  S3=x, Horner form)
MUL S0,S3 -> S4
ADD S4,S1 -> S4
MUL S4,S3 -> S4
ADD S4,S2 -> S4        ; y in S4 — four ops, ONE doorbell, one result read
```

The op set covers `+ − × ÷`, neg/abs/sqrt/min/max/cmp/rem, the `libm`
transcendentals (sin cos tan asin acos atan atan2 exp log log10 pow floor ceil round
trunc), int↔float↔double conversions, and integer and/or/xor/not/shl/shr/sar.

### Vectors are the bulk-maths win

A vector op is one op-word *pair*: the scalar op plus a lane-geometry word (lane
count and signed per-operand **strides** in elements). That makes MECH shine on
array work:

- A **32-element multiply** is **one 8-byte op pair** instead of 32 scalar ops.
- A **4×4 matrix multiply** is 16 `VDOT`s (row stride 1, column stride 4) instead of
  112 scalar ops.
- Stride-0 on a source **broadcasts** it — free scale / `axpy` forms via `vmla`.

Strides make matrix columns, interleaved buffers and reversals addressable with no
CPU-side reshuffling. Reductions (`vdot`, `vsum`) collapse a whole vector into a
single slot in one op.

## From xcc

The op stream is exactly what a compiler back-end emits, so this is mostly invisible
in [xcc](/compiler/): a float or integer expression tree lowers to 3-address ops with
the register allocator targeting the slot file, array expressions lower to vector ops,
and all that is left in the generated code is "read the result slot." The
[Math standard library](/compiler/api/math/) routes through MECH.

## Reusable programs (define once, call by id)

An op-word program can be uploaded **inline** on every doorbell (the default, id `0`),
or **registered once under an id** and invoked by reference. The define / call / free
commands ride the op stream itself as control ops — there are no extra registers or
header fields:

| Control op | Effect |
|------------|--------|
| `DEF <id>` … `END` | capture the enclosed op words and store them under `id` |
| `CALL <id>` | run stored program `id` against the current slots |
| `UNDEF <id>` | free a stored program |

The id space is signed:

- **`0`** — inline: the op words sitting in the page run as-is (what the examples
  above do).
- **`> 0`** — a **user program**: an interpreted op-word stream held in a per-task
  table.
- **`< 0`** — a **native-C builtin** (below).

Because `CALL` is itself just an op word, a stored program can call another, so
programs **compose** (nestable, depth ≤ 8).

**Why it matters.** Inline upload re-`POKE`s the whole (up to 4 KB) program on every
call — thousands of 6502 cycles for a kernel you run in a loop. Register it once and
each later call is a **single `CALL` op word plus fresh operand slots**; EXEC then
flushes only the operand lines, not the program. That is the decisive win for tight
loops of one kernel — matmul, FIR / `VMLA`, Horner:

```text
first use:   DEF 5  …kernel ops…  END   CALL 5     ; define + run, one doorbell
thereafter:  (set input slots)          CALL 5     ; one op word, nothing restaged
```

### Native builtins

Negative ids are reserved for native-C kernels — the heavy forms it is not worth
expressing as op words. Each reads a small `i32` parameter header plus its data from a
base slot passed in the `CALL`. The user-program path above is the general mechanism;
these are the fast native shortcuts reachable through the same `CALL`:

| id | Kernel | Shape |
|----|--------|-------|
| `MATMUL` | `C = A·B` | M×K · K×N |
| `FFT` | complex FFT, in place | N points, N ≤ 128 |
| `CONV` | 1-D convolution | signal `L`, kernel `K` |
| `CROSS` | 3-vector cross product | `a × b` |
| `QROOTS` | quadratic roots | `a·x² + b·x + c`, f64 |

:::note
The `DEF` / `CALL` / `UNDEF` user-program path (compose to depth 8 included) is live;
the native builtins above are the newest kernels and are still being wired in behind
their reserved ids.
:::

## Latency & when it pays off

The ~23 µs is a fixed **per-doorbell floor**, dominated by the FreeRTOS round-trip
(interrupt latency + notify + context-switch into the FPU worker and back) — **not**
the flush or the maths, which are sub-µs and nanoseconds respectively. A
transcendental therefore costs the same wall-clock as an add, and the floor is *flat*
across the whole batch.

Two consequences drive every "should I offload this?" decision:

**Batch aggressively.** Because the floor is per-doorbell, packing many op words into
one EXEC amortises the ~23 µs toward zero-per-op. One big program always beats many
small ones.

**The break-even is speed-dependent.** The 23 µs is real wall-clock (the latency
counter at `$D5C9` runs on the raw 100 MHz fabric clock, so it is turbo-independent).
Against the CPU it is therefore worth *different amounts* depending on how fast the
6502 is clocked:

| CPU speed | MECH's 23 µs floor ≈ this much 6502 work | Inline beats MECH only for… |
|-----------|------------------------------------------|-----------------------------|
| **1× (1.79 MHz)** | ~42 cycles | a bare byte / 16-bit add. Any multiply, divide or float is hundreds-to-thousands of cycles → **offload wins**. |
| **56× turbo** (top tier) | ~2300 cycles | *cheap* integer work — adds, a single narrow multiply. A **32-bit divide** (~2–3k cyc), a short expression like `y = x / b * c` (~4k cyc), or **any float op** still favour MECH. |

Note that the turbo case does **not** demand "heavy batches": 6502 software multiply
and *especially* divide run into thousands of cycles, so even a two-op integer
`y = x / b * c` (~4k cycles of software work) stays ahead of the ~2.3k-cycle floor
even at the 56× top turbo tier — and well past it. Vectors, matrices and
transcendentals are simply where MECH wins by the *widest* margin, not the threshold
for winning at all.

:::tip[Compare against the *software* cost, not the op count]
The floor figures are how much 6502 work the round-trip is worth — 23 µs × the
effective clock (1.79 MHz at 1×, ~100–120 MHz at turbo; ~2300 cycles ≈ 700-odd
instructions). The decision is just *does the software routine cost more than that?*
6502 integer multiply and divide are hundreds-to-thousands of cycles (a 32-bit divide
alone is ~2–3k), and software float is worse — so the answer is "yes" for almost
everything except a handful of cheap integer ops at high turbo. Don't picture the `42`
as the cost of a multiply; it is the *floor*, and real multiplies/divides tower over
it.
:::

Because the break-even moves with the turbo multiplier, the xcc cost model takes the
target `CLOCK_MULT` as an input when deciding inline-vs-offload.

### Where MECH excels

- **Any float op, at any CPU speed** — software float is hundreds to tens-of-thousands
  of cycles per operation; the flat ~23 µs beats it outright, even a single op at 1×.
  Transcendentals (`sin`/`cos`/`exp`/`pow`) win hardest — tens of thousands of cycles in
  software, the same flat floor here.
- **Integer divide, and short integer expressions** — a 6502 32-bit divide is ~2–3k
  cycles and a multiply ~1–2k, so even a two-op `y = x / b * c` (~4k cycles) beats
  inline right through the top turbo tier. No batch required.
- **Compound scalar expressions** — polynomials, Horner evaluation: a whole chain for
  one round-trip.
- **Double precision** — free on the A9's FPU, brutal in 6502 software.
- **Vectors and matrices** — one op pair per vector; where MECH wins by the widest
  margin.

### Where it doesn't

- **Cheap scalar integer work under turbo** — a single add, or a single narrow
  multiply, is under the ~2.3k-cycle floor at 56×, so the fast CPU does it inline
  quicker. At 1× even those win; the penalty is a turbo effect, and it does **not**
  extend to divides, multi-op expressions, or floats.
- **A trivial op at any speed** — a single byte / 16-bit integer add is below even the
  1× floor; never worth a round-trip.
- **Bulk DSP over very large arrays** — the page is an 8 KB *window*, not a streaming
  interface. For big arrays, hand the A9 the whole array (it is all DDR) rather than
  paging it through MECH.
- **Uploading a kernel inline every call** — re-`POKE`ing a multi-KB program each
  doorbell burns thousands of 6502 cycles. Not a real limit, just don't do it: register
  the kernel once as a [stored program](#reusable-programs-define-once-call-by-id) and
  each call becomes a single `CALL`.
