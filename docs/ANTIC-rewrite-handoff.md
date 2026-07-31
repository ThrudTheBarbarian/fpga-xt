# ANTIC/GTIA rewrite — handoff

Branch `fix-antic-nmi-pulse`. The rewrite is **live on hardware as the sole
raster**. Plan and rationale: `docs/ANTIC-rewrite.md`. DMA oracle:
`docs/antic-dma-maps.md`.

## State

26 new modules in `hdl/`, 29 testbenches in `sim/`, all green
(`make -C sim <name>`). Timing closes on every clock.

| | |
|---|---|
| clk_sys WNS | **+0.215 ns** |
| clk_sally / clk_pix | +0.483 / +0.161 |
| Slices | **93%** (was 99.62% before the drops) |

Board: `192.168.192.179` (**use the IP** — mDNS drops out and is not a sign the
board is down). Build: `./vivado/run-valhalla.sh bit` from the **repo root**.
Load: `./vivado/jtag-valhalla.sh reset` then `... load`.

## ACID800: the sweep runs, and where it stands

**32 of 63** at `sallyrst = $06` — level with the legacy baseline (run
`2026-07-29-3`). It was **21** when the sweep first completed.

| value | rdy/steal/NMI | VCOUNT the CPU reads | pass |
|---|---|---|---|
| **`$06`** | legacy timing machine | the timing machine's | **32** |
| `$0A` | the rewrite | the rewrite's | 27 |
| `$0E` | **do not use** — both bits set | incoherent | 14 |

Of the 63: 5 `mod_*` never halt by design and `cpu_65c816` is a probe, so the
achievable ceiling is **57**.

### NEITHER configuration is coherent, and this is the key thing to know

`$06` scores best, but it is **two rasters running out of phase vertically**.
The CPU reads the timing machine's VCOUNT while the picture and the collisions
come from the rewrite's beam, and nothing aligns their line counters.

Measured with a hand-assembled probe (`pmVBL.xex`) doing exactly what ACID's
VBLANK check does — wait VCOUNT 124, park all eight objects overlapping,
HITCLR, wait VCOUNT 0, read M0PL:

```
sallyrst $06   M0PL = $0F     collisions recorded "during vertical blank"
sallyrst $0A   M0PL = $00     correct
```

Same bitstream, same program. So at `$06` every test that syncs on VCOUNT and
then observes the raster is looking at the wrong lines. `$0A` is the coherent
machine and is where the rewrite has to end up — `gtia_collision` passes there
and nowhere else.

### CTRL_RWTUNE: bisect cycle numbers without a bitstream

GP0 `0x328`, four **signed nibble** offsets on exactly the cycle numbers ACID
pins — `[3:0]` NMIST status, `[7:4]` /NMI, `[11:8]` WSYNC release, `[15:12]`
VCOUNT advance. `tune = 0` is the RTL defaults (a sweep confirms it scores
identically). Only meaningful under rewrite authority.

This changes how the remaining timing work is done: a cycle question costs a
register write, not 25 minutes. It found /NMI = 9 in one pass over eight
offsets, and it has already ruled things OUT cheaply — WSYNC release 103 is two
tests worse than 104, so 104 stands.

```
mem -w 0x43C0031C 0x0A      # rewrite authority
mem -w 0x43C00328 0x0011    # status +1, /NMI +1
```

**Read the failure TEXT, not the pass/fail bit** — a test that moves from one
assertion to a later one is progress the boolean hides. That is how the JVB and
collision-window fixes were confirmed.

### What was wrong, and how it was found

Three root causes, all integration rather than the rewrite's raster logic —
every one of the 26 module testbenches was green throughout.

1. **Paravirtual SIO had been riding on math_cop's mailbox**, so dropping the
   maths engine wedged every cold boot spinning at `$CB8A` and no `.xex` would
   load at all. That is why the sweep had never completed and every test came
   back `error`. Fixed by `hdl/xt_sio_mbox.sv`; see
   [[sio_mailbox_decoupled_from_mathcop]] in the memory notes.

2. **`antic_rdata_top` is antic_top's WHOLE-CHIPSET read mux**, not the legacy
   raster's, and `rw_auth_sys` is hardwired to 1 — so every POKEY and PIA read
   was answered by a block that decodes neither. PACTL read `$FF` instead of
   `$3F`, RANDOM read `$FF` so the polys looked frozen, every IRQST poll saw
   "no interrupt". **Nine failures, nothing wrong in the rewrite.**

3. **`$D014` reported PAL on a 262-line NTSC machine.** `antic_vcount` reads
   it, picks 155 as the last VCOUNT of a PAL frame, and waits for a value that
   cannot occur — it did not fail, it *hung*, and scored `na`.

The technique that found (3) is the one to reuse: **run the test by hand and
read the 6502 registers against the `.lst`.** `X=$9B` was 155, which is the PAL
constant, which named the bug in one step. `tools/bmp2text.py` now finds the
character grid instead of assuming it sits at (0,0) — without that the result
screens decoded to nothing, and the assertion text is what makes a failure
diagnosable at all.

## Proven on hardware

- Glyphs render (cursor visible), COLPF2 background correct for hi-res
- Attract-mode colour cycling → the OS VBI is being delivered
- 6502 runs the real XL OS at **~387k instructions/sec** in its idle loop
- `.xex` load + run works end to end (paravirtual SIO serves the boot sectors)
- Cycle stealing measured in sim at 52 held cycles/line with a normal mode E
  playfield, 12 without — exactly 40 fetches + 9 refresh + 1 DL + 2 LMS

## NOT proven — the open work

**Two tests remain behind the legacy baseline**, and both are collision
assertions:

