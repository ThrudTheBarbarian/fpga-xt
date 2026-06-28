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
#define PRIV_VA    0x1FF00000u           /* top pool section, repurposed per-process */
#define PRIV_SEC   (PRIV_VA >> 20)       /* L1 index 0x1FF */
#define L2_IDX(va) (((va) >> 12) & 0xFF) /* L2 (4KB page) index within a section */

/* L2 small-page (4KB) descriptor: Normal non-cacheable, AP=11 (full), nG=1
 * (ASID-tagged), XN=0. bits: nG[11] | AP[5:4]=11 | TEX[8:6]=001 | type=10 */
#define L2_PAGE(phys) (((phys) & 0xFFFFF000u) | (1u<<11) | (3u<<4) | (1u<<6) | 0x2u)
/* L1 coarse descriptor pointing at an L2 table (domain 0) */
#define L1_COARSE(l2) (((uint32_t)(l2) & 0xFFFFFC00u) | 0x1u)

extern uint32_t *mmu_master_table(void);

static uint32_t  space_l1[NSPACE][4096] __attribute__((aligned(16384)));
static uint32_t  space_l2[NSPACE][256]  __attribute__((aligned(1024)));  /* one L2 / space (private section) */
static uint32_t *g_cur_table;            /* currently-active TTBR0 table */
static uint32_t  g_cur_asid;

/* Build space `idx`'s table (ASID = idx+1; 0 is the kernel/master): copy the
 * master, then map a single private 4 KB page at PRIV_VA via an L2 table — fine
 * (page) granularity is what real per-process libc data / heaps / guard pages
 * need. The page is non-global (ASID-tagged); the rest of the section faults.
 * Drop any stale TLB entries for this reused ASID. */
uint32_t *vm_space_create(int idx)
{
    uint32_t *t  = space_l1[idx];
    uint32_t *l2 = space_l2[idx];
    uint32_t  asid = (uint32_t)idx + 1u;
    memcpy(t, mmu_master_table(), 4096 * sizeof(uint32_t));

    memset(l2, 0, 256 * sizeof(uint32_t));            /* all pages fault by default */
    void *priv = frtos_alloc(0x1000, 0x1000, NULL);   /* one 4 KB private page */
    if (priv) {
        memset(priv, 0, 0x1000);
        l2[L2_IDX(PRIV_VA)] = L2_PAGE((uint32_t)priv);
        t[PRIV_SEC] = L1_COARSE(l2);                  /* section now an L2 (page) table */
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
}
