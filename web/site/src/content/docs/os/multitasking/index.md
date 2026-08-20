---
title: "Multitasking & executable loading"
description: "Process loading and scheduling across three target CPUs — ARM Cortex-A9, the SALLY 6502, and an m68k target emulated on the spare A9."
---

Three target CPUs, three sets of constraints, one shared OS design.

| Target CPU | Where it lives | Address model | Stack | Clock |
|------------|---------------|---------------|-------|-------|
| **ARM Cortex-A9** | PS (hard silicon) | 32-bit, per-process MMU spaces (load-bearing) | 32-bit hardware, memory-backed | 766 MHz |
| **6502 (SALLY)** | PL (fabric) | 16 banked windows, 32 MB max via page registers | 4 KB internal BRAM, 12-bit SP | 100 MHz |
| **m68k (planned)** | PS — emulated on the 2nd A9 (JIT) | 32-bit flat, uses the A9 MMU | host-backed | A9 766 MHz |

The common question: **can the target CPU load a binary and run it as a separate process under a pre-emptive multitasking OS?** Each target has its own page:

- **[ARM Cortex-A9: dynamic loading](/os/multitasking/arm/)** — **implemented**: ELF `ET_DYN` modules loaded on demand into protected, per-process address spaces. See **[Runtime: loading & memory protection](/os/runtime/)** for how the loader and MMU protection work today.
- **[XT multitasking](/os/multitasking/6502/xt-multitasking/)** — the bank-switched 6502 kernel (banks as the MMU), backed by fast **[banked-stack context switching](/os/multitasking/6502/context-switch/)**.
- **[m68k: FreeMiNT via emulation](/os/multitasking/m68k/)** — running real FreeMiNT under an m68k→ARM JIT on the spare A9, using the A9 MMU for protection.

---

## Cross-target common core

Regardless of which target CPU runs the multitasking kernel, these components can be shared:

### Shared (same source, different compile target)

| Component | Language | Lines | Description |
|-----------|----------|-------|-------------|
| **GEMDOS RPC protocol** | C or xcc | ~200 | Message format, mailbox read/write, reply handling |
| **FreeRTOS backend** | C | ~200 | Mailbox dispatch on the ARM side (identical regardless of sender CPU) |
| **Ready-queue logic** | C or xcc | ~100 | Priority queue insert/remove/pick (portable if compiled for the target) |
| **Binary format header** | C or xcc | ~30 | The `.xex` header struct (6502) or ELF parsing (m68k) is different, but the concept of "read header, allocate, load" is the same |
| **GEM AES event model** | xcc | ~500 | AES message queues, evnt_multi(), wind_*() — runs on the target CPU, same API |
| **SALLY-to-FreeRTOS mailbox driver** | Verilog + C | ~200 | The mailbox registers in the PL, CDC handling, IRQ |

### Target-specific

| Component | 6502 | m68k (FreeMiNT) |
|-----------|------|---------------|
| Context-switch asm | ~80 lines | The emulator's m68k context (handled by the JIT) |
| Executable loader | ~200 lines (simple header + memcpy) | Already in FreeMiNT (`Pexec`, ELF + relocation) |
| Syscall trap | BRK handler, ~60 lines | trap #1 handler, already in FreeMiNT |
| MMU / protection | Optional MPU in fabric (~1500 LUTs) | The A9 MMU (FreeMiNT's protection layer, no 68030 MMU to emulate) |
| Device drivers | Custom for SALLY peripherals | FreeMiNT/EmuTOS already has ST/STE/TT/Falcon drivers; I/O bridged to XTOS |

---

## Summary

| Target | OS approach | Load-binary mechanism | Status |
|--------|------------|----------------------|--------|
| **ARM** (Cortex-A9) | XTOS on FreeRTOS — dynamic ELF loading + protected processes | ELF `ET_DYN` + kernel exports + `DT_NEEDED` libraries (`xtld`) | **Implemented & hardware-validated** — see [Runtime](/os/runtime/) |
| **6502** (SALLY) | Custom MiNT-inspired kernel with bank-switching | Bank allocator + memcpy — banks are the MMU | Hardware foundations exist (stack banks at `$D386`, 4 KB stack, 12-bit SP, banked memory) — OS software not started |
| **m68k** (planned) | Real FreeMiNT under an m68k→ARM JIT on the spare A9 | Real `Pexec()` — ELF + relocation, already in FreeMiNT | A9 MMU provides the protection FreeMiNT needs; emulator integration pending |

The ARM path is built: XTOS loads relocatable ELF programs into protected, per-process address spaces with copy-on-write, shared library text, demand paging, guard pages, W^X, and an enforced PL0 user/kernel boundary — validated on silicon (see [Runtime: loading & memory protection](/os/runtime/)). The 6502 path is the most concrete of the *native-fabric* targets: the SALLY embellishments (4 KB stack, PSH/PLL, banked memory, stack-bank registers) were designed with exactly this multitasking model in mind. The `current_task_q` register at `$D386` and the 32 KB stack-bank BRAM array (per [banked-stack context switching](/os/multitasking/6502/context-switch/)) are already in the HDL — what's missing is the kernel software that uses them.
