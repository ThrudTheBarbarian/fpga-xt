/* libc-compat: paths.h — newlib's, plus the _PATH_* spellings it lacks,
 * pointed at the XTOS filesystem layout. */
#ifndef _XT_COMPAT_PATHS_H
#define _XT_COMPAT_PATHS_H

#include_next <paths.h>

#ifndef _PATH_DEFPATH
# define _PATH_DEFPATH "/System/bin:/OS/bin:/bin"
#endif
#ifndef _PATH_BSHELL
# define _PATH_BSHELL "/System/bin/sh"
#endif
#ifndef _PATH_TTY
# define _PATH_TTY "/dev/tty"
#endif
#ifndef _PATH_DEVNULL
# define _PATH_DEVNULL "/dev/null"
#endif

#endif
