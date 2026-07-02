/* vfs_ramfs.c — a small writable in-memory filesystem (a tmpfs, mounted /tmp).
 *
 * Its job is to give the page store (docs/OS/fs-pagecache.md step 3c) a WRITABLE
 * backing on qemu, where the only other backends are read-only (romfs) or HW-only
 * (SD/fatfs). So it is a BACKING-STORE driver (f->data = NULL): reads and writes go
 * through the fs task's page cache (fill via ramfs read, flush via ramfs write) exactly
 * as SD does — the same code path, minus the FatFs leaf. serialized=0: it's only ever
 * touched by the single fs task (open/close/fill/flush), so it needs no shared lock.
 *
 * A file is a flat-namespace node whose bytes live in a list of pool pages (the same
 * DDR pool the cache draws from), grown on write. Non-persistent by nature. */
#include "vfs.h"
#include <stdint.h>
#include <string.h>

extern void *vm_page_alloc(void);        /* raw pool page (frtos_os.h) */
extern void  vm_page_free(void *p);

#define RAMFS_FILES 8
#define RAMFS_PAGES 16                    /* 64 KB max per file — ample for tests */
#define NAME_MAX    64

typedef struct {
    int      used;
    int      islink;                      /* 1: a symlink (content = target path) */
    char     name[NAME_MAX];              /* rel path within the mount, e.g. "/foo" */
    uint32_t size;
    void    *pg[RAMFS_PAGES];             /* page-indexed content (NULL = hole -> zero) */
} rnode;

static rnode g_rn[RAMFS_FILES];

static int streq(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return *a == 0 && *b == 0; }

static rnode *find(const char *name)
{
    for (int i = 0; i < RAMFS_FILES; i++)
        if (g_rn[i].used && streq(g_rn[i].name, name)) return &g_rn[i];
    return 0;
}

static void free_pages(rnode *nd)
{
    for (int i = 0; i < RAMFS_PAGES; i++) if (nd->pg[i]) { vm_page_free(nd->pg[i]); nd->pg[i] = 0; }
    nd->size = 0;
}

/* page-aware read/write against the node's page list. The page store always fills and
 * flushes on 4 KB boundaries, so these only ever see page-aligned f->pos in practice —
 * but they handle arbitrary offsets so a direct (uncached) caller works too. */
static long rf_read(vfs_file *f, void *buf, uint32_t n)
{
    rnode *nd = (rnode *)f->priv;
    if (f->pos >= nd->size) return 0;
    uint32_t avail = nd->size - f->pos; if (n > avail) n = avail;
    uint32_t done = 0, pos = f->pos;
    while (done < n) {
        uint32_t pi = pos >> 12, off = pos & 0xFFFu, want = 0x1000u - off;
        if (want > n - done) want = n - done;
        if (nd->pg[pi]) memcpy((uint8_t *)buf + done, (uint8_t *)nd->pg[pi] + off, want);
        else            memset((uint8_t *)buf + done, 0, want);           /* sparse hole */
        done += want; pos += want;
    }
    f->pos = pos;
    return (long)n;
}

static long rf_write(vfs_file *f, const void *buf, uint32_t n)
{
    rnode *nd = (rnode *)f->priv;
    uint32_t done = 0, pos = f->pos;
    while (done < n) {
        uint32_t pi = pos >> 12;
        if (pi >= RAMFS_PAGES) break;                                     /* file size cap */
        uint32_t off = pos & 0xFFFu, want = 0x1000u - off;
        if (want > n - done) want = n - done;
        if (!nd->pg[pi]) { nd->pg[pi] = vm_page_alloc(); if (!nd->pg[pi]) break;
                           memset(nd->pg[pi], 0, 0x1000u); }
        memcpy((uint8_t *)nd->pg[pi] + off, (const uint8_t *)buf + done, want);
        done += want; pos += want;
    }
    f->pos = pos;
    if (pos > nd->size) nd->size = pos;
    return (long)done;
}

