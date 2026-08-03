/*
 * pl310.h — the Zynq's outer (L2) cache controller.
 *
 * WHY: measured, the A9 falls off a cliff the moment a working set leaves the
 * 32 KB L1 — 32 ns/iter up to 32 KB, then 242 ns at 64 KB and 338 at 1 MB, with
 * NO plateau in between (loader/test/freertos/progs/wsweep.c). That is DRAM
 * latency with nothing behind L1, because the PL310 was never enabled: mathcop.c
 * and cpu1.h both say so in as many words. Turning it on is worth ~7x to any
 * program whose data exceeds 32 KB, which is most of them.
 *
 * The PL310 is a UNIFIED OUTER cache on the AXI path, not a per-core one, so
 * enabling it serves CPU0 and CPU1 alike with no per-core action. CPU1 already
 * runs with its MMU and L1 caches on and shares CPU0's master table, and the SCU
 * is enabled with ACTLR.SMP set on both cores, so the two L1s stay coherent with
 * each other and both sit in front of this.
 *
 * WHAT IT DOES NOT BREAK: the AMP mailbox at 0x2100_0000 is mapped Normal
 * NON-cacheable (SEC_PLANE_K in mmu.c), so it bypasses L1 AND L2 and remains
 * coherent by construction — the concern recorded in cpu1.h ("the PL310 L2 is not
 * enabled in this port, so there is nothing behind that either") is answered
 * rather than aggravated. The same is true of the PL-shared planes.
 *
 * WHAT IT DOES CHANGE: every DMA path that pushes data to, or reads data from,
 * the PROGRAMMABLE LOGIC must now maintain L2 as well as L1, because the PL
 * reads DDR directly and L2 sits between the core and DDR. Those are the
 * `_poc` helpers below. ORDER MATTERS and is the easy thing to get wrong:
 *
 *   sending data OUT to the PL   clean L1 -> clean L2 -> sync   (inner first)
 *   reading data IN from the PL  inval L1 -> inval L2 -> inval L1 again
 *
 * The doubled inner invalidate on the way in is deliberate: between the two
 * outer and inner steps a speculative fetch can refill L1 from a line that is
 * still stale in L2, and the second pass discards it.
 *
 * Instruction coherency does NOT need anything here: mmu_sync_caches cleans to
 * the Point of Unification and instruction fetch reads through L2, so data
 * cleaned that far is already visible to the I-side.
 */
#ifndef XT_PL310_H
#define XT_PL310_H

#include <stdint.h>

#define PL310_BASE 0xF8F02000u
#define PL310_R(o) (*(volatile uint32_t *)(PL310_BASE + (o)))

#define PL310_CTRL        PL310_R(0x100)
#define PL310_AUX_CTRL    PL310_R(0x104)
#define PL310_INT_CLEAR   PL310_R(0x220)
#define PL310_CACHE_SYNC  PL310_R(0x730)
#define PL310_INV_PA      PL310_R(0x770)
#define PL310_INV_WAY     PL310_R(0x77C)
#define PL310_CLEAN_PA    PL310_R(0x7B0)
#define PL310_CLEAN_WAY   PL310_R(0x7BC)
#define PL310_CLINV_PA    PL310_R(0x7F0)
#define PL310_CLINV_WAY   PL310_R(0x7FC)

#define PL310_LINE 32u                 /* PL310 line size */
#define PL310_WAYS 0xFFFFu             /* Zynq: 8 ways; the mask is 16 bits wide */

/* Drain the store buffer and wait for outstanding maintenance to land. */
static inline void pl310_sync(void) { PL310_CACHE_SYNC = 0u; }

static inline int pl310_on(void) { return (PL310_CTRL & 1u) != 0; }

/* Bring the outer cache up. Called ONCE, by CPU0, after the MMU and the L1
 * caches are on — CPU1 must not repeat it. AUX_CTRL is deliberately left as the
 * boot stage set it: the RAM latencies there are board-specific and a wrong
 * guess is worse than a conservative default, so tune it only with a measurement
 * in hand. Contents are UNKNOWN out of reset, hence the invalidate first. */
static inline void pl310_init(void)
{
    if (pl310_on()) return;
    PL310_INV_WAY = PL310_WAYS;
    while (PL310_INV_WAY & PL310_WAYS) { }
    pl310_sync();
    PL310_INT_CLEAR = 0x1FFu;
    PL310_CTRL = 1u;
}

/* Push a span out of the outer cache to DDR (after the inner clean). */
static inline void pl310_clean(uint32_t addr, uint32_t len)
{
    if (!pl310_on()) return;
    uint32_t end = addr + len;
    for (uint32_t p = addr & ~(PL310_LINE - 1u); p < end; p += PL310_LINE)
        PL310_CLEAN_PA = p;
    pl310_sync();
}

/* Discard a span from the outer cache (before the inner invalidate). */
static inline void pl310_inval(uint32_t addr, uint32_t len)
{
    if (!pl310_on()) return;
    uint32_t end = addr + len;
    for (uint32_t p = addr & ~(PL310_LINE - 1u); p < end; p += PL310_LINE)
        PL310_INV_PA = p;
    pl310_sync();
}

/* Clean AND discard a span. Use on a partial line at the edge of a DMA buffer:
 * a plain invalidate there would throw away the bytes OUTSIDE the buffer that
 * share the line, exactly as the inner code already argues in xil_shim.c. */
static inline void pl310_cleaninval(uint32_t addr, uint32_t len)
{
    if (!pl310_on()) return;
    uint32_t end = addr + len;
    for (uint32_t p = addr & ~(PL310_LINE - 1u); p < end; p += PL310_LINE)
        PL310_CLINV_PA = p;
    pl310_sync();
}

#endif /* XT_PL310_H */
