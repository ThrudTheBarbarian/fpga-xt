# Filesystem: a page cache behind an fs service

## Why

Today a PL0 program's file syscalls (`open`/`read`/`write`/`lseek`) run **inline in
the SVC handler**. That works for the console and for in-memory romfs, but it breaks
for the SD card: FatFs/xsdps drive polled transfers that only work in the context
`sd_init` runs in — IRQs enabled, scheduler live. Inline we're in an exception with
IRQs masked, so an SD read from PL0 takes a data abort on real hardware. (qemu has no
SD backend, so it never showed — it only bit on metal, the first time `init` read a
`/OS/Boot` script.)

The stop-gap is `needs_task_ctx()`: a syscall that blocks (waitpid, stdin) or touches
FatFs (open; read/write/lseek/close of a non-in-memory fd; spawn) is deferred to the
calling task via the deferral thunk, where the context is correct. That fixes the
fault, but it leaves two things unsolved:

* **Concurrency.** FatFs is built with `FF_FS_REENTRANT = 0` — no internal locking.
  Deferring to *each caller's own task* means two tasks touching the filesystem at
  once race FatFs's shared window buffer. Fine while access is serial (one shell), a
  corruption waiting to happen the moment a background daemon does I/O.
* **No choke-point.** Caching, permissions, quotas, and multiple filesystems have
  nowhere to live.

Both want the same thing: **one owner of the filesystem**. That's the fs service.

## Shape

Three layers, each a clean idea:

1. **Shared memory (shm)** — the IPC substrate.
2. **The fs service task** — the sole owner of FatFs, behind a request channel.
3. **The page store** — `read`/`write`/`mmap` unified as views over demand-paged,
   write-back file pages. This is where the real design lives.

### 1. Shared memory

We have a full per-process VM (ASID-tagged spaces, per-space L2 windows). Add an
`XTOS_SHM_VA` window and an shm object = `{ pages[], nref, used }`, pages taken from
the DDR page pool via a raw (un-charged) allocation so they belong to the shm, not to
a space.

The key simplification: **the service never maps shm into its own address space.** The
page pool is identity-mapped, and that mapping is global (copied into every space), so
the fs task reaches any shm page by its physical address directly. Only the **client**
maps the pages into its window at a clean PL0 VA. Cortex-A9 L1 D-cache is PIPT and we
run on one core, so the client's window view and the service's identity view are
coherent with no cache maintenance.

Lifecycle is reference-counted, exactly as it should be:

* client mapping = +1, the service's hold = +1;
* a client dropping the mapping, **or exiting** (the `frtos_reap` teardown is the
  crash-safe hook — a faulted client still has its ref dropped), decrements;
* at `nref == 1` (service only) the service frees the pages back to the pool.

This same primitive is what GEM's bespoke "shared param block" should sit on later —
one IPC mechanism for every service.

### 2. The fs service task

A task that owns FatFs outright. Clients post requests to it (a small per-client
**control-channel** shm page: `{ op, path-offset, fd, count, off, result, status }`)
and **park** — the same block/wake primitive the deferred `waitpid` already uses. The
service serves the request and wakes the caller. Because only this one task ever calls
FatFs, `FF_FS_REENTRANT` stays off and there is no race: serialization is structural,
not a lock.

Its entire interface to the storage layer is three page-level operations — see below.

### 3. The page store (the heart of it)

`read`, `write`, and `mmap` are three views over **one** demand-paged, write-back set
of file pages — a page cache. Implemented in the kernel, so the syscalls stay standard
(no libc changes).

* **`read(fd,buf,n)`** — ensure the pages are resident → `memcpy(buf, page+off, n)`.
* **`write(fd,buf,n)`** — ensure the pages are resident *(if the write is partial)* →
  `memcpy(page+off, buf, n)` → mark dirty.
* **`mmap(fd)`** — map those same pages into the client's window. Reads are direct;
  a write-fault marks the page dirty.

The service only ever: **fills a page** (`f_read`), **flushes a dirty page**
(`f_write`), **extends a file** (grow). The separate "write an arbitrary buffer to
disk" path disappears — `write` is just a `memcpy` into a page the service later
flushes.

Two properties fall out for free:

* **Read-modify-write is automatic.** A sub-page `write` first *fills* the page from
  the card (the read step), then overlays the new bytes, so the surrounding bytes are
  preserved with no special code.
* **Caching is inherent.** A second touch of a resident page is a `memcpy`, no SD I/O.
  read, write and mmap all share the resident pages.

Copy count is optimal: `write` is one `memcpy` (client buf → page) plus one eventual
SD write — unavoidable since `buf` is client-private; `mmap`-write skips even the
`memcpy`.

## Permissions and write-back

The map permission follows the open mode:

* **read-only** → pages mapped **RO**; multiple readers can share **one** physical
  copy (as romfs already does).
* **read-write** → pages mapped **RW**; the client modifies in place, the service
  writes dirty pages back to the card by identity.

**Write-back timing:** flush on `close`/`munmap` first; add `msync(addr)` for explicit
flush. (Write-through is too slow — skip.)

