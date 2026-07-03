/* libc-compat: sys/random.h — the shim's getentropy is a timer-seeded
 * xorshift (uuidgen/mktemp; NOT cryptographic). The header's presence is
 * also the feature probe (__has_include) toybox uses to pick this API
 * over reading /dev/urandom, which doesn't exist here. */
#ifndef _XT_COMPAT_SYS_RANDOM_H
#define _XT_COMPAT_SYS_RANDOM_H

#include <sys/types.h>

#define GRND_NONBLOCK 1
#define GRND_RANDOM   2

#ifdef __cplusplus
extern "C" {
#endif
int getentropy(void *buf, size_t len);
ssize_t getrandom(void *buf, size_t len, unsigned flags);
#ifdef __cplusplus
}
#endif

#endif
