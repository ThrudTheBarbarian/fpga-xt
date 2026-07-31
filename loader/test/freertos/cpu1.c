/*
 * cpu1.c — CPU0's side of the AMP link: release CPU1 and talk to it.
 *
 * See cpu1.h for the mechanism (BootROM pen at 0xFFFF_FFF0) and the memory
 * rules.  Everything here runs on CPU0; the code CPU1 executes is in
 * cpu1_core.c and cpu1_boot.S.
 */
#include <stddef.h>
#include <string.h>
#include "FreeRTOS.h"
#include "frtos_os.h"
#include "cpu1.h"

/* the offsets cpu1_boot.S hard-codes must agree with the struct */
_Static_assert(offsetof(cpu1_mbox, magic)      == CPU1_MB_MAGIC,      "mbox layout");
_Static_assert(offsetof(cpu1_mbox, heartbeat)  == CPU1_MB_HEARTBEAT,  "mbox layout");
_Static_assert(offsetof(cpu1_mbox, mpidr)      == CPU1_MB_MPIDR,      "mbox layout");
_Static_assert(offsetof(cpu1_mbox, cmd)        == CPU1_MB_CMD,        "mbox layout");
_Static_assert(offsetof(cpu1_mbox, seq)        == CPU1_MB_SEQ,        "mbox layout");
_Static_assert(offsetof(cpu1_mbox, ack)        == CPU1_MB_ACK,        "mbox layout");
_Static_assert(offsetof(cpu1_mbox, arg)        == CPU1_MB_ARG,        "mbox layout");
_Static_assert(offsetof(cpu1_mbox, res)        == CPU1_MB_RES,        "mbox layout");
_Static_assert(offsetof(cpu1_mbox, fault_pc)   == CPU1_MB_FAULT_PC,   "mbox layout");
_Static_assert(offsetof(cpu1_mbox, fault_kind) == CPU1_MB_FAULT_KIND, "mbox layout");
_Static_assert(offsetof(cpu1_mbox, fault_spsr) == CPU1_MB_FAULT_SPSR, "mbox layout");
_Static_assert(offsetof(cpu1_mbox, fault_dfsr) == CPU1_MB_FAULT_DFSR, "mbox layout");
_Static_assert(offsetof(cpu1_mbox, fault_dfar) == CPU1_MB_FAULT_DFAR, "mbox layout");

#define GT_LO         (*(volatile uint32_t *)0xF8F00200)
#define SCU_CTRL       0xF8F00000       /* bit 0 = SCU enable */
#define SCU_INVALIDATE 0xF8F0000C       /* per-CPU tag-RAM ways, 4 bits each */

#define SLCR_LOCK      0xF8000004       /* write 0x767B to re-lock */
#define SLCR_UNLOCK    0xF8000008       /* write 0xDF0D to unlock */
#define A9_CPU_RST_CTRL 0xF8000244
#define A9_RST1        (1u << 1)        /* CPU1 reset */
#define A9_CLKSTOP1    (1u << 5)        /* CPU1 clock stop */
#define PERIPHCLK_HZ  (configCPU_CLOCK_HZ / 2)
#define US_TICKS(us)  ((uint32_t)(((uint64_t)(us) * PERIPHCLK_HZ) / 1000000ULL))

extern void klog(const char *);
extern void klog_u(unsigned);
extern void mmu_poke_phys0(const uint32_t *w, int n);   /* mmu.c */

/* CPU1's reset vector lives at physical 0.  `ldr pc, [pc, #-4]` reads the word
 * that follows it (PC reads as +8, so 8-4 = 4) and jumps there. */
#define TRAMP_JUMP  0xE51FF004u
#define TRAMP_PARK  0xEAFFFFFEu   /* `b .` — a spurious CPU1 start parks harmlessly */

static cpu1_mbox *const mb = (cpu1_mbox *)CPU1_MBOX_ADDR;
static int cpu1_busy;                       /* one outstanding cpu1_call at a time */

/* What the last release attempt actually observed.  Bringing CPU1 up turned
 * into a sequence of plausible-but-wrong theories, so the release records what
 * it saw at each step rather than leaving the next person to infer it. */
static uint32_t dbg_pen_armed;   /* pen read back straight after arming it */
static uint32_t dbg_pen_final;   /* pen read after the reset pulse + wait */
static uint32_t dbg_rst_before;  /* A9_CPU_RST_CTRL before the pulse */
static uint32_t dbg_rst_held;    /* ...with CPU1 held in reset (did the write take?) */
static uint32_t dbg_rst_after;   /* ...after release */

static inline void dsb(void) { __asm__ volatile("dsb" ::: "memory"); }
static inline void sev(void) { __asm__ volatile("sev" ::: "memory"); }

/* klog_u is decimal; addresses and MPIDR only read as themselves in hex. */
static void klog_x(uint32_t v)
{
    char b[11] = "0x00000000";
    for (int i = 0; i < 8; i++) b[9 - i] = "0123456789abcdef"[(v >> (i * 4)) & 0xf];
    klog(b);
}

