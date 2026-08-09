/* xt_random.h — the kernel CSPRNG behind /dev/random and /dev/urandom.
 *
 * Output comes from ChaCha20 keyed by SHA-256-conditioned words gathered from
 * the PL TRNG, each one gated on TRNG_STAT[8] so it is backed by 32 genuinely
 * fresh debiased bits. See xt_random.c for why both halves of that matter.
 */
#ifndef XT_RANDOM_H
#define XT_RANDOM_H

#include <stdint.h>
#include <stddef.h>

/* Fill `buf` with `n` cryptographically random bytes. Never fails: if the
 * hardware gather is unavailable the construction still holds, but the result
 * rests on clock seeding — ask xt_random_is_hw() if that distinction matters. */
void xt_random_bytes(void *buf, size_t n);

/* Non-zero once the pool has been keyed at least once. */
int xt_random_ready(void);

/* Non-zero when the CURRENT key was derived from a successful hardware gather.
 * Zero on qemu, or after a TRNG fault made the gather time out. Callers drawing
 * long-lived key material should refuse rather than proceed when this is zero. */
int xt_random_is_hw(void);

/* Mix a seed (typically 32 bytes persisted across a boot) into the pool. It is
 * hashed WITH the existing state, so a stale or known seed can only add to the
 * pool's unpredictability, never reduce it. */
void xt_random_add_seed(const void *seed, size_t n);

/* Produce 32 bytes to persist for the next boot. Drawn from the cipher like any
 * other output, so it reveals nothing about the key; overwrite the stored copy
 * as soon as it has been read back, so a stolen image cannot replay it. */
void xt_random_save_seed(uint8_t out[32]);

/* Non-zero when this build has a TRNG at all (XT_HW). The getrandom() blocking
 * contract only makes sense where there is something to wait FOR: on qemu a
 * blocking wait would never end, so callers must not impose one. */
int xt_random_hw_present(void);

/* Force one gather-and-rekey. 0 = the new key is hardware-backed, -1 = the
 * gather failed and it rests on the clock. This is the retry primitive behind
 * a blocking getrandom(); the delay between attempts belongs to the caller,
 * which is the only side that knows about the scheduler. */
int xt_random_gather(void);

/* Read the across-boot seed from `path`, mix it in, and immediately overwrite
 * it with fresh bytes. Call once from TASK context after the filesystem holding
 * `path` is mounted — it does real file I/O. Returns 0 when the replacement
 * seed was written, -1 when it could not be (no writable filesystem there):
 * the caller should LOG that, because a seed that silently fails to persist
 * looks exactly like one that works. A missing seed on the way IN is not an
 * error — the first boot of a fresh card has none. */
int xt_random_seed_boot(const char *path);

#endif
