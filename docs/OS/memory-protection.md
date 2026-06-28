# Memory protection, the MMU, and the process model

> **Status: decided (2026-06-28) — tier 2.** Native XTOS uses the full A9 MMU:
> per-process address spaces, hardware protection, and demand paging (mmap +
> opt-in swap), with **`spawn`** as the process primitive. `fork()` (tier 3) is
> deferred as a possible single-threaded-legacy compat shim only. This doc is the
> canonical home for the A9 MMU argument; it supersedes the north-star's earlier
> "memory protection is deferred" (P1, now updated). See
> [dynamic-loading.md](dynamic-loading.md) and [xtos-vision.md](xtos-vision.md).

## 1. The reframe: the MMU is now load-bearing, not deferred

The vision deferred ARM-native memory protection (P1) on the grounds that the
multi-CPU design gives client fault-isolation for free. That reasoning assumed
the MMU was *optional* — pure native-app hardening we could add later.

The m68k analysis (§2) changes the economics: **building the A9 MMU lets us delete
the single worst part of the m68k port** (emulating the 68030 MMU and its bus-error
continuation frame). So we are now paying for the A9 MMU *regardless of native
apps* — which means a real, per-process address-space MMU is in hand, and the only
question left is how far to use it on the native side (§3).

## 2. The m68k case: the A9 MMU abrogates the 68030 MMU

The m68k runs as a **JIT on the spare A9** ([[m68k_core_mmu_requirements]]), not a
fabric soft-core. There is no physical 68030, so "the 68030 MMU" only exists if we
choose to *emulate* it in software. We don't have to — and shouldn't.

**The horror we avoid.** The 68020/030 *continue* a faulted instruction
mid-execution rather than restarting it, so on a bus fault the CPU pushes the
format-B stack frame — ~46 words of largely undocumented *micro-architectural*
state — and resuming means pushing that internal state back. It is the reason
demand paging on the 030 was a nightmare (the 040/060 abandoned it for instruction
restart).

**Why it evaporates here.** Two facts stack:

1. **FreeMiNT needs protection, not demand paging.** A protection fault means
   *deliver a signal / kill the process* — you never resume the faulting
   instruction. The entire reason format-B exists (fix-the-fault-and-continue) is
   irrelevant to what MiNT does.
2. **We own the MiNT port.** So we give its memory-protection layer an
   *A9-MMU backend* instead of a 68030 PMMU it would otherwise need emulated.

**The mechanism** (the bare-metal form of what QEMU-user / Amiberry already do):

- The guest's emulated RAM is a DDR region **mapped into the guest process's A9
  virtual space** with MiNT's protection attributes. JIT-translated guest
  loads/stores become plain ARM `[guest_base + m68k_addr]` accesses, and the **A9
  hardware MMU enforces protection on every one for free** — no per-access
  software bounds-check in the JIT (also a real perf win over a software MMU).
- Translated code runs in **A9 user mode** under the guest's protection map; the
  JIT runtime sits in supervisor. A violation is an **A9 Data Abort**.
- The abort handler uses the **UAE-style precise-instruction-boundary mode the JIT
  needs for P6 debugging anyway**: materialize full m68k *architectural* state at
  the faulting instruction, then deliver a **MiNT signal** — synthesized at the
  signal level (which we own; MiNT traps fall through to the A9), not by rebuilding
  a hardware bus-error sequence. **Format-B never gets generated.**

**The work this becomes:** not "emulate the 030 MMU" but "give FreeMiNT's
memory-protection layer an A9-MMU backend" driven via a hypervisor syscall.
FreeMiNT already carries CPU-model-specific protection code (030/040/060 table
formats, plus a no-MMU build), so an A9-hosted variant is in the same spirit — its
`mark_region`/protection calls program the A9 page tables instead of a PMMU. Either
shadow MiNT's protection map into A9 PTEs, or (cleaner, since we own it) make that
layer the sole authority and skip the 030 tables entirely. Granularity is a
non-issue: A9 4 KB pages are finer than MiNT's pages.

**Bonus:** the same MMU gives free self-modifying-code detection (write-protect
translated guest code pages → fault → invalidate the translation), which JITs
otherwise hand-roll.

**Caveats.** This is protection-only. The rare m68k program that catches a bus
error and *resumes the faulting instruction* would need a credible m68k frame — the
precise-state JIT can synthesize the *architectural* restart frame; what we never
need is the *micro-architectural* continuation state. And it is gated on the A9
per-process MMU machinery (§3) existing — one more reason that work pays off.

## 3. The native process model: three tiers

The m68k reframe tips native from tier 1 toward tier 2. Tier 3 (fork) is a
separate, more debatable step.

