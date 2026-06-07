// posix_dir.c — POSIX opendir/readdir/closedir backed by the VFS.
//
// newlib has no directory syscalls on bare metal, but portable code (the GEM
// font loader) expects <dirent.h>.  These map straight onto vfs_opendir/
// vfs_readdir/vfs_closedir so opendir("/OS/Fonts") enumerates the SD via FatFs
// (and any mounted tmpfs).  See xtos/compat/dirent.h for the shim types.

#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include "vfs.h"

struct __dirstream {
    int           vh;          // VFS dir handle
    struct dirent de;          // returned entry (reused each readdir)
};

DIR *opendir(const char *name)
{
    int vh = vfs_opendir(name);
    if (vh < 0) return NULL;
    DIR *d = malloc(sizeof *d);
    if (!d) { vfs_closedir(vh); return NULL; }
    d->vh = vh;
    return d;
}

struct dirent *readdir(DIR *d)
{
    if (!d) return NULL;
    struct vfs_dirent ve;
    if (vfs_readdir(d->vh, &ve) != 1) return NULL;
    strncpy(d->de.d_name, ve.name, sizeof d->de.d_name - 1);
    d->de.d_name[sizeof d->de.d_name - 1] = '\0';
    return &d->de;
}

int closedir(DIR *d)
{
    if (!d) return -1;
    vfs_closedir(d->vh);
    free(d);
    return 0;
}
