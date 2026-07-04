/*
 * posix_shim.c — the userland POSIX layer under toybox (and any future
 * unix-ish port). Linked INTO toybox.so, so toybox-internal references bind
 * here first; libc.so (newlib) supplies the ANSI layer above it and the
 * kernel export table supplies the _foo syscall primitives below it.
 *
 * Three kinds of function live here:
 *  - real implementations over the XTOS syscalls (stat family, dirent
 *    enumeration, the *at family, exec/vfork/waitpid, getcwd/chdir)
 *  - honest fakes for facilities XTOS doesn't have but a shell expects to
 *    interrogate (identity = root, terminal = 80x24 vt102, permissions
 *    succeed, mount table empty)
 *  - hard failures (pipe, dup2, sockets-adjacent) that Phase B's kernel
 *    pipe/spawn_fd work will replace
 *
 * Process model: there is no fork. vfork() snapshots the callee-saved
 * registers + sp + lr into a static area (naked asm, no stack frame of its
 * own — restoring the caller's sp exactly is what makes the trick sound)
 * and returns 0, so the caller runs the "child" codepath in-process; the
 * execv() that codepath must reach then SYS_spawns the program and restores
 * the snapshot, so vfork() returns a second time with the real pid — the
 * parent path. This matches how toybox uses XVFORK() on nommu targets:
 * everything between vfork and exec is idempotent parent-memory writes
 * (argv[0] high-bit marker, toys.stacktop = 0).
 */
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <dirent.h>
#include <termios.h>
#include <signal.h>
#include <poll.h>
#include <pwd.h>
#include <grp.h>
#include <paths.h>
#include <mntent.h>
#include <syslog.h>
#include <regex.h>
#include <sys/ioctl.h>
#include <sys/statvfs.h>
#include <sys/statfs.h>
#include <sys/utsname.h>
#include <sys/mman.h>
#include <sys/uio.h>
#include <sys/resource.h>

#include "usys.h"   /* raw svc #1 wrappers + xtsys.h syscall numbers */

#ifndef AT_FDCWD
#define AT_FDCWD -2
#endif
#ifndef AT_SYMLINK_NOFOLLOW
#define AT_SYMLINK_NOFOLLOW 0x100
#endif
#ifndef WNOHANG
#define WNOHANG 1
#endif

/* the kernel-exported primitive close (libc.so's _close) */
extern int _close(int fd);

/* ---- environment ---------------------------------------------------------
 * toybox manipulates the environ array directly (lib/env.c) and calls
 * getenv/setenv; both must see the SAME array, and libc.so's newlib getenv
 * would read newlib's own (empty) environ — so the whole family lives here. */
static char *g_env0[] = {
    "PATH=/System/bin:/OS/bin:/bin",
    "HOME=/media/home",         /* login scripts, ssh config, ~ expansion live here */
    "TERM=vt102",
    "TZ=GMT0",                  /* UTC fallback; /OS/etc/timezone overrides at first use */
    "_=/System/bin/toybox",     /* toybox's nommu re-exec fallback path */
    0,
};
char **environ = g_env0;

/* Resolve the system timezone the first time TZ is looked up (by tzset): read
 * the zone NAME from /OS/etc/timezone, map it to a POSIX TZ string via
 * /OS/etc/tz.tab ("name  POSIX-TZ" lines), and setenv it. A name not in the
 * table is used verbatim (so an advanced user can put a POSIX string straight
 * into /OS/etc/timezone). No files -> the GMT0 default stands. newlib's tzset
 * understands POSIX TZ only (no zoneinfo db), which is why the table exists. */
static void load_tz(void)
{
    FILE *tf = fopen("/OS/etc/timezone", "r");
    if (!tf) return;
    char zone[64];
    if (!fgets(zone, sizeof zone, tf)) { fclose(tf); return; }
    fclose(tf);
    zone[strcspn(zone, "\r\n")] = 0;
    while (*zone && (zone[strlen(zone)-1] == ' ' || zone[strlen(zone)-1] == '\t'))
        zone[strlen(zone)-1] = 0;
    if (!zone[0]) return;

    FILE *tab = fopen("/OS/etc/tz.tab", "r");
    if (tab) {
        char line[160];
        while (fgets(line, sizeof line, tab)) {
            if (line[0] == '#') continue;
            char *nm = strtok(line, " \t\r\n");
            char *tz = nm ? strtok(NULL, "\r\n") : 0;
            if (tz) { while (*tz == ' ' || *tz == '\t') tz++; }
            if (nm && tz && *tz && !strcmp(nm, zone)) { setenv("TZ", tz, 1); fclose(tab); return; }
        }
        fclose(tab);
    }
    setenv("TZ", zone, 1);                    /* not in the table: take it verbatim */
}

char *getenv(const char *name)
{
    static int tz_done = 0;                   /* /OS/etc/timezone -> TZ, once, on first TZ lookup */
    if (!tz_done && name[0] == 'T' && name[1] == 'Z' && !name[2]) { tz_done = 1; load_tz(); }
    int n = strlen(name);
    for (char **e = environ; e && *e; e++)
        if (!strncmp(*e, name, n) && (*e)[n] == '=') return *e + n + 1;
    return 0;
}

int setenv(const char *name, const char *val, int overwrite)
{
    int n = strlen(name), count = 0;
    char **e, **ne, *slot;

    for (e = environ; *e; e++, count++)
        if (!strncmp(*e, name, n) && (*e)[n] == '=') {
            if (!overwrite) return 0;
            slot = malloc(n + strlen(val) + 2);
            if (!slot) return -1;
            sprintf(slot, "%s=%s", name, val);
            *e = slot;                       /* old entry may leak: fine */
            return 0;
        }
    ne = malloc((count + 2) * sizeof(char *));
    if (!ne) return -1;
    memcpy(ne, environ, count * sizeof(char *));
    slot = malloc(n + strlen(val) + 2);
    if (!slot) { free(ne); return -1; }
    sprintf(slot, "%s=%s", name, val);
    ne[count] = slot;
    ne[count + 1] = 0;
    environ = ne;                            /* old array may leak: fine */
    return 0;
}

int unsetenv(const char *name)
{
    int n = strlen(name);
    for (char **e = environ; *e; e++)
        if (!strncmp(*e, name, n) && (*e)[n] == '=') {
            do { e[0] = e[1]; } while (*e++);
            return 0;
        }
    return 0;
}

int putenv(char *str)
{
    char *eq = strchr(str, '=');
    if (!eq) return unsetenv(str);
    *eq = 0;
    int r = setenv(str, eq + 1, 1);
    *eq = '=';
    return r;
}

/* ---- stat family ---------------------------------------------------------
 * struct xt_stat carries {mode,size,mtime}; everything else is synthesized
 * (single-user system: root owns the world, permissions are decorative).
 * st_ino is a hash of the path — stable, distinct-enough identity so
 * same-file checks (tar's input==archive, cp's src==dst) work. */
