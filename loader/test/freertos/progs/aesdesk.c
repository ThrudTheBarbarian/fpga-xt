/* /bin/aesdesk — Phase-1 bring-up of the AES desktop on the A9.
 *
 * Renders the real GEM AES (objc_draw / themed windows / G_CICON icons) onto the
 * OS compositor plane and presents it — no registry or input yet (icons are
 * hardcoded, drawn once).  Proves the AES layer + theme + colour icons render on
 * hardware.  libGEM.so (aes + wm + VDI + theme + img + FreeType) -> libc.so/libm.so.
 *
 * Assets come from the SD (fatfs root): theme /OS/Themes/<Default>/1x, icons
 * /OS/Icons/*.pam; the font from the embedded romfs (/OS/Fonts).
 */
#include "aes/aes.h"
#include "img.h"
#include "registry.h"
#include "font.h"
#include "usys.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define ICON_SZ 48
#define ICON_CW 100
#define ICON_CH (ICON_SZ + 26)
#define MAX_ICONS 32
static int    HV, PW, PH;
static theme  TH;
static CICON  ci[MAX_ICONS];
static gfx_surface *isurf[MAX_ICONS];
static reg_desktop_icon rows[MAX_ICONS];
static OBJECT desk[1 + MAX_ICONS];
static int    n_icons;

static int read_default(const char *dir, char *out, int n) {
    char p[160]; snprintf(p, sizeof p, "%s/Default", dir);
    FILE *f = fopen(p, "r"); out[0] = 0;
    if (!f) return 0;
    if (!fgets(out, n, f)) out[0] = 0;
    fclose(f);
    for (int i = (int)strlen(out)-1; i >= 0 && (out[i]=='\n'||out[i]=='\r'||out[i]==' '||out[i]=='\t'); i--) out[i] = 0;
    return out[0] != 0;
}

static gfx_surface *load_icon(const char *path) {
    char p[200]; snprintf(p, sizeof p, "/OS/Icons/%s", path);
    gfx_surface *raw = img_load(p, NULL);
    if (!raw) return NULL;
    int dw = ICON_SZ, dh = ICON_SZ;
    if (raw->w >= raw->h) dh = raw->h * ICON_SZ / (raw->w ? raw->w : 1);
    else                  dw = raw->w * ICON_SZ / (raw->h ? raw->h : 1);
    if (dw < 1) dw = 1; if (dh < 1) dh = 1;
    gfx_surface *ic = img_scale(raw, dw, dh);
    gfx_surface_free(raw);
    return ic;
}

// Build the desktop object tree from the registry's desktopIcons (x,y,path,name).
static void build_desktop(void) {
    n_icons = registry_desktop_icons(rows, MAX_ICONS);
    if (n_icons < 0) n_icons = 0;
    desk[0] = (OBJECT){ NIL, n_icons ? 1 : NIL, n_icons ? n_icons : NIL,
                        G_IBOX, OF_NONE, OS_NORMAL, 0, 0, 0, (int16_t)PW, (int16_t)PH };
    for (int i = 0; i < n_icons; i++) {
        isurf[i]   = load_icon(rows[i].path);
        ci[i].img  = isurf[i];
        ci[i].text = rows[i].displayName[0] ? rows[i].displayName : NULL;
        int oi = 1 + i, last = (i == n_icons - 1);
        desk[oi] = (OBJECT){ (int16_t)(last ? 0 : oi+1), NIL, NIL, G_CICON,
                             (uint16_t)(OF_SELECTABLE | (last ? OF_LASTOB : 0)), OS_NORMAL,
                             &ci[i], (int16_t)rows[i].x, (int16_t)rows[i].y, ICON_CW, ICON_CH };
    }
}

static void deskcontent(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; (void)ud;
    aes_icon_label_style(1);                       // over the (dark) desktop
    objc_draw(desk, 0, 2, wx, wy, ww, wh);
}
static void win_draw(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; (void)ww; (void)wh; (void)ud;
    vst_color(HV, 1); vst_height(HV, 20, 0,0,0,0);
    v_gtext(HV, wx+20, wy+30, "AES desktop on the A9 compositor plane.");
    vst_height(HV, 15, 0,0,0,0);
    v_gtext(HV, wx+20, wy+64, "Themed window + G_CICON icons via libGEM.");
}
static void info_draw(int hd, int ix, int iy, int iw, int ih, void *ud) {
    (void)hd; (void)iw; (void)ud;
    vst_color(HV, 1); vst_height(HV, 14, 0,0,0,0);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
    v_gtext(HV, ix+12, iy+ih/2, "info line");
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
}

// ---- interactivity: A9 event source (SYS_input) + click handling -----------
static struct os_fbinfo g_fb;
static gfx_surface *g_bb;

