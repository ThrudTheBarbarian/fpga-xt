/* libc-compat: sys/wait.h — newlib's, plus the W* spellings it lacks.
 * No job control on XTOS: nothing is ever stopped/continued. */
#ifndef _XT_COMPAT_SYS_WAIT_H
#define _XT_COMPAT_SYS_WAIT_H

#include_next <sys/wait.h>

#ifndef WCONTINUED
# define WCONTINUED 8
#endif
#ifndef WIFCONTINUED
# define WIFCONTINUED(w) 0
#endif

#endif
