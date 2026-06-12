# fpga-xt motherboard — architecture

Status: **draft v0.3**

This is the **motherboard**. The **MyIR Z-Turn board mounts on it as a
daughterboard** (through CN1/CN2), bringing the Zynq-7020, DDR3, QSPI, SD,
GbE, USB-host, on-board **SiI9022A HDMI**, and its 5 V/3.3 V PMICs. The
motherboard turns that into an Atari-XT machine by exposing the legacy I/O:
cartridge slot, PBI, SIO, 4× joystick, audio-in, and a high-speed expansion
connector.

> Joysticks/paddles/SIO/buttons are read **directly by the RP2354B**; there
> is **no PCAL9722**. The RP↔FPGA path is a **single SPI link + IRQ** on PL
> Bank 13. (Legacy `joy_link.sv`/`joy_bridge.sv` PCAL9722 RTL is superseded
> — joystick/button state now rides the peri SPI link; §7.)

## 1. Platform

The Z-Turn daughterboard does all the modern-SoC heavy lifting, so the
motherboard does **no video** (HDMI is wholly on the daughterboard) and adds
no DDR/QSPI/PHY. The motherboard's scope is the Atari legacy I/O, the
3.3⇄5 V level translation, the RP2354B peripheral MCU, USB host expansion,
audio-in, power, and the connectors. The daughterboard mounts on standoffs
(102×63 mm, M3 holes on 96×57 mm); the two boards mate through CN1/CN2
(**Harwin M55, 2×40, 1.27 mm SMD**; 1.2 A/contact → parallel `VDD_5V`/`GND`).

## 2. Daughterboard ↔ motherboard interface (`refs/Z-TURNBOARD_schematic.pdf`, sheet 15)

Two 80-pin board-to-board connectors, **CN1** + **CN2** (each 2×40, "CON80"):

| Source | Conn | Signals | VCCIO | Motherboard use |
|---|---|---|---|---|
| **Bank 34** | CN1 | `LCD_DATA[15:0]`, H/V/DE/PCLK, `I2S_*`, `I2C0_*` | 3.3 V | reserved (on-board SiI9022A); **I²S group → PCM1808** |
| **Bank 13** | CN1 | `IO_B13_LP/LN11..16,21` | 3.3 V | **RP↔FPGA SPI link** (SCK/MOSI/MISO + IRQ) + spare |
| JTAG | CN1 | `TCK/TMS/TDI/TDO/NTRST` | 3.3 V | debug header |
| **Bank 35** | CN2 | `IO_B35_LP/LN0..24` (~50) | 3.3 V | **cart/PBI bus + expansion (TMDS_33)** |
| **PS MIO** | CN2 | `PS_MIO0..15` | 3.3 V | **unused** (no MIO this design) |
| **XADC** | CN2 | `XADC_INP0/INN0`,`TEMP_P/N` | analog | optional sense |
| Power | both | `VDD_5V`,`VDD_3.3V`,`VDDIO_13_PL`,`VDD18_KEY_BACKUP` | — | **5 V back-fed from barrel jack**; 3.3 V available |

**PL budget = 78 GPIO** = cart/PBI **39** (Bank 35) + expansion **39**
(Bank 35, TMDS_33). RP-link SPI (4) + PCM1808 I²S (3–4) on Bank 13 / Bank 34
audio group. **No PS MIO used.**

## 3. Block diagram

```
                       ┌────────────────────────────────────────────┐
                       │ Z-Turn DAUGHTERBOARD (XC7Z020-2)            │
                       │ PS+DDR3+SD+GbE · on-board SiI9022A → HDMI ──┼─▶ HDMI
                       └──┬──────────────────┬──────────────────┬────┘
                   CN1(Bank13 SPI,I²S,JTAG)  CN2 (Bank35 ×~50)   │ 5V/3.3V
   ┌──────────────────────┼──────────────────┼──────────────────┼───────────────────┐
   │ MOTHERBOARD           │                  │                  │                   │
   │            PCM1808◀─I²S│       ┌──────────┴────────┐  ┌──────┴──────┐            │
   │            (audio-in)  │       │  2× SN74CB3T16210 │  │ 39-pin EXP  │ TMDS_33    │
   │   ┌──────────────┐  SPI│       │  3.3⇄5V (39 bus)  │  │ (matched-len│ diff       │
   │   │  RP2354B     │◀───3+IRQ────┤                   │  │  pairs)     │            │
   │   │ joy16 btn4   │            ┌┴────────┐  ┌────────┴┐ └─────────────┘            │
   │   │ pot8(ADC)    │──DB9×4────▶│ CART    │  │  PBI    │  shared A0-15/D0-7/φ2/RW   │
   │   │ SIO8 ─CB3T─▶ │  SIO 13p   │ 30p edge│  │ 50p edge│  (5 V TTL)                │
   │   │ USB-dev(C)   │            └─────────┘  └─────────┘                           │
   │   │ USB-host PIO0│──D+/D-──▶ [1:4 USB HUB] ──▶ 4× USB-A (HID/gamepad/storage)    │
   │   │ LED1         │                                                              │
   │   └──────────────┘                                                              │
   │   POWER: 5V barrel jack ─┬─▶ 5V plane ─▶ Z-Turn (CN1/CN2), legacy +5V, USB VBUS  │
   │                          └─▶ buck ─▶ 3.3V (RP, hub, PCM1808, CB3T Vcc, pull-ups, │
   │                                            joy/paddle pin7 supply)               │
   │   Reset btn · JTAG hdr · power/activity LEDs                                      │
   └───────────────────────────────────────────────────────────────────────────────────┘
```