static unsigned path_ino(const char *path)
{
    unsigned h = 2166136261u;
    while (*path) { h ^= (unsigned char)*path++; h *= 16777619u; }
    return h ? h : 1;
}

static void st_from_xt(struct stat *st, const struct xt_stat *xs, const char *path)
{
    memset(st, 0, sizeof *st);
    st->st_mode = (xs->mode & XT_S_IFMT) |
                  (((xs->mode & XT_S_IFMT) == XT_S_IFDIR) ? 0755 : 0644);
    st->st_size = xs->size;
    st->st_mtime = st->st_atime = st->st_ctime = xs->mtime;
    st->st_nlink = 1;
    st->st_dev = 1;
    st->st_ino = path ? path_ino(path) : 0;
    st->st_blksize = 4096;
    st->st_blocks = (xs->size + 511) / 512;
}

int stat(const char *__restrict path, struct stat *__restrict st)
{
    struct xt_stat xs;
    if (sys_stat(path, &xs) < 0) { errno = ENOENT; return -1; }
    st_from_xt(st, &xs, path);
    return 0;
}

int lstat(const char *__restrict path, struct stat *__restrict st)
{
    struct xt_stat xs;
    if (sys_lstat(path, &xs) < 0) { errno = ENOENT; return -1; }
    st_from_xt(st, &xs, path);
    return 0;
}

/* ---- directory enumeration + pseudo-fds ----------------------------------
 * SYS_readdir is stateless (path + index), so a DIR is just a path and a
 * cursor. Directories also need FDs (toybox's dirtree walks with
 * openat/fdopendir/fstatat), and the kernel can't open a directory — so
 * directory fds are shim-local pseudo-fds >= XT_PFD_BASE holding the path. */
#define XT_PFD_BASE 0x1000
#define XT_PFD_MAX  32
static struct { char path[512]; int used; } g_pfd[XT_PFD_MAX];

static int pfd_alloc(const char *path)
{
    for (int i = 0; i < XT_PFD_MAX; i++)
        if (!g_pfd[i].used) {
            g_pfd[i].used = 1;
            strncpy(g_pfd[i].path, path, sizeof g_pfd[i].path - 1);
            g_pfd[i].path[sizeof g_pfd[i].path - 1] = 0;
            return XT_PFD_BASE + i;
        }
    errno = EMFILE;
    return -1;
}

static const char *pfd_path(int fd)
{
    int i = fd - XT_PFD_BASE;
    if (i < 0 || i >= XT_PFD_MAX || !g_pfd[i].used) return 0;
    return g_pfd[i].path;
}

/* join (dirfd, maybe-relative path) into buf; NULL result = pass through */
static const char *at_join(int dirfd, const char *path, char *buf, int len)
{
    const char *base;
    if (path[0] == '/' || dirfd == AT_FDCWD) return path;
    base = pfd_path(dirfd);
    if (!base) { errno = EBADF; return 0; }
    snprintf(buf, len, "%s/%s", base, path);
    return buf;
}

struct __xt_DIR {
    int pfd;                 /* pseudo-fd owning the path (closed on closedir) */
    int idx;                 /* SYS_readdir cursor */
    struct dirent de;
};

DIR *fdopendir(int fd)
{
    DIR *d;
    if (!pfd_path(fd)) { errno = EBADF; return 0; }
    d = calloc(1, sizeof *d);
    if (d) d->pfd = fd;
    return d;
}

DIR *opendir(const char *path)
{
    struct xt_stat xs;
    int fd;
    if (sys_stat(path, &xs) < 0) { errno = ENOENT; return 0; }
    if ((xs.mode & XT_S_IFMT) != XT_S_IFDIR) { errno = ENOTDIR; return 0; }
    fd = pfd_alloc(path);
    if (fd < 0) return 0;
    return fdopendir(fd);
}

struct dirent *readdir(DIR *d)
{
    struct xt_dirent xe;
    const char *path = d ? pfd_path(d->pfd) : 0;
    if (!path) return 0;
    if (sys_readdir(path, d->idx, &xe) != 1) return 0;
    d->idx++;
    memset(&d->de, 0, sizeof d->de);
    d->de.d_ino = d->idx;
    d->de.d_type = IFTODT(xe.mode & XT_S_IFMT);
    strncpy(d->de.d_name, xe.name, sizeof d->de.d_name - 1);
    return &d->de;
}

void rewinddir(DIR *d) { if (d) d->idx = 0; }
int dirfd(DIR *d) { return d ? d->pfd : -1; }

int closedir(DIR *d)
{
    if (!d) return -1;
    int i = d->pfd - XT_PFD_BASE;
    if (i >= 0 && i < XT_PFD_MAX) g_pfd[i].used = 0;
    free(d);
    return 0;
}

/* open must be dir-aware (toybox opens directories to walk them: ls's
 * listfiles, dirtree's openat) — a directory open yields a pseudo-fd */
int open(const char *path, int flags, ...)
{
    struct xt_stat xs;
    if (sys_stat(path, &xs) == 0 && (xs.mode & XT_S_IFMT) == XT_S_IFDIR)
        return pfd_alloc(path);
    long fd = sys_open(path, flags & 0xfff);   /* strip O_CLOEXEC and friends */
    if (fd < 0) { errno = ENOENT; return -1; }
    return fd;
}

/* fd bookkeeping between vfork and exec — the "child" is still this process:
 * - dup2 onto 0/1/2 is RECORDED (g_redir) and becomes SYS_spawn_fd's stdio map
 * - close() in the fake child is a NO-OP on the parent's table (in real vfork
 *   the child closes its own copy); it just marks the fd not-inherited
 * - fcntl FD_CLOEXEC is tracked here and merged into the same mask
 * The kernel inherits every unmasked parent pipe fd >=3 at the same slot. */
static unsigned g_vfork_regs[11];        /* defined with the vfork asm below */
#define g_vfork_armed (g_vfork_regs[10])
static int g_redir[3] = { -1, -1, -1 };
static unsigned g_child_closed;          /* fds the fake child "closed" */
static unsigned g_cloexec;               /* fds marked close-on-exec */

static void redir_reset(void)
{
    for (int i = 0; i < 3; i++) g_redir[i] = -1;
    g_child_closed = 0;
}

/* close/fstat/dup must understand pseudo-fds; real fds go to the kernel */
int close(int fd)
{
    int i = fd - XT_PFD_BASE;
    if (i >= 0 && i < XT_PFD_MAX) { g_pfd[i].used = 0; return 0; }
    if (g_vfork_armed && fd >= 0 && fd < 16) {   /* fake child: parent's table untouched */
        g_child_closed |= 1u << fd;
        return 0;
    }
    if (fd >= 0 && fd < 16) g_cloexec &= ~(1u << fd);
    return _close(fd);
}

