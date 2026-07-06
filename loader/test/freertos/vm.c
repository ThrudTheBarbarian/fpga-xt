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

#define NSPACE     64      /* must match MAXPROC (frtos_os.c) */
#define STK_ARENA_MAXSECS 8 /* must match stackguard.c ceiling */
#define L2_IDX(va) (((va) >> 12) & 0xFF) /* L2 (4KB page) index within a section */
#define HEAP_SECS  (XTOS_HEAP_SIZE >> 20) /* heap spans this many 1 MB sections */

/* L2 small-page (4KB) descriptor: Normal non-cacheable, AP=11 (full), nG=1
 * (ASID-tagged), XN=0. bits: nG[11] | AP[5:4]=11 | TEX[8:6]=001 | type=10 */
/* Normal WB-WA cacheable (TEX=001 C=1 B=1), AP=11 (full), nG=1, XN=0 */
#define L2_PAGE(phys) (((phys) & 0xFFFFF000u) | (1u<<11) | (3u<<4) | (1u<<6) | (1u<<3) | (1u<<2) | 0x2u)
/* same, but read-only (AP[2]=1 -> AP=111): a write faults (the COW trigger) */
#define L2_PAGE_RO(phys) (L2_PAGE(phys) | (1u<<9))
/* PL0-NONE identity page (AP=01: PL1 RW, PL0 none), nG, XN, cacheable — the
 * per-process background for an overridden section: pages a process must not reach
 * at PL0 (only its COW/window pages, set separately, are PL0-accessible). */
#define L2_KERN(phys) (((phys) & 0xFFFFF000u) | (1u<<11) | (1u<<4) | (1u<<6) | (1u<<3) | (1u<<2) | 0x1u | 0x2u)
/* L1 coarse descriptor pointing at an L2 table (domain 0) */
#define L1_COARSE(l2) (((uint32_t)(l2) & 0xFFFFFC00u) | 0x1u)
/* per-process heap: a section mapped to private physical, non-global */
#define SEC_NG(phys, attr) (((phys) & 0xFFF00000u) | (attr) | (1u<<17))

extern uint32_t *mmu_master_table(void);
extern void klog(const char *s); extern void klog_u(unsigned v);   /* diagnostic log -> /tmp */

static uint32_t  space_l1[NSPACE][4096]     __attribute__((aligned(16384)));
static uint32_t  space_l2_heap[NSPACE][HEAP_SECS][256] __attribute__((aligned(1024)));/* heap: HEAP_SECS sections, demand-paged */
static uint32_t  space_l2_mmap[NSPACE][256] __attribute__((aligned(1024)));/* mmap window (file-backed RO) */
static uint32_t  space_l2_stk[NSPACE][STK_ARENA_MAXSECS][256] __attribute__((aligned(1024)));/* stack arena (per section): own slot only */
/* a small per-space pool of L2 tables, one per 1 MB section the space overrides
 * (libc data, program data, the synthetic demo). Section-keyed so a program and
 * libc that happen to share a 1 MB section reuse ONE L2 (no clobber, the §6
 * collision). */
#define MAXSEC 12       /* per-space overridden sections: libc + each shared lib's data
                         * + synthetic + the program's data (libs are global ranges) */
static uint32_t  space_l2pool[NSPACE][MAXSEC][256] __attribute__((aligned(1024)));
static uint16_t  space_l2sec[NSPACE][MAXSEC];   /* section number each slot maps */
static uint8_t   space_l2n[NSPACE];             /* slots used this space */
/* per-space list of pool pages charged to a space (heap + COW), for reclaim on
 * exit. MAXPP covers a full heap window (256) + COW pages; overflow stops tracking
 * (extra pages leak, never double-freed). */
#define MAXPP 320
static void     *g_space_pages[NSPACE][MAXPP];
static uint16_t  g_space_npages[NSPACE];

/* DEBUG (scp/SD corruption hunt): is `p` currently charged (COW/heap page) to ANY
 * space? A page handed to the fd page-cache / SD DMA must NEVER also be a live COW
 * page — that's the corruption. Returns space idx+1 (the owner) or 0. Linear but
 * rare-path (called at fd-cache alloc). */
int vm_page_charged(void *p)
{
    for (int s = 0; s < NSPACE; s++)
        for (int i = 0; i < g_space_npages[s]; i++)
            if (g_space_pages[s][i] == p) return s + 1;
    return 0;
}
static uint32_t  g_space_shm[NSPACE];            /* bitmap: which shm ids each space mapped (for reap) */
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
#define NCOW 12
typedef struct { uint32_t va, end, src; } cow_rng;
static cow_rng  g_cow_rng[NCOW];                 /* global ranges (synthetic, libc, libraries) */
static int      g_cow_n;
static int      g_cow_perm = -1;                 /* count of PERMANENT ranges (synthetic+libc) */
static cow_rng  g_space_prog[NSPACE];            /* the program data range of each space */
static uint32_t g_cow_count;

/* per-process mmap window: file-backed READ-ONLY mappings (romfs pages), demand-
 * paged. Each descriptor maps [va,end) RO to the file's physical pages at `src`.
 * VAs are bump-allocated in [XTOS_MMAP_VA, +SIZE); the backing is shared romfs
 * (never pool pages), so teardown just drops the descriptors. */
