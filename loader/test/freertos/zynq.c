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

/* stack-overflow hook (configCHECK_FOR_STACK_OVERFLOW=2): name the task LOUDLY —
 * a silent overflow shows up as nondeterministic early wedges (HW-learned). */
void vApplicationStackOverflowHook(TaskHandle_t task, char *name)
{
    (void)task;
    extern void puts0(const char *);
    puts0("\n*** STACK OVERFLOW in task '");
    puts0(name ? name : "?");
    puts0("' ***\n");
    for (;;) { }
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
    else if (id == 54) { extern void gem0_isr(void); gem0_isr(); }           /* GEM0 (net RX) */
    else if (id == 62) { extern void mathcop_isr(void); mathcop_isr(); }     /* math-cop doorbell (IRQ_F2P[1]) */
}

/* ---- A9 performance monitors (PMUv2) --------------------------------------
 *
 * The question this exists to answer: the software Atari runs ~12,900 A9 cycles
 * per emulated 6502 cycle against the Mac's ~384, and clock x IPC does not come
 * close to explaining the gap. Two very different causes look identical from
 * outside — the core could be STALLED (memory-bound, so the per-cycle design's
 * ~180 touches per emulated cycle is the problem) or it could be RETIRING far
 * more instructions than the same C does elsewhere (a codegen problem). Cycles
 * and instructions-retired separate them outright, and guessing between them
 * would send the next month of work in the wrong direction.
 *
 * PMUSERENR.EN is set so PL0 can read the counters directly: the measurement
 * belongs around the emulator's inner loop, in the program, not behind a
 * syscall whose own cost would land inside the window being measured.
 *
 * NOTE the counters are 32-bit and PMCCNTR wraps in ~6.4 s at 667 MHz, so a
 * reader must accumulate and reset rather than take one reading across a
 * 53-second run. */
/* 0x08 (INST_RETIRED) reads ZERO on this A9 -- it is optional in ARMv7 and this
 * part does not implement it. 0x68 is the A9's own "instructions coming out of
 * the rename stage", which is the usable instruction count here.
 *
 * The A9 has SIX event counters, so take all of them in one run: with IPC at
 * 0.19 and the D-cache missing only 0.1%, the remaining suspects are the
 * INSTRUCTION side (a per-cycle design runs CPU+ANTIC+GTIA+POKEY every cycle,
 * which is a lot of code through a 32 KB L1I) and BRANCHES (interpreter dispatch
 * is an indirect branch the A9 predicts poorly). Measuring both at once avoids
 * another build-load cycle per hypothesis. */
#define PMU_EVT_INST         0x68u   /* instructions renamed          */
#define PMU_EVT_L1D_REFILL   0x03u   /* data cache refill             */
#define PMU_EVT_L1D_ACCESS   0x04u   /* data cache access             */
#define PMU_EVT_L1I_REFILL   0x01u   /* INSTRUCTION cache refill      */
#define PMU_EVT_BR_MISS      0x10u   /* branch mispredicted           */
#define PMU_EVT_BR_EXEC      0x12u   /* predictable branches executed */

static void pmu_set_event(uint32_t ctr, uint32_t ev)
{
    __asm__ volatile("mcr p15,0,%0,c9,c12,5" :: "r"(ctr));   /* PMSELR */
    __asm__ volatile("isb");
    __asm__ volatile("mcr p15,0,%0,c9,c13,1" :: "r"(ev));    /* PMXEVTYPER */
    __asm__ volatile("isb");
}

/* Report the ACTUAL CPU clock from the PLL, because everything timed on this
 * board is scaled by it: gtimer_timeofday() divides the global-timer count by
 * configCPU_CLOCK_HZ/2, so if that constant is wrong every measured duration is
 * wrong by the same ratio -- silently, and in a way no amount of repeating the
 * measurement reveals. The Zynq-7020 -2 part on this carrier is rated well above
 * the 666.67 MHz the config assumes.
 *
 *   CPU_6x4x = PS_CLK * ARM_PLL_FDIV / ARM_CLK_DIVISOR
 *
 * PS_CLK is the board crystal (33.333 MHz on this carrier). */
uint32_t cpu_hz_actual(void)
{
    uint32_t pll  = REG(0xF8000100u);         /* ARM_PLL_CTRL */
    uint32_t ctl  = REG(0xF8000120u);         /* ARM_CLK_CTRL */
    uint32_t fdiv = (pll >> 12) & 0x7Fu;
    uint32_t div  = (ctl >> 8)  & 0x3Fu;
    return div ? (uint32_t)((33333333ull * fdiv) / div) : 0u;
}

/* What the config CLAIMS, for callers that want to show both. */
uint32_t cpu_hz_configured(void) { return (uint32_t)configCPU_CLOCK_HZ; }

void clk_report(void)
{
    uint32_t pll  = REG(0xF8000100u);
    uint32_t ctl  = REG(0xF8000120u);
    extern void klog(const char *) __attribute__((weak));
    extern void klog_u(unsigned) __attribute__((weak));
    if (klog && klog_u) {
        klog("[clk] ARM_PLL fdiv="); klog_u((pll >> 12) & 0x7Fu);
        klog(" div=");               klog_u((ctl >> 8)  & 0x3Fu);
        klog(" cpu_hz=");            klog_u(cpu_hz_actual());
        klog(" configCPU_CLOCK_HZ="); klog_u(configCPU_CLOCK_HZ);
        klog("\n");
    }
}

