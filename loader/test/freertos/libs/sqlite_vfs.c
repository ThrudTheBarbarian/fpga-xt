/* sqlite_vfs.c — an XTOS VFS for SQLite (built with -DSQLITE_OS_OTHER).
 *
 * SQLite routes all I/O through a registered sqlite3_vfs; on a non-POSIX target
 * it ships none, so we provide one over the loader's file syscalls (sys_open/
 * read/write/lseek/close).  The READ path is complete (open/read/filesize/access
 * + no-op locking — a single read-only connection needs no cross-process lock);
 * the WRITE path works for plain writes, but xDelete/xTruncate/xSync need
 * unlink/truncate/fsync syscalls (added in the write-hardening step) — until then
 * they are benign no-ops, which is correct as long as nothing writes the DB.
 *
 * Config: journal mode only (no WAL -> no shared-memory VFS), TEMP_STORE=memory
 * (no temp files), single-threaded.  Cross-process locking arrives with the lock
 * service (lockfs @ /OS/Var/Locks).
 */
#include "sqlite3.h"
#include "usys.h"
#include <string.h>

/* sys_open flag subset (matches vfs.h VFS_O_*) */
#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_RDWR   0x0002
#define O_CREAT  0x0200
#define O_TRUNC  0x0400

typedef struct xt_file {
    sqlite3_file base;
    int fd;
    int lock;                 /* current SQLite lock level (NONE..EXCLUSIVE) */
} xt_file;

/* ---- per-file I/O methods ------------------------------------------------- */
static int xtClose(sqlite3_file *f) {
    xt_file *p = (xt_file *)f;
    if (p->fd >= 0) { sys_close(p->fd); p->fd = -1; }
    return SQLITE_OK;
}
static int xtRead(sqlite3_file *f, void *buf, int n, sqlite3_int64 off) {
    xt_file *p = (xt_file *)f;
    if (sys_lseek(p->fd, (long)off, 0) != (long)off) return SQLITE_IOERR_READ;
    long got = sys_read(p->fd, buf, (unsigned)n);
    if (got == n) return SQLITE_OK;
    if (got < 0) return SQLITE_IOERR_READ;
    memset((char *)buf + got, 0, (size_t)(n - got));       /* short read -> zero-fill */
    return SQLITE_IOERR_SHORT_READ;
}
static int xtWrite(sqlite3_file *f, const void *buf, int n, sqlite3_int64 off) {
    xt_file *p = (xt_file *)f;
    if (sys_lseek(p->fd, (long)off, 0) != (long)off) return SQLITE_IOERR_WRITE;
    long put = sys_write(p->fd, buf, (unsigned)n);
    return put == n ? SQLITE_OK : SQLITE_IOERR_WRITE;
}
static int xtTruncate(sqlite3_file *f, sqlite3_int64 sz) {
    (void)f; (void)sz; return SQLITE_OK;                    /* TODO: SYS_truncate */
}
static int xtSync(sqlite3_file *f, int flags) {
    (void)f; (void)flags; return SQLITE_OK;                 /* TODO: SYS_fsync */
}
static int xtFileSize(sqlite3_file *f, sqlite3_int64 *pSize) {
    xt_file *p = (xt_file *)f;
    long end = sys_lseek(p->fd, 0, 2);                      /* SEEK_END */
    if (end < 0) return SQLITE_IOERR_FSTAT;
    *pSize = (sqlite3_int64)end;
    return SQLITE_OK;
}
/* Single-process locking for now: track the level, always grant.  Correct for a
 * lone connection; cross-process arbitration comes with the lock service. */
static int xtLock(sqlite3_file *f, int level)   { ((xt_file *)f)->lock = level; return SQLITE_OK; }
static int xtUnlock(sqlite3_file *f, int level) { ((xt_file *)f)->lock = level; return SQLITE_OK; }
static int xtCheckReservedLock(sqlite3_file *f, int *pOut) { (void)f; *pOut = 0; return SQLITE_OK; }
static int xtFileControl(sqlite3_file *f, int op, void *arg) { (void)f; (void)op; (void)arg; return SQLITE_NOTFOUND; }
static int xtSectorSize(sqlite3_file *f) { (void)f; return 512; }
static int xtDeviceCharacteristics(sqlite3_file *f) { (void)f; return 0; }

