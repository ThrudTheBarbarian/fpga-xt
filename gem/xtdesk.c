// xtdesk.c — the XTOS desktop on the SDL host testbed.  A themed AES desktop with
// a wallpaper and desktop icons driven entirely by the registry
// (/OS/var/registry.db, desktopIcons): each row gives a position, an iconTypes id,
// an icon bitmap and a displayName.  Icons are clickable G_CICON objects —
// single-click selects/toggles the highlight, double-click opens a (stub) window.
// Everything runs through the real AES, so this is the same logic that will run on
// the A9 once an input backend exists.
//
// Assets load from a base OS dir (argv positional, default the mounted SD
// /Volumes/XTOS/OS) mirroring the A9 layout.  The desktop is 1920x1080 (the plane
// size); SDL renders it scaled-to-fit any window via a logical size.
// `xtdesk --ppm` renders one frame to /tmp/xtdesk.ppm (no SDL).

#include "aes/aes_internal.h"
#include "img.h"
#include "registry.h"
#include "font.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <dirent.h>
#include <sys/stat.h>
#include <SDL2/SDL.h>

#define WIN_W 1920
#define WIN_H 1080
#define ICON_SZ  48          // system-default icon size (up to 128 src, scaled)
#define ICON_CW  100         // icon cell width
#define ICON_CH  (ICON_SZ + 26)
#define DCLICK_MS 320
#define MAX_ICONS 64

// `base` mirrors the runtime root "/" (the SD mount): system assets live under
// /OS, user content under /Media — exactly as on the A9 (SD = fatfs root).
static char base[256] = "/Volumes/XTOS";
static theme TH;
static gfx_surface *g_desk, *g_wall;
static int HV;

// desktop object tree: an invisible root (index 0) + one G_CICON per registry row
static OBJECT desk[1 + MAX_ICONS];
static CICON  cic[MAX_ICONS];
static gfx_surface *csurf[MAX_ICONS];
static reg_desktop_icon rows[MAX_ICONS];
static int n_icons;
#define ROOT 0

static int read_default(const char *dir, char *out, int n) {
    char p[320]; snprintf(p, sizeof p, "%s/Default", dir);
    FILE *f = fopen(p, "r"); out[0] = 0;
    if (!f) return 0;
    if (!fgets(out, n, f)) out[0] = 0;
    fclose(f);
    for (int i = (int)strlen(out)-1; i >= 0 && (out[i]=='\n'||out[i]=='\r'||out[i]==' '||out[i]=='\t'); i--) out[i] = 0;
    return out[0] != 0;
}

static int load_theme(void) {
    char name[64], dir[420], td[320];
    snprintf(td, sizeof td, "%s/OS/Themes", base);
    if (read_default(td, name, sizeof name)) {
        snprintf(dir, sizeof dir, "%s/OS/Themes/%s/1x", base, name);
        if (theme_load(&TH, dir) == 0) return 1;
    }
    return theme_load(&TH, "themes/Aristo2/1x") == 0;   // repo fallback
}

// Load an icon named by a registry path (relative to /OS/Icons), scaled to fit
// ICON_SZ (aspect preserved).  Tries the SD, then the repo icons/<path>, then the
// repo icons/<basename> — so the testbed shows something even without the card.
static gfx_surface *load_icon(const char *path) {
    char p[440];
    snprintf(p, sizeof p, "%s/OS/Icons/%s", base, path);
    gfx_surface *raw = img_load(p, NULL);
    if (!raw) { snprintf(p, sizeof p, "icons/%s", path); raw = img_load(p, NULL); }
    if (!raw) { const char *b = strrchr(path, '/'); b = b ? b+1 : path;
                snprintf(p, sizeof p, "icons/%s", b); raw = img_load(p, NULL); }
    if (!raw) return NULL;
    int dw = ICON_SZ, dh = ICON_SZ;
    if (raw->w >= raw->h) dh = raw->h * ICON_SZ / (raw->w ? raw->w : 1);
    else                  dw = raw->w * ICON_SZ / (raw->h ? raw->h : 1);
    if (dw < 1) dw = 1; if (dh < 1) dh = 1;
    gfx_surface *ic = img_scale(raw, dw, dh);
    gfx_surface_free(raw);
    return ic;
}

static gfx_surface *make_gradient(void) {
    gfx_surface *s = gfx_surface_alloc(WIN_W, WIN_H);
    if (!s) return NULL;
    for (int y = 0; y < WIN_H; y++) {
        int t = WIN_H > 1 ? y*255/(WIN_H-1) : 0;
        uint8_t r = (uint8_t)(0x1a + (0x30-0x1a)*t/255);
        uint8_t g = (uint8_t)(0x2a + (0x50-0x2a)*t/255);
        uint8_t b = (uint8_t)(0x40 + (0x78-0x40)*t/255);
        uint32_t c = GFX_RGBA(r, g, b, 0xFF);
        for (int x = 0; x < WIN_W; x++) s->px[(size_t)y*s->stride + x] = c;
    }
    return s;
}

