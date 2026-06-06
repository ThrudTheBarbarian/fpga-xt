// pdf_demo.c — headless smoke test for the PDF printer device (v_opnwk id 21).
// Opens a PDF workstation, draws vector lines / fills / bars across two pages,
// and closes it — producing out.pdf.  No SDL, no screen: this exercises the VDI
// -> PDF translation path end to end.
//
//   make -C gem pdf      # builds + runs, writes gem/out.pdf

#include "vdi/vdi.h"
#include <stdio.h>

int main(int argc, char **argv) {
    const char *out = argc > 1 ? argv[1] : "out.pdf";

    // vdi_init needs a default (screen) surface for extent inquiries; the PDF
    // device never draws to it.  A tiny dummy is fine.
    gfx_surface *desk = gfx_surface_alloc(64, 64);
    vdi_init(desk);
    font_face *face = font_face_open("fonts/AovelSansRounded.ttf");
    if (face) vdi_set_face(face);

    vdi_set_device_file(out);
    int16_t work_in[11] = {0}; work_in[0] = 21;        // device 21 = PDF printer
    int h = 0; int16_t work_out[57];
    v_opnwk(work_in, &h, work_out);
    if (!h) { fprintf(stderr, "v_opnwk(21) failed — no PDF driver?\n"); return 1; }
    printf("opened PDF workstation: handle=%d, page extent %dx%d device units\n",
           h, work_out[0] + 1, work_out[1] + 1);

    // ---- Page 1: a border, a thick diagonal, a filled triangle, a bar -------
    vsl_color(h, 1); vsl_width(h, 8);
    int16_t border[] = { 500,500, 5400,500, 5400,7900, 500,7900, 500,500 };
    v_pline(h, 5, border);

    vsl_color(h, 2); vsl_width(h, 24);
    int16_t diag[] = { 500,500, 5400,7900 };
    v_pline(h, 2, diag);

    vsf_color(h, 4); vsf_interior(h, VDI_FIS_SOLID); vsf_perimeter(h, 1);
    int16_t tri[] = { 2000,1500, 4500,2200, 3000,4200 };
    v_fillarea(h, 3, tri);

    vsf_color(h, 3); vsf_perimeter(h, 0);
    int16_t bar[] = { 1000,5200, 4800,6800 };
    v_bar(h, bar);

    // ---- Page 2: a fan of dashed lines, one per line style ------------------
    v_clrwk(h);                                         // form feed -> page 2
    for (int i = 0; i < 6; i++) {
        vsl_color(h, 1 + i); vsl_type(h, 1 + i); vsl_width(h, 6);
        int16_t s[] = { 500, 500, (int16_t)(900 + i * 850), 7900 };
        v_pline(h, 2, s);
    }

    // ---- Page 3: curved GDPs (bezier), pattern/hatch fills, clipping --------
    v_clrwk(h);                                         // form feed -> page 3
    vsf_perimeter(h, 1); vsl_type(h, 1);               // solid strokes

    vsf_color(h, 2); vsf_interior(h, VDI_FIS_SOLID);
    v_circle(h, 1500, 1500, 900);                      // solid red circle
    vsf_color(h, 4); vsf_interior(h, VDI_FIS_PATTERN); vsf_style(h, 4);
    v_ellipse(h, 4200, 1500, 1500, 900);               // patterned blue ellipse
    vsf_color(h, 11); vsf_interior(h, VDI_FIS_HATCH); vsf_style(h, 6);
    v_pieslice(h, 1500, 4000, 1000, 300, 1200);        // hatched green pie wedge

    vsl_color(h, 1); vsl_width(h, 10);
    v_arc(h, 4200, 4000, 1200, 0, 1800);               // open black arc (semicircle)

    vsf_color(h, 6); vsf_interior(h, VDI_FIS_SOLID);
    int16_t rb[] = { 600, 5400, 2600, 6600 };
    v_rfbox(h, rb);                                    // filled rounded box
    vsl_color(h, 1); vsl_width(h, 6);
    int16_t rb2[] = { 3200, 5400, 5400, 6600 };
    v_rbox(h, rb2);                                    // outline rounded box

    // Clipping: a big patterned fill clipped to a rectangle window.
    int16_t cw[] = { 800, 7000, 5200, 8000 };
    vs_clip(h, 1, cw);
    vsf_color(h, 9); vsf_interior(h, VDI_FIS_HATCH); vsf_style(h, 3);
    int16_t big[] = { 0, 6500, 5950, 8419 };
    v_bar(h, big);                                     // only the clip window shows
    vs_clip(h, 0, cw);

    // ---- Page 4: vector text (FreeType glyph outlines) ----------------------
    if (face) {
        v_clrwk(h);                                     // form feed -> page 4
        vsl_type(h, 1); vsf_interior(h, VDI_FIS_SOLID);

        // Sizes (text sized in device units; 720 dpi page).
        vst_color(h, 1); vst_alignment(h, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
        int sizes[] = { 120, 200, 320, 480 };
        int ty = 600;
        for (int i = 0; i < 4; i++) {
            vst_height(h, sizes[i], NULL, NULL, NULL, NULL);
            v_gtext(h, 500, ty, "Vector text — the quick brown fox");
            ty += sizes[i] + 120;
        }

        // Alignment.
        vst_height(h, 200, NULL, NULL, NULL, NULL); vst_color(h, 4);
        vst_alignment(h, VDI_TA_LEFT,   VDI_TA_TOP, NULL, NULL); v_gtext(h, 2975, 3100, "left");
        vst_alignment(h, VDI_TA_CENTER, VDI_TA_TOP, NULL, NULL); v_gtext(h, 2975, 3360, "centred");
        vst_alignment(h, VDI_TA_RIGHT,  VDI_TA_TOP, NULL, NULL); v_gtext(h, 2975, 3620, "right");
        vst_alignment(h, VDI_TA_LEFT,   VDI_TA_TOP, NULL, NULL);

        // Effects.
        vst_color(h, 1);
        vst_effects(h, FX_BOLD);      v_gtext(h, 500, 4100, "bold");
        vst_effects(h, FX_ITALIC);    v_gtext(h, 2200, 4100, "italic");
        vst_effects(h, FX_UNDERLINE); v_gtext(h, 4000, 4100, "underline");
        vst_effects(h, FX_OUTLINE);   v_gtext(h, 500, 4450, "outline");
        vst_effects(h, FX_SHADOW);    v_gtext(h, 2600, 4450, "shadow");
        vst_effects(h, 0);

        // Rotation (about the anchor).
        vst_color(h, 2);
        for (int deg = 0; deg <= 90; deg += 30) {
            vst_rotation(h, deg * 10);
            v_gtext(h, 1200, 6400, "rotated");
        }
        vst_rotation(h, 0);

        // Justified to a width.
        vst_color(h, 11); vst_height(h, 180, NULL, NULL, NULL, NULL);
        v_justified(h, 500, 7600, "Justified text spread to fill the line.", 4950, 1, 1);
    }

    v_clswk(h);                                         // finalise + write out.pdf
    printf("wrote %s\n", out);

    if (face) font_face_close(face);
    gfx_surface_free(desk);
    return 0;
}
