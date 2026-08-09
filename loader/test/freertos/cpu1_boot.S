/*
 * cpu1_boot.S — CPU1's reset entry and CPU1's own exception vectors.
 *
 * CPU1 arrives here straight from the BootROM pen (see cpu1.h): MMU off, caches
 * off, IRQ/FIQ masked, no stack.  It runs in place out of the kernel image, so
 * `ldr rN, =symbol` literals are correct absolute addresses — kernel VA == PA.
 *
 * CPU1 gets its OWN vector table.  Without it a fault on CPU1 would branch to
 * address 0 and the core would simply vanish with no way to tell that from "the
 * pen never released it".  Instead each vector records the offending PC and the
 * vector number in the mailbox and parks, so CPU0 can read the corpse out of
 * /OS/proc/cpu1.
 */
#include "cpu1.h"

    .syntax unified
    .cpu cortex-a9
    .fpu neon-vfpv3
    .arm

    .section .text, "ax"

    .global cpu1_entry
    .type   cpu1_entry, %function
cpu1_entry:
    cpsid   if                          /* stay masked; CPU1 takes no interrupts yet */

    ldr     r0, =cpu1_vectors
    mcr     p15, 0, r0, c12, c0, 0      /* VBAR */
    isb

    /* ACTLR is per-core too: join the SCU so this core participates in
     * coherency and in the cross-core event path.  Harmless today (CPU1 runs
     * MMU-off and uncached), and required the day it runs cached. */
    mrc     p15, 0, r0, c1, c0, 1       /* ACTLR */
    orr     r0, r0, #(1 << 6)           /* SMP */
    mcr     p15, 0, r0, c1, c0, 1
    dsb
    isb

    /* CPACR / FPEXC are per-core, so CPU1 must enable its own VFP+NEON —
     * CPU0 doing it in xt_boot.S does nothing for this core. */
    mrc     p15, 0, r0, c1, c0, 2       /* CPACR: full access to CP10/CP11 */
    orr     r0, r0, #(0xf << 20)
    mcr     p15, 0, r0, c1, c0, 2
    isb
    mov     r0, #(1 << 30)              /* FPEXC.EN */
    vmsr    fpexc, r0

    ldr     sp, =CPU1_STACK_TOP         /* uncached AMP region — see cpu1.h */
    bl      cpu1_main                   /* never returns */
0:  wfi
    b       0b

/* ---- CPU1's exception vectors -------------------------------------------- */

/* Record the fault in the mailbox and park.  These handlers touch no stack —
 * the fault modes have no SP set up — and clobber only r0/r1, which is fine
 * because this core is not going anywhere afterwards.
 *
 * Only the FIRST fault is recorded.  If a handler's own store is what aborts,
 * the abort vector re-enters and would otherwise overwrite the original fault
 * with a description of the loop — leaving no trace of what actually went
 * wrong.  DFSR/DFAR come along because for an ASYNCHRONOUS external abort the
 * banked LR points at an unrelated instruction, and then the recorded PC is a
 * red herring; DFSR is what says so. */
    .macro  CPU1_FAULT name, kind, lroff
    .type   \name, %function
\name:
    ldr     r0, =CPU1_MBOX_ADDR
    ldr     r1, [r0, #CPU1_MB_FAULT_KIND]
    cmp     r1, #0
    bne     2f                          /* already have one — keep it */
    mov     r1, #\kind
    str     r1, [r0, #CPU1_MB_FAULT_KIND]
    sub     r1, lr, #\lroff             /* back out the pipeline offset */
    str     r1, [r0, #CPU1_MB_FAULT_PC]
    mrs     r1, spsr
    str     r1, [r0, #CPU1_MB_FAULT_SPSR]
    mrc     p15, 0, r1, c5, c0, 0       /* DFSR */
    str     r1, [r0, #CPU1_MB_FAULT_DFSR]
    mrc     p15, 0, r1, c6, c0, 0       /* DFAR */
    str     r1, [r0, #CPU1_MB_FAULT_DFAR]
2:  dsb
1:  wfi
    b       1b
    .endm

    CPU1_FAULT cpu1_f_rst,  CPU1_FAULT_RST,  0
    CPU1_FAULT cpu1_f_und,  CPU1_FAULT_UND,  4
    CPU1_FAULT cpu1_f_svc,  CPU1_FAULT_SVC,  4
    CPU1_FAULT cpu1_f_pabt, CPU1_FAULT_PABT, 4
    CPU1_FAULT cpu1_f_dabt, CPU1_FAULT_DABT, 8
    CPU1_FAULT cpu1_f_rsvd, CPU1_FAULT_RSVD, 4
    CPU1_FAULT cpu1_f_irq,  CPU1_FAULT_IRQ,  4
    CPU1_FAULT cpu1_f_fiq,  CPU1_FAULT_FIQ,  4

    .align  5                           /* VBAR needs 32-byte alignment */
    .global cpu1_vectors
cpu1_vectors:
    b       cpu1_f_rst
    b       cpu1_f_und
    b       cpu1_f_svc
    b       cpu1_f_pabt
    b       cpu1_f_dabt
    b       cpu1_f_rsvd
    b       cpu1_f_irq
    b       cpu1_f_fiq
