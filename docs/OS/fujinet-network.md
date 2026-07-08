# FujiNet: the network as a folder

> **Layer 1 (libfujinet) built and verified; the rest is proposed design.**
> How XTOS presents FujiNet/TNFS file servers as ordinary folders on the
> desktop: a Network icon opens a window of known servers, a server browses
> like a local disk, and double-clicking an XEX/ATR launches it via the
> [app-launch](app-launch.md) flow.

## UX model

- The desktop has a **Network** icon. Double-click → a folder window listing
  the known servers (plus **Add Server…**; delete is icon-level).
- Opening a server browses it exactly like a local hard-disk window — same
  folder windows, same `windowIcons` glob→icon rules (`*.xex`, `*.atr` →
  `ICT_MEDIA_8BIT`).
- Double-clicking an XEX/ATR runs it: fetch, then hand off to the launcher.
  The 6502 never knows the network exists — it is served a local disk.

The whole feature terminates on the **A9**. The STM32 [SIO
bridge](sio-bridge.md) is where a classic FujiNet-over-SIO peripheral would
live, but nothing here depends on it.

## Why TNFS

TNFS is the FujiNet ecosystem's file-server protocol: trivial wire format
(4-byte header + status-first replies), a public server ecosystem already
hosting the 8-bit software libraries (`tnfs.fujinet.online`,
`apps.irata.online`, …), and a near-1:1 mapping onto VFS operations
(OPENDIR/READDIR, OPEN/READ/WRITE/SEEK/CLOSE, STAT). Spec:
`tnfs-protocol.md` in the Spectranet/FujiNet repos; server: `tnfsd`.

## Layers

### 1. libfujinet — portable TNFS client  ✅ built

`fujinet/` at the repo root (see `fujinet/README.md` for API and build):

- **Core** (`src/tnfs.c`): protocol only, no OS deps. All I/O goes through a
  `tnfs_transport` (datagram `send`, timed `recv`, `close`, `stream` flag).
  Retry-with-same-sequence (the server dedupes), stale-reply rejection,
  EAGAIN back-off, and stream reassembly live in the core, so every
  transport inherits them.
- **Transports**: POSIX UDP and TCP (`src/tnfs_{udp,tcp}_posix.c`). UDP is
  the spec's mandatory transport; **several public servers are TCP-only**
  (e.g. `apps.irata.online`), and TCP also survives NATs that eat UDP.
  On TCP the core frames replies itself from per-command lengths — tnfsd
  writes one `send()` per message but segments still split.
- **Transfers**: `tnfs_download`/`tnfs_upload` own the chunk loop and report
  through a progress callback (`done`, `total`); a nonzero return cancels —
  the hook for a GEM progress dialog's cancel button.
- Sessions are self-contained (no globals): one concurrent session per
  mounted server, many files/dirs open per session, one command in flight
  per session (protocol rule).
- **`tnfsh`**: interactive host shell (`open`/`ls`/`cd`/`get`/`put`/…) with
  UDP→TCP auto-fallback. Doubles as the reference client and soak-tester.

Spec-vs-reality notes (verified against tnfsd source + live servers, baked
into the implementation):

- STAT replies are a **fixed 22 payload bytes** — the spec's trailing
  uid/gid strings are never sent by any deployed tnfsd.
- Reads/writes cap at 512 bytes/message → WAN throughput is ~1 RTT per
  512 B (~4–6 KB/s observed). Fine for browsing; launches use a
  copy-through cache (below). READDIRX batching and read pipelining are the
  upgrades if this starts to hurt.

Verified: mock server (`fujinet/tools/mock_tnfsd.py`, UDP+TCP, lossy mode
for the retry path) and live — `tnfs.fujinet.online` (UDP, proto 1.2) and
`apps.irata.online` (TCP-only, proto 1.3), downloads bit-exact.

### 1b. fujinetd — the daemon  ✅ built

