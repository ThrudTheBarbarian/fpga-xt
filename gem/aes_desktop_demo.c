// aes_desktop_demo.c — the whole AES, interactive, in one SDL window: a themed
// desktop with a menu bar, draggable/resizable/closable windows, and a modal
// dialog launched from a menu.  Everything routes through evnt_multi + the
// message pipe.  Esc / close to quit; File > Quit too.

#include "aes/aes_internal.h"
#include "font.h"
#include <stdio.h>
#include <string.h>
#include <SDL2/SDL.h>

#define WIN_W 720
#define WIN_H 480

static const char *desk_i[] = {"About XT…"};
static const char *file_i[] = {"New Window", "Quit"};
static const char *edit_i[] = {"Cut", "Copy", "Paste"};
static menu_def md[] = { {"Desk",desk_i,1}, {"File",file_i,2}, {"Edit",edit_i,3} };

// The About dialog as an OBJECT tree.
enum { D_ROOT, D_TITLE, D_L1, D_L2, D_OK };
static OBJECT about[] = {
 { NIL,  D_TITLE, D_OK, G_BOX,    OF_NONE,                                     OS_NORMAL, 0,                              0,0, 320,150 },
 { D_L1, NIL,     NIL,  G_STRING, OF_NONE,                                     OS_NORMAL, (void*)"XT — GEM Desktop",        28,22, 280,18 },
 { D_L2, NIL,     NIL,  G_STRING, OF_NONE,                                     OS_NORMAL, (void*)"VDI + AES on the Aristo2 theme.", 28,50, 280,16 },
 { D_OK, NIL,     NIL,  G_STRING, OF_NONE,                                     OS_NORMAL, (void*)"Clean-room, RGBA-8888, scalable.",  28,72, 280,16 },
 { D_ROOT,NIL,    NIL,  G_BUTTON, OF_SELECTABLE|OF_EXIT|OF_DEFAULT|OF_LASTOB,  OS_NORMAL, (void*)"OK",                     220,108, 76,30 },
};

static SDL_Renderer *g_ren; static SDL_Texture *g_tex; static gfx_surface *g_desk;
static int g_btn, HV;
static OBJECT *g_menu;

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
            ev->type=AES_KEY; ev->key=(e.key.keysym.sym==SDLK_RETURN?'\r':(int)e.key.keysym.sym); return AES_KEY;
        case SDL_MOUSEMOTION: ev->type=AES_MOTION; ev->mx=e.motion.x-ox; ev->my=e.motion.y-oy; return AES_MOTION;
        case SDL_MOUSEBUTTONDOWN: if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn|=1; ev->button=g_btn; ev->type=AES_BTN_DOWN; ev->mx=e.button.x-ox; ev->my=e.button.y-oy; return AES_BTN_DOWN;
        case SDL_MOUSEBUTTONUP: if(e.button.button!=SDL_BUTTON_LEFT)break;
            g_btn&=~1; ev->button=g_btn; ev->type=AES_BTN_UP; ev->mx=e.button.x-ox; ev->my=e.button.y-oy; return AES_BTN_UP;
    }} while(SDL_PollEvent(&e));
    ev->type=AES_NONE; return AES_NONE;
}

static void xl_draw(int hd,int wx,int wy,int ww,int wh,void*ud){ (void)hd;(void)ud;
    vsf_color(HV,1); vsf_interior(HV,VDI_FIS_SOLID); vsf_perimeter(HV,0);
    int16_t r[4]={(int16_t)wx,(int16_t)wy,(int16_t)(wx+ww-1),(int16_t)(wy+wh-1)}; vr_recfl(HV,r);
    vst_color(HV,3); vst_height(HV,16,0,0,0,0);
    v_gtext(HV,wx+10,wy+10,"READY");
    v_gtext(HV,wx+10,wy+34,"10 PRINT \"HELLO FROM XT\"");
    v_gtext(HV,wx+10,wy+54,"20 GOTO 10");
    v_gtext(HV,wx+10,wy+82,"RUN");
}

