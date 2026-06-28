# Dynamic loading, the syscall ABI, and bootstrap

> **Status: design spec for Phase 4.** This is the detailed contract behind the
> north-star's *"FreeRTOS loads and runs applications dynamically"* (P1) and the
> *interface/registry* (P4). The **syscall numbers and the calling convention are
> meant to be frozen early** — codegen and every loaded binary bind to them, so
> renumbering later is an ABI break. Everything else (loader internals, the
> process table layout) can move. See [xtos-vision.md](xtos-vision.md).
>
> **Relationship to P4.** The vision folds "service" and "library" into one
> abstraction — an ops-table fetched from a registry and called in-process. That
> still holds for *userland* services and libraries. This doc adds the tier
> *beneath* it: a real **kernel/userland split via an `SVC` syscall gateway**, for
> the irreducible mechanism only the kernel can provide (process, memory, file,
> blitter-submit) and as the convergence point for the three guest transports.
> The registry lookup itself becomes a syscall. This **extends** P4; it does not
> replace it. P4 in the vision now references this syscall tier.

## 1. The model: Unix semantics on a flat address space (uClinux)

XTOS is an early-Unix-shaped OS — programs, syscalls, a shell that spawns
children, pipes, a real libc — running with **no MMU protection and one flat
physical address space**. That is precisely uClinux territory, and uClinux's
design lessons apply directly:

- **`spawn` is the primary primitive** (load a fresh image + create a task), not
  fork+exec — the shell and all userland are written spawn-first. `fork()` needs
  copy-on-write and thus an MMU; with the MMU now load-bearing for the m68k port,
  fork is a live *option* rather than ruled out, but it is an additive tier-3
  decision, not the baseline — see [memory-protection.md](memory-protection.md).
- **Programs are position-independent** (`ET_DYN`), so the same binary can be
  loaded at any address — and later, mapped at per-process virtual addresses
  without re-relocation, when the MMU lands.
- **Protection is by convention now, enforcement later.** Nothing in the ABI
  assumes a shared address space *across the kernel boundary* (§9), so MMU
  protection becomes an enforcement pass, not an ABI break — the same promise P1
  and P4 make.

The FreeRTOS binary **is the kernel**: scheduler + drivers + VFS + loader +
syscall dispatch + the service registry, statically linked. Everything else —
the desktop, apps, even `libGEM` — is loaded from disk. The kernel's last act at
boot is to create one task and become pure mechanism (§7).

This is the *hypervisor* framing from P1/P2 made concrete: the kernel vends
services, and the ST/XL/TT environments are **guests** that fall through to the
same service surface as native ARM programs (§4).

## 2. The layered ABI

Three tiers, lowest first:

| Tier | Mechanism | For | MMU-safe because |
|------|-----------|-----|------------------|
| **0 — Kernel syscalls** | `SVC #1` gateway, numbered (§8) | process, memory, file/VFS, time, blitter-submit, registry, debug | a trap crosses address spaces by construction; supervisor entry |
| **1 — System services** | registry lookup → ops-table (P4) or task-server RPC | GEM, sound, net stack — userland services with global state | the registry indirection can become a cross-AS proxy (P4) |
| **2 — Shared libraries** | ELF `.dynsym` direct-bind (§5) | `libc` (newlib), `libpng`, math — plain code, per-process state | each process maps its own copy; no shared globals (§9) |

- **`registry_lookup` is a tier-0 syscall** that returns a tier-1 service handle.
  That makes the registry the single MMU-safe discovery seam P4 asks for.
- **GEM is a tier-1 service** (P3: "a service *and* a library"). Native apps get
  its ops-table via the registry and call it directly (fast, no trap); guests
  reach it via trap→syscall→service. Its **authoritative global state (the window
  list, compositor bookkeeping) lives in the service, not in `libGEM`'s shared
  globals** — see the §9 rule that makes this MMU-safe. The drawing code is the
  portable core; the per-arch harness is tiny (§10).

## 3. Binary format: ELF `ET_DYN`, minimal-relocation PIC

