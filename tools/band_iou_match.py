#!/usr/bin/env python3
"""Scene-match the board's logo band against Altirra's, by SHAPE.

Shape is the palette-independent part: mode-9 nibbles set LUMA and COLBK sets
HUE, so two machines showing the same content agree on shape even if the hue
decode differs.  The recorded IoU of 44.7% was measured at equal ELAPSED time;
if the two are simply offset in the sequence, the best match for each board
grab sits at some consistent Altirra frame instead, and the IoU there is high.

board grabs : auth.bin, 96 x 184374 B, 320x192 24-bit BMP, rows BOTTOM-UP, BGR
altirra     : altband.pkl from tools/altirra_band_sweep.py
band        : board y=25..84 x=20..303 ; altirra y=41..100 x=28..311  (284x60)
"""
import pickle, sys

GRAB, W, H = 184374, 320, 192
BY0, BX0, BX1 = 25, 20, 303
ROWS, COLS = 60, 284

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
acaps = d['caps']
AY0, AY1, AX0, AX1 = d['band']
ACOLS = AX1 - AX0 + 1


def alt_mask_int(cap):
    """Slice the stored 61-row mask down to the board's 60 rows."""
    m = cap['mask']
    bits = 0
    for n in range(ROWS * ACOLS):
        if m[n >> 3] >> (n & 7) & 1:
            bits |= 1 << n
    return bits


blob = open('auth.bin', 'rb').read()
ngrab = len(blob) // GRAB
print('board grabs: %d   altirra caps: %d' % (ngrab, len(acaps)))

unmapped_total = 0
bmasks = []
for g in range(ngrab):
    off = g * GRAB + 54                      # skip the 54-byte BMP header
    lum = []
    for r in range(ROWS):
        y = BY0 + r
        row = off + (H - 1 - y) * W * 3      # BOTTOM-UP
        for x in range(BX0, BX1 + 1):
            o = row + x * 3
            c = (blob[o + 2], blob[o + 1], blob[o])   # BGR -> RGB
            i = idx_of.get(c)
            if i is None:
                unmapped_total += 1
                best, bd = 0, 1 << 30
                for k, (pr, pg, pb) in enumerate(pal):
                    dd = (pr - c[0]) ** 2 + (pg - c[1]) ** 2 + (pb - c[2]) ** 2
                    if dd < bd:
                        best, bd = k, dd
                i = best
            lum.append(i & 0x0F)
    med = sorted(lum)[len(lum) // 2]
    bits = 0
    for n, l in enumerate(lum):
        if l > med:
            bits |= 1 << n
    bmasks.append((bits, sum(1 for l in lum if l > med), med))

print('board unmapped pixels: %d  (0 means the palette decode is exact)'
      % unmapped_total)

amasks = [(alt_mask_int(c), c) for c in acaps]

print('\n grab  bright   best-alt   t_alt    IoU   | IoU at equal t')
print(' ----  ------   --------   -----   -----  | --------------')
offsets, best_ious = [], []
for g, (bm, br, med) in enumerate(bmasks):
    t_board = g * 0.57
    best = (-1.0, None)
    for am, cap in amasks:
        inter = (bm & am).bit_count()
        union = (bm | am).bit_count()
        iou = inter / union if union else 0.0
        if iou > best[0]:
            best = (iou, cap)
    # what the naive equal-elapsed-time comparison would have given
    same_t = min(acaps, key=lambda c: abs(c['secs'] - t_board))
    am_t = alt_mask_int(same_t)
    it = (bm & am_t).bit_count()
    ut = (bm | am_t).bit_count()
    iou_t = it / ut if ut else 0.0
    if g % 8 == 0 or best[0] > 0.9:
        print(' %4d  %6d   cap %3d   %5.1fs  %5.1f%% | %5.1f%%'
              % (g, br, best[1]['cap'], best[1]['secs'],
                 100 * best[0], 100 * iou_t))
    offsets.append(best[1]['secs'] - t_board)
    best_ious.append(best[0])

import statistics
print('\nbest-match IoU: median %.1f%%  max %.1f%%  min %.1f%%'
      % (100 * statistics.median(best_ious), 100 * max(best_ious),
         100 * min(best_ious)))
print('implied offset (alt_t - board_t): median %.1fs  stdev %.1fs'
      % (statistics.median(offsets), statistics.pstdev(offsets)))
print('\nIf best-match IoU stays near the equal-time value, the content really')
print('does differ; if it jumps above ~90%%, the bands match once offset.')
