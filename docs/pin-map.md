# Pin map — fpga-antic on Ti60F256-C4

Signal-group allocation for the Titanium Ti60F256-C4 (BGA-256, 0.8 mm
pitch). Per the Ti60 datasheet, the F256 package gives:

- **27 HVIO** single-ended (1.8 / 2.5 / 3.0 / 3.3 V LVCMOS, 3.0 / 3.3 V LVTTL)
- **142 HSIO** single-ended (1.2 / 1.35 / 1.5 / 1.8 V LVCMOS, HSTL, SSTL)
  — also configurable as **71 differential pairs** (LVDS / diff HSTL /
  SSTL / MIPI TX/RX)
- **16** global clock / control nets routable from GPIO
- **4** PLLs

Total user I/O = 169 pins. Exact pin numbers are finalised when the
PCB layout lands; this doc fixes the **groupings** + the
floorplan-driving constraints (which clusters need to sit near which
package edges to keep HyperRAM / HDMI traces short).

Final part choice + cost rationale: see
[fpga-part-selection.md](fpga-part-selection.md). Synth flow:
[../efinity/run.sh](../efinity/run.sh).

## I/O budget

The Ti60F256 has two I/O bank classes:

- **HVIO** — 27 pins on the **left edge** (per the F256 die diagram).
  Configurable to 1.8 / 2.5 / 3.0 / 3.3 V LVCMOS or 3.0 / 3.3 V LVTTL.
  Max LVCMOS33 SDR rate is 200 MHz, comfortably above our 162 MHz
  `clk_bus`. **Hosts the inbound 3.3 V traffic** that would otherwise
  pay LVC8T245 toll on HSIO: rp_rx (17 ch RP → FPGA) + the peri-RP
  SPI link (5 ch). Both endpoints run at 3.3 V CMOS, so HVIO connects
  to them directly with no level translator.
- **HSIO** — 142 pins distributed across bottom, top, and right edges
  (PLL blocks live in the corners). Configurable to 1.2 / 1.35 / 1.5
  / 1.8 V LVCMOS / HSTL / SSTL, **with 71 differential pairs**
  available for LVDS / diff HSTL / SSTL / MIPI TX/RX. Carries the
  high-speed peripherals (HyperRAM PHY at 200 MHz DDR, HDMI TMDS at
  250-400 Mbps differential, RP2354 source-synchronous link rp_tx)
  plus the **6502 bus** (with 4× LVC8T245 1.8 V ↔ 5 V; see
  [hardware-notes.md](hardware-notes.md)).

Until the M25-2c-rev pivot the 6502 bus sat on HVIO. Moving it to
HSIO doesn't change LVC8T245 quantity or cost (the chip's VCCA range
covers both 1.8 V and 3.3 V) and frees HVIO to absorb the 3.3 V
inbound traffic that previously needed a translator hop. Net BOM
saving: 5 × LVC8T245 (~$3.50). See `docs/hardware-notes.md` "HVIO
repurpose".

### HVIO bank (left edge — 27 pins, 3.3 V)

| Group              | Pin count | Notes                                                          |
|--------------------|----------:|----------------------------------------------------------------|
| **rp_rx**          | 17        | RP → FPGA, clk + 16 data — direct 3.3 V CMOS, no LVC8T245      |
| **Peri RP SPI**    | 5         | CLK + MOSI + MISO + /CS + IRQ — direct 3.3 V CMOS, no LVC8T245 |
| Spare              | ~5        | room for cart-slot CS, GPIO LEDs, future expansion             |
| **HVIO total**     | **22 + 5 spare** | 81 % used (vs the prior 100 % when 6502 lived here)     |

### HSIO banks (top / bottom / right edges — 142 pins, 1.8 V)

