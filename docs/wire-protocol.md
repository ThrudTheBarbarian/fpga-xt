# Wire protocol

`fpga-antic` is FPGA-native — it speaks the rp-XT real bus directly.
There is no dev-rig 5-byte loopback layer like rp-antic's, because we
don't have a Feather-class GPIO bottleneck.

This doc covers two buses:

1. **The rp-XT system bus** — the 6502 bus on the 168-pin slot, with
   /D0xx, /D4xx, /ANTIC_* tag CS lines, /NMI / /HALT / /RDY status
   outputs.
2. **The FPGA<->RP video-memory bus** — a private tagged bus between
   the FPGA and its paired RP2354 carrying FETCH / SET / DRAW
   opcodes. This is internal to fpga-antic; rp-XT has no visibility
   into it.

Self-test inside the FPGA is handled by the iverilog testbench (see
`sim/`), not by a runtime loopback frame format.

## Bus signals (rp-XT system bus, fpga-antic's view)

| Signal           | Dir | Width | Source              | Notes |
|------------------|-----|------:|---------------------|-------|
| `A[15:0]`        | in  | 16    | rp-SALLY            | Address bus. Sampled on CLK rising. |
| `D[7:0]`         | i/o | 8     | bus master of cycle | ANTIC drives only for /D0xx and /D4xx reads (R/W=1). |
| `CLK`            | in  | 1     | rp-syscontroller    | Bus phi0 (1.79 MHz × CLOCK_MULT). Rising edge = sample. |
| `R/W`            | in  | 1     | rp-SALLY            | Sampled with A. 1 = read, 0 = write. |
| `/G_RST`         | in  | 1     | rp-syscontroller    | Active-low global reset. Held until syscontroller has configured ANTIC over the serial link. |
| `/D0xx`          | in  | 1     | rp-syscontroller    | Active-low GTIA register page select. |
| `/D4xx`          | in  | 1     | rp-syscontroller    | Active-low ANTIC register page select. |
| `/NMI`           | out | 1     | fpga-antic          | Pulsed low at VBI / DLI. Idle high. |
| `/HALT`          | out | 1     | fpga-antic          | Asserted across DMA cycles in DMA mode. Always high in snoop mode. |
| `/RDY`           | out | 1     | fpga-antic          | Clock-stretch for WSYNC. Pulled low when CPU writes $D40A; released at next horizontal sync. |
| `SERIAL_RX`      | in  | 1     | rp-syscontroller    | UART-class inter-chip serial in. |
| `SERIAL_TX`      | out | 1     | rp-syscontroller    | UART-class inter-chip serial out. |
| `TMDS_DATA[2:0]` | out | 3 pr  | fpga-antic          | TMDS-encoded R/G/B differential pairs. |
| `TMDS_CLK`       | out | 1 pr  | fpga-antic          | TMDS clock (= pix_clk) differential pair. |

(I2S audio pins, console-key inputs, and power/ground are tracked in
[pin-map.md](pin-map.md), out of scope for the bus protocol. SRAM
pins are absent — the framebuffer lives in the paired RP2354, not on
external SRAM; see [architecture.md](architecture.md).)

### No /ANTIC_* tag CS lines

rp-antic's bus protocol carries five SALLY-driven `/ANTIC_*` tag CS
lines (`/ANTIC_DL`, `/ANTIC_CHAR`, `/ANTIC_PM`, `/ANTIC_SCREEN`,
`/ANTIC_TEXT`) that pre-classify each cycle for the rp-antic firmware.
**fpga-antic does not use them.** Those tags were an IRQ-budget
workaround for an RP2354 that couldn't afford the address comparators
on its hot path. In FPGA fabric the comparators are free — one cycle
of combinational logic produces the same classification from the
ANTIC register state the FPGA already holds (DLISTL/H, CHBASE, PMBASE,
parsed-DL LMS ranges, parsed-DL text-mode LMS ranges).

Dropping the tags saves five pins on every chip on the slot — including
SALLY, which no longer has to track ANTIC's region map. SALLY is a
plain 6502 bus master again; ANTIC's region knowledge stays where it
belongs, inside ANTIC.

## Snoop dispatch

The snoop pipeline lives entirely in the bus_clk domain. On every
rising CLK edge it samples `{A[15:0], D[7:0], R/W, /D0xx, /D4xx}`
and dispatches:

