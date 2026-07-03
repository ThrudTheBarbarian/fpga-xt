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
 * (xorshift stream — NOT cryptographic; reseeded from the wall clock at
 * every open), tty + console (the console), i2c-0 (the PS-I2C0 bus, Linux
 * i2c-dev ioctl surface — the toybox i2c tools speak it).
 */
#include "vfs.h"
#include <stdint.h>
#include <string.h>

extern int _gettimeofday(void *tv, void *tz);   /* kernel syscall primitive (syscalls.c) */
extern int xt_i2c_send(uint8_t addr, const uint8_t *buf, int n);   /* hdmi.c (0=ok; qemu: -1) */
extern int xt_i2c_recv(uint8_t addr, uint8_t *buf, int n);

static long dv_null_rd(vfs_file *f, void *buf, uint32_t n)
{ (void)f; (void)buf; (void)n; return 0; }                       /* instant EOF */

static long dv_sink_wr(vfs_file *f, const void *buf, uint32_t n)
{ (void)f; (void)buf; return (long)n; }                          /* swallow */

static long dv_zero_rd(vfs_file *f, void *buf, uint32_t n)
{ (void)f; memset(buf, 0, n); return (long)n; }

static long dv_rand_rd(vfs_file *f, void *buf, uint32_t n)
{
    uint32_t s = (uint32_t)(uintptr_t)f->priv;
    uint8_t *b = (uint8_t *)buf;
    for (uint32_t i = 0; i < n; i++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        b[i] = (uint8_t)s;
    }
    f->priv = (void *)(uintptr_t)s;
    return (long)n;
}

static void dv_close(vfs_file *f) { (void)f; }

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

typedef struct {
    const char *name;                    /* rel path within the mount, e.g. "/null" */
    int chr;                             /* VFS_CHR_DEV or VFS_CHR_TTY */
    long (*rd)(vfs_file *, void *, uint32_t);
    long (*wr)(vfs_file *, const void *, uint32_t);
    long (*ioc)(vfs_file *, unsigned, void *);
} devnode;

static const devnode g_nodes[] = {
    { "/null",    VFS_CHR_DEV, dv_null_rd, dv_sink_wr, 0 },
    { "/zero",    VFS_CHR_DEV, dv_zero_rd, dv_sink_wr, 0 },
    { "/urandom", VFS_CHR_DEV, dv_rand_rd, dv_sink_wr, 0 },
    { "/random",  VFS_CHR_DEV, dv_rand_rd, dv_sink_wr, 0 },
    { "/tty",     VFS_CHR_TTY, 0, 0, 0 },
    { "/console", VFS_CHR_TTY, 0, 0, 0 },
    { "/i2c-0",   VFS_CHR_DEV, dv_i2c_rd, dv_i2c_wr, dv_i2c_ioctl },
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
    f->ioctl = d->ioc;
    f->size = 0; f->pos = 0; f->data = 0; f->mnt = 0;
    f->chr = d->chr;
    if (d->rd == dv_rand_rd) {           /* per-open xorshift state, clock-seeded */
        struct { long sec, usec; } tv = { 0, 0 };
        _gettimeofday(&tv, 0);
        uint32_t s = (uint32_t)tv.usec ^ ((uint32_t)tv.sec << 12) ^ 0x9e3779b9u;
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
