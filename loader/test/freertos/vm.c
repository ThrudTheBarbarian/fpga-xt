/*
 * vm.c — T2-b per-process address spaces.
 *
 * Each process gets its own L1 translation table, created as a COPY of the master
 * (kernel) table so the kernel + wired regions are mapped identically in every
 * space — only a process's PRIVATE window differs. On a context switch into a
 * process task we point TTBR0 at its table (vm_switch); switching back to the
 * kernel/shell uses the master table. Process A then literally cannot address
 * process B's private memory: the same VA maps to different physical in each.
 *
 * Switching is ASID-tagged (ARMv7 8-bit ASID in CONTEXTIDR): each space has its
 * own ASID, so a context switch needs NO TLB flush — entries are tagged and
 * coexist. The kernel/shared map is global (nG=0, copied into every table) so its
 * TLB entries are shared across ASIDs; only the per-process PRIVATE window is
 * non-global (nG=1) so it's ASID-tagged and truly isolated. An ASID is flushed
 * (TLBIASID) when its slot is reused, to drop a dead process's stale entries.
 *
 * The demo window: PRIV_VA is remapped per-process to a fresh private 1 MB, so
 * each process sees its own memory at that address.
 */
#include <stdint.h>
#include <string.h>
#include "frtos_os.h"

#define NSPACE     8
#define L2_IDX(va) (((va) >> 12) & 0xFF) /* L2 (4KB page) index within a section */

/* L2 small-page (4KB) descriptor: Normal non-cacheable, AP=11 (full), nG=1
 * (ASID-tagged), XN=0. bits: nG[11] | AP[5:4]=11 | TEX[8:6]=001 | type=10 */
#define L2_PAGE(phys) (((phys) & 0xFFFFF000u) | (1u<<11) | (3u<<4) | (1u<<6) | 0x2u)
/* L1 coarse descriptor pointing at an L2 table (domain 0) */
#define L1_COARSE(l2) (((uint32_t)(l2) & 0xFFFFFC00u) | 0x1u)
/* per-process heap: a section mapped to private physical, non-global */
#define SEC_NG(phys, attr) (((phys) & 0xFFF00000u) | (attr) | (1u<<17))

extern uint32_t *mmu_master_table(void);

static uint32_t  space_l1[NSPACE][4096]   __attribute__((aligned(16384)));
static uint32_t  space_l2[NSPACE][256]    __attribute__((aligned(1024)));  /* libc data section, per space */
static uint32_t  space_l2_heap[NSPACE][256] __attribute__((aligned(1024)));/* heap section (demand-paged) */
static uint32_t *g_cur_table;            /* currently-active TTBR0 table */
static uint32_t  g_cur_asid;

/* libc.so's writable (data/bss) range + a pristine snapshot, set once at boot. */
static uintptr_t   g_libc_wva;
static uint32_t    g_libc_wsize;
static const void *g_libc_snap;
void vm_set_libc(uintptr_t wva, uint32_t wsize, const void *snapshot)
{ g_libc_wva = wva; g_libc_wsize = wsize; g_libc_snap = snapshot; }

/* Build space `idx`'s table (ASID = idx+1; 0 = kernel/master): copy the master,
 * then give the process PRIVATE copies of (a) libc.so's data/bss pages — mapped
 * at the same VA via an L2 table, 4KB-granular, seeded from the pristine snapshot
 * so each process's malloc state is its own; and (b) a heap section at
 * XTOS_HEAP_VA. All non-global (ASID-tagged). Drop stale TLB for the reused ASID. */
uint32_t *vm_space_create(int idx)
{
    uint32_t *t  = space_l1[idx];
    uint32_t *l2 = space_l2[idx];
    uint32_t  asid = (uint32_t)idx + 1u;
    memcpy(t, mmu_master_table(), 4096 * sizeof(uint32_t));

    /* (a) private libc data/bss: copy the snapshot into fresh pages, map them via
     * L2 at libc's data VA (only the data pages — ~16KB, not a 1MB section). */
    if (g_libc_wva && g_libc_snap) {
        uint32_t first = (uint32_t)g_libc_wva & ~0xFFFu;
        uint32_t last  = ((uint32_t)g_libc_wva + g_libc_wsize - 1u) & ~0xFFFu;
        uint32_t npg   = (last - first) / 0x1000u + 1u;
        char *blk = frtos_alloc(npg * 0x1000u, 0x1000, NULL);
        if (blk) {
            uint32_t sec = first >> 20;
            memset(blk, 0, npg * 0x1000u);
            memcpy(blk + ((uint32_t)g_libc_wva - first), g_libc_snap, g_libc_wsize);
            /* identity-map the whole section (it also holds the shared boot heap /
             * program image / argv), then override ONLY libc's data pages private */
            for (uint32_t i = 0; i < 256; i++)
                l2[i] = L2_PAGE((sec << 20) + i * 0x1000u);
            for (uint32_t p = 0; p < npg; p++)
                l2[L2_IDX(first + p * 0x1000u)] = L2_PAGE((uint32_t)blk + p * 0x1000u);
            t[sec] = L1_COARSE(l2);
        }
    }

    /* (b) private heap: an L2 with every page faulting -> zero-filled ON DEMAND
     * (T2-c). Physical is consumed only for pages the process actually touches. */
    {
        uint32_t *hl2 = space_l2_heap[idx];
        memset(hl2, 0, 256 * sizeof(uint32_t));
        t[XTOS_HEAP_VA >> 20] = L1_COARSE(hl2);
    }

    __asm__ volatile("mcr p15,0,%0,c8,c7,2" :: "r"(asid));   /* TLBIASID: clear stale */
    __asm__ volatile("dsb; isb");
    return t;
}

