// aes/window.c — the AES window layer: themed frames (9-slice window +
// titlebar + traffic lights), a z-ordered window list, and frame interaction
// (raise / drag / resize / close) caught inside evnt_multi.  The app draws each
// work area through a content callback and reacts to WM_* messages.  On the host
// the whole desktop is redrawn on each change (wind_redraw); the A9 build will
// use the DDR3 backing-store blit instead.

#include "aes/aes_internal.h"
#include "font.h"
#include <string.h>
#include <stdio.h>

gfx_surface *vdi_screen_target(void);   // the physical workstation's surface (VDI core)

#define MAXW 16
typedef struct {
    int used, kind, x, y, w, h, px,py,pw,ph;   // full rect (+ previous)
    char name[64];
    wind_draw_fn draw; void *ud;
} awin;

static awin g_w[MAXW];          // slot 0 unused (handles are 1-based)
static int  g_z[MAXW], g_nz;    // z-order: g_z[0] bottom .. g_z[nz-1] top
static uint32_t g_deskbg = 0x46566EFF;
static int H(void){ return aes_handle(); }

static int bw(void){ const theme_slice*s=theme_find(aes_theme(),"window"); return s?s->l:5; }
static int tbh(void){ const theme_slice*s=theme_find(aes_theme(),"titlebar"); return s?s->sh:22; }

void wind_calc(int dir,int kind,int x,int y,int w,int h,int*ox,int*oy,int*ow,int*oh){
    (void)kind; int b=bw(), th=tbh();
    if(dir==WC_BORDER){ *ox=x-b; *oy=y-b-th; *ow=w+2*b; *oh=h+2*b+th; }   // work -> full
    else              { *ox=x+b; *oy=y+b+th; *ow=w-2*b; *oh=h-2*b-th; }   // full -> work
}

static void spr(const char*n,int x,int y){ const theme_slice*s=theme_find(aes_theme(),n); if(s) theme_blit(H(),aes_theme(),s,x,y,s->sw,s->sh); }

static void draw_one(int hd, int active){
    awin*W=&g_w[hd]; int b=bw(), th=tbh();
    theme_draw(H(),aes_theme(),"window", W->x,W->y,W->w,W->h);
    theme_draw(H(),aes_theme(), active?"titlebar":"titlebar.inactive", W->x+b, W->y+b, W->w-2*b, th);
    int cy = W->y+b+(th-16)/2;
    if(W->kind & W_CLOSER) spr("close",    W->x+b+8,  cy);
    if(W->kind & W_FULLER) spr("maximize", W->x+b+28, cy);
    if(W->kind & W_NAME){ vst_color(H(),1); vst_height(H(),15,0,0,0,0);
        vst_alignment(H(),VDI_TA_CENTER,VDI_TA_HALF,0,0);
        v_gtext(H(), W->x+W->w/2, W->y+b+th/2, W->name);
        vst_alignment(H(),VDI_TA_LEFT,VDI_TA_TOP,0,0); }
    // work area + content (clipped)
    int wx,wy,ww,wh; wind_calc(WC_WORK,W->kind,W->x,W->y,W->w,W->h,&wx,&wy,&ww,&wh);
    if(W->draw){ int16_t clip[4]={(int16_t)wx,(int16_t)wy,(int16_t)(wx+ww-1),(int16_t)(wy+wh-1)};
        vs_clip(H(),1,clip); W->draw(hd,wx,wy,ww,wh,W->ud); vs_clip(H(),0,clip); }
}

void wind_set_desktop(uint32_t bg){ g_deskbg = bg; }

void wind_redraw(void){
    gfx_surface *d = vdi_screen_target();
    if(d){ uint32_t bg=g_deskbg; for(int i=0;i<d->w*d->h;i++) d->px[i]=bg; }
    for(int i=0;i<g_nz;i++) draw_one(g_z[i], i==g_nz-1);
    menu_redraw();                 // the menu bar sits above every window
}

