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
make freertos # the REAL Xilinx FreeRTOS kernel + CA9 port on qemu's Zynq model
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
  Two tasks preempt/alternate on the real scheduler + real tick. This is the
  "real thing" testbed: the same kernel + port as the board, fast to iterate, with
  gdb attach (`-s -S`) — so most kernel/syscall work happens here, not over JTAG.
  PL peripherals (blitter/HDMI/ANTIC/compositor) aren't modelled and stay a
  hardware concern. **Stage 2** chains the SVC vector (`svc #0`→FreeRTOS,
  `svc #1`→the gateway) and rewires `spawn` onto `xTaskCreate`.

Requires `arm-none-eabi-gcc`, `ld.lld`, and `qemu-system-arm` on `PATH` (all via
Homebrew).
