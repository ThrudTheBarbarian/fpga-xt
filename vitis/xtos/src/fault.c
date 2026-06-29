/*
 * fault.c — T2-a memory protection + fault RECOVERY on real hardware.
 *
 * The BSP's Xil_ExceptionRegisterHandler hands a C handler only a void* (no saved
 * register frame / return PC), so it can't kill-and-resume. So we install our own
 * exception vector table via VBAR — same shape as the qemu xt_vectors.S — that
 * keeps SVC/IRQ chaining to the FreeRTOS port handlers, but routes data/prefetch
 * aborts to report + redirect the faulting task into xtos_hw_task_die (running in
 * the task's own mode via `movs pc`, which restores SPSR_abt). The task deletes
 * itself and the scheduler keeps the rest of the OS running.
 *
 * Zynq's FSBL/BSP table maps all 4 GB, so a wild pointer doesn't fault by
 * default — Xil_SetTlbAttributes carves a no-access test section to exercise it.
 */
#include <stdint.h>
#include <stdio.h>
#include "xil_mmu.h"
#include "FreeRTOS.h"
#include "task.h"

#define FAULT_TEST_ADDR 0x60000000u          /* unused PL GP1 section, carved no-access */

/* Our exception vector table + abort handlers. SVC/IRQ load the FreeRTOS port
 * handlers (unchanged scheduler/ticks); data/prefetch aborts report then return
 * INTO the faulting task to delete itself. movw/movt avoid a literal pool. */
__asm__(
    ".section .text\n"
    ".balign 32\n"
    ".global xt_hw_vector_table\n"
    "xt_hw_vector_table:\n"
    "    b    .\n"                          /* reset (unused at runtime) */
    "    b    xt_hw_undef\n"                /* undefined instruction     */
    "    ldr  pc, _hw_svc\n"               /* svc  -> FreeRTOS          */
    "    b    xt_hw_pabt\n"                /* prefetch abort            */
    "    b    xt_hw_dabt\n"                /* data abort                */
    "    nop\n"                            /* reserved                  */
    "    ldr  pc, _hw_irq\n"              /* irq  -> FreeRTOS          */
    "    b    .\n"                          /* fiq                       */
    "_hw_svc: .word FreeRTOS_SWI_Handler\n"
    "_hw_irq: .word FreeRTOS_IRQ_Handler\n"
    "xt_hw_undef: mov r0, #1\n  mov r1, lr\n      b xt_hw_fault\n"
    "xt_hw_pabt:  mov r0, #3\n  sub r1, lr, #4\n  b xt_hw_fault\n"
    "xt_hw_dabt:  mov r0, #4\n  sub r1, lr, #8\n  b xt_hw_fault\n"
    "xt_hw_fault: bl  fault_report_hw\n"
    "    movw lr, #:lower16:xtos_hw_task_die\n"
    "    movt lr, #:upper16:xtos_hw_task_die\n"
    "    movs pc, lr\n"
    ".global xt_hw_install_vectors\n"
    "xt_hw_install_vectors:\n"
    "    movw r0, #:lower16:xt_hw_vector_table\n"
    "    movt r0, #:upper16:xt_hw_vector_table\n"
    "    mcr  p15, 0, r0, c12, c0, 0\n"    /* VBAR = our table */
    "    isb\n"
    "    bx   lr\n"
);
extern void xt_hw_install_vectors(void);

/* The task currently being killed + how many times its kill path has re-faulted,
 * so the recovery is bounded — a kill that itself faults must never loop forever. */
static TaskHandle_t g_dying = NULL;
static int          g_die_depth = 0;

