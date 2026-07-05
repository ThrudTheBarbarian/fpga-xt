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

## Build + link: DONE

`tools/build-dropbear.sh` compiles the 65-object server set + libtomcrypt.a + libtommath.a
out-of-tree (~35 s cold), and `make build/dropbear.so` links a **335 KB PIC `.so`** —
mirroring `toybox.so` (posix/net shim + `dropbear_glue.o` over `libc.so`). Split flag note:
Dropbear's own files build WITHOUT `-DLTC_SOURCE` (that's libtomcrypt-internal and clashes
its math macros against libtommath); the libtomcrypt archive builds WITH it.

`dropbear_glue.c` supplies the small libc surface: `select()` over `poll()`, and single-user
no-ops (`chown`, `set[e]uid/gid`, `get/setrlimit`, `utimes`, `gethost*/getserv*`).
Everything else resolves from `libc.so`; the only load-time unresolved is `_close` (a
kernel-export primitive, same as toybox.so). `dropbearkey.o` is excluded (its own `main`).

## MILESTONE: dropbearkey RUNS on XTOS

`dropbearkey -t ed25519 -f <file>` runs on qemu and generates a valid ed25519 host key,
writes it, and re-reads it identically (`-y`) — proving the `.so` loads and executes, the
full crypto (libtomcrypt/libtommath ed25519) works at runtime, `/dev/urandom` seeds it, and
file I/O round-trips. Built by `make` (`dropbearkey.so` target → `/bin/dropbearkey` in the
romfs); its objects are the COMMON set + dropbearkey compiled NEUTRAL (no `DROPBEAR_SERVER`).
One fix needed: XTOS has no hard links, and dropbearkey writes a temp file then `link()`s it
to the final name, falling back to a plain write only on EPERM/EACCES/ENOSYS — newlib's
`link()` failed with errno 0, skipping the fallback, so `dropbear_glue.c` now provides
`link()` returning EPERM. (Build note: build sequentially — interleaving build-dropbear.sh
with `make` produced a corrupt toybox.so once.)

## MILESTONE: server starts, listens, accepts (fork blocker confirmed)

`dropbear -F -r <key> -p <port>` runs on qemu: parses args, "Not backgrounding", binds and
listens — the server `.so` executes. qemu has working networking (SLIRP, `e0`/10.0.2.15), so
with `-nic user,hostfwd=tcp::2222-:22` a host `ssh -p 2222 root@127.0.0.1` reaches it: TCP
connects and dropbear ACCEPTS (not refused), but the client times out "during banner
exchange" — no banner comes back. Root cause CONFIRMED empirically: `svr-main.c:308`
`fork()`s a child per connection to send the banner + run KEX, and XTOS has no fork
(`posix_shim.c`: "there is no fork"), so the handler never runs. Exactly the predicted gap.
(Also: drop `-E` — syslog is disabled, so stderr is already the log and `-E` is unknown.)

So the transport is one launcher away: **inetd mode + an XTOS sshd listener** that binds :22,
accepts, and `SYS_spawn_fd`s `dropbear -i` with the socket as fd 0/1 (model on `httpd.so`,
which already does listen/accept). That gets KEX + pubkey auth working over a real
connection; the interactive session then needs `spawn_command`→spawn + the pty.

Packaging done: `dropbear.so` → `/bin/dropbear` in the romfs (alongside `/bin/dropbearkey`).

## Runtime — decisions + status

**`/dev/urandom` — DONE.** Already exists in `vfs_devfs.c` (`dv_rand_rd`, per-open
clock-seeded xorshift), mounted at `/OS/dev`, reachable as `/dev/urandom` via the `/dev`
root alias — exactly Dropbear's default `DROPBEAR_URANDOM_DEV`. Dev-grade (weak clock seed);
the fabric TRNG later just repoints `dv_rand_rd` at a PL register. No changes needed.

**fork model — DECIDED.** Dropbear forks in two places; XTOS maps both onto what it has:
- *Per-connection* (`svr-main.c main_noinetd` `fork()` at ~308): use **inetd mode**
  (`main_inetd`, one connection on stdin/stdout). A small XTOS sshd listener binds :22,
  accepts, and `SYS_spawn_fd`s `dropbear -i` with the connection socket as fd 0/1 — our
  existing spawn + fd inheritance, no fork.
- *Shell launch* (`spawn_command` in svr-chansession) forks+execs the login shell → adapt
  to `SYS_spawn` (or the shim vfork path toybox already uses).

## Remaining work, in order

1. **XTOS sshd listener** + `localoptions.h` for inetd/no-fork; wire `dropbear -i`.
2. **`spawn_command`** → XTOS spawn (verify the shim fork/vfork path or route to `SYS_spawn`).
3. **host key** — package `dropbearkey` (separate `.so`, or dbmulti argv[0] dispatch); gen
   an ed25519 key → `/OS/etc/dropbear/`; authorized_keys there too.
4. **`/dev/ptmx` pty** (kernel): master/slave + line discipline + `TIOCSWINSZ`/`TIOCSCTTY`/
   `TIOCGPTN`/`TIOCSPTLCK`. Only for the interactive shell — exec + scp land before it.
5. **bring-up order**: transport → KEX → pubkey auth → exec (no pty) → scp → pty + shell.
   (Steps 3-4 touch the kernel — coordinate with in-flight kernel work.)

## Deploy
Server binary builds to a PIC `.so` (like toybox) → **sdpush**; anything needing the kernel
(pty layer, entropy syscall) → **make hw + JTAG**.
