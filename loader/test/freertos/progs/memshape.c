/* memshape.c — is the 10x between memprobe and bssbench the MEMORY or the CODE?
 *
 * memprobe reads 15.6 ns/iter for BOTH a 4 KB and a 64 KB array — flat, which
 * cannot be right if the 64 KB one is really being touched (it exceeds the 32 KB
 * L1 D-cache, so a dependent random load should cost far more). bssbench, same
 * board, same session, reads 34.9 / 168 for the same two sizes.
 *
 * The two differ in exactly two ways and this file separates them:
 *   memprobe: file-scope array, COMPILE-TIME CONSTANT mask, loop inlined in run()
 *   bssbench: pointer + runtime mask passed to a non-inlined bench()
 *
 * So run BOTH shapes over the SAME arrays in ONE program at ONE optimisation
 * level. If the constant-mask shape reads ~15 ns and the pointer shape ~168 ns
 * over the very same 64 KB, the difference is CODEGEN and there is no memory
 * mystery — the emulator is simply memory-bound. If both read ~168, memprobe's
 * flat number is an artefact of something else and the mystery stands.
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

static uint8_t small_a[4096];
static uint8_t big_a[65536];

#define N 5000000L

/* the bssbench shape: opaque pointer, runtime mask, NOT inlined */
__attribute__((noinline))
static void bench_ptr(const char *what, uint8_t *a, uint32_t mask)
{
    volatile uint32_t sink = 0;
    uint32_t x = 12345;
    long long t0 = now_us();
    for (long i = 0; i < N; i++) { x += a[x & mask]; x = x * 1664525u + 1u; }
    long long t1 = now_us();
    sink += x;
    printf("%-26s %.2f ns/iter\n", what, (double)(t1 - t0) * 1000.0 / N);
    (void)sink;
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    volatile uint32_t sink = 0;
    uint32_t x;
    long long t0, t1;

    /* the memprobe shape: file-scope array, constant mask, inlined right here */
    x = 12345; t0 = now_us();
    for (long i = 0; i < N; i++) { x += small_a[x & 4095]; x = x * 1664525u + 1u; }
    t1 = now_us(); sink += x;
    printf("%-26s %.2f ns/iter\n", "4KB  const-mask inline", (double)(t1 - t0) * 1000.0 / N);

    x = 12345; t0 = now_us();
    for (long i = 0; i < N; i++) { x += big_a[x & 65535]; x = x * 1664525u + 1u; }
    t1 = now_us(); sink += x;
    printf("%-26s %.2f ns/iter\n", "64KB const-mask inline", (double)(t1 - t0) * 1000.0 / N);

    /* the same arrays through the other shape */
    bench_ptr("4KB  ptr+runtime mask",  small_a, 4095);
    bench_ptr("64KB ptr+runtime mask",  big_a,   65535);

    /* and once more with the 64 KB array WRITTEN, so its pages are real and
     * distinct rather than possibly-shared demand-zero */
    for (int i = 0; i < 65536; i++) big_a[i] = (uint8_t)i;
    x = 12345; t0 = now_us();
    for (long i = 0; i < N; i++) { x += big_a[x & 65535]; x = x * 1664525u + 1u; }
    t1 = now_us(); sink += x;
    printf("%-26s %.2f ns/iter\n", "64KB const-mask, WRITTEN", (double)(t1 - t0) * 1000.0 / N);
    bench_ptr("64KB ptr+mask,   WRITTEN", big_a, 65535);

    (void)sink;
    sys_exit(0);
}
