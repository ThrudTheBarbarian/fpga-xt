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

/* ---- PL0/PL1 access permissions (the user/kernel boundary) ----------------
 * Programs run at PL0 (User mode). The background identity map is PL0-NONE so a
 * process can't touch the kernel, the heap internals, the page pool, or another
 * process's private memory by address; only its own regions are PL0-accessible:
 * kernel + module TEXT is PL0-RX (so it can call the svc stubs / libgcc), and its
 * own data/heap/stack/cow/mmap windows are granted PL0 access per-process (vm.c).
 *
 * AP encodings (domain client): 11 = RW all, 111 = RO all (PL0-RX for X pages),
 * 01 = PL1 RW / PL0 none. All Normal WB-WA cacheable (TEX=001, C=1, B=1). */
#define PGS_RX    ((1u<<9)|(3u<<4)|(1u<<6)|(1u<<3)|(1u<<2)|0x2u)        /* small: AP=111, X  */
#define PGS_NONE  ((1u<<4)|(1u<<6)|(1u<<3)|(1u<<2)|0x1u|0x2u)           /* small: AP=01, XN  */
#define SEC_KDATA 0x141Eu     /* section: AP=01 (PL1 RW, PL0 none), cacheable, XN */
#define SEC_PLANE 0x1C12u     /* section: AP=11 (PL0 RW), Normal NON-cacheable, XN (PL-shared) */
#define SEC_PLANE_C (SEC_PLANE | 0xCu) /* 0x1C1E: as SEC_PLANE but Normal cacheable WB-WA —
                                        * CPU-only graphics scratch (WM back-buffer); no PL
                                        * master reads it, so no coherency vs the compositor */
#define SEC_PERIPH 0x0416u    /* section: AP=01 (PL0 none), Device, XN */

extern char __ktext_end[];    /* end of kernel text+rodata (linker, page-aligned) */
static uint32_t boot_text_l2[256] __attribute__((aligned(1024)));   /* splits section 1 */

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
    /* Domain 0 = CLIENT (AP enforced). The background identity map denies PL0:
     * kernel/heap/pool sections are PL0-none (SEC_KDATA); section 1 (which holds the
     * kernel text) is a per-page L2 so the text is PL0-RX and its data tail PL0-none;
     * the PL-shared planes stay PL0-RW (programs draw the framebuffer); peripherals
     * and the NULL section are PL0-none. Loaded modules + per-process windows punch
     * PL0-accessible holes over this background (mmu_protect + vm_space_create). */
    uint32_t ktend = (uint32_t)__ktext_end;          /* kernel text fits section 1 (<1 MB) */
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t va = 0x00100000u + i * 0x1000u;
        boot_text_l2[i] = (va & 0xFFFFF000u) | (va < ktend ? PGS_RX : PGS_NONE);
    }
    for (uint32_t i = 0; i < 4096; i++) {
        uint32_t base = i << 20;                 /* 1 MB sections */
        if (i == 0)              l1[i] = 0;                              /* NULL trap */
        else if (i == 1)         l1[i] = ((uint32_t)boot_text_l2 & 0xFFFFFC00u) | 0x1u;  /* kernel text/data split */
        else if (i < 0x200)      l1[i] = base | SEC_KDATA;              /* kernel data + heap + pool: PL0-none */
        else if (i >= 0x330 && i < 0x340) l1[i] = base | SEC_PLANE_C;  /* WALLPAPER_BASE 16 MB: PL0-RW cacheable
                                                                        * WM/desktop back-buffer (CPU-only) */
        else if (i < 1024)       l1[i] = base | SEC_PLANE;             /* SALLY/planes: PL0-RW, non-cacheable */
        else                     l1[i] = base | SEC_PERIPH;            /* peripherals: PL0-none, Device */
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
#define L2POOL_N 64
static uint32_t l2pool[L2POOL_N][256] __attribute__((aligned(1024)));
static int      l2pool_next;

#define PG_NORMAL ((3u << 4) | (1u << 6) | (1u << 3) | (1u << 2) | 0x2u) /* AP=RW all, TEX=001 C=1 B=1 (WB-WA cacheable), small page, executable */
#define PG_RO     (1u << 9)                          /* AP[2]=1 -> read-only */
#define PG_XN     0x1u                               /* execute-never */

/* Split a 1MB section into a coarse L2 (or return the existing one). The check +
 * pool-claim + background-fill + L1 install must be ATOMIC: two tasks loading images
 * concurrently (an interactive spawn while a background daemon loads a lib) would
 * otherwise both see the section as un-split, claim two pool entries, and race the
 * L1 write — orphaning one L2 and corrupting the mapping. Guard with an IRQ-masked
 * critical section (short: at most a 256-entry fill, only at image load). */
static uint32_t *l2_for_section(uint32_t sec)
{
    unsigned f = xt_irq_save();
    if ((l1[sec] & 0x3u) == 0x1u) {                                            /* already coarse */
        uint32_t *l2 = (uint32_t *)(l1[sec] & 0xFFFFFC00u); xt_irq_restore(f); return l2;
    }
    if (l2pool_next >= L2POOL_N) {                                             /* pool exhausted */
        xt_irq_restore(f);
        extern void puts0(const char *); extern void putu(unsigned);
        puts0("*** mmu: split-pool EXHAUSTED at section "); putu(sec);
        puts0(" (loaded code there will NOT be PL0-executable)\n");
        return 0;
    }
    uint32_t *l2 = l2pool[l2pool_next++];
    uint32_t secbase = sec << 20;
    /* identity background = PL0-none (the non-module pages in this section: heap
     * internals / other allocations a process must not reach). mmu_protect then
     * punches the module's own text (PL0-RX) and data (PL0-none master; the owner
     * gets PL0-RW via the per-process COW override in vm.c). */
    for (uint32_t i = 0; i < 256; i++) l2[i] = (secbase + i * 0x1000u) | PGS_NONE;
    l1[sec] = ((uint32_t)l2 & 0xFFFFFC00u) | 0x1u;
    xt_irq_restore(f);
    return l2;
}

void mmu_protect(uint32_t va, uint32_t size, int ro, int xn)
{
    uint32_t end = (va + size + 0xFFFu) & ~0xFFFu;
    for (uint32_t p = va & ~0xFFFu; p < end; p += 0x1000u) {
        uint32_t *l2 = l2_for_section(p >> 20);
        if (!l2) return;
        /* text (ro): PL0-RX (AP=111 RO-all, executable). writable seg (!ro): PL0-NONE
         * in the master (AP=01) — its owner process gets PL0-RW per-process via COW;
         * other processes can't see it. (xn applies to the writable seg.) */
        l2[(p >> 12) & 0xFFu] = (p & 0xFFFFF000u) |
            (ro ? (PG_NORMAL | PG_RO) : (PGS_NONE | (xn ? PG_XN : 0u)));
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
