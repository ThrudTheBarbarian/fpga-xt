/* vfs.c — mount table + open dispatch (see vfs.h). */
#include "vfs.h"

#define MAXFS  6
#define MAXMNT 6
static vfs_fs   *g_fs[MAXFS];   static int g_nfs;
static vfs_mount g_mnt[MAXMNT]; static int g_nmnt;

/* No lock here: the fs service task is the SOLE driver of every backing-store
 * filesystem — clients route read/write/open/close/mmap through it, and the two
 * remaining kernel callers (open_lib_sd, sd_listdir) go through its kernel mailbox — so
 * FatFs is serialized STRUCTURALLY, not by a mutex (the interim g_vfs_mtx retired in fs
 * page-cache step 3c-4). sd_init's one-time mount runs at boot before the task serves
 * any request. romfs/ramfs are reentrant/in-memory. See docs/OS/fs-pagecache.md. */
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

/* /proc/mounts (and df): one "dev  mountpoint  fstype  opts 0 0" line per mount */
int vfs_mounts_str(char *out, int cap)
{
    int o = 0;
    for (int i = 0; i < g_nmnt && o < cap - 96; i++) {
        const char *dev = g_mnt[i].fs->name, *mp = g_mnt[i].prefix, *fs = g_mnt[i].fs->name;
        for (const char *s = dev; *s && o < cap-1; s++) out[o++] = *s;
        out[o++] = ' ';
        for (const char *s = mp; *s && o < cap-1; s++) out[o++] = *s;
        out[o++] = ' ';
        for (const char *s = fs; *s && o < cap-1; s++) out[o++] = *s;
        const char *tail = " rw,relatime 0 0\n";
        for (const char *s = tail; *s && o < cap-1; s++) out[o++] = *s;
    }
    out[o] = 0;
    return o;
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

/* ---- symlink resolution (mount-aware namei) ------------------------------- */
static int vlen(const char *s) { int n = 0; while (s[n]) n++; return n; }
static void vcpy(char *d, const char *s, int cap)
{ int i = 0; while (s[i] && i < cap - 1) { d[i] = s[i]; i++; } d[i] = 0; }

/* collapse "//", "/./" and "/x/../" in an absolute path (so relative link targets
 * with ".." resolve without FatFs rpath support). */
static void vfs_normalize(const char *in, char *out, int outsz)
{
    int oi = 0, i = 0;
    if (in[0] != '/') out[oi++] = '/';
    while (in[i]) {
        if (in[i] == '/') { if (!(oi > 0 && out[oi-1] == '/')) out[oi++] = '/'; i++; continue; }
        int s = i; while (in[i] && in[i] != '/') i++;
        int seg = i - s;
        if (seg == 1 && in[s] == '.') continue;                 /* "." -> nothing */
        if (seg == 2 && in[s] == '.' && in[s+1] == '.') {       /* ".." -> pop a segment */
            if (oi > 1 && out[oi-1] == '/') oi--;
            while (oi > 0 && out[oi-1] != '/') oi--;
            continue;
        }
        for (int k = s; k < i && oi < outsz - 1; k++) out[oi++] = in[k];
    }
    if (oi == 0) out[oi++] = '/';
    if (oi > 1 && out[oi-1] == '/') oi--;                        /* strip trailing '/' */
    out[oi] = 0;
}

/* ---- root aliases ---------------------------------------------------------
 * Synthetic symlinks in "/" giving the traditional Unix names while the real
 * trees stay segregated under /OS. They behave as symlinks everywhere:
 * readlink/lstat see the link, everything else follows it. */
static const struct { const char *name; const char *target; } g_alias[] = {
    { "/etc",  "/OS/etc"          },
    { "/boot", "/OS/boot"         },
    { "/dev",  "/OS/dev"          },
    { "/proc", "/OS/proc"         },
    { "/var",  "/OS/var"          },
    { "/lib",  "/OS/library"      },
};
#define NALIAS ((int)(sizeof g_alias / sizeof g_alias[0]))

static int alias_find(const char *np)
{
    for (int i = 0; i < NALIAS; i++)
        if (streq(np, g_alias[i].name)) return i;
    return -1;
}

long vfs_readlink(const char *path, char *buf, int sz)
{
    /* normalize like every other entry point: "/OS/./x" must reach the
     * driver as "/x" (FatFs has no rpath support — "." components fail) */
    char np[VFS_PATH_MAX];
    vfs_normalize(path, np, sizeof np);
    int a = alias_find(np);
    if (a >= 0) {
        const char *t = g_alias[a].target;
        int n = 0; while (t[n] && n < sz) { buf[n] = t[n]; n++; }
        return n;
    }
    const char *rel; vfs_mount *m = resolve(np, &rel);
    if (!m || !m->fs->readlink) return -1;
    return m->fs->readlink(m, rel, buf, sz);
}

/* Expand every symlink component of `in` into `out`. follow_leaf=0 leaves the final
 * component un-followed (for lstat/readlink/unlink/symlink-create). */
int vfs_resolve(const char *in, char *out, int outsz, int follow_leaf)
{
    char cur[VFS_PATH_MAX];
    vfs_normalize(in, cur, sizeof cur);
    for (int loops = 0; loops < VFS_SYMLOOP_MAX; loops++) {
        int len = vlen(cur), spliced = 0;
        for (int i = 1; i <= len; i++) {
            if (i < len && cur[i] != '/') continue;             /* component boundary */
            if (i == len && !follow_leaf) break;                /* don't follow the leaf */
            char prefix[VFS_PATH_MAX];
            for (int k = 0; k < i; k++) prefix[k] = cur[k]; prefix[i] = 0;
            char tgt[VFS_PATH_MAX];
            long n = vfs_readlink(prefix, tgt, sizeof tgt);
            if (n <= 0) continue;                               /* not a symlink -> keep walking */
            tgt[n] = 0;
            char nw[VFS_PATH_MAX]; int w = 0;
            if (tgt[0] == '/') {                                /* absolute target */
                for (int k = 0; tgt[k] && w < VFS_PATH_MAX-1; k++) nw[w++] = tgt[k];
            } else {                                            /* relative to the link's dir */
                int d = i; while (d > 0 && cur[d-1] != '/') d--;
                for (int k = 0; k < d && w < VFS_PATH_MAX-1; k++) nw[w++] = cur[k];
                for (int k = 0; tgt[k] && w < VFS_PATH_MAX-1; k++) nw[w++] = tgt[k];
            }
            for (int k = i; cur[k] && w < VFS_PATH_MAX-1; k++) nw[w++] = cur[k];  /* remainder */
            nw[w] = 0;
            vfs_normalize(nw, cur, sizeof cur);
            spliced = 1; break;
        }
        if (!spliced) { vcpy(out, cur, outsz); return 0; }
    }
    return -1;                                                  /* too many links -> ELOOP */
}

/* "/" belongs to no mount (it is pure namespace) and a mount root always
 * exists — both stat as plain directories without asking a driver. */
static int synth_dir(struct xt_stat *st)
{
    st->mode = XT_S_IFDIR; st->size = 0; st->mtime = 0;
    return 0;
}

long vfs_stat(const char *path, struct xt_stat *st)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(path, rp, sizeof rp, 1) != 0) return -1;    /* follow the leaf */
    if (rp[0] == '/' && !rp[1]) return synth_dir(st);
    const char *rel; vfs_mount *m = resolve(rp, &rel);
    if (!m) return -1;
    if (rel[0] == '/' && !rel[1]) return synth_dir(st);         /* mount root */
    if (!m->fs->stat) return -1;
    return m->fs->stat(m, rel, st);
}
long vfs_lstat(const char *path, struct xt_stat *st)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(path, rp, sizeof rp, 0) != 0) return -1;    /* the link itself */
    if (rp[0] == '/' && !rp[1]) return synth_dir(st);
    int a = alias_find(rp);
    if (a >= 0) {                                               /* root alias = symlink */
        st->mode = XT_S_IFLNK; st->size = (unsigned)vlen(g_alias[a].target); st->mtime = 0;
        return 0;
    }
    const char *rel; vfs_mount *m = resolve(rp, &rel);
    if (!m) return -1;
    if (rel[0] == '/' && !rel[1]) return synth_dir(st);         /* mount root */
    if (!m->fs->stat) return -1;
    return m->fs->stat(m, rel, st);
}
long vfs_unlink(const char *path)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(path, rp, sizeof rp, 0) != 0) return -1;
    const char *rel; vfs_mount *m = resolve(rp, &rel);
    if (!m || !m->fs->unlink) return -1;
    return m->fs->unlink(m, rel);
}
long vfs_symlink(const char *target, const char *linkpath)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(linkpath, rp, sizeof rp, 0) != 0) return -1;
    const char *rel; vfs_mount *m = resolve(rp, &rel);
    if (!m || !m->fs->symlink) return -1;
    return m->fs->symlink(m, target, rel);
}
/* enumerating "/" = the unique first components of the mount prefixes
 * ("/OS/var/locks" and "/OS" both contribute just "OS"), then the root
 * aliases as symlinks. The "/" mount's own files (BOOT.BIN, boot images)
 * are deliberately NOT listed — reachable by exact path, invisible to ls. */