#define NMMAP 8
/* one mmap descriptor. va/end/src match cow_rng so the shared demand-fault logic reads
 * them the same way; the rest is backing-store (owned) + writable (dirty-via-fault) state.
 * owned: pages are POOL pages owned by the mapping (free on munmap/reap) vs shared romfs
 * physical. writable: a write-fault may flip the page RW + mark it dirty (else fatal RO).
 * fd/foff: the backing fd + file offset, for writing dirty pages back at munmap. dirty:
 * per-page dirty bitmap (bit k = page k written; capped at 64 pages = MMAP_MAXPG). */
typedef struct {
    uint32_t va, end, src;
    uint8_t  owned, writable;
    uint32_t fd, foff;
    uint64_t dirty;
} mmap_desc;
static mmap_desc g_space_maps[NSPACE][NMMAP];
static int       g_space_nmaps[NSPACE];
static uint32_t  g_space_mmap_brk[NSPACE];       /* next free VA in the window */
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
/* Drop the DYNAMIC (shared-library) ranges, keeping the permanent ones (synthetic +
 * libc). The library set is then rebuilt from the live loaded-object list after a
 * load or unload — so a library freed by an eviction stops being mapped COW. */
void vm_cow_reset_dynamic(void)
{
    if (g_cow_perm < 0) g_cow_perm = g_cow_n;   /* first call: synthetic+libc are permanent */
    g_cow_n = g_cow_perm;
}
static int cow_owns(int idx, uint32_t va)
{
    for (int i = 0; i < g_cow_n; i++)
        if (va >= g_cow_rng[i].va && va < g_cow_rng[i].end) return 1;
    return va >= g_space_prog[idx].va && va < g_space_prog[idx].end;
}
/* COW source page backing `va` (the pristine RO template), or 0 if `va` isn't in a
 * COW range. Mirrors cow_owns' search order (global lib ranges, then this space's
 * program range) so a read fault seeds from the same source map_cow_range used. */
static uint32_t cow_src_for(int idx, uint32_t va)
{
    uint32_t pg = va & ~0xFFFu;
    for (int i = 0; i < g_cow_n; i++)
        if (va >= g_cow_rng[i].va && va < g_cow_rng[i].end)
            return g_cow_rng[i].src + (pg - g_cow_rng[i].va);
    if (va >= g_space_prog[idx].va && va < g_space_prog[idx].end)
        return g_space_prog[idx].src + (pg - g_space_prog[idx].va);
    return 0;
}
uint32_t vm_cow_count(void) { return g_cow_count; }

/* DEBUG (dropbear GOT jump-to-garbage): on a fatal fault, scan every COW range of
 * space `idx` and compare each mapped page's PROCESS-VISIBLE physical (walked from
 * space_l1[idx]) against the pristine identity template (cow_src_for). Report any
 * page whose process copy holds a wild pointer (0xff-high / 0xfffffffa) the template
 * does NOT — that's the corrupted COW frame. `PRIV` = the L2 points at a private
 * copy (COW'd); `SHARED` = still the RO template (so a mismatch there means a stale
 * TLB read from a 3rd physical, since the tables agree with the template). Runs at
 * PL1 in the abort path; logs to /tmp (safe). */
void vm_dump_cow_divergence(int idx)
{
    if (idx < 0 || idx >= NSPACE) return;
    /* build the list of ranges to scan: global lib COW ranges + this space's program */
    for (int r = -1; r < g_cow_n; r++) {
        uint32_t rva, rend;
        if (r < 0) { rva = g_space_prog[idx].va; rend = g_space_prog[idx].end; }
        else       { rva = g_cow_rng[r].va;      rend = g_cow_rng[r].end;      }
        if (rva == rend) continue;
        for (uint32_t va = rva; va < rend; va += 0x1000u) {
            uint32_t l1e = space_l1[idx][va >> 20];
            if ((l1e & 0x3u) != 0x1u) continue;
            uint32_t *l2 = (uint32_t *)(l1e & 0xFFFFFC00u);
            uint32_t  e  = l2[L2_IDX(va)];
            if ((e & 0x3u) == 0) continue;
            uint32_t phys = e & 0xFFFFF000u;
            uint32_t src  = cow_src_for(idx, va) & 0xFFFFF000u;
            if (!src) continue;
            volatile uint32_t *pp = (volatile uint32_t *)phys;   /* identity, PL1-readable */
            volatile uint32_t *tp = (volatile uint32_t *)src;
            int bad = 0, firstw = -1;
            for (int w = 0; w < 1024; w++) {
                uint32_t a = pp[w], b = tp[w];
                if (a != b && (a == 0xfffffffau || (a & 0xFFF00000u) == 0xFFF00000u)) {
                    if (firstw < 0) firstw = w; bad++;
                }
            }
            if (bad) {
                klog("[cowdiv va="); klog_u(va); klog(" phys="); klog_u(phys);
                klog(" src="); klog_u(src);
                klog(phys != src ? " PRIV" : " SHARED");
                klog(" bad="); klog_u((unsigned)bad);
                klog(" @+"); klog_u((unsigned)(firstw * 4));
                klog(" pp="); klog_u(pp[firstw]);
                klog(" tp="); klog_u(tp[firstw]); klog("]\r\n");
            }
        }
    }
}

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
        for (uint32_t i = 0; i < 256; i++) l2[i] = L2_KERN((sec << 20) + i * 0x1000u);  /* PL0-none bg */
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
    g_space_npages[idx] = 0;                   /* fresh private-page charge list */
    g_space_shm[idx] = 0;                      /* fresh shm-mapping set (reap dropped the old refs) */

    /* (b) private heap: an L2 with every page faulting -> zero-filled ON DEMAND
     * (T2-c). Physical is consumed only for pages the process actually touches. */
    for (uint32_t s = 0; s < HEAP_SECS; s++) {     /* HEAP_SECS contiguous demand-paged sections */
        uint32_t *hl2 = space_l2_heap[idx][s];
        memset(hl2, 0, 256 * sizeof(uint32_t));
        t[(XTOS_HEAP_VA >> 20) + s] = L1_COARSE(hl2);
    }

    /* mmap window: an empty L2 (every page faults -> file page mapped RO on demand
     * by vm_mmap_fault). Bump + descriptors reset for the fresh space. */
    {
        uint32_t *ml2 = space_l2_mmap[idx];
        memset(ml2, 0, 256 * sizeof(uint32_t));
        t[XTOS_MMAP_VA >> 20] = L1_COARSE(ml2);
        g_space_nmaps[idx] = 0;
        g_space_mmap_brk[idx] = XTOS_MMAP_VA;
    }

    /* stack arena: a PRIVATE view exposing only THIS space's stack slot PL0-RW —
     * every other slot is PL0-none, so a process can't read or write another's
     * stack (a write into another task's saved context would be a PL1-escalation
     * vector). Overrides the shared all-slots arena L2 the master clone provided. */
    {
        extern void stackguard_build_l2(int slot, uint32_t (*l2)[256], uint32_t *l1);
        stackguard_build_l2(idx, space_l2_stk[idx], t);   /* installs the arena L1 entries too */
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

    /* TLBIALL, not TLBIASID: loading the image ran in the SPAWNER's space, whose L1
     * may still map the target sections as GLOBAL SEC_KDATA sections (they were split
     * in the master only). Those accesses cache stale GLOBAL section-level TLB entries
     * (PL0-none) that TLBIASID can't clear (they aren't ASID-tagged) and that would
     * shadow this process's correct coarse+PL0-RX mapping -> a section-level prefetch
     * abort on its first instruction (HW only; qemu doesn't model the shadow). A full
     * flush here (after the load, before the process runs) clears them. */
    (void)asid;
    __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));     /* TLBIALL: clear stale global + ASID entries */
    __asm__ volatile("dsb; isb");
    return t;
}

