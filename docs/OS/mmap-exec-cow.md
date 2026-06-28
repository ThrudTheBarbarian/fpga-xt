# mmap-exec + COW — design, plan, and handoff

> **Status: NOT BUILT — next-session task.** This is a working handoff doc for the
> last big tier-2 piece (memory-protection.md §4). A first COW attempt was made
> and reverted (§4); start from the plan in §5. Current tree is green at the W^X
> checkpoint. See [memory-protection.md](memory-protection.md), [dynamic-loading.md](dynamic-loading.md).

## 1. Goal

Two coupled capabilities from tier-2 (memory-protection.md §4):

- **Demand-loaded / shared-text executables** — map a program's text pages
  instead of `malloc`+`memcpy`-ing them, so spawn is cheaper and **text is shared
  across instances** of the same program (one physical copy).
- **Copy-on-write (COW)** — a writable page starts shared read-only and is copied
  privately on first write. This is the **fork-ready mechanism** and the proper way
  to give each process private data without an eager full copy.

Both are *optimizations*: the current eager model (each spawn re-loads the whole
image, relocates in place, and `vm_space_create` eagerly copies libc's data) is
**correct**. So there is no correctness pressure — take the time to do it cleanly.

## 2. Current state (the checkpoint to build on)

Green at commit **`ec6129d`** (W^X). Tier-2 on qemu, all passing
(`vmtest / demandtest / faulttest / stacktest / wxtest`, OS survives each):

- per-process address spaces + ASIDs (`vm.c`, `vm_space_create`/`vm_switch`)
- per-process malloc (eager libc-data copy, part (a) of `vm_space_create`)
- demand-paged lazy heap (`vm_demand_map`, the `xtos_demand_fault` path)
- guard pages (`stackguard.c`, emergency-stack kill)
- W^X (`mmu_protect` in `mmu.c`, called per spawn)

Build/run: `cd loader && make build/freertos.elf` then pipe commands to
`qemu-system-arm -M xilinx-zynq-a9 … -kernel build/freertos.elf` (see the Makefile
`freertos` target / earlier sessions for the exact qemu line).

## 3. The intended design

**In-memory romfs makes text-sharing elegant.** The ELF files already live in RAM
(the embedded romfs blob), so:

- **Text/rodata** (PIC, no relocations): map the **romfs's ELF text pages directly,
  RO, shared** — *no copy*. PIC means it runs at the romfs address; every instance
  and the file share one physical copy. Requires the segment to be page-aligned in
  the file (it is, via `-z max-page-size`).
- **Data/bss**: per-process, **COW** — shared RO from a pristine template until a
  write faults → private copy + remap RW. `bss` = demand-zero.

**The VA≠PA wrinkle.** Sharing text between *instances of one program* works under
identity mapping (same physical, same VA). But running **two different programs**
each at their own fixed VA needs VA≠PA (the loader relocating for a runtime VA
different from where the image physically sits). The testbed is all-identity so
far. Decide early: (a) identity, one-program-family-at-a-time is enough for the
demo; (b) go VA≠PA for the general case (a real loader change — `xtld` currently
relocates for the alloc'd = physical address).

## 4. The COW attempt that was reverted (READ THIS FIRST)

Approach tried (then reverted to keep the tree green):

- `vm.c`: `#define L2_PAGE_RO(phys) (L2_PAGE(phys) | (1u<<9))` (AP[2]=read-only).
  `vm_space_create` part (a) mapped libc's data pages **RO at the shared snapshot**
  (`g_libc_snap`) instead of eager-copying to a private block.
- `vm_cow(idx, va)`: on a write fault in the libc-data range to an RO page →
  `dpage()` a private page, `memcpy` from the snapshot, remap `L2_PAGE` (RW),
  `TLBIMVAA`, bump a counter.
- `frtos_os.c` `xtos_demand_fault`: read `DFSR`, and if `WnR` (bit 11 = write) try
  `vm_cow` before the heap demand-zero path.

**Failure (deterministic):** libc-using programs took an **UNDEF (undefined
instruction) at `PC=0x0254620c`, `DFAR=0/DFSR=0` — BEFORE any COW write fault
fired** (`vm_cow` count stayed 0; `vmtest`/`demandtest` produced no program
output). So a libc **read** off the RO-snapshot mapping returned a bad
pointer/instruction stream — the crash is upstream of the write path, in how the
RO→snapshot mapping presents libc's data.

**Leading suspects (to check next time):**
1. `_impure_ptr` / the newlib `_reent` struct, or a self-pointer in libc's data,
   read off the snapshot and dereferenced/called wrong.
2. The snapshot physical/offset mapping is subtly wrong for some page (re-verify
   `g_libc_wva` page-alignment vs `g_libc_snap + p*0x1000`; libc.so is
   `-z max-page-size=0x100000`).
3. The program executes a mis-mapped page (a GOT/PLT entry pointing into the
   RO-mapped data region).

Disassembling the runtime image around `0x0254620c` (which loaded object + offset)
is the fastest way in.

## 5. Recommended plan (incremental — the hard lesson from guard pages)

Do **one layer at a time, test each on qemu before the next.** A first attempt
that did everything at once thrashed; the incremental retry succeeded.

1. **COW mechanism on a SYNTHETIC isolated region** — not libc. Map a scratch VA
   range RO→a known template, write to it, confirm `vm_cow` copies + remaps + the
   store re-runs into private memory. This validates the mechanism away from
   libc's reentrancy/GOT subtleties.
2. **COW for libc data** — apply the validated mechanism to part (a); debug the §4
   UNDEF with the mechanism already known-good.
3. **Shared text from romfs** — the loader change: map text pages from the romfs
   ELF (RO, shared) instead of copying; relocate only the per-process data. Decide
   the VA≠PA question (§3) here.
4. **Per-process program globals via COW** — today only libc data is per-process;
   a program's own writable segment is still shared/re-copied. The same COW path
   covers it.

## 6. Gotchas carried from this session

- **Static-task spawn race:** `xTaskCreateStatic` *returns* the handle (unlike
  `xTaskCreate`'s pre-write out-param) and the child outranks the spawner, so set
  `p->task` before it can run — `vTaskSuspendAll()` across creation (frtos_os.c).
- **HW-only stale global TLB shadow:** the master maps regions global+identity;
  per-process nG overrides are shadowed by cached global entries on real silicon
  (qemu hides it). `vm_switch` flushes libc's data pages by MVA on entry to a
  process. Any new per-process override of a kernel-touched VA needs the same.
- **W^X + COW interaction:** `mmu_protect` converts a program's section to an L2 in
  the master; `vm_space_create` part (a) overrides the libc-data section's L1 to a
  per-process L2. If a program and libc share a 1 MB section these can collide —
  check section disjointness when wiring shared-text.
- **Don't thrash:** revert to the green checkpoint rather than stacking fixes on a
  shaky base; bisect by isolating one layer.

## 7. After it lands

Per the user's plan: **re-graduate all of tier-2 to hardware**
(`freertos-hw.elf` + `./vivado/jtag-valhalla.sh testbed`, user drives the JTAG
load), **then turn caches on** (the testbed runs non-cacheable today —
`mmu.c` sets the MMU on but leaves caches off; enabling them needs
`xtld_host.sync_caches` wired for loaded code).
