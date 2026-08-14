# Next Steps / Open Work — consolidated

## antic-sally-interop — phase 6 (one clock domain) landed; residuals
The Atari realm (antic2 + GTIA + both POKEYs) runs NATIVE on clk_sally
beside the fid core — unification phase 6, chunks 1+2 + the SUB_DATA strobe
fix (04ac8092 / 75951a58 / ba04f4a6; status in
docs/antic-unification-plan.md).  Every CPU-bus crossing, delay tap, skid
and lookahead is gone; the per-boot mesochronous phase lottery is
structurally dead (the fabric resets WITH the CPU); both builds met timing
first try, no directive roulette.  ACID: 50 (chunk 1) -> 54 (chunk 2) of
58, runs 2026-08-10-4/-5.

Open:
- antic_wsync: CLOSED — SUB_DATA strobe fix ba04f4a6 validated on HW; full
  sweep 2026-08-10-6 = 55 pass, HW at sim parity.
- pokey_serdirect / pokey_skstat: DECIDED (Simon, 2026-08-10) — na like
  the sim (no serial bus device).  Sweep + dashboard grey them; the sweep
  list in tools/acid-sweep.sh is where they come BACK when the peri-RP
  board (at PCBA now, arriving soon) delivers a real serial bus.
  **The dashboard's top run is now ZERO FAILS — HW fully at sim parity.**
- Legacy retirement (phase-6 tail): antic_top's legacy machine is still
  the phi2 timing master and hosts the peri/i2s glue; the crossed register
  lanes remain for the clk_sys pages.  Retiring it removes the last
  compensation-era machinery.
- Timing: HEALTHY (2026-08-10 MCP campaign, 79910d25+e09561d9).  2-cycle
  multicycle exceptions on the slot-proven stall cones took clk_sally
  +0.001→+0.813, clk_sys +0.217, clk_pix +0.378, hold +0.045; a 4-directive
  sweep ALL passed (spread = seed noise; ExtraTimingOpt stays default) and
  the MCP bitstream swept ACID at 55/8/0 (run 2026-08-10-7).  Remaining
  worst paths are genuine clock-rate (fid state→CE, blitter cx→state,
  sprite cache→prio) — next gains need floorplan/fmax or pipeline RTL,
  only if a need arises.  A future 120 MHz attempt must re-audit the MCPs
  (slot spacing scales with N).
- Turbo core: lost POKEY access by design (debug core; the crossed path no
  longer decodes $D2xx).  Revisit only if turbo needs full-chip debugging.
- Board mDNS drops: FIXED (624c5bfe) — a 60 s kernel keepalive re-sends
  IGMP membership reports and issues a gratuitous mDNS announce.  Root
  cause: inbound MULTICAST delivery dies (snooping-switch aging suspected)
  while the responder stays healthy — proven mid-wedge by a UNICAST
  `dig @board -p 5353 xtos.local` answering perfectly.  Validated 22 min
  continuous resolution with traffic (historic wedges hit at 4-18 min).
  Keep an eye on it across longer sessions.

Rare sibling still open: one basic-from-self-test reset re-entered self-test
(OPTION sampled held despite CONSOL=$07) — 1 in ~10, unreproduced in 6/6.

## XTOS threads (xtc threading Phase 3) — LANDED, open tail

Threads inside one process are in: eight syscalls (`thread_create`/`exit`/`join`/
`detach`/`self`/`tls` + a futex pair), guarded per-thread stacks carved from pool
pages by `vm.c`, `TPIDRURW` thread-local storage, a real futex-backed
`__malloc_lock` in libc.so (newlib's was a no-op stub, so malloc was
single-threaded), and process-wide death when a thread faults.
`Mutex`/`Cond`/`Sem` are user-space over the futex, so an uncontended lock never
enters the kernel.  Docs: `docs/OS/threads.md` (+ the
Starlight page); the compiler side is `fpga-xtc/docs/Design/threading.md` §9.9.

Verified under qemu: `/bin/threadtest` (spawn/join, shared state, a contended
mutex at exactly 8000 increments, TLS isolation, detach-and-reclaim, a futex
rendezvous, the faulting-thread process kill, and a thread stack overflow landing
in its guard page), plus all nine xtc threading fixtures compiled `-A arm9`
running byte-identical to the hosts — including `threads_tls_many`, which spawns
a hundred concurrent threads.  The
existing suite is unregressed (selftest, pipetest, sigtest 5/5, fstest, locktest,
lntest, shmtest, cowtest, vmtest, demandtest, mmaptest, regtest).

**HARDWARE VERIFIED 2026-08-11** (build 5017b86c, Z-Turn V2).  `threadtest` 6/6
first load; the two opt-in fault tests both correct on metal — a faulting worker
takes the process down and the OS keeps running, and a thread stack overflow
lands in its GUARD PAGE (`DFAR=0x64010e68` decodes to slot 8 / thread 1 /
offset 0xe68, inside the 4 KB guard, `L2[pg]=0` a genuine translation fault).
That was the result most at risk from qemu's loose MMU modelling and it needed
no changes.  Existing suite on the board: locktest, lntest, shmtest, fstest all
pass.

⚠ Run the suite from the SERIAL console, not ssh: `fstest` asserts "initial cwd
is /", which only holds for the serial login shell, so over ssh it reports a
spurious `fstest: FAIL` with every other assertion passing.

**The hardware run found one real bug, which qemu could not have.**
`proc_exit_self` set `p->exited` FIRST as the one-thread-owns-the-teardown
claim — but `exited` is what reap_orphans/waitpid test for COLLECTABLE, and
`frtos_reap` then does vTaskDelete + vm_space_destroy.  So a parent could reap a
process while it was still inside `pipes_release()`, and the pipeline peers
never got their EOF.  On a busy board that leaked to 17 live processes (hwm 19)
and 20 pipes with nothing attached, ssh sessions that never exited, and finally
no networking at all.  Fixed by giving the claim its own `dying` flag and
restoring `exited` to LAST, where it was before this work touched it.
Confirmed on hardware: idle 9 procs / 7 pipes, and STILL 9/7 (hwm unmoved) after
selftest + both fault tests + 18 spawns over 6 ssh sessions.

⚠ On this board `reset && load` now wedges the DAP every time.  What works:
`jtag_dapfix.tcl`, then `load` DIRECTLY with no reset leg.

Getting the load on took a DAP-wedge recovery (`vivado/scripts/jtag_dapfix.tcl`,
then `load` DIRECTLY with no reset leg — the 2026-08-08 wrinkle in
[[jtag_dap_wedge_recovery]]).

Open:
- **Main-thread stacks should migrate to the new window.**  They are still in
  `stackguard.c`'s static arena, sized MAXPROC x 64 KB up front.  The thread-stack
  window is deliberately built to be the template for that move (global VA,
  per-space PL0 permissions, pool-backed) — the arena then goes away.
- **Limits**: 128 threads/process, 128 system-wide, 32 concurrent futex
  waiters, 48 KB default stack.  Array bounds, not design limits.
- **Page accounting**: the threads build sits ~2 pages (8 KB) above baseline in
  the selftest's pool count and PLATEAUS there (139/140 vs a flat 138 over eight
  runs), traced to the ramfs page store (`rf_write`), not to thread state — no
  threads run in that test.  Fixed offset, not a leak.  (The selftest's "LEAK"
  line itself is pre-existing: baseline reports it too.)
- **The static-init guard is still racy** (`fpga-xtc` threading.md §9.5): two
  threads first-touching one class's statics can both run its `init`.  Rule until
  fixed: touch static classes on the main thread before spawning.

# Immediate targets

## >>> THE SOFTWARE 6502/ANTIC INVESTIGATION IS ANSWERED — pick the next target <<<

**Verdict: feasible, and the baseline is beaten outright.**  The software Atari
800 in `emu/` scores **57 pass / 0 fail of 63 ACID800** — every in-scope test.
The six that remain were out of scope from the start and are not emulator bugs:
the five `mod_*` display modules need a boot-loader/OS in the `$0A00` resident
page the harness does not provide, and `cpu_65c816` skips itself without a
65C816 core.  Brief: `docs/Design/software-emulation-investigation.md`.
Fabric baseline it replaced: 32/63 at sallyrst `$06`, ceiling 57.

The fabric path is untouched, as instructed — it is still the fallback.

**What is open is which direction to take next.  Candidates, unranked:**

* **An OS / boot-loader stub for the `mod_*` modules.**  A real feature with its
  own scope, exactly as the SIO drive was: ship it inert until it answers
  honestly.  Turns 5 more tests green.
* **A 65C816 core** for `cpu_65c816`.  Large, and only that one test wants it.
* **Port the validated ANTIC/GTIA semantics back into the RTL.**  This was the
  original point of the investigation — the software model is now a cycle-level
  oracle the fabric can be diffed against, which is what the fabric never had.
* **Performance on the A9.**  `make bench` projects what a frame costs; CPU1 is
  at parity with CPU0 (9.00 ns/iter with MMU + caches), so ~35x realtime holds
  on the second core.

**Stage 1 (dedicated second A9 core) is DONE.**  `cat /OS/proc/cpu1` on the
board: `mpidr 0x80000001`, a live ping CPU0 never computed, heartbeat, benchmark.
Code: `loader/test/freertos/cpu1.{h,c}`, `cpu1_core.c`, `cpu1_boot.S`,
`mmu_poke_phys0()`.  Two things worth keeping:
  - **The documented release (`0xFFFFFFF0` + SEV) does not work on this board.**
    What works is Linux's method: a trampoline at physical 0 plus an SLCR reset
    pulse (an SLCR core reset does not re-enter the BootROM, so CPU1 restarts at
    address 0).
  - Kernel pages are not marked Shareable, so CPU1 must touch only the uncached
    AMP region at `0x2100_0000` plus read-only kernel text — never CPU0's mutable
    cached data.  That is why CPU1's code lives in its own file.

Licensing, unchanged: atari800/Altirra are GPL and this repo is permissive-only.
Everything in `emu/` was written fresh; libatari800 and AltirraSDL are used as
measurement and oracle only, never vendored.  `emu/tools/altirra-wsync.py` drives
the AltirraSDL bridge for cycle-accurate ground truth and earned its keep.


