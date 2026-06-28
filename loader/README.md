# xtld — the XTOS dynamic loader + syscall spine

The first pieces of os-making (milestone **M0**): the ELF `ET_DYN` loader, and
the `svc #1` syscall gateway + `spawn`. Spec:
[../docs/OS/dynamic-loading.md](../docs/OS/dynamic-loading.md) §3/§5 (loader) and
§7/§8 (gateway, ABI).

- `xtld.h` / `xtld.c` — the loader. No OS dependencies: the caller supplies
  allocation, cache maintenance, and symbol resolution via `xtld_host`. The same
  source runs in this host testbed (cache ops are no-ops) and, later, in the XTOS
  kernel (kernel allocator + `Xil_DCacheFlushRange`/`Xil_ICacheInvalidateRange` +
  the curated export table). It handles `ET_DYN` (EM_ARM, ELFCLASS32, LE), copies
  `PT_LOAD` segments, applies the model's relocation set (`R_ARM_RELATIVE`,
  `R_ARM_GLOB_DAT`, `R_ARM_ABS32`, `R_ARM_JUMP_SLOT`), resolves undefined symbols,
  and discovers `DT_INIT_ARRAY`.
- `kernel/` — the portable syscall spine. `xtsys.h` (the ABI numbers),
  `ksys.{c,h}` (the `svc #1` dispatch + `k_syscall` + `spawn` + the exit
  longjmp), and `arch_arm.S` (the vector table + svc handler, `enter_user` which
  runs loaded code in System mode so its `svc` traps cleanly, `set_vbar`, and a
  minimal `setjmp`/`longjmp`). On hardware this becomes the FreeRTOS port's
  chained SVC handler (svc #0 = scheduler, svc #1 = syscall) + a real process
  table.

## Testing — two levels

```
make test     # host verify: load a real arm32 .so, check relocated data
make qemu     # bare-metal EXECUTION of loaded code under qemu-system-arm
make kernel   # svc #1 gateway + spawn: a kernel spawns an app that syscalls
make freertos # interactive shell on real FreeRTOS (qemu Zynq) — type commands
make dump     # readelf -h -d -r on the test .so
make clean
```

`test/testlib.c` is built into a **real arm32 ELF `ET_DYN`** with
`arm-none-eabi-gcc` + `ld.lld`, so the relocations are the genuine `R_ARM_*`
types.

- **`make test`** (host, arm64) loads it and **verifies the relocated data** —
  segment placement, all relocation types (incl. symbol resolution against a host
  table), exported-symbol lookup, init_array discovery. No ARM code runs; it
  checks relocation *results*.
- **`make qemu`** builds a tiny **bare-metal ARM image** (`test/qemu/`, semihosting
  for I/O) that embeds the `.so` and **actually executes** it under
  `qemu-system-arm -M virt`: runs the constructor (`init_array`), calls exported
  functions, and exercises a cross-call from loaded code back into the host
  (`greet()` → `host_log`). This is the closest thing to the real XTOS target
  (bare metal, no Linux) until on-hardware bring-up. Two bugs were caught here
  that the verify-only path missed (init_array double-bias; JUMP_SLOT add-vs-set)
  — execution earns its keep.
- **`make kernel`** builds a tiny test *kernel* (`kernel/` + `test/qemu/kmain.c`)
  that installs the vector table, `spawn`s an embedded app (`test/qemu/app.c`),
  and reports its exit code. The app runs in System mode and issues genuine
  `svc #1` traps for `write`/`getpid`/`exit` — proving the full syscall spine
  (immediate-decoded gateway coexisting with semihosting's `svc 0x123456`,
  dispatch by `r7`, System↔Supervisor mode switch, exit via `longjmp`).
- **`make freertos`** runs the **real Xilinx FreeRTOS** (`../third_party/
  freertos10_xilinx`, the same `freertos10_xilinx` @ `xilinx_v2025.2` as the
  hardware Vitis build) — the kernel + the Cortex-A9 port unmodified — under
  `qemu-system-arm -M xilinx-zynq-a9` (a model of the actual Zynq PS). Only the
  BSP board-glue is ours (`test/freertos/`): boot, the runtime vector table, and
  a functionally-identical GIC + A9-private-timer tick wired through the port's
  `configSETUP_TICK_INTERRUPT()` / `vApplicationIRQHandler()` seams (`zynq.c`),
  with no-op shims for the few BSP calls the port links (`bsp_shim.c`, `shim/`).
  This is the "real thing" testbed: the same kernel + port as the board, fast to
  iterate, with gdb attach (`-s -S`) — so most kernel/syscall work happens here,
  not over JTAG. PL peripherals (blitter/HDMI/ANTIC/compositor) aren't modelled
  and stay a hardware concern.

  The loader + syscall spine run **on** this kernel (`frtos_os.c`): the SVC vector
  is chained (`svc #0`→`FreeRTOS_SWI_Handler`, `svc #1`→`k_syscall_dispatch`),
  `spawn` is `xTaskCreate` (the loaded `ET_DYN` runs as a real task whose `svc #1`
  traps cleanly), `exit` redirects the task's resume PC to a task-context thunk so
  `vTaskDelete` doesn't nest `svc`, and `waitpid` blocks on a per-process
  semaphore. An "init" task spawns the embedded app, which issues real
  `write`/`getpid`/`exit` syscalls; init reaps it and reports — the init/pid-1
  model on the genuine kernel.

  **M2** adds a filesystem: an embedded read-only **romfs** (`tools/mkromfs.c`
  packs the blob; `romfs.c` reads it), `spawn`-by-path (the loader reads the ELF
  from the FS), and `open`/`read`/`close`/`lseek` syscalls over a **per-process fd
  table**. `init` spawns `/bin/hello` and `/bin/showmotd` (the latter reads
  `/etc/motd`) — programs loaded from a filesystem doing real file I/O.

  **M3** adds shared libraries (the `libGEM.so` mechanism): the loader handles
  `DT_NEEDED` (recursively loading deps from `/OS/Library/`), resolves undefined
  symbols across a registry of loaded objects, dedups/refcounts by `DT_SONAME`,
  and falls back to a **curated kernel export table** (`frtos_ksym` — `memcpy`
  etc.). `/bin/usestr` imports `strrev` from `/OS/Library/libutil.so` and calls
  it across the module boundary.

  **M4** adds an interactive shell: a stdin syscall (`sh_readc`, semihosting
  `SYS_READC` bound to a stdio chardev), **argv** passing to spawned programs,
  and a kernel-resident shell that reads a line, parses argv, and spawns
  `/bin/<cmd> args…` (e.g. `/bin/echo` prints its arguments). Type commands at
  the `xtos$` prompt, or pipe a script in. *(A userspace shell needs
  `SYS_spawn`/`SYS_waitpid` syscalls whose blocking parts run in task context —
  a follow-up.)*

  **M6a** brings up a real **`libc.so`** (PIC newlib — `tools/build-newlib-pic.sh`
  → `newlib-pic/`, linked to `/OS/Library/libc.so`). The kernel is `-nostdlib`
  (its own `bare_libc`) and **exports a bounded, fixed 40-symbol surface** the way
  a real OS does: ~26 `_foo` syscall primitives + 10 libgcc helpers + 4 stubs
  (`frtos_os.c`'s `frtos_ksym`; `syscalls.c`). At boot a one-shot bootstrap
  allocator loads `libc.so` pinned at the heap base, then `_sbrk` runs above it
  and the loader's allocator becomes `libc.so`'s `malloc`/`free`
  (`frtos_activate_libc`). `/bin/libc_test` `DT_NEEDED`s `libc.so` and uses
  `printf`/`malloc`/`strcpy` from it. The loader also learned **weak undefined
  symbols → 0** (for `libc.so`'s init-array markers).

  **M6b** brings up the **real graphics stack** as shared libraries: the actual
  portable `gem/` VDI core + `gfx_soft.c` + the vendored FreeType (`xtos/freetype/
  tu/*.c`, 19 TUs) compiled `-fpic` into **`/OS/Library/libGEM.so`**, which
  `DT_NEEDED`s `libc.so` + `libm.so` (also PIC newlib). `/bin/gemtext` opens a VDI
  workstation on an RGBA surface, fills a rectangle, and draws a string with
  **FreeType-rasterised antialiased glyphs** from a TTF loaded out of the romfs
  via `fopen` (`/OS/Fonts/AovelSansRounded.ttf` via the `System.font` pointer) —
  then ASCII-dumps the surface (the `@%#+=:.` ramp is glyph coverage). The
  `__aeabi_*` libgcc helpers the libs need (incl. float/`__muldc3`) are vended by
  the kernel export table; the dir-scan `dirent` path is shimmed (fonts load by
  pointer file, not scan). A **flat identity MMU map** (`mmu.c`) marks DDR as
  *Normal* memory so libc's NEON/word-tail `memcpy` can do unaligned access
  (strongly-ordered memory — the MMU-off default — faults on those); caches stay
  off for now. Spawned-task stacks went to 64 KB (FreeType is stack-hungry).

  **M6c** gives the OS the **display plane**: it owns one RGBA plane at `FB_BASE`
  (`0x3000_0000`, the hardware compositor-plane address; just RAM under qemu).
  New gfx syscalls (`gfxplane.c`) — `SYS_fb_info` hands an app the plane
  descriptor (`struct os_fbinfo`), `SYS_fb_present` pushes it (the compositor on
  hardware; an ASCII dump under qemu). `/bin/gemtext` no longer allocates a
  private surface: it wraps the OS plane in a `gfx_surface`, draws, and presents.
  This is the seam the on-hardware compositor slots behind unchanged.

Requires `arm-none-eabi-gcc`, `ld.lld`, and `qemu-system-arm` on `PATH` (all via
Homebrew).