/* Propagate master section SPLITS into every space's L1. When a library/program loads,
 * mmu_protect splits its 1 MB SECTION (SEC_KDATA) in the MASTER into a coarse L2 (per-page
 * RO+X for the text). But a process whose L1 was copied from the master BEFORE that split
 * still maps the region as a 1 MB SECTION (PL0-none, global). While such a process runs,
 * the A9 can cache — even speculatively — a GLOBAL section-level TLB entry for that region;
 * because it's global it survives the context switch into the process that DID link the
 * library, shadows that library's correct per-page RO+X mapping, and takes a PL0 prefetch-
 * abort on the freshly-loaded code (HW only — qemu doesn't speculate; deterministic).
 * Adopting the master's split (only where a space still holds the stale SECTION; the shared
 * split L2 is the master's, so no per-process override is touched) removes the 1 MB mapping
 * everywhere, so no stale global section entry can be cached. Call after each load. */
void vm_sync_loaded_sections(void)
{
    uint32_t *m = mmu_master_table();
    for (int idx = 0; idx < NSPACE; idx++) {
        uint32_t *t = space_l1[idx];
        for (uint32_t sec = 0; sec < 4096; sec++)
            if ((m[sec] & 0x3u) == 0x1u && (t[sec] & 0x3u) == 0x2u)   /* master coarse, space still SECTION */
                t[sec] = m[sec];                                       /* adopt the shared split L2 */
    }
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));    /* TLBIALL: drop any stale section entries */
    __asm__ volatile("dsb; isb");
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

    /* Full TLB flush on every process switch. This is a deliberate SLEDGEHAMMER: the
     * image region suffers stale cross-context TLB entries — a PL0-none section shadow
     * over split code (scp: recurring prefetch-fault storm) AND a stale entry over a
     * process's private nG program-data copy (dropbear: a silent non-faulting GOT read
     * -> PLT jump to garbage). A per-range MVA flush was tried (program COW range only):
     * it fixed dropbear but left scp's CODE-page fault storm, which measured SLOWER than
     * this full flush (per-fault exception cost > the flush). So flush everything: zero
     * faults, robust, and faster in practice. Subsumes the libc-data flush below.
     * Proper long-term fix = eliminate the stale-section-shadow source (mmu.c global
     * SEC_KDATA sections over the image region), then this flush can go. */
    if (asid) {
        __asm__ volatile("dsb");
        __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));            /* TLBIALL */
        __asm__ volatile("dsb; isb");
    }

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

/* ---- T2-c physical page pool (DDR-backed) ---------------------------------
 * The CPU heap is ONE arena [0x0200_0000, 0x2000_0000) (~480 MB, docs/Zynq/
 * memory-map.md): libc malloc grows UP from the bottom via kern_sbrk; this page
 * pool grows DOWN from the top (g_pfront), and the two meet in the middle — no
 * fixed split, all of DDR available to whichever needs it. Reclaimed pages go on a
 * free list (intrusive: each free page's first word is the next pointer), so
 * dpage() prefers the list and only advances the frontier for genuinely new pages.
 *
 * The data-abort handler allocates from here WITHOUT calling libc (it runs in the
 * faulting process's address space, where libc's data is the process's private
 * copy). kern_sbrk (task context) and dpage (abort context) share the boundary, so
 * each does its check+update under a short IRQ-masked critical section — single
 * core, so masking IRQ fully serialises them (a data abort can't occur inside the
 * allocator's own non-faulting code).
 *
 * No cache maintenance on reuse: the A9 L1 D-cache is PIPT, so the pool's identity
 * VA and a process's window VA share lines for one physical, and every page is
 * re-initialised (zero-fill / COW memcpy) when handed out. */
