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
#include "aes/rscload.h"
#include "img.h"
#include "registry.h"
#include "fujiclient.h"
#include "font.h"
#include <sqlite3.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include <dirent.h>
#include <unistd.h>
#include <sys/stat.h>
#include <SDL2/SDL.h>

#define WIN_W 1920
#define WIN_H 1080
#define ICON_SZ  48          // system-default icon size (up to 128 src, scaled)
#define ICON_CW  100         // icon cell width
#define ICON_CH  (ICON_SZ + 26)
#define TEXT_ROWH 20         // text-view row height (single/multi column)
#define TEXT_COLW 220        // multi-column text: target column width
#define BR_TEXT_SEL 250      // theme selection background (aes object.c PEN_SEL)
#define DCLICK_MS 320
#define MAX_ICONS 64

// `base` mirrors the runtime root "/" (the SD mount): system assets live under
// /OS, user content under /Media — exactly as on the A9 (SD = fatfs root).
static char base[256] = "/Volumes/XTOS";
static rscdoc *g_rsc;                                  // desktop.rsc dialogs (New…, …); NULL = built-ins
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
// Three flavours share the struct + window plumbing: net=0 a local directory,
// net=1 the FujiNet servers window (one tile per registry server + "Add
// server"), net=2 a network browser over fujinetd (rel = the remote path).
#define MAXBR   6
#define MAXENT  128
#define MAX_CRUMB 18                                  // breadcrumb: <root> + up to ~16 path segments
#define BR_WKIND (W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER|W_INFO)   // browser-window kind
typedef struct { char name[128], label[128]; int dir; long size, mtime;
                 char state; int srvid; } bent;     // state: lsc cache column; srvid: servers row (-1 = Add server)
typedef struct {
    int used, win, media_type, sel;
    int net, server_id;                               // net browser flavour (see above)
    char logical_root[128], fs_root[300], rel[256];   // rel = "" at the (rooted) top
    int nent, nfiles; long total;
    int req_fd, req_kind, req_hdr;                     // async fujinetd request (req_fd < 0 = idle)
    unsigned prog_done, prog_total;                    // fetch progress (pump-updated)
    char prog_name[64];                                // fetch display name
    int req_total;                                     // lsc entry count from "+ok <n>" (-1 = unknown)
    unsigned prog_phase;                               // listing spinner tick (indeterminate bar)
    unsigned prog_stall;                               // pumps since the last reply line (watchdog)
    char req_err[96];                                  // last async error (shown in the info bar)
    bent ent[MAXENT];
    gfx_surface *isurf[MAXENT];
    CICON  cic[MAXENT];
    OBJECT tree[2 + MAXENT];                           // + the synthetic ".." tile
    int wax, way, waw, wah;                            // last work area (for hit-testing)
    int infox, infoy, infow, infoh;                    // last W_INFO chrome rect
    int titlex, titley, titlew, titleh;                // last interactive-title work rect
    int retryx, retryw;                                // Retry button rect in the info bar (error state)
    int fitx, fitw;                                    // Fit button rect in the info bar (path windows)
    int viewx, vieww;                                  // View button rect (cycles the view mode)
    int maskx, maskw;                                  // file-mask span rect (in the title)
    int viewmode;                                      // 1=icons grid, 2=single-col text, 3=multi-col text
    int sortmode, sortinv;                             // 1 unsorted/2 name/3 type/4 size/5 date; sortinv reverses
    int selall;                                        // context-menu "select all": highlight every entry
    char mask[32];                                     // per-window file mask ("*"/"*.*"/"" = show all)
    int ncrumb;                                        // breadcrumb span count (0 = none drawn)
    int crumbx[MAX_CRUMB], crumbw[MAX_CRUMB];          // per-segment hit rects (in the title)
    int crumbcut[MAX_CRUMB];                           // strlen to truncate crumbpath to on a segment click
    char crumbpath[400];                               // full absolute logical path the crumbs were built from
} browser;
static browser BR[MAXBR];
static int g_bx = 380, g_by = 130;

// The synthetic ".." up-entry that leads a non-root browser's icon grid: a
// single shared folder icon (ICT_FOLDER) + ".." label, built once on demand.
static gfx_surface *g_dotsurf;
static CICON g_dotcic;
static void ensure_doticon(void) {
    if (g_dotcic.text) return;                         // already built
    char ip[REG_PATH_MAX] = "", id[REG_NAME_MAX] = "";
    if (registry_match("..", ICT_FOLDER, ip, sizeof ip, id, sizeof id) && ip[0])
        g_dotsurf = load_icon(ip);
    g_dotcic.img = g_dotsurf; g_dotcic.text = "..";
}

static browser *br_of_window(int win) {
    for (int i = 0; i < MAXBR; i++) if (BR[i].used && BR[i].win == win) return &BR[i];
    return NULL;
}
// The default view mode for a new browser window: deskPrefs 'viewMode' (1=icons,
// 2=single-col text, 3=multi-col text), falling back to icons.
static int default_viewmode(void) {
    char v[16]; registry_pref("viewMode", "1", v, sizeof v);
    int m = atoi(v); return (m >= 1 && m <= 3) ? m : 1;
}
// deskPrefs sort defaults (sortMode 1..5, sortInverted 0/1) for a new window.
static int default_sortmode(void) {
    char v[16]; registry_pref("sortMode", "2", v, sizeof v);
    int m = atoi(v); return (m >= 1 && m <= 5) ? m : 2;
}
static int default_sortinv(void) {
    char v[16]; registry_pref("sortInverted", "0", v, sizeof v); return atoi(v) ? 1 : 0;
}
static void br_free_icons(browser *b) {
    for (int i = 0; i < b->nent; i++) if (b->isurf[i]) { gfx_surface_free(b->isurf[i]); b->isurf[i] = NULL; }
}
// Case-insensitive glob match: '*' matches any run (incl. empty), '?' one char.
static int glob_ci(const char *pat, const char *s) {
    while (*pat) {
        if (*pat == '*') {
            while (*pat == '*') pat++;                 // collapse a run of '*'
            if (!*pat) return 1;                       // trailing '*' matches the rest
            for (; *s; s++) if (glob_ci(pat, s)) return 1;
            return glob_ci(pat, s);                    // also try the empty tail
        }
        if (!*s) return 0;
        if (*pat != '?' && tolower((unsigned char)*pat) != tolower((unsigned char)*s)) return 0;
        pat++; s++;
    }
    return *s == 0;
}
// "*", "*.*" and "" all mean "show everything".
static int br_show_all(const char *m) {
    return !m[0] || !strcmp(m, "*") || !strcmp(m, "*.*");
}
// A directory (and the synthetic "..") is always shown; a file must match the mask.
static int br_visible(browser *b, const char *name, int isdir) {
    return isdir || br_show_all(b->mask) || glob_ci(b->mask, name);
}
static void br_settitle(browser *b) {
    char t[400];
    if (b->rel[0]) snprintf(t, sizeof t, "%s/%s", b->logical_root, b->rel);
    else           snprintf(t, sizeof t, "%s", b->logical_root);
    if (!br_show_all(b->mask)) {                        // show the active filter in the title
        int n = (int)strlen(t); snprintf(t + n, sizeof t - n, "  (%s)", b->mask);
    }
    wind_set_name(b->win, t);
}
// Active sort key (set from the browser before every qsort — qsort has no
// context arg): 2 name / 3 type (extension) / 4 size / 5 date; 1 unsorted keeps
// only the dirs-first grouping.  g_sort_inv reverses within the group.
static int g_sort_mode = 2, g_sort_inv = 0;
static const char *ext_of(const char *n) { const char *d = strrchr(n, '.'); return d ? d + 1 : ""; }
static int ent_cmp(const void *a, const void *c) {
    const bent *x = a, *y = c; int r;
    if (x->dir != y->dir) return y->dir - x->dir;     // folders always first
    switch (g_sort_mode) {
        case 1:  r = 0; break;                                                    // unsorted
        case 3:  r = strcasecmp(ext_of(x->name), ext_of(y->name));
                 if (!r) r = strcasecmp(x->name, y->name); break;                 // type
        case 4:  r = (x->size  < y->size)  ? -1 : (x->size  > y->size)  ? 1 : 0;
                 if (!r) r = strcasecmp(x->name, y->name); break;                 // size
        case 5:  r = (x->mtime < y->mtime) ? -1 : (x->mtime > y->mtime) ? 1 : 0;
                 if (!r) r = strcasecmp(x->name, y->name); break;                 // date
        default: r = strcasecmp(x->name, y->name); break;                         // name
    }
    return g_sort_inv ? -r : r;
}
// ---- FujiNet listings (fujiclient.c talks to fujinetd; the daemon does the
// TNFS + registry/netcache work).  All daemon I/O is ASYNC: *_start sends the
// command on a non-blocking fd and returns; net_pump() (driven from the event
// loop) feeds reply lines back in as they arrive, so the UI never blocks on
// the daemon (single-threaded, one client at a time — a reply can sit behind
// another window's transfer for minutes). ------------------------------------
enum { RQ_NONE = 0, RQ_SRV, RQ_LSC, RQ_FETCH, RQ_ADD };   // browser.req_kind
// net_pump ticks ~40ms while a request is pending; a request that goes fully
// silent for this many pumps (~20s) is declared dead by the watchdog.
#define NET_WATCHDOG_TICKS 500
static void br_info_redraw(browser *b);               // fwd (contacting/progress feedback)

static void net_req_close(browser *b) {               // idle the request slot (also = cancel)
    if (b->req_fd >= 0) fuji_close(b->req_fd);
    b->req_fd = -1; b->req_kind = RQ_NONE;
}
static void srv_row(browser *b, const char *ln) {     // one `servers` reply row -> a tile
    if (b->nent >= MAXENT-1 || ln[0] == '-') return;
    int sid, off = 0; char tr[16], hp[160], pa[160];   // "<id> <udp|tcp|auto> <host>:<port> <path> <name…>"
    if (sscanf(ln, "%d %15s %159s %159s %n", &sid, tr, hp, pa, &off) < 4) return;
    bent *e = &b->ent[b->nent++];
    snprintf(e->name, sizeof e->name, "%s", ln[off] ? ln + off : hp);
    e->dir = 1; e->size = 0; e->state = 0; e->srvid = sid;
}
static void srv_finish(browser *b) {                  // rows all in: Add tile + icons
    bent *a = &b->ent[b->nent++];                     // trailing "Add server" tile
    snprintf(a->name, sizeof a->name, "Add server");
    a->dir = 0; a->size = 0; a->state = 0; a->srvid = -1;
    for (int i = 0; i < b->nent; i++) {
        bent *e = &b->ent[i];
        char ip[REG_PATH_MAX] = "", id[REG_NAME_MAX] = "";
        if (!registry_match(e->srvid < 0 ? "Add server" : "Server",
                            e->srvid < 0 ? ICT_ADD_SERVER : ICT_SERVER,
                            ip, sizeof ip, id, sizeof id)) ip[0] = 0;
        b->isurf[i] = ip[0] ? load_icon(ip) : NULL;
        snprintf(e->label, sizeof e->label, "%s", e->name);
        b->cic[i].img = b->isurf[i]; b->cic[i].text = e->label;
    }
}
static void srv_list_start(browser *b) {              // one tile per `servers` row + "Add server"
    br_free_icons(b);
    b->nent = 0; b->nfiles = 0; b->total = 0; b->sel = -1;
    b->req_err[0] = 0; b->req_hdr = 0;
    b->prog_phase = 0; b->prog_stall = 0;             // fresh contacting bounce + watchdog
    int fd = fuji_connect();
    if (fd < 0 || fuji_cmd(fd, "servers") != 0) {     // no daemon: just the Add tile
        if (fd >= 0) fuji_close(fd);
        snprintf(b->req_err, sizeof b->req_err, "daemon not running");
        srv_finish(b);
        return;
    }
    fuji_set_nonblock(fd);
    b->req_fd = fd; b->req_kind = RQ_SRV;             // net_pump takes it from here
    if (b->infow > 0) br_info_redraw(b);              // instant contacting feedback (replaces desk_busy)
}

