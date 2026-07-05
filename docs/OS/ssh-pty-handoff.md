# SSH interactive-shell (pty) — debugging handoff

**One bug stands between XTOS and a working `ssh root@xtos` interactive login.** Everything
else works: connect → KEX → pubkey auth → **run a command** → output returned. This doc is a
complete, self-contained brief to finish the last mile: dropbear's I/O pump over the pty
hangs — the login shell spawns and runs, but its output never flows back to the client.

Work lives on branch **`ssh-server`** in worktree **`/Users/simon/src/fpga-xt-ssh`**. Read
`docs/OS/ssh-server.md` for the full port story; `~/.claude/.../memory/ssh_server_port.md`
has the running notes.

---

## TL;DR of the bug

`ssh -tt root@xtos 'echo HI'` (force a pty) produces **no output anywhere** — not to the SSH
client, not to the guest console. Verified facts:
- Auth succeeds (`Pubkey auth succeeded for 'root'`).
- dropbear allocates the pty (BSD `/dev/ptyp0` scan) and sets up the controlling tty
  (logs the benign `Failed to disconnect from controlling tty` — our `/dev/tty` always opens).
- **The shell IS spawned** — a temporary probe in `frtos_spawn_argv_fds` printed
  `[spawn] /System/bin/sh`. So exec works.
- Then dropbear (the parent) hangs: no shell output reaches the client, and the client
  eventually times out (`Exit ... Disconnect received`).
- **The non-pty path works fine**: `ssh root@xtos 'echo HI'` (no `-tt`) prints `HI`. That
  path uses the *same* `spawn_command`+vfork but a *simple* exec child (pipes, no pty).

So the failure is specific to the **pty I/O pump** and/or the **complex pty vfork child**.

---

## What works (don't re-verify unless needed)

- Full SSH transport + RSA pubkey auth + non-interactive command exec. Commits up to
  `ed28d45` on `ssh-server`.
- The pty subsystem is BUILT and the session establishes + the shell spawns. Commits
  `12d9a53`, `de4c33f`.

---

## Reproduce (exact — the harness is finicky)

Build (kernel only — the pty is kernel-side; dropbear is unchanged):
```
cd /Users/simon/src/fpga-xt-ssh/loader
rm -f build/freertos.elf build/romfs.bin
make build/freertos.elf          # ~a few min
```
First-time-only prerequisites in this worktree:
```
ln -sfn /Users/simon/src/fpga-xt/loader/newlib-pic newlib-pic   # gitignored prebuilt libc
git submodule update --init third_party/dropbear                # if missing
# A test authorized_keys (personal key; gitignored via romfs-overlay):
mkdir -p romfs-overlay/etc/dropbear && cp ~/.ssh/id_rsa.pub romfs-overlay/etc/dropbear/authorized_keys
```
Run the server under qemu + connect from the host. **KEY GOTCHAS:**
- qemu user-net + `hostfwd` gives host:2222 → guest:22.
- **Keep the guest stdin open with `sleep`** or the guest console stops flushing to the log
  (plain background qemu buffers stdout → empty log; `script -q` is racy). This is the
  reliable pattern:
```
pkill -f 'qemu-system-arm.*freertos'; sleep 1; rm -f /tmp/g.txt
( bash -c "( printf 'dropbearkey -t ed25519 -f /tmp/hk >/dev/null 2>&1\nsshd 22 /tmp/hk /System/etc/dropbear\n'; sleep 120 ) | \
  qemu-system-arm -M xilinx-zynq-a9 -display none -no-reboot -m 1024 \
  -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
  -kernel build/freertos.elf -nic user,hostfwd=tcp::2222-:22 > /tmp/g.txt 2>&1" ) &
# wait for boot:
for i in $(seq 1 20); do sleep 2; grep -qa 'listening for ssh' /tmp/g.txt && break; done
# connect (force a pty with -tt):
timeout 15 ssh -tt -p 2222 -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=publickey \
  -o IdentitiesOnly=yes root@127.0.0.1 'echo PTY_MARK; id' 2>&1 | cat -v
# guest-side log (dropbear messages, [spawn] probes, etc.):
sed -n '/Child connection/,$p' /tmp/g.txt | tr -d '\r'
pkill -f 'qemu-system-arm.*freertos'
```
Expected today: auth succeeds, `Failed to disconnect from controlling tty`, **no `PTY_MARK`
anywhere**, then a timeout/disconnect. The working non-pty case is the same but drop `-tt`
and the command prints normally.

