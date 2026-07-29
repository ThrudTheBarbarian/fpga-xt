/* rngtest.c — is the kernel CSPRNG actually backed by the hardware TRNG?
 *
 * There is no /proc entry for this and none is needed: SYS_getrandom's own
 * contract already distinguishes the cases, so a userspace probe can answer it
 * without touching the kernel.
 *
 *   GRND_NONBLOCK returns -EAGAIN  ->  a TRNG exists but the pool has never
 *                                     completed a gated gather (not hw-backed)
 *   GRND_NONBLOCK succeeds         ->  the pool IS hw-backed, because the
 *                                     not-hw case is exactly what EAGAIN means
 *   blocking returns -EIO          ->  the TRNG is present and faulted
 *
 * (On a build with no TRNG at all — qemu — there is nothing to wait for, so
 * both forms simply serve what the pool has and neither branch applies. This
 * probe is meaningful on hardware.)
 *
 * Also samples TRNG_STAT/TRNG_RND through SYS_devmem so the freshness gate can
 * be observed from the same run: reading TRNG_RND consumes the pool and
 * restarts the debiased-bit count, and back-to-back reads through one syscall
 * each are close enough together to catch bit 8 still clear.
 */
#include "usys.h"

#define TRNG_RND_ADDR  0x43C00700u
#define TRNG_STAT_ADDR 0x43C00704u
#define TRNG_FRESH     (1u << 8)

static void put(const char *s)
{
    unsigned n = 0; while (s[n]) n++;
    sys_write(1, s, n);
}

static void puthex(unsigned v)
{
    char b[11]; b[0] = '0'; b[1] = 'x';
    for (int i = 0; i < 8; i++) {
        unsigned nib = (v >> ((7 - i) * 4)) & 0xF;
        b[2 + i] = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
    }
    b[10] = 0;
    put(b);
}

static void putdec(long v)
{
    char b[16]; int i = 15; b[i--] = 0;
    int neg = v < 0; unsigned long u = (unsigned long)(neg ? -v : v);
    if (!u) b[i--] = '0';
    while (u) { b[i--] = (char)('0' + (u % 10)); u /= 10; }
    if (neg) b[i--] = '-';
    put(&b[i + 1]);
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    unsigned char buf[32];

    /* 1. The question that matters. */
    long nb = sys_getrandom(buf, sizeof buf, GRND_NONBLOCK);
    put("getrandom(GRND_NONBLOCK) = "); putdec(nb);
    if (nb == (long)sizeof buf)       put("   -> HARDWARE-BACKED\n");
    else if (nb == -11)               put("   -> -EAGAIN: pool not hw-backed yet\n");
    else if (nb == -5)                put("   -> -EIO: TRNG present but faulted\n");
    else if (nb == -38)               put("   -> -ENOSYS: kernel predates SYS_getrandom\n");
    else                              put("   -> unexpected\n");

    /* 2. The blocking form must also succeed on healthy hardware. */
    long bl = sys_getrandom(buf, sizeof buf, 0);
    put("getrandom(blocking)      = "); putdec(bl); put("\n");

    /* 3. Two draws must differ — a fixed pool would repeat. */
    unsigned char a[8], b[8];
    sys_getrandom(a, sizeof a, 0);
    sys_getrandom(b, sizeof b, 0);
    int same = 1;
    for (unsigned i = 0; i < sizeof a; i++) if (a[i] != b[i]) { same = 0; break; }
    put(same ? "two draws IDENTICAL (bad)\n" : "two draws differ (ok)\n");

    /* 4. The freshness gate, observed directly. */
    unsigned st0 = (unsigned)sys_devmem(TRNG_STAT_ADDR, 0, 0);
    unsigned rnd = (unsigned)sys_devmem(TRNG_RND_ADDR, 0, 0);   /* consumes */
    unsigned st1 = (unsigned)sys_devmem(TRNG_STAT_ADDR, 0, 0);
    put("TRNG_STAT before = "); puthex(st0);
    put("  (fresh="); putdec((st0 & TRNG_FRESH) ? 1 : 0);
    put(" bits="); putdec(st0 & 0x3F); put(")\n");
    put("TRNG_RND read    = "); puthex(rnd); put("\n");
    put("TRNG_STAT after  = "); puthex(st1);
    put("  (fresh="); putdec((st1 & TRNG_FRESH) ? 1 : 0);
    put(" bits="); putdec(st1 & 0x3F); put(")\n");

    /* 5. The RESTART, which a single before/after pair cannot see: each
     *    sys_devmem is its own syscall, and a fresh word only needs ~1 us to
     *    re-accumulate, so by the time the second call lands the pool has
     *    always refilled. Consume repeatedly in a tight loop instead and count
     *    how often STAT comes back NOT-fresh — a pool that ignored the consume
     *    would report fresh every single time. */
    int notFresh = 0, iters = 64;
    unsigned minBits = 64;
    for (int i = 0; i < iters; i++) {
        (void)sys_devmem(TRNG_RND_ADDR, 0, 0);          /* consume */
        unsigned st = (unsigned)sys_devmem(TRNG_STAT_ADDR, 0, 0);
        if (!(st & TRNG_FRESH)) notFresh++;
        if ((st & 0x3F) < minBits) minBits = st & 0x3F;
    }
    put("after "); putdec(iters); put(" consume+poll pairs: not-fresh ");
    putdec(notFresh); put(", lowest bit-count seen "); putdec((long)minBits);
    put(notFresh ? "  -> restart OBSERVED\n"
                 : "  -> restart not caught (syscall gap > refill time)\n");

    sys_exit(nb == (long)sizeof buf ? 0 : 1);
}
