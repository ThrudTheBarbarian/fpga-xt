---
title: "ARM Cortex-A9: dynamic loading"
description: "Dynamic ELF module loading on the Zynq PS Cortex-A9 under FreeRTOS — -fPIE binaries, relocations, and a kernel symbol-export table."
---

## Context

The ARM side runs FreeRTOS with everything statically linked into a single image (see `zynq-architecture.md`). It provides:

- FatFs over SDIO (file I/O)
- USB HID (mouse/keyboard)
- xt-blitter command ring (via AXI-Lite GP0 register pokes)
- LVGL rendering
- GEMDOS RPC mailbox service for the target CPU

Dynamic loading of ARM executables is **implemented** — programs are position-independent ELF `ET_DYN` objects loaded at runtime into protected, per-process address spaces. See **[Runtime: loading & memory protection](/os/runtime/)** for how the loader, process model, and MMU protection actually work today. The sections below record the design reasoning that led there.

## What "loading a binary" means

For ARM-side user apps (a launcher, a terminal, a developer utility) that live as `.elf` files on the SD card and are loaded on demand, we will need:

```
1. A file format for compiled ARM binaries
2. A relocation mechanism (PIC or fixup table)
3. A symbol-export table from the kernel
4. A memory allocator for loaded code
5. A loader that does: read → parse → allocate → relocate → spawn
6. A task-lifecycle manager (create / kill / clean up)
```

### Binary format — ELF with -fPIE

The ARM GCC toolchain (`arm-none-eabi-gcc`) produces standard ELF files. With `-fPIE -msingle-pic-base -mno-pic-data-is-text-relative`, the compiler generates position-independent executables that can be loaded at any address. The loader parses `PT_LOAD` segments, allocates memory, copies segment data, zeroes `.bss`, and applies relocations.

The ELF-parser is ~250 lines of C. The Xilinx Vitis ARM GCC toolchain already produces ELF; no new tooling needed.

### Relocations

With `-fPIE`, the bulk of relocations are:

| Type | What it fixes | How many |
|------|---------------|----------|
| `R_ARM_RELATIVE` | Absolute pointers in `.data` / `.got` that need the load-base offset added | ~1 per global pointer (dozens to hundreds) |
| `R_ARM_GLOB_DAT` | GOT entries for imported kernel symbols | ~1 per API call used |
| `R_ARM_ABS32` | If compiling without -fPIE, every absolute address | Thousands — avoid this |

Each `R_ARM_RELATIVE` fixup is one add: `*(base + r_offset) += load_bias`. Simple loop.

### Kernel symbol export

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

The bundled FreeRTOS provides a fairly rich environment for programming, so this is quite a viable route to go down.

### The PIC register problem

ARM `-fPIE` wants a dedicated register for the GOT pointer (typically `r9`). The Xilinx Vitis FreeRTOS BSP doesn't reserve one — it treats all core registers as general-purpose. To make this work, the POR is:

1. Modify the FreeRTOS startup assembly (`freertos_ARM_interface_N.c` or equivalent) to leave `r9` untouched.
2. Compile the kernel itself with `-mpic-register=r9` so the kernel and loaded modules agree on the ABI.
3. Ensure all interrupt handlers save/restore `r9` (they probably don't today).

### Memory management

The 1 GB DDR3 makes reservation easy. Carve out `0x08000000`–`0x10000000` (128 MB) as the dynamic-load zone. Use `pvPortMalloc` on a separate heap region (`vPortDefineHeapRegions` in heap_4.c) or a simple page allocator (4 KB pages). Load segments are allocated from this region and freed on task exit.

### Loader pseudo-code

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

### When is this needed?

The main reason would be to provide ARM-side developer tools (an on-device XT compiler, a file manager with an LVGL GUI) that are separate from the 6502/m68k workload. That's a plausible future desire but not a current requirement.
