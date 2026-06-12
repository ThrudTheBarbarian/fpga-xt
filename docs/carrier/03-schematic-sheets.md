# fpga-xt motherboard — schematic sheets (netlist / ASCII)

Status: **draft v0.1** · Pairs with [`01-architecture.md`](01-architecture.md),
[`02-bom.md`](02-bom.md). Transcribe these into Altium (symbols built by the
DelphiScript under `altium/`).

**Net-naming convention**
- `+5V`, `+3V3`, `GND` — power.
- `F_*` — FPGA-side (3.3 V) bus nets (A side of CB3T).
- `B_*` — connector-side (5 V) bus nets (B side of CB3T), shared cart+PBI.
- `R_*` — RP2354B I/O nets.
- Active-low signals carry a trailing `_N`.

**Authoritative pinouts** below are 800XL-strict (AtariWiki / *Mapping the
Atari* / Wikipedia). 800XL gotchas applied: SIO pin 12 = NC, PBI pins
47/48 = NC, **no /HALT or /CASINH on PBI**, cart /RD4//RD5 are inputs.

---

## Sheet 1 — Power

```
J_PWR (5V barrel, center +) .center ─ VIN
                            .sleeve ─ GND
VIN ─ D_TVS1 (SMBJ5.0A) ─ GND                  ; input clamp
VIN ─ F1 (polyfuse 5A) ─ N1
N1  ─ Q_IDEAL (P-FET ideal-diode, e.g. LM74700+FET)  ─ +5V   ; reverse-batt protect
      (or Schottky SS54 N1→+5V if simpler)
+5V ─ C1,C2 (47µF/10V ×2) ─ GND                ; bulk
+5V ─ C3 (0.1µF) ─ GND

; ---- 3.3V buck ----
U_BUCK (TPS562201)  VIN=+5V  EN=+5V(via Renable)  GND=GND
   SW ─ L1 (2.2µH) ─ +3V3
   +3V3 ─ Rfb_top ─ FB ─ Rfb_bot ─ GND         ; set 3.3V
   +3V3 ─ C4,C5 (22µF ×2) ─ GND
   +3V3 ─ C6 (0.1µF) ─ GND

; ---- distribution ----
+5V  → CN1.VDD_5V, CN2.VDD_5V                   ; back-feed daughterboard
+5V  → F_CART (polyfuse 0.2A) → CART_+5V
+5V  → F_SIO  (polyfuse 0.1A) → SIO_+5V (pin10)
+5V  → F_USB1..4 (polyfuse 0.5A ea) → USBn_VBUS
+3V3 → all 3V3 loads (RP, hub, PCM1808, CB3T Vcc, pull-ups, joystick pin7)
```

---

## Sheet 2 — Daughterboard interface CN1 / CN2 (Harwin M55, 2×40, 1.27 mm SMD)

