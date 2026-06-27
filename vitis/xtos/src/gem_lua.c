// gem_lua.c — bring the portable GEM VDI (+ FreeType scalable text) up on the
// A9 and expose it to Lua as the `vdi` table.
//
// The VDI draws through gfx.h primitives into a gfx_surface that wraps the
// compositor's desktop plane in DDR (0x30000000, RGBA-8888, 2048-word stride),
// so gem/gfx_soft.c renders straight into the live framebuffer.  The A9 writes
// through its cache, the compositor reads DDR — so every drawing op flushes the
// plane's cache range afterwards (same rule as main.c's screen.* helpers).
//
// Scope: VDI graphics + FreeType text only (no AES / window manager yet).  The
// hardware-blitter gfx backend (gfx_a9.c) is a planned follow-up; this first
// cut is the software renderer on the plane.

#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include "xil_cache.h"
#include "xil_printf.h"
#include "sprite.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include "gfx.h"
#include "vdi/vdi.h"
#include "gem.h"             /* gem_wm — backing-store window manager */
#include "blitter.h"         /* hardware blitter (HP1 DDR master) — gfx_a9 de-risk */
#include "compositor.h"      /* drag-overlay (xt_overlay_*) */

#define DESK_BASE    0x30000000u
#define DESK_W       1920
#define DESK_H       1080
#define DESK_STRIDE  2048            /* words per row (8192-byte stride) */

static gfx_surface g_desk = {
    .w = DESK_W, .h = DESK_H, .stride = DESK_STRIDE,
    .px = (uint32_t *)(uintptr_t)DESK_BASE,
};
static int        g_vh  = 0;         /* VDI virtual workstation handle (0 = down) */
static font_face *g_sys = NULL;      /* loaded system font (id 1)                 */
static gem_wm     g_wm;              /* backing-store window manager (lazy init)  */
static int        g_wm_up = 0;

static void desk_flush(void)
{
    Xil_DCacheFlushRange((INTPTR)DESK_BASE, (INTPTR)((uint32_t)DESK_H * DESK_STRIDE * 4u));
}

// One-shot diagnostic: isolate which layer fails for a font path — raw stdio
// (fopen/fseek/ftell/fread) vs FreeType (FT_New_Face).  Removed once fonts load.
static void gem_font_diag(const char *path)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) { xil_printf("    diag %s: fopen FAILED\r\n", path); }
    else {
        fseek(fp, 0, SEEK_END);
        long sz = ftell(fp);
        fseek(fp, 0, SEEK_SET);
        unsigned char hdr[4] = { 0 };
        unsigned got = (unsigned)fread(hdr, 1, sizeof hdr, fp);
        fclose(fp);
        xil_printf("    diag %s: fopen ok, ftell-size=%ld, read=%u, hdr=%02x %02x %02x %02x\r\n",
                   path, sz, got, hdr[0], hdr[1], hdr[2], hdr[3]);
    }
    FT_Library lib;
    FT_Error e1 = FT_Init_FreeType(&lib);
    if (e1) { xil_printf("    diag %s: FT_Init_FreeType -> err %d\r\n", path, (int)e1); return; }
    FT_Face fc;
    FT_Error e2 = FT_New_Face(lib, path, 0, &fc);
    if (e2) xil_printf("    diag %s: FT_New_Face -> err %d\r\n", path, (int)e2);
    else {
        xil_printf("    diag %s: FT_New_Face OK, family='%s', glyphs=%ld\r\n",
                   path, fc->family_name ? fc->family_name : "(null)", (long)fc->num_glyphs);
        FT_Done_Face(fc);
    }
    FT_Done_FreeType(lib);
}

// Bring up the VDI on the desktop plane + load the system font.  Called once at
// boot, after the SD is mounted (the font file is read via the VFS).
int gem_init(void)
{
    vdi_init(&g_desk);                       /* default target + 16-pen palette  */
    vdi_set_font_dir("/OS/Fonts");           /* VFS path (FatFs is mounted at /)  */
    g_sys = vdi_load_system_font();          /* /OS/Fonts/System.font -> the TTF  */
    g_vh  = v_opnvwk(&g_desk);               /* virtual workstation on the plane  */
    if (g_vh <= 0) { xil_printf("  gem: v_opnvwk failed\r\n"); g_vh = 0; return -1; }
    if (g_sys == NULL) {
        xil_printf("  gem: VDI up (handle %d) but no system font — diagnosing:\r\n", g_vh);
        gem_font_diag("/OS/Fonts/System.font");
        gem_font_diag("/OS/Fonts/Roboto.ttf");
        return -1;
    }
    char name[64] = { 0 };
    vqt_name(g_vh, 1, name);
    xil_printf("  gem: VDI up (handle %d), system font = '%s'\r\n", g_vh, name);
    return 0;
}

