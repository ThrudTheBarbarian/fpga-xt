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
    int hidden;                                // lifted into the HW drag-overlay: skip in redraw
    char name[64];
    wind_draw_fn draw; void *ud;
    wind_draw_fn info; void *infoud;           // W_INFO chrome line
    wind_draw_fn title; void *titleud;         // interactive title renderer (wind_title)
    int titlex, titley, titlew, titleh;        // last title work rect (app-drawable span)
} awin;

static awin g_w[MAXW];          // slot 0 unused (handles are 1-based)
static int  g_z[MAXW], g_nz;    // z-order: g_z[0] bottom .. g_z[nz-1] top
static uint32_t g_deskbg = 0x46566EFF;
static int g_wa[4] = {-1,0,0,0};   // desktop work area (x,y,w,h); x<0 = auto
static int g_top_reserve = 0;       // top strip reserved by chrome (e.g. menu bar)
static int H(void){ return aes_handle(); }

// The desktop work area: what Desktop.app set, else the screen minus reserved
// top chrome.  Window 0 reports it (classic GEM).
static void work_area(int *x,int *y,int *w,int *h){
    if (g_wa[0] >= 0) { *x=g_wa[0]; *y=g_wa[1]; *w=g_wa[2]; *h=g_wa[3]; return; }
    gfx_surface *d = vdi_screen_target();
    *x = 0; *y = g_top_reserve; *w = d?d->w:0; *h = (d?d->h:0) - g_top_reserve;
}
void aes_set_workarea(int x,int y,int w,int h){ g_wa[0]=x; g_wa[1]=y; g_wa[2]=w; g_wa[3]=h; }
void aes_reserve_top(int h){ g_top_reserve = h; }

static int bw(void){ const theme_slice*s=theme_find(aes_theme(),"window"); return s?s->l:5; }
static int tbh(void){ const theme_slice*s=theme_find(aes_theme(),"titlebar"); return s?s->sh:22; }

void wind_calc(int dir,int kind,int x,int y,int w,int h,int*ox,int*oy,int*ow,int*oh){
    int b=bw(), th=tbh(), inf=(kind&W_INFO)?AES_INFO_H:0;
    if(dir==WC_BORDER){ *ox=x-b; *oy=y-th-inf; *ow=w+2*b; *oh=h+th+inf+b; }   // work -> full (flush header)
    else              { *ox=x+b; *oy=y+th+inf; *ow=w-2*b; *oh=h-th-inf-b; }   // full -> work
}

static void spr(const char*n,int x,int y){ const theme_slice*s=theme_find(aes_theme(),n); if(s) theme_blit(H(),aes_theme(),s,x,y,s->sw,s->sh); }

// Keep the window reachable: the title bar stays below the menu bar, above the
// work-area bottom, and at least MINVIS px stays on-screen horizontally — so a
// window can never be dragged completely out of reach.
#define MINVIS 72
static void clamp_win(awin *W){
    int wx,wy,ww,wh; work_area(&wx,&wy,&ww,&wh); int th=tbh();
    if (W->y < wy)            W->y = wy;
    if (W->y > wy+wh - th)    W->y = wy+wh - th;
    if (W->x > wx+ww - MINVIS)        W->x = wx+ww - MINVIS;
    if (W->x < wx - (W->w - MINVIS))  W->x = wx - (W->w - MINVIS);
}

