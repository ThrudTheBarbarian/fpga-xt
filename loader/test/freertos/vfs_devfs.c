/* vfs_devfs.c — character devices, mounted /OS/dev.
 *
 * Pure in-memory driver (reentrant, no fs-task dependency): each node is a
 * name + behaviour. Streams are UNBOUNDED, so devfs files bypass the page
 * store entirely — the kernel calls f->read/f->write directly for fds whose
 * vfs_file carries VFS_CHR_DEV, and turns a VFS_CHR_TTY open (tty, console)
 * into a console-alias fd, which already routes through the cooked-tty line
 * discipline and the console writer.
 *
 * Nodes: null (read EOF, write sink), zero (endless zeros), urandom/random
 * (xorshift stream re-stirred every 32 bits with genuine hardware entropy from
 * the PL ring-oscillator TRNG at GP0 0x7xx — clock-seeded fallback on qemu),
 * tty + console (the console), i2c-0 (the PS-I2C0 bus, Linux i2c-dev ioctl
 * surface — the toybox i2c tools speak it).
 */
#include "vfs.h"
#include <stdint.h>
#include <string.h>

extern int _gettimeofday(void *tv, void *tz);   /* kernel syscall primitive (syscalls.c) */

#ifdef XT_HW
/* PL ring-oscillator TRNG whitened word (xt_trng → GP0 TRNG_RND).  Reads return
 * fresh entropy — the fabric pool free-runs at clk_sys.  Used to keep /dev/urandom
 * genuinely unpredictable rather than a bare clock-seeded PRNG. */
static inline uint32_t hw_entropy(void) { return *(volatile uint32_t *)0x43C00700u; }
#endif
extern int xt_i2c_send(uint8_t addr, const uint8_t *buf, int n);   /* hdmi.c (0=ok; qemu: -1) */
extern int xt_i2c_recv(uint8_t addr, uint8_t *buf, int n);

static long dv_null_rd(vfs_file *f, void *buf, uint32_t n)
{ (void)f; (void)buf; (void)n; return 0; }                       /* instant EOF */

static long dv_sink_wr(vfs_file *f, const void *buf, uint32_t n)
{ (void)f; (void)buf; return (long)n; }                          /* swallow */

static long dv_zero_rd(vfs_file *f, void *buf, uint32_t n)
{ (void)f; memset(buf, 0, n); return (long)n; }

/* /dev/fb0 — the scan-out plane, READ-ONLY and kernel-mediated (M7): the gate made the
 * plane PL0-none, which killed fbgrab's direct mapping; a screen grab is a legitimate
 * diagnostic, so the kernel streams the pixels instead — no PL0 mapping, the write
 * discipline intact. Geometry comes from SYS_fb_info, whose NUMBERS survived the gate
 * for exactly this kind of use. Sequential reads walk the raw plane (stride*4*h bytes);
 * EOF at the end. Uncached reads — a grab is seconds-tolerant, the desktop is not. */
static long dv_fb0_rd(vfs_file *f, void *buf, uint32_t n)
{
    extern void fb_info(int *, int *, int *, uint32_t *);
    int w, h, stride; uint32_t addr;
    fb_info(&w, &h, &stride, &addr);
    uint32_t total = (uint32_t)stride * 4u * (uint32_t)h;
    if (f->pos >= total) return 0;
    if (n > total - f->pos) n = total - f->pos;
    memcpy(buf, (const void *)(uintptr_t)(addr + f->pos), n);   /* kernel identity view */
    f->pos += n;
    return (long)n;
}

static long dv_rand_rd(vfs_file *f, void *buf, uint32_t n)
{
    uint32_t s = (uint32_t)(uintptr_t)f->priv;
    uint8_t *b = (uint8_t *)buf;
    for (uint32_t i = 0; i < n; i++) {
#ifdef XT_HW
        if ((i & 3u) == 0) s ^= hw_entropy();   /* re-stir with fresh HW entropy each 32-bit word */
#endif
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        b[i] = (uint8_t)s;
    }
    f->priv = (void *)(uintptr_t)s;
    return (long)n;
}

static void dv_close(vfs_file *f) { (void)f; }

/* ---- pseudoterminals: /dev/ptyp[0-3] (master) + /dev/ttyp[0-3] (slave) -----
 * The pty core (buffers, blocking, ioctls) lives in frtos_os.c; these are thin
 * routers. f->priv packs the pair index (low bits) + a slave flag (0x100). */
