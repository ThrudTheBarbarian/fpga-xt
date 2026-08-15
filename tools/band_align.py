#!/usr/bin/env python3
"""Is the band's low IoU a CONTENT difference, or just MISREGISTRATION?

The two band rectangles came from notes.  A logo is high-frequency content, so
a few pixels of offset destroys IoU between two IDENTICAL images.  Scan the
relative shift and take the best overlap-normalised IoU.  If some (dx,dy)
jumps to >90%, the bands are the same picture and the rectangles were simply
misaligned; if the surface stays flat near 45%, the content really differs.
"""
import pickle

GRAB, W, H = 184374, 320, 192
BY0, BX0, BX1 = 25, 20, 303
ROWS, COLS = 60, 284
PAD = 16                      # how far the board window may roam

pal = []
for ln in open('/Users/simon/src/fpga-xt/hdl/palette/atari_ntsc.hex'):
    ln = ln.strip()
    if not ln or ln.startswith('//'):
        continue
    v = int(ln, 16)
    pal.append(((v >> 16) & 255, (v >> 8) & 255, v & 255))
idx_of = {}
for i, c in enumerate(pal):
    idx_of.setdefault(c, i)

d = pickle.load(open('altband.pkl', 'rb'))
AY0, AY1, AX0, AX1 = d['band']
ACOLS = AX1 - AX0 + 1
cap = d['caps'][40]                       # mid-intro, band is static anyway
am = cap['mask']
alt = [[(am[(r * ACOLS + c) >> 3] >> ((r * ACOLS + c) & 7)) & 1
        for c in range(ACOLS)] for r in range(AY1 - AY0 + 1)]

blob = open('auth.bin', 'rb').read()
g = 40
off = g * GRAB + 54

# Board luma over a PADDED window so the shift search has room.
lum = {}
for y in range(BY0 - PAD, BY0 + ROWS + PAD):
    row = off + (H - 1 - y) * W * 3
    for x in range(BX0 - PAD, BX1 + 1 + PAD):
        o = row + x * 3
        c = (blob[o + 2], blob[o + 1], blob[o])
        i = idx_of.get(c)
        if i is None:
            best, bd = 0, 1 << 30
            for k, (pr, pg, pb) in enumerate(pal):
                dd = (pr - c[0]) ** 2 + (pg - c[1]) ** 2 + (pb - c[2]) ** 2
                if dd < bd:
                    best, bd = k, dd
            i = best
        lum[(y, x)] = i & 0x0F

print('scanning shifts +/-%d ...' % PAD)
results = []
for dy in range(-PAD, PAD + 1):
    for dx in range(-PAD, PAD + 1):
        vals = [lum[(BY0 + r + dy, BX0 + c + dx)]
                for r in range(ROWS) for c in range(COLS)]
        med = sorted(vals)[len(vals) // 2]
        inter = union = 0
        n = 0
        for r in range(ROWS):
            arow = alt[r]
            for c in range(COLS):
                b = 1 if vals[n] > med else 0
                n += 1
                a = arow[c]
                if a or b:
                    union += 1
                    if a and b:
                        inter += 1
        results.append((inter / union if union else 0.0, dx, dy))

results.sort(reverse=True)
print('\n best IoU   dx   dy')
for iou, dx, dy in results[:10]:
    print('  %6.1f%%  %+3d  %+3d' % (100 * iou, dx, dy))
print('\n at (0,0): %.1f%%' % (100 * next(
    r for r, dx, dy in results if dx == 0 and dy == 0)))
worst = results[-1][0]
print(' worst over the whole scan: %.1f%%' % (100 * worst))
print('\nA sharp peak >90%% => same picture, misregistered.')
print('A flat surface near 45%% => the content genuinely differs.')
