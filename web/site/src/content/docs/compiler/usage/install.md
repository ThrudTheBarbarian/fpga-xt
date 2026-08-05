---
title: Install
description: Where the toolchain goes, how xcc finds its own libraries, and how to run several versions side by side.
---

The toolchain installs into one versioned directory and finds everything else
relative to itself. Put `bin/` on your `PATH` and you are done — no environment
variable, no `-H`, no `-I` for the standard library.

```bash
make            # build
make install    # -> /opt/xcc/<version>
```

`make install` prints the directory to add to `PATH` when it finishes.

## Layout

On macOS and Linux the root is `/opt/xcc/$(VERSION)`:

```
/opt/xcc/0.3/
├── bin/                 xcc and everything it runs
│   ├── xcc              the driver — this is the one you invoke
│   ├── xcc-fe           front end (source → IR text)
│   ├── xcc-cg-<arch>    code generator, one per target
│   ├── xcc-ln-<fmt>     linker / executable writer
│   ├── xcc-as           6502 assembler
│   ├── xcc-sim-6502     6502 simulator
│   └── xcc-sim-68k      68000 simulator
├── lib/                 shared libraries
│   └── xc/              the support tree: standard library, layouts, runtime
│       ├── generic/lib/     architecture-neutral classes
│       ├── arm64/           arm64 libraries + host runtime
│       ├── xt6502/          6502 libraries, layouts, startup, asm runtime
│       └── arm9-sysroot/    (when present) libc.so etc. for -A arm9
└── …
```

Only `xcc` is meant to be invoked directly. Everything else in `bin/` is a stage
`xcc` spawns; they are on `PATH` because `xcc` finds them beside itself, not
because you should call them. (`xcc-sim-6502` and `xcc-sim-68k` are the
exceptions — you run those to execute what you just built.)

On **Windows** the default root is `C:\Program Files\xcc`, and because Windows
does not use a `bin`/`lib` split, the binaries sit directly in that directory
with the support tree in `C:\Program Files\xcc\xc`.

### Changing the root

`PREFIX` picks the root and the three subdirectories follow from it:

```bash
make install PREFIX=$HOME/opt/xcc-dev
make install PREFIX=/usr/local            # BINDIR=/usr/local/bin, XCDIR=/usr/local/lib/xc
```

`BINDIR`, `LIBDIR` and `XCDIR` can each be overridden individually if your
packaging needs a layout the default does not produce.

## How `xcc` finds its libraries

This is the part that makes the plain `xcc -o prog prog.xc` invocation work. On
startup `xcc` looks for a **support tree** — the directory holding `generic/`,
`arm64/`, `xt6502/` and friends — by probing each of these roots in turn for
`lib/xc`, then `xc`, then `support`:

1. `-H <path>`
2. `$XCC_HOME` (`$XTC_HOME` is still read, for older scripts)
3. **the directory holding the `xcc` binary, and its parent**
4. the current directory
5. `~/xcc`, `~/xtc`
6. `/opt/xcc/<version>`, `/opt/xcc`, `/usr/local/xcc`, `/usr/local/xtc`, `/opt/xtc`

Step 3 is the one that matters. An installed `/opt/xcc/0.3/bin/xcc` goes up one
level and finds `/opt/xcc/0.3/lib/xc`; a Windows `xcc.exe` finds `xc\` without
going up at all. Neither needs a flag or an environment variable, and two
installed versions never see each other's libraries.

Because the probe accepts `support/` as well as `lib/xc`, running `xcc` straight
out of a source checkout works too — it finds the repo's own `support/`
directory the same way.

If a build fails with *Cannot find include file*, `-V` prints the resolved
support root and every include path, which is almost always enough to see which
of the six roots won.

## Several versions at once

The version is in the path, so nothing special is required:

```bash
/opt/xcc/0.3/bin/xcc -o prog prog.xc      # explicit
PATH=/opt/xcc/0.4/bin:$PATH xcc -o prog prog.xc
```

Each binary resolves its own libraries relative to itself, so a 0.3 compiler
never picks up 0.4's standard library even when both are on `PATH`.

The one thing that *does* go wrong is a **stale copy earlier in `PATH`** — an old
binary in `~/bin` looks exactly like a live compiler bug, because it is a real
compiler, just not the one you built. `make uninstall-legacy` removes the copies
that pre-0.4 builds used to drop into `~/bin`, and `tools/check-install.sh`
reports which `xcc` a bare invocation actually resolves to.

## Cross-compiling

Nothing extra is installed per target: the code generators for all six live
targets are part of the same install, and the support tree carries each
target's libraries.

```bash
xcc -A win64  -o prog.exe prog.xc
xcc -A m68k   -o prog.tos prog.xc
xcc -A 6502   -o prog.xex prog.xc
```

The native targets assemble and link in-house, so no system assembler, linker or
SDK is involved.

`-A arm9` is the exception: it links against the XTOS loader's `libc.so`, which
lives in a separate repository. `make install` vendors it into
`lib/xc/arm9-sysroot/` when it can find it, and says so explicitly when it
cannot — in which case `-A arm9` needs `-L <path-to-sysroot>` until you install
it.

## Uninstalling

```bash
make uninstall                  # remove the installed version
make uninstall-legacy           # remove pre-0.4 copies from ~/bin
```
