/* libc-compat: stdio.h — newlib's, plus POSIX getdelim/getline spellings
 * (newlib ships the implementations as __getdelim/__getline only). */
#ifndef _XT_COMPAT_STDIO_H
#define _XT_COMPAT_STDIO_H

#include_next <stdio.h>

#define getdelim __getdelim
#define getline  __getline

#endif