int fcntl(int fd, int cmd, ...)
{
    va_list ap;
    long arg;
    va_start(ap, cmd);
    arg = va_arg(ap, long);
    va_end(ap);
    if (fd < 0 || fd >= 16) { errno = EBADF; return -1; }
    switch (cmd) {
    case 1 /*F_GETFD*/: return (g_cloexec >> fd) & 1;
    case 2 /*F_SETFD*/:
        if (arg & 1) g_cloexec |= 1u << fd; else g_cloexec &= ~(1u << fd);
        return 0;
    case 3 /*F_GETFL*/: {                /* doubles as the "is this fd free" probe */
        struct xt_stat xs;
        if (sys_fstat(fd, &xs) == 0) return 0;
        errno = EBADF;
        return -1;
    }
    case 4 /*F_SETFL*/: return 0;
    }
    errno = EINVAL;
    return -1;
}

int fstat(int fd, struct stat *st)
{
    struct xt_stat xs;
    if (pfd_path(fd)) {
        memset(st, 0, sizeof *st);
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 1;
        st->st_blksize = 4096;
        return 0;
    }
    memset(st, 0, sizeof *st);
    if (sys_fstat(fd, &xs) == 0) {       /* kernel knows pipes/console/files */
        unsigned t = xs.mode & XT_S_IFMT;
        st->st_mode = (t == XT_S_IFIFO) ? (S_IFIFO | 0600)
                    : (t == XT_S_IFCHR) ? (S_IFCHR | 0620)
                    : (S_IFREG | 0644);
        st->st_size = xs.size;
        st->st_nlink = 1;
        st->st_blksize = 4096;
        return 0;
    }
    errno = EBADF;
    return -1;
}

int dup(int fd)
{
    const char *p = pfd_path(fd);
    if (p) return pfd_alloc(p);
    if (fd >= 0 && fd < 3) return fd;   /* console: same endpoint anyway */
    errno = ENOSYS;
    return -1;
}

int dup2(int oldfd, int newfd)
{
    if (oldfd == newfd) return newfd;
    if (g_vfork_armed && newfd >= 0 && newfd < 3) {
        g_redir[newfd] = oldfd;
        return newfd;
    }
    long r = sys_dup2(oldfd, newfd);     /* parent context: real pipe-end duplication */
    if (r < 0) { errno = EBADF; return -1; }
    g_cloexec &= ~(1u << newfd);
    return (int)r;
}

int pipe(int fd[2])
{
    if (sys_pipe(fd) < 0) { errno = EMFILE; return -1; }
    return 0;
}

/* ---- the *at family ------------------------------------------------------
 * All resolved to plain paths via the pseudo-fd registry. */
int openat(int dirfd, const char *path, int flags, ...)
{
    char buf[600];
    const char *p = at_join(dirfd, path, buf, sizeof buf);
    if (!p) return -1;
    return open(p, flags);
}

int fstatat(int dirfd, const char *path, struct stat *st, int flags)
{
    char buf[600];
    const char *p = at_join(dirfd, path, buf, sizeof buf);
    if (!p) return -1;
    return (flags & AT_SYMLINK_NOFOLLOW) ? lstat(p, st) : stat(p, st);
}

int faccessat(int dirfd, const char *path, int mode, int flags)
{
    struct stat st;
    (void)mode; (void)flags;
    return fstatat(dirfd, path, &st, 0);
}

/* the kernel's _isatty is a blind fd<3 — a child whose stdio is a pipe end
 * must answer honestly or ls/grep columnize into the pipeline */
int isatty(int fd)
{
    struct xt_stat xs;
    if (sys_fstat(fd, &xs) == 0) return (xs.mode & XT_S_IFMT) == XT_S_IFCHR;
    return fd < 3;
}

/* newlib's access() would bounce off the kernel's _stat stub */
int access(const char *path, int mode)
{
    struct xt_stat xs;
    (void)mode;                          /* exists == usable (root, mode 0755) */
    if (sys_stat(path, &xs) < 0) { errno = ENOENT; return -1; }
    return 0;
}

int unlinkat(int dirfd, const char *path, int flags)
{
    char buf[600];
    (void)flags;
    const char *p = at_join(dirfd, path, buf, sizeof buf);
    if (!p) return -1;
    if (sys_unlink(p) < 0) { errno = ENOENT; return -1; }
    return 0;
}

int mkdirat(int dirfd, const char *path, mode_t mode)
{
    char buf[600];
    const char *p = at_join(dirfd, path, buf, sizeof buf);
    if (!p) return -1;
    if (sys_mkdir(p, mode) < 0) { errno = EEXIST; return -1; }
    return 0;
}

ssize_t readlinkat(int dirfd, const char *path, char *out, size_t size)
{
    char buf[600];
    struct xt_stat xs;
    const char *p = at_join(dirfd, path, buf, sizeof buf);
    if (!p) return -1;
    long n = sys_readlink(p, out, size);
    if (n < 0) {
        /* callers (xabspath) branch on WHY: not-a-symlink vs doesn't-exist */
        errno = (sys_lstat(p, &xs) == 0) ? EINVAL : ENOENT;
        return -1;
    }
    return n;
}

int symlinkat(const char *target, int dirfd, const char *path)
{
    char buf[600];
    const char *p = at_join(dirfd, path, buf, sizeof buf);
    if (!p) return -1;
    if (sys_symlink(target, p) < 0) { errno = EEXIST; return -1; }
    return 0;
}

int linkat(int od, const char *op, int nd, const char *np, int flags)
{
    (void)od; (void)op; (void)nd; (void)np; (void)flags;
    errno = EPERM;                       /* no hard links on the VFS */
    return -1;
}

int mknodat(int dirfd, const char *path, mode_t mode, dev_t dev)
{
    (void)dirfd; (void)path; (void)mode; (void)dev;
    errno = EPERM;
    return -1;
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags)
{
    (void)dirfd; (void)path; (void)mode; (void)flags;
    return 0;                            /* permissions are decorative */
}

int fchownat(int dirfd, const char *path, uid_t o, gid_t g, int flags)
{
    (void)dirfd; (void)path; (void)o; (void)g; (void)flags;
    return 0;
}

int utimensat(int dirfd, const char *path, const struct timespec *ts, int fl)
{
    /* no stored timestamps, but existence must be honest — touch relies on
     * ENOENT here to know it has to create the file */
    struct stat st;
    (void)ts; (void)fl;
    return fstatat(dirfd, path, &st, 0);
}

int futimens(int fd, const struct timespec *ts)
{
    (void)fd; (void)ts;
    return 0;
}

/* ---- plain-path fs calls newlib routes nowhere ---------------------------- */
int chdir(const char *path)
{
    if (sys_chdir(path) < 0) { errno = ENOENT; return -1; }
    return 0;
}

char *getcwd(char *buf, size_t size)
{
    if (!buf) {                          /* glibc extension toybox relies on */
        size = size ? size : 512;
        buf = malloc(size);
        if (!buf) { errno = ENOMEM; return 0; }
        if (sys_getcwd(buf, size) < 0) { free(buf); errno = ERANGE; return 0; }
        return buf;
    }
    if (sys_getcwd(buf, size) < 0) { errno = ERANGE; return 0; }
    return buf;
}