Both apps (PIE) and libraries (`.so`) are ELF `ET_DYN` — the same type; the only
difference is whether `DT_NEEDED`/entry are used. One loader handles both.

xtc owns the arm32 codegen, so we **co-design the relocation model to make the
loader trivial** instead of accepting gcc's GOT + lazy-PLT machinery:

- Eager binding only — **no lazy PLT**, no runtime resolver stub. The GOT is
  fully populated at load.
- The loader only ever handles three ARM relocation types:
  `R_ARM_RELATIVE`, `R_ARM_GLOB_DAT`, `R_ARM_ABS32`.
- ARM uses **`REL`** (`Elf32_Rel`), not `RELA` — addends live in-place at the
  target word; the loader reads-modify-writes.

Constraint: the output stays **valid ELF with DWARF**, so `addr2line`/gdb and the
P6 debugger work. xtc's debug-info (vision §3) is emitted in the same flat-address
coordinates the loader uses — one logical-address contract, four consumers.

xtc-ARM must also speak the **C ABI** (AAPCS32 + C type layout): it links the C
kernel, newlib, and the C libraries (Lua/FreeType/SQLite). It is the **XTOS system
language** (ARC by default, with an unmanaged subset for the hardware-touching
bottom); existing C deps stay C, cross-compiled on the host; on-device C
compilation is deferred. Full port requirements: [xtc-on-arm9.md](xtc-on-arm9.md).

## 4. The hypervisor surface: one service set, three transports

The reason the kernel service surface is a *numbered syscall table* and not just
direct symbol binding: three different front-ends must converge on **one
dispatch**.

| Guest | "Trap" mechanism | translates to |
|-------|------------------|---------------|
| Native ARM app | `SVC #1`, number in `r7` | → syscall dispatch |
| XL (6502) | hooked vector → GP0 doorbell | → syscall dispatch |
| TT (m68k, JIT) | `TRAP #1/#13/#14` (GEMDOS/BIOS/XBIOS) | → syscall dispatch |

The m68k thinks it is calling MiNT; the JIT maps the MiNT call number + stack
frame onto our syscall number and dispatches into the **same kernel routine** a
native app reaches via `SVC`. One kernel, three trap decoders. Launching an XL/TT
program (see [app-launch.md](app-launch.md)) is therefore just `env_create`
(§8) — spawn a native session-manager task that cold-boots the guest CPU and
serves it; the guest is a process whose CPU happens to be emulated.

## 5. The loader

Flat address space ⇒ "map a segment" is `malloc + memcpy`. The loader is small:

```
load_object(path):
  read + validate ELF header (ET_DYN, EM_ARM, LE)
  span = extent of PT_LOAD segments
  base = page_aligned_alloc(span)              # base == load bias
  copy each PT_LOAD file→base+vaddr; memset bss = 0
  walk PT_DYNAMIC → STRTAB/SYMTAB/REL/JMPREL/INIT_ARRAY/NEEDED
  for each DT_NEEDED: load_object() (refcounted, resolved by name)
  apply relocations (the 3 types in §3)
  Xil_DCacheFlushRange(base, span)             # push code+data to DDR
  Xil_ICacheInvalidateRange(text, tlen)        # <-- the classic gotcha
  run DT_INIT_ARRAY (constructors)
  return handle{base, dynsym, refcount, segments[]}
```

The **I-cache invalidate** over the freshly written text is non-negotiable — the
A9's L1 I-cache may hold stale lines for those addresses. Omit it and you get
"relocation bugs" that are really cache bugs.

**Symbol resolution order** for an undefined symbol:
1. already-loaded libraries' `.dynsym` (so an app finds `v_gtext` in `libGEM`, and
   anything finds `malloc`/`printf`/… in **`libc.so`**);
2. the kernel's **curated export table** — now just the **syscall-level
   primitives** `libc.so` imports (`_sbrk`/`_write`/`_read`/…). It does **not**
   publish a libc surface: libc is a real shared library (`/OS/Library/libc.so`,
   newlib built `-fPIC`) that everything `DT_NEEDED`s, so libc resolves via #1.
   *(Earlier POR had the kernel export the whole libc surface — retired once the
   loadable-`.so` system made `libc.so` the clean answer; an ever-growing export
   table is a kludge.)* The *syscalls* proper still go through `SVC`, not binding.

