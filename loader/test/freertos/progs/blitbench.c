/*
 * blitbench — measure the PL blitter's copy rate vs the CPU's, on real DDR.
 *
 * The question this answers: is SRC_BLIT worth wiring into gemd's present path TODAY, or
 * does the RTL burst work ("open perf: burst it") come first? gemd's present is the CPU
 * writing ~1.5 MB of sequential UNCACHED stores per composite — the engine wins only if it
 * beats that. Run it before and after any RTL change to the blitter's AXI mastering.
 *
 *   blitbench [MB]        default 2 MB per surface (plv CONTIG, uncached)
 *
 * Reports MB/s for: engine COPY (queued, fenced on the retired SEQ), CPU memcpy on the same
 * uncached buffers, and a CPU uncached fill (the present path's write half).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usys.h"

static long long now_us(void)
{
    unsigned tv[3];                                   /* tv_sec lo/hi + tv_usec (SYS 0x400) */
    __syscall(SYS_gettimeofday, (long)tv, 0, 0);
    return (long long)tv[0] * 1000000ll + tv[2];
}

static int g_bfd;

static long submit(struct xt_blit_cmd *c)             /* returns the command's SEQ (queued) */
{ return sys_write(g_bfd, c, sizeof *c); }

static void fence(long seq)                           /* the engine RETIRED up to seq */
{
    for (int i = 0; i < 5000000; i++) {
        unsigned r = 0; sys_ioctl(g_bfd, XT_BLIT_SEQ, &r);
        if ((long)r >= seq) return;
    }
    printf("blitbench: FENCE TIMED OUT\n"); sys_exit(1);
}

static int mbs(long long us, long bytes, int reps)
{ return us > 0 ? (int)(((long long)bytes * reps) / us) : 0; }   /* bytes/us == MB/s */

void _app_entry(int argc, char **argv)
{
    long mb = (argc > 1) ? atol(argv[1]) : 2;
    if (mb < 1) mb = 1;
    if (mb > 8) mb = 8;
    const int W = 1024, BPP = 4;                      /* stride 4096 B; height from the size */
    const int H = (int)(mb * 1024 * 1024) / (W * BPP);
    const long SZ = (long)W * BPP * H;
    const int REPS = 8;

    g_bfd = (int)sys_open("/dev/blitter", 2);
    if (g_bfd < 0) { printf("blitbench: no /dev/blitter (%d)\n", g_bfd); sys_exit(1); }

    int sid = sys_shm_create(SZ, XT_SHM_CONTIG);
    int did = sys_shm_create(SZ, XT_SHM_CONTIG);
    if (sid < 0 || did < 0) { printf("blitbench: CONTIG create failed (%d/%d)\n", sid, did); sys_exit(1); }
    volatile unsigned *sp = sys_shm_map(sid);
    volatile unsigned *dp = sys_shm_map(did);
    if (!sp || !dp) { printf("blitbench: map failed\n"); sys_exit(1); }

    struct xt_blit_surf ss = { sid, (unsigned)(W * BPP) };
    struct xt_blit_surf ds = { did, (unsigned)(W * BPP) };
    if (sys_ioctl(g_bfd, XT_BLIT_DECLARE, &ss) < 0 ||
        sys_ioctl(g_bfd, XT_BLIT_DECLARE, &ds) < 0) { printf("blitbench: DECLARE failed\n"); sys_exit(1); }

    for (long i = 0; i < SZ / 4; i++) sp[i] = 0xFF00FF00u ^ (unsigned)i;

    /* --- engine: COPY x REPS, fence on the last SEQ ----------------------------------- */
    struct xt_blit_cmd c; memset(&c, 0, sizeof c);
    c.op = XT_BLIT_COPY; c.dst_id = did; c.src_id = sid;
    c.dx = 0; c.dy = 0; c.dw = (uint16_t)W; c.dh = (uint16_t)H; c.sx = 0; c.sy = 0;
    long seq = 0;
    long long t0 = now_us();
    for (int r = 0; r < REPS; r++) {
        seq = submit(&c);
        if (seq < 0) { printf("blitbench: submit FAILED (%ld)\n", seq); sys_exit(1); }
        fence(seq);                                    /* serialize: measure the ENGINE, not the queue */
    }
    long long t1 = now_us();
    if (dp[0] != sp[0] || dp[SZ/4 - 1] != sp[SZ/4 - 1]) printf("blitbench: VERIFY FAILED\n");

    /* --- CPU: memcpy on the same uncached buffers ------------------------------------- */
    long long t2 = now_us();
    for (int r = 0; r < REPS; r++) memcpy((void *)dp, (const void *)sp, (size_t)SZ);
    long long t3 = now_us();

    /* --- CPU: pure uncached WRITES (the present path's write half) -------------------- */
    long long t4 = now_us();
    for (int r = 0; r < REPS; r++) for (long i = 0; i < SZ / 4; i++) dp[i] = 0x12345678u;
    long long t5 = now_us();

    printf("blitbench: %dx%d (%ld KB) x%d\n", W, H, SZ / 1024, REPS);
    printf("  engine COPY (fenced)  : %5d MB/s\n", mbs(t1 - t0, SZ, REPS));
    printf("  cpu memcpy (uncached) : %5d MB/s\n", mbs(t3 - t2, SZ, REPS));
    printf("  cpu fill   (uncached) : %5d MB/s\n", mbs(t5 - t4, SZ, REPS));
    sys_exit(0);
}