To turn on dropbear's own tracing: add `#define DEBUG_TRACE 1` to
`loader/dropbear-config/localoptions.h`, add a `-v` arg in `loader/test/freertos/progs/sshd.c`
(the `dropbear -i` argv), then `tools/build-dropbear.sh && make build/freertos.elf`. NB: only
`TRACE1` prints at `-v`; you may need multiple `-v` for full `TRACE()`.

---

## The pty architecture (what I built)

Dropbear's `sshpty.c` finds no configured pty method (HAVE_OPENPTY / USE_DEV_PTMX /
HAVE_DEV_PTS_AND_PTC all undef in `build/dropbear/config.h`), so it falls back to scanning
BSD-style pairs `/dev/pty[p-z][0-9a-f]` (master) + `/dev/tty..` (slave). I provide 4 pairs:
`/dev/ptyp[0-3]` + `/dev/ttyp[0-3]`.

- **Core** — `loader/test/freertos/frtos_os.c`, `xt_pty_*` (search "pseudoterminals (pty)").
  Each pair = two FreeRTOS StreamBuffers: `m2s` (master→slave, i.e. dropbear→shell keystrokes)
  and `s2m` (slave→master, i.e. shell output→dropbear). PASS-THROUGH (no kernel line
  discipline; the shell's linenoise sets raw mode + echoes itself). `mopen`/`sopen` are
  refcounts, not flags (an SSH pty child dup2's the slave onto 0/1/2 and dropbear closes its
  own slave copy, so the slave "closes" only when all holders close). `xt_pty_read` honors a
  nonblock flag (returns `-11` = -EAGAIN when empty). `xt_pty_nread` = bytes available (for
  poll). ioctls: XT_TTY_GETMODE/SETMODE, TIOCSWINSZ/TIOCGWINSZ, TIOCSCTTY (no-op).
- **Device nodes** — `loader/test/freertos/vfs_devfs.c` (search "pseudoterminals"). Thin
  routers: `dv_ptym_rd/wr` (master), `dv_ptys_rd/wr` (slave), `dv_pty_ioctl` (handles
  XT_TTY_NREAD via `xt_pty_nread`, else forwards), `dv_pty_close`/`dv_pty_dup`. `f->priv`
  packs pair-index (low byte) + slave flag (0x100). `dv_open` sets `f->close`, `f->ondup`,
  `f->nonblock`, and calls `xt_pty_open`.
- **`vfs_file` gained `ondup` + `nonblock`** — `loader/test/freertos/vfs.h`.
- **`spawn_fd` copies (not moves) a char-device stdio fd** — `frtos_os.c`, search
  "char device (pty slave". A pty child dup2's the SAME slave onto 0/1/2, so several child
  slots must reference it (moving would leave 1/2 as console fallback → output escapes the
  pty). Each inherited copy calls `vf.ondup` (`dv_pty_dup`) to bump the pty refcount. Sockets
  still MOVE (the inetd `dropbear -i` uses one fd; copying would triple-close the netconn).

Data flow for an interactive session:
```
client --socket--> dropbear -i (fd0) --write master--> m2s --slave read--> shell (fd0)
client <--socket-- dropbear -i (fd0) <--read master--- s2m <--slave write-- shell (fd1)
```
`dropbear -i` (the per-connection process, spawned by `/bin/sshd`) opens the pty MASTER; the
login shell (spawned by dropbear via `spawn_command`+vfork+`execchild`) gets the SLAVE on
fd 0/1/2.

---

## Suspects, in priority order

### 1. `-EAGAIN` errno mapping (check first — cheap)
dropbear sets its pty master `O_NONBLOCK` (`setnonblocking(ptyfd)`), and its channel loop
reads it. `xt_pty_read` now returns `-11` when empty+nonblock. **But does the libc glue map a
`-11` syscall return to `read() == -1, errno == EAGAIN`?** If not, dropbear's channel code
(`common-channel.c`, look for `read(...)` + `errno == EAGAIN`/`EWOULDBLOCK`) sees a `<0`
return with a non-EAGAIN errno and treats it as a hard error (or mishandles it). Check the
`_read` return→errno mapping (kernel returns `-errno`; find where libc/newlib turns that into
`-1`+errno for read specifically). Note: the pipe case worked only because dropbear's
signal-pipe drain is `while(read()>0)` — it doesn't care about errno, so it never proved the
mapping.

### 2. Complex pty vfork child vs snapshot-vfork
XTOS has no fork; the shim's `vfork()` is a register/sp/lr snapshot (`posix_shim.c`, search
"vfork") designed for toybox's XVFORK pattern: `vfork → a couple dup2 → exec`. The *non-pty*
exec child is that simple and WORKS. The *pty* child (`svr-chansession.c execchild` →
`sshpty.c pty_make_controlling_tty`) does much more before exec: `setsid()` (our no-op,
returns getpid — fine), `open("/dev/tty")` ×2 + `ioctl(TIOCNOTTY)` + `ioctl(TIOCSCTTY, slave)`
+ `close()` (no-ops in vfork) + `dup2(slave→0/1/2)` + `close(slave)`. The exec itself
succeeds (`[spawn] /System/bin/sh` printed), so the theory is the **parent's resume** after
the snapshot is left in a bad state by all that child activity, so dropbear doesn't pump.
Test: instrument the parent right after `spawn_command` returns (does it reach the session
loop? are `chansess->master` and the channel fds sane?). If this is it, options: make the
snapshot-vfork robust to a heavier child, or spawn the pty shell via a dedicated path
(`SYS_spawn` with the slave fds prepared) instead of dropbear's vfork+execchild.