static void draw_one(int hd, int active){
    awin*W=&g_w[hd]; int b=bw(), th=tbh();
    if(W->hidden) return;                        // lifted into the HW drag-overlay
    theme_draw(H(),aes_theme(),"window", W->x,W->y,W->w,W->h);
    theme_draw(H(),aes_theme(), active?"titlebar":"titlebar.inactive", W->x, W->y, W->w, th);  // flush top
    int cy = W->y+(th-16)/2;
    if(W->kind & W_CLOSER) spr("close",    W->x+8,  cy);
    if(W->kind & W_FULLER) spr("maximize", W->x+28, cy);
    if(W->kind & W_NAME){
        // Title work span: right of the close/full boxes, up to the right edge.
        int tlx=W->x+8; if(W->kind&W_CLOSER) tlx+=20; if(W->kind&W_FULLER) tlx+=20;
        int trx=W->x+W->w-8; int tlw=trx-tlx; if(tlw<0) tlw=0;
        W->titlex=tlx; W->titley=W->y; W->titlew=tlw; W->titleh=th;
        if(W->title){                          // app-drawn interactive title (clipped to its span)
            int16_t tc[4]={(int16_t)tlx,(int16_t)W->y,(int16_t)(trx-1),(int16_t)(W->y+th-1)};
            vs_clip(H(),1,tc); W->title(hd, tlx, W->y, tlw, th, W->titleud); vs_clip(H(),0,tc);
        } else {                               // plain centred name
            vst_color(H(),1); vst_height(H(),15,0,0,0,0);
            vst_alignment(H(),VDI_TA_CENTER,VDI_TA_HALF,0,0);
            v_gtext(H(), W->x+W->w/2, W->y+th/2, W->name);
            vst_alignment(H(),VDI_TA_LEFT,VDI_TA_TOP,0,0);
        }
    }
    if(W->kind & W_INFO){          // W_INFO chrome line under the title; tuck 2px inside the
        int ix=W->x+2, iy=W->y+th, iw=W->w-4;   // rounded frame corners (the flat fill can't self-round)
        vsf_color(H(),248); vsf_interior(H(),VDI_FIS_SOLID); vsf_perimeter(H(),0);   // PEN_DLG (object.c): light chrome
        int16_t ir[4]={(int16_t)ix,(int16_t)iy,(int16_t)(ix+iw-1),(int16_t)(iy+AES_INFO_H-1)}; vr_recfl(H(),ir);
        vsl_color(H(),249); vsl_width(H(),1);                                        // PEN_BORDER: bottom divider
        int16_t il[4]={(int16_t)ix,(int16_t)(iy+AES_INFO_H-1),(int16_t)(ix+iw-1),(int16_t)(iy+AES_INFO_H-1)}; v_pline(H(),2,il);
        if(W->info){ int16_t ic[4]={(int16_t)ix,(int16_t)iy,(int16_t)(ix+iw-1),(int16_t)(iy+AES_INFO_H-1)};
            vs_clip(H(),1,ic); W->info(hd,ix,iy,iw,AES_INFO_H,W->infoud); vs_clip(H(),0,ic); }
    }
    // work area + content (clipped)
    int wx,wy,ww,wh; wind_calc(WC_WORK,W->kind,W->x,W->y,W->w,W->h,&wx,&wy,&ww,&wh);
    if(W->draw){ int16_t clip[4]={(int16_t)wx,(int16_t)wy,(int16_t)(wx+ww-1),(int16_t)(wy+wh-1)};
        vs_clip(H(),1,clip); W->draw(hd,wx,wy,ww,wh,W->ud); vs_clip(H(),0,clip); }
}

void wind_set_desktop(uint32_t bg){ g_deskbg = bg; }

static wind_draw_fn g_deskcontent; static void *g_deskcontent_ud;
void wind_set_desktop_content(wind_draw_fn fn, void *ud){ g_deskcontent=fn; g_deskcontent_ud=ud; }

/* HW drag-overlay hooks (A9 only): begin() lifts the window rect into the overlay
 * plane, move() repositions it with NO redraw, end() drops it; present() pushes a
 * plane rect. All NULL on the SDL host -> classic redraw-per-motion drag. */
static int  (*g_ovl_begin)(int x,int y,int w,int h);
static void (*g_ovl_move)(int x,int y);
static void (*g_ovl_end)(void);
static void (*g_ovl_present)(int x,int y,int w,int h);
void wind_set_overlay(int(*begin)(int,int,int,int), void(*move)(int,int),
                      void(*end)(void), void(*present)(int,int,int,int)){
    g_ovl_begin=begin; g_ovl_move=move; g_ovl_end=end; g_ovl_present=present;
}
/* Push a just-drawn screen rect through the registered present hook, so code
 * that draws outside wind_redraw (modal dialogs, progress boxes) is visible on
 * targets that composite into a back-buffer (A9).  No-op when no hook is set
 * (the SDL host presents inside its event source). */