static void load_wall(void) {
    char name[64], p[440], d[320];
    snprintf(d, sizeof d, "%s/OS/Wallpaper", base);
    if (read_default(d, name, sizeof name)) {
        snprintf(p, sizeof p, "%s/OS/Wallpaper/%s", base, name);
        g_wall = img_load(p, NULL);
    }
    if (!g_wall) g_wall = make_gradient();      // repo fallback
}

// Build the desktop object tree from the registry's desktopIcons rows.
static void build_desktop(void) {
    n_icons = registry_desktop_icons(rows, MAX_ICONS);
    if (n_icons < 0) n_icons = 0;
    desk[ROOT] = (OBJECT){ NIL, n_icons ? 1 : NIL, n_icons ? n_icons : NIL,
                           G_IBOX, OF_NONE, OS_NORMAL, 0, 0, 0, WIN_W, WIN_H };
    for (int i = 0; i < n_icons; i++) {
        csurf[i]   = load_icon(rows[i].path);
        cic[i].img = csurf[i];
        cic[i].text = rows[i].displayName[0] ? rows[i].displayName : NULL;
        int oi = 1 + i;
        int last = (i == n_icons - 1);
        desk[oi] = (OBJECT){ (int16_t)(last ? ROOT : oi+1), NIL, NIL, G_CICON,
                             (uint16_t)(OF_SELECTABLE | (last ? OF_LASTOB : 0)), OS_NORMAL,
                             &cic[i], (int16_t)rows[i].x, (int16_t)rows[i].y, ICON_CW, ICON_CH };
    }
}

static void clear_sel(void) { for (int i = 1; i <= n_icons; i++) desk[i].ob_state &= ~OS_SELECTED; }

static void deskcontent(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; (void)ud;
    if (g_wall) {
        MFDB m; mfdb_from_surface(&m, g_wall);
        int16_t pxy[8] = { 0, 0, (int16_t)(g_wall->w-1), (int16_t)(g_wall->h-1),
                           (int16_t)wx, (int16_t)wy, (int16_t)(wx+ww-1), (int16_t)(wy+wh-1) };
        vr_transfer_bits(HV, &m, NULL, pxy, VR_OVER);
    }
    aes_icon_label_style(1);                       // desktop: over the wallpaper (dark)
    objc_draw(desk, ROOT, 2, wx, wy, ww, wh);
}

static void desk_click(int mx, int my);   // fwd

