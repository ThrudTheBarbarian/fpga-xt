/* busybox-compat: glob.h — POSIX-flavoured, replacing newlib's BSD header
 * (whose implementation never shipped in libc.a anyway). The implementation
 * is the posix shim's: readdir + fnmatch per path component. */
#ifndef _BB_COMPAT_GLOB_H
#define _BB_COMPAT_GLOB_H

#include <stddef.h>

typedef struct {
    size_t gl_pathc;
    char **gl_pathv;
    size_t gl_offs;
} glob_t;

/* flags */
#define GLOB_ERR      0x0001
#define GLOB_MARK     0x0002
#define GLOB_NOSORT   0x0004
#define GLOB_DOOFFS   0x0008
#define GLOB_NOCHECK  0x0010
#define GLOB_APPEND   0x0020
#define GLOB_NOESCAPE 0x0040

/* error returns */
#define GLOB_NOSPACE  1
#define GLOB_ABORTED  2
#define GLOB_NOMATCH  3

#ifdef __cplusplus
extern "C" {
#endif
int glob(const char *pattern, int flags,
         int (*errfunc)(const char *, int), glob_t *g);
void globfree(glob_t *g);
#ifdef __cplusplus
}
#endif

#endif
