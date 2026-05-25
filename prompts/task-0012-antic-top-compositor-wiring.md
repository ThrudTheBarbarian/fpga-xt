# task-0012 — wire ANTIC's render output to the compositor (video-arch phase 2, part 3)

Completes `prompts/NEXT-SESSION-antic-top-integration.md`: the final
phase-2 step that makes the Atari XL appear as a scaled window (compositor
plane 1) over the desktop.

## Goal
Connect ANTIC's per-pixel render stream to the standalone, already-tested
`antic_writeback` + `plane_fetch` + `plane_compositor` datapath so the XL
surface is produced in DDR3 and composited as plane 1.

## What this delivered

### 1. ANTIC render tap exposed (`hdl/antic_top.sv`)
New clk_bus (= clk_sys) output ports `wb_*`, assigned from the existing
(display-bypassed) line-buffer/palette chain so the DDR3 XL surface mirrors
the legacy image:
- `wb_pix_valid`  ← `lb_wr_strobe_bus_q`  (1 pulse / pixel-pair)
- `wb_pix_pair`   ← `lb_wr_pair_bus_q`    (column/2)
- `wb_color_lo/hi`← `lb_wr_data_bus_q[7:0]` / `[15:8]` (8-bit Atari codes)
- `wb_atari_row`  ← `atari_row_sync_q2[7:0]` (0..191)
- `wb_row_flush`  ← `line_start_pulse_bus`
- `wb_frame_done` ← `vbi_start_pulse_bus`
- `wb_pal_we/idx/rgb` ← `pal_write_strobe` / `pal_idx_q` / `{pal_r_q,pal_g_q,pal_b_q}`

### 2. `antic_writeback` instantiated at the top on HP3 (`hdl/fpga_xt_top.sv`)
- XL surface: `base_a=0x3100_0000`, `base_b=0x3110_0000` (1 MB apart),
  `src_w=320`, `stride=1280` (320×4, RGBA8888).
- `front_sel` (flipped on ANTIC vblank) selects the front buffer.
- AXI write master → **HP3** (the spec §10 "XL/compositor" port).

### 3. Compositor plane 1 enabled (`hdl/fpga_xt_top.sv`)
- A second `plane_fetch` reads the XL FRONT buffer
  (`front_sel ? base_b : base_a`) over **HP3's read channel** — writeback and
  fetch use independent AXI channels of the same full-duplex HP port.
- Window: native 320×192, **scale 3** → 960×576, **centred** (origin
  480,252), depth 1 (in front of the desktop), clip = window rect.
- **Scaled vertical prefetch** (deferred from 1b-ii): plane-1 `fetch_row =
  ((v_count+1) - clip_y0) / scale` while the next line is inside the window,
  matching the compositor's own nearest-neighbour vertical accumulator
  (verified: rows 0,0,0,1,1,1,… for scale 3). Computed at the top.

### 4. HP3 plumbing
- `hdl/zynq_ps_hp_stub.sv`: added a full-duplex HP3 slave (read responder
  mirrors HP0; write responder mirrors HP1) for the OOC flow.
- `hdl/fpga_xt_top.sv`: HP3 wired in both the OOC stub instance and the
  `ps_bd` instance (direct, like HP0 — XL traffic is light vs the blitter).
- `vivado/bd/gen_ps_bd.tcl`: `PCW_USE_S_AXI_HP3=1`; HP3 ACLK→FCLK_CLK0,
  exported as `m_axi_hp3`, address-assigned, added to `ASSOCIATED_BUSIF`.
  HP2 stays disabled (skipped by the `-quiet` guards).

## Verify
- `make -C sim lint` — PASS (antic_top etc.).
- `verilator --lint-only --top-module fpga_xt_top hdl/*.sv` — only the 10
  baseline MODMISSING errors (MMCME2_BASE/BUFG/IOBUF/sally_core).
- `make -C sim plane_compositor plane_fetch axi_line_writer antic_writeback`
  — all PASS. ANTIC-dependent sims (smoke/pbi/snoop/read/pokey/pia_regs/
  hwreg_rd_cdc) still PASS. (`tb_dma_int` is pre-existing broken — missing
  Efinix-era `rp_tx`/`rp_bus_mock` mocks, unrelated.)

## Synthesis (win10) — REQUIRED before the bit build
1. **Regenerate the PS BD** so `ps_bd` actually has the `m_axi_hp3_*` ports:
   `vivado -mode batch -source vivado/bd/gen_ps_bd.tcl` on win10. Without
   this the bit-flow elaboration fails (the committed BD has no HP3).
2. `vivado/run-win10.sh` bit flow → HDMI should show a 960×576 Atari window,
   centred, over the (blue once desktop.app fills it) 1080p desktop.

## Gotchas / notes for the next session
- **Pair-index off-by-one is intentional/consistent**: `lb_wr_pair_bus_q`
  is post-increment when the strobe is high, so a pair's data lands at
  column-pair (P+1) — but the legacy line_buffer path samples it the same
  way, so the writeback reproduces the native image (2-px shift, harmless).
- **front_sel tearing (deferred)**: the fetch reads `front_sel` directly
  (combinational), so an ANTIC vblank mid-compositor-frame can tear (both
  halves are complete frames). Tear-free = sample front_sel at the
  compositor's clk_pix frame start (spec §3 / open question §13).
- **ANTIC native raster rate**: antic_top's internal hdmi_out vbeam (800×600
  timing) now runs at the 148 MHz clk_pix, so the writeback frame rate isn't
  the true Atari rate — the double buffer decouples it from 1080p60, so a
  window still appears; smoothness is a later tuning item.
- **Fixed src_w=320**: narrow/wide playfield tracking is deferred.
