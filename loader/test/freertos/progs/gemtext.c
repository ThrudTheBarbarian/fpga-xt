/* /bin/gemtext — the FIRST GEM CLIENT.
 *
 * It used to draw straight to the display plane (SYS_fb_info -> a gfx_surface on the
 * framebuffer -> SYS_fb_present). It now does what every app will do under gemd
 * (RESPONSIBILITIES.md §5), and touches the framebuffer nowhere:
 *
 *      connect to "gem"  ->  wind_create  ->  map the surface it is handed
 *   -> draw into it with the SAME software VDI as before, zero IPC, full speed
 *   -> post ONE damage rect: "this rect of my surface is new"
 *
 * gemd composites it. gemtext never learns where its window is, what is above it, or
 * whether it is visible at all — and never needs to.
 *
 * It then HOLDS THE WINDOW OPEN until it is killed, because that is the M1 gate: the window
 * must survive, and must then VANISH — with its surface id reclaimed (§11) — when the client
 * dies. gemd notices by channel EOF, not SIGCHLD (which only ever reaches a parent, and gemd
 * is not this process's parent when it is launched over ssh).
 *
 *   gemtext                  draw, then hold the window open until killed
 *   gemtext <secs>           draw, hold for <secs>, exit cleanly  (0 = exit at once)
 *   gemtext <secs> <x> <y>   ...at a given position, so TWO can be on screen at once and
 *                            killing one must take exactly one window with it
 */
#include <stdlib.h>
#include "gemclient.h"
#include "vdi/vdi.h"
#include "font.h"
#include "usys.h"
#include <stdint.h>
#include <stdio.h>

void _app_entry(int argc, char **argv)
{
    int hold = (argc >= 2) ? atoi(argv[1]) : -1;      /* -1 = forever (until killed) */
    int wx   = (argc >= 4) ? atoi(argv[2]) : 200;
    int wy   = (argc >= 4) ? atoi(argv[3]) : 150;

    int fd = gem_connect();
    if (fd < 0) { printf("gemtext: no \"gem\" service (%d) — is gemd running?\n", fd); sys_exit(1); }

    /* 600 x 180 is DELIBERATELY not a multiple of the 64px capacity quantum: the surface
     * comes back 640 x 192, so its STRIDE (640) differs from its EXTENT WIDTH (600) and the
     * §12 rule is actually exercised rather than accidentally true. A round 640 would make
     * stride == width and any code that confused the two would pass this test unharmed —
     * which is exactly how the wind_redraw_area bug survived. */
    gem_window win;
    if (gem_wind_create(fd, 0, wx, wy, 600, 180, &win) != 0) {
        printf("gemtext: wind_create FAILED\n"); sys_exit(1);
    }
    printf("gemtext: wh=%d surf=%d gen=%u extent %dx%d capacity %dx%d (stride %d)\n",
           win.wh, win.surf_id, win.surf_gen, win.w, win.h, win.cap_w, win.cap_h,
           win.surf.stride);

    /* The VDI draws into OUR OWN buffer — ordinary cached memory (§14), so this is fast —
     * and into the TOP-LEFT w x h sub-rect of a surface whose stride is its CAPACITY width
     * (§12). gfx_soft honours surf.stride, so that is all it takes. */
    vdi_init(&win.surf);
    vdi_set_font_dir("/OS/fonts");
    font_face *face = vdi_load_system_font();
    if (!face) { printf("gemtext: system font load FAILED\n"); sys_exit(1); }
    vdi_set_face(face);

    int vh = v_opnvwk(&win.surf);
    if (vh <= 0) { printf("gemtext: v_opnvwk FAILED\n"); sys_exit(1); }

    int16_t bg[4] = { 0, 0, (int16_t)(win.w - 1), (int16_t)(win.h - 1) };
    vsf_color(vh, 0); vsf_interior(vh, 1); vr_recfl(vh, bg);        /* white */
    int16_t box[4] = { 4, 4, 30, (int16_t)(win.h - 6) };
    vsf_color(vh, 1); vr_recfl(vh, box);                            /* black rect */

    vst_color(vh, 1);
    vst_height(vh, 26, 0, 0, 0, 0);
    v_gtext(vh, 40, 8, "Hello XTOS");
    v_gtext(vh, 40, 48, "a window, not the framebuffer");

    /* stamp the pid, so two of these on screen are TELLABLE APART — otherwise "kill one and
     * the right window disappears" is not something you can actually check. */
    char who[48];
    snprintf(who, sizeof who, "pid %d  wh %d  surf %d", (int)sys_getpid(), win.wh, win.surf_id);
    v_gtext(vh, 40, 96, who);

    /* ONE message. gemd blits the rect and never learns why it changed (§3). */
    gem_damage(fd, &win, 0, 0, win.w, win.h);
    v_clsvwk(vh);
    printf("gemtext: damage posted%s\n", hold < 0 ? " — holding the window open (kill me)" : "");
    fflush(stdout);

    if (hold < 0) for (;;) sys_nanosleep(1000000u);                 /* until killed: EOF -> gemd */
    for (int i = 0; i < hold; i++) sys_nanosleep(1000000u);

    /* Clean exit: drop our ref on the surface (gemd still holds one, so a composite in
     * flight is safe — §11), then close the channel. gemd sees EOF either way: the window
     * goes, and the id is reclaimed. */
    gem_wind_close(fd, &win);
    sys_close(fd);
    sys_exit(0);
}
