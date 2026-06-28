/*
 * fault.c — T2-a memory-protection faults on real hardware.
 *
 * The board's MMU is the FSBL/BSP translation table (DDR + peripherals mapped,
 * everything else a translation fault), so a wild pointer into unmapped space
 * already aborts — we just need to *catch it precisely* instead of the BSP's
 * default spin. Register data/prefetch-abort handlers (the same Xil exception
 * API xtos already uses for IRQ) that read the CP15 fault registers + the
 * faulting task, so an abort on the real board is diagnosable over UART — the
 * hardware counterpart of the qemu T2-a fault_report.
 *
 * (Surviving the fault — killing just the task — needs replacing the BSP's abort
 * vector with our own entry asm, like the qemu xt_vectors.S; deferred. For now a
 * caught fault reports precisely and halts; power-cycle to recover.)
 */
#include <stdint.h>
#include <stdio.h>
#include "xil_exception.h"
#include "xil_mmu.h"
#include "FreeRTOS.h"
#include "task.h"

/* Zynq's FSBL/BSP translation table maps the whole 4 GB (DDR + PL + device +
 * reserved), so there are no unmapped holes — a wild pointer doesn't fault by
 * default. To get protection we must actively mark a section no-access. This
 * carves one test section in the unused PL M_AXI_GP1 window; the full T2-a map
 * (null-trap + W^X over the real regions) is the follow-on, same mechanism. */
#define FAULT_TEST_ADDR 0x60000000u

static void abort_handler(void *ref)
{
    const char *kind = (const char *)ref;
    uint32_t dfar, dfsr, ifsr;
    __asm__ volatile("mrc p15,0,%0,c6,c0,0" : "=r"(dfar));     /* data fault address */
    __asm__ volatile("mrc p15,0,%0,c5,c0,0" : "=r"(dfsr));     /* data fault status  */
    __asm__ volatile("mrc p15,0,%0,c5,c0,1" : "=r"(ifsr));     /* instr fault status */
    char *tn = pcTaskGetName(NULL);
    printf("\r\n*** %s in task '%s'\r\n", kind, tn ? tn : "?");
    printf("    DFAR=0x%08lx  DFSR=0x%08lx  IFSR=0x%08lx\r\n",
           (unsigned long)dfar, (unsigned long)dfsr, (unsigned long)ifsr);
    printf("*** protection fault caught (T2-a on HW) — halted; power-cycle to recover ***\r\n");
    for (;;) {}
}

void xtos_fault_handlers_init(void)
{
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_DATA_ABORT_INT,     abort_handler, (void *)"DATA-ABORT");
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_PREFETCH_ABORT_INT, abort_handler, (void *)"PREFETCH-ABORT");
    /* invalid descriptor (bits[1:0]=00) -> translation fault on access */
    Xil_SetTlbAttributes(FAULT_TEST_ADDR, 0x0u);
}