| Tier | Model | Process primitive | Cost / character |
|------|-------|-------------------|------------------|
| **1** | Flat, no protection | `spawn` | Ships fastest; the current [dynamic-loading.md](dynamic-loading.md) baseline. |
| **2** | MMU, per-process address spaces, protection, **full demand paging** (§4) | `spawn` / `posix_spawn` | Real isolation, modern process model, shared libraries, mmap'd executables/files, lazy alloc, guard pages, opt-in swap — the full useful MMU. Already being built for the m68k. **Recommended.** |
| **3** | MMU + `fork()` | `fork` + `exec` | Maximal classic-Unix *source* compatibility; the gnarliest, most dated primitive. |

### Why tier 2, with fork() designed-for but deferred

`fork()` bundles two separable things, and only one is clearly worth it:

- **Per-process virtual address spaces + protection** — the valuable part, now
  justified by the MMU we're building anyway. Take it.
- **`fork()` as the primitive** — separate and dubious:
  - It is the hardest piece: COW fault handling, page-table duplication, the
    address-space-clone machinery.
  - It is widely regarded as a misfeature (Baumann et al., *"A fork() in the
    road"*) — hostile to threads, large address spaces, and single-address-space
    code. **Hostile to threads** specifically: POSIX `fork()` duplicates *only the
    calling thread*; siblings vanish in the child, so any lock they held (the
    malloc/stdio/loader locks) stays locked forever → the child deadlocks on
    almost any libc call. The "fix" is the async-signal-safe-only rule between
    `fork` and `exec` — i.e. the safe subset of fork *is* spawn. **Our process
    model is multithreaded by construction** (a process = N FreeRTOS tasks sharing
    an address space, §3 / dynamic-loading.md §6), so this lands on us directly.
  - **"Just duplicate all threads" is not the escape — it is strictly worse.** It
    converts deadlock into *silent corruption* (two copies of a thread resume from
    a torn critical section), and it cannot duplicate the kernel/hardware state the
    threads were mid-interaction with — **the PL can't fork** (a duplicated task
    re-issues its blitter/SD/compositor op against one set of hardware; same theme
    as the wired-pages invariant, §4). `exec()` discards all threads anyway, and
    POSIX software expects single-thread semantics, so all-threads fork helps
    nobody. The only coherent fork is the single-thread one.
  - **Most of what you want it for is `fork`-immediately-`exec`** (shell, `make`,
    `gcc`, `configure`), which `posix_spawn` covers without the wasted COW.
  - **Decision (leaning):** `spawn` is the primitive; take the compat hit. If
    tier 3 ever happens, offer single-thread `fork()` purely as a compat shim for
    single-threaded legacy programs — never as the centerpiece.

The genuine `fork()` win is **source compatibility** — running *unmodified* Unix
software (busybox, bash) that assumes fork, which is a real "awesome dev
environment" benefit. So it is a compatibility-vs-complexity trade, not a
correctness one.

The decisive point: **the address-space machinery tier 2 requires is exactly the
prerequisite for fork.** Building tier 2 first loses nothing and de-risks fork — if
the porting reality later demands it, fork is then "just" a COW handler on top.

**Decision (2026-06-28): tier 2.** `posix_spawn` is the primary primitive; the
address-space model is architected so `fork()` *can* be added without rework, but
tier 3 is deferred (and if it ever lands, fork is a single-threaded compat shim,
not the centerpiece).

### What "MMU-based FreeRTOS" actually entails

