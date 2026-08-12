/* fault.c — turn a hard fault into something you can read.
 *
 * The report is written to a .noinit buffer that survives a warm reset, then
 * printed to the console.  If nothing is listening (no probe, Zynq not up) the
 * next boot still finds it: `fault` in the REPL prints the saved record.
 */
#include "fault.h"

#include <stdint.h>

#include "console.h"
#include "stm32f411.h"

#define FAULT_MAGIC 0x464C5431UL            /* "FLT1" */

struct fault_record {
    uint32_t magic;
    uint32_t cfsr, hfsr, mmfar, bfar;
    uint32_t r0, r1, r2, r3, r12, lr, pc, psr;
    uint32_t exc_return;
};

__attribute__((section(".noinit")))
static struct fault_record s_fault;

/* The naked trampoline hands the C body a pointer to the stack frame the core
 * pushed — which lives on MSP or PSP depending on EXC_RETURN bit 2.
 */
__attribute__((naked)) void fault_handler(void)
{
    __asm__ volatile (
        "tst   lr, #4          \n"
        "ite   eq              \n"
        "mrseq r0, msp         \n"
        "mrsne r0, psp         \n"
        "mov   r1, lr          \n"
        "b     fault_report    \n"
    );
}

/* Park in a plain spin — no BKPT, no WFI.
 *
 * BKPT is the tempting choice, but it is wrong in both debugger states: with
 * C_DEBUGEN clear it escalates to a HardFault (an infinite fault loop, each
 * pass clobbering the saved record), and with a debugger enabled but detached
 * it wedges the debug port hard enough that the probe can no longer scan the
 * target — recovering needs a connect-under-reset.  WFI is no better: it gates
 * the debug clocks unless DBGMCU_CR allows it.
 *
 * A spinning core stays scannable and haltable, which is exactly what you want
 * to find after something has gone wrong.
 */
__attribute__((noreturn)) static void park(void)
{
    for (;;)
        __asm__ volatile ("nop" ::: "memory");
}

__attribute__((used, noreturn))
void fault_report(uint32_t *frame, uint32_t exc_return)
{
    /* A fault raised while reporting a fault must not overwrite the record —
     * the first one is the one worth keeping. */
    static int s_reporting;

    if (s_reporting)
        park();
    s_reporting = 1;

    s_fault.magic      = FAULT_MAGIC;
    s_fault.cfsr       = SCB->CFSR;
    s_fault.hfsr       = SCB->HFSR;
    s_fault.mmfar      = SCB->MMFAR;
    s_fault.bfar       = SCB->BFAR;
    s_fault.r0         = frame[0];
    s_fault.r1         = frame[1];
    s_fault.r2         = frame[2];
    s_fault.r3         = frame[3];
    s_fault.r12        = frame[4];
    s_fault.lr         = frame[5];
    s_fault.pc         = frame[6];
    s_fault.psr        = frame[7];
    s_fault.exc_return = exc_return;

    console_puts("\r\n\r\n*** FAULT ***\r\n");
    fault_dump();
    park();
}

int fault_pending(void)
{
    return s_fault.magic == FAULT_MAGIC;
}

void fault_dump(void)
{
    if (!fault_pending()) {
        console_puts("no fault recorded\r\n");
        return;
    }

    console_printf("  pc   %08lx   lr   %08lx   psr  %08lx\r\n",
                   s_fault.pc, s_fault.lr, s_fault.psr);
    console_printf("  r0   %08lx   r1   %08lx   r2   %08lx   r3 %08lx\r\n",
                   s_fault.r0, s_fault.r1, s_fault.r2, s_fault.r3);
    console_printf("  r12  %08lx   exc  %08lx\r\n",
                   s_fault.r12, s_fault.exc_return);
    console_printf("  cfsr %08lx   hfsr %08lx\r\n", s_fault.cfsr, s_fault.hfsr);

    if (s_fault.cfsr & (1UL << 7))
        console_printf("  memmanage address %08lx\r\n", s_fault.mmfar);
    if (s_fault.cfsr & (1UL << 15))
        console_printf("  bus fault address %08lx\r\n", s_fault.bfar);
    if (s_fault.hfsr & (1UL << 30))
        console_puts("  escalated from a configurable fault\r\n");
    if (s_fault.cfsr & (1UL << 16))
        console_puts("  undefined instruction\r\n");
    if (s_fault.cfsr & (1UL << 24))
        console_puts("  unaligned access\r\n");
}

void fault_clear(void)
{
    s_fault.magic = 0;
}

/* Enable the configurable faults so bus/usage errors report precisely instead
 * of escalating to an anonymous hard fault. */
void fault_init(void)
{
    SCB->SHCSR |= (1UL << 16) | (1UL << 17) | (1UL << 18);
    SCB->CCR   |= (1UL << 4);               /* DIV_0_TRP */
}
