/* vfs_fatfs.c — FatFs as a VFS driver (read path). Confines ff.h to storage/.
 * A small static FIL pool backs open files; the mount's drive is FatFs "0:".
 *
 * INTERIM serialization: FatFs is built FF_FS_REENTRANT=0 (no internal lock) and
 * shares one window buffer, so concurrent access from two tasks corrupts it (e.g.
 * init's fire-and-forget boot shells each opening a script at once). Guard every op
 * with one mutex until the fs service (single owner of FatFs) makes serialization
 * structural — see docs/OS/fs-pagecache.md. */
#include "vfs.h"
#include "ff.h"
#include <stdint.h>
#include "FreeRTOS.h"
#include "semphr.h"

#define NFIL 8
static FIL     pool[NFIL];
static uint8_t used[NFIL];

static SemaphoreHandle_t fs_mtx;
static void fs_lock(void)   { if (fs_mtx) xSemaphoreTake(fs_mtx, portMAX_DELAY); }
static void fs_unlock(void) { if (fs_mtx) xSemaphoreGive(fs_mtx); }

static long ff_rd(vfs_file *f, void *buf, uint32_t n)
{
    FIL *fp = (FIL *)f->priv;
    UINT br = 0;
    fs_lock();
    FRESULT r = f_read(fp, buf, n, &br);
    f->pos = (uint32_t)f_tell(fp);
    fs_unlock();
    return r == FR_OK ? (long)br : -1;
}

static long ff_sk(vfs_file *f, long off, int whence)
{
    FIL *fp = (FIL *)f->priv;
    fs_lock();
    FSIZE_t base = (whence == 1) ? f_tell(fp) : (whence == 2) ? f_size(fp) : 0;
    long np = (long)base + off;
    long r = -1;
    if (np >= 0 && f_lseek(fp, (FSIZE_t)np) == FR_OK) { f->pos = (uint32_t)f_tell(fp); r = (long)f->pos; }
    fs_unlock();
    return r;
}

static void ff_cl(vfs_file *f)
{
    FIL *fp = (FIL *)f->priv;
    if (!fp) return;
    fs_lock();
    f_close(fp);
    for (int i = 0; i < NFIL; i++) if (&pool[i] == fp) { used[i] = 0; break; }
    fs_unlock();
}

static int ff_open(vfs_mount *m, const char *path, vfs_file *f)
{
    (void)m;
    fs_lock();
    int h = -1;
    for (int i = 0; i < NFIL; i++) if (!used[i]) { h = i; break; }
    if (h < 0) { fs_unlock(); return -1; }
    /* prefix the FatFs drive: "/foo" -> "0:/foo" */
    char p[256];
    p[0] = '0'; p[1] = ':';
    int i = 0;
    while (path[i] && i < (int)sizeof p - 3) { p[2 + i] = path[i]; i++; }
    p[2 + i] = 0;
    if (f_open(&pool[h], p, FA_READ) != FR_OK) { fs_unlock(); return -1; }
    used[h] = 1;
    f->priv = &pool[h];
    f->size = (uint32_t)f_size(&pool[h]);
    f->pos = 0; f->data = 0;
    f->read = ff_rd; f->lseek = ff_sk; f->close = ff_cl;
    fs_unlock();
    return 0;
}

static vfs_fs fatfs_fs = { "fatfs", ff_open };

void vfs_fatfs_init(void) { if (!fs_mtx) fs_mtx = xSemaphoreCreateMutex(); vfs_register_fs(&fatfs_fs); }
