/*
 * prof.h — where do the 2,570 host instructions per emulated 6502 cycle go?
 *
 * The A9 runs this emulator at ~52 K emulated cycles/s against the Mac's 11.4 M,
 * and the PMU says why in aggregate: 2,570 instructions per emulated cycle at
 * IPC 0.19, with the data cache hitting 99.9% of the time. What the aggregate
 * does NOT say is which subsystem those instructions belong to, and that single
 * fact decides whether the event-scheduled rewrite is worth doing:
 *
 *   - If most of it is ANTIC/GTIA/POKEY stepping every cycle to discover that
 *     nothing changed, that work can be SCHEDULED AWAY rather than executed, and
 *     the ~36x needed for realtime is plausible.
 *   - If most of it is the 6502 core itself, that work is irreducible — a 6502
 *     instruction has to be fetched, decoded and executed no matter how the
 *     surrounding machine is modelled — and no amount of event scheduling helps.
 *
 * So measure per subsystem rather than argue about it.
 *
 * METHOD: read the A9 cycle counter (PMCCNTR) either side of each per-cycle
 * call and accumulate. The CPU's own cost is NOT wrapped, because sys_cycle() is
 * re-entered FROM the CPU's bus access — nesting the timers would double-count.
 * It is derived instead as (total - sum of the parts), which is exact.
 *
 * COST: two MRCs per wrapped call, ~16 per emulated cycle against a 13,291-cycle
 * budget — under half a percent, and it perturbs every slot equally so the SHARES
 * stay honest. Off unless -DEMU_PROF, so the shipping build pays nothing.
 */
#ifndef EMU_PROF_H
#define EMU_PROF_H

#if defined(EMU_PROF) && defined(__XTOS__)

#define PROF_ANTIC   0
#define PROF_RENDER  1
#define PROF_PMLATCH 2
#define PROF_PRAND   3
#define PROF_PTIMER  4
#define PROF_SIO     5
#define PROF_IRQ     6
#define PROF_PHANTOM 7
#define PROF_PF      8   /* antic_pf_* playfield lookup */
#define PROF_GTIA    9   /* gtia_clock: players/missiles/priority */
#define PROF_N       10

/* Plain event counters, separate from the cycle timers: "how often does this
 * path run" is a different question from "how long does it take", and the idle
 * fast paths added to gtia.c are only worth anything if they actually FIRE. */
#define PROFC_OBJ_IDLE  0   /* obj_step: player had no runs and no trigger */
#define PROFC_OBJ_FULL  1   /* obj_step: full run-walk                     */
#define PROFC_CLK_EARLY 2   /* gtia_clock: returned early, nothing lit     */
#define PROFC_CLK_FULL  3   /* gtia_clock: something was lit               */
#define PROFC_N         4
extern unsigned long long prof_c[PROFC_N];
extern const char *const prof_cname[PROFC_N];
#define PROF_COUNT(i) (prof_c[i]++)

extern unsigned long long prof_acc[PROF_N];
extern unsigned long long prof_cnt[PROF_N];
extern const char *const prof_name[PROF_N];

static inline unsigned prof_now(void)
{
    unsigned v;
    __asm__ volatile("mrc p15,0,%0,c9,c13,0" : "=r"(v));   /* PMCCNTR */
    return v;
}

/* PMCCNTR wraps every ~6.4 s, but each interval here is tens of cycles, so the
 * unsigned difference is correct across a wrap. */
#define PROF_BEG(slot) unsigned prof_t_##slot = prof_now()
#define PROF_END(slot) do { prof_acc[slot] += (unsigned)(prof_now() - prof_t_##slot); \
                            prof_cnt[slot]++; } while (0)
#else
#define PROF_BEG(slot) do { } while (0)
#define PROF_END(slot) do { } while (0)
#define PROF_COUNT(i)  do { } while (0)
#endif

#endif /* EMU_PROF_H */