cpu1_mbox *cpu1_box(void) { return mb; }

/* Liveness is the mailbox's own magic, not a flag latched at boot.  If CPU1
 * turns up late (a missed wake, a slow pen) it becomes usable the moment it
 * announces itself, instead of staying written off until the next reboot. */
int cpu1_alive(void) { return mb->magic == (uint32_t)CPU1_MAGIC; }

/* How far the idle counter moves in `us`.  This is the liveness signal that
 * does NOT depend on the command channel: a CPU1 that is executing but whose
 * doorbell loop is wedged still ticks, and one that is parked in a fault
 * handler does not.  It separates "dead" from "deaf". */
uint32_t cpu1_heartbeat_delta(uint32_t us)
{
    uint32_t h0 = mb->heartbeat;
    uint32_t t0 = GT_LO, lim = US_TICKS(us);
    while ((uint32_t)(GT_LO - t0) < lim) { }
    return mb->heartbeat - h0;
}

/* Busy-wait until `pred` or `us` microseconds elapse.  The global timer is the
 * only clock available this early (cpu1_init runs before the scheduler). */
#define WAIT_UNTIL(pred, us) do {                                             \
        uint32_t _t0 = GT_LO, _lim = US_TICKS(us);                            \
        while (!(pred) && (uint32_t)(GT_LO - _t0) < _lim) { }                 \
    } while (0)

/* Set ACTLR.SMP on the calling core.  The A9 only participates in the SCU —
 * and therefore in the cross-core EVENT path that SEV/WFE rides on — when this
 * bit is set.  Enabling the SCU alone is not enough: with SMP clear on CPU0 the
 * SEV never reaches CPU1, which is exactly the symptom seen on the board (50 ms
 * of continuous SEV moved a pen-parked CPU1 not at all, while a debugger resume
 * released it instantly).  CPU0's cache behaviour is otherwise unchanged: it is
 * the only core running cached, so there is nothing for it to be coherent WITH
 * yet — this buys the event path, and pre-arranges the coherency CPU1 will need
 * the day it runs cached. */
static inline void set_smp(void)
{
    uint32_t v;
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 1" : "=r"(v));
    __asm__ volatile("mcr p15, 0, %0, c1, c0, 1" :: "r"(v | (1u << 6)));
    __asm__ volatile("dsb; isb" ::: "memory");
}

static void scu_enable(void)
{
    *(volatile uint32_t *)SCU_INVALIDATE = 0x00F0u;   /* CPU1's tag ways only —
                                                       * do not disturb CPU0's */
    dsb();
    *(volatile uint32_t *)SCU_CTRL |= 1u;
    dsb();
    set_smp();
}

uint32_t cpu1_scu_ctrl(void) { return *(volatile uint32_t *)SCU_CTRL; }

void cpu1_debug(uint32_t *v)   /* pen_armed, pen_final, rst_before, rst_held, rst_after */
{
    v[0] = dbg_pen_armed; v[1] = dbg_pen_final;
    v[2] = dbg_rst_before; v[3] = dbg_rst_held; v[4] = dbg_rst_after;
}

uint32_t cpu1_actlr(void)
{
    uint32_t v;
    __asm__ volatile("mrc p15, 0, %0, c1, c0, 1" : "=r"(v));
    return v;
}

/* Arm the pen with our entry point and wake CPU1, then re-park the sentinel.
 * Split out of cpu1_init so it can be RETRIED at runtime: a core that missed
 * its release at boot should not need a reboot (and, while this is being
 * brought up, an experiment should not cost a bitstream load).  Returns 1 if
 * CPU1 is alive when we are done.
 *
 * `pen_state` reports what the pen held on entry, for the caller's diagnostics. */
