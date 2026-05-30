#!/usr/bin/env python3
"""render_antic_fb.py — turn tb_boot's ANTIC render-tap dump into a PNG.

tb_boot.sv (`make boot` / `make boot_trace`) captures one composited frame from
ANTIC's render tap into /tmp/antic_fb.hex — ANTIC_W x ANTIC_H 8-bit Atari colour
values (hue[7:4]:luma[3:1]), the values the colour resolver hands to scan-out.
This maps each through the real hardware palette (hdl/palette/atari_ntsc.hex,
256 x RGB888 — the same LUT palette_lut loads) and writes a PNG so you can
actually see what ANTIC produced.

    tools/render_antic_fb.py [--fb F] [--pal F] [--out F] [-W N] [-H N] [-s N]

Defaults: --fb /tmp/antic_fb.hex  --pal hdl/palette/atari_ntsc.hex
          --out /tmp/antic_frame.png  -W 384 -H 192 -s 3
"""
import argparse, struct, zlib, sys, os


def load_hex(path):
    """Return the list of integers in a $writememh/$readmemh file (skip // comments)."""
    out = []
    with open(path) as f:
        for ln in f:
            ln = ln.split('//')[0].strip()
            if ln:
                out.append(int(ln, 16))
    return out


def write_png(path, rgb_rows, w, h):
    """rgb_rows: list of h bytearrays, each 3*w bytes (R,G,B...).  Writes RGB8 PNG."""
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    raw = bytearray()
    for row in rgb_rows:
        raw.append(0)            # filter type 0 (None)
        raw.extend(row)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))  # 8-bit RGB
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fb",  default="/tmp/antic_fb.hex")
    ap.add_argument("--pal", default=os.path.join(os.path.dirname(__file__),
                                                  "..", "hdl", "palette", "atari_ntsc.hex"))
    ap.add_argument("--out", default="/tmp/antic_frame.png")
    ap.add_argument("-W", type=int, default=384)
    ap.add_argument("-H", type=int, default=192)
    ap.add_argument("-s", "--scale", type=int, default=3)
    ap.add_argument("--panel", action="store_true",
                    help="emit the real 1920x1080 HDMI panel geometry: active playfield "
                         "x4, centred, COLBK border filling the overscan (cf. legacy_upscale.sv)")
    ap.add_argument("--border", type=lambda s: int(s, 16), default=0x00,
                    help="COLBK border colour byte (hex) used to crop+fill the panel (default 00)")
    a = ap.parse_args()

    fb  = load_hex(a.fb)
    pal = load_hex(a.pal)
    if len(fb) < a.W * a.H:
        sys.exit(f"fb has {len(fb)} px, need {a.W*a.H} ({a.W}x{a.H})")
    if len(pal) < 256:
        sys.exit(f"palette has {len(pal)} entries, need 256")

    def rgb(byte):
        v = pal[byte & 0xff]
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)

    if a.panel:
        # Real 1920x1080 HDMI geometry: integer x4 (legacy_upscale.sv), the active
        # playfield CENTRED with a COLBK border filling the overscan — like a real
        # Atari.  The render tap stores playfield content top/left-anchored in the
        # buffer with --border ($00 = COLBK here) padding, so we crop to the active
        # bbox and centre THAT (centring the raw buffer would keep it off-centre).
        PW, PH, sc, bg = 1920, 1080, 4, a.border
        xs = [x for y in range(a.H) for x in range(a.W) if fb[y * a.W + x] != bg]
        ys = [y for y in range(a.H) for x in range(a.W) if fb[y * a.W + x] != bg]
        if xs:
            x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        else:
            x0, x1, y0, y1 = 0, a.W - 1, 0, a.H - 1
        cw, ch = x1 - x0 + 1, y1 - y0 + 1
        sw, sh = cw * sc, ch * sc
        hoff, voff = (PW - sw) // 2, (PH - sh) // 2
        br, bgc, bb = rgb(bg)
        rows = [bytearray(bytes((br, bgc, bb)) * PW) for _ in range(PH)]
        for y in range(ch):
            seg = bytearray()
            for x in range(cw):
                r, g, b = rgb(fb[(y0 + y) * a.W + (x0 + x)])
                seg += bytes((r, g, b)) * sc
            for dy in range(sc):
                rows[voff + y * sc + dy][hoff * 3: hoff * 3 + sw * 3] = seg
        write_png(a.out, rows, PW, PH)
        out_w, out_h = PW, PH
        print(f"  panel: active bbox cols {x0}..{x1} rows {y0}..{y1} "
              f"({cw}x{ch}) -> x{sc} = {sw}x{sh} centred at ({hoff},{voff})")
    else:
        rows = []
        for y in range(a.H):
            line = bytearray()
            for x in range(a.W):
                r, g, b = rgb(fb[y * a.W + x])
                line += bytes((r, g, b)) * a.scale       # horizontal scale
            for _ in range(a.scale):                      # vertical scale
                rows.append(line)
        write_png(a.out, rows, a.W * a.scale, a.H * a.scale)
        out_w, out_h = a.W * a.scale, a.H * a.scale

    # quick on-screen summary
    from collections import Counter
    c = Counter(fb[:a.W * a.H])
    top = ", ".join(f"${v:02x}:{n}" for v, n in sorted(c.items(), key=lambda kv: -kv[1])[:6])
    print(f"wrote {a.out}  ({out_w}x{out_h}{', panel' if a.panel else ''})  colours: {top}")


if __name__ == "__main__":
    main()
