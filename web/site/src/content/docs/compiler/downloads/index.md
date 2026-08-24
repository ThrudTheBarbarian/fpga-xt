---
title: Downloads
description: Prebuilt xcc toolchain archives for macOS, Linux and Windows.
---

The current release line is **xcc 0.4**. One install is the whole toolchain: the
driver (`xcc`), the front end, seven code generators, xcc's own assemblers and
linkers, the simulators (`xcc-sim-6502`, `xcc-sim-68k`), and the complete standard
library — plus the vendored Linux (musl) and Windows (mingw) link pools, so a
single machine cross-builds native binaries for every target with **no other
toolchain installed**.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (Apple silicon) | [xcc-osx-0.4.tar.bz2](/downloads/xcc-osx-0.4.tar.bz2) | 8.9 MB |
| Linux (x86_64) | [xcc-linux-0.4.tar.bz2](/downloads/xcc-linux-0.4.tar.bz2) | 61 MB |
| Windows (x64) | [xcc-win64-0.4.zip](/downloads/xcc-win64-0.4.zip) | 71 MB |

Every archive is the same compiler: each host build cross-compiles to **all**
targets, so the platform you download for is only where the compiler runs, never
what it can produce.

## macOS

```bash
tar xjf xcc-osx-0.4.tar.bz2
export PATH="$PWD/xcc-osx-0.4/bin:$PATH"
xcc -v
```

The compiler finds its libraries **relative to its own binary** — no flags, no
environment variables, no fixed install path. Move the directory anywhere you
like. The first run on a fresh macOS install may need a one-time Gatekeeper
override (`xattr -dr com.apple.quarantine xcc-osx-0.4/`) since the binaries
aren't notarised.

One omission from every archive: the arm9 sysroot (it is large and
target-specific); `-A arm9` needs a `-L` pointing at one.

## Linux

```bash
tar xjf xcc-linux-0.4.tar.bz2
export PATH="$PWD/xcc-linux-0.4/bin:$PATH"
xcc -v
```

The binaries are static (musl), so they run on any x86_64 distribution with no
library dependencies at all.

## Windows

Unzip `xcc-win64-0.4.zip` anywhere and add the folder to `PATH` (or invoke
`xcc.exe` by path). The binaries are self-contained; no runtime installer is
needed.

## First build

```c
// hello.xc — no imports needed: Log is ambient on every target.
void main(void) {
    Log.info("hello from %s", "xcc");
}
```

```bash
xcc -o hello hello.xc      # native binary for this machine, like cc
./hello
```

The same file cross-compiles to every target by picking an architecture:

```bash
xcc -A x86_64 -o hello-linux hello.xc    # static Linux ELF (musl)
xcc -A win64  -o hello.exe    hello.xc   # Windows PE
xcc -A wasm32 -o hello        hello.xc   # hello.wasm + a Node/browser loader
xcc -A 6502   -o hello.xex    hello.xc   # banked Atari XEX (run: xcc-sim-6502 -m xt hello.xex)
```

From here, [Compiler usage → CLI reference](/compiler/usage/cli/) covers the flags
you'll reach for next, and [Install](/compiler/usage/install/) covers a system-wide
`make install`.

Older archives (including the pre-rename `xtc` 0.1x line) are on the
[Historical Releases](/compiler/downloads/historical/) page, and the
[ChangeLog](/compiler/downloads/changelog/) lists what changed per version.