static void    *g_dfree;                 /* head of the reclaimed-page free list */
static char    *g_pfront = (char *)0x20000000u;  /* frontier: grows DOWN; floor = heap top */
static uint32_t g_demand_count;          /* heap pages mapped on demand (cumulative) */
static uint32_t g_freelist_n;            /* pages currently on the free list */
static uint32_t g_pages_inuse;           /* pages currently handed out (issued - freed) */

extern uint32_t kern_heap_top(void);     /* libc heap's grow-up frontier (syscalls.c) */

/* libc's sbrk ceiling = the page frontier. Until vm_phys_init, g_pfront is already
 * the arena top, so the boot heap works before the pool is "announced". */
uint32_t vm_page_floor(void) { return (uint32_t)g_pfront; }
void vm_phys_init(uint32_t top) { g_pfront = (char *)top; }

uint32_t vm_demand_count(void) { return g_demand_count; }
uint32_t vm_pages_inuse(void)  { return g_pages_inuse; }
/* pages available right now: reclaimed list + the unclaimed gap down to the heap */
uint32_t vm_pages_free(void)
{
    uint32_t gap = ((uint32_t)g_pfront - kern_heap_top()) / 0x1000u;
    return g_freelist_n + gap;
}

/* allocate a raw page from the pool (NOT charged to any space). Used for shm, whose
 * pages are refcount-owned by the shm object, not a space. */
static void *dpage_raw(void)
{
    uint32_t f = xt_irq_save();
    void *p = g_dfree;
    if (p) { g_dfree = *(void **)p; g_freelist_n--; }      /* reuse a reclaimed page */
    else {                                                  /* else take from the frontier */
        char *nf = g_pfront - 0x1000u;
        /* SKIP the per-process window VA band [XTOS_HEAP_VA, XTOS_POOL_FLOOR): a pool
         * page whose identity VA lands there is shadowed per-process, so the fd
         * page-cache fill (CLIENT space) would write the wrong page — corrupting the
         * file AND spraying data into that process (root cause of the scp zero-data +
         * crashes). Pages above and below the band are safe, so jump the frontier past
         * it and keep descending toward the image-heap top.
         * TEMPORARY: reserves a 64 MB VA band. The real fix is a physical page map /
         * dynamic paging so the pool can use those frames at a non-window VA. */
        if (nf < (char *)XTOS_POOL_FLOOR && nf >= (char *)XTOS_HEAP_VA)
            nf = (char *)XTOS_HEAP_VA - 0x1000u;             /* hop below the window band */
        if (nf < (char *)kern_heap_top()) { xt_irq_restore(f); return (void *)0; }  /* arena full */
        g_pfront = nf; p = nf;
    }
    g_pages_inuse++;
    xt_irq_restore(f);
    return p;
}

/* scrub + return a raw page to the pool (undoes dpage_raw). */
static void dfree_raw(void *p)
{
    memset(p, 0, 0x1000);
    uint32_t f = xt_irq_save();
    *(void **)p = g_dfree; g_dfree = p; g_freelist_n++; g_pages_inuse--;
    xt_irq_restore(f);
}

/* raw pool page alloc/free for kernel subsystems that own their pages outside any
 * space (the fs page cache — docs/OS/fs-pagecache.md step 3c). Identity-mapped and
 * global, so a page is reachable at PL1 in every space (the fs task fills it, the
 * client copies from it). Not charged to a space: the owner frees explicitly. */
void *vm_page_alloc(void) { return dpage_raw(); }
void  vm_page_free(void *p) { if (p) dfree_raw(p); }

/* allocate a page from the pool and charge it to space `idx` (for reclaim) */
static void *dpage(int idx)
{
    void *p = dpage_raw();
    if (p && g_space_npages[idx] < MAXPP) g_space_pages[idx][g_space_npages[idx]++] = p;
    return p;
}

/* Reclaim every page this space was charged (heap demand-zero + COW copies) back to
 * the pool. Each page is SCRUBBED (zeroed) before being freed so a dead process's
 * runtime data doesn't linger on the free list — defense-in-depth for the window
 * before the page is re-initialised on its next dpage(), and against a read of the
 * page via its identity alias (until the PL0 split lands, all RAM is reachable that
 * way). Only the free-list link word (a pool address, not user data) is then
 * non-zero. Safe once the space's task is gone: its ASID isn't active, and
 * vm_space_create TLBIASIDs + rebuilds the tables on slot reuse. The A9 L1 D-cache
 * is PIPT, so the scrub via the pool's identity VA is coherent with any window VA. */
