// aes_menu_demo.c — a GEM menu bar driving the AES event loop.  Clicking a
// title pulls the menu down (tracked live inside evnt_multi); releasing on an
// item posts MN_SELECTED, which the app reads from evnt_mesag and shows in a
// status line.  File > Quit exits.  Esc / close to quit.

#include "aes/aes_internal.h"
#include "font.h"
#include <stdio.h>
#include <string.h>
#include <SDL2/SDL.h>

#define WIN_W 560
#define WIN_H 320

static const char *desk_i[] = {"About GEM…"};
static const char *file_i[] = {"New", "Open…", "Save", "Quit"};
static const char *edit_i[] = {"Cut", "Copy", "Paste"};
static menu_def md[] = { {"Desk",desk_i,1}, {"File",file_i,4}, {"Edit",edit_i,3} };

static SDL_Renderer *g_ren; static SDL_Texture *g_tex; static gfx_surface *g_desk;
static int g_btn;
static char g_status[80] = "Pick a menu item.";

static int present_and_wait(aes_event *ev, int timeout_ms) {
    SDL_UpdateTexture(g_tex,NULL,g_desk->px,g_desk->stride*(int)sizeof(uint32_t));
    int ow=WIN_W,oh=WIN_H; SDL_GetRendererOutputSize(g_ren,&ow,&oh);
    int ox=(ow-WIN_W)/2, oy=(oh-WIN_H)/2; SDL_Rect ds={ox,oy,WIN_W,WIN_H};
    SDL_SetRenderDrawColor(g_ren,0,0,0,255); SDL_RenderClear(g_ren);
    SDL_RenderCopy(g_ren,g_tex,NULL,&ds); SDL_RenderPresent(g_ren);
    SDL_Event e;
    int got = (timeout_ms<0)?SDL_WaitEvent(&e):SDL_WaitEventTimeout(&e,timeout_ms);
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

static void draw_desktop(int HV) {
    for (int i=0;i<WIN_W*WIN_H;i++) g_desk->px[i]=GFX_RGB(64,86,114);
    vst_color(HV,0); vst_height(HV,16,0,0,0,0);
    v_gtext(HV, 24, 120, g_status);
    vst_color(HV,0); vst_height(HV,13,0,0,0,0);
    v_gtext(HV, 24, WIN_H-30, "Click a menu title and drag to an item.  File > Quit to exit.");
}

int main(int argc, char **argv) {
    g_desk=gfx_surface_alloc(WIN_W,WIN_H);
    int HV; vdi_init(g_desk); HV=v_opnvwk(g_desk);
    font_face *ff=font_face_open("fonts/AovelSansRounded.ttf"); if(ff)font_face_set_tracking(ff,1); vdi_set_face(ff);
    static theme TH; if(theme_load(&TH,"themes/Aristo2/1x")){fprintf(stderr,"theme load failed (make themepack)\n");return 1;}
    aes_init(HV,&TH); appl_init();
    OBJECT *menu = menu_build(md, 3, WIN_W);

    if (argc>1 && !strcmp(argv[1],"--ppm")) {
        draw_desktop(HV); menu_bar(menu,1);
        menu_render_open(1, 1);                     // File menu, "Open…" highlighted
        FILE *f=fopen("/tmp/aes_menu.ppm","wb"); fprintf(f,"P6\n%d %d\n255\n",WIN_W,WIN_H);
        for(int i=0;i<WIN_W*WIN_H;i++){uint32_t v=g_desk->px[i];unsigned char c[3]={v>>24,v>>16,v>>8};fwrite(c,1,3,f);}
        fclose(f); return 0;
    }

    if (SDL_Init(SDL_INIT_VIDEO)!=0){fprintf(stderr,"SDL: %s\n",SDL_GetError());return 1;}
    SDL_Window *win=SDL_CreateWindow("GEM AES — menus",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,WIN_W,WIN_H,SDL_WINDOW_RESIZABLE);
    g_ren=SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    g_tex=SDL_CreateTexture(g_ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    aes_set_events(present_and_wait);

    draw_desktop(HV); menu_bar(menu,1);
    for (;;) {
        int16_t msg[8]; int mx,my,mb,ks,key;
        int r = evnt_multi(MU_MESAG|MU_KEYBD, 0,0,0, 0,0,0,0,0, 0,0,0,0,0, msg,0,0, &mx,&my,&mb,&ks,&key,0);
        if (r & MU_QUIT) break;
        if (r & MU_MESAG && msg[0]==MN_SELECTED) {
            const char *item = (const char*)menu[msg[4]].ob_spec;
            if (!strcmp(item,"Quit")) break;
            snprintf(g_status,sizeof g_status,"Selected: %s", item);
            printf("MN_SELECTED: title obj %d, item '%s'\n", msg[3], item);
            draw_desktop(HV); menu_bar(menu,1);        // redraw under the (now closed) menu
        }
    }
    free(menu); theme_free(&TH); if(ff)font_face_close(ff); gfx_surface_free(g_desk);
    SDL_DestroyTexture(g_tex); SDL_DestroyRenderer(g_ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
