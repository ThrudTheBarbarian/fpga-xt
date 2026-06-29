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
  mechanism. It backs per-process data for libc, every shared library, and the
  program's own data/bss, plus a synthetic demo region.

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
writable range, LRU tick}`. On a hit it reuses the object — no second load, no
second relocation. `frtos_waitpid` reaps the process slot but leaves the cached
image resident for reuse.

When the cache is full (`MAXPROG`, default 32 — kept above `MAXPROC` so an idle
image is always evictable), `prog_evict` drops the least-recently-used image that
has **no live process**: it `mmu_unprotect`s the image's pages (back to identity
RWX, so the freed RAM is safe to reuse), then `xtld_unload`s it. Unload runs the
module's **`DT_FINI_ARRAY` destructors** (`xtld_run_fini`, reverse order) and
**transitively releases its `DT_NEEDED` libraries** (each refcount drops; a library
is freed only when its last dependent goes). If a library is freed this way,
`register_lib_cow` rebuilds the COW range set so the gone library stops being
mapped. (Constructors run per process in `app_main`; destructors run once, at
module unload — programs aren't unloaded per-exit, so a program's `fini` runs when
its cached image is evicted.)

## 4a. mmap'd files (`SYS_mmap`)

A process can map a romfs file **read-only + shared + demand-paged** instead of
`read()`-ing it into a malloc'd buffer: `SYS_mmap(fd, len, off)` returns a VA in a
per-process window (`XTOS_MMAP_VA`, one section, bump-allocated). Nothing is mapped
up front; on a read fault in the window `vm_mmap_fault` maps the page **RO + XN** to
the file's physical romfs page. Since romfs is resident and page-aligned (`mkromfs`
page-aligns each file; the embedded blob is `aligned(4096)`), this is **zero-copy**
and **shared** — every mapper points at the one physical copy. A **write** to the
mapping is fatal (it's read-only). `SYS_munmap` drops the descriptor (the shared
romfs physical is left alone). On exit, the mmap window is just torn down — its
pages are romfs, never pool pages, so reclaim ignores them.

`/bin/mmaptest` proves it: mmap'd bytes equal a `read()` of the same file
(zero-copy correctness), a multi-page font demand-pages first + last page, and
`mmaptest ro` writes to the mapping and is killed (RO enforced), OS surviving.

FreeType now uses it: `font_face_open` (gem/font.c) maps the font file and hands it
to `FT_New_Memory_Face`, so glyphs are read straight from the shared RO mapping
(demand-paged) instead of `fread` into a per-process malloc buffer. Portable via
weak `xt_font_map`/`xt_font_unmap` hooks (XTOS overrides them in `gem_stubs.c`; the
host falls back to `FT_New_Face(path)`).

## 4b. Running host files (`runhost`) — test harness

For iterating many libc-linked binaries without rebuilding the embedded romfs, the
shell can load + run an ELF straight from the **host** filesystem over qemu ARM
semihosting: `runhost <hostpath> [args]`. `hostfs_open/len/read/close` (bare_rt.c,
`SYS_OPEN/FLEN/READ/CLOSE`) read the host file into a buffer; `frtos_spawn_host`
runs it through the loader exactly like a romfs program — its `DT_NEEDED`
(libc.so/libm/libGEM) still resolve from the embedded romfs. Host programs are
**transient**: loaded fresh (not cached) and `xtld_unload`ed + buffer-freed when
reaped, so a 300-file run doesn't accumulate (pool pages reclaimed; the libc heap
high-water-marks but freed images are reused). On real metal semihosting is absent,
so `hostfs_*` stub to failure. (e.g. `runhost build/vmtest.so A`.)

## 5. Hardware notes (carried for the HW re-graduation)

- **Stale global TLB shadow.** The master maps RAM global+identity. A per-process
  `nG` override is shadowed by a cached global TLB entry **only for VAs the kernel
  actually touches** (libc's data arena). `vm_switch` flushes libc's data pages by
  MVA on entry to a process. Program data and the synthetic/heap windows are never
  touched by the kernel, so (like the heap) they need no extra flush. Any new
  per-process override of a *kernel-touched* VA must add the same flush. (qemu's TLB
  model hides this; it bites only on real silicon.)
- The physical page pool is **DDR-backed and shares the one CPU heap arena**
  (`[0x0200_0000, 0x2000_0000)`, ~480 MB — docs/Zynq/memory-map.md). libc malloc
  grows UP from the bottom (`kern_sbrk`); the page pool grows DOWN from the top
  (`g_pfront`); they meet in the middle — no fixed split, all of DDR available to
  whichever needs it (vs the old 4 MB carve-out). `dpage(idx)` prefers the reclaim
  free list, else advances the frontier; `vm_space_destroy(idx)` (from
  `frtos_waitpid`) returns a dead space's pages, so heap + COW pages are
  **reclaimed** — no steady-state leak.
  - `kern_sbrk` (task context) and `dpage` (abort context) share the boundary, so
    each does its check+update under a short **IRQ-masked critical section** —
    single core, so masking IRQ fully serialises them (the allocator's own code
    never faults, so no data abort can occur inside it).
  - Reclaim frees the *exact* pages a space was charged (a per-space list), NOT
    every page-table entry pointing into the pool: a per-process L2 inherits
    identity mappings for the rest of its 1 MB section, which can overlap the pool,
    so walking the tables would mass-double-free the pool's own pages.
  - The A9 L1 D-cache is PIPT and every page is re-initialised on the next
    `dpage()`, so reuse needs no cache maintenance. (`memtest` shows ~478 MB free
    and pages-in-use returning to baseline across many spawn/exit cycles.)
- **Per-process data covers libc, every shared library, and the program.** Each
  loaded library's writable (data/bss) range is registered as a global COW range
  (`register_lib_cow` in `frtos_os.c`, via `xtld_object_at`/`xtld_soname`). A
  library's data is never written by the kernel, so its COW source is the library
  image itself (identity — pristine after its one-time load-init); only libc keeps
  a boot snapshot (the kernel mutates its malloc arena). This dissolved the earlier
  shared-library-globals clash: `gemtext`→`desktop`, `desktop` twice, etc. each get
  their own FreeType/VDI/libGEM state and run clean.

## 6. Tests (all green on qemu — `make freertos`)

`cowtest` (synthetic COW + isolation), `sharetext` (1 load for 2 spawns, shared
`&marker`, pristine-then-private `g_counter`), `vmtest` (per-process heaps),
`libc_test` / `gemtext` / `desktop` (libc + libm + FreeType under COW),
`demandtest`, `wxtest`, `stacktest`, `faulttest`, `memtest` (DDR pool + reclaim),
`finictor` (ctor/dtor — fini on eviction), `mmaptest` (zero-copy RO file map +
multi-page demand + RO-enforced).

## 7. Caches (on)

Caches are **enabled** (`mmu.c`). The CPU's own RAM (everything below
`0x2000_0000`: code, libc, heap, COW pages) is Normal **Write-Back Write-Allocate
cacheable**, and page-table walks are cacheable (`XTOS_TTBR_ATTR`, OR'd into TTBR0
in `mmu_init` and `vm_switch`) so walks stay coherent with our cacheable PTE
writes — no explicit PTE cache-cleaning needed.

- The loader makes freshly-copied code coherent for execution via
  `xtld_host.sync_caches → mmu_sync_caches` (clean D to PoU + invalidate I by MVA +
  BPIALL). COW/heap data pages are **XN**, so they need no I-side maintenance, and
  Normal-cacheable keeps them coherent for data access.
- `mmu_init` invalidates I- and D-caches (D by set/way) before enabling, since
  cache contents are UNKNOWN out of reset.
- **The PL-shared region (`0x2000_0000..0x3FFF_FFFF`: SALLY/planes/framebuffer at
  `FB_BASE 0x3000_0000`) stays Normal NON-cacheable**, and peripherals stay Device:
  the FPGA compositor and the CPU must see each other's writes without a cache
  between them (the "PL-visible ⇒ wired/uncached" invariant).

Validated on qemu (full suite green incl. framebuffer rendering). qemu models
caches as coherent, so it exercises the **plumbing** (attribute encodings, the
enable sequence, the set/way loop, `sync_caches` wiring) but not true cache
*incoherency* — that, plus the SMP/SCU shareability bits (`XTOS_TTBR_ATTR` is
currently non-shared), is the **HW re-graduation** step: `freertos-hw.elf` +
`./vivado/jtag-valhalla.sh testbed`, user drives the JTAG load.

## 8. Roadmap (ordered)

1. **mmap'd files** — mechanism DONE (§4a: `SYS_mmap`/`SYS_munmap`, RO + shared +
   demand-paged, page-aligned romfs). Remaining: wire FreeType/asset loading in
   libGEM to use it (`FT_New_Memory_Face` on the mapped pointer) so fonts/assets
   stop being `read()` into per-process malloc buffers.
2. **Scrub pages on free** — zero a space's private pages in `vm_space_destroy`
   (not just on the next `dpage()` alloc), so freed runtime data doesn't linger on
   the pool free list. Defense-in-depth; only fully meaningful with #3.
3. **PL0 user/kernel split — the real memory-protection boundary.** Today every
   task runs **privileged (System mode)** and the whole identity-mapped DDR
   (`0x0010_0000–0x1FFF_FFFF`) is mapped **AP=11 (RW)** in every space, so the
   per-process windows isolate *honest* programs but are **not a boundary against
   hostile code**: a process can read/write any physical RAM — other processes'
   pages, the kernel, freed pool pages — directly at its identity address. The fix:
   run user code in **User mode (PL0)**, mark kernel/identity sections **no-access
   at PL0** (AP=01), and harden the SVC/abort entry paths for the privilege
   transition (this is the "user ≠ kernel" goal in
   [memory-protection.md](memory-protection.md) §4). With that in place, scrub-on-
   alloc (and #2) close the page-reuse leak for the kernel's view too.
