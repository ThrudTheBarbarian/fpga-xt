/* /bin/prefs — per-application preferences, as a GEM client.
 *
 * Right-click an application or disk on the desktop and pick "Preferences…";
 * the desktop spawns this with the target's leaf name, which is the SETTINGS
 * DOMAIN.  registry_setting_get/set already namespace per application (two apps
 * may each keep a 'fontSize'), so the storage is the desktop's own registry and
 * nothing new had to be invented for it — this is the UI, not a new store.
 *
 * TABLE-DRIVEN ON PURPOSE.  The first setting to need this was launch speed, but
 * a dialog hard-wired to one checkbox would have to be rewritten the moment a
 * second setting appears.  Adding one here is a row in `SETTINGS[]`: a key, a
 * label, and its choices.  The drawing and hit-testing are written against the
 * table, not against launchSpeed.
 *
 * WHY LAUNCH SPEED EXISTS AT ALL: authentic is real-drive timing, and some
 * titles need it — BallBlazer's intro animates from the VBI while its sectors
 * stream, so the duration of an SIO call is how much animation it gets, and at
 * snappy speed the vehicle never sweeps across.  Everything else just wants to
 * start.  Neither is "correct", so it is a per-title choice.
 *
 *   prefs <name>                 edit the settings for <name> (a window)
 *   prefs <name> <key> <value>   set one setting and exit -- no GEM, no window
 *   prefs -l <name>              list <name>'s settings on stdout
 *
 * The headless forms exist because seeding a title from a shell (or a boot
 * script) must go through the SAME api as the dialog: the `settings` table is
 * created on first write, and hand-crafting its schema in SQL would fork the
 * definition.
 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "aes/aes.h"
#include "vdi/vdi.h"
#include "theme.h"
#include "font.h"
#include "registry.h"
#include "usys.h"

static theme TH;
static char  g_domain[128];

typedef struct { const char *key, *label, *deflt; const char *choice[2]; const char *blurb[2]; } setting;

static const setting SETTINGS[] = {
    { "launchSpeed", "Launch speed", "snappy",
      { "snappy",    "authentic" },
      { "load as fast as the hardware allows",
        "real 1050 drive timing \xe2\x80\x94 for intros that animate while loading" } },
};
#define NSETTINGS ((int)(sizeof SETTINGS / sizeof SETTINGS[0]))

/* Geometry, shared by the painter and the hit test so the two cannot drift.  A
 * setting is a BLOCK: its name, then one row per choice, so adding a setting to
 * SETTINGS[] grows the window instead of overprinting the one above. */
#define HDR_H    92                       /* domain + the "applies to" line */
#define LBL_H    24                       /* the setting's own name */
#define ROW_H    34                       /* one choice: label + blurb */
#define ROW_X    28
#define BLOCK_H  (LBL_H + 2 * ROW_H)
#define TITLE_H  30                       /* window chrome, not work area */
static int block_top(int s)        { return HDR_H + s * BLOCK_H; }
static int row_top(int s, int c)   { return block_top(s) + LBL_H + c * ROW_H; }

static int cur_choice(int s)
{
    char v[32];
    registry_setting_get(g_domain, SETTINGS[s].key, SETTINGS[s].deflt, v, sizeof v);
    return strcmp(v, SETTINGS[s].choice[1]) == 0 ? 1 : 0;
}

static void draw_content(int hd, int wx, int wy, int ww, int wh, void *ud)
{
    (void)hd; (void)ud;
    int vh = aes_handle();

    int16_t bg[4] = { (int16_t)wx, (int16_t)wy, (int16_t)(wx+ww-1), (int16_t)(wy+wh-1) };
    vsf_color(vh, 0); vsf_interior(vh, 1); vr_recfl(vh, bg);

    vst_color(vh, 1);
    vst_height(vh, 20, 0, 0, 0, 0);
    v_gtext(vh, wx + 20, wy + 16, g_domain);
    vst_height(vh, 13, 0, 0, 0, 0);
    v_gtext(vh, wx + 20, wy + 40, "Settings apply to this item only.");

    for (int s = 0; s < NSETTINGS; s++) {
        int sel = cur_choice(s);
        vst_height(vh, 15, 0, 0, 0, 0);
        v_gtext(vh, wx + 20, wy + row_top(s, 0) - 18, SETTINGS[s].label);
        for (int c = 0; c < 2; c++) {
            int ty = wy + row_top(s, c);
            /* the marker: filled when chosen, outlined when not */
            int16_t box[4] = { (int16_t)(wx + ROW_X), (int16_t)(ty + 3),
                               (int16_t)(wx + ROW_X + 12), (int16_t)(ty + 15) };
            vsf_color(vh, sel == c ? 1 : 0); vr_recfl(vh, box);
            int16_t out[10] = { box[0], box[1], box[2], box[1], box[2], box[3],
                                box[0], box[3], box[0], box[1] };
            vsl_color(vh, 1); v_pline(vh, 5, out);
            vst_height(vh, 15, 0, 0, 0, 0);
            v_gtext(vh, wx + ROW_X + 24, ty + 2,  SETTINGS[s].choice[c]);
            vst_height(vh, 12, 0, 0, 0, 0);
            v_gtext(vh, wx + ROW_X + 24, ty + 17, SETTINGS[s].blurb[c]);
        }
    }
}

