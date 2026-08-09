/* libc-compat: sys/random.h — both entry points reach the kernel CSPRNG through
 * SYS_getrandom: ChaCha20 keyed by SHA-256-conditioned words from the PL TRNG,
 * each gated on TRNG_STAT[8]. On hardware the blocking form waits for a gather
 * to succeed and fails with EIO if the TRNG is faulted — it never substitutes
 * clock-seeded bytes. GRND_NONBLOCK opts into whatever the pool can serve now.
 * (Until 2026-07 this was a timer-seeded xorshift that emitted its own state.)
 *
 * The header's presence is also the feature probe (__has_include) toybox uses
 * to pick this API over reading /dev/urandom — which does now exist, served by
 * this same pool, but the syscall skips the open. This is the interface
 * Dropbear should use. */
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