extern void xt_pty_open(int i, int master);
extern void xt_pty_close(int i, int master);
extern long xt_pty_read(int i, int master, void *buf, uint32_t n, int nonblock);
extern long xt_pty_write(int i, int master, const void *buf, uint32_t n);
extern int  xt_pty_nread(int i, int master);
extern long xt_pty_ioctl(int i, unsigned req, void *arg);
#define PTY_IDX(f)  ((int)((uintptr_t)(f)->priv & 0xff))
#define PTY_MASTER(f) (((uintptr_t)(f)->priv & 0x100) == 0)

static long dv_ptym_rd(vfs_file *f, void *buf, uint32_t n) { return xt_pty_read(PTY_IDX(f), 1, buf, n, f->nonblock); }
static long dv_ptym_wr(vfs_file *f, const void *buf, uint32_t n) { return xt_pty_write(PTY_IDX(f), 1, buf, n); }
static long dv_ptys_rd(vfs_file *f, void *buf, uint32_t n) { return xt_pty_read(PTY_IDX(f), 0, buf, n, f->nonblock); }
static long dv_ptys_wr(vfs_file *f, const void *buf, uint32_t n) { return xt_pty_write(PTY_IDX(f), 0, buf, n); }
static long dv_pty_ioctl(vfs_file *f, unsigned req, void *arg)
{
    int i = PTY_IDX(f), m = PTY_MASTER(f);
    if (req == 0x7403u /*XT_TTY_NREAD*/) { if (arg) *(int *)arg = xt_pty_nread(i, m); return 0; }
    return xt_pty_ioctl(i, req, arg);
}
static void dv_pty_close(vfs_file *f) { xt_pty_close(PTY_IDX(f), PTY_MASTER(f)); }
static void dv_pty_dup(vfs_file *f)   { xt_pty_open(PTY_IDX(f), PTY_MASTER(f)); }  /* +1 ref on spawn */

/* ---- i2c-0: the PS-I2C0 master, Linux i2c-dev semantics -------------------
 * The slave address is per-open state (set by I2C_SLAVE, kept in f->pos);
 * read()/write() are raw transfers to it, ioctl(I2C_SMBUS) the SMBus ops.
 * Structs/codes mirror the Linux uapi the tools are compiled against
 * (libc-compat/linux/i2c*.h). */
#define XT_I2C_SLAVE       0x0703u
#define XT_I2C_SLAVE_FORCE 0x0706u
#define XT_I2C_FUNCS       0x0705u
#define XT_I2C_SMBUS       0x0720u

#define XT_SMBUS_READ   1
#define XT_SMBUS_QUICK      0
#define XT_SMBUS_BYTE       1
#define XT_SMBUS_BYTE_DATA  2
#define XT_SMBUS_WORD_DATA  3
#define XT_SMBUS_I2C_BLOCK  8
#define XT_SMBUS_BLOCK_MAX  32

union xt_smbus_data {
    uint8_t  byte;
    uint16_t word;
    uint8_t  block[XT_SMBUS_BLOCK_MAX + 2];   /* block[0] = length */
};
struct xt_smbus_ioctl {
    uint8_t  read_write;                      /* XT_SMBUS_READ / 0 = write */
    uint8_t  command;                         /* register offset */
    uint32_t size;                            /* XT_SMBUS_* transaction kind */
    union xt_smbus_data *data;
};

static long dv_i2c_rd(vfs_file *f, void *buf, uint32_t n)
{
    if (!f->pos) return -1;                                  /* no I2C_SLAVE set */
    return xt_i2c_recv((uint8_t)f->pos, (uint8_t *)buf, (int)n) ? -1 : (long)n;
}

static long dv_i2c_wr(vfs_file *f, const void *buf, uint32_t n)
{
    if (!f->pos || n > 14) return -1;                        /* TX FIFO depth (16) - addr margin */
    return xt_i2c_send((uint8_t)f->pos, (const uint8_t *)buf, (int)n) ? -1 : (long)n;
}

