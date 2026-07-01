/* vfs.c — mount table + open dispatch (see vfs.h). */
#include "vfs.h"
#include "FreeRTOS.h"
#include "semphr.h"

#define MAXFS  6
#define MAXMNT 6
static vfs_fs   *g_fs[MAXFS];   static int g_nfs;
static vfs_mount g_mnt[MAXMNT]; static int g_nmnt;

/* ONE lock shared by every serialized (backing-store) filesystem, so fatfs + minixfs
 * + swap on the same block device serialize together. Reentrant filesystems (romfs)
 * never take it. Created at first driver registration (boot, pre-scheduler). Callers
 * only ever hit it in task context — sys_* defers serialized-fd ops off the SVC
 * handler — so taking a (possibly blocking) mutex here is safe. */
static SemaphoreHandle_t g_vfs_mtx;
static void vfs_lock(void)   { if (g_vfs_mtx) xSemaphoreTake(g_vfs_mtx, portMAX_DELAY); }
static void vfs_unlock(void) { if (g_vfs_mtx) xSemaphoreGive(g_vfs_mtx); }

static int streq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == 0 && *b == 0;
}

int vfs_register_fs(vfs_fs *fs)
{
    if (!fs || g_nfs >= MAXFS) return -1;
    if (!g_vfs_mtx) g_vfs_mtx = xSemaphoreCreateMutex();   /* first driver creates the shared lock */
    g_fs[g_nfs++] = fs;
    return 0;
}

vfs_fs *vfs_find_fs(const char *name)
{
    for (int i = 0; i < g_nfs; i++)
        if (streq(g_fs[i]->name, name)) return g_fs[i];
    return 0;
}

int vfs_add_mount(const char *prefix, const char *fsname, void *priv)
{
    if (g_nmnt >= MAXMNT) return -1;
    vfs_fs *fs = vfs_find_fs(fsname);
    if (!fs) return -1;
    vfs_mount *m = &g_mnt[g_nmnt];
    int i = 0;
    while (prefix[i] && i < (int)sizeof m->prefix - 1) { m->prefix[i] = prefix[i]; i++; }
    m->prefix[i] = 0;
    m->fs = fs; m->priv = priv;
    g_nmnt++;
    return 0;
}

/* longest-prefix match; *rel = path relative to the chosen mount (leading '/'). */
static vfs_mount *resolve(const char *path, const char **rel)
{
    vfs_mount *best = 0; int blen = -1;
    for (int i = 0; i < g_nmnt; i++) {
        const char *p = g_mnt[i].prefix;
        int n = 0; while (p[n]) n++;
        int ok = 1;
        for (int j = 0; j < n; j++) if (path[j] != p[j]) { ok = 0; break; }
        if (!ok) continue;
        /* prefixes longer than "/" need a path boundary ('/' or end) after them */
        if (n > 1 && path[n] != 0 && path[n] != '/') continue;
        if (n > blen) { best = &g_mnt[i]; blen = n; }
    }
    if (!best) { *rel = path; return 0; }
    const char *r = (blen <= 1) ? path : path + blen;   /* "/" mount: keep full path */
    if (*r == 0) r = "/";
    *rel = r;
    return best;
}

int vfs_open(const char *path, vfs_file *f)
{
    const char *rel;
    vfs_mount *m = resolve(path, &rel);
    if (!m) return -1;
    f->read = 0; f->lseek = 0; f->close = 0;
    f->size = 0; f->pos = 0; f->data = 0; f->priv = 0; f->mnt = m;
    int ser = m->fs->serialized;
    if (ser) vfs_lock();
    int r = m->fs->open(m, rel, f);
    if (ser) vfs_unlock();
    return r;
}

/* op wrappers: take the shared lock only for serialized filesystems. */
long vfs_read(vfs_file *f, void *buf, uint32_t n)
{
    if (!f->read) return -1;
    int ser = f->mnt && f->mnt->fs->serialized;
    if (ser) vfs_lock();
    long r = f->read(f, buf, n);
    if (ser) vfs_unlock();
    return r;
}

long vfs_lseek(vfs_file *f, long off, int whence)
{
    if (!f->lseek) return -1;
    int ser = f->mnt && f->mnt->fs->serialized;
    if (ser) vfs_lock();
    long r = f->lseek(f, off, whence);
    if (ser) vfs_unlock();
    return r;
}

void vfs_close(vfs_file *f)
{
    if (!f->close) return;
    int ser = f->mnt && f->mnt->fs->serialized;
    if (ser) vfs_lock();
    f->close(f);
    if (ser) vfs_unlock();
}
