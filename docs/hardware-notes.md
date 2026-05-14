# Hardware notes — board-level interfaces (POR, May 2026)

Plan-of-record for the rp-XT board. Captures voltage domains, pin
allocation per chip, and the level-translator BOM. Companion doc:
[pin-map.md](pin-map.md) (FPGA-side pin grouping detail);
[fpga-part-selection.md](fpga-part-selection.md) (Ti60F256-C4
rationale); [register-map.md](register-map.md) (software-visible
register layout).

This doc replaces an earlier draft that routed peripherals (joystick
/ POT / SIO / SD) directly onto FPGA HSIO pins. That plan ran into
two hard constraints: (a) HSIO maxes at 1.8 V, requiring level
shifters between the FPGA and every 5 V Atari signal; (b) PIA's
PORTA / PORTB pins are bidirectional per-bit (XEP80, mouse adapters
etc. drive specific bits as outputs while leaving others as inputs),
which forces auto-sense translators rather than the cheaper
DIR-pin parts. Moving the peripherals onto a dedicated RP2354 with
its own 3.3 V GPIOs (with cheap series-R protection for the 5 V Atari
side) keeps the FPGA away from 5 V signaling entirely and lets the
peripheral protocols live in firmware. The joystick block specifically
moved off the peri-RP onto a PCAL9722 GPIO expander once the peri-RP
needed `/CS` on its SPI link (see "Architecture history" at the
bottom).

**HVIO gets repurposed in this revision.** The earlier draft put the
6502 bus on FPGA HVIO (3.3 V) so it could meet 5 V Atari TTL with the
smallest voltage gap. But the 6502 bus needs LVC8T245s either way
(same chip, same cost — VCCA = 1.8 V or 3.3 V both work), so HVIO's
3.3 V "advantage" wasn't buying anything. Moving the 6502 bus onto
HSIO frees HVIO's 27 pins for the **rp_rx (17) + peri-RP SPI link
(5)** — both run at 3.3 V matching HVIO directly, so they now
connect to the FPGA *with no level translation at all*. Net BOM
saving: 5 LVC8T245s (~$3.50). HVIO's confirmed 200 MHz max LVCMOS33
rate covers our 162 MHz `clk_bus` source-synchronous timing
comfortably.

## Architecture

```
   Atari 6502 bus  (5 V TTL)                              HDMI
          │                                                 ▲
     4× LVC8T245                                            │
     (1.8 ↔ 5 V)                                         TMDS1204
          ▼                                                 │
   ┌────────────────────────────────────────────────────────┐
   │              FPGA  Ti60F256-C4                         │
   │  ┌──────────────────┐   ┌──────────────────────┐       │
   │  │ HVIO  3.3 V      │   │     HSIO  1.8 V      │       │
   │  │  rp_rx (17)      │   │   6502 bus (27)      │       │
   │  │  Peri RP SPI (5) │   │   HyperRAM           │       │
   │  │  (5 spare)       │   │   HDMI TMDS          │       │
   │  └──────────────────┘   │   rp_tx (27)         │       │
   │                         │   Joy SPI + INT (5)  │       │
   │                         └──────────────────────┘       │
   └──┬───────────────────────┬─────────────────┬───────────┘
      │ SPI 4 + IRQ 1         │ rp_tx 27        │ SPI 4 + INT 1
      │ rp_rx 17              │ (4× LVC8T245    │ (no shifter — dual-supply)
      │ + QSPI config 8       │  1.8 V ↔ 3.3 V) │
      │ (HVIO direct + 2×     │                 │
      │  LVC8T245 for QSPI)   │                 │
      ▼                       ▼                 ▼
   ┌──────────────────┐  ┌──────────────┐  ┌────────────────────┐
   │ Peri RP2354B     │  │ Main RP2354B │  │ PCAL9722  (TSSOP)  │
   │ (QFN-80, 48 GPIO)│  │ (QFN-80,     │  │  VDDI 1.8 V        │
   │  - 8× POT        │  │   44/48 used)│  │  VDDP 5 V          │
   │  - SIO (12)      │  │  - video RAM │  │  - 4× joystick (20)│
   │  - SD card SPI(4)│  │  - USB host  │  │  - 2 GPIOs spare   │
   │  - PL022 HW SPI  │  │  - 4 spare   │  │  - INT_N → FPGA    │
   │  - FPGA QSPI (8) │  └──────────────┘  └────────────────────┘
   └──────────────────┘
            ▲                                        ▲
            │ direct + series-R                      │ direct (5 V VDDP)
       POT / SIO / SD                          joystick PORTA/PORTB
       5 V Atari side                         + 4× fire (5 V Atari)
```

Three off-FPGA chips, each with a focused job:

- **Main RP2354B**: line-buffered video RAM (rp_rx side serves the
  FPGA's framebuffer fetches at high rate), USB host (keyboard /
  mouse via TinyUSB). 44 of 48 GPIOs used for rp_tx (27) + rp_rx
  (17); 4 spare. **FPGA boot moved to the peri-RP** (passive ×4
  QSPI, see [fpga-configuration.md](fpga-configuration.md)) —
  earlier plan had it share rp_rx pins via passive parallel ×16
  but the HVIO repurpose made the cross-bank CDI[0..15] geometry
  untenable. USB DP/DM pins are dedicated and don't count toward
  the 48-GPIO budget.
- **Peri RP2354B**: timing-critical Atari peripherals — POT discharge
  counter (1.79 MHz fast-scan rate), SIO bus state machine (high-rate
  accessory-speed support), SD card SPI master. Talks to the FPGA
  via a 4-pin SPI link (CLK + MOSI + MISO + /CS) plus a 1-pin IRQ
  that signals "state changed, master should poll." Uses the
  RP2350's on-chip PL022 hardware SPI peripheral in slave mode — no
  PIO needed for the FPGA link.
- **PCAL9722**: 22-bit SPI GPIO expander with **independent VDDI / VDDP
  rails**. VDDI = 1.8 V matches FPGA HSIO directly (no LVC8T245 on
  the SPI link); VDDP = 5 V matches Atari joystick TTL directly (no
  series-R level translation). Carries all 4 × 5 joystick port pins
  (PORTA/PORTB bidirectional per-bit + 4 fire buttons) plus an INT_N
  line back to the FPGA for change-on-input detection.

Both RPs run at **3.3 V GPIO**. Main RP needs 3.3 V drive to sustain
rp_tx/rp_rx source-synchronous edges at FPGA `clk_bus` rate (~162 MHz
at BASE_DIV=90). Peri-RP can't cleanly partition its 48 GPIOs across
multiple IOVDD rails, so the FPGA-link bank inherits 3.3 V too.