```
on (posedge CLK):
    if  /D0xx low and R/W=0:    -> gtia_regs.write(A[7:0], D)
    if  /D0xx low and R/W=1:    -> arm read response (D driven until CLK fall)
    if  /D4xx low and R/W=0:    -> antic_regs.write(A[7:0], D)  (incl. $D480-$D4FF ext)
    if  /D4xx low and R/W=1:    -> arm read response
    if  /D0xx high and /D4xx high
        and R/W=0
        and A NOT in $D000-$D7FF (hardware page filter):
                                -> cpu_shadow[A] <= D     (snoop main RAM)
                                -> if A in active bank window per PORTB shadow,
                                   ALSO bank_shadow[A & 0x3FFF] <= D
    otherwise:                  -> nothing
```

The **single** snoop shadow `cpu_shadow[64K]` mirrors all of system
RAM. The compositor reads from it at the offsets indicated by the
ANTIC register state:

| Region | Read offset within cpu_shadow |
|--------|-------------------------------|
| Display list | `(antic_regs.dlisth << 8) \| antic_regs.dlistl` |
| Charset | `antic_regs.chbase << 8` (1 KB) |
| P/M data | `antic_regs.pmbase << 8` (size depends on `dmactl[4]` 1-line vs 2-line) |
| Screen RAM | per-line LMS pointer captured by `dl_parser` |
| Text-mode char codes | per-line LMS pointer (mode 2/3/4/5) |

There are no separate `dl_shadow` / `charset_shadow` / `pm_shadow` /
`textram_shadow` BlockRAMs — the rp-antic split was a consequence of
the SALLY-driven /ANTIC_* tags pre-classifying writes to per-region
sinks. Without those tags we just shadow everything once and read it
at the right offset.

### Region classification is FPGA state, not bus state

The FPGA already holds every register that defines the active screen
regions (DLISTL/H, CHBASE, PMBASE) because it owns the ANTIC register
file, and it walks the DL once per VBI to capture every active LMS
range. So at any cycle, classifying "is this address part of an active
ANTIC region?" is a register-comparator problem, not a bus-protocol
problem. SALLY does not need to drive any tags.

For the snoop write path this is even simpler: we don't need to
classify writes at all. Anything that lands in cpu_shadow is fair
game; the compositor only reads from the offsets the registers say
matter, so spurious writes outside those regions are harmless.

### 130XE bank selection

When PORTB selects extended-bank RAM into the $4000-$7FFF window,
ANTIC must shadow into a separate 16 KB `bank_shadow` so the main
$4000-$7FFF cpu_shadow region keeps its own bank's contents. The FPGA
snoops PORTB writes from PIA (also via the bus) and gates the
write-to-bank-shadow on the current PORTB state. This mirrors the
130XE-style ANTIC-uses-extended-bank convention noted in the README.

### Read response timing

For `/D0xx` and `/D4xx` reads, the `D[7:0]` drivers must produce the
register's value before SALLY samples on CLK fall. The pipeline:

```
CLK rising edge n:
    -> snoop captures A, R/W, /D0xx, /D4xx
    -> address decoder fires combinationally
    -> selected register's value drives onto D
    -> D output enable asserted

CLK falling edge n:
    -> SALLY samples D
    -> D output enable de-asserted on next rising edge
       (only if the next cycle's tags don't keep it asserted)
```

This is "comb-out, latch-in" — the register file's read path is
combinational, the write path is registered. Output-enable is a
one-cycle pulse aligned to /D0xx-low or /D4xx-low + R/W=1.

## $D4xx address map (production)

```
$D400-$D40F   canonical ANTIC registers
$D410-$D41F   reserved for second-ANTIC (placeholder, do not reuse)
$D420-$D47F   mirror of $D400-$D40F (every 16 bytes), legacy compat
$D480-$D4FF   chiplet-extension window — mirror behaviour breaks here
```

Full chiplet-ext register layout: see [register-map.md](register-map.md).

## Chiplet-extension page convention (system-wide)

Every $Dxxx-owning chip uses the upper half of its page for chiplet
extensions, with mirror behaviour broken there:

| Page  | Owner                | Extension window |
|-------|----------------------|------------------|
| $D0xx | fpga-antic (GTIA)    | $D080-$D0FF |
| $D2xx | rp-POKEY/PIA (POKEY) | $D280-$D2FF |
| $D3xx | rp-POKEY/PIA (PIA)   | $D380-$D3FF |
| $D4xx | fpga-antic (ANTIC)   | $D480-$D4FF |
| $D7xx | rp-syscontroller     | $D700-$D7FF (incl. $D7FF boot-go) |

Pages $D1xx / $D5xx / $D6xx are unallocated.

## DMA-mode bus master sequence

