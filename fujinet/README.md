# fujinet — TNFS client library + shell

First layer of the "network as a folder" feature: a portable **TNFS**
(Trivial Network File System — the FujiNet ecosystem's file-server
protocol) client, packaged as a shared library, plus an interactive
shell for exercising it from a Mac.

```
include/fujinet/tnfs.h   public API
src/tnfs.c               protocol core — transport-agnostic, no OS deps
src/tnfs_udp_posix.c     BSD-socket UDP transport (macOS / Linux hosts)
src/tnfs_tcp_posix.c     BSD-socket TCP transport (for TCP-only servers)
src/tnfs_connect.c       transport-policy connect (udp / tcp / auto-fallback)
shell/tnfsh.c            interactive shell (links libfujinet)
daemon/fujinetd.c        the FujiNet daemon (loopback control port 16385)
cli/fuji.c               fuji — CLI client of the daemon
```

## Build & run (host)

```sh
make                     # build/libfujinet.dylib (.so on Linux) + build/tnfsh
./build/tnfsh tnfs.fujinet.online
tnfs://tnfs.fujinet.online/> ls
tnfs://tnfs.fujinet.online/> cd Atari
tnfs://tnfs.fujinet.online/Atari> get GAME.XEX
```

Shell commands: `open [udp://|tcp://]host[:port] [mountpath]`, `close`,
`ls`, `cd`, `pwd`, `get`, `put`, `cat`, `stat`, `df`, `mkdir`, `rmdir`,
`rm`, `mv`, `help`, `quit`. With no scheme, `open` probes UDP first and
falls back to TCP — several public servers (e.g. `apps.irata.online`)
are TCP-only.

## Design

The core (`src/tnfs.c`) speaks the wire protocol only; all I/O goes
through a `tnfs_transport` — three function pointers (datagram `send`,
timed `recv`, `close`). Retry/backoff, sequence matching, stale-datagram
rejection, and EAGAIN handling live in the core, so every transport gets
them for free.

Sessions are self-contained (no library globals) — hold as many
concurrent mounts as you like, one command in flight per session.
`tnfs_download`/`tnfs_upload` are whole-file helpers that own the chunk
loop and report through a `tnfs_progress_cb` (return nonzero to cancel
— that's the hook for a UI progress bar / cancel button).
`tnfs_connect` applies transport policy: `TNFS_T_UDP`/`TNFS_T_TCP`
force one, `TNFS_T_AUTO` probes UDP and falls back to TCP (ids match
the registry's `fujiTransport` rows).

## fujinetd

`fujinetd [port] [logfile] [registry.db]` (default 16385) is the daemon
the desktop talks to: a loopback TCP control port speaking a line
protocol — `ping`, `servers`, `ls <server> <path>`, `stat <server>
<path>`, `df <server>`, `get <server> <remote> <local>` (emits
`+progress <done> <total>` events; downloads via `.part` + rename so a
kill mid-fetch never leaves a half-file that looks cached). It keeps a
small pool of live sessions so repeated requests reuse mounts.
Kill/restart any time — sessions are disposable.

`<server>` resolves against the registry's `fujinet` table (numeric id,
displayName, or host — the row supplies port + transport), falling back
to a literal `[udp://|tcp://]host[:port]`. The registry is found at
`/OS/var/registry.db` (SD), `/test/Registry.db` (qemu romfs), or the
explicit argv path; without one, `servers`/name-resolution are simply
unavailable.

**`fuji`** is the CLI client: `fuji ping | servers | ls <server> [path]
| stat <server> <path> | df <server> | fetch <server> <remote> [local]`.
Raw access works too: `printf 'ping\nquit\n' | nc 127.0.0.1 16385`.

On XTOS both live on the SD (`/OS/bin/fujinetd`, `/OS/bin/fuji`); the
daemon is started by the boot script `sd/boot/40-FujiNet` →
`/OS/boot/40-FujiNet` — edit or remove that file on the card to
reconfigure/disable; no rebuild needed.

Porting to XTOS = supplying a transport built on the `net_shim` BSD
socket API (the POSIX one here should compile nearly unchanged) and
building `src/tnfs.c` as a PIC `.so` with the `loader/` toolchain, like
the other userland libraries. The intended consumer there is a
`vfs_tnfs` VFS backend mounting servers under `/Network`, per the
desktop/FujiNet design discussion.

## Protocol notes

Implemented per `tnfs-protocol.md` (Spectranet/FujiNet): port 16384,
4-byte header (session id LE16, sequence, command), status byte leading
every reply. Commands covered: MOUNT/UMOUNT, OPENDIR/READDIR/CLOSEDIR,
MKDIR/RMDIR, OPEN(0x29)/READ/WRITE/CLOSE/LSEEK, STAT, UNLINK, RENAME,
CHMOD, SIZE/FREE. Not yet: the OPENDIRX/READDIRX batched-listing
extensions (worth adding for snappier `ls` on big directories).

Retry semantics: a command is retried with the **same** sequence number
so the server can dedupe (tnfsd dedupes identically on both transports);
replies with a mismatched sequence/command/session are discarded; EAGAIN
replies are honoured with the server's suggested delay. Reads/writes are
capped at 512 bytes per message.

TCP: tnfsd does no stream framing (one send() per message), but replies
can still arrive split, so the core reassembles messages itself when
`transport.stream` is set, using per-command reply lengths. Reality
check baked in: STAT replies are a fixed 22 payload bytes — the spec's
trailing uid/gid strings are never sent by any deployed tnfsd (verified
against source and a live protocol-1.3 server).

## Testing

`tools/mock_tnfsd.py` is a minimal Python tnfsd (serves a local
directory over the same wire format, with an optional packet-drop mode
to exercise the retry path):

```sh
python3 tools/mock_tnfsd.py /path/to/serve 16384 &
./build/tnfsh 127.0.0.1
```

Public servers for real-world testing: `tnfs.fujinet.online`,
`atari-apps.irata.online`.