// ---- emulator window: a frame that envelops the emulation plane -------------
// On the A9 the work area is the compositor's emulation plane; here it's a stub
// that shows the machine + what was booted into it.
#define MAXEMU 6
typedef struct { int used, win; char name[48], boot[96]; } emuwin;
static emuwin EMU[MAXEMU];
static int g_ex = 380, g_ey = 130;

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
    g_ex += 34; g_ey += 30; if (g_ey > WIN_H-320) { g_ex = 380; g_ey = 130; }
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
#define MAXENT  128
typedef struct { char name[128], label[128]; int dir; long size; } bent;
typedef struct {
    int used, win, media_type, sel;
    char logical_root[128], fs_root[300], rel[256];   // rel = "" at the (rooted) top
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
static void br_list(browser *b) {
    br_free_icons(b);
    b->nent = 0; b->nfiles = 0; b->total = 0; b->sel = -1;
    char dir[400];
    if (b->rel[0]) snprintf(dir, sizeof dir, "%s/%s", b->fs_root, b->rel);
    else           snprintf(dir, sizeof dir, "%s", b->fs_root);
    DIR *d = opendir(dir);
    if (d) {
        struct dirent *de;
        while ((de = readdir(d)) && b->nent < MAXENT) {
            if (de->d_name[0] == '.') continue;       // hidden + . ..
            bent *e = &b->ent[b->nent];
            snprintf(e->name, sizeof e->name, "%s", de->d_name);
            char full[560]; snprintf(full, sizeof full, "%s/%s", dir, de->d_name);
            struct stat stt; e->dir = 0; e->size = 0;
            if (stat(full, &stt) == 0) { e->dir = S_ISDIR(stt.st_mode); e->size = (long)stt.st_size; }
            b->nent++;
        }
        closedir(d);
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
        br_list(b); br_settitle(b); wind_redraw(); return;
    }
    int oi = objc_find(b->tree, 0, 2, mx, my);
    if (oi <= 0) { b->sel = -1; wind_redraw(); return; }
    int i = oi-1, was = (b->sel == i);
    b->sel = i; wind_redraw();
    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int w2 = wind_find(mx2, my2);
        if (w2 == b->win && objc_find(b->tree, 0, 2, mx2, my2) == oi) {   // double-click
            if (b->ent[i].dir) {                             // descend
                int n = (int)strlen(b->rel);
                snprintf(b->rel + n, sizeof b->rel - n, "%s%s", b->rel[0] ? "/" : "", b->ent[i].name);
                br_list(b); br_settitle(b); wind_redraw();
            } else {                                         // launch the file in its emulator
                desk_launch(b->ent[i].name, b->media_type);
            }
            return;
        }
        if (w2 == b->win) br_click(b, mx2, my2);             // 2nd click elsewhere in-window
        else if (!w2)     desk_click(mx2, my2);
        return;
    }
    if (was) { b->sel = -1; wind_redraw(); }                 // toggle off
}
static void open_browser(const char *logical, int media_type) {
    int s = -1; for (int i = 0; i < MAXBR; i++) if (!BR[i].used) { s = i; break; }
    if (s < 0) return;
    browser *b = &BR[s]; memset(b, 0, sizeof *b);
    b->used = 1; b->media_type = media_type; b->sel = -1;
    snprintf(b->logical_root, sizeof b->logical_root, "%s", logical);
    snprintf(b->fs_root, sizeof b->fs_root, "%s%s", base, logical);
    int kind = W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER|W_INFO;
    int pw = 760, ph = 520, bx, by, bw, bh;
    wind_calc(WC_BORDER, kind, g_bx, g_by, pw, ph, &bx, &by, &bw, &bh);
    b->win = wind_create(kind, bx, by, bw, bh);
    if (!b->win) { b->used = 0; return; }
    br_list(b); br_settitle(b);
    wind_content(b->win, br_content, b);
    wind_info(b->win, br_infobar, b);
    wind_open(b->win, bx, by, bw, bh);
    g_bx += 34; g_by += 30; if (g_by > WIN_H-320) { g_bx = 380; g_by = 130; }
}

// Dispatch a desktop icon by its registry type: emulators -> an emulator window,
// media -> a rooted browser rooted at the matching /Media volume.
static void open_icon(int obj) {
    reg_desktop_icon *ri = &rows[obj-1];
    switch (ri->type) {
        case ICT_MEDIA_8BIT: open_browser("/Media/6502", ICT_MEDIA_8BIT); break;
        case ICT_MEDIA_1632: open_browser("/Media/m68k", ICT_MEDIA_1632); break;
        case ICT_EMU_8BIT: case ICT_EMU_1632:
        default:             open_emulator(ri->type ? ri->type : ICT_EMU_8BIT, NULL, NULL); break;
    }
}

// A desktop click (window frames + menus were already handled inside evnt_multi).
static void desk_click(int mx, int my) {
    int obj = objc_find(desk, ROOT, 2, mx, my);
    if (obj <= ROOT) { clear_sel(); wind_redraw(); return; }     // empty desktop
    int was_sel = desk[obj].ob_state & OS_SELECTED;
    clear_sel(); desk[obj].ob_state |= OS_SELECTED; wind_redraw();  // immediate select

    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int obj2 = objc_find(desk, ROOT, 2, mx2, my2);
        if (obj2 == obj) { open_icon(obj); return; }              // double-click -> open
        desk_click(mx2, my2); return;                             // 2nd click elsewhere
    }
    if (was_sel) { desk[obj].ob_state &= ~OS_SELECTED; wind_redraw(); }  // toggle off
}

static void dump_ppm(const char *path) {
    FILE *f = fopen(path, "wb"); if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", WIN_W, WIN_H);
    for (int i = 0; i < WIN_W*WIN_H; i++) {
        uint32_t v = g_desk->px[i];
        unsigned char c[3] = { (unsigned char)(v>>24), (unsigned char)(v>>16), (unsigned char)(v>>8) };
        fwrite(c, 1, 3, f);
    }
    fclose(f);
}

