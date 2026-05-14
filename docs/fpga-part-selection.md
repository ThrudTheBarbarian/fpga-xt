# FPGA part selection

## Why we're picking again

Original target was Efinix Trion T20F256-C4 — small, cheap, 0.8 mm
ball pitch (hand-solderable). M-int synth shows two issues:

1. **BRAM is too small for full Atari shadow.** The CPU-visible address
   space is 64 KB; Atari 130XE bumps that to ~80 KB once you count the
   PORTB-banked $4000-$7FFF window. T20F256 has 204 EFX_RAM_5K blocks
   (~128 KB raw, but dual-port mode roughly halves the usable depth)
   so the largest dual-port `cpu_shadow` we can fit is 32 KB. We've
   been wrap-aliasing the full address space onto 15 bits as a
   synth-only kludge. Anything that runs real Atari software needs
   the full depth.

2. **Headroom for future features.** PRIOR + GTIA modes 9-11, the
   wider idx_buf encoding for PM5, palette LUT, TMDS encoder, line
   buffers — they all want more BRAM than T20 has spare.

## Candidates (Q10 pricing as of now)

| Part                   | Family   | Pitch   | BRAM     | LUTs   | $/Q10 | Notes                              |
|------------------------|----------|---------|----------|--------|-------|------------------------------------|
| Efinix T20F256-C4      | Trion    | 0.8 mm  | ~1.0 Mb  | 19 K   | (was) | Current — too small                |
| Efinix T35F256-C4      | Trion    | 0.8 mm  | ~2.0 Mb  | 33 K   | $26   | Same flow, more headroom           |
| Efinix T35F400         | Trion    | 0.8 mm  | ~2.0 Mb  | 33 K   | $26   | Bigger BGA package                 |
| Lattice LFE5U-25F-7    | ECP5     | 0.8 mm  | ~1.0 Mb  | 24 K   | $27   | Different toolchain (Diamond/nextpnr) |
| Efinix Tz50F256-C2     | Topaz    | 0.8 mm  | ~3.7 Mb  | 50 K   | $26   | C2 (consumer, slow grade) — initial pick |
| Efinix Tz50F256-I3     | Topaz    | 0.8 mm  | ~3.7 Mb  | 50 K   | $35   | I3 (industrial, fast grade); ram_clk closes 200 MHz post-M16b-int but slack vanished after M17-2 added ~360 LUT |
| **Efinix Ti60F256-C4** | Titanium | 0.8 mm  | ~3.7 Mb  | 60 K   | $38   | **Picked** — pin-compatible with Tz50F256; ram_clk @ 244.8 MHz (+915 ps slack); +10 K LUTs of headroom for M23/M24 chip-absorption |

## Decision: Ti60F256-C4

Part history:

1. **Tz50F256-C2** ($26 Topaz, consumer/slow grade) — initial pick.
   M16b-int synth showed C2 misses the HyperRAM IP's 200 MHz target
   by 105 ps and stays at 195.9 MHz no matter what PnR effort
   ([synth-results.md](synth-results.md) has the full sweep).
2. **Tz50F256-I3** ($35 Topaz, industrial -3) — closed ram_clk at
   219.3 MHz post-M16b-int (slack +0.441 ns). Looked comfortable.
   Then M17-2 added ~360 LUT of DRAW logic, PnR placement shifted,
   and ram_clk slack collapsed to +0.061 ns. With M17-3 / M18 /
   M23 / M24 still to add, that's not enough margin.
3. **Ti60F256-C4** ($38 Titanium, consumer/fast grade) — Picked.
   Same F256 BGA package (pin-compatible with Tz50F256, so PCB
   layouts carry over). On the M17-2 design ram_clk closes at
   244.8 MHz (slack **+0.915 ns**) — 15× the Tz50-I3 margin and
   well above the 200 MHz HyperRAM target. Ti60 also bumps LUT
   capacity from 50 K → 60 K, headroom for M23 (POKEY) + M24
   (SALLY) integration.

