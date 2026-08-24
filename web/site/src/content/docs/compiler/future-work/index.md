---
title: Future work
description: What's planned, in progress, and known-incomplete in xcc.
---

xcc is pre-1.0. This page tracks where it's going, what's known-incomplete, and what's
recently landed — sourced from the project's `doc/Issues` log. Pre-1.0 software is more
useful when its rough edges are visible than when they're hidden.

## Where things stand

The compiler lowers to a single architecture-neutral IR and out through **seven live
backends** — xt6502, arm64 (macOS), arm9, m68k, x86_64 (Linux/musl), win64 and
**wasm32** — every one passing the full fixture corpus, and every one produced end to
end by the **in-house toolchain**: xcc's own assemblers, linkers and executable-format
writers, with no external compiler in the chain. A macOS machine with nothing but xcc
installed cross-builds native binaries for Linux, Windows and the browser out of the box —
the libc link pools ship inside the install.

The whole compiler also exists a **second time, written in xcc**, and every stage of it is
held byte-identical to the original by a set of twenty-four differential harnesses. That
"one language, one behaviour" claim is enforced to the byte on every commit, not asserted.

Application code is **platform-neutral by default**: `Url`, `Log` and `Platform` are
ambient on every target (each platform's prelude wires its own transports and loggers),
so the same directive-free source file compiles, links and *runs* on a Mac, a Linux
server, a browser and a banked 6502 — degrading honestly (a fetch with no transport
completes with status 0 and a logged warning) rather than failing to build.

## What's next: mobile

The next targets are **iOS/iPadOS and Android** — one language across desktop, server,
browser and phone. The plans are staged and deliberately similar in shape:

- **iOS is a platform variant of the shipped arm64/Mach-O target** — same ISA, object
  format and calling convention as macOS. The deltas are a platform stamp in the binary,
  the iOS SDK's stub libraries, a small native shell that owns the run loop and feeds
  events in, and packaging/signing scripts. The simulator makes the whole loop
  scriptable on a Mac.
- **Android pairs the arm64 code generator with the ELF writer** (both already shipped,
  never yet combined), links against Android's libc as a shared object, and rides
  **NativeActivity** — an app whose entire logic is native code behind a boilerplate
  manifest, the same mechanism QT and SDL use. No Java required.
- On both, **the app draws itself**: the Xtg toolkit renders into a GPU surface (Metal /
  GLES) hosted by the shell, so native widget-set bindings are a later option, never the
  gate. And on both, the acceptance test is the same file that already runs everywhere
  else, unchanged — the platform prelude is the seam, so `Log.info` goes to the console
  on a server, the browser console on the web, and the system log on a phone, with app
  source none the wiser.

## Accepted limitations

These are tradeoffs, not bugs — they won't be "fixed":

- **A bound method (`^`) widened in two *different* modules compares unequal.** Two `^`s
  widened in the *same* module are always equal — which is the case that matters, since a
  program registers and unregisters its own callbacks. Closing the exotic case would need
  a canonical trampoline address, which the loader cannot provide.
- **Floating point is IEEE-754 everywhere** — `float` is binary32 and `double` is
  binary64 on every target, with literals encoded at lex time — but xcc makes no promise
  that a *transcendental* (`sin`, `pow`, …) returns bit-identical results across
  targets: each platform's math library answers with its own final-bit rounding, exactly
  as C compilers behave across libms.

## Recently shipped

- **The ambient platform surface.** `Url` (an NSURL-style value with a cross-platform
  `fetch`), a `Logger` protocol behind the `Log` facade (tty-coloured console on hosted
  targets, browser console on wasm), and a `Platform` delegate seam — all available with
  zero imports in application code, wired per-target by each platform's prelude.
- **The wasm32 target.** `xcc -A wasm32 -o app app.xc` produces a `.wasm` plus a
  universal loader that runs under Node and in a browser unchanged — classes, ARC,
  protocols, blocks, 64-bit integers, IEEE floats, the lot — with the browser's
  fetch/DOM/console surface carried inside the generated loader.
- **Blocks.** Closures as first-class values with by-value snapshot captures, declared
  the way variables are declared (`block b u32(u16 x) = { … };`), storable in fields and
  registries, passable inline to methods — plus `block:` write-back captures for the
  accumulate-into-a-local pattern, with escape analysis making the unsound cases compile
  errors. See [Blocks](/compiler/language/blocks/).
- **UTF-8 strings, end to end.** `String` is UTF-8-native with byte *and* character
  interfaces, and 0.4 adds `\xNN`, `\uNNNN` and `\UNNNNNNNN` escapes with fixed digit
  counts (deliberately unlike C's greedy `\x`).
- **The toolchain-free cross matrix.** `make install` vendors the Linux (musl) and
  Windows (mingw) link pools into the install, so producing static Linux ELFs and
  Windows PEs from a Mac needs no external toolchain — and a missing pool is a clear
  error naming what's absent, never a silent fallback.
- **Export names are promises.** An `extern` definition exports under its *spelled* name
  even when overload resolution mangles the symbol internally, and two `extern`
  definitions of one name is a compile error — an export a host looks up by name can't
  quietly wear a mangled one.
- **A real Mach-O export trie.** The single-node writer that silently capped a dylib at
  255 exported symbols now builds the full prefix tree; a 400-symbol library round-trips
  with clients calling either side of the old cap.
- **Shared libraries and `#import <Lib>`** on arm9, arm64, x86_64 and win64 — a library
  carries its own interface *inside* the binary, so clients type-check against the real
  artifact rather than a header that may have drifted. Protocols compose across
  libraries built in complete ignorance of each other; `weak:` fields, bound methods and
  re-exported C types all cross the boundary.
- **`weak:` without a table.** Weak slots thread onto an intrusive list in the referent's
  own heap header — no capacity limit, O(1) stores, and destroying an object with no
  weak references costs one null test.
- **A differential fuzzer.** Generates random programs, compiles them through every
  backend, and treats any divergence between two targets as a bug. It found seven the
  corpus had missed.
- **Collections.** `Array`, `Map`, `Set`, `String`, `Data`, `Number` and `Sort`, plus the
  `Comparable` / `Hashable` / `Enumerable` protocols — one implementation shared by
  every backend.

## Known issues

None outstanding at the time of writing. Bug reports through [the feedback form](/feedback/)
feed straight into the canonical `doc/Issues` log.
