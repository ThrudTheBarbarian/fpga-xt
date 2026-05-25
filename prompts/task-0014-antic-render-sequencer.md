# task-0014 — ANTIC native raster *sequencer* (phi2-paced render trigger)

**Status: SPECCED, not built.**  Follow-on to task-0013 (which made the
*heartbeat* phi2-correct and deleted the dead 800×600 display chain).  Re-read
`docs/video-architecture.md` §5.1 — specifically the "Coupled scope" paragraph
— before starting.  Branch context: `video-compositor`.

## Why
task-0013 made ANTIC's VCOUNT / WSYNC / VBI / DLI **cadence** phi2-correct
(`antic_raster` drives `line_start` / `vbi_start` / `atari_row` / `vcount`).
But the render *trigger* — what tells `dl_parser` to parse and `compositor` to
compose — is still a scaffold.  In `antic_top.sv` (~lines 934-945):

```systemverilog
logic [17:0] kick_counter;          // free-running, wraps ~every 256K clk_bus (~12 ms)
kick_counter    <= kick_counter + 18'd1;
dl_start_pulse  <= (kick_counter == 18'h0);      // parse the display list
cmp_start_pulse <= (kick_counter == 18'h00400);  // 1024 cycles later: compose
```

Two problems:
1. **Not raster-locked.**  It's a fixed ~12 ms timer unrelated to the emulated
   frame.  Even though `antic_raster` now produces proper phi2 `vbi_start` /
   `line_start` / `atari_row`, the render still ignores them.  A window appears
   (faster than VBI, hidden by the §3 double buffer) but it is **not frame-
   accurate**.
2. **One compose per kick, not per scanline.**  A single `dl_start` then a
   single `cmp_start` 1024 cycles later → the compositor burst-walks the whole
   frame in one go, decoupled from the beam.

So the *rendered image* is not phi2-correct: mid-frame CPU register writes
(raster colour changes, P/M repositioning) and DLIs do not land on the correct
scanline relative to the CPU.  This is the emulation-timing-sensitive half of
§5.1 that was deliberately deferred from task-0013 (which was scoped as
deletion-only).

## What to build
Replace the `kick_counter` block with a sequencer driven by the existing
`antic_raster` pulses (already wired in `antic_top` as
`vbi_start_pulse_bus` = `ar_vbi_start`, `line_start_pulse_bus` = `ar_line_start`,
`ar_atari_row`):

- **`dl_start` at start of frame (post-VBI)** — fire it from `vbi_start_pulse_bus`.
  `dl_parser` already parses the whole display list into a **192-entry,
  row-indexed meta table** (see `hdl/dl_parser.sv` header: `meta_row` is the
  lookup *index* input; `meta_*` are the looked-up outputs).  So a single parse
  per frame is the right model — the parse must complete during the vertical
  blank, before the first active scanline composes.
- **`cmp_start` per scanline** — fire it from `line_start_pulse_bus` for the
  active region (`atari_row` 0..191, ≤0..239 overscan), composing the row for
  the current `ar_atari_row`.  As §5.1 puts it: *"`cmp_start_pulse` becomes
  'scanline begins' not 'kick_counter == 0x400'."*

### The key design decision — compositor row model
Today `compositor` *drives* `meta_row` itself (`output logic [7:0] meta_row` in
`hdl/compositor.sv`): one `start_compose` makes it walk **all** rows 0..191 in a
burst, indexing the dl_parser table per row.  Per-scanline triggering needs one
of:
- **(a)** Pace the compositor's row advance with `line_start` — it composes row
  `atari_row`, then waits for the next `line_start` before advancing.  Smaller
  change to the compositor, but it must hold mid-row state between lines.
- **(b)** Refactor the compositor to compose **one row per `start_compose`**,
  with the row index supplied by the sequencer (= `ar_atari_row`) rather than
  self-generated.  Cleaner boundary; bigger compositor change.

Pick one and justify it.  (b) is likely cleaner given the writeback tap is
already per-row.

### Constraints / things to get right
- **Timing budget.**  `clk_bus = phi2 × CLOCK_MULT`; a scanline is 114 phi2 =
  114 × CLOCK_MULT `clk_bus` cycles.  One row's compose (≤192 column-pairs +
  P/M + memory latency) must fit inside that, or add explicit back-pressure /
  overrun handling.  Confirm it fits at the configured CLOCK_MULT.
- **Writeback alignment.**  The §5 tap already uses `wb_row_flush =
  line_start_pulse_bus`, `wb_frame_done = vbi_start_pulse_bus`, `wb_atari_row =
  ar_atari_row`.  Ensure each composed row's pixel stream lands in the buffer
  row the writeback flushes on that same `line_start` — i.e. compose for row N
  must complete and drain into `lb_wr_*_bus_q` before the `line_start` that
  flushes row N.  Beware an off-by-one between "line_start opens row N" and
  "line_start flushes row N-1".
- **dl_start / parse latency.**  `dl_parser.parse_done` must be observed before
  the first active-row compose; gate the first `cmp_start` on it (or guarantee
  the parse fits in VBlank).
- **Mid-frame register writes.**  Because compose now happens per scanline in
  raster order, register values latched at compose time naturally reflect CPU
  writes up to that row — that is the whole point.  Verify it.

## Verify
- `make -C sim lint` clean (`antic_top` is a verilator top); baseline-only.
- Extend `sim/tb_antic_raster` (or a new `sim/tb_antic_seq`) to assert:
  `dl_start` fires once per frame at `vbi_start`; `cmp_start` fires once per
  active scanline; the composed `wb_atari_row` advances 0,1,2,… in lockstep
  with `line_start`; a mid-frame register change is reflected only from the row
  it was written at, not retroactively.
- ANTIC tbs (smoke/snoop/read/pbi/pokey/pia_regs/hwreg_rd_cdc) + `tb_xt_blitter`
  + sprite tbs stay green; `make -C sim all` green.
- Klaus unaffected (phi2/CPU only; doesn't touch ANTIC display) — but run it as
  the conformance gate before trusting the emulation-timing change.
- **win10 re-synth — do this once task-0014 is in the build** (deferred from
  task-0013 on purpose: measure the raster behaviour we actually want, not an
  intermediate state).  Re-measure `clk_sys` / `clk_sally` + utilisation; the
  display-chain deletion (task-0013) should have dropped utilisation, and this
  task adds the sequencer + (possibly) a reworked compositor row path.  Then
  decide on the targeted closure pass for the standing `clk_sys -1.43` /
  `clk_sally -0.98` long paths (sally_core, sally_mem hwreg, ANTIC compositor).

## Notes
- Decoupled from the committed phase-2 writeback (task-0012) and from
  task-0013's deletion: the writeback/compositor consume the pulses regardless
  of trigger source.
- Reference for correct ANTIC DL→scanline semantics:
  `rp-antic/src/display_list.c` § parse_display_list() (already cited in
  `dl_parser.sv`), and the per-mode scan counts dl_parser already implements.
- This is the last open sub-item of §5.1; when it lands, "ANTIC native raster"
  is fully done (heartbeat + dead-chain deletion + sequencer).
