// menu_test.c — headless self-test for the AES popup-menu primitive (menu_popup
// and its factored geometry/hit-test/navigation helpers in aes/menu.c).  No SDL:
// it sets up a software VDI + AES + theme exactly like aes_menu_demo's --ppm
// path, then (a) unit-tests the pure helpers (layout, hit-test, keyboard nav,
// mnemonics, separator/disabled skipping, submenu resolution) and (b) renders
// one open popup + its cascade to /tmp/xtdesk-menu.ppm for visual confirmation.
//
// It deliberately does NOT drive the modal loop (which needs a live event
// source); the loop's decisions are all made by the helpers this test exercises
// directly, plus a static rendered frame.

#include "aes/aes_internal.h"
#include "font.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

gfx_surface *vdi_screen_target(void);   // the physical workstation surface (VDI core)

#define WIN_W 560
#define WIN_H 360

static int g_fail;
#define CHECK(cond, msg) do { if (!(cond)) { \
    printf("FAIL: %s  (%s:%d)\n", (msg), __FILE__, __LINE__); g_fail++; } \
    else printf("ok:   %s\n", (msg)); } while (0)

// A submenu (Show ▸) plus a top-level popup exercising every row kind.
static const menu_item show_sub[] = {
    { "Icons",        NULL, 201, NULL, 0, 0 },
    { "List",         NULL, 202, NULL, 0, MI_CHECKED },
    { "Columns",      NULL, 203, NULL, 0, 0 },
};
static const menu_item ctx[] = {
    { "Open",         "^O",           101, NULL, 0, 0 },              // accel, right-aligned
    { "Open With…",   NULL,           102, NULL, 0, 0 },
    { "-",            NULL,           0,   NULL, 0, 0 },              // separator
    { "Cut",          "^X",           103, NULL, 0, 0 },
    { "Copy",         "^C",           104, NULL, 0, 0 },
    { "Paste",        "^V",           105, NULL, 0, MI_DISABLED },   // disabled
    { "-",            NULL,           0,   NULL, 0, 0 },
    { "Show",         NULL,           0,   show_sub, 3, 0 },         // submenu
    { "Get Info",     "^I",           107, NULL, 0, 0 },
};
#define NCTX ((int)(sizeof ctx / sizeof ctx[0]))

static void unit_tests(void) {
    printf("--- geometry / hit-test / nav -------------------------\n");
    popup_geom g;
    menu_popup_layout(ctx, NCTX, 40, 40, &g);
    CHECK(g.w > 0 && g.h > 0, "layout produces a positive box");
    CHECK(g.n == NCTX, "layout records the item count");

    // Clamp: a popup placed off the right/bottom edge shifts fully on-screen.
    popup_geom gc;
    menu_popup_layout(ctx, NCTX, WIN_W - 4, WIN_H - 4, &gc);
    CHECK(gc.x + gc.w <= WIN_W && gc.y + gc.h <= WIN_H, "off-edge popup clamps on-screen");
    CHECK(gc.x >= 0 && gc.y >= 0, "clamped popup stays non-negative");

    // Hit-test: a point in the first row resolves to row 0; the separator row
    // (index 2) and the disabled row (index 5) resolve to -1 (non-selectable).
    int r0 = menu_popup_hit(&g, ctx, g.x + 10, g.y + g.pady + g.rowh/2);
    CHECK(r0 == 0, "hit-test maps a point in row 0 to item 0");

    // Compute the y-centre of a given row to probe it.
    #define ROW_CY(row) ({ int ty = g.y + g.pady; \
        for (int i = 0; i < (row); i++) ty += (ctx[i].label[0]=='-'&&!ctx[i].label[1]) ? g.seph : g.rowh; \
        ty + ((ctx[row].label[0]=='-'&&!ctx[row].label[1]) ? g.seph : g.rowh)/2; })
    CHECK(menu_popup_hit(&g, ctx, g.x + 10, ROW_CY(2)) == -1, "separator row is non-selectable");
    CHECK(menu_popup_hit(&g, ctx, g.x + 10, ROW_CY(5)) == -1, "disabled row (Paste) is non-selectable");
    CHECK(menu_popup_hit(&g, ctx, g.x + 10, ROW_CY(7)) == 7, "submenu row (Show) is selectable");
    CHECK(menu_popup_hit(&g, ctx, g.x - 5, ROW_CY(0)) == -1, "point left of the box misses");

    printf("--- keyboard navigation -------------------------------\n");
    // Down from the top lands on row 0; nav skips the separator + disabled rows.
    int n0 = menu_popup_nav(ctx, NCTX, -1, 1);
    CHECK(n0 == 0, "nav down from edge selects first item");
    int n1 = menu_popup_nav(ctx, NCTX, 1, 1);   // from "Open With…" (1) -> skip sep -> Cut (3)
    CHECK(n1 == 3, "nav down skips a separator (1 -> 3)");
    int n2 = menu_popup_nav(ctx, NCTX, 4, 1);   // from Copy(4) -> Paste(5) disabled -> skip -> sep(6) skip -> Show(7)
    CHECK(n2 == 7, "nav down skips a disabled item (Copy -> Show)");
    int nup = menu_popup_nav(ctx, NCTX, 3, -1); // from Cut(3) up -> skip sep(2) -> Open With…(1)
    CHECK(nup == 1, "nav up skips a separator (3 -> 1)");
    int nwrap = menu_popup_nav(ctx, NCTX, NCTX-1, 1);
    CHECK(nwrap == 0, "nav down wraps to the top");

    printf("--- mnemonics -----------------------------------------\n");
    // Auto-assigned first-letter mnemonics: O(pen), then Open With… collides on
    // 'o' so gets 'p'(?) — just assert the ones that must hold.
    int mo = menu_popup_mnemonic(ctx, NCTX, 'o');
    CHECK(mo == 0, "mnemonic 'o' selects Open");
    int mc = menu_popup_mnemonic(ctx, NCTX, 'c');
    CHECK(mc == 3, "mnemonic 'c' selects Cut");
    int mg = menu_popup_mnemonic(ctx, NCTX, 'g');
    CHECK(mg == 8, "mnemonic 'g' selects Get Info");
    int mz = menu_popup_mnemonic(ctx, NCTX, 'z');
    CHECK(mz == -1, "unknown mnemonic returns -1");

    printf("--- submenu resolution --------------------------------\n");
    CHECK(ctx[7].sub == show_sub && ctx[7].nsub == 3, "Show row carries its submenu");
    // The cascade's own nav/hit works too.
    int sfirst = menu_popup_nav(show_sub, 3, -1, 1);
    CHECK(sfirst == 0, "submenu nav selects its first item");
    CHECK(show_sub[1].flags & MI_CHECKED, "submenu 'List' is checked");
}