Eager-bind every relocation at load, including `JUMP_SLOT`. An unresolved symbol =
load failure with a clear message (`undefined symbol "foo" needed by X`).

**Per-instance data — the subtle rule.** With PIC, the GOT lives in the writable
data segment. So:

- **Libraries** (`OS/Library/`) are **singletons**: loaded once, **refcounted**,
  shared — one text, one data, one GOT. Right for stateful services that *want*
  one copy. Held resident while any user exists; `DT_FINI_ARRAY` + free on last
  release.
- **Apps** are loaded **fresh per `spawn`** (full text+data+bss). Two shells =
  two independent images. RAM is plentiful (1 GB); paying a few hundred KB per
  instance beats GOT-sharing gymnastics. Threads *within* one app share that
  app's data (normal FreeRTOS tasks); only separate spawns get separate images.

No ELF TLS — if a library needs per-task state, hang it off FreeRTOS thread-local
storage pointers.

## 6. Processes over FreeRTOS tasks

FreeRTOS gives *tasks*, not *processes*. The kernel grows a **process table**:

- A **process** = `pid` + loaded image + parent + exit status + a **per-process
  fd table** + 1..N FreeRTOS tasks (the main task plus any `thread_create`
  siblings, which share the image and fd table).
- `spawn` allocates a pid + entry, loads the image, creates the main task;
  `exit` records status, runs `DT_FINI_ARRAY`, frees the image, `dlclose`s
  `DT_NEEDED` libs (refcount--), `vTaskDelete`s; `waitpid` reaps.
- **Per-process stdio** is the one real change from today's global-newlib-fd VFS:
  each program needs its own `fd 0/1/2`. v1: init wires the console to the
  fallback shell; later, a pipe/pty for terminal windows.

## 7. Bootstrap: `main()` stops being "the app"

`main()` becomes the kernel coming up; its last act is to create exactly one task
and disappear into the scheduler. Everything after is userland.

**Phase 1 — pre-scheduler (`main()`, IRQs off, single-threaded).** Mechanism
bring-up: install exception vectors incl. the chained `SVC` handler (see below) +
GIC; drivers (UART early console → SD → HDMI/compositor → blitter → timers →
NIC); carve DDR into regions (kernel image, FreeRTOS heap, the **loadable-image
arena**, the graphics planes at `0x30000000+`); register VFS backends, mount SD
at `/`; install the syscall dispatch table; `xTaskCreate(init_task)` — **this is
pid 1, the only task the kernel creates**; `vTaskStartScheduler()`. That call is
the kernel↔system boundary.

**Phase 2 — `init` (pid 1, scheduler live).** Late init needing blocking/timers;
`dlopen` the resident libraries (`/OS/Library/libc.so`, `/OS/Library/libGEM.so`)
and register them; start the GEM service task (for guest doorbell traffic); run
the **rc scripts** — the existing Lua `/OS/Boot/NN-*` runner is the `/etc/rc`
equivalent, executed by init; then `spawn("/OS/Apps/desktop.app")`, falling back
to an interactive **shell on the console** (single-user mode) if the desktop is
missing or fails. init then loops on `waitpid()`, reaping children and
**respawning the session if it dies** (classic init-respawn).

**Phase 3 — steady state.** The kernel only services `SVC` syscalls, fields IRQs,
and schedules. It never "runs" anything again. Programs spawn programs; the
desktop spawns apps; guests appear via `env_create`. "External programs are the
bread and butter" is then structurally enforced — the kernel has nothing else to
do.

This splits today's `repl_task`: its boot-scripting role moves *into* init
(trusted, in-kernel Lua); its interactive role becomes a *spawned shell program*.

### The `SVC` collision (freeze this now)

