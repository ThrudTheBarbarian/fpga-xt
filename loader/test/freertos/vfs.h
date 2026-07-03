/*
 * vfs.h — tiny virtual filesystem. sys_open/read/lseek/close dispatch here.
 * A mount binds a path prefix to a filesystem driver; longest-prefix wins.
 * Filesystem drivers (romfs, fatfs, minixfs later) implement open() -> vfs_file
 * with per-file read/lseek/close ops. New filesystems need no syscall changes.
 */
#ifndef VFS_H
#define VFS_H
#include <stdint.h>
#include "xtsys.h"           /* struct xt_stat + XT_S_IF* file-type bits */

typedef struct vfs_file  vfs_file;
typedef struct vfs_mount vfs_mount;

/* On-disk symlink (Cygwin-style, survives Mac/Windows): a regular file with the
 * FAT SYSTEM attribute set, whose content is XT_SLNK_MAGIC ("XTLK") + '\0' + the
 * target path. The magic is one aligned uint32 compare; the SYSTEM bit is a fast
 * reject so only system files get content-peeked. */
#define XT_SLNK_MAGIC 0x4B4C5458u   /* "XTLK" little-endian */
#define VFS_PATH_MAX  256
#define VFS_SYMLOOP_MAX 40

/* open-flag subset (newlib O_*, sys/_default_fcntl.h) the drivers interpret. Write
 * intent = (flags & VFS_O_ACCMODE) != 0. */
#define VFS_O_ACCMODE 0x0003   /* WRONLY(1) | RDWR(2); RDONLY = 0 */
#define VFS_O_WRONLY  0x0001
#define VFS_O_RDWR    0x0002
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
    /* metadata ops — all OPTIONAL (NULL = unsupported; the vfs_* wrappers degrade
     * gracefully). paths are relative to the mount prefix, like open(). */
    int (*readlink)(vfs_mount *m, const char *path, char *buf, int sz);  /* >=0 len, <0 not-a-link/err */
    int (*stat)(vfs_mount *m, const char *path, struct xt_stat *st);     /* 0 ok, <0 err */
    int (*unlink)(vfs_mount *m, const char *path);                       /* 0 ok, <0 err */
    int (*symlink)(vfs_mount *m, const char *target, const char *path);  /* 0 ok, <0 err */
    /* enumerate: fill name/mode of the index-th entry -> 1 filled, 0 end, -1 err */
    int (*readdir)(vfs_mount *m, const char *path, int index, char *name, int nsz, unsigned *mode);
    int (*mkdir)(vfs_mount *m, const char *path);                            /* 0 ok, <0 err */
    int (*rename)(vfs_mount *m, const char *oldp, const char *newp);         /* 0 ok, <0 err */
} vfs_fs;

/* an open file (lives inside the per-process fd table) */
struct vfs_file {
    long      (*read )(vfs_file *f, void *buf, uint32_t n);
    long      (*write)(vfs_file *f, const void *buf, uint32_t n);   /* NULL on a read-only fd */
    long      (*lseek)(vfs_file *f, long off, int whence);
    void      (*close)(vfs_file *f);
    long      (*ioctl)(vfs_file *f, unsigned req, void *arg);  /* char devices only
                           * (SYS_ioctl); NULL = no device controls */
    uint32_t    size;
    uint32_t    pos;
    const void *data;     /* in-memory backing (romfs) -> enables identity mmap; NULL otherwise */
    void       *priv;     /* fs-private (FIL*, rnode*, ...) */
    vfs_mount  *mnt;
    int         chr;      /* char device: 0 = regular file; VFS_CHR_DEV = unbounded stream
                           * (read/write called directly, no page store, no lseek);
                           * VFS_CHR_TTY = the console (the kernel turns the fd into a
                           * console alias at open) */
};
#define VFS_CHR_DEV 1
#define VFS_CHR_TTY 2

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

/* metadata + symlinks. vfs_open/vfs_stat FOLLOW symlinks (leaf included); the l*
 * variants and unlink/symlink operate on the link itself. vfs_resolve is the mount-
 * aware namei loop that expands symlinks in a path (follow_leaf: also the final one). */
long     vfs_readlink(const char *path, char *buf, int sz);    /* >=0 target len, <0 err */
long     vfs_stat (const char *path, struct xt_stat *st);      /* follows symlinks */
long     vfs_lstat(const char *path, struct xt_stat *st);      /* the link itself */
long     vfs_unlink(const char *path);
long     vfs_symlink(const char *target, const char *linkpath);
long     vfs_readdir(const char *path, int index, char *name, int nsz, unsigned *mode);
long     vfs_mkdir(const char *path);
long     vfs_rename(const char *oldp, const char *newp);
int      vfs_resolve(const char *in, char *out, int outsz, int follow_leaf); /* 0 ok, <0 ELOOP */

#endif
