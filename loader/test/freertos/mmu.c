/*
 * mmu.c — a minimal flat (identity) MMU map so RAM is *Normal* memory.
 *
 * With the MMU off, the Cortex-A9 treats all memory as Strongly-ordered, where
 * every unaligned access faults — which kills libc.so's NEON/word-tail memcpy
 * (FreeType hits it constantly). A flat 1:1 section map marks the 1 GB of DDR as
 * Normal (unaligned-friendly) and everything above as Device (GIC/UART/PL).
 *
 * Caches are ON. The CPU's own RAM (code, libc, heap, COW pages — everything
 * below 0x2000_0000) is Normal Write-Back Write-Allocate cacheable; page-table
 * walks are cacheable too (XTOS_TTBR_ATTR) so they stay coherent with our PTE
 * writes. The loader cleans D + invalidates I over freshly-copied code
 * (xtld_host.sync_caches -> mmu_sync_caches). COW/heap data pages are XN, so they
 * need no I-side maintenance.
 *
 * The PL-shared region (0x2000_0000..0x3FFF_FFFF: SALLY/planes/framebuffers) stays
 * Normal NON-cacheable, and peripherals stay Device: the FPGA and the display must
 * see CPU writes (and vice-versa) without a cache between them — the
 * "PL-visible => wired/uncached" invariant.
 */
#include <stdint.h>
#include "frtos_os.h"

static volatile uint32_t l1[4096] __attribute__((aligned(16384)));

/* ---- cache maintenance (CP15) ----------------------------------------------
 * Invalidate the entire L1 D-cache by set/way — required before enabling the
 * D-cache from reset, when its contents are UNKNOWN (an unclean line could evict
 * garbage over RAM). Walks CLIDR/CCSIDR for the geometry. */
static void dcache_invalidate_all(void)
{
    uint32_t clidr;
    __asm__ volatile("mrc p15,1,%0,c0,c0,1" : "=r"(clidr));   /* CLIDR */
    uint32_t loc = (clidr >> 24) & 0x7u;                       /* level of coherency */
    for (uint32_t lvl = 0; lvl < loc; lvl++) {
        if (((clidr >> (lvl * 3)) & 0x7u) < 2u) continue;     /* no D-cache at this level */
        __asm__ volatile("mcr p15,2,%0,c0,c0,0" :: "r"(lvl << 1));   /* CSSELR */
        __asm__ volatile("isb");
        uint32_t ccsidr;
        __asm__ volatile("mrc p15,1,%0,c0,c0,0" : "=r"(ccsidr));     /* CCSIDR */
        uint32_t linesz = (ccsidr & 0x7u) + 4u;                       /* log2(line bytes) */
        uint32_t ways   = ((ccsidr >> 3)  & 0x3FFu);
        uint32_t sets   = ((ccsidr >> 13) & 0x7FFFu);
        uint32_t wayshift = __builtin_clz(ways);                      /* align way field */
        for (int w = (int)ways; w >= 0; w--)
            for (int s = (int)sets; s >= 0; s--) {
                uint32_t v = (lvl << 1) | ((uint32_t)w << wayshift) | ((uint32_t)s << linesz);
                __asm__ volatile("mcr p15,0,%0,c7,c6,2" :: "r"(v));   /* DCISW */
            }
    }
    __asm__ volatile("dsb; isb");
}

/* Make `len` bytes at `addr` coherent for execution: clean D-cache to PoU + invalidate
 * I-cache, both by MVA, then flush the branch predictor. This is xtld_host.sync_caches —
 * the loader calls it after copying a program's segments into (cacheable) RAM. */