The FreeRTOS Cortex-A9 port **already uses `SVC #0`** — for `portYIELD()` and to
launch the first task. So the syscall gateway is **`SVC #1`**: the handler reads
the immediate from the instruction at `lr-4`, masks it — `0` → chain to
FreeRTOS's context-switch path, `1` → our dispatch. One `ldr`/`and`/`cmp` on the
syscall path, vendor port untouched.

## 8. Syscall ABI

**Calling convention (arm32), mirroring the Linux ARM EABI** so a ported libc, a
debugger, and anyone's mental model just work:

- number in **`r7`**, args in **`r0–r5`** (six; larger arg lists go by struct
  pointer), via **`svc #1`**;
- return in **`r0`** (`r1:r0` for 64-bit returns like `lseek`);
- errors as **`-errno`** in `r0` (the `-1..-4095` band is reserved for errors; the
  libc wrapper turns it into `-1` + `errno`).

**Numbering rule: numbers are permanent.** Reserve generous ranges per class so a
new syscall is "next free slot in its range" — never a renumber.

```
0x0000_0000              meta            (abi_version, …)
0x0000_0100              process/task
0x0000_0200              memory
0x0000_0300              filesystem/VFS
0x0000_0400              time/timers
0x0000_0500              registry/service
0x0000_0600              graphics/compositor
0x0000_0700              input/events
0x0000_0800              networking
0x0000_0900              debug
0x0000_0A00 – 0x0000_0F00   spare core blocks (6 reserved)
0x0000_1000 – 0x0000_FFFF   kernel expansion (sound, USB, crypto … one block each)
0x0001_0000 +            GUEST ENVIRONMENTS — one 0x1_0000 block per env type:
   0x0001_0000             guest mgmt (env_create, env_map_service)
   0x0002_0000             XL / 8-bit guest-specific
   0x0003_0000             TT / m68k guest-specific
   0x0004_0000 +           future guests
```

v1 entries (the rest of each block reserved):

| Block | Class | v1 syscalls |
|-------|-------|-------------|
| `0x0000` | meta | `abi_version` |
| `0x0100` | process/task | `spawn` · `exit` · `waitpid` · `getpid` · `yield` · `nanosleep` · `thread_create` · `thread_exit` |
| `0x0200` | memory | `heap_grow`(sbrk) · `map_anon` · `unmap` · `shm_create` · `shm_map` |
| `0x0300` | filesystem/VFS | `open` · `close` · `read` · `write` · `lseek` · `stat` · `fstat` · `getdents` · `mkdir` · `unlink` · `rename` · `ioctl` · `dup` · `pipe` |
| `0x0400` | time/timers | `clock_gettime` · `timer_create` · `timer_arm` |
| `0x0500` | registry/service | `registry_register` · `registry_lookup` · `service_open` |
| `0x0600` | graphics/compositor | `surface_alloc` · `surface_free` · `gfx_submit` · `plane_bind` · `vsync_wait` · `cursor_set` |
| `0x0700` | input/events | `evt_poll` · `evt_wait` |
| `0x0800` | networking | reserved (BSD layout: `socket`/`bind`/`connect`/`listen`/`accept`/`send`/`recv` …) |
| `0x0900` | debug | `dbg_attach` · `dbg_mem_read` · `dbg_mem_write` · `dbg_bp_set` · `dbg_bp_clear` · `dbg_task_list` |
| `0x1_0000` | guest mgmt | `env_create` · `env_map_service` |

Design choices worth the eye:

- **Graphics syscalls are coarse on purpose** — `gfx_submit(descriptor)`, not
  per-primitive. Per-pixel/glyph drawing is `libGEM` in-process; only "allocate
  DDR surface / submit a blitter descriptor / wait vsync" crosses the boundary,
  matching how the blitter already takes command descriptors.
- **`dbg_*` leans on P6 as decided** — `dbg_bp_set` takes the flat-address
  descriptor `{bank,offset,R/W/X,EN}`; `dbg_mem_read/write` are a `memcpy`
  because (today) debugger and debuggee share the space.
- **`abi_version`** lets any binary check the frozen contract at startup and
  refuse politely on mismatch — the `ABIVER` house style (P4) at the syscall
  level.

