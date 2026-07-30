#!/usr/bin/env python3
#
# NOT VALID YET — DO NOT TRUST RESULTS FROM THIS HARNESS.
#
# It runs the test image with NO OS ROM.  The ACID framework installs handlers
# in the OS vectors (VDSLST, VVBLKI) and relies on the OS ROM's NMI dispatcher
# at $FFFA to read NMIST and jump through them.  The XEX does not cover $FFFA —
# antic_vcount's segments are $1A20-$1F30, $2000-$21F2, $02E0-$02E1 — so with
# no ROM that vector is RAM, reads as zero, and the first DLI or VBI kills the
# machine.  There is also no VBI, no SIO and no E: handler.
#
# A result out of this harness therefore means nothing, and it will still print
# a confident PASS or FAIL, which is worse than printing nothing.
#
# What it needs to be real: RAM + the XL OS ROM at $C000 (rsrc/atari-xl.rom) +
# PIA for PORTB banking (pia_regs.sv) + POKEY (pokey.sv) + the display chips,
# cold-booted, with the XEX injected afterwards the way loader/test/freertos/
# progs/xexload.c does it on the board.  Every piece is already in the repo.
#

"""acid2mem.py — turn an ACID800 standalone XEX into simulator memory.

Emits a 64K byte-per-line hex image plus a tiny config file, so an ACID test can
be run against the ANTIC rewrite in simulation instead of only on hardware.

The board runs these through xexload with a hardware breakpoint at the ACID
framework's _testEnd, then classifies the Y register: _testPassed leaves Y at
$00, _testFailed at $80.  This reproduces that arrangement for a testbench —
the breakpoint address comes out of the test's own .lab file rather than being
hardcoded, because it moves between builds.

Breaking at the ENTRY to _testEnd matters: the routine itself programs a POKEY
timer and spins on IRQST, so a harness with no POKEY hangs there.  The board's
sweep breaks at the entry for the same reason.

A small stub is planted at $0700 and the reset vector aimed at it: a bare 6502
comes up with no stack pointer, and on a real machine the OS would have set one
before the loader ever ran the test.

The framework prints its progress through IOCB 0's put-byte vector, which it
copies out of the OS's IOCB table at $0346 and increments -- the OS stores those
as address-minus-one for its RTS dispatch.  With no OS underneath, that vector is
zero and the first character printed jumps to $0001.  A null sink is installed
at $0346 in the same minus-one form, which is exactly what the OS would have put
there.  That loses only the printed text, which the result does not depend on:
the board's own sweep reads the Y register at _testEnd and discards the printing
too.

    usage: acid2mem.py <name> [outdir]
"""
import sys, struct, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
STANDALONE = ROOT / "rsrc/acid800/Acid800/standalone"
SYMBOLS = ROOT / "rsrc/acid800/Acid800/symbols"
STUB = 0x0700
ICPTL = 0x0346                      # IOCB 0 put-byte vector, in the OS's table


def load_xex(path):
    """Return (memory dict, run address)."""
    d = path.read_bytes()
    mem, run = {}, None
    i = 2 if d[0:2] == b"\xff\xff" else 0
    while i + 4 <= len(d):
        if d[i:i + 2] == b"\xff\xff":
            i += 2
            continue
        lo, hi = struct.unpack("<HH", d[i:i + 4])
        i += 4
        if hi < lo:
            break
        n = hi - lo + 1
        seg = d[i:i + n]
        i += n
        for k, b in enumerate(seg):
            mem[lo + k] = b
        # $02E0/$02E1 is the RUN vector: a segment landing there names the entry.
        if lo <= 0x02E0 <= hi and lo <= 0x02E1 <= hi:
            run = mem[0x02E0] | (mem[0x02E1] << 8)
    return mem, run


def symbols(name):
    """_testEnd and friends, from the test's own .lab."""
    out = {}
    # The standalone build's own .lab first: symbols/ is a different build and
    # its _testEnd is at a different address, which silently breakpoints on
    # nothing.
    for cand in (STANDALONE / f"{name}.lab", SYMBOLS / f"{name}.lab"):
        if not cand.exists():
            continue
        if out:
            break
        for line in cand.read_text(errors="ignore").splitlines():
            parts = line.split()
            if len(parts) >= 3 and len(parts[1]) == 4:
                try:
                    out.setdefault(parts[2], int(parts[1], 16))
                except ValueError:
                    pass
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    name = sys.argv[1]
    outdir = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "sim"

    xex = STANDALONE / f"{name}.xex"
    if not xex.exists():
        sys.exit(f"no such test: {xex}")

    mem, run = load_xex(xex)
    if run is None:
        sys.exit(f"{name}: no RUN address in the XEX")

    syms = symbols(name)
    end = syms.get("_testEnd")
    if end is None:
        sys.exit(f"{name}: no _testEnd in the .lab")

    # A bare 6502 has no stack pointer; on hardware the OS set one long before
    # the loader ran.  Plant the equivalent and aim the reset vector at it.
    stub = [0xA2, 0xFF,             # LDX #$FF
            0x9A,                   # TXS
            0xD8,                   # CLD
            0x78,                   # SEI
            0x4C, run & 0xFF, run >> 8]
    for k, b in enumerate(stub):
        mem[STUB + k] = b
    mem[0xFFFC] = STUB & 0xFF
    mem[0xFFFD] = STUB >> 8

    # A null character sink, installed where the OS would have left it.  The
    # framework does `mwa icptl _vputchar` then `inw _vputchar`, so the table
    # entry is the target minus one.
    sink = STUB + len(stub)
    mem[sink] = 0x60                # RTS
    mem[ICPTL]     = (sink - 1) & 0xFF
    mem[ICPTL + 1] = (sink - 1) >> 8

    outdir.mkdir(parents=True, exist_ok=True)
    with open(outdir / "acid.mem", "w") as f:
        for a in range(0x10000):
            f.write(f"{mem.get(a, 0):02x}\n")
    with open(outdir / "acid_cfg.mem", "w") as f:
        f.write(f"{end:04x}\n")

    print(f"{name}: run=${run:04X} _testEnd=${end:04X} bytes={len(mem)}")


if __name__ == "__main__":
    main()
