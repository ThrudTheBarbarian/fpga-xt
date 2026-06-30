/* /bin/desktop — the GEM window manager on the OS display plane. Brings up
 * gem_wm on the plane (SYS_fb_info), adds two overlapping windows with chrome +
 * FreeType title/content text (each drawn into its own backing-store surface via
 * the window's VDI workstation), composites the desktop, and presents it
 * (SYS_fb_present). libGEM.so (gem/wm.c + VDI + FreeType) -> libc.so/libm.so. */
#include "gem.h"
#include "vdi/vdi.h"
#include "font.h"
#include "usys.h"
#include <stdint.h>

static gem_wm wm;

/* a window redraw: draw into win->backing (local coords) via its VDI handle */
static void win_redraw(gem_window *win, void *ud)
{
    vst_color(win->vh, 1);                 /* black */
    vst_height(win->vh, 36, 0, 0, 0, 0);   /* readable on the 1920x1080 plane */
    v_gtext(win->vh, 24, 48, (const char *)ud);
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;

    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) { sys_write(2, "desktop: no display plane\n", 26); return; }
    gfx_surface desk = { fb.w, fb.h, fb.stride, (uint32_t *)fb.addr };

    font_face *face = font_face_open("/OS/Fonts/AovelSansRounded.ttf");
    if (!face) { sys_write(2, "desktop: font load FAILED\n", 26); return; }

    gem_wm_init(&wm, &desk, GFX_RGB(0x30, 0x50, 0x78));   /* desktop blue */
    gem_wm_set_font(&wm, face);

    gem_window *w1 = gem_wm_add(&wm, 120, 90, 720, 480, "Hello", 1);
    gem_wm_set_redraw(w1, win_redraw, (void *)"XTOS");
    gem_window *w2 = gem_wm_add(&wm, 980, 420, 760, 520, "Window 2", 0);
    gem_wm_set_redraw(w2, win_redraw, (void *)"GEM desktop");

    gem_wm_draw(&wm);          /* redraw dirty windows, frames, composite */
    sys_fb_present();          /* push the plane to the display */
}
