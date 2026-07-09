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
typedef struct { char name[128], label[128]; int dir; long size;
                 char state; int srvid; } bent;     // state: lsc cache column; srvid: servers row (-1 = Add server)
typedef struct {
    int used, win, media_type, sel;
    int net, server_id;                               // net browser flavour (see above)
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
// ---- FujiNet listings (fujiclient.c talks to fujinetd; the daemon does the
// TNFS + registry/netcache work) -----------------------------------------------
static void srv_list(browser *b) {                    // one tile per `servers` row + "Add server"
    br_free_icons(b);
    b->nent = 0; b->nfiles = 0; b->total = 0; b->sel = -1;
    int fd = fuji_connect();
    char ln[640];
    if (fd >= 0 && fuji_cmd(fd, "servers") == 0 &&
        fuji_readline(fd, ln, sizeof ln) == 1 && ln[0] == '+') {
        while (fuji_readline(fd, ln, sizeof ln) == 1 && strcmp(ln, ".")) {
            if (b->nent >= MAXENT-1 || ln[0] == '-') continue;
            int sid, off = 0; char tr[16], hp[160], pa[160];   // "<id> <udp|tcp|auto> <host>:<port> <path> <name…>"
            if (sscanf(ln, "%d %15s %159s %159s %n", &sid, tr, hp, pa, &off) < 4) continue;
            bent *e = &b->ent[b->nent++];
            snprintf(e->name, sizeof e->name, "%s", ln[off] ? ln + off : hp);
            e->dir = 1; e->size = 0; e->state = 0; e->srvid = sid;
        }
    }
    if (fd >= 0) fuji_close(fd);
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
static void net_list(browser *b) {                    // entries from `lsc <server> <path>`
    br_free_icons(b);
    b->nent = 0; b->nfiles = 0; b->total = 0; b->sel = -1;
    char path[300]; snprintf(path, sizeof path, "/%s", b->rel);
    int fd = fuji_connect();
    char ln[640];
    if (fd >= 0 && fuji_cmd(fd, "lsc %d \"%s\"", b->server_id, path) == 0 &&
        fuji_readline(fd, ln, sizeof ln) == 1 && ln[0] == '+') {
        while (fuji_readline(fd, ln, sizeof ln) == 1 && strcmp(ln, ".")) {
            if (b->nent >= MAXENT || ln[0] == '-') continue;
            char kind, cs; long size; int off = 0;    // "d <size> - <name>" | "f <size> <g|f|c|u> <name>"
            if (sscanf(ln, " %c %ld %c %n", &kind, &size, &cs, &off) < 3 || !ln[off]) continue;
            bent *e = &b->ent[b->nent++];
            snprintf(e->name, sizeof e->name, "%s", ln + off);
            e->dir = (kind == 'd'); e->size = size;
            e->state = e->dir ? 0 : cs; e->srvid = 0;
        }
    }
    if (fd >= 0) fuji_close(fd);
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
// List the browser's current directory over the kernel VFS (sys_readdir gives
// the type; sys_stat only for file sizes).
static void br_list(browser *b) {
    if (b->net == 1) { srv_list(b); return; }         // FujiNet flavours
    if (b->net == 2) { net_list(b); return; }
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
    if (b->net == 1)                                          // servers window (minus the Add tile)
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
    br_layout(b);
    aes_icon_label_style(0);                       // browser: over the light window
    objc_draw(b->tree, 0, 2, wax, way, waw, wah);
}
static int br_up_hit(browser *b, int mx, int my) {
    return b->rel[0] && mx >= b->infox+8 && mx < b->infox+70 && my >= b->infoy && my < b->infoy+b->infoh;
}
static void open_fuji_browser(int server_id, const char *name);   // fwd
// Fetch-progress box: filename + a bar, drawn straight to the screen (the next
// repaint draws over it); aes_flush_rect (-> present_rect) makes it visible
// mid-loop.
static void net_progress(const char *name, unsigned done, unsigned total) {
    int W = 360, H = 64, wx, wy, ww, wh;
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
    v_gtext(HV, x+12, y+17, name);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
    int tw = W-24, fill = total ? (int)((long long)tw * done / total) : 0;
    if (fill > tw) fill = tw;
    int16_t tr[4] = { (int16_t)(x+12), (int16_t)(y+34), (int16_t)(x+12+tw-1), (int16_t)(y+49) };
    vsf_color(HV, 9); vr_recfl(HV, tr);                       // trough
    if (fill > 0) {
        int16_t fr[4] = { tr[0], tr[1], (int16_t)(x+12+fill-1), tr[3] };
        vsf_color(HV, 1); vr_recfl(HV, fr);                   // done so far
    }
    aes_flush_rect(x, y, W, H);
}
// Modal netcache fetch: stream `fetch` progress into the box, then re-list so
// the entry solidifies (or reverts on error).  No cancel in v1.
static void net_fetch(browser *b, const char *remote, const char *name) {
    int fd = fuji_connect(), ok = 0;
    char ln[640] = "";
    if (fd < 0) { form_alert(1, "[3][FujiNet daemon not running|(boot script 40-FujiNet)][OK]"); return; }
    if (fuji_cmd(fd, "fetch %d \"%s\"", b->server_id, remote) == 0) {
        net_progress(name, 0, 0);
        while (fuji_readline(fd, ln, sizeof ln) == 1) {
            if (!strncmp(ln, "+progress ", 10)) {
                unsigned done = 0, total = 0;
                sscanf(ln + 10, "%u %u", &done, &total);
                net_progress(name, done, total);
            }
            else if (!strncmp(ln, "+ok", 3)) { ok = 1; break; }
            else if (ln[0] == '-') break;
        }
    }
    fuji_close(fd);
    if (!ok) {
        char msg[120];
        for (char *p = ln; *p; p++) if (*p=='['||*p==']'||*p=='|') *p = ' ';   // keep form_alert parsable
        snprintf(msg, sizeof msg, "[3][Fetch failed|%.60s][OK]", ln[0] == '-' ? ln+1 : "daemon connection lost");
        form_alert(1, msg);
    }
    br_list(b); repaint();
}
// Open a network file: cached -> launch its /Cache mirror; ghost (or a cache
// row whose file went missing) -> modal fetch first.
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
    net_fetch(b, remote, e->name);
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
            if (b->net == 1) {                               // servers window
                if (b->ent[i].srvid < 0)                     // "Add server": v1 points at the CLI
                    form_alert(1, "[1][To add a server, run:|fuji add-server host udp/tcp/auto|path name][OK]");
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
    int s = -1; for (int i = 0; i < MAXBR; i++) if (!BR[i].used) { s = i; break; }
    if (s < 0) return;
    browser *b = &BR[s]; memset(b, 0, sizeof *b);
    b->used = 1; b->media_type = media_type; b->sel = -1;
    b->net = net; b->server_id = server_id;
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
    wind_set_overlay(ovl_begin, ovl_move, ovl_end, present_rect);   // tear-free HW-overlay window drag
    repaint();                                       // initial frame

    for (;;) {                                       // interactive loop
        int mx, my, mb, ks, key, nc; int16_t msg[8];
        int r = evnt_multi(MU_MESAG|MU_KEYBD|MU_BUTTON, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, msg, 0,0,
                           &mx, &my, &mb, &ks, &key, &nc);
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
            browser *b = br_of_window(msg[3]); if (b) { br_free_icons(b); b->used = 0; }
            emuwin *e = emu_of_window(msg[3]); if (e) e->used = 0;
            xl_unbind(msg[3]);
            wind_close(msg[3]); repaint_rect(cx,cy,cw,ch);
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
