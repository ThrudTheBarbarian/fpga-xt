/*
 * xt_vectors.S — runtime exception vector table (pointed to by VBAR).
 * SVC -> FreeRTOS_SWI_Handler, IRQ -> FreeRTOS_IRQ_Handler (the real port
 * handlers); the rest hang. Stage 2 swaps the SVC slot for a chaining
 * dispatcher (svc #0 -> FreeRTOS, svc #1 -> the syscall gateway).
 */
    .syntax unified
    .cpu cortex-a9
    .arm

    .extern FreeRTOS_SWI_Handler
    .extern FreeRTOS_IRQ_Handler
    .extern k_syscall_dispatch

    .section .text
    .balign 32
    .global xt_vectors
xt_vectors:
    b     _start            /* reset (unused at runtime) */
    b     xt_undef          /* undefined               */
    ldr   pc, _vswi         /* supervisor call         */
    b     xt_pabt           /* prefetch abort          */
    b     xt_dabt           /* data abort              */
    nop                     /* reserved                */
    ldr   pc, _virq         /* irq                     */
    b     xt_fiq            /* fiq                     */
_vswi:  .word xt_svc_dispatch
_virq:  .word FreeRTOS_IRQ_Handler

/* Chained SVC: svc #0 -> FreeRTOS (yield/scheduler), svc #1 -> syscall gateway.
 * The immediate is read via a stack-saved scratch so the svc #0 path reaches
 * FreeRTOS_SWI_Handler with pristine task state for its portSAVE_CONTEXT. */
    .global xt_svc_dispatch
xt_svc_dispatch:
    push  {r0}
    ldr   r0, [lr, #-4]
    and   r0, r0, #0xff
    cmp   r0, #1
    pop   {r0}                /* restore r0 + sp; flags from cmp preserved */
    bne   FreeRTOS_SWI_Handler
    push  {r0-r12, lr}        /* struct k_regs { r0..r12, lr } */
    mov   r0, sp
    bl    k_syscall_dispatch
    pop   {r0-r12, lr}        /* lr may have been redirected (exit) */
    movs  pc, lr

    .extern fault_report
xt_undef: mov r0, #1
          mov r1, lr
          b   xt_fault
xt_pabt:  mov r0, #3
          sub r1, lr, #4
          b   xt_fault
xt_dabt:  mov r0, #4
          sub r1, lr, #8
          b   xt_fault
xt_fiq:   mov r0, #7
          mov r1, lr
          b   xt_fault
xt_fault: bl  fault_report
    .global xt_hang
xt_hang:
    b     xt_hang