// ---- Lua bindings (`vdi` table) ------------------------------------------
// All ops are no-ops with an error if the VDI failed to come up.

static int gem_ready(lua_State *L)
{
    if (g_vh > 0) return 1;
    luaL_error(L, "vdi not initialised (no system font?)");
    return 0;
}

static int l_vdi_text(lua_State *L)   /* vdi.text(x, y, str [, pts]) */
{
    if (!gem_ready(L)) return 0;
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    const char *s = luaL_checkstring(L, 3);
    if (lua_gettop(L) >= 4 && !lua_isnil(L, 4))
        vst_point(g_vh, (int)luaL_checkinteger(L, 4), NULL, NULL, NULL, NULL);
    v_gtext(g_vh, x, y, s);
    desk_flush();
    return 0;
}

static int l_vdi_point(lua_State *L)  /* vdi.point(pts) — text size in points */
{
    if (!gem_ready(L)) return 0;
    vst_point(g_vh, (int)luaL_checkinteger(L, 1), NULL, NULL, NULL, NULL);
    return 0;
}

static int l_vdi_color(lua_State *L)  /* vdi.color(pen) — text colour (1=black) */
{
    if (!gem_ready(L)) return 0;
    vst_color(g_vh, (int)luaL_checkinteger(L, 1));
    return 0;
}

/* vdi.rotation(tenths) — text baseline angle in 1/10 degree, CCW, any angle.
 * Stateful on the workstation (like the GEM API): set it, draw with vdi.text,
 * reset to 0.  Returns the normalised angle (0..3599). */
static int l_vdi_rotation(lua_State *L)
{
    if (!gem_ready(L)) return 0;
    int a = vst_rotation(g_vh, (int)luaL_checkinteger(L, 1));
    lua_pushinteger(L, a);
    return 1;
}

static int l_vdi_fillcolor(lua_State *L)  /* vdi.fillcolor(pen) — solid fill */
{
    if (!gem_ready(L)) return 0;
    vsf_color(g_vh, (int)luaL_checkinteger(L, 1));
    vsf_interior(g_vh, 1);                /* VDI_FIS_SOLID */
    return 0;
}

static int l_vdi_bar(lua_State *L)    /* vdi.bar(x, y, w, h) — filled rectangle */
{
    if (!gem_ready(L)) return 0;
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3), h = (int)luaL_checkinteger(L, 4);
    int16_t pxy[4] = { (int16_t)x, (int16_t)y,
                       (int16_t)(x + w - 1), (int16_t)(y + h - 1) };
    v_bar(g_vh, pxy);
    desk_flush();
    return 0;
}

static int l_vdi_line(lua_State *L)   /* vdi.line(x0,y0,x1,y1[,pen]) — line segment */
{
    if (!gem_ready(L)) return 0;
    int16_t pxy[4] = {
        (int16_t)luaL_checkinteger(L, 1), (int16_t)luaL_checkinteger(L, 2),
        (int16_t)luaL_checkinteger(L, 3), (int16_t)luaL_checkinteger(L, 4)
    };
    if (!lua_isnoneornil(L, 5)) vsl_color(g_vh, (int)luaL_checkinteger(L, 5));
    v_pline(g_vh, 2, pxy);                /* 1px solid -> blitter LINE_DRAW path */
    desk_flush();
    return 0;
}

static int l_vdi_clear(lua_State *L)  /* vdi.clear() — whole workstation to pen 0 */
{
    if (!gem_ready(L)) return 0;
    v_clrwk(g_vh);
    desk_flush();
    return 0;
}

static int l_vdi_flush(lua_State *L)  /* vdi.flush() — push the plane to the compositor */
{
    (void)L;
    desk_flush();
    return 0;
}