void pmu_init(void)
{
    uint32_t v;
    __asm__ volatile("mrc p15,0,%0,c9,c12,0" : "=r"(v));     /* PMCR */
    v |=  (1u << 0) | (1u << 1) | (1u << 2);                 /* E | reset events | reset cycles */
    v &= ~(1u << 3);                                         /* D=0: count every cycle, not /64 */
    __asm__ volatile("mcr p15,0,%0,c9,c12,0" :: "r"(v));
    pmu_set_event(0, PMU_EVT_INST);
    pmu_set_event(1, PMU_EVT_L1D_REFILL);
    pmu_set_event(2, PMU_EVT_L1D_ACCESS);
    pmu_set_event(3, PMU_EVT_L1I_REFILL);
    pmu_set_event(4, PMU_EVT_BR_MISS);
    pmu_set_event(5, PMU_EVT_BR_EXEC);
    /* enable cycle counter (bit 31) + counters 0..5 */
    __asm__ volatile("mcr p15,0,%0,c9,c12,1" :: "r"(0x8000003Fu));  /* PMCNTENSET */
    __asm__ volatile("mcr p15,0,%0,c9,c14,0" :: "r"(1u));           /* PMUSERENR: PL0 may read */
    __asm__ volatile("isb");
}

/* Fault output goes to the console AND the kernel log. Console-only was a
 * half-instrument: the person at the screen can read a crash dump but nobody
 * over the network can, so `dmesg` showed a task had vanished with no reason
 * why. Mirroring into klog makes a fault diagnosable remotely. */
void fr_puts(const char *s)
{
    extern void puts0(const char *);
    extern void klog(const char *) __attribute__((weak));
    puts0(s);
    if (klog) klog(s);
}

void fr_hex(const char *label, unsigned v)   /* non-static: vm.c's debug probe prints to console too */
{
    char hex[11] = "0x00000000";
    for (int i = 0; i < 8; i++) { unsigned d = (v >> ((7 - i) * 4)) & 0xF; hex[2 + i] = (char)(d < 10 ? '0' + d : 'a' + d - 10); }
    fr_puts(label); fr_puts(hex);
}

/* called from the exception vectors (xt_vectors.S) to localize a fault.
 * T2-a: read the CP15 fault registers + the faulting task so a protection abort
 * (NULL/wild pointer, W^X violation) is precisely diagnosable rather than a
 * silent corruption or an anonymous hang. */
void fault_report(unsigned code, unsigned addr, unsigned caller)
{
    extern void puts0(const char *);
    /* A fault STORM (e.g. a corrupted server respawning + re-faulting) must not wedge
     * the console — the task still gets killed (xt_vectors.S), we just stop printing
     * after a cap so the board stays usable for diagnosis. */
    /* RE-ENTRANCY GUARD. If anything below faults -- and fault_symbolize once did,
     * walking the loader's object registry -- the abort re-enters here and the
     * two recurse until the scheduler asserts. One report at a time; a fault
     * raised while reporting is dropped rather than allowed to eat the system. */
    static volatile int g_in_fault;
    if (g_in_fault) return;
    g_in_fault = 1;

    static unsigned g_faultn;
    if (++g_faultn > 24u) {
        g_in_fault = 0;
        if (g_faultn == 25u) fr_puts("\n*** fault storm: suppressing further reports (tasks still killed) ***\n");
        return;
    }
    unsigned dfar, dfsr, ifsr;
    __asm__ volatile("mrc p15,0,%0,c6,c0,0" : "=r"(dfar));      /* data fault address */
    __asm__ volatile("mrc p15,0,%0,c5,c0,0" : "=r"(dfsr));      /* data fault status  */
    __asm__ volatile("mrc p15,0,%0,c5,c0,1" : "=r"(ifsr));      /* instr fault status */
    static const char *const names[8] =
        { "reset", "UNDEF", "svc", "PREFETCH-ABORT", "DATA-ABORT", "resv", "irq", "FIQ" };
    /* pcTaskGetName asserts if no task is running (a fault during boot) — guard it */
    char *tn = xTaskGetCurrentTaskHandle() ? pcTaskGetName(0) : 0;
    fr_puts("\n*** "); fr_puts(code < 8 ? names[code] : "?");
    fr_puts(" in task '"); fr_puts(tn ? tn : "<boot/none>"); fr_puts("'\n");
    fr_hex("    PC=", addr); fr_hex("  CALLER=", caller);
    /* map PC + CALLER to <object>+offset so the crash names a function offline */
    { extern void fault_symbolize(unsigned, void (*)(const char *, unsigned));
      fault_symbolize(addr, fr_hex); fr_puts("]");
      fault_symbolize(caller, fr_hex); fr_puts("]"); }
    fr_hex("  DFAR=", dfar); fr_hex("  DFSR=", dfsr); fr_hex("  IFSR=", ifsr);
    { extern int stackguard_is_guard(unsigned);
      if (code == 4 && stackguard_is_guard(dfar)) fr_puts("\n*** STACK OVERFLOW (hit guard page)"); }
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
    fr_puts("\n*** killing the faulting task; OS continues (T2-a) ***\n");
    g_in_fault = 0;
    /* returns to xt_vectors.S, which redirects the task into xtos_task_fault_exit */
}

void vAssertCalled(const char *file, int line)
{
    extern void puts0(const char *); extern void putu(unsigned);
    puts0("ASSERT at "); puts0(file ? file : "?"); puts0(":"); putu((unsigned)line); puts0("\n");
    taskDISABLE_INTERRUPTS();
    for (;;) {}
}