ssize_t readlink(const char *__restrict path, char *__restrict buf, size_t size)
{
    struct xt_stat xs;
    long n = sys_readlink(path, buf, size);
    if (n < 0) {
        errno = (sys_lstat(path, &xs) == 0) ? EINVAL : ENOENT;
        return -1;
    }
    return n;
}

int mkdir(const char *path, mode_t mode)
{
    if (sys_mkdir(path, (int)mode) < 0) { errno = EEXIST; return -1; }
    return 0;
}

int symlink(const char *target, const char *linkpath)
{
    if (sys_symlink(target, linkpath) < 0) { errno = EEXIST; return -1; }
    return 0;
}

int fchdir(int fd)
{
    const char *p = pfd_path(fd);
    if (!p) { errno = EBADF; return -1; }
    return chdir(p);
}

int ftruncate(int fd, off_t length)
{
    (void)fd; (void)length;
    errno = ENOSYS;                      /* no truncate in the VFS yet */
    return -1;
}

long pathconf(const char *path, int name)
{
    (void)path;
    switch (name) {
    case 4 /*_PC_NAME_MAX*/: return 255;
    case 5 /*_PC_PATH_MAX*/: return 512;
    }
    return -1;
}

int rmdir(const char *path)
{
    struct xt_stat xs;
    if (sys_unlink(path) == 0) return 0;         /* drivers remove empty dirs */
    if (sys_lstat(path, &xs) < 0) errno = ENOENT;
    else if ((xs.mode & XT_S_IFMT) != XT_S_IFDIR) errno = ENOTDIR;
    else errno = ENOTEMPTY;
    return -1;
}

/* honest unlink (the kernel primitive doesn't set errno) */
int unlink(const char *path)
{
    struct xt_stat xs;
    if (sys_unlink(path) == 0) return 0;
    errno = (sys_lstat(path, &xs) == 0) ? EPERM : ENOENT;
    return -1;
}

/* newlib has no _rename glue here, so its rename() is ENOSYS — override it with
 * the real syscall (vi's .swp->file save, mv). The kernel replaces an existing
 * target, POSIX-style. */
int rename(const char *oldp, const char *newp)
{
    struct xt_stat xs;
    if (sys_rename(oldp, newp) == 0) return 0;
    errno = (sys_lstat(oldp, &xs) == 0) ? EACCES : ENOENT;
    return -1;
}

/* glibc-compatible wcwidth: -1 for control chars, not newlib's 0 — toybox vi's
 * cursor clamp relies on the truthiness of -1 to let the cursor rest on a
 * newline, so with 0 every EMPTY LINE was unreachable (the cursor slid back to
 * the previous line). Defined here so it overrides the libc.so import. */
int wcwidth(wchar_t wc)
{
    if (wc == 0) return 0;
    if (wc < 32 || (wc >= 0x7f && wc < 0xa0)) return -1;
    return 1;                            /* no double-width ranges on this console */
}

int mknod(const char *path, mode_t mode, dev_t dev)
{
    (void)path; (void)mode; (void)dev;
    errno = EPERM;                       /* no device nodes / FIFOs on the VFS */
    return -1;
}

int chmod(const char *path, mode_t mode) { (void)path; (void)mode; return 0; }
int fchmod(int fd, mode_t mode) { (void)fd; (void)mode; return 0; }
int fchown(int fd, uid_t o, gid_t g) { (void)fd; (void)o; (void)g; return 0; }
int lchown(const char *p, uid_t o, gid_t g) { (void)p; (void)o; (void)g; return 0; }
mode_t umask(mode_t mask) { (void)mask; return 022; }
int fsync(int fd) { (void)fd; return 0; }   /* page cache flushes on close */

ssize_t readv(int fd, const struct iovec *iov, int cnt)
{
    ssize_t total = 0;
    for (int i = 0; i < cnt; i++) {
        long n = sys_read(fd, iov[i].iov_base, iov[i].iov_len);
        if (n < 0) return total ? total : -1;
        total += n;
        if ((size_t)n < iov[i].iov_len) break;
    }
    return total;
}

ssize_t writev(int fd, const struct iovec *iov, int cnt)
{
    ssize_t total = 0;
    for (int i = 0; i < cnt; i++) {
        long n = sys_write(fd, iov[i].iov_base, iov[i].iov_len);
        if (n < 0) return total ? total : -1;
        total += n;
        if ((size_t)n < iov[i].iov_len) break;
    }
    return total;
}

/* ---- process: vfork / exec / waitpid --------------------------------------
 * See the file comment. The register snapshot is {r4-r11, sp, lr}; slot 10
 * is the armed flag (set by vfork, cleared by execve before restoring).
 * Addressing is PC-relative — this object links into a PIC .so. */
__asm__(".local g_vfork_regs");   /* asm below names it; keep it non-preemptible */
#define MAX_KIDS 64   /* concurrent children one process can track (waitpid/jobs) */
static int g_kids[MAX_KIDS];

__attribute__((naked)) pid_t vfork(void)
{
    __asm__ volatile(
        "ldr   r0, 1f            \n"
        "2: add r0, pc, r0       \n"
        "stmia r0, {r4-r11}      \n"
        "str   sp, [r0, #32]     \n"
        "str   lr, [r0, #36]     \n"
        "mov   r1, #1            \n"
        "str   r1, [r0, #40]     \n"   /* g_vfork_armed = 1 */
        "mov   r0, #0            \n"
        "bx    lr                \n"
        "1: .word g_vfork_regs - (2b + 8)\n");
}

/* second return from vfork(): restore the snapshot with r0 = pid */
__attribute__((naked)) static void vfork_return(int pid)
{
    __asm__ volatile(
        "ldr   r1, 1f            \n"
        "2: add r1, pc, r1       \n"
        "ldmia r1, {r4-r11}      \n"
        "ldr   sp, [r1, #32]     \n"
        "ldr   lr, [r1, #36]     \n"
        "bx    lr                \n"
        "1: .word g_vfork_regs - (2b + 8)\n");
}

static void kids_add(int pid)
{
    for (int i = 0; i < MAX_KIDS; i++)
        if (!g_kids[i]) { g_kids[i] = pid; return; }
}

/* A fake vfork child that _exits without ever reaching a successful exec
 * (command not found, redirect failed) must NOT kill the process — it
 * becomes a "ghost" child: waitpid hands back its exit code from a table.
 * Ghost pids sit above the kernel's range (max 8 real procs). */
#define GHOST_BASE 30000
static struct { int pid, code; } g_ghosts[MAX_KIDS];
static int g_ghost_seq;

