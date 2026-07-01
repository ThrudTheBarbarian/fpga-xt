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

## Build order

Each step is qemu-testable except the SD leaf (qemu has no SD backend; romfs exercises
the client side of everything).

1. **shm core** — `shm_create` / `shm_map` (into a client) / `shm_ref` / `shm_drop`,
   the `XTOS_SHM_VA` window, and the `frtos_reap` drop hook. Test: two procs map one
   shm, one writes, the other reads.
2. **fs service + control channel** — the task owns FatFs; clients post + park, the
   service serves + wakes. Test on qemu against **romfs** (proves the protocol and the
   serialization).
3. **page store** — per-fd demand-paged, write-back pages; `read`/`write`/`mmap` as the
   three entry points; service = fill / flush / extend; single-writer; growth explicit.
   SD is the HW-only leaf; the romfs path exercises the client side.

Later: dirty-via-fault, eviction, `(file,page)` dedup, and moving GEM's param block
onto the shm primitive.
