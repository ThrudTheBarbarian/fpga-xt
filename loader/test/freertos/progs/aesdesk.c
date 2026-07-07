/* /bin/aesdesk — the XTOS AES desktop on the A9 (the loader-side port of
 * gem/xtdesk.c, which is the same desktop on the SDL host testbed — keep the
 * two structurally aligned).
 *
 * Registry-driven desktop icons; double-click media icons to open ROOTED
 * folder browsers (/media/6502, /media/m68k) with per-type icons, Up
 * navigation and an info bar; double-click a media file to open its emulator
 * window loaded with the right boot method (D1:/CART/RUN — the 6502/m68k core
 * hookup behind the window is the next phase; the frame, machine and env are
 * real). libGEM.so (aes + wm + VDI + theme + img + FreeType) -> libc/libm.
 *
 * A9 specifics vs the host testbed: events come from SYS_input (the cursor is
 * a HW sprite moved kernel-side), frames are composited into the cacheable
 * back-buffer and blitted to the plane on present(), and directories are read
 * with sys_readdir/sys_stat (no opendir here — that's the toybox shim's).
 * Assets from the SD: theme /OS/themes/<Default>/1x, icons /OS/icons/*.pam,
 * registry /OS/var/registry.db; the font from /OS/fonts.
 */
#include "aes/aes.h"
#include "img.h"
#include "registry.h"
#include "font.h"
#include "usys.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define ICON_SZ 48
#define ICON_CW 100
#define ICON_CH (ICON_SZ + 26)
#define MAX_ICONS 32
#define DCLICK_MS 320

static int    HV, PW, PH;
static theme  TH;
static CICON  ci[MAX_ICONS];
static gfx_surface *isurf[MAX_ICONS];
static reg_desktop_icon rows[MAX_ICONS];
static OBJECT desk[1 + MAX_ICONS];
static int    n_icons;

static struct os_fbinfo g_fb;
static gfx_surface *g_bb;

static void present(void) {                        // blit the back-buffer to the plane
    uint32_t *plane = (uint32_t *)g_fb.addr;
    for (int y = 0; y < g_fb.h; y++)
        memcpy(plane + (size_t)y * g_fb.stride, g_bb->px + (size_t)y * g_bb->stride, (size_t)g_fb.w * 4);
    sys_fb_present();
}
static void repaint(void) { wind_redraw(); present(); }

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
    char p[200]; snprintf(p, sizeof p, "/OS/icons/%s", path);
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
static void clear_sel(void) { for (int i = 1; i <= n_icons; i++) desk[i].ob_state &= ~OS_SELECTED; }

static void deskcontent(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; (void)ud;
    aes_icon_label_style(1);                       // desktop: over the dark backdrop
    objc_draw(desk, 0, 2, wx, wy, ww, wh);
}

static void desk_click(int mx, int my);   // fwd

// ---- emulator window: a frame that envelops the emulation plane -------------
// The work area will be the compositor's emulation plane; until the core hookup
// lands it shows the machine + what was booted into it (same as the host stub).
#define MAXEMU 6
typedef struct { int used, win; char name[48], boot[96]; } emuwin;
static emuwin EMU[MAXEMU];
static int g_ex = 380, g_ey = 130;

// The live XL compositor plane binds to ONE 6502 window (first opened): the
// kernel places plane 1 over that window's work area (SYS_xl_window), and we
// re-place it whenever the window moves/resizes, hide it on close.  m68k
// windows stay placeholders (no core hosted yet).
#define XL_SCALE 2                      // 320x192 writeback -> 640x384 in the 672x480 work area
static int g_xlwin;                     // window handle owning the plane (0 = none)

static void xl_sync(void) {
    if (!g_xlwin) return;
    int x, y, w, h;
    wind_get(g_xlwin, WF_WORKXYWH, &x, &y, &w, &h);
    sys_xl_window(x, y, w, h, XL_SCALE);
}
static void xl_unbind(int win) {
    if (win != g_xlwin || !g_xlwin) return;
    sys_xl_window(0, 0, 0, 0, 0);       // hide the plane
    g_xlwin = 0;
}

