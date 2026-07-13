/* ============================================================================
 * ⚠ REFERENCE ONLY — THIS FILE IS NOT BUILT, NOT LINKED, NOT RUN.
 *
 * This is the RETIRED bare-metal XTOS. The live operating system is in loader/.
 * Do not "fix" this file; do not assume it reflects the running system.
 * See reference/vitis-baremetal/README.md.
 * ============================================================================ */
// vfs.c — VFS dispatcher + newlib file syscalls.
//
// Owns the fd table and the strong _open/_read/_write/_close/_lseek/_fstat/
// _unlink (overriding the BSP's weak stubs).  fd 0/1/2 = the UART console;
// fd>=3 = an open file routed to the backend that claims its path.  So fopen/
// fread/FreeType/Lua-io read whatever backend owns the path: FatFs (SD) at "/",
// tmpfs (RAM) at "/tmp".

#include <errno.h>
#include <sys/stat.h>
#include <string.h>
#include "vfs.h"

#ifndef SEEK_SET
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
#endif

#define VFS_MAXFS 4
#define VFS_MAXFD 12

static const vfs_fs *fstab[VFS_MAXFS];
static int           nfs = 0;
static struct { const vfs_fs *fs; int bh; char used; } fdtab[VFS_MAXFD];

static void cons_putc(char c)
{
    volatile unsigned *u = (volatile unsigned *)0xE0001000u;
    while (u[0x2C / 4] & 0x10u) { }
    u[0x30 / 4] = (unsigned char)c;
}

void vfs_register(const vfs_fs *fs) { if (nfs < VFS_MAXFS) fstab[nfs++] = fs; }

const vfs_fs *vfs_lookup(const char *path)
{
    const vfs_fs *best = (void *)0;
    unsigned bl = 0;
    for (int i = 0; i < nfs; i++) {
        const char *p = fstab[i]->prefix;
        unsigned l = (unsigned)strlen(p);
        /* match when path == prefix or path starts with "prefix/" (a "/" prefix
         * is the catch-all) */
        if (strncmp(path, p, l) == 0 && (l == 1 || path[l] == '\0' || path[l] == '/')) {
            if (l >= bl) { bl = l; best = fstab[i]; }
        }
    }
    return best;
}

/* ---- current directory + relative-path resolution --------------------- */
static char vfs_cwd[VFS_PATH_MAX] = "/";

void vfs_abspath(const char *in, char *out, int outsz)
{
    int i = 0;
    if (in[0] == '/') {                         /* already absolute */
        while (in[i] && i < outsz - 1) { out[i] = in[i]; i++; }
        out[i] = 0;
        return;
    }
    const char *c = vfs_cwd;                     /* prepend cwd */
    while (*c && i < outsz - 1) out[i++] = *c++;
    if (i > 1 && out[i - 1] != '/' && i < outsz - 1) out[i++] = '/';  /* separator */
    while (*in && i < outsz - 1) out[i++] = *in++;
    out[i] = 0;
}

const char *vfs_getcwd(void) { return vfs_cwd; }

int vfs_chdir(const char *path)
{
    char a[VFS_PATH_MAX];
    vfs_abspath(path, a, sizeof a);
    int d = vfs_opendir(a);                      /* must be a real/valid directory */
    if (d < 0) return -1;
    vfs_closedir(d);
    int i = 0;
    while (a[i] && i < (int)sizeof(vfs_cwd) - 1) { vfs_cwd[i] = a[i]; i++; }
    vfs_cwd[i] = 0;
    return 0;
}

/* Is mount-prefix p a direct child of directory d? (e.g. "/tmp" under "/"). */
static int is_direct_child(const char *p, const char *d)
{
    size_t dl = strlen(d);
    while (dl > 1 && d[dl - 1] == '/') dl--;       /* ignore trailing '/', keep "/" */
    if (strncmp(p, d, dl) != 0) return 0;
    const char *rest = p + dl;
    if (dl > 1) { if (*rest != '/') return 0; rest++; }   /* non-root: need d + "/x" */
    if (*rest == '\0') return 0;                   /* p == d, not a child */
    if (strchr(rest, '/')) return 0;               /* deeper than a direct child */
    return 1;
}

#define VFS_MAXDIR 4
static struct { const vfs_fs *fs; int bh; int mit; char used; char path[VFS_PATH_MAX]; }
    vdir[VFS_MAXDIR];

int vfs_opendir(const char *path)
{
    char a[VFS_PATH_MAX];
    vfs_abspath(path, a, sizeof a);
    int i;
    for (i = 0; i < VFS_MAXDIR; i++) if (!vdir[i].used) break;
    if (i == VFS_MAXDIR) return -1;
    const vfs_fs *fs = vfs_lookup(a);
    vdir[i].fs  = fs;
    vdir[i].bh  = (fs && fs->diropen) ? fs->diropen(a) : -1;
    vdir[i].mit = 0;
    strncpy(vdir[i].path, a, VFS_PATH_MAX - 1);
    vdir[i].path[VFS_PATH_MAX - 1] = 0;
    vdir[i].used = 1;
    if (vdir[i].bh < 0) {                           /* no real dir — valid only if a mount lives here */
        int has_mount = 0;
        for (int k = 0; k < nfs; k++)
            if (strcmp(fstab[k]->prefix, "/") != 0 && is_direct_child(fstab[k]->prefix, a))
                { has_mount = 1; break; }
        if (!has_mount) { vdir[i].used = 0; return -1; }
    }
    return i;
}

