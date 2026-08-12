/* stm32f411ve.ld — STM32F411VET6: 512 KB flash, 128 KB SRAM. */

ENTRY(reset_handler)

MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
}

/* the main stack lives at the top of SRAM and grows down toward the heap */
_stack_size = 8K;
_heap_min   = 4K;

SECTIONS
{
    .isr_vector : ALIGN(512)
    {
        KEEP(*(.isr_vector))
    } > FLASH

    .text :
    {
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.glue_7 .glue_7t)
        KEEP(*(.init))
        KEEP(*(.fini))
        . = ALIGN(4);
    } > FLASH

    .ARM.exidx :
    {
        __exidx_start = .;
        *(.ARM.exidx* .gnu.linkonce.armexidx.*)
        __exidx_end = .;
    } > FLASH

    . = ALIGN(4);
    _data_load = LOADADDR(.data);

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data .data.*)
        . = ALIGN(4);
        _data_end = .;
    } > RAM AT > FLASH

    .bss (NOLOAD) : ALIGN(4)
    {
        _bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RAM

    /* survives a warm reset — used to hand a fault report to the next boot */
    .noinit (NOLOAD) : ALIGN(4)
    {
        *(.noinit .noinit.*)
        . = ALIGN(4);
    } > RAM

    /* No heap section: the firmware is -nostdlib and allocates nothing at
     * runtime — every buffer (console rings, USB pools, paddle state) is
     * static, which is what you want in a device with no way to report an
     * allocation failure.  All RAM above .noinit is free for the stack, and
     * the linker's memory report then means something.
     */
    _heap_start = .;
    _heap_end   = ORIGIN(RAM) + LENGTH(RAM) - _stack_size;
    _stack_top  = ORIGIN(RAM) + LENGTH(RAM);

    ASSERT(_heap_end >= _heap_start, "static allocation overflowed RAM")

    /DISCARD/ : { *(.ARM.attributes) *(.comment) }
}
