/* libc-compat: sys/statvfs.h — declaration surface only */
#ifndef _XT_COMPAT_SYS_STATVFS_H
#define _XT_COMPAT_SYS_STATVFS_H

#include <sys/types.h>   /* newlib already typedefs fsblkcnt_t/fsfilcnt_t */

struct statvfs {
    unsigned long f_bsize;
    unsigned long f_frsize;
    fsblkcnt_t    f_blocks;
    fsblkcnt_t    f_bfree;
    fsblkcnt_t    f_bavail;
    fsfilcnt_t    f_files;
    fsfilcnt_t    f_ffree;
    fsfilcnt_t    f_favail;
    unsigned long f_fsid;
    unsigned long f_flag;
    unsigned long f_namemax;
};

#define ST_RDONLY 1
#define ST_NOSUID 2

#ifdef __cplusplus
extern "C" {
#endif
int statvfs(const char *path, struct statvfs *buf);
int fstatvfs(int fd, struct statvfs *buf);
#ifdef __cplusplus
}
#endif

#endif
