#!/usr/bin/env python3
"""Mode-10 PRIORITY oracle.

Our RTL (hdl/gtia_stage.sv, commit 6ef5bab2) classes a mode-10 pixel for
PRIORITY by the nibble's BIT 2:

    gtia_nib[2] ? (PF0 + nib[1:0]) : SRC_BK

ACID's gtia_collision2 proves that rule for COLLISIONS.  Nothing proved it
for priority, because collisions are CPU-readable and colours are not.
This asks Altirra, which is the reference.

Setup: GTIA mode 10 + PRIOR scheme 2 (playfield ABOVE all four players),
a solid player 0 laid across a playfield of a single repeated nibble.

    nibble 1 -> bit 2 CLEAR.  We class it SRC_BK, so the PLAYER should win.
                Playfield would be drawn in COLPM1, the player in COLPM0.
    nibble 5 -> bit 2 SET.    We class it PF1, and scheme 2 puts playfield
                above players, so the PLAYFIELD (COLPF1) should win.

Discriminator is which colour appears on the scanline, AND WHERE: report
runs, not counts.  In mode 10 the BORDER is COLPM0 (not COLBK), so the
player's colour always appears at both screen edges in both cases -- a
count alone looks like "the player is partly visible" when it is not.

Launch the emulator first (no window, and note --headless is broken on
macOS: the SDL offscreen driver cannot init GL):

    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \\
        AltirraSDL --bridge=tcp:127.0.0.1:6503

The bridge is SINGLE-CLIENT, and RAWSCREEN inline=true hangs it, so this
uses the server-side path form.
"""
import sys, glob, collections

sys.path.insert(0, "/Users/simon/src/AltirraSDL/src/AltirraSDL/AltirraBridge/sdk/python")
from altirra_bridge import AltirraBridge

TOK = sorted(glob.glob("/var/folders/**/altirra-bridge-*.token", recursive=True),
             key=lambda p: p)
if not TOK:
    sys.exit("no token file")

# --- hardware registers ---------------------------------------------------
HPOSP0, SIZEP0, GRAFP0 = 0xD000, 0xD008, 0xD00D
COLPM0, COLPM1         = 0xD012, 0xD013
COLPF1, COLBK, PRIOR   = 0xD017, 0xD01A, 0xD01B
GRACTL, DMACTL         = 0xD01D, 0xD400
DLISTL                 = 0xD402
# --- OS shadows (VBLANK copies these over the hardware every frame) -------
SDMCTL, SDLSTL, GPRIOR = 0x022F, 0x0230, 0x026F
PCOLR0, PCOLR1, COLOR1, COLOR4 = 0x02C0, 0x02C1, 0x02C5, 0x02C8

C_PM0, C_PM1, C_PF1, C_BK = 0x3A, 0x8A, 0x28, 0x00
DL, SCR, NLINES = 0x3000, 0x4000, 100


def build_dl():
    dl = bytes([0x70, 0x70, 0x70])                      # 24 blank lines
    dl += bytes([0x4F, SCR & 0xFF, SCR >> 8])           # LMS, mode F
    dl += bytes([0x0F]) * (NLINES - 1)
    dl += bytes([0x41, DL & 0xFF, DL >> 8])             # JVB
    return dl


def rgb_of(pal, idx):
    if len(pal) >= 256 * 4:
        b = pal[idx * 4: idx * 4 + 4]
        return (b[2], b[1], b[0])          # BGRx on the wire
    b = pal[idx * 3: idx * 3 + 3]
    return (b[0], b[1], b[2])


