#!/usr/bin/env python3
"""altirra-wsync.py -- ask Altirra what cycle an instruction really runs at.

Altirra PASSES every ACID800 test, so where two of our tests disagree about one
machine cycle it is the arbiter.  This drives it over AltirraBridge: set a PC
breakpoint, boot a .xex, and read the cycle-accurate history around the stop.

Usage:
    python3 tools/altirra-wsync.py <name> <bp-hex> [lo-hex hi-hex]

    python3 tools/altirra-wsync.py gtia_pmresize 2347 2330 2360

Start the emulator first:
    cd <altirra>/build/macos-release/src/AltirraSDL/AltirraSDL.app/Contents/MacOS
    SDL_VIDEO_DRIVER=dummy ./AltirraSDL --headless --bridge > /tmp/altirra.log 2>&1 &
    grep token-file /tmp/altirra.log

TWO THINGS THAT WILL MISLEAD YOU:

  * The breakpoint must be set BEFORE `boot`, and the emulator paused when you
    set it.  These tests run in about 30 000 cycles -- under 20 ms -- so any
    "boot, sleep, then set it" ordering has already missed the whole test.

  * `cycle` is a free-running machine-cycle counter, so `cycle % 114` is the
    line position only up to an offset, and THE OFFSET CHANGES FROM BOOT TO
    BOOT.  Calibrate it inside the run you are reading.  The reliable anchor is
    a WSYNC halt: a halted instruction's post-fetch cycles resume at line 105,
    so for a 4-cycle instruction the NEXT instruction starts at line 108.
    `antic()` also reports beam_x in COLOUR CLOCKS (two per machine cycle),
    which is a good cross-check but lands within a cycle rather than on one.
"""
import glob
import sys
import time

SDK = "/Users/simon/src/AltirraSDL/src/AltirraSDL/AltirraBridge/sdk/python"
XEX = "/Users/simon/src/fpga-xt/rsrc/acid800/Acid800/standalone/%s.xex"

sys.path.insert(0, SDK)
from altirra_bridge import AltirraBridge          # noqa: E402


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    name, bp = sys.argv[1], int(sys.argv[2], 16)
    lo = int(sys.argv[3], 16) if len(sys.argv) > 3 else bp - 0x30
    hi = int(sys.argv[4], 16) if len(sys.argv) > 4 else bp + 0x10

    tok = glob.glob("/var/folders/**/altirra-bridge-*.token", recursive=True)
    tok += glob.glob("/tmp/altirra-bridge-*.token")
    if not tok:
        sys.exit("no bridge token -- is AltirraSDL running with --bridge?")

    a = AltirraBridge.from_token_file(sorted(tok)[-1])
    a.bp_clear_all()
    a.pause()
    a.bp_set(bp)
    a.boot(XEX % name)
    for _ in range(40):
        time.sleep(0.25)
        if int(a.regs().get("PC", "$0").lstrip("$"), 16) == bp:
            break
    else:
        sys.exit("breakpoint never hit -- wrong address, or the test skipped it")

    an = a.antic()
    print("stopped at $%04X  beam_x %s (colour clocks) beam_y %s"
          % (bp, an.get("beam_x"), an.get("beam_y")))
    try:
        a.history(4)                    # the first call after a stop errors
    except Exception:
        pass
    prev = None
    for e in a.history(200):
        pc = int(e["pc"].lstrip("$"), 16)
        if not lo <= pc <= hi:
            continue
        d = "" if prev is None else "  +%d" % (e["cycle"] - prev)
        prev = e["cycle"]
        print("pc $%04X  cyc %d  mod114 %3d  op %s%s"
              % (pc, e["cycle"], e["cycle"] % 114, e["op"], d))


if __name__ == "__main__":
    main()
