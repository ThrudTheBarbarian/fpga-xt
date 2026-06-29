---
title: Operating system
description: The software half of Atari-XT — FreeRTOS on the Cortex-A9 PS, Atari OS compatibility on the SALLY 6502, GEM/VDI via the blitter, and the multitasking design.
---

Atari-XT's software stack spans both halves of the Zynq. The dual Cortex-A9 **PS** runs
FreeRTOS and the modern services (SD filesystem, GEM helpers, and USB-HID input via a companion MCU); the **SALLY 6502** in
fabric runs the classic Atari OS and its software unchanged, with expanded RAM paged in through
bank-switched windows.

These pages cover the operating-system layer that bridges the two:

- **[Runtime: loading & memory protection](/os/runtime/)** — how XTOS loads programs and protects
  them: the `xtld` ELF loader, per-process address spaces, copy-on-write, mmap'd executables and
  files, guard pages, W^X, and a real PL0 user/kernel boundary on the Cortex-A9.
- **[Multitasking & executable loading](/os/multitasking/)** — one shared OS design across three
  target CPUs: dynamic ELF loading on the ARM (implemented), bank-switched processes on the 6502,
  and an m68k target emulated on the spare A9.
- **[Banked-stack context switching](/os/multitasking/6502/context-switch/)** — switching 6502 tasks in a handful
  of cycles by holding several 4 KB stacks resident in BRAM instead of copying to DDR3.
- **[GEM — VDI, AES & theming](/os/gem/)** — the clean-room GEM environment: a true-colour
  scalable VDI, the AES object/window/menu layer, and the 9-slice theme engine. A call-level
  reference for each.
- **[VDI / blitter driver](/os/vdi-blitter/)** — how GEM VDI drawing calls map onto xt-blitter
  register writes, from either the PS or the SALLY side.
- **[Self-hosting roadmap](/os/self-hosting/)** — the plan to compile xtc with itself, hosted on
  the Zynq hardware.
