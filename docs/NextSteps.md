# Next Steps / Open Work — consolidated

Single rolled-up list of the open "things to do" scattered across `docs/`.
Grouped by theme, not by source file; each item points back to its source doc.
This is a tracker, so it intentionally carries forward-looking/historical context
(unlike the design docs, which describe only current behaviour).

> HDMI artifacts fixed), so it is not listed below.

---

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
---

## Architecture review (the "tock") — open work

Tracking `docs/Design/architecture-review.md`; landed pieces are in the commit log.
Remaining:
### Immediate Priorities:
- n/a
### Future:
- **Partial-reconfig CPU swap.** RP region confirmed viable at X1Y2 (not the PS
  corner — hard blocks there). Implement: `sally_subsystem` wrapper → exclusive RP
  pblock → DFX static/RM flow → runtime PCAP swap. *(docs/Design/partial-reconfig.md)*
  
- Still open: the **ST compositor plane** (bind enum ST-ready,
  plane not wired); and verify/close the **VDI-workstation leak** (direct `vdi.*` after
  `wintest` draws into a window backing, not the desktop). *(docs/OS/desktop-emulation-windows.md)*

- **§3.1 ACP coherency** (evaluate on GEM/desktop surfaces), 

### Some time, maybe:
- **§3.2 SALLY memory hierarchy → 120 MHz**, 
- **§3.3 HP-port budget doc** — deferred.


---

## HW / RTL bring-up

### Future:
- **Keyboard injection host source** — RTL path is done (GP0 → `$D4CF` → POKEY).
  Remaining: a host-side source + ASCII→KBCODE map. *(likely partly covered by the
  serial `{ }` paste path — verify; src: former docs/TODO.txt)*
- **GPIO LED MIO mapping** — `main.c` LED toggle waits on Z-Turn MIO confirmation.
  *(src: docs/bring-up.md)*

---
## Video / compositor / sprites / textures

- **Banked screen RAM** — dual-bank screen-RAM design ($D5C2/$D5C3/$D5C4, CPU+ANTIC
  caches, copy/reload engines); verify it's disjoint from $D5C0/$D5C1 windows and fits
  the BRAM budget (7010 is tight). *(proposal; src: docs/video/screen-banking.md)*
- **Compositor polish (deferred)** — desktop-window-over-live-window occlusion
  (clip-rect → bitmap override); visible-span-only plane fetch (bandwidth); tear-free
  `front_sel` sampling at the compositor's own frame start; narrow/wide playfield
  `src_w` tracking. *(src: docs/video/video-architecture.md, former docs/TODO.txt)*
- **PL-only test-pattern mux in `plane_compositor`** — build-param gradient/colour-bar
  bypass of plane_fetch reads (old `SCANOUT_TEST_PATTERN` lived only in orphaned
  `fb_scanout.sv`). *(src: docs/bring-up.md)*
- **Palette: PAL/NTSC runtime re-push** — page a non-default reference palette in via
  $D483-$D486 on region switch (bake-in is the default); plus more accurate reference
  tables. *(src: docs/HDMI/palette.md)*
  
### Some time, maybe:
- **Sprite engine — deferred/optional refinements.** Core, HW mouse cursor, H/V flip + 2× scale, Remaining (none currently blocking): palettised sprites, rotation (SW-first),
  blitter→sprite-arena integration. *(src: hdl/sprite_engine.sv, docs/Design/sprite-engine.md)*

- **Texture mapping (tiers)** — T1 affine point-sampled (~1 day) → T2 bilinear
  (+½ day) → T3 textured triangles (+½–1 day) → T4 perspective-correct (several days);
  plus `$D4D0..` TEX_* regs / `CMD=0x08` / `TEX_WRAP` wiring and a texture-cache
  throughput upgrade (2×2 quad reads / BRAM tile cache). *(src: docs/video/texture-mapping.md)*

---

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
- **COVOX-style DMA sample playback** — `pokey_sample_dma` streaming DDR buffers to
  the mixer (8-bit mono + 16-bit stereo, EOS IRQ). *(deferred to M22+; src:
  docs/Design/aux-audio-and-reservations.md)*
- **Analog-audio fidelity (Altirra App. E)** — post-mixer DSP: channel-DAC bit
  weights, non-linear saturation, AC coupling, DC bias. *(skip until a "purist" mode
  is wanted; src: docs/Design/aux-audio-and-reservations.md, docs/Altirra/altirra-pokey-audit.md)*