static long dv_i2c_ioctl(vfs_file *f, unsigned req, void *arg)
{
    switch (req) {
    case XT_I2C_SLAVE:
    case XT_I2C_SLAVE_FORCE:                                 /* arg is the ADDRESS, not a pointer */
        f->pos = (uint32_t)(uintptr_t)arg & 0x7Fu;
        return 0;
    case XT_I2C_FUNCS:                                       /* I2C + the SMBus ops below */
        if (!arg) return -1;
        *(unsigned long *)arg = 0x00000001ul   /* I2C_FUNC_I2C              */
                              | 0x00010000ul   /* I2C_FUNC_SMBUS_QUICK      */
                              | 0x00060000ul   /* SMBUS_READ/WRITE_BYTE      */
                              | 0x00180000ul   /* SMBUS_READ/WRITE_BYTE_DATA */
                              | 0x00600000ul   /* SMBUS_READ/WRITE_WORD_DATA */
                              | 0x0C000000ul;  /* SMBUS_READ/WRITE_I2C_BLOCK */
        return 0;
    case XT_I2C_SMBUS: {
        struct xt_smbus_ioctl *io = (struct xt_smbus_ioctl *)arg;
        if (!io || !f->pos) return -1;
        uint8_t addr = (uint8_t)f->pos, cmd = io->command;
        union xt_smbus_data *d = io->data;
        int rd = (io->read_write == XT_SMBUS_READ);
        switch (io->size) {
        case XT_SMBUS_QUICK:                                 /* address probe (i2cdetect) */
            return xt_i2c_send(addr, 0, 0) ? -1 : 0;
        case XT_SMBUS_BYTE:                                  /* bare 1-byte read / cmd write */
            if (!rd) return xt_i2c_send(addr, &cmd, 1) ? -1 : 0;
            return (d && !xt_i2c_recv(addr, &d->byte, 1)) ? 0 : -1;
        case XT_SMBUS_BYTE_DATA:
            if (!rd) { uint8_t b[2] = { cmd, d ? d->byte : 0 };
                       return xt_i2c_send(addr, b, 2) ? -1 : 0; }
            if (!d || xt_i2c_send(addr, &cmd, 1)) return -1;
            return xt_i2c_recv(addr, &d->byte, 1) ? -1 : 0;
        case XT_SMBUS_WORD_DATA:                             /* SMBus words: little-endian */
            if (!rd) { uint8_t b[3] = { cmd, (uint8_t)(d ? d->word : 0),
                                        (uint8_t)((d ? d->word : 0) >> 8) };
                       return xt_i2c_send(addr, b, 3) ? -1 : 0; }
            { uint8_t w[2];
              if (!d || xt_i2c_send(addr, &cmd, 1) || xt_i2c_recv(addr, w, 2)) return -1;
              d->word = (uint16_t)(w[0] | (w[1] << 8));
              return 0; }
        case XT_SMBUS_I2C_BLOCK: {                           /* block[0]=len, data in block[1..] */
            if (!d || d->block[0] == 0 || d->block[0] > XT_SMBUS_BLOCK_MAX) return -1;
            int len = d->block[0];
            if (!rd) { uint8_t b[14];                        /* cmd + data within the TX FIFO */
                       if (len > 13) return -1;
                       b[0] = cmd; memcpy(b + 1, d->block + 1, (size_t)len);
                       return xt_i2c_send(addr, b, len + 1) ? -1 : 0; }
            if (xt_i2c_send(addr, &cmd, 1)) return -1;
            return xt_i2c_recv(addr, d->block + 1, len) ? -1 : 0;
        }
        default: return -1;
        }
    }
    default: return -1;                                      /* ENOTTY */
    }
}

/* ---- /dev/input (docs/OS/gemd-plan.md M4) ----------------------------------
 * INPUT AS AN FD. SYS_input blocks, so a window server cannot wait on input and on its client
 * channels at once; as an fd it just joins the poll set. The queue, the producer task and the
 * decoder live in input_dev.c — this is only the node. */
extern long xt_input_dev_read(vfs_file *f, void *buf, uint32_t n);
extern long xt_input_dev_avail(vfs_file *f);
extern long xt_input_dev_ioctl(vfs_file *f, unsigned req, void *arg);
extern void xt_input_start(void);     /* the decoder task. MUST be started at OPEN, not at the
                                       * first read: a poller never reads until poll() says
                                       * readable, and poll() never says readable until the
                                       * producer has produced. Start-on-read deadlocks the one
                                       * caller this device exists for. */

typedef struct {
    const char *name;                    /* rel path within the mount, e.g. "/null" */
    int chr;                             /* VFS_CHR_DEV or VFS_CHR_TTY */
    long (*rd)(vfs_file *, void *, uint32_t);
    long (*wr)(vfs_file *, const void *, uint32_t);
    long (*ioc)(vfs_file *, unsigned, void *);
    long (*avl)(vfs_file *);             /* readable-now (poll); NULL = always ready */
} devnode;

/* ---- /dev/blitter (RESPONSIBILITIES.md §13) --------------------------------
 * The fd IS the capability. The kernel already knows which process owns it, and it closes
 * on process death, so queue cleanup is free.
 *
 * write() = submit a BATCH of commands (one per objc_draw, not one per primitive) and get
 * back the retire seq of the last. Commands name surfaces by HANDLE; blit_submit() resolves
 * them to physical and clips every rect to the surface's own allocation, so a client cannot
 * express an out-of-bounds blit.
 *
 * PRIORITY is privileged: only the process that called aes_init — i.e. gemd — may have it,
 * because a client that floods the queue must never be able to stall the screen. */
