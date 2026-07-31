/*
 * cpu1_core.c — the code that runs ON CPU1.
 *
 * HARD RULE FOR THIS FILE: every function here executes on the second A9 with
 * its MMU off.  It may touch ONLY the uncached AMP region (the mailbox and
 * CPU1's own stack) plus read-only literals in the kernel image.  It must never
 * touch a kernel global, the heap, a FreeRTOS object, klog, or libc: CPU0 holds
 * all of that in a write-back D-cache, and there is no coherency between a
 * cached core and an MMU-off one.  Nothing in here may block or take a lock.
 *
 * Keeping CPU1's code in its own file is the enforcement mechanism — if it is
 * in cpu1.c it runs on CPU0, if it is here it runs on CPU1.
 */
#include "cpu1.h"

/* The A9 global timer: 64-bit, free-running at PERIPHCLK (CPU/2), shared by
 * both cores and started by CPU0's gtimer_init.  Reading it is how CPU1 times
 * its own work without needing any of the kernel's clock plumbing. */
#define GT_LO  (*(volatile uint32_t *)0xF8F00200)

static inline uint32_t mpidr(void)
{
    uint32_t v;
    __asm__ volatile("mrc p15, 0, %0, c0, c0, 5" : "=r"(v));
    return v;
}

static inline void dsb(void) { __asm__ volatile("dsb" ::: "memory"); }

static inline uint32_t midr(void)
{
    uint32_t v; __asm__ volatile("mrc p15, 0, %0, c0, c0, 0" : "=r"(v)); return v;
}
static inline uint32_t sctlr(void)
{
    uint32_t v; __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(v)); return v;
}
static inline uint32_t actlr(void)
{
    uint32_t v; __asm__ volatile("mrc p15, 0, %0, c1, c0, 1" : "=r"(v)); return v;
}

/* Invalidate CPU1's own L1 D-cache by set/way.  Mandatory before enabling the
 * D-cache: its contents are UNKNOWN out of reset, and an unclean line could
 * evict garbage over RAM the moment caching turns on.  Walks CLIDR/CCSIDR for
 * the geometry, exactly as mmu.c does for CPU0 — duplicated rather than shared
 * because this must run on CPU1, and CPU1 code lives in this file. */
static void dcache_invalidate_all(void)
{
    uint32_t clidr;
    __asm__ volatile("mrc p15,1,%0,c0,c0,1" : "=r"(clidr));
    uint32_t loc = (clidr >> 24) & 0x7u;
    for (uint32_t lvl = 0; lvl < loc; lvl++) {
        if (((clidr >> (lvl * 3)) & 0x7u) < 2u) continue;
        __asm__ volatile("mcr p15,2,%0,c0,c0,0" :: "r"(lvl << 1));   /* CSSELR */
        __asm__ volatile("isb");
        uint32_t ccsidr;
        __asm__ volatile("mrc p15,1,%0,c0,c0,0" : "=r"(ccsidr));
        uint32_t linesz = (ccsidr & 0x7u) + 4u;
        uint32_t ways   = ((ccsidr >> 3)  & 0x3FFu);
        uint32_t sets   = ((ccsidr >> 13) & 0x7FFFu);
        uint32_t wayshift = (uint32_t)__builtin_clz(ways);
        for (int w = (int)ways; w >= 0; w--)
            for (int s = (int)sets; s >= 0; s--)
                __asm__ volatile("mcr p15,0,%0,c7,c6,2"
                                 :: "r"((lvl << 1) | ((uint32_t)w << wayshift)
                                        | ((uint32_t)s << linesz)));
    }
    __asm__ volatile("dsb; isb");
}

/* Turn on CPU1's MMU, D-cache, I-cache and branch prediction.
 *
 * Without this CPU1 fetches every single instruction from DDR uncached, which
 * measured 133 ns/iter against CPU0's 9.35 ns/iter on the same loop — a 14x
 * penalty that would sink the software 6502/ANTIC before it started.
 *
 * CPU1 runs on CPU0's MASTER table (passed in the mailbox): a flat identity map
 * where kernel text is cacheable, the AMP region is already Normal
 * NON-cacheable and peripherals are already Device.  So the mailbox stays
 * uncached on both sides — coherent by construction, exactly as before — while
 * code and stack become cacheable.  ACTLR.SMP is already set by cpu1_boot.S,
 * which must happen BEFORE the caches come on. */
