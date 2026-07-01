/* vfs_romfs.c — romfs as a VFS driver (in-memory; read-only). */
#include "vfs.h"
#include "romfs.h"
#include <stdint.h>

static long ro_read(vfs_file *f, void *buf, uint32_t n)
{
    uint32_t avail = f->size - f->pos;
    if (n > avail) n = avail;
    const uint8_t *d = (const uint8_t *)f->data;
    for (uint32_t i = 0; i < n; i++) ((uint8_t *)buf)[i] = d[f->pos + i];
    f->pos += n;
    return (long)n;
}

static long ro_lseek(vfs_file *f, long off, int whence)
{
    long base = (whence == 1) ? (long)f->pos : (whence == 2) ? (long)f->size : 0;
    long np = base + off;
    if (np < 0 || np > (long)f->size) return -1;
    f->pos = (uint32_t)np;
    return np;
}

static void ro_close(vfs_file *f) { (void)f; }

static int ro_open(vfs_mount *m, const char *path, int flags, vfs_file *f)
{
    (void)m;
    if (flags & VFS_O_ACCMODE) return -1;               /* romfs is read-only */
    const uint8_t *d; uint32_t sz;
    if (!romfs_lookup(path, &d, &sz)) return -1;
    f->data = d; f->size = sz; f->pos = 0;
    f->read = ro_read; f->write = 0; f->lseek = ro_lseek; f->close = ro_close;
    return 0;
}

static vfs_fs romfs_fs = { "romfs", ro_open };

void vfs_romfs_init(void) { vfs_register_fs(&romfs_fs); }
