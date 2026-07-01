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

/* open-flag subset (newlib O_*, sys/_default_fcntl.h) the drivers interpret. Write
 * intent = (flags & VFS_O_ACCMODE) != 0. */
#define VFS_O_ACCMODE 0x0003   /* WRONLY(1) | RDWR(2); RDONLY = 0 */
#define VFS_O_APPEND  0x0008
#define VFS_O_CREAT   0x0200
#define VFS_O_TRUNC   0x0400

/* a filesystem driver */
typedef struct vfs_fs {
    const char *name;                                   /* "romfs", "fatfs", "ramfs", ... */
    /* open: path is RELATIVE to the mount prefix (leading '/'); `flags` = VFS_O_* subset;
     * fill *f. 0=ok, <0=err (incl. write intent on a read-only fs). */
    int (*open)(vfs_mount *m, const char *path, int flags, vfs_file *f);
    int serialized;   /* 1: a backing-store driver (non-reentrant / shares the block
                       * device) -> vfs takes ONE shared lock across all such drivers so
                       * fatfs+minixfs+swap serialize together. 0: reentrant (romfs, ramfs). */
} vfs_fs;

/* an open file (lives inside the per-process fd table) */
struct vfs_file {
    long      (*read )(vfs_file *f, void *buf, uint32_t n);
    long      (*write)(vfs_file *f, const void *buf, uint32_t n);   /* NULL on a read-only fd */
    long      (*lseek)(vfs_file *f, long off, int whence);
    void      (*close)(vfs_file *f);
    uint32_t    size;
    uint32_t    pos;
    const void *data;     /* in-memory backing (romfs) -> enables identity mmap; NULL otherwise */
    void       *priv;     /* fs-private (FIL*, rnode*, ...) */
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
int      vfs_open(const char *path, int flags, vfs_file *f);              /* 0=ok, <0=err */
/* op wrappers that take the shared backing-store lock for serialized filesystems
 * (a no-op passthrough for reentrant ones like romfs). Callers use these, not the
 * vfs_file function pointers directly, so all on-disk access serializes. */
long     vfs_read (vfs_file *f, void *buf, uint32_t n);
long     vfs_write(vfs_file *f, const void *buf, uint32_t n);   /* -1 if the fd is read-only */
long     vfs_lseek(vfs_file *f, long off, int whence);
void     vfs_close(vfs_file *f);

#endif
