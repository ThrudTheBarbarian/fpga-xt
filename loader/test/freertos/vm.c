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
/* Normal WB-WA cacheable (TEX=001 C=1 B=1), AP=11 (full), nG=1, XN=0 */
#define L2_PAGE(phys) (((phys) & 0xFFFFF000u) | (1u<<11) | (3u<<4) | (1u<<6) | (1u<<3) | (1u<<2) | 0x2u)
/* same, but read-only (AP[2]=1 -> AP=111): a write faults (the COW trigger) */
#define L2_PAGE_RO(phys) (L2_PAGE(phys) | (1u<<9))
/* L1 coarse descriptor pointing at an L2 table (domain 0) */
#define L1_COARSE(l2) (((uint32_t)(l2) & 0xFFFFFC00u) | 0x1u)
/* per-process heap: a section mapped to private physical, non-global */
#define SEC_NG(phys, attr) (((phys) & 0xFFF00000u) | (attr) | (1u<<17))

extern uint32_t *mmu_master_table(void);

static uint32_t  space_l1[NSPACE][4096]     __attribute__((aligned(16384)));
static uint32_t  space_l2_heap[NSPACE][256] __attribute__((aligned(1024)));/* heap section (demand-paged) */
/* a small per-space pool of L2 tables, one per 1 MB section the space overrides
 * (libc data, program data, the synthetic demo). Section-keyed so a program and
 * libc that happen to share a 1 MB section reuse ONE L2 (no clobber, the §6
 * collision). */
#define MAXSEC 6
static uint32_t  space_l2pool[NSPACE][MAXSEC][256] __attribute__((aligned(1024)));
static uint16_t  space_l2sec[NSPACE][MAXSEC];   /* section number each slot maps */
static uint8_t   space_l2n[NSPACE];             /* slots used this space */
static uint32_t *g_cur_table;            /* currently-active TTBR0 table */
static uint32_t  g_cur_asid;

/* ---- copy-on-write (T2-c) -------------------------------------------------
 * A COW page starts mapped shared read-only at a pristine source; the first WRITE
 * permission-faults, and the handler makes a PRIVATE copy (read through the RO
 * mapping into a fresh page), remaps it RW, and re-runs the store. This is the
 * fork-ready mechanism. Pages are COW only inside known ranges — so a write to
 * read-only TEXT (W^X) is NOT in any range and stays fatal.
 *
 * Two kinds of range. GLOBAL ranges (libc data, the synthetic demo) live at the
 * same VA in every space and are mapped into all of them. The PER-SPACE program
 * range is the spawning program's own data: its VA is the program's identity load
 * address (different programs -> different VAs), so it belongs only to that space.
 * Each range carries `src`: page (va + k*0x1000) maps RO to (src + k*0x1000). */
#define NCOW 4
typedef struct { uint32_t va, end, src; } cow_rng;
static cow_rng  g_cow_rng[NCOW];                 /* global ranges (libc, synthetic) */
static int      g_cow_n;
static cow_rng  g_space_prog[NSPACE];            /* the program data range of each space */
static uint32_t g_cow_count;
void vm_cow_register(uint32_t va, uint32_t size, uint32_t src)
{
    uint32_t base = va & ~0xFFFu;
    for (int i = 0; i < g_cow_n; i++) if (g_cow_rng[i].va == base) return;  /* dedup */
    if (g_cow_n >= NCOW) return;
    g_cow_rng[g_cow_n].va  = base;
    g_cow_rng[g_cow_n].end = (va + size + 0xFFFu) & ~0xFFFu;
    g_cow_rng[g_cow_n].src = src & ~0xFFFu;
    g_cow_n++;
}
static int cow_owns(int idx, uint32_t va)
{
    for (int i = 0; i < g_cow_n; i++)
        if (va >= g_cow_rng[i].va && va < g_cow_rng[i].end) return 1;
    return va >= g_space_prog[idx].va && va < g_space_prog[idx].end;
}
uint32_t vm_cow_count(void) { return g_cow_count; }

/* Get (or lazily create) space `idx`'s private L2 for 1 MB section `sec`, seeded
 * from the master so pages we DON'T override (shared text/rodata/GOT in the same
 * section) keep their master mapping. The master section is either a 1 MB section
 * descriptor (synthesize an identity L2) or already a coarse L2 (copy it — e.g. a
 * program's W^X section). Installs the coarse L1 entry in `t`. */
