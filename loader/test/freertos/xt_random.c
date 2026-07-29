/* xt_random.c — the kernel CSPRNG behind /dev/random and /dev/urandom.
 *
 * The PL ring-oscillator TRNG is a sound entropy SOURCE, but it is slow: one
 * raw bit per clk_sys, von-Neumann debiased at ~25% yield, so a fresh 32-bit
 * word takes ~1 us. An AXI read is ~100-300 ns. Reading TRNG_RND back to back
 * therefore returns a pool that has absorbed a fraction of a bit since the
 * previous read — 256 bits of "key material" gathered that way carries maybe
 * 50 bits of real entropy, and nothing about the old construction made that
 * visible.
 *
 * Two rules follow, and they are the whole design:
 *
 *   1. NEVER read TRNG_RND without first seeing TRNG_STAT[8]. The RTL counts
 *      debiased bits since the last consume and sets bit 8 at 32, so gating on
 *      it is the difference between a fresh word and a stretched one. The spin
 *      is bounded and failure is LOUD — falling through to an ungated read
 *      would reintroduce exactly the silent degradation this replaces.
 *
 *   2. NEVER hand out generator state. The old path emitted xorshift32 state
 *      bytes directly, so a few output bytes recovered the state and rolled it
 *      forward or backward. Here the gathered words are CONDITIONED through
 *      SHA-256 (XOR is not an extractor — it does not remove the structure the
 *      pool's LFSR leaves) into a ChaCha20 key, and output comes from the
 *      cipher. Rekeying from fresh gathered entropy gives backtracking
 *      resistance: the key that produced earlier output no longer exists.
 *
 * SHA-256 and ChaCha20 are implemented here rather than borrowed from
 * third_party/dropbear: dropbear is a userspace .so and this is the FreeRTOS
 * kernel, so there is no link path between them. Both are small and are the
 * standard constructions, written out plainly.
 *
 * On qemu there is no TRNG. The gather fails, the pool falls back to the
 * clock-and-address seeding it always had, and the ChaCha construction still
 * applies — so qemu output is non-cryptographic but the code path is the same
 * one hardware takes. `xt_random_is_hw()` reports which happened.
 */
#include "xt_random.h"
#include "vfs.h"
#include <string.h>

extern int _gettimeofday(void *tv, void *tz);

/* ── SHA-256 ──────────────────────────────────────────────────────────── */

typedef struct { uint32_t s[8]; uint64_t len; uint8_t buf[64]; uint32_t n; } sha256_ctx;

static uint32_t ror32(uint32_t x, int r) { return (x >> r) | (x << (32 - r)); }

static const uint32_t sha_k[64] = {
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,
    0x923f82a4u,0xab1c5ed5u,0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,
    0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,0xe49b69c1u,0xefbe4786u,
    0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,
    0x06ca6351u,0x14292967u,0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,
    0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,0xa2bfe8a1u,0xa81a664bu,
    0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,
    0x5b9cca4fu,0x682e6ff3u,0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,
    0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
};

static void sha256_block(sha256_ctx *c, const uint8_t *p)
{
    uint32_t w[64], a, b, d, e, f, g, h, t1, t2, cc;
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[i*4] << 24) | ((uint32_t)p[i*4+1] << 16) |
               ((uint32_t)p[i*4+2] << 8) | (uint32_t)p[i*4+3];
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = ror32(w[i-15],7) ^ ror32(w[i-15],18) ^ (w[i-15] >> 3);
        uint32_t s1 = ror32(w[i-2],17) ^ ror32(w[i-2],19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    a=c->s[0]; b=c->s[1]; cc=c->s[2]; d=c->s[3];
    e=c->s[4]; f=c->s[5]; g=c->s[6]; h=c->s[7];
    for (int i = 0; i < 64; i++) {
        uint32_t S1 = ror32(e,6) ^ ror32(e,11) ^ ror32(e,25);
        uint32_t ch = (e & f) ^ (~e & g);
        t1 = h + S1 + ch + sha_k[i] + w[i];
        uint32_t S0 = ror32(a,2) ^ ror32(a,13) ^ ror32(a,22);
        uint32_t mj = (a & b) ^ (a & cc) ^ (b & cc);
        t2 = S0 + mj;
        h=g; g=f; f=e; e=d+t1; d=cc; cc=b; b=a; a=t1+t2;
    }
    c->s[0]+=a; c->s[1]+=b; c->s[2]+=cc; c->s[3]+=d;
    c->s[4]+=e; c->s[5]+=f; c->s[6]+=g; c->s[7]+=h;
}

