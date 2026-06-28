/* Minimal bare-metal startup for qemu-system-arm -M virt.
 * Sets the stack, zeroes .bss, calls main(). */
    .syntax unified
    .cpu cortex-a15
    .arm
    .section .text.start, "ax"
    .global _start
_start:
    ldr   sp, =_stack_top

    /* zero .bss */
    ldr   r0, =__bss_start
    ldr   r1, =__bss_end
    mov   r2, #0
1:  cmp   r0, r1
    bcs   2f
    str   r2, [r0], #4
    b     1b
2:
    bl    main
3:  b     3b          /* main calls the semihosting exit; loop if it returns */
