/* vfs.c — mount table + open dispatch (see vfs.h). */
#include "vfs.h"

#define MAXFS  6
#define MAXMNT 6
static vfs_fs   *g_fs[MAXFS];   static int g_nfs;
static vfs_mount g_mnt[MAXMNT]; static int g_nmnt;

static int streq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == 0 && *b == 0;
}

int vfs_register_fs(vfs_fs *fs)
{
    if (!fs || g_nfs >= MAXFS) return -1;
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
    return m->fs->open(m, rel, f);
}