When `MODE_SNOOP=0` and ANTIC needs a DL / charset / playfield / P-M
byte from system memory:

```
cycle k-1 (CPU is bus master):
    fpga-antic asserts /HALT low.
    SALLY samples /HALT, prepares to tristate next cycle.

cycle k (ANTIC is bus master):
    SALLY tristates A, D, R/W.
    fpga-antic drives A = target_addr, R/W = 1, D = tristated.
    rp-MMU sees ANTIC's address (and the /HALT-low + R/W=1 pattern)
        and drives D[7:0].
    On CLK falling edge, fpga-antic samples D.

cycle k+1 (CPU resumes):
    fpga-antic releases /HALT.
    SALLY's bus drivers re-engage on the next rising CLK.
```

The snoop pipeline keeps running in DMA mode — it sees ANTIC's own
fetch cycles too. The drain ignores those entries because R/W=1 and
none of /D0xx, /D4xx, /ANTIC_* are asserted (SALLY isn't driving the
tags during /HALT). The DMA-fetched byte communicates back to the
display generator via an internal register, not via the snoop ring.

## Mode-flip safety

Writing $D480 bit 0 transitions the chip between snoop and DMA modes:

- **1 → 0** (snoop → DMA): the snoop shadows go stale gracefully —
  ANTIC stops reading from them after the next vsync and starts
  bus-mastering instead.
- **0 → 1** (DMA → snoop): the snoop shadows are rebuilt from natural
  CPU traffic over the next frame. Visual artefacts during the
  rebuild window are expected; software is responsible for setting
  $D480 during VBI to avoid a visible glitch.

## Self-checking traps

Every published invariant is verified inside the FPGA and traced via a
counter, mirroring rp-antic's "compute-the-equality-check, fire-glaring-
fail-signal" pattern. Counters are exposed via the inter-chip serial
link's diagnostic channel. Examples:

- `bus_tag_overlap_count` — ticks if SALLY ever asserts more than one
  /ANTIC_* tag simultaneously on the same rising CLK.
- `wsync_overdue_count` — ticks if /RDY release latency exceeds 100 µs.
- `dma_fetch_unmatched_count` — ticks if a DMA-mode fetch returns
  before the request was registered (chip is reading garbage).

User has explicitly asked for traps over column-eyeballing (see
rp-antic's `feedback_self_checking_traps.md`). Honour the same
discipline here.

## Atomic cross-domain publication

When the bus_clk domain publishes multi-field state to the pix_clk
domain (or vice-versa), pack into a single multi-bit word and pulse a
"valid" handshake; the consumer latches the whole word atomically on
the rising edge it observes valid go high. Don't expose individual
fields with independent flops — the consumer can sample partial state.

This is the FPGA equivalent of rp-antic's "single uint32_t volatile
snapshot" rule.

## FPGA<->RP bus

The private tagged bus between fpga-antic and its paired RP2354. The
RP2354 is the framebuffer + drawing-accelerator subsystem; rp-XT has
no visibility here.

### Pin allocation

Two source-synchronous unidirectional buses: 27 wires FPGA→RP,
17 wires RP→FPGA. **All payload + tag wires within each bus must be
contiguous on the RP2354** so a single PIO state machine can OUT/IN
the full word in one instruction.

| Bus      | Width | Wires                              | Clock source |
|----------|-------|------------------------------------|--------------|
| FPGA→RP  | 27    | 24 payload + 2 tag + 1 clk         | FPGA         |
| RP→FPGA  | 17    | 16 payload + 1 clk                 | RP           |

Total 44 RP2354 pins (27 in + 17 out) — fits the 48-pin variant with
4 pins to spare for control / status (e.g. DRAW-queue-not-full,
emergency reset).

### FPGA→RP opcode format

Each rp_tx_clk rising edge presents one beat:

```
beat = { tag[1:0], payload[23:0] }     // 26 bits + 1 clk = 27 wires

tag values:
  00  FETCH    payload = 24-bit byte address. RP must reply with the
               16-bit word at mem[addr]:mem[addr+1] on its RX bus.
               Two-byte alignment: addr[0] MUST be 0 (PIO does not
               check, undefined behaviour if violated).
  01  SET      payload = 24-bit byte address. The NEXT beat carries
               the 16-bit data on payload[15:0]; payload[23:16] is
               ignored. Low byte of data → mem[addr], high byte →
               mem[addr+1]. The data beat's tag is also `01`.
  10  DRAW    payload = 8-bit op + 16-bit context. Some draw opcodes
               consume additional fixed-length beats with tag = `10`.
               See the DRAW opcode table below.
  11  NOP     bus is idle; payload ignored.
```

**SET sequencing**: SET's two beats must arrive on consecutive
rp_tx_clk cycles. If the FPGA cannot guarantee that (rare), it must
emit NOP between them — but the RP-side PIO is implemented assuming
no gap.

**FETCH ordering**: FPGA is allowed to pipeline multiple in-flight
FETCHes; the RP responds in order. Latency is 4 rp_tx_clk cycles
worst case (PIO ingest → ARM/PIO RAM-read → PIO emit → cross-domain
synchronise on the FPGA side). The line-buffer prefetch logic accounts
for this.

**DRAW back-pressure**: if the RP's DRAW queue is full, the RP
asserts `draw_full` (one of the spare control wires); FPGA must hold
DRAW beats off until it deasserts. Until DRAW lands, FPGA may continue
to issue FETCH and SET — they queue into a separate, never-full
buffer drained by core 0's PIO.

### RP→FPGA bus format

```
beat = payload[15:0]                   // 16 bits + 1 clk = 17 wires

response sequencing matches the order of FPGA→RP requests that
generate responses. Currently only FETCH generates a response; SET
and DRAW are write-only.
```

For FETCH at byte address `addr` (with addr[0] = 0):

```
mem[addr]      → payload[7:0]   (low byte / leftmost pixel index)
mem[addr+1]    → payload[15:8]  (high byte / next pixel index)
```

Two pixel indices per beat, leftmost in the low byte. This matches
the FPGA's natural in-order line-buffer fill (write to
`line_buf[2*i+0] := payload[7:0]; line_buf[2*i+1] := payload[15:8]`).

