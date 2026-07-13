/*
 * blittest — /dev/blitter end-to-end (Rocks RESPONSIBILITIES.md §13).
 *
 * Runs a REAL blit on the PL engine and checks the pixels, then checks the two things that
 * make the device safe rather than merely convenient:
 *
 *   - a pool-backed (scattered) surface is REFUSED. The engine accumulates base+stride and
 *     would walk off the first page into whatever followed — it would not fail, it would
 *     render garbage and corrupt memory.
 *   - an out-of-bounds rect cannot be expressed. The driver clips against the surface's own
 *     allocation, so a client cannot blit into another window's memory through the engine.
 */
#include <stdio.h>
#include <string.h>
#include "usys.h"

#define W   256
#define H   256
#define STR (W * 4)
#define SZ  (STR * H)

static int bfd;

static long submit(struct xt_blit_cmd *c)
{ return sys_write(bfd, c, sizeof *c); }

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;

    bfd = (int)sys_open("/dev/blitter", 2 /*O_RDWR*/);
    if (bfd < 0) { printf("blittest: FAIL — cannot open /dev/blitter\n"); sys_exit(1); }
    printf("blittest: /dev/blitter opened OK\n");

    /* two CONTIGUOUS surfaces: the engine has no MMU, so only these may be named */
    int sid = sys_shm_create(SZ, XT_SHM_CONTIG);
    int did = sys_shm_create(SZ, XT_SHM_CONTIG);
    if (sid < 0 || did < 0) { printf("blittest: FAIL — CONTIG create\n"); sys_exit(1); }
    volatile unsigned *sp = sys_shm_map(sid);
    volatile unsigned *dp = sys_shm_map(did);
    if (!sp || !dp) { printf("blittest: FAIL — map\n"); sys_exit(1); }

    struct xt_blit_surf ds = { sid, STR };  sys_ioctl(bfd, XT_BLIT_DECLARE, &ds);
    struct xt_blit_surf dd = { did, STR };  sys_ioctl(bfd, XT_BLIT_DECLARE, &dd);

    /* ---- 1. RECT_FILL on the hardware ---------------------------------------- */
    struct xt_blit_cmd fill = { 0 };
    fill.op = XT_BLIT_FILL; fill.dst_id = sid; fill.src_id = -1;
    fill.dx = 0; fill.dy = 0; fill.dw = W; fill.dh = H;
    fill.color = 0xC0FFEE11u;
    long seq = submit(&fill);
    /* fence: the engine is QUEUED, so "I submitted" is not "the pixels are there" */
    for (int i = 0; i < 200000; i++) {
        unsigned r = 0; sys_ioctl(bfd, XT_BLIT_SEQ, &r);
        if ((long)r >= seq) break;
    }
    unsigned f0 = sp[0], fmid = sp[(H/2)*W + W/2], flast = sp[W*H - 1];
    printf("blittest: FILL seq=%ld -> first=0x%08x mid=0x%08x last=0x%08x %s\n",
           seq, f0, fmid, flast,
           (f0 == 0xC0FFEE11u && fmid == 0xC0FFEE11u && flast == 0xC0FFEE11u)
             ? "OK (hardware filled it)" : "FAIL");

    /* ---- 2. BLOCK_BLIT src -> dst -------------------------------------------- */
    for (unsigned i = 0; i < (unsigned)(W*H); i++) dp[i] = 0;      /* clear the destination */
    struct xt_blit_cmd cp = { 0 };
    cp.op = XT_BLIT_COPY; cp.dst_id = did; cp.src_id = sid;
    cp.dx = 0; cp.dy = 0; cp.dw = W; cp.dh = H; cp.sx = 0; cp.sy = 0;
    seq = submit(&cp);
    for (int i = 0; i < 200000; i++) {
        unsigned r = 0; sys_ioctl(bfd, XT_BLIT_SEQ, &r);
        if ((long)r >= seq) break;
    }
    unsigned c0 = dp[0], cmid = dp[(H/2)*W + W/2], clast = dp[W*H - 1];
    printf("blittest: COPY seq=%ld -> first=0x%08x mid=0x%08x last=0x%08x %s\n",
           seq, c0, cmid, clast,
           (c0 == 0xC0FFEE11u && cmid == 0xC0FFEE11u && clast == 0xC0FFEE11u)
             ? "OK (hardware blitted src->dst)" : "FAIL");

    /* ---- 3. a POOL-BACKED surface must be REFUSED ----------------------------- */
    int pool = sys_shm_create(SZ, 0);                  /* scattered pages */
    if (pool >= 0) {
        sys_shm_map(pool);
        struct xt_blit_surf ps = { pool, STR }; sys_ioctl(bfd, XT_BLIT_DECLARE, &ps);
        struct xt_blit_cmd bad = fill; bad.dst_id = pool;
        long r = submit(&bad);
        printf("blittest: pool-backed surface as a blit target -> %s\n",
               r < 0 ? "REFUSED OK (engine cannot walk a page list)"
                     : "FAIL — ACCEPTED, the engine would corrupt memory");
        sys_shm_unmap(pool);
    }

    /* ---- 4. an out-of-bounds rect must not be expressible --------------------- */
    struct xt_blit_cmd oob = fill;
    oob.dst_id = did; oob.dx = 0; oob.dy = 0; oob.dw = W * 8; oob.dh = H * 8;  /* 8x the surface */
    long r2 = submit(&oob);
    /* it is clipped to the allocation, so the byte AFTER the surface must be untouched */
    unsigned char *after = (unsigned char *)dp + SZ;
    printf("blittest: 8x-oversize rect -> submit=%ld, byte past the surface = 0x%02x %s\n",
           r2, *after, (*after == 0x00) ? "OK (clipped; nothing scribbled past it)" : "FAIL — OVERRAN");

    sys_shm_unmap(sid); sys_shm_unmap(did); sys_close(bfd);
    printf("blittest: done\n");
    sys_exit(0);
}
