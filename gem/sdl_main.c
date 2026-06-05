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

// The desktop surface is rendered 1:1 with the window's device pixels and
// presented without any rescale, so text and 1px frame lines stay crisp.  (The
// FPGA target is 1920x1080; on a sub-1080p / non-Retina dev screen a 1:1 1080p
// surface would have to be bilinearly shrunk to fit — which softens every edge.
// So the testbed renders at a fit-to-screen size instead; the GEM core is
// resolution-independent, and the real 1080p look is best judged on the HDMI
// output itself.)
#define WIN_W 1280
#define WIN_H 720
#define COL_DESKTOP  GFX_RGB(0x20, 0x80, 0x84)   // muted teal

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

// A demo "app": colour bars, a polyline, and a line of graphic text.  Bars/
// lines/text overrun the content and are clipped to the backing surface.
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
    vst_color(w->vh, 0);                          // white text
    vst_point(w->vh, 22, NULL, NULL, NULL, NULL); // bigger via vst_point
    v_gtext(w->vh, 16, 12, "GEM / VDI text");
    vst_height(w->vh, 13, NULL, NULL, NULL, NULL);// smaller via vst_height
    v_gtext(w->vh, 16, 40, "AovelSansRounded, sized by the workstation");
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }
    SDL_Window   *win = SDL_CreateWindow("XTOS / GEM testbed",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        WIN_W, WIN_H, SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    // No logical-size rescale: the texture is the same size as the desktop and
    // is blitted 1:1 (centred if the window is resized), so nothing resamples.
    SDL_Texture  *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING, WIN_W, WIN_H);

    gfx_surface *desk = gfx_surface_alloc(WIN_W, WIN_H);
    if (!win || !ren || !tex || !desk) {
        fprintf(stderr, "SDL/surface init failed: %s\n", SDL_GetError());
        return 1;
    }

    gem_wm wm;
    gem_wm_init(&wm, desk, COL_DESKTOP);                 // brings up the VDI on desk
    font_face *uiface = font_face_open("fonts/AovelSansRounded.ttf");
    if (!uiface) fprintf(stderr, "warning: title font failed to load\n");
    if (uiface) font_face_set_tracking(uiface, 1);       // this face is cut tight
    gem_wm_set_font(&wm, uiface);                         // titles + VDI default text

    // "Atari XL" content is 4:3 (512x384); outer adds 2px edge + 30px title bar.
    gem_window *xlwin = gem_wm_add(&wm,  60,  70, 516, 418, "Atari XL", 1);
    gem_window *info  = gem_wm_add(&wm, 770,  60, 450, 320, "Info", 0);
    if (xlwin) gem_wm_set_redraw(xlwin, xl_redraw, NULL);
    if (info)  gem_wm_set_redraw(info,  app_redraw, NULL);

    SDL_ShowCursor(SDL_DISABLE);           // the WM draws its own pointer

    // The 1:1 desktop is centred in the (possibly resized) window; this is the
    // top-left offset, kept in sync so mouse coords map straight to desktop px.
    int off_x = 0, off_y = 0;

    int running = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) running = 0;
            else if (e.type == SDL_MOUSEMOTION)
                gem_wm_mouse_move(&wm, e.motion.x - off_x, e.motion.y - off_y);
            else if ((e.type == SDL_MOUSEBUTTONDOWN || e.type == SDL_MOUSEBUTTONUP)
                     && e.button.button == SDL_BUTTON_LEFT)
                gem_wm_mouse_button(&wm, e.button.x - off_x, e.button.y - off_y,
                                    e.type == SDL_MOUSEBUTTONDOWN);
        }
        gem_wm_draw(&wm);                  // redraw dirty content + frames + composite
        SDL_UpdateTexture(tex, NULL, desk->px, desk->stride * (int)sizeof(uint32_t));

        int ow = WIN_W, oh = WIN_H;
        SDL_GetRendererOutputSize(ren, &ow, &oh);
        off_x = (ow - WIN_W) / 2; off_y = (oh - WIN_H) / 2;
        SDL_Rect dst = { off_x, off_y, WIN_W, WIN_H };   // 1:1, centred
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, &dst);
        SDL_RenderPresent(ren);
        SDL_Delay(16);
    }

    if (uiface) font_face_close(uiface);
    gfx_surface_free(desk);
    SDL_DestroyTexture(tex);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
