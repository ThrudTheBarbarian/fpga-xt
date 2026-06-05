// output_demo.c — the remaining VDI output primitives at a range of sizes:
// v_pmarker (6 marker types x 6 heights), v_cellarray (various grid dims), and
// v_contourfill (growing regions).  Drawn through the VDI, presented 1:1 (see
// sdl_main.c).  SPACE recolours the markers; ESC quits.
//
//   make -C gem output

#include "vdi/vdi.h"
#include <SDL2/SDL.h>
#include <stdio.h>

#define WIN_W 1280
#define WIN_H 720
#define COL_BG GFX_RGB(0xec, 0xec, 0xec)
#define VH 1

static void label(int x, int y, const char *s, int pen, int px) {
    vst_color(VH, pen); vst_height(VH, px, NULL, NULL, NULL, NULL);
    vst_alignment(VH, VDI_TA_CENTER, VDI_TA_TOP, NULL, NULL);
    v_gtext(VH, x, y, s);
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
}
static void lleft(int x, int y, const char *s, int px) {
    vst_color(VH, 1); vst_height(VH, px, NULL, NULL, NULL, NULL);
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_HALF, NULL, NULL);
    v_gtext(VH, x, y, s);
    vst_alignment(VH, VDI_TA_LEFT, VDI_TA_TOP, NULL, NULL);
}

static void draw(gfx_surface *desk, int cshift) {
    vdi_init(desk);
    gfx_fill_rect(desk, 0, 0, WIN_W, WIN_H, COL_BG);
    char buf[16];

    label(WIN_W/2, 12, "GEM VDI output primitives at various sizes", 1, 22);
    label(WIN_W/2, 40, "v_pmarker  ·  v_cellarray  ·  v_contourfill    [SPACE recolour, ESC quit]", 1, 13);

    // --- Markers: 6 types down, 6 heights across ---
    vst_color(VH, 1); vst_height(VH, 14, NULL, NULL, NULL, NULL);
    v_gtext(VH, 20, 66, "v_pmarker — 6 types (rows) x 6 heights (vsm_height, columns)");
    const char *mn[6] = { "dot", "plus", "asterisk", "square", "cross", "diamond" };
    int hts[6] = { 6, 10, 16, 24, 32, 40 };
    int colx[6];
    for (int i = 0; i < 6; i++) { colx[i] = 150 + i*78;
        snprintf(buf, sizeof buf, "h=%d", hts[i]); label(colx[i], 86, buf, 9, 12); }
    for (int t = 1; t <= 6; t++) {
        int rowy = 124 + (t-1)*60;
        lleft(20, rowy, mn[t-1], 13);
        vsm_type(VH, t); vsm_color(VH, 2 + (t-1 + cshift) % 6);
        for (int i = 0; i < 6; i++) {
            vsm_height(VH, hts[i]);
            int16_t p[2] = { (int16_t)colx[i], (int16_t)rowy };
            v_pmarker(VH, 1, p);
        }
    }

    // --- Cell arrays of various dimensions, each into a 150x96 rect ---
    vst_color(VH, 1); vst_height(VH, 14, NULL, NULL, NULL, NULL);
    v_gtext(VH, 660, 66, "v_cellarray — different grid dimensions");
    static const struct { int cols, rows; const char *name; } cg[6] = {
        {1,1,"1x1"}, {4,1,"4x1"}, {1,4,"1x4"}, {6,4,"6x4"}, {12,8,"12x8"}, {3,3,"3x3"} };
    int16_t pal[96];
    for (int t = 0; t < 6; t++) {
        int gx = 660 + (t % 3)*200, gy = 100 + (t / 3)*150;
        int n = cg[t].cols * cg[t].rows;
        for (int i = 0; i < n; i++) pal[i] = (int16_t)(1 + (i + cshift) % 7);   // pens 1..7
        int16_t r[4] = { (int16_t)gx, (int16_t)gy, (int16_t)(gx+149), (int16_t)(gy+95) };
        v_cellarray(VH, r, cg[t].cols, cg[t].rows, pal);
        label(gx + 75, gy + 100, cg[t].name, 1, 13);
    }

    // --- Contour fills of growing regions ---
    vst_color(VH, 1); vst_height(VH, 14, NULL, NULL, NULL, NULL);
    v_gtext(VH, 20, 470, "v_contourfill — seed fill of growing circles (boundary fill, pen 1)");
    int radii[5] = { 14, 24, 38, 56, 78 };
    int cxp = 80;
    for (int i = 0; i < 5; i++) {
        int r = radii[i], cy = 600;
        vsl_color(VH, 1); vsl_width(VH, 1); v_arc(VH, cxp + r, cy, r, 0, 3600);
        vsf_color(VH, 2 + (i + cshift) % 6); v_contourfill(VH, cxp + r, cy, 1);
        snprintf(buf, sizeof buf, "r=%d", r); label(cxp + r, cy + r + 6, buf, 1, 12);
        cxp += 2*r + 40;
    }
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
    SDL_Window   *win = SDL_CreateWindow("GEM VDI output demo",
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

    int cshift = 0, running = 1, dirty = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN) {
                if (e.key.keysym.sym == SDLK_ESCAPE) running = 0;
                else if (e.key.keysym.sym == SDLK_SPACE) { cshift = (cshift + 1) % 6; dirty = 1; }
            }
        }
        if (dirty) { draw(desk, cshift); dirty = 0; }

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