static long root_readdir(int index, char *name, int nsz, unsigned *mode)
{
    int emitted = 0;
    for (int i = 0; i < g_nmnt; i++) {
        const char *p = g_mnt[i].prefix + 1;
        int n = 0; while (p[n] && p[n] != '/') n++;
        if (!n) continue;                                       /* the "/" mount */
        int dup = 0;
        for (int j = 0; j < i && !dup; j++) {
            const char *q = g_mnt[j].prefix + 1;
            int k = 0; while (q[k] && q[k] != '/') k++;
            if (k == n) {
                dup = 1;
                for (int t = 0; t < n; t++) if (p[t] != q[t]) { dup = 0; break; }
            }
        }
        if (dup) continue;
        if (emitted++ == index) {
            int t = 0;
            while (t < n && t < nsz - 1) { name[t] = p[t]; t++; }
            name[t] = 0;
            if (mode) *mode = XT_S_IFDIR;
            return 1;
        }
    }
    for (int i = 0; i < NALIAS; i++) {                          /* then the root aliases */
        if (emitted++ == index) {
            vcpy(name, g_alias[i].name + 1, nsz);
            if (mode) *mode = XT_S_IFLNK;
            return 1;
        }
    }
    if (emitted++ == index) {           /* /media: user-facing SD dir, listed by name
                                         * (the "/" mount's other files stay unlisted) */
        vcpy(name, "media", nsz);
        if (mode) *mode = XT_S_IFDIR;
        return 1;
    }
    return 0;
}