static int g_blit_prio_pid = -1;      /* the one process allowed to jump the queue */

extern int  blit_wait_seq(uint32_t want);        /* blitter.c (frtos_os.h) */
extern int  fb_owner_pid(void);                  /* frtos_os.c: the M7 display owner */

/* M7 gate, the driver leg (xtsys.h asked for it): the well-known PLANE/WALLPAPER handles
 * belong to the display owner — any process can still blit between its OWN declared
 * surfaces, but only the compositor may name the screen. */
static int blit_names_display(const struct xt_blit_cmd *c)
{
    return c->dst_id == XT_BLIT_SURF_PLANE || c->dst_id == XT_BLIT_SURF_WALLPAPER ||
           ((c->op == XT_BLIT_COPY || c->op == XT_BLIT_SCALE) &&
            (c->src_id == XT_BLIT_SURF_PLANE || c->src_id == XT_BLIT_SURF_WALLPAPER));
}

static long dv_blit_wr(vfs_file *f, const void *buf, uint32_t n)
{
    (void)f;
    if (!buf || n < sizeof(struct xt_blit_cmd)) return -1;
    const struct xt_blit_cmd *c = (const struct xt_blit_cmd *)buf;
    uint32_t cnt = n / (uint32_t)sizeof(struct xt_blit_cmd);
    int pid  = frtos_current_pid();
    int prio = (pid == g_blit_prio_pid);
    long seq = 0;
    for (uint32_t i = 0; i < cnt; i++) {
        if (blit_names_display(&c[i]) && pid != fb_owner_pid()) return -1;   /* M7 gate */
        long s = blit_submit(&c[i], prio);
        if (s < 0) return -1;              /* rejected: bad handle, or out of bounds */
        seq = s;
    }
    return seq;                            /* the fence the caller puts on its damage rect */
}
static long dv_blit_ioctl(vfs_file *f, unsigned req, void *arg)
{
    (void)f;
    switch (req) {
    case XT_BLIT_DECLARE: {
        if (!arg) return -1;
        struct xt_blit_surf *s = (struct xt_blit_surf *)arg;
        return blit_declare(s->id, s->stride);
    }
    case XT_BLIT_SEQ:
        if (!arg) return -1;
        *(uint32_t *)arg = blit_seq();
        return 0;
    case XT_BLIT_WAIT: {
        /* Block until the engine retires *arg — blit_wait_seq (blitter.c): brief register
         * spin (a small present retires in tens of microseconds — a tick sleep would
         * DOUBLE its cost), then tick sleeps. Bounded: a wedged engine costs the caller
         * 200 ms and an error, never a hang. */
        if (!arg) return -1;
        return blit_wait_seq(*(uint32_t *)arg);
    }
    case XT_BLIT_PRIORITY:
        /* First caller wins and is remembered; gemd starts before any client, so this is
         * the aes_init process. A second claimant is refused rather than allowed to steal
         * the screen from the window server. */
        if (g_blit_prio_pid >= 0 && g_blit_prio_pid != frtos_current_pid()) return -1;
        g_blit_prio_pid = frtos_current_pid();
        return 0;
    default: return -1;
    }
}

static const devnode g_nodes[] = {
    { "/blitter", VFS_CHR_DEV, 0, dv_blit_wr, dv_blit_ioctl, 0 },
    { "/input",   VFS_CHR_DEV, xt_input_dev_read, 0, xt_input_dev_ioctl, xt_input_dev_avail },
    { "/null",    VFS_CHR_DEV, dv_null_rd, dv_sink_wr, 0, 0 },
    { "/zero",    VFS_CHR_DEV, dv_zero_rd, dv_sink_wr, 0, 0 },
    { "/urandom", VFS_CHR_DEV, dv_rand_rd, dv_sink_wr, 0, 0 },
    { "/fb0",     VFS_CHR_DEV, dv_fb0_rd,  0,          0, 0 },   /* plane pixels, read-only (M7) */
    { "/random",  VFS_CHR_DEV, dv_rand_rd, dv_sink_wr, 0, 0 },
    { "/tty",     VFS_CHR_TTY, 0, 0, 0, 0 },
    { "/console", VFS_CHR_TTY, 0, 0, 0, 0 },
    { "/i2c-0",   VFS_CHR_DEV, dv_i2c_rd, dv_i2c_wr, dv_i2c_ioctl, 0 },
    { "/ptyp0",   VFS_CHR_DEV, dv_ptym_rd, dv_ptym_wr, dv_pty_ioctl, 0 },
    { "/ptyp1",   VFS_CHR_DEV, dv_ptym_rd, dv_ptym_wr, dv_pty_ioctl, 0 },
    { "/ptyp2",   VFS_CHR_DEV, dv_ptym_rd, dv_ptym_wr, dv_pty_ioctl, 0 },
    { "/ptyp3",   VFS_CHR_DEV, dv_ptym_rd, dv_ptym_wr, dv_pty_ioctl, 0 },
    { "/ttyp0",   VFS_CHR_DEV, dv_ptys_rd, dv_ptys_wr, dv_pty_ioctl, 0 },
    { "/ttyp1",   VFS_CHR_DEV, dv_ptys_rd, dv_ptys_wr, dv_pty_ioctl, 0 },
    { "/ttyp2",   VFS_CHR_DEV, dv_ptys_rd, dv_ptys_wr, dv_pty_ioctl, 0 },
    { "/ttyp3",   VFS_CHR_DEV, dv_ptys_rd, dv_ptys_wr, dv_pty_ioctl, 0 },
};
#define NDEV ((int)(sizeof g_nodes / sizeof g_nodes[0]))