static void net_row(browser *b, const char *ln) {     // one `lsc` reply row -> an entry
    if (b->nent >= MAXENT || ln[0] == '-') return;
    char kind, cs; long size; int off = 0;            // "d <size> - <name>" | "f <size> <g|f|c|u> <name>"
    if (sscanf(ln, " %c %ld %c %n", &kind, &size, &cs, &off) < 3 || !ln[off]) return;
    if (!br_visible(b, ln + off, kind == 'd')) return; // masked file (dirs always shown)
    bent *e = &b->ent[b->nent++];
    snprintf(e->name, sizeof e->name, "%s", ln + off);
    e->dir = (kind == 'd'); e->size = size;
    e->state = e->dir ? 0 : cs; e->srvid = 0;
    b->cic[b->nent-1].img = NULL;                      // live fill: text label now,
    b->cic[b->nent-1].text = e->name;                  // sorted icons on completion
}
static void net_finish(browser *b) {                  // rows all in: sort + icons
    g_sort_mode = b->sortmode; g_sort_inv = b->sortinv;
    qsort(b->ent, b->nent, sizeof(bent), ent_cmp);
    for (int i = 0; i < b->nent; i++) {
        bent *e = &b->ent[i];
        if (!e->dir) { b->nfiles++; b->total += e->size; }
        char ip[REG_PATH_MAX] = "", id[REG_NAME_MAX] = "";
        int t = e->dir ? ICT_FOLDER : b->media_type;
        if (!registry_match(e->name, t, ip, sizeof ip, id, sizeof id))
            if (e->dir || !registry_match(e->name, ICT_FILE, ip, sizeof ip, id, sizeof id)) ip[0] = 0;
        b->isurf[i] = ip[0] ? load_icon(ip) : NULL;
        if (b->isurf[i] && (e->state == 'g' || e->state == 'f')) {   // uncached -> ghosted icon
            gfx_surface *gs = icon_ghost(b->isurf[i]);
            if (gs) { gfx_surface_free(b->isurf[i]); b->isurf[i] = gs; }
        }
        snprintf(e->label, sizeof e->label, "%s", id[0] ? id : e->name);
        b->cic[i].img = b->isurf[i]; b->cic[i].text = e->label;
    }
}
static void net_list_start(browser *b) {              // entries from `lsc <server> <path>`
    br_free_icons(b);
    b->nent = 0; b->nfiles = 0; b->total = 0; b->sel = -1;
    b->req_err[0] = 0; b->req_hdr = 0;
    b->req_total = -1; b->prog_phase = 0;             // count unknown until the +ok header
    b->prog_stall = 0;                                // reset the listing watchdog
    char path[300]; snprintf(path, sizeof path, "/%s", b->rel);
    int fd = fuji_connect();
    if (fd < 0 || fuji_cmd(fd, "lsc %d \"%s\"", b->server_id, path) != 0) {
        if (fd >= 0) fuji_close(fd);
        snprintf(b->req_err, sizeof b->req_err, "daemon not running");
        net_finish(b);
        return;
    }
    fuji_set_nonblock(fd);
    b->req_fd = fd; b->req_kind = RQ_LSC;             // net_pump takes it from here
    if (b->infow > 0) br_info_redraw(b);              // instant contacting feedback (replaces desk_busy)
}
static void br_list(browser *b) {
    if (b->net == 1) { srv_list_start(b); return; }   // FujiNet flavours (async)
    if (b->net == 2) { net_list_start(b); return; }
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
            struct stat stt; e->dir = 0; e->size = 0; e->mtime = 0; e->state = 0; e->srvid = 0;
            if (stat(full, &stt) == 0) { e->dir = S_ISDIR(stt.st_mode); e->size = (long)stt.st_size;
                                         e->mtime = (long)stt.st_mtime; }
            if (!br_visible(b, de->d_name, e->dir)) continue;   // masked file (dirs always shown)
            b->nent++;
        }
        closedir(d);
    }
    g_sort_mode = b->sortmode; g_sort_inv = b->sortinv;
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
    int dd = b->rel[0] ? 1 : 0;                        // synthetic ".." leads a non-root grid
    int ntile = b->nent + dd;
    b->tree[0] = (OBJECT){ NIL, ntile?1:NIL, ntile?ntile:NIL, G_IBOX, OF_NONE, OS_NORMAL,
                           0, (int16_t)b->wax, (int16_t)b->way, (int16_t)b->waw, (int16_t)b->wah };
    if (dd) {                                          // ".." tile at grid slot 0
        ensure_doticon();
        int last = (b->nent == 0);
        b->tree[1] = (OBJECT){ (int16_t)(last?0:2), NIL, NIL, G_CICON,
                               (uint16_t)(OF_SELECTABLE | (last?OF_LASTOB:0)), OS_NORMAL,
                               &g_dotcic, (int16_t)pad, (int16_t)pad, ICON_CW, ICON_CH };
    }
    for (int i = 0; i < b->nent; i++) {
        int oi = 1+dd+i, last = (i == b->nent-1), slot = i + dd;
        int cx = pad + (slot % cols) * ICON_CW;
        int cy = pad + (slot / cols) * ICON_CH;
        int ghost = (b->ent[i].state == 'g' || b->ent[i].state == 'f');   // uncached net entry
        b->tree[oi] = (OBJECT){ (int16_t)(last?0:oi+1), NIL, NIL, G_CICON,
                                (uint16_t)(OF_SELECTABLE | (last?OF_LASTOB:0)),
                                (uint16_t)(((i == b->sel || b->selall) ? OS_SELECTED : OS_NORMAL) | (ghost ? OS_DISABLED : 0)),
                                &b->cic[i], (int16_t)cx, (int16_t)cy, ICON_CW, ICON_CH };
    }
}
static int br_textw(const char *s);                   // fwd (defined with the info-bar helpers)
// Compact human-readable size ("512", "13K", "4M") for the text-view size column.
static void br_fmt_size(long sz, char *out, int cap) {
    if (sz < 1000)           snprintf(out, cap, "%ld", sz);
    else if (sz < 1000*1000) snprintf(out, cap, "%ldK", (sz + 512) / 1024);
    else                     snprintf(out, cap, "%ldM", (sz + 524288) / (1024*1024));
}
// Text-view geometry (viewmode 2/3): columns (single=1; multi=work_width/COLW,
// min 1 — recomputed every call so a resize reflows), rows-per-column (newspaper
// flow: fill a column top-to-bottom then step right), and the per-column pixel
// width.  ntile counts the synthetic ".." tile.  cols/rpc/colw/ntile are optional.
static void br_text_grid(browser *b, int *cols, int *rpc, int *colw, int *ntile) {
    int pad = 14, dd = b->rel[0] ? 1 : 0, nt = b->nent + dd;
    int avail = b->waw - 2*pad; if (avail < 40) avail = 40;
    int c = 1;
    if (b->viewmode == 3) { c = avail / TEXT_COLW; if (c < 1) c = 1; }
    int rows = ((nt < 1 ? 1 : nt) + c - 1) / c; if (rows < 1) rows = 1;
    if (cols)  *cols  = c;
    if (rpc)   *rpc   = rows;
    if (colw)  *colw  = avail / c;
    if (ntile) *ntile = nt;
}
// Pixel cell rect for text-view tile `slot` (0..ntile-1, slot 0 = ".." when present).
static void br_text_cell(browser *b, int slot, int *x, int *y, int *w, int *h) {
    int pad = 14, cols, rpc, colw, nt; br_text_grid(b, &cols, &rpc, &colw, &nt);
    int col = slot / rpc, row = slot % rpc;
    *x = b->wax + pad + col * colw;
    *y = b->way + pad + row * TEXT_ROWH;
    *w = colw; *h = TEXT_ROWH;
}
// Reverse of br_text_cell: the tile slot under (mx,my), or -1 for a miss.
static int br_text_hit(browser *b, int mx, int my) {
    int pad = 14, cols, rpc, colw, nt; br_text_grid(b, &cols, &rpc, &colw, &nt);
    if (nt <= 0) return -1;
    int lx = mx - (b->wax + pad), ly = my - (b->way + pad);
    if (lx < 0 || ly < 0) return -1;
    int col = lx / colw, row = ly / TEXT_ROWH;
    if (col < 0 || col >= cols || row < 0 || row >= rpc) return -1;
    int slot = col * rpc + row;
    return (slot >= 0 && slot < nt) ? slot : -1;
}
// Draw the entries as one-line text rows (viewmode 2 single / 3 multi): name left,
// size right-aligned per cell (dirs / ".." -> "<dir>").  The selected row gets a
// PEN_SEL fill.  Geometry mirrors br_text_cell so br_click resolves the same slot.
static void br_draw_text(browser *b) {
    int dd = b->rel[0] ? 1 : 0, nt = b->nent + dd;
    vst_height(HV, 14, 0,0,0,0);
    for (int slot = 0; slot < nt; slot++) {
        int cx, cy, cw, ch; br_text_cell(b, slot, &cx, &cy, &cw, &ch);
        int isdot = (dd && slot == 0), i = slot - dd;
        int sel   = (!isdot && (i == b->sel || b->selall));
        int ghost = (!isdot && (b->ent[i].state == 'g' || b->ent[i].state == 'f'));
        if (sel) {                                          // selection highlight bar
            vsf_color(HV, BR_TEXT_SEL); vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0);
            int16_t r[4] = { (int16_t)cx, (int16_t)cy, (int16_t)(cx+cw-2), (int16_t)(cy+ch-1) };
            vr_recfl(HV, r);
        }
        const char *nm = isdot ? ".." : (b->ent[i].label[0] ? b->ent[i].label : b->ent[i].name);
        char szbuf[24];
        if (isdot || b->ent[i].dir) snprintf(szbuf, sizeof szbuf, "<dir>");
        else                        br_fmt_size(b->ent[i].size, szbuf, sizeof szbuf);
        int szw = br_textw(szbuf), pen = ghost ? 9 : 1;
        char lbl[128];
        aes_label_fit(HV, nm, cw - szw - 18, lbl, sizeof lbl);   // leave room for the size
        vst_color(HV, pen); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
        v_gtext(HV, cx + 6, cy + ch/2, lbl);
        vst_alignment(HV, VDI_TA_RIGHT, VDI_TA_HALF, 0,0);
        v_gtext(HV, cx + cw - 8, cy + ch/2, szbuf);
    }
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
}
// Graphical progress indicator drawn straight into the info bar — the old
// (removed) net_progress modal box style, relocated: a grey track (disabled
// pen 9) with a solid fill (pen 1) and a thin outline.  Determinate fills
// done/total; indeterminate sweeps a ~30%-wide block left<->right off the
// caller's triangle-wave phase.  Geometry is pixels within the info rect.
static void br_progbar(int x, int y, int w, int h, int determinate,
                       unsigned done, unsigned total, unsigned phase) {
    if (w < 8) return;
    vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0);
    int16_t tr[4] = { (int16_t)x, (int16_t)y, (int16_t)(x+w-1), (int16_t)(y+h-1) };
    vsf_color(HV, 9); vr_recfl(HV, tr);                       // grey track (trough)
    if (determinate) {
        int tot = total ? (int)total : 1;
        int fill = (int)((long long)w * done / tot);
        if (fill > w) fill = w; if (fill < 0) fill = 0;
        if (fill > 0) {
            int16_t fr[4] = { (int16_t)x, (int16_t)y, (int16_t)(x+fill-1), (int16_t)(y+h-1) };
            vsf_color(HV, 1); vr_recfl(HV, fr);               // filled portion
        }
    } else {                                                  // bouncing ~30%-wide block
        int bw = w * 3 / 10; if (bw < 6) bw = 6;
        int span = w - bw; if (span < 1) span = 1;
        int ph = (int)(phase % 14);                           // 0..7..0 triangle wave
        int t = ph < 7 ? ph : 14 - ph;                        // block sweeps + returns
        int bx = x + span * t / 7;
        int16_t fr[4] = { (int16_t)bx, (int16_t)y, (int16_t)(bx+bw-1), (int16_t)(y+h-1) };
        vsf_color(HV, 1); vr_recfl(HV, fr);                   // moving block
    }
    vsl_color(HV, 1); vsl_width(HV, 1);                       // thin outline
    int16_t o[10] = { (int16_t)x,(int16_t)y, (int16_t)(x+w-1),(int16_t)y,
                      (int16_t)(x+w-1),(int16_t)(y+h-1), (int16_t)x,(int16_t)(y+h-1),
                      (int16_t)x,(int16_t)y };
    v_pline(HV, 5, o);
}
static int br_textw(const char *s) {                  // width of s in the current font/size
    int16_t e[8]; vqt_extent(HV, s, e); return e[2] - e[0];
}
// Interactive window TITLE (wind_title draw fn): the FULL absolute logical path
// as individually-clickable segments, then the file-mask as its own clickable
// span — e.g. "/Media/6502/*.*".  The path = logical_root joined with rel, so
// EVERY absolute level is clickable (incl. ancestors above the window's open
// root).  Records a hit rect (crumbx/crumbw) + the crumbpath truncation length
// (crumbcut) per drawn segment, and the mask rect (maskx/maskw).  Overflow
// middle-ellipsises the path at segment granularity (first + "…" + the tail that
// fits) while always keeping the mask, so the recorded rects stay correct.
static void br_title(int hd, int tx, int ty, int tw, int th, void *ud) {
    (void)hd; browser *b = ud;
    b->titlex = tx; b->titley = ty; b->titlew = tw; b->titleh = th;
    b->ncrumb = 0; b->maskx = 0; b->maskw = 0;
    if (b->rel[0]) snprintf(b->crumbpath, sizeof b->crumbpath, "%s/%s", b->logical_root, b->rel);
    else           snprintf(b->crumbpath, sizeof b->crumbpath, "%s", b->logical_root);
    char masktext[40];
    snprintf(masktext, sizeof masktext, "%s", br_show_all(b->mask) ? "*.*" : b->mask);
    vst_height(HV, 15, 0,0,0,0);
    vst_color(HV, 1); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
    int ay = ty + th/2;
    // Split crumbpath into components; cut[k] = strlen to truncate crumbpath to.
    char seg[MAX_CRUMB][80]; int cut[MAX_CRUMB], segw[MAX_CRUMB], nseg = 0;
    for (int i = 0; b->crumbpath[i] && nseg < MAX_CRUMB; ) {
        while (b->crumbpath[i] == '/') i++;               // skip separators (incl. a leading '/')
        if (!b->crumbpath[i]) break;
        int j = i; while (b->crumbpath[j] && b->crumbpath[j] != '/') j++;
        int len = j - i; if (len > 79) len = 79;
        memcpy(seg[nseg], b->crumbpath + i, len); seg[nseg][len] = 0;
        cut[nseg] = j; nseg++; i = j;
    }
    int sepw = br_textw("/"), ellw = br_textw("...");
    int lead = (b->crumbpath[0] == '/') ? sepw : 0;       // draw a leading '/' for absolute paths
    int maskw = br_textw(masktext), maskspace = sepw + maskw;
    int pathavail = tw - maskspace - 6;                   // reserve the mask span at the right
    for (int k = 0; k < nseg; k++) segw[k] = br_textw(seg[k]);
    int need = lead;
    for (int k = 0; k < nseg; k++) need += segw[k] + (k ? sepw : 0);
    int t = 1;                                            // suffix start after an elided middle (1 = all)
    if (pathavail > 0 && need > pathavail && nseg > 2) {
        for (t = 2; t < nseg; t++) {
            int w = lead + segw[0] + sepw + ellw;
            for (int k = t; k < nseg; k++) w += sepw + segw[k];
            if (w <= pathavail) break;
        }
        if (t >= nseg) t = nseg - 1;                      // always keep first + last
    }
    int x = tx;
    if (lead) { v_gtext(HV, x, ay, "/"); x += sepw; }
    if (nseg > 0) {
        v_gtext(HV, x, ay, seg[0]);
        b->crumbx[b->ncrumb] = x; b->crumbw[b->ncrumb] = segw[0]; b->crumbcut[b->ncrumb] = cut[0]; b->ncrumb++;
        x += segw[0];
    }
    if (t > 1) { v_gtext(HV, x, ay, "/"); x += sepw; v_gtext(HV, x, ay, "..."); x += ellw; }
    for (int k = (t > 1 ? t : 1); k < nseg; k++) {
        v_gtext(HV, x, ay, "/"); x += sepw;
        v_gtext(HV, x, ay, seg[k]);
        if (b->ncrumb < MAX_CRUMB) {
            b->crumbx[b->ncrumb] = x; b->crumbw[b->ncrumb] = segw[k]; b->crumbcut[b->ncrumb] = cut[k]; b->ncrumb++;
        }
        x += segw[k];
    }
    v_gtext(HV, x, ay, "/"); x += sepw;                   // mask span (own clickable rect)
    b->maskx = x; b->maskw = maskw;
    v_gtext(HV, x, ay, masktext);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
}
// Navigate the window to an absolute logical path (a clicked title segment).
// Within the current root it just re-points rel; an ancestor above the root
// re-roots the local window there (rel="") — so ANY level is reachable.  A
// network (net!=0) root is the server top, so its crumbs are always within it
// (rel-relative) and never re-root.  fs_root is rebuilt as open_browser_win
// does (base + logical here).
static void br_list(browser *b);                          // fwd
static void br_navigate(browser *b, const char *abspath) {
    size_t rl = strlen(b->logical_root);
    if (strncmp(abspath, b->logical_root, rl) == 0 && (abspath[rl] == '/' || abspath[rl] == 0)) {
        const char *r = abspath + rl; while (*r == '/') r++;   // within the current root
        snprintf(b->rel, sizeof b->rel, "%s", r);
    } else if (b->net == 0) {                             // ancestor above the open root: re-root
        snprintf(b->logical_root, sizeof b->logical_root, "%s", abspath);
        snprintf(b->fs_root, sizeof b->fs_root, "%s%s", base, abspath);
        b->rel[0] = 0;
    } else return;                                        // network: nothing above the server root
    br_list(b); br_settitle(b); wind_redraw();
}
// Fit the window to its current icon-grid contents: enough columns for
// min(nEntries, 8) × ICON_CW wide and the resulting rows × ICON_CH tall (the
// ".." tile counts), plus the title + info chrome (wind_calc).  Clamped to 80%
// of the screen and a sane minimum, top-left fixed, kept on-screen.
static void br_fit(browser *b) {
    int dd = b->rel[0] ? 1 : 0, ntile = b->nent + dd; if (ntile < 1) ntile = 1;
    int pad = 14, maxcols = 8;
    int cols = ntile < maxcols ? ntile : maxcols; if (cols < 1) cols = 1;
    int nrows = (ntile + cols - 1) / cols;
    int cw = 2*pad + cols * ICON_CW, chh = 2*pad + nrows * ICON_CH;   // desired work-area size
    int cx, cy, cw0, ch0; wind_get(b->win, WF_CURRXYWH, &cx, &cy, &cw0, &ch0);
    int bx, by, bw, bh;
    wind_calc(WC_BORDER, BR_WKIND, cx, cy, cw, chh, &bx, &by, &bw, &bh);   // + chrome
    int maxw = 8*WIN_W/10, maxh = 8*WIN_H/10;             // clamp to 80% of the screen
    if (bw > maxw) bw = maxw; if (bh > maxh) bh = maxh;
    if (cx + bw > WIN_W) bw = WIN_W - cx;                 // keep on-screen (top-left fixed)
    if (cy + bh > WIN_H) bh = WIN_H - cy;
    int minw = 280, minh = 200;                           // sane minimum
    if (bw < minw) bw = minw; if (bh < minh) bh = minh;
    wind_open(b->win, cx, cy, bw, bh);                    // already open: resizes in place
    wind_redraw();
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
    char info[96];
    int irx = ix+iw-12;                                      // right edge of the info text
    b->retryx = 0; b->retryw = 0;                            // no Retry button unless in the error state
    b->fitx = 0; b->fitw = 0;                                // Fit recorded only when drawn
    b->viewx = 0; b->vieww = 0;                             // View button recorded only when drawn
    int drewbar = 0, drewleft = 0;                          // active states draw a graphical bar; idle draws left status
    int pw = 120, pbh = 10;                                  // progress track: 120x10, vertically centred
    int pby = iy + (ih - pbh)/2;
    int pbx = ix + iw - 12 - pw;                             // right-anchored, before the right margin
    // Fit button (path windows, no request in flight — the bar owns the right
    // side while a request is): far right, before the margin.
    if (b->net != 1 && b->req_fd < 0) {
        vst_height(HV, 14, 0,0,0,0);
        b->fitw = br_textw("Fit") + 14; b->fitx = ix + iw - 12 - b->fitw;
        vst_color(HV, 1); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
        v_gtext(HV, b->fitx + 7, ay, "Fit");
        irx = b->fitx - 12;                                  // keep other content clear of the button
    }
    // View button (all browsers incl. servers; hidden while a request owns the
    // right side): cycles icons -> single -> multi.  Sits left of Fit.
    if (b->req_fd < 0) {
        const char *vl = b->viewmode == 2 ? "View: List"
                       : b->viewmode == 3 ? "View: Cols" : "View: Icons";
        vst_height(HV, 14, 0,0,0,0);
        b->vieww = br_textw(vl) + 14; b->viewx = irx - b->vieww;
        vst_color(HV, 1); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
        v_gtext(HV, b->viewx + 7, ay, vl);
        irx = b->viewx - 12;                                 // keep other content clear of the button
    }
    // (The file mask + the path breadcrumb now live in the interactive window
    // TITLE — see br_title; the info bar keeps Up / View / Fit / progress /
    // Retry and, when idle, the file-count status on the left.)
    if (b->req_fd >= 0 && b->req_kind == RQ_FETCH) {          // fetch in flight: label + determinate bar
        unsigned pc = b->prog_total
                    ? (unsigned)((unsigned long long)b->prog_done * 100 / b->prog_total) : 0;
        if (pc > 100) pc = 100;
        snprintf(info, sizeof info, "Fetching %.40s %u%%", b->prog_name, pc);
        br_progbar(pbx, pby, pw, pbh, 1, b->prog_done, b->prog_total, 0);
        drewbar = 1;
    }
    else if (b->req_fd >= 0 && (b->req_kind == RQ_LSC || b->req_kind == RQ_SRV)) {  // listing in flight
        if (!b->req_hdr) {                                   // contacting: indeterminate (header not in yet)
            snprintf(info, sizeof info, "Contacting %.40s", b->logical_root);
            br_progbar(pbx, pby, pw, pbh, 0, 0, 0, b->prog_phase);
        } else if (b->req_kind == RQ_LSC && b->req_total >= 0) {   // determinate: rows/total
            snprintf(info, sizeof info, "Listing %d/%d", b->nent, b->req_total);
            br_progbar(pbx, pby, pw, pbh, 1, (unsigned)b->nent,
                       (unsigned)(b->req_total > 0 ? b->req_total : 1), 0);
        } else {                                             // indeterminate: a bouncing block
            snprintf(info, sizeof info, "Listing %d", b->nent);
            br_progbar(pbx, pby, pw, pbh, 0, 0, 0, b->prog_phase);
        }
        drewbar = 1;
    }
    else if (b->req_err[0]) {                                 // last async request failed: msg + Retry
        snprintf(info, sizeof info, "Error: %.80s", b->req_err);
        b->retryw = 58; b->retryx = irx - b->retryw;         // clickable Retry button, left of Fit
        vst_height(HV, 14, 0,0,0,0);
        vst_color(HV, 1); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
        v_gtext(HV, b->retryx, ay, "Retry");
        irx = b->retryx-12;                                  // keep the error text clear of the button
    }
    else if (b->net == 1)                                     // servers window (minus the Add tile)
        snprintf(info, sizeof info, "%d servers", b->nent ? b->nent-1 : 0);
    else {                                                    // path window (net 0/2), idle: file-count status
        char sz[16]; br_fmt_size(b->total, sz, sizeof sz);
        snprintf(info, sizeof info, "%d items, %d files  %s", b->nent, b->nfiles, sz);
        vst_height(HV, 14, 0,0,0,0);
        vst_color(HV, 1); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
        v_gtext(HV, ix+72, ay, info);                        // left status, after the Up button
        drewleft = 1;
    }
    if (!drewleft) {
        vst_color(HV, 1); vst_alignment(HV, VDI_TA_RIGHT, VDI_TA_HALF, 0,0);
        v_gtext(HV, drewbar ? pbx-8 : irx, ay, info);        // active: label to the LEFT of the bar
    }
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
}
static void br_content(int hd, int wax, int way, int waw, int wah, void *ud) {
    (void)hd; browser *b = ud;
    b->wax = wax; b->way = way; b->waw = waw; b->wah = wah;
    // A listing lays out the partial/empty list as it fills (rows arrive live);
    // the info bar carries the single contacting -> progress indicator.  A fetch
    // keeps the existing list on screen and shows progress in the info bar too.
    aes_icon_label_style(0);                       // browser: over the light window
    if (b->viewmode == 2 || b->viewmode == 3) { br_draw_text(b); return; }
    br_layout(b);                                  // viewmode 1: the icon grid
    objc_draw(b->tree, 0, 2, wax, way, waw, wah);
}
// Repaint ONLY the info bar (per fetch-progress line): chrome fill + divider +
// br_infobar + flush — no full-window redraw per tick.  Drawn straight to the
// screen; the next full redraw repaints it anyway.
static void br_info_redraw(browser *b) {
    if (!b->used || b->infow <= 0) return;
    int ix = b->infox, iy = b->infoy, iw = b->infow, ih = b->infoh;
    vsf_color(HV, 248); vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0);   // PEN_DLG chrome
    int16_t ir[4] = { (int16_t)ix, (int16_t)iy, (int16_t)(ix+iw-1), (int16_t)(iy+ih-1) };
    vr_recfl(HV, ir);
    vsl_color(HV, 249); vsl_width(HV, 1);                                        // PEN_BORDER divider
    int16_t il[4] = { (int16_t)ix, (int16_t)(iy+ih-1), (int16_t)(ix+iw-1), (int16_t)(iy+ih-1) };
    v_pline(HV, 2, il);
    br_infobar(HV, ix, iy, iw, ih, b);
    aes_flush_rect(ix, iy, iw, ih);
}
static int br_up_hit(browser *b, int mx, int my) {
    return b->rel[0] && mx >= b->infox+8 && mx < b->infox+70 && my >= b->infoy && my < b->infoy+b->infoh;
}
static void open_fuji_browser(int server_id, const char *name);   // fwd

