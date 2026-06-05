// sdl_main.c — host testbed for the portable GEM core.
//
// SDL owns only the window + the final texture upload.  The desktop, window
// frames and window content are all produced by the portable GEM core (wm.c +
// vdi.c) through the gfx.h primitives, so it runs unchanged on the A9 backend.
// Window content is drawn in LOCAL coordinates into each window's backing
// surface on a redraw, then composited by the WM with vro_cpyfm.
//
// Build:  make -C gem        Run:  make -C gem run        Quit: ESC / close.

#include "gem.h"
#include "vdi/vdi.h"
#include <SDL2/SDL.h>
#include <stdio.h>

// Target raster (matches the FPGA HDMI output); the window scales to fit.
#define SCREEN_W 1920
#define SCREEN_H 1080
#define COL_DESKTOP  GFX_RGB(0x20, 0x80, 0x84)   // muted teal

// The real compositor XL-plane rect (origin 480,252, size 960x576): milestone-1
// target is to frame exactly this with a window's content area.
#define XL_X 480
#define XL_Y 252
#define XL_W 960
#define XL_H 576
#define TITLE_H 30
#define EDGE    2

// Stand-in for the live XL plane: a blue field with cyan diagonals, drawn into
// the window's backing surface in local coords via its VDI workstation.
static void xl_redraw(gem_window *w, void *ud) {
    (void)ud;
    int16_t full[4] = { 0, 0, (int16_t)(w->cw - 1), (int16_t)(w->ch - 1) };
    vsf_color(w->vh, 4); vsf_interior(w->vh, 1); vr_recfl(w->vh, full);
    vsl_color(w->vh, 5);
    int16_t d1[4] = { 0, 0, (int16_t)(w->cw - 1), (int16_t)(w->ch - 1) };
    int16_t d2[4] = { (int16_t)(w->cw - 1), 0, 0, (int16_t)(w->ch - 1) };
    v_pline(w->vh, 2, d1); v_pline(w->vh, 2, d2);
}

// A demo "app": colour bars + a polyline.  Bars/lines overrun the content and
// are clipped to the backing surface (the content rect) — no bleed.
static void app_redraw(gem_window *w, void *ud) {
    (void)ud;
    int16_t full[4] = { 0, 0, (int16_t)(w->cw - 1), (int16_t)(w->ch - 1) };
    vsf_color(w->vh, 0); vsf_interior(w->vh, 1); vr_recfl(w->vh, full);
    for (int i = 0; i < 6; i++) {
        int16_t b[4] = { (int16_t)(20 + i*60), 20,
                         (int16_t)(60 + i*60), (int16_t)(w->ch + 40) };
        vsf_color(w->vh, 2 + i); v_bar(w->vh, b);
    }
    int16_t poly[8] = { -30, 200, (int16_t)(w->cw/3), 60,
                        (int16_t)(2*w->cw/3), 260, (int16_t)(w->cw + 30), 100 };
    vsl_color(w->vh, 1); v_pline(w->vh, 4, poly);
}

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

    gem_wm wm;
    gem_wm_init(&wm, desk, COL_DESKTOP);                 // brings up the VDI on desk
    gem_window *xlwin = gem_wm_add(&wm,
        XL_X - EDGE, XL_Y - EDGE - TITLE_H,
        XL_W + 2 * EDGE, XL_H + 2 * EDGE + TITLE_H, "Atari XL", 1);
    gem_window *info  = gem_wm_add(&wm, 1150, 120, 520, 340, "Info", 0);
    if (xlwin) gem_wm_set_redraw(xlwin, xl_redraw, NULL);
    if (info)  gem_wm_set_redraw(info,  app_redraw, NULL);

    SDL_ShowCursor(SDL_DISABLE);           // the WM draws its own pointer

    int running = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) running = 0;
            else if (e.type == SDL_MOUSEMOTION) {
                float lx, ly;
                SDL_RenderWindowToLogical(ren, e.motion.x, e.motion.y, &lx, &ly);
                gem_wm_mouse_move(&wm, (int)lx, (int)ly);
            } else if (e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP) {
                if (e.button.button == SDL_BUTTON_LEFT) {
                    float lx, ly;
                    SDL_RenderWindowToLogical(ren, e.button.x, e.button.y, &lx, &ly);
                    gem_wm_mouse_button(&wm, (int)lx, (int)ly,
                                        e.type == SDL_MOUSEBUTTONDOWN);
                }
            }
        }
        gem_wm_draw(&wm);                  // redraw dirty content + frames + composite
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