**Dirty tracking:** flush-all-on-close is the trivial first cut. The proper version is
**dirty-bit-via-fault** — map RW files clean-but-RO, take a permission fault on the
first store, mark the page dirty and flip it RW, and write back only dirty pages. ARMv7
short descriptors have no HW dirty bit in our config, so fault-based tracking is the
standard trick — and it reuses the *exact* fault machinery already written for COW and
W^X (`vm_cow_map` is 90% of it).

**Sharing for RW: single-writer.** A file opened RW maps into one client; others get RO
or wait. Real concurrent writers to one file (`MAP_SHARED` vs `MAP_PRIVATE`/COW) is a
can of worms we don't need yet.

## Open decisions (staged, not now)

* **File growth / append.** mmap doesn't naturally grow. The store tracks a file's
  *logical* size; a write at/after EOF allocates a fresh page (no SD read needed — it's
  new), bumps the size, marks dirty; flush extends the on-disk file
  (`f_lseek`+`f_write`). Handle in-bounds writes first, append as the explicit case.
* **Eviction.** Pages are pool memory; under pressure, flush+drop by LRU. Defer — cap
  the cache and fail loudly first.
* **Cross-fd/client dedup.** A true cache keys pages by `(file-id, page-index)` so two
  openers share one copy. Start with **per-fd** pages; add keyed dedup later.

## Build order + status (2026-07-01)

Each step is qemu-testable except the SD leaf (qemu has no SD backend — `sd.c` is
`#ifdef XT_HW`; romfs exercises the client side of everything).

1. **shm core — DONE (commit 2084687), qemu-validated.** `vm_shm_create` / `vm_shm_map`
   / `vm_shm_drop_space` in vm.c; `XTOS_SHM_VA` window (0x1300_0000, 16×1 MB id slots,
   id-derived VA -> portable pointers); pool-backed via `dpage_raw`/`dfree_raw`
   (un-charged, owned by the shm); refcount = mappers, freed at 0; reap hook in
   `vm_space_destroy` (crashed mapper still releases). `SYS_shm_create`/`SYS_shm_map`
   (0x203/0x204), `sys_shm_create`/`sys_shm_map` in usys.h. Test `/bin/shmtest`: parent
   create+map+write, child maps same id -> shared read AND write, both directions; id 0
   reused across runs (no leak). Cacheable + single-core PIPT = coherent, no maintenance.

2. **Serialization — DONE (commit a32590c), qemu-validated.** NOT a task — a lock, per
   the concurrency model. Moved from a FatFs-specific mutex up to the VFS layer: `vfs_fs`
   has a `serialized` flag; `vfs.c` has one shared `g_vfs_mtx` that every serialized
   (backing-store) driver takes, so fatfs + future minixfs/swap on the same SD serialize
   TOGETHER. romfs (reentrant, RO) = serialized 0, lock-free inline. New
   `vfs_read`/`vfs_lseek`/`vfs_close` wrappers lock per-driver; `sys_*` route through
   them; serialized-fd ops are always deferred off the SVC handler so the mutex is only
   taken in task context.

3. **page store — IN PROGRESS.** The dedicated `fs` TASK + shm control channel, and
   read/write/mmap unified over demand-paged write-back pages (this section, above). The
   task earns its keep here (owns cached pages: fill / flush / extend). Three sub-steps:

   * **(a) fs task + request channel — DONE, qemu-validated.** An `fs` FreeRTOS task
     (`fs_task`, priority 4) owns the VFS metadata path, behind a skeleton request
     channel: a kernel queue of `fs_req*` + a per-call task-notification wake. A client
     builds the `fs_req` on its OWN stack (it stays parked, so the frame is live), posts
     to `g_fs_q`, and blocks; the task serves with the client's proc as the *explicit*
     context (not `cur_proc`, which is the task itself) and notifies it. `frtos_fs_start`
     (from `main`, pre-scheduler) stands it up. The deferral thunk routes **open / lseek
     / close** here — metadata ops with NO client data buffer, so the task (in the
     master space) never touches a client PL0 VA. `read` (SD) STAYS in the caller's
     deferral thunk, where the user buffer VA is mapped, under `g_vfs_mtx`. On qemu every
     romfs `open` (already unconditionally deferred — the path's fs isn't known until it
     resolves) exercises the channel: `libc_test` fopen, `mmaptest`, boot-script reads.
   * **(b) shm control channel — NEXT.** Replace the kernel-queue transport with the
     per-client shm page `{op,path-off,fd,count,off,result,status}` from §1, so a client
     posts + parks over shm rather than a kernel struct pointer.
   * **(c) read/write/mmap over the page store.** Route the *data* path to the service:
     demand-paged write-back file pages (fill / flush / extend). This is what lets the
     data-carrying ops leave the caller's space — and lets the interim `g_vfs_mtx` retire
     once one task owns the whole FatFs path. Test on qemu against **romfs** (protocol +
     serialization); SD is the HW-only leaf. Single-writer; growth explicit.

Later: dirty-via-fault (reuse `vm_cow_map`), eviction (LRU), `(file,page)` dedup, and
moving GEM's param block onto the shm primitive.
