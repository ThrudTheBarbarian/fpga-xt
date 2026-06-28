/* /bin/gemtext — real-VDI client on XTOS: open a virtual workstation on an RGBA
 * surface, fill a rectangle, and draw a string with the actual gem/ VDI +
 * vendored FreeType (libGEM.so -> libc.so + libm.so). qemu has no display, so
 * the surface is dumped as ASCII — antialiased glyphs as a brightness ramp. */
#include "gfx.h"
#include "vdi/vdi.h"
#include "font.h"
#include <stdio.h>
#include <stdint.h>

static void ascii_dump(gfx_surface *s)
{
    static const char ramp[] = " .:-=+*#%@";
    for (int y = 0; y < s->h; y += 2) {                /* 2 rows -> ~square chars */
        char line[260];
        int n = 0;
        for (int x = 0; x < s->w && n < 256; x++) {
            uint32_t p = s->px[y * s->stride + x];
            int r = (p >> 24) & 255, g = (p >> 16) & 255, b = (p >> 8) & 255;
            int ink = 255 - (r * 30 + g * 59 + b * 11) / 100;   /* black text -> dense */
            line[n++] = ramp[ink * 9 / 255];
        }
        line[n] = 0;
        printf("%s\n", line);
    }
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;
    gfx_surface *s = gfx_surface_alloc(180, 44);
    if (!s) { printf("gemtext: surface alloc FAILED\n"); return; }

    vdi_init(s);
    vdi_set_font_dir("/OS/Fonts");
    font_face *face = vdi_load_system_font();
    if (!face) { printf("gemtext: system font load FAILED\n"); return; }
    vdi_set_face(face);

    int vh = v_opnvwk(s);
    if (vh <= 0) { printf("gemtext: v_opnvwk FAILED\n"); return; }

    int16_t bg[4] = { 0, 0, 179, 43 };          /* fill white */
    vsf_color(vh, 0); vsf_interior(vh, 1); vr_recfl(vh, bg);
    int16_t box[4] = { 4, 4, 30, 39 };          /* black rect */
    vsf_color(vh, 1); vr_recfl(vh, box);

    vst_color(vh, 1);
    vst_height(vh, 26, 0, 0, 0, 0);
    v_gtext(vh, 40, 8, "Hello XTOS");

    printf("gemtext: real VDI + FreeType (%dx%d surface):\n", s->w, s->h);
    ascii_dump(s);
    v_clsvwk(vh);
    fflush(stdout);
}