/* Point TTBR0 at `table` with `asid` (NULL/0 = master). ARM-recommended sequence:
 * park on the reserved ASID, change TTBR0, then set the new ASID — no flush. */
void vm_switch(uint32_t *table, uint32_t asid)
{
    if (!table) { table = mmu_master_table(); asid = 0; }
    if (table == g_cur_table && asid == g_cur_asid) return;
    g_cur_table = table; g_cur_asid = asid;
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c13,c0,1" :: "r"(0u));            /* CONTEXTIDR = reserved ASID 0 */
    __asm__ volatile("isb");
    __asm__ volatile("mcr p15,0,%0,c2,c0,0"  :: "r"((uint32_t)table)); /* TTBR0 */
    __asm__ volatile("isb");
    __asm__ volatile("mcr p15,0,%0,c13,c0,1" :: "r"(asid));          /* CONTEXTIDR = new ASID */
    __asm__ volatile("isb");

    /* Drop stale GLOBAL TLB entries for libc's data VA when entering a process.
     * The master table maps that region global+identity, and the kernel/shell
     * touch it on every malloc (libc's arena). On real hardware that cached
     * global entry SHADOWS this process's private (nG) copy installed by
     * vm_space_create — so the process would see shared libc data. Invalidate
     * just those few pages by MVA (all ASIDs); everything else keeps the
     * ASID-tagged no-flush switch. (qemu's TLB model doesn't show the shadow.) */
    if (asid && g_libc_wva && g_libc_wsize) {
        uint32_t a = (uint32_t)g_libc_wva & ~0xFFFu;
        uint32_t e = ((uint32_t)g_libc_wva + g_libc_wsize - 1u) & ~0xFFFu;
        for (uint32_t v = a; v <= e; v += 0x1000u)
            __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(v));      /* TLBIMVAA */
        __asm__ volatile("dsb");
        __asm__ volatile("isb");
    }
}

/* ---- T2-c demand paging ---------------------------------------------------
 * A kernel page pool (reserved once at boot from the libc pool) that the data-
 * abort handler can draw from WITHOUT calling libc — the handler runs in the
 * faulting process's address space, where libc's data is the process's private
 * copy, so libc malloc there would be wrong. A plain bump over a pre-reserved
 * region is safe from any space. */
static char    *g_dpool, *g_dpool_end;
static uint32_t g_demand_count;
void vm_demand_pool_init(void *base, uint32_t size) { g_dpool = base; g_dpool_end = (char *)base + size; }
uint32_t vm_demand_count(void) { return g_demand_count; }

static void *dpage(void)
{ if (!g_dpool || g_dpool + 0x1000 > g_dpool_end) return (void *)0; void *p = g_dpool; g_dpool += 0x1000; return p; }

/* zero-fill-on-demand: map a fresh 4KB page at `va` in space `idx`'s heap L2.
 * Called from the data-abort handler when a process touches an unmapped heap
 * page. Returns 1 if mapped (resume), 0 if not ours / pool exhausted. */
int vm_demand_map(int idx, uint32_t va)
{
    uint32_t *hl2 = space_l2_heap[idx];
    uint32_t  i   = L2_IDX(va);
    if (hl2[i]) return 1;                       /* already present (lost race) */
    void *pg = dpage();
    if (!pg) return 0;
    memset(pg, 0, 0x1000);                      /* zero-fill */
    hl2[i] = L2_PAGE((uint32_t)pg);
    g_demand_count++;
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(va & 0xFFFFF000u));  /* TLBIMVAA */
    __asm__ volatile("dsb; isb");
    return 1;
}
