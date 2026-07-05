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

## Compile-map: COMPLETE

**Everything compiles for the target.** 69/69 Dropbear server sources compile clean, and
the bundled crypto (libtomcrypt, libtommath) compiles clean too. Config + stubs live in
`loader/dropbear-config/` (submodule untouched):
- `localoptions.h`: server, pubkey-only, no fwd/agent/X11, XTOS `DEFAULT_PATH`.
- `libgen.h` shim: our newlib `string.h` declares GNU `basename(const char*)`, which
  collides with newlib `libgen.h`'s XPG `basename(char*)`; the shim provides `dirname` and
  defers `basename` to `string.h` (shadows newlib's — `-Idropbear-config` is first).
- header stubs: `netinet/ip.h`, `netinet/in_systm.h`, `sys/{endian,prctl,random}.h`, and
  `sys/un.h` (minimal `sockaddr_un` + `PF_UNIX` so the unused unix-socket paths compile).
- build flags: `-DDROPBEAR_SERVER=1 -DDROPBEAR_CLIENT=0` (both default 0, `#ifndef`-guarded),
  no `-D_GNU_SOURCE` at compile (drags in GNU `basename`).

## Link surface (88 unmet symbols, categorised)

- **~60 crypto** (`chacha_*`, `sha256/384/512_*`, `poly1305_*`, `ecc_*`, `hmac_*`, `mp_*`,
  `ltc_*`, `register_*`, `find_cipher/hash`) → satisfied by compiling the libtomcrypt/
  libtommath subset into the link. Build work, not porting.
- **~8 `__aeabi_*` + `_GLOBAL_OFFSET_TABLE_`** → libgcc + PIC linker. Free.
- **2 endian macros** `htole64`/`le64toh` → flesh out `dropbear-config/sys/endian.h`.
- **The real libc surface is tiny:** `select` (main-loop multiplexing — implement over the
  netconn/poll layer), plus single-user no-op/trivial stubs: `chown`, `setegid`, `seteuid`,
  `getrlimit`, `setrlimit`, `utimes`, `gethostbyaddr`, `getservbyname`.

**Key finding:** `openpty` and `getrandom` are NOT missing symbols — Dropbear reaches the
pty and entropy through `open()`/`read()` on **`/dev/ptmx`** and **`/dev/urandom`**. So pty
and entropy are **kernel *device* work at runtime, not libc functions.** That's the real
substance of the remaining port, and it's cleanly separated from the (small) symbol layer.

## Remaining work, in order

1. **build-dropbear.sh** + loader Makefile target: compile the server + libtom subset into
   objects, link the PIC `.so` (mirror `toybox.so`).
2. **Symbol layer** (shim): `select` over the netconn poll; the trivial single-user stubs;
   `sys/endian.h` macros.
3. **`/dev/urandom`** (kernel char device): seed a CSPRNG (jitter + packet timing + global
   timer; PL ring-oscillator TRNG later). *Dev-grade entropy until a real TRNG lands.*
4. **`/dev/ptmx` pty** (kernel): master/slave pair + line discipline + `TIOCSWINSZ`/
   `TIOCSCTTY`/`TIOCGPTN`/`TIOCSPTLCK`. The big new primitive; needed only for the
   interactive shell — `ssh board 'cmd'` (exec) and scp land before it.
5. **Runtime**: `dropbearkey` ed25519 host key → `/OS/etc/dropbear/`; authorized_keys;
   bring-up order transport → KEX → pubkey auth → exec → scp → pty + interactive shell.

## Deploy
Server binary builds to a PIC `.so` (like toybox) → **sdpush**; anything needing the kernel
(pty layer, entropy syscall) → **make hw + JTAG**.
