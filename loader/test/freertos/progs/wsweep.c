/* wsweep.c — where are this A9's cache cliffs, really?
 *
 * The arithmetic that motivates it: the software Atari runs at 22.1 K emulated
 * 6502 cycles/s on the board = 45.2 us per emulated cycle, against 90 ns on the
 * Mac.  At the measured ~244 ns per dependent access that is ~185 memory touches
 * per emulated cycle, which is plausible for a per-cycle design (GTIA's obj_step
 * alone walks 4 players x up to 8 runs, twice per machine cycle).  So most of the
 * 500x is the Mac's caches holding a 423 KB working set that the A9's 32 KB L1
 * cannot.  Fine, and not a bug.
 *
 * What does NOT fit: 64 KB costing 244 ns.  The PL310 L2 is 512 KB, so a 64 KB
 * set should be L2-resident at roughly 30-45 ns.  244 ns is DRAM.  If the curve
 * below shows a cliff at ~32 KB (L1) and then NO plateau anywhere before DRAM,
 * the outer cache is not serving these pages and that is worth ~6x to every
 * program on the system.  If instead it plateaus around 64-512 KB, the L2 is
 * working and 244 ns simply is what a dependent miss costs here.
 *
 * THE ARRAY MUST ESCAPE.  memprobe's numbers were meaningless because its arrays
 * were file-scope statics that were never written and never had their address
 * taken, so gcc proved them all-zero and deleted the loads -- 4 KB and 64 KB both
 * "15.6 ns", faster than its own compute-only loop.  Here every buffer is written
 * first (so the pages are real and distinct, not shared demand-zero) and is
 * passed through a noinline function (so the load cannot be folded).
 */
#include <stdint.h>
#include <stdio.h>

#include "usys.h"

static long long now_us(void)
{
    unsigned tv[3];
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (long long)tv[0] * 1000000ll + tv[2];
}

#define MAXB (1u << 20)          /* 1 MB, comfortably past the 512 KB L2 */
static uint8_t arena[MAXB];

#define N 2000000L

__attribute__((noinline))
static double walk(uint8_t *a, uint32_t mask)
{
    volatile uint32_t sink = 0;
    uint32_t x = 12345;
    long long t0 = now_us();
    for (long i = 0; i < N; i++) { x += a[x & mask]; x = x * 1664525u + 1u; }
    long long t1 = now_us();
    sink += x;
    (void)sink;
    return (double)(t1 - t0) * 1000.0 / N;
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;

    /* write the whole arena: real, distinct pages -- no demand-zero sharing */
    for (unsigned i = 0; i < MAXB; i++) arena[i] = (uint8_t)i;

    printf("working set   ns/iter\n");
    for (unsigned kb = 4; kb <= MAXB / 1024u; kb <<= 1) {
        unsigned bytes = kb * 1024u;
        printf("%6u KB   %8.2f\n", kb, walk(arena, bytes - 1u));
    }

    /* baseline: same loop, no memory at all, so the memory cost can be separated */
    volatile uint32_t sink = 0;
    uint32_t x = 12345;
    long long t0 = now_us();
    for (long i = 0; i < N; i++) { x = x * 1664525u + 1u; }
    long long t1 = now_us();
    sink += x; (void)sink;
    printf("  compute    %8.2f\n", (double)(t1 - t0) * 1000.0 / N);

    sys_exit(0);
}
