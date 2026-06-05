// text_demo.c — twelve strings spinning, each a different colour, size and
// rate, via vst_rotation (arbitrary angle).  Each is centred in its grid cell:
// the baseline origin is offset so the string rotates about its own middle.
// Presented 1:1 (see sdl_main.c).  SPACE pauses, ESC quits.
//
//   make -C gem text

#include "vdi/vdi.h"
#include "font.h"
#include <SDL2/SDL.h>
#include <stdio.h>
#include <math.h>

#define WIN_W 1280
#define WIN_H 720
#define COL_BG GFX_RGB(0x12, 0x16, 0x1c)   // near-black
#define VH 1

static const char *words[12] = {
    "Rotate", "Spin", "Twirl", "Whirl", "Pivot", "Swirl",
    "Orbit", "Gyrate", "Revolve", "Turn", "Cycle", "Wheel",
};
static const int sizes[12] = { 18, 24, 30, 36, 22, 28, 34, 40, 20, 26, 32, 38 };
static const int fx[12] = {
    0, FX_BOLD, FX_ITALIC, FX_BOLD | FX_ITALIC,
    FX_OUTLINE, FX_SHADOW, FX_LIGHT, FX_UNDERLINE,
    FX_BOLD | FX_SHADOW, FX_OUTLINE | FX_ITALIC, FX_BOLD | FX_UNDERLINE, FX_SHADOW | FX_ITALIC,
};
static const int16_t hue[12][3] = {
    {1000,0,0}, {1000,500,0}, {1000,800,0}, {1000,1000,0},
    {600,1000,0}, {0,1000,0}, {0,1000,600}, {0,1000,1000},
    {0,400,1000}, {300,0,1000}, {700,0,1000}, {1000,0,700},
};
static font_face *g_face;
static int angle[12], speed[12];

static void draw(gfx_surface *desk) {
    gfx_fill_rect(desk, 0, 0, WIN_W, WIN_H, COL_BG);

    vst_color(VH, 0); vst_height(VH, 22, NULL, NULL, NULL, NULL);
    vst_rotation(VH, 0); vst_alignment(VH, VDI_TA_CENTER, VDI_TA_TOP, NULL, NULL);
    v_gtext(VH, WIN_W/2, 16, "GEM VDI — 12 rotating strings (vst_rotation), each with a vst_effect");
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);

    for (int i = 0; i < 12; i++) {
        int col = i % 4, row = i / 4;
        int cx = 160 + col * 320, cy = 170 + row * 200;
        int size = sizes[i], a = angle[i];
        if (fx[i] & FX_OUTLINE) size *= 2;             // outline needs room to show hollow
        vst_color(VH, 100 + i);
        vst_height(VH, size, NULL, NULL, NULL, NULL);
        vst_rotation(VH, a);
        vst_effects(VH, fx[i]);                        // a different effect per string

        font *f = font_at(g_face, size);
        int W = font_text_width(f, words[i]), asc = font_ascent(f);
        double th = a * (M_PI / 1800.0), s = sin(th), c = cos(th);
        // baseline dir = (c,-s); text-up = (-s,-c).  Place the string's middle at (cx,cy).
        double ox = cx - (W / 2.0) * c        - (asc / 2.0) * (-s);
        double oy = cy - (W / 2.0) * (-s)      - (asc / 2.0) * (-c);
        v_gtext(VH, (int)lround(ox), (int)lround(oy) - asc, words[i]);
    }
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
    SDL_Window   *win = SDL_CreateWindow("GEM VDI text demo",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIN_W, WIN_H, SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture  *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING, WIN_W, WIN_H);
    gfx_surface *desk = gfx_surface_alloc(WIN_W, WIN_H);
    if (!win || !ren || !tex || !desk) { fprintf(stderr, "init failed\n"); return 1; }

    vdi_init(desk);
    g_face = font_face_open("fonts/AovelSansRounded.ttf");
    if (g_face) font_face_set_tracking(g_face, 1);
    vdi_set_face(g_face);
    for (int i = 0; i < 12; i++) {
        vs_color(VH, 100 + i, hue[i]);                 // 12-hue rainbow
        angle[i] = i * 300;                            // staggered start
        speed[i] = (i & 1 ? 1 : -1) * (8 + i * 3);     // varied rate + direction
    }

    int running = 1, paused = 0;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN) {
                if (e.key.keysym.sym == SDLK_ESCAPE) running = 0;
                else if (e.key.keysym.sym == SDLK_SPACE) paused = !paused;
            }
        }
        if (!paused)
            for (int i = 0; i < 12; i++) { int a = (angle[i] + speed[i]) % 3600; angle[i] = a < 0 ? a + 3600 : a; }
        draw(desk);

        SDL_UpdateTexture(tex, NULL, desk->px, desk->stride * (int)sizeof(uint32_t));
        int ow = WIN_W, oh = WIN_H; SDL_GetRendererOutputSize(ren, &ow, &oh);
        SDL_Rect dst = { (ow-WIN_W)/2, (oh-WIN_H)/2, WIN_W, WIN_H };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
        SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, &dst);
        SDL_RenderPresent(ren);
        SDL_Delay(16);
    }

    if (g_face) font_face_close(g_face);
    gfx_surface_free(desk);
    SDL_DestroyTexture(tex); SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
