/* libc-compat: sys/mount.h — no mount syscall on XTOS (the VFS mount table
 * is kernel-internal); declaration surface only. */
#ifndef _XT_COMPAT_SYS_MOUNT_H
#define _XT_COMPAT_SYS_MOUNT_H

/* toybox's portability.h only includes sys/statfs.h under __linux__ but uses
 * struct statfs unconditionally; it includes THIS header just before, so
 * carry it. */
#include <sys/statfs.h>

#define MS_RDONLY   1
#define MS_NOSUID   2
#define MS_NODEV    4
#define MS_NOEXEC   8
#define MS_REMOUNT  32
#define MS_BIND     4096
#define MS_MOVE     8192
#define MNT_DETACH  2

#ifdef __cplusplus
extern "C" {
#endif
int mount(const char *src, const char *dst, const char *type,
          unsigned long flags, const void *data);
int umount(const char *target);
int umount2(const char *target, int flags);
#ifdef __cplusplus
}
#endif

#endif