* `antic_addresswrap` — its pass condition is simply `P0PF == $00`, so a single
  spurious collision fails it while the message still blames the display list.
  The DL PC wrap itself is correct: `pc_next = {pc[15:10], pc[9:0] + 1}` is
  applied at all three fetch states (instruction, both LMS operand bytes), so
  an LMS operand straddling a 1K boundary wraps as it should.
* `gtia_collision` — now reaches **"Missing P/M collisions on right at `$DD`"**,
  four assertions further than it used to. `$DD` is the last colour clock GTIA
  compares in and `$DE` is already blank, so the window bound is right, and
  `tb_gtia_stage` T8g/T8g2 and `tb_antic_scanline` T9c both show objects at
  `$DD` colliding correctly **in simulation**. Whatever drops it is above the
  scanline model and needs hardware visibility, not more static reading.

The other 24 real failures are ones the **legacy path fails too** — the
mid-line-register-change cluster this rewrite exists to fix. Nothing has been
attempted on them yet.

Useful shape in the messages: `antic_linebuffering` reads its result back
through collisions and returns a repeating byte (`01010101`, then `04040404`
after later fixes), and `gtia_vdelay` gets `00` from
`p0pf & p2pf & m0pf & m2pf` where its players are DMA-fed and its missiles are
CPU-written. `antic_pm_fetch` was checked closely against this and its address
formula, its walk over disabled objects and its VDELAY bit indices are all
correct, so the P/M suspicion is **not** confirmed — treat those messages as a
lead, not a diagnosis.

### Next steps, in order

1. **antic_wsync — the RMW's missing cycle.** Measured exactly: POKEY's RANDOM
   is a cycle clock, the 9-bit poly's taps are `q[0]^q[5]` (they reproduce the
   test's four asserted values at steps 113/342/569/1253), and our `$1B` is
   step 341 against the required `$0D` at 342. One machine cycle early on the
   read-modify-write; plain STA is already right. Two /RDY shapes are ruled out
   on hardware and recorded in `antic_reg_file.sv` — mid-cycle retiming (moves
   it the wrong way; the fid core samples near the END of its window) and
   `q1|q2` (lengthens the stall but the reading does not move at all). Since
   delaying the release provably does NOT change the measurement, look at the
   CPU side: `xt6502f`'s rdy sampling, or where the RMW's two writes land
   relative to cycle 104.

2. **antic_dlitiming — even is right, odd is one out.** The even count is now
   `$0A` as required (it was `$C3`); only the odd count is wrong, by one. A
   per-line-PARITY effect, which is a much narrower target than it was.

3. **antic_vcount** reads `$02` where `$01` is required at cycle 110 of line 3 —
   before the 111 advance, so by construction it should be right. No advance
   offset fixes it, and a negative WSYNC offset moves it several assertions
   further on, so its alignment depends on where the CPU resumes from WSYNC:
   likely falls out of (1).

4. The remaining ~24 are ones the **legacy path fails too** — the real prize,
   because they lift the score above the baseline. Known shape: five of the
   GTIA P/M tests report `00` at their FIRST sample. That is NOT a broad P/M
   DMA break — a probe with a solid mode-F playfield shows a DMA-fed player and
   a CPU-written one both collide correctly — so it is configuration-specific
   (one-line resolution, missiles, VDELAY, GRACTL gating).

5. Wire in `rsrc/atari-basic.rom` so a `READY` prompt makes regressions obvious.
6. Drop code/data banking (`BANKED_CACHE` in `sally_mem`; validate with
   `make boot`). Authorised, still outstanding.

### Probe .xex files are the sharpest tool here

Hand-assembled, ~60 bytes, no assembler and no bitstream: set the registers,
read ONE register, `JMP` to self, then `6502 break` on the loop and read A/X/Y.
Scratchpad has a dozen (`pm*.xex`, `dli*.xex`, `nx*.xex`, `bank5000.xex`).
They isolated missile 3 dropping at HPOS `$DD`, the 23-scanline frame
displacement, the stuck aperture bit, and the PAL/NTSC hang — each in minutes.

### How to run the sweep

```
cat tools/acid-sweep.sh | ssh BOARD 'cat > /tmp/acid-sweep.sh'
ssh BOARD sh /tmp/acid-sweep.sh          # ~20 min, 63 tests
ssh BOARD cat /tmp/acid-sweep.tsv > local.tsv
```

Use ONE multiplexed ssh connection (`-M -S`) for the whole run: Dropbear
rate-limits after ~30 new connections and the sweep then collapses into `na`.
For the failure text — which is what makes a failure diagnosable — grab the
result screens and decode them:

```
cat tools/acid-shots.sh | ssh BOARD 'cat > /media/6502/acid-shots.sh'
ssh BOARD sh /media/6502/acid-shots.sh <names...>
ssh BOARD tar cf - -C /media/6502/acid-shots . > shots.tar
python3 tools/bmp2text.py shot.bmp
```

`/media/6502/acid-shots` accumulates across sessions and is NOT cleared by the
script, so old prefixed grabs (`b10_`, `tri_`, …) sit alongside new ones —
clear it first or you will read a months-old failure as today's.

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
- `run-valhalla.sh` **exits 0 when synthesis fails.** Same class as the above:
  grep the log for `ERROR:` / `Elaboration failed`, never trust `$?`.
- A block that touches a RAM array **must not carry an asynchronous reset**, or
  it is not a dual-port BRAM template — with `ram_style="block"` Vivado errors
  out (`Unsupported Dual Port Block-RAM template`) rather than falling back.
  Keep the RAM access and the reset-bearing pointer/state in separate
  `always_ff` blocks, as `math_cop` and `screen_bank` do.
