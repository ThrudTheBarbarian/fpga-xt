# Handoff: `/dev/random` entropy gating (RTL side is DONE)

**For:** the compiler/language/OS thread.
**From:** the RTL thread. All hardware changes below are committed; nothing
further is needed in `hdl/`. This document is the software work that remains.

> **Status 2026-07-29: all five items are implemented**, in
> `loader/test/freertos/xt_random.c` (+ `.h`). `/dev/random`, `/dev/urandom`,
> `getentropy()`, `getrandom()` and Dropbear now draw from one pool: ChaCha20
> keyed by SHA-256-conditioned words, each gathered behind `TRNG_STAT[8]`.
> Two deliberate deviations from the plan below, both noted where they land in
> the code:
>
> - **Item 2, "prefer reusing Dropbear's ChaCha20/SHA-256":** not possible.
>   Dropbear is a userspace `.so` and `vfs_devfs.c` is in the FreeRTOS kernel
>   image, so there is no link path between them. Both primitives are written
>   out plainly in `xt_random.c` instead.
> - **Item 4, "persist 32 bytes at shutdown":** there is no shutdown hook to
>   hang it on — `SYS_reboot` masks interrupts and resets the PS, so no
>   filesystem write can run there. The seed is instead read at boot and
>   **immediately overwritten** with fresh bytes (`xt_random_seed_boot`, called
>   from `shell_task` once the SD is mounted). Same no-replay guarantee, and it
>   covers a power cut too.
>
> Item 5's blocking contract holds wherever a TRNG exists to wait for: on
> hardware the default blocks for a gather and returns `EIO` if the TRNG is
> faulted, never clock-seeded bytes, and `GRND_NONBLOCK` gets `EAGAIN` — the
> path Dropbear's `dbrandom.c` probes with (`HAVE_GETRANDOM` is now forced on in
> `tools/build-dropbear.sh`, since configure's link test links against newlib
> alone and cannot see the shim's definition). On qemu there is nothing to wait
> for, so neither branch applies; `xt_random_is_hw()` tells the cases apart.
>
> Not yet run on hardware — built only. The verification below is still to do.

## The problem

`/dev/random` and `/dev/urandom` (same node, `loader/test/freertos/vfs_devfs.c`,
`dv_rand_rd`) are a per-open **xorshift32** whose state is XOR-stirred with a
hardware entropy word every 32 bits:

```c
if ((i & 3u) == 0) s ^= hw_entropy();   /* 0x43C00700 = TRNG_RND */
s ^= s << 13; s ^= s >> 17; s ^= s << 5;
b[i] = (uint8_t)s;                      /* output IS the PRNG state */
```

Two defects, both on the hardware path (qemu is dev-only and out of scope):

**1. The pool is drained faster than it fills.** `xt_trng` produces one raw bit
per `clk_sys` (133.3 MHz), von-Neumann debiased at ~25% yield → ~33 Mbit/s, so
**32 fresh bits take ~0.96 µs**. An AXI GP0 read is ~100–300 ns. Back-to-back
reads therefore return an LFSR-stretched pool that has absorbed a *fraction of a
bit* since the previous read. Generating a 256-bit SSH host key pulls 8 reads in
~1.6 µs and gets roughly **50 bits** of genuine entropy.

**2. Everything after the debias stage is linear** — Galois LFSR pool, XOR into
the PRNG, xorshift32, and output bytes taken directly from the state. So the
shortfall is not concealed by the construction; given a few output bytes the
state can be recovered and rolled forward or backward. It degrades *silently*
rather than blocking or erroring.

The TRNG itself is fine: 24 ring oscillators, two-stage async capture where the
metastability is the entropy, von-Neumann debias, 32-bit whitening pool. The
source is sound; the accounting and the extraction were missing.

## What the RTL now gives you

`xt_trng` counts debiased bits since the last consume, and `TRNG_RND` is now
**read-to-consume** (same pattern as `MATH_EVT`): reading it restarts the count,
so a subsequent `fresh` means 32 genuinely *new* bits.

New register, in the generated map (`hdl/regmap/xt_gp0_map.h`):

| symbol | addr | bits |
|---|---|---|
| `XT_TRNG_RND` | `0x43C00700` | R, 32-bit entropy word. **Reading consumes** — restarts the freshness count. |
| `XT_TRNG_STAT` | `0x43C00704` | R, `[5:0]` = debiased bits since last `TRNG_RND` read (saturates at 32); `[8]` = `fresh` (≥32, a fully re-seeded word) |

Poll `TRNG_STAT[8]` before each `TRNG_RND` read and you get a word backed by 32
fresh debiased bits. Expect ~1 µs per word — fine for key material (32 bytes =
8 words ≈ 8 µs), useless for bulk.

## What to do in software

1. **Gate the gather.** Add a helper that spins on `XT_TRNG_STAT` bit 8 before
   each `XT_TRNG_RND` read. Bound the spin (a few ms) and fail loudly on
   timeout — never silently fall through to an ungated read.

2. **Stop emitting PRNG state.** Gather ~32 bytes through the gate, use it to
   key a **ChaCha20** stream, and serve `/dev/random` bytes from the cipher.
   Rekey periodically (say every 1 MB or 60 s) from freshly gated words. This
   removes the linear-everywhere problem and gives backtracking resistance.
   Dropbear already brings ChaCha20 and SHA-256 into the tree — prefer reusing
   those over a second implementation.

3. **Condition, don't XOR.** Feed gathered words through SHA-256 (or BLAKE2s) to
   derive the ChaCha key rather than XOR-stirring them into a state word. XOR is
   not an extractor and does not remove structure the LFSR leaves behind.

4. **Seed across boots.** Persist 32 bytes at shutdown, mix on start, and
   overwrite immediately after reading so a stolen image cannot replay it.

5. **`getrandom()`** (`loader/libc-compat/sys/random.h`) should block until the
   first successful gated gather, matching the Linux contract. This is the
   interface Dropbear should use.

## Why it matters now

`loader/test/freertos/libs/dropbear_glue.c` names `/dev/urandom` as one of the
two kernel facilities Dropbear needs. SSH host and session keys are drawn from
this path. The SSH port is on a branch and not yet deployed to hardware
([[ssh_server_port]]), so fixing it before it ships avoids having to rotate keys
generated by a weak RNG afterwards.

## Verification

`gp0_mux` and the golden boot co-sim pass with the RTL change. On hardware,
`mr 43C00704` should show `[5:0]` climbing to 32 and bit 8 setting within ~1 µs
of an `mr 43C00700`, then restarting from ~0 after each read of `0x700`.