static int g_nx=80,g_ny=70;
static void open_xl(const char*name){
    int h=wind_create(W_NAME|W_CLOSER|W_MOVER|W_SIZER|W_FULLER,g_nx,g_ny,340,210);
    if(!h)return; wind_set_name(h,name); wind_content(h,xl_draw,0);
    wind_open(h,g_nx,g_ny,340,210); g_nx+=34; g_ny+=30;
}
static void deskredraw(void){ wind_redraw(); menu_bar(g_menu,1); }

static void run_about(void){
    about[D_ROOT].ob_x=(WIN_W-about[D_ROOT].ob_w)/2;
    about[D_ROOT].ob_y=(WIN_H-about[D_ROOT].ob_h)/2;
    form_do(about, D_ROOT);
    about[D_OK].ob_state &= ~OS_SELECTED;
    deskredraw();
}

int main(int argc,char**argv){
    g_desk=gfx_surface_alloc(WIN_W,WIN_H);
    vdi_init(g_desk); HV=v_opnvwk(g_desk);
    font_face*ff=font_face_open("fonts/AovelSansRounded.ttf"); if(ff)font_face_set_tracking(ff,1); vdi_set_face(ff);
    static theme TH; if(theme_load(&TH,"themes/Aristo2/1x")){fprintf(stderr,"theme load failed (make themepack)\n");return 1;}
    aes_init(HV,&TH); appl_init(); wind_set_desktop(0x46566EFF);
    g_menu=menu_build(md,3,WIN_W);
    wind_redraw(); menu_bar(g_menu,1);
    open_xl("Atari XL"); open_xl("Atari XL #2"); menu_bar(g_menu,1);

    if(argc>1 && !strcmp(argv[1],"--ppm")){
        about[D_ROOT].ob_x=(WIN_W-about[D_ROOT].ob_w)/2; about[D_ROOT].ob_y=130;
        objc_draw(about,D_ROOT,8,0,0,WIN_W,WIN_H);     // show the dialog over the desktop
        FILE*f=fopen("/tmp/aes_desktop.ppm","wb"); fprintf(f,"P6\n%d %d\n255\n",WIN_W,WIN_H);
        for(int i=0;i<WIN_W*WIN_H;i++){uint32_t v=g_desk->px[i];unsigned char c[3]={v>>24,v>>16,v>>8};fwrite(c,1,3,f);}
        fclose(f); return 0;
    }

    if(SDL_Init(SDL_INIT_VIDEO)!=0){fprintf(stderr,"SDL: %s\n",SDL_GetError());return 1;}
    SDL_Window*win=SDL_CreateWindow("XT — GEM Desktop",SDL_WINDOWPOS_CENTERED,SDL_WINDOWPOS_CENTERED,WIN_W,WIN_H,SDL_WINDOW_RESIZABLE);
    g_ren=SDL_CreateRenderer(win,-1,SDL_RENDERER_ACCELERATED);
    g_tex=SDL_CreateTexture(g_ren,SDL_PIXELFORMAT_RGBA8888,SDL_TEXTUREACCESS_STREAMING,WIN_W,WIN_H);
    aes_set_events(present_and_wait);

    for(;;){
        int16_t msg[8]; int mx,my,mb,ks,key;
        int r=evnt_multi(MU_MESAG|MU_KEYBD,0,0,0,0,0,0,0,0,0,0,0,0,0,msg,0,0,&mx,&my,&mb,&ks,&key,0);
        if(r&MU_QUIT) break;
        if(r&MU_MESAG){
            if(msg[0]==WM_CLOSED){ wind_close(msg[3]); menu_bar(g_menu,1); }
            else if(msg[0]==WM_MOVED||msg[0]==WM_SIZED||msg[0]==WM_TOPPED) menu_bar(g_menu,1);
            else if(msg[0]==MN_SELECTED){
                const char*it=(const char*)g_menu[msg[4]].ob_spec;
                if(!strcmp(it,"Quit")) break;
                else if(!strcmp(it,"New Window")) open_xl("Atari XL");
                else if(!strcmp(it,"About XT…")) run_about();
                menu_bar(g_menu,1);
            }
        }
    }
    free(g_menu); theme_free(&TH); if(ff)font_face_close(ff); gfx_surface_free(g_desk);
    SDL_DestroyTexture(g_tex); SDL_DestroyRenderer(g_ren); SDL_DestroyWindow(win); SDL_Quit();
    return 0;
}