static int l_vdi_font(lua_State *L)   /* name = vdi.font() — system font family */
{
    if (!gem_ready(L)) return 0;
    char name[64] = { 0 };
    vqt_name(g_vh, 1, name);
    lua_pushstring(L, name);
    return 1;
}

/* vdi.hwfill(x, y, w, h, 0xRRGGBB) — de-risk the hardware blitter: a solid
 * RECT_FILL into the desktop plane (FB_BASE=0x30000000) via a 1x1 RGBA pattern.
 * The blitter writes DDR directly through HP1 (no A9 cache flush needed).
 * Returns (idle, seq): idle==0 means the command FSM completed, seq is the SYNC
 * counter (was last seen NOT advancing on HW — this proves whether it does now). */
static int l_vdi_hwfill(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3), h = (int)luaL_checkinteger(L, 4);
    uint32_t c = (uint32_t)luaL_checkinteger(L, 5);          /* 0xRRGGBB */
    uint8_t pat[4] = { (uint8_t)(c >> 16), (uint8_t)(c >> 8),
                       (uint8_t)c, 0xFF };                   /* R,G,B,A=opaque */
    xt_blitter_set_pat_log(0, 0);                            /* 1x1 pattern */
    xt_blitter_set_pat_phase(0, 0);
    xt_blitter_write_pat(pat, 4);
    xt_blitter_set_raster_op(XT_BL_RASTER_S);                /* S (copy) */
    xt_blitter_set_dst((int16_t)x, (int16_t)y, (uint16_t)w, (uint16_t)h);
    xt_blitter_fire(XT_BL_CMD_RECT_FILL);
    int idle = xt_blitter_wait_idle(200000);                 /* 0 ok, -1 timeout */
    lua_pushinteger(L, idle);
    lua_pushinteger(L, (lua_Integer)xt_blitter_seq_counter());
    return 2;
}

/* vdi.scaletest(sx,sy,sw,sh, dx,dy,dw,dh [,bilinear]) — scale a plane region to
 * another plane region via the blitter SCALED_BLIT (bilinear by default).  Point
 * the source at existing on-screen content (e.g. the READY text) and watch it
 * scale up smoothly.  Plane src + dst (no descriptor); the blitter writes DDR
 * directly so the compositor shows it with no flush. */
static int l_vdi_scaletest(lua_State *L)
{
    int sx=(int)luaL_checkinteger(L,1), sy=(int)luaL_checkinteger(L,2);
    int sw=(int)luaL_checkinteger(L,3), sh=(int)luaL_checkinteger(L,4);
    int dx=(int)luaL_checkinteger(L,5), dy=(int)luaL_checkinteger(L,6);
    int dw=(int)luaL_checkinteger(L,7), dh=(int)luaL_checkinteger(L,8);
    int bilin = (lua_gettop(L) >= 9) ? lua_toboolean(L, 9) : 1;   /* default bilinear */
    xt_blitter_set_src((int16_t)sx,(int16_t)sy,(uint16_t)sw,(uint16_t)sh);
    xt_blitter_set_dst((int16_t)dx,(int16_t)dy,(uint16_t)dw,(uint16_t)dh);
    xt_blitter_set_flags(bilin ? XT_BL_FLAG_BILINEAR : 0);   /* plane src + dst */
    xt_blitter_fire(XT_BL_CMD_SCALED_BLIT);
    int idle = xt_blitter_wait_idle(200000);
    lua_pushinteger(L, idle);
    return 1;
}

/* gem_wm de-risk: bring up the backing-store window manager on the live plane
 * and spawn two windows.  Each window owns an off-plane DDR backing the VDI
 * draws into (local coords); gem_wm_draw() composites them onto the plane via
 * the hardware blitter (gfx_blit, any-DDR DDR->DDR).  vdi.wintest() */
static void win_content(gem_window *win, void *ud)
{
    int vh = win->vh;                       /* VDI workstation on the backing */
    int16_t r[4];
    vsf_interior(vh, 1);
    vsf_color(vh, 0);                       /* pen 0 = white: content background */
    r[0]=0; r[1]=0; r[2]=(int16_t)(win->cw-1); r[3]=(int16_t)(win->ch-1);
    vr_recfl(vh, r);
    vst_color(vh, 1);                       /* black text */
    vst_height(vh, 28, NULL, NULL, NULL, NULL);
    v_gtext(vh, 14, 44, (const char *)ud);
}

static void cur_init(void);                 /* HW-sprite cursor (defined below) */