void vm_space_destroy(int idx)
{
    vm_shm_drop_space(idx);                    /* release this space's shm refs (free at last mapper) */
    /* free pool pages owned by backing-store mmaps (uncharged, so not in g_space_pages) */
    for (int m = 0; m < g_space_nmaps[idx]; m++) {
        if (!g_space_maps[idx][m].owned) continue;
        uint32_t *ml2 = space_l2_mmap[idx];
        for (uint32_t p = g_space_maps[idx][m].va; p < g_space_maps[idx][m].end; p += 0x1000u) {
            uint32_t e = ml2[L2_IDX(p)];
            if (e & 0x3u) dfree_raw((void *)(e & 0xFFFFF000u));
        }
    }
    g_space_nmaps[idx] = 0;
    for (int i = 0; i < g_space_npages[idx]; i++) {
        void *p = g_space_pages[idx][i];
        memset(p, 0, 0x1000);                 /* scrub the dead process's data */
        uint32_t f = xt_irq_save();
        *(void **)p = g_dfree; g_dfree = p;   /* push to free list (link in word 0) */
        g_freelist_n++; g_pages_inuse--;
        xt_irq_restore(f);
    }
    g_space_npages[idx] = 0;
}

/* zero-fill-on-demand: map a fresh 4KB page at `va` in space `idx`'s heap L2.
 * Called from the data-abort handler when a process touches an unmapped heap
 * page. Returns 1 if mapped (resume), 0 if not ours / pool exhausted. */
int vm_demand_map(int idx, uint32_t va)
{
    uint32_t  sec = (va - XTOS_HEAP_VA) >> 20;  /* which heap section (0..HEAP_SECS-1) */
    uint32_t *hl2 = space_l2_heap[idx][sec];
    uint32_t  i   = L2_IDX(va);
    if (hl2[i]) return 1;                       /* already present (lost race) */
    void *pg = dpage(idx);
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
    void *pg = dpage(idx);
    if (!pg) return 0;
    /* Copy from the pristine identity TEMPLATE (stable PL1 identity map), NOT via the
     * process's RO `va` mapping: under load that va can be stale-TLB-shadowed and read a
     * WRONG physical, seeding the private copy — including the loader-resolved .got.plt
     * slots — with garbage (the dropbear PLT jump-to-0xffffffff). cow_src_for gives the
     * template physical; fall back to va only if it isn't a known COW range. */
    uint32_t csrc = cow_src_for(idx, va);
    memcpy(pg, (const void *)(csrc ? csrc : (va & 0xFFFFF000u)), 0x1000);
    /* private copy: new physical, clear AP[2] (RO->RW), keep all other attrs
     * (XN, TEX, nG, ...) so a COW'd program-data page stays execute-never (W^X). */
    l2[i] = ((uint32_t)pg & 0xFFFFF000u) | (e & 0xFFFu);
    l2[i] &= ~(1u << 9);
    /* DEBUG: a COW frame must never already be a live fd page-cache page */
    { extern int frtos_cpage_live(void *); extern void klog(const char *); extern void klog_u(unsigned);
      int pid = frtos_cpage_live(pg);
      if (pid) { klog("*** COLLISION: COW frame is live fd-cache page of pid "); klog_u((unsigned)pid);
                 klog(" phys="); klog_u((unsigned)pg); klog(" ***\r\n"); } }
    g_cow_count++;
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(va & 0xFFFFF000u));  /* TLBIMVAA */
    __asm__ volatile("dsb; isb");
    return 1;
}

/* READ permission fault at `va` in a COW range (HW-only; qemu doesn't model it).
 * The demand handler only calls vm_cow_map on WRITES, so before this a READ that
 * permission-faulted here was fatal. Two causes, both non-fatal:
 *  (a) the per-process page is already PL0-readable (RO seed or a private RW copy)
 *      but a STALE TLB entry — typically a lingering GLOBAL 1 MB section mapping
 *      (PL0-none) that survived a context switch, the same class vm_sync_loaded_
 *      sections fights — shadows it. Invalidate the VA and re-run. This is what
 *      bit dropbear's exec path: reading its .got.plt (every memcpy/strlen PLT
 *      call) fataled even though the table mapped the page RW.
 *  (b) the page still holds the master's PL0-none writable descriptor (its section
 *      L2 was created fresh from the master and never seeded) — seed it RO to the
 *      COW source, then re-run. No private copy is made (that's the WRITE path).
 * Returns 1 (serviced, re-run) or 0 (not a COW range / not present -> fatal, so a
 * genuine wild read still dies). Runs in the abort handler: only L2 edits + TLB ops. */
int vm_cow_read_fault(int idx, uint32_t va)
{
    uint32_t src = cow_src_for(idx, va);
    if (!src) return 0;                              /* not COW (e.g. W^X text) -> fatal */
    uint32_t *l2 = perproc_l2(idx, space_l1[idx], va >> 20);  /* own L2 (seeds from master if new) */
    if (!l2) return 0;
    uint32_t i = L2_IDX(va), e = l2[i];
    if ((e & 0x3u) == 0) return 0;                  /* genuinely not present -> fatal */
    uint32_t before = e, seeded = e;
    if (((e >> 4) & 0x3u) == 0x1u && !(e & (1u<<9))) {   /* AP=001: master PL0-none writable */
        uint32_t xn = e & 0x1u;                          /* keep the page's XN (W^X) */
        seeded = (L2_PAGE_RO(src) & ~0x1u) | xn;
        l2[i] = seeded;                                  /* seed RO to the shared source */
    }
    /* DEBUG (dropbear GOT): watch the read-fault service for the program COW range.
     * Shows va, the src it seeds from, the L2 before/after, and the WORD the re-run
     * will read at va from both the seeded physical and the template. -> /tmp. */
    if (va >= g_space_prog[idx].va && va < g_space_prog[idx].end) {
        volatile uint32_t *sp = (volatile uint32_t *)((seeded & 0xFFFFF000u) | (va & 0xFFCu));
        volatile uint32_t *tp = (volatile uint32_t *)((src   & 0xFFFFF000u) | (va & 0xFFCu));
        klog("[cowrd va="); klog_u(va); klog(" src="); klog_u(src);
        klog(" e0="); klog_u(before); klog(" e1="); klog_u(seeded);
        klog(" @va: seeded="); klog_u(*sp); klog(" tmpl="); klog_u(*tp); klog("]\r\n");
    }
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(va & 0xFFFFF000u));  /* TLBIMVAA */
    __asm__ volatile("dsb; isb");
    return 1;
}