### 3. The pump / poll itself
Confirm data actually reaches `s2m`: does the shell's `echo` land in the slave's buffer, and
does `xt_pty_nread(master)` report it? Does dropbear's `select` (our `select`-over-`poll` in
`dropbear_glue.c`) report the master readable? `k_fstat` returns `XT_S_IFCHR` for the master
(good — `poll_probe` then uses `XT_TTY_NREAD` → `xt_pty_nread`). If the master's poll never
fires, dropbear never reads.

---

## Recommended first move: trace the pty I/O live

Add temporary `g_console(...)` prints inside `xt_pty_read` / `xt_pty_write` / `xt_pty_nread`
(frtos_os.c) logging `{idx, master, n, got/sent, mopen, sopen}` on each call, rebuild the
kernel, run one `ssh -tt ... 'echo HI'`, and read the guest log. That immediately shows:
- whether the shell writes `HI` to `s2m` (→ `xt_pty_write(slave)` called with the bytes),
- whether dropbear ever reads the master (`xt_pty_read(master)` called) or polls it
  (`xt_pty_nread(master)`),
- whether either side is stuck.
That single trace collapses suspects 1–3 to the real one. (Use `g_console` — it writes
straight to the console, unlike `klog` which goes through the fs task.)

---

## Files touched (all on `ssh-server`)
- `loader/test/freertos/frtos_os.c` — pty core (`xt_pty_*`), FIONBIO/`fd_t.nonblock`,
  `spawn_fd` char-copy + `ondup` call.
- `loader/test/freertos/vfs_devfs.c` — pty device nodes + routers.
- `loader/test/freertos/vfs.h` — `vfs_file.ondup`, `.nonblock`.
- `loader/test/freertos/progs/sshd.c` — the inetd launcher (binds :22, spawns `dropbear -i`
  with the socket as stdio, `-D` authkeys dir).
- `loader/dropbear-config/localoptions.h` — `DROPBEAR_VFORK` (via stripping HAVE_FORK in
  `tools/build-dropbear.sh`), `COMPAT_USER_SHELLS`, server/pubkey config.
- `loader/tools/build-dropbear.sh` — out-of-tree Dropbear build; strips `HAVE_FORK`.

## Deploy note (for later, on real hardware)
kernel changes (pty, spawn_fd, O_NONBLOCK) → `make -C loader hw` + JTAG; `toybox.so`/shim →
`make sdpush`; dropbear/sshd `.so` → SD. authorized_keys + host key live on the SD at
`/OS/etc/dropbear/` on HW (baked into the romfs-overlay only for the qemu test).