// Async netcache fetch: send `fetch` and return; the pump streams "+progress"
// into the info bar, "+ok" triggers an async re-list (the entry solidifies)
// and "-err" alerts (the re-list reverts the entry).  Closing the window
// cancels: the daemon sees the dead socket and aborts the transfer.
static void net_fetch_start(browser *b, const char *remote, const char *name) {
    int fd = fuji_connect();
    if (fd < 0) { form_alert(1, "[3][FujiNet daemon not running|(boot script 40-FujiNet)][OK]"); return; }
    if (fuji_cmd(fd, "fetch %d \"%s\"", b->server_id, remote) != 0) {
        fuji_close(fd);
        form_alert(1, "[3][Fetch failed|daemon connection lost][OK]");
        return;
    }
    fuji_set_nonblock(fd);
    b->req_fd = fd; b->req_kind = RQ_FETCH; b->req_hdr = 0;
    b->prog_done = 0; b->prog_total = 0; b->prog_stall = 0;   // reset the transfer watchdog
    snprintf(b->prog_name, sizeof b->prog_name, "%s", name);
    b->req_err[0] = 0;
    br_info_redraw(b);                                        // instant "Fetching ..." feedback
}
// Open a network file: cached -> launch its /Cache mirror; ghost (or a cache
// row whose file went missing) -> async fetch first.
static void net_open(browser *b, int i) {
    bent *e = &b->ent[i];
    char remote[420];
    if (b->rel[0]) snprintf(remote, sizeof remote, "/%s/%s", b->rel, e->name);
    else           snprintf(remote, sizeof remote, "/%s", e->name);
    if (e->state == 'c' || e->state == 'u') {
        char local[720]; struct stat stt;                     // <base>/Cache/<id><remote> (the daemon's mirror)
        snprintf(local, sizeof local, "%s/Cache/%d%s", base, b->server_id, remote);
        if (stat(local, &stt) == 0) { desk_launch(e->name, b->media_type); return; }
    }
    net_fetch_start(b, remote, e->name);
}
// ---- Add Server dialog (the "Add server" tile; form_do consumer #1) ---------
// host[:port] + transport radio + mount path + display name; OK (default) sends
// `add-server` through the servers browser's async request slot, Cancel /
// Esc-Esc backs out.  Movable (OF_MOVEABLE fly corner), mnemonics auto-assign.
enum { AS_ROOT, AS_TITLE, AS_LHOST, AS_FHOST, AS_LTRAN, AS_RUDP, AS_RTCP,
       AS_RAUTO, AS_LPATH, AS_FPATH, AS_LNAME, AS_FNAME, AS_CANCEL, AS_OK, AS_N };
