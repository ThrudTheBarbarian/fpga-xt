# sally_mem_v2 — DDR3-era memory subsystem for SALLY

**Status**: design draft, 2026-05-14. Implementation hasn't started.

## Motivation

Phase 0 fmax probe (sally_synth_top on xc7z020-2clg400) closed at
**~96 MHz post-route** against a 165 MHz target. Both the post-synth
and post-route worst paths sit inside `u_mem/u_bank_cache_*`. The
critical path family is structurally tied to the cache shape:

- Post-synth worst path: BRAM-out → 12 logic levels → `bank_cache_code/miss_byte_off_q_reg` CE
- Post-route worst path: FDRE → `bank_cache_data/g_data[1].u_mem/g_narrow.mem_reg_64_127_3_5/RAMA/I` (LUT-as-RAM write)

The cache was designed to mask HyperRAM's ~70 ns random-access latency
on the Generation-2 N6 path. With the Zynq pivot, that latency target
is gone — DDR3 via Zynq AXI HP has different characteristics, and the
99 % case (main 64 KB Atari RAM) already lives entirely in BRAM and
never touches DDR3.

The cache is therefore *both* the fmax bottleneck *and* architecturally
unjustified. `sally_mem_v2` replaces it with something proportionate to
what DDR3 actually requires.

## What we measured / what changes

| Aspect | sally_mem v1 (HyperRAM-era) | sally_mem_v2 (DDR3-era) |
|---|---|---|
| Main 64 KB Atari RAM | 16× RAMB36E1 (BRAM) | **unchanged** — 16× RAMB36E1 (BRAM) |
| Banked windows ($4000–$7FFF when PORTB-selected; cart > 16 KB) | N-way set-assoc cache w/ NUM_SETS=16, NUM_WAYS=4, LINE_BYTES=1024 in front of HyperRAM | **AXI-master read FSM** to PS DDR3, optionally fronted by a 1-line prefetch buffer |
| Address space | 23-bit (`HR_ADDR_W`) into 8 MB HyperRAM | 32-bit AXI4 into 1 GB PS DDR3 |
| Transaction protocol | `hr_req`/`hr_burst_len`/`hr_rdata`/`hr_rvalid`/`hr_done` (HyperRAM bespoke) | AXI4-Lite read or AXI4 burst (8-beat × 8-byte) |
| Partial vs streaming HR access split | `code_part_hr_*` / `code_strm_hr_*` (latency-hiding shape) | one path; AXI bursts are AXI bursts |
| LUTs estimate | ~1200 (cache + line RAM + FSMs) | ~200–300 (AXI master + 1-line buffer) |
| Critical path | BRAM-out → 12-level cache decode → flop CE | BRAM-out → 1-cycle pipe → SALLY rdata mux |

Result: the bottleneck-defining cone disappears entirely. ~1000 LUTs
recovered. fmax expected to recover into the 130–160 MHz -2 range the
architecture memory predicted, without touching the SALLY core.

## Architecture

```
                       cpu_addr ──┐
                                  ▼
                   ┌──────────────────────┐
                   │  address decode       │
                   │  (BRAM / hwreg /      │
                   │   bank / cart / pbi)  │
                   └─┬─────┬─────┬─────┬───┘
                     │     │     │     │
              BRAM ◄─┘     │     │     └─► external bus (cart RD4/5, PBI MPD)
              ($0000-                          (unchanged from v1)
               $FFFF)
                           │     │
                           │     └─► hwreg passthrough
                           │           ($D000-$D5FF chiplet regs;
                           │            unchanged from v1)
                           ▼
                ┌─────────────────────┐
                │ banked-window port  │
                │ (NEW)               │
                │                     │
                │  ┌───────────────┐  │
                │  │ 1-line prefetch│  │
                │  │ buffer (64 B)  │  │
                │  └───────┬───────┘  │
                │          │          │
                │  ┌───────▼───────┐  │
                │  │ AXI-master    │  │
                │  │ read FSM      │  │
                │  └───────┬───────┘  │
                └──────────┼──────────┘
                           ▼
                   AXI HP → PS DDR3
```

Three response paths feed `data_out`:

1. **BRAM hit** (main 64 KB): 1-cycle latency. The SALLY `rdy` contract
   is satisfied — data on cycle N+1 from addr on cycle N.
2. **Prefetch-line hit** (banked-window, sequential): 1-cycle latency
   (line buffer is BRAM-mapped). SALLY does not stall.
