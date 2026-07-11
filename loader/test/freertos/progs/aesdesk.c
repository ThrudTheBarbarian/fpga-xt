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
#include "aes/rscload.h"
#include "img.h"
#include "registry.h"
#include "fujiclient.h"
#include "font.h"
#include "usys.h"

#ifndef O_RDONLY
#define O_RDONLY 0x0000
#define O_WRONLY 0x0001
#define O_CREAT  0x0200
#endif
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define ICON_SZ 48
#define ICON_CW 100
#define ICON_CH (ICON_SZ + 26)
#define GAL_CW  180         // Gallery (viewmode 4) cell: ~2x the icon cell -> fewer per row
#define GAL_CH  140         // (icon art is still ICON_SZ; true thumbnails are a future enhancement)
#define TEXT_ROWH 20         // text-view row height (single/multi column)
#define TEXT_COLW 260        // multi-column text: target column width (name + attrs + size fields)
#define BR_TEXT_SEL 250      // theme selection background (aes object.c PEN_SEL)
#define MAX_ICONS 32
#define DCLICK_MS 500   /* generous: serial Enter-Enter / Space-toggle need more than a real mouse */

static int    HV, PW, PH;
static rscdoc *g_rsc;                                // desktop.rsc dialogs (New…, …); NULL = built-ins
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
typedef struct { int used, win, istext; char name[48], boot[96]; } emuwin;
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
// A minimal text-viewer window naming the file.  There is no process-spawn
// primitive here yet, so like open_emulator (which frames the compositor plane
// rather than spawning a core) this is a stub page; when a spawn syscall lands
// it launches /bin/gemtext on the file the same way emulator media is passed.
// Reuses an EMU slot (istext=1) so the event loop's close handling frees it.
static void txt_draw(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; emuwin *e = ud;
    vsf_color(HV, 0); vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0);   // white page
    int16_t r[4] = { (int16_t)wx, (int16_t)wy, (int16_t)(wx+ww-1), (int16_t)(wy+wh-1) };
    vr_recfl(HV, r);
    vst_color(HV, 1); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
    vst_height(HV, 16, 0,0,0,0); v_gtext(HV, wx+12, wy+12, e->boot);           // the file name
    vst_height(HV, 13, 0,0,0,0); v_gtext(HV, wx+12, wy+40, "(text viewer — stub)");
}
static void open_textview(const char *name) {
    int s = -1; for (int i = 0; i < MAXEMU; i++) if (!EMU[i].used) { s = i; break; }
    if (s < 0) return;
    emuwin *e = &EMU[s]; memset(e, 0, sizeof *e); e->used = 1; e->istext = 1;
    snprintf(e->name, sizeof e->name, "Text");
    snprintf(e->boot, sizeof e->boot, "%s", name);
    int pw = 560, ph = 420, bx, by, bw, bh;
    wind_calc(WC_BORDER, W_NAME|W_CLOSER|W_MOVER, g_ex, g_ey, pw, ph, &bx, &by, &bw, &bh);
    e->win = wind_create(W_NAME|W_CLOSER|W_MOVER, bx, by, bw, bh);
    if (!e->win) { e->used = 0; return; }
    char title[128]; snprintf(title, sizeof title, "Text \xE2\x80\x94 %s", name);
    wind_set_name(e->win, title); wind_content(e->win, txt_draw, e);
    wind_open(e->win, bx, by, bw, bh);
    g_ex += 34; g_ey += 30; if (g_ey > PH-320) { g_ex = 380; g_ey = 130; }
    repaint_rect(bx, by, bw, bh);
}
static void ctx_san(const char *s, char *out, int cap);   // fwd (alert-string sanitiser)
// No application maps to this file: a graceful notice (never a silent emulator).
static void launch_none(const char *name) {
    char nm[96]; ctx_san(name, nm, sizeof nm);
    char m[160]; snprintf(m, sizeof m, "[1][No application for|%s][OK]", nm);
    form_alert(1, m);
}
// Launch a file THROUGH the mimeApps database (registry_mime): the file TYPE
// (its extension glob) decides the app — an emulator (with the looked-up
// machine + boot method), the text viewer, or a "no application" notice.  A
// text file must NEVER route to an emulator.  Only if the table can't be loaded
// at all do we fall back to the old path-based media inference (`media_type`).
static void desk_launch(const char *name, int media_type) {
    char app[16], machine[8], meth[8];
    int r = registry_mime(name, app, sizeof app, machine, sizeof machine, meth, sizeof meth);
    if (r >= 0) {                                          // table present: obey it
        if (r == 0 || !strcmp(app, "none")) { launch_none(name); return; }
        if (!strcmp(app, "textview"))       { open_textview(name); return; }
        if (!strcmp(app, "emulator")) {
            int emu = !strcmp(machine, "m68k") ? ICT_EMU_1632 : ICT_EMU_8BIT;
            char boot[96];
            if (!strcmp(meth, "cart"))      snprintf(boot, sizeof boot, "CART %s", name);
            else if (!strcmp(meth, "disk")) snprintf(boot, sizeof boot, "%s %s", emu == ICT_EMU_8BIT ? "D1:" : "A:", name);
            else                            snprintf(boot, sizeof boot, "RUN %s", name);   // exec
            open_emulator(emu, name, boot);
            return;
        }
        launch_none(name); return;                        // unknown verb -> notice
    }
    // Last resort (mimeApps table unavailable): infer emulator by path-derived media.
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
// Per-entry access-attribute bits, rendered as a "d a r x h s" flag string
// (br_fmt_attr).  d=dir a=archived r=read-only x=executable h=hidden s=system.
// a/s are FAT/DOS-only and stay off here; the kernel stat only reports the file
// type, so A9 entries only get d (r/x/h/a/s dashed).
#define BATTR_DIR 0x01
#define BATTR_ARC 0x02
#define BATTR_RO  0x04
#define BATTR_EXE 0x08
#define BATTR_HID 0x10
#define BATTR_SYS 0x20
typedef struct { char name[128], label[128]; int dir; long size, mtime;
                 char state; int srvid; unsigned char attr; } bent;   // state: lsc cache column; srvid: servers row (-1 = Add server); attr: BATTR_* flags
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
    int titlex, titley, titlew, titleh;                // last interactive-title work rect
    int retryx, retryw;                                // Retry button rect in the info bar (error state)
    int fitx, fitw;                                    // Fit button rect in the info bar (path windows)
    int viewx, vieww;                                  // (retired) info-bar View rect — now a title button
    int maskx, maskw;                                  // file-mask span rect (in the title)
    int viewmode;                                      // 1=icons 2=single-col 3=multi-col 4=gallery
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
// 2=single-col text, 3=multi-col text, 4=gallery), falling back to icons.
static int default_viewmode(void) {
    char v[16]; registry_pref("viewMode", "1", v, sizeof v);
    int m = atoi(v); return (m >= 1 && m <= 4) ? m : 1;
}
// Icon-grid cell size for the current view mode: normal (viewmode 1) or the
// larger Gallery cell (viewmode 4).  The text views (2/3) don't use this.
static void br_cell_size(browser *b, int *cw, int *ch) {
    if (b->viewmode == 4) { *cw = GAL_CW; *ch = GAL_CH; }
    else                  { *cw = ICON_CW; *ch = ICON_CH; }
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
    e->dir = 1; e->size = 0; e->state = 0; e->srvid = sid; e->attr = BATTR_DIR;
}
static void srv_finish(browser *b) {                  // rows all in: Add tile + icons
    bent *a = &b->ent[b->nent++];                     // trailing "Add server" tile
    snprintf(a->name, sizeof a->name, "Add server");
    a->dir = 0; a->size = 0; a->state = 0; a->srvid = -1; a->attr = 0;
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
    e->attr = e->dir ? BATTR_DIR : 0;   // lsc protocol carries no FAT attribute bits
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
// List the browser's current directory over the kernel VFS (sys_readdir gives
// the type; sys_stat only for file sizes).
static void br_report_content(browser *b);            // fwd: report content size for the scrollbar
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
        e->size = 0; e->mtime = 0; e->state = 0; e->srvid = 0;
        // Kernel stat reports type only (no permission bits), so only d is known;
        // r/x/h/a/s stay dashed on A9.
        e->attr = e->dir ? BATTR_DIR : 0;
        { char full[560]; struct xt_stat st;             // stat every entry (size + mtime for sorting)
          snprintf(full, sizeof full, "%s/%s", dir, de.name);
          if (sys_stat(full, &st) == 0) { if (!e->dir) e->size = (long)st.size; e->mtime = (long)st.mtime; } }
        if (!br_visible(b, de.name, e->dir)) continue;   // masked file (dirs always shown)
        b->nent++;
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
    // A fresh listing resets the scroll to the top, then reports the new content
    // height so the scrollbar (and the reserved work-area width) are right on the
    // very next redraw.
    wind_set_scroll(b->win, 0, 0);
    { int wx, wy, ww, wh; wind_get(b->win, WF_WORKXYWH, &wx, &wy, &ww, &wh);
      b->wax = wx; b->way = wy; b->waw = ww; b->wah = wh; br_report_content(b); }
}
// Lay the entry grid out in the current work area (also used for hit-testing).
// Tiles are shifted up by the window's scroll_y; the IBOX root stays on the
// visible work rect so objc_find recurses for clicks in the visible band (and
// the click Y already carries the scroll, so br_hit_slot needs no adjustment).
static void br_layout(browser *b) {
    int icw, ich; br_cell_size(b, &icw, &ich);          // icon (1) or gallery (4) cell
    int pad = 14, cols = (b->waw - pad) / icw; if (cols < 1) cols = 1;
    int sy = wind_scroll_y(b->win);                     // vertical scroll offset
    int dd = b->rel[0] ? 1 : 0;                        // synthetic ".." leads a non-root grid
    int ntile = b->nent + dd;
    b->tree[0] = (OBJECT){ NIL, ntile?1:NIL, ntile?ntile:NIL, G_IBOX, OF_NONE, OS_NORMAL,
                           0, (int16_t)b->wax, (int16_t)b->way, (int16_t)b->waw, (int16_t)b->wah };
    if (dd) {                                          // ".." tile at grid slot 0
        ensure_doticon();
        int last = (b->nent == 0);
        b->tree[1] = (OBJECT){ (int16_t)(last?0:2), NIL, NIL, G_CICON,
                               (uint16_t)(OF_SELECTABLE | (last?OF_LASTOB:0)), OS_NORMAL,
                               &g_dotcic, (int16_t)pad, (int16_t)(pad - sy), (int16_t)icw, (int16_t)ich };
    }
    for (int i = 0; i < b->nent; i++) {
        int oi = 1+dd+i, last = (i == b->nent-1), slot = i + dd;
        int cx = pad + (slot % cols) * icw;
        int cy = pad + (slot / cols) * ich - sy;
        int ghost = (b->ent[i].state == 'g' || b->ent[i].state == 'f');   // uncached net entry
        b->tree[oi] = (OBJECT){ (int16_t)(last?0:oi+1), NIL, NIL, G_CICON,
                                (uint16_t)(OF_SELECTABLE | (last?OF_LASTOB:0)),
                                (uint16_t)(((i == b->sel || b->selall) ? OS_SELECTED : OS_NORMAL) | (ghost ? OS_DISABLED : 0)),
                                &b->cic[i], (int16_t)cx, (int16_t)cy, (int16_t)icw, (int16_t)ich };
    }
}
static int br_textw(const char *s);                   // fwd (defined with the info-bar helpers)
// Compact human-readable size ("512", "13K", "4M") for the text-view size column.
static void br_fmt_size(long sz, char *out, int cap) {
    if (sz < 1000)           snprintf(out, cap, "%ld", sz);
    else if (sz < 1000*1000) snprintf(out, cap, "%ldK", (sz + 512) / 1024);
    else                     snprintf(out, cap, "%ldM", (sz + 524288) / (1024*1024));
}
// Format the BATTR_* bitmask as a fixed 6-char flag string in canonical order
// "d a r x h s" (letter when set, '-' when clear), e.g. "d-----" / "-r-x--".
static void br_fmt_attr(unsigned char attr, char *out) {
    static const char let[6] = { 'd','a','r','x','h','s' };
    static const unsigned char bit[6] = { BATTR_DIR,BATTR_ARC,BATTR_RO,BATTR_EXE,BATTR_HID,BATTR_SYS };
    for (int i = 0; i < 6; i++) out[i] = (attr & bit[i]) ? let[i] : '-';
    out[6] = 0;
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
// br_text_cell yields content coords (drawn shifted up by scroll_y), so add
// scroll_y to the click Y to map screen -> content before resolving the row.
static int br_text_hit(browser *b, int mx, int my) {
    int pad = 14, cols, rpc, colw, nt; br_text_grid(b, &cols, &rpc, &colw, &nt);
    if (nt <= 0) return -1;
    int sy = wind_scroll_y(b->win);
    int lx = mx - (b->wax + pad), ly = (my + sy) - (b->way + pad);
    if (lx < 0 || ly < 0) return -1;
    int col = lx / colw, row = ly / TEXT_ROWH;
    if (col < 0 || col >= cols || row < 0 || row >= rpc) return -1;
    int slot = col * rpc + row;
    return (slot >= 0 && slot < nt) ? slot : -1;
}
// Full content height of the current view at the current work width (b->waw):
// icon/gallery grid = rows*cell_h + top+bottom margin; text = rows*TEXT_ROWH +
// margins (single = one column of nt rows; multi = ceil(nt/cols) rows).
static int br_content_height(browser *b) {
    int pad = 14;
    if (b->viewmode == 2 || b->viewmode == 3) {
        int cols, rpc, colw, nt; br_text_grid(b, &cols, &rpc, &colw, &nt);
        return (nt > 0 ? rpc : 0) * TEXT_ROWH + 2 * pad;
    }
    int icw, ich; br_cell_size(b, &icw, &ich);
    int cols = (b->waw - pad) / icw; if (cols < 1) cols = 1;
    int dd = b->rel[0] ? 1 : 0, nt = b->nent + dd;
    int rows = (nt + cols - 1) / cols;                  // ceil
    return rows * ich + 2 * pad;
}
static void br_report_content(browser *b) {
    wind_content_size(b->win, b->waw, br_content_height(b));
}
// Draw the entries as one-line text rows (viewmode 2 single / 3 multi): name left,
// size right-aligned per cell (dirs / ".." -> "<dir>").  The selected row gets a
// PEN_SEL fill.  Geometry mirrors br_text_cell so br_click resolves the same slot.
static void br_draw_text(browser *b) {
    int dd = b->rel[0] ? 1 : 0, nt = b->nent + dd;
    int sy = wind_scroll_y(b->win);                     // content is drawn shifted up
    int pad = 14, cols, rpc, colw, ntg; br_text_grid(b, &cols, &rpc, &colw, &ntg);
    vst_height(HV, 14, 0,0,0,0);
    // Columns:  [name… (left)]  gap  [attrs (LEFT-aligned, FIXED column)]  gap
    //           [size (right, fixed zone)]  gutter.  The attr column is measured
    // from a fixed size zone (not the variable size width), so it lines up row to
    // row instead of drifting with "<dir>" vs "2K" vs "18".
    int gutter = 12, gap = 8, attrw = br_textw("darxhs"), szzone = br_textw("<dir>");
    for (int slot = 0; slot < nt; slot++) {
        int cx, cy, cw, ch; br_text_cell(b, slot, &cx, &cy, &cw, &ch);
        cy -= sy;                                       // screen y (clipped to the work rect)
        if (cy + ch <= b->way || cy >= b->way + b->wah) continue;   // fully scrolled off
        int isdot = (dd && slot == 0), i = slot - dd;
        int sel   = (!isdot && (i == b->sel || b->selall));
        int ghost = (!isdot && (b->ent[i].state == 'g' || b->ent[i].state == 'f'));
        if (sel) {                                          // selection highlight bar
            vsf_color(HV, BR_TEXT_SEL); vsf_interior(HV, VDI_FIS_SOLID); vsf_perimeter(HV, 0);
            int16_t r[4] = { (int16_t)cx, (int16_t)cy, (int16_t)(cx+cw-2), (int16_t)(cy+ch-1) };
            vr_recfl(HV, r);
        }
        const char *nm = isdot ? ".." : (b->ent[i].label[0] ? b->ent[i].label : b->ent[i].name);
        char szbuf[24], atbuf[8];
        if (isdot || b->ent[i].dir) snprintf(szbuf, sizeof szbuf, "<dir>");
        else                        br_fmt_size(b->ent[i].size, szbuf, sizeof szbuf);
        br_fmt_attr(isdot ? (BATTR_DIR|BATTR_EXE) : b->ent[i].attr, atbuf);   // ".." is a dir: d--x--
        int pen = ghost ? 9 : 1;
        int size_rx = cx + cw - gutter;                     // size right-aligned in the fixed zone
        int attrs_x = size_rx - szzone - gap - attrw;       // attrs LEFT edge — a FIXED column
        int name_x  = cx + 6;
        int name_w  = attrs_x - gap - name_x;               // name fills up to the attr column
        if (name_w < 8) name_w = 8;
        char lbl[128];
        aes_label_fit(HV, nm, name_w, lbl, sizeof lbl);
        vst_color(HV, pen); vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
        v_gtext(HV, name_x, cy + ch/2, lbl);
        vst_color(HV, 9);                                   // attrs: muted, LEFT-aligned at the fixed column
        v_gtext(HV, attrs_x, cy + ch/2, atbuf);
        vst_color(HV, pen); vst_alignment(HV, VDI_TA_RIGHT, VDI_TA_HALF, 0,0);
        v_gtext(HV, size_rx, cy + ch/2, szbuf);             // size right-aligned in the reserved zone
    }
    // Multi-column view: subtle light-gray dividers at internal column boundaries,
    // spanning the visible work rect (viewmode 2 single-column needs none).
    if (b->viewmode == 3 && cols > 1) {
        vsl_color(HV, 249); vsl_width(HV, 1);               // PEN_BORDER (same as the info divider)
        for (int col = 1; col < cols; col++) {
            int sx = b->wax + pad + col * colw;
            int16_t seg[4] = { (int16_t)sx, (int16_t)b->way,
                               (int16_t)sx, (int16_t)(b->way + b->wah - 1) };
            v_pline(HV, 2, seg);
        }
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
    int tpen = 1;                                        // dark text on the pale inactive bar
    if (wind_title_active()) { v_setrgb(HV, 250, 255,255,255); tpen = 250; }  // white on the dark active bar
    vst_color(HV, tpen);
    vst_alignment(HV, VDI_TA_LEFT, VDI_TA_HALF, 0,0);
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
// does (the logical path IS the SD path here).
static void br_list(browser *b);                          // fwd
static void br_navigate(browser *b, const char *abspath) {
    size_t rl = strlen(b->logical_root);
    if (strncmp(abspath, b->logical_root, rl) == 0 && (abspath[rl] == '/' || abspath[rl] == 0)) {
        const char *r = abspath + rl; while (*r == '/') r++;   // within the current root
        snprintf(b->rel, sizeof b->rel, "%s", r);
    } else if (b->net == 0) {                             // ancestor above the open root: re-root
        snprintf(b->logical_root, sizeof b->logical_root, "%s", abspath);
        snprintf(b->fs_root, sizeof b->fs_root, "%s", abspath);
        b->rel[0] = 0;
    } else return;                                        // network: nothing above the server root
    br_list(b); br_settitle(b); repaint();
}
// Fit the window to its current icon-grid contents: enough columns for
// min(nEntries, 8) × ICON_CW wide and the resulting rows × ICON_CH tall (the
// ".." tile counts), plus the title + info chrome (wind_calc).  Clamped to 80%
// of the screen and a sane minimum, top-left fixed, kept on-screen.
static void br_fit(browser *b) {
    int icw, ich; br_cell_size(b, &icw, &ich);            // icon (1) or gallery (4) cell
    int dd = b->rel[0] ? 1 : 0, ntile = b->nent + dd; if (ntile < 1) ntile = 1;
    int pad = 14, maxcols = 8;
    int cols = ntile < maxcols ? ntile : maxcols; if (cols < 1) cols = 1;
    int nrows = (ntile + cols - 1) / cols;
    int cw = 2*pad + cols * icw, chh = 2*pad + nrows * ich;   // desired work-area size
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
// W_INFO chrome FOOTER (window bottom): file count / total size (+ progress /
// Retry).  Navigation moved to the ".." tile + the breadcrumb, so there is no
// "Up" button; resize grips occupy both footer ends, so text insets past them.
static void br_infobar(int hd, int ix, int iy, int iw, int ih, void *ud) {
    (void)hd; browser *b = ud;
    b->infox = ix; b->infoy = iy; b->infow = iw; b->infoh = ih;
    int gripw = 20;                                          // clear the footer resize grips (both ends)
    int ay = iy+ih/2;
    char info[96];
    int irx = ix+iw-gripw;                                   // right edge of the info text (clear of the R grip)
    b->retryx = 0; b->retryw = 0;                            // no Retry button unless in the error state
    b->fitx = 0; b->fitw = 0;                                // Fit recorded only when drawn
    b->viewx = 0; b->vieww = 0;                             // View button recorded only when drawn
    int drewbar = 0, drewleft = 0;                          // active states draw a graphical bar; idle draws left status
    int pw = 120, pbh = 10;                                  // progress track: 120x10, vertically centred
    int pby = iy + (ih - pbh)/2;
    int pbx = irx - pw;                                      // right-anchored, before the right grip inset
    // (The View popup + Fit are now RIGHT-side title-bar icon buttons — see
    // wind_titlebtns in open_browser_win + the title-button hit-test in br_click;
    // the file mask + path breadcrumb live in the interactive window TITLE.  The
    // info footer keeps progress / Retry and, when idle, the file-count status.)
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
        v_gtext(HV, ix+gripw, ay, info);                     // left status, clear of the left resize grip
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
    br_report_content(b);                          // full content height -> scrollbar + width
    if (b->viewmode == 2 || b->viewmode == 3) { br_draw_text(b); return; }
    br_layout(b);                                  // viewmode 1: the icon grid
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
    vsl_color(HV, 249); vsl_width(HV, 1);                                        // PEN_BORDER: TOP divider (work | footer)
    int16_t il[4] = { (int16_t)ix, (int16_t)iy, (int16_t)(ix+iw-1), (int16_t)iy };
    v_pline(HV, 2, il);
    br_infobar(HV, ix, iy, iw, ih, b);
    aes_flush_rect(ix, iy, iw, ih);
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
    repaint();                                        // repaint under the dismissed dialog
    if (r != MK_OK) return;
    char m[32]; snprintf(m, sizeof m, "%s", mk_buf);  // trim trailing blanks; empty -> "*"
    for (int i = (int)strlen(m)-1; i >= 0 && m[i] == ' '; i--) m[i] = 0;
    snprintf(b->mask, sizeof b->mask, "%s", m[0] ? m : "*");
    br_list(b); br_settitle(b); repaint();            // re-list/re-layout/retitle/redraw
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
// Unified tile hit-test: returns a tile slot (0..ntile-1, slot 0 = ".." when
// present) or -1.  Icon view goes through the OBJECT tree (objc_find, tree[1] =
// slot 0); the text views mirror br_text_cell's row/column math.
static int br_hit_slot(browser *b, int mx, int my) {
    if (b->viewmode == 2 || b->viewmode == 3) return br_text_hit(b, mx, my);
    int oi = objc_find(b->tree, 0, 2, mx, my);
    return oi <= 0 ? -1 : oi - 1;
}
// The View title-button popup: pick a view mode, a check on the current one.
// Opens at the button's screen rect; choosing one relayouts + redraws.  Item ids
// 1..4 map directly onto viewmode (icons/list/columns/gallery).
static void br_view_popup(browser *b, int px, int py) {
    enum { V_ICONS = 1, V_LIST, V_COLS, V_GALLERY };
    menu_item it[4] = {
        { "as Icons",   NULL, V_ICONS,   NULL, 0, b->viewmode == 1 ? MI_CHECKED : 0 },
        { "as List",    NULL, V_LIST,    NULL, 0, b->viewmode == 2 ? MI_CHECKED : 0 },
        { "as Columns", NULL, V_COLS,    NULL, 0, b->viewmode == 3 ? MI_CHECKED : 0 },
        { "as Gallery", NULL, V_GALLERY, NULL, 0, b->viewmode == 4 ? MI_CHECKED : 0 },
    };
    int r = menu_popup(it, 4, px, py);
    if (r < V_ICONS || r > V_GALLERY) return;
    b->viewmode = r; b->sel = -1; repaint();
}
static void br_click(browser *b, int mx, int my) {
    if (b->req_fd >= 0) return;                               // request in flight: ignore clicks
    for (int k = 0; k < 2; k++) {                             // right-side title icon buttons (View, Fit)
        int bx, by, bw, bh;
        if (wind_titlebtn_rect(b->win, k, &bx, &by, &bw, &bh) &&
            mx >= bx && mx < bx + bw && my >= by && my < by + bh) {
            if (k == 0) br_view_popup(b, bx, by + bh);       // chevron -> view popup, below the button
            else        br_fit(b);                            // expand -> size window to contents
            return;
        }
    }
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
    if (b->req_err[0] && b->retryw > 0 &&                     // Retry button (error state): re-run
        mx >= b->retryx && mx < b->retryx + b->retryw &&
        my >= b->infoy && my < b->infoy + b->infoh) {
        b->req_err[0] = 0;
        if (b->net == 1) srv_list_start(b); else net_list_start(b);
        repaint(); return;
    }
    b->selall = 0;                                           // any in-window click drops a "select all"
    int slot = br_hit_slot(b, mx, my);
    if (slot < 0) { b->sel = -1; repaint(); return; }
    int dd = b->rel[0] ? 1 : 0;
    int isdot = (dd && slot == 0);                          // synthetic ".." up-tile
    int i = slot-dd, was = (!isdot && b->sel == i);
    b->sel = isdot ? -1 : i; repaint();
    int mx2, my2, nc2; int16_t m2[8];
    int r = evnt_multi(MU_BUTTON|MU_TIMER, 2,1,1, 0,0,0,0,0, 0,0,0,0,0, m2, DCLICK_MS, 0,
                       &mx2, &my2, NULL, NULL, NULL, &nc2);
    if (r & MU_BUTTON) {
        int w2 = wind_find(mx2, my2);
        if (w2 == b->win && br_hit_slot(b, mx2, my2) == slot) {   // double-click
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
    b->viewmode = default_viewmode();
    b->sortmode = default_sortmode(); b->sortinv = default_sortinv();
    snprintf(b->mask, sizeof b->mask, "*");           // default file mask: show everything
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
    if (net != 1) {                                   // path windows: interactive title + right-side buttons
        wind_title(b->win, br_title, b);              // (servers window keeps a plain name, no buttons)
        int glyphs[2] = { WTG_CHEVRON, WTG_EXPAND };  // [0] View popup, [1] Fit
        wind_titlebtns(b->win, glyphs, 2);
    }
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
// testable core the host twin's --browsenav headless test drives.
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
    static struct xt_dirent de;
    int ns = 0, trunc = 0;
    for (int idx = 0; sys_readdir(dir, idx, &de) == 1; idx++) {
        if (de.name[0] == '.') continue;                 // hidden + . ..
        if (ns >= BR_MAX) { trunc = 1; break; }
        int isdir = (de.mode & XT_S_IFMT) == XT_S_IFDIR;
        snprintf(sc[ns].name, sizeof sc[ns].name, "%s", de.name);
        sc[ns].dir = isdir; ns++;
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
    desk_launch(nm, media); repaint();
}
// Open a browsed folder as a rooted browser WINDOW.  On A9 the logical path IS
// the SD path, so the absolute FS path is passed to open_browser directly.
static void browse_open_folder(const char *fullpath) {
    int media = strstr(fullpath, "m68k") ? ICT_MEDIA_1632 : ICT_MEDIA_8BIT;
    open_browser(fullpath, media); repaint();
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
    int cx = sx; if (cx > PW - 220) cx = PW - 220; if (cx < 0) cx = 0;
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
// modal ctx_menu_at) to match the host twin, whose --ctx test drives them.
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
enum { SH_VIEW_ICONS = 100, SH_VIEW_LIST, SH_VIEW_COLS, SH_VIEW_GALLERY,
       SH_SORT_NAME = 110, SH_SORT_TYPE, SH_SORT_SIZE, SH_SORT_DATE, SH_SORT_INV };

// Build the cascading Show submenu off a window's live view/sort state (the
// checkmarks track the current mode / inverted flag).  Returns the item count.
static int ctx_build_show(menu_item *it, browser *b) {
    int vm = b ? b->viewmode : 1, sm = b ? b->sortmode : 2, si = b ? b->sortinv : 0;
    int n = 0;
    it[n++] = (menu_item){ "Icons",        NULL, SH_VIEW_ICONS, NULL, 0, vm == 1 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "List",         NULL, SH_VIEW_LIST,  NULL, 0, vm == 2 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "Columns",      NULL, SH_VIEW_COLS,  NULL, 0, vm == 3 ? MI_CHECKED : 0 };
    it[n++] = (menu_item){ "Gallery",      NULL, SH_VIEW_GALLERY, NULL, 0, vm == 4 ? MI_CHECKED : 0 };
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
    int obj = objc_find(desk, 0, 2, mx, my);
    if (obj > 0) {                                       // a desktop icon
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
//   desktop bg    -> the SD root
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
            case ICT_MEDIA_8BIT: snprintf(out, cap, "/media/6502"); return 1;
            case ICT_MEDIA_1632: snprintf(out, cap, "/media/m68k"); return 1;
            case ICT_FUJINET:    return 0;               // net drive: local-only
            default:             snprintf(out, cap, "/"); return 1;
        }
    }
    snprintf(out, cap, "/");                             // desktop background -> the root
    return 1;
}
// Start the browse navigator for the resolved scope/target.  Local FS targets
// run the cascading navigator; the Fujinet desktop drive is a NETWORK root, so
// it routes to the net browser (open_fuji_servers) instead of the local nav.
static void ctx_browse(int scope, browser *b, int tentry, int tdeskobj) {
    if (!b && tdeskobj && rows[tdeskobj-1].type == ICT_FUJINET) { open_fuji_servers(); return; }
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
        br_list(b); br_settitle(b); repaint();
    } else if (b->net == 2) {
        net_open(b, i);
    } else {
        desk_launch(b->ent[i].name, b->media_type); repaint();
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
    repaint();                                        // repaint under the dismissed dialog
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
        if (sys_mkdir(full, 0777) != 0) { form_alert(1, "[3][Could not create the folder][OK]"); return; }
        br_list(b); br_settitle(b); repaint(); return;
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
    repaint();                                          // repaint under the dismissed dialog

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
        long fd = sys_open(full, O_CREAT | O_WRONLY);   // create an empty file
        if (fd < 0) { form_alert(1, "[3][Could not create the file][OK]"); return; }
        sys_close(fd);
    } else if (sys_mkdir(full, 0777) != 0) {
        form_alert(1, "[3][Could not create the folder][OK]"); return;
    }
    br_list(b); br_settitle(b); repaint();
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
        sys_unlink(full);                                // files (+ dirs the kernel allows); ignore failures
    }
    b->sel = -1; b->selall = 0;
    br_list(b); br_settitle(b); repaint();
}
// Dispatch a menu_popup result (factored out of ctx_menu_at to match the host
// twin, whose --ctx test invokes actions without driving the modal loop).
static void ctx_apply(int chosen, ctxrow *crows, int scope, browser *b, int tentry, int tdeskobj) {
    if (chosen < 0) return;
    if (chosen >= CTX_ROW_BASE) {                        // a flat contextMenu row
        switch (ctx_action_id(crows[chosen - CTX_ROW_BASE].action)) {
            case ACT_OPEN:      if (b && tentry >= 0) ctx_open_entry(b, tentry);
                                else if (tdeskobj)   open_icon(tdeskobj); break;
            case ACT_INFO:      ctx_info(scope, b, tentry, tdeskobj); break;
            case ACT_SELECTALL: if (b) { b->selall = 1; b->sel = -1; repaint(); } break;
            case ACT_NEW:       ctx_new(b); break;
            case ACT_DELETE:    ctx_delete(b, scope, tentry); break;
            case ACT_BROWSE:    ctx_browse(scope, b, tentry, tdeskobj); break;
            default:            break;                    // sep / unknown: no-op
        }
        return;
    }
    if (!b) return;                                      // Show items act on a window
    switch (chosen) {
        case SH_VIEW_ICONS: b->viewmode = 1; b->sel = -1; repaint(); break;
        case SH_VIEW_LIST:  b->viewmode = 2; b->sel = -1; repaint(); break;
        case SH_VIEW_COLS:  b->viewmode = 3; b->sel = -1; repaint(); break;
        case SH_VIEW_GALLERY: b->viewmode = 4; b->sel = -1; repaint(); break;
        case SH_SORT_NAME:  b->sortmode = 2; br_list(b); repaint(); break;
        case SH_SORT_TYPE:  b->sortmode = 3; br_list(b); repaint(); break;
        case SH_SORT_SIZE:  b->sortmode = 4; br_list(b); repaint(); break;
        case SH_SORT_DATE:  b->sortmode = 5; br_list(b); repaint(); break;
        case SH_SORT_INV:   b->sortinv = !b->sortinv; br_list(b); repaint(); break;
    }
}
// The right-click entry point: resolve the scope/target, highlight it, build the
// registry menu (+ the Show cascade), run it, dispatch the choice.
static void ctx_menu_at(int mx, int my) {
    browser *b; int tentry, tdeskobj;
    int scope = ctx_resolve(mx, my, &b, &tentry, &tdeskobj);
    if (b && tentry >= 0 && (b->sel != tentry || b->selall)) { b->sel = tentry; b->selall = 0; repaint(); }
    g_ctx_mx = mx; g_ctx_my = my;                        // browse popups open at the right-click point
    ctxrow crows[24]; menu_item items[24], show[12]; int nshow;
    int n = ctx_build_items(scope, crows, 24, items, show, &nshow, b);
    if (n <= 0) return;
    int chosen = menu_popup(items, n, mx, my);
    ctx_apply(chosen, crows, scope, b, tentry, tdeskobj);
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
// Right-click plumbing.  The A9 input layer has no secondary-button bit yet, so
// the documented terminal fallback is Ctrl+left (we also honour a real right
// button, bit 1, if that ever lands).  g_rclick marks the one synthetic click
// the main loop routes to the context menu; g_swallow_up turns the trailing
// button-release into a harmless motion so it can't pre-select a menu row.
static int g_rclick, g_swallow_up;

static int a9_events(aes_event *ev, int timeout_ms) {
    struct os_event oe = { OS_EV_TIMER, 0, 0, 0, 0, 0 };   // default if the syscall fails
    // raw keys while an emulator window is topped AND grabbed: Enter/Space TYPE
    // into the machine instead of clicking (the mouse clicks/drags either way)
    sys_input(&oe, timeout_ms, g_kbd_grab && emu_of_window(wind_top()) != NULL);
    g_rclick = 0;                                          // valid only for the event we return
    if (oe.type == OS_EV_BTN_DOWN && ((oe.button & 2) || (oe.shift & K_CTRL))) {
        g_rclick = 1; g_swallow_up = 1; oe.button = 1;     // secondary click: menu on the DOWN
    } else if (g_swallow_up && oe.type == OS_EV_BTN_UP) {
        g_swallow_up = 0; oe.type = OS_EV_MOTION; oe.button = 0;   // eat its release
    }
    ev->type = oe.type; ev->mx = oe.mx; ev->my = oe.my;
    ev->button = oe.button; ev->key = oe.key; ev->shift = oe.shift;
    ev->wheel = 0;                                        // A9 input layer has no wheel yet
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
    ctx_db_open("/OS/var/registry.db");              // parallel read-only conn for contextMenu

    /* Dialog resource: the SD layout first (/OS, user-overridable), then the copy
     * bundled in romfs (/System) so aesdesk has it in qemu / on a bare card.  No
     * host fopen here — read the bytes then rscload_mem().  On failure the built-in
     * hard-coded dialogs take over. */
    { static const char *const rscp[] = { "/OS/Apps/Desktop/desktop.rsc",
                                          "/System/OS/Apps/Desktop/desktop.rsc" };
      for (int i = 0; i < 2 && !g_rsc; i++) {
          struct xt_stat st;
          if (sys_stat(rscp[i], &st) != 0 || st.size == 0) continue;
          uint8_t *buf = malloc(st.size); if (!buf) continue;
          long fd = sys_open(rscp[i], O_RDONLY);
          if (fd < 0) { free(buf); continue; }
          long got = 0, k;
          while (got < (long)st.size && (k = sys_read(fd, buf + got, st.size - got)) > 0) got += k;
          sys_close(fd);
          const char *err = NULL;
          if (got == (long)st.size) g_rsc = rscload_mem(buf, st.size, &err);
          free(buf);
      }
      if (!g_rsc) sys_write(2, "aesdesk: no desktop.rsc — using built-in dialogs\n", 49); }

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
            if (g_rclick) { g_rclick = 0; ctx_menu_at(mx, my); }   // right-click -> context menu
            else {
                int wh = wind_find(mx, my); browser *b = wh ? br_of_window(wh) : NULL;
                if (b) br_click(b, mx, my); else desk_click(mx, my);
            }
        }
    }
    if (g_rsc) rscload_free(g_rsc);
    registry_close(); ctx_db_close();
}
