/* Separate COMPUTE speed from MEMORY speed on the A9.  If the ratio to the Mac
 * is ~30-50x for compute but hundreds for arrays, the applet's data is in
 * UNCACHED DDR and cycbench measured memory latency, not the CPU. */
#include <stdio.h>
#include <stdint.h>
#include "usys.h"
static long long now_us(void){ unsigned tv[3]; __syscall(SYS_gettimeofday,(long)tv,0,0);
    return (long long)tv[0]*1000000ll + tv[2]; }
static uint8_t small_a[4096];
static uint8_t big_a[65536];
static void run(void)
{
    const long N = 20000000;
    volatile uint32_t sink = 0;
    long long t0,t1;
    uint32_t x = 12345;

    t0 = now_us();
    for (long i = 0; i < N; i++) { x = x*1664525u + 1013904223u; x ^= x >> 13; }
    t1 = now_us(); sink += x;
    printf("compute-only : %lld us for %ld iters = %.2f ns/iter\n",
           t1-t0, N, (double)(t1-t0)*1000.0/N);

    t0 = now_us();
    for (long i = 0; i < N; i++) { x += small_a[x & 4095]; x = x*1664525u+1u; }
    t1 = now_us(); sink += x;
    printf("4KB array    : %lld us for %ld iters = %.2f ns/iter\n",
           t1-t0, N, (double)(t1-t0)*1000.0/N);

    t0 = now_us();
    for (long i = 0; i < N; i++) { x += big_a[x & 65535]; x = x*1664525u+1u; }
    t1 = now_us(); sink += x;
    printf("64KB array   : %lld us for %ld iters = %.2f ns/iter\n",
           t1-t0, N, (double)(t1-t0)*1000.0/N);
    (void)sink;
}
void _app_entry(int argc, char **argv){ (void)argc;(void)argv; run(); sys_exit(0); }