**HVIO (3.3 V CMOS, max 200 MHz LVCMOS33) absorbs the inbound 3.3 V
traffic without translators**: rp_rx (RP → FPGA, 17 pins) and the
peri-RP SPI link (FPGA ↔ peri-RP, 5 pins) both connect directly,
eating 22 of HVIO's 27 pins. rp_tx (27 pins, FPGA → RP) doesn't fit
alongside, so it stays on HSIO with 4 LVC8T245s for level
translation. The 6502 bus moved off HVIO to make room — its
LVC8T245 count is unchanged (still 4 chips, just with VCCA = 1.8 V
instead of 3.3 V).

The PCAL9722's dual-supply design sidesteps both translation hops in
one shot: the SPI bus to the FPGA can stay at 1.8 V (no shifter) AND
the joystick pins to the Atari run at 5 V directly (no series-R level
translation, just pennies of ESD / fault-protection resistor arrays).

## Voltage domains

| Domain         | Voltage     | Where                                                |
|----------------|-------------|------------------------------------------------------|
| Atari bus      | 5 V TTL     | 6502 A/D/RW/page-selects, /NMI/HALT/RDY, joysticks, SIO, paddles |
| FPGA HVIO      | 3.3 V CMOS  | Left edge — 27 pins, dedicated to the 6502 bus       |
| FPGA HSIO      | 1.8 V CMOS  | Top/bottom/right edges — 142 pins, all high-speed paths |
| HDMI TMDS      | 3.3 V diff  | TMDS1204 re-driver between FPGA and HDMI socket       |
| Main RP2354B   | 3.3 V       | All 48 GPIOs                                         |
| Peri RP2354B   | 3.3 V       | All 48 GPIOs (with 5 V tolerant input clamps + series-R for Atari side) |
| PCAL9722 VDDI  | 1.8 V       | SPI interface side — matches FPGA HSIO               |
| PCAL9722 VDDP  | 5 V         | Joystick port side — matches Atari TTL               |
| SD card        | 3.3 V       | Direct connect to peri-RP                            |

The FPGA itself only ever runs 3.3 V (HVIO, 6502 bus) and 1.8 V
(HSIO, everything else). The 1.8 V vs 3.3 V split is purely an FPGA
internal voltage choice; nothing outside the FPGA needs to interface
to 1.8 V except the level shifters and the PCAL9722's VDDI.

## Pin allocation

### FPGA — Ti60F256-C4 (169 user I/O)

| Group               | Pins | Bank | Notes                                                 |
|---------------------|-----:|------|-------------------------------------------------------|
| **rp_rx**           |   17 | HVIO | RP → FPGA, clk + 16 data — direct 3.3 V, no LVC8T245  |
| **Peri RP2354B SPI**|    5 | HVIO | CLK + MOSI + MISO + /CS + IRQ — direct 3.3 V, no LVC8T245 |
| HVIO spare          |   ~5 | HVIO | room for cart-slot CS, GPIO LEDs                      |
| 6502 bus            |   27 | HSIO | A[15:0] + D[7:0] + RW + /D0xx + /D4xx (4× LVC8T245 1.8↔5 V) |
| **rp_tx**           |   27 | HSIO | FPGA → RP, clk + 26 data (4× LVC8T245 1.8↔3.3 V)      |
| HyperRAM PHY        |   13 | HSIO | DQ[7:0] + RWDS + CK_p + CS_n + RST_n (single-ended clock — CK_n dropped) |
| HDMI TMDS           |    8 | HSIO | 4 differential pairs. **+~4-8 SE pins reserved** by LVDS-adjacency rules — effective HSIO budget shrinks to ~134-138 (see pin-map.md § LVDS-adjacency tax). |
| HDMI auxiliary      |    5 | HSIO | /HPD_OUT (from TMDS1204, level-shifted to VIO) + TMDS1204 control I²C (SCL + SDA) + low-voltage DDC I²C (LV_DDC_SCL + LV_DDC_SDA — high-voltage side to HDMI connector goes through 1× PCA9306). Co-located with TMDS in banks 2A/2B (low-rate, no SSO impact). **TMDS1204 VIO = 1.8 V** (configurable, accepts 1.2 / 1.8 / 3.3 V LVCMOS) so the FPGA-facing 5 wires drive direct from HSIO — **no PCA9306 / HPD-shifter on the FPGA side**. The HPD level-shift to/from the 5 V HDMI connector pin is **built into the TMDS1204** (HPD_IN pin tolerant to 5.5 V). |
| **Joy PCAL9722 SPI**|    5 | HSIO | CLK + MOSI + MISO + /CS + INT_N (PCAL9722 VDDI = 1.8 V, no LVC8T245) |
| ANTIC status        |    3 | HSIO | /NMI, /HALT, /RDY (open-drain, external level shift)  |
| **FPGA config (QSPI)**|   8 | HSIO | CDI[0..3] + CCK + SSL_N + CRESET_N + CDONE — peri-RP boots the FPGA via Passive ×4; dedicated pins, no sharing with rp_rx. 2× LVC8T245 for HSIO 1.8 V ↔ peri-RP 3.3 V (one each direction). See [fpga-configuration.md](fpga-configuration.md). |
| Clocks / reset      |    2 | HSIO | sysclk in, /G_RST (`ram_clk` and `ram_clk_cal` are PLL outputs, no pins) |
| HSIO spare          |  ~42 | HSIO | nominal — actual spare is **~14-18** after the LVDS-adjacency tax (the 4 TMDS pairs reserve ~4-8 neighbouring SE pins as quiet-neighbour buffers; see pin-map.md). Additionally constrained by **per-bank SSO limits** — rp_tx split 15/12 across banks 3A/3B; HyperRAM PHY in banks 4A/4B; HDMI TMDS + auxiliary in banks 2A/2B. Room for the M-PBI 9 pins is still there but would consume most of the real margin. |
| **Total used**      | **120** |   | ~71 % of the nominal 169 budget; ~73 % of the effective ~161-165 (after LVDS-adjacency, before bank-SSO check) |

