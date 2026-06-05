// sdl_main.c — host testbed for the portable GEM core.
//
// SDL owns only the window + the final texture upload.  Everything on the
// desktop is produced by the portable GEM window manager (wm.c) through the
// gfx.h primitives, so it will run unchanged on the A9 hardware-blitter backend.
//
// Build:  make -C gem        Run:  make -C gem run        Quit: ESC / close.

#include "gem.h"
#include "vdi.h"
#include <SDL2/SDL.h>
#include <stdio.h>

// Target raster (matches the FPGA HDMI output); the window scales to fit.
#define SCREEN_W 1920
#define SCREEN_H 1080

#define COL_DESKTOP  GFX_RGB(0x20, 0x80, 0x84)   // muted teal

// Draw a window's content through the VDI, clipped to its content rect.  Lines
// and bars deliberately overrun the rect to show the clip holds (no bleed onto
// the frame/desktop).  `xl` selects the XL-plane stand-in vs a demo "app".
static void draw_content(int vh, const gem_window *win, int xl) {
    int16_t clip[4] = { (int16_t)win->cx, (int16_t)win->cy,
                        (int16_t)(win->cx + win->cw - 1), (int16_t)(win->cy + win->ch - 1) };
    vs_clip(vh, 1, clip);
    if (xl) {
        vsf_color(vh, 4); vsf_interior(vh, 1);          // blue fill = XL stand-in
        vr_recfl(vh, clip);
        vsl_color(vh, 5);                               // cyan diagonals
        int16_t d1[4] = { clip[0], clip[1], clip[2], clip[3] };
        int16_t d2[4] = { clip[2], clip[1], clip[0], clip[3] };
        v_pline(vh, 2, d1); v_pline(vh, 2, d2);
    } else {
        vsf_color(vh, 0); vsf_interior(vh, 1);          // white paper
        vr_recfl(vh, clip);
        for (int i = 0; i < 6; i++) {                   // colour bars (clipped at edge)
            int16_t b[4] = { (int16_t)(win->cx + 20 + i*60), (int16_t)(win->cy + 20),
                             (int16_t)(win->cx + 60 + i*60), (int16_t)(win->cy + win->ch + 40) };
            vsf_color(vh, 2 + i); v_bar(vh, b);
        }
        int16_t poly[8] = { (int16_t)(win->cx - 30),            (int16_t)(win->cy + 200),
                            (int16_t)(win->cx + win->cw/3),     (int16_t)(win->cy + 60),
                            (int16_t)(win->cx + 2*win->cw/3),   (int16_t)(win->cy + 260),
                            (int16_t)(win->cx + win->cw + 30),  (int16_t)(win->cy + 100) };
        vsl_color(vh, 1); v_pline(vh, 4, poly);
    }
    vs_clip(vh, 0, clip);
}

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
    gem_window *info = gem_wm_add(&wm, 1150, 120, 520, 340, "Info", 0);

    vdi_init(desk);                 // pen palette + physical workstation on desk
    int vh = v_opnvwk(desk);        // a virtual workstation for the demo content

    int running = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) running = 0;
        }

        gem_wm_draw(&wm);                  // portable: desktop + window frames
        if (xlwin) draw_content(vh, xlwin, 1);   // XL plane stand-in, via VDI
        if (info)  draw_content(vh, info, 0);    // demo "app" content, via VDI

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