| Group                | Pin count | Notes                                                          |
|----------------------|----------:|----------------------------------------------------------------|
| **6502 bus**         | 27        | A[15:0] + D[7:0] + RW + /D0xx + /D4xx — 4 × LVC8T245 (VCCA = 1.8 V, VCCB = 5 V) |
| ANTIC status         | 3         | /NMI, /HALT, /RDY (1.8 V CMOS → discrete OD level shifter)     |
| HyperRAM PHY         | 13        | DQ[7:0] + RWDS + CK_p + CS_n + RST_n; ram_clk via PLL. CK_n dropped — single-ended clock committed (ram_clk capped at 250 MHz, well below where modern HyperRAM ICs demand diff clock). |
| HDMI TMDS            | 8 (4 pairs)| TMDS_DATA[2:0] diff pairs + TMDS_CLK pair — 4 of 71 available HSIO diff pairs. **Plus ~4-8 reserved SE neighbour pins** lost to LVDS-adjacency constraints (see "LVDS-adjacency tax" note below). **AC-coupled to TMDS181** via 8 × 100 nF series caps (the FPGA's LVDS output common-mode of 0.9 V ± 0.175 V is well below the TMDS181's input common-mode range of VCC−0.4 to VCC+0.1 = 2.9–3.4 V at VCC = 3.3 V; AC coupling blocks the DC mismatch and lets the TMDS181's internal input bias re-reference the signal to its native common-mode). See [hardware-notes.md § TMDS181 AC-coupling](hardware-notes.md). |
| HDMI auxiliary       | 5         | /HPD_OUT (TMDS1204 → FPGA, level-shifted to VIO inside the chip), TMDS1204 control I²C (SCL + SDA), TMDS1204 low-voltage DDC pins (LV_DDC_SCL + LV_DDC_SDA — high-voltage side to the HDMI receptacle goes through 1 × PCA9306). All low-frequency (≤ 400 kHz). Co-locates with HDMI TMDS in banks 2A/2B — no SSO impact since they're low-rate. **TMDS1204 VIO = 1.8 V** (configurable, accepts 1.2 / 1.8 / 3.3 V LVCMOS per §5.3) so the FPGA-facing 5 wires drive **direct from HSIO — no FPGA-side level translators needed.** HPD level-shifting between the 5 V HDMI connector and VIO is built into the TMDS1204 (HPD_IN pin tolerant to 5.5 V). |
| **rp_tx**            | 27        | FPGA → RP, clk + 26 data — 4 × LVC8T245 (VCCA = 1.8 V, VCCB = 3.3 V) |
| **Joy PCAL9722 SPI** | 5         | CLK + MOSI + MISO + /CS + INT_N — PCAL9722's split-supply VDDI = 1.8 V means **no LVC8T245** between |
| **FPGA config (QSPI from peri-RP)** | 8 | CDI[0..3] + CCK + SSL_N + CRESET_N + CDONE — dedicated (no pin sharing with rp_rx). 7 RP→FPGA + 1 FPGA→RP, with 2 × LVC8T245 for HSIO 1.8 V ↔ peri-RP 3.3 V translation. See [fpga-configuration.md](fpga-configuration.md). |
| Clock / reset        | 2         | sysclk in (24 MHz crystal or RP-driven) + /G_RST. `ram_clk` and `ram_clk_cal` are PLL outputs (internal), not pins. |
| Spares (debug LED, cart slot, status) | ~46 | room for cart-slot interface (M22) + debug + future expansion |
| **HSIO total**       | **~98**   | ~69 % of the 142 HSIO budget (effective budget is **~134-138** after LVDS-adjacency reservation — see below) |

### Summary

| Bank      | Used    | Available | %    |
|-----------|--------:|----------:|-----:|
| HVIO      | 22      | 27        | 81 %  — 5 pins spare on the 3.3 V bank for cart-slot CS / debug |
| HSIO      | ~98     | 142 (effective ~134-138) | ~71-73 % once LVDS-adjacency is subtracted from the denominator |
| **Total** | **~120**| **169 (effective ~161-165)** | **~73 %** effective |

### LVDS-adjacency tax

Efinix Titanium's HSIO bank rules **reserve SE pins adjacent to
active LVDS pairs** for IOVDD reference quiet-neighbor and routing-
headroom reasons. The exact reservation per pair depends on the
bank, the LVDS data rate, and the Interface Designer's placement
verdict — but a working estimate:

- **Each LVDS pair at TMDS rate** (up to ~1.5 Gbps DATA, ~150 MHz
  CLK at 1080p60) reserves the pair's 2 pins **plus ~1-2 adjacent
  SE pins per side**.
- **Outer-row placement (rows A/B, our choice)** keeps one side of
  each pair against the package edge, so only the inner-side
  neighbour is at risk — halves the tax.

For our 4 TMDS pairs:
- 8 pair-pins (already counted in the HSIO total above)
- **~4-8 SE neighbour-pins** lost to reservation — not currently
  reflected in the per-row tally, but does shrink the spare-pin
  budget.

Net: **effective HSIO budget ≈ 134-138 of the nominal 142**.
Still well above our 115 used (margin of 19-23 spare HSIO pins,
not the apparent ~46 in the spare row), but should be locked down
in the Interface Designer's pin-locking pass before PCB.

**Engineering check before PCB**: run the Efinix Interface Designer
with the 4 LVDS pairs locked to their chosen outer-row positions,
attempt to assign every other HSIO signal in the design, and
record which SE pins the tool rejects as "reserved by LVDS
adjacency". That gives the exact reservation count for our
specific pin choices; the budget estimate above gets replaced
with the measured value at that point.

### HSIO bank assignment summary

Locked placements for the high-speed signal groups:

| Bank(s) | Group | Pin count | Notes |
|---------|-------|----------:|-------|
| 2A / 2B | HDMI TMDS + HDMI auxiliary | 8 + 5 = 13 | Outer-row LVDS pairs on rows A/B (commit 805306b). Aux signals (/HPD + 2× I²C) co-locate here since they're low-frequency (≤ 400 kHz) and don't add to the bank's high-speed SSO budget. LVDS-adjacency tax applies to any other SE pin in these banks. |
| 3A | rp_tx (part) | 15 | clk_bus ~130 MHz source-synchronous. Contains the rp_tx clk pin. |
| 3B | rp_tx (part) | 12 | clk_bus ~130 MHz source-synchronous. Out-of-bank-with-clk data pins. |
| 4A / 4B | HyperRAM PHY | ~13 | ram_clk DDR ~250 MHz. Separate VCCIO from rp_tx. |
| Other HSIO banks | 6502 bus, joy SPI, FPGA config, ANTIC status, clock/reset | ~45 | Low-rate (≤ 25 MHz or async) **once M-PBI internal-gating lands** — the 6502-bus output flops must hold D=Q at CLOCK_MULT ≥ 2 (see below). Until then the 6502 bus is technically clk_bus-rate at fast mode and should not co-locate with any other high-speed group. |

Each high-speed group is sized comfortably under the ~20-30
SSO/bank estimate, and they're on physically separate VCCIO +
ground-return networks so their SSO budgets don't stack.

### Per-bank SSO (Simultaneous Switching Output) limits

Titanium HSIO on the Ti60F256 is partitioned into multiple physical
banks (3A, 3B, and others), each with its own VCCIO and ground-
return network. Per the Efinix Titanium IO User Guide, each bank
has an **SSO limit** that bounds how many outputs can switch
simultaneously without violating ground-bounce / VCCIO-droop
margins. Working estimate for 1.8 V LVCMOS at 8 mA / fast slew:
**~20-30 SSO per bank** for clean signalling.

This isn't a pin-count tax in the LVDS-adjacency sense — it's a
**bank-assignment** constraint. The total pin count stays the
same, but the freedom to drop any signal in any bank shrinks.

At-risk concentrations in fpga-antic:

| Group              | Outputs | Toggle rate     | Bank placement |
|--------------------|--------:|-----------------|----------------|
| **rp_tx**          | 27      | clk_bus ~130 MHz | **Split: 15 in bank 3A + 12 in bank 3B.** Comfortably under typical SSO limits per bank (15 and 12 are both well below the ~20-30 estimate). Source-synchronous skew control handled in `efinity/constraints/antic_top.sdc`. |
| **HyperRAM PHY**   | ~13     | ram_clk DDR ~250 MHz | **In banks 4A / 4B** — physically separate from rp_tx's 3A/3B placement, so the two high-speed concentrations don't stack on a single bank's VCCIO. |
| **HDMI TMDS**      | 8 (4 LVDS pairs) | up to ~1.5 Gbps | **In banks 2A / 2B** — outer-row placement on rows A/B (commit 805306b). LVDS pairs reduce SSO impact via differential common-mode cancellation, but 2A/2B still have reduced LVCMOS-output headroom for everything else, so any LVCMOS sharing those banks should be low-rate (≤ 25 MHz) or low drive-strength. |
| **6502 bus**       | 25      | 1.79 MHz at CLOCK_MULT=1; **static** at CLOCK_MULT ≥ 2 | Not a risk **provided** the M-PBI internal-gating rule is implemented (D=Q hold on output flops when `clock_mult != 1`). Without that gating, the FPGA bus pads would transition at up to clk_bus ~130-160 MHz at fast mode — 25 SSO concentrated in whichever bank hosts them, well over typical limits. See [future-work.md § M-PBI](future-work.md) step 2. |
| **Joy SPI / FPGA config** | 5 + 8 | ~5-25 MHz | Not a risk. |

**rp_tx bank-split implications:**

- The rp_tx **clk pin** lives in one of the two banks; the data pins
  in the *other* bank have a longer flop-to-pad route, adding a
  small skew between the in-bank-with-clk data pins and the
  out-of-bank data pins. The RP-side capture window is wide enough
  to absorb this; just needs the SDC `set_output_delay` constraints
  to use a unified spec for both bank groups (not split per-bank).
- HyperRAM PHY placed in banks 4A/4B, physically separate from
  rp_tx's 3A/3B. The two high-speed groups don't share VCCIO, so
  their SSO budgets are independent.

**Engineering check before PCB (combined with the LVDS-adjacency
check above)**: in the Interface Designer pin-locking pass, verify
each bank's SSO count against the IO User Guide table for LVCMOS18
+ the chosen slew rate. Remaining resolutions if violations show
up elsewhere:
- Drop slew rate where the receiver can tolerate it (cart-slot
  control lines, peri_link SPI — anything ≤ 25 MHz).
- Split additional high-speed groups across banks if the tool
  flags HyperRAM or TMDS-hosting bank concentrations.
- Reduce drive strength (4 mA likely sufficient for most groups
  on the short, well-terminated rp-XT board traces).

**Atari peripherals split across two off-FPGA chips**: a dedicated
peripheral RP2354B (QFN-80, 48 GPIOs) and a PCAL9722 GPIO expander
(TSSOP-32, 22 GPIOs).

- **Peri-RP2354B** handles **POT / SIO / SD** — the timing-critical
  parts (1.79 MHz POT scan, high-rate accessory SIO, native SD SPI).
  Talks to the FPGA over a 5-pin link (4-pin SPI with /CS + 1-pin
  IRQ). The /CS-delimited frame format lets the peri-RP use its
  on-chip PL022 hardware SPI in slave mode — no PIO needed.
- **PCAL9722** handles **joystick + fire** (4 × 5 = 20 GPIOs of
  bidirectional per-bit traffic for PORTA/PORTB and fire). Its
  split-supply design (VDDI = 1.8 V, VDDP = 5 V) eliminates **both**
  level-translator hops: SPI bus to FPGA HSIO is direct 1.8 V → 1.8 V,
  and joystick pins to Atari are direct 5 V → 5 V.

The main RP2354B (QFN-80, 48 GPIOs — uses 44 for rp_tx+rp_rx, 4
spare since FPGA boot moved to peri-RP per
[fpga-configuration.md](fpga-configuration.md); USB DP/DM are
dedicated pins outside the 48 budget) handles:

- Line-buffered video RAM (the framebuffer)
- USB host (keyboard / mouse via TinyUSB)

The peri-RP/PCAL9722 split keeps every 5 V signal off the FPGA
entirely, reduces the FPGA peripheral pin count from ~40 (FPGA-direct
plan) to 10 (5 peri-RP + 5 PCAL9722), and moves the SIO state machine
+ SD card protocol stack from fabric work into C firmware on a chip
with hardware SPI + plenty of GPIOs.

**Architecture history**: see [hardware-notes.md](hardware-notes.md)
"Architecture history" for the full five-iteration walk from the
FPGA-direct plan through to the current peri-RP + PCAL9722 + HVIO
hybrid.

## Group floorplan strategy

Aim: keep high-speed clusters' traces short, segregate clusters by
voltage domain, and use the 27 HVIO pins on the left edge for the
3.3 V inbound traffic (rp_rx + peri-RP SPI) that would otherwise pay
LVC8T245 toll on HSIO. The Ti60F256 die layout (per the F256 diagram)
has HVIO on the **left**, HSIO along the **bottom**, PLL block
bottom-right, with embedded memory + DSP columns through the fabric.

```
                +-----------------------------+
                |        Top edge (HSIO)      |
                |  HDMI cluster (TMDS, 4 prs) |
                |  near the HDMI connector    |
                +--+-----------------------+--+
   HVIO (27)    |                          |    HSIO right edge,
   left edge,   |                          |    1.8 V:
   3.3 V:       |                          |    - rp_tx (27)
   - rp_rx (17) |   Ti60F256C4             |      → main RP
   - peri-RP    |                          |    - 6502 bus (27)
     SPI (5)    |                          |      → Atari connector
   - 5 spare    |                          |    - Joy PCAL9722
                |                          |      SPI (5)
                +--+-----------------------+--+
                |        Bottom edge (HSIO) | PLL |
                |  HyperRAM cluster         |     |
                |  (DQ, RWDS, CK, CS, RST)  |     |
                |  short trace to HyperRAM  |     |
                |  IC under PCB             |     |
                +-----------------------------+
```

**HVIO ↔ HSIO assignments**:

- HVIO left edge → rp_rx (17) + peri-RP SPI link (5) — both 3.3 V
  CMOS direct, no level shifter
- HSIO bottom → HyperRAM (high-speed DDR, sits next to PLL block)
- HSIO top → HDMI TMDS pairs (closest to board's HDMI connector)
- HSIO right → 6502 bus (4× LVC8T245 to 5 V Atari) + rp_tx (4×
  LVC8T245 to 3.3 V main RP) + Joy PCAL9722 SPI (direct 1.8 V via
  PCAL9722's VDDI)
- HSIO scattered → ANTIC status (/NMI, /HALT, /RDY) + config + clock + spares

## HyperRAM PHY pins

The Efinix HyperRAM Controller IP exposes the PHY as **pre-DDR-mux
signal pairs** (LO/HI per edge). The synth wrapper above `antic_top`
instantiates Efinix `EFX_GPIO` primitives in DDR mode that combine
each LO/HI pair into a single physical pin:

| Internal antic_top signal | DDR primitive | External pin     | Notes |
|---------------------------|---------------|------------------|-------|
| `hbc_dq_OUT_LO[7:0]` + `hbc_dq_OUT_HI[7:0]` (with `hbc_dq_OE`) | EFX_GPIO ×8 (bidir DDR) | DQ[7:0] | x8 HyperRAM data, DDR |
| `hbc_dq_IN_LO[7:0]` + `hbc_dq_IN_HI[7:0]` | (same primitives, input side) | DQ[7:0] | DDR sample on both edges |
| `hbc_rwds_OUT_LO/HI` (with `hbc_rwds_OE`) | EFX_GPIO (bidir DDR) | RWDS | data strobe / mask, DDR |
| `hbc_rwds_IN_LO/HI` | (input) | RWDS | |
| `hbc_ck_p_LO/HI` | EFX_GPIO ×1 (DDR out) | CK | single-ended commit (2026-05-11). IP still emits `hbc_ck_n_LO/HI` internally but they're tied off at the antic_top instantiation; the EFX_GPIO for CK_n isn't instantiated in the synth wrapper. |
| `hbc_cs_n` | EFX_GPIO out | CS_n | |
| `hbc_rst_n` | EFX_GPIO out | RST_n | |
| `ram_clk` | (PLL input) | — | from on-chip PLL |
| `ram_clk_cal` | (PLL input) | — | from on-chip PLL |

The `EFX_GPIO` instantiations live in the synth wrapper, NOT in
`antic_top` — keeping `antic_top` toolchain-agnostic so simulation
testbenches don't need to mock the DDR primitives.

## HDMI TMDS pins

| Internal signal | External pin | Notes |
|-----------------|--------------|-------|
| TMDS_DATA[2] | TMDS_DATA2_p / _n | Differential pair, 100 Ω matched |
| TMDS_DATA[1] | TMDS_DATA1_p / _n | |
| TMDS_DATA[0] | TMDS_DATA0_p / _n | |
| TMDS_CLK     | TMDS_CLK_p / _n   | At pix_clk (25.175 / 40 MHz depending on mode) |

3.3 V differential at the package, dropped to TMDS via discrete
re-driver (TMDS181, RGZ 48-pin VQFN) near the HDMI connector. See
[hdmi.md](hdmi.md) and [fpga-part-selection.md](fpga-part-selection.md)
for the bank-voltage discussion.

### Ti60F256-C4 recommended BGA-side pin assignment

Picked so all four pairs sit on the **outermost two rows of the BGA**
(rows A + B), each pair vertical with P at row A (north) and N at
row B (south). That matches TMDS181's IN-side convention
(IN_xxp at lower pin number = "north" on its left edge), giving
**no diff-pair crossings** between FPGA and TMDS181 when the
TMDS181 sits above the FPGA's top edge with its left edge facing
south. Escape routing is 2-row-deep — every trace exits the BGA
package edge directly without diving through inner rows.

| TMDS net | FPGA pair (HSIO) | FPGA P pin | FPGA N pin | TMDS181 P pin | TMDS181 N pin |
|---|---|---|---|---|---|
| TMDS_D2  | 03         | A4  | B4  | 2  (IN_D2p)  | 3  (IN_D2n)  |
| TMDS_D1  | 05         | A6  | B6  | 5  (IN_D1p)  | 6  (IN_D1n)  |
| TMDS_D0  | 09 (CLK6)  | A9  | B9  | 8  (IN_D0p)  | 9  (IN_D0n)  |
| TMDS_CLK | 13         | A11 | B11 | 11 (IN_CLKp) | 12 (IN_CLKn) |

All four pairs share `VCCIO33_TL` (red square at B3 in the BGA
diagram), so they're in the same I/O bank — no voltage-domain
configuration friction. Left-to-right on the FPGA (col 4 → 11)
maps directly to top-to-bottom on the TMDS181's IN-side edge
(pin 2 → 12), so the four pairs run parallel without crossing.

Avoid pair 08 at A7/A8 even though it's geometrically close —
its P and N halves are arranged horizontally (same row), so
mapping it to TMDS181's vertically-stacked IN_Dx pair forces
either a 90° pair rotation or a polarity swap. The 4 vertical
pairs above are strictly easier. The TMDS181's `SWAP/POL` pin
exists precisely to let you use pair 08 if escape routing on
some future PCB rev demands it, but for the v1 layout it's
unnecessary complexity.

## Main RP2354 link pins (rp_tx + rp_rx)

Source-synchronous, no shared clock. See
[wire-protocol.md § "Clocking"](wire-protocol.md).

| Direction | Pins | FPGA bank | Translator | Notes |
|-----------|------|-----------|-----------|-------|
| FPGA → RP | `rp_tx_clk` + 26 data | HSIO 1.8 V | 4 × LVC8T245 (1.8 ↔ 3.3 V) | { tag[1:0], payload[23:0] }; clock free-running |
| RP → FPGA | `rp_rx_clk` + 16 data | **HVIO 3.3 V** | **none — direct** | 16-bit responses to FETCH; clock starts/stops |

The RP2354's PIO state machine drives `rp_rx_clk`; the FPGA receives
async and synchronises with a 2-flop chain in the pix_clk domain
where the line buffer lives.

## Peri-RP2354 link pins (peri_link)

Owns POT / SIO / SD card. FPGA-side master via `peri_link.sv`. /CS-
delimited 8-bit Motorola SPI MODE 0, two pulses per logical 16-bit
transaction (cmd byte + data byte separated by a master-controlled
gap). Peri-RP slave is its on-chip PL022 hardware SPI peripheral.

| Pin | Direction | FPGA bank | Notes |
|-----|-----------|-----------|-------|
| `spi_clk`  | FPGA → peri-RP | **HVIO 3.3 V** | ≈5 MHz at 162 MHz `clk_bus`, no shifter |
| `spi_mosi` | FPGA → peri-RP | HVIO 3.3 V | no shifter |
| `spi_miso` | peri-RP → FPGA | HVIO 3.3 V | no shifter |
| `spi_cs_n` | FPGA → peri-RP | HVIO 3.3 V | active-low slave-select |
| `spi_irq`  | peri-RP → FPGA | HVIO 3.3 V | active-low IRQ on STATUS-flag set |

## Joy PCAL9722 link pins (joy_link)

Owns 4 × 5 = 20 GPIOs of bidirectional joystick + fire pins.
FPGA-side master via `joy_link.sv`. Single 24-bit /CS-framed SPI MODE 0
transaction (cmd + reg-addr + data byte). PCAL9722's split VDDI
(1.8 V) / VDDP (5 V) eliminates both translation hops.

| Pin | Direction | FPGA bank | Notes |
|-----|-----------|-----------|-------|
| `joy_spi_clk`   | FPGA → PCAL9722 | HSIO 1.8 V | direct to VDDI 1.8 V — no shifter |
| `joy_spi_mosi`  | FPGA → PCAL9722 | HSIO 1.8 V | no shifter |
| `joy_spi_miso`  | PCAL9722 → FPGA | HSIO 1.8 V | no shifter |
| `joy_spi_cs_n`  | FPGA → PCAL9722 | HSIO 1.8 V | active-low |
| `joy_spi_int_n` | PCAL9722 → FPGA | HSIO 1.8 V | active-low; asserts on any unmasked input change |

## FPGA config link pins (peri-RP QSPI)

Boot-only. peri-RP pushes the bitstream over an 8-pin **Passive ×4**
link, then the pins go quiet for the rest of system runtime. See
[fpga-configuration.md](fpga-configuration.md) for the full sequence.

| Pin | Direction | FPGA bank | Notes |
|-----|-----------|-----------|-------|
| `CDI0` | peri-RP → FPGA | HSIO 1.8 V | data bit 0 (4-bit parallel) |
| `CDI1` | peri-RP → FPGA | HSIO 1.8 V | data bit 1 |
| `CDI2` | peri-RP → FPGA | HSIO 1.8 V | data bit 2 |
| `CDI3` | peri-RP → FPGA | HSIO 1.8 V | data bit 3 |
| `CCK`  | peri-RP → FPGA | HSIO 1.8 V | config clock, 25 MHz nominal |
| `SSL_N`| peri-RP → FPGA | HSIO 1.8 V | active-low config-block CS |
| `CRESET_N` | peri-RP → FPGA | HSIO 1.8 V | hold-in-reset, open-drain |
| `CDONE` | FPGA → peri-RP | HSIO 1.8 V | open-drain, pull-up to peri-RP 3.3 V rail |

Translators: 2 × 74LVC8T245BQ between FPGA HSIO 1.8 V and peri-RP
3.3 V (one outbound for the 7 RP→FPGA wires, one inbound for the
single CDONE). The dedicated nature of these pins means **no
runtime sharing** with rp_rx (unlike the prior main-RP scheme),
so no PIO program-swap is needed at CDONE.

## 6502 bus pins

fpga-antic has **no external 6502**. The internal SALLY (Arlet
core in `hdl/sally/cpu.v`) is always the bus master in deployment;
the external bus pins are a slave-side fan-out for cart-slot / PBI
/ ECI peripherals and are electrically active only at
`$D480 CLOCK_MULT = 1`. At CLOCK_MULT ≥ 2 the external bus
tristates entirely. See [architecture.md § External bus interfaces](architecture.md).

The `bus_addr` / `bus_rw` *input* ports on `antic_top` exist for
testbench-only stimulus: with `$D481[1] cpu_internal = 0` the snoop
pipeline reads from those ports instead of the internal SALLY's
bus, so testbenches can exercise the register-decode pipeline
without instantiating SALLY. Production silicon flips
`cpu_internal` to 1 once the OS ROM is loaded.

ANTIC's two display-fetch modes (snoop / DMA, $D481[0]) are
**internal-only** — they decide whether ANTIC reads `cpu_shadow`
without contending with SALLY (snoop, default) or asserts /HALT
to steal SALLY's bus cycles for cycle-exact compat (DMA mode).
The labels don't refer to any external-CPU snooping.

| Pin               | Direction       | Notes |
|-------------------|-----------------|-------|
| A[15:0]           | input or output | tristate-mux of `bus_addr` (snoop) and `dma_addr_o` (DMA), gated by `dma_oe` |
| D[7:0]            | inout           | tristate via `bus_data_oe` for FPGA reads; otherwise input |
| R/W               | input or output | tristate-mux similarly to A[] |
| /D0xx, /D4xx      | input           | page selects (active low) |
| /NMI, /HALT, /RDY | output (open-drain) | Atari signal convention |

The synth wrapper instantiates Efinix tristate IO buffers around each
of these; `antic_top` exposes the split data_in/data_out/data_oe
form so the testbench can drive both directions cleanly.

## Configuration / boot pins

The **peri-RP2354B** boots the FPGA at power-on via **Passive ×4**
(QSPI) — see [fpga-configuration.md](fpga-configuration.md). 8
dedicated pins, no sharing with rp_tx / rp_rx. Per-pin breakdown
in "FPGA config link pins (peri-RP QSPI)" above.

Earlier plan: main RP boots the FPGA via passive parallel ×16
sharing the rp_rx data pins. Reverted 2026-05-11 because the HVIO
repurpose (rp_rx onto HVIO 3.3 V direct) made the cross-bank
CDI[0..15] geometry untenable. The peri-RP route uses 8 dedicated
pins on a chip that has spare GPIOs and adds 2 × LVC8T245 to the
translator BOM. Frees 4 pins on the main RP.

## What "pin assignments" means at this stage

Concrete pin numbers (e.g., "A[0] is on package ball T11") get fixed
at the board-layout stage and live in
`efinity/constraints/<top>.peri.xml` (Efinix's I/O constraint file
format). The **groupings + counts** documented here are the
pre-layout commitments — they tell the PCB designer which signals
need to come out of which package edge, and they tell us early if
we're on track for the I/O budget.

Generated via the Efinity GUI's Interface Designer once the board is
in hand; Q4 / production-build follow-up.