/* PREFETCH (instruction-fetch) permission fault at `va`. If the current space's
 * table maps that page present + EXECUTABLE (XN=0), the fetch is legal per the
 * page tables, so the fault is a STALE global 1 MB SECTION TLB entry (PL0-none)
 * shadowing the split coarse RO+X mapping — the same class vm_sync_loaded_sections
 * eliminates, re-exposed whenever a layout shift changes which task cached the
 * pre-split section. TLBIALL (drop every global + ASID entry; the tables are
 * already correct so nothing re-caches the section) and re-run. Returns 1
 * (serviced) or 0 (page not present / XN=1 genuine W^X or wild fetch -> fatal). */
int vm_exec_fault(int idx, uint32_t va)
{
    uint32_t l1e = space_l1[idx][va >> 20];
    uint32_t *l2 = (uint32_t *)(l1e & 0xFFFFFC00u);
    uint32_t  e  = ((l1e & 0x3u) == 0x1u) ? l2[L2_IDX(va)] : 0xFFFFFFFFu;
    { /* DEBUG (scp desktop-dependent pabt): does space_l1[idx] match the active TTBR0,
       * and what does vm_exec_fault see? Logs to /tmp — safe. One line per invocation:
       * count of lines at the SAME va reveals guard-trip (many) vs wrong-table (one). */
      extern void klog(const char *); extern void klog_u(unsigned);
      uint32_t ttbr; __asm__ volatile("mrc p15,0,%0,c2,c0,0" : "=r"(ttbr));
      klog("[pabt idx="); klog_u((unsigned)idx);
      klog(" va="); klog_u(va);
      klog(" ttbr="); klog_u(ttbr & 0xFFFFC000u);
      klog(" tbl="); klog_u((unsigned)(uintptr_t)space_l1[idx]);
      klog(" l1="); klog_u(l1e); klog(" l2="); klog_u(e); klog("]\r\n"); }
    if ((l1e & 0x3u) != 0x1u) return 0;             /* section isn't a coarse L2 -> fatal */
    if ((e & 0x3u) == 0) return 0;                  /* not present -> fatal */
    if (e & 0x1u)        return 0;                  /* XN=1: not executable -> fatal (real W^X) */
    __asm__ volatile("dsb");
    /* Invalidate ONLY this page's stale section-shadow (TLBIMVAA clears the covering
     * global section entry for the MVA, all ASIDs). NOT TLBIALL: that also flushed the
     * sibling code page's freshly-serviced good entry, so two code pages branching to
     * each other ping-ponged into an ENDLESS prefetch-fault livelock (HW-observed: scp
     * stuck alternating two PCs in one section, no forward progress). */
    __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(va & 0xFFFFF000u));  /* TLBIMVAA */
    __asm__ volatile("dsb; isb");
    return 1;
}

/* ---- mmap'd files (read-only, shared, demand-paged) -----------------------
 * Reserve a VA window for a file: page (va+k) will map READ-ONLY to file physical
 * (src+k) on first touch. The backing is the resident romfs (shared, one physical
 * copy across all mappers) — no copy, unlike read()-into-malloc. `src` and `size`
 * must be page-granular (romfs files are page-aligned). Returns the VA, or 0. */
uint32_t vm_mmap(int idx, uint32_t src, uint32_t size)
{
    if (!size || (src & 0xFFFu)) return 0;                   /* need a page-aligned source */
    uint32_t npg = (size + 0xFFFu) >> 12;
    uint32_t va  = g_space_mmap_brk[idx];
    if (va + npg * 0x1000u > XTOS_MMAP_VA + XTOS_MMAP_SIZE) return 0;   /* window full */
    if (g_space_nmaps[idx] >= NMMAP) return 0;
    mmap_desc *d = &g_space_maps[idx][g_space_nmaps[idx]++];
    d->va = va; d->end = va + npg * 0x1000u; d->src = src;
    d->owned = 0; d->writable = 0; d->fd = 0; d->foff = 0; d->dirty = 0;  /* shared romfs, demand-paged */
    g_space_mmap_brk[idx] = va + npg * 0x1000u;
    return va;
}

/* Install an EAGER mmap of a backing-store file (SD/ramfs): map the pre-filled pool
 * `pages` into space idx's mmap window (RO+XN for now — writable = 3c-3b dirty-via-fault)
 * at a fresh bump-allocated VA. The pages are OWNED by the mapping (freed on munmap/reap).
 * No demand fault (unlike romfs mmap): the pages are already resident, so the abort
 * handler — which can't drive FatFs — is never involved. Runs in the fs task (any space):
 * it writes space idx's L2 directly; the VA is fresh (bump) so no client TLB shadow, a dsb
 * makes the new descriptors visible before the client resumes. Returns the VA, or 0. */
