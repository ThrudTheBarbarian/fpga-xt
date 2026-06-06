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

    v_clswk(h);                                         // finalise + write out.pdf
    printf("wrote %s\n", out);

    gfx_surface_free(desk);
    return 0;
}
