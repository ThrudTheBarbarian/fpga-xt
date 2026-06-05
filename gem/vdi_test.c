// vdi_test.c — headless sanity for the VDI (no SDL): dispatch, clipping, pens.
// Draws onto an in-memory surface and checks individual pixels.

#include "vdi/vdi.h"
#include <stdio.h>
#include <stdlib.h>

static int fails = 0;
static uint32_t PX(gfx_surface *s, int x, int y) { return s->px[(size_t)y * s->stride + x]; }

// Bounding box (width,height) of the non-zero pixels in s.
static void ink_bbox(gfx_surface *s, int *w, int *h) {
    int x0 = s->w, y0 = s->h, x1 = -1, y1 = -1;
    for (int y = 0; y < s->h; y++) for (int x = 0; x < s->w; x++)
        if (s->px[(size_t)y * s->stride + x]) {
            if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
    *w = x1 - x0; *h = y1 - y0;
}

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
    vswr_mode(hf, VDI_MD_TRANS);                        // transparent: pattern gaps stay clear
    int16_t redrgb[3] = { 1000, 0, 0 };
    vs_color(hf, 5, redrgb);                            // redefine pen 5 -> pure red
    vsf_color(hf, 5); vsf_interior(hf, VDI_FIS_SOLID); vsf_perimeter(hf, 0);
    int16_t solid[4] = { 0, 0, 9, 9 }; vr_recfl(hf, solid);
    CHECK(PX(fs, 3, 3) == GFX_RGB(255, 0, 0));         // pen 5 is now red

    for (int i = 0; i < 40 * 40; i++) fs->px[i] = 0;   // hatch 5 = horizontal lines
    vsf_color(hf, 1); vsf_interior(hf, VDI_FIS_HATCH); vsf_style(hf, 5);
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

    // The full pattern range is handled: a high style fills (not all clamped to
    // empty), and a user-defined pattern fills exactly its bits.
    for (int i = 0; i < 40 * 40; i++) fs->px[i] = 0;
    vsf_color(hf, 1); vsf_interior(hf, VDI_FIS_PATTERN); vsf_style(hf, 21); vsf_perimeter(hf, 0);
    int16_t fr[4] = { 0, 0, 15, 15 }; vr_recfl(hf, fr);
    int any = 0; for (int i = 0; i < 40 * 40; i++) if (fs->px[i]) { any = 1; break; }
    CHECK(any);                                        // pattern 21 produced ink

    uint16_t up[16]; for (int i = 0; i < 16; i++) up[i] = 0x0001;   // column x%16==0
    vsf_udpat(hf, up); vsf_interior(hf, VDI_FIS_USER);
    for (int i = 0; i < 40 * 40; i++) fs->px[i] = 0;
    vr_recfl(hf, fr);
    CHECK(PX(fs, 0, 5) == vdi_pen_rgba(1));            // user-pattern column set
    CHECK(PX(fs, 1, 5) == 0);                          // adjacent column clear
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

    // Font registry: vst_load_fonts maps OS/Fonts, vqt_name enumerates,
    // vst_font selects a face by id (id 1 = system, 2.. = mapped files).
    font_face *sysf = font_face_open("fonts/AovelSansRounded.ttf");
    vdi_set_face(sysf);                                 // system font (id 1)
    vdi_set_font_dir("fonts");
    CHECK(vst_load_fonts(1, 0) == 1);                  // one extra font mapped (id 2)
    char fnm[40] = {0};
    CHECK(vqt_name(1, 1, fnm) == 1); CHECK(fnm[0] != '\0');   // system family name
    char fnm2[40] = {0};
    CHECK(vqt_name(1, 2, fnm2) == 2); CHECK(fnm2[0] != '\0'); // mapped file name
    CHECK(vqt_name(1, 9, fnm2) == 0);                  // unknown id

    gfx_surface *rf = gfx_surface_alloc(80, 30);
    for (int i = 0; i < 80 * 30; i++) rf->px[i] = 0;
    int hrf = v_opnvwk(rf);
    CHECK(vst_font(hrf, 2) == 2);                       // select the mapped face (opens it)
    vst_color(hrf, 1); vst_height(hrf, 18, NULL, NULL, NULL, NULL);
    v_gtext(hrf, 2, 2, "Hi");
    int rdrew = 0; for (int i = 0; i < 80 * 30; i++) if (rf->px[i]) { rdrew = 1; break; }
    CHECK(rdrew);                                       // rendered with the selected face
    CHECK(vst_font(hrf, 1) == 1);                       // back to the system font
    CHECK(vst_font(hrf, 99) == 1);                      // invalid id -> unchanged
    v_clsvwk(hrf); gfx_surface_free(rf);

    vdi_set_font_dir("does/not/exist");
    CHECK(vst_load_fonts(1, 0) == 0);                  // missing dir -> 0
    vst_unload_fonts(1, 0);                            // no-op, must not crash
    (void)sysf;                                         // left open: keeps the system face valid

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

    // v_pmarker: an asterisk marks its centre and arms.
    gfx_surface *pm = gfx_surface_alloc(40, 40);
    for (int i = 0; i < 40 * 40; i++) pm->px[i] = 0;
    int hpm = v_opnvwk(pm);
    vsm_color(hpm, 1); vsm_type(hpm, VDI_MK_ASTERISK); CHECK(vsm_height(hpm, 16) == 16);
    int16_t mk[2] = { 20, 20 }; v_pmarker(hpm, 1, mk);
    CHECK(PX(pm, 20, 20) == vdi_pen_rgba(1));          // centre
    CHECK(PX(pm, 20, 14) == vdi_pen_rgba(1));          // vertical arm (r=8)
    CHECK(PX(pm, 14, 20) == vdi_pen_rgba(1));          // horizontal arm
    v_clsvwk(hpm); gfx_surface_free(pm);

    // v_cellarray: 2x2 cells -> four coloured quadrants.
    gfx_surface *ca = gfx_surface_alloc(20, 20);
    for (int i = 0; i < 20 * 20; i++) ca->px[i] = 0;
    int hca = v_opnvwk(ca);
    int16_t crect[4] = { 0, 0, 19, 19 };
    int16_t cells[4] = { 2, 3, 4, 5 };                 // TL TR BL BR
    v_cellarray(hca, crect, 2, 2, cells);
    CHECK(PX(ca,  5,  5) == vdi_pen_rgba(2));
    CHECK(PX(ca, 15,  5) == vdi_pen_rgba(3));
    CHECK(PX(ca,  5, 15) == vdi_pen_rgba(4));
    CHECK(PX(ca, 15, 15) == vdi_pen_rgba(5));
    v_clsvwk(hca); gfx_surface_free(ca);

    // v_contourfill: seed fill inside a boundary box.
    gfx_surface *cf = gfx_surface_alloc(30, 30);
    for (int i = 0; i < 30 * 30; i++) cf->px[i] = 0;
    int hcf = v_opnvwk(cf);
    vsl_color(hcf, 1); vsl_width(hcf, 1); vsl_type(hcf, 1);
    int16_t box[10] = { 5,5, 24,5, 24,24, 5,24, 5,5 }; v_pline(hcf, 5, box);
    vsf_color(hcf, 2);
    v_contourfill(hcf, 15, 15, 1);                     // fill up to boundary pen 1
    CHECK(PX(cf, 15, 15) == vdi_pen_rgba(2));          // interior filled
    CHECK(PX(cf,  2,  2) == 0);                         // outside the box untouched
    CHECK(PX(cf,  5,  5) == vdi_pen_rgba(1));           // boundary intact
    v_clsvwk(hcf); gfx_surface_free(cf);

    // ---- various sizes of the last three ----------------------------------
    // Markers scale with vsm_height: the asterisk arm reaches ~height/2.
    gfx_surface *vm = gfx_surface_alloc(120, 120);
    int hvm = v_opnvwk(vm);
    vsm_color(hvm, 1); vsm_type(hvm, VDI_MK_ASTERISK);
    int mheights[] = { 4, 10, 21, 40 };
    for (int k = 0; k < 4; k++) {
        for (int i = 0; i < 120 * 120; i++) vm->px[i] = 0;
        CHECK(vsm_height(hvm, mheights[k]) == mheights[k]);
        int16_t p[2] = { 60, 60 }; v_pmarker(hvm, 1, p);
        int r = mheights[k] / 2;
        CHECK(PX(vm, 60, 60)     == vdi_pen_rgba(1));   // centre
        CHECK(PX(vm, 60, 60 - r) == vdi_pen_rgba(1));   // arm top at ~height/2
        CHECK(PX(vm, 60, 60 - r - 2) == 0);             // nothing past the arm
    }
    v_clsvwk(hvm); gfx_surface_free(vm);

    // Cell arrays at different grid dimensions, all into a 40x40 rect.
    gfx_surface *vc = gfx_surface_alloc(40, 40);
    int hvc = v_opnvwk(vc);
    int16_t full40[4] = { 0, 0, 39, 39 }, fourc[4] = { 2, 3, 4, 5 };
    for (int i = 0; i < 40 * 40; i++) vc->px[i] = 0;
    v_cellarray(hvc, full40, 1, 1, fourc);              // 1x1: whole rect
    CHECK(PX(vc, 0, 0) == vdi_pen_rgba(2) && PX(vc, 39, 39) == vdi_pen_rgba(2));
    for (int i = 0; i < 40 * 40; i++) vc->px[i] = 0;
    v_cellarray(hvc, full40, 4, 1, fourc);              // 4 columns
    CHECK(PX(vc, 5, 20) == vdi_pen_rgba(2) && PX(vc, 15, 20) == vdi_pen_rgba(3));
    CHECK(PX(vc, 25, 20) == vdi_pen_rgba(4) && PX(vc, 35, 20) == vdi_pen_rgba(5));
    for (int i = 0; i < 40 * 40; i++) vc->px[i] = 0;
    v_cellarray(hvc, full40, 1, 4, fourc);              // 4 rows
    CHECK(PX(vc, 20, 5) == vdi_pen_rgba(2) && PX(vc, 20, 35) == vdi_pen_rgba(5));
    int16_t fine[64]; for (int i = 0; i < 64; i++) fine[i] = (i & 1) ? 1 : 2;
    int16_t r32[4] = { 0, 0, 31, 31 };
    for (int i = 0; i < 40 * 40; i++) vc->px[i] = 0;
    v_cellarray(hvc, r32, 8, 8, fine);                  // 8x8 fine grid (4px cells)
    CHECK(PX(vc, 1, 1) == vdi_pen_rgba(2) && PX(vc, 5, 1) == vdi_pen_rgba(1));
    v_clsvwk(hvc); gfx_surface_free(vc);

    // Contour fill of a small and a large region (the latter grows the stack).
    gfx_surface *vf = gfx_surface_alloc(140, 140);
    int hvf = v_opnvwk(vf);
    vsl_color(hvf, 1); vsl_width(hvf, 1); vsl_type(hvf, 1);
    for (int i = 0; i < 140 * 140; i++) vf->px[i] = 0;
    int16_t sbox[10] = { 10,10, 20,10, 20,20, 10,20, 10,10 }; v_pline(hvf, 5, sbox);
    vsf_color(hvf, 2); v_contourfill(hvf, 15, 15, 1);
    CHECK(PX(vf, 15, 15) == vdi_pen_rgba(2) && PX(vf, 11, 11) == vdi_pen_rgba(2));
    CHECK(PX(vf, 5, 5) == 0);
    for (int i = 0; i < 140 * 140; i++) vf->px[i] = 0;
    int16_t lbox[10] = { 10,10, 130,10, 130,130, 10,130, 10,10 }; v_pline(hvf, 5, lbox);
    vsf_color(hvf, 3); v_contourfill(hvf, 70, 70, 1);   // ~120x120 interior
    CHECK(PX(vf, 70, 70) == vdi_pen_rgba(3));
    CHECK(PX(vf, 12, 12) == vdi_pen_rgba(3) && PX(vf, 128, 128) == vdi_pen_rgba(3));
    CHECK(PX(vf, 5, 5) == 0);
    v_clsvwk(hvf); gfx_surface_free(vf);

    // vswr_mode: XOR is reversible, REPLACE writes the ground, ERASE inverts.
    gfx_surface *wm = gfx_surface_alloc(20, 20);
    int hwm = v_opnvwk(wm);
    vsf_color(hwm, 2); vsf_interior(hwm, VDI_FIS_SOLID); vsf_perimeter(hwm, 0);
    for (int i = 0; i < 20 * 20; i++) wm->px[i] = 0x11223344;
    CHECK(vswr_mode(hwm, VDI_MD_XOR) == VDI_MD_XOR);
    int16_t wr[4] = { 2, 2, 12, 12 };
    vr_recfl(hwm, wr); CHECK(PX(wm, 5, 5) != 0x11223344);   // XOR changed it
    vr_recfl(hwm, wr); CHECK(PX(wm, 5, 5) == 0x11223344);   // XOR twice restores

    vswr_mode(hwm, VDI_MD_REPLACE);                    // opaque pattern: gaps = pen 0
    for (int i = 0; i < 20 * 20; i++) wm->px[i] = 0;
    vsf_color(hwm, 1); vsf_interior(hwm, VDI_FIS_HATCH); vsf_style(hwm, 5);   // horizontal
    int16_t wr2[4] = { 0, 0, 15, 15 }; vr_recfl(hwm, wr2);
    CHECK(PX(wm, 5, 0) == vdi_pen_rgba(1));            // hatch line
    CHECK(PX(wm, 5, 1) == vdi_pen_rgba(0));            // gap filled with the ground

    vswr_mode(hwm, VDI_MD_ERASE);                      // reverse-transparent
    for (int i = 0; i < 20 * 20; i++) wm->px[i] = 0;
    vsf_color(hwm, 3); vr_recfl(hwm, wr2);
    CHECK(PX(wm, 5, 0) == 0);                          // on the line: left unchanged
    CHECK(PX(wm, 5, 1) == vdi_pen_rgba(3));            // in the gap: drawn
    v_clsvwk(hwm); gfx_surface_free(wm);

    // vst_rotation: text rotates to any angle (not just 0/90/180/270).
    font_face *rotf = font_face_open("fonts/AovelSansRounded.ttf");
    vdi_set_face(rotf);
    gfx_surface *rs = gfx_surface_alloc(120, 120);
    int hrs = v_opnvwk(rs);
    vst_color(hrs, 1); vst_height(hrs, 24, NULL, NULL, NULL, NULL);
    int rw, rh;
    CHECK(vst_rotation(hrs, 0) == 0);
    for (int i = 0; i < 120 * 120; i++) rs->px[i] = 0;
    v_gtext(hrs, 8, 50, "mmmm");
    ink_bbox(rs, &rw, &rh); CHECK(rw > rh);            // horizontal: wider than tall

    CHECK(vst_rotation(hrs, 900) == 900);              // 90 degrees
    for (int i = 0; i < 120 * 120; i++) rs->px[i] = 0;
    v_gtext(hrs, 70, 90, "mmmm");
    ink_bbox(rs, &rw, &rh); CHECK(rh > rw);            // rotated: taller than wide

    CHECK(vst_rotation(hrs, 450) == 450);              // arbitrary (45 degrees) accepted
    for (int i = 0; i < 120 * 120; i++) rs->px[i] = 0;
    v_gtext(hrs, 30, 70, "Ag");
    int rdr = 0; for (int i = 0; i < 120 * 120; i++) if (rs->px[i]) { rdr = 1; break; }
    CHECK(rdr);                                        // renders at 45 degrees
    CHECK(vst_rotation(hrs, -100) == 3500);            // normalised into 0..3599
    v_clsvwk(hrs); gfx_surface_free(rs); font_face_close(rotf);

    // vst_effects: bold adds ink; the bitmask round-trips (6 bits).
    font_face *ef = font_face_open("fonts/AovelSansRounded.ttf");
    vdi_set_face(ef);
    gfx_surface *es = gfx_surface_alloc(80, 40);
    int he = v_opnvwk(es);
    vst_color(he, 1); vst_height(he, 28, NULL, NULL, NULL, NULL);
    CHECK(vst_effects(he, FX_BOLD) == FX_BOLD);
    for (int i = 0; i < 80 * 40; i++) es->px[i] = 0;
    v_gtext(he, 6, 4, "M");
    int boldn = 0; for (int i = 0; i < 80 * 40; i++) if (es->px[i]) boldn++;
    vst_effects(he, 0);
    for (int i = 0; i < 80 * 40; i++) es->px[i] = 0;
    v_gtext(he, 6, 4, "M");
    int plainn = 0; for (int i = 0; i < 80 * 40; i++) if (es->px[i]) plainn++;
    CHECK(boldn > plainn);                             // bold is heavier
    CHECK(vst_effects(he, 0x7F) == 0x3F);              // only the six defined bits kept
    v_clsvwk(he); gfx_surface_free(es); font_face_close(ef);

    // vsl_ends: an arrow end adds a filled arrowhead (more ink than a plain line).
    gfx_surface *ae = gfx_surface_alloc(60, 40);
    int hae = v_opnvwk(ae);
    vsl_color(hae, 1); vsl_width(hae, 1); vsl_type(hae, 1);
    int16_t aln[4] = { 6, 20, 50, 20 };
    for (int i = 0; i < 60 * 40; i++) ae->px[i] = 0;
    vsl_ends(hae, VDI_LE_SQUARE, VDI_LE_SQUARE); v_pline(hae, 2, aln);
    int plainl = 0; for (int i = 0; i < 60 * 40; i++) if (ae->px[i]) plainl++;
    for (int i = 0; i < 60 * 40; i++) ae->px[i] = 0;
    vsl_ends(hae, VDI_LE_SQUARE, VDI_LE_ARROW); v_pline(hae, 2, aln);
    int arrowl = 0; for (int i = 0; i < 60 * 40; i++) if (ae->px[i]) arrowl++;
    CHECK(arrowl > plainl + 20);                        // arrowhead adds a triangle of ink
    CHECK(PX(ae, 40, 16) != 0 && PX(ae, 40, 24) != 0);  // both wings off the line

    // Square vs round caps on a thick line: square is flat at the end point,
    // round bulges past it.
    vsl_width(hae, 6);
    for (int i = 0; i < 60 * 40; i++) ae->px[i] = 0;
    vsl_ends(hae, VDI_LE_SQUARE, VDI_LE_SQUARE); v_pline(hae, 2, aln);
    CHECK(PX(ae, 50, 20) != 0);                         // reaches the end point
    CHECK(PX(ae, 52, 20) == 0);                         // flat: no bulge past it
    for (int i = 0; i < 60 * 40; i++) ae->px[i] = 0;
    vsl_ends(hae, VDI_LE_ROUND, VDI_LE_ROUND); v_pline(hae, 2, aln);
    CHECK(PX(ae, 52, 20) != 0);                         // round cap bulges past
    v_clsvwk(hae); gfx_surface_free(ae);

    if (fails == 0) printf("*** VDI TEST OK ***\n");
    else            printf("*** VDI TEST: %d FAIL(s) ***\n", fails);
    gfx_surface_free(s);
    return fails ? 1 : 0;
}