void _app_entry(int argc, char **argv)
{
    int list = (argc >= 2 && !strcmp(argv[1], "-l"));
    snprintf(g_domain, sizeof g_domain, "%s", argc >= (list ? 3 : 2) ? argv[list ? 2 : 1] : "");
    if (!g_domain[0]) {
        printf("usage: prefs <name> | prefs <name> <key> <value> | prefs -l <name>\n");
        fflush(stdout); sys_exit(2);
    }

    if (registry_open_or_create("/OS/var/registry.db") != 0) {
        printf("prefs: cannot open the registry\n"); fflush(stdout); sys_exit(1);
    }

    if (list) {
        char k[64], v[128];
        for (int i = 0; registry_setting_key(g_domain, i, k, sizeof k) > 0; i++) {
            registry_setting_get(g_domain, k, "", v, sizeof v);
            printf("%s = %s\n", k, v);
        }
        fflush(stdout); registry_close(); sys_exit(0);
    }
    if (argc >= 4) {
        int rc = registry_setting_set(g_domain, argv[2], argv[3]);
        printf("%s: %s = %s%s\n", g_domain, argv[2], argv[3], rc == 0 ? "" : "  (FAILED)");
        fflush(stdout); registry_close(); sys_exit(rc == 0 ? 0 : 1);
    }

    vdi_set_font_dir("/OS/fonts");
    font_face *face = vdi_load_system_font();
    if (!face) { printf("prefs: system font load FAILED\n"); sys_exit(1); }
    vdi_set_face(face);
    if (theme_load(&TH, "/OS/themes/Aristo2/1x") != 0)
        theme_load(&TH, "/System/themes/Aristo2/1x");
    aes_init(0, &TH);

    appl_init();
    if (aes_mode() != AES_CLIENT) {
        printf("prefs: no \"gem\" service — is gemd running?\n"); sys_exit(1);
    }

    /* wind_create/wind_open take the OUTER size, so the title bar has to be paid
     * for or the last blurb falls off the bottom edge. */
    int W = 540, H = TITLE_H + HDR_H + NSETTINGS * BLOCK_H + 20;
    int hd = wind_create(W_NAME|W_CLOSER|W_MOVER, 240, 180, W, H);
    if (hd <= 0) { printf("prefs: wind_create FAILED\n"); sys_exit(1); }
    char title[160]; snprintf(title, sizeof title, "Preferences \xE2\x80\x94 %s", g_domain);
    wind_set_name(hd, title);
    wind_content(hd, draw_content, NULL);
    wind_open(hd, 240, 180, W, H);

    for (;;) {
        int mx, my, mb, ks, key, nc; int16_t msg[8];
        int r = evnt_multi(MU_MESAG | MU_BUTTON | MU_KEYBD, 1, 1, 1, 0,0,0,0,0,
                           0,0,0,0,0, msg, 0, 0, &mx, &my, &mb, &ks, &key, &nc);
        if (r & MU_QUIT) break;
        if ((r & MU_MESAG) && msg[0] == WM_CLOSED) break;
        if (r & MU_BUTTON) {
            /* Clicks arrive in OUR work-area coordinates, so the hit test is the
             * same arithmetic the painter used. */
            for (int s = 0; s < NSETTINGS; s++)
                for (int c = 0; c < 2; c++) {
                    int ty = row_top(s, c);
                    if (my >= ty && my < ty + ROW_H && mx >= ROW_X) {
                        registry_setting_set(g_domain, SETTINGS[s].key, SETTINGS[s].choice[c]);
                        wind_redraw_win(hd);     /* the marker moves */
                    }
                }
        }
    }
    wind_close(hd);
    appl_exit();
    registry_close();
    sys_exit(0);
}