- **tb_hscrol_e2e AND tb_antic_display are STALE (fail at HEAD, pre-existing).** Both
  predate the dl_parser walker rework: they tie `frame_start`/`line_start`/`prep_tick`
  low, so the walker never steps and `meta_*` (now the walker's current-row registers)
  serve stale/zero rows — "row0 not mode 4", wrong row-0 pixel pairs.  Not regressions;
  they broke when the walker interface landed.  Fix = port them to the tb_dl_parse
  `step_row()` harness pattern.  Until then they are NOT part of the sim gate
  (gate = dl_parse, nmi, antic_dli, antic_dli_cdc, antic_modes, antic_dma_steal,
  wsync, pokey, boot).


## Fidelity 6502 ("single-speed Sally") — time-native cycle-exact core
Design: **docs/Design/fidelity-6502.md** (a FRESH core built around ~56 clk_sally per
machine cycle; debug first-class in the micro-schedule; resident alongside turbo xt6502
per docs/Design/dual-cpu-resident-mux.md). Refs: MOS datasheet
(refs/mos_6501-6505_mpu_preliminary_aug_1975.pdf) governs the core cycle; the XL PBI gif
(refs/XL-bus-timing.gif, ~worst-case) governs the expansion boundary.
- **Phases 1–3 DONE**: `hdl/xt6502f/xt6502f.sv` — cycle engine + `sub`-slotting + RDY halt,
  and the **entire ISA cycle-exact: all 256 opcodes pass Tom Harte** (documented + every
  illegal incl. NMOS decimal ADC/SBC, JMP($xxFF) wrap, SLO/RLA/SRE/RRA/DCP/ISC, ANC/ALR/
  ARR/XAA/LXA/SBX, KIL/JAM lock-up, unstable SHA/SHX/SHY/TAS/LAS). Harness: `sim/tb_xt6502f
  _harte.sv` + `sim/harte/{fetch,convert,run}.sh`; `sim/harte/run.sh` → "256 pass, 0 fail".
- **Phase 3 interrupts DONE** — IRQ (level, I-gated), NMI (edge-latched, one-shot), 7-cycle
  push+vector, B-clear pushed status, NMI hijack of BRK/IRQ, RTI. Directed bench
  `sim/tb_xt6502f_irq.sv` (all pass); Harte ties the lines inactive so the ISA is unaffected.
  Refinements left: exact Φ2 sample slot (CLI/SEI/PLP one-instruction delay) + RESET-as-
  interrupt sequencing.
- **Phase 4 debug slots DONE** (RTL + sim) — `hdl/xt6502f/xt6502f_debug.sv`: two coherent
  sample windows (early cycle-entry / late settled), break-before-execute PC bkpt + data wp
  (halt drives cpu_halt -> rdy-gate), single-instruction step, per-cycle trace ring.
  Bench `sim/tb_xt6502f_dbg.sv` (all pass). Left for Phase 5: wire cpu_halt/bkpt/wp/trace to
  the GP0 DEBUG block + `/bin/6502` cycle-level additions once the core is in the SoC.
- **Phase 5 SoC integration BUILT + TIMING-CLOSED** — the fidelity `xt6502f` is resident in
  `fpga_xt_top` alongside turbo `xt6502`: `cpu_*` is the muxed active-core bus, `cpu_sel`
  (=`sallyrst[1]`, 2-FF synced) picks the owner, default 0 = turbo (shipping system
  bit-identical). Free-running phi2 window (N=56) + busy-aware `mem_ok` gate (SUB_DATA=49) +
  /HALT. **Bitstream closes: clk_sally WNS = 0.000 ns** (the binding-path 2:1 mux — mux doc
  §5 — closes, but at ZERO margin). `vivado/build/fpga_xt_top.bit` built (Explore).
  - Handoff FSM `cpu_handoff.sv` (sim-proven) is NOT yet wired in — this build just proves
    residency + mux timing, and lets the OS boot on either core (set `sallyrst[1]` before
    releasing SALLYRST).
  - **HW VALIDATED 2026-07-18:** turbo unchanged (desktop boots); `6502 core fid` boots the
    real Atari OS to READY on the cycle-exact core at 1x. Needed one fix: sally_mem.rdy must
    follow the ACTIVE core (its read-latch + writes + bank/peripheral strobes are rdy-gated) —
    fid drives a single early-window pulse. `/bin/6502 core [turbo|fid]` switches live.
  - **Follow-ups:** clk_sally has zero slack — if HW is marginal, retime the mux into the
    shared MAR D-input (mux doc §5.1) to reclaim margin. Then wire cpu_handoff (live switch;
    turbo snapshot via cdbg_* raw taps, inject via idbg_* muxed with xt6502_debug) + the
    fidelity debug to a GP0 block. Turbo specialization (§0a) deferred per the user.
- **Phase 6** — HW bring-up: cold-load, run the OS/games on the fidelity core, chase the
  fidelity backlog (magenta palette, garbled tiles, input) ON the right core.

## In-fabric 6502 debugger (branch `debug`) + XL app-launch
The debugger is BUILT and HW-PROVEN: `/bin/6502 status|halt|go|step N|break $A|
break off|breakreset on|off|reset|REG=VAL...` (halt via non-destructive rdy-gate,
single-step, PC breakpoint, register snapshot + injection), GP0 DEBUG block
(0x8xx), `xt6502_debug.sv`. Closed timing (clk_sally WNS +0.001). `/bin/xlboot`
launches an ATR from the CLI. Docs: `docs/OS/6502-debug.md`. Tag `pre-6502-debug`
on `main` is the fast baseline; sel 0x9 + DBG_BEAM reserved for the future ANTIC
debugger. **Next tools (user's roadmap):** ANTIC recorder + waterfall diff; 6502
AND ANTIC breakpoints; step DLIs with beam position (wire DBG_BEAM).

**XL app-launch — WORKING END-TO-END 2026-07-18.** `xlboot DespatchRider.atr` boots:
HW dmesg shows SIO STATUS ($53) + READ ($52) of boot sectors 1..$27 into $0400 via
the doorbell→SIO-mailbox→A9 SIO worker, all st=01; the 6502 runs boot+game code
(351 distinct PCs). Two real blockers, both found with the new debug tools:
1. **Bulk ROM-window upload dropped the OS patch.** `sally_rom_loader` does NOT
   back-pressure; a tight 49 KB `romwin_write` store loop outran its depth-4 CDC
   drain and dropped all but the tail ($FFFC-$FFFF), so the reset stub never landed →
   reset fetched $00=BRK → derail. FIX (kernel): pace `romwin_write` (dsb + spin per
   byte). *(RTL follow-up: give the loader real WREADY back-pressure.)*
2. **OS ROM self-checksum** rejected the patched image → self-test. Coldstart $FF73
   sums $C002-$CFFF+$5000-$57FF+$D800-$DFFF vs $C000/1, $FF92 sums $E000-$FFF7+
   $FFFA-$FFFF vs $FFF8/9; mismatch does `LSR $01`→$01=0→`JMP $5003` self-test. Our
   patches break both. FIX: `fix_os_checksums()` re-points $C000/1 and $FFF8/9 by the
   patch delta. FOUND via `6502 watch $01 w`. See [[xl-app-launch]].
- The earlier NMIEN/IRQEN/PORTB "fixes" were DERAIL AFTERMATH, not the cause — kept as
  valid hardening. The self-test was corruption, not a coldstart decision, until (2).
- **Debugger: breakpoint is reliable** (was never broken — earlier misses were the
  derail aftermath + incoherent run-state PC reads). Added `6502 diag` (self-observability)
  and a **data watchpoint** `6502 watch $A r|w|rw` (DBG_WP/WPCFG). Build #7 clk_sally
  WNS +0.154. Docs: `docs/OS/6502-debug.md`.
- Gotcha: rom_we (ROM-window) writes commit to the CPU's mem[] fine while SALLYRST is
  held, BUT a fast burst overflows the loader FIFO (see blocker 1); pace it.
- Branch hygiene: debugger + all fixes live on `debug`; cherry-pick to `main`.
- **Next tools (user roadmap):** ANTIC recorder + waterfall diff; 6502 AND ANTIC
  breakpoints; step DLIs with beam position (wire DBG_BEAM).

## Open Issues (tracked bugs)
- **Retire the per-switch `TLBIALL` sledgehammer (residual stale image-region TLB entry).**
  `vm_switch` does a full `TLBIALL` on every process switch as a robust backstop for HW
  scp/ssh crashes (conflicting/stale TLB entries over image-region section `0x29`: scp
  takes a recurring PL0-none prefetch-fault storm; dropbear reads its GOT through a stale
  entry → PLT jump to ~`0xffffffff`). Robust (16× 19 MB scp, zero faults) but taxes every
  context switch with a cold-TLB refill (negligible for long jobs; up to ~10–25 % for
  high-switch-rate workloads — shell pipelines, many short-lived programs, chatty IPC).
  **Investigated (ssh-server):** the crash values cluster at ~`0xFFFFFFFF` = the fingerprint
  of an A9 **conflicting TLB entry** from a **break-before-make violation** — live remaps
  wrote a new valid descriptor over a live valid one. Fixed BBM at `vm_cow_map`,
  `vm_cow_read_fault` reseed, and `perproc_l2`'s L1 swap: this **materially helped**
  (dropbear crash went immediate→rare, and the GOT read went silent→a *serviceable*
  permission fault) but did **not** fully eliminate it — a residual conflicting-entry path
  survives (suspect: section-`0x29` **code**-page entries, given scp's `[pabt]` storm
  persists through BBM + the `perproc_l2` TLBIALL). So BBM is KEPT (correct + reduces the
  problem) and the sledgehammer STAYS as backstop. Next: chase the residual — likely a
  code-page remap/speculation in section `0x29` not yet going through BBM, or eliminate the
  global `SEC_KDATA` 1 MB sections over the image region (mmu.c) so nothing can conflict.
  RULED OUT: `perproc_l2` missing-invalidation alone; MAXSEC exhaustion (dropbear needs
  only libc); the `cowdiv` scanner (false positives — flags legit large `.data` values).
  *(src: loader/test/freertos/vm.c `vm_switch` + the BBM sites; branch ssh-server)*

- **Signals belong in the kernel, not the user-space shim (fixes the ambiguous
  `read`/`signal`/`sigaction` bind).** A standalone `.so` that references
  `read`/`signal`/`sigaction` can bind them **ambiguously across the libc/shim
  boundary and fault**. Root cause: `libs/posix_shim.c` implements POSIX signals
  in **user space** with **synchronous delivery** (handlers in a user-side table;
  delivery happens inside the shim's *wrapped* `read`/`wait`/… at syscall
  boundaries), while the kernel's only signal primitive is a `SYS_kill` **flag**
  checked at the next syscall/blocking tick. That couples the three — `read()` has
  to be the shim's version to be a delivery point — so when the dynamic loader
  binds the **shim's `sigaction`** but **libc's `read`** (or a test `.so` brings
  its own), the register-side and deliver-side desync → handler never fires, or a
  wrapped `read` touches shim state libc never set up → fault. **This is the whole
  SSH SIGCHLD/fake-vfork saga's root class** (synchronous user-space signals are
  fragile because delivery is smeared across every blocking wrapper). Two
  independent fixes, do BOTH:
  1. **Symbol hygiene (immediate, cheap).** One definition per symbol in the
     global dynsym scope: shim internals `hidden`/local; the shim is either the
     sole provider or defers to libc, never both; `xtld` binds with deterministic
     precedence (single global libc, `RTLD_LOCAL` for the standalone `.so`). Kills
     the ambiguity even before touching signals.
  2. **Kernel-delivered signals — DONE (2026-07-10, commit 9aba845).** Real
     per-process disposition table in the kernel + rt_sigaction/rt_sigprocmask/
     sigreturn/sig_async syscalls + a hidden sigreturn trampoline. All three
     delivery paths qemu-validated (`/bin/sigtest` 3/3): sync at syscall-return,
     ASYNC into a CPU-bound loop (tick-return hook), and EINTR of a blocked syscall.
     **desktop-can't-kill is FIXED** — it blocks in `aes_wait` (a syscall), so EINTR
     now delivers. Full design + ABI: docs/Design/process-signal-model.md.
     Kernel SIGCHLD-on-exit + SIGWINCH + soft-dispatch removal DONE (ed61752),
     symbol dedup DONE (fc6fe7d, libc-hide.map), and SA_RESTART DONE (2026-07-10 —
     kernel returns XT_ERESTARTSYS, __syscall re-issues; sigtest 5/5). Signals are
     feature-complete (sync/async/EINTR/SA_RESTART/SIGCHLD/SIGWINCH); HW-validated
     end to end — sigtest **5/5 on HW** (test 5 SA_RESTART restart included).
     newlib-pic provenance DONE: newlib-pic.stamp golden +
     `make newlib-check` + `make newlib` version-upgrade path (085e5bf, 735d87f).
  The shim still has a legit job afterwards (the POSIX *shape* newlib lacks —
  `opendir`/`readdir` over `getdents`, stdio buffering, `spawn`/`wait`, termios —
  none of it `read`-coupled). Cost/why-not-done-first: real frame-injection
  delivery (EINTR-ing a blocked FreeRTOS task + sigreturn) is more work than the
  user-space synchronous shim that got toysh/dropbear up. *(src:
  loader/test/freertos/libs/posix_shim.c; frtos_os.c `SYS_kill` kill-flag;
  branch ssh-server — the SIGCHLD/vfork fixes are symptoms of this)*

## Post-architecture-review
- none

## HW / RTL bring-up
- none

## Video / compositor / sprites / textures
- none

## Audio (PCM1808 capture + HDMI audio)
- **FPGA SCKI for the PCM1808 (the carrier's one new audio clock)** — the SiI9022A
  is MCLK-less (takes only BCLK/LRCLK/DATA), so no master clock exists in the design
  today. The PCM1808 *requires* a 256 fs SCKI. **Generate 12.288 MHz in the FPGA
  (MMCM) and route it out to the carrier as the PCM1808 SCKI**; derive BCK (÷4 =
  3.072 MHz) and LRCK (÷256 = 48 kHz) from that *same* domain so SCKI/BCK/LRCK stay
  synchronous (else the ADC resync-mutes). Make that 12.288 MHz MMCM the single root
  for the SiI9022 BCLK/LRCLK too, so capture and playback are sample-locked. *(src:
  docs/OS/pcm1808-audio-in.svg)*
- **Repoint `pcm1808_rx.sv` off `clk_bus`** — today it derives BCK/LRCK from
  `clk_bus` (fractional-N); move them to the 12.288 MHz MMCM dividers. Fix the stale
  header comments ("slave mode, no SCKI", "FMT0=0,FMT1=0" — PCM1808 has one FMT pin;
  FMT must strap HIGH = left-justified). *(src: pcm1808_rx.sv, pcm1808-audio-in.svg)*
- **Add `adc_sclki_o` + `adc_sdata_i` top-level pads + carrier pin assignment**, and
  the per-channel analog front-end (1 µF DC-block + 100 Ω + 1 nF; VCC 5 V / VDD 3.3 V;
  MD0=MD1→GND). *(src: pcm1808-audio-in.svg)*
- **HDMI audio islands** — route the POKEY I²S stream out over the SiI9022A's audio
  islands (BCLK/LRCLK/DATA path; MCLK-less). *(desired; not on critical path; src:
  docs/HDMI/hdmi.md, docs/Zynq/FPGA.md)*
  
## Memory / banking (DDR3 banked window — parallel track, not on boot path)
- none

## SIO / PBI / cartridge / companion MCU
- **HW: PB2/BOOT1 is unconnected** — datasheet-confirmed (DocID026289 Rev 7 Table 8:
  PB2's only additional function is BOOT1, and it has no reset-state pull). With no
  net, the level is undefined, so "FPGA raises BOOT0 and pulses NRST to reach the
  AN3155 ROM bootloader" is a coin flip between system memory and embedded SRAM.
  Fix: **10K from PB2 to GND** (firmware now parks PB2 as an analog input so it can
  never drive the pin). Blocks the UART firmware-update path; SWD is unaffected.
  *(src: motherboard/README.md)*
- **Companion: own bootloader as the durable answer to BOOT1** — a resident loader in
  flash sector 0 that takes images over USART2 and self-programs makes BOOT0/BOOT1
  irrelevant, and lets us checksum + validate + fall back rather than trusting the
  ROM protocol. Must never overwrite itself and must refuse an invalid app image.
  Alternative to the 10K bodge, not a replacement for it.
- **HW: confirm HUB_RST polarity on PA9** — firmware assumes active low
  (`HUB_RST_ACTIVE_LOW` in `motherboard/firmware/src/board.c`). Check the hub page
  of the schematic before debugging a failed enumeration.
- **HW: USB hub has no clock — Y2 is an active oscillator in a passive-crystal
  footprint.** ROOT CAUSE, confirmed 2026-08-12 **by JLCPCB** (the fitted part is
  **YXC OT2EL4C4JI-111OLP-24M**, LCSC category *Crystal Oscillators*, spec
  "1.8V~3.3V 24MHz CMOS" — an **active XO**). Note `hw/bom-match.csv` happens to agree
  but is NOT evidence: see the staleness item below. The schematic wires Y2 as a passive
  crystal (pin1 -> XTALIN, pin3 -> XTALOUT, **pins 2 and 4 to GND**), which grounds an
  XO's **VDD**: it has never been powered, so the USB2514B has no 24 MHz reference.
  Explains the symptom exactly — pads/bias/reset run off 3V3 so the hub holds up its
  D+ pull-up and obeys HUB_RST, but the USB core cannot run, so SETUP is never
  answered. The Altium BOM intended `RH10024000181020EXTTR` (Raltron RH100-24.000-18,
  a passive 18 pF crystal); the substitution happened at BOM-match time.
  **Fix: fit a passive 24 MHz crystal.** C29/C30 = 18 pF present ~10 pF of load, so
  CL ~10-12 pF is the best match (the original 18 pF part also works, ~+90 ppm fast vs
  the +/-350 ppm allowed). Contrast Y1 (8 MHz, STM32): category *Crystals*, 8 pF — a
  real crystal, which is why HSE locks. **Audit the rest of bom-match.csv for the same
  class of substitution.**
  Everything else on the hub sheet was verified clean against Microchip's design
  checklist (DS00004541) and the USB251xB datasheet: RESET_N 10K+1uF active low exactly
  per Fig 7-2, RBIAS 12K 1%, CFG_SEL[1:0]=00 (straps enabled, self-powered),
  NON_REM=00, 0.1uF per supply pin + 1uF bulk, CRFILT/PLLFILT 0.1uF ("up to 0.1uF, or
  unconnected"), VBUS_DET via 100K to 3V3 ("permissible"), TEST to GND ("no connect or
  connect to ground"), ePAD grounded with 3 vias, DP/DM correctly oriented, and
  TPS2051B enable active-high as Microchip requires.
  *(src: motherboard/README.md)*
- **`hw/` describes the PREVIOUS board spin, not the one on the bench** — the BOM,
  pick-and-place and gerbers there are the 2026-07-16 carrier manufacture package.
  Do not cite them as the assembly record for the current board; ask for the current
  outputs, or get them from JLCPCB. (Same trap as [docs/carrier].)
- **Companion: HID -> POKEY routing — keyboard DONE, mouse pending.**
  `motherboard/firmware/src/keymap.c`. Every HID usage has **two independently
  settable entries** (unshifted, shifted), so a Desktop app can assign anything to any
  keypress; the firmware only ships starting points. Two are built in:
  **POSITIONAL** (the PC key in a place presses the Atari key in the same place —
  shift-2 gives `"`, because that is what the Atari's 2 key does) and **SYMBOLIC**
  (the symbol on the key you press is what you get — shift-2 on a US keyboard gives
  `@`, which the Atari makes with shift-8). Symbolic is the right basis for
  international layouts, where positions do not correspond at all. Default is
  positional; `key layout [positional|symbolic]` switches.
  Entries hold a COMPLETE Atari code (shift folded into bit 6 where the layout needs
  it), so the shifted column is a lookup rather than a modification. All KBCODE values
  come from the machine's own ROM — **TCKD** at $FB51 in
  `refs/OS-xl-rev-2-Disassembly.lst` — which is also the authority for the modifier
  bits: **shift is bit 6, ctrl is bit 7**.
  Desktop upload: `SPI_REG_KEYMAP_CTL` selects a column (and rewinds), then
  `SPI_REG_KEYMAP_VAL` streams 256 bytes auto-incrementing; two passes load a whole
  layout. CTL can also reload either built-in.
  Non-matrix keys are handled as what they are: **START/SELECT/OPTION** drive
  `SPI_REG_CONSOL` (active-low, matching `XT_CTRL_CONSOL`) and are rebuilt from every
  report because the 6502 reads them as levels; **BREAK** and **RESET** are events on
  `KBD_STAT`; **HELP** is a real KBCODE ($11). Console keys on F2/F3/F4 and keypad
  +/-/* (the xtmouse convention already in CTRL_CONSOL), RESET F5, HELP F6, BREAK
  F7/F12; arrows use the ctrl-combinations the real keyboard uses.
  Remaining: mouse deltas, the FPGA side consuming CONSOL + the reset event, and the
  Desktop-side keymap editor.
- **Companion: paddle calibration** — endpoints are computed for 1 MOhm x 47 nF
  (0..33000 us); measure against a real paddle and set with `pot cal <lo> <hi>`.
- **SIO: PIA CA1/CA2/CB1/CB2 control lines** — PROCEED/MOTOR/INTERRUPT/COMMAND in
  `pia_regs.sv` store bits but drive nothing; implement + add the pad/GPIO path.
  *(main remaining SIO RTL; src: docs/OS/sio-bridge.md)*
- **SIO: re-point peri link at STM32F411** — `peri_bridge.sv`/`peri_link.sv` SPI still
  targets the RP2354. Decide COMMAND treatment (dedicated GPIO vs SPI status byte) and
  SERIN-IRQ pacing policy. *(src: docs/OS/sio-bridge.md)*
- **Retire PCAL9722 joystick RTL** — remove `joy_link.sv`/`joy_bridge.sv`; fold joy/
  button fields into the peri SPI register map. *(src: docs/OS/sio-bridge.md)*
- **PBI bridge (build steps 1-7)** — plumb M-PBI outputs to pads → bidir `D[7:0]`
  IOBUF → `/CARDSEL` decode → input syncs (/IRQ,/RDY,/HALT,/RST) → 1× bus-window FSM
  → `/MPD` shadow mux ($D800-$DFFF) → `pbi_active` dynamic slowdown. Blockers to
  confirm first: exact `/MPD` shadow range + $D1FF select/IRQ semantics; the
  slowdown mechanism (clk_sally force-1×, see next bullet); `pbi_active` timeout
  value; carrier PCIe-×4 pinout +
  level-shifter OE. *(src: docs/OS/expansion-options.md)*
- **PBI slowdown = a clk_sally `force_1x` override, NOT a software `$D4CA` poke** —
  the software `clock_mult` path can't slow a *single* PBI access: it has CDC latency
  (clk_sys → 2-FF → clk_sally), so "poke 1× then access" lands several cycles late and
  the CPU may already have run the access at turbo → the PBI device sees a too-fast
  cycle (a real failure, not just a step-cadence glitch). Robust design: decode the
  PBI access in **clk_sally** (the CPU's own domain — no CDC) and drive a `force_1x`
  into `sally_clock` that overrides `clock_mult` to 1× for the access and reverts
  after — zero-latency, deterministic, inherently glitch-free. The software
  `clock_mult` stays the turbo *ceiling*; the override is transient on top
  (`max(force_1x ? 1 : clock_mult)`). Precedent: `auto_phi2_on_extirq` /
  `extirq_fallback` already force 1× on a condition, but those live in clk_sys — fine
  for a sustained IRQ, too slow for a single-cycle access. Open: does `$D4CA`
  read-back report the ceiling or the momentary force-1×? (lean: the ceiling).
  *(design decided 2026-06-26; src: docs/OS/expansion-options.md §8)*
- **PBI device-RAM window ($D600-$D7FF) is undesigned** — the bridge covers the
  `$D1FF` select and the `/MPD` `$D800-$DFFF` device-ROM shadow, but not the
  card's RAM/scratch window, which needs the same suppress-and-route mux keyed on
  addr ∈ `$D600-$D7FF` + selected.  Also the reason no XT register may ever be
  allocated there: the range is contested by PBI device RAM, MIO/BlackBox RAM,
  Covox and both VBXE install windows (`$D640-$D65F`, `$D740-$D75F`).
  *(src: docs/OS/expansion-options.md §6; ecosystem table in docs/Zynq/register-map.md)*
- **Cartridge "run" support** — suppress internal memory on RD4/RD5, drive /S4//S5,
  take read data from the cart, route $D5xx out /CCTL for bank-switching. *(same Tier-B
  work as /MPD shadow; src: docs/OS/expansion-options.md)*

## GEM (VDI + AES) / desktop
- **gemd M7: board visual/perf pass (code landed + gate/engine proven 2026-07-17)** —
  the engine composite (cached CONTIG surfaces + driver-owned coherency) and the
  SEC_PLANE gate (display-owner grant via first SYS_fb_wallpaper; syscall + blitter
  legs) are in; fbgrab fault-kill and the full blittest matrix passed on the board.
  Remaining: eyeball the desktop on the textured wallpaper (drag/resize feel — expect
  the ~4× composite win), emulator window still perfect (M6 plane bind now runs under
  the owner check). Follow-ups when someone wants them: ASYNC present + in-flight-rect
  tracking (the present is deliberately synchronous); gemd's `wind_set_overlay` onto
  the HW drag overlay (DRAG_BASE is gemd-private now — a free win); profiler
  recoverable via `make INSTRUMENT=1`. *(src: gemd-plan.md §M7)*
- **VDI dispatch layer (Phase 1, keystone)** — opcode wire format + 6502-side VDI
  library + N6 DRAW dispatcher + palette expansion + inquiry RPCs. *(highest priority;
  everything depends on it; src: docs/GEM/GEM-implementation.md)*
- **AES layer (Phase 2)** — `Window` class, event queue (HID→N6→6502), dialogs, menu
  bar, file selector, `.RSC` loader. *(after Phase 1; src: GEM-implementation.md)*
- **GEMDOS via FMC RPC (Phase 3)**, **Desktop + sample apps (Phase 4)**, **Polish
  (Phase 5)** — clipboard, drag-drop, file associations, DRAW batching, font-cache,
  multitasking model. *(src: GEM-implementation.md)*
- **Desktop media-change reaction (plumbing DONE, UX TODO)** — `desktop` already
  receives `XTOS_MEDIA_CHANGE` (the kernel broadcasts it on SD insert/remove;
  delivered as a normal `MU_MESAG` via `evnt_multi` — commit a721d3b). Current
  handler is a placeholder that just logs `[desk] SD removed/inserted` to dmesg.
  TODO: the real UX — when the card leaves (`msg[3]==0`), grey out / close windows
  rooted on `/media` (browsers, file windows) and stop in-flight SD reads; on
  reinsert (`msg[3]==1`, `msg[4]`=volume) restore/refresh them. The one-line switch
  case is all it takes to act; the plumbing hands over the event. Same pattern will
  serve future `XTOS_*` system events (net up/down, temp alarm, low memory). *(src:
  gem/aes/aes.h `XTOS_*`, loader sd.c `media_change_msg`, desktop.c handler; memory
  gem_xtos_messages)*
- **VDI op gaps** — define reserved/extended-colour ops ($0xC0-0xFE, RGB-direct
  0xC1-0xCF); N6 form/bitmap cache mgmt; font-ID→`lv_font_t` table; bezier-quality
  (escape 99) mapping; `vr_trnfm` behaviour; multi-plane forms. *(src: docs/GEM/VDI-opcodes.md)*
- **VDI SW primitives (future)** — `v_ellipse`/`v_ellarc`/`v_pieslice` (no HW ellipse);
  `v_fillarea` scanline polygon-fill; monospace line-batching (CMD=0x05); italic shear
  FSM; affine-transform blit for rotated text. *(src: docs/GEM/vdi-sw-implementation.md)*
- **Pre-lock risk mitigation** — inventory the full FreeGEM/EmuTOS VDI op set before
  freezing the wire format; wire one full vertical slice (`v_pline`→PSSI→N6→LVGL→
  screen) + profile fill-rate / FMC RPC roundtrip early; verify xcc stdlib gaps
  (`Array<Window@>`, `weak:` in collections). *(src: GEM-implementation.md)*
- **Open GEM decisions** — font-render boundary (N6-rasterises vs 6502 glyph cache);
  `.RSC` format (reuse ST vs native); VBI 50 Hz-vs-60 Hz tick mismatch; per-frame DRAW
  batching; multitasking model (cooperative vs preemptive). *(src: GEM-implementation.md)*
- **ARM-native xcc GEM client** — lands once the xcc-ARM backend lands. *(src:
  docs/GEM/gem-service-abi.md)*
- **Desktop redraw de-jerk (software-first, ordered)** — (1) GEM rectangle list +
  clipped `WM_REDRAW` (foundation); (2) `wind_scroll(win,dy)` HW backing-store move;
  (3) plane-body-move fast-path. Optional RTL (4): odd-X horizontal lane mux +
  reverse-direction BLOCK_BLIT. *(src: docs/OS/desktop-redraw.md)*

- **Opaque window movement — Geneva message model OVER the HW overlay (design
  decided).** Adopt Geneva-style opaque dragging (all windows move with content,
  continuous `WM_MOVED`) but layered on our HW drag-overlay, NOT Geneva's software
  repaint — the overlay stays the rendering engine so we NEVER reintroduce
  per-motion plane writes (that DDR-burst starvation is what drops the SiI9022 HDMI
  link — the whole reason the overlay exists). Bottom-up (needs the rectangle list
  from item (1): the AES enum stops at `WF_FULLXYWH`, no `WF_FIRSTXYWH`/
  `WF_NEXTXYWH`, so no per-window visible-rect clipping today):
  - **Continuous `WM_MOVED`** (per-motion, not one-shot-at-release like stock TOS /
    our current `window.c`). The real work is making `wind_drag()` NON-BLOCKING
    (main-loop-driven, feeding `WM_MOVED` concurrently) instead of the current
    nested blocking loop — and it's in the SHARED `gem/aes/window.c` (retest the SDL
    host too).
  - **Message discipline (HDMI-safe by construction):** `WM_MOVED` → update coords
    (`wind_set WF_CURRXYWH`) + reposition any LIVE plane the app owns (emulator:
    `xl_sync`, a register write) — NEVER redraw. `WM_REDRAW` → the ONLY place a GEM
    app paints, ONE-SHOT at the drop, dirty-rect clipped. Nothing but register
    writes is per-motion → no plane-write storm.
  - **Capture-correctness guard (NOT just an optimization):** at drag-start the
    dragged window's rectangle-list count is the branch. `nrects==1` = fully visible
    = the back-buffer already holds ITS content at its rect → capture into the
    overlay as-is, zero pre-redraw. `nrects>1` = partially covered = the back-buffer
    holds the COVERING window's pixels in the covered sub-rects → MUST raise+redraw
    first, else the overlay drags foreign pixels (visible corruption). So:
    `nrects==1 ? capture_now : raise_redraw_then_capture`.
  - **Z-order = raise-and-keep** (drag promotes to top; standard, and the drop
    redraw is then just the window's new area + the vacated region clipped to the
    underlying windows' newly-visible rects). Restore-original-z is possible but
    costs a stack recomposite + `WM_REDRAW` to every window that should re-occlude
    the drop — skip unless stacking-preserving drag is specifically wanted.
  - **Already shipped (today, without the rect list):** the HW overlay + the
    per-motion `ovl_move → xl_sync` hook already give opaque drag + live XL-plane
    tracking (commit a02204c); capture-correctness is handled crudely by the
    two-click "top-then-drag" (first click raises + full-redraws → forces fully
    visible before the second click captures). The Geneva model replaces that with
    one gesture + the `nrects==1` fast path once the rectangle list lands.
  *(src: docs/OS/desktop-redraw.md; Geneva `WM_MOVED`/`WM_REDRAW` packet layout;
  depends on item (1) rectangle-list foundation)*

## App launch (desktop → XL realm)

- **RESOLVED — ElektraGlide boots and runs.**  Three defects, in the order they
  were peeled off.  (1) `sally_mem`'s RAM write was not gated on the math/SIO
  aperture, so an aperture write shadowed into the guest RAM underneath — the
  stub burned its 12-byte DCB at `$4040-$404B` plus `$5A` at `$4005` into the
  running game on EVERY sector (regression `tb_sally_math_overlay` T5).  (2) The
  mailbox was reached through the `$D5C6.0` aperture over `$4000-$5FFF` — the
  guest's own RAM — held mapped across the whole A9 round-trip, so any interrupt
  in that window ran with the guest's memory replaced; it is a **register port**
  now (`$D5CD` index / `$D5CE` data, `hdl/xt_sio_mbox.sv`), which also took
  clk_sally from +0.570 to +0.907.  (3) The actual killer: `xl_boot.c` delivered
  sectors through the **ROM window while the 6502 was running**.  `sally_mem`
  shares one BRAM port between the CPU read and the ROM-load write
  (`mem_addr_w = rom_we ? rom_addr : addr`, and `bram_dout_q <= mem[mem_addr_w]`),
  so a `rom_we` in the same clk as a CPU read handed the CPU the byte at the
  ROM-window address — a corrupted opcode fetch.  That window is only safe with
  SALLYRST asserted.  Despatch Rider delivered 3 sectors that way and survived on
  odds; ElektraGlide streamed ~340 and could not.  Payloads now always come back
  through the mailbox.  Soak: icnt linear 5.4M->41.9M over 80 s, title screen
  renders, 3/3 cold boots identical, DR unaffected.
- **Still worth doing, no longer urgent:** the A9 cannot write SALLY
  `$0000-$0FFF` (the ROM-loader window maps GP0 `$1000-$FFFF` 1:1 and
  `$0000-$0FFF` belongs to `xt_gp0_regs`).  That is now moot for SIO — everything
  goes through the mailbox — but a poke path in `xt_gp0_regs` driving the
  existing `rom_we`/`rom_addr` port would still be useful for A9-side debug.
  **It must never be used against a running 6502** for the reason above.
- **BallBlazer intro: OPEN. Root cause NOT found. Read this before resuming.**
  The game PLAYS PERFECTLY; only the intro misbehaves, deterministically: two
  objects on screen where there should be one, a vehicle that stalls instead of
  sweeping, a ball that never crosses, and a persistent 4 px bar at the left edge.

  **VERIFIED CORRECT — do not re-test** (each by a minimal repro validated
  against Altirra first): HPOSP writes in VBLANK (`pmsweep.xex`) and MID-LINE
  (`hpmid.xex`, x=32 top / x=224 below, identical to the reference); players
  parked at HPOS $00/$08 invisible on both (`hp0.xex`); P/M-to-P/M collision
  (`tools/pcoll2.xex` decodes P2PL = $08 = player 3, using a needle validated
  against a known constant in the same run); GTIA mode 9 basic rendering; P/M
  DMA and its addressing (PMBASE=$2C single-line -> region $2800, missiles
  $2B00); 6502 RAM cleared at boot; disk DATA (gameplay is flawless); ACID800
  55 pass / 8 na / **0 fail**.

  **FIXED ALONG THE WAY (real, but NOT this bug):** the paravirtual SIOV service
  answered a sector in 775 instructions where a real drive takes ~62,000 — 80x
  too fast. Now derived from link rate + rotational latency, off by default,
  per-title via `xlboot -a` (SYS_sio_timing). The user confirmed it changed
  nothing visually.

  **SHARPEST SYMPTOM (2026-08-14, from watching it):** motion WITHIN a sequence
  is SMOOTH -- so HPOS writes, P/M DMA and per-frame animation are all fine.
  What breaks is SEQUENCING: objects vanish mid-scene, a different set of PMGs
  takes over and animates, scenes jerk into one another, and whole scenes (the
  man getting out of the vehicle and waving) never play. Combined with the
  left-edge bars each having THE SAME VERTICAL EXTENT as the object at that
  height, the leading hypothesis is now:

    a player is painted at x~=0 IN ADDITION to its real HPOS, on every scanline
    where its shape is non-zero -> the bars; two overlapping there -> the weird
    colours when a PMG crosses one; and the same spurious image produces
    SPURIOUS COLLISIONS, which corrupt an attract-mode state machine that is
    driven by collision registers -> scenes abort early and the script jumps.

  Gameplay surviving fits if the artifact is specific to the intro's display
  mode (GTIA mode 9) rather than the gameplay mode. TEST THIS IN SIMULATION
  FIRST -- render a mode-9 frame with a player at a known HPOS and look for
  pixels at x~=0; no board needed, and the compositor testbenches already exist.

  **TIMING IS EXONERATED, TWICE.** The SIOV model (g_siov_baud) was calibrated to
  100% of reference and changed nothing because a FAST LOADER NEVER CALLS SIOV
  (xl_boot.c:514) -- it was pacing a path this title never enters. Rotational
  latency on the serial-bus path (g_sio_rot, the path it DOES use, ~1 ms -> a
  real drive's ~130 ms) then also changed nothing visible. Do not spend more
  time on drive timing for this bug.

  **P/M CAPTURE, 2026-08-14 (validated channel).** Traced on hardware with
  `6502 dtrace` 45 s in (a trace at 6 s catches only the loader), decoded with
  tools/trace_writes.py against a CORRECTLY BOOTED Altirra. In the captured
  window EVERY player and missile is PARKED OFFSCREEN WITH ZERO GRAPHICS:
  HPOSP0=$F9, HPOSP1=$00, HPOSP2=$FC, HPOSP3=$FC, all HPOSM=$00, all SIZE=$00,
  and GRAFP0-3 + GRAFM all written $00 (constant, ~22 times each). COLPF0/COLPF1
  take 1995 writes each (DLI colour work), so the display list IS running.

  Reading: the game is CLEARING P/M and parking everything; the man is never
  POSITIONED. So he is not being suppressed by our renderer -- the game never
  places him. That points UPSTREAM (script/protection path), not at GTIA.
  NEXT: capture the same window from Altirra and diff the P/M register writes;
  if Altirra positions a player where we park one, the divergence is upstream of
  the renderer and the code path that decides it is the target.

  **THE DIVERGENCE, MEASURED (2026-08-14). Altirra uses the FIFTH PLAYER; we
  never enable it.** Read directly from Altirra's own state via the bridge's
  `pmg()` (no trace decoding, no operand guessing), sampled over 6 SECONDS to
  rule out phase mismatch -- it is steady, not a transient frame:

      Altirra: prior=$54 CONSTANT   -> bit4 = FIFTH PLAYER, bits7:6=01 = GTIA mode 9
               hposm = [$76,$74,$72,$70] held for 5 s, then MOVES AS A GROUP to
                       [$82,$80,$7e,$7c]  (four missiles, 2 apart, animated as ONE figure)
               hposp = $30/$50 -> $28/$48 -> $90/$b0 -> $08/$28 -> $f0/$10,
                       and at one point all four at $70/$78/$80/$88
               grafp = [$ff,$ff,$00,$00] (solid shapes on screen)

      OURS:    prior NEVER WRITTEN in the window; all four hposm = $00;
               all sizep/sizem = $00; GRAFP0-3 and GRAFM all written $00;
               hposp = $F9/$00/$FC/$FC (all parked offscreen), sustained ~22 frames

  So the missing figure is almost certainly drawn as the FIFTH PLAYER (the four
  missiles combined, coloured COLPF3, enabled by PRIOR bit 4), and on our machine
  that object is never positioned and PRIOR is never set. The renderer is not
  suppressing it -- the game never asks for it. NOTE the fifth player IS
  implemented in the live RTL (gtia_priority.sv `pm5 = prior[4]`), so this is not
  a missing feature; it is that our 6502 never runs the code that turns it on.

  NEXT: find the code that writes PRIOR/HPOSM on Altirra and determine whether our
  machine ever reaches it. Altirra PCs seen in that window: $3ab7 $3ad6 $3ae5
  $3b0c $3b12 $30c6 $31f4 $3296 $bf9f -- our hardware trace's hot pages were
  $5000/$4000/$8000/$B000/$A000 with NOTHING in $3xxx, which is the same $3xxx
  region the earlier "$37AE code Altirra never has" puzzle sat in. That $3xxx
  region is where this should be chased next.

  **CONFIRMED AT FULL SCALE (2026-08-14):** a complete 3 s capture written to SD
  root (NOT /tmp, which silently truncates at 1 MB) gave 1,308,432 instructions,
  DROPS=0, no truncation. Our machine executes **ZERO instructions in $3xxx**.
  Samples by page: $5000=358785 $4000=262387 $8000=222573 $B000=133742
  $A000=130838 $7000=67824 $6000=71543 $9000=54615 $C000=5914 $E000=211.

  And it is NOT the same routine relocated: the trace records the opcode at every
  PC, so a partial disassembly can be rebuilt from the trace itself with no
  memory-read tool. Altirra's $3AB0 sprite plotter (84 A5 85 A5 85 4A A9 90 A9 85
  A6 BD ...) matches NOWHERE in our 5314 executed PCs. The two machines are
  running STRUCTURALLY DIFFERENT CODE, not the same code at a different address.

  Note there is NO guest-RAM read aperture: XT_DBG_STRM_RADDR/RDLO/RDHI address
  the TRACE RING, not memory (xt_gp0_pkg.sv:105-107). Answering "does our RAM
  even contain the $3xxx engine" would need new RTL or a 6502 stub that copies
  memory into the SIO mailbox — do not start that on an unverified hypothesis.

  **CORRECTION + BIG RESULT (2026-08-14, later): the two machines AGREE THROUGH
  THE LOAD.** The "zero $3xxx execution" result above is true only of the INTRO
  window. Captured at t=2..6 s instead (the load/protection phase, 2,097,152
  entries, DROPS=0) our machine runs $3xxx HEAVILY: 1,598,953 samples in page
  $3000, code in three regions $3C4C-3C77, $3D86-3E90, $3EA1-3F37. ~61% of the
  window is SPIN LOOPS waiting on the drive -- $3D9E `LDA zp` / $3DA0 `BPL` alone
  is 481,899 samples, plus $3D86/$3D88 and $3DF2/$3DF4 -- which is CORRECT now
  that rotational latency makes the guest wait.

  Cold-resetting Altirra to catch its load phase and comparing: Altirra's own PC
  sits at **$3d88 and $3da0 -- THE SAME TWO SPIN LOOPS** -- and its memory matches
  our executed opcodes **18/18** across $3C40-$3D3F. So both machines run an
  IDENTICAL loader and are in lockstep through the load. The divergence is
  therefore AFTER the load, not inside it: $3xxx is later OVERLAID, on Altirra
  with the sprite engine ($3AB0 plotter, `lda $3950,X`, nibble masks) that sets
  PRIOR=$54 and animates the four missiles as one figure. On ours that overlay
  never runs. FIND WHERE THE OVERLAY IS LOADED/JUMPED TO -- that is the target.

  TOOL NOTE: alt has no `_command`, so TRACEFILE cannot be driven from the Python
  SDK that way, and tools/altirra_trace.py TIMED OUT at 500 s draining history
  (--frames 60 --step 1 --chunk 8000). Use alt.pmg()/alt.peek()/alt.disasm()
  state comparison instead of full-trace diffing until that is sorted.

  ############################################################################
  **THE SIM REPRODUCTION IS A NEAR-DROP-IN (2026-08-14).** The right harness
  already exists and targets the LIVE module: **sim/tb_antic_timing.sv** (267
  lines, `make -C sim antic_timing`). Do NOT use sim/tb_nmi.sv -- it instantiates
  `nmi_gen`, not antic_timing, so it cannot reproduce this.
  Existing cases: T3 = VBI NMIST bit 6 with NMIEN=$40; T4 = DL machine
  `70 70 70 F0 F0 41` giving DLI NMIST at lines 39 and 47 (the ACID antic_nmist
  anchor); T5 = vscroldli bracket. NOTE **$F0 IS DLI-FLAGGED** (bit 7 set on a
  blank line) -- that is how T4 produces its DLIs.

  ADD A NEW CASE MIRRORING OUR REAL DISPLAY LIST, which contains NO $8x/$Fx bytes:
        70 60 4F <lo> <hi>  then ~190x 0F  then 41 <lo> <hi>     (JVB to start)
        i.e. blank8, blank7, modeF+LMS, a run of modeF, JVB
  ASSERT, with NMIEN=$40: **NMIST bit 7 is NEVER set, and exactly ONE /NMI pulse
  occurs per frame.** If the RTL asserts bit 7 ~4x per frame, that is the
  reproduction of the hardware measurement ($C01D DLI dispatch x1608 vs $C020 VBI
  path x785).
  Then fix in antic_timing.sv -- look at what ARMS `nmi_arm_q` (:557 VBI, :575
  DLI) and what SETS the NMIST DLI bit (`nmist_hi` / `nmist_hold_q` around :405)
  when no DLI is requested. The fix MUST explain ~4 per frame, not one. Keep
  ACID800 green (55/8na/0fail; antic_nmist + the DLI cluster are the guard), and
  also re-run `make -C sim antic_dli_cdc`.

  ############################################################################
  **THE REAL INTRO NUMBERS (2026-08-14) — measured in bbt.bin, 99.3% page $3000,
  i.e. the PURE INTRO. This retracts the dropped-VBI claim and finds the actual
  gate.**
                              INTRO (bbt.bin)    multi.bin (game-mixed)
        $BC78 VBI entry            281                383
        **$BC80 SHORT (dropped)      0**                 31
        $BC85 FULL                 281                383
        **$3E00 `INC $C2`            53**                174
        $30CC spin             158,820             99,656
        $30DC `bit RANDOM`           1                  0

  **OUR VBI PATH IS 100% FULL IN THE INTRO — ZERO dropped VBIs, exactly like
  Altirra.** So "31 dropped VBIs / 92.5% vs Altirra's 100%" is GAME-PHASE data and
  is RETRACTED as an intro claim. Likewise "$30D0-$30E5 never execute" was
  multi.bin's story: in the intro `$30DC bit RANDOM` DOES run (once).

  **THE ACTUAL STARVATION:** 281 VBIs but only **53** reach `INC $C2` -- just
  **19%**. The VBI is not being dropped; the PATH TO THE TICKER is conditional and
  mostly not taken. At 53 ticks per 281 VBIs, reaching $FF (255 ticks) needs
  ~1350 VBIs = **~22 seconds**, which matches the long wait Simon sees.

  **THE QUESTION IS NOW SHARP AND NEW: why do only ~19% of VBIs reach $3E00?**
  The VBI chain is $BC78 -> $BC85 -> ... -> $BC8E `lda $CA / bne $BC95` ->
  `jsr $BDBA` ... -> $BC95 `lda $D9 / bmi $BC9F` -> $BC99 `jsr $BCEB` -> $BC9C
  `jmp XITVBV`, with the ticker reached via $BC8E -> $3DE0. Find WHICH branch
  gates it and what state it tests ($CA, $D9, and the `$3de0 inx / bne $3E0F /
  lda $C2 / bne $3DFC` entry itself). Then MEASURE THE SAME RATIO ON ALTIRRA at
  the same scene -- if Altirra reaches the ticker on most VBIs and we reach it on
  19%, that gap IS the bug, and it is about the state those branches read, not
  about interrupts at all.
  ############################################################################

  ############################################################################
  **RETRACTION #11 — THE DLI STORY DOES NOT APPLY TO THE INTRO (2026-08-14).**
  NMIST bit 7 measured DIRECTLY (not inferred from branch counts): `BIT $D40F` at
  $C018 sets N from bit 7, and the trace records P at retire, so scan for IR=$2C
  with next_pc=$C01B and read bit 7 of P.
        multi.bin (mixed/game)  2393 NMIs   1608 DLI-bit set  (67.2%)
        hand.bin  (handoff)     1910 NMIs   1078 DLI-bit set  (56.4%)
        **bbt.bin (TRUE INTRO, t=31-35 s, page $3000 dominated)
                                 281 NMIs      0 DLI-bit set  (0.0%)**
  **IN THE INTRO PROPER THERE ARE NO DLIs AT ALL.** All 281 NMIs are VBIs, which
  is correct behaviour. The DLIs are a GAME-PHASE phenomenon; multi.bin carried
  them because its page profile ($4000-$B000) is largely GAME, not intro.

  So the entire spurious-DLI chain DOES NOT EXPLAIN THE INTRO STALL, and the
  "1608 DLIs" figure must never again be quoted as an intro fact. Same root cause
  as most of today's retractions: attributing a measurement to the wrong window.
  The 31 dropped VBIs (92.5% vs Altirra's 100%) were ALSO counted in multi.bin
  and are therefore ALSO suspect as an intro claim -- RE-MEASURE $BC80/$BC85 in
  bbt.bin (pure intro) before building anything on them.

  WHAT REMAINS SOLID FOR THE INTRO (measured in bbt.bin, the pure-intro capture):
    * `$30cc cmp $C2 / bne $30CC` spins 99,656 times, Z NEVER set.
    * $30D0-$30E5 (scene scheduler + `bit RANDOM` scene select) NEVER execute.
    * $C2's only writer is `INC $C2` at $3E00, called from the VBI, needing 255
      ticks to reach $FF.
  So the intro stall is real and the mechanism (a starved $C2) still stands --
  but WHY the ticker is starved is once again OPEN, because it is not DLIs.
  NEXT: re-measure the VBI short/full split ($BC80 vs $BC85) and the $C2 tick rate
  IN bbt.bin ONLY, and compare against Altirra at the same scene.
  ############################################################################

  ############################################################################
  **T11 REFUTES THE MID-FRAME-REWRITE HYPOTHESIS TOO (2026-08-14).** Added to
  sim/tb_antic_timing.sv (committed): build the real list, run into the display
  region, then zero the WHOLE $3C00 page mid-frame exactly as the game's fill
  does, and finish the frame.
        T11: DL zeroed mid-frame -> /NMI pulses=2   NMIST-DLI assertions=0
  **ZERO DLI assertions.** (The "2" is an artifact -- T11's run_to sequence spans
  a frame boundary so it sees two VBIs; NOT a finding.) Rewriting the display
  list under ANTIC does not produce a spurious DLI in the model.

  **THREE RTL-SIDE HYPOTHESES NOW ELIMINATED IN SIM:** static DLI-free list (T10),
  CDC latency (antic_dli_cdc NOT-REPRODUCED), and mid-frame DL rewrite (T11).
  Hardware still dispatches 1608 DLIs. The model and the machine disagree and no
  amount of further modelling is closing it.

  **THEREFORE: STOP MODELLING, START OBSERVING.** The next investment must be
  something that reports what the HARDWARE is doing at the moment a DLI fires:
    * the mailbox read path (6502 stub -> SIO mailbox, kernel reads it) to
      snapshot the live DL and zero page without halting; and/or
    * an RTL debug counter/latch capturing WHY each NMI was raised (which arm
      fired, the line, the control byte fetched) -- a few registers in
      antic_timing.sv read back through GP0, which is far cheaper to interpret
      than another inference chain.
  Note tb_antic_timing now has T10 + T11 as permanent regression tests either way.
  ############################################################################

  ############################################################################
  **THE FILL'S TARGET, DERIVED (2026-08-14): $3C00-$3CFF, OVER THE DISPLAY-LIST
  HEAD.** No extra capture needed -- the watchpoint gave both halves: the write
  landed on **$3C7E** with **Y=$7E**, so the base is $3C7E - $7E = **$3C00**. The
  256-byte fill at $5FAB therefore covers **$3C00-$3CFF with $00**, and OUR
  DISPLAY LIST STARTS AT $3C7C -- so its head ($3C7C blank8, $3C7D blank7,
  $3C7E modeF+LMS) sits INSIDE the filled range.

  So the intro BLOCK-FILLS OVER THE LIVE DISPLAY LIST and then rebuilds it. That
  is a strong candidate for the sim/hardware split: a testbench with a STATIC
  DLI-free list cannot show what ANTIC fetches while the list is being
  overwritten mid-frame. Whether that yields a spurious DLI depends on what ANTIC
  reads DURING the rewrite window and on how our DL fetch handles a control byte
  changing under it.

  SCALE OF THE BLIND SPOT (why inference kept failing): indexed-store executions
  per capture window are enormous -- multi.bin STA abs,Y 19,430 / abs,X 158,054 /
  (zp),Y 51,987; hand.bin 13,739 / 107,220 / 61,255. None of these targets are
  recoverable from the trace alone.

  NEXT: (a) test in SIM whether rewriting DL bytes mid-frame can produce an NMIST
  DLI -- extend tb_antic_timing T10 to overwrite the list DURING the frame and
  re-check the assertions; that is cheap, needs no board, and directly probes the
  new hypothesis. (b) Still worth building the mailbox read path to snapshot the
  list before/during/after a fill.
  ############################################################################

  ############################################################################
  **THE WRITER IS A 256-BYTE BLOCK FILL (2026-08-14).** Altirra CANNOT disassemble
  it -- its memory at $5FAE-$5FBF is all $00/BRK, so it does not have that code
  (cross-machine trap again; the echo caught it). Rebuilt from OUR OWN traces
  instead, via the per-PC opcode map:
        $5F91 LDX#   $5F93 TYA    $5F94 CMP zp  $5F96 STA zp  $5F98 BEQ
        $5F9C CPX abs $5F9F STX abs $5FA2 BEQ   $5FA6 RTS      (x402 / x270 / x211)
        $5FA7 LDY# x1   $5FA9 LDA# x1   **$5FAB STA abs,Y x256**
  $5FAB is a one-shot 256-BYTE BLOCK FILL with a constant -- consistent with the
  A=$00 write we caught landing in the display-list area. The halt PC $5FBE sits
  just past it, so there is probably a SECOND fill loop there that these
  particular capture windows did not include.

  IMPLICATION: the intro periodically BLOCK-FILLS a 256-byte region that overlaps
  the display list. If a fill ever writes a byte with bit 7 set, or if a fill
  races ANTIC mid-frame, that is a plausible route to DLIs the static list never
  requests. NEXT: capture a window that CONTAINS $5FBE (vary the sleep: the fill
  is one-shot and rare, so try several offsets), recover its opcodes the same way,
  and determine the fill's TARGET BASE (the `abs` operand) and VALUE.
  ############################################################################

  ############################################################################
  **THE INTRO *DOES* REWRITE THE DISPLAY LIST — writer found (2026-08-14).**
  Watch armed INSIDE the intro (at PC=$32D0, icnt=14,092,976), 9 s later:
        HALTED (bkpt)  PC=**$5FBE**  A=$00  X=$40  Y=$7E  icnt=16,789,892
        wp_seen=1  wp_hit=1
  So $3C7E IS written during the intro, by GAME code at $5FBE -- not the loader
  ($CBxx) and not the SIO stub. Y=$7E is the low byte of the target, so this is
  exactly the `STA (zp),Y` class that trace decoding could never resolve. **A=$00
  and STA does not modify A, so the VALUE WRITTEN IS $00** -- bit 7 CLEAR, i.e.
  a plain blank-line control byte, NOT a DLI flag.

  This SUPERSEDES the "the list is static after load" entry below, which was
  measured in the GAME window (t=38-58 s) and is simply not true of the intro.
  Scope every watch result by the PC it was armed at: $3xxx = intro, $4C/$5D = game.

  WHERE THAT LEAVES THE DLI QUESTION: the one runtime DL write we have caught
  writes $00, so it does NOT explain the ~1608 DLIs. But it PROVES the intro
  mutates the list, so a static parse of $3C7C cannot settle whether a DLI bit is
  ever present. NEXT: watch more control bytes during the intro (0x3C90 in the
  animated modeF run, 0x3D45 the JVB, and bytes in the $BA00 segment) and record
  the VALUE (A at the halt) each time. One address per boot -- a hit halts the
  run, so ALWAYS `6502 watch off` then `6502 go`. Better still, build the mailbox
  read path and snapshot the WHOLE list at two points in the intro and diff it.
  ############################################################################

  ############################################################################
  **WATCH RE-RUN, ARMED AFTER THE LOAD (2026-08-14): $3C7E IS NOT WRITTEN.**
        armed at icnt=18,021,668 (PC=$4C7E) -> 20 s later icnt=27,285,464 (PC=$5D36)
        wp_seen=0  wp_hit=0      and the core stayed RUNNING (no halt)
  So that display-list control byte is STATIC once the load is done -- the list
  is not being rewritten, and the earlier hit really was just the loader.

  **SCOPE CAVEAT, STATED HONESTLY:** PC=$4C7E/$5D36 are GAME pages, and t=38-58 s
  is the GAME window, not the intro. This proves $3C7E is static THEN, not during
  the intro. The windows overlap awkwardly -- the load takes ~34 s while the intro
  runs ~26-38 s -- and run-to-run timing VARIES (Simon saw the goalposts on one
  build and not another). To test the INTRO specifically, arm at ~t=27-30 s and
  accept that a late-finishing load may still trigger it; distinguish the two by
  the halt PC ($CBxx/$Bxxx = loader/stub, $3xxx = game).
  ############################################################################

  ############################################################################
  **RETRACTION + TOOL CAVEAT (2026-08-14): THE WATCHPOINT IS A BREAKPOINT, AND
  THE $3C7E WRITE WAS THE LOADER, NOT THE GAME.**
  `6502 watch` does NOT passively monitor -- XT_DBG_WPCFG is documented as
  "**break** on WRITE/READ" and it HALTS THE 6502. After the hit, `6502` reports:
        6502 HALTED (bkpt)  PC=$CBE0  A=$3C X=$00 Y=$7E SP=$0FD  icnt=45936
  **icnt=45936** -- only ~46k instructions in, i.e. during the LOAD, not the
  intro. So the watchpoint fired almost immediately and the "30 s of intro" that
  followed was 30 s of a STOPPED CPU. And $CBE0 is in OUR SIOV STUB region, with
  A=$3C / Y=$7E composing $3C7E: that write was **the loader storing sector data
  into RAM** -- the display list being loaded from disk in the first place.
  It is NOT evidence that the game rewrites control bytes at runtime, and the
  previous entry's conclusion is WITHDRAWN.

  ALSO NOTE: DBG_WPC / DBG_WAXYS / DBG_WPSH are **INJECTION** registers (write
  PC/regs then DBG_COMMIT to resume a halted core), NOT capture registers. The
  watchpoint yields only wp_seen/wp_hit plus wherever the core halted.
  **USING IT COSTS YOU THE RUN**, so to survey runtime writes either
    * set the watch AFTER the load completes (t > ~34 s) so a load-time store
      cannot trigger it, read the halted PC, then `6502 go` to resume; or
    * build the mailbox read path and snapshot the DL at two times instead.
  **ALWAYS `6502 go` afterwards -- a halted guest left behind is a dead board.**
  (Verified resumed: PC=$3D87, icnt advancing.)
  ############################################################################

  ############################################################################
  **WATCHPOINT RESULT (2026-08-14): THE DL CONTROL BYTE $3C7E *IS* WRITTEN DURING
  THE INTRO.** `6502 watch 0x3C7E w` armed 3 s after boot, then `6502 diag` after
  30 s: **wp_seen=1 wp_hit=1**.

  This CUTS AGAINST the "our display list is DLI-free" reading. The control bytes
  ARE modified at runtime -- by the `STA (zp),Y` stores that absolute-store
  decoding cannot see -- so a STATIC snapshot of the list proves nothing about
  what ANTIC fetches frame to frame. The game may well be writing DLI bits into
  control bytes as it animates, which would make our ~1608 DLIs LEGITIMATE and
  move the question back to why the VBI collides with them here but not on the
  reference (handler LENGTH, or DLI placement relative to VBLANK). It would also
  reconcile the sim (clean on a static DLI-free list) with the hardware.

  **INSTRUMENT TRAP, CAUGHT:** `6502 watch 3C7E w` silently set the watch to
  **$0003** -- parse_num stops at the 'C', reading "3C7E" as decimal 3. A
  "no writes" result from that would have been meaningless. **ALWAYS pass hex as
  `0x3C7E` or `\$3C7E`** (both verified working).

  NEXT: get the WRITING PC. DBG_WPC / DBG_WAXYS / DBG_WPSH capture PC and
  registers at the hit, but `6502 diag` does not print them -- check `6502 status`
  or add a one-line readout to dbg6502.c (kernel-only rebuild, no bitstream).
  Then watch several control bytes across the modeF run and the $BA00 segment,
  and read back the VALUE written to see whether bit 7 is being set.
  ############################################################################

  ############################################################################
  **TOOL ALREADY EXISTS: A NON-HALTING WATCHPOINT (2026-08-14).** Before building
  a guest-RAM read path, note `6502 watch <addr> [r|w|rw]` (dbg6502.c:522) sets
  DBG_WP + DBG_WPCFG (bit0 enable, bit1 on_write, bit2 on_read) and does NOT halt
  the core; `6502 watch off` disables. `6502 diag` reports `wp_seen` and
  `wp_hit`, and DBG_WPC / DBG_WAXYS / DBG_WPSH capture the PC and registers AT
  THE HIT. So the PC behind an otherwise-unresolvable `STA (zp),Y` CAN be
  identified -- one address at a time, with no new tooling and no bitstream.

  USE IT to answer the open question directly: watch a DL control byte for WRITE
  and see whether anything modifies it. Candidates in priority order: a byte in
  the animated modeF run (e.g. $3C90), the mode/LMS byte $3C7E, and bytes in the
  $BA00 segment. If a write lands with bit 7 set, the DLIs are the GAME'S doing
  and legitimate; if nothing ever writes a control byte, they are ours.
  This is much cheaper than option A below and should be tried FIRST -- though a
  single-address watch is a needle in a haystack, so still build the read path if
  a few targeted watches come up empty.
  ############################################################################

  ############################################################################
  **THE GAME NEVER INSTALLS A DLI HANDLER (2026-08-14) — independent evidence
  that our DLIs are unwanted, needing NO display-list read.**
  Decoding every absolute store in all three capture windows:
        VVBLKI ($0222/$0223) <- $BC78   written once (the game's VBI handler)
        VDSLST ($0200/$0201) <- NEVER WRITTEN, in any window
  Altirra's VDSLST reads $C055, the OS ROM default stub. So the game installs a
  VBI handler and NO DLI handler: it does not intend DLIs to fire at all. Our
  1608 `JMP ($0200)` dispatches are therefore landing in the OS default stub --
  harmless in themselves, but EVERY ONE sets I and can collide with the VBI,
  which is precisely the mechanism that starves the $C2 ticker.

  This corroborates "the DLIs are spurious" WITHOUT depending on any
  display-list byte, sidestepping the cross-machine-memory trap entirely. It is
  the strongest evidence in the chain, because it rests only on OUR stores.

  Note it does NOT identify the source -- sim still refutes both the timing
  machine (T10) and the CDC path. The guest-RAM read path below remains the
  right next investment.
  ############################################################################

  ############################################################################
  **BOTH SIM PATHS ARE CLEAN — STOP INFERRING, BUILD THE READ PATH (2026-08-14).**
        make -C sim antic_timing   -> T10: /NMI=1, NMIST-DLI=0, ANTIC_TIMING OK
        make -C sim antic_dli_cdc  -> *** NOT-REPRODUCED (CDC-latency refuted) ***
  Neither the timing machine in isolation nor the register-write CDC produces a
  spurious DLI. Hardware nonetheless dispatches 1608 DLIs ($C01D = JMP (VDSLST),
  decoded from OUR ROM). No model available to us reproduces it.

  **STRUCTURAL FACT NOT YET CHASED: our DLIST is $3C7C, Altirra's is $BA00.** The
  ANTIC start addresses genuinely DIFFER, so Altirra's dlist() -- which parses
  only from $BA00 -- has NEVER examined the $3C7C segment on the machine that
  owns it. The 198-entry DLI-free parse of $3C7C was done by hand against
  ANOTHER machine's RAM. Our stores put $BA00 at $3C7A/$3C7B, just BELOW the
  list, so that word may be a code pointer rather than part of the DL at all --
  unresolved either way.

  **THE REAL BLOCKER, AND THE RECOMMENDATION: WE CANNOT READ OUR OWN GUEST RAM.**
  Every dead end tonight traces back to this. 52,000-61,000 `STA (zp),Y` stores
  per capture window are UNRESOLVABLE (the target lives in zero page at runtime),
  and any one of them could set a DLI bit in a control byte. Before more
  inference, BUILD A GUEST-RAM READ PATH:
      option A -- a small 6502 stub that copies a memory range into the SIO
                  mailbox page, which the kernel already reads (lowest risk, no
                  RTL, reuses xl_boot's romwin_write to inject the stub);
      option B -- a debug read aperture in RTL (needs a bitstream).
  With it, "what is at $3C7C on OUR machine" and "does any control byte have bit
  7" become one command instead of an argument. Recommend option A.
  ############################################################################

  ############################################################################
  **OUR DISPLAY LIST, FROM OUR OWN STORES (2026-08-14).** Decoding absolute
  stores into $3C00-$3E00 from our traces (no borrowed memory):
        $3C7A=00 $3C7B=BA   -> the game writes **$BA00** into the DL structure
        $3C18/$3C19, $3C7F/$3C80, $3CE4/$3CE5  -> LMS OPERANDS rewritten EVERY
              FRAME ($2090 in one window, $1074 in another) = the artwork
              scrolling; the CONTROL bytes ($3C7C=70, $3C7D=60, $3C7E=4F) are
              never rewritten, only the operands.
  So our list at $3C7C **CHAINS TO $BA00** -- which is precisely the list Altirra
  reported (DLIST=$ba00, 170 entries, 0 DLI-flagged). The two machines are using
  the SAME display-list data after all, which restores confidence in the earlier
  read even though the method was wrong.

  **THE CONTRADICTION IS THEREFORE UNRESOLVED AND SHARPER:** both DL segments
  look DLI-free, sim says a DLI-free list raises no DLI, yet our NMIST reports
  DLIs 1608 times. Do NOT resolve this by picking a side. Candidates:
    * a THIRD DL segment not yet inspected (follow the chain from $BA00 to its
      own JMP/JVB and check every control byte for bit 7);
    * the ~52k-61k **STA (zp),Y** stores per window, which are UNRESOLVABLE
      without a guest-RAM read -- one of them could be writing a DLI bit into a
      control byte at runtime. This is now the biggest blind spot in the whole
      investigation and probably justifies building a guest-RAM read path
      (6502 stub -> SIO mailbox, or a small RTL aperture) rather than more
      inference;
    * NMIST bit 7 set by something other than a DL-requested DLI.
  ############################################################################

  ############################################################################
  **SIM DOES NOT REPRODUCE IT — antic_timing.sv IS CLEAN (2026-08-14).** A new
  case **T10** was added to sim/tb_antic_timing.sv (committed): it builds
  BallBlazer's list byte-for-byte (`70 60 4F 8B 20`, 190x `0F`, `41 7C 3C` JVB
  to $3C7C), sets DLIST=$3C7C, DMACTL=$22, NMIEN=$40, and counts /NMI pulses and
  NMIST bit-7 assertions across a full frame with a cycle-accurate monitor.
  RESULT:
        T10: over one frame -> /NMI pulses=1   NMIST-DLI assertions=0
        *** ANTIC_TIMING OK ***
  Exactly ONE VBI NMI, and the DLI bit NEVER asserted. **The module behaves
  correctly under the modelled conditions, so do NOT "fix" antic_timing.sv.**

  **AND A FLAW IN MY OWN EVIDENCE, OWNED:** the display-list bytes at $3C7C were
  read out of **ALTIRRA's** memory, and Altirra is on a DIFFERENT list ($ba00).
  That is exactly the catalogued trap of reading another machine's memory as if
  it were ours. The clean parse (198 entries, JVB back to its own head) is
  suggestive but is NOT proof about OUR RAM. So "our display list has zero DLI
  bits" is UNPROVEN, and with it the whole "spurious DLI" reading.

  WHAT IS STILL HARD FACT (measured on OUR hardware, from OUR ROM):
    * $C018 x2393 = $C01D x1608 (JMP (VDSLST) — the DLI dispatch) + $C020 x785.
      Our ROM bytes decode this unambiguously: BIT $D40F / BPL $C020 / JMP ($0200).
      So our NMIST really is reporting DLIs ~4x per VBI-path entry.
    * 31 VBIs took the short path (I set) vs Altirra's ZERO in 60 frames.
    * The $30CC wait, the $C2 ticker, and the never-executed scene scheduler.

  **NEXT — RESOLVE THE CONTRADICTION.** Sim says a DLI-free list raises no DLI;
  hardware says DLIs are being dispatched. Therefore ONE of these is true and it
  must be decided by measurement, not argument:
    (a) OUR display list is NOT DLI-free (most likely — the $3C7C bytes were
        Altirra's). READ OUR OWN LIST: no guest-RAM path exists, so infer it from
        the trace instead — the DL is fetched by ANTIC, not the CPU, so look for
        the game WRITING it (stores into $3C7C..$3D45) during the load/handoff
        windows and reconstruct the bytes from the store values.
    (b) The bug is in INTEGRATION rather than antic_timing in isolation — what
        feeds it on hardware (CDC of register writes, DMACTL/DLIST timing,
        `make -C sim antic_dli_cdc` covers one such path and is worth running).
    (c) Something else sets NMIST bit 7.
  ############################################################################

  **DLI DISPATCH VERIFIED FROM OUR OWN ROM (2026-08-14, final).** Altirra's $C018
  is attract-mode code -- its OS build differs (NMI vector $C18E) -- so its
  disassembly says NOTHING about ours. Always cross-check sim/atari_xl_rom.mem:
        $C018  2C 0F D4   BIT $D40F     ; NMIST, N = bit 7 = DLI status
        $C01B  10 03      BPL $C020     ; NOT a DLI -> VBI path
        $C01D  6C 00 02   JMP ($0200)   ; VDSLST -- the DLI vector
  So **$C01D x1608 IS the DLI dispatch** and $C020 x785 is the VBI path. Our
  ANTIC asserts NMIST bit 7 about **4.2 times per frame** while our display list
  ($3C7C, 198 entries, JVB back to itself) carries ZERO DLI-flagged entries. The
  earlier count-based inference is now verified from bytes.

  **ROOT CAUSE REINSTATED ON FIRMER GROUND (2026-08-14, final): WE TAKE ~5
  SPURIOUS NMIs PER FRAME WITH NO DLI REQUESTED ANYWHERE.**

  The retraction below was right to demand our OWN display list. Here it is.
  Our trace writes DLISTL=$7C / DLISTH=$3C, so OUR DLIST = $3C7C. Parsing memory
  there gives a COMPLETE, SELF-CONSISTENT display list:
        198 entries, ~225 scanlines, terminator **$3D45 JVB -> $3C7C**
        (blank8, blank7, modeF LMS $208B, then a long run of modeF)
        **DLI-flagged entries: 0**
  A correct JVB pointing exactly back at its own head after 198 valid entries is
  not something garbage bytes produce, so these really are our display-list bytes.

  THIS CLOSES BOTH GAPS THAT FORCED THE RETRACTION:
    1. It no longer leans on Altirra's list -- this is OUR list at OUR DLIST.
    2. **NMIEN NO LONGER MATTERS.** NMIEN only GATES DLIs; the DISPLAY LIST
       REQUESTS them. With zero DLI bits anywhere, no DLI NMI should be raised
       whatever NMIEN holds -- so the uncovered t~6-20 s window cannot hide a
       contradicting write. The argument is now independent of NMIEN entirely.

  And yet: $C018 (every NMI) : $BC78 (game VBI) = 2393 : 414 = **5.78 NMIs per
  VBI**. One VBI per frame, no DLI requested anywhere => ~4.8 NMIs per frame with
  NO LEGITIMATE SOURCE. That is the bug, and it is ours.

  **THE OS DISPATCH CONFIRMS THEY ARE CLASSIFIED AS DLIs.** In the intro capture
  the OS NMI handler splits cleanly:
        $C018 x2393  (NMI entry)   $C01B x2393
        $C01D x1608  <- one branch
        $C020..$C029 x785 <- the other branch      (1608 + 785 = 2393)
  The VBI-side count 785 is ~2x the 383 $BC78 calls, consistent with XITVBV being
  reached twice per VBI (immediate VVBLKI + deferred VVBLKD, which also explains
  the earlier 1:2 $BC78:XITVBV puzzle). That leaves **1608 NMIs, ~4.2 per frame,
  taking the OTHER branch.**
  The XL OS handler chooses that branch by reading **NMIST ($D40F)**, so our ANTIC
  is not merely raising extra NMIs -- it is ASSERTING THE DLI STATUS BIT while the
  display list contains ZERO DLI-flagged entries. (Which branch is DLI vs VBI was
  inferred from the counts, not disassembled -- confirm with alt.disasm($C018,16)
  before relying on it.)

  FULL CHAIN: spurious NMIs -> a VBI lands inside a handler (all 31 dropped VBIs
  interrupted $BED0/$BEEC/$BEF5/$BECD/$BEAF/$BF90/$BEF3/$C02C, every one with
  I=1) -> the game's gate `$bc78 tsx / lda $0104,X / and #$04 / beq $BC85` takes
  the short path `$bc80 dec $81 / jmp XITVBV` -> the `INC $C2` tick at $3E00 is
  dropped (ours 92.5% full path; Altirra 100%, $9D -60 / $81 -0 over 60 frames)
  -> $C2 needs 255 ticks -> `$30cc cmp $C2 / bne $30CC` drags (99,656 iterations,
  Z never set) -> the scene scheduler and its `bit RANDOM` select at $30D0-$30E5
  never run -> the man's scene never plays. THAT IS SIMON'S SYMPTOM.

  **NEXT: REPRODUCE IN SIM, THEN FIX.** Target, now very clean: a display list
  with NO DLI bits must produce EXACTLY ONE NMI PER FRAME. If the RTL produces
  ~6, that is the reproduction -- and it needs no NMIEN games and no DLI-flagged
  lines. Live module is antic_timing.sv (fpga_xt_top.sv:1229 selects tm_nmi_n;
  antic_nmi.sv is LEGACY -- do not edit). Suspect what ARMS nmi_arm_q at :557/:575
  when no DLI is requested. Harnesses: tb_nmi, tb_antic_display, tb_antic_modes,
  tb_antic_beam. ACID800 (55/8na/0fail, antic_nmist + the DLI cluster) is the
  regression guard. Any fix needs a bitstream (~8 min).
  ############################################################################

  **SUPERSEDED RETRACTION (kept for the reasoning; its demand for our own display
  list has now been satisfied):** Two gaps, both found by running the confirmation
  step rather than trusting the conclusion:

  1. **WE ARE ON A DIFFERENT DISPLAY LIST.** Our trace writes DLISTL=$7C /
     DLISTH=$3C, so OUR DLIST = **$3C7C**. Altirra's is **$ba00**. The finding
     "Altirra's display list has 170 entries and ZERO DLI-flagged lines"
     therefore says NOTHING about ours -- our list at $3C7C may legitimately be
     full of DLI bits, in which case ~5 DLIs/frame is CORRECT behaviour and there
     is no bug here at all. The comparison is VOID until both machines are on the
     same list at the same scene.
  2. **NMIEN=$40 IS NOT ESTABLISHED FOR THE INTRO.** The captures cover t~2-6 s,
     t~20-32 s and t~26-38 s. The window **t~6-20 s is NEVER CAPTURED**, and a
     write to NMIEN there (e.g. $C0, enabling DLIs) would be invisible to every
     search run so far. "NMIEN is only written during the load" is really "no
     NMIEN write appears in the windows I captured".

  WHAT SURVIVES AND IS STILL SOLID (all duration-free or directly measured):
    * The wait is real: `$30cc cmp $C2 / bne $30CC`, 99,656 iterations, Z NEVER
      set, and $30D0-$30E5 (scene scheduler + `bit RANDOM` scene select) never
      execute. This IS Simon's "vehicle stops and waits where the man should be".
    * $C2's only writer is `INC $C2` at $3E00, called from the game's VBI, and it
      needs 255 ticks.
    * The VBI drops its work when it interrupts code with I set, and ALL 31
      dropped VBIs interrupted handler code with I=1.
    * OURS 92.5% full-path vs ALTIRRA 100% ($9D -60, $81 -0 over 60 frames).
    * $C018:$BC78 = 5.78 NMIs per VBI on ours.
  What is NOT established is WHY we take ~5 NMIs per VBI -- legitimate DLIs from
  our own display list, or spurious ones. That is the whole remaining question.

  **NEXT SESSION, IN THIS ORDER:**
   1. Capture the UNCOVERED WINDOW t~6-20 s and search it for NMIEN ($D40E) and
      DLIST ($D402/$D403) writes, absolute AND indexed.
   2. Determine what OUR display list at $3C7C actually contains. There is no
      guest-RAM read path, but Altirra's memory matched ours 192/192 in the intro
      code regions -- peek $3C7C there and check whether it parses as a display
      list with DLI bits. If it does, ~5 DLIs/frame is CORRECT and the NMI angle
      collapses; the real question becomes why the VBI collides with them here and
      not on the reference (handler LENGTH, or DLI placement near VBLANK).
   3. Only then consider RTL.
  ############################################################################

  **SUPERSEDED (kept for the measurements, NOT the conclusion): "our ANTIC raises
  DLI NMIs while NMIEN bit 7 is clear".** Measured, not inferred:
    * NMIEN is written ONLY during the load: values $00, $00, $40. Nothing writes
      it in the handoff (t~20-32 s) or intro (t~26-38 s) windows. The search
      covered absolute AND INDEXED stores (abs,X / abs,Y) with targets computed
      from X/Y at retire, so an indexed `sta $D400,X` could not have been missed.
    * NMIEN=$40 => bit 7 CLEAR => DLIs DISABLED => only the VBI NMI should fire,
      i.e. **60 Hz**. Altirra reports the same NMIEN=$40 for this scene.
    * **STATE IT RATE-FREE.** The trace has NO timestamps, and a measured icnt
      rate (4,737,018 instructions in 10 s = ~474k/s) was sampled during the GAME,
      where cycles-per-instruction differ from the intro -- so any duration
      derived from it is soft, and two rate claims have already been retracted
      today. Use a RATIO instead, which needs no clock:
          $C018 (EVERY NMI) : $BC78 (the game's VBI handler) = 2393 : 414 = **5.78**
      With DLIs disabled that ratio MUST be 1.0 -- every NMI would be a VBI.
      Measuring 5.78 means ~78% of our NMIs are NOT VBIs: they are DLIs firing
      with NMIEN bit 7 CLEAR. This holds whatever the capture duration was.
    * (Superseded, do not quote: an "NMI rate of ~140-176 Hz" derived from an
      assumed 13.6 s window. The ratio above is the defensible form.)

  **THE DISPLAY LIST REQUESTS NO DLIs AT ALL (2026-08-14).** alt.dlist() for the
  intro: **170 entries, DLI-flagged: 0**, with NMIEN=$40 and DLIST=$ba00. So on
  the reference nothing anywhere asks for a DLI, which is why it takes exactly one
  NMI per frame ($C018:$BC78 = 1.0 equivalent).

  Our ~4.8 EXTRA NMIs per frame therefore have NO legitimate source: this is not
  "DLIs fire despite nmien[7]" but "NMIs fire with no DLI requested". That is a
  stronger and simpler statement, and it changes what the sim must reproduce --
  a display list with NO DLI bits and NMIEN=$40 must produce EXACTLY ONE NMI per
  frame; if the RTL produces ~6, that is the reproduction.

  MUST CONFIRM FIRST (one measurement, cheap): that OUR DLIST matches $ba00 and
  our display list likewise has no DLI bits. Look for writes to $D402/$D403
  (DLISTL/DLISTH) in the captures the same way NMIEN was found (absolute AND
  indexed, targets computed from X/Y at retire). If our DLIST differs, the two
  machines are on different display lists and this comparison is void -- the same
  scene-alignment trap that produced several retractions today.

  **LIVE MODULE CONFIRMED + A CONCRETE CANDIDATE (2026-08-14).** fpga_xt_top.sv
  :1229 multiplexes three NMI sources: `rw_auth ? rw_nmi_n : tm_auth ? tm_nmi_n
  : nmi_n_sync`. The TIMING MACHINE is default, so **antic_timing.sv drives the
  live NMI** (tm_nmi_n, instantiated at fpga_xt_top.sv:950). antic_nmi.sv -- the
  one with the clean `dli_fire = at_nmi && dli_armed && nmien[7]` -- sits inside
  antic_gtia -> antic_scanline and is the LEGACY path. Do not "fix" it.

  In antic_timing.sv the arm points are :557 (VBI) and :575 (DLI), both commented
  "condition only -- NMIEN gates at pulse time", and the gate is :620:
        nmi_en_early <= (line == VBI_LINE) ? nmien_q[6] : nmien_q[7];
  **HYPOTHESIS TO TEST IN SIM (not yet proven):** the NMIEN bit is chosen from the
  LIVE LINE COMPARE, not from `nmi_arm_vbi_q` which records WHICH KIND of arm it
  was. The comment says that is deliberate (nmi_arm_vbi_q is written on the same
  tick and would read stale). But it means a DLI armed on the line that is being
  evaluated as VBI_LINE gets gated by **nmien[6]** -- the VBI enable -- instead of
  nmien[7]. With NMIEN=$40 that is 1 instead of 0, so the DLI FIRES. Compare
  [[dli_coincidence_bug]].
  CAVEAT THAT MUST BE RESOLVED: that path can only misfire around ONE line per
  frame, yet we measure ~5 extra NMIs per frame ($C018:$BC78 = 5.78). So either
  there is a second mechanism, or the arm persists across lines, or the ratio has
  another explanation. DO NOT EDIT RTL until sim reproduces ~5 spurious DLIs per
  frame with NMIEN=$40 -- matching the measurement, not merely producing one.

  **WHERE THE LEGACY GATE LIVES.** hdl/antic_nmi.sv:84 has `dli_fire = at_nmi &&
  dli_armed && nmien[7]`, but that module is NOT necessarily the live path --
  [[antic_timing_machine]] has been DEFAULT since build 68, and hdl/antic_timing.sv
  does its own gating at :620-631 (`nmi_en_early <= (line == VBI_LINE) ?
  nmien_q[6] : nmien_q[7]`, with the fire conditioned on `nmi_arm_q &&
  nmi_en_early`). That gating LOOKS correct and is pinned by four ACID
  antic_nmist asserts, so the bug is more likely in what ARMS `nmi_arm_q` for a
  DLI line than in the enable term itself. CONFIRM WHICH MODULE IS SYNTHESIZED
  before editing either -- reading dead code has already cost a wrong conclusion
  today ([[compositor_sv_is_dead_code]]).

  * OUR MEASURED NMI RATE ($C018, our real NMI vector from
      sim/atari_xl_rom.mem) is **~140-176 Hz** across two independent captures.
      That is ~80-116 EXTRA NMIs per second -- DLIs that must not be firing.

  THE COMPLETE CHAIN, ALL MEASURED:
      spurious DLI NMIs
        -> a VBI lands INSIDE a DLI handler (all 31 dropped VBIs interrupted
           $BED0/$BEEC/$BEF5/$BECD/$BEAF/$BF90/$BEF3/$C02C, every one with I=1)
        -> the game's VBI gate `tsx / lda $0104,X / and #$04 / beq $BC85` sees
           I SET and takes the short path `dec $81 / jmp XITVBV`
        -> the `INC $C2` tick at $3E00 is DROPPED (ours 92.5% full path vs
           Altirra's 100%: $9D -60 / $81 -0 over 60 frames)
        -> $C2 climbs at ~12.8 Hz instead of 60 Hz and needs 255 ticks
        -> the wait at `$30cc cmp $C2 / bne $30CC` stretches from ~4.25 s to ~20 s
           (99,656 iterations observed, Z never set)
        -> $30D0-$30E5 never run, so the scene scheduler and its `bit RANDOM`
           scene selection never execute
        -> the man's scene never plays. THAT IS SIMON'S SYMPTOM: the vehicle
           stops in the middle and waits where the man should appear and wave.

  **NEXT: PROVE IT IN SIMULATION BEFORE TOUCHING RTL.** Write/extend a testbench
  that sets NMIEN=$40 with a display list containing DLI-flagged instructions and
  asserts that NO DLI NMI is raised (sim/ has tb_nmi, tb_antic_display,
  tb_antic_modes, tb_antic_beam, tb_wsync; `make -C sim <target>`). Then fix the
  NMIEN bit-7 gate in the ANTIC NMI path and rebuild the bitstream
  (vivado/run-valhalla.sh bit, ~8 min). Related: [[acid800_dli_cluster]],
  [[dli_coincidence_bug]], [[acid800_dli_staleness_fix]], [[antic_timing_machine]].
  ACID800 passes 55/8na/0fail today, so any fix MUST keep that green -- the DLI
  tests are the regression guard.
  ############################################################################

  **HANDLERS IDENTIFIED FROM OUR OWN ROM (2026-08-14).** No guest-RAM read needed
  -- the OS image we upload is in the repo. `sim/atari_xl_rom.mem` (16384 bytes,
  base $C000) gives OUR vectors:
        $FFFA NMI   -> $C018
        $FFFC RESET -> $C2AA
        $FFFE IRQ   -> $C02C
  (Altirra's are $C18E/$C1A2 -- a DIFFERENT OS build, which is why its vectors
  could not identify ours.) Mapping the interrupt counts from the intro capture:
        $C018 = NMI : 2393 entries  ~176 Hz
        $C02C = IRQ : 3820 entries  ~281 Hz   (POKEY timers -- the game's sound)
  With DLIs disabled the NMI rate should be 60 Hz (VBI only). Ours is ~176 Hz,
  i.e. roughly **1.9 EXTRA NMIs per frame** -- we ARE taking DLIs. Altirra runs
  this scene with NMIEN=$40 (DLIs OFF).

  THAT IS THE SHAPE OF THE BUG: extra DLI NMIs -> a VBI lands inside a DLI
  handler -> the I-flag gate sends it down the short path -> $C2 tick dropped ->
  the $30CC wait drags -> the scene scheduler never runs -> no man.
  ONE MEASUREMENT STILL MISSING: OUR NMIEN value. If it is $40 while we still
  take ~2 DLIs/frame, our ANTIC is raising DLI NMIs with bit 7 CLEAR and that is
  an RTL bug. If it is $C0, the game enabled DLIs and the extra NMIs are correct
  -- in which case the difference is scene alignment, not hardware.

  **NMIEN IS NOT WRITTEN DURING THE INTRO (2026-08-14).** Decoding every absolute
  store in the intro capture against Altirra (memories match, so operands are
  valid) finds NO writes to $D40E at all. The only ANTIC-control writes are one
  $D400 (DMACTL) = **$3E**, which MATCHES Altirra's DMACTL=$3e exactly, and heavy
  $D40A (WSYNC) traffic, which is normal raster work. So NMIEN is established
  BEFORE this window and its value cannot be read from this trace.

  CONSEQUENCE: "are we taking DLIs the reference is not?" is STILL OPEN and must
  not be asserted. To settle it, capture a trace spanning the LOAD and the
  handoff into the intro (the NMIEN write will be in there -- the game does
  `sei / lda #$00 / sta NMIEN` at $bc9f, so it manipulates NMIEN itself), or
  find the last $D40E write before the intro begins. Remember the two machines
  may simply be in DIFFERENT SCENES with legitimately different NMIEN -- that
  alone has produced several false leads today.

  **THE SHARPEST OPEN QUESTION: ARE WE TAKING DLIs THAT THE REFERENCE IS NOT?**
  Altirra in this scene reports **NMIEN=$40** -- bit 7 CLEAR, i.e. DLIs DISABLED,
  only the VBI NMI enabled (IRQEN=$20, DMACTL=$3e, DLIST=$ba00). That alone would
  explain why Altirra NEVER has a VBI land inside a DLI handler: it has no DLIs
  to land in.

  Our side takes 6213 interrupt entries in the same capture, through exactly two
  handlers: **$C02C x3820** and **$C018 x2393** (~281 Hz and ~176 Hz). Against
  ~816 VBIs that is ~5400 interrupts the reference would not be taking IF its
  NMIEN state also applies to us.

  MEASUREMENT GAP, DO NOT SKIP: Altirra's vectors are $FFFA=$C18E (NMI) and
  $FFFE=$C1A2 (IRQ), which do NOT match our $C02C/$C018 -- our OS image is a
  different build, so our handlers CANNOT be identified from Altirra's vectors.
  Before claiming "we take spurious DLIs":
    1. Determine OUR NMIEN during the intro -- find stores to $D40E ($D40E writes
       are decodable since the memories match) and read the value from the trace.
       The game itself writes NMIEN ($bc9f sei / lda #$00 / sta NMIEN), so it is
       game-controlled and may legitimately differ by scene.
    2. Work out which of $C02C/$C018 is NMI and which is IRQ IN OUR OS image
       (peek our own ROM is impossible -- no guest-RAM read -- so infer from the
       trace: the NMI handler will be the one whose rate tracks 60 Hz x (1+DLIs),
       and POKEY timer IRQs will track AUDF/AUDCTL).
    3. Only then compare like with like, ALIGNED ON A SCENE.
  If our ANTIC raises DLI NMIs while NMIEN bit 7 is clear, that is an RTL bug and
  the direct cause of the dropped $C2 ticks. SIMULATE FIRST (tb_nmi, tb_antic_*).

  **THE MECHANISM, NAMED (2026-08-14): our VBI lands INSIDE A DLI HANDLER.**
  Walking back from each dropped VBI to the instruction it interrupted:
        $BED0 x11   $BEEC x11   $BEF5 x2   $C02C x2   $BECD x2
        $BF90 x1    $BEAF x1    $BEF3 x1        -- all 31 with I=1
  That range is an INTERRUPT HANDLER, so the VBI is arriving while a DLI handler
  is still executing; the handler's I flag then sends the VBI down the short path
  and the $C2 tick is lost. Altirra NEVER does this (0 short paths in 60 frames).

  Context for a number that looks alarming but is not: 62.6% of trace records
  have I set, top pages $4Cxx/$99xx/$5Axx/$5Dxx/$BExx. With 6213 interrupt
  entries (~457 Hz, ~7.6 DLIs/frame) and long raster handlers, that is simply
  time spent INSIDE handlers -- roughly 500 instructions per handler accounts for
  it exactly. It is NOT a stuck I flag or a CPU bug.

  NEXT — this is now an ANTIC/DLI TIMING question, our side of the fence:
  (a) count Altirra's DLIs per frame in the SAME scene and compare with our ~7.6;
      if we generate EXTRA or LATE DLIs, one lands on top of VBLANK;
  (b) check whether our VBI NMI is raised at the right scanline relative to the
      last DLI (see [[acid800_dli_cluster]], [[dli_coincidence_bug]],
      [[acid800_dli_staleness_fix]], [[antic_timing_machine]]);
  (c) note the game DISABLES NMIEN in one VBI path ($bc9f sei / lda #$00 /
      sta NMIEN), so NMIEN handling around that window is worth checking too.
  If ours emits a DLI at or after the VBLANK boundary that the reference does
  not, that is the bug, and it is RTL -- requiring a bitstream, so SIM IT FIRST.

  **THE VBI GATE, AND THE MEASURED DIVERGENCE (2026-08-14).** The game's VBI
  handler starts by inspecting the INTERRUPTED code's I flag:
        $bc78 tsx / $bc79 lda $0104,X / $bc7c and #$04
        $bc7e beq $BC85        ; I CLEAR -> FULL work (this path reaches the $C2 ticker)
        $bc80 dec $81 / $bc82 jmp XITVBV   ; I SET -> SHORT path, no tick
        $bc85 dec $9D ...                  ; full path
  So $81 counts short-path VBIs and $9D counts full-path ones, which makes the
  ratio measurable on BOTH machines with no tracing at all.

        ALTIRRA : $9D -60, $81 -0 over 60 frames -> 100% full path, EXACTLY one
                  game-VBI per frame (60 in 60).
        OURS    : $BC85 383, $BC80 31            ->  92.5% full path.

  Altirra NEVER takes the short path; we take it 31 times. Each one is a DROPPED
  $C2 TICK, and $C2 must reach $FF for the intro to advance past $30CC. So our
  VBI is repeatedly catching code with INTERRUPTS DISABLED, which the reference
  never does.

  Second, duration-independent oddity: $BC78 runs 414 times against 816 XITVBV
  ($E462) entries -- a 1:2 ratio -- while Altirra's game VBI is 1:1 with frames.
  Worth understanding before drawing conclusions: XITVBV may legitimately be
  reached by both the immediate (VVBLKI) and deferred (VVBLKD) paths, so confirm
  what the second entry is rather than assuming the game handler is being skipped.

  NEXT: find WHERE our 6502 sits with I set when the VBI arrives -- the trace has
  P at retire, so histogram the PC at interrupt-entry records (IR==$00, SP-=3)
  and see which code was interrupted with I set. Suspects: a long SEI critical
  section, our SIO/mailbox stub, or a DLI handler overrunning. 7.5% of VBIs is
  small but the wait needs 255 consecutive successful ticks, so a steady 7.5%
  loss stretches a ~4.25 s wait toward ~20 s, which is what Simon sees.

  **INTERRUPT CADENCE IS HEALTHY — the "4x slow VBI" idea is WRONG.** Measured
  from the same trace (5,178,368 entries):
        $E462 XITVBV ............ 816     $C28A/$C28F (VBI exit path) ... 816
        $BC9C (VBI tail) ........ 383
        $3E00 `inc $C2` ......... 174
        RTI / interrupt entries . 6213
  816 XITVBV at 60 Hz means the capture was ~13.6 s (NOT the 12 s assumed), so
  the VBI runs at ~60 Hz and is CORRECT, and DLIs run ~457 Hz (~7.6 per frame),
  which is normal for this title. An earlier inference of "VBI is 14.5 Hz, 4x too
  slow" used the wrong denominator AND the wrong counter and is WITHDRAWN.

  What is actually true is narrower: the ticker's CALL is conditional, so $C2
  advances only ~174 times in ~13.6 s (~12.8 Hz) while the VBI fires ~816 times.
  $C2 needs 255 ticks to reach $FF, hence a ~20 s wait at $30CC. NEXT: find why
  the path $BC8E -> $3DE0 -> $3DFE is taken on only ~174 of 383 $BC9C passes, and
  what Altirra's ratio is IN THE SAME SCENE. Note Altirra's $C2 is STATIC across
  60 consecutive frames (zero increments) while ours ticks 174 times, so ours
  calls it MORE, not less -- the two are in different scenes and that comparison
  cannot settle anything until they are aligned on a CODE LANDMARK.

  **THE $C2 WRITER (2026-08-14).** alt.memsearch finds the
  ONLY writer of $C2: `INC $C2` at **$3E00**, inside a SOUND-UPDATE routine:
        $3dfc cmp #$FF
        $3dfe bcs $3E02          ; skip the INC if A >= $FF
        $3e00 inc $C2            ; <-- the only writer anywhere in memory
        $3e02 lsr x4 / ora #$A0 / sta AUDC1 ($D201) / sta AUDC2 ($D203) / rts
  In our t=26..38 s window $3E00 executes **174 times** (~14.5 Hz), and the BCS
  is never taken. $C2 must climb to $FF = 255 ticks, so at that rate the wait at
  $30CC lasts ~17.6 SECONDS.

  So "stuck" is too strong -- it is a VERY LONG WAIT, which is consistent with
  Simon seeing the vehicle stop and stay still and the game eventually starting.
  If this routine is meant to run once per frame (60 Hz) the wait should clear in
  ~4.25 s, i.e. our tick rate would be ~4x too slow.

  NEXT, AND MEASURE BEFORE CONCLUDING: (a) find what CALLS $3DF0/$3DFE and how
  often it should fire -- is it a VBI, a DLI, or a timer IRQ? (b) measure
  ALTIRRA's tick rate for the same routine (bp_set/watch_set on $3E00 and count
  per frame) -- note polling $C2 every 3 frames showed $00 for 90 frames on
  Altirra, which is FEWER increments than ours, so the naive reading is
  contradictory and the two must be compared AT THE SAME SCENE, not at whatever
  moment each happens to be in. (c) if our rate really is ~4x low, the suspect is
  interrupt cadence (VBI/DLI/POKEY timer IRQ), not GTIA.

  Do NOT conclude a rate bug from our number alone -- 174 ticks in 12 s is only
  meaningful against Altirra's rate in the SAME scene.

  **EARLIER FRAMING (still true, but see the rate note above): we sit in a wait
  for $C2 == $FF.**
  Disassembly of our own path (via alt.disasm; legitimate, memories match):
        $30c4 lda #$01
        $30c6 cmp $CA / bne $30C6      ; wait for $CA == $01   (this one PASSES)
        $30ca lda #$FF
        $30cc cmp $C2 / bne $30CC      ; wait for $C2 == $FF   <-- WE NEVER LEAVE
        $30d0 inc $D6 ...              ; scene scheduler + `bit RANDOM` selection
  Measured from the trace (t=26..38 s, 5,178,368 entries): the CMP at $30CC
  retired 99,656 times with A=$FF in 99,655 of them and the Z flag NEVER set --
  $C2 never reaches $FF. $30D0/$30DC/$30E3/$30E5 execute ZERO times, so the scene
  scheduler and the RANDOM-based scene selection are never reached at all.

  **THIS IS EXACTLY SIMON'S SYMPTOM.** "The vehicle comes to a stop and stays
  still in the middle, which is when the man is supposed to appear and wave" IS
  this spin: the code sits at $30CC for the whole window and never advances, so
  the next scene never starts and the man is never drawn.

  The ONLY entry into the spin besides its own branch is an RTI from **$C28F**
  (18 times), i.e. the VBI/DLI returning into it. So $C2 is written by an
  INTERRUPT HANDLER, and the wait is for that handler to signal $FF.
  NEXT: find who writes $C2 (`sta $C2` = 85 C2; try alt.memsearch, or
  alt.watch_set on $00C2 and catch the writer on Altirra), then work out why our
  handler never produces $FF. Suspects in order: (a) a DLI/VBI that never fires
  or fires at the wrong scanline, (b) a handler that counts something timing-
  dependent, (c) NMIEN/VCOUNT-related. Altirra samples every 3 frames show
  $C2=$00 throughout, so the $FF is TRANSIENT there -- sample far more finely or
  use a watchpoint rather than polling.

  **SECOND RETRACTION — "we never execute $3043/$3AB0" IS ALSO FALSE.** A better
  capture (three back-to-back `dtrace 4` windows in ONE boot, t=26..38 s,
  5,178,368 entries) shows our machine DOES execute Altirra's intro routines:
  $3xxx regions run include $3043-30CE, $327F-32E2 (the $3282/$32C3 chain) and
  $3A5C-3BA6 (the $3AB0 sprite plotter). The earlier "zero" came from the t=45 s
  trace, which is the GAME. That is the THIRD window-scoping error today; treat
  ANY "we never run X" claim as unproven until it is measured across the whole
  intro, not one 4 s slice.

  **WHAT SURVIVED, AND IT IS SHARP:** in that same run
        PC $30CC executed 99,656 times
        PC $30DC executed 0 times      <-- the `bit RANDOM` scene-select
        PC $30D0/$30E3/$30E5 executed 0 times
        PC $30EC executed (region $30EC-30F3), $3307 executed 25,668 times
  So we SPIN at `$30cc cmp $C2 / $30ce bne $30CC` and NEVER fall through to
  $30D0-$30E5. The scene-selection block is not being reached at all in this run;
  the `jsr $3307` display loop at $30EC is entered from elsewhere. The question
  is now WHY `cmp $C2` never matches -- $C2 is the frame counter the scheduler
  waits on, and $D6/$3A58 gate the selection. Chase $C2: who writes it, and does
  our value ever reach the compared value? Compare against Altirra, which does
  reach $30DC (its $9C selection works and its RANDOM varies, SKCTL=$13).

  **RETRACTION (2026-08-14, latest): the two machines run IDENTICAL CODE.** The
  "structurally different intro implementations" claim below is WRONG and is
  withdrawn. Peeking Altirra at OUR OWN executed PCs gives a 192/192 opcode match
  across all six of our intro regions ($30CC-30F1 16/16, $3307-33A1 67/67,
  $33D3-33E7 5/5, $37D3-37D9 4/4, $37FC-3854 42/42, $3DE0-3E6A 58/58). The
  earlier signature search failed only because we do not EXECUTE $3043/$3AB0 --
  absence of execution, not difference of code. This is SAME CODE, DIFFERENT
  PATH: a control-flow divergence inside a byte-identical intro.

  That also unlocks a capability: because the memories agree, `alt.disasm(addr)`
  at OUR addresses is a readable disassembly of OUR execution path.

  **OUR PATH, DISASSEMBLED — the intro is a SCENE SCHEDULER driven by POKEY
  RANDOM.** At $30CC:
        $30cc cmp $C2 / bne $30CC        ; wait for the frame counter
        $30d0 inc $D6
        $30d2 lda $3A58 / eor $D6
        $30d7 beq $30DA / $30d9 rts      ; only every $5A frames does it proceed
        $30da lda #$00
        $30dc bit RANDOM ($D20A)         ; <-- picks the scene
        $30df bpl $30E3 / $30e1 lda #$06
        $30e3 sta $9C                    ; $9C = 0 or 6
        $30e5 jsr $37D3 / $30ec jsr $3307
  and $9C later indexes a table (`$332d lda $32E3,X`). So WHICH SCENE PLAYS is
  chosen from bit 7 of POKEY's RANDOM register. A stuck or biased RANDOM would
  select the same scene forever -- which is exactly the repeating
  {smooth anim}{abrupt switch} Simon sees, the man's scene never appearing, and
  the goalposts showing on one build but not another (timing shifts the sample).

  MEASURED SO FAR: Altirra has SKCTL=$13 (poly counters RUNNING) and RANDOM
  genuinely varies ($FD,$1E,$73,$0F,$E0,$1E). On OUR side, bit 7 of RANDOM is
  readable WITHOUT any memory-read tool: `bit $D20A` sets N from bit 7, and the
  trace records P at retire -- find records with IR=$2C and next_pc=$30DF and
  read bit 7 of P. In the t=31-35 s window that fires only ONCE (N=0, so $9C=0),
  because the scheduler gates it to ~once per $5A frames. NOT ENOUGH SAMPLES.
  NEXT: capture several intro windows and collect the N distribution; if ours is
  always one value while Altirra's alternates, that is the bug. Note
  pokey_audio.sv:199 forces RANDOM to $FF when the poly counters are held in
  reset (SKCTL[1:0]==00) -- check OUR SKCTL in the intro.

  **PHASE CORRECTION + THE STRUCTURAL RESULT (2026-08-14, latest).** The t=45 s
  capture was NOT the intro -- it was the GAME (the intro ends and the game
  starts, as Simon observed). The TRUE intro window is t~31-35 s. Captured there
  (1,282,800 entries, DROPS=0): page $3000 dominates with 1,273,246 samples, in
  regions $30CC-30F1, $3307-33A1, $33D3-33E7, **$37D3-37D9**, $37FC-3854,
  $3DE0-3E6A.

  Against Altirra's intro, executed on OURS in that window:
      $3AB0 sprite plotter .... 0 samples
      $3043 dispatcher ........ 0 samples
      $3282 / $32C3 ........... 0 samples
      $3950 sprite table ...... 0 samples
  and none of those four routines' opcode signatures match ANYWHERE among our
  5314 executed PCs. Both machines run page-3 code; they run DIFFERENT ROUTINES
  AT DIFFERENT ADDRESSES. Altirra's intro dispatcher chain is $3043 -> $3282 ->
  $32C3 -> $32CF (from alt.callstack()).

  **THIS VINDICATES THE ORIGINAL $37AE OBSERVATION.** Our machine really does
  execute $37xx code that Altirra never runs -- $37D3-$37D9 and $37FC-$3854 are
  right there in the true intro window. Earlier doubt cast on that finding (from
  a trace taken at t=45 s, i.e. in the GAME) was the phase trap again, and is
  withdrawn. SCOPE EVERY CLAIM TO ITS WINDOW: load = t~2-6 s, intro = t~31-35 s,
  game = t~45 s+.

  Combined with the machines being in LOCKSTEP THROUGH THE LOAD (identical
  loader, same spin loops, bytes 18/18), the picture is exactly Simon's
  SEMI-CRACK: same disc, same loader, same sectors, then the protection check
  fails on ours and it runs a DIFFERENT INTRO IMPLEMENTATION -- one that never
  sets PRIOR=$54 and never drives the four missiles as the fifth-player figure.

  **CAVEAT ON THE OPERAND CHANNEL:** tools/trace_writes.py resolves operands by
  peeking ALTIRRA. That is only valid where the two memories AGREE (it held for
  the loader, 18/18). It is INVALID for our $3xxx intro code, which Altirra does
  not have. Decoding our own intro's P/M writes needs a guest-RAM read path,
  which does NOT exist (XT_DBG_STRM_RADDR/RDLO/RDHI address the trace ring).

  **BETTER NEXT MOVE — diff at the PROTECTION READ, not in the intro.** By the
  intro the two machines have long since parted, so diffing there only re-measures
  the gap. Sector 130 is read at roughly transaction 34 of 302, about 11% into a
  ~34 s load, i.e. ~3-4 s in. Capture our trace across t=2..6 s and compare with
  Altirra at the SAME CODE LANDMARK to see what each does with the CRC error.
  The ring holds ~2 M entries (~4.4 s), so a whole load needs ~8 captures.

  **INSTRUMENT NOTE — this nearly produced a false finding twice.** The first
  decode reported "zero writes to $D000-$D01F" with an empty --summary. That was
  a DEAD CHANNEL, not a result: Altirra was running WITHOUT THE DISK (bind()
  failed 48 on a stale port, so a previously-running instance was answering) and
  sat in a 2-instruction spin at $5109/$516d for 210 s of emulated time with
  operand resolution frozen at 9/107. With the disk actually mounted it resolves
  92/107 after 900 frames. ALWAYS validate the operand channel in the SAME run
  (peek a known-live address; note alt.regs() returns UPPERCASE 'PC').

  **THE ONE DURABLE UNEXPLAINED FACT:** both machines have IDENTICAL
  PMBASE=$2c / DMACTL=$3d / GRACTL=$03, yet our machine executes code at $37AE
  every frame while Altirra has $00 across $3700-$37FF at EVERY sample in 1800
  frames. The hardware config matches; the CODE PATH differs. What selects it is
  unknown. (The missile-strip write at $3B18 is an ordinary read-modify-write
  sprite plotter through a zero-page pointer and is probably legitimate — the
  ball is plausibly drawn with missiles.)

  **TOOLING BUILT (the durable win):** `6502 dtrace <secs>` streams a gap-free
  instruction trace to DDR over HP0 WITHOUT halting the core (the old tracer
  halted it, which tore the disk load and produced a convincing FALSE story);
  Altirra gained a matching `TRACEFILE` command; `tools/trace_diff.py` diffs the
  two with interrupt-skew tolerance and an allowed-divergence resync past the
  patched SIOV vector. It matched 214,237 instructions before finding a real
  split.

  **MEASUREMENT TRAPS THAT COST HOURS — read before measuring anything:**
  PHASE MISMATCH (comparing the two machines at the same wall-clock second or
  frame number produced at least three false leads; anchor on a CODE LANDMARK);
  unvalidated readout channels (a PCOLR-colour readout returned black whatever
  the value and produced a false "collisions are broken" finding — use POSITION,
  and validate the channel in the SAME run); absent stimulus (a
  player-vs-playfield test returned $00 on both only because the screen had no
  ink); metrics that conflate objects (a "centroid" of vehicle+ball+background
  appeared to show a fix that was not there); and coarse sampling (every 4th
  frame made a smooth sweep look like 16-CC jumps).

- **Emulator window chrome: COMPLETE, verified end-to-end on hardware.**
  Open the 6502 window -> zoom in (2x -> 3x) -> zoom out (-> 1x) -> full screen
  -> pointer into the letterbox reveals "Exit full screen" -> click it -> back to
  the desktop with the menu bar restored and the windows behind intact.
  Three fixes were needed underneath, each the same shape: something assumed the
  plane and the window were the same rect, or that a client-side call reached the
  server.
    1. gemd placed the plane by STRETCHING it to the work area.  It now takes the
       plane's SOURCE size with the bind and centres the box.
    2. The alpha hole was still punched over the WHOLE work area, and `draw_content`
       returned before blitting the backing store -- so everything the app drew
       around the picture was not merely covered, it was never composited.  The
       hole now follows the PICTURE (`wind_plane_box`) and the surround is the
       app's pixels, which is what makes a letterbox black rather than transparent.
    3. `menu_bar(tree, 0)` only cleared the client's own pointer; gemd went on
       compositing the reserved band above every window.  GEM_MENU_BAR now carries
       a show flag, and hiding UNRESERVES the band so a window can own y=0.
       Re-reserving it moves every window's work area, so the show path repaints.
  Plus: a window that opens takes the focus, without which motion never reached
  the full-screen window at all.
  **A process trap worth remembering:** `make build/desktop.so` does NOT refresh
  `build/sdstage/OS/bin/desktop`.  Two rounds of "pushed" delivered a stale binary
  and the fixes looked like they had failed.  Run `make sdstage` before pushing.

- **(superseded) Emulator window chrome: buttons and full-screen LANDED; two gaps left.**
  The 6502 window carries three title buttons (zoom out, zoom in, full screen)
  through the existing `WM_TBUTTON` path, so the desktop never hit-tests a
  titlebar rect (§11).  Verified on hardware: the buttons draw, and the
  full-screen button blacks the screen and rebinds the plane to a borderless
  full-screen window.
  gemd also stopped assuming a bound plane FILLS the work area.  It now takes the
  plane's SOURCE size with the bind and centres the box, which is what lets a
  full-screen window letterbox instead of scanning DDR past the end of the
  writeback buffer into the window — a latent bug the old "size the window to the
  plane exactly" contract only hid.
  And a window that OPENS now takes the focus (`gemd_focus_window`).  Motion goes
  only to the focused window, and focus followed clicks alone, so a
  programmatically opened window never heard the pointer; the desktop had already
  hand-worked-around the keyboard half of this.

- **Virtual SIO drive: BUILT and answering; BallBlazer not yet loading.**
  The whole path is live on hardware — `xt_sio_drive` decodes and checksums the
  command frame, `xt_sio_cdc` crosses to the A9, `xl_sio_bus_poll` runs the same
  `xl_disk_op` the SIOV stub uses, and the drive paces the reply at the guest's
  own rate.  Instrumentation in `SIO_DSTAT[31:8]` reads frames=96, bytes=224,
  **accepted=12**, with `busy` set and `req_pending` clear — i.e. the full
  round trip completes.  ATR loading is unaffected (ElektraGlide and Despatch
  Rider both verified with D1: claimed).
  **RESOLVED 2026-08-13: BallBlazer.atx loads off the virtual serial-bus drive.**
  The bus log shows `dev=31 cmd=52` reads of D1: advancing one sector at a time
  from $25 to $10B, every one `st=01 len=0080` with a clean FDC, no retries and
  no errors, while the 6502 runs on through game code with interrupts enabled.
  What finally did it was pacing the reply at a MEASURED bit rate (below).
  Remaining: strip the diagnostic counters, and confirm the picture in a desktop
  emulator window rather than from the transaction log.

  **Two more layers landed, and the guest now gets its data.**
  (a) The ACK turnaround was paced in FRAME TIMES, which scale with the bit
  rate; a real drive's turnaround is a fixed physical time.  Pacing it as an
  absolute ~1 ms plus an `IRQEN[5]` gate made `irqen5_at_ack` read 1 — the guest
  IS listening when we ACK.  (b) The reply then stalled after exactly one byte
  per frame, because `pace_done` was gated on the guest's `shift_tick` and a
  guest STOPS that clock while it reprograms its POKEY timers between sending
  the command and receiving the answer.  A real drive has its own baud
  generator: the pacing now tracks the tick when it runs and falls back to an
  absolute ~520 µs period when it does not.  `tb_xt_sio_drive` T5 had asserted
  the WRONG model (that a stopped clock means silence) and hid this.
  **Where it stands (2026-08-13).**  BallBlazer's loader runs off the end of its
  wait loop into game code, and the bus log shows real traffic: `dev=31 cmd=52`
  reads of D1: sectors returning `st=01 len=0080` with a clean FDC.  The screen
  says LOAD ERROR.  **The signature to chase: every sector is requested 6-10
  times** — the guest is RETRYING, so it is receiving our reply and rejecting
  it.  That is the data frame, not the framing and not the ACK.  Check, in
  order: the data checksum as POKEY computes it; whether the guest's timeout
  expires before the last of 131 bytes lands; and whether BallBlazer's loader
  reprograms POKEY to a rate the pacing should be tracking but is not.
  Instrument the reply side — a "reply abandoned before the last byte" counter
  answers all three at once.
  (Historical, for the shape of the earlier diagnosis.)  Reading the counters as
  "frames are truncated" was wrong.  Latching /COMMAND against transient PBCTL
  mode changes (24d5e5cd) was built on that reading and changed nothing
  measurable: 96/224/12 before, 94/214/10 after.  The better reading of the same
  numbers is that there are only ~10 REAL command frames — each complete, each
  ACCEPTED — plus ~84 spurious /COMMAND assertions that catch a stray byte or
  two and are correctly rejected on checksum.  So the framing works.
  That puts the problem in the REPLY: ten frames accepted, ten replies paced
  back, and the guest still waits at `$BC4C`.  Next to check, in order — does
  `ser_in_byte_pulse` actually raise IRQST bit 5 for the guest (is IRQEN[5]
  set when we pulse?); is the ACK/COMPLETE/data ORDER right; is the data
  checksum right; is the pacing inside the guest's timeout.  Instrument the
  REPLY side rather than guessing again — the frame counters earned their build,
  a reply-side counter will too.
  **The 84 spurious asserts are themselves worth explaining** before trusting
  any of this.
  Three bugs were found and fixed getting this far, all worth remembering:
  a missing CDC synchroniser on `/COMMAND` (antic_top is clk_sys, the drive is
  clk_sally) which stuck `busy` on; `drv_sel` following `busy` so a stuck drive
  starved the SIOV stub's mailbox port; and a command watchdog SHORTER than a
  command frame (655 µs vs ~4 ms) which aborted every legitimate frame.
  **Strip the diagnostic counters when done** — they cost clk_sys margin
  (+0.001 ns on the instrumented build, +0.266 without).
- **(superseded) BallBlazer.atx needs a VIRTUAL DRIVE ON THE SERIAL BUS, not a better disk
  image.**  ATX support landed (`xl_boot.c`: sector map, missing/CRC/deleted
  sectors, weak bits, and a 288 RPM rotation model for duplicate sectors) and
  the image mounts and serves correctly — BallBlazer reads sectors 1-8 and
  10-17, correctly skipping the 9 that is genuinely absent (9 and 18 are absent
  from every one of its 23 populated tracks).  It then stops at its own LOAD
  ERROR, and the reason is not the disk at all: **it is a fast loader that
  bypasses SIOV and drives the bus itself.**  The loaded code programs POKEY
  channels 3/4 as the bit-rate generator (`$D200-$D207`), asserts /COMMAND
  through PIA PBCTL (`$D303`), clocks the frame out of SEROUT (`$D20D`), sets
  SKCTL (`$D20F`) and enables the serial IRQ (`$D20E`) — then waits at `$BC4C`
  for its interrupt handler to count `$D2` down to zero and set `$CA`.  No drive
  answers, so `$CA` never becomes 1 and it lands in its error loop at `$BCC7`
  (`LDA $D20A / AND #$F6 / STA $D01A` — the rainbow stripes on screen, with the
  "LOAD ERROR" screen codes at `$BCDE`).
  Our paravirtual SIO hooks SIOV, so it serves the OS boot loader and nothing
  else.  Making this class of title work means emulating a 1050 at the SERIAL
  level: watch /COMMAND, decode the 5-byte command frame, and reply with
  ACK/COMPLETE plus the data frame at the loader's own (non-standard) bit rate.
  That is where SIO TIMING has to be modelled properly, and it is the same
  capability `pokey_serdirect` / `pokey_skstat` are parked on — currently `na`
  in the ACID sweep for exactly this reason ("no serial bus device").
  **Designed: `docs/OS/sio-bridge.md` §13** — the virtual drive as a third
  transport into the mux `pokey_serial.sv` already anticipates, a per-ID
  ownership table (`PHYSICAL`/`VIRTUAL`/`UNCLAIMED`) so a real peripheral on the
  DIN port and a mounted image can never both answer, four drives with
  INDEPENDENT rotation phase (Alternate Reality uses four at once), and
  authentic-by-default with the SIOV shortcut kept as an opt-in per-title "fast
  load".  Note §13 also corrects §2/§11: `pokey_serial.sv` IS built and
  instantiated, so the serial shift timing is not missing — only the responder.
- **Launch an 8-bit app from the desktop** — the A9 reads the file, looks up its
  prefs (a namespace in the single SQLite registry), serves it as a **virtual disk**
  (ATR direct; XEX wrapped in a synthesized boot disk; cart via the cart window) and
  **cold-boots** the fabric 6502 (the A9 serves sectors, the XL OS does the load —
  no 6502 PC control needed). Two app classes by XEX header: `$FFFF`/ATR/CAR =
  **classic** (emulator surface, scale 1–5 / fullscreen-with-pillarbox, mouse-move
  chrome + `[Home]` to close, raw input to POKEY/PIA); `$FFFE` = **GEM app** (a 6502
  GEM client → A9 GEM service → a desktop window, AES input + window close-box, the
  emulator surface hidden/debug). Cold-boot per launch now → **"launch task"** once
  multitasking lands (→ multiple GEM windows). *(design ready, not built; src:
  docs/OS/app-launch.md)*

## Multitasking / self-hosting / compiler
- **xcc ARM back-end (`XTARMLowering`)** — the critical missing compiler piece
  (~3,000 lines); gates ARM-native apps, the dynamic loader, and the GEM ARM client.
  Target = **Cortex-A9 / ARMv7-A / AArch32** (port *from* the arm64 backend — a real
  ISA change, not a tweak). Consolidated port requirements (C-ABI/newlib interop,
  PIC/ET_DYN minimal-reloc, `svc #1` syscall stubs, ARC + unmanaged subset, DWARF +
  full backtrace) in **docs/OS/xcc-on-arm9.md**. *(Phase 1; immediate next step if
  greenlit; src: docs/MultiTasking/self-hosting.md, docs/OS/xcc-on-arm9.md)*
- **Port stdlib file I/O to the Zynq side** — SD/FAT32 driver via FreeRTOS exposed as
  a trap class (<200 lines). Then write `xcc.xt` in xcc (self-host bootstrap), feature
  parity (`-O1/2/3`, self-hosted 6502 back-end), benchmark a parse on the Zynq first.
  *(src: docs/MultiTasking/self-hosting.md)*
- **6502 (SALLY) multitasking kernel** — scheduler + loader + syscall/BRK handler +
  GEMDOS proxy (~10-14 days; HW foundations exist). v1 stubs MiNT signals to ENOSYS
  except kill/wait/exit; true memory protection needs a fabric MPU (~1500 LUTs, no
  exception model today). *(src: docs/MultiTasking/multitasking.md)*
- **SALLY tasking HW (decide early)** — SP_BANK/ZP_BANK per-task registers (~50 LUTs,
  fmax-neutral); optional tick IRQ + atomic CAS (preemption); HW context-switch
  instruction (~100 LUTs); wider 11-bit SP + stack-relative addressing (fmax-risky,
  needs xcc compiler hooks); cheap IRQ auto-push A/X/Y. *(src: docs/GEM/GEM-implementation.md,
  docs/MultiTasking/banked-stack-context-switch.md)*
- **ARM-A9 dynamic ELF loading** — feasible (~1-2 weeks) but deferred until a concrete
  ARM user-app use case; main risk is `-fPIE` `r9` PIC ABI vs the FreeRTOS BSP. *(src:
  docs/MultiTasking/multitasking.md)*
- **m68k EmuTOS/MiNT port** — ~480-line board-support port; blocked on the m68k soft-
  core / JIT existing first. *(src: docs/MultiTasking/multitasking.md)*

## 6502 / xt embellishments

- **$x2 SP-relative opcodes** — `AND/ORA/EOR d,SP` in the spare `$82/$C2/$E2` slots.
- **$x3 SP-indirect family** — twelve free `$x3` slots for SP-indirect variants.
- **65C02 `$80` BRA / `$89` BIT #imm** — trivial; harmless NOP on NMOS.
- **Dual-port stack BRAM speedup** — PSH/PLL 8/9 → 5 cycles via dual-port (or 16-bit)
  stack BRAM in `sally_mem`. *(optimisation; src: docs/6502/6502-embellishments.md)*

- **NMOS illegal opcodes for software compat** — `xt6502` passes Klaus but Klaus is
  documented-only, so it currently decodes **none** of the undocumented opcodes (they
  fall through to `default`). Real A8 software needs them: **Prince of Persia** (A8 port)
  executes `ANC $0B`, `SAX $87/$97`, `LAX $A7` — confirmed by an instrumented-atari800
  trace (see memory `pop_illegal_opcodes`, reproduce via `scratchpad/atari800-src` cpu.c
  hook). Without them the PoP intro breaks exactly like it does on a 65C816 (Rapidus).
  - **Scope.** Implement the *stable* set: `LAX SAX DCP ISC SLO RLA SRE RRA ANC ALR ARR
    SBX` + the undoc-NOPs. Skip the *unstable* group (`ANE LXA TAS SHA SHX SHY LAS`) —
    analog-magic-constant behaviour, and no real software depends on it (PoP doesn't).
  - **Decode is free, datapath is the risk.** The decoder is off the `clk_sally`
    critical path (ALU carry chain + `sally_mem` read mux + routing is the ceiling), so
    extra opcode patterns cost LUTs, not MHz — in *both* decode modes (one decoder, one
    clock; STA already times the worst case). The fMax trap is implementing the heavy RMW
    combos (`SLO/RLA/SRE/RRA/DCP/ISC`) as single-cycle fused ALU ops — do them as
    **multi-cycle micro-sequences reusing existing ALU primitives** (extra FSM states,
    zero new combinational depth), like the embellishments already do.
  - PoP's three are all shallow anyway: `LAX` = load fan-out to A+X (no ALU), `SAX` =
    store `A&X` (one AND, no flags), `ANC` = `AND` then bit7→C/N (a wire). Effectively
    free even on the binding constraint.
  - **cc=11 coexistence.** The `$x3` embellishments overlap NMOS `SLO/RLA` (`$03/$13/$23/$33`),
    but the native-decode gate muxes *meaning* per mode — compat decode keeps NMOS-illegal
    semantics, native decode emits the embellishments. It's a correctness switch, not a
    speed switch (no per-mode clock difference). PoP uses `$x7/$xB`, not `$x3`, so no
    clash with the chosen embellishment slots regardless.

- **Dedicated "fidelity / 1× purist" 6502 core (design option)** — a
  *second* CPU optimised for **correctness, not speed**, run at 1× with ~50× timing
  slack. It's the clean home for the things the turbo core architecturally *can't* do
  (and shouldn't be contorted to): cycle-exact dummy reads / exact bus-cycle pattern
  (turbo is registered-MAR, 1 fabric clk/op, no round-trip), the **unstable** opcode
  group, exact NMOS decimal flags, RMW double-write timing — i.e. the same fidelity the
  **position-exact-raster stretch** wants (see memory `sally_halt_not_modeled`:
  ACID800 / RastaConverter, CPU↔ANTIC phi2 phase-lock). Bonus: a fabric cycle-exact
  core doubles as an on-chip co-sim oracle for the turbo core (hardware analogue of the
  golden-trace `cosim_diff.py` flow).
  - **Not for the common case.** Stable illegals on the turbo core already cover PoP +
    ~99% of software far more cheaply. Only build this for a genuine *cycle-exact
    faithful mode* feature.
  - **Switch is cold, at app launch** — no live A↔B state hand-off (machine resets and
    reloads the app either way). Shared RAM (ZP/stack/screen) lives in the memory
    subsystem both cores reach; only one core is active at a time.
  - **Area is cheap, integration is the cost.** A 6502 is a few k LUT/FF and ~zero extra
    BRAM (BRAM hogs are screen + page cache), so a small LUT bump and barely a touch on
    the binding BRAM budget. The real cost is the bus/boundary into `sally_mem` + 2×
    verification surface, not area.
  - **Three implementation options:**
    - **(A) Both cores resident + 2:1 bus mux.** Simplest build; instant switch; all
      subsystems stay live. Cost: the mux lands on the binding `clk_sally` CPU↔`sally_mem`
      path (~0.3–0.5 ns ≈ 1 LUT level). Current operating point is **100 MHz** (`clk_sally`
      100 / `clk_sys` 133 / `clk_pix` 148; 120 no longer closes off-the-shelf), so there's
      more headroom than the old 120 target — but it still eats margin on the binding
      family, so gate any build on `clk_sally` WNS ≥ 0. **Written up as a build in
      docs/Design/dual-cpu-resident-mux.md** — reuses `sally_clock` as the fidelity-core
      cycle-enable (no 1.79 MHz clock domain, no CDC) and the `xt6502_debug`
      snapshot/inject ports as the core-to-core state handoff, so it is mostly wiring;
      §5 there gives the mux-retime mitigations if the one LUT-level won't close.
    - **(B) Partial Reconfiguration** — CPU in a Reconfigurable Partition, swap the core
      via a small partial bitstream over PCAP from the A9 (sub-ms, invisible at launch),
      **HDMI/ANTIC/compositor/PS-links stay live**. Removes the 2:1 mux. *Catch:* the RP
      boundary is a hard fence — if the CPU is in the RP and `sally_mem` is static, the
      binding CPU↔memory path crosses the boundary through fixed partition pins and can
      gain delay (trades the mux penalty for a boundary penalty). **fMax-neutral only if
      the RP is floorplanned to contain the entire `clk_sally`-critical loop** (CPU +
      registered MAR + `sally_mem` read mux); boundary then carries only slow signals.
      Keep all RAM static so it survives the swap (trivial for cold-launch). The RP needs
      a Pblock — familiar ground (the design already floorplans with pblocks, e.g. the
      sally pblock), but PR layers a *hard boundary* constraint on top of the usual
      placement-only pblock. Adds the Vivado PR flow (RP + per-core Reconfigurable Modules,
      Pblock sized for the larger fidelity core, decoupler, post-load reset). PR is
      license-free on 7-series.
    - **(C) Two full bitstreams, PS loads at launch** — cleanest per-core timing (flat
      builds, no mux, no boundary), but a full reload **blanks the whole display + re-syncs
      PS↔PL** every launch (bad UX). Rejected unless the display teardown becomes
      acceptable.
  - **Recommendation (updated 2026-07-18):** start with **(A)** — on the LUT-rich 7020 a
    second resident 6502 is a rounding error in area (~1.9k LUT, **0 binding BRAM** — the
    fidelity core is logic; the 22 BRAM live once in the shared `sally_mem`), and (A)
    avoids the entire DFX flow + partition-pin fence. Its lone cost is one 2:1 LUT on the
    binding path, self-gated by our WNS-≥0 build abort. **(B) PR is the fMax-purist
    fallback** if that LUT-level won't close after the docs/Design/dual-cpu-resident-mux.md
    §5 mitigations — it removes the mux at the price of the RP fence. Either way, sequence
    it **after** stable illegals land, and only when cycle-exact faithful mode is actually
    wanted. (Prior recommendation was (B); flipped because the resident-mux handoff turned
    out to reuse existing infrastructure — `sally_clock` + the debug inject ports.)

> See also the parked branch `xt-embellishment-relocate` (opcode relocation to free
> the cc=11 undoc territory; ISA-correct but costs ~150 ps — cherry-pick after fmax
> levers land).

---



# Future targets

## JIT 6502 as a performance "core" (PARKED — gated on the fidelity core first)
Simon, 2026-07-31: a dynamic recompiler could give a performance core alongside
the cycle-exact one (ref: jahej.com "JIT CPU emulation: a 6502 to x86 dynamic
recompiler"). **Explicitly gated: only once the fidelity core is up and
running.** Notes so the option stays open rather than being designed out:
- It maps onto the **turbo** role, not the fidelity role — the same split the
  fabric already has (`xt6502` turbo vs `xt6502f` fidelity, cold-switched at app
  launch, docs/Design/dual-cpu-resident-mux.md). A recompiler cannot be
  cycle-exact per bus cycle *and* fast; that is the whole trade.
- **The interaction to watch is with ANTIC, and it is the crux.** The software
  design has ANTIC running INSIDE the CPU's bus-cycle callback (emu/antic-design.md).
  A JIT's speed comes from *not* leaving a basic block per cycle — so a naive JIT
  and a cycle-exact ANTIC are mutually exclusive. The workable shapes are: run the
  JIT only when DMA is off/uncontended and fall back to the interpreter when ANTIC
  is stealing; or compile per-block with a cycle budget and check the budget at
  block boundaries. Decide this BEFORE writing a JIT, not after.
- Other 6502-JIT hazards, cheap to note now: self-modifying code (needs page
  invalidation of compiled blocks — Atari software does this), computed jumps
  into mid-block addresses, and the undocumented opcodes already implemented here.

## SSH (HW-VALIDATED end-to-end; docs/OS/ssh-server.md)
Server + client + scp all work — HW-confirmed: clean boot (Networking/SecureShell/
Desktop all [OK]), `ssh xtos.local` login, exec, scp both ways, boot-script start,
per-boot /var/log/sshd.log with real peer IPs, SIGWINCH. The session-exit hang
(interactive `exit`/Ctrl-D used to hang, then crash on HW) is FIXED and confirmed
on the board — `ps` after Ctrl-D shows sshd-session + login shell cleanly reaped.
Root cause was dropbear's SIGCHLD-gated reap + the fake-vfork wiping the SIGCHLD
handler; fix = synchronous SIGCHLD delivery + a vfork-armed guard on signal()/
sigaction(). (A late loader-COW misstep during this work — folding the RELRO
segment into COW — briefly crashed sshd-session on connect; reverted, see
loader-wx-multi-segment.) Open:
- **scp crashes on HW during the SD file write** (interactive + non-pty exec +
  1.2 MB bulk channel transfer ALL work HW-validated; scp is the lone failure).
  sshd-session takes a wild-jump PREFETCH-ABORT: a PLT stub reads dropbear's
  memcpy .got.plt slot and finds GARBAGE (`0x5c7bdab4`), so dropbear's private
  COW copy of that GOT page is corrupted mid-transfer. Bisected: `ssh host 'cmd'`
  and `ssh host 'cat /System/bin/*' | wc -c` (1.2 MB, no SD) both pass → it is
  specifically the scp **SD-write** path, not exec or bulk crypto. Ruled out:
  DMA unaligned-edge invalidate (Xil_DCacheInvalidateRange clean+invalidates
  edges correctly), the shared page pool double-allocating (dpage_raw is
  IRQ-critical-section safe). Leading theory: a page-lifetime / DMA-coherency
  interaction between the fs-task SD writes and dropbear's cached GOT page (the
  fd page-cache and COW pages share dpage_raw's pool; PIPT, no cache maintenance
  on reuse). Needs ON-BOARD instrumentation (log/catch the writer of the GOT
  physical page during a transfer) — not fixable by code-reading. Two kernel
  hardening fixes DID land here and stay: vm_cow_read_fault + vm_exec_fault
  (service stale-section-TLB read/prefetch faults instead of killing the task).
- **sftp** — no server binary yet (scp covers file transfer).
- **lwIP loopback** — the board can't ssh/scp to 127.0.0.1 (no `lo` netif; the
  connection wedges the stack). Outbound to real peers is fine. *(loader-networking)*
- **mDNS dropped off mid-session once during bring-up** (IP stayed up; fine after
  reload) — watch for recurrence; loader-networking, not ssh.
- **Merge `ssh-server` → `main`** once soak-tested on HW.

## Open Issues (tracked bugs)
- **A loaded libGEM.so re-running `vdi_init` wipes the kernel's live VDI** — the
  `gemhw`/runhost demo (`xtld_host.c`) resolves `vdi_init` from the loaded `libGEM.so`
  and calls `vdi_init(&desk)`; because the kernel and libGEM share the symbol, that
  **resets the shared workstation table**, invalidating the desktop's `g_vh` and
  overdrawing the desktop (lost wallpaper). Symptom: after the demo runs, `vdi.*` →
  "vdi not initialised" and `vdi.wscount()` drops to 1. (NB: this — not any blitter
  bug — was the cause of the earlier "`vdi.bar` draws nothing"; with a valid `g_vh`
  fills work. Also note `dow` ELF-reloads accumulate this kind of stale VDI state — a
  cold-load restores it.) Fix: the loaded GEM must not re-init the kernel's live VDI —
  either guard `vdi_init` against clobbering an initialised table, or give the demo its
  own workstation without resetting. *(vitis/xtos/src/xtld_host.c, gem/vdi/core.c)*

## Post-architecture-review
 (Tracking `docs/Design/architecture-review.md`)
- **Partial-reconfig CPU swap.** RP region confirmed viable at X1Y2 (not the PS
  corner — hard blocks there). Implement: `sally_subsystem` wrapper → exclusive RP
  pblock → DFX static/RM flow → runtime PCAP swap. *(docs/Design/partial-reconfig.md)*
  
- Still open: the **ST compositor plane** (bind enum ST-ready,
  plane not wired); and verify/close the **VDI-workstation leak** (direct `vdi.*` after
  `wintest` draws into a window backing, not the desktop). *(docs/OS/desktop-emulation-windows.md)*

- **§3.1 ACP coherency** (evaluate on GEM/desktop surfaces), 

## HW / RTL bring-up
- **Keyboard injection host source** — RTL path is done (GP0 → `$D4CF` → POKEY).
  Remaining: a host-side source + ASCII→KBCODE map. *(likely partly covered by the
  serial `{ }` paste path — verify; src: former docs/TODO.txt)*
- **GPIO LED MIO mapping** — `main.c` LED toggle waits on Z-Turn MIO confirmation.
  *(src: docs/bring-up.md)*

## Video / compositor / sprites / textures
- **Palette: PAL/NTSC runtime re-push** — page a non-default reference palette in via
  $D483-$D486 on region switch (bake-in is the default); plus more accurate reference
  tables. *(src: docs/HDMI/palette.md)*

## Audio (PCM1808 capture + HDMI audio)
- **Analog-audio fidelity (Altirra App. E)** — post-mixer DSP: channel-DAC bit
  weights, non-linear saturation, AC coupling, DC bias. *(skip until a "purist" mode
  is wanted; src: docs/Design/aux-audio-and-reservations.md, docs/Altirra/altirra-pokey-audit.md)*

## Memory / banking (DDR3 banked window — parallel track, not on boot path)
- **Reserve + validate the DDR3 region** — 0x2000_0000 code / 0x2040_0000 data; keep
  PS out of 0x2000_0000-0x207F_FFFF; validate with an explicit $D5C0/$D5C1 bank-switch
  test (boot won't exercise DDR3). *(src: former docs/TODO.txt)*
- **Provisional memory regions not yet wired** — 68k "T" realm (0x1C00_0000), GEM
  heap/asset cache (0x3800_0000), sprite arena (0x3400_0000). *(src: docs/Zynq/memory-map.md)*

## Filesystems (VFS + block-device layer — loader foundations landed)
- **Swap** — VM page-out/in over the `blkdev` layer: a dedicated swap partition exposed as a
  `blkdev`, or the pager calling `blkdev_write/read` on `sd0`. Revives the parked demand-paging
  work; needs MBR partition parsing (`sd0p1…`) for a swap partition. *(src: loader blkdev/VFS)*
- **MinixFS** — a `vfs_fs` driver reading blocks via `blkdev_read(sd0,…)`, mounted with
  `vfs_add_mount`; needs no syscall/fd changes (the VFS dispatch is filesystem-agnostic).
  *(src: loader blkdev/VFS)*

## SIO / PBI / cartridge / companion MCU
- none

## GEM (VDI + AES) / desktop
- none


## Thermal / cooling (closed-loop fan)

- **DONE on the STM32 side (2026-08-12), with the split changed: the A9 pushes
  TEMPERATURE, not duty, and the STM32 owns the curve.** Forced by the link
  direction — the FPGA is the SPI master, so the STM32 *cannot poll it*; a slave
  cannot initiate. It is also the better split: the controller lives next to the
  actuator, so an A9 hang cannot stop the fan. The A9 writes the XADC junction temp
  to **`SPI_REG_TEMP` ($07)**; `fan.c` maps it to an RPM setpoint (quiet floor 1200
  rpm below 55 °C, linear ramp to 4500 rpm at 70 °C, full duty above that) and the
  existing tach PID holds it. **Failsafe verified on hardware**: no temperature ever
  received, or one older than 10 s, forces 100 % duty. Measured: 50 °C -> 1200 rpm,
  62 °C -> 2740 target, 68 °C -> 4060. REPL `fan thermal` / `fan temp <c>`.
  Remaining on the A9 side: push the temp byte each period, and surface tach RPM +
  target in `/proc`.
- **Closed-loop fan control (A9 curve → STM32 PWM/tach, failsafe-to-100%).** HW
  outlet added on the motherboard (5V / GND / Tach / PWM); Tach+PWM wired to the
  STM32 companion. Planned fan: **Noctua NF-A4x20 5V PWM**, mounted in the case
  next to the Zynq for direct heatsink impingement — the heatsink is
  convection-limited (a *breath* moved the die ~1 °C; the fix that took it 78→66 °C
  was passive), so steady airflow should pull the ~66 °C sustained-load temp well
  into the 50s. Design follows PS-does-config / companion-does-plumbing: the **A9
  reads the XADC junction temp** (the real silicon, ~20 °C above the I2C board
  sensor — the honest input) and runs a **tunable fan curve** (quiet floor below
  ~55 °C, ramp toward ~70), pushing a duty byte to the STM32 over the companion
  SPI link each period; the **STM32 makes 25 kHz PWM + reads tach** (input
  capture) and reports RPM back. **Non-negotiable failsafe on the STM32:** spin
  **100 %** at power-up and whenever the A9 update goes silent past a short
  watchdog (hang / reboot / cold-load) — the safe failure of a thermal loop is
  LOUD, not off; a crashed controller must never be able to cook the chip. Surface
  tach RPM + current target in `/proc` (extend `/OS/proc/temp` or add
  `/OS/proc/fan`) next to the die/board temps + peak-hold, so a `cat` shows the
  loop converging. *(gating: needs the case/enclosure to physically mount the fan
  + the motherboard to exist; src: STM32F411 companion — docs/OS/sio-bridge.md;
  XADC die temp in /OS/proc/temp; "PS does config, PL/companion = plumbing")*

## Math coprocessor (A9-offloaded FPU + integer + SIMD)

Built: PL math page + doorbell (sim-validated, `make mathcop`) and the A9
service (ISR + FPU worker + scalar/vector op interpreter, in the kernel).
See docs/Design/math-coprocessor.md.  Open:

- **HW validation** — flash the IRQ_F2P[1] bitstream, run a 6502-side test
  program (Horner + 4×4 matmul + per-op-class goldens vs A9-computed values),
  measure the real round-trip µs and record it in the design doc.
- **6502-side include** — hand-written `.inc` (or generated from mathcop.h)
  with the register/opcode constants for asm clients.
- **OS chunk allocation** — allocate math chunks per task out of the
  screen_bank chunk stack + `$D5C8` retarget on context switch (and the
  completion-while-preempted notification path, chunk→task in the service).
- **xcc lowering** — target the slot file as a register machine; lower array
  expressions to the vector ops.
- **$D800 FP ROM patch** — route Atari BASIC's floating point through the
  coprocessor transparently (the visible payoff demo).
- Deferred fast paths: ACP-coherent chunk traffic; NEON in the worker.

---

## DSP56001 (Falcon DSP) in fabric (design option — gated on Falcon/m68k target)

The Atari Falcon's Motorola **DSP56001** (24-bit, ~16 MIPS @ 32 MHz). Wanted if the
Falcon becomes a target alongside the m68k. Conclusion of the design thread: build it
**wide, in fabric** — *not* on the A9 and *not* serialised.

- **Why fabric (not A9-emulated).** Both A9s are committed once Falcon is a target —
  one runs GEM/graphics, the other the JIT 68030 ([[m68k_core_mmu_requirements]],
  docs/MultiTasking/multitasking.md). No spare host for a Hatari-style DSP emulator, so
  the "just emulate it" route (which would otherwise win on effort) is off the table.
- **Loose coupling is the unlock.** The real Falcon Host Interface (HI) is an
  **asynchronous mailbox** — the 68k uploads code/data, pokes a command, the DSP runs
  independently on its own clock and replies through the same mailbox. So the fabric DSP
  talks to the A9-JIT-68k through memory-mapped HI registers/FIFO **across a clock-domain
  boundary, with no cycle-lockstep** (reuse the existing hwreg/CDC/GP0 plumbing, same as
  the math coprocessor). The hardest coprocessor problem — keeping two engines in sync —
  doesn't exist here by design.
- **Microarchitecture: wide execute + multi-cycle *non-overlapped* decode.** Decouple
  the **ISA-visible contract** (one emulated 56k instruction-cycle per "tick", which is
  all the HI/SSI boundary + cycle-accuracy care about) from the **internal gate-level
  timing** (as many fabric cycles, as deeply staged, as convenient):
  - *Wide execute.* The 56k has only ~6–8 data-ALU registers (X1/X0/Y1/Y0/A/B) — make
    them flip-flops → unlimited concurrent reads for free; replicate the two AGU adders;
    give X and Y their own BRAMs (Harvard wants this anyway). The "many buses" become
    wide combinational muxing in the **spare LUTs**. Bonus: doing the parallel moves
    genuinely simultaneously makes the 56k's simultaneous-move semantics **bit-exact by
    construction** — no operand-snapshot bookkeeping (which serialising would have forced).
  - *Staged decode, one instruction in flight.* The dense 24-bit parallel-move encoding
    needn't be one scary combinational step — stage it over 4–6 shallow fabric cycles.
    With ~6–10× clock headroom over 16 MIPS, a **non-overlapped** multi-cycle FSM (only
    one instruction in the machine at a time) still retires at real-time and has **zero
    pipeline hazards** — no forwarding, no interlocks, no need to model the real 56k's own
    pipeline restrictions. Stage purely for design simplicity + timing comfort, not speed.
- **SDMA + connection matrix (crossbar) — required for audio compat.** Real Falcon DSP
  audio almost never touches bulk memory directly: the **sound DMA streams blocks between
  RAM and the DSP's SSI through the crossbar** (`$FFFF89xx` DMA-sound + matrix block), and
  software runs an SSI-interrupt processing loop. So to run real binaries you need the
  SDMA + crossbar **register models**, not just the HI. Well-aligned, reuse-heavy:
  - The SDMA-equivalent is another HP-port AXI streamer — a sibling of the COVOX
    `pokey_sample_dma` item — pushing/pulling a FIFO into the DSP SSI.
  - The crossbar is a thin register-compatible mux over the audio-routing fabric already
    being built (PCM1808 capture + codec + HDMI audio).
  - **Coherency:** the SDMA reads/writes the DDR region holding *emulated Falcon RAM*,
    which the A9-JIT-68k also touches → the usual PL↔PS shared-buffer coherency
    (non-cached region / flush / ACP). Don't let it sneak up.
  - **Pacing:** the SDMA→SSI→DSP→SSI→SDMA loop and the DSP's SSI interrupts run at the
    **audio sample/frame rate**, not free-running.
- **Two interfaces, opposite coupling.** To the 68k the DSP is **loosely** coupled (HI
  mailbox, no lockstep, "upload and run"); to the audio subsystem it's **tightly** coupled
  (SSI/SDMA/crossbar paced by the audio clock). So "runs independently" holds for *compute*
  DSP use but not *streaming audio*, where it's a sample-paced interrupt loop. Clean
  partition: **HI in the control/clock domain** (to the JIT-68k); **SSI + SDMA + crossbar
  as an audio-clock-domain subsystem** next to the codec/PCM1808 fabric.
- **Faithful-vs-turbo clock mode**, like the 6502: pace the tick to ~16 MIPS for
  cycle-exact Falcon audio, or run faster for code that doesn't care. Lives next to the
  audio fabric (SSI → PCM1808/codec clock domain).
- **Resource / timing: not the constraint.** 24×24→56 MAC = 2–4 DSP48E1 of 220; X/Y/P
  on-chip RAM + tables = a few BRAMs; decode/AGU/control = a few k LUTs. Fits the 7020
  with room; ~zero fMax pressure (16 MIPS target). **Effort, not silicon, is the cost.**
- **The genuine effort center (unchanged by any of the above): comprehension +
  validation.** Transcribing every parallel-move format / addressing mode and the
  bit-exact data ALU (56-bit extension, scaling, convergent rounding, saturation), plus
  the HI + SSI peripheral models, bootstrap ROM, on-chip X/Y/P map, µ-law tables — then
  proving it bit-exact. Staging makes the *gates* easy; it does **not** shrink the
  spec-transcription work, where the months actually are.
- **References, not blank-page:** **Suska** (experiment-s.de — open-source VHDL Falcon+,
  crib the decode + bit-exact ALU) and **Hatari**'s `dsp.c` (mature, accurate Falcon DSP
  emulator → golden co-sim model). Net risk profile: a *medium-complexity microcoded
  coprocessor faithfully copying a well-documented spec*, not taming exotic silicon.
- **Sequencing:** gated on the m68k JIT + Falcon target maturing; not near-term. *(design
  option; no source doc yet — capture in a docs/Design/ note if it advances.)*

## Compiler (xcc) — link-time vtable shrinking

- **Shrink vtables at link time, when the used-method set is finally known.**
  Virtuality in xcc is inferred *whole-program*: a method earns a vtable slot only
  when some subclass in the same compilation overrides it, and everything else keeps
  a direct call. That inference is unsound the moment the program isn't whole, so
  `--emit-lib` now has to give **every** instance method of every exported class a
  slot — the overrides live in a client that doesn't exist yet, and devirtualising on
  their absence would make an app's override unreachable forever. Correct, but it
  gives up the optimisation wholesale for library code, and it inflates every vtable
  with slots nobody ever dispatches through.

  The link step is where the program becomes whole again. At that point the used-method
  set *is* known: a slot no client dispatches through can be dropped, and the surviving
  slots renumbered densely. That recovers most of what `--emit-lib` currently concedes,
  without reintroducing the unsoundness — the closed-world assumption is finally true at
  link time, which is exactly when it wasn't at compile time.

- **This is load-bearing on xt6502, not just a size win.** The 6502 backend packs
  `slot * 3` into a byte, so it hard-errors above **slot 84**
  (`XT6502Backend.m:2655`). Forcing every exported method into a slot means a large
  library can now hit that ceiling where it previously didn't. It fails loudly at
  compile time rather than silently miscompiling, and `--emit-lib` is really an
  arm9/x86_64 story today — but link-time shrinking is what makes `--emit-lib` viable
  on the 6502 at all.

- **The opt-in escape hatch, if this doesn't land:** a `final` keyword restoring
  devirtualisation per-method where the author can prove no client overrides. Note the
  polarity — `final` (opt *into* the optimisation) rather than a `virtual:`/`public:`
  marker (opt *into* correctness), because a marker you must remember for correctness
  is silently wrong the day you forget it. *(src: fpga-xtc
  `docs/Design/bound-methods.md`; `XTSemanticAnalyzer.libraryBuild`.)*


---

# Sometime / Maybe
## Open Issues (tracked bugs)
- none

## Post-architecture-review
- **§3.2 SALLY memory hierarchy → 120 MHz**, 

## HW / RTL bring-up
- none

## Video / compositor / sprites / textures
- **plane_fetch vs blitter DDR arbitration (RTL — the residual overrun
  trickle)** — the desktop fetcher (HP0) loses to blitter bursts (HP1) on their
  shared DDRC port: single-frame line-segment corruption, ZERO overruns with the
  engine off (board A/B 2026-07-17). PS QoS is a dead end (QOS pins tied 0 in
  fabric, "inert without HPR arb config"). Remaining fabric options: deeper/
  earlier plane_fetch line FIFO (needs compositor row+2 lookahead), or arb
  priority for the fetcher. gemd-side mitigations shipped (128-row banded engine
  blits + CPU composite during live drags) make it visually clean; hdmi-mon
  coalesces the residual events to 1 line/5 s. **Same-row-skip attempt REVERTED
  (89c4291 + f3d830f reverted by 0ebc6cd/f1d23fd)** — on hardware it
  black-screened the XL window at scale 2 while the machine ran fine
  (XEX booted, HP3 fetches active, displayed half never updated); the four
  unit tbs (plane_fetch/vscale/compositor/cmp_fetch) all passed, so the
  failure lives in a fabric condition they don't model — likely the real
  vbeam's line_start/line_start_e shape vs the tb's. Before re-landing:
  build a tb that reuses the actual u_vbeam line_start generation, and
  reproduce the black window in sim FIRST. Simon confirms the overruns
  cause no visible glitches (absorbed by buffering), so this is bandwidth
  hygiene, not a fix — low priority. *(src: gemd-plan.md §M7, hdmi.c hdmi-mon)*
- **Compositor polish (deferred)** — visible-span-only plane fetch (bandwidth);
  tear-free `front_sel` sampling at the compositor's own frame start; narrow/wide
  playfield `src_w` tracking. *(desktop-window-over-live-window occlusion is DONE —
  the Route-A alpha hole, no clip-rect list; docs/OS/m6-routeA-handoff.md.)*
  *(src: docs/video/video-architecture.md, former docs/TODO.txt)*
  
- **PL-only test-pattern mux in `plane_compositor`** — build-param gradient/colour-bar
  bypass of plane_fetch reads (old `SCANOUT_TEST_PATTERN` lived only in orphaned
  `fb_scanout.sv`). *(src: docs/bring-up.md)*
  
- **Sprite engine — deferred/optional refinements.** Core, HW mouse cursor, H/V flip + 2× scale, Remaining (none currently blocking): palettised sprites, rotation (SW-first),
  blitter→sprite-arena integration. *(src: hdl/sprite_engine.sv, docs/Design/sprite-engine.md)*

- **Texture mapping (tiers)** — T1 affine point-sampled (~1 day) → T2 bilinear
  (+½ day) → T3 textured triangles (+½–1 day) → T4 perspective-correct (several days);
  plus `$D4D0..` TEX_* regs / `CMD=0x08` / `TEX_WRAP` wiring and a texture-cache
  throughput upgrade (2×2 quad reads / BRAM tile cache). *(src: docs/video/texture-mapping.md)*

## Audio (PCM1808 capture + HDMI audio)

- **COVOX-style DMA sample playback** — `pokey_sample_dma` streaming DDR buffers to
  the mixer (8-bit mono + 16-bit stereo, EOS IRQ). *(deferred to M22+; src:
  docs/Design/aux-audio-and-reservations.md)*
- **RS-232 via second POKEY** — rear-panel RS-232 off the unused 2nd-POKEY serial
  port: MAX232/SP3232 footprint + 2 peri pads (PCB), `peri_bridge.sv` 2nd serial
  channel + companion software-UART firmware. *(M-serial; src: docs/Design/aux-audio-and-reservations.md)*

## Memory / banking (DDR3 banked window — parallel track, not on boot path)

- **Banked page cache (`"PAGE"`) — fmax pass.** `banked_page_cache` (resident pages +
  write-back) is the better backend once banking is heavy, but it adds ~0.5 ns to
  SALLY's 1-cycle mem loop (clk_sally −0.495, ~54% routing) — needs a floorplan
  (`pb_sally` + `screen_bank` CPU-BRAM co-location) and/or read-path depth reduction
  before it can replace LINE. Also: its **write-back/reload path is incomplete** — a
  code/data-bank write does not persist across a swap (code-bank write is a no-op; data
  write-back fails too). Exposed by `tb_sally_mem` A.4c — run `make sally_mem_page` (the
  PAGE variant skips A.4c via `-D PAGE_BACKEND`; remove that gate once fixed).
  *(src: docs/Design/banked-page-cache.md, sim/tb_sally_mem.sv)*

## SIO / PBI / cartridge / companion MCU
- none

## GEM (VDI + AES) / desktop
- none

## Multitasking / self-hosting / compiler
- none




---

## XTOS / OS / boot / fonts / Lua

- **XTOS phases** — P1 GEM-as-C-lib draws via the blitter under FreeRTOS; P2 four-
  surface compositor WM + input/event bus with focus routing; P3 VFS + launcher +
  per-app profiles (SD VFS, image drives, SQLite-on-NAND, trashcan, shell); P4 dynamic
  ELF loader + interface/registry + `ABIVER`; P5 IDE + on-device xcc; P6 cross-core
  source-level debugger. *(src: docs/OS/xtos-vision.md)*
- **Dynamic-loading / syscall ABI / bootstrap (Phase 4 spec)** — uClinux model
  (spawn not fork); 3-tier ABI (`SVC #1` kernel syscalls + registry/ops-table services
  + ELF-dynsym libraries); `ET_DYN` minimal-reloc loader; `init`/pid-1 bootstrap +
  process table; **frozen syscall numbering + `r7`/`svc #1` convention**; MMU-readiness
  rules. Vision P4 now references the `SVC #1` syscall tier. *(src:
  docs/OS/dynamic-loading.md)*
- **Process limit — dynamic per-space allocation (raise the 64/255 ceiling).** MAXPROC is
  64 (was 8). All per-process resources are **static `[NSPACE]` arrays** — the 16 KB L1
  page table, the L2 tables, `proc_t`, and the multi-section stack arena — so the kernel
  reserves the full 64-process footprint (~10 MB BSS) always, even idle, and 64 is near
  the ceiling of the 31 MB kernel RAM region. Two hard limits block going higher as-is:
  (1) **ARM 8-bit ASID** — `asid = idx+1` written to CONTEXTIDR[7:0], so 255 is the max
  and 256 aliases the reserved kernel ASID 0 (would corrupt); (2) the **static-array RAM
  tax**. To reach hundreds: allocate the per-space tables + stacks from the DDR pool **on
  spawn** (freed on reap) so RAM tracks *live* processes, not the max; **cap at 255** (or
  add ASID recycling for non-running spaces); and **split stack sizes** (small default,
  opt-in large only for FreeType/GUI procs — 64 KB × N is the arena's main cost). The
  MAXPROC=64 bump already flushed the stale hardcoded-8 caps (procfs `PF_MAXPROC`, shim
  `MAX_KIDS`, and fs_ctl-as-shm vs. `NSHM`); a dynamic rework is the real fix.
- **Process model — opt-in swap + tier-3 fork (deferred).** Tier 2 is done & HW-validated
  (per-process MMU spaces, shared libs, mmap-exec/files, COW, demand heap, guard pages,
  W^X, DDR pool+reclaim+scrub, loader teardown, PL0 user/kernel split + per-process
  stacks; site /os/runtime/) — the A9 MMU is load-bearing, giving the JIT-hosted m68k's
  FreeMiNT protection layer its backend. Still open: **opt-in swap** (safe via the
  PL-visible⇒wired invariant, so the Atari surfaces never page out — designed, not built)
  and **tier-3 fork** (deferred; possible later as a single-threaded compat shim).
  *(src: docs/OS/memory-protection.md, docs/OS/mmap-exec-cow.md)*
- **Loadable filesystems + device drivers (as isolated PL0 services)** — DESIGNED,
  not a current priority; resume when wanted. Goal: drop a binary into
  `/OS/Filesystems/` or `/OS/Devices/` (plain basename = the type, no extension, e.g.
  `/OS/Filesystems/fat`) and have it extend the OS — MiNT XFS/XDD was the inspiration,
  not the model. **Decided model: services, not in-kernel modules.** A filesystem/
  driver is an ordinary PL0 program — gets the full `libc.so`/`libm` by DT_NEEDED,
  `printf` debugging, blocking, FP, and crash isolation (a bad driver faults its own
  task and is killed; the OS survives) — vs. an in-kernel module which would resolve
  only against `frtos_ksym`, run privileged, and crash the kernel. Cheap despite
  linking libc: libc text is one shared physical copy (mmap-exec), only its data is
  per-process COW. **ABI:** `svc_register(kind, name)` announces a *type*; a separate
  `mount(type, source, mountpoint)` creates each mount instance (so one `fat` service
  serves many partitions — `mount fat /dev/sd0p1 /mnt/c` + `…p2 /mnt/d`); the kernel
  installs a VFS mount whose `fs_ops` are IPC stubs carrying `{service, instance}`, and
  a per-open `vfile` carries the service-assigned file handle. **Discovery:** boot-scan
  `/OS/Filesystems/` + `/OS/Devices/` (romfs prefix-iterate), spawn each as a service,
  each registers by basename. **Device drivers** = userspace-driver model: kernel
  offers "map this device's MMIO into me" + "deliver IRQ N to me as an event," driver
  does protocol/logic at PL0 — *but* DMA stays a trusted edge (no IOMMU/SMMU on the
  Zynq-7020, so a DMA-capable driver can scribble anywhere regardless of PL0).
  **Networking** = a device-driver service; in-fabric (PL) HDL blocks are device-driver
  clients too. **Perf:** FUSE-class (one IPC round-trip + one copy per op); fine for
  filesystems. Keep **romfs as the in-kernel root** (zero-copy `exec`/`mmap` live
  there — a service-backed FS can't be mapped as cheaply without fault-forwarding);
  services are for *mounted* filesystems; the fs task's kernel page cache hides per-op
  cost. Caution: a FS service must use the **block-device interface** for storage, not
  libc file I/O, or it recurses back through the VFS. **Staging:** (1) VFS dispatch layer
  (mount table + per-driver ops, romfs root, location-agnostic) — **LANDED** (romfs +
  fatfs + ramfs; `read`/`write`/`mmap` unified over the page cache). (2) **blockable
  syscalls + in-kernel fs service — LANDED** (this was the crux): the syscall path defers
  a blocking op off the `svc #1` handler — saves the client's resume frame and runs the
  body in System mode as a task, so it can block and context-switch the client out/back
  (`deferral_thunk`); the fs task owns FatFs behind a per-client **shm control channel**,
  the reusable IPC substrate. Remaining OPEN: (3) package fs drivers as **PL0 services**
  over that substrate — `svc_register`/`mount` ABI, spawn a driver per `/OS/Filesystems/`
  binary, a real on-disk FS beyond the in-kernel fatfs, and the MMIO/IRQ conduit for
  device drivers; (4) devfs/ioctl/concurrency polish.
  *(src: docs/OS/xtos-vision.md P3 VFS; docs/OS/fs-pagecache.md; this entry)*
- **Library build variants (speed vs debug) + loader search path** — DESIGNED, deferred
  (companion to the source-level debugger). Build each shared lib (libc/libm/libGEM, and
  programs) in **two variants**: *speed* (`-O2`/`-Os`, the default, stripped) and *debug*
  (`-Og -g`, unstripped) — a build switch, e.g. `VARIANT=debug`. Note today's libs are a
  single `-O2 -g` build (symbols draped over optimized code: jumpy stepping, locals
  `<optimized out>`) and programs are `-Os` with NO `-g` — neither is a true debug build.
  **Distribution:** the *embedded boot romfs* (baked into the kernel ELF) stays
  speed-only to keep the image lean; the **SD card ships BOTH** — speed at `/OS/Library/`,
  debug at a parallel dir (e.g. `/OS/Library/Debug/` or `/Library/Debug/`). A debug `-O0`
  libc is ~3 MB — trivial on SD, so no need to choose at deploy time. **Resolution:**
  `xtld`'s `open_lib` consults a **loader search path** (an `LD_LIBRARY_PATH`-style env,
  per-process): default → the speed dir; the debugger spawns the debuggee with the path
  pointing at the Debug dir, so only the thing being debugged pulls the big `-Og` libs (+
  step into a debug-built program directly). **Reserve-now piece:** make `xtld` library
  resolution path-driven *now* — don't hardcode `/OS/Library/` (currently `frtos_open_lib`
  does) — even before the debug variants/env exist; retrofitting the fixed path later is
  the painful kind. The debug variants + env plumbing land with the debugger; the
  search-path hook is the cheap bake-in. *(src: this entry; ties to the P6 debugger +
  Reserve-now)*
- **Reserve-now (cheap to bake in early, expensive to retrofit)** — xcc PIC/relocatable
  ARM codegen; service-call indirection via interface tables (never globals);
  interface/registry + `ABIVER` from day one; directory-mapped drives as a first-class
  VFS mode; xcc restricted-DWARF debug-info emission for all 3 backends; **`xtld`
  library resolution via a search path (not a hardcoded dir)** — enables the speed/debug
  library swap above. *(src: docs/OS/xtos-vision.md)*
- **Open XTOS decisions** — none outstanding (DWARF subset now written:
  docs/OS/dwarf-subset.md). *(DECIDED: memory protection = tier 2; debug = full
  backtrace+unwind, all 3 backends, debug-build frames; libc = newlib; front GEM
  plane = NOT building (close the emulator to run a GEM app full-desktop); boot =
  SD-only (NAND holds the registry); **system language = xcc** (C deps
  cross-compiled on host, on-device C deferred — no tcc). See memory-protection.md
  / xtos-vision.md.)* *(src: docs/OS/xtos-vision.md)*
- **Fonts** — confirm `xilffs` LFN config (`FF_USE_LFN`/`FF_MAX_LFN=255`); `opsz` axis
  tracks render pixel size; decide catalog/index on-disk format (`OS/Fonts/.index`);
  wire the `(file,coords)→FT_Face` registry into the `font_face`/`font` model; Font
  Chooser UI; prefer real variable-font masters over synthetic bold/italic. *(src:
  docs/OS/fonts.md, docs/OS/creation.md)*
- **PDF/printer VDI device (ids 21-30)** — `v_opnwk` printer path + `v_opnprn`/
  `v_etext`/etc.; parked, contourfill dropped, no Flate/selectable-text yet. *(src:
  docs/OS/creation.md)*

---


## Fidelity / Altirra audit (mostly deferred — need cycle-accurate bus model)

- **WSYNC release at cycle 105** — /RDY releases at `line_start` (~9 cyc late vs real
  ANTIC). *(genuine bug; blocked on cycle-accurate bus / SALLY-on-FPGA observability)*
- **Display-list 1K boundary wrap** — `dl_pos` should split 6-bit + 10-bit halves.
  *(blocked on SALLY-on-FPGA)*
- **End-of-frame VCOUNT anomaly** — one-cycle `$83`/`$9C` VCOUNT transient on the last
  line. *(cosmetic; deferred; src: docs/Altirra/altirra-antic-audit.md)*

## Deferred (with reasons)

- **fmax / 120 MHz (deferred, deep).** Both binding paths are logic-depth-bound —
  floorplan won't help (co-location tried, neutral):
  - clk_sys: ANTIC GTIA/compositor colour-priority cone (`cur_mode → col_presH`,
    14 levels) → needs a pipeline stage in the real-time pixel path.
  - clk_sally: CPU/page-cache loop (11 levels) → read-pipeline already reverted;
    residual levers = page_cache RLOC + LUTRAM ZP/stack tiers. Gates 120 turbo.
  *(architecture-review §1.5; [[xt6502_clean_sheet]])*
  
- **SCALED blit burst-write rewrite (deferred — path unused by gfx).** Wide scaled
  rows cap at one 32 px burst + beat-half mis-align (SC_ACCUM burst/Bresenham write
  path); fix when scaled is actually used. *([[blitter_addrgen_consolidation]])*

- **`^` equality across two modules that each widen the same function (limitation, not a
  bug).** A widened `^` carries `{recv = fnptr, code = __bm_tramp_<sig>}`. `recv` is
  canonical — the function's address resolves through normal dynamic linking — but `code`
  is the *widening module's* trampoline, and the loader binds a defined symbol to the
  module that defines it (no interposition, `xtld.c:333`), so two modules each get their
  own. Two `^`s widened in the **same** module always compare equal, which is the pattern
  that matters: an app registers *and* unregisters its own callbacks, so
  `removeAction(&f)` finds what `addAction(&f)` stored even though the *library* holding
  them has a different trampoline. Only the exotic case — the **same function widened in
  two different modules**, then compared — differs, and it is no longer a safety issue
  (the weak-register guard is value-based since phase-611). Closing it would need a
  canonical trampoline address, which this loader cannot give. Recorded rather than
  papered over. *(fpga-xtc `docs/Design/bound-methods-across-modules.md`)*
