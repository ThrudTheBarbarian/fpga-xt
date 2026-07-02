/* libc-compat: sys/statfs.h — declaration surface; the shim answers statfs
 * with ramfs/fatfs-appropriate fakes if anything configured-in ever asks. */
#ifndef _XT_COMPAT_SYS_STATFS_H
#define _XT_COMPAT_SYS_STATFS_H

struct statfs {
    unsigned f_type;
    unsigned f_bsize;
    unsigned f_frsize;
    unsigned f_blocks;
    unsigned f_bfree;
    unsigned f_bavail;
    unsigned f_files;
    unsigned f_ffree;
    unsigned f_fsid;
    unsigned f_namelen;
    unsigned f_flags;
};

#ifdef __cplusplus
extern "C" {
#endif
int statfs(const char *path, struct statfs *buf);
int fstatfs(int fd, struct statfs *buf);
#ifdef __cplusplus
}
#endif

#endif
