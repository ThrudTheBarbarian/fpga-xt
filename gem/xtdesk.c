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
#include "fujiclient.h"
#include "font.h"
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
// Three flavours share the struct + window plumbing: net=0 a local directory,
// net=1 the FujiNet servers window (one tile per registry server + "Add
// server"), net=2 a network browser over fujinetd (rel = the remote path).
#define MAXBR   6
#define MAXENT  128
typedef struct { char name[128], label[128]; int dir; long size;
                 char state; int srvid; } bent;     // state: lsc cache column; srvid: servers row (-1 = Add server)
typedef struct {
    int used, win, media_type, sel;
    int net, server_id;                               // net browser flavour (see above)
    char logical_root[128], fs_root[300], rel[256];   // rel = "" at the (rooted) top
    int nent, nfiles; long total;
    int req_fd, req_kind, req_hdr;                     // async fujinetd request (req_fd < 0 = idle)
    unsigned prog_done, prog_total;                    // fetch progress (pump-updated)
    char prog_name[64];                                // fetch display name
    char req_err[96];                                  // last async error (shown in the info bar)
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
// ---- FujiNet listings (fujiclient.c talks to fujinetd; the daemon does the
// TNFS + registry/netcache work).  All daemon I/O is ASYNC: *_start sends the
// command on a non-blocking fd and returns; net_pump() (driven from the event
// loop) feeds reply lines back in as they arrive, so the UI never blocks on
// the daemon (single-threaded, one client at a time — a reply can sit behind
// another window's transfer for minutes). ------------------------------------
enum { RQ_NONE = 0, RQ_SRV, RQ_LSC, RQ_FETCH, RQ_ADD };   // browser.req_kind

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
    int fd = fuji_connect();
    if (fd < 0 || fuji_cmd(fd, "servers") != 0) {     // no daemon: just the Add tile
        if (fd >= 0) fuji_close(fd);
        snprintf(b->req_err, sizeof b->req_err, "daemon not running");
        srv_finish(b);
        return;
    }
    fuji_set_nonblock(fd);
    b->req_fd = fd; b->req_kind = RQ_SRV;             // net_pump takes it from here
}
static void desk_busy(const char *msg);   // fwd

