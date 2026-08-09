# ACID800 on the fidelity core — single-phi2 + the ANTIC timing cluster

Status of the cycle-exact ACID800 work on the **fidelity 6502 core** (`xt6502f`).
Currently **25 / 57 passing** (run `2026-07-23-1` on the dashboard). The
register/DMA/decode bugs are largely closed and the core timing contracts
(cpu_timing, VCOUNT, WSYNC — including INC WSYNC's RMW delay slot) are now
**met on hardware**; this document records the architecture that unblocked
them, the exact hardware contracts, and the precise state of each remaining
failure.

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
- `wsync_gen` (rewritten 2026-07-23, `antic_wsync` + `antic_vcount` both pass):
  the WSYNC latch's **SET is registered to the machine-cycle boundary** (a
  `$D40A` write in cycle K drops the latch at tick K+1; a release on that same
  tick wins and discards the write — clear-beats-set as a true same-edge
  arbitration, which is what the late-INC-straddle needs). /RDY is the **q1
  tap retimed onto the phi2 falling edge** — one cycle behind the latch on
  both edges, changing value mid-cycle because the fid core samples /RDY for
  cycle K at `SUB_COMMIT` ≈ the next tick, where tick-launched edges are
  invisible. The release pulse fires at cycle **104**, landing the resume on
  the 105 contract (anchored by `antic_vcount`; `antic_wsync` itself is
  offset-invariant — its poly clock resynchronises to the release). Writes
  stay /RDY-immune (NMOS: /RDY halts reads only). Shape and release remain
  runtime-sweepable (§4). Cycle model: `tools/wsyncrtl.py`, validated
  byte-exact against a 28-config on-board sweep.
- `antic_raster` VCOUNT: `VCOUNT_INC_CYC` = 111 — `antic_vcount` **and**
  `cpu_timing` both pass with the single value.
- `nmi_gen` DLI/VBI trigger on `cycle_8_pulse`, NMIST registered (set @9), /NMI
  window on the gated event — **matches the cycle-8 contract.** (VBI works,
  validating the path.)

---

## 3. Remaining failures — precise diagnoses

Resolved since this report was first written (kept here because the contracts
live in §2): **cpu_timing** and **antic_vcount** both pass with
`VCOUNT_INC_CYC` = 111, and **antic_wsync** passes with the registered-set
WSYNC latch + q1 mid-retimed /RDY + release-104 (§2). The WSYNC fix's suite
prerequisite is also in: `_testEnd` runs `INC WSYNC`, and a stalled write once
deadlocked the whole machine — writes are now /RDY-immune, so every test
reaches a verdict.

### 3a. DLI cluster — DLI row-state cleared between parse and raster row
`antic_nmist`/`dlitiming`/`pfstarttiming`/`pfstoptiming`/`vscroldli`: DLI
*delivery* works (VBI proves the cycle-8 path; sim `tb_dli_e2e` asserts /NMI
with `nmist=$9F` on the right scanlines). On hardware the dl_parser populates
the per-row DLI state correctly during vblank (row 23 recorded at scanline
248), but by the time the raster reaches the DLI row the state reads **0** —
cleared in between. The only architectural clear path is `start_parse`
(`dl_start_pulse`, fired only at vbi_start), yet one diagnostic build measured
`dl_start` firing mid-frame at scanline 4 and the next build measured zero:
**non-deterministic across builds, sim-clean, passes timing** — a genuine
metastability/glitch fault. Functional `mem`-probe diagnostics are exhausted;
the next step is an **ILA capture** on `dl_start_pulse` / `vbi_start` /
`dli_cnt` / `dl_parser.state` (trigger: `dl_start_pulse && scanline != 248`).
If it is a spurious `dl_start`, gate `start_parse` to the true vblank window
and register the pulse. (An earlier theory — NMIEN bit7 clobbered to `$40` —
was diagnostic error: NMIEN holds `$80` through the DLI phase.)

