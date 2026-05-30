---
title: "Multitasking & executable loading"
description: "Process loading and scheduling across three target CPUs — ARM Cortex-A9, the SALLY 6502, and a future m68k soft core."
---

Three target CPUs, three sets of constraints, one shared OS design.

| Target CPU | Where it lives | Address model | Stack | Clock |
|------------|---------------|---------------|-------|-------|
| **ARM Cortex-A9** | PS (hard silicon) | 32-bit flat, MMU optional | 32-bit hardware, memory-backed | 766 MHz |
| **6502 (SALLY)** | PL (fabric) | 16 banked windows, 32 MB max via page registers | 4 KB internal BRAM, 12-bit SP | 100 MHz |
| **m68k (future)** | PL (fabric) | 32-bit flat, MMU possible | 32-bit hardware, memory-backed | TBD (~50–100 MHz) |

The common question: **can the target CPU load a binary from SD and run it as a separate process under a pre-emptive multitasking OS?** The answer depends entirely on which CPU you're asking about — each target has its own page:

- **[ARM Cortex-A9: dynamic loading](/os/multitasking/arm/)** — ELF + `-fPIE` modules loaded on demand under FreeRTOS.
- **[XT multitasking](/os/multitasking/6502/xt-multitasking/)** — the bank-switched 6502 kernel (banks as the MMU), backed by fast **[banked-stack context switching](/os/multitasking/6502/context-switch/)**.
- **[m68k: porting EmuTOS/MiNT](/os/multitasking/m68k/)** — running real MiNT on a future soft core.

---

## Cross-target common core

Regardless of which target CPU runs the multitasking kernel, these components can be shared:

### Shared (same source, different compile target)

| Component | Language | Lines | Description |
|-----------|----------|-------|-------------|
| **GEMDOS RPC protocol** | C or xtc | ~200 | Message format, mailbox read/write, reply handling |
| **FreeRTOS backend** | C | ~200 | Mailbox dispatch on the ARM side (identical regardless of sender CPU) |
| **Ready-queue logic** | C or xtc | ~100 | Priority queue insert/remove/pick (portable if compiled for the target) |
| **Binary format header** | C or xtc | ~30 | The `.xex` header struct (6502) or ELF parsing (m68k) is different, but the concept of "read header, allocate, load" is the same |
| **GEM AES event model** | xtc | ~500 | AES message queues, evnt_multi(), wind_*() — runs on the target CPU, same API |
| **SALLY-to-FreeRTOS mailbox driver** | Verilog + C | ~200 | The mailbox registers in the PL, CDC handling, IRQ |

### Target-specific

| Component | 6502 | m68k (EmuTOS) |
|-----------|------|---------------|
| Context-switch asm | ~80 lines | Already in EmuTOS |
| Executable loader | ~200 lines (simple header + memcpy) | Already in EmuTOS (ELF + relocation) |
| Syscall trap | BRK handler, ~60 lines | trap #1 handler, already in EmuTOS |
| MMU / protection | Optional MPU in fabric (~1500 LUTs) | Optional MMU in fabric (~2500 LUTs) |
| Device drivers | Custom for SALLY peripherals | EmuTOS already has ST/STE/TT/Falcon drivers |

---

## Summary

| Target | OS approach | Effort | Load-binary mechanism | Status |
|--------|------------|--------|----------------------|--------|
| **ARM** (Cortex-A9) | FreeRTOS + static tasks — no dynamic loading needed | 0 days (deferred) | ELF + -fPIE + kernel symtab | No use case yet |
| **6502** (SALLY) | Custom MiNT-inspired kernel with bank-switching | ~10–14 days | Bank allocator + memcpy — banks are MMU | Hardware foundations exist (stack banks at `$D386`, 4 KB stack, 12-bit SP, banked memory) — OS software not started |
| **m68k** (future core) | Port EmuTOS/MiNT | ~1–2 weeks for board port | Real `Pexec()` — ELF + relocation — already in EmuTOS | Requires the m68k core to exist first |

The 6502 path is the most concrete right now: the SALLY embellishments (4 KB stack, PSH/PLL, banked memory, stack-bank registers) were designed with exactly this multitasking model in mind. The `current_task_q` register at `$D386` and the 32 KB stack-bank BRAM array (per [banked-stack context switching](/os/multitasking/6502/context-switch/)) are already in the HDL — what's missing is the kernel software that uses them.