static int dveq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == 0 && *b == 0; }

static const devnode *dv_find(const char *rel)
{
    for (int i = 0; i < NDEV; i++)
        if (dveq(g_nodes[i].name, rel)) return &g_nodes[i];
    return 0;
}

static int dv_open(vfs_mount *m, const char *rel, int flags, vfs_file *f)
{
    (void)m; (void)flags;
    const devnode *d = dv_find(rel);
    if (!d) return -1;
    f->read = d->rd; f->write = d->wr; f->lseek = 0; f->close = dv_close;
    f->ioctl = d->ioc; f->avail = d->avl; f->ondup = 0; f->nonblock = 0;
    f->size = 0; f->pos = 0; f->data = 0; f->mnt = 0;
    f->chr = d->chr;
    if (d->rd == dv_ptym_rd || d->rd == dv_ptys_rd) {   /* pty: idx from the trailing digit */
        int slave = (d->rd == dv_ptys_rd);
        int k = 0; while (rel[k]) k++;                   /* index = the trailing digit */
        int idx = (k > 0) ? (rel[k-1] - '0') : 0;
        f->priv = (void *)(uintptr_t)((idx & 0xff) | (slave ? 0x100 : 0));
        f->close = dv_pty_close;
        f->ondup = dv_pty_dup;           /* spawn-inherited copies bump the open count */
        xt_pty_open(idx, !slave);
        return 0;
    }
    if (d->rd == xt_input_dev_read) { xt_input_start(); f->priv = 0; return 0; }
    if (d->rd == dv_rand_rd) {           /* per-open xorshift state, clock-seeded */
        struct { long long sec, usec; } tv = { 0, 0 };   /* time_t is 64-bit here — must not undersize */
        _gettimeofday(&tv, 0);
        uint32_t s = (uint32_t)tv.usec ^ ((uint32_t)tv.sec << 12) ^ 0x9e3779b9u;
#ifdef XT_HW
        s ^= hw_entropy();               /* mix in hardware entropy at open */
#endif
        f->priv = (void *)(uintptr_t)(s ? s : 1);
    } else f->priv = 0;
    return 0;
}

static int dv_stat(vfs_mount *m, const char *rel, struct xt_stat *st)
{
    (void)m;
    if (rel[0] == 0 || (rel[0] == '/' && rel[1] == 0)) {
        st->mode = XT_S_IFDIR; st->size = 0; st->mtime = 0;
        return 0;
    }
    if (!dv_find(rel)) return -1;
    st->mode = XT_S_IFCHR; st->size = 0; st->mtime = 0;
    return 0;
}

static int dv_readdir(vfs_mount *m, const char *rel, int index,
                      char *name, int nsz, unsigned *mode)
{
    (void)m;
    if (!(rel[0] == 0 || (rel[0] == '/' && rel[1] == 0))) return -1;
    if (index < 0 || index >= NDEV) return 0;
    const char *n = g_nodes[index].name + 1;             /* strip '/' */
    int i = 0;
    while (n[i] && i < nsz - 1) { name[i] = n[i]; i++; }
    name[i] = 0;
    if (mode) *mode = XT_S_IFCHR;
    return 1;
}

static vfs_fs devfs_fs = {
    .name = "devfs", .open = dv_open,
    .stat = dv_stat, .readdir = dv_readdir,
};

void vfs_devfs_init(void) { vfs_register_fs(&devfs_fs); }