- **RS-232 via second POKEY** — rear-panel RS-232 off the unused 2nd-POKEY serial
  port: MAX232/SP3232 footprint + 2 peri pads (PCB), `peri_bridge.sv` 2nd serial
  channel + companion software-UART firmware. *(M-serial; src: docs/Design/aux-audio-and-reservations.md)*

---


## Memory / banking (DDR3 banked window — parallel track, not on boot path)

- **Connect `sally_mem`'s AXI master to a real HP port** — hard tied-off today
  (`fpga_xt_top.sv:322-327`); add HP2 on the PS BD, clock it at clk_sally, with the
  AXI4→AXI3 burst-len handling the blitter already does. *(src: former docs/TODO.txt)*
- **Make the code page-cache read-write** — `banked_page_cache` code cache is
  read-only (a code write is a no-op); add dirty-bit write-back on page swap like the
  data cache, or extended code-bank writes silently vanish. *(src: former docs/TODO.txt,
  docs/Design/banked-page-cache.md)*
- **Implement the resident page cache** — `banked_page_cache.sv` (code 16 KB RO→RW +
  data 12 KB RW, demand-fill, dirty write-back), parameter-selectable vs the line
  cache, + `tb_sally_mem` verification. Settle write-miss policy (read-allocate),
  fill (demand), dirty granularity (per-line). *(src: docs/Design/banked-page-cache.md)*
