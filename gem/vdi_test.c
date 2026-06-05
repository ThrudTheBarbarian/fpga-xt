// vdi_test.c — headless sanity for the VDI (no SDL): dispatch, clipping, pens.
// Draws onto an in-memory surface and checks individual pixels.

#include "vdi/vdi.h"
#include <stdio.h>
#include <stdlib.h>

static int fails = 0;
static uint32_t PX(gfx_surface *s, int x, int y) { return s->px[(size_t)y * s->stride + x]; }

#define CHECK(cond) do { if (!(cond)) { \
    printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); fails++; } } while (0)

int main(void) {
    gfx_surface *s = gfx_surface_alloc(100, 100);
    vdi_init(s);
    int h = v_opnvwk(s);
    CHECK(h > 0);

    const uint32_t RED   = vdi_pen_rgba(2);
    const uint32_t BLACK = vdi_pen_rgba(1);

    // Fill a full-surface rect but clip to (10,10)-(50,50): only that survives.
    int16_t clip[4] = { 10, 10, 50, 50 };
    vs_clip(h, 1, clip);
    vsf_color(h, 2); vsf_interior(h, 1);
    int16_t big[4] = { 0, 0, 99, 99 };
    vr_recfl(h, big);
    CHECK(PX(s, 30, 30) == RED);     // inside clip
    CHECK(PX(s, 10, 10) == RED);     // clip edge inclusive
    CHECK(PX(s, 50, 50) == RED);     // clip edge inclusive
    CHECK(PX(s,  9,  9) == 0);       // just outside (top-left)
    CHECK(PX(s, 51, 51) == 0);       // just outside (bottom-right)
    CHECK(PX(s,  5,  5) == 0);
    CHECK(PX(s, 80, 80) == 0);

    // hollow interior => fill is a no-op
    vsf_interior(h, 0);
    int16_t small[4] = { 20, 20, 30, 30 };
    vsf_color(h, 6); v_bar(h, small);
    CHECK(PX(s, 25, 25) == RED);     // unchanged (still the earlier red fill)

    // Cohen–Sutherland line clip: (0,0)-(99,99) clipped to the same rect.
    vsl_color(h, 1);
    int16_t ln[4] = { 0, 0, 99, 99 };
    v_pline(h, 2, ln);
    CHECK(PX(s, 30, 30) == BLACK);   // on the clipped diagonal, inside clip
    CHECK(PX(s,  5,  5) == 0);        // segment outside clip not drawn

    // vro_cpyfm: copy a green 20x20 source into a fresh dst at (10,10).
    gfx_surface *srcS = gfx_surface_alloc(20, 20);
    for (int i = 0; i < 20 * 20; i++) srcS->px[i] = vdi_pen_rgba(3);  // green
    gfx_surface *dstS = gfx_surface_alloc(40, 40);
    int hd = v_opnvwk(dstS);
    MFDB ms, md;
    mfdb_from_surface(&ms, srcS);
    mfdb_from_surface(&md, dstS);
    int16_t cp[8] = { 0, 0, 19, 19, 10, 10, 29, 29 };
    vro_cpyfm(hd, VRO_COPY, cp, &ms, &md);
    CHECK(PX(dstS, 15, 15) == vdi_pen_rgba(3));   // inside the copied rect
    CHECK(PX(dstS, 10, 10) == vdi_pen_rgba(3));   // top-left of copy
    CHECK(PX(dstS, 29, 29) == vdi_pen_rgba(3));   // bottom-right of copy
    CHECK(PX(dstS,  5,  5) == 0);                  // outside the copy
    CHECK(PX(dstS, 35, 35) == 0);
    gfx_surface_free(srcS); gfx_surface_free(dstS);
    v_clsvwk(hd);

    // v_gtext: FreeType text renders, has positive width, sizes, and clips.
    const uint32_t WHITE = vdi_pen_rgba(0);
    font_face *tf = font_face_open("fonts/AovelSansRounded.ttf");
    CHECK(tf != NULL);
    if (tf) {
        vdi_set_face(tf);
        gfx_surface *ts = gfx_surface_alloc(220, 64);
        for (int i = 0; i < 220 * 64; i++) ts->px[i] = WHITE;
        int ht = v_opnvwk(ts);
        vst_color(ht, 1);                              // black text
        CHECK(font_text_width(font_at(tf, 24), "Ag") > 0);
        vst_height(ht, 24, NULL, NULL, NULL, NULL);
        v_gtext(ht, 4, 4, "Ag");
        int drew = 0;
        for (int i = 0; i < 220 * 64; i++) if (ts->px[i] != WHITE) { drew = 1; break; }
        CHECK(drew);                                   // glyphs marked the surface

        // vst_height / vst_point change the size: wider string at a bigger size.
        int w24 = 0, w12 = 0, cellh = 0;
        vst_height(ht, 12, NULL, NULL, NULL, &cellh);
        w12 = font_text_width(font_at(tf, 12), "Width");
        vst_height(ht, 24, NULL, NULL, NULL, NULL);
        w24 = font_text_width(font_at(tf, 24), "Width");
        CHECK(w24 > w12);                              // bigger size => wider text
        CHECK(cellh > 0);
        int pt = vst_point(ht, 18, NULL, NULL, NULL, NULL);  // 72dpi => 18px
        CHECK(pt == 18);

        // UTF-8: a multibyte codepoint is one glyph, not one-per-byte.
        font *f24 = font_at(tf, 24);
        CHECK(font_text_width(f24, "é") < font_text_width(f24, "??"));   // é (2 bytes)
        CHECK(font_text_width(f24, "—") < font_text_width(f24, "???"));  // — (3 bytes)

        for (int i = 0; i < 220 * 64; i++) ts->px[i] = WHITE;
        int16_t cl[4] = { 200, 56, 201, 57 };          // clip far from the text
        vs_clip(ht, 1, cl);
        v_gtext(ht, 4, 4, "Ag");
        int leaked = 0;
        for (int y = 0; y < 50; y++) for (int x = 0; x < 200; x++)
            if (PX(ts, x, y) != WHITE) leaked = 1;
        CHECK(!leaked);                                // nothing drawn outside the clip

        v_clsvwk(ht);
        gfx_surface_free(ts);
        font_face_close(tf);
    }

    if (fails == 0) printf("*** VDI TEST OK ***\n");
    else            printf("*** VDI TEST: %d FAIL(s) ***\n", fails);
    gfx_surface_free(s);
    return fails ? 1 : 0;
}