static int l_vdi_wintest(lua_State *L)
{
    if (!gem_ready(L)) return 0;
    if (!g_wm_up) {
        gem_wm_init(&g_wm, &g_desk, GFX_RGB(0x20, 0x60, 0x90));
        gem_wm_set_font(&g_wm, g_sys);
        g_wm.no_cursor = 1;          /* the A9 owns the pointer (HW sprite, below) */
        g_wm_up = 1;
        cur_init();                  /* bring up the hardware-sprite cursor */
    }
    gem_window *a = gem_wm_add(&g_wm, 220, 160, 380, 260, "Window One", 1);
    if (a) gem_wm_set_redraw(a, win_content, (void *)"Hello from window one");
    gem_window *b = gem_wm_add(&g_wm, 560, 380, 380, 260, "Window Two", 0);
    if (b) gem_wm_set_redraw(b, win_content, (void *)"...and window two");
    gem_wm_draw(&g_wm);
    desk_flush();
    return 0;
}

/* ---- serial-keyboard mouse driver -----------------------------------------
 * main.c routes passthrough chars here while mouse-drive mode is on (toggled by
 * '\').  Cursor keys move the WM pointer; Ctrl+arrow holds the LEFT button (so a
 * Ctrl+arrow then a plain arrow = a click; sustained Ctrl+arrows = a drag).
 * Option/Alt+arrow is the right button (reserved — gem_wm has no right action
 * yet).  Recomposites + flushes the plane after each event. */
static int  g_mx = DESK_W/2, g_my = DESK_H/2;   /* WM pointer position */
static int  g_mbtn = 0;                          /* left button currently down */
static int  g_esc = 0, g_escn = 0;               /* CSI escape parse state */
static char g_escbuf[8];

/* ---- Hardware-sprite pointer ----------------------------------------------
 * The cursor is sprite slot CUR_SLOT, composited on top of everything (including
 * the drag overlay) in the scan-out path.  Moving it is just a descriptor
 * reposition — no save-under, no plane traffic, and no baking into the drag
 * surface (the sprite is already above it). */
#define CURW 12
#define CURH 19
#define CUR_SLOT 0
static const char *s_arrow[CURH] = {
    "X           ", "XX          ", "X.X         ", "X..X        ",
    "X...X       ", "X....X      ", "X.....X     ", "X......X    ",
    "X.......X   ", "X........X  ", "X.....XXXXX ", "X..X..X     ",
    "X.X X..X    ", "XX  X..X    ", "X    X..X   ", "     X..X   ",
    "      X..X  ", "      X..X  ", "       XX   ",
};
static int s_cx, s_cy, s_cvis;

/* Paint the 12x19 arrow into a 32x32 transparent sprite image and bring the
 * cursor up at the current pointer position.  Call once, after the sprite
 * engine is live (post-bitstream). */
static void cur_init(void) {
    static uint32_t img[32 * 32];
    for (int r = 0; r < 32; r++)
        for (int c = 0; c < 32; c++) {
            uint32_t px = 0x00000000u;                   /* transparent (alpha=0) */
            if (r < CURH && c < CURW) {
                char ch = s_arrow[r][c];
                if      (ch == 'X') px = 0x000000FFu;     /* black outline, opaque */
                else if (ch == '.') px = 0xFFFFFFFFu;     /* white fill, opaque    */
            }
            img[r * 32 + c] = px;
        }
    sprite_load_rgba(0, 0, 32, 32, img);                 /* arena image at (0,0) */
    sprite_set(CUR_SLOT, /*prio*/0, /*log2sz*/5, /*arena*/0, 0, g_mx, g_my);
    sprite_enable(CUR_SLOT, /*format32*/1);
    sprite_global_enable(1);
    s_cx = g_mx; s_cy = g_my; s_cvis = 1;
}

/* Reposition the cursor sprite (hot spot = its top-left = (x,y)). */
static void cur_show(int x, int y) {
    sprite_set(CUR_SLOT, 0, 5, 0, 0, x, y);
    s_cx = x; s_cy = y; s_cvis = 1;
}

/* The HW sprite stays composited on top — nothing to erase from the plane. */
static void cur_hide(void) {
    s_cvis = 0;
}

