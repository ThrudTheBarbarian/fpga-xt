---
title: Historical Releases
description: Older xtc toolchain binaries kept for archival reference.
---

These are the previously-released archives, kept here so an existing build can be reproduced byte-for-byte against the version it was originally compiled with. For new work, grab the [most recent release](/compiler/downloads/) — the [ChangeLog](/compiler/downloads/changelog/) lists what's changed since.

## xtc 0.11

Foundation-style class library (`Object`, `Number`, `String`, `Data`, `Array`, `Map`, `Set` plus `Comparable` / `Hashable` / `Enumerable` protocols), autoboxing, range-based `for-in`, array slicing, the `bank()` builtin and `raw:T@` pointer flavour, full cross-region cloaked-code support, and the `xt-shadow-heap-regC` layout.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (universal) | [xtc-osx-0.11.tar.bz2](/downloads/xtc-osx-0.11.tar.bz2) | 1.0 MB |
| Linux (x86_64) | [xtc-linux-0.11.tar.bz2](/downloads/xtc-linux-0.11.tar.bz2) | 16 MB |
| Windows (x64) | [xtc-win64-0.11.zip](/downloads/xtc-win64-0.11.zip) | 18 MB |

## xtc 0.1

The first public release.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (universal) | [xtc-osx-0.1.tar.bz2](/downloads/xtc-osx-0.1.tar.bz2) | 1.8 MB |
| Linux (x86_64) | [xtc-linux-0.1.tar.bz2](/downloads/xtc-linux-0.1.tar.bz2) | 16 MB |
| Windows (x64) | [xtc-win64-0.1.zip](/downloads/xtc-win64-0.1.zip) | 18 MB |

Each archive contains the compiler driver (`xtc`), the assembler (`xcc-as`), the simulator (`xcc-sim-6502`), and the matching `resources/support/` tree. Installation matches the procedure described on the current download page — substitute `0.1` for the version number in the unpack and `cd` commands.