## 4. Subsystems

### 4.1 Cartridge + PBI 6502 bus — `2× SN74CB3T16210` (FPGA, 39 PL pins)
RTL outbound (`hdl/antic_top.sv`): `bus_addr_o[15:0]`, `bus_data_out[7:0]`+
`bus_data_oe` (→ bidir `D[7:0]` IOBUFs), `phi2_o`, `bus_rw_o`,
`bus_s4_n_o`, `bus_s5_n_o`, `bus_cctl_n_o`, **`bus_d1xx_n_o` → PBI /EXTSEL**,
**`bus_extenb_n_o` → PBI /EXTENB**; inbound `bus_mpd_n_in` (/MPD),
`bus_extirq_n_in` (/IRQ), `bus_rd4_in`, `bus_rd5_in`.

- The **shared** bus (`A0-15`, `D0-7`, `φ2`, `R/W`) is translated once and
  fanned to the **cartridge** edge (taps `A0-12`, `D0-7`, `/S4 /S5 /CCTL`,
  in `/RD4 /RD5`) and **PBI** (taps `A0-15`, `D0-7`, out `/EXTSEL /EXTENB
  /REF /RST`, in `/MPD /IRQ /RDY`).
- ~39 lines → **2× CB3T16210** (20-bit ea = 40 ch). Passive, *bidirectional,
  no DIR* — correct for a 6502 bus (single active driver by protocol).
  Vcc(3.3 V) clamp: 5 V in → ~3.3 V to FPGA; 3.3 V out → valid 5 V **TTL**
  high. Independent `1OE/2OE` per bank → isolate the **cart slot** (empty/
  hot-swap) from the **PBI**. **5 V-side bus pull-ups** (transparent switch
  floats when `D[]` tri-states). Exact pin↔connector map: see `03-schematic-sheets.md`.
- **Strict-800XL:** PBI has **no /HALT, no /CASINH, no +5 V** (pins 47/48 NC);
  cart `/RD4`(A)//RD5`(14) are **inputs** to the computer.

### 4.2 Joysticks / paddles / SIO / USB — `RP2354B` (43 of 48 GPIO)
RP2350B + 2 MB stacked flash, QFN-80, 48 GPIO, ≤8 ADC, 3 PIO. SPI **slave**
to the FPGA (`peri_link.sv`/`peri_bridge.sv`, ~5 MHz) on **Bank 13**.

| RP2354B function | GPIO | Notes |
|---|---:|---|
| SPI to FPGA (MISO/MOSI/SCK) | 3 | two-phase /CS framing |
| SPI IRQ | 1 | open-drain |
| USB **host** (PIO0 D+/D−) | 2 | Pico-PIO-USB + TinyUSB → **1:4 hub** |
| Paddles POT0-7 | 8 | 4 ports × 2, ADC, **3.3 V** ref |
| Joysticks (directions) | 16 | 4 × U/D/L/R, switch-to-GND |
| Buttons (triggers) | 4 | 1 fire/joystick |
| SIO | 8 | 4 out (DATA-OUT,CMD,MOTOR,CLK-OUT) + 4 in (DATA-IN,PROCEED,INT,CLK-IN) |
| LED | 1 | activity |
| **Total** | **43** | 5 spare |

- **USB:** RP native USB controller = **device-only** → **USB-C** for
  flashing/console (CDC). **Host** is the PIO0 pair via Pico-PIO-USB+TinyUSB
  → a **CH334F** (or FE1.1s) **1:4 USB hub** → 4× **USB-A** downstream (HID
  keyboard, gamepads, ATR storage). Hub is **strap-configured (no firmware/
  EEPROM)** and keeps **per-port LS/FS**; runs FS-upstream from the PIO host.
  Hub VBUS from the 5 V plane, per-port current limit.
- **Joysticks/triggers:** switch-to-GND, **3.3 V** pull-ups; series R + ESD
  clamp at each DB9 (external connector).
- **Paddles:** pot fed from **3.3 V** (DB9 pin 7) → RP ADC full-scale, **no
  divider**. Series R + clamp on each POT line.