static emuwin *emu_of_window(int win) {
    for (int i = 0; i < MAXEMU; i++) if (EMU[i].used && EMU[i].win == win) return &EMU[i];
    return NULL;
}
static const char *emu_machine(int type) { return type == ICT_EMU_1632 ? "m68k" : "6502"; }

static void emu_draw(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; emuwin *e = ud;
    vsf_color(HV, 1); vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0);   // the emulation plane (black)
    int16_t r[4] = { (int16_t)wx, (int16_t)wy, (int16_t)(wx+ww-1), (int16_t)(wy+wh-1) };
    vr_recfl(HV, r);
    vst_color(HV, 3); vst_alignment(HV, VDI_TA_CENTER, VDI_TA_HALF, 0,0);
    vst_height(HV, 22, 0,0,0,0);
    v_gtext(HV, wx+ww/2, wy+wh/2-16, e->name);                 // the machine
    vst_height(HV, 15, 0,0,0,0);
    v_gtext(HV, wx+ww/2, wy+wh/2+14, e->boot[0] ? e->boot : "READY.");   // what it booted
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
}
// Open an emulator window for `type` (ICT_EMU_*), optionally booted with `media`
// (the boot method already resolved into `boot`, e.g. "D1: game.atr").
static void open_emulator(int type, const char *media, const char *boot) {
    int s = -1; for (int i = 0; i < MAXEMU; i++) if (!EMU[i].used) { s = i; break; }
    if (s < 0) return;
    emuwin *e = &EMU[s]; memset(e, 0, sizeof *e); e->used = 1;
    snprintf(e->name, sizeof e->name, "%s", emu_machine(type));
    if (boot) snprintf(e->boot, sizeof e->boot, "%s", boot);
    int pw = (type == ICT_EMU_8BIT) ? 672 : 640;              // work area = the emulation plane
    int ph = (type == ICT_EMU_8BIT) ? 480 : 400;
    int bx, by, bw, bh;
    wind_calc(WC_BORDER, W_NAME|W_CLOSER|W_MOVER, g_ex, g_ey, pw, ph, &bx, &by, &bw, &bh);
    e->win = wind_create(W_NAME|W_CLOSER|W_MOVER, bx, by, bw, bh);
    if (!e->win) { e->used = 0; return; }
    char title[96];
    if (media) snprintf(title, sizeof title, "%s \xE2\x80\x94 %s", e->name, media);
    else       snprintf(title, sizeof title, "%s", e->name);
    wind_set_name(e->win, title); wind_content(e->win, emu_draw, e);
    wind_open(e->win, bx, by, bw, bh);
    g_ex += 34; g_ey += 30; if (g_ey > PH-320) { g_ex = 380; g_ey = 130; }
    if (type == ICT_EMU_8BIT && !g_xlwin) {   // frame the live 6502 plane here
        g_xlwin = e->win;
        xl_sync();
    }
}
// Launch a media file: pick the emulator by the browser's media type, and the
// boot method by extension (disk -> D1:/A:, cartridge -> CART, executable -> a
// dummy-env RUN), then open the emulator window loaded with it.
static void desk_launch(const char *name, int media_type) {
    int emu = (media_type == ICT_MEDIA_1632) ? ICT_EMU_1632 : ICT_EMU_8BIT;
    char ext[8] = ""; const char *dot = strrchr(name, '.');
    if (dot) { int i = 0; for (const char *p = dot+1; *p && i < 7; p++) ext[i++] = (char)tolower((unsigned char)*p); ext[i] = 0; }
    char boot[96];
    if (emu == ICT_EMU_8BIT) {
        if (!strcmp(ext,"atr")||!strcmp(ext,"atx")||!strcmp(ext,"xfd")) snprintf(boot,sizeof boot,"D1: %s",name);
        else if (!strcmp(ext,"rom")||!strcmp(ext,"car")||!strcmp(ext,"bin")) snprintf(boot,sizeof boot,"CART %s",name);
        else snprintf(boot,sizeof boot,"RUN %s",name);        // xex/exe -> dummy env
    } else {
        if (!strcmp(ext,"st")||!strcmp(ext,"msa")||!strcmp(ext,"dim")) snprintf(boot,sizeof boot,"A: %s",name);
        else snprintf(boot,sizeof boot,"RUN %s",name);        // prg/tos/app
    }
    open_emulator(emu, name, boot);
}

