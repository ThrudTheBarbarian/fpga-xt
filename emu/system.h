/*
 * system.h — CPU + ANTIC + GTIA + POKEY sharing one 64 K address space.
 *
 * THE STRUCTURAL POINT: ANTIC runs INSIDE the CPU's bus-cycle callback.  It is
 * not stepped alongside the CPU — it owns the bus and hands the CPU its cycles.
 * A read callback ticks ANTIC until it yields, so a halted CPU is simply a
 * callback that takes longer to return.
 *
 * Everything that makes the fabric path hard therefore does not exist here:
 * no CDC, no two rasters with an arbitrary relative phase, no level-vs-edge
 * strobe hazard, and no /RDY sampled at a commit slot inside a 56-slot
 * subcycle window.  WSYNC and DMA stalls are not modelled — they fall out.
 */
#ifndef SYSTEM_H
#define SYSTEM_H

#include "xt6502.h"
#include "antic.h"
#include "gtia.h"
#include "pokey_rand.h"

typedef struct {
    uint8_t    ram[65536];
    xt6502     cpu;
    antic      an;
    gtia       gt;
    pokey_rand pk;
    uint64_t   cycles;

    /* Diagnosis for the RANDOM-as-a-cycle-clock path.  The ANTIC timing tests
     * measure elapsed MACHINE CYCLES between taking POKEY out of SKCTL init and
     * reading $D20A, so counting the LFSR's own ticks between those two events
     * says directly whether the system path is off, and by how much. */
    uint64_t   pk_ticks;      /* LFSR advances since reset */
    uint64_t   dbg_skctl_at;  /* pk_ticks when SKCTL last released the counters */
    uint64_t   dbg_rand_at;   /* pk_ticks at the first RANDOM read after that */
    int        dbg_rand_seen;
    int        dbg_trace;     /* >0: print this many more bus accesses */
} atari;

void atari_init(atari *s);
void atari_step(atari *s);     /* one CPU instruction, with ANTIC running under it */

#endif /* SYSTEM_H */
