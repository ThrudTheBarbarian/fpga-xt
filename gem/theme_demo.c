// theme_demo.c — exercise the 9-slice theme engine against a synthetic atlas:
// build an RGBA atlas (opaque corners, gradient edges, translucent centre),
// round-trip it through the .tex loader, then blit it at several sizes over a
// checker background to confirm corners stay 1:1, edges stretch one axis, the
// centre stretches both, and the alpha composites (VR_OVER).

#include "theme.h"
#include <stdio.h>
#include <stdlib.h>
#include <SDL2/SDL.h>

static void present(gfx_surface *d) {        // show d 1:1 in a window until quit
    if (SDL_Init(SDL_INIT_VIDEO) != 0) return;
    SDL_Window *w = SDL_CreateWindow("GEM theme — 9-slice engine test",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, d->w, d->h, SDL_WINDOW_RESIZABLE);
    SDL_Renderer *r = SDL_CreateRenderer(w, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture *t = SDL_CreateTexture(r, SDL_PIXELFORMAT_RGBA8888,
        SDL_TEXTUREACCESS_STREAMING, d->w, d->h);
    int run = 1;
    while (run) {
        SDL_Event e;
        while (SDL_PollEvent(&e))
            if (e.type == SDL_QUIT || (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE)) run = 0;
        SDL_UpdateTexture(t, NULL, d->px, d->stride * (int)sizeof(uint32_t));
        int ow = d->w, oh = d->h; SDL_GetRendererOutputSize(r, &ow, &oh);
        SDL_Rect ds = { (ow-d->w)/2, (oh-d->h)/2, d->w, d->h };
        SDL_SetRenderDrawColor(r, 0,0,0,255); SDL_RenderClear(r);
        SDL_RenderCopy(r, t, NULL, &ds); SDL_RenderPresent(r); SDL_Delay(16);
    }
    SDL_DestroyTexture(t); SDL_DestroyRenderer(r); SDL_DestroyWindow(w); SDL_Quit();
}

int main(void) {
    // ---- synthetic 36x36 atlas, 12px insets ----
    int A = 36, ins = 12;
    gfx_surface *atlas = gfx_surface_alloc(A, A);
    for (int y = 0; y < A; y++) for (int x = 0; x < A; x++) {
        int corner = (x < ins || x >= A-ins) && (y < ins || y >= A-ins);
        int edge   = (x < ins || x >= A-ins) ^ (y < ins || y >= A-ins);
        uint32_t px;
        if (corner)      px = GFX_RGB(200,40,40);                 // opaque red corners
        else if (edge)   px = GFX_RGB(40,160,60);                 // opaque green edges
        else             px = GFX_RGBA(40,90,210,150);            // translucent blue centre
        atlas->px[(size_t)y*atlas->stride+x] = px;
    }
    // write + reload through the .tex path
    FILE *tf = fopen("/tmp/theme_test.tex", "wb");
    uint32_t w = A, h = A; fwrite("GTEX",1,4,tf); fwrite(&w,4,1,tf); fwrite(&h,4,1,tf);
    for (int y=0;y<A;y++) fwrite(atlas->px+(size_t)y*atlas->stride,4,A,tf);
    fclose(tf); gfx_surface_free(atlas);

    theme th = {0};
    th.atlas = theme_tex_load("/tmp/theme_test.tex");
    if (!th.atlas) { fprintf(stderr,"tex load failed\n"); return 1; }
    mfdb_from_surface(&th.atlas_mfdb, th.atlas);
    theme_slice sl = { "frame", 0,0,A,A, ins,ins,ins,ins, THEME_STRETCH };

    // ---- destination: a grey/white checker so the translucent centre shows ----
    gfx_surface *d = gfx_surface_alloc(420, 240);
    for (int y=0;y<240;y++) for (int x=0;x<420;x++)
        d->px[(size_t)y*d->stride+x] = ((x/12 + y/12) & 1) ? GFX_RGB(210,210,210) : GFX_RGB(245,245,245);
    vdi_init(d); int handle = v_opnvwk(d);

    theme_blit(handle, &th, &sl,  20,  20,  60,  60);   // small square
    theme_blit(handle, &th, &sl,  95,  20, 300,  50);   // wide (edges stretch horizontally)
    theme_blit(handle, &th, &sl,  20,  95,  55, 130);   // tall (edges stretch vertically)
    theme_blit(handle, &th, &sl,  95,  95, 300, 130);   // big (centre stretches both ways)

    present(d);
    theme_free(&th);
    return 0;
}
