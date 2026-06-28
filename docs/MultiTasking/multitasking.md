# Multitasking & executable loading across target CPUs

Three target CPUs, three sets of constraints, one shared OS design.

| Target CPU | Where it lives | Address model | Stack | Clock |
|------------|---------------|---------------|-------|-------|
| **ARM Cortex-A9** | PS (hard silicon) | 32-bit flat, MMU optional | 32-bit hardware, 4 KB per core (RP2354 limit) | 766 MHz |
| **6502 (SALLY)** | PL (fabric) | 16 banked windows, 32 MB max via page registers | 4 KB internal BRAM, 12-bit SP | 100 MHz |
| **m68k (future)** | PL (fabric) | 32-bit flat, MMU possible | 32-bit hardware, memory-backed | TBD (~50–100 MHz) |

The common question: **can the target CPU load a binary from SD and run it as a separate process under a pre-emptive multitasking OS?** The answer depends entirely on which CPU you're asking about.

---

## 1. Native-ARM: dynamic loading on the Cortex-A9

### Context

The ARM side runs FreeRTOS with everything statically linked into a single image (see [zynq-architecture.md](zynq-architecture.md)). It provides:

- FatFs over SDIO (file I/O)
- USB HID (mouse/keyboard)
- xt-blitter command ring (via AXI-Lite GP0 register pokes)
- LVGL rendering
- GEMDOS RPC mailbox service for the target CPU

There are currently **no dynamically-loadable ARM executables**. Every FreeRTOS task is compiled into the same monolithic image at build time.

### What "loading a binary" would mean

If you wanted ARM-side user apps (a launcher, a terminal, a developer utility) that live as `.elf` files on the SD card and are loaded on demand, you'd need:

```
1. A file format for compiled ARM binaries
2. A relocation mechanism (PIC or fixup table)
3. A symbol-export table from the kernel
4. A memory allocator for loaded code
5. A loader that does: read → parse → allocate → relocate → spawn
6. A task-lifecycle manager (create / kill / clean up)
```

#### 1.1 Binary format — ELF with -fPIE

The ARM GCC toolchain (`arm-none-eabi-gcc`) produces standard ELF files. With `-fPIE -msingle-pic-base -mno-pic-data-is-text-relative`, the compiler generates position-independent executables that can be loaded at any address. The loader parses `PT_LOAD` segments, allocates memory, copies segment data, zeroes `.bss`, and applies relocations.

The ELF-parser is ~250 lines of C. The Xilinx Vitis ARM GCC toolchain already produces ELF; no new tooling needed.

#### 1.2 Relocations

With `-fPIE`, the bulk of relocations are:

| Type | What it fixes | How many |
|------|---------------|----------|
| `R_ARM_RELATIVE` | Absolute pointers in `.data` / `.got` that need the load-base offset added | ~1 per global pointer (dozens to hundreds) |
| `R_ARM_GLOB_DAT` | GOT entries for imported kernel symbols | ~1 per API call used |
| `R_ARM_ABS32` | If compiling without -fPIE, every absolute address | Thousands — avoid this |

Each `R_ARM_RELATIVE` fixup is one add: `*(base + r_offset) += load_bias`. Simple loop.

#### 1.3 Kernel symbol export

Loaded executables need access to FreeRTOS APIs and platform services. The simplest approach is a static export table in the kernel image:

```c
const struct sym_export _kernel_symtab[] = {
    {"xTaskCreate",         (void*)xTaskCreate},
    {"vTaskDelay",          (void*)vTaskDelay},
    {"pvPortMalloc",        (void*)pvPortMalloc},
    {"vPortFree",           (void*)vPortFree},
    {"f_open",              (void*)f_open},
    {"f_read",              (void*)f_read},
    {"f_write",             (void*)f_write},
    {"blitter_submit_cmd",  (void*)blitter_submit_cmd},
    // ... maintain by hand
    {NULL, NULL}
};
```