/* Move the pointer.  Pure moves touch only the cursor box; a HW-overlay drag
 * moves just the overlay layer; otherwise (button held, no overlay) the WM may
 * move a window so we recomposite the whole scene. */

/* ---- HW drag overlay (compositor plane 1) ---------------------------------
 * While a window is dragged we LIFT it off the GEM desktop plane (g_wm.hide_slot
 * omits it from draws) and show it in the hardware overlay layer instead, so a
 * move is one register write (vblank-latched, tear-free) with NO plane redraw.
 * The drag surface is a tight RGBA copy of the (raised, unoccluded) window rect
 * read straight off the plane, with the pointer baked in at the grab offset so
 * the cursor tracks the window (the overlay sits ABOVE the plane, so the plane
 * save-under pointer would otherwise be hidden under it).  Shares the test
 * scratch with the REPL `ovl` command (never concurrent). */
/* The desktop plane spans 0x30000000..0x30870000 (8192-byte stride * 1080) and
 * the XL buffers sit at 0x31000000..0x31300000, so the drag surface lives in the
 * clear region above them.  16 MB fits any window up to 2048x2048 at the fixed
 * OVL_STRIDE_W. */
#define DRAG_BASE 0x32000000u
#define DRAG_END  0x33000000u
static int g_drag_active = 0;

/* Flush a plane rectangle to DDR (row by row), clamped to the desktop — so a
 * damage-rect redraw only pushes its own area (not the whole 8 MB plane, which
 * would race the scanout and flicker every window). */
static void flush_rect(int x, int y, int w, int h)
{
    uint32_t *pl = (uint32_t *)(uintptr_t)DESK_BASE;
    if (x < 0) { w += x; x = 0; }  if (y < 0) { h += y; y = 0; }
    if (x + w > DESK_W) w = DESK_W - x;
    if (y + h > DESK_H) h = DESK_H - y;
    if (w <= 0 || h <= 0) return;
    for (int r = 0; r < h; r++)
        Xil_DCacheFlushRange((INTPTR)(pl + (size_t)(y+r)*DESK_STRIDE + x), (unsigned)w*4);
}

static void drag_build_surface(gem_window *w, int gx, int gy)
{
    uint32_t *pl = (uint32_t *)(uintptr_t)DESK_BASE;
    uint32_t *ds = (uint32_t *)(uintptr_t)DRAG_BASE;
    int W = w->w, H = w->h;                           /* surface uses OVL_STRIDE_W/row */
    for (int r = 0; r < H; r++) {
        int py = w->y + r;
        for (int c = 0; c < W; c++) {
            int px = w->x + c;
            ds[(size_t)r*OVL_STRIDE_W + c] = (px >= 0 && px < DESK_W && py >= 0 && py < DESK_H)
                                ? pl[(size_t)py*DESK_STRIDE + px] : 0;
        }
    }
    (void)gx; (void)gy;   /* cursor is a HW sprite on top of the overlay — no bake */
    for (int r = 0; r < H; r++)                       /* strided -> flush each row's W px */
        Xil_DCacheFlushRange((INTPTR)(ds + (size_t)r*OVL_STRIDE_W), (size_t)W*4u);
}

/* Drag-path tracing.  These printfs sit in the per-move hot path; over the UART
 * each line is several ms and the queue backs up, throttling interactive drag
 * latency (the cleanup redraw appears to "catch up" a fraction of a second
 * later).  Off by default — build with -DGEM_DRAG_DEBUG=1 to re-enable. */
#ifndef GEM_DRAG_DEBUG
#define GEM_DRAG_DEBUG 0
#endif
#if GEM_DRAG_DEBUG
#define DRAG_DBG(...) xil_printf(__VA_ARGS__)
#else
#define DRAG_DBG(...) ((void)0)
#endif

/* Begin a HW-overlay drag of the (already raised) window in g_wm.drag_slot.
 * All redraws are confined to the window's OWN rect (no full-screen clear/flush,
 * which would flicker every window).  The window is NOT lifted off the plane
 * yet: it stays drawn, exactly coincident with the overlay, so nothing changes
 * visibly at grab.  The lift happens on the first actual move (wm_pointer). */
