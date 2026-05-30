#!/usr/bin/env python3
"""
mkromhex.py — combine Atari XL OS ROM + BASIC into a 64 KB hex image for
BRAM $readmemh initialisation.

Usage:
    ./mkromhex.py atari-xl.rom atari-basic.rom [output.hex]

The output file contains 65536 hex bytes (one line per 16 bytes) that map
the full 64 KB SALLY address space.  Only the ROM regions are populated:

    Address    Content
    -------    -------
    $A000-BFFF  BASIC ROM (8 KB from atari-basic.rom)
    $C000-CFFF  OS ROM low  (4 KB = atari-xl.rom[0x0000..0x0FFF])
    $D000-D7FF  Hardware registers (zeros — ROM padding)
    $D800-FFFF  OS ROM high (10 KB = atari-xl.rom[0x1800..0x3FFF])

All other addresses are filled with 0x00 (will be overwritten at runtime).
"""

import sys

CHUNK = 16  # bytes per output line


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <xl-rom> <basic-rom> [output.hex]", file=sys.stderr)
        sys.exit(1)

    xl_path = sys.argv[1]
    basic_path = sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else "sally-boot.hex"

    # Read input ROMs
    with open(xl_path, "rb") as f:
        xl = f.read()
    with open(basic_path, "rb") as f:
        basic = f.read()

    if len(xl) != 16384:
        print(f"Warning: XL ROM is {len(xl)} bytes (expected 16384)", file=sys.stderr)
    if len(basic) != 8192:
        print(f"Warning: BASIC ROM is {len(basic)} bytes (expected 8192)", file=sys.stderr)

    # Build the 64 KB address space
    img = bytearray(65536)

    # BASIC at $A000-$BFFF (0xA000..0xBFFF)
    a000 = 0xA000
    for i, b in enumerate(basic):
        if a000 + i < 0xC000:
            img[a000 + i] = b

    # XL ROM split:
    #   [0x0000..0x0FFF] -> $C000-$CFFF (OS ROM low, 4 KB)
    c000 = 0xC000
    for i in range(min(0x1000, len(xl))):
        img[c000 + i] = xl[i]

    #   [0x1800..0x3FFF] -> $D800-$FFFF (OS ROM high, 10 KB)
    d800 = 0xD800
    src_start = 0x1800
    count = min(len(xl) - src_start, 0xFFFF - d800 + 1)
    for i in range(count):
        img[d800 + i] = xl[src_start + i]

    # Write output as Verilog $readmemh hex (one byte per token, 16/line)
    with open(out_path, "w") as f:
        for i in range(0, len(img), CHUNK):
            line = " ".join(f"{b:02x}" for b in img[i:i + CHUNK])
            f.write(line + "\n")

    print(f"Wrote {len(img)} bytes to {out_path}", file=sys.stderr)
    print(f"  BASIC @ $A000: {len(basic)} bytes", file=sys.stderr)
    print(f"  XL OS @ $C000: {min(0x1000, len(xl))} bytes", file=sys.stderr)
    print(f"  XL OS @ $D800: {count} bytes", file=sys.stderr)

    # XL self-test ROM: xl[0x1000..0x17FF] (2 KB) maps to $5000-$57FF when the
    # OS clears PORTB[7].  That's the address-map hole behind the $D000-$D7FF
    # I/O page, so it is NOT in the flat 64 KB image above — emit it as a
    # separate hex for sally_mem's SELFTEST_HEX_PATH.  The no-cart/no-disk XL
    # boot JMPs into it (Memo Pad / self-test); without it the OS cold-start
    # runs $00/BRK garbage and hangs in a stack-underflow runaway.
    import os
    st_path = os.path.join(os.path.dirname(out_path), "selftest.hex")
    selftest = xl[0x1000:0x1800]
    with open(st_path, "w") as f:
        for i in range(0, 2048, CHUNK):
            line = " ".join(f"{b:02x}" for b in selftest[i:i + CHUNK])
            f.write(line + "\n")
    print(f"  self-test ROM -> {st_path}: {len(selftest)} bytes", file=sys.stderr)


if __name__ == "__main__":
    main()