### 3b. P/M cluster — distinct sub-features, no longer one bug
The old blanket root cause (direct `GRAFP` writes dangling — players rendered
only from DMA) is **fixed**, which is why `gtia_collision` passes. The five
remaining P/M failures are separate sub-features, each reading "Got 00":
`gtia_pmoverlap` (overlap priority), `gtia_pmresize` (SIZEP mid-line resize),
`gtia_vdelay` (VDELAY), `gtia_phantomdma` (phantom DMA), `antic_pmdma`
(P/M DMA fetch). Decode each screen assertion (`tools/bmp2text.py`) and pick
them off individually — do not assume a shared fix. Standing lead for
`antic_pmdma` specifically: the compositor's fetch addressing is verified
correct (`$3408`, `PM_ROW_OFFSET=8`), so its `$00` points at the memory path —
the 6502's write not being visible to ANTIC's read port for `$3300-$37FF`.

### 3c. per-color-clock P/M (architectural)
`pmretrigger`/`psuedomodee`/`hiresbug`/`collision2` need a per-color-clock
horizontal P/M evaluation; the compositor is whole-row-latched. Real rework,
not a cycle tweak.

---

## 4. Measurement tooling

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
  The same register carries the **WSYNC runtime knobs**: `[28:26]` /RDY shape
  mask {latch,q1,q2} (0 = default q1), `[23:20]` signed release offset from
  104, `[14]` combinational fallback, `[15]` disable write immunity — the full
  WSYNC shape space sweeps on hardware with no rebuild.
- **Y-register read** — `Y=$00`/`$80` at `_testEnd` distinguishes pass/fail
  without a readable screen (screens are often garbled — tests leave a non-text
  DLIST).
- **Zero-page result readout over the OVL peek** — while halted at `_testEnd`,
  the test's sampled bytes sit at `$C8-$CD` (d0..d5): `mem 43C00204 800000C8`
  then read `mem 43C00418` (low byte), stepping the address; **always write
  `mem 43C00204 0` afterwards** (the peek hijacks the XL plane). Each wrong
  RANDOM byte decodes to an exact machine-cycle delta (9-bit poly, AUDCTL=$80),
  so a ~30-config shape×offset sweep quantifies itself in under 10 minutes —
  this is what pinned the WSYNC fix.
- **On-board bulk sweep** — `tools/acid-sweep.sh` copied to `/media/6502/` and
  run there (ONE ssh; Dropbear rate-limits connection loops, and piping scripts
  over `ssh sh -s` degrades). Results TSV → `docs/a800/tsv2run.py` →
  `gen.py` regenerates the dashboard. The sweep undercounts (breakpoint
  races); trust an individual `xexload --hold` for any single test's verdict.
- **Screen-assertion decode** — `tools/bmp2text.py` turns a `graboverlay` BMP
  into the exact on-screen assertion text via OS-ROM glyph lookup.
- **Offline cycle models** — `tools/wsyncmodel.py` (the test's machine-cycle
  program + 9-bit poly) and `tools/wsyncrtl.py` (exact wsync_gen RTL + the fid
  core's commit-slot sampling; validated byte-for-byte against hardware).
- **Altirra golden reference** — `~/src/AltirraSDL --headless --bridge`
  (SDL_VIDEO_DRIVER=dummy) + the Python SDK: boot a test XEX, read `$C8-$CD`,
  per-instruction history with cycle counts. Ground truth for any timing
  question — the suite's source comments are NOT (their cycle numbers are
  known-wrong).

---

## 5. Next steps

1. **DLI cluster (5 tests)** — ILA/ChipScope capture of the spurious
   `dl_start`/state-clear (§3a); functional probes are exhausted. See
   `HANDOFF.md` §4A for the exact signal list and trigger.
2. **P/M cluster (5 tests)** — decode each assertion and fix per sub-feature
   (§3b); no shared root cause remains.
3. **Scattered singles** — `antic_vscroll` ("expected 12, got 14", a clean
   off-by-2), `antic_addresswrap`/`antic_dlistwrap` (DL address wrapping),
   `cpu_bugs` (BRK handler edge). `antic_blockednmi` is out of scope —
   Altirra itself fails it (ceiling is 54, not 57).
4. **per-color-clock compositor** — the architectural P/M rework (§3c).

Foundation (single-phi2, VCOUNT@111, the WSYNC latch/RDY model) is committed
and HW-proven; the dashboard (`index.html`, run `2026-07-23-1`) is the
authoritative per-test record.