/* called from xt_hw_fault (r0=exception code, r1=faulting PC) */
void fault_report_hw(unsigned code, unsigned addr)
{
    /* Re-fault from inside the kill path for the SAME task: don't re-spam the
     * report — xtos_hw_reap (below) bounds the actual recovery. */
    if (g_dying && xTaskGetCurrentTaskHandle() == g_dying) return;
    static const char *const names[8] =
        { "reset", "UNDEF", "svc", "PREFETCH-ABORT", "DATA-ABORT", "resv", "irq", "FIQ" };
    uint32_t dfar, dfsr, ifsr;
    __asm__ volatile("mrc p15,0,%0,c6,c0,0" : "=r"(dfar));
    __asm__ volatile("mrc p15,0,%0,c5,c0,0" : "=r"(dfsr));
    __asm__ volatile("mrc p15,0,%0,c5,c0,1" : "=r"(ifsr));
    char *tn = pcTaskGetName(NULL);
    printf("\r\n*** %s in task '%s'\r\n", code < 8 ? names[code] : "?", tn ? tn : "?");
    printf("    PC=0x%08x  DFAR=0x%08lx  DFSR=0x%08lx  IFSR=0x%08lx\r\n",
           addr, (unsigned long)dfar, (unsigned long)dfsr, (unsigned long)ifsr);
    printf("*** killing the faulting task; OS continues (T2-a HW) ***\r\n");
}

/* Dedicated kill stack: the faulting task's own SP may be corrupt (a stack
 * overflow is a common fault cause), which is exactly why the kill path used to
 * re-fault and loop.  `used` so it survives even though only asm references it. */
static uint8_t xt_die_stack[4096] __attribute__((aligned(8), used));

/* xtos_hw_task_die — entered (via `movs pc`) in the faulting task's own mode.
 * Switch to the dedicated stack FIRST (before any push, so a bad task SP can't
 * fault the kill), then run the C reaper. */
__asm__(
    "    .global xtos_hw_task_die\n"
    "xtos_hw_task_die:\n"
    "    movw sp, #:lower16:(xt_die_stack + 4096)\n"
    "    movt sp, #:upper16:(xt_die_stack + 4096)\n"
    "    b    xtos_hw_reap\n"
);

/* Bounded recovery (called from xtos_hw_task_die on the dedicated stack):
 *   1st fault for a task -> delete it cleanly (OS continues);
 *   its kill path re-faults -> park it (suspend) so the OS still continues;
 *   even that re-faults -> stop, rather than spin reporting forever.
 * g_dying tracks the task so a NEW task's fault restarts the count instead of
 * being mistaken for a re-fault. */
void xtos_hw_reap(void)
{
    TaskHandle_t cur = xTaskGetCurrentTaskHandle();
    if (cur != g_dying) { g_dying = cur; g_die_depth = 0; }   /* fresh fault */
    g_die_depth++;

    if (g_die_depth >= 3) {                                   /* kill keeps faulting */
        printf("*** kill path unrecoverable (x%d) — stopping to avoid a fault loop ***\r\n",
               g_die_depth);
        portDISABLE_INTERRUPTS();
        for (;;) {}
    }
    if (g_die_depth == 1) {
        vTaskDelete(NULL);                                   /* normal: clean delete + yield */
    } else {
        printf("*** kill path re-faulted — parking the task; OS continues ***\r\n");
        if (cur) vTaskSuspend(cur);                          /* self-suspend -> yields away */
    }
    for (;;) {}
}

void xtos_fault_handlers_init(void)
{
    xt_hw_install_vectors();                       /* our VBAR table (abort -> kill) */
    Xil_SetTlbAttributes(FAULT_TEST_ADDR, 0x0u);   /* invalid descriptor -> fault on access */
}

/* a throwaway task that derefs the no-access section, to prove a faulting task
 * is killed while the OS (REPL) keeps running. */
static void fault_task(void *arg)
{
    (void)arg;
    printf("[flt] task writing to no-access 0x%08x ...\r\n", FAULT_TEST_ADDR);
    *(volatile unsigned *)FAULT_TEST_ADDR = 0xdeadu;
    printf("[flt] SURVIVED (no fault?!)\r\n");
    vTaskDelete(NULL);
}
void xtos_fault_spawn(void) { xTaskCreate(fault_task, "flt", 1024, NULL, tskIDLE_PRIORITY + 1, NULL); }