void mmu_sync_caches(void *addr, unsigned long len, void *user)
{
    (void)user;
    uint32_t a = (uint32_t)addr & ~0x3Fu;                 /* 32-byte line (A9) */
    uint32_t end = (uint32_t)addr + (uint32_t)len;
    for (uint32_t p = a; p < end; p += 0x20u)
        __asm__ volatile("mcr p15,0,%0,c7,c11,1" :: "r"(p));   /* DCCMVAU: clean D to PoU */
    __asm__ volatile("dsb");
    for (uint32_t p = a; p < end; p += 0x20u)
        __asm__ volatile("mcr p15,0,%0,c7,c5,1" :: "r"(p));    /* ICIMVAU: invalidate I */
    __asm__ volatile("mcr p15,0,%0,c7,c5,6" :: "r"(0u));       /* BPIALL */
    __asm__ volatile("dsb; isb");
}

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
        else if (i < 0x200)      l1[i] = base | 0x1C0E;       /* 0x0010_0000..0x1FFF_FFFF: kernel+pool, Normal WB-WA cacheable, AP=11, X */
        else if (i < 1024)       l1[i] = base | 0x1C12;       /* 0x2000_0000..0x3FFF_FFFF: SALLY/planes, Normal NON-cacheable (PL-shared), XN */
        else                     l1[i] = base | 0x0C16;       /* peripherals: Device, AP=11, XN */
    }
    /* caches are UNKNOWN out of reset — invalidate before enabling, or a stale
     * dirty D-line could evict garbage over RAM once the D-cache turns on. */
    asm volatile("mcr p15,0,%0,c7,c5,0" :: "r"(0u));            /* ICIALLU: invalidate I-cache */
    asm volatile("mcr p15,0,%0,c7,c5,6" :: "r"(0u));            /* BPIALL: invalidate branch predictor */
    dcache_invalidate_all();                                    /* invalidate D-cache (set/way) */

    asm volatile("mcr p15,0,%0,c3,c0,0" :: "r"(0x1u));          /* DACR: domain 0 = CLIENT (enforce AP) */
    asm volatile("mcr p15,0,%0,c2,c0,2" :: "r"(0u));            /* TTBCR = 0 (TTBR0 only) */
    asm volatile("mcr p15,0,%0,c2,c0,0" :: "r"((uint32_t)l1 | XTOS_TTBR_ATTR)); /* TTBR0 = L1 (cacheable walks) */
    asm volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));            /* invalidate unified TLB */
    asm volatile("dsb; isb");
    uint32_t sctlr;
    asm volatile("mrc p15,0,%0,c1,c0,0" : "=r"(sctlr));
    sctlr |=  1u;                                               /* M = 1: MMU on */
    sctlr &= ~2u;                                               /* A = 0: no alignment faults */
    sctlr |=  (1u << 2);                                        /* C = 1: D-cache on */
    sctlr |=  (1u << 12);                                       /* I = 1: I-cache on */
    sctlr |=  (1u << 11);                                       /* Z = 1: branch prediction on */
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

#define PG_NORMAL ((3u << 4) | (1u << 6) | (1u << 3) | (1u << 2) | 0x2u) /* AP=RW all, TEX=001 C=1 B=1 (WB-WA cacheable), small page, executable */
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

/* Undo mmu_protect over a range: restore identity RWX (cacheable) in the master,
 * so memory freed by unloading an image is safe to re-use (otherwise its text
 * pages stay read-only and a later write to the reused RAM would fault). The
 * section's coarse L2 is kept (identity RWX is equivalent to the original section). */
void mmu_unprotect(uint32_t va, uint32_t size)
{
    uint32_t end = (va + size + 0xFFFu) & ~0xFFFu;
    for (uint32_t p = va & ~0xFFFu; p < end; p += 0x1000u) {
        uint32_t sec = p >> 20;
        if ((l1[sec] & 0x3u) != 0x1u) continue;          /* not coarse -> already plain identity */
        uint32_t *l2 = (uint32_t *)(l1[sec] & 0xFFFFFC00u);
        l2[(p >> 12) & 0xFFu] = (p & 0xFFFFF000u) | PG_NORMAL;   /* identity RWX */
    }
    asm volatile("dsb");
    asm volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));   /* TLBIALL */
    asm volatile("dsb; isb");
}
