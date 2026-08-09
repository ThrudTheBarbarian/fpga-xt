/* XTOS dropbear-port shim: sys/random.h.
 *
 * This was an empty stub from when there was no getrandom() to declare, and it
 * shadows libc-compat's real header because dropbear-config comes first on the
 * include path — so dbrandom.c saw HAVE_SYS_RANDOM_H, included this, and found
 * no GRND_NONBLOCK. Chain to the real one rather than restate it: one truth for
 * the declarations, and this file exists only for the search order.
 */
#ifndef XTSTUB_sys_random_h
#define XTSTUB_sys_random_h
#include_next <sys/random.h>          /* loader/libc-compat/sys/random.h */
#endif