int vfs_readdir(int d, struct vfs_dirent *o)
{
    if (d < 0 || d >= VFS_MAXDIR || !vdir[d].used) return -1;
    if (vdir[d].bh >= 0) {                          /* backend's own entries first */
        int r = vdir[d].fs->dirnext ? vdir[d].fs->dirnext(vdir[d].bh, o) : 0;
        if (r == 1) return 1;
        if (vdir[d].fs->dirclose) vdir[d].fs->dirclose(vdir[d].bh);
        vdir[d].bh = -1;
    }
    while (vdir[d].mit < nfs) {                     /* then inject child mount points */
        const vfs_fs *b = fstab[vdir[d].mit++];
        if (strcmp(b->prefix, "/") == 0) continue;
        if (is_direct_child(b->prefix, vdir[d].path)) {
            const char *base = strrchr(b->prefix, '/');
            base = base ? base + 1 : b->prefix;
            strncpy(o->name, base, VFS_NAME_MAX - 1);
            o->name[VFS_NAME_MAX - 1] = 0;
            o->is_dir = 1; o->size = 0;
            return 1;
        }
    }
    return 0;
}

void vfs_closedir(int d)
{
    if (d < 0 || d >= VFS_MAXDIR || !vdir[d].used) return;
    if (vdir[d].bh >= 0 && vdir[d].fs->dirclose) vdir[d].fs->dirclose(vdir[d].bh);
    vdir[d].used = 0;
}

int _open(const char *path, int flags, int mode)
{
    (void)mode;
    char a[VFS_PATH_MAX];
    vfs_abspath(path, a, sizeof a);
    const vfs_fs *fs = vfs_lookup(a);
    if (!fs || !fs->open) { errno = ENOENT; return -1; }
    int bh = fs->open(a, flags);
    if (bh < 0) { errno = ENOENT; return -1; }
    int i;
    for (i = 0; i < VFS_MAXFD; i++) if (!fdtab[i].used) break;
    if (i == VFS_MAXFD) { if (fs->close) fs->close(bh); errno = EMFILE; return -1; }
    fdtab[i].fs = fs; fdtab[i].bh = bh; fdtab[i].used = 1;
    return i + 3;
}

int _read(int fd, char *buf, int n)
{
    if (fd <= 2) return 0;
    int i = fd - 3;
    if (i < 0 || i >= VFS_MAXFD || !fdtab[i].used) { errno = EBADF; return -1; }
    return fdtab[i].fs->read ? fdtab[i].fs->read(fdtab[i].bh, buf, n) : -1;
}

int _write(int fd, char *buf, int n)
{
    if (fd == 1 || fd == 2) { for (int k = 0; k < n; k++) cons_putc(buf[k]); return n; }
    if (fd <= 2) return n;
    int i = fd - 3;
    if (i < 0 || i >= VFS_MAXFD || !fdtab[i].used) { errno = EBADF; return -1; }
    return fdtab[i].fs->write ? fdtab[i].fs->write(fdtab[i].bh, buf, n) : -1;
}

int _close(int fd)
{
    if (fd <= 2) return 0;
    int i = fd - 3;
    if (i < 0 || i >= VFS_MAXFD || !fdtab[i].used) { errno = EBADF; return -1; }
    int r = fdtab[i].fs->close ? fdtab[i].fs->close(fdtab[i].bh) : 0;
    fdtab[i].used = 0;
    return r;
}

off_t _lseek(int fd, off_t off, int whence)
{
    if (fd <= 2) return 0;
    int i = fd - 3;
    if (i < 0 || i >= VFS_MAXFD || !fdtab[i].used) { errno = EBADF; return -1; }
    return fdtab[i].fs->lseek ? (off_t)fdtab[i].fs->lseek(fdtab[i].bh, (long)off, whence) : -1;
}

int _fstat(int fd, struct stat *st)
{
    memset(st, 0, sizeof *st);
    if (fd <= 2) { st->st_mode = S_IFCHR; return 0; }
    int i = fd - 3;
    if (i < 0 || i >= VFS_MAXFD || !fdtab[i].used) { errno = EBADF; return -1; }
    st->st_mode = S_IFREG;
    st->st_size = fdtab[i].fs->size ? (off_t)fdtab[i].fs->size(fdtab[i].bh) : 0;
    return 0;
}

int _isatty(int fd) { return (fd <= 2) ? 1 : 0; }

int _unlink(const char *path)
{
    char a[VFS_PATH_MAX];
    vfs_abspath(path, a, sizeof a);
    const vfs_fs *fs = vfs_lookup(a);
    if (!fs || !fs->remove) { errno = ENOSYS; return -1; }
    return (fs->remove(a) == 0) ? 0 : (errno = EIO, -1);
}
int _link(const char *o, const char *n) { (void)o; (void)n; errno = ENOSYS; return -1; }
