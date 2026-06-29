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
    bl    k_syscall_dispatch  /* returns 1 if exit: resume the thunk at PL1 (System) */
    cmp   r0, #1              /* (r0 = C return, before the pop restores the user's r0) */
    bne   1f
    mrs   r0, spsr            /* exit: a PL0 task's thunk must run privileged to call */
    bic   r0, r0, #0x1f       /*   vTaskDelete — force the resumed mode to System */
    orr   r0, r0, #0x1f
    msr   spsr_cxsf, r0
1:  pop   {r0-r12, lr}        /* lr may have been redirected (exit thunk) */
    movs  pc, lr

/* enter_user_and_run(entry, argc, argv): drop from System to USER mode (sharing
 * the task's SP) and call the program entry at PL0; on return, exit via svc. The
 * program runs unprivileged — syscalls/IRQs/faults all trap up to PL1. */
    .global enter_user_and_run
enter_user_and_run:
    mov   r3, r0             /* entry */
    mov   r0, r1             /* argc -> r0 */
    mov   r1, r2             /* argv -> r1 */
    cps   #0x10              /* -> User mode (User/System share SP+LR) */
    isb
    blx   r3                 /* entry(argc, argv) at PL0 */
    movw  r7, #0x101         /* SYS_exit */
    mov   r0, #0             /* exit code 0 (program returned) */
    svc   #1
2:  b     2b

    .extern fault_report
    .extern xtos_task_fault_exit
xt_undef: mov r0, #1
          mov r1, lr
          b   xt_fault
xt_pabt:  mov r0, #3
          sub r1, lr, #4
          b   xt_fault
/* data abort: try demand paging first (T2-c lazy heap). Save the task's
 * caller-saved regs + lr_abt (the C call clobbers them; the task needs them on
 * re-run); if serviced, re-run the faulting instruction; else fall to the kill. */
xt_dabt:  stmfd sp!, {r0-r3, r12, lr}
          mrc   p15, 0, r0, c6, c0, 0      /* r0 = DFAR (faulting data address) */
          bl    xtos_demand_fault          /* r0 = 1 serviced, 0 fatal */
          cmp   r0, #1
          ldmfd sp!, {r0-r3, r12, lr}      /* restore (ldm preserves flags) */
          bne   xt_dabt_fatal
          subs  pc, lr, #8                 /* serviced: re-run, restore CPSR from SPSR */
xt_dabt_fatal:
          mov r0, #4
          sub r1, lr, #8
          b   xt_fault
xt_fiq:   mov r0, #7
          mov r1, lr
          b   xt_fault
/* report the fault, then RETURN INTO THE FAULTING TASK running the fault-exit
 * thunk (movs restores SPSR_abt = the task's mode), so it deletes itself and the
 * scheduler keeps running the rest of the OS. T2-a.2. */
xt_fault: bl   fault_report
          bl   xtos_emerg_sp        @ r0 = emergency stack top, 0 if not a stack overflow
          cmp  r0, #0
          beq  1f
          cps  #0x1f                @ System mode: replace the task's (overflowed) SP
          mov  sp, r0               @   with the emergency stack so the kill thunk has
          cps  #0x17                @   a valid stack to run on
1:        mrs  r0, spsr             @ the fault-exit thunk calls vTaskDelete, so it must
          bic  r0, r0, #0x1f        @   run privileged even if the faulting task was PL0:
          orr  r0, r0, #0x1f        @   force the resumed mode to System
          msr  spsr_cxsf, r0
          movw lr, #:lower16:xtos_task_fault_exit
          movt lr, #:upper16:xtos_task_fault_exit
          movs pc, lr
    .global xt_hang
xt_hang:
    b     xt_hang