### Clocking

Both buses are **source-synchronous** with no shared clock domain:

- FPGA→RP: `rp_tx_clk` is FPGA-driven, free-running while the bus is
  active. RP-side PIO sets its sample edge against this clock.
- RP→FPGA: `rp_rx_clk` is RP-driven; the FPGA receives it
  asynchronously to its other clocks. A 2-flop synchroniser lands
  payload + write-strobe in the FPGA's pix_clk domain (where the line
  buffer lives) before commit.

The README flags glitch sensitivity: "the receiver will have to cope
with the clk being changed in an asynchronous-to-its-clock-domain
manner, which might require synchronizers." Both directions use
2-flop synchronisers on the data + clock-edge-detect; the RP-side
PIO's clkdiv keeps the bus far enough below the RP sys_clk that
metastability resolution has plenty of margin.

### DRAW opcode table

(Provisional — opcodes ship in the order their CPU-side HDL is ready,
gated by the corresponding milestone. All opcodes have fixed beat
counts; there is no variable-length-with-terminator.)

Each coordinate is a **16-bit signed value** carried in `payload[15:0]`
of its own beat — one coord per beat. Future-proof to ≥ 32 K × 32 K
resolutions (well beyond the 1024×768 stretch goal in the README).
`colour` is 8-bit indexed but transported as a 16-bit beat for
symmetry; the upper 8 bits are reserved (alpha / mode / palette-page,
TBD).

**op layout**: `op[6:0]` is the 7-bit primitive ID (128 slots);
`op[7]` is the **fill flag** for paired closed-shape primitives
(RECT, OVAL, ARC). 0 = outline, 1 = filled. For unpaired ops
(NOP, LINE, FILL, BEZIER, BEZIER_TO) `op[7]` is reserved (must be
0). FILL is a separate primitive (paint-bucket flood-fill); it is
NOT "RECT with op[7]=1".

