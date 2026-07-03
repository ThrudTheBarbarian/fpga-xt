/* /bin/desktop — the GEM desktop on the OS display plane.
 *
 * Brings up gem_wm with a themed 9-slice window chrome, a wallpaper backdrop, and
 * desktop icons — all user content on the SD, each selected by a `Default` file:
 *   - theme:     /OS/themes/<Default>/1x     (SD, baked .tex — no PNG decode)
 *   - wallpaper: /OS/wallpaper/<Default>     (SD, user-swappable PPM; a procedural
 *                gradient is drawn instead when the SD file is absent/unreadable)
 *   - icons:     /OS/icons/*.pam             (SD, user-swappable RGBA; scaled to ICON_SZ)
 *
 * The wallpaper is decoded straight into the OS-owned WALLPAPER_BASE DDR buffer
 * (SYS_fb_wallpaper) — a 1080p surface is ~8 MB, too big for the per-process heap.
 * Icons + labels are composited into that backdrop, so the WM restores them for
 * free when it erases behind a moved/closed window.  libGEM.so (wm/theme/img/VDI
 * + FreeType) -> libc.so/libm.so. */
#include "gem.h"
#include "theme.h"
#include "img.h"
#include "vdi/vdi.h"
#include "font.h"
#include "usys.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Desktop-icon grid (configurable later). A cell is icon band + gap + label:
 * ICON_SZ + ICON_GAP + ICON_TEXT = 64 + 2 + 24 = 90, inside a <=100 px cell. */
#define ICON_SZ    64       /* icon fits within this box (system-default size) */
#define ICON_GAP    2       /* icon bottom -> label top */
#define ICON_TEXT  24       /* label band height */
#define ICON_CELL  96       /* grid cell pitch (<= 100) */
#define LABEL_PX   11       /* label glyph height (~half the previous 20) */

static gem_wm wm;
static theme  th;
static int    have_theme;

/* a window redraw: draw into win->backing (local coords) via its VDI handle */
static void win_redraw(gem_window *win, void *ud)
{
    vst_color(win->vh, 1);                 /* black */
    vst_height(win->vh, 36, NULL, NULL, NULL, NULL);   /* readable on the 1080p plane */
    v_gtext(win->vh, 24, 48, (const char *)ud);
}

/* Vertical gradient fallback backdrop (deep blue -> desktop blue). */
static void gradient(gfx_surface *wp)
{
    for (int y = 0; y < wp->h; y++) {
        int t = wp->h > 1 ? y * 255 / (wp->h - 1) : 0;
        uint8_t r = (uint8_t)(0x1a + (0x30 - 0x1a) * t / 255);
        uint8_t g = (uint8_t)(0x2a + (0x50 - 0x2a) * t / 255);
        uint8_t b = (uint8_t)(0x40 + (0x78 - 0x40) * t / 255);
        uint32_t c = GFX_RGB(r, g, b);
        uint32_t *row = wp->px + (size_t)y * wp->stride;
        for (int x = 0; x < wp->w; x++) row[x] = c;
    }
}

/* Read the one-line selector from "<dir>/Default" (the active theme/wallpaper
 * name), whitespace-trimmed. Returns 1 with `out` filled, 0 if absent/empty. */
static int read_default(const char *dir, char *out, int n)
{
    char path[160];
    snprintf(path, sizeof path, "%s/Default", dir);
    FILE *f = fopen(path, "r");
    out[0] = 0;
    if (!f) return 0;
    if (!fgets(out, n, f)) out[0] = 0;
    fclose(f);
    for (int i = (int)strlen(out) - 1; i >= 0 && (out[i] == '\n' || out[i] == '\r' ||
                 out[i] == ' ' || out[i] == '\t'); i--) out[i] = 0;
    return out[0] != 0;
}

/* Decode the user's wallpaper (named by /OS/wallpaper/Default) into the backdrop
 * buffer; fall back to a gradient if the SD isn't there or the file won't parse
 * (e.g. not a P6/P7 image, or not exactly plane-sized). */
static void load_wallpaper(gfx_surface *wp)
{
    char name[128], path[192];
    if (read_default("/OS/wallpaper", name, sizeof name)) {
        snprintf(path, sizeof path, "/OS/wallpaper/%s", name);
        if (img_load(path, wp)) return;
    }
    gradient(wp);
}

/* Composite one icon into the backdrop: scaled to fit the ICON_SZ band (aspect
 * preserved) and bottom-aligned in it, with a shadowed white label ICON_GAP px
 * below the actual icon pixels.  `cx` is the cell centre; `top` the cell top. */
