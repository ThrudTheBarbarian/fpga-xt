/* Layout for qemu-system-arm -M xilinx-zynq-a9, per docs/Zynq/memory-map.md.
 * Kernel image + FreeRTOS heap_4 + per-mode stacks live in the kernel region
 * (0x0010_0000–0x01FF_FFFF); the newlib OS heap (_sbrk) is the big contiguous
 * 0x0200_0000–0x1FFF_FFFF block. */
ENTRY(_start)

/* kernel region only — capped at 0x0200_0000 so an overflow errors here rather
 * than silently eating the OS heap */
MEMORY { RAM (rwx) : ORIGIN = 0x00100000, LENGTH = 0x01F00000 }

SECTIONS
{
    . = 0x00100000;

    .text : {
        KEEP(*(.text.boot))
        *(.text*)
        *(.rodata*)
        *(.glue_7) *(.glue_7t)
    } > RAM

    .ARM.exidx : { *(.ARM.exidx*) } > RAM
    .data : { *(.data*) } > RAM

    . = ALIGN(8);
    .bss : { __bss_start = .; *(.bss*) *(COMMON) __bss_end = .; } > RAM  /* incl. FreeRTOS heap_4 */

    /* one stack per CPU mode (in the kernel region) */
    . = ALIGN(16);
    . = . + 0x02000; _fiq_stack_top = .;
    . = . + 0x02000; _und_stack_top = .;
    . = . + 0x02000; _abt_stack_top = .;
    . = . + 0x08000; _irq_stack_top = .;
    . = . + 0x08000; _sys_stack_top = .;
    . = . + 0x10000; _svc_stack_top = .;

    /* newlib OS heap (malloc/realloc via _sbrk) — the contiguous CPU heap */
    _heap_start = 0x02000000;
    _heap_end   = 0x20000000;
}
