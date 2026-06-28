/* libGEM.so — minimal VDI geometric primitives on an RGBA-8888 surface.
 * Pure code (no syscalls); built -shared -soname libGEM.so. The real GEM core
 * (gem/, FreeType, themes) graduates here once this integration shape is proven. */
#include "vdi.h"

static inline void put(vdi_surface *s, int x, int y, uint32_t c)
{
    if ((unsigned)x < (unsigned)s->w && (unsigned)y < (unsigned)s->h)
        s->px[y * s->w + x] = c;
}

void v_clear(vdi_surface *s, uint32_t c)
{
    for (int i = 0; i < s->w * s->h; i++) s->px[i] = c;
}

void v_bar(vdi_surface *s, int x, int y, int w, int h, uint32_t c)
{
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++) put(s, x + i, y + j, c);
}

void v_pline(vdi_surface *s, int x0, int y0, int x1, int y1, uint32_t c)
{
    int dx = x1 - x0, dy = y1 - y0;
    int adx = dx < 0 ? -dx : dx, ady = dy < 0 ? -dy : dy;
    int sx = dx < 0 ? -1 : 1, sy = dy < 0 ? -1 : 1;
    int err = (adx > ady ? adx : -ady) / 2, e2;
    for (;;) {
        put(s, x0, y0, c);
        if (x0 == x1 && y0 == y1) break;
        e2 = err;
        if (e2 > -adx) { err -= ady; x0 += sx; }
        if (e2 <  ady) { err += adx; y0 += sy; }
    }
}

void v_circle(vdi_surface *s, int cx, int cy, int r, uint32_t c)
{
    for (int dy = -r; dy <= r; dy++)
        for (int dx = -r; dx <= r; dx++)
            if (dx * dx + dy * dy <= r * r) put(s, cx + dx, cy + dy, c);
}
