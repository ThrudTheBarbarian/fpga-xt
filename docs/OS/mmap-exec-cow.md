# mmap-exec + copy-on-write

> **Status: BUILT and validated on qemu** (the last tier-2 / memory-protection.md
> §4 piece). See [memory-protection.md](memory-protection.md),
> [dynamic-loading.md](dynamic-loading.md).

## 1. What it does

Two coupled capabilities, both layered on one copy-on-write (COW) mechanism:

- **Shared-text executables (mmap-exec).** A program spawned N times is loaded
  **once**. Its text / rodata / GOT are shared **read-only** — one physical copy
  across all instances — and W^X (read-only + executable). Previously each spawn
  re-loaded and relocated the whole image, duplicating text per instance.
- **Copy-on-write data.** A writable page starts mapped shared read-only at a
  pristine source and is copied privately on the first write. This gives each
  process private data without an eager full copy, and is the **fork-ready**
  mechanism. It backs per-process libc data, per-process program data/bss, and a
  synthetic demo region.

## 2. The COW mechanism (`vm.c`)

A COW page is mapped **read-only** (`L2_PAGE_RO`, AP=111) at a shared pristine
source. A write permission-faults; the data-abort handler (`xt_vectors.S` →
`xtos_demand_fault` → `vm_cow_map`) services it:

1. Gate: the faulting VA must be in a known COW range (else it's a genuine fault —
   e.g. a write to read-only **text** under W^X — and stays fatal).
2. Draw a fresh page from the pre-reserved kernel demand pool (`dpage()` — no libc
   from the abort handler; it runs in the faulting process's address space).
3. `memcpy` the shared page into it **through the still-valid RO mapping** (reads
   are allowed), so the source needs no separate kernel VA.
4. Rewrite the L2 entry to the private page, **clearing AP[2] (RO→RW) but keeping
   every other attribute** — crucially XN, so a COW'd program-data page stays
   execute-never (W^X).
5. `TLBIMVAA` the page and return 1 to re-run the store into private memory.

The write fault is distinguished from a read fault via `DFSR.WnR` (bit 11).

### COW ranges

`vm_space_create` builds each space from a copy of the master table, then installs
per-process L2s for the ranges it needs to override:

- **Global ranges** (libc data, the synthetic demo) live at the same VA in every
  space and are mapped into all of them. Registered via `vm_cow_register`.
- **The per-space program range** is the spawning program's own data: its VA is the
  program's identity load address, so it belongs only to that space. Tracked in
  `g_space_prog[idx]` and passed to `vm_space_create`.

Each range carries a `src`: page `(va + k·0x1000)` maps RO to `(src + k·0x1000)`.

L2s are **section-keyed** (`perproc_l2`): one per-process L2 per 1 MB section, seeded
from the master so shared text/rodata/GOT pages in the same section keep their
mapping while the COW pages are overridden. If a program and libc land in the same
1 MB section they reuse **one** L2 (no clobber — the collision hazard from earlier
notes is closed).

## 3. The shared pristine source per feature

- **Program data** — COW source is the **program image's own data pages**
  (identity). The kernel never writes a loaded program's data, so the master image
  stays pristine and serves every instance. No snapshot, no alignment fixup
  (identity preserves the sub-page offset). Constructors (`.init_array`) run **per
  process** in `app_main` (classic exec semantics), writing into each instance's
  COW copy.
- **libc data** — COW source is **one shared pristine block** built once in
  `vm_set_libc`. libc's writable segment starts at a **non-page-aligned VA** (e.g.
  `…c58`), so the block is page-aligned with the data seeded at its true sub-page
  offset. Mapping a page-aligned VA straight to `snapshot[0]` would shift every
  pointer/GOT entry by the offset and crash on the first libc call — the block
  avoids that. The kernel mutates the *original* libc data (its own malloc arena);
  processes COW from the pristine block.
- **Synthetic demo** — COW source is a template page; `/bin/cowtest` proves the
  mechanism in isolation.

## 4. The program cache (`frtos_os.c`)

`prog_get` keys on the romfs image pointer. On a miss it `xtld_load`s, applies W^X
`mmu_protect` (text RO+X, writable RW+XN) **once**, and caches `{obj, entry,
writable range}`. On a hit it reuses the object — no second load, no second
relocation. `frtos_waitpid` reaps the process slot but leaves the cached image
resident for reuse.

## 5. Hardware notes (carried for the HW re-graduation)

- **Stale global TLB shadow.** The master maps RAM global+identity. A per-process
  `nG` override is shadowed by a cached global TLB entry **only for VAs the kernel
  actually touches** (libc's data arena). `vm_switch` flushes libc's data pages by
  MVA on entry to a process. Program data and the synthetic/heap windows are never
  touched by the kernel, so (like the heap) they need no extra flush. Any new
  per-process override of a *kernel-touched* VA must add the same flush. (qemu's TLB
  model hides this; it bites only on real silicon.)
- The demand pool is a bump allocator that is never reclaimed — fine for the
  testbed; a real page allocator (free list) is the follow-up that also unlocks
  reclaiming COW/heap pages on process exit.

## 6. Tests (all green on qemu — `make freertos`)

`cowtest` (synthetic COW + isolation), `sharetext` (1 load for 2 spawns, shared
`&marker`, pristine-then-private `g_counter`), `vmtest` (per-process heaps),
`libc_test` / `gemtext` / `desktop` (libc + libm + FreeType under COW),
`demandtest`, `wxtest`, `stacktest`, `faulttest`.

## 7. After this

Per the user's plan: **re-graduate all of tier-2 to hardware**
(`freertos-hw.elf` + `./vivado/jtag-valhalla.sh testbed`, user drives the JTAG
load), **then turn caches on** (the testbed runs non-cacheable today — `mmu.c`
sets the MMU on but leaves caches off; enabling them needs `xtld_host.sync_caches`
wired for loaded code).