uint32_t vm_mmap_install(int idx, void **pages, uint32_t npg, int writable, uint32_t fd, uint32_t foff)
{
    if (!npg) return 0;
    uint32_t va = g_space_mmap_brk[idx];
    if (va + npg * 0x1000u > XTOS_MMAP_VA + XTOS_MMAP_SIZE) return 0;
    if (g_space_nmaps[idx] >= NMMAP) return 0;
    uint32_t *ml2 = space_l2_mmap[idx];
    /* install CLEAN-but-RO even for a writable mapping: the first store faults, so
     * vm_mmap_write_fault flips it RW + marks the page dirty (dirty-via-fault — ARMv7
     * short descriptors have no HW dirty bit here). Only dirty pages get written back. */
    for (uint32_t k = 0; k < npg; k++)
        ml2[L2_IDX(va + k * 0x1000u)] = L2_PAGE_RO((uint32_t)pages[k]) | 0x1u;  /* RO + XN */
    mmap_desc *d = &g_space_maps[idx][g_space_nmaps[idx]++];
    d->va = va; d->end = va + npg * 0x1000u; d->src = 0;
    d->owned = 1; d->writable = writable ? 1 : 0; d->fd = fd; d->foff = foff; d->dirty = 0;
    g_space_mmap_brk[idx] = va + npg * 0x1000u;
    __asm__ volatile("dsb; isb");
    return va;
}

/* WRITE fault in the mmap window: if `va` is in a WRITABLE owned mapping, flip that page
 * RW and mark it dirty (dirty-via-fault), then re-run the store. Returns 1 (serviced) or
 * 0 (RO mapping / not found -> fatal). Synchronous (L2 edit + a bit) — safe in the abort
 * handler; the actual write-back happens later at munmap (needs FatFs). */
int vm_mmap_write_fault(int idx, uint32_t va)
{
    for (int m = 0; m < g_space_nmaps[idx]; m++) {
        mmap_desc *d = &g_space_maps[idx][m];
        if (va < d->va || va >= d->end || !d->owned || !d->writable) continue;
        uint32_t *ml2 = space_l2_mmap[idx];
        uint32_t  i   = L2_IDX(va);
        ml2[i] &= ~(1u << 9);                                   /* clear AP[2]: RO -> RW */
        d->dirty |= (uint64_t)1 << ((va - d->va) >> 12);        /* mark this page dirty */
        __asm__ volatile("dsb");
        __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(va & 0xFFFFF000u));  /* TLBIMVAA */
        __asm__ volatile("dsb; isb");
        return 1;
    }
    return 0;
}

/* Collect the dirty pages of the mapping at `va` for write-back: fills pages[]/foffs[]
 * (pool page + its file offset) for each dirty page, and *fd = the backing fd. Returns
 * the dirty count, or -1 if `va` isn't a writable owned mapping. The caller (fs task)
 * writes them back through the fd, then calls vm_munmap. */
int vm_mmap_dirty_plan(int idx, uint32_t va, uint32_t *fd, void **pages, uint32_t *foffs, int max)
{
    for (int m = 0; m < g_space_nmaps[idx]; m++) {
        mmap_desc *d = &g_space_maps[idx][m];
        if (d->va != va || !d->owned || !d->writable) continue;
        uint32_t *ml2 = space_l2_mmap[idx];
        int n = 0;
        for (uint32_t p = d->va; p < d->end && n < max; p += 0x1000u) {
            uint32_t k = (p - d->va) >> 12;
            if (!(d->dirty & ((uint64_t)1 << k))) continue;
            uint32_t e = ml2[L2_IDX(p)];
            if (!(e & 0x3u)) continue;
            pages[n] = (void *)(e & 0xFFFFF000u);
            foffs[n] = d->foff + (p - d->va);
            n++;
        }
        *fd = d->fd;
        return n;
    }
    return -1;
}

/* fault in the mmap window: map the faulting page READ-ONLY + execute-never to its
 * file physical page. Returns 1 (serviced) or 0 (no descriptor -> fatal). A WRITE
 * to a mapped RO page is NOT a COW range, so it stays fatal (mmap is read-only). */
int vm_mmap_fault(int idx, uint32_t va)
{
    for (int m = 0; m < g_space_nmaps[idx]; m++) {
        mmap_desc *r = &g_space_maps[idx][m];
        if (va < r->va || va >= r->end) continue;
        if (r->owned) continue;                    /* eager/backing: pages pre-installed, not demand-filled */
        uint32_t *ml2 = space_l2_mmap[idx];
        ml2[L2_IDX(va)] = L2_PAGE_RO(r->src + ((va & ~0xFFFu) - r->va)) | 0x1u;  /* RO + XN */
        __asm__ volatile("dsb");
        __asm__ volatile("mcr p15,0,%0,c8,c7,3" :: "r"(va & 0xFFFFF000u));  /* TLBIMVAA */
        __asm__ volatile("dsb; isb");
        return 1;
    }
    return 0;
}

/* drop a mapping: clear its L2 entries (the shared romfs physical is left alone)
 * and remove the descriptor. The VA window is bump-only, so VAs aren't recycled
 * until the space is rebuilt — fine for a testbed. */
