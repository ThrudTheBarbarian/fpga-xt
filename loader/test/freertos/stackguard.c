/*
 * stackguard.c — process stack provisioning (tier-2, T2-c).
 *
 * Step 1: spawned tasks run on STATIC stacks (one slot per process) so we can
 * later place an unmapped guard page below each. This file first just proves
 * static-stack spawn/exit/teardown is solid; the guard arena + overflow handling
 * layer on top once that's green.
 */
#include <stdint.h>
#include "FreeRTOS.h"
#include "task.h"
#include "timers.h"

#define MAXSLOT     8                       /* must match MAXPROC */
#define STACK_WORDS 16384                   /* 64 KB (FreeType is stack-hungry) */

static StackType_t g_stacks[MAXSLOT][STACK_WORDS] __attribute__((aligned(8)));

StackType_t *stackguard_stack(int slot, uint32_t *words_out)
{
    if (words_out) *words_out = STACK_WORDS;
    return g_stacks[slot];
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
