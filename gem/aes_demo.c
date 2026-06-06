// aes_demo.c — a GEM AES dialog defined as an OBJECT tree, rendered through
// objc_draw (which themes each widget via theme_draw).  Clicking an EXIT button
// flashes it (selected) and reports it — a hand-rolled mini form_do.  Shows the
// AES object layer driving the Aristo2 theme.  Esc / close to quit.

#include "aes/aes.h"
#include "font.h"
#include <stdio.h>
#include <string.h>
#include <SDL2/SDL.h>

#define WIN_W 520
#define WIN_H 300

// The dialog tree.  Children: title, message, checkbox, three buttons.
enum { ROOT, TITLE, MSG, CHK, BTN_DONT, BTN_CANCEL, BTN_SAVE };
static OBJECT dlg[] = {
 /*ROOT  */ { NIL,    TITLE, BTN_SAVE, G_BOX,    OF_NONE,                     OS_NORMAL,  0,            70,60, 380,180 },
 /*TITLE */ { MSG,    NIL,   NIL,      G_STRING, OF_NONE,                     OS_NORMAL,  (void*)"Save changes?",                          24,18,  340,18 },
 /*MSG   */ { CHK,    NIL,   NIL,      G_STRING, OF_NONE,                     OS_NORMAL,  (void*)"Do you want to save the changes you made?", 24,44, 340,16 },
 /*CHK   */ { BTN_DONT,NIL,  NIL,      G_CHECKBOX,OF_SELECTABLE,              OS_NORMAL,  (void*)"Apply to all open documents",          24,78,  280,20 },
 /*DONT  */ { BTN_CANCEL,NIL,NIL,      G_BUTTON, OF_SELECTABLE|OF_EXIT,       OS_NORMAL,  (void*)"Don't Save",                            24,132, 104,30 },
 /*CANCEL*/ { BTN_SAVE,NIL,  NIL,      G_BUTTON, OF_SELECTABLE|OF_EXIT,       OS_NORMAL,  (void*)"Cancel",                                188,132, 84,30 },
 /*SAVE  */ { ROOT,   NIL,   NIL,      G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_DEFAULT|OF_LASTOB, OS_NORMAL, (void*)"Save",                      288,132, 84,30 },
};

static theme TH;
static int   HV;

static void redraw(gfx_surface *d) {
    for (int i = 0; i < WIN_W*WIN_H; i++) d->px[i] = GFX_RGB(70,90,120);   // a plain desktop
    objc_draw(dlg, ROOT, 8, 0, 0, WIN_W, WIN_H);
}

int main(int argc, char **argv) {
    gfx_surface *desk = gfx_surface_alloc(WIN_W, WIN_H);
    vdi_init(desk); HV = v_opnvwk(desk);
    font_face *ff = font_face_open("fonts/AovelSansRounded.ttf"); if (ff) font_face_set_tracking(ff,1); vdi_set_face(ff);
    if (theme_load(&TH, "themes/Aristo2/1x") != 0) { fprintf(stderr,"theme load failed (make themepack)\n"); return 1; }
    aes_init(HV, &TH);

    if (argc>1 && !strcmp(argv[1],"--ppm")) {
        redraw(desk);
        FILE *f=fopen("/tmp/aes_demo.ppm","wb"); fprintf(f,"P6\n%d %d\n255\n",WIN_W,WIN_H);
        for(int i=0;i<WIN_W*WIN_H;i++){uint32_t v=desk->px[i];unsigned char c[3]={v>>24,v>>16,v>>8};fwrite(c,1,3,f);}
        fclose(f); return 0;
    }

    if (SDL_Init(SDL_INIT_VIDEO)!=0){fprintf(stderr,"SDL: %s\n",SDL_GetError());return 1;}
    SDL_Window *win=SDL_CreateWindow("GEM AES — dialog",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,WIN_W,WIN_H,SDL_WINDOW_RESIZABLE);
    SDL_Renderer *ren=SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    SDL_Texture *tex=SDL_CreateTexture(ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    int run=1, dirty=1, off_x=0, off_y=0;
    while(run){
        SDL_Event e;
        while(SDL_PollEvent(&e)){
            if(e.type==SDL_QUIT||(e.type==SDL_KEYDOWN&&e.key.keysym.sym==SDLK_ESCAPE)) run=0;
            else if(e.type==SDL_MOUSEBUTTONDOWN && e.button.button==SDL_BUTTON_LEFT){
                int mx=e.button.x-off_x, my=e.button.y-off_y;
                int o=objc_find(dlg, ROOT, 8, mx, my);
                if(o>=0){
                    if(dlg[o].ob_type==G_CHECKBOX){ dlg[o].ob_state ^= OS_SELECTED; dirty=1; }
                    else if(dlg[o].ob_flags & OF_EXIT){           // flash + report
                        dlg[o].ob_state |= OS_SELECTED; redraw(desk);
                        SDL_UpdateTexture(tex,NULL,desk->px,desk->stride*4);
                        SDL_RenderClear(ren); SDL_RenderCopy(ren,tex,NULL,NULL); SDL_RenderPresent(ren);
                        SDL_Delay(120); dlg[o].ob_state &= ~OS_SELECTED; dirty=1;
                        printf("clicked: %s\n",(const char*)dlg[o].ob_spec);
                    }
                }
            }
        }
        if(dirty){ redraw(desk); dirty=0; }
        SDL_UpdateTexture(tex,NULL,desk->px,desk->stride*(int)sizeof(uint32_t));
        int ow=WIN_W,oh=WIN_H; SDL_GetRendererOutputSize(ren,&ow,&oh);
        off_x=(ow-WIN_W)/2; off_y=(oh-WIN_H)/2;
        SDL_Rect ds={off_x,off_y,WIN_W,WIN_H};
        SDL_SetRenderDrawColor(ren,0,0,0,255); SDL_RenderClear(ren);
        SDL_RenderCopy(ren,tex,NULL,&ds); SDL_RenderPresent(ren); SDL_Delay(16);
    }
    theme_free(&TH); if(ff)font_face_close(ff); gfx_surface_free(desk);
    SDL_DestroyTexture(tex); SDL_DestroyRenderer(ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
