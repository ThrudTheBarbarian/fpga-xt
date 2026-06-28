/* Bare-metal layout for qemu-system-arm -M virt (RAM at 0x40000000). */
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 0x04000000 } /* 64 MB */

SECTIONS
{
    . = 0x40000000;

    .text : {
        KEEP(*(.text.start))
        *(.text*)
        *(.rodata*)
        *(.glue_7) *(.glue_7t)
    } > RAM

    .ARM.exidx : { *(.ARM.exidx*) } > RAM

    .data : { *(.data*) } > RAM

    . = ALIGN(8);
    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    _heap_start = .;
    . = . + 0x02000000;     /* 32 MB loadable-image arena */
    _heap_end = .;

    . = ALIGN(16);
    . = . + 0x00100000;     /* 1 MB stack */
    _stack_top = .;
}
