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

3. **page store — DONE (a, b, c-1..c-4), qemu-validated.** The dedicated `fs` TASK + shm
   control channel, and read/write/mmap unified over demand-paged write-back pages (this
   section, above). The task owns the cached pages (fill / flush / extend) and is now the
   SOLE FatFs driver — the interim `g_vfs_mtx` retired. Sub-steps:

   * **(a) fs task — DONE, qemu-validated.** An `fs` FreeRTOS task (`fs_task`, priority
     4) owns the VFS metadata path. `frtos_fs_start` (from `main`, pre-scheduler) stands
     it up. The deferral thunk routes **open / lseek / close** to it — metadata ops with
     NO client data buffer, so the task (in the kernel's master space) never touches a
     client PL0 VA. It serves with the client's proc as the *explicit* context (not
     `cur_proc`, which is the task itself). `read` (SD) STAYS in the caller's deferral
     thunk, where the user buffer VA is mapped, under `g_vfs_mtx`. On qemu every romfs
     `open` (already unconditionally deferred — the path's fs isn't known until it
     resolves) exercises the path: `libc_test` fopen, `mmaptest`, boot-script reads.
   * **(b) shm control channel — DONE, qemu-validated.** The request travels over the §1
     shm primitive: one control page per proc SLOT (`fs_ctl` = `{op, fd, off, whence,
     result, path[256]}`), allocated once at `frtos_fs_start` via `vm_shm_create` and kept
     for the system's life (no per-request alloc/free → leak-free without an unmapped-shm
     free path). The client's deferral thunk (PL1, in the CLIENT's space) marshals the
     request in — **copying the path string** out of client memory — then rings the
     doorbell (a kernel queue carrying just the slot index) and parks on a task
     notification; the fs task reaches the page by its pool IDENTITY address (new
     `vm_shm_kaddr`, no map) and serves from the copy. This closes a latent 3(a) hole: a
     path in a **malloc'd (per-process-heap) buffer** was read by the fs task as
     master-space identity — wrong physical, silently. `libc_test` now opens a heap-path
     (VA `0x10…`) to prove it. The control page is PL1-identity-only for now (not
     PL0-mapped; mapping it PL0 is the later syscall-less-IPC path). Cost: 8 of 16 `NSHM`
     ids reserved for control pages (`shmtest` lands on id 8+; it uses a dynamic id, so
     unaffected).
   * **(c-1) read over the page store — DONE, qemu-validated.** Each fd gets a logical
     read cursor (`fd.pos`) and a single-page cache window (`cpi`+`cpage`); `read` becomes
     a page loop in the client's deferral thunk (in the CLIENT's space, where `buf` is
     mapped) — one `memcpy` per page straight from the resident page to the user buffer. An
     in-memory (romfs) fd resolves the page to `vf.data+base` inline (no fs-task hop, no
     pool page); an SD fd calls the fs task (`FS_OP_GETPAGE`), which fills one pooled cache
     page via the backing driver (`vfs_read`) and returns its identity address — a re-touch
     of the same page is a hit, else refill. `lseek` collapses to inline arithmetic on
     `fd.pos`+size (no I/O, no fs task). Cache pages freed on close/reap (`vm_page_alloc`/
     `vm_page_free`). Validated on romfs: `libc_test` streams a 106 KB font in 1000-byte
     chunks straddling 4 KB boundaries (26 pages, exact byte count) and `read()`==`mmap`
     bytes; the SD fill is the HW-only leaf. **`g_vfs_mtx` does NOT retire yet** —
     `open_lib_sd` / `sd_listdir` are still non-fs-task FatFs callers; the fs task's fills
     take the lock alongside them. Lock retirement waits on migrating those (c-4).
   * **(c-2) write + write-back — DONE, qemu-validated.** The VFS `open` gained a flags
     arg (`VFS_O_*`) and a `write` op; `fatfs` maps flags → `FA_*` (+ `ff_wr` = `f_write`),
     `romfs` rejects write intent. `write` is a page loop in the client's deferral thunk
     (client space, `buf` mapped): `fs_getpage(forwrite)` makes the page resident (RMW for
     an existing page, a fresh zero page past EOF for growth), `memcpy`s buf → page, marks
     the fd dirty; the fs task flushes a dirty page on eviction (single-page window) and on
     `close`, and growth bumps the logical size. `lseek` past EOF is allowed for grow.
     Since qemu has no writable backend (romfs RO, SD HW-only), a small **ramfs** (`/tmp`,
     files = pool-page lists) is the writable backing — a real backing-store driver, so
     writes exercise the *same* fill/flush path SD will (minus the `f_write` leaf).
     Validated: `libc_test` writes a 10 000-byte (3-page) pattern to `/tmp/scratch`, closes,
     reopens, reads it back byte-for-byte (flush-on-evict at each boundary + flush-on-close).
     Single-writer; per-fd cache pages freed (and flushed) on close/reap.
   * **(c-3a) RO mmap over backing-store files — DONE, qemu-validated.** `mmap` of an
     SD/ramfs file (`vf.data == NULL`) is **eager**, not demand: the fs task
     (`FS_OP_MMAP`) fills each page of the region into a fresh pool page via the backing
     driver, then `vm_mmap_install` maps them RO+XN into the client's window at a fresh
     bump VA. Eager because the **abort handler can't drive FatFs** (mmap-fault must be
     synchronous) — so pages are resident before first touch; it also makes
     close-after-mmap safe. The pages are OWNED by the mapping: `vm_munmap` and
     `vm_space_destroy` (reap) free them (they're raw/uncharged pool pages).
     `vm_mmap_fault` skips owned ranges (nothing to demand-fill). romfs mmap is unchanged
     (inline, shared physical, demand-paged). Validated: `mmaptest` writes a 9 000-byte
     file to `/tmp`, mmaps it RO, and reads it back through the mapping byte-for-byte
     (repeatable, no page leak); the SD fill is the HW-only leaf.
   * **(c-3b) RW mmap + dirty-via-fault — DONE, qemu-validated.** mmap of a *writable* fd
     (`vf.write != NULL`) is a writable mapping, but still installed **clean-but-RO**: the
     first store to a page faults, and `vm_mmap_write_fault` (in the abort handler —
     synchronous, just an L2 flip + a bit) flips it RW and sets a per-page dirty bit
     (ARMv7 short descriptors have no HW dirty bit here). `munmap` is deferred to the fs
     task, which writes back **only the dirty pages** through the backing fd
     (`vm_mmap_dirty_plan` returns the pool page + file offset for each), a partial last
     page clamped to EOF, then `vm_munmap` frees. The mmap descriptor became a struct
     (`va/end/src/owned/writable/fd/foff/dirty`). Validated: `mmaptest` maps `/tmp/rw`
     writable, stores into two pages, munmaps, reopens and confirms the writes persisted
     **and** untouched bytes survived. Limitation (first cut): write-back happens at
     `munmap` via the still-open fd — close-before-munmap of a writable mapping drops
     unflushed writes (a later version holds an independent file ref). SD is the HW leaf.
   * **(c-4) retire `g_vfs_mtx` — DONE, qemu-validated.** The two remaining non-fs-task
     FatFs callers now route through the service too, so it is the SOLE FatFs driver and
     the interim lock is gone. They're KERNEL callers (no proc slot -> no per-slot control
     page), so they use a small **kernel mailbox** (one request, serialized among kernel
     callers by `g_kfs_mtx` — the path is rare: a lib missing from the romfs, or the boot
     dir listing) posted to the fs task via a `FS_KERNEL_JOB` doorbell: `KFS_READFILE`
     (open+alloc+read a whole file — `open_lib_sd`) and `KFS_LISTDIR` (`sd_listdir` ->
     `sd_listdir_raw`). `g_vfs_mtx` + `vfs_lock`/`unlock` deleted; `vfs_*` are plain
     dispatch now. `sd_init`'s one-time `f_mount` stays in shell_task — it completes before
     the fs task ever touches FatFs (happens-before), so it needs no lock. Validated: boot
     + read/write/mmap/shm all healthy with the lock gone; the mailbox round-trip runs on
     qemu via `sd_listdir` (READFILE success + true concurrent FatFs are the HW/SD leaf).

Later: multi-page per-fd cache + eviction (LRU), `(file,page)` cross-fd dedup, and moving
GEM's param block onto the shm primitive.