Stated plainly so the scope is clear: FreeRTOS has **no concept of processes,
address spaces, or fork**. Tier 2/3 means *we* write the VM subsystem, the process
model, address-space switching on context switch (swap `TTBR0`; ARMv7-A **ASIDs**,
8-bit, let us avoid full TLB flushes per switch), and — for tier 3 — the COW
handler. This is consistent with P1 ("FreeRTOS is the bottom 5%; everything else is
XTOS") — it just makes FreeRTOS an even thinner slice (scheduler + sync) and means
we are writing more real kernel. It does **not** revisit the FreeRTOS-not-Linux
decision; it is the OS layer being ours to build, as P1 always intended.

Threads within a process share one address space (`TTBR0`) and the fd table; a
process is a group of FreeRTOS tasks sharing a page table — consistent with the
process table in [dynamic-loading.md](dynamic-loading.md) §6.

## 4. What the MMU buys, and the wired/swappable invariant

"Virtual memory" is a spectrum. Tier 2 should mean **the full useful MMU**, not
just protection. The enabler for everything fault-driven below: the **A9 has
precise, restartable data aborts** — the very thing the 68030 lacked (its
format-B continuation frame, §2). So "fault → service it → re-run the
instruction" is available to us; the JIT-hosted m68k can even get VM tricks it
could never have had natively.

**Comes with tier 2 (the address-space + protection machinery itself):**
per-process virtual address spaces; hardware protection (wild/null pointer →
SIGSEGV, user≠kernel, process≠process); **W^X** pages; **properly shared
libraries** (one *physical* copy mapped into many spaces — this dissolves the flat
model's singleton/shared-globals compromise); shared-memory IPC; **guard pages**
(stack-overflow → fault, not silent corruption); per-region cache/device
attributes (which *replaces* today's manual `Xil_DCacheFlushRange` discipline with
proper memory typing).

**Nearly free on top (a page-fault handler that does one more thing) — folded into
tier 2:** lazy / zero-fill-on-demand memory (sparse allocations cost nothing until
touched); **mmap'd / demand-loaded executables** (the loader maps ELF file pages
instead of `malloc`+`memcpy` → faster `spawn` *and* text shared across instances of
the same program, repaying the flat model's fresh-copy-per-spawn cost); mmap'd
files (the SQLite registry, fonts, assets); **copy-on-write** as a mechanism (cheap
page cloning — and the thing that makes `fork()` mostly already-built, hence "tier 2
is fork-ready").

### Demand paging to disk (swap) — in scope, opt-in, cheap given mmap

Swap is **in scope**, not an anti-feature, because the objections are mitigable and
the cost is low:

- **Wear** is a non-issue: the SD has its own internal FTL, swap is a rare safety
  valve (no steady-state pressure at 1 GB) so write *volume* is low, and it lives
  on a **raw swap partition via the VFS block layer — not FatFs** (sharing the
  wear-aware layer the NAND/SQLite store needs).
- **Jitter** is handled by the invariant below, not by banning swap: the
  latency-sensitive subsystems are never swap victims; only stall-tolerant working
  sets (a TT app like Calamus, a native compiler) are swappable.
- **Cost** is small: building the Group-above demand-paging engine for mmap *is*
  the swap engine. Anonymous swap is the same page-fault handler pointed at the
  swap area, plus an eviction/write-back path and a replacement policy (clock/LRU
  over swappable pages only). Given we build demand paging for mmap regardless, it
  would be odd *not* to complete it into swap.

### The load-bearing rule: PL-visible ⇒ wired

The real invariant is not "swap vs no swap" but **wired vs swappable pages**, and
it is **mandatory for correctness independent of jitter**:

> **Any page the PL touches by physical address must be wired (never swapped, never
> remapped).** The blitter, plane_fetch/compositor, writeback, ANTIC writeback, and
> sprite arena read DDR by *physical* address and know nothing of the A9 page
> tables — swap a page from under them and you get garbage reads or corruption.
> This is the same hazard as the §9 VA→PA-at-`gfx_submit` rule in
> [dynamic-loading.md](dynamic-loading.md), made absolute.

This single rule also *encodes the latency policy for free*: the **XL/ST emulation
surfaces are PL-visible** (the compositor scans them out), so they are wired
automatically — "never swap the Atari" is a consequence, not a policy to enforce.
The default partition:

- **Wired:** PL-visible buffers, the kernel, ISR paths, the JIT runtime, in-flight
  DMA/syscall buffers.
- **Swappable:** native app heaps, TT app working sets — exactly the stall-tolerant
  cases swap exists for.

The pinning bookkeeping this needs is required for DMA correctness anyway, so swap
adds only the eviction policy and swap-area block management on top.

## 5. What this changes in the existing design

- **[dynamic-loading.md](dynamic-loading.md) §9 "MMU-readiness rules" graduate from
  hypothetical to the migration we intend to make.** `copyin`/`copyout` becomes a
  real translated copy; the loader gains per-process address-space setup;
  PL-facing addresses get real VA→PA translation at the `gfx_submit` boundary.
- **The shared-library singleton restriction relaxes** under per-process address
  spaces (each process maps its own copy of a library), **but keep authoritative
  global service state behind the service (tier 1 of the ABI), not in library
  globals** — the guest path and the MMU path both want that.
- **The loader gains an mmap path** (§4): map ELF file pages instead of
  `malloc`+`memcpy`, so `spawn` is cheaper and text is shared across instances —
  relaxing the flat model's fresh-full-copy-per-spawn cost.
- **Pinning becomes a first-class loader/allocator concern** (§4): PL-visible and
  real-time allocations are wired; everything else is swap-eligible. The VA→PA
  helper at `gfx_submit` and the `copyin`/`copyout` discipline are where this lands.
- **`spawn` stays the primary primitive** in every tier; tier 3 only *adds* fork.
- **Vision P1 updated** — "memory protection is deferred" is replaced with the
  committed tier-2 stance (protection is load-bearing via the m68k).

## Related

- [dynamic-loading.md](dynamic-loading.md) — the loader, syscall ABI, process
  table, and the §9 readiness rules this doc promotes.
- [xtos-vision.md](xtos-vision.md) — P1 (protection deferred — see §4), P6 (the
  precise-instruction-boundary JIT the §2 fault path reuses).
- [../MultiTasking/multitasking.md](../MultiTasking/multitasking.md) — per-CPU
  loading/process model (its m68k §3 predates the A9-JIT pivot; §2 here is current).