static void net_row(browser *b, const char *ln) {     // one `lsc` reply row -> an entry
    if (b->nent >= MAXENT || ln[0] == '-') return;
    char kind, cs; long size; int off = 0;            // "d <size> - <name>" | "f <size> <g|f|c|u> <name>"
    if (sscanf(ln, " %c %ld %c %n", &kind, &size, &cs, &off) < 3 || !ln[off]) return;
    bent *e = &b->ent[b->nent++];
    snprintf(e->name, sizeof e->name, "%s", ln + off);
    e->dir = (kind == 'd'); e->size = size;
    e->state = e->dir ? 0 : cs; e->srvid = 0;
}
static void net_finish(browser *b) {                  // rows all in: sort + icons
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
    { char m[160]; snprintf(m, sizeof m, "Contacting %s ...", b->logical_root);
      desk_busy(m); }                                 // click-instant feedback (non-blocking)
    br_free_icons(b);
    b->nent = 0; b->nfiles = 0; b->total = 0; b->sel = -1;
    b->req_err[0] = 0; b->req_hdr = 0;
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
            struct stat stt; e->dir = 0; e->size = 0; e->state = 0; e->srvid = 0;
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
        int ghost = (b->ent[i].state == 'g' || b->ent[i].state == 'f');   // uncached net entry
        b->tree[oi] = (OBJECT){ (int16_t)(last?0:oi+1), NIL, NIL, G_CICON,
                                (uint16_t)(OF_SELECTABLE | (last?OF_LASTOB:0)),
                                (uint16_t)((i == b->sel ? OS_SELECTED : OS_NORMAL) | (ghost ? OS_DISABLED : 0)),
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
    char info[96];
    if (b->req_fd >= 0 && b->req_kind == RQ_FETCH) {          // fetch in flight: text + bar
        char bar[12];
        unsigned pc = b->prog_total
                    ? (unsigned)((unsigned long long)b->prog_done * 100 / b->prog_total) : 0;
        if (pc > 100) pc = 100;
        for (int i = 0; i < 10; i++) bar[i] = (unsigned)i < pc/10 ? '#' : ' ';
        bar[10] = 0;
        snprintf(info, sizeof info, "Fetching %.40s  [%s] %u%%", b->prog_name, bar, pc);
    }
    else if (b->req_err[0])                                   // last async request failed
        snprintf(info, sizeof info, "Error: %.80s", b->req_err);
    else if (b->net == 1)                                     // servers window (minus the Add tile)
        snprintf(info, sizeof info, "%d servers", b->nent ? b->nent-1 : 0);
    else if (b->net == 2)
        snprintf(info, sizeof info, "%d files, %ld KB \xE2\x80\x94 %s",
                 b->nfiles, (b->total+1023)/1024, b->logical_root);
    else
        snprintf(info, sizeof info, "%d files, %ld KB", b->nfiles, (b->total+1023)/1024);
    vst_color(HV, 1); vst_alignment(HV, VDI_TA_RIGHT, VDI_TA_HALF, 0,0);
    v_gtext(HV, ix+iw-12, ay, info);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
}
static void br_content(int hd, int wax, int way, int waw, int wah, void *ud) {
    (void)hd; browser *b = ud;
    b->wax = wax; b->way = way; b->waw = waw; b->wah = wah;
    if (b->req_fd >= 0 && b->req_kind != RQ_FETCH) {          // list still in flight
        char m[160]; snprintf(m, sizeof m, "Contacting %s ...", b->logical_root);
        vst_color(HV, 1); vst_height(HV, 15, 0,0,0,0);
        vst_alignment(HV, VDI_TA_CENTER, VDI_TA_HALF, 0,0);
        v_gtext(HV, wax+waw/2, way+wah/2, m);
        vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
        return;
    }
    br_layout(b);
    aes_icon_label_style(0);                       // browser: over the light window
    objc_draw(b->tree, 0, 2, wax, way, waw, wah);
}
// Repaint ONLY the info bar (per fetch-progress line): chrome fill + divider +
// br_infobar + flush — no full-window redraw per tick.  Drawn straight to the
// screen like desk_busy; the next full redraw repaints it anyway.
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
/* immediate "working..." box — click-instant feedback, drawn straight to the
 * screen (aes_flush_rect makes it visible mid-loop) and wiped by the next
 * full redraw; it never blocks */
static void desk_busy(const char *msg) {
    int W = 360, H = 40, wx, wy, ww, wh;
    wind_get(0, WF_WORKXYWH, &wx, &wy, &ww, &wh);
    int x = wx + (ww-W)/2, y = wy + (wh-H)/2;
    vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0); vsf_color(HV, 0);
    int16_t bx[4] = { (int16_t)x, (int16_t)y, (int16_t)(x+W-1), (int16_t)(y+H-1) };
    vr_recfl(HV, bx);
    vsl_color(HV, 1); vsl_width(HV, 1);
    int16_t o[10] = { (int16_t)x,(int16_t)y, (int16_t)(x+W-1),(int16_t)y,
                      (int16_t)(x+W-1),(int16_t)(y+H-1), (int16_t)x,(int16_t)(y+H-1),
                      (int16_t)x,(int16_t)y };
    v_pline(HV, 5, o);
    vst_color(HV, 1); vst_height(HV, 13, 0,0,0,0); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
    v_gtext(HV, x+12, y+H/2, msg);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
    aes_flush_rect(x, y, W, H);
}

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
    b->prog_done = 0; b->prog_total = 0;
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
static TEDINFO as_thost = { as_host, as_tmpl, "P", sizeof as_host, TE_LEFT };
static TEDINFO as_tpath = { as_path, as_tmpl, "P", sizeof as_path, TE_LEFT };
static TEDINFO as_tname = { as_name, as_tmpl, "X", sizeof as_name, TE_LEFT };
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
    if (!b->req_hdr) {                                        // list header: +ok / -err
        if (ln[0] == '+') { b->req_hdr = 1; return; }
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
        for (int n = 0; n < 64 && b->req_fd >= 0; n++) {
            int r = fuji_poll_line(b->req_fd, ln, sizeof ln);
            if (r == 0) break;                                // no complete line yet
            if (r < 0) { net_req_fail(b, "daemon connection lost"); break; }
            net_req_line(b, ln);
        }
    }
}
static void br_click(browser *b, int mx, int my) {
    if (b->req_fd >= 0) return;                               // request in flight: ignore clicks
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
            if (b->net == 1) {                               // servers window
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
        case SDL_MOUSEBUTTONDOWN: if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn|=1; ev->button=g_btn; ev->type=AES_BTN_DOWN; ev->mx=e.button.x; ev->my=e.button.y; return AES_BTN_DOWN;
        case SDL_MOUSEBUTTONUP: if(e.button.button!=SDL_BUTTON_LEFT)break;
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
      if (registry_open(dbp) != 0) fprintf(stderr, "xtdesk: no registry at %s\n", dbp); }
    load_wall();
    build_desktop();
    wind_set_desktop_content(deskcontent, NULL);
    if (sel && n_icons) desk[1].ob_state |= OS_SELECTED;
    if (browse) { open_browser("/Media/6502/Games", ICT_MEDIA_8BIT); if (sel) BR[0].sel = 0; }
    if (browse == 2) desk_launch("River Raid.atr", ICT_MEDIA_8BIT);
    wind_redraw();

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
