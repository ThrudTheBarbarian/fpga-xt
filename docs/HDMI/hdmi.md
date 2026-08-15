# HDMI output

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
     148.5 MHz.  All driven by `fb_scanout` from the line-buffer
     BRAM via the compositor / scanout pipeline.

## Audio

POKEY's mixed stereo output rides out over the same HDMI connector.
The SiI9022A takes audio on its own pins, and the Z-Turn V2 wires four
of them to PL bank 34, each through a 0R link (schematic sheet 10):

| SiI9022A | net             | link | ball |
|----------|-----------------|------|------|
| 38 MCLK  | `12MHZ`         | R116 | U15  |
| 45 SCK   | `I2S_SCLK`      | R107 | T17  |
| 44 WS    | `I2S_FSYNC_OUT` | R109 | R18  |
| 41 SD0   | `I2S_Dout`      | R108 | V17  |

The net names follow the PS's convention, but the pins are PL, so the
fabric owns them.  SD1–SD3 are unconnected and SPDIF is grounded
through R110, so those four carry all of HDMI audio.

**MCLK is ours to drive.**  The 12 MHz oscillator Y3 that sits on that
net reaches it only through R115, which is DNP, so U15 is its sole
driver and there is no contention.  The chip needs it: in I2S mode it
computes the CTS it sends the sink by dividing MCLK by the ratio in
TPI 0x20[6:4], and never measures WS.  Without MCLK there is no audio,
however correct the bits on SD0.

One clock is therefore the root of all of it — `u_mmcm3` in
`fpga_xt_top`, VCO 1425 MHz ÷ 116 = 12.28448 MHz:

    MCLK = 256 fs      SCK = MCLK / 4      WS = MCLK / 256

Every division is integer, so the ratio the chip is told is the ratio
it gets.  The absolute rate lands 0.03 % below nominal (fs = 47.986
kHz), which is inaudible and beside the point: the sink locks to the
measured CTS, not to the sample rate named in the InfoFrame.

`hdl/hdmi_i2s_out.sv` serialises the sample (Philips I²S, 32-bit slots,
24 bits left-justified, WS low = left) and `sii_enable_audio()` in
`loader/test/freertos/hdmi.c` configures and unmutes the transmitter.
`make -C sim hdmi_i2s` checks the wire against the I²S spec.
