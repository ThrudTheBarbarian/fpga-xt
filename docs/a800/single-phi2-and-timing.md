# ACID800 on the fidelity core — single-phi2 + the ANTIC timing cluster

Status of the cycle-exact ACID800 work on the **fidelity 6502 core** (`xt6502f`).
The register/DMA/decode bugs are largely closed; what remains is the
**cycle-exact timing cluster**, and this document records the architecture that
unblocked it, the exact hardware contracts it must meet, and the precise state
of each remaining failure.

---

## 1. single-phi2 — one timing master

**The defect (fixed).** The system had *two* independent phi2 grids:

- ANTIC divides `clk_sys` (133.3 MHz) by 74 → phi2 ≈ 1.80 MHz (its machine-cycle grid).
- The fid core divided `clk_sally` (100 MHz) by 56 → its *own* phi2 ≈ 1.79 MHz.

Two free-running dividers at 555 ns vs 560 ns **slide ~5 ns/cycle with no
resync**. Every ACID contract (DMA steal slots, WSYNC@105, VCOUNT@111, NMI@8) is
a comparison measured against ANTIC's ruler, so a CPU that counts its own
approximation makes all of them approximations. On real hardware there is one
phi2 — ANTIC generates it, SALLY consumes it.

**The fix.** ANTIC is the timing master. `antic_top` exposes its raw phi2 *level*
via a dedicated `(* DONT_TOUCH *)` replicated launch FF; `fpga_xt_top` 2-FF-syncs
that level into `clk_sally` and edge-detects it → `phi2_tick_fid` (replacing the
old `fid_ph_ctr` divider). The fid core already micro-sequences off `phi2_tick`
(`sub` resets on the tick, runs its schedule, holds after `SUB_COMMIT` until the
next tick), so machine cycles become **identical to ANTIC's by construction,
self-correcting every cycle**. FID-CORE ONLY — the turbo core stays free-running.
The crossing is mesochronous (both clocks are outputs of one MMCM, phase-locked
3:4), covered by the async clock-group + a `set_max_delay` on the launch→capture pair.

Schedule fit: ANTIC phi2 ≈ 55.5 `clk_sally`; `SUB_COMMIT = N-3 = 53 < 55.5`, ~2.5
cycles of hold margin. `xt6502f.sv` is untouched.

**Result.** Boots the XL OS on the fid core (HW-verified), and **flipped
`cpu_timing`** — the pure CPU-cycle-count test — proving the grids are now locked.
Real POKEY-serial timing also improved (tests now run to completion and
soft-reset instead of hanging in a POKEY-serial wait).

> The dither option (74/75 → effective 74.5 → 1.7897 MHz, matching real NTSC to
> <0.01%) is separable and deferred; it needs the fixed-period consumer audit
> before enabling.

---

## 2. Exact ANTIC horizontal contracts (the reference)

Scanline = **114 machine cycles, 0-113**. From the Altirra Hardware Reference
Manual (Avery Lee), Fig 6 + the DLI cycle-counting breakdown, cross-checked
against `refs/Antic_Timings.txt`:

| Event | Cycle | Notes |
|---|---|---|
| **WSYNC resume** | **105** | ANTIC takes 1 cycle to halt after `STA WSYNC`; releases on 105. "Looks like 104" but it's 105. |
| **VCOUNT increment** | **~110** | Reflected in reads from ~110; the counter *leads* the physical scanline (which advances at 113). |
| **DLI / VBI /NMI** | **8** | Triggered @8, NMIST status bit set @9, /NMI ack ~@10; 7-cycle NMI seq starts at first insn boundary ≥10. |
| Display-list DMA | 1 | between missile (112) and player |
| Player DMA | 1-5 | missile @112/0; DMACTL P/M change needs ≥2 cycles lead |
| Refresh DMA | 25, +4… | 9 cycles/line |
| Playfield DMA | start 25 (normal) / stop 105 | 106+ suppressed ("virtual DMA"); wide stop @105, narrow @~88; ±1 cyc per +2 HSCROL |

Rule of thumb: *writes* must beat the event cycle; *reads* must follow it.

Our RTL vs the contracts:
- `wsync_gen` releases on `cycle_105_pulse` — **correct target (105).**
- `antic_raster` VCOUNT: leads via `VCOUNT_INC_CYC` (see §3).
- `nmi_gen` DLI/VBI trigger on `cycle_8_pulse`, NMIST registered (set @9), /NMI
  window on the gated event — **matches the cycle-8 contract.** (VBI works,
  validating the path.)

---

## 3. Remaining failures — precise diagnoses

