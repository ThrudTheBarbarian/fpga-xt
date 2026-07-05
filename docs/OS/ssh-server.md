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
file I/O round-trips. Built by `make` (`dropbearkey.so` target → `/bin/ssh-keygen` in the
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

Packaging done: `dropbear.so` → `/bin/sshd-session` in the romfs (alongside `/bin/ssh-keygen`).

## MILESTONE: `ssh root@xtos 'cmd'` WORKS — full non-interactive SSH login ✅✅✅

A host runs a command on XTOS over SSH end to end: connect → KEX → **pubkey auth succeeds**
→ **exec → command output returned**. `ssh -i key root@127.0.0.1 'echo hi; pwd'` prints
`hi` / `/`. The whole thing: real crypto transport, RSA pubkey auth, and command execution.

The fixes that got from handshake to login:
1. **pipe O_NONBLOCK** (kernel) — dropbear's signal-pipe drain no longer deadlocks (see below).
2. **`COMPAT_USER_SHELLS`** (localoptions) = "/System/bin/sh",... — dropbear validates the
   login shell against this list when /etc/shells is absent; without it, "invalid shell".
3. **authorized_keys** — default `~/.ssh/authorized_keys` (pw_dir = `/media/home`); an
   explicit dir can be forced via `sshd`'s third arg (`-D`). The qemu harness bakes a test
   key at `/System/etc/ssh/authorized_keys` (romfs-overlay, gitignored — personal key) and
   passes `-D /System/etc/ssh` because `/media/home` lives on the SD.
4. **DROPBEAR_VFORK** — XTOS has no fork; configure saw newlib's nosys fork stub and defined
   HAVE_FORK (→ dropbear used fork() → "exec request failed"). build-dropbear.sh now strips
   `HAVE_FORK` from config.h so sysoptions.h selects `DROPBEAR_VFORK=1`; `spawn_command` then
   uses vfork (the shim's snapshot trick, as toybox's XVFORK) and the command runs.

**Interactive shell — pty subsystem BUILT, I/O pump is the last mile.** `ssh -tt root@xtos`
reaches full auth, dropbear allocates a pty (BSD `/dev/ptyp` scan), sets up the controlling
tty, and **the shell IS spawned** (`/System/bin/sh`). But dropbear's I/O pump hangs — the
shell's output never reaches the client. The pty itself is done: pass-through pairs
`/dev/ptyp[0-3]`+`/dev/ttyp[0-3]` (vfs_devfs.c + frtos_os.c `xt_pty_*`), refcounted opens
(`vf.ondup`), mode/winsize ioctls, O_NONBLOCK read (`vf.nonblock`); `spawn_fd` COPIES a
char-device stdio fd so the pty child's `dup2(slave→0/1/2)` wires all three. Remaining
suspects: (1) the kernel `-EAGAIN` from the nonblock master read may not map to
`errno=EAGAIN` for dropbear's channel read; (2) dropbear's complex pty vfork child
(`pty_make_controlling_tty`) vs our snapshot-vfork (the simple non-pty exec child works).
Next: trace `xt_pty_*` during a live session to see where data stops. Non-interactive exec
works fully; scp needs an scp binary on the guest (dropbear execs the system scp; toybox has none).

## (earlier) real SSH handshake to XTOS (KEX + host key + cipher)

A host OpenSSH client completes the FULL handshake with Dropbear on XTOS over a real TCP
link (qemu `-nic user,hostfwd=tcp::2222-:22`, `sshd` running the inetd launcher):
banner (`dropbear_2025.88`), KEX (`sntrup761x25519-sha512`), ed25519 host key,
chacha20-poly1305 cipher, then pubkey auth offered — "Permission denied (publickey)" only
because no `authorized_keys` is set up yet. The whole crypto transport works.

Two things made it work: (1) the **pipe O_NONBLOCK fix** (dropbear's signal-pipe drain no
longer deadlocks the session loop); (2) `dropbear -i` uses fd 0 for BOTH directions
(`common_session_init(sock, sock)`), so `SYS_spawn_fd` moving the socket onto child fd 0 is
exactly right — no socket-multi-slot work needed after all.

**Remaining for a full login:** (a) pubkey auth — drop a client key in the user's
authorized_keys (getpwnam home + `/.ssh/authorized_keys`); (b) the interactive session —
`spawn_command`→`SYS_spawn` + the `/dev/ptmx` pty. A non-interactive `ssh board 'cmd'` (exec)
lands before the pty.

## (superseded) earlier launcher notes

Built the inetd launcher `sshd.c` (`/bin/sshd`, bare usys, modelled on httpd.c): binds the
port, accepts, and `SYS_spawn_fd`s `dropbear -i` with the socket as the child's fd 0/1/2.
It RUNS and listens ("sshd: listening for ssh"). But a host `ssh` still times out at banner
exchange. The frontier is a cluster of I/O-integration issues to work through, in order:

1. **Session-loop banner flush — ROOT CAUSE FOUND (fix this first).** dropbear
   (common-session.c:95-99) makes a signal self-pipe and `setnonblocking()`s it via
   `fcntl(F_SETFL, O_NONBLOCK)`. The shim's `fcntl(F_SETFL)` is a **NO-OP**, so the pipe
   stays BLOCKING. Each loop iteration adds `signal_pipe[0]` to the read set (line 183),
   `poll_probe` reports pipes as always-readable (empty or not), so `select` returns it
   "readable"; dropbear's drain `while (read(signal_pipe[0],&x,1) > 0)` (line 236) then
   **blocks on the empty pipe → hangs before the banner flushes.** Fix = real pipe
   **O_NONBLOCK**: shim `fcntl(F_SETFL)` records a per-fd nonblock flag (like `g_cloexec`),
   and a nonblock pipe `read()` returns `-1/EAGAIN` when empty instead of blocking (needs a
   "pipe has data" path in the kernel/shim). Shared infra — verify no toybox regression
   (fstest, pipelines). Testable without a connection: `dropbear -i -r key` should then
   print its `SSH-2.0-dropbear...` banner immediately.
2. **Socket-fd inheritance through `SYS_spawn_fd`.** The fd-wiring (frtos_os.c ~2240) MOVES a
   non-console stdio fd to the child's slot — so a socket passed as fds[0..2]=cfd lands only
   on child fd 0 (fd 1/2 fall back to console). For inetd dropbear needs the socket on BOTH
   fd 0 (in) and fd 1 (out): wire a socket fd to multiple child slots and refcount the
   netconn on close (or make main_inetd use one fd for in+out). Needed for the real link.

Test harness note: qemu with `-nic user,hostfwd=tcp::2222-:22` works; **foreground shows
guest output, background does NOT** (qemu buffers stdout to a file). Use foreground for
guest-side debugging; the host `ssh -v` shows the handshake either way.

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

## MILESTONE: interactive `ssh root@xtos` WORKS — pty login shell ✅✅✅

All session shapes pass in the qemu harness, repeatably and back-to-back on one boot:
- `ssh root@xtos 'cmd'` — non-pty exec, output + exit status
- `ssh -tt root@xtos 'cmd'` — forced-pty exec, works even when the client's stdin
  EOFs immediately (`< /dev/null`)
- `ssh -tt root@xtos` — full interactive login shell: prompt, linenoise editing/echo,
  applets resolve via PATH, clean `exit`

### User-facing names + key locations

The Dropbear name is an implementation detail; the runtime binaries use the standard
ssh names (romfs mappings in the loader Makefile):

- `/bin/sshd` — the XTOS listener (binds, accepts, spawns a session process per
  connection). `sshd [port] [hostkeyfile] [authkeysdir]`.
- `/bin/sshd-session` — the per-connection server (Dropbear `svr-main` in inetd mode;
  same name OpenSSH ≥9.8 uses for this role). Spawned by sshd, never run by hand.
- `/bin/ssh-keygen` — the host-key generator (Dropbear dropbearkey; same `-t`/`-f`
  flags: `ssh-keygen -t ed25519 -f /OS/etc/ssh/ed25519_host_key`).

Key locations follow the usual conventions:
- **host key**: `/OS/etc/ssh/ed25519_host_key` (sshd's default; override as argv[2])
- **authorized keys**: `~/.ssh/authorized_keys` — the shim's passwd entry sets
  `pw_dir = /media/home` (matching `HOME`), and dropbear resolves `~` from pw_dir.
  An explicit dir can still be forced with sshd's third arg (`-D`); the qemu harness
  does that (`/System/etc/ssh`, romfs-overlay) because `/media/home` lives on the SD.

### The pty subsystem (kernel + devfs)

Dropbear's `sshpty.c` finds no `/dev/ptmx` and falls back to scanning BSD-style pairs;
XTOS provides 4: `/dev/ptyp[0-3]` (master) + `/dev/ttyp[0-3]` (slave).

- **Core** — `frtos_os.c` `xt_pty_*`: each pair = two FreeRTOS StreamBuffers, `m2s`
  (keystrokes) and `s2m` (shell output). Near-pass-through: the ONE output-discipline
  rule is ONLCR (slave-side writes translate `\n` to `\r\n` — program output writes
  bare newlines and the ssh client's terminal is raw). No input discipline; the
  shell's linenoise sets raw mode and echoes itself. `mopen`/`sopen` are open COUNTS
  (spawn copies refcount via `ondup`). A fresh master open resets both buffers (a dead
  session must not replay into the next). Zero-length write returns 0 (dropbear probes
  with len 0/NULL when its ring is empty). Nonblock read of an empty stream returns
  `-EAGAIN`. ioctls: XT_TTY_GETMODE/SETMODE, TIOCSWINSZ/TIOCGWINSZ, TIOCSCTTY (no-op),
  XT_TTY_NREAD (honest poll).
- **Device nodes** — `vfs_devfs.c`: thin routers (`dv_ptym_*`/`dv_ptys_*`/`dv_pty_*`);
  `f->priv` packs pair index + slave flag.
- **`spawn_fd` copies (not moves) a char-device stdio fd** — the pty child dup2's the
  SAME slave onto 0/1/2; each inherited copy bumps the refcount via `ondup`. Sockets
  still move (the inetd `dropbear -i` uses one fd).

### POSIX-shaping in the shim (`posix_shim.c`)

- `read()`/`write()` wrappers map the kernel's raw `-errno` returns to `-1` + `errno`
  (`-11` → `EAGAIN`). Dropbear's channel pump checks `errno == EAGAIN` on negative
  returns and treats anything else as a dead fd — a stale errno there kills the session.
  `readv`/`writev` use the wrappers and skip zero-length iovs. (newlib stdio calls
  `_read`/`_write` directly and never uses O_NONBLOCK — unaffected.)
- **Fake-vfork child opens really close**: `close()` in the armed-vfork window of an fd
  the child itself opened (`g_child_opened`) closes it for real — real vfork shares the
  fd table, so child open+close is net zero. Without this every pty session leaked its
  by-name slave open (`pty_make_controlling_tty`) and the slave never reached EOF.

### Dropbear deviations (all out-of-tree, submodule pristine)

- `localoptions.h`: `DEFAULT_PATH` **and** `DEFAULT_ROOT_PATH` =
  `/System/bin:/OS/bin:/bin` (XTOS logins are root; dropbear picks ROOT_PATH for uid 0).
- `build-dropbear.sh` compiles a sed-patched copy of `svr-chansession.c` with
  ptycommand's `channel->bidir_fd = 1` (pre-e28ba1b behaviour): a pty master is one
  bidirectional fd, and with `bidir_fd = 0` a client half-close (`ssh -tt host cmd
  < /dev/null` sends CHANNEL_EOF immediately) `close()`s the master before the shell's
  output is drained. Our `shutdown()` is a no-op, so EOF just marks the write side.

### Known quirks

- The **first connection right after boot** can die with "Timeout before auth": SNTP
  sets the wallclock mid-session and dropbear sees `now - connect_time` exceed the auth
  timeout. Harmless — reconnect. (Fix would be a monotonic time source for dropbear.)
- qemu harness only: keep the guest's stdin open (`sleep`) and expect the guest log to
  flush in bursts.

## Remaining work

1. **HW deploy**: `make hw` + JTAG (everything — kernel, shim and the ssh binaries —
   is baked into the hw romfs). First-time setup on the board:
   `mkdir -p /OS/etc/ssh && ssh-keygen -t ed25519 -f /OS/etc/ssh/ed25519_host_key`,
   put the client's public key in `~/.ssh/authorized_keys` (= `/media/home/.ssh/`),
   then `sshd 22`. Validate the `~/.ssh` default on HW (qemu has no SD, so it always
   uses the `-D` override).
2. **scp/sftp** — untested; scp needs a `scp` applet on PATH, sftp a server binary.
3. **Window-size propagation** — TIOCSWINSZ is stored per-pair but nothing forwards
   SIGWINCH to the shell (no async signals); linenoise re-queries on each prompt.

## Deploy
Server binary builds to a PIC `.so` (like toybox) → **sdpush**; anything needing the kernel
(pty layer, entropy syscall) → **make hw + JTAG**.