int vm_munmap(int idx, uint32_t va, uint32_t size)
{
    (void)size;
    for (int m = 0; m < g_space_nmaps[idx]; m++) {
        mmap_desc *r = &g_space_maps[idx][m];
        if (va != r->va) continue;
        uint32_t *ml2 = space_l2_mmap[idx];
        for (uint32_t p = r->va; p < r->end; p += 0x1000u) {
            if (r->owned) {                                    /* backing-store: free the pool page */
                uint32_t e = ml2[L2_IDX(p)];
                if (e & 0x3u) dfree_raw((void *)(e & 0xFFFFF000u));
            }
            ml2[L2_IDX(p)] = 0;
        }
        __asm__ volatile("dsb");
        __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));   /* TLBIALL (range cleared) */
        __asm__ volatile("dsb; isb");
        g_space_maps[idx][m] = g_space_maps[idx][--g_space_nmaps[idx]];   /* compact */
        return 0;
    }
    return -1;
}

/* ---- shared memory (fs-pagecache IPC substrate) --------------------------
 * Pool-backed pages, refcounted by mappers, mapped PL0-RW into a space's SHM window
 * at a per-id 1 MB VA slot (same VA in every mapper -> portable pointers). The fs
 * service reaches the same pages by their pool IDENTITY address (no map needed on the
 * service side); only clients map. Cacheable + single-core PIPT -> the two views are
 * coherent with no maintenance. See docs/OS/fs-pagecache.md. */
#define NSHM      16
#define SHM_SLOT  (XTOS_SHM_SIZE / NSHM)     /* VA bytes per id (1 MB) */
#define SHM_MAXPG (SHM_SLOT >> 12)           /* max pages per shm (256) */
#define L2_SHM(phys) (L2_PAGE(phys) | 0x1u)  /* cacheable RW nG small page, execute-never */

typedef struct { void *pages[SHM_MAXPG]; uint32_t npages; int nref; int used; } shm_t;
static shm_t    g_shm[NSHM];                  /* g_space_shm[] declared up top (used by vm_space_create) */

/* allocate an shm of `size` bytes -> id, or -1. nref starts 0 (a mapper adds one). */
int vm_shm_create(uint32_t size)
{
    uint32_t np = (size + 0xFFFu) >> 12; if (!np) np = 1;
    if (np > SHM_MAXPG) return -1;
    uint32_t f = xt_irq_save();
    int id = -1;
    for (int i = 0; i < NSHM; i++) if (!g_shm[i].used) { g_shm[i].used = 1; id = i; break; }
    xt_irq_restore(f);
    if (id < 0) return -1;
    for (uint32_t k = 0; k < np; k++) {
        void *pg = dpage_raw();
        if (!pg) { for (uint32_t j = 0; j < k; j++) dfree_raw(g_shm[id].pages[j]);
                   g_shm[id].used = 0; return -1; }
        g_shm[id].pages[k] = pg;                       /* dpage_raw zeroes on free; scrub-on-create too */
        memset(pg, 0, 0x1000);
    }
    g_shm[id].npages = np; g_shm[id].nref = 0;
    return id;
}

/* the shm's first page by its pool IDENTITY address — how the fs service (and any PL1
 * agent, e.g. the deferral thunk marshalling a request) reaches an shm WITHOUT mapping
 * it into a space: the pool is identity-mapped and global, so this pointer is valid at
 * PL1 in every space. Returns 0 for an unused id. Used by the fs control channel
 * (docs/OS/fs-pagecache.md step 3b). */
void *vm_shm_kaddr(int id)
{
    if (id < 0 || id >= NSHM || !g_shm[id].used || !g_shm[id].npages) return 0;
    return g_shm[id].pages[0];
}

/* map shm `id` PL0-RW into space idx's SHM window -> VA (0 on failure). Idempotent per
 * space (a re-map doesn't double-count). Caller runs in space idx (its own), so the
 * TLBIALL clears any stale window entry for the freshly-installed pages. */
uint32_t vm_shm_map(int idx, int id)
{
    if (id < 0 || id >= NSHM || !g_shm[id].used) return 0;
    uint32_t va  = XTOS_SHM_VA + (uint32_t)id * SHM_SLOT;
    uint32_t *l2 = perproc_l2(idx, space_l1[idx], va >> 20);
    if (!l2) return 0;
    for (uint32_t k = 0; k < g_shm[id].npages; k++)
        l2[L2_IDX(va + k * 0x1000u)] = L2_SHM((uint32_t)g_shm[id].pages[k]);
    uint32_t f = xt_irq_save();
    if (!(g_space_shm[idx] & (1u << id))) { g_space_shm[idx] |= (1u << id); g_shm[id].nref++; }
    xt_irq_restore(f);
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));   /* TLBIALL (window pages installed) */
    __asm__ volatile("dsb; isb");
    return va;
}

/* reap hook: drop every shm this space held; free an shm's pages when its last mapper
 * goes (nref -> 0). The space's L2s + bitmap are reset by vm_space_create on reuse. */
void vm_shm_drop_space(int idx)
{
    uint32_t f = xt_irq_save();
    uint32_t bits = g_space_shm[idx]; g_space_shm[idx] = 0;
    xt_irq_restore(f);
    for (int id = 0; id < NSHM; id++) {
        if (!(bits & (1u << id))) continue;
        f = xt_irq_save();
        int free_now = (g_shm[id].nref > 0 && --g_shm[id].nref == 0);
        if (free_now) g_shm[id].used = 0;
        xt_irq_restore(f);
        if (free_now) { for (uint32_t k = 0; k < g_shm[id].npages; k++) dfree_raw(g_shm[id].pages[k]);
                        g_shm[id].npages = 0; }
    }
}