// Render one open popup + its Show▸ cascade as a static frame, mirroring what
// the modal loop draws (draw_popup + save-under), and dump it to a PPM.
static void render_frame(int HV) {
    // desktop backdrop
    gfx_surface *d = vdi_screen_target();
    for (int i = 0; i < d->w * d->h; i++) d->px[i] = GFX_RGB(64, 86, 114);
    vst_color(HV, 0); vst_height(HV, 15, 0,0,0,0);
    v_gtext(HV, 20, 24, "menu_popup — context menu with a cascading submenu");

    // Drive the (public) drawing helpers the way menu_popup does, but statically:
    // lay out the top popup, then its Show cascade to the right, and draw both
    // with a hovered row in each so the highlight + triangle are visible.
    popup_geom top; menu_popup_layout(ctx, NCTX, 60, 60, &top);
    popup_geom sub; menu_popup_layout(show_sub, 3, top.x + top.w - 2, top.y, &sub);

    // menu_popup itself owns draw_popup (static); reproduce an open frame by
    // running the loop's first paint through the public entry is not possible
    // headlessly, so we render via a tiny shim exported for the test:
    menu_popup_render_demo(ctx, NCTX, 7, &top);        // top popup, "Show" hovered
    menu_popup_render_demo(show_sub, 3, 0, &sub);      // cascade, "Icons" hovered

    FILE *f = fopen("/tmp/xtdesk-menu.ppm", "wb");
    if (!f) { perror("fopen"); return; }
    fprintf(f, "P6\n%d %d\n255\n", WIN_W, WIN_H);
    for (int i = 0; i < WIN_W * WIN_H; i++) {
        uint32_t v = d->px[i];
        unsigned char c[3] = { (unsigned char)(v>>24), (unsigned char)(v>>16), (unsigned char)(v>>8) };
        fwrite(c, 1, 3, f);
    }
    fclose(f);
    printf("\nwrote /tmp/xtdesk-menu.ppm (%dx%d)\n", WIN_W, WIN_H);
}

int main(void) {
    gfx_surface *desk = gfx_surface_alloc(WIN_W, WIN_H);
    vdi_init(desk);
    int HV = v_opnvwk(desk);
    font_face *ff = font_face_open("fonts/AovelSansRounded.ttf");
    if (ff) font_face_set_tracking(ff, 1);
    vdi_set_face(ff);
    static theme TH;
    if (theme_load(&TH, "themes/Aristo2/1x")) {
        fprintf(stderr, "theme load failed (run: make -C gem themepack)\n");
        return 1;
    }
    aes_init(HV, &TH);
    appl_init();

    printf("=== menu_popup helper unit tests ======================\n");
    unit_tests();
    render_frame(HV);

    printf("\n%s\n", g_fail ? "SOME TESTS FAILED" : "ALL TESTS PASSED");
    theme_free(&TH); if (ff) font_face_close(ff); gfx_surface_free(desk);
    return g_fail ? 1 : 0;
}