// ---- rooted folder browser -------------------------------------------------
#define MAXBR   6
#define MAXENT  96
typedef struct { char name[128], label[128]; int dir; long size; } bent;
typedef struct {
    int used, win, media_type, sel;
    char logical_root[128], fs_root[160], rel[256];   // rel = "" at the (rooted) top
    int nent, nfiles; long total;
    bent ent[MAXENT];
    gfx_surface *isurf[MAXENT];
    CICON  cic[MAXENT];
    OBJECT tree[1 + MAXENT];
    int wax, way, waw, wah;                            // last work area (for hit-testing)
    int infox, infoy, infow, infoh;                    // last W_INFO chrome rect
} browser;
static browser BR[MAXBR];
static int g_bx = 380, g_by = 130;

static browser *br_of_window(int win) {
    for (int i = 0; i < MAXBR; i++) if (BR[i].used && BR[i].win == win) return &BR[i];
    return NULL;
}
static void br_free_icons(browser *b) {
    for (int i = 0; i < b->nent; i++) if (b->isurf[i]) { gfx_surface_free(b->isurf[i]); b->isurf[i] = NULL; }
}
static void br_settitle(browser *b) {
    char t[400];
    if (b->rel[0]) snprintf(t, sizeof t, "%s/%s", b->logical_root, b->rel);
    else           snprintf(t, sizeof t, "%s", b->logical_root);
    wind_set_name(b->win, t);
}
static int ent_cmp(const void *a, const void *c) {
    const bent *x = a, *y = c;
    if (x->dir != y->dir) return y->dir - x->dir;     // folders first
    return strcasecmp(x->name, y->name);
}
// List the browser's current directory over the kernel VFS (sys_readdir gives
// the type; sys_stat only for file sizes).
static void br_list(browser *b) {
    br_free_icons(b);
    b->nent = 0; b->nfiles = 0; b->total = 0; b->sel = -1;
    char dir[420];
    if (b->rel[0]) snprintf(dir, sizeof dir, "%s/%s", b->fs_root, b->rel);
    else           snprintf(dir, sizeof dir, "%s", b->fs_root);
    static struct xt_dirent de;
    for (int idx = 0; b->nent < MAXENT && sys_readdir(dir, idx, &de) == 1; idx++) {
        if (de.name[0] == '.') continue;              // hidden + . ..
        bent *e = &b->ent[b->nent];
        snprintf(e->name, sizeof e->name, "%s", de.name);
        e->dir = (de.mode & XT_S_IFMT) == XT_S_IFDIR;
        e->size = 0;
        if (!e->dir) {
            char full[560]; struct xt_stat st;
            snprintf(full, sizeof full, "%s/%s", dir, de.name);
            if (sys_stat(full, &st) == 0) e->size = (long)st.size;
        }
        b->nent++;
    }
    qsort(b->ent, b->nent, sizeof(bent), ent_cmp);
    for (int i = 0; i < b->nent; i++) {
        bent *e = &b->ent[i];
        if (!e->dir) { b->nfiles++; b->total += e->size; }
        char ip[REG_PATH_MAX] = "", id[REG_NAME_MAX] = "";
        int t = e->dir ? ICT_FOLDER : b->media_type;
        if (!registry_match(e->name, t, ip, sizeof ip, id, sizeof id))
            if (e->dir || !registry_match(e->name, ICT_FILE, ip, sizeof ip, id, sizeof id)) ip[0] = 0;
        b->isurf[i] = ip[0] ? load_icon(ip) : NULL;
        snprintf(e->label, sizeof e->label, "%s", id[0] ? id : e->name);
        b->cic[i].img = b->isurf[i]; b->cic[i].text = e->label;
    }
}
// Lay the entry grid out in the current work area (also used for hit-testing).
static void br_layout(browser *b) {
    int pad = 14, cols = (b->waw - pad) / ICON_CW; if (cols < 1) cols = 1;
    b->tree[0] = (OBJECT){ NIL, b->nent?1:NIL, b->nent?b->nent:NIL, G_IBOX, OF_NONE, OS_NORMAL,
                           0, (int16_t)b->wax, (int16_t)b->way, (int16_t)b->waw, (int16_t)b->wah };
    for (int i = 0; i < b->nent; i++) {
        int oi = 1+i, last = (i == b->nent-1);
        int cx = pad + (i % cols) * ICON_CW;
        int cy = pad + (i / cols) * ICON_CH;
        b->tree[oi] = (OBJECT){ (int16_t)(last?0:oi+1), NIL, NIL, G_CICON,
                                (uint16_t)(OF_SELECTABLE | (last?OF_LASTOB:0)),
                                (uint16_t)(i == b->sel ? OS_SELECTED : OS_NORMAL),
                                &b->cic[i], (int16_t)cx, (int16_t)cy, ICON_CW, ICON_CH };
    }
}
// W_INFO chrome line: Up button (greyed at root) + file count / total size.
static void br_infobar(int hd, int ix, int iy, int iw, int ih, void *ud) {
    (void)hd; browser *b = ud;
    b->infox = ix; b->infoy = iy; b->infow = iw; b->infoh = ih;
    int upc = b->rel[0] ? 1 : 9;                              // greyed at the root
    int ax = ix+12, ay = iy+ih/2;
    vsf_color(HV, upc); vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0);
    int16_t tri[6] = { (int16_t)ax,(int16_t)(ay+5), (int16_t)(ax+5),(int16_t)(ay-5), (int16_t)(ax+10),(int16_t)(ay+5) };
    v_fillarea(HV, 3, tri);                                   // up-triangle
    vst_height(HV, 14, 0,0,0,0);
    vst_color(HV, upc); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
    v_gtext(HV, ax+18, ay, "Up");
    char info[64]; snprintf(info, sizeof info, "%d files, %ld KB", b->nfiles, (b->total+1023)/1024);
    vst_color(HV, 1); vst_alignment(HV, VDI_TA_RIGHT, VDI_TA_HALF, 0,0);
    v_gtext(HV, ix+iw-12, ay, info);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
}
static void br_content(int hd, int wax, int way, int waw, int wah, void *ud) {
    (void)hd; browser *b = ud;
    b->wax = wax; b->way = way; b->waw = waw; b->wah = wah;
    br_layout(b);
    aes_icon_label_style(0);                       // browser: over the light window
    objc_draw(b->tree, 0, 2, wax, way, waw, wah);
}
static int br_up_hit(browser *b, int mx, int my) {
    return b->rel[0] && mx >= b->infox+8 && mx < b->infox+70 && my >= b->infoy && my < b->infoy+b->infoh;
}
static void br_click(browser *b, int mx, int my) {
    if (br_up_hit(b, mx, my)) {                               // ascend (never above the root)
        char *s = strrchr(b->rel, '/'); if (s) *s = 0; else b->rel[0] = 0;
        br_list(b); br_settitle(b); repaint(); return;
    }
    int oi = objc_find(b->tree, 0, 2, mx, my);
    if (oi <= 0) { b->sel = -1; repaint(); return; }
    int i = oi-1, was = (b->sel == i);
    b->sel = i; repaint();
    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int w2 = wind_find(mx2, my2);
        if (w2 == b->win && objc_find(b->tree, 0, 2, mx2, my2) == oi) {   // double-click
            if (b->ent[i].dir) {                             // descend
                int n = (int)strlen(b->rel);
                snprintf(b->rel + n, sizeof b->rel - n, "%s%s", b->rel[0] ? "/" : "", b->ent[i].name);
                br_list(b); br_settitle(b); repaint();
            } else {                                         // launch the file in its emulator
                desk_launch(b->ent[i].name, b->media_type);
                repaint();
            }
            return;
        }
        if (w2 == b->win) br_click(b, mx2, my2);             // 2nd click elsewhere in-window
        else if (!w2)     desk_click(mx2, my2);
        return;
    }
    if (was) { b->sel = -1; repaint(); }                     // toggle off
}
static void open_browser(const char *logical, int media_type) {
    int s = -1; for (int i = 0; i < MAXBR; i++) if (!BR[i].used) { s = i; break; }
    if (s < 0) return;
    browser *b = &BR[s]; memset(b, 0, sizeof *b);
    b->used = 1; b->media_type = media_type; b->sel = -1;
    snprintf(b->logical_root, sizeof b->logical_root, "%s", logical);
    snprintf(b->fs_root, sizeof b->fs_root, "%s", logical);   // logical IS the SD path here
    int kind = W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER|W_INFO;
    int pw = 760, ph = 520, bx, by, bw, bh;
    wind_calc(WC_BORDER, kind, g_bx, g_by, pw, ph, &bx, &by, &bw, &bh);
    b->win = wind_create(kind, bx, by, bw, bh);
    if (!b->win) { b->used = 0; return; }
    br_list(b); br_settitle(b);
    wind_content(b->win, br_content, b);
    wind_info(b->win, br_infobar, b);
    wind_open(b->win, bx, by, bw, bh);
    g_bx += 34; g_by += 30; if (g_by > PH-320) { g_bx = 380; g_by = 130; }
}

