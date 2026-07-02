// img.c — Netpbm (P6 PPM / P7 PAM) loader + box scaler + alpha blit.  See img.h.
#include "img.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- PNM header scanning ---------------------------------------------------
// Skip whitespace and '#'-to-EOL comments; return the next significant byte.
static int pnm_skip_ws(FILE *f)
{
    int c;
    for (;;) {
        c = fgetc(f);
        if (c == '#') { while (c != '\n' && c != EOF) c = fgetc(f); continue; }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') continue;
        return c;
    }
}

// Read one non-negative decimal token (PPM header); consumes one trailing
// delimiter byte (so after MAXVAL the file is positioned at the binary data).
static int pnm_uint(FILE *f, int *out)
{
    int c = pnm_skip_ws(f);
    if (c < '0' || c > '9') return -1;
    long v = 0;
    while (c >= '0' && c <= '9') { v = v * 10 + (c - '0'); c = fgetc(f); }
    *out = (int)v;
    return 0;
}

// Fill a surface row from `chan` bytes/pixel of raw samples (chan 3 = RGB opaque,
// 4 = RGBA, 2 = gray+alpha, 1 = gray).
static void row_expand(uint32_t *dst, const unsigned char *raw, int w, int chan)
{
    for (int x = 0; x < w; x++) {
        const unsigned char *p = raw + (size_t)x * chan;
        uint8_t r, g, b, a;
        switch (chan) {
            case 1: r = g = b = p[0]; a = 0xFF; break;
            case 2: r = g = b = p[0]; a = p[1]; break;
            case 4: r = p[0]; g = p[1]; b = p[2]; a = p[3]; break;
            default: r = p[0]; g = p[1]; b = p[2]; a = 0xFF; break;   // 3 = RGB
        }
        dst[x] = GFX_RGBA(r, g, b, a);
    }
}

// Decode `w`x`h` at `chan` bytes/pixel from f into a surface (into `dst` if given
// and sized to match, else a fresh allocation).  f is positioned at the binary.
static gfx_surface *decode_body(FILE *f, int w, int h, int chan, gfx_surface *dst)
{
    if (w <= 0 || h <= 0 || w > 16384 || h > 16384) return NULL;
    gfx_surface *s = dst;
    if (s) { if (s->w != w || s->h != h) return NULL; }
    else   { s = gfx_surface_alloc(w, h); if (!s) return NULL; }

    unsigned char *row = (unsigned char *)malloc((size_t)w * chan);
    if (!row) { if (!dst) gfx_surface_free(s); return NULL; }
    for (int y = 0; y < h; y++) {
        if (fread(row, 1, (size_t)w * chan, f) != (size_t)w * chan) {
            free(row); if (!dst) gfx_surface_free(s); return NULL;
        }
        row_expand(s->px + (size_t)y * s->stride, row, w, chan);
    }
    free(row);
    return s;
}

gfx_surface *img_load(const char *path, gfx_surface *dst)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    int c0 = fgetc(f), c1 = fgetc(f);
    gfx_surface *s = NULL;

    if (c0 == 'P' && c1 == '6') {                       // binary PPM: RGB, opaque
        int w, h, mx;
        if (pnm_uint(f, &w) == 0 && pnm_uint(f, &h) == 0 &&
            pnm_uint(f, &mx) == 0 && mx == 255)
            s = decode_body(f, w, h, 3, dst);
    } else if (c0 == 'P' && c1 == '7') {                // binary PAM: RGBA / gray
        int w = 0, h = 0, depth = 0, mx = 0;
        char line[128];
        (void)fgetc(f);                                 // consume the '\n' after "P7"
        while (fgets(line, sizeof(line), f)) {
            if (!strncmp(line, "ENDHDR", 6)) break;
            if      (!strncmp(line, "WIDTH ",  6)) w     = atoi(line + 6);
            else if (!strncmp(line, "HEIGHT ", 7)) h     = atoi(line + 7);
            else if (!strncmp(line, "DEPTH ",  6)) depth = atoi(line + 6);
            else if (!strncmp(line, "MAXVAL ", 7)) mx    = atoi(line + 7);
        }
        if (mx == 255 && depth >= 1 && depth <= 4)
            s = decode_body(f, w, h, depth, dst);
    }
    fclose(f);
    return s;
}

gfx_surface *img_scale(const gfx_surface *src, int dw, int dh)
{
    if (!src || dw <= 0 || dh <= 0) return NULL;
    gfx_surface *d = gfx_surface_alloc(dw, dh);
    if (!d) return NULL;
    for (int y = 0; y < dh; y++) {
        int sy0 = (int)((long long)y * src->h / dh);
        int sy1 = (int)((long long)(y + 1) * src->h / dh);
        if (sy1 <= sy0) sy1 = sy0 + 1; if (sy1 > src->h) sy1 = src->h;
        for (int x = 0; x < dw; x++) {
            int sx0 = (int)((long long)x * src->w / dw);
            int sx1 = (int)((long long)(x + 1) * src->w / dw);
            if (sx1 <= sx0) sx1 = sx0 + 1; if (sx1 > src->w) sx1 = src->w;
            uint32_t r = 0, g = 0, b = 0, a = 0, n = 0;
            for (int sy = sy0; sy < sy1; sy++)
                for (int sx = sx0; sx < sx1; sx++) {
                    uint32_t p = src->px[(size_t)sy * src->stride + sx];
                    r += (p >> 24) & 0xFF; g += (p >> 16) & 0xFF;
                    b += (p >> 8) & 0xFF;  a += p & 0xFF; n++;
                }
            if (!n) n = 1;
            d->px[(size_t)y * d->stride + x] = GFX_RGBA(r / n, g / n, b / n, a / n);
        }
    }
    return d;
}

void img_blit_over(gfx_surface *dst, int dx, int dy, const gfx_surface *src)
{
    if (!dst || !src) return;
    for (int y = 0; y < src->h; y++) {
        int Y = dy + y; if (Y < 0 || Y >= dst->h) continue;
        for (int x = 0; x < src->w; x++) {
            int X = dx + x; if (X < 0 || X >= dst->w) continue;
            uint32_t sp = src->px[(size_t)y * src->stride + x];
            uint32_t a  = sp & 0xFF;
            if (!a) continue;                            // fully transparent
            uint32_t *dp = &dst->px[(size_t)Y * dst->stride + X];
            if (a == 0xFF) { *dp = sp | 0xFF; continue; }// opaque fast path
            uint32_t dpx = *dp, ia = 255 - a;
            uint32_t r = (((sp >> 24) & 0xFF) * a + ((dpx >> 24) & 0xFF) * ia) / 255;
            uint32_t g = (((sp >> 16) & 0xFF) * a + ((dpx >> 16) & 0xFF) * ia) / 255;
            uint32_t b = (((sp >>  8) & 0xFF) * a + ((dpx >>  8) & 0xFF) * ia) / 255;
            *dp = GFX_RGBA(r, g, b, 0xFF);
        }
    }
}
