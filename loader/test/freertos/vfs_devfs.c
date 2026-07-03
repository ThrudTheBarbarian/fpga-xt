/* vfs_devfs.c — character devices, mounted /OS/Dev.
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
 * every open), tty + console (the console).
 */
#include "vfs.h"
#include <stdint.h>
#include <string.h>

extern int _gettimeofday(void *tv, void *tz);   /* kernel syscall primitive (syscalls.c) */

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

typedef struct {
    const char *name;                    /* rel path within the mount, e.g. "/null" */
    int chr;                             /* VFS_CHR_DEV or VFS_CHR_TTY */
    long (*rd)(vfs_file *, void *, uint32_t);
    long (*wr)(vfs_file *, const void *, uint32_t);
} devnode;

static const devnode g_nodes[] = {
    { "/null",    VFS_CHR_DEV, dv_null_rd, dv_sink_wr },
    { "/zero",    VFS_CHR_DEV, dv_zero_rd, dv_sink_wr },
    { "/urandom", VFS_CHR_DEV, dv_rand_rd, dv_sink_wr },
    { "/random",  VFS_CHR_DEV, dv_rand_rd, dv_sink_wr },
    { "/tty",     VFS_CHR_TTY, 0, 0 },
    { "/console", VFS_CHR_TTY, 0, 0 },
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
