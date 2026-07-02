/* libc-compat: regex.h — newlib's uses off_t without pulling in sys/types.h */
#ifndef _XT_COMPAT_REGEX_H
#define _XT_COMPAT_REGEX_H

#include <sys/types.h>
#include_next <regex.h>

#endif