- **SIO (5 V):** the 8 SIO lines cross via a **bidirectional CB3T switch**
  (e.g. 8-bit `SN74CB3T3245`) — same FET-switch family as the bus, no DIR
  pin. Audio-in (SIO pin 11) is analog → PCM1808, not the RP. SIO **+12 V is
  NC** on XL (pin 12); pin 10 = +5 V/Ready (~50 mA).

### 4.3 Expansion / spare-pin breakout (FPGA, ~39 PL pins)
Purpose is simply **not stranding spare Bank-35 PL pins** — no fixed protocol
yet. Likely **3× 12-pin (2×6) headers**. Everything stays 3.3 V; where a pair
might later carry differential, route it `TMDS_33` and length-matched.
Interleave GND, and bring +3V3/+5V to the headers.

### 4.4 Audio-in — `PCM1808` (FPGA I²S master, `pcm1808_rx.sv`)
`BCK` 3.072 MHz, `LRCK` 48 kHz, `DOUT`. **`SCKI` (256·fs = 12.288 MHz) is
FPGA-generated** (4th I²S wire, MMCM/PLL) and is the clock root — `BCK =
SCKI/4`, `LRCK = SCKI/256` integer-divided so the ADC's ratio is coherent by
construction. No local oscillator. (Jitter is a non-issue for legacy
SIO/cassette/cart audio capture.) Left = SIO/cassette audio, Right = cart/PBI
audio-in (cart has no audio pin; source = PBI pin 49 + cassette/SIO). I²S on
Bank 34 audio group.

### 4.5 Reset / JTAG / clocks
JTAG (CN1) → 2×7 debug header. Reset via the daughterboard `PB_RESETn` path
+ a motherboard button + power LED. No motherboard oscillator (daughterboard
provides clocks) except the optional PCM1808 SCKI source.

## 5. Pin budget
**FPGA PL (78):** cart/PBI **39** + expansion **39** (both Bank 35). RP-link
SPI (4) + PCM1808 I²S (3–4) on Bank 13 / Bank 34. **No MIO.**
**RP2354B (43/48):** §4.2.

## 6. Power

**Single 5 V barrel jack** powers everything; 5 V back-feeds the Z-Turn
through CN1/CN2 (`VDD_5V`). Local buck makes 3.3 V.

```
5V jack ─▶ [reverse/TVS + polyfuse] ─▶ 5V plane ─┬─▶ Z-Turn (CN1/CN2 VDD_5V)
                                                 ├─▶ legacy +5V: cart, SIO(pin10)  (polyfuse+TVS/port)
                                                 ├─▶ USB hub VBUS ×4 (per-port limit)
                                                 ├─▶ SIO 5V side of CB3T
                                                 └─▶ buck (TPS562201/AP63203, ~3A)
                                                       └▶ 3.3V: RP2354B, USB hub, PCM1808,
                                                                CB3T16210 Vcc, bus/joy pull-ups,
                                                                joy/paddle pin7 supply
```
*(PBI has no +5 V on 800XL — devices self-powered. Joystick pin 7 = 3.3 V.)*

### Power budget (5 V input) — estimate

| Load | Typ | Max |
|---|---:|---:|
| Z-Turn daughterboard (Zynq+DDR3+GbE+HDMI) | 1.0 A | 1.5 A |
| 4× USB-A downstream (bus-powered) | 0.4 A | 2.0 A |
| 3.3 V rail @5 V-in (RP+hub+PCM1808+pull-ups, ~85 %) | 0.2 A | 0.4 A |
| Cartridge +5 V | 0.15 A | 0.25 A |
| SIO +5 V (pin 10) | 0.05 A | 0.10 A |
| Joysticks/paddles (3.3 V, negligible @5 V) | 0.02 A | 0.05 A |
| **Total @ 5 V** | **~1.8 A (9 W)** | **~4.3 A (21 W)** |

→ Spec a **5 V / 5 A (25 W)** supply; barrel jack + input protection rated ≥5 A.

## 7. Open items (remaining)
1. **Expansion breakout** — finalize the 3× 12-pin header pinout (which spare Bank-35 pins; any TMDS_33 pairs).
2. **RTL/firmware** — retire `joy_link.sv`/`joy_bridge.sv` (PCAL9722); grow peri SPI register map with joystick/button fields; root the PCM1808 clocks on FPGA `SCKI` (`BCK=SCKI/4`, `LRCK=SCKI/256`). *(Not motherboard HW.)*

## 8. Deliverables
1. **Architecture + block diagram** — this doc.
2. **Part selection + BOM** — `02-bom.md`.
3. **Schematic sheets (netlist/ASCII)** — `03-schematic-sheets.md`.
4. **Carrier pin constraints (draft XDC)** — `04-carrier-pins.xdc` (balls TBD).
5. **Altium symbols** — `altium/build_fpga_xt_lib.pas`.
6. **Altium PBI edge-finger footprint** — `altium/build_fpga_xt_pcblib.pas`.
