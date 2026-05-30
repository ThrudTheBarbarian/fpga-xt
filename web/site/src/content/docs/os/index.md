---
title: Operating system
description: The software half of Atari-XT — FreeRTOS on the Cortex-A9 PS, Atari OS compatibility on the SALLY 6502, GEM/VDI via the blitter, and the multitasking design.
---

Atari-XT's software stack spans both halves of the Zynq. The dual Cortex-A9 **PS** runs
FreeRTOS and the modern services (USB HID, SD filesystem, GEM helpers); the **SALLY 6502** in
fabric runs the classic Atari OS and its software unchanged, with expanded RAM paged in through
bank-switched windows.

These pages cover the operating-system layer that bridges the two:

- **[Multitasking & executable loading](/os/multitasking/)** — one shared OS design across three
  target CPUs: dynamic ELF loading on the ARM, bank-switched processes on the 6502, and a future
  m68k soft core.
- **[Banked-stack context switching](/os/multitasking/6502/context-switch/)** — switching 6502 tasks in a handful
  of cycles by holding several 4 KB stacks resident in BRAM instead of copying to DDR3.
- **[VDI / blitter driver](/os/vdi-blitter/)** — how GEM VDI drawing calls map onto xt-blitter
  register writes, from either the PS or the SALLY side.
- **[Self-hosting roadmap](/os/self-hosting/)** — the plan to compile xtc with itself, hosted on
  the Zynq hardware.
