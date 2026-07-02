/* libc-compat: setjmp.h — newlib's, plus sigjmp_buf (newlib only has it for
 * Cygwin/RTEMS). No signal masks on XTOS, so the sig forms are the plain ones. */
#ifndef _XT_COMPAT_SETJMP_H
#define _XT_COMPAT_SETJMP_H

#include_next <setjmp.h>

#ifndef sigsetjmp
typedef jmp_buf sigjmp_buf;
# define sigsetjmp(env, savemask) setjmp(env)
# define siglongjmp(env, val)     longjmp(env, val)
#endif

#endif
