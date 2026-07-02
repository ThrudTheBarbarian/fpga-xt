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

static long ff_wr(vfs_file *f, const void *buf, uint32_t n)
{
    FIL *fp = (FIL *)f->priv;
    UINT bw = 0;
    if (f_write(fp, buf, n, &bw) != FR_OK) return -1;
    f->pos = (uint32_t)f_tell(fp);
    if (f->pos > f->size) f->size = f->pos;
    return (long)bw;
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

/* "/foo" -> "0:/foo" (the FatFs drive prefix). dst must hold path len + 3. */
static void ffpath(char *dst, const char *path)
{
    dst[0] = '0'; dst[1] = ':';
    int i = 0;
    while (path[i] && i < 253) { dst[2 + i] = path[i]; i++; }
    dst[2 + i] = 0;
}

/* metadata ops all run serialized in the fs task, so a single static FIL/FILINFO
 * (never nested) backs them without touching the open-file pool. */
static FIL     g_meta;
static FILINFO g_mfno;

/* If ffp is an XTLK symlink, return the target length (copying into tgt when non-NULL,
 * NUL-terminated); else -1. Caller has already fast-rejected on !AM_SYS where it can. */
static int slink_target(const char *ffp, char *tgt, int tsz)
{
    if (f_open(&g_meta, ffp, FA_READ) != FR_OK) return -1;
    uint8_t hdr[5]; UINT br = 0;
    int islink = (f_read(&g_meta, hdr, 5, &br) == FR_OK && br == 5 &&
                  hdr[0]=='X' && hdr[1]=='T' && hdr[2]=='L' && hdr[3]=='K' && hdr[4]==0);
    int n = -1;
    if (islink) {
        UINT tn = 0; int cap = tsz > 0 ? tsz - 1 : 0;
        if (tgt && cap > 0) { if (f_read(&g_meta, tgt, (UINT)cap, &tn) != FR_OK) tn = 0; tgt[tn] = 0; }
        else { FSIZE_t sz = f_size(&g_meta); tn = (UINT)(sz > 5 ? sz - 5 : 0); }
        n = (int)tn;
    }
    f_close(&g_meta);
    return n;
}

static int ff_readlink(vfs_mount *m, const char *path, char *buf, int sz)
{
    (void)m; char p[256]; ffpath(p, path);
    if (f_stat(p, &g_mfno) != FR_OK) return -1;
    if (!(g_mfno.fattrib & AM_SYS)) return -1;                 /* fast reject: not a symlink */
    return slink_target(p, buf, sz);
}

static int ff_stat(vfs_mount *m, const char *path, struct xt_stat *st)
{
    (void)m;
    if (path[0] == 0 || (path[0] == '/' && path[1] == 0)) {    /* mount root: f_stat("0:/") is invalid */
        st->mode = XT_S_IFDIR; st->size = 0; st->mtime = 0; return 0;
    }
    char p[256]; ffpath(p, path);
    if (f_stat(p, &g_mfno) != FR_OK) return -1;
    uint32_t mode, size = (uint32_t)g_mfno.fsize;
    if (g_mfno.fattrib & AM_DIR) mode = XT_S_IFDIR;
    else if (g_mfno.fattrib & AM_SYS) {
        int tl = slink_target(p, 0, 0);
        if (tl >= 0) { mode = XT_S_IFLNK; size = (uint32_t)tl; } else mode = XT_S_IFREG;
    } else mode = XT_S_IFREG;
    st->mode = mode; st->size = size;
    st->mtime = ((uint32_t)g_mfno.fdate << 16) | g_mfno.ftime;  /* FAT packed date:time */
    return 0;
}

static int ff_unlink(vfs_mount *m, const char *path)
{
    (void)m; char p[256]; ffpath(p, path);
    return (f_unlink(p) == FR_OK) ? 0 : -1;
}

static int ffeq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == 0 && *b == 0; }

/* One open DIR cursor caches the last enumeration position, so sequential readdir
 * (index 0,1,2,...) is O(N); a non-sequential index re-opens + skips. Stateless API,
 * no per-fd/handle/reap machinery — and serialized in the fs task, so one cursor is safe. */
