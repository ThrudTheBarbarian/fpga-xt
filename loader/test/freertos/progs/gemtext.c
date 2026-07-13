/* /bin/gemtext — a GEM CLIENT, written against the ordinary AES.
 *
 * M1 had this talking to gemd through the raw transport. That was scaffolding for one client.
 * It now uses the SAME AES CALLS a single-process GEM app uses — wind_create, wind_set_name,
 * wind_content, wind_open — with their signatures unchanged (RESPONSIBILITIES.md §5). The only
 * thing that differs from a local GEM app is the attach: appl_init() finds the "gem" service
 * and puts the library in client mode. With no gemd running, these very same calls stay local.
 *
 * What it therefore does NOT do, and must never learn to (§5):
 *   - touch the framebuffer;
 *   - draw its own chrome — the frame, title bar, closer and sizer are gemd's, and it never
 *     even sees them;
 *   - ask where its window is, what is above it, or whether it is visible at all.
 *
 * It draws its CONTENT into its own backing store, in its own coordinates starting at 0,0, and
 * posts one damage rect. gemd blits it and never learns why it changed (§3).
 *
 *   gemtext                  hold the window open until killed  (the M1/M2 gate)
 *   gemtext <secs>           hold for <secs>, then exit cleanly (0 = exit at once)
 *   gemtext <secs> <x> <y>   ...at a position, so two can be on screen at once
 */
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include "aes/aes.h"
#include "vdi/vdi.h"
#include "theme.h"
#include "font.h"
#include "usys.h"

static theme TH;

/* THE CONTENT CALLBACK — the seam the whole design hangs off (§8). The AES calls it when the
 * window needs drawing, and we draw through the AES's workstation, which in client mode is
 * bound to OUR OWN surface. Coordinates start at 0,0: this is the work area, and we neither
 * know nor care where it is on screen. No IPC happens in here — it is ordinary cached memory,
 * written at full speed. */
static void draw_content(int hd, int wx, int wy, int ww, int wh, void *ud)
{
    (void)hd; (void)ud;
    int vh = aes_handle();

    int16_t bg[4] = { (int16_t)wx, (int16_t)wy, (int16_t)(wx+ww-1), (int16_t)(wy+wh-1) };
    vsf_color(vh, 0); vsf_interior(vh, 1); vr_recfl(vh, bg);           /* white */
    int16_t box[4] = { (int16_t)(wx+4), (int16_t)(wy+4),
                       (int16_t)(wx+30), (int16_t)(wy+wh-6) };
    vsf_color(vh, 1); vr_recfl(vh, box);                               /* black bar: a landmark */

    vst_color(vh, 1);
    vst_height(vh, 26, 0, 0, 0, 0);
    v_gtext(vh, wx+40, wy+8,  "Hello XTOS");
    vst_height(vh, 15, 0, 0, 0, 0);
    v_gtext(vh, wx+40, wy+48, "content is mine; the chrome is gemd's");

    char who[64];
    snprintf(who, sizeof who, "pid %d   work area %dx%d", (int)sys_getpid(), ww, wh);
    v_gtext(vh, wx+40, wy+72, who);
}

void _app_entry(int argc, char **argv)
{
    int hold = (argc >= 2) ? atoi(argv[1]) : -1;      /* -1 = forever (until killed) */
    int wx   = (argc >= 4) ? atoi(argv[2]) : 200;
    int wy   = (argc >= 4) ? atoi(argv[3]) : 150;

    vdi_set_font_dir("/OS/fonts");
    font_face *face = vdi_load_system_font();
    if (!face) { printf("gemtext: system font load FAILED\n"); sys_exit(1); }
    vdi_set_face(face);

    /* The theme is read-only art and §5 explicitly allows both sides to load it: we need it for
     * objc_draw, gemd needs it for the chrome. No conflict, and nothing to negotiate. */
    if (theme_load(&TH, "/OS/themes/Aristo2/1x") != 0 &&
        theme_load(&TH, "/System/themes/Aristo2/1x") != 0)
        printf("gemtext: no theme (widgets would be unstyled)\n");
    aes_init(0, &TH);            /* the theme now; the AES binds our workstation at wind_open,
                                  * once the surface exists (§10: opened once, never re-opened) */

    /* THE ATTACH — the one line that differs from single-process GEM, and §6 budgets exactly
     * this much (XGApplication.boot() -> .attach()). Everything below is the plain AES. */
    appl_init();
    if (aes_mode() != AES_CLIENT) {
        printf("gemtext: no \"gem\" service — is gemd running?\n");
        sys_exit(1);
    }

    /* 600 x 180 is DELIBERATELY not a multiple of the 64px capacity quantum, so the surface
     * comes back with stride != extent width and §12 is exercised rather than accidentally
     * true. Note this is the FULL window rect: gemd takes the chrome out of it, and the work
     * area we draw into is smaller. We are never told by how much — we are told the size of the
     * drawable, which is all an app may know. */
    int hd = wind_create(W_NAME|W_CLOSER|W_MOVER|W_SIZER, wx, wy, 600, 180);
    if (hd <= 0) { printf("gemtext: wind_create FAILED\n"); sys_exit(1); }

    wind_set_name(hd, "gemtext");
    wind_content(hd, draw_content, NULL);   /* the AES will call this. It is the entire seam. */
    wind_open(hd, wx, wy, 600, 180);        /* -> surface, first paint (§3), damage */

    printf("gemtext: wh=%d open%s\n", hd, hold < 0 ? " — holding it open (kill me)" : "");
    fflush(stdout);

    /* THE EVENT LOOP — the plain AES one, and it is the same one a single-process GEM app runs.
     * Our events come from gemd (M4): it owns the pointer, hit-tests the z-order, handles the
     * chrome itself and sends us only what is ours — clicks in our work area, in OUR coordinates,
     * and the messages that fall out of the chrome. WM_CLOSED is the closer being clicked, and it
     * is a REQUEST: gemd did not close us, it asked. Closing is the app's decision (§3). */
    int deadline = hold;                                   /* seconds; <0 = until killed */
    for (;;) {
        int mx, my, mb, ks, key, nc; int16_t msg[8];
        int r = evnt_multi(MU_MESAG | MU_BUTTON | MU_KEYBD | (deadline >= 0 ? MU_TIMER : 0),
                           1, 1, 1, 0,0,0,0,0, 0,0,0,0,0, msg,
                           deadline >= 0 ? 1000 : 0, 0, &mx, &my, &mb, &ks, &key, &nc);
        if (r & MU_QUIT) break;                            /* gemd is gone: nothing works now */
        if ((r & MU_MESAG) && msg[0] == WM_CLOSED) break;  /* the closer: we agree, and we quit */
        if ((r & MU_TIMER) && deadline >= 0 && --deadline <= 0) break;
        if (r & MU_BUTTON)
            printf("gemtext: click at %d,%d (MY coordinates — I have no idea where I am)\n", mx, my);
        if (r & MU_KEYBD) printf("gemtext: key 0x%02x\n", key);
        fflush(stdout);
    }

    wind_close(hd);            /* drops our surface ref; gemd still holds its own (§11) */
    appl_exit();               /* closes the channel — gemd sees EOF either way */
    sys_exit(0);
}
