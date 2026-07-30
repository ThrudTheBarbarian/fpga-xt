# ANTIC/GTIA rewrite — handoff

Branch `fix-antic-nmi-pulse`. The rewrite is **live on hardware as the sole
raster**. Plan and rationale: `docs/ANTIC-rewrite.md`. DMA oracle:
`docs/antic-dma-maps.md`.

## State

26 new modules in `hdl/`, 26 testbenches in `sim/`, all green
(`make -C sim <name>`). Timing closes on every clock; a bitstream is built and
loaded.

| | |
|---|---|
| clk_sys WNS | **+0.278 ns** (was −9.707 at first attempt) |
| clk_sally / clk_pix | +0.658 / +0.415 |
| Slices | **94.28%** (was 99.62%) |
| Slice LUTs / Registers | 25,150 / 31,210 |

Board: `192.168.192.179` (**use the IP** — mDNS drops out and is not a sign the
board is down). Build: `./vivado/run-valhalla.sh bit` from the **repo root**.
Load: `./vivado/jtag-valhalla.sh reset` then `... load`.

## Proven on hardware

- Glyphs render (cursor visible), COLPF2 background correct for hi-res
- Attract-mode colour cycling → the OS VBI is being delivered
- 6502 runs the real XL OS at **~387k instructions/sec** in its idle loop
- Cycle stealing measured in sim at 52 held cycles/line with a normal mode E
  playfield, 12 without — exactly 40 fetches + 9 refresh + 1 DL + 2 LMS

## NOT proven — the open work

**The ACID sweep has never completed.** Two problems, not yet separated:

1. The sweep harness crashes the A9 shell (null deref in libc) after 1–2 tests.
   `antic_addresswrap` returned `error`, then it died.
2. After tests run, the 6502 ends up stuck near `$CB8A` with `icnt` *resetting*,
   where a clean boot sits happily at `$C046`–`$C052`. Could be a rewrite bug
   that specific DMACTL/display-list combinations trigger, or the harness
   leaving a halted core behind. **Unresolved.**

Baseline to beat: **32 of 63** on the legacy path (run `2026-07-29-3`).

### Next steps, in order

1. Run **one** ACID test by hand, watching 6502 state — separates "harness is
   fragile" from "rewrite wedges".
2. If it's the rewrite: build the **full-machine sim harness** (OS ROM at $C000
   from `rsrc/atari-xl.rom`, `pokey.sv`, `pia_regs.sv`, cold boot, then inject
   the XEX as `xexload` does). All pieces are in the repo. `sim/tb_acid.sv`
   exists but is **marked NOT VALID** — it runs without an OS, so the framework's
   NMI dispatch is absent and results are meaningless.
3. Wire in `rsrc/atari-basic.rom`. Right now correct and broken look identical
   (blank screen either way); a `READY` prompt makes regressions obvious.
4. Drop code/data banking (`BANKED_CACHE` in `sally_mem` — add a `NONE` branch;
   validate with `make boot`). Authorised, still outstanding. Area only — it is
   in clk_sally which has margin.
5. Widen the playfield past 320 (see `antic_wb_adapt` header for everything that
   has to move with it).

## Where things attach

- `antic_gtia` runs in **clk_sys**, paced by the legacy ANTIC's `phi2` so the two
  stay locked. Memory: **`sally_mem`'s DMA port** (`antic_bram_addr` /
  `scrn_shadow_rdata`) — the real 64K *including ROM*.
- Display: `antic_wb_adapt` → unchanged `antic_writeback`. `rw_auth_sys = 1'b1`
  (forced: the legacy raster is not built, so a mux would boot to a blank screen).
- Timing authority still A/B-able on **`sallyrst[3]`** (rdy/steal/NMI).
- Not built: turbo core (`cpu_sel` tied), `math_cop` (generate), legacy
  compositor (`LEGACY_RASTER` in `antic_top`). Each reversible by one bit.
- `antic_top` is **the whole chipset** — POKEY, PIA, sprite, keyboard all still
  live in it. Only the compositor was gated.

## Facts that cost time to learn

- **The colour of a wrong screen says which stage failed.** COLBK black = no
  playfield at all. COLPF2 blue = playfield rendered, data was zero. In hi-res
  the text background is **COLPF2, not COLBK**.
- **`span / bytes_per_line` is a shift, never a division.** Written as `/` it
  synthesised 22 carry chains and a 17 ns path — the whole of a −9.7 ns violation.
  It is `2^(px_shift−2)`; width cancels out.
- **Never put a distributed RAM in the memory address path.** Reading the stored
  character name combinationally cost 8 ns of mostly routing.
- **Character names are fetched once per mode line, not per scanline**, and a
  multi-row bitmap fetches nothing on later rows. So the scan pointer advances
  once per *mode line*. (From `antic_dmapattern`'s own DMA masks.)
- **WSYNC is a latch whose /RDY trails by one machine cycle, both edges.** DMA
  HALT has no such delay and is unconditional — a write cannot be stalled by
  RDY but can be by HALT. That asymmetry is why SALLY exists.
- **`rdy` is a LEVEL for the fid core** (it paces itself from `phi2_tick`), a
  pulse for turbo. `dma_steal` must be a level too.
- The design is **packing-limited**: dropping a whole 6502 freed 2,494 LUTs and
  **82 slices**; dropping the redundant raster freed 629 slices and closed the
  clock.

## Process traps hit this session

- `ssh BOARD 'sh -s' < script` is **broken** on this board (runs line 1 only) —
  `cat`-push then `sh /tmp/x.sh`. The sweep script's own header recommends the
  broken form. **strace before blaming RTL.**
- The shell's cwd persists between commands — use **absolute paths**. Cost three
  appends to the wrong `Makefile` and one build that silently never ran.
- `grab` captures the GEM plane (6502 window comes out **black**); use
  **`graboverlay`** for anything on the Atari display.
- A `.bit` **is** written even when the timing gate reports FAIL. Check the gate
  output, not the file's existence.
