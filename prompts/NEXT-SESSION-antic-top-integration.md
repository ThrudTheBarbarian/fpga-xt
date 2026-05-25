# Next session — finish phase 2: wire ANTIC's render output to the compositor

You are continuing the **video-compositor** work on fpga-xt (Atari XL on a
Zynq-7020, evolving toward an ARM desktop compositor where the XL is a
window). Read `docs/video-architecture.md` first — it is the authoritative
design spec. Work is on branch **`video-compositor`**; the last clean baseline
before any ANTIC surgery is tag **`compositor-baseline-pre-antic`**.

## Build / verify workflow (important)
- Unit tests: `make -C sim <target>` (iverilog). Lint: `make -C sim lint`
  (verilator, `--top-module` over hdl/*.sv).
- fpga_xt_top can't be sim'd (Xilinx primitives); verify it with
  `verilator --lint-only -Wno-fatal -Ihdl --top-module fpga_xt_top hdl/*.sv` —
  it should report ONLY the ~10 baseline `MODMISSING` errors (MMCME2_BASE,
  BUFG, IOBUF, sally_core). Any OTHER error is yours.
- Synthesis / P&R run on the **win10** host via `vivado/run-win10.sh` (faster
  than the ubuntu box). Edit on the Mac; don't edit-in-place on win10.
- Commits: NO AI-attribution trailers (`Co-Authored-By` etc.). Keep committing
  per logical step like the existing history.

## State — what's already built, unit-tested, and committed
The whole compositor + writeback datapath exists as standalone, tested modules:
- `hdl/plane_compositor.sv` — N-plane depth/scale/clip mixer (tb_plane_compositor).
- `hdl/plane_fetch.sv` — per-plane DDR3 line reader, ping-pong (tb_plane_fetch).
- `hdl/axi_line_writer.sv` — row→DDR3 AXI write DMA (tb_axi_line_writer).
- `hdl/antic_writeback.sv` — palette-resolve + row DMA + double-buffer
  (tb_antic_writeback).
- `fpga_xt_top.sv` already uses `vbeam -> plane_fetch (desktop, HP0) ->
  plane_compositor -> sprite_engine -> pads`. Plane 0 (desktop) is live;
  **plane 1 (the XL window) is wired but DISABLED** (`pl_enable=2'b01`,
  `src_pixel_i[1]` tied 0).

## YOUR TASK — connect ANTIC's render output so the XL window appears
Three coupled steps. There is no top-level sim, so go read-only first, map the
exact signals, then wire carefully.

### 1. Expose ANTIC's render tap as `antic_top` output ports
All these live in `hdl/antic_top.sv`, clk_bus domain (= clk_sys in this build):
- `lb_wr_strobe_bus_q` (~line 1396/1408) — 1-cycle pulse per pixel-PAIR →
  `antic_writeback.pix_valid`.
- `lb_wr_pair_bus_q` (~1394) — pair index (column/2), 8-bit → `.pix_pair`.
- `lb_wr_data_bus_q` (~1395/1407) = `{resolved_color_hi, resolved_color_lo}` →
  `.color_lo = [7:0]`, `.color_hi = [15:8]` (8-bit Atari colour codes).
- `atari_row_sync_q2[7:0]` (~460/474) — row being rendered → `.atari_row`.
- `line_start_pulse_bus` (~480) → `.row_flush` (flush the just-finished row).
- `vbi_start_pulse_bus` (~479) → `.frame_done` (flip the double buffer).
- clk_bus palette writes (feed the palette CDC at ~1491-1495):
  `pal_write_strobe` (~417), `pal_idx_q`, `{pal_r_q, pal_g_q, pal_b_q}` →
  `.pal_we / .pal_idx / .pal_rgb`.
Add these as new outputs on antic_top and pass them up to fpga_xt_top. (Or
instantiate antic_writeback INSIDE antic_top and expose only its AXI master +
front_sel — your call; exposing the taps keeps the AXI masters together at the
top with HP0/HP1/HP2, which is the existing pattern.)

### 2. Instantiate `antic_writeback` at the top, on a free HP port (HP3)
- Config: `base_a`/`base_b` = the two XL surface buffers (reserve in DDR3,
  e.g. 0x3100_0000 / 0x3110_0000 — see spec §3; keep clear of FB 0x3000_0000
  and banked 0x2000_0000), `stride_bytes`, `src_w` (the live playfield width,
  ≤384).
- Wire its AXI write master to **HP3**. You must add HP3: in the OOC path,
  extend `zynq_ps_hp_stub` with an HP3 write slave (mirror HP1's write side);
  in the PS BD path (`USE_PS_BD`), enable `M_AXI_HP3` and wire it (mirror HP1).
- `front_sel` (output) selects which XL buffer the compositor reads.

### 3. Enable compositor plane 1 (the XL window)
- In the `plane_compositor` instance: set `pl_enable=2'b11`; plane-1 fields:
  `origin_x/y` (e.g. centre the window), `scale` (2..5), `depth=1`, `clip_*` =
  the window rect.
- Source plane 1 from a SECOND `plane_fetch` reading the XL front buffer:
  `surface_base = front_sel ? base_b : base_a` (front = the just-written one),
  `stride`, `src_w`. Feed its `rd_pixel` to `src_pixel_i[1]`, `rd_col` from
  `cmp_src_col[1*12 +: 12]`.
- **Scaled vertical prefetch (deferred from phase 1b-ii):** plane 1's
  `plane_fetch.fetch_row` must be the SOURCE row for the *next* display line.
  For the scale-1 desktop this was `v_count+1`; for a scaled window it is
  `((v_count+1) - clip_y0) / scale` while inside the window. Compute it
  (divide-by-small-constant once per line is fine, or a per-line vertical
  accumulator). `plane_compositor` currently outputs `src_row_o` (current
  row); you may add a `src_row_next_o` for this, or compute it at the top.

## Gotchas already paid for this milestone (don't re-learn them)
- AXI read/write FSMs: make the line-buffer write-enable **combinational**
  (`state==DATA && valid`), NOT registered — a registered we drops the first
  beat.
- Ping-pong line buffers: flip read AND write pointers on the SAME event
  (line_start), initialised in OPPOSITE phase — otherwise read and write hit
  the same buffer (not double-buffered).
- BRAM / palette_lut reads are 1-cycle latent — add a setup state before
  sampling rdata (see antic_writeback's R_SETUP).
- Testbench busy-waits on a multi-stage trigger: wait for `busy` to RISE then
  fall (`while(!busy)@; while(busy)@;`). A bare `while(busy)` can exit before
  busy rises and check mid-DMA.

## Verify
- `make -C sim lint` clean.
- `verilator --lint-only --top-module fpga_xt_top hdl/*.sv` → only the baseline
  MODMISSING errors.
- Re-run all compositor sims (`plane_compositor plane_fetch axi_line_writer
  antic_writeback`) — should stay green.
- Then win10 synth + HDMI: a scaled, positioned Atari window over the desktop.

When done, update `docs/TODO.txt` item 4(c) and the task list, and write a
`prompts/task-00NN-*.md` summary (the existing convention).
