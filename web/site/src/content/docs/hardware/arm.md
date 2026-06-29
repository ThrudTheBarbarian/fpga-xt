---
title: "ARM — Cortex-A9 PS"
description: "The dual Cortex-A9 processing system — the host that runs FreeRTOS, GEM, and the desktop, and bridges to the PL over AXI."
---

The Zynq-7020's **processing system (PS)** is a dual-core ARM Cortex-A9 (~867 MHz, 1 GB DDR3). It is
the substrate that ties Atari-XT together — not one of the named realms. ("XT" is
[X](/hardware/x/) + [T](/hardware/t/); the ARM is what makes them run, which is why the name isn't
"XTA".)

The PS hosts the modern half of the system:

- **FreeRTOS** and the modern services — the SD-card filesystem and the GEM AES / VDI
  helpers. USB-HID input arrives from a companion MCU, not an A9 USB stack.
- **The desktop and GEM**, drawing through the [`xt-blitter`](/hardware/blitter/) into the DDR3
  framebuffer.
- **User-provided binaries** — once FreeRTOS gains dynamic ELF loading (see
  [Multitasking & executable loading](/os/multitasking/)). It will also host the
  [T-realm m68k emulator](/hardware/t/).

It reaches the PL over AXI: **HP ports** carry bulk data (DDR3, the framebuffer, and blitter /
scan-out traffic) while **GP ports** carry control and register access (such as the AXI-Lite
blitter bridge). The software that runs here is documented under **[Operating system](/os/)**.
