/* vfs.c — mount table + path dispatch. See vfs.h. */
#include "vfs.h"
#include <string.h>

#define NMOUNT 8
static struct { const char *prefix; uint32_t plen; const struct fs_ops *fs; void *fsdata; } g_mnt[NMOUNT];
static int g_nmnt;

/* does `s` start with the first `n` bytes of `pfx`? (bare_libc has no strncmp) */
static int has_prefix(const char *s, const char *pfx, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) if (s[i] != pfx[i]) return 0;
    return 1;
}

int vfs_mount(const char *prefix, const struct fs_ops *fs, void *fsdata)
{
    if (g_nmnt >= NMOUNT || !prefix || !fs) return -1;
    g_mnt[g_nmnt].prefix = prefix;
    g_mnt[g_nmnt].plen   = (uint32_t)strlen(prefix);
    g_mnt[g_nmnt].fs     = fs;
    g_mnt[g_nmnt].fsdata = fsdata;
    g_nmnt++;
    return 0;
}

/* longest-prefix match; the chosen fs gets the path with its mount prefix stripped
 * (the root mount "/" gets the full absolute path, since romfs keys are absolute). */
int vfs_open(const char *path, int flags, struct vfile *f)
{
    int best = -1; uint32_t blen = 0;
    for (int i = 0; i < g_nmnt; i++) {
        uint32_t pl = g_mnt[i].plen;
        if (has_prefix(path, g_mnt[i].prefix, pl) && pl >= blen) { best = i; blen = pl; }
    }
    if (best < 0) return -1;
    const char *sub = path + blen;
    if (blen <= 1)      sub = path;     /* root "/" -> full absolute path */
    else if (*sub == 0) sub = "/";      /* exactly the mountpoint -> that fs's root */
    f->fs = g_mnt[best].fs; f->priv = 0; f->size = 0; f->pos = 0;
    if (f->fs->open(g_mnt[best].fsdata, sub, flags, f) != 0) { f->fs = 0; return -1; }
    return 0;
}

long vfs_read(struct vfile *f, void *buf, long n)
{
    if (!f || !f->fs || n < 0) return -1;
    return f->fs->read(f, buf, n);
}

/* generic seek over the open file's byte range (read-only files; pos lives here) */
long vfs_lseek(struct vfile *f, long off, int whence)
{
    if (!f || !f->fs) return -1;
    long base = (whence == 1) ? (long)f->pos : (whence == 2) ? (long)f->size : 0;
    long np = base + off;
    if (np < 0 || np > (long)f->size) return -1;
    f->pos = (uint32_t)np;
    return np;
}

void vfs_close(struct vfile *f)
{
    if (f && f->fs) { if (f->fs->close) f->fs->close(f); f->fs = 0; }
}

uint32_t vfs_mmap_base(struct vfile *f)
{
    return (f && f->fs && f->fs->mmap_base) ? f->fs->mmap_base(f) : 0;
}
