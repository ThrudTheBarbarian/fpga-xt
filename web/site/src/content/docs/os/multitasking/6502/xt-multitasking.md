---
title: "XT multitasking"
description: "Bank-switched pre-emptive multitasking on the SALLY 6502 — banks as the MMU, the process model, scheduler, BRK syscalls, and a MiNT-style signal subset."
---

The goal here is to port a significant fraction of MiNT over to the 6502, though it'll be written in xtc, not plain C.

## Context

The SALLY CPU is a 6502-class core in the PL fabric with significant hardware embellishments (see [6502-embellishments.md](/hardware/cpu/)):

- **4 KB internal stack RAM** with 12-bit SP (vs original 6502's 256-byte stack)
- **SP-relative addressing** (`LDA d,SP`, `STA d,SP`, etc. — all 2-cycle)
- **PSH/PLL instructions** for atomic function-frame allocation (5 cycles)
- **Multiple stack banks** for fast context switching (see [Context switching](/os/multitasking/6502/context-switch/))
- **Banked memory** with three independent page-switchable windows

The memory model (from the xtc linker layout):

```
$D5C0        code bank selector (selects $6000-$9FFF, 256 x 16 KB)
$D5C1        data bank selector (selects $A000-$CFFF, 256 x 12 KB)

$2400-$3FFF  System region (unbanked — core, common routines)
$4000-$5FFF  Screen memory (fixed, unbanked)
$6000-$9FFF  Code bank window (via $D5C0, 4 MB addressable)
$A000-$CFFF  Data bank window (via $D5C1, 3 MB addressable)
$D800-$FFF9  Main region (unbanked — ROM, hardware registers)
```

- 256 code banks × 16 KB = 4 MB of code space.
- 256 data banks × 12 KB = 3 MB of data/heap space 

## Why no PIC is needed

Each process is compiled to run at a fixed address:

- **Code** page always starts at `$6000` in the code bank window
- **Data** page always at `$A000` in region-C window
- **Zero-page** (`$82–$FF`) is the process's ABI workspace, identical layout per process

When the scheduler switches from process A to process B, it just writes new values into `$D5C0` and `$D5C1` — the bank registers. Process B's code now appears at `$6000`; its data at `$A000`. **No relocation, no fixups, no PIC.** The bank controller *is* the MMU. (The registers are readable, so the scheduler can save the outgoing task's banks before loading the incoming task's.)

This is the same principle as the BBC Micro's sideways ROM banking, the C64's REU, or the 2600's cartridge switching — the address space is a window into a much larger physical memory, and you switch windows on context switch.

## Process memory layout

Each process occupies:

| Region | Size | Banked? | Contents |
|--------|------|---------|----------|
| Code | 16 KB (one `$D5C0` bank) | Yes | Executable code, read-only data |
| Data | 12 KB (one `$D5C1` bank) | Yes | Heap, globals, PCB, stack frame |
| ZP save area | 64 bytes | Partially | Saved ZP bytes `$82–$BF`, `$C0–$FF` (part of TCB) |
| Stack | 4 KB | Internal BRAM (banked per [Context switching](/os/multitasking/6502/context-switch/)) |

The TCB fits inside the data pages alongside the heap:

```
Offset | Size | Field
0      | 1    | state (ready/running/blocked/zombie)
1      | 1    | priority (0–255, higher = more urgent)
2      | 1    | code_bank ($D5C0 value for this process)
3      | 2    | data_bank ($D5C1 value)
5      | 1    | stack_bank (0–7 for the 8-way stack RAM)
6      | 2    | saved_sp (12-bit SP stored as 16-bit word)
8      | 1    | entry_point_bank (for exec/restart)
9      | 2    | heap_chain_ptr (linked list of region-C pages)
11     | 16   | AES message queue (ring buffer for GEM events)
27     | 2    | next_pcb (linked-list pointer)
29     | 2    | exit_code (set by _exit syscall)
31     | 1    | flags (bit 0: needs GEM, bit 1: background, etc.)
32     | 64   | saved ZP ($82–$BF, $C0–$FF on context switch)
96     | —    | (rest of 12 KB page available for heap start)
```

Total PCB overhead: ~100 bytes. The remaining ~11.9 KB of the banked data is the process's initial heap arena (the HP (heap pointer) in ZP grows downward from the top of the page).

## Executable format

A 6502 executable is dead simple — no ELF needed:

```c
struct xex_header {
    uint16_t magic;           // 0xFFFF (Atari .xex convention, or custom)
    uint16_t code_size;       // bytes to copy into code bank at $6000
    uint16_t data_size;       // bytes to copy into data bank at $A000
    uint16_t bss_size;        // zero-fill after data in data bank
    uint8_t  entry_bank;      // 0xFF = allocate any free code bank
    uint16_t entry_offset;    // offset from $6000 of start address
    uint16_t stack_reserve;   // bytes to reserve in 4 KB stack page
    uint8_t  flags;           // bit 0: needs GEM, bit 1: background
};
// Followed by code_size bytes of code, then data_size bytes of data.
```

16-byte header, then raw segments. The loader reads the file via GEMDOS RPC → FreeRTOS → FatFs, allocates a code bank and a data bank from the free-bank bitmap, memcpy's the segments into physical memory (by setting the bank register and writing to `$6000`/`$A000`), zeroes `.bss`, and creates a PCB.

## Pre-emptive scheduler

The scheduler runs out of the **system region** (`$2400–$3FFF`, unbanked). It's a simple priority round-robin:

```
tick_interrupt:
    save_registers_to_stack()         // A, X, Y, P on the current process's stack
    save_zp_to_pcb()                  // ZP bytes $82–$FF → PCB in region-C page
    save_stack_bank_and_sp()          // bank_select register + SP into PCB
    save_bank_registers_to_pcb()      // $D5C0, $D5C1 values into PCB

    call scheduler_pick_next()        // walk process list, find highest-priority ready task
    if (next != current):
        load_bank_registers_from_pcb(next)
        load_stack_bank_and_sp(next)
        load_zp_from_pcb(next)
        current_pid = next_pid

    restore_registers_from_stack()
    RTI
```

The scheduler tick comes from the ANTIC VBI (vertical blank interrupt, 50/60 Hz) or a dedicated timer. At 120 MHz, a full context switch (save 6 registers + 64 bytes ZP + bank registers + PCB linked-list traversal) takes well under 100 µs — negligible at 60 Hz.

**Fast path** (switching between two processes that are both in the 8-way stack-bank BRAM): just swap bank registers and ZP. No external memory traffic. ~20 cycles = 0.2 µs.

**Slow path** (a cold process from DDR3): the hardware stack-bank controller loads the 4 KB stack from DDR3 via the AXI HP port in ~3.4 µs (see [Context switching](/os/multitasking/6502/context-switch/)). The loading process is stalled; other processes continue to run.

## Syscall convention

| Event | Mechanism | Entry point |
|-------|-----------|-------------|
| Yield / syscall | `BRK #syscall_number` | Fixed BRK vector in unbanked space |
| Pre-emption | Timer → IRQ → saved context | IRQ vector in unbanked space |
| GEMDOS file I/O | BRK + GEMDOS mailbox | Kernel dispatches RPC to ARM |
| VDI draw command | BRK + VDI opcode | Kernel dispatches to blitter registers |

`BRK` is the 6502's software-interrupt instruction. The kernel installs a handler in unbanked ROM that:
1. Saves context (same as tick interrupt above)
2. Decodes the syscall number from the byte after the BRK
3. Dispatches to the appropriate kernel service
4. Restores context and returns via `RTI`

The xtc compiler already uses `BRK` for its `_xcall` cross-bank mechanism; the syscall path reuses the same hardware vector.

## Process startup

When `Pexec()` loads an executable:

1. Allocate a code bank (first free slot in the 256-bit bank bitmap)
2. Allocate a region-C page for data + PCB
3. Copy code into the code bank (set `$D5C0` to the bank number, memcpy to `$6000`)
4. Copy initial data into the data page (set `$D5C1` to the page number, memcpy to `$A000`)
5. Zero `.bss` region in the data page
6. Allocate a stack bank (from the 8-way stack hardware)
7. Set SP to `$FFF` (top of 4 KB stack), minus `stack_reserve`
8. Initialise ZP: `HP` = top of region-C page, `SP` = stack pointer low byte
9. Set PCB fields: initialise saved register state (all zero except entry point)
10. Mark process as READY and add to scheduler's ready queue

When the scheduler picks this process and context-switches to it, execution begins at `$6000 + entry_offset` with the stack and ZP already set up. No trampoline needed.

## Pre-emptive vs cooperative

The same kernel supports both models:

- **Pre-emptive**: timer IRQ fires at VBI rate (50/60 Hz or faster if a dedicated timer is used). The kernel saves context, may reschedule, and restores the chosen process. Every process gets a timeslice regardless of its behaviour.

- **Cooperative**: a process calls `BRK #_yield` to voluntarily yield the CPU. If no process pre-empts, a process can run indefinitely. GEM applications are naturally cooperative (they spend most of their time in `evnt_multi()` waiting for events) but a misbehaving process can hang the system.

The recommended model is **pre-emptive with priority scheduling**, which is what MiNT provides. Cooperative yielding is available for processes that want finer-grained control (e.g., real-time audio).

## Signals (MiNT compatibility)

MiNT supports Unix-style signals. On 6502 these are implemented as:

- A **pending_signals** bitmask in the PCB (up to 8 signals, 1 byte)
- The scheduler checks the bitmask on every context switch
- On delivery: the kernel pushes a synthetic frame onto the process's stack (saved PC pointing at a signal-trampoline in unbanked space, saved P with interrupts disabled)
- The trampoline calls the process's signal handler (a fixed entry point in unbanked space that the process registered)
- After the handler returns, the trampoline executes a BRK to re-enter the kernel, which restores the original context

This is complex (~200 lines of assembly) and the MiNT signal model is richer than what 8-bit workloads typically need. **POR**: implement signal delivery as a v2 feature. For v1, processes only need kill/wait/exit — signals can be stubbed to return ENOSYS.

## Comparison with original MiNT (m68k)

| Feature | 6502 (this design) | Original MiNT (68030) |
|---------|--------------------|----------------------|
| Pre-emptive | Yes | Yes |
| Process isolation | Bank-based (no write across pages) | MMU-based (4 KB pages, supervisor/user) |
| Max processes | ~64 (limited by code-bank bitmap; PCB limited by 256 data-pages) | ~4096 |
| Stack per process | 4 KB (one of 8 hardware banks) | Dynamic, up to several MB |
| Binary format | Custom 16-byte header + raw segments | ELF or TOS with relocation tables |
| PIC needed? | No — banks are the MMU | Yes — MMU requires page-aligned segments |
| Signals | Simpler 8-signal subset | Full POSIX signal set |
| Memory protection | By page-bank isolation (a process can't touch another's bank), but no MMU fault on wild pointer within its own page | Full MMU: SEGV on bad access |
| GEM integration | AES on 6502, VDI via blitter, GEMDOS via ARM RPC | Same architecture, native drivers |

## Verdict

| Question | Answer |
|----------|--------|
| Feasible? | **Yes** — the hardware supports it directly. Banks = virtual memory. |
| Effort | ~10–14 days of C/asm (scheduler + loader + syscall handler + GEMDOS proxy) |
| Hardest part? | Getting the timer IRQ + BRK vector to play nicely with the SALLY core's existing interrupt logic (there is a `current_task_q` at `$D386` already, some groundwork is laid) |
| Main gap? | No exception model — a wild store in a process can corrupt its own data page but can't touch other processes (different banks). True memory protection would need an MPU in the fabric. |
