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

        // vst_alignment: right-anchored text ends at the anchor; centred straddles it.
        vst_height(ht, 16, NULL, NULL, NULL, NULL);
        font *f16 = font_at(tf, 16);
        int tw = font_text_width(f16, "Align");
        for (int i = 0; i < 220 * 64; i++) ts->px[i] = WHITE;
        vst_alignment(ht, VDI_TA_RIGHT, VDI_TA_TOP, NULL, NULL);
        v_gtext(ht, 120, 4, "Align");                  // text occupies ~[120-tw, 120)
        int left_of_anchor = 0, right_of_anchor = 0;
        for (int y = 4; y < 24; y++) for (int x = 0; x < 220; x++)
            if (PX(ts, x, y) != WHITE) { if (x < 120) left_of_anchor = 1; if (x > 120) right_of_anchor = 1; }
        CHECK(left_of_anchor && !right_of_anchor);     // all ink left of the anchor
        (void)tw;
        vst_alignment(ht, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);   // restore

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

    // vs_color (palette) + fill patterns/hatch + perimeter.
    gfx_surface *fs = gfx_surface_alloc(40, 40);
    int hf = v_opnvwk(fs);
    int16_t redrgb[3] = { 1000, 0, 0 };
    vs_color(hf, 5, redrgb);                            // redefine pen 5 -> pure red
    vsf_color(hf, 5); vsf_interior(hf, VDI_FIS_SOLID); vsf_perimeter(hf, 0);
    int16_t solid[4] = { 0, 0, 9, 9 }; vr_recfl(hf, solid);
    CHECK(PX(fs, 3, 3) == GFX_RGB(255, 0, 0));         // pen 5 is now red

    for (int i = 0; i < 40 * 40; i++) fs->px[i] = 0;   // hatch: horizontal lines
    vsf_color(hf, 1); vsf_interior(hf, VDI_FIS_HATCH); vsf_style(hf, 1);
    int16_t hr[4] = { 0, 0, 15, 15 }; vr_recfl(hf, hr);
    CHECK(PX(fs, 5, 0) == vdi_pen_rgba(1));            // row 0 = hatch line
    CHECK(PX(fs, 5, 1) == 0);                          // row 1 = gap
    CHECK(PX(fs, 5, 4) == vdi_pen_rgba(1));            // row 4 = hatch line

    for (int i = 0; i < 40 * 40; i++) fs->px[i] = 0;   // hollow + perimeter = outline only
    vsf_color(hf, 2); vsf_interior(hf, VDI_FIS_HOLLOW); vsf_perimeter(hf, 1);
    int16_t pr[4] = { 2, 2, 12, 12 }; vr_recfl(hf, pr);
    CHECK(PX(fs, 7, 2) == vdi_pen_rgba(2));            // top edge drawn
    CHECK(PX(fs, 2, 7) == vdi_pen_rgba(2));            // left edge drawn
    CHECK(PX(fs, 7, 7) == 0);                          // interior left empty
    v_clsvwk(hf);
    gfx_surface_free(fs);

    // GDP curved primitives: filled circle, filled rounded rect, rbox outline.
    gfx_surface *gs = gfx_surface_alloc(40, 40);
    int hg = v_opnvwk(gs);
    vsf_color(hg, 2); vsf_interior(hg, VDI_FIS_SOLID); vsf_perimeter(hg, 0);

    for (int i = 0; i < 40 * 40; i++) gs->px[i] = 0;
    v_circle(hg, 20, 20, 15);
    CHECK(PX(gs, 20, 20) == vdi_pen_rgba(2));      // centre filled
    CHECK(PX(gs, 20,  2) == 0);                    // above the circle
    CHECK(PX(gs,  2,  2) == 0);                    // corner outside the disc

    for (int i = 0; i < 40 * 40; i++) gs->px[i] = 0;
    int16_t rb[4] = { 2, 2, 37, 37 };
    v_rfbox(hg, rb);
    CHECK(PX(gs, 20, 20) == vdi_pen_rgba(2));      // centre filled
    CHECK(PX(gs, 20,  2) == vdi_pen_rgba(2));      // top edge filled
    CHECK(PX(gs,  2,  2) == 0);                    // rounded corner cut away

    for (int i = 0; i < 40 * 40; i++) gs->px[i] = 0;
    vsl_color(hg, 1);
    v_rbox(hg, rb);                                // outline only (line colour)
    CHECK(PX(gs, 20,  2) == vdi_pen_rgba(1));      // top edge drawn
    CHECK(PX(gs, 20, 20) == 0);                    // interior empty
    v_clsvwk(hg);
    gfx_surface_free(gs);

    // Line styles: width thickens, dash leaves gaps.
    gfx_surface *ls = gfx_surface_alloc(40, 40);
    int hl = v_opnvwk(ls);
    vsl_color(hl, 1);
    CHECK(vsl_width(hl, 3) == 3);
    for (int i = 0; i < 40 * 40; i++) ls->px[i] = 0;
    int16_t hline[4] = { 2, 20, 37, 20 };              // horizontal, width 3
    v_pline(hl, 2, hline);
    CHECK(PX(ls, 20, 19) == vdi_pen_rgba(1));          // one row above centre
    CHECK(PX(ls, 20, 20) == vdi_pen_rgba(1));          // centre
    CHECK(PX(ls, 20, 21) == vdi_pen_rgba(1));          // one row below => width 3

    CHECK(vsl_type(hl, 3) == 3);                        // dotted
    vsl_width(hl, 1);
    for (int i = 0; i < 40 * 40; i++) ls->px[i] = 0;
    int16_t dline[4] = { 0, 10, 39, 10 };
    v_pline(hl, 2, dline);
    int on = 0, off = 0;
    for (int x = 0; x < 32; x++) { if (PX(ls, x, 10)) on = 1; else off = 1; }
    CHECK(on && off);                                  // dotted => some on, some off
    v_clsvwk(hl);
    gfx_surface_free(ls);

    // vst_load_fonts: count of font files in the fonts directory.
    vdi_set_font_dir("fonts");
    CHECK(vst_load_fonts(1, 0) == 1);                  // only AovelSansRounded.ttf
    vdi_set_font_dir("does/not/exist");
    CHECK(vst_load_fonts(1, 0) == 0);                  // missing dir -> 0
    vst_unload_fonts(1, 0);                            // no-op, must not crash

    // v_opnwk: screen device opens with a handle + extent; others report failure.
    int16_t win[11] = { 1 };                           // device 1 = screen
    int hw = -1; int16_t wout[57] = { 0 };
    v_opnwk(win, &hw, wout);
    CHECK(hw > 0);
    CHECK(wout[0] > 0 && wout[1] > 0);                 // device extent in work_out
    v_clswk(hw);
    int16_t pin[11] = { 21 };                          // device 21 = printer (no driver yet)
    int hp = -1;
    v_opnwk(pin, &hp, wout);
    CHECK(hp == 0);                                    // failed to open

    // Metafile: record drawing to a .gem, then replay it onto a fresh surface.
    vdi_set_device_file("/tmp/vdi_test.gem");
    int16_t mwin[11] = { 31 };                          // device 31 = metafile
    int mh = -1; int16_t mwout[57] = { 0 };
    v_opnwk(mwin, &mh, mwout);
    CHECK(mh > 0);
    vsf_color(mh, 2); vsf_interior(mh, VDI_FIS_SOLID); vsf_perimeter(mh, 0);
    int16_t mrect[4] = { 5, 5, 20, 20 }; vr_recfl(mh, mrect);   // recorded, not drawn
    v_clswk(mh);

    gfx_surface *mp = gfx_surface_alloc(40, 40);
    for (int i = 0; i < 40 * 40; i++) mp->px[i] = 0;
    int mhs = v_opnvwk(mp);
    int played = vdi_play_metafile("/tmp/vdi_test.gem", mhs);
    CHECK(played >= 2);                                 // attrs + the fill
    CHECK(PX(mp, 10, 10) == vdi_pen_rgba(2));           // the rect replayed
    CHECK(PX(mp, 30, 30) == 0);                         // outside it
    CHECK(vdi_play_metafile("/tmp/does-not-exist.gem", mhs) == -1);
    v_clsvwk(mhs);
    gfx_surface_free(mp);

    // Metafile vro_cpyfm: the source bitmap is inlined and replays.
    vdi_set_device_file("/tmp/vdi_test_cpy.gem");
    int16_t cwin[11] = { 31 }; int chm = -1; int16_t cwout[57] = { 0 };
    v_opnwk(cwin, &chm, cwout);
    gfx_surface *csrc = gfx_surface_alloc(8, 8);
    for (int i = 0; i < 8 * 8; i++) csrc->px[i] = vdi_pen_rgba(3);   // green
    MFDB cmf; mfdb_from_surface(&cmf, csrc);
    int16_t cpy[8] = { 0, 0, 7, 7, 4, 4, 11, 11 };     // 8x8 src -> dst at (4,4)
    vro_cpyfm(chm, VRO_COPY, cpy, &cmf, NULL);
    v_clswk(chm);
    gfx_surface_free(csrc);                            // freed after the inline copy

    gfx_surface *cdst = gfx_surface_alloc(20, 20);
    for (int i = 0; i < 20 * 20; i++) cdst->px[i] = 0;
    int chs = v_opnvwk(cdst);
    CHECK(vdi_play_metafile("/tmp/vdi_test_cpy.gem", chs) >= 1);
    CHECK(PX(cdst, 6, 6) == vdi_pen_rgba(3));          // inside the replayed copy
    CHECK(PX(cdst, 15, 15) == 0);                      // outside it
    v_clsvwk(chs);
    gfx_surface_free(cdst);

    // True-colour detection: v_opnvwk work_out[13] >= 2, vq_extnd work_out[5] == 0.
    int16_t oc[16] = {0}, oii[128], opi[256], oio[128], opo[256];
    vdi_pb opb = { oc, oii, opi, oio, opo };
    oc[0] = VDI_OPNVWK; oc[6] = 0;
    vdi_call(&opb);                                    // raw param-block open
    CHECK(oio[13] >= 2);                               // colour device
    if (oc[6] > 0) v_clsvwk(oc[6]);
    int16_t ext[57] = { 0 };
    vq_extnd(1, 1, ext);                               // extended inquiry on the physical ws
    CHECK(ext[5] == 0);                                // 0 => true-colour (no LUT)
    CHECK(ext[4] == 32);                               // 32 planes

    // v_clrwk clears the whole surface to pen 0; v_updwk is a harmless no-op.
    gfx_surface *clr = gfx_surface_alloc(16, 16);
    for (int i = 0; i < 16 * 16; i++) clr->px[i] = 0x12345678;
    int hc = v_opnvwk(clr);
    v_clrwk(hc);
    CHECK(PX(clr, 0, 0)   == vdi_pen_rgba(0));         // pen 0 = background
    CHECK(PX(clr, 15, 15) == vdi_pen_rgba(0));
    v_updwk(hc);                                       // no-op, must not crash
    v_clsvwk(hc);
    gfx_surface_free(clr);

    // v_fillarea: filled polygon (a triangle), interior in / edge-region out.
    gfx_surface *fa = gfx_surface_alloc(20, 20);
    for (int i = 0; i < 20 * 20; i++) fa->px[i] = 0;
    int hfa = v_opnvwk(fa);
    vsf_color(hfa, 2); vsf_interior(hfa, VDI_FIS_SOLID); vsf_perimeter(hfa, 0);
    int16_t tri[6] = { 2, 2, 18, 2, 10, 18 };          // base top, apex bottom
    v_fillarea(hfa, 3, tri);
    CHECK(PX(fa, 10, 8) == vdi_pen_rgba(2));           // inside the triangle
    CHECK(PX(fa,  2, 8) == 0);                          // left of the left edge
    CHECK(PX(fa, 18, 8) == 0);                          // right of the right edge
    v_clsvwk(hfa);
    gfx_surface_free(fa);

    // v_justified: text spreads to fill the requested width.
    font_face *jf = font_face_open("fonts/AovelSansRounded.ttf");   // (earlier face was closed)
    vdi_set_face(jf);
    gfx_surface *js = gfx_surface_alloc(160, 30);
    int hj = v_opnvwk(js);
    vst_color(hj, 1); vst_height(hj, 16, NULL, NULL, NULL, NULL);
    #define RIGHTMOST(surf, W, H) ({ int r = -1; for (int yy=0; yy<(H); yy++) \
        for (int xx=0; xx<(W); xx++) if ((surf)->px[(size_t)yy*(surf)->stride+xx]) if (xx>r) r=xx; r; })
    for (int i = 0; i < 160 * 30; i++) js->px[i] = 0;
    v_gtext(hj, 2, 4, "ABCD");
    int nat_right = RIGHTMOST(js, 160, 30);
    for (int i = 0; i < 160 * 30; i++) js->px[i] = 0;
    v_justified(hj, 2, 4, "ABCD", 120, 0, 1);           // char-spacing, width 120
    int just_right = RIGHTMOST(js, 160, 30);
    CHECK(just_right > nat_right + 30);                  // visibly spread out
    CHECK(just_right >= 100);                            // reaches near 2+120
    v_clsvwk(hj);
    gfx_surface_free(js);
    font_face_close(jf);

    if (fails == 0) printf("*** VDI TEST OK ***\n");
    else            printf("*** VDI TEST: %d FAIL(s) ***\n", fails);
    gfx_surface_free(s);
    return fails ? 1 : 0;
}