Why HVIO holds the inbound traffic + peri-RP SPI: HVIO's 3.3 V
CMOS matches the main RP's and peri-RP's 3.3 V GPIOs directly, so
those 22 pins skip the LVC8T245 hop entirely. HSIO's 1.8 V hosts
everything else, including rp_tx (which doesn't fit alongside rp_rx
in HVIO's 27 pins) and the 6502 bus (which needs LVC8T245 anyway —
a 1.8 V FPGA side and 3.3 V FPGA side cost the same since the
LVC8T245's VCCA range covers both).

The peri-RP and PCAL9722 SPI buses are independent — separate CLK /
MOSI / MISO / /CS, on different banks — so the FPGA can poll
joystick state in parallel with peri-RP traffic. At ~5 MHz each
they're easily within timing budget for a sequential master, but two
masters mean joystick reads don't queue behind a long SD-card
transaction.

### Peri RP2354B (QFN-80, 48 GPIOs)

All peri-RP GPIOs share **3.3 V IOVDD** — RP2354's bank partitioning
doesn't cleanly isolate the FPGA-link pins from the Atari-peripheral
pins, so a single rail covers everything. Per-pin protection comes
from the GPIO's input clamps + cheap series resistors.

| Group              | Pins | Voltage | Notes                                                 |
|--------------------|-----:|---------|-------------------------------------------------------|
| POT0..POT7         |    8 | 3.3 V/5 V ext | open-drain bidir (paddle discharge counter — see below) |
| SIO                |   12 | 5 V ext | DATAIN, DATAOUT, /COMMAND, /MOTOR, /PROCEED, /INTERRUPT, /READY, CLOCK_IN, CLOCK_OUT, AUDIO_IN, +5V sense, spare |
| SD card            |    4 | 3.3 V   | CLK / CS_n / MOSI / MISO (SPI mode, native PL022)     |
| FPGA SPI link      |    4 | 3.3 V   | CLK + MOSI + MISO + /CS — direct to FPGA HVIO (3.3 V), no LVC8T245 |
| IRQ to FPGA        |    1 | 3.3 V   | edge — peri-RP asserts when something changed; direct to HVIO     |
| **FPGA QSPI config** | 8 | 3.3 V | CDI[0..3] + CCK + SSL_N + CRESET_N + CDONE — boots the FPGA at power-on via Passive ×4 (~134 ms for ~1.7 MB bitstream at 25 MHz). 2× LVC8T245 between this side and the FPGA HSIO 1.8 V bank. |
| **Power-rail enables** | 2 | 3.3 V | EN_0.95V (FPGA core + PLL) + EN_1.8V (FPGA HSIO/AUX + TMDS1204 VIO + PCAL9722 VDDI). Driven during the rail-up sequence after peri-RP boots (see "Power rails + sequencing" above). Optional PG inputs add up to +2 more pins if using LDOs/bucks that expose PG. |
| **Total used**     |  **39** |     | 9 GPIOs spare                                         |

9 GPIOs free after FPGA boot moved here (was 19) and power-rail
sequencing added (-2 for rail enables; +2 more if we wire PG
inputs back to the peri-RP for closed-loop sequencing). M25-4 /
M25-5 follow-up work (SD 4-bit mode, additional SIO clock lines,
debug LEDs) still has room within the remaining 9 pins.

5 V signaling on the Atari side: RP2350 GPIOs are 3.3 V CMOS with
input clamps that survive transient 5 V. Standard Arduino-class
paddle adapters connect Atari 5 V lines directly to GPIOs. For a
shipping product we add a small **series resistor (~470 Ω - 1 kΩ)
per Atari pin** to limit clamp-diode current under fault — costs
pennies in resistor arrays, no level shifter ICs.

POT lines need their existing analog network unchanged (paddle pot
+ 0.1 µF cap to GND, pull-up to rail). The peri-RP runs the
discharge-counter algorithm in PIO + firmware — same algorithm as
POKEY's hardware did, with the result reported back to the FPGA's
POKEY shadow registers via the SPI link.

### Main RP2354B (QFN-80, 48 GPIOs)

| Group              | Pins | Voltage | Notes                                                 |
|--------------------|-----:|---------|-------------------------------------------------------|
| rp_tx (FPGA → RP)  |   27 | 3.3 V   | clk + 26 data — { tag[1:0], payload[23:0] }            |
| rp_rx (RP → FPGA)  |   17 | 3.3 V   | clk + 16 data — 16-bit responses to FETCH commands    |
| Spare              |    4 | 3.3 V   | freed when FPGA boot moved to peri-RP (2026-05-11). Possible uses: dedicated debug UART, second I²S for stereo metering, expansion connector. |
| **Total GPIOs**    | **48** |       | 44 used / 4 spare                                     |
| USB host (D+/D−)   |    2 | dedicated | RP2350 dedicates the USB pins separately from the GPIO budget; they don't compete with rp_tx/rp_rx |

Both rp_tx and rp_rx are source-synchronous at FPGA `clk_bus` rate
(~162 MHz at BASE_DIV=90). RP2350 GPIO drive at 1.8 V is too soft to
sustain those edges across a board trace, so we run the main-RP
GPIOs at 3.3 V. The link splits across two FPGA banks:

- **rp_tx** (FPGA → RP, 27 channels) on HSIO (1.8 V) → 4 × LVC8T245
  with DIR tied A→B (32 ch, 5 spare). LVC8T245's single DIR pin
  forces a per-direction split.
- **rp_rx** (RP → FPGA, 17 channels) on HVIO (3.3 V) → **direct
  connection, no LVC8T245**. HVIO's 200 MHz max LVCMOS33 rate
  handles the 162 MHz source-synchronous timing.

Total main-RP-link translator BOM: $2.80 (4 chips), down from $4.89
(7 chips) when both directions sat on HSIO. The "1.8 V everywhere"
optimisation is in [future-work.md](future-work.md) — gated on
real-silicon throughput measurement.

### PCAL9722 — joystick GPIO expander (TSSOP-32)

22-bit GPIO expander with split VDDI / VDDP rails, SPI host
interface, input change interrupt, per-pin direction / polarity /
pull-up / latch. NXP PCAL series — successor to the older PCA9555 et
al. with much richer per-pin control.

| Group              | Pins | Voltage | Notes                                                 |
|--------------------|-----:|---------|-------------------------------------------------------|
| Joystick port 1    |    5 | VDDP 5 V | UP / DN / LF / RT / TRIG (bidirectional per-bit)     |
| Joystick port 2    |    5 | VDDP 5 V | same shape                                            |
| Joystick port 3    |    5 | VDDP 5 V | same shape                                            |
| Joystick port 4    |    5 | VDDP 5 V | same shape                                            |
| Spare GPIOs        |    2 | VDDP 5 V | 2 of the 22 ports unused                              |
| **GPIO total**     |  **22** |      | exact fit, 2 spare                                    |
| SPI to FPGA        |    4 | VDDI 1.8 V | CLK + MOSI + MISO + /CS — direct to FPGA HSIO, no level shifter |
| INT_N to FPGA      |    1 | VDDI 1.8 V | active-low; asserts on any unmasked input change     |
| **Interface total**|  **5** |       | 5 FPGA HSIO pins                                      |

The dual-supply trick is the architectural win — without it, joystick
on a GPIO expander would need either a 1.8↔3.3 LVC8T245 on the SPI
side (extra IC) or a 3.3↔5 V translator on the joystick side (auto-
sense for bidirectional bits). PCAL9722 puts the level translation
inside the silicon at no extra cost.

PIA per-bit DDR (PORTA / PORTB direction control owned by the SALLY
side — see `pia_regs.sv`) maps to the PCAL9722's per-pin direction
register, written via `joy_link.sv` whenever software changes
DDRA / DDRB. INT_N + PCAL9722's input-latch + change-detect registers
cover the IRQ-on-change path so the FPGA-side `joy_bridge.sv` can
service joystick events on edge rather than polling at 30 kHz.

## Expansion connector traces (board-layout reminders)

These signals are wired in HDL (or planned, in the second-POKEY
case) but don't connect to any chip directly on the rp-XT main
PCB — they need traces to **physical headers / edge connectors**
that get populated later with adapter boards (cartridge slot,
PBI breakout, RS-232 DB9, etc.). The list exists so the PCB
designer doesn't forget to reserve pads / route traces / size the
LVC8T245 footprints for them.

### Cart slot (XL/XE 36-pin edge connector or equivalent header)

The cart slot is the headline expansion target — physical Atari
carts plug into a standard 36-pin edge connector. M-PBI's
external-bus + cart-detect signals all go here.

| FPGA signal     | Dir | Cart pin (typical) | Notes |
|-----------------|-----|--------------------|-------|
| `bus_addr_o[12:0]` | out | A0-A12 | 13 lines visible to cart (cart sees the 8K bank window only) — drive from same outputs as the 6502-bus traces |
| `bus_data_in[7:0]` / `bus_data_out` | bidir | D0-D7 | 8 lines; LVC8T245 controlled by `bus_data_oe` |
| `bus_rw_o`      | out | R/W | |
| `bus_s4_n_o`    | out | /S4 | $8000-$9FFF cart-window select |
| `bus_s5_n_o`    | out | /S5 | $A000-$BFFF cart-window select |
| `bus_cctl_n_o`  | out | /CCTL | $D5xx cart-control select |
| `bus_rd4_in`    | in (pulled-high) | RD4 | Cart-present, $8000-$9FFF (pull-up on board) |
| `bus_rd5_in`    | in (pulled-high) | RD5 | Cart-present, $A000-$BFFF (pull-up on board) |
| `halt_n`        | out | /HALT | Some carts use this to know when ANTIC is DMA-ing |
| `rst_n` (system) | bidir | /RST | Goes to the cart for cart-side reset |
| `phi2_o`        | out | φ2 | Synthetic phi2 clock (clk_bus / 90 ≈ 1.79 MHz) gated to CLOCK_MULT=1 production cycles. Exposed at antic_top (commit `2d07117`). |
| (cart audio)    | in  | AUDIO_IN | Analog signal from cart edge. Routes (fanned to PBI's AUDIO_IN too) to **PCM1808 Rin** — a stereo I²S ADC; the PCM1808's Lin pairs with SIO's AUDIO_IN. Both channels are mono signals from independent sources, both summed into both sides of the stereo HDMI output. See [future-work.md § Cart/PBI AUDIO_IN](future-work.md). +3 FPGA pads for the I²S RX bus to the PCM1808 (BCLK out, LRCK out, SDATA in). |
| +5 V, GND       | n/a | power | Cart-slot rail. Already on board. |

### PBI (XL/XE 50-pin Parallel Bus Interface header)

The PBI signals from M-PBI head here, alongside the full address
bus and the open-drain IRQ aggregate. The PBI is rare (only the
1090XL expansion enclosure used it natively), so this is most
likely a pin header rather than a real 50-pin connector — but the
trace assignments still need to happen.

| FPGA signal      | Dir | PBI pin (typical) | Notes |
|------------------|-----|--------------------|-------|
| `bus_addr_o[15:0]` | out | A0-A15 | Full 16-bit address (PBI devices typically decode all 16) |
| `bus_data_in` / `bus_data_out` | bidir | D0-D7 | Same LVC8T245 as cart slot — both connectors share these traces |
| `bus_rw_o`       | out | R/W | |
| `bus_d1xx_n_o`   | out | /EXTSEL | $D1xx page select (the PBI's chiplet decode) — same physical wire as the ECI `/D1xx` signal below |
| `bus_extenb_n_o` | out | /EXTENB | PBI device master-enable |
| `bus_mpd_n_in`   | in (pulled-high) | /MPD | Math-Pack Disable (overrides $D800-$DFFF FP ROM) |
| `bus_extirq_n_in`| in (OD, pulled-high) | /EXTIRQ | PBI IRQ, wired-OR with the main /IRQ tree |
| `nmi_n`          | out (OD) | /NMI | Driven by ANTIC nmi_gen; visible to PBI device |
| `halt_n`         | out (OD) | /HALT | DMA-cycle indicator |
| `rdy_n`          | out (OD) | /RDY | WSYNC + DMA stall indicator |
| `rst_n` (system) | bidir | /RST | |
| `phi2_o`         | out | φ2 | Same wire as cart slot |
| (PBI audio mix)  | in  | AUDIO_IN | Same as cart-slot AUDIO_IN — Y-mux at the board or share a single ADC input |
| +5 V, GND        | n/a | power | |

### ECI (XEGS Enhanced Cartridge Interface)

ECI is a few extra pins on the cart-edge connector that XEGS-class
machines exposed. **No new FPGA traces** — all the ECI signals are
the same physical wires as cart-slot or PBI, just brought out to
the cart-edge pins instead of (or in addition to) the PBI header:

| ECI pin | Same FPGA signal as | Notes |
|---------|---------------------|-------|
| /D1xx   | `bus_d1xx_n_o` (= PBI's /EXTSEL) | Board fans the one wire to both connectors |
| /RST    | `rst_n` (system) | |
| /HALT   | `halt_n` | |

Board layout note: the cart-edge connector footprint should
include pads for the ECI pins even if the cart connector is the
XL/XE 36-pin form (the ECI pins extend the standard cart edge).

### Second POKEY serial port (future RS-232 DB9 header)

The second POKEY (`u_pokey_r` at $D21x) is byte-level inside the
FPGA (`serout_byte` + `serout_strobe`, `ser_in_byte` +
`ser_in_byte_pulse`) — exactly like the first POKEY. The
first POKEY's SIO is bit-serialised on the **peri-RP firmware
side** (via the peri_link byte channel), so the analogous RS-232
routing for the second POKEY goes through the **peri-RP**, not via
FPGA pads.

Peri-RP-side reservation needed today:

- **2 peri-RP pads** (TX + RX) routed to a future RS-232 header.
  Peri-RP has 9 spare GPIOs after M-PBI's power-rail enables; this
  fits comfortably.
- **Footprint for a MAX232 / SP3232 / equivalent charge-pump
  translator** between peri-RP's 3.3 V outputs and the ±12 V DB9
  swing. Or skip translation and use a 3.3-V pin header (talks to
  USB-serial adapters fine; doesn't meet RS-232 voltage spec but
  works for most uses).
- **3-pin or DB9 header** at the board edge.

HDL side (deferred to a future milestone, M-serial):

- Extend `peri_bridge` with a second serial channel (`pokey_r`'s
  `serout_byte` / `serout_strobe` over peri_link).
- Peri-RP firmware: a software UART (bit-banged or PIO) that takes
  pokey_r byte payloads and emits RS-232 frames, and the reverse
  for RXD.

No FPGA-pad changes — antic_top doesn't need a new port for this.

Cost: ~$1 for MAX232 + caps + DB9, or $0.10 for a 3.3 V pin header.

### Summary: signals that need PCB destinations beyond on-board chips

| Signal group | Trace destinations | Status |
|--------------|--------------------|-------:|
| M-PBI cart-slot signals | XL/XE 36-pin cart edge (or pin header) | ✓ HDL complete (M-PBI commits) |
| M-PBI PBI signals | 50-pin PBI header (or pin header) | ✓ HDL complete (M-PBI commits) |
| M-PBI ECI extension pins | cart-edge extension pads | ✓ HDL complete (same wires as cart/PBI) |
| `phi2_o` | both cart slot + PBI | ✓ HDL exposed (commit `2d07117`) |
| Cart/PBI + SIO AUDIO_IN | cart-slot + PBI + SIO pins → PCM1808 stereo I²S ADC → FPGA (BCLK/LRCK/SDATA) | ⏳ Reserve PCB traces + PCM1808 footprint + **3 FPGA pads** for the I²S RX bus |
| Second POKEY serial | DB9 header via peri-RP + MAX232 | ⏳ Reserve 2 peri-RP pads + MAX232 footprint; no FPGA-pad change today |

**+1 FPGA pad** landed (phi2_o), with **+3 more reserved** for the
PCM1808 I²S RX bus. The full picture:

- **Cart/PBI/SIO AUDIO_IN via PCM1808** (~$2): stereo I²S ADC, Lin
  = SIO AUDIO_IN, Rin = PBI/cart AUDIO_IN. Both summed into both
  L and R of the HDMI stereo output (they're mono signals from
  independent sources). 3 FPGA pads for the I²S RX bus: BCLK out
  (3.072 MHz), LRCK out (48 kHz), SDATA in (serial 24-bit per
  channel). v1 board can leave the PCM1808 footprint depopulated
  if cart audio support is non-essential; the 3 FPGA pads still
  need to be reserved so the bus is wired even with the ADC
  unpopulated.

- **Second POKEY serial (RS-232)**: byte-level POKEY ↔ bit-level
  RS-232 framing happens on the peri-RP firmware side (same pattern
  as the first POKEY's SIO). PCB designer reserves **2 peri-RP
  pads** for TXD/RXD + a **MAX232-class translator footprint** +
  a **DB9 / 3-pin header**. No FPGA pads needed.

## Power rails + sequencing

rp-XT carries **four rails**, two of which need a managed sequence:

| Rail | Sources / consumers | Estimated current | Always-on? |
|------|---------------------|------------------:|-----------|
| **+5 V** | Atari side (cart slot, /S4//S5//CCTL/PBI signal levels), HDMI sink (DDC pull-ups), main board input | a few hundred mA | Yes (USB-C or external supply) |
| **+3.3 V** | RP2354s (both), TMDS1204 VCC, FPGA HVIO, PCAL9722 VDDP, level-translator B-sides | ~500 mA | Yes (always-on regulator from +5 V) |
| **+1.8 V** | FPGA VCCAUX + VCCIO (HSIO), **TMDS1204 VIO**, PCAL9722 VDDI, level-translator A-sides | ~300 mA | **No — sequenced** |
| **+0.95 V** | FPGA VCC (core) + VCCA (PLL) — both on the same rail on C4-timing parts | ~500 mA-1 A (depends on utilisation / clk_bus rate) | **No — sequenced** |

### Why sequencing matters

Efinix Titanium has constraints on the order and ramp-rate of its
power rails: the 0.95 V rail (VCC + VCCA) must come up before or
alongside the 1.8 V rail (VCCAUX + VCCIO), with documented ramp-
rate and slew limits. Out-of-order bring-up risks latch-up /
leakage / unrecoverable boot states. Exact spec lives in the Ti60
datasheet — needs lookup before PCB.

### Proposed sequencer: peri-RP2354B

The peri-RP already owns FPGA boot via QSPI (see
[fpga-configuration.md](fpga-configuration.md)). Extending it to
own **rail-enable sequencing** is the natural architectural fit:

```
USB-C power in
  → always-on 3.3 V regulator (from 5 V)
  → peri-RP boots from 3.3 V (~10-50 ms)
  → peri-RP firmware asserts EN_0.95V         (LDO/buck enable GPIO)
  → wait for PG_0.95V (or fixed delay if no PG)
  → peri-RP asserts EN_1.8V                   (LDO enable GPIO)
  → wait for PG_1.8V
  → wait for all rails settled (10-100 ms)
  → peri-RP releases CRESET_N to FPGA
  → peri-RP streams FPGA bitstream via QSPI
  → FPGA boots, system runs
```

Costs +2 peri-RP GPIOs (one per controlled rail enable). Peri-RP
total used 37 → 39; spare 11 → 9. Still within the 48-pin budget.

### Brick risk: low

RP2354 has the **UF2 flashing bootloader in hardware** (ROM /
silicon), not in firmware. Holding BOOTSEL while power-cycling
drops the chip into USB mass-storage mode regardless of what
state the user-flashed firmware is in, allowing drag-and-drop
recovery of a fresh UF2. So "bad peri-RP firmware bricks the
FPGA" isn't a real failure mode — every conceivable firmware bug
is recoverable via USB-C + BOOTSEL without specialist tools.

This makes the firmware-driven sequencing approach safe to commit
to without a hardware-PMIC fallback. If a dedicated PMIC (e.g.
LTC2937) is wanted later for other reasons — certification
deterministic-boot requirements, or a wish to remove peri-RP
from the critical-path of power-on — it can be retrofitted in a
PCB revision without changing the firmware architecture.

### Regulator topology (placeholder — needs current-budget validation)

| Rail | Topology | Suggested part | Cost |
|------|----------|----------------|-----:|
| 3.3 V | Buck (always-on) from 5 V | TPS62177 / MP2451 | ~$0.50 |
| 1.8 V | LDO from 3.3 V | AP2127N-1.8 / TLV70218 | ~$0.30 |
| 0.95 V | Buck from 3.3 V (current too high for LDO) | TPS62082 / MP2161 | ~$1.00 |

Regulator BOM: ~$1.80 plus passives + EN-control circuitry.

### Engineering checks before PCB

1. **Ti60 C4-timing power-on sequence.** Look up the exact
   required order, ramp-rate, and timing-between-rails between
   0.95 V (VCC + VCCA) and 1.8 V (VCCAUX + VCCIO) in the Ti60
   datasheet's "Power-On Sequence" section.
2. **Current budget per rail.** The 0.95 V current depends on
   utilisation, clk_bus rate, and which bursts are active (rp_tx
   + HyperRAM at full rate is the peak). Estimate with Efinity's
   power calculator after synth lands at the M25 freeze.
3. **PG / fixed-delay decision per rail.** Cheap LDOs don't have
   PG output. If we go LDO-without-PG, the sequencer waits a
   fixed dead-time (e.g., 1 ms per rail) — works as long as the
   LDO's enable-to-output time is well below the dead-time.
4. **Always-on 3.3 V regulator must boot the peri-RP reliably
   without further sequencing.** USB-C power-on → 3.3 V available
   → peri-RP boots. This regulator can't depend on the peri-RP
   for its own enable.

## TMDS1204 AC-coupling

The Efinix Titanium HSIO LVDS output has a typical common-mode
voltage of **0.9 V ± 0.175 V** (range 0.725 – 1.075 V). The
TMDS1204's DC-coupled-RX mode expects a **~3.3 V common-mode**
HDMI-TX-spec input (per §5.3 Recommended Operating Conditions:
the FRL-12Gbps DC-coupled-RX power figures specifically call out
"DC-coupled RX to 3.3 V Vicm"). There's a ~2.4 V gap — direct DC
connection isn't valid.

**Fix: AC-couple each of the 4 differential pairs** with series
capacitors. Each leg of each pair gets one 100 nF capacitor between
the FPGA pad and the TMDS1204 input. The cap blocks the DC common-
mode mismatch; the TMDS1204's input network biases the AC-coupled
signal to its native common-mode. TMDS1204 datasheet §5.3 specifies
input AC-coupling cap (`C_ACRX`) of **85-253 nF**, so 100 nF X7R
0402 fits the spec.

| Pair | Caps |
|------|-----:|
| TMDS_DATA0 P/N | 2 × 100 nF |
| TMDS_DATA1 P/N | 2 × 100 nF |
| TMDS_DATA2 P/N | 2 × 100 nF |
| TMDS_CLK P/N   | 2 × 100 nF |
| **Total** | **8 × 100 nF 0402 X7R** |

Cost: ~$0.16. Tiny vs the rest of the BOM.

### AC-coupling engineering checks before PCB

1. **Cap value within spec.** 85-253 nF per §5.3; we're using
   100 nF, comfortably inside the window. For low pixel-clock
   modes (480p, 720p) the lower end of the cap range can cause
   baseline wander — 100 nF gives margin.
2. **Cap placement close to the FPGA pads** (≤ 3 mm). The trace
   from the FPGA pad to the cap is at the FPGA's LVDS common-mode
   (~0.9 V); after the cap the trace is at the TMDS1204's input
   common-mode (~3 V via internal bias). Keeping the pre-cap
   trace short minimizes coupled noise on the lower-bias side.
3. **Differential routing post-cap unchanged.** The two caps in
   each pair are placed symmetrically so the P/N traces remain
   length-matched. Caps don't add latency mismatch if placed at
   the same point along each leg.
4. **AC_EN pin strap.** TMDS1204 pin 23 (AC_EN) controls whether
   the **TX output** to the HDMI sink is AC-coupled. For a
   standard HDMI receptacle the answer is yes — strap AC_EN high
   in pin-strap mode (or program via I²C). Note: AC_EN does
   **not** control the RX-input coupling — that's just the
   physical presence of input series caps.

## Level-translator BOM

Translators are needed **only** for the 5 V Atari side and for the
rp_tx outbound flow from FPGA HSIO 1.8 V to main-RP 3.3 V. rp_rx
and the peri-RP SPI link both run 3.3 V → 3.3 V via HVIO direct,
saving 5 LVC8T245s vs the previous all-on-HSIO plan.

| Group                                                | Translator           | Qty | Q10 unit | Subtotal |
|------------------------------------------------------|----------------------|----:|---------:|---------:|
| 6502 bus (FPGA HSIO 1.8 V ↔ 5 V Atari)               | 74LVC8T245BQ,118     |   4 |  $0.699  |   $2.80  |
| Atari status (/NMI etc.)                             | 74LVC1G07 open-drain |   3 |  $0.20   |   $0.60  |
| HDMI redriver (HDMI 2.1 FRL + 1.8 V VIO + integrated HPD shifter) | TMDS1204         |   1 |   $6.81  |   $6.81  |
| HDMI TMDS AC-coupling caps (4 pairs, 2 each)         | 100 nF 0402 X7R      |   8 |  $0.02   |   $0.16  |
| HDMI DDC level shifter (TMDS1204 1.8 V ↔ HDMI 5 V)    | PCA9306              |   1 |  $0.50   |   $0.50  |
| Stereo ADC (SIO + cart/PBI AUDIO_IN → I²S → FPGA)     | PCM1808              |   1 |  $2.00   |   $2.00  |
| rp_tx (FPGA HSIO 1.8 V ↔ 3.3 V main RP)              | 74LVC8T245BQ         |   4 |  $0.699  |   $2.80  |
| rp_rx (FPGA HVIO 3.3 V ↔ 3.3 V main RP) — direct     |  —                   |   0 |     —    |   $0.00  |
| Peri RP SPI + IRQ (FPGA HVIO 3.3 V ↔ 3.3 V peri RP) — direct | —            |   0 |     —    |   $0.00  |
| FPGA config QSPI (FPGA HSIO 1.8 V ↔ 3.3 V peri RP)   | 74LVC8T245BQ         |   2 |  $0.699  |   $1.40  |
| **PCAL9722** (joystick GPIO expander, dual-supply)   | PCAL9722             |   1 |  $1.44   |   $1.44  |
| Series resistors (peri-RP Atari side + joystick side)| 0805 R-arrays        |  ~8 |  $0.05   |   $0.40  |
| **Total**                                            |                      |     |          | **~$18.51** |

Earlier estimates ($13.74 FPGA-direct, $11.10 pure peri-RP-3-pin)
under-counted LVC8T245 quantity on links that mix unidirectional
flows in both directions; later estimates ($14.03 with full HSIO
hosting) didn't yet exploit HVIO. The current figure folds in both
corrections.

**HVIO repurpose**: HVIO (3.3 V CMOS, 27 pins, max 200 MHz LVCMOS33)
hosts the inbound 3.3 V traffic that previously went through HSIO
1.8 V translators. rp_rx (17 ch) + peri-RP SPI (5 ch) = 22 pins,
matching FPGA-side voltage to RP-side voltage exactly — no
LVC8T245 needed for either link. This evicts the 6502 bus to HSIO,
but its translator count is unchanged (LVC8T245's VCCA covers both
1.8 V and 3.3 V identically).

**LVC8T245 per-direction splits**: 74LVC8T245BQ has a *single* DIR
pin that controls all 8 channels in lockstep — they all go A→B or
all B→A. Any HSIO-hosted link with unidirectional flows needs
separate chips per direction:

- **rp_tx, 4 chips total**: 27 channels FPGA → RP, DIR=A→B,
  32 ch / 5 spare. rp_rx is on HVIO direct, so the data sheet's
  reverse direction doesn't need a chip here.
- (Peri-RP SPI: zero chips — entirely HVIO direct.)

The 6502 bus is the exception in another sense — its data lines
D[7:0] are genuinely bidirectional (driven high or driven low by
either side depending on RW), so its 4 LVC8T245s have their DIR
pins driven dynamically by the FPGA's bus_rw signal. That's the
part type's design intent; for the unidirectional rp_tx traffic
above, we just tie DIR static.

PCAL9722's split-supply design dodges translation on the joystick
SPI bus: its 1.8 V VDDI side ties to FPGA HSIO directly without any
LVC8T245 between them.

## POT (paddle) hardware

The Atari paddle isn't a "read this voltage" analog input — it's a
**discharge-time-counter**. The mechanism:

```
    +5 V (or +3.3 V — paddle is voltage-agnostic; see "rail" below)
     │
   ~1 MΩ     paddle pot — variable resistance, 0 Ω (full clockwise)
     │       to ~1 MΩ (full counter-clockwise)
     │
     ├──────*──────►  POT_n pin (peri-RP GPIO, open-drain bidir)
     │
   0.1 µF
     │
    GND
```

Discharge / count cycle (was POKEY hardware in M23-5; now peri-RP
firmware):

1. Software writes `POTGO` ($D20B) — kicks off a scan via the
   FPGA→peri-RP SPI link.
2. Peri-RP pulls the line **low** (open-drain to GND) for ~7 ref ticks
   to **discharge the cap** through its GPIO.
3. Peri-RP **releases** the line (high-Z input mode).
4. Cap **charges** through the paddle pot. Time to charge =
   *R*·*C* approximately, where *R* is the paddle's pot setting.
5. Peri-RP samples the line on every ref tick (15 kHz slow / 1.79 MHz
   fast — driven by a PIO timer); when the line crosses the input
   threshold, peri-RP **latches** the count.
6. The count is reported back to the FPGA's POKEY shadow registers
   (`POT0..POT7` at $D200..$D207) via the next SPI cycle / IRQ pulse.

Peri-RP pin requirements per channel:

- **Bidirectional, open-drain** behaviour (drive low / release; never
  drive high). Standard for RP2350 GPIO with output-enable + input
  high-Z modes.
- 1 kΩ series resistor between RP pin and Atari connector — limits
  clamp-diode current if a paddle / cable injects an out-of-spec
  voltage. Cheap, no IC needed.
- Schmitt-trigger input for clean threshold crossing — RP2350 GPIO
  already has Schmitt input as a setting.

**Paddle rail decision**: ship rp-XT v1 with **3.3 V paddle pull-ups**.
Trade-offs vs 5 V:

- Lower cap-charge current (≈ 3.3 µA vs 5 µA worst case at 1 MΩ).
  Marginally less power, no functional difference.
- Aligns with the 3.3 V rails already on board for the SD card and
  RP-link side.

A DNP solder jumper rebrands the external pull-up rail (3.3 V ↔ 5 V)
for users wanting period-accurate paddle voltage on a specific
accessory. POKEY's count semantics are voltage-agnostic (count =
time to cross threshold), so any software seeing a paddle reading
works either way.

## Open questions

1. **Paddle rail**: 3.3 V default committed; DNP jumper for 5 V.
   Open: any real-world period peripherals that demand 5 V we can't
   ignore? (Trak-balls, light pen, etc — most period digital
   peripherals ride the joystick port not the paddle pins.)
2. **6502 bus DIR signal sharing** — 2 DIR pins is the M23-area
   estimate; PCB might want to gang to 1 with a per-byte /OE on each
   chip. Refine when the layout starts.
3. **PCAL9722 VDDI rail** — committed to 1.8 V to match FPGA HSIO
   directly. PCAL9722's spec range is 1.65 V to 5.5 V on VDDI, so
   1.8 V is well inside. Open: real-silicon SPI rise-time on the
   1.8 V interface across the board trace; if too slow, fall back
   to 3.3 V VDDI + 1 × LVC8T245 for $0.70.

## Closed questions / locked decisions

- **Both RPs are RP2354B (QFN-80, 48 GPIOs each).** Main RP uses
  44 (rp_tx + rp_rx); 4 spare since FPGA boot moved to peri-RP
  (2026-05-11). Peri-RP uses 37 (POT + SIO + SD + FPGA SPI link
  + FPGA QSPI config) — 11 free. USB DP/DM are dedicated pins
  separate from the 48-GPIO budget on both chips.
- **FPGA boots from peri-RP via Passive ×4 QSPI**, not from main-RP
  via passive parallel ×16. 8 dedicated config pins on the FPGA
  HSIO side + 2 × LVC8T245 (one each direction) for 1.8 V ↔ 3.3 V
  translation. The earlier plan tried to share the 16-bit CDI[0..15]
  config data with rp_rx pins via PIO program-swap, but the HVIO
  repurpose put rp_rx on HVIO 3.3 V direct — and Efinix doesn't
  allow CDI[0..15] to span both HVIO and HSIO banks. See
  [fpga-configuration.md](fpga-configuration.md).
- **Both RPs run at 3.3 V GPIO.** Main RP needs 3.3 V drive to
  sustain rp_tx/rp_rx source-synchronous edges at FPGA `clk_bus`
  rate. Peri-RP can't cleanly partition its 48 GPIOs across multiple
  IOVDD rails, and the Atari side needs 3.3 V to interoperate with
  5 V TTL noise margins, so the FPGA-link bank inherits 3.3 V too.
- **HVIO (FPGA 3.3 V bank, 27 pins) hosts inbound 3.3 V traffic.**
  rp_rx (17 ch RP → FPGA) and the peri-RP SPI link (5 ch, all five
  pins) connect directly to HVIO with no level translation, since
  both sides are 3.3 V CMOS. HVIO's max LVCMOS33 rate is 200 MHz,
  comfortably above the 162 MHz `clk_bus`. The 6502 bus moves to
  HSIO with VCCA = 1.8 V on its LVC8T245s — same chip count as
  before. Net BOM saving: 5 LVC8T245s eliminated (3 for rp_rx, 2
  for peri-RP SPI).
- **Joystick on PCAL9722, not peri-RP.** The peri-RP needed `/CS` on
  its SPI link (eliminates the slave-side timing race so `peri_link`
  can use the RP2350's PL022 hardware SPI peripheral instead of a
  custom PIO program). With joystick at 20 GPIOs blocking 19 free
  pins on the peri-RP, /CS would have pushed the peri-RP back to
  exact-fit. Moving joystick to a $1.44 PCAL9722 frees the budget
  AND the dual-supply rails translate both 1.8↔3.3 (SPI) and
  3.3↔5 V (joystick) for free.
- **Peri-RP SPI link is 5 pins (CLK + MOSI + MISO + /CS + IRQ).**
  Two 8-bit /CS pulses per logical 16-bit transaction; the master-
  controlled gap between halves removes the cmd-byte → MISO timing
  race the no-/CS plan had.

## Architecture history

The M25 architecture iterated five times before landing on the
current peri-RP2354B + PCAL9722 + HVIO-direct hybrid:

1. **FPGA-direct routing**: every Atari peripheral pin landed on
   FPGA HSIO with discrete level shifters. ~$13.74 in translators,
   constrained by HSIO's 1.8 V class meeting 5 V Atari plus the
   per-bit bidirectional pain on PIA's PORTA/PORTB (XEP80, mouse
   adapters, bit-banged serial gadgets — drove specific bits as
   outputs while leaving others as inputs; shared-DIR LVC8T245s
   couldn't follow that, so auto-sense TXS0108E was needed for
   joysticks alone). End-to-end ~$18.74 / board.
2. **2 × PCAL9722 GPIO expander** (NXP 22-bit SPI expander with
   split VDDI/VDDP rails): cheapest BOM at ~$18.27 / board, no
   firmware build, but two showstoppers:
   - **SIO can't reach high-rate accessory speeds.** Standard SIO
     at 19.2 kbaud fits; faster modes (Black Box / MIO / SIO2PC at
     38.4-127 kbaud, or modern USB-SIO bridges at 250+ kbaud) need
     SIO line sampling at rates that exceed PCAL9722's 5 MHz SPI
     access ceiling. The 8 µs/bit budget at 124 kbaud SIO already
     equals one PCAL9722 register read.
   - **Fast pot scan unsupported.** SKCTL[2]=1 mode samples each
     POT line at 1.79 MHz; PCAL9722 SPI tops out at ~200 kHz GPIO
     read rate. Slow scan (15 kHz) works but software using fast
     scan would need an emulation hack.
3. **Peri-RP2354B (single chip, no /CS)**: dedicated RP2354B handles
   all peripherals — joystick + POT + SIO + SD. No /CS on the SPI
   link, frame boundaries via CLK idle. Custom PIO program on the
   peri-RP for the SPI slave because PL022 needs /CS. ~$11.10 BOM.
   Worked, but the cmd-byte-to-MISO timing race within a single
   16-bit frame meant the polling loop had ~50 cycles to load the
   read response before MISO bit 8 needed to be valid — fragile.
4. **Peri-RP2354B + PCAL9722 (all-HSIO)**: split joystick (20 pins,
   low-rate, no critical timing) onto a PCAL9722 — its SPI ceiling
   at 5 MHz is plenty for the 30 kHz joystick scan rate. Frees a
   peri-RP pin for /CS, which lets the peri-RP use its PL022 hardware
   SPI instead of PIO. The 6502 bus stayed on HVIO and every other
   3.3 V link sat behind LVC8T245s on HSIO. ~$14.03 BOM.
5. **Peri-RP + PCAL9722 + HVIO-direct (2026-05-10)**: same chip
   layout as (4), but moves rp_rx (17 ch) + peri-RP SPI (5 ch) onto
   HVIO. HVIO's 3.3 V CMOS matches the RP-side directly (no
   LVC8T245), and its 200 MHz max LVCMOS33 rate covers the 162 MHz
   `clk_bus` source-synchronous timing. The 6502 bus moves to HSIO
   with VCCA = 1.8 V on its translators (same chip count, no extra
   cost). Net BOM saving vs (4): −$3.49 from 5 fewer LVC8T245s.
6. **FPGA boot moves to peri-RP via QSPI (current POR, 2026-05-11)**:
   the HVIO repurpose at (5) put rp_rx on HVIO direct, but the
   original passive-parallel-×16 boot scheme had been sharing those
   pins with CDI[0..15] via a PIO program-swap at CDONE. Once rp_rx
   was on HVIO, the 16-bit CDI[0..15] data would have had to span
   HVIO + HSIO, which Efinix's Interface Designer rejects. Solution:
   move FPGA boot to **peri-RP** using **Passive ×4 (QSPI)** on 8
   dedicated HSIO pins (CDI[0..3] + CCK + SSL_N + CRESET_N + CDONE),
   no shared pins. Costs +2 × LVC8T245 (+$1.40) for HSIO 1.8 V ↔
   peri-RP 3.3 V translation. Frees 4 pins on main RP. Eliminates
   the PIO program-swap. See [fpga-configuration.md](fpga-configuration.md).

Trade-off summary at the POR landing (every BOM figure here uses
correct per-direction LVC8T245 counts):

| Plan | Translator BOM | Off-FPGA silicon | End-to-end | High-rate SIO | Fast POT scan | SD throughput | SPI race |
|------|---------------:|-----------------:|-----------:|---------------|---------------|---------------|----------|
| FPGA-direct† | $14.44 | $5 (1× LVC8T245 array) | $19.44 | OK (HDL) | OK (HDL) | OK (HDL) | n/a |
| 2× PCAL9722 | $13.97† | $2.88 (2× expander) | $18.97 | **No** | **No** | Slow | n/a |
| Peri-RP no /CS | $12.50† | $5 (1× RP2354B) | $22.50 | OK (PIO) | OK (PIO) | OK | **Tight** |
| Peri-RP + PCAL9722 all-HSIO | $14.03 | $6.44 | $24.03 | OK (PIO) | OK (PIO) | OK | **None** |
| Peri-RP + PCAL9722 + HVIO | $10.54 | $6.44 | $20.54 | OK (PIO) | OK (PIO) | OK | **None** |
| **+ QSPI-config-on-peri-RP (POR)** | $11.94 | $6.44 (1× RP2354B + 1× PCAL9722) | $20.94 | OK (PIO) | OK (PIO) | OK | **None** |

† Corrected from earlier estimates that under-counted LVC8T245
quantity by missing the per-direction-split rule (LVC8T245's single
DIR pin controls all 8 channels in lockstep, so unidirectional flows
in both directions need separate chips). Main-RP rp_tx/rp_rx needs
4+3=7 chips on HSIO (or 4+0 once rp_rx moves to HVIO direct).
Peri-RP SPI needs 2 on HSIO (or 0 once it moves to HVIO direct).

The HVIO-direct rev brings the **translator BOM** below the FPGA-
direct baseline ($10.54 vs $14.44, a $3.90 saving) while keeping
every architectural win of (3) and (4): high-rate SIO, fast POT
scan, native SD throughput, HW SPI on the peri-RP, no SPI timing
race. End-to-end (translator + off-FPGA silicon) sits at $20.54 —
~$1.10 above FPGA-direct's $19.44, but that delta is the price of
the off-FPGA peri-RP + PCAL9722 silicon ($6.44 vs $5.00), and
that's exactly what buys the high-rate features.