## 9. MMU-readiness rules (the corner-painting list)

The MMU is now **load-bearing** (it lets the m68k port skip emulating the 68030
MMU — see [memory-protection.md](memory-protection.md)), so these are no longer
hypothetical readiness rules but the migration we intend to make. They cost only
discipline now and keep that migration mechanical. **Do not violate them even
though the flat space would let you.**

1. **Everything PIC `ET_DYN`** — so images relocate to per-process virtual
   addresses later with no re-fixup. (§3)
2. **All kernel services go through `SVC`, never direct symbol binding to kernel
   code.** A trap works across address spaces; a direct call into kernel memory
   would not. (This is why we rejected the AmigaOS-LVO option.)
3. **`copyin`/`copyout` discipline at the syscall boundary.** A userspace pointer
   passed to a syscall (`read(fd,buf,n)`) is a pointer *in the caller's space*;
   the kernel accesses it through a copy helper. Today that helper is a `memcpy`;
   under MMU it becomes a translated copy. Write the helper now, even as a no-op
   wrapper, so nothing assumes "kernel and caller share addresses."
4. **Global service state lives behind the service (tier 1 / syscalls), not in
   shared-library globals.** A library's globals are per-process under MMU, so the
   GEM window list etc. must live in the GEM service, not `libGEM`'s `.data`.
   `libGEM` holds only per-process state (its workstation handles, local caches).
5. **Page-align segment allocations and track per-process segment lists.** No
   fixed offsets, nothing kernel-relative. Migrating to "map these segments into a
   private address space" then becomes mechanical.
6. **Userland deals in handles/VAs; any address handed to the PL (blitter,
   compositor, DMA) is translated VA→PA at the kernel boundary.** Today VA==PA
   (FSBL identity map) so a no-op helper; under MMU the PL still sees physical
   while the A9 sees virtual. The coarse `gfx_submit` syscall is the natural place
   to do the translation — so never expose a raw PL address to userland.
7. **No assumption of VA==PA in portable or userland code.** Identity mapping is
   an implementation detail of today, not a contract.

## 10. Per-arch libraries: portable core + thin harness

A service/runtime lib is **one portable core + a per-arch harness**, not N
rewrites. For any lib (GEM, libc):

- **Portable** (`gem/…`, shared `.c`): all logic — drawing, layout, font, window
  management. 90%+.
- **`support/{arch}/lib`**: just the harness — `crt0` (image entry → run
  `init_array` → `main` → `exit`), the syscall stubs (the actual `svc`/`trap`/
  doorbell sequence per transport), `setjmp`/`longjmp`, asm intrinsics. A few
  dozen lines.

So "the m68k GEM" and "the arm32 GEM" differ only by harness. xtc emits the right
transport per backend from the same source.

## 11. Relation to the roadmap

This is the spec for **Phase 4** (vision §5: *Dynamic loading + interface/
registry*). It depends on Phase 3 (VFS, `OS/` layout) and feeds Phase 5/6 (the
on-device xtc IDE produces these ELFs; the P6 debugger consumes their DWARF and
drives the `dbg_*` syscalls). The frozen artifacts here — the `SVC #1`
convention, the syscall numbering, the `ET_DYN`/minimal-reloc format — are the
"reserve-now" items (vision §4) that later phases bind to.

## Related

- [xtos-vision.md](xtos-vision.md) — P1 (OS on FreeRTOS), P3 (GEM service+library),
  P4 (interface/registry), P6 (flat-address debug); this doc is P4's detail.
- [app-launch.md](app-launch.md) — launching guest (XL/6502) programs; the
  `env_create` syscall is the native side of that.
- [creation.md](creation.md) — the GEM portable-core + backend split and the
  Lua boot-runner this doc generalizes into init.
- [../GEM/gem-service-abi.md](../GEM/gem-service-abi.md) — the client↔A9 GEM
  binary ABI (the tier-1 GEM service's wire format for guests).
- [../NextSteps.md](../NextSteps.md) — consolidated open work.
