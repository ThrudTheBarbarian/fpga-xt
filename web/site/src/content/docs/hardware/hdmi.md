---
title: "HDMI output"
description: "RGB565 + sync to the on-SOM SiI9022A HDMI transmitter, and the 1080p60 pixel-clock bring-up."
---


The Z-Turn board carries an SiI9022A HDMI transmitter on the SOM,
driven by RGB565 + HSYNC/VSYNC/DE on the PL pins.  We never roll our
own TMDS serialiser — the SiI9022A handles TMDS encoding, the +5 V
on HDMI pin 18, hot-plug detect, DDC EDID, and CEC.

HDMI 1080p60 is up on the Z-Turn V2. Two bring-up gotchas worth recording: the pixel clock
must be synthesised from a **PS FCLK**, not the board reference — the SOM's crystal is 12 MHz,
which left every clock at quarter-speed and `clk_pix` out of HDMI range; and a bare-DVI output
won't sync, so the SiI9022A is put in **HDMI mode with an AVI InfoFrame** (VIC 16).

## Mandatory bring-up

  1. I²C init of the SiI9022A from the PS (CEC_A0..CEC_A2 strap, input
     clock select, TMDS PLL config).  Done once at boot before the
     first valid pixel arrives.
  2. PLL config (`pll_pix.sv`) hitting 148.5 MHz for 1080p60 output.
     This is the only pixel rate the SOM is wired for.
  3. The PL→SiI9022A bus carrying RGB565 + DE + HSYNC + VSYNC at
     148.5 MHz.  All driven by the plane compositor (`plane_fetch`
     → `plane_compositor`) from the line-buffer BRAM.

## Audio

POKEY's mixed stereo output rides out over the same HDMI connector.
The SiI9022A takes audio on its own pins, and the Z-Turn V2 wires four
of them to PL bank 34, each through a 0R link:

| SiI9022A | net             | link | ball |
|----------|-----------------|------|------|
| 38 MCLK  | `12MHZ`         | R116 | U15  |
| 45 SCK   | `I2S_SCLK`      | R107 | T17  |
| 44 WS    | `I2S_FSYNC_OUT` | R109 | R18  |
| 41 SD0   | `I2S_Dout`      | R108 | V17  |

The net names follow the PS's naming convention, but the pins are PL,
so the fabric owns them.  SD1–SD3 are unconnected and SPDIF is
grounded through R110, so those four carry all of HDMI audio.

**MCLK is ours to drive.**  The 12 MHz oscillator that sits on that net
reaches it only through a DNP resistor, so U15 is its sole driver.  The
chip needs it: in I2S mode it computes the CTS it sends the sink by
dividing MCLK by the ratio in TPI `0x20[6:4]`, and never measures WS.
Without MCLK there is no audio, however correct the data bits are.

One clock is therefore the root of all of it — 12.28448 MHz, from its
own MMCM:

    MCLK = 256 fs      SCK = MCLK / 4      WS = MCLK / 256

Every division is integer, so the ratio the chip is told is the ratio
it gets.  The absolute rate lands 0.03 % below nominal, which is
inaudible and beside the point: the sink locks to the measured CTS,
not to the sample rate named in the InfoFrame.

The wire is Philips I²S — 32-bit slots, 24 bits left-justified, WS low
= left, data changing on SCK's falling edge.  The PS configures the
transmitter's audio path over I²C and unmutes it last, since that write
is what starts the stream and arms the Audio InfoFrame.
