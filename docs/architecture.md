# Architecture

## Decision: interesting (FPGA-owned ANTIC + RP2354 as smart video RAM)

`fpga-antic` commits to the **interesting** path described in
[../README.md § The interesting approach](../README.md):

- An Efinix T20 FPGA implements every realtime element of ANTIC +
  CTIA/GTIA in fabric: bus snoop, register file, display-list parser,
  per-scanline compositor, P/M overlay, collision, palette LUT, and
  TMDS DVI/HDMI scan-out.
- An RP2354 (48-pin, overclocked to ≈300–360 MHz) sits beside the
  FPGA as **intelligent video memory** — it owns the framebuffer and
  optionally accelerates drawing primitives.
- A pin-tight tagged bus connects them: FPGA→RP carries
  `FETCH(addr)` / `SET(addr,data)` / `DRAW(op,...)` opcodes;
  RP→FPGA returns 16 bits of colour-index per beat. Line-buffered
  into FPGA BlockRAM, **never per-pixel scan-out reads**.

There is no external SRAM chip; the RP's PSRAM/SRAM combined with its
on-die TCM is the framebuffer storage.

### Why not the traditional path

The README's traditional option (FPGA + 1 MB CY62158 SRAM) is the
boring engineering-safe path, and it would close timing more
conservatively. The interesting path is committed because the gains —
software-flexible drawing accelerators, a memory subsystem that scales
with extra RP2354s for higher resolutions, no second BOM line for an
SRAM chip — outweigh the marginal additional risk of getting the
FPGA↔RP bus right once.

### Why this is NOT rp-antic's failure mode redux

The temptation is to say "but rp-antic is dying because RP+PIO+IRQ
budget can't close — putting an RP back in the data path repeats that
failure." That misreads the rp-antic problem.

rp-antic puts a *single CPU* in charge of:

1. Bus snoop sample drain
2. ANTIC register file dispatch
3. Display-list parsing
4. Per-scanline composition (playfield + char + P-M + collision)
5. PRIOR priority resolution
6. Palette resolve
7. HSTX scan-out IRQ + DMA chain re-arm
8. /NMI / /HALT / /RDY pin assertion
9. WSYNC release
10. Inter-chip serial link service

All of that fights for the same 32 µs HSTX-chain-wrap deadline. M30
collision, M32 PRIOR priority, and M33 MODE_SNOOP runtime toggle have
all been deferred precisely because adding any new per-scanline work
overflows that budget.

The interesting fpga-antic design **moves every realtime path into
the FPGA fabric**, where the compositor is a continuous pipeline with
no IRQ concept. The RP2354 keeps only the work that has no per-pixel
deadline:

| Concern in rp-antic | Where it lives in fpga-antic |
|---|---|
| Bus snoop + drain | FPGA fabric, combinational dispatch |
| Register files | FPGA fabric |
| **System RAM** (cpu shadow + 130XE bank + cart banks) | **HyperRAM** attached to FPGA via Efinix HyperRAM Controller IP (M16) |
| DL parse | FPGA fabric (one walk per VBI), reads from HyperRAM |
| Compositor | FPGA fabric, per pixel-clock tick, reads from HyperRAM |
| PRIOR + collision | FPGA fabric, per pixel-clock tick |
| Scan-out / TMDS | FPGA fabric |
| /NMI / /HALT / /RDY | FPGA fabric |
| **Framebuffer storage** | **RP2354** — bulk memory only |
| **Drawing primitives** (LINE/FILL/ARC/CIRCLE) | **RP2354** — queued, no per-pixel deadline |

System memory and graphics memory are deliberately on different
chips: HyperRAM gets the bus-side reads (small, fast, every DL walk
+ every compositor pair), RP2354 gets the bulk framebuffer writes
and the queued DRAW opcodes. RP2354 keeps its software-GPU role
(M17 / M18) — the HyperRAM addition only takes over the
"system-RAM mirror" job that the BRAM cpu_shadow was doing.

The FPGA<->RP link is **line-buffered**: the FPGA prefetches one
framebuffer line into a ping-pong BlockRAM line buffer while the
other buffer drives TMDS scan-out. **In ANTIC-compat mode the
framebuffer is line-doubled (640×240) or line-tripled (800×200), so
each framebuffer line drives 2–3 output scanlines and the RP only has
to deliver a fresh line every 2–3 scanlines.** The contention surface
is reduced to "SRAM bandwidth + bank multiplexing inside the RP2354",
which is a fundamentally smaller problem than "RP cannot keep up with
HSTX IRQ".

