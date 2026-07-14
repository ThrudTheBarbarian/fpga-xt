---
title: Downloads
description: Prebuilt xtc toolchain binaries for macOS, Linux, and Windows.
---

Prebuilt binaries for **xtc 0.12**. Each archive contains the compiler driver (`xtc`), the standalone assembler (`xta`), the 6502 simulator (`xts`), and the `resources/support/` tree the compiler expects to find alongside the binaries (linker scripts, startup stubs, runtime asm, standard-library classes).

| Platform | Download | Size |
| --- | --- | --- |
| macOS (universal) | [xtc-osx-0.12.tar.bz2](/downloads/xtc-osx-0.12.tar.bz2) | 1.1 MB |
| Linux (x86_64) | [xtc-linux-0.12.tar.bz2](/downloads/xtc-linux-0.12.tar.bz2) | 16 MB |
| Windows (x64) | [xtc-win64-0.12.zip](/downloads/xtc-win64-0.12.zip) | 18 MB |

## macOS

```bash
tar xjf xtc-osx-0.12.tar.bz2
cd xtc-osx-0.12
./xtc --version
```

Add `xtc-osx-0.12/` to your `PATH`, or invoke the binaries by full path. The first run on a fresh macOS install may need a one-time Gatekeeper override (`xattr -dr com.apple.quarantine xtc-osx-0.12/`) since the binaries aren't notarised.

## Linux

```bash
tar xjf xtc-linux-0.12.tar.bz2
cd xtc-linux-0.12
./xtc --version
```

The Linux build is statically linked against GNUstep, so no system GNUstep install is required. Tested on x86_64; if you need ARM64 or another architecture, build from source.

## Windows

```powershell
Expand-Archive xtc-win64-0.12.zip -DestinationPath xtc
cd xtc
.\xtc.exe --version
```

The Windows build is statically linked against GNUstep, so no separate GNUstep installation is required.

## First build

Try a small program to confirm everything's wired up:

```c
// hello.xt
#use Stdio

void main(void) {
    Stdio.print("hello, atari\n");
}
```

```bash
xtc -O2 hello.xt -o hello.xex
```

```
xtc: optimised -O2 (... → ...)
xtc: compiled 'hello.xt' -> 'hello.xex' (0 warnings, 0 errors)
xta: assembled -> 'hello.xex' (... bytes, 1 segments)
```

Drop `hello.xex` into your favourite Atari emulator (Altirra, atari800, or run it under the bundled simulator with `xts hello.xex`) and you should see `hello, atari` print to the screen.

One thing to note is that xtc will attempt to read from its 'support' folder for things like Stdio.xt. It therefore needs to know where those files are, and you can tell it that in one of several ways (in order of priority)...

 - pass "-H path-to-support-dir" to xtc on the command line
 - set an environment variable of XTC_HOME to point to the support dir
 - have the 'support' directory in the same directory as the files you're compiling
 - place the 'support' directory into $HOME/xtc
 - place the 'support' directory into /usr/local/xtc
 - place the 'support' directory into /opt/xtc

You should find the support directory itself in the resources/ folder that came in the download along with xtc, xta and xts.

From here, [Compiler usage → CLI reference](/compiler/usage/cli/) covers the flags you'll reach for next; [Memory models](/compiler/usage/memory-models/) walks through the xt6502 memory map.
