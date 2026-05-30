---
title: "T — Atari ST/TT (m68k)"
description: "The planned T realm — an m68k machine for Atari ST/STe/TT software, hosted by emulation on the Cortex-A9 PS."
---

:::note[Planned realm]
The T realm is **not built yet** — it's the "or at least it will be" half of Atari-XT. This page records the direction; nothing here is implemented.
:::

The **"T"** in Atari-XT is the Atari ST line, after the **sT** / **tT** machines. Where the
[X realm](/hardware/x/) is a fabric reproduction of the 6502 Atari, the T realm targets the
680x0-family Atari — the ST, STe, and TT — so the same box can run GEM/TOS-era software.

The current plan hosts the m68k by **emulation on the spare Cortex-A9** (a JIT translating m68k → ARM, reusing existing open-source ST emulation) rather than building a 680x0 soft core in fabric. Running a protected multitasking TOS variant (e.g. FreeMiNT) needs the MMU's memory protection, which the A9 provides directly. The multitasking and executable-loading design across
all three CPUs — ARM, 6502, and this m68k target — is sketched under
**[Multitasking & executable loading](/os/multitasking/)**.

Like the X realm, the T realm will share the underlying hardware: the
[display compositor](/hardware/video/), the [`xt-blitter`](/hardware/blitter/),
[audio](/hardware/audio/), DDR3, and the [ARM PS](/hardware/arm/) — appearing as another scalable window on the 1080p desktop when running in emulation mode, or just using the desktop natively as a GEM surface when running flat-out at max speed.