The loader matches `R_ARM_GLOB_DAT` symbol names against this table and writes the resolved address into the loaded binary's GOT. This is what FreeRTOS+POSIX and similar "process on RTOS" layers do.

#### 1.4 The PIC register problem

ARM `-fPIE` wants a dedicated register for the GOT pointer (typically `r9`). The Xilinx Vitis FreeRTOS BSP doesn't reserve one — it treats all core registers as general-purpose. To make this work:

1. Modify the FreeRTOS startup assembly (`freertos_ARM_interface_N.c` or equivalent) to leave `r9` untouched.
2. Compile the kernel itself with `-mpic-register=r9` so the kernel and loaded modules agree on the ABI.
3. Ensure all interrupt handlers save/restore `r9` (they probably don't today).

If you don't want to fight with the PIC register, an alternative is to compile executables as **position-dependent but relocatable**:
- Link at a fixed address (e.g., `0x08000000`).
- Include a relocation table of absolute addresses to fix up.
- The loader keeps a "load offset" and adds it to every absolute address in the table.

This is cruder but avoids the register-gotcha entirely. The table is larger (every absolute address in the binary) but still manageable for small executables (a 16 KB binary might have ~500 relocatable addresses).

#### 1.5 Memory management

The 1 GB DDR3 makes reservation easy. Carve out `0x08000000`–`0x10000000` (128 MB) as the dynamic-load zone. Use `pvPortMalloc` on a separate heap region (`vPortDefineHeapRegions` in heap_4.c) or a simple page allocator (4 KB pages). Load segments are allocated from this region and freed on task exit.

#### 1.6 Loader pseudo-code

```c
int dl_load(const char *path, uint32_t priority, uint16_t stack_words) {
    // 1. Open via FatFs
    FIL f;
    if (f_open(&f, path, FA_READ) != FR_OK) return -1;

    // 2. Read and validate ELF header
    Elf32_Ehdr ehdr;
    f_read(&f, &ehdr, sizeof(ehdr), &br);
    if (memcmp(ehdr.e_ident, ELFMAG, 4)) return -2;

    // 3. Read program headers
    Elf32_Phdr phdr[ehdr.e_phnum];
    f_lseek(&f, ehdr.e_phoff);
    f_read(&f, phdr, sizeof(Elf32_Phdr) * ehdr.e_phnum, &br);

    // 4. Allocate + copy PT_LOAD segments
    uint32_t load_bias = alloc_segment_space(phdr, ehdr.e_phnum);
    for (int i = 0; i < ehdr.e_phnum; i++) {
        if (phdr[i].p_type == PT_LOAD) {
            uint32_t dst = load_bias + phdr[i].p_vaddr;
            f_lseek(&f, phdr[i].p_offset);
            f_read(&f, (void*)dst, phdr[i].p_filesz, &br);
            memset((void*)(dst + phdr[i].p_filesz), 0,
                   phdr[i].p_memsz - phdr[i].p_filesz);
        }
    }

    // 5. Apply relocations (R_ARM_RELATIVE, R_ARM_GLOB_DAT)
    apply_relocations(load_bias);

    // 6. Create FreeRTOS task
    TaskHandle_t handle;
    xTaskCreate((TaskFunction_t)(load_bias + ehdr.e_entry),
                path, stack_words, NULL, priority, &handle);

    return (int)handle;
}
```

#### 1.7 When is this needed?

**Probably never.** The ARM side's job is to be a backend — filesystem, USB, blitter acceleration, LVGL for modern UI elements. All of these are fixed services known at compile time. There's no use case for loading an ARM app from SD that isn't better served by running it on the target CPU (6502 or m68k).

The exception would be if you wanted ARM-side developer tools (an on-device assembler, a file manager with an LVGL GUI) that are separate from the 6502/m68k workload. That's a plausible future desire but not a current requirement.

#### 1.8 Verdict

| Question | Answer |
|----------|--------|
| Feasible? | Yes, ~1–2 weeks of C work |
| Required now? | No — all ARM tasks are known at compile time |
| Main risk? | ARM PIC ABI register (`r9`) convention with FreeRTOS BSP |
| Recommendation | Defer until a specific ARM-side user-app use case appears |

---

## 2. 6502 (SALLY): bank-switched multitasking

### Context

The SALLY CPU is a 6502-class core in the PL fabric with significant hardware embellishments (see [6502-embellishments.md](6502-embellishments.md)):

- **4 KB internal stack RAM** with 12-bit SP (vs original 6502's 256-byte stack)
- **SP-relative addressing** (`LDA d,SP`, `STA d,SP`, etc. — all 2-cycle)
- **PSH/PLL instructions** for atomic function-frame allocation (5 cycles)
- **Multiple stack banks** for fast context switching (see [banked-stack-context-switch.md](banked-stack-context-switch.md))
- **Banked memory** with three independent page-switchable windows

The memory model (from the xtc linker layout):

```
$D5C0        code bank selector (selects $6000-$9FFF, 16 KB window; 8-bit)
$D5C1        data bank selector (selects $A000-$CFFF, 12 KB window; 8-bit)
             (relocated off zero page — $82/$83 are BASIC's VNTP/VNTD — into the
              CCTL I/O gap that the OS never touches/zeroes; both are readable.
              $D5C2 is reserved for a future data-bank high byte (16-bit / larger
              heap) if the model needs it. See sally_mem XTC_CTL_BASE.)

$2400-$3FFF  System region (unbanked — kernel core, common routines)
$4000-$5FFF  Screen memory (fixed, unbanked)
$6000-$9FFF  Code bank window (via $D5C0, 256× 16 KB = 4 MB addressable)
$A000-$CFFF  Data bank window (via $D5C1, 256× 12 KB = 3 MB addressable)
$D800-$FFF9  Main region (unbanked — ROM, hardware registers)
```

256 code banks × 16 KB = 4 MB of code space.
256 data banks × 12 KB = 3 MB of data/heap space (widen $D5C1 to 16 bits via the
reserved $D5C2 high byte for more).

### 2.1 Why no PIC is needed

Each process is compiled to run at a fixed address:

- **Code** always at `$6000` in the code bank window
- **Data** always at `$A000` in region-C window
- **Zero-page** (`$82–$FF`) is the process's ABI workspace, identical layout per process

When the scheduler switches from process A to process B, it just writes new values into `$D5C0` and `$D5C1` — the bank registers. Process B's code now appears at `$6000`; its data at `$A000`. **No relocation, no fixups, no PIC.** The bank controller *is* the MMU. (The registers are readable, so the scheduler can save the outgoing task's banks before loading the incoming task's.)

This is the same principle as the BBC Micro's sideways ROM banking, the C64's REU, or the 2600's cartridge switching — the address space is a window into a much larger physical memory, and you switch windows on context switch.

### 2.2 Process memory layout

Each process occupies:

| Region | Size | Banked? | Contents |
|--------|------|---------|----------|
| Code | 16 KB (one `$D5C0` bank) | Yes | Executable code, read-only data |
| Data | 12 KB (one `$D5C1` bank) | Yes | Heap, globals, PCB, stack frame |
| ZP save area | 64 bytes | Partially | Saved ZP bytes `$82–$BF`, `$C0–$FF` (part of PCB) |
| Stack | 4 KB | Internal BRAM (banked per [banked-stack-context-switch.md](banked-stack-context-switch.md)) |

The PCB fits inside the region-C page alongside the heap:

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
96     | —    | (rest of 4 KB page available for heap start)
```

Total PCB overhead: ~100 bytes. The remaining ~3.9 KB of the region-C page is the process's heap arena (the HP (heap pointer) in ZP grows downward from the top of the page).

### 2.3 Executable format

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

### 2.4 Pre-emptive scheduler

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

The scheduler tick comes from the ANTIC VBI (vertical blank interrupt, 50/60 Hz) or a dedicated timer. At 100 MHz, a full context switch (save 6 registers + 64 bytes ZP + bank registers + PCB linked-list traversal) takes well under 100 µs — negligible at 60 Hz.

**Fast path** (switching between two processes that are both in the 8-way stack-bank BRAM): just swap bank registers and ZP. No external memory traffic. ~20 cycles = 0.2 µs.

**Slow path** (a cold process from DDR3): the hardware stack-bank controller loads the 4 KB stack from DDR3 via the AXI HP port in ~3.4 µs (see [banked-stack-context-switch.md](banked-stack-context-switch.md)). The loading process is stalled; other processes continue to run.

### 2.5 Syscall convention

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

### 2.6 Process startup

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

### 2.7 Pre-emptive vs cooperative

The same kernel supports both models:

- **Pre-emptive**: timer IRQ fires at VBI rate (50/60 Hz or faster if a dedicated timer is used). The kernel saves context, may reschedule, and restores the chosen process. Every process gets a timeslice regardless of its behaviour.

- **Cooperative**: a process calls `BRK #_yield` to voluntarily yield the CPU. If no process pre-empts, a process can run indefinitely. GEM applications are naturally cooperative (they spend most of their time in `evnt_multi()` waiting for events) but a misbehaving process can hang the system.

The recommended model is **pre-emptive with priority scheduling**, which is what MiNT provides. Cooperative yielding is available for processes that want finer-grained control (e.g., real-time audio).

### 2.8 Signals (MiNT compatibility)

MiNT supports Unix-style signals. On 6502 these are implemented as:

- A **pending_signals** bitmask in the PCB (up to 8 signals, 1 byte)
- The scheduler checks the bitmask on every context switch
- On delivery: the kernel pushes a synthetic frame onto the process's stack (saved PC pointing at a signal-trampoline in unbanked space, saved P with interrupts disabled)
- The trampoline calls the process's signal handler (a fixed entry point in unbanked space that the process registered)
- After the handler returns, the trampoline executes a BRK to re-enter the kernel, which restores the original context

This is complex (~200 lines of assembly) and the MiNT signal model is richer than what 8-bit workloads typically need. **Recommendation**: implement signal delivery as a v2 feature. For v1, processes only need kill/wait/exit — signals can be stubbed to return ENOSYS.

### 2.9 Comparison with original MiNT (m68k)

| Feature | 6502 (this design) | Original MiNT (68030) |
|---------|--------------------|----------------------|
| Pre-emptive | Yes | Yes |
| Process isolation | Bank-based (no write across pages) | MMU-based (4 KB pages, supervisor/user) |
| Max processes | ~64 (limited by code-bank bitmap; PCB limited by region-C pages) | ~4096 |
| Stack per process | 4 KB (one of 8 hardware banks) | Dynamic, up to several MB |
| Binary format | Custom 16-byte header + raw segments | ELF or TOS with relocation tables |
| PIC needed? | No — banks are the MMU | Yes — MMU requires page-aligned segments |
| Signals | Simpler 8-signal subset | Full POSIX signal set |
| Memory protection | By page-bank isolation (a process can't touch another's bank), but no MMU fault on wild pointer within its own page | Full MMU: SEGV on bad access |
| GEM integration | AES on 6502, VDI via blitter, GEMDOS via ARM RPC | Same architecture, native drivers |

### 2.10 Verdict

| Question | Answer |
|----------|--------|
| Feasible? | **Yes** — the hardware supports it directly. Banks = virtual memory. |
| Effort | ~10–14 days of C/asm (scheduler + loader + syscall handler + GEMDOS proxy) |
| Hardest part? | Getting the timer IRQ + BRK vector to play nicely with the SALLY core's existing interrupt logic (there is a `current_task_q` at `$D386` already, suggesting some groundwork is laid) |
| Main gap? | No exception model — a wild store in a process can corrupt its own data page but can't touch other processes (different banks). True memory protection would need an MPU in the fabric. |

---

## 3. m68k: a real MiNT, JIT-hosted on the A9

> The m68k runs as a **JIT on the spare A9** ([[m68k_core_mmu_requirements]]), not
> a fabric soft-core, and **memory protection comes from the A9 MMU**, not a fabric
> 68030 MMU — see [../OS/memory-protection.md](../OS/memory-protection.md) §2 for
> the protection model (and why this lets us skip emulating the 030 MMU entirely).
> The fabric-soft-core detail below is kept as reference for the OS/`Pexec`/GEMDOS
> layering, which is transport-independent; the *core* is A9-JIT, not PL.

### Context

Hosting m68k opens the door to running **real MiNT** — the actual Atari-ST
multitasking OS, not a reimplementation. This is a fundamentally different
proposition from the 6502 case:

- EmuTOS is an actively-maintained, GPL-licensed MiNT distribution
- It already supports multiple Atari machines (ST, STE, TT, Falcon)
- It already has GEMDOS, AES, VDI, and a working `Pexec()` that loads ELF executables
- It already has a process model, pre-emptive scheduler, signals, and memory protection

The question isn't "how do we write multitasking for the m68k?" — it's **"how do we port EmuTOS/MiNT to our custom m68k soft-core?"**

### 3.1 What porting EmuTOS involves

EmuTOS is written in C with ~500 lines of hardware-specific assembly. The architecture-dependent parts are:

```
emutos/
├── arch/               # CPU-specific (mostly 68000 family — no changes needed)
│   └── m68k/
├── sys/                # Machine-specific (board support)
│   ├── st/             # Atari ST
│   ├── ste/            # Atari STE
│   ├── tt/             # Atari TT
│   ├── falcon/         # Atari Falcon
│   └── YOUR_CORE/      # NEW — your soft-core
├── include/
├── gem/                # AES, VDI (portable)
├── gemdos/             # GEMDOS file I/O (portable C, hooks at bottom)
└── drivers/            # Timer, interrupt, console, etc.
```

A new machine directory (`sys/<your_core>/`) needs:

| Component | What it does | Lines of C/asm |
|-----------|-------------|----------------|
| **`crt0.S`** | CPU initialisation (set stack, clear BSS, call main) | ~20 |
| **`vectors.S`** | Exception vector table (reset, bus error, trap #1, IRQs, etc.) | ~30 |
| **`timer.c`** | Programmable timer for scheduler tick (e.g., 100 Hz or 200 Hz) | ~50 |
| **`console.c`** | UART character I/O for debug and boot-time output | ~30 |
| **`ikbd.c`** | Keyboard/mouse input (redirect to PS-side event queue) | ~50 |
| **`bios.c`** | Low-level I/O hooks that EmuTOS expects | ~80 |
| **`xbios.c`** | Extended BIOS (e.g., get clock, set palette) | ~50 |
| **`gemdos.c`** | GEMDOS file I/O: re-mapped to FreeRTOS GEMDOS RPC mailbox | ~100 |
| **Makefile`** | Build config for your toolchain | ~30 |
| **Linker script** | Memory layout (ROM at `$0` or `$F00000`, RAM at `$100000` or wherever) | ~40 |
| | **Total** | **~480 lines** |

This is a ~1–2 week port for someone familiar with EmuTOS internals. The heavy lifting (process loading via `Pexec()`, scheduler, memory management, GEM AES, VDI dispatch) is all already working in EmuTOS's portable C core.

### 3.2 GEMDOS remapping

The critical adaptation: EmuTOS's GEMDOS layer normally talks to a floppy/hard disk via the BIOS. On this hardware, **all file I/O goes through the FreeRTOS GEMDOS RPC mailbox**. The `gemdos.c` file in the new machine port replaces:

- `Fopen()` → send `{OPEN, path, mode}` to ARM via mailbox, wait for reply
- `Fread()` → send `{READ, fd, len}` to ARM, get data back
- `Fwrite()` → send `{WRITE, fd, data, len}`
- `Fclose()` → send `{CLOSE, fd}`
- `Dfree()` → send `{DISK_STATUS}`
- etc.

EmuTOS already abstracts GEMDOS into a set of functions in `gemdos.c` — we just replace the bottom half. The upper half (path parsing, file handles, buffering, MiNT extensions) stays.

### 3.3 Executables: real ELF with real Pexec

MiNT executables are ELF files with a `.mint.header` section containing version, flags, and relocation offsets. The `Pexec()` syscall:

1. Parses the ELF header
2. Reads `PT_LOAD` segments
3. Allocates pages via the MMU (or flat memory if no MMU)
4. Applies relocations (MiNT executables have a custom relocation table, not standard ELF relocs — EmuTOS handles this in `src/gemdos/exec.c`)
5. Sets up the process's stack with `argc`/`argv`
6. Creates a PCB and adds it to the scheduler

The loader is ~1500 lines of C in EmuTOS, already debugged and working. You get it for free.

### 3.4 MMU / memory protection

Memory protection is provided by the **A9 hardware MMU**, not a fabric 68030 MMU.
Because the m68k is JIT-hosted, the guest's RAM is mapped into a guest-process A9
address space with MiNT's protection attributes, and the A9 MMU enforces them on
every translated access — so we **never emulate the 68030 MMU** (and never generate
its bus-error continuation frame). MiNT's memory-protection layer is ported to an
**A9-MMU backend** driven over a hypervisor syscall, in place of a 68030 PMMU
driver. Full mechanism, caveats, and the format-B argument:
[../OS/memory-protection.md](../OS/memory-protection.md) §2.

A flat, no-protection bring-up build (MiNT's no-MMU mode, fixed-address `Pexec`
with base-page relocation) remains available for early porting before the A9
per-process MMU machinery lands.

### 3.5 How GEM maps onto the three-layer model

| GEM layer | m68k (EmuTOS) | 6502 (custom kernel) |
|-----------|---------------|----------------------|
| **AES** (window management, events) | EmuTOS AES — fully featured, multi-process with message queues | AES rewritten in xtc, same API, simpler implementation |
| **VDI** (drawing primitives) | EmuTOS VDI → blitter register pokes (like the 6502 case) | xtc direct blitter dispatch via `$D4Bx`/`$D4Cx` registers |
| **GEMDOS** (file I/O) | EmuTOS GEMDOS → FreeRTOS mailbox | Same mailbox protocol — identical on both CPUs |
| **Process model** | Real MiNT with `Pexec()`, signals, ptrace | Custom kernel with `Pexec()` equivalent, simpler signal model |

The FreeRTOS backend doesn't care which CPU is making the GEMDOS requests — the mailbox protocol is the same. Both the 6502 kernel and the m68k EmuTOS port send the same message format. This means **GEMDOS services are shared across both targets with zero additional work**.

### 3.6 Verdict

| Question | Answer |
|----------|--------|
| Feasible? | **Yes, and it's the shortest path to a full-featured OS** — EmuTOS already exists. |
| Effort | ~1–2 weeks for the board-support port, then you have real MiNT |
| What you get for free | Scheduler, Pexec(), signals, GEM AES, GEMDOS, VDI framework, FAT filesystem support, developer tools |
| Main risk? | The m68k soft-core itself (timing closure, correctness) — the OS port is straightforward |
| Recommendation | Do this when the m68k core exists. Until then, the 6502 custom kernel is the primary path. |

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

The 6502 path is the most concrete right now: the SALLY embellishments (4 KB stack, PSH/PLL, banked memory, stack-bank registers) were designed with exactly this multitasking model in mind. The `current_task_q` register at `$D386` and the 32 KB stack-bank BRAM array (per [banked-stack-context-switch.md](banked-stack-context-switch.md)) are already in the HDL — what's missing is the kernel software that uses them.