static long rf_lseek(vfs_file *f, long off, int whence)
{
    rnode *nd = (rnode *)f->priv;
    long base = (whence == 1) ? (long)f->pos : (whence == 2) ? (long)nd->size : 0;
    long np = base + off;
    if (np < 0) return -1;                                                /* may seek past EOF (write grows) */
    f->pos = (uint32_t)np;
    return np;
}

static void rf_close(vfs_file *f) { (void)f; }                           /* content persists in the node */

static int rf_open(vfs_mount *m, const char *path, int flags, vfs_file *f)
{
    (void)m;
    rnode *nd = find(path);
    if (!nd) {
        if (!(flags & VFS_O_CREAT)) return -1;                           /* not found, no create */
        for (int i = 0; i < RAMFS_FILES; i++) if (!g_rn[i].used) { nd = &g_rn[i]; break; }
        if (!nd) return -1;                                              /* table full */
        nd->used = 1; nd->size = 0; nd->islink = 0;
        for (int i = 0; i < RAMFS_PAGES; i++) nd->pg[i] = 0;
        int j = 0; while (path[j] && j < NAME_MAX - 1) { nd->name[j] = path[j]; j++; } nd->name[j] = 0;
    } else if (flags & VFS_O_TRUNC) {
        free_pages(nd);
    }
    f->priv = nd; f->data = 0; f->size = nd->size; f->pos = 0;
    f->read = rf_read; f->write = (flags & VFS_O_ACCMODE) ? rf_write : 0;
    f->lseek = rf_lseek; f->close = rf_close;
    return 0;
}

/* symlinks (so the resolver + metadata syscalls are testable on qemu, where there is
 * no SD/fatfs). A link's node holds the target path as its content; islink flags it. */
static int rf_symlink(vfs_mount *m, const char *target, const char *path)
{
    (void)m;
    rnode *nd = find(path);
    if (nd) free_pages(nd);
    else {
        for (int i = 0; i < RAMFS_FILES; i++) if (!g_rn[i].used) { nd = &g_rn[i]; break; }
        if (!nd) return -1;
        nd->used = 1;
        for (int i = 0; i < RAMFS_PAGES; i++) nd->pg[i] = 0;
        int j = 0; while (path[j] && j < NAME_MAX - 1) { nd->name[j] = path[j]; j++; } nd->name[j] = 0;
    }
    nd->size = 0; nd->islink = 1;
    vfs_file f; f.priv = nd; f.pos = 0;                       /* reuse rf_write to store the target */
    rf_write(&f, target, (uint32_t)strlen(target));
    return 0;
}
static int rf_readlink(vfs_mount *m, const char *path, char *buf, int sz)
{
    (void)m;
    rnode *nd = find(path);
    if (!nd || !nd->islink) return -1;
    uint32_t n = nd->size; if (sz > 0 && n > (uint32_t)(sz - 1)) n = (uint32_t)(sz - 1);
    vfs_file f; f.priv = nd; f.pos = 0;
    long r = rf_read(&f, buf, n); if (r < 0) r = 0;
    buf[r] = 0;
    return (int)r;
}
static int rf_stat(vfs_mount *m, const char *path, struct xt_stat *st)
{
    (void)m;
    if (path[0] == 0 || (path[0] == '/' && path[1] == 0)) { st->mode = XT_S_IFDIR; st->size = 0; st->mtime = 0; return 0; }
    rnode *nd = find(path);
    if (!nd) return -1;
    st->mode = nd->islink ? XT_S_IFLNK : XT_S_IFREG;
    st->size = nd->size; st->mtime = 0;
    return 0;
}
static int rf_unlink(vfs_mount *m, const char *path)
{
    (void)m;
    rnode *nd = find(path);
    if (!nd) return -1;
    free_pages(nd); nd->used = 0; nd->islink = 0;
    return 0;
}

static vfs_fs ramfs_fs = { "ramfs", rf_open, 0 /* reentrant: fs-task-serialized, no block device */,
                           rf_readlink, rf_stat, rf_unlink, rf_symlink };

void vfs_ramfs_init(void) { vfs_register_fs(&ramfs_fs); }
