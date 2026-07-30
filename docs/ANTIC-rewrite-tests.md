# ANTIC rewrite — ACID800 test map

Companion to `docs/ANTIC-rewrite.md`. Every ANTIC and GTIA test in the suite,
mapped to the module that must satisfy it, with what it actually checks and what
we already know about it. **Read the row for a module before writing that
module** — the point is that test knowledge shapes the design rather than being
retrofitted afterwards.

Status is from run `2026-07-29-3` (build 99). `PASS` rows are regressions to
protect, not work to do — several were hard-won and are easy to break.

---

## 1. `antic_timing` — counters, DL machine, DMA schedule, interrupts

The spine. Already beam-accurate and carrying most of these; the rewrite must
not regress them.

| Test | Now | What it pins |
|---|---|---|
| `antic_default` | PASS | Register reset values. |
| `antic_vcount` | PASS | VCOUNT increments at cycle 111, not the line boundary. |
| `antic_wsync` | PASS | /RDY release at cycle 104; writes are RDY-immune; the RMW re-arm fires on the FIRST `$D40A` write. Fragile — see `wsync_rmw_rearm`. |
| `antic_nmist` | PASS | NMIST set/clear vs NMIRES; data valid at 39/5. |
| `antic_blockednmi` | PASS | An NMI landing during a genuine BRK's vector fetch is **consumed and lost**. Needs the NMOS penultimate-poll rules in the core. |
| `antic_vscroldli` | PASS | VSCROL's DCTR compare point within the scanline vs DLI delivery. |
| `antic_dlistwrap` | PASS | DL PC advances with a **1K wrap**; JVB parks while DLIs keep firing. |
| `antic_addresswrap` | PASS | Playfield memscan wraps within a **4K page** (low 12 bits). |
| `antic_addrmirror` | PASS | `$D4xx` register mirroring. |
| `antic_vscroll` | PASS | Vertical scrolling. |
| `antic_dlitiming` | **fail** | DLI delivery cycle. **Closed from the CPU side** — recognition depth, both pulse positions, RDY gating and penultimate-poll all move the two sleds *together*, so the split is not in the CPU. Fix belongs in **DLI emission** here. Four probes exist (`tb_fid_raster` progs 1/2/3/9). |
| `antic_dmapattern` | **fail** | The full DMA cycle schedule. Our schedule was verified against the test's own embedded oracle masks at `$3800` and matches for narrow/normal × first/later rows — yet the test still fails, and it **failed under the legacy path too**, so this is not an authority artefact. Re-check refresh slip and the ≥105 virtual-cycle rule. |
| `antic_virtdma` | **fail** | DMA cycles at/after 105 are virtual (no steal). |

**Design notes baked in:** `cold` must clear the whole DL machine, not just
DMACTL/NMIEN — a partially-cleared machine leaks state between programs and
produced fake non-determinism for a whole day (HANDOFF 1n). Keep the LMS operand
as a live memscan pointer; the old design discarded it as "the renderer's
concern", which is why the burst had to re-derive it.

---

## 2. `antic_pf_serial` + mode decode — playfield fetch and unpack

The byte stream exists; the mode decode migrates here from `pack_pair`. **These
are the static-first tests** — most need no CPU.

| Test | Now | What it pins |
|---|---|---|
| `antic_charcontrol` | **fail** | CHACTL blank/invert/reflect. Known failure: `chactl=$00 on mode 2 at row 0: expected $10, got $00` — i.e. **baseline mode-2 rendering is wrong before any CHACTL feature applies**. Fix mode 2 first, then the three CHACTL bits. |
| `antic_hiresbug` | **fail** | The GR.0/GR.8 hi-res quirk: modes 2/3/F display lit pixels as COLPF1 luma over COLPF2 hue, but for **collision and priority** a hi-res pixel counts as **playfield 2**. The remap already exists in `collision_combine` — carry it across. |
| `antic_linebuffering` | **fail** | ANTIC's own line-buffer semantics — directly the thing being rewritten. |
| `antic_hscrolbug` | **fail** | Mid-line HSCROL. Needs the 2-char window (`cur`/`next`) and the `hs_delay = HSCROL[3:1]` playfield-start shift. |
| `antic_pfstarttiming` | **fail** | Mid-line DMACTL width change — when the playfield **starts**. Char modes start 26/18/10 (narrow/normal/wide), bitmap 28/20/12. |
| `antic_pfstoptiming` | **fail** | Mid-line DMACTL change — when the playfield **stops**. Span 96/80/64 by width. |

**Design notes baked in:** playfield start/stop and HSCROL must be evaluated
**per colour clock** against live DMACTL/HSCROL, not sampled once per row — that
is precisely what `pfstarttiming`/`pfstoptiming`/`hscrolbug` are testing and what
the burst cannot express. `pf_nibble` must stay **combinational** from the
shifter: both stages clock on `cc_tick`, so a registered output hands the
consumer the previous colour clock's pixel (caught in `tb_pf_serial`).

---

## 3. `gtia_pm_collide` — players, missiles, collisions

Already walks the beam with per-object shift registers. Three of these are the
reason it exists.

