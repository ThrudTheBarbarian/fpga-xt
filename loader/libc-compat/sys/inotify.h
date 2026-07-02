/* libc-compat: sys/inotify.h — no file-watch facility on XTOS; the shim's
 * inotify_* fail (nothing configured in watches files). */
#ifndef _XT_COMPAT_SYS_INOTIFY_H
#define _XT_COMPAT_SYS_INOTIFY_H

#include <stdint.h>

struct inotify_event {
    int      wd;
    uint32_t mask;
    uint32_t cookie;
    uint32_t len;
    char     name[];
};

#define IN_MODIFY 0x002
#define IN_ATTRIB 0x004
#define IN_MOVED_TO 0x080
#define IN_CREATE 0x100
#define IN_DELETE 0x200

#ifdef __cplusplus
extern "C" {
#endif
int inotify_init(void);
int inotify_init1(int flags);
int inotify_add_watch(int fd, const char *path, uint32_t mask);
int inotify_rm_watch(int fd, int wd);
#ifdef __cplusplus
}
#endif

#endif