static void place_icon(gfx_surface *wp, int wvh, const char *path, const char *label,
                       int cx, int top)
{
    int band_bottom = top + ICON_SZ;
    gfx_surface *raw = img_load(path, NULL);
    if (raw) {
        int dw = ICON_SZ, dh = ICON_SZ;
        if (raw->w >= raw->h) dh = raw->h * ICON_SZ / (raw->w ? raw->w : 1);
        else                  dw = raw->w * ICON_SZ / (raw->h ? raw->h : 1);
        if (dw < 1) dw = 1; if (dh < 1) dh = 1;
        gfx_surface *ic = img_scale(raw, dw, dh);
        gfx_surface_free(raw);
        if (ic) {
            img_blit_over(wp, cx - dw / 2, band_bottom - dh, ic);  /* bottom-aligned */
            gfx_surface_free(ic);
        }
    }
    if (wvh > 0 && label) {
        int ly = band_bottom + ICON_GAP;                 /* immediately under the icon */
        vst_height(wvh, LABEL_PX, NULL, NULL, NULL, NULL);
        vst_alignment(wvh, VDI_TA_CENTER, VDI_TA_TOP, NULL, NULL);
        vst_color(wvh, 1); v_gtext(wvh, cx + 1, ly + 1, label);   /* black shadow */
        vst_color(wvh, 0); v_gtext(wvh, cx,     ly,     label);   /* white text  */
        vst_alignment(wvh, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);  /* restore */
    }
}

/* Build the desktop backdrop into the OS wallpaper buffer: image/gradient, then
 * icons + labels baked in.  Returns the wallpaper surface (points at DDR). */
static void build_backdrop(gfx_surface *wp)
{
    load_wallpaper(wp);
    int wvh = v_opnvwk(wp);                 /* a workstation on the backdrop, for labels */
    int cx = 24 + ICON_SZ / 2, top = 32;    /* left column */
    place_icon(wp, wvh, "/OS/icons/xe.pam", "XE", cx, top);
    place_icon(wp, wvh, "/OS/icons/st.pam", "ST", cx, top + ICON_CELL);
    if (wvh > 0) v_clsvwk(wvh);
}

void _app_entry(int argc, char **argv)
{
    (void)argc; (void)argv;

    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) { sys_write(2, "desktop: no display plane\n", 26); return; }
    gfx_surface desk = { fb.w, fb.h, fb.stride, (uint32_t *)fb.addr };

    font_face *face = font_face_open("/OS/fonts/AovelSansRounded.ttf");
    if (!face) { sys_write(2, "desktop: font load FAILED\n", 26); return; }

    gem_wm_init(&wm, &desk, GFX_RGB(0x30, 0x50, 0x78));   /* desktop blue fallback */
    gem_wm_set_font(&wm, face);

    /* theme from SD: /OS/themes/<Default>/1x (baked .tex atlas + slices + ini) */
    char tname[64], tdir[160];
    if (read_default("/OS/themes", tname, sizeof tname)) {
        snprintf(tdir, sizeof tdir, "/OS/themes/%s/1x", tname);
        if (theme_load(&th, tdir) == 0) { gem_wm_set_theme(&wm, &th); have_theme = 1; }
    }
    if (!have_theme) {
        const char *m = "desktop: no SD theme in /OS/themes; skeleton chrome\n";
        sys_write(2, m, (unsigned)strlen(m));
    }

    /* backdrop in the OS-owned wallpaper DDR buffer (kept out of the 8 MB heap) */
    struct os_fbinfo wpi;
    if (sys_fb_wallpaper(&wpi) == 0 && wpi.addr) {
        static gfx_surface wp;
        wp.w = wpi.w; wp.h = wpi.h; wp.stride = wpi.stride; wp.px = (uint32_t *)wpi.addr;
        build_backdrop(&wp);
        gem_wm_set_wallpaper(&wm, &wp);
    }

    gem_window *w1 = gem_wm_add(&wm, 320, 150, 720, 480, "XTOS", 1);
    if (w1) gem_wm_set_redraw(w1, win_redraw, (void *)"Welcome to XTOS");
    gem_window *w2 = gem_wm_add(&wm, 980, 470, 760, 460, "GEM", 0);
    if (w2) gem_wm_set_redraw(w2, win_redraw, (void *)"Aristo2 desktop");

    gem_wm_draw(&wm);          /* redraw windows, themed frames, composite */
    sys_fb_present();          /* push the plane to the display */
    (void)have_theme;
}
