// theme_window_demo.c — render a window dressed in the real Aristo2 theme:
// titlebar + window controls + frame, with buttons / checkbox / radio / text
// field inside, text drawn through the VDI.  Proves the baked atlas + 9-slice
// engine on actual artwork.  Shown 1:1 in an SDL window (Esc / close to quit).

#include "theme.h"
#include "font.h"
#include <stdio.h>
#include <SDL2/SDL.h>

#define WIN_W 440
#define WIN_H 300

static theme TH;
static int H;                                          // the VDI workstation

static void sprite(const char *name, int x, int y) {   // draw at natural size
    const theme_slice *s = theme_find(&TH, name);
    if (s) theme_blit(H, &TH, s, x, y, s->sw, s->sh);
}
static int text_w(font_face *ff, const char *s, int px) { return font_text_width(font_at(ff, px), s); }

// A themed push button sized to its label; returns its width.
static int button(font_face *ff, const char *variant, int x, int y, const char *lbl) {
    const theme_slice *s = theme_find(&TH, variant);
    int h = s ? s->sh : 24, w = text_w(ff, lbl, 15) + 28;
    theme_blit(H, &TH, s, x, y, w, h);
    vst_color(H,1); vst_height(H,15,0,0,0,0);
    vst_alignment(H, VDI_TA_CENTER, VDI_TA_HALF, 0,0);
    v_gtext(H, x + w/2, y + h/2, lbl);
    vst_alignment(H, VDI_TA_LEFT, VDI_TA_TOP, 0,0);
    return w;
}

static void draw(gfx_surface *d, font_face *ff) {
    for (int i = 0; i < WIN_W*WIN_H; i++) d->px[i] = GFX_RGB(236,238,240);

    int wx = 30, wy = 26, ww = 380, wh = 240;
    const theme_slice *head = theme_find(&TH, "titlebar");
    int th = head ? head->sh : 24;
    theme_draw(H, &TH, "window", wx, wy, ww, wh);                 // 9-slice frame
    theme_blit(H, &TH, head, wx, wy, ww, th);                     // titlebar strip
    sprite("close", wx + 8, wy + (th-16)/2);
    sprite("minimize", wx + 28, wy + (th-16)/2);
    sprite("maximize", wx + 48, wy + (th-16)/2);
    vst_color(H,1); vst_height(H,15,0,0,0,0);
    vst_alignment(H, VDI_TA_CENTER, VDI_TA_HALF, 0,0);
    v_gtext(H, wx + ww/2, wy + th/2, "Aristo2 Window");
    vst_alignment(H, VDI_TA_LEFT, VDI_TA_TOP, 0,0);

    int cx = wx + 24, cy = wy + th + 24;
    vst_height(H,15,0,0,0,0);
    sprite("check.selected", cx, cy);        vst_color(H,1); v_gtext(H, cx+28, cy+3, "Enabled option");
    sprite("radio.selected", cx, cy+34);     vst_color(H,1); v_gtext(H, cx+28, cy+37, "Selected radio");
    const theme_slice *tf = theme_find(&TH, "textfield");
    theme_blit(H, &TH, tf, cx, cy+72, 220, 26);
    vst_color(H,1); v_gtext(H, cx+8, cy+78, "text field");

    int by = wy + wh - 50;
    int bw = button(ff, "button.disabled", wx + 24, by, "Disabled");
    int b2 = button(ff, "button", wx + 40 + bw, by, "Cancel");
    button(ff, "button.selected", wx + 56 + bw + b2, by, "Accept");
}

int main(void) {
    if (SDL_Init(SDL_INIT_VIDEO) != 0) { fprintf(stderr, "SDL_Init: %s\n", SDL_GetError()); return 1; }
    SDL_Window   *win = SDL_CreateWindow("GEM theme — Aristo2 window",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIN_W, WIN_H, SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture  *tex = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING, WIN_W, WIN_H);
    gfx_surface *desk = gfx_surface_alloc(WIN_W, WIN_H);
    if (!win || !ren || !tex || !desk) { fprintf(stderr, "init failed\n"); return 1; }

    vdi_init(desk); H = v_opnvwk(desk);
    font_face *ff = font_face_open("fonts/AovelSansRounded.ttf");
    if (ff) font_face_set_tracking(ff, 1);
    vdi_set_face(ff);
    if (theme_load(&TH, "themes/Aristo2/1x") != 0) { fprintf(stderr, "theme load failed (run: make themepack)\n"); return 1; }

    int running = 1, dirty = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running = 0;
            else if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE) running = 0;
        }
        if (dirty) { draw(desk, ff); dirty = 0; }
        SDL_UpdateTexture(tex, NULL, desk->px, desk->stride * (int)sizeof(uint32_t));
        int ow = WIN_W, oh = WIN_H; SDL_GetRendererOutputSize(ren, &ow, &oh);
        SDL_Rect dst = { (ow-WIN_W)/2, (oh-WIN_H)/2, WIN_W, WIN_H };
        SDL_SetRenderDrawColor(ren, 0, 0, 0, 255); SDL_RenderClear(ren);
        SDL_RenderCopy(ren, tex, NULL, &dst); SDL_RenderPresent(ren);
        SDL_Delay(16);
    }
    theme_free(&TH); if (ff) font_face_close(ff);
    gfx_surface_free(desk);
    SDL_DestroyTexture(tex); SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
