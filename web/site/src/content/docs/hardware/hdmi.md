---
title: "HDMI output"
description: "RGB565 + sync to the on-SOM SiI9022A HDMI transmitter, and the 1080p60 pixel-clock bring-up."
---


The Z-Turn board carries an SiI9022A HDMI transmitter on the SOM,
driven by RGB565 + HSYNC/VSYNC/DE on the PL pins.  We never roll our
own TMDS serialiser — the SiI9022A handles TMDS encoding, the +5 V
on HDMI pin 18, hot-plug detect, DDC EDID, and CEC.

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

The SiI9022A supports audio islands across the TMDS line, so the
POKEY I²S stream can ride out over the same HDMI connector when we
get there.  Strongly desired; not on the bring-up critical path.