- **Reserve + validate the DDR3 region** — 0x2000_0000 code / 0x2040_0000 data; keep
  PS out of 0x2000_0000-0x207F_FFFF; validate with an explicit $D5C0/$D5C1 bank-switch
  test (boot won't exercise DDR3). *(src: former docs/TODO.txt)*
- **Provisional memory regions not yet wired** — 68k "T" realm (0x1C00_0000), GEM
  heap/asset cache (0x3800_0000), sprite arena (0x3400_0000). *(src: docs/Zynq/memory-map.md)*

---

## SIO / PBI / cartridge / companion MCU

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
  *(design decided 2026-06-26; src: docs/OS/expansion-options.md §7)*
- **Cartridge "run" support** — suppress internal memory on RD4/RD5, drive /S4//S5,
  take read data from the cart, route $D5xx out /CCTL for bank-switching. *(same Tier-B
  work as /MPD shadow; src: docs/OS/expansion-options.md)*

---

## App launch (desktop → XL realm)

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

---

## GEM (VDI + AES) / desktop

- **Wallpaper-backed desktop (drop the solid-blue fill)** — `gem_wm_draw()` fills the
  whole desktop with `wm->desktop_color` (solid blue, `gem/wm.c:262/290`), painting
  over the textured boot wallpaper. Back the WM with the wallpaper surface and erase
  windows *to it* (copy-from-wallpaper) instead of fill-solid. More correct, and it
  stops masking wrong-source/offset bugs (it hid the scaled-blit HW bug — see
  [[hw_test_fidelity_textured_bg]] / §1.5). *(src: this session)*
- **VDI dispatch layer (Phase 1, keystone)** — opcode wire format + 6502-side VDI
  library + N6 DRAW dispatcher + palette expansion + inquiry RPCs. *(highest priority;
  everything depends on it; src: docs/GEM/GEM-implementation.md)*
- **AES layer (Phase 2)** — `Window` class, event queue (HID→N6→6502), dialogs, menu
  bar, file selector, `.RSC` loader. *(after Phase 1; src: GEM-implementation.md)*
- **GEMDOS via FMC RPC (Phase 3)**, **Desktop + sample apps (Phase 4)**, **Polish
  (Phase 5)** — clipboard, drag-drop, file associations, DRAW batching, font-cache,
  multitasking model. *(src: GEM-implementation.md)*
- **VDI op gaps** — define reserved/extended-colour ops ($0xC0-0xFE, RGB-direct
  0xC1-0xCF); N6 form/bitmap cache mgmt; font-ID→`lv_font_t` table; bezier-quality
  (escape 99) mapping; `vr_trnfm` behaviour; multi-plane forms. *(src: docs/GEM/VDI-opcodes.md)*
- **VDI SW primitives (future)** — `v_ellipse`/`v_ellarc`/`v_pieslice` (no HW ellipse);
  `v_fillarea` scanline polygon-fill; monospace line-batching (CMD=0x05); italic shear
  FSM; affine-transform blit for rotated text. *(src: docs/GEM/vdi-sw-implementation.md)*
- **Pre-lock risk mitigation** — inventory the full FreeGEM/EmuTOS VDI op set before
  freezing the wire format; wire one full vertical slice (`v_pline`→PSSI→N6→LVGL→
  screen) + profile fill-rate / FMC RPC roundtrip early; verify xtc stdlib gaps
  (`Array<Window@>`, `weak:` in collections). *(src: GEM-implementation.md)*
- **Open GEM decisions** — font-render boundary (N6-rasterises vs 6502 glyph cache);
  `.RSC` format (reuse ST vs native); VBI 50 Hz-vs-60 Hz tick mismatch; per-frame DRAW
  batching; multitasking model (cooperative vs preemptive). *(src: GEM-implementation.md)*
- **ARM-native xtc GEM client** — lands once the xtc-ARM backend lands. *(src:
  docs/GEM/gem-service-abi.md)*
- **Desktop redraw de-jerk (software-first, ordered)** — (1) GEM rectangle list +
  clipped `WM_REDRAW` (foundation); (2) `wind_scroll(win,dy)` HW backing-store move;
  (3) plane-body-move fast-path. Optional RTL (4): odd-X horizontal lane mux +
  reverse-direction BLOCK_BLIT. *(src: docs/OS/desktop-redraw.md)*

---

## XTOS / OS / boot / fonts / Lua

- **XTOS phases** — P1 GEM-as-C-lib draws via the blitter under FreeRTOS; P2 four-
  surface compositor WM + input/event bus with focus routing; P3 VFS + launcher +
  per-app profiles (SD VFS, image drives, SQLite-on-NAND, trashcan, shell); P4 dynamic
  ELF loader + interface/registry + `ABIVER`; P5 IDE + on-device xtc; P6 cross-core
  source-level debugger. *(src: docs/OS/xtos-vision.md)*
- **Dynamic-loading / syscall ABI / bootstrap (Phase 4 spec)** — uClinux model
  (spawn not fork); 3-tier ABI (`SVC #1` kernel syscalls + registry/ops-table services
  + ELF-dynsym libraries); `ET_DYN` minimal-reloc loader; `init`/pid-1 bootstrap +
  process table; **frozen syscall numbering + `r7`/`svc #1` convention**; MMU-readiness
  rules. Vision P4 now references the `SVC #1` syscall tier. *(src:
  docs/OS/dynamic-loading.md)*
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
  services are for *mounted* filesystems; a kernel buffer/page cache hides per-op cost.
  Caution: a FS service must use the **block-device interface** for storage, not libc
  file I/O, or it recurses back through the VFS. **Staging:** (1) VFS dispatch layer
  (mount table + `fs_ops` vtable, romfs as root, location-agnostic so an op can be a
  direct call or an IPC stub) — *prototyped + working (transparent refactor, zero-copy
  mmap via an `mmap_base` op), then reverted to keep main lean until prioritized*;
  (2) **service framework — the crux:** synchronous IPC requires **blockable
  syscalls**. Today `do_syscall` runs in the `svc #1` handler in SVC mode and can't
  yield (a FreeRTOS block → nested `svc #0` clobbers `lr_svc`/`spsr_svc` — same hazard
  as the `_sbrk` boot path). Fix = restructure the syscall path to run re-entrantly
  (save the client resume state, run the body in System mode with IRQs on so a blocking
  primitive context-switches the client out/back as a normal task); test with a trivial
  `sleep(ms)` syscall *before* layering `svc_register`/`mount`/IPC on top; (3) block
  layer + a real on-disk FS (RAM-disk driver → FAT) + the MMIO/IRQ conduit;
  (4) devfs/ioctl/concurrency polish. *(src: docs/OS/xtos-vision.md P3 VFS; this entry)*
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
- **Reserve-now (cheap to bake in early, expensive to retrofit)** — xtc PIC/relocatable
  ARM codegen; service-call indirection via interface tables (never globals);
  interface/registry + `ABIVER` from day one; directory-mapped drives as a first-class
  VFS mode; xtc restricted-DWARF debug-info emission for all 3 backends; **`xtld`
  library resolution via a search path (not a hardcoded dir)** — enables the speed/debug
  library swap above. *(src: docs/OS/xtos-vision.md)*
- **Open XTOS decisions** — none outstanding (DWARF subset now written:
  docs/OS/dwarf-subset.md). *(DECIDED: memory protection = tier 2; debug = full
  backtrace+unwind, all 3 backends, debug-build frames; libc = newlib; front GEM
  plane = NOT building (close the emulator to run a GEM app full-desktop); boot =
  SD-only (NAND holds the registry); **system language = xtc** (C deps
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

## Multitasking / self-hosting / compiler

- **xtc ARM back-end (`XTARMLowering`)** — the critical missing compiler piece
  (~3,000 lines); gates ARM-native apps, the dynamic loader, and the GEM ARM client.
  Target = **Cortex-A9 / ARMv7-A / AArch32** (port *from* the arm64 backend — a real
  ISA change, not a tweak). Consolidated port requirements (C-ABI/newlib interop,
  PIC/ET_DYN minimal-reloc, `svc #1` syscall stubs, ARC + unmanaged subset, DWARF +
  full backtrace) in **docs/OS/xtc-on-arm9.md**. *(Phase 1; immediate next step if
  greenlit; src: docs/MultiTasking/self-hosting.md, docs/OS/xtc-on-arm9.md)*
- **Port stdlib file I/O to the Zynq side** — SD/FAT32 driver via FreeRTOS exposed as
  a trap class (<200 lines). Then write `xtc.xt` in xtc (self-host bootstrap), feature
  parity (`-O1/2/3`, self-hosted 6502 back-end), benchmark a parse on the Zynq first.
  *(src: docs/MultiTasking/self-hosting.md)*
- **6502 (SALLY) multitasking kernel** — scheduler + loader + syscall/BRK handler +
  GEMDOS proxy (~10-14 days; HW foundations exist). v1 stubs MiNT signals to ENOSYS
  except kill/wait/exit; true memory protection needs a fabric MPU (~1500 LUTs, no
  exception model today). *(src: docs/MultiTasking/multitasking.md)*
- **SALLY tasking HW (decide early)** — SP_BANK/ZP_BANK per-task registers (~50 LUTs,
  fmax-neutral); optional tick IRQ + atomic CAS (preemption); HW context-switch
  instruction (~100 LUTs); wider 11-bit SP + stack-relative addressing (fmax-risky,
  needs xtc compiler hooks); cheap IRQ auto-push A/X/Y. *(src: docs/GEM/GEM-implementation.md,
  docs/MultiTasking/banked-stack-context-switch.md)*
- **ARM-A9 dynamic ELF loading** — feasible (~1-2 weeks) but deferred until a concrete
  ARM user-app use case; main risk is `-fPIE` `r9` PIC ABI vs the FreeRTOS BSP. *(src:
  docs/MultiTasking/multitasking.md)*
- **m68k EmuTOS/MiNT port** — ~480-line board-support port; blocked on the m68k soft-
  core / JIT existing first. *(src: docs/MultiTasking/multitasking.md)*

---

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
      family, so gate any build on `clk_sally` WNS ≥ 0.
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
  - **Recommendation:** (B) is the architecturally correct answer for "swap the CPU while
    the desktop/video stays alive" — *provided* the RP is floorplanned around the
    CPU↔memory critical loop. Sequence it **after** stable illegals land, and only when
    cycle-exact faithful mode is actually wanted.

> See also the parked branch `xt-embellishment-relocate` (opcode relocation to free
> the cc=11 undoc territory; ISA-correct but costs ~150 ps — cherry-pick after fmax
> levers land).

---

## Math coprocessor (A9-offloaded FPU + integer)

- **A9-offloaded math coprocessor** — memory-mapped FPU + integer unit: the 6502
  writes operands into per-task register banks, picks an op, and a spare Cortex-A9
  core does the math (native VFP + libm + integer) and writes the result back.
  Replaces software FP with IEEE-754 single/double + full libm + integer mul/div,
  ~15–100× faster and **flat cost** (a transcendental costs the same as an add).
  Key feature: ops name source/dest slots, so the 6502 offloads whole *expressions*
  rather than one op at a time (the xtc backend targets it as a register machine).
  Same doorbell/mailbox as the GEM service; reuses the hwreg/CDC/GP0 plumbing.
  *(design ready, not built; src: docs/Design/math-coprocessor.md)*

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