static void drag_begin(void)
{
    gem_window *w = &g_wm.win[g_wm.drag_slot];        /* fixed stride: cap W to the stride */
    if ((unsigned)w->w > OVL_STRIDE_W ||              /* and H so the surface fits the region */
        (size_t)w->h * (OVL_STRIDE_W * 4u) > (DRAG_END - DRAG_BASE)) return; /* else SW path */
    int x0 = w->x, y0 = w->y;
    gem_wm_draw_rect(&g_wm, x0, y0, x0 + w->w - 1, y0 + w->h - 1);  /* window on top (raise) */
    flush_rect(x0, y0, w->w, w->h);                                /* — confined to its rect */
    drag_build_surface(w, g_wm.drag_ox, g_wm.drag_oy);             /* copy the clean window  */
    int ox = w->x < 0 ? 0 : w->x, oy = w->y < 0 ? 0 : w->y;
    xt_overlay_enable(DRAG_BASE, (uint16_t)ox, (uint16_t)oy,       /* overlay coincident with */
                      (uint16_t)w->w, (uint16_t)w->h);             /* the still-drawn window  */
    s_cvis = 0;                                       /* pointer now lives in the overlay */
    g_drag_active = 1;                                /* hide_slot stays -1 until first move */
    DRAG_DBG("[drag] GRAB slot=%d win=(%d,%d %dx%d) off=(%d,%d)\r\n",
               g_wm.drag_slot, w->x, w->y, w->w, w->h, g_wm.drag_ox, g_wm.drag_oy);
}

/* End a HW-overlay drag: settle the window onto the plane at its final spot
 * (confined redraw, under the still-live overlay), then retire the overlay. */
static void drag_end(void)
{
    int fx = 0, fy = 0, fw = 0, fh = 0, have = 0;
    if (g_wm.drag_slot >= 0) {                        /* capture final rect before release */
        gem_window *w = &g_wm.win[g_wm.drag_slot];
        fx = w->x; fy = w->y; fw = w->w; fh = w->h; have = 1;
    }
    DRAG_DBG("[drag] DROP final=(%d,%d %dx%d)\r\n", fx, fy, fw, fh);
    gem_wm_mouse_button(&g_wm, g_mx, g_my, 0);        /* end the WM drag (clears drag_slot) */
    g_mbtn = 0;
    g_wm.hide_slot = -1;                              /* un-lift: the window draws again */
    if (have) {                                       /* redraw it at the final pos, confined */
        gem_wm_draw_rect(&g_wm, fx, fy, fx + fw - 1, fy + fh - 1);
        flush_rect(fx, fy, fw, fh);
    }
    cur_show(g_mx, g_my);                             /* restore the plane pointer        */
    xt_overlay_disable();                             /* retire the overlay (window already there) */
    g_drag_active = 0;
}

static void wm_pointer(int dx, int dy)
{
    if (!g_wm_up) return;
    int nx = g_mx + dx; if (nx < 0) nx = 0; if (nx >= DESK_W) nx = DESK_W - 1;
    int ny = g_my + dy; if (ny < 0) ny = 0; if (ny >= DESK_H) ny = DESK_H - 1;
    if (g_drag_active) {                              /* HW-overlay drag: move the layer only */
        gem_window *w = &g_wm.win[g_wm.drag_slot];
        if (g_wm.hide_slot < 0) {                     /* first move: lift it off the plane now */
            int x0 = w->x, y0 = w->y;                 /* OLD rect — redraw UNDER the overlay   */
            g_wm.hide_slot = g_wm.drag_slot;          /* (overlay still covers it), then the   */
            gem_wm_draw_rect(&g_wm, x0, y0, x0 + w->w - 1, y0 + w->h - 1);  /* move reveals the */
            flush_rect(x0, y0, w->w, w->h);           /* clean hole — no flicker, confined.    */
            DRAG_DBG("[drag] LIFT hole=(%d,%d %dx%d)\r\n", x0, y0, w->w, w->h);
        }
        g_mx = nx; g_my = ny;
        gem_wm_mouse_move(&g_wm, nx, ny);            /* updates the (hidden) window's x/y */
        int ox = w->x < 0 ? 0 : w->x, oy = w->y < 0 ? 0 : w->y;
        xt_overlay_move((uint16_t)ox, (uint16_t)oy); /* tear-free; no plane write, no flush */
        cur_show(g_mx, g_my);                        /* HW cursor sprite tracks, on top of the overlay */
        DRAG_DBG("[drag] MOVE ptr=(%d,%d) win=(%d,%d) ovl=(%d,%d)\r\n",
                   g_mx, g_my, w->x, w->y, ox, oy);
    } else if (g_mbtn) {                              /* button down, no window grabbed -> full */
        s_cvis = 0;
        g_mx = nx; g_my = ny;
        gem_wm_mouse_move(&g_wm, nx, ny);
        gem_wm_draw(&g_wm); desk_flush(); cur_show(nx, ny);
    } else {                                          /* pure move -> cursor box only */
        cur_hide();
        g_mx = nx; g_my = ny;
        cur_show(nx, ny);
    }
}

