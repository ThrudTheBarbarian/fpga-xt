/*
 * xt_boot.S — bare-metal boot for the FreeRTOS-on-qemu testbed.
 * Sets up a stack per CPU mode, zeroes .bss, points VBAR at our vector table,
 * and calls main() in Supervisor mode. (MMU/caches left off — qemu is lenient
 * and the scheduler doesn't need them; add a flat MMU later if required.)
 */
    .syntax unified
    .cpu cortex-a9
    .fpu neon-vfpv3
    .arm

    .equ MODE_FIQ, 0x11
    .equ MODE_IRQ, 0x12
    .equ MODE_SVC, 0x13
    .equ MODE_ABT, 0x17
    .equ MODE_UND, 0x1B
    .equ MODE_SYS, 0x1F
    .equ I_BIT,    0x80
    .equ F_BIT,    0x40

    .section .text.boot, "ax"
    .global _start
_start:
    cpsid if                          /* mask IRQ+FIQ during bring-up */

    /* one stack per mode (sizes from the linker) */
    msr   cpsr_c, #(MODE_IRQ | I_BIT | F_BIT)
    ldr   sp, =_irq_stack_top
    msr   cpsr_c, #(MODE_ABT | I_BIT | F_BIT)
    ldr   sp, =_abt_stack_top
    msr   cpsr_c, #(MODE_UND | I_BIT | F_BIT)
    ldr   sp, =_und_stack_top
    msr   cpsr_c, #(MODE_FIQ | I_BIT | F_BIT)
    ldr   sp, =_fiq_stack_top
    msr   cpsr_c, #(MODE_SYS | I_BIT | F_BIT)
    ldr   sp, =_sys_stack_top
    msr   cpsr_c, #(MODE_SVC | I_BIT | F_BIT)
    ldr   sp, =_svc_stack_top

    /* zero .bss */
    ldr   r0, =__bss_start
    ldr   r1, =__bss_end
    mov   r2, #0
1:  cmp   r0, r1
    bcs   2f
    str   r2, [r0], #4
    b     1b
2:
    /* install our vector table */
    ldr   r0, =xt_vectors
    mcr   p15, 0, r0, c12, c0, 0      /* VBAR */
    isb

    /* enable VFP/NEON: CP10/CP11 full access, then FPEXC.EN
       (the FreeRTOS port saves FPU context, so the FPU must be on) */
    mrc   p15, 0, r0, c1, c0, 2       /* CPACR */
    orr   r0, r0, #(0xf << 20)
    mcr   p15, 0, r0, c1, c0, 2
    isb
    mov   r0, #(1 << 30)              /* FPEXC.EN */
    vmsr  fpexc, r0

    bl    main
3:  b     3b