DRAW commands have **no realtime deadline**. The FPGA queues them into
the RP's input bus; one ARM core picks them off and works through
them at whatever pace it can manage. If the queue fills the FPGA
back-pressures the bus until space opens. Realistic 6502 software
cannot saturate two ARM cores doing LINE/FILL — the user has spelt
this out: "they'd have to be constantly filling large areas of the
screen with bezier patches or similar for there to be back-pressure,
and that doesn't seem like a sustained load."

### What this commits us to

- A working FPGA HDL design + iverilog testbench (deliverable items
  3, 5).
- A working RP2354 firmware: C ARM code + PIO assembly + a paired sim
  that exercises FETCH/SET/DRAW round-trips (deliverable item 4).
- An integration sim that crosses the FPGA<->RP boundary so the
  combined system can be regression-tested before bring-up.
- An Efinity project that closes timing on the FPGA side (item 6).

## What fpga-antic is

The FPGA-based replacement for the Atari 8-bit's **ANTIC display chip
combined with the CTIA/GTIA video chip**, plus 640×480 / 800×600 60 Hz
DVI/HDMI scan-out. Owns:

- Driving the screen — display-list interpretation, scanline timing,
  HSYNC/VSYNC, mode-by-mode pixel composition.
- Reading display-list and screen-RAM bytes from system memory. In
  **DMA mode** ANTIC asserts `/HALT` and bus-masters the cycles; in
  **snoop mode** (the default), ANTIC passively observes the CPU's
  natural memory writes and shadows the relevant regions in its own
  64 KB BlockRAM mirror.
- Generating Non-Maskable Interrupts (`/NMI`) for VBI and DLI events.
- Handling WSYNC ($D40A) — clock-stretches the CPU via `/RDY` until
  the next horizontal sync.
- Exposing readable status registers (VCOUNT $D40B, NMIST $D40F).
- Owning the **CTIA/GTIA register bank** at $D000-$D01F.
- Compositing playfield + character + P-M graphics + collision into
  per-scanline pixel data.
- Driving DVI/HDMI through fabric TMDS at the chosen output mode.
- Issuing FETCH/SET/DRAW opcodes to the paired RP2354 to read/write
  the framebuffer and dispatch drawing accelerators.

## rp-XT system overview

`fpga-antic` is one of five chips on the rp-XT motherboard's 168-pin
PCIe x16 slot. The paired RP2354 sits on the same module as the FPGA
and is **not** addressable by SALLY — it is a private subsystem of
fpga-antic.

| Chip | Drives | Owns registers | Notes |
|------|--------|----------------|-------|
| **rp-SALLY** | A[15:0], D[7:0], R/W, /IRQ accept | n/a (CPU) | Drives bus cycles; asserts /ANTIC_* tag CS lines per cycle. |
| **fpga-antic** (this) | /NMI, /HALT, /RDY, TMDS→HDMI, possible I2S→HDMI audio mux | $D000-$D01F (GTIA), $D400-$D40F (ANTIC), $D480-$D4FF (chiplet ext) | Snoops the bus; in DMA mode also bus-masters. Talks to its private RP2354 over the FETCH/SET/DRAW bus. |
| **fpga-antic-RP** (paired RP2354, private) | (none on system bus) | (none — private) | Holds framebuffer. Implements LINE / FILL / ARC / CIRCLE drawing primitives. Slave to FPGA on the FETCH/SET bus. |
| **rp-POKEY/PIA** | SIO, audio I2S out | $D200-$D20F (POKEY), $D300-$D303 (PIA) | Also pushes joystick/trigger state to ANTIC over serial. |
| **rp-MMU** | RAM bus responses | (no register page) | Owns 64 KB main memory + bank-switched extensions; serves bus reads. |
| **rp-syscontroller** | CLK (PLL), /G_RST, /Dxxx CS pre-decode, serial config | $D7FF (boot-go), console-key state | Boots the system, distributes clock, holds others in reset until configured. Pushes console-key state to ANTIC over serial. |

ANTIC, GTIA and the video pipeline are **all in the FPGA**. There is
no separate rp-CTIA or rp-GTIA. The paired RP2354 is part of
fpga-antic's implementation, not a separate chiplet.

## CPU model

