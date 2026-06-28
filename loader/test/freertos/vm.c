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
 * T2-b.1: correctness first — invalidate the TLB on every table change (skipped
 * when the table is unchanged). ASID-tagged switching (no flush) is the follow-on.
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

extern uint32_t *mmu_master_table(void);

static uint32_t  space_l1[NSPACE][4096] __attribute__((aligned(16384)));
static uint32_t *g_cur_table;            /* currently-active TTBR0 table */

/* Build space `idx`'s table: copy the master, then point PRIV_VA at a fresh,
 * zeroed private 1 MB (from the libc pool via frtos_alloc). Returns the table. */
uint32_t *vm_space_create(int idx)
{
    uint32_t *t = space_l1[idx];
    uint32_t *m = mmu_master_table();
    memcpy(t, m, 4096 * sizeof(uint32_t));

    void *priv = frtos_alloc(0x100000, 0x100000, NULL);   /* 1 MB-aligned physical */
    if (priv) {
        memset(priv, 0, 0x100000);
        t[PRIV_SEC] = ((uint32_t)priv & 0xFFF00000u) | (m[PRIV_SEC] & 0x000FFFFFu); /* keep attrs */
    }
    return t;
}

/* Point TTBR0 at `table` (NULL = master). Flush the TLB only when it changes. */
void vm_switch(uint32_t *table)
{
    if (!table) table = mmu_master_table();
    if (table == g_cur_table) return;
    g_cur_table = table;
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c2,c0,0" :: "r"((uint32_t)table));  /* TTBR0 */
    __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));              /* invalidate unified TLB */
    __asm__ volatile("dsb; isb");
}
