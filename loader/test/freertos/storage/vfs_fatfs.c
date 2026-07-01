/* vfs_fatfs.c — FatFs as a VFS driver (read path). Confines ff.h to storage/.
 * A small static FIL pool backs open files; the mount's drive is FatFs "0:".
 *
 * Serialization is at the VFS layer now (fatfs_fs.serialized=1): vfs_open/vfs_read/
 * vfs_lseek/vfs_close take ONE shared backing-store lock, so fatfs (and future
 * minixfs/swap on the same block device) never run concurrently — FatFs is
 * FF_FS_REENTRANT=0 with a shared window, and they share the SD. So these ops need no
 * lock of their own; callers must reach them through the vfs_* wrappers. */
#include "vfs.h"
#include "ff.h"
#include <stdint.h>

#define NFIL 8
static FIL     pool[NFIL];
static uint8_t used[NFIL];

static long ff_rd(vfs_file *f, void *buf, uint32_t n)
{
    FIL *fp = (FIL *)f->priv;
    UINT br = 0;
    if (f_read(fp, buf, n, &br) != FR_OK) return -1;
    f->pos = (uint32_t)f_tell(fp);
    return (long)br;
}

static long ff_sk(vfs_file *f, long off, int whence)
{
    FIL *fp = (FIL *)f->priv;
    FSIZE_t base = (whence == 1) ? f_tell(fp) : (whence == 2) ? f_size(fp) : 0;
    long np = (long)base + off;
    if (np < 0) return -1;
    if (f_lseek(fp, (FSIZE_t)np) != FR_OK) return -1;
    f->pos = (uint32_t)f_tell(fp);
    return (long)f->pos;
}

static void ff_cl(vfs_file *f)
{
    FIL *fp = (FIL *)f->priv;
    if (!fp) return;
    f_close(fp);
    for (int i = 0; i < NFIL; i++) if (&pool[i] == fp) { used[i] = 0; break; }
}

static int ff_open(vfs_mount *m, const char *path, vfs_file *f)
{
    (void)m;
    int h = -1;
    for (int i = 0; i < NFIL; i++) if (!used[i]) { h = i; break; }
    if (h < 0) return -1;
    /* prefix the FatFs drive: "/foo" -> "0:/foo" */
    char p[256];
    p[0] = '0'; p[1] = ':';
    int i = 0;
    while (path[i] && i < (int)sizeof p - 3) { p[2 + i] = path[i]; i++; }
    p[2 + i] = 0;
    if (f_open(&pool[h], p, FA_READ) != FR_OK) return -1;
    used[h] = 1;
    f->priv = &pool[h];
    f->size = (uint32_t)f_size(&pool[h]);
    f->pos = 0; f->data = 0;
    f->read = ff_rd; f->lseek = ff_sk; f->close = ff_cl;
    return 0;
}

static vfs_fs fatfs_fs = { "fatfs", ff_open, 1 /* serialized: backing-store */ };

void vfs_fatfs_init(void) { vfs_register_fs(&fatfs_fs); }
