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
_vswi:  .word FreeRTOS_SWI_Handler
_virq:  .word FreeRTOS_IRQ_Handler

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