static void sha256_init(sha256_ctx *c)
{
    c->s[0]=0x6a09e667u; c->s[1]=0xbb67ae85u; c->s[2]=0x3c6ef372u; c->s[3]=0xa54ff53au;
    c->s[4]=0x510e527fu; c->s[5]=0x9b05688cu; c->s[6]=0x1f83d9abu; c->s[7]=0x5be0cd19u;
    c->len = 0; c->n = 0;
}

static void sha256_update(sha256_ctx *c, const void *data, size_t n)
{
    const uint8_t *p = data;
    c->len += n;
    while (n--) {
        c->buf[c->n++] = *p++;
        if (c->n == 64) { sha256_block(c, c->buf); c->n = 0; }
    }
}

static void sha256_final(sha256_ctx *c, uint8_t out[32])
{
    uint64_t bits = c->len * 8;
    c->buf[c->n++] = 0x80;
    if (c->n > 56) { while (c->n < 64) c->buf[c->n++] = 0; sha256_block(c, c->buf); c->n = 0; }
    while (c->n < 56) c->buf[c->n++] = 0;
    for (int i = 7; i >= 0; i--) c->buf[c->n++] = (uint8_t)(bits >> (8*i));
    sha256_block(c, c->buf);
    for (int i = 0; i < 8; i++) {
        out[i*4]   = (uint8_t)(c->s[i] >> 24);
        out[i*4+1] = (uint8_t)(c->s[i] >> 16);
        out[i*4+2] = (uint8_t)(c->s[i] >> 8);
        out[i*4+3] = (uint8_t)(c->s[i]);
    }
}

/* ── ChaCha20 ─────────────────────────────────────────────────────────── */

#define QR(a,b,c,d) ( \
    a += b, d ^= a, d = (d << 16) | (d >> 16), \
    c += d, b ^= c, b = (b << 12) | (b >> 20), \
    a += b, d ^= a, d = (d <<  8) | (d >> 24), \
    c += d, b ^= c, b = (b <<  7) | (b >> 25))

/* One 64-byte keystream block. The counter is 64-bit (words 12-13), so a
 * single key never runs out before the rekey threshold below fires. */
static void chacha20_block(const uint32_t key[8], uint64_t counter,
                           const uint32_t nonce[2], uint8_t out[64])
{
    static const uint32_t sigma[4] = { 0x61707865u, 0x3320646eu, 0x79622d32u, 0x6b206574u };
    uint32_t x[16], s[16];
    s[0]=sigma[0]; s[1]=sigma[1]; s[2]=sigma[2]; s[3]=sigma[3];
    for (int i = 0; i < 8; i++) s[4+i] = key[i];
    s[12] = (uint32_t)counter; s[13] = (uint32_t)(counter >> 32);
    s[14] = nonce[0]; s[15] = nonce[1];
    memcpy(x, s, sizeof x);
    for (int i = 0; i < 10; i++) {
        QR(x[0],x[4],x[ 8],x[12]); QR(x[1],x[5],x[ 9],x[13]);
        QR(x[2],x[6],x[10],x[14]); QR(x[3],x[7],x[11],x[15]);
        QR(x[0],x[5],x[10],x[15]); QR(x[1],x[6],x[11],x[12]);
        QR(x[2],x[7],x[ 8],x[13]); QR(x[3],x[4],x[ 9],x[14]);
    }
    for (int i = 0; i < 16; i++) {
        uint32_t v = x[i] + s[i];
        out[i*4]   = (uint8_t)v;        out[i*4+1] = (uint8_t)(v >> 8);
        out[i*4+2] = (uint8_t)(v >> 16); out[i*4+3] = (uint8_t)(v >> 24);
    }
}

