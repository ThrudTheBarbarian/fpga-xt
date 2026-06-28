/* Layout for qemu-system-arm -M xilinx-zynq-a9 (DDR from 0x00100000). */
ENTRY(_start)

MEMORY { RAM (rwx) : ORIGIN = 0x00100000, LENGTH = 0x0FE00000 }

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
    .bss : { __bss_start = .; *(.bss*) *(COMMON) __bss_end = .; } > RAM

    . = ALIGN(16);
    _heap_start = .;            /* for bare_rt's bump (unused by FreeRTOS) */
    . = . + 0x00100000;
    _heap_end = .;

    /* one stack per CPU mode */
    . = ALIGN(16);
    . = . + 0x2000; _fiq_stack_top = .;
    . = . + 0x2000; _und_stack_top = .;
    . = . + 0x2000; _abt_stack_top = .;
    . = . + 0x4000; _irq_stack_top = .;
    . = . + 0x4000; _sys_stack_top = .;
    . = . + 0x8000; _svc_stack_top = .;
}