| Test | Now | What it pins |
|---|---|---|
| `gtia_collision` | PASS | Collision latches; **no accumulation during VBLANK** — needs an `active_line` gate, horizontal windowing alone is not enough. Also **authority-sensitive**: it passes on the legacy path and fails under the timing machine, so protect it deliberately. |
| `gtia_pmretrigger` | **fail** | A second HPOS match mid-line **reloads** the shift register and draws the player again. Asserts `p0pl & $06 == $06` — collided with *both* p1 and p2. A positional formula draws once per line and cannot pass. Geometry mirrored in `tb_pm_collide` T3. |
| `gtia_pmresize` | **fail** | Mid-draw SIZEP changes the **advance rate** only; emitted pixels stand and the register continues. Known failure `4x-to-1x failed at index 0: expected $80, got $E0` — the old formula re-indexed the whole shape. |
| `gtia_pmoverlap` | **fail** | Sweeps HPOSP0 across every position checking missile-player collisions (`m0pl`..`m3pl`). Exercises the geometry exhaustively — a good regression once passing. |
| `gtia_collision2` | **fail** | Collisions in the GTIA special modes (9/10/11). |
| `gtia_vdelay` | **fail** | VDELAY picks the previous row's missile/player byte per object. |
| `gtia_phantomdma` | **fail** | P/M DMA fetch behaviour when DMA is disabled mid-frame. |

**Design notes baked in:** the visible window is `X_LO = -28`, `X_HI = 346`, and
it is **load-bearing** — with `GRAFP=$80` an object at HPOS `$22` sits exactly on
the low bound and must register, while `$21` must not. ACID pins both halves
(`tb_pm_collide` T7/T8). Players never collide with themselves (diagonal masked).
HITCLR takes effect at the exact cycle written, and must not disturb the shift
registers.

---

## 4. `gtia_stream` + `color_resolver` — priority and colour

| Test | Now | What it pins |
|---|---|---|
| `gtia_default` | PASS | Register reset values. |
| `gtia_consol` | PASS | CONSOL read/write. |
| `gtia_addrmirror` | error | `$D0xx` mirroring. Currently an `xexload` flake, not a real failure — re-measure. |
| `gtia_psuedomodee` | **fail** | Pseudo mode E — mode F data displayed with mode E's colour interpretation. |
| `gtia_collision2` | **fail** | (see above) — needs the special modes to feed collisions correctly. |

**Design notes baked in:** the `idx_buf` contract is `[3:0]` PF0..PF3 one-hot,
`[7:4]` P|M shared, `[11:8]` M-only so PM5 can strip missiles back out. PRIOR and
the colour registers must be sampled **at the colour clock being resolved** —
`tb_gtia_stream` T3/T5 pin mid-line COLPF and PRIOR changes taking effect from
the next colour clock, which is the whole reason for the streaming path. GTIA
modes 9/10/11 already exist in `color_resolver`; do not re-implement them.

---

## 5. P/M DMA fetch — currently unowned

| Test | Now | What it pins |
|---|---|---|
| `antic_pmdma` | **fail** | Known failure `One-line P0 data bad at line 8: $00 != $08`. Real hardware fetches P/M shapes **early in the line**, so they are available as the beam sweeps. Our shapes arrive during the compose burst, which is why the beam-time engine can only see CPU-written GRAFP/GRAFM. |
| `gtia_phantomdma` | **fail** | Same fetch path, DMA disabled mid-frame. |

**Design note:** hoist the P/M DMA fetch to the start of the line in
`antic_timing`, alongside the DL fetch. Until then the beam-time engine is
limited to the register path, which is enough for retrigger/resize/overlap but
not for these two.

---

## 6. `mod_*` — display-mode modules

`mod_dispmin`, `mod_disp80`, `mod_scroll40`, `mod_options`, `mod_vbxe80` all read
`na` — they are display-only modules that never halt, so the harness cannot
classify them. Not work items; they need a visual check, not a pass/fail.

---

## Ordering implied by this map

1. **`antic_pf_serial` mode decode** — `charcontrol` first (baseline mode 2 is
   wrong *before* CHACTL), then `hiresbug`, then `linebuffering`. Static tests,
   no CPU.
2. **Playfield start/stop/HSCROL** — `pfstarttiming`, `pfstoptiming`,
   `hscrolbug`. Per-colour-clock evaluation is the shared mechanism; do them
   together.
3. **P/M DMA hoist** — unlocks `antic_pmdma` and `gtia_phantomdma`, and lets
   `gtia_pm_collide` see DMA-fetched shapes.
4. **P/M geometry** — `pmretrigger`, `pmresize`, `pmoverlap` (the engine is
   built; these should follow from it).
5. **Special modes** — `psuedomodee`, `collision2`, `vdelay`.
6. **DLI emission** — `dlitiming`, the one known to be raster-side.
7. **DMA schedule** — `dmapattern`, `virtdma`. Hardest and least understood;
   the oracle masks match yet the test fails.

That ordering is roughly cheapest-first and dependency-respecting: static mode
decode needs no CPU, the P/M DMA hoist unblocks two tests plus an engine
limitation, and the two genuinely murky ones (`dmapattern`, `dlitiming`) come
last when the surrounding model is trustworthy.
