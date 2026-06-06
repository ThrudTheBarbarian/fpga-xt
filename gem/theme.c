// theme.c — the 9-slice theme renderer (see theme.h).

#include "theme.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

gfx_surface *theme_tex_load(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    char magic[4]; uint32_t w = 0, h = 0;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "GTEX", 4) != 0) { fclose(f); return NULL; }
    if (fread(&w, 4, 1, f) != 1 || fread(&h, 4, 1, f) != 1) { fclose(f); return NULL; }
    gfx_surface *s = gfx_surface_alloc((int)w, (int)h);
    if (!s) { fclose(f); return NULL; }
    for (int y = 0; y < (int)h; y++)
        if (fread(s->px + (size_t)y * s->stride, 4, w, f) != w) { gfx_surface_free(s); fclose(f); return NULL; }
    fclose(f);
    return s;
}

static uint32_t hex(const char *s) {           // "RRGGBB" -> RGBA opaque
    return (uint32_t)(strtoul(s, NULL, 16) << 8) | 0xFF;
}

int theme_load(theme *th, const char *dir) {
    memset(th, 0, sizeof(*th));
    th->fg = GFX_RGB(40,40,40); th->highlight = GFX_RGB(56,117,214);
    th->sel_bg = GFX_RGB(153,204,255); th->border = GFX_RGB(217,217,211);
    th->disabled = GFX_RGB(160,160,160);

    char path[512];
    snprintf(path, sizeof(path), "%s/artwork.tex", dir);
    th->atlas = theme_tex_load(path);
    if (!th->atlas) return -1;
    mfdb_from_surface(&th->atlas_mfdb, th->atlas);

    snprintf(path, sizeof(path), "%s/locations.txt", dir);
    FILE *f = fopen(path, "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f) && th->nslices < THEME_MAX_SLICES) {
            if (line[0] == '#' || line[0] == '\n') continue;
            theme_slice *s = &th->slice[th->nslices];
            char fill[16] = "stretch";
            int n = sscanf(line, "%39s %d %d %d %d %d %d %d %d %15s",
                           s->name, &s->sx, &s->sy, &s->sw, &s->sh,
                           &s->l, &s->t, &s->r, &s->b, fill);
            if (n < 5) continue;
            s->fill = !strcmp(fill, "tile") ? THEME_TILE : !strcmp(fill, "none") ? THEME_NONE : THEME_STRETCH;
            th->nslices++;
        }
        fclose(f);
    }

    snprintf(path, sizeof(path), "%s/theme.ini", dir);
    f = fopen(path, "r");
    if (f) {
        char key[40], val[40];
        while (fscanf(f, "%39[^=]=%39s\n", key, val) == 2) {
            if      (!strcmp(key, "fg"))        th->fg = hex(val);
            else if (!strcmp(key, "highlight")) th->highlight = hex(val);
            else if (!strcmp(key, "sel_bg"))    th->sel_bg = hex(val);
            else if (!strcmp(key, "border"))    th->border = hex(val);
            else if (!strcmp(key, "disabled"))  th->disabled = hex(val);
        }
        fclose(f);
    }
    return 0;
}

void theme_free(theme *th) {
    if (th->atlas) gfx_surface_free(th->atlas);
    th->atlas = NULL; th->nslices = 0;
}

const theme_slice *theme_find(const theme *th, const char *name) {
    for (int i = 0; i < th->nslices; i++) if (!strcmp(th->slice[i].name, name)) return &th->slice[i];
    return NULL;
}

// One sub-blit: src rect (atlas) -> dst rect (ws target), src-over.
static void cell(int handle, const theme *th, int sx, int sy, int sw, int sh,
                 int dx, int dy, int dw, int dh) {
    if (sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return;
    int16_t pxy[8] = { (int16_t)sx, (int16_t)sy, (int16_t)(sx+sw-1), (int16_t)(sy+sh-1),
                       (int16_t)dx, (int16_t)dy, (int16_t)(dx+dw-1), (int16_t)(dy+dh-1) };
    vr_transfer_bits(handle, &th->atlas_mfdb, NULL, pxy, VR_OVER);
}

void theme_blit(int handle, const theme *th, const theme_slice *s,
                int dx, int dy, int dw, int dh) {
    if (!s) return;
    int l = s->l, t = s->t, r = s->r, b = s->b;
    if (s->fill == THEME_NONE || (l == 0 && t == 0 && r == 0 && b == 0)) {
        cell(handle, th, s->sx, s->sy, s->sw, s->sh, dx, dy, dw, dh);   // sprite / plain stretch
        return;
    }
    // Source / destination column + row spans: [near cap][stretched middle][far cap].
    int scx[3] = { s->sx, s->sx + l, s->sx + s->sw - r };
    int scw[3] = { l, s->sw - l - r, r };
    int scy[3] = { s->sy, s->sy + t, s->sy + s->sh - b };
    int sch[3] = { t, s->sh - t - b, b };
    int dcx[3] = { dx, dx + l, dx + dw - r };
    int dcw[3] = { l, dw - l - r, r };
    int dcy[3] = { dy, dy + t, dy + dh - b };
    int dch[3] = { t, dh - t - b, b };
    for (int row = 0; row < 3; row++)
        for (int col = 0; col < 3; col++)
            cell(handle, th, scx[col], scy[row], scw[col], sch[row],
                            dcx[col], dcy[row], dcw[col], dch[row]);
}

void theme_draw(int handle, const theme *th, const char *name,
                int dx, int dy, int dw, int dh) {
    theme_blit(handle, th, theme_find(th, name), dx, dy, dw, dh);
}
