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
#define SEC_NG     (1u << 17)            /* section descriptor nG bit (ASID-tagged) */

extern uint32_t *mmu_master_table(void);

static uint32_t  space_l1[NSPACE][4096] __attribute__((aligned(16384)));
static uint32_t *g_cur_table;            /* currently-active TTBR0 table */
static uint32_t  g_cur_asid;

/* Build space `idx`'s table (ASID = idx+1; 0 is the kernel/master): copy the
 * master, then point PRIV_VA at a fresh zeroed private 1 MB, marked non-global so
 * it is ASID-tagged. Drop any stale TLB entries for this reused ASID. */
uint32_t *vm_space_create(int idx)
{
    uint32_t *t = space_l1[idx];
    uint32_t *m = mmu_master_table();
    uint32_t  asid = (uint32_t)idx + 1u;
    memcpy(t, m, 4096 * sizeof(uint32_t));

    void *priv = frtos_alloc(0x100000, 0x100000, NULL);   /* 1 MB-aligned physical */
    if (priv) {
        memset(priv, 0, 0x100000);
        t[PRIV_SEC] = ((uint32_t)priv & 0xFFF00000u) | (m[PRIV_SEC] & 0x000FFFFFu) | SEC_NG;
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
