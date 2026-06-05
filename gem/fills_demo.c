// fills_demo.c — a showcase of the VDI fill attributes: interior styles
// (pattern / hatch), the palette (vs_color), and perimeters.  Everything is
// drawn through the VDI onto one desktop surface, presented 1:1 (see sdl_main.c
// for why).  SPACE toggles the perimeter on the pattern/hatch tiles; ESC quits.
//
//   make -C gem fills

#include "vdi/vdi.h"
#include <SDL2/SDL.h>
#include <stdio.h>

#define WIN_W 1280
#define WIN_H 720
#define COL_BG GFX_RGB(0x20, 0x80, 0x84)   // muted teal

#define VH 1                               // physical workstation (vdi_init)

// Centred label at (x,y-top).
static void label(int x, int y, const char *s, int pen, int px) {
    vst_color(VH, pen);
    vst_height(VH, px, NULL, NULL, NULL, NULL);
    vst_alignment(VH, VDI_TA_CENTER, VDI_TA_TOP, NULL, NULL);
    v_gtext(VH, x, y, s);
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
}
static void left_label(int x, int y, const char *s, int pen, int px) {
    vst_color(VH, pen);
    vst_height(VH, px, NULL, NULL, NULL, NULL);
    v_gtext(VH, x, y, s);
}

static void rect(int x, int y, int w, int h) {
    int16_t r[4] = { (int16_t)x, (int16_t)y, (int16_t)(x+w-1), (int16_t)(y+h-1) };
    vr_recfl(VH, r);
}
static void white_bg(int x, int y, int w, int h) {
    vsf_color(VH, 0); vsf_interior(VH, VDI_FIS_SOLID); vsf_perimeter(VH, 0);
    rect(x, y, w, h);
}
static void frame_black(int x, int y, int w, int h) {     // definition outline
    vsf_color(VH, 1); vsf_interior(VH, VDI_FIS_HOLLOW); vsf_perimeter(VH, 1);
    rect(x, y, w, h);
}

// A pattern/hatch tile: white tile, fill in pen, optional perimeter in pen.
static void tile_fill(int x, int y, int w, int h, int interior, int style,
                      int pen, int perim, const char *cap) {
    white_bg(x, y, w, h);
    vsf_color(VH, pen); vsf_interior(VH, interior); vsf_style(VH, style);
    vsf_perimeter(VH, perim);                     // the perimeter is the thing on show
    rect(x, y, w, h);
    if (cap) label(x + w/2, y + h + 4, cap, 0, 13);
}

// A solid colour swatch with a black definition frame.
static void tile_color(int x, int y, int w, int h, int pen, const char *cap) {
    white_bg(x, y, w, h);
    vsf_color(VH, pen); vsf_interior(VH, VDI_FIS_SOLID); vsf_perimeter(VH, 0);
    rect(x, y, w, h);
    frame_black(x, y, w, h);
    if (cap) label(x + w/2, y + h + 4, cap, 0, 13);
}

static void draw(gfx_surface *desk, int perim) {
    vdi_init(desk);                                // fresh palette + workstation
    gfx_fill_rect(desk, 0, 0, WIN_W, WIN_H, COL_BG);   // teal backdrop

    label(WIN_W/2, 16, "GEM VDI fills — patterns, hatches, vs_color palette, perimeters", 0, 22);
    label(WIN_W/2, 46, perim ? "pattern/hatch perimeter: ON   [SPACE to toggle, ESC to quit]"
                             : "pattern/hatch perimeter: OFF  [SPACE to toggle, ESC to quit]", 0, 14);

    const int TW = 96, TH = 70, GAP = 24;

    // --- Patterns (vsf_interior PATTERN, vsf_style 1..4) ---
    left_label(40, 86, "Patterns (vsf_interior FIS_PATTERN)", 0, 15);
    const char *pn[] = { "d12", "d25", "d50", "d75" };
    for (int i = 0; i < 4; i++)
        tile_fill(40 + i*(TW+GAP), 110, TW, TH, VDI_FIS_PATTERN, i+1, 1, perim, pn[i]);

    // --- Hatches (vsf_interior HATCH, vsf_style 1..6) ---
    left_label(40, 214, "Hatches (vsf_interior FIS_HATCH)", 0, 15);
    const char *hn[] = { "horiz", "vert", "grid", "diag", "anti", "xgrid" };
    for (int i = 0; i < 6; i++)
        tile_fill(40 + i*(TW+GAP), 238, TW, TH, VDI_FIS_HATCH, i+1, 4, perim, hn[i]);

    // --- Standard palette pens (0..7) ---
    left_label(40, 342, "Standard pens (vsf_color)", 0, 15);
    const char *cn[] = { "0 white","1 black","2 red","3 green","4 blue","5 cyan","6 yellow","7 magenta" };
    for (int i = 0; i < 8; i++)
        tile_color(40 + i*(TW+GAP), 366, TW, TH, i, cn[i]);

    // --- Palette redefined with vs_color (a hue ramp) ---
    left_label(40, 470, "Palette redefined live with vs_color (RGB 0..1000)", 0, 15);
    static const int16_t ramp[8][3] = {
        {1000,   0,   0}, {1000, 500,   0}, {1000,1000,   0}, {   0,1000,   0},
        {   0,1000,1000}, {   0,   0,1000}, { 600,   0,1000}, {1000,   0, 600},
    };
    for (int i = 0; i < 8; i++) {
        vs_color(VH, 200 + i, ramp[i]);            // redefine a spare pen
        tile_color(40 + i*(TW+GAP), 494, TW, TH, 200 + i, NULL);
    }

    // --- Perimeter behaviour ---
    left_label(40, 598, "vsf_perimeter", 0, 15);
    // OFF: hatch reaches the tile edge, no border line
    white_bg(40, 622, 150, 60);
    vsf_color(VH, 4); vsf_interior(VH, VDI_FIS_HATCH); vsf_style(VH, 4); vsf_perimeter(VH, 0);
    rect(40, 622, 150, 60);
    label(40 + 75, 686, "OFF", 0, 13);
    // ON: same hatch + a solid border in the fill colour
    white_bg(230, 622, 150, 60);
    vsf_color(VH, 4); vsf_interior(VH, VDI_FIS_HATCH); vsf_style(VH, 4); vsf_perimeter(VH, 1);
    rect(230, 622, 150, 60);
    label(230 + 75, 686, "ON", 0, 13);
    // HOLLOW + perimeter: outline only, empty interior
    white_bg(420, 622, 150, 60);
    vsf_color(VH, 4); vsf_interior(VH, VDI_FIS_HOLLOW); vsf_perimeter(VH, 1);
    rect(420, 622, 150, 60);
    label(420 + 75, 686, "HOLLOW + perimeter", 0, 13);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
    SDL_Window   *win = SDL_CreateWindow("GEM VDI fills demo",
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

    int perim = 1, running = 1, dirty = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN) {
                if (e.key.keysym.sym == SDLK_ESCAPE) running = 0;
                else if (e.key.keysym.sym == SDLK_SPACE) { perim = !perim; dirty = 1; }
            }
        }
        if (dirty) { draw(desk, perim); dirty = 0; }

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
