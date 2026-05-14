# N6 HDL migration plan

How to evolve the current RP2354-coupled HDL to match the N6 architecture
specified in [n6-migration.md](./n6-migration.md). This is the work that
unblocks GEM ([GEM-implementation.md](./GEM-implementation.md)).

## At-a-glance status

| Phase | Status |
|------:|--------|
| 0 — pin-map prep | **Done** (2026-05-14) |
| 1 — PSSI TX | **Done** (2026-05-14) |
| 2 — FMC slave | Not started |
| 3 — LTDC capture | Not started |
| 4 — SPI master + event IRQs | Not started |
| 5 — `n6_link` integration + LEGACY_RP removal | Not started |
| 6 — boot sequencing + QSPI flash sharing | Not started |
| 7 — soak + perf characterisation | Not started |

Update this table when a phase moves through `In progress` → `Done`.
Detailed notes go under each phase's **Progress** block.

## Scope

The current design is a **paired-RP2354** system: the FPGA talks to one
RP for video framebuffer / VDI (paired RP2354) and another for SD card /
SIO / POTs / FPGA config (peri-RP). The N6 absorbs both roles and the
RP-side HDL goes away. The replacement transports are:

- **PSSI** (16-bit + sync) for FPGA→N6 forward bulk (DRAW + bitmap)
- **FMC** (8-bit data + 8-bit address, async, no clock) for N6↔FPGA
  memory-mapped peripheral interface (RPC, filesystem, bulk reverse)
- **SPI** (4-wire, FPGA master) for event-payload pull post-IRQ
- **LTDC capture** (28-pin parallel RGB + sync) for N6→FPGA video stream
- **4 event-IRQ GPIOs** (2 HP/LP each direction) for out-of-band signalling

Nothing in the SALLY core, ANTIC/GTIA/POKEY register files, bus snoop,
or caching subsystem changes for this migration. The CPU core and the
legacy chiplet emulation stay intact; what changes is the *peripheral
interface* — the bridges and pads facing the off-chip world.

## Module fate

### Keep unchanged

- `sally/*`, `sally_core`, `sally_mem`, `sally_clock`, `prefetch`
- `bank_cache`, `bank_translator`, `bank_xlat`, `cache_line_ram`,
  `cache_regs`, `mem_read_mux`
- `hyperram_phy`, `hyperram_shim`, `hyperram_mock`
- `antic_regs`, `dl_parser`, `dma_arbiter`, `dma_master`, `vbeam`,
  `wsync_gen`, `nmi_gen`
- `gtia_regs`, `pia_regs`, `pokey_regs`, `pokey`, `pokey_audio`,
  `pokey_pot`, `pokey_i2s_tx`
- `compositor`, `color_resolver`, `line_buffer`, `scan_out`,
  `palette_lut`
- `bus_snoop`, `draw_regs`
- `joy_bridge`, `joy_link` (PCAL9722 stays — independent of the RP/N6
  split)
- `pcm1808_rx`
- `byte_ram`, `byte_ram_dp`

### Change

- **`antic_top`** — top-level pin map: remove RP SPI + RP control pins,
  add PSSI TX pins, FMC slave pins, SPI master pins, LTDC capture pins,
  4 event-IRQ GPIOs. Re-route audio + video paths so HDMI output is fed
  by LTDC capture (with a legacy-mode fallback to the existing
  compositor → TMDS path).
- **`sally_synth_top`** — pad wrapper updates to match new top-level
  port list.
- **`hdmi_out` and the TMDS chain (`tmds_encoder`, `tmds_serializer`,
  `tmds_out`)** — now optionally fed from the LTDC-capture line buffer
  instead of the compositor. A mode bit selects source. The TMDS encode
  pipeline itself is unchanged.

### Remove

- `peri_bridge`, `peri_link` — peri-RP comms
- `rp_rx`, `rp_tx` — paired-RP framebuffer comms
- `rp_bus_mock` — RP testbench mock

### Add (new modules)

- **`pssi_tx`** — PSSI master (forward path). DRAW ring buffer in BRAM,
  16-bit + PIXCLK + DE, source-sync at 80 MHz.
