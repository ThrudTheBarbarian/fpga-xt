/*
 * stackguard.c — guard pages for process stacks (tier-2, T2-c).
 *
 * Spawned tasks run on stacks carved from a dedicated 1 MB arena whose page table
 * leaves an UNMAPPED guard page just below each slot. A stack overflow grows down
 * into the guard and takes a precise data abort instead of silently corrupting
 * whatever sits below. One L2 covers the arena, built once at boot; slot =
 * process index (no per-spawn page-table surgery). Inherited by every per-process
 * table (vm_space_create copies the master after stackguard_init runs).
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "timers.h"

extern uint32_t *mmu_master_table(void);

#define MAXSLOT     8                       /* must match MAXPROC */
#define SLOT_GUARD  0x1000u                 /* 4 KB guard (unmapped) */
#define SLOT_STACK  0x10000u                /* 64 KB stack (FreeType is stack-hungry) */
#define SLOT_SIZE   (SLOT_GUARD + SLOT_STACK)

/* one 1 MB section (owns the whole section so the guard holes hit only us) */
static uint8_t  g_arena[0x100000] __attribute__((aligned(0x100000)));
static uint32_t g_arena_l2[256]   __attribute__((aligned(1024)));

/* per-slot emergency stack: on a stack OVERFLOW the task's own stack is the
 * casualty, so the fault handler points its SP here before running the kill thunk
 * (xtos_task_fault_exit), which needs a valid stack to give the semaphore + delete. */
static uint8_t  g_emerg[MAXSLOT][2048] __attribute__((aligned(8)));
uint32_t stackguard_emerg_top(int slot) { return (uint32_t)g_emerg[slot] + sizeof g_emerg[slot]; }

/* Normal non-cacheable, XN small page, nG=1 (ASID-tagged). AP under AFE=1:
 * STK_PAGE = AP=01 (PL0+PL1 RW) — a process's own stack; STK_NONE = AP=00 (PL1 RW,
 * PL0 none) — another process's stack, unreachable from PL0. (AF=bit4 set in both.)
 *
 * nG (bit 11) is REQUIRED: proc_launch's copy_argv writes the CHILD's stack while
 * the SPAWNER's space is active (a PL0 spawn runs the SVC handler in the parent's
 * space, where the child's slot is STK_NONE = PL0-none). Were these pages global,
 * that walk would cache a GLOBAL TLB entry carrying the parent's restrictive perms,
 * which then SHADOWS the child's own PL0-RW mapping on real hardware -> the child
 * faults writing its own stack. qemu's TLB model doesn't show the shadow, so it only
 * bit on metal. ASID-tagging keeps each space's view separate — matches vm.c's
 * L2_PAGE, which is nG for exactly this reason. */
#define STK_PAGE(phys) (((phys) & 0xFFFFF000u) | (1u << 11) | (3u << 4) | (1u << 6) | 0x3u)
#define STK_NONE(phys) (((phys) & 0xFFFFF000u) | (1u << 11) | (1u << 4) | (1u << 6) | 0x3u)

void stackguard_init(void)
{
    uint32_t sec = (uint32_t)g_arena >> 20;
    for (uint32_t i = 0; i < 256; i++)
        g_arena_l2[i] = STK_PAGE((sec << 20) + i * 0x1000u);    /* identity-map the section */
    for (int s = 0; s < MAXSLOT; s++)
        g_arena_l2[(s * SLOT_SIZE) >> 12] = 0;                  /* punch a guard hole per slot */
    mmu_master_table()[sec] = ((uint32_t)g_arena_l2 & 0xFFFFFC00u) | 0x1u;  /* L1 -> coarse L2 */
    __asm__ volatile("dsb");
    __asm__ volatile("mcr p15,0,%0,c8,c7,0" :: "r"(0u));        /* flush TLB (section changed) */
    __asm__ volatile("dsb; isb");
}

/* Build space `slot`'s PRIVATE view of the stack-arena section into `l2`: ONLY this
 * slot's stack pages are PL0-RW, every other slot's pages are PL0-none, and the
 * guard pages stay faulting. So a PL0 process can read/write its own stack and
 * NOTHING else's — closing the cross-process stack read/write (a write into another
 * task's saved context would otherwise be a privilege-escalation vector). Returns
 * the arena's 1 MB section index (the caller installs the coarse L1 entry). The
 * kernel/master keeps the full g_arena_l2 (PL1) for proc_launch's argv writes. */
uint32_t stackguard_build_l2(int slot, uint32_t *l2)
{
    uint32_t sec = (uint32_t)g_arena >> 20;
    for (uint32_t i = 0; i < 256; i++) l2[i] = STK_NONE((sec << 20) + i * 0x1000u);
    uint32_t base = (uint32_t)slot * SLOT_SIZE + SLOT_GUARD;     /* this slot's stack */
    for (uint32_t p = 0; p < SLOT_STACK; p += 0x1000u)
        l2[(base + p) >> 12] = STK_PAGE((sec << 20) + base + p); /* -> PL0-RW */
    l2[((uint32_t)slot * SLOT_SIZE) >> 12] = 0;                  /* this slot's guard: fault */
    return sec;
}

/* the stack buffer for `slot` (the guard page sits immediately below it). */
StackType_t *stackguard_stack(int slot, uint32_t *words_out)
{
    if (words_out) *words_out = SLOT_STACK / sizeof(StackType_t);
    return (StackType_t *)(g_arena + (uint32_t)slot * SLOT_SIZE + SLOT_GUARD);
}

/* is `va` inside any slot's guard page? (for a "stack overflow" diagnosis) */
int stackguard_is_guard(uint32_t va)
{
    uint32_t a = (uint32_t)g_arena;
    if (va < a || va >= a + 0x100000u) return 0;
    return ((va - a) % SLOT_SIZE) < SLOT_GUARD;
}

/* --- static-allocation plumbing (required once STATIC_ALLOCATION is on) --- */
static StaticTask_t g_idle_tcb;
static StackType_t  g_idle_stk[configMINIMAL_STACK_SIZE];
void vApplicationGetIdleTaskMemory(StaticTask_t **tcb, StackType_t **stk, uint32_t *n)
{ *tcb = &g_idle_tcb; *stk = g_idle_stk; *n = configMINIMAL_STACK_SIZE; }

static StaticTask_t g_timer_tcb;
static StackType_t  g_timer_stk[configTIMER_TASK_STACK_DEPTH];
void vApplicationGetTimerTaskMemory(StaticTask_t **tcb, StackType_t **stk, uint32_t *n)
{ *tcb = &g_timer_tcb; *stk = g_timer_stk; *n = configTIMER_TASK_STACK_DEPTH; }
