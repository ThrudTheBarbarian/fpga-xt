// vfs.h — tiny virtual filesystem: route Unix paths to a backend by longest
// matching prefix.  Each backend (FatFs on the SD at "/", tmpfs in RAM at
// "/tmp") registers an op-table; vfs.c owns the newlib syscalls + fd table and
// dispatches to the claiming backend.  (Shape after T288's app/fs/vfs.)

#ifndef VFS_H
#define VFS_H

#define VFS_NAME_MAX 64
#define VFS_PATH_MAX 256

struct vfs_dirent { char name[VFS_NAME_MAX]; int is_dir; unsigned long size; };

// Handles below are backend-local (an index into the backend's own table).
typedef struct vfs_fs {
    const char *prefix;                              // "/" = fallback, "/tmp" etc.
    int  (*open)  (const char *path, int flags);     // -> handle >=0, or -1
    int  (*read)  (int h, char *buf, int n);         // bytes (0 = EOF), or -1
    int  (*write) (int h, const char *buf, int n);
    int  (*close) (int h);
    long (*lseek) (int h, long off, int whence);
    long (*size)  (int h);
    int  (*remove)(const char *path);                // 0 ok, -1 err
    int  (*diropen) (const char *path);              // -> dir handle >=0, or -1
    int  (*dirnext) (int dh, struct vfs_dirent *o);  // 1 = entry, 0 = end, -1 err
    void (*dirclose)(int dh);
} vfs_fs;

void          vfs_register(const vfs_fs *fs);   // register a backend
const vfs_fs *vfs_lookup(const char *path);     // longest-prefix match, or NULL

// Current directory + relative-path resolution.  A relative path resolves
// against the cwd (default "/"); an absolute path is taken as-is.
void          vfs_abspath(const char *in, char *out, int outsz);
int           vfs_chdir(const char *path);      // 0 ok, -1 not a directory
const char   *vfs_getcwd(void);

// Directory listing across the VFS: the claiming backend's entries PLUS any
// child mount points (e.g. listing "/" yields the SD root + "tmp").
int  vfs_opendir(const char *path);             // dir handle >=0, or -1
int  vfs_readdir(int d, struct vfs_dirent *o);  // 1 = entry, 0 = end, -1 = err
void vfs_closedir(int d);

// Backends self-register via these (called once at boot).
void fatfs_backend_register(void);
void tmpfs_backend_register(void);

#endif /* VFS_H */
