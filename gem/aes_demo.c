// aes_demo.c — a GEM AES dialog (OBJECT tree) run through the real form_do
// modal loop.  Push buttons flash while held and trigger on release, the
// checkbox toggles, Return fires the default (Save) button.  The host supplies
// the event source (present + SDL_WaitEvent).  Esc / close to quit.

#include "aes/aes.h"
#include "font.h"
#include <stdio.h>
#include <string.h>
#include <SDL2/SDL.h>

#define WIN_W 520
#define WIN_H 300

enum { ROOT, TITLE, MSG, CHK, BTN_DONT, BTN_CANCEL, BTN_SAVE };
static OBJECT dlg[] = {
 /*ROOT  */ { NIL,    TITLE, BTN_SAVE, G_BOX,    OF_NONE,               OS_NORMAL, 0,                                                70,60, 380,180 },
 /*TITLE */ { MSG,    NIL,   NIL,      G_STRING, OF_NONE,               OS_NORMAL, (void*)"Save changes?",                            24,18,  340,18 },
 /*MSG   */ { CHK,    NIL,   NIL,      G_STRING, OF_NONE,               OS_NORMAL, (void*)"Do you want to save the changes you made?", 24,44, 340,16 },
 /*CHK   */ { BTN_DONT,NIL,  NIL,      G_CHECKBOX,OF_SELECTABLE,        OS_NORMAL, (void*)"Apply to all open documents",            24,78,  280,20 },
 /*DONT  */ { BTN_CANCEL,NIL,NIL,      G_BUTTON, OF_SELECTABLE|OF_EXIT, OS_NORMAL, (void*)"Don't Save",                              24,132, 104,30 },
 /*CANCEL*/ { BTN_SAVE,NIL,  NIL,      G_BUTTON, OF_SELECTABLE|OF_EXIT, OS_NORMAL, (void*)"Cancel",                                  188,132, 84,30 },
 /*SAVE  */ { ROOT,   NIL,   NIL,      G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_DEFAULT|OF_LASTOB, OS_NORMAL, (void*)"Save",                288,132, 84,30 },
};

static SDL_Renderer *g_ren;
static SDL_Texture  *g_tex;
static gfx_surface  *g_desk;

// Host event source: present the current frame, then block (up to timeout_ms,
// -1 = forever) for the next event, reporting the live pointer state.
static int g_btn;     // current button mask
static int present_and_wait(aes_event *ev, int timeout_ms) {
    SDL_UpdateTexture(g_tex, NULL, g_desk->px, g_desk->stride*(int)sizeof(uint32_t));
    int ow=WIN_W, oh=WIN_H; SDL_GetRendererOutputSize(g_ren, &ow, &oh);
    int ox=(ow-WIN_W)/2, oy=(oh-WIN_H)/2;
    SDL_Rect ds = { ox, oy, WIN_W, WIN_H };
    SDL_SetRenderDrawColor(g_ren,0,0,0,255); SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren, g_tex, NULL, &ds); SDL_RenderPresent(g_ren);

    SDL_Event e;
    int got = (timeout_ms < 0) ? SDL_WaitEvent(&e) : SDL_WaitEventTimeout(&e, timeout_ms);
    ev->button = g_btn;
    if (!got) { ev->type = AES_TIMER; return AES_TIMER; }
    do {
        switch (e.type) {
            case SDL_QUIT: ev->type=AES_QUIT; return AES_QUIT;
            case SDL_KEYDOWN:
                if (e.key.keysym.sym==SDLK_ESCAPE) { ev->type=AES_QUIT; return AES_QUIT; }
                ev->type=AES_KEY; ev->key=(e.key.keysym.sym==SDLK_RETURN?'\r':(int)e.key.keysym.sym);
                ev->shift = SDL_GetModState() & KMOD_SHIFT ? 1 : 0; return AES_KEY;
            case SDL_MOUSEMOTION:
                ev->type=AES_MOTION; ev->mx=e.motion.x-ox; ev->my=e.motion.y-oy; return AES_MOTION;
            case SDL_MOUSEBUTTONDOWN:
                if (e.button.button!=SDL_BUTTON_LEFT) break;
                g_btn |= 1; ev->button=g_btn; ev->type=AES_BTN_DOWN; ev->mx=e.button.x-ox; ev->my=e.button.y-oy; return AES_BTN_DOWN;
            case SDL_MOUSEBUTTONUP:
                if (e.button.button!=SDL_BUTTON_LEFT) break;
                g_btn &= ~1; ev->button=g_btn; ev->type=AES_BTN_UP; ev->mx=e.button.x-ox; ev->my=e.button.y-oy; return AES_BTN_UP;
        }
    } while (SDL_PollEvent(&e));
    ev->type=AES_NONE; return AES_NONE;
}

int main(void) {
    if (SDL_Init(SDL_INIT_VIDEO)!=0){fprintf(stderr,"SDL: %s\n",SDL_GetError());return 1;}
    SDL_Window *win=SDL_CreateWindow("GEM AES — form_do",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,WIN_W,WIN_H,SDL_WINDOW_RESIZABLE);
    g_ren=SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    g_tex=SDL_CreateTexture(g_ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    g_desk=gfx_surface_alloc(WIN_W,WIN_H);
    int HV; vdi_init(g_desk); HV=v_opnvwk(g_desk);
    font_face *ff=font_face_open("fonts/AovelSansRounded.ttf"); if(ff)font_face_set_tracking(ff,1); vdi_set_face(ff);
    static theme TH;
    if (theme_load(&TH,"themes/Aristo2/1x")!=0){fprintf(stderr,"theme load failed (make themepack)\n");return 1;}
    aes_init(HV,&TH);
    aes_set_events(present_and_wait);

    for (int i=0;i<WIN_W*WIN_H;i++) g_desk->px[i]=GFX_RGB(70,90,120);   // desktop, drawn once

    for (;;) {
        int o = form_do(dlg, ROOT);
        if (o < 0) break;                                     // window closed / Esc
        printf("form_do -> %s\n", (const char*)dlg[o].ob_spec);
        dlg[o].ob_state &= ~OS_SELECTED;                      // release for the next run
        if (o==BTN_SAVE || o==BTN_CANCEL || o==BTN_DONT) {}   // a real app would close here
    }

    theme_free(&TH); if(ff)font_face_close(ff); gfx_surface_free(g_desk);
    SDL_DestroyTexture(g_tex); SDL_DestroyRenderer(g_ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