long vfs_readdir(const char *path, int index, char *name, int nsz, unsigned *mode)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(path, rp, sizeof rp, 1) != 0) return -1;    /* follow to the real dir */
    if (rp[0] == '/' && !rp[1]) return root_readdir(index, name, nsz, mode);
    const char *rel; vfs_mount *m = resolve(rp, &rel);
    if (!m || !m->fs->readdir) return -1;
    return m->fs->readdir(m, rel, index, name, nsz, mode);
}
long vfs_readdir_meta(const char *path, int index, struct vfs_dent *out)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(path, rp, sizeof rp, 1) != 0) return -1;   /* follow to the real dir */
    if (rp[0] == '/' && !rp[1]) return -2;                     /* root: synthetic, not cacheable */
    const char *rel; vfs_mount *m = resolve(rp, &rel);
    if (!m || !m->fs->readdir_meta) return -2;                 /* fs opts out -> caller falls back */
    return m->fs->readdir_meta(m, rel, index, out);
}
long vfs_mkdir(const char *path)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(path, rp, sizeof rp, 0) != 0) return -1;    /* create the leaf itself */
    const char *rel; vfs_mount *m = resolve(rp, &rel);
    if (!m || !m->fs->mkdir) return -1;
    return m->fs->mkdir(m, rel);
}
long vfs_rename(const char *oldp, const char *newp)
{
    char ro[VFS_PATH_MAX], rn[VFS_PATH_MAX];
    if (vfs_resolve(oldp, ro, sizeof ro, 0) != 0) return -1;
    if (vfs_resolve(newp, rn, sizeof rn, 0) != 0) return -1;
    const char *rel_o; vfs_mount *mo = resolve(ro, &rel_o);
    const char *rel_n; vfs_mount *mn = resolve(rn, &rel_n);
    if (!mo || !mn || mo != mn || !mo->fs->rename) return -1;   /* same mount only */
    return mo->fs->rename(mo, rel_o, rel_n);
}

int vfs_open(const char *path, int flags, vfs_file *f)
{
    char rp[VFS_PATH_MAX];
    if (vfs_resolve(path, rp, sizeof rp, 1) != 0) return -1;    /* follow symlinks */
    const char *rel;
    vfs_mount *m = resolve(rp, &rel);
    if (!m) return -1;
    f->read = 0; f->write = 0; f->lseek = 0; f->close = 0; f->ioctl = 0;
    f->size = 0; f->pos = 0; f->data = 0; f->priv = 0; f->mnt = m; f->chr = 0;
    return m->fs->open(m, rel, flags, f);
}

/* op wrappers: plain dispatch — serialization is structural (the fs task is the sole
 * driver of every backing-store fs; see the header note). */
long vfs_read(vfs_file *f, void *buf, uint32_t n)
{
    return f->read ? f->read(f, buf, n) : -1;
}

long vfs_write(vfs_file *f, const void *buf, uint32_t n)
{
    return f->write ? f->write(f, buf, n) : -1;          /* -1 if read-only */
}

long vfs_lseek(vfs_file *f, long off, int whence)
{
    return f->lseek ? f->lseek(f, off, whence) : -1;
}

void vfs_close(vfs_file *f)
{
    if (f->close) f->close(f);
}
