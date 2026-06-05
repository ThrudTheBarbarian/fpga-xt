// sdl_main.c — host testbed for the portable GEM core.
//
// Opens an SDL window, builds an RGBA-8888 desktop surface entirely through the
// gfx.h primitives (software backend, gfx_soft.c), and presents it.  This is
// the iterate-fast harness: everything drawn here is portable C that will move
// into the GEM core / window manager and run unchanged on the A9 (hardware
// blitter backend).  No SDL drawing calls — SDL only owns the window + the
// final texture upload.
//
// Build:  make -C gem        Run:  ./gem/build/gem_sdl     Quit: ESC / close.

#include "gfx.h"
#include <SDL2/SDL.h>
#include <stdio.h>

// Target raster (matches the FPGA HDMI output); the window scales to fit.
#define SCREEN_W 1920
#define SCREEN_H 1080

// Provisional palette (will become the themed pen table).
#define COL_DESKTOP    GFX_RGB(0x20, 0x80, 0x84)   // muted teal
#define COL_WIN_BODY   GFX_RGB(0xc8, 0xc8, 0xc8)
#define COL_WIN_EDGE   GFX_RGB(0x20, 0x20, 0x20)
#define COL_TITLE_ACT  GFX_RGB(0x28, 0x5a, 0xc0)   // active title bar
#define COL_TITLE_TXT  GFX_RGB(0xff, 0xff, 0xff)
#define COL_XL_BG      GFX_RGB(0x10, 0x18, 0x60)   // placeholder for the live XL plane

#define TITLE_H 30
#define EDGE    2

// Draw a GEM-ish window: outer edge, title bar, body.  Returns the content
// rect (where an app — or the live XL plane — would draw) via *cx/*cy/*cw/*ch.
static void draw_window(gfx_surface *s, int x, int y, int w, int h, int active,
                        int *cx, int *cy, int *cw, int *ch) {
    gfx_fill_rect(s, x, y, w, h, COL_WIN_EDGE);                       // outer edge
    gfx_fill_rect(s, x + EDGE, y + EDGE, w - 2*EDGE, TITLE_H,         // title bar
                  active ? COL_TITLE_ACT : COL_WIN_EDGE);
    int by = y + EDGE + TITLE_H;
    int bh = h - 2*EDGE - TITLE_H;
    gfx_fill_rect(s, x + EDGE, by, w - 2*EDGE, bh, COL_WIN_BODY);     // body
    // crude "close box" on the left of the title bar (themed art comes later)
    gfx_fill_rect(s, x + EDGE + 6, y + EDGE + 7, TITLE_H - 14, TITLE_H - 14, COL_WIN_BODY);
    (void)COL_TITLE_TXT;
    if (cx) *cx = x + EDGE;
    if (cy) *cy = by;
    if (cw) *cw = w - 2*EDGE;
    if (ch) *ch = bh;
}

static void draw_desktop(gfx_surface *s) {
    gfx_fill_rect(s, 0, 0, s->w, s->h, COL_DESKTOP);

    // The XL window, positioned so its content rect lands on the real compositor
    // XL plane (origin 480,252, size 960x576) — milestone 1's static target.
    int cx, cy, cw, ch;
    draw_window(s, 478, 252 - EDGE - TITLE_H, 964, 576 + 2*EDGE + TITLE_H, 1,
                &cx, &cy, &cw, &ch);
    gfx_fill_rect(s, cx, cy, cw, ch, COL_XL_BG);                      // XL placeholder
    gfx_line(s, cx, cy, cx + cw - 1, cy + ch - 1, GFX_RGB(0x30, 0x90, 0xff));
    gfx_line(s, cx + cw - 1, cy, cx, cy + ch - 1, GFX_RGB(0x30, 0x90, 0xff));

    // A second, inactive window to prove overlap/stacking.
    draw_window(s, 1150, 120, 520, 340, 0, NULL, NULL, NULL, NULL);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window *win = SDL_CreateWindow("XTOS / GEM testbed",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        1280, 720, SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_RenderSetLogicalSize(ren, SCREEN_W, SCREEN_H);   // scale 1080p -> window
    SDL_Texture *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING, SCREEN_W, SCREEN_H);

    gfx_surface *desk = gfx_surface_alloc(SCREEN_W, SCREEN_H);
    if (!win || !ren || !tex || !desk) {
        fprintf(stderr, "SDL/surface init failed: %s\n", SDL_GetError());
        return 1;
    }

    int running = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) running = 0;
        }
        draw_desktop(desk);   // redraw whole surface for now (WM expose comes later)
        SDL_UpdateTexture(tex, NULL, desk->px, desk->stride * (int)sizeof(uint32_t));
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, NULL);
        SDL_RenderPresent(ren);
        SDL_Delay(16);
    }

    gfx_surface_free(desk);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
