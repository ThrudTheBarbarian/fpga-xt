// wm_test.c — headless sanity for the WM interaction layer (no SDL):
// stacking order, hit classification, raise/focus, drag-move, resize, close.

#include "gem.h"
#include <stdio.h>

static int fails = 0;
#define CHECK(cond) do { if (!(cond)) { \
    printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); fails++; } } while (0)

int main(void) {
    gfx_surface *desk = gfx_surface_alloc(1000, 800);
    gem_wm wm;
    gem_wm_init(&wm, desk, GFX_RGB(0x20, 0x80, 0x84));

    // A: 100,100,300x200 ; B: 450,300,300x200 (disjoint).
    gem_window *A = gem_wm_add(&wm, 100, 100, 300, 200, "A", 1);
    gem_window *B = gem_wm_add(&wm, 450, 300, 300, 200, "B", 0);
    CHECK(A && B);
    CHECK(wm.nwin == 2);
    CHECK(gem_wm_top(&wm) == B);                 // last added is on top

    // Content rect of A: cx=102 cy=132 cw=296 ch=166.
    CHECK(A->cx == 102 && A->cy == 132 && A->cw == 296 && A->ch == 166);

    // Hit classification on A.
    CHECK(gem_wm_hit(A, 200, 115) == GEM_HIT_TITLE);    // title strip
    CHECK(gem_wm_hit(A, 115, 116) == GEM_HIT_CLOSE);    // close box
    CHECK(gem_wm_hit(A, 200, 200) == GEM_HIT_CONTENT);  // body
    CHECK(gem_wm_hit(A, 392, 292) == GEM_HIT_RESIZE);   // bottom-right grip
    CHECK(gem_wm_hit(A,  50,  50) == GEM_HIT_NONE);     // outside

    CHECK(gem_wm_window_at(&wm, 200, 200) == A);        // only A there
    CHECK(gem_wm_window_at(&wm, 500, 400) == B);
    CHECK(gem_wm_window_at(&wm,  10,  10) == NULL);

    // Raise A to the front, focus follows.
    gem_wm_raise(&wm, A);
    CHECK(gem_wm_top(&wm) == A);
    gem_wm_focus(&wm, A);
    CHECK(A->active == 1 && B->active == 0);

    // Drag-move A by the title bar: press (200,115) -> move (+60,+25) -> release.
    gem_wm_mouse_button(&wm, 200, 115, 1);
    CHECK(A->active == 1);                              // press focuses A
    gem_wm_mouse_move(&wm, 260, 140);
    CHECK(A->x == 160 && A->y == 125);                 // moved by the same delta
    CHECK(A->cx == 162 && A->cy == 157);               // content followed
    gem_wm_mouse_button(&wm, 260, 140, 0);
    gem_wm_mouse_move(&wm, 400, 400);                  // no drag after release
    CHECK(A->x == 160 && A->y == 125);

    // Resize A from the corner: grab bottom-right, drag in by (-40,-30).
    int rx = A->x + A->w - 4, ry = A->y + A->h - 4;     // inside the grip
    CHECK(gem_wm_hit(A, rx, ry) == GEM_HIT_RESIZE);
    gem_wm_mouse_button(&wm, rx, ry, 1);
    gem_wm_mouse_move(&wm, rx - 40, ry - 30);
    CHECK(A->w == 260 && A->h == 170);                 // shrunk by the delta
    CHECK(A->cw == 256 && A->ch == 136);               // content recomputed
    gem_wm_mouse_button(&wm, rx - 40, ry - 30, 0);

    // Min-size clamp: try to collapse B far past the minimum.
    gem_wm_resize(&wm, B, 1, 1);
    CHECK(B->w == 120 && B->h == 80);

    // Close A via its close box; B becomes the focused top window.
    int cx = A->x + 2 + 7 + 1, cy = A->y + 2 + 8 + 1;   // inside A's close box
    CHECK(gem_wm_hit(A, cx, cy) == GEM_HIT_CLOSE);
    gem_wm_mouse_button(&wm, cx, cy, 1);
    CHECK(wm.nwin == 1);
    CHECK(gem_wm_top(&wm) == B);
    CHECK(B->active == 1);

    gfx_surface_free(desk);
    if (fails == 0) printf("*** WM TEST OK ***\n");
    else            printf("*** WM TEST: %d FAIL(s) ***\n", fails);
    return fails ? 1 : 0;
}