static uint32_t *perproc_l2(int idx, uint32_t *t, uint32_t sec)
{
    for (int i = 0; i < space_l2n[idx]; i++)
        if (space_l2sec[idx][i] == sec) return space_l2pool[idx][i];
    if (space_l2n[idx] >= MAXSEC) return 0;
    uint32_t *l2  = space_l2pool[idx][space_l2n[idx]];
    uint32_t  ml1 = mmu_master_table()[sec];
    if ((ml1 & 0x3u) == 0x1u)                                     /* master is coarse L2 */
        memcpy(l2, (uint32_t *)(ml1 & 0xFFFFFC00u), 256 * sizeof(uint32_t));
    else                                                          /* master is a 1 MB section */
        for (uint32_t i = 0; i < 256; i++) l2[i] = L2_PAGE((sec << 20) + i * 0x1000u);
    space_l2sec[idx][space_l2n[idx]] = (uint16_t)sec;
    space_l2n[idx]++;
    t[sec] = L1_COARSE(l2);
    return l2;
}

/* Synthetic COW demo: a pristine template page mapped shared-RO at XTOS_COW_VA in
 * every space. cowtest reads the template, writes (faulting -> private copy), and
 * reads back its own value; two instances stay isolated. The kernel never touches
 * XTOS_COW_VA, so (like the heap window) no stale global TLB entry shadows the
 * per-space mapping on real hardware — no extra vm_switch flush needed. */
static uint8_t cow_template[0x1000] __attribute__((aligned(0x1000)));
void vm_cow_init(void)
{
    for (int i = 0; i < 0x1000; i++) cow_template[i] = 0x5A;
    cow_template[0] = 'C'; cow_template[1] = 'O'; cow_template[2] = 'W';
    vm_cow_register(XTOS_COW_VA, XTOS_COW_SIZE, (uint32_t)cow_template);
}

/* libc.so's writable (data/bss) range + a pristine snapshot, set once at boot. */
static uintptr_t   g_libc_wva;
static uint32_t    g_libc_wsize;
static const void *g_libc_snap;
static char       *g_libc_share;   /* the ONE shared pristine libc-data copy (COW source) */
/* Register libc.so's data/bss as COW. Build ONE shared pristine copy (page-aligned
 * with the data at its TRUE sub-page offset — libc's writable seg starts at a
 * non-page-aligned VA, e.g. ...c58, so mapping a page-aligned VA straight to
 * snapshot[0] would shift every pointer/GOT entry and crash). All processes map
 * this block shared-RO and COW on first write (malloc updating its arena, etc.). */
void vm_set_libc(uintptr_t wva, uint32_t wsize, const void *snapshot)
{
    g_libc_wva = wva; g_libc_wsize = wsize; g_libc_snap = snapshot;
    if (!wva || !snapshot) return;
    uint32_t first = (uint32_t)wva & ~0xFFFu;
    uint32_t last  = ((uint32_t)wva + wsize - 1u) & ~0xFFFu;
    uint32_t npg   = (last - first) / 0x1000u + 1u;
    char *s = frtos_alloc(npg * 0x1000u, 0x1000, NULL);
    if (!s) return;
    memset(s, 0, npg * 0x1000u);
    memcpy(s + ((uint32_t)wva - first), snapshot, wsize);
    g_libc_share = s;
    vm_cow_register(first, npg * 0x1000u, (uint32_t)s);
}

/* Build space `idx`'s table (ASID = idx+1; 0 = kernel/master): copy the master,
 * give the process (b) a demand-zero heap section and per-process COW copies of
 * the global ranges (libc data, the synthetic demo) plus (if any) the spawning
 * program's own data range — mapped shared READ-ONLY at their pristine source
 * until first write. All non-global (ASID-tagged). Drop stale TLB for the ASID. */
