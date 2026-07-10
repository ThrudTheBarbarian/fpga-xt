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
#include "fujiclient.h"
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
#define DCLICK_MS 500   /* generous: serial Enter-Enter / Space-toggle need more than a real mouse */

static int    HV, PW, PH;
static theme  TH;
static CICON  ci[MAX_ICONS];
static gfx_surface *isurf[MAX_ICONS];
static reg_desktop_icon rows[MAX_ICONS];
static OBJECT desk[1 + MAX_ICONS];
static int    n_icons;

static struct os_fbinfo g_fb;
static gfx_surface *g_bb;

/* Push only the changed rectangle from the cached back-buffer to the scanned
 * plane.  wind_redraw regenerates ALL of g_bb (cheap — cached, no plane traffic),
 * but the plane write is the only thing that contends with the free-running
 * compositor's DDR reads.  A full-plane blit is ~8 MB and starved the compositor
 * hard enough to briefly drop the HDMI link (SiI read the sink as absent) on
 * every repaint; presenting just the touched region keeps an icon highlight to a
 * few KB.  g_bb is always fully correct and the plane already matches outside the
 * rect, so a partial push stays in sync. */
static void present_rect(int x, int y, int w, int h) {
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > g_fb.w) w = g_fb.w - x;
    if (y + h > g_fb.h) h = g_fb.h - y;
    if (w <= 0 || h <= 0) return;
    uint32_t *plane = (uint32_t *)g_fb.addr;
    for (int r = y; r < y + h; r++)
        memcpy(plane + (size_t)r * g_fb.stride + x,
               g_bb->px + (size_t)r * g_bb->stride + x, (size_t)w * 4);
    sys_fb_present();
}
static void present(void) { present_rect(0, 0, g_fb.w, g_fb.h); }
static void repaint(void) { wind_redraw(); present(); }
static void repaint_rect(int x, int y, int w, int h) { wind_redraw(); present_rect(x, y, w, h); }

/* dirty-rect helpers: union two rects, and the on-screen bounds of a desktop
 * icon (padded to cover the G_CICON label below the bitmap + selection chrome). */
#define ICON_PAD 24
static void rect_union(int *x,int *y,int *w,int *h, int x2,int y2,int w2,int h2) {
    if (*w <= 0) { *x = x2; *y = y2; *w = w2; *h = h2; return; }
    int ax = *x + *w, ay = *y + *h, bx = x2 + w2, by = y2 + h2;
    if (x2 < *x) *x = x2; if (y2 < *y) *y = y2;
    *w = (ax > bx ? ax : bx) - *x; *h = (ay > by ? ay : by) - *y;
}
static void icon_dirty(int obj, int *x,int *y,int *w,int *h) {
    int ox, oy; objc_offset(desk, obj, &ox, &oy);
    *x = ox - ICON_PAD; *y = oy - ICON_PAD;
    *w = desk[obj].ob_w + 2*ICON_PAD; *h = desk[obj].ob_h + 2*ICON_PAD;
}
static int desk_sel(void) { for (int i = 1; i <= n_icons; i++) if (desk[i].ob_state & OS_SELECTED) return i; return 0; }

/* The live XL compositor plane (emulator video) binds to ONE 6502 window: the
 * kernel places plane 1 over that window's work area (SYS_xl_window).  Declared
 * here because the drag-overlay hooks below track it during a drag. */
#define XL_SCALE 2                      // 320x192 XL writeback -> a 640x384 work area
static int g_xlwin;                     // window handle owning the plane (0 = none)
static void xl_sync(void);              // fwd: re-place the plane on g_xlwin's work area

/* HW drag-overlay ops (registered with wind_set_overlay): the AES title-bar drag
 * lifts the window into the overlay plane and moves it by register write — no
 * per-motion redraw, tear-free. begin copies the window rect from the cached
 * back-buffer into the DRAG_BASE overlay buffer.  The back-buffer holds only the
 * chrome + a black work area, though — the emulator's live picture is a SEPARATE
 * compositor plane (XL, depth 2, above this overlay).  So when the lifted window
 * is the emu window, move the XL plane in lock-step with the overlay: the live
 * picture then rides on top of the dragged frame instead of staying pinned. */