/* Topmost live window currently marked active, or NULL. */
static gem_window *wm_active_window(void)
{
    for (int i = g_wm.nwin - 1; i >= 0; i--) {
        gem_window *w = &g_wm.win[g_wm.z[i]];
        if (w->used && w->active) return w;
    }
    return NULL;
}

/* Toggle the left button at the pointer (space): grab a title to drag, or tap
 * twice for a click (raise / close box). */
static void wm_button_toggle(void)
{
    if (!g_wm_up) return;
    if (g_drag_active) { drag_end(); return; }        /* second press -> drop the window */
    g_mbtn = !g_mbtn;
    cur_hide();                                        /* cleanly erase the plane pointer first */
    gem_window *prev = wm_active_window();             /* who's active BEFORE the raise/focus */
    gem_wm_mouse_button(&g_wm, g_mx, g_my, g_mbtn);    /* press raises+focuses+grabs; release ends */
    if (g_mbtn && g_wm.drag_slot >= 0) {              /* grabbed a title -> HW-overlay drag */
        drag_begin();
        if (g_drag_active) {
            gem_window *cur = &g_wm.win[g_wm.drag_slot];
            if (prev && prev != cur && !prev->active) {   /* focus moved: repaint the */
                gem_wm_draw_rect(&g_wm, prev->x, prev->y, /* de-focused window inactive, */
                                 prev->x + prev->w - 1, prev->y + prev->h - 1);
                flush_rect(prev->x, prev->y, prev->w, prev->h);   /* confined to its rect */
                DRAG_DBG("[drag] DEFOCUS prev=(%d,%d %dx%d)\r\n",
                           prev->x, prev->y, prev->w, prev->h);
            }
            return;                                   /* overlay running; pointer is baked in */
        }
    }
    gem_wm_draw(&g_wm);                               /* click / close / too-big: normal redraw */
    desk_flush();
    cur_show(g_mx, g_my);
}

/* Re-sync + redraw the cursor (mode entry) and drop any held button (mode exit). */
void gem_mouse_reset(void)
{
    g_esc = 0; g_escn = 0;
    if (!g_wm_up) return;
    if (g_drag_active)      drag_end();                            /* clean up a live drag */
    else if (g_mbtn) { gem_wm_mouse_button(&g_wm, g_mx, g_my, 0); g_mbtn = 0; }
    cur_hide();
    cur_show(g_mx, g_my);   /* (re)show the pointer at its current spot */
}

/* Feed one passthrough char while mouse-drive mode is on. */
void gem_mouse_feed(int c)
{
    if (g_esc == 0) {
        if (c == 0x1B) { g_esc = 1; return; }                /* ESC -> CSI */
        if (c == ' ')  { wm_button_toggle(); return; }       /* space = left button grab/drop */
        return;                                              /* ignore other keys in mouse mode */
    }
    if (g_esc == 1) { g_esc = (c == '[') ? 2 : 0; g_escn = 0; return; }  /* CSI introducer */
    if ((c >= '0' && c <= '9') || c == ';') {                /* skip any modifier params */
        if (g_escn < (int)sizeof(g_escbuf) - 1) g_escbuf[g_escn++] = (char)c;
        return;
    }
    int step = 24, dx = 0, dy = 0;
    switch (c) {
        case 'A': dy = -step; break;     /* up    */
        case 'B': dy =  step; break;     /* down  */
        case 'C': dx =  step; break;     /* right */
        case 'D': dx = -step; break;     /* left  */
        default:  g_esc = 0; g_escn = 0; return;             /* not a cursor key */
    }
    wm_pointer(dx, dy);
    g_esc = 0; g_escn = 0;
}