**fpga-antic has no provision for an external 6502.** The internal
SALLY (Arlet's 6502 core, instantiated in `hdl/sally/cpu.v`) is
always the system bus master in deployment builds. The earlier
"chiplet" framing — where rp-antic / fpga-antic listened to a real
external Atari's bus — is **historical**; in fpga-antic the bus is
synthesised internally end-to-end.

The `cpu_internal` flag at `$D481[1]` is a test-bench seam: when
set to `0` the synth wrapper exposes raw `bus_addr` / `bus_data` /
`bus_rw` inputs so testbenches can stimulate the register-decode
pipeline directly without bringing up SALLY. Production silicon
boots with `cpu_internal=0` (external-stimulus compatible) and
software flips it to `1` after the OS ROM is loaded and locked
(see `hdl/antic_regs.sv:139`). After that, SALLY drives the bus
and the input pins are dark.

## Two ANTIC display-fetch modes

The chiplet-extension register at $D481 selects:

- **bit 0 `MODE_SNOOP`** — `1` (default at /G_RST) = snoop;
  `0` = legacy DMA.

(Note: this is at $D481, not $D480. $D480 carries CLOCK_MULT — see
[register-map.md](register-map.md).)

### Snoop mode (default, fast)

ANTIC never asserts /HALT and never contends with SALLY for the
bus. Instead, the snoop pipeline observes **SALLY's bus** on every
phi2 cycle, samples `{A[15:0], D[7:0], R/W, /D0xx, /D4xx}` on the
rising edge of CLK, and dispatches:

- `/D0xx` low + R/W=0 → GTIA register write (low byte of A selects).
- `/D0xx` low + R/W=1 → ANTIC drives D[7:0] for the read response.
- `/D4xx` low + R/W=0 → ANTIC register write (incl. $D480-$D4FF ext).
- `/D4xx` low + R/W=1 → ANTIC drives D[7:0] for VCOUNT/NMIST/etc.
- Both /D0xx and /D4xx high, R/W=0, A NOT in $D000-$D7FF
  → cpu_shadow[A] := D (mirror main RAM into the display shadow).
- Same condition + active 130XE bank window per snooped PORTB
  → ALSO bank_shadow[A & 0x3FFF] := D.
- Otherwise: discard.

(The "snoop" label is historical — the same RTL pipeline used to
listen to an external 6502 in rp-antic. In fpga-antic it's just the
internal address-decode + RAM-mirror path for SALLY's writes; the
implementation didn't change, only the source of the bus signals
did.)

There are **no SALLY-driven /ANTIC_* tag CS lines**. rp-antic carries
five (`/ANTIC_DL`, `/ANTIC_CHAR`, `/ANTIC_PM`, `/ANTIC_SCREEN`,
`/ANTIC_TEXT`) so the rp-antic firmware doesn't have to do address
comparators on its IRQ-bound hot path. In FPGA fabric the comparators
are free — the FPGA already holds DLISTL/H, CHBASE, PMBASE, and the
parsed-DL LMS ranges, so per-cycle classification is one cycle of
combinational decode driven by ANTIC's own register state. SALLY
stays a plain 6502 bus master.

Display generation runs purely from the snoop shadow. ANTIC never
re-reads from system memory in snoop mode.

The single 64 KB `cpu_shadow` BlockRAM mirrors all of system RAM. The
compositor reads from it at the offsets indicated by the ANTIC
register state — DL bytes from `(dlisth:dlistl)`, charset bytes from
`chbase << 8`, P/M bytes from `pmbase << 8`, screen bytes from the
per-line LMS pointer captured by the DL parser. Because the FPGA
controls the read offsets, spurious snoop writes outside any active
ANTIC region are harmless — they land in cpu_shadow but are never
read.

### DMA mode (legacy compatible)

When `MODE_SNOOP=0`, ANTIC behaves like real silicon — it actively
contends with SALLY for the bus:

- Asserts `/HALT` low one cycle ahead of its DMA cycles.
- Drives A[15:0] for DL / charset / playfield / P-M fetches (the
  fetch reads `cpu_shadow` internally — A[15:0] still surfaces on
  the external bus pins at CLOCK_MULT=1 so cart/PBI/ECI devices see
  legit ANTIC DMA cycles).
- Samples D[7:0] from cpu_shadow at CLK rising edge.
- Releases /HALT after the fetch.

This mode costs ~30 % of CPU throughput due to the /HALT cycles and is
**opt-in** via $D481 bit 0 = 0. Useful for cycle-exact compatibility
with programs that race the beam and depend on /HALT-induced CPU
stalls; the 64 K shadow alone is functionally sufficient otherwise.

## External bus interfaces (CLOCK_MULT=1 only)

The FPGA fans the internal SALLY's bus out to physical pins so that
**cartridge slot**, **PBI** (XL/XE Parallel Bus Interface), and
**ECI** (XEGS Enhanced Cartridge Interface) peripherals can respond
as if a real Atari 6502 were driving the bus. There is no external
CPU socket; the external bus is a slave-side fan-out, not an
arbitration point.

### Active-only-at-CLOCK_MULT=1 rule

All external bus pins are **electrically active only when
`$D480 CLOCK_MULT = 1`**. At CLOCK_MULT ≥ 2 SALLY runs at fabric
rate from internal memories (`cpu_shadow` + OS ROM BRAM + cart-bank
HyperRAM via the bank_cache), and the external bus pins go quiet.

The gating is **internal at the FPGA pad-register, not (only) at
the LVC8T245 OE**. SALLY's bus signals are captured into output
registers only on CLOCK_MULT=1 cycles; at CLOCK_MULT ≥ 2 those
registers hold their last value with `D = Q`, so the FPGA pad
drivers don't transition. Without this discipline the FPGA pads
would toggle at clk_bus rate even with the LVC8T245s OE-disabled —
a real SSO + EMI + dynamic-power problem internal to the FPGA
package and the short FPGA-to-LVC8T245 board traces.

LVC8T245 OE-disable is **secondary safety**: it ensures the cart-
slot backplane stays quiet even if the internal gating has a bug.

**Input-direction LVC8T245s stay enabled at all CLOCK_MULTs.** They
don't toggle anything; they cost nothing in power. This lets the
FPGA sample `/MPD`, `RD4`, `RD5`, `/EXTIRQ` on demand at fast mode
without forcing a transient drop back to CLOCK_MULT=1 for cart-
hot-plug detection or PBI-IRQ response.

Reasons the gating rule applies:

- **Power / EMI.** A[15:0] + D[7:0] + R/W + control = 25+ FPGA
  output drivers. At clk_bus ~130-160 MHz that's a meaningful SSO
  + radiated-EMI source even before the LVC8T245s pass anything
  through. Internal gating eliminates it at source.
- **Cart/PBI/ECI device timing budgets** are sized for NMOS Atari
  (1.79 MHz, ~280 ns half-period). LVC8T245 prop delay is fine at
  any rate, but anything on the cart slot — and PBI devices'
  address comparators — see undefined behaviour at faster phi2.
- **No external master to serve.** Cart/PBI/ECI devices are pure
  slaves; with no external CPU, there's nothing on the external
  side that needs to see SALLY's fast-mode cycles.
- **Cart ROMs are already shadowed** in HyperRAM via
  `bank_translator` (see [roadmap.md M16b-3](roadmap.md)). Reading
  them through `cpu_shadow` at fast mode loses nothing relative to
  going to the physical cart pins.

### Signal sets

The external bus carries three overlapping device families.
Direction is from the FPGA's perspective.

**Core 6502 bus** (driven on every CLOCK_MULT=1 cycle):

| Signal | Dir | Purpose |
|--------|-----|---------|
| `A[15:0]` | out | Address (always outbound — no external master) |
| `D[7:0]` | bidir | Data (FPGA writes on R/W=0; reads slave responses on R/W=1) |
| `R/W` | out | Read/write |
| `/D0xx` | out | $D0xx page decode (GTIA region) |
| `/D4xx` | out | $D4xx page decode (ANTIC region) |
| `/NMI` | out (OD) | NMI to slaves that observe (rare; mostly informational) |
| `/IRQ` | out (OD) | IRQ aggregate |
| `/HALT` | out (OD) | ANTIC DMA-bus halt (during DMA mode) |
| `/RDY` | out (OD) | WSYNC release / DMA stall |
| `/RST` | bidir (OD) | System reset (drives slaves; also accepts external assert) |

**PBI** (Parallel Bus Interface — $D1xx page):

| Signal | Dir | Purpose |
|--------|-----|---------|
| `/EXTSEL` | out | $D1xx page select to the PBI device (= `/D1xx` on the ECI cart edge — single wire, board fans to both connectors) |
| `/EXTENB` | out | Master enable for PBI bank decode |
| `/MPD` | in | Math-Pack Disable — PBI device overrides $D800-$DFFF FP ROM |
| `/EXTIRQ` | in (OD) | PBI interrupt; wired-OR with `/IRQ` |

**Cart slot** (XL/XE cartridge edge):

| Signal | Dir | Purpose |
|--------|-----|---------|
| `/S4` | out | Cart-slot CS for $8000-$9FFF |
| `/S5` | out | Cart-slot CS for $A000-$BFFF |
| `/CCTL` | out | Cart control region select ($D5xx) |
| `RD4` | in | Cart-present indicator for $8000-$9FFF (idle-high; pull-low by cart) |
| `RD5` | in | Cart-present indicator for $A000-$BFFF (idle-high; pull-low by cart) |

**ECI** (Enhanced Cartridge Interface — XEGS combined cart+PBI edge):
No new wires; just routes existing signals to the cart-edge
connector. Specifically `/RST`, `/HALT`, and `/D1xx` (= `/EXTSEL`)
reach the ECI footprint via board traces.

### Latched-config inputs

`/MPD`, `RD4`, `RD5` are inputs whose values **affect FPGA-internal
decode** (cpu_shadow / bank_translator) even at fast mode. The rule
is: sample them at every CLOCK_MULT=1 cycle, latch the result, and
honour the latched value across fast-mode accesses until the next
CLOCK_MULT=1 cycle re-samples. RD4/RD5 are slow ("is a cart
plugged in") — a once-per-frame poll at CLOCK_MULT=1 is sufficient
even if the system spends most cycles at fast mode.

`/EXTIRQ` is an open-drain input that's wired-OR with `/IRQ`. At
CLOCK_MULT ≥ 2 the FPGA can either ignore it (no external master
to inject IRQs into) or **drop back to CLOCK_MULT=1 to service
it**. The latter is the natural answer if PBI devices need
real-time interrupt handling; cost is a brief mode-switch back to
1.79 MHz on PBI IRQ assert.

### Implementation: see milestone

Not yet built. See [future-work.md](future-work.md) §M-PBI for the
implementation plan + pin-budget delta.

## FPGA<->RP bus

The full signal-level spec lives in
[wire-protocol.md § FPGA<->RP bus](wire-protocol.md#fpga-rp-bus). The
short version:

- **Two source-synchronous buses**, one each direction.
- **FPGA→RP** (27 lines): 24 bits payload + 2 bits opcode tag + 1
  clock. Tag values: `FETCH=00`, `SET=01`, `DRAW=10`, `NOP=11`.
- **RP→FPGA** (17 lines): 16 bits payload + 1 clock. Returns the word
  at `mem[addr]:mem[addr+1]` for FETCH, returns sequenced data during
  DRAW responses (rare).
- All clocks are FPGA-driven for the FPGA→RP bus and RP-driven for
  the RP→FPGA bus. Receivers cross the clock with a 2-flop synchroniser.
- The RP→FPGA latency is bounded by the line-buffer prefetch budget,
  not the per-pixel scan-out budget. See § "Line-buffer prefetch".

### Line-buffer prefetch

A ping-pong BlockRAM line buffer pair sits between the FPGA's RP-side
RX path and the pix_clk-domain TMDS encoder. While buffer A drives
TMDS for the current framebuffer line, the FPGA spreads a burst of
FETCHes across the time-window during which buffer A is in use,
filling buffer B with the *next* framebuffer line.

In **ANTIC-compat mode** (the default — `OUTPUT_MODE` bit 1 = 0)
each framebuffer line drives multiple output scanlines, so the
prefetch window is 2–3 scanlines wide:

| Mode                                       | FB size  | Beats/FB-line | Output scanlines per FB-line | Window | Sustained beat rate |
|--------------------------------------------|----------|--------------:|-----------------------------:|-------:|--------------------:|
| 640×480 ANTIC-compat (line-doubled)        | 640×240  | 320           | 2                            | 63.6 µs | **5.0 MHz**         |
| 800×600 ANTIC-compat (line-tripled)        | 800×200  | 400           | 3                            | 79.2 µs | **5.0 MHz**         |

In **fullres extended mode** (`OUTPUT_MODE` bit 1 = 1) every output
scanline is a unique framebuffer line, so the window collapses to one
scanline:

| Mode                                       | FB size   | Beats/FB-line | Window | Sustained beat rate |
|--------------------------------------------|-----------|--------------:|-------:|--------------------:|
| 640×480 fullres                            | 640×480   | 320           | 31.8 µs | 10.1 MHz            |
| 800×600 fullres                            | 800×600   | 400           | 26.4 µs | 15.2 MHz            |

All four sustained rates are well inside the RP2354's PIO + memory
capability at 360 MHz sys_clk (PIO sustains ~180 MHz simple SM rate;
PSRAM/SRAM access is ~5 ns per word out of TCM). The default ANTIC-
compat path leaves an order of magnitude of headroom; even the
worst-case fullres rate has 10× margin to the RP's PIO speed limit.

Implementation note: the prefetch can overlap the entire window in
which the off-buffer is unused — i.e. across both (or all three) of
the output scanlines that share the FB-line currently being read out.
The FPGA does NOT need to squeeze the burst into H blanking only.

### Scroll handling

ANTIC's HSCROL ($D404) and VSCROL ($D405) registers are the design
constraint for the framebuffer layout. Naive "compose every visible
pixel into FB on every scroll change" generates an unacceptable amount
of SET traffic — a typical horizontal-scroll game changes HSCROL every
frame, which would force the entire HSCROL-affected band to be
rewritten 60 times per second.

The fpga-antic FB layout is designed so that scroll register changes
do **not** trigger compose work in the common case.

#### HSCROL — read-side parameter

HSCROL is applied at scan-out time as an address offset into the line
buffer, never baked into the FB. Per-row metadata in FPGA BlockRAM
(`line_hscrol[r]`) holds the current HSCROL for each atari row;
scan-out reads `line_buf[(native_x >> 1) + line_hscrol[r]]`. HSCROL
register writes update the metadata only — zero SET traffic.

#### LMS slides — also read-side, via a per-row "cache window"

Programs commonly scroll horizontally by sliding the LMS pointer in
the DL (e.g., overwriting the LMS-low byte each frame). Naively this
would also force a recompose since the rendered pixels shift.

Instead, each FB row caches **1024 atari-pixel indices** anchored at a
known source address `cache_lms_base[r]`. As long as the new visible
LMS range (`line_lms_addr[r]` derived from the current DL) remains
inside the window
`[cache_lms_base[r], cache_lms_base[r] + cache_window_in_source_bytes)`,
the scan-out simply reads from the FB at a different offset:

```
fb_read_offset[r] =
    (line_lms_addr[r] - cache_lms_base[r])
        × atari_px_per_source_byte_for_mode_of[r]
  + line_hscrol[r]
```

LMS slides within the cached window cost zero SETs. Slides past the
window (or to a different LMS region) trigger a recompose: dirty the
affected atari rows, snap `cache_lms_base[r]` to the new source
position, recompose, write back to FB.

Sizing rationale: 1024 atari pixels per row covers the typical
"128 source bytes per scanline" allocation in mode F (8 atari px/byte)
and "256 bytes per scanline" in 2bpp char-mode classes (4 cells/byte
× 2 atari px/cell = 8 atari px/byte). At 240 rows that's 240 KB of RP
storage — small relative to the 1 MB available. Wider source buffers
(rare) fall back to recompose on every cache-window cross.

#### VSCROL — compose-side, dirty-row tracked

VSCROL changes which source bytes feed each scan line within a DL
line, so it CAN'T be a pure read-side offset (different bytes get
rendered, not just shifted). But VSCROL also changes much less often
than HSCROL — typically once per scroll step (every few frames), not
once per frame.

A 192-bit `dirty[]` bitmap tracks rows that need recompose. Snoop-side
write detection sets the appropriate bits:

- Snoop write to screen RAM, charset, P/M shape RAM → the affected
  atari rows go dirty.
- VSCROL register write → all atari rows in VSCROL-enabled DL lines
  go dirty.
- DLISTL/H, CHBASE, PMBASE, DMACTL register writes → re-parse + dirty
  all rows.
- HSCROL register write → no dirty (read-side).
- LMS-slide that fits in cache → no dirty.
- LMS-slide past cache window → affected rows dirty.

The compositor walks the dirty list during VBI and emits SETs only
for rows whose `dirty[]` bit is set. For a static screen with no
animation, zero SETs per frame. For a smooth-scroller staying within
the cache window, also zero SETs per frame — the only cost is the
read-side address arithmetic at scan-out.

### DRAW commands (deferred to a later milestone)

Drawing primitives are an optimisation, not a correctness requirement.
Initial bring-up uses only FETCH and SET — the FPGA composites every
pixel and writes through to the framebuffer via SET. Once the basic
pipeline closes, LINE / FILL / RECT / ARC / CIRCLE land as DRAW
opcodes that offload the work from the FPGA's per-pixel composite.

## Inter-chip serial link

A UART-class serial channel connects each chip on the rp-XT slot to
rp-syscontroller and optionally chip-to-chip via syscontroller relay.
Used for:

- **Boot-time configuration**: firmware version, slot ID, clock
  multiplier, peripheral wiring map.
- **Low-rate runtime state push**:
  - rp-POKEY/PIA → fpga-antic: joystick triggers state ($D010-$D013
    reads), pot positions if any GTIA-side accessors care.
  - rp-syscontroller → fpga-antic: console-key state ($D01F CONSOL
    reads), PAL/NTSC sense.
- **Diagnostic / TRAP escalation** between chips.

The paired RP2354 is **not** on the inter-chip serial link. It
communicates with the FPGA only via the FETCH/SET/DRAW bus.

## Memory layout (target)

| Region | Where | Size | Notes |
|--------|-------|-----:|-------|
| `cpu_shadow[64K]` | T20 BlockRAM | 64 KB | Snoop-mode shadow of system memory. ANTIC reads only from here for display generation. |
| `bank_shadow[16K]` | T20 BlockRAM | 16 KB | XE-bank shadow when PORTB selects extra DRAM for screen memory. |
| Display-list view | T20 BlockRAM | ~1 KB | Parsed-DL working set: per-line mode, DLI flag, LMS pointer, sub-row, hscrol, cache_lms_base, etc. |
| Line buffer | T20 BlockRAM | 384 B × 2 | Ping-pong colour-index data for one atari row's worth of cached pixels (visible width + HSCROL margin). RP-side prefetch fills the off-screen buffer. |
| 256-entry palette | T20 BlockRAM | 1 KB | Extended palette indexed by composited byte. Written via $D480+ extension. |
| Framebuffer | RP2354 PSRAM/SRAM | ~240 KB | **1024 atari-pixel indices per row × 240 rows** in ANTIC-compat mode. The 1024-wide row caches the program's source buffer (typically 128-256 source bytes/scanline) plus HSCROL margin so LMS slides become read-side address arithmetic instead of FB rewrites. Fullres extended mode uses a different layout — see § "Scroll handling". |

## Clock / pixel-clock domains

- **bus_clk** — sourced from `CLK` pin, driven by rp-syscontroller's
  PLL. Snoop pipeline + register file run in this domain.
- **pix_clk** — internal PLL'd output. 25.175 MHz for 640×480, 40 MHz
  for 800×600. Compositor + line buffer read + TMDS encoder all run
  here. Selected at boot via the output-mode register; reconfigures
  on the next vsync after a write.
- **tmds_clk** — 5× pix_clk for the TMDS serializer (250 MHz at
  640×480; 200 MHz at 800×600). Internal SerDes only.
- **rp_tx_clk** — FPGA-driven clock for the FPGA→RP bus.
  Source-synchronous, free-running while the bus is active. Frequency
  capped by RP2354 PIO ingest rate (target 100 MHz).
- **rp_rx_clk** — RP-driven clock for the RP→FPGA bus. The FPGA
  receives this asynchronously to its other clocks; a 2-flop
  synchroniser feeds the line-buffer fill logic.

Cross-domain handoffs:

- bus_clk → pix_clk: line buffer is single-writer (compositor) /
  single-reader (TMDS DMA). Synchroniser flop pair on the snoop-
  shadow read path is sufficient because reads are at scanline rate.
- pix_clk → bus_clk: VCOUNT / NMIST / collision latches go through a
  small synchroniser FIFO so /D4xx reads return a coherent value.
- rp_tx_clk → bus_clk: command queue tail pointer is gray-coded across
  domains.
- rp_rx_clk → pix_clk: line buffer write address + write strobe go
  through a 2-flop synchroniser; safe because the writer + reader
  visit non-overlapping line buffers.

## Where to start

See [roadmap.md](roadmap.md). M0 is the iverilog harness booting and
running an empty top-level. M1 is producing valid 640×480 timing in
sim. RP firmware boots and runs the FETCH/SET PIO pair separately at
M2. The two halves merge at M5 when the line-buffer prefetch loop
closes the round-trip.
