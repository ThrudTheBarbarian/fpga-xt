# SSH server (Dropbear) — XTOS port

Goal: run an SSH **server** on XTOS so you can `ssh`/`scp` **into** the board over the
network, retiring the serial-paste / JTAG file workflow. Library: **Dropbear**
(github.com/mkj/dropbear, MIT — no GPL), pinned as a submodule at
`third_party/dropbear` (tag `DROPBEAR_2025.88`). Auth: **public key** (XTOS has no
`crypt()`, so no password hashing — and pubkey is better anyway).

The port layers on top of the pristine submodule: config + stubs live in
`loader/dropbear-config/` (on the `-I` path), objects build out-of-tree into
`loader/build/dropbear/`, and the final link is a PIC `.so` against `libc.so` + the
posix/net shim, exactly like `toybox.so`.

## Build harness (works today)

Out-of-tree configure with newlib's nosys stubs so autoconf's link tests pass:

```
cd loader/build/dropbear
CC=arm-none-eabi-gcc \
CFLAGS="-marm -mcpu=cortex-a9 -mfloat-abi=softfp -mfpu=neon-vfpv3 -fno-builtin \
        --specs=nosys.specs -I<libc-compat> -I<newlib-pic/include>" \
  ../../../third_party/dropbear/configure --host=arm-none-eabi \
  --disable-zlib --disable-pam --disable-syslog --disable-lastlog \
  --disable-utmp --disable-utmpx --disable-wtmp --disable-loginfunc
# generate the guard header the Makefile would:
sh <db>/src/ifndef_wrapper.sh < <db>/src/default_options.h > default_options_guard.h
```

Gotchas found: `--specs=nosys.specs` must appear in CFLAGS **only** (in LDFLAGS too =
"spec already defined"); Dropbear includes `localoptions.h` only under
**`-DLOCALOPTIONS_H_EXISTS`**; compile flags do **not** want `-D_GNU_SOURCE` (it drags in
GNU `basename` — see below).

## Compile-map: porting surface (in dependency order)

**Done**
- Build harness: configure (nosys.specs), guard-header generation, `-DLOCALOPTIONS_H_EXISTS`.
- `loader/dropbear-config/localoptions.h`: server, pubkey-only, no fwd/agent/X11, XTOS `DEFAULT_PATH`.
- Missing-header stubs in `dropbear-config/`: `netinet/ip.h`, `netinet/in_systm.h`,
  `sys/endian.h`, `sys/prctl.h`, `sys/random.h`, `sys/un.h` (minimal; flesh out as used).

**Next — header reconciliation**
- `libgen.h` vs `string.h`: our newlib-pic `string.h` declares GNU `basename(const char*)`,
  which collides with `libgen.h`'s XPG `basename(char*)` → `conflicting types for
  __xpg_basename`. Fix: a small `dropbear-config/libgen.h` shim (declare `dirname`, defer
  `basename` to string.h) — shadows newlib's since `-Idropbear-config` is first.
- `svr_ses undeclared` in svr-auth/svr-chansession/svr-authpubkey: a Dropbear-internal
  config gate (the `extern struct serversession svr_ses` decl isn't visible under our
  option set) — resolve once the header layer compiles cleanly.

**Then — link layer (missing functions to provide in the shim/kernel)**
- **Entropy** — Dropbear seeds its CSPRNG from `/dev/urandom` / `getrandom`. Provide a seed
  source (jitter + packet timing + global timer; a PL ring-oscillator TRNG later). *Security
  caveat: dev-grade until a real TRNG lands.*
- **pty** — the big new kernel primitive. `sshpty.c` wants `openpty`/`login_tty`
  semantics: master/slave pair, line discipline, `TIOCSWINSZ`/`TIOCSCTTY`. Needed for the
  interactive shell; a non-interactive `ssh board 'cmd'` and scp can land first without it.
- Smaller stubs likely: `getpwnam`/`getpwuid` (single-user root), signals, `getgrouplist`,
  `clearenv`, `prctl` (no-op).

**Runtime bring-up**
- Host key: `dropbearkey` (ed25519) → `/OS/etc/dropbear/`.
- authorized_keys under `/OS/etc/dropbear/` (or a user home).
- Phase order: transport + KEX + pubkey auth + `exec` (no pty) → scp-in → pty + interactive shell.

## Deploy
Server binary builds to a PIC `.so` (like toybox) → **sdpush**; anything needing the kernel
(pty layer, entropy syscall) → **make hw + JTAG**.
