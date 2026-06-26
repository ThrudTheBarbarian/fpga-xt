# Zynq configuration parameters

A checklist of the Zynq settings the carrier design depends on, so nothing is
forgotten when the PS block design (MIO config) and the PL constraints (`.xdc`
pin pulls) are filled in. Pin assignments live in [pin-map](pin-map.md); this
file records the *intent* (pull direction, drive mode) per net.

## Pin pull-ups / pull-downs

### Set as Zynq INTERNAL pulls — in the PL `.xdc` (or PS MIO config)

These are FPGA-read signals that only need a defined level once the device is
configured. The weak internal pull is fine; a float during the ~100 ms config
window is harmless because the fabric isn't acting on them yet.

| Net                       | Pin            | Pull            | Reason |
|---------------------------|----------------|-----------------|--------|
| `EX_IRQ0`                 | IO_B34_LN11    | **PULLUP**      | card IRQ, active-low, idle high |
| `EX_IRQ1`                 | IO_B34_LP11    | **PULLUP**      | card IRQ, active-low |
| `EX_IRQ2`                 | IO_B34_LN8     | **PULLUP**      | card IRQ, active-low |
| `EX_IRQ3`                 | IO_B34_LP8     | **PULLUP**      | card IRQ, active-low |
| `EX_IRQ4`                 | IO_B34_LN6     | **PULLUP**      | card IRQ, active-low |
| `EX_READY`                | IO_B34_LN7     | **PULLUP**      | active-low, idle = deasserted |
| `EX_MODE`                 | IO_B34_LP7     | **PULL** (safe default) | defined slot mode at idle |
| `EX_UART_RX`              | IO_B34_LN5     | **PULLUP**      | UART idle = high |
| `FPGA_INTERRUPT`/`STM_SIRQ` | IO_B35_LP6   | **PULL** to deasserted | SPI IRQ from STM, no spurious assert |

### Provided EXTERNALLY on the carrier — do NOT also set an internal pull

Listed so the internal config doesn't duplicate (or fight) them.

| Net                  | External part (carrier)            | Reason |
|----------------------|------------------------------------|--------|
| `STM_BOOT0` (PS_MIO8)| 10 K pull-**down**                 | STM boots from flash → free-runs standalone |
| `STM_RST` (PS_MIO0)  | 10 K pull-**up** + 0.1 µF to GND   | STM free-runs; Zynq only resets it |
| `A8_*` card-driven inputs (`A8_IRQ`/`A8_MPD`/`A8_RDY`/`A8_HALT`) | pulled on the **5 V PBI** side — see PBI section | the 5 V pulls reach these 3.3 V pins via the CB3T; don't internal-pull |
| `FPGA_SLOT0`,`FPGA_SLOT1`,`FPGA_SLOT2` | 10 K pull-**up** → +3V3 | default the '138 select code to the unused output during config — see Expansion slots section |

### No pull

| Net(s) | Why |
|--------|-----|
| `I2S_DIN`/`SCLK`/`FSYNC_IN`/`FSYNC_OUT`/`DOUT`, `I2S_MCLK` (FPGA-gen, `IO_B35_LN4`) | point-to-point, always driven |
| `STM_SCLK`/`STM_MISO`/`STM_MOSI` | SPI, driven |
| `XADC_INP0`/`INN0`/`TEMP_P`/`VCC` | analog — tie unused inputs to GND per UG480, no digital pull |
| `LCD_*` / `HSYNC` / `VSYNC` / `LCD_DE` / `LCD_PCLK` | driven to the SiI9022A |
| `A8_*` outputs (addr, data, R/W, CLK, RAS/CAS/REF, EXTENB/EXTSEL/CARDSEL) | FPGA-driven; the 5 V-side pulls cover the config-float window |

## PBI connector (J1)