/* ── the gated gather ─────────────────────────────────────────────────── */

#ifdef XT_HW
#define TRNG_RND   (*(volatile uint32_t *)0x43C00700u)
#define TRNG_STAT  (*(volatile uint32_t *)0x43C00704u)
#define TRNG_FRESH (1u << 8)            /* >=32 debiased bits since the last read */

/* A fresh word needs ~1 us of ring-oscillator output. The bound is generous
 * against that (a stalled TRNG is a hardware fault, not a slow one) and is
 * counted in loop iterations rather than wall time so it needs no timer. */
#define TRNG_SPIN_LIMIT 2000000u

static int trng_word(uint32_t *out)
{
    uint32_t spins = 0;
    while (!(TRNG_STAT & TRNG_FRESH))
        if (++spins > TRNG_SPIN_LIMIT) return -1;   /* never fall through ungated */
    *out = TRNG_RND;                                 /* the read consumes and restarts the count */
    return 0;
}
#endif

/* ── the pool ─────────────────────────────────────────────────────────── */

/* Rekey thresholds. Both are deliberately conservative: a rekey costs ~8 us of
 * gather, which is nothing beside the 1 MB of output it covers. */
#define REKEY_BYTES  (1u << 20)

static uint32_t g_key[8];
static uint32_t g_nonce[2];
static uint64_t g_counter;
static uint32_t g_since_rekey;
static uint8_t  g_block[64];
static uint32_t g_block_used = 64;      /* forces a block on first use */
static int      g_ready;
static int      g_is_hw;
static uint8_t  g_carry[32];            /* previous key material, folded into the next */

/* Derive a fresh key by conditioning: 32 gathered words plus the carry from the
 * last key plus the clock, all through SHA-256. Conditioning rather than XOR is
 * the point — XOR is not an extractor, and the pool's LFSR leaves structure a
 * hash removes.
 *
 * Returns 0 when the key is backed by hardware entropy, -1 when the gather
 * failed and the result rests on the clock alone. The caller decides what to do
 * about it; nothing here pretends the difference does not exist. */
static int rekey(void)
{
    sha256_ctx c;
    uint8_t digest[32];
    int hw = 0;

    sha256_init(&c);
    sha256_update(&c, g_carry, sizeof g_carry);     /* backtracking resistance */

#ifdef XT_HW
    hw = 1;
    for (int i = 0; i < 32; i++) {                  /* 32 words = 1024 fresh bits */
        uint32_t w;
        if (trng_word(&w) != 0) { hw = 0; break; }  /* loud: the caller sees !is_hw */
        sha256_update(&c, &w, sizeof w);
    }
#endif

    /* Always fold in the clock and an address. On hardware this adds nothing to
     * a gather that already succeeded; on qemu, or after a TRNG fault, it is
     * all there is — and the construction stays identical either way. */
    { struct { long long sec, usec; } tv = { 0, 0 };
      _gettimeofday(&tv, 0);
      sha256_update(&c, &tv, sizeof tv);
      uintptr_t here = (uintptr_t)&c;
      sha256_update(&c, &here, sizeof here);
      sha256_update(&c, &g_counter, sizeof g_counter); }

    sha256_final(&c, digest);
    memcpy(g_key, digest, 32);
    memcpy(g_carry, digest, 32);        /* only ever hashed, never emitted */

    /* A fresh nonce and a counter reset per key; the key itself is new, so the
     * (key, nonce, counter) triple cannot repeat. */
    g_nonce[0] ^= 0x9e3779b9u; g_nonce[1] += 1u;
    g_counter = 0;
    g_since_rekey = 0;
    g_block_used = 64;
    g_is_hw = hw;
    g_ready = 1;
    return hw ? 0 : -1;
}