Connector: **Harwin M55-7008042R** (or mating gender) — use vendor footprint.
1.2 A/contact → **parallel all `VDD_5V` and `GND` contacts** (we back-feed the
Z-Turn's ≤1.5 A of 5 V through them). Physical CN pin numbers per
`refs/Z-TURNBOARD_schematic.pdf` sheet 15;
this sheet lists the **logical** assignment (our net ↔ Z-Turn signal name).
The matching Zynq XDC pin (Bank 35 / Bank 13 ball) goes in
`vivado/constraints/` — proposed assignment in the table below.

**Power/control on CN1/CN2**
```
CN1.VDD_5V, CN2.VDD_5V       ← +5V        (we source it)
CN1.VDD_3.3V, CN2.VDD_3.3V   ← +3V3 (or leave to SOM PMIC; pick one source ⚑)
CN1.VDDIO_13_PL              ← +3V3       (Bank 13 VCCIO = 3.3V)
CN*.DGND                     ← GND
CN1.JTAG_TCK/TMS/TDI/TDO/NTRST → J_JTAG header
```

**Proposed FPGA net → bank-pin assignment** (fill XDC ball + CN pin from sheet 15):

| Net group | Count | Bank | Signal names |
|---|---:|---|---|
| `F_A0..F_A15` | 16 | 35 | `IO_B35_LP0..LP15` |
| `F_D0..F_D7` (bidir) | 8 | 35 | `IO_B35_LN0..LN7` |
| `F_PHI2, F_RW` | 2 | 35 | `IO_B35_LP16, LN16` |
| `F_S4_N, F_S5_N, F_CCTL_N` | 3 | 35 | `IO_B35_LP17, LN17, LP18` |
| `F_EXTSEL_N, F_EXTENB_N, F_REF_N, F_RST_N` | 4 | 35 | `IO_B35_LN18, LP19, LN19, LP20` |
| `F_RD4_N, F_RD5_N, F_MPD_N, F_IRQ_N, F_RDY_N` (in) | 5 | 35 | `IO_B35_LN20..LP22,LN22` |
| `F_BUS_OE1..OE4` (CB3T bank OE) | 4 | 35 | `IO_B35_LP23,LN23,LP24,LN24` |
| `EXP_*` (TMDS_33 pairs + s-e) | 39 | 35 | remaining Bank-35 LP/LN pairs |
| `SPI_SCK,SPI_MOSI,SPI_MISO,SPI_CSN,SPI_IRQ_N` | 5 | 13 | `IO_B13_LP11..LP13,LN13,LP14` |
| `I2S_BCK,I2S_LRCK,I2S_DOUT,I2S_SCKI` | 4 | 34 | `I2S_SCLK,I2S_FSYNC,I2S_Din,(SCKI)` group |

*(39 bus signals = 16+8+2+3+4+5+1 spare; the 4 OE lines are extra control.)*

---

## Sheet 3 — Cart/PBI bus + 2× SN74CB3T16210

A side = FPGA (`F_*`, 3.3 V), B side = connectors (`B_*`, 5 V). Vcc = +3V3.
OEs tied **active (low)** by default (see note); option to gate cart selects.

```
U_BUS1 (CB3T16210)  VCC=+3V3  GND=GND  1OE=BUS_OE1_N  2OE=BUS_OE2_N
  ; Bank1 (1A/1B ×10)            ; Bank2 (2A/2B ×10)
  1A1 F_A0   ─ 1B1 B_A0          2A1 F_A10  ─ 2B1 B_A10
  1A2 F_A1   ─ 1B2 B_A1          2A2 F_A11  ─ 2B2 B_A11
  1A3 F_A2   ─ 1B3 B_A2          2A3 F_A12  ─ 2B3 B_A12
  1A4 F_A3   ─ 1B4 B_A3          2A4 F_A13  ─ 2B4 B_A13
  1A5 F_A4   ─ 1B5 B_A4          2A5 F_A14  ─ 2B5 B_A14
  1A6 F_A5   ─ 1B6 B_A5          2A6 F_A15  ─ 2B6 B_A15
  1A7 F_A6   ─ 1B7 B_A6          2A7 F_D0   ─ 2B7 B_D0
  1A8 F_A7   ─ 1B8 B_A7          2A8 F_D1   ─ 2B8 B_D1
  1A9 F_A8   ─ 1B9 B_A8          2A9 F_D2   ─ 2B9 B_D2
  1A10 F_A9  ─ 1B10 B_A9         2A10 F_D3  ─ 2B10 B_D3

U_BUS2 (CB3T16210)  VCC=+3V3  GND=GND  1OE=BUS_OE3_N  2OE=BUS_OE4_N
  1A1 F_D4   ─ 1B1 B_D4          2A1 F_EXTENB_N ─ 2B1 B_EXTENB_N
  1A2 F_D5   ─ 1B2 B_D5          2A2 F_REF_N    ─ 2B2 B_REF_N
  1A3 F_D6   ─ 1B3 B_D6          2A3 F_RST_N    ─ 2B3 B_RST_N
  1A4 F_D7   ─ 1B4 B_D7          2A4 F_RD4_N    ─ 2B4 B_RD4_N   (in)
  1A5 F_PHI2 ─ 1B5 B_PHI2        2A5 F_RD5_N    ─ 2B5 B_RD5_N   (in)
  1A6 F_RW   ─ 1B6 B_RW          2A6 F_MPD_N    ─ 2B6 B_MPD_N   (in)
  1A7 F_S4_N ─ 1B7 B_S4_N        2A7 F_IRQ_N    ─ 2B7 B_IRQ_N   (in)
  1A8 F_S5_N ─ 1B8 B_S5_N        2A8 F_RDY_N    ─ 2B8 B_RDY_N   (in)
  1A9 F_CCTL_N ─ 1B9 B_CCTL_N    2A9  (spare)
  1A10 F_EXTSEL_N ─ 1B10 B_EXTSEL_N   2A10 (spare)

; 5V-side bus pull-ups (bus floats when FPGA D[] tri-states)
RN_PU (10k ×8) : B_D0..B_D7 → +5V
R_PU2 (10k)   : B_IRQ_N, B_RDY_N, B_MPD_N → +5V   ; open-drain-ish inputs
```

> **OE note:** A0–A15/D0–D7 are *shared* by cart and PBI, so the FET switch
> can't isolate the cart slot without also cutting PBI. Tie all OE low
> (always on); cart "isolation" is achieved by the FPGA simply not asserting
> `/S4 //S5 //CCTL`. If you want a hard cart cut-off for hot-swap, put the
> three cart selects on one bank (2OE of U_BUS2) and gate `BUS_OE4_N`.

### Cartridge connector J_CART (30-pin, 2×15 **0.1″ B2B pin header**) — 5 V side (`B_*`)
```
 Numbered row              Lettered row
 1  B_S4_N                 A  B_RD4_N   (in)
 2  B_A3                   B  GND
 3  B_A2                   C  B_A4
 4  B_A1                   D  B_A5
 5  B_A0                   E  B_A6
 6  B_D4                   F  B_A7
 7  B_D5                   H  B_A8
 8  B_D2                   J  B_A9
 9  B_D1                   K  B_A12
 10 B_D0                   L  B_D3
 11 B_D6                   M  B_D7
 12 B_S5_N                 N  B_A11
 13 CART_+5V               P  B_A10
 14 B_RD5_N  (in)          R  B_RW
 15 B_CCTL_N               S  B_PHI2
```
*(No audio pin on the cartridge connector.)*

### PBI connector J_PBI (50-pin, 2×25 — **PCB edge fingers**, board-edge) — 5 V side
```
 1  GND            26 B_D5
 2  B_EXTSEL_N(in) 27 B_D6
 3  B_A0           28 B_D7
 4  B_A1           29 GND
 5  B_A2           30 GND
 6  B_A3           31 B_PHI2
 7  B_A4           32 GND
 8  B_A5           33 NC
 9  B_A6           34 B_RST_N
 10 GND            35 B_IRQ_N (in)
 11 B_A7           36 B_RDY_N (in)
 12 B_A8           37 NC
 13 B_A9           38 B_EXTENB_N
 14 B_A10          39 NC
 15 B_A11          40 B_REF_N
 16 B_A12          41 (B_CAS_N) *
 17 B_A13          42 GND
 18 B_A14          43 B_MPD_N (in)
 19 GND            44 (B_RAS_N) *
 20 B_A15          45 GND
 21 B_D0           46 B_RW   (LR/W latched R/W)
 22 B_D1           47 NC  (NOT +5V on 800XL)
 23 B_D2           48 NC  (NOT +5V on 800XL)
 24 B_D3           49 AUDIO_PBI → Sheet 8 (analog)
 25 B_D4           50 GND
```
\* **/CAS, /RAS** are the daughterboard's DRAM strobes — *not present* in our
FPGA design (DDR is on the SoM). Leave pins 41/44 **NC** unless an expansion
device needs them; flag if any target PBI peripheral requires DRAM timing.

---

## Sheet 4 — RP2354B core

```
U_RP (RP2354B, QFN-80)
  IOVDD/DVDD_IO pins ─ +3V3 (+ 100nF each)
  USB_VDD ─ +3V3 (+100nF) ; ADC_AVDD ─ FB+RC from +3V3 (+1µF,100nF)
  VREG_VIN ─ +3V3 ; VREG_VOUT(DVDD core ~1.1V) ─ C(1µF)+100nF ─ GND
  QSPI ─ internal stacked flash (no external flash)
  XIN/XOUT ─ Y_RP(12MHz) + 2×15pF to GND
  RUN ─ SW_RUN→GND, +100nF→GND, 10k→+3V3
  GPIO?(BOOTSEL strap per RP2350 stacked-flash) ─ SW_BOOT→GND
  SWCLK/SWDIO ─ J_SWD (1×3 w/ GND)
  ; native USB (DEVICE)
  USB_DP ─ R(27)─ J_USBC.DP ;  USB_DM ─ R(27)─ J_USBC.DM
  J_USBC.VBUS ─ (optional 5V power-in path / detect)  ; J_USBC.CC1/CC2 ─ 5.1k→GND
```

---

## Sheet 5 — RP2354B I/O: joysticks, paddles, buttons

GPIO map (RP2350B: ADC = GPIO40–47):

| Function | RP GPIO | Net |
|---|---|---|
| Joy0 U/D/L/R | 0,1,2,3 | `R_J0_U/D/L/R` |
| Joy1 U/D/L/R | 4,5,6,7 | `R_J1_*` |
| Joy2 U/D/L/R | 8,9,10,11 | `R_J2_*` |
| Joy3 U/D/L/R | 12,13,14,15 | `R_J3_*` |
| Triggers J0..J3 | 16,17,18,19 | `R_TRIG0..3` |
| POT0..7 (ADC) | 40..47 | `R_POT0..7` |

```
; each direction/trigger: switch-to-GND with 3.3V pull-up + series R + ESD
R_J*_x : +3V3 ─ 10k ─ R_J*_x ─ Rs(220) ─ DB9 pin ; ESD array to GND at connector
; paddles: pot wiper → Rs(1k) → R_POTn → ADC ; 100nF R_POTn→GND ; clamp
```

### Joystick ports J_JOY1..4 (DE-9 female) — port *p* (1..4)
```
 1 R_J{p-1}_U      6 R_TRIG{p-1}
 2 R_J{p-1}_D      7 +3V3   (joystick/paddle supply)
 3 R_J{p-1}_L      8 GND
 4 R_J{p-1}_R      9 R_POT{2(p-1)}   (POT A / lower)
 5 R_POT{2(p-1)+1} (POT B / upper)
```
*(Per-port POT pair: pin 9 = POT0/2/4/6, pin 5 = POT1/3/5/7.)*

---

## Sheet 6 — SIO (CB3T translate + 13-pin connector)

RP SIO GPIO 20–27 (3.3 V) ↔ SIO connector (5 V) via `U_SIO (SN74CB3T3245)`.
Connector/footprint reference: **`atari-sio-breakout/`** v2.2 (CERN-OHL-2,
FujiNet connectors) — a pass-through SIO board built from the same individual
contact pins, with all 13 pins bussed side-to-side and a 2.54 mm right-angle
header tapping every line (the model for an optional on-board logic-analyzer
debug tap).

| SIO sig | Dir (vs computer) | RP GPIO | A (3V3) | B (5V) |
|---|---|---|---|---|
| DATA_OUT (pin5) | out | 20 | R_SIO_DOUT | B_SIO_DOUT |
| COMMAND_N (pin7) | out | 21 | R_SIO_CMD_N | B_SIO_CMD_N |
| MOTOR (pin8) | out | 22 | R_SIO_MOTOR | B_SIO_MOTOR |
| CLOCK_OUT (pin2) | out | 23 | R_SIO_CKO | B_SIO_CKO |
| DATA_IN (pin3) | in | 24 | R_SIO_DIN | B_SIO_DIN |
| PROCEED_N (pin9) | in | 25 | R_SIO_PROC_N | B_SIO_PROC_N |
| INTERRUPT_N (pin13) | in | 26 | R_SIO_INT_N | B_SIO_INT_N |
| CLOCK_IN (pin1) | in | 27 | R_SIO_CKI | B_SIO_CKI |

```
U_SIO (SN74CB3T3245) VCC=+3V3 GND=GND  OE_N=GND   ; transparent
  A1..A8 = R_SIO_*   B1..B8 = B_SIO_*
J_SIO (SIO receptacle, 13× AT60-202-2031 contact pins solder to PCB;
       footprint = receptacle pad layout from `atari-sio-breakout/` v2.2):
  1 B_SIO_CKI    2 B_SIO_CKO   3 B_SIO_DIN   4 GND
  5 B_SIO_DOUT   6 GND         7 B_SIO_CMD_N 8 B_SIO_MOTOR
  9 B_SIO_PROC_N 10 SIO_+5V    11 AUDIO_SIO→Sheet8  12 NC(+12V n/a)
  13 B_SIO_INT_N
; 5V-side pull-ups on open-drain control lines as needed (CMD/INT/PROC)
```

---

## Sheet 7 — USB host (PIO0 → 1:4 hub → 4 ports)

```
RP GPIO34 = R_USBH_DP, GPIO35 = R_USBH_DM   (Pico-PIO-USB)
R_USBH_DP ─ Rs(22) ─ HUB.UP_DP
R_USBH_DM ─ Rs(22) ─ HUB.UP_DM
U_HUB (CH334F / FE1.1s, no-program, per-port LS/FS)  VDD=+3V3(+reg caps)  XTAL=12MHz  GND=GND
  DP1..4/DM1..4 ─ Rs(22) ─ J_USB1..4 (USB-A) D+/D-
  J_USBn.VBUS ─ USBn_VBUS (Sheet1, polyfuse 0.5A)  ; VBUS 5V to downstream
  J_USBn.shield ─ chassis/GND (bead)
  per-port ESD array (TPD4E) on D+/D-/VBUS
```

---

## Sheet 8 — Audio-in (PCM1808)

```
U_ADC (PCM1808)  AVDD/DVDD=+3V3  AGND/DGND=GND
  SCKI ─ I2S_SCKI (FPGA-generated, MMCM/PLL; BCK=SCKI/4, LRCK=SCKI/256 - coherent)
  BCK  ─ I2S_BCK (FPGA)   LRCK ─ I2S_LRCK (FPGA)   DOUT ─ I2S_DOUT → FPGA
  MD0/MD1/FMT ─ strap per format (slave, I²S/left-justified) ⚑
  VREF caps per datasheet
  ; analog inputs (AC-coupled + anti-alias RC)
  VINL ← AUDIO_SIO (Sheet6 pin11) via Ccoupling+Raa
  VINR ← AUDIO_PBI (Sheet3 pin49) via Ccoupling+Raa
```

---

## Sheet 9 — Expansion / spare-pin breakout (3× 12-pin headers)

```
J_EXP1..3 (2×6 0.1" headers) — expose spare Bank-35 PL pins (no fixed protocol)
  each header: ~8-10 GPIO + GND + (+3V3 and/or +5V)
  where a pair may later be differential: route TMDS_33, length-matched, GND between
  ESD on exposed pins
  (which pins on which header = TBD)
```

---

## Sheet 10 — Reset / JTAG / LEDs

```
SW_RST ─ daughterboard PB_RESETn path (CN) ; + RC debounce
J_JTAG (2×7 0.05" Xilinx or 2×5 0.1") ← CN1 JTAG_TCK/TMS/TDI/TDO/NTRST + +3V3/GND
LED_PWR : +3V3 ─ R(1k) ─ LED ─ GND
LED_ACT : R_LED(RP GPIO33) ─ R(1k) ─ LED ─ GND
```

---

## Cross-sheet net summary (key)
- `+5V` Sheet1 → CN1/CN2, cart/SIO/USB VBUS, SIO CB3T B-side, buck-in.
- `+3V3` Sheet1 → CB3T Vcc (all), RP, hub, PCM1808, all pull-ups, joy pin7.
- `F_*` (Bank 35) ↔ CB3T A side ↔ `B_*` ↔ cart/PBI pins.
- `SPI_*`/`SPI_IRQ_N` (Bank 13) ↔ RP GPIO28–32.
- `I2S_*` (Bank 34) ↔ PCM1808.
- `R_*` RP GPIO ↔ joystick/paddle/SIO/USB.

## Open (schematic)
- CN1/CN2 physical pin numbers from sheet 15 → fill Sheet 2 + XDC.
- PBI /CAS//RAS (41/44): NC unless a target device needs DRAM timing.
- SPI CS: `SPI_CSN` shown (5 wires). If using 3-wire (CS tied), drop to 43-GPIO budget.
- Expansion 3×12 pinout (which spare Bank-35 pins).