#define AS_W 480
#define AS_H 246
static char as_host[64], as_path[64], as_name[48];
static char as_tmpl[35];                              // 34 input positions ('_' run)
static TEDINFO as_thost = { .te_ptext = as_host, .te_ptmplt = as_tmpl, .te_pvalid = "P", .te_txtlen = sizeof as_host, .te_just = TE_LEFT };
static TEDINFO as_tpath = { .te_ptext = as_path, .te_ptmplt = as_tmpl, .te_pvalid = "P", .te_txtlen = sizeof as_path, .te_just = TE_LEFT };
static TEDINFO as_tname = { .te_ptext = as_name, .te_ptmplt = as_tmpl, .te_pvalid = "X", .te_txtlen = sizeof as_name, .te_just = TE_LEFT };
static OBJECT as_dlg[AS_N] = {
 /*ROOT  */ { NIL, AS_TITLE, AS_OK, G_BOX, OF_MOVEABLE, OS_NORMAL, 0, 0,0, AS_W, AS_H },
 /*TITLE */ { AS_LHOST,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Add FujiNet server",  20,12, 440,20 },
 /*LHOST */ { AS_FHOST,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Host:",               20,50, 88,20 },
 /*FHOST */ { AS_LTRAN,  NIL,NIL, G_FTEXT,  OF_EDITABLE, OS_NORMAL, &as_thost,               116,47, 340,26 },
 /*LTRAN */ { AS_RUDP,   NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Transport:",          20,86, 88,20 },
 /*RUDP  */ { AS_RTCP,   NIL,NIL, G_RADIO,  OF_SELECTABLE|OF_RBUTTON, OS_NORMAL, (void*)"udp",  116,84, 70,20 },
 /*RTCP  */ { AS_RAUTO,  NIL,NIL, G_RADIO,  OF_SELECTABLE|OF_RBUTTON, OS_NORMAL, (void*)"tcp",  196,84, 70,20 },
 /*RAUTO */ { AS_LPATH,  NIL,NIL, G_RADIO,  OF_SELECTABLE|OF_RBUTTON, OS_SELECTED, (void*)"auto", 276,84, 80,20 },
 /*LPATH */ { AS_FPATH,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Path:",               20,122, 88,20 },
 /*FPATH */ { AS_LNAME,  NIL,NIL, G_FTEXT,  OF_EDITABLE, OS_NORMAL, &as_tpath,               116,119, 340,26 },
 /*LNAME */ { AS_FNAME,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Name:",               20,158, 88,20 },
 /*FNAME */ { AS_CANCEL, NIL,NIL, G_FTEXT,  OF_EDITABLE, OS_NORMAL, &as_tname,               116,155, 340,26 },
 /*CANCEL*/ { AS_OK,     NIL,NIL, G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_CANCEL, OS_NORMAL, (void*)"Cancel", 252,196, 100,32 },
 /*OK    */ { AS_ROOT,   NIL,NIL, G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_DEFAULT|OF_LASTOB, OS_NORMAL, (void*)"OK", 364,196, 92,32 },
};
static void add_server_dialog(browser *b) {           // b = the servers browser
    as_host[0] = 0; as_name[0] = 0;
    snprintf(as_path, sizeof as_path, "/");
    memset(as_tmpl, '_', sizeof as_tmpl - 1); as_tmpl[sizeof as_tmpl - 1] = 0;
    as_dlg[AS_RUDP].ob_state &= ~OS_SELECTED;
    as_dlg[AS_RTCP].ob_state &= ~OS_SELECTED;
    as_dlg[AS_RAUTO].ob_state |= OS_SELECTED;         // default transport: auto
    int r = form_do_dialog(as_dlg, 0);                // focus starts in Host
    if (r >= 0) as_dlg[r].ob_state &= ~OS_SELECTED;   // release for the next run
    if (r != AS_OK || !as_host[0]) return;
    const char *tr = (as_dlg[AS_RUDP].ob_state & OS_SELECTED) ? "udp"
                   : (as_dlg[AS_RTCP].ob_state & OS_SELECTED) ? "tcp" : "auto";
    int fd = fuji_connect();
    if (fd < 0) { form_alert(1, "[3][FujiNet daemon not running|(boot script 40-FujiNet)][OK]"); return; }
    if (fuji_cmd(fd, "add-server \"%s\" %s \"%s\" \"%s\"",
                 as_host, tr, as_path[0] ? as_path : "/", as_name) != 0) {
        fuji_close(fd);
        form_alert(1, "[3][Add server failed|daemon connection lost][OK]");
        return;
    }
    fuji_set_nonblock(fd);
    b->req_fd = fd; b->req_kind = RQ_ADD; b->req_hdr = 0;   // net_pump takes it from here
    b->prog_stall = 0;                                     // reset the request watchdog
}

// ---- Set-filter dialog (the info-bar "Filter" button; form_do consumer #2) ---
// One editable field prefilled with the current mask; OK (default) stores it and
// re-lists, Cancel / Esc-Esc backs out.  Mirrors add_server_dialog's plumbing.
enum { MK_ROOT, MK_TITLE, MK_LFILT, MK_FFILT, MK_CANCEL, MK_OK, MK_N };
#define MK_W 360
#define MK_H 150
static char mk_buf[32];
static char mk_tmpl[31];                             // 30 input positions ('_' run)
static TEDINFO mk_tfilt = { .te_ptext = mk_buf, .te_ptmplt = mk_tmpl, .te_pvalid = "X", .te_txtlen = sizeof mk_buf, .te_just = TE_LEFT };
static OBJECT mk_dlg[MK_N] = {
 /*ROOT  */ { NIL, MK_TITLE, MK_OK, G_BOX, OF_MOVEABLE, OS_NORMAL, 0, 0,0, MK_W, MK_H },
 /*TITLE */ { MK_LFILT,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Set file filter",  20,12, 320,20 },
 /*LFILT */ { MK_FFILT,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Filter:",          20,54, 70,20 },
 /*FFILT */ { MK_CANCEL, NIL,NIL, G_FTEXT,  OF_EDITABLE, OS_NORMAL, &mk_tfilt,              98,51, 240,26 },
 /*CANCEL*/ { MK_OK,     NIL,NIL, G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_CANCEL, OS_NORMAL, (void*)"Cancel", 132,102, 100,32 },
 /*OK    */ { MK_ROOT,   NIL,NIL, G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_DEFAULT|OF_LASTOB, OS_NORMAL, (void*)"OK", 244,102, 92,32 },
};
static void mask_dialog(browser *b) {
    snprintf(mk_buf, sizeof mk_buf, "%s", b->mask[0] ? b->mask : "*");
    memset(mk_tmpl, '_', sizeof mk_tmpl - 1); mk_tmpl[sizeof mk_tmpl - 1] = 0;
    int r = form_do_dialog(mk_dlg, MK_FFILT);         // focus starts in the field
    if (r >= 0) mk_dlg[r].ob_state &= ~OS_SELECTED;   // release for the next run
    if (r != MK_OK) return;
    char m[32]; snprintf(m, sizeof m, "%s", mk_buf);  // trim trailing blanks; empty -> "*"
    for (int i = (int)strlen(m)-1; i >= 0 && m[i] == ' '; i--) m[i] = 0;
    snprintf(b->mask, sizeof b->mask, "%s", m[0] ? m : "*");
    br_list(b); br_settitle(b); wind_redraw();        // re-list/re-layout/retitle/redraw
}

// ---- async pump: feed arrived reply lines back into the owning browser -----
static void net_req_fail(browser *b, const char *msg) {
    int kind = b->req_kind;
    net_req_close(b);
    if (kind == RQ_FETCH || kind == RQ_ADD) {                 // alert + re-list (entry/list reverts)
        char e[80], m[120];
        snprintf(e, sizeof e, "%s", msg);
        for (char *p = e; *p; p++) if (*p=='['||*p==']'||*p=='|') *p = ' ';   // keep form_alert parsable
        snprintf(m, sizeof m, "[3][%s failed|%.60s][OK]", kind == RQ_ADD ? "Add server" : "Fetch", e);
        form_alert(1, m);
        if (kind == RQ_ADD) srv_list_start(b); else net_list_start(b);
        wind_redraw();
        return;
    }
    snprintf(b->req_err, sizeof b->req_err, "%s", msg);       // lists: empty + error in the info bar
    if (kind == RQ_SRV) srv_finish(b); else net_finish(b);
    wind_redraw();
}
static void net_req_line(browser *b, char *ln) {              // dispatch one reply line
    if (b->req_kind == RQ_ADD) {                              // one-line reply: +ok <id> / -err
        if (ln[0] == '-') { net_req_fail(b, ln + 1); return; }
        net_req_close(b);
        srv_list_start(b); wind_redraw();                     // async refresh: the new tile appears
        return;
    }
    if (b->req_kind == RQ_FETCH) {
        if (!strncmp(ln, "+progress ", 10)) {
            sscanf(ln + 10, "%u %u", &b->prog_done, &b->prog_total);
            br_info_redraw(b);                                // ONLY the info bar repaints
        } else if (!strncmp(ln, "+ok", 3)) {
            net_req_close(b);
            net_list_start(b); wind_redraw();                 // async re-list: entry solidifies
        } else if (ln[0] == '-') {
            net_req_fail(b, ln + 1);
        }
        return;
    }
    if (!b->req_hdr) {                                        // list header: "+ok <count>" / -err
        if (ln[0] == '+') {
            int cnt = -1;                                    // count: >=0 fast path, -1 legacy
            if (sscanf(ln, "+ok %d", &cnt) != 1) cnt = -1;
            b->req_total = cnt;
            b->req_hdr = 1;
            return;
        }
        net_req_fail(b, ln[0] == '-' ? ln + 1 : ln);
        return;
    }
    if (!strcmp(ln, ".")) {                                   // list complete: finalize + redraw
        int kind = b->req_kind;
        net_req_close(b);
        if (kind == RQ_SRV) srv_finish(b); else net_finish(b);
        wind_redraw();
        return;
    }
    if (b->req_kind == RQ_SRV) srv_row(b, ln); else net_row(b, ln);
}
static int net_pending(void) {                                // any request in flight?
    for (int i = 0; i < MAXBR; i++) if (BR[i].used && BR[i].req_fd >= 0) return 1;
    return 0;
}
// Called from the event loop (after every event, plus a 40ms tick while a
// request is pending): drain the reply lines that have arrived, bounded per
// browser per call so a firehose of rows can't starve input.
static void net_pump(void) {
    char ln[640];
    for (int i = 0; i < MAXBR; i++) {
        browser *b = &BR[i];
        if (!b->used) continue;
        int before = b->nent, consumed = 0;
        for (int n = 0; n < 64 && b->req_fd >= 0; n++) {
            int r = fuji_poll_line(b->req_fd, ln, sizeof ln);
            if (r == 0) break;                                // no complete line yet
            if (r < 0) { net_req_fail(b, "daemon connection lost"); break; }
            consumed = 1;
            net_req_line(b, ln);
        }
        // watchdog: any reply line (rows or +progress) resets the stall counter;
        // a request that sends nothing for NET_WATCHDOG_TICKS pumps is declared
        // dead so a wedged listing/transfer can never wait forever.
        if (b->req_fd >= 0) {
            if (consumed) b->prog_stall = 0;
            else if (++b->prog_stall > NET_WATCHDOG_TICKS) {
                net_req_fail(b, "server not responding");
                continue;
            }
        }
        // listing still in flight: advance the spinner + reflect new rows.  New
        // rows -> full redraw (the window fills, batched per pump, not per row);
        // an idle tick -> just the info bar (keeps the contacting/indeterminate
        // bar moving, in the servers window too).
        if (b->req_fd >= 0 && (b->req_kind == RQ_LSC || b->req_kind == RQ_SRV)) {
            b->prog_phase++;
            if (b->nent != before) wind_redraw();
            else                   br_info_redraw(b);
        }
    }
}
// Unified tile hit-test: returns a tile slot (0..ntile-1, slot 0 = ".." when
// present) or -1.  Icon view goes through the OBJECT tree (objc_find, tree[1] =
// slot 0); the text views mirror br_text_cell's row/column math.
static int br_hit_slot(browser *b, int mx, int my) {
    if (b->viewmode == 2 || b->viewmode == 3) return br_text_hit(b, mx, my);
    int oi = objc_find(b->tree, 0, 2, mx, my);
    return oi <= 0 ? -1 : oi - 1;
}
static void br_click(browser *b, int mx, int my) {
    if (b->req_fd >= 0) return;                               // request in flight: ignore clicks
    for (int c = 0; c < b->ncrumb; c++)                       // title breadcrumb: jump to an absolute level
        if (my >= b->titley && my < b->titley + b->titleh &&
            mx >= b->crumbx[c] && mx < b->crumbx[c] + b->crumbw[c]) {
            char tgt[400]; snprintf(tgt, sizeof tgt, "%s", b->crumbpath);
            if (b->crumbcut[c] < (int)sizeof tgt) tgt[b->crumbcut[c]] = 0;
            br_navigate(b, tgt); return;
        }
    if (b->maskw > 0 &&                                       // title mask span: edit the file filter
        my >= b->titley && my < b->titley + b->titleh &&
        mx >= b->maskx && mx < b->maskx + b->maskw) {
        mask_dialog(b); return;
    }
    if (br_up_hit(b, mx, my)) {                               // ascend (never above the root)
        char *s = strrchr(b->rel, '/'); if (s) *s = 0; else b->rel[0] = 0;
        br_list(b); br_settitle(b); wind_redraw(); return;
    }
    if (b->fitw > 0 &&                                        // Fit button: size window to contents
        mx >= b->fitx && mx < b->fitx + b->fitw &&
        my >= b->infoy && my < b->infoy + b->infoh) {
        br_fit(b); return;
    }
    if (b->req_err[0] && b->retryw > 0 &&                     // Retry button (error state): re-run
        mx >= b->retryx && mx < b->retryx + b->retryw &&
        my >= b->infoy && my < b->infoy + b->infoh) {
        b->req_err[0] = 0;
        if (b->net == 1) srv_list_start(b); else net_list_start(b);
        wind_redraw(); return;
    }
    if (b->vieww > 0 &&                                      // View button: cycle icons/single/multi
        mx >= b->viewx && mx < b->viewx + b->vieww &&
        my >= b->infoy && my < b->infoy + b->infoh) {
        b->viewmode = b->viewmode >= 3 ? 1 : b->viewmode + 1;
        b->sel = -1; wind_redraw(); return;
    }
    b->selall = 0;                                           // any in-window click drops a "select all"
    int slot = br_hit_slot(b, mx, my);
    if (slot < 0) { b->sel = -1; wind_redraw(); return; }
    int dd = b->rel[0] ? 1 : 0;
    int isdot = (dd && slot == 0);                          // synthetic ".." up-tile
    int i = slot-dd, was = (!isdot && b->sel == i);
    b->sel = isdot ? -1 : i; wind_redraw();
    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int w2 = wind_find(mx2, my2);
        if (w2 == b->win && br_hit_slot(b, mx2, my2) == slot) {   // double-click
            if (isdot) {                                     // ".." : ascend one level (like Up)
                char *s = strrchr(b->rel, '/'); if (s) *s = 0; else b->rel[0] = 0;
                br_list(b); br_settitle(b); wind_redraw();
            } else if (b->net == 1) {                        // servers window
                if (b->ent[i].srvid < 0)                     // "Add server": the dialog
                    add_server_dialog(b);
                else open_fuji_browser(b->ent[i].srvid, b->ent[i].label);
            } else if (b->ent[i].dir) {                      // descend
                int n = (int)strlen(b->rel);
                snprintf(b->rel + n, sizeof b->rel - n, "%s%s", b->rel[0] ? "/" : "", b->ent[i].name);
                br_list(b); br_settitle(b); wind_redraw();
            } else if (b->net == 2) {                        // network file: launch cached / fetch ghost
                net_open(b, i);
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
static void open_browser_win(const char *logical, int media_type, int net, int server_id) {
    for (int i = 0; i < MAXBR; i++) {             // one window per place: re-top it
        browser *e = &BR[i];
        if (!e->used || e->net != net) continue;
        if (net == 2 ? e->server_id == server_id
                     : strcmp(e->logical_root, logical) == 0) {
            wind_raise(e->win); wind_redraw();
            return;
        }
    }
    int s = -1; for (int i = 0; i < MAXBR; i++) if (!BR[i].used) { s = i; break; }
    if (s < 0) return;
    browser *b = &BR[s]; memset(b, 0, sizeof *b);
    b->used = 1; b->media_type = media_type; b->sel = -1; b->req_fd = -1;
    b->net = net; b->server_id = server_id;
    b->viewmode = default_viewmode();
    b->sortmode = default_sortmode(); b->sortinv = default_sortinv();
    snprintf(b->mask, sizeof b->mask, "*");           // default file mask: show everything
    snprintf(b->logical_root, sizeof b->logical_root, "%s", logical);
    snprintf(b->fs_root, sizeof b->fs_root, "%s%s", base, logical);
    int kind = BR_WKIND;
    int pw = 760, ph = 520, bx, by, bw, bh;
    wind_calc(WC_BORDER, kind, g_bx, g_by, pw, ph, &bx, &by, &bw, &bh);
    b->win = wind_create(kind, bx, by, bw, bh);
    if (!b->win) { b->used = 0; return; }
    br_list(b); br_settitle(b);
    wind_content(b->win, br_content, b);
    wind_info(b->win, br_infobar, b);
    if (net != 1) wind_title(b->win, br_title, b);    // path windows: interactive title; servers keep a plain name
    wind_open(b->win, bx, by, bw, bh);
    g_bx += 34; g_by += 30; if (g_by > WIN_H-320) { g_bx = 380; g_by = 130; }
}
static void open_browser(const char *logical, int media_type) {
    open_browser_win(logical, media_type, 0, 0);
}
// FujiNet: the servers window, then per-server network browsers rooted at "/".
static void open_fuji_browser(int server_id, const char *name) {
    open_browser_win(name, ICT_MEDIA_8BIT, 2, server_id);
}
static void open_fuji_servers(void) {
    int fd = fuji_connect();
    if (fd < 0) { form_alert(1, "[3][FujiNet daemon not running|(boot script 40-FujiNet)][OK]"); return; }
    fuji_close(fd);
    open_browser_win("FujiNet", ICT_MEDIA_8BIT, 1, 0);
}

// Dispatch a desktop icon by its registry type: emulators -> an emulator window,
// media -> a rooted browser rooted at the matching /Media volume.
static void open_icon(int obj) {
    reg_desktop_icon *ri = &rows[obj-1];
    switch (ri->type) {
        case ICT_MEDIA_8BIT: open_browser("/Media/6502", ICT_MEDIA_8BIT); break;
        case ICT_MEDIA_1632: open_browser("/Media/m68k", ICT_MEDIA_1632); break;
        case ICT_FUJINET:    open_fuji_servers(); break;
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

// ======================================================================
// Browse navigator — a LIVE cascading filesystem menu (TeraDesk/Jinni "Contents"
// style) invoked from the context menu's "browse" verb.  The start directory's
// contents are the first popup; hovering a folder row cascades ITS contents as a
// live submenu, recursively, reading each directory only when it first opens
// (menu_popup_dyn + the br_expand provider below).  Leaf actions: choosing a
// FILE launches it (the double-click path); choosing a FOLDER (clicking the row,
// as opposed to hovering to cascade) opens it as a folder WINDOW.  Local FS only.
//
// Since a submenu id can't encode a path, a per-session node table maps each
// interned entry to (parent, name, isdir); its 1-based index is the menu id AND
// the provider key (item->id), and br_path() rebuilds the absolute path by
// walking parents.  Expansions are cached (firstkid/nkids) so re-hovering a
// folder doesn't re-read it or grow the table.  br_expand + the table are the
// testable core the --browsenav headless test drives without the modal loop.
// ======================================================================
#define BR_MAX        256               // per-level entry cap (matches menu_popup's advice)
#define BR_MAXNODES   1536              // path-table capacity (grows as folders open)
typedef struct { char name[128]; int dir; } br_scan;
static int br_scan_cmp(const void *a, const void *b) {   // dirs first, then name
    const br_scan *x = a, *y = b;
    if (x->dir != y->dir) return y->dir - x->dir;
    return strcasecmp(x->name, y->name);
}
// One interned filesystem entry.  parent 0 = the root (path in br_rootpath).
// firstkid < 0 = not yet expanded; else the 1-based id of the first child.
typedef struct { int parent, isdir, firstkid, nkids, trunc; char name[128]; } br_node;
static br_node br_nodes[BR_MAXNODES];
static int     br_nnodes;
static char    br_rootpath[512];
static void br_reset(void) { br_nnodes = 0; }
// Intern one entry; returns its 1-based id (0 = table full).
static int br_intern(int parent, const char *name, int isdir) {
    if (br_nnodes >= BR_MAXNODES) return 0;
    br_node *nd = &br_nodes[br_nnodes];
    nd->parent = parent; nd->isdir = isdir; nd->firstkid = -1; nd->nkids = 0; nd->trunc = 0;
    snprintf(nd->name, sizeof nd->name, "%s", name);
    return ++br_nnodes;                                  // id = index + 1
}
// Rebuild the absolute FS path of node `id` by walking parents up to the root.
static void br_path(int id, char *out, int cap) {
    if (id <= 0 || id > br_nnodes) { if (cap) out[0] = 0; return; }
    br_node *nd = &br_nodes[id-1];
    if (nd->parent == 0) { snprintf(out, cap, "%s", br_rootpath); return; }
    char pp[512]; br_path(nd->parent, pp, sizeof pp);
    snprintf(out, cap, "%s/%s", pp, nd->name);
}
// Read directory node `id` once: readdir (dirs-first sorted), interning each
// child as a node.  Children are interned back-to-back, so they occupy a
// contiguous id range [firstkid .. firstkid+nkids-1] — cached for re-hovers.
static void br_scan_dir(int id) {
    char dir[512]; br_path(id, dir, sizeof dir);
    static br_scan sc[BR_MAX + 1];
    int ns = 0, trunc = 0;
    DIR *d = opendir(dir);
    if (d) {
        struct dirent *de;
        while ((de = readdir(d))) {
            if (de->d_name[0] == '.') continue;          // hidden + . ..
            if (ns >= BR_MAX) { trunc = 1; break; }
            char full[600]; snprintf(full, sizeof full, "%s/%s", dir, de->d_name);
            struct stat st; int isdir = 0;
            if (stat(full, &st) == 0) isdir = S_ISDIR(st.st_mode);
            snprintf(sc[ns].name, sizeof sc[ns].name, "%s", de->d_name);
            sc[ns].dir = isdir; ns++;
        }
        closedir(d);
    }
    qsort(sc, ns, sizeof sc[0], br_scan_cmp);
    br_node *nd = &br_nodes[id-1];
    nd->firstkid = 0; nd->nkids = 0; nd->trunc = trunc;  // mark expanded (even if empty)
    for (int i = 0; i < ns; i++) {
        int cid = br_intern(id, sc[i].name, sc[i].dir);
        if (cid == 0) { nd->trunc = 1; break; }          // table full: note truncation, stop
        if (nd->nkids == 0) nd->firstkid = cid;          // first child's id
        nd->nkids++;
    }
}
// Build a malloc'd menu_item[] block for the (already-interned) children of node
// `id`.  ONE block holds the items AND their label strings (labels alias into
// it), so menu_popup_dyn frees it with a single free().  Dirs get MI_LAZY (they
// cascade on hover) + a trailing "/"; every row's id is its node id (so a click
// resolves to launch/open).  A truncated directory gets a disabled "(more…)"
// tail.  Returns 1 with *out/*outn set, or 0 (empty / OOM).
static int br_build_block(int id, menu_item **out, int *outn) {
    br_node *nd = &br_nodes[id-1];
    int nk = nd->nkids, extra = nd->trunc ? 2 : 0, total = nk + extra;
    if (total <= 0) { *out = NULL; *outn = 0; return 0; }
    const size_t LBL = 132;
    char *block = malloc(sizeof(menu_item) * total + LBL * nk);
    if (!block) { *out = NULL; *outn = 0; return 0; }
    menu_item *it = (menu_item *)block;
    char *labels = block + sizeof(menu_item) * total;
    for (int k = 0; k < nk; k++) {
        int cid = nd->firstkid + k;                      // contiguous child ids
        br_node *c = &br_nodes[cid-1];
        char *lbl = labels + (size_t)k * LBL;
        if (c->isdir) snprintf(lbl, LBL, "%s/", c->name);
        else          snprintf(lbl, LBL, "%s",  c->name);
        it[k] = (menu_item){ lbl, NULL, cid, NULL, 0, (unsigned)(c->isdir ? MI_LAZY : 0) };
    }
    if (nd->trunc) {                                      // the cap was hit
        it[nk]   = (menu_item){ "-", NULL, 0, NULL, 0, 0 };
        it[nk+1] = (menu_item){ "(more not shown)", NULL, 0, NULL, 0, MI_DISABLED };
    }
    *out = it; *outn = total; return 1;
}
// menu_popup_dyn provider: expand directory node `dynid` into its children (on
// first open it reads the directory; thereafter it reuses the cached range).
static int br_expand(void *ctx, int dynid, menu_item **out, int *outn) {
    (void)ctx;
    if (dynid <= 0 || dynid > br_nnodes || !br_nodes[dynid-1].isdir) { *out = NULL; *outn = 0; return 0; }
    if (br_nodes[dynid-1].firstkid < 0) br_scan_dir(dynid);   // first time: read it
    return br_build_block(dynid, out, outn);
}
// Launch a browsed file: the same emulator path a double-click runs, with the
// media type inferred from the path (the m68k media root vs the 6502 one).
static void browse_launch(const char *fullpath) {
    const char *nm = strrchr(fullpath, '/'); nm = nm ? nm + 1 : fullpath;
    int media = strstr(fullpath, "m68k") ? ICT_MEDIA_1632 : ICT_MEDIA_8BIT;
    desk_launch(nm, media);
}
// Open a browsed folder as a rooted browser WINDOW.  open_browser wants a logical
// path (relative to `base`), so strip the base prefix off the absolute FS path.
static void browse_open_folder(const char *fullpath) {
    const char *logical = fullpath; size_t bl = strlen(base);
    if (!strncmp(fullpath, base, bl)) logical = fullpath + bl;   // absolute FS -> logical
    if (!logical[0]) logical = "/";
    int media = strstr(fullpath, "m68k") ? ICT_MEDIA_1632 : ICT_MEDIA_8BIT;
    open_browser(logical, media);
}
// Run the live cascading browse navigator rooted at `startdir` (an absolute FS
// path), the first popup at (sx,sy).  Builds the root level, runs menu_popup_dyn
// (which cascades into folders live as they are hovered), then acts on the chosen
// leaf: a FILE launches, a FOLDER opens as a window.  Local FS only (caller
// guards net paths).
static void browse_at(const char *startdir, int sx, int sy) {
    br_reset();
    snprintf(br_rootpath, sizeof br_rootpath, "%s", startdir);
    int root = br_intern(0, "", 1);                      // the root node (id 1)
    menu_item *items = NULL; int n = 0;
    if (!br_expand(NULL, root, &items, &n) || n <= 0) { free(items); return; }  // empty root
    int cx = sx; if (cx > WIN_W - 220) cx = WIN_W - 220; if (cx < 0) cx = 0;
    int chosen = menu_popup_dyn(items, n, cx, sy, br_expand, NULL);
    free(items);                                         // the root block is caller-owned
    if (chosen > 0 && chosen <= br_nnodes) {             // a chosen entry: act on it
        char full[512]; br_path(chosen, full, sizeof full);
        if (br_nodes[chosen-1].isdir) browse_open_folder(full);
        else                          browse_launch(full);
    }
}

// ======================================================================
// Right-click context menus.  A scope-sensitive popup built from the
// registry's contextMenu table (what's under the cursor decides the scope:
// 1 desktop bg / 2 drive / 3 window / 4 icon) and dispatched to the desktop's
// verbs.  The flat rows come from SQL; the "Show" submenu (view mode + sort)
// is built in code off the target window's live state.  menu_popup (aes/menu.c)
// runs the modal loop.  The build + dispatch halves are factored out (below the
// modal ctx_menu_at) so the headless --ctx test can drive them directly.
// ======================================================================
typedef struct { char label[48], accel[12], action[24], submenu[24]; } ctxrow;

// A parallel read-only connection to the same DB (registry.c keeps its own
// handle private, and we must not touch it) — used only for contextMenu rows.
static sqlite3 *g_ctxdb;
static void ctx_db_open(const char *dbpath) {
    if (!g_ctxdb) sqlite3_open_v2(dbpath, &g_ctxdb, SQLITE_OPEN_READONLY, NULL);
}
static void ctx_db_close(void) { if (g_ctxdb) { sqlite3_close(g_ctxdb); g_ctxdb = NULL; } }
static int ctx_menu_rows(int scope, ctxrow *out, int max) {
    if (!g_ctxdb) return 0;
    sqlite3_stmt *st;
    const char *sql = "SELECT label,COALESCE(accel,''),action,COALESCE(submenu,'') "
                      "FROM contextMenu WHERE scope=? ORDER BY ord";
    if (sqlite3_prepare_v2(g_ctxdb, sql, -1, &st, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_int(st, 1, scope);
    int n = 0;
    while (n < max && sqlite3_step(st) == SQLITE_ROW) {
        snprintf(out[n].label,   sizeof out[n].label,   "%s", (const char*)sqlite3_column_text(st, 0));
        snprintf(out[n].accel,   sizeof out[n].accel,   "%s", (const char*)sqlite3_column_text(st, 1));
        snprintf(out[n].action,  sizeof out[n].action,  "%s", (const char*)sqlite3_column_text(st, 2));
        snprintf(out[n].submenu, sizeof out[n].submenu, "%s", (const char*)sqlite3_column_text(st, 3));
        n++;
    }
    sqlite3_finalize(st);
    return n;
}
// A scope with no rows of its own falls back to a sensible sibling (drive ->
// icon), so every click still yields a usable menu.
static int ctx_scope_rows(int scope, ctxrow *out, int max) {
    int n = ctx_menu_rows(scope, out, max);
    if (n == 0 && scope == 2) n = ctx_menu_rows(4, out, max);   // drive -> icon
    return n;
}

enum { ACT_UNKNOWN = 0, ACT_NEW, ACT_INFO, ACT_SELECTALL, ACT_DELETE, ACT_OPEN, ACT_BROWSE, ACT_SHOW, ACT_SEP };
static int ctx_action_id(const char *a) {
    if (!strcmp(a, "new"))       return ACT_NEW;
    if (!strcmp(a, "info"))      return ACT_INFO;
    if (!strcmp(a, "selectall")) return ACT_SELECTALL;
    if (!strcmp(a, "delete"))    return ACT_DELETE;
    if (!strcmp(a, "open"))      return ACT_OPEN;
    if (!strcmp(a, "browse"))    return ACT_BROWSE;
    if (!strcmp(a, "show"))      return ACT_SHOW;
    if (!strcmp(a, "sep"))       return ACT_SEP;
    return ACT_UNKNOWN;
}
// menu_popup id spaces: flat contextMenu rows return CTX_ROW_BASE+index; the
// built-in Show submenu leaves return their own SH_* ids.
#define CTX_ROW_BASE 1000
enum { SH_VIEW_ICONS = 100, SH_VIEW_LIST, SH_VIEW_COLS,
       SH_SORT_NAME = 110, SH_SORT_TYPE, SH_SORT_SIZE, SH_SORT_DATE, SH_SORT_INV };

// Build the cascading Show submenu off a window's live view/sort state (the
// checkmarks track the current mode / inverted flag).  Returns the item count.
static int ctx_build_show(menu_item *it, browser *b) {
    int vm = b ? b->viewmode : 1, sm = b ? b->sortmode : 2, si = b ? b->sortinv : 0;
    int n = 0;
    it[n++] = (menu_item){ "Icons",        NULL, SH_VIEW_ICONS, NULL, 0, vm == 1 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "List",         NULL, SH_VIEW_LIST,  NULL, 0, vm == 2 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "Columns",      NULL, SH_VIEW_COLS,  NULL, 0, vm == 3 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "-",            NULL, 0,             NULL, 0, 0 };
    it[n++] = (menu_item){ "Sort by Name", NULL, SH_SORT_NAME,  NULL, 0, sm == 2 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "Sort by Type", NULL, SH_SORT_TYPE,  NULL, 0, sm == 3 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "Sort by Size", NULL, SH_SORT_SIZE,  NULL, 0, sm == 4 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "Sort by Date", NULL, SH_SORT_DATE,  NULL, 0, sm == 5 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "-",            NULL, 0,             NULL, 0, 0 };
    it[n++] = (menu_item){ "Inverted",     NULL, SH_SORT_INV,   NULL, 0, si ? MI_CHECKED : 0 };
    return n;
}
// Assemble the flat menu_item[] for `scope` from `crows` (which the caller keeps
// alive across menu_popup — items[].label alias into it); the row flagged with a
// submenu name gets the built Show cascade.  Returns the item count.
static int ctx_build_items(int scope, ctxrow *crows, int maxr,
                           menu_item *items, menu_item *show, int *nshow, browser *b) {
    int nr = ctx_scope_rows(scope, crows, maxr);
    *nshow = 0;
    for (int i = 0; i < nr; i++) {
        items[i].label = crows[i].label;
        items[i].accel = crows[i].accel[0] ? crows[i].accel : NULL;
        items[i].id    = CTX_ROW_BASE + i;
        items[i].sub   = NULL; items[i].nsub = 0; items[i].flags = 0;
        if (crows[i].submenu[0]) {                       // "Show" -> the built cascade
            *nshow = ctx_build_show(show, b);
            items[i].sub = show; items[i].nsub = *nshow; items[i].id = 0;
        }
    }
    return nr;
}
// Resolve what's under (mx,my): the scope + dispatch target (a browser window's
// entry, a desktop icon, or just the background).
static int ctx_resolve(int mx, int my, browser **tb, int *tentry, int *tdeskobj) {
    *tb = NULL; *tentry = -1; *tdeskobj = 0;
    int wh = wind_find(mx, my);
    browser *b = wh ? br_of_window(wh) : NULL;
    if (b) {
        *tb = b;
        int slot = br_hit_slot(b, mx, my);
        int dd = b->rel[0] ? 1 : 0;
        if (slot >= 0 && !(dd && slot == 0)) { *tentry = slot - dd; return 4; }  // an entry -> icon
        return 3;                                        // work-area background -> window
    }
    int obj = objc_find(desk, ROOT, 2, mx, my);
    if (obj > ROOT) {                                    // a desktop icon
        *tdeskobj = obj;
        int t = rows[obj-1].type;
        if (t == ICT_MEDIA_8BIT || t == ICT_MEDIA_1632 || t == ICT_FUJINET) return 2;  // drive
        return 4;                                        // generic icon (emulators)
    }
    return 1;                                            // desktop background
}
// Copy s into out, neutralising form_alert's structural chars so file/dir names
// can't corrupt an alert string.
static void ctx_san(const char *s, char *out, int cap) {
    int j = 0;
    for (int i = 0; s[i] && j < cap - 1; i++) { char c = s[i]; out[j++] = (c=='['||c==']'||c=='|') ? ' ' : c; }
    out[j] = 0;
}
// Absolute filesystem path of `name` in the browser's current directory.
static void ctx_entry_path(browser *b, const char *name, char *out, int cap) {
    if (b->rel[0]) snprintf(out, cap, "%s/%s/%s", b->fs_root, b->rel, name);
    else           snprintf(out, cap, "%s/%s", b->fs_root, name);
}
static int g_ctx_mx, g_ctx_my;                        // the right-click point (browse popup origin)
// Compute the browse start dir for the resolved scope/target.  Returns 1 with
// `out` filled for a local, browsable target; 0 for a net (non-local) target.
//   window scope  -> the window's current dir (fs_root + rel)
//   folder entry  -> that folder;  file entry -> its parent (the window dir)
//   drive icon    -> the media root; net drive -> not local (0)
//   desktop bg    -> the base root
static int ctx_browse_start(int scope, browser *b, int tentry, int tdeskobj, char *out, int cap) {
    if (b) {
        if (b->net != 0) return 0;                       // net browser: local-only
        if (scope == 4 && tentry >= 0 && b->ent[tentry].dir)
            ctx_entry_path(b, b->ent[tentry].name, out, cap);
        else if (b->rel[0]) snprintf(out, cap, "%s/%s", b->fs_root, b->rel);
        else                snprintf(out, cap, "%s", b->fs_root);
        return 1;
    }
    if (tdeskobj) {
        switch (rows[tdeskobj-1].type) {
            case ICT_MEDIA_8BIT: snprintf(out, cap, "%s/Media/6502", base); return 1;
            case ICT_MEDIA_1632: snprintf(out, cap, "%s/Media/m68k", base); return 1;
            case ICT_FUJINET:    return 0;               // net drive: local-only
            default:             snprintf(out, cap, "%s", base); return 1;
        }
    }
    snprintf(out, cap, "%s", base);                      // desktop background -> the root
    return 1;
}
// Start the browse navigator for the resolved scope/target (local FS only).
static void ctx_browse(int scope, browser *b, int tentry, int tdeskobj) {
    char start[512];
    if (!ctx_browse_start(scope, b, tentry, tdeskobj, start, sizeof start)) {
        form_alert(1, "[1][Browse|browse is local-only][OK]"); return;
    }
    browse_at(start, g_ctx_mx, g_ctx_my);
}
// Open a browser entry — the same descend/launch/net-open the double-click path
// runs (factored so both callers stay in step).
static void ctx_open_entry(browser *b, int i) {
    if (b->net == 1) {
        if (b->ent[i].srvid < 0) add_server_dialog(b);
        else open_fuji_browser(b->ent[i].srvid, b->ent[i].label);
    } else if (b->ent[i].dir) {
        int n = (int)strlen(b->rel);
        snprintf(b->rel + n, sizeof b->rel - n, "%s%s", b->rel[0] ? "/" : "", b->ent[i].name);
        br_list(b); br_settitle(b); wind_redraw();
    } else if (b->net == 2) {
        net_open(b, i);
    } else {
        desk_launch(b->ent[i].name, b->media_type);
    }
}
// A context-sensitive Info alert: differs by scope (file / folder / window /
// drive / desktop).
static void ctx_info(int scope, browser *b, int tentry, int tdeskobj) {
    char m[300], nm[96], loc[160];
    if (scope == 4 && b && tentry >= 0) {                // an in-window entry
        bent *e = &b->ent[tentry];
        ctx_san(e->name, nm, sizeof nm);
        if (b->rel[0]) { char t[160]; snprintf(t, sizeof t, "%s/%s", b->logical_root, b->rel); ctx_san(t, loc, sizeof loc); }
        else           ctx_san(b->logical_root, loc, sizeof loc);
        if (e->dir) snprintf(m, sizeof m, "[1][%s|folder in %s][OK]", nm, loc);
        else        snprintf(m, sizeof m, "[1][%s|%ld bytes|in %s][OK]", nm, e->size, loc);
    } else if ((scope == 4 || scope == 2) && tdeskobj) { // a desktop icon / drive
        reg_desktop_icon *ri = &rows[tdeskobj-1];
        ctx_san(ri->displayName[0] ? ri->displayName : "icon", nm, sizeof nm);
        snprintf(m, sizeof m, "[1][%s|%s][OK]", nm, scope == 2 ? "drive / volume" : "desktop icon");
    } else if (scope == 3 && b) {                        // a window
        if (b->rel[0]) { char t[160]; snprintf(t, sizeof t, "%s/%s", b->logical_root, b->rel); ctx_san(t, loc, sizeof loc); }
        else           ctx_san(b->logical_root, loc, sizeof loc);
        snprintf(m, sizeof m, "[1][%s|%d items, %d files|%ld bytes total][OK]", loc, b->nent, b->nfiles, b->total);
    } else {                                             // the desktop background
        snprintf(m, sizeof m, "[1][XTOS desktop|right-click for actions][OK]");
    }
    form_alert(1, m);
}
// ---- New-folder dialog (context-menu "New..."; form_do consumer #3) ----------
enum { NF_ROOT, NF_TITLE, NF_LNAME, NF_FNAME, NF_CANCEL, NF_OK, NF_N };
#define NF_W 360
#define NF_H 150
static char nf_buf[64];
static char nf_tmpl[41];                              // 40 input positions ('_' run)
static TEDINFO nf_tname = { .te_ptext = nf_buf, .te_ptmplt = nf_tmpl, .te_pvalid = "F", .te_txtlen = sizeof nf_buf, .te_just = TE_LEFT };
static OBJECT nf_dlg[NF_N] = {
 /*ROOT  */ { NIL, NF_TITLE, NF_OK, G_BOX, OF_MOVEABLE, OS_NORMAL, 0, 0,0, NF_W, NF_H },
 /*TITLE */ { NF_LNAME,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"New folder", 20,12, 320,20 },
 /*LNAME */ { NF_FNAME,  NIL,NIL, G_STRING, OF_NONE, OS_NORMAL, (void*)"Name:",      20,54, 60,20 },
 /*FNAME */ { NF_CANCEL, NIL,NIL, G_FTEXT,  OF_EDITABLE, OS_NORMAL, &nf_tname,       88,51, 250,26 },
 /*CANCEL*/ { NF_OK,     NIL,NIL, G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_CANCEL, OS_NORMAL, (void*)"Cancel", 132,102, 100,32 },
 /*OK    */ { NF_ROOT,   NIL,NIL, G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_DEFAULT|OF_LASTOB, OS_NORMAL, (void*)"OK", 244,102, 92,32 },
};
static int new_folder_dialog(char *out, int cap) {
    nf_buf[0] = 0; memset(nf_tmpl, '_', sizeof nf_tmpl - 1); nf_tmpl[sizeof nf_tmpl - 1] = 0;
    int r = form_do_dialog(nf_dlg, NF_FNAME);         // focus starts in the field
    if (r >= 0) nf_dlg[r].ob_state &= ~OS_SELECTED;
    if (r != NF_OK) return 0;
    char nm[64]; snprintf(nm, sizeof nm, "%s", nf_buf);
    for (int i = (int)strlen(nm)-1; i >= 0 && nm[i] == ' '; i--) nm[i] = 0;
    if (!nm[0]) return 0;
    snprintf(out, cap, "%s", nm);
    return 1;
}
// ---- New… from the desktop.rsc "New" tree (tree 0) ---------------------------
// mkrsc build_new object indices: 0 root G_BOX, 1 "New", 2 "Kind:", 3 Folder
// radio, 4 File radio, 5 "Type:" label, 6 Type G_POPUP, 7 "Name:", 8 Name
// G_FTEXT, 9 Cancel, 10 OK.  Kept as an enum so both twins read identically.
enum { NEW_ROOT=0, NEW_FOLDER=3, NEW_FILE=4, NEW_TYPELBL=5, NEW_POPUP=6,
       NEW_NAME=8, NEW_CANCEL=9, NEW_OK=10 };

// Set the Type popup's shown value to the first item of its linked menu tree
// (.txt) — used to reset the tree to a pristine state before each open.
static void new_reset_type(OBJECT *t) {
    int link = rscload_ext(g_rsc, 0, NEW_POPUP);
    if (link <= 0) return;
    OBJECT *menu = rscload_tree(g_rsc, link);
    if (!menu) return;
    for (int c = menu[0].ob_head; c >= 0; c = (c == menu[0].ob_tail ? -1 : menu[c].ob_next))
        if (menu[c].ob_type == G_STRING && menu[c].ob_spec) { t[NEW_POPUP].ob_spec = menu[c].ob_spec; return; }
}
// Run the Type popup: build a menu_item[] from its linked menu tree's G_STRING
// items, run menu_popup at the popup rect, and set the popup's shown value.
static void new_run_typepopup(OBJECT *t, int popup) {
    int link = rscload_ext(g_rsc, 0, popup);          // linked menu tree index (RSC high byte)
    if (link <= 0) return;
    OBJECT *menu = rscload_tree(g_rsc, link);
    if (!menu) return;
    menu_item items[16]; int n = 0;
    for (int c = menu[0].ob_head; c >= 0 && n < 16; c = (c == menu[0].ob_tail ? -1 : menu[c].ob_next)) {
        if (menu[c].ob_type != G_STRING || !menu[c].ob_spec) continue;
        items[n].label = (const char *)menu[c].ob_spec; items[n].accel = NULL;
        items[n].id = n; items[n].sub = NULL; items[n].nsub = 0; items[n].flags = 0;
        n++;
    }
    if (!n) return;
    int x, y; objc_offset(t, popup, &x, &y);
    int choice = menu_popup(items, n, x, y + t[popup].ob_h);
    if (choice >= 0 && choice < n) t[popup].ob_spec = (void *)items[choice].label;
}
// form_do hook: Folder/File radio -> show/hide the Type popup + its label; Type
// popup click -> run its linked menu.  Registered only around the New dialog.
static int new_hook(OBJECT *t, int obj, void *ud) {
    (void)ud;
    if (obj == NEW_FOLDER || obj == NEW_FILE) {
        int file = (t[NEW_FILE].ob_state & OS_SELECTED) != 0;
        if (file) { t[NEW_POPUP].ob_flags &= ~OF_HIDETREE; t[NEW_TYPELBL].ob_flags &= ~OF_HIDETREE; }
        else      { t[NEW_POPUP].ob_flags |=  OF_HIDETREE; t[NEW_TYPELBL].ob_flags |=  OF_HIDETREE; }
        return 1;
    }
    if (obj == NEW_POPUP) { new_run_typepopup(t, obj); return 1; }
    return 0;
}

// New folder/file in the target window's directory (local net==0 only; else a
// stub alert).  Prompt via the resource "New" tree (Folder/File + conditional
// Type popup + Name); create -> re-list.  Falls back to the built-in
// folder-only dialog when the resource is unavailable.
static void ctx_new(browser *b) {
    if (!b || b->net != 0) { form_alert(1, "[1][New folder|only in local windows][OK]"); return; }

    OBJECT *t = g_rsc ? rscload_tree(g_rsc, 0) : NULL;
    if (!t) {                                          // fallback: legacy folder-only dialog
        char nm[64];
        if (!new_folder_dialog(nm, sizeof nm)) return;
        char full[520]; ctx_entry_path(b, nm, full, sizeof full);
        if (mkdir(full, 0777) != 0) { form_alert(1, "[3][Could not create the folder][OK]"); return; }
        br_list(b); br_settitle(b); wind_redraw(); return;
    }

    // Reset the shared resource tree to a pristine state (Folder default, Type
    // hidden, popup value .txt, name empty) so it survives repeated opens.
    t[NEW_FOLDER].ob_state |= OS_SELECTED; t[NEW_FILE].ob_state &= ~OS_SELECTED;
    t[NEW_TYPELBL].ob_flags |= OF_HIDETREE; t[NEW_POPUP].ob_flags |= OF_HIDETREE;
    new_reset_type(t);
    // The rsc TEDINFO's te_ptext lives in the resource arena; hand the editor a
    // local writable buffer for this run, then restore it (keeps the rsc pristine).
    char namebuf[64]; namebuf[0] = 0;
    TEDINFO *te = (TEDINFO *)t[NEW_NAME].ob_spec;
    char *save_ptext = te->te_ptext; int16_t save_txtlen = te->te_txtlen;
    te->te_ptext = namebuf; te->te_txtlen = (int16_t)sizeof namebuf;

    form_set_hook(new_hook, NULL);
    int r = form_do_dialog(t, 0);                      // focus starts in the Name field
    form_set_hook(NULL, NULL);
    if (r >= 0) t[r].ob_state &= ~OS_SELECTED;

    int file = (t[NEW_FILE].ob_state & OS_SELECTED) != 0;
    char nm[64]; snprintf(nm, sizeof nm, "%s", namebuf);
    char suffix[16]; snprintf(suffix, sizeof suffix, "%s", (const char *)t[NEW_POPUP].ob_spec);
    te->te_ptext = save_ptext; te->te_txtlen = save_txtlen;   // restore pristine
    if (r != NEW_OK) return;
    for (int i = (int)strlen(nm)-1; i >= 0 && nm[i] == ' '; i--) nm[i] = 0;
    if (!nm[0]) return;

    char leaf[96];
    if (file && suffix[0]) snprintf(leaf, sizeof leaf, "%s%s", nm, suffix);
    else                   snprintf(leaf, sizeof leaf, "%s", nm);
    char full[520]; ctx_entry_path(b, leaf, full, sizeof full);
    if (file) {
        FILE *cf = fopen(full, "w");                   // create an empty file
        if (!cf) { form_alert(1, "[3][Could not create the file][OK]"); return; }
        fclose(cf);
    } else if (mkdir(full, 0777) != 0) {
        form_alert(1, "[3][Could not create the folder][OK]"); return;
    }
    br_list(b); br_settitle(b); wind_redraw();
}
// Delete the target entr(y/ies): confirm, then unlink (local net==0 only).  An
// icon-scope click deletes that entry; otherwise the selection (or every listed
// entry when "select all" is active).
static void ctx_delete(browser *b, int scope, int tentry) {
    if (!b || b->net != 0) { form_alert(1, "[1][Delete|only in local windows][OK]"); return; }
    int one = -1;
    if (scope == 4 && tentry >= 0) one = tentry;
    else if (b->sel >= 0)          one = b->sel;
    if (one < 0 && !b->selall) { form_alert(1, "[1][Nothing selected to delete][OK]"); return; }
    int r = form_alert(2, b->selall ? "[2][Delete all listed items?][Cancel|Delete]"
                                     : "[2][Delete the selected item?][Cancel|Delete]");
    if (r != 2) return;
    int lo = b->selall ? 0 : one, hi = b->selall ? b->nent - 1 : one;
    for (int i = lo; i <= hi; i++) {
        char full[520]; ctx_entry_path(b, b->ent[i].name, full, sizeof full);
        remove(full);                                    // files + empty dirs; ignore failures
    }
    b->sel = -1; b->selall = 0;
    br_list(b); br_settitle(b); wind_redraw();
}
// Dispatch a menu_popup result (factored out of ctx_menu_at so the headless test
// can invoke actions without driving the modal loop).
static void ctx_apply(int chosen, ctxrow *crows, int scope, browser *b, int tentry, int tdeskobj) {
    if (chosen < 0) return;
    if (chosen >= CTX_ROW_BASE) {                        // a flat contextMenu row
        switch (ctx_action_id(crows[chosen - CTX_ROW_BASE].action)) {
            case ACT_OPEN:      if (b && tentry >= 0) ctx_open_entry(b, tentry);
                                else if (tdeskobj)   open_icon(tdeskobj); break;
            case ACT_INFO:      ctx_info(scope, b, tentry, tdeskobj); break;
            case ACT_SELECTALL: if (b) { b->selall = 1; b->sel = -1; wind_redraw(); } break;
            case ACT_NEW:       ctx_new(b); break;
            case ACT_DELETE:    ctx_delete(b, scope, tentry); break;
            case ACT_BROWSE:    ctx_browse(scope, b, tentry, tdeskobj); break;
            default:            break;                    // sep / unknown: no-op
        }
        return;
    }
    if (!b) return;                                      // Show items act on a window
    switch (chosen) {
        case SH_VIEW_ICONS: b->viewmode = 1; b->sel = -1; wind_redraw(); break;
        case SH_VIEW_LIST:  b->viewmode = 2; b->sel = -1; wind_redraw(); break;
        case SH_VIEW_COLS:  b->viewmode = 3; b->sel = -1; wind_redraw(); break;
        case SH_SORT_NAME:  b->sortmode = 2; br_list(b); wind_redraw(); break;
        case SH_SORT_TYPE:  b->sortmode = 3; br_list(b); wind_redraw(); break;
        case SH_SORT_SIZE:  b->sortmode = 4; br_list(b); wind_redraw(); break;
        case SH_SORT_DATE:  b->sortmode = 5; br_list(b); wind_redraw(); break;
        case SH_SORT_INV:   b->sortinv = !b->sortinv; br_list(b); wind_redraw(); break;
    }
}
// The right-click entry point: resolve the scope/target, highlight it, build the
// registry menu (+ the Show cascade), run it, dispatch the choice.
static void ctx_menu_at(int mx, int my) {
    browser *b; int tentry, tdeskobj;
    int scope = ctx_resolve(mx, my, &b, &tentry, &tdeskobj);
    if (b && tentry >= 0 && (b->sel != tentry || b->selall)) { b->sel = tentry; b->selall = 0; wind_redraw(); }
    g_ctx_mx = mx; g_ctx_my = my;                        // browse popups open at the right-click point
    ctxrow crows[24]; menu_item items[24], show[12]; int nshow;
    int n = ctx_build_items(scope, crows, 24, items, show, &nshow, b);
    if (n <= 0) return;
    int chosen = menu_popup(items, n, mx, my);
    ctx_apply(chosen, crows, scope, b, tentry, tdeskobj);
}

// Headless drain: pump pending async requests to completion so the --fuji*
// modes stay synchronous end-to-end.  max_s is a wall-clock cap for wedged
// servers (the daemon's own mount timeout lands a -err well inside it).
static int net_drain(int max_s) {
    for (int i = 0; i < max_s * 100; i++) {           // 10ms ticks
        net_pump();
        if (!net_pending()) return 1;
        usleep(10000);
    }
    fprintf(stderr, "net_drain: still pending after %ds\n", max_s);
    return 0;
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

// ---- scripted event source (headless replay, --fuji-add) --------------------
// A canned aes_event[] drives the full interactive stack — evnt_multi,
// br_click, form_do — with no SDL.  SE_SNAP dumps the composited frame to a
// PPM mid-replay (so a modal dialog can be captured while it is up); running
// off the end delivers AES_QUIT, which unwinds every loop cleanly.
typedef struct { int op, x, y, key, shift; const char *path; } sev;
enum { SE_END = 0, SE_DOWN, SE_UP, SE_MOVE, SE_KEY, SE_SNAP };
static sev g_fa[160];
static int g_fan, g_sbtn;
static void fa_push(int op, int x, int y, int key, int shift, const char *path) {
    if (g_fan < (int)(sizeof g_fa / sizeof g_fa[0]) - 1)
        g_fa[g_fan++] = (sev){ op, x, y, key, shift, path };
}
static void fa_keys(const char *s) { for (; *s; s++) fa_push(SE_KEY, 0,0, *s, 0, NULL); }
static const sev *g_script;
static int script_events(aes_event *ev, int timeout_ms) {
    (void)timeout_ms;
    for (;;) {
        const sev *s = g_script;
        if (!s || s->op == SE_END) { ev->type = AES_QUIT; return AES_QUIT; }
        g_script++;
        switch (s->op) {
            case SE_SNAP:
                dump_ppm(s->path);
                fprintf(stderr, "fuji-add: snap %s (dialog at %d,%d)\n",
                        s->path, as_dlg[0].ob_x, as_dlg[0].ob_y);
                continue;
            case SE_DOWN: g_sbtn = 1; ev->type = AES_BTN_DOWN; break;
            case SE_UP:   g_sbtn = 0; ev->type = AES_BTN_UP;   break;
            case SE_MOVE: ev->type = AES_MOTION; break;
            case SE_KEY:  ev->type = AES_KEY; break;
            default: continue;
        }
        ev->mx = s->x; ev->my = s->y; ev->button = g_sbtn;
        ev->key = s->key; ev->shift = s->shift;
        return ev->type;
    }
}
// Ask the daemon whether the row landed exactly as typed; returns its id (0 =
// no match) — the honest end-to-end check that add-server crossed the wire.
static int fa_verify_row(const char *name, const char *hostport,
                         const char *tr, const char *path) {
    int fd = fuji_connect();
    if (fd < 0) return 0;
    if (fuji_cmd(fd, "servers") != 0) { fuji_close(fd); return 0; }
    char ln[320]; int ok = 0, hdr = 0;
    while (fuji_readline(fd, ln, sizeof ln) == 1) {
        if (!hdr) { hdr = 1; if (ln[0] != '+') break; continue; }
        if (!strcmp(ln, ".")) break;
        int sid, off = 0; char trs[16], hp[160], pa[160];
        if (sscanf(ln, "%d %15s %159s %159s %n", &sid, trs, hp, pa, &off) < 4) continue;
        if (!strcmp(ln + off, name) && !strcmp(hp, hostport) &&
            !strcmp(trs, tr) && !strcmp(pa, path)) ok = sid;
    }
    fuji_close(fd);
    return ok;
}

static SDL_Renderer *g_ren; static SDL_Texture *g_tex; static int g_btn;
// Set for the one synthetic event a right-button *release* delivers, so the main
// loop routes it to the context menu instead of the normal left-click path.
// (Right-click acts on release so no pending button lands inside menu_popup and
// pre-selects a row.)  Reset every wait, so it's only ever true for that event.
static int g_rclick;
// SDL modifier state -> the classic Kbshift bits (aes_event.shift / kstate).
static int sdl_mods(void) {
    SDL_Keymod m = SDL_GetModState();
    return ((m & KMOD_RSHIFT) ? K_RSHIFT : 0) | ((m & KMOD_LSHIFT) ? K_LSHIFT : 0)
         | ((m & KMOD_CTRL)   ? K_CTRL   : 0) | ((m & KMOD_ALT)    ? K_ALT    : 0)
         | ((m & KMOD_CAPS)   ? K_CAPS   : 0);
}
// SDL keysym -> AES key: low byte = ASCII (shift-applied, US layout), high
// byte = Atari scancode for keys with no ASCII.  0 = nothing to deliver.
static int sdl_map_key(SDL_Keycode k, int shift) {
    switch (k) {
        case SDLK_RETURN: case SDLK_KP_ENTER: return '\r';
        case SDLK_BACKSPACE: return 0x08;
        case SDLK_TAB:       return 0x09;
        case SDLK_ESCAPE:    return 0x1b;
        case SDLK_UP:        return XK_UP << 8;
        case SDLK_DOWN:      return XK_DOWN << 8;
        case SDLK_LEFT:      return XK_LEFT << 8;
        case SDLK_RIGHT:     return XK_RIGHT << 8;
        case SDLK_HOME:      return XK_HOME << 8;
        case SDLK_DELETE:    return XK_DEL << 8;
        case SDLK_INSERT:    return XK_INS << 8;
        default: break;
    }
    if (k >= SDLK_F1 && k <= SDLK_F10) return (XK_F1 + (int)(k - SDLK_F1)) << 8;
    if (k < 32 || k > 126) return 0;                      // bare modifier / unmapped
    int c = (int)k, sh = (shift & (K_LSHIFT | K_RSHIFT)) != 0;
    if (c >= 'a' && c <= 'z') {
        if (sh != ((shift & K_CAPS) != 0)) c -= 32;       // uppercase
    } else if (sh) {                                      // US-layout shifted symbols
        static const char *from = "1234567890-=[]\\;',./`";
        static const char *to   = "!@#$%^&*()_+{}|:\"<>?~";
        const char *f = strchr(from, (char)c);
        if (f) c = to[f - from];
    }
    return c;
}
static int present_and_wait(aes_event *ev, int timeout_ms) {
    g_rclick = 0;                                        // valid only for the event we return below
    SDL_UpdateTexture(g_tex, NULL, g_desk->px, g_desk->stride*(int)sizeof(uint32_t));
    SDL_SetRenderDrawColor(g_ren,0,0,0,255); SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, NULL); SDL_RenderPresent(g_ren);   // logical size scales it
    SDL_Event e;
    int got=(timeout_ms<0)?SDL_WaitEvent(&e):SDL_WaitEventTimeout(&e,timeout_ms);
    ev->button=g_btn; ev->shift=sdl_mods(); if(!got){ ev->type=AES_TIMER; return AES_TIMER; }
    do { switch(e.type){
        case SDL_QUIT: ev->type=AES_QUIT; return AES_QUIT;
        case SDL_KEYDOWN: {
            ev->shift = sdl_mods();
            int k = sdl_map_key(e.key.keysym.sym, ev->shift);
            if (!k) break;                                 // modifier-only press
            ev->type=AES_KEY; ev->key=k; return AES_KEY; }
        case SDL_MOUSEMOTION: ev->type=AES_MOTION; ev->mx=e.motion.x; ev->my=e.motion.y; return AES_MOTION;
        case SDL_MOUSEBUTTONDOWN:
            if(e.button.button==SDL_BUTTON_RIGHT) break;   // right button: acted on at release
            if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn|=1; ev->button=g_btn; ev->type=AES_BTN_DOWN; ev->mx=e.button.x; ev->my=e.button.y; return AES_BTN_DOWN;
        case SDL_MOUSEBUTTONUP:
            if(e.button.button==SDL_BUTTON_RIGHT){         // deliver a context-menu click at the release point
                g_rclick=1; ev->type=AES_BTN_DOWN; ev->button=1; ev->mx=e.button.x; ev->my=e.button.y; return AES_BTN_DOWN; }
            if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn&=~1; ev->button=g_btn; ev->type=AES_BTN_UP; ev->mx=e.button.x; ev->my=e.button.y; return AES_BTN_UP;
    }} while(SDL_PollEvent(&e));
    ev->type=AES_NONE; return AES_NONE;
}
// aes_flush_rect hook: modal draws (dialogs, fetch progress) present here too,
// not just inside the event wait.  (The logical size scales the full frame.)
static void host_flush(int x, int y, int w, int h) {
    (void)x; (void)y; (void)w; (void)h;
    if (!g_ren) return;
    SDL_UpdateTexture(g_tex, NULL, g_desk->px, g_desk->stride*(int)sizeof(uint32_t));
    SDL_SetRenderDrawColor(g_ren,0,0,0,255); SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, NULL); SDL_RenderPresent(g_ren);
}

int main(int argc, char **argv) {
    int ppm = 0, sel = 0, browse = 0, fuji = 0, fuji_id = 0;
    const char *fuji_path = NULL;
    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--ppm")) ppm = 1;
        else if (!strcmp(argv[i], "--sel")) sel = 1;      // headless: pre-select the first icon
        else if (!strcmp(argv[i], "--browse")) browse = 1;// headless: open the 8-bit browser
        else if (!strcmp(argv[i], "--launch")) browse = 2;// headless: browser + a launched game
        else if (!strcmp(argv[i], "--fuji")) fuji = 1;    // headless: open the FujiNet servers window
        else if (!strcmp(argv[i], "--fuji-browse") && i+1 < argc)   // headless: + net browser on <id>
            { fuji = 2; fuji_id = atoi(argv[++i]); }
        else if (!strcmp(argv[i], "--fuji-fetch") && i+2 < argc)    // headless: + fetch <id> <path>
            { fuji = 3; fuji_id = atoi(argv[++i]); fuji_path = argv[++i]; }
        else if (!strcmp(argv[i], "--fuji-add")) fuji = 4;          // headless: Add-Server replay
        else if (!strcmp(argv[i], "--fuji-listprog") && i+2 < argc) // headless: listing-progress <id> <dir>
            { fuji = 5; fuji_id = atoi(argv[++i]); fuji_path = argv[++i]; }
        else if (!strcmp(argv[i], "--nav")) fuji = 6;               // headless: ".."/breadcrumb/Fit render
        else if (!strcmp(argv[i], "--views")) fuji = 7;             // headless: text view-mode render
        else if (!strcmp(argv[i], "--mask")) fuji = 8;              // headless: file-mask filter render
        else if (!strcmp(argv[i], "--ctx"))  fuji = 9;              // headless: right-click context menu
        else if (!strcmp(argv[i], "--browsenav")) fuji = 10;        // headless: browse navigator
        else if (!strcmp(argv[i], "--newdlg")) fuji = 11;           // headless: New… resource dialog
        else if (!strcmp(argv[i], "--title")) fuji = 12;            // headless: interactive title breadcrumb/mask
        else snprintf(base, sizeof base, "%s", argv[i]);
    }

    g_desk = gfx_surface_alloc(WIN_W, WIN_H);
    vdi_init(g_desk); HV = v_opnvwk(g_desk);
    // label font: the SD layout first (mirrors aesdesk's /OS/fonts), then the
    // repo copy so a bare dev tree still has text — regardless of cwd
    char fontp[320]; snprintf(fontp, sizeof fontp, "%s/OS/fonts/AovelSansRounded.ttf", base);
    font_face *ff = font_face_open(fontp);
    if (!ff) ff = font_face_open("fonts/AovelSansRounded.ttf");
    if (!ff) fprintf(stderr, "xtdesk: no label font (%s) — icon text will be missing\n", fontp);
    if (ff) font_face_set_tracking(ff, 1);
    vdi_set_face(ff);
    if (!load_theme()) { fprintf(stderr, "xtdesk: theme load failed (make themepack, or pass an OS dir)\n"); return 1; }
    aes_init(HV, &TH); appl_init();
    wind_set_desktop(0x30507800u);

    { char dbp[320]; snprintf(dbp, sizeof dbp, "%s/OS/var/registry.db", base);
      if (registry_open(dbp) != 0) fprintf(stderr, "xtdesk: no registry at %s\n", dbp);
      ctx_db_open(dbp); }                                // parallel read-only conn for contextMenu

    // Dialog resource: the SD layout first (mirrors aesdesk's /OS), then the repo
    // copy so a bare dev tree still has it — regardless of cwd.  On failure the
    // built-in hard-coded dialogs take over.
    { char rscp[320]; const char *err = NULL;
      snprintf(rscp, sizeof rscp, "%s/OS/Apps/Desktop/desktop.rsc", base);
      g_rsc = rscload_file(rscp, &err);
      if (!g_rsc) g_rsc = rscload_file("resources/desktop.rsc", &err);
      if (!g_rsc) fprintf(stderr, "xtdesk: no desktop.rsc (%s) — using built-in dialogs\n", err ? err : rscp); }
    load_wall();
    build_desktop();
    wind_set_desktop_content(deskcontent, NULL);
    if (sel && n_icons) desk[1].ob_state |= OS_SELECTED;
    if (browse) { open_browser("/Media/6502/Games", ICT_MEDIA_8BIT); if (sel) BR[0].sel = 0; }
    if (browse == 2) desk_launch("River Raid.atr", ICT_MEDIA_8BIT);
    wind_redraw();

    if (fuji == 6) {                                  // headless nav-chrome render (".."/breadcrumb/Fit)
        open_browser("/navtest", ICT_MEDIA_8BIT);     // local browser rooted at <base>/navtest
        browser *nb = BR[0].used ? &BR[0] : NULL;
        if (!nb) { fprintf(stderr, "nav: no browser (mkdir <base>/navtest/a/b/c first)\n"); return 1; }
        snprintf(nb->rel, sizeof nb->rel, "a/b");     // descend two levels
        br_list(nb); br_settitle(nb);
        wind_redraw();                                 // runs br_infobar -> lays out the crumbs
        dump_ppm("/tmp/xtdesk-nav.ppm");
        int dot_ok = (nb->tree[1].ob_type == G_CICON && nb->tree[1].ob_spec == (void*)&g_dotcic);
        // Title crumbs are the FULL absolute path "/navtest/a/b": segments
        // navtest(cut=8) a(cut=10) b(cut=12), each truncating crumbpath.
        int crumb_ok = (nb->ncrumb == 3 && nb->crumbcut[0] == 8 &&
                        nb->crumbcut[1] == 10 && nb->crumbcut[2] == 12);
        fprintf(stderr, "nav: rel=%s nent=%d  '..' first=%s  ncrumb=%d path=%s (%s)\n",
                nb->rel, nb->nent, dot_ok ? "OK" : "FAIL", nb->ncrumb, nb->crumbpath, crumb_ok ? "OK" : "FAIL");
        for (int c = 0; c < nb->ncrumb; c++)
            fprintf(stderr, "  crumb %d x=%d w=%d cut=%d\n",
                    c, nb->crumbx[c], nb->crumbw[c], nb->crumbcut[c]);
        if (nb->ncrumb >= 2)                           // click the "a" breadcrumb -> re-list at rel="a"
            br_click(nb, nb->crumbx[1] + 2, nb->titley + nb->titleh/2);
        int click_ok = !strcmp(nb->rel, "a");
        fprintf(stderr, "nav: breadcrumb click 'a' -> rel=\"%s\" (%s)\n", nb->rel, click_ok ? "OK" : "FAIL");
        wind_redraw();                                 // refresh Fit rect at the new level
        int bx0,by0,bw0,bh0; wind_get(nb->win, WF_CURRXYWH, &bx0,&by0,&bw0,&bh0);
        if (nb->fitw > 0)                              // click Fit -> resize window to contents
            br_click(nb, nb->fitx + 2, nb->infoy + nb->infoh/2);
        int bx1,by1,bw1,bh1; wind_get(nb->win, WF_CURRXYWH, &bx1,&by1,&bw1,&bh1);
        int fit_ok = (bx1 == bx0 && by1 == by0 && (bw1 != bw0 || bh1 != bh0));
        fprintf(stderr, "nav: Fit %dx%d -> %dx%d topleft (%d,%d)->(%d,%d) (%s)\n",
                bw0,bh0, bw1,bh1, bx0,by0, bx1,by1, fit_ok ? "OK" : "FAIL");
        dump_ppm("/tmp/xtdesk-nav-fit.ppm");
        registry_close();
        return (dot_ok && crumb_ok && click_ok && fit_ok) ? 0 : 1;
    }
    if (fuji == 12) {                                 // headless interactive-title test (--title)
        // Open a browser a couple of levels deep; the title shows the FULL
        // absolute path "/Media/6502/Games" as clickable segments + "/*.*".
        open_browser("/Media/6502/Games", ICT_MEDIA_8BIT);
        browser *nb = BR[0].used ? &BR[0] : NULL;
        if (!nb) { fprintf(stderr, "title: no browser (mkdir <base>/Media/6502/Games first)\n"); return 1; }
        wind_redraw();                                // draw_one -> br_title lays out the crumbs + mask
        // Every absolute level is a segment: Media(cut=6) 6502(cut=11) Games(cut=17).
        int path_ok = !strcmp(nb->crumbpath, "/Media/6502/Games");
        int seg_ok  = (nb->ncrumb == 3 && nb->crumbcut[0] == 6 &&
                       nb->crumbcut[1] == 11 && nb->crumbcut[2] == 17);
        int mask_ok = (nb->maskw > 0 && nb->maskx > nb->crumbx[nb->ncrumb-1]);
        fprintf(stderr, "title: path=\"%s\" ncrumb=%d maskx=%d maskw=%d (%s/%s/%s)\n",
                nb->crumbpath, nb->ncrumb, nb->maskx, nb->maskw,
                path_ok ? "OK" : "FAIL", seg_ok ? "OK" : "FAIL", mask_ok ? "OK" : "FAIL");
        for (int c = 0; c < nb->ncrumb; c++)
            fprintf(stderr, "  seg %d x=%d w=%d cut=%d\n", c, nb->crumbx[c], nb->crumbw[c], nb->crumbcut[c]);
        dump_ppm("/tmp/xtdesk-title.ppm");            // shows "/Media/6502/Games/*.*"
        // A click at the mask span resolves to the mask (not a crumb) — the same
        // hit-test br_click runs before opening mask_dialog.
        int mcx = nb->maskx + 2, mcy = nb->titley + nb->titleh/2, hit_mask = 0;
        if (nb->maskw > 0 && mcy >= nb->titley && mcy < nb->titley + nb->titleh &&
            mcx >= nb->maskx && mcx < nb->maskx + nb->maskw) hit_mask = 1;
        for (int c = 0; c < nb->ncrumb; c++)          // must NOT also fall on a crumb
            if (mcx >= nb->crumbx[c] && mcx < nb->crumbx[c] + nb->crumbw[c]) hit_mask = 0;
        fprintf(stderr, "title: mask hit-test at (%d,%d) -> %s\n", mcx, mcy, hit_mask ? "OK" : "FAIL");
        // Click the "Media" segment (an ancestor ABOVE the open root) -> re-root
        // the window to /Media (rel="").
        br_click(nb, nb->crumbx[0] + 2, nb->titley + nb->titleh/2);
        int up_ok = (!strcmp(nb->logical_root, "/Media") && nb->rel[0] == 0);
        fprintf(stderr, "title: click 'Media' -> root=\"%s\" rel=\"%s\" (%s)\n",
                nb->logical_root, nb->rel, up_ok ? "OK" : "FAIL");
        registry_close();
        return (path_ok && seg_ok && mask_ok && hit_mask && up_ok) ? 0 : 1;
    }
    if (fuji == 7) {                                  // headless text view-mode render (--views)
        open_browser("/navtest/many", ICT_MEDIA_8BIT);   // a dir with many files
        browser *nb = BR[0].used ? &BR[0] : NULL;
        if (!nb) { fprintf(stderr, "views: no browser (mkdir <base>/navtest/many first)\n"); return 1; }
        // 1) icons (the default), then drive the info-bar toggle to cycle modes.
        nb->viewmode = 1; wind_redraw(); dump_ppm("/tmp/xtdesk-views-icons.ppm");
        br_click(nb, nb->viewx + 2, nb->infoy + nb->infoh/2);   // View -> single
        wind_redraw();
        int c1, r1, cw1, nt1; br_text_grid(nb, &c1, &r1, &cw1, &nt1);
        int single_ok = (nb->viewmode == 2 && c1 == 1 && nt1 == nb->nent);
        dump_ppm("/tmp/xtdesk-views-single.ppm");
        fprintf(stderr, "views: single mode=%d cols=%d rows=%d ntile=%d (%s)\n",
                nb->viewmode, c1, r1, nt1, single_ok ? "OK" : "FAIL");
        br_click(nb, nb->viewx + 2, nb->infoy + nb->infoh/2);   // View -> multi
        wind_redraw();
        int c2, r2, cw2, nt2; br_text_grid(nb, &c2, &r2, &cw2, &nt2);
        int multi_ok = (nb->viewmode == 3 && c2 > 1);
        dump_ppm("/tmp/xtdesk-views-multi.ppm");
        fprintf(stderr, "views: multi mode=%d cols=%d rows=%d (%s)\n",
                nb->viewmode, c2, r2, multi_ok ? "OK" : "FAIL");
        // 2) geometry <-> index round-trip at the multi default width (this is the
        // math br_click uses to resolve a click / double-click to an entry).
        int geom_ok = 1, dd = nb->rel[0] ? 1 : 0;
        for (int s = 0; s < nt2; s++) {
            int cx, cy, cw, ch; br_text_cell(nb, s, &cx, &cy, &cw, &ch);
            int hit = br_text_hit(nb, cx + cw/2, cy + ch/2);
            if (hit != s) { geom_ok = 0; fprintf(stderr, "views: slot %d center hit->%d MISMATCH\n", s, hit); }
        }
        if (nt2 > 5) {                                   // show a resolved entry for a sample slot
            int cx, cy, cw, ch; br_text_cell(nb, 5, &cx, &cy, &cw, &ch);
            int hs = br_text_hit(nb, cx + cw/2, cy + ch/2);
            fprintf(stderr, "views: slot 5 -> entry[%d] = \"%s\"\n", hs - dd, nb->ent[hs - dd].name);
        }
        fprintf(stderr, "views: geometry<->index round-trip %s\n", geom_ok ? "OK" : "FAIL");
        // 3) responsive columns: same multi view at two widths must reflow.
        int wx, wy, ww, wh; wind_get(nb->win, WF_CURRXYWH, &wx, &wy, &ww, &wh);
        int bx, by, bw, bh;
        wind_calc(WC_BORDER, BR_WKIND, wx, wy, 1200, 520, &bx, &by, &bw, &bh);
        wind_open(nb->win, bx, by, bw, bh); wind_redraw();
        int cwide, rwide, cwwide, ntwide; br_text_grid(nb, &cwide, &rwide, &cwwide, &ntwide);
        wind_calc(WC_BORDER, BR_WKIND, wx, wy, 420, 520, &bx, &by, &bw, &bh);
        wind_open(nb->win, bx, by, bw, bh); wind_redraw();
        int cnar, rnar, cwnar, ntnar; br_text_grid(nb, &cnar, &rnar, &cwnar, &ntnar);
        int resp_ok = (cwide > cnar);
        fprintf(stderr, "views: responsive cols wide=%d narrow=%d (%s)\n",
                cwide, cnar, resp_ok ? "OK" : "FAIL");
        registry_close();
        return (single_ok && multi_ok && geom_ok && resp_ok) ? 0 : 1;
    }
    if (fuji == 8) {                                  // headless file-mask filter test (--mask)
        // 1) glob helper unit checks (case-insensitive '*' / '?').
        struct { const char *pat, *nm; int want; } gt[] = {
            { "*.gif", "pic1.gif", 1 }, { "*.gif", "readme.txt", 0 },
            { "*.GIF", "pic1.gif", 1 }, { "*.gif", "PIC2.GIF", 1 },
            { "*",     "anything", 1 }, { "pic?.gif", "pic2.gif", 1 },
            { "pic?.gif", "pic10.gif", 0 }, { "*.x*", "a.xex", 1 }, { "*.x*", "a.txt", 0 },
        };
        int glob_ok = 1;
        for (int i = 0; i < (int)(sizeof gt / sizeof gt[0]); i++) {
            int got = glob_ci(gt[i].pat, gt[i].nm);
            if (got != gt[i].want) { glob_ok = 0;
                fprintf(stderr, "mask: glob(%s,%s)=%d want %d FAIL\n", gt[i].pat, gt[i].nm, got, gt[i].want); }
        }
        fprintf(stderr, "mask: glob unit %s\n", glob_ok ? "OK" : "FAIL");
        // 2) open a local browser on a mixed-extension dir; filter to "*.gif".
        open_browser("/navtest/many", ICT_MEDIA_8BIT);
        browser *nb = BR[0].used ? &BR[0] : NULL;
        if (!nb) { fprintf(stderr, "mask: no browser (mkdir <base>/navtest/many first)\n"); return 1; }
        int all_n = nb->nent;
        snprintf(nb->mask, sizeof nb->mask, "*.gif");
        br_list(nb); br_settitle(nb); wind_redraw();
        int gif = 0, nongif = 0, dirs = 0;
        for (int i = 0; i < nb->nent; i++) {
            if (nb->ent[i].dir) { dirs++; continue; }
            if (glob_ci("*.gif", nb->ent[i].name)) gif++; else nongif++;
        }
        int mask_ok = (nongif == 0 && gif > 0);
        dump_ppm("/tmp/xtdesk-mask.ppm");
        fprintf(stderr, "mask: all=%d  '*.gif' nent=%d gif=%d nongif=%d dirs=%d (%s)\n",
                all_n, nb->nent, gif, nongif, dirs, mask_ok ? "OK" : "FAIL");
        // 3) switching back to "*" shows everything again.
        snprintf(nb->mask, sizeof nb->mask, "*");
        br_list(nb); br_settitle(nb); wind_redraw();
        int restore_ok = (nb->nent == all_n);
        fprintf(stderr, "mask: restore '*' nent=%d (%s)\n", nb->nent, restore_ok ? "OK" : "FAIL");
        registry_close();
        return (glob_ok && mask_ok && restore_ok) ? 0 : 1;
    }
    if (fuji == 9) {                                  // headless right-click context-menu test (--ctx)
        open_browser("/navtest/many", ICT_MEDIA_8BIT);
        browser *nb = BR[0].used ? &BR[0] : NULL;
        if (!nb) { fprintf(stderr, "ctx: no browser (mkdir <base>/navtest/many first)\n"); return 1; }
        nb->viewmode = 1; wind_redraw();              // icon view so the tile grid is laid out
        // (a) right-click entry 0 -> icon scope; the items come from the registry.
        int ex, ey; objc_offset(nb->tree, 1 + (nb->rel[0] ? 1 : 0), &ex, &ey);
        ex += ICON_CW/2; ey += ICON_SZ/2;             // tile centre
        browser *tb; int te, tdo;
        int scope = ctx_resolve(ex, ey, &tb, &te, &tdo);
        ctxrow crows[24]; menu_item items[24], show[12]; int nshow;
        int n = ctx_build_items(scope, crows, 24, items, show, &nshow, tb);
        int has_open = 0, has_info = 0;
        for (int i = 0; i < n; i++) { if (!strcmp(crows[i].action, "open")) has_open = 1;
                                      if (!strcmp(crows[i].action, "info")) has_info = 1; }
        int reg_ok = (scope == 4 && tb == nb && te == 0 && n > 0 && has_open && has_info);
        fprintf(stderr, "ctx: entry right-click scope=%d target[%d]=\"%s\" n=%d open=%d info=%d (%s)\n",
                scope, te, te >= 0 ? nb->ent[te].name : "-", n, has_open, has_info, reg_ok ? "OK" : "FAIL");
        // (b) Show -> Sort by Size reorders the list by size.
        ctx_apply(SH_SORT_SIZE, crows, scope, nb, te, tdo);
        int sort_ok = 1; long prev = -1;
        for (int i = 0; i < nb->nent; i++) {
            if (nb->ent[i].dir) continue;
            if (prev >= 0 && (nb->sortinv ? nb->ent[i].size > prev : nb->ent[i].size < prev)) sort_ok = 0;
            prev = nb->ent[i].size;
        }
        fprintf(stderr, "ctx: Show>Sort>Size sortmode=%d inv=%d monotone=%s\n",
                nb->sortmode, nb->sortinv, sort_ok ? "OK" : "FAIL");
        // (c) Show -> view Columns switches the view mode.
        ctx_apply(SH_VIEW_COLS, crows, scope, nb, te, tdo);
        int view_ok = (nb->viewmode == 3);
        fprintf(stderr, "ctx: Show>view>Columns viewmode=%d (%s)\n", nb->viewmode, view_ok ? "OK" : "FAIL");
        // (d) render one open menu (window scope: the richest set, incl. Show) + its
        // cascade to a PPM, via menu_popup's render path (no modal loop).
        nb->viewmode = 1;
        int wn = ctx_build_items(3, crows, 24, items, show, &nshow, nb);
        popup_geom pg; menu_popup_layout(items, wn, 720, 300, &pg);
        wind_redraw();                                // desktop + window under the popup
        menu_popup_render_demo(items, wn, 0, &pg);
        int showrow = -1; for (int i = 0; i < wn; i++) if (items[i].sub) showrow = i;
        if (showrow >= 0) {
            popup_geom sg; menu_popup_layout(items[showrow].sub, items[showrow].nsub, pg.x + pg.w - 2, pg.y, &sg);
            menu_popup_render_demo(items[showrow].sub, items[showrow].nsub, 0, &sg);
        }
        dump_ppm("/tmp/xtdesk-ctx.ppm");
        fprintf(stderr, "ctx: wrote /tmp/xtdesk-ctx.ppm (window-scope menu, %d items + Show cascade)\n", wn);
        registry_close(); ctx_db_close();
        return (reg_ok && sort_ok && view_ok) ? 0 : 1;
    }
    if (fuji == 11) {                                // headless New… resource-dialog test (--newdlg)
        if (!g_rsc) { fprintf(stderr, "newdlg: no desktop.rsc under %s/OS/Apps/Desktop\n", base); return 1; }
        OBJECT *t = rscload_tree(g_rsc, 0);
        int link = t ? rscload_ext(g_rsc, 0, NEW_POPUP) : -1;
        int struct_ok = t && t[NEW_ROOT].ob_type == G_BOX
            && (t[NEW_FOLDER].ob_flags & OF_RBUTTON) && (t[NEW_FILE].ob_flags & OF_RBUTTON)
            && t[NEW_POPUP].ob_type == G_POPUP && link == 1
            && t[NEW_NAME].ob_type == G_FTEXT
            && (t[NEW_OK].ob_flags & OF_DEFAULT) && (t[NEW_CANCEL].ob_flags & OF_CANCEL);
        fprintf(stderr, "newdlg: structure box+radios+popup(link=%d)+ftext+ok/cancel (%s)\n",
                link, struct_ok ? "OK" : "FAIL");

        // File selected -> Type popup shown; Folder -> hidden (via new_hook).
        t[NEW_FOLDER].ob_state &= ~OS_SELECTED; t[NEW_FILE].ob_state |= OS_SELECTED;
        new_hook(t, NEW_FILE, NULL);
        int shown_ok = !(t[NEW_POPUP].ob_flags & OF_HIDETREE) && !(t[NEW_TYPELBL].ob_flags & OF_HIDETREE);
        t[NEW_FILE].ob_state &= ~OS_SELECTED; t[NEW_FOLDER].ob_state |= OS_SELECTED;
        new_hook(t, NEW_FOLDER, NULL);
        int hidden_ok = (t[NEW_POPUP].ob_flags & OF_HIDETREE) && (t[NEW_TYPELBL].ob_flags & OF_HIDETREE);
        fprintf(stderr, "newdlg: File->Type shown %s ; Folder->Type hidden %s\n",
                shown_ok ? "OK" : "FAIL", hidden_ok ? "OK" : "FAIL");

        // Simulate choosing ".html" from the Type popup's linked menu tree.
        OBJECT *menu = rscload_tree(g_rsc, link);
        for (int c = menu[0].ob_head; c >= 0; c = (c == menu[0].ob_tail ? -1 : menu[c].ob_next))
            if (menu[c].ob_type == G_STRING && menu[c].ob_spec && !strcmp((char *)menu[c].ob_spec, ".html"))
                t[NEW_POPUP].ob_spec = menu[c].ob_spec;
        int val_ok = !strcmp((const char *)t[NEW_POPUP].ob_spec, ".html");
        fprintf(stderr, "newdlg: popup pick '.html' value=\"%s\" (%s)\n",
                (const char *)t[NEW_POPUP].ob_spec, val_ok ? "OK" : "FAIL");

        // OK with File + .html + name "testfile" -> create <base>/navtest/testfile.html.
        char dir[400]; snprintf(dir, sizeof dir, "%s/navtest", base); mkdir(dir, 0777);
        char full[520]; snprintf(full, sizeof full, "%s/testfile.html", dir);
        remove(full);
        FILE *cf = fopen(full, "w"); if (cf) fclose(cf);
        struct stat stt; int created = (stat(full, &stt) == 0);
        fprintf(stderr, "newdlg: create %s (%s)\n", full, created ? "OK" : "FAIL");
        remove(full);

        // Render the dialog (File selected, Type popup visible) to a PPM.
        t[NEW_FOLDER].ob_state &= ~OS_SELECTED; t[NEW_FILE].ob_state |= OS_SELECTED;
        new_hook(t, NEW_FILE, NULL);
        TEDINFO *te = (TEDINFO *)t[NEW_NAME].ob_spec; char nb2[64] = "testfile";
        char *sv = te->te_ptext; te->te_ptext = nb2;
        int wx, wy, ww, wh; wind_get(0, WF_WORKXYWH, &wx, &wy, &ww, &wh);
        t[0].ob_x = (int16_t)(wx + (ww - t[0].ob_w) / 2);
        t[0].ob_y = (int16_t)(wy + (wh - t[0].ob_h) / 2);
        wind_redraw();
        objc_draw(t, 0, 8, 0, 0, WIN_W, WIN_H);
        dump_ppm("/tmp/xtdesk-newdlg.ppm");
        te->te_ptext = sv;
        fprintf(stderr, "newdlg: wrote /tmp/xtdesk-newdlg.ppm\n");
        if (g_rsc) rscload_free(g_rsc); g_rsc = NULL;
        registry_close(); ctx_db_close();
        return (struct_ok && shown_ok && hidden_ok && val_ok && created) ? 0 : 1;
    }
    if (fuji == 10) {                                // headless browse-navigator test (--browsenav)
        char nav[400]; snprintf(nav, sizeof nav, "%s/navtest", base);
        // (a) the expand provider for <base>/navtest yields lazy dirs (a/, many/)
        // plus a file (root.xex): dirs carry MI_LAZY + a trailing "/", files don't.
        br_reset(); snprintf(br_rootpath, sizeof br_rootpath, "%s", nav);
        int root = br_intern(0, "", 1);                   // root node (id 1)
        menu_item *ri = NULL; int rn = 0;
        int got = br_expand(NULL, root, &ri, &rn);
        int has_a = 0, alazy = 0, aid = 0, has_many = 0, has_root = 0, rfile = 0;
        int distinct_ok = (rn > 0);                       // dirs: "/" + MI_LAZY; files: neither
        for (int i = 0; i < rn; i++) {
            int cid = ri[i].id; if (cid <= 0) continue;   // skip the "(more)" tail, if any
            br_node *c = &br_nodes[cid-1];
            int len = (int)strlen(ri[i].label), slash = len > 0 && ri[i].label[len-1] == '/';
            int lazy = (ri[i].flags & MI_LAZY) != 0;
            if (slash != c->isdir || lazy != c->isdir) distinct_ok = 0;
            if (!strcmp(c->name, "a"))        { has_a = 1; alazy = lazy; aid = cid; }
            if (!strcmp(c->name, "many"))       has_many = 1;
            if (!strcmp(c->name, "root.xex")) { has_root = 1; rfile = !c->isdir && !lazy; }
        }
        int build_ok = (got && has_a && alazy && has_many && has_root && rfile && distinct_ok);
        fprintf(stderr, "browsenav: expand root n=%d a(lazy=%d) many=%d root.xex(file=%d) distinct=%s (%s)\n",
                rn, alazy, has_many, rfile, distinct_ok?"OK":"FAIL", build_ok?"OK":"FAIL");
        // (b) expand "a" then "b" then "c" live via the provider; c holds
        // leaf1.xex + leaf2.atr.
        int cur = aid; const char *steps[2] = { "b", "c" }; int descend_ok = (aid > 0);
        menu_item *lv = NULL; int ln = 0;
        for (int s = 0; s < 2 && descend_ok; s++) {
            if (!br_expand(NULL, cur, &lv, &ln)) { descend_ok = 0; break; }
            int nx = 0;
            for (int i = 0; i < ln; i++) { int cid = lv[i].id;
                if (cid > 0 && br_nodes[cid-1].isdir && !strcmp(br_nodes[cid-1].name, steps[s])) nx = cid; }
            free(lv); lv = NULL;
            if (nx <= 0) { descend_ok = 0; break; }
            cur = nx;
        }
        int cl1 = 0, cl2 = 0, leaf = 0, cn = 0;
        if (descend_ok && br_expand(NULL, cur, &lv, &ln)) {
            cn = ln;
            for (int i = 0; i < ln; i++) { int cid = lv[i].id; if (cid <= 0) continue;
                if (!strcmp(br_nodes[cid-1].name, "leaf1.xex")) cl1 = 1;
                if (!strcmp(br_nodes[cid-1].name, "leaf2.atr")) { cl2 = 1; leaf = cid; } }
            free(lv); lv = NULL;
        }
        descend_ok = descend_ok && cl1 && cl2;
        fprintf(stderr, "browsenav: expand a/b/c -> nrows=%d leaf1=%d leaf2=%d (%s)\n",
                cn, cl1, cl2, descend_ok?"OK":"FAIL");
        // (c) a FILE id resolves to its absolute launch path.
        char lpath[512]; br_path(leaf, lpath, sizeof lpath);
        char expect[512]; snprintf(expect, sizeof expect, "%s/a/b/c/leaf2.atr", nav);
        int open_ok = (leaf > 0 && !br_nodes[leaf-1].isdir && !strcmp(lpath, expect));
        fprintf(stderr, "browsenav: file leaf2.atr id=%d -> \"%s\" (%s)\n", leaf, lpath, open_ok?"OK":"FAIL");
        // (d) a FOLDER id resolves to "open as folder window": its path is a
        // directory that strips to the logical path open_browser() roots at.
        char fpath[512]; br_path(aid, fpath, sizeof fpath);
        const char *logical = fpath; size_t bl = strlen(base);
        if (!strncmp(fpath, base, bl)) logical = fpath + bl;
        int folder_ok = (aid > 0 && br_nodes[aid-1].isdir && !strcmp(logical, "/navtest/a"));
        fprintf(stderr, "browsenav: folder 'a' id=%d dir=%d logical=\"%s\" (%s)\n",
                aid, aid>0?br_nodes[aid-1].isdir:0, logical, folder_ok?"OK":"FAIL");
        // ctx_browse wiring: window scope -> the window's current dir.
        open_browser("/navtest", ICT_MEDIA_8BIT);
        browser *wb = BR[0].used ? &BR[0] : NULL;
        char stt[512]; int scope_ok = 0;
        if (wb) scope_ok = ctx_browse_start(3, wb, -1, 0, stt, sizeof stt) && !strcmp(stt, nav);
        fprintf(stderr, "browsenav: window-scope start=\"%s\" (%s)\n", wb?stt:"-", scope_ok?"OK":"FAIL");
        // render one open cascade (root + the 'a/' submenu expanded) to a PPM via
        // the menu render path (no modal loop).
        wind_redraw();
        popup_geom pg; menu_popup_layout(ri, rn, 220, 160, &pg);
        int subrow = -1; for (int i = 0; i < rn; i++) if (ri[i].id == aid) subrow = i;
        menu_popup_render_demo(ri, rn, subrow >= 0 ? subrow : 0, &pg);
        menu_item *sub = NULL; int sn = 0;
        if (aid > 0 && br_expand(NULL, aid, &sub, &sn)) {
            popup_geom sg; menu_popup_layout(sub, sn, pg.x + pg.w - 2, pg.y, &sg);
            menu_popup_render_demo(sub, sn, 0, &sg);
            free(sub);
        }
        dump_ppm("/tmp/xtdesk-browse2.ppm");
        fprintf(stderr, "browsenav: wrote /tmp/xtdesk-browse2.ppm (root + 'a/' cascade)\n");
        free(ri);
        registry_close(); ctx_db_close();
        return (build_ok && descend_ok && open_ok && folder_ok && scope_ok) ? 0 : 1;
    }
    if (fuji == 4) {                                  // headless Add-Server dialog replay
        open_fuji_servers();
        net_drain(60);                                // servers list settles
        wind_redraw();                                // lay the tiles out (br_layout)
        browser *sb = &BR[0];
        int add = -1;
        for (int i = 0; i < sb->nent; i++) if (sb->ent[i].srvid < 0) add = i;
        if (!sb->used || add < 0) { fprintf(stderr, "fuji-add: no Add-server tile\n"); return 1; }
        int tx, ty; objc_offset(sb->tree, 1 + add, &tx, &ty);
        tx += ICON_CW/2; ty += ICON_SZ/2;             // tile centre
        int wx, wy, ww, wh; wind_get(0, WF_WORKXYWH, &wx, &wy, &ww, &wh);
        int dx = wx + (ww - AS_W)/2, dy = wy + (wh - AS_H)/2;   // where the dialog centres
        // the replay: double-click the tile; type; Alt-T mnemonic; TAB / Esc-clear /
        // Shift-TAB traversal; snap; fly-corner drag; snap; Return submits.
        fa_push(SE_DOWN, tx, ty, 0,0,0); fa_push(SE_UP, tx, ty, 0,0,0);
        fa_push(SE_DOWN, tx, ty, 0,0,0); fa_push(SE_UP, tx, ty, 0,0,0);
        fa_keys("127.0.0.1:16917");                   // Host (focused on entry)
        fa_push(SE_KEY, 0,0, 't', K_ALT, 0);          // mnemonic: Alt-T -> tcp radio
        fa_push(SE_KEY, 0,0, 0x09, 0, 0);             // TAB -> Path (holds "/")
        fa_push(SE_KEY, 0,0, 0x1b, 0, 0);             // Esc stage 1: clears the field
        fa_keys("/data");
        fa_push(SE_KEY, 0,0, 0x09, 0, 0);             // TAB -> Name
        fa_push(SE_KEY, 0,0, 0x09, K_LSHIFT, 0);      // Shift-TAB back to Path
        fa_push(SE_KEY, 0,0, 0x09, 0, 0);             // TAB -> Name again
        fa_keys("Test Box");
        fa_push(SE_SNAP, 0,0,0,0, "/tmp/xtdesk-addsrv.ppm");
        fa_push(SE_DOWN, dx + AS_W - 8, dy + 8, 0,0,0);          // grab the fly corner
        fa_push(SE_MOVE, dx + AS_W - 8 + 40, dy + 8 + 30, 0,0,0);
        fa_push(SE_MOVE, dx + AS_W - 8 + 80, dy + 8 + 60, 0,0,0);
        fa_push(SE_UP,   dx + AS_W - 8 + 80, dy + 8 + 60, 0,0,0);
        fa_push(SE_SNAP, 0,0,0,0, "/tmp/xtdesk-addsrv-moved.ppm");
        fa_push(SE_KEY, 0,0, '\r', 0, 0);             // Return fires OK (OF_DEFAULT)
        fa_push(SE_END, 0,0,0,0,0);
        g_script = g_fa;
        aes_set_events(script_events);
        aes_set_idle(net_pump, 40);                   // modal loops keep the pump alive
        for (;;) {                                    // the interactive loop, replayed
            int mx,my,mb,ks,key,nc; int16_t msg[8];
            int r = evnt_multi(MU_MESAG|MU_KEYBD|MU_BUTTON, 2,1,1, 0,0,0,0,0, 0,0,0,0,0,
                               msg, 0,0, &mx,&my,&mb,&ks,&key,&nc);
            net_pump();
            if (r & MU_QUIT) break;
            if (r & MU_MESAG && msg[0]==WM_CLOSED) wind_close(msg[3]);
            if (r & MU_BUTTON) {
                int wh2 = wind_find(mx, my); browser *bb = wh2 ? br_of_window(wh2) : NULL;
                if (bb) br_click(bb, mx, my); else desk_click(mx, my);
            }
        }
        net_drain(60);                                // the add + triggered re-list settle
        wind_redraw();
        dump_ppm("/tmp/xtdesk-addsrv2.ppm");
        int moved_ok = (as_dlg[0].ob_x == dx + 80 && as_dlg[0].ob_y == dy + 60);
        int tile_ok = 0;
        for (int i = 0; i < sb->nent; i++) if (!strcmp(sb->ent[i].label, "Test Box")) tile_ok = 1;
        int row_id = fa_verify_row("Test Box", "127.0.0.1:16917", "tcp", "/data");
        fprintf(stderr, "fuji-add: fly-corner move %s (dlg %d,%d expect %d,%d)\n",
                moved_ok ? "OK" : "FAIL", as_dlg[0].ob_x, as_dlg[0].ob_y, dx+80, dy+60);
        fprintf(stderr, "fuji-add: server tile %s, daemon row %s (id %d)\n",
                tile_ok ? "OK" : "FAIL", row_id ? "OK" : "FAIL", row_id);
        if (row_id) {                                 // leave the scratch registry re-runnable
            int fd = fuji_connect();
            if (fd >= 0) { char tmp[64];
                if (fuji_cmd(fd, "del-server %d", row_id) == 0) fuji_readline(fd, tmp, sizeof tmp);
                fuji_close(fd); }
        }
        registry_close();
        return (moved_ok && tile_ok && row_id) ? 0 : 1;
    }
    if (fuji == 5) {                                  // headless listing-progress capture
        open_fuji_servers();
        net_drain(60);                                // servers list settles
        browser *sb = &BR[0];
        for (int i = 0; sb->used && i < sb->nent; i++)
            if (sb->ent[i].srvid == fuji_id) { open_fuji_browser(fuji_id, sb->ent[i].label); break; }
        net_drain(60);                                // the root listing settles
        browser *nb = BR[1].used ? &BR[1] : NULL;
        if (!nb) { fprintf(stderr, "fuji-listprog: no net browser\n"); return 1; }
        // list a (large) subdir and snapshot mid-flight: pump until a partial set
        // of rows is in but the listing is still open (a big dir won't drain in
        // one 64-line pump), so the mid PPM shows the bar + partial list.
        snprintf(nb->rel, sizeof nb->rel, "%s", fuji_path);
        net_list_start(nb); br_settitle(nb);
        for (int k = 0; k < 400 && nb->req_fd >= 0 && nb->nent < 30; k++) {
            net_pump(); usleep(2000);
        }
        wind_redraw();
        dump_ppm("/tmp/xtdesk-listprog-mid.ppm");
        fprintf(stderr, "fuji-listprog: mid rows=%d total=%d inflight=%d\n",
                nb->nent, nb->req_total, nb->req_fd >= 0);
        net_drain(60);                                // finish the listing
        wind_redraw();
        dump_ppm("/tmp/xtdesk-listprog-final.ppm");
        fprintf(stderr, "fuji-listprog: final rows=%d total=%d\n", nb->nent, nb->req_total);
        registry_close();
        return 0;
    }
    if (fuji) {                                       // headless FujiNet render modes
        open_fuji_servers();
        net_drain(60);                                // async: settle before inspecting
        if (fuji >= 2 && BR[0].used) {                // find the server tile -> open its browser
            browser *sb = &BR[0];
            for (int i = 0; i < sb->nent; i++)
                if (sb->ent[i].srvid == fuji_id) { open_fuji_browser(fuji_id, sb->ent[i].label); break; }
            open_fuji_servers();                      // deliberate re-opens: both must
            open_fuji_browser(fuji_id, "dup?");       //   re-top, not duplicate
            net_drain(60);                            // dead server: its -err lands inside the cap
            int used = 0;
            for (int i = 0; i < MAXBR; i++) used += BR[i].used;
            fprintf(stderr, "fuji-browse: %d browser windows (expect 2)\n", used);
        }
        wind_redraw();
        dump_ppm(fuji == 1 ? "/tmp/xtdesk-fuji.ppm" : "/tmp/xtdesk-fujibr.ppm");
        if (fuji == 3 && BR[1].used) {                // fetch <path>'s entry, then re-render
            browser *nb = &BR[1];
            const char *nm = strrchr(fuji_path, '/'); nm = nm ? nm+1 : fuji_path;
            for (int i = 0; i < nb->nent; i++)
                if (!strcmp(nb->ent[i].name, nm)) { net_open(nb, i); break; }
            net_drain(60);                            // fetch + the triggered re-list
            wind_redraw();
            dump_ppm("/tmp/xtdesk-fujibr2.ppm");
        }
        registry_close();
        return 0;
    }
    if (ppm) { dump_ppm("/tmp/xtdesk.ppm"); registry_close(); return 0; }

    if (SDL_Init(SDL_INIT_VIDEO)!=0) { fprintf(stderr,"SDL: %s\n",SDL_GetError()); return 1; }
    SDL_Window *win = SDL_CreateWindow("XTOS Desktop", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIN_W, WIN_H, SDL_WINDOW_RESIZABLE);
    g_ren = SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    SDL_RenderSetLogicalSize(g_ren, WIN_W, WIN_H);   // 1920x1080 logical, scaled to the window
    g_tex = SDL_CreateTexture(g_ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    aes_set_events(present_and_wait);
    aes_set_idle(net_pump, 40);                       // modal loops (dialogs, drags) keep pumping
    wind_set_overlay(NULL, NULL, NULL, host_flush);   // aes_flush_rect -> present (modal draws)

    for (;;) {
        int mx,my,mb,ks,key,nc; int16_t msg[8];
        int pend = net_pending();                     // net I/O in flight: tick to pump it
        int r = evnt_multi(MU_MESAG|MU_KEYBD|MU_BUTTON|(pend?MU_TIMER:0), 2,1,1, 0,0,0,0,0, 0,0,0,0,0, msg, pend?40:0, 0, &mx,&my,&mb,&ks,&key,&nc);
        net_pump();                                   // drain any arrived reply lines
        if (r & MU_QUIT) break;
        if ((r & MU_KEYBD) && key == 0x1b) break;     // Esc at the desktop quits (as on the A9)
        if (r & MU_MESAG && msg[0]==WM_CLOSED) {
            browser *b = br_of_window(msg[3]);        // close cancels any in-flight request
            if (b) { net_req_close(b); br_free_icons(b); b->used = 0; }
            emuwin *e = emu_of_window(msg[3]); if (e) e->used = 0;
            wind_close(msg[3]);
        }
        if (r & MU_BUTTON) {
            if (g_rclick) { g_rclick = 0; ctx_menu_at(mx, my); }   // right-click -> context menu
            else {
                int wh = wind_find(mx, my); browser *b = wh ? br_of_window(wh) : NULL;
                if (b) br_click(b, mx, my); else desk_click(mx, my);
            }
        }
    }

    if (g_rsc) rscload_free(g_rsc);
    registry_close(); ctx_db_close();
    theme_free(&TH); if (ff) font_face_close(ff);
    if (g_wall) gfx_surface_free(g_wall);
    gfx_surface_free(g_desk);
    SDL_DestroyTexture(g_tex); SDL_DestroyRenderer(g_ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