int xt_random_ready(void) { return g_ready; }
int xt_random_is_hw(void) { return g_ready && g_is_hw; }

void xt_random_add_seed(const void *seed, size_t n)
{
    /* Mix a caller-supplied seed (the across-boot file) into the carry, so the
     * next rekey folds it in. It is hashed with the existing carry rather than
     * replacing it: a stale or attacker-known seed must not be able to REDUCE
     * the pool's unpredictability, only add to it. */
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, g_carry, sizeof g_carry);
    sha256_update(&c, seed, n);
    sha256_final(&c, g_carry);
    g_since_rekey = REKEY_BYTES;        /* take it into use on the next request */
}

void xt_random_save_seed(uint8_t out[32])
{
    /* Output for persisting across a boot. It comes from the cipher like any
     * other output, so it reveals nothing about the key; the caller is expected
     * to overwrite the file as soon as it has been read back. */
    xt_random_bytes(out, 32);
}

void xt_random_bytes(void *buf, size_t n)
{
    uint8_t *b = buf;
    if (!g_ready || g_since_rekey >= REKEY_BYTES) rekey();
    while (n) {
        if (g_block_used == 64) {
            chacha20_block(g_key, g_counter++, g_nonce, g_block);
            g_block_used = 0;
        }
        size_t take = 64 - g_block_used;
        if (take > n) take = n;
        memcpy(b, g_block + g_block_used, take);
        /* Zero the consumed keystream: it is never needed again, and leaving it
         * in a static buffer is a copy of live output sitting in kernel memory. */
        memset(g_block + g_block_used, 0, take);
        g_block_used += (uint32_t)take;
        b += take; n -= take;
        g_since_rekey += (uint32_t)take;
        if (g_since_rekey >= REKEY_BYTES && n) rekey();
    }
}

/* ── the getrandom() contract ──────────────────────────────────────────── */

int xt_random_hw_present(void)
{
#ifdef XT_HW
    return 1;
#else
    return 0;                   /* qemu: there is no TRNG to wait for */
#endif
}

int xt_random_gather(void) { return rekey(); }

/* ── seeding across a boot ─────────────────────────────────────────────── */

/* Read the persisted seed, mix it in, and OVERWRITE it immediately with fresh
 * bytes. The overwrite is the security-relevant half: a seed that stays on disk
 * after being consumed lets anyone holding a copy of the image replay the boot
 * it seeds. Writing the replacement now rather than at shutdown also means a
 * power cut or a hard SYS_reboot (which masks interrupts and resets the PS, so
 * no filesystem write can run there) cannot leave a stale seed behind.
 *
 * A missing or short file is not an error — the first boot of a fresh card has
 * no seed, and the pool does not depend on one. It matters most on qemu and in
 * the window before the TRNG's first gather, which is exactly when the machine
 * would otherwise be reduced to clock seeding. */
void xt_random_seed_boot(const char *path)
{
    uint8_t seed[32];
    vfs_file f;

    if (vfs_open(path, 0, &f) == 0) {
        long got = vfs_read(&f, seed, sizeof seed);
        vfs_close(&f);
        if (got > 0) xt_random_add_seed(seed, (size_t)got);
        memset(seed, 0, sizeof seed);
    }

    xt_random_save_seed(seed);
    if (vfs_open(path, VFS_O_WRONLY | VFS_O_CREAT | VFS_O_TRUNC, &f) == 0) {
        vfs_write(&f, seed, sizeof seed);
        vfs_close(&f);
    }
    memset(seed, 0, sizeof seed);
}
