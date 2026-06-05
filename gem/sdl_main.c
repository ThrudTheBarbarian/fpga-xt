// sdl_main.c — host testbed for the portable GEM core.
//
// SDL owns only the window + the final texture upload.  Everything on the
// desktop is produced by the portable GEM window manager (wm.c) through the
// gfx.h primitives, so it will run unchanged on the A9 hardware-blitter backend.
//
// Build:  make -C gem        Run:  make -C gem run        Quit: ESC / close.

#include "gem.h"
#include <SDL2/SDL.h>
#include <stdio.h>

// Target raster (matches the FPGA HDMI output); the window scales to fit.
#define SCREEN_W 1920
#define SCREEN_H 1080

#define COL_DESKTOP  GFX_RGB(0x20, 0x80, 0x84)   // muted teal
#define COL_XL_BG    GFX_RGB(0x10, 0x18, 0x60)   // placeholder for the live XL plane

// The real compositor XL-plane rect (origin 480,252, size 960x576): milestone-1
// target is to frame exactly this with a window's content area.
#define XL_X 480
#define XL_Y 252
#define XL_W 960
#define XL_H 576
#define TITLE_H 30
#define EDGE    2

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window   *win = SDL_CreateWindow("XTOS / GEM testbed",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        1280, 720, SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_RenderSetLogicalSize(ren, SCREEN_W, SCREEN_H);   // scale 1080p -> window
    SDL_Texture  *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING, SCREEN_W, SCREEN_H);

    gfx_surface *desk = gfx_surface_alloc(SCREEN_W, SCREEN_H);
    if (!win || !ren || !tex || !desk) {
        fprintf(stderr, "SDL/surface init failed: %s\n", SDL_GetError());
        return 1;
    }

    // Build the desktop: an XL window whose content area lands on the real XL
    // plane rect, plus a second window to show stacking.
    gem_wm wm;
    gem_wm_init(&wm, desk, COL_DESKTOP);
    gem_window *xlwin = gem_wm_add(&wm,
        XL_X - EDGE, XL_Y - EDGE - TITLE_H,
        XL_W + 2 * EDGE, XL_H + 2 * EDGE + TITLE_H, "Atari XL", 1);
    gem_wm_add(&wm, 1150, 120, 520, 340, "Info", 0);

    int running = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) running = 0;
        }

        gem_wm_draw(&wm);                                  // portable: desktop + frames
        // Stand-in for the live XL plane drawn into the XL window's content rect.
        if (xlwin) {
            gfx_fill_rect(desk, xlwin->cx, xlwin->cy, xlwin->cw, xlwin->ch, COL_XL_BG);
            gfx_line(desk, xlwin->cx, xlwin->cy,
                     xlwin->cx + xlwin->cw - 1, xlwin->cy + xlwin->ch - 1,
                     GFX_RGB(0x30, 0x90, 0xff));
            gfx_line(desk, xlwin->cx + xlwin->cw - 1, xlwin->cy,
                     xlwin->cx, xlwin->cy + xlwin->ch - 1, GFX_RGB(0x30, 0x90, 0xff));
        }

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