void _exit(int code)
{
    if (g_vfork_armed) {
        g_vfork_armed = 0;
        redir_reset();                   /* drop recorded redirects + deferred closes */
        int pid = GHOST_BASE + (g_ghost_seq++ & 0x3fff);
        for (int i = 0; i < MAX_KIDS; i++)
            if (!g_ghosts[i].pid) { g_ghosts[i].pid = pid; g_ghosts[i].code = code; break; }
        vfork_return(pid);               /* parent sees a "child" that died */
    }
    sys_exit(code);
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    int argc = 0;
    long pid;
    (void)envp;                          /* spawn doesn't carry an env yet */

    /* toybox's nommu re-exec target */
    if (!strcmp(path, "/proc/self/exe")) path = "/System/bin/toybox";

    while (argv[argc]) argc++;
    (void)argc;
    /* spawn_fd always: stdio from the dup2 record, other pipe fds inherited
     * at the same slots minus what the fake child closed / marked cloexec */
    int fds[4] = { g_redir[0], g_redir[1], g_redir[2],
                   (int)(g_child_closed | g_cloexec) };
    pid = sys_spawn_fd(path, (char **)argv, fds);
    if (pid < 0) { errno = ENOENT; return -1; }

    if (g_vfork_armed) {                 /* "child" side of a vfork pair */
        g_vfork_armed = 0;
        redir_reset();                   /* child owns copies now; flush deferred closes */
        kids_add((int)pid);
        vfork_return((int)pid);          /* no return */
    }
    redir_reset();
    /* exec without vfork = process replacement: relay the child's exit */
    sys_exit((int)sys_waitpid((int)pid));
    return -1;                           /* unreachable */
}

int execv(const char *path, char *const argv[])
{
    return execve(path, argv, environ);
}

int execvp(const char *name, char *const argv[])
{
    char buf[600];
    const char *path;
    if (strchr(name, '/')) return execve(name, argv, environ);
    path = getenv("PATH");
    if (!path) path = _PATH_DEFPATH;
    while (*path) {
        const char *colon = strchr(path, ':');
        int n = colon ? (int)(colon - path) : (int)strlen(path);
        snprintf(buf, sizeof buf, "%.*s/%s", n, path, name);
        struct xt_stat xs;
        if (sys_stat(buf, &xs) == 0) return execve(buf, argv, environ);
        if (!colon) break;
        path = colon + 1;
    }
    errno = ENOENT;
    return -1;
}

pid_t waitpid(pid_t pid, int *status, int options)
{
    int i;
    /* ghost children first: their exit code is already known */
    for (i = 0; i < MAX_KIDS; i++)
        if (g_ghosts[i].pid && (pid <= 0 || pid == g_ghosts[i].pid)) {
            int gp = g_ghosts[i].pid;
            if (status) *status = (g_ghosts[i].code & 0xff) << 8;
            g_ghosts[i].pid = 0;
            return gp;
        }
    if (options & WNOHANG) {             /* poll: kernel checks the exited flag */
        if (pid > 0) {
            long code = sys_waitpid_nb((int)pid);
            if (code == -11) return 0;   /* still running */
            for (i = 0; i < MAX_KIDS; i++) if (g_kids[i] == pid) g_kids[i] = 0;
            if (code < 0) { errno = ECHILD; return -1; }
            if (status) *status = (int)((code & 0xff) << 8);
            return pid;
        }
        for (i = 0; i < MAX_KIDS; i++) { /* wait-any: poll each live child */
            if (!g_kids[i]) continue;
            long code = sys_waitpid_nb(g_kids[i]);
            if (code == -11) continue;
            int gp = g_kids[i];
            g_kids[i] = 0;
            if (code < 0) continue;      /* vanished: swept elsewhere; keep looking */
            if (status) *status = (int)((code & 0xff) << 8);
            return gp;
        }
        return 0;                        /* nothing exited yet */
    }
    if (pid <= 0) {                      /* wait-any: oldest live child */
        for (i = 0; i < MAX_KIDS; i++) if (g_kids[i]) { pid = g_kids[i]; break; }
        if (i == MAX_KIDS || pid <= 0) { errno = ECHILD; return -1; }
    }
    long code = sys_waitpid((int)pid);
    if (code == XT_WAIT_STOPPED) {       /* ^Z: the job stopped, not exited. toysh has no
                                          * job table, so report exit(148) = 128+SIGTSTP
                                          * (it reprompts); fg/bg pick the job up later. */
        for (i = 0; i < MAX_KIDS; i++) if (g_kids[i] == pid) g_kids[i] = 0;
        if (status) *status = 148 << 8;
        return pid;
    }
    for (i = 0; i < MAX_KIDS; i++) if (g_kids[i] == pid) g_kids[i] = 0;
    if (status) *status = (int)((code & 0xff) << 8);   /* WIFEXITED shape */
    return pid;
}

pid_t wait(int *status) { return waitpid(-1, status, 0); }

/* the rusage-carrying waits: no accounting on XTOS — zero-filled */
pid_t wait4(pid_t pid, int *status, int options, struct rusage *ru)
{
    if (ru) memset(ru, 0, sizeof *ru);
    return waitpid(pid, status, options);
}

pid_t wait3(int *status, int options, struct rusage *ru)
{
    return wait4(-1, status, options, ru);
}

int getrusage(int who, struct rusage *ru)
{
    (void)who;
    if (ru) memset(ru, 0, sizeof *ru);
    return 0;
}

int getpriority(int which, id_t who) { (void)which; (void)who; return 0; }
int setpriority(int which, id_t who, int prio)
{
    (void)which; (void)who; (void)prio;
    return 0;                            /* one priority class; politeness accepted */
}
int nice(int incr) { (void)incr; return 0; }

/* ---- identity: single-user system, everyone is root ----------------------- */
uid_t getuid(void) { return 0; }
uid_t geteuid(void) { return 0; }
gid_t getgid(void) { return 0; }
gid_t getegid(void) { return 0; }
pid_t getppid(void) { return 1; }
int setuid(uid_t u) { (void)u; return 0; }
int setgid(gid_t g) { (void)g; return 0; }
pid_t setsid(void) { return (pid_t)sys_getpid(); }
pid_t getsid(pid_t pid) { (void)pid; return 1; }   /* one session: the console's */
int initgroups(const char *user, gid_t g) { (void)user; (void)g; return 0; }
int chroot(const char *path) { (void)path; errno = EPERM; return -1; }

static char *g_grmem[] = { 0 };
static struct passwd g_pw = {
    .pw_name = "root", .pw_passwd = "", .pw_uid = 0, .pw_gid = 0,
    .pw_gecos = "root", .pw_dir = "/", .pw_shell = "/System/bin/sh",
};
static struct group g_gr = {
    .gr_name = "root", .gr_passwd = "", .gr_gid = 0, .gr_mem = g_grmem,
};

struct passwd *getpwuid(uid_t uid) { (void)uid; return &g_pw; }
struct passwd *getpwnam(const char *n) { (void)n; return &g_pw; }
struct group *getgrgid(gid_t gid) { (void)gid; return &g_gr; }
struct group *getgrnam(const char *n) { (void)n; return &g_gr; }

int getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t len,
               struct passwd **out)
{
    (void)uid; (void)buf; (void)len;
    *pw = g_pw; *out = pw;
    return 0;
}

int getpwnam_r(const char *n, struct passwd *pw, char *buf, size_t len,
               struct passwd **out)
{
    (void)n; (void)buf; (void)len;
    *pw = g_pw; *out = pw;
    return 0;
}

int getgrgid_r(gid_t gid, struct group *gr, char *buf, size_t len,
               struct group **out)
{
    (void)gid; (void)buf; (void)len;
    *gr = g_gr; *out = gr;
    return 0;
}

int getgrnam_r(const char *n, struct group *gr, char *buf, size_t len,
               struct group **out)
{
    (void)n; (void)buf; (void)len;
    *gr = g_gr; *out = gr;
    return 0;
}

/* ---- terminal: a fixed 80x24 vt102 over the UART console ------------------
 * The line discipline is kernel-side; ICANON/ECHO are REAL (routed over
 * SYS_ioctl XT_TTY_*), the rest of the termios struct is decorative. */
int tcgetattr(int fd, struct termios *t)
{
    memset(t, 0, sizeof *t);
    t->c_iflag = ICRNL | IXON;
    t->c_oflag = OPOST | ONLCR;
    t->c_cflag = CS8 | CREAD;
    t->c_lflag = ISIG | ICANON | ECHO | ECHOE | ECHOK;
    t->c_cc[VINTR] = 3;
    t->c_cc[VEOF] = 4;
    t->c_cc[VMIN] = 1;
    struct xt_ttymode m;
    if (sys_ioctl(fd, XT_TTY_GETMODE, &m) == 0) {   /* the kernel's live mode */
        if (!m.canon) t->c_lflag &= ~(tcflag_t)ICANON;
        if (!m.echo)  t->c_lflag &= ~(tcflag_t)ECHO;
    }
    return 0;
}

int tcsetattr(int fd, int act, const struct termios *t)
{
    (void)act;                                       /* NOW/DRAIN/FLUSH: no output queue */
    struct xt_ttymode m = { (t->c_lflag & ICANON) != 0, (t->c_lflag & ECHO) != 0 };
    sys_ioctl(fd, XT_TTY_SETMODE, &m);               /* non-tty fd: kernel says -1, harmless */
    return 0;
}

int tcflush(int fd, int q) { (void)fd; (void)q; return 0; }
int cfsetspeed(struct termios *t, speed_t s) { (void)t; (void)s; return 0; }

void cfmakeraw(struct termios *t)
{
    t->c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON);
    t->c_oflag &= ~OPOST;
    t->c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
    t->c_cflag = (t->c_cflag & ~(CSIZE | PARENB)) | CS8;
    t->c_cc[VMIN] = 1;
    t->c_cc[VTIME] = 0;
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);         /* by-value requests (I2C_SLAVE) ride the same slot */
    va_end(ap);
    if (req == TIOCGWINSZ) {
        struct winsize *ws = (struct winsize *)arg;
        ws->ws_row = 24;
        ws->ws_col = 80;
        ws->ws_xpixel = ws->ws_ypixel = 0;
        return 0;
    }
    /* everything else goes to the kernel: char-device controls (i2c-dev, ...);
     * non-device fds, unsupported requests and failed transfers (i2c NACK)
     * all come back -1 — EIO reads truthfully for the common case */
    long r = sys_ioctl(fd, (unsigned)req, arg);
    if (r < 0) { errno = EIO; return -1; }
    return (int)r;
}

/* poll: HONEST readability for consoles (XT_TTY_NREAD) and sockets
 * (FIONREAD); pipes/files report ready (kernel reads block correctly).
 * xpoll lives in toybox's lib/net.c now and calls down to this. POLLOUT is
 * optimistic — socket sends block briefly at worst. */
static int poll_probe(struct pollfd *f)
{
    f->revents = 0;
    if (f->fd < 0) return 0;
    struct xt_stat xs;
    int kind = (sys_fstat(f->fd, &xs) == 0) ? (int)(xs.mode & XT_S_IFMT) : 0;
    if (f->events & POLLOUT) f->revents |= POLLOUT;
    if (f->events & POLLIN) {
        if (kind == XT_S_IFSOCK) {
            int n = 0;
            if (sys_ioctl(f->fd, XT_FIONREAD, &n) == 0 && n > 0) f->revents |= POLLIN;
        } else if (kind == XT_S_IFCHR) {
            int n = 0;
            if (sys_ioctl(f->fd, XT_TTY_NREAD, &n) != 0 || n > 0) f->revents |= POLLIN;
        } else {
            f->revents |= POLLIN;                    /* pipes/files: reads block correctly */
        }
    }
    return f->revents != 0;
}

int poll(struct pollfd *fds, nfds_t nfds, int timeout)
{
    struct timeval t0;
    gettimeofday(&t0, 0);
    for (;;) {
        int ready = 0;
        for (nfds_t i = 0; i < nfds; i++) ready += poll_probe(&fds[i]);
        if (ready || timeout == 0) return ready;
        if (timeout > 0) {
            struct timeval t1;
            gettimeofday(&t1, 0);
            long el = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_usec - t0.tv_usec) / 1000;
            if (el >= timeout) return 0;
        }
        /* nothing ready: if the ONLY interesting fd is the console, let the
         * kernel block properly; else nap-and-recheck */
        if (nfds == 1 && (fds[0].events & POLLIN)) {
            struct xt_stat xs;
            if (sys_fstat(fds[0].fd, &xs) == 0 && (xs.mode & XT_S_IFMT) == XT_S_IFCHR) {
                long w = sys_ioctl(fds[0].fd, XT_TTY_INWAIT,
                                   (void *)(long)(timeout > 0 ? 50 : 200));
                if (w > 0) { fds[0].revents = POLLIN; return 1; }
                continue;
            }
        }
        usleep(20000);
    }
}

/* ---- signals: soft only (never delivered asynchronously) ------------------ */
static struct sigaction g_sigact[32];

int sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
    if (sig < 0 || sig >= 32) { errno = EINVAL; return -1; }
    if (old) *old = g_sigact[sig];
    if (act) g_sigact[sig] = *act;
    return 0;
}

int kill(pid_t pid, int sig)
{
    if (sys_kill((int)pid, sig) < 0) { errno = ESRCH; return -1; }
    return 0;
}

int killpg(int pgrp, int sig) { (void)pgrp; (void)sig; return 0; }
int sigisemptyset(const sigset_t *set) { return !*set; }

/* ---- time ------------------------------------------------------------------ */
int settimeofday(const struct timeval *tv, const struct timezone *tz)
{
    (void)tv; (void)tz;
    errno = EPERM;                       /* the wall clock is the A9 timer since boot */
    return -1;
}

