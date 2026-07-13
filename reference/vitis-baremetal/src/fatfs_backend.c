/* ============================================================================
 * ⚠ REFERENCE ONLY — THIS FILE IS NOT BUILT, NOT LINKED, NOT RUN.
 *
 * This is the RETIRED bare-metal XTOS. The live operating system is in loader/.
 * Do not "fix" this file; do not assume it reflects the running system.
 * See reference/vitis-baremetal/README.md.
 * ============================================================================ */
// fatfs_backend.c — VFS backend for the SD card (FatFs), mounted at "/".
//
// Backend handles are indices into a small FIL/DIR pool.  f_read/f_write use a
// 32-byte-aligned bounce buffer (the xsdps ADMA2 driver flushes/invalidates the
// caller's cache lines; newlib's stdio buffers aren't aligned).  The static
// bounce is NOT reentrant — single-task file I/O for now.

#include <fcntl.h>
#include <string.h>
#include "vfs.h"
#include "ff.h"

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

#define FF_MAXF 8
#define FF_MAXD 4
static FIL  ff_fil[FF_MAXF];  static char ff_used[FF_MAXF];
static DIR  ff_dir[FF_MAXD];  static char ff_dused[FF_MAXD];

static int ff_open(const char *path, int flags)
{
    BYTE m;
    int acc = flags & O_ACCMODE;
    if      (acc == O_WRONLY) m = FA_WRITE;
    else if (acc == O_RDWR)   m = FA_READ | FA_WRITE;
    else                      m = FA_READ;
    if (flags & O_CREAT) m |= (flags & O_TRUNC) ? FA_CREATE_ALWAYS
                            : (flags & O_EXCL)  ? FA_CREATE_NEW
                                                : FA_OPEN_ALWAYS;
    else if (flags & O_TRUNC) m |= FA_CREATE_ALWAYS;
    if (flags & O_APPEND) m |= FA_OPEN_APPEND;

    int i;
    for (i = 0; i < FF_MAXF; i++) if (!ff_used[i]) break;
    if (i == FF_MAXF) return -1;
    if (f_open(&ff_fil[i], path, m) != FR_OK) return -1;
    ff_used[i] = 1;
    return i;
}

static int ff_read(int h, char *buf, int n)
{
    static char bb[512] __attribute__((aligned(32)));
    int total = 0;
    while (n > 0) {
        UINT want = (n > 512) ? 512u : (UINT)n, got = 0;
        if (f_read(&ff_fil[h], bb, want, &got) != FR_OK) return -1;
        if (got == 0) break;
        memcpy(buf + total, bb, got);
        total += (int)got; n -= (int)got;
        if (got < want) break;
    }
    return total;
}

static int ff_write(int h, const char *buf, int n)
{
    static char wb[512] __attribute__((aligned(32)));
    int total = 0;
    while (n > 0) {
        UINT want = (n > 512) ? 512u : (UINT)n, put = 0;
        memcpy(wb, buf + total, want);
        if (f_write(&ff_fil[h], wb, want, &put) != FR_OK) return -1;
        total += (int)put; n -= (int)put;
        if (put < want) break;
    }
    return total;
}

static int  ff_close(int h)               { f_close(&ff_fil[h]); ff_used[h] = 0; return 0; }
static long ff_size (int h)               { return (long)f_size(&ff_fil[h]); }
static int  ff_remove(const char *path)   { return (f_unlink(path) == FR_OK) ? 0 : -1; }

static long ff_lseek(int h, long off, int whence)
{
    FSIZE_t base = (whence == SEEK_CUR) ? f_tell(&ff_fil[h])
                 : (whence == SEEK_END) ? f_size(&ff_fil[h]) : 0;
    FSIZE_t pos = base + (FSIZE_t)off;
    if (f_lseek(&ff_fil[h], pos) != FR_OK) return -1;
    return (long)pos;
}

static int ff_diropen(const char *path)
{
    int i;
    for (i = 0; i < FF_MAXD; i++) if (!ff_dused[i]) break;
    if (i == FF_MAXD) return -1;
    if (f_opendir(&ff_dir[i], path) != FR_OK) return -1;
    ff_dused[i] = 1;
    return i;
}

static int ff_dirnext(int dh, struct vfs_dirent *o)
{
    FILINFO fno;
    if (f_readdir(&ff_dir[dh], &fno) != FR_OK) return -1;
    if (fno.fname[0] == 0) return 0;
    strncpy(o->name, fno.fname, VFS_NAME_MAX - 1);
    o->name[VFS_NAME_MAX - 1] = 0;
    o->is_dir = (fno.fattrib & AM_DIR) ? 1 : 0;
    o->size   = (unsigned long)fno.fsize;
    return 1;
}

static void ff_dirclose(int dh) { f_closedir(&ff_dir[dh]); ff_dused[dh] = 0; }

static const vfs_fs FF = {
    "/", ff_open, ff_read, ff_write, ff_close, ff_lseek, ff_size,
    ff_remove, ff_diropen, ff_dirnext, ff_dirclose
};

void fatfs_backend_register(void) { vfs_register(&FF); }
