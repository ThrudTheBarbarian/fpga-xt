/*
 * mmu.c — a minimal flat (identity) MMU map so RAM is *Normal* memory.
 *
 * With the MMU off, the Cortex-A9 treats all memory as Strongly-ordered, where
 * every unaligned access faults — which kills libc.so's NEON/word-tail memcpy
 * (FreeType hits it constantly). A flat 1:1 section map marks the 1 GB of DDR as
 * Normal (unaligned-friendly) and everything above as Device (GIC/UART/PL).
 *
 * Caches are deliberately left OFF: Normal-non-cacheable already fixes unaligned
 * access without the I/D-cache coherency dance the loader would otherwise need
 * (clean-D + invalidate-I after copying code). Turning caches on — and wiring
 * xtld_host.sync_caches — is a later step, together with real per-process
 * page tables (tier-2). This is flat and protectionless on purpose.
 */
#include <stdint.h>

static volatile uint32_t l1[4096] __attribute__((aligned(16384)));

/* the master (kernel) translation table — per-process spaces (vm.c) start as
 * copies of this so the kernel + wired regions are mapped in every space. */
uint32_t *mmu_master_table(void) { return (uint32_t *)l1; }

void mmu_init(void)
{
    /* T2-a protection: domain 0 is a CLIENT (AP enforced, not bypassed). The
     * null/low section is a translation fault (NULL/wild-low pointer -> abort);
     * code regions are executable, data regions XN (W^X at section grain). */
    for (uint32_t i = 0; i < 4096; i++) {
        uint32_t base = i << 20;                 /* 1 MB sections */
        if (i == 0)              l1[i] = 0;                    /* 0x00000000: fault (NULL trap) */
        else if (i < 0x200)      l1[i] = base | 0x1C02;       /* 0x0010_0000..0x1FFF_FFFF: kernel+pool, Normal, AP=11, X */
        else if (i < 1024)       l1[i] = base | 0x1C12;       /* 0x2000_0000..0x3FFF_FFFF: SALLY/spare/planes, Normal, XN */
        else                     l1[i] = base | 0x0C16;       /* peripherals: Device, AP=11, XN */
    }
    asm volatile("mcr p15,0,%0,c3,c0,0" :: "r"(0x1u));          /* DACR: domain 0 = CLIENT (enforce AP) */
    asm volatile("mcr p15,0,%0,c2,c0,2" :: "r"(0u));            /* TTBCR = 0 (TTBR0 only) */
    asm volatile("mcr p15,0,%0,c2,c0,0" :: "r"((uint32_t)l1));  /* TTBR0 = L1 table */
    asm volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));            /* invalidate unified TLB */
    asm volatile("dsb; isb");
    uint32_t sctlr;
    asm volatile("mrc p15,0,%0,c1,c0,0" : "=r"(sctlr));
    sctlr |=  1u;                                               /* M = 1: MMU on */
    sctlr &= ~2u;                                               /* A = 0: no alignment faults */
    asm volatile("mcr p15,0,%0,c1,c0,0" :: "r"(sctlr));
    asm volatile("dsb; isb");
}