static int cpu1_release(uint32_t *pen_state)
{
    volatile uint32_t *pen = (volatile uint32_t *)CPU1_PEN_ADDR;
    if (pen_state) *pen_state = *pen;

    *pen = (uint32_t)(uintptr_t)&cpu1_entry;
    dsb();
    dbg_pen_armed = *pen;

    /* Try the documented wake first: SEV, repeatedly, because the pen does
     * `dsb; wfe; read` and a single event delivered between the read and the
     * WFE would be consumed and lost.
     *
     * On this board it does not work — and that is measured, not assumed.  With
     * SCU_CTRL = 0x3 (SCU on) and CPU0's ACTLR = 0x40 (SMP set), 50 ms of
     * continuous SEV leaves a pen-parked CPU1 exactly where it was, while a
     * debugger resume (which terminates WFE by other means) releases it
     * instantly.  So the SEV is kept as the cheap first attempt and the reset
     * pulse below is what actually does the work. */
    {
        uint32_t t0 = GT_LO, lim = US_TICKS(2000);
        while (!cpu1_alive() && (uint32_t)(GT_LO - t0) < lim) sev();
    }

    /* The lever that actually works: plant a trampoline at CPU1's reset vector
     * and pulse its reset through the SLCR — Linux's zynq_cpun_start.
     *
     * An SLCR core reset does NOT re-enter the BootROM.  Measured on the board:
     * with the pen armed and the SLCR write confirmed taking effect
     * (A9_CPU_RST_CTRL read back 0x22 while held), the pen still contained our
     * address afterwards, untouched — CPU1 came out of reset and never read it.
     * It restarts at its reset vector, address 0, so that is where the jump has
     * to be.  Only a full system reset (`rst -srst`) re-runs the BootROM and
     * re-parks CPU1 in the pen. */
    {
        uint32_t tramp[2] = { TRAMP_JUMP, (uint32_t)(uintptr_t)&cpu1_entry };
        mmu_poke_phys0(tramp, 2);
    }
    *(volatile uint32_t *)SLCR_UNLOCK = 0xDF0Du;
    dsb();
    {
        volatile uint32_t *rst = (volatile uint32_t *)A9_CPU_RST_CTRL;
        dbg_rst_before = *rst;
        *rst |= A9_RST1 | A9_CLKSTOP1;   /* hold CPU1 in reset, clock stopped */
        dsb();
        dbg_rst_held = *rst;             /* did the SLCR write take at all? */
        *rst &= ~A9_RST1;                /* release the reset ... */
        dsb();
        *rst &= ~A9_CLKSTOP1;            /* ... then let its clock run */
        dsb();
        dbg_rst_after = *rst;
    }
    *(volatile uint32_t *)SLCR_LOCK = 0x767Bu;
    dsb();

    /* Bounded — a board where CPU1 never answers must still boot. */
    {
        uint32_t t0 = GT_LO, lim = US_TICKS(50000);
        while (!cpu1_alive() && (uint32_t)(GT_LO - t0) < lim) { }
    }

    dbg_pen_final = *pen;   /* sentinel here => the BootROM rewrote our arm */

    /* Disarm the trampoline: replace the jump with `b .`.  Address 0 is DDR and
     * survives `rst -system`, so a live jump left there would fire CPU1 into the
     * image on the NEXT reset, while JTAG is still downloading it — the same
     * wedge the stale pen caused, and it took the whole DAP down with it.  A
     * parked spin is the safe thing to leave behind. */
    {
        uint32_t park[2] = { TRAMP_PARK, 0 };
        mmu_poke_phys0(park, 2);
    }

    /* Put the sentinel back (NOT 0, which is a jump to address 0) so the next
     * reset finds CPU1 properly parked rather than firing it at a half-written
     * image. */
    *pen = (uint32_t)CPU1_PEN_PARKED;
    dsb();
    return cpu1_alive();
}

/* Retry the release on a core that did not come up at boot. */
int cpu1_retry(void) { return cpu1_release(0); }

void cpu1_init(void)
{
    /* Zero the mailbox first so `magic` can only ever be CPU1's own write —
     * otherwise a warm reload would find the previous run's value and we would
     * declare a core alive that never woke. */
    memset((void *)mb, 0, sizeof *mb);
    dsb();

    scu_enable();

    uint32_t pen_before = 0;
    if (!cpu1_release(&pen_before)) {
        klog("[cpu1] no response from the second A9 (pen was ");
        klog_x(pen_before);
        klog(", SCU_CTRL ");
        klog_x(cpu1_scu_ctrl());
        klog(", ACTLR ");
        klog_x(cpu1_actlr());
        klog(") — CPU0 only\n");
        return;
    }
    klog("[cpu1] up: MPIDR ");
    klog_x(mb->mpidr);
    klog(", entry ");
    klog_x((uint32_t)(uintptr_t)&cpu1_entry);
    klog("\n");

    /* Prove it is really executing, not just that something wrote the magic:
     * a round-trip whose answer CPU0 never computed. */
    uint32_t arg[4] = { 0x12345678, 0, 0, 0 }, res[4] = { 0, 0, 0, 0 };
    if (cpu1_call(CPU1_CMD_PING, arg, res, 10000) == 0 &&
        res[0] == (0x12345678u ^ 0xA5A5A5A5u))
        klog("[cpu1] ping ok\n");
    else
        klog("[cpu1] ping FAILED (magic set but no command response)\n");
}

int cpu1_call(uint32_t cmd, const uint32_t arg[4], uint32_t res[4], uint32_t timeout_us)
{
    if (!cpu1_alive()) return -1;

    unsigned f = xt_irq_save();             /* claim the single outstanding slot */
    if (cpu1_busy) { xt_irq_restore(f); return -1; }
    cpu1_busy = 1;
    xt_irq_restore(f);

    for (int i = 0; i < 4; i++) mb->arg[i] = arg ? arg[i] : 0;
    mb->cmd = cmd;
    dsb();                                   /* args + cmd land before the doorbell */
    uint32_t seq = mb->ack + 1;
    mb->seq = seq;
    dsb();

    WAIT_UNTIL(mb->ack == seq, timeout_us);

    int rc = -1;
    if (mb->ack == seq) {
        for (int i = 0; i < 4; i++) if (res) res[i] = mb->res[i];
        rc = 0;
    }
    cpu1_busy = 0;
    return rc;
}
