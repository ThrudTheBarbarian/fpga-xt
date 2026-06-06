// aes_window_demo.c — the draggable-window milestone: a themed AES window
// ("Atari XL") on a desktop with a menu bar.  Drag the title to move it, the
// bottom-right corner to resize, the close box to close; File > New opens
// another, File > Quit exits.  All frame interaction is handled by the AES
// inside evnt_multi; the app just draws the work area (content callback) and
// reacts to WM_* / MN_SELECTED messages.  Esc / close to quit.

#include "aes/aes_internal.h"
#include "font.h"
#include <stdio.h>
#include <string.h>
#include <SDL2/SDL.h>

#define WIN_W 640
#define WIN_H 420

static const char *desk_i[] = {"About…"};
static const char *file_i[] = {"New Window", "Quit"};
static menu_def md[] = { {"Desk",desk_i,1}, {"File",file_i,2} };

static SDL_Renderer *g_ren; static SDL_Texture *g_tex; static gfx_surface *g_desk;
static int g_btn, HV;

static int present_and_wait(aes_event *ev, int timeout_ms) {
    SDL_UpdateTexture(g_tex,NULL,g_desk->px,g_desk->stride*(int)sizeof(uint32_t));
    int ow=WIN_W,oh=WIN_H; SDL_GetRendererOutputSize(g_ren,&ow,&oh);
    int ox=(ow-WIN_W)/2, oy=(oh-WIN_H)/2; SDL_Rect ds={ox,oy,WIN_W,WIN_H};
    SDL_SetRenderDrawColor(g_ren,0,0,0,255); SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren,g_tex,NULL,&ds); SDL_RenderPresent(g_ren);
    SDL_Event e;
    int got=(timeout_ms<0)?SDL_WaitEvent(&e):SDL_WaitEventTimeout(&e,timeout_ms);
    ev->button=g_btn; if(!got){ev->type=AES_TIMER;return AES_TIMER;}
    do { switch(e.type){
        case SDL_QUIT: ev->type=AES_QUIT; return AES_QUIT;
        case SDL_KEYDOWN: if(e.key.keysym.sym==SDLK_ESCAPE){ev->type=AES_QUIT;return AES_QUIT;}
            ev->type=AES_KEY; ev->key=(int)e.key.keysym.sym; return AES_KEY;
        case SDL_MOUSEMOTION: ev->type=AES_MOTION; ev->mx=e.motion.x-ox; ev->my=e.motion.y-oy; return AES_MOTION;
        case SDL_MOUSEBUTTONDOWN: if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn|=1; ev->button=g_btn; ev->type=AES_BTN_DOWN; ev->mx=e.button.x-ox; ev->my=e.button.y-oy; return AES_BTN_DOWN;
        case SDL_MOUSEBUTTONUP: if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn&=~1; ev->button=g_btn; ev->type=AES_BTN_UP; ev->mx=e.button.x-ox; ev->my=e.button.y-oy; return AES_BTN_UP;
    }} while(SDL_PollEvent(&e));
    ev->type=AES_NONE; return AES_NONE;
}

// Window content: a little Atari-XL "screen" (black + green BASIC text).
static void xl_draw(int hd, int wx, int wy, int ww, int wh, void *ud) {
    (void)hd; (void)ud;
    vsf_color(HV,1); vsf_interior(HV,VDI_FIS_SOLID); vsf_perimeter(HV,0);
    int16_t r[4]={(int16_t)wx,(int16_t)wy,(int16_t)(wx+ww-1),(int16_t)(wy+wh-1)}; vr_recfl(HV,r);
    vst_color(HV,3); vst_height(HV,16,0,0,0,0);
    v_gtext(HV, wx+10, wy+10, "READY");
    v_gtext(HV, wx+10, wy+34, "10 PRINT \"HELLO FROM XT\"");
    v_gtext(HV, wx+10, wy+54, "20 GOTO 10");
    v_gtext(HV, wx+10, wy+82, "RUN");
}

static int g_nextx = 70, g_nexty = 70;
static int open_xl(const char *name) {
    int h = wind_create(W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER, g_nextx, g_nexty, 360, 240);
    if (!h) return 0;
    wind_set_name(h, name); wind_content(h, xl_draw, 0);
    wind_open(h, g_nextx, g_nexty, 360, 240);
    g_nextx += 30; g_nexty += 28;
    return h;
}

int main(int argc, char **argv) {
    g_desk=gfx_surface_alloc(WIN_W,WIN_H);
    vdi_init(g_desk); HV=v_opnvwk(g_desk);
    font_face *ff=font_face_open("fonts/AovelSansRounded.ttf"); if(ff)font_face_set_tracking(ff,1); vdi_set_face(ff);
    static theme TH; if(theme_load(&TH,"themes/Aristo2/1x")){fprintf(stderr,"theme load failed (make themepack)\n");return 1;}
    aes_init(HV,&TH); appl_init();
    wind_set_desktop(0x46566EFF);
    OBJECT *menu = menu_build(md, 2, WIN_W);
    wind_redraw(); menu_bar(menu, 1);
    open_xl("Atari XL"); menu_bar(menu, 1);     // redraw bar over the fresh window area

    if (argc>1 && !strcmp(argv[1],"--ppm")) {
        FILE *f=fopen("/tmp/aes_window.ppm","wb"); fprintf(f,"P6\n%d %d\n255\n",WIN_W,WIN_H);
        for(int i=0;i<WIN_W*WIN_H;i++){uint32_t v=g_desk->px[i];unsigned char c[3]={v>>24,v>>16,v>>8};fwrite(c,1,3,f);}
        fclose(f); return 0;
    }

    if (SDL_Init(SDL_INIT_VIDEO)!=0){fprintf(stderr,"SDL: %s\n",SDL_GetError());return 1;}
    SDL_Window *win=SDL_CreateWindow("GEM AES — windows",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,WIN_W,WIN_H,SDL_WINDOW_RESIZABLE);
    g_ren=SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    g_tex=SDL_CreateTexture(g_ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    aes_set_events(present_and_wait);

    for (;;) {
        int16_t msg[8]; int mx,my,mb,ks,key;
        int r = evnt_multi(MU_MESAG|MU_KEYBD, 0,0,0, 0,0,0,0,0, 0,0,0,0,0, msg,0,0, &mx,&my,&mb,&ks,&key,0);
        if (r & MU_QUIT) break;
        if (r & MU_MESAG) {
            if (msg[0]==WM_CLOSED) { wind_close(msg[3]); menu_bar(menu,1); }
            else if (msg[0]==MN_SELECTED) {
                const char *it=(const char*)menu[msg[4]].ob_spec;
                if (!strcmp(it,"Quit")) break;
                if (!strcmp(it,"New Window")) { open_xl("Atari XL"); }
                menu_bar(menu,1);
            }
            // WM_MOVED/WM_SIZED/WM_TOPPED already redrawn by the AES; just keep the bar on top
            else if (msg[0]==WM_MOVED||msg[0]==WM_SIZED||msg[0]==WM_TOPPED) menu_bar(menu,1);
        }
    }
    free(menu); theme_free(&TH); if(ff)font_face_close(ff); gfx_surface_free(g_desk);
    SDL_DestroyTexture(g_tex); SDL_DestroyRenderer(g_ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
