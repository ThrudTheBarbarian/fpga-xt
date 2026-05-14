# Current state — Phase 1a (SALLY + ANTIC integrated on Zynq-7020)

Session date: 2026-05-14.

## Overall goals

See [docs/zynq-architecture.md](./zynq-architecture.md) for the full plan.
In short: replace the Efinix Ti60 + STM32N6 dual-chip design with a single
Zynq-7020 SoC (on a Z-Turn SOM), targeting ~$150/board at ≤100 units.

## What exists

### Top-level module: `fpga_xt_top` (hdl/fpga_xt_top.sv)

Integrates the main SALLY CPU stack + ANTIC video pipeline on a single
clock domain (clk_50 = clk_sally = clk_bus = 100 MHz).  Three sub-systems:

1. **SALLY CPU** — Arlet 6502 core + sally_mem (64 KB BRAM, dual-port for
   ANTIC DMA reads) + sally_clock (RDY gating) + banked_axi_reader (AXI
   master for DDR3-backed banked-memory window, tied off for Phase 1).
2. **ANTIC video pipeline** — full ANTIC/GTIA/POKEY chain with DL parser,
   compositor, GTIA colour resolution, line buffer, scan-out, palette LUT,
   and parallel RGB565 + sync output (via hdmi_out_zynq.sv — no TMDS
   serializers, drives SiI9022A HDMI transmitter on the Z-Turn SOM).
3. **Peripheral I/O** — PIA shadow ($D300), joy_bridge (PCAL9722 SPI),
   peri_bridge (SIO + POT), PCM1808 stereo I²S ADC, bus-snoop for M-PBI
   cart/PBI bus mastering.

### Build flow: `vivado/run.sh` + `vivado/build.tcl`

- Remote build on Ubuntu (Vivado 2025.2.1) via rsync.
- Out-of-context synthesis (no IO pads) for fmax probing.
- Default synthesis directives (no aggressive timing, no retiming).
- Default implementation (opt + place + route, no aggressive directives).
- Single `clk_50` clock constraint at 10 ns (100 MHz).

### Dead code removed (this session)

~250 lines stripped from antic_top.sv that were Efinix N6-era carryover:

| Removed | Reason |
|---------|--------|
| Shadow SALLY core (sally_core + sally_mem + sally_clock inside antic_top) | Main CPU in fpga_xt_top handles everything |
| N6 PSSI serial stream (pssi_tx, pssi_bytes) | No N6 co-processor on Zynq |
| FPGA↔RP serial links (rp_tx, rp_rx) | No RP2040 on this platform |
| HyperRAM miss-handler FSM + mock PHY signals | BRAM shim replaces HyperRAM |
| cache_regs ($D380-$D3FF) | v1 cache register file, unused |
| bank_translator | v1 cache address translator, unused |
| Stale output ports (sally_addr_o, sally_data_o, xlat_phys_addr_o) | Observability ports for removed modules |
| clk_pssi, rst_pssi_n input ports | No PSSI domain |
| n6_fmc_* port references | Already commented from port list but still referenced in assign statements |

Build.tcl updated to exclude 13 unused modules from elaboration.  6 new
files committed (fpga_xt_top.sv, bram_shim.sv, hdmi_out_zynq.sv,
cdc_fifo_1w1r.sv, cdc_sync_bit.sv, docs/sprite-engine.md).

## Timing at 100 MHz (10 ns period)

```
WNS = +0.343ns, TNS = 0.000ns, 0 failing endpoints (of 6763)
WHS = +0.093ns, THS = 0.000ns (hold clean)
```

All constraints met with margin.

### Utilization on XC7Z020-2CLG400 (Z-Turn full)

| Resource | Used | Available | Util% |
|----------|-----:|----------:|------:|
| Slice LUTs | 1,497 | 53,200 | 2.81% |
| Slice Registers | 2,002 | 106,400 | 1.88% |
| Block RAM Tile | 33.5 | 140 | 23.93% |
| RAMB36E1 | 32 | 140 | 22.86% |
| RAMB18E1 | 3 | 280 | 1.07% |

Plenty of room for xt-blitter, FreeRTOS, LVGL, and everything else.

### fmax bottleneck

The critical path is the unpipelined Arlet 6502 ALU carry chain:

```
u_sally_mem/mem_reg_0_7 (BRAM cascade) → 13 LUT levels in ALU
→ u_sally_core/u_cpu/ALU/CO_reg (carry-out register)
```

- Data path delay: 9.372 ns (45% logic, 55% route)
- 14 logic levels (1 BRAM + 13 LUTs)
- fmax ~107 MHz

Retiming (`-retiming` / `-global_retiming`) made no difference — the ALU
carry chain has no intermediate registers for the retimer to exploit.
Fixing this requires either:
- A pipelined CPU core (e.g. 65816 with pipelined memory access)
- Multi-cycle path constraints on the ALU
- Adding a register stage between sally_mem and the CPU data input

The 65816 route is noted as desirable anyway for 6502 compatibility in
8-bit mode (see session notes).

## Phase 1a exit gates — build results

Per [zynq-architecture.md](./zynq-architecture.md) Phase 1 exit criteria:

| Gate | Status |
|------|--------|
| SALLY core boots from BRAM | ✅ Synthesises + implements cleanly. 100 MHz timing closed. |
| ANTIC pipeline produces legacy video | ✅ Compositor + line buffer + scan-out + palette LUT all present. Parallel RGB565 + sync outputs. |
| HDMI output via SiI9022A | ✅ Parallel RGB565 ports driven by hdmi_out_zynq. TMDS chain removed. |
| Per-module testbenches pass | ⚠️ Not yet run under Vivado XSIM (no local simulator setup). |

## Next steps (Phase 1b → Phase 4)

### Phase 1b — Multi-clock domains (next session)

Currently all logic runs on a single `clk_50` (100 MHz) clock.  The
architecture targets three domains:

| Domain | Target | Source |
|--------|-------:|--------|
| clk_sally (SALLY CPU) | 100 MHz | Currently clk_50 directly |
| clk_sys (ANTIC pipeline) | 162 MHz | Needs PLL-generated clock |
| clk_pix (pixel output) | 25.175/40 MHz | Needs PLL-generated clock |

Steps:
1. Instantiate a PLL (MMCME2_BASE or similar) to generate the three clocks
   from the 50 MHz reference.
2. Add `create_clock` constraints per domain with appropriate periods.
3. Add `set_clock_groups -asynchronous` for CDC paths.
4. Validate that the CDC bridges (cdc_fifo_1w1r, cdc_sync_bit) work at
   target frequencies.

### Phase 2 — xt-blitter v0

Implement the 2D GPU command parser + primitives (fill, line, blit, etc.)
as AXI-stream consumers.  Byte stream arrives via the existing $D49C
register path (same VDI wire format as the N6 design).

### Phase 3 — FreeRTOS + LVGL

Vitis FreeRTOS BSP on the Cortex-A9s.  PS side hosts:
- FatFs over SDIO
- USB HID (TinyUSB or XUSBPS)
- xt-blitter command ring driver (AXI register pokes)
- LVGL (LV_COLOR_DEPTH 16) rendering into DDR3 framebuffer

### Phase 4 — Atari I/O integration

Port PCM1808, cart slot, SIO, PBI bridges against PL pins.

## Files

| File | Purpose |
|------|---------|
| hdl/fpga_xt_top.sv | Top-level integration (SALLY + ANTIC) |
| hdl/antic_top.sv | ANTIC video pipeline + peripheral I/O |
| hdl/sally_mem.sv | 64 KB dual-port BRAM + banked-window AXI reader |
| hdl/sally_core.sv + hdl/sally/* | Arlet 6502 CPU |
| hdl/sally_clock.sv | Clock-enable + RDY gating |
| hdl/hdmi_out_zynq.sv | Parallel RGB565 + sync (replaces TMDS chain) |
| hdl/hyperram_shim.sv | BRAM-backed dual-read-port shim (replaced HyperRAM) |
| hdl/bram_shim.sv | Lightweight BRAM read-port for ANTIC DMA |
| hdl/cdc_fifo_1w1r.sv | Async FIFO for SALLY→ANTIC register writes |
| hdl/cdc_sync_bit.sv | 2-FF synchroniser for single-bit CDC |
| vivado/build.tcl | Non-project-mode Vivado build (OOC synth + impl) |
| vivado/constraints/sally_synth_probe.xdc | Timing constraints (100 MHz clk_50) |
| vivado/run.sh | rsync + remote-build wrapper |
| docs/zynq-architecture.md | Target architecture and phased migration plan |