def run(a, nib, pal):
    a.memload(SCR, bytes([(nib << 4) | nib]) * (NLINES * 40))
    a.memload(DL, build_dl())

    # shadows first, so the OS VBLANK re-asserts exactly what we want
    for addr, val in ((SDMCTL, 0x22), (GPRIOR, 0x94),
                      (PCOLR0, C_PM0), (PCOLR1, C_PM1),
                      (COLOR1, C_PF1), (COLOR4, C_BK)):
        a.poke(addr, val)
    a.poke(SDLSTL, DL & 0xFF); a.poke(SDLSTL + 1, DL >> 8)

    for addr, val in ((DMACTL, 0x22), (DLISTL, DL & 0xFF), (DLISTL + 1, DL >> 8),
                      (PRIOR, 0x94), (GRACTL, 0x00),
                      (COLPM0, C_PM0), (COLPM1, C_PM1),
                      (COLPF1, C_PF1), (COLBK, C_BK),
                      (HPOSP0, 0x70), (SIZEP0, 0x03), (GRAFP0, 0xFF)):
        a.hwpoke(addr, val)

    a.frame(4)
    # GRAFP0 is not DMA-fed here, but the OS VBLANK runs between frames;
    # re-assert the write-only P/M registers right before the capture.
    for addr, val in ((HPOSP0, 0x70), (SIZEP0, 0x03), (GRAFP0, 0xFF),
                      (PRIOR, 0x94)):
        a.hwpoke(addr, val)
    a.frame(1)

    # RAWSCREEN inline=true HANGS the bridge (logged as received, never
    # answered, reproduced twice).  Server-side capture works.
    f = a.rawscreen(path="/tmp/alt_raw.bin")
    w, h = f.width, f.height
    px = open("/tmp/alt_raw.bin", "rb").read()
    want = {"COLPM0(player)": rgb_of(pal, C_PM0), "COLPM1(pf nib1)": rgb_of(pal, C_PM1),
            "COLPF1(pf nib5)": rgb_of(pal, C_PF1), "COLBK": rgb_of(pal, C_BK)}

    def runs_of(y, target):
        out, start = [], None
        for x in range(w):
            o = (y * w + x) * 4
            c = (px[o + 2], px[o + 1], px[o])
            if c == target and start is None:
                start = x
            elif c != target and start is not None:
                out.append((start, x - 1)); start = None
        if start is not None:
            out.append((start, w - 1))
        return out

    best = None
    for y in range(h // 3, 2 * h // 3):
        row = collections.Counter()
        for x in range(w):
            o = (y * w + x) * 4
            row[(px[o + 2], px[o + 1], px[o])] += 1
        hits = {n: row.get(v, 0) for n, v in want.items()}
        if hits["COLPM0(player)"] or hits["COLPM1(pf nib1)"] or hits["COLPF1(pf nib5)"]:
            best = (y, hits, {n: runs_of(y, v) for n, v in want.items()})
            break
    return best, want


with AltirraBridge.from_token_file(TOK[-1]) as a:
    a._sock.settimeout(30)
    a.ping()
    try:
        a.config("artifact", "none")
    except Exception as e:
        print("artifact config:", e)
    a.cold_reset()
    a.frame(200)
    pal = a.palette()
    print("palette bytes:", len(pal))
    for name, idx in (("COLPM0", C_PM0), ("COLPM1", C_PM1), ("COLPF1", C_PF1)):
        print(f"  {name} ${idx:02X} -> {rgb_of(pal, idx)}")

    for nib, expect in ((1, "PLAYER wins (COLPM0) if bit2-clear => SRC_BK"),
                        (5, "PLAYFIELD wins (COLPF1) if bit2-set => PF1")):
        best, want = run(a, nib, pal)
        print(f"\n=== nibble {nib}: our RTL predicts {expect}")
        if not best:
            print("  NO candidate colour found on any sampled row")
            continue
        y, hits, runs = best
        print(f"  row {y}: " + ", ".join(f"{n}={c}" for n, c in hits.items()))
        for n, r in runs.items():
            if r:
                print(f"    {n:16s} runs {r}")
        print("    (playfield spans x=10..329; runs outside that are the "
              "mode-10 COLPM0 BORDER, not the player)")