3. **Prefetch-line miss** (banked-window, first byte of a new line):
   `rdy` is de-asserted; AXI burst-read fetches 64 bytes into the line
   buffer (~25–40 cycles); first byte delivered on completion; next
   ~63 sequential accesses hit the line buffer.

## Address decode

| CPU address | Source | Notes |
|---|---|---|
| `$D000–$D5FF` | hwreg passthrough (unchanged) | ANTIC/GTIA/POKEY/PIA + chiplet-ext registers |
| `$D800–$DFFF` while `/MPD` active | external PBI | unchanged from v1 |
| `$8000–$BFFF` while `/RD4` or `/RD5` active | external cart | unchanged from v1 |
| `$4000–$7FFF` while PORTB[4]=0 (XE banking enabled) | banked-window port (DDR3) | DDR3 address = `{base, port_b[7:2], addr[13:0]}` (TBD) |
| all other addresses | BRAM | the standard Atari address space |

Window detection logic is the same shape as today's `is_in_window_w` —
no fmax-critical changes needed.

## Banked-window port — interface

A new fabric module `banked_axi_reader`:

```systemverilog
module banked_axi_reader #(
    parameter int unsigned AXI_ADDR_W  = 32,
    parameter int unsigned LINE_BYTES  = 64
)(
    input  wire         clk,
    input  wire         rst,

    // SALLY-side request
    input  wire [31:0]  req_addr,        // DDR3 address (decoded upstream)
    input  wire         req_valid,
    output wire [7:0]   req_rdata,
    output wire         req_ready,       // 1 = hit, drives SALLY rdy

    // AXI4 read master (HP0 by default)
    output wire [31:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,     // 7 → 8-beat burst → 64 B
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [63:0]  m_axi_rdata,
    input  wire         m_axi_rvalid,
    input  wire         m_axi_rlast,
    output wire         m_axi_rready
);
```

Internal state:

- `line_addr[31:6]` — the 64-byte line currently buffered (or invalid)
- `line_valid` — buffer-occupied flag
- `line[63:0][8]` — the line buffer, BRAM-mapped (8 × 64-bit beats)
- `fsm` — `IDLE` / `AR` (drive arvalid, wait arready) / `R` (consume
  8 beats) / `DONE`

Hit logic:
```
hit = req_valid && line_valid && (req_addr[31:6] == line_addr[31:6])
req_ready = hit       // 1-cycle response
req_rdata = line[ req_addr[5:3] ][ req_addr[2:0]*8 +: 8 ]
```

On miss: de-assert `req_ready`, latch `line_addr`, kick the AXI burst.
When `rlast` arrives, set `line_valid` and re-assert `req_ready` —
SALLY un-stalls and reads the first byte.

## Writes to banked windows

CPU writes to banked DDR3 windows aren't on the fmax-critical path
(they're rare and they're rare-er still since the cycle count of
write-back-then-restall would dominate any banked-write workload). v2
options:

- **A — Write-through, write-no-allocate**: every CPU write to a banked
  address kicks a single-beat AXI write; line buffer invalidated if the
  written address falls within the cached line. Simple; CPU stalls
  the full ~25 cycles per write.
- **B — Write-back to line buffer + lazy flush**: writes update the
  buffer in 1 cycle and a dirty flag; a flush triggers on
  line-eviction (next miss) or on a flush-strobe register. Faster CPU
  writes, but adds a flush state and a coherency contract with the
  modern-half view of DDR3.

**Recommendation**: start with **A** (write-through). Simpler to reason
about, simpler to verify. Banked-window writes are infrequent in legacy
Atari workloads. Upgrade to **B** later only if benchmarks show it
matters.

## Parameters and addresses

| Parameter | v1 (HyperRAM) | v2 (DDR3) |
|---|---|---|
| `HR_ADDR_W` | 23 (8 MB) | dropped |
| `AXI_ADDR_W` | n/a | 32 (1 GB DDR3 + headroom) |
| `LINE_BYTES` | 1024 | 64 |
| `NUM_SETS` | 16 | n/a (single line) |
| `NUM_WAYS` | 4 | n/a |
| `CPU_OFFSET_W` | 12 | n/a — direct AXI address |
| `BANK_ID_W` | 8 | n/a — banked DDR3 address fully decoded upstream |
| `CACHE_WORD_BYTES` | 2 (Step 7) | 8 (AXI HP native width) |

Bank-id arithmetic stays in the address-decode logic upstream of
`banked_axi_reader` — that module sees a flat 32-bit AXI address and
doesn't know about Atari banks.

## What gets discarded

