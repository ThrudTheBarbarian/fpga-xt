/* libc-compat: sys/stat.h — newlib's, plus lstat/mknod (newlib only declares
 * them for SPU/RTEMS/Cygwin; lstat is the posix shim over SYS_lstat, mknod
 * always fails — no device nodes on the VFS) */
#ifndef _XT_COMPAT_SYS_STAT_H
#define _XT_COMPAT_SYS_STAT_H

#include_next <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif
int lstat(const char *__restrict path, struct stat *__restrict buf);
int mknod(const char *path, mode_t mode, dev_t dev);
#ifdef __cplusplus
}
#endif

#endif
