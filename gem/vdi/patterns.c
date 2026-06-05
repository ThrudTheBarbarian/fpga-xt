// vdi/patterns.c — the VDI fill masks selected by vsf_interior + vsf_style.
// 16x16 bitmaps (bit 1<<(x&15) of row y&15), built once, clean-room:
//   interior 2 (PATTERN): 24 — styles 1..8 are a graduated ordered dither
//     (4x4 Bayer), 9..24 are decorative textures.
//   interior 3 (HATCH):   12 line hatches (thin 1..6, bold 7..12).
//   interior 4 (USER):    a 16x16 pattern set by vsf_udpat.
// Out-of-range styles clamp to the ends.

#include "vdi/vdi.h"
#include "vdi/internal.h"
#include <stddef.h>

#define PW 16

static uint16_t dither[8][PW];
static uint16_t deco[16][PW];
static uint16_t hatch[12][PW];
static uint16_t userpat[PW];
static int      built;

static void set(uint16_t *rows, int x, int y) { rows[y & 15] |= (uint16_t)(1u << (x & 15)); }

static void build(void) {
    static const int bayer[4][4] = { {0,8,2,10}, {12,4,14,6}, {3,11,1,9}, {15,7,13,5} };
    for (int L = 0; L < 8; L++) {                       // graduated dither 2,1..2,8
        int th = (L + 1) * 2;                           // 2,4,..,16 set cells per 16
        for (int y = 0; y < 16; y++) {
            uint16_t r = 0;
            for (int x = 0; x < 16; x++) if (bayer[y & 3][x & 3] < th) r |= (uint16_t)(1u << x);
            dither[L][y] = r;
        }
    }
    for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++) {
        int X = x & 7, Y = y & 7;
        int dx = (X - 4 < 0) ? 4 - X : X - 4, dy = (Y - 4 < 0) ? 4 - Y : Y - 4;   // dist to 8-cell centre
        if ((y & 7) == 0 || x % 16 == (((y >> 3) & 1) ? 8 : 0)) set(deco[0],  x, y);  // brick
        if (((x + y) & 7) == 0)                                 set(deco[1],  x, y);  // thin /
        if ((x & 7) == 0 && (y & 7) == 0)                       set(deco[2],  x, y);  // sparse dots
        if ((x & 3) == 0 || (y & 3) == 0)                       set(deco[3],  x, y);  // fine grid
        if (((x + y) & 7) < 2)                                  set(deco[4],  x, y);  // diagonal weave
        if ((x & 3) == 1 && (y & 3) == 1)                       set(deco[5],  x, y);  // medium dots
        if ((x & 15) == 0 && (y & 15) == 0)                     set(deco[6],  x, y);  // very sparse
        if (((x + y) & 3) == 0)                                 set(deco[7],  x, y);  // dense /
        if (dx + dy == 3)                                       set(deco[8],  x, y);  // scales (outline)
        if (((x + (y & 1 ? 4 : 0)) & 7) < 2)                    set(deco[9],  x, y);  // herringbone
        if (((x - y) & 7) < 2)                                  set(deco[10], x, y);  // dense back-diag
        if ((x & 7) < 2 && (y & 7) < 2)                         set(deco[11], x, y);  // tiles
        if (((x >> 2) ^ (y >> 2)) & 1)                          set(deco[12], x, y);  // 4px checker
        if (dx + dy < 3)                                        set(deco[13], x, y);  // small diamonds
        { int Dx = (x & 15) - 8, Dy = (y & 15) - 8;
          if ((Dx < 0 ? -Dx : Dx) + (Dy < 0 ? -Dy : Dy) < 6)   set(deco[14], x, y); } // big diamonds
        if (((x - y) & 3) < 2)                                  set(deco[15], x, y);  // diagonal bands

        if (((x - y) & 3) == 0)                  set(hatch[0],  x, y);  // / thin
        if (((x + y) & 3) == 0)                  set(hatch[1],  x, y);  // \ thin
        if (((x - y) & 3) == 0 || ((x + y) & 3) == 0) set(hatch[2], x, y); // X thin
        if ((x & 3) == 0)                        set(hatch[3],  x, y);  // vertical thin
        if ((y & 3) == 0)                        set(hatch[4],  x, y);  // horizontal thin
        if ((x & 3) == 0 || (y & 3) == 0)        set(hatch[5],  x, y);  // grid thin
        if (((x - y) & 7) < 2)                   set(hatch[6],  x, y);  // / bold
        if (((x + y) & 7) < 2)                   set(hatch[7],  x, y);  // \ bold
        if (((x - y) & 7) < 2 || ((x + y) & 7) < 2) set(hatch[8], x, y); // X bold
        if ((x & 7) < 2)                         set(hatch[9],  x, y);  // vertical bold
        if ((y & 7) < 2)                         set(hatch[10], x, y);  // horizontal bold
        if ((x & 7) < 2 || (y & 7) < 2)          set(hatch[11], x, y);  // grid bold
    }
    built = 1;
}

const uint16_t *vdi_fill_mask(int interior, int style) {
    if (!built) build();
    if (interior == VDI_FIS_PATTERN) {
        int i = style; if (i < 1) i = 1; if (i > 24) i = 24;
        return i <= 8 ? dither[i - 1] : deco[i - 9];
    }
    if (interior == VDI_FIS_HATCH) {
        int i = style; if (i < 1) i = 1; if (i > 12) i = 12;
        return hatch[i - 1];
    }
    if (interior == VDI_FIS_USER) return userpat;
    return NULL;                        // solid / hollow
}

void vdi_set_userpat(const uint16_t *rows16) {
    for (int i = 0; i < PW; i++) userpat[i] = rows16[i];
}
