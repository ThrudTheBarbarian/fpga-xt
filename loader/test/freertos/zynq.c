/*
 * zynq.c — our functionally-identical replacement for the Xilinx BSP glue
 * (portZynq7000.c): GIC init, the Cortex-A9 private-timer tick, and the IRQ
 * router the FreeRTOS port calls (vApplicationIRQHandler). Standard Zynq/A9
 * MPCore peripherals, all modelled by qemu's xilinx-zynq-a9.
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"

#define REG(a) (*(volatile uint32_t *)(a))

/* GIC (Cortex-A9 MPCore) */
#define GICD_BASE   0xF8F01000UL          /* distributor    */
#define GICC_BASE   0xF8F00100UL          /* cpu interface  */
#define GICD_CTLR   (GICD_BASE + 0x000)
#define GICD_ISENABLER(n) (GICD_BASE + 0x100 + 4 * (n))
#define GICD_IPRIORITYR(n) (GICD_BASE + 0x400 + (n))   /* byte per id */
#define GICC_CTLR   (GICC_BASE + 0x000)
#define GICC_PMR    (GICC_BASE + 0x004)
#define GICC_BPR    (GICC_BASE + 0x008)

/* Cortex-A9 private timer (per-CPU), interrupt id 29 (PPI) */
#define PTIMER_BASE 0xF8F00600UL
#define PT_LOAD     (PTIMER_BASE + 0x00)
#define PT_COUNTER  (PTIMER_BASE + 0x04)
#define PT_CONTROL  (PTIMER_BASE + 0x08)
#define PT_ISR      (PTIMER_BASE + 0x0C)
#define PT_IRQ_ID   29

void gic_init(void)
{
    REG(GICC_CTLR) = 0;                    /* disable while configuring */
    REG(GICD_CTLR) = 0;
    REG(GICC_PMR)  = 0xF0;                 /* allow all priorities through */
    REG(GICC_BPR)  = 0x0;                  /* lowest binary point (FreeRTOS requires full preemption) */
    REG(GICD_CTLR) = 0x1;                  /* enable distributor */
    REG(GICC_CTLR) = 0x1;                  /* enable cpu interface */
}

/* configSETUP_TICK_INTERRUPT() — program the private timer + enable its IRQ */
void vConfigureTickInterrupt(void)
{
    uint32_t periphclk = configCPU_CLOCK_HZ / 2;       /* A9 periph = CPU/2 */
    uint32_t load = (periphclk / configTICK_RATE_HZ) - 1;

    /* priority for id 29 (IPRIORITYR is byte-addressable — must be a byte store),
     * and enable it in the distributor */
    *(volatile uint8_t *)GICD_IPRIORITYR(PT_IRQ_ID) = 0xA0;
    REG(GICD_ISENABLER(PT_IRQ_ID / 32)) = (1u << (PT_IRQ_ID % 32));

    REG(PT_LOAD)    = load;
    REG(PT_ISR)     = 1;                   /* clear any pending event */
    REG(PT_CONTROL) = 0x7;                 /* enable | auto-reload | irq-enable */
}

/* configCLEAR_TICK_INTERRUPT() */
void vClearTickInterrupt(void)
{
    REG(PT_ISR) = 1;                       /* write-1-to-clear the event flag */
}

/* Called by FreeRTOS_IRQ_Handler (portASM.S) with the acked interrupt id. */
void vApplicationIRQHandler(uint32_t ulICCIAR)
{
    uint32_t id = ulICCIAR & 0x3FF;
    if (id == PT_IRQ_ID)
        FreeRTOS_Tick_Handler();
}

static void fr_hex(const char *label, unsigned v)
{
    extern void puts0(const char *);
    char hex[11] = "0x00000000";
    for (int i = 0; i < 8; i++) { unsigned d = (v >> ((7 - i) * 4)) & 0xF; hex[2 + i] = (char)(d < 10 ? '0' + d : 'a' + d - 10); }
    puts0(label); puts0(hex);
}

/* called from the exception vectors (xt_vectors.S) to localize a fault.
 * T2-a: read the CP15 fault registers + the faulting task so a protection abort
 * (NULL/wild pointer, W^X violation) is precisely diagnosable rather than a
 * silent corruption or an anonymous hang. */
void fault_report(unsigned code, unsigned addr)
{
    extern void puts0(const char *);
    unsigned dfar, dfsr, ifsr;
    __asm__ volatile("mrc p15,0,%0,c6,c0,0" : "=r"(dfar));      /* data fault address */
    __asm__ volatile("mrc p15,0,%0,c5,c0,0" : "=r"(dfsr));      /* data fault status  */
    __asm__ volatile("mrc p15,0,%0,c5,c0,1" : "=r"(ifsr));      /* instr fault status */
    static const char *const names[8] =
        { "reset", "UNDEF", "svc", "PREFETCH-ABORT", "DATA-ABORT", "resv", "irq", "FIQ" };
    char *tn = pcTaskGetName(0);
    puts0("\n*** "); puts0(code < 8 ? names[code] : "?");
    puts0(" in task '"); puts0(tn ? tn : "?"); puts0("'\n");
    fr_hex("    PC=", addr);
    fr_hex("  DFAR=", dfar); fr_hex("  DFSR=", dfsr); fr_hex("  IFSR=", ifsr);
    { extern int stackguard_is_guard(unsigned);
      if (code == 4 && stackguard_is_guard(dfar)) puts0("\n*** STACK OVERFLOW (hit guard page)"); }
    puts0("\n*** killing the faulting task; OS continues (T2-a) ***\n");
    /* returns to xt_vectors.S, which redirects the task into xtos_task_fault_exit */
}

void vAssertCalled(const char *file, int line)
{
    extern void puts0(const char *); extern void putu(unsigned);
    (void)file;
    puts0("ASSERT at line "); putu((unsigned)line); puts0("\n");
    taskDISABLE_INTERRUPTS();
    for (;;) {}
}