static void cpu1_mmu_enable(uint32_t ttbr)
{
    __asm__ volatile("mcr p15,0,%0,c7,c5,0" :: "r"(0u));   /* ICIALLU */
    __asm__ volatile("mcr p15,0,%0,c7,c5,6" :: "r"(0u));   /* BPIALL  */
    dcache_invalidate_all();

    __asm__ volatile("mcr p15,0,%0,c3,c0,0" :: "r"(0x1u));  /* DACR: domain 0 client */
    __asm__ volatile("mcr p15,0,%0,c2,c0,2" :: "r"(0u));    /* TTBCR = 0 */
    __asm__ volatile("mcr p15,0,%0,c2,c0,0" :: "r"(ttbr));  /* TTBR0 */
    __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));    /* TLBIALL */
    __asm__ volatile("dsb; isb");

    uint32_t s = sctlr();
    s |=  1u;            /* M: MMU on */
    s &= ~2u;            /* A = 0: no alignment faults */
    s |=  (1u << 2);     /* C: D-cache */
    s |=  (1u << 12);    /* I: I-cache */
    s |=  (1u << 11);    /* Z: branch prediction */
    __asm__ volatile("mcr p15,0,%0,c1,c0,0" :: "r"(s));
    __asm__ volatile("dsb; isb");
}

/* Idle padding between heartbeats.  Register-only, so an idle CPU1 makes no bus
 * traffic — it must not compete with the compositor for DDR. */
static void spin(uint32_t n)
{
    while (n--) __asm__ volatile("nop");
}

/* The benchmark: branchy integer work in registers, the same shape as
 * progs/memprobe.c's compute loop, so CPU1's number is directly comparable with
 * the CPU0/Mac figures already in the investigation doc. */
static uint32_t bench(uint32_t iters)
{
    uint32_t x = 0x12345678;
    while (iters--) {
        x = x * 1664525u + 1013904223u;
        if (x & 0x00010000u) x ^= 0x9e3779b9u;
    }
    return x;
}

void cpu1_main(void)
{
    volatile cpu1_mbox *m = (volatile cpu1_mbox *)CPU1_MBOX_ADDR;

    /* Caches first — everything below is measured with them on.  ttbr is read
     * before the MMU comes up, out of the uncached mailbox, so it cannot be a
     * stale cached copy. */
    uint32_t ttbr = m->ttbr;
    if (ttbr) cpu1_mmu_enable(ttbr);

    m->mpidr = mpidr();
    m->midr  = midr();
    m->sctlr = sctlr();          /* what we ACTUALLY ended up with, not what we set */
    m->actlr = actlr();
    dsb();
    m->magic = CPU1_MAGIC;      /* last: CPU0 treats this as "everything above is valid" */
    dsb();

    for (;;) {
        uint32_t seq = m->seq;
        if (seq != m->ack) {                  /* doorbell */
            switch (m->cmd) {
            case CPU1_CMD_PING:
                m->res[0] = m->arg[0] ^ 0xA5A5A5A5u;
                m->res[1] = mpidr();
                break;
            case CPU1_CMD_BENCH: {
                uint32_t t0 = GT_LO;
                uint32_t chk = bench(m->arg[0]);
                m->res[0] = GT_LO - t0;       /* PERIPHCLK ticks */
                m->res[1] = chk;
                break;
            }
            case CPU1_CMD_STOP:
                dsb();
                m->ack = seq;
                dsb();
                for (;;) __asm__ volatile("wfi");
            default:
                break;
            }
            dsb();                            /* results land before the ack */
            m->ack = seq;
        }
        m->heartbeat = m->heartbeat + 1;
        spin(20000);
    }
}
