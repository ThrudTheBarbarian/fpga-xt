// theme_demo.c — exercise the 9-slice theme engine against a synthetic atlas:
// build an RGBA atlas (opaque corners, gradient edges, translucent centre),
// round-trip it through the .tex loader, then blit it at several sizes over a
// checker background to confirm corners stay 1:1, edges stretch one axis, the
// centre stretches both, and the alpha composites (VR_OVER).

#include "theme.h"
#include <stdio.h>
#include <stdlib.h>

static void putppm(const char *p, gfx_surface *s) {
    FILE *f = fopen(p, "wb"); fprintf(f, "P6\n%d %d\n255\n", s->w, s->h);
    for (int i = 0; i < s->w * s->h; i++) { uint32_t v = s->px[i];
        unsigned char c[3] = { v>>24, v>>16, v>>8 }; fwrite(c, 1, 3, f); }
    fclose(f);
}

int main(void) {
    // ---- synthetic 36x36 atlas, 12px insets ----
    int A = 36, ins = 12;
    gfx_surface *atlas = gfx_surface_alloc(A, A);
    for (int y = 0; y < A; y++) for (int x = 0; x < A; x++) {
        int corner = (x < ins || x >= A-ins) && (y < ins || y >= A-ins);
        int edge   = (x < ins || x >= A-ins) ^ (y < ins || y >= A-ins);
        uint32_t px;
        if (corner)      px = GFX_RGB(200,40,40);                 // opaque red corners
        else if (edge)   px = GFX_RGB(40,160,60);                 // opaque green edges
        else             px = GFX_RGBA(40,90,210,150);            // translucent blue centre
        atlas->px[(size_t)y*atlas->stride+x] = px;
    }
    // write + reload through the .tex path
    FILE *tf = fopen("/tmp/theme_test.tex", "wb");
    uint32_t w = A, h = A; fwrite("GTEX",1,4,tf); fwrite(&w,4,1,tf); fwrite(&h,4,1,tf);
    for (int y=0;y<A;y++) fwrite(atlas->px+(size_t)y*atlas->stride,4,A,tf);
    fclose(tf); gfx_surface_free(atlas);

    theme th = {0};
    th.atlas = theme_tex_load("/tmp/theme_test.tex");
    if (!th.atlas) { fprintf(stderr,"tex load failed\n"); return 1; }
    mfdb_from_surface(&th.atlas_mfdb, th.atlas);
    theme_slice sl = { "frame", 0,0,A,A, ins,ins,ins,ins, THEME_STRETCH };

    // ---- destination: a grey/white checker so the translucent centre shows ----
    gfx_surface *d = gfx_surface_alloc(420, 240);
    for (int y=0;y<240;y++) for (int x=0;x<420;x++)
        d->px[(size_t)y*d->stride+x] = ((x/12 + y/12) & 1) ? GFX_RGB(210,210,210) : GFX_RGB(245,245,245);
    vdi_init(d); int handle = v_opnvwk(d);

    theme_blit(handle, &th, &sl,  20,  20,  60,  60);   // small square
    theme_blit(handle, &th, &sl,  95,  20, 300,  50);   // wide (edges stretch horizontally)
    theme_blit(handle, &th, &sl,  20,  95,  55, 130);   // tall (edges stretch vertically)
    theme_blit(handle, &th, &sl,  95,  95, 300, 130);   // big (centre stretches both ways)

    putppm("/tmp/theme_demo.ppm", d);
    theme_free(&th);
    return 0;
}
