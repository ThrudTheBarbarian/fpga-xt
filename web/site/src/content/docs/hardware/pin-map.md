---
title: "Pin map"
description: "IO assignment for the Z-Turn Z7-Lite SOM — RGB565 + sync to the HDMI transmitter, clocks, reset, and debug LEDs."
---


Pin assignments for the MYiR Z-Turn Z7-Lite SOM (Zynq-7020,
xc7z020clg400-2).  Authoritative source is
``vivado/constraints/zturn_board.xdc``;
this doc summarises the groupings + their routing rationale.

The Zynq has two distinct I/O domains:

- **MIO** (54 pins, PS side) — Ethernet, USB, UART, SD, QSPI flash,
  I²C / SPI / GPIO routed off the Processing System.  Configured in
  the block design (`vivado/bd/`), not constrained here.
- **PL I/O** — the FPGA fabric pins.  Z-Turn carrier breaks ~150 of
  these out via the baseboard, organised into LCD/HDMI, GPIO, and
  user-button banks.  All are 3.3 V LVCMOS in our build.

## RGB → SiI9022A

The SOM has an on-board SiI9022A HDMI transmitter driven by a
16-bit RGB565 parallel bus on the `LCD_DATA[15:0]` pins.  We map
that as RGB565 directly (no FPGA-side TMDS encoding — the SiI9022A
handles serialisation).

| Net      | Pin  | Bank | Notes                                  |
|----------|------|------|----------------------------------------|
| `rgb_r[4]` | Y19 | 34   | LCD_DATA[15]                           |
| `rgb_r[3]` | Y18 | 34   | LCD_DATA[14]                           |
| `rgb_r[2]` | W20 | 34   | LCD_DATA[13]                           |
| `rgb_r[1]` | V20 | 34   | LCD_DATA[12]                           |
| `rgb_r[0]` | U20 | 34   | LCD_DATA[11]                           |
| `rgb_g[5]` | T20 | 34   | LCD_DATA[10]                           |
| `rgb_g[4]` | P20 | 34   | LCD_DATA[9]                            |
| `rgb_g[3]` | N20 | 34   | LCD_DATA[8]                            |
| `rgb_g[2]` | P19 | 34   | LCD_DATA[7]                            |
| `rgb_g[1]` | N18 | 34   | LCD_DATA[6]                            |
| `rgb_g[0]` | U19 | 34   | LCD_DATA[5]                            |
| `rgb_b[4]` | U18 | 34   | LCD_DATA[4]                            |
| `rgb_b[3]` | W15 | 34   | LCD_DATA[3]                            |
| `rgb_b[2]` | V15 | 34   | LCD_DATA[2]                            |
| `rgb_b[1]` | U17 | 34   | LCD_DATA[1]                            |
| `rgb_b[0]` | T16 | 34   | LCD_DATA[0]                            |
| `rgb_hsync`  | W16 | 34 | LCD_HSYNC                              |
| `rgb_vsync`  | V16 | 34 | LCD_VSYNC                              |
| `rgb_de`     | R16 | 34 | LCD_DE                                 |
| `rgb_pixclk` | R17 | 34 | LCD_PCLK (148.5 MHz at 1080p60)        |

Internally the framebuffer / blitter / compositor operate on
RGBA-8888 (see memory: `internal_colour_format`); the scan-out
stage drops alpha and truncates RGB888 → RGB565 just before driving
these pins.

## HDMI control (I²C)

The SiI9022A is configured by the PS over I²C0.  These two pins
route the PS-side I²C bus through PL fabric pins to the SiI9022A's
DDC channel.

| Net        | Pin | Bank | Notes                                  |
|------------|-----|------|----------------------------------------|
| `hdmi_scl` | P16 | 34   | 4.7 kΩ pull-up to 3.3 V on baseboard   |
| `hdmi_sda` | P15 | 34   | 4.7 kΩ pull-up to 3.3 V on baseboard   |

## Clocks, reset, debug

| Net      | Pin | Bank | Notes                                          |
|----------|-----|------|------------------------------------------------|
| `clk_50` | U14 | 34   | 50 MHz on-board oscillator (PL clock input)    |
| `rst_n`  | R19 | 34   | User push-button SW[0], active-low             |
| `dbg[0]` | Y16 | 34   | LED0                                           |
| `dbg[1]` | Y17 | 34   | LED1                                           |
| `dbg[2]` | R14 | 34   | LED2                                           |

UART (`uart_tx` / `uart_rx`) is MIO-routed via the PS-side USB-UART
bridge; not assigned to PL pins in this build.

## Clocks (PLL outputs)

Derived from `clk_50` inside the PL:

- `clk_sally` (100 MHz) — SALLY 6502 core domain
- `clk_sys`   (150 MHz) — ANTIC + blitter + sally_mem main mem
- `clk_pix`   (148.4375 MHz) — `plane_compositor` → SiI9022A

## Reserved / unused

The Z-Turn baseboard exposes additional GPIO headers, audio codec
pins, FMC-LPC, and Pmod-style pin groups not currently used.  None
of these are constrained — Vivado leaves them floating, which is the
intended state for the PL-only build.

## I/O standard

Every PL net listed above uses `LVCMOS33`.  Bank 34 on the Z-Turn
SOM is wired to 3.3 V; no level-translation chips are present on the
PL signal path.
