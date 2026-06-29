/*
 * vfs.h — a tiny virtual filesystem: a mount table + an fs_ops vtable, so the
 * file syscalls dispatch to whichever filesystem owns a path instead of calling
 * one hardcoded backend. The root (romfs) is an in-kernel, direct fs_ops; later,
 * mounted filesystems are PL0 services whose fs_ops entries are IPC stubs — the
 * VFS doesn't care which. See docs/OS/filesystems.md.
 */
#ifndef VFS_H
#define VFS_H
#include <stdint.h>

struct vfile;

/* A filesystem's operations. `path` passed to open() is already stripped of the
 * mount prefix (the root mount "/" receives the full absolute path). open() fills
 * f->priv + f->size. read() works at f->pos and advances it. mmap_base() returns a
 * physical address for zero-copy mmap (romfs, in RAM) or 0 if not mappable. */
struct fs_ops {
    const char *name;
    int      (*open)(void *fsdata, const char *path, int flags, struct vfile *f);
    long     (*read)(struct vfile *f, void *buf, long n);
    void     (*close)(struct vfile *f);
    uint32_t (*mmap_base)(struct vfile *f);
};

/* An open file — stored in the per-process fd table. */
struct vfile {
    const struct fs_ops *fs;
    void     *priv;          /* fs-private handle (romfs: the file's data pointer) */
    uint32_t  size;
    uint32_t  pos;
};

int      vfs_mount(const char *prefix, const struct fs_ops *fs, void *fsdata);
int      vfs_open(const char *path, int flags, struct vfile *f);   /* 0 / -1 */
long     vfs_read(struct vfile *f, void *buf, long n);
long     vfs_lseek(struct vfile *f, long off, int whence);
void     vfs_close(struct vfile *f);
uint32_t vfs_mmap_base(struct vfile *f);                           /* 0 if not mappable */

#endif
