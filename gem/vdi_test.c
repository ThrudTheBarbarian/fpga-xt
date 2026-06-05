// vdi_test.c — headless sanity for the VDI (no SDL): dispatch, clipping, pens.
// Draws onto an in-memory surface and checks individual pixels.

#include "vdi/vdi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static void dummy_vec(void) { }     // a vex_* handler to exchange
static int g_wheel_amt = 0;
static void wheel_vec(int wheel, int amount) { (void)wheel; g_wheel_amt += amount; }

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

    // vrt_cpyfm: colour an 8x8 monochrome checkerboard (MSB = leftmost pixel).
    static const uint16_t mono[8] = { 0xAA00,0x5500,0xAA00,0x5500,0xAA00,0x5500,0xAA00,0x5500 };
    MFDB mm = { (uint32_t *)mono, 8, 8, 1 };           // w,h pixels; stride = 1 word/row
    gfx_surface *mc = gfx_surface_alloc(16, 16);
    for (int i = 0; i < 16 * 16; i++) mc->px[i] = 0;
    int hm = v_opnvwk(mc);
    int16_t mpxy[8] = { 0, 0, 7, 7, 2, 2, 9, 9 };
    int16_t mcol[2] = { 2, 3 };                         // fg red, bg green
    vrt_cpyfm(hm, VDI_MD_REPLACE, mpxy, &mm, NULL, mcol);
    CHECK(PX(mc, 2, 2) == vdi_pen_rgba(2));            // set bit -> foreground
    CHECK(PX(mc, 3, 2) == vdi_pen_rgba(3));            // clear bit -> background
    CHECK(PX(mc, 4, 2) == vdi_pen_rgba(2));            // set bit again
    v_clsvwk(hm); gfx_surface_free(mc);

    // vr_trnfm: standard (planar) <-> device (chunky).  Build a 16x1, 4-plane
    // standard form where pixel x has colour index x (pens 0..15).
    uint16_t planar[4] = { 0, 0, 0, 0 };               // 4 planes, 1 word each (16 px)
    for (int x = 0; x < 16; x++) for (int p = 0; p < 4; p++)
        if ((x >> p) & 1) planar[p] |= (uint16_t)(1u << (15 - x));
    MFDB std = { (uint32_t *)planar, 16, 1, 1, 4, 1 };  // stride=1 word, 4 planes, standard
    gfx_surface *dev = gfx_surface_alloc(16, 1);
    for (int i = 0; i < 16; i++) dev->px[i] = 0;
    MFDB dmf; mfdb_from_surface(&dmf, dev);
    int htr = v_opnvwk(dev);
    vr_trnfm(htr, &std, &dmf);                          // planar -> chunky
    int ok = 1; for (int x = 0; x < 16; x++) if (dev->px[x] != vdi_pen_rgba(x)) ok = 0;
    CHECK(ok);                                          // each pixel = pen[x]
    uint16_t back[4] = { 9, 9, 9, 9 };                  // garbage to be overwritten
    MFDB std2 = { (uint32_t *)back, 16, 1, 1, 4, 1 };
    vr_trnfm(htr, &dmf, &std2);                          // chunky -> planar (round-trip)
    CHECK(back[0] == planar[0] && back[1] == planar[1] &&
          back[2] == planar[2] && back[3] == planar[3]);
    v_clsvwk(htr); gfx_surface_free(dev);

    // v_get_pixel: read back a pen; an unmatched true-colour pixel -> index -1.
    gfx_surface *gp = gfx_surface_alloc(10, 10);
    int hgp = v_opnvwk(gp);
    vsf_color(hgp, 4); vsf_interior(hgp, VDI_FIS_SOLID); vsf_perimeter(hgp, 0);
    int16_t gpr[4] = { 0, 0, 9, 9 }; vr_recfl(hgp, gpr);
    int pel = -9, idx = -9;
    v_get_pixel(hgp, 5, 5, &pel, &idx);
    CHECK(idx == 4 && pel == 4);                        // matched pen 4
    gp->px[0] = 0x12345678;
    v_get_pixel(hgp, 0, 0, &pel, &idx);
    CHECK(idx == -1);                                  // no palette match
    v_clsvwk(hgp); gfx_surface_free(gp);

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

    // vqt_extent: bounding box matches the font width/height and rotates.
    vst_effects(he, 0); vst_rotation(he, 0); vst_height(he, 20, NULL, NULL, NULL, NULL);
    int16_t tex[8];
    vqt_extent(he, "Wide", tex);
    int ew = tex[2], eh = tex[1];                      // LR.x = width, LL.y = height
    CHECK(ew == font_text_width(font_at(ef, 20), "Wide"));
    CHECK(eh == font_height(font_at(ef, 20)));
    CHECK(tex[6] == 0 && tex[7] == 0);                 // upper-left at the origin
    CHECK(tex[0] == 0 && tex[4] == ew);                // left x=0; right x=width
    vst_rotation(he, 900);                             // 90 deg: box becomes taller than wide
    vqt_extent(he, "Wide", tex);
    int minx = tex[0], maxx = tex[0], miny = tex[1], maxy = tex[1];
    for (int i = 0; i < 4; i++) {
        if (tex[2*i]   < minx) minx = tex[2*i];   if (tex[2*i]   > maxx) maxx = tex[2*i];
        if (tex[2*i+1] < miny) miny = tex[2*i+1]; if (tex[2*i+1] > maxy) maxy = tex[2*i+1];
    }
    CHECK(maxy - miny > maxx - minx);                  // rotated upright

    // vqt_width: one character's cell width == its single-char string width.
    vst_rotation(he, 0); vst_height(he, 20, NULL, NULL, NULL, NULL);
    int lbear = -1, rover = -1;
    int cwid = vqt_width(he, 'W', &lbear, &rover);
    CHECK(cwid == font_text_width(font_at(ef, 20), "W"));
    CHECK(lbear >= 0 && rover >= 0);
    CHECK(vqt_width(he, 'i', NULL, NULL) < cwid);       // 'i' narrower than 'W'

    // Attribute inquiries: set state, read it back.
    int16_t qrgb[3] = { -1, -1, -1 };
    int16_t setrgb[3] = { 1000, 0, 0 };                 // pure red
    vs_color(he, 40, setrgb);
    vq_color(he, 40, 0, qrgb);
    CHECK(qrgb[0] == 1000 && qrgb[1] == 0 && qrgb[2] == 0);

    vsl_type(he, 3); vsl_color(he, 2); vsl_width(he, 5); vswr_mode(he, VDI_MD_XOR);
    int16_t lat[4];
    vql_attributes(he, lat);
    CHECK(lat[0] == 3 && lat[1] == 2 && lat[2] == VDI_MD_XOR && lat[3] == 5);

    vsm_type(he, 4); vsm_color(he, 6); vsm_height(he, 12);
    int16_t mat[4];
    vqm_attributes(he, mat);
    CHECK(mat[0] == 4 && mat[1] == 6 && mat[3] == 12);

    vsf_interior(he, VDI_FIS_PATTERN); vsf_color(he, 7); vsf_style(he, 5);
    vsf_perimeter(he, 1);
    int16_t fqa[5];
    vqf_attributes(he, fqa);
    CHECK(fqa[0] == VDI_FIS_PATTERN && fqa[1] == 7 && fqa[2] == 5 && fqa[4] == 1);

    vst_color(he, 3); vst_rotation(he, 0); vst_alignment(he, VDI_TA_CENTER, VDI_TA_BOTTOM, NULL, NULL);
    int16_t ta[10];
    vqt_attributes(he, ta);
    CHECK(ta[1] == 3 && ta[3] == VDI_TA_CENTER && ta[4] == VDI_TA_BOTTOM);
    CHECK(ta[9] == font_height(font_at(ef, 20)));       // cell height = line height

    // vqt_fontinfo: structural metrics — ordered distances, sane range.
    vst_height(he, 24, NULL, NULL, NULL, NULL);
    int fmin = -1, fmax = -1, fmw = -1; int16_t dist[5], fx[3];
    vqt_fontinfo(he, &fmin, &fmax, dist, &fmw, fx);
    CHECK(fmin == 32 && fmax == 255);
    CHECK(fmw > 0);
    // distances are bottom, descent, half, ascent, top — top >= ascent and
    // bottom >= descent (box spans accents + deepest descenders).
    CHECK(dist[4] >= dist[3] && dist[1] >= 0 && dist[0] >= dist[1]);
    CHECK(dist[3] == font_ascent(font_at(ef, 24)));     // ascent line = font ascent
    CHECK(dist[3] + dist[1] <= font_height(font_at(ef, 24)) + 2);  // asc+desc ~ line

    // --- Extended text / colour attributes (NVDI/FSM) ---
    // v_setrgb: set a pen straight from 8-bit RGB.
    v_setrgb(he, 50, 10, 20, 30);
    CHECK(vdi_pen_rgba(50) == GFX_RGB(10, 20, 30));

    // vst_fg_color: alias of the text pen; returns the previous value.
    vst_color(he, 1);
    CHECK(vst_fg_color(he, 2) == 1);                    // previous was 1
    vst_color(he, 1);                                   // restore

    // vst_bg_color: opaque text fills its cell box first (-1 = none = blend).
    vswr_mode(he, VDI_MD_REPLACE);                      // opaque mode (XOR left set earlier)
    vst_height(he, 16, NULL, NULL, NULL, NULL); vst_color(he, 1);
    for (int i = 0; i < 80 * 40; i++) es->px[i] = 0;
    vst_bg_color(he, 2);                                // red opaque background
    v_gtext(he, 2, 2, "x");
    int redbg = 0; for (int i = 0; i < 80 * 40; i++) if (es->px[i] == vdi_pen_rgba(2)) redbg++;
    CHECK(redbg > 0);                                   // background painted behind the glyph
    CHECK(vst_bg_color(he, -1) == 2);                   // disable, returns previous

    // vst_name: select the system face by its family name -> id 1.
    char sysname[40]; vqt_name(he, 1, sysname);
    int nid = -1;
    CHECK(vst_name(he, sysname, &nid) == 1 && nid == 1);

    // vst_setsize / vst_width: a narrow cell makes the string narrower.
    vst_height(he, 24, NULL, NULL, NULL, NULL);
    int16_t we[8]; vqt_extent(he, "MMMM", we); int wideW = we[2] - we[0];
    vst_width(he, 8, NULL, NULL, NULL, NULL);           // 8px cells (condensed)
    vqt_extent(he, "MMMM", we); int narrowW = we[2] - we[0];
    CHECK(narrowW > 0 && narrowW < wideW);
    vst_height(he, 24, NULL, NULL, NULL, NULL);         // resets to square

    // vst_arbpt32: fractional size rounds to whole px for the raster.
    CHECK(vst_arbpt32(he, 18L << 16, NULL, NULL, NULL, NULL) == 18);
    CHECK(vst_arbpt32(he, (20L << 16) | 0x8000, NULL, NULL, NULL, NULL) == 21);  // 20.5 -> 21

    // vst_skew: returns the previous shear; renders without disturbing metrics.
    CHECK(vst_skew(he, 200) == 0);
    CHECK(vst_skew(he, 0) == 200);

    // vst_kern: engages only if the face has a kern table; reports what's in effect.
    CHECK(vst_kern(he, 1) == (font_face_has_kern(ef) ? 1 : 0));
    vst_kern(he, 0);
    vst_track_offset(he, 0);

    // vst_charmap / vst_map_mode: Unicode-only device.
    CHECK(vst_charmap(he, 0) == VDI_MAP_UNICODE);
    CHECK(vst_map_mode(he, 1) == VDI_MAP_UNICODE);

    // v_ftext: outline text == v_gtext on this device (same pixels).
    vswr_mode(he, VDI_MD_REPLACE); vst_skew(he, 0); vst_bg_color(he, -1);
    vst_height(he, 18, NULL, NULL, NULL, NULL); vst_color(he, 1);
    vst_alignment(he, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
    gfx_surface *fg = gfx_surface_alloc(80, 40), *fh = gfx_surface_alloc(80, 40);
    for (int i = 0; i < 80 * 40; i++) { fg->px[i] = 0; fh->px[i] = 0; }
    int hfg = v_opnvwk(fg), hfh = v_opnvwk(fh);
    vst_color(hfg, 1); vst_color(hfh, 1);
    v_gtext(hfg, 4, 4, "Ag");
    v_ftext(hfh, 4, 4, "Ag");
    int same = 1; for (int i = 0; i < 80 * 40; i++) if (fg->px[i] != fh->px[i]) { same = 0; break; }
    CHECK(same);                                         // v_ftext mirrors v_gtext

    // v_ftext_offset: explicit per-glyph placement — push the 2nd glyph far right.
    for (int i = 0; i < 80 * 40; i++) fh->px[i] = 0;
    int16_t foff[4] = { 0, 0, 50, 0 };                  // glyph 0 at origin, glyph 1 +50px
    v_ftext_offset(hfh, 4, 4, "Ag", foff);
    int leftcol = 0, rightcol = 0;
    for (int y = 0; y < 40; y++) for (int x = 0; x < 30; x++) if (fh->px[(size_t)y*fh->stride+x]) leftcol++;
    for (int y = 0; y < 40; y++) for (int x = 50; x < 80; x++) if (fh->px[(size_t)y*fh->stride+x]) rightcol++;
    CHECK(leftcol > 0 && rightcol > 0);                 // ink in both the placed positions
    v_clsvwk(hfg); v_clsvwk(hfh); gfx_surface_free(fg); gfx_surface_free(fh);

    // --- Extended inquiry (NVDI/FSM) ---
    vst_color(he, 5); vsf_color(he, 6); vsl_color(he, 7); vsm_color(he, 8);
    CHECK(vqt_fg_color(he) == 5);                        // read back text / fill / line / marker pens
    CHECK(vqf_fg_color(he) == 6);
    CHECK(vql_fg_color(he) == 7);
    CHECK(vqm_fg_color(he) == 8);
    vswr_mode(he, VDI_MD_REPLACE); vst_bg_color(he, 3);
    CHECK(vqt_bg_color(he) == 3);                        // read back opaque bg
    vst_bg_color(he, -1);

    // vqt_advance32: full 16.16 advance == vqt_advance's integer + remainder.
    vst_height(he, 24, NULL, NULL, NULL, NULL);
    int aax = 0, arx = 0; vqt_advance(he, 'W', &aax, NULL, &arx, NULL);
    long a32 = 0; vqt_advance32(he, 'W', &a32, NULL);
    CHECK(a32 == (((long)aax << 16) | arx));

    // vqt_name_and_id: name -> id without selecting, with canonical name back.
    char syscanon[40]; vqt_name(he, 1, sysname);
    CHECK(vqt_name_and_id(he, sysname, syscanon) == 1);
    CHECK(strcmp(syscanon, sysname) == 0);

    // vq_scrninfo: direct true-colour RGBA-8888.
    int16_t sci[12]; vq_scrninfo(he, sci);
    CHECK(sci[0] == 2 && sci[1] == 32);                 // model=true colour, 32 bpp
    CHECK(sci[3] == 8 && sci[4] == 24);                 // red: 8 bits at shift 24

    // vqt_pairkern: a number (0 if the face has no kern table) without crashing.
    int kx = -1, ky = -1; vqt_pairkern(he, 'A', 'V', &kx, &ky);
    CHECK(ky == 0 && (font_face_has_kern(ef) || kx == 0));

    // vqt_trackkern: reflects the uniform track offset.
    vst_track_offset(he, 3);
    int tkx = -1; vqt_trackkern(he, &tkx, NULL);
    CHECK(tkx == 3);
    vst_track_offset(he, 0);

    // vqt_real_extent: inked box is no wider than the cell-box extent.
    int16_t rex[8], cex[8];
    vqt_extent(he, "Wax", cex);
    vqt_real_extent(he, "Wax", rex);
    int cellw = cex[2] - cex[0], inkw = rex[2] - rex[0];
    CHECK(inkw > 0 && inkw <= cellw + 1);

    // vqt_justified: per-char offsets ascend and span ~ the requested width.
    int16_t joff[16];
    int jn = vqt_justified(he, "abcd", 200, 0, 1, joff);
    CHECK(jn == 4 && joff[0] == 0 && joff[2*3] > joff[0]);

    // vqt_char_index: Unicode-only identity.
    CHECK(vqt_char_index(he, 'Z', 0, 1) == 'Z');

    // vq_cellarray: read back a painted region as pen indices.
    gfx_surface *ce = gfx_surface_alloc(20, 20);
    int hce = v_opnvwk(ce);
    vsf_color(hce, 2); vsf_interior(hce, VDI_FIS_SOLID); vsf_perimeter(hce, 0);
    int16_t cer[4] = { 0, 0, 19, 19 }; vr_recfl(hce, cer);
    int16_t carr[16]; int eu = 0, ru = 0, st = -1;
    int16_t cpxy[4] = { 0, 0, 19, 19 };
    vq_cellarray(hce, cpxy, 4, 4, &eu, &ru, &st, carr);
    CHECK(st == 0 && eu == 4 && ru == 4 && carr[0] == 2 && carr[15] == 2);
    v_clsvwk(hce); gfx_surface_free(ce);

    // vst_arbpt: arbitrary point size, reports metrics + returns the size used.
    int aw = 0, ah = 0, acw = 0, ach = 0;
    CHECK(vst_arbpt(he, 22, &aw, &ah, &acw, &ach) == 22);
    CHECK(ach == font_height(font_at(ef, 22)));

    // vqt_advance: integer advance + a sub-pixel remainder (1/65536 px).
    vst_height(he, 24, NULL, NULL, NULL, NULL);
    int ax = -1, ay = -1, rx = -1, ry = -1;
    vqt_advance(he, 'W', &ax, &ay, &rx, &ry);
    CHECK(ax > 0 && rx >= 0 && rx < 65536 && ay == 0);
    double adv = ax + rx / 65536.0;                     // matches the 26.6 source
    CHECK(adv > 0 && adv <= font_max_advance(font_at(ef, 24)) + 1);

    // vqt_f_extent: fractional width is within a pixel of the integer extent for
    // a short string, but never accumulates the per-glyph rounding drift.
    int16_t ie[8], fe[8];
    vqt_extent(he, "Wide String", ie);
    vqt_f_extent(he, "Wide String", fe);
    int iw = ie[2] - ie[0], fw = fe[2] - fe[0];
    CHECK(fw > 0 && (iw - fw <= 2 && fw - iw <= 2));     // close, but fractionally summed
    CHECK(fe[6] == 0 && fe[7] == 0);                    // same corner layout as vqt_extent

    // Input / cursor: with no host pump, REQUEST degrades to non-blocking.
    vdi_input_mouse(50, 60, VDI_BTN_LEFT);
    int qb = -1, qx = -1, qy = -1;
    CHECK(vq_mouse(he, &qb, &qx, &qy) == VDI_BTN_LEFT);
    CHECK(qx == 50 && qy == 60);
    int lx = -1, ly = -1;
    vsm_locator(he, 0, 0, &lx, &ly);
    CHECK(lx == 50 && ly == 60);                         // samples current pos

    vdi_input_shift(VDI_KS_CTRL | VDI_KS_LSHIFT);
    int sh = 0;
    CHECK(vq_key_s(he, &sh) == (VDI_KS_CTRL | VDI_KS_LSHIFT));

    CHECK(vdi_cursor_visible() == 1);
    v_hide_c(he); v_hide_c(he); CHECK(vdi_cursor_visible() == 0);   // nests
    v_show_c(he, 0); CHECK(vdi_cursor_visible() == 0);              // one undone
    v_show_c(he, 0); CHECK(vdi_cursor_visible() == 1);              // both undone
    v_hide_c(he); v_show_c(he, 1); CHECK(vdi_cursor_visible() == 1);// reset forces visible

    vdi_input_valuator(42);
    int vv = -1; vsm_valuator(he, &vv); CHECK(vv == 42);
    vdi_input_choice(3);
    int ch = -1; CHECK(vsm_choice(he, &ch) != 0 && ch == 3);

    vsin_mode(he, VDI_DEV_STRING, VDI_MODE_REQUEST);
    vdi_input_key('H'); vdi_input_key('i'); vdi_input_key('\r'); vdi_input_key('X');
    char sbuf[32];
    CHECK(vrq_string(he, 30, 0, sbuf) == 2);             // stops at Enter
    CHECK(sbuf[0] == 'H' && sbuf[1] == 'i' && sbuf[2] == '\0');

    CHECK(vex_butv(he, dummy_vec) == NULL);              // no prior handler
    CHECK(vex_butv(he, NULL) == dummy_vec);              // returns the one we set

    // vex_wheelv: a wheel tick fires the installed handler and bumps the valuator.
    g_wheel_amt = 0;
    CHECK(vex_wheelv(he, wheel_vec) == NULL);            // no prior handler
    vdi_input_valuator(0);
    vdi_input_wheel(0, 3);
    CHECK(g_wheel_amt == 3);                             // handler ran
    int wv = -1; vsm_valuator(he, &wv); CHECK(wv == 3);  // accumulated into the valuator
    CHECK(vex_wheelv(he, NULL) == wheel_vec);            // returns the one we set

    // vsc_form: setting a pointer shape makes vdi_cursor_form report it.
    CHECK(vdi_cursor_form() == NULL);                    // built-in arrow until set
    MFORM mf = { 4, 2, 1, 0, 1, {0}, {0} };
    mf.data[3] = 0x8000; mf.mask[3] = 0xC000;            // one fg pixel, two mask
    vsc_form(he, &mf);
    const MFORM *mform_cur = vdi_cursor_form();
    CHECK(mform_cur != NULL && mform_cur->hotx == 4 && mform_cur->hoty == 2);
    CHECK(mform_cur->fg == 1 && mform_cur->bg == 0 && mform_cur->data[3] == 0x8000 && mform_cur->mask[3] == 0xC000);

    // --- Control extensions ---
    // v_getoutline: a glyph's outline as a v_bez path; re-fill it and check ink.
    vst_height(he, 40, NULL, NULL, NULL, NULL);
    int16_t oxy[512]; uint8_t obez[256];
    int onp = v_getoutline(he, 'o', oxy, obez, 256);
    CHECK(onp > 4);                                      // a real contour
    int hasmove = 0, hasbez = 0;
    for (int i = 0; i < onp; i++) { if (obez[i] & 2) hasmove++; if (obez[i] & 1) hasbez++; }
    CHECK(hasmove >= 1 && hasbez >= 1);                  // contour start(s) + cubic(s)
    // Render it via v_bez_fill at an offset and confirm pixels land.
    gfx_surface *os = gfx_surface_alloc(80, 80);
    for (int i = 0; i < 80 * 80; i++) os->px[i] = 0;
    int hos = v_opnvwk(os);
    for (int i = 0; i < onp; i++) { oxy[2*i] += 20; oxy[2*i+1] += 50; }   // into view
    vsf_color(hos, 1); vsf_interior(hos, VDI_FIS_SOLID); vsf_perimeter(hos, 0);
    v_bez_fill(hos, onp, oxy, obez, NULL, NULL, NULL);
    int oink = 0; for (int i = 0; i < 80 * 80; i++) if (os->px[i]) oink++;
    CHECK(oink > 0);                                     // the outline filled
    v_clsvwk(hos); gfx_surface_free(os);
    v_killoutline(he);                                   // no-op, must not crash

    // v_flushcache: drops the cache; text still renders afterwards.
    v_flushcache(he);
    for (int i = 0; i < 80 * 40; i++) es->px[i] = 0;
    vst_color(he, 1); v_gtext(he, 2, 2, "Z");
    int zdrew = 0; for (int i = 0; i < 80 * 40; i++) if (es->px[i]) { zdrew = 1; break; }
    CHECK(zdrew);                                        // re-rasterised on demand

    // v_resize_bm: re-point a bitmap workstation at a bigger MFDB.
    uint32_t bm1[10 * 10], bm2[30 * 30];
    for (int i = 0; i < 10 * 10; i++) bm1[i] = 0;
    for (int i = 0; i < 30 * 30; i++) bm2[i] = 0;
    MFDB mb1 = { bm1, 10, 10, 10, 0, 0 }, mb2 = { bm2, 30, 30, 30, 0, 0 };
    int hrb = v_opnbm(&mb1, NULL);
    CHECK(v_resize_bm(hrb, &mb2) == 0);
    vsf_color(hrb, 2); vsf_interior(hrb, VDI_FIS_SOLID); vsf_perimeter(hrb, 0);
    int16_t rbr[4] = { 0, 0, 29, 29 }; vr_recfl(hrb, rbr);
    CHECK(bm2[29 * 30 + 29] == vdi_pen_rgba(2));         // fills the new larger bitmap
    v_clsbm(hrb);

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

    // vsl_udsty: a user dash mask used by line type 7 (distance-phased).
    vsl_width(hae, 1); vsl_ends(hae, VDI_LE_SQUARE, VDI_LE_SQUARE);
    CHECK(vsl_type(hae, 7) == 7);
    vsl_udsty(hae, 0x000F);                             // 4 on, 12 off
    for (int i = 0; i < 60 * 40; i++) ae->px[i] = 0;
    int16_t uln[4] = { 0, 10, 40, 10 }; v_pline(hae, 2, uln);
    CHECK(PX(ae, 2, 10) == vdi_pen_rgba(1));            // phase 2 -> on
    CHECK(PX(ae, 8, 10) == 0);                          // phase 8 -> off
    CHECK(PX(ae, 18, 10) == vdi_pen_rgba(1));           // phase 18 (=2 mod 16) -> on again
    v_clsvwk(hae); gfx_surface_free(ae);

    // v_opnbm: open an off-screen device-format bitmap as a workstation and draw
    // into it (no screen target).
    uint32_t bmpx[40 * 30];
    for (int i = 0; i < 40 * 30; i++) bmpx[i] = 0;
    MFDB bm = { bmpx, 40, 30, 40, 0, 0 };               // device form (stand=0)
    int hbm = v_opnbm(&bm, NULL);
    CHECK(hbm > 0);
    vsf_color(hbm, 2); vsf_interior(hbm, VDI_FIS_SOLID); vsf_perimeter(hbm, 0);
    int16_t br[4] = { 5, 5, 34, 24 }; vr_recfl(hbm, br);
    CHECK(bmpx[15 * 40 + 20] == vdi_pen_rgba(2));        // filled into the caller's buffer
    CHECK(bmpx[0] == 0);                                 // outside the rect untouched
    v_clsbm(hbm);                                        // the v_opnbm pair
    MFDB bmstd = { bmpx, 40, 30, 40, 1, 1 };             // standard (planar) -> rejected
    CHECK(v_opnbm(&bmstd, NULL) == 0);

    // v_bez: a cubic bulging up from the baseline marks ink above its endpoints,
    // reports one contour, and a sane bounding box.
    gfx_surface *bs = gfx_surface_alloc(120, 80);
    for (int i = 0; i < 120 * 80; i++) bs->px[i] = 0;
    int hbz = v_opnvwk(bs);
    vsl_color(hbz, 1); vsl_width(hbz, 1); vsl_type(hbz, 1);
    int16_t bxy[8]  = { 10, 70, 40, 0, 80, 0, 110, 70 };   // anchor,ctrl,ctrl,anchor
    uint8_t bfl[4]  = { 1, 0, 0, 0 };                       // point 0 starts a cubic
    int16_t bext[4]; int btp = 0, btm = 0;
    v_bez(hbz, 4, bxy, bfl, bext, &btp, &btm);
    CHECK(btp > 4 && btm == 1);                          // flattened to many pts, 1 contour
    CHECK(bext[1] < 70 && bext[3] >= 70);               // box reaches up above the ends
    int bezink = 0;
    for (int y = 0; y < 40; y++) for (int x = 0; x < 120; x++)
        if (bs->px[(size_t)y * bs->stride + x]) bezink++;
    CHECK(bezink > 0);                                   // the curve arched into the top half

    // v_bez_qual: lower quality => coarser flattening => fewer generated points.
    v_bez_qual(hbz, 100, NULL); int hiq = 0; v_bez(hbz, 4, bxy, bfl, NULL, &hiq, NULL);
    v_bez_qual(hbz, 0, NULL);   int loq = 0; v_bez(hbz, 4, bxy, bfl, NULL, &loq, NULL);
    CHECK(hiq > loq);
    CHECK(v_bez_on(hbz) != 0);                           // capability advertised

    // v_bez_fill: close the curve to the baseline and fill it solid.
    for (int i = 0; i < 120 * 80; i++) bs->px[i] = 0;
    vsf_color(hbz, 3); vsf_interior(hbz, VDI_FIS_SOLID); vsf_perimeter(hbz, 0);
    v_bez_qual(hbz, 100, NULL);
    v_bez_fill(hbz, 4, bxy, bfl, NULL, NULL, NULL);
    CHECK(bs->px[(size_t)60 * bs->stride + 60] == vdi_pen_rgba(3));  // interior filled
    v_clsvwk(hbz); gfx_surface_free(bs);

    if (fails == 0) printf("*** VDI TEST OK ***\n");
    else            printf("*** VDI TEST: %d FAIL(s) ***\n", fails);
    gfx_surface_free(s);
    return fails ? 1 : 0;
}