static DIR  g_rdir;
static char g_rdir_path[256];
static int  g_rdir_open, g_rdir_next;

static int ff_readdir(vfs_mount *m, const char *path, int index, char *name, int nsz, unsigned *mode)
{
    (void)m; char p[256]; ffpath(p, path);
    if (!(g_rdir_open && g_rdir_next == index && ffeq(g_rdir_path, p))) {
        if (g_rdir_open) { f_closedir(&g_rdir); g_rdir_open = 0; }
        if (f_opendir(&g_rdir, p) != FR_OK) return -1;
        int i = 0; while (p[i] && i < 255) { g_rdir_path[i] = p[i]; i++; } g_rdir_path[i] = 0;
        g_rdir_open = 1; g_rdir_next = 0;
        for (int k = 0; k < index; k++) {                     /* skip to the requested index */
            if (f_readdir(&g_rdir, &g_mfno) != FR_OK || !g_mfno.fname[0]) break;
            g_rdir_next++;
        }
    }
    if (f_readdir(&g_rdir, &g_mfno) != FR_OK) { f_closedir(&g_rdir); g_rdir_open = 0; return -1; }
    g_rdir_next++;
    if (!g_mfno.fname[0]) { f_closedir(&g_rdir); g_rdir_open = 0; return 0; }   /* end of dir */
    int i = 0; while (g_mfno.fname[i] && i < nsz - 1) { name[i] = g_mfno.fname[i]; i++; } name[i] = 0;
    *mode = (g_mfno.fattrib & AM_DIR) ? XT_S_IFDIR : XT_S_IFREG;   /* type hint; lstat for the truth */
    return 1;
}

static int ff_symlink(vfs_mount *m, const char *target, const char *path)
{
    (void)m; char p[256]; ffpath(p, path);
    if (f_open(&g_meta, p, FA_CREATE_ALWAYS | FA_WRITE) != FR_OK) return -1;
    static const uint8_t magic[5] = { 'X','T','L','K',0 };
    UINT bw = 0; int ok = (f_write(&g_meta, magic, 5, &bw) == FR_OK && bw == 5);
    int tl = 0; while (target[tl]) tl++;
    if (ok && (f_write(&g_meta, target, (UINT)tl, &bw) != FR_OK || bw != (UINT)tl)) ok = 0;
    f_close(&g_meta);
    if (!ok) { f_unlink(p); return -1; }
    if (f_chmod(p, AM_SYS, AM_SYS) != FR_OK) return -1;        /* mark it a symlink */
    return 0;
}

static int ff_open(vfs_mount *m, const char *path, int flags, vfs_file *f)
{
    (void)m;
    int h = -1;
    for (int i = 0; i < NFIL; i++) if (!used[i]) { h = i; break; }
    if (h < 0) return -1;
    /* prefix the FatFs drive: "/foo" -> "0:/foo" */
    char p[256];
    ffpath(p, path);
    /* map VFS open flags -> FatFs mode */
    BYTE mode;
    if (!(flags & VFS_O_ACCMODE)) mode = FA_READ;                         /* read-only */
    else {
        mode = FA_READ | FA_WRITE;
        if (flags & VFS_O_TRUNC)      mode |= FA_CREATE_ALWAYS;           /* create/truncate */
        else if (flags & VFS_O_CREAT) mode |= FA_OPEN_ALWAYS;             /* create if absent */
        else                          mode |= FA_OPEN_EXISTING;
    }
    if (f_open(&pool[h], p, mode) != FR_OK) return -1;
    used[h] = 1;
    f->priv = &pool[h];
    f->size = (uint32_t)f_size(&pool[h]);
    f->pos = 0; f->data = 0;
    f->read = ff_rd; f->write = (flags & VFS_O_ACCMODE) ? ff_wr : 0;
    f->lseek = ff_sk; f->close = ff_cl;
    return 0;
}

static vfs_fs fatfs_fs = { "fatfs", ff_open, 1 /* serialized: backing-store */,
                           ff_readlink, ff_stat, ff_unlink, ff_symlink, ff_readdir };

void vfs_fatfs_init(void) { vfs_register_fs(&fatfs_fs); }