The 5 V parallel bus. All pulls sit on the **5 V side → +5 V** and reach the
3.3 V `A8_*` FPGA pins through the CB3T (so don't *also* internal-pull those).
**4.7 K throughout** (faster `/RDY` rise + matches the real Atari's ~3.3–4.7 K;
the bus is slow so the value is uncritical).

### Pull-UP → +5 V (4.7 K)

| Net(s) | Why |
|--------|-----|
| `5V_IRQ`, `5V_RDY`, `5V_MPD`, `5V_HALT` | card-driven, active-low / open-collector → idle high (essential; a floating `/IRQ` = spurious interrupts) |
| `5V_RST` | bidirectional reset; idle high (not-in-reset) |
| `5V_RAS`, `5V_CAS`, `5V_REF` | host outputs, **not implemented yet but wired** — pull-ups define the idle now and don't conflict once driven (future-proof) |
| `5V_EXTSEL`, `5V_EXTENB`, `5V_CARDSEL` | host-output active-low strobes; pull-ups keep them deasserted while the FPGA is unconfigured (config-float insurance) |

### No pull

- `5V_CLK`, `5V_R/W`, `5V_A0–A15` (host outputs), `5V_D0–D7` (bidir, driven each cycle)
- `PBI_AUDIO_IN` — analog → PCM1808, no digital pull

## Cartridge port (J7)

The cart shares `CLK` / `R/W` / `A0–A12` / `D0–D7` with the PBI (same 5 V nets)
— those are covered on the PBI sheet, not repeated. (`5V_CCTL` is cart-specific
and pulled below.) IC5's `1OE`/`2OE`
are tied low (always enabled), so a 5 V-side pull propagates through to the 3.3 V
FPGA pin (clamped to 3.3 V). One pull per net, don't double-pull.

### External (carrier, 5 V side)

| Net(s) | Pull | Reason |
|--------|------|--------|
| `5V_S4`, `5V_S5`, `5V_CCTL` | 4.7 K pull-**up** → +5 V | host→cart selects, active-low; cart acts on them → must idle deasserted through the config-float window |
| `5V_RD4`, `5V_RD5` | 10 K pull-**down** → GND | cartridge-presence sense — no cart = low, inserted cart drives high |

### No pull

- `5V_CLK`, `5V_R/W`, `5V_A0–A12` (host outputs), `5V_D0–D7` (bidir) — shared with PBI

> **SIO** signals also pass through IC5 (shared level-shifter); their pulls are
> in the SIO connector section below.

## SIO connector (U3) — physical Atari SIO port

The carrier is the SIO **host** (the STM32 drives the bus); real Atari
peripherals plug into U3. Host-output lines are driven; peripheral-output lines
float when nothing is connected and must be defined. Pulls go on the 5 V side
and propagate through IC5 to the 3.3 V host pins.

### External (carrier, 5 V side) — 4.7 K pull-up to +5 V

| Net (pin) | Reason |
|-----------|--------|
| `SIO_DIN_5V` (3, DATA IN)     | peripheral→host; idle = serial mark (high) |
| `SIO_PROCEED_5V` (9)          | peripheral→host, active-low (open-collector); idle deasserted |
| `SIO_IRQ_5V` (13, INTERRUPT)  | peripheral→host, active-low (open-collector); idle deasserted |
| `SIO_CLKIN_5V` (1, CLK IN)    | peripheral→host synchronous clock (rarely used); defined idle |

### No pull

- `SIO_CLKOUT_5V` (2), `SIO_DOUT_5V` (5), `SIO_CMD_5V` (7), `SIO_MOTOR_5V` (8) — host outputs, driven by the free-running STM
- `SIO_AUDIO_IN` (11) — analog → PCM1808 (AC-couple/bias on the audio sheet), no digital pull
- pins 12, 14 — n.c.

## Joystick / paddle ports (J3 ×4)

Atari DE-9 joysticks are passive — directions/trigger are switch closures to
GND, paddles are pots charging an RC network. Read by the joystick/paddle
consumer (the STM, per the joysticks-on-STM design).

### Direction + trigger — pull-UP to 3.3 V

`JLL_UP`, `JLL_DN`, `JLL_LT`, `JLL_RT`, `JLL_BTN` (×4 ports): switch-to-GND,
active-low. These go only to the STM, so use its **internal pull-ups**
(`GPIOx_PUPDR`, ~40 kΩ) — **no external parts** (saves 20 across the 4 ports).
The internal pull is to 3.3 V VDD, so the lines just swing 0 → 3.3 V (switch
only pulls low); 5 V tolerance isn't invoked here and no level shifter is
needed. External 10 K → 3V3 only if a firmer cable pull is ever wanted.

### Paddle POT lines — NO pull

`POT_A` (9) / `POT_B` (5) and their `JLL_POTA` / `JLL_POTB` lines: the **1 K
series (R1/R3) + 47 nF (C3/C6) is the paddle charge-time RC network** — the STM
discharges then times the charge through the paddle pot. A pull would corrupt
the measurement. **Read via STM timer input-capture (digital threshold), NOT the
ADC** — FT pins are 5 V-tolerant as digital inputs but not in analog mode, and
the POT line sits at up to +5 V.

### No pull

- `+V` (7, +5 V to the paddle pots), `SHELL` (10/11, chassis), `GND` (8)

## Expansion slots + 3:8 CS decoder (IC14, J14 ×5)

Five logically-identical slots; one SN74HC138 (always enabled: `G1`=3V3,
`/G2A`=`/G2B`=GND) decodes `FPGA_SLOT0..2` → `EX_CS0..4` (active-low, one at a
time). `Y5–Y7` are unused.

### External (carrier) — the config-window guard

| Net | Pull | Reason |
|-----|------|--------|
| `FPGA_SLOT0`, `FPGA_SLOT1`, `FPGA_SLOT2` | 10 K pull-**up** → +3V3 | the '138 is always enabled, so during FPGA config (select lines floating) it must not assert a real slot CS. Pull-ups default the code to `111` → the **unused `Y7`**, leaving `EX_CS0–4` all deasserted. Must be external (internal pulls are dead during config). The FPGA also drives `111` as its software "deselect all". |

This is how the "decoder default-disabled" requirement is met — no enable pin or
decoder rewiring; the unused `Y7` + select-line pull-ups do it.

### Defined idle (FPGA internal)

| Net | Pull | Reason |
|-----|------|--------|
| `EX_SPI0–7` (shared bidir byte-bus) | weak **PULLUP** (FPGA internal) or bus-keeper | defined idle for the tristate data bus when no card is selected |

### No pull / already handled

- `EX_CS0–4` — '138 push-pull outputs (all high on the unused code)
- `EX_IRQ3` / `EX_READY` / `EX_UART_RX` / `EX_MODE` — FPGA internal pulls (Zynq sheet)
- `A8_*` slot bus — pulled on the 5 V PBI side, via the CB3T
- `EX_UART_TX`, `EX_SPI_SCK` — FPGA-driven outputs; `+5V`, `GND`
- IC14 `VCC` — `C63` 0.1 µF decoupling ✓

## MIO drive configuration

| Net | MIO | Drive | Reason |
|-----|-----|-------|--------|
| `STM_RST` | PS_MIO0 | **OPEN-DRAIN** | assert-low-only; resets the STM without fighting the carrier NRST pull-up or the STM's own bidirectional NRST |

All other MIO default to push-pull.

## Clocking

- Source the PL MMCMs from **PS `FCLK_CLK1` = 50 MHz**, *not* the board's 12 MHz
  crystal (U14). The crystal route leaves every clock at quarter-speed and
  `clk_pix` out of HDMI range.
- Operating point: `clk_sally` **100 MHz**, `clk_sys` **133.3 MHz**,
  `clk_pix` **148.4375 MHz** (1080p60).

## I²C0 / SiI9022A / HDMI

- **I²C0 is the shared SOM I²C bus.** The SiI9022A (HDMI) and the other SOM I²C
  devices sit on it, and it is **already pulled up (4.7 K) on the SOM**. The
  front-panel OLED shares this same bus, so the **carrier fits NO I²C pull-ups**
  — a second pair would only parallel the SOM's down to ~2.35 K. OLED (0x3C/0x3D)
  and the SiI9022A are at different addresses, so they coexist fine.
  - A single small OLED on a ~5 cm lead is fine on the SOM's 4.7 K. If a 400 kHz
    bus ever looks marginal with the added cable capacitance, *parallel* a
    pull-up rather than relying on it alone — or just run the OLED at 100 kHz.
- At boot the PS must put the SiI9022A in **HDMI mode with an AVI InfoFrame
  (VIC 16)** — a bare-DVI output won't sync.

## Series termination (already on the schematic, not pulls)

- `A8_CLK` (R27), `EX_SPI_SCK` + `EX_SPI0–7` (R30–R38): **33 R** source
  termination. Correct as drawn.