// Dispatch a desktop icon by its registry type: emulators -> an emulator window,
// media -> a rooted browser at the matching /media volume (lowercase SD layout).
static void open_icon(int obj) {
    reg_desktop_icon *ri = &rows[obj-1];
    switch (ri->type) {
        case ICT_MEDIA_8BIT: open_browser("/media/6502", ICT_MEDIA_8BIT); break;
        case ICT_MEDIA_1632: open_browser("/media/m68k", ICT_MEDIA_1632); break;
        case ICT_EMU_8BIT: case ICT_EMU_1632:
        default:             open_emulator(ri->type ? ri->type : ICT_EMU_8BIT, NULL, NULL); break;
    }
}

// A desktop click (window frames were already handled inside evnt_multi).
static void desk_click(int mx, int my) {
    int obj = objc_find(desk, 0, 2, mx, my);
    if (obj <= 0) { clear_sel(); repaint(); return; }            // empty desktop
    int was_sel = desk[obj].ob_state & OS_SELECTED;
    clear_sel(); desk[obj].ob_state |= OS_SELECTED; repaint();   // immediate select

    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int obj2 = objc_find(desk, 0, 2, mx2, my2);
        if (obj2 == obj) { open_icon(obj); repaint(); return; }  // double-click -> open
        desk_click(mx2, my2); return;                            // 2nd click elsewhere
    }
    if (was_sel) { desk[obj].ob_state &= ~OS_SELECTED; repaint(); }  // toggle off
}

