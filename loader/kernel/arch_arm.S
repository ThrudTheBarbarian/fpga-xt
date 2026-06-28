/*
 * arch_arm.S — ARM (AArch32) kernel glue for the qemu testbed:
 *   - exception vector table + the svc #1 gateway handler
 *   - enter_user: run loaded code in System mode so its `svc` traps cleanly
 *   - set_vbar, and a minimal setjmp/longjmp (no libc)
 *
 * This is the testbed's stand-in for what becomes the FreeRTOS port's chained
 * SVC handler on hardware (svc #0 = scheduler, svc #1 = syscall).
 */
    .syntax unified
    .cpu cortex-a15
    .arm
    .section .text

    .balign 32
    .global vector_table
vector_table:
    b   .             /* reset    */
    b   .             /* undef    */
    b   svc_handler   /* svc      */
    b   .             /* p-abort  */
    b   .             /* d-abort  */
    b   .             /* reserved */
    b   .             /* irq      */
    b   .             /* fiq      */

/* On svc entry (SVC mode): r0-r6 hold the caller's args (r0-r12 are shared with
 * System mode), r7 the syscall number, lr_svc the return address. Save the
 * block, dispatch in C, restore (r0 = result), return. */
    .global svc_handler
svc_handler:
    push    {r0-r12, lr}        /* struct k_regs { r0..r12, lr } */
    mov     r0, sp
    bl      k_syscall_dispatch
    pop     {r0-r12, lr}        /* r0 = result written by dispatch */
    movs    pc, lr             /* return, restoring cpsr from spsr_svc */

/* void set_vbar(void *vectors) */
    .global set_vbar
set_vbar:
    mcr     p15, 0, r0, c12, c0, 0
    bx      lr

/* void enter_user(uintptr_t entry r0, int argc r1, char **argv r2, void *sp_top r3)
 * Switch to System mode, set the user stack, call entry(argc, argv). Returns to
 * the caller (SVC) if entry returns normally; exit() instead longjmps out. */
    .global enter_user
enter_user:
    push    {r4-r11, lr}
    mov     r4, r0              /* entry */
    mov     r5, r1             /* argc  */
    mov     r6, r2             /* argv  */
    mrs     r0, cpsr
    bic     r0, r0, #0x1f
    orr     r0, r0, #0x1f       /* System mode */
    msr     cpsr_c, r0
    mov     sp, r3              /* user stack */
    mov     r0, r5
    mov     r1, r6
    blx     r4                  /* entry(argc, argv) in System mode */
    mrs     r0, cpsr
    bic     r0, r0, #0x1f
    orr     r0, r0, #0x13       /* back to Supervisor mode */
    msr     cpsr_c, r0
    pop     {r4-r11, lr}
    bx      lr

/* int my_setjmp(jmp_buf r0) — saves r4-r11, sp, lr; returns 0 */
    .global my_setjmp
my_setjmp:
    stmia   r0, {r4-r11}
    str     sp, [r0, #32]
    str     lr, [r0, #36]
    mov     r0, #0
    bx      lr

/* void my_longjmp(jmp_buf r0, int val r1) — restores, returns val (>=1) */
    .global my_longjmp
my_longjmp:
    ldmia   r0, {r4-r11}
    ldr     sp, [r0, #32]
    ldr     lr, [r0, #36]
    movs    r0, r1
    moveq   r0, #1
    bx      lr
