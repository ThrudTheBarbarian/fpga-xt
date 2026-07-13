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

    /* ---- 2b. STRETCH: scaled blit, DDR -> DDR -------------------------------- */
    /* 2x2 source, upscaled 4x to 8x8. Nearest-neighbour is EXACT, so this is a real
     * assertion, not a vibe check: each 4x4 destination quadrant must equal its source
     * pixel. (The reference driver only ever scales plane->plane, so DDR->DDR scaling
     * is an untested silicon path -- which is the point of testing it.) */
    const unsigned Q[4] = { 0x11111111u, 0x22222222u, 0x33333333u, 0x44444444u };
    sp[0] = Q[0]; sp[1] = Q[1]; sp[W] = Q[2]; sp[W + 1] = Q[3];
    for (unsigned i = 0; i < 64; i++) dp[(i / 8) * W + (i % 8)] = 0;

    struct xt_blit_cmd sc = { 0 };
    sc.op = XT_BLIT_SCALE; sc.dst_id = did; sc.src_id = sid;
    sc.sx = 0; sc.sy = 0; sc.sw = 2; sc.sh = 2;
    sc.dx = 0; sc.dy = 0; sc.dw = 8; sc.dh = 8;
    seq = submit(&sc);
    if (seq < 0) { printf("blittest: STRETCH -> REJECTED by the driver FAIL\n"); }
    else {
        for (int i = 0; i < 200000; i++) {
            unsigned r = 0; sys_ioctl(bfd, XT_BLIT_SEQ, &r);
            if ((long)r >= seq) break;
        }
        unsigned q0 = dp[1 * W + 1], q1 = dp[1 * W + 6];      /* quadrant centres */
        unsigned q2 = dp[6 * W + 1], q3 = dp[6 * W + 6];
        /* DIAGNOSTIC: sample again after a long spin. If the pixels APPEAR, the fence
         * is racing (seq retired before the writes drained); if they stay zero, the
         * scaled path genuinely wrote nothing. */
        volatile unsigned spin = 0;
        for (unsigned i = 0; i < 4000000u; i++) spin += i;
        unsigned l0 = dp[1 * W + 1], l3 = dp[6 * W + 6];
        printf("blittest: STRETCH 2x2 -> 8x8 NN -> %08x %08x %08x %08x %s\n",
               q0, q1, q2, q3,
               (q0 == Q[0] && q1 == Q[1] && q2 == Q[2] && q3 == Q[3])
                 ? "OK (each quadrant = its source pixel)" : "FAIL");
        printf("blittest:   after-delay resample -> %08x %08x  (%s)\n", l0, l3,
               (l0 == Q[0] && l3 == Q[3]) ? "FENCE RACE: pixels arrived late"
                                          : "engine wrote nothing");

        /* Does the SCALED command work AT ALL on a DDR surface? 1:1, no scaling. */
        for (unsigned i = 0; i < 64; i++) dp[(i / 8) * W + (i % 8)] = 0;
        for (unsigned i = 0; i < 64; i++) sp[(i / 8) * W + (i % 8)] = 0xABCD0000u + i;
        struct xt_blit_cmd s11 = { 0 };
        s11.op = XT_BLIT_SCALE; s11.dst_id = did; s11.src_id = sid;
        s11.sx = 0; s11.sy = 0; s11.sw = 8; s11.sh = 8;
        s11.dx = 0; s11.dy = 0; s11.dw = 8; s11.dh = 8;
        long q = submit(&s11);
        for (int i = 0; i < 400000; i++) {
            unsigned r = 0; sys_ioctl(bfd, XT_BLIT_SEQ, &r);
            if ((long)r >= q) break;
        }
        printf("blittest:   SCALED 1:1 (no scaling) -> %08x %08x %s\n",
               dp[0], dp[7 * W + 7],
               (dp[0] == 0xABCD0000u && dp[7 * W + 7] == 0xABCD0000u + 63)
                 ? "OK (SC path works on DDR)" : "FAIL (SC path writes nothing on DDR)");
    }

    /* bilinear: interior pixels must be INTERPOLATED, i.e. take values that appear in
     * NO source pixel. Exact taps depend on the RTL's 8-bit weight divider, so assert
     * the property (it blended) and print the values rather than hard-code a guess. */
    for (unsigned i = 0; i < 64; i++) dp[(i / 8) * W + (i % 8)] = 0;
    sc.flags = XT_BLITF_BILINEAR;
    seq = submit(&sc);
    for (int i = 0; i < 200000; i++) {
        unsigned r = 0; sys_ioctl(bfd, XT_BLIT_SEQ, &r);
        if ((long)r >= seq) break;
    }
    unsigned b_mid = dp[4 * W + 4], b_c0 = dp[0];
    int interpolated = (b_mid != Q[0] && b_mid != Q[1] && b_mid != Q[2] && b_mid != Q[3]
                        && b_mid != 0);
    printf("blittest: STRETCH bilinear -> corner=%08x mid=%08x %s\n", b_c0, b_mid,
           interpolated ? "OK (mid is a blend of no single source pixel)"
                        : "FAIL (mid is not interpolated)");

    /* ---- 2c. ALPHA: per-pixel alpha-over, RGBA src -> DDR dst ------------------ */
    /* The engine's alpha path is proven -- it is how text renders (SRC_BLIT with an
     * 8-bit COVERAGE source). What is NOT proven is the variant gemd needs: a 4 B/px
     * RGBA source with SRC_AOVER, compositing one shm surface onto another.
     *
     * alpha=255 and alpha=0 are exact under ANY rounding, so those are the assertions.
     * The partial-alpha pixel is reported, and only checked for "it actually blended". */
    const unsigned DSTBG = 0x11223344u;
    const unsigned SRCOP = 0xC0FFEEFFu;   /* A = 0xFF (low byte): fully opaque   */
    const unsigned SRCTR = 0xAABBCC00u;   /* A = 0x00: fully transparent         */
    const unsigned SRCHF = 0xAABBCC80u;   /* A = 0x80: half                      */
    for (unsigned y = 0; y < 4; y++)
        for (unsigned x = 0; x < 8; x++) {
            dp[y * W + x] = DSTBG;
            sp[y * W + x] = (x < 3) ? SRCOP : (x < 6) ? SRCTR : SRCHF;
        }

    struct xt_blit_cmd al = { 0 };
    al.op = XT_BLIT_COPY; al.flags = XT_BLITF_BLEND;   /* -> SRC_BLIT + SRC_AOVER */
    al.dst_id = did; al.src_id = sid;
    al.sx = 0; al.sy = 0; al.dx = 0; al.dy = 0; al.dw = 8; al.dh = 4;
    seq = submit(&al);
    if (seq < 0) { printf("blittest: ALPHA -> REJECTED by the driver FAIL\n"); }
    else {
        for (int i = 0; i < 200000; i++) {
            unsigned r = 0; sys_ioctl(bfd, XT_BLIT_SEQ, &r);
            if ((long)r >= seq) break;
        }
        unsigned a_op = dp[1], a_tr = dp[4], a_hf = dp[7];
        int blended = (a_hf != SRCHF && a_hf != DSTBG);   /* neither src nor dst: it mixed */
        printf("blittest: ALPHA a=255 -> %08x %s\n", a_op,
               (a_op == SRCOP) ? "OK (opaque source wins)" : "FAIL (expected c0ffeeff)");
        printf("blittest: ALPHA a=0   -> %08x %s\n", a_tr,
               (a_tr == DSTBG) ? "OK (destination preserved)" : "FAIL (expected 11223344)");
        printf("blittest: ALPHA a=128 -> %08x %s\n", a_hf,
               blended ? "OK (mixed src and dst)" : "FAIL (no blend happened)");
    }

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