// ---- A9 event source: block for the next kernel input event ----------------
// (the cursor is a HW sprite moved kernel-side, so motion needs no present —
// only real actions repaint).
static int a9_events(aes_event *ev, int timeout_ms) {
    struct os_event oe = { OS_EV_TIMER, 0, 0, 0, 0, 0 };   // default if the syscall fails
    sys_input(&oe, timeout_ms);
    ev->type = oe.type; ev->mx = oe.mx; ev->my = oe.my;
    ev->button = oe.button; ev->key = oe.key; ev->shift = oe.shift;
    return ev->type;
}

void _app_entry(int argc, char **argv) {
    (void)argc; (void)argv;

    struct os_fbinfo fb;
    if (sys_fb_info(&fb) != 0) { sys_write(2, "aesdesk: no display plane\n", 26); return; }
    PW = fb.w; PH = fb.h;

    /* Composite into the reserved, cacheable WM back-buffer region (SYS_fb_wallpaper
     * -> WALLPAPER_BASE, mapped Normal-WB in the MMU) — fast alpha blending in the
     * D-cache — then blit it to the strided, non-cacheable plane once on present. */
    struct os_fbinfo wp;
    if (sys_fb_wallpaper(&wp) != 0 || !wp.addr) { sys_write(2, "aesdesk: no back-buffer\n", 24); return; }
    static gfx_surface bb_s;
    bb_s.w = wp.w; bb_s.h = wp.h; bb_s.stride = wp.stride; bb_s.px = (uint32_t *)wp.addr;
    g_fb = fb; g_bb = &bb_s;

    /* Prefer the SD font (/OS, user-overridable); fall back to the one bundled in
     * romfs (/System, always present — lets aesdesk run in qemu / on a card with no
     * fonts installed, instead of aborting at boot). */
    font_face *face = font_face_open("/OS/fonts/AovelSansRounded.ttf");
    if (!face) face = font_face_open("/System/fonts/AovelSansRounded.ttf");
    if (!face) { sys_write(2, "aesdesk: font load FAILED\n", 26); return; }
    vdi_init(g_bb); HV = v_opnvwk(g_bb);
    font_face_set_tracking(face, 1); vdi_set_face(face);

    char tn[64], td[160];
    if (read_default("/OS/themes", tn, sizeof tn)) snprintf(td, sizeof td, "/OS/themes/%s/1x", tn);
    else                                           snprintf(td, sizeof td, "/OS/themes/Aristo2/1x");
    /* SD theme first (user-overridable); fall back to the Aristo2 pack bundled in
     * romfs so aesdesk runs in qemu / on a card with no themes installed. */
    if (theme_load(&TH, td) != 0 &&
        theme_load(&TH, "/System/themes/Aristo2/1x") != 0) {
        sys_write(2, "aesdesk: theme load FAILED\n", 27); return;
    }
    aes_init(HV, &TH); appl_init();
    wind_set_desktop(0x30507800u);

    if (registry_open("/OS/var/registry.db") != 0)
        sys_write(2, "aesdesk: no registry (/OS/var/registry.db)\n", 43);
    build_desktop();
    wind_set_desktop_content(deskcontent, NULL);

    aes_set_events(a9_events);
    repaint();                                       // initial frame

    for (;;) {                                       // interactive loop
        int mx, my, mb, ks, key, nc; int16_t msg[8];
        int r = evnt_multi(MU_MESAG|MU_KEYBD|MU_BUTTON, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, msg, 0,0,
                           &mx, &my, &mb, &ks, &key, &nc);
        if ((r & MU_KEYBD) && key == 0x1b) break;                              // Esc quits
        if ((r & MU_MESAG) && msg[0] == WM_CLOSED) {
            browser *b = br_of_window(msg[3]); if (b) { br_free_icons(b); b->used = 0; }
            emuwin *e = emu_of_window(msg[3]); if (e) e->used = 0;
            xl_unbind(msg[3]);
            wind_close(msg[3]); repaint();
        }
        if ((r & MU_MESAG) && (msg[0] == WM_MOVED || msg[0] == WM_SIZED) && msg[3] == g_xlwin)
            xl_sync();                                   // keep the plane on the work area
        if (r & MU_BUTTON) {
            int wh = wind_find(mx, my); browser *b = wh ? br_of_window(wh) : NULL;
            if (b) br_click(b, mx, my); else desk_click(mx, my);
        }
    }
    registry_close();
}