static const sqlite3_io_methods xt_io = {
    1, xtClose, xtRead, xtWrite, xtTruncate, xtSync, xtFileSize,
    xtLock, xtUnlock, xtCheckReservedLock, xtFileControl,
    xtSectorSize, xtDeviceCharacteristics,
    0, 0, 0, 0, 0, 0,                                       /* v2 shm/fetch: unused (no WAL) */
};

/* ---- VFS methods ---------------------------------------------------------- */
static int xtOpen(sqlite3_vfs *vfs, const char *name, sqlite3_file *f, int flags, int *pOut) {
    (void)vfs;
    xt_file *p = (xt_file *)f;
    memset(p, 0, sizeof *p); p->fd = -1;
    int of = (flags & SQLITE_OPEN_READWRITE) ? O_RDWR : O_RDONLY;
    if (flags & SQLITE_OPEN_CREATE) of |= O_CREAT;
    if (!name) return SQLITE_IOERR;                        /* no anonymous temp files */
    long fd = sys_open(name, of);
    if (fd < 0 && (of & O_RDWR)) { of = O_RDONLY; fd = sys_open(name, of); }  /* fall back RO */
    if (fd < 0) return SQLITE_CANTOPEN;
    p->fd = (int)fd; p->base.pMethods = &xt_io;
    if (pOut) *pOut = (of & O_RDWR) ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY;
    return SQLITE_OK;
}
static int xtDelete(sqlite3_vfs *vfs, const char *name, int sync) {
    (void)vfs; (void)name; (void)sync; return SQLITE_OK;   /* TODO: SYS_unlink */
}
static int xtAccess(sqlite3_vfs *vfs, const char *name, int flags, int *pOut) {
    (void)vfs; (void)flags;
    long fd = sys_open(name, O_RDONLY);
    *pOut = (fd >= 0);
    if (fd >= 0) sys_close((int)fd);
    return SQLITE_OK;
}
static int xtFullPathname(sqlite3_vfs *vfs, const char *in, int nOut, char *out) {
    (void)vfs;
    /* paths are already absolute (/OS/...); copy through */
    int n = (int)strlen(in); if (n >= nOut) n = nOut - 1;
    memcpy(out, in, (size_t)n); out[n] = 0;
    return SQLITE_OK;
}
static int xtRandomness(sqlite3_vfs *vfs, int n, char *out) {
    (void)vfs; for (int i = 0; i < n; i++) out[i] = (char)(i * 41 + 7); return n;
}
static int xtSleep(sqlite3_vfs *vfs, int us) { (void)vfs; return us; }
static int xtCurrentTime(sqlite3_vfs *vfs, double *pNow) {
    (void)vfs; *pNow = 2440587.5;                          /* Julian day of the epoch (no RTC) */
    return SQLITE_OK;
}
static int xtGetLastError(sqlite3_vfs *vfs, int n, char *out) { (void)vfs; (void)n; if (out && n) out[0] = 0; return 0; }

static sqlite3_vfs xt_vfs = {
    3, sizeof(xt_file), 512, 0, "xtos", 0,
    xtOpen, xtDelete, xtAccess, xtFullPathname,
    0, 0, 0, 0,                                            /* dlopen family: none */
    xtRandomness, xtSleep, xtCurrentTime, xtGetLastError,
    0, 0, 0,                                               /* v2 currentTimeInt64 + syscall hooks */
};

/* SQLITE_OS_OTHER requires the app to provide these; register our VFS as default. */
int sqlite3_os_init(void) { return sqlite3_vfs_register(&xt_vfs, 1); }
int sqlite3_os_end(void)  { return SQLITE_OK; }
