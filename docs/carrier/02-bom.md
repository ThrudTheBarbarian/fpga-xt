# fpga-xt motherboard — part selection + BOM

Status: **draft v0.2** · Pairs with [`01-architecture.md`](01-architecture.md)
In effect: Z-Turn daughterboard via CN1/CN2 · one **3.3 V** FPGA domain
(TMDS_33) · RP2354B owns joy/paddle/SIO + USB · **2× CB3T16210** on cart/PBI,
**CB3T on SIO** · RP native USB = device, **PIO0 host → 1:4 hub → 4 ports** ·
**5 V barrel-jack** power.

Mechanical: daughterboard **102 × 63 mm**, **4× M3** on **96 × 57 mm**.
Legend: **⚑ = confirm before order/layout.**

## 1. Core ICs

| Ref | Qty | Part | Pkg | Function | Notes |
|---|---:|---|---|---|---|
| U? | 2 | **SN74CB3T16210DGGR** | 48-TSSOP | 20-bit 3.3⇄5 V FET bus switch | cart/PBI bus; Vcc=3.3 V |
| U? | 1 | **SN74CB3T3245DBQR** | 24-QSOP | 8-bit 3.3⇄5 V FET bus switch | **SIO** 5 V translate (no DIR pin) |
| U? | 1 | **RP2354B** | QFN-80 | peri MCU + USB | 2 MB stacked flash, 48 GPIO, 8 ADC |
| U? | 1 | **PCM1808PWR** | TSSOP-14 | stereo I²S audio ADC | needs **SCKI** ⚑ (§5) |
| U? | 1 | **CH334F** (or FE1.1s) USB 2.0 1:4 hub | SOIC-16 | USB host expansion | **no EEPROM/firmware** (pin-strapped); **per-port LS/FS**; FS upstream from RP PIO0; 12 MHz xtal |

## 2. RP2354B + USB-host support

| Ref | Qty | Part | Pkg | Notes |
|---|---:|---|---|---|
| Y? | 1 | 12 MHz crystal | 3.2×2.5 | required for USB timing |
| Y? | 1 | hub crystal (12 or 24 MHz ⚑ per hub) | 3.2×2.5 | for the 1:4 hub IC |
| C? | 4 | crystal load caps (~15 pF ⚑) | 0402 | RP + hub |
| C? | 1 | 1 µF VREG/core | 0402 | per RP2350 HW guide ⚑ |
| C? | ~12 | 100 nF/supply pin | 0402 | RP + hub + ICs |
| C? | 3 | 4.7–10 µF bulk | 0603 | 3.3 V local |
| FB?| 1 | ferrite + RC | 0402 | ADC_AVDD filter (paddle accuracy) |
| SW?| 1 | BOOTSEL tactile | — | stacked-flash boot entry ⚑ |
| SW?| 1 | RUN/reset tactile (+100 nF) | — | |
| J? | 1 | SWD header (SWCLK/SWDIO/GND) | 1×3 | flash/debug |
| R? | 2 | 22–27 Ω series (PIO D+/D−) | 0402 | host port to hub |
| R? | a few | USB pull-ups/downs per hub datasheet | 0402 | |

## 3. Level-translation / protection

| Ref | Qty | Part | Function |
|---|---:|---|---|
| RN? | several | 10 kΩ arrays | cart/PBI **5 V-side bus pull-ups**; joystick/trigger 3.3 V pull-ups |
| R? | many | 100–330 Ω series | DB9 + SIO + paddle series (ESD/ringing) |
| D? | ~10 | TVS arrays (TPD4E1U06 / SP3004 / PESD) | DB9 (36), SIO, cart/PBI edge, USB ports |

> Joysticks/paddles need **no** level translator (3.3 V pull-ups + ADC).
> Only **SIO** and the **cart/PBI bus** cross 3.3↔5 V — both via CB3T.

## 4. Connectors

| Ref | Qty | Part | Function | Notes |
|---|---:|---|---|---|
| CN1/CN2 | 2 | **Harwin M55-7008042R** (male, 2×40, 1.27 mm, SMD) | mate to Z-Turn (female on SOM) | 1.2 A/contact → parallel VDD_5V/GND; pick stack 8/10.8/15.4 mm ⚑ |
| J_CART | 1 | **30-pos (2×15) 0.1″ B2B pin header** | Atari cartridge | strict 800XL pinout; standard header footprint |
| J_PBI | — | **50-pos (2×25) 0.1″ PCB edge fingers** | PBI (board-edge connector) | strict 800XL pinout (no +5 V/HALT); **custom edge footprint**, no mounted part |
| J_SIO | 1 | **SIO receptacle** — 13× **AT60-202-2031** contact pins | SIO | per `atari-sio-breakout/` v2.2 (FujiNet connectors); pins solder to PCB; footprint = receptacle pad layout from that design's Gerbers. SMD+THT pad for the 5 V-line cap. (Computer side = receptacle; **7-745288-2** plug pins are the cable-plug variant.) |
| J_JOY1-4 | 4 | **DE-9 female, R/A PCB** | joystick/paddle | pin 7 = 3.3 V |
| J_USB_DEV | 1 | **USB-C** | RP native USB (device) | flash/console + power-in option |
| J_USB1-4 | 4 | **USB-A** (host downstream) | from 1:4 hub | per-port VBUS limit |
| J_JTAG | 1 | 2×7 0.05″ (Xilinx) or 2×5 0.1″ | Zynq JTAG (from CN1) | |
| J_EXP1-3 | 3 | **2×6 (12-pin) headers** ⚑ | spare Bank-35 PL breakout | no fixed protocol; route as length-matched pairs where diff (TMDS_33) might be used; interleave GND |
| J_PWR | 1 | **5 V barrel jack** (≥5 A) | main power in | center-positive ⚑ |
| MTG | 4 | M3 standoff | mount daughterboard | 96×57 |

## 5. Power

| Ref | Qty | Part | Function | Notes |
|---|---:|---|---|---|
| D? | 1 | reverse-protect (Schottky/ideal-diode) + TVS | jack input | 5 V/≥5 A |
| F? | 1 | input polyfuse / eFuse | main 5 V | ~5 A |
| U? | 1 | **TPS562201 / AP63203** buck | 5 V → 3.3 V, ~2–3 A | RP, hub, PCM1808, CB3T Vcc, pull-ups |
| F? | ≥6 | polyfuse + TVS per port | cart, SIO, 4× USB VBUS | hot-plug limit |
| U? | 1 | quad load switch (opt) | USB VBUS per-port | or per-port polyfuse |
| C? | many | 0.1/10 µF decoupling | rails | |

*(PCM1808 SCKI is FPGA-generated — no oscillator part.)*

**Budget (5 V in):** ~**1.8 A typ / 4.3 A max** → spec **5 V / 5 A (25 W)**.
See `01-architecture.md` §6 table.

## 6. Open BOM items
1. **Expansion** — finalize the 3× 12-pin header pinout.

*(SIO uses the `atari-sio-breakout/` v2.2 receptacle — pull the 13 contact-pin pad positions (AT60-202-2031) from that design's Gerbers/layout for the footprint.)*

*(CN1/CN2 stack height (8/10.8/15.4 mm) is a layout-time pick once component clearance under the daughterboard is known.)*

## 7. Not on motherboard (on Z-Turn daughterboard)
HDMI (SiI9022A), GbE, microSD, DDR3, QSPI, PMICs, JTAG source, clocks — none duplicated.