static void map_cow_range(int idx, uint32_t *t, const cow_rng *r)
{
    /* build a per-process L2 for each 1 MB section the range spans (seeded from the
     * master so shared text/rodata/GOT pages in the same section keep their mapping)
     * and mark the range's pages READ-ONLY -> the shared source, preserving each
     * page's XN bit (W^X for program data). */
    for (uint32_t va = r->va; va < r->end; va += 0x1000u) {
        uint32_t *l2 = perproc_l2(idx, t, va >> 20);
        if (!l2) break;
        uint32_t i  = L2_IDX(va);
        uint32_t xn = l2[i] & 0x1u;                       /* keep XN from the master mapping */
        l2[i] = (L2_PAGE_RO(r->src + (va - r->va)) & ~0x1u) | xn;
    }
}

uint32_t *vm_space_create(int idx, uint32_t prog_va, uint32_t prog_size, uint32_t prog_src)
{
    uint32_t *t    = space_l1[idx];
    uint32_t  asid = (uint32_t)idx + 1u;
    memcpy(t, mmu_master_table(), 4096 * sizeof(uint32_t));
    space_l2n[idx] = 0;                        /* fresh per-space L2 pool */

    /* (b) private heap: an L2 with every page faulting -> zero-filled ON DEMAND
     * (T2-c). Physical is consumed only for pages the process actually touches. */
    {
        uint32_t *hl2 = space_l2_heap[idx];
        memset(hl2, 0, 256 * sizeof(uint32_t));
        t[XTOS_HEAP_VA >> 20] = L1_COARSE(hl2);
    }

    /* global COW ranges (libc data, synthetic demo) */
    for (int r = 0; r < g_cow_n; r++) map_cow_range(idx, t, &g_cow_rng[r]);

    /* the program's own data range (its identity load VA; COW source = the program
     * image itself, which the kernel never writes so it stays pristine). */
    g_space_prog[idx].va = g_space_prog[idx].end = g_space_prog[idx].src = 0;
    if (prog_va && prog_size) {
        g_space_prog[idx].va  = prog_va & ~0xFFFu;
        g_space_prog[idx].end = (prog_va + prog_size + 0xFFFu) & ~0xFFFu;
        g_space_prog[idx].src = (prog_src ? prog_src : prog_va) & ~0xFFFu;
        map_cow_range(idx, t, &g_space_prog[idx]);
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
    __asm__ volatile("mcr p15,0,%0,c2,c0,0"  :: "r"((uint32_t)table | XTOS_TTBR_ATTR)); /* TTBR0 (cacheable walks) */
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

/* copy-on-write fault: a WRITE permission-faulted at `va` in space `idx`. If `va`
 * is in a registered COW range and its page is present + read-only, make a private
 * copy (read the shared page through the still-valid RO mapping into a fresh page),
 * remap it RW, and return 1 to re-run the store. Returns 0 (-> fatal) for any VA
 * not under COW — so a write to read-only TEXT (W^X) is correctly killed.
 *
 * Reached only on a WRITE fault (the caller checks DFSR.WnR). Runs in the faulting
 * process's address space, so `va` reads the shared source and space_l2_*[idx] are
 * the live tables; uses the pre-reserved demand pool (no libc from the handler). */
int vm_cow_map(int idx, uint32_t va)
{
    if (!cow_owns(idx, va)) return 0;            /* not COW (e.g. W^X text) -> fatal */
    uint32_t l1e = space_l1[idx][va >> 20];
    if ((l1e & 0x3u) != 0x1u) return 0;          /* section isn't a coarse L2 */
    uint32_t *l2 = (uint32_t *)(l1e & 0xFFFFFC00u);
    uint32_t  i  = L2_IDX(va);
    uint32_t  e  = l2[i];
    if ((e & 0x3u) == 0) return 0;               /* not present -> not a COW page */
    if (!(e & (1u<<9))) return 1;                /* already RW (stale TLB) -> just re-run */
    void *pg = dpage();
    if (!pg) return 0;
    memcpy(pg, (const void *)(va & 0xFFFFF000u), 0x1000);   /* read via the RO mapping */
    /* private copy: new physical, clear AP[2] (RO->RW), keep all other attrs
     * (XN, TEX, nG, ...) so a COW'd program-data page stays execute-never (W^X). */
    l2[i] = ((uint32_t)pg & 0xFFFFF000u) | (e & 0xFFFu);
    l2[i] &= ~(1u << 9);
    g_cow_count++;
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(va & 0xFFFFF000u));  /* TLBIMVAA */
    __asm__ volatile("dsb; isb");
    return 1;
}
