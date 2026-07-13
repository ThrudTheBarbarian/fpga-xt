# BUG: SCALED blit (CMD 0x04 / 0x06) writes nothing to a DDR surface

**Status:** ROOT-CAUSED, fixed in `hdl/xt_blitter.sv`, proven in simulation and confirmed
on silicon. **The RTL fix is NOT yet on the board — it needs a Vivado bitstream rebuild.**

## The answer

**`seg_cx` is never assigned anywhere in the SC_* (scaled-blit) states.**

The burst write address is `seg_raw_addr = dst_row_base + (seg_cx << 2)` (line ~959,
consumed by `S_AW`). `seg_cx` is written in exactly two places: `S_SEG` (rect fill / line /
font) and `BL_READ` (block blit). The scaled path — `SC_ROW → SC_CALC → SC_READ → SC_ACCUM
→ SC_NEXT → S_PEND → S_AW` — touches neither. So a scaled blit **inherits the column left
behind by whichever command ran before it** and writes its entire rect that many pixels to
the right.

**It does not "write nothing". It writes to the wrong column.** In `blittest` the scaled
blit follows a 256-wide FILL and COPY; bursts are 32px, so the last segment of a 256px row
starts at column 224, and `seg_cx` is still 224. The 8x8 result lands at columns 224-231.
The test sampled columns 0-7 and read zeros.

Confirmed on silicon (no Vivado needed) by probing column 224: the source quadrants
(`11111111` / `44444444`) are sitting exactly there.

**This is NOT a DDR bug** — the DDR framing was a red herring that cost the previous session
hours. It is command-history-dependent. The only pre-existing caller (`gem_lua.c`, plane->
plane) never tripped it because its scaled blits happen to follow commands narrow enough to
leave `seg_cx == 0`. The testbench's 8 scaled tests passed for the same accidental reason.

**Fix:** capture the segment origin when a burst *starts* (`burst_len == 0 &&
!beat_lo_filled`) in both `SC_CALC` and `SC_BL_RD`. Two hunks. `sim/tb_xt_blitter.sv` gains
`test_scaled_after_wide` (the direct reproducer — fails at `0x30300580` without the fix,
`0x30300000` with it) and `test_scaled_wide_row` (a 40px scaled row spanning two bursts —
this had ZERO coverage and is exactly what gemd needs). 35/35 pass with the fix.

## Original symptom (kept for the record)

## Symptom

`blittest` (romfs; `ssh xtos.local blittest`) prints:

```
blittest: STRETCH 2x2 -> 8x8 NN     -> 00000000 00000000 00000000 00000000 FAIL
blittest:   after-delay resample    -> 00000000 00000000  (engine wrote nothing)
blittest:   SCALED 1:1 (no scaling) -> 00000000 00000000 FAIL (SC path writes nothing on DDR)
blittest: STRETCH bilinear          -> corner=00000000 mid=00000000 FAIL
```

Every other command works on the same surfaces, in the same run, through the same
driver: `RECT_FILL` (0x01), `BLOCK_BLIT` (0x03), and `SRC_BLIT` (0x08) with RGBA
alpha-over. Only `SCALED` produces nothing.

## Already ruled out (do NOT re-chase these)

1. **Not a fence race.** The test re-samples the destination after a multi-million
   iteration spin. The pixels never arrive. It is not "sampled too early".
2. **Not a scaling/Bresenham bug.** A 1:1 SCALED (sw=dw=8, sh=dh=8, no scaling at all)
   *also* writes nothing. The scale factor is irrelevant.
3. **Not the register map.** The driver's offsets were diffed against the authoritative
   `vitis/xtos/src/blitter.h`: DST_X/Y/W/H 0x00-0x07, CMD 0x0C, RASTER_OP 0x0F,
   SRC_X/Y/W/H 0x10-0x17, FLAGS 0x18, SRC_BASE 0x30, SRC_STRIDE 0x34, DST_BASE 0x36,
   DST_STRIDE 0x3A. All correct.
4. **Not the unlock gate.** The blitter is behind the XT register-unlock (resets locked;
   `CTRL_UNLOCK` at GP0 `0x43C0_0308`, blitter = bit 2, `UNLK_BLIT=2` in
   `fpga_xt_top.sv:528`). The driver unlocks it, and the other three commands work
   through the same unlocked register file, so the gate is open.
5. **Not a zero-extent early-out.** `S_IDLE` bails to `S_DONE` only if dst_w/h or src_w/h
   are zero. The test passes 8x8 and 2x2.

## What the RTL *looks* like it should do (hdl/xt_blitter.sv)

This is the confusing part — by inspection it should work:

