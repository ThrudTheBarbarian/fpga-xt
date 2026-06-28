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

/* ---- W^X: per-page protection of loaded images (tier-2, T2-c) ----------
 * Set a VA range read-only and/or execute-never in the master table, converting
 * the (1 MB section) it lives in to a per-page L2 on first touch. Called on each
 * loaded program's text (RO+X) and writable (RW+XN) segments BEFORE the process
 * table is cloned from the master, so every space inherits W^X. */
static uint32_t l2pool[32][256] __attribute__((aligned(1024)));
static int      l2pool_next;

#define PG_NORMAL ((3u << 4) | (1u << 6) | 0x2u)   /* AP=RW all, TEX=001, small page, executable */
#define PG_RO     (1u << 9)                          /* AP[2]=1 -> read-only */
#define PG_XN     0x1u                               /* execute-never */

static uint32_t *l2_for_section(uint32_t sec)
{
    if ((l1[sec] & 0x3u) == 0x1u) return (uint32_t *)(l1[sec] & 0xFFFFFC00u);  /* already coarse */
    if (l2pool_next >= 32) return 0;                                            /* pool exhausted */
    uint32_t *l2 = l2pool[l2pool_next++];
    uint32_t secbase = sec << 20;
    for (uint32_t i = 0; i < 256; i++) l2[i] = (secbase + i * 0x1000u) | PG_NORMAL;  /* identity, RWX */
    l1[sec] = ((uint32_t)l2 & 0xFFFFFC00u) | 0x1u;
    return l2;
}

void mmu_protect(uint32_t va, uint32_t size, int ro, int xn)
{
    uint32_t end = (va + size + 0xFFFu) & ~0xFFFu;
    for (uint32_t p = va & ~0xFFFu; p < end; p += 0x1000u) {
        uint32_t *l2 = l2_for_section(p >> 20);
        if (!l2) return;
        l2[(p >> 12) & 0xFFu] = (p & 0xFFFFF000u) | PG_NORMAL | (ro ? PG_RO : 0u) | (xn ? PG_XN : 0u);
    }
    asm volatile("dsb");
    asm volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));   /* TLBIALL */
    asm volatile("dsb; isb");
}
