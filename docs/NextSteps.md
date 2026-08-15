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
  **RETRACTION #20: IT IS NOT THE MISSILES — IT IS THE FOUR PLAYERS
  (2026-08-15).**
  Altirra peeked at the exact moment its object is on screen (frame ~1150,
  t~23 s):
        **grafm = $00**, **sizem = $00**, **$0300-$03FF: 1 of 256 non-zero (0.4%)**
        hposm = $76 $74 $72 $70
        **hposp = $84 $7c $74 $6c**,  prior = $54,  gractl = $03
  **GRAFM IS $00 AND THE MISSILE REGION IS EMPTY, so the object is NOT the
  missiles / fifth player.** (And our own missile region being 2-5% non-zero is
  therefore not a deficit -- Altirra's is 0.4%.)
  **IT IS THE FOUR PLAYERS.** `x_left = (HPOS - 48) * 2` maps $6c/$74/$7c/$84 to
  **x = 120 / 136 / 152 / 168**, spanning x=120..184 -- which is exactly the
  measured object at **x=130..179**. Four adjacent players forming one figure.
  **AND WE WRITE THOSE SAME POSITIONS:** our HPOSP2/HPOSP3 took **$74 and $6C**
  and HPOSP0 took **$84** -- the very values Altirra uses when the man appears.
  So **our players are correctly positioned, carry shape data, and still do not
  appear.**
  **=> THE TARGET IS PLAYER RENDERING AT HPOSP $6c..$84 WITH PRIOR $54 IN GTIA
  MODE 9 — not missiles, not the fifth player, not the P/M DMA missile slot.**
  **NEXT: build exactly that case in `sim/tb_gtia_stage.sv`** -- four players at
  HPOSP $6c/$74/$7c/$84, SIZEP as measured, GRAFP non-zero (as DMA would supply),
  PRIOR $54, GTIA mode 9 active, COLPM = $36 -- and assert the players WIN and
  emit $36. If sim draws them, the fault is upstream of gtia_stage (the P/M DMA
  player fetch or the register file); if sim does NOT, the bug is in the walk or
  priority and is now reproducible offline.
  ############################################################################

  ############################################################################
  **THE LIVE MISSILE DMA PATH, IDENTIFIED AND READ (2026-08-15).**
  **`antic_pm_fetch.sv` is SIM-ONLY** -- instantiated only in `antic_scanline.sv`.
  **The LIVE path is `antic_pm_dma.sv`**, instantiated in `antic2.sv:843`, whose
  output feeds `gtia_reg_file` in `a2_video` as pm_we/pm_obj/pm_data/pm_fetch
  (obj 0 = missiles, 1..4 = players).
  Read of `antic_pm_dma.sv`, and it looks CORRECT:
        `missile_en = dmactl[2] || dmactl[3]`   -- DMACTL $3E sets BOTH
        `slot_m = (hcount == 7'd0) && missile_en`
        `m_addr = base + (one_line ? 16'h0300 : 16'h0180) + idx`
        PMBASE $00 + one-line -> **$0300 + idx**, which is right
  **So the missile fetch path is correct BY CODE READING, and GRAFM should be
  loaded from DMA.** (The game writes GRAFM ZERO times directly, so DMA is its
  only source.)
  **=> THE NEXT STEP MUST BE EMPIRICAL, NOT MORE CODE READING.** Verify on
  hardware/sim that (a) the missile byte is actually fetched each scanline,
  (b) GRAFM is non-zero in the window, and (c) `pres[7:4]` goes non-zero so
  `gtia_priority`'s `any_missile` can let the fifth player win.
  **NOTE the shape data is THINNER than expected:** our missile region ($0300)
  measured only **2-5% non-zero**, where a 28-row-tall object would want ~11% of
  256 bytes. Worth checking whether the uploader fills the missile region as
  fully as Altirra's does -- compare $0300-$03FF non-zero counts on both at
  t~22-24 s, the window where Altirra's 50x28 object is on screen.
  ############################################################################

  ############################################################################
  **THE MISSING OBJECT IS THE FIFTH PLAYER (MISSILES), AND IT IS AT THE POSITION
  WE ALREADY WRITE (2026-08-15).**
  Altirra's object, located on screen (altd28/altd29, artifacting OFF, 336x224):
        **542 px, x=130..179 (50 wide), y=141..168 (28 tall), ALL colour $36**
  **RETRACTION #19 (a heuristic, not a conclusion): "hues 3 and 5 = players" was
  IMPRECISE.** $36 is NOT a COLPM value (those are $52/$32/$54/$34) -- it is one
  of **COLPF3**'s written values. **But in GTIA mode 9 the playfield is recoloured
  to COLBK's hue, so a COLPF3-coloured region MUST be an object**, and **PRIOR
  $54 has BIT 4 SET = FIFTH PLAYER, under which the MISSILES take COLPF3.**
  **=> ALTIRRA IS DRAWING THE FIFTH PLAYER (MISSILES) AS A 50x28 OBJECT
  MID-SCREEN. WE DRAW NOTHING OF THAT COLOUR ANYWHERE.**
  **AND THE POSITION MATCHES WHAT WE ALREADY WRITE:** our **HPOSM values are
  $70..$82**, and `x_left = (HPOS - 48) * 2` puts them at **x ~= 128..164** --
  squarely inside Altirra's x=130..179 object. Our missiles also receive shape
  bytes (missile region $0300: 5% and 2% non-zero in two captures).
  **=> THE BUG IS NARROWED TO OUR FIFTH-PLAYER / MISSILE RENDERING.** The inputs
  are right (HPOSM positioned mid-screen, shape data present, PRIOR bit 4 set)
  and the object does not appear.
  **WHERE TO LOOK (all live, all synthesized):**
   * `gtia_priority.sv`: `pm5 = prior[4]`; the fifth-player step uses `s = 4'd7`
     (PF3) with **`s_present = pm5 && any_missile`** and `any_missile = |pres[7:4]`
   * `gtia_obj_walk.sv`: missiles are objects 4..7, two bits each from GRAFM,
     sized by SIZEM -- check they are being STRUCK and EMITTED at HPOSM $70..$82
   * the P/M DMA fetch for the MISSILE region ($0300 with PMBASE $00), which is a
     different address than the players' $0400-$0700
  **FIRST CHECK: does `pres[7:4]` ever go non-zero on our board in that window?**
  If the missiles are never present in the walk, priority never sees them and the
  fifth player can never win.
  ############################################################################

  ############################################################################
  **THE RENDER PATH IS *NOT* EXONERATED — ALTIRRA DRAWS PLAYERS UNDER THE EXACT
  CONFIGURATION WHERE WE DRAW NONE (2026-08-15).**
  With the screen as ground truth (both machines reach gameplay ~22-28 s, so the
  man's scene is inside the 0-24 s window on both):
        **OURS:    0 of 9 mode-9 frames contain ANY player pixel**
        **ALTIRRA: 5 of 30 mode-9 frames DO**, fraction growing monotonically
                   0.05% -> 0.16% -> 0.30% -> 0.72% (an object appearing)
  **AND THE CONFIGURATION MATCHES.** `altdense` captured at frame 450+25(k+1), so
  the player-bearing frames altd25-29 are frames 1100-1200 = **t~22-24 s**. And
  Altirra's PRIOR went to **$54 at frame 680 (t=13.6 s)**. **So Altirra is drawing
  players at t=22-24 s WHILE RUNNING PRIOR $54 IN MODE 9 — exactly the
  configuration under which we draw none.**
  **=> "PRIOR $54 (playfield above players) hides the man" is REFUTED: it does not
  hide them on Altirra.** And **the earlier "render path exonerated" was based on
  the GAME WRITING correct P/M data (registers, shapes, positions), NOT on the
  SCREEN showing it.** Both can be true at once, and together they isolate the
  fault: **the 6502 writes the object correctly and OUR CHIPSET does not put it on
  screen.**
  **THIS IS THE ORIGINAL QUESTION, ANSWERED THE WAY SIMON FRAMED IT:** *"if the
  game writes an object we never draw, the bug is ours in the LIVE render path."*
  **The game writes it. We never draw it. The bug is ours in the live render
  path.**
  **NEXT, AND IT IS NOW WELL-POSED:** take OUR mode-9 frames and ALTIRRA's
  player-bearing mode-9 frames at t~22-24 s, and compare the P/M state at the
  SAME instant -- HPOSP/SIZEP/GRAFP-via-DMA, PRIOR, and the shape bytes at
  $0400-$07FF -- then walk the live chipset (`gtia_obj_walk` -> `gtia_priority`
  -> `color_resolver`) for that exact case. **Do NOT re-run the P/M register
  comparison at aggregate level; it already matched. The question is why matching
  inputs produce a player on one machine and not the other.**
  ############################################################################

  ############################################################################
  **RETRACTION #17 AND #18: OUR INTRO IS NOT SHORTER, AND IT IS NOT VARIABLE
  (2026-08-15). THE "SHORTER INTRO" CONCLUSION COLLAPSES.**
  Five FRESH launches, screen grabs at t = 24/28/32/36/40 s, hue-mapped:
        run 1..5 (ALL IDENTICAL): **t=24 s INTRO (hue1 100%), t=28 s GAME**,
        and game at 32/36/40 s.
  **=> RETRACTION #17: "our intro duration VARIES between runs" is WRONG.** It is
  highly repeatable (5/5). The apparent variation came from inferring phase from
  CODE PAGES in traces rather than from the SCREEN.
  **=> RETRACTION #18: "our intro is much SHORTER than Altirra's" is WRONG.**
  Altirra's own screen transition, from the `alt_seq` set (frames at boot+500/
  650/800/950/1100/1250 ~= t=10/13/16/19/22/25 s): **a-d are mode 9, e-f are
  gameplay -- Altirra reaches the game screen at t~22 s, slightly EARLIER than
  our 24-28 s.** Both machines reach gameplay at a similar time.
  **AND THE LABELLING ERROR BEHIND IT:** I called Altirra's $37xx/$3Bxx activity
  at t=45-60 s "intro code". **It is not** -- `$353A` (the P/M uploader) lives in
  $37xx and runs during GAMEPLAY too. So "Altirra is still playing the intro at
  t=60 s" was an inference from code pages, not a screen observation.
  **WHAT SURVIVES, AND IT IS NARROWER:** at t=30/45/60 s the two machines run
  DIFFERENT CODE REGIONS -- ours $4Cxx/$5Axx/$5Dxx/$81xx (which **Altirra never
  executes at all**: zero in 23.9M records) and Altirra's $37xx/$3Bxx/$3Axx with
  its sound tick at exactly 1/frame. **Both are in "the game" by ~t=25 s; they
  simply run different code there.** Whether that difference matters to the
  missing man is NO LONGER ESTABLISHED.
  **LESSON: DO NOT INFER A PHASE FROM CODE PAGES WHEN THE SCREEN CAN BE
  MEASURED DIRECTLY.** The screen is the ground truth for "which scene is
  playing"; code-page profiles conflate scenes that share subroutines.
  ############################################################################

  ############################################################################
  **REFINEMENT: OUR INTRO DURATION VARIES BETWEEN RUNS (2026-08-15).**
  Three separate launches, each a fresh `xlboot`:
        stages.bin run: intro at t=15 s, **gameplay ($4Cxx) by t=30 s**
        tr27 run:       **still intro at t=27 s** ($37xx dominant, NO $4Cxx)
        tr31 run:       **still intro at t=31 s** ($30xx dominant -- the scene
                        dispatcher, 693,400 records -- NO $4Cxx)
  **Three runs, three different progressions**, and tr31 is deep in the $30xx
  dispatcher at t=31 s, i.e. FURTHER ALONG in the intro than the run that had
  already left it by t=30 s.
  **=> "our intro is ALWAYS shorter" is TOO STRONG.** What holds: **our intro ends
  somewhere in the 26-31+ s range while Altirra's is still running past 73 s** --
  a large difference, but a VARIABLE one.
  **This is consistent with the POKEY-RANDOM seeding** ($3000-$303E reads $D20A
  four times plus `bit RANDOM / bpl`) and with Simon's own report that the
  goalposts appeared on one build and not another.
  **CONSEQUENCE FOR METHOD: our side must be characterised as a DISTRIBUTION over
  several runs, never from a single capture.** Altirra is deterministic across
  cold resets (5 runs byte-identical) and can serve as a fixed ruler; we cannot.
  **NEXT: repeat the staged snapshot over >=5 fresh launches and record, for each,
  the wall-clock time at which $4Cxx first appears.** That gives our intro-length
  DISTRIBUTION against Altirra's fixed >73 s. Only then is "how much shorter" a
  real number.
  ############################################################################

  ############################################################################
  **RETRACTION #16: THE $B3 "SPIN" IS THE NORMAL WAIT-FOR-VBLANK IDIOM
  (2026-08-15). WE ARE NOT STUCK — WE ARE IN GAMEPLAY.**
  Writers of $B3 in our t=45 s snapshot (opcode scan + operand resolve):
        $4C88 **STA** $B3  **225** times   (the loop clearing it)
        $5BDA **DEC** $B3  **112** times
        $5D81 **DEC** $B3  **113** times
  **The decrements (112+113 = 225) EXACTLY BALANCE the clears (225).** So $B3 is
  decremented to $FF (negative), the `bpl` falls through, the frame's work runs,
  $B3 is cleared, and it repeats -- **225 COMPLETED iterations in a 3.5 s
  snapshot ~= 64/s ~= FRAME RATE.** That is the standard wait-for-vblank main
  loop, and the huge $4C72/$4C74/$4C8A counts are just a game spending most of
  each frame waiting for the next one.
  **=> "our main thread is parked" is WITHDRAWN. Our board is running NORMAL
  GAMEPLAY from t~26 s.**
  **WHAT SURVIVES, AND IT IS THE SAME CONCLUSION AS BEFORE THE DETOUR:**
   1. **Ours leaves intro code by t=30 s; Altirra is STILL IN THE INTRO at
      t=60 s** (sound tick exactly 1/frame at every matched point; P/M uploader
      active at t=45 s and 60 s). Measured at MATCHED wall-clock points.
   2. **Altirra never executes $4Cxx/$5Axx/$5Dxx/$81xx at all** -- zero in 23.9M
      records across five captures spanning t=13..73 s.
   3. Our $4Cxx region is a normal frame-synced main loop.
  **=> OUR INTRO IS MUCH SHORTER THAN ALTIRRA'S AND WE PROCEED TO THE GAME. The
  man's scene is in the part of the intro we skip.** That is the divergence to
  chase, and it is where the evidence pointed before the $B3 detour.
  **LESSON (worth more than the detour cost): BEFORE CALLING A LOOP A HANG,
  COUNT ITS COMPLETIONS.** A wait-for-vblank spin looks exactly like a hang in a
  PC histogram; the giveaway is that the loop's exit path executes once per
  frame. Check the balance of the flag's setters and clearers.
  ############################################################################

  ############################################################################
  **OUR MAIN THREAD SPINS ON $B3 IN CODE ALTIRRA NEVER EXECUTES (2026-08-15).**
  **ALTIRRA NEVER TOUCHES $4Cxx/$5Axx/$5Dxx/$81xx AT ALL** -- zero occurrences in
  **23.9M records** across five captures spanning t=13..73 s (alt_vlong plus the
  four matched-point snapshots). **Ours executes them heavily from t=30 s.**
  Disassembled (realigned from $4C72 -- the $4C70 alignment is mid-instruction):
        $4C72  lda $B3
        $4C74  bpl $4C8A
               ... jsr $A0B2 / jsr $9C47 / inc $B5 / lda #$00 / sta $B3
        $4C8A  jmp $4C72
        ($4C8D  lda #$AB / sta VVBLKI $0222 -- this region installs a VBI vector)
  **Our top three PCs are exactly that loop: $4C74 (132,091), $4C72 (132,076),
  $4C8A (132,047) -- near-identical counts.** So **OUR MAIN THREAD IS PARKED,
  SPINNING ON $B3 WAITING FOR IT TO GO NEGATIVE.**
  **This refines the earlier "not a hang" remark:** the 5394 distinct PCs are
  interrupt handlers and other subsystems still running -- but the MAIN THREAD is
  stuck. Both statements are true; the main thread is what matters.
  **=> THE PICTURE: at t~26 s we leave the intro into a region ALTIRRA NEVER
  ENTERS, and park there spinning on $B3. Altirra meanwhile is still playing the
  intro at t=60 s (sound tick exactly 1/frame, P/M uploader active). The man's
  scene is in the part we never reach.**
  **NEXT: (1) find every writer of $B3** (scan zp INC/DEC/STA/STX/STY opcodes and
  resolve operands, as was done for $CA -- `trace_writes.py` sees neither INC/DEC
  nor `STA (zp),Y`); **(2) find what BRANCHES us into $4Cxx at t~26 s** -- take a
  snapshot straddling the transition (`dtrace 26`/`28`; the ring keeps the last
  ~3.5 s) and predecessor-histogram the first $4Cxx execution. **$B3 is set to
  $00 inside the loop itself ($4C88), so something ELSE must make it negative --
  most likely an interrupt handler. If that handler never runs, we spin forever.**
  ############################################################################

  ############################################################################
  **THE LIKE-FOR-LIKE COMPARISON, AT LAST: ALTIRRA IS STILL IN THE INTRO AT
  t=60 s WHILE WE ARE NOT (2026-08-15).**
  Gap-free snapshots at the SAME wall-clock points on both machines -- ours via
  the `dtrace` ring (`dtrace 60` = a snapshot 60 s in), Altirra via TRACEFILE
  windows of ~175 frames:
        ALTIRRA  t=15s  $BCxx/$32xx/$3Bxx   BCEB=**175**  3043=1, 33AF=1
                 t=30s  $31xx/$32xx/$3Bxx   BCEB=**175**  3043=2
                 t=45s  $37xx/$BExx/$BFxx   BCEB=**175**  **353A=608**
                 t=60s  $37xx/$3Bxx/$3Axx   BCEB=**175**  **353A=192**
        OURS     t=15s  $37xx/$3Bxx/$3Axx   BCEB=320      3043=1, 353A=642
                 t=30s  **$4Cxx/$5Axx/$5Dxx/$81xx  NO BCEB, NO 353A, NO 3043**
                 t=45s  identical profile          none
                 t=60s  identical profile          none
  **Altirra's sound tick is EXACTLY 175 per 175 frames (1/frame) at every point,
  and its P/M uploader is still running at t=45 s and t=60 s -- it is STILL
  PLAYING THE INTRO.** Our board has left that world by t=30 s: different code,
  **sound engine entirely absent**, no uploader, no dispatcher.
  **IT IS NOT A HANG.** Our t=45 s snapshot has **5394 DISTINCT PCs** with a hot
  inner loop at $4C72/$4C74/$4C8A (~19% combined) -- a real program in a steady
  periodic state, not a crash. (The byte-stable profile across t=30/45/60,
  including $81xx = 111,644 in all three, is periodicity, not a freeze.)
  **=> THE DIVERGENCE, STATED AS DIRECTLY COMPARABLE FACT: at t=30/45/60 s
  Altirra is executing the intro and we are executing something else. The man's
  scene is in the part we never play.**
  **NEXT: identify what our $4Cxx state IS and what transitions us into it around
  t=26 s.** Candidates: the game proper starting early, an attract/demo mode, or
  a wrong branch out of the intro. Predecessor-histogram the FIRST $4Cxx
  execution in a capture that straddles the transition (a `dtrace 26`-ish
  snapshot), and check whether Altirra ever reaches $4Cxx at all.
  ############################################################################

  ############################################################################
  **STAGED SNAPSHOTS SETTLE IT: WE ARE NOT PARKED — OUR INTRO IS SIMPLY MUCH
  SHORTER THAN ALTIRRA'S (2026-08-15).**
  Four gap-free 4 s `dtrace` snapshots taken AT t = 15 / 30 / 45 / 60 s (the ring
  keeps the LAST ~4 s, so `dtrace 60` samples 60 s in):
        t=15s  $37xx/$3Bxx/$3Axx/$BExx (INTRO code), VBI=320, $BC=$00, **waits 0.0%**
        t=30s  **$4Cxx/$5Axx/$5Dxx/$81xx**, **VBI=0**,          **waits 0.0%**
        t=45s  identical page profile,      VBI=0,              waits 0.0%
        t=60s  identical page profile,      VBI=0,              waits 0.0%
  **$30C6 and $30CC are 0.0% of ALL FOUR snapshots -- WE ARE NEVER PARKED.** The
  "stuck in a wait" framing is dead; earlier $30CC counts were TRANSIENT visits
  during the intro, not parking. (And `altwait.log`'s 12 PC samples already ruled
  out parking on Altirra, so **NEITHER machine parks**.)
  **WHAT IS CONFIRMED INSTEAD:** by **t=30 s our board has LEFT THE INTRO
  ENTIRELY** -- a different code region ($4Cxx), **ZERO sound-engine ticks**, and
  a byte-stable page profile across t=30/45/60 s (396k/404k/396k for $4Cxx).
  **Altirra is still in mode 9 at t=40 s+.**
  **=> THE ORIGINAL OBSERVATION IS THE RIGHT ONE, NOW ON MATCHED INSTRUMENTS:
  OUR INTRO IS FAR SHORTER THAN ALTIRRA'S -- ours ends by ~26 s, Altirra's is
  still running at 40 s. The man's scene is in the part we never play.**
  **NEXT: find what CUTS the intro short.** Not a wait, not the render path, not
  a rate difference in the sound engine (those match within ~14%). Compare the
  SCENE SEQUENCE itself: which scenes each machine plays and in what order,
  anchored on the $3043 dispatcher and the $353A P/M uploader, using staged
  snapshots at MATCHED wall-clock points on both sides.
  ############################################################################

  ############################################################################
  **THE PER-FRAME COUNTER PROBE IS UNDER-POWERED — AND SO IS EVERY 1 Hz SAMPLER
  FOR THIS QUESTION (2026-08-15).**
  `altwait.py` sampled $C2/$CA/$BC and the PC once per frame for 1500 frames
  (t~30 s) on Altirra:
        f  872 t~17.4s  C2=00 CA=**01** BC=00  pc=$31f6   <- caught the $CA release
        f 1500 t~30.0s  C2=00 CA=00 BC=00  pc=$3b23
        **$C2 read $00 at EVERY sample; the PC was NEVER in $30C6/$30CC.**
  **THAT IS A RESOLUTION ARTEFACT, NOT A FINDING.** Altirra's 45,253 $30CC
  executions over 3000 frames is ~15 instructions per frame out of ~30,000 cycles
  = **0.05% duty**; ours at 237/frame is ~0.8%. **A once-per-frame peek will
  essentially never land inside the loop**, and $C2 is evidently incremented and
  consumed within a frame, so a frame-boundary sample only ever sees $00.
  **=> DO NOT read "Altirra never waits" or "$C2 never climbs" from this. The
  instrument cannot see it.** Probe killed rather than mined for a 16th
  retraction.
  **WHAT WOULD ACTUALLY WORK, IF THIS IS PICKED UP AGAIN:**
   * **Sub-frame residency needs a TRACE, not a sampler** -- but the trace must
     span a whole ~55 s stage, i.e. **12-20 stitched `dtrace 4` segments**
     (a 16 MB segment is only ~4 s).
   * **Or count, do not sample:** an instrument that COUNTS $30CC entries/exits
     and $C2 transitions in hardware would answer it in one run. The `6502` tool
     has no memory read and no counters today -- adding one would be the cheapest
     real fix to the methodology.
   * **Compare LIKE STAGES**, never elapsed time.
  ############################################################################

  ############################################################################
  **RETRACTION #15, AND THE REASON THIS THREAD KEEPS FLIP-FLOPPING: THE INTRO
  CONTAINS A ~1-MINUTE WAIT AND EVERY CAPTURE IS SHORTER THAN IT (2026-08-15).**
        per VBI                 OURS (longq, 1405 VBI)   ALTIRRA (3000 VBI)
        $BC == $FF (the wrap)   **0.0975**                **0.0853**
        $3E00 inc $C2           **0.0968**                **0.0850**
        $3DE0 ticker             0.2000                    0.1377
        $3E58 envelope           0.1025                    0.0523
  **Our $C2 advances FASTER, not 40% slower.** The 0.0501 figure came from the
  SHORTER hw_long2 capture. **The sound-engine rates MATCH within ~14%.**
  **=> RETRACTION #15: "our $C2 advances ~40% slower" is WITHDRAWN.**
  **THE STRUCTURAL PROBLEM, AND IT EXPLAINS #12/#13/#14/#15 TOGETHER:** at ~0.09
  increments per VBI, reaching `$C2 == $FF` needs **255 / 0.09 ~= 2800 VBIs ~= 55
  SECONDS -- ON BOTH MACHINES.** The intro contains a **~1-minute, TWO-STAGE wait**
  ($30C6 on $CA, then $30CC on $C2). **Every capture taken tonight (4-28 s) is
  SHORTER THAN ONE STAGE.** So $30C6-vs-$30CC counts invert depending on which
  stage the window happened to catch -- that is phase, not rate.
  **=> NO CONFIRMED RATE DIVERGENCE EXISTS IN THE SOUND ENGINE.** $BC-wrap,
  inc $C2, ticker and envelope rates are all comparable or slightly faster on
  ours.
  **WHAT ANY FUTURE ATTEMPT MUST DO DIFFERENTLY:**
   * **Captures must span MINUTES, not seconds** -- or abandon tracing for this
     question and use a COUNTER/WATCHPOINT instrument that survives the whole
     wait. A 16 MB `dtrace` segment is ~4 s; one stage of this wait is ~55 s.
   * **Anchor on the STAGE, not the clock:** record which of $30C6/$30CC the
     machine is in at capture start, and only compare like stages.
   * **Rates are only meaningful for TERMINATED events** -- and neither wait
     terminates inside a 4 s segment.
  **STILL UNEXPLAINED: Simon's visual symptom.** What is SOLID and shipped is the
  left-edge bar fix. The intro-timing thread has NOT produced a confirmed
  machine-to-machine divergence, and should not be presented as though it has.
  ############################################################################

  ############################################################################
  **RETRACTION #14 AND A CONVERGENCE: WE STALL IN THE $C2 WAIT, AND $C2 ADVANCES
  ~40% TOO SLOWLY (2026-08-15). THE ORIGINAL MECHANISM WAS RIGHT.**
  A LONGER continuous board capture (`longq.bin`, **10,735,584 records**, 6
  back-to-back `dtrace 4` segments) versus alt_vlong (19.2M):
        per VBI (clock $BCEB)   OURS (1405 VBI)        ALTIRRA (3000 VBI)
        $30C6 ($CA wait)         55,572 = **39.6/VBI**   556,338 = **185.4/VBI**
        $30CC ($C2 wait)        333,167 = **237.1/VBI**   45,253 = **15.1/VBI**
        $BE0A (releases $CA)          3                        4
        $BE00 (countdown $D2)       166                      281
  **RETRACTION #14: "$BE0A never runs on ours" was a WINDOW ARTEFACT** -- it runs
  3 times here. So was "$30CC executes zero times" (retraction #12 was ITSELF the
  artefact): it executes **333,167 times**.
  **THE PICTURE INVERTS CLEANLY: we pass the $CA wait ~4.7x FASTER, then STALL in
  the $C2 wait, spinning ~16x MORE than Altirra.** And `inc $C2` at $3E00 runs at
  **0.0501/VBI on ours vs 0.0850 on Altirra -- our $C2 advances ~40% SLOWER**, so
  a `cmp #$FF` wait takes far longer.
  **=> THIS IS THE ORIGINAL MECHANISM, VINDICATED:** $C2 needs 255 ticks;
  `inc $C2` fires only when $BC wraps at `$3DE1 inx / bne $3E0F`; so the $30CC
  wait stalls the intro, scenes do not advance, and the man's scene never plays.
  The chain from the very first night's analysis stands -- what was wrong was the
  *evidence* used to retract it, not the mechanism.
  **THE DECODED GATE (for the record):**
        $BDF6 lda $D0 / $BDF8 adc $D4 (FR0) / $BDFA sta $D0 / $BDFC bcc / $BDFE inc $D1
              -> 16-bit pointer $D0/$D1 += FR0
        $BE00 dec $D2 / $BE02 bne $BE31      -> countdown; on ZERO:
        $BE04 lda #$01 ... $BE0A sta $CA     -> releases the $30C6 wait
  **NEXT: why does $BC wrap to $FF less often on ours?** That is what throttles
  `inc $C2`. $BC writers: `dec $BC` at $309B/$30EA/$3E12 and `sta $BC` at $3E60
  ($0E..$00). Compare **$BC-wrap events per VBI** on both sides, and the $BD
  envelope rate that drives $3E60. **Use ONLY terminated events for rates, and
  match window lengths -- three retractions tonight came from ignoring that.**
  ############################################################################

  ############################################################################
  **THE GATE IS $BE0A: THE WRITER THAT RELEASES THE $CA WAIT NEVER RUNS ON OURS
  (2026-08-15). AND THIS INVERTS THE "WE RUN FASTER" READING.**
  Only two sites touch $CA (found by scanning zp INC/DEC/STA/STX/STY opcodes and
  resolving each operand against Altirra):
        **$BC69 STY $CA**  -> writes **$00** (arms the gate)
        **$BE0A STA $CA**  -> writes **$01** (RELEASES the `$30C6 cmp $CA` wait)
        per capture        ALTIRRA (3000 VBI)   OURS (1058 VBI)
        $BC69                    3                   1
        **$BE0A                  4                   0**   <- never executes on ours
  **Both machines enter the wait exactly once ($30C4 executes once in each
  capture). Altirra is released by $BE0A and proceeds to $30CA/$30CC/$30D0; ours
  spins at $30C6 and the capture ends.**
  **=> RETRACTION #13: "we wait ~3.2x LESS per frame" was an artefact of dividing
  a SINGLE UNTERMINATED SPIN by frame count.** The likelier reading is the
  OPPOSITE: **we are STUCK in the $CA wait, not racing past it.** The main thread
  parks at $30C6 while VBI-driven code keeps the screen advancing -- which is why
  the display still reaches gameplay at t~26 s even though the main thread is
  blocked.
  **THIS ALSO RE-OPENS "the intro runs ~3x faster"** -- that synthesis rested on
  the same per-VBI division. **The SOLID part is the SITE COUNT: $BE0A runs 4
  times on Altirra and 0 on ours.**
  **NEXT: why does $BE0A never execute?** It is in the $BExx sound-engine region.
  Predecessor-histogram $BE0A and walk back to the branch that gates it; compare
  that gate's INPUT on both machines. **Mind the window caveat: ours is 6.9M
  records vs Altirra's 19.2M — before concluding "never", take a LONGER
  continuous board capture (more back-to-back `dtrace 4` segments) and confirm
  $BE0A is still absent.**
  ############################################################################

  ############################################################################
  **THE PACING PATH, QUANTIFIED: WE WAIT ~3.2x LESS PER FRAME (2026-08-15).**
  Both machines take the path `$30C1 jsr $33F2` -> `$30C4 lda #$01` ->
  `$30C6 cmp $CA / $30C8 bne $30C6` (wait for $CA==1) -> `$30CA lda #$FF` ->
  `$30CC cmp $C2 / $30CE bne $30CC` (wait for $C2==$FF) -> $30D0.
        per VBI            ALTIRRA (19.2M, 3000 VBI)   OURS (6.9M, 1058 VBI)
        $30C6 ($CA wait)   556,338 = **185.4/VBI**      61,285 = **57.9/VBI**
        $30CC ($C2 wait)    45,253 = **15.1/VBI**            0 = **0.0/VBI**
        $30CA / $30D0      reached                      NOT reached in window
  **Per frame Altirra spends 185 iterations in the $CA wait PLUS 15 in the $C2
  wait; we spend 58 and zero. We wait ~3.2x LESS -- that IS the ~3x speed
  difference, on a normalised clock.**
  **DO NOT CLAIM "we never exit $30C6".** Our capture is 2.8x SHORTER than
  Altirra's, so the exit may simply lie beyond the window. **The per-VBI ratio is
  the sound comparison; the raw absence of $30CA/$30CC is NOT.**
  **NEXT: why does our $CA wait cost fewer iterations per frame?** $CA is the
  gate; find what increments it (predecessor/writer histogram for $00CA on both
  sides, remembering `trace_writes.py` cannot decode `STA (zp),Y`) and compare
  the INCREMENT RATE PER VBI. If $CA advances faster per frame on ours, the wait
  is satisfied sooner and everything downstream runs early -- including $33AF's
  PRIOR $54, which hides every player.
  ############################################################################

  ############################################################################
  **THE INTRO-SPEED MECHANISM, MEASURED AS A PER-VBI RATIO: WE NEVER ENTER THE
  $30CC WAIT (2026-08-15).**
  Using the per-VBI sound tick ($BCEB) as the clock -- phase-independent, and the
  fraction discipline this whole night argued for:
        per VBI            ALTIRRA (n=3000)   OURS (n=1058)
        **$30CC C2 wait      15.0843            0.0000**   <- we NEVER enter it
        $3DE0 ticker         0.1377             0.2533     <- ours ~1.8x MORE
        $3E00 inc C2         0.0850             0.0501
        $3542 P/M upload     0.8960             0.7259
        $3043 dispatcher     0.0047             0.0057
  **`$30CC cmp $C2 / bne $30CC` is the pacing wait. Altirra executes it ~15 times
  EVERY FRAME; we execute it ZERO times, ever, in a 6.9M-record continuous
  capture.** That is the ~3x speed difference: Altirra pauses there each frame
  waiting on $C2 and we skip it entirely.
  **CORRECTS AN EARLIER READING:** I previously described OUR machine as spinning
  ~12 s at $30CC (158,820 iterations). In the continuous capture we never execute
  it at all -- that earlier figure came from a different, pre-fix capture and
  must not be reused.
  **THE PATH TO $30CC:** `$30C1 jsr $33F2` -> `$30C4 lda #$01 / cmp $CA / bne
  $30C6` (wait on $CA) -> `$30CA lda #$FF` -> `$30CC cmp $C2 / bne $30CC`.
  **So we must be failing to reach $30C4/$30CA at all.** NEXT: predecessor-
  histogram $30C4 / $30CA / $30CC and $33F2's return in a CONTINUOUS board
  capture, and compare with alt_vlong -- find WHERE our control flow leaves that
  path. That is the last link between "intro too fast" and "man never drawn".
  ############################################################################

  ############################################################################
  **SYNTHESIS: THE MAN IS MISSING BECAUSE OUR INTRO RUNS ~3x FASTER
  (2026-08-15). THIS CLOSES BACK ONTO SIMON'S ORIGINAL SYMPTOM.**
  `$33AF` is the ONLY writer of $54 (`$33AD lda #$54` is an IMMEDIATE; MEMSEARCH
  finds no other absolute writer that executes). So the first appearance of $54
  IS the first execution of $33AF, measurable within each machine's own run:
        ALTIRRA  first $54 at **frame 680 = t~13.6 s** (5 cold-reset runs, IDENTICAL)
        OURS     $54 already in effect at the FIRST screen sample, **t=4 s**
        => **we reach $33AF roughly 9.6 SECONDS EARLIER**
  **And we do NOT take that branch more often** -- the `$33A0 iny / $33A1 bne`
  fall-through rates MATCH (Altirra 5.3% n=94, ours 6.5% n=31). **We take it
  SOONER, not oftener.** That is a SPEED difference, not a logic difference.
  **$54 = scheme 2 = playfield above all four players, and in mode 9 the
  playfield covers the ENTIRE window, so from the moment $33AF runs EVERY PLAYER
  IS HIDDEN.** Hence 0 of 9 of our mode-9 frames contain a player pixel, while
  Altirra's man appears late in its longer $41 window (player fraction growing
  0.05% -> 0.16% -> 0.30% -> 0.72%).
  **=> THE MAN'S SCENE IS PROBABLY STILL PLAYING ON OUR BOARD -- WITH ALL FOUR
  PLAYERS INVISIBLE. The missing man and the fast/repeating intro are ONE bug,
  and it is the INTRO SPEED.** Other supporting spans: our mode-9 phase is
  t=4..18 s and we are in GAMEPLAY by t~26 s; Altirra is still in mode 9 well
  past that.
  **THE VBI STAGE-2 RATE FITS THE SAME PICTURE, and is NOT a separate bug:** our
  $C146/$C149/$C14C shadow copy runs EVERY FRAME for the first 4 s (209 times,
  GPRIOR=$41), then only 14 times over t~5-13 s, then not at all -- i.e. it stops
  winning at almost exactly the moment $33AF lands. Altirra's PRIOR simply holds
  $41 until 13.6 s because NOTHING overwrites it until then.
  **=> NEXT, AND IT IS THE ORIGINAL QUESTION: WHY IS OUR INTRO ~3x FASTER?**
  Do NOT resurrect the retracted $97/$BC chain (#6). Rebuild from measurement:
  pick a CODE LANDMARK both machines execute early (e.g. the $3043 dispatcher, or
  the first $353A uploader run), and compare ELAPSED TIME / FRAME COUNT to
  $33AF within each machine's own run. >=1000 samples per side, fractions not
  counts. Altirra is DETERMINISTIC across cold resets, which makes it a stable
  ruler.
  ############################################################################

  ############################################################################
  **THE MAN: OUR OS VBI SHADOW COPY *DECAYS AND THEN STOPS* (2026-08-15).
  MOST CONCRETE FINDING SO FAR.**
  Our OS ROM DOES contain the classic VBI stage-2 shadow sequence (found by
  searching `sim/atari_xl_rom.mem` for `8D 1B D0`):
        $C146  8D 00 D4   sta DMACTL
        $C149  AD 6F 02   lda GPRIOR ($026F)
        $C14C  8D 1B D0   sta PRIOR  ($D01B)
  **How often it actually executes, measured across our captures:**
        early.bin  (first 4 s):  **209 times (~52/s = EVERY FRAME)**, GPRIOR = **$41 x130**, $00 x79
        prior.bin  (t~5-13 s):   **14 times (~1.75/s)**,              GPRIOR = **$41 x14**
        hw_long2.bin / multi.bin / entry.bin (later): **NEVER EXECUTED**
  **So we DO push $41 (scheme 0, players above playfield) -- at full frame rate
  at first, then sparsely, then not at all -- while $33AF keeps writing $54.
  As the VBI copy dies out, $54 stands unopposed and EVERY PLAYER IS HIDDEN.**
  That matches the screen exactly: 0 of 9 mode-9 frames contain a player pixel,
  from t=4 s onward.
  **=> THE TARGET IS "WHY DOES THE OS VBI STAGE-2 STOP RUNNING?", NOT THE RENDER
  PATH.** Compare against Altirra, whose PRIOR holds $41 for frames 107..680
  (t~2.1..13.6 s) before going to $54 -- i.e. its stage-2 keeps winning for far
  longer.
  **CAUTION:** the three "NEVER EXECUTED" captures are from EARLIER SESSIONS and
  different phases; re-measure the decay in ONE continuous capture before
  treating the rate curve as exact. The early-vs-prior contrast (209 vs 14) is
  within tonight's runs and is the solid part.
  **NOTE this rhymes with an earlier measured result that must NOT be
  contradicted carelessly: "$BC80=0, VBI path 100% FULL, no dropped VBIs" was
  true IN ITS WINDOW.** Stage-2 ceasing is not the same as the VBI being dropped
  -- a game commonly installs its own VVBLKD. The question is whether OUR
  stage-2 stops EARLIER than Altirra's.
  ############################################################################

  ############################################################################
  **RETRACTION #11 (MY OWN INSTRUMENT MISREAD) AND THE CORRECTED PICTURE:
  ALTIRRA HAS AN ~11.5 s "$41" WINDOW WHERE PLAYERS ARE ABOVE THE PLAYFIELD
  (2026-08-15).**
  FIVE independent cold-reset runs, PRIOR sampled per frame -- **Altirra is
  DETERMINISTIC across cold resets** (runs 0 and 1 byte-identical):
        PRIOR histogram {$00: 107, $41: 573, $54: 820}; **first $54 at frame 680
        (t~13.6 s)**
  **So Altirra DOES reach $54, at t~13.6 s.** The earlier "PRIOR stays $41 for
  1892 frames" was **ME MISREADING MY OWN LOG**: altprior.py only printed changes
  to the MODE BITS (PRIOR[7:6]), and $41 -> $54 leaves those at 01, so the
  transition was never logged. The instrument was fine; the reading was not.
  **CORRECTED DIVERGENCE -- smaller, but sharper:**
        ALTIRRA  $00 -> **$41 for frames 107..680 (t~2.1..13.6 s)** -> $54
        OURS     $54 already in effect at the FIRST sample, **t=4 s**
  **$41 = scheme 0 = PLAYERS ABOVE PLAYFIELD.** That ~11.5 s window is exactly
  when Altirra's man is visible. **Ours appears to have little or no such
  window**, which is why 0 of 9 of our mode-9 frames contain a player pixel.
  **WHERE DOES $41 COME FROM?** `MEMSEARCH 8d1bd0` finds only three absolute
  PRIOR writers: $33AF ($54), $BCC4 (`lda #$01`, executed by nobody), and
  **$C083 (OS ROM)**. GPRIOR ($026F) = **$41** on Altirra. So the OS is almost
  certainly pushing GPRIOR -> PRIOR during that window. **OUR OS ROM IS A
  DIFFERENT BUILD** (our vectors $C018/$C02C vs Altirra's $C18E/$C1A2), so it is
  a strong candidate for not doing that push, leaving $33AF's $54 standing.
  **NEXT: capture our EARLY intro (t=0..6 s) and ask whether our PRIOR is EVER
  $41, and whether anything writes it.** Then compare GPRIOR ($026F) on both.
  If ours never sees $41, the missing man is an OS-ROM behaviour difference, not
  an RTL bug.
  **NOTE the earlier "we run $33AF ~36 s early" is now ~10 s, and the branch-rate
  mechanism stays REFUTED (fall-through 5.3% Altirra vs 6.5% ours).**
  ############################################################################

  ############################################################################
  **QUALIFYING THE "36 SECONDS EARLY" CLAIM — THE PROPOSED MECHANISM IS DEAD,
  AND THE COMPARISON IS CROSS-RUN (2026-08-15).**
  The gate is `$33A0 iny / $33A1 bne $33D3`, so the $54 setup at $33A3 is reached
  ONLY when Y wraps to 0. Measured fall-through rates:
        alt_vlong  iny@$33A0 n=94  Y==0 -> **5  (5.3%)**
        hw_long2   iny@$33A0 n=31  Y==0 -> **2  (6.5%)**
        (prior.bin 2/10 = 20% and multi.bin 1/7 = 14.3% are SMALL-n NOISE)
  **THE RATES MATCH. We are NOT reaching $33AF disproportionately often**, so
  "we take that branch more" is refuted.
  **AND THE HEADLINE COMPARISON IS CROSS-RUN.** `alt_vlong.bin` covers t~13-73 s
  and contains **5 $33AF writes of $54**, while the PRIOR sweep covering t=0-40 s
  reported **$41 throughout**. Those windows OVERLAP, so both can only be true if
  they are **DIFFERENT RUNS** -- which they are. **And the intro is POKEY-RANDOM
  SEEDED ($3000-$303E reads $D20A four times plus `bit RANDOM / bpl`), so separate
  runs genuinely diverge.**
  **=> "we run $33AF ~36 s early" rests on ONE Altirra run vs ours. One run may
  not be representative. DO NOT BUILD ON IT YET.**
  **RUNNING:** `scratchpad/altrep.py` -> `altrep.log` -- **FIVE independent
  cold-reset Altirra runs**, each sweeping PRIOR per frame for 1500 frames (30 s)
  and recording the histogram and the frame at which $54 first appears. If $41
  persists across most runs while ours is $54 by t=4 s every time, the timing
  divergence is real; if Altirra's runs vary widely, the whole comparison is
  seed-noise and must be redone per-run with a shared landmark.
  **STANDING RULE THIS EXPOSES: NEVER COMPARE TWO CAPTURES FROM DIFFERENT RUNS OF
  A RANDOM-SEEDED PROGRAM.** Anchor within a single run, or repeat and compare
  DISTRIBUTIONS.
  ############################################################################

  ############################################################################
  **RESOLVED TO A TIMING DIVERGENCE: WE RUN $33AF ~36 SECONDS TOO EARLY
  (2026-08-15). THE MAN IS A CASUALTY OF SEQUENCING, NOT OF THE RENDER PATH.**
  **CHANNEL VALIDATED FIRST** (the step that saved this from being wrong):
        Altirra now: `PMG`.prior = **$54** (HARDWARE), GPRIOR $026F = **$41** (OS SHADOW)
  They genuinely differ, and `PMG`.prior tracks the HARDWARE register -- so the
  earlier sweep reading $41 for 1892 consecutive intro frames was real.
  **NEITHER MACHINE RUNS A PER-FRAME VBI COPY.** `trace_writes --altirra` over
  alt_vlong (19.2M records) finds **only 5 PRIOR writes, ALL from $33AF, ALL
  $54** -- and ours finds only 2, also $33AF/$54. A GPRIOR->PRIOR copy would give
  hundreds. So **$41 is a one-time value standing from boot**, not maintained.
  **THE DIVERGENCE IS WHEN $33AF RUNS:**
        ALTIRRA  PRIOR = $41 from t~2.2 s and **STILL $41 at t~40 s** -- $33AF has
                 NOT run at any point during the whole intro
        OURS     scheme-2 behaviour on the screen from the FIRST sample at
                 **t=4 s**; mode 9 ends t~18 s; GAMEPLAY by t~26 s
  **Both machines execute the same byte-identical code; ours executes it roughly
  THIRTY-SIX SECONDS EARLIER.** $33AF is display setup (DMACTL=$3E, GRACTL=$03,
  PRIOR=$54) and $33AD is an IMMEDIATE `lda #$54`, so there is no data
  dependence -- only control flow.
  **THIS TIES THE WHOLE SYMPTOM TOGETHER:** PRIOR $54 = scheme 2 = playfield above
  all four players, and in mode 9 the playfield covers the entire window, so
  **every player is hidden from t=4 s onward -- which is why 0 of 9 of our mode-9
  frames contain a single player pixel while Altirra's man appears late in its
  much longer mode-9 phase (0.05% -> 0.72%, monotonic growth).** It is the same
  fault as the intro running too fast and cutting to gameplay early.
  **=> THE MISSING MAN AND THE FAST/REPEATING INTRO ARE ONE BUG, AND IT IS
  CPU-SIDE SEQUENCING.** The render path is exonerated for this symptom; do NOT
  touch gtia_priority.
  **NEXT:** find what gates the path to $33AF and why we reach it ~36 s early --
  predecessor-histogram $33A3/$33AD in a CONTINUOUS board capture, and compare
  against Altirra with **>=1000 samples per side, fractions, phase-anchored on a
  code landmark**. Note this is the SAME territory as the retracted $97/$BC chain
  (#6) -- rebuild it from measurement, not from that chain.
  ############################################################################

  ############################################################################
  **PRIOR DIFFERS DURING THE INTRO: OURS $54, ALTIRRA $41 — STRONGEST LEAD FOR
  THE MISSING MAN, BUT ONE CHANNEL IS UNVALIDATED (2026-08-15).**
        ALTIRRA PRIOR sweep from cold reset (per frame, `PMG`.prior):
              frame   0 (t~0.0 s): PRIOR=$00, GTIA mode bits 0
              frame 108 (t~2.2 s): **PRIOR=$41**, GTIA mode bits 1
              ...and it **NEVER CHANGES for the remaining 1892 frames (to t~40 s)**
        OURS (dtrace during the intro, trace_writes): **PRIOR=$54 written twice
              from $33AF**; screen behaviour agrees (players hidden).
        **$41** = mode 9, no fifth player, **priority scheme 0 = PLAYERS ABOVE PLAYFIELD**
        **$54** = mode 9, fifth player,   **priority scheme 2 = PLAYFIELD ABOVE PLAYERS**
  That is exactly the difference between a visible man and a hidden one.
  **RETRACTION #10:** "PRIOR $54 matches on both machines" was based on a single
  `alt.pmg()` peek taken during **GAMEPLAY** — the sample-at-one-moment trap
  again. During the INTRO they differ.
  **PHASE SPANS ALSO DIFFER:** ours is in mode 9 t=4..18 s and in GAMEPLAY by
  t=26 s (whole intro ~22 s); **Altirra is still in mode 9 at t=40 s.** Its player
  pixels appear late in that long stretch (0.05% -> 0.16% -> 0.30% -> 0.72%,
  monotonic growth = an object appearing), in 5 of 30 mode-9 frames; **ours: 0 of
  9 mode-9 frames, across the ENTIRE span of our mode-9 phase.**

  **WHAT IS NOT YET EXPLAINED — DO NOT SKIP THIS.**
  `$33AD lda #$54` is an **IMMEDIATE CONSTANT**, and **BOTH machines execute
  $33AF and write $54** (alt_vlong: 5 times). `MEMSEARCH 8d1bd0` finds only three
  PRIOR writers: **$33AF ($54), $BCC4 (`lda #$01`, executed by NOBODY in any
  trace), and $C083 (OS ROM, executed by NOBODY in these windows)**. **So the
  source of Altirra's $41 is UNIDENTIFIED.**
  **THE UNVALIDATED CHANNEL:** it was never confirmed that `PMG`.prior reports the
  HARDWARE register rather than the **GPRIOR shadow ($026F)**, which the OS VBI
  copies to PRIOR each frame. **If pmg() reports the shadow, the $54-vs-$41
  difference may be an artefact and this whole lead collapses.**
  **NEXT, IN ORDER:** (1) **validate the channel** — write a known value to PRIOR
  on Altirra and see whether `PMG`.prior follows it, and separately peek GPRIOR
  ($026F) on both machines; (2) if the difference is real, find what writes $41
  (try a write-watch, or search for indexed/indirect PRIOR stores that
  `MEMSEARCH 8d1bd0` cannot see); (3) only then decide whether this is a
  sequencing divergence (we take a path that leaves $54 standing) or a shadow /
  VBI difference.
  ############################################################################

  ############################################################################
  **DENSE SAMPLING: ALTIRRA'S MAN APPEARS LATE IN A *LONGER* MODE-9 PHASE
  (2026-08-15). THIS LOOKS LIKE SEQUENCING, NOT PRIORITY.**
        ALTIRRA  30 mode-9 frames, **5 with player pixels**, and the fraction
                 GROWS MONOTONICALLY over the last five:
                 altd25 **0.05%** -> altd26 **0.16%** -> altd27 **0.30%**
                 -> altd28 **0.72%** -> altd29 **0.72%**
        OURS      9 mode-9 frames, **0 with player pixels**
  A monotonically growing player fraction is an object APPEARING and EXPANDING --
  plausibly the man walking out and waving.
  **BUT THE SPANS DIFFER, AND THAT IS THE POINT.** ALL THIRTY of Altirra's
  sampled frames are still in mode 9, and the player appears near the END of that
  long stretch. **Ours leaves mode 9 after frame 8 (t~18 s)** -- every later frame
  is a different scene (f09-f17 have hue1 = 0%). **Our mode-9 phase is SHORTER,
  and we exit it before the point where Altirra's man appears.**
  **=> "we exit the scene early" is AT LEAST AS CONSISTENT with this data as "our
  priority hides the player", and it also fits the reported symptom (the intro
  fast-forwards / repeats). DO NOT CHANGE THE PRIORITY PATH.**
  **THE DISCRIMINATING TEST:** measure **HOW LONG each machine stays in mode 9**
  (PRIOR[7:6]==01) from the same code landmark -- on ours from the trace
  (PRIOR writes at $33AF and any others), on Altirra by sampling PRIOR per frame.
  If our mode-9 phase is genuinely shorter, the man is a casualty of SEQUENCING
  and the whole priority line is void. Only if the phases are the SAME LENGTH and
  we still show no player does the priority asymmetry (gtia_stage line 294 vs
  line 142) become the suspect again.
  **SAMPLING NOTE:** ours was 18 frames at 1 s intervals from t~10 s; Altirra's
  was 30 frames 25 emulator-frames apart from boot+450. **Not the same cadence or
  window** -- re-measure both against a CODE LANDMARK before drawing more.
  ############################################################################

  ############################################################################
  **ORACLE RESULT: THE PRIORITY HYPOTHESIS IS *NOT* CONFIRMED (2026-08-15).**
  Altirra with **NTSC artifacting DISABLED** (`CONFIG artifact none` -- syntax is
  `CONFIG <key> <value>`, and it drops rawscreen to a clean **336x224**), six
  frames across its intro, colours mapped by NEAREST NEIGHBOUR through Altirra's
  own palette (`PALETTE` verb; exact lookup FAILS on rounding of 1..65):
        alt_seq_a: hue1 100.0%              player hues 3+5 = 0.00%
        alt_seq_b: hue1 99.27, hue3 0.73    player hues 3+5 = **0.73%**
        alt_seq_c: hue1 100.0%              player hues 3+5 = 0.00%
        alt_seq_d: hue1 100.0%              player hues 3+5 = 0.00%
        alt_seq_e/f: gameplay (hue7 41.96, hue11 41.96)
  **Altirra's mode-9 intro is ALSO ~100% hue 1.** Three of four frames contain NO
  player pixels, exactly like ours. Only ONE frame carries 0.73% hue 3 (~1650 px,
  plausibly a small object).
  **That is 1-of-4 versus our 0-of-4 -- nowhere near enough to claim a
  difference.** The hypothesis may still be right (that 0.73% could BE the man)
  but four frames a side is precisely the thin sampling behind retractions #6 and
  #8. **DO NOT CHANGE THE PRIORITY PATH ON THIS EVIDENCE.**
  **NEXT: DENSE SAMPLING BOTH SIDES.** >=20 frames each across the mode-9 phase,
  and compare the FRACTION OF FRAMES containing any hue-3/hue-5 pixel. If Altirra
  shows player pixels in a meaningful share of frames and we show none, the
  hypothesis is confirmed and the fix is to give the priority path the same
  GTIA-aware substitution the collision path already has (gtia_stage line 294 vs
  line 142). If both are ~0, the man is not a visible player in this phase and
  the whole line is void.

  **TWO TOOLING FACTS ESTABLISHED (both needed for any future screen compare):**
  * **NEAREST-NEIGHBOUR palette matching is required** -- Altirra's rawscreen
    values differ from its own palette by 1..65 per channel, so exact lookup
    silently maps NOTHING and yields a confident empty answer.
  * **The 16-vs-8 colour count is PALETTE GRANULARITY, not players.** Altirra's
    palette has distinct ODD luminances ($17 = #768600); ours duplicates each
    pair because luma bit 0 is unused. Do not read that as a rendering
    difference.
  ############################################################################

  ############################################################################
  **THE MISSING MAN: NO PLAYER IS VISIBLE ANYWHERE IN THE INTRO (2026-08-15).**
  Eight frames grabbed across the intro on the FIXED bitstream, colours mapped
  through the palette and grouped by HUE:
        frames 1-4 (t~12-24 s): 8 colours, **hue 1 = 100.0%  -- NOTHING ELSE**
        frame  5   (t~28 s):    hue3 44.8%, hue5 45.8%, hue0 9.4%  (scene change)
        frames 6-8 (t~32-40 s): hue7 44.8%, hue11 43.8%           (gameplay)
  **Player colours come from COLPM0-3 = $52/$32/$54/$34 -- hues 3 and 5.** In a
  GTIA mode a winning player keeps its OWN colour, so a visible player must show
  as hue 3 or 5. **Across the whole mode-9 intro there are ZERO hue-3 and ZERO
  hue-5 pixels: no player is drawn anywhere, on any frame** -- while we separately
  measured HPOSP0/HPOSP1 animated with Altirra-matching values and shape data
  uploaded. The players are set up correctly and then never appear.

  **MECHANISM, AND IT IS AN EXPLICIT ASYMMETRY IN OUR CODE.** PRIOR $54 selects
  **scheme 2: playfield above all four players**. In GTIA mode 9 the playfield
  covers the ENTIRE window -- every nibble is a luminance, never background -- so
  scheme 2 hides EVERY player EVERYWHERE. gtia_stage already knows a GTIA-mode
  pixel is not a playfield pixel, and says so in its own comment ("PRIOR[7:6]
  stops the playfield being a playfield ... mode 9: no playfield collisions at
  all -- the byte is a LUMINANCE"), **but applies that rule ONLY to collisions**:
        line 294  `wire [2:0] col_pf = gtia_active ? col_pf_now : cur_pf;`  <- collisions: GTIA-aware
        line 142  `.pf_src(cur_pf)`                                          <- priority:  RAW, not GTIA-aware
  So in mode 9 the luminance is still ranked PF0-3 and outranks every player.

  **DO NOT CHANGE RTL ON THIS WITHOUT THE ORACLE.** The claim that players should
  win over a mode-9 field is exactly the kind that has been wrong nine times
  tonight. **THE DECISIVE TEST: does ALTIRRA show player-coloured pixels during
  the mode-9 intro?** If yes, our priority path is wrong and should take the same
  GTIA-aware substitution the collision path already uses. If no, the man is not
  a player at all and this whole line is void.
  **CAUTION on the oracle:** `alt.rawscreen()` is NTSC-FILTERED (672x224, 790+
  colours vs our 8), so compare HUE FAMILIES / structure, never exact colours.
  ############################################################################

  ############################################################################
  **THE LEFT-EDGE BAR IS FIXED — CONFIRMED ON HARDWARE BY MEASUREMENT
  (2026-08-15, commit b0de37fe, bitstream loaded).**
        graboverlay, two intro frames 6 s apart, colours mapped through the palette
        BEFORE: **9 distinct colours, hues {1,2}**, columns 0-3 = **$29 (hue 2)**
                over 148 of 192 rows
        AFTER:  **8 distinct colours, hues {1} ONLY**, columns 0-3 = **$11
                (background) over 192/192 rows, in BOTH frames**
  **Hue 2 is GONE from the frame entirely**, and the same eight legitimate hue-1
  colours remain, so nothing else changed. That is exactly what GTIA mode 9
  mandates: every playfield pixel carries COLBK's hue.
  This artefact was verifiable WITHOUT a human judgement call -- it is a
  four-pixel column of a specific colour code, so measuring it is stronger
  evidence than an impression. **Simon's eyes are still wanted for the intro as a
  whole, but the bar itself is settled.**
  **VALIDATION BEFORE LOADING:** all three ACID tests that can reach the changed
  line PASS -- **gtia_psuedomodee, antic_pmdma, gtia_phantomdma** (found by
  grepping the ACID sources for PRIOR[7:6] != 00; nothing else can reach it).
  Unit benches green. Build closed timing despite the extra mux level
  (`write_bitstream completed successfully`; the build aborts on negative WNS).
  ############################################################################

  ############################################################################
  **SCOPING CORRECTION: THE BAR FIX DOES NOT EXPLAIN THE MISSING MAN
  (2026-08-15).** Do not let these two run together.
  The measured spurious playfield is **4 pixels, columns 0-3**, and its colour
  appears at **ZERO other pixels in the frame** -- so there is **no other
  spurious playfield anywhere on screen**. The man appears MID-SCREEN. **A
  four-pixel left-edge artefact cannot hide him.**
  "PRIOR $54 puts the playfield above all players, so spurious playfield hides
  objects" is a REAL mechanism but its MEASURED EXTENT is four pixels. Expecting
  the man to return with the bar fix over-reads the evidence.
  **THE MAN REMAINS OPEN, and the likeliest explanation is still SEQUENCING** --
  the scene never plays -- which is the thread whose mechanism ($97 -> $A1 -> $BC)
  was RETRACTED as a sample-size artifact (#6). That leaves the intro's
  slowness/repetition ({smooth anim}{abrupt switch}) genuinely UNEXPLAINED.
  **NEXT, AFTER THE BAR IS CONFIRMED FIXED:** re-open the sequencing question
  with the sample discipline learned tonight -- >=1000 samples per side,
  fractions not counts, phase-anchored on a code landmark, and a CONTINUOUS
  board capture (hw_long2.bin style, 4 back-to-back dtrace segments) against
  alt_vlong.bin. Do NOT rebuild the retracted $97/$BC chain from a short capture.
  ############################################################################

  ############################################################################
  **LEFT-EDGE BAR: CONFIRMED IN SIM, AND ONE OF THE TWO CANDIDATE FIXES IS
  REFUTED (2026-08-15).  `make -C sim gtia_stage` IS RED ON PURPOSE.**
  `tb_gtia_stage` TG/TG2 drive GTIA mode 9 with **COLBK at hue 1 and the
  playfield registers at hue 2**, so the two are told apart by HUE ALONE exactly
  as on hardware:
        TG  (after line_start):       cc0 $26 h2, cc1 $26 h2, cc2 $1f h1, cc3 $1f h1
        TG2 (window opens mid-line):  0cc $26 h2, 1cc $26 h2, 2cc $1f h1, ...
  The window opens at machine cycle 20 = px_pos 80 = **PLANE COLUMN 0**, so those
  two colour clocks ARE plane columns 0-3 -- **the measured bar, to the pixel.
  Width, hue and position all agree with the board.**
  **THESE ASSERT (unlike T10 in tb_gtia_obj_walk, which only REPORTS).** The
  claim *"in a GTIA mode every displayed playfield pixel carries COLBK's hue"* is
  true whichever fix is chosen, so the test is right and the RTL is wrong. T10's
  layer was genuinely unknown, so it reports. **Keep that distinction.**

  **FIX (b) IS REFUTED: `pf_win` IS NOT RISING EARLY.** a2_video.sv:139-155
  assigns `win_cap <= px_in_window` and `pv_cap_a <= px_wr ? px_val : 2'd0` in
  the **SAME `if (!px_odd)` BRANCH ON THE SAME `px_tick`**. The window flag and
  the playfield data are captured in LOCKSTEP and cannot drift. So the artefact
  is NOT an upstream misalignment; it is the `gtia_win`/`gtia_nib` staging in
  `gtia_stage`.
  **AND `gtia_win` IS CONSISTENT WITH `gtia_nib`:** both load on the ODD clock
  (`win_ready <= pf_win`, `nib_ready <= {an_prev, an_pair}`) and both transfer on
  the EVEN clock. The nibble GENUINELY needs two colour clocks to assemble (2
  bits per clock, 4 bits per nibble), so the staging itself is right.
  **THE ACTUAL DEFECT IS THE FALL-THROUGH.** During the priming pair `gtia_win`
  is 0, so `resolved` takes **`sel_color` -- a NORMAL PLAYFIELD COLOUR, WHICH
  DOES NOT EXIST IN A GTIA MODE.** ANTIC is sending luminance/index data there,
  not a playfield source, so `sel_color` is meaningless; a real Atari shows the
  BACKGROUND at that edge, not COLPF3.
  **LIKELY MINIMAL FIX (NOT YET APPLIED):** when `gtia_active && !win_is_object
  && !gtia_win`, emit **COLBK** rather than `sel_color`. Narrow and defensible,
  but it changes the border/field boundary, so **sim it, then a bitstream, then
  SIMON MUST CONFIRM VISUALLY.** Do not claim it works without his eyes.
  **DO NOT "fix" by shifting cc_pos** (a2_video.sv:227-233: everything positional
  shares one origin; shifting slides objects across the playfield).
  **LOOSE END (does NOT block the fix):** COLBK's traced writes are $00/$50/$30
  (hues 0/5/3), none hue 1 or $28, so where the hue-1 field and the hue-2 bar
  each originate is not fully derived. The hue-mismatch assertion holds anyway.
  ############################################################################

  ############################################################################
  **THE LEFT-EDGE BAR: MECHANISM FOUND (2026-08-15). GTIA-MODE RECOLOUR IS
  UNPRIMED FOR THE FIRST 2 COLOUR CLOCKS OF EVERY LINE.**
  Measured with `graboverlay` (XL plane, 320x192 BMP) during the intro, then the
  colours mapped through `hdl/palette/atari_ntsc.hex`:
        our whole screen: **$10 $12 $14 $16 $18 $1A $1C $1E**
                          = **hue 1, ALL EVEN LUMINANCES** = exactly GTIA mode 9
                            (16 luminances of COLBK's hue), PRIOR[7:6]=01
        the bar (cols 0-3, 592 px, 148 of 192 rows, 2 frames 6 s apart):
                          **$28 = hue 2 -- THE WRONG HUE**
  In mode 9 `gtia_special` computes `color = {colbk[7:4], nibble}`, so EVERY
  playfield pixel must carry COLBK's hue. A hue-2 pixel never went through the
  recolour: it took `sel_color`, not `gtia_color`.
  **WHY (gtia_stage.sv:204-221):** `line_start` clears `win_ready` and
  `gtia_win` to 0. Re-priming takes TWO steps -- an ODD colour clock loads
  `win_ready <= pf_win`, and the NEXT EVEN clock does `gtia_win <= win_ready`.
  **So gtia_win is 0 for the first 2 colour clocks of every line**, and
  `resolved = (gtia_active && gtia_win && !win_is_object) ? gtia_color :
  sel_color` therefore emits the UN-RECOLOURED playfield colour there.
        2 colour clocks = **4 pixels** = columns 0-3            MATCHES
        un-recoloured   = raw register hue, not COLBK's        MATCHES ($28)
        every line the playfield is active = 148 of 192 rows   MATCHES
  **THE SAME PIPELINE CARRIES `gtia_nib`**, cleared identically, so the first
  pair's nibble is stale/zero as well.
  **OPEN BEFORE FIXING:** COLBK's traced writes are $00/$50/$30 (hue 0/5/3),
  none of them hue 1 or $28, so where the hue-1 background and the hue-2 bar
  each come from is NOT yet fully derived -- **do not patch on this alone.**
  Next: a `tb_gtia_stage` case that asserts the first 2 colour clocks after
  line_start in a GTIA mode, which will either reproduce this or refute it.
  **DO NOT "FIX" BY SHIFTING cc_pos** (a2_video.sv:227-233: everything positional
  shares one origin; shifting it slides objects across the playfield).

  **RETRACTION #9 -- my own "HPOS $00 paints the left edge".** `antic_wb_adapt`:
  the framebuffer is 320 px taken from **px_pos 80..399** ("a normal window opens
  at machine cycle 20 and 20*4 = 80"). With `cc_pos = px_pos[8:1] - 1`, an object
  at HPOS h lands at **plane column 2h - 78**, so HPOS $00 -> column **-78**, OFF
  THE PLANE. The sim emission at cc 0..1 is real but never reaches the screen.
  T10 was left REPORTING rather than ASSERTING precisely so this could be undone
  without having baked in the wrong mechanism.

  **ALTIRRA: A HUNG BRIDGE MAY JUST BE PAUSED.** It had been silently paused
  since the breakpoint work, and **the Python client library HANGS against a
  paused emulator with no error**. The RAW protocol says so at once:
        s=socket.create_connection(('127.0.0.1',6503)); f=s.makefile('rwb')
        cmd('HELLO '+token) -> {"ok":true,...,"paused":true}   then cmd('RESUME')
  Token file: line 1 `tcp:127.0.0.1:6503`, line 2 the token. Verbs: HELLO, PING,
  RESUME, COLD_RESET, FRAME 1, REGS, RAWSCREEN [path=..|inline=true],
  RENDER_FRAME, DISASM. **BPCLEARALL is NOT a verb.**
  **`alt.rawscreen()` IS NTSC-FILTERED** -- 672x224 XRGB8888 with **790-986
  distinct colours** where ours has 9. **Do NOT diff its colours against ours.**
  ############################################################################

  ############################################################################
  **PRIOR $54 UNIFIES THE BARS AND THE MISSING MAN (2026-08-15).**
  PRIOR is **$54 on BOTH machines** (ours written once at $33AF; Altirra's
  `alt.pmg()` agrees). It decodes as:
        bits 7:6 = 01  -> **GTIA mode 9** (16 luminances of COLBK's hue)
        bit  4   = 1   -> fifth player (missiles join PF3)
        bits 3:0 = 0100 -> **priority scheme 2: PLAYFIELD ABOVE ALL PLAYERS**
  Our scheme-2 table (`gtia_priority.sv` rank_of, case 2) ranks PF0-3 at 0-3 and
  P0-3 at 4-7 -- **CORRECT**. The colour path is right too: gtia_stage recolours
  only a playfield/background win (`win_is_object = win_src >= 4'd6`), so players
  keep their own colour in GTIA modes. **Nothing is wrong in GTIA here.**
  **THE CONSEQUENCE IS THE POINT:** with PF above P0-3, a player is visible ONLY
  where the playfield is background. **Any spurious playfield content HIDES the
  players behind it.** The LEFT-EDGE BARS are exactly spurious playfield content,
  and their height is a MODE LINE's.
  **=> THE BARS AND THE MISSING MAN ARE PLAUSIBLY ONE BUG, NOT TWO:** our ANTIC
  playfield carries content where Altirra's carries background, and PRIOR $54
  converts that into a hidden object. **This also explains why every P/M
  measurement matched** -- the players are written, positioned and shaped
  correctly, and then covered.
  **=> THE SUSPECT MOVES FROM GTIA TO ANTIC'S PLAYFIELD GENERATION.**
  **NEXT:** compare the PLAYFIELD, not the players. `alt.rawscreen()` gives
  Altirra's screen; ours needs a board framebuffer grab (plane_grab -- see
  [[plane_grab_cache_and_oracles]], the stale-cache phantom was FIXED in
  d6f2c77a, trust devmem probes). The bars are persistent, so they do NOT need
  tight phase matching -- **capture the bar region on both and diff it.** That is
  the cheapest decisive experiment left.

  **SIM STATUS OF THE LIVE RENDER PATH (all pass, commits 15fcb818, 14c42532):**
  gtia_obj_walk, gtia_stage (26 of 28 fabric clocks), gtia_priority, gtia_collide.
  * **T8 (new)** drives `cc_pos` the way a2_video really does -- an 8-bit
    subtraction presenting **$FF at line start**, where every existing case fed a
    clean 0-upward count. A player at **HPOS $30** (x_left 0, the true left edge,
    BallBlazer's most-written HPOSP0) spans cc **48..55** correctly, and an object
    at $FF struck on the wrapped clock stays within its 8 clocks. **The cc_pos
    wrap lead is RETIRED.**
  * **A REAL TEST-QUALITY HOLE:** both benches instantiated their DUT with input
    **`resize` DANGLING** -- it means "SIZEP was WRITTEN this colour clock" and
    gates the resize clock and the 1x-alt lockup, so it floated **x** into all of
    it. Both now drive it. Tying it low is NOT sufficient: **T5 changes SIZEP
    mid-draw with no strobe, which cannot happen in hardware**, so defined-low
    makes T5 unphysical. **T9 (new)** is T5 plus the strobe, one colour clock
    wide: spans cc 60..67 for 8 clocks, shape does not restart. No bug, new
    coverage.
  ############################################################################

  ############################################################################
  **LONG CONTINUOUS BOARD CAPTURE CONFIRMS IT (2026-08-15).** `hw_long2.bin`,
  **6,917,312 records** (4 back-to-back `dtrace 4` segments from t=14 s), the
  like-for-like comparison that was missing all night. Sample counts finally meet
  the >=1000 bar.
        P/M shape bytes, non-zero fraction   P0    P1    P2    P3
        Altirra          n=2250              18%   31%   67%   72%
        board continuous n=962               15%   24%   51%   58%
  **Same ordering, same shape, no divergence.** The uniformly lower values track
  the different phase coverage.
        $BC at $BCEB   board n=1058: $00 74% / $FF 5% / $FD 18%
                       Altirra n=3000: $00 86% / $FF 8% / $FD  5%
  A modest residual ($FD 18% vs 5%) but the windows are NOT phase-matched (ours
  t=14-30 s, Altirra frames 652-3652), and our own captures span 0-100% on this
  metric. **NOT a divergence on this evidence.**

  **CAPTURE RECIPE — THE `&` TRAP.** `xlboot` must run in the FOREGROUND:
      rm -f /t1.bin..; /System/bin/xlboot /media/6502/Games/BallBlazer.atx; sleep 14;
      /System/bin/6502 dtrace 4 /t1.bin; ... ; cat /t1.bin /t2.bin /t3.bin /t4.bin
  Backgrounding it with `&` produced a capture that was **8.1M of 8.4M records
  spinning in $4Cxx with ZERO game code** -- the game never launched. **A capture
  whose page histogram lacks $3xxx is DEAD; check the histogram BEFORE analysing.**
  A saturated ring (every segment exactly 16777216 bytes) is another tell;
  real activity gives varying sizes.
  ############################################################################

  ############################################################################
  **RETRACTION #8, AND THE HONEST STATE: NO 6502-VISIBLE DIVERGENCE EXISTS
  (2026-08-15).**
  The "P1/P2 get only zeros" result came from multi.bin's **32 samples** -- the
  exact thinness flagged one turn earlier. With bigger captures it dies:
        non-zero fraction of P/M shape bytes uploaded by $353A
                        P0    P1    P2    P3
        Altirra n=2250  18%   31%   67%   72%
        hw_intro n=512  25%   **41%**  **72%**  71%     <- MATCHES Altirra
        hand    n=1732  10%   12%   11%   11%     <- different phase
  Our machine DOES fill P1 and P2 with real shape data, at fractions close to
  Altirra's. **The missing-man-as-missing-shape-data theory is dead.**
  (Only multi.bin, hw_intro.bin and hand.bin contain the uploader at all;
  entry/bbt/bbp/hw_anim/hw_fixed/hw_start/hw_p3-5/bb3 never execute $353A.)

  **THE $BC RATIO DIES THE SAME WAY.** $BC at $BCEB, share reading $00:
        alt_vlong n=3000 **86%** | hw_intro n=324 **100%** | hand n=562 50%
        multi n=383 27% | entry n=541 51% | bbt n=281 **0%** | hw_anim n=311 100%
  **Our own captures span 0%-100% -- a wider spread than the gap to Altirra's
  86%.** Phase-dependent, not a machine difference. NOT ESTABLISHED.

  **=> EVERYTHING 6502-VISIBLE THAT HAS BEEN MEASURED WITH ADEQUATE SAMPLES
  MATCHES ALTIRRA:** the $3043 dispatcher and its gates ($97, $A1, $D6), $BC and
  the ticker, the P/M REGISTERS (HPOSP0/1 values $F0/$10 match EXACTLY; HPOSP2/3
  parked on both; COLPM0-3 recoloured ~203x on both), the P/M SHAPE DATA, PMBASE,
  DMACTL, GRACTL, and the code itself (byte-identical). **That is a significant
  NEGATIVE RESULT, not a failure** -- it says the CPU-visible behaviour is right.

  **WHICH REDIRECTS SUSPICION BACK TO THE RENDER/DISPLAY PATH** -- the opposite of
  what was concluded earlier tonight from the (now retracted) tool artifact. If
  the 6502 writes the same data at the same rates and the SCREEN still differs,
  the difference is in what the chipset DOES with correct data: per-colour-clock
  P/M evaluation, priority, or WHEN writes land relative to the beam. Note
  ACID800's P/M cluster PASSES, so it is not a gross P/M fault -- look for
  TIMING-of-write-vs-beam and mid-line register effects.
  **CAVEAT THAT MATTERS:** our captures are SHORT (1.3-5.2M records, ~0.2-0.8 s of
  game time) and taken at SCATTERED moments; Altirra's reference is 19.2M
  CONTINUOUS. **We have never compared like-for-like over a long continuous
  window on hardware.** NEXT: take a long continuous board capture (back-to-back
  dtrace segments across the whole intro) and compare aggregates against
  alt_vlong.bin before drawing any further conclusion.
  ############################################################################

  ############################################################################
  **RETRACTION #7 — "ALTIRRA NEVER WRITES P/M SHAPE MEMORY" IS WRONG, AND
  trace_writes.py HAS A SILENT-FAILURE MODE (2026-08-15).**
  Altirra executes the clear/upload routine **2688 times** ($3542, $3548, $354E,
  $3554) against our 32 -- and scaled for capture length the RATES MATCH
  (2688/32 = 84x; $3500 is 336/4 = 84x; alt_vlong is ~84x longer in game-time).
  Disassembly gives the ground truth -- it is a **P/M SHAPE UPLOADER**, and its
  stores are ABSOLUTE-INDEXED, identical on both machines:
        $353A lda ($FE),Y / $353C sta $0300,X   (missiles)
        $3540 lda ($FE),Y / $3542 sta $0400,X   (P0)
        $3546 lda ($FE),Y / $3548 sta $0500,X   (P1)
        $354C lda ($FE),Y / $354E sta $0600,X   (P2)
        $3552 lda ($FE),Y / $3554 sta $0700,X   (P3)
  So the "we uniquely clear P1/P2 while Altirra leaves them alone" conclusion is
  DEAD, and so is the inference that PMBASE is $98 on Altirra (that came from the
  same broken run; `alt.antic()` reporting PMBASE=$00 was ALSO a single-moment
  gameplay peek -- do not use it for the intro either).

  **THE TOOL HAZARD — READ BEFORE QUOTING ANY trace_writes.py NUMBER.**
  `trace_writes.py` resolves each store site's operand with `alt.peek(pc+1,n)`
  inside a `try/except` that **`continue`s silently on failure**. A site whose
  peek fails is DROPPED, so the tool can report **"0 writes" when it means "0
  operands resolved"**. With 411 distinct store sites against a busy bridge this
  is easy to hit, and it is exactly what produced both the false "Altirra writes
  nothing into $0400-$07FF" and the phantom "$353A -> $9Exx" (impossible: $353A
  is `lda ($FE),Y`, a LOAD, which is not even in the tool's STORES table).
  **FIX THE TOOL FIRST:** count and REPORT peek failures, and fail loudly rather
  than returning an empty result. Until then treat every zero result as UNPROVEN.

  **NET EFFECT ON THE INVESTIGATION.** Both pillars of the last several hours are
  now retracted: the $97/$BC gate (sample-size artifact, #6) and the P/M
  shape-memory difference (tool artifact, #7). **NO CONFIRMED DIVERGENCE between
  the machines currently stands.** What remains solid is the downstream MECHANISM
  (only $BC==$FF wraps X at $3DE1 to reach $3E00 `inc $C2`; at $FD the ticker
  runs while $C2 stalls, giving the ~12 s spin at $30CC) and the fact that the
  intro is SEEDED FROM POKEY RANDOM. Rebuild from measurements, not from the
  retracted chain.
  ############################################################################

  ############################################################################
  **RETRACTION #6 — THE $97/$BC DIVERGENCE IS NOT REAL (2026-08-15).**
  A 3000-frame TRACEFILE capture (`alt_vlong.bin`, **19,186,675 records, 0
  lost**) shows Altirra doing EVERYTHING we do:
        reach: 3083 x1, 309B x1, 30EA x1, 3E12 x1, **3E00 x255**, BCEF x413
        $BC at $BCEB (n=3000): **$00 x2587, $FF x256, $FD x156, $FE x1**
        $97 at $3053 (n=3):    **$FE x2**, $00 x1     <- Altirra ALSO has $FE
        $A1 at $3069 (n=2):    $03, $04
  So "Altirra holds $97=$00 and $BC=$00 in 420/420 and never executes
  $3083/$309B/$3E00" was a **SAMPLE-SIZE ARTIFACT**: alt_late.bin's 420 samples
  all landed in the quiet phase. The trap list already said CHECK SAMPLE COUNT
  BEFORE CONCLUDING -- written one turn before it was violated.
  **What survives is quantitative, not binary:** Altirra sits at $BC==$00 for
  **86%** of ticks (2587/3000); ours is 100% (hw_anim), 53% (entry), 27%
  (multi), **0%** (bbt). A RATIO difference over short, varying captures --
  much weaker than reported. **Prefer ratios over rates** (also already on the
  trap list).
  **DO NOT re-derive a "$97 divergence" from a short capture.** Any future claim
  here needs >=1000 samples per side.

  **THE P/M FINDING SURVIVES, AND SURVIVES HARDER.** Re-run against the same
  19.2M-record trace: Altirra still writes **ZERO** into $0400-$07FF, versus our
  264 writes including the repeated P1/P2 clears. More samples moved it AWAY from
  zero-difference, which is the opposite of a sample-size artifact.

  **TOP REMAINING HYPOTHESIS: POKEY RANDOM ($D20A).** $3000-$303E seeds the whole
  intro from RANDOM (4 reads into $A4-$A9 plus `$3032 bit RANDOM / bpl`), which is
  a register WE EMULATE -- so a difference here is OUR bug, and it would explain
  the run-to-run non-determinism, the varying $BC ratios, and why GAMEPLAY (not
  random-seeded) is perfect.
  **hdl/pokey_audio.sv SELF-DOCUMENTS THE WEAK POINT:** RANDOM = lfsr17_q[16:9],
  and the 17-bit poly's comment says it is *"fit to ONE constraint (unlike the
  9-bit, which was pinned by three), chosen because it is the only exact fit that
  is also structurally identical to the verified 9-bit form"* -- one ACID800
  pokey_noise read expecting $08. The 9-bit form was pinned by three simultaneous
  reads; the 17-bit was not.
  **NOTE the reciprocal argument is sound as far as it goes:** taps (5,0)
  right-shifting realises the reciprocal of x^17+x^12+1, and the reciprocal of a
  primitive polynomial IS primitive, so the PERIOD is still 131071. A wrong
  realisation would therefore still look "random" -- it would differ in PHASE and
  ORDERING, not in period or uniformity. **So a period/uniformity test alone
  CANNOT settle this**; the test must compare the SEQUENCE against Altirra from a
  known SKCTL-release point.
  **NEXT:** dump RANDOM every phi2 tick from the SKCTL release in sim, and get
  the matching sequence out of Altirra (successive reads at known cycle offsets);
  compare ordering, not just distribution.
  ############################################################################

  ############################################################################
  **P/M REGISTERS CAPTURED: THE MISSING MAN IS NOT A RENDER BUG (2026-08-15).**
  `trace_writes.py multi.bin --range D000 D01F` + `--range 0400 07FF`, against
  the phase-matched `alt_late.bin`. Both machines: **PMBASE=$00, DMACTL=$3E,
  GRACTL=$03**, so player shapes come from **P/M DMA out of $0400-$07FF**
  (P0 $0400, P1 $0500, P2 $0600, P3 $0700) and **GRAFP0-3/GRAFM get ZERO direct
  writes** on our side -- correct, DMA supplies them.
        register        ours                      Altirra
        HPOSP0          50 writes, $F0 / $30      **$F0**
        HPOSP1          50 writes, $10 / $50      **$10**
        HPOSP2/3        3 writes (init only)      $00 / $00
        COLPM0-3        ~203 writes EACH          --
        GRAFP (DMA)     --                        **$FF,$FF,$00,$00**
        shape bytes     P0 136 non-zero           **writes NOTHING in-window**
                        **P1 0 non-zero (32 clears from $3548)**
                        **P2 0 non-zero (32 clears from $354E)**
                        P3 24 non-zero
  **Our HPOSP0/HPOSP1 values MATCH Altirra exactly ($F0/$10)**, and our render
  path visibly draws P0 and P3. The difference is the SHAPE MEMORY: Altirra holds
  live shapes in BOTH P0 and P1 and never touches P/M RAM in the window (set up
  earlier, left alone), while **we write it 264 times, repeatedly CLEARING P1 and
  P2**. All four players are recoloured ~203x while only two ever move.
  **CONCLUSION: the game never writes the missing object's shape in our run -- it
  keeps tearing it down. This is NOT a bug in the live render path; it is
  downstream of the scene-sequencing fault ($97 -> $A1 -> $BC).** It also matches
  the reported symptom exactly: objects animate smoothly, vanish abruptly, and a
  different set animates.
  **STALE MEMORY CORRECTED:** `ballblazer_players_frozen` says "HPOSP never
  updates, P0 stuck at $30". **P0 and P1 DO update** (50 writes each). Do not
  cite that note.
  **TOOL BLIND SPOT — STATE IT WHENEVER QUOTING THESE NUMBERS:** trace_writes.py
  decodes STA abs/abs,X/abs,Y/zp/zp,X but **NOT `STA (zp),Y` ($91) or ($81)**,
  and the block-fill routine uses (zp),Y **16,929 times**. So "P1/P2 never
  filled" means "no direct or indexed store filled them in this window". The
  ours-vs-Altirra comparison stays valid because BOTH sides share the blind spot.
  ############################################################################

  ############################################################################
  **PHASE-MATCHED ALTIRRA TRACE: THE DIVERGENCE IS $97 (2026-08-15).**
  Captured `alt_late.bin` via `alt._send_command('TRACEFILE <path>')` (the raw
  bridge verb; the Python client has no wrapper) after cold reset + 600 frames:
  **2,753,560 records, 0 lost**, covering frames ~652-1072. This is the first
  Altirra trace that actually executes the $3043 dispatcher, so it is the first
  legitimate comparison against ours.
        at $3053 `lda $97`   Altirra **$97=$00**      ours **$97=$FE**
        -> `bne $3069`        NOT taken               TAKEN
        $BC at $BCEB          **$00 in 420/420**      $FF / $FD
        $3083 $309B $30EA $3E00 $3E12   **NEVER**     all executed
        (both sides DO run $3043 x5, $304F x5, $3053 -- phase-anchored)
  Altirra's $97=$00 keeps it on the harmless $3057 arm and it **never reaches
  $3069 at all**. Ours is $FE (= -2), takes the branch, finds **$A1=$02** (bit 0
  clear, so `lsr`/`bcs $307B` does NOT recover via `inc $97`), and falls into the
  $3083 init whose `$309B dec $BC` starts the whole cascade.
  $97=$FE means **`$3061 dec $97` ran twice**, which fires when
  `lda $3A56 / eor $D6 / beq $3061`, i.e. when **$D6 == $3A56** ($00 at this
  stage). So the trigger is $D6's trajectory through zero.
  **NEXT: why does our $D6 hit $00 when Altirra's does not?** $D6 is FR0+2, an OS
  floating-point scratch byte, and it is `inc`-ed at BOTH $3057 and $306E.

  **REVISED MECHANISM — $FD MATTERS MORE THAN $FF.** `trace_writes.py --range
  00BC 00BC` shows the ONLY stores to $BC are $3E60 ($0E..$00), $5FAB ($00) and
  $B2BB ($00) -- **nothing writes $FD**. It arrives by repeated `dec $BC`; the
  three sites are **$309B, $30EA and $3E12** (the last INSIDE the ticker, so the
  ticker drives $BC further down each pass). At $3DE1 `inx / bne $3E0F`, only
  $BC==$FF wraps X to $00 and reaches **$3E00 `inc $C2`**. At $FD it does not --
  so the ticker runs but **$C2 never advances**, which IS the ~12 s spin at $30CC.

  **THREE RETRACTIONS, ALL CAUGHT BEFORE THEY BECAME HARDWARE HYPOTHESES:**
   1. "$3BA6 is the entry point" -- it is an **RTS**; the caller is $3087.
   2. "$3A56-$3A58 differ" -- **NO**; $00 on both until Altirra writes them at
      frames 658-660. My $AF/$5A came from a gameplay-phase peek.
   3. "Altirra never runs the $3043 dispatcher / has different code at $30xx" --
      **NO, a CAPTURE-LENGTH ARTIFACT**: `$3040 jsr $3228` sits at index
      5,881,373 of alt_intro.bin's 6,044,948, so the trace simply ended before
      the `jsr` returned to $3043. Disassembly confirms **identical code**, and
      Altirra walks the same path $3228 -> $316E -> $322D -> $37EA -> $37C4 ->
      $3B61 -> $3B8B (the block fill).
  **BREAKPOINT POLLING IS A WEAK INSTRUMENT HERE** -- `$3043` runs only ~3 times
  per 5M instructions, so a few hundred polled frames miss it and look like
  "never". Validate any bp channel in-run (bp on $E462 DID halt, proving the
  channel works) and prefer TRACEFILE.

  **THE INTRO IS SEEDED FROM POKEY RANDOM.** $301E-$303E reads $D20A four times
  into $A4-$A9 and branches on `$3032 bit RANDOM / bpl`. **That is the source of
  the run-to-run non-determinism** (goalposts appearing on one build, not
  another; hand.bin never running $3083 while multi.bin does). Values read look
  sane on both sides ($39/$01/$7A vs $0A/$5E/$47) but only 3 samples each -- NOT
  enough to judge RANDOM quality. Worth a dedicated comparison.
  ############################################################################

  ############################################################################
  **THE SCENE DISPATCHER, DECODED (2026-08-15) — AND ONE RETRACTION.**
  The block at $3043 is a per-frame state machine, read out of Altirra (the code
  is static and identical at these addresses):
        $3043 lda #$00 / sta $8F,$90,$99,$91
        $304D lda #$01 / cmp $CA / bne $307D
        $3053 lda $97  / bne $3069
        $3057 inc $D6 / lda $3A56 / eor $D6 / beq $3061 / rts
        $3061 dec $97 / jsr $BC53 / jmp $307D
        $3069 lda $A1 / lsr / bcs $307B
        $306E inc $D6 / lda $3A57 / eor $D6 / bpl $307A(rts)
        $3077 jmp $3083            <-- THE INIT
        $307B inc $97
        $307D jsr $30F6 / $3080 jmp $3043      <-- the loop
        $3083 lda #$00 / sta $86 / jsr $37C4 / jsr $37D3 / lda #$0C / sta $8E
        $3091 lda #$FD / sta $82 ... $309B dec $BC
  Confirmed by predecessor histograms: $3077 -> $3083 (x1), $3055 -> $3069 (x1),
  $3293 RTS -> $3080, $3051 -> $307D. In hand.bin the $3083 block NEVER RUNS
  (only $307D/$3080) -- the run-to-run non-determinism is visible inside our own
  machine.

  **RETRACTED, SAME DAY:** "the $3A56-$3A58 scene table is $00 on our board and
  $AF/$5A on Altirra". A COLD-RESET SWEEP shows Altirra's $3A57/$3A58 are $00 for
  at least the first 180 frames too -- the $AF/$5A peek was taken at cycle
  156,591,563, deep in GAMEPLAY. Trap #1 (sample-at-one-moment) again; the sweep
  is the only reason it did not become a hardware hypothesis. **The table is NOT
  a difference.**

  **WHAT THE SWEEP LEAVES INSTEAD — A SHARPER TARGET.** With $3A57 = $00 on both
  machines the gate `lda $3A57 / eor $D6 / bpl` reduces to **"is $D6 bit 7 set?"**
  Altirra $D6=$B3 (set), ours $FF (set) -- BOTH fall through to `jmp $3083`. So
  the divergence is NOT the gate. It is ONE INSTRUCTION LATER:
        **$309B `dec $BC` -- ours $00 -> $FF (wraps, arms the envelope);
          Altirra's $88 -> $87 (no wrap, harmless).**
  Only $FF wraps X at $3DE1. So the whole bug reduces to: **what value does $BC
  hold when $309B executes, and who puts $88 there on Altirra?**
  NEXT: (a) `alt.bp_set(0x3083)` -- does Altirra reach the init at all? (b) find
  the writer of $BC=$88 on Altirra; ours only ever sees $00 there.
  ############################################################################

  ############################################################################
  **$3BA6 IS AN RTS — THE CALLER IS AT $3087 (2026-08-14).** Our executed opcodes
  $3B88-$3BAC:
        $3B8B 85 x11   $3B8D A2 x11
        $3B8F A9 x1056  $3B91 A4 x1056  **$3B93 91 (STA (zp),Y) x16929**
        $3B95 88 x16974  $3B96 10 x16922  $3B98 18 x1058  $3B99 A5 x1058
        $3B9B 69 x1057  $3B9D 85 x1058  $3B9F 90 x1058  $3BA1 E6 x166
        $3BA3 CA x1056  $3BA4 D0 x1059  **$3BA6 60 (RTS) x11**
  So $3BA6 is an **RTS**, and "$3BA6 -> $308A" is the routine RETURNING. The call
  therefore came from **$3087 JSR** (three bytes before $308A), and $3087..$309B
  is ONE LINEAR INIT SEQUENCE, not a branch target.
  The routine itself is a **BLOCK FILL** (`LDA # / LDY zp / STA (zp),Y / DEY /
  BPL`) with **16,929 `STA (zp),Y` executions**, run 11 times -- which also
  accounts for a large share of the `STA (zp),Y` blind spot that defeated the
  earlier writer searches.

  **SO THE QUESTION MOVES UP ONE MORE LEVEL: what reaches $3087?**
   1. Predecessor-histogram **$3087** (and $3070-$3087) in our traces.
   2. `alt.bp_set(0x3087)` from cold reset — does Altirra arrive? If not, keep
      walking back to the last common address.
   3. Because this is a LINEAR init (not a conditional), the divergence is
      whatever CALLS or JUMPS into this block — likely a scene/state dispatcher.
      **If its input is a protection result or loaded data, that connects to
      Simon's semi-crack theory; if it is a hardware register, it is our bug.**
  ############################################################################

  ############################################################################
  **THE ENTRY POINT IS $3BA6 (2026-08-14).** Predecessor histogram across two
  independent captures:
        **$3BA6 -> $308A**   (once in entry.bin, once in multi.bin)
        $308A is `JSR $37D3`; $37D9 -> $308D is its RTS returning
        $308F -> $3091 -> the init -> **$309B dec $BC**
  ($C28F -> $308A also appears once: that is the RTI from the OS NMI handler
  landing mid-sequence, NOT a caller.)
  So the entire chain is entered from **$3BA6**, as a ONE-TIME transition. Note
  `$30A0 JSR $3BEB` sits in the same routine, so $3Bxx is part of this subsystem.

  **THE FINAL QUESTION: what leads to $3BA6, and does ALTIRRA ever execute it?**
   1. Predecessor-histogram $3BA6 (and $3B90-$3BA6) in our traces to get its
      caller and the branch condition.
   2. `alt.bp_set(0x3BA6)` from cold reset — if Altirra never arrives, walk back
      to the last common address and find the diverging branch.
   3. Identify that branch's INPUT. **If it derives from a hardware register we
      emulate, that is the bug.** If it derives from loaded data or a protection
      result, the divergence is upstream in the load/protection path -- which
      would connect back to Simon's original semi-crack theory.
  ############################################################################

  ############################################################################
  **IT ALL RESOLVES: ALTIRRA'S $BC NEVER EQUALS $FF (2026-08-14).** The
  cold-reset sweep already contains the answer -- **$BC takes exactly three values
  there: $00 (x997), $88 (x397), $81 (x6). NEVER $FF.**
  `$3DE1 bne $3E0F` branches on X AFTER `inx`, so **ONLY $BC == $FF wraps X to
  zero and reaches the $BD countdown.** With $BC never $FF, Altirra NEVER ENTERS
  THE ENVELOPE PATH -- which is precisely why its $BD sits static at $B0 while
  ours steps $F0 -> $00.
  **No hardware difference is required to explain any of it.**

  **THE COMPLETE, SELF-CONSISTENT STORY:**
        we run `$3091 LDA #$FD / $3093 STA $82 / $3095 spin / $309B DEC $BC`
        -> $BC $00 -> **$FF** (Altirra never sets $82=$FD, so never runs this)
        -> `$BCED BEQ` falls through -> `$BCEF JMP $3DE0`
        -> `inx` wraps ($FF+1=$00) -> falls into the $BD countdown
        -> envelope runs -> `$3E60 sta $BC` keeps $BC cycling
        -> `inc $C2` only on the rare $FF -> $C2 needs 255 ticks
        -> `$30cc cmp $C2 / bne $30CC` spins ~12 s per scene
        -> scene scheduler + `bit RANDOM` rarely run -> **the man's scene never plays**
  **THE ROOT QUESTION IS NOW SINGULAR: why do WE reach the $309B init and Altirra
  does not?** It is guarded by the spin at `$3095/$3097` waiting for **$82** to be
  counted to zero by something else. Altirra never even sets $82=$FD, so it takes
  a DIFFERENT BRANCH EARLIER.
  **NEXT: find what leads to $3091 on ours, and what Altirra does instead at that
  point.** Predecessor-histogram $3091/$308D in our traces, then check the same
  address on Altirra with bp_set. That branch -- and whatever input decides it --
  is the true divergence, and it is upstream of everything measured tonight.
  ############################################################################

  ############################################################################
  **CORRECTION: ALTIRRA'S $BC IS *NOT* PERMANENTLY $00 (2026-08-14).** A proper
  1400-frame sweep from COLD RESET (the earlier "$00 for 300/300 frames" was a
  single-moment sample, not a sweep -- the same scoping error yet again):
        $82: 20 distinct -- $00 x977, $78 x283, $0F x83, $FF x21 ... **$FD: NEVER**
        $83:  4 distinct -- $00 x769, $A0 x398, $FF x227, $EA x6
        **$BC:  3 distinct -- $00 x997, $88 x397, $81 x6**
  **So $BC is NON-ZERO for ~400 of 1400 frames on Altirra.** Every claim resting
  on "Altirra's $BC is $00 permanently, so `$BCED BEQ` is always taken and it
  never reaches $3DE0" is **UNDERMINED and must be re-derived.**

  **WHAT SURVIVES, AND IT IS SHARPER:**
   * **Altirra NEVER sets $82 = $FD** in 1400 frames, so it genuinely never runs
     the $3091-$309B init sequence. That part stands.
   * **$BC=$88 coincides EXACTLY with $BD=$B0 for the same 397 frames** -- both
     STATIC. Ours actively COUNTS DOWN ($BD stepping $F0 -> $00, 241 distinct).
   * **So the real contrast is STATIC vs COUNTING, not zero vs non-zero.** Altirra
     holds a fixed pair; we run an envelope. Re-frame the whole comparison around
     that.

  **NEXT:** work out what makes Altirra's pair STATIC. If $BC is non-zero there,
  `$BCED BEQ` falls through and it SHOULD reach $3DE0 and decrement $BD -- yet
  $BD does not move. Either (a) it does not actually reach $3DE0 (verify with
  bp_set, not by inference from $BC), or (b) the decrement path is gated further
  in ($3DE1 `bne $3E0F`, which depends on X after `inx`). **Check (a) directly
  before theorising** -- inference from a zero-page value has now misled twice.
  ############################################################################

  ############################################################################
  **$309B IS A DELIBERATE ONE-TIME INIT, NOT A STRAY INSTRUCTION (2026-08-14).**
  Region cross-checked first: our executed opcodes $3088-$30A8 match Altirra
  byte-for-byte EXCEPT $308A, where ours reads $00 -- that is the INTERRUPT-ENTRY
  marker (IR==$00), not a memory difference. So the disassembly is trustworthy:
        $3091  A9 FD     LDA #$FD
        $3093  85 82     STA $82          ; arm a counter with $FD
        $3095  A5 82     LDA $82          <- **3196 executions**
        $3097  D0 FC     BNE $3095        <- **SPIN until $82 reaches $00**
        $3099  C6 83     DEC $83
        **$309B  C6 BC     DEC $BC**        <- the bootstrap ($00 -> $FF)
        $309D  20 53 BC  JSR $BC53
        $30A0  20 EB 3B  JSR $3BEB
        $30A3  20 C4 37  JSR $37C4
  So this is a DELIBERATE INIT SEQUENCE: set $82=$FD, spin until an interrupt
  counts it to zero, then `dec $83` and `dec $BC`. With $BC at $00 that `dec`
  INTENTIONALLY yields $FF, arming the sound engine. **We are not executing a
  wrong instruction -- we are executing the RIGHT one.**

  **SO THE DIVERGENCE INVERTS AGAIN: ALTIRRA APPARENTLY NEVER REACHES THIS INIT**
  (its $BC stays $00 forever). The question is no longer "why do we run $309B"
  but **"why does the REFERENCE not run it -- or run it at a different time?"**
  NEXT:
   1. `alt.bp_set(0x309B)` (or watch $82/$83) and run a full intro from cold
      reset -- does Altirra EVER reach $309B? If it does, WHEN, and what is $BC
      at that moment?
   2. Note the spin at $3095/$3097 (3196 iterations) waits for **$82** to be
      decremented to zero BY SOMETHING ELSE -- find that decrementer; if it is
      interrupt-driven, its rate decides when this init completes on each machine.
   3. Consider that BOTH may be correct and simply at different points: Simon's
      run is non-deterministic. The music question ("does the intro have music?")
      would disambiguate cheaply.
  ############################################################################

  ############################################################################
  **THE LOOP CLOSES — ROOT CAUSE CANDIDATE IS `$309B dec $BC` WRAPPING $00 -> $FF
  (2026-08-14).** Predecessor analysis shows the sound engine is reached ONLY from
  inside the VBI, and the whole path is gated by $BC:
        $BCEF -> $3DE0   (281 / 260)      $3DE1 -> $3E0F  (227 / 241)
        $3E10 -> $3E35   (226 / 240)      $3E41 -> $3E43  (227 / 241)
  `$BCEF JMP $3DE0` is reached ONLY when **`$BCED BEQ $BCF2` FALLS THROUGH**, i.e.
  when **$BC != $00**.

  **ON ALTIRRA $BC = $00 PERMANENTLY -> the BEQ is ALWAYS taken -> it NEVER
  reaches $3DE0 -> its $BD never counts down.** That single gate explains the
  entire observed difference, including the cold-reset sweep (3 distinct $BD
  values in 1400 frames).

  **THE PATH IS SELF-SUSTAINING ONCE STARTED:** $BC != $00 -> run the sound engine
  -> `$3E60 sta $BC` keeps writing $BC -> stays non-zero. So the real question is
  the BOOTSTRAP: **what first made $BC non-zero on our machine?**
  **AND THE WATCHPOINT ALREADY ANSWERED IT: `$309B dec $BC` executed while $BC was
  $00, wrapping it to $FF** (halt at PC=$309D, A=$00 X=$00 Y=$FF, icnt
  14,170,324). `dec` of $00 yields $FF -- exactly the phase-2 value observed.

  **SO THE ROOT-CAUSE CANDIDATE IS: OUR MACHINE EXECUTES `$309B dec $BC` WHEN THE
  REFERENCE DOES NOT** (or does not with $BC==$00). Everything downstream --
  sound engine running, $BC cycling, $C2 ticking slowly, the $30CC wait, scene
  pacing, the man never appearing -- follows from that one instruction.
  **NEXT:**
   1. Find what calls/branches to $309B: predecessor histogram around $3090-$30A0
      in our traces, and what condition leads there.
   2. Check whether Altirra ever executes $309B (bp_set at $309B, or watch $BC).
   3. Identify the input to that branch -- if it derives from a hardware register
      we emulate, THAT is the bug. This is the first candidate all night that
      explains every downstream observation from a single divergence.
  ############################################################################

  ############################################################################
  **REINSTATED ON PROPER EVIDENCE: OUR ENVELOPE COUNTS DOWN, ALTIRRA'S DOES NOT
  (2026-08-14).** Sweeping Altirra from COLD RESET for **1400 frames (~23 s,
  covering the whole load AND intro)**, polling $BD every frame:
        **distinct values: 3 -> $00 x997, $B0 x397, $3D x6**
        (first non-zero at frame 0; $B0 held for ~400 frames, then $00)
  **Altirra's $BD DOES NOT COUNT DOWN.** Ours takes **241 DISTINCT values** in a
  single 4 s window, stepping monotonically $F0 -> $00.

  **THIS IS NOT PHASE MISMATCH.** A full sweep from cold reset across the entire
  load and intro shows the reference NEVER runs the countdown, so it cannot be
  "we caught ours mid-envelope and Altirra after". The previous entry's
  withdrawal was correct to demand this sweep; the sweep now REINSTATES the
  divergence on evidence that sampling cannot explain away.

  **SO: `$3E58 dec $BD` RUNS ON OURS AND EFFECTIVELY NOT ON ALTIRRA.** The sound
  routine containing it ($3E43-$3E6A, writing AUDF1-AUDF4 and AUDC2) is being
  entered on our machine when the reference does not enter it -- or enters it far
  less. That extra activity is what drives $BC, which drives $C2, which paces the
  intro.

  **NEXT: FIND WHO CALLS THE $3E43 ROUTINE AND WHY IT RUNS HERE.**
   1. In our traces, histogram the PCs that lead INTO $3E43/$3E48 (predecessor
      analysis) -- that names the caller.
   2. Then check whether Altirra executes that caller at all (bp_set or a $BD
      watch equivalent), and what gates it.
   3. Suspect a hardware-register read feeding the decision (POKEY/PIA/GTIA). If
      the trigger derives from something we emulate, THAT is our bug.
   Note Altirra's $B0 -> $00 with only 3 distinct values suggests IT sets $BD
   directly to a value and clears it, never stepping -- a different code path
   entirely, not merely a slower one.
  ############################################################################

  ############################################################################
  **CORRECTION — "WE DO EXTRA WORK" IS PROBABLY PHASE MISMATCH (2026-08-14).**
  Scanning $BD's read sequence for UPWARD jumps (reload points) in entry.bin:
        **UPWARD jumps: 0.** 241 samples, 241 distinct, strictly DESCENDING
        $F0 -> $00 -- i.e. **exactly ONE COMPLETE ENVELOPE**, ending at $00, with
        the 15 below-$0F samples being its fade-out tail.
  So the envelope RUNS ONCE AND STOPS AT $00, which is **exactly the state Altirra
  is in** ($BD=$00 for 300/300 frames). Altirra is therefore most likely PAST an
  envelope that we happened to capture DURING.

  **THE PREVIOUS ENTRY'S CONCLUSION ("our envelope runs, Altirra's does not, so we
  do extra work") IS WITHDRAWN AS UNPROVEN.** It is the same phase-mismatch trap
  that produced most of tonight's retractions, now recurring one level deeper on
  a variable rather than a window.

  **TO SETTLE IT PROPERLY, ALIGN ON THE ENVELOPE ITSELF, NOT ON WALL-CLOCK:**
   1. On Altirra, drive it BACKWARD/FORWARD to a moment when $BD is NON-ZERO
      (cold_reset then step frames while polling $BD until it moves), then measure
      ITS steps/frame. Comparing a running envelope against a finished one proves
      nothing.
   2. If Altirra's $BD NEVER becomes non-zero across a full intro, THEN the
      "extra note" claim is real -- but that needs a sweep, not a single 300-frame
      sample at one arbitrary moment.
   3. Equally, check whether OUR envelope RESTARTS (a second descent later in a
      longer capture). If ours restarts and Altirra's does not, that is the
      divergence; if both run once, there is none here.
  **AND ASK SIMON: does the intro have music?** One listen settles which machine
  is behaving.
  ############################################################################

  ############################################################################
  **DECISIVE, AND IT INVERTS THE ASSUMPTION: ALTIRRA'S ENVELOPE IS NOT RUNNING
  AT ALL (2026-08-14).** Peeking Altirra's $BD every frame for 300 frames at the
  intro scene (PC=$37df):
        **distinct values = 1, all $00. Changes: 0. -> 0.00 steps/frame
         (OURS: ~0.81 steps/frame). Below $0F: 100% (ours 0.4%).**
  Five seconds with ZERO movement, against a note length of ~4 s -- so this is not
  "between notes", the envelope is genuinely IDLE there.

  **SO THE DIVERGENCE RUNS THE OPPOSITE WAY FROM THE WORKING ASSUMPTION: WE ARE
  DOING EXTRA WORK, NOT TOO LITTLE.** Our machine runs a sound envelope during the
  intro that Altirra does not. Because ours is active, `$3E60 sta $BC` fires,
  which engages the ENTIRE $BC -> $C2 -> $30CC chain -- a path Altirra never
  enters at all (exactly consistent with its $BC being $00 for 300/300 frames).

  **THE TARGET IS NOW: WHY IS OUR SOUND ENGINE PLAYING A NOTE HERE AT ALL?**
   1. Find what STARTS the envelope -- who writes $BD with $F0? Search our traces
      for a store of $F0 to $BD (and note $3E14 `lda #$F9` / $3E16 `sta zp` nearby,
      which looks like a sibling initialiser). A `6502 watch 0x00BD w` armed early
      will name it directly.
   2. Then ask why that trigger fires on ours and not on Altirra -- is it a
      keyboard/console read, a collision, a POKEY status read, or a timer? If it
      derives from a hardware register we emulate, THAT is our bug.
   3. Sanity-check the premise both ways: is it OURS that is wrong (spurious note)
      or ALTIRRA that is silent (e.g. its music never started because it took a
      different branch earlier)? Simon can settle it instantly by ear -- **does the
      intro have music on the real thing?** Worth asking him in the morning.
  ############################################################################

  ############################################################################
  **$BD IS A 240-STEP NOTE ENVELOPE — THE INTRO IS MUSIC-PACED (2026-08-14).**
  Histogramming A at `$3E5A lda $BD`:
        bbt.bin:   227 samples, **227 DISTINCT values**, running $F0, $EF, $EE,
                   $ED, $EC, ... -- a MONOTONIC COUNTDOWN. Below $0F: **1 (0.4%)**
        entry.bin: 241 samples, 241 distinct, below $0F: 15 (6.2%)
  So $BD counts down from **$F0 (240)** one step per call (~0.81/frame), taking
  ~240 frames ~= **4 SECONDS** to fall below $0F. Only in that final stretch does
  `$3e60 sta $BC` run, writing $0E..$00 -- **the decaying VOLUME nibble into
  AUDC2** (`ora #$A0`).

  **THIS IS A NOTE ENVELOPE.** A ~4 s tone whose last ~15 frames fade out. $BC is
  non-zero only during the fade, and $BC==$FF (needed for `inc $C2`) requires a
  `dec $BC` exactly when $BC has reached $00 -- the very tail of the fade.
  **THEREFORE THE INTRO'S SCENE PACING IS DRIVEN BY THE MUSIC**: roughly one scene
  advance per note. "Once per ~12 s" is two or three notes, not a broken counter.

  **THIS MAY BE CORRECT BEHAVIOUR, NOT A BUG.** Before treating it as a fault,
  establish what the intro is SUPPOSED to sound/look like:
   1. Is our note length right? 240 steps at ~0.81/frame ~= 296 frames ~= 5 s per
      note. Compare against Altirra: measure ITS $BD countdown rate at the same
      scene (peek $BD each frame for ~300 frames). If Altirra's envelope runs
      faster, our notes are too long and everything downstream stretches.
   2. Does Altirra even run this envelope? Its $BC is $00 for 300/300 frames,
      which is consistent with "fade already finished" -- so sample $BD there
      directly rather than inferring from $BC.
   3. If the envelope rates MATCH, then the intro pacing is by design and the real
      bug is elsewhere -- revisit what Simon actually sees (the man never
      appearing) against a correctly-paced reference run.
  ############################################################################

  ############################################################################
  **NO IRQ ANOMALY IN THE INTRO — the sound engine is VBI-driven (2026-08-14).**
  Duration-free rates per VBI ($BC78):
        bbt.bin (PURE intro, 99.3% page $3000): VBI 281, **NMI 1.00/VBI**,
              **IRQ 0.00/VBI (ZERO POKEY timer IRQs)**, envelope dec 0.81/VBI
        entry.bin (mixed/game):                  VBI 541, NMI 3.60, IRQ 8.06,
              envelope 0.45
  **Zero timer IRQs in the intro is CORRECT**, not a fault: Altirra's IRQEN=$20 is
  serial-input only, with all three timer-IRQ enable bits CLEAR. So the sound
  engine is NOT IRQ-driven during the intro -- it is called from the VBI path at
  ~0.81 per frame (the shortfall being VBIs that take another branch).
  This also CONFIRMS INDEPENDENTLY that the intro has **no DLIs** (NMI exactly
  1.00 per VBI), matching the direct NMIST measurement (0/281).

  **SO THE AUDIO INTERRUPT PATH IS EXONERATED for the intro** -- the envelope
  advances about once per frame, as designed. The remaining question is not the
  RATE of the envelope but its VALUE: $BD must fall below $0F for $BC to be
  written at all, and $BC must then be decremented from $00 to $FF for `inc $C2`
  to run. NEXT: measure $BD's distribution the same way $BC was measured (it is
  loaded into A at $3E5A, and A at retire is in every trace record) and compare
  against Altirra at the same scene. If our $BD rarely dips below $0F, find what
  RELOADS $BD -- that is one level further up the same chain and is where the
  divergence must now live.
  ############################################################################

  ############################################################################
  **ANSWERED: $BC IS A SOUND-ENVELOPE VALUE (2026-08-14).** Disassembling the gate
  (region $3DE0-$3E6A is one of the six VERIFIED byte-identical blocks):
        $3e43 tay
        $3e44 bcs $3E48        $3e46 dec $C1
        $3e48 stx AUDF1 ($D200)   $3e4b sty AUDF3 ($D204)
        $3e4e ldx $BF   $3e50 ldy $C1
        $3e52 stx AUDF2 ($D202)   $3e55 sty AUDF4 ($D206)
        **$3e58 dec $BD          ; envelope counter**
        **$3e5a lda $BD / $3e5c cmp #$0F / $3e5e bcs $3E6A**
        **$3e60 sta $BC          ; $BC = $BD, i.e. $00..$0E**
        $3e62 ora #$A0 / $3e64 sta AUDC2 ($D203) / $3e67 sta AUDC1? / $3e6a rts
  **This whole routine is the SOUND ENGINE** -- it writes AUDF1-AUDF4 and AUDC.
  $BD is an envelope counter decremented every call; once it drops below $0F it
  is used as the VOLUME nibble (ORA #$A0 -> AUDC2) **and copied into $BC**.

  **SO THE INTRO'S SCENE PACING IS GATED BY AUDIO ENVELOPE STATE.** $C2 only ticks
  when $BC==$FF, and $BC is only ever written from a decaying sound envelope
  ($00..$0E). That explains why the pacing is erratic and varies between boots.
  NOTE THE TENSION: $BC is written here with $00..$0E, yet the VBI gate needs $FF
  -- so the $FF seen in phase 2 must come from elsewhere (the `dec $BC` sites
  wrapping $00 -> $FF is the obvious candidate: $309B/$30EA decrement $BC, and
  decrementing $00 yields $FF).

  **THAT IS PROBABLY THE WHOLE STORY:** $BC reaches $FF only by a `dec` wrapping
  from $00, i.e. only in a narrow window after the sound engine happens to leave
  $BC at $00. Everything downstream (C2, the $30CC wait, scene scheduling) is
  hostage to that coincidence.
  **NEXT: compare the SOUND ENGINE's behaviour against Altirra** -- AUDF/AUDC
  writes and the $BD envelope rate at the same scene. If our audio timing differs
  (POKEY divider/IRQ rate), the envelope decays at the wrong rate and everything
  above follows. Altirra state seen earlier: AUDCTL=$28, AUDF1=$02, AUDF3=$28,
  IRQEN=$20, SKCTL=$13.
  ############################################################################

  ############################################################################
  **THE DELAYING BRANCH IS $3E5E (2026-08-14) — the reload is gated by a
  threshold compare.** Executed-PC counts for $3E00..$3E70 (bbt.bin / entry.bin):
        $3E58  C6 DEC zp     227 / 241
        $3E5A  A5 LDA zp     227 / 241
        $3E5C  C9 CMP #imm   227 / 241
        **$3E5E  B0 BCS -> $3E6A RTS   taken 226 / 226 times**
        **$3E60  85 STA $BC    1 /  15**   <- reached ONLY when BCS falls through
        $3E6A  60 RTS        227 / 241
  So the $BC reload fires only when a zero-page counter -- decremented at $3E58 --
  drops BELOW the immediate compared at $3E5C. `$3E5E BCS` skips it otherwise.
  (Also note $3E46 `DEC` runs 113 times, about half of 227: a second conditional
  decrement worth understanding.)

  **THIS IS THE LAST LINK.** $BC is reloaded rarely -> $BC sits at $FD -> `inc $C2`
  never runs -> the $30CC wait stalls -> scenes advance ~10x too slowly -> the
  man's scene never plays.
  **RUN-TO-RUN VARIATION IS VISIBLE HERE TOO:** the reload fired 1/227 in one
  capture and 15/241 in another -- the same non-determinism Simon sees on screen.

  **NEXT (small and well-defined):**
   1. Peek the OPERANDS of $3E58 / $3E5A / $3E5C -- WHICH zero-page counter and
      WHAT threshold. $3DE0-$3E6A is one of the six VERIFIED-identical regions
      (192/192), so peeking Altirra is legitimate here; still cross-check the
      opcode against our trace first ($3E58=C6, $3E5A=A5, $3E5C=C9).
   2. Then find who ELSE writes that counter, and compare its behaviour against
      Altirra AT THE SAME SCENE. If the counter advances more slowly on ours, that
      is the divergence -- and it will be one level further up the same chain.
  ############################################################################

  ############################################################################
  **ALL THREE $BC WRITERS CAUGHT IN ONE BOOT — THE MECHANISM IS COMPLETE
  (2026-08-14).** Five arm/hit/resume cycles in a single run (arm, 4 s, read halt
  PC, `watch off`, `go`, repeat) gave three distinct writers IN SEQUENCE:
        PC=$309D  icnt=14,170,324            <- after **$309B `dec $BC`**
        PC=$30EC  icnt=15,724,216  X=$A0     <- after **$30EA `dec $BC`**
        PC=$3E62  icnt=16,670,955  **A=$0E** <- after **$3E60 `sta $BC`** (the reload)
  Cycles 4-5 got no hit and the guest had moved to $81C9/$5ACD (game code), i.e.
  the intro had ended.

  **THIS MATCHES THE PHASE TIMELINE EXACTLY:**
        $BC=$FF -> dec ($309B) -> $FE -> dec ($30EA) -> $FD -> **LONG GAP** ->
        $3E60 writes $0E -> countdown $0E..$00 (one step per VBI)
  So "phase 3, stuck at $FD for 226 reads" is precisely **THE GAP BETWEEN THE
  SECOND DECREMENT AND THE $3E60 RELOAD**, during which $BC != $FF so `inc $C2`
  never runs and the $30CC wait stalls. **All three writers fire; none was
  missing.** (The earlier "nothing writes $BC" was an artifact of analysing a
  single capture in which $309B happened not to run.)

  **THE REMAINING QUESTION IS NARROW: WHY IS THE $3E60 RELOAD LATE?**
  $3E60 sits in the sound routine ($3E00-$3E6A). Between the second `dec` and the
  reload, ~1 M instructions elapse (icnt 15.7 M -> 16.7 M ~= 2 s). Find what gates
  reaching $3E60: walk from $3E00 to $3E60 in a capture and identify the branch
  that delays it, and compare that branch's input against Altirra. NOTE Altirra
  holds $BC=$00 permanently and never runs this path, so compare CODE and
  CONDITIONS, not values.
  ############################################################################

  ############################################################################
  **WATCHPOINT FIRED — THERE *IS* A STORE. READ-PATH HYPOTHESIS DROPPED
  (2026-08-14).** `6502 watch 0x00BC w` armed at PC=$3B21 (icnt=9,073,734) halted
  at:
        **PC=$309D  A=$00 X=$00 Y=$FF  icnt=14,170,324   wp_seen=1 wp_hit=1**
  $309D is the instruction AFTER **`$309B dec $BC`** -- one of the three known
  `dec $BC` sites. **So a real CPU store writes $BC, and OUR MEMORY SYSTEM IS NOT
  IMPLICATED.** Drop the read-path theory. Guest verified running afterwards
  (PC=$30C9, icnt 14,384,369).

  **WHY THE TRACE ANALYSIS MISSED IT:** $309B executed **ZERO** times in
  entry.bin (counted directly) yet fires in this run. That is the SAME run-to-run
  timing sensitivity Simon saw with the goalposts appearing on one build and not
  another. **I was analysing a capture in which that writer never ran**, so the
  $00 -> $FF transition in entry.bin has a different explanation from the one the
  watchpoint just caught -- or my window identification was wrong for that file.

  **LESSON (the deepest one tonight): DO NOT GENERALISE FROM A SINGLE CAPTURE OF A
  NON-DETERMINISTIC RUN.** Every "exhaustive" scan I did was exhaustive only over
  ONE recording of a system whose behaviour varies between boots. Confirm any
  "nothing does X" claim across SEVERAL captures, or on live hardware.
  NEXT: re-run the watchpoint two or three more times to see whether $309B is the
  consistent writer, and count $309B/$30EA/$3E12 across several fresh captures to
  characterise which decrementer actually dominates.
  ############################################################################

  ############################################################################
  **DECODE FLAW IS REAL BUT DOES NOT EXPLAIN IT — READ-PATH HYPOTHESIS
  STRENGTHENED (2026-08-14).** Comparing OUR trace opcodes against Altirra byte
  by byte at every store site in the window:
        $3D4A/$3D4C/$3D4E  85 = 85   MATCH        $3803/$3808/$3822  85 = 85  MATCH
        $BD59/$BD5E/$BD65/$BD6A  8D = 8D  MATCH
        **$C026  ours=8D (STA abs)   altirra=86 (STX zp)   MISMATCH**
  Only $C026 differs, and it is in the OS ROM where the builds are KNOWN to differ
  (our vectors $C018/$C02C vs Altirra's $C18E/$C1A2). So operands decoded there
  were indeed garbage -- the concern was justified.
  **BUT IT IS NOT THE WRITER.** Our own ROM image (sim/atari_xl_rom.mem) gives
  $C018.. = `2C 0F D4 10 03 6C 00 02 D8 48 8A 48 98 48 8D 0F`, so $C026 = 8D with
  operand starting $0F -> **`STA $D40F`** (NMIRES, the NMI handler clearing
  NMIST). Not $BC.

  So EVERY store in the transition window is now accounted for with OUR-side
  opcodes, and NONE writes $BC -- while $BC demonstrably reads $00 before and $FF
  after (idx 1,905,889 -> 1,915,203, confirmed across both read sites).
  **THAT PUSHES THE WEIGHT ONTO THE READ-PATH HYPOTHESIS: `LDX $BC` returning a
  value no store produced.** If true this is OUR MEMORY SYSTEM, far more serious
  than the intro, and it would undermine the $BC histogram and phase timeline
  (both built on reads).
  **NEXT, AND DECIDE IT ON HARDWARE:** arm `6502 watch 0x00BC w` to halt inside
  the window (~18-22 s after xlboot; confirm the armed PC is $3xxx), then read the
  halt PC. **If the watchpoint DOES fire, a store exists that the trace analysis
  missed -- find out why. If it does NOT fire while $BC still changes value, the
  read path is confirmed broken and that becomes the headline bug.**
  ############################################################################

  ############################################################################
  **THE TRANSITION IS CONFIRMED, AND THE LIKELY FLAW IS AN UNVERIFIED OPERAND
  DECODE (2026-08-14).** All $BC reads across BOTH read sites ($BCEB `LDX $BC`
  and $30EF `LDA $BC`, 1024 reads total) bracket the change cleanly:
        idx 1,900,194 $00   idx 1,905,889 $00   idx 1,915,203 $FF   idx 1,921,305 $FF
  So the change really does happen inside the window that the exhaustive
  memory-write scan says contains no write to $BC.

  **BUT THE OPERANDS IN THAT SCAN WERE PEEKED FROM ALTIRRA, AND NOT ALL OF THOSE
  PC REGIONS WERE EVER VERIFIED TO MATCH OURS.** Verified regions were the six
  intro blocks (192/192) -- which cover $37FC-$3854, hence the $38xx stores -- and
  $BCxx. **NOT verified: $3D4A/$3D4C/$3D4E, $BD59-$BD6A, $C026.** If Altirra's
  bytes differ at any of those, the operand read is WRONG and a store that really
  targets $BC would appear to target something else. That is the cross-machine
  trap one level deeper: it was applied to DECODING, not just to reading state.

  **NEXT: RE-DECODE THE GAP WITHOUT ALTIRRA.** For each store site in the window,
  recover the operand from OUR OWN trace instead: the operand bytes are not in the
  trace, BUT the instruction LENGTH is implied by the PC delta (next_pc - pc), and
  for a 3-byte store the target can often be pinned by correlating with the value
  that later appears in $BC. Failing that, use `6502 watch 0x00BC w` armed to halt
  exactly in this window (sleep tuned so the arm lands before idx ~1.9 M) and read
  the halt PC -- that names the writer with NO cross-machine assumption at all.
  **RULE: never decode an operand from another machine's memory unless that exact
  region has been proven byte-identical.**
  ############################################################################

  ############################################################################
  **EXHAUSTIVE SCAN: NOTHING IN THE GAP WRITES $BC (2026-08-14).** Opcode set
  built MECHANICALLY this time -- every 6502 instruction that writes memory, in
  every addressing mode: STA/STX/STY (zp, zp,X/Y, abs, abs,X/Y, (zp,X), (zp),Y)
  PLUS the read-modify-writes INC/DEC/ASL/LSR/ROL/ROR in all their memory forms.
  Over idx 1,905,889..1,915,204 the writes go to:
        $94 $93 $95 $8F $90 $8D $8E $92 $C6 $C7 $C8 $9D $B4 and POKEY $D200-$D203
  **NOT ONE targets $BC.**

  So either (a) the gap boundaries are wrong, or (b) **THE VALUE CHANGE IS NOT
  CAUSED BY A CPU STORE** -- which would mean `LDX $BC` READ BACK $FF where memory
  holds $00, i.e. a READ-PATH bug on our side. That is a materially different
  hypothesis from anything chased so far and would sit in OUR memory system, not
  in the game.

  **NEXT, IN ORDER:**
   1. **Re-derive the boundaries carefully.** The timeline compressed CONSECUTIVE
      EQUAL events, so "read $00 x281" spans idx 2,888..1,905,889 -- confirm the
      last-$00 index by walking events, not by re-scanning with a separate loop,
      and confirm no $BC read sits between it and 1,915,203.
   2. **Test the read-path hypothesis directly:** does a zero-page read ever
      return a value that no store produced? Compare $BC's read values against
      the last value actually stored to it across a whole capture. If reads
      disagree with the last write, that is OUR bug and a big one.
   3. Only then consider exotic causes (stack/DMA aliasing).
  Note this also re-opens whether "$BC" is even the right variable -- if the read
  path is suspect, the X histogram at $BCEB inherits that doubt.
  ############################################################################

  ############################################################################
  **AND NO INDEXED STORE EITHER — THE MODE I MISSED IS `STA abs` TO A ZERO-PAGE
  ADDRESS (2026-08-14).** Re-scanning the same 9,314-instruction gap for $9D
  (STA abs,X), $99 (STA abs,Y), $91 (STA (zp),Y) and $81 (STA (zp,X)) gives
  **ZERO executions**. Combined with the 12 zero-page store sites (none targeting
  $BC), $BC apparently changed with no store at all -- which is impossible.

  The gap is NOT a trace discontinuity: entry.bin is three concatenated dtrace
  files of ~1,652,725 entries each, and BOTH indices (1,905,889 and 1,915,203)
  fall inside file 2, so no capture boundary separates them.

  **THE OMITTED MODE IS PLAIN `STA abs` ($8D) WITH OPERAND $00BC.** An absolute
  store to a zero-page address is legal and common, and it was in NEITHER of my
  two scans -- I checked zero-page modes, then indexed modes, and never the
  obvious one. (I had literally just written "enumerate ALL addressing modes" as
  a lesson and then failed to apply it. The rule needs to be MECHANICAL: build the
  candidate opcode set from a table, do not hand-list it.)

  **NEXT — trivial: scan the gap for $8D (and $8E STX abs / $8C STY abs) and keep
  any whose 16-bit operand == $00BC.** Peek the operand from Altirra; the intro
  code matched 192/192 so it is valid there. That should name the writer outright.
  ############################################################################

  ############################################################################
  **THE GAP CONTAINS NO ZERO-PAGE STORE TO $BC (2026-08-14) — so the writer is an
  ABSOLUTE INDEXED store landing in page zero.** The last `$BC==$00` read is at
  idx 1,905,889 and the first `$FF` read at 1,915,203: a gap of only **9,314
  instructions** containing just **12 zero-page store sites**, and peeking every
  one of their operands gives:
        $3D4A->$C6  $3D4C->$C7  $3D4E->$C8  $3803->$93  $3808->$94  $381C->$95
        $3822->$8F  $3828->$90  $382F->$8F  $3845->$8D  $384B->$8E  $3852->$92
  **NOT ONE writes $BC**, and there were ZERO `STA (zp),Y` ($91) in the gap.

  So $BC went $00 -> $FF with no zero-page store touching it. The only remaining
  form is an **ABSOLUTE INDEXED store whose computed target lands in page zero**
  -- e.g. `STA $0000,X` with X=$BC, or `STA $00xx,Y`. A zero-page-opcode scan
  STRUCTURALLY CANNOT SEE THESE, which is why every search so far missed it.
  **NEXT (should finish it): re-scan the 9,314-instruction gap for opcodes $9D
  (STA abs,X) and $99 (STA abs,Y), peek each site's 16-bit base from Altirra, add
  X or Y AT RETIRE, and keep any whose target == $00BC.** That is a tiny search
  over a tiny window and it will name the writer outright.
  (Method note: "no store to X in the gap" was only true of the addressing modes
  I enumerated. Enumerate ALL modes that can reach an address, not just the
  obvious ones.)
  ############################################################################

  ############################################################################
  **THE $00 -> $FF TRANSITION IS NOT AT THE FIRST $FF READ (2026-08-14).**
  Dumping the 40 instructions before the first `$BC==$FF` read (idx 1,915,203 in
  entry.bin) shows NO `sta $BC`. At idx 1,915,193 an `LDA zp` already pulls $FF
  into A, so **$BC was ALREADY $FF before this point** -- the write happened
  earlier, somewhere in the long gap after phase 1's last $00 read.
  The path INTO the read is the ordinary VBI chain:
        $3374 RTS -> $3376 -> $BC8E -> $BC95 -> $BC99 `jsr $BCEB`   (A=$0D throughout)
  NEXT: binary-search the gap. Find the index of the LAST $00 read, then scan
  forward for any store whose target could be $BC -- including INDEXED stores
  (compute base+X/Y at retire) since the plain `sta $BC` sites do not fire here.
  This is the ~52k `STA (zp),Y` blind spot, so an aliasing indexed write is the
  most likely culprit and CANNOT be found by opcode-site search alone.
  ############################################################################

  ############################################################################
  **THE $BC TIMELINE — THE TENSION IS RESOLVED, AND PHASE 3 IS THE BUG
  (2026-08-14).** Walking entry.bin IN EXECUTION ORDER (556 events) instead of
  aggregating:
        idx     2,888   read  $00  x281   <- PHASE 1: ticker SKIPPED ($BCED BEQ)
        idx 1,915,203   read  $FF  x19    <- PHASE 2: ticker RUNS ($FF wraps X)
        idx 2,029,246   read  $FE  x1
        idx 2,033,462   read  $FD  x226   <- **PHASE 3: STUCK, 226 reads, NO WRITES**
        idx 2,978,845   WRITE $0E ... $00 <- PHASE 4: normal countdown, one step
                                             per ~4,180 instructions (= per VBI)
  Both earlier "contradictory" histograms were real -- they were DIFFERENT PHASES.
  Aggregating hid the structure; the timeline shows it immediately.

  **PHASE 4 PROVES THE MACHINERY WORKS**: $BC counts $0E -> $00 one step per frame,
  written by $3E60. **PHASE 3 IS THE FAULT**: $BC reaches $FD by two decrements
  from $FF ($30EA and $3E12, once each) and then **NOTHING WRITES IT for 226
  reads** -- the reload that should follow never comes, so `inc $C2` never runs and
  the $30CC wait stalls.

  **AND PHASE 1 IS THE REFERENCE'S STEADY STATE**: $BC = $00 for 281 reads is
  exactly what Altirra holds PERMANENTLY (300/300 frames). So Altirra stays in
  phase 1 forever, while WE PROGRESS INTO $FF -> $FD AND GET STUCK.

  **NEXT — TWO CONCRETE QUESTIONS:**
   1. What moves us OUT of phase 1 into phase 2 ($BC $00 -> $FF) around
      idx ~1.9 M, when Altirra never leaves phase 1? Find the writer of $FF
      (none of $3E60/$5139/$BF9B wrote it in this window -- so it is an untraced
      store, possibly the `STA (zp),Y` blind spot, or an aliasing write).
   2. In phase 3, what SHOULD have written $BC and did not? Compare against a
      capture that reaches phase 4 promptly.
  This timeline is the single most useful artifact from the night; start here.
  ############################################################################

  ############################################################################
  **THE $BC WRITERS, AND AN UNRESOLVED TENSION (2026-08-14).** memsearch finds
  THREE `sta $BC` sites -- **$3E60, $5139, $BF9B** -- and **NO `lda #$FF / sta $BC`
  (A9 FF 85 BC) anywhere**. Three `dec $BC`: $309B, $30EA, $3E12.
  Which of them actually RUN (counts from our traces):
        $3E60  1 (bbt) / 15 (entry) / 15 (multi)      <- the ONLY writer that runs
        $5139  0 / 0 / 0        $BF9B  0 / 0 / 0
        $309B  0 / 0 / 1        $30EA  1 / 1 / 0      $3E12  1 / 1 / 0
  And the VALUES $3E60 writes (A at retire) are a **DESCENDING SEQUENCE**:
        **$0E, $0D, $0C, $0B, $0A, $09, ...**  (one of each)
  So $BC is a COUNTDOWN loaded around $0E and stepped down -- **it is never
  reloaded to $FF at all**.

  **UNRESOLVED TENSION -- DO NOT PAPER OVER IT.** The X histogram at $BCEB showed
  $BC = $FD x226 / $FF x54 / $FE x1, but $3E60 writes $0E-and-below. Those two
  observations CANNOT both describe the same moment, so they must come from
  DIFFERENT PHASES of the intro. Resolve before building anything on either:
   1. Timestamp both within ONE capture -- walk a single trace in order and record
      ($BC-observed-at-$BCEB, index) alongside (value-written-at-$3E60, index) to
      see how $BC evolves over the window rather than as two aggregates.
   2. Note `$BCED BEQ $BCF2` SKIPS the ticker when $BC==$00, so a countdown that
      reaches 0 stops ticking -- consistent with the stall, but only if $BC is in
      the low range at that time.
   3. The $FD/$FF values may belong to the pre-countdown phase, or to a different
      variable aliasing $BC (the ~52k `STA (zp),Y` blind spot).
  This is the sharpest open thread; everything else about the intro is measured.
  ############################################################################

  ############################################################################
  **THE MECHANISM, EXACT (2026-08-14): $BC DECAYS $FF -> $FE -> $FD AND IS NEVER
  RELOADED.** Counting the decrementers in bbt.bin and entry.bin:
        `$3E12 dec $BC`   **1**        `$30EA dec $BC`   **1**   (both windows)
        $3E0F / $3E10 / $3E35   227 / 241   (the `bne $3E35` is ALWAYS taken)
        $30EC `jsr $3307` 455 / 483    $30EF `lda $BC` 454 / 483
  $BC is decremented only TWICE in a whole window yet READ constantly -- and that
  reconciles the X histogram at $BCEB EXACTLY:
        **$FF x54  ->  $FE x1  ->  $FD x226**
  So $BC STARTS AT $FF, is decremented twice, and then SITS AT $FD.

  While $BC == $FF the ticker ran (54 reads, 53 `inc $C2` -- matches). Once $BC
  reached $FD, **$C2 STOPPED ADVANCING ENTIRELY**, because only $BC==$FF wraps X
  at `$3DE0 inx / bne $3E0F`. **This is NOT a counter cycling too slowly -- it is
  a value that should be RELOADED to $FF and never is.** The wait then only clears
  by some other route, roughly once per 12 s, which is the ~10x slowdown.

  **THE QUESTION IS NOW EXACTLY ONE THING: WHAT SHOULD RELOAD $BC TO $FF, AND WHY
  DOES IT NOT RUN ON OURS?** Note `$3e12 dec $BC` is followed by `$3e14 lda #$F9`,
  so the reload is NOT there. Altirra holds $BC=$00 permanently and never uses
  this path, so it cannot be compared directly -- instead find the CODE that
  writes $FF to $BC (search our traces for `lda #$FF` / `sta $BC` pairs, or
  memsearch Altirra for `A9 FF 85 BC` since $BCxx/intro code matched) and then
  determine why it does not execute here.
  ############################################################################

  ############################################################################
  **$BC WRITE CAUGHT — it is the scheduler's `dec $BC` (2026-08-14).**
  `6502 watch 0x00BC w` armed inside the intro (armed at PC=$BEC3,
  icnt=14,035,200) halted 6 s later at:
        **PC=$30EC  A=$00 X=$A0 Y=$27  icnt=15,440,759   wp_seen=1 wp_hit=1**
  $30EC is the instruction immediately AFTER **`$30EA dec $BC`**, so the write is
  that decrement in the scene scheduler. Guest verified running afterwards.

  **BUT THIS DOES NOT EXPLAIN THE DISTRIBUTION, AND THAT IS THE POINT.** $30EA
  only executes when the wait CLEARS (once per ~12 s), yet $BC reads **$FD on 81%
  of VBIs**. One decrement per scene cannot hold a value there. **SOMETHING ELSE
  IS KEEPING $BC AT $FD, AND THE RELOAD IS STILL UNIDENTIFIED.**
  Candidates to check next, in order:
    * `$3e12 dec $BC` in the sound routine (reached from the VBI) -- count it in
      bbt.bin/entry.bin; if it runs per-VBI it would dominate the distribution.
    * A reload (`lda #$xx / sta $BC`) somewhere not yet traced -- re-arm the watch
      REPEATEDLY (each hit halts, so one hit per boot) and collect several halt
      PCs, not just the first. The first hit is only the first writer, NOT the
      only one.
    * $BC may be a shared/aliased byte written by an indexed store (the ~52k
      `STA (zp),Y` blind spot).
  METHOD NOTE: a single watch hit answers "who wrote it FIRST after arming", not
  "who writes it". To characterise a hot variable, arm/halt/read/resume several
  times across a run and histogram the PCs.
  ############################################################################

  ############################################################################
  **t=24-36 s CAPTURE (2026-08-14): the wait CLEARS, but only ONCE in ~12 s.**
  entry.bin, 4,958,176 entries, page $3000 dominant (2,775,811):
        $30CC `cmp $C2`   53,953        **$30D0 `inc $D6`   1**
        $30C1 / $30C4 / $30C6 / $30C8 / $30CA   **still 0**
        **$30DC `bit RANDOM`   1**
  So the wait is NOT permanent -- it cleared ONCE in ~12 s, and the scene selector
  ran once. That matches Simon's "{smooth anim}{abrupt switch} repeating": scenes
  DO advance, roughly every ~10-20 s instead of every ~1.5 s.

  The entry sequence ($30C1 `jsr $33F2` -> $30C4 -> the $CA wait -> $30CA) is
  STILL outside the window even at t=24 s, and after the wait clears control goes
  to the **$30EC loop** ($30ec jsr $3307 / $30ef lda $BC / $30f1 bne $30EC), NOT
  back through $30CA -- which is why the entry never reappears once passed.

  SO THE ENTRY HAPPENS ONCE, EARLY (before t~24 s, during or just after the load).
  To capture it, trace from BOOT across the load->intro handoff (sleep 14, 18, 20
  with three `dtrace 4` each) and search for $30C1/$30CA. Alternatively set
  `6502 watch 0x00CA w` or a breakpoint-style watch near the transition to halt
  exactly there and read the state.
  KEY REFRAME FOR THE MORNING: the intro is not frozen, it is running ~10x too
  SLOW because $C2 gates each scene and $C2 only advances when $BC passes $FF
  ($BC = $FD 81% of the time on ours; Altirra holds $BC=$00 and never uses this
  path at all).
  ############################################################################

  ############################################################################
  **THE WAIT IS ENTERED BEFORE t=31 s AND NEVER LEFT (2026-08-14).** In bbt.bin
  (t=31-35 s, the pure intro):
        $30CC `cmp $C2`   158,820      $30CE loops back
        **$30CA `lda #$FF`      0**
        **$30C8 / $30C6 / $30C4 / $30C1   0**
  We NEVER execute the code LEADING INTO the wait -- the capture opened while the
  machine was ALREADY SPINNING. So the entry happened BEFORE t=31 s and we never
  escape within the window. The predecessors are not absent, they are OUTSIDE THE
  CAPTURE. (Another window-scoping lesson: a zero count can mean "did not happen"
  OR "happened outside the window" -- distinguish them before concluding.)

  **NEXT: CAPTURE t~26-31 s** (three back-to-back `dtrace 4` from sleep 24 or 26)
  and look for $30C1/$30C4/$30C6/$30C8/$30CA. That window contains the ENTRY into
  the wait. Recover the branch that leads in and the register/flag state at that
  moment, then compare the same decision point against Altirra -- which NEVER
  enters this wait at all ($BC=$00 for 300/300 frames there, so $C2 never
  increments and the wait would be infinite).
  Note $30C6 `cmp $CA / bne $30C6` is a SECOND wait just before it (on $CA), so
  the entry sequence to recover is: whatever calls $30C1 `jsr $33F2` -> $30C4
  `lda #$01` -> the $CA wait -> $30CA `lda #$FF` -> the $C2 wait.
  ############################################################################

  ############################################################################
  **THE COMPARISON, AND IT INVERTS THE PICTURE (2026-08-14).** Altirra's $BC
  peeked every frame for 300 frames at the intro scene:
        **$00 x300 (100%) -- ONE distinct value. $FF fraction: 0.0% (OURS: 19.2%)**
  On Altirra $BC is ALWAYS $00, so `$BCED BEQ $BCF2` is ALWAYS taken, the ticker
  at $3DE0 is NEVER called, and **$C2 NEVER INCREMENTS** -- yet its intro plays
  perfectly (PC=$3aee, in the sprite plotter, animating).

  **THEREFORE $C2 IS NOT THE INTRO'S PACING MECHANISM ON THE REFERENCE AT ALL.**
  If Altirra ever executed `$30cc cmp $C2 / bne $30CC` it would spin FOREVER,
  because nothing would ever advance $C2. It does not spin -- **IT NEVER ENTERS
  THAT WAIT.**

  So the framing flips: the $30CC wait is NOT "running too slowly" on our machine,
  **it is a CODE PATH ALTIRRA NEVER TAKES.** Making $C2 tick faster would be
  fixing the wrong thing. The real question is WHY OUR MACHINE ENTERS THE WAIT AT
  ALL, and $BC is the concrete state divergence: **$00 on Altirra, $FD/$FF on
  ours**.

  NEXT:
   1. Find WHO WRITES $BC on our side and what value/why (`6502 watch 0x00BC w`
      inside the intro -- it HALTS, so read the PC with bare `6502`, then
      `6502 watch off` and `6502 go`). We already know `$30ea dec $BC` and
      `$3e12 dec $BC` decrement it; find the RELOAD.
   2. Work out what decides whether $30CC is reached at all -- walk backwards from
      $30CC in bbt.bin (predecessor histogram) to the branch that leads in, and
      compare that branch's input against Altirra at the same scene.
   3. Treat $BC=$00 vs $FD as the PRIMARY divergence now; everything else tonight
      (DLIs, drive timing, display list, fifth player) was downstream or a detour.
  ############################################################################

  ############################################################################
  **THE DECISION VARIABLE IS ZERO-PAGE $BC (2026-08-14) — the bug is now one
  byte.** Recovered from OUR OWN trace (opcodes A6 / F0 / 4C at $BCEB/$BCED/$BCEF)
  and confirmed against Altirra, whose bytes MATCH (`A6 BC F0 03 4C E0 3D`), so
  $BCxx does agree between the machines:
        $BCEB  A6 BC     **LDX $BC**       ; the decision variable
        $BCED  F0 03     BEQ $BCF2         ; $BC == 0 -> SKIP the ticker entirely
        $BCEF  4C E0 3D  JMP $3DE0         ; else fall into `inx / bne $3E0F`
        $BCF2  C6 B4     DEC $B4
  So the rule is: **$BC == $00 -> no ticker at all; $BC == $FF -> X wraps and
  `inc $C2` runs; any other value -> no tick.** Ours reads **$FD x226 / $FF x54**
  (A is constant $0D throughout). Altirra's $BC currently reads $00, but it is in
  a different scene so that is NOT yet a comparison.

  $BC IS GAME STATE WE HAVE ALREADY SEEN BEING DECREMENTED: `$30ea dec $BC` in
  the intro scheduler ($30e8 dec $9B / $30ea dec $BC / $30ec jsr $3307) and
  `$3e12 dec $BC` in the sound routine. So $C2's tick rate is governed by how $BC
  CYCLES, and $BC must pass through $FF for a tick.

  NEXT, AND THIS SHOULD FINISH IT:
   1. Histogram $BC over time on OUR side -- it is not directly readable, but the
      LDX at $BCEB puts it in X, so the X histogram at $BCEB IS $BC's
      distribution: $FD 81%, $FF 19%. Find WHO RELOADS $BC (who writes $FD?) --
      watch 0x00BC for WRITE during the intro (remember: the watch HALTS; read the
      halt PC, then `6502 watch off` and `6502 go`).
   2. Measure the SAME distribution on ALTIRRA at the same scene (peek $BC each
      frame for ~300 frames and histogram). If Altirra's $BC passes through $FF
      far more often, that gap IS the bug.
   3. Whatever writes $BC is the divergence. If it derives from a hardware
      register we emulate, that is our bug.
  ############################################################################

  ############################################################################
  **X IS NOT A COUNTER -- IT IS A TWO-VALUE DECISION (2026-08-14).** Histogramming
  X at the gate in bbt.bin (the pure intro), taken from the record where the `inx`
  at $3DE0 retires (X there is AFTER the increment):
        X=$FE  x226  (81%)  -> no tick
        **X=$00  x54   (19%)  -> WRAPS, `inc $C2` runs**
        X=$FF  x1
        only THREE distinct values in 281 samples
  So X BEFORE the `inx` is **$FD (226x) or $FF (54x)**. It is NOT a free-running
  counter -- it is SET FRESH each VBI to one of two values, where **$FF means
  "tick" and $FD means "do not"**.

  And the caller is unambiguous: **$BCEF enters $3DE0 all 281 times** (`jsr $BCEB`
  at $BC99 -> $BCEB..$BCEF -> falls into $3DE0).

  **THEREFORE THE DIVERGENCE IS IN THE ROUTINE AT $BCEB, WHICH CHOOSES $FF vs
  $FD, AND WE CHOOSE $FD 81% OF THE TIME.** That is the whole bug reduced to one
  decision. NEXT: recover $BCEB..$BCEF from OUR OWN trace (per-PC opcode map --
  Altirra's memory is NOT reliable for $BCxx) and find WHAT IT TESTS. Then read
  that input on both machines at the same scene. Whatever it reads is the real
  divergence; everything upstream (DLIs, drive timing, the display list) was a
  detour.
  ############################################################################

  ############################################################################
  **THE GATE, FOUND EXACTLY (2026-08-14).** Counting the VBI chain in bbt.bin
  (the pure intro) shows the chain is UNIFORM -- every VBI walks all of it:
        $BC78 281  $BC85 281  $BC87 281  $BC8B 281  $BC8E 281
        $BC95 281  $BC99 281  $BC9C 281      ($BC92 and $BC9F: 0)
  and the shedding happens at the TICKER ENTRY:
        **$3DE0 `inx`            281**   <- every VBI arrives
        **$3DE1 `bne $3E0F`  -> $3E0F 227**  <- 81% turned away (X != 0)
        **$3DE3 `lda $C2`         54**   <- only these fall through (X wrapped to $00)
        $3DFC 54   $3DFE 54   **$3E00 `inc $C2` 53**
  227 + 54 = 281. So `$C2` ONLY advances when **X WRAPS TO ZERO** at $3DE0/$3DE1.

  **THE WHOLE STALL REDUCES TO: X IS NOT WRAPPING OFTEN ENOUGH.** Note `inx`
  alone would wrap once per 256 VBIs, but we see 54 wraps in 281 VBIs (~1 in 5),
  so **X is a SHARED counter written elsewhere** -- that other writer is the state
  to chase, and to compare against Altirra.

  NEXT: (a) find what else writes X before $3DE0 -- walk backwards in the trace
  from each $3DE0 occurrence and histogram the preceding PCs, and recover X's
  value at $3DE0 from the trace (X is in the record at retire) to see the
  distribution. (b) Measure the SAME ratio on Altirra at the same scene: if it
  wraps far more often, the divergence is in whatever feeds X. This is no longer
  an interrupt question at all -- it is about one 6502 register's value.
  ############################################################################

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