static void present(void) {                        // blit the back-buffer to the plane
    uint32_t *plane = (uint32_t *)g_fb.addr;
    for (int y = 0; y < g_fb.h; y++)
        memcpy(plane + (size_t)y * g_fb.stride, g_bb->px + (size_t)y * g_bb->stride, (size_t)g_fb.w * 4);
    sys_fb_present();
}
// the AES event source: block for the next kernel input event (the cursor is a HW
// sprite moved kernel-side, so motion needs no present — only real actions do).
static int a9_events(aes_event *ev, int timeout_ms) {
    struct os_event oe = { OS_EV_TIMER, 0, 0, 0, 0, 0 };   // default if the syscall fails
    sys_input(&oe, timeout_ms);
    ev->type = oe.type; ev->mx = oe.mx; ev->my = oe.my;
    ev->button = oe.button; ev->key = oe.key; ev->shift = oe.shift;
    return ev->type;
}
static int g_nx = 300, g_ny = 180;
static void stub_draw(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; (void)ww; (void)wh;
    vst_color(HV, 1); vst_height(HV, 18, 0,0,0,0);
    v_gtext(HV, wx+18, wy+26, (const char *)ud);
    vst_height(HV, 14, 0,0,0,0);
    v_gtext(HV, wx+18, wy+56, "(browser / emulator \342\200\224 coming next)");
}
static void open_window(int obj) {
    const char *title = rows[obj-1].displayName[0] ? rows[obj-1].displayName : rows[obj-1].path;
    int h = wind_create(W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER, g_nx, g_ny, 620, 380);
    if (!h) return;
    wind_set_name(h, title); wind_content(h, stub_draw, (void *)title);
    wind_open(h, g_nx, g_ny, 620, 380);
    g_nx += 30; g_ny += 26; if (g_ny > PH-260) { g_nx = 300; g_ny = 180; }
}
static void clear_sel(void) { for (int i = 1; i <= n_icons; i++) desk[i].ob_state &= ~OS_SELECTED; }
static void desk_click(int mx, int my) {
    int obj = objc_find(desk, 0, 2, mx, my);
    if (obj <= 0) { clear_sel(); wind_redraw(); present(); return; }
    int was = desk[obj].ob_state & OS_SELECTED;
    clear_sel(); desk[obj].ob_state |= OS_SELECTED; wind_redraw(); present();
    int mx2, my2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, 340, 0, &mx2, &my2, 0, 0, 0, 0);
    if (r & MU_BUTTON) {
        if (objc_find(desk, 0, 2, mx2, my2) == obj) { open_window(obj); wind_redraw(); present(); return; }
        desk_click(mx2, my2); return;
    }
    if (was) { desk[obj].ob_state &= ~OS_SELECTED; wind_redraw(); present(); }
}

void _app_entry(int argc, char **argv) {
    (void)argc; (void)argv;

    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) { sys_write(2, "aesdesk: no display plane\n", 26); return; }
    PW = fb.w; PH = fb.h;

    /* Composite into the reserved, cacheable WM back-buffer region (SYS_fb_wallpaper
     * -> WALLPAPER_BASE, mapped Normal-WB in the MMU) — fast alpha blending in the
     * D-cache — then blit it to the strided, non-cacheable plane once on present.
     * Drawing straight onto the plane is a slow read-modify-write per pixel. */
    struct os_fbinfo wp;
    if (sys_fb_wallpaper(&wp) != 0 || !wp.addr) { sys_write(2, "aesdesk: no back-buffer\n", 24); return; }
    static gfx_surface bb_s;
    bb_s.w = wp.w; bb_s.h = wp.h; bb_s.stride = wp.stride; bb_s.px = (uint32_t *)wp.addr;
    gfx_surface *bb = &bb_s;

    font_face *face = font_face_open("/OS/Fonts/AovelSansRounded.ttf");
    if (!face) { sys_write(2, "aesdesk: font load FAILED\n", 26); return; }
    vdi_init(bb); HV = v_opnvwk(bb);
    font_face_set_tracking(face, 1); vdi_set_face(face);

    char tn[64], td[160];
    if (read_default("/OS/Themes", tn, sizeof tn)) snprintf(td, sizeof td, "/OS/Themes/%s/1x", tn);
    else                                           snprintf(td, sizeof td, "/OS/Themes/Aristo2/1x");
    if (theme_load(&TH, td) != 0) { sys_write(2, "aesdesk: theme load FAILED\n", 27); return; }
    aes_init(HV, &TH); appl_init();
    wind_set_desktop(0x30507800u);

    if (registry_open("/OS/Etc/Registry.db") != 0)
        sys_write(2, "aesdesk: no registry (/OS/Etc/Registry.db)\n", 43);
    build_desktop();
    wind_set_desktop_content(deskcontent, NULL);

    int w = wind_create(W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER|W_INFO, 360, 240, 760, 480);
    if (w) {
        wind_set_name(w, "XTOS \342\200\224 AES on the plane");
        wind_content(w, win_draw, NULL);
        wind_info(w, info_draw, NULL);
        wind_open(w, 360, 240, 760, 480);
    }
    g_fb = fb; g_bb = bb;
    aes_set_events(a9_events);
    wind_redraw(); present();                       // initial frame

    for (;;) {                                       // interactive loop
        int mx, my, mb, ks, key, nc; int16_t msg[8];
        int r = evnt_multi(MU_MESAG|MU_KEYBD|MU_BUTTON, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, msg, 0,0,
                           &mx, &my, &mb, &ks, &key, &nc);
        if ((r & MU_KEYBD) && key == 0x1b) break;                              // Esc quits
        if ((r & MU_MESAG) && msg[0] == WM_CLOSED) { wind_close(msg[3]); wind_redraw(); present(); }
        if (r & MU_BUTTON) desk_click(mx, my);
    }
    registry_close();
}
