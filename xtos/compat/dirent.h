/* dirent.h — minimal POSIX directory shim for the bare-metal A9 build.
 *
 * newlib (arm-none-eabi) ships no working <dirent.h>, but the portable GEM
 * font loader (gem/vdi/load_fonts.c) uses opendir/readdir/closedir.  This
 * header + xtos/src/posix_dir.c bridge them onto the VFS (vfs_opendir/…).
 * Placed on the A9 include path so `#include <dirent.h>` resolves here; the
 * SDL host build uses the real system header instead.
 */
#ifndef XTOS_COMPAT_DIRENT_H
#define XTOS_COMPAT_DIRENT_H

#ifdef __cplusplus
extern "C" {
#endif

struct dirent {
    char d_name[256];          /* filename (no path) */
};

typedef struct __dirstream DIR;

DIR           *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int            closedir(DIR *dirp);

#ifdef __cplusplus
}
#endif

#endif /* XTOS_COMPAT_DIRENT_H */
