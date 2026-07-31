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

    m->mpidr = mpidr();
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