| Op  | Name        | Beats | Beat-by-beat payload |
|-----|-------------|------:|----------------------|
| $00 | NOP_DRAW    | 1     | (op + ignored 16 bits) |
| $01 | LINE        | 5     | (op, x0\[15:0\]) (y0\[15:0\]) (x1\[15:0\]) (y1\[15:0\]) (colour\[15:0\]) |
| $02 | RECT        | 5     | (op, x\[15:0\]) (y\[15:0\]) (w\[15:0\]) (h\[15:0\]) (colour\[7:0\] + mode\[7:0\]) — outline |
| $82 | RECT-fill   | 5     | same args as $02 — filled rectangle |
| $03 | FILL        | 3     | (op, x\[15:0\]) (y\[15:0\]) (colour\[15:0\]) — flood-fill (paint-bucket): replaces every 4-connected pixel of the seed-colour at (x,y) with `colour`. |
| $04 | OVAL        | 5     | (op, cx\[15:0\]) (cy\[15:0\]) (rx\[15:0\]) (ry\[15:0\]) (colour\[15:0\]) — outline; M18 |
| $84 | OVAL-fill   | 5     | same args as $04 — filled oval; M18 |
| $05 | ARC         | 7     | (op, cx\[15:0\]) (cy\[15:0\]) (rx\[15:0\]) (ry\[15:0\]) (start_angle\[15:0\]) (end_angle\[15:0\]) (colour\[15:0\]) — outline; M18 |
| $85 | ARC-fill    | 7     | same args as $05 — filled arc / pie slice; M18 |
| $06 | BEZIER      | 9     | (op, x0\[15:0\]) (y0\[15:0\]) (x1\[15:0\]) (y1\[15:0\]) (x2\[15:0\]) (y2\[15:0\]) (x3\[15:0\]) (y3\[15:0\]) (colour\[15:0\]) — cubic, 4 control points; M18.1 |
| $07 | BEZIER_TO   | 7     | (op, x1\[15:0\]) (y1\[15:0\]) (x2\[15:0\]) (y2\[15:0\]) (x3\[15:0\]) (y3\[15:0\]) (colour\[15:0\]) — chains: implicit start = previous end-point; M18.1 |

Beat-0 packing: every DRAW opcode carries `op` in `payload[7:0]` and
its first 16-bit value in `payload[23:8]`. Subsequent beats carry
their 16-bit value in `payload[15:0]` with `payload[23:16]` reserved
(must be 0; receiver may trap on non-zero as a sync-loss indicator).

Oval / circle: the `circle` primitive doesn't have its own opcode —
it's a degenerate `OVAL` with `rx == ry`.

ARC / pie: `op[7]=1` on `$05` chord-fills the arc into a pie slice.

DRAW opcodes are deferred until after the basic FETCH/SET pipeline is
stable; see [roadmap.md](roadmap.md). Until then the FPGA composites
every pixel and writes through to the framebuffer via SET.

### Line-buffer prefetch budget

A ping-pong line buffer sits between the RP→FPGA path and the TMDS
encoder. While buffer A drives scan-out for the current framebuffer
line, the FPGA spreads a burst of FETCHes across the entire window
during which buffer A is in use, filling buffer B with the *next*
framebuffer line. The available window is the time the off-buffer
sits unused — which is the time during which the on-buffer's
framebuffer line is being read out.

In **ANTIC-compat mode** (default — `OUTPUT_MODE` bit 1 = 0) the
framebuffer is line-doubled (640×240) or line-tripled (800×200), so
each framebuffer line drives 2 or 3 consecutive output scanlines:

| Mode                                  | FB size | Beats/FB-line | Output scanlines per FB-line | Window | Sustained beat rate |
|---------------------------------------|---------|--------------:|-----------------------------:|-------:|--------------------:|
| 640×480 ANTIC-compat (line-doubled)   | 640×240 | 320           | 2                            | 63.6 µs | **5.0 MHz**         |
| 800×600 ANTIC-compat (line-tripled)   | 800×200 | 400           | 3                            | 79.2 µs | **5.0 MHz**         |

In **fullres extended mode** (`OUTPUT_MODE` bit 1 = 1) every output
scanline is a unique framebuffer line:

| Mode                                  | FB size  | Beats/FB-line | Window | Sustained beat rate |
|---------------------------------------|----------|--------------:|-------:|--------------------:|
| 640×480 fullres                       | 640×480  | 320           | 31.8 µs | 10.1 MHz            |
| 800×600 fullres                       | 800×600  | 400           | 26.4 µs | 15.2 MHz            |

All four sustained rates are well inside the RP2354's capability at
360 MHz sys_clk; the default ANTIC-compat path has an order of
magnitude of headroom. The FPGA does **not** need to squeeze the
burst into H blanking — it spreads FETCHes across the entire 2- or
3-scanline window the off-buffer is idle.

### Self-checking traps (FPGA<->RP)

- `rp_tag_invalid_count` — ticks on a beat with tag = `00`/`01`/`10`
  but payload outside the spec'd range (e.g. SET with addr[0] = 1).
- `rp_response_late_count` — ticks if FETCH response arrives after
  its line-buffer write window closed.
- `rp_draw_full_block_count` — ticks each cycle the FPGA wanted to
  issue a DRAW but couldn't because the RP's queue was full.
- `rp_response_unmatched_count` — ticks if RP→FPGA delivers more
  beats than FPGA issued FETCHes for.

All counters exposed via the inter-chip serial diagnostic channel.
