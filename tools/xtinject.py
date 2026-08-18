#!/usr/bin/env python3
"""Drive the board's pointer and keyboard over the input UDP lane (port 4242).

The same protocol gem/tools/xtmouse.c speaks, without needing an SDL window: an
8-byte packet whose buttons carry STATE, not edges.  It exists so a change to
the desktop's input handling can be VERIFIED rather than handed over untested --
right-click, in particular, was broken in four separate layers and each fix
looked plausible until someone actually clicked.

The pointer is DELTA-driven and the board clamps it to the screen, so absolute
positioning is "slam to a corner, then step out": `moveto` does that for you.

    python3 tools/xtinject.py moveto X Y
    python3 tools/xtinject.py click [left|right] [X Y]
    python3 tools/xtinject.py dclick [X Y]
    python3 tools/xtinject.py key <char>|<code>
    python3 tools/xtinject.py raw <buttons> <dx> <dy>

BOARD=<ip> overrides the default.  Every command leaves the buttons released.
"""
import os, socket, struct, sys, time

BOARD = os.environ.get("BOARD", "192.168.192.179")
PORT  = 4242
SCR_W, SCR_H = 1920, 1080

_s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)


def pkt(buttons=0, dx=0, dy=0, wheel=0):
    _s.sendto(struct.pack("<BBhhbB", ord('X'), buttons, dx, dy, wheel, 0), (BOARD, PORT))
    time.sleep(0.02)                     # the board coalesces; give it a frame


def key(code, shift=0):
    _s.sendto(struct.pack("<BBHBBBB", ord('K'), shift, code, 1, 0, 0, 0), (BOARD, PORT))
    time.sleep(0.05)


def moveto(x, y):
    """Absolute placement: the deltas are clamped at the edges, so drive hard to
    0,0 first and step out from there.  Deltas are s16, hence the chunking."""
    for _ in range(3):
        pkt(0, -32000, -32000)
    rx, ry = int(x), int(y)
    while rx or ry:
        sx = max(-30000, min(30000, rx)); sy = max(-30000, min(30000, ry))
        pkt(0, sx, sy)
        rx -= sx; ry -= sy


def click(button=1, x=None, y=None):
    if x is not None: moveto(x, y)
    pkt(button); pkt(button); pkt(0)     # down (repeat: state, so a lost one is harmless), up


def dclick(x=None, y=None):
    if x is not None: moveto(x, y)
    pkt(1); pkt(0); time.sleep(0.05); pkt(1); pkt(0)


def main():
    if len(sys.argv) < 2: print(__doc__); return 2
    cmd = sys.argv[1]
    if cmd == "moveto":
        moveto(int(sys.argv[2]), int(sys.argv[3]))
    elif cmd == "click":
        b = 2 if (len(sys.argv) > 2 and sys.argv[2] == "right") else 1
        rest = sys.argv[3:] if len(sys.argv) > 3 and not sys.argv[2].isdigit() else sys.argv[2:]
        if len(rest) >= 2: click(b, int(rest[0]), int(rest[1]))
        else:              click(b)
    elif cmd == "dclick":
        if len(sys.argv) >= 4: dclick(int(sys.argv[2]), int(sys.argv[3]))
        else:                  dclick()
    elif cmd == "key":
        a = sys.argv[2]
        key(int(a, 0) if a.startswith("0x") or a.isdigit() else ord(a))
    elif cmd == "raw":
        pkt(int(sys.argv[2], 0), int(sys.argv[3]), int(sys.argv[4]))
    else:
        print(__doc__); return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