### 3a. VCOUNT / cpu_timing — a 1-cycle read offset
`antic_vcount` passes with VCOUNT incrementing at cycle **110**; `cpu_timing`
passes at **111**. Same CPU, so the two tests read VCOUNT with slightly different
instruction timing and **our read lands 1 cycle off from real hardware for one of
them**. The real value is 110 (Altirra); `cpu_timing` failing there means its
VCOUNT read is 1 cycle early on our core. → Fix the **read-cycle position** (the
`SUB_DATA` latch point relative to the ANTIC cycle) so a single VCOUNT value
satisfies both; don't paper over it by picking 110 vs 111 (that trades the two
tests net-zero — currently held uncommitted at 110).

### 3b. DLI cluster — NMIEN clobbered before the gate
`antic_nmist`/`dlitiming`/`pfstart`/`pfstop`: measured **at the real gate cycle
(8)**, the DLI events fire on the right scanlines but **NMIEN = `$40` at every one
— bit7 clear** — even though the test writes `$C0`. So something resets bit7 to
`$40` (VBI-only) before the DLI line each frame. This is a **value/clobber bug,
not a timing bug** (single-phi2 did not and could not fix it). Next: capture the
`$D40E` write sequence with scanlines (DBG_TB mode 1) to find where `$C0 → $40`
— the XL-OS VBI handler rewriting NMIEN vs the test's own sequence.

> Note: the earlier `dbg_dli_cnt`/probe-mode-3 diagnostic sampled at
> `ar_line_start` (~cycle 0), not the cycle-8 gate. Both now corrected to
> `cycle_8_pulse`; the conclusion (bit7 clear at the DLI) survived the fix.

### 3c. pmdma / P/M DMA-fetch — memory coherency (not the compositor)
`antic_pmdma` + the P/M-fetch family read `$00` for the player shape. The
compositor's address logic is **correct** (fetches `$3408`; `PM_ROW_OFFSET=8` is
right — offset=0 recreates the exact `$00 != $08` failure in `tb_antic_modes`).
The HW `$00` is a **memory-path coherency gap**: the 6502's write to `$3408` isn't
visible to ANTIC's BRAM read port (`sally_mem` dma port / DDR banking / snoop
coverage of `$3300-$37FF`). Fix target is the memory subsystem, not the
compositor. (`tb_cmp_fetch` was buggy — planted the shape at `$3400` — now fixed.)

### 3d. per-color-clock P/M (architectural)
`pmretrigger`/`psuedomodee`/`hiresbug`/`collision2`/`vdelay` need a per-color-clock
horizontal P/M evaluation; the compositor is whole-row-latched. Real rework, not
a cycle tweak.

---

## 4. Measurement tooling (built this session)

- **`xexload --hold`** — arms a breakpoint at the framework's `_testEnd` (`$1D93`),
  inside the load path after the cold-boot so it survives, before driving RUNAD.
  The test halts *at its result*: `6502 status` Y = `$00` pass / `$80` fail, and
  the frozen screen is grab-able (`graboverlay <file>` on the Mac). **Always
  release with `6502 go` + `6502 break off`** — a halted 6502 wedges the desktop.
- **`DBG_TB` probe** (GP0 DEBUG block, keep-able) — captures `{scanline, cycle,
  data}` on a configurable trigger into a 16-entry ring. Modes: 1=`$D4xx` write
  @match, 2=read @match, 3=DLI (@cycle 8, data=NMIEN), 4=VBI, 5=WSYNC, 6=any
  write, 7=every line. Bit [25]=circular (last-16 vs first-16). Registers:
  `DBG_TB_CFG 0x43C00878`, `DBG_TB_STAT 0x87C`, `DBG_TB_CAP 0x880`.
- **Y-register read** — `Y=$00`/`$80` at `_testEnd` distinguishes pass/fail
  without a readable screen (screens are often garbled — tests leave a non-text
  DLIST). Bulk sweep is blocked by Dropbear rate-limiting; use spaced/foreground.

---

## 5. Next steps

1. **VCOUNT/cpu_timing** — pin the 1-cycle read-cycle offset (`SUB_DATA` position);
   then VCOUNT@110 satisfies both. (Flips antic_vcount, keeps cpu_timing.)
2. **DLI cluster** — trace the NMIEN `$C0 → $40` clobber (DBG_TB mode 1 +
   scanlines); likely an OS-VBI or test-sequence interaction → SW fix.
3. **pmdma** — memory-path coherency for `$3300-$37FF` (sally_mem dma / banking).
4. **per-color-clock compositor** — the architectural P/M rework.

Foundation (single-phi2) is committed and HW-proven; the rest is applying the
§2 contracts and the two located bugs above.
