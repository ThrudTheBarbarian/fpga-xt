#!/usr/bin/env python3
"""Dense Altirra sweep of BallBlazer's logo band.

Captures the band region every 34 frames (~0.57 s, the same cadence as the
board's graboverlay sweep in auth.bin) and records, per capture:
  * a HUE histogram (Atari palette index >> 4)
  * a SHAPE MASK, thresholded at the band's own median luma

The shape mask is the palette-independent part: mode-9 nibbles set LUMA and
COLBK sets HUE, so two machines showing the SAME content agree on shape even
if they disagree on hue.  That is what lets us scene-match BEFORE comparing
colour, instead of comparing two different frames and inventing a defect.
"""
import sys, os, glob, pickle

sys.path.insert(0, os.path.expanduser(
    '~/src/AltirraSDL/src/AltirraSDL/AltirraBridge/sdk/python'))
from altirra_bridge import AltirraBridge

RAW = '/tmp/alt_band_raw.bin'
OUT = 'altband.pkl'
LOG = open('altband.log', 'w', buffering=1)

# Altirra's logo band, from the earlier cross-machine alignment.
Y0, Y1, X0, X1 = 41, 101, 28, 311
W, H = 336, 224
STEP, NCAP = 34, 110


def main():
    tok = sorted(glob.glob(os.environ.get('TMPDIR', '/tmp').rstrip('/') +
                           '/altirra-bridge-*.token'), key=os.path.getmtime)[-1]
    with AltirraBridge.from_token_file(tok) as a:
        a._sock.settimeout(60)
        try:
            a.config('artifact', 'none')
        except Exception as e:
            LOG.write('artifact: %r\n' % (e,))
        pal = a.palette()
        # exact RGB -> palette index; the frame is post-palette but with
        # artifacting off every pixel is a palette entry.
        idx_of = {}
        for i in range(256):
            idx_of.setdefault((pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]), i)

        a.cold_reset()
        booted = -1
        for f in range(1200):
            a.frame(1)
            r = a.regs()
            v = r.get('PC')
            pc = int(str(v).lstrip('$'), 16) if v else -1
            if 0x3000 <= pc < 0x4000:
                booted = f
                break
        LOG.write('booted at frame %d\n' % booted)
        if booted < 0:
            LOG.write('NO BOOT\n')
            return

        caps = []
        for c in range(NCAP):
            for _ in range(STEP):
                a.frame(1)
            a.rawscreen(path=RAW)
            px = open(RAW, 'rb').read()
            hue = [0] * 16
            lum = []
            idxs = []
            for y in range(Y0, Y1 + 1):
                base = y * W * 4
                for x in range(X0, X1 + 1):
                    o = base + x * 4
                    i = idx_of.get((px[o + 2], px[o + 1], px[o]))
                    if i is None:          # nearest, should be rare
                        best, bd = 0, 1 << 30
                        r_, g_, b_ = px[o + 2], px[o + 1], px[o]
                        for k in range(256):
                            d = ((pal[k * 3] - r_) ** 2 +
                                 (pal[k * 3 + 1] - g_) ** 2 +
                                 (pal[k * 3 + 2] - b_) ** 2)
                            if d < bd:
                                best, bd = k, d
                        i = best
                    idxs.append(i)
                    hue[i >> 4] += 1
                    lum.append(i & 0x0F)
            med = sorted(lum)[len(lum) // 2]
            mask = bytearray((len(lum) + 7) // 8)
            for n, l in enumerate(lum):
                if l > med:
                    mask[n >> 3] |= 1 << (n & 7)
            frame_no = booted + (c + 1) * STEP
            caps.append({'cap': c, 'frame': frame_no,
                         'secs': frame_no / 59.92,
                         'hue': hue, 'median_luma': med,
                         'bright': sum(1 for l in lum if l > med),
                         'mask': bytes(mask)})
            if c % 10 == 0:
                top = sorted(range(16), key=lambda k: -hue[k])[:3]
                LOG.write('cap %3d frame %5d t=%5.1fs hues %s\n' %
                          (c, frame_no, frame_no / 59.92,
                           [(hex(k), hue[k]) for k in top if hue[k]]))
        pickle.dump({'caps': caps, 'band': (Y0, Y1, X0, X1)}, open(OUT, 'wb'))
        LOG.write('WROTE %s, %d captures\nDONE\n' % (OUT, len(caps)))


main()
