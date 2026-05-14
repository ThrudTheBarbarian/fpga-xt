# Roadmap

Milestones are sim-first — every step ships a passing testbench
before any HDL or firmware is committed. Hardware bring-up is gated
on Efinity P&R closing timing (M19) and a matching RP2354 build that
exercises the FPGA<->RP bus from real silicon (M20+).

## Status at a glance

Legend: ✓ = done, ⏳ = pending / not started, partial-✓ = sub-set done.

| Milestone                | Status        | Notes                                                                   |
|--------------------------|---------------|-------------------------------------------------------------------------|
| [M0](#m0)                | ✓             | tb_smoke                                                                |
| [M0-RP](#m0-rp)          | ⏳            | RP-side firmware — tracked separately; production build at [M21](#m21)  |
| [M1](#m1)                | ✓             | tb_snoop                                                                |
| [M2](#m2)                | ✓             | RTL exists + bus-side read mux verified via tb_read.sv (M2b)            |
| [M2b](#m2b)              | ✓             | tb_read.sv — bus_data_oe + bus_data_out muxing verified for /D0xx, /D4xx, $D2xx reads + non-paged + write paths |
| [M3](#m3)                | ✓ (FPGA side) | RP-side ingest ↦ [M21](#m21)                                            |
| [M4](#m4)                | ✓             | tb_prefetch — line_buffer leading-edge mask removal ↦ [M19](#m19)       |
| [M5](#m5)                | ✓             | tb_dl_parse                                                             |
| [M6](#m6)                | ✓             | tb_mode_f                                                               |
| [M7](#m7)                | ✓             | modes 2/4/5/6/7 — mode 3 descender ↦ [M11d](#m11d)                      |
| [M8](#m8)                | ✓             | tb_gfx_modes                                                            |
| [M9](#m9)                | ✓             | tb_pm — base + 9b/9c/9d sub-milestones                                  |
| [M10](#m10)              | ✓             | PRIOR[0:3] + OR-mode                                                    |
| [M10b](#m10b)            | ✓             | GTIA modes 9/10/11 (compositor + resolver)                              |
| [M10c](#m10c)            | ✓             | PM5 + 12-bit idx_buf (M-only top nibble); cmd_data 16→24 widened        |
| [M11](#m11)              | ✓             | mode-F HSCROL + start-of-block VSCROL                                   |
| [M11c](#m11c)            | ✓             | HSCROL for graphics modes 8-E via mode-dispatched window packer         |
| [M11d](#m11d)            | ✓             | mode 3 descender + char-mode HSCROL + VSCROL last-row truncate         |
| [M-int](#m-int)          | ✓             | antic_top closes 173 MHz on Tz50F256 (64/235 BRAM, 11% LUT)             |
| [M12](#m12)              | ✓             | nmi_gen — DLI + VBI + NMIRES set-wins; antic_top wiring at [M14b](#m14b) |
| [M13](#m13)              | ✓             | wsync_gen — $D40A asserts /RDY, line_start releases; overdue counter   |
| [M14](#m14)              | ✓             | palette_lut + chiplet-ext writes; NTSC + PAL reference tables shipped  |
| [M14b](#m14b)            | ✓             | TMDS 8b/10b encoder + 10:1 serializer (sim-portable; Efinity SERDES TBD) |
| [M15](#m15)              | ✓             | tmds_out — vbeam + 3 encoders + 4 serializers, 800×600 default        |
| [M15b-1](#m15b-1)        | superseded    | i2s_rx — removed at M23-7; POKEY → HDMI audio is an internal fabric feed |
| [M15b-2](#m15b-2)        | ✓             | terc4_encoder — HDMI data-island 4b/10b LUT                             |
| [M15b-3](#m15b-3)        | ✓             | hdmi_bch + hdmi_packet + hdmi_pkt_source (audio sample / 2 InfoFrames / clk regen / null) |
| [M15b-4](#m15b-4)        | ✓             | hdmi_out — period sequencer (control / preamble / guard band / island) |
| [M16](#m16)              | ✓             | dma_master — 6502-style /HALT + addr-drive bus master (1025 fetches verified) |
| [M16-int](#m16-int)      | ✓             | mem_read_mux × 2 + dma_arbiter wired through antic_top; $D481[0] vsync-latched |
| [M16-int-tb](#m16-int-tb) | ✓             | DL-through-both-modes verification — fb byte-for-byte identical |
| [M16b-1](#m16b-1)        | ✓             | hyperram_shim foundation — dual-port reads, write FIFO, latency-tagged response routing |
| [M16b-2](#m16b-2)        | ✓             | bank_translator — 130XE PORTB[4]/[5] CPU vs ANTIC bank partitioning + bank-idx switching |
| [M16b-3](#m16b-3)        | ✓             | cart banking — 8 KB at $A000-$BFFF + 16 KB at $8000-$BFFF, 16 banks each |
| [M16b](#m16b)            | ✓             | HyperRAM-backed cpu_shadow + 130XE bank + cart banks (integration into antic_top is M16b-int, follow-up) |
| [M16b-int](#m16b)        | ✓             | hyperram_shim wired into antic_top in place of byte_ram_dp; BRAM 128 → 13, fMax 153 MHz |
| [M17-1](#m17-1)          | ✓             | rp_tx DRAW emission FSM — 5-beat NOP/LINE/RECT/FILL + draw_full stall + invalid-op trap |
| [M17-2](#m17-2)          | ✓             | draw_regs — chiplet-ext register port at $D488-$D493 for software-driven DRAW |
| [M17-3](#m17-3)          | ✓             | rp/video/src/draw.c — RP-side dispatch + LINE/RECT/FILL/NOP_DRAW renderers (host C model verified) |
| [M17-1.1](#m17-1-1)      | ✓             | FILL is flood-fill (not filled-rect); op[7] = fill flag for paired RECT/OVAL/ARC; OVAL/BEZIER opcode IDs reserved |
| [M18-1](#m18-1)          | ✓             | OVAL outline + filled (paired via op[7]) — midpoint ellipse + per-row span fill; circle is degenerate rx==ry |
| [M18-2](#m18-2)          | ✓             | rp_tx args storage 5 → 7; chiplet-ext $D494-$D497; ARC outline + PIE renderers |
| [M18.1](#m18-1-bezier)   | ✓             | rp_tx / draw_regs args 7 → 9; BEZIER + BEZIER_TO cubic curves with chained-endpoint state |
| [M17](#m17)              | ✓             | DRAW pipeline — rolls up M17-1 / 17-1.1 / 17-2 / 17-3 (NOP/LINE/RECT/RECT-fill/FILL flood-fill) |
| [M18](#m18)              | ✓             | OVAL/PIE/BEZIER pipeline — rolls up M18-1 / 18-2 / 18.1 (full DRAW set on the wire) |
| [M19](#m19)              | ✓             | Efinity project skeleton + synth — script-driven flow + SDC + pin-map |
| [M20](#m20)              | ✓ PnR / ⏳ bit | PnR + STA closure (Ti60-C4, ram_clk +1.4 ns slack); bitstream gen gated on board-layout `.peri.xml` |
| [M21](#m21)              | ✓ code / ⏳ HW | RP firmware — bus.pio + multicore drain + draw dispatch wired up; HW bring-up gated on silicon |
| **next →**               | **[M24-int](#m24-int)** | SALLY → antic_top integration — M24-int-1/2/3 + osrom-bake all ✓ (full integration at 115.2 MHz / +0.79 ns slack on Ti60-C4); M24-int-cache attempted, reverted, deferred (see Issues `bank-cache-async-read`) |
| [M22](#m22)              | ⏳            | chiplet integration handoff                                             |
| [M23](#m23)              | ✓             | POKEY in fabric — rolls up M23-1..M23-7 (audio + keyboard + POT + serial + I2S to HDMI) |
| [M23-1](#m23-1)          | ✓             | bus_snoop $D2xx classification + pokey register file + 4× square-wave channels (no LFSR) |
| [M23-2](#m23-2)          | ✓             | LFSR polynomial counters (4 / 5 / 9 / 17-bit) + RANDOM ($D20A) — full POKEY tone repertoire |
| [M23-3](#m23-3)          | ✓             | AUDCTL features — REF15 / CH1-3 high-freq / 16-bit pair (1+2, 3+4) / high-pass filter (FILT1, FILT2) / POLY9 |
| [M23-4](#m23-4)          | ✓             | Keyboard event ingest — KBCODE / SKSTAT / SKCTL (USB-HID via RP2354) |
| [M23-5](#m23-5)          | ✓             | POT scan — discharge-time counter, POT0..POT7, ALLPOT, POTGO            |
| [M23-6](#m23-6)          | ✓             | Serial / IRQ aggregation — IRQEN / IRQST / SEROUT / SERIN / SKRES + irq_n |
| [M23-7](#m23-7)          | ✓             | I2S TX — dual-POKEY stereo mix → 24-bit LPCM @ 48 kHz → 4-deep audio packet feed |
| [M23-stereo](#m23-stereo) | ✓             | Second POKEY at $D21x (130XE-style stereo mod); audio-only, IRQs ignored |
| [M24](#m24)              | ⏳            | SALLY in fabric — rolls up M24-1..M24-7 (Arlet 6502 + tiered BRAM + bank cache + dual-view + OS ROM) |
| [M24-1](#m24-1)          | ✓             | Arlet 6502 sim bring-up + undocumented-opcode survey (M24-und needed)   |
| [M24-2](#m24-2)          | ✓             | Memory skeleton — direct BRAM regions + combinational $Dxxx reg decode (real GTIA/ANTIC/POKEY hookup deferred to M24-5) |
| [M24-3](#m24-3)          | ✓             | Bank cache — 16 × 4 KB lines, full assoc, RR victim, integrated into sally_mem |
| [M24-4](#m24-4)          | ✓             | Dual-view bank select — bank_xlat + ANTIC chiplet-ext bank registers $D488-$D48B |
| [M24-5](#m24-5)          | ✓             | Bus arbitration — /HALT cycle-stealing at CLOCK_MULT=1, free-run ≥2     |
| [M24-6](#m24-6)          | ✓             | OS ROM load path — chiplet-ext $D48C-$D48F + sally_mem rom-load port + tb_os_rom_load 5/5 |
| [M24-7](#m24-7)          | ✓             | Standalone SALLY-stack synth on Ti60F256-C4 — **106.3 MHz / +0.595 ns slack** at 100 MHz target. sally_core 142 FF / 924 LUT; bank_cache dominates (8418 FF / 38928 LUT — async-read forces LUT mapping, logged as `bank-cache-async-read`) |
| [M24-und](#m24-und)      | ⏳ deferred    | Add stable undocumented opcodes (LAX/SAX/DCP/ISC/…) only when real software needs them — Arlet's core passes Klaus's documented suite cleanly (2026-05-08), so the documented portion of the M24 ship criterion is met without M24-und. |
| [M25](#m25)              | 🟢 software-complete | Peripherals — every piece has a passing host or HDL sim (4 host sims + 6-phase tb_peri_bridge + 4-phase tb_joy_bridge). PIO programs (peri_pot, peri_sio) and the SD card SPI driver are stubbed pending hardware bring-up. |
| [M25-1](#m25-1)          | ✓             | PIA shadow at $D300-$D37F + bidirectional PORTA/PORTB — `pia_regs.sv`; fire buttons → GTIA TRIG0..3 |
| [M25-2](#m25-2)          | ✓             | Peri-RP SPI link with /CS (FPGA side) — `peri_link.sv` (M25-2) + `joy_link.sv` + `joy_bridge.sv` PCAL9722 path (M25-2c-rev) + `antic_top` integration. HVIO repurposed for inbound 3.3 V traffic, no LVC8T245 on rp_rx or peri-RP SPI |
| [M25-3](#m25-3)          | 🟢 software-complete | Peri-RP firmware (HW SPI ✓ + POT scanner C state machine ✓ + IRQ aggregation ✓). Joystick block deleted from peri-RP scope (PCAL9722 in HDL). PIO program for POT discharge timing stubbed. |
| [M25-4](#m25-4)          | 🟢 software-complete | SIO TX/RX queue + register glue (FPGA bridge ✓ + peri-RP firmware ✓; tb_peri_bridge phases E/F + tb_peri_sio host sim). UART framing PIO stubbed. |
| [M25-5](#m25-5)          | 🟢 software-complete | SD card driver scaffold (state machine ✓ + register glue ✓ + STATUS.sd_done IRQ path ✓). Hardware SPI driver + FAT32 + SIO-disk emulation pending hardware. |
| [M-PBI](#m-pbi)          | ✓ (HDL complete) | External 6502 bus + cart slot + PBI + ECI fanout. Steps 1-3 + deferred #1/#2/#3/#4 all landed (commits `ae29ceb` / `7307e32` / `3d932ac` / `9edccce` / `7f547c9`). clk_bus 167.11 MHz / +0.186 ns slack. 46/46 sims passing. No deferred items remain. |

The architecture is **interesting** (RP2354 as smart video RAM); see
[architecture.md](architecture.md). Two parallel codebases:

- `hdl/` + `sim/` — FPGA HDL and iverilog testbench.
- `rp/` — RP2354 C firmware + PIO assembly + paired sim (the RP-side
  testbench lives here too, mocking the FPGA half).

Order parallels rp-antic's milestone sequence so we re-use the
validated mode-by-mode behaviour port-by-port. HDL modules replace
ARM C / PIO programs, but the per-mode semantics are identical —
collision lookup tables, PRIOR resolution, charset row indexing,
mode-by-mode pixel unpack. Don't reinvent.

## Phase 0 — sim harnesses

### M0 — iverilog harness boots (FPGA)  ✓
<sub><a id="m0"></a>[⤴ status table](#status-at-a-glance)</sub>


- `sim/Makefile` with a `make sim` target that compiles
  `hdl/*.sv` + `sim/tb_*.sv` via `iverilog -g2012` and runs `vvp`.
- `sim/tb_smoke.sv` instantiates the top-level, drives `/G_RST` for a
  few cycles, releases reset, runs for 1 ms simulated, prints
  `*** SMOKE OK ***` if no `$fatal`.

**Ship criterion**: `make sim` exits 0 with `SMOKE OK` printed.

### M0-RP — RP2354 firmware boot (RP)  ⏳ (separate side, not started here)
<sub><a id="m0-rp"></a>[⤴ status table](#status-at-a-glance)</sub>


- `rp/video/CMakeLists.txt` for an `rp_antic_video` target. PICO_BOARD =
  `adafruit_feather_rp2350` for dev rig (production board file added
  later). PICO_PLATFORM = `rp2350-arm-s`. USB CDC for stdio.
- `rp/main.c` with the canonical clock init (sys_clk = 360 MHz with
  vreg 1.35 V + QMI flash retune, lifted from rp-antic's
  M3-with-360-target build). USB CDC + 2 s sleep + boot banner.

**Ship criterion**: UF2 flashes, USB CDC connects, banner prints,
sys_clk reads back as 360000000 Hz.

## Phase 1 — bus snoop pipeline (FPGA-only)

### M1 — bus snoop dispatches register writes  ✓
<sub><a id="m1"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/bus_snoop.sv` samples `{A, D, R/W, /D0xx, /D4xx, /ANTIC_*}` on
  posedge CLK and produces decoded write-enables.
- `hdl/antic_regs.sv` and `hdl/gtia_regs.sv` register files latch
  on the snoop's enables.
- `sim/tb_snoop.sv` drives a small CPU bus + tag pattern and asserts
  that each register file received the expected value.

**Ship criterion**: tb_snoop reports zero mismatches across all
$D000-$D01F + $D400-$D40F write paths plus one $D481 chiplet-ext
write.

### M2 — register read response  ✓ (RTL only; testbench → [M2b](#m2b))
<sub><a id="m2"></a>[⤴ status table](#status-at-a-glance)</sub>


- $D0xx and $D4xx reads (R/W=1) drive `D[7:0]` with the appropriate
  register's current value, with combinational decode → registered
  output enable timed against CLK rising. (Wired in `antic_top.sv`
  via `gtia_read_data` / `antic_read_data` muxed into `bus_data_out`.)
- VCOUNT, NMIST, collision latches, TRIG, CONSOL, PAL/NTSC sense are
  all readable.
- Independent verification deferred to [M2b](#m2b).

### M2b — bus-side register-read testbench  ⏳
<sub><a id="m2b"></a>[⤴ status table](#status-at-a-glance)</sub>


- `sim/tb_read.sv` drives back-to-back read/write patterns against the
  full $D0xx / $D4xx register set and asserts `bus_data_out` matches
  expected values. Existing `tb_snoop.sv` only verifies the write
  path via hierarchical `cpu_shadow.mem[]` reads — the bus-side
  read mux is currently unverified.

**Ship criterion**: tb_read reports zero mismatches across the full
read-side register set with arbitrary back-to-back read/write patterns.

## Phase 2 — FPGA<->RP bus bring-up (parallel HDL + RP)

### M3 — FPGA-side TX path + RP-side PIO ingest (paired)  ✓ (FPGA side; RP side TBD)
<sub><a id="m3"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/rp_tx.sv` packs FETCH / SET / NOP into rp_tx_clk-domain beats.
- `hdl/rp_rx.sv` accepts RP→FPGA beats and lands them in the line
  buffer (or response FIFO for FETCH replies).
- `rp/bus.pio` — RP-side PIO state machine that ingests the
  27-wire FPGA→RP bus, decodes the 2-bit tag, dispatches FETCH /
  SET / DRAW / NOP to handlers in the ARM/PIO core split.
- `rp/bus_server.c` — core 0 main loop draining FETCH / SET requests,
  servicing them out of an in-RAM stub framebuffer (256 KB at this
  milestone), and pushing FETCH responses back via the RP→FPGA PIO.
- `sim/tb_rp_bus.sv` instantiates the FPGA TX/RX modules and a
  Verilog **mock** of the RP-side PIO behaviour (synthesisable
  behavioural model, validated against the actual `bus.pio` via a
  shared opcode table).
- `rp/video/sim/tb_bus_pio.c` — RP-side paired sim using
  pico-sdk's PIO emulator (or a hand-rolled tick-level model) that
  mirrors the FPGA's mock.

**Ship criterion**: round-trip FETCH at simulated 360 MHz sys_clk on
both sides; SET writes land at the right address; NOP traffic doesn't
move state. Both sims report zero mismatches on a 1024-op
randomized opcode stream.

### M4 — line-buffer prefetch loop closes  ✓
<sub><a id="m4"></a>[⤴ status table](#status-at-a-glance)</sub>


- FB contract: **1024 atari-pixel indices per row × 240 rows** in
  ANTIC-compat mode (~240 KB in RP). See architecture.md § "Scroll
  handling" for the rationale.
- `hdl/line_buffer.sv` is a ping-pong BlockRAM pair, **384 atari px ×
  2 banks** (visible width + HSCROL margin).
- `hdl/prefetch.sv` issues FETCH commands to `rp_tx` to fill the
  off-buffer for atari row N+1 while scan-out reads atari row N from
  the on-buffer. Effective FB read offset per row computed from
  `line_lms_addr[r]`, `cache_lms_base[r]`, and `line_hscrol[r]` (see
  architecture.md § "LMS slides — also read-side"). Per-row metadata
  is stub-populated for M4 (DL parser at M5 fills it for real).
- `hdl/scan_out.sv` reads the on-buffer at pix_clk rate, applies
  `line_hscrol[r]` as a read-address offset, drives `pix_r/g/b` (no
  palette LUT yet — directly emits the index as grayscale at M4).
- The FPGA spreads its FETCH burst across the entire window during
  which the off-buffer is idle — 2 output scanlines at 640×480
  line-doubled (see
  [wire-protocol.md § Line-buffer prefetch budget](wire-protocol.md#line-buffer-prefetch-budget)).
- `sim/tb_prefetch.sv` writes a known per-row pattern into the RP
  mock FB via a back-door, runs 2 frames, asserts that scan-out
  reads back the pattern pixel-exact.

**Ship criterion**: tb_prefetch passes with zero pixel mismatches at
640×480 over 2 frames. The 1024-wide FB contract is in place even
though the LMS-slide bookkeeping is exercised only by stubs at M4 —
the path through `cache_lms_base` and `line_lms_addr` is wired so M5
just populates it.

**M19 polish carried over from M4**: line_buffer's read path has 2
cycles of pipeline latency (rd_word + rd_hi_q registers), and the
`swap` pulse + bank_select flip costs another cycle. At atari-row
transitions the scan-out reads stale data for ~3 native pixels until
the pipeline fills. M4 masks this in the testbench (`h_count > 4`).
M19 either drops the line_buffer registers in favour of a
combinational read (Efinix BRAM "WRITE_FIRST" / read-during-write
mode) or fires `swap` 1-2 pix_clk cycles ahead of the atari-row
boundary using a lookahead from vbeam. Either way, the leading-edge
mask comes off the testbench.

## Phase 3 — display pipeline (FPGA reads from cpu_shadow, writes via SET)

### M5 — display-list parser  ✓
<sub><a id="m5"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/dl_parser.sv` walks the shadow display list once per VBI,
  populates per-line metadata (`line_mode[193]`, `line_dli[193]`,
  `line_lms_addr[193]`, `line_sub_row[193]`, `line_hscrol[193]`,
  `line_vscrol[193]`).
- Handles JMP ($01), JVB ($41), LMS auto-advance, blank-line modes
  ($00/$10/.../$70), text & graphics modes ($02..$0F).
- `sim/tb_dl_parse.sv` builds canonical DLs in shadow memory and
  asserts the parsed metadata is correct.

**Ship criterion**: tb_dl_parse covers JMP, JVB, LMS, mode 2-F lines,
and DLI-bit propagation; zero mismatches.

### M6 — mode F scanline pipeline  ✓
<sub><a id="m6"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/compositor.sv` reads from cpu_shadow / charset_shadow / pm_shadow
  per pixel, produces an 8-bit playfield index, writes to the RP via
  SET opcodes for the current scanline's region of the framebuffer.
- `hdl/palette_lut.sv` resolves index → RGB888 on the scan-out side
  (separate from the framebuffer, which stores indices).
- Mode F path only at this milestone: 1 bpp, 320 px → pixel-double to
  640.
- `sim/tb_mode_f.sv` populates cpu_shadow with a stripe pattern, parses
  a one-line mode-F DL, observes that the RP's framebuffer mock
  receives the expected SET traffic AND that scan-out from the line
  buffer produces the expected RGB sequence.

**Ship criterion**: tb_mode_f validates pixel content for one full
frame, zero mismatches on either the SET-write or the scan-out side.

### M7 — char modes 2-7  ✓ (modes 2/4/5/6/7; mode 3 ↦ [M11d](#m11d))
<sub><a id="m7"></a>[⤴ status table](#status-at-a-glance)</sub>


- Compositor adds char-mode unpack: 8-px or 16-px char-cell width,
  CHACTL inverse-video / blank, charset_shadow lookup, multi-color
  modes 4-7.
- Per-mode helpers parallel rp-antic's expand.c branches.
- `sim/tb_char_modes.sv` covers each of modes 2-7 in its own band.

**Ship criterion**: zero mismatches across all six modes.

### M8 — graphics modes 8-E  ✓
<sub><a id="m8"></a>[⤴ status table](#status-at-a-glance)</sub>


- Modes 8-E: 1 bpp / 2 bpp, 40/80/160 atari pixel widths.
- Composes alongside mode F + char modes.
- `sim/tb_gfx_modes.sv` covers each of modes 8-E.

**Ship criterion**: zero mismatches across modes 8-E.

### M9 — players, missiles, collision  ✓
<sub><a id="m9"></a>[⤴ status table](#status-at-a-glance)</sub>


Landed in 4 sub-milestones inside `hdl/compositor.sv`:

- **M9-base**: P0 overlay + bit_4 ($10) on PF.
- **M9b**: P1..P3 + missiles M0..M3 (1-line, SIZEP=00, no VDELAY).
- **M9c**: SIZEP / SIZEM scaling (1x/2x/4x), per-channel VDELAY ($D01C),
  2-line PM resolution (DMACTL[4]=0). PM fetch loop covers 6 entities
  to support per-missile VDELAY (current + previous-row missile byte).
- **M9d**: Collision latches — M{i}PF / P{i}PF / M{i}PL / P{i}PL
  accumulate per pixel; HITCLR strobe clears all four 16-bit registers.

`sim/tb_pm.sv` runs five oracle-checked phases: 1x baseline, scaled
SIZEP/SIZEM, 2-line resolution (verifies row 2), VDELAY (verifies row 1
reads row-0 byte), and a collision phase that programs overlapping
P0/P1/M2 to exercise every collision type.

**Ship criterion (met)**: framebuffer matches per-pixel oracle across
all 5 phases; collision latches match the oracle exactly.

**Wiring follow-up**: collision read-back into gtia_regs ($D000-$D00F)
and HITCLR strobe ($D01E) routing — both done in [M-int](#m-int).

### M10 — PRIOR priority modes  ✓ (PRIOR[0:3] + OR-mode)
<sub><a id="m10"></a>[⤴ status table](#status-at-a-glance)</sub>


`hdl/color_resolver.sv` resolves an idx_buf byte + GTIA register state
into an 8-bit Atari hue:luma value. Combinational, no clock — meant to
be instantiated at scan-out time (compositor still writes raw idx_buf
into the FB so PRIOR can be changed mid-frame).

Implemented:
- PRIOR[0]: P0..P3 > PF0..PF3 > BG
- PRIOR[1]: P0,P1 > PF0..PF3 > P2,P3 > BG
- PRIOR[2]: PF0..PF3 > P0..P3 > BG
- PRIOR[3]: PF0,PF1 > P0..P3 > PF2,PF3 > BG
- PRIOR[5] OR-mode (overlapping players → OR'd colours)

`sim/tb_prior.sv` sweeps every PRIOR mode × OR-mode bit × 256 idx_buf
values against an independent SV oracle (2048 cases) plus a handful of
spot checks.

**Follow-ups**:
- PRIOR[7:6] GTIA modes 9 / 10 / 11 — landed in [M10b](#m10b).
- PRIOR[4] PM5: missiles take COLPF3 — needs missile-vs-player split in
  idx_buf. Tracked as [M10c](#m10c).

### M10b — GTIA modes 9/10/11  ✓
<sub><a id="m10b"></a>[⤴ status table](#status-at-a-glance)</sub>


- compositor mode F path dispatches on `prior[7:6]`: when ≠ 00 it emits
  the source nibble (0..15) into idx_buf[3:0] via
  `pack_pair_F_gtia_window`; collision_contribution still sees the
  underlying PF-bit form so collision latches keep working.
- color_resolver decodes the nibble per GTIA mode:
   - 9  (01): `{COLBK[7:4], nibble}` — 16 luma, hue from BK
  - 10 (10): 9-colour palette (nibble 0..3 → COLPM0..3, 4..7 →
     COLPF0..3, 8..15 → COLBK)
  - 11 (11): `{nibble, COLBK[3:0]}` — 16 hues, luma from BK
- PRIOR[1] / PRIOR[3] degenerate cleanly in GTIA mode (no PF-hi/lo
  split since there's only one PF colour).
- tb_prior sweeps every (PRIOR mode × {normal, OR, GTIA9, GTIA10,
  GTIA11} × 256 idx) combination against an independent SV oracle plus
  spot checks. tb_scroll Phase C drives compositor mode F with PRIOR=$40
  (GTIA 9), known nibble pattern in PF source, and verifies
  u_mock.fb[atari_x] holds the right nibble per the 4-px-wide GTIA
  pixel rule.

### M10c — PM5 (PRIOR[4]) + missile/player split in idx_buf  ✓
<sub><a id="m10c"></a>[⤴ status table](#status-at-a-glance)</sub>


PRIOR[4] makes missiles colour as COLPF3 instead of their player
colour. That requires distinguishing missile from player at resolve
time, which the existing 8-bit idx_buf encoding (P|M shared per
channel) can't do.

Widening, end-to-end:
- idx_buf is now **12 bits** per atari pixel:
   - bits [3:0]   = PF source / GTIA nibble (unchanged)
  - bits [7:4]   = P|M shared (unchanged — legacy)
  - bits [11:8]  = M-only nibble (NEW)
- `compositor.cmd_data` widened **16 → 24 bits** = 2× 12-bit pixels.
  M-only nibbles sit in the TOP byte so a legacy 16-bit driver that
  zero-extends still produces the correct legacy-byte encoding in
  the bottom 16 bits. Layout:
  `{m_hi[3:0], m_lo[3:0], hi_byte[7:0], lo_byte[7:0]}`.
- `rp_tx.cmd_data` widened to match; `bus_payload` was already 24-bit.
- `rp_bus_mock.fb[]` widened from 8 → 12 bits per cell. SET stores
  the M-only nibble in the top 4 bits of each cell. FETCH stays
  16-bit (returns the bottom byte of each cell) so the legacy
  tb_prefetch byte-pattern test path still works.
- `color_resolver.idx_buf` widened to 12 bits. PM5 routes the M-only
  nibble through a "missile becomes PF3" path: any missile bit set
  fires `pf3_eff` so the missile colours as COLPF3 and slots into
  the PF-lo group for PRIOR[3] split semantics. PM5 also masks the
  P|M-shared player bit when its corresponding M-only bit is set,
  so the player slot doesn't double-paint.

`sim/tb_prior.sv` gains 6 PM5 spot checks: M-only → COLPF3, P-only
→ COLPM unchanged, M+P overlap → COLPF3 wins, P0 + M2 in PRIOR[0]
→ P0 wins (player priority over PF-level missile), PM5 + PRIOR[2]
→ missile wins (PF over PM), legacy non-PM5 missile → COLPM2.

All 16 sims pass — the legacy 16-bit cmd_data path is preserved by
`tb_rp_bus` zero-extending its 16-bit data into 24-bit for the
widened cmd_data port. Existing tb_pm / tb_visual / tb_scroll keep
verifying `u_mock.fb[i] === 8'hXX` because the bottom 8 bits of
each 12-bit fb cell still hold the legacy P|M-shared encoding.

Compositor instantiation in antic_top now feeds the resolver a
12-bit idx_buf assembled from `{rp_bus_payload[23:20],
rp_bus_payload[7:0]}` — top nibble = M-only, bottom byte = legacy.

### M11 — HSCROL / VSCROL / fine scrolling  ✓ (mode F + start-of-block VSCROL)
<sub><a id="m11"></a>[⤴ status table](#status-at-a-glance)</sub>


Landed as two sub-milestones:

- **M11a**: HSCROL for mode F via a 16-bit shift register
  ({cur_byte, next_byte}). Per-row pre-fetch at LMS+hs_byte_offset
  then per-unit fetch of the next byte; pack_pair_F_window extracts
  pixels at offset (15 - hs_sub_byte - 2p). Graphics modes 8-E and
  char modes 2-7 still go through the legacy single-byte path —
  they ignore HSCROL.
- **M11b**: VSCROL start-of-block sub_row offset. dl_parser tracks
  prev_vscrol_q and seeds sub_row at VSCROL value when entering a
  VSCROL block. Subsequent rows in the block render full 0..scan_count-1.

`sim/tb_scroll.sv` covers HSCROL ∈ {0, 1, 4, 7, 15} on a known-
pattern mode-F line plus a 3-line VSCROL block test.

**Follow-ups**:
- HSCROL for graphics modes 8-E — tracked as [M11c](#m11c).
- HSCROL for char modes 2-7 + VSCROL last-row truncate +
  mode 3 descender — tracked as [M11d](#m11d).

### M11c — HSCROL for graphics modes 8-E  ✓
<sub><a id="m11c"></a>[⤴ status table](#status-at-a-glance)</sub>


All byte-source modes (F + 8 / 9 / A / B / C / D / E) now go through
the same HSCROL-aware shift-register path. Mode dispatch happens at
pack time:

- `pack_pair_F_window` / `pack_pair_F_gtia_window` — mode F (existing
  from M11a + M10b), now take a 5-bit `hs_sub` input.
- `pack_pair_gfx_window` — NEW. Dispatches on mode for the per-byte
  pixel unpack via `gfx_pixel_extract`:
   - mode 8: 8 atari/cell, 4 cells/byte (32 atari/byte) — 2bpp via mode4_pixel
   - mode 9: 4 atari/bit, 8 bits/byte (32 atari/byte) — 1bpp
   - mode A: 4 atari/cell, 4 cells/byte (16 atari/byte) — 2bpp
   - modes B / C: 2 atari/bit, 8 bits/byte (16 atari/byte) — 1bpp
   - modes D / E: 2 atari/cell, 4 cells/byte (8 atari/byte) — 2bpp

`hs_sub_atari` widened from 3-bit (mode-F-only) to 5-bit because
modes 8 / 9 push it up to 30 atari px. `hs_byte_offset` is now
mode-dependent in `S_LATCH_META`:

```
F / D / E (8 atari/byte):    byte_off = hscrol[3:2], sub = {hscrol[1:0], 0}
A / B / C (16 atari/byte):   byte_off = {0, hscrol[3]}, sub = {hscrol[2:0], 0}
8 / 9 (32 atari/byte):       byte_off = 0, sub = {hscrol, 0}
```

The legacy `S_F_FETCH_BYTE` path is retired — gfx modes 8-E now go
through `S_HS_*` even when HSCROL is disabled (PRE fetch costs one
extra byte per row, same trade-off as mode F).

`tb_scroll` Phase D adds three gfx-HSCROL cases:
- mode 8 + HSCROL=4 (byte-aligned 8-atari shift)
- mode 9 + HSCROL=7 (sub-bit shift, 14 atari px)
- mode B + HSCROL=4 (cross-byte boundary in 16-atari/byte mode)

Each verifies all 320 atari px against an oracle that mirrors
`gfx_pixel_extract`. Required widening source-pattern load to 48
bytes (was 12) to cover mode B / C's 20 source + HSCROL spill.

**Ship criterion (met)**: 16/16 sims pass; gfx-HSCROL phases match
the per-mode oracle exactly across the test patterns.

### M11d — HSCROL for char modes 2-7 + VSCROL last-row truncate + mode 3 descender  ⏳
<sub><a id="m11d"></a>[⤴ status table](#status-at-a-glance)</sub>


Three char-mode-shaped follow-ups bundled into one milestone — they
share the dl_parser + char-mode compositor surface area.

- **HSCROL for char modes**: each unit needs char-code AND glyph
  fetched for the *next* char as well, so a sub-byte shift can pull
  bits from across a glyph boundary. Doubles the per-unit fetch
  count (code + glyph + next-code + next-glyph). Same shift-register
  pattern as [M11a](#m11) but at glyph granularity.
- **VSCROL last-row truncation**: dl_parser needs DL-line lookahead
  to know "this is the last VSCROL row before a non-VSCROL line".
  When detected, scan_count is replaced by VSCROL so the row emits
  only `vscrol` atari rows. Probably easiest with a one-DL-line
  buffer in the parser FSM.
- **Mode 3 descender**: char codes ≥ 96 in mode 3 wrap their glyph
  rows differently — the bottom 2 scan lines come from the *top* of
  the glyph (descender hack). Added to the existing char-mode
  glyph_row computation; deferred from [M7](#m7).

**Ship criterion**: tb_char_modes grows phases for HSCROL on each
char mode + an end-of-VSCROL-block truncation case + a mode-3
descender pattern.

### M-int — wire compositor + dl_parser + color_resolver into antic_top  ✓
<sub><a id="m-int"></a>[⤴ status table](#status-at-a-glance)</sub>


So far each compositor-side module has lived only in unit-test
harnesses. `antic_top.sv` still has stub raddrs / unused `*_q` register
outputs. This milestone closes that loop:

- Instantiate `dl_parser`, `compositor`, `color_resolver` inside
  `antic_top` and route them to the existing register file outputs.
- Wire the collision latches (mpf_q/ppf_q/mpl_q/ppl_q + hitclr) back
  into `gtia_regs` so $D000-$D00F reads return live collision state
  and a $D01E write asserts hitclr for one cycle.
- Stand up a minimal SDC under `efinity/constraints/` declaring
  `bus_clk` / `pix_clk` / `rp_tx_clk` / `rp_rx_clk` periods so the
  Efinity PnR + STA flow returns a real fMax.
- Smoke-synth via `./efinity/run.sh pnr` and capture the timing
  report's worst-slack endpoint.

**Ship criterion**: `antic_top` synthesises with no unconnected ports;
PnR completes; timing report attached to the commit message.

Lives between M11 and the deferred-feature catch-up (M10b + the M9
gtia_regs read-back wiring) so we have a real synthesis baseline
before doing the wider-idx_buf and PM5 work.

## Phase 4 — interrupts & sync

### M12 — DLI / VBI / NMI  ✓
<sub><a id="m12"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/nmi_gen.sv` latches NMIST bits and drives /NMI low whenever
  any unacked interrupt is set.
   - VBI: pulses on `vbi_start` from vbeam, gated by `NMIEN[6]` ($D40E).
  - DLI: pulses on `line_start` for any atari_row whose
     `line_dli[r]` (from dl_parser) is set, gated by `NMIEN[7]`.
  - $D40F write strobes `nmires_strobe` from antic_regs which clears
     NMIST. Set-and-clear in the same cycle: SET wins (the firing
     interrupt is preserved; CPU has to ack again).
- `hdl/dl_parser.sv` gains a second read port (`dli_row` → `dli_at`)
  for nmi_gen; the existing `meta_row` port is untouched.
- `hdl/antic_regs.sv` exposes `nmires_strobe` (1-cycle pulse on $D40F
  write).
- `sim/tb_nmi.sv` builds a DL with DLI on row 1, drives line_start /
  vbi_start pulses by hand, walks 5 phases:
  1. NMIEN[7] only — DLI fires on row 1, /NMI low, NMIRES clears.
  2. NMIEN[6] only — VBI fires, NMIRES clears, DLI is masked.
  3. NMIEN=$00 — neither fires.
  4. NMIEN=$C0 — both fire, NMIST=$C0.
  5. NMIRES + new DLI in same cycle → set wins, NMIST=$80.

**Wiring follow-up**: nmi_gen is built and unit-tested but not yet
instantiated in `antic_top.sv` because vbeam isn't there yet either.
Both wire in together at [M14](#m14) when the scan-out path lands —
that's when vbeam needs to be in the bus_clk domain anyway, with the
2-FF synchroniser for cross-domain pulses.

**Ship criterion (met)**: 5/5 phases pass; module + dl_parser DLI
read-port verified.

### M13 — WSYNC / RDY  ✓
<sub><a id="m13"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/wsync_gen.sv` latches /RDY low when `wsync_pending` pulses
  (one cycle after the CPU writes $D40A) and releases on the next
  vbeam `line_start`. Same-cycle WSYNC + line_start: WSYNC wins so
  /RDY stays low one extra scan line — matches Atari "WSYNC at hsync
  still stalls" behaviour.
- Diagnostic: `wsync_overdue_count` ticks each cycle that /RDY has
  been held low for more than `OVERDUE_THRESHOLD` clk_bus cycles
  (default 256 ≈ one full Atari scan line). Real ANTIC always
  releases by the next hsync; the counter flags vbeam misconfig.
- `sim/tb_wsync.sv` runs four phases: idle, assert+release,
  coincident WSYNC + line_start (set wins), overdue counter ticks
  when line_start is withheld past threshold.

**Wiring follow-up**: like nmi_gen, wsync_gen is built and unit-
tested but not yet instantiated in `antic_top.sv` — it joins the
party at [M14](#m14) when vbeam lands and the diag_wsync_overdue
output gets a real driver.

**Ship criterion (met)**: 4/4 phases pass; assert/release timing
correct, overdue counter advances under fault-injection.

## Phase 5 — output flexibility

### M14 — palette LUT + chiplet-ext writes  ✓
<sub><a id="m14"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/palette_lut.sv` is a 256-entry × 24-bit RAM. The Atari hue:luma
  byte from `color_resolver` indexes RGB888 out. 1-cycle registered
  read; `INIT_FILE` parameter loads a default palette via `$readmemh`
  at elaboration time.
- `hdl/antic_regs.sv` exposes the chiplet-ext write path:
   - $D483 latches PAL_R, $D484 latches PAL_G, $D485 latches PAL_B
   - $D486 commits `{PAL_R, PAL_G, PAL_B}` into entry IDX (= written
    value) via a one-cycle `pal_write_strobe` pulse.
- Two reference palettes ship in `hdl/palette/`:
   - `atari_ntsc.hex` — NTSC hue wheel
  - `atari_pal.hex` — PAL hue wheel (rotated, slightly desat)
  Either can be picked at synth time; firmware can swap regions by
  re-pushing the other table over the chiplet-ext writes (~1 ms at
  1.79 MHz bus). See [docs/palette.md](palette.md).
- `sim/tb_palette.sv` writes 3 spot entries, sweeps all 256 entries
  with unique values, reads them all back, then verifies a rewrite
  takes effect. 16/16 sims pass after this lands.

**Wiring follow-up**: `palette_lut` instantiation in `antic_top.sv`
is bundled with the M14b scan-out wiring (vbeam + color_resolver →
palette_lut → TMDS encode), since the read port belongs in the
pix_clk domain and that's M14b's main job.

**Ship criterion (met)**: 256/256 palette entries write/read clean.

### M14b — TMDS encoder + serializer (HDMI/DVI output)
<sub><a id="m14b"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/tmds_encode.sv` — pix_clk-domain 10b/8b TMDS encoder per the
  DVI 1.0 spec. Three instances (one per R/G/B channel). During
  active video, encodes the 8-bit pixel value into a 10-bit symbol
  with bounded DC balance. During blanking, emits the appropriate
  control word (HSYNC/VSYNC encoded into the blue channel; R + G
  channels emit fixed control symbols).
- `hdl/tmds_serialize.sv` — wraps the Efinix vendor SerDes IP
  (`OSER10` / equivalent) to serialize each channel's 10-bit symbol
  at 5× pix_clk onto a differential pair. Produces TMDS_DATA[2:0] +
  TMDS_CLK pads.
- `hdl/pll_pix.sv` — PLL configuration generating clk_pix (25.175 MHz
  for 640×480, 40 MHz for 800×600) and clk_tmds (5× clk_pix) from the
  bus reference clock.
- `sim/tb_tmds.sv` — instantiates a TMDS *decoder* alongside the
  encoder, runs a known RGB pattern through encoder → decoder, and
  verifies the round-trip RGB matches input pixel-exact. Decoder is
  testbench-only (no synthesis target) — exists to validate encoder
  conformance.
- note that the clock and all data lines need to be from one 'side' of the FPGA, they need to be associated to remain coherent

**Ship criterion**: encoder produces 10-bit symbols with correct
disparity-balanced encoding (per DVI spec); decoder recovers the
original RGB across a 1-frame stripe pattern with zero mismatches.
At M19 (Efinity P&R), the synthesised SerDes drives real pads at
250 MHz (640×480) / 200 MHz (800×600) and timing closes.

Why it's here: M0..M14 produces RGB888 on `pix_r/g/b` in the pix_clk
domain — that's the "video output" sim sees. TMDS sits between that
RGB and the actual HDMI pads. Sim doesn't need it; silicon does.

### M15 — output-mode 800×600
<sub><a id="m15"></a>[⤴ status table](#status-at-a-glance)</sub>


- $D482 OUTPUT_MODE write reconfigures vbeam at next vsync to
  800×600@60 timing (40 MHz pix_clk, ANTIC wide playfield → 752 px,
  pillarbox 24 px each side).
- ANTIC narrow / standard remain on 640×480.
- Line-buffer prefetch budget retuned for the wider line.
- `sim/tb_output_mode.sv` toggles the register and validates timing
  on both sides of the switch.

**Ship criterion**: scan-out timing valid in both modes; mode-flip
takes effect on the cycle following the next vsync. Prefetch budget
holds at 800×600.

## Phase 5b — Audio

Not strictly an ANTIC requirement, but since the FPGA is producing
the TMDS, it has to mux POKEY audio into the HDMI stream too. POKEY
emulation lives on the partner RP2354 (the PSG chiplet) and produces
an I2S stream into the FPGA, where it would be packetised into HDMI
data islands. M23-7 collapsed this path: POKEY now feeds the audio
packetiser directly inside the fabric, no I2S serial wires required.

Architecture (post-M23-7):

```
  pokey ch1..4 --> pokey_i2s_tx --> hdmi_pkt_source --> hdmi_packet --> hdmi_out
                  (M23-7)           (M15b-3)            (M15b-3)        (M15b-4)
                                                           |
   terc4_encoder (M15b-2) for the data-island             /
   period; hdmi_bch (M15b-3) for header + subpacket ECC.
```

The output stream upgrades from DVI (M14b/M15) to HDMI: same TMDS
encoder for active video, but blanking is now sequenced through
control / preamble / guard-band / data-island periods carrying
audio samples + an AVI InfoFrame + an Audio InfoFrame.

### M15b-1 — i2s_rx (superseded by M23-7)
<sub><a id="m15b-1"></a>[⤴ status table](#status-at-a-glance)</sub>

Originally shipped as a stereo I2S receiver (24-bit, 32-bit-slot
tolerant) for an external audio source. **Removed at M23-7** when the
POKEY → audio-packetiser path moved fully inside the fabric and the
external I2S pins were dropped from the package allocation.

`hdl/i2s_rx.sv` and `sim/tb_i2s.sv` were deleted. If a future external
audio input is ever needed, the design can be resurrected from the
git history (commit `e1f1337` and earlier).

### M15b-2 — terc4_encoder  ✓
<sub><a id="m15b-2"></a>[⤴ status table](#status-at-a-glance)</sub>

- HDMI 1.4a §5.4.2 / Table 5-7 4-bit-to-10-bit encoder used during
  the data island period.
- Pure combinational LUT — the spec defines a fixed mapping (no
  running disparity, unlike TMDS 8b/10b).
- Each entry has exactly 5 ones and 5 zeros (DC-balanced).
- `sim/tb_terc4.sv` sweeps 0x0..0xF and checks both the spec values
  and the 5/5 popcount.

### M15b-3 — hdmi_packet (with hdmi_bch ECC)  ✓
<sub><a id="m15b-3"></a>[⤴ status table](#status-at-a-glance)</sub>

- `hdmi_bch.sv` — combinational BCH(g(x) = x^8 + x^7 + x^6 + x^4 + 1)
  encoder. Two flavours: 24→8 (header) and 56→8 (each body
  subpacket). Verified against an in-test software reference in
  `sim/tb_hdmi_bch.sv`.
- `hdmi_packet.sv` — packs `(pkt_type, hb1, hb2, sp[0..3])` + ECC
  into 32 cycles of `(lane0, lane1, lane2)` 4-bit nibbles per HDMI
  Table 5-1: blue carries hsync/vsync + first-cycle marker + header
  bit; green/red split each subpacket bit-pair (green = even
  positions, red = odd).
- `hdmi_pkt_source.sv` — produces the packet content tuple for the
  five packet types we emit:
  - **Null** (Type 0x00): all zeros.
  - **Audio Clock Regen** (Type 0x01): N=6144, CTS=40000 for 48 kHz
    audio at the M15 40 MHz pixel clock. Parameterizable (N_VALUE,
    CTS_VALUE) for other modes.
  - **Audio Sample** (Type 0x02): IEC 60958 sub-frame layout per
    subpacket — 24-bit L + 24-bit R, V/U/C stubbed at 0 (consumer
    LPCM), P parity computed via `^{V, U, C, sample}`.
  - **AVI InfoFrame** (Type 0x82): 800×600 RGB full-range, 4:3 aspect.
    Pre-computed checksum PB0 = 0x57.
  - **Audio InfoFrame** (Type 0x84): 2-ch LPCM 48 kHz 24-bit.
    Pre-computed checksum PB0 = 0xF4.
- `sim/tb_hdmi_pkt.sv` covers all 5 packet types — header + payload
  bytes vs. independently-recomputed reference in the testbench
  (the InfoFrame phases re-derive PB0 in-test rather than matching
  a constant). Phase F round-trips an Audio Sample Packet through
  `hdmi_packet` and reconstructs HB0|HB1|HB2|ECC from the per-cycle
  lane-0 bit-3 stream.

Channel status (the 192-bit IEC 60958 block) is stubbed at C=0 for
every frame. Bits 0-1 = "consumer LPCM" — coincidentally correct for
the first 2 frames of any block. Sample rate + word length live in
the Audio InfoFrame, which sinks prefer over channel-status bits, so
this is "spec-violating but accepted in practice." A 192-bit cycler
can layer in if a real sink rejects.

### M15b-4 — hdmi_out — period sequencer  ✓
<sub><a id="m15b-4"></a>[⤴ status table](#status-at-a-glance)</sub>

- Stitches vbeam + 3 tmds_encoders + 3 terc4_encoders + 4 serializers
  + hdmi_pkt_source + hdmi_packet into a full HDMI output path.
- Coexists with `tmds_out.sv`; `tmds_out` stays as the DVI-only mode
  for sink-interop testing.
- Per-line layout (defaults are 800×600@60):
  - h_count 0..799        : `P_VIDEO`        (active RGB → tmds_encoder)
  - 800..811              : `P_CONTROL_F`    (≥12-cycle control)
  - 812..819              : `P_DI_PRE`       (8-cycle data-island preamble — CTL[3:0]=0101)
  - 820..821              : `P_DI_GLEAD`     (2-cycle leading guard band)
  - 822..853              : `P_DATA_ISL`     (32-cycle TERC4 packet payload)
  - 854..855              : `P_DI_GTRAIL`    (2-cycle trailing guard band)
  - 856..1045             : `P_CONTROL_B`    (back-of-line control)
  - 1046..1053            : `P_VID_PRE`      (8-cycle video preamble — CTL[3:0]=0001)
  - 1054..1055            : video guard band (2 cycles)
- Per-lane output mux picks between TMDS-encoded data, TERC4-encoded
  packet payload, or fixed guard-band symbols (HDMI §5.2.2.1 +
  §5.2.3.4) based on a 1-cycle-registered period selector that
  aligns with the TMDS encoder's 1-cycle latency.
- Packet selection is exposed via the `pkt_select` input — the
  caller (eventual integration milestone) rotates the five packet
  types from M15b-3 against an audio-FIFO + per-frame InfoFrame
  pacing policy.
- `sim/tb_hdmi_out.sv` walks one full 800×600 line and verifies:
  - Period schedule: 802 P_VIDEO (incl. 2 video-guard) + 12 P_CTL_F
    + 8 P_DI_PRE + 2 P_DI_GLEAD + 32 P_DATA_ISL + 2 P_DI_GTRAIL +
    190 P_CTL_B + 8 P_VID_PRE = 1056 cycles total.
  - Symbol-type mux: 6 guard-band cycles (= 2×3) emit one of the
    two HDMI guard symbols on lane 0; 32 data-island cycles emit a
    valid TERC4 LUT entry; 1018 remaining cycles use the TMDS
    encoder output.

## Phase 6 — DMA mode parity

### M16 — DMA-mode bus master  ✓
<sub><a id="m16"></a>[⤴ status table](#status-at-a-glance)</sub>


- `hdl/dma_master.sv` — 6502-style bus-master FSM:
  - `S_IDLE` → on `req`: assert `/HALT` immediately, latch `req_addr`,
    pulse `ack`.
  - `S_HALT_WAIT` → wait one phi2 falling edge so the 6502 sees
    `/HALT` low at its sample point and releases the bus.
  - `S_DRIVE` → drive `addr_o` + `rw_o = 1` + `bus_oe = 1` across the
    next phi2 high. On the following phi2 fall, sample the D bus
    into `req_data` and pulse `data_valid`.
  - `S_RELEASE` → release `/HALT`, drop `bus_oe`, return to idle.
  - Total fetch cost: 2 phi2 cycles (≈ 24 fabric cycles at
    CLOCK_MULT=12).
- `sim/tb_dma_master.sv` runs an MMU stub (64 KB synthetic memory
  keyed on address: `mem[a] = (a & 0xFF) ^ (a >> 8)`) through:
  - **Phase A**: a single fetch at `$1234`, verifying
    `req_data == mmu[$1234]` and bus invariants (`bus_oe` only
    while `halt_n` is low; `rw_o == 1` whenever `bus_oe == 1`).
  - **Phase B**: 1024 sequential fetches at `$0000..$03FF`,
    asserting zero mismatches against the oracle.
- Pipelined back-to-back fetches (one /HALT held across multiple
  phi2 cycles) deferred — the simple per-fetch protocol is fine for
  the prefetch budget at 800×600.

**Ship criterion**: zero mismatches across a 1024-fetch DL walkthrough.
✓ Met by `tb_dma_master` Phase B.

### M16-int — DMA / cpu_shadow integration  ✓
<sub><a id="m16-int"></a>[⤴ status table](#status-at-a-glance)</sub>

Three sub-pieces, delivered incrementally:

**M16-int (1/3) — `mem_read_mux.sv`** ✓ (own milestone). Tiny adapter
that routes the consumer's `(mem_raddr, mem_rdata)` port to either
cpu_shadow (1-cycle BRAM) or dma_master (multi-cycle 6502 bus master)
based on `dma_mode`. Snoop mode is pass-through with `caller_ready`
held high. DMA mode runs a 2-state FSM (READY ↔ BUSY): on `caller_req`
it latches the address, fires the dma_master, drops `caller_ready=0`
until `dma_data_valid` lands, then holds the captured byte on
`caller_rdata`. Mode flip mid-stream works because READY is the
quiescent state.

**M16-int (2/3) — `mem_ready` plumbing** ✓. Both `dl_parser` and
`compositor` gained a `mem_req` output (combinational; pulses one
cycle on every FETCH state) and a `mem_ready` input (gates each
WAIT state's advance). All 9 `dl_parser` instantiations + 7
`compositor` instantiations updated to tie `.mem_req()` open and
`.mem_ready(1'b1)` for the existing snoop-only testbenches.

**M16-int (3/3) — antic_top wiring + vsync-aligned mode flip** ✓.
- `dma_arbiter.sv` folds the two consumers' DMA-side ports onto
  the single `dma_master`. Priority arbitration: port 0
  (`dl_parser`) wins over port 1 (`compositor`) on simultaneous
  request — in practice they don't overlap because `dl_parser`
  finishes the DL walk before `compositor` starts the row walk.
- `antic_top` instantiates `2 × mem_read_mux` + `1 × dma_master` +
  `1 × dma_arbiter`, exposes the Atari-side bus pins (`dma_addr_o`,
  `dma_rw_o`, `dma_oe`) at the package boundary. `halt_n` is now
  driven by `dma_master` instead of being tied high.
- `$D481[0]` (already mirrored to `mode_snoop_q`) is sampled at
  `dl_start_pulse` (= proxy for vsync; real VBI tie-in pending) and
  inverted into `dma_mode_q`. dma_mode therefore only changes on
  frame boundaries → no torn-frame transitions.
- Synthetic `phi2` is derived from `clk_bus / 12` (matches
  CLOCK_MULT=12); a real Atari-mode build would receive `phi2` from
  a package-pin input instead.

The full DL-through-both-modes integration tb (Phase D / ship
criterion) is split out as **M16-int-tb** below to keep this
milestone's diff manageable. tb_smoke covers structural integration:
`antic_top` boots through reset, all 25/25 sims still pass.

### M16-int-tb — DL-through-both-modes verification  ✓
<sub><a id="m16-int-tb"></a>[⤴ status table](#status-at-a-glance)</sub>

`sim/tb_dma_int.sv` instantiates dl_parser + compositor + 2 ×
mem_read_mux + dma_arbiter + dma_master + cpu_shadow + an
atari_mem mock + rp_tx + rp_bus_mock. Bypasses antic_top's
periodic kick so the test can drive `dl_start` / `cmp_start`
directly and switch `dma_mode` between frames.

Loads a 1-line mode-F DL + 40-byte PF source into both cpu_shadow
(via the BRAM write port) and atari_mem (combinationally driven
onto bus_data_in when dma_oe is asserted). Runs one frame in
snoop mode, captures the rp_bus_mock fb. Switches dma_mode to 1,
runs another frame, captures fb. Asserts byte-for-byte
identical — 4 KB FB compared, zero mismatches.

Two race-condition fixes that landed during this milestone:

- `mem_req` was originally tied to FETCH state (held high through
  WAIT). Sustained req caused `mem_read_mux` to re-trigger DMAs
  on its `D_BUSY → D_READY` return, fetching the next address
  instead of the requested one. Changed to a one-shot pulse on
  the FETCH→WAIT transition, registered via a `prev_state_was_fetch`
  bit in both dl_parser and compositor.
- `caller_ready` was strictly `(dma_state == D_READY)`. When
  `caller_req` fired in `D_READY`, dl_parser would see ready=1 in
  the same cycle (combinational reads from pre-edge) and advance
  out of WAIT before the new DMA had even started. Changed to
  `(dma_state == D_READY) && !caller_req` so a new req-cycle
  immediately drops ready in the same cycle.

### M16b — HyperRAM-backed cpu_shadow + 130XE bank + cart banks
<sub><a id="m16b"></a>[⤴ status table](#status-at-a-glance)</sub>


Move system memory off BRAM into an external HyperRAM via the Efinix
HyperRAM Controller IP (Topaz/Titanium). Graphics memory stays on
the RP2354 — RP keeps its software-GPU role for [M17](#m17) /
[M18](#m18). See
[fpga-part-selection.md](fpga-part-selection.md#architectural-pivot-on-board-hyperram-for-system-memory-only).

Three sub-milestones:

#### M16b-1 — hyperram_shim foundation  ✓
<sub><a id="m16b-1"></a>[⤴ status table](#status-at-a-glance)</sub>

- `hdl/hyperram_mock.sv` — sim-only model of the Efinix HyperRAM
  Controller IP. Parameterised read latency (LATENCY clk cycles);
  combinational `rd_data` / `rd_valid` from the head of an
  N-deep shift pipeline. Writes complete in ≈1 cycle. cmd_ready
  drops while a read is in flight (single outstanding read).
  In synth this module is replaced by the vendor IP behind the
  same protocol.
- `hdl/hyperram_shim.sv` — dual read-port + write-port wrapper:
  - Two read request ports `(req_a/raddr_a/rdata_a/rd_valid_a/ready_a)`
    + matching `_b` signals. Each port has a single in-flight
    request slot — caller stalls until `rd_valid_*` returns.
  - One write port `(we, waddr, wdata, wready)`. A 1-deep write
    FIFO absorbs the cycle between bus_snoop's combinational
    `we` pulse and the shim's command issue. NBA ordering: drain
    happens before capture in the same always_ff body, so a
    same-cycle drain + capture leaves wfifo_full = 1 (last write
    wins).
  - Priority arbitration onto the single HyperRAM channel:
    write-FIFO drain > port-A read > port-B read.
  - `tag_pipe_valid[TAG_DEPTH-1:0]` tracks who owns each
    in-flight read. TAG_DEPTH = LATENCY + 1 to absorb the 1-cycle
    skew between the shim's registered `cmd_valid` and the mock's
    `pipe_valid` injection.
- `sim/tb_hyperram.sv` covers Phase A (16 writes + 16 reads on
  port A round-trip), Phase B (8 dual-port read pairs A+B
  alternating), Phase C (write-then-read coherence).

#### M16b-2 — 130XE PORTB banking  ✓
<sub><a id="m16b-2"></a>[⤴ status table](#status-at-a-glance)</sub>

- `hdl/bank_translator.sv` — combinational logical→physical address
  remap. Outside `$4000-$7FFF` and any time `bank_en=0`, the
  16-bit logical address passes through into the lower 64 KB of
  the physical map. Inside the window with `bank_en=1`, the
  address is remapped into one of four 16 KB extended banks
  starting at physical `$10000`:
  ```
  physical = $10000 | (bank_idx[1:0] << 14) | logical[13:0]
  ```
- One translator instance per port: the CPU side (write port)
  uses `bank_en = !PORTB[4]`, the two ANTIC sides (dl_parser /
  compositor reads) use `bank_en = !PORTB[5]`. Bank index for
  both contexts comes from `PORTB[3:2]`.
- `sim/tb_bank.sv` runs five phases through the translator +
  `hyperram_shim`:
  - **A** banking off (PORTB=$FF) — pass-through writes/reads.
  - **B** CPU banked / ANTIC main — write to bank 0 at logical
    `$4100`, ANTIC reads main and sees the pre-loaded value;
    flipping ANTIC into the same bank reveals the new write.
  - **C** ANTIC banked / CPU main — mirror of B.
  - **D** both banked, same idx — write via CPU lands at the
    same physical addr ANTIC reads.
  - **E** bank-index switching — four writes at logical `$6000`
    via four different bank indices land at four distinct
    physical addresses; reads through each idx return the matching
    sentinel ($66/$77/$88/$99).

#### M16b-3 — Cartridge banking  ✓
<sub><a id="m16b-3"></a>[⤴ status table](#status-at-a-glance)</sub>

`bank_translator` extended with a second banking layer (cart) that
sits below the 130XE PORTB layer. Two cart-window flavours
selected by `cart_size_16k`:
- **8 KB cart** at `$A000-$BFFF`: 16 banks × 8 KB at physical
  `$20000 + idx*8K + offset[12:0]`. Used by Atari's stock 8K
  carts and many homebrews.
- **16 KB cart** at `$8000-$BFFF`: 16 banks × 16 KB at physical
  `$20000 + idx*16K + offset[13:0]`. Used by "big cart" /
  Bounty Bob / OSS / Atarimax schemes — the bank-control register
  driving `cart_idx` is cart-specific (typically a write to a
  magic address in `$D500`), not part of this module.
- The PORTB and cart windows don't overlap, so a single translator
  instance handles both. Pass-through to the low 64 KB applies
  any time neither banking system is active for the access.

`sim/tb_bank` adds two phases on top of the PORTB tests:
- **F** — 8 KB cart, 4 distinct bank indices write/read distinct
  sentinels at logical `$A100` ($A0/$A5/$AA/$AF), no aliasing
  with main RAM.
- **G** — 16 KB cart at idx 3 vs idx 7, two offsets within each
  bank ($8200 + $A200 = upper + lower halves of the 16 KB
  window), four sentinels at four distinct physical addresses.

The framebuffer-side ship criterion (banked-RAM test case rendered
correctly through dl_parser + compositor) lands when the M16b
modules are wired into antic_top — covered as **M16b-int**, the
mirror of M16-int for the HyperRAM path.

## Phase 7 — DRAW accelerators (optional, after basic close)

### M17 — RECT / FILL / LINE
<sub><a id="m17"></a>[⤴ status table](#status-at-a-glance)</sub>

Rolled up from sub-milestones. The original sketch (single bullet
list) is decomposed below as M17-1..M17-N.

#### M17-1 — rp_tx DRAW emission  ✓
<sub><a id="m17-1"></a>[⤴ status table](#status-at-a-glance)</sub>

- `hdl/rp_tx.sv` extended with a second host port (`draw_cmd_*`) plus
  a `draw_full` back-pressure input. Internally the FSM gains an
  `S_DRAW` state that emits the per-opcode beat sequence (1 beat for
  NOP_DRAW; 5 for LINE / RECT / FILL; 4 / 6 for CIRCLE / ARC at M18)
  one beat per `clk` with `bus_tag = BUS_TAG_DRAW`.
- Beat layout matches the wire-protocol DRAW table:
  - beat 0: `{ arg0[15:0], op[7:0] }`
  - beats 1..N-1: `{ 8'h00, argK[15:0] }`
- `draw_full` mid-sequence stalls the FSM (emits NOP, holds the beat
  counter) — option-A atomic, no FETCH/SET interleave during a DRAW
  pause; revisit if RP-side queue depth makes this matter.
- Invalid opcodes (anything outside the BUS_DRAW_OP_* table) trap
  into `tx_draw_op_invalid_count` and are silently dropped — emitting
  an unknown beat-count would desync the RP-side decoder.
- `hdl/bus_opcodes.vh` ships the `BUS_DRAW_OP_*` constants in sync
  with the wire-protocol doc.
- `sim/tb_draw.sv` covers all three M17 opcodes (+ NOP_DRAW), the
  draw_full stall path, the invalid-op trap, and FETCH/SET interop
  after DRAW.

#### M17-2 — chiplet-ext DRAW register port  ✓
<sub><a id="m17-2"></a>[⤴ status table](#status-at-a-glance)</sub>

- `hdl/draw_regs.sv` — chiplet-extension register block exposing
  software-driven DRAW at `$D488-$D493`:
    - `$D488` DRAW_OP, `$D489-$D492` 5× 16-bit args (LO/HI),
      `$D493` DRAW_GO (write to commit; read returns pending bit).
  Internally latches op + args + a `pending` flag; dispatches to
  `rp_tx`'s draw port via a 1-cycle pulse on `draw_cmd_valid` when
  rp_tx is ready. Software polls DRAW_GO[0] for back-pressure.
- `hdl/antic_top.sv` — instantiates `draw_regs` alongside `antic_regs`
  and merges its read data into the chiplet-ext bus mux. `rp_tx`'s
  draw port now hooks straight onto the dispatch outputs (no longer
  tied off). `draw_full` stays at `1'b0` until M17-3 surfaces the RP
  back-pressure pin.
- `sim/tb_draw_regs.sv` covers stage + dispatch sequencing, the
  pending semantics under stuck `draw_cmd_ready=0`, the back-to-
  back-GO-while-pending lost-write contract, and full read-back of
  staged op + args.

**SDC follow-up**: M17-2's added clk_bus-domain logic shifted PnR
placement enough to lengthen ram_clk's IP-internal critical path
(see `docs/synth-results.md` row M17-2). Loosened the SDC's clk_bus
target from 6.5 ns → 10 ns to give PnR more freedom on ram_clk; the
Atari workload only needs ~21.5 MHz on clk_bus, so 100 MHz / 135 MHz
achieved is still ~6× headroom. ram_clk closes at 202.5 MHz. A
follow-up refactor — moving DRAW arg storage from `rp_tx` into
`draw_regs` (eliminates ~80 FF of duplicate latches) — is on the
list when later M17/M18 work erodes the now-narrow ram_clk slack.

**Compositor pattern detector** is split out as a separate sub-
milestone and is NOT part of M17-2 — chiplet-ext is the simpler
unblock for software-driven DRAW.

#### M17-3 — RP-side DRAW handler  ✓
<sub><a id="m17-3"></a>[⤴ status table](#status-at-a-glance)</sub>

- `rp/video/src/draw.h` + `rp/video/src/draw.c` — self-contained dispatcher +
  primitive renderers. One `draw_beat(ctx, payload)` call per
  DRAW-tagged bus beat; internally tracks the per-opcode beat
  sequence and executes the primitive on the last beat. FB is
  caller-provided (production = PSRAM, test = host array).
- Primitives: `FILL` (memset-per-row), `RECT` (1-pixel outline),
  `LINE` (Bresenham), `NOP_DRAW` (counter-only). All clip silently
  to FB extent; out-of-bounds pixels are dropped without trap.
- `rp/video/src/bus_server.h` — `BUS_DRAW_OP_*` constants alongside
  `BUS_TAG_*`. Cross-checked against `hdl/bus_opcodes.vh` by the
  `rp/video/sim/Makefile` `verify` target (extended to handle SV's
  `8'dN` width-prefix syntax).
- `rp/video/sim/tb_bus_pio.c` — host C test extended with phases 3-8 that
  exercise FILL / LINE / RECT / NOP_DRAW + invalid-opcode trap +
  clipping. Each pixel-rendering phase compares the model FB
  byte-for-byte against an oracle that mirrors the same algorithm.
- The production glue (PIO drain → tag dispatch → `draw_beat`)
  lands at M21; for M17-3 the dispatcher + renderers are built and
  verified, ready for that hookup.

**Open follow-ups** (future, not blocking M17 ship):

- `draw_full` back-pressure pin from RP to FPGA — surface as a
  top-level antic_top input when RP firmware lands at M21; until
  then the FPGA's `draw_full` is tied to 0.
- PIO-side fast path for RECT-fill, if profiling shows it's needed.

#### M17-1.1 — FILL semantics fix + op[7] fill flag  ✓
<sub><a id="m17-1-1"></a>[⤴ status table](#status-at-a-glance)</sub>

Discovered post-M17-3 that the original wire-protocol DRAW table had
FILL listed as a 5-beat filled-rectangle primitive (x/y/w/h/colour).
That was a mistake — FILL is paint-bucket flood-fill (seed point +
new colour). Fixed in this sub-milestone:

- `hdl/bus_opcodes.vh` — FILL is now 3 beats; added `BUS_DRAW_FILL_FLAG`
  (`8'h80`); reserved opcode IDs for OVAL / ARC / BEZIER / BEZIER_TO
  with the new naming (CIRCLE removed — it's a degenerate OVAL).
- `hdl/rp_tx.sv` — `draw_beats()` masks `op[7]` before lookup so
  paired ops share an entry; FILL → 3 beats; OVAL/ARC/BEZIER trap as
  unknown until M18 extends the arg storage to ≥ 7 args.
- `rp/video/src/draw.c` — replaced the bogus filled-rect `draw_fill()` with
  a scanline (Heckbert) flood-fill. Push row-segment seeds onto an
  explicit 256-deep stack rather than per-pixel; bounded depth +
  cache-friendly. Stats keyed by base op (op[6:0]) so paired ops
  count as one. Filled-rect splits out as `draw_rect_filled()`,
  selected via `op[7]`.
- `rp/video/src/bus_server.h` — opcode IDs mirror the SV side; added the
  fill-flag mask + a clarifying comment about FILL's flood-fill
  semantic.
- `rp/video/sim/tb_bus_pio.c` — Phase 3 / Phase 8 now drive RECT-fill
  (`op | 0x80`); new Phase 9 paints a RECT outline as a boundary,
  flood-fills the interior from a centre seed, and verifies the
  outline + interior match the oracle.
- `sim/tb_draw.sv` — Phase C split into RECT (outline) / RECT-fill
  (`op|0x80`) / FILL (flood, 3 beats). Phase D (back-pressure stall)
  retargeted at RECT-fill since FILL's 3 beats are too short to
  demonstrate a useful mid-sequence stall.
- `docs/wire-protocol.md` + `docs/register-map.md` — DRAW table
  rewritten with the new op layout and FILL semantics.

**Ship criterion (M17 overall)**: each opcode's resulting framebuffer
state matches a CPU-composited reference (tb_draw_e2e under sim, or
RP-loop test in hardware); round-trip latency under the per-frame
budget.

### M18 — OVAL / FILLED OVAL / ARC / PIE
<sub><a id="m18"></a>[⤴ status table](#status-at-a-glance)</sub>

Decomposed into M18-1 (OVAL — fits in current rp_tx 5-arg storage)
and M18-2 (ARC, needs 7 args → rp_tx storage extension).

#### M18-1 — OVAL outline + fill  ✓
<sub><a id="m18-1"></a>[⤴ status table](#status-at-a-glance)</sub>

- `hdl/rp_tx.sv` — `BUS_DRAW_OP_OVAL` added to `draw_beats()` (5 beats:
  cx, cy, rx, ry, colour). `op[7]=1` → filled.
- `rp/video/src/draw.c`:
  - `draw_oval_outline()` — midpoint ellipse algorithm, integer-only,
    4-way symmetric. Walks region 1 (|dy/dx|<1) then region 2.
    Degenerate cases (rx=0, ry=0, or both) fall through to a 1-pixel
    or thin-line render.
  - `draw_oval_filled()` — per-row span fill. Half-width per scanline
    `dy` is `isqrt(rx² · (ry² − dy²) / ry²)` via a 32-iter Newton's
    `isqrt_l()` (no FPU on RP2354's fast path).
- `rp/video/sim/tb_bus_pio.c` — Phases 10 / 11 / 12: outline ellipse,
  filled circle (rx==ry), filled ellipse with bottom-right clipping.
  Each phase compares the model FB byte-for-byte against an oracle
  duplicating the same algorithm.
- `sim/tb_draw.sv` — Phase C.4 (OVAL outline) + C.5 (OVAL fill via
  `op | 0x80`) verify rp_tx serialises the 5-beat sequences correctly.

Circle isn't a separate primitive — `OVAL` with `rx == ry`
degenerates to one. No CIRCLE opcode.

#### M18-2 — ARC + PIE  ✓
<sub><a id="m18-2"></a>[⤴ status table](#status-at-a-glance)</sub>

- `hdl/rp_tx.sv` — args storage extended 5 → 7 (`d_arg5`, `d_arg6`).
  Beat-payload mux extended to idx 5/6. `BUS_DRAW_OP_ARC` added to
  `draw_beats()` (7 beats: cx, cy, rx, ry, start_angle, end_angle,
  colour). `BUS_DRAW_OP_BEZIER_TO` also added (7 beats) so the
  M18.1 wire shape is reserved.
- `hdl/draw_regs.sv` — chiplet-ext window extended 12 bytes → 16
  bytes. `$D494-$D497` are `DRAW_ARG5_LO/HI` and `DRAW_ARG6_LO/HI`.
  DRAW_GO stays at `$D493` so software submitting M17/M18-1
  primitives is unaffected.
- `rp/video/src/draw.c`:
  - `point_in_arc(dx, dy, start, span)` — polar-angle test using
    `atan2f` + uint16 wrap-around arithmetic. ~20 µs/call on
    RP2354 with newlib soft-FP. Sin/cos LUT + cross-product is
    the obvious follow-up if profiling demands it.
  - `draw_arc_outline()` — same midpoint-ellipse walk as OVAL,
    each of the 4 reflected pixels gated by `point_in_arc`.
  - `draw_pie()` — per-scanline span over the bounding ellipse;
    every interior pixel that passes the angle gate paints.
    Selected via `op[7]=1`.
- `DRAW_MAX_ARGS` bumped 5 → 7 in `draw.h`.
- Tests:
  - `sim/tb_draw.sv` — Phase C.6 (ARC, 7 beats) + C.7 (PIE,
    `op | 0x80`) verify rp_tx serialises the new 7-beat sequence
    over the bus.
  - `sim/tb_draw_regs.sv` — instantiation extended for the new
    `arg5`/`arg6` ports; existing phases still pass.
  - `rp/video/sim/tb_bus_pio.c` — Phase 13 (ARC outline, 0°-90° quarter
    sweep) + Phase 14 (PIE, 180° wedge) compare model FB
    byte-for-byte against an oracle that mirrors the renderer.

Angle units: 16-bit unsigned, 65 536 = 360°. Screen-coord convention
(0° = +x = east; 90° = +y = south; sweep direction = increasing
angle = visually CW). Wrap-around arcs (e.g. 350° → 10°) work via
`uint16` arithmetic on `(theta - start)` vs `(end - start)`.

**Synth (Ti60F256-C4)**: clk_bus 146.8 MHz, ram_clk **243.1 MHz**
(slack +0.887 ns vs 5 ns target — only 28 ps closer than M18-1's
+0.915 ns despite the extra 32 FF arg storage).

### M18.1 — BEZIER / BEZIER_TO  ✓
<sub><a id="m18-1-bezier"></a>[⤴ status table](#status-at-a-glance)</sub>

Cubic Bezier primitives — real benefit appears mostly for extended-mode
software; ANTIC-compat content rarely uses them. Shipping for the same
reason BEZIER_TO chains exist: extended-mode software (and modern
porting paths) want them.

- `hdl/rp_tx.sv` — args storage 7 → 9 (`d_arg7`, `d_arg8`). Beat-payload
  mux extended to idx 7/8. `BUS_DRAW_OP_BEZIER` (9 beats: 4 control
  points + colour) and `BUS_DRAW_OP_BEZIER_TO` (7 beats: 3 new control
  points + colour, P0 = chained endpoint) added to `draw_beats()`.
- `hdl/draw_regs.sv` — chiplet-ext window 16 → 20 bytes.
  `$D498-$D49B` = `DRAW_ARG7_LO/HI` and `DRAW_ARG8_LO/HI`. DRAW_GO
  stays at `$D493`.
- `rp/video/src/draw.h` — `DRAW_MAX_ARGS` 7 → 9; `chain_x` / `chain_y`
  fields added to `draw_ctx_t` for BEZIER_TO state.
- `rp/video/src/draw.c`:
  - `draw_cubic_bezier()` — parametric step in `t ∈ [0..1]`.
    Step count = `|P0-P1|+|P1-P2|+|P2-P3|` (Manhattan hull length,
    upper bound on actual length), capped 8..4096. Consecutive
    samples connected by Bresenham line so any > 1-px gap fills.
    After render, `chain_x`/`chain_y` ← P3.
  - `BUS_DRAW_OP_BEZIER` dispatch: P0..P3 from args 0-7, colour
    from arg 8.
  - `BUS_DRAW_OP_BEZIER_TO` dispatch: P0 = `chain_x`/`chain_y`;
    P1..P3 from args 0-5, colour from arg 6. If no prior BEZIER,
    P0 defaults to (0, 0) — degenerate but doesn't crash.
- Tests:
  - `sim/tb_draw.sv` — Phase C.8 (BEZIER, 9 beats) + C.9 (BEZIER_TO,
    7 beats) verify rp_tx serialises both lengths.
  - `sim/tb_draw_regs.sv` — port list extended for arg7/arg8.
  - `rp/video/sim/tb_bus_pio.c` — Phase 15 (BEZIER) checks endpoints
    P0/P3 are painted, the chain_x/y captured P3, and the curve
    has non-trivial coverage. Phase 16 (BEZIER_TO) verifies P0
    is the previous chain endpoint, not (0, 0).

**Synth (Ti60F256-C4)**: clk_bus 148.4 MHz, ram_clk **279.4 MHz**
(slack +1.421 ns vs 5 ns target — actually *improved* vs M18-2's
+0.887 ns; the added arg7/arg8 logic shifted placement in a way
that helped ram_clk's IP-internal critical path).

Float math: `draw_cubic_bezier` uses single-precision via newlib
soft-FP on RP2354. Measured ~3 µs per sample on Cortex-M33 at 150
MHz; a 256-sample curve is ~1 ms. If profiling demands it, the
follow-up optimisation is **forward differences** (one-time setup
of 4 quintic-state values, then 4 adds per step instead of the
full polynomial evaluation).


## Phase 8 — silicon close

### M19 — Efinity project skeleton + synth  ✓
<sub><a id="m19"></a>[⤴ status table](#status-at-a-glance)</sub>

Shipped — the M19 deliverables landed incrementally alongside earlier
milestones rather than as a single project-skeleton commit. The
original sketch called for a `efinity/fpga-antic.xml` Efinity project
file; we ended up with a script-driven flow (`efinity/run.sh`) that
calls `efx_run` directly with the family / device / timing as env
vars, which is functionally equivalent + more diff-friendly +
easier to retarget across part bumps (Trion T20 → Tz50-C2 → Tz50-I3
→ Ti60F256-C4 all happened by changing env vars, no project XML
edit).

Inventory of what's in place:

- **Synth flow** — `efinity/run.sh` runs `efx_run -f map | pnr | pgm`
  on the remote Ubuntu box; rsyncs `hdl/*.sv` + `efinity/ip/` + the
  SDC; pulls back `outflow/` for inspection. Default target is
  Ti60F256-C4 (set per the part decision in
  [fpga-part-selection.md](fpga-part-selection.md)).
- **Source set** — `hdl/*.sv` (excluding `_mock.sv` files) + the
  generated HyperRAM IP at `efinity/ip/hyperram/hyperram.sv` are
  all fed to synth.
- **Constraints** — `efinity/constraints/antic_top.sdc` carries the
  clock-period targets for `clk_bus` / `ram_clk` / `ram_clk_cal`
  with `set_clock_groups -asynchronous` separating bus / HyperRAM /
  pix domains. `clk_pix` / `tmds_clk` / `rp_tx_clk` / `rp_rx_clk`
  enter the SDC when scan-out lands in `antic_top` (currently those
  modules are present in the file set but trimmed by Synplify
  because they're not yet wired into the top — see the M-int /
  Phase 5b notes in `synth-results.md`).
- **PnR effort knobs** — `beneficial_skew=on physical_packing=on
  max_router_iterations=200` are the run.sh defaults; `PNR_SKEW=off`
  / `PNR_PACK=off` / `PNR_SEED=N` env-var overrides documented in
  the script.
- **Pin allocation strategy** — [pin-map.md](pin-map.md) groups the
  ~110 user I/Os into HyperRAM / HDMI / RP-link / 6502-bus /
  status-config clusters with a floorplan strategy. Concrete pin
  numbers are deferred to PCB layout and will land in
  `efinity/constraints/antic_top.peri.xml` (Efinix's I/O
  constraint format) once the board is in hand.
- **Synth wrapper** — the outer wrapper that instantiates
  `EFX_GPIO` DDR primitives around the HyperRAM PHY ports + the
  PLL that drives `ram_clk` / `ram_clk_cal` is documented in
  [pin-map.md § "HyperRAM PHY pins"](pin-map.md). The wrapper file
  itself is M20-territory work — it instantiates Efinix-specific
  primitives so `antic_top` stays toolchain-agnostic.

**Ship criterion**: synthesis closes; no unsupported-construct
errors. **Met** — `efx_run -f map` consistently passes on
Trion T20F256-C4, Tz50F256-C2, Tz50F256-I3, and Ti60F256-C4 across
every milestone since M-int. Latest synth results in
[synth-results.md](synth-results.md).

### M20 — Efinity P&R closes timing  ✓ (PnR + STA)  ⏳ (bitstream)
<sub><a id="m20"></a>[⤴ status table](#status-at-a-glance)</sub>

**PnR + STA closure — done**. `efx_run -f pnr` consistently passes
on Ti60F256-C4 with positive slack on every constrained clock:

| Clock        | Constraint | Achieved (M18.1) | Slack |
|--------------|-----------:|-----------------:|------:|
| `clk_bus`    | 10.000 ns  | 6.737 ns / 148 MHz | +3.263 ns |
| `ram_clk`    |  5.000 ns  | 3.579 ns / **279 MHz** | **+1.421 ns** |
| `ram_clk_cal`| 40.000 ns  | 1.963 ns / 509 MHz | +38.04 ns  |

`clk_pix` / `tmds_clk` / `rp_tx_clk` / `rp_rx_clk` enter the SDC
when their respective modules wire into `antic_top` — currently
`tmds_out` / `scan_out` / `rp_tx` are present in the file set but
trimmed by Synplify because they're not yet hooked up at the top.
Their constraints are pre-staged behind comments in the SDC for
quick uncomment when integration lands.

**Bitstream — gated on board layout**. `efx_run -f pgm` runs after
PnR completes (`run.sh`'s `pgm` flow chains `map → pnr → pgm`), but
currently SKIPs because Efinix's bitstream packager needs an I/O
constraint file (`<top>.peri.xml`) mapping each `antic_top` port to
a physical package ball. That file is generated by Efinity's
**Interface Designer** GUI from the board's PCB pin assignments —
which don't exist yet (M22 chiplet integration territory).

What landed at M20:

- `efinity/run.sh` chains `pgm = map → pnr → pgm`. Ready to
  produce a bitstream the moment a `.peri.xml` is dropped into
  `efinity/constraints/`.
- [pin-map.md](pin-map.md) groups the ~112 user I/Os into HVIO
  (27 left-edge 3.3V pins → 6502 bus + page selects) and HSIO
  (~85 bottom/top/right 1.8V pins → HyperRAM / HDMI / RP-link /
  config). The HVIO group is exactly 27 pins, matching the
  available count.
- Synth-wrapper layer (`EFX_GPIO` DDR primitives + `EFX_PLL` for
  ram_clk/ram_clk_cal/clk_bus generation) is staged as the next
  M20 sub-deliverable: the wrapper instantiates `antic_top`
  alongside the Efinix-specific primitives and exposes physical
  pin names as its top-level ports. Lands when board layout
  decides exact pin numbers.
- TMDS serializer constraints — pre-staged in the SDC behind a
  comment; uncomment when scan_out + tmds_out wire into
  antic_top.

**Ship criterion** (revised): PnR closes with positive slack on
all constrained clocks ✓. Bitstream gen blocked on board layout
(M22 dependency); the flow path itself is verified.

**Open follow-ups** (track separately as a sub-milestone whenever
the board lands):
- `efinity/constraints/antic_top.peri.xml` — concrete pin assignments
- `efinity/wrapper/antic_top_synth.sv` — DDR primitives + PLL +
  tristate buffers wrapping `antic_top`
- Wire scan_out + tmds_out + the rp_tx / rp_rx pin paths into the
  top so their clock domains contribute to the SDC's STA report
- Final bitstream produced from `efx_run -f pgm`

### M21 — RP firmware production build  ✓ (code) / ⏳ (HW bring-up)
<sub><a id="m21"></a>[⤴ status table](#status-at-a-glance)</sub>

Code-complete. Production binary builds at `RP_VIDEO_SYS_MHZ=360`
(`vreg=1.35 V`, QMI retune via `clock.c`); the bus PIO state machines
are wired through to the dispatch loop; FETCH / SET / DRAW are live
on real beats from the FPGA. Hardware verification gated on actual
RP2354 silicon — same gating as M20's bitstream.

What's in place:

- `rp/video/src/bus.pio` — `bus_rx_skel` SM samples 26-bit beats on
  `bus_rx_clk` rising edges (24 payload + 2 tag); `bus_tx_skel` SM
  drives 16-bit FETCH responses on `bus_tx_clk` (one cycle high
  after the data is presented).
- `rp/video/src/bus_server.c` — production drain. `bus_server_start()`
  initialises a 256 KB framebuffer at a deterministic boot pattern,
  initialises the draw dispatcher with 640×240 clip geometry,
  claims pio0/SM0 (RX) + pio0/SM1 (TX), installs the bus.pio
  programs, configures GPIO 0..43 directions, then launches a
  drain loop on **core 1**. The loop blocks on the RX FIFO; per
  beat it does the same dispatch as the host model
  (`rp/video/sim/tb_bus_pio.c` `model_step`):
    - FETCH → 2-byte FB lookup, push 16-bit response on TX SM
    - SET   → 2-beat sequence (latch addr / write 2 FB bytes)
    - DRAW  → forward to `draw_beat()` (M17-3 / M18-1 / M18-2 /
      M18.1 renderers), counter ++
    - NOP   → idle, clears any half-formed SET state
    - other → `bad_tag_count` ++
- `rp/video/src/draw.c` — the renderer module from M17-3 onward;
  `bus_server.c` instantiates one `draw_ctx_t` and feeds every
  DRAW-tagged beat to `draw_beat()`. NO_FILL / RECT / RECT-fill /
  FILL flood / OVAL / OVAL-fill / ARC / PIE / BEZIER / BEZIER_TO
  all execute at run time.
- `rp/video/src/clock.c` — already configures vreg + QMI retune for the
  selected `RP_VIDEO_SYS_MHZ`. 360 MHz is the validated default;
  252 / 432 / 480 / 528 MHz options remain available via the
  CMake variable.
- `rp/video/src/main.c` — banner + heartbeat unchanged from M0-RP. Still
  prints `[heartbeat]` over USB CDC every 2 s with the live counter
  values from `bus_server_stats`.

What's deferred to hardware bring-up:

- **PSRAM framebuffer** — currently a 256 KB BSS array. A board-file
  change will retarget the array into the RP2354's external PSRAM
  via the QMI memory-mapped region. Logic doesn't change; it's
  one `__attribute__((section(...)))` decoration plus a linker-
  script tweak.
- **Self-test loop** — boot-time paired loopback against the FPGA's
  test pattern. The dispatch logic + counters are in place; the
  loopback orchestration (drive a known SET pattern, FETCH it
  back, compare) is a small `selftest.c` that runs once after
  `bus_server_start()` before handing off to the heartbeat. Lands
  with the silicon.
- **Pin-locked build** — concrete RP2354 board pinmap (the dev rig
  was Adafruit Feather RP2350; production custom RP2354 board
  takes 48 pins so all 4 spare control wires plus the full 27+17
  data buses fit).

**Ship criterion** (revised): production UF2 builds at
`RP_VIDEO_SYS_MHZ=360`; dispatch logic verified end-to-end against
the FPGA-side `tb_draw` + `tb_draw_regs` + the host C model
(`tb_bus_pio` cross-validated against `bus_server.c`'s switch).
Live boot + 5-minute paired-counter test runs once silicon is in
hand.

### M22 — chiplet integration handoff
<sub><a id="m22"></a>[⤴ status table](#status-at-a-glance)</sub>


This is where the multi-chip silicon work begins; the ANTIC firmware
becomes one of five interlocked builds. Out of scope for this repo's
first iteration; the contract between chips is documented in
[wire-protocol.md](wire-protocol.md), and the sibling projects
(rp-SALLY, rp-MMU, rp-syscontroller, rp-POKEY/PIA) implement against
it.

## Phase 9 — chip absorption (BOM reduction)

The Tz50F256-I3 silicon (M16b-int default) has ~94 % free BRAM and
~85 % free LUT capacity after the ANTIC + HyperRAM stack. That
headroom funds folding three discrete chips back into the FPGA,
absorbing their BOM cost and erasing inter-chip latency:

- **POKEY** (audio + keyboard scan + pots) → [M23](#m23)
- **SALLY** (6502 CPU core)                → [M24](#m24)
- **Peripheral glue** (RP2354 + SPI bridge) → [M25](#m25)

The cost case: Tz50F256-I3 is ~$35 (vs ~$26 for C2). Removing
discrete POKEY (~$5) + 6502 (~$5-10) more than offsets the +$9
silicon delta, and collapses several level-translator / glue parts.
The functional case: integrated POKEY hands its I2S stream straight
to the HDMI audio packetizer ([M15b-3](#m15b-3)) with no inter-chip
hop, and integrated SALLY shares the bus_snoop / dma_arbiter
plumbing already in `antic_top` with no halt-cycle penalty.

See [docs/FPGA.md](FPGA.md) for the original sketch.

### M23 — POKEY in fabric
<sub><a id="m23"></a>[⤴ status table](#status-at-a-glance)</sub>

POKEY is the most substantive of the chip-absorption milestones —
it's audio + keyboard + paddle scan + serial port + IRQ aggregation
all in one. Decomposed into seven sub-milestones (M23-1 .. M23-7)
that ship independently against `tb_pokey`'s incremental coverage.

Reference: [MiSTer-devel/Arcade-Centipede_MiSTer/rtl/pokey][mister-pokey]
for the polynomial counters + AUDC mode logic; license-compatible
with re-implementation.

[mister-pokey]: https://github.com/MiSTer-devel/Arcade-Centipede_MiSTer/tree/master/rtl/pokey

**Ship criterion** (rolling-up): a tone written to AUDF1/AUDC1
produces the expected sample frequency on the I2S bus (cycle-accurate
vs the real-chip golden trace), HDMI audio packets carry it through
`tmds_out` to a sink, and `tb_pokey` verifies the polynomial-counter
sequences against published MAME tables. Keyboard / paddle / serial
scan also each verifiable end-to-end.

#### M23-1 — register file + 4× square-wave channels  ✓
<sub><a id="m23-1"></a>[⤴ status table](#status-at-a-glance)</sub>

Foundation. Routes `$D2xx` writes through a POKEY register file and
4 square-wave channels generating output. No LFSR yet (M23-2 adds
the polynomials); no keyboard / POT / serial yet.

- `hdl/bus_snoop.sv` — `$D2xx` page select decoded from address
  (no external pin; PIA at `$D3xx` follows the same pattern at M25).
  New `snoop_we_pokey` + `snoop_re_pokey` outputs.
- `hdl/pokey_regs.sv` — register file. Write-side: AUDF1-4, AUDC1-4,
  AUDCTL. Read-side: AUDCTL read-back as a debug aid; other reads
  return 0 (real reads land at M23-4 / 5 / 6 with KBCODE / POTn /
  SKSTAT / IRQST / RANDOM).
- `hdl/pokey_audio.sv` — 4 channels, each a programmable divider
  fed by AUDF[i]. Channel toggles every (AUDF + 1) ref ticks;
  `clock_base` is selectable (15 kHz / 64 kHz reference per AUDCTL
  at M23-3 — hardcoded to 64 kHz for M23-1). Output per channel:
  a 4-bit `(volume * channel_state)` value.
- `hdl/pokey.sv` — top wrapper instantiating `pokey_regs` +
  `pokey_audio`; exposes the four 4-bit channel outputs.
- `hdl/antic_top.sv` — instantiates `pokey` alongside `gtia_regs` /
  `antic_regs`; merges `pokey_read_data` into the bus read mux;
  drives `bus_data_oe` for `$D2xx` reads (combinational decode of
  `bus_addr[15:8] == 8'hD2`).
- `sim/tb_pokey.sv`:
    - Phase A — register write + AUDCTL read-back
    - Phase B — frequency check on all 4 channels with different
      AUDF values (3, 7, 0, 15). Toggle counts hit the expected
      values exactly: 100 / 50 / 400 / 25 over a 1600-clock window.
    - Phase C — volume gate (AUDC vol=0 → silence verified for
      200 cycles after write)

The four channel outputs flow downstream to M23-7's I2S TX
module; until then they're inspectable in sim and tied off in
synth (synth's logic optimiser absorbs them as no external
consumer reaches them yet).

**Sim**: 31 / 31 sim targets pass (including `tb_pokey`). **Synth**:
`efx_run -f map` passes on Ti60F256-C4.

#### M23-2 — LFSR polynomial counters  ✓
<sub><a id="m23-2"></a>[⤴ status table](#status-at-a-glance)</sub>

Replaced the M23-1 square-wave channels with the full POKEY tone
repertoire driven by AUDC's poly-mode bits.

- 4-bit, 5-bit, 9-bit, and 17-bit LFSRs in `pokey_audio.sv`. All
  free-run on the reference tick (Fibonacci form, max-period
  polys: x⁴+x³+1, x⁵+x³+1, x⁹+x⁵+1, x¹⁷+x¹⁴+1).
- `RANDOM` register at `$D20A` reads the high byte of the 17-bit
  LFSR — wired through `pokey.sv` to `pokey_regs`'s read mux.
  The AUDCTL ($D208) read-back at debug-only `4'h8` mirrors the
  latched value; real ALLPOT semantics arrive at M23-5.
- `pokey_audio` gains a `next_state(audc, cur)` function that
  computes the channel's post-trigger state from the AUDC mode
  bits:
    - `AUDC[7]` NOT_5    — bypass / use 5-bit poly gate
    - `AUDC[6]` POLY_SEL — 0 = 17-bit, 1 = 4-bit
    - `AUDC[5]` PURE     — 0 = poly-modulated, 1 = pure square wave
    - 9-bit poly is unused at M23-2; AUDCTL POLY9 selector lands
      at M23-3.
- `tb_pokey` Phase B updated to use `AUDC = $Av` (PURE + NOT_5 +
  volume) for the M23-1 frequency-check regression. New phases:
    - **Phase D — RANDOM advances**: read `$D20A` twice with 256
      ref ticks between samples; verify the byte changes (LFSR is
      live).
    - **Phase E — poly modulation**: AUDC = $8F (POLY_SEL=0, NOT_5=1,
      PURE=0, vol=15); count high vs low samples over 1024 clocks
      and verify ~50/50 distribution (LFSR's high byte is balanced
      over a long enough window).

**Sim**: 31 / 31 sim targets pass; tb_pokey covers register r/w +
4-channel freq + volume gate + RANDOM advances + poly modulation.

(Note: real-chip POKEY clocks the 9 / 17-bit polys at the master
clock and the 4 / 5-bit polys at the channel rate, with subtle
sampling-vs-trigger relationships. M23-2 simplifies all four to
free-run on the reference tick — audio output won't be bit-exact
real-POKEY but produces the correct tone *families*. M23-3
refines clocking when AUDCTL features land.)

#### M23-3 — AUDCTL features  ✓
<sub><a id="m23-3"></a>[⤴ status table](#status-at-a-glance)</sub>

The remaining audio features encoded in AUDCTL ($D208).

- **REF15 (AUDCTL[0])** — `pokey_audio.sv` runs both 64 kHz and
  15 kHz reference dividers in parallel; `ref_tick` is muxed live
  off AUDCTL[0]. Tested in Phase H — toggle ratio HI / LO = 400 /
  200 = 2× (matches the 2× divider ratio in the reduced-rate test
  config; production 64 kHz / 15.7 kHz gives ~4×).
- **CH1_HF / CH3_HF (AUDCTL[6:5])** — channels 1 and 3 count on
  every `clk_bus` instead of the divided reference. Per-channel
  `tick` source selected via AUDCTL bit; the wrap detection feeds
  the paired channel's tick when applicable.
- **PAIR12 / PAIR34 (AUDCTL[4:3])** — ch2 (resp. ch4) decrements
  only when ch1 (resp. ch3) wraps. Effective period of the paired
  channel = (AUDF_lo + 1) × (AUDF_hi + 1). Tested in Phase F —
  AUDF1=2, AUDF2=3 with PAIR12 produces 33 ch2 toggles in
  1600 clocks (predicted: 33).
- **FILT1 / FILT2 (AUDCTL[2:1])** — ch1 audible state = ch1_state
  XOR ch3_state (likewise ch2 vs ch4). XOR model captures the
  audible high-pass effect without modelling the real-chip's flop
  clock — refinable later if golden-trace work demands it. Tested
  in Phase G — sample agreement with vs without FILT1 = 98/200,
  so the filter materially changes output.
- **POLY9 (AUDCTL[7])** — when set, AUDC POLY_SEL=0 routes to the
  9-bit poly instead of the 17-bit poly. `next_state()` picks
  via `poly_long = audctl[7] ? poly9 : poly17;`.

Two-tone serial mode is SKCTL[3:2] (not AUDCTL); deferred to M23-6.

**Sim**: 31 / 31 sim targets pass; tb_pokey covers register r/w +
4-channel freq + volume + RANDOM advance + poly modulation +
16-bit pair + high-pass filter + REF15 select.

**Synth (Ti60F256-C4)**: clk_bus 140.8 MHz, ram_clk 249.6 MHz
(slack +0.994 ns vs 5 ns target — only 24 ps narrower than M23-2).

#### M23-4 — keyboard event ingest  ✓
<sub><a id="m23-4"></a>[⤴ status table](#status-at-a-glance)</sub>

The Atari keyboard is a USB-HID source via the RP2354 (no external
matrix on the rp-XT board). RP2354's USB-host code translates HID
keycodes → Atari scan-code byte (scan code [5:0] + shift [6] +
ctrl [7]); a side channel from the spare RP→FPGA control wires
delivers the byte + a 1-cycle valid pulse. POKEY's role is
reduced to surfacing the event on KBCODE / SKSTAT and pulsing
KEY_INT — no matrix-scan timing needed.

- `hdl/pokey_regs.sv`:
    - `kbcode_q` (8 bits): latches `kbd_event_code` on each
      `kbd_event_valid` pulse. Read at $D209 (KBCODE).
    - `key_latch_q` (1 bit): set on event, cleared one cycle after
      a KBCODE read (read-clears semantics; uses `re` +
      `re_addr[3:0]==4'h9`).
    - `skctl_q` (8 bits): SKCTL write at $D20F. Bits remembered
      but not yet acted on (debounce / scan rate are matrix-scan
      concerns; serial-port modes land at M23-6).
    - SKSTAT read at $D20F surfaces `{kbcode_q[6], 1'b0,
      key_latch_q, 5'h00}` — SHIFT live + KEY_LATCH; KEY_DOWN +
      serial bits land at M23-6.
- `hdl/pokey.sv` — passes the new `re` / `re_addr` / `kbd_event_*`
  ports through to `pokey_regs`; exposes `key_int`.
- `hdl/antic_top.sv` — adds top-level inputs `kbd_event_valid` +
  `kbd_event_code[7:0]` (synth wrapper above clocks them into
  clk_bus from the RP-side spare control wires); wires
  `snoop_re_pokey` + `snoop_addr` for the read-clears latch.
- `sim/tb_pokey.sv` Phase I — drive a key event ($6A: scan $2A +
  SHIFT), verify KBCODE = $6A, SKSTAT bit 7 (SHIFT) = 1, bit 5
  (KEY_LATCH) = 1, KEY_INT pulses once. Then drive a KBCODE-read
  pulse and verify KEY_LATCH clears 1 cycle later.

KEY_INT is not yet IRQEN-gated — that's M23-6's job. For now it
pulses freely on each event; consumers can ignore it until the
IRQ aggregator lands.

**Sim**: 31 / 31 sim targets pass.

**Synth (Ti60F256-C4)**: clk_bus 141.8 MHz, ram_clk **265.1 MHz**
(slack +1.228 ns vs 5 ns target — actually *improved* over M23-3's
+0.994 ns; PnR placement found a better arrangement with the new
small-FF additions).

#### M23-5 — POT scan  ✓
<sub><a id="m23-5"></a>[⤴ status table](#status-at-a-glance)</sub>

Paddle / pot reading via the discharge-counter timing trick. Pin
hardware spec is in [hardware-notes.md](hardware-notes.md).

- `hdl/pokey_pot.sv` — 8 channels of "discharge then count" state
  machine. After POTGO ($D20B write):
    1. Drive all POT lines LOW for `DISCHARGE_TICKS` ref ticks
       (default 8) to discharge the cap. `pot_oe = 8'hFF`.
    2. Release lines (`pot_oe = 0`); start counting per-channel.
    3. Each ref tick: for each channel still scanning AND with
       `pot_in[i]=0` (line still low): increment counter, clamp at
       228 (0xE4).
    4. When `pot_in[i]` rises past threshold (cap charged through
       the paddle pot): freeze counter, clear `scanning_q[i]`.
- `hdl/pokey_regs.sv` — `potgo_pulse` strobes from a $D20B write.
  Read mux now serves POT0..POT7 at $D200-$D207 and ALLPOT at
  $D208 (replacing the M23-1 debug AUDCTL read-back).
- `hdl/pokey.sv` — instantiates `pokey_pot`, shares `ref_tick`
  with `pokey_audio`, exposes `pot_oe` / `pot_in` ports.
- `hdl/antic_top.sv` — top-level `pot_oe[7:0]` output + `pot_in[7:0]`
  input. Synth wrapper combines them into 8 inout open-drain pins
  (3.3 V or 5 V external pull-up; see hardware-notes.md).
- `sim/tb_pokey.sv` Phase J — drives POTGO, asserts `pot_oe = $FF`
  during discharge, simulates the cap crossing the threshold for
  POT0 after 17 ref ticks and POT1 after 42 ref ticks. Verifies
  POT0 captures count = 17 (exact) and POT1 captures count = 45
  (within ±5; loose bounds for sampling alignment). ALLPOT post-
  scan = $FC (POT0 / POT1 cleared, others still scanning).

SKCTL[2] fast / slow scan-rate selection lands at M23-6 alongside
the rest of the SKCTL bits. M23-5 fixes the rate at one count per
ref tick.

**Sim**: 31 / 31 sim targets pass.

#### M23-6 — serial / IRQ aggregation  ✓
<sub><a id="m23-6"></a>[⤴ status table](#status-at-a-glance)</sub>

The chip's plumbing — serial port shadow registers + IRQ multiplexer.

- **IRQEN ($D20E write) / IRQST ($D20E read)** — 8-bit mask + status of
  the 8 POKEY-sourced IRQ sources:

  | bit | source                    |
  |----:|---------------------------|
  |   0 | TIMER 1 (channel 1 wrap)  |
  |   1 | TIMER 2 (channel 2 wrap)  |
  |   2 | TIMER 4 (channel 4 wrap — POKEY has no TIMER 3) |
  |   3 | SER OUT NEEDED (shift register empty) |
  |   4 | SER OUT DONE (final byte fully shifted out) |
  |   5 | SER IN BYTE (SERIN holds a fresh byte) |
  |   6 | KEYBOARD                   |
  |   7 | BREAK KEY                  |

  IRQST returns the inverted-latch (bit = 0 means "this source pending"),
  matching the Atari hardware-manual convention. Software acks an IRQ
  by writing IRQEN with the bit cleared (which clears the latch);
  re-arming is a second IRQEN write with the bit set again.
- **SEROUT ($D20D write) / SERIN ($D20D read)** — direct shadow registers
  for the SIO state machine (M25). `serout_byte` + 1-cycle
  `serout_strobe` are surfaced from `pokey.sv` for the future SIO
  module; `serin_byte` is captured on a `ser_in_byte_pulse` from the
  same direction.
- **SKCTL ($D20F write)** — serial-port mode + POT-scan-rate
  selector (SKCTL[2] gives continuous-scan POT). Surfaced as
  `skctl_out` for `pokey_pot` to honour later.
- **SKRES ($D20A write)** — clears the three serial IRQ latches
  (bits 3..5). Other latches untouched.
- **SKSTAT ($D20F read)** — bits 4..2 now reflect framing-error /
  input-overrun / input-busy from the SIO module (tied 0 in the
  chiplet build until M25).
- **/IRQ output** (`irq_n`) — asserted (low) while any latch bit is
  set. Wired to the new top-level `irq_n` output on `antic_top`;
  feeds the SALLY core (M24) once that lands.

**Sim**: `tb_pokey` Phase K covers eight scenarios:
- IRQEN=0 + kbd event → no latch, irq_n stays high.
- IRQEN[6]=1 + kbd event → irq_n low, IRQST[6]=0.
- IRQEN-clear ack → IRQST returns to $FF, irq_n high again.
- IRQEN[0]=1 + ch1 wrap → timer1 latches, IRQST[0]=0.
- SEROUT write → byte captured on `serout_byte`, strobe pulses 1 cycle.
- SERIN read after `ser_in_byte_pulse` returns the latched byte;
  IRQEN[5]=1 makes the same pulse latch the IRQ.
- SKRES write clears bits 3..5 of the IRQ latch but leaves bit 6
  (kbd) intact.
- SKSTAT bits 4..2 mirror the SIO-side input wires.

31 / 31 sim targets pass. No timer-3 source is exposed (matches POKEY).

#### M23-7 — POKEY → HDMI audio packet feed  ✓
<sub><a id="m23-7"></a>[⤴ status table](#status-at-a-glance)</sub>

The rp-XT board allocates **no external I²S pins** — the POKEY-to-HDMI
audio path is a fabric-internal feed. The original "I²S TX → I²S RX
→ packetiser" design collapsed to a single POKEY-mixer + sample-rate
strobe + 4-deep audio buffer, presented directly in the format
`hdmi_pkt_source` consumes.

- **`hdl/pokey_i2s_tx.sv`** (the name is a holdover; no actual I²S
  serial frames are emitted) — three stages:
  1. **Channel sum → 24-bit LPCM**. ch1..ch4_out (4-bit each, 0..15) →
     6-bit sum (0..60), left-shifted 18 places to land in 24-bit
     LPCM range [0, 15728640]. Mono — same value on L and R. POKEY
     is naturally positive-valued; sinks AC-couple, so DC offset
     is inaudible.
  2. **Fractional sample-rate divider**. 24-bit phase accumulator;
     `inc = SAMPLE_HZ × 2^24 / CLK_BUS_HZ` (computed at parameter
     time using 64-bit intermediates). At default
     CLK_BUS_HZ = 21.477 MHz, SAMPLE_HZ = 48 kHz: inc ≈ 37496,
     frequency error ≈ 0.5 ppm.
  3. **4-deep ring buffer + IEC 192-frame block tracker**. Every
     4 sample strobes, the captured samples are presented as
     audio_l0..3 / audio_r0..3 with audio_present = $F. audio_flat[i]
     reflects sample-i silence; audio_block_start[i] is set on the
     IEC 192-frame boundary.
- **`hdl/i2s_rx.sv` deleted**. The external-I²S receive path is no
  longer needed; if it's ever wanted again it can be resurrected from
  git history.
- **`hdl/hdmi_pkt_source.sv`** (M15b-3) — interface unchanged;
  consumes the audio_l0..3 / audio_r0..3 / audio_present /
  audio_flat / audio_block_start that pokey_i2s_tx now produces.
- **No external I²S pin allocated** — saves 4 pins on the package.

The audio outputs propagate up through `pokey.sv` and surface at
`antic_top.sv` as new top-level outputs. The clk_pix-domain
hdmi_out wrapper will add 2-FF synchronisers when the full HDMI
integration lands; the audio outputs are slow-changing (≥83 µs
between frame_ready pulses) so CDC is straightforward.

**Sim**: `tb_pokey_i2s` covers 7 phases:
- A: sample_strobe rate matches SAMPLE_HZ within rounding error.
- B: LPCM mapping (sum=10 → $280000, sum=60 → $F00000, sum=0 → $000000).
- C: frame_ready pulses every 4 sample strobes.
- D: audio_present = $F when a frame is ready.
- E: audio_l[i] / audio_r[i] reflect L/R independently (stereo
  separation; updated post-M23-stereo to verify L≠R).
- F: audio_flat[i] = 1 only on slots where both L and R were zero.
- G: audio_block_start cycles every 192 sample strobes (≈4 hits in 200 frames).

31 / 31 sim targets pass after the i2s_rx removal. M23 (POKEY in fabric)
is now complete.

### M23-stereo — second POKEY at $D21x  ✓
<sub><a id="m23-stereo"></a>[⤴ status table](#status-at-a-glance)</sub>

The 130XE-style "stereo POKEY mod" places a second POKEY chip at
$D21x. POKEY mirrors every 16 bytes within $D200-$D2FF, so the
stereo decoding is by `bus_addr[4]`: even mirrors ($D200, $D220, …)
hit the left chip, odd mirrors ($D210, $D230, …) hit the right chip.

- **`hdl/bus_snoop.sv`** — replaces the single `snoop_we_pokey` /
  `snoop_re_pokey` pair with `_l` / `_r` versions decoded by
  `bus_addr[4]`.
- **`hdl/antic_top.sv`** — instantiates two `pokey` instances:
  - `u_pokey_l` ($D20x): full I/O — keyboard event ingest, POT
    pins, IRQ output (drives top-level `irq_n`), serial / SKCTL
    outputs for the future SIO state machine (M25).
  - `u_pokey_r` ($D21x): **audio-only**. Keyboard, POT, all serial
    sources tied off; `irq_n` output **intentionally dropped** —
    the OS doesn't know about a second POKEY's IRQ table, and
    routing serial through the second chip is future work
    (`docs/future-work.md` — RS-232 connector idea).
  - Bus-data read mux split: even-mirror reads return
    `pokey_l_read_data`, odd-mirror reads return `pokey_r_read_data`.
- **`hdl/pokey_i2s_tx.sv`** — restructured from 4-channel mono to
  8-channel stereo. Two parametric POKEY-side sums (`ch1..4_l` and
  `ch1..4_r`) → independent 24-bit LPCM L+R. The 4-deep ring buffer
  presents true stereo to `hdmi_pkt_source`. Now lives at
  `antic_top` level (one shared mixer for both POKEYs) rather than
  inside `pokey.sv`.
- **`hdl/pokey.sv`** — drops the audio-packet ports and the
  `pokey_i2s_tx` instantiation; now exposes only `ch1..4_out` for
  external consumption. Cleaner separation of concerns.

**Parametric clocking**: nothing in the audio chain hardcodes a
specific bus-multiplier. `antic_top` exposes `POKEY_CLK_BUS_HZ` and
`AUDIO_SAMPLE_HZ` as module parameters; downstream modules consume
those rather than referring to "12×" or any fixed CLOCK_MULT. This
keeps the design generic across CLOCK_MULT settings (the runtime
register $D480 still records the chosen multiplier for software).

**IRQ scope**: per the user's call, only the left POKEY's IRQ
output is wired up. The OS would not be able to distinguish IRQs
sourced from a second POKEY anyway (no second IRQ vector, no second
PIA register), so feeding the right chip's IRQ into the same OR
fan-in would only cause spurious interrupts.

**Dual-mono fallback for non-stereo software**: there is no
register-based way for software to detect dual POKEY on real
hardware (the second chip is just another POKEY at $D21x — no
"capability" register, no version byte). Most Atari titles only
know about one POKEY at $D200 and never write to $D21x; if we let
POKEY-R sit at its reset state (silent), those titles would play
half-volume on the left channel only.

The fix: a `stereo_active_q` flop in `antic_top` latches **on the
first write to $D21x** (any address, any value). Until then, the
right-channel mixer inputs to `pokey_i2s_tx` are taken from
**POKEY-L's channel outputs**, giving dual-mono playback. Once
latched, the flag stays set until /G_RST and the right-channel
inputs come from POKEY-R for true stereo. This matches the
"opt-in" behaviour a stereo-aware program implicitly signals by
configuring the second chip.

**Sim**:
- `tb_snoop` extended to write $D200=$11 + $D210=$22 and verify via
  hierarchical references that `u_pokey_l.u_regs.audf1_q==$11` and
  `u_pokey_r.u_regs.audf1_q==$22` — no cross-talk through the
  decoder. Also asserts `stereo_active_q==0` before the $D210 write
  and `==1` after.
- `tb_pokey_i2s` Phase E rewritten to drive distinct L+R values and
  verify audio_l[i] / audio_r[i] reflect them independently.

31 / 31 sim targets still pass.

### M24 — SALLY in fabric
<sub><a id="m24"></a>[⤴ status table](#status-at-a-glance)</sub>

The SALLY (NMOS 6502) core moves into the FPGA, replacing the
external 6502 chip. Same bus shape ANTIC already drives — addr,
data, R/W, /HALT — so the integration touches few existing modules.

**Architecture decision** (this conversation):

- **Memory layout** keeps M16-int's HyperRAM-for-banking but adds
  generous BRAM tiers for fast CPU access. ~122 KB BRAM out of
  ~256 KB on Ti60 ≈ 48 % budget — plenty of headroom.

  | Address | Backing | Latency |
  |---|---|---|
  | $0000-$00FF (zero page) | Direct BRAM | 1 cycle |
  | $0100-$01FF (stack)     | Direct BRAM | 1 cycle |
  | $0200-$3FFF             | Direct BRAM | 1 cycle |
  | $4000-$7FFF (banked)    | Bank cache (16 × 4 KB BRAM lines) | 1 cycle on hit, ~700 ns on miss |
  | $8000-$BFFF             | Direct BRAM | 1 cycle |
  | $C000-$CFFF             | OS ROM BRAM (loadable) | 1 cycle |
  | $D000-$D7FF             | Combinational reg decode | 1 cycle |
  | $D800-$FFFF             | OS ROM BRAM (loadable) | 1 cycle |

- **Bank cache** ($4000-$7FFF): 64 KB of BRAM split into 16 lines
  of 4 KB each. Each line tagged with `(valid, dirty, bank_id,
  region_mask)` where region_mask says whether the line covers a
  16K, 8K, or 4K window. Supports:
  - **XT 3-way split**: 8 KB code at $4000-$5FFF + 4 KB data at
    $6000-$6FFF + 4 KB region-C at $7000-$7FFF, each independently
    bank-switched ($82, $83, $84-$85). Hot working set fits in cache.
  - **XE flat 16K**: each bank fills 4 lines; up to 4 banks
    resident. Switch = retag, no refill if cached.
  - **Rambo / compy / etc.**: stop-the-world refill from HyperRAM
    on miss; ~700 ns ≈ 1.25 Atari machine cycles. Rare in real
    workloads.

- **Dual-view bank select**: cache lookup takes a "who's asking"
  bit. CPU uses its own zero-page bank registers ($82-$85);
  ANTIC has its own chiplet-ext bank registers (`$D488 ANTIC_CODE_BANK`,
  `$D489 ANTIC_DATA_BANK`, `$D48A ANTIC_REGC_BANK`). Same physical
  cache line serves both views when bank-ids match; different ids
  give independent overlays at the same address — period-correct
  technique for "CPU runs from one bank while ANTIC composites a
  different bank's screen RAM".

- **ANTIC always reads BRAM** (no separate snoop / DMA modes for
  the read path). Cycle-accurate emulation of original /HALT
  bus-stealing comes from gating SALLY's RDY input — the data
  path is the same in both modes; only the timing differs.

  | CLOCK_MULT | SALLY clock | /HALT behavior |
  |---|---|---|
  | 1 (default) | phi2 lockstep with ANTIC | Real /HALT — SALLY stalled during DL/PM/playfield DMA cycles, exact match for beam-racing software |
  | ≥ 2 | Native fabric Fmax | /HALT permanently deasserted — SALLY runs free; ANTIC reads BRAM in parallel via dual-port |

- **Vendor**: Arlet Ottens' [verilog-6502][arlet-6502] core. Small
  (~700 LUTs), fast (≥80 MHz on Spartan-6, expect higher on
  Ti60F256-C4), free with attribution, cycle-accurate for our
  workload. Single-clock fully static. Synchronous memory model
  — output address on cycle N, accept data on cycle N+1 — fits
  our BRAM dual-port shape directly.

- **Sweet 16** ([wikipedia][sweet16]) as native hardware ops is a
  follow-up nicety, not part of M24's ship criterion.

[arlet-6502]: https://github.com/Arlet/verilog-6502
[sweet16]: https://en.wikipedia.org/wiki/SWEET16

**Execution order** (different from sub-milestone numbering — the
labels are topical, the order is dependency-driven for early demo):
**M24-1 → M24-2 → M24-5 → M24-3 → M24-4 → M24-6 → M24-7.** First
demo lands at end of M24-5 (working CPU + cycle-accurate ANTIC
arbitration on a non-banked program).

**Ship criterion (M24 roll-up)**: Klaus Dormann's [6502 functional
test][klaus] passes against the Arlet core ✓ (reached success trap
$3469 after 96,241,600 sim cycles on 2026-05-08; harness lives at
`sim/tb_klaus.sv`, vendored binary at `sim/test_data/`; run via
`make klaus` — long-running, ~40 min in iverilog, not in `make
all`). Bruce Clark's [BCD test][bcd] passes ✓ (subsumed by the
decimal section of Klaus's test, which our run completes). A small
Atari demo program (e.g., draw to GR.0 with PMG) rendering
identically at CLOCK_MULT=1 vs the existing external-CPU
configuration is the remaining gate.

[klaus]: https://github.com/Klaus2m5/6502_65C02_functional_tests
[bcd]: http://6502.org/tutorials/decimal_mode.html

#### M24-1 — Arlet 6502 sim bring-up + undocumented-opcode survey  ✓
<sub><a id="m24-1"></a>[⤴ status table](#status-at-a-glance)</sub>

- Vendor `cpu.v` + `ALU.v` from Arlet's repo (permissive license,
  attribution preserved in headers) live in `hdl/sally/`. A thin
  `sally_core.sv` wrapper renames I/O to our conventions
  (`clk`, `rst`, `addr`, `data_in`, `data_out`, `rw`, `rdy`,
  `irq_n`, `nmi_n`) and inverts the active-low IRQ / NMI senses
  to match real-6502 / Atari pin polarity.
- `tb_sally.sv` instantiates the wrapper plus a flat 64 KB BRAM
  with hand-assembled test programs. Six phases:
  - **A** LDA #imm + STA abs
  - **B** BNE branch logic (taken)
  - **C** JSR / RTS round-trip
  - **D** INX/BNE 256-iteration loop (validates wrap + branch)
  - **E** BCD ADC ($15 + $27 in decimal mode = $42)
  - **F** IRQ entry / RTI (CLI, then external IRQ assertion,
    ISR runs, RTI returns to spin loop)
- All phases reset the CPU and use a 3-byte stack-pointer init
  prelude (`LDX #$FF / TXS`) before the test program — real 6502
  leaves S undefined at reset, and the Atari OS does this same
  init on cold boot.
- **Undocumented opcode survey result**: Arlet's `casex`-based
  decode tree only matches documented opcodes. Patterns like
  `xxx0_0011` (where LAX (zp,X) lives) have **no case entry**
  — the CPU enters DECODE state and never transitions out, so
  any LAX/SAX/DCP/ISC/RLA/SLO/SRE/RRA effectively hangs the
  CPU. **M24-und is required** for any undocumented-opcode
  support; scheduled.

**Sim**: 32 / 32 sim targets pass (added `tb_sally`).

#### M24-2 — Memory skeleton (direct-BRAM regions)  ✓
<sub><a id="m24-2"></a>[⤴ status table](#status-at-a-glance)</sub>

- **`hdl/sally_mem.sv`**: standalone memory-subsystem module.
  64 KB single-port BRAM covers the entire $0000-$FFFF address
  space. Hardware-register page at $D000-$D7FF is overridden by
  a combinational hwreg_dout passthrough; writes there route to
  hwreg_we / hwreg_addr / hwreg_din without shadowing into BRAM
  (so reads back through the override aren't polluted).
- **Synchronous-read pipeline**: BRAM dout and the receiver's
  combinational hwreg_dout are both registered in sally_mem to
  share the same N → N+1 timing as Arlet's `cpu.v` contract;
  `was_hwreg_q` selects between them on the read-back cycle.
- **Bank window** ($4000-$7FFF) currently passes through to
  flat BRAM (no cache yet — M24-3 wires the real cache in).
- **ROM regions** ($C000-$CFFF, $D800-$FFFF) are writable RAM at
  this stage; the WRITE_LOCK arrives at M24-6 with the OS-ROM
  load path.
- **Dual-port for ANTIC reads** is deferred — single-port for
  this milestone. The hookup to ANTIC's `mem_read_mux` /
  `dl_parser` / `compositor` lands as part of M24-5.
- **`sim/tb_sally_mem.sv`**: 7 unit-level tests stressing each
  region boundary — zero page, stack, main RAM lo / hi, bank
  window, ROM regions, hwreg page (read returns stub $FF, writes
  fire hwreg_we), and the page-boundary decode at $CFFF/$D000
  and $D7FF/$D800.
- **Integration with `tb_sally`**: existing 8 CPU-conformance
  phases (A-H) now run through `sally_mem` end-to-end via a
  ``\`define mem u_mem.mem`` hierarchical-reference macro.

**Sim**: 33 / 33 sim targets pass (was 32 — added `tb_sally_mem`).

#### M24-3 — Bank cache for $4000-$7FFF  ✓ (standalone)
<sub><a id="m24-3"></a>[⤴ status table](#status-at-a-glance)</sub>

- **`hdl/bank_cache.sv`**: 16-line fully-associative cache. Each
  line tagged with an 8-bit `bank_id`; data BRAM is one big
  64 KB array indexed by `{line_id, offset}`. Round-robin
  victim selection (simpler than LRU — refinement target).
- **Lookup**: 16 parallel tag comparators (combinational); priority
  encoder for the hit index. Hit returns data on cycle N+1
  matching Arlet's synchronous-memory contract.
- **Miss path**: stop-the-world FSM —
  `IDLE → EVICT/EVICT_WAIT (if dirty) → FETCH/FETCH_WAIT →
  INSTALL → IDLE`. Walks LINE_BYTES bytes through the HyperRAM
  port one byte per FETCH iteration. `cpu_ready` drops to 0 for
  the duration; SALLY stalls via the existing rdy chain
  (sally_mem → sally_clock).
- **`sim/tb_bank_cache.sv`** (4 phases — line size shrunk to 64 B
  for sim speed; production uses 4 KB):
  - A: cold miss, cycles ≈ 2 × LINE_BYTES.
  - B: warm hit, 1-cycle response.
  - C: dirty write + 17 distinct-bank thrash → forces eviction
       writeback. Verifies the modified byte landed in HyperRAM.
  - D: re-fetch evicted bank, sees the updated byte. Round-trip
       writeback proven.

**Tradeoff: line size**. Production 4 KB / line means each miss
walks 4 KB of bus, which at 1-byte-per-fabric-cycle in a simple
mock is ~8200 cycles ≈ 82 µs at 100 MHz fabric (= ~147 Atari
machine cycles, ~one scan line). Acceptable for the rare miss
case but not the user's original "~700 ns" estimate, which
assumed 256-byte lines. Switching to 256-byte lines would give
sub-Atari-cycle miss times at the cost of 256 cache slots
(more comparator LUTs + wider tag mux). The cache is parametric
on `LINE_BYTES` so we can profile + adjust later. Marker
issued — see `docs/Issues.md#bank-cache-line-size`.

**Sim**: 35 / 35 sim targets pass (was 34 — added `tb_bank_cache`).

**sally_mem integration deferred**: gluing bank_cache into
sally_mem's $4000-$7FFF path needs the dual-view bank-id source
(CPU vs ANTIC) — that lands as part of M24-4. Standalone cache
is verified; the wiring is mechanical once the bank-id source
is decided.

#### M24-4 — Dual-view bank select  ✓
<sub><a id="m24-4"></a>[⤴ status table](#status-at-a-glance)</sub>

- **`hdl/bank_xlat.sv`** — combinational bank-id translator. Maps
  (cpu_addr, bank-select state, view) → 16-bit bank_id +
  12-bit offset + is_in_window. Implements the XT 3-way split:
  - $4000-$4FFF: code lo (8 KB code window split into 2 × 4 KB
    cache lines), bank_id top tag = `00`.
  - $5000-$5FFF: code hi, bank_id top tag = `01`.
  - $6000-$6FFF: data, bank_id top tag = `10`.
  - $7000-$7FFF: region-C, bank_id top tag = `11`, with the low
    14 bits composed of regc_bank_hi[5:0] + regc_bank_lo
    (16384 distinct region-C banks).
  - Region tags ensure cross-region bank ids never collide.
- **CPU bank-select snoop** (in sally_mem): writes to zero-page
  $0082-$0085 are mirrored into latched registers
  (`cpu_code_bank`, `cpu_data_bank`, `cpu_regc_bank_lo/hi`)
  visible to bank_xlat without needing a BRAM read port.
- **ANTIC chiplet-ext registers** ($D488-$D48B): added to
  antic_regs as `ANTIC_CODE_BANK / ANTIC_DATA_BANK /
  ANTIC_REGC_BANK_LO / ANTIC_REGC_BANK_HI`. Default 0 at reset
  (= matches CPU view if CPU also at 0).
- **`bank_cache` integration into sally_mem**: $4000-$7FFF
  accesses route through bank_xlat → bank_cache (using the low
  byte of the 16-bit bank_id; production builds should widen
  `bank_cache.BANK_ID_W` to 16). sally_mem outputs `busy` for
  sally_clock to fold into the rdy gating chain.
- **`view_is_antic` input** on sally_mem: tied 0 in the CPU-side
  instance (used by sally_core); the ANTIC-side instance (when
  wired up at antic_top integration) ties it 1 to use the
  ANTIC bank-select set instead.

**Sim**:
- `tb_bank_xlat` (6 phases): in-window decode, CPU view encoding,
  ANTIC view encoding, **dual-view divergence at the same
  address**, matching-selectors collapse, offset extraction.
- `tb_sally_mem` and `tb_sally_arbitration` updated with
  HyperRAM mock for the bank_cache plumbing; both still pass
  end-to-end through the new memory subsystem.

**Deferred** (lands at the antic_top integration step):
- Wiring sally_mem with `view_is_antic=1` for ANTIC's read path
  (replacing the existing `mem_read_mux` flow).
- Full integration test with CPU and ANTIC reading the same
  address through the same bank_cache and seeing distinct data.

**Sim**: 36 / 36 sim targets pass (was 35 — added `tb_bank_xlat`).

#### M24-5 — Bus arbitration (CLOCK_MULT-driven)  ✓
<sub><a id="m24-5"></a>[⤴ status table](#status-at-a-glance)</sub>

- **`hdl/sally_clock.sv`**: combines four inputs into a single
  `sally_rdy` line that drives Arlet's `cpu.v` RDY pin —
  `step` pulse from a sub-phi2 counter (CLOCK_MULT pulses per
  phi2 cycle), `halt_n` from ANTIC's DMA scheduler (gated only
  at CLOCK_MULT=1), and `wsync_rdy_n` from `wsync_gen` (always
  honoured).
- **`hdl/sally_mem.sv` rdy gating**: critical fix. Arlet's `ADD`
  register captures `data_in` at every state transition, so if
  the memory updates `data_in` between the address presentation
  and the next RDY=1 pulse, ADD picks up the wrong byte (the
  bug shows up immediately on the JMP0→JMP1 reset-vector load:
  PCL captured was $FFFD's value instead of $FFFC's). Fix:
  freeze `bram_dout_q` / `hwreg_dout_q` updates while
  `sally_rdy=0`. With this, Arlet sees consistent `data_in`
  values across the multi-cycle stall window.
- **`sim/tb_sally_arbitration.sv`**: 4 phases:
  - **A** scaling: same program at K=1, 2, 4, 12. Cycle counts
    178, 88, 43, 13 — clean ~K× scaling.
  - **B** /HALT honoured at K=1: dropping halt_n for 400 cycles
    extends program by ~400 cycles.
  - **C** /HALT bypassed at K=4: same halt pattern has zero
    effect on completion time.
  - **D** WSYNC honoured at K=4: pulling wsync_rdy_n=0 stalls
    SALLY despite the higher clock rate.
- **First end-to-end SALLY demo lands here**: working CPU
  running real 6502 code, with cycle-accurate /HALT semantics
  at K=1 and software-selectable speedup up to ~12× (= full
  fabric Fmax). Software opts into faster modes by writing
  CLOCK_MULT (the existing `$D480` register).

**Sim**: 34 / 34 sim targets pass (was 33 — added `tb_sally_arbitration`).

#### M24-6 — OS ROM load path
<sub><a id="m24-6"></a>[⤴ status table](#status-at-a-glance)</sub>

- BRAMs at $C000-$CFFF and $D800-$FFFF initialise from
  `os_rom.hex` via `$readmemh` at synth time. Default image:
  the real Atari OS-B (the user has earmarked their own OS to
  replace it later, but OS-B is the working baseline so we get
  real software running on day one).
- New chiplet-ext registers:
  - `$D48C OS_ROM_ADDR_LO`
  - `$D48D OS_ROM_ADDR_HI` (13-bit address into combined ROM image)
  - `$D48E OS_ROM_DATA` (write triggers byte commit + auto-incr)
  - `$D48F OS_ROM_CTL` (bit 0 = WRITE_LOCK)
- Loader software: write addr-pair, stream bytes through DATA,
  set WRITE_LOCK to disable further writes.
- **tb_os_rom_load**: read default image, write a different
  image via the load path, verify, set lock, verify writes are
  ignored, soft-reset, verify the new image persists (BRAM
  doesn't clear on reset — this matches the spec, see audit).

#### M24-7 — Synth / STA timing closure
<sub><a id="m24-7"></a>[⤴ status table](#status-at-a-glance)</sub>

- Run the M19 Efinity flow with the SALLY-included build.
  Target `clk_bus` ≥ 100 MHz sustained, stretch goal 150 MHz.
- ANTIC was reportedly already at 173 MHz on Tz50-C2 / +1.4 ns
  slack on Ti60-C4 — adding SALLY shouldn't disturb that since
  SALLY lives in its own clock domain and the fabric BRAMs are
  not on the critical path of the existing design.
- **Find max stable CLOCK_MULT**: at clk_bus = 100 MHz and
  base phi2 = 1.79 MHz, theoretical CLOCK_MULT max is ~56×.
  Stretch goal: stable 50× (= ~89 MHz effective Atari rate).
- Document achieved Fmax in `docs/synth-results.md`.

#### M24-und — Stable undocumented opcodes (conditional)
<sub><a id="m24-und"></a>[⤴ status table](#status-at-a-glance)</sub>

Spawned only if M24-1's opcode survey shows Arlet's core lacks
the stable undocumented opcodes. **Likely required**, since
Arlet's core was explicitly written to NMOS-6502 documented
behaviour — but worth checking before reserving milestone time.

If needed:
- Add LAX, SAX, DCP, ISC, RLA, SLO, SRE, RRA at minimum (these
  are the ones real Atari demos use).
- Use Lorenz Diener's [extra opcode test][lorenz] suite for
  verification.
- Skip "unstable" opcodes (XAA, AHX, …) — Atari software
  effectively never uses them, and their behaviour depends on
  process variation that we can't reproduce on FPGA.

[lorenz]: http://www.softwolves.com/arkiv/cbm-hackers/7/7114.html

### M25 — Peripherals (peri-RP2354B + 4-pin link to FPGA)
<sub><a id="m25"></a>[⤴ status table](#status-at-a-glance)</sub>

POR (May 2026): all Atari-side peripherals (4 joysticks, 8 paddles,
SIO, SD card) live on a **dedicated peripheral RP2354B** (QFN-80,
48 GPIOs). The peri-RP talks to the FPGA over a 4-pin link
(3-pin SPI + 1-pin IRQ), and **boots the FPGA** over a separate
8-pin Passive ×4 QSPI link (CDI[0..3] + CCK + SSL_N + CRESET_N +
CDONE — see [fpga-configuration.md](fpga-configuration.md)). All
voltage translation between Atari and the rest of the board lives
on the peri-RP's clamp-protected 3.3 V GPIOs (with cheap series-R
arrays for fault tolerance). 1 × LVC8T245 between FPGA HSIO 1.8 V
and peri-RP 3.3 V on the peri_link, and 2 × LVC8T245 on the QSPI
config link. The main RP2354B (also QFN-80) is now solely video
RAM + USB host (4 spare GPIOs since FPGA-boot moved off it,
2026-05-11).

[hardware-notes.md](hardware-notes.md) has the full architecture +
BOM. [pin-map.md](pin-map.md) tracks the pin allocation.

**Why this changed from the earlier FPGA-direct plan**:

1. **5 V exposure on FPGA is expensive.** HSIO is 1.8 V LVCMOS, so
   every 5 V Atari signal needs a level shifter. The FPGA-direct
   plan ran ~$13 in translator ICs alone, plus board-area cost.
2. **PIA PORTA / PORTB are bidirectional per-bit.** XEP80 80-column
   adapter, mouse adapters, and bit-banged serial accessories drive
   specific bits as outputs while leaving others as inputs. A
   shared-DIR LVC8T245 can't follow per-bit direction; auto-sense
   (TXS0108E) was needed for joysticks alone.
3. **SIO state machine + SD card protocol stack.** Both are
   straightforward in C firmware on the peri-RP (PIO + hardware SPI)
   but multi-day fabric work in HDL. Moving them to firmware drops
   ~3-5 days of HDL.

**Peri-RP's job** (29 of 48 GPIOs used; 19 spare after M25-2c-rev
moved joystick onto a PCAL9722):

| Group              | Pins | Notes                                                 |
|--------------------|-----:|-------------------------------------------------------|
| 8× POT             |    8 | Open-drain bidir, paddle discharge counter (PIO)      |
| SIO                |   12 | Full DB-13 signal set, including AUDIO_IN + spare     |
| SD card            |    4 | Hardware SPI peripheral on the RP                     |
| FPGA SPI link      |    4 | CLK + MOSI + MISO + /CS; PL022 hardware SPI in slave  |
| IRQ to FPGA        |    1 | Edge — peri-RP signals "state changed, poll me"       |

**PCAL9722's job** (22 GPIOs, 20 used + 2 spare; split-supply VDDI/VDDP):

| Group              | Pins | Notes                                                 |
|--------------------|-----:|-------------------------------------------------------|
| 4× joystick        |   20 | Direction + trigger; per-bit bidirectional via DDR    |
| FPGA SPI bus       |    4 | CLK + MOSI + MISO + /CS; FPGA is master (joy_link)    |
| INT_N to FPGA      |    1 | Edge — change-on-input via internal mask + latch      |

**FPGA's job**: 5 HVIO pins for the peri-RP link (rp_rx + peri-RP SPI
go on HVIO 3.3 V — direct, no level shifter) + 5 HSIO pins for the
PCAL9722 bus (PCAL9722 VDDI = 1.8 V matches HSIO directly, also no
shifter). See [pin-map.md](pin-map.md) "HVIO bank" / "HSIO banks"
for the full allocation.

The existing PIA shadow at $D300-$D37F (M25-1, `pia_regs.sv`) and
POKEY's POT registers (M23-5) are unchanged — they're the
software-visible registers SALLY reads from. What changes is the
*source* of `joy_porta_in` / `pot_in` / etc.: instead of physical
pads on the FPGA, those signals come from the peri-RP (POT) or
PCAL9722 (joystick) via their respective SPI bridges.

**Cart slot** (M22-adjacent): cartridge slot IS the 6502 bus exposed
externally — shares the 27 HSIO pins now allocated for the bus. No
new pins needed; just an external connector + buffer ICs.

**Main RP2354B** (existing role, QFN-80; 44 of 48 GPIOs used for
rp_tx + rp_rx, 4 spare since FPGA boot moved to peri-RP 2026-05-11;
USB DP/DM are dedicated pins outside the GPIO budget):

- Line-buffered video RAM (the framebuffer)
- USB host for keyboard / mouse via TinyUSB

FPGA boot is now driven by the **peri-RP** via Passive ×4 QSPI on 8
dedicated HSIO pins (CDI[0..3] + CCK + SSL_N + CRESET_N + CDONE).
See [fpga-configuration.md](fpga-configuration.md); also addressed
under M0-RP below.

**Ship criterion**: a paddle reading is end-to-end testable from the
joystick port → peri-RP discharge counter → SPI link → POKEY POT0
shadow register → 6502 read of $D200. A joystick wiggle moves the
PCAL9722 input register → INT_N → joy_bridge → PIA PORTA → 6502 read
of $D300. SIO read-from-disk (or SD-card-mounted-as-SIO) reaches the
6502 as a normal system call.

#### Sub-milestones

#### M25-1 — PIA shadow + bidirectional PORTA/PORTB  ✓ (commits `db64aa4` + `3e98923`)
<sub><a id="m25-1"></a>[⤴ status table](#status-at-a-glance)</sub>

`pia_regs.sv` at $D300-$D37F. PORTA / PORTB / PACTL / PBCTL with the
standard 6520 port-vs-DDR mode select; PORTB writes always feed the
130XE banking translator regardless of mode. Exposes
`joy_porta_in/out/oe` + `joy_portb_in/out/oe` for true per-bit
bidirectional access (XEP80 etc.), plus `joy_fire[3:0]` to GTIA's
TRIG0..TRIG3. bus_snoop adds `snoop_we_pia` decode for the $D3 page
bit-7=0 window (cache_regs owns bit-7=1).

The signal interface (joy_*_in / joy_*_out / joy_*_oe) is independent
of where the physical pins live — under the new POR, those signals
hop through the peri-RP bridge (M25-2-rev) instead of FPGA pads, but
the HDL is unchanged.

Synth (after the bidir correction): clk_bus 167.36 MHz / +0.195 ns
slack at 162 MHz target. 93.50× original Atari, BASE_DIV=90 with
6.3 MHz margin. `tb_pia_regs` covers reset state, port/DDR mode
round-trip, joystick read in port mode, PORTB-always-latches-banking,
the $D300-$D303 mirror decode, and the bidirectional-output
behaviour.

#### M25-2 — Peri-RP SPI link with /CS + PCAL9722 joystick path  ✓
<sub><a id="m25-2"></a>[⤴ status table](#status-at-a-glance)</sub>

Two independent SPI links on the FPGA side, each with its own /CS:
peri_link drives the peri-RP2354B (POT / SIO / SD), joy_link drives
the PCAL9722 GPIO expander (joystick / fire). Sub-milestones in
landing order:

- **M25-2** — `peri_link.sv`: SPI master, /CS-delimited 8-bit frames,
  two pulses per logical 16-bit transaction (cmd byte + data byte)
  with a master-controlled `HALF_GAP` between halves. The /CS
  protocol lets the peri-RP slave use its on-chip PL022 hardware SPI
  in slave mode — no PIO state machine on the slave side, no
  cmd-byte-to-MISO timing race. CLK_DIV=16 → ≈5 MHz at 162 MHz
  clk_bus. 2-FF synced + edge-detected IRQ. `tb_peri_link` covers
  round-trip write, read, back-to-back streams, IRQ pulse.
- **M25-2b** — `joy_bridge.sv` (was `peri_bridge.sv` pre-pivot):
  write-through scheduler + ~30 kHz poll loop above `joy_link`.
  Tracks last_*_q for joy_porta_out / _oe / portb_out / _oe and
  inverts OE before writing PCAL9722's CONFIG register (PCAL9722:
  1=INPUT, opposite of PIA's DDR). Polls PCAL9722 Input port 0/1/2
  every tick to refresh joy_porta_in / joy_portb_in / joy_fire.
  `tb_joy_bridge` covers write-through, polled shadow, live tracking,
  TRIG nibble truncation.
- **M25-2c** — `antic_top` integration: 7 joystick I/O ports
  collapsed to 10 SPI pads (5 peri-RP + 5 PCAL9722). joy_bridge
  drives the PCAL9722 path; peri_link instantiated bare (xfer_start
  tied 0 → synth optimises it away) on the peri-RP pads, ready for
  M25-3c to wrap with a polling FSM. **HVIO repurposed**: rp_rx (17)
  + peri-RP SPI link (5) move from HSIO to HVIO at 3.3 V CMOS direct
  — saves 5 LVC8T245s. 6502 bus moves to HSIO 1.8 V (same chip count
  via VCCA=1.8 V on its translators). See
  [hardware-notes.md](hardware-notes.md) "HVIO repurpose".
- **M25-2c-rev** — `joy_link.sv`: PCAL9722 SPI master speaking the
  chip's 24-bit register-access protocol (cmd byte = device addr +
  R/W, reg addr byte, data byte). Single /CS pulse per transaction
  (the PCAL9722 is hardware, no firmware-decode race). 2-FF synced
  INT_N falling-edge → peri_int_pulse. `tb_joy_link` covers
  write/read round-trip, back-to-back, INT_N pulse.

Outbound peri-RP register slots reserved in `peri_link.sv`: POT_OE,
CMD (POTGO / SIO_TX), SIO_OUT. Inbound: STATUS, ALLPOT, POT0..7,
SIO_IN, SIO_STAT, SD-card window. PORTA/PORTB/TRIG slots removed —
joystick lives on PCAL9722 now. Synth: 168.5 MHz / +0.234 ns slack
at 162 MHz target on Ti60F256-C4 (see
[synth-results.md](synth-results.md) "M25-2c-rev").

#### M25-3 — Peri-RP firmware (POT / SIO / SD)  🟡 in progress
<sub><a id="m25-3"></a>[⤴ status table](#status-at-a-glance)</sub>

C firmware on the peri-RP2354B. Lives at `rp/peri/`, sibling to the
existing `rp/video/` (video-RP firmware). Joystick / fire-button
handling is **gone from this milestone** — moved off to the PCAL9722
GPIO expander in M25-2c-rev, where it's a pure FPGA-HDL problem.
Sub-milestones:

- **M25-3a — ✓ Skeleton + HW SPI slave + register file.** Banner
  main + `clock.{c,h}` cribbed from `rp/video/`, PL022 hardware SPI
  driver (no PIO needed thanks to /CS on `peri_link`), C polling
  loop at `peri_spi_slave_run()` on core 1 doing
  `spi_write_read_blocking()` for cmd byte → decode →
  `spi_write_read_blocking()` for data byte, 128-byte register file
  at `peri_regs.{c,h}`. `rp/peri/sim/tb_peri_regs` host-tests the
  C-side decode. Hardware bring-up is the validation gate (no PIO
  emulator needed).
- **M25-3b — n/a (joystick moved to PCAL9722).** Reserved for
  potential PCAL9722 init-sequence work if it turns out the
  expander needs runtime configuration beyond the bring-up writes
  joy_bridge already does (interrupt mask, polarity inversion,
  input-latch enable).
- **M25-3c — ✓ FPGA bridge + ✓ pokey shadow + 🟡 firmware glue.**
  Three pieces:
  - `peri_pot_bridge.sv` — FPGA-side wrapper above `peri_link` that
    forwards `potgo_pulse` → CMD=POTGO write, polls STATUS for
    `pot_done`, and reads back ALLPOT + POT0..7 into the shadow
    `pokey_pot` consumes. **Resurrects `peri_link` from the synth-
    eliminated stub** — antic_top now drives the peri-RP SPI pads
    via this bridge instead of the old constant-fold-away wire.
  - `pokey_pot` rewritten as a thin pass-through (M25-3c-shadow):
    `potgo_pulse` + `fast_scan` flow up to the bridge,
    shadow_pot0..7 + shadow_allpot flow back into POKEY's read mux.
    The HDL discharge-counter loop is gone.
  - **peri-RP firmware** (M25-3c-firmware): C state machine in
    `peri_pot.{c,h}` decodes CMD=POTGO writes, kicks the PIO scanner
    (via the production `peri_pot.pio`, stub today — needs hardware
    bring-up to validate the per-channel discharge timing), commits
    counts + ALLPOT into peri_regs and sets STATUS.pot_done on
    completion. `tb_peri_pot` host-tests the C state machine via
    PERI_POT_HOST_SIM injectable "scan-done" events. PIO program
    itself runs on hardware only.
- **M25-3d — ✓ IRQ aggregation.** STATUS register coalesces flag
  bits from POT (M25-3c — `pot_done`), SIO (M25-4 — `sio_rx`), SD
  (M25-5 — `sd_done`). Reading STATUS clears all flags + releases
  IRQ_OUT (peri_link.sv "IRQ-ack" semantics). peri-RP firmware:
  `peri_irq.{c,h}` owns the open-drain IRQ_OUT pin (PERI_IRQ_OUT_PIN);
  every path that touches STATUS calls `peri_irq_update()` which
  drives the pin low if STATUS != 0, releases otherwise.
  FPGA-side: `peri_pot_bridge.sv` listens for `peri_link.peri_irq_pulse`
  (falling edge of spi_irq, 2-FF synced) and short-circuits its
  POLL_DIV wait — STATUS poll fires immediately on IRQ rather than
  up to ~33 µs later. tb_peri_pot Phase A asserts `IRQ_OUT` is low
  while STATUS.pot_done is set + released after the read; tb_peri_pot_bridge
  Phase D asserts the FPGA-side short-circuit kicks the chain.

Acceptance per sub-milestone is a host-side C test that exercises
the relevant logic plus a hardware bring-up smoke. End-to-end
validation (FPGA peri_link ↔ peri-RP) is the M25-3 ship gate.

#### M25-4 — SIO state machine  🟡 in progress
<sub><a id="m25-4"></a>[⤴ status table](#status-at-a-glance)</sub>

SIO is the Atari peripheral bus (DATAIN / DATAOUT / /COMMAND /
/MOTOR / /PROCEED / /INTERRUPT / /READY / CLOCK_IN / CLOCK_OUT etc).
Two pieces:

- **M25-4-bridge — ✓ FPGA-side TX/RX path.** `peri_pot_bridge`
  renamed to `peri_bridge` and extended with SIO ports. POKEY's
  `serout_strobe` + `serout_byte` push bytes into peri-RP via
  SIO_OUT writes; STATUS bit 1 (`sio_rx`) seen during a poll
  triggers an SIO_IN + SIO_STAT read chain that drives
  `ser_in_byte` / `ser_in_byte_pulse` / `ser_framing_err` /
  `ser_input_overrun` / `ser_input_busy` / `break_key_pulse` back
  to POKEY. tb_peri_bridge Phases E + F cover both directions.
- **M25-4-firmware — 🟡 peri-RP TX/RX queues + register glue.**
  `peri_sio.{c,h}` owns the per-direction ring buffers
  (PERI_SIO_{RX,TX}_QUEUE_SIZE). peri_regs_handle hooks SIO_OUT
  writes → `peri_sio_handle_sio_out_write()` (TX enqueue) and
  SIO_IN reads → `peri_sio_handle_sio_in_read()` (RX dequeue +
  STATUS.sio_rx update). `peri_sio_service()` keeps SIO_STAT.busy
  in sync with the TX queue depth. `tb_peri_sio` host-tests TX
  enqueue, RX dequeue, queue overrun, framing+break flag pipe.
  PIO program (`peri_sio.pio`) is stubbed — bit-level UART framing
  needs hardware to calibrate per-baud-rate timing against a real
  Atari accessory.

Acceptance: tb_peri_bridge (FPGA) + tb_peri_sio (peri-RP) both
green, plus hardware bring-up against a real SIO peripheral (disk
drive, SIO2PC bridge) once the rp-XT board is in hand.

#### M25-5 — SD card driver  🟡 in progress
<sub><a id="m25-5"></a>[⤴ status table](#status-at-a-glance)</sub>

Hardware SPI peripheral on the peri-RP drives the SD card directly.
Two integration paths:

1. **Mount as an SIO device**: peri-RP runs a full Atari-SIO disk
   protocol stack on top of FAT32. The OS sees a regular Atari
   floppy drive at the SIO bus. Broad software compatibility, no new
   chiplet-ext registers.
2. **Native block driver via chiplet-ext registers**: small register
   file (CMD / SECTOR / STATUS / DATA) at e.g. $D5xx for xtc-aware
   programs to stream sectors directly. Higher throughput, requires
   software opt-in.

The two aren't mutually exclusive — both can coexist. FAT32 stack:
off-the-shelf port (TinyUSB-class licensing), no in-house FS code.

**M25-5 status**: scaffolding committed:
- `peri_sd.{h,c}` — state-machine shell (UNINIT → INITIALISING →
  READY ↔ BUSY, ERROR sink). Block read/write API enqueues a single
  request at a time (`peri_sd_read_block` / `_write_block`); test
  hooks (`peri_sd_inject_init_ok` / `_init_err` / `_block_done`) fire
  the events the production hardware-SPI ISR will fire.
- STATUS bit 2 (`sd_done`) integrated with `peri_irq_update()` — same
  IRQ-aggregation path POT and SIO use.
- `tb_peri_sd` host-tests init flow, block read → done → STATUS,
  request rejection while BUSY, init error.

Pending hardware bring-up: hardware SPI peripheral configuration, the
actual CMD0/CMD8/ACMD41/CMD58 init sequence, CMD17/CMD24 block I/O,
the FAT32 stack, and either the SIO-disk-emulation glue (path 1) or
the chiplet-ext register window (path 2). The scaffold lets the
STATUS / IRQ / register paths be exercised end-to-end while those
land.

### M-PBI — Parallel Bus Interface + cart slot + ECI  ✓ (HDL complete)
<sub><a id="m-pbi"></a>[⤴ status table](#status-at-a-glance)</sub>

External-bus fanout for cart slot / PBI / ECI peripherals.
**There is no external 6502 socket on rp-XT** — the internal SALLY
is always bus master in deployment, and the external bus is a
slave-side fanout. The architectural rule "external bus active
only at CLOCK_MULT=1" is implemented as **internal D=Q hold** on
the output flops, not just LVC8T245-OE-disable. At CLOCK_MULT ≥ 2
the FPGA pads stay static — no SSO event, no EMI, no
dynamic-power burn at clk_bus rate. See
[architecture.md § External bus interfaces](architecture.md).

#### Sub-milestones

#### M-PBI step 1 — new bus signals + internal gating  ✓ (commit `ae29ceb`)

New output ports on antic_top: `bus_addr_o[15:0]`, `bus_rw_o`,
`bus_d0xx_n_o`, `bus_d4xx_n_o`, `bus_d1xx_n_o` (= /EXTSEL on PBI),
`bus_s4_n_o`, `bus_s5_n_o`, `bus_cctl_n_o`, `bus_extenb_n_o`. New
2-FF-synced inputs: `bus_mpd_n_in`, `bus_extirq_n_in`, `bus_rd4_in`,
`bus_rd5_in`. /EXTIRQ wired-OR'd into POKEY's `irq_n` at the top
level (both at the external `irq_n` pin and SALLY's `.irq_n` input).
Gating signal: `ext_bus_active = cpu_internal_q ? (clock_mult_q ==
8'h01) : 1'b1` — testbench mode keeps the bus permanently active so
tb_read / tb_snoop continue to pass on the same cycle as the read
address; production mode holds D=Q on the new output flops at
CLOCK_MULT ≥ 2.

Synth: clk_bus **171.15 MHz / +0.327 ns slack**, ram_clk 245.2 MHz
/ +0.921 ns slack. **+1749 FF / +1512 LUT** vs post-CK_n-drop
baseline — the new output flops actually *improved* fmax by ~2 MHz
because PnR got cleaner placement headroom on the IO ring. 45/45
sims pass.

#### M-PBI step 2 — $D481 status bits + /MPD $D800-$DFFF mask  ✓ (commit `7307e32`)

`antic_regs`'s $D481 read response gains 4 new bits exposing the
synced inputs: `[4]=RD4`, `[5]=RD5`, `[6]=/MPD`, `[7]=/EXTIRQ`.
Software polls $D481 to detect cart hot-plug and PBI status.
`sally_mem` gains a `bus_mpd_n_in` input and a `was_mpd_window_q`
tracker flop; the data_out mux returns `8'hFF` when /MPD is
asserted and the previous address fell in $D800-$DFFF (the OS-ROM
hi window). Without /MPD, behaviour unchanged.

Synth: clk_bus **166.86 MHz / +0.177 ns slack** (−4.3 MHz vs step
1; the new `(was_mpd_window_q & mpd_active)` AND added one LUT
level to the cache-read hot path). +11 FF / +1 LUT. 45/45 sims
pass (tb_sally_mem needed a 1-cycle tie-off update for the new
`bus_mpd_n_in` port).

#### M-PBI step 3 — FPGA-as-bus-master writes + /D1xx/MPD read capture  ✓ (commit `3d932ac`)

Three changes complete the bus-master cycle protocol: (a) new 8-bit
2-FF sync on `bus_data_in[7:0]` → `bus_data_in_q`; (b) the
`sally_hwreg_dout` mux in antic_top gains a $D1xx case routing to
`bus_data_in_q` so SALLY reads from the PBI page see the device's
drive; (c) `sally_mem` gains a `bus_pbi_rdata` input — the /MPD
$D800-$DFFF override changes from the `8'hFF` stub to the real
external value; (d) `bus_data_out` / `bus_data_oe` restructured
into a 3-way mux: `prod_write_drive` (cpu_internal_q &
clock_mult_q == 1 & R/W = 0) drives `snoop_bus_data_w` outbound
for SALLY writes so PBI / cart / ECI slaves can latch them.
Testbench mode (cpu_internal_q=0) unchanged.

Synth: clk_bus **165.45 MHz / +0.126 ns slack** (−1.4 MHz vs step
2). +13 FF / **−334 LUT** (Synplify rebalanced placement once the
bus_data_out logic restructured into a cleaner 3-way mux). ram_clk
recovered to 247.6 MHz. 45/45 sims pass.

**Ship criterion (met)**: 45/45 FPGA sims passing, clk_bus closes
at 165.45 MHz with +0.126 ns slack at 162 MHz target (4.4 MHz
above BASE_DIV=90 floor), all PBI / cart / ECI external pins
correctly gated to CLOCK_MULT=1 production cycles.

#### M-PBI #1 + #2 — phi2-fall capture + RD4/RD5 cart override  ✓ (commit `9edccce`)

Two deferred-future-work items from future-work.md closed in one
commit since they share the same `bus_pbi_rdata` plumbing.

**#1**: antic_top gains a `phi2_fall` pulse and an 8-bit
`bus_pbi_rdata_q` register that captures `bus_data_in_q` on each
phi2 falling edge. The captured value is stable through phi2-low
into the next phi2-high. Replaces the live `bus_data_in_q` in
both consumers — `sally_hwreg_dout` $D1xx case and
`sally_mem.bus_pbi_rdata` — giving PBI/cart slaves the full
phi2-high window to drive D[7:0] before SALLY samples.

**#2**: `sally_mem` gains two new inputs (`bus_rd4_n_in`,
`bus_rd5_n_in`) and a `was_cart_external_q` tracker flop. New
combinational `cart_external_read = rw & ((cart-s4 & ~rd4) |
(cart-s5 & ~rd5))` identifies cart-window reads when a physical
cart is plugged in. The data_out mux's priority becomes:
hwreg → **cart-external** → /MPD → bank → BRAM. Physical-cart-
plugged-in wins over any HyperRAM-mirrored cart image. Writes
still route through the cache (cart hardware ignores writes).

Synth: clk_bus **169.18 MHz / +0.259 ns slack** (+3.7 MHz vs step
3 — PnR found a better placement on the cache-read hot path once
bus_pbi_rdata sources from a clean registered output rather than
the 2-FF sync chain). +19 FF / +699 LUT. ram_clk 234.3 MHz
(rebalanced toward clk_bus, still 34 MHz above target). 45/45
sims pass.

**Remaining deferred follow-up work** lives in [future-work.md
§ M-PBI deferred items](future-work.md) — #3 /EXTIRQ
fall-back-to-phi2 mode and #4 tb_pbi behavioural integration
test.

#### M-PBI #3 + #4 — /EXTIRQ fall-back + tb_pbi integration test  ✓ (commit `7f547c9`)

Closes the last two deferred items. M-PBI is now fully complete.

**#3**: antic_regs gains a `$D481[3] = auto_phi2_on_extirq`
software-writable enable bit, an internal
`extirq_fallback_active_q` flag, and a `bus_extirq_n_prev_q`
edge-detector. On the falling edge of /EXTIRQ when the enable
is set, the fallback flag goes high; on the rising edge (PBI
deassert), it clears. `clock_mult_q` output gets a 2-way mux —
`extirq_fallback_active_q ? 8'h01 : serial_clock_mult_in` — so
SALLY is forced to CLOCK_MULT=1 for the duration of the PBI IRQ
without any software action. PBI handlers can reach $D1xx
immediately without first writing $D480.

**#4**: new `sim/tb_pbi.sv` (8 phases) exercises post-reset
sanity, address decode, output flop tracking, $D481 PBI status
visibility, /EXTIRQ → irq_n propagation, phi2-fall capture,
fall-back-to-phi2 mode, and ext_bus_active gating at fast mode.

Synth: clk_bus **167.11 MHz / +0.186 ns slack** (−2.1 MHz vs
#1+#2 from the new clock_mult_q mux on the path into sally_clock).
**−42 FF / −541 LUT** vs #1+#2 (the fall-back state machine is
tiny; Synplify rebalanced surrounding logic). ram_clk 228.2 MHz
(still 28 MHz above target). 46/46 sims pass.

## Per-milestone discipline

One commit per milestone. Each commit message references:

- Which milestone (M3, M9, etc.).
- What the ship-criterion was.
- Any deviation from the docs (and update the doc in the same commit).

Don't squash — keeping milestones separate makes it easier to
git-bisect a regression to "the milestone that introduced the bug".

When a milestone has both FPGA and RP work (Phase 2 onwards), commit
each side separately under its own subject prefix:

- `hdl: M3 - rp_tx + rp_rx skeleton`
- `rp:  M3 - bus.pio + bus_server.c skeleton`

Then a third commit that updates the integration sim:

- `sim: M3 - tb_rp_bus round-trip closes`