/* vdi.srctest(x, y, 0xRRGGBB) — de-risk SRC_BLIT's coverage→colour path (the
 * font path).  Builds a 64x32 coverage atlas in DDR with a horizontal 0->255
 * gradient, then blits it in the given colour to (x,y) on the plane: you should
 * see a left-to-right fade from the background into a solid colour block.
 * Proves the DDR-source read + coverage blend on hardware before FreeType. */
static int l_vdi_srctest(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    uint32_t c = (uint32_t)luaL_checkinteger(L, 3);
    static uint8_t atlas[64 * 32] __attribute__((aligned(64)));   /* DDR, flat-mapped */
    for (int yy = 0; yy < 32; yy++)
        for (int xx = 0; xx < 64; xx++)
            atlas[yy * 64 + xx] = (uint8_t)(xx * 255 / 63);       /* 0..255 across */
    Xil_DCacheFlushRange((INTPTR)atlas, (INTPTR)sizeof atlas);    /* push to DDR for HP read */
    desk_flush();                                                 /* no stale plane lines */

    uint8_t pat[4] = { (uint8_t)(c >> 16), (uint8_t)(c >> 8), (uint8_t)c, 0xFF };
    xt_blitter_set_pat_log(0, 0);
    xt_blitter_set_pat_phase(0, 0);
    xt_blitter_write_pat(pat, 4);                                 /* 1x1 = text colour */
    xt_blitter_set_src_surface((uint32_t)(uintptr_t)atlas, 64, 1); /* coverage atlas (1 B/px) */
    xt_blitter_set_dst_surface(DESK_BASE, DESK_STRIDE * 4);        /* dest = plane (explicit surface) */
    xt_blitter_set_flags(XT_BL_FLAG_SRC_COV);
    xt_blitter_src_blit(0, 0, 64, 32, (int16_t)x, (int16_t)y);
    int idle = xt_blitter_wait_idle(200000);
    lua_pushinteger(L, idle);
    return 1;
}

/* vdi.windowtest(x, y, w, h, rgb) — allocate a w*h DDR backing store, HW-fill it
 * with the colour (off-plane RECT_FILL), then HW-composite it to the desktop
 * plane at (x,y) (BLOCK_BLIT backing-store -> plane).  Proves the any-DDR fill +
 * compositing path that GEM windows ride on.  Returns true, or false+msg. */
static int l_vdi_windowtest(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1), y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3), h = (int)luaL_checkinteger(L, 4);
    uint32_t rgb = (uint32_t)luaL_checkinteger(L, 5);   /* 0xRRGGBB */
    uint32_t rgba = (rgb << 8) | 0xFFu;                 /* opaque */

    gfx_surface *bs = gfx_surface_alloc(w, h);
    if (!bs) { lua_pushboolean(L, 0); lua_pushstring(L, "backing-store alloc failed"); return 2; }
    gfx_fill_rect(bs, 0, 0, w, h, rgba);                /* off-plane fill   */
    gfx_blit(&g_desk, x, y, bs, 0, 0, w, h);            /* composite -> plane */
    gfx_surface_free(bs);
    lua_pushboolean(L, 1);
    return 1;
}

void gem_lua_open(lua_State *L)
{
    static const luaL_Reg vdi_lib[] = {
        {"text",      l_vdi_text},
        {"point",     l_vdi_point},
        {"color",     l_vdi_color},
        {"rotation",  l_vdi_rotation}, /* text angle, 1/10 deg CCW (vst_rotation) */
        {"fillcolor", l_vdi_fillcolor},
        {"bar",       l_vdi_bar},
        {"line",      l_vdi_line},    /* 1px solid line — blitter LINE_DRAW */
        {"clear",     l_vdi_clear},
        {"flush",     l_vdi_flush},
        {"font",      l_vdi_font},
        {"hwfill",    l_vdi_hwfill},   /* blitter RECT_FILL — HW de-risk */
        {"srctest",   l_vdi_srctest},  /* SRC_BLIT coverage — HW de-risk */
        {"windowtest",l_vdi_windowtest}, /* off-plane fill + composite — HW de-risk */
        {"scaletest", l_vdi_scaletest},  /* SCALED_BLIT bilinear — HW de-risk */
        {"wintest",   l_vdi_wintest},    /* gem_wm backing-store windows — HW de-risk */
        {NULL, NULL}
    };
    luaL_newlib(L, vdi_lib);
    lua_setglobal(L, "vdi");
}