void aes_flush_rect(int x,int y,int w,int h){ if(g_ovl_present) g_ovl_present(x,y,w,h); }

/* The drag-overlay ops, for other modal movers (dialog drag in form.c): lift
 * returns 0 when no hook is registered / the lift was refused, and the caller
 * falls back to the classic redraw-per-motion move. */
int  aes_ovl_lift(int x,int y,int w,int h){ return g_ovl_begin ? g_ovl_begin(x,y,w,h) : 0; }
void aes_ovl_move(int x,int y){ if(g_ovl_move) g_ovl_move(x,y); }
void aes_ovl_drop(void){ if(g_ovl_end) g_ovl_end(); }

static int g_redraw_gen;           // bumped per wind_redraw: modal loops watch it
int aes_redraw_gen(void){ return g_redraw_gen; }

void wind_redraw(void){
    g_redraw_gen++;
    gfx_surface *d = vdi_screen_target();
    if(d){ uint32_t bg=g_deskbg; for(int i=0;i<d->w*d->h;i++) d->px[i]=bg; }
    if(g_deskcontent && d) g_deskcontent(0, 0,0, d->w,d->h, g_deskcontent_ud);  // wallpaper + icons
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
    g_w[hd].x=x; g_w[hd].y=y; g_w[hd].w=w; g_w[hd].h=h; clamp_win(&g_w[hd]);
    for(int i=0;i<g_nz;i++) if(g_z[i]==hd) return;       // already open
    g_z[g_nz++]=hd; wind_redraw();
}
static void zremove(int hd){ for(int i=0;i<g_nz;i++) if(g_z[i]==hd){ for(int j=i;j<g_nz-1;j++) g_z[j]=g_z[j+1]; g_nz--; return; } }
void wind_close(int hd){ zremove(hd); wind_redraw(); }
void wind_delete(int hd){ if(hd>=1&&hd<MAXW){ zremove(hd); g_w[hd].used=0; } }
void wind_set_name(int hd,const char*n){ if(hd>=1&&hd<MAXW){ snprintf(g_w[hd].name,sizeof g_w[hd].name,"%s",n?n:""); } }
void wind_content(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].draw=fn; g_w[hd].ud=ud; } }
void wind_info(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].info=fn; g_w[hd].infoud=ud; } }
void wind_title(int hd,wind_draw_fn fn,void*ud){ if(hd>=1&&hd<MAXW){ g_w[hd].title=fn; g_w[hd].titleud=ud; } }

void wind_get(int hd,int field,int*a,int*b,int*c,int*d){
    if(hd==0){ int x,y,w,h; work_area(&x,&y,&w,&h); if(a)*a=x; if(b)*b=y; if(c)*c=w; if(d)*d=h; return; }  // desktop
    if(hd<1||hd>=MAXW){ if(a)*a=0; return; }
    awin*W=&g_w[hd]; int x=W->x,y=W->y,w=W->w,h=W->h;
    if(field==WF_WORKXYWH) wind_calc(WC_WORK,W->kind,W->x,W->y,W->w,W->h,&x,&y,&w,&h);
    else if(field==WF_PREVXYWH){ x=W->px;y=W->py;w=W->pw;h=W->ph; }
    if(a)*a=x; if(b)*b=y; if(c)*c=w; if(d)*d=h;
}
void wind_set(int hd,int field,int a,int b,int c,int d){
    if(hd<1||hd>=MAXW) return; awin*W=&g_w[hd];
    if(field==WF_CURRXYWH){ W->px=W->x;W->py=W->y;W->pw=W->w;W->ph=W->h; W->x=a;W->y=b;W->w=c;W->h=d; clamp_win(W); wind_redraw(); }
}

