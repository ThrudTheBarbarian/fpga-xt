/* busybox-compat: sys/stat.h — newlib's, plus lstat (newlib only declares it
 * for SPU/RTEMS/Cygwin; the implementation is the posix shim over SYS_lstat) */
#ifndef _BB_COMPAT_SYS_STAT_H
#define _BB_COMPAT_SYS_STAT_H

#include_next <sys/stat.h>

#ifdef __cplusplus
extern "C"
#endif
int lstat(const char *__restrict path, struct stat *__restrict buf);

#endif