- `S_IDLE` (~line 1387) seeds the row bases from the descriptors when the DDR flags are set:
  ```systemverilog
  dst_row_base <= q_flags[5] ? q_dst_base : (FB_BASE + (32'(q_dst_y) << 13) + (32'(q_dst_x) << 2));
  src_row_base <= q_flags[2] ? q_src_base : (FB_BASE + (32'(q_src_y) << 13) + (32'(q_src_x) << 2));
  ```
- `q_sc_mode = (q_cmd == 8'h04) && !q_flags[1]` (~753); dispatch enters `SC_ROW` (~1414).
- `SC_ROW` (~2442) seeds `sc_col_addr_q <= src_row_base` — the DDR descriptor.
- `dst_stride_eff = dst_ddr_q ? dst_stride_q : FB_STRIDE_B` (~950), `src_stride_eff`
  likewise (~956). So strides honour DDR too.

So the seeding, the mode decode, and the strides all appear DDR-aware. Yet nothing is
written. **The next place to look is the SC *write* path** — how accumulated pixels get
drained to AXI (`S_PEND` / the burst-drain states) and whether that path derives its
address or its write-strobe from something plane-specific, or from the pattern alpha
(`px_alpha_nz` / `px_strb`, ~1104) rather than the scaled source pixel. Also worth
checking `SC_ACCUM` and whether `dma_mode_q` or a fill-only fast path interferes.

## Key context: this path has NEVER run before

`vitis/xtos/src/gem_lua.c` is the only caller of `XT_BL_CMD_SCALED_BLIT`, and it scales
**plane -> plane**: `xt_blitter_set_flags(bilin ? XT_BL_FLAG_BILINEAR : 0)` — no
`SRC_DDR`, no `DST_DDR`. So scaled-blit has only ever been exercised in plane mode.
DDR->DDR scaling is new silicon territory, which is entirely consistent with it being
broken in a way nobody noticed.

**A cheap discriminating experiment:** drive a SCALED blit plane->plane (flags = 0 or
BILINEAR only) and confirm it still works. If plane mode works and DDR mode doesn't, the
bug is isolated to the descriptor path in the SC states specifically.

## How to reproduce / test

Kernel-side (fast, ~8 min per cycle):
```
make -C loader hw
./vivado/jtag-valhalla.sh treset && ./vivado/jtag-valhalla.sh testbed
# wait ~60s for the board to come up
ssh xtos.local blittest
```
- `treset` alone resets the board but WIPES the PL bitstream; `testbed` reloads it.
  `treset && testbed` is the only working sequence. `tdow` HANGS the board — never use it.
- The board runs sshd. romfs mounts at `/System/bin`.
- Serial is `/dev/cu.usbserial-0001` @115200, but **DTR-reset is wired**: opening the port
  REBOOTS the board, and reopening it per-write will silently reboot it mid-test. Hold one
  fd (`exec 3<>$PORT`). `lsof /dev/cu.usbserial-0001` finds a stale holder. ssh is better.

HDL-side (expensive): a change to `hdl/*.sv` needs a bitstream rebuild —
`make bitstream` -> `./vivado/run-win10.sh bit`, Vivado on the **win10 host**. This is a
long, host-dependent step. Check for a simulation testbench first (`hdl/tb`, `sim/`) —
proving the fix in simulation is far cheaper than a synthesis round-trip.

## Driver / ABI

- Driver: `loader/test/freertos/blitter.c` (`blit_submit`). It already implements SCALE
  correctly per the register spec; the op is `XT_BLIT_SCALE` with `sw`/`sh` and an
  optional `XT_BLITF_BILINEAR`.
- ABI: `loader/kernel/xtsys.h`, where `XT_BLIT_SCALE` carries a loud warning comment.
- Test: `loader/test/freertos/progs/blittest.c`.

## Two adjacent hardware truths worth knowing (learned the hard way)

- **FILL colour is a 1x1 PATTERN**, not a colour register (PAT_LOG/PAT_PHASE/4x PAT_DATA).
  Get it wrong and the engine fills *perfectly* with the reset-zero pattern BRAM — all
  zeros, which reads exactly like "the engine never ran". Beware: that failure signature
  is the same one this bug presents with.
- **BLOCK_BLIT (0x03) has no blend path.** `FLAGS.BLEND` is honoured only on 0x01/0x02
  (`q_blend_mode`) and 0x04/0x06 (`q_sc_blend`). On a 0x03 it is silently IGNORED and you
  get an opaque copy. Alpha compositing must use SRC_BLIT (0x08) + SRC_AOVER.
- `seq_counter` is the **SYNC-barrier** counter — it does not tick per command. Fire a
  SYNC (0x07) or a fence on it waits forever on 0.
