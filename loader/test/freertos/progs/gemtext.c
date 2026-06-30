/* /bin/gemtext — draws to the OS-owned display plane (not a private buffer):
 * SYS_fb_info hands back the plane descriptor, we wrap it in a gfx_surface, open
 * a VDI workstation on it, fill a rect + draw FreeType text, then SYS_fb_present
 * pushes the plane to the display (the compositor on hardware; an ASCII dump
 * under qemu). libGEM.so -> libc.so + libm.so do the rendering. */
#include "gfx.h"
#include "vdi/vdi.h"
#include "font.h"
#include "usys.h"
#include <stdint.h>

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;

    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) { sys_write(2, "gemtext: no display plane\n", 26); return; }

    gfx_surface surf = { fb.w, fb.h, fb.stride, (uint32_t *)fb.addr };
    vdi_init(&surf);
    vdi_set_font_dir("/System/Fonts");
    font_face *face = vdi_load_system_font();
    if (!face) { sys_write(2, "gemtext: system font load FAILED\n", 33); return; }
    vdi_set_face(face);

    int vh = v_opnvwk(&surf);
    if (vh <= 0) { sys_write(2, "gemtext: v_opnvwk FAILED\n", 25); return; }

    int16_t bg[4] = { 0, 0, (int16_t)(fb.w - 1), (int16_t)(fb.h - 1) };
    vsf_color(vh, 0); vsf_interior(vh, 1); vr_recfl(vh, bg);     /* white */
    int16_t box[4] = { 4, 4, 30, (int16_t)(fb.h - 6) };
    vsf_color(vh, 1); vr_recfl(vh, box);                         /* black rect */

    vst_color(vh, 1);
    vst_height(vh, 26, 0, 0, 0, 0);
    v_gtext(vh, 40, 8, "Hello XTOS");

    sys_fb_present();                                            /* push to the display */
    v_clsvwk(vh);
}