`fujinetd [port] [logfile] [registry.db]` (`fujinet/daemon/fujinetd.c` —
portable, host-testable): a loopback TCP control port (default 16385)
speaking a line protocol (`ping` / `servers` / `ls` / `stat` / `df` /
`get` with `+progress` events and `.part`+rename atomic downloads),
holding a small pool of live server sessions so repeated requests reuse
mounts. `<server>` arguments resolve against the registry's `fujinet`
table (id / displayName / host → row's port + transport) with literal
`host[:port]` fallback — the daemon owns registry access (and will own
`fujiCache` updates). Kill/restart is always safe. Lives on the **SD**
(`/OS/bin/fujinetd`), enabled by the SD boot script `/OS/boot/40-FujiNet`
(source: `loader/sd/boot/40-FujiNet`) — user-editable, no rebuild to
disable. **`fuji`** (`fujinet/cli/fuji.c`, `/OS/bin/fuji`) is the CLI
client: `fuji servers`, `fuji ls Irata /`, `fuji fetch 1 /path/game.xex`;
the desktop's netcache layer drives the same protocol.

### 2. `vfs_tnfs` — mount the network at `/Network`  ⬜ proposed

A VFS backend alongside `vfs_fatfs` etc. (`loader/test/freertos/vfs.c` is
the extension point). The XTOS port of libfujinet is the core built as a
PIC `.so` with a transport on the `net_shim` BSD sockets (the POSIX one
should port nearly unchanged).

- `/Network` root is synthetic: one directory entry per configured server.
- Descending into `/Network/<server>/…` lazily mounts a session (LRU-cap
  live sessions; a dead server's entries error, they don't hang — every op
  carries the core's timeout).
- Read-only in v1 (TNFS supports writes; nothing needs them yet).
- Server list persists in the desktop's SQLite **registry**: the
  `fujinet` table `{id, displayName, host, port (16384), transport,
  path ('/')}` with `transport` a foreign key into the `fujiTransport`
  lookup (`udp` / `tcp` / `auto`, default auto — probe UDP, fall back to
  TCP, as `tnfsh` does). `path` is the TNFS mount point requested from
  that server.

### 3. netcache — cache-authoritative downloads  ⬜ proposed

TNFS is slow (~1 RTT per 512 B), so the network is for *browsing and
fetching*, never for launching. Fetched files live in **`/Cache`**, a
plain directory at the top level of the SD (a peer to `OS`) — invisible by
construction, since nothing at `/` shows unless explicitly registered.

- **Mirror layout**: `/Network/<server>/path/to/file` caches as
  `/Cache/<server-id>/path/to/file`, keyed by the `fujinet` row id —
  stable across display-name and even host edits (a `host_port` dir name
  is the human-readable alternative if the SD being legible in another
  machine matters more).
- **State lives in the registry**: netcache is a thin wrapper around a
  `fujiCache` table — `{id, server → fujinet.id, remotePath, state →
  fujiCacheState, size, remoteMtime, fetchedAt}` with a `fujiCacheState`
  lookup (`fetching` / `cached` / `updateAvailable`), matching the
  transport-lookup idiom. No row = uncached. Lifecycle: `fetching` while
  the `.part` transfer runs; → `cached` when the rename lands (on disk,
  ready — what fetch-then-launch waits on, and the icon's cue to
  solidify); an explicit refresh that finds newer upstream flips it to
  `updateAvailable`. Boot-time reconcile purges `fetching` orphans and
  their partials.
- **Atomicity**: download to `file.part`, rename into place on completion;
  cancel/crash never leaves something that looks cached.
- **The cache is authoritative.** Once fetched, a file always launches
  from `/Cache` — no network touch, no auto-refetch. "Cached" pins that
  exact version (the user might want v1.5, not v1.6). Refresh is explicit:
  a context-menu Sync/Refresh re-STATs (size/mtime vs the table) and
  badges the icon `UPDATE_AVAILABLE`; an optional background checker may
  *mark*, but never fetches. "Update" re-downloads on request.
- **Unified view**: a folder window merges the live server listing with
  the cache rows under that prefix — cached entries draw solid (normal
  icon, black label), uncached ones ghosted (dimmed icon, grey label),
  fetching ones show the progress fill. Offline or with the server down,
  the same query degrades to cache-rows-only: you browse and launch what
  you have.
- **Trigger semantics**: double-click on a ghost = fetch-then-launch as
  one gesture (icon solidifies as the bar fills); double-click on a solid
  = instant local launch. Context menu: Download (prefetch), Remove from
  cache, Refresh.
- **Eviction**: none in v1 — a Flush action plus a cache-size readout.
  LRU later, using the table's `fetched_at`/last-launch bookkeeping.

### 4. Desktop integration  ⬜ proposed (mostly registry entries)

- The **Fujinet desktop icon already exists** (`desktopIcons` row,
  `devices/network-nfs.pam`); double-click opens the servers window.
- Files/folders inside a server window use the **same `windowIcons` glob
  mapping as normal SD browsing** — network-ness shows only as draw
  state: ghosts (uncached) render at reduced alpha with a grey label,
  cached entries draw normally.
- **Server / Add Server icons exist**: `iconTypes` 9 (`Server`,
  `actions/document-open-remote.pam` — label = the server's
  displayName) and 10 (`Add Server`, `actions/folder-new-7.pam` — the
  action icon opening the Add Server… dialog that writes the `fujinet`
  row), each with a `windowIcons` mapping so client code fetches them by
  type. Later: mDNS/broadcast discovery pre-filling candidates.

### 4. Launch  ⬜ proposed (depends on [app-launch](app-launch.md))

Double-click on `*.xex`/`*.atr` invokes the launcher with a VFS path, so
local and network files take the identical path. Network-specific policy:
**copy-through cache** — download to ramfs/SD first (GEM progress dialog
with cancel, wired to the transfer callback), then serve the local copy to
the 6502. Live SIO sector reads must never stall on WAN round-trips.
Streaming through the [page cache](fs-pagecache.md) is a later upgrade.

## Build order

1. ~~libfujinet + tnfsh, validated against mock + live servers~~ ✅
2. XTOS port: net_shim transport + `vfs_tnfs` + `/Network` + registry
   server table.
3. Desktop: Network/Server icon types, Add/Delete UI.
4. Launcher integration (the long pole — app-launch itself is unbuilt and
   is needed with or without networking; keeping it VFS-path-based makes
   network launch free).
5. Later: discovery, write support, READDIRX/pipelining, exposing mounts to
   the 6502 as directory-mapped drives ([xtos-vision](xtos-vision.md),
   "FujiNet-as-sockets").
