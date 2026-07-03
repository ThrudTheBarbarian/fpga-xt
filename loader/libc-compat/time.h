/* libc-compat: time.h — newlib's, plus the POSIX clock API surface bare-metal
 * newlib hides (the shim implements clock_gettime over the A9 global timer
 * via SYS_gettimeofday, and nanosleep as a timed wait). */
#ifndef _XT_COMPAT_TIME_H
#define _XT_COMPAT_TIME_H

#include_next <time.h>

#ifndef CLOCK_REALTIME
# define CLOCK_REALTIME  0
#endif
#ifndef CLOCK_MONOTONIC
# define CLOCK_MONOTONIC 1
#endif
#ifndef UTIME_NOW
# define UTIME_NOW  0x3fffffff
#endif
#ifndef UTIME_OMIT
# define UTIME_OMIT 0x3ffffffe
#endif

#ifdef __cplusplus
extern "C" {
#endif
struct timespec;
int clock_gettime(clockid_t clock_id, struct timespec *tp);
int nanosleep(const struct timespec *req, struct timespec *rem);
#ifdef __cplusplus
}
#endif

#endif