| File | Fate |
|---|---|
| `hdl/bank_cache.sv` | **delete** — replaced by `banked_axi_reader.sv` |
| `hdl/cache_line_ram.sv` | **delete** — line buffer is a tiny BRAM inferred inline |
| `hdl/hyperram_phy.sv`, `hyperram_shim.sv`, `hyperram_mock.sv` | **delete** — already excluded from synth, no longer relevant |
| `hdl/mem_read_mux.sv` | review — likely simplifies; might delete |
| `sally_mem.sv` HR-port plumbing (`hr_addr`, `hr_burst_len`, `code_part_*`/`code_strm_*` arbitration) | **delete** — replaced by single `req_*` interface to `banked_axi_reader` |
| `tb_bank_cache.sv`, `tb_bank_cache_*.sv` testbenches | **archive** — replaced by `tb_banked_axi_reader.sv` |

Estimated net deletion: ~1200 LOC of HDL + ~2000 LOC of testbench.

## What stays

- `sally_core.sv`, `sally/cpu.v`, `sally/ALU.v` — untouched
- `sally_clock.sv` — untouched
- `bank_xlat.sv` — address translation logic (XE PORTB → bank-id);
  upstream of banked_axi_reader; untouched
- BRAM main memory in `sally_mem.sv` — untouched (already BRAM-inferable
  after the synth fix landed today)
- Hardware-register passthrough — untouched
- External-bus override paths (PBI /MPD, cart /RD4 /RD5) — untouched

## Migration plan

Three increments, each independently testable.

**v2a — strip the cache, AXI master only, no prefetch buffer.**
Every banked-window access stalls SALLY for the full AXI latency
(~25–40 cycles). Goal: prove fmax recovers and the architecture is
correct. Re-run the Phase 0 fmax probe — expectation: WNS goes positive
at 165 MHz; the cache-critical path is gone.

**v2b — add the 1-line prefetch buffer.**
Sequential access in banked windows hits the buffer; only line-cross
events stall. Expected to bring banked-code effective rate from
~24 MHz (no-buffer) back near full clock for sequential workloads.

**v2c — write-through writes to DDR3.**
Until v2c lands, banked-window writes are dropped or asserted-out.
Most legacy code doesn't write to banked windows, so this is fine for
bring-up but isn't a shippable state.

Each increment ends with passing testbenches + a Vivado synth report
showing WNS / utilisation.

## Open questions

1. **Does the prefetcher need eviction on banked-window writes from
   the modern half?** The modern half can DMA into DDR3-backed Atari
   memory (e.g. loading a cart image). If SALLY's prefetch buffer
   holds stale data while the modern half writes underneath, SALLY
   reads stale bytes. Options:
   - Modern half issues a "flush SALLY line buffer" register write
     before/after touching banked regions
   - banked_axi_reader snoops a modern-half coherency strobe
   - Modern half only writes when SALLY is held in reset (simplest;
     fits cart-load semantics)

   **Default**: third option for v2. SALLY held in reset during cart-
   load is the same assumption Atari hardware makes.

2. **AXI HP port choice and clock**. HP0 is the default. Whether AXI
   HP runs at SALLY clock (165 MHz) or at a separate, higher clock
   (250 MHz, Zynq max) affects DDR3 latency in SALLY cycles. Need a
   CDC FIFO if they're decoupled. Default: same-clock for v2a, revisit
   for v2b.

3. **Should DDR3 host more than banked Atari memory?** The framebuffer
   needs DDR3. xt-blitter command rings need DDR3. The modern half
   needs DDR3 for FreeRTOS heap. These are separate AXI masters on
   separate HP ports; banked_axi_reader is just one of (likely four)
   AXI masters into DDR3. The DDR3 bandwidth budget (~600 MB/s per
   HP port, ~2.4 GB/s aggregate) easily covers all of them.

## Why this is the right v2 design

- **Eliminates the fmax-critical path family** without touching the
  SALLY core.
- **Architecturally honest**: the cache existed to hide a latency that
  no longer applies. Removing it is not a regression — it's removing
  inherited complexity.
- **Verifiable incrementally**: v2a → v2b → v2c each ship a working
  system, each with measurable timing and coverage.
- **Reduces HDL surface area** by ~1200 lines (cache + line RAM +
  HyperRAM mock).
- **Recovers ~1000 LUTs** for use by the rest of the system (xt-blitter,
  ANTIC pipeline, debug logic).

The architecture memory's predicted "~130–160 MHz on -2 grade" should
be reachable with v2a alone, before any pipelining tweaks. Validates
the pivot's fmax assumption.
