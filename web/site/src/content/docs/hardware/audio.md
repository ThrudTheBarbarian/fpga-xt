---
title: "Audio"
description: "POKEY four-channel audio in fabric, a PCM1808 stereo I²S input, and audio carried over the HDMI TMDS link."
---

Audio is part of the shared hardware. Output comes from **POKEY** — the Atari sound chip — running
in fabric with its four channels, and is carried to the display as audio islands over the HDMI TMDS
link (POKEY I²S → the on-SOM SiI9022A transmitter), so a single cable carries both picture and
sound.

Input comes from an on-board **PCM1808** stereo ADC over I²S, exposed on the carrier for line-in
and sampling.

Planned extensions — a second POKEY driving an RS-232 serial port, COVOX-style DMA-fed sample
playback, and post-mixer DSP — are tracked under **[Future work](/project/future-work/)**.