int wind_create(int kind,int x,int y,int w,int h){
    for(int i=1;i<MAXW;i++) if(!g_w[i].used){
        memset(&g_w[i],0,sizeof g_w[i]); g_w[i].used=1; g_w[i].kind=kind;
        g_w[i].x=x; g_w[i].y=y; g_w[i].w=w; g_w[i].h=h;
        return i;
    }
    return 0;
}
void wind_open(int hd,int x,int y,int w,int h){
    if(hd<1||hd>=MAXW||!g_w[hd].used) return;
    g_w[hd].x=x; g_w[hd].y=y; g_w[hd].w=w; g_w[hd].h=h;
    for(int i=0;i<g_nz;i++) if(g_z[i]==hd) return;       // already open
    g_z[g_nz++]=hd; wind_redraw();
}
static void zremove(int hd){ for(int i=0;i<g_nz;i++) if(g_z[i]==hd){ for(int j=i;j<g_nz-1;j++) g_z[j]=g_z[j+1]; g_nz--; return; } }
void wind_close(int hd){ zremove(hd); wind_redraw(); }
void wind_delete(int hd){ if(hd>=1&&hd<MAXW){ zremove(hd); g_w[hd].used=0; } }
void wind_set_name(int hd,const char*n){ if(hd>=1&&hd<MAXW){ snprintf(g_w[hd].name,sizeof g_w[hd].name,"%s",n?n:""); } }
void wind_content(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].draw=fn; g_w[hd].ud=ud; } }

void wind_get(int hd,int field,int*a,int*b,int*c,int*d){
    if(hd<1||hd>=MAXW){ if(a)*a=0; return; }
    awin*W=&g_w[hd]; int x=W->x,y=W->y,w=W->w,h=W->h;
    if(field==WF_WORKXYWH) wind_calc(WC_WORK,W->kind,W->x,W->y,W->w,W->h,&x,&y,&w,&h);
    else if(field==WF_PREVXYWH){ x=W->px;y=W->py;w=W->pw;h=W->ph; }
    if(a)*a=x; if(b)*b=y; if(c)*c=w; if(d)*d=h;
}
void wind_set(int hd,int field,int a,int b,int c,int d){
    if(hd<1||hd>=MAXW) return; awin*W=&g_w[hd];
    if(field==WF_CURRXYWH){ W->px=W->x;W->py=W->y;W->pw=W->w;W->ph=W->h; W->x=a;W->y=b;W->w=c;W->h=d; wind_redraw(); }
}

int wind_find(int x,int y){
    for(int i=g_nz-1;i>=0;i--){ awin*W=&g_w[g_z[i]]; if(x>=W->x&&x<W->x+W->w&&y>=W->y&&y<W->y+W->h) return g_z[i]; }
    return 0;
}

static void post(int type,int hd,int a,int b,int c,int d){
    int16_t m[8]={(int16_t)type,1,0,(int16_t)hd,(int16_t)a,(int16_t)b,(int16_t)c,(int16_t)d}; appl_write(0,16,m);
}
static void raise(int hd){ zremove(hd); g_z[g_nz++]=hd; }

int wind_handle_click(int mx,int my){
    int hd = wind_find(mx,my);
    if(!hd) return 0;
    awin*W=&g_w[hd];
    if(g_z[g_nz-1]!=hd){ raise(hd); wind_redraw(); post(WM_TOPPED,hd,0,0,0,0); return 1; }
    int b=bw(), th=tbh();
    int tx=W->x+b, ty=W->y+b, tw=W->w-2*b;
    // close box
    if((W->kind&W_CLOSER) && mx>=tx+8 && mx<tx+8+16 && my>=ty && my<ty+th){ post(WM_CLOSED,hd,0,0,0,0); return 1; }
    // title bar -> drag (live move)
    if((W->kind&W_MOVER) && my>=ty && my<ty+th && mx>=tx && mx<tx+tw){
        int gx=mx-W->x, gy=my-W->y;
        for(;;){ aes_event e; int t=aes_wait(&e,-1); if(t==AES_QUIT)break;
            if(t==AES_MOTION){ W->x=e.mx-gx; W->y=e.my-gy; wind_redraw(); }
            if(t==AES_BTN_UP) break; }
        post(WM_MOVED,hd,W->x,W->y,W->w,W->h); return 1;
    }
    // size box (bottom-right corner)
    if((W->kind&W_SIZER) && mx>=W->x+W->w-18 && my>=W->y+W->h-18){
        for(;;){ aes_event e; int t=aes_wait(&e,-1); if(t==AES_QUIT)break;
            if(t==AES_MOTION){ int nw=e.mx-W->x, nh=e.my-W->y; if(nw<120)nw=120; if(nh<80)nh=80; W->w=nw; W->h=nh; wind_redraw(); }
            if(t==AES_BTN_UP) break; }
        post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
    }
    return 0;     // click in the work area -> the app gets it
}
