/*
 * libc-dirent.c — opendir/readdir/closedir for xtos's libc.so.
 *
 * newlib has NO directory support: its <dirent.h> is a hard `#error`, and
 * libc.a defines none of these names.  The XTOS posix shim
 * (test/freertos/libs/posix_shim.c) does implement them, but the shim is linked
 * only into toybox and dropbear, so any OTHER program that walks a directory
 * linked cleanly against libc.so with UNDEFINED opendir/readdir and then died at
 * load with no diagnostic.  That is how it bit: emu's ACID800 harness ran a
 * single named test fine and the whole-directory run exited instantly and
 * silently.  Check any program with `arm-none-eabi-nm -u <prog>.so`.
 *
 * So: a small, honest implementation in libc.so, where the rest of the world
 * expects to find it.  Deliberately NOT a copy of the shim's — the shim carries
 * a directory snapshot cache and pseudo-fds so toybox's dirtree can fstatat()
 * children against an open dir fd, which is machinery a plain readdir loop does
 * not need and should not pay for.
 *
 * SYS_getdents is the fast path: one syscall fills a buffer with packed records
 * (mode, size, mtime, reclen, namelen, name), so a directory costs a couple of
 * round trips instead of one per entry.  A filesystem that cannot batch-enumerate
 * answers -1, and then SYS_readdir(path, index) serves entries one at a time.
 */
#include <stdlib.h>
#include <string.h>

#include "xtsys.h"
#include "usys.h"
#include "dirent.h"

#define DBUF 4096

struct __xt_DIR {
    char           path[512];
    int            index;      /* next entry index to ask the kernel for */
    int            n, used;    /* getdents records in buf, and how many consumed */
    int            batch;      /* 0 once getdents has said "not batch-enumerable" */
    char          *cur;        /* cursor into buf */
    struct dirent  de;
    char           buf[DBUF];
};

DIR *opendir(const char *name)
{
    if (!name) return 0;

    /* Probe before committing: the kernel has no open-a-directory call, so this
     * is the only way opendir can honestly fail on a path that is not there.
     * A -1 here is ambiguous (missing, or simply not batch-enumerable), so fall
     * through to a per-entry readdir probe rather than guessing. */
    static char probe[DBUF];
    long got   = sys_getdents(name, 0, probe);
    int   batch = got >= 0;
    if (!batch) {
        struct xt_dirent e;
        if (sys_readdir(name, 0, &e) < 0) return 0;
    }

    DIR *d = calloc(1, sizeof *d);
    if (!d) return 0;
    strncpy(d->path, name, sizeof d->path - 1);
    d->batch = batch;
    return d;
}

struct dirent *readdir(DIR *d)
{
    if (!d) return 0;

    if (!d->batch) {
        struct xt_dirent e;
        if (sys_readdir(d->path, d->index, &e) != 1) return 0;
        d->index++;
        d->de.d_ino  = (ino_t)d->index;
        d->de.d_type = (unsigned char)IFTODT(e.mode);
        strncpy(d->de.d_name, e.name, sizeof d->de.d_name - 1);
        d->de.d_name[sizeof d->de.d_name - 1] = 0;
        return &d->de;
    }

    if (d->used >= d->n) {                       /* buffer drained: refill */
        long got = sys_getdents(d->path, d->index, d->buf);
        if (got <= 0) return 0;                  /* 0 = end of directory */
        d->n     = (int)got;
        d->used  = 0;
        d->cur   = d->buf;
        d->index += (int)got;
    }

    /* record layout, from xtsys.h: u32 mode, u32 size, u32 mtime,
     * u16 reclen (the WHOLE record), u16 namelen, char name[] + NUL */
    const char    *p       = d->cur;
    unsigned       mode    = *(const unsigned *)(p + 0);
    unsigned short reclen  = *(const unsigned short *)(p + 12);
    unsigned short namelen = *(const unsigned short *)(p + 14);
    const char    *nm      = p + 16;

    if (namelen >= sizeof d->de.d_name) namelen = sizeof d->de.d_name - 1;
    memcpy(d->de.d_name, nm, namelen);
    d->de.d_name[namelen] = 0;
    d->de.d_type = (unsigned char)IFTODT(mode);
    d->de.d_ino  = (ino_t)(d->index - d->n + d->used + 1);

    d->cur = p + reclen;
    d->used++;
    return &d->de;
}

void rewinddir(DIR *d)
{
    if (!d) return;
    d->index = d->n = d->used = 0;
    d->cur = d->buf;
}

int closedir(DIR *d)
{
    if (!d) return -1;
    free(d);
    return 0;
}

/* There are no directory file descriptors — the kernel cannot open a directory,
 * which is exactly why the shim invents pseudo-fds for openat/fstatat.  A plain
 * readdir loop never needs one, so these fail honestly rather than pretending. */
DIR *fdopendir(int fd) { (void)fd; return 0; }
int  dirfd(DIR *d)     { (void)d;  return -1; }
