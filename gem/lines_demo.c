// lines_demo.c — the VDI line attributes: vsl_type (6 dash styles), vsl_width
// (1..8), vsl_ends (square / arrow / round), vsl_color, and a rotating colour
// burst that sweeps every angle while varying width / style / end / hue at once.
// Presented 1:1 (see sdl_main.c).  SPACE pauses, ESC quits.
//
//   make -C gem lines

#include "vdi/vdi.h"
#include "font.h"
#include <SDL2/SDL.h>
#include <stdio.h>
#include <math.h>

#define WIN_W 1280
#define WIN_H 720
#define COL_BG GFX_RGB(0x14, 0x18, 0x1e)   // near-black
#define VH 1
#define NSPOKE 18

static void label(int x, int y, const char *s, int pen, int px, int halign) {
    vst_color(VH, pen); vst_height(VH, px, NULL, NULL, NULL, NULL);
    vst_alignment(VH, halign, VDI_TA_HALF, NULL, NULL);
    v_gtext(VH, x, y, s);
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
}
static void line(int x0, int y0, int x1, int y1) {
    int16_t l[4] = { (int16_t)x0, (int16_t)y0, (int16_t)x1, (int16_t)y1 };
    v_pline(VH, 2, l);
}

static void hue_rgb(double h, int16_t out[3]) {        // h in [0,360)
    double x = 1.0 - fabs(fmod(h / 60.0, 2.0) - 1.0), r, g, b;
    if      (h <  60) { r = 1; g = x; b = 0; }
    else if (h < 120) { r = x; g = 1; b = 0; }
    else if (h < 180) { r = 0; g = 1; b = x; }
    else if (h < 240) { r = 0; g = x; b = 1; }
    else if (h < 300) { r = x; g = 0; b = 1; }
    else              { r = 1; g = 0; b = x; }
    out[0] = (int16_t)(r * 1000); out[1] = (int16_t)(g * 1000); out[2] = (int16_t)(b * 1000);
}

static void draw(gfx_surface *desk, int spin) {
    vdi_init(desk);
    gfx_fill_rect(desk, 0, 0, WIN_W, WIN_H, COL_BG);
    char buf[16];

    label(WIN_W/2, 18, "GEM VDI lines — styles, widths, ends, colours, angles", 0, 22, VDI_TA_CENTER);

    // --- vsl_type ---
    label(40, 64, "vsl_type", 0, 15, VDI_TA_LEFT);
    const char *tn[6] = { "solid", "long dash", "dotted", "dash-dot", "dashed", "dash-dot-dot" };
    vsl_color(VH, 0); vsl_width(VH, 2); vsl_ends(VH, VDI_LE_SQUARE, VDI_LE_SQUARE);
    for (int t = 1; t <= 6; t++) {
        int y = 90 + (t-1) * 26;
        label(36, y, tn[t-1], 8, 12, VDI_TA_LEFT);
        vsl_type(VH, t); line(180, y, 560, y);
    }

    // --- vsl_width ---
    label(40, 270, "vsl_width", 0, 15, VDI_TA_LEFT);
    vsl_type(VH, 1);
    for (int w = 1; w <= 8; w++) {
        int y = 296 + (w-1) * 22;
        snprintf(buf, sizeof buf, "%d px", w);
        label(36, y, buf, 8, 12, VDI_TA_LEFT);
        vsl_width(VH, w); line(180, y, 560, y);
    }

    // --- vsl_ends ---
    label(40, 494, "vsl_ends", 0, 15, VDI_TA_LEFT);
    struct { int b, e; const char *n; } es[3] = {
        { VDI_LE_SQUARE, VDI_LE_SQUARE, "square" },
        { VDI_LE_ARROW,  VDI_LE_ARROW,  "double arrow" },
        { VDI_LE_ROUND,  VDI_LE_ARROW,  "round / arrow" } };
    vsl_width(VH, 7);
    for (int i = 0; i < 3; i++) {
        int y = 524 + i * 46;
        label(36, y, es[i].n, 8, 12, VDI_TA_LEFT);
        vsl_ends(VH, es[i].b, es[i].e); line(200, y, 540, y);
    }

    // --- rotating colour burst: every angle, varied width/style/end/hue ---
    label(920, 60, "vsl_color · all angles · varied width / type / end", 0, 14, VDI_TA_CENTER);
    int cx = 920, cy = 400;
    for (int i = 0; i < NSPOKE; i++) {
        int16_t rgb[3]; hue_rgb(i * 360.0 / NSPOKE, rgb);
        vs_color(VH, 100 + i, rgb);
        vsl_color(VH, 100 + i);
        vsl_width(VH, 1 + (i % 6));
        vsl_type(VH, 1 + (i % 6));
        vsl_ends(VH, VDI_LE_ROUND, (i & 1) ? VDI_LE_ARROW : VDI_LE_ROUND);
        double th = (spin / 10.0 + i * 360.0 / NSPOKE) * (M_PI / 180.0);
        double L = 150 + (i % 5) * 30;
        line(cx, cy, (int)lround(cx + L * cos(th)), (int)lround(cy - L * sin(th)));
    }
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
    SDL_Window   *win = SDL_CreateWindow("GEM VDI lines demo",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIN_W, WIN_H, SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture  *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING, WIN_W, WIN_H);
    gfx_surface *desk = gfx_surface_alloc(WIN_W, WIN_H);
    if (!win || !ren || !tex || !desk) { fprintf(stderr, "init failed\n"); return 1; }

    vdi_init(desk);
    font_face *face = font_face_open("fonts/AovelSansRounded.ttf");
    if (face) font_face_set_tracking(face, 1);
    vdi_set_face(face);

    int spin = 0, running = 1, paused = 0;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN) {
                if (e.key.keysym.sym == SDLK_ESCAPE) running = 0;
                else if (e.key.keysym.sym == SDLK_SPACE) paused = !paused;
            }
        }
        if (!paused) spin = (spin + 6) % 3600;
        draw(desk, spin);

        SDL_UpdateTexture(tex, NULL, desk->px, desk->stride * (int)sizeof(uint32_t));
        int ow = WIN_W, oh = WIN_H; SDL_GetRendererOutputSize(ren, &ow, &oh);
        SDL_Rect dst = { (ow-WIN_W)/2, (oh-WIN_H)/2, WIN_W, WIN_H };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, &dst);
        SDL_RenderPresent(ren);
        SDL_Delay(16);
    }

    if (face) font_face_close(face);
    gfx_surface_free(desk);
    SDL_DestroyTexture(tex); SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
