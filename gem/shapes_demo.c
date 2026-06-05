// shapes_demo.c — a showcase of the VDI GDP curved primitives and line styles:
// filled circle/ellipse/pieslice/ellpie/rounded-box, their outline cousins
// (arc / elliptical arc / rounded box), the six line types, and a range of line
// widths.  Drawn entirely through the VDI onto one desktop surface, presented
// 1:1 (see sdl_main.c).  SPACE cycles the outline line width; ESC quits.
//
//   make -C gem shapes

#include "vdi/vdi.h"
#include <SDL2/SDL.h>
#include <stdio.h>

#define WIN_W 1280
#define WIN_H 720
#define COL_BG GFX_RGB(0x20, 0x80, 0x84)   // muted teal
#define VH 1                               // physical workstation (vdi_init)

static void label(int x, int y, const char *s, int pen, int px) {
    vst_color(VH, pen); vst_height(VH, px, NULL, NULL, NULL, NULL);
    vst_alignment(VH, VDI_TA_CENTER, VDI_TA_TOP, NULL, NULL);
    v_gtext(VH, x, y, s);
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
}
static void section(int x, int y, const char *s) {
    vst_color(VH, 0); vst_height(VH, 15, NULL, NULL, NULL, NULL);
    v_gtext(VH, x, y, s);
}

static void draw(gfx_surface *desk, int line_w) {
    vdi_init(desk);
    gfx_fill_rect(desk, 0, 0, WIN_W, WIN_H, COL_BG);
    char buf[64];

    label(WIN_W/2, 14, "GEM VDI — curved GDPs and line styles", 0, 22);
    snprintf(buf, sizeof buf, "outline width: %d px   [SPACE, ESC to quit]", line_w);
    label(WIN_W/2, 44, buf, 0, 14);

    // --- Filled GDPs (fill colour / interior / perimeter) ---
    section(40, 80, "Filled GDPs");
    vsf_perimeter(VH, 1); vsl_color(VH, 1); vsl_width(VH, 1); vsl_type(VH, 1);
    vsf_color(VH, 4); vsf_interior(VH, VDI_FIS_SOLID);                 v_circle(VH, 120, 168, 58);
    label(120, 236, "v_circle", 0, 13);
    vsf_color(VH, 3); vsf_interior(VH, VDI_FIS_HATCH);  vsf_style(VH, 4); v_ellipse(VH, 360, 168, 92, 55);
    label(360, 236, "v_ellipse (hatch)", 0, 13);
    vsf_color(VH, 6); vsf_interior(VH, VDI_FIS_SOLID);                 v_pieslice(VH, 610, 182, 66, 300, 1500);
    label(610, 236, "v_pieslice 30-150", 0, 13);
    vsf_color(VH, 7); vsf_interior(VH, VDI_FIS_PATTERN); vsf_style(VH, 3); v_ellpie(VH, 860, 182, 86, 56, 200, 1600);
    label(860, 236, "v_ellpie (pattern)", 0, 13);
    vsf_color(VH, 5); vsf_interior(VH, VDI_FIS_SOLID);
    int16_t rf[4] = { 1040, 112, 1210, 224 }; v_rfbox(VH, rf);
    label(1125, 236, "v_rfbox", 0, 13);

    // --- Outline GDPs (drawn with the line attributes) ---
    section(40, 286, "Outline GDPs — line colour / width / type");
    vsl_color(VH, 1); vsl_width(VH, line_w); vsl_type(VH, 1);
    v_arc(VH, 120, 370, 56, 0, 3600);             label(120, 436, "circle (v_arc 0-360)", 0, 13);
    vsl_color(VH, 2);
    v_arc(VH, 360, 370, 58, 0, 2700);             label(360, 436, "v_arc 0-270", 0, 13);
    vsl_color(VH, 4);
    v_ellarc(VH, 610, 380, 86, 50, 200, 1700);    label(610, 436, "v_ellarc", 0, 13);
    vsl_color(VH, 1);
    int16_t rb[4] = { 800, 324, 1000, 426 }; v_rbox(VH, rb);
    label(900, 436, "v_rbox", 0, 13);

    // --- Line types (vsl_type 1..6) ---
    section(40, 474, "Line types (vsl_type)");
    vsl_color(VH, 1); vsl_width(VH, 2); vst_alignment(VH, VDI_TA_LEFT, VDI_TA_HALF, NULL, NULL);
    const char *lt[] = { "solid", "long dash", "dotted", "dash-dot", "dashed", "dash-dot-dot" };
    for (int t = 1; t <= 6; t++) {
        int y = 506 + (t-1) * 32;
        vst_color(VH, 0); vst_height(VH, 13, NULL, NULL, NULL, NULL);
        v_gtext(VH, 40, y, lt[t-1]);
        vsl_type(VH, t);
        int16_t l[4] = { 190, (int16_t)y, 560, (int16_t)y }; v_pline(VH, 2, l);
    }

    // --- Line widths (vsl_width 1..7) ---
    section(640, 474, "Line widths (vsl_width)");
    vsl_type(VH, 1);
    for (int wd = 1; wd <= 7; wd++) {
        int y = 506 + (wd-1) * 28;
        snprintf(buf, sizeof buf, "%d px", wd);
        vst_color(VH, 0); vst_height(VH, 13, NULL, NULL, NULL, NULL);
        v_gtext(VH, 640, y, buf);
        vsl_width(VH, wd);
        int16_t l[4] = { 720, (int16_t)y, 1200, (int16_t)y }; v_pline(VH, 2, l);
    }
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
    SDL_Window   *win = SDL_CreateWindow("GEM VDI shapes demo",
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

    static const int widths[] = { 1, 2, 4, 8 };
    int wi = 1, running = 1, dirty = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN) {
                if (e.key.keysym.sym == SDLK_ESCAPE) running = 0;
                else if (e.key.keysym.sym == SDLK_SPACE) { wi = (wi + 1) % 4; dirty = 1; }
            }
        }
        if (dirty) { draw(desk, widths[wi]); dirty = 0; }

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
