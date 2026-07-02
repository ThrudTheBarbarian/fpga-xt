/* busybox-compat: sys/resource.h — newlib's (rusage), plus the rlimit surface
 * ash's ulimit wants. The shim's getrlimit reports "unlimited"; setrlimit fails. */
#ifndef _BB_COMPAT_SYS_RESOURCE_H
#define _BB_COMPAT_SYS_RESOURCE_H

#include_next <sys/resource.h>

typedef unsigned long rlim_t;
#define RLIM_INFINITY ((rlim_t)~0ul)

struct rlimit {
    rlim_t rlim_cur;
    rlim_t rlim_max;
};

#define RLIMIT_CPU     0
#define RLIMIT_FSIZE   1
#define RLIMIT_DATA    2
#define RLIMIT_STACK   3
#define RLIMIT_CORE    4
#define RLIMIT_RSS     5
#define RLIMIT_NPROC   6
#define RLIMIT_NOFILE  7
#define RLIMIT_MEMLOCK 8
#define RLIMIT_AS      9
#define RLIMIT_LOCKS   10

#ifdef __cplusplus
extern "C" {
#endif
int getrlimit(int resource, struct rlimit *rlp);
int setrlimit(int resource, const struct rlimit *rlp);
#ifdef __cplusplus
}
#endif

#endif
