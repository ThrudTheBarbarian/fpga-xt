#!/usr/bin/env python3
"""CONTROL: is the logo band's 'three hues on Altirra' just NTSC ARTIFACTING?

Captures the SAME frame twice -- artifacting off, then on -- and compares hue
histograms.  Mode 9 sets HUE from COLBK and LUMA from the nibble, so with DLIs
disabled the band can only be one hue unless COLBK is rewritten mid-frame.
If artifacting alone reproduces the recorded hueB/hue1/hueC split, the
'discrepancy' was in the measurement, not in either machine.
"""
import sys, os, glob

sys.path.insert(0, os.path.expanduser(
    '~/src/AltirraSDL/src/AltirraSDL/AltirraBridge/sdk/python'))
from altirra_bridge import AltirraBridge

Y0, Y1, X0, X1 = 41, 101, 28, 311
W = 336
LOG = open('artctl.log', 'w', buffering=1)


def hues(a, pal, tag):
    a.rawscreen(path='/tmp/art_%s.bin' % tag)
    px = open('/tmp/art_%s.bin' % tag, 'rb').read()
    idx_of = {}
    for i in range(256):
        idx_of.setdefault((pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2]), i)
    h = [0] * 16
    unmapped = 0
    for y in range(Y0, Y1 + 1):
        for x in range(X0, X1 + 1):
            o = (y * W + x) * 4
            i = idx_of.get((px[o + 2], px[o + 1], px[o]))
            if i is None:
                unmapped += 1
                best, bd = 0, 1 << 30
                r_, g_, b_ = px[o + 2], px[o + 1], px[o]
                for k in range(256):
                    d = ((pal[k * 3] - r_) ** 2 + (pal[k * 3 + 1] - g_) ** 2 +
                         (pal[k * 3 + 2] - b_) ** 2)
                    if d < bd:
                        best, bd = k, d
                i = best
            h[i >> 4] += 1
    tot = sum(h)
    top = sorted(range(16), key=lambda k: -h[k])[:4]
    LOG.write('%-22s unmapped=%-6d  %s\n' % (
        tag, unmapped,
        '  '.join('hue%X %5.1f%%' % (k, 100.0 * h[k] / tot)
                  for k in top if h[k])))
    return h


tok = sorted(glob.glob(os.environ.get('TMPDIR', '/tmp').rstrip('/') +
                       '/altirra-bridge-*.token'), key=os.path.getmtime)[-1]
with AltirraBridge.from_token_file(tok) as a:
    a._sock.settimeout(60)
    a.config('artifact', 'none')
    pal = a.palette()
    a.cold_reset()
    booted = -1
    for f in range(1200):
        a.frame(1)
        v = a.regs().get('PC')
        pc = int(str(v).lstrip('$'), 16) if v else -1
        if 0x3000 <= pc < 0x4000:
            booted = f
            break
    LOG.write('booted at frame %d\n' % booted)
    for _ in range(1400):                 # ~t=24s, mid-intro
        a.frame(1)
    LOG.write('--- same frame, two artifact settings ---\n')
    hues(a, pal, 'artifact=none')
    for mode in ('ntsc', 'ntschi', 'pal'):
        try:
            a.config('artifact', mode)
        except Exception as e:
            LOG.write('%-22s SET FAILED %r\n' % ('artifact=' + mode, e))
            continue
        a.frame(1)
        hues(a, pal, 'artifact=' + mode)
    a.config('artifact', 'none')
LOG.write('DONE\n')
