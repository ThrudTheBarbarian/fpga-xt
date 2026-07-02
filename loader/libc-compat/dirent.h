/* libc-compat: dirent.h — newlib's is a "#error not supported" stub.
 * Backed by SYS_readdir (stateless path+index) via the posix shim. */
#ifndef _XT_COMPAT_DIRENT_H
#define _XT_COMPAT_DIRENT_H

#include <sys/types.h>

struct dirent {
    ino_t         d_ino;
    unsigned char d_type;
    char          d_name[256];
};

/* opaque cursor: the shim re-issues SYS_readdir(path, index) per entry */
typedef struct __xt_DIR DIR;

#define DT_UNKNOWN 0
#define DT_FIFO    1
#define DT_CHR     2
#define DT_DIR     4
#define DT_BLK     6
#define DT_REG     8
#define DT_LNK     10
#define DT_SOCK    12

#define IFTODT(mode) (((mode) & 0170000) >> 12)
#define DTTOIF(dt)   ((dt) << 12)

#ifdef __cplusplus
extern "C" {
#endif
DIR *opendir(const char *name);
DIR *fdopendir(int fd);
struct dirent *readdir(DIR *dir);
int closedir(DIR *dir);
void rewinddir(DIR *dir);
int dirfd(DIR *dir);
#ifdef __cplusplus
}
#endif

#endif