#define DRAG_BASE 0x32000000u
static int g_ovl_w, g_ovl_h;
static int ovl_begin(int x, int y, int w, int h) {
    if (w <= 0 || h <= 0) return 0;
    if (x < 0 || y < 0 || x + w > g_fb.w || y + h > g_fb.h) return 0;   // off-screen edge -> classic drag
    uint32_t *dst = (uint32_t *)DRAG_BASE;              // COMP plane reads a FIXED 2048-word (8192 B)
    for (int r = 0; r < h; r++)                         // row stride (hdl/fpga_xt_top.sv stride_bytes=8192),
        memcpy(dst + (size_t)r * g_fb.stride,           // NOT packed — OVL_W only bounds the displayed width
               g_bb->px + (size_t)(y + r) * g_bb->stride + x, (size_t)w * 4);
    g_ovl_w = w; g_ovl_h = h;
    sys_overlay(x, y, w, h, 1);
    return 1;
}
// The emulator's live picture is a SEPARATE compositor plane (XL, depth 2, above
// this drag overlay).  WM_MOVED is one-shot at drag-END (classic GEM), so it can
// only SNAP the plane, never track it — the continuous follow must ride the
// per-motion overlay hook.  xl_sync() re-reads g_xlwin's LIVE work area (window.c
// updates W->x/W->y before calling ovl_move), so the plane steps with the drag
// and settles on release.  A no-op when the dragged window isn't the emu window
// (g_xlwin's work area is unchanged → same placement), so it's safe to call
// unconditionally without a per-drag bind check (the old g_drag_xl arming, which
// never fired reliably).
static void ovl_move(int x, int y) {
    sys_overlay(x, y, g_ovl_w, g_ovl_h, 1);
    xl_sync();                                          // XL plane follows the emu window each step
}
static void ovl_end(void) { sys_overlay(1920, 1080, 1, 1, 1); xl_sync(); }  /* park overlay; settle the plane */

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
// windows stay placeholders (no core hosted yet).  (XL_SCALE / g_xlwin are
// declared up by the drag-overlay hooks, which track the plane during a drag.)
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
    // one 6502 core, one 6502 window: a second open raises the existing one
    if (type == ICT_EMU_8BIT && g_xlwin) { wind_raise(g_xlwin); return; }
    int s = -1; for (int i = 0; i < MAXEMU; i++) if (!EMU[i].used) { s = i; break; }
    if (s < 0) return;
    emuwin *e = &EMU[s]; memset(e, 0, sizeof *e); e->used = 1;
    snprintf(e->name, sizeof e->name, "%s", emu_machine(type));
    if (boot) snprintf(e->boot, sizeof e->boot, "%s", boot);
    // work area = the emulation plane, EXACTLY: the XL writeback is 320x192, so
    // at XL_SCALE=2 the plane covers 640x384 — a larger work area would scan
    // DDR garbage beyond the buffer into the window.
    int pw = (type == ICT_EMU_8BIT) ? 320*XL_SCALE : 640;
    int ph = (type == ICT_EMU_8BIT) ? 192*XL_SCALE : 400;
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
    repaint_rect(bx, by, bw, bh);             // push just the new window, not the whole plane
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
#define MAXENT  96
#define MAX_CRUMB 18                                  // breadcrumb: <root> + up to ~16 path segments
#define BR_WKIND (W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER|W_INFO)   // browser-window kind
typedef struct { char name[128], label[128]; int dir; long size;
                 char state; int srvid; } bent;     // state: lsc cache column; srvid: servers row (-1 = Add server)