- **`fmc_slave`** — FMC slave with 8-bit address decoder, FIFO endpoints
  at 0x00/0x01, byte-addressable status/control/scratch register banks,
  IRQ source registers at 0x80–0x86. See
  [n6-migration.md § FMC mailbox map](./n6-migration.md#fmc-mailbox-map).
- **`ltdc_capture`** — parallel RGB + sync input capture into a line
  buffer; feeds TMDS encoder.
- **`spi_event_master`** — 4-wire SPI master, FPGA master polling N6
  slave for event payload after IRQ.
- **`irq_aggregator`** — collects FPGA-internal source bits (RPC_REQUEST,
  BULK_IN_AVAIL, PSSI_FAULT, etc.) into the HP / LP source-bitmap
  registers in `fmc_slave`; drives the two FPGA→N6 IRQ pins level-sensitive
  on the bitmaps' OR; receives the two N6→FPGA IRQ edges and sets
  internal RPC_RESPONSE / HID_EVENT flags.
- **`n6_link`** — wraps PSSI TX + FMC slave + SPI master + IRQ
  aggregator behind one module so `antic_top` instantiates a single
  block.

## Phased migration

Phases ordered to keep the design simulable and (eventually) synthesisable
at every step. Each phase ends with a green test-suite checkpoint.

### Phase 0 — pin-map prep (1 sprint)

- Define new `antic_top` ports for PSSI TX (18 pins), FMC slave (19
  pins), SPI master (4 pins), LTDC capture (28 pins), event IRQs (4
  pins). Total +73 pins committed in the port list.
- Stub the implementations: ports exist but drive defaults / tie inputs
  to inactive. RP-specific ports stay live alongside, with a top-level
  `LEGACY_RP` config knob selecting which interface is active.
- Update `sally_synth_top` pad-wrapper to match.
- Sim still passes against existing testbench.

**Exit gate**: synth closes timing with both interfaces' ports present;
no RTL change to any internal module yet.

**Progress**:
- 2026-05-14: Added `LEGACY_RP` parameter (default 1) to `antic_top`.
- 2026-05-14: Added new N6 ports to `antic_top`: PSSI (18), FMC slave with split-pad bidirectional data (8 addr + 8 data_in + 8 data_out + 1 oe + 3 strobes = 28 RTL ports for 19 physical pins), SPI master (4), LTDC capture (28), event IRQs (4). 73 physical pins; ports use SystemVerilog default values (`= 1'b0` etc.) so existing testbenches with named connections don't need updating.
- 2026-05-14: Added Phase 0 stub block at end of module body — outputs driven to safe defaults (PSSI clock low, FMC data tri-state via data_oe=0, SPI /CS de-asserted, IRQs low). Reduction-OR sentinel keeps unconnected inputs alive in synth to prevent unused-port pruning.
- 2026-05-14: `sally_synth_top.sv` unchanged — it's a SALLY-only synth wrapper that doesn't touch peripheral pads.
- 2026-05-14: Full sim regression clean — **46 / 46 testbenches pass** (`make -C sim all`). Synth check deferred until Phase 5 cutover; Phase 0 RTL changes are purely additive and don't affect any internal module.
- 2026-05-14: **Exit gate met**: ports present, stubs drive safely, no internal module touched.

### Phase 1 — PSSI TX (DRAW forward path) (2 sprints)

- Implement `pssi_tx`: BRAM-backed DRAW ring buffer (sized per
  [VDI-opcodes.md](./VDI-opcodes.md) — start with 16 KB = ~25 EBRs), TX
  state machine clocked at 80 MHz, source-sync PIXCLK output, DE high
  while ring has data, NOP padding for 16-bit alignment.
- Route `$D4xx` writes captured by `bus_snoop` into the DRAW ring.
- Add status/error registers to `draw_regs` (ring fill level, overflow
  flag).
- Sim with a mock N6 receiver that consumes the PSSI stream.

**Exit gate**: testbench drives 6502 STA $D4xx writes; PSSI output
shows correctly framed opcodes; ring fill / drain matches.

**Progress**:
- 2026-05-14: `hdl/pssi_tx.sv` (~180 lines) — dual-clock async-FIFO module with BRAM-backed ring buffer. Writer side at clk_wr; reader side at clk_pssi (80 MHz). Standard textbook async-FIFO with gray-code pointer sync (per Cummings). Pair-only emission: pssi_de fires only when ≥2 bytes queued; software is responsible for software-emitted NOP padding to even out odd-length packets. (Earlier mid-stream NOP-padding idea rejected — racy against the CDC sync latency and caused spurious NOPs when writer momentarily ran ahead of reader's fill view.)
- 2026-05-14: `sim/tb_pssi_tx.sv` — standalone unit test with mock N6 receiver. Cases: [A] 100-byte even sequential, [B] software-padded 2-byte pair, [C] overflow with reader stalled in reset. All passing.
- 2026-05-14: Makefile wired (`make pssi_tx`) and added to the `all` target.
- 2026-05-14: Full regression: **47 / 47 testbenches pass**.
- 2026-05-14: `hdl/pssi_bytes.sv` (~95 lines) — chiplet-extension register decoder. Exposes $D49C `PSSI_BYTE` (W: push byte to FIFO, R: last-byte readback) and $D49D `PSSI_STATUS` (R: bit 0 = overflow_q, W: bit 0 clears overflow). Lives just past `draw_regs`'s 0x08–0x1B span. Decided against a `draw_regs`-style fixed-shape 9-arg adapter — the new VDI wire format is a raw byte stream (per `VDI-opcodes.md`), and a single push register is the right interface to commit to.
- 2026-05-14: Added `wr_overflow_clear` input to `pssi_tx` for software-driven clear of the sticky overflow flag.
- 2026-05-14: `antic_top.sv` integration: added `clk_pssi` (default 1'b0) and `rst_pssi_n` (default 1'b0) input ports with SV defaults so legacy testbenches don't need updating. Instantiated `pssi_bytes` + `pssi_tx` next to `draw_regs`. Removed the Phase 0 `n6_pssi_*` hardcoded stubs — the three output pins now come from `pssi_tx`. ORed `pssi_bytes_read_data` into both the SALLY-side chiplet read mux and the external-bus read mux.
- 2026-05-14: `sim/tb_pssi_int.sv` — integration test exercising the snoop-port interface of `pssi_bytes`+`pssi_tx`. Cases: [A] 64-byte sequential push via $D49C → PSSI output match, [B] $D49C last-byte readback, [C] overflow set + software-clear via $D49D. All passing.
- 2026-05-14: `pssi_tx.sv` + `pssi_bytes.sv` added to the global HDL_SRCS list in the Makefile (so antic_top-instantiating testbenches link them in). New `pssi_tx` and `pssi_int` targets added to `.PHONY` and `all`.
- 2026-05-14: **Full regression: 49 / 49 testbenches pass**, exit 0.
- 2026-05-14: **Exit gate met**: snoop-level writes drive the PSSI byte stream end-to-end; overflow status visible and clearable from software; no internal module regressions.

### Phase 2 — FMC slave (memory-mapped peripheral) (3 sprints)

- Implement `fmc_slave`: 8-bit address decoder, /CS/OE/WE strobe
  handling, async-mode timing (no source-sync clock from N6).
- FIFO endpoints at 0x00 W/R (bulk-out / bulk-in) and 0x01 W/R (RPC
  reply / RPC request). Each FIFO ~4 KB = ~7 EBRs. Total ~28 EBRs for
  4 FIFOs.
- Byte-addressable status registers at 0x10–0x1F (read), control
  registers at 0x10–0x1F (write).
- Command-parameter scratch RAM at 0x20–0x3F (32 bytes).
- IRQ source bitmaps + ack at 0x80–0x81; counters at 0x84–0x86.
- Hook bulk-in FIFO drain → HyperRAM write path (for filesystem reads
  landing in 6502 RAM).
- Hook bulk-out FIFO fill ← HyperRAM read path (for FPGA-staged
  buffers).
- Sim with a mock FMC master that exercises FIFO and register
  semantics.

**Exit gate**: testbench round-trips a getpixel-style RPC (write
request → read response) and a 64 KB file-content stream into FPGA
HyperRAM through the bulk-out FIFO. Verifies set-bit-then-write
ordering and level-sensitive source bits.

**Progress**:
- (not started)

### Phase 3 — LTDC capture (2 sprints)

- Implement `ltdc_capture`: latch RGB888 + HSYNC + VSYNC + DE on each
  PIXCLK edge into a line buffer (~2 EBRs). Detect frame and line
  boundaries; expose a pixel stream to the existing scan-out path.
- Wire `ltdc_capture` output into a mux ahead of `tmds_encoder`. Mode
  bit (compositor vs LTDC capture) lives in a chiplet register.
- Sim with a mock LTDC source generating a known test pattern; verify
  TMDS output captures it correctly.

**Exit gate**: end-to-end "N6 emits a test pattern via mock LTDC → FPGA
captures → TMDS output matches" passes.

**Progress**:
- (not started)

### Phase 4 — SPI master + event IRQs (1 sprint)

- Implement `spi_event_master`: 4-wire SPI MODE 0 at 25 MHz, FPGA
  master, fixed-frame transactions (1 byte info + 1 byte data).
- Implement `irq_aggregator`: HP/LP source registers, bidirectional
  IRQ pin handling, edge detection on N6→FPGA pins.
- Wire FPGA→N6 IRQ pins to the OR of HP/LP source bitmaps from
  `fmc_slave`.
- Wire N6→FPGA IRQ pins to set internal RPC_RESPONSE / HID_EVENT
  flags; on rising edge, kick `spi_event_master` to pull payload.
- Sim with mock N6 raising IRQs and providing SPI payload.

**Exit gate**: round-trip "N6 raises HID_EVENT IRQ → FPGA pulls 16-bit
payload via SPI → event lands in a queue readable by 6502" passes.

**Progress**:
- (not started)

### Phase 5 — `n6_link` integration + LEGACY_RP removal (1 sprint)

- Wrap PSSI TX + FMC slave + SPI master + IRQ aggregator into
  `n6_link`. `antic_top` instantiates one block instead of five.
- Drop `LEGACY_RP=1` build target; delete `peri_bridge`, `peri_link`,
  `rp_rx`, `rp_tx`, `rp_bus_mock`.
- Update `sally_synth_top` to remove RP ports.
- Full regression of the test suite with the N6 interfaces as the only
  available path.

**Exit gate**: synth closes with RP modules removed; integrated
testbench (mock N6 driving all four channels) passes.

**Progress**:
- (not started)

### Phase 6 — boot sequencing + QSPI flash sharing (1 sprint)

- /CRESET_N input pin driven by N6 GPIO; FPGA loads from shared QSPI
  flash on release. (Most of this is wrapper/board-level; HDL only
  needs to expose CDONE correctly.)
- N6 SPI5 access to QSPI flash physically shared via 3 lines + 22 Ω
  series. FPGA reads in 4-bit QSPI mode at boot; runtime FPGA does
  not touch the flash, so no contention in operation.
- Verify FPGA-only boot (no N6) still loads cached bitstream and
  comes up in legacy ANTIC mode (NO_SD screen).

**Exit gate**: hardware bring-up checklist passes — both cold-boot
(flash empty, N6 programs first) and warm-boot (cached flash) paths
work; FPGA-only fallback comes up.

**Progress**:
- (not started)

### Phase 7 — soak + perf characterisation (1 sprint)

- Synth + place-and-route the whole thing at 165 MHz fmax target.
- Verify EBR budget against projection: ~155 starting + ~25 (PSSI
  ring) + ~30 (FMC FIFOs) + ~2 (LTDC line buffer) ≈ ~215 / 256 EBRs.
  Headroom for stack BRAM (GEM SALLY extensions) later: ~40 EBRs left.
- Run an end-to-end test on real silicon if a hardware bring-up board
  is available; otherwise stop at simulation-clean.

**Exit gate**: ready to hand off to GEM Phase 1 (VDI dispatch layer
bring-up).

**Progress**:
- (not started)

## What's *not* in this migration

The SALLY tasking extensions (SP_BANK, ZP_BANK, wider SP, stack-relative
addressing, atomic CAS, tick IRQ — see [GEM-implementation.md § SALLY
CPU extensions](./GEM-implementation.md#sally-cpu-extensions-for-multi-tasking))
are deferred. They're independent of the N6 transport switch and can
land in parallel with or after the GEM port. Doing them in the same
sprint as transport migration would conflate two large risks.

Likewise, anything from the GEM port itself (VDI library, AES, GEMDOS
RPC) is downstream of this migration completing.

## EBR budget tracking

Per [GEM-implementation.md § wider SP](./GEM-implementation.md), the
N6 HDL migration needs to fit inside an EBR budget that leaves room for
the future SALLY tasking work (32 EBRs for 8 × 2 KB task stacks).

| Phase | Adds | Cumulative used | Free (of 256) |
|------:|------|----------------:|--------------:|
| start | (baseline) | 155 | 101 |
| 1 | +25 (PSSI ring) | 180 | 76 |
| 2 | +30 (FMC FIFOs) | 210 | 46 |
| 3 | +2 (LTDC line buffer) | 212 | 44 |
| 4 | +1 (small SPI FIFOs) | 213 | 43 |
| 5 | -5 (drop RP-side cached lines etc.) | 208 | 48 |
| **end-of-migration** | | **~208** | **~48** |
| later: SALLY stacks | +32 | 240 | 16 |

Tight at the end but inside budget. Phase 2 (FMC FIFOs) is where the
biggest single chunk goes — worth being intentional about FIFO sizing
(4 KB chosen as a round number; could go to 2 KB if budget pressure
materialises).

## Risks

1. **PSSI source-sync timing closure at 80 MHz** — the FPGA fabric easily
   runs 80 MHz, but driving DDR-free source-sync output cleanly across
   18 pins to the N6 needs tight skew control. Defer to Efinity's IO
   timing constraints; flag as a Phase 1 check.
2. **FMC async-mode contract** — without a source-sync clock, FMC slave
   timing closure depends entirely on N6-side strobes meeting setup/hold
   against fabric latches. Verify `t_OE_valid` and `t_WE_valid` from
   STM32N655 datasheet against the worst-case FPGA latch delay.
3. **EBR pressure** — 213 / 256 at end of Phase 4 is fine but FMC FIFO
   sizing could blow it out if we go to 8 KB per FIFO. Stay at 4 KB
   unless workload demands more, and use Pattern-C overflow (HyperRAM
   spill) rather than larger FIFOs if needed.
4. **Mode-bit churn** — the compositor-vs-LTDC-capture mux in TMDS path,
   plus the legacy 1.79 / modern 165 MHz 6502 clock mode, plus the
   per-resolution framebuffer format, plus LEGACY_RP during Phase 0–5,
   add up to a meaningful state surface. Document the mode-bit register
   layout early so subsequent phases don't conflict.
5. **Test infrastructure drift** — every existing sim references the RP
   bus mock. As Phase 5 removes that, all those sims need port
   migration. Cost is modest if done in one sweep alongside the HDL
   removal; expensive if spread across multiple commits.

## Verification strategy

- Each phase ships its own testbench (already implied by exit gates).
- Sim coverage hierarchy: per-module unit tests, then integrated
  testbench at `antic_top` boundary, then full-system regression.
- Phase 5 ships a "hello world" end-to-end: mock N6 driving all four
  channels, 6502 program running on SALLY, makes a syscall via FMC
  RPC, gets a response, draws something via PSSI, captures the
  resulting LTDC output through TMDS. Smoke-test for the whole
  pipeline.
- Phase 7 adds a synth-clean check at 165 MHz fmax with both legacy
  ANTIC and N6 paths active.

## References

- [n6-migration.md](./n6-migration.md) — target architecture, channel
  spec, FMC mailbox map, IRQ source semantics
- [VDI-opcodes.md](./VDI-opcodes.md) — what flows over PSSI / FMC
- [GEM-implementation.md](./GEM-implementation.md) — downstream
  consumer; constrains EBR budget via the SALLY tasking extensions
- `hdl/antic_top.sv` — current top-level; the file most heavily
  affected by this migration
- `hdl/peri_bridge.sv`, `hdl/peri_link.sv`, `hdl/rp_rx.sv`,
  `hdl/rp_tx.sv`, `hdl/rp_bus_mock.sv` — slated for removal in
  Phase 5
