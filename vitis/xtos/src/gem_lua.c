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

void gem_lua_open(lua_State *L)
{
    static const luaL_Reg vdi_lib[] = {
        {"text",      l_vdi_text},
        {"point",     l_vdi_point},
        {"color",     l_vdi_color},
        {"fillcolor", l_vdi_fillcolor},
        {"bar",       l_vdi_bar},
        {"clear",     l_vdi_clear},
        {"flush",     l_vdi_flush},
        {"font",      l_vdi_font},
        {NULL, NULL}
    };
    luaL_newlib(L, vdi_lib);
    lua_setglobal(L, "vdi");
}
