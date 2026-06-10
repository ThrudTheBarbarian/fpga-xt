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

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include "gfx.h"
#include "vdi/vdi.h"
#include "gem.h"             /* gem_wm — backing-store window manager */
#include "xt_blitter.h"      /* hardware blitter (HP1 DDR master) — gfx_a9 de-risk */

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

static int l_vdi_wintest(lua_State *L)
{
    if (!gem_ready(L)) return 0;
    if (!g_wm_up) {
        gem_wm_init(&g_wm, &g_desk, GFX_RGB(0x20, 0x60, 0x90));
        gem_wm_set_font(&g_wm, g_sys);
        g_wm.no_cursor = 1;          /* the A9 owns the pointer (save-under, below) */
        g_wm_up = 1;
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

/* ---- A9 save-under pointer ------------------------------------------------
 * gem_wm draws the scene only (no_cursor=1); we move the pointer by touching
 * just its 12x19 box.  The scene under it is HW-composited in DDR, so the
 * save-under read invalidates that box first; the cursor write flushes it. */
#define CURW 12
#define CURH 19
static const char *s_arrow[CURH] = {
    "X           ", "XX          ", "X.X         ", "X..X        ",
    "X...X       ", "X....X      ", "X.....X     ", "X......X    ",
    "X.......X   ", "X........X  ", "X.....XXXXX ", "X..X..X     ",
    "X.X X..X    ", "XX  X..X    ", "X    X..X   ", "     X..X   ",
    "      X..X  ", "      X..X  ", "       XX   ",
};
static uint32_t s_save[CURW * CURH];
static int s_cx, s_cy, s_cvis;

static void cur_inval(int x, int y) {
    uint32_t *pl = (uint32_t *)(uintptr_t)DESK_BASE;
    for (int r = 0; r < CURH; r++) { int py = y + r; if (py < 0 || py >= DESK_H) continue;
        Xil_DCacheInvalidateRange((INTPTR)(pl + (size_t)py*DESK_STRIDE + x), CURW*4); }
}
static void cur_flush(int x, int y) {
    uint32_t *pl = (uint32_t *)(uintptr_t)DESK_BASE;
    for (int r = 0; r < CURH; r++) { int py = y + r; if (py < 0 || py >= DESK_H) continue;
        Xil_DCacheFlushRange((INTPTR)(pl + (size_t)py*DESK_STRIDE + x), CURW*4); }
}
static void cur_hide(void) {
    if (!s_cvis) return;
    uint32_t *pl = (uint32_t *)(uintptr_t)DESK_BASE;
    for (int r = 0; r < CURH; r++) { int py = s_cy + r; if (py < 0 || py >= DESK_H) continue;
        for (int c = 0; c < CURW; c++) { int px = s_cx + c; if (px < 0 || px >= DESK_W) continue;
            pl[(size_t)py*DESK_STRIDE + px] = s_save[r*CURW + c]; } }
    cur_flush(s_cx, s_cy);
    s_cvis = 0;
}
static void cur_show(int x, int y) {
    uint32_t *pl = (uint32_t *)(uintptr_t)DESK_BASE;
    cur_inval(x, y);                                   /* read fresh HW-composited scene */
    for (int r = 0; r < CURH; r++) { int py = y + r;
        for (int c = 0; c < CURW; c++) { int px = x + c;
            int in = (py >= 0 && py < DESK_H && px >= 0 && px < DESK_W);
            s_save[r*CURW + c] = in ? pl[(size_t)py*DESK_STRIDE + px] : 0;
            char ch = s_arrow[r][c];
            if (ch == ' ' || !in) continue;
            pl[(size_t)py*DESK_STRIDE + px] = (ch == 'X') ? GFX_RGB(0,0,0) : GFX_RGB(255,255,255);
        } }
    cur_flush(x, y);
    s_cx = x; s_cy = y; s_cvis = 1;
}

/* Move the pointer.  Pure moves touch only the cursor box; with a button held
 * (click/drag) the WM may move a window, so recomposite the whole scene. */
/* Flush a plane rectangle to DDR (row by row), clamped to the desktop. */
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

static void wm_pointer(int dx, int dy)
{
    if (!g_wm_up) return;
    int nx = g_mx + dx; if (nx < 0) nx = 0; if (nx >= DESK_W) nx = DESK_W - 1;
    int ny = g_my + dy; if (ny < 0) ny = 0; if (ny >= DESK_H) ny = DESK_H - 1;
    if (g_mbtn && g_wm.drag_slot >= 0) {              /* dragging a window -> damage-rect redraw */
        gem_window *w = &g_wm.win[g_wm.drag_slot];   /* full old∪new rect: artifact-free (the */
        int ox0 = w->x, oy0 = w->y;                  /* per-strip composite-in-place was buggy; */
        int ox1 = w->x + w->w - 1, oy1 = w->y + w->h - 1;  /* tearing is the real issue -> needs */
        s_cvis = 0;                                  /* a double-buffered GEM layer, not this).  */
        g_mx = nx; g_my = ny;
        gem_wm_mouse_move(&g_wm, nx, ny);            /* moves the window */
        int x0 = w->x < ox0 ? w->x : ox0, y0 = w->y < oy0 ? w->y : oy0;
        int x1 = (w->x + w->w - 1) > ox1 ? (w->x + w->w - 1) : ox1;
        int y1 = (w->y + w->h - 1) > oy1 ? (w->y + w->h - 1) : oy1;
        gem_wm_draw_rect(&g_wm, x0, y0, x1, y1);
        flush_rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1);
        cur_show(nx, ny);
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

/* Toggle the left button at the pointer (space): grab a title to drag, or tap
 * twice for a click (raise / close box). */
static void wm_button_toggle(void)
{
    if (!g_wm_up) return;
    g_mbtn = !g_mbtn;
    s_cvis = 0;
    gem_wm_mouse_button(&g_wm, g_mx, g_my, g_mbtn);
    gem_wm_draw(&g_wm);
    desk_flush();
    cur_show(g_mx, g_my);
}

/* Re-sync + redraw the cursor (mode entry) and drop any held button (mode exit). */
void gem_mouse_reset(void)
{
    g_esc = 0; g_escn = 0;
    if (!g_wm_up) return;
    if (g_mbtn) { gem_wm_mouse_button(&g_wm, g_mx, g_my, 0); g_mbtn = 0; }
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
