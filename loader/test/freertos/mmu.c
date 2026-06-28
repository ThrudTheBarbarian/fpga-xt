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

void mmu_init(void)
{
    for (uint32_t i = 0; i < 4096; i++) {
        uint32_t base = i << 20;                 /* 1 MB sections */
        l1[i] = (i < 1024) ? (base | 0x1C02)     /* 0..1GB DDR: Normal non-cacheable, AP=11 */
                           : (base | 0x0C06);    /* peripherals: Device, AP=11 */
    }
    asm volatile("mcr p15,0,%0,c3,c0,0" :: "r"(0x3u));          /* DACR: domain 0 = manager */
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