Cost case: Ti60F256-C4 is +$3 vs Tz50F256-I3, +$12 vs the original
Tz50F256-C2 plan. Offset by the chip-absorption work in
[Phase 9](roadmap.md#phase-9--chip-absorption-bom-reduction):

- Drop discrete POKEY (~$5) — folded into fabric at [M23](roadmap.md#m23)
- Drop discrete 6502 (~$5-10) — folded into fabric at [M24](roadmap.md#m24) via the Arlet Ottens core
- Drop level-translator glue around POKEY/6502 — small, but real

Net BOM impact remains a **wash or small saving**, with the bonus
of collapsing inter-chip latency (POKEY → HDMI audio) and freeing
two substantial pins/board areas.

Cheapest-and-largest in the 0.8 mm-pitch group AND has the on-die
HyperRAM controller IP:

- **50 K LUTs** (vs T20's 19 K) — runway for the still-to-come scan-
  out pipeline + palette + TMDS without squeezing.
- **235 × 10 Kbit BRAM blocks (~2.3 Mb total)** — full 64 KB Atari
  shadow uses 64 blocks (27%), leaving 171 for the 16 KB 130XE bank,
  line-buffer, palette LUT, and scan-out FIFO.
- **0.8 mm BGA-256** — same pitch as the T20F256 we've been
  targeting, hand-assembly stays in reach.
- **HyperRAM IP** — Efinix supplies a HyperRAM Controller soft-IP core
  that supports Topaz and Titanium FPGAs (per
  https://www.efinixinc.com/support/ip/hyperram-controller.php).
  Hosts the **system memory** (cpu_shadow + 130XE bank + cartridge
  windows + extended ROM) directly on the FPGA — see the
  architectural pivot below. The framebuffer stays on RP2354 so
  RP2354 keeps its software-GPU role (DRAW opcodes, RECT/FILL/LINE/
  CIRCLE acceleration).
  (The IP is downloaded separately from the Efinix support portal —
  it isn't bundled in the Efinity IDE install, so the IDE's docs
  index doesn't flag Topaz HyperRAM. The product page is the
  authoritative source.)

### Validated synth numbers (Efinity 2025.2, full M-int design)

| Part        | Family | fMax     | BRAM   | cpu_shadow | Notes                                |
|-------------|--------|----------|--------|------------|--------------------------------------|
| T20F256-C4  | Trion  | 83.3 MHz | 128/204 | 32 KB     | Wraps full 64 KB onto bottom 32 KB   |
| T35F256-C4  | Trion  | 80.9 MHz | 128/?   | 32 KB     | Same wrap; mostly more LUT headroom  |
| **Tz50F256-C2** | **Topaz** | **173.3 MHz** | **64/235** | **64 KB** | **No wrap. 2× faster, 27% BRAM used** |

Topaz Tz50 doubles the achievable clock and gives full address-space
fidelity — clearly worth the part swap.

## The 1.8 V trade-off

Topaz / Titanium parts are largely 1.8 V banks (only a few HSIO-capable
banks accept 3.3 V). The rest of the rp-XT subsystem needs to be 1.8 V
on the ANTIC-facing pins:

- **RP2354**: per RP2354 datasheet, GPIO supports 1.8 - 3.3 V — running
  the side that talks to the FPGA at 1.8 V is supported.
- **Cartridge / system bus pins**: need level translators if the rest
  of the rp-XT runs at 3.3 V. A handful of TXS0108 / NXB0108 chips
  cover the slow bus interface.
- **DVI/HDMI TMDS**: TMDS is current-mode; output pads typically need
  3.3 V or a discrete TMDS buffer. A few HSIO bank pins on Topaz
  support DVI/MIPI directly.

## Architectural pivot: on-board HyperRAM for SYSTEM memory only

With Topaz, we can put a HyperRAM chip (8 - 16 MB, ~$3 - 5) on the
FPGA's HyperRAM pins. Chosen model is S70KS1283GABHB023, the split is:

- **HyperRAM (FPGA-attached) = system memory.** Hosts the
  64 KB Atari address space, the 16 KB 130XE PORTB-banked window,
  cartridge ROM/RAM banks, and extended-RAM banking modes. The
  current 64 KB BRAM `cpu_shadow` moves out into HyperRAM, freeing
  64 EFX_RAM10 blocks back to ~0% used and lifting the 80 KB ceiling
  the original architecture imposed.
- **RP2354 = graphics memory + software GPU (unchanged).** The
  framebuffer (idx_buf rows, scaled output buffers) stays on RP2354
  exactly as the current FETCH/SET/DRAW protocol assumes. RP2354
  keeps its DRAW-opcode role for the M17/M18 software-GPU
  primitives (RECT / FILL / LINE / CIRCLE / ARC). No change to the
  rp_tx/rp_rx wire format.
- **What's new:** dl_parser, compositor, and (eventually) DMA-mode
  bus-master path read system bytes from HyperRAM instead of from
  the BRAM `cpu_shadow`. bus_snoop writes them. Effectively cpu_shadow
  becomes a HyperRAM-backed cache rather than a BRAM mirror.

The pivot proper slots in around M16 (DMA-mode bus master) where
extended-RAM access matters. M14 / M14b (palette + TMDS) and M12 / M13
(NMI / WSYNC) come first because they're independent of where system
memory lives.

## Build flow

`efinity/run.sh` reads `FAMILY` / `DEVICE` / `TIMING` from the
environment; the Ti60F256-C4 default is now baked in:

```
# Default target (Ti60F256-C4 — closes ram_clk @ 244.8 MHz)
./efinity/run.sh pnr

# Equivalent explicit form
FAMILY=Titanium DEVICE=Ti60F256 TIMING=C4 ./efinity/run.sh pnr

# Tz50-I3 fallback ($35, narrow but closes 200 MHz)
FAMILY=Topaz    DEVICE=Tz50F256 TIMING=I3 ./efinity/run.sh pnr

# Tz50-C2 baseline ($26 — historical; ram_clk @ 195.9 MHz misses 200)
FAMILY=Topaz    DEVICE=Tz50F256 TIMING=C2 ./efinity/run.sh pnr
```

Now that the HyperRAM is integrated and timing closes with comfortable
margin, the historic note about wrap-aliasing the cpu_shadow into a
smaller BRAM no longer applies — system RAM lives in HyperRAM
(128 Mb), so there's nothing to wrap.