int clock_gettime(clockid_t id, struct timespec *tp)
{
    struct timeval tv;
    (void)id;                            /* wall clock serves for both */
    if (gettimeofday(&tv, 0) < 0) return -1;
    tp->tv_sec = tv.tv_sec;
    tp->tv_nsec = tv.tv_usec * 1000;
    return 0;
}

int nanosleep(const struct timespec *req, struct timespec *rem)
{
    /* no sleep syscall yet: spin on the wall clock (sleep/usleep are rare
     * in a shell; a kernel timed-wait can replace this when needed) */
    struct timeval t0, t1;
    long long want = req->tv_sec * 1000000ll + req->tv_nsec / 1000;
    (void)rem;
    gettimeofday(&t0, 0);
    do gettimeofday(&t1, 0);
    while ((t1.tv_sec - t0.tv_sec) * 1000000ll + (t1.tv_usec - t0.tv_usec) < want);
    return 0;
}

/* ---- host identity --------------------------------------------------------- */
#include <sys/sysinfo.h>
/* pull "<label>: N kB" out of /OS/proc/meminfo (the kernel's real pool view) */
static unsigned long meminfo_kb(const char *text, const char *label)
{
    const char *p = strstr(text, label);
    if (!p) return 0;
    p += strlen(label);
    while (*p == ':' || *p == ' ' || *p == '\t') p++;
    unsigned long v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (unsigned long)(*p++ - '0');
    return v;
}

int sysinfo(struct sysinfo *info)
{
    struct timeval tv;
    char mi[512];
    memset(info, 0, sizeof *info);
    gettimeofday(&tv, 0);
    info->uptime = tv.tv_sec;            /* wall clock IS boot time here */
    info->mem_unit = 1;
    info->procs = 8;
    long fd = sys_open("/OS/proc/meminfo", 0);
    if (fd >= 0) {
        long n = sys_read((int)fd, mi, sizeof mi - 1);
        sys_close((int)fd);
        if (n > 0) {
            mi[n] = 0;
            info->totalram = meminfo_kb(mi, "MemTotal") * 1024ul;
            info->freeram  = meminfo_kb(mi, "MemFree") * 1024ul;
        }
    }
    if (!info->totalram) { info->totalram = 512u << 20; info->freeram = 256u << 20; }
    return 0;
}

long sysconf(int name)
{
    switch (name) {
    case _SC_CLK_TCK:            return 100;
    case _SC_PAGESIZE:           return 4096;
    case _SC_NPROCESSORS_CONF:
    case _SC_NPROCESSORS_ONLN:   return 1;
    case _SC_OPEN_MAX:           return 16;
    }
    return -1;
}

/* netcat's -W/-q timers; no async signals to deliver, so a no-op alarm is
 * honest enough (its poll timeouts do the real limiting) */
unsigned alarm(unsigned sec) { (void)sec; return 0; }

int usleep(useconds_t us)
{
    struct timespec ts = { (time_t)(us / 1000000u), (long)(us % 1000000u) * 1000 };
    return nanosleep(&ts, 0);
}

unsigned sleep(unsigned sec)
{
    struct timespec ts = { (time_t)sec, 0 };
    nanosleep(&ts, 0);
    return 0;
}

int gethostname(char *buf, size_t len)
{
    strncpy(buf, "xtos", len);
    return 0;
}

int sethostname(const char *name, size_t len)   /* single fixed hostname (xtos.local) */
{ (void)name; (void)len; return 0; }
int getdomainname(char *buf, size_t len) { if (len) buf[0] = 0; return 0; }
int setdomainname(const char *name, size_t len) { (void)name; (void)len; return 0; }

int uname(struct utsname *u)
{
    memset(u, 0, sizeof *u);
    strcpy(u->sysname, "XTOS");
    strcpy(u->nodename, "xtos");
    strcpy(u->release, "0.1");
    strcpy(u->version, "XTOS loader");
    strcpy(u->machine, "armv7l");
    return 0;
}

/* ---- odds and ends --------------------------------------------------------- */
/* newlib's _GNU_SOURCE string.h claims the source name `basename` for its
 * (absent) __gnu_basename; emit the POSIX one under the plain symbol name */
char *xt_basename(char *path) __asm__("basename");
char *xt_basename(char *path)
{
    char *p;
    if (!path || !*path) return ".";
    p = path + strlen(path);
    while (p > path + 1 && p[-1] == '/') *--p = 0;   /* strip trailing / */
    p = strrchr(path, '/');
    return (p && p[1]) ? p + 1 : (p ? path : path);
}

/* fnmatch — newlib ships the header but no implementation. Handles * ? [set]
 * (ranges, ^/! negation), backslash escapes, FNM_PATHNAME/PERIOD/CASEFOLD. */
#include <fnmatch.h>
#include <ctype.h>

static int fnm_one(const char *pat, const char *str, int flags, int at_start)
{
    while (*pat) {
        char pc = *pat;
        if (pc == '*') {
            while (*pat == '*') pat++;
            if (!*pat) {                 /* trailing *: match rest (bar / with PATHNAME) */
                if (flags & FNM_PATHNAME)
                    for (const char *s = str; *s; s++) if (*s == '/') return FNM_NOMATCH;
                return 0;
            }
            for (const char *s = str; ; s++) {
                if (!fnm_one(pat, s, flags & ~FNM_PERIOD, 0)) return 0;
                if (!*s) return FNM_NOMATCH;
                if ((flags & FNM_PATHNAME) && *s == '/') return FNM_NOMATCH;
            }
        }
        if (!*str) return FNM_NOMATCH;
        if ((flags & FNM_PERIOD) && at_start && *str == '.' && pc != '.')
            return FNM_NOMATCH;
        if (pc == '?') {
            if ((flags & FNM_PATHNAME) && *str == '/') return FNM_NOMATCH;
        } else if (pc == '[') {
            const char *p = pat + 1;
            int neg = (*p == '!' || *p == '^');
            if (neg) p++;
            int hit = 0;
            char sc = (flags & FNM_CASEFOLD) ? (char)tolower((unsigned char)*str) : *str;
            while (*p && !(*p == ']' && p != pat + 1 + neg)) {
                char lo = *p;
                if (lo == '\\' && !(flags & FNM_NOESCAPE) && p[1]) lo = *++p;
                if ((flags & FNM_CASEFOLD)) lo = (char)tolower((unsigned char)lo);
                if (p[1] == '-' && p[2] && p[2] != ']') {
                    char hi = p[2];
                    if ((flags & FNM_CASEFOLD)) hi = (char)tolower((unsigned char)hi);
                    if (sc >= lo && sc <= hi) hit = 1;
                    p += 3;
                } else {
                    if (sc == lo) hit = 1;
                    p++;
                }
            }
            if (!*p) return FNM_NOMATCH; /* unterminated set */
            if (hit == neg) return FNM_NOMATCH;
            if ((flags & FNM_PATHNAME) && *str == '/') return FNM_NOMATCH;
            pat = p;                     /* at ']' */
        } else {
            if (pc == '\\' && !(flags & FNM_NOESCAPE) && pat[1]) pc = *++pat;
            char sc = *str;
            if (flags & FNM_CASEFOLD) {
                pc = (char)tolower((unsigned char)pc);
                sc = (char)tolower((unsigned char)sc);
            }
            if (pc != sc) return FNM_NOMATCH;
        }
        at_start = ((flags & FNM_PATHNAME) && *str == '/');
        pat++; str++;
    }
    return *str ? FNM_NOMATCH : 0;
}