int wind_find(int x,int y){
    for(int i=g_nz-1;i>=0;i--){ awin*W=&g_w[g_z[i]]; if(x>=W->x&&x<W->x+W->w&&y>=W->y&&y<W->y+W->h) return g_z[i]; }
    return 0;
}

int wind_top(void){ return g_nz ? g_z[g_nz-1] : 0; }

void wind_raise(int hd){
    if(hd<1||hd>=MAXW) return;
    for(int i=0;i<g_nz;i++) if(g_z[i]==hd){ zremove(hd); g_z[g_nz++]=hd; wind_redraw(); return; }
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
    int th=tbh();
    int tx=W->x, ty=W->y, tw=W->w;               // flush title bar
    // close box
    if((W->kind&W_CLOSER) && mx>=tx+8 && mx<tx+8+16 && my>=ty && my<ty+th){ post(WM_CLOSED,hd,0,0,0,0); return 1; }
    // title bar -> drag (live move)
    if((W->kind&W_MOVER) && my>=ty && my<ty+th && mx>=tx && mx<tx+tw){
        // Interactive title: a press on the app's title span that does NOT move is
        // a click for the app (return 0 -> evnt_multi delivers MU_BUTTON at the
        // press point, the app hit-tests its own title hot-rects).  A press that
        // moves past the slop still drags, so the whole title stays grab-to-move.
        if(W->title && mx>=W->titlex && mx<W->titlex+W->titlew){
            int dnx=mx, dny=my, moved=0;
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1);
                if(t==AES_QUIT) break;
                if(t==AES_MOTION){ int ex=e.mx-dnx, ey=e.my-dny; if(ex<0)ex=-ex; if(ey<0)ey=-ey;
                    if(ex>3||ey>3){ moved=1; break; } }
                if(t==AES_BTN_UP) break; }
            if(!moved) return 0;               // click (no drag) -> app handles it
            // moved: fall through into the drag loop (anchored to the press point)
        }
        int gx=mx-W->x, gy=my-W->y;
        if(g_ovl_begin && g_ovl_begin(W->x,W->y,W->w,W->h)){    // A9: lift window into the HW overlay
            int ox=W->x, oy=W->y, ow=W->w, oh=W->h;            // vacated rect
            W->hidden=1; wind_redraw();                        // erase from the plane (overlay still covers it)...
            if(g_ovl_present) g_ovl_present(ox,oy,ow,oh);      // ...push the now-behind pixels
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ W->x=e.mx-gx; W->y=e.my-gy; clamp_win(W); g_ovl_move(W->x,W->y); } // register write, no redraw
                if(t==AES_BTN_UP) break; }
            W->hidden=0; wind_redraw();                        // paint the window at its new home (under the overlay)...
            if(g_ovl_present){ g_ovl_present(ox,oy,ow,oh); g_ovl_present(W->x,W->y,W->w,W->h); }
            g_ovl_end();                                       // ...then drop the overlay -> seamless
        } else {                                               // SDL host: classic redraw-per-motion
            for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
                if(t==AES_MOTION){ W->x=e.mx-gx; W->y=e.my-gy; clamp_win(W); wind_redraw(); }
                if(t==AES_BTN_UP) break; }
        }
        post(WM_MOVED,hd,W->x,W->y,W->w,W->h); return 1;
    }
    // size box (bottom-right corner)
    if((W->kind&W_SIZER) && mx>=W->x+W->w-18 && my>=W->y+W->h-18){
        for(;;){ aes_event e; int t=aes_wait_idle(&e,-1); if(t==AES_QUIT)break;
            if(t==AES_MOTION){ int nw=e.mx-W->x, nh=e.my-W->y; if(nw<120)nw=120; if(nh<80)nh=80; W->w=nw; W->h=nh; wind_redraw(); }
            if(t==AES_BTN_UP) break; }
        post(WM_SIZED,hd,W->x,W->y,W->w,W->h); return 1;
    }
    return 0;     // click in the work area -> the app gets it
}
