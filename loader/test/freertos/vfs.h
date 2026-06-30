/*
 * vfs.h — tiny virtual filesystem. sys_open/read/lseek/close dispatch here.
 * A mount binds a path prefix to a filesystem driver; longest-prefix wins.
 * Filesystem drivers (romfs, fatfs, minixfs later) implement open() -> vfs_file
 * with per-file read/lseek/close ops. New filesystems need no syscall changes.
 */
#ifndef VFS_H
#define VFS_H
#include <stdint.h>

typedef struct vfs_file  vfs_file;
typedef struct vfs_mount vfs_mount;

/* a filesystem driver */
typedef struct vfs_fs {
    const char *name;                                   /* "romfs", "fatfs", ... */
    /* open: path is RELATIVE to the mount prefix (leading '/'); fill *f. 0=ok, <0=err */
    int (*open)(vfs_mount *m, const char *path, vfs_file *f);
} vfs_fs;

/* an open file (lives inside the per-process fd table) */
struct vfs_file {
    long      (*read )(vfs_file *f, void *buf, uint32_t n);
    long      (*lseek)(vfs_file *f, long off, int whence);
    void      (*close)(vfs_file *f);
    uint32_t    size;
    uint32_t    pos;
    const void *data;     /* in-memory backing (romfs) -> enables identity mmap; NULL otherwise */
    void       *priv;     /* fs-private (FIL*, ...) */
    vfs_mount  *mnt;
};

struct vfs_mount {
    char     prefix[24];  /* "/", "/sd" */
    vfs_fs  *fs;
    void    *priv;        /* fs-private mount state */
};

int      vfs_register_fs(vfs_fs *fs);
vfs_fs  *vfs_find_fs(const char *name);
int      vfs_add_mount(const char *prefix, const char *fsname, void *priv);  /* 0=ok */
int      vfs_open(const char *path, vfs_file *f);                          /* 0=ok, <0=err */

#endif
