/* bssbench.c — the SAME loops as memprobe.c, but built the way a LIBC PROGRAM is
 * built (main(), DT_NEEDED libc.so) rather than as a raw applet (_app_entry,
 * -nostdlib, no libc).
 *
 * Why: memprobe measured the A9 at 9.35 ns/iter compute and 7.8 ns/iter over a
 * 64 KB static array — caches plainly working, ~6-7x the Mac — and that number is
 * what the whole "~35x realtime is affordable" argument rests on.  But the
 * software Atari (a libc program) then measured ~500x slower than the Mac, not
 * 6-7x.  memprobe and that program are loaded by DIFFERENT paths, so before
 * blaming the emulator, run the identical loops through the OTHER path.
 *
 * If the numbers here are far worse than memprobe's, the fault is in how the
 * loader maps a libc program's writable segment — cacheability, most likely —
 * and it costs EVERY libc program on the system, not just this one.
 * If they match memprobe, the emulator itself is the problem and this rules the
 * mapping out.
 *
 * Third loop added on purpose: the emulator's hot data is a ~64 KB array inside a
 * much larger (~423 KB) .bss, so it also walks a 256 KB array to show whether the
 * cost tracks WORKING-SET SIZE (a cache effect) or is flat (an uncached mapping).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "usys.h"

static long long now_us(void)
{
    unsigned tv[3];
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (long long)tv[0] * 1000000ll + tv[2];
}

static uint8_t small_a[4096];
static uint8_t big_a[65536];
static uint8_t huge_a[262144];

#define N 5000000L

static void bench(const char *what, uint8_t *a, uint32_t mask)
{
    volatile uint32_t sink = 0;
    uint32_t x = 12345;
    long long t0 = now_us();
    for (long i = 0; i < N; i++) { x += a[x & mask]; x = x * 1664525u + 1u; }
    long long t1 = now_us();
    sink += x;
    printf("%-22s %lld us for %ld iters = %.2f ns/iter\n",
           what, t1 - t0, N, (double)(t1 - t0) * 1000.0 / N);
    (void)sink;
}

int main(void)
{
    setvbuf(stdout, 0, _IOLBF, 0);

    volatile uint32_t sink = 0;
    uint32_t x = 12345;
    long long t0 = now_us();
    for (long i = 0; i < N; i++) { x = x * 1664525u + 1013904223u; x ^= x >> 13; }
    long long t1 = now_us();
    sink += x;
    printf("%-22s %lld us for %ld iters = %.2f ns/iter\n",
           "compute-only", t1 - t0, N, (double)(t1 - t0) * 1000.0 / N);

    bench("4KB static (.bss)",   small_a, 4095);
    bench("64KB static (.bss)",  big_a,   65535);
    bench("256KB static (.bss)", huge_a,  262143);

    /* the same 64 KB on the HEAP.  If .bss is slow and malloc is fast, the
     * writable segment's mapping is the difference and the heap's is right. */
    uint8_t *heap = malloc(65536);
    if (heap) {
        for (int i = 0; i < 65536; i++) heap[i] = (uint8_t)i;
        bench("64KB heap (malloc)", heap, 65535);
    } else {
        printf("64KB heap (malloc)     malloc failed\n");
    }
    (void)sink;
    return 0;
}