typedef struct {
    int used, win, media_type, sel;
    int net, server_id;                               // net browser flavour (see above)
    char logical_root[128], fs_root[160], rel[256];   // rel = "" at the (rooted) top
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
    int retryx, retryw;                                // Retry button rect in the info bar (error state)
    int fitx, fitw;                                    // Fit button rect in the info bar (path windows)
    int ncrumb;                                        // breadcrumb span count (0 = none drawn)
    int crumbx[MAX_CRUMB], crumbw[MAX_CRUMB];          // per-segment hit rects (info bar left)
    int crumbcut[MAX_CRUMB];                           // strlen to truncate b->rel to on a segment click
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
    bent *e = &b->ent[b->nent++];
    snprintf(e->name, sizeof e->name, "%s", ln + off);
    e->dir = (kind == 'd'); e->size = size;
    e->state = e->dir ? 0 : cs; e->srvid = 0;
    b->cic[b->nent-1].img = NULL;                      // live fill: text label now,
    b->cic[b->nent-1].text = e->name;                  // sorted icons on completion
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
// List the browser's current directory over the kernel VFS (sys_readdir gives
// the type; sys_stat only for file sizes).
static void br_list(browser *b) {
    if (b->net == 1) { srv_list_start(b); return; }   // FujiNet flavours (async)
    if (b->net == 2) { net_list_start(b); return; }
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
        e->size = 0; e->state = 0; e->srvid = 0;
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
                                (uint16_t)((i == b->sel ? OS_SELECTED : OS_NORMAL) | (ghost ? OS_DISABLED : 0)),
                                &b->cic[i], (int16_t)cx, (int16_t)cy, ICON_CW, ICON_CH };
    }
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
// Draw the location as a row of individually-clickable path segments in the
// info bar's left region: "<logical_root>/seg1/seg2/…".  Records a hit rect
// (crumbx/crumbw) + the b->rel truncation length (crumbcut) for every segment
// actually drawn.  When the row overflows availw it middle-ellipsises at
// segment granularity (root + "…" + the tail that fits) so the recorded rects
// stay correct for exactly what is on screen.
static void br_crumbs(browser *b, int x0, int ay, int availw) {
    b->ncrumb = 0;
    vst_height(HV, 14, 0,0,0,0);
    vst_color(HV, 1); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
    char seg[MAX_CRUMB][80]; int cut[MAX_CRUMB], segw[MAX_CRUMB], nseg = 0;
    snprintf(seg[nseg], sizeof seg[0], "%s", b->logical_root); cut[nseg] = 0; nseg++;
    for (int i = 0; b->rel[i] && nseg < MAX_CRUMB; ) {     // one span per rel component
        int j = i; while (b->rel[j] && b->rel[j] != '/') j++;
        int len = j - i; if (len > 79) len = 79;
        memcpy(seg[nseg], b->rel + i, len); seg[nseg][len] = 0;
        cut[nseg] = j;                                    // truncate rel just before the next '/'
        nseg++;
        if (b->rel[j] == '/') i = j + 1; else break;
    }
    int sepw = br_textw("/"), ellw = br_textw("...");
    int need = 0;
    for (int k = 0; k < nseg; k++) { segw[k] = br_textw(seg[k]); need += segw[k] + (k ? sepw : 0); }
    int t = 1;                                            // suffix start after an elided middle (1 = show all)
    if (availw > 0 && need > availw && nseg > 2) {
        for (t = 2; t < nseg; t++) {
            int w = segw[0] + sepw + ellw;
            for (int k = t; k < nseg; k++) w += sepw + segw[k];
            if (w <= availw) break;
        }
        if (t >= nseg) t = nseg - 1;                      // always keep root + last
    }
    int x = x0;
    v_gtext(HV, x, ay, seg[0]);                           // root span
    b->crumbx[b->ncrumb] = x; b->crumbw[b->ncrumb] = segw[0]; b->crumbcut[b->ncrumb] = cut[0]; b->ncrumb++;
    x += segw[0];
    if (t > 1) { v_gtext(HV, x, ay, "/"); x += sepw; v_gtext(HV, x, ay, "..."); x += ellw; }
    for (int k = (t > 1 ? t : 1); k < nseg; k++) {
        v_gtext(HV, x, ay, "/"); x += sepw;
        v_gtext(HV, x, ay, seg[k]);
        if (b->ncrumb < MAX_CRUMB) {
            b->crumbx[b->ncrumb] = x; b->crumbw[b->ncrumb] = segw[k]; b->crumbcut[b->ncrumb] = cut[k]; b->ncrumb++;
        }
        x += segw[k];
    }
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
    int maxw = 8*PW/10, maxh = 8*PH/10;                   // clamp to 80% of the screen
    if (bw > maxw) bw = maxw; if (bh > maxh) bh = maxh;
    if (cx + bw > PW) bw = PW - cx;                       // keep on-screen (top-left fixed)
    if (cy + bh > PH) bh = PH - cy;
    int minw = 280, minh = 200;                           // sane minimum
    if (bw < minw) bw = minw; if (bh < minh) bh = minh;
    wind_open(b->win, cx, cy, bw, bh);                    // already open: resizes in place
    repaint();
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
    b->fitx = 0; b->fitw = 0; b->ncrumb = 0;                // Fit / breadcrumb recorded only when drawn
    int drewbar = 0, drewcrumbs = 0;                        // active states draw a graphical bar + left label
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
    else {                                                    // path window (net 0/2), idle: breadcrumb
        br_crumbs(b, ix+72, ay, irx - (ix+72) - 8);          // clickable "<root>/seg1/seg2/…"
        drewcrumbs = 1;
    }
    if (!drewcrumbs) {
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
    br_layout(b);
    aes_icon_label_style(0);                       // browser: over the light window
    objc_draw(b->tree, 0, 2, wax, way, waw, wah);
}
// Repaint ONLY the info bar (per fetch-progress line): chrome fill + divider +
// br_infobar + flush — no full-window redraw per tick.  Drawn straight to the
// back-buffer; the next full redraw repaints it anyway.
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
        char local[560]; struct xt_stat st;                   // /Cache/<id><remote> (the daemon's mirror)
        snprintf(local, sizeof local, "/Cache/%d%s", b->server_id, remote);
        if (sys_stat(local, &st) == 0) { desk_launch(e->name, b->media_type); repaint(); return; }
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
    repaint();                                        // repaint under the dismissed dialog
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
        repaint();
        return;
    }
    snprintf(b->req_err, sizeof b->req_err, "%s", msg);       // lists: empty + error in the info bar
    if (kind == RQ_SRV) srv_finish(b); else net_finish(b);
    repaint();
}
static void net_req_line(browser *b, char *ln) {              // dispatch one reply line
    if (b->req_kind == RQ_ADD) {                              // one-line reply: +ok <id> / -err
        if (ln[0] == '-') { net_req_fail(b, ln + 1); return; }
        net_req_close(b);
        srv_list_start(b); repaint();                         // async refresh: the new tile appears
        return;
    }
    if (b->req_kind == RQ_FETCH) {
        if (!strncmp(ln, "+progress ", 10)) {
            sscanf(ln + 10, "%u %u", &b->prog_done, &b->prog_total);
            br_info_redraw(b);                                // ONLY the info bar repaints
        } else if (!strncmp(ln, "+ok", 3)) {
            net_req_close(b);
            net_list_start(b); repaint();                     // async re-list: entry solidifies
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
        repaint();
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
            if (b->nent != before) repaint();
            else                   br_info_redraw(b);
        }
    }
}
static void br_click(browser *b, int mx, int my) {
    if (b->req_fd >= 0) return;                               // request in flight: ignore clicks
    for (int c = 0; c < b->ncrumb; c++)                       // breadcrumb: jump to a path level
        if (my >= b->infoy && my < b->infoy + b->infoh &&
            mx >= b->crumbx[c] && mx < b->crumbx[c] + b->crumbw[c]) {
            if (b->crumbcut[c] >= (int)strlen(b->rel)) return;   // current level: no-op
            b->rel[b->crumbcut[c]] = 0;
            br_list(b); br_settitle(b); repaint(); return;
        }
    if (br_up_hit(b, mx, my)) {                               // ascend (never above the root)
        char *s = strrchr(b->rel, '/'); if (s) *s = 0; else b->rel[0] = 0;
        br_list(b); br_settitle(b); repaint(); return;
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
        repaint(); return;
    }
    int oi = objc_find(b->tree, 0, 2, mx, my);
    if (oi <= 0) { b->sel = -1; repaint(); return; }
    int dd = b->rel[0] ? 1 : 0;
    int isdot = (dd && oi == 1);                             // synthetic ".." up-tile
    int i = oi-1-dd, was = (!isdot && b->sel == i);
    b->sel = isdot ? -1 : i; repaint();
    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int w2 = wind_find(mx2, my2);
        if (w2 == b->win && objc_find(b->tree, 0, 2, mx2, my2) == oi) {   // double-click
            if (isdot) {                                     // ".." : ascend one level (like Up)
                char *s = strrchr(b->rel, '/'); if (s) *s = 0; else b->rel[0] = 0;
                br_list(b); br_settitle(b); repaint();
            } else if (b->net == 1) {                        // servers window
                if (b->ent[i].srvid < 0)                     // "Add server": the dialog
                    add_server_dialog(b);
                else open_fuji_browser(b->ent[i].srvid, b->ent[i].label);
            } else if (b->ent[i].dir) {                      // descend
                int n = (int)strlen(b->rel);
                snprintf(b->rel + n, sizeof b->rel - n, "%s%s", b->rel[0] ? "/" : "", b->ent[i].name);
                br_list(b); br_settitle(b); repaint();
            } else if (b->net == 2) {                        // network file: launch cached / fetch ghost
                net_open(b, i);
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
static void open_browser_win(const char *logical, int media_type, int net, int server_id) {
    for (int i = 0; i < MAXBR; i++) {             // one window per place: re-top it
        browser *e = &BR[i];
        if (!e->used || e->net != net) continue;
        if (net == 2 ? e->server_id == server_id
                     : strcmp(e->logical_root, logical) == 0) {
            wind_raise(e->win); repaint();
            return;
        }
    }
    int s = -1; for (int i = 0; i < MAXBR; i++) if (!BR[i].used) { s = i; break; }
    if (s < 0) return;
    browser *b = &BR[s]; memset(b, 0, sizeof *b);
    b->used = 1; b->media_type = media_type; b->sel = -1; b->req_fd = -1;
    b->net = net; b->server_id = server_id;
    snprintf(b->logical_root, sizeof b->logical_root, "%s", logical);
    snprintf(b->fs_root, sizeof b->fs_root, "%s", logical);   // logical IS the SD path here
    int kind = BR_WKIND;
    int pw = 760, ph = 520, bx, by, bw, bh;
    wind_calc(WC_BORDER, kind, g_bx, g_by, pw, ph, &bx, &by, &bw, &bh);
    b->win = wind_create(kind, bx, by, bw, bh);
    if (!b->win) { b->used = 0; return; }
    br_list(b); br_settitle(b);
    wind_content(b->win, br_content, b);
    wind_info(b->win, br_infobar, b);
    wind_open(b->win, bx, by, bw, bh);
    g_bx += 34; g_by += 30; if (g_by > PH-320) { g_bx = 380; g_by = 130; }
    repaint_rect(bx, by, bw, bh);             // push just the new window, not the whole plane
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
// media -> a rooted browser at the matching /media volume (lowercase SD layout).
static void open_icon(int obj) {
    reg_desktop_icon *ri = &rows[obj-1];
    switch (ri->type) {
        case ICT_MEDIA_8BIT: open_browser("/media/6502", ICT_MEDIA_8BIT); break;
        case ICT_MEDIA_1632: open_browser("/media/m68k", ICT_MEDIA_1632); break;
        case ICT_FUJINET:    open_fuji_servers(); break;
        case ICT_EMU_8BIT: case ICT_EMU_1632:
        default:             open_emulator(ri->type ? ri->type : ICT_EMU_8BIT, NULL, NULL); break;
    }
}

// A desktop click (window frames were already handled inside evnt_multi).
static void desk_click(int mx, int my) {
    int obj = objc_find(desk, 0, 2, mx, my);
    if (obj <= 0) {                                              // empty desktop -> drop any selection
        int old = desk_sel(); clear_sel();
        if (old) { int x,y,w,h; icon_dirty(old,&x,&y,&w,&h); repaint_rect(x,y,w,h); }
        return;
    }
    int was_sel = desk[obj].ob_state & OS_SELECTED;
    int old = desk_sel();
    clear_sel(); desk[obj].ob_state |= OS_SELECTED;              // immediate select
    { int x,y,w,h; icon_dirty(obj,&x,&y,&w,&h);
      if (old && old != obj) { int ox,oy,ow,oh; icon_dirty(old,&ox,&oy,&ow,&oh); rect_union(&x,&y,&w,&h,ox,oy,ow,oh); }
      repaint_rect(x,y,w,h); }

    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int obj2 = objc_find(desk, 0, 2, mx2, my2);
        if (obj2 == obj) { open_icon(obj); return; }             // double-click -> open (opener self-presents)
        desk_click(mx2, my2); return;                            // 2nd click elsewhere
    }
    if (was_sel) { desk[obj].ob_state &= ~OS_SELECTED;           // toggle off
                   int x,y,w,h; icon_dirty(obj,&x,&y,&w,&h); repaint_rect(x,y,w,h); }
}

// ---- A9 event source: block for the next kernel input event ----------------
// (the cursor is a HW sprite moved kernel-side, so motion needs no present —
// only real actions repaint).
// The emulator keyboard GRAB: while a topped emu window holds it, every key
// types into the machine — so Ctrl-] (not an Atari key) releases it, giving
// Enter/Space back to the desktop (close box, icons) without a mouse.  Topping
// an emu window again re-grabs.  The grab CANNOT eat the arrow keys (pointer
// motion) or Tab (a click): those bypass raw in the input layer, so you can
// always steer to a grabbed emu window's close box and Tab it shut.
static int g_kbd_grab = 1;
static int g_last_top;

static int a9_events(aes_event *ev, int timeout_ms) {
    struct os_event oe = { OS_EV_TIMER, 0, 0, 0, 0, 0 };   // default if the syscall fails
    // raw keys while an emulator window is topped AND grabbed: Enter/Space TYPE
    // into the machine instead of clicking (the mouse clicks/drags either way)
    sys_input(&oe, timeout_ms, g_kbd_grab && emu_of_window(wind_top()) != NULL);
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
    aes_set_idle(net_pump, 40);                      // modal loops (dialogs, drags) keep pumping
    wind_set_overlay(ovl_begin, ovl_move, ovl_end, present_rect);   // tear-free HW-overlay window drag
    repaint();                                       // initial frame

    for (;;) {                                       // interactive loop
        int mx, my, mb, ks, key, nc; int16_t msg[8];
        int pend = net_pending();                    // net I/O in flight: tick to pump it
        int r = evnt_multi(MU_MESAG|MU_KEYBD|MU_BUTTON|(pend?MU_TIMER:0), 2,1,1, 0,0,0,0,0, 0,0,0,0,0, msg, pend?40:0, 0,
                           &mx, &my, &mb, &ks, &key, &nc);
        net_pump();                                  // drain any arrived reply lines
        { int top = wind_top();                          // (re-)grab on topping an emu window
          if (top != g_last_top) { g_last_top = top; if (emu_of_window(top)) g_kbd_grab = 1; } }
        // Keyboard goes to the ATARI while a topped emulator window holds the
        // grab (kernel injects into POKEY); Ctrl-] releases the grab; with no
        // grab, keys act on the desktop and Esc quits it.
        if ((r & MU_KEYBD) && key == 0x1D) { g_kbd_grab = !g_kbd_grab; continue; }  // Ctrl-]
        if ((r & MU_KEYBD) && g_kbd_grab && emu_of_window(wind_top())) { sys_kbd_6502(key); continue; }
        if ((r & MU_KEYBD) && key == 0x1b) break;                              // Esc quits
        if ((r & MU_MESAG) && msg[0] == WM_CLOSED) {
            int cx,cy,cw,ch; wind_get(msg[3], WF_CURRXYWH, &cx,&cy,&cw,&ch);   // area the close reveals
            browser *b = br_of_window(msg[3]);       // close cancels any in-flight request
            if (b) { net_req_close(b); br_free_icons(b); b->used = 0; }
            emuwin *e = emu_of_window(msg[3]); if (e) e->used = 0;
            xl_unbind(msg[3]);
            wind_close(msg[3]); repaint_rect(cx,cy,cw,ch);
        }
        if ((r & MU_MESAG) && (msg[0] == WM_MOVED || msg[0] == WM_SIZED) && msg[3] == g_xlwin)
            xl_sync();                                   // keep the plane on the work area
        if ((r & MU_MESAG) && msg[0] == XTOS_MEDIA_CHANGE) {
            // OS says the SD card left (msg[3]=0) or came back (msg[3]=1). Placeholder:
            // log it. Real UX would grey out / close windows rooted on /media.
            if (msg[3]) sys_klog("[desk] SD inserted\n", 19);
            else        sys_klog("[desk] SD removed\n", 18);
        }
        if (r & MU_BUTTON) {
            int wh = wind_find(mx, my); browser *b = wh ? br_of_window(wh) : NULL;
            if (b) br_click(b, mx, my); else desk_click(mx, my);
        }
    }
    registry_close();
}