static SDL_Renderer *g_ren; static SDL_Texture *g_tex; static int g_btn;
static int present_and_wait(aes_event *ev, int timeout_ms) {
    SDL_UpdateTexture(g_tex, NULL, g_desk->px, g_desk->stride*(int)sizeof(uint32_t));
    SDL_SetRenderDrawColor(g_ren,0,0,0,255); SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, NULL); SDL_RenderPresent(g_ren);   // logical size scales it
    SDL_Event e;
    int got=(timeout_ms<0)?SDL_WaitEvent(&e):SDL_WaitEventTimeout(&e,timeout_ms);
    ev->button=g_btn; if(!got){ ev->type=AES_TIMER; return AES_TIMER; }
    do { switch(e.type){
        case SDL_QUIT: ev->type=AES_QUIT; return AES_QUIT;
        case SDL_KEYDOWN: if(e.key.keysym.sym==SDLK_ESCAPE){ ev->type=AES_QUIT; return AES_QUIT; }
            ev->type=AES_KEY; ev->key=(e.key.keysym.sym==SDLK_RETURN?'\r':(int)e.key.keysym.sym); return AES_KEY;
        case SDL_MOUSEMOTION: ev->type=AES_MOTION; ev->mx=e.motion.x; ev->my=e.motion.y; return AES_MOTION;
        case SDL_MOUSEBUTTONDOWN: if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn|=1; ev->button=g_btn; ev->type=AES_BTN_DOWN; ev->mx=e.button.x; ev->my=e.button.y; return AES_BTN_DOWN;
        case SDL_MOUSEBUTTONUP: if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn&=~1; ev->button=g_btn; ev->type=AES_BTN_UP; ev->mx=e.button.x; ev->my=e.button.y; return AES_BTN_UP;
    }} while(SDL_PollEvent(&e));
    ev->type=AES_NONE; return AES_NONE;
}

int main(int argc, char **argv) {
    int ppm = 0, sel = 0, browse = 0;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--ppm")) ppm = 1;
        else if (!strcmp(argv[i], "--sel")) sel = 1;      // headless: pre-select the first icon
        else if (!strcmp(argv[i], "--browse")) browse = 1;// headless: open the 8-bit browser
        else if (!strcmp(argv[i], "--launch")) browse = 2;// headless: browser + a launched game
        else snprintf(base, sizeof base, "%s", argv[i]);
    }

    g_desk = gfx_surface_alloc(WIN_W, WIN_H);
    vdi_init(g_desk); HV = v_opnvwk(g_desk);
    font_face *ff = font_face_open("fonts/AovelSansRounded.ttf");
    if (ff) font_face_set_tracking(ff, 1);
    vdi_set_face(ff);
    if (!load_theme()) { fprintf(stderr, "xtdesk: theme load failed (make themepack, or pass an OS dir)\n"); return 1; }
    aes_init(HV, &TH); appl_init();
    wind_set_desktop(0x30507800u);

    { char dbp[320]; snprintf(dbp, sizeof dbp, "%s/OS/var/registry.db", base);
      if (registry_open(dbp) != 0) fprintf(stderr, "xtdesk: no registry at %s\n", dbp); }
    load_wall();
    build_desktop();
    wind_set_desktop_content(deskcontent, NULL);
    if (sel && n_icons) desk[1].ob_state |= OS_SELECTED;
    if (browse) { open_browser("/Media/6502/Games", ICT_MEDIA_8BIT); if (sel) BR[0].sel = 0; }
    if (browse == 2) desk_launch("River Raid.atr", ICT_MEDIA_8BIT);
    wind_redraw();

    if (ppm) { dump_ppm("/tmp/xtdesk.ppm"); registry_close(); return 0; }

    if (SDL_Init(SDL_INIT_VIDEO)!=0) { fprintf(stderr,"SDL: %s\n",SDL_GetError()); return 1; }
    SDL_Window *win = SDL_CreateWindow("XTOS Desktop", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIN_W, WIN_H, SDL_WINDOW_RESIZABLE);
    g_ren = SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    SDL_RenderSetLogicalSize(g_ren, WIN_W, WIN_H);   // 1920x1080 logical, scaled to the window
    g_tex = SDL_CreateTexture(g_ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    aes_set_events(present_and_wait);

    for (;;) {
        int mx,my,mb,ks,key,nc; int16_t msg[8];
        int r = evnt_multi(MU_MESAG|MU_KEYBD|MU_BUTTON, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, msg,0,0, &mx,&my,&mb,&ks,&key,&nc);
        if (r & MU_QUIT) break;
        if (r & MU_MESAG && msg[0]==WM_CLOSED) {
            browser *b = br_of_window(msg[3]); if (b) { br_free_icons(b); b->used = 0; }
            emuwin *e = emu_of_window(msg[3]); if (e) e->used = 0;
            wind_close(msg[3]);
        }
        if (r & MU_BUTTON) {
            int wh = wind_find(mx, my); browser *b = wh ? br_of_window(wh) : NULL;
            if (b) br_click(b, mx, my); else desk_click(mx, my);
        }
    }

    registry_close();
    theme_free(&TH); if (ff) font_face_close(ff);
    if (g_wall) gfx_surface_free(g_wall);
    gfx_surface_free(g_desk);
    SDL_DestroyTexture(g_tex); SDL_DestroyRenderer(g_ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