int fnmatch(const char *pat, const char *str, int flags)
{
    return fnm_one(pat, str, flags, 1);
}

/* regcomp/regexec/regfree/regerror come from the vendored Spencer regex
 * (libs/regex, lifted from the newlib source tree); it wants the locale
 * collation loader's error flag — no locales here, so "not loaded" */
int __collate_load_error = 1;

int statvfs(const char *path, struct statvfs *sv)
{
    (void)path;
    memset(sv, 0, sizeof *sv);
    sv->f_bsize = sv->f_frsize = 4096;
    sv->f_blocks = 65536;
    sv->f_bfree = sv->f_bavail = 32768;
    sv->f_files = 65536;
    sv->f_ffree = sv->f_favail = 32768;
    sv->f_namemax = 255;
    return 0;
}

int statfs(const char *path, struct statfs *sf)
{
    (void)path;
    memset(sf, 0, sizeof *sf);
    sf->f_bsize = sf->f_frsize = 4096;
    sf->f_blocks = 65536;
    sf->f_bfree = sf->f_bavail = 32768;
    sf->f_files = 65536;
    sf->f_ffree = 32768;
    sf->f_namelen = 255;
    return 0;
}

char *dirname(char *path)
{
    char *p;
    if (!path || !*path) return ".";
    p = path + strlen(path);
    while (p > path + 1 && p[-1] == '/') *--p = 0;   /* strip trailing / */
    p = strrchr(path, '/');
    if (!p) return ".";
    if (p == path) return p[1] ? (*(p + 1) = 0, path) : path;   /* "/x" -> "/" */
    *p = 0;
    return path;
}

/* real mount enumeration over /proc/mounts (df/mount want it): setmntent opens
 * the file, getmntent parses one "dev dir type opts freq passno" line into a
 * static mntent (fields point into a static line buffer). */
FILE *setmntent(const char *file, const char *mode)
{
    return fopen(file, mode && *mode ? mode : "r");
}

struct mntent *getmntent(FILE *f)
{
    static char line[256];
    static struct mntent me;
    if (!f) return 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char *sp[6] = { 0, 0, 0, 0, 0, 0 };
        int k = 0;
        for (char *t = strtok(line, " \t\r\n"); t && k < 6; t = strtok(0, " \t\r\n")) sp[k++] = t;
        if (k < 3) continue;                 /* need at least dev dir type */
        me.mnt_fsname = sp[0];
        me.mnt_dir    = sp[1];
        me.mnt_type   = sp[2];
        me.mnt_opts   = sp[3] ? sp[3] : (char *)"rw";
        me.mnt_freq   = sp[4] ? atoi(sp[4]) : 0;
        me.mnt_passno = sp[5] ? atoi(sp[5]) : 0;
        return &me;
    }
    return 0;
}
struct mntent *getmntent_r(FILE *f, struct mntent *m, char *buf, int len)
{
    struct mntent *s = getmntent(f);
    if (!s || !m) return 0;
    (void)buf; (void)len;
    *m = *s;                                 /* fields still point at getmntent's static line */
    return m;
}
int endmntent(FILE *f) { if (f) fclose(f); return 1; }

void openlog(const char *ident, int opt, int fac) { (void)ident; (void)opt; (void)fac; }
void closelog(void) {}

void vsyslog(int pri, const char *fmt, va_list ap)
{
    (void)pri;
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
}

void syslog(int pri, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsyslog(pri, fmt, ap);
    va_end(ap);
}

/* entropy: no hardware RNG surfaced yet — timer-seeded xorshift (uuidgen,
 * mktemp randomness; NOT cryptographic) */
int getentropy(void *buf, size_t len)
{
    static unsigned s;
    unsigned char *b = buf;
    if (!s) {
        struct timeval tv;
        gettimeofday(&tv, 0);
        s = (unsigned)tv.tv_usec ^ ((unsigned)tv.tv_sec << 12) ^ ((unsigned)sys_getpid() << 24) ^ 0x9e3779b9u;
    }
    for (size_t i = 0; i < len; i++) {
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        b[i] = (unsigned char)s;
    }
    return 0;
}

/* newlib's mkstemp probes candidates through the kernel's _stat stub; do the
 * X-substitution ourselves over honest sys_stat + sys_open(O_CREAT) */
int mkstemp(char *template)
{
    int n = strlen(template);
    if (n < 6 || strcmp(template + n - 6, "XXXXXX")) { errno = EINVAL; return -1; }
    for (int tries = 0; tries < 100; tries++) {
        unsigned r;
        getentropy(&r, sizeof r);
        for (int i = n - 6; i < n; i++) {
            template[i] = (char)('a' + (r % 26));
            r /= 26;
        }
        struct xt_stat xs;
        if (sys_stat(template, &xs) == 0) continue;       /* exists: next candidate */
        long fd = sys_open(template, 0x0601 /* WRONLY|CREAT|TRUNC */);
        if (fd >= 0) return (int)fd;
    }
    errno = EEXIST;
    return -1;
}

int inotify_init(void) { errno = ENOSYS; return -1; }
int inotify_add_watch(int fd, const char *path, uint32_t mask)
{
    (void)fd; (void)path; (void)mask;
    errno = ENOSYS;
    return -1;
}

/* anonymous mmaps are malloc-backed; remember them so munmap can free */
#define ANON_MAPS 8
static void *g_anon_map[ANON_MAPS];

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
    (void)addr; (void)prot;
    if (flags & MAP_ANONYMOUS) {
        void *p = calloc(1, len);
        if (!p) return MAP_FAILED;
        for (int i = 0; i < ANON_MAPS; i++)
            if (!g_anon_map[i]) { g_anon_map[i] = p; break; }
        return p;
    }
    void *p = sys_mmap(fd, len, off);    /* romfs RO file mapping */
    return p ? p : MAP_FAILED;
}

int munmap(void *addr, size_t len)
{
    for (int i = 0; i < ANON_MAPS; i++)
        if (g_anon_map[i] == addr) { g_anon_map[i] = 0; free(addr); return 0; }
    return (int)sys_munmap(addr, len);
}

/* ---- entry ------------------------------------------------------------------ */
extern int main(int argc, char **argv);

void _app_entry(int argc, char **argv)
{
    exit(main(argc, argv));
}
