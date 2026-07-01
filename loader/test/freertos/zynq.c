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

/* Cortex-A9 GLOBAL timer (64-bit, shared by both cores, free-running at
 * PERIPHCLK = CPU/2). Separate from the private timer above (which is the
 * FreeRTOS tick). This is our wall clock for gettimeofday — monotonic, ~µs
 * resolution, epoch = boot (the board has no RTC). */
#define GTIMER_BASE 0xF8F00200UL
#define GT_LO   (GTIMER_BASE + 0x00)
#define GT_HI   (GTIMER_BASE + 0x04)
#define GT_CTRL (GTIMER_BASE + 0x08)

void gtimer_init(void)
{
    REG(GT_CTRL) = 0;                      /* disable so the counter can be zeroed */
    REG(GT_LO)   = 0;
    REG(GT_HI)   = 0;
    REG(GT_CTRL) = 1;                      /* enable, prescaler 0 -> ticks at PERIPHCLK */
}

/* fill tv_sec / tv_usec (since boot). Read the 64-bit counter atomically by
 * re-reading the high word to catch a low-word rollover between the two reads. */
void gtimer_timeofday(uint32_t *sec, uint32_t *usec)
{
    uint32_t hi, lo;
    do { hi = REG(GT_HI); lo = REG(GT_LO); } while (hi != REG(GT_HI));
    uint64_t t = ((uint64_t)hi << 32) | lo;
    uint64_t f = (uint64_t)(configCPU_CLOCK_HZ / 2);   /* PERIPHCLK Hz */
    *sec  = (uint32_t)(t / f);
    *usec = (uint32_t)(((t % f) * 1000000ULL) / f);
}

/* Called by FreeRTOS_IRQ_Handler (portASM.S) with the acked interrupt id. */
void vApplicationIRQHandler(uint32_t ulICCIAR)
{
    uint32_t id = ulICCIAR & 0x3FF;
    if (id == PT_IRQ_ID)
        FreeRTOS_Tick_Handler();
#ifdef XT_HW_UART
    else if (id == 82) { extern void uart1_rx_isr(void); uart1_rx_isr(); }   /* UART1 receive */
#endif
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
void fault_report(unsigned code, unsigned addr, unsigned caller)
{
    extern void puts0(const char *);
    unsigned dfar, dfsr, ifsr;
    __asm__ volatile("mrc p15,0,%0,c6,c0,0" : "=r"(dfar));      /* data fault address */
    __asm__ volatile("mrc p15,0,%0,c5,c0,0" : "=r"(dfsr));      /* data fault status  */
    __asm__ volatile("mrc p15,0,%0,c5,c0,1" : "=r"(ifsr));      /* instr fault status */
    static const char *const names[8] =
        { "reset", "UNDEF", "svc", "PREFETCH-ABORT", "DATA-ABORT", "resv", "irq", "FIQ" };
    /* pcTaskGetName asserts if no task is running (a fault during boot) — guard it */
    char *tn = xTaskGetCurrentTaskHandle() ? pcTaskGetName(0) : 0;
    puts0("\n*** "); puts0(code < 8 ? names[code] : "?");
    puts0(" in task '"); puts0(tn ? tn : "<boot/none>"); puts0("'\n");
    fr_hex("    PC=", addr); fr_hex("  CALLER=", caller);
    fr_hex("  DFAR=", dfar); fr_hex("  DFSR=", dfsr); fr_hex("  IFSR=", ifsr);
    { extern int stackguard_is_guard(unsigned);
      if (code == 4 && stackguard_is_guard(dfar)) puts0("\n*** STACK OVERFLOW (hit guard page)"); }
    /* DIAG: walk the LIVE tables (current TTBR0) for the faulting address — shows
     * whether the MMU sees the section as split (coarse L2) or a plain SEC_KDATA
     * section, and the page's permission bits. */
    { unsigned va = (code == 3) ? addr : dfar;              /* prefetch: PC; data: DFAR */
      unsigned ttbr; __asm__ volatile("mrc p15,0,%0,c2,c0,0" : "=r"(ttbr));
      unsigned *l1 = (unsigned *)(ttbr & 0xFFFFC000u);
      unsigned l1e = l1[va >> 20];
      fr_hex("\n    TTBR0=", ttbr); fr_hex("  L1[sec]=", l1e);
      if ((l1e & 3u) == 1u) { unsigned *l2 = (unsigned *)(l1e & 0xFFFFFC00u);
                              fr_hex("  L2[pg]=", l2[(va >> 12) & 0xFFu]); } }
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
